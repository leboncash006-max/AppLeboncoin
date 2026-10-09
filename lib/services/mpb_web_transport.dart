import 'dart:async';
import 'dart:convert';

import 'package:webview_flutter/webview_flutter.dart';

/// Fait les requêtes MPB depuis une page mpb.com ouverte dans une WebView :
/// c'est un vrai moteur Chrome, avec les cookies du site, que l'anti-robot de
/// MPB laisse passer (il refuse le client HTTP de Dart avec un 403).
///
/// La WebView doit être affichée quelque part (même repliée à 1 px) pour que
/// la page se charge normalement.
class MpbWebTransport {
  static final home = Uri.parse('https://www.mpb.com/fr-fr/');

  final controller = WebViewController();

  /// Appelé quand MPB répond par une page HTML (vérification anti-robot) :
  /// l'écran peut alors déplier la WebView pour que l'utilisateur la fasse.
  void Function()? onChallenge;

  final _pending = <int, Completer<({int status, String body})>>{};
  var _nextId = 0;

  /// Vérification non passée pendant cette analyse : on n'attend plus 90 s
  /// à chaque requête suivante.
  var _gaveUp = false;
  Completer<void> _ready = Completer<void>();

  MpbWebTransport() {
    controller
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..addJavaScriptChannel('MpbBridge', onMessageReceived: _onMessage)
      ..setNavigationDelegate(NavigationDelegate(onPageFinished: (_) {
        if (!_ready.isCompleted) _ready.complete();
      }))
      ..loadRequest(home);
  }

  void _onMessage(JavaScriptMessage m) {
    try {
      final j = jsonDecode(m.message) as Map<String, dynamic>;
      final c = _pending.remove((j['id'] as num).toInt());
      c?.complete((status: (j['status'] as num).toInt(), body: (j['body'] ?? '').toString()));
    } catch (_) {}
  }

  Future<({int status, String body})> _jsFetch(Uri uri, Map<String, String> headers) async {
    await _ready.future.timeout(const Duration(seconds: 30),
        onTimeout: () => throw Exception('mpb.com ne se charge pas dans la WebView.'));
    final id = _nextId++;
    final c = Completer<({int status, String body})>();
    _pending[id] = c;
    // requête « same-origin » depuis la page mpb.com, avec ses cookies
    await controller.runJavaScript('''
fetch(${jsonEncode(uri.toString())}, {headers: ${jsonEncode(headers)}, credentials: 'include'})
  .then(r => r.text().then(t => MpbBridge.postMessage(JSON.stringify({id: $id, status: r.status, body: t}))))
  .catch(e => MpbBridge.postMessage(JSON.stringify({id: $id, status: 0, body: String(e)})));
''');
    return c.future.timeout(const Duration(seconds: 20), onTimeout: () {
      _pending.remove(id);
      throw Exception('MPB ne répond pas (délai dépassé).');
    });
  }

  /// [MpbFetch] pour MpbService. Si MPB renvoie une page HTML, la page mpb.com
  /// est rechargée (le navigateur passe souvent la vérification tout seul,
  /// sinon elle s'affiche à l'écran) puis la requête est refaite.
  Future<({int status, String body})> fetch(Uri uri, Map<String, String> headers) async {
    var r = await _jsFetch(uri, headers);
    if (_isJson(r.body)) {
      _gaveUp = false;
      return r;
    }
    if (_gaveUp) return r;
    onChallenge?.call();
    _ready = Completer<void>();
    await controller.loadRequest(home);
    // laisse le temps à une éventuelle vérification (automatique ou manuelle)
    final deadline = DateTime.now().add(const Duration(seconds: 90));
    while (true) {
      await Future.delayed(const Duration(seconds: 3));
      r = await _jsFetch(uri, headers);
      if (_isJson(r.body)) return r;
      if (DateTime.now().isAfter(deadline)) {
        _gaveUp = true;
        return r;
      }
    }
  }

  static bool _isJson(String b) {
    final t = b.trimLeft();
    return t.startsWith('{') || t.startsWith('[');
  }
}
