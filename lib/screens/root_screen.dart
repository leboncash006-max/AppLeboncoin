import 'package:flutter/material.dart';

import '../radar/radar_bridge.dart';
import '../radar/radar_db.dart';
import '../services/settings.dart';
import 'home_screen.dart';
import 'radar_screen.dart';
import 'radar_verify_screen.dart';
import 'result_screen.dart';

/// Onglets « Analyse » et « Radar ». Gère aussi l'ouverture depuis une
/// notification du radar (bonne affaire ou vérification Leboncoin).
class RootScreen extends StatefulWidget {
  final Settings settings;
  const RootScreen({super.key, required this.settings});

  @override
  State<RootScreen> createState() => _RootScreenState();
}

class _RootScreenState extends State<RootScreen> {
  int _tab = 0;

  @override
  void initState() {
    super.initState();
    RadarBridge.onLaunch(_handleLaunch);
    WidgetsBinding.instance.addPostFrameCallback((_) => _handleLaunch());
  }

  Future<void> _handleLaunch() async {
    final l = await RadarBridge.takeLaunch();
    if (l == null || !mounted) return;
    final nav = Navigator.of(context);
    nav.popUntil((r) => r.isFirst);
    setState(() => _tab = 1);
    final id = l['open_analysis'];
    final verify = l['radar_verify'];
    if (id != null) {
      final a = await RadarDb.analysis(id);
      if (a == null || !mounted) return;
      final entry = a.entry;
      await nav.push(MaterialPageRoute(
          builder: (_) => ResultScreen(entry: entry, settings: widget.settings)));
      await RadarDb.updateEntry(id, entry); // conserve la conversation
    } else if (verify != null) {
      await nav.push(MaterialPageRoute(builder: (_) => RadarVerifyScreen(url: verify)));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(index: _tab, children: [
        HomeScreen(settings: widget.settings),
        RadarScreen(settings: widget.settings, visible: _tab == 1),
      ]),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (i) => setState(() => _tab = i),
        height: 66,
        destinations: const [
          NavigationDestination(icon: Icon(Icons.bolt_outlined), selectedIcon: Icon(Icons.bolt), label: 'Analyse'),
          NavigationDestination(icon: Icon(Icons.radar_outlined), selectedIcon: Icon(Icons.radar), label: 'Radar'),
        ],
      ),
    );
  }
}
