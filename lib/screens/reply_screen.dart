import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../messages/lbc_scripts.dart';
import '../messages/message_settings.dart';
import '../messages/message_store.dart';
import '../messages/reply_tools.dart';
import '../messages/sender.dart';
import '../radar/radar_db.dart';
import '../services/deals.dart';
import '../services/gemini_service.dart';
import '../services/history.dart';
import '../services/offer.dart';
import '../services/settings.dart';
import '../theme.dart';
import '../widgets/common.dart';
import 'deals_screen.dart';

/// Réponse d'un vendeur : conversation dans le navigateur connecté, réponses
/// proposées par l'IA, que je choisis, modifie et envoie MOI-MÊME (confirmation
/// obligatoire : une réponse peut m'engager, rien n'est envoyé automatiquement).
class ReplyScreen extends StatefulWidget {
  final int messageId;
  final Settings settings;
  const ReplyScreen({super.key, required this.messageId, required this.settings});

  @override
  State<ReplyScreen> createState() => _ReplyScreenState();
}

class _ReplyScreenState extends State<ReplyScreen> {
  final _web = WebViewController()..setJavaScriptMode(JavaScriptMode.unrestricted);
  late final _page = VisibleDriver(_web);
  SellerMessage? _m;
  HistoryEntry? _entry;
  List<ReplySuggestion> _suggestions = [];
  final _text = TextEditingController();
  bool _busy = false;
  String? _info;

  @override
  void initState() {
    super.initState();
    _start();
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    final m = await MessageStore.byId(widget.messageId);
    if (m == null || !mounted) return;
    final e = await entryForMessage(m);
    setState(() {
      _m = m;
      _entry = e;
      _info = 'Ouverture de la messagerie…';
    });
    await _web.loadRequest(Uri.parse('https://www.leboncoin.fr/messages'));
    // ouvre la conversation de l'annonce (sinon, je la touche moi-même)
    for (var i = 0; i < 8; i++) {
      await Future.delayed(const Duration(milliseconds: 1500));
      final st = await _page.evalJson(pageStateScript);
      if (st?['blocked'] == true || st?['login'] == true) {
        if (mounted) setState(() => _info = 'Connexion ou vérification Leboncoin à faire ci-dessous (à la main).');
        return;
      }
      final r = await _page.evalJson(openConversationScript(m.title));
      if (r?['ok'] == true) break;
    }
    if (mounted) setState(() => _info = 'Vérifie que c\'est la bonne conversation, puis « Proposer des réponses ».');
  }

  Future<void> _suggest() async {
    final m = _m;
    if (m == null) return;
    setState(() {
      _busy = true;
      _info = 'Lecture de la conversation…';
    });
    try {
      final conv = ((await _page.evalJson(readConversationScript))?['text'] ?? '').toString();
      final s = await MessageSettings.load();
      final list = await suggestReplies(
        gemini: GeminiService(),
        conversation: conv.isEmpty ? m.reply : conv,
        msg: m,
        entry: _entry,
        minMargin: widget.settings.minMargin,
        s: s,
      );
      if (!mounted) return;
      setState(() {
        _suggestions = list;
        _info = list.isEmpty ? 'Aucune proposition : écris ta réponse toi-même.' : 'Choisis une réponse, modifie-la si besoin.';
      });
    } catch (e) {
      if (mounted) setState(() => _info = 'Propositions impossibles : $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Écrit la réponse dans la page puis, après MA confirmation, clique « Envoyer ».
  Future<void> _send() async {
    final text = _text.text.trim();
    final m = _m;
    if (text.isEmpty || m == null) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Envoyer cette réponse ?'),
        content: Text(text),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Annuler')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Envoyer')),
        ],
      ),
    );
    if (ok != true) return;
    setState(() {
      _busy = true;
      _info = 'Écriture de la réponse…';
    });
    try {
      final st = await _page.evalJson(pageStateScript);
      if (st?['blocked'] == true || st?['login'] == true) throw 'connexion ou vérification Leboncoin à faire';
      final f = await _page.evalJson(fillScript(text));
      if (f?['ok'] != true) throw 'zone de message introuvable (ouvre la conversation)';
      await Future.delayed(const Duration(milliseconds: 1200));
      final c = await _page.evalJson(clickSendScript);
      if (c?['ok'] != true) throw 'bouton « Envoyer » introuvable : envoie-la à la main dans la page';
      final sent = await MessageSender(_page).waitSent(text, const Duration(seconds: 15));
      await RadarDb.log('💬 Réponse ${sent ? 'envoyée' : 'non confirmée'} pour « ${m.title} » : $text');
      if (mounted) setState(() => _info = sent ? 'Réponse envoyée ✓' : 'Envoi non confirmé : vérifie dans la page.');
    } catch (e) {
      if (mounted) setState(() => _info = 'Arrêté : $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _agreed() async {
    await MessageStore.update(widget.messageId, status: MsgStatus.agreed);
    await _start();
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Statut : accord ✓')));
  }

  Future<void> _bought() async {
    final e = _entry;
    if (e == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Analyse introuvable pour cette annonce.')));
      return;
    }
    final ctrl = TextEditingController(
        text: (_m?.offer ?? suggestedOffer(e.analysis, widget.settings.minMargin) ?? e.adPrice ?? 0).toStringAsFixed(0));
    final price = await showDialog<double>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Prix payé'),
        content: TextField(
            controller: ctrl,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(suffixText: '€')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Annuler')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, double.tryParse(ctrl.text.replaceAll(',', '.'))),
              child: const Text('Ajouter au Stock')),
        ],
      ),
    );
    if (price == null) return;
    await DealsStore.addFromEntry(e, price, fees: e.analysis.costs?.total ?? 0);
    await MessageStore.update(widget.messageId, status: MsgStatus.bought);
    if (!mounted) return;
    await Navigator.pushReplacement(
        context, MaterialPageRoute(builder: (_) => DealsScreen(settings: widget.settings)));
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final m = _m;
    return Scaffold(
      appBar: AppBar(
        title: Text(m == null ? 'Réponse du vendeur' : m.title, maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          PopupMenuButton<String>(
            onSelected: (v) => v == 'agreed' ? _agreed() : _bought(),
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'agreed', child: Text('Accord trouvé')),
              PopupMenuItem(value: 'bought', child: Text('Acheté → Stock')),
            ],
          ),
        ],
      ),
      body: Column(children: [
        if (m != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
            child: Row(children: [
              Pill(label: MsgStatus.label(m.status), color: cs.primary),
              const SizedBox(width: 8),
              if (m.offer != null) Pill(label: 'Proposé ${euros(m.offer)}', color: AppColors.neutral),
              const SizedBox(width: 8),
              if (_entry != null && maxBuyPrice(_entry!.analysis, widget.settings.minMargin) != null)
                Pill(
                    label: 'Max ${euros(maxBuyPrice(_entry!.analysis, widget.settings.minMargin))}',
                    color: AppColors.good),
            ]),
          ),
        if (_info != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
            child: Text(_info!, style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12.5)),
          ),
        Expanded(child: WebViewWidget(controller: _web)),
        SafeArea(
          top: false,
          child: Container(
            color: cs.surfaceContainerHigh,
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              if (_suggestions.isNotEmpty)
                SizedBox(
                  height: 92,
                  child: ListView(scrollDirection: Axis.horizontal, children: [
                    for (final s in _suggestions)
                      Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: InkWell(
                          onTap: () => setState(() => _text.text = s.text),
                          borderRadius: BorderRadius.circular(12),
                          child: Container(
                            width: 240,
                            padding: const EdgeInsets.all(10),
                            decoration: BoxDecoration(
                                color: cs.surface, borderRadius: BorderRadius.circular(12)),
                            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                              Text(s.label, style: TextStyle(fontWeight: FontWeight.w800, color: cs.primary)),
                              Text(s.text, maxLines: 3, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12.5)),
                            ]),
                          ),
                        ),
                      ),
                  ]),
                ),
              const SizedBox(height: 6),
              TextField(
                controller: _text,
                minLines: 1,
                maxLines: 4,
                decoration: const InputDecoration(hintText: 'Ta réponse (modifiable)'),
              ),
              const SizedBox(height: 6),
              Row(children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _busy ? null : _suggest,
                    icon: const Icon(Icons.auto_awesome, size: 18),
                    label: const Text('Proposer des réponses'),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton.icon(
                  onPressed: _busy ? null : _send,
                  icon: const Icon(Icons.send, size: 18),
                  label: const Text('Envoyer'),
                ),
              ]),
            ]),
          ),
        ),
      ]),
    );
  }
}
