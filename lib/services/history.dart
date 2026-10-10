import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models.dart';
import 'v3_models.dart';

/// Un message de la conversation « Poser une question ».
class ChatMessage {
  final String role; // user | model
  final String text;
  final List<WebSource> sources;
  final bool isError;

  ChatMessage(this.role, this.text, {this.sources = const [], this.isError = false});

  bool get isUser => role == 'user';

  Map<String, dynamic> toJson() => {
        'role': role,
        'text': text,
        'sources': sources.map((s) => s.toJson()).toList(),
        if (isError) 'error': true,
      };

  factory ChatMessage.fromJson(Map<String, dynamic> j) => ChatMessage(
        (j['role'] ?? 'user').toString(),
        (j['text'] ?? '').toString(),
        sources: ((j['sources'] as List?) ?? [])
            .map((e) => WebSource.fromJson(Map<String, dynamic>.from(e as Map)))
            .toList(),
        isError: j['error'] == true,
      );
}

/// Source web citée par Gemini (recherche Google).
class WebSource {
  final String uri;
  final String title;
  WebSource(this.uri, this.title);

  Map<String, dynamic> toJson() => {'uri': uri, 'title': title};
  factory WebSource.fromJson(Map<String, dynamic> j) =>
      WebSource((j['uri'] ?? '').toString(), (j['title'] ?? '').toString());
}

/// Une analyse enregistrée : l'annonce, le résultat complet et la conversation.
class HistoryEntry {
  final String id;
  final DateTime date;
  final String url; // vide en saisie manuelle
  final String title;
  final double? adPrice;
  final String description;
  final Map<String, String> attributes;
  final Analysis analysis;
  final List<ChatMessage> chat;

  /// Photos, lieu et livraison lus dans la page (null en saisie manuelle).
  final AdExtras? extras;

  HistoryEntry({
    required this.id,
    required this.date,
    required this.url,
    required this.title,
    required this.adPrice,
    required this.description,
    required this.attributes,
    required this.analysis,
    List<ChatMessage>? chat,
    this.extras,
  }) : chat = chat ?? [];

  Map<String, dynamic> toJson() => {
        'id': id,
        'date': date.toIso8601String(),
        'url': url,
        'title': title,
        'adPrice': adPrice,
        'description': description,
        'attributes': attributes,
        'analysis': analysis.toJson(),
        'chat': chat.map((m) => m.toJson()).toList(),
        if (extras != null) 'extras': extras!.toJson(),
      };

  factory HistoryEntry.fromJson(Map<String, dynamic> j) => HistoryEntry(
        id: (j['id'] ?? '').toString(),
        date: DateTime.tryParse((j['date'] ?? '').toString()) ?? DateTime.now(),
        url: (j['url'] ?? '').toString(),
        title: (j['title'] ?? '').toString(),
        adPrice: (j['adPrice'] as num?)?.toDouble(),
        description: (j['description'] ?? '').toString(),
        attributes: Map<String, dynamic>.from((j['attributes'] as Map?) ?? {})
            .map((k, v) => MapEntry(k, v.toString())),
        analysis: Analysis.fromJson(Map<String, dynamic>.from(j['analysis'] as Map)),
        chat: ((j['chat'] as List?) ?? [])
            .map((e) => ChatMessage.fromJson(Map<String, dynamic>.from(e as Map)))
            .toList(),
        extras: j['extras'] == null ? null : AdExtras.fromJson(Map<String, dynamic>.from(j['extras'] as Map)),
      );

  String get attributesText =>
      attributes.entries.map((e) => '${e.key} : ${e.value}').join('\n');
}

/// Les 50 dernières analyses, stockées en JSON dans shared_preferences.
class HistoryStore {
  static const _key = 'history_v1';
  static const maxEntries = 50;

  static Future<List<HistoryEntry>> load() async {
    final p = await SharedPreferences.getInstance();
    final raw = p.getString(_key);
    if (raw == null) return [];
    try {
      return (jsonDecode(raw) as List)
          .map((e) => HistoryEntry.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList();
    } catch (_) {
      return [];
    }
  }

  static Future<void> _save(List<HistoryEntry> list) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(
        _key, jsonEncode(list.take(maxEntries).map((e) => e.toJson()).toList()));
  }

  /// Ajoute ou met à jour (même id) une entrée, en tête de liste.
  static Future<void> upsert(HistoryEntry e) async {
    final list = await load();
    final i = list.indexWhere((x) => x.id == e.id);
    if (i >= 0) {
      list[i] = e;
    } else {
      list.insert(0, e);
    }
    await _save(list);
  }

  static Future<void> remove(String id) async {
    final list = await load()
      ..removeWhere((x) => x.id == id);
    await _save(list);
  }
}
