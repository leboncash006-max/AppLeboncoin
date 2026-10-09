import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import '../models.dart';
import '../radar/radar_db.dart';
import '../services/history.dart';
import '../services/mpb_service.dart';
import '../services/settings.dart';

/// Ce qu'on exporte.
enum ExportScope { radarAll, radarProfitable, history }

/// Feuille de choix puis génération et partage du PDF.
Future<void> showExportSheet(BuildContext context, Settings settings) async {
  final choice = await showModalBottomSheet<(ExportScope, int?)>(
    context: context,
    showDragHandle: true,
    builder: (_) => const _ExportSheet(),
  );
  if (choice == null || !context.mounted) return;
  final messenger = ScaffoldMessenger.of(context);
  messenger.showSnackBar(const SnackBar(content: Text('Création du PDF…')));
  try {
    final bytes = await buildResultsPdf(choice.$1, days: choice.$2, minMargin: settings.minMargin);
    final d = DateTime.now();
    await Printing.sharePdf(
        bytes: bytes,
        filename: 'mpb-check-${d.year}${_pad2(d.month)}${_pad2(d.day)}-${_pad2(d.hour)}${_pad2(d.minute)}.pdf');
  } catch (e) {
    messenger.showSnackBar(SnackBar(content: Text('Export impossible : $e')));
  }
}

String _pad2(int n) => n.toString().padLeft(2, '0');

class _ExportSheet extends StatefulWidget {
  const _ExportSheet();

  @override
  State<_ExportSheet> createState() => _ExportSheetState();
}

class _ExportSheetState extends State<_ExportSheet> {
  ExportScope _scope = ExportScope.radarAll;
  int? _days = 7;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text('Exporter en PDF', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 8),
          RadioGroup<ExportScope>(
            groupValue: _scope,
            onChanged: (v) => setState(() => _scope = v!),
            child: const Column(children: [
              RadioListTile(value: ExportScope.radarAll, title: Text('Radar : toutes les annonces analysées')),
              RadioListTile(value: ExportScope.radarProfitable, title: Text('Radar : seulement les rentables')),
              RadioListTile(value: ExportScope.history, title: Text('Mes analyses (historique)')),
            ]),
          ),
          const SizedBox(height: 4),
          Wrap(spacing: 6, children: [
            for (final (label, d) in [("Aujourd'hui", 1), ('7 jours', 7), ('30 jours', 30), ('Tout', null)])
              ChoiceChip(label: Text(label), selected: _days == d, onSelected: (_) => setState(() => _days = d)),
          ]),
          const SizedBox(height: 14),
          FilledButton.icon(
            onPressed: () => Navigator.pop(context, (_scope, _days)),
            icon: const Icon(Icons.picture_as_pdf_outlined),
            label: const Text('Créer et partager le PDF'),
          ),
        ]),
      ),
    );
  }
}

/// Une ligne du rapport.
class _Row {
  final DateTime date;
  final String title;
  final String source; // recherche ou « manuel »
  final String url;
  final Analysis analysis;
  final double? adPrice;
  _Row(this.date, this.title, this.source, this.url, this.analysis, this.adPrice);
}

/// Nettoie le texte pour le PDF (émojis et symboles rares absents de la police).
String _t(String s) => s
    .replaceAll('—', '-')
    .replaceAll('–', '-')
    .replaceAll(' ', ' ')
    .replaceAll(' ', ' ')
    .replaceAll('−', '-')
    .replaceAll('→', '->')
    .replaceAll('…', '...')
    .replaceAll('’', "'")
    .replaceAll('⛔', '!')
    .replaceAll(RegExp(r'[^\x20-\x7E -ÿ€«»œŒ•→−\n]'), '');

String _eur(double? v, {bool signed = false}) {
  if (v == null) return '-';
  final r = v.round();
  return '${signed && r > 0 ? '+' : ''}$r €';
}

String _date(DateTime d) => '${_pad2(d.day)}/${_pad2(d.month)}/${d.year} ${_pad2(d.hour)}:${_pad2(d.minute)}';

Future<List<_Row>> _rows(ExportScope scope, int? days) async {
  final since = days == null ? null : DateTime.now().subtract(Duration(days: days));
  final rows = <_Row>[];
  if (scope == ExportScope.history) {
    for (final e in await HistoryStore.load()) {
      rows.add(_Row(e.date, e.title, 'manuel', e.url, e.analysis, e.adPrice));
    }
  } else {
    for (final a in await RadarDb.analyses()) {
      if (scope == ExportScope.radarProfitable && !a.profitable) continue;
      final e = a.entry;
      rows.add(_Row(a.createdAt, a.title, a.searchName, a.url, e.analysis, a.price));
    }
  }
  return rows.where((r) => since == null || r.date.isAfter(since)).toList()
    ..sort((a, b) => (b.analysis.margin ?? -1e9).compareTo(a.analysis.margin ?? -1e9));
}

Future<List<int>> _bytes(pw.Document doc) => doc.save();

/// Génère le PDF : synthèse, tableau de toutes les annonces, puis le détail
/// par annonce (éléments, modèle MPB, reprise, alertes).
Future<Uint8List> buildResultsPdf(ExportScope scope, {int? days, required double minMargin}) async {
  final rows = await _rows(scope, days);
  // Roboto embarquée (accents, €, flèches) ; Apache 2.0, fournie avec Flutter
  final theme = pw.ThemeData.withFont(
    base: pw.Font.ttf(await rootBundle.load('assets/fonts/Roboto-Regular.ttf')),
    bold: pw.Font.ttf(await rootBundle.load('assets/fonts/Roboto-Bold.ttf')),
  );
  final doc = pw.Document(title: 'MPB Check - résultats', author: 'MPB Check', theme: theme);
  final title = switch (scope) {
    ExportScope.radarAll => 'Radar : annonces analysées',
    ExportScope.radarProfitable => 'Radar : annonces rentables',
    ExportScope.history => 'Mes analyses',
  };
  final period = days == null ? 'toute la période' : (days == 1 ? "aujourd'hui" : '$days derniers jours');
  final profitable = rows.where((r) => (r.analysis.margin ?? -1) >= minMargin).length;
  final best = rows.isEmpty ? null : rows.first.analysis.margin;
  PdfColor colorFor(double? m) => m == null
      ? PdfColors.grey600
      : m >= minMargin
          ? PdfColors.green700
          : m >= 0
              ? PdfColors.orange700
              : PdfColors.red700;

  doc.addPage(pw.MultiPage(
    pageFormat: PdfPageFormat.a4.landscape,
    margin: const pw.EdgeInsets.all(28),
    header: (_) => pw.Text(_t('MPB Check - $title'),
        style: const pw.TextStyle(fontSize: 9, color: PdfColors.grey600)),
    footer: (c) => pw.Align(
        alignment: pw.Alignment.centerRight,
        child: pw.Text('${c.pageNumber} / ${c.pagesCount}', style: const pw.TextStyle(fontSize: 9))),
    build: (c) => [
      pw.Text(_t(title), style: const pw.TextStyle(fontSize: 22, fontWeight: pw.FontWeight.bold)),
      pw.SizedBox(height: 4),
      pw.Text(_t('Généré le ${_date(DateTime.now())} - $period - seuil de marge ${minMargin.round()} €')),
      pw.SizedBox(height: 10),
      pw.Text(_t('${rows.length} annonce(s), $profitable rentable(s), meilleure marge ${_eur(best, signed: true)}'),
          style: const pw.TextStyle(fontWeight: pw.FontWeight.bold)),
      pw.SizedBox(height: 14),
      if (rows.isEmpty) pw.Text('Aucune annonce sur cette période.'),
      if (rows.isNotEmpty)
        pw.TableHelper.fromTextArray(
          headerStyle: const pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 9),
          cellStyle: const pw.TextStyle(fontSize: 8.5),
          headerDecoration: const pw.BoxDecoration(color: PdfColors.grey300),
          columnWidths: {
            0: const pw.FixedColumnWidth(70),
            1: const pw.FlexColumnWidth(3),
            2: const pw.FlexColumnWidth(1.2),
            3: const pw.FixedColumnWidth(45),
            4: const pw.FixedColumnWidth(50),
            5: const pw.FixedColumnWidth(50),
            6: const pw.FixedColumnWidth(55),
          },
          cellAlignments: {
            3: pw.Alignment.centerRight,
            4: pw.Alignment.centerRight,
            5: pw.Alignment.centerRight,
          },
          headers: ['Date', 'Annonce', 'Recherche', 'Prix', 'Reprise', 'Marge', 'État'],
          data: [
            for (final r in rows)
              [
                _date(r.date),
                _t(r.title),
                _t(r.source),
                _eur(r.adPrice ?? r.analysis.price),
                r.analysis.hasBuyback ? _eur(r.analysis.totalBuyback) : '-',
                _eur(r.analysis.margin, signed: true),
                _t(mpbConditionLabels[r.analysis.condition] ?? (r.analysis.condition == 'parts' ? 'Pièces' : '-')),
              ],
          ],
        ),
      pw.SizedBox(height: 18),
      if (rows.isNotEmpty) pw.Text('Détail', style: const pw.TextStyle(fontSize: 16, fontWeight: pw.FontWeight.bold)),
      for (final r in rows.take(300)) ...[
        pw.SizedBox(height: 10),
        pw.Container(
          padding: const pw.EdgeInsets.all(8),
          decoration: pw.BoxDecoration(border: pw.Border.all(color: PdfColors.grey400), borderRadius: pw.BorderRadius.circular(6)),
          child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
            pw.Row(children: [
              pw.Expanded(
                  child: pw.Text(_t(r.title), style: const pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 11))),
              pw.Text(_eur(r.analysis.margin, signed: true),
                  style: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 12, color: colorFor(r.analysis.margin))),
            ]),
            pw.Text(_t('${_date(r.date)} - ${r.source} - prix ${_eur(r.adPrice ?? r.analysis.price)} -> '
                'reprise ${_eur(r.analysis.totalBuyback)}'),
                style: const pw.TextStyle(fontSize: 9, color: PdfColors.grey700)),
            if (r.url.isNotEmpty)
              pw.UrlLink(
                  destination: r.url,
                  child: pw.Text(r.url, style: const pw.TextStyle(fontSize: 8, color: PdfColors.blue700))),
            pw.SizedBox(height: 4),
            for (final it in r.analysis.items)
              pw.Bullet(
                text: _t('${it.mpbModel ?? it.item.nameGuess} : '
                    '${it.buyback == null ? 'pas de prix' : _eur(it.buyback)}'
                    '${it.realPrice ? ' (prix MPB réel)' : it.approximate ? ' (estimation approximative)' : ''}'
                    '${it.purchasePrices.isEmpty ? '' : ' - ${mpbConditions.where(it.purchasePrices.containsKey).map((c) => '${mpbConditionLabels[c]} ${_eur(it.purchasePrices[c])}').join(', ')}'}'),
                style: const pw.TextStyle(fontSize: 8.5),
              ),
            for (final w in r.analysis.warnings)
              pw.Text(_t(w.startsWith('⛔') ? w : '• $w'), style: const pw.TextStyle(fontSize: 8.5, color: PdfColors.orange800)),
          ]),
        ),
      ],
    ],
  ));
  final out = await _bytes(doc);
  return Uint8List.fromList(out);
}
