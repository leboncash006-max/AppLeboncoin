import 'dart:convert';

import 'package:flutter/services.dart';

/// État des permissions nécessaires au radar.
class RadarPermissions {
  final bool notificationAccess;
  final bool batteryExempt;
  final bool notificationsAllowed;
  final bool enabled;
  final String? firstPackage;
  final bool backgroundRestricted;
  final bool listenerConnected;
  final DateTime? watchdogLast;
  final String? problem;
  RadarPermissions(Map m)
      : notificationAccess = m['notificationAccess'] == true,
        batteryExempt = m['batteryExempt'] == true,
        notificationsAllowed = m['notificationsAllowed'] == true,
        enabled = m['enabled'] != false,
        firstPackage = m['firstPackage'] as String?,
        backgroundRestricted = m['backgroundRestricted'] == true,
        listenerConnected = m['listenerConnected'] == true,
        watchdogLast = ((m['watchdogLast'] as num?) ?? 0) > 0
            ? DateTime.fromMillisecondsSinceEpoch((m['watchdogLast'] as num).toInt())
            : null,
        problem = m['problem'] as String?;

  bool get ready => notificationAccess && batteryExempt && notificationsAllowed && !backgroundRestricted;
}

/// Accès au côté Android du radar depuis l'interface (MainActivity.kt).
class RadarBridge {
  static const _ch = MethodChannel('mpb_check/radar');

  static Future<RadarPermissions?> status() async {
    try {
      return RadarPermissions(await _ch.invokeMethod('status') as Map);
    } catch (_) {
      return null; // hors Android
    }
  }

  static Future<void> openNotificationAccess() => _ch.invokeMethod('openNotificationAccess');
  static Future<void> requestBatteryExempt() => _ch.invokeMethod('requestBatteryExempt');
  /// Dernier plantage Android enregistré (effacé après lecture).
  static Future<String?> lastCrash() async {
    try {
      return await _ch.invokeMethod<String>('lastCrash');
    } catch (_) {
      return null;
    }
  }

  /// Écrit les cookies sur le disque (connexion Leboncoin conservée).
  static Future<void> flushCookies() async {
    try {
      await _ch.invokeMethod('flushCookies');
    } catch (_) {}
  }

  static Future<void> openAppSettings() => _ch.invokeMethod('openAppSettings');
  static Future<void> rebind() => _ch.invokeMethod('rebind');
  static Future<void> requestNotifications() => _ch.invokeMethod('requestNotifications');
  static Future<void> setEnabled(bool on) => _ch.invokeMethod('setEnabled', {'on': on});
  static Future<void> setPeriodic(bool on) => _ch.invokeMethod('setPeriodic', {'on': on});

  /// Dernières notifications Leboncoin vues (et celles affichées en ce moment).
  static Future<List<LbcNotif>> recentNotifs() async {
    try {
      final m = Map<String, dynamic>.from(await _ch.invokeMethod('recentNotifs') as Map);
      final all = <LbcNotif>[
        ...(jsonDecode(m['active'] as String) as List).map((e) => LbcNotif(Map<String, dynamic>.from(e as Map))),
        ...(jsonDecode(m['recent'] as String) as List).map((e) => LbcNotif(Map<String, dynamic>.from(e as Map))),
      ];
      final seen = <String>{};
      final out = <LbcNotif>[];
      for (final n in all..sort((a, b) => b.at.compareTo(a.at))) {
        if (seen.add('${n.title}|${n.text}|${n.channel}')) out.add(n);
      }
      return out;
    } catch (_) {
      return [];
    }
  }

  /// Déclencheur choisi ({text, channel}) ; text null = réglage par défaut.
  static Future<({String? text, String? channel})> trigger() async {
    try {
      final m = Map<String, dynamic>.from(await _ch.invokeMethod('getTrigger') as Map);
      return (text: m['text'] as String?, channel: m['channel'] as String?);
    } catch (_) {
      return (text: null, channel: null);
    }
  }

  static Future<void> setTrigger(String? text, String? channel) =>
      _ch.invokeMethod('setTrigger', {'text': text, 'channel': channel});

  /// Lance le radar maintenant (relance « manual » ou « resume »).
  static Future<void> start([String kind = 'manual']) => _ch.invokeMethod('start', {'kind': kind});

  /// Ouverture depuis une notification du radar : {open_analysis: id} ou {radar_verify: url}.
  static Future<Map<String, String>?> takeLaunch() async {
    try {
      final m = await _ch.invokeMethod('takeLaunch');
      return m == null ? null : Map<String, String>.from(m as Map);
    } catch (_) {
      return null;
    }
  }

  /// Appelé par Android quand une notification du radar est ouverte, appli lancée.
  static void onLaunch(void Function() cb) {
    _ch.setMethodCallHandler((call) async {
      if (call.method == 'launch') cb();
    });
  }
}

/// Notification Leboncoin vue par l'écouteur.
class LbcNotif {
  final String title;
  final String text;
  final String channel;
  final String pkg;
  final DateTime at;
  final bool active;
  LbcNotif(Map<String, dynamic> m)
      : title = (m['title'] ?? '').toString(),
        text = (m['text'] ?? '').toString(),
        channel = (m['channel'] ?? '').toString(),
        pkg = (m['pkg'] ?? '').toString(),
        at = DateTime.fromMillisecondsSinceEpoch((m['ts'] as num?)?.toInt() ?? 0),
        active = m['active'] == true;
}
