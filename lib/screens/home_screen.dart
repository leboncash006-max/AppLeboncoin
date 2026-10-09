import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../models.dart';
import '../services/analyzer.dart';
import '../services/leboncoin_reader.dart';
import '../services/settings.dart';
import 'settings_screen.dart';

class HomeScreen extends StatefulWidget {
  final Settings settings;
  const HomeScreen({super.key, required this.settings});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _url = TextEditingController();
  final _title = TextEditingController();
  final _desc = TextEditingController();
  final _price = TextEditingController();

  bool _manual = false;
  bool _busy = false;
  bool _showWeb = false;
  String? _step;
  String? _error;
  WebViewController? _web;
  AdData? _ad;
  Analysis? _result;

  Settings get s => widget.settings;

  // ---------------------------------------------------------------- actions

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (data?.text != null) {
      _url.text = data!.text!.trim();
      _analyzeLink();
    }
  }

  Future<void> _analyzeLink() async {
    FocusScope.of(context).unfocus();
    final uri = extractLeboncoinUrl(_url.text);
    if (uri == null) {
      setState(() => _error = 'Colle un lien d\'annonce leboncoin.fr.');
      return;
    }

    final web = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..loadRequest(uri);
    setState(() {
      _busy = true;
      _error = null;
      _result = null;
      _ad = null;
      _web = web;
      _showWeb = true;
      _step = 'Ouverture de l\'annonce…';
    });

    AdData? ad;
    final deadline = DateTime.now().add(const Duration(seconds: 25));
    var extended = false;
    while (DateTime.now().isBefore(deadline) || (extended && ad == null && _busy)) {
      await Future.delayed(const Duration(milliseconds: 1500));
      if (!mounted || _web != web) return; // nouvelle analyse lancée entre-temps
      try {
        final j = decodeJsResult(await web.runJavaScriptReturningResult(extractionScript));
        final candidate = adDataFromJs(uri, j);
        if (candidate.isComplete) {
          ad = candidate;
          break;
        }
        if (j['blocked'] == true && !extended) {
          // Leboncoin affiche un test anti-robot : c'est à toi de le faire.
          extended = true;
          setState(() => _step =
              'Leboncoin demande une vérification : fais-la dans la fenêtre ci-dessous.');
        }
      } catch (_) {
        // page pas encore prête
      }
      if (extended && DateTime.now().isAfter(deadline.add(const Duration(minutes: 2)))) break;
    }

    if (!mounted || _web != web) return;
    if (ad == null) {
      setState(() {
        _busy = false;
        _step = null;
        _error = 'Impossible de lire l\'annonce. Copie le titre et la description '
            'en mode manuel.';
      });
      return;
    }
    setState(() {
      _ad = ad;
      _showWeb = false;
    });
    await _run(ad.title, ad.description, ad.price, ad.attributesText);
  }

  Future<void> _analyzeManual() async {
    FocusScope.of(context).unfocus();
    if (_title.text.trim().isEmpty && _desc.text.trim().isEmpty) {
      setState(() => _error = 'Colle au moins le titre de l\'annonce.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
      _result = null;
      _ad = null;
    });
    final price = double.tryParse(_price.text.replaceAll(',', '.').replaceAll('€', '').trim());
    await _run(_title.text.trim(), _desc.text.trim(), price, '');
  }

  Future<void> _run(String title, String desc, double? price, String attrs) async {
    try {
      final a = await Analyzer(s).analyze(title, desc, price,
          attributes: attrs, onStep: (st) {
        if (mounted) setState(() => _step = st);
      });
      if (mounted) setState(() => _result = a);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _step = null;
        });
      }
    }
  }

  void _open(String url) =>
      launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);

  // -------------------------------------------------------------------- UI

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('MPB Check'),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: () async {
              await Navigator.push(context,
                  MaterialPageRoute(builder: (_) => SettingsScreen(settings: s)));
              setState(() {});
            },
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          SegmentedButton<bool>(
            segments: const [
              ButtonSegment(value: false, icon: Icon(Icons.link), label: Text('Lien')),
              ButtonSegment(value: true, icon: Icon(Icons.edit_note), label: Text('Texte')),
            ],
            selected: {_manual},
            onSelectionChanged: _busy ? null : (v) => setState(() => _manual = v.first),
          ),
          const SizedBox(height: 16),
          if (!_manual) ..._linkForm() else ..._manualForm(),
          if (_step != null) ...[
            const SizedBox(height: 16),
            Row(children: [
              const SizedBox(
                  width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
              const SizedBox(width: 12),
              Expanded(child: Text(_step!)),
            ]),
          ],
          if (_web != null && _showWeb) ...[
            const SizedBox(height: 12),
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: SizedBox(height: 380, child: WebViewWidget(controller: _web!)),
            ),
          ],
          if (_error != null) ...[
            const SizedBox(height: 16),
            Card(
              color: Theme.of(context).colorScheme.errorContainer,
              child: ListTile(
                leading: const Icon(Icons.error_outline),
                title: Text(_error!),
              ),
            ),
          ],
          if (_ad != null) ...[
            const SizedBox(height: 16),
            _AdCard(ad: _ad!, onOpen: () => _open(_ad!.url)),
          ],
          if (_result != null) ...[
            const SizedBox(height: 12),
            _ResultCard(result: _result!, minMargin: s.minMargin, onOpen: _open),
          ],
        ],
      ),
    );
  }

  List<Widget> _linkForm() => [
        TextField(
          controller: _url,
          keyboardType: TextInputType.url,
          decoration: InputDecoration(
            labelText: 'Lien de l\'annonce Leboncoin',
            border: const OutlineInputBorder(),
            suffixIcon: IconButton(
                icon: const Icon(Icons.content_paste), onPressed: _busy ? null : _paste),
          ),
          onSubmitted: (_) => _analyzeLink(),
        ),
        const SizedBox(height: 12),
        FilledButton.icon(
          onPressed: _busy ? null : _analyzeLink,
          icon: const Icon(Icons.search),
          label: const Text('Analyser'),
        ),
      ];

  List<Widget> _manualForm() => [
        TextField(
          controller: _title,
          decoration: const InputDecoration(labelText: 'Titre', border: OutlineInputBorder()),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _desc,
          minLines: 4,
          maxLines: 10,
          decoration:
              const InputDecoration(labelText: 'Description', border: OutlineInputBorder()),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _price,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: const InputDecoration(
              labelText: 'Prix (€)', border: OutlineInputBorder(), suffixText: '€'),
        ),
        const SizedBox(height: 12),
        FilledButton.icon(
          onPressed: _busy ? null : _analyzeManual,
          icon: const Icon(Icons.search),
          label: const Text('Analyser'),
        ),
      ];
}

class _AdCard extends StatelessWidget {
  final AdData ad;
  final VoidCallback onOpen;
  const _AdCard({required this.ad, required this.onOpen});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(ad.title, style: t.titleMedium),
          if (ad.price != null) Text('${ad.price!.toStringAsFixed(0)} €', style: t.titleLarge),
          if (ad.attributes.isNotEmpty) ...[
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: ad.attributes.entries
                  .take(6)
                  .map((e) => Chip(
                        label: Text('${e.key} : ${e.value}'),
                        visualDensity: VisualDensity.compact,
                      ))
                  .toList(),
            ),
          ],
          if (ad.description.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(ad.description, maxLines: 4, overflow: TextOverflow.ellipsis),
          ],
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
                onPressed: onOpen,
                icon: const Icon(Icons.open_in_new, size: 18),
                label: const Text('Voir l\'annonce')),
          ),
        ]),
      ),
    );
  }
}

class _ResultCard extends StatelessWidget {
  final Analysis result;
  final double minMargin;
  final void Function(String url) onOpen;
  const _ResultCard({required this.result, required this.minMargin, required this.onOpen});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final m = result.margin;
    final Color color;
    final String verdict;
    if (m == null) {
      color = Colors.grey;
      verdict = 'Prix inconnu';
    } else if (m >= minMargin) {
      color = Colors.green.shade600;
      verdict = 'Bonne affaire';
    } else if (m >= 0) {
      color = Colors.orange.shade700;
      verdict = 'Marge trop faible';
    } else {
      color = Colors.red.shade600;
      verdict = 'Pas rentable';
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(verdict, style: t.titleMedium?.copyWith(color: color)),
          Text(
            m == null ? '—' : '${m >= 0 ? '+' : ''}${m.toStringAsFixed(0)} €',
            style: t.displaySmall?.copyWith(color: color, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          _row('Prix de l\'annonce',
              result.price == null ? '?' : '${result.price!.toStringAsFixed(0)} €'),
          _row('Reprise MPB estimée', '${result.totalBuyback.toStringAsFixed(0)} €'),
          if (result.shutterCount != null)
            _row('Déclenchements', '${result.shutterCount}'),
          const Divider(height: 24),
          ...result.items.map((i) => _item(context, i)),
          if (result.warnings.isNotEmpty) ...[
            const SizedBox(height: 8),
            ...result.warnings.map((w) => Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Icon(Icons.warning_amber, size: 18, color: Colors.orange.shade700),
                    const SizedBox(width: 6),
                    Expanded(child: Text(w)),
                  ]),
                )),
          ],
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerRight,
            child: OutlinedButton.icon(
              onPressed: () => onOpen('https://www.mpb.com/fr-fr/vente-ou-reprise'),
              icon: const Icon(Icons.sell_outlined),
              label: const Text('Faire l\'estimation sur MPB'),
            ),
          ),
        ]),
      ),
    );
  }

  Widget _row(String a, String b) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(children: [Expanded(child: Text(a)), Text(b)]),
      );

  Widget _item(BuildContext context, ItemResult i) {
    final icon = switch (i.item.type) {
      'boitier' => Icons.photo_camera,
      'objectif' => Icons.camera,
      'flash' => Icons.flash_on,
      _ => Icons.devices_other,
    };
    final name = i.mpbModel ?? '${i.item.nameGuess} (introuvable chez MPB)';
    String sub;
    if (i.source == 'estimation réelle') {
      sub = 'Vraie estimation MPB (état Bon)';
    } else if (i.resale != null && i.coef != null) {
      sub = 'Revente MPB ${i.resale!.basis} : ${i.resale!.median.toStringAsFixed(0)} € '
          '(${i.resale!.count} en vente) × ${i.coef}';
    } else {
      sub = 'Pas de prix de référence';
    }
    if (i.mpbModel != null && !i.confident) sub += '\n⚠️ Version à vérifier';
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(icon),
      title: Text(name),
      subtitle: Text(sub),
      isThreeLine: sub.contains('\n'),
      trailing: Text(i.buyback == null ? '—' : '~${i.buyback!.toStringAsFixed(0)} €',
          style: Theme.of(context).textTheme.titleMedium),
      onTap: i.resale?.productUrl == null ? null : () => onOpen(i.resale!.productUrl!),
    );
  }
}
