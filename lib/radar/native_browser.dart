import 'dart:convert';

import 'package:flutter/services.dart';

import '../services/leboncoin_reader.dart';
import '../services/mpb_service.dart';

/// WebView Android sans affichage (HeadlessBrowser.kt), un « onglet » par usage.
/// Elle partage les cookies de la WebView visible de l'appli.
class NativeBrowser {
  static const _ch = MethodChannel('mpb_check/browser');
  final String tab;
  NativeBrowser(this.tab);

  Future<({bool ok, String? error})> load(String url, {int timeoutMs = 30000}) async {
    final r = Map<String, dynamic>.from(
        await _ch.invokeMethod('load', {'tab': tab, 'url': url, 'timeoutMs': timeoutMs}) as Map);
    return (ok: r['ok'] == true, error: r['error'] as String?);
  }

  /// Exécute [js] (qui rend une chaîne JSON) et décode le résultat.
  Future<Map<String, dynamic>?> evalJson(String js) async {
    final raw = await _ch.invokeMethod('eval', {'tab': tab, 'js': js});
    if (raw == null || raw == 'null') return null;
    try {
      return decodeJsResult(raw as Object);
    } catch (_) {
      return null;
    }
  }

  Future<({int status, String body})> fetch(Uri uri, Map<String, String> headers) async {
    final raw = await _ch.invokeMethod('fetch', {'tab': tab, 'url': uri.toString(), 'headers': jsonEncode(headers)});
    final j = jsonDecode(raw as String) as Map<String, dynamic>;
    return (status: (j['status'] as num).toInt(), body: (j['body'] ?? '').toString());
  }

  Future<void> dispose() => _ch.invokeMethod('dispose', {'tab': tab});
}

/// Requêtes MPB depuis une page mpb.com ouverte dans une WebView sans affichage
/// (équivalent de MpbWebTransport pour le radar en arrière-plan).
class NativeMpbFetch {
  final _b = NativeBrowser('mpb');
  bool _loaded = false;

  Future<void> _home() async {
    await _b.load('https://www.mpb.com/fr-fr/', timeoutMs: 30000);
    _loaded = true;
  }

  Future<({int status, String body})> call(Uri uri, Map<String, String> headers) async {
    if (!_loaded) await _home();
    var r = await _b.fetch(uri, headers);
    if (!_isJson(r.body)) {
      // page de vérification MPB : on recharge une fois (souvent passée seule)
      await _home();
      await Future.delayed(const Duration(seconds: 3));
      r = await _b.fetch(uri, headers);
    }
    return r;
  }

  MpbService service() => MpbService(null, call);

  static bool _isJson(String b) {
    final t = b.trimLeft();
    return t.startsWith('{') || t.startsWith('[');
  }
}

/// Annonce telle qu'elle apparaît dans une page de recherche Leboncoin.
class SearchAd {
  final String listId;
  final String subject;
  final double? price;
  final DateTime? date;
  final String categoryId;
  final String url;
  final Map<String, String> attributes;
  final bool boosted;

  SearchAd.fromJson(Map<String, dynamic> j)
      : listId = '${j['list_id']}',
        subject = (j['subject'] ?? '').toString(),
        price = (j['price'] as num?)?.toDouble(),
        date = DateTime.tryParse((j['date'] ?? '').toString()),
        categoryId = '${j['category_id'] ?? ''}',
        url = (j['url'] ?? '').toString(),
        attributes = Map<String, dynamic>.from((j['attributes'] as Map?) ?? {})
            .map((k, v) => MapEntry(k, v.toString())),
        boosted = j['boosted'] == true;

  String get attributesText => attributes.entries.map((e) => '${e.key} : ${e.value}').join('\n');
}

/// Lit les annonces d'une page de recherche (données Next.js, validé le 09/10/2026).
/// Le corps des annonces (body) est vide dans les résultats de recherche.
const searchExtractionScript = r'''
(() => {
  const out = {ok: false, blocked: false, ads: []};
  try {
    const nd = document.getElementById('__NEXT_DATA__');
    if (nd) {
      const d = JSON.parse(nd.textContent);
      const ads = (((d.props || {}).pageProps || {}).searchData || {}).ads;
      if (Array.isArray(ads)) {
        out.ok = true;
        out.ads = ads.map(a => {
          const attrs = {};
          (a.attributes || []).forEach(x => {
            if (x && x.key_label && (x.value_label || x.value)) attrs[x.key_label] = String(x.value_label || x.value);
          });
          return {
            list_id: a.list_id,
            subject: a.subject || '',
            price: Array.isArray(a.price) ? a.price[0] : (typeof a.price === 'number' ? a.price : null),
            date: a.first_publication_date || '',
            category_id: a.category_id || '',
            url: a.url || '',
            attributes: attrs,
            boosted: !!a.is_boosted,
            images: (a.images || {}).nb_images || 0,
          };
        });
      }
    }
  } catch (e) {}
  const html = document.documentElement.innerHTML;
  out.blocked = !out.ok && /captcha-delivery|datadome|geo\.captcha/i.test(html);
  return JSON.stringify(out);
})()
''';

/// Ajoute sort=time (plus récentes d'abord) si l'URL n'a pas de tri.
String normalizeSearchUrl(String raw) {
  final m = RegExp(r'https?://\S+').firstMatch(raw.trim());
  final uri = Uri.tryParse(m?.group(0) ?? raw.trim());
  if (uri == null) return raw.trim();
  final q = Map<String, String>.from(uri.queryParameters);
  q.putIfAbsent('sort', () => 'time');
  return uri.replace(queryParameters: q).toString();
}

/// Résultat du chargement d'une page de recherche.
class SearchPage {
  final bool ok;
  final bool blocked;
  final String? error;
  final List<SearchAd> ads;
  SearchPage({required this.ok, this.blocked = false, this.error, this.ads = const []});
}

/// Charge une page de recherche et attend les données (25 s max).
Future<SearchPage> loadSearchPage(NativeBrowser b, String url) async {
  final r = await b.load(url, timeoutMs: 30000);
  if (!r.ok) return SearchPage(ok: false, error: r.error ?? 'chargement impossible');
  final deadline = DateTime.now().add(const Duration(seconds: 25));
  while (true) {
    final j = await b.evalJson(searchExtractionScript);
    if (j != null && j['ok'] == true) {
      final ads = ((j['ads'] as List?) ?? [])
          .map((e) => SearchAd.fromJson(Map<String, dynamic>.from(e as Map)))
          .where((a) => a.listId.isNotEmpty && a.listId != 'null')
          .toList();
      return SearchPage(ok: true, ads: ads);
    }
    if (j != null && j['blocked'] == true) return SearchPage(ok: false, blocked: true);
    if (DateTime.now().isAfter(deadline)) {
      return SearchPage(ok: false, error: 'données de recherche introuvables');
    }
    await Future.delayed(const Duration(milliseconds: 1500));
  }
}

/// Charge une page d'annonce et la lit avec le script validé (extractionScript).
Future<({AdData? ad, bool blocked, String? error})> loadAdPage(NativeBrowser b, String url) async {
  final r = await b.load(url, timeoutMs: 30000);
  if (!r.ok) return (ad: null, blocked: false, error: r.error ?? 'chargement impossible');
  final uri = Uri.parse(url);
  final deadline = DateTime.now().add(const Duration(seconds: 25));
  while (true) {
    final j = await b.evalJson(extractionScript);
    if (j != null) {
      final ad = adDataFromJs(uri, j);
      if (ad.isComplete) return (ad: ad, blocked: false, error: null);
      if (j['blocked'] == true) return (ad: null, blocked: true, error: null);
    }
    if (DateTime.now().isAfter(deadline)) return (ad: null, blocked: false, error: 'annonce illisible');
    await Future.delayed(const Duration(milliseconds: 1500));
  }
}
