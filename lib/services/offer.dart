import '../models.dart';
import 'net_margin.dart';

/// Prix d'achat maximum pour garder la marge NETTE voulue (arrondi aux 5 € inférieurs).
double? maxBuyPrice(Analysis a, double minMargin, {bool prudent = false}) {
  if (!a.hasBuyback) return null;
  // marge NETTE : frais Leboncoin, livraison ou trajet déduits
  final v = maxPriceFor(prudent ? a.prudentTotal : a.totalBuyback, minMargin, a.costs);
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
