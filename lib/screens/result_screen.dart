import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models.dart';
import '../radar/native_browser.dart';
import '../radar/radar_db.dart';
import '../services/analyzer.dart';
import '../services/corrections.dart';
import '../services/deals.dart';
import '../services/history.dart';
import '../services/mpb_catalog.dart';
import '../services/mpb_service.dart';
import '../services/offer.dart';
import '../services/settings.dart';
import '../theme.dart';
import '../widgets/common.dart';
import 'chat_screen.dart';
import '../messages/message_store.dart';
import 'send_screen.dart';
import 'deals_screen.dart';

const mpbSellUrl = 'https://www.mpb.com/fr-fr/vente-ou-reprise';

void openExternal(String url) =>
    launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);

/// « Message vendeur » : rédaction + envoi dans la WebView de l'appli
/// (selon le mode choisi : je confirme, envoi direct ou test à blanc).
Future<void> contactSeller(BuildContext context, HistoryEntry e, double minMargin, {SellerMessage? existing}) async {
  if (e.url.isEmpty) return;
  await Navigator.push(context,
      MaterialPageRoute(builder: (_) => SendScreen(entry: e, minMargin: minMargin, existing: existing)));
}

/// Résultat d'une analyse (nouvelle ou rouverte depuis l'historique).
class ResultScreen extends StatefulWidget {
  final HistoryEntry entry;
  final Settings settings;
  const ResultScreen({super.key, required this.entry, required this.settings});

  @override
  State<ResultScreen> createState() => _ResultScreenState();
}

class _ResultScreenState extends State<ResultScreen> {
  HistoryEntry get entry => widget.entry;
  Settings get settings => widget.settings;
  Deal? _deal;
  SellerMessage? _msg; // dernier message au vendeur pour cette annonce

  @override
  void initState() {
    super.initState();
    _loadDeal();
    _loadMsg();
  }

  Future<void> _loadMsg() async {
    try {
      final m = await MessageStore.forAd(listIdOf(entry));
      if (mounted) setState(() => _msg = m);
    } catch (_) {}
  }

  Future<void> _contact() async {
    await contactSeller(context, entry, settings.minMargin);
    _loadMsg();
  }

  Future<void> _loadDeal() async {
    try {
      final d = await DealsStore.forEntry(entry.id);
      if (mounted) setState(() => _deal = d);
    } catch (_) {}
  }

  /// Enregistre l'analyse modifiée (radar ou historique).
  Future<void> _save() async {
    if (entry.id.startsWith('radar_')) {
      await RadarDb.updateEntry(entry.id.substring(6), entry, minMargin: settings.minMargin);
    } else {
      await HistoryStore.upsert(entry);
    }
  }

  Future<void> _bought() async {
    final ctrl = TextEditingController(
        text: (suggestedOffer(entry.analysis, settings.minMargin) ?? entry.adPrice ?? 0).toStringAsFixed(0));
    final price = await showDialog<double>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Je l\'ai acheté'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: const InputDecoration(labelText: 'Prix payé', suffixText: '€'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Annuler')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, double.tryParse(ctrl.text.replaceAll(',', '.').trim())),
            child: const Text('Enregistrer'),
          ),
        ],
      ),
    );
    if (price == null) return;
    await DealsStore.addFromEntry(entry, price);
    await _loadDeal();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: const Text('Ajouté à « Mes affaires »'),
      action: SnackBarAction(
          label: 'Voir',
          onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => DealsScreen(settings: settings)))),
    ));
  }

  Future<void> _correct(ItemResult item) async {
    final model = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _CorrectSheet(initial: item.mpbModel ?? item.item.nameGuess),
    );
    if (model == null || !mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(const SnackBar(content: Text('Recalcul avec les prix MPB…')));
    final wrong = item.mpbModel;
    try {
      await repriceItem(item, model, entry.analysis.condition, NativeMpbFetch().service());
      entry.analysis.aiVerdict = null; // modèle changé : vérification à refaire
      if (wrong != null) await Corrections.add(wrong, model);
      entry.analysis.warnings.removeWhere((w) => wrong != null && w.contains(wrong));
      await _save();
      if (!mounted) return;
      setState(() {});
      messenger.showSnackBar(SnackBar(
          content: Text(wrong == null ? 'Modèle corrigé.' : 'Corrigé. L\'appli s\'en souviendra pour « $wrong ».')));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Correction impossible : $e')));
    }
  }

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
          if (maxBuyPrice(a, settings.minMargin) != null) ...[
            const SizedBox(height: 10),
            FadeSlideIn(delay: d(), child: _OfferCard(entry: entry, minMargin: settings.minMargin)),
          ],
          for (final w in others) ...[
            const SizedBox(height: 10),
            FadeSlideIn(delay: d(), child: AlertBanner(text: w, level: AlertBanner.levelOf(w))),
          ],
          const SizedBox(height: 16),
          FadeSlideIn(delay: d(), child: _AdCard(entry: entry)),
          if (a.items.isNotEmpty) ...[
            const SizedBox(height: 22),
            _SectionTitle('Éléments identifiés', trailing: '${a.items.length}'),
            const SizedBox(height: 4),
            Text(
              '${a.engine == 'local' ? 'Identifié par le catalogue local (IA indisponible)' : 'Identifié par l\'IA'}'
              '${switch (a.aiVerdict) { 'oui' => ' · correspondance vérifiée ✓', 'doute' => ' · vérification : doute', 'non' => ' · vérification : non', _ => '' }}',
              style: TextStyle(
                  fontSize: 12.5,
                  color: a.aiVerdict == 'oui' ? AppColors.good : Theme.of(context).colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 10),
            for (final it in a.items) ...[
              FadeSlideIn(
                  delay: d(),
                  child: _ItemCard(result: it, condition: a.condition, onCorrect: () => _correct(it))),
              const SizedBox(height: 10),
            ],
          ],
          const SizedBox(height: 14),
          FadeSlideIn(
            delay: d(),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Row(children: [
                if (entry.url.isNotEmpty) ...[
                  Expanded(
                    child: _msg?.status == MsgStatus.sent
                        ? FilledButton.tonalIcon(
                            onPressed: _contact,
                            icon: const Icon(Icons.mark_email_read_outlined, size: 20),
                            label: const Text('Contacté ✓'),
                          )
                        : FilledButton.icon(
                            onPressed: _contact,
                            icon: const Icon(Icons.send_outlined, size: 20),
                            label: const Text('Message vendeur'),
                          ),
                  ),
                  const SizedBox(width: 10),
                ],
                Expanded(
                  child: _deal == null
                      ? FilledButton.tonalIcon(
                          onPressed: _bought,
                          icon: const Icon(Icons.shopping_bag_outlined, size: 20),
                          label: const Text('Je l\'ai acheté'),
                        )
                      : FilledButton.tonalIcon(
                          onPressed: () => Navigator.push(
                              context, MaterialPageRoute(builder: (_) => DealsScreen(settings: settings))),
                          icon: const Icon(Icons.check_circle_outline, size: 20),
                          label: Text('Acheté ${euros(_deal!.boughtPrice)}'),
                        ),
                ),
              ]),
              if (_msg != null) ...[
                const SizedBox(height: 6),
                Text(
                  '✉️ ${MsgStatus.label(_msg!.status)} · ${shortDate(_msg!.sentAt ?? _msg!.createdAt)}'
                  '${_msg!.offer == null ? '' : ' · proposé ${euros(_msg!.offer)}'}',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 12.5, color: Theme.of(context).colorScheme.onSurfaceVariant),
                ),
              ],
              const SizedBox(height: 10),
              OutlinedButton.icon(
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
          Text(
              analysis.condition == 'parts'
                  ? 'Pour pièces'
                  : 'Marge · état ${mpbConditionLabels[analysis.condition] ?? 'Bon'}',
              style: TextStyle(color: cs.onSurfaceVariant, fontSize: 13)),
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
                  value: analysis.hasBuyback ? euros(analysis.totalBuyback) : '—',
                  alignEnd: true,
                  color: cs.primary),
            ),
          ]),
        ),
        if (analysis.prudentMargin != null &&
            analysis.prudentCondition != 'parts' &&
            analysis.items.any((i) => i.realPrice)) ...[
          const SizedBox(height: 12),
          _PrudentRow(analysis: analysis, minMargin: minMargin),
        ],
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

class _PrudentRow extends StatelessWidget {
  final Analysis analysis;
  final double minMargin;
  const _PrudentRow({required this.analysis, required this.minMargin});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final pm = analysis.prudentMargin!;
    final pv = verdictFor(pm, minMargin);
    return Row(children: [
      Icon(Icons.shield_outlined, size: 18, color: cs.onSurfaceVariant),
      const SizedBox(width: 8),
      Expanded(
        child: Text(
          'Marge prudente (état ${mpbConditionLabels[analysis.prudentCondition] ?? '?'})',
          style: TextStyle(color: cs.onSurfaceVariant, fontSize: 13.5),
        ),
      ),
      AnimatedEuro(
        value: pm,
        signed: true,
        style: TextStyle(color: pv.color, fontWeight: FontWeight.w800, fontSize: 18),
      ),
    ]);
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
  final String condition;
  final VoidCallback onCorrect;
  const _ItemCard({required this.result, required this.condition, required this.onCorrect});

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
          if (r.realPrice)
            const Pill(label: 'Prix MPB réel', color: AppColors.good, icon: Icons.verified)
          else if (r.source == 'pour pièces')
            const Pill(label: 'Pour pièces : 0 €', color: AppColors.bad, icon: Icons.block)
          else if (r.approximate)
            const Pill(
                label: 'Estimation approximative',
                color: AppColors.warn,
                icon: Icons.warning_amber_rounded),
          if (r.resale != null)
            Pill(
                label: '${r.resale!.count} chez MPB',
                color: AppColors.neutral,
                icon: Icons.inventory_2_outlined),
          if (found && !r.confident)
            const Pill(label: 'Version à vérifier', color: AppColors.warn, icon: Icons.help_outline),
        ]),
        if (r.purchasePrices.isNotEmpty) ...[
          const SizedBox(height: 12),
          _PriceLadder(prices: r.purchasePrices, selected: condition),
        ],
        if (r.approximate) ...[
          const SizedBox(height: 8),
          Text(
            r.source == 'revente × coef' && r.resale != null
                ? 'API de reprise indisponible : revente MPB (${r.resale!.basis}) '
                    '${euros(r.resale!.median)} × ${r.coef!.toStringAsFixed(2).replaceAll('.', ',')}'
                : 'API de reprise indisponible : ancienne estimation enregistrée',
            style: const TextStyle(fontSize: 12.5, color: AppColors.warn),
          ),
        ],
        Row(children: [
          TextButton.icon(
            style: TextButton.styleFrom(
                visualDensity: VisualDensity.compact, padding: const EdgeInsets.only(top: 4)),
            onPressed: onCorrect,
            icon: const Icon(Icons.edit_outlined, size: 16),
            label: const Text('Pas le bon modèle ?'),
          ),
          const Spacer(),
          if (url != null)
            TextButton.icon(
              style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact, padding: const EdgeInsets.only(top: 4)),
              onPressed: () => openExternal(url),
              icon: const Icon(Icons.open_in_new, size: 16),
              label: const Text('Page MPB'),
            ),
        ]),
      ]),
    );
  }
}

/// Mini-échelle des 5 prix de reprise MPB, l'état retenu mis en avant.
class _PriceLadder extends StatelessWidget {
  final Map<String, double> prices;
  final String selected;
  const _PriceLadder({required this.prices, required this.selected});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final max = prices.values.fold<double>(0, (m, v) => v > m ? v : m);
    return Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
      for (final c in mpbConditions) ...[
        Expanded(
          child: Builder(builder: (context) {
            final v = prices[c];
            final sel = c == selected;
            final color = sel ? cs.primary : cs.onSurfaceVariant;
            return Column(children: [
              Text(v == null ? '—' : euros(v),
                  style: TextStyle(
                      fontSize: sel ? 14 : 12.5,
                      fontWeight: sel ? FontWeight.w800 : FontWeight.w600,
                      color: sel ? cs.onSurface : cs.onSurfaceVariant,
                      fontFeatures: tabular)),
              const SizedBox(height: 4),
              TweenAnimationBuilder<double>(
                tween: Tween(begin: 0, end: (v == null || max == 0) ? 0.04 : v / max),
                duration: const Duration(milliseconds: 700),
                curve: Curves.easeOutCubic,
                builder: (_, f, __) => Container(
                  height: 6 + 30 * f,
                  decoration: BoxDecoration(
                    color: sel ? cs.primary : cs.onSurfaceVariant.withValues(alpha: 0.22),
                    borderRadius: BorderRadius.circular(6),
                  ),
                ),
              ),
              const SizedBox(height: 4),
              Text(mpbConditionLabels[c]!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: 10.5,
                      fontWeight: sel ? FontWeight.w700 : FontWeight.w500,
                      color: color)),
            ]);
          }),
        ),
        if (c != mpbConditions.last) const SizedBox(width: 6),
      ],
    ]);
  }
}

// ------------------------------------------------------- prix max / offre

class _OfferCard extends StatelessWidget {
  final HistoryEntry entry;
  final double minMargin;
  const _OfferCard({required this.entry, required this.minMargin});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final a = entry.analysis;
    final max = maxBuyPrice(a, minMargin)!;
    final prudent = maxBuyPrice(a, minMargin, prudent: true);
    final offer = suggestedOffer(a, minMargin);
    final over = a.price != null && a.price! > max;
    return AppCard(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(Icons.price_check, color: cs.primary),
          const SizedBox(width: 10),
          const Expanded(child: Text('Prix d\'achat max', style: TextStyle(fontWeight: FontWeight.w700))),
          Text(euros(max),
              style: TextStyle(fontWeight: FontWeight.w800, fontSize: 20, color: cs.primary, fontFeatures: tabular)),
        ]),
        const SizedBox(height: 4),
        Text(
          'Pour garder ${euros(minMargin)} de marge'
          '${prudent != null && prudent != max ? ' (prudent : ${euros(prudent)})' : ''}. '
          '${over ? 'Propose ${euros(offer)} au vendeur.' : 'Le prix demandé est déjà en dessous.'}',
          style: TextStyle(color: cs.onSurfaceVariant, fontSize: 13),
        ),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton.icon(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: sellerMessage(entry, minMargin)));
              if (context.mounted) {
                ScaffoldMessenger.of(context)
                    .showSnackBar(const SnackBar(content: Text('Message pour le vendeur copié')));
              }
            },
            icon: const Icon(Icons.copy, size: 16),
            label: const Text('Copier le message'),
          ),
        ),
      ]),
    );
  }
}

// ------------------------------------------------------- correction de modèle

class _CorrectSheet extends StatefulWidget {
  final String initial;
  const _CorrectSheet({required this.initial});

  @override
  State<_CorrectSheet> createState() => _CorrectSheetState();
}

class _CorrectSheetState extends State<_CorrectSheet> {
  late final _q = TextEditingController(text: widget.initial);
  MpbCatalog? _catalog;
  List<String> _results = [];

  @override
  void initState() {
    super.initState();
    MpbCatalog.load().then((c) {
      _catalog = c;
      _search();
    });
  }

  void _search() {
    final c = _catalog;
    if (c == null || !mounted) return;
    final q = _q.text.trim();
    final exact = c.exact(q);
    setState(() => _results = {if (exact != null) exact, ...c.match(q, limit: 15)}.toList());
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: EdgeInsets.fromLTRB(16, 0, 16, 16 + MediaQuery.viewInsetsOf(context).bottom),
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.7,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text('Choisir le bon modèle', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 4),
          Text('Catalogue MPB. L\'appli retiendra la correction pour les prochaines annonces.',
              style: TextStyle(color: cs.onSurfaceVariant, fontSize: 13)),
          const SizedBox(height: 12),
          TextField(
            controller: _q,
            autofocus: true,
            decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'Ex. Sony A68, 18-55 IS II…'),
            onChanged: (_) => _search(),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: _catalog == null
                ? Center(
                    child: Text('Catalogue MPB pas encore téléchargé (lance une analyse d\'abord).',
                        textAlign: TextAlign.center, style: TextStyle(color: cs.onSurfaceVariant)))
                : ListView(children: [
                    for (final r in _results)
                      ListTile(
                        title: Text(r),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => Navigator.pop(context, r),
                      ),
                  ]),
          ),
        ]),
      ),
    );
  }
}
