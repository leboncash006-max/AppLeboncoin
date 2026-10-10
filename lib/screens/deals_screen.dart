import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../services/deals.dart';
import '../services/mpb_service.dart';
import '../services/settings.dart';
import '../theme.dart';
import '../widgets/common.dart';
import 'result_screen.dart' show openExternal, ResultScreen;

/// Onglet « Stock » : suivi des achats jusqu'au paiement MPB, bénéfice réel.
class DealsScreen extends StatefulWidget {
  final Settings settings;
  final bool visible; // onglet affiché (rechargement)
  final bool embedded; // dans la barre d'onglets (pas de bouton retour)
  const DealsScreen({super.key, required this.settings, this.visible = true, this.embedded = false});

  @override
  State<DealsScreen> createState() => _DealsScreenState();
}

class _DealsScreenState extends State<DealsScreen> {
  List<Deal> _deals = [];
  bool _showDone = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(DealsScreen old) {
    super.didUpdateWidget(old);
    if (widget.visible && !old.visible) _load();
  }

  Future<void> _load() async {
    final d = await DealsStore.all();
    if (mounted) setState(() => _deals = d);
  }

  Future<void> _export() async {
    try {
      final dir = await getTemporaryDirectory();
      final f = File('${dir.path}/stock-mpb-check.csv');
      // BOM : accents corrects à l'ouverture dans Excel
      await f.writeAsString('﻿${dealsCsv(_deals)}');
      await SharePlus.instance.share(ShareParams(files: [XFile(f.path, mimeType: 'text/csv')], subject: 'Stock MPB Check'));
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Export impossible : $e')));
    }
  }

  double? _n(String t) => double.tryParse(t.replaceAll(',', '.').replaceAll('€', '').trim());

  Future<void> _open(Deal d) async {
    final bought = TextEditingController(text: d.boughtPrice.toStringAsFixed(0));
    final fees = TextEditingController(text: d.fees == 0 ? '' : d.fees.toStringAsFixed(0));
    final quote = TextEditingController(text: d.mpbQuote?.toStringAsFixed(0) ?? '');
    final paid = TextEditingController(text: d.soldPrice?.toStringAsFixed(0) ?? '');
    final items = TextEditingController(text: d.items);
    var status = d.status;
    var cond = d.receivedCondition;
    var where = d.soldWhere.isEmpty ? 'Leboncoin' : d.soldWhere;
    final action = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => Padding(
          padding: EdgeInsets.fromLTRB(16, 0, 16, 16 + MediaQuery.viewInsetsOf(ctx).bottom),
          child: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Text(d.title, maxLines: 2, overflow: TextOverflow.ellipsis, style: Theme.of(ctx).textTheme.titleLarge),
              const SizedBox(height: 4),
              Text('Acheté le ${shortDate(d.boughtAt)}${d.estimated == null ? '' : ' · reprise estimée ${euros(d.estimated)}'}',
                  style: TextStyle(color: Theme.of(ctx).colorScheme.onSurfaceVariant, fontSize: 12.5)),
              const SizedBox(height: 12),
              const Text('Statut', style: TextStyle(fontWeight: FontWeight.w700)),
              const SizedBox(height: 6),
              Wrap(spacing: 6, runSpacing: 6, children: [
                for (final st in [...DealStatus.flow, DealStatus.soldElsewhere])
                  ChoiceChip(
                    label: Text(DealStatus.label(st)),
                    selected: status == st,
                    onSelected: (_) => setS(() => status = st),
                  ),
              ]),
              const SizedBox(height: 12),
              TextField(controller: items, decoration: const InputDecoration(labelText: 'Éléments achetés')),
              const SizedBox(height: 10),
              Row(children: [
                Expanded(
                  child: TextField(
                      controller: bought,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(labelText: 'Prix payé', suffixText: '€')),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: TextField(
                      controller: fees,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(labelText: 'Frais réels', suffixText: '€')),
                ),
              ]),
              const SizedBox(height: 10),
              const Text('État constaté à réception', style: TextStyle(fontWeight: FontWeight.w700)),
              const SizedBox(height: 6),
              Wrap(spacing: 6, runSpacing: 6, children: [
                for (final c in mpbConditions)
                  ChoiceChip(
                    label: Text(mpbConditionLabels[c] ?? c),
                    selected: cond == c,
                    onSelected: (_) => setS(() => cond = c),
                  ),
              ]),
              const SizedBox(height: 10),
              TextField(
                  controller: quote,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: 'Estimation MPB reçue', suffixText: '€')),
              const SizedBox(height: 10),
              TextField(
                controller: paid,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(
                    labelText: status == DealStatus.soldElsewhere ? 'Prix de revente' : 'Montant réellement payé par MPB',
                    suffixText: '€'),
              ),
              if (status == DealStatus.soldElsewhere) ...[
                const SizedBox(height: 8),
                Wrap(spacing: 6, children: [
                  for (final w in ['Leboncoin', 'eBay', 'Vinted', 'Autre'])
                    ChoiceChip(label: Text(w), selected: where == w, onSelected: (_) => setS(() => where = w)),
                ]),
              ],
              const SizedBox(height: 16),
              FilledButton(onPressed: () => Navigator.pop(ctx, 'save'), child: const Text('Enregistrer')),
              const SizedBox(height: 6),
              Row(children: [
                if (d.url.isNotEmpty)
                  TextButton.icon(
                      onPressed: () => Navigator.pop(ctx, 'ad'),
                      icon: const Icon(Icons.open_in_new, size: 18),
                      label: const Text('Annonce')),
                TextButton.icon(
                    onPressed: () => Navigator.pop(ctx, 'analysis'),
                    icon: const Icon(Icons.analytics_outlined, size: 18),
                    label: const Text('Analyse')),
                const Spacer(),
                TextButton(
                    onPressed: () => Navigator.pop(ctx, 'delete'),
                    child: const Text('Supprimer', style: TextStyle(color: AppColors.bad))),
              ]),
            ]),
          ),
        ),
      ),
    );
    if (!mounted || action == null) return;
    switch (action) {
      case 'save':
        final p = _n(paid.text);
        await DealsStore.update(d.id!,
            boughtPrice: _n(bought.text),
            fees: _n(fees.text) ?? 0,
            items: items.text.trim(),
            receivedCondition: cond,
            mpbQuote: _n(quote.text),
            status: status,
            soldPrice: DealStatus.isDone(status) ? p : null,
            soldWhere: status == DealStatus.paid ? 'MPB' : (status == DealStatus.soldElsewhere ? where : null),
            clearSale: !DealStatus.isDone(status));
        if (DealStatus.isDone(status) && p == null && mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(const SnackBar(content: Text('Saisis le montant payé pour compter le bénéfice.')));
        }
      case 'ad':
        openExternal(d.url);
      case 'analysis':
        final e = await DealsStore.entry(d.id!);
        if (e != null && mounted) {
          await Navigator.push(
              context, MaterialPageRoute(builder: (_) => ResultScreen(entry: e, settings: widget.settings)));
        }
      case 'delete':
        await DealsStore.delete(d.id!);
    }
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final st = StockStats.from(_deals);
    final shown = _showDone ? _deals : _deals.where((d) => !DealStatus.isDone(d.status)).toList();
    Widget tile(String label, String value, {Color? color}) => Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(value,
                style: TextStyle(fontWeight: FontWeight.w800, fontSize: 18, color: color, fontFeatures: tabular)),
            Text(label, style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12)),
          ]),
        );
    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: !widget.embedded,
        title: const Text('Stock'),
        actions: [
          IconButton(
              tooltip: 'Exporter en CSV', onPressed: _deals.isEmpty ? null : _export, icon: const Icon(Icons.ios_share)),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 32), children: [
          AppCard(
            child: Column(children: [
              Row(children: [
                tile('bénéfice total', euros(st.totalProfit, signed: true),
                    color: st.totalProfit >= 0 ? AppColors.good : AppColors.bad),
                tile('ce mois-ci', euros(st.monthProfit, signed: true)),
                tile('achats', '${st.count}'),
              ]),
              const SizedBox(height: 14),
              Row(children: [
                tile('bénéfice moyen', st.avgProfit == null ? '—' : euros(st.avgProfit, signed: true)),
                tile('meilleur coup', st.best == null ? '—' : euros(st.best!.profit, signed: true)),
                tile('précision', st.precisionPct == null ? '—' : '± ${st.precisionPct!.toStringAsFixed(0)} %'),
              ]),
              if (st.precisionDiff != null) ...[
                const SizedBox(height: 10),
                Text(
                  'Payé par MPB vs estimé : ${euros(st.precisionDiff, signed: true)} en moyenne '
                  'sur ${st.precisionCount} achat(s).',
                  style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12.5),
                ),
              ],
              if (st.best != null) ...[
                const SizedBox(height: 4),
                Text('Meilleur coup : ${st.best!.title}',
                    maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12.5)),
              ],
            ]),
          ),
          const SizedBox(height: 12),
          Row(children: [
            const Text('Fiches', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
            const Spacer(),
            FilterChip(
                label: const Text('Terminées'), selected: _showDone, onSelected: (v) => setState(() => _showDone = v)),
          ]),
          const SizedBox(height: 8),
          if (shown.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 30),
              child: Text('Aucun achat. Appuie sur « Je l\'ai acheté » depuis un résultat.',
                  textAlign: TextAlign.center, style: TextStyle(color: cs.onSurfaceVariant)),
            )
          else
            for (final d in shown) ...[
              AppCard(
                padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
                onTap: () => _open(d),
                child: Row(children: [
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(d.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
                      const SizedBox(height: 3),
                      Text('${DealStatus.label(d.status)} · payé ${euros(d.cost)} · ${shortDate(d.boughtAt)}',
                          style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12.5)),
                      const SizedBox(height: 6),
                      _Steps(status: d.status),
                    ]),
                  ),
                  const SizedBox(width: 10),
                  Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                    Text(
                      euros(d.profit ?? d.expectedProfit, signed: true),
                      style: TextStyle(
                          fontWeight: FontWeight.w800,
                          fontSize: 17,
                          fontFeatures: tabular,
                          color: (d.profit ?? d.expectedProfit ?? 0) >= 0 ? AppColors.good : AppColors.bad),
                    ),
                    Text(d.profit == null ? 'attendu' : 'réel',
                        style: TextStyle(color: cs.onSurfaceVariant, fontSize: 11.5)),
                  ]),
                ]),
              ),
              const SizedBox(height: 8),
            ],
        ]),
      ),
    );
  }
}

/// Petite frise : Acheté → Reçu → Estimation → Expédié → Payé.
class _Steps extends StatelessWidget {
  final String status;
  const _Steps({required this.status});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    if (status == DealStatus.soldElsewhere) {
      return const Pill(label: 'Revendu ailleurs', color: AppColors.good);
    }
    final idx = DealStatus.flow.indexOf(status);
    return Row(children: [
      for (var i = 0; i < DealStatus.flow.length; i++) ...[
        Expanded(
          child: Container(
            height: 5,
            decoration: BoxDecoration(
              color: i <= idx ? (idx == DealStatus.flow.length - 1 ? AppColors.good : cs.primary) : cs.outlineVariant,
              borderRadius: BorderRadius.circular(3),
            ),
          ),
        ),
        if (i < DealStatus.flow.length - 1) const SizedBox(width: 3),
      ],
    ]);
  }
}
