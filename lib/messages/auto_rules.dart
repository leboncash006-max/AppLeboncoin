import '../models.dart';

/// Raison (sans base de données ni IA) pour laquelle une analyse ne peut PAS
/// partir en envoi automatique ; null = conditions réunies côté analyse.
/// La marge testée est la marge NETTE.
String? autoBlockReason(Analysis a, double minMargin) {
  if (a.price == null) return 'prix inconnu';
  if (a.costs?.tooFar == true) return 'trop loin pour une remise en main propre';
  final m = a.margin;
  if (m == null || m < minMargin) return 'marge nette sous le seuil';
  if (a.condition == 'parts') return 'pour pièces';
  final p = a.photos;
  if (p != null && p.hasMajorDefect) return 'défaut majeur visible sur les photos';
  if (p != null && p.coherent != 'oui') return 'photos : correspondance « ${p.coherent} »';
  // (l'info « état visuel plus bas » n'est pas bloquante : le prix en tient déjà compte)
  final alerts = a.warnings.where((w) => !w.startsWith('📷')).toList();
  if (alerts.isNotEmpty) return 'alerte : ${alerts.first}';
  if (a.defects.isNotEmpty) return 'défauts signalés';
  if (a.items.isEmpty) return 'rien d\'identifié';
  if (a.items.any((i) => !i.confident || !i.realPrice)) return 'version incertaine ou prix non réel';
  return null;
}
