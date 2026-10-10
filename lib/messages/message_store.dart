import '../radar/radar_db.dart';

/// Statuts d'un message au vendeur.
class MsgStatus {
  static const queued = 'queued'; // en file (garde-fous, nuit)
  static const confirm = 'confirm'; // en attente de ma confirmation
  static const sending = 'sending';
  static const sent = 'sent';
  static const test = 'test'; // test à blanc : tout sauf le clic final
  static const failed = 'failed';
  static const cancelled = 'cancelled';
  static const replied = 'replied'; // le vendeur a répondu
  static const agreed = 'agreed'; // accord trouvé
  static const bought = 'bought'; // acheté (fiche dans le Stock)

  static String label(String s) => switch (s) {
        queued => 'En file',
        confirm => 'À confirmer',
        sending => 'En cours',
        sent => 'Envoyé',
        test => 'Test à blanc',
        failed => 'Échec',
        cancelled => 'Annulé',
        replied => 'Réponse reçue',
        agreed => 'Accord',
        bought => 'Acheté',
        _ => s,
      };
}

class SellerMessage {
  final int id;
  final String listId;
  final String url;
  final String title;
  final String seller;
  final double? offer;
  final String text;
  final String status;
  final String step;
  final String error;
  final bool auto;
  final DateTime createdAt;
  final DateTime? notBefore;
  final DateTime? sentAt;
  final String reply; // dernier message du vendeur (notification)
  final DateTime? repliedAt;

  SellerMessage.fromRow(Map<String, Object?> r)
      : id = r['id'] as int,
        listId = (r['list_id'] as String?) ?? '',
        url = (r['url'] as String?) ?? '',
        title = (r['title'] as String?) ?? '',
        seller = (r['seller'] as String?) ?? '',
        offer = (r['offer'] as num?)?.toDouble(),
        text = (r['text'] as String?) ?? '',
        status = (r['status'] as String?) ?? '',
        step = (r['step'] as String?) ?? '',
        error = (r['error'] as String?) ?? '',
        auto = (r['auto'] as int? ?? 0) == 1,
        createdAt = DateTime.fromMillisecondsSinceEpoch((r['created_at'] as int?) ?? 0),
        notBefore = r['not_before'] == null ? null : DateTime.fromMillisecondsSinceEpoch(r['not_before'] as int),
        sentAt = r['sent_at'] == null ? null : DateTime.fromMillisecondsSinceEpoch(r['sent_at'] as int),
        reply = (r['reply'] as String?) ?? '',
        repliedAt = r['replied_at'] == null ? null : DateTime.fromMillisecondsSinceEpoch(r['replied_at'] as int);
}

/// Accès à la table des messages (base du radar, partagée avec l'arrière-plan).
class MessageStore {
  static int _now() => DateTime.now().millisecondsSinceEpoch;

  static Future<int> add({
    required String listId,
    required String url,
    required String title,
    double? offer,
    String text = '',
    required String status,
    bool auto = false,
    DateTime? notBefore,
  }) async =>
      (await RadarDb.db).insert('messages', {
        'list_id': listId,
        'url': url,
        'title': title,
        'offer': offer,
        'text': text,
        'status': status,
        'auto': auto ? 1 : 0,
        'created_at': _now(),
        'not_before': notBefore?.millisecondsSinceEpoch,
      });

  static Future<void> update(int id,
      {String? status, String? step, String? error, String? text, String? seller, bool sentNow = false}) async {
    await (await RadarDb.db).update(
        'messages',
        {
          if (status != null) 'status': status,
          if (step != null) 'step': step,
          if (error != null) 'error': error,
          if (text != null) 'text': text,
          if (seller != null) 'seller': seller,
          if (sentNow) 'sent_at': _now(),
        },
        where: 'id = ?',
        whereArgs: [id]);
  }

  static Future<List<SellerMessage>> all({int limit = 300}) async =>
      (await (await RadarDb.db).query('messages', orderBy: 'id DESC', limit: limit))
          .map(SellerMessage.fromRow)
          .toList();

  static Future<SellerMessage?> byId(int id) async {
    final r = await (await RadarDb.db).query('messages', where: 'id = ?', whereArgs: [id]);
    return r.isEmpty ? null : SellerMessage.fromRow(r.first);
  }

  /// Dernier message pour une annonce (pour afficher « contacté »).
  static Future<SellerMessage?> forAd(String listId) async {
    final r = await (await RadarDb.db)
        .query('messages', where: 'list_id = ?', whereArgs: [listId], orderBy: 'id DESC', limit: 1);
    return r.isEmpty ? null : SellerMessage.fromRow(r.first);
  }

  /// Annonces déjà contactées (envoyé, en cours ou en file) parmi [ids].
  static Future<Set<String>> contacted(List<String> ids) async {
    if (ids.isEmpty) return {};
    final r = await (await RadarDb.db).query('messages',
        columns: ['list_id'],
        where: "status IN ('sent','sending','queued','confirm','replied','agreed','bought') AND list_id IN (${List.filled(ids.length, '?').join(',')})",
        whereArgs: ids);
    return r.map((e) => e['list_id'] as String).toSet();
  }

  /// Déjà envoyé (ou en cours / en file) pour cette annonce ?
  static Future<bool> adAlreadyContacted(String listId) async => (await contacted([listId])).isNotEmpty;

  /// Ce vendeur a-t-il reçu un message dans les dernières 24 h ?
  static Future<bool> sellerContactedRecently(String seller) async {
    if (seller.isEmpty) return false;
    final since = _now() - 24 * 3600 * 1000;
    final r = await (await RadarDb.db).query('messages',
        where: "seller = ? AND status = 'sent' AND sent_at >= ?", whereArgs: [seller, since], limit: 1);
    return r.isNotEmpty;
  }

  /// Envois automatiques réellement faits depuis [since].
  static Future<int> autoSentSince(DateTime since) async {
    final r = await (await RadarDb.db).rawQuery(
        "SELECT COUNT(*) AS n FROM messages WHERE auto = 1 AND status = 'sent' AND sent_at >= ?",
        [since.millisecondsSinceEpoch]);
    return (r.first['n'] as int?) ?? 0;
  }

  static Future<DateTime?> lastSentAt() async {
    final r = await (await RadarDb.db).rawQuery("SELECT MAX(sent_at) AS t FROM messages WHERE status = 'sent'");
    final t = r.first['t'] as int?;
    return t == null ? null : DateTime.fromMillisecondsSinceEpoch(t);
  }

  /// Statut du dernier message envoyé pour une annonce (accord, acheté…).
  static Future<void> setStatusForAd(String listId, String status) async {
    final m = await forAd(listId);
    if (m == null || m.status == MsgStatus.cancelled || m.status == MsgStatus.failed) return;
    await update(m.id, status: status);
  }

  /// Réponse du vendeur reçue (notification Leboncoin).
  static Future<void> recordReply(int id, String text) async {
    final m = await byId(id);
    await (await RadarDb.db).update(
        'messages',
        {
          'reply': text,
          'replied_at': _now(),
          // on ne recule pas un accord ou un achat
          if (m != null && m.status != MsgStatus.agreed && m.status != MsgStatus.bought) 'status': MsgStatus.replied,
        },
        where: 'id = ?',
        whereArgs: [id]);
  }

  /// Messages envoyés pouvant recevoir une réponse (30 derniers jours).
  static Future<List<SellerMessage>> awaitingReply() async {
    final since = _now() - 30 * 24 * 3600 * 1000;
    return (await (await RadarDb.db).query('messages',
            where: "status IN ('sent','replied','agreed') AND sent_at >= ?", whereArgs: [since], orderBy: 'sent_at DESC'))
        .map(SellerMessage.fromRow)
        .toList();
  }

  /// Messages en file dont l'heure est venue (le plus ancien d'abord).
  static Future<List<SellerMessage>> dueQueue() async =>
      (await (await RadarDb.db).query('messages',
              where: "status = 'queued' AND (not_before IS NULL OR not_before <= ?)",
              whereArgs: [_now()],
              orderBy: 'id ASC'))
          .map(SellerMessage.fromRow)
          .toList();

  static Future<DateTime?> nextQueued() async {
    final r = await (await RadarDb.db).rawQuery("SELECT MIN(not_before) AS t FROM messages WHERE status = 'queued'");
    final t = r.first['t'] as int?;
    return t == null ? null : DateTime.fromMillisecondsSinceEpoch(t);
  }
}
