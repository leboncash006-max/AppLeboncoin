import 'package:flutter/material.dart';

import '../radar/radar_bridge.dart';
import '../radar/radar_db.dart';
import '../services/settings.dart';
import '../theme.dart';
import '../widgets/common.dart';
import 'radar_log_screen.dart';
import 'radar_notifs_screen.dart';
import 'radar_searches_screen.dart';
import 'radar_setup_screen.dart';
import 'radar_verify_screen.dart';
import 'result_screen.dart';

/// Onglet Radar : état, chiffres du jour et fil des annonces analysées.
class RadarScreen extends StatefulWidget {
  final Settings settings;
  final bool visible;
  const RadarScreen({super.key, required this.settings, required this.visible});

  @override
  State<RadarScreen> createState() => _RadarScreenState();
}

class _RadarScreenState extends State<RadarScreen> with WidgetsBindingObserver {
  List<RadarAnalysis> _feed = [];
  List<RadarSearch> _searches = [];
  int? _filter;
  RadarState _state = RadarState.active;
  RadarPermissions? _perms;
  ({int seen, int analyzed, RadarAnalysis? best})? _today;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
  }

  @override
  void didUpdateWidget(RadarScreen old) {
    super.didUpdateWidget(old);
    if (widget.visible && !old.visible) _load();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState s) {
    if (s == AppLifecycleState.resumed) _load();
  }

  Future<void> _load() async {
    final perms = await RadarBridge.status();
    final searches = await RadarDb.searches();
    final feed = await RadarDb.analyses(searchId: _filter);
    final today = await RadarDb.today();
    var state = await RadarDb.state();
    if (perms != null && !perms.enabled) state = RadarState.off;
    if (!mounted) return;
    setState(() {
      _perms = perms;
      _searches = searches;
      _feed = feed;
      _today = today;
      _state = state;
    });
  }

  Future<void> _open(RadarAnalysis a) async {
    final entry = a.entry;
    await Navigator.push(
        context, MaterialPageRoute(builder: (_) => ResultScreen(entry: entry, settings: widget.settings)));
    await RadarDb.updateEntry(a.listId, entry); // conserve la conversation
    _load();
  }

  Future<void> _push(Widget w) async {
    await Navigator.push(context, MaterialPageRoute(builder: (_) => w));
    _load();
  }

  Future<void> _toggle(bool on) async {
    await RadarBridge.setEnabled(on);
    _load();
  }

  Future<void> _runNow() async {
    await RadarBridge.start('manual');
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Radar lancé sur toutes les recherches actives.')));
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Radar'),
        actions: [
          IconButton(
              tooltip: 'Recherches surveillées',
              icon: const Icon(Icons.manage_search),
              onPressed: () => _push(const RadarSearchesScreen())),
          PopupMenuButton<String>(
            onSelected: (v) => switch (v) {
              'notifs' => _push(const RadarNotifsScreen()),
              'setup' => _push(const RadarSetupScreen()),
              'log' => _push(const RadarLogScreen()),
              _ => _runNow(),
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'run', child: Text('Lancer maintenant')),
              PopupMenuItem(value: 'notifs', child: Text('Notifications reçues')),
              PopupMenuItem(value: 'setup', child: Text('Permissions et réglages')),
              PopupMenuItem(value: 'log', child: Text('Journal')),
            ],
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
          children: [
            if (_perms != null && !_perms!.ready) ...[
              AppCard(
                onTap: () => _push(const RadarSetupScreen()),
                child: const Row(children: [
                  Icon(Icons.settings_suggest_outlined, color: AppColors.warn),
                  SizedBox(width: 12),
                  Expanded(
                    child: Text('Configure le radar : accès aux notifications, batterie, notifications.',
                        style: TextStyle(fontWeight: FontWeight.w600)),
                  ),
                  Icon(Icons.chevron_right),
                ]),
              ),
              const SizedBox(height: 12),
            ],
            _statusCard(cs),
            const SizedBox(height: 12),
            _statsRow(cs),
            const SizedBox(height: 18),
            if (_searches.isEmpty)
              AppCard(
                onTap: () => _push(const RadarSearchesScreen()),
                child: const Row(children: [
                  Icon(Icons.add_circle_outline),
                  SizedBox(width: 12),
                  Expanded(child: Text('Ajoute une recherche Leboncoin à surveiller')),
                ]),
              )
            else
              SizedBox(
                height: 40,
                child: ListView(scrollDirection: Axis.horizontal, children: [
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: ChoiceChip(
                      label: const Text('Toutes'),
                      selected: _filter == null,
                      onSelected: (_) {
                        _filter = null;
                        _load();
                      },
                    ),
                  ),
                  for (final s in _searches)
                    Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: ChoiceChip(
                        label: Text(s.name),
                        selected: _filter == s.id,
                        onSelected: (_) {
                          _filter = s.id;
                          _load();
                        },
                      ),
                    ),
                ]),
              ),
            const SizedBox(height: 12),
            if (_feed.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 32),
                child: Column(children: [
                  Icon(Icons.radar, size: 40, color: cs.onSurfaceVariant),
                  const SizedBox(height: 8),
                  Text('Aucune annonce analysée pour le moment.',
                      style: TextStyle(color: cs.onSurfaceVariant)),
                ]),
              )
            else
              for (final a in _feed) ...[
                _FeedTile(a: a, minMargin: widget.settings.minMargin, onTap: () => _open(a)),
                const SizedBox(height: 8),
              ],
          ],
        ),
      ),
    );
  }

  Widget _statusCard(ColorScheme cs) {
    final (label, color, icon) = switch (_state) {
      RadarState.active => ('Actif', AppColors.good, Icons.radar),
      RadarState.paused => ('En pause (erreurs réseau, 30 min)', AppColors.warn, Icons.pause_circle_outline),
      RadarState.verify => ('Vérification Leboncoin demandée', AppColors.bad, Icons.verified_user_outlined),
      RadarState.off => ('Désactivé', AppColors.neutral, Icons.radar),
    };
    return AppCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Pill(label: label, color: color, icon: icon),
          const Spacer(),
          Switch(value: _state != RadarState.off, onChanged: _toggle),
        ]),
        if (_state == RadarState.verify) ...[
          const SizedBox(height: 10),
          FilledButton.icon(
            onPressed: () async {
              final url = await RadarDb.get('verify_url') ?? 'https://www.leboncoin.fr';
              await _push(RadarVerifyScreen(url: url));
            },
            icon: const Icon(Icons.verified_user_outlined),
            label: const Text('Faire la vérification'),
          ),
        ],
        const SizedBox(height: 6),
        Text(
          '${_searches.where((s) => s.active).length} recherche(s) surveillée(s) · '
          'seuil ${widget.settings.minMargin.toStringAsFixed(0)} €',
          style: TextStyle(color: cs.onSurfaceVariant, fontSize: 13),
        ),
      ]),
    );
  }

  Widget _statsRow(ColorScheme cs) {
    final t = _today;
    Widget stat(String label, String value, {Color? color}) => Expanded(
          child: AppCard(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(value,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800, color: color, fontFeatures: tabular)),
              const SizedBox(height: 2),
              Text(label, style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
            ]),
          ),
        );
    final best = t?.best;
    return Row(children: [
      stat('vues aujourd\'hui', '${t?.seen ?? 0}'),
      const SizedBox(width: 8),
      stat('analysées', '${t?.analyzed ?? 0}'),
      const SizedBox(width: 8),
      stat('meilleure affaire', best == null ? '—' : euros(best.margin, signed: true),
          color: best == null ? null : verdictFor(best.margin, widget.settings.minMargin).color),
    ]);
  }
}

class _FeedTile extends StatelessWidget {
  final RadarAnalysis a;
  final double minMargin;
  final VoidCallback onTap;
  const _FeedTile({required this.a, required this.minMargin, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final v = verdictFor(a.margin, minMargin);
    final stage = switch (a.stage) {
      'full' => '',
      'limit' => ' · provisoire',
      _ => ' · pré-analyse',
    };
    return Opacity(
      opacity: a.profitable ? 1 : 0.55,
      child: AppCard(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        onTap: onTap,
        child: Row(children: [
          Container(width: 6, height: 44, decoration: BoxDecoration(color: v.color, borderRadius: BorderRadius.circular(4))),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(a.title, maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
              const SizedBox(height: 3),
              Text('${euros(a.price)} · ${a.searchName} · ${shortDate(a.createdAt)}$stage',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12.5)),
            ]),
          ),
          const SizedBox(width: 10),
          Text(euros(a.margin, signed: true),
              style: TextStyle(color: v.color, fontWeight: FontWeight.w800, fontSize: 18, fontFeatures: tabular)),
        ]),
      ),
    );
  }
}
