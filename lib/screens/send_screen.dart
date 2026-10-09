import 'dart:async';

import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../messages/message_settings.dart';
import '../messages/message_store.dart';
import '../messages/message_writer.dart';
import '../messages/sender.dart';
import '../radar/radar_db.dart';
import '../services/history.dart';
import '../theme.dart';

/// Identifiant Leboncoin de l'annonce (list_id).
String listIdOf(HistoryEntry e) {
  if (e.id.startsWith('radar_')) return e.id.substring(6);
  final m = RegExp(r'(\d{6,})').allMatches(e.url).lastOrNull;
  return m?.group(1) ?? e.id;
}

/// Envoi d'un message au vendeur dans une WebView VISIBLE (plein écran), avec
/// la progression et un bouton STOP. Selon le mode : je confirme moi-même,
/// envoi direct, ou test à blanc (tout sauf le clic final).
class SendScreen extends StatefulWidget {
  final HistoryEntry entry;
  final double minMargin;

  /// Message déjà préparé (file d'attente, nouvel essai) ; sinon il est rédigé.
  final SellerMessage? existing;
  const SendScreen({super.key, required this.entry, required this.minMargin, this.existing});

  @override
  State<SendScreen> createState() => _SendScreenState();
}

class _SendScreenState extends State<SendScreen> {
  final _web = WebViewController()..setJavaScriptMode(JavaScriptMode.unrestricted);
  MessageSender? _sender;
  int _step = -1; // -1 : rédaction
  String _detail = 'Rédaction du message…';
  String? _status; // MsgStatus final
  String? _error;
  String _mode = 'confirm';
  SellerMessage? _msg;
  bool _waitingUser = false;

  @override
  void initState() {
    super.initState();
    _start();
  }

  @override
  void dispose() {
    _sender?.stopRequested = true;
    _waitingUser = false;
    super.dispose();
  }

  Future<void> _start() async {
    final s = await MessageSettings.load();
    // mode : test à blanc > envoi direct > je confirme (aussi pour l'auto, ici c'est moi qui ai demandé)
    _mode = s.dryRun ? 'dry' : (s.mode == SendMode.direct ? 'send' : 'confirm');
    var m = widget.existing;
    if (m == null) {
      final e = widget.entry;
      final offer = MessageWriter.offerFor(e, widget.minMargin, s);
      final text = await MessageWriter().write(e, widget.minMargin, s);
      final id = await MessageStore.add(
          listId: listIdOf(e), url: e.url, title: e.title, offer: offer, text: text, status: MsgStatus.sending);
      m = await MessageStore.byId(id);
    }
    if (!mounted || m == null) return;
    setState(() {
      _msg = m;
      _step = 0;
      _detail = 'Ouverture de l\'annonce…';
    });
    final sender = MessageSender(VisibleDriver(_web), onStep: (i, d) {
      if (mounted) {
        setState(() {
          _step = i;
          _detail = d;
        });
      }
    });
    _sender = sender;
    final out = await sender.run(m, mode: _mode);
    if (!mounted) return;
    setState(() {
      _status = out.status;
      _error = out.error;
    });
    if (out.status == MsgStatus.confirm) _waitForUserSend(sender, m);
    if (out.status == MsgStatus.sent) _snack('Message envoyé ✓');
  }

  /// Mode « je confirme » : on surveille la page jusqu'à ce que j'aie envoyé.
  Future<void> _waitForUserSend(MessageSender sender, SellerMessage m) async {
    _waitingUser = true;
    final until = DateTime.now().add(const Duration(minutes: 15));
    while (_waitingUser && mounted && DateTime.now().isBefore(until)) {
      if (await sender.waitSent(m.text, const Duration(seconds: 3))) {
        await _markSent();
        return;
      }
    }
  }

  Future<void> _markSent() async {
    final m = _msg;
    if (m == null) return;
    _waitingUser = false;
    await MessageStore.update(m.id, status: MsgStatus.sent, step: sendSteps.last, sentNow: true);
    await RadarDb.log('✉️ Message envoyé (confirmé) : « ${m.title} »');
    if (!mounted) return;
    setState(() {
      _status = MsgStatus.sent;
      _step = 3;
      _detail = 'Message envoyé ✓';
    });
    _snack('Message envoyé ✓');
  }

  void _snack(String t) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t)));

  void _stop() {
    _sender?.stopRequested = true;
    _waitingUser = false;
    setState(() => _detail = 'Arrêt demandé… la page reste affichée pour finir à la main.');
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final running = _status == null;
    final color = switch (_status) {
      MsgStatus.sent => AppColors.good,
      MsgStatus.test => AppColors.good,
      MsgStatus.confirm => cs.primary,
      null => cs.primary,
      _ => AppColors.bad,
    };
    return Scaffold(
      appBar: AppBar(
        title: Text(switch (_mode) { 'dry' => 'Test à blanc', 'send' => 'Envoi direct', _ => 'Message au vendeur' }),
        actions: [
          if (running || _waitingUser)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: FilledButton.icon(
                style: FilledButton.styleFrom(backgroundColor: AppColors.bad, minimumSize: const Size(0, 40)),
                onPressed: _stop,
                icon: const Icon(Icons.stop),
                label: const Text('STOP'),
              ),
            ),
        ],
      ),
      body: Column(children: [
        // progression : Ouverture → Contact → Message écrit → Envoyé
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Row(children: [
            for (var i = 0; i < sendSteps.length; i++) ...[
              Expanded(
                child: Column(children: [
                  Icon(
                    i < _step || (i == _step && _status != null && _status != MsgStatus.failed)
                        ? Icons.check_circle
                        : (i == _step ? Icons.radio_button_checked : Icons.radio_button_unchecked),
                    size: 20,
                    color: i <= _step ? color : cs.outlineVariant,
                  ),
                  const SizedBox(height: 2),
                  Text(sendSteps[i],
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 10.5, color: i <= _step ? cs.onSurface : cs.onSurfaceVariant)),
                ]),
              ),
            ],
          ]),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Row(children: [
            if (running) const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
            if (running) const SizedBox(width: 8),
            Expanded(
              child: Text(
                _error == null ? _detail : '${MsgStatus.label(_status!)} : $_error — termine à la main si besoin.',
                style: TextStyle(fontWeight: FontWeight.w600, color: _error == null ? null : AppColors.bad),
              ),
            ),
          ]),
        ),
        if (_msg != null)
          Container(
            width: double.infinity,
            margin: const EdgeInsets.symmetric(horizontal: 16),
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
                color: cs.surfaceContainerHigh, borderRadius: BorderRadius.circular(12)),
            child: Text(
              '${_msg!.offer == null ? '' : 'Proposé : ${_msg!.offer!.toStringAsFixed(0)} € · '}${_msg!.text}',
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12.5),
            ),
          ),
        const SizedBox(height: 8),
        Expanded(child: WebViewWidget(controller: _web)),
        if (_waitingUser)
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.all(10),
              child: Row(children: [
                const Expanded(child: Text('Appuie sur « Envoyer » dans la page.', style: TextStyle(fontSize: 13))),
                TextButton(onPressed: _markSent, child: const Text('C\'est envoyé')),
              ]),
            ),
          ),
      ]),
    );
  }
}
