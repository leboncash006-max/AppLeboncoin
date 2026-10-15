import 'dart:math';

import 'package:flutter/services.dart';

import '../radar/native_browser.dart';
import '../radar/radar_db.dart';
import '../services/deals.dart';
import '../services/gemini_service.dart';
import '../services/history.dart';
import '../services/settings.dart';
import 'buy_rules.dart';
import 'buy_settings.dart';
import 'lbc_scripts.dart';
import 'page_driver.dart';

/// Statuts d'une tentative d'achat.
class BuyStatus {
  static const test = 'test'; // test : tout sauf le clic final
  static const bought = 'bought';
  static const failed = 'failed';
  static const skipped = 'skipped'; // refusée par les règles ou l'IA

  static String label(String s) => switch (s) {
        test => 'Test réussi',
        bought => 'Acheté',
        failed => 'Échec',
        skipped => 'Refusé',
        _ => s,
      };
}

class BuyAttempt {
  final int id;
  final String listId, url, title, status, step, error;
  final double? price, total;
  final int certainty;
  final DateTime at;
  BuyAttempt.fromRow(Map<String, Object?> r)
      : id = r['id'] as int,
        listId = (r['list_id'] as String?) ?? '',
        url = (r['url'] as String?) ?? '',
        title = (r['title'] as String?) ?? '',
        status = (r['status'] as String?) ?? '',
        step = (r['step'] as String?) ?? '',
        error = (r['error'] as String?) ?? '',
        price = (r['price'] as num?)?.toDouble(),
        total = (r['total'] as num?)?.toDouble(),
        certainty = (r['certainty'] as int?) ?? 0,
        at = DateTime.fromMillisecondsSinceEpoch((r['created_at'] as int?) ?? 0);
}

class BuyStore {
  static Future<int> add(String listId, String url, String title, double? price, double? total, String status,
          {String step = '', String error = '', int certainty = 0}) async =>
      (await RadarDb.db).insert('buys', {
        'list_id': listId,
        'url': url,
        'title': title,
        'price': price,
        'total': total,
        'status': status,
        'step': step,
        'error': error,
        'certainty': certainty,
        'created_at': DateTime.now().millisecondsSinceEpoch,
      });

  static Future<List<BuyAttempt>> all({int limit = 200}) async =>
      (await (await RadarDb.db).query('buys', orderBy: 'id DESC', limit: limit)).map(BuyAttempt.fromRow).toList();

  /// Annonce déjà achetée (ou tentée en réel) : jamais deux fois.
  static Future<bool> tried(String listId) async => (await (await RadarDb.db).query('buys',
          where: "list_id = ? AND status IN ('bought','failed')", whereArgs: [listId], limit: 1))
      .isNotEmpty;

  /// Achats réels aujourd'hui : nombre et montant.
  static Future<({int count, double spent})> today() async {
    final n = DateTime.now();
    final r = await (await RadarDb.db).rawQuery(
        "SELECT COUNT(*) AS n, COALESCE(SUM(total), 0) AS s FROM buys WHERE status = 'bought' AND created_at >= ?",
        [DateTime(n.year, n.month, n.day).millisecondsSinceEpoch]);
    return (count: (r.first['n'] as int?) ?? 0, spent: (r.first['s'] as num?)?.toDouble() ?? 0);
  }
}

/// Résultat de l'automate.
class BuyOutcome {
  final String status;
  final String step;
  final String error;
  final double? total;
  BuyOutcome(this.status, this.step, {this.error = '', this.total});
}

/// Automate d'achat avec le solde Leboncoin. S'arrête à la moindre surprise,
/// ne contourne jamais une vérification, ne paie jamais par carte, et ne
/// recommence jamais un paiement (pas de double achat).
class Buyer {
  final PageDriver page;
  final void Function(String step)? onStep;
  final _rand = Random();
  Buyer(this.page, {this.onStep});

  Future<void> _pause() => Future.delayed(Duration(milliseconds: 1200 + _rand.nextInt(1500)));

  Future<Map<String, dynamic>?> _waitFor(String js, bool Function(Map<String, dynamic>) ok, Duration max) async {
    final until = DateTime.now().add(max);
    Map<String, dynamic>? last;
    while (DateTime.now().isBefore(until)) {
      await Future.delayed(const Duration(milliseconds: 1500));
      last = await page.evalJson(js);
      if (last != null && (ok(last) || last['blocked'] == true || last['login'] == true)) return last;
    }
    return last;
  }

  /// [maxTotal] : total à ne jamais dépasser. [test] : tout sauf le clic « Payer ».
  Future<BuyOutcome> run(String url, {required double maxTotal, required bool test}) async {
    var step = 'Ouverture de l\'annonce';
    Future<BuyOutcome> fail(String error) async {
      final st = await page.evalJson(pageStateScript);
      await RadarDb.log('🛒 Achat arrêté à « $step » : $error\nBoutons : ${(st?['buttons'] as List?)?.join(' | ') ?? '?'}\n'
          'Page : ${st?['url'] ?? '?'}\nExtrait : ${st?['snippet'] ?? ''}');
      return BuyOutcome(BuyStatus.failed, step, error: error);
    }

    try {
      onStep?.call(step);
      await page.load(url);
      var st = await _waitFor(pageStateScript, (s) => s['ready'] == true, const Duration(seconds: 25));
      if (st?['blocked'] == true) return await fail('vérification anti-robot demandée (à faire à la main)');
      if (st?['login'] == true) return await fail('connexion à Leboncoin nécessaire');

      step = 'Bouton « Acheter »';
      onStep?.call(step);
      await _pause();
      final b = await page.evalJson(clickBuyScript);
      if (b?['ok'] != true) return await fail('bouton « Acheter » introuvable (achat en ligne indisponible ?)');

      step = 'Page de paiement';
      onStep?.call(step);
      var co = await _waitFor(checkoutStateScript, (s) => s['payButton'] != '' || s['hasBalance'] == true,
          const Duration(seconds: 25));
      if (co == null) return await fail('page de paiement non chargée');
      if (co['blocked'] == true) return await fail('vérification anti-robot demandée (à faire à la main)');
      if (co['login'] == true) return await fail('connexion à Leboncoin nécessaire');

      step = 'Paiement avec le solde';
      onStep?.call(step);
      await _pause();
      final sel = await page.evalJson(selectBalanceScript);
      if (sel?['ok'] != true) return await fail('paiement avec le solde introuvable');
      await _pause();
      co = await page.evalJson(checkoutStateScript);
      if (co == null) return await fail('page de paiement illisible');
      final total = (co['total'] as num?)?.toDouble();
      final balance = (co['balance'] as num?)?.toDouble();
      if (total == null) return await fail('total à payer illisible');
      if (total > maxTotal) return await fail('total ${total.toStringAsFixed(2)} € > maximum ${maxTotal.toStringAsFixed(2)} €');
      if (balance != null && balance < total) return await fail('solde insuffisant (${balance.toStringAsFixed(2)} €)');
      if (co['card'] == true && balance == null) return await fail('la page demande une carte bancaire : refusé');
      if ((co['payButton'] ?? '') == '' || co['payEnabled'] != true) {
        return await fail('bouton de paiement absent ou inactif (point relais ou adresse à choisir ?)');
      }

      if (test) {
        await RadarDb.log('🛒 Test réussi : prêt à payer ${total.toStringAsFixed(2)} € avec le solde (pas payé)');
        return BuyOutcome(BuyStatus.test, step, total: total);
      }

      step = 'Paiement';
      onStep?.call(step);
      await _pause();
      final pay = await page.evalJson(clickPayScript);
      if (pay?['ok'] != true) return await fail('clic sur « ${co['payButton']} » impossible');
      final done = await _waitFor(purchaseConfirmedScript, (s) => s['ok'] == true || s['secure'] == true,
          const Duration(seconds: 40));
      if (done?['ok'] == true) {
        await RadarDb.log('🛒 ACHAT CONFIRMÉ : ${total.toStringAsFixed(2)} € payés avec le solde');
        return BuyOutcome(BuyStatus.bought, step, total: total);
      }
      if (done?['secure'] == true) return await fail('validation bancaire demandée : à finir dans l\'appli Leboncoin');
      // jamais de nouvel essai : le paiement est peut-être passé
      return await fail('paiement non confirmé : vérifie tes achats dans l\'appli Leboncoin');
    } catch (e) {
      return await fail('$e');
    }
  }
}

/// Achat automatique depuis le Radar, avec plafonds et suspension.
class AutoBuyer {
  static const _bg = MethodChannel('mpb_check/radar_bg');

  static Future<void> _notify(String title, String text, {bool high = false}) async {
    try {
      await _bg.invokeMethod('notifyInfo', {
        'id': 4600 + Random().nextInt(300),
        'title': title,
        'text': text,
        'key': 'buy',
        'value': '1',
        'high': high,
      });
    } catch (_) {}
  }

  /// Appelé par le Radar après une analyse complète. Rend vrai si un achat
  /// (ou un test) a eu lieu.
  static Future<bool> consider(HistoryEntry e, String listId, Settings settings, {void Function(String)? onLive}) async {
    final b = await BuySettings.load();
    if (!b.enabled || b.suspended) return false;
    if (await BuyStore.tried(listId)) return false;
    final why = buyBlockReason(e, b, settings.net);
    if (why != null) {
      await RadarDb.log('🛒 Pas d\'achat auto pour « ${e.title} » : $why');
      return false;
    }
    final today = await BuyStore.today();
    final total = e.analysis.price! + onlineCosts(e.analysis.price!, settings.net).total;
    if (today.count >= b.maxPerDay) {
      await RadarDb.log('🛒 Plafond d\'achats du jour atteint (${b.maxPerDay})');
      return false;
    }
    if (today.spent + total > b.dailyBudget) {
      await RadarDb.log('🛒 Budget du jour dépassé (${today.spent.toStringAsFixed(0)} € déjà dépensés)');
      return false;
    }
    onLive?.call('Achat auto : dernier contrôle par l\'IA');
    final ai = await aiBuyCheck(GeminiService(), e, total);
    if (!ai.go) {
      await BuyStore.add(listId, e.url, e.title, e.analysis.price, total, BuyStatus.skipped,
          step: 'Contrôle IA', error: 'IA ${ai.certainty} % : ${ai.reason}', certainty: ai.certainty);
      await RadarDb.log('🛒 IA pas sûre (${ai.certainty} %) pour « ${e.title} » : ${ai.reason}');
      return false;
    }

    final browser = NativeBrowser('buy');
    try {
      // marge de sécurité : frais réels un peu différents de l'estimation
      final maxTotal = min(b.maxPrice, total * 1.05 + 1);
      final out = await Buyer(HeadlessDriver(browser), onStep: (s) => onLive?.call('Achat auto : $s'))
          .run(e.url, maxTotal: maxTotal, test: b.testMode);
      await BuyStore.add(listId, e.url, e.title, e.analysis.price, out.total ?? total, out.status,
          step: out.step, error: out.error, certainty: ai.certainty);
      final net = e.analysis.totalBuyback - (out.total ?? total);
      switch (out.status) {
        case BuyStatus.bought:
          await DealsStore.addFromEntry(e, e.analysis.price!, fees: (out.total ?? total) - e.analysis.price!);
          await _notify('🛒 Acheté : ${e.title}',
              '${out.total!.toStringAsFixed(2)} € payés avec ton solde · marge nette ≈ ${net.toStringAsFixed(0)} €',
              high: true);
          return true;
        case BuyStatus.test:
          await _notify('🧪 Test d\'achat réussi : ${e.title}',
              'Prêt à payer ${out.total!.toStringAsFixed(2)} € avec le solde (pas payé, mode test). IA sûre à ${ai.certainty} %.');
          return true;
        default:
          b.suspended = true; // au moindre échec : je reprends la main
          await b.save();
          await _notify('⛔ Achat auto suspendu', '« ${e.title} » : ${out.error}. Vérifie, puis réactive dans l\'onglet Achat.',
              high: true);
          return false;
      }
    } finally {
      await browser.dispose();
    }
  }
}
