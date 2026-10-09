import 'dart:convert';

import 'package:http/http.dart' as http;

import '../secrets.dart';

class _KeyError implements Exception {}

class _ModelError implements Exception {}

class _ToolError implements Exception {}

/// Réponse texte libre du chat, avec les sources web de la recherche Google.
class ChatReply {
  final String text;
  final List<({String uri, String title})> sources;
  final bool searched; // false si la recherche web a dû être désactivée
  ChatReply(this.text, this.sources, this.searched);
}

/// Modèle de repli quand le modèle principal refuse l'outil Google Search.
const chatSearchFallbackModel = 'gemini-flash-latest';

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

  // ------------------------------------------------------------------ chat

  /// Conversation libre (pas de responseSchema) avec l'outil Google Search.
  /// Ordre : modèle habituel + recherche → [chatSearchFallbackModel] + recherche
  /// → modèle habituel sans outil. Mêmes clés de secours que [generateJson].
  Future<ChatReply> chat(
      String systemInstruction, List<({String role, String text})> turns) async {
    final primary = [
      if (_workingModel != null) _workingModel!,
      ...models.where((m) => m != _workingModel),
    ];
    final attempts = <({String model, bool search})>[
      for (final m in primary) (model: m, search: true),
      (model: chatSearchFallbackModel, search: true),
      for (final m in primary) (model: m, search: false),
    ];
    Object? lastError;
    for (final a in attempts) {
      while (_keyIndex < keys.length) {
        try {
          return await _chatCall(keys[_keyIndex], a.model, systemInstruction, turns, a.search);
        } on _KeyError {
          _keyIndex++;
        } on _ModelError catch (e) {
          lastError = e;
          break;
        } on _ToolError catch (e) {
          lastError = e;
          break;
        }
      }
      if (_keyIndex >= keys.length) {
        _keyIndex = 0;
        throw Exception('Aucune clé Gemini valide (vérifie lib/secrets.dart).');
      }
    }
    throw Exception(lastError is _ToolError
        ? 'Gemini refuse la requête, même sans recherche web.'
        : 'Aucun modèle Gemini disponible pour le chat.');
  }

  Future<ChatReply> _chatCall(String key, String model, String system,
      List<({String role, String text})> turns, bool search) async {
    final uri = Uri.https('generativelanguage.googleapis.com',
        '/v1beta/models/$model:generateContent');
    final body = jsonEncode({
      'systemInstruction': {
        'parts': [
          {'text': system}
        ]
      },
      'contents': [
        for (final t in turns)
          {
            'role': t.role,
            'parts': [
              {'text': t.text}
            ]
          }
      ],
      if (search)
        'tools': [
          {'google_search': {}}
        ],
      'generationConfig': {'temperature': 0.4},
    });

    late http.Response r;
    for (var attempt = 0;; attempt++) {
      r = await _client
          .post(uri,
              headers: {'Content-Type': 'application/json', 'x-goog-api-key': key},
              body: body)
          .timeout(const Duration(seconds: 60));
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
        throw Exception('Quota Gemini atteint pour le moment (trop de questions '
            'ou de recherches web). Réessaie dans quelques minutes.');
      }
      if (search &&
          r.statusCode == 400 &&
          (low.contains('tool') || low.contains('search') || low.contains('grounding'))) {
        throw _ToolError();
      }
      throw Exception('Gemini ${r.statusCode} : $msg');
    }

    final data = jsonDecode(utf8.decode(r.bodyBytes));
    final cand = (data['candidates'] as List?)?.firstOrNull;
    final parts = (cand?['content']?['parts'] as List?) ?? [];
    final text = parts
        .where((p) => p['thought'] != true && p['text'] != null)
        .map((p) => p['text'].toString())
        .join()
        .trim();
    if (text.isEmpty) throw Exception('Réponse Gemini vide.');

    final sources = <({String uri, String title})>[];
    final seen = <String>{};
    for (final c in (cand?['groundingMetadata']?['groundingChunks'] as List?) ?? []) {
      final web = c['web'];
      final u = web?['uri']?.toString();
      if (u == null || u.isEmpty || !seen.add(u)) continue;
      final t = web['title']?.toString() ?? '';
      sources.add((uri: u, title: t.isEmpty ? Uri.tryParse(u)?.host ?? u : t));
    }
    return ChatReply(text, sources, search);
  }
}
