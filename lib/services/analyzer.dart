import '../data/real_quotes.dart';
import '../models.dart';
import 'corrections.dart';
import 'gemini_service.dart';
import 'local_identifier.dart';
import 'match_check.dart';
import 'mpb_catalog.dart';
import 'mpb_service.dart';
import 'settings.dart';

/// Annonce d'accessoire (d'après le TITRE) : bagues, filtres, sacs… pas de reprise MPB.
final accessoryTitle = RegExp(
    r'^\W*(?:\d+\s*)?(?:lot\s+(?:de\s+)?)?(?:\d+\s*)?(?<acc>bagues?|adaptateurs?|filtres?|pare[- ]soleils?|bouchons?|sacs?|'
    r'sacoches?|tr[ée]pieds?|monopodes?|batteries?|chargeurs?|grips?|poign[ée]es?|cartes?|c[âa]bles?|'
    r't[ée]l[ée]commandes?|courroies?|dragonnes?|housses?|[ée]tuis?|rotules?|oeilletons?|[œo]illetons?|'
    r'protections?|films?|pellicules?|flashs?\s+cobra\s+universel)\b',
    caseSensitive: false);

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
  « Sony Alpha SLT-A68 » (souvent écrit « Sony a68 » ou « alpha 68 »),
  « Canon EF-S 18-55mm f/3.5-5.6 IS STM », « Nikon AF-S DX Nikkor 35mm f/1.8G ».
  Déduis la version exacte des indices (STM, IS, VR, II…). Un objectif de kit
  sans précision est souvent la version livrée avec ce boîtier.
- search_query : 2 à 5 mots pour chercher le modèle (marque + référence),
  par exemple « Canon 1200D », « Sony A68 » ou « Canon 18-55 IS STM ».
Les vendeurs abrègent souvent : « a68 », « 1200d », « d3200 », « xt20 » ; retrouve
toujours le modèle officiel correspondant.
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

/// Alerte posée quand la reprise dépasse 6 fois le prix (et +150 €).
const suspiciousWarning = '⚠️ Estimation à vérifier : la reprise MPB dépasse 6 fois le prix '
    'de l\'annonce (modèle probablement mal identifié).';

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
      {String attributes = '', Progress? onStep, bool verify = true}) async {
    final ad = [
      'Titre : $title',
      'Prix : ${price ?? "?"} €',
      if (attributes.isNotEmpty) attributes,
      '',
      description,
    ].join('\n').trim();
    final warnings = <String>[];

    // annonce d'accessoire : rien à reprendre chez MPB, pas d'appel inutile
    if (accessoryTitle.hasMatch(title)) {
      return Analysis(
        items: [],
        price: price,
        defects: [],
        conditionHint: 'inconnu',
        shutterCount: null,
        warnings: ['Accessoire (${accessoryTitle.firstMatch(title)!.namedGroup('acc')}) : pas de reprise MPB estimée.'],
        condition: conditionFromAd('$attributes\n$title'),
        prudentCondition: conditionBelow(conditionFromAd('$attributes\n$title')),
      );
    }

    // 1. Identification par l'IA (Gemini) partout. Le catalogue local ne sert
    //    qu'en secours, si l'IA ne répond pas (quota, réseau).
    var ext = <String, dynamic>{};
    var defects = <String>[];
    final adLower = ad.toLowerCase();
    final results = <ItemResult>[];
    String? searchError;
    final failedSearch = <ExtractedItem>{};
    var engine = 'ia';
    final priceIn = price;
    try {
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
      // l'IA n'a rien retenu : un seul candidat porte exactement la même
      // référence (a68, 1200d, 16-50…) → on le prend, marqué incertain.
      for (final r in withCands.where((r) => r.mpbModel == null)) {
        final codes = MpbCatalog.tokens('${r.item.nameGuess} ${r.item.searchQuery}')
            .where((w) => w.contains(RegExp(r'\d')))
            .toSet();
        if (codes.isEmpty) continue;
        final same = r.candidates.where((c) {
          final t = MpbCatalog.tokens(c).where((w) => w.contains(RegExp(r'\d'))).toSet();
          return t.isNotEmpty && t.every(codes.contains);
        }).toList();
        if (same.length == 1) {
          r.mpbModel = same.first;
          r.confident = false;
          r.reason = 'Même référence que l\'annonce (choix automatique, à vérifier)';
        }
      }
    } catch (e) {
      final local = catalog != null ? LocalIdentifier(catalog!).identify(title, description, attributes) : null;
      if (local == null || local.items.isEmpty) rethrow;
      results
        ..clear()
        ..addAll(local.items);
      failedSearch.clear();
      searchError = null;
      price = priceIn ?? local.priceInText;
      defects = local.defects;
      ext = {'condition_hint': local.conditionHint, 'shutter_count': local.shutterCount};
      engine = 'local';
      for (final r in results) {
        r.confident = false; // sans l'IA, jamais « sûr »
      }
      warnings.add('IA indisponible (${e.toString().replaceFirst('Exception: ', '')}) : '
          'identification de secours par le catalogue local, à vérifier.');
      onStep?.call('IA indisponible : catalogue local (${local.items.length} élément(s))');
    }

    // 3 bis. corrections faites à la main (« Pas le bon modèle ? »)
    final corrections = await Corrections.load();
    for (final r in results) {
      final fixed = corrections[r.mpbModel];
      if (fixed != null) {
        r.mpbModel = fixed;
        r.confident = true;
        r.reason = 'Correction enregistrée';
      }
    }

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
    // garde-fou : reprise très supérieure au prix → identification probablement fausse
    final buyback = results.fold(0.0, (t, r) => t + (r.buyback ?? 0));
    if (price != null && price > 0 && buyback > 6 * price && buyback - price > 150) {
      warnings.insert(0, suspiciousWarning);
      for (final r in results) {
        r.confident = false;
      }
    }
    if (defects.isNotEmpty) {
      warnings.insert(0, 'Défauts signalés : ${defects.join(", ")}');
    }
    if (forParts) {
      warnings.insert(0, '⛔ Annoncé « pour pièces » : aucun rachat MPB (0 €).');
    } else if (RegExp(r'pour pi[eè]ces|hors service|\bHS\b', caseSensitive: false)
        .hasMatch('$attributes\n$title')) {
      warnings.insert(0, '⛔ Annoncé « pour pièces / HS » : MPB ne le reprendra pas.');
    }

    final an = Analysis(
      items: results,
      price: price,
      defects: defects,
      conditionHint: (ext['condition_hint'] ?? 'inconnu').toString(),
      shutterCount: (ext['shutter_count'] as num?)?.toInt(),
      warnings: warnings,
      condition: condition,
      prudentCondition: forParts ? 'parts' : prudentCond,
      engine: engine,
    );
    // 5. vérification de correspondance (garde-fou marque + verdict IA)
    if (verify && an.items.any((i) => i.mpbModel != null)) {
      onStep?.call('Vérification de la correspondance (IA)…');
      final v = await MatchCheck.run(gemini, an, title, attributes, description);
      an.aiVerdict = v.verdict;
      an.aiReason = v.reason;
      if (v.verdict != 'oui') {
        for (final r in an.items) {
          r.confident = false;
        }
        an.warnings.insert(
            0,
            v.verdict == 'non'
                ? '⛔ Vérification IA : identification probablement fausse. ${v.reason}'
                : '⚠️ Vérification IA : doute. ${v.reason}');
      }
    }
    return an;
  }
}

/// Recalcule un élément avec un autre modèle MPB (correction à la main) :
/// prix de reprise réels pour [condition], marge prudente, nombre en vente.
Future<void> repriceItem(ItemResult r, String model, String condition, MpbService mpb, {double? coef}) async {
  r.mpbModel = model;
  r.confident = true;
  r.reason = 'Corrigé à la main';
  r.coef = null;
  r.candidates
    ..clear()
    ..add(model);
  r.resale = null;
  r.purchasePrices = {};
  try {
    r.resale = await mpb.resale(model);
  } catch (_) {}
  Object? priceError;
  try {
    r.modelId = await mpb.modelId(model);
    if (r.modelId != null) r.purchasePrices = await mpb.purchasePrices(r.modelId!);
  } catch (e) {
    priceError = e;
  }
  if (condition == 'parts') {
    r.buyback = 0;
    r.prudentBuyback = 0;
    r.source = 'pour pièces';
    return;
  }
  final real = r.purchasePrices[condition];
  if (real == null) {
    // pas de prix de reprise en ligne (404 = MPB ne le propose pas) : estimation de secours
    final why = priceError == null ? '' : ' (${priceError.toString().replaceFirst('Exception: ', '')})';
    if (r.resale != null && coef != null) {
      r.coef = coef;
      r.buyback = r.resale!.median * coef;
      r.prudentBuyback = null;
      r.source = 'revente × coef';
      return;
    }
    throw Exception('MPB ne donne pas de prix de reprise pour $model$why');
  }
  r.buyback = real;
  r.prudentBuyback = r.purchasePrices[conditionBelow(condition)] ?? real;
  r.source = 'prix MPB réel';
}
