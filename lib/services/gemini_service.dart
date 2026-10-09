import 'dart:convert';

import 'package:http/http.dart' as http;

import '../secrets.dart';

class _KeyError implements Exception {}

class _ModelError implements Exception {}

/// Appel à l'API Gemini avec réponse JSON imposée par un schéma.
/// - Modèles essayés dans l'ordre de [geminiModels] (repli si l'alias n'existe pas).
/// - Clés de [geminiKeys] : la suivante n'est utilisée que si la précédente est
///   invalide ou révoquée (pas de rotation pour contourner les quotas).
class GeminiService {
  final List<String> keys;
  final List<String> models;
  final http.Client _client;

  static int _keyIndex = 0; // clé valide mémorisée pour la session
  static String? _workingModel;

  GeminiService({List<String>? keys, List<String>? models, http.Client? client})
      : keys = keys ?? geminiKeys,
        models = models ?? geminiModels,
        _client = client ?? http.Client();

  Future<Map<String, dynamic>> generateJson(
      String prompt, Map<String, dynamic> schema) async {
    final modelOrder = [
      if (_workingModel != null) _workingModel!,
      ...models.where((m) => m != _workingModel),
    ];
    for (final model in modelOrder) {
      while (_keyIndex < keys.length) {
        try {
          final res = await _call(keys[_keyIndex], model, prompt, schema);
          _workingModel = model;
          return res;
        } on _KeyError {
          _keyIndex++; // clé invalide : on passe à la clé de secours suivante
        } on _ModelError {
          break; // modèle inconnu : on essaie le modèle suivant
        }
      }
      if (_keyIndex >= keys.length) {
        _keyIndex = 0;
        throw Exception('Aucune clé Gemini valide (vérifie lib/secrets.dart).');
      }
    }
    throw Exception('Aucun modèle Gemini disponible : ${models.join(", ")}.');
  }

  Future<Map<String, dynamic>> _call(String key, String model, String prompt,
      Map<String, dynamic> schema) async {
    final uri = Uri.https('generativelanguage.googleapis.com',
        '/v1beta/models/$model:generateContent');
    final body = jsonEncode({
      'contents': [
        {
          'role': 'user',
          'parts': [
            {'text': prompt}
          ]
        }
      ],
      'generationConfig': {
        'temperature': 0,
        'responseMimeType': 'application/json',
        'responseSchema': schema,
      },
    });

    late http.Response r;
    for (var attempt = 0;; attempt++) {
      r = await _client
          .post(uri,
              headers: {'Content-Type': 'application/json', 'x-goog-api-key': key},
              body: body)
          .timeout(const Duration(seconds: 40));
      // limite par minute : on patiente un peu et on réessaie la même clé
      if (r.statusCode == 429 && attempt < 2) {
        await Future.delayed(Duration(seconds: 4 * (attempt + 1)));
        continue;
      }
      break;
    }

    if (r.statusCode != 200) {
      String msg = r.body;
      try {
        msg = jsonDecode(r.body)['error']['message'].toString();
      } catch (_) {}
      final low = msg.toLowerCase();
      if (r.statusCode == 404 || (low.contains('model') && low.contains('not found'))) {
        throw _ModelError();
      }
      if (r.statusCode == 401 ||
          r.statusCode == 403 ||
          (r.statusCode == 400 && (low.contains('api key') || low.contains('api_key')))) {
        throw _KeyError();
      }
      if (r.statusCode == 429) {
        throw Exception('Quota Gemini atteint pour le moment. Réessaie dans quelques minutes.');
      }
      throw Exception('Gemini ${r.statusCode} : $msg');
    }

    final data = jsonDecode(utf8.decode(r.bodyBytes));
    final parts = (data['candidates']?[0]?['content']?['parts'] as List?) ?? [];
    final text = parts
        .where((p) => p['thought'] != true && p['text'] != null)
        .map((p) => p['text'].toString())
        .join();
    if (text.trim().isEmpty) throw Exception('Réponse Gemini vide.');
    return jsonDecode(text) as Map<String, dynamic>;
  }
}
