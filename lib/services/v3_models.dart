// Données v3 : photos de l'annonce, analyse des photos par l'IA, coûts réels
// (frais Leboncoin, livraison ou trajet) pour la marge NETTE.

/// États MPB du meilleur au pire.
const conditionOrder = ['like-new', 'excellent', 'good', 'well-used', 'heavily-used'];

/// État le plus BAS entre [a] et [b] (« inconnu » ou null est ignoré).
String lowestCondition(String a, String? b) {
  final ia = conditionOrder.indexOf(a);
  final ib = b == null ? -1 : conditionOrder.indexOf(b);
  if (ib < 0) return a;
  if (ia < 0) return b!;
  return ib > ia ? b! : a;
}

/// Ce qu'on lit en plus dans la page de l'annonce (__NEXT_DATA__).
class AdExtras {
  final List<String> images;
  final String city;
  final String zipcode;
  final double? lat;
  final double? lng;
  final bool shippable;
  final String shippingType;

  AdExtras({
    this.images = const [],
    this.city = '',
    this.zipcode = '',
    this.lat,
    this.lng,
    this.shippable = false,
    this.shippingType = '',
  });

  Map<String, dynamic> toJson() => {
        'images': images,
        'city': city,
        'zipcode': zipcode,
        'lat': lat,
        'lng': lng,
        'shippable': shippable,
        'shippingType': shippingType,
      };

  factory AdExtras.fromJson(Map<String, dynamic> j) => AdExtras(
        images: ((j['images'] as List?) ?? []).map((e) => '$e').where((e) => e.startsWith('http')).toList(),
        city: (j['city'] ?? '').toString(),
        zipcode: (j['zipcode'] ?? '').toString(),
        lat: (j['lat'] as num?)?.toDouble(),
        lng: (j['lng'] as num?)?.toDouble(),
        shippable: j['shippable'] == true || j['shippable'] == 'true',
        shippingType: (j['shippingType'] ?? '').toString(),
      );

  String get place => [zipcode, city].where((s) => s.isNotEmpty).join(' ');
}

/// Défaut vu sur une photo.
class PhotoDefect {
  final String type;
  final bool major;
  final int? photoIndex;
  PhotoDefect(this.type, this.major, this.photoIndex);

  Map<String, dynamic> toJson() => {'type': type, 'gravite': major ? 'majeur' : 'mineur', 'photo_index': photoIndex};
  factory PhotoDefect.fromJson(Map<String, dynamic> j) => PhotoDefect(
      (j['type'] ?? '').toString(), j['gravite'] == 'majeur', (j['photo_index'] as num?)?.toInt());
}

/// Défauts toujours considérés comme majeurs, quoi qu'en dise l'IA.
final majorDefectWords = RegExp(
    r'[ée]cran (cass|fissur|bris)|lentille ray|ray(ure|é)e? (sur|de) la lentille|champignon|moisissure|bu[ée]e|'
    r'objectif ray|verre (cass|ray|fissur)|capteur (ray|ab[iî]m|cass)',
    caseSensitive: false);

/// Résultat de l'analyse des photos par Gemini.
class PhotoCheck {
  final List<String> images; // URL des photos analysées (même ordre que photo_index)
  final String visibleModel;
  final String coherent; // oui | non | doute
  final String reason;
  final String visualCondition; // état MPB ou « inconnu »
  final List<PhotoDefect> defects;
  final List<String> accessories;

  PhotoCheck({
    required this.images,
    this.visibleModel = '',
    this.coherent = 'doute',
    this.reason = '',
    this.visualCondition = 'inconnu',
    this.defects = const [],
    this.accessories = const [],
  });

  /// Défaut majeur (écran cassé, lentille rayée, champignon, buée…).
  bool get hasMajorDefect => defects.any((d) => d.major || majorDefectWords.hasMatch(d.type));

  Map<String, dynamic> toJson() => {
        'images': images,
        'modele_visible': visibleModel,
        'coherent_avec_annonce': coherent,
        'raison': reason,
        'etat_visuel': visualCondition,
        'defauts': defects.map((d) => d.toJson()).toList(),
        'accessoires_visibles': accessories,
      };

  factory PhotoCheck.fromJson(Map<String, dynamic> j, {List<String> images = const []}) => PhotoCheck(
        images: ((j['images'] as List?) ?? images).map((e) => '$e').toList(),
        visibleModel: (j['modele_visible'] ?? '').toString(),
        coherent: ['oui', 'non', 'doute'].contains(j['coherent_avec_annonce']) ? j['coherent_avec_annonce'] as String : 'doute',
        reason: (j['raison'] ?? '').toString(),
        visualCondition: (j['etat_visuel'] ?? 'inconnu').toString(),
        defects: ((j['defauts'] as List?) ?? [])
            .map((e) => PhotoDefect.fromJson(Map<String, dynamic>.from(e as Map)))
            .toList(),
        accessories: ((j['accessoires_visibles'] as List?) ?? []).map((e) => '$e').toList(),
      );
}

/// Détail des coûts réels d'un achat (pour la marge nette).
class CostBreakdown {
  final double fees; // frais Leboncoin à l'achat
  final double shipping; // livraison (si envoi)
  final double travel; // trajet aller-retour (si main propre)
  final double? distanceKm; // distance à vol d'oiseau × 1,25 (route)
  final String mode; // livraison | main propre | inconnu
  final bool tooFar; // main propre seulement et trop loin
  final double feePct; // pour recalculer le prix max
  final double feeFixed;

  CostBreakdown({
    this.fees = 0,
    this.shipping = 0,
    this.travel = 0,
    this.distanceKm,
    this.mode = 'inconnu',
    this.tooFar = false,
    this.feePct = 0,
    this.feeFixed = 0,
  });

  double get total => fees + shipping + travel;

  /// Les frais Leboncoin ne s'appliquent qu'au paiement en ligne (livraison).
  bool get feesApply => mode == 'livraison';

  Map<String, dynamic> toJson() => {
        'fees': fees,
        'shipping': shipping,
        'travel': travel,
        'distanceKm': distanceKm,
        'mode': mode,
        'tooFar': tooFar,
        'feePct': feePct,
        'feeFixed': feeFixed,
      };

  factory CostBreakdown.fromJson(Map<String, dynamic> j) => CostBreakdown(
        fees: (j['fees'] as num?)?.toDouble() ?? 0,
        shipping: (j['shipping'] as num?)?.toDouble() ?? 0,
        travel: (j['travel'] as num?)?.toDouble() ?? 0,
        distanceKm: (j['distanceKm'] as num?)?.toDouble(),
        mode: (j['mode'] ?? 'inconnu').toString(),
        tooFar: j['tooFar'] == true,
        feePct: (j['feePct'] as num?)?.toDouble() ?? 0,
        feeFixed: (j['feeFixed'] as num?)?.toDouble() ?? 0,
      );
}
