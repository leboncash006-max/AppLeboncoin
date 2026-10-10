import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/net_margin.dart';
import '../services/settings.dart';
import '../widgets/common.dart';

/// Page d'aide Leboncoin sur les frais côté acheteur.
const lbcFeesHelpUrl = 'https://assistance.leboncoin.info/hc/fr/search?query=frais%20de%20service%20acheteur';

/// Réglages de la marge NETTE : lieu, trajet, frais Leboncoin, livraison.
class NetSettingsScreen extends StatefulWidget {
  final Settings settings;
  const NetSettingsScreen({super.key, required this.settings});

  @override
  State<NetSettingsScreen> createState() => _NetSettingsScreenState();
}

class _NetSettingsScreenState extends State<NetSettingsScreen> {
  NetSettings get n => widget.settings.net;
  late final _home = TextEditingController(text: n.home);
  late final _km = TextEditingController(text: n.kmCost.toString());
  late final _max = TextEditingController(text: n.maxKm.toStringAsFixed(0));
  late final _pct = TextEditingController(text: n.feePct.toString());
  late final _fixed = TextEditingController(text: n.feeFixed.toString());
  late final _ship = TextEditingController(text: n.shippingCost.toString());
  String? _place;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    if (n.homeLat != null) _place = '${n.home} (position enregistrée)';
  }

  double _num(TextEditingController c, double fallback) =>
      double.tryParse(c.text.replaceAll(',', '.').replaceAll('€', '').replaceAll('%', '').trim()) ?? fallback;

  Future<void> _save() async {
    setState(() => _busy = true);
    final home = _home.text.trim();
    if (home != n.home || n.homeLat == null) {
      final g = home.isEmpty ? null : await geocode(home);
      n.homeLat = g?.lat;
      n.homeLng = g?.lng;
      if (home.isNotEmpty && g == null && mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('Ville introuvable : le trajet ne sera pas compté.')));
      }
      _place = g?.label;
    }
    n
      ..home = home
      ..kmCost = _num(_km, 0.15)
      ..maxKm = _num(_max, 30)
      ..feePct = _num(_pct, 0)
      ..feeFixed = _num(_fixed, 0)
      ..shippingCost = _num(_ship, 6);
    await widget.settings.save();
    if (!mounted) return;
    setState(() => _busy = false);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(_place == null ? 'Enregistré.' : 'Enregistré : $_place.')));
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    Widget field(TextEditingController c, String label, {String? suffix, String? helper}) => Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: TextField(
            controller: c,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: InputDecoration(labelText: label, suffixText: suffix, helperText: helper),
          ),
        );
    return Scaffold(
      appBar: AppBar(title: const Text('Marge nette')),
      body: ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 32), children: [
        Text(
          'Marge nette = reprise MPB − prix − frais Leboncoin − (livraison, ou trajet aller-retour '
          'si remise en main propre). Le Radar, les notifications et l\'envoi automatique l\'utilisent.',
          style: TextStyle(color: cs.onSurfaceVariant),
        ),
        const SizedBox(height: 14),
        AppCard(
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            const Text('Trajet (main propre)', style: TextStyle(fontWeight: FontWeight.w800)),
            const SizedBox(height: 10),
            TextField(
              controller: _home,
              decoration: InputDecoration(
                labelText: 'Ma ville ou mon code postal',
                helperText: _place,
                prefixIcon: const Icon(Icons.home_outlined),
              ),
            ),
            const SizedBox(height: 12),
            field(_km, 'Coût au km', suffix: '€/km'),
            field(_max, 'Distance max pour une remise en main propre', suffix: 'km',
                helper: 'Distance estimée par la route (vol d\'oiseau × 1,25).'),
          ]),
        ),
        const SizedBox(height: 12),
        AppCard(
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            const Text('Achat avec livraison', style: TextStyle(fontWeight: FontWeight.w800)),
            const SizedBox(height: 4),
            Text('Les frais Leboncoin ne sont comptés que pour un achat en ligne (livraison).',
                style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12.5)),
            const SizedBox(height: 10),
            field(_pct, 'Frais Leboncoin (pourcentage)', suffix: '%'),
            field(_fixed, 'Frais Leboncoin (fixe)', suffix: '€'),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: () => launchUrl(Uri.parse(lbcFeesHelpUrl), mode: LaunchMode.externalApplication),
                icon: const Icon(Icons.help_outline, size: 18),
                label: const Text('Voir les frais sur l\'aide Leboncoin'),
              ),
            ),
            field(_ship, 'Frais d\'envoi estimés', suffix: '€'),
          ]),
        ),
        const SizedBox(height: 16),
        FilledButton.icon(
          onPressed: _busy ? null : _save,
          icon: _busy
              ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.save_outlined),
          label: const Text('Enregistrer'),
        ),
      ]),
    );
  }
}
