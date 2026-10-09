import 'package:flutter/material.dart';

import 'screens/home_screen.dart';
import 'services/settings.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = ColorScheme.fromSeed(seedColor: const Color(0xFF5B3CC4));
    return MaterialApp(
      title: 'MPB Check',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorScheme: scheme, useMaterial3: true),
      darkTheme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
            seedColor: const Color(0xFF5B3CC4), brightness: Brightness.dark),
        useMaterial3: true,
      ),
      home: FutureBuilder<Settings>(
        future: Settings.load(),
        builder: (context, snap) {
          if (!snap.hasData) {
            return const Scaffold(body: Center(child: CircularProgressIndicator()));
          }
          return HomeScreen(settings: snap.data!);
        },
      ),
    );
  }
}
