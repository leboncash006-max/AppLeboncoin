import 'dart:convert';
import 'dart:math';

import 'package:http/http.dart' as http;

import 'settings.dart';
import 'v3_models.dart';

/// Distance à vol d'oiseau en km (formule de haversine).
double haversineKm(double lat1, double lng1, double lat2, double lng2) {
  const r = 6371.0;
  double rad(double d) => d * pi / 180;
  final dLat = rad(lat2 - lat1), dLng = rad(lng2 - lng1);
  final a = sin(dLat / 2) * sin(dLat / 2) + cos(rad(lat1)) * cos(rad(lat2)) * sin(dLng / 2) * sin(dLng / 2);
  return 2 * r * asin(sqrt(a));
}

/// Facteur route / vol d'oiseau (estimation).
const roadFactor = 1.25;

/// Coûts réels d'un achat au prix [price] :
/// - livraison possible → frais Leboncoin (paiement en ligne) + frais d'envoi,
///   sauf si la main propre (trajet aller-retour) coûte moins cher et que c'est assez près ;
/// - main propre seulement → trajet aller-retour × coût/km ; trop loin → alerte.
CostBreakdown computeCosts(double price, AdExtras? ad, NetSettings s) {
  double? km;
  if (ad != null && ad.lat != null && ad.lng != null && s.homeLat != null && s.homeLng != null) {
    km = haversineKm(s.homeLat!, s.homeLng!, ad.lat!, ad.lng!) * roadFactor;
  }
  final fees = s.feePct / 100 * price + s.feeFixed;
  final shipCost = fees + s.shippingCost;
  final travel = km == null ? null : 2 * km * s.kmCost;
  final near = km != null && km <= s.maxKm;
  final shippable = ad?.shippable ?? false;

  CostBreakdown ship() => CostBreakdown(
      fees: fees, shipping: s.shippingCost, distanceKm: km, mode: 'livraison', feePct: s.feePct, feeFixed: s.feeFixed);
  CostBreakdown hand({bool tooFar = false}) => CostBreakdown(
      travel: travel ?? 0, distanceKm: km, mode: 'main propre', tooFar: tooFar, feePct: s.feePct, feeFixed: s.feeFixed);

  if (ad == null) return CostBreakdown(feePct: s.feePct, feeFixed: s.feeFixed); // saisie manuelle : inconnu
  if (shippable) {
    if (near && travel! < shipCost) return hand();
    return ship();
  }
  if (km == null) return hand(); // distance inconnue (ville non réglée)
  return hand(tooFar: !near);
}

/// Prix d'achat maximum pour garder [minMargin] de marge NETTE avec la reprise [buyback].
double maxPriceFor(double buyback, double minMargin, CostBreakdown? c) {
  if (c == null) return buyback - minMargin;
  if (c.feesApply) {
    return (buyback - minMargin - c.shipping - c.feeFixed) / (1 + c.feePct / 100);
  }
  return buyback - minMargin - c.travel - c.shipping;
}

/// Coordonnées d'une ville ou d'un code postal (Base Adresse Nationale, gratuite).
Future<({double lat, double lng, String label})?> geocode(String query) async {
  final q = query.trim();
  if (q.isEmpty) return null;
  try {
    final r = await http
        .get(Uri.https('api-adresse.data.gouv.fr', '/search/', {'q': q, 'type': 'municipality', 'limit': '1'}))
        .timeout(const Duration(seconds: 15));
    if (r.statusCode != 200) return null;
    final f = ((jsonDecode(r.body)['features'] as List?) ?? []);
    if (f.isEmpty) return null;
    final c = f.first['geometry']['coordinates'] as List;
    final p = f.first['properties'] as Map;
    return (
      lat: (c[1] as num).toDouble(),
      lng: (c[0] as num).toDouble(),
      label: '${p['postcode'] ?? ''} ${p['city'] ?? p['label'] ?? ''}'.trim()
    );
  } catch (_) {
    return null;
  }
}
