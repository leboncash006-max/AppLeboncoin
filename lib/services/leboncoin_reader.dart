import 'dart:convert';

/// Données d'une annonce lues dans la page Leboncoin.
class AdData {
  final String url;
  final String title;
  final String description;
  final double? price;
  final Map<String, String> attributes; // ex. « État » : « Très bon état »
  final String source;

  AdData({
    required this.url,
    required this.title,
    required this.description,
    required this.price,
    required this.attributes,
    required this.source,
  });

  bool get isComplete => title.isNotEmpty && (description.isNotEmpty || price != null);

  String get attributesText =>
      attributes.entries.map((e) => '${e.key} : ${e.value}').join('\n');
}

/// Extrait la première URL Leboncoin d'un texte collé (le partage de l'appli
/// Leboncoin ajoute souvent une phrase avant le lien).
Uri? extractLeboncoinUrl(String text) {
  final m = RegExp(r'https?://(?:www\.)?leboncoin\.fr/\S+').firstMatch(text) ??
      RegExp(r'(?:www\.)?leboncoin\.fr/\S+').firstMatch(text);
  if (m == null) return null;
  var s = m.group(0)!.replaceAll(RegExp(r'[)\]>,.;]+$'), '');
  if (!s.startsWith('http')) s = 'https://$s';
  return Uri.tryParse(s);
}

/// Script exécuté dans la page : lit d'abord les données Next.js de la page
/// (__NEXT_DATA__), puis les données structurées JSON-LD, puis le texte visible.
const extractionScript = r'''
(() => {
  const out = {title: '', description: '', price: null, attributes: {}, source: '', blocked: false};
  const num = s => { if (s == null) return null; const m = String(s).replace(/[\s  ]/g, '').match(/(\d+(?:[.,]\d+)?)/); return m ? parseFloat(m[1].replace(',', '.')) : null; };
  try {
    const nd = document.getElementById('__NEXT_DATA__');
    if (nd) {
      const data = JSON.parse(nd.textContent);
      const seen = new Set();
      const find = (o, d) => {
        if (!o || typeof o !== 'object' || d > 9 || seen.has(o)) return null;
        seen.add(o);
        if (typeof o.subject === 'string' && typeof o.body === 'string') return o;
        for (const k in o) { const r = find(o[k], d + 1); if (r) return r; }
        return null;
      };
      const ad = find(data, 0);
      if (ad) {
        out.title = ad.subject; out.description = ad.body;
        const p = Array.isArray(ad.price) ? ad.price[0] : ad.price;
        out.price = typeof p === 'number' ? p : (ad.price_cents ? ad.price_cents / 100 : num(p));
        // seuls les attributs avec un libellé lisible (État, Marque, Type…) ; les autres sont techniques
        (ad.attributes || []).forEach(a => {
          if (a && a.key_label && (a.value_label || a.value)) out.attributes[a.key_label] = String(a.value_label || a.value);
        });
        out.source = 'next';
      }
    }
  } catch (e) {}
  if (!out.title) {
    try {
      document.querySelectorAll('script[type="application/ld+json"]').forEach(s => {
        if (out.title) return;
        let j = JSON.parse(s.textContent); if (Array.isArray(j)) j = j.find(x => x && x.name) || j[0];
        if (j && j.name) {
          out.title = j.name; out.description = j.description || '';
          const of = Array.isArray(j.offers) ? j.offers[0] : j.offers;
          out.price = of ? num(of.price) : null;
          if (j.itemCondition) out.attributes['État'] = String(j.itemCondition).split('/').pop();
          out.source = 'jsonld';
        }
      });
    } catch (e) {}
  }
  if (!out.title) {
    const q = s => document.querySelector(s);
    const txt = el => (el.innerText || el.textContent || '').trim();
    const h1 = q('h1');
    if (h1) {
      out.title = txt(h1);
      const d = q('[data-qa-id="adview_description_container"]');
      out.description = d ? txt(d) : '';
      const p = q('[data-qa-id="adview_price"]');
      out.price = p ? num(txt(p)) : null;
      const c = q('[data-qa-id="criteria_container"]');
      if (c) out.attributes['Critères'] = txt(c).replace(/\n+/g, ' | ');
      out.source = 'dom';
    }
  }
  const html = document.documentElement.innerHTML;
  out.blocked = !out.title && (/captcha-delivery|datadome|geo\.captcha/i.test(html));
  return JSON.stringify(out);
})()
''';

/// Décode le résultat de runJavaScriptReturningResult (souvent une chaîne JSON
/// elle-même encodée en JSON sur Android).
Map<String, dynamic> decodeJsResult(Object raw) {
  var s = raw is String ? raw : raw.toString();
  if (s.startsWith('"')) s = jsonDecode(s) as String;
  return jsonDecode(s) as Map<String, dynamic>;
}

AdData adDataFromJs(Uri url, Map<String, dynamic> j) => AdData(
      url: url.toString(),
      title: (j['title'] ?? '').toString().trim(),
      description: (j['description'] ?? '').toString().trim(),
      price: (j['price'] as num?)?.toDouble(),
      attributes: Map<String, dynamic>.from(j['attributes'] ?? {})
          .map((k, v) => MapEntry(k, v.toString())),
      source: (j['source'] ?? '').toString(),
    );
