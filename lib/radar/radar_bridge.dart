import 'package:flutter/services.dart';

/// État des permissions nécessaires au radar.
class RadarPermissions {
  final bool notificationAccess;
  final bool batteryExempt;
  final bool notificationsAllowed;
  final bool enabled;
  final String? firstPackage;
  RadarPermissions(Map m)
      : notificationAccess = m['notificationAccess'] == true,
        batteryExempt = m['batteryExempt'] == true,
        notificationsAllowed = m['notificationsAllowed'] == true,
        enabled = m['enabled'] != false,
        firstPackage = m['firstPackage'] as String?;

  bool get ready => notificationAccess && batteryExempt && notificationsAllowed;
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
  static Future<void> requestNotifications() => _ch.invokeMethod('requestNotifications');
  static Future<void> setEnabled(bool on) => _ch.invokeMethod('setEnabled', {'on': on});
  static Future<void> setPeriodic(bool on) => _ch.invokeMethod('setPeriodic', {'on': on});

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
