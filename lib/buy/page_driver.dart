import 'dart:async';

import 'package:webview_flutter/webview_flutter.dart';

import '../radar/native_browser.dart';
import '../services/leboncoin_reader.dart' show decodeJsResult;

/// Une page pilotable : WebView visible (dans l'appli) ou WebView sans
/// affichage (radar en arrière-plan). Mêmes cookies dans les deux cas.
abstract class PageDriver {
  Future<void> load(String url);
  Future<Map<String, dynamic>?> evalJson(String js);
}

class VisibleDriver implements PageDriver {
  final WebViewController controller;
  VisibleDriver(this.controller);

  @override
  Future<void> load(String url) => controller.loadRequest(Uri.parse(url));

  @override
  Future<Map<String, dynamic>?> evalJson(String js) async {
    try {
      final raw = await controller.runJavaScriptReturningResult(js).timeout(const Duration(seconds: 15));
      return decodeJsResult(raw);
    } catch (_) {
      return null;
    }
  }
}

class HeadlessDriver implements PageDriver {
  final NativeBrowser browser;
  HeadlessDriver(this.browser);

  @override
  Future<void> load(String url) async => browser.load(url, timeoutMs: 30000);

  @override
  Future<Map<String, dynamic>?> evalJson(String js) => browser.evalJson(js);
}
