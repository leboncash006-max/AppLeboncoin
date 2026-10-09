import 'dart:convert';

import 'package:sqflite/sqflite.dart';

import '../radar/radar_db.dart';
import 'history.dart';

/// Un achat (et sa revente) : suivi du bénéfice réel.
class Deal {
  final int? id;
  final String entryId;
  final String title;
  final String url;
  final double boughtPrice;
  final DateTime boughtAt;
  final double? estimated; // reprise MPB estimée au moment de l'achat
  final double? soldPrice;
  final DateTime? soldAt;
  final String soldWhere; // MPB, Leboncoin, eBay…
  final String note;

  Deal({
    this.id,
    required this.entryId,
    required this.title,
    required this.url,
    required this.boughtPrice,
    required this.boughtAt,
    this.estimated,
    this.soldPrice,
    this.soldAt,
    this.soldWhere = '',
    this.note = '',
  });

  bool get sold => soldPrice != null;
  double? get profit => soldPrice == null ? null : soldPrice! - boughtPrice;

  factory Deal.fromRow(Map<String, Object?> r) => Deal(
        id: r['id'] as int,
        entryId: (r['entry_id'] as String?) ?? '',
        title: (r['title'] as String?) ?? '',
        url: (r['url'] as String?) ?? '',
        boughtPrice: (r['bought_price'] as num?)?.toDouble() ?? 0,
        boughtAt: DateTime.fromMillisecondsSinceEpoch((r['bought_at'] as int?) ?? 0),
        estimated: (r['estimated'] as num?)?.toDouble(),
        soldPrice: (r['sold_price'] as num?)?.toDouble(),
        soldAt: r['sold_at'] == null ? null : DateTime.fromMillisecondsSinceEpoch(r['sold_at'] as int),
        soldWhere: (r['sold_where'] as String?) ?? '',
        note: (r['note'] as String?) ?? '',
      );
}

class DealsStore {
  static Future<int> addFromEntry(HistoryEntry e, double price) async => (await RadarDb.db).insert('deals', {
        'entry_id': e.id,
        'title': e.title,
        'url': e.url,
        'bought_price': price,
        'bought_at': DateTime.now().millisecondsSinceEpoch,
        'estimated': e.analysis.hasBuyback ? e.analysis.totalBuyback : null,
        'entry': jsonEncode(e.toJson()),
      });

  static Future<List<Deal>> all() async =>
      (await (await RadarDb.db).query('deals', orderBy: 'bought_at DESC')).map(Deal.fromRow).toList();

  static Future<Deal?> forEntry(String entryId) async {
    final rows = await (await RadarDb.db).query('deals', where: 'entry_id = ?', whereArgs: [entryId], limit: 1);
    return rows.isEmpty ? null : Deal.fromRow(rows.first);
  }

  static Future<void> markSold(int id, double price, String where) async => (await RadarDb.db).update(
      'deals', {'sold_price': price, 'sold_at': DateTime.now().millisecondsSinceEpoch, 'sold_where': where},
      where: 'id = ?', whereArgs: [id]);

  static Future<void> update(int id, {double? boughtPrice, double? soldPrice, String? soldWhere, bool clearSale = false}) async {
    await (await RadarDb.db).update(
        'deals',
        {
          if (boughtPrice != null) 'bought_price': boughtPrice,
          if (soldPrice != null) 'sold_price': soldPrice,
          if (soldWhere != null) 'sold_where': soldWhere,
          if (clearSale) 'sold_price': null,
          if (clearSale) 'sold_at': null,
        },
        where: 'id = ?',
        whereArgs: [id],
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  static Future<void> delete(int id) async => (await RadarDb.db).delete('deals', where: 'id = ?', whereArgs: [id]);

  static HistoryEntry? entryOf(Map<String, Object?> row) {
    final j = row['entry'] as String?;
    if (j == null) return null;
    return HistoryEntry.fromJson(Map<String, dynamic>.from(jsonDecode(j) as Map));
  }
}
