import 'package:flutter/material.dart';

import '../main.dart';
import '../services/mpb_catalog.dart';
import '../services/settings.dart';
import 'catalog_screen.dart';
import 'net_settings_screen.dart';
import 'radar_log_screen.dart';
import '../theme.dart';
import '../widgets/common.dart';

class SettingsScreen extends StatefulWidget {
  final Settings settings;
  const SettingsScreen({super.key, required this.settings});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late final _coefBody =
      TextEditingController(text: widget.settings.coefBody.toString());
  late final _coefLens =
      TextEditingController(text: widget.settings.coefLens.toString());
  late final _margin =
      TextEditingController(text: widget.settings.minMargin.toStringAsFixed(0));

  MpbCatalog? _catalog;
  bool _catalogLoaded = false;

  @override
  void initState() {
    super.initState();
    MpbCatalog.load().then((c) {
      if (mounted) {
        setState(() {
          _catalog = c;
          _catalogLoaded = true;
        });
      }
    });
  }

  Future<void> _refreshCatalog() async {
    await MpbCatalog.invalidate();
    if (!mounted) return;
    setState(() => _catalog = null);
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Le catalogue sera retéléchargé à la prochaine analyse.')));
  }

  double _num(TextEditingController c, double fallback) =>
      double.tryParse(c.text.replaceAll(',', '.').trim()) ?? fallback;

  Future<void> _save() async {
    final s = widget.settings
      ..coefBody = _num(_coefBody, 0.54)
      ..coefLens = _num(_coefLens, 0.40)
      ..minMargin = _num(_margin, 30);
    await s.save();
    if (mounted) Navigator.pop(context, true);
  }

  Future<void> _setDark(bool v) async {
    setState(() => widget.settings.darkTheme = v);
    darkThemeNotifier.value = v;
    await widget.settings.save();
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Réglages')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
        children: [
          AppCard(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
            child: SwitchListTile(
              value: widget.settings.darkTheme,
              onChanged: _setDark,
              secondary: const Icon(Icons.dark_mode_outlined),
              title: const Text('Thème sombre', style: TextStyle(fontWeight: FontWeight.w600)),
            ),
          ),
          const SizedBox(height: 16),
          AppCard(
            padding: EdgeInsets.zero,
            onTap: () => Navigator.push(
                context, MaterialPageRoute(builder: (_) => NetSettingsScreen(settings: widget.settings))),
            child: ListTile(
              leading: const Icon(Icons.receipt_long_outlined),
              title: const Text('Marge nette', style: TextStyle(fontWeight: FontWeight.w600)),
              subtitle: Text(widget.settings.net.home.isEmpty
                  ? 'Ville, trajet, frais Leboncoin, livraison'
                  : '${widget.settings.net.home} · ${widget.settings.net.kmCost} €/km · max ${widget.settings.net.maxKm.toStringAsFixed(0)} km'),
              trailing: const Icon(Icons.chevron_right),
            ),
          ),
          const SizedBox(height: 16),
          AppCard(
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Text('Catalogue MPB', style: t.titleLarge?.copyWith(fontSize: 18)),
              const SizedBox(height: 4),
              Text(
                  !_catalogLoaded
                      ? '…'
                      : _catalog == null
                          ? 'Pas encore téléchargé : il le sera à la prochaine analyse.'
                          : '${_catalog!.size} noms exacts de modèles, mis à jour le '
                              '${shortDate(_catalog!.date)}. Rafraîchi automatiquement chaque semaine.',
                  style: TextStyle(color: cs.onSurfaceVariant)),
              const SizedBox(height: 10),
              FilledButton.tonalIcon(
                onPressed: _catalog == null
                    ? null
                    : () => Navigator.push(context, MaterialPageRoute(builder: (_) => const CatalogScreen())),
                icon: const Icon(Icons.list_alt),
                label: const Text('Voir le catalogue (modèles et identifiants)'),
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: _catalog == null ? null : _refreshCatalog,
                icon: const Icon(Icons.refresh),
                label: const Text('Retélécharger le catalogue'),
              ),
            ]),
          ),
          const SizedBox(height: 16),
          AppCard(
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Text('Calcul de secours', style: t.titleLarge?.copyWith(fontSize: 18)),
              const SizedBox(height: 4),
              Text(
                  'La reprise vient du prix réel de MPB pour l\'état de l\'annonce. '
                  'Les coefficients ne servent que si cette API ne répond pas : '
                  'revente MPB en état Bon × coefficient (estimation approximative).',
                  style: TextStyle(color: cs.onSurfaceVariant)),
              const SizedBox(height: 16),
              Row(children: [
                Expanded(
                  child: TextField(
                    controller: _coefBody,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    decoration: const InputDecoration(labelText: 'Coef boîtiers'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    controller: _coefLens,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    decoration: const InputDecoration(labelText: 'Coef objectifs'),
                  ),
                ),
              ]),
              const SizedBox(height: 12),
              TextField(
                controller: _margin,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                    labelText: 'Marge mini pour « bonne affaire »', suffixText: '€'),
              ),
            ]),
          ),
          const SizedBox(height: 16),
          AppCard(
            padding: EdgeInsets.zero,
            onTap: () => Navigator.push(
                context, MaterialPageRoute(builder: (_) => const RadarLogScreen())),
            child: const ListTile(
              leading: Icon(Icons.receipt_long_outlined),
              title: Text('Journal du radar', style: TextStyle(fontWeight: FontWeight.w600)),
              trailing: Icon(Icons.chevron_right),
            ),
          ),
          const SizedBox(height: 20),
          FilledButton.icon(
              onPressed: _save, icon: const Icon(Icons.check), label: const Text('Enregistrer')),
        ],
      ),
    );
  }
}
