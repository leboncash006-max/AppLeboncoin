import '../data/real_quotes.dart';
import '../models.dart';
import 'gemini_service.dart';
import 'local_identifier.dart';
import 'mpb_catalog.dart';
import 'mpb_service.dart';
import 'settings.dart';

/// Variantes du catalogue MPB qu'on écarte sauf si l'annonce les mentionne.
final _special = RegExp(r'astro|infrarouge|converti|modifi|full spectrum', caseSensitive: false);

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

/// État MPB correspondant à l'attribut « État » de Leboncoin.
/// « parts » = pour pièces (aucun rachat) ; état inconnu → good.
String conditionFromAd(String attributesText) {
  final m = RegExp(r'^\s*État\s*:\s*(.+)$', multiLine: true, caseSensitive: false)
      .firstMatch(attributesText);
  final v = (m?.group(1) ?? '').toLowerCase();
  if (v.contains('pièces') || v.contains('pieces')) return 'parts';
  if (v.contains('très bon') || v.contains('tres bon')) return 'excellent';
  if (v.contains('neuf')) return 'like-new';
  if (v.contains('satisfaisant')) return 'well-used';
  if (v.contains('bon')) return 'good';
  return 'good';
}

/// État juste en dessous (pour la marge prudente).
String conditionBelow(String c) {
  final i = mpbConditions.indexOf(c);
  if (i < 0) return 'well-used';
  return mpbConditions[(i + 1).clamp(0, mpbConditions.length - 1)];
}

class Analyzer {
  final Settings settings;
  final MpbService mpb;
  final GeminiService gemini;

  /// Noms exacts des modèles MPB (téléchargés une fois, gardés dans l'appli).
  final MpbCatalog? catalog;

  Analyzer(this.settings, {MpbService? mpb, GeminiService? gemini, this.catalog})
      : mpb = mpb ?? MpbService(),
        gemini = gemini ?? GeminiService() {
    if (catalog != null) this.mpb.rememberIds(catalog!.ids);
  }

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

    // 0. Mode local : identification SANS IA (catalogue MPB + mots-clés).
    //    Gemini ne sert qu'en secours, si rien n'est reconnu.
    final local = settings.localEngine && catalog != null
        ? LocalIdentifier(catalog!).identify(title, description, attributes)
        : null;
    final useLocal = local != null && local.items.isNotEmpty;
    var ext = <String, dynamic>{};
    var defects = <String>[];
    final adLower = ad.toLowerCase();
    final results = <ItemResult>[];
    String? searchError;
    final failedSearch = <ExtractedItem>{};
    if (useLocal) {
      onStep?.call('Identification locale (sans IA)…');
      results.addAll(local.items);
      defects = local.defects;
      price ??= local.priceInText;
      ext = {'condition_hint': local.conditionHint, 'shutter_count': local.shutterCount};
      onStep?.call('Catalogue MPB : ${local.items.length} élément(s) reconnu(s)');
    } else {
      // 1. Gemini comprend l'annonce
      onStep?.call("Lecture de l'annonce…");
      ext = await gemini.generateJson(_extractPrompt(ad), _extractSchema);
      final extracted = ((ext['items'] as List?) ?? [])
          .map((e) => ExtractedItem.fromJson(Map<String, dynamic>.from(e)))
          .where((e) => e.type != 'autre')
          .toList();
      price ??= (ext['price_in_text'] as num?)?.toDouble();
      defects = ((ext['defects'] as List?) ?? []).map((e) => '$e').toList();

      // 2. Recherche des candidats dans le catalogue MPB
      onStep?.call('Recherche dans le catalogue MPB…');
      final exactMatches = <ExtractedItem, String>{};
      for (final it in extracted) {
        final cands = <String>{};
        // a) catalogue local : nom exact, sinon noms les plus proches (sans réseau)
        final cat = catalog;
        if (cat != null) {
          final exact = cat.exact(it.nameGuess);
          if (exact != null) {
            exactMatches[it] = exact;
            cands.add(exact);
          } else {
            cands.addAll(cat.match('${it.nameGuess} ${it.searchQuery}', brand: it.brand));
          }
        }
        // b) moteur de recherche MPB, seulement sans catalogue ou sans résultat
        if (cands.isEmpty) {
          final codes =
              MpbCatalog.tokens(it.nameGuess).where((w) => w.contains(RegExp(r'\d'))).join(' ');
          final queries = [
            it.searchQuery,
            it.nameGuess,
            '${it.brand} ${it.nameGuess}',
            if (codes.isNotEmpty) '${it.brand} $codes',
          ];
          for (final q in queries) {
            if (cands.length >= 6) break;
            try {
              cands.addAll(await mpb.suggest(q));
            } catch (e) {
              searchError ??= e.toString().replaceFirst('Exception: ', '');
              failedSearch.add(it);
              break;
            }
          }
        }
        final filtered = cands
            .where((c) => !_special.hasMatch(c) || _special.hasMatch(adLower))
            .take(12)
            .toList();
        final r = ItemResult(it, filtered);
        final exact = exactMatches[it];
        if (exact != null && filtered.contains(exact)) {
          // nom exact du catalogue : pas besoin de demander à l'IA
          r.mpbModel = exact;
          r.confident = true;
          r.reason = 'Nom exact du catalogue MPB';
        }
        results.add(r);
      }

      // 3. Gemini choisit le bon nom parmi les candidats
      final withCands =
          results.where((r) => r.candidates.isNotEmpty && r.mpbModel == null).toList();
      if (withCands.isNotEmpty) {
        onStep?.call('Identification des modèles exacts…');
        final ch = await gemini.generateJson(_choosePrompt(ad, withCands), _chooseSchema);
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
    } // fin de l'identification par Gemini

    // 4. Prix : reprise réelle MPB pour l'état annoncé ; en secours seulement,
    //    vraie estimation enregistrée ou revente MPB en état Bon × coefficient.
    onStep?.call('Calcul des prix de reprise…');
    final condition = conditionFromAd('$attributes\n$title');
    final forParts = condition == 'parts';
    final mainCond = forParts ? 'good' : condition;
    final prudentCond = conditionBelow(mainCond);
    for (final r in results) {
      final m = r.mpbModel;
      if (m == null) {
        warnings.add(failedSearch.contains(r.item)
            ? '« ${r.item.nameGuess} » non chiffré : la recherche MPB a échoué.'
            : '« ${r.item.nameGuess} » introuvable chez MPB.');
        continue;
      }
      try {
        r.resale = await mpb.resale(m);
      } catch (e) {
        // sert seulement au nombre en vente, au lien et au calcul de secours
      }
      try {
        r.modelId = await mpb.modelId(m);
        if (r.modelId != null) r.purchasePrices = await mpb.purchasePrices(r.modelId!);
      } catch (_) {
        // l'API de reprise ne répond pas : calcul de secours plus bas
      }
      final real = r.purchasePrices[mainCond];
      if (forParts) {
        r.buyback = 0;
        r.prudentBuyback = 0;
        r.source = 'pour pièces';
      } else if (real != null) {
        r.buyback = real;
        r.prudentBuyback = r.purchasePrices[prudentCond] ?? real;
        r.source = 'prix MPB réel';
      } else {
        if (realQuotes.containsKey(m)) {
          r.buyback = realQuotes[m];
          r.source = 'estimation réelle';
        } else if (r.resale != null) {
          r.coef = r.item.isLens ? settings.coefLens : settings.coefBody;
          r.buyback = r.resale!.median * r.coef!;
          r.source = 'revente × coef';
        }
        if (r.buyback != null) {
          warnings.add('Prix de reprise MPB indisponible pour $m : estimation approximative.');
        } else {
          warnings.add('Aucun prix de référence pour $m.');
        }
      }
      if (!r.confident) {
        warnings.add('Version incertaine pour $m : vérifie sur MPB.');
      }
    }

    if (searchError != null) warnings.insert(0, 'Recherche MPB impossible : $searchError');
    if (price == null) warnings.add('Prix de l\'annonce inconnu.');
    if (defects.isNotEmpty) {
      warnings.insert(0, 'Défauts signalés : ${defects.join(", ")}');
    }
    if (forParts) {
      warnings.insert(0, '⛔ Annoncé « pour pièces » : aucun rachat MPB (0 €).');
    } else if (RegExp(r'pour pi[eè]ces|hors service|\bHS\b', caseSensitive: false)
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
      condition: condition,
      prudentCondition: forParts ? 'parts' : prudentCond,
    );
  }
}
