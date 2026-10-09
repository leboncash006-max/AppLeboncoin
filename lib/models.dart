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
}

/// Statistiques des prix de revente MPB pour un modèle.
class ResaleStats {
  final double median;
  final int count;
  final String basis; // "Bon" ou "tous états × 0,9"
  final String? productUrl;

  ResaleStats(this.median, this.count, this.basis, this.productUrl);
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
  String source = ''; // "estimation réelle" | "revente × coef"
  double? coef;

  ItemResult(this.item, this.candidates);
}

class Analysis {
  final List<ItemResult> items;
  final double? price;
  final List<String> defects;
  final String conditionHint;
  final int? shutterCount;
  final List<String> warnings;

  Analysis({
    required this.items,
    required this.price,
    required this.defects,
    required this.conditionHint,
    required this.shutterCount,
    required this.warnings,
  });

  double get totalBuyback =>
      items.fold(0.0, (s, i) => s + (i.buyback ?? 0));

  double? get margin => price == null ? null : totalBuyback - price!;
}
