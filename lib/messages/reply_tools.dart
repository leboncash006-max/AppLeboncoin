import 'dart:convert';

import '../radar/radar_db.dart';
import '../services/gemini_service.dart';
import '../services/history.dart';
import '../services/offer.dart';
import 'message_settings.dart';
import 'message_store.dart';

/// Mots significatifs (minuscules, sans accents, ≥ 3 lettres ou avec chiffre).
Set<String> _words(String s) {
  var t = s.toLowerCase();
  const accents = {'é': 'e', 'è': 'e', 'ê': 'e', 'à': 'a', 'â': 'a', 'î': 'i', 'ô': 'o', 'û': 'u', 'ç': 'c'};
  accents.forEach((a, b) => t = t.replaceAll(a, b));
  const stop = {'les', 'des', 'une', 'pour', 'avec', 'sur', 'dans', 'vous', 'nouveau', 'message', 'leboncoin'};
  return t
      .split(RegExp(r'[^a-z0-9]+'))
      .where((w) => (w.length >= 3 || w.contains(RegExp(r'\d'))) && !stop.contains(w))
      .toSet();
}

/// Rattache une notification de message Leboncoin à une annonce contactée :
/// par les mots du titre de l'annonce présents dans la notification ; sinon,
/// s'il n'y a qu'une seule annonce contactée dans les 7 derniers jours, elle.
SellerMessage? matchReply(String notifText, List<SellerMessage> candidates, {DateTime? now}) {
  if (candidates.isEmpty) return null;
  final n = _words(notifText);
  SellerMessage? best;
  var bestScore = 0;
  for (final m in candidates) {
    final score = _words(m.title).intersection(n).length;
    if (score > bestScore) {
      best = m;
      bestScore = score;
    }
  }
  if (best != null && bestScore >= 2) return best;
  final t = now ?? DateTime.now();
  final recent = candidates.where((m) => m.sentAt != null && t.difference(m.sentAt!).inDays < 7).toList();
  return recent.length == 1 ? recent.first : null;
}

/// Analyse liée à un message (radar ou historique).
Future<HistoryEntry?> entryForMessage(SellerMessage m) async {
  final a = await RadarDb.analysis(m.listId);
  if (a != null) return a.entry;
  final h = await HistoryStore.load();
  for (final e in h) {
    if (e.url == m.url || e.id == m.listId) return e;
  }
  return null;
}

/// Ouvre la conversation dont le texte contient le titre de l'annonce
/// (page « Messages » de Leboncoin). Rien n'est envoyé.
String openConversationScript(String title) => '''
(() => {
  const norm = s => (s || '').toString().toLowerCase().normalize('NFD').replace(/[\\u0300-\\u036f]/g, '').replace(/\\s+/g, ' ').trim();
  const want = norm(${jsonEncode(title)}).slice(0, 24);
  const items = Array.from(document.querySelectorAll('a, li, [role=listitem], [role=button]'))
    .filter(el => el.getBoundingClientRect().height > 0 && norm(el.innerText).includes(want));
  items.sort((a, b) => a.innerText.length - b.innerText.length);
  if (!items.length) return JSON.stringify({ok: false});
  items[0].click();
  return JSON.stringify({ok: true});
})()
''';

/// Texte de la conversation affichée (les derniers messages).
const readConversationScript = r'''
(() => {
  const main = document.querySelector('main') || document.body;
  const t = (main.innerText || '').replace(/\n{2,}/g, '\n').trim();
  return JSON.stringify({text: t.slice(-2500)});
})()
''';

/// Réponses proposées au vendeur (je choisis, je peux modifier, j'envoie moi-même).
class ReplySuggestion {
  final String kind; // accepter | contre_offre | question
  final String text;
  ReplySuggestion(this.kind, this.text);

  String get label => switch (kind) {
        'accepter' => 'Accepter',
        'contre_offre' => 'Contre-offre',
        _ => 'Question',
      };
}

Future<List<ReplySuggestion>> suggestReplies({
  required GeminiService gemini,
  required String conversation,
  required SellerMessage msg,
  required HistoryEntry? entry,
  required double minMargin,
  required MessageSettings s,
}) async {
  final a = entry?.analysis;
  final max = a == null ? null : maxBuyPrice(a, minMargin);
  final price = a?.price ?? entry?.adPrice;
  final prompt = '''
Je suis acheteur sur Leboncoin. Annonce : « ${msg.title} »${price == null ? '' : ' (prix demandé ${price.toStringAsFixed(0)} €)'}.
${msg.offer == null ? '' : 'Je lui avais proposé ${msg.offer!.toStringAsFixed(0)} €.'}
${max == null ? '' : 'Mon prix MAXIMUM (marge nette comprise) est ${max.toStringAsFixed(0)} € : ne propose jamais plus.'}
Voici la fin de la conversation (le dernier message est celui du vendeur) :
"""
${conversation.length > 2500 ? conversation.substring(conversation.length - 2500) : conversation}
"""
Propose 3 réponses courtes (1 à 3 phrases), en français naturel :
1. type « accepter » : j'accepte sa proposition SEULEMENT si elle est au plus à ${max?.toStringAsFixed(0) ?? 'mon maximum'} €,
   sinon une acceptation conditionnelle à mon maximum ;
2. type « contre_offre » : une contre-offre précise entre ma dernière offre et mon maximum ;
3. type « question » : une question utile (état, défauts, accessoires, remise en main propre ou envoi).
Ton : ${s.tone}. ${s.formal ? 'Vouvoie le vendeur.' : 'Tutoie le vendeur.'}
${s.instructions.trim().isEmpty ? '' : 'Consignes : ${s.instructions.trim()}'}
Pas de lien, pas de numéro de téléphone, pas d'e-mail, ne parle pas de MPB ni de revente.''';
  const schema = {
    'type': 'OBJECT',
    'properties': {
      'reponses': {
        'type': 'ARRAY',
        'items': {
          'type': 'OBJECT',
          'properties': {
            'type': {
              'type': 'STRING',
              'enum': ['accepter', 'contre_offre', 'question'],
            },
            'texte': {'type': 'STRING'},
          },
          'required': ['type', 'texte'],
        },
      },
    },
    'required': ['reponses'],
  };
  final j = await gemini.generateJson(prompt, schema, temperature: 0.7);
  return ((j['reponses'] as List?) ?? [])
      .map((e) => ReplySuggestion((e['type'] ?? 'question').toString(), (e['texte'] ?? '').toString().trim()))
      .where((r) => r.text.isNotEmpty && !RegExp(r'https?://|@|\bmpb\b', caseSensitive: false).hasMatch(r.text))
      .take(3)
      .toList();
}

/// Notification de message reçue (radar en arrière-plan) : rattachement + statut.
/// Rend le message rattaché (ou null).
Future<SellerMessage?> handleReplyNotification(String title, String text) async {
  final m = matchReply('$title $text', await MessageStore.awaitingReply());
  if (m == null) {
    await RadarDb.log('💬 Message Leboncoin « $title » : aucune annonce contactée correspondante');
    return null;
  }
  await MessageStore.recordReply(m.id, text.isEmpty ? title : text);
  await RadarDb.log('💬 Réponse reçue pour « ${m.title} » ($title)');
  return m;
}
