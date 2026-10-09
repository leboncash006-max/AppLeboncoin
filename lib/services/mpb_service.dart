import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../models.dart';

/// États acceptés par l'API de reprise MPB, du meilleur au moins bon.
const mpbConditions = ['like-new', 'excellent', 'good', 'well-used', 'heavily-used'];

const mpbConditionLabels = {
  'like-new': 'Comme neuf',
  'excellent': 'Excellent',
  'good': 'Bon',
  'well-used': 'Usé',
  'heavily-used': 'Très usé',
};

/// Accès aux API JSON publiques de mpb.com (repérées le 09/10/2026).
class MpbService {
  static const _host = 'www.mpb.com';
  static const _headers = {
    'Content-Language': 'fr_FR',
    'Accept': 'application/json',
    ..._browser,
  };

  /// En-têtes de navigateur : certains filtres anti-robot renvoient une page
  /// HTML au client HTTP de Dart (User-Agent « Dart/… »).
  static const _browser = {
    'User-Agent': 'Mozilla/5.0 (Linux; Android 14; SM-S911B) AppleWebKit/537.36 '
        '(KHTML, like Gecko) Chrome/129.0.0.0 Mobile Safari/537.36',
    'Accept-Language': 'fr-FR,fr;q=0.9',
  };

  final http.Client _client;
  final Map<String, List<String>> _suggestCache = {};
  final Map<String, ResaleStats?> _resaleCache = {};

  MpbService([http.Client? client]) : _client = client ?? http.Client();

  Future<dynamic> _get(String path, Map<String, dynamic> params) =>
      _getJson(Uri.https(_host, path, params), _headers);

  /// GET qui exige du JSON. Si MPB renvoie une page HTML (anti-robot, limite de
  /// requêtes…), on réessaie une fois puis on lève une erreur lisible.
  Future<dynamic> _getJson(Uri uri, Map<String, String> headers) async {
    for (var attempt = 0;; attempt++) {
      final r = await _client.get(uri, headers: headers).timeout(const Duration(seconds: 15));
      final body = utf8.decode(r.bodyBytes, allowMalformed: true);
      final isJson = body.trimLeft().startsWith('{') || body.trimLeft().startsWith('[');
      if (r.statusCode == 200 && isJson) return jsonDecode(body);
      if (attempt == 0 && (!isJson || r.statusCode == 429 || r.statusCode >= 500)) {
        await Future.delayed(const Duration(milliseconds: 1500));
        continue;
      }
      if (!isJson) {
        throw Exception('MPB a renvoyé une page web au lieu des données '
            '(HTTP ${r.statusCode}) : protection anti-robot ou trop de requêtes. '
            'Réessaie dans quelques minutes.');
      }
      throw Exception('MPB a répondu ${r.statusCode}');
    }
  }

  /// Noms exacts du catalogue MPB proches de [query].
  Future<List<String>> suggest(String query, {int count = 10}) async {
    final q = query.trim();
    if (q.isEmpty) return [];
    final key = q.toLowerCase();
    if (_suggestCache.containsKey(key)) return _suggestCache[key]!;
    final data = await _get('/search-service/product/suggest/model/fuzzy/',
        {'query': q, 'count': '$count'});
    final list = ((data['suggestions'] as List?) ?? [])
        .map((s) => (s['term'] ?? '').toString())
        .where((s) => s.isNotEmpty)
        .toList();
    _suggestCache[key] = list;
    return list;
  }

  /// Médiane des prix de revente MPB en état Bon pour [modelName].
  Future<ResaleStats?> resale(String modelName) async {
    if (_resaleCache.containsKey(modelName)) return _resaleCache[modelName];
    final data = await _get('/search-service/product/query/', {
      'filter_query[model_name]': '"$modelName"',
      'filter_query[model_market]': 'EU',
      'filter_query[object_type]': 'product',
      'filter_query[model_available]': 'true',
      'filter_query[model_is_published_out]': 'true',
      'field_list': [
        'model_name',
        'product_price',
        'product_condition',
        'model_url_segment',
      ],
      'rows': '200',
    });
    final good = <double>[];
    final all = <double>[];
    String? segment;
    for (final r in (data['results'] as List? ?? [])) {
      try {
        if (_first(r, 'model_name') != modelName) continue;
        final price = int.parse(_first(r, 'product_price')!) / 100;
        all.add(price);
        if (_first(r, 'product_condition') == 'GOOD') good.add(price);
        segment ??= _first(r, 'model_url_segment');
      } catch (_) {
        continue;
      }
    }
    final url = segment == null
        ? null
        : 'https://www.mpb.com/fr-fr/produit/$segment';
    ResaleStats? stats;
    if (good.isNotEmpty) {
      stats = ResaleStats(median(good), good.length, 'Bon', url);
    } else if (all.isNotEmpty) {
      stats = ResaleStats(median(all) * 0.9, all.length, 'tous états × 0,9', url);
    }
    _resaleCache[modelName] = stats;
    return stats;
  }

  // ------------------------------------------------- prix de reprise réel

  final Map<String, int?> _idCache = {};
  static const _priceTtl = Duration(hours: 24);

  /// Identifiant MPB du modèle (marche aussi hors stock).
  Future<int?> modelId(String modelName) async {
    if (_idCache.containsKey(modelName)) return _idCache[modelName];
    final data = await _get('/search-service/product/query/', {
      'filter_query[model_name]': '"$modelName"',
      'filter_query[object_type]': 'model',
      'filter_query[model_market]': 'EU',
      'field_list': ['model_id', 'model_name'],
      'rows': '1',
    });
    final rows = (data['results'] as List?) ?? [];
    final id = rows.isEmpty ? null : int.tryParse(_first(rows.first, 'model_id') ?? '');
    _idCache[modelName] = id;
    return id;
  }

  /// Prix de reprise MPB pour [modelId] et un état de [mpbConditions], en euros.
  /// Cache local de 24 h par id + état.
  Future<double> purchasePrice(int modelId, String condition) async {
    final key = 'mpb_pp_${modelId}_$condition';
    final prefs = await SharedPreferences.getInstance();
    final cached = prefs.getString(key);
    if (cached != null) {
      try {
        final j = jsonDecode(cached) as Map<String, dynamic>;
        final t = DateTime.fromMillisecondsSinceEpoch((j['t'] as num).toInt());
        if (DateTime.now().difference(t) < _priceTtl) return (j['v'] as num).toDouble();
      } catch (_) {}
    }
    final uri = Uri.https(_host, '/public-api/v1/models/purchase-price/$modelId/$condition/');
    final j = await _getJson(uri, {
      'X-Market': 'fr', // obligatoire, sinon prix en GBP
      'Accept': 'application/json',
      ..._browser,
    }) as Map<String, dynamic>;
    if (j['currency'] != 'EUR') throw Exception('Reprise MPB : devise ${j['currency']}');
    final v = (j['purchase_value'] as num).toDouble();
    await prefs.setString(
        key, jsonEncode({'v': v, 't': DateTime.now().millisecondsSinceEpoch}));
    return v;
  }

  /// Les 5 prix de reprise (appels en séquence, ~300 ms d'écart hors cache).
  /// Les états en échec sont absents de la table.
  Future<Map<String, double>> purchasePrices(int modelId) async {
    final out = <String, double>{};
    Object? lastError;
    for (final c in mpbConditions) {
      final sw = Stopwatch()..start();
      try {
        out[c] = await purchasePrice(modelId, c);
      } catch (e) {
        lastError = e;
      }
      // pas de pause après un prix servi par le cache
      if (sw.elapsedMilliseconds > 50 && c != mpbConditions.last) {
        await Future.delayed(const Duration(milliseconds: 300));
      }
    }
    if (out.isEmpty && lastError != null) throw lastError;
    return out;
  }

  static String? _first(dynamic row, String field) {
    final v = row[field]?['values'];
    if (v is List && v.isNotEmpty) return v.first.toString();
    return null;
  }
}

double median(List<double> xs) {
  final s = [...xs]..sort();
  final n = s.length;
  return n.isOdd ? s[n ~/ 2] : (s[n ~/ 2 - 1] + s[n ~/ 2]) / 2;
}
