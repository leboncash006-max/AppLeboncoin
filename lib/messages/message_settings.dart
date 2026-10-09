import 'package:shared_preferences/shared_preferences.dart';

/// Mode d'envoi des messages aux vendeurs.
enum SendMode {
  confirm, // a) toujours confirmer : je tape Envoyer moi-même (par défaut)
  direct, // b) envoi direct quand j'appuie sur « Message vendeur »
  auto, // c) automatique pour les bonnes affaires (Radar)
}

/// Réglages « Envoi des messages » (lus aussi par le radar en arrière-plan).
class MessageSettings {
  SendMode mode;
  bool dryRun; // test à blanc : tout sauf le clic final sur Envoyer
  bool autoEnabled; // interrupteur général « Envoi auto »
  bool autoSuspended; // suspendu après 2 échecs ou un captcha
  String tone; // poli | direct | amical
  bool formal; // vouvoiement
  bool proposePrice;
  String instructions; // consignes perso
  int dailyMax; // plafond des envois automatiques par jour (≤ 20)

  MessageSettings({
    this.mode = SendMode.confirm,
    this.dryRun = true,
    this.autoEnabled = false,
    this.autoSuspended = false,
    this.tone = 'poli',
    this.formal = true,
    this.proposePrice = true,
    this.instructions = '',
    this.dailyMax = 10,
  });

  /// Garde-fous codés en dur (seul le plafond journalier est réglable).
  static const maxDailyCap = 20;
  static const maxPerHour = 3;
  static const minGap = Duration(minutes: 3);
  static const randomGapMinS = 20, randomGapMaxS = 90;
  static const quietStartHour = 22, quietEndHour = 8;
  static const failuresBeforeSuspend = 2;

  static Future<MessageSettings> load() async {
    final p = await SharedPreferences.getInstance();
    await p.reload(); // valeurs à jour même dans le moteur du radar
    return MessageSettings(
      mode: SendMode.values[(p.getInt('msg_mode') ?? 0).clamp(0, SendMode.values.length - 1)],
      dryRun: p.getBool('msg_dry_run') ?? true,
      autoEnabled: p.getBool('msg_auto_enabled') ?? false,
      autoSuspended: p.getBool('msg_auto_suspended') ?? false,
      tone: p.getString('msg_tone') ?? 'poli',
      formal: p.getBool('msg_formal') ?? true,
      proposePrice: p.getBool('msg_propose_price') ?? true,
      instructions: p.getString('msg_instructions') ?? '',
      dailyMax: (p.getInt('msg_daily_max') ?? 10).clamp(1, maxDailyCap),
    );
  }

  Future<void> save() async {
    final p = await SharedPreferences.getInstance();
    await p.setInt('msg_mode', mode.index);
    await p.setBool('msg_dry_run', dryRun);
    await p.setBool('msg_auto_enabled', autoEnabled);
    await p.setBool('msg_auto_suspended', autoSuspended);
    await p.setString('msg_tone', tone);
    await p.setBool('msg_formal', formal);
    await p.setBool('msg_propose_price', proposePrice);
    await p.setString('msg_instructions', instructions);
    await p.setInt('msg_daily_max', dailyMax.clamp(1, maxDailyCap));
  }

  /// Compteur d'échecs consécutifs (envois automatiques).
  static Future<int> failures() async {
    final p = await SharedPreferences.getInstance();
    await p.reload();
    return p.getInt('msg_failures') ?? 0;
  }

  static Future<void> setFailures(int n) async =>
      (await SharedPreferences.getInstance()).setInt('msg_failures', n);
}
