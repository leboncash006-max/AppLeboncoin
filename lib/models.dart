/// Un élément vendu dans l'annonce, tel que Gemini l'a compris.
class ExtractedItem {
  final String type; // boitier | objectif | flash | autre
  final String brand;
  final String nameGuess;
  final String searchQuery;
  final String details;

  ExtractedItem({
    required this.type,
    required this.brand,
    required this.nameGuess,
    required this.searchQuery,
    this.details = '',
  });

  factory ExtractedItem.fromJson(Map<String, dynamic> j) => ExtractedItem(
        type: (j['type'] ?? 'autre').toString(),
        brand: (j['brand'] ?? '').toString(),
        nameGuess: (j['mpb_name_guess'] ?? '').toString(),
        searchQuery: (j['search_query'] ?? '').toString(),
        details: (j['details'] ?? '').toString(),
      );

  bool get isLens => type == 'objectif';

  Map<String, dynamic> toJson() => {
        'type': type,
        'brand': brand,
        'mpb_name_guess': nameGuess,
        'search_query': searchQuery,
        'details': details,
      };
}

/// Statistiques des prix de revente MPB pour un modèle.
class ResaleStats {
  final double median;
  final int count;
  final String basis; // "Bon" ou "tous états × 0,9"
  final String? productUrl;

  ResaleStats(this.median, this.count, this.basis, this.productUrl);

  Map<String, dynamic> toJson() =>
      {'median': median, 'count': count, 'basis': basis, 'url': productUrl};

  factory ResaleStats.fromJson(Map<String, dynamic> j) => ResaleStats(
      (j['median'] as num).toDouble(),
      (j['count'] as num).toInt(),
      (j['basis'] ?? '').toString(),
      j['url'] as String?);
}

/// Résultat pour un élément de l'annonce.
class ItemResult {
  final ExtractedItem item;
  final List<String> candidates;
  String? mpbModel;
  bool confident = false;
  String reason = '';
  ResaleStats? resale;
  double? buyback;
  String source = ''; // "prix MPB réel" | secours : "estimation réelle" | "revente × coef"
  double? coef;

  /// Identifiant MPB et les 5 prix de reprise réels (état API → €).
  int? modelId;
  Map<String, double> purchasePrices = {};

  /// Reprise avec l'état juste en dessous de l'état annoncé (marge prudente).
  double? prudentBuyback;

  /// true si le prix vient de l'API de reprise MPB.
  bool get realPrice => source == 'prix MPB réel';

  /// true si le prix est un calcul de secours (API indisponible).
  bool get approximate => buyback != null && source != 'prix MPB réel' && source != 'pour pièces';

  ItemResult(this.item, this.candidates);

  Map<String, dynamic> toJson() => {
        'item': item.toJson(),
        'candidates': candidates,
        'mpbModel': mpbModel,
        'confident': confident,
        'reason': reason,
        'resale': resale?.toJson(),
        'buyback': buyback,
        'source': source,
        'coef': coef,
        'modelId': modelId,
        'purchasePrices': purchasePrices,
        'prudentBuyback': prudentBuyback,
      };

  factory ItemResult.fromJson(Map<String, dynamic> j) {
    final r = ItemResult(
      ExtractedItem.fromJson(Map<String, dynamic>.from(j['item'] as Map)),
      ((j['candidates'] as List?) ?? []).map((e) => '$e').toList(),
    )
      ..mpbModel = j['mpbModel'] as String?
      ..confident = j['confident'] == true
      ..reason = (j['reason'] ?? '').toString()
      ..buyback = (j['buyback'] as num?)?.toDouble()
      ..source = (j['source'] ?? '').toString()
      ..coef = (j['coef'] as num?)?.toDouble()
      ..modelId = (j['modelId'] as num?)?.toInt()
      ..purchasePrices = Map<String, dynamic>.from((j['purchasePrices'] as Map?) ?? {})
          .map((k, v) => MapEntry(k, (v as num).toDouble()))
      ..prudentBuyback = (j['prudentBuyback'] as num?)?.toDouble();
    if (j['resale'] != null) {
      r.resale = ResaleStats.fromJson(Map<String, dynamic>.from(j['resale'] as Map));
    }
    return r;
  }
}

class Analysis {
  final List<ItemResult> items;
  final double? price;
  final List<String> defects;
  final String conditionHint;
  final int? shutterCount;
  final List<String> warnings;

  /// État MPB retenu d'après l'annonce (like-new…heavily-used, ou "parts"
  /// pour pièces) et l'état juste en dessous pour la marge prudente.
  final String condition;
  final String prudentCondition;

  /// Vérification IA de correspondance annonce ↔ modèles : oui | doute | non
  /// (null = pas faite). Sans « oui », jamais d'envoi automatique.
  String? aiVerdict;
  String aiReason;

  /// Verdict utilisable : jamais « oui » si un élément n'a pas de modèle MPB
  /// (protège aussi les analyses enregistrées avant cette règle).
  String? get verdict => aiVerdict == 'oui' && items.any((i) => i.mpbModel == null) ? 'doute' : aiVerdict;

  /// Moteur d'identification : « ia » ou « local » (secours si l'IA échoue).
  String engine;

  Analysis({
    required this.items,
    required this.price,
    required this.defects,
    required this.conditionHint,
    required this.shutterCount,
    required this.warnings,
    this.condition = 'good',
    this.prudentCondition = 'well-used',
    this.aiVerdict,
    this.aiReason = '',
    this.engine = 'ia',
  });

  double get totalBuyback =>
      items.fold(0.0, (s, i) => s + (i.buyback ?? 0));

  /// true si au moins un élément a un prix de reprise (0 € pour pièces compris).
  bool get hasBuyback => items.any((i) => i.buyback != null);

  /// Marge inconnue si le prix manque ou si rien n'a pu être chiffré
  /// (sinon « 0 € de reprise » afficherait une fausse perte).
  double? get margin => price == null || !hasBuyback ? null : totalBuyback - price!;

  /// Reprise si MPB classe le matériel un cran en dessous.
  double get prudentTotal =>
      items.fold(0.0, (s, i) => s + (i.prudentBuyback ?? i.buyback ?? 0));

  double? get prudentMargin => price == null || !hasBuyback ? null : prudentTotal - price!;

  Map<String, dynamic> toJson() => {
        'items': items.map((i) => i.toJson()).toList(),
        'price': price,
        'defects': defects,
        'conditionHint': conditionHint,
        'shutterCount': shutterCount,
        'warnings': warnings,
        'condition': condition,
        'prudentCondition': prudentCondition,
        'aiVerdict': aiVerdict,
        'aiReason': aiReason,
        'engine': engine,
      };

  factory Analysis.fromJson(Map<String, dynamic> j) => Analysis(
        items: ((j['items'] as List?) ?? [])
            .map((e) => ItemResult.fromJson(Map<String, dynamic>.from(e as Map)))
            .toList(),
        price: (j['price'] as num?)?.toDouble(),
        defects: ((j['defects'] as List?) ?? []).map((e) => '$e').toList(),
        conditionHint: (j['conditionHint'] ?? 'inconnu').toString(),
        shutterCount: (j['shutterCount'] as num?)?.toInt(),
        warnings: ((j['warnings'] as List?) ?? []).map((e) => '$e').toList(),
        condition: (j['condition'] ?? 'good').toString(),
        prudentCondition: (j['prudentCondition'] ?? 'well-used').toString(),
        aiVerdict: j['aiVerdict'] as String?,
        aiReason: (j['aiReason'] ?? '').toString(),
        engine: (j['engine'] ?? 'ia').toString(),
      );
}
