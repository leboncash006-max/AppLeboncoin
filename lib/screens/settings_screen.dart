import 'package:flutter/material.dart';

import '../main.dart';
import '../services/settings.dart';
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
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Text('Calcul de la reprise', style: t.titleLarge?.copyWith(fontSize: 18)),
              const SizedBox(height: 4),
              Text(
                  'Reprise estimée = prix de revente MPB en état Bon × coefficient, '
                  'quand le modèle n\'a pas de vraie estimation enregistrée.',
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
          const SizedBox(height: 20),
          FilledButton.icon(
              onPressed: _save, icon: const Icon(Icons.check), label: const Text('Enregistrer')),
        ],
      ),
    );
  }
}
