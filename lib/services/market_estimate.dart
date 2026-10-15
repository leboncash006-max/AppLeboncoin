import 'dart:convert';

import 'gemini_service.dart';

/// Estimation de prix pour les objets HORS photo (consoles, téléphones,
/// tablettes, montres…) : l'IA cherche sur le web les prix d'occasion et de
/// reprise (Back Market, Recommerce, Easy Cash…). Ce n'est jamais un prix
/// réel garanti : jamais d'achat automatique sur ces estimations.
class MarketEstimate {
  final double? resale; // revente réaliste entre particuliers
  final double? quickBuyback; // reprise immédiate par un professionnel
  final String buyer; // qui reprend (Back Market, Easy Cash…)
  final String note;
  MarketEstimate(this.resale, this.quickBuyback, this.buyer, this.note);

  /// Ce qu'on retient pour la marge : la reprise rapide, sinon 80 % de la revente.
  double? get value => quickBuyback ?? (resale == null ? null : resale! * 0.8);
}

Future<MarketEstimate?> estimateMarket(GeminiService gemini, String product, String condition, String adText) async {
  final reply = await gemini.chat(
    'Tu es expert du marché de l\'occasion en France. Tu cherches les prix réels sur le web '
        '(annonces vendues, sites de reprise comme Back Market, Recommerce, Easy Cash, Cash Converters, '
        'Rakuten). Réponds UNIQUEMENT avec un objet JSON, sans texte autour.',
    [
      (
        role: 'user',
        text: '''
Produit : $product
État annoncé : $condition
Extrait de l'annonce : ${adText.length > 800 ? adText.substring(0, 800) : adText}

Donne en euros, pour CE modèle exact et cet état :
{"revente": prix de revente réaliste entre particuliers (Leboncoin),
 "reprise": meilleure offre de reprise immédiate d'un professionnel (null si aucune),
 "repreneur": nom du site de reprise,
 "note": une phrase (capacité, version, ce qui fait varier le prix)}'''
      )
    ],
    allowDeepSeek: false, // il faut la recherche web de Gemini pour les prix
  );
  final m = RegExp(r'\{[\s\S]*\}').firstMatch(reply.text);
  if (m == null) return null;
  try {
    final j = jsonDecode(m.group(0)!) as Map<String, dynamic>;
    double? n(Object? v) => v is num ? v.toDouble() : double.tryParse('${v ?? ''}'.replaceAll(RegExp(r'[^\d.,]'), '').replaceAll(',', '.'));
    final est = MarketEstimate(n(j['revente']), n(j['reprise']), (j['repreneur'] ?? '').toString(), (j['note'] ?? '').toString());
    return est.value == null || est.value! <= 0 ? null : est;
  } catch (_) {
    return null;
  }
}
