import 'package:flutter/material.dart';

import '../radar/radar_db.dart';
import '../theme.dart';
import '../widgets/common.dart';
import 'radar_searches_screen.dart';

/// Notifications Leboncoin reçues, avec création de recherche en un appui.
class RadarNotifsScreen extends StatefulWidget {
  const RadarNotifsScreen({super.key});

  @override
  State<RadarNotifsScreen> createState() => _RadarNotifsScreenState();
}

class _RadarNotifsScreenState extends State<RadarNotifsScreen> {
  List<RadarNotifRow> _list = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final l = await RadarDb.notifs();
    if (mounted) setState(() => _list = l);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Notifications reçues')),
      body: _list.isEmpty
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Text('Aucune notification Leboncoin reçue pour le moment.',
                    textAlign: TextAlign.center, style: TextStyle(color: cs.onSurfaceVariant)),
              ),
            )
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
              children: [
                for (final n in _list) ...[
                  AppCard(
                    padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
                    child: Row(children: [
                      Expanded(
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text(n.title.isEmpty ? '(sans titre)' : n.title,
                              style: const TextStyle(fontWeight: FontWeight.w700)),
                          Text('${shortDate(n.at)} · ${n.text}',
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12.5)),
                        ]),
                      ),
                      if (n.searchId != null)
                        const Pill(label: 'Surveillée', color: AppColors.good, icon: Icons.check)
                      else
                        TextButton(
                          onPressed: () async {
                            await Navigator.push(context,
                                MaterialPageRoute(builder: (_) => RadarSearchesScreen(createWithName: n.title)));
                            _load();
                          },
                          child: const Text('Créer la recherche'),
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
