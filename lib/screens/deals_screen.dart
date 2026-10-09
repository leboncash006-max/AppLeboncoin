import 'package:flutter/material.dart';

import '../services/deals.dart';
import '../services/settings.dart';
import '../theme.dart';
import '../widgets/common.dart';
import 'result_screen.dart' show openExternal;

/// Mes achats-reventes : bénéfice réel, stock, historique.
class DealsScreen extends StatefulWidget {
  final Settings settings;
  const DealsScreen({super.key, required this.settings});

  @override
  State<DealsScreen> createState() => _DealsScreenState();
}

class _DealsScreenState extends State<DealsScreen> {
  List<Deal> _deals = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final d = await DealsStore.all();
    if (mounted) setState(() => _deals = d);
  }

  Future<void> _edit(Deal d) async {
    final bought = TextEditingController(text: d.boughtPrice.toStringAsFixed(0));
    final sold = TextEditingController(
        text: d.soldPrice?.toStringAsFixed(0) ?? d.estimated?.toStringAsFixed(0) ?? '');
    var where = d.soldWhere.isEmpty ? 'MPB' : d.soldWhere;
    final action = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => Padding(
          padding: EdgeInsets.fromLTRB(16, 0, 16, 16 + MediaQuery.viewInsetsOf(ctx).bottom),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text(d.title, maxLines: 2, overflow: TextOverflow.ellipsis, style: Theme.of(ctx).textTheme.titleLarge),
            const SizedBox(height: 12),
            TextField(
              controller: bought,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'Prix payé', suffixText: '€'),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: sold,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'Prix de revente', suffixText: '€'),
            ),
            const SizedBox(height: 8),
            Wrap(spacing: 6, children: [
              for (final w in ['MPB', 'Leboncoin', 'eBay', 'Vinted', 'Autre'])
                ChoiceChip(label: Text(w), selected: where == w, onSelected: (_) => setS(() => where = w)),
            ]),
            const SizedBox(height: 14),
            FilledButton.icon(
              onPressed: () => Navigator.pop(ctx, 'sold'),
              icon: const Icon(Icons.sell_outlined),
              label: Text(d.sold ? 'Mettre à jour la vente' : 'Marquer comme vendu'),
            ),
            const SizedBox(height: 8),
            Row(children: [
              Expanded(
                child: OutlinedButton(onPressed: () => Navigator.pop(ctx, 'save'), child: const Text('Enregistrer')),
              ),
              const SizedBox(width: 8),
              if (d.sold)
                Expanded(
                  child: OutlinedButton(
                      onPressed: () => Navigator.pop(ctx, 'unsell'), child: const Text('Pas vendu')),
                ),
              if (d.sold) const SizedBox(width: 8),
              IconButton(
                tooltip: 'Supprimer',
                onPressed: () => Navigator.pop(ctx, 'delete'),
                icon: const Icon(Icons.delete_outline),
              ),
            ]),
            if (d.url.isNotEmpty)
              TextButton.icon(
                onPressed: () => openExternal(d.url),
                icon: const Icon(Icons.open_in_new, size: 18),
                label: const Text('Voir l\'annonce'),
              ),
          ]),
        ),
      ),
    );
    double? n(TextEditingController c) => double.tryParse(c.text.replaceAll(',', '.').trim());
    switch (action) {
      case 'sold':
        final p = n(sold);
        if (p != null) await DealsStore.markSold(d.id!, p, where);
        await DealsStore.update(d.id!, boughtPrice: n(bought));
      case 'save':
        await DealsStore.update(d.id!, boughtPrice: n(bought));
      case 'unsell':
        await DealsStore.update(d.id!, clearSale: true);
      case 'delete':
        await DealsStore.delete(d.id!);
    }
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final sold = _deals.where((d) => d.sold).toList();
    final stock = _deals.where((d) => !d.sold).toList();
    final profit = sold.fold(0.0, (s, d) => s + d.profit!);
    final invested = stock.fold(0.0, (s, d) => s + d.boughtPrice);
    final stockValue = stock.fold(0.0, (s, d) => s + (d.estimated ?? d.boughtPrice));
    final now = DateTime.now();
    final month = sold
        .where((d) => d.soldAt != null && d.soldAt!.year == now.year && d.soldAt!.month == now.month)
        .fold(0.0, (s, d) => s + d.profit!);
    final avg = sold.isEmpty ? null : profit / sold.length;

    Widget stat(String label, String value, {Color? color}) => Expanded(
          child: AppCard(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(value,
                  maxLines: 1,
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800, color: color, fontFeatures: tabular)),
              const SizedBox(height: 2),
              Text(label, style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
            ]),
          ),
        );

    return Scaffold(
      appBar: AppBar(title: const Text('Mes affaires')),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
          children: [
            Row(children: [
              stat('bénéfice réalisé', euros(profit, signed: true),
                  color: profit >= 0 ? AppColors.good : AppColors.bad),
              const SizedBox(width: 8),
              stat('ce mois-ci', euros(month, signed: true), color: month >= 0 ? AppColors.good : AppColors.bad),
            ]),
            const SizedBox(height: 8),
            Row(children: [
              stat('en stock (${stock.length})', euros(invested)),
              const SizedBox(width: 8),
              stat('reprise estimée du stock', euros(stockValue), color: cs.primary),
            ]),
            const SizedBox(height: 8),
            Text(
              '${_deals.length} achat(s), ${sold.length} revendu(s)'
              '${avg == null ? '' : ' · bénéfice moyen ${euros(avg, signed: true)}'}',
              style: TextStyle(color: cs.onSurfaceVariant, fontSize: 13),
            ),
            const SizedBox(height: 14),
            if (_deals.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 40),
                child: Text(
                  'Aucun achat pour le moment.\nSur un résultat d\'analyse, appuie sur « Je l\'ai acheté ».',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: cs.onSurfaceVariant),
                ),
              ),
            for (final d in _deals) ...[
              AppCard(
                padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
                onTap: () => _edit(d),
                child: Row(children: [
                  Icon(d.sold ? Icons.sell : Icons.inventory_2_outlined,
                      color: d.sold ? AppColors.good : cs.primary),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(d.title, maxLines: 1, overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontWeight: FontWeight.w700)),
                      Text(
                        d.sold
                            ? 'Acheté ${euros(d.boughtPrice)} → vendu ${euros(d.soldPrice)} · ${d.soldWhere}'
                            : 'Acheté ${euros(d.boughtPrice)} le ${shortDate(d.boughtAt)}'
                                '${d.estimated == null ? '' : ' · reprise ~${euros(d.estimated)}'}',
                        style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12.5),
                      ),
                    ]),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    d.sold
                        ? euros(d.profit, signed: true)
                        : (d.estimated == null ? 'stock' : euros(d.estimated! - d.boughtPrice, signed: true)),
                    style: TextStyle(
                        fontWeight: FontWeight.w800,
                        fontFeatures: tabular,
                        color: d.sold
                            ? ((d.profit ?? 0) >= 0 ? AppColors.good : AppColors.bad)
                            : cs.onSurfaceVariant),
                  ),
                ]),
              ),
              const SizedBox(height: 8),
            ],
          ],
        ),
      ),
    );
  }
}
