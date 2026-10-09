import 'package:flutter/material.dart';

import '../radar/native_browser.dart';
import '../radar/radar_db.dart';
import '../theme.dart';
import '../widgets/common.dart';

/// Recherches Leboncoin surveillées par le radar.
class RadarSearchesScreen extends StatefulWidget {
  /// Nom pré-rempli (création depuis une notification reçue).
  final String? createWithName;
  const RadarSearchesScreen({super.key, this.createWithName});

  @override
  State<RadarSearchesScreen> createState() => _RadarSearchesScreenState();
}

class _RadarSearchesScreenState extends State<RadarSearchesScreen> {
  List<RadarSearch> _list = [];

  @override
  void initState() {
    super.initState();
    _load();
    if (widget.createWithName != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _edit(null, name: widget.createWithName));
    }
  }

  Future<void> _load() async {
    final l = await RadarDb.searches();
    if (mounted) setState(() => _list = l);
  }

  Future<void> _edit(RadarSearch? s, {String? name}) async {
    final res = await showModalBottomSheet<RadarSearch>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _SearchSheet(search: s, name: name),
    );
    if (res == null) return;
    await RadarDb.saveSearch(res);
    await RadarDb.log(s == null ? 'Recherche ajoutée : « ${res.name} »' : 'Recherche modifiée : « ${res.name} »');
    _load();
  }

  Future<void> _delete(RadarSearch s) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text('Supprimer « ${s.name} » ?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Annuler')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Supprimer')),
        ],
      ),
    );
    if (ok != true) return;
    await RadarDb.deleteSearch(s.id!);
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Recherches surveillées')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _edit(null),
        icon: const Icon(Icons.add),
        label: const Text('Ajouter'),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 96),
        children: [
          Text(
            'Le nom doit être exactement celui de la notification Leboncoin '
            '(ex. « objectif »). Au premier passage, le radar analyse les 3 annonces '
            'les plus récentes ; ensuite, toutes celles parues depuis la dernière vue.',
            style: TextStyle(color: cs.onSurfaceVariant, fontSize: 13),
          ),
          const SizedBox(height: 14),
          for (final s in _list) ...[
            AppCard(
              padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
              onTap: () => _edit(s),
              child: Row(children: [
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(s.name, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
                    const SizedBox(height: 2),
                    Text(
                      '≤ ${s.maxPrice.toStringAsFixed(0)} € · catégorie ${s.category.isEmpty ? 'toutes' : s.category}'
                      '${s.checkpoint == null ? ' · jamais lancée' : ' · vue ${shortDate(s.checkpoint!)}'}',
                      style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12.5),
                    ),
                    Text(s.url, maxLines: 1, overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: cs.onSurfaceVariant, fontSize: 11.5)),
                  ]),
                ),
                Switch(
                  value: s.active,
                  onChanged: (v) async {
                    await RadarDb.saveSearch(s.copyWith(active: v));
                    _load();
                  },
                ),
                IconButton(icon: const Icon(Icons.delete_outline), onPressed: () => _delete(s)),
              ]),
            ),
            const SizedBox(height: 8),
          ],
        ],
      ),
    );
  }
}

class _SearchSheet extends StatefulWidget {
  final RadarSearch? search;
  final String? name;
  const _SearchSheet({this.search, this.name});

  @override
  State<_SearchSheet> createState() => _SearchSheetState();
}

class _SearchSheetState extends State<_SearchSheet> {
  late final _name = TextEditingController(text: widget.search?.name ?? widget.name ?? '');
  late final _url = TextEditingController(text: widget.search?.url ?? '');
  late final _max = TextEditingController(text: (widget.search?.maxPrice ?? 200).toStringAsFixed(0));
  late final _cat = TextEditingController(text: widget.search?.category ?? '16');
  String? _error;

  void _submit() {
    final name = _name.text.trim();
    final url = normalizeSearchUrl(_url.text);
    if (name.isEmpty) return setState(() => _error = 'Donne le nom de la recherche (titre de la notification).');
    if (!url.contains('leboncoin.fr/recherche')) {
      return setState(() => _error = 'Colle l\'URL d\'une recherche leboncoin.fr/recherche?…');
    }
    final max = double.tryParse(_max.text.replaceAll(',', '.').trim()) ?? 200;
    final base = widget.search ?? RadarSearch(name: name, url: url);
    Navigator.pop(context, base.copyWith(name: name, url: url, maxPrice: max, category: _cat.text.trim()));
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(16, 0, 16, 16 + MediaQuery.viewInsetsOf(context).bottom),
      child: SingleChildScrollView(
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(widget.search == null ? 'Nouvelle recherche' : 'Modifier la recherche',
              style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 14),
          TextField(controller: _name, decoration: const InputDecoration(labelText: 'Nom (titre de la notification)')),
          const SizedBox(height: 10),
          TextField(
            controller: _url,
            keyboardType: TextInputType.url,
            maxLines: 3,
            minLines: 1,
            decoration: InputDecoration(labelText: 'URL de la recherche Leboncoin', errorText: _error),
          ),
          const SizedBox(height: 10),
          Row(children: [
            Expanded(
              child: TextField(
                controller: _max,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: 'Prix max', suffixText: '€'),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: TextField(
                controller: _cat,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: 'Catégorie', helperText: '16 = Photo, audio & vidéo'),
              ),
            ),
          ]),
          const SizedBox(height: 6),
          const Text('« sort=time » est ajouté à l\'URL si besoin (plus récentes d\'abord).',
              style: TextStyle(fontSize: 12)),
          const SizedBox(height: 14),
          FilledButton.icon(onPressed: _submit, icon: const Icon(Icons.check), label: const Text('Enregistrer')),
        ]),
      ),
    );
  }
}
