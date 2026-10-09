import '../models.dart';
import 'mpb_catalog.dart';

/// Identification SANS IA : retrouve dans le catalogue MPB local les boîtiers,
/// objectifs et flashs cités dans l'annonce, et repère défauts, déclenchements
/// et état par mots-clés. Gemini ne sert plus qu'en secours (rien reconnu).
class LocalIdentifier {
  final MpbCatalog catalog;
  LocalIdentifier(this.catalog);

  static final _cache = Expando<List<_Model>>();

  List<_Model> get _models => _cache[catalog] ??= catalog.ids.keys.map(_Model.parse).whereType<_Model>().toList();

  LocalResult identify(String title, String description, String attributes) {
    final text = '$title\n$attributes\n$description';
    final low = _deaccent(text.toLowerCase());
    final ad = _AdIndex(low);
    final special = RegExp(r'astro|infrarouge|converti|modifi|full spectrum');
    final allowSpecial = special.hasMatch(low);

    // ---- boîtiers et flashs : marque + toutes les références présentes
    final bodies = <String, ({_Model m, double score, double second})>{};
    for (final m in _models.where((m) => m.kind != _Kind.lens)) {
      if (!ad.brands.contains(m.brand)) continue;
      if (m.codes.isEmpty || !m.codes.every((alts) => alts.any(ad.has))) continue;
      if (!allowSpecial && special.hasMatch(m.lower)) continue;
      var score = 10.0 + 2 * m.codes.length;
      for (final w in m.extra) {
        if (ad.has(w)) score += 1;
      }
      for (final r in m.roman) {
        if (!ad.has(r)) score -= 3; // « Mark II » absent de l'annonce
      }
      for (final r in ad.roman) {
        if (!m.roman.contains(r) && m.extra.isNotEmpty) score -= 1;
      }
      final key = '${m.brand}:${m.codes.map((c) => c.first).join('+')}';
      final cur = bodies[key];
      if (cur == null || score > cur.score) {
        bodies[key] = (m: m, score: score, second: cur?.score ?? 0);
      } else if (score > cur.second) {
        bodies[key] = (m: cur.m, score: cur.score, second: score);
      }
    }
    // une référence contenue dans une autre plus longue (5d / 5d mark ii) : garder la plus précise
    final bodyList = bodies.values.toList()..sort((a, b) => b.score.compareTo(a.score));

    // ---- objectifs : même focale (zoom ou fixe), départagés par ouverture et mentions
    final lenses = <String, ({_Model m, double score, double second})>{};
    for (final m in _models.where((m) => m.kind == _Kind.lens)) {
      if (m.focal == null || !ad.focals.contains(m.focal)) continue;
      final brandKnown = ad.brands.contains(m.brand);
      // un objectif exige sa marque dans l'annonce (« 55mm » seul = souvent un filtre)
      if (!brandKnown) continue;
      // focale fixe : il faut aussi l'ouverture (« 50mm 1.8 »), sinon trop ambigu
      final prime = !m.focal!.contains('-');
      if (prime && m.apertures.isNotEmpty && !m.apertures.any(ad.has)) continue;
      // montures anciennes citées (FD, FL, AI, M42…) : seulement les objectifs de cette monture
      final vintage = _vintageMounts.where(ad.has).toList();
      if (vintage.isNotEmpty && !vintage.any((v) => m.lower.contains(v))) continue;
      if (!allowSpecial && special.hasMatch(m.lower)) continue;
      var score = 10.0 + (brandKnown ? 3 : 0);
      for (final a in m.apertures) {
        score += ad.has(a) ? 2 : -0.5;
      }
      for (final w in m.extra) {
        if (ad.has(w)) {
          score += 1;
        } else {
          // version haut de gamme non citée (PRO, L, Art, GM…) : très peu probable
          score -= _premium.contains(w) ? 4 : 0.3;
        }
      }
      // ouverture non précisée : préférer l'objectif « grand public » (ouverture variable)
      if (!m.apertures.any(ad.has) && m.apertures.length >= 2) score += 1;
      if (m.mount != null && ad.brands.contains(m.mount)) score += 1;
      final key = m.focal!;
      final cur = lenses[key];
      if (cur == null || score > cur.score) {
        lenses[key] = (m: m, score: score, second: cur?.score ?? 0);
      } else if (score > cur.second) {
        lenses[key] = (m: cur.m, score: cur.score, second: score);
      }
    }

    final items = <ItemResult>[];
    for (final b in bodyList.take(4)) {
      items.add(_item(b.m, b.score - b.second >= 1));
    }
    for (final l in lenses.values.toList()..sort((a, b) => b.score.compareTo(a.score))) {
      if (items.length >= 6) break;
      items.add(_item(l.m, l.score - l.second >= 1));
    }

    return LocalResult(
      items: items,
      defects: _defects(low),
      shutterCount: _shutter(low),
      conditionHint: _condition(low),
      priceInText: _price(low),
    );
  }

  ItemResult _item(_Model m, bool confident) {
    final type = switch (m.kind) {
      _Kind.lens => 'objectif',
      _Kind.flash => 'flash',
      _Kind.body => 'boitier',
    };
    final it = ExtractedItem(
      type: type,
      brand: m.brand,
      nameGuess: m.name,
      searchQuery: m.name,
      details: 'Identifié sans IA (catalogue MPB)',
    );
    return ItemResult(it, [m.name])
      ..mpbModel = m.name
      ..confident = confident
      ..reason = confident ? 'Correspondance locale' : 'Plusieurs versions possibles';
  }

  // ------------------------------------------------------------- mots-clés

  static const _defectWords = {
    'hors service': 'hors service',
    'pour pieces': 'pour pièces',
    'ne fonctionne pas': 'ne fonctionne pas',
    'ne fonctionne plus': 'ne fonctionne plus',
    'en panne': 'en panne',
    'champignon': 'champignon',
    'moisissure': 'moisissure',
    'fongus': 'champignon',
    'rayure': 'rayure',
    'raye': 'rayure',
    'ecran casse': 'écran cassé',
    'ecran fissure': 'écran fissuré',
    'fissure': 'fissure',
    'casse': 'cassé',
    'defectueux': 'défectueux',
    'bloque': 'bloqué',
    'message d\'erreur': 'erreur',
    'err 01': 'erreur',
    'erreur': 'erreur',
    'buee': 'buée',
    'poussiere': 'poussière',
    'sans batterie': 'sans batterie',
    'sans chargeur': 'sans chargeur',
    'manque': 'pièce manquante',
  };

  static List<String> _defects(String low) {
    final out = <String>{};
    if (RegExp(r'\bhs\b').hasMatch(low)) out.add('HS');
    _defectWords.forEach((k, v) {
      if (RegExp('\\b${RegExp.escape(k)}').hasMatch(low)) out.add(v);
    });
    // « aucune rayure », « pas de champignon » : pas des défauts
    out.removeWhere((d) => RegExp('(aucun|aucune|pas de|sans|zero|0)\\s+${RegExp.escape(_deaccent(d))}').hasMatch(low));
    return out.toList();
  }

  static int? _shutter(String low) {
    final m = RegExp(r'(\d[\d\s.]{0,7}\d|\d)\s*(k)?\s*(?:declenchements?|clics?|shots?|actuations?)').firstMatch(low) ??
        RegExp(r'(?:declenchements?|clics?|shutter count|compteur)\s*:?\s*(\d[\d\s.]{0,7}\d|\d)\s*(k)?').firstMatch(low);
    if (m == null) return null;
    final n = int.tryParse(m.group(1)!.replaceAll(RegExp(r'[\s.]'), ''));
    if (n == null) return null;
    return m.group(2) == null ? n : n * 1000;
  }

  static String _condition(String low) {
    if (RegExp(r'comme neuf|etat neuf|jamais servi').hasMatch(low)) return 'comme_neuf';
    if (RegExp(r'tres bon etat|excellent etat|parfait etat').hasMatch(low)) return 'excellent';
    if (RegExp(r'bon etat').hasMatch(low)) return 'bon';
    if (RegExp(r'traces d.usure|etat d.usage|use\b|usee').hasMatch(low)) return 'use';
    return 'inconnu';
  }

  static double? _price(String low) {
    final m = RegExp(r'(\d{2,5})\s*(?:€|euros?)').firstMatch(low);
    return m == null ? null : double.tryParse(m.group(1)!);
  }
}

/// Résultat de l'identification locale.
class LocalResult {
  final List<ItemResult> items;
  final List<String> defects;
  final int? shutterCount;
  final String conditionHint;
  final double? priceInText;
  LocalResult({
    required this.items,
    required this.defects,
    required this.shutterCount,
    required this.conditionHint,
    required this.priceInText,
  });
}

// --------------------------------------------------------------------- index

const _brandAliases = {
  'canon': 'canon',
  'nikon': 'nikon',
  'nikkor': 'nikon',
  'sony': 'sony',
  'fujifilm': 'fujifilm',
  'fuji': 'fujifilm',
  'panasonic': 'panasonic',
  'lumix': 'panasonic',
  'olympus': 'olympus',
  'om': 'olympus',
  'pentax': 'pentax',
  'leica': 'leica',
  'sigma': 'sigma',
  'tamron': 'tamron',
  'tokina': 'tokina',
  'samyang': 'samyang',
  'rokinon': 'samyang',
  'zeiss': 'zeiss',
  'voigtlander': 'voigtlander',
  'ricoh': 'ricoh',
  'hasselblad': 'hasselblad',
  'gopro': 'gopro',
  'dji': 'dji',
  'minolta': 'minolta',
  'viltrox': 'viltrox',
  'godox': 'godox',
  'nissin': 'nissin',
  'metz': 'metz',
  'yongnuo': 'yongnuo',
  'laowa': 'laowa',
  'meike': 'meike',
  'ttartisan': 'ttartisan',
  '7artisans': '7artisans',
};

/// Mentions des versions haut de gamme (beaucoup plus chères).
const _premium = {'pro', 'l', 'art', 'sport', 'sports', 'gm', 'master', 'plena', 'noct', 'apd'};

/// Montures anciennes : si l'annonce en cite une, l'objectif doit être de cette monture.
const _vintageMounts = ['fd', 'fl', 'nfd', 'ais', 'm42', 'pk'];


/// Mots qui désignent des accessoires sans intérêt : exclus du catalogue local.
final _accessory = RegExp(
    r'\b(grip|poignee|batterie|battery|chargeur|charger|filtre|filter|adaptateur|adapter|bouchon|cap|pare-soleil|hood|'
    r'sac|bag|trepied|tripod|courroie|strap|telecommande|remote|cable|carte|card|oeilleton|eyecup|viseur|viewfinder|'
    r'microphone|housing|caisson|bague|ring|extender|teleconvertisseur|teleconverter|multiplicateur|kit de nettoyage)\b');

final _romanOrMark = RegExp(r'^(ii|iii|iv|v|vi|mark|mk|mkii|mkiii)$');

/// Mots génériques ignorés dans la comparaison.
const _stop = {
  'mm', 'f', 'monture', 'objectif', 'lens', 'de', 'pour', 'avec', 'et', 'le', 'la', 'boitier', 'body', 'appareil',
  'photo', 'numerique', 'hybride', 'reflex', 'camera', 'nu', 'seul', 'only',
};

enum _Kind { body, lens, flash }

class _Model {
  final String name;
  final String lower;
  final String brand;
  final _Kind kind;
  final List<List<String>> codes; // références obligatoires (boîtiers, flashs), avec variantes
  final List<String> extra; // mots secondaires (départage)
  final List<String> roman; // ii, iii, mark…
  final String? focal; // « 18-55 » ou « 50 »
  final List<String> apertures; // « 1.8 », « 3.5 », « 5.6 »
  final String? mount;

  _Model(this.name, this.lower, this.brand, this.kind, this.codes, this.extra, this.roman, this.focal,
      this.apertures, this.mount);

  static _Model? parse(String name) {
    final lower = _deaccent(name.toLowerCase());
    if (_accessory.hasMatch(lower)) return null;
    final toks = MpbCatalog.tokens(name);
    if (toks.isEmpty) return null;
    final brand = _brandAliases[toks.first];
    if (brand == null) return null;
    final focalM = RegExp(r'(\d+(?:\.\d+)?)(?:\s*-\s*(\d+(?:\.\d+)?))?\s*mm').firstMatch(lower);
    final isFlash = RegExp(r'speedlite|speedlight|flash|\bsb-\d|\bfl-|\bhvl-').hasMatch(lower);
    final mountM = RegExp(r'monture\s+([a-z]+)').firstMatch(lower);
    final mount = mountM == null ? null : _brandAliases[mountM.group(1)!];
    final roman = toks.where(_romanOrMark.hasMatch).toList();

    if (focalM != null && !isFlash) {
      final focal = focalM.group(2) == null ? _num(focalM.group(1)!) : '${_num(focalM.group(1)!)}-${_num(focalM.group(2)!)}';
      // ouvertures écrites « f/2.4 » ou « f/3.5-5.6 » (pas le f de « XF 60mm »)
      final apertures = RegExp(r'(?<![a-z])f/(\d+(?:\.\d+)?)(?:\s*-\s*(\d+(?:\.\d+)?))?')
          .allMatches(lower)
          .expand((m) => [m.group(1), m.group(2)])
          .whereType<String>()
          .toList();
      final extra = toks
          .skip(1)
          .where((w) => !RegExp(r'\d').hasMatch(w) && !_stop.contains(w) && w.length >= 2 && _brandAliases[w] == null)
          .toList();
      // série L de Canon (« f/4L ») : mention haut de gamme
      if (RegExp(r'f/\d+(?:\.\d+)?l\b').hasMatch(lower)) extra.add('l');
      return _Model(name, lower, brand, _Kind.lens, const [], extra, roman, focal, apertures, mount);
    }

    // boîtier / flash : références = mots avec chiffres (et lettre, ou ≥ 3 chiffres),
    // plus les formes collées « x-t3 » → xt3, « slt-a68 » → a68 déjà présent
    final codes = <List<String>>[];
    for (var i = 1; i < toks.length; i++) {
      final w = toks[i];
      if (!RegExp(r'\d').hasMatch(w)) continue;
      final hasLetter = RegExp(r'[a-z]').hasMatch(w);
      final prev = toks[i - 1];
      final joined = RegExp(r'^[a-z]{1,3}$').hasMatch(prev) && _brandAliases[prev] == null ? '$prev$w' : null;
      if (hasLetter || w.length >= 3) {
        codes.add([w, if (joined != null) joined]); // « X-T3 » : t3 ou xt3
      } else if (joined != null) {
        codes.add([joined]); // « a 7 » → a7
      }
    }
    if (codes.isEmpty) return null;
    final extra = toks
        .skip(1)
        .where((w) => !RegExp(r'\d').hasMatch(w) && !_stop.contains(w) && !_romanOrMark.hasMatch(w) && w.length >= 2)
        .toList();
    return _Model(name, lower, brand, isFlash ? _Kind.flash : _Kind.body, codes, extra, roman, null, const [], mount);
  }
}

String _num(String s) => s.endsWith('.0') ? s.substring(0, s.length - 2) : s;

String _deaccent(String s) {
  const m = {'é': 'e', 'è': 'e', 'ê': 'e', 'ë': 'e', 'à': 'a', 'â': 'a', 'î': 'i', 'ï': 'i', 'ô': 'o', 'û': 'u', 'ù': 'u', 'ç': 'c'};
  var t = s;
  m.forEach((a, b) => t = t.replaceAll(a, b));
  return t;
}

/// Index de l'annonce : mots, mots collés deux à deux, focales et marques citées.
class _AdIndex {
  final Set<String> words = {};
  final Set<String> focals = {};
  final Set<String> brands = {};
  final Set<String> roman = {};

  _AdIndex(String low) {
    final toks = MpbCatalog.tokens(low);
    words.addAll(toks);
    for (var i = 0; i + 1 < toks.length; i++) {
      words.add('${toks[i]}${toks[i + 1]}'); // « d 3200 » → d3200, « x t3 » → xt3
    }
    // « 600D » collé à la marque : « canon600d »
    for (final w in toks) {
      final b = _brandAliases[w];
      if (b != null) brands.add(b);
      final m = RegExp(r'^([a-z]+)(\d.*)$').firstMatch(w);
      if (m != null && _brandAliases[m.group(1)] != null) {
        brands.add(_brandAliases[m.group(1)]!);
        words.add(m.group(2)!);
      }
      if (_romanOrMark.hasMatch(w)) roman.add(w);
      // « a7iii » → a7 + iii, « 5dmkii » → 5d + ii
      final r = RegExp(r'^([a-z]*\d+)(?:mk)?(iii|ii|iv)$').firstMatch(w) ??
          RegExp(r'^([a-z]*\d+[a-z])(?:mk)?(iii|ii|iv)$').firstMatch(w);
      if (r != null) {
        words.add(r.group(1)!);
        roman.add(r.group(2)!);
      }
    }
    if (low.contains('mkii') || low.contains('mk2') || low.contains('mark 2')) roman.add('ii');
    if (low.contains('mkiii') || low.contains('mk3') || low.contains('mark 3')) roman.add('iii');
    words.addAll(roman);
    if (RegExp(r'\d(?:[.,]\d)?\s*l\b|serie l\b|\bl series?\b').hasMatch(low)) words.add('l');
    // focales : « 18-55 », « 18-55mm », « 70 - 300 mm », « 50mm »
    for (final m in RegExp(r'(?<![\d.,/])(\d{1,3})(?![\d.,])\s*(?:-|–|a)\s*(\d{2,3})(?![\d.,])\s*(?:mm)?').allMatches(low)) {
      final a = int.parse(m.group(1)!), b = int.parse(m.group(2)!);
      if (a < b && a >= 4) focals.add('$a-$b');
    }
    for (final m in RegExp(r'(?<![\d.,/-])(\d{1,4})\s*mm').allMatches(low)) {
      focals.add(m.group(1)!);
    }
    // ouvertures « f/1.8 », « 1:1.8 », « f1.8 », « f3.5-5.6 »
    for (final m in RegExp(r'(?:(?<![a-z])f\s*/?\s*|(?<![\d.])1\s*:\s*)(\d+(?:[.,]\d+)?)(?:\s*-\s*(\d+(?:[.,]\d+)?))?').allMatches(low)) {
      for (final g in [m.group(1), m.group(2)]) {
        if (g != null) words.add(_num(g.replaceAll(',', '.')));
      }
    }
  }

  bool has(String w) => words.contains(w);
}
