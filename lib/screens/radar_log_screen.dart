import 'package:flutter/material.dart';

import '../radar/radar_db.dart';

/// Journal interne du radar (notifications reçues, pages chargées, analyses, erreurs).
class RadarLogScreen extends StatefulWidget {
  const RadarLogScreen({super.key});

  @override
  State<RadarLogScreen> createState() => _RadarLogScreenState();
}

class _RadarLogScreenState extends State<RadarLogScreen> {
  List<RadarLogRow> _logs = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final l = await RadarDb.logs();
    if (mounted) setState(() => _logs = l);
  }

  String _time(DateTime d) =>
      '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')} '
      '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}:'
      '${d.second.toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Journal du radar'),
        actions: [
          IconButton(icon: const Icon(Icons.refresh), onPressed: _load),
          IconButton(
            icon: const Icon(Icons.delete_sweep_outlined),
            onPressed: () async {
              await RadarDb.clearLogs();
              _load();
            },
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView.builder(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
          itemCount: _logs.length,
          itemBuilder: (_, i) => Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(_time(_logs[i].at),
                  style: TextStyle(fontSize: 11.5, color: cs.onSurfaceVariant, fontFeatures: const [FontFeature.tabularFigures()])),
              const SizedBox(width: 8),
              Expanded(child: Text(_logs[i].msg, style: const TextStyle(fontSize: 12.5))),
            ]),
          ),
        ),
      ),
    );
  }
}
