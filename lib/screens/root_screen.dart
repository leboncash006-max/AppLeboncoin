import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../radar/radar_bridge.dart';
import '../radar/radar_db.dart';
import '../services/settings.dart';
import 'home_screen.dart';
import 'messages_screen.dart';
import 'radar_screen.dart';
import 'radar_setup_screen.dart';
import 'radar_verify_screen.dart';
import 'result_screen.dart';

/// Onglets « Analyse », « Radar » et « Messages ». Gère aussi l'ouverture depuis une
/// notification du radar (bonne affaire ou vérification Leboncoin).
class RootScreen extends StatefulWidget {
  final Settings settings;
  const RootScreen({super.key, required this.settings});

  @override
  State<RootScreen> createState() => _RootScreenState();
}

class _RootScreenState extends State<RootScreen> {
  int _tab = 0;
  bool _radarBuilt = false; // l'onglet Radar n'est construit qu'au premier affichage
  bool _msgBuilt = false;

  @override
  void initState() {
    super.initState();
    RadarBridge.onLaunch(_handleLaunch);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _handleLaunch();
      _showLastCrash();
    });
  }

  /// Plantage lors du lancement précédent : on affiche le rapport à copier.
  Future<void> _showLastCrash() async {
    final report = await RadarBridge.lastCrash();
    if (report == null || !mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('L\'appli a planté la dernière fois'),
        content: SingleChildScrollView(
          child: SelectableText(report, style: const TextStyle(fontSize: 11)),
        ),
        actions: [
          TextButton(
            onPressed: () => Clipboard.setData(ClipboardData(text: report)),
            child: const Text('Copier'),
          ),
          FilledButton(onPressed: () => Navigator.pop(ctx), child: const Text('OK')),
        ],
      ),
    );
  }

  Future<void> _handleLaunch() async {
    final l = await RadarBridge.takeLaunch();
    if (l == null || !mounted) return;
    final nav = Navigator.of(context);
    nav.popUntil((r) => r.isFirst);
    final toMessages = l['messages'] != null || l['confirm_send'] != null;
    setState(() {
      _tab = toMessages ? 2 : 1;
      if (toMessages) {
        _msgBuilt = true;
      } else {
        _radarBuilt = true;
      }
    });
    if (l['messages'] != null) return;
    final contact = l['contact'] ?? l['confirm_send'];
    if (contact != null) {
      // « Contacter » / « À confirmer » : écran d'envoi du message
      final a = await RadarDb.analysis(contact);
      if (a != null && mounted) await contactSeller(context, a.entry, widget.settings.minMargin);
      return;
    }
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
    } else if (l['radar_setup'] != null) {
      await nav.push(MaterialPageRoute(builder: (_) => const RadarSetupScreen()));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(index: _tab, children: [
        HomeScreen(settings: widget.settings),
        if (_radarBuilt || _tab == 1)
          RadarScreen(settings: widget.settings, visible: _tab == 1)
        else
          const SizedBox.shrink(),
        if (_msgBuilt || _tab == 2)
          MessagesScreen(settings: widget.settings, visible: _tab == 2)
        else
          const SizedBox.shrink(),
      ]),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (i) => setState(() {
          _tab = i;
          if (i == 1) _radarBuilt = true;
          if (i == 2) _msgBuilt = true;
        }),
        height: 66,
        destinations: const [
          NavigationDestination(icon: Icon(Icons.bolt_outlined), selectedIcon: Icon(Icons.bolt), label: 'Analyse'),
          NavigationDestination(icon: Icon(Icons.radar_outlined), selectedIcon: Icon(Icons.radar), label: 'Radar'),
          NavigationDestination(
              icon: Icon(Icons.forum_outlined), selectedIcon: Icon(Icons.forum), label: 'Messages'),
        ],
      ),
    );
  }
}
