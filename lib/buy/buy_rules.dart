import '../services/analyzer.dart' show suspiciousWarning;
import '../services/gemini_service.dart';
import '../services/history.dart';
import '../services/mpb_service.dart';
import '../services/settings.dart';
import '../services/v3_models.dart';
import 'buy_settings.dart';

/// Coûts d'un achat EN LIGNE (paiement avec le solde = livraison obligatoire).
CostBreakdown onlineCosts(double price, NetSettings s) => CostBreakdown(
    fees: s.feePct / 100 * price + s.feeFixed,
    shipping: s.shippingCost,
    mode: 'livraison',
    feePct: s.feePct,
    feeFixed: s.feeFixed);

/// Raison (sans réseau) pour laquelle l'annonce NE PEUT PAS être achetée
/// automatiquement ; null = toutes les conditions STRICTES sont réunies.
/// Il faut que tout soit sûr : modèle, photos, état, prix réel MPB et une
/// marge nette largement positive, même un état en dessous.
String? buyBlockReason(HistoryEntry e, BuySettings b, NetSettings net) {
  final a = e.analysis;
  final price = a.price;
  if (price == null || price <= 0) return 'prix inconnu';
  if (e.extras == null || !e.extras!.shippable) return 'pas de livraison : paiement en ligne impossible';
  if (a.condition == 'parts') return 'pour pièces';
  if (a.engine != 'ia') return 'identification de secours (IA indisponible)';
  if (a.items.isEmpty) return 'rien d\'identifié';
  if (a.items.length > 2) return 'lot de plus de 2 éléments';
  if (a.items.any((i) => i.mpbModel == null || !i.confident || !i.realPrice)) {
    return 'modèle ou prix MPB pas certain';
  }
  if (a.verdict != 'oui') return 'vérification de correspondance « ${a.verdict ?? 'non faite'} »';
  final p = a.photos;
  if (p == null || p.images.length < 2) return 'pas assez de photos analysées';
  if (p.coherent != 'oui') return 'photos : « ${p.coherent} »';
  if (p.hasMajorDefect) return 'défaut majeur sur les photos';
  if (p.defects.length > 1) return 'plusieurs défauts visibles';
  if (p.visualCondition == 'inconnu' || p.visualCondition == 'heavily-used') return 'état visuel « ${p.visualCondition} »';
  if (a.defects.isNotEmpty) return 'défauts signalés dans l\'annonce';
  if (a.warnings.contains(suspiciousWarning)) return 'reprise anormalement haute';
  final alerts = a.warnings.where((w) => !w.startsWith('📷')).toList();
  if (alerts.isNotEmpty) return 'alerte : ${alerts.first}';
  // marge nette d'un achat en ligne, et marge même un état en dessous (prudente)
  final c = onlineCosts(price, net);
  final total = price + c.total;
  if (total > b.maxPrice) return 'total ${total.toStringAsFixed(0)} € > max ${b.maxPrice.toStringAsFixed(0)} €';
  final net1 = a.totalBuyback - total;
  if (net1 < b.minNetMargin) return 'marge nette ${net1.toStringAsFixed(0)} € < ${b.minNetMargin.toStringAsFixed(0)} €';
  final prudent = a.prudentTotal - total;
  if (prudent < b.minNetMargin / 2) return 'marge prudente trop faible (${prudent.toStringAsFixed(0)} €)';
  if (a.totalBuyback < total * 1.25) return 'reprise moins de 25 % au-dessus du coût';
  return null;
}

/// Dernier contrôle par l'IA : « go » seulement si elle est sûre à ≥ 95 %.
Future<({bool go, int certainty, String reason})> aiBuyCheck(GeminiService gemini, HistoryEntry e, double total) async {
  final a = e.analysis;
  final items = a.items
      .map((i) => '- ${i.item.type} : ${i.mpbModel} → reprise MPB ${i.buyback?.toStringAsFixed(0)} € '
          '(${mpbConditionLabels[a.condition] ?? a.condition})')
      .join('\n');
  final p = a.photos!;
  final prompt = '''
Tu décides si un acheteur peut ACHETER AUTOMATIQUEMENT cette annonce Leboncoin pour la revendre à MPB.
L'achat est définitif : réponds « go » UNIQUEMENT si tu es certain que c'est une bonne affaire sans
risque. Au moindre doute (version, état, arnaque, lot incomplet, prix trop beau, description vague,
objet volé possible, pièces manquantes, compte ou photos suspects), réponds « no_go ».
Titre : ${e.title}
${e.attributesText}
Description : """
${e.description.length > 2000 ? e.description.substring(0, 2000) : e.description}
"""
Prix ${a.price!.toStringAsFixed(0)} € ; coût total livré ${total.toStringAsFixed(0)} €.
Modèles et reprises MPB réelles :
$items
Photos : ${p.images.length} analysées, modèle visible « ${p.visibleModel} », état visuel ${p.visualCondition},
défauts : ${p.defects.isEmpty ? 'aucun' : p.defects.map((d) => d.type).join(', ')},
accessoires : ${p.accessories.join(', ')}.
Donne : decision (go | no_go), certitude (0 à 100) et raison courte.''';
  const schema = {
    'type': 'OBJECT',
    'properties': {
      'decision': {
        'type': 'STRING',
        'enum': ['go', 'no_go'],
      },
      'certitude': {'type': 'INTEGER'},
      'raison': {'type': 'STRING'},
    },
    'required': ['decision', 'certitude', 'raison'],
  };
  try {
    final j = await gemini.generateJson(prompt, schema);
    final c = (j['certitude'] as num?)?.toInt() ?? 0;
    return (go: j['decision'] == 'go' && c >= BuySettings.minCertainty, certainty: c, reason: (j['raison'] ?? '').toString());
  } catch (err) {
    return (go: false, certainty: 0, reason: 'IA indisponible : $err');
  }
}
