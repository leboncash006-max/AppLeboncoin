import 'dart:convert';

import '../radar/radar_db.dart';
import 'history.dart';

/// Étapes d'un achat (onglet Stock).
class DealStatus {
  static const bought = 'bought';
  static const received = 'received';
  static const quoted = 'quoted'; // estimation MPB faite
  static const shipped = 'shipped'; // expédié à MPB
  static const paid = 'paid'; // payé par MPB
  static const soldElsewhere = 'sold_elsewhere';

  static const flow = [bought, received, quoted, shipped, paid];

  static String label(String s) => switch (s) {
        bought => 'Acheté',
        received => 'Reçu',
        quoted => 'Estimation MPB faite',
        shipped => 'Expédié à MPB',
        paid => 'Payé par MPB',
        soldElsewhere => 'Revendu ailleurs',
        _ => s,
      };

  static bool isDone(String s) => s == paid || s == soldElsewhere;
}

/// Un achat et son suivi jusqu'au paiement : bénéfice réel.
class Deal {
  final int? id;
  final String entryId;
  final String listId;
  final String title;
  final String url;
  final double boughtPrice;
  final double fees; // frais réels (Leboncoin, livraison, trajet)
  final DateTime boughtAt;
  final String items; // éléments achetés (texte)
  final String receivedCondition; // état constaté à réception (état MPB)
  final double? estimated; // reprise MPB estimée au moment de l'achat
  final double? mpbQuote; // estimation MPB reçue (après envoi de la demande)
  final double? soldPrice; // montant réellement payé (MPB ou ailleurs)
  final DateTime? soldAt;
  final String soldWhere; // MPB, Leboncoin, eBay…
  final String status;
  final String note;

  Deal({
    this.id,
    required this.entryId,
    this.listId = '',
    required this.title,
    required this.url,
    required this.boughtPrice,
    this.fees = 0,
    required this.boughtAt,
    this.items = '',
    this.receivedCondition = '',
    this.estimated,
    this.mpbQuote,
    this.soldPrice,
    this.soldAt,
    this.soldWhere = '',
    this.status = DealStatus.bought,
    this.note = '',
  });

  bool get sold => DealStatus.isDone(status) && soldPrice != null;

  /// Coût total de l'achat.
  double get cost => boughtPrice + fees;

  /// Bénéfice réel (seulement une fois payé).
  double? get profit => sold ? soldPrice! - cost : null;

  /// Bénéfice attendu (estimation MPB reçue, sinon reprise estimée).
  double? get expectedProfit {
    final v = mpbQuote ?? estimated;
    return v == null ? null : v - cost;
  }

  factory Deal.fromRow(Map<String, Object?> r) {
    final soldPrice = (r['sold_price'] as num?)?.toDouble();
    return Deal(
      id: r['id'] as int,
      entryId: (r['entry_id'] as String?) ?? '',
      listId: (r['list_id'] as String?) ?? '',
      title: (r['title'] as String?) ?? '',
      url: (r['url'] as String?) ?? '',
      boughtPrice: (r['bought_price'] as num?)?.toDouble() ?? 0,
      fees: (r['fees'] as num?)?.toDouble() ?? 0,
      boughtAt: DateTime.fromMillisecondsSinceEpoch((r['bought_at'] as int?) ?? 0),
      items: (r['items'] as String?) ?? '',
      receivedCondition: (r['received_condition'] as String?) ?? '',
      estimated: (r['estimated'] as num?)?.toDouble(),
      mpbQuote: (r['mpb_quote'] as num?)?.toDouble(),
      soldPrice: soldPrice,
      soldAt: r['sold_at'] == null ? null : DateTime.fromMillisecondsSinceEpoch(r['sold_at'] as int),
      soldWhere: (r['sold_where'] as String?) ?? '',
      // anciennes fiches (avant v3) : vendue = payée
      status: (r['status'] as String?) ??
          (soldPrice == null
              ? DealStatus.bought
              : ((r['sold_where'] as String?) == 'MPB' ? DealStatus.paid : DealStatus.soldElsewhere)),
      note: (r['note'] as String?) ?? '',
    );
  }
}

/// Tableau de bord du Stock (calculs purs, testés).
class StockStats {
  final int count; // achats
  final int done; // payés ou revendus
  final double totalProfit;
  final double monthProfit;
  final double? avgProfit;
  final Deal? best;
  final int precisionCount; // achats payés par MPB avec une estimation
  final double? precisionDiff; // moyenne (payé − estimé), en €
  final double? precisionPct; // écart moyen absolu, en %

  StockStats._(this.count, this.done, this.totalProfit, this.monthProfit, this.avgProfit, this.best,
      this.precisionCount, this.precisionDiff, this.precisionPct);

  factory StockStats.from(List<Deal> deals, {DateTime? now}) {
    final n = now ?? DateTime.now();
    final sold = deals.where((d) => d.profit != null).toList();
    final total = sold.fold(0.0, (t, d) => t + d.profit!);
    final month = sold
        .where((d) => d.soldAt != null && d.soldAt!.year == n.year && d.soldAt!.month == n.month)
        .fold(0.0, (t, d) => t + d.profit!);
    Deal? best;
    for (final d in sold) {
      if (best == null || d.profit! > best.profit!) best = d;
    }
    final prec = deals.where((d) => d.status == DealStatus.paid && d.soldPrice != null && (d.estimated ?? 0) > 0).toList();
    double? diff, pct;
    if (prec.isNotEmpty) {
      diff = prec.fold(0.0, (t, d) => t + (d.soldPrice! - d.estimated!)) / prec.length;
      pct = prec.fold(0.0, (t, d) => t + ((d.soldPrice! - d.estimated!).abs() / d.estimated! * 100)) / prec.length;
    }
    return StockStats._(deals.length, sold.length, total, month, sold.isEmpty ? null : total / sold.length, best,
        prec.length, diff, pct);
  }
}

/// Export CSV (séparateur « ; », lisible dans Excel / LibreOffice en français).
String dealsCsv(List<Deal> deals) {
  String c(Object? v) {
    final s = v == null ? '' : (v is double ? v.toStringAsFixed(2).replaceAll('.', ',') : '$v');
    return s.contains(RegExp(r'[;"\n]')) ? '"${s.replaceAll('"', '""')}"' : s;
  }

  String d(DateTime? t) => t == null ? '' : t.toIso8601String().substring(0, 10);
  final rows = [
    'date_achat;annonce;url;elements;prix_paye;frais;cout_total;etat_reception;reprise_estimee;estimation_mpb;'
        'statut;montant_paye;date_paiement;vendu_ou;benefice',
    for (final x in deals)
      [
        d(x.boughtAt), x.title, x.url, x.items, x.boughtPrice, x.fees, x.cost, x.receivedCondition, x.estimated,
        x.mpbQuote, DealStatus.label(x.status), x.soldPrice, d(x.soldAt), x.soldWhere, x.profit
      ].map(c).join(';'),
  ];
  return rows.join('\n');
}

class DealsStore {
  static Future<int> addFromEntry(HistoryEntry e, double price, {double fees = 0}) async =>
      (await RadarDb.db).insert('deals', {
        'entry_id': e.id,
        'list_id': e.id.startsWith('radar_') ? e.id.substring(6) : '',
        'title': e.title,
        'url': e.url,
        'bought_price': price,
        'fees': fees,
        'bought_at': DateTime.now().millisecondsSinceEpoch,
        'items': e.analysis.items.map((i) => i.mpbModel ?? i.item.nameGuess).join(' + '),
        'estimated': e.analysis.hasBuyback ? e.analysis.totalBuyback : null,
        'status': DealStatus.bought,
        'entry': jsonEncode(e.toJson()),
      });

  static Future<List<Deal>> all() async =>
      (await (await RadarDb.db).query('deals', orderBy: 'bought_at DESC')).map(Deal.fromRow).toList();

  static Future<Deal?> forEntry(String entryId) async {
    final rows = await (await RadarDb.db).query('deals', where: 'entry_id = ?', whereArgs: [entryId], limit: 1);
    return rows.isEmpty ? null : Deal.fromRow(rows.first);
  }

  static Future<Deal?> forListId(String listId) async {
    if (listId.isEmpty) return null;
    final rows = await (await RadarDb.db).query('deals', where: 'list_id = ?', whereArgs: [listId], limit: 1);
    return rows.isEmpty ? null : Deal.fromRow(rows.first);
  }

  /// Mise à jour d'une fiche (seuls les champs donnés changent).
  static Future<void> update(
    int id, {
    double? boughtPrice,
    double? fees,
    String? receivedCondition,
    String? items,
    double? mpbQuote,
    String? status,
    double? soldPrice,
    String? soldWhere,
    String? note,
    bool clearSale = false,
  }) async {
    final done = status != null && DealStatus.isDone(status);
    await (await RadarDb.db).update(
        'deals',
        {
          if (boughtPrice != null) 'bought_price': boughtPrice,
          if (fees != null) 'fees': fees,
          if (receivedCondition != null) 'received_condition': receivedCondition,
          if (items != null) 'items': items,
          if (mpbQuote != null) 'mpb_quote': mpbQuote,
          if (status != null) 'status': status,
          if (soldPrice != null) 'sold_price': soldPrice,
          if (soldPrice != null || done) 'sold_at': DateTime.now().millisecondsSinceEpoch,
          if (soldWhere != null) 'sold_where': soldWhere,
          if (note != null) 'note': note,
          if (clearSale) 'sold_price': null,
          if (clearSale) 'sold_at': null,
        },
        where: 'id = ?',
        whereArgs: [id]);
  }

  static Future<void> delete(int id) async => (await RadarDb.db).delete('deals', where: 'id = ?', whereArgs: [id]);

  static HistoryEntry? entryOf(Map<String, Object?> row) {
    final j = row['entry'] as String?;
    if (j == null) return null;
    return HistoryEntry.fromJson(Map<String, dynamic>.from(jsonDecode(j) as Map));
  }

  static Future<HistoryEntry?> entry(int id) async {
    final rows = await (await RadarDb.db).query('deals', where: 'id = ?', whereArgs: [id], limit: 1);
    return rows.isEmpty ? null : entryOf(rows.first);
  }
}
