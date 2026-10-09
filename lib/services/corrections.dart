import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// Corrections de modèle faites à la main (« Pas le bon modèle ? ») :
/// modèle trouvé à tort → bon modèle. Appliquées aux analyses suivantes.
class Corrections {
  static const _key = 'model_corrections';

  static Future<Map<String, String>> load() async {
    final p = await SharedPreferences.getInstance();
    await p.reload();
    final raw = p.getString(_key);
    if (raw == null) return {};
    try {
      return Map<String, dynamic>.from(jsonDecode(raw) as Map).map((k, v) => MapEntry(k, '$v'));
    } catch (_) {
      return {};
    }
  }

  static Future<void> add(String wrong, String right) async {
    if (wrong == right) return;
    final m = await load()
      ..[wrong] = right;
    final p = await SharedPreferences.getInstance();
    await p.setString(_key, jsonEncode(m));
  }
}
