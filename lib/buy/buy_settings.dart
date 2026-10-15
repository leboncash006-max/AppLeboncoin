import 'package:shared_preferences/shared_preferences.dart';

/// Réglages de l'achat automatique (un seul menu). Lus aussi par le radar.
class BuySettings {
  bool enabled; // interrupteur général
  bool testMode; // tout sauf le clic final « Payer » (activé par défaut)
  bool suspended; // suspendu après un échec : je réactive moi-même
  double minNetMargin; // marge nette minimale pour acheter seul
  double maxPrice; // prix maximum d'un achat (livraison comprise)
  double dailyBudget; // dépense maximum par jour
  int maxPerDay; // achats maximum par jour

  BuySettings({
    this.enabled = false,
    this.testMode = true,
    this.suspended = false,
    this.minNetMargin = 60,
    this.maxPrice = 150,
    this.dailyBudget = 300,
    this.maxPerDay = 1,
  });

  /// Certitude minimale demandée à l'IA (non réglable).
  static const minCertainty = 95;

  static Future<BuySettings> load() async {
    final p = await SharedPreferences.getInstance();
    await p.reload(); // valeurs à jour aussi dans le moteur du radar
    return BuySettings(
      enabled: p.getBool('buy_enabled') ?? false,
      testMode: p.getBool('buy_test') ?? true,
      suspended: p.getBool('buy_suspended') ?? false,
      minNetMargin: p.getDouble('buy_min_margin') ?? 60,
      maxPrice: p.getDouble('buy_max_price') ?? 150,
      dailyBudget: p.getDouble('buy_daily_budget') ?? 300,
      maxPerDay: (p.getInt('buy_max_per_day') ?? 1).clamp(1, 5),
    );
  }

  Future<void> save() async {
    final p = await SharedPreferences.getInstance();
    await p.setBool('buy_enabled', enabled);
    await p.setBool('buy_test', testMode);
    await p.setBool('buy_suspended', suspended);
    await p.setDouble('buy_min_margin', minNetMargin);
    await p.setDouble('buy_max_price', maxPrice);
    await p.setDouble('buy_daily_budget', dailyBudget);
    await p.setInt('buy_max_per_day', maxPerDay.clamp(1, 5));
  }
}
