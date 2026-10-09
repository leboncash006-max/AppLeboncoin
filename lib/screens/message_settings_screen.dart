import 'package:flutter/material.dart';

import '../messages/message_settings.dart';
import '../widgets/common.dart';

/// Réglages des messages aux vendeurs : mode, test à blanc, ton, consignes, plafond.
class MessageSettingsScreen extends StatefulWidget {
  const MessageSettingsScreen({super.key});

  @override
  State<MessageSettingsScreen> createState() => _MessageSettingsScreenState();
}

class _MessageSettingsScreenState extends State<MessageSettingsScreen> {
  MessageSettings? _s;
  final _instructions = TextEditingController();

  @override
  void initState() {
    super.initState();
    MessageSettings.load().then((s) {
      if (!mounted) return;
      _instructions.text = s.instructions;
      setState(() => _s = s);
    });
  }

  @override
  void dispose() {
    _instructions.dispose();
    super.dispose();
  }

  Future<void> _set(void Function(MessageSettings s) f) async {
    final s = _s!;
    setState(() => f(s));
    await s.save();
  }

  @override
  Widget build(BuildContext context) {
    final s = _s;
    final cs = Theme.of(context).colorScheme;
    if (s == null) return const Scaffold(body: Center(child: CircularProgressIndicator()));
    Widget title(String t) => Padding(
          padding: const EdgeInsets.fromLTRB(4, 18, 4, 8),
          child: Text(t, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
        );
    return Scaffold(
      appBar: AppBar(title: const Text('Réglages des messages')),
      body: ListView(padding: const EdgeInsets.fromLTRB(16, 0, 16, 32), children: [
        title('Mode d\'envoi'),
        AppCard(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: RadioGroup<SendMode>(
            groupValue: s.mode,
            onChanged: (v) => _set((s) => s.mode = v ?? SendMode.confirm),
            child: const Column(children: [
              RadioListTile(
                value: SendMode.confirm,
                title: Text('Toujours confirmer'),
                subtitle: Text('L\'appli écrit le message, j\'appuie moi-même sur « Envoyer ».'),
              ),
              RadioListTile(
                value: SendMode.direct,
                title: Text('Envoi direct'),
                subtitle: Text('Envoyé dès que j\'appuie sur « Message vendeur ».'),
              ),
              RadioListTile(
                value: SendMode.auto,
                title: Text('Automatique pour les bonnes affaires'),
                subtitle: Text('Le radar envoie seul si tout est sûr (marge ≥ seuil, IA « oui », '
                    'aucune alerte, annonce jamais contactée, prix connu). Sinon : notification « À confirmer ».'),
              ),
            ]),
          ),
        ),
        const SizedBox(height: 10),
        AppCard(
          padding: EdgeInsets.zero,
          child: SwitchListTile(
            value: s.dryRun,
            onChanged: (v) => _set((s) => s.dryRun = v),
            title: const Text('Test à blanc'),
            subtitle: const Text('Tout est fait (ouverture, contact, message écrit) sauf le clic final sur « Envoyer ».'),
          ),
        ),
        title('Le message'),
        AppCard(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('Ton', style: TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            Wrap(spacing: 8, children: [
              for (final t in const ['poli', 'amical', 'direct'])
                ChoiceChip(
                  label: Text(t[0].toUpperCase() + t.substring(1)),
                  selected: s.tone == t,
                  onSelected: (_) => _set((s) => s.tone = t),
                ),
            ]),
            const SizedBox(height: 6),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: s.formal,
              onChanged: (v) => _set((s) => s.formal = v),
              title: Text(s.formal ? 'Vouvoiement' : 'Tutoiement'),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: s.proposePrice,
              onChanged: (v) => _set((s) => s.proposePrice = v),
              title: const Text('Proposer un prix'),
              subtitle: const Text('Prix conseillé (marge visée) quand il est sous le prix demandé.'),
            ),
            const SizedBox(height: 6),
            TextField(
              controller: _instructions,
              maxLines: 3,
              minLines: 2,
              decoration: const InputDecoration(
                labelText: 'Consignes perso',
                hintText: 'ex. je peux venir le chercher ce week-end',
                border: OutlineInputBorder(),
              ),
              onChanged: (v) => s.instructions = v,
              onEditingComplete: () => s.save(),
              onTapOutside: (_) {
                FocusScope.of(context).unfocus();
                s.save();
              },
            ),
            const SizedBox(height: 6),
            Text('Chaque message est rédigé à neuf par l\'IA : jamais deux fois le même texte.',
                style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
          ]),
        ),
        title('Garde-fous (envoi automatique)'),
        AppCard(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Maximum ${s.dailyMax} messages automatiques par jour',
                style: const TextStyle(fontWeight: FontWeight.w600)),
            Slider(
              value: s.dailyMax.toDouble(),
              min: 1,
              max: MessageSettings.maxDailyCap.toDouble(),
              divisions: MessageSettings.maxDailyCap - 1,
              label: '${s.dailyMax}',
              onChanged: (v) => setState(() => s.dailyMax = v.round()),
              onChangeEnd: (_) => s.save(),
            ),
            Text(
              'Non réglables :\n'
              '• ${MessageSettings.maxPerHour} messages par heure au plus\n'
              '• ${MessageSettings.minGap.inMinutes} min minimum entre deux envois, '
              '+ ${MessageSettings.randomGapMinS} à ${MessageSettings.randomGapMaxS} s au hasard\n'
              '• 1 à 3 s entre chaque étape\n'
              '• rien entre ${MessageSettings.quietStartHour} h et ${MessageSettings.quietEndHour} h '
              '(mis en file pour ${MessageSettings.quietEndHour} h)\n'
              '• un seul contact par annonce, et par vendeur sur 24 h\n'
              '• ${MessageSettings.failuresBeforeSuspend} échecs de suite ou une vérification anti-robot : '
              'envoi auto suspendu jusqu\'à ce que je le réactive',
              style: TextStyle(fontSize: 12.5, color: cs.onSurfaceVariant, height: 1.4),
            ),
          ]),
        ),
      ]),
    );
  }
}
