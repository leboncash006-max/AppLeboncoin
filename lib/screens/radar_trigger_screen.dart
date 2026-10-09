import 'dart:async';

import 'package:flutter/material.dart';

import '../radar/radar_bridge.dart';
import '../radar/radar_db.dart';
import '../theme.dart';
import '../widgets/common.dart';

/// Choix de la notification Leboncoin qui déclenche le radar. Les autres
/// notifications Leboncoin (messages, offres…) sont ignorées et jamais retirées.
class RadarTriggerScreen extends StatefulWidget {
  const RadarTriggerScreen({super.key});

  @override
  State<RadarTriggerScreen> createState() => _RadarTriggerScreenState();
}

class _RadarTriggerScreenState extends State<RadarTriggerScreen> {
  List<LbcNotif> _list = [];
  ({String? text, String? channel}) _trigger = (text: null, channel: null);
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _load();
    // on attend la bonne notification : rafraîchissement automatique
    _timer = Timer.periodic(const Duration(seconds: 3), (_) => _load());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    final l = await RadarBridge.recentNotifs();
    final t = await RadarBridge.trigger();
    if (mounted) {
      setState(() {
        _list = l;
        _trigger = t;
      });
    }
  }

  Future<void> _choose(LbcNotif n) async {
    await RadarBridge.setTrigger(n.text, n.channel.isEmpty ? null : n.channel);
    await RadarDb.log('Déclencheur choisi : « ${n.text} » (canal ${n.channel.isEmpty ? '?' : n.channel})');
    await _load();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Le radar écoutera seulement les notifications « ${n.text} ».')));
  }

  Future<void> _reset() async {
    await RadarBridge.setTrigger(null, null);
    await RadarDb.log('Déclencheur : réglage par défaut (« nouveaux résultats »)');
    _load();
  }

  bool _isCurrent(LbcNotif n) =>
      _trigger.text != null && n.text == _trigger.text && (_trigger.channel == null || n.channel == _trigger.channel);

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Notification à écouter')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
        children: [
          AppCard(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('Déclencheur actuel', style: TextStyle(fontWeight: FontWeight.w700)),
              const SizedBox(height: 4),
              Text(
                _trigger.text == null
                    ? 'Par défaut : notifications dont le texte contient « nouveaux résultats ».'
                    : '« ${_trigger.text} »${_trigger.channel == null ? '' : ' · canal ${_trigger.channel}'}',
                style: TextStyle(color: cs.onSurfaceVariant),
              ),
              if (_trigger.text != null)
                TextButton(onPressed: _reset, child: const Text('Revenir au réglage par défaut')),
            ]),
          ),
          const SizedBox(height: 12),
          Text(
            'Attends une notification de recherche Leboncoin, reviens ici et appuie sur '
            '« Écouter celle-ci ». Seules les notifications de ce type lanceront le radar '
            '(le titre = nom de la recherche). La liste se met à jour toute seule.',
            style: TextStyle(color: cs.onSurfaceVariant, fontSize: 13),
          ),
          const SizedBox(height: 12),
          if (_list.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 32),
              child: Column(children: [
                const SizedBox(width: 26, height: 26, child: CircularProgressIndicator(strokeWidth: 2.4)),
                const SizedBox(height: 12),
                Text('En attente d\'une notification Leboncoin…', style: TextStyle(color: cs.onSurfaceVariant)),
              ]),
            ),
          for (final n in _list) ...[
            AppCard(
              padding: const EdgeInsets.fromLTRB(16, 12, 12, 8),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Expanded(
                    child: Text(n.title.isEmpty ? '(sans titre)' : n.title,
                        style: const TextStyle(fontWeight: FontWeight.w700)),
                  ),
                  if (_isCurrent(n)) const Pill(label: 'Écoutée', color: AppColors.good, icon: Icons.hearing),
                ]),
                const SizedBox(height: 2),
                Text(n.text, style: TextStyle(color: cs.onSurfaceVariant)),
                const SizedBox(height: 2),
                Text('${shortDate(n.at)}${n.active ? ' · affichée' : ''} · ${n.pkg}${n.channel.isEmpty ? '' : ' · ${n.channel}'}',
                    style: TextStyle(color: cs.onSurfaceVariant, fontSize: 11.5)),
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton.icon(
                    onPressed: _isCurrent(n) ? null : () => _choose(n),
                    icon: const Icon(Icons.hearing, size: 18),
                    label: const Text('Écouter celle-ci'),
                  ),
                ),
              ]),
            ),
            const SizedBox(height: 8),
          ],
        ],
      ),
    );
  }
}
