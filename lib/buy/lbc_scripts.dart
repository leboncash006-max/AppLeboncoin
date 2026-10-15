// Scripts exécutés dans les pages Leboncoin pour l'achat automatique.
// Les boutons sont trouvés PAR LEUR TEXTE. Aucune vérification anti-robot
// n'est jamais contournée : page de vérification ou de connexion = arrêt.

const _helpers = r'''
const norm = s => (s || '').toString().toLowerCase().normalize('NFD').replace(/[\u0300-\u036f]/g, '').replace(/\s+/g, ' ').trim();
const visible = el => { if (!el) return false; const r = el.getBoundingClientRect(); const st = getComputedStyle(el);
  return r.width > 0 && r.height > 0 && st.visibility !== 'hidden' && st.display !== 'none'; };
const inChrome = el => !!el.closest('nav, header, footer, [role=navigation]');
const clickables = () => Array.from(document.querySelectorAll('button, a, [role=button], input[type=submit], label, [role=radio]'))
  .filter(el => visible(el) && !inChrome(el));
const label = el => norm(el.innerText || el.value || el.getAttribute('aria-label') || el.getAttribute('title'));
const enabled = el => !el.disabled && el.getAttribute('aria-disabled') !== 'true';
// Vrai blocage seulement : le script DataDome est présent sur TOUTES les pages,
// on cherche donc la fenêtre de vérification elle-même (iframe ou page).
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
const euros = s => { const m = (s || '').replace(/\u00a0|\u202f/g, ' ').match(/(\d[\d ]*(?:[.,]\d{1,2})?)\s*€/); return m ? parseFloat(m[1].replace(/ /g, '').replace(',', '.')) : null; };
const bodyText = () => (document.body ? document.body.innerText : '');
// bouton FINAL de paiement : un vrai bouton (pas une option à cocher), texte court et sans ambiguïté
const payButtons = () => Array.from(document.querySelectorAll('button, input[type=submit], [role=button]'))
  .filter(el => visible(el) && !inChrome(el) && !el.closest('label') && !el.querySelector('input'))
  .map(el => ({el, t: label(el)}))
  .filter(x => !/solde|carte|avec|porte-monnaie|methode|moyen/.test(x.t) &&
    /^(payer( maintenant)?( \d[\d ,.]*\s?€?)?|confirmer (le paiement|et payer|l'achat|mon achat)|valider (le paiement|et payer|l'achat))\$/.test(x.t));
''';

/// État de la page : vérification anti-robot, connexion, boutons.
const pageStateScript = '''
(() => { $_helpers
  return JSON.stringify({
    url: location.href, ready: document.readyState === 'complete', blocked: blocked(), login: loginPage(),
    buttons: clickables().map(label).filter(t => t && t.length < 40).slice(0, 40),
    snippet: bodyText().replace(/\\s+/g, ' ').slice(0, 600),
  });
})()
''';

/// Clique « Acheter » sur la page de l'annonce (jamais « Faire une offre »).
const clickBuyScript = '''
(() => { $_helpers
  const els = clickables().filter(enabled).map(el => ({el, t: label(el)}))
    .filter(x => x.t && !x.t.includes('offre') && !x.t.includes('message'));
  const hit = els.find(x => x.t === 'acheter') || els.find(x => /^acheter( maintenant| cet article)?\$/.test(x.t));
  if (!hit) return JSON.stringify({ok: false, buttons: els.map(x => x.t).slice(0, 30)});
  hit.el.scrollIntoView({block: 'center'}); hit.el.click();
  return JSON.stringify({ok: true, text: hit.t});
})()
''';

/// Page de paiement : moyen « solde », total, solde disponible, bouton de paiement.
const checkoutStateScript = '''
(() => { $_helpers
  const txt = bodyText();
  const lines = txt.split('\\n').map(s => s.trim()).filter(Boolean);
  // total : la ligne « Total » (ou « Montant à payer ») et le montant qui suit
  let total = null;
  for (let i = 0; i < lines.length; i++) {
    const l = norm(lines[i]);
    if (/^(total|montant (total|a payer)|a payer)/.test(l)) {
      total = euros(lines[i]) ?? euros(lines[i + 1] || '');
      if (total != null) break;
    }
  }
  // solde disponible (porte-monnaie)
  let balance = null, hasBalance = false;
  for (let i = 0; i < lines.length; i++) {
    const l = norm(lines[i]);
    if (/solde|porte-monnaie|portefeuille|cagnotte/.test(l)) {
      hasBalance = true;
      balance = balance ?? euros(lines[i]) ?? euros(lines[i + 1] || '');
    }
  }
  const pay = payButtons();
  return JSON.stringify({
    url: location.href, ready: document.readyState === 'complete', blocked: blocked(), login: loginPage(),
    total, balance, hasBalance,
    payButton: pay.length ? pay[0].t : '', payEnabled: pay.length ? enabled(pay[0].el) : false,
    card: /numero de (la )?carte|cryptogramme|date d'expiration/.test(norm(txt)),
    buttons: clickables().map(label).filter(t => t && t.length < 40).slice(0, 40),
    snippet: txt.replace(/\\s+/g, ' ').slice(0, 800),
  });
})()
''';

/// Choisit le paiement avec le solde Leboncoin (porte-monnaie).
const selectBalanceScript = '''
(() => { $_helpers
  const els = clickables().map(el => ({el, t: label(el)})).filter(x => /solde|porte-monnaie|portefeuille|cagnotte/.test(x.t));
  if (!els.length) return JSON.stringify({ok: false});
  els.sort((a, b) => a.t.length - b.t.length);
  const el = els[0].el;
  const input = el.querySelector('input[type=radio], input[type=checkbox]') ||
    (el.htmlFor ? document.getElementById(el.htmlFor) : null);
  if (input && input.checked) return JSON.stringify({ok: true, already: true});
  el.click();
  return JSON.stringify({ok: true, text: els[0].t});
})()
''';

/// Clique le bouton final de paiement (seulement s'il est actif).
const clickPayScript = '''
(() => { $_helpers
  const pay = payButtons().filter(x => enabled(x.el));
  if (pay.length !== 1) return JSON.stringify({ok: false, count: pay.length});
  pay[0].el.click();
  return JSON.stringify({ok: true, text: pay[0].t});
})()
''';

/// Paiement confirmé par la page ?
const purchaseConfirmedScript = '''
(() => { $_helpers
  const t = norm(bodyText());
  const ok = /paiement (a ete |bien )?(accepte|confirme|valide|effectue)|merci pour (votre|ton) achat|(commande|achat) (confirme|valide|enregistre)|votre achat est confirme/.test(t);
  const secure = /3d ?secure|authentification forte|validez (le paiement|l'operation) (dans|sur|depuis) (votre|l')|code (recu|envoye) par sms/.test(t);
  return JSON.stringify({ok, secure, blocked: blocked(), login: loginPage(), url: location.href});
})()
''';
