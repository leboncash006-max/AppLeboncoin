import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import '../radar/radar_db.dart';
import '../screens/result_screen.dart' show openExternal;
import '../theme.dart';
import 'common.dart';

/// « En direct » : ce que fait le radar à l'instant (recherche, annonce n/m,
/// étape, résultat) et ses dernières actions. Rafraîchi chaque seconde.
class RadarLiveCard extends StatefulWidget {
  final bool active; // onglet affiché et appli au premier plan
  const RadarLiveCard({super.key, required this.active});

  @override
  State<RadarLiveCard> createState() => _RadarLiveCardState();
}

class _RadarLiveCardState extends State<RadarLiveCard> with SingleTickerProviderStateMixin {
  Map<String, dynamic> _live = const {};
  List<RadarLogRow> _logs = const [];
  Timer? _timer;
  late final _pulse = AnimationController(vsync: this, duration: const Duration(milliseconds: 900))
    ..repeat(reverse: true);

  @override
  void initState() {
    super.initState();
    _sync();
  }

  @override
  void didUpdateWidget(RadarLiveCard old) {
    super.didUpdateWidget(old);
    if (old.active != widget.active) _sync();
  }

  void _sync() {
    _timer?.cancel();
    if (widget.active) {
      _read();
      _timer = Timer.periodic(const Duration(seconds: 1), (_) => _read());
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _pulse.dispose();
    super.dispose();
  }

  Future<void> _read() async {
    try {
      final raw = await RadarDb.get('live');
      final logs = await RadarDb.logs(limit: 6);
      if (!mounted) return;
      setState(() {
        _live = raw == null ? const {} : Map<String, dynamic>.from(jsonDecode(raw) as Map);
        _logs = logs;
      });
    } catch (_) {}
  }

  String _ago(DateTime t) {
    final d = DateTime.now().difference(t);
    if (d.inSeconds < 60) return 'il y a ${d.inSeconds} s';
    if (d.inMinutes < 60) return 'il y a ${d.inMinutes} min';
    return shortDate(t);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final ts = _live['ts'] == null ? null : DateTime.fromMillisecondsSinceEpoch((_live['ts'] as num).toInt());
    final running = _live['running'] == true;
    // en cours mais plus de nouvelles depuis 3 min : service probablement coupé
    final stale = running && ts != null && DateTime.now().difference(ts) > const Duration(minutes: 3);
    final ad = _live['ad'] as Map?;
    final index = (_live['index'] as num?)?.toInt();
    final total = (_live['total'] as num?)?.toInt();
    final color = stale ? AppColors.warn : (running ? AppColors.good : cs.onSurfaceVariant);
    final label = stale ? 'Interrompu ?' : (running ? 'En direct' : 'En attente');

    return AppCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          FadeTransition(
            opacity: running && !stale ? _pulse : const AlwaysStoppedAnimation(1),
            child: Container(width: 10, height: 10, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
          ),
          const SizedBox(width: 8),
          Text(label, style: TextStyle(fontWeight: FontWeight.w800, color: color)),
          const Spacer(),
          if (ts != null)
            Text(running ? _ago(ts) : 'dernier passage ${_ago(ts)}',
                style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
        ]),
        const SizedBox(height: 10),
        if (!running)
          Text(
            ts == null
                ? 'Le radar n\'a pas encore tourné. Il démarre à la prochaine notification Leboncoin.'
                : 'Le radar attend la prochaine notification Leboncoin.',
            style: TextStyle(color: cs.onSurfaceVariant),
          )
        else ...[
          if (_live['search'] != null)
            Text('Recherche « ${_live['search']} »',
                style: TextStyle(fontSize: 12.5, color: cs.onSurfaceVariant, fontWeight: FontWeight.w600)),
          if (ad != null) ...[
            const SizedBox(height: 4),
            InkWell(
              onTap: ad['url'] == null ? null : () => openExternal(ad['url'] as String),
              child: Row(children: [
                Expanded(
                  child: Text('${ad['title']}',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15.5)),
                ),
                const SizedBox(width: 8),
                Text(euros((ad['price'] as num?)?.toDouble()),
                    style: TextStyle(fontWeight: FontWeight.w800, color: cs.primary, fontFeatures: tabular)),
              ]),
            ),
            if (index != null && total != null) ...[
              const SizedBox(height: 8),
              Row(children: [
                Expanded(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(6),
                    child: LinearProgressIndicator(value: total == 0 ? null : index / total, minHeight: 6),
                  ),
                ),
                const SizedBox(width: 8),
                Text('Annonce $index/$total', style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
              ]),
            ],
          ],
          const SizedBox(height: 8),
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(Icons.subdirectory_arrow_right, size: 18, color: cs.primary),
            const SizedBox(width: 6),
            Expanded(
              child: Text('${_live['step'] ?? '…'}', style: const TextStyle(fontWeight: FontWeight.w600)),
            ),
          ]),
          if (_live['detail'] != null)
            Padding(
              padding: const EdgeInsets.only(left: 24, top: 2),
              child: Text('${_live['detail']}', style: TextStyle(fontSize: 12.5, color: cs.onSurfaceVariant)),
            ),
        ],
        if (_logs.isNotEmpty) ...[
          const Divider(height: 22),
          for (final l in _logs)
            Padding(
              padding: const EdgeInsets.only(bottom: 3),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('${l.at.hour.toString().padLeft(2, '0')}:${l.at.minute.toString().padLeft(2, '0')}:'
                    '${l.at.second.toString().padLeft(2, '0')}',
                    style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant, fontFeatures: tabular)),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(l.msg.trim(),
                      maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12)),
                ),
              ]),
            ),
        ],
      ]),
    );
  }
}
