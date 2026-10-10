import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../messages/lbc_scripts.dart';
import '../messages/message_settings.dart';
import '../messages/message_store.dart';
import '../radar/native_browser.dart';
import '../radar/radar_db.dart';
import '../services/history.dart';
import '../services/settings.dart';
import '../theme.dart';
import '../widgets/common.dart';
import 'lbc_login_screen.dart';
import 'message_settings_screen.dart';
import 'reply_screen.dart';
import 'result_screen.dart';
import 'send_screen.dart';

enum _Login { unknown, checking, yes, no, blocked }

/// Onglet « Messages » : connexion Leboncoin, interrupteur « Envoi auto »,
/// garde-fous et liste des envois.
class MessagesScreen extends StatefulWidget {
  final Settings settings;
  final bool visible;
  const MessagesScreen({super.key, required this.settings, required this.visible});

  @override
  State<MessagesScreen> createState() => _MessagesScreenState();
}

class _MessagesScreenState extends State<MessagesScreen> {
  MessageSettings? _s;
  List<SellerMessage> _msgs = [];
  int _autoToday = 0;
  _Login _login = _Login.unknown;

  @override
  void initState() {
    super.initState();
    _load();
    _checkLogin();
  }

  @override
  void didUpdateWidget(MessagesScreen old) {
    super.didUpdateWidget(old);
    if (widget.visible && !old.visible) _load();
  }

  Future<void> _load() async {
    final s = await MessageSettings.load();
    final msgs = await MessageStore.all();
    final now = DateTime.now();
    final today = await MessageStore.autoSentSince(DateTime(now.year, now.month, now.day));
    if (!mounted) return;
    setState(() {
      _s = s;
      _msgs = msgs;
      _autoToday = today;
    });
  }

  /// Ouvre « Mes annonces » sans affichage : page de connexion = non connecté.
  Future<void> _checkLogin() async {
    setState(() => _login = _Login.checking);
    final b = NativeBrowser('lbc_login');
    var r = _Login.unknown;
    try {
      final l = await b.load(LbcLoginScreen.startUrl, timeoutMs: 25000);
      if (l.ok) {
        final until = DateTime.now().add(const Duration(seconds: 15));
        while (DateTime.now().isBefore(until)) {
          await Future.delayed(const Duration(milliseconds: 1200));
          final st = await b.evalJson(pageStateScript);
          if (st == null || st['ready'] != true) continue;
          if (st['blocked'] == true) {
            r = _Login.blocked;
          } else {
            r = st['login'] == true ? _Login.no : _Login.yes;
          }
          break;
        }
      }
    } catch (_) {}
    await b.dispose();
    if (mounted) setState(() => _login = r);
  }

  Future<void> _openLogin() async {
    await Navigator.push(context, MaterialPageRoute(builder: (_) => const LbcLoginScreen()));
    _checkLogin();
  }

  Future<void> _set(void Function(MessageSettings s) f) async {
    final s = _s;
    if (s == null) return;
    setState(() => f(s));
    await s.save();
  }

  Future<void> _reactivate() async {
    await MessageSettings.setFailures(0);
    await _set((s) => s.autoSuspended = false);
    await RadarDb.log('✉️ Envoi auto réactivé');
  }

  /// Analyse liée au message (radar ou historique), pour un nouvel essai.
  Future<HistoryEntry?> _entryFor(SellerMessage m) async {
    final a = await RadarDb.analysis(m.listId);
    if (a != null) return a.entry;
    final h = await HistoryStore.load();
    return h.where((e) => listIdOf(e) == m.listId || e.url == m.url).firstOrNull;
  }

  Future<void> _details(SellerMessage m) async {
    final cs = Theme.of(context).colorScheme;
    final action = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(m.title, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
            const SizedBox(height: 6),
            Wrap(spacing: 8, runSpacing: 6, children: [
              Pill(label: MsgStatus.label(m.status), color: _color(m.status, cs)),
              if (m.offer != null) Pill(label: 'Proposé ${euros(m.offer)}', color: cs.primary),
              if (m.auto) const Pill(label: 'Auto', color: AppColors.neutral),
            ]),
            const SizedBox(height: 10),
            Text(_dates(m), style: TextStyle(fontSize: 12.5, color: cs.onSurfaceVariant)),
            if (m.error.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text('Étape « ${m.step} » : ${m.error}', style: const TextStyle(color: AppColors.bad, fontSize: 13)),
            ],
            const SizedBox(height: 12),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(color: cs.surfaceContainerHigh, borderRadius: BorderRadius.circular(12)),
              child: SelectableText(m.text.isEmpty ? '(message pas encore rédigé)' : m.text),
            ),
            if (m.reply.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text('Réponse du vendeur${m.repliedAt == null ? '' : ' (${shortDate(m.repliedAt!)})'} :',
                  style: const TextStyle(fontWeight: FontWeight.w700)),
              const SizedBox(height: 4),
              SelectableText(m.reply),
            ],
            const SizedBox(height: 14),
            Wrap(spacing: 8, runSpacing: 8, children: [
              FilledButton.tonalIcon(
                  onPressed: () => Navigator.pop(ctx, 'open'),
                  icon: const Icon(Icons.open_in_new, size: 18),
                  label: const Text('Voir l\'annonce')),
              if (m.text.isNotEmpty)
                OutlinedButton.icon(
                    onPressed: () => Navigator.pop(ctx, 'copy'),
                    icon: const Icon(Icons.copy, size: 18),
                    label: const Text('Copier')),
              if (const [MsgStatus.sent, MsgStatus.replied, MsgStatus.agreed].contains(m.status))
                FilledButton.icon(
                    onPressed: () => Navigator.pop(ctx, 'reply'),
                    icon: const Icon(Icons.reply, size: 18),
                    label: const Text('Répondre')),
              if (!const [MsgStatus.sent, MsgStatus.sending, MsgStatus.replied, MsgStatus.agreed, MsgStatus.bought]
                  .contains(m.status))
                FilledButton.icon(
                    onPressed: () => Navigator.pop(ctx, 'retry'),
                    icon: const Icon(Icons.send_outlined, size: 18),
                    label: Text(m.status == MsgStatus.queued ? 'Envoyer maintenant' : 'Reprendre')),
              if (m.status == MsgStatus.queued || m.status == MsgStatus.confirm)
                TextButton(onPressed: () => Navigator.pop(ctx, 'cancel'), child: const Text('Annuler l\'envoi')),
              if (m.status == MsgStatus.confirm || m.status == MsgStatus.failed)
                TextButton(onPressed: () => Navigator.pop(ctx, 'sent'), child: const Text('Je l\'ai envoyé')),
            ]),
          ]),
        ),
      ),
    );
    if (!mounted || action == null) return;
    switch (action) {
      case 'open':
        openExternal(m.url);
      case 'copy':
        await Clipboard.setData(ClipboardData(text: m.text));
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Message copié.')));
        }
      case 'cancel':
        await MessageStore.update(m.id, status: MsgStatus.cancelled, error: 'annulé à la main');
      case 'sent':
        await MessageStore.update(m.id, status: MsgStatus.sent, error: '', sentNow: true);
      case 'reply':
        await Navigator.push(
            context, MaterialPageRoute(builder: (_) => ReplyScreen(messageId: m.id, settings: widget.settings)));
      case 'retry':
        final e = await _entryFor(m);
        if (!mounted) return;
        if (e == null) {
          ScaffoldMessenger.of(context)
              .showSnackBar(const SnackBar(content: Text('Analyse introuvable : rouvre l\'annonce depuis le Radar.')));
          return;
        }
        await contactSeller(context, e, widget.settings.minMargin, existing: m);
    }
    _load();
  }

  static Color _color(String status, ColorScheme cs) => switch (status) {
        MsgStatus.sent => AppColors.good,
        MsgStatus.replied => AppColors.warn,
        MsgStatus.agreed => AppColors.good,
        MsgStatus.bought => AppColors.good,
        MsgStatus.test => AppColors.good,
        MsgStatus.failed => AppColors.bad,
        MsgStatus.confirm => AppColors.warn,
        MsgStatus.queued => cs.primary,
        MsgStatus.sending => cs.primary,
        _ => AppColors.neutral,
      };

  static String _dates(SellerMessage m) {
    final parts = ['Créé ${shortDate(m.createdAt)}'];
    if (m.sentAt != null) parts.add('envoyé ${shortDate(m.sentAt!)}');
    if (m.status == MsgStatus.queued && m.notBefore != null) parts.add('prévu ${shortDate(m.notBefore!)}');
    return parts.join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final s = _s;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Messages'),
        actions: [
          IconButton(
            tooltip: 'Réglages des messages',
            icon: const Icon(Icons.tune),
            onPressed: () async {
              await Navigator.push(context, MaterialPageRoute(builder: (_) => const MessageSettingsScreen()));
              _load();
            },
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 32), children: [
          _account(cs),
          const SizedBox(height: 10),
          if (s != null) _auto(s, cs),
          const SizedBox(height: 18),
          Row(children: [
            const Text('Envois', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
            const Spacer(),
            Text('${_msgs.length}', style: TextStyle(color: cs.onSurfaceVariant)),
          ]),
          const SizedBox(height: 8),
          if (_msgs.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 30),
              child: Text(
                'Aucun message pour l\'instant.\nAppuie sur « Message vendeur » depuis un résultat.',
                textAlign: TextAlign.center,
                style: TextStyle(color: cs.onSurfaceVariant),
              ),
            )
          else
            for (final m in _msgs) ...[
              AppCard(
                padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
                onTap: () => _details(m),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    Expanded(
                      child: Text(m.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
                    ),
                    const SizedBox(width: 8),
                    Pill(label: MsgStatus.label(m.status), color: _color(m.status, cs)),
                  ]),
                  const SizedBox(height: 4),
                  Text(
                    '${m.offer == null ? 'Sans offre' : 'Proposé ${euros(m.offer)}'} · ${_dates(m)}${m.auto ? ' · auto' : ''}',
                    style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12.5),
                  ),
                  if (m.text.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(m.text, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13)),
                  ],
                  if (m.error.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text('${m.step} : ${m.error}',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 12.5, color: AppColors.bad)),
                  ],
                ]),
              ),
              const SizedBox(height: 8),
            ],
        ]),
      ),
    );
  }

  Widget _account(ColorScheme cs) {
    final (icon, color, text) = switch (_login) {
      _Login.yes => (Icons.verified_user, AppColors.good, 'Connecté'),
      _Login.no => (Icons.no_accounts, AppColors.bad, 'Non connecté'),
      _Login.blocked => (Icons.gpp_maybe, AppColors.warn, 'Vérification Leboncoin à faire'),
      _Login.checking => (Icons.hourglass_top, cs.primary, 'Vérification…'),
      _Login.unknown => (Icons.help_outline, AppColors.neutral, 'État inconnu'),
    };
    return AppCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(icon, color: color),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('Compte Leboncoin', style: TextStyle(fontWeight: FontWeight.w800)),
              Text(text, style: TextStyle(color: color, fontWeight: FontWeight.w600)),
            ]),
          ),
          IconButton(
            tooltip: 'Vérifier',
            onPressed: _login == _Login.checking ? null : _checkLogin,
            icon: const Icon(Icons.refresh),
          ),
        ]),
        const SizedBox(height: 10),
        SizedBox(
          width: double.infinity,
          child: _login == _Login.yes
              ? OutlinedButton.icon(
                  onPressed: _openLogin, icon: const Icon(Icons.manage_accounts), label: const Text('Ouvrir mon compte'))
              : FilledButton.icon(
                  onPressed: _openLogin, icon: const Icon(Icons.login), label: const Text('Se connecter à Leboncoin')),
        ),
        const SizedBox(height: 6),
        Text('Je tape moi-même mes identifiants ; le mot de passe n\'est jamais enregistré.',
            style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
      ]),
    );
  }

  Widget _auto(MessageSettings s, ColorScheme cs) {
    final modeText = switch (s.mode) {
      SendMode.confirm => 'Mode : toujours confirmer',
      SendMode.direct => 'Mode : envoi direct',
      SendMode.auto => 'Mode : automatique (bonnes affaires)',
    };
    return AppCard(
      padding: const EdgeInsets.fromLTRB(4, 4, 4, 12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SwitchListTile(
          value: s.autoEnabled,
          onChanged: (v) => _set((s) => s.autoEnabled = v),
          title: const Text('Envoi auto', style: TextStyle(fontWeight: FontWeight.w800)),
          subtitle: Text(s.mode == SendMode.auto
              ? 'Le radar contacte seul les bonnes affaires sûres.'
              : 'Choisis le mode « automatique » dans les réglages pour l\'utiliser.'),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Wrap(spacing: 8, runSpacing: 6, children: [
            Pill(label: modeText, color: cs.primary),
            if (s.dryRun) const Pill(label: 'Test à blanc', icon: Icons.science_outlined, color: AppColors.warn),
            Pill(label: 'Auto aujourd\'hui : $_autoToday / ${s.dailyMax}', color: AppColors.neutral),
          ]),
        ),
        if (s.autoSuspended) ...[
          const SizedBox(height: 10),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                  color: AppColors.bad.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(12)),
              child: Row(children: [
                const Icon(Icons.pause_circle, color: AppColors.bad),
                const SizedBox(width: 10),
                const Expanded(
                  child: Text('Envoi auto suspendu (échecs ou vérification anti-robot). Vérifie le journal.',
                      style: TextStyle(fontSize: 13)),
                ),
                TextButton(onPressed: _reactivate, child: const Text('Réactiver')),
              ]),
            ),
          ),
        ],
      ]),
    );
  }
}
