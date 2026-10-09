import 'dart:math';

import '../services/gemini_service.dart';
import '../services/history.dart';
import '../services/offer.dart';
import 'message_settings.dart';

/// Rédige les messages aux vendeurs (Gemini flash-lite, texte différent à
/// chaque fois) et vérifie que l'identification correspond bien à l'annonce.
class MessageWriter {
  final GeminiService gemini;
  MessageWriter([GeminiService? g]) : gemini = g ?? GeminiService();

  static const _msgSchema = {
    'type': 'OBJECT',
    'properties': {
      'message': {'type': 'STRING'},
    },
    'required': ['message'],
  };

  static const _verdictSchema = {
    'type': 'OBJECT',
    'properties': {
      'verdict': {
        'type': 'STRING',
        'enum': ['oui', 'doute', 'non'],
      },
      'raison': {'type': 'STRING'},
    },
    'required': ['verdict', 'raison'],
  };

  /// Prix proposé (null = pas de proposition : prix demandé accepté).
  static double? offerFor(HistoryEntry e, double minMargin, MessageSettings s) {
    if (!s.proposePrice) return null;
    final offer = suggestedOffer(e.analysis, minMargin);
    final price = e.analysis.price ?? e.adPrice;
    if (offer == null || price == null || offer >= price) return null;
    return offer;
  }

  /// Message prêt à envoyer. Repli sur un modèle de texte si Gemini échoue.
  Future<String> write(HistoryEntry e, double minMargin, MessageSettings s) async {
    final offer = offerFor(e, minMargin, s);
    final price = e.analysis.price ?? e.adPrice;
    final prompt = '''
Écris UN message court (2 à 4 phrases) à envoyer à un particulier qui vend sur Leboncoin.
Annonce : « ${e.title} »${price == null ? '' : ', prix demandé ${price.toStringAsFixed(0)} €'}.
Objectif : savoir si c'est toujours disponible et proposer un achat rapide.
${offer == null ? 'Ne propose pas de prix (le prix demandé convient).' : 'Propose poliment ${offer.toStringAsFixed(0)} €, sans être insistant.'}
Ton : ${s.tone}. ${s.formal ? 'Vouvoie le vendeur.' : 'Tutoie le vendeur.'}
${s.instructions.trim().isEmpty ? '' : 'Consignes de l\'acheteur : ${s.instructions.trim()}'}
Règles : en français naturel, pas de lien, pas de numéro de téléphone, pas d'adresse e-mail,
ne parle ni de revente ni de MPB, pas de formule toute faite, varie la tournure.
Variante n°${Random().nextInt(100000)} : formulation différente des précédentes.''';
    try {
      final r = await gemini.generateJson(prompt, _msgSchema, temperature: 1.0);
      final text = (r['message'] ?? '').toString().trim();
      if (text.length >= 15 && !_forbidden.hasMatch(text)) return text;
    } catch (_) {}
    return _fallback(e, offer, s);
  }

  static final _forbidden = RegExp(r'https?://|www\.|@|\b0[67](?:[ .]?\d{2}){4}\b|\bmpb\b', caseSensitive: false);

  static String _fallback(HistoryEntry e, double? offer, MessageSettings s) {
    final r = Random();
    final hello = s.formal ? ['Bonjour', 'Bonjour à vous', 'Bonsoir'] : ['Salut', 'Bonjour', 'Hello'];
    final dispo = s.formal
        ? ['votre annonce « ${e.title} » est-elle toujours disponible ?', 'est-ce que « ${e.title} » est encore disponible ?']
        : ['ton annonce « ${e.title} » est toujours dispo ?', '« ${e.title} » est encore dispo ?'];
    final prop = offer == null
        ? (s.formal ? 'Je suis intéressé au prix indiqué.' : 'Je suis intéressé au prix indiqué.')
        : (s.formal
            ? 'Je vous propose ${offer.toStringAsFixed(0)} €, si cela vous convient.'
            : 'Je te propose ${offer.toStringAsFixed(0)} €, si ça te va.');
    final end = s.formal
        ? ['Je peux régler rapidement. Merci !', 'Paiement rapide possible. Bonne journée !']
        : ['Je peux payer rapidement. Merci !', 'Paiement rapide possible. Bonne journée !'];
    return '${hello[r.nextInt(hello.length)]}, ${dispo[r.nextInt(dispo.length)]} $prop ${end[r.nextInt(end.length)]}';
  }

  /// Verdict IA : les modèles identifiés correspondent-ils à l'annonce ?
  /// « oui », « doute » ou « non » (en cas d'erreur : « doute »).
  Future<({String verdict, String reason})> verify(HistoryEntry e) async {
    final items = e.analysis.items
        .where((i) => i.mpbModel != null)
        .map((i) => '- ${i.item.type} : ${i.mpbModel}')
        .join('\n');
    if (items.isEmpty) return (verdict: 'non', reason: 'Aucun modèle identifié');
    final prompt = '''
Tu vérifies une identification de matériel photo d'occasion.
Annonce Leboncoin :
Titre : ${e.title}
${e.attributesText}
Description : """
${e.description}
"""
Modèles identifiés (catalogue MPB) :
$items

Réponds « oui » seulement si CHAQUE modèle identifié est sans ambiguïté celui vendu (même
version, même monture). « doute » si une version, une monture ou la présence d'un élément est
incertaine, ou si un élément vendu manque. « non » si au moins un modèle est faux (ex. objectif
intégré d'un compact pris pour un objectif séparé, accessoire pris pour un boîtier).''';
    try {
      final r = await gemini.generateJson(prompt, _verdictSchema);
      final v = (r['verdict'] ?? 'doute').toString();
      return (verdict: ['oui', 'doute', 'non'].contains(v) ? v : 'doute', reason: (r['raison'] ?? '').toString());
    } catch (e) {
      return (verdict: 'doute', reason: 'Vérification IA impossible : $e');
    }
  }
}
