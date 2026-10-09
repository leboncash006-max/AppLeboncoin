import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'mpb_service.dart';

/// Catalogue local des noms EXACTS des modèles MPB (avec leur identifiant).
///
/// Le moteur de recherche de MPB ne trouve un modèle que si on tape presque
/// son nom exact (« Sony A68 » ne trouve pas « Sony Alpha SLT-A68 »). On
/// télécharge donc une fois la liste complète des modèles depuis MPB, on la
/// garde dans l'appli (rafraîchie chaque semaine) et on fait la correspondance
/// en local, sans appel réseau ni IA quand le nom est sans ambiguïté.
class MpbCatalog {
  final Map<String, int> ids; // nom exact → identifiant MPB
  final DateTime date;
  late final List<_Entry> _entries =
      ids.keys.map((n) => _Entry(n, tokens(n), normalize(n))).toList();

  MpbCatalog(this.ids, this.date);

  static const maxAge = Duration(days: 7);
  static const _version = 2; // 2 : tous marchés
  static MpbCatalog? _memory;

  int get size => ids.length;
  bool get stale => DateTime.now().difference(date) > maxAge;

  // ------------------------------------------------------------ stockage

  static Future<File> _file() async =>
      File('${(await getApplicationSupportDirectory()).path}/mpb_catalog.json');

  /// Catalogue enregistré dans l'appli (null si jamais téléchargé).
  static Future<MpbCatalog?> load() async {
    if (_memory != null) return _memory;
    try {
      final f = await _file();
      if (!await f.exists()) return null;
      final j = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
      _memory = MpbCatalog(
        Map<String, dynamic>.from(j['ids'] as Map).map((k, v) => MapEntry(k, (v as num).toInt())),
        // ancien format : gardé en secours mais considéré périmé (retéléchargé)
        (j['v'] as num? ?? 1) < _version ? DateTime(2000) : DateTime.parse(j['date'] as String),
      );
      return _memory;
    } catch (_) {
      return null;
    }
  }

  Future<void> _save() async {
    final f = await _file();
    await f.writeAsString(jsonEncode({'v': _version, 'date': date.toIso8601String(), 'ids': ids}));
  }

  /// Demande un nouveau téléchargement à la prochaine analyse.
  static Future<void> invalidate() async {
    _memory = null;
    try {
      final f = await _file();
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }

  /// Catalogue à jour : celui de l'appli s'il a moins d'une semaine, sinon
  /// téléchargé depuis MPB. En cas d'échec, l'ancien catalogue (ou null).
  static Future<MpbCatalog?> ensure(MpbService mpb, {void Function(String)? onStatus}) async {
    final current = await load();
    if (current != null && !current.stale) return current;
    try {
      onStatus?.call(current == null
          ? 'Téléchargement du catalogue MPB (une seule fois)…'
          : 'Mise à jour du catalogue MPB…');
      final ids = await mpb.allModels(onProgress: (n) => onStatus?.call('Catalogue MPB : $n modèles…'));
      if (ids.length < 500) return current; // liste manifestement incomplète
      // 2e passe sans filtre de marché : des modèles (ex. Sony Alpha SLT-A68) manquaient
      try {
        await mpb.allModels(
            market: null, into: ids, onProgress: (n) => onStatus?.call('Catalogue MPB : $n modèles…'));
      } catch (_) {}
      final cat = MpbCatalog(ids, DateTime.now());
      await cat._save();
      _memory = cat;
      return cat;
    } catch (_) {
      return current;
    }
  }

  // ---------------------------------------------------------- correspondance

  static String normalize(String s) => tokens(s).join(' ');

  /// Mots en minuscules, sans accents ni ponctuation (« SLT-A68 » → slt, a68 ;
  /// « 55mm » → 55, mm ; « f/1.8 » → f, 1.8).
  static List<String> tokens(String s) {
    var t = s.toLowerCase();
    const accents = {'é': 'e', 'è': 'e', 'ê': 'e', 'à': 'a', 'â': 'a', 'î': 'i', 'ô': 'o', 'û': 'u', 'ç': 'c'};
    accents.forEach((a, b) => t = t.replaceAll(a, b));
    t = t.replaceAllMapped(RegExp(r'(\d)mm\b'), (m) => '${m[1]} mm');
    // « α68 », « alpha 68 », « alpha-68 » → a68 (référence Sony)
    t = t.replaceAllMapped(RegExp(r'(?:α|\balpha)[\s-]?(\d{1,4}[a-z]{0,3})\b'), (m) => 'a${m[1]}');
    t = t.replaceAll('α', 'a');
    return t
        .split(RegExp(r'[^a-z0-9.]+'))
        .map((w) => w.replaceAll(RegExp(r'^\.+|\.+$'), ''))
        .where((w) => w.isNotEmpty)
        .toList();
  }

  static bool _hasDigit(String w) => w.contains(RegExp(r'\d'));

  /// Nom du catalogue identique au nom deviné (à la ponctuation près).
  String? exact(String guess) {
    final n = normalize(guess);
    if (n.isEmpty) return null;
    for (final e in _entries) {
      if (e.norm == n) return e.name;
    }
    return null;
  }

  /// Les [limit] noms du catalogue les plus proches de [query]. Les références
  /// (mots avec chiffres : a68, 1200d, 18, 55, 1.8…) comptent beaucoup plus que
  /// les mots ordinaires, et une référence absente de la requête pénalise.
  List<String> match(String query, {String brand = '', int limit = 10}) {
    final q = tokens(query).toSet();
    final codes = q.where(_hasDigit).toSet();
    final b = tokens(brand).toSet();
    final scored = <(double, _Entry)>[];
    for (final e in _entries) {
      var score = 0.0;
      var codeHits = 0;
      for (final w in e.tokens) {
        if (q.contains(w)) {
          if (_hasDigit(w)) {
            score += 3;
            codeHits++;
          } else {
            score += 1;
          }
        } else if (_hasDigit(w)) {
          score -= 1; // autre référence : autre modèle
        }
      }
      if (codes.isNotEmpty && codeHits == 0) continue;
      if (b.isNotEmpty && !e.tokens.any(b.contains)) continue;
      if (score > 0) scored.add((score - e.tokens.length * 0.01, e));
    }
    if (scored.isEmpty && b.isNotEmpty) return match(query, limit: limit);
    scored.sort((a, b) => b.$1.compareTo(a.$1));
    return scored.take(limit).map((s) => s.$2.name).toList();
  }
}

class _Entry {
  final String name;
  final List<String> tokens;
  final String norm;
  _Entry(this.name, this.tokens, this.norm);
}
