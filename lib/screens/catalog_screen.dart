import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import '../services/mpb_catalog.dart';
import '../theme.dart';

/// Le catalogue MPB gardé dans l'appli : tous les noms exacts de modèles avec
/// leur identifiant. C'est la liste avec laquelle l'IA fait la correspondance.
class CatalogScreen extends StatefulWidget {
  const CatalogScreen({super.key});

  @override
  State<CatalogScreen> createState() => _CatalogScreenState();
}

class _CatalogScreenState extends State<CatalogScreen> {
  MpbCatalog? _catalog;
  bool _loaded = false;
  List<MapEntry<String, int>> _all = [];
  List<MapEntry<String, int>> _shown = [];
  final _q = TextEditingController();
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    MpbCatalog.load().then((c) {
      if (!mounted) return;
      final all = (c?.ids.entries.toList() ?? [])..sort((a, b) => a.key.toLowerCase().compareTo(b.key.toLowerCase()));
      setState(() {
        _catalog = c;
        _loaded = true;
        _all = all;
        _shown = all;
      });
    });
  }

  @override
  void dispose() {
    _q.dispose();
    super.dispose();
  }

  /// Filtre : tous les mots tapés doivent apparaître (« sony a68 », « 18-55 canon »).
  /// Si rien ne correspond, on montre les noms les plus proches (même calcul que l'analyse).
  void _filter(String q) {
    final words = MpbCatalog.tokens(q);
    if (words.isEmpty) {
      setState(() => _shown = _all);
      return;
    }
    var shown = _all.where((e) {
      final t = MpbCatalog.tokens(e.key);
      return words.every((w) => t.any((x) => x.startsWith(w)));
    }).toList();
    final c = _catalog;
    if (shown.isEmpty && c != null) {
      shown = c.match(q, limit: 30).map((n) => MapEntry(n, c.ids[n] ?? 0)).toList();
    }
    setState(() => _shown = shown);
  }

  String _csv(List<MapEntry<String, int>> rows) =>
      'model_name;model_id\n${rows.map((e) => '${e.key.replaceAll(';', ',')};${e.value}').join('\n')}';

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: _csv(_shown)));
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('${_shown.length} modèles copiés (format CSV).')));
    }
  }

  Future<void> _pdf() async {
    final rows = _shown;
    final c = _catalog;
    if (c == null) return;
    setState(() => _busy = true);
    try {
      final theme = pw.ThemeData.withFont(
        base: pw.Font.ttf(await rootBundle.load('assets/fonts/Roboto-Regular.ttf')),
        bold: pw.Font.ttf(await rootBundle.load('assets/fonts/Roboto-Bold.ttf')),
      );
      final doc = pw.Document(theme: theme);
      const perPage = 60;
      doc.addPage(pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.all(28),
        maxPages: 2000,
        header: (ctx) => pw.Text(
            'Catalogue MPB — ${rows.length} modèles${_q.text.trim().isEmpty ? '' : ' (« ${_q.text.trim()} »)'} — '
            'mis à jour le ${shortDate(c.date)}',
            style: const pw.TextStyle(fontSize: 9, color: PdfColors.grey700)),
        build: (ctx) => [
          for (var i = 0; i < rows.length; i += perPage)
            pw.TableHelper.fromTextArray(
              headers: ['Nom exact du modèle MPB', 'Identifiant'],
              data: [for (final e in rows.skip(i).take(perPage)) [e.key, '${e.value}']],
              headerStyle: const pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 8.5),
              cellStyle: const pw.TextStyle(fontSize: 8.5),
              cellAlignments: {1: pw.Alignment.centerRight},
              columnWidths: {0: const pw.FlexColumnWidth(5), 1: const pw.FlexColumnWidth(1)},
              cellPadding: const pw.EdgeInsets.symmetric(horizontal: 4, vertical: 2),
            ),
        ],
      ));
      await Printing.sharePdf(bytes: await doc.save(), filename: 'catalogue-mpb.pdf');
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Export impossible : $e')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final c = _catalog;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Catalogue MPB'),
        actions: [
          IconButton(tooltip: 'Copier (CSV)', onPressed: c == null ? null : _copy, icon: const Icon(Icons.copy)),
          IconButton(
            tooltip: 'Exporter en PDF',
            onPressed: c == null || _busy ? null : _pdf,
            icon: _busy
                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.picture_as_pdf_outlined),
          ),
        ],
      ),
      body: !_loaded
          ? const Center(child: CircularProgressIndicator())
          : c == null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                        'Catalogue pas encore téléchargé.\nLance une analyse : il est récupéré chez MPB '
                        'automatiquement (une seule fois, puis chaque semaine).',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: cs.onSurfaceVariant)),
                  ),
                )
              : Column(children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
                    child: TextField(
                      controller: _q,
                      onChanged: _filter,
                      decoration: const InputDecoration(
                          prefixIcon: Icon(Icons.search), hintText: 'Ex. sony a68, canon 18-55, nikon d3200'),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 4, 20, 4),
                    child: Row(children: [
                      Text('${_shown.length} / ${c.size} modèles',
                          style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12.5)),
                      const Spacer(),
                      Text('MAJ ${shortDate(c.date)}', style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12.5)),
                    ]),
                  ),
                  Expanded(
                    child: ListView.builder(
                      itemCount: _shown.length,
                      itemBuilder: (_, i) {
                        final e = _shown[i];
                        return ListTile(
                          dense: true,
                          title: Text(e.key),
                          trailing: Text('${e.value}', style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12)),
                          onLongPress: () {
                            Clipboard.setData(ClipboardData(text: e.key));
                            ScaffoldMessenger.of(context)
                                .showSnackBar(SnackBar(content: Text('« ${e.key} » copié.')));
                          },
                        );
                      },
                    ),
                  ),
                ]),
    );
  }
}
