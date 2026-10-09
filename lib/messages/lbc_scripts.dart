import 'dart:convert';

/// Scripts exécutés dans la page Leboncoin pour envoyer un message.
/// Les boutons sont trouvés PAR LEUR TEXTE (pas de sélecteurs fragiles), avec
/// une liste noire : jamais d'offre, de réservation, d'achat ni de paiement.

const _helpers = r'''
const norm = s => (s || '').toString().toLowerCase().normalize('NFD').replace(/[̀-ͯ]/g, '').replace(/\s+/g, ' ').trim();
const visible = el => { if (!el) return false; const r = el.getBoundingClientRect(); const st = getComputedStyle(el);
  return r.width > 0 && r.height > 0 && st.visibility !== 'hidden' && st.display !== 'none'; };
// liste noire : boutons de paiement, d'engagement ou hors sujet
const BLACK = ['offre', 'reserv', 'achet', 'acheter', 'payer', 'paiement', 'commander', 'livraison', 'panier',
  'signaler', 'partager', 'favori', 'appeler', 'numero', 'telephone', 'voir le numero', 'messages'];
const blacklisted = t => BLACK.some(b => t.includes(b));
const inChrome = el => !!el.closest('nav, header, footer, [role=navigation]');
const clickables = () => Array.from(document.querySelectorAll('button, a, [role=button], input[type=submit]'))
  .filter(el => visible(el) && !inChrome(el));
const label = el => norm(el.innerText || el.value || el.getAttribute('aria-label') || el.getAttribute('title'));
// Vrai blocage seulement : le script DataDome est présent sur TOUTES les pages
// Leboncoin, on cherche donc la fenêtre de vérification elle-même (iframe ou page).
const blocked = () => {
  const frames = Array.from(document.querySelectorAll('iframe')).filter(f =>
    /captcha-delivery\.com|geo\.captcha|interstitial|\/captcha/i.test(f.src || '') && visible(f));
  if (frames.length) return true;
  if (/captcha-delivery\.com/i.test(location.href)) return true;
  const txt = norm(document.body ? document.body.innerText : '');
  return !document.getElementById('__NEXT_DATA__') && txt.length < 600 &&
    /verification|robot|captcha|acces (temporairement )?(bloque|restreint)/.test(txt);
};
const loginPage = () => /connexion|login|auth\.|\/auth|se connecter/.test(norm(location.href)) ||
  Array.from(document.querySelectorAll('input[type=password]')).some(visible);
const textarea = () => Array.from(document.querySelectorAll('textarea, [contenteditable=true]')).find(visible);
''';

/// État de la page : vérification anti-robot, connexion, zone de texte, boutons.
const pageStateScript = '''
(() => { $_helpers
  const ta = textarea();
  return JSON.stringify({
    url: location.href, ready: document.readyState === 'complete', blocked: blocked(), login: loginPage(),
    hasTextarea: !!ta, textareaValue: ta ? (ta.value || ta.innerText || '') : '',
    buttons: clickables().map(label).filter(t => t && t.length < 40).slice(0, 40),
    snippet: (document.body ? document.body.innerText : '').replace(/\\s+/g, ' ').slice(0, 600),
  });
})()
''';

/// Clique le bouton de contact (« Envoyer un message », « Contacter », « Message »).
const clickContactScript = '''
(() => { $_helpers
  const prefs = ['envoyer un message', 'contacter le vendeur', 'contacter', 'ecrire au vendeur', 'message'];
  const els = clickables().map(el => ({el, t: label(el)})).filter(x => x.t && !blacklisted(x.t));
  for (const p of prefs) {
    const hit = els.find(x => p === 'message' ? x.t === 'message' || x.t.startsWith('message ') : x.t.includes(p));
    if (hit) { hit.el.scrollIntoView({block: 'center'}); hit.el.click(); return JSON.stringify({ok: true, text: hit.t}); }
  }
  return JSON.stringify({ok: false, buttons: els.map(x => x.t).slice(0, 30)});
})()
''';

/// Écrit [text] dans la zone de message (setter natif + événements : compatible React).
String fillScript(String text) => '''
(() => { $_helpers
  const ta = textarea();
  if (!ta) return JSON.stringify({ok: false, error: 'zone de texte introuvable'});
  const text = ${jsonEncode(text)};
  ta.focus();
  if (ta.tagName === 'TEXTAREA') {
    const setter = Object.getOwnPropertyDescriptor(HTMLTextAreaElement.prototype, 'value').set;
    setter.call(ta, text);
  } else { ta.innerText = text; }
  ta.dispatchEvent(new Event('input', {bubbles: true}));
  ta.dispatchEvent(new Event('change', {bubbles: true}));
  const v = ta.value || ta.innerText || '';
  return JSON.stringify({ok: v.trim() === text.trim(), value: v.slice(0, 80)});
})()
''';

/// Clique « Envoyer » (jamais un bouton de la liste noire, jamais désactivé).
const clickSendScript = '''
(() => { $_helpers
  const els = clickables().map(el => ({el, t: label(el)}))
    .filter(x => x.t && !blacklisted(x.t) && !x.el.disabled && x.el.getAttribute('aria-disabled') !== 'true');
  const hit = els.find(x => x.t === 'envoyer') || els.find(x => x.t.startsWith('envoyer') && !x.t.includes('offre'));
  if (!hit) return JSON.stringify({ok: false, buttons: els.map(x => x.t).slice(0, 30)});
  hit.el.click();
  return JSON.stringify({ok: true, text: hit.t});
})()
''';

/// Le message apparaît-il dans la conversation (zone de texte vidée) ?
String verifySentScript(String text) => '''
(() => { $_helpers
  const probe = norm(${jsonEncode(text)}).slice(0, 40);
  const ta = textarea();
  const taValue = ta ? norm(ta.value || ta.innerText) : '';
  const body = norm(document.body ? document.body.innerText : '');
  const shown = body.includes(probe) && !taValue.includes(probe);
  // « message envoyé » (mot entier : pas « message envoyer » d'un bouton voisin)
  const confirm = /message (a ete |bien )?envoye(?![a-z])|votre message a bien ete envoye(?![a-z])/.test(body);
  return JSON.stringify({ok: shown || confirm, blocked: blocked(), login: loginPage()});
})()
''';

/// Identifiant du vendeur (données Next.js de l'annonce), pour « 1 contact / vendeur / 24 h ».
const sellerIdScript = r'''
(() => {
  try {
    const d = JSON.parse(document.getElementById('__NEXT_DATA__').textContent);
    const seen = new Set();
    const find = (o, k) => { if (!o || typeof o !== 'object' || seen.has(o)) return null; seen.add(o);
      if (o.owner && (o.owner.user_id || o.owner.store_id)) return String(o.owner.user_id || o.owner.store_id);
      for (const x in o) { const r = find(o[x], k + 1); if (r) return r; } return null; };
    return JSON.stringify({seller: find(d, 0) || ''});
  } catch (e) { return JSON.stringify({seller: ''}); }
})()
''';
