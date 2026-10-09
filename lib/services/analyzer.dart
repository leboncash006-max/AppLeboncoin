import '../data/real_quotes.dart';
import '../models.dart';
import 'gemini_service.dart';
import 'mpb_service.dart';
import 'settings.dart';

/// Variantes du catalogue MPB qu'on écarte sauf si l'annonce les mentionne.
final _special = RegExp(r'astro|infrarouge|converti|modifi|full spectrum',
    caseSensitive: false);

const _extractSchema = {
  'type': 'OBJECT',
  'properties': {
    'items': {
      'type': 'ARRAY',
      'items': {
        'type': 'OBJECT',
        'properties': {
          'type': {
            'type': 'STRING',
            'enum': ['boitier', 'objectif', 'flash', 'autre']
          },
          'brand': {'type': 'STRING'},
          'mpb_name_guess': {'type': 'STRING'},
          'search_query': {'type': 'STRING'},
          'details': {'type': 'STRING'},
        },
        'required': ['type', 'brand', 'mpb_name_guess', 'search_query'],
      },
    },
    'price_in_text': {'type': 'NUMBER', 'nullable': true},
    'defects': {
      'type': 'ARRAY',
      'items': {'type': 'STRING'}
    },
    'condition_hint': {
      'type': 'STRING',
      'enum': ['comme_neuf', 'excellent', 'bon', 'use', 'tres_use', 'inconnu']
    },
    'shutter_count': {'type': 'INTEGER', 'nullable': true},
  },
  'required': ['items', 'defects', 'condition_hint'],
};

const _chooseSchema = {
  'type': 'OBJECT',
  'properties': {
    'choices': {
      'type': 'ARRAY',
      'items': {
        'type': 'OBJECT',
        'properties': {
          'index': {'type': 'INTEGER'},
          'model': {'type': 'STRING', 'nullable': true},
          'confident': {'type': 'BOOLEAN'},
          'reason': {'type': 'STRING'},
        },
        'required': ['index', 'confident', 'reason'],
      },
    },
  },
  'required': ['choices'],
};

String _extractPrompt(String ad) => '''
Tu es expert en matériel photo d'occasion. Voici une annonce Leboncoin.

Liste chaque boîtier, objectif et flash VENDU dans l'annonce (pas les sacs,
cartes SD, batteries, chargeurs, courroies, filtres ou trépieds sans valeur).
Pour chacun :
- type : boitier, objectif, flash ou autre
- brand : la marque (Canon, Nikon, Sony, Fujifilm, Sigma, Tamron…)
- mpb_name_guess : le nom officiel complet, au format du catalogue MPB, par
  exemple « Canon EOS 1200D », « Nikon D3200 », « Sony Alpha A6000 »,
  « Canon EF-S 18-55mm f/3.5-5.6 IS STM », « Nikon AF-S DX Nikkor 35mm f/1.8G ».
  Déduis la version exacte des indices (STM, IS, VR, II…). Un objectif de kit
  sans précision est souvent la version livrée avec ce boîtier.
- search_query : 2 à 5 mots pour chercher le modèle (marque + référence),
  par exemple « Canon 1200D » ou « Canon 18-55 IS STM ».
- details : version incertaine, monture, etc.
Indique aussi : le prix s'il figure dans le texte (price_in_text), les défauts
mentionnés (defects : HS, panne, rayure sur lentille, champignon, écran cassé,
erreur, pièces manquantes…), l'état annoncé (condition_hint) et le nombre de
déclenchements s'il est donné (shutter_count).

ANNONCE :
"""
$ad
"""''';

String _choosePrompt(String ad, List<ItemResult> items) {
  final b = StringBuffer()
    ..writeln("Pour chaque élément, choisis le nom EXACT du catalogue MPB qui "
        "correspond à l'annonce, parmi les candidats proposés (recopie-le "
        "caractère pour caractère). Si aucun ne correspond, model = null. "
        "confident = false si plusieurs versions restent possibles.")
    ..writeln()
    ..writeln('ANNONCE :\n"""\n$ad\n"""')
    ..writeln();
  for (var i = 0; i < items.length; i++) {
    final it = items[i];
    b.writeln('Élément $i : ${it.item.type} « ${it.item.nameGuess} » '
        '(${it.item.details})');
    for (final c in it.candidates) {
      b.writeln('  - $c');
    }
  }
  return b.toString();
}

typedef Progress = void Function(String step);

class Analyzer {
  final Settings settings;
  final MpbService mpb;
  final GeminiService gemini;

  Analyzer(this.settings, {MpbService? mpb, GeminiService? gemini})
      : mpb = mpb ?? MpbService(),
        gemini = gemini ?? GeminiService();

  Future<Analysis> analyze(String title, String description, double? price,
      {String attributes = '', Progress? onStep}) async {
    final ad = [
      'Titre : $title',
      'Prix : ${price ?? "?"} €',
      if (attributes.isNotEmpty) attributes,
      '',
      description,
    ].join('\n').trim();
    final warnings = <String>[];

    // 1. Gemini comprend l'annonce
    onStep?.call("Lecture de l'annonce…");
    final ext = await gemini.generateJson(_extractPrompt(ad), _extractSchema);
    final extracted = ((ext['items'] as List?) ?? [])
        .map((e) => ExtractedItem.fromJson(Map<String, dynamic>.from(e)))
        .where((e) => e.type != 'autre')
        .toList();
    price ??= (ext['price_in_text'] as num?)?.toDouble();
    final defects = ((ext['defects'] as List?) ?? []).map((e) => '$e').toList();

    // 2. Recherche des candidats dans le catalogue MPB
    onStep?.call('Recherche dans le catalogue MPB…');
    final adLower = ad.toLowerCase();
    final results = <ItemResult>[];
    for (final it in extracted) {
      final cands = <String>{};
      for (final q in [it.searchQuery, it.nameGuess, '${it.brand} ${it.nameGuess}']) {
        if (cands.length >= 6) break;
        try {
          cands.addAll(await mpb.suggest(q));
        } catch (e) {
          warnings.add('Recherche MPB impossible : $e');
          break;
        }
      }
      final filtered = cands
          .where((c) => !_special.hasMatch(c) || _special.hasMatch(adLower))
          .take(12)
          .toList();
      results.add(ItemResult(it, filtered));
    }

    // 3. Gemini choisit le bon nom parmi les candidats
    final withCands = results.where((r) => r.candidates.isNotEmpty).toList();
    if (withCands.isNotEmpty) {
      onStep?.call('Identification des modèles exacts…');
      final ch = await gemini.generateJson(
          _choosePrompt(ad, withCands), _chooseSchema);
      for (final c in (ch['choices'] as List? ?? [])) {
        final idx = (c['index'] as num?)?.toInt();
        if (idx == null || idx < 0 || idx >= withCands.length) continue;
        final r = withCands[idx];
        final model = c['model']?.toString();
        if (model != null && r.candidates.contains(model)) {
          r.mpbModel = model;
          r.confident = c['confident'] == true;
          r.reason = (c['reason'] ?? '').toString();
        }
      }
    }

    // 4. Prix : vraie estimation, sinon revente MPB en état Bon × coefficient
    onStep?.call('Calcul des prix de reprise…');
    for (final r in results) {
      final m = r.mpbModel;
      if (m == null) {
        warnings.add('« ${r.item.nameGuess} » introuvable chez MPB.');
        continue;
      }
      try {
        r.resale = await mpb.resale(m);
      } catch (e) {
        warnings.add('Prix MPB indisponible pour $m : $e');
      }
      if (realQuotes.containsKey(m)) {
        r.buyback = realQuotes[m];
        r.source = 'estimation réelle';
      } else if (r.resale != null) {
        r.coef = r.item.isLens ? settings.coefLens : settings.coefBody;
        r.buyback = r.resale!.median * r.coef!;
        r.source = 'revente × coef';
      } else {
        warnings.add('Aucun $m en vente chez MPB : pas de prix de référence.');
      }
      if (!r.confident) {
        warnings.add('Version incertaine pour $m : vérifie sur MPB.');
      }
    }

    if (price == null) warnings.add('Prix de l\'annonce inconnu.');
    if (defects.isNotEmpty) {
      warnings.insert(0, 'Défauts signalés : ${defects.join(", ")}');
    }
    if (RegExp(r'pour pi[eè]ces|hors service|\bHS\b', caseSensitive: false)
        .hasMatch('$attributes\n$title')) {
      warnings.insert(0, '⛔ Annoncé « pour pièces / HS » : MPB ne le reprendra pas.');
    }

    return Analysis(
      items: results,
      price: price,
      defects: defects,
      conditionHint: (ext['condition_hint'] ?? 'inconnu').toString(),
      shutterCount: (ext['shutter_count'] as num?)?.toInt(),
      warnings: warnings,
    );
  }
}
