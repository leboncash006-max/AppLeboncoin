import 'package:shared_preferences/shared_preferences.dart';

/// Réglages de la marge nette : lieu, trajet, frais Leboncoin, livraison.
class NetSettings {
  String home; // ville ou code postal saisi
  double? homeLat;
  double? homeLng;
  double kmCost; // €/km
  double maxKm; // distance max pour une remise en main propre
  double feePct; // frais Leboncoin à l'achat (%)
  double feeFixed; // frais Leboncoin à l'achat (fixe, €)
  double shippingCost; // frais d'envoi estimés si livraison

  NetSettings({
    this.home = '',
    this.homeLat,
    this.homeLng,
    this.kmCost = 0.15,
    this.maxKm = 30,
    this.feePct = 0,
    this.feeFixed = 0,
    this.shippingCost = 6,
  });
}

class Settings {
  double coefBody;
  double coefLens;
  double minMargin;
  bool darkTheme;
  final NetSettings net;

  Settings(
      {this.coefBody = 0.54,
      this.coefLens = 0.40,
      this.minMargin = 30,
      this.darkTheme = true,
      NetSettings? net})
      : net = net ?? NetSettings();

  static Future<Settings> load() async {
    final p = await SharedPreferences.getInstance();
    await p.reload(); // valeurs à jour aussi dans le moteur du radar
    return Settings(
      coefBody: p.getDouble('coefBody') ?? 0.54,
      coefLens: p.getDouble('coefLens') ?? 0.40,
      minMargin: p.getDouble('minMargin') ?? 30,
      darkTheme: p.getBool('darkTheme') ?? true,
      net: NetSettings(
        home: p.getString('net_home') ?? '',
        homeLat: p.getDouble('net_home_lat'),
        homeLng: p.getDouble('net_home_lng'),
        kmCost: p.getDouble('net_km_cost') ?? 0.15,
        maxKm: p.getDouble('net_max_km') ?? 30,
        feePct: p.getDouble('net_fee_pct') ?? 0,
        feeFixed: p.getDouble('net_fee_fixed') ?? 0,
        shippingCost: p.getDouble('net_shipping') ?? 6,
      ),
    );
  }

  Future<void> save() async {
    final p = await SharedPreferences.getInstance();
    await p.setDouble('coefBody', coefBody);
    await p.setDouble('coefLens', coefLens);
    await p.setDouble('minMargin', minMargin);
    await p.setBool('darkTheme', darkTheme);
    await p.setString('net_home', net.home);
    if (net.homeLat != null && net.homeLng != null) {
      await p.setDouble('net_home_lat', net.homeLat!);
      await p.setDouble('net_home_lng', net.homeLng!);
    } else {
      await p.remove('net_home_lat');
      await p.remove('net_home_lng');
    }
    await p.setDouble('net_km_cost', net.kmCost);
    await p.setDouble('net_max_km', net.maxKm);
    await p.setDouble('net_fee_pct', net.feePct);
    await p.setDouble('net_fee_fixed', net.feeFixed);
    await p.setDouble('net_shipping', net.shippingCost);
  }
}
