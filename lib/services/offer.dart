import '../models.dart';
import 'history.dart';

/// Prix d'achat maximum pour garder la marge voulue (arrondi aux 5 € inférieurs).
double? maxBuyPrice(Analysis a, double minMargin, {bool prudent = false}) {
  if (!a.hasBuyback) return null;
  final v = (prudent ? a.prudentTotal : a.totalBuyback) - minMargin;
  if (v <= 0) return 0;
  return (v / 5).floorToDouble() * 5;
}

/// Prix à proposer au vendeur : le prix demandé s'il est déjà sous le max,
/// sinon le max (jamais au-dessus du prix demandé).
double? suggestedOffer(Analysis a, double minMargin) {
  final max = maxBuyPrice(a, minMargin);
  final price = a.price;
  if (max == null) return null;
  if (price == null) return max;
  return price <= max ? price : max;
}

/// Message prêt à envoyer au vendeur.
String sellerMessage(HistoryEntry e, double minMargin) {
  final offer = suggestedOffer(e.analysis, minMargin);
  final price = e.analysis.price;
  final b = StringBuffer('Bonjour, votre annonce « ${e.title} » est-elle toujours disponible ? ');
  if (offer != null && price != null && offer < price) {
    b.write('Je vous propose ${offer.toStringAsFixed(0)} €, ');
  } else {
    b.write('Je suis intéressé au prix indiqué, ');
  }
  b.write('je peux régler rapidement (paiement sécurisé Leboncoin ou en main propre). Merci !');
  return b.toString();
}
