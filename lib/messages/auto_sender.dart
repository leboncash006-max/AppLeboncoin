import 'dart:math';

import 'package:flutter/services.dart';

import '../radar/native_browser.dart';
import '../radar/radar_db.dart';
import '../services/history.dart';
import 'auto_rules.dart';
import 'message_settings.dart';
import 'message_store.dart';
import 'message_writer.dart';
import 'sender.dart';

/// Envoi AUTOMATIQUE des messages pour les bonnes affaires du Radar, avec
/// des garde-fous codés en dur (seul le plafond journalier est réglable).
class AutoSender {
  static const _bg = MethodChannel('mpb_check/radar_bg');
  static final _rand = Random();

  static Future<void> _notify(String title, String text,
      {String key = 'messages', String value = '1', bool high = false, int? id}) async {
    try {
      await _bg.invokeMethod('notifyInfo', {
        'id': id ?? 4300 + _rand.nextInt(500),
        'title': title,
        'text': text,
        'key': key,
        'value': value,
        'high': high,
      });
    } catch (_) {}
  }

  /// Raison pour laquelle l'annonce NE PEUT PAS partir automatiquement (null = OK).
  /// Toutes les conditions : marge ≥ seuil, prix connu, aucune alerte, versions
  /// sûres, jamais contactée, et verdict IA « oui ».
  static Future<String?> refusal(HistoryEntry e, String listId, double minMargin, MessageSettings s,
      {MessageWriter? writer}) async {
    final block = autoBlockReason(e.analysis, minMargin);
    if (block != null) return block;
    if (await MessageStore.adAlreadyContacted(listId)) return 'annonce déjà contactée';
    final v = await (writer ?? MessageWriter()).verify(e);
    if (v.verdict != 'oui') return 'verdict IA « ${v.verdict} » : ${v.reason}';
    return null;
  }

  /// Prochaine heure autorisée par les garde-fous (nuit, écart mini, plafonds).
  static Future<DateTime> nextSlot(MessageSettings s) async {
    var t = DateTime.now();
    // au moins 3 min depuis le dernier envoi + 20 à 90 s au hasard
    final last = await MessageStore.lastSentAt();
    final gap = MessageSettings.minGap +
        Duration(seconds: MessageSettings.randomGapMinS + _rand.nextInt(MessageSettings.randomGapMaxS - MessageSettings.randomGapMinS + 1));
    if (last != null && last.add(gap).isAfter(t)) t = last.add(gap);
    // plafond horaire (3) : on attend l'heure suivante
    if (await MessageStore.autoSentSince(DateTime.now().subtract(const Duration(hours: 1))) >= MessageSettings.maxPerHour) {
      final h = DateTime.now().add(const Duration(hours: 1));
      if (h.isAfter(t)) t = h;
    }
    // plafond journalier : demain 8 h
    final today = DateTime(t.year, t.month, t.day);
    if (await MessageStore.autoSentSince(today) >= s.dailyMax) {
      t = DateTime(t.year, t.month, t.day + 1, MessageSettings.quietEndHour, _rand.nextInt(30));
    }
    // nuit (22 h – 8 h) : file d'attente jusqu'à 8 h
    if (t.hour >= MessageSettings.quietStartHour) {
      t = DateTime(t.year, t.month, t.day + 1, MessageSettings.quietEndHour, _rand.nextInt(30));
    } else if (t.hour < MessageSettings.quietEndHour) {
      t = DateTime(t.year, t.month, t.day, MessageSettings.quietEndHour, _rand.nextInt(30));
    }
    return t;
  }

  /// Appelé par le Radar pour une bonne affaire : met le message en file (mode
  /// auto, toutes conditions réunies) ou envoie une notification « À confirmer ».
  static Future<void> consider(HistoryEntry e, String listId, String url, double minMargin) async {
    final s = await MessageSettings.load();
    if (s.mode != SendMode.auto || !s.autoEnabled) return;
    final title = e.title;
    if (s.autoSuspended) {
      await _notify('À confirmer : $title', 'Envoi auto suspendu. Appuie pour envoyer le message toi-même.',
          key: 'confirm_send', value: listId);
      return;
    }
    final writer = MessageWriter();
    final why = await refusal(e, listId, minMargin, s, writer: writer);
    if (why != null) {
      await RadarDb.log('✉️ Pas d\'envoi auto pour « $title » : $why');
      await _notify('À confirmer : $title', 'Pas d\'envoi automatique ($why). Appuie pour vérifier et envoyer.',
          key: 'confirm_send', value: listId);
      return;
    }
    final offer = MessageWriter.offerFor(e, minMargin, s);
    final text = await writer.write(e, minMargin, s);
    final at = await nextSlot(s);
    await MessageStore.add(
        listId: listId, url: url, title: title, offer: offer, text: text, status: MsgStatus.queued, auto: true, notBefore: at);
    await RadarDb.log('✉️ Message mis en file pour « $title » (envoi prévu ${at.hour}h${at.minute.toString().padLeft(2, '0')})');
  }

  /// Envoie les messages en file dont l'heure est venue (un à la fois, avec
  /// tous les garde-fous revérifiés juste avant).
  static Future<void> processQueue({void Function(String)? onLive}) async {
    var s = await MessageSettings.load();
    final browser = NativeBrowser('msg');
    try {
      for (final m in await MessageStore.dueQueue()) {
        s = await MessageSettings.load();
        if (s.mode != SendMode.auto || !s.autoEnabled || s.autoSuspended) {
          await RadarDb.log('✉️ File en pause (envoi auto désactivé ou suspendu)');
          return;
        }
        final slot = await nextSlot(s);
        if (slot.isAfter(DateTime.now().add(const Duration(seconds: 5)))) {
          // garde-fou pas encore respecté : on décale
          await (await RadarDb.db).update('messages', {'not_before': slot.millisecondsSinceEpoch},
              where: 'id = ?', whereArgs: [m.id]);
          await RadarDb.log('✉️ « ${m.title} » décalé à ${slot.hour}h${slot.minute.toString().padLeft(2, '0')} (garde-fous)');
          continue;
        }
        onLive?.call('Envoi du message à « ${m.title} »');
        final sender = MessageSender(HeadlessDriver(browser), onStep: (i, d) => onLive?.call('${sendSteps[i]} : $d'));
        final out = await sender.run(m,
            mode: s.dryRun ? 'dry' : 'send',
            allowSeller: (seller) async => !await MessageStore.sellerContactedRecently(seller));
        final offer = m.offer == null ? '' : ' (proposé ${m.offer!.toStringAsFixed(0)} €)';
        switch (out.status) {
          case MsgStatus.sent:
            await MessageSettings.setFailures(0);
            await _notify('Message envoyé à ${m.title}$offer', m.text, value: '${m.id}');
          case MsgStatus.test:
            await MessageSettings.setFailures(0);
            await _notify('Test à blanc réussi : ${m.title}$offer', 'Tout a marché sauf le clic final sur Envoyer.',
                value: '${m.id}');
          case MsgStatus.cancelled:
            break;
          default:
            final fails = await MessageSettings.failures() + 1;
            await MessageSettings.setFailures(fails);
            if (out.actionRequired || fails >= MessageSettings.failuresBeforeSuspend) {
              s.autoSuspended = true;
              await s.save();
              await RadarDb.log('✉️ Envoi auto SUSPENDU (${out.actionRequired ? out.error : '$fails échecs de suite'})');
              await _notify(
                  out.actionRequired ? 'Action requise : Leboncoin' : 'Envoi auto suspendu',
                  '${out.error ?? 'Échec'}. Fais-le toi-même dans l\'onglet Messages, puis réactive l\'envoi auto.',
                  high: true);
              return;
            }
            await _notify('Échec de l\'envoi : ${m.title}', '${out.step} : ${out.error ?? '?'}', value: '${m.id}');
        }
      }
    } finally {
      await browser.dispose();
    }
  }
}
