import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../radar/native_browser.dart';
import '../radar/radar_bridge.dart';
import '../radar/radar_db.dart';
import '../secrets.dart';
import '../services/gemini_service.dart';
import '../services/local_identifier.dart';
import '../services/mpb_catalog.dart';
import '../theme.dart';
import '../widgets/common.dart';
import 'radar_setup_screen.dart';
import 'radar_trigger_screen.dart';

enum _St { wait, run, ok, warn, fail }

class _Check {
  final String name;
  _St st = _St.wait;
  String detail = '';
  Duration? took;
  _Check(this.name);
}

/// Test global, lancé à la main : vérifie tout ce dont l'appli a besoin et
/// produit un rapport (copiable).
class RadarTestScreen extends StatefulWidget {
  const RadarTestScreen({super.key});

  @override
  State<RadarTestScreen> createState() => _RadarTestScreenState();
}

class _RadarTestScreenState extends State<RadarTestScreen> {
  final _checks = <_Check>[];
  bool _running = false;
  DateTime? _at;

  Future<void> _step(_Check c, Future<(_St, String)> Function() body) async {
    setState(() => c.st = _St.run);
    final sw = Stopwatch()..start();
    try {
      final (st, detail) = await body().timeout(const Duration(seconds: 90));
      c.st = st;
      c.detail = detail;
    } catch (e) {
      c.st = _St.fail;
      c.detail = e.toString().replaceFirst('Exception: ', '');
    }
    c.took = sw.elapsed;
    if (mounted) setState(() {});
  }

  Future<void> _run() async {
    final names = [
      'Autorisations',
      'Écoute des notifications',
      'Notification déclencheur',
      'Service en arrière-plan',
      'Chien de garde',
      'API Gemini (chaque clé)',
      'Catalogue MPB',
      'Identification sans IA',
      'API MPB (prix de reprise réel)',
      'Leboncoin (page de recherche)',
      'État du radar',
    ];
    setState(() {
      _running = true;
      _at = DateTime.now();
      _checks
        ..clear()
        ..addAll(names.map(_Check.new));
    });
    final c = {for (final x in _checks) x.name: x};
    final perms = await RadarBridge.status();

    await _step(c['Autorisations']!, () async {
      if (perms == null) return (_St.fail, 'Disponible seulement sur Android');
      final missing = [
        if (!perms.notificationAccess) 'accès aux notifications',
        if (!perms.batteryExempt) 'optimisation de batterie active',
        if (!perms.notificationsAllowed) 'notifications de l\'appli',
        if (perms.backgroundRestricted) 'arrière-plan restreint',
      ];
      return missing.isEmpty ? (_St.ok, 'Tout est autorisé') : (_St.fail, 'Manque : ${missing.join(', ')}');
    });

    await _step(c['Écoute des notifications']!, () async {
      if (perms == null) return (_St.fail, '—');
      final recent = await RadarBridge.recentNotifs();
      final last = recent.isEmpty ? 'aucune notification Leboncoin vue pour le moment' : 'dernière vue ${shortDate(recent.first.at)}';
      return perms.listenerConnected ? (_St.ok, 'Branchée ; $last') : (_St.fail, 'Débranchée ; $last');
    });

    await _step(c['Notification déclencheur']!, () async {
      final t = await RadarBridge.trigger();
      return t.text == null
          ? (_St.warn, 'Réglage par défaut (« nouveaux résultats »). Choisis la notification exacte ci-dessous.')
          : (_St.ok, '« ${t.text} »${t.channel == null ? '' : ' · canal ${t.channel}'}');
    });

    await _step(c['Service en arrière-plan']!, () async {
      final since = DateTime.now();
      await RadarBridge.start('test');
      for (var i = 0; i < 30; i++) {
        await Future.delayed(const Duration(seconds: 1));
        final logs = await RadarDb.logs();
        if (logs.any((l) => l.msg.startsWith('Test global') && l.at.isAfter(since.subtract(const Duration(seconds: 1))))) {
          return (_St.ok, 'Démarré et terminé en ${i + 1} s');
        }
      }
      return (_St.fail, 'Le service n\'a pas répondu en 30 s (batterie restreinte ?)');
    });

    await _step(c['Chien de garde']!, () async {
      final w = perms?.watchdogLast;
      if (w == null) return (_St.warn, 'Pas encore passé (il tourne toutes les 15 min)');
      final ago = DateTime.now().difference(w);
      return ago.inMinutes <= 40
          ? (_St.ok, 'Dernier contrôle ${shortDate(w)}${perms?.problem == null ? '' : ' · problème : ${perms!.problem}'}')
          : (_St.warn, 'Dernier contrôle il y a ${ago.inMinutes} min (Android le retarde)');
    });

    await _step(c['API Gemini (chaque clé)']!, () async {
      final res = <String>[];
      var ok = 0;
      for (var i = 0; i < geminiKeys.length; i++) {
        final r = await GeminiService().testKey(geminiKeys[i]);
        res.add('clé ${i + 1} : $r');
        if (r == 'OK') ok++;
      }
      return (ok == geminiKeys.length ? _St.ok : ok > 0 ? _St.warn : _St.fail, res.join(' · '));
    });

    MpbCatalog? catalog;
    await _step(c['Catalogue MPB']!, () async {
      catalog = await MpbCatalog.load();
      if (catalog == null) return (_St.warn, 'Pas encore téléchargé (il le sera à la prochaine analyse)');
      return (catalog!.size > 1000 ? _St.ok : _St.warn, '${catalog!.size} modèles, du ${shortDate(catalog!.date)}');
    });

    await _step(c['Identification sans IA']!, () async {
      final cat = catalog;
      if (cat == null) return (_St.warn, 'Nécessite le catalogue MPB');
      final r = LocalIdentifier(cat).identify('Canon 1200D + objectif 18-55 IS II', '8000 déclenchements', '');
      final names = r.items.map((i) => i.mpbModel).join(' + ');
      return r.items.isEmpty ? (_St.fail, 'Rien reconnu dans l\'annonce de test') : (_St.ok, '« Canon 1200D + 18-55 IS II » → $names');
    });

    await _step(c['API MPB (prix de reprise réel)']!, () async {
      final mpb = NativeMpbFetch().service();
      final id = await mpb.modelId('Canon EOS 1200D');
      if (id == null) return (_St.fail, 'Identifiant MPB introuvable');
      final p = await mpb.purchasePrice(id, 'good');
      return (_St.ok, 'Canon EOS 1200D (id $id), état Bon : ${p.toStringAsFixed(0)} €');
    });

    await _step(c['Leboncoin (page de recherche)']!, () async {
      final searches = await RadarDb.searches();
      final url = searches.isEmpty
          ? 'https://www.leboncoin.fr/recherche?category=16&sort=time'
          : searches.first.url;
      await RadarDb.addPageLoad('search');
      final b = NativeBrowser('test');
      final page = await loadSearchPage(b, url);
      await b.dispose();
      if (page.blocked) return (_St.fail, 'Leboncoin demande une vérification (à faire depuis le radar)');
      if (!page.ok) return (_St.fail, page.error ?? 'Lecture impossible');
      final recent = page.ads.where((a) => a.date != null).toList();
      return (_St.ok, '${page.ads.length} annonces lues${searches.isEmpty ? ' (recherche de test)' : ' (« ${searches.first.name} »)'}'
          '${recent.isEmpty ? '' : ', la plus récente : « ${recent.first.subject} »'}');
    });

    await _step(c['État du radar']!, () async {
      final st = await RadarDb.state();
      final searches = await RadarDb.searches();
      final active = searches.where((s) => s.active).length;
      if (perms != null && !perms.enabled) return (_St.warn, 'Radar désactivé');
      return switch (st) {
        RadarState.verify => (_St.fail, 'Vérification Leboncoin en attente'),
        RadarState.paused => (_St.warn, 'En pause (erreurs réseau)'),
        _ => (active == 0 ? _St.warn : _St.ok, 'Actif · $active recherche(s) surveillée(s)'),
      };
    });

    await RadarDb.log('Test global : ${_checks.where((x) => x.st == _St.ok).length}/${_checks.length} OK');
    if (mounted) setState(() => _running = false);
  }

  String get _report {
    final b = StringBuffer('Test global MPB Check — ${_at == null ? '' : shortDate(_at!)}\n');
    for (final c in _checks) {
      final icon = switch (c.st) { _St.ok => '✅', _St.warn => '⚠️', _St.fail => '❌', _ => '…' };
      b.writeln('$icon ${c.name} : ${c.detail}');
    }
    return b.toString();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final ok = _checks.where((c) => c.st == _St.ok).length;
    final fail = _checks.where((c) => c.st == _St.fail).length;
    return Scaffold(
      appBar: AppBar(title: const Text('Test global')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
        children: [
          Text('Vérifie les autorisations, l\'écoute des notifications, le service en arrière-plan, '
              'les clés Gemini, MPB et Leboncoin (1 page chargée).',
              style: TextStyle(color: cs.onSurfaceVariant)),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: _running ? null : _run,
            icon: _running
                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.fact_check_outlined),
            label: Text(_running ? 'Test en cours…' : 'Faire un test global'),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const RadarTriggerScreen())),
            icon: const Icon(Icons.hearing),
            label: const Text('Choisir la notification à écouter'),
          ),
          if (_checks.isNotEmpty) ...[
            const SizedBox(height: 16),
            if (!_running)
              AppCard(
                child: Row(children: [
                  Icon(fail == 0 ? Icons.check_circle : Icons.error,
                      color: fail == 0 ? AppColors.good : AppColors.bad, size: 30),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      fail == 0 ? 'Tout fonctionne ($ok/${_checks.length})' : '$fail problème(s) sur ${_checks.length}',
                      style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 17),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Copier le rapport',
                    icon: const Icon(Icons.copy),
                    onPressed: () {
                      Clipboard.setData(ClipboardData(text: _report));
                      ScaffoldMessenger.of(context)
                          .showSnackBar(const SnackBar(content: Text('Rapport copié')));
                    },
                  ),
                ]),
              ),
            const SizedBox(height: 10),
            for (final c in _checks) ...[
              AppCard(
                padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
                onTap: c.name == 'Autorisations' || c.name == 'Écoute des notifications'
                    ? () => Navigator.push(context, MaterialPageRoute(builder: (_) => const RadarSetupScreen()))
                    : c.name == 'Notification déclencheur'
                        ? () => Navigator.push(
                            context, MaterialPageRoute(builder: (_) => const RadarTriggerScreen()))
                        : null,
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  SizedBox(
                    width: 26,
                    child: switch (c.st) {
                      _St.run => const SizedBox(
                          width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2.2)),
                      _St.ok => const Icon(Icons.check_circle, color: AppColors.good),
                      _St.warn => const Icon(Icons.warning_amber_rounded, color: AppColors.warn),
                      _St.fail => const Icon(Icons.cancel, color: AppColors.bad),
                      _St.wait => Icon(Icons.radio_button_unchecked, color: cs.outlineVariant),
                    },
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(c.name, style: const TextStyle(fontWeight: FontWeight.w700)),
                      if (c.detail.isNotEmpty)
                        Text(c.detail, style: TextStyle(color: cs.onSurfaceVariant, fontSize: 13)),
                    ]),
                  ),
                  if (c.took != null)
                    Text('${(c.took!.inMilliseconds / 1000).toStringAsFixed(1)} s',
                        style: TextStyle(color: cs.onSurfaceVariant, fontSize: 11.5)),
                ]),
              ),
              const SizedBox(height: 8),
            ],
          ],
        ],
      ),
    );
  }
}
