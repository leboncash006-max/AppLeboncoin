import 'package:shared_preferences/shared_preferences.dart';

class Settings {
  double coefBody;
  double coefLens;
  double minMargin;
  bool darkTheme;

  Settings(
      {this.coefBody = 0.54,
      this.coefLens = 0.40,
      this.minMargin = 30,
      this.darkTheme = true});

  static Future<Settings> load() async {
    final p = await SharedPreferences.getInstance();
    return Settings(
      coefBody: p.getDouble('coefBody') ?? 0.54,
      coefLens: p.getDouble('coefLens') ?? 0.40,
      minMargin: p.getDouble('minMargin') ?? 30,
      darkTheme: p.getBool('darkTheme') ?? true,
    );
  }

  Future<void> save() async {
    final p = await SharedPreferences.getInstance();
    await p.setDouble('coefBody', coefBody);
    await p.setDouble('coefLens', coefLens);
    await p.setDouble('minMargin', minMargin);
    await p.setBool('darkTheme', darkTheme);
  }
}
