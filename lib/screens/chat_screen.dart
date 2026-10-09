import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/gemini_service.dart';
import '../services/history.dart';
import '../services/settings.dart';
import '../theme.dart';
import '../widgets/common.dart';

const suggestedQuestions = [
  'Le prix est-il négociable ?',
  'Quels défauts vérifier avant d\'acheter ?',
  'Où le revendre plus cher que MPB ?',
  'Quel prix proposer au vendeur ?',
];

/// Contexte complet envoyé en systemInstruction : annonce + analyse.
String buildChatContext(HistoryEntry e, Settings s) {
  final a = e.analysis;
  final b = StringBuffer()
    ..writeln("Tu es un expert en achat-revente de matériel photo d'occasion "
        '(boîtiers, objectifs, flashs) en France. Tu aides un revendeur qui achète '
        'sur Leboncoin pour revendre, notamment à MPB (reprise).')
    ..writeln('Consignes : réponds en français, court et concret (quelques phrases '
        'ou une petite liste), chiffres en euros. Sois honnête sur l\'incertitude : '
        'dis quand une info manque ou quand une estimation est fragile. Utilise la '
        'recherche web pour les prix du marché actuels quand c\'est utile. '
        "N'invente pas de détails absents de l'annonce.")
    ..writeln()
    ..writeln('=== ANNONCE LEBONCOIN ===')
    ..writeln('Titre : ${e.title}')
    ..writeln('Prix : ${e.adPrice == null ? "inconnu" : "${e.adPrice!.toStringAsFixed(0)} €"}');
  if (e.url.isNotEmpty) b.writeln('Lien : ${e.url}');
  if (e.attributes.isNotEmpty) b.writeln('Attributs :\n${e.attributesText}');
  b
    ..writeln('Description :\n"""\n${e.description}\n"""')
    ..writeln()
    ..writeln('=== ANALYSE MPB CHECK ===')
    ..writeln('Prix retenu : ${a.price == null ? "inconnu" : "${a.price!.toStringAsFixed(0)} €"}')
    ..writeln('Reprise MPB totale estimée : ${a.totalBuyback.toStringAsFixed(0)} €')
    ..writeln('Marge estimée (reprise − prix) : '
        '${a.margin == null ? "inconnue" : "${a.margin!.toStringAsFixed(0)} €"} '
        '(seuil « bonne affaire » : ${s.minMargin.toStringAsFixed(0)} €)')
    ..writeln('État annoncé (déduit) : ${a.conditionHint}');
  if (a.shutterCount != null) b.writeln('Déclenchements : ${a.shutterCount}');
  if (a.defects.isNotEmpty) b.writeln('Défauts signalés : ${a.defects.join(", ")}');
  b.writeln('Éléments :');
  for (final it in a.items) {
    b.write('- ${it.item.type} « ${it.item.nameGuess} »');
    b.write(it.mpbModel == null
        ? ' : introuvable chez MPB'
        : ' → modèle MPB « ${it.mpbModel} »${it.confident ? "" : " (version incertaine)"}');
    if (it.resale != null) {
      b.write(' ; revente MPB médiane ${it.resale!.median.toStringAsFixed(0)} € '
          '(${it.resale!.basis}, ${it.resale!.count} en vente)');
    }
    if (it.buyback != null) {
      b.write(' ; reprise estimée ${it.buyback!.toStringAsFixed(0)} € (${it.source}'
          '${it.coef != null ? ", coef ${it.coef}" : ""})');
    }
    if (it.item.details.isNotEmpty) b.write(' ; détails : ${it.item.details}');
    b.writeln();
  }
  if (a.warnings.isNotEmpty) {
    b.writeln('Alertes :');
    for (final w in a.warnings) {
      b.writeln('- $w');
    }
  }
  return b.toString();
}

class ChatScreen extends StatefulWidget {
  final HistoryEntry entry;
  final Settings settings;
  const ChatScreen({super.key, required this.entry, required this.settings});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  bool _busy = false;

  List<ChatMessage> get _msgs => widget.entry.chat;

  @override
  void dispose() {
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _toBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(_scroll.position.maxScrollExtent + 200,
            duration: const Duration(milliseconds: 350), curve: Curves.easeOutCubic);
      }
    });
  }

  /// Historique au format Gemini : sans les erreurs, rôles alternés.
  List<({String role, String text})> _turns() {
    final out = <({String role, String text})>[];
    for (final m in _msgs.where((m) => !m.isError)) {
      if (out.isNotEmpty && out.last.role == m.role) out.removeLast();
      out.add((role: m.role, text: m.text));
    }
    return out;
  }

  Future<void> _send(String text) async {
    final q = text.trim();
    if (q.isEmpty || _busy) return;
    _input.clear();
    setState(() {
      _msgs.add(ChatMessage('user', q));
      _busy = true;
    });
    _toBottom();
    try {
      final reply = await GeminiService()
          .chat(buildChatContext(widget.entry, widget.settings), _turns());
      _msgs.add(ChatMessage(
        'model',
        reply.searched ? reply.text : '${reply.text}\n\n_(réponse sans recherche web)_',
        sources: reply.sources.map((s) => WebSource(s.uri, s.title)).toList(),
      ));
      HapticFeedback.lightImpact();
    } catch (e) {
      _msgs.add(ChatMessage('model', e.toString().replaceFirst('Exception: ', ''),
          isError: true));
    }
    await HistoryStore.upsert(widget.entry);
    if (!mounted) return;
    setState(() => _busy = false);
    _toBottom();
  }

  Future<void> _clear() async {
    setState(() => _msgs.clear());
    await HistoryStore.upsert(widget.entry);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Questions'),
          Text(widget.entry.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  fontSize: 12.5, fontWeight: FontWeight.w500, color: cs.onSurfaceVariant)),
        ]),
        actions: [
          if (_msgs.isNotEmpty)
            IconButton(
              tooltip: 'Effacer la conversation',
              icon: const Icon(Icons.delete_sweep_outlined),
              onPressed: _busy ? null : _clear,
            ),
        ],
      ),
      body: Column(children: [
        Expanded(
          child: _msgs.isEmpty
              ? _Empty(onPick: _send)
              : ListView.builder(
                  controller: _scroll,
                  padding: const EdgeInsets.fromLTRB(14, 8, 14, 12),
                  itemCount: _msgs.length + (_busy ? 1 : 0),
                  itemBuilder: (_, i) => i == _msgs.length
                      ? const _Typing()
                      : FadeSlideIn(offsetY: 10, child: _Bubble(msg: _msgs[i])),
                ),
        ),
        if (_msgs.isNotEmpty && !_busy)
          SizedBox(
            height: 44,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 14),
              children: [
                for (final s in suggestedQuestions)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ActionChip(label: Text(s), onPressed: () => _send(s)),
                  ),
              ],
            ),
          ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 6, 12, 10),
            child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
              Expanded(
                child: TextField(
                  controller: _input,
                  minLines: 1,
                  maxLines: 5,
                  textCapitalization: TextCapitalization.sentences,
                  textInputAction: TextInputAction.send,
                  onSubmitted: _send,
                  decoration: const InputDecoration(
                    hintText: 'Pose ta question…',
                    contentPadding: EdgeInsets.symmetric(horizontal: 18, vertical: 14),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              IconButton.filled(
                style: IconButton.styleFrom(minimumSize: const Size(52, 52)),
                onPressed: _busy ? null : () => _send(_input.text),
                icon: const Icon(Icons.arrow_upward_rounded),
              ),
            ]),
          ),
        ),
      ]),
    );
  }
}

class _Empty extends StatelessWidget {
  final void Function(String) onPick;
  const _Empty({required this.onPick});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 24, 20, 20),
      children: [
        Icon(Icons.forum_outlined, size: 44, color: cs.primary),
        const SizedBox(height: 12),
        Text("Une question sur l'annonce ?",
            textAlign: TextAlign.center, style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 6),
        Text(
          "L'IA connaît l'annonce et l'analyse complète, et peut chercher sur le web.",
          textAlign: TextAlign.center,
          style: TextStyle(color: cs.onSurfaceVariant),
        ),
        const SizedBox(height: 22),
        for (final s in suggestedQuestions)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: AppCard(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              onTap: () => onPick(s),
              child: Row(children: [
                Icon(Icons.auto_awesome, size: 18, color: cs.primary),
                const SizedBox(width: 12),
                Expanded(child: Text(s, style: const TextStyle(fontWeight: FontWeight.w600))),
                Icon(Icons.chevron_right, color: cs.onSurfaceVariant),
              ]),
            ),
          ),
      ],
    );
  }
}

class _Bubble extends StatelessWidget {
  final ChatMessage msg;
  const _Bubble({required this.msg});

  void _open(String url) =>
      launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final user = msg.isUser;
    final bg = user
        ? cs.primary
        : msg.isError
            ? AppColors.bad.withValues(alpha: 0.12)
            : cs.surfaceContainerHigh;
    final fg = user ? cs.onPrimary : cs.onSurface;

    final Widget content = user || msg.isError
        ? Text(msg.text, style: TextStyle(color: fg, height: 1.35))
        : MarkdownBody(
            data: msg.text,
            selectable: true,
            onTapLink: (_, href, __) {
              if (href != null) _open(href);
            },
            styleSheet: MarkdownStyleSheet.fromTheme(Theme.of(context)).copyWith(
              p: TextStyle(color: fg, height: 1.4, fontSize: 14.5),
              listBullet: TextStyle(color: fg),
              strong: const TextStyle(fontWeight: FontWeight.w800),
            ),
          );

    return Align(
      alignment: user ? Alignment.centerRight : Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width * 0.86),
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 5),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.only(
              topLeft: const Radius.circular(18),
              topRight: const Radius.circular(18),
              bottomLeft: Radius.circular(user ? 18 : 6),
              bottomRight: Radius.circular(user ? 6 : 18),
            ),
            border: msg.isError ? Border.all(color: AppColors.bad.withValues(alpha: 0.5)) : null,
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            content,
            if (msg.sources.isNotEmpty) ...[
              const SizedBox(height: 10),
              Text('Sources',
                  style: TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.8,
                      color: cs.onSurfaceVariant)),
              const SizedBox(height: 6),
              Wrap(spacing: 6, runSpacing: 6, children: [
                for (final s in msg.sources)
                  ActionChip(
                    avatar: const Icon(Icons.link, size: 16),
                    label: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 200),
                      child: Text(s.title, overflow: TextOverflow.ellipsis),
                    ),
                    labelStyle: const TextStyle(fontSize: 12),
                    visualDensity: VisualDensity.compact,
                    onPressed: () => _open(s.uri),
                  ),
              ]),
            ],
          ]),
        ),
      ),
    );
  }
}

class _Typing extends StatefulWidget {
  const _Typing();

  @override
  State<_Typing> createState() => _TypingState();
}

class _TypingState extends State<_Typing> with SingleTickerProviderStateMixin {
  late final _c =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 1100))..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 5),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
            color: cs.surfaceContainerHigh, borderRadius: BorderRadius.circular(18)),
        child: AnimatedBuilder(
          animation: _c,
          builder: (_, __) => Row(mainAxisSize: MainAxisSize.min, children: [
            for (var i = 0; i < 3; i++)
              Container(
                width: 8,
                height: 8,
                margin: const EdgeInsets.symmetric(horizontal: 3),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: cs.primary.withValues(
                      alpha: 0.3 + 0.7 * (((_c.value * 3 - i) % 3) < 1 ? 1 : 0)),
                ),
              ),
            const SizedBox(width: 8),
            Text('Recherche…', style: TextStyle(color: cs.onSurfaceVariant, fontSize: 13)),
          ]),
        ),
      ),
    );
  }
}
