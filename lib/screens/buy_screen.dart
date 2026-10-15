import 'package:flutter/material.dart';

import '../buy/buy_settings.dart';
import '../buy/buyer.dart';
import '../buy/lbc_scripts.dart';
import '../radar/native_browser.dart';
import '../radar/radar_db.dart';
import '../services/settings.dart';
import '../theme.dart';
import '../widgets/common.dart';
import 'lbc_login_screen.dart';
import 'result_screen.dart' show openExternal;

enum _Login { unknown, checking, yes, no, blocked }

/// Onglet « Achat » : UN seul menu pour l'achat automatique avec le solde
/// Leboncoin (connexion, interrupteur, mode test, plafonds, historique).
class BuyScreen extends StatefulWidget {
  final Settings settings;
  final bool visible;
  const BuyScreen({super.key, required this.settings, required this.visible});

  @override
  State<BuyScreen> createState() => _BuyScreenState();
}

class _BuyScreenState extends State<BuyScreen> {
  BuySettings? _b;
  List<BuyAttempt> _history = [];
  ({int count, double spent}) _today = (count: 0, spent: 0);
  _Login _login = _Login.unknown;

  @override
  void initState() {
    super.initState();
    _load();
    _checkLogin();
  }

  @override
  void didUpdateWidget(BuyScreen old) {
    super.didUpdateWidget(old);
    if (widget.visible && !old.visible) _load();
  }

  Future<void> _load() async {
    final b = await BuySettings.load();
    final h = await BuyStore.all();
    final t = await BuyStore.today();
    if (!mounted) return;
    setState(() {
      _b = b;
      _history = h;
      _today = t;
    });
  }

  Future<void> _checkLogin() async {
    setState(() => _login = _Login.checking);
    final br = NativeBrowser('lbc_login');
    var r = _Login.unknown;
    try {
      final l = await br.load(LbcLoginScreen.startUrl, timeoutMs: 25000);
      if (l.ok) {
        final until = DateTime.now().add(const Duration(seconds: 15));
        while (DateTime.now().isBefore(until)) {
          await Future.delayed(const Duration(milliseconds: 1200));
          final st = await br.evalJson(pageStateScript);
          if (st == null || st['ready'] != true) continue;
          r = st['blocked'] == true ? _Login.blocked : (st['login'] == true ? _Login.no : _Login.yes);
          break;
        }
      }
    } catch (_) {}
    await br.dispose();
    if (mounted) setState(() => _login = r);
  }

  Future<void> _set(void Function(BuySettings b) f) async {
    final b = _b;
    if (b == null) return;
    setState(() => f(b));
    await b.save();
  }

  Future<void> _toggle(bool on) async {
    if (on && _b!.testMode == false) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Achat auto RÉEL'),
          content: const Text('L\'appli paiera SEULE avec ton solde Leboncoin quand tout est sûr. '
              'Les achats sont définitifs. Tu confirmes ?'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Annuler')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Oui, activer')),
          ],
        ),
      );
      if (ok != true) return;
    }
    await _set((b) => b.enabled = on);
  }

  Future<void> _num(String title, double value, String suffix, void Function(double) apply) async {
    final c = TextEditingController(text: value.toStringAsFixed(0));
    final v = await showDialog<double>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: TextField(
            controller: c, autofocus: true, keyboardType: TextInputType.number, decoration: InputDecoration(suffixText: suffix)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Annuler')),
          FilledButton(onPressed: () => Navigator.pop(ctx, double.tryParse(c.text.replaceAll(',', '.'))), child: const Text('OK')),
        ],
      ),
    );
    if (v != null && v > 0) await _set((b) => apply(v));
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final b = _b;
    return Scaffold(
      appBar: AppBar(title: const Text('Achat auto')),
      body: b == null
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 32), children: [
                _account(cs),
                const SizedBox(height: 10),
                AppCard(
                  padding: const EdgeInsets.fromLTRB(4, 4, 4, 8),
                  child: Column(children: [
                    SwitchListTile(
                      value: b.enabled,
                      onChanged: _toggle,
                      title: const Text('Achat automatique', style: TextStyle(fontWeight: FontWeight.w800)),
                      subtitle: const Text('Paie seul avec ton solde Leboncoin, seulement quand tout est sûr.'),
                    ),
                    SwitchListTile(
                      value: b.testMode,
                      onChanged: (v) => _set((b) => b.testMode = v),
                      title: const Text('Mode test'),
                      subtitle: const Text('Tout est fait sauf le clic final « Payer ». Laisse-le au début.'),
                    ),
                    if (b.suspended)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
                        child: Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                              color: AppColors.bad.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(12)),
                          child: Row(children: [
                            const Icon(Icons.pause_circle, color: AppColors.bad),
                            const SizedBox(width: 10),
                            const Expanded(child: Text('Suspendu après un échec. Vérifie l\'historique.')),
                            TextButton(
                                onPressed: () async {
                                  await _set((b) => b.suspended = false);
                                  await RadarDb.log('🛒 Achat auto réactivé');
                                },
                                child: const Text('Réactiver')),
                          ]),
                        ),
                      ),
                    const Divider(),
                    ListTile(
                      title: const Text('Marge nette minimale'),
                      trailing: Text(euros(b.minNetMargin), style: const TextStyle(fontWeight: FontWeight.w700)),
                      onTap: () => _num('Marge nette minimale', b.minNetMargin, '€', (v) => b.minNetMargin = v),
                    ),
                    ListTile(
                      title: const Text('Prix max d\'un achat (livré)'),
                      trailing: Text(euros(b.maxPrice), style: const TextStyle(fontWeight: FontWeight.w700)),
                      onTap: () => _num('Prix max d\'un achat', b.maxPrice, '€', (v) => b.maxPrice = v),
                    ),
                    ListTile(
                      title: const Text('Budget par jour'),
                      subtitle: Text('Aujourd\'hui : ${euros(_today.spent)} · ${_today.count} achat(s)'),
                      trailing: Text(euros(b.dailyBudget), style: const TextStyle(fontWeight: FontWeight.w700)),
                      onTap: () => _num('Budget par jour', b.dailyBudget, '€', (v) => b.dailyBudget = v),
                    ),
                    ListTile(
                      title: const Text('Achats max par jour'),
                      trailing: SegmentedButton<int>(
                        showSelectedIcon: false,
                        segments: const [
                          ButtonSegment(value: 1, label: Text('1')),
                          ButtonSegment(value: 2, label: Text('2')),
                          ButtonSegment(value: 3, label: Text('3')),
                        ],
                        selected: {b.maxPerDay.clamp(1, 3)},
                        onSelectionChanged: (v) => _set((b) => b.maxPerDay = v.first),
                      ),
                    ),
                  ]),
                ),
                const SizedBox(height: 10),
                ExpansionTile(
                  tilePadding: const EdgeInsets.symmetric(horizontal: 4),
                  title: const Text('Quand l\'appli achète-t-elle ?', style: TextStyle(fontWeight: FontWeight.w700)),
                  children: [
                    Text(
                      'Seulement si TOUT est réuni :\n'
                      '• modèle identifié par l\'IA, prix de reprise MPB réel, vérification « oui »\n'
                      '• au moins 2 photos cohérentes, état visuel connu, aucun défaut majeur\n'
                      '• aucune alerte, pas « pour pièces », livraison possible\n'
                      '• marge nette ≥ ton minimum, et ≥ la moitié même un état en dessous\n'
                      '• reprise au moins 25 % au-dessus du coût total\n'
                      '• dernier contrôle par l\'IA : « go » sûr à ${BuySettings.minCertainty} % minimum\n'
                      '• plafonds respectés (prix, budget, nombre par jour), jamais deux fois la même annonce\n'
                      '• paiement avec le solde uniquement, jamais par carte\n'
                      'Au moindre imprévu (vérification, page inconnue, solde insuffisant), l\'achat s\'arrête '
                      'et l\'achat auto se suspend.',
                      style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12.5, height: 1.4),
                    ),
                    const SizedBox(height: 8),
                  ],
                ),
                const SizedBox(height: 10),
                Row(children: [
                  const Text('Historique', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
                  const Spacer(),
                  Text('${_history.length}', style: TextStyle(color: cs.onSurfaceVariant)),
                ]),
                const SizedBox(height: 8),
                if (_history.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 24),
                    child: Text('Aucune tentative pour l\'instant.',
                        textAlign: TextAlign.center, style: TextStyle(color: cs.onSurfaceVariant)),
                  )
                else
                  for (final h in _history) ...[
                    AppCard(
                      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
                      onTap: h.url.isEmpty ? null : () => openExternal(h.url),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Row(children: [
                          Expanded(
                            child: Text(h.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontWeight: FontWeight.w700)),
                          ),
                          Pill(
                            label: BuyStatus.label(h.status),
                            color: switch (h.status) {
                              BuyStatus.bought => AppColors.good,
                              BuyStatus.test => AppColors.good,
                              BuyStatus.failed => AppColors.bad,
                              _ => AppColors.neutral,
                            },
                          ),
                        ]),
                        const SizedBox(height: 4),
                        Text(
                          '${euros(h.total ?? h.price)} · ${shortDate(h.at)}${h.certainty > 0 ? ' · IA ${h.certainty} %' : ''}',
                          style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12.5),
                        ),
                        if (h.error.isNotEmpty)
                          Text('${h.step} : ${h.error}',
                              maxLines: 3,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                  fontSize: 12.5, color: h.status == BuyStatus.failed ? AppColors.bad : cs.onSurfaceVariant)),
                      ]),
                    ),
                    const SizedBox(height: 8),
                  ],
              ]),
            ),
    );
  }

  Widget _account(ColorScheme cs) {
    final (icon, color, text) = switch (_login) {
      _Login.yes => (Icons.verified_user, AppColors.good, 'Connecté'),
      _Login.no => (Icons.no_accounts, AppColors.bad, 'Non connecté'),
      _Login.blocked => (Icons.gpp_maybe, AppColors.warn, 'Vérification Leboncoin à faire'),
      _Login.checking => (Icons.hourglass_top, cs.primary, 'Vérification…'),
      _Login.unknown => (Icons.help_outline, AppColors.neutral, 'État inconnu'),
    };
    return AppCard(
      child: Row(children: [
        Icon(icon, color: color),
        const SizedBox(width: 10),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('Compte Leboncoin', style: TextStyle(fontWeight: FontWeight.w800)),
            Text(text, style: TextStyle(color: color, fontWeight: FontWeight.w600)),
          ]),
        ),
        IconButton(onPressed: _login == _Login.checking ? null : _checkLogin, icon: const Icon(Icons.refresh)),
        TextButton(
          onPressed: () async {
            await Navigator.push(context, MaterialPageRoute(builder: (_) => const LbcLoginScreen()));
            _checkLogin();
          },
          child: Text(_login == _Login.yes ? 'Compte' : 'Se connecter'),
        ),
      ]),
    );
  }
}
