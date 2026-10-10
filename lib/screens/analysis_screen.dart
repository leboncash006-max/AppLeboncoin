import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../services/ad_extras.dart';
import '../services/v3_models.dart';
import '../services/analyzer.dart';
import '../services/history.dart';
import '../services/leboncoin_reader.dart';
import '../services/mpb_catalog.dart';
import '../services/mpb_service.dart';
import '../services/mpb_web_transport.dart';
import '../services/settings.dart';
import '../theme.dart';
import '../widgets/common.dart';
import 'result_screen.dart';

/// Annonce saisie à la main (mode texte).
class ManualAd {
  final String title;
  final String description;
  final double? price;
  ManualAd(this.title, this.description, this.price);
}

/// Lance la lecture de l'annonce puis l'analyse, en affichant les étapes.
/// Une fois terminé, remplace l'écran par le résultat.
class AnalysisScreen extends StatefulWidget {
  final Settings settings;
  final Uri? url;
  final ManualAd? manual;
  const AnalysisScreen({super.key, required this.settings, this.url, this.manual})
      : assert(url != null || manual != null);

  @override
  State<AnalysisScreen> createState() => _AnalysisScreenState();
}

const _stepLabels = [
  "Lecture de l'annonce",
  'Identification',
  'Catalogue MPB',
  'Calcul',
];

class _AnalysisScreenState extends State<AnalysisScreen> {
  int _step = 0;
  String? _detail;
  String? _error;
  bool _blocked = false;
  bool _webOpen = false;
  bool _cancelled = false;
  WebViewController? _web;

  /// mpb.com ouvert dans une WebView : les appels MPB passent par elle.
  late final MpbWebTransport _mpbWeb = MpbWebTransport()
    ..onChallenge = () {
      if (!mounted) return;
      HapticFeedback.mediumImpact();
      setState(() {
        _mpbOpen = true;
        _mpbChallenge = true;
        _detail = 'MPB demande une vérification : fais-la ci-dessous si elle s\'affiche.';
      });
    };
  late final MpbService _mpb = MpbService(null, _mpbWeb.fetch);

  /// Catalogue des noms exacts MPB, préparé pendant la lecture de l'annonce.
  late final Future<MpbCatalog?> _catalog = MpbCatalog.ensure(_mpb, onStatus: (st) {
    if (mounted && _step >= 1 && _error == null) setState(() => _detail = st);
  });
  bool _mpbOpen = false;
  bool _mpbChallenge = false;

  @override
  void initState() {
    super.initState();
    _catalog; // démarre tout de suite, en parallèle de la lecture Leboncoin
    _start();
  }

  @override
  void dispose() {
    _cancelled = true;
    super.dispose();
  }

  void _start() {
    setState(() {
      _error = null;
      _step = 0;
      _detail = null;
      _blocked = false;
    });
    if (widget.manual != null) {
      final m = widget.manual!;
      _run(m.title, m.description, m.price, const {}, '');
    } else {
      _read(widget.url!);
    }
  }

  // ------------------------------------------------------- lecture Leboncoin

  AdExtras? _extras; // photos, lieu, livraison de l'annonce lue

  Future<void> _read(Uri uri) async {
    final web = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..loadRequest(uri);
    setState(() {
      _web = web;
      _detail = "Ouverture de l'annonce…";
    });

    AdData? ad;
    final deadline = DateTime.now().add(const Duration(seconds: 25));
    var extended = false;
    while (DateTime.now().isBefore(deadline) || (extended && ad == null && !_cancelled)) {
      await Future.delayed(const Duration(milliseconds: 1500));
      if (!mounted || _cancelled || _web != web) return;
      try {
        final j = decodeJsResult(await web.runJavaScriptReturningResult(extractionScript));
        final candidate = adDataFromJs(uri, j);
        if (candidate.isComplete) {
          ad = candidate;
          try {
            _extras = adExtrasFromJs(decodeJsResult(await web.runJavaScriptReturningResult(adExtrasScript)));
          } catch (_) {}
          break;
        }
        if (j['blocked'] == true && !extended) {
          // Leboncoin affiche un test anti-robot : c'est à toi de le faire.
          extended = true;
          HapticFeedback.mediumImpact();
          setState(() {
            _blocked = true;
            _webOpen = true;
            _detail = 'Leboncoin demande une vérification : fais-la ci-dessous.';
          });
        }
      } catch (_) {
        // page pas encore prête
      }
      if (extended && DateTime.now().isAfter(deadline.add(const Duration(minutes: 2)))) break;
    }

    if (!mounted || _cancelled || _web != web) return;
    if (ad == null) {
      setState(() => _error = "Impossible de lire l'annonce. Réessaie, ou copie le titre "
          'et la description en saisie manuelle.');
      return;
    }
    setState(() {
      _blocked = false;
      _webOpen = false;
    });
    await _run(ad.title, ad.description, ad.price, ad.attributes, ad.url);
  }

  // ---------------------------------------------------------------- analyse

  Future<void> _run(String title, String desc, double? price, Map<String, String> attrs,
      String url) async {
    setState(() {
      _step = 1;
      _detail = null;
    });
    final attrsText = attrs.entries.map((e) => '${e.key} : ${e.value}').join('\n');
    try {
      final catalog = await _catalog;
      final a = await Analyzer(widget.settings, mpb: _mpb, catalog: catalog).analyze(title, desc, price,
          attributes: attrsText, extras: url.isEmpty ? null : _extras, onStep: (st) {
        if (!mounted) return;
        setState(() {
          _detail = st;
          final l = st.toLowerCase();
          if (l.contains('calcul')) {
            _step = 3;
          } else if (l.contains('catalogue') || l.contains('modèles')) {
            _step = 2;
          } else {
            _step = 1;
          }
        });
      });
      if (!mounted || _cancelled) return;
      final entry = HistoryEntry(
        id: DateTime.now().microsecondsSinceEpoch.toString(),
        date: DateTime.now(),
        url: url,
        title: title,
        adPrice: price,
        description: desc,
        attributes: attrs,
        analysis: a,
        extras: url.isEmpty ? null : _extras,
      );
      await HistoryStore.upsert(entry);
      setState(() => _step = 4);
      HapticFeedback.heavyImpact();
      await Future.delayed(const Duration(milliseconds: 450));
      if (!mounted) return;
      Navigator.of(context).pushReplacement(PageRouteBuilder(
        transitionDuration: const Duration(milliseconds: 450),
        pageBuilder: (_, __, ___) => ResultScreen(entry: entry, settings: widget.settings),
        transitionsBuilder: (_, anim, __, child) => FadeTransition(opacity: anim, child: child),
      ));
    } catch (e) {
      if (mounted) {
        HapticFeedback.vibrate();
        setState(() => _error = e.toString().replaceFirst('Exception: ', ''));
      }
    }
  }

  // ---------------------------------------------------------------------- UI

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    final subtitle = widget.url?.toString() ?? widget.manual!.title;
    return Scaffold(
      appBar: AppBar(title: const Text('Analyse')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
        children: [
          Text(subtitle,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: t.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
          const SizedBox(height: 14),
          AppCard(
            padding: const EdgeInsets.fromLTRB(18, 18, 18, 10),
            child: Column(children: [
              for (var i = 0; i < _stepLabels.length; i++)
                _StepRow(
                  label: _stepLabels[i],
                  state: _error != null && i == _step
                      ? _StepState.failed
                      : i < _step
                          ? _StepState.done
                          : i == _step
                              ? _StepState.active
                              : _StepState.pending,
                  detail: i == _step && _error == null ? _detail : null,
                  last: i == _stepLabels.length - 1,
                ),
            ]),
          ),
          if (_error != null) ...[
            const SizedBox(height: 14),
            FadeSlideIn(child: AlertBanner(text: _error!, level: AlertLevel.critical)),
            const SizedBox(height: 12),
            Row(children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.arrow_back),
                  label: const Text('Retour'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton.icon(
                  onPressed: _start,
                  icon: const Icon(Icons.refresh),
                  label: const Text('Réessayer'),
                ),
              ),
            ]),
          ],
          const SizedBox(height: 14),
          _WebPanel(
            controller: _mpbWeb.controller,
            open: _mpbOpen,
            highlight: _mpbChallenge,
            title: 'Page MPB',
            challengeTitle: 'Vérification MPB',
            onToggle: () => setState(() => _mpbOpen = !_mpbOpen),
          ),
          if (_web != null) ...[
            const SizedBox(height: 14),
            _WebPanel(
              controller: _web!,
              open: _webOpen,
              highlight: _blocked,
              onToggle: () => setState(() => _webOpen = !_webOpen),
            ),
          ],
        ],
      ),
    );
  }
}

enum _StepState { pending, active, done, failed }

class _StepRow extends StatelessWidget {
  final String label;
  final _StepState state;
  final String? detail;
  final bool last;
  const _StepRow(
      {required this.label, required this.state, this.detail, required this.last});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final Widget badge = switch (state) {
      _StepState.done => Container(
          key: const ValueKey('done'),
          width: 28,
          height: 28,
          decoration: const BoxDecoration(color: AppColors.good, shape: BoxShape.circle),
          child: const Icon(Icons.check_rounded, size: 18, color: Colors.white),
        ),
      _StepState.active => SizedBox(
          key: const ValueKey('active'),
          width: 28,
          height: 28,
          child: Padding(
            padding: const EdgeInsets.all(3),
            child: CircularProgressIndicator(strokeWidth: 2.6, color: cs.primary),
          ),
        ),
      _StepState.failed => Container(
          key: const ValueKey('failed'),
          width: 28,
          height: 28,
          decoration: const BoxDecoration(color: AppColors.bad, shape: BoxShape.circle),
          child: const Icon(Icons.close_rounded, size: 18, color: Colors.white),
        ),
      _StepState.pending => Container(
          key: const ValueKey('pending'),
          width: 28,
          height: 28,
          decoration: BoxDecoration(
              shape: BoxShape.circle, border: Border.all(color: cs.outlineVariant, width: 2)),
        ),
    };
    final dim = state == _StepState.pending;
    return IntrinsicHeight(
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Column(children: [
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 300),
            transitionBuilder: (c, a) => ScaleTransition(scale: a, child: c),
            child: badge,
          ),
          if (!last)
            Expanded(
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 400),
                width: 2,
                margin: const EdgeInsets.symmetric(vertical: 4),
                color: state == _StepState.done ? AppColors.good : cs.outlineVariant,
              ),
            ),
        ]),
        const SizedBox(width: 14),
        Expanded(
          child: Padding(
            padding: EdgeInsets.only(top: 3, bottom: last ? 8 : 18),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              AnimatedDefaultTextStyle(
                duration: const Duration(milliseconds: 250),
                style: Theme.of(context).textTheme.titleMedium!.copyWith(
                    color: dim ? cs.onSurfaceVariant.withValues(alpha: 0.6) : cs.onSurface),
                child: Text(label),
              ),
              AnimatedSize(
                duration: const Duration(milliseconds: 250),
                child: detail == null
                    ? const SizedBox(width: double.infinity)
                    : Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(detail!,
                            style: TextStyle(color: cs.onSurfaceVariant, fontSize: 13)),
                      ),
              ),
            ]),
          ),
        ),
      ]),
    );
  }
}

/// WebView repliable. Repliée, elle reste dans l'arbre (1 px de haut) pour que
/// la page continue de se charger et que le script puisse la lire.
class _WebPanel extends StatelessWidget {
  final WebViewController controller;
  final bool open;
  final bool highlight;
  final String title;
  final String challengeTitle;
  final VoidCallback onToggle;
  const _WebPanel(
      {required this.controller,
      this.title = 'Page Leboncoin',
      this.challengeTitle = 'Vérification Leboncoin',
      required this.open,
      required this.highlight,
      required this.onToggle});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final color = highlight ? AppColors.warn : cs.outlineVariant;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 300),
      decoration: BoxDecoration(
        color: cs.surface,
        borderRadius: BorderRadius.circular(kRadius),
        border: Border.all(color: color, width: highlight ? 1.6 : 1),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(children: [
        InkWell(
          onTap: onToggle,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Row(children: [
              Icon(highlight ? Icons.verified_user_outlined : Icons.public,
                  size: 20, color: highlight ? AppColors.warn : cs.onSurfaceVariant),
              const SizedBox(width: 10),
              Expanded(
                child: Text(highlight ? challengeTitle : title,
                    style: const TextStyle(fontWeight: FontWeight.w600)),
              ),
              AnimatedRotation(
                turns: open ? 0.5 : 0,
                duration: const Duration(milliseconds: 250),
                child: const Icon(Icons.expand_more),
              ),
            ]),
          ),
        ),
        AnimatedContainer(
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOutCubic,
          height: open ? 440 : 1,
          width: double.infinity,
          child: WebViewWidget(controller: controller),
        ),
      ]),
    );
  }
}
