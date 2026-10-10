import 'v3_models.dart';

/// Lit dans la page d'annonce (__NEXT_DATA__) les photos, le lieu et la
/// livraison. Script séparé : le script d'extraction validé n'est pas modifié.
/// Champs Leboncoin : ad.images.{urls_large, urls, thumb_url},
/// ad.location.{city, city_label, zipcode, lat, lng}, attributs « shippable »
/// et « shipping_type ». Plusieurs variantes sont essayées par prudence.
const adExtrasScript = r'''
(() => {
  const out = {images: [], city: '', zipcode: '', lat: null, lng: null, shippable: false, shippingType: '', keys: []};
  try {
    const nd = document.getElementById('__NEXT_DATA__');
    if (!nd) return JSON.stringify(out);
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
    if (!ad) return JSON.stringify(out);
    out.keys = Object.keys(ad).slice(0, 60);
    const im = ad.images || {};
    let urls = (Array.isArray(im.urls_large) && im.urls_large.length) ? im.urls_large
      : (Array.isArray(im.urls) && im.urls.length) ? im.urls
      : (im.thumb_url ? [im.thumb_url] : (im.small_url ? [im.small_url] : []));
    out.images = urls.filter(u => typeof u === 'string' && u.startsWith('http')).slice(0, 6);
    const loc = ad.location || {};
    out.city = String(loc.city || loc.city_label || '');
    out.zipcode = String(loc.zipcode || '');
    out.lat = typeof loc.lat === 'number' ? loc.lat : (parseFloat(loc.lat) || null);
    out.lng = typeof loc.lng === 'number' ? loc.lng : (parseFloat(loc.lng) || null);
    (ad.attributes || []).forEach(a => {
      if (!a || !a.key) return;
      if (a.key === 'shippable') out.shippable = String(a.value) === 'true';
      if (a.key === 'shipping_type') out.shippingType = String(a.value || '');
    });
    if (ad.shippable === true || (ad.shipping && ad.shipping.enabled)) out.shippable = true;
    if (out.shippingType && out.shippingType !== 'face_to_face') out.shippable = out.shippable || /ship|colis|relay|mondial|poste|courrier/i.test(out.shippingType);
  } catch (e) {}
  return JSON.stringify(out);
})()
''';

AdExtras adExtrasFromJs(Map<String, dynamic> j) => AdExtras.fromJson(j);
