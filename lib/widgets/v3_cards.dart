import 'package:flutter/material.dart';

import '../models.dart';
import '../services/mpb_service.dart';
import '../services/v3_models.dart';
import '../theme.dart';
import 'common.dart';

/// Détail de la marge nette : reprise − prix − frais − livraison ou trajet.
class NetMarginCard extends StatelessWidget {
  final Analysis analysis;
  final AdExtras? extras;
  const NetMarginCard({super.key, required this.analysis, this.extras});

  @override
  Widget build(BuildContext context) {
    final a = analysis;
    final c = a.costs;
    final cs = Theme.of(context).colorScheme;
    if (c == null || a.grossMargin == null) return const SizedBox.shrink();
    Widget row(String label, String value, {bool bold = false, Color? color}) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 2.5),
          child: Row(children: [
            Expanded(child: Text(label, style: TextStyle(color: bold ? null : cs.onSurfaceVariant))),
            Text(value,
                style: TextStyle(
                    fontWeight: bold ? FontWeight.w800 : FontWeight.w600, color: color, fontFeatures: tabular)),
          ]),
        );
    final where = [
      if (extras != null && extras!.place.isNotEmpty) extras!.place,
      if (c.distanceKm != null) '≈ ${c.distanceKm!.toStringAsFixed(0)} km',
    ].join(' · ');
    return AppCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(Icons.receipt_long_outlined, color: cs.primary),
          const SizedBox(width: 10),
          const Expanded(child: Text('Marge nette', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16))),
          Pill(
            label: switch (c.mode) { 'livraison' => 'Livraison', 'main propre' => 'Main propre', _ => 'Mode inconnu' },
            color: c.tooFar ? AppColors.bad : cs.primary,
            icon: c.mode == 'livraison' ? Icons.local_shipping_outlined : Icons.directions_car_outlined,
          ),
        ]),
        if (where.isNotEmpty) ...[
          const SizedBox(height: 4),
          Text(where, style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12.5)),
        ],
        const SizedBox(height: 10),
        row('Reprise MPB (${mpbConditionLabels[a.condition] ?? a.condition})', euros(a.totalBuyback)),
        row('Prix de l\'annonce', '− ${euros(a.price)}'),
        if (c.fees > 0) row('Frais Leboncoin', '− ${euros(c.fees)}'),
        if (c.shipping > 0) row('Livraison (estimée)', '− ${euros(c.shipping)}'),
        if (c.travel > 0) row('Trajet aller-retour', '− ${euros(c.travel)}'),
        const Divider(height: 14),
        row('Marge nette', euros(a.margin, signed: true),
            bold: true, color: (a.margin ?? 0) >= 0 ? AppColors.good : AppColors.bad),
        if (c.mode == 'inconnu' || (c.mode == 'main propre' && c.distanceKm == null)) ...[
          const SizedBox(height: 6),
          Text('Règle ta ville dans les Réglages pour compter le trajet.',
              style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12)),
        ],
      ]),
    );
  }
}

/// Carrousel des photos de l'annonce avec les défauts vus par l'IA.
class PhotosCard extends StatelessWidget {
  final PhotoCheck check;
  const PhotosCard({super.key, required this.check});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final p = check;
    final ok = p.coherent == 'oui' && !p.hasMajorDefect;
    final badgeColor = p.hasMajorDefect || p.coherent == 'non'
        ? AppColors.bad
        : (p.coherent == 'doute' ? AppColors.warn : AppColors.good);
    return AppCard(
      padding: const EdgeInsets.fromLTRB(0, 14, 0, 14),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(children: [
            const Expanded(child: Text('Photos', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16))),
            Pill(
              label: ok ? 'Photos vérifiées' : (p.hasMajorDefect ? 'Défaut majeur' : 'Photos : ${p.coherent}'),
              color: badgeColor,
              icon: ok ? Icons.verified : Icons.report_outlined,
            ),
          ]),
        ),
        const SizedBox(height: 10),
        SizedBox(
          height: 190,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            itemCount: p.images.length,
            separatorBuilder: (_, __) => const SizedBox(width: 8),
            itemBuilder: (ctx, i) {
              final defects = p.defects.where((d) => d.photoIndex == i).toList();
              return GestureDetector(
                onTap: () => showDialog<void>(
                  context: ctx,
                  builder: (_) => Dialog(
                    insetPadding: const EdgeInsets.all(12),
                    child: InteractiveViewer(child: Image.network(p.images[i], fit: BoxFit.contain)),
                  ),
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: Stack(children: [
                    Image.network(p.images[i],
                        width: 190,
                        height: 190,
                        fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) =>
                            Container(width: 190, color: cs.surfaceContainerHigh, child: const Icon(Icons.broken_image))),
                    if (defects.isNotEmpty)
                      Positioned(
                        left: 6,
                        right: 6,
                        bottom: 6,
                        child: Wrap(spacing: 4, runSpacing: 4, children: [
                          for (final d in defects)
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                              decoration: BoxDecoration(
                                  color: (d.major || majorDefectWords.hasMatch(d.type) ? AppColors.bad : AppColors.warn)
                                      .withValues(alpha: 0.92),
                                  borderRadius: BorderRadius.circular(8)),
                              child: Text(d.type,
                                  style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w700)),
                            ),
                        ]),
                      ),
                  ]),
                ),
              );
            },
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            if (p.visibleModel.isNotEmpty) Text('Modèle visible : ${p.visibleModel}', style: const TextStyle(fontSize: 13)),
            Text('État visuel : ${mpbConditionLabels[p.visualCondition] ?? 'inconnu'}', style: const TextStyle(fontSize: 13)),
            if (p.reason.isNotEmpty)
              Text(p.reason, style: TextStyle(fontSize: 12.5, color: cs.onSurfaceVariant)),
            if (p.accessories.isNotEmpty)
              Text('Accessoires vus : ${p.accessories.join(', ')}',
                  style: TextStyle(fontSize: 12.5, color: cs.onSurfaceVariant)),
          ]),
        ),
      ]),
    );
  }
}
