import 'package:flutter/material.dart';

import '../services/settings.dart';

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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Réglages')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('Calcul de la reprise', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 4),
          const Text('Reprise estimée = prix de revente MPB en état Bon × coefficient, '
              'quand le modèle n\'a pas de vraie estimation enregistrée.'),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(
              child: TextField(
                controller: _coefBody,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(
                    labelText: 'Coef boîtiers', border: OutlineInputBorder()),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: TextField(
                controller: _coefLens,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(
                    labelText: 'Coef objectifs', border: OutlineInputBorder()),
              ),
            ),
          ]),
          const SizedBox(height: 12),
          TextField(
            controller: _margin,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
                labelText: 'Marge mini pour « bonne affaire » (€)',
                border: OutlineInputBorder()),
          ),
          const SizedBox(height: 24),
          FilledButton.icon(
              onPressed: _save, icon: const Icon(Icons.save), label: const Text('Enregistrer')),
        ],
      ),
    );
  }
}
