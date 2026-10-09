import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'radar/radar_engine.dart';
import 'screens/root_screen.dart';
import 'services/settings.dart';
import 'theme.dart';

/// Thème courant (sombre par défaut), modifiable depuis les réglages.
final darkThemeNotifier = ValueNotifier<bool>(true);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // en cas d'erreur d'affichage, on montre le message (au lieu d'un écran gris)
  ErrorWidget.builder = (details) => Material(
        color: const Color(0xFF2A0F14),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: SelectableText('Erreur d\'affichage :\n${details.exceptionAsString()}',
              style: const TextStyle(color: Colors.white, fontSize: 12)),
        ),
      );
  final settings = await Settings.load();
  darkThemeNotifier.value = settings.darkTheme;
  runApp(MyApp(settings: settings));
}

class MyApp extends StatelessWidget {
  final Settings settings;
  const MyApp({super.key, required this.settings});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: darkThemeNotifier,
      builder: (context, dark, _) {
        SystemChrome.setSystemUIOverlayStyle(
            dark ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark);
        return MaterialApp(
          title: 'MPB Check',
          debugShowCheckedModeBanner: false,
          theme: buildTheme(Brightness.light),
          darkTheme: buildTheme(Brightness.dark),
          themeMode: dark ? ThemeMode.dark : ThemeMode.light,
          home: RootScreen(settings: settings),
        );
      },
    );
  }
}

/// Point d'entrée du radar en arrière-plan, lancé par RadarService.kt dans un
/// moteur Flutter sans écran.
@pragma('vm:entry-point')
Future<void> radarMain() async {
  WidgetsFlutterBinding.ensureInitialized();
  DartPluginRegistrant.ensureInitialized();
  final engine = RadarEngine();
  RadarEngine.bg.setMethodCallHandler((call) async {
    if (call.method == 'wake') engine.wake();
  });
  await engine.run();
}
