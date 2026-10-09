import 'dart:async';
import 'dart:math';

import 'package:webview_flutter/webview_flutter.dart';

import '../radar/native_browser.dart';
import '../radar/radar_db.dart';
import '../services/leboncoin_reader.dart' show decodeJsResult;
import 'lbc_scripts.dart';
import 'message_store.dart';

/// Une page pilotable : WebView visible (envoi depuis l'appli) ou WebView sans
/// affichage (envoi automatique du radar). Mêmes cookies dans les deux cas.
abstract class PageDriver {
  Future<void> load(String url);
  Future<Map<String, dynamic>?> evalJson(String js);
}

class VisibleDriver implements PageDriver {
  final WebViewController controller;
  VisibleDriver(this.controller);

  @override
  Future<void> load(String url) => controller.loadRequest(Uri.parse(url));

  @override
  Future<Map<String, dynamic>?> evalJson(String js) async {
    try {
      final raw = await controller.runJavaScriptReturningResult(js).timeout(const Duration(seconds: 15));
      return decodeJsResult(raw);
    } catch (_) {
      return null;
    }
  }
}

class HeadlessDriver implements PageDriver {
  final NativeBrowser browser;
  HeadlessDriver(this.browser);

  @override
  Future<void> load(String url) async => browser.load(url, timeoutMs: 30000);

  @override
  Future<Map<String, dynamic>?> evalJson(String js) => browser.evalJson(js);
}

/// Étapes affichées pendant l'envoi.
const sendSteps = ["Ouverture de l'annonce", 'Contact', 'Message écrit', 'Envoyé'];

/// Résultat d'un envoi.
class SendOutcome {
  final String status; // MsgStatus
  final String step;
  final String? error;
  final bool actionRequired; // captcha / connexion : je dois agir moi-même
  SendOutcome(this.status, this.step, {this.error, this.actionRequired = false});
}

class SendStopped implements Exception {}

/// Automate d'envoi d'un message, étape par étape. S'arrête à la moindre
/// étape qui échoue (la page reste affichée pour finir à la main) et ne
/// contourne jamais une vérification anti-robot ni une page de connexion.
class MessageSender {
  final PageDriver page;
  final void Function(int step, String detail)? onStep;
  bool stopRequested = false;
  final _rand = Random();

  MessageSender(this.page, {this.onStep});

  Future<void> _human() async {
    // délai « humain » entre deux étapes (1 à 3 s)
    await Future.delayed(Duration(milliseconds: 1000 + _rand.nextInt(2000)));
    if (stopRequested) throw SendStopped();
  }

  Future<Map<String, dynamic>?> _state() => page.evalJson(pageStateScript);

  /// [mode] : 'dry' (tout sauf le clic final), 'confirm' (je tape Envoyer) ou 'send'.
  /// [allowSeller] : refuse l'envoi si ce vendeur a déjà été contacté (24 h).
  Future<SendOutcome> run(SellerMessage m,
      {required String mode, void Function(String seller)? onSeller, Future<bool> Function(String seller)? allowSeller}) async {
    var step = 0;
    String stepName() => sendSteps[step];
    Future<SendOutcome> fail(String error, {bool action = false}) async {
      final st = await _state();
      await RadarDb.log('✉️ Échec « ${m.title} » à l\'étape « ${stepName()} » : $error\n'
          'Boutons : ${(st?['buttons'] as List?)?.join(' | ') ?? '?'}\n'
          'Page : ${st?['url'] ?? '?'}\nExtrait : ${(st?['snippet'] ?? '').toString()}');
      await MessageStore.update(m.id, status: MsgStatus.failed, step: stepName(), error: error);
      return SendOutcome(MsgStatus.failed, stepName(), error: error, actionRequired: action);
    }

    Future<SendOutcome?> guard() async {
      final st = await _state();
      if (st?['blocked'] == true) {
        return await fail('Leboncoin demande une vérification anti-robot (à faire à la main)', action: true);
      }
      if (st?['login'] == true) return await fail('Connexion à Leboncoin nécessaire', action: true);
      return null;
    }

    try {
      await MessageStore.update(m.id, status: MsgStatus.sending, step: stepName());
      // 1. ouverture de l'annonce
      onStep?.call(step, 'Chargement…');
      await page.load(m.url);
      final deadline = DateTime.now().add(const Duration(seconds: 25));
      while (true) {
        await Future.delayed(const Duration(milliseconds: 1200));
        if (stopRequested) throw SendStopped();
        final st = await _state();
        if (st != null && st['ready'] == true) break;
        if (DateTime.now().isAfter(deadline)) return await fail('page de l\'annonce non chargée');
      }
      final g1 = await guard();
      if (g1 != null) return g1;
      final seller = ((await page.evalJson(sellerIdScript))?['seller'] ?? '').toString();
      if (seller.isNotEmpty) {
        if (allowSeller != null && !await allowSeller(seller)) {
          await MessageStore.update(m.id,
              status: MsgStatus.cancelled, step: stepName(), error: 'vendeur déjà contacté dans les 24 h');
          return SendOutcome(MsgStatus.cancelled, stepName(), error: 'vendeur déjà contacté dans les 24 h');
        }
        await MessageStore.update(m.id, seller: seller);
        onSeller?.call(seller);
      }

      // 2. bouton de contact (par son texte)
      step = 1;
      await MessageStore.update(m.id, step: stepName());
      await _human();
      onStep?.call(step, 'Recherche du bouton « Envoyer un message »…');
      var st = await _state();
      if (st?['hasTextarea'] != true) {
        final c = await page.evalJson(clickContactScript);
        if (c?['ok'] != true) return await fail('bouton de contact introuvable');
        onStep?.call(step, 'Bouton « ${c?['text']} » cliqué');
        final until = DateTime.now().add(const Duration(seconds: 15));
        while (true) {
          await Future.delayed(const Duration(milliseconds: 1000));
          if (stopRequested) throw SendStopped();
          final g = await guard();
          if (g != null) return g;
          st = await _state();
          if (st?['hasTextarea'] == true) break;
          if (DateTime.now().isAfter(until)) return await fail('zone de message introuvable après le clic');
        }
      }

      // 3. écriture du message
      step = 2;
      await MessageStore.update(m.id, step: stepName());
      await _human();
      onStep?.call(step, 'Écriture du message…');
      final f = await page.evalJson(fillScript(m.text));
      if (f?['ok'] != true) return await fail('message non écrit (${f?['error'] ?? f?['value'] ?? '?'})');

      if (mode == 'dry') {
        await MessageStore.update(m.id, status: MsgStatus.test, step: stepName());
        await RadarDb.log('✉️ Test à blanc OK : « ${m.title} » (tout sauf le clic sur Envoyer)');
        onStep?.call(step, 'Test à blanc : message prêt, pas envoyé');
        return SendOutcome(MsgStatus.test, stepName());
      }
      if (mode == 'confirm') {
        await MessageStore.update(m.id, status: MsgStatus.confirm, step: stepName());
        onStep?.call(step, 'Vérifie le message et appuie sur « Envoyer » dans la page');
        return SendOutcome(MsgStatus.confirm, stepName());
      }

      // 4. envoi + vérification
      step = 3;
      await _human();
      onStep?.call(step, 'Clic sur « Envoyer »…');
      final s = await page.evalJson(clickSendScript);
      if (s?['ok'] != true) return await fail('bouton « Envoyer » introuvable');
      final ok = await waitSent(m.text, const Duration(seconds: 15));
      if (!ok) return await fail('envoi non confirmé par la page');
      await MessageStore.update(m.id, status: MsgStatus.sent, step: stepName(), sentNow: true);
      await RadarDb.log('✉️ Message envoyé : « ${m.title} »');
      onStep?.call(step, 'Message envoyé ✓');
      return SendOutcome(MsgStatus.sent, stepName());
    } on SendStopped {
      await MessageStore.update(m.id, status: MsgStatus.cancelled, step: stepName(), error: 'arrêté (STOP)');
      await RadarDb.log('✉️ Envoi arrêté (STOP) : « ${m.title} »');
      return SendOutcome(MsgStatus.cancelled, stepName(), error: 'arrêté');
    } catch (e) {
      return await fail('$e');
    }
  }

  /// Attend que le message apparaisse dans la conversation.
  Future<bool> waitSent(String text, Duration max) async {
    final until = DateTime.now().add(max);
    while (DateTime.now().isBefore(until)) {
      await Future.delayed(const Duration(milliseconds: 1500));
      final v = await page.evalJson(verifySentScript(text));
      if (v?['ok'] == true) return true;
      if (v?['blocked'] == true || v?['login'] == true) return false;
    }
    return false;
  }
}
