import 'dart:convert';

import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import '../services/history.dart';

/// Recherche Leboncoin surveillée par le radar.
class RadarSearch {
  final int? id;
  final String name; // = titre de la notification Leboncoin
  final String url;
  final bool active;
  final double maxPrice;
  final String category; // vide = toutes
  /// Point de reprise : date de publication de la plus récente annonce vue.
  final DateTime? checkpoint;
  final DateTime? lastLoadedAt;

  RadarSearch({
    this.id,
    required this.name,
    required this.url,
    this.active = true,
    this.maxPrice = 200,
    this.category = '16',
    this.checkpoint,
    this.lastLoadedAt,
  });

  factory RadarSearch.fromRow(Map<String, Object?> r) => RadarSearch(
        id: r['id'] as int,
        name: r['name'] as String,
        url: r['url'] as String,
        active: (r['active'] as int) == 1,
        maxPrice: (r['max_price'] as num).toDouble(),
        category: (r['category'] as String?) ?? '',
        checkpoint: _date(r['checkpoint']),
        lastLoadedAt: _date(r['last_loaded_at']),
      );

  Map<String, Object?> toRow() => {
        'name': name,
        'url': url,
        'active': active ? 1 : 0,
        'max_price': maxPrice,
        'category': category,
      };

  RadarSearch copyWith({String? name, String? url, bool? active, double? maxPrice, String? category}) =>
      RadarSearch(
        id: id,
        name: name ?? this.name,
        url: url ?? this.url,
        active: active ?? this.active,
        maxPrice: maxPrice ?? this.maxPrice,
        category: category ?? this.category,
        checkpoint: checkpoint,
        lastLoadedAt: lastLoadedAt,
      );
}

DateTime? _date(Object? ms) => ms == null ? null : DateTime.fromMillisecondsSinceEpoch(ms as int);

/// Annonce analysée par le radar (fil « Radar »).
class RadarAnalysis {
  final String listId;
  final int searchId;
  final String searchName;
  final String title;
  final double? price;
  final String url;
  final DateTime? publishedAt;
  final String stage; // pre | full | limit
  final double? margin;
  final bool profitable;
  final DateTime createdAt;
  final String entryJson;

  RadarAnalysis.fromRow(Map<String, Object?> r)
      : listId = r['list_id'] as String,
        searchId = (r['search_id'] as int?) ?? 0,
        searchName = (r['search_name'] as String?) ?? '',
        title = (r['title'] as String?) ?? '',
        price = (r['price'] as num?)?.toDouble(),
        url = (r['url'] as String?) ?? '',
        publishedAt = _date(r['published_at']),
        stage = (r['stage'] as String?) ?? 'pre',
        margin = (r['margin'] as num?)?.toDouble(),
        profitable = (r['profitable'] as int? ?? 0) == 1,
        createdAt = _date(r['created_at']) ?? DateTime.now(),
        entryJson = (r['entry'] as String?) ?? '{}';

  HistoryEntry get entry =>
      HistoryEntry.fromJson(Map<String, dynamic>.from(jsonDecode(entryJson) as Map));
}

class RadarNotifRow {
  final int id;
  final DateTime at;
  final String title;
  final String text;
  final String pkg;
  final int? searchId;
  RadarNotifRow.fromRow(Map<String, Object?> r)
      : id = r['id'] as int,
        at = _date(r['at'])!,
        title = (r['title'] as String?) ?? '',
        text = (r['text'] as String?) ?? '',
        pkg = (r['pkg'] as String?) ?? '',
        searchId = r['search_id'] as int?;
}

class RadarLogRow {
  final DateTime at;
  final String msg;
  RadarLogRow.fromRow(Map<String, Object?> r)
      : at = _date(r['at'])!,
        msg = (r['msg'] as String?) ?? '';
}

/// État du radar.
enum RadarState { active, paused, verify, off }

/// Stockage sqflite du radar (partagé par l'appli et le service en arrière-plan).
class RadarDb {
  static Database? _db;

  static Future<Database> get db async {
    if (_db != null) return _db!;
    final path = p.join(await getDatabasesPath(), 'radar.db');
    _db = await openDatabase(path, version: 1, onCreate: (d, _) async {
      await d.execute('''CREATE TABLE searches(
        id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT, url TEXT, active INTEGER,
        max_price REAL, category TEXT, checkpoint INTEGER, last_loaded_at INTEGER,
        created_at INTEGER)''');
      await d.execute('''CREATE TABLE seen_ads(
        list_id TEXT PRIMARY KEY, search_id INTEGER, seen_at INTEGER)''');
      await d.execute('''CREATE TABLE analyses(
        list_id TEXT PRIMARY KEY, search_id INTEGER, search_name TEXT, title TEXT,
        price REAL, url TEXT, published_at INTEGER, stage TEXT, margin REAL,
        profitable INTEGER, entry TEXT, created_at INTEGER)''');
      await d.execute('''CREATE TABLE notifs(
        id INTEGER PRIMARY KEY AUTOINCREMENT, at INTEGER, title TEXT, text TEXT,
        pkg TEXT, search_id INTEGER)''');
      await d.execute('CREATE TABLE logs(id INTEGER PRIMARY KEY AUTOINCREMENT, at INTEGER, msg TEXT)');
      await d.execute('CREATE TABLE kv(k TEXT PRIMARY KEY, v TEXT)');
      await d.execute('CREATE TABLE page_loads(at INTEGER, kind TEXT)');
    });
    return _db!;
  }

  static int _now() => DateTime.now().millisecondsSinceEpoch;

  // ---------------------------------------------------------------- recherches

  static Future<List<RadarSearch>> searches() async =>
      (await (await db).query('searches', orderBy: 'id')).map(RadarSearch.fromRow).toList();

  static Future<int> saveSearch(RadarSearch s) async {
    final d = await db;
    if (s.id == null) {
      return d.insert('searches', {...s.toRow(), 'created_at': _now()});
    }
    await d.update('searches', s.toRow(), where: 'id = ?', whereArgs: [s.id]);
    return s.id!;
  }

  static Future<void> deleteSearch(int id) async =>
      (await db).delete('searches', where: 'id = ?', whereArgs: [id]);

  static Future<void> setCheckpoint(int id, DateTime? checkpoint) async => (await db).update(
      'searches', {'checkpoint': checkpoint?.millisecondsSinceEpoch, 'last_loaded_at': _now()},
      where: 'id = ?', whereArgs: [id]);

  static Future<void> resetCheckpoint(int id) async =>
      (await db).update('searches', {'checkpoint': null}, where: 'id = ?', whereArgs: [id]);

  // -------------------------------------------------------------- annonces vues

  static Future<Set<String>> seenAmong(List<String> ids) async {
    if (ids.isEmpty) return {};
    final rows = await (await db).query('seen_ads',
        columns: ['list_id'], where: 'list_id IN (${List.filled(ids.length, '?').join(',')})', whereArgs: ids);
    return rows.map((r) => r['list_id'] as String).toSet();
  }

  static Future<void> markSeen(int searchId, Iterable<String> ids) async {
    final b = (await db).batch();
    for (final id in ids) {
      b.insert('seen_ads', {'list_id': id, 'search_id': searchId, 'seen_at': _now()},
          conflictAlgorithm: ConflictAlgorithm.ignore);
    }
    await b.commit(noResult: true);
  }

  // ------------------------------------------------------------------ analyses

  static Future<void> saveAnalysis({
    required String listId,
    required RadarSearch search,
    required String title,
    required double? price,
    required String url,
    required DateTime? publishedAt,
    required String stage,
    required double? margin,
    required bool profitable,
    required HistoryEntry entry,
  }) async {
    await (await db).insert(
        'analyses',
        {
          'list_id': listId,
          'search_id': search.id,
          'search_name': search.name,
          'title': title,
          'price': price,
          'url': url,
          'published_at': publishedAt?.millisecondsSinceEpoch,
          'stage': stage,
          'margin': margin,
          'profitable': profitable ? 1 : 0,
          'entry': jsonEncode(entry.toJson()),
          'created_at': _now(),
        },
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  /// Fil : rentables en haut, puis les plus récentes.
  static Future<List<RadarAnalysis>> analyses({int? searchId, int limit = 200}) async =>
      (await (await db).query('analyses',
              where: searchId == null ? null : 'search_id = ?',
              whereArgs: searchId == null ? null : [searchId],
              orderBy: 'profitable DESC, created_at DESC',
              limit: limit))
          .map(RadarAnalysis.fromRow)
          .toList();

  static Future<RadarAnalysis?> analysis(String listId) async {
    final rows = await (await db).query('analyses', where: 'list_id = ?', whereArgs: [listId]);
    return rows.isEmpty ? null : RadarAnalysis.fromRow(rows.first);
  }

  static Future<void> updateEntry(String listId, HistoryEntry e) async => (await db).update(
      'analyses', {'entry': jsonEncode(e.toJson())}, where: 'list_id = ?', whereArgs: [listId]);

  static Future<({int seen, int analyzed, RadarAnalysis? best})> today() async {
    final d = await db;
    final now = DateTime.now();
    final start = DateTime(now.year, now.month, now.day).millisecondsSinceEpoch;
    final seen = Sqflite.firstIntValue(
            await d.rawQuery('SELECT COUNT(*) FROM seen_ads WHERE seen_at >= ?', [start])) ??
        0;
    final analyzed = Sqflite.firstIntValue(
            await d.rawQuery('SELECT COUNT(*) FROM analyses WHERE created_at >= ?', [start])) ??
        0;
    final best = await d.query('analyses',
        where: 'created_at >= ? AND margin IS NOT NULL', whereArgs: [start], orderBy: 'margin DESC', limit: 1);
    return (seen: seen, analyzed: analyzed, best: best.isEmpty ? null : RadarAnalysis.fromRow(best.first));
  }

  // ------------------------------------------------------- notifications reçues

  static Future<void> addNotif(String title, String text, String pkg, int? searchId, DateTime at) async {
    final d = await db;
    await d.insert('notifs', {
      'at': at.millisecondsSinceEpoch,
      'title': title,
      'text': text,
      'pkg': pkg,
      'search_id': searchId,
    });
    await d.rawDelete('DELETE FROM notifs WHERE id NOT IN (SELECT id FROM notifs ORDER BY id DESC LIMIT 200)');
  }

  static Future<List<RadarNotifRow>> notifs() async =>
      (await (await db).query('notifs', orderBy: 'id DESC', limit: 200)).map(RadarNotifRow.fromRow).toList();

  // --------------------------------------------------------------------- journal

  static Future<void> log(String msg) async {
    final d = await db;
    await d.insert('logs', {'at': _now(), 'msg': msg});
    await d.rawDelete('DELETE FROM logs WHERE id NOT IN (SELECT id FROM logs ORDER BY id DESC LIMIT 1000)');
  }

  static Future<List<RadarLogRow>> logs() async =>
      (await (await db).query('logs', orderBy: 'id DESC', limit: 500)).map(RadarLogRow.fromRow).toList();

  static Future<void> clearLogs() async => (await db).delete('logs');

  // ------------------------------------------------------------- clé / valeur

  static Future<String?> get(String k) async {
    final rows = await (await db).query('kv', where: 'k = ?', whereArgs: [k]);
    return rows.isEmpty ? null : rows.first['v'] as String?;
  }

  static Future<void> set(String k, String? v) async {
    final d = await db;
    if (v == null) {
      await d.delete('kv', where: 'k = ?', whereArgs: [k]);
    } else {
      await d.insert('kv', {'k': k, 'v': v}, conflictAlgorithm: ConflictAlgorithm.replace);
    }
  }

  static Future<int> getInt(String k) async => int.tryParse(await get(k) ?? '') ?? 0;
  static Future<void> setInt(String k, int v) => set(k, '$v');

  static Future<RadarState> state() async {
    final s = await get('state');
    if (s == 'verify') return RadarState.verify;
    if (await getInt('paused_until') > _now()) return RadarState.paused;
    return RadarState.active;
  }

  // ----------------------------------------------------------- limites de débit

  static Future<void> addPageLoad(String kind) async =>
      (await db).insert('page_loads', {'at': _now(), 'kind': kind});

  static Future<int> pageLoadsLastHour(String kind) async {
    final d = await db;
    final since = _now() - 3600 * 1000;
    await d.delete('page_loads', where: 'at < ?', whereArgs: [since - 3600 * 1000]);
    return Sqflite.firstIntValue(await d.rawQuery(
            'SELECT COUNT(*) FROM page_loads WHERE kind = ? AND at >= ?', [kind, since])) ??
        0;
  }

  static Future<DateTime?> lastPageLoad() async {
    final v = Sqflite.firstIntValue(await (await db).rawQuery('SELECT MAX(at) FROM page_loads'));
    return v == null ? null : DateTime.fromMillisecondsSinceEpoch(v);
  }
}
