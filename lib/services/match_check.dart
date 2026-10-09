import '../models.dart';
import 'gemini_service.dart';

/// Vérification de correspondance annonce ↔ modèles identifiés :
/// 1. garde-fou marque (sans IA) : la marque de chaque modèle doit figurer
///    dans l'annonce, sinon verdict « non » ;
/// 2. verdict IA (gemini-flash-lite-latest) : « oui », « doute » ou « non ».
/// En cas d'erreur de l'IA : « doute » (jamais « oui » par défaut).
class MatchCheck {
  static const _schema = {
    'type': 'OBJECT',
    'properties': {
      'verdict': {
        'type': 'STRING',
        'enum': ['oui', 'doute', 'non'],
      },
      'raison': {'type': 'STRING'},
    },
    'required': ['verdict', 'raison'],
  };

  /// Autres façons d'écrire une marque dans une annonce.
  static const _aliases = {
    'fujifilm': ['fuji', 'fujinon'],
    'panasonic': ['lumix'],
    'olympus': ['om system', 'om-d', 'omd', 'zuiko'],
    'om': ['olympus', 'om system', 'om-d'],
    'nikon': ['nikkor'],
    'sony': ['alpha'],
    'hasselblad': ['xcd'],
    'leica': ['leitz'],
  };

  /// Marque d'un nom MPB (premier mot : « Sony Alpha SLT-A68 » → sony).
  static String brandOf(String model) => model.trim().split(RegExp(r'\s+')).first.toLowerCase();

  static String _plain(String s) {
    var t = s.toLowerCase();
    const accents = {'é': 'e', 'è': 'e', 'ê': 'e', 'à': 'a', 'â': 'a', 'î': 'i', 'ô': 'o', 'û': 'u', 'ç': 'c'};
    accents.forEach((a, b) => t = t.replaceAll(a, b));
    return t;
  }

  /// Modèles dont la marque n'apparaît nulle part dans l'annonce.
  static List<String> missingBrands(Analysis a, String adText) {
    final text = _plain(adText);
    final out = <String>[];
    for (final i in a.items) {
      final m = i.mpbModel;
      if (m == null) continue;
      final b = brandOf(m);
      final names = [b, ...?_aliases[b]];
      final ok = names.any((n) => RegExp('(^|[^a-z])${RegExp.escape(n)}([^a-z]|\$)').hasMatch(text));
      if (!ok) out.add(m);
    }
    return out;
  }

  /// Verdict pour l'analyse [a] de l'annonce (titre, attributs, description).
  static Future<({String verdict, String reason})> run(
      GeminiService gemini, Analysis a, String title, String attributes, String description) async {
    final identified = a.items.where((i) => i.mpbModel != null).toList();
    if (identified.isEmpty) return (verdict: 'non', reason: 'Aucun modèle identifié');
    final unknown = a.items.where((i) => i.mpbModel == null).map((i) => i.item.nameGuess).toList();
    if (unknown.isNotEmpty) {
      return (verdict: 'doute', reason: 'Non trouvé dans le catalogue MPB : ${unknown.join(', ')}');
    }
    final missing = missingBrands(a, '$title\n$attributes\n$description');
    if (missing.isNotEmpty) {
      return (verdict: 'non', reason: 'Marque absente de l\'annonce pour : ${missing.join(', ')}');
    }
    final items = identified.map((i) => '- ${i.item.type} : ${i.mpbModel}').join('\n');
    final prompt = '''
Tu vérifies une identification de matériel photo d'occasion.
Annonce Leboncoin :
Titre : $title
$attributes
Description : """
$description
"""
Modèles identifiés (catalogue MPB) :
$items

Réponds « oui » seulement si CHAQUE modèle identifié est sans ambiguïté celui vendu (même
marque, même version, même monture). Les noms commerciaux courts comptent comme le même
modèle (ex. « Sony a68 » = « Sony Alpha SLT-A68 », « Canon 1200D » = « Canon EOS 1200D »).
« doute » si une version, une monture ou la présence d'un élément est incertaine, ou si un
élément vendu manque. « non » si au moins un modèle est faux (autre marque, objectif intégré
d'un compact pris pour un objectif séparé, accessoire pris pour un boîtier…).''';
    try {
      final r = await gemini.generateJson(prompt, _schema);
      final v = (r['verdict'] ?? 'doute').toString();
      return (verdict: ['oui', 'doute', 'non'].contains(v) ? v : 'doute', reason: (r['raison'] ?? '').toString());
    } catch (e) {
      return (verdict: 'doute', reason: 'Vérification IA impossible : $e');
    }
  }
}
