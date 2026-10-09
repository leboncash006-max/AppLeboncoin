import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models.dart';
import '../services/history.dart';
import '../services/settings.dart';
import '../theme.dart';
import '../widgets/common.dart';
import 'chat_screen.dart';

const mpbSellUrl = 'https://www.mpb.com/fr-fr/vente-ou-reprise';

void openExternal(String url) =>
    launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);

/// Résultat d'une analyse (nouvelle ou rouverte depuis l'historique).
class ResultScreen extends StatelessWidget {
  final HistoryEntry entry;
  final Settings settings;
  const ResultScreen({super.key, required this.entry, required this.settings});

  @override
  Widget build(BuildContext context) {
    final a = entry.analysis;
    final critical = a.warnings.where((w) => AlertBanner.levelOf(w) == AlertLevel.critical);
    final others = a.warnings.where((w) => AlertBanner.levelOf(w) != AlertLevel.critical);
    var i = 0;
    Duration d() => Duration(milliseconds: 60 * i++);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Résultat'),
        actions: [
          if (entry.url.isNotEmpty)
            IconButton(
              tooltip: "Voir l'annonce",
              icon: const Icon(Icons.open_in_new),
              onPressed: () => openExternal(entry.url),
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
        children: [
          for (final w in critical) ...[
            FadeSlideIn(delay: d(), child: AlertBanner(text: w, level: AlertLevel.critical)),
            const SizedBox(height: 12),
          ],
          FadeSlideIn(
              delay: d(), child: _Hero(analysis: a, minMargin: settings.minMargin)),
          for (final w in others) ...[
            const SizedBox(height: 10),
            FadeSlideIn(delay: d(), child: AlertBanner(text: w, level: AlertBanner.levelOf(w))),
          ],
          const SizedBox(height: 16),
          FadeSlideIn(delay: d(), child: _AdCard(entry: entry)),
          if (a.items.isNotEmpty) ...[
            const SizedBox(height: 22),
            _SectionTitle('Éléments identifiés', trailing: '${a.items.length}'),
            const SizedBox(height: 10),
            for (final it in a.items) ...[
              FadeSlideIn(delay: d(), child: _ItemCard(result: it)),
              const SizedBox(height: 10),
            ],
          ],
          const SizedBox(height: 14),
          FadeSlideIn(
            delay: d(),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              FilledButton.icon(
                onPressed: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                        builder: (_) => ChatScreen(entry: entry, settings: settings))),
                icon: const Icon(Icons.forum_outlined),
                label: const Text('Poser une question'),
              ),
              const SizedBox(height: 10),
              Row(children: [
                if (entry.url.isNotEmpty) ...[
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () => openExternal(entry.url),
                      icon: const Icon(Icons.storefront_outlined, size: 20),
                      label: const Text("Voir l'annonce"),
                    ),
                  ),
                  const SizedBox(width: 10),
                ],
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => openExternal(mpbSellUrl),
                    icon: const Icon(Icons.sell_outlined, size: 20),
                    label: const Text('Estimer sur MPB'),
                  ),
                ),
              ]),
            ]),
          ),
        ],
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  final String text;
  final String? trailing;
  const _SectionTitle(this.text, {this.trailing});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Row(children: [
      Text(text.toUpperCase(),
          style: TextStyle(
              fontSize: 12.5,
              letterSpacing: 1.1,
              fontWeight: FontWeight.w700,
              color: cs.onSurfaceVariant)),
      if (trailing != null) ...[
        const SizedBox(width: 8),
        Text(trailing!,
            style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: cs.primary)),
      ],
    ]);
  }
}

// ------------------------------------------------------------------- héros

class _Hero extends StatelessWidget {
  final Analysis analysis;
  final double minMargin;
  const _Hero({required this.analysis, required this.minMargin});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    final m = analysis.margin;
    final v = verdictFor(m, minMargin);
    final dark = Theme.of(context).brightness == Brightness.dark;

    return Container(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 20),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(kRadius),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            v.color.withValues(alpha: dark ? 0.26 : 0.18),
            cs.surface,
          ],
        ),
        border: Border.all(color: v.color.withValues(alpha: 0.5)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Pill(label: v.label, color: v.color, icon: v.icon),
          const Spacer(),
          Text('Marge estimée', style: TextStyle(color: cs.onSurfaceVariant, fontSize: 13)),
        ]),
        const SizedBox(height: 10),
        FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: m == null
              ? Text('—', style: t.displayLarge?.copyWith(color: v.color))
              : AnimatedEuro(
                  value: m,
                  signed: true,
                  style: t.displayLarge?.copyWith(
                      color: v.color, fontSize: 64, height: 1.05, letterSpacing: -1.5),
                ),
        ),
        const SizedBox(height: 16),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: cs.surfaceContainerHigh.withValues(alpha: 0.7),
            borderRadius: BorderRadius.circular(14),
          ),
          child: Row(children: [
            Expanded(child: _Figure(label: 'Prix annonce', value: euros(analysis.price))),
            Icon(Icons.arrow_forward_rounded, color: cs.onSurfaceVariant),
            Expanded(
              child: _Figure(
                  label: 'Reprise MPB',
                  value: euros(analysis.totalBuyback),
                  alignEnd: true,
                  color: cs.primary),
            ),
          ]),
        ),
        if (analysis.shutterCount != null) ...[
          const SizedBox(height: 10),
          Row(children: [
            Icon(Icons.camera_outlined, size: 16, color: cs.onSurfaceVariant),
            const SizedBox(width: 6),
            Text('${analysis.shutterCount} déclenchements',
                style: TextStyle(color: cs.onSurfaceVariant, fontSize: 13)),
          ]),
        ],
      ]),
    );
  }
}

class _Figure extends StatelessWidget {
  final String label;
  final String value;
  final bool alignEnd;
  final Color? color;
  const _Figure(
      {required this.label, required this.value, this.alignEnd = false, this.color});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: alignEnd ? CrossAxisAlignment.end : CrossAxisAlignment.start,
      children: [
        Text(label, style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
        const SizedBox(height: 2),
        Text(value,
            style: TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.w800,
                color: color,
                fontFeatures: tabular)),
      ],
    );
  }
}

// ----------------------------------------------------------- carte annonce

const _conditionLabels = {
  'comme_neuf': 'Comme neuf',
  'excellent': 'Excellent état',
  'bon': 'Bon état',
  'use': 'Usé',
  'tres_use': 'Très usé',
};

class _AdCard extends StatefulWidget {
  final HistoryEntry entry;
  const _AdCard({required this.entry});

  @override
  State<_AdCard> createState() => _AdCardState();
}

class _AdCardState extends State<_AdCard> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final e = widget.entry;
    final t = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    final chips = <(String, IconData)>[
      for (final kv in e.attributes.entries)
        if (kv.value.length <= 40) ('${kv.key} : ${kv.value}', _iconFor(kv.key)),
      if (_conditionLabels[e.analysis.conditionHint] != null &&
          !e.attributes.keys.any((k) => k.toLowerCase().contains('état')))
        ('Annoncé : ${_conditionLabels[e.analysis.conditionHint]}', Icons.star_outline),
    ];

    return AppCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(
            child: Text(e.title.isEmpty ? 'Annonce sans titre' : e.title,
                style: t.titleLarge?.copyWith(fontSize: 19, height: 1.25)),
          ),
          const SizedBox(width: 12),
          Text(euros(e.adPrice ?? e.analysis.price),
              style: t.titleLarge?.copyWith(
                  fontWeight: FontWeight.w800, fontFeatures: tabular, color: cs.primary)),
        ]),
        if (chips.isNotEmpty) ...[
          const SizedBox(height: 12),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final c in chips.take(8))
                Chip(
                  avatar: Icon(c.$2, size: 16),
                  label: Text(c.$1),
                  visualDensity: VisualDensity.compact,
                  labelStyle: const TextStyle(fontSize: 12.5),
                ),
            ],
          ),
        ],
        if (e.description.isNotEmpty) ...[
          const SizedBox(height: 12),
          AnimatedSize(
            duration: const Duration(milliseconds: 250),
            alignment: Alignment.topCenter,
            child: Text(
              e.description,
              maxLines: _expanded ? null : 3,
              overflow: _expanded ? TextOverflow.visible : TextOverflow.ellipsis,
              style: TextStyle(color: cs.onSurfaceVariant, height: 1.4),
            ),
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              style: TextButton.styleFrom(padding: EdgeInsets.zero),
              onPressed: () => setState(() => _expanded = !_expanded),
              icon: Icon(_expanded ? Icons.expand_less : Icons.expand_more, size: 18),
              label: Text(_expanded ? 'Réduire' : 'Lire la description'),
            ),
          ),
        ],
      ]),
    );
  }

  static IconData _iconFor(String key) {
    final k = key.toLowerCase();
    if (k.contains('état')) return Icons.star_outline;
    if (k.contains('marque')) return Icons.sell_outlined;
    if (k.contains('type')) return Icons.category_outlined;
    return Icons.label_outline;
  }
}

// --------------------------------------------------------- carte élément

class _ItemCard extends StatelessWidget {
  final ItemResult result;
  const _ItemCard({required this.result});

  @override
  Widget build(BuildContext context) {
    final r = result;
    final cs = Theme.of(context).colorScheme;
    final (icon, kind) = switch (r.item.type) {
      'boitier' => (Icons.photo_camera_outlined, 'Boîtier'),
      'objectif' => (Icons.camera_outlined, 'Objectif'),
      'flash' => (Icons.flash_on_outlined, 'Flash'),
      _ => (Icons.devices_other_outlined, 'Autre'),
    };
    final found = r.mpbModel != null;
    final real = r.source == 'estimation réelle';
    final url = r.resale?.productUrl;

    return AppCard(
      padding: const EdgeInsets.all(16),
      onTap: url == null ? null : () => openExternal(url),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Container(
            width: 46,
            height: 46,
            decoration: BoxDecoration(
              color: cs.primary.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Icon(icon, color: cs.primary),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(kind.toUpperCase(),
                  style: TextStyle(
                      fontSize: 11,
                      letterSpacing: 1,
                      fontWeight: FontWeight.w700,
                      color: cs.onSurfaceVariant)),
              const SizedBox(height: 2),
              Text(found ? r.mpbModel! : r.item.nameGuess,
                  style: const TextStyle(fontSize: 15.5, fontWeight: FontWeight.w700, height: 1.25)),
              if (!found)
                const Padding(
                  padding: EdgeInsets.only(top: 2),
                  child: Text('Introuvable chez MPB',
                      style: TextStyle(color: AppColors.warn, fontSize: 12.5)),
                ),
            ]),
          ),
          const SizedBox(width: 10),
          Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
            Text(r.buyback == null ? '—' : euros(r.buyback),
                style: TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w800,
                    fontFeatures: tabular,
                    color: r.buyback == null ? cs.onSurfaceVariant : cs.onSurface)),
            Text('reprise', style: TextStyle(fontSize: 11.5, color: cs.onSurfaceVariant)),
          ]),
        ]),
        const SizedBox(height: 12),
        Wrap(spacing: 6, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
          if (real)
            const Pill(label: 'Estimation réelle', color: AppColors.good, icon: Icons.verified)
          else if (r.coef != null)
            Pill(
                label: 'Revente × ${r.coef!.toStringAsFixed(2).replaceAll('.', ',')}',
                color: cs.primary,
                icon: Icons.calculate_outlined),
          if (r.resale != null)
            Pill(
                label: '${r.resale!.count} chez MPB',
                color: AppColors.neutral,
                icon: Icons.inventory_2_outlined),
          if (found && !r.confident)
            const Pill(label: 'Version à vérifier', color: AppColors.warn, icon: Icons.help_outline),
        ]),
        if (r.resale != null) ...[
          const SizedBox(height: 8),
          Text(
            'Revente MPB (${r.resale!.basis}) : ${euros(r.resale!.median)} en médiane',
            style: TextStyle(fontSize: 12.5, color: cs.onSurfaceVariant),
          ),
        ],
        if (url != null)
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact, padding: const EdgeInsets.only(top: 4)),
              onPressed: () => openExternal(url),
              icon: const Icon(Icons.open_in_new, size: 16),
              label: const Text('Page MPB'),
            ),
          ),
      ]),
    );
  }
}
