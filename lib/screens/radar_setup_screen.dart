import 'package:flutter/material.dart';

import '../radar/radar_bridge.dart';
import '../radar/radar_db.dart';
import '../theme.dart';
import '../widgets/common.dart';

/// Mise en route du radar : les 3 autorisations (vert/rouge) et le filet de sécurité.
class RadarSetupScreen extends StatefulWidget {
  const RadarSetupScreen({super.key});

  @override
  State<RadarSetupScreen> createState() => _RadarSetupScreenState();
}

class _RadarSetupScreenState extends State<RadarSetupScreen> with WidgetsBindingObserver {
  RadarPermissions? _p;
  bool _periodic = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState s) {
    if (s == AppLifecycleState.resumed) _load(); // retour des réglages Android
  }

  Future<void> _load() async {
    final p = await RadarBridge.status();
    final periodic = await RadarDb.get('periodic') == '1';
    if (mounted) {
      setState(() {
        _p = p;
        _periodic = periodic;
      });
    }
  }

  Future<void> _setPeriodic(bool v) async {
    await RadarBridge.setPeriodic(v);
    await RadarDb.set('periodic', v ? '1' : '0');
    await RadarDb.log(v ? 'Filet de sécurité activé (toutes les 60 min)' : 'Filet de sécurité désactivé');
    _load();
  }

  Widget _row(String title, String help, bool ok, String action, VoidCallback onTap) {
    final cs = Theme.of(context).colorScheme;
    return AppCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(ok ? Icons.check_circle : Icons.cancel, color: ok ? AppColors.good : AppColors.bad),
          const SizedBox(width: 10),
          Expanded(child: Text(title, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15.5))),
        ]),
        const SizedBox(height: 6),
        Text(help, style: TextStyle(color: cs.onSurfaceVariant, fontSize: 13)),
        if (!ok) ...[
          const SizedBox(height: 10),
          FilledButton.tonal(onPressed: onTap, child: Text(action)),
        ],
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = _p;
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Mise en route du radar')),
      body: p == null
          ? const Center(child: Text('Disponible seulement sur Android.'))
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
              children: [
                _row(
                  'Accès aux notifications',
                  'Pour détecter les notifications « De nouveaux résultats sont disponibles » '
                      'de tes recherches Leboncoin. Active « MPB Check Radar » dans la liste.',
                  p.notificationAccess,
                  'Ouvrir les réglages',
                  RadarBridge.openNotificationAccess,
                ),
                const SizedBox(height: 10),
                _row(
                  'Optimisation de la batterie désactivée',
                  'Obligatoire : c\'est ce qui autorise le radar à démarrer en arrière-plan '
                      '(Android 12 et plus).',
                  p.batteryExempt,
                  'Autoriser',
                  RadarBridge.requestBatteryExempt,
                ),
                const SizedBox(height: 10),
                _row(
                  'Notifications de MPB Check',
                  'Pour t\'avertir des bonnes affaires et des vérifications Leboncoin.',
                  p.notificationsAllowed,
                  'Autoriser',
                  RadarBridge.requestNotifications,
                ),
                const SizedBox(height: 16),
                AppCard(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                  child: SwitchListTile(
                    value: _periodic,
                    onChanged: _setPeriodic,
                    title: const Text('Filet de sécurité', style: TextStyle(fontWeight: FontWeight.w600)),
                    subtitle: const Text('Relance les recherches actives toutes les 60 min au cas où une '
                        'notification aurait été manquée. Mêmes limites.'),
                  ),
                ),
                if (p.firstPackage != null) ...[
                  const SizedBox(height: 12),
                  Text('Package Leboncoin détecté : ${p.firstPackage}',
                      style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12.5)),
                ],
              ],
            ),
    );
  }
}
