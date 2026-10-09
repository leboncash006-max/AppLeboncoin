import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models.dart';

/// Accès aux API JSON publiques de mpb.com (repérées le 09/10/2026).
class MpbService {
  static const _host = 'www.mpb.com';
  static const _headers = {
    'Content-Language': 'fr_FR',
    'Accept': 'application/json',
  };

  final http.Client _client;
  final Map<String, List<String>> _suggestCache = {};
  final Map<String, ResaleStats?> _resaleCache = {};

  MpbService([http.Client? client]) : _client = client ?? http.Client();

  Future<dynamic> _get(String path, Map<String, dynamic> params) async {
    final uri = Uri.https(_host, path, params);
    final r = await _client
        .get(uri, headers: _headers)
        .timeout(const Duration(seconds: 15));
    if (r.statusCode != 200) {
      throw Exception('MPB a répondu ${r.statusCode}');
    }
    return jsonDecode(utf8.decode(r.bodyBytes));
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
