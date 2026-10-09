import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../radar/radar_bridge.dart';

/// Connexion à Leboncoin dans une WebView visible : je tape moi-même mes
/// identifiants, l'appli ne lit ni ne garde jamais le mot de passe. Seuls les
/// cookies de session de la WebView sont conservés (comme un navigateur).
class LbcLoginScreen extends StatefulWidget {
  const LbcLoginScreen({super.key});

  static const startUrl = 'https://www.leboncoin.fr/compte/part/mes-annonces';

  @override
  State<LbcLoginScreen> createState() => _LbcLoginScreenState();
}

class _LbcLoginScreenState extends State<LbcLoginScreen> {
  late final WebViewController _web = WebViewController()
    ..setJavaScriptMode(JavaScriptMode.unrestricted)
    ..setNavigationDelegate(NavigationDelegate(
      onProgress: (p) {
        if (mounted) setState(() => _progress = p);
      },
      onNavigationRequest: (r) =>
          r.url.startsWith('http') ? NavigationDecision.navigate : NavigationDecision.prevent,
    ))
    ..loadRequest(Uri.parse(LbcLoginScreen.startUrl));
  int _progress = 0;

  Future<void> _done() async {
    await RadarBridge.flushCookies();
    if (mounted) Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) RadarBridge.flushCookies();
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Connexion Leboncoin'),
          actions: [
            IconButton(tooltip: 'Recharger', icon: const Icon(Icons.refresh), onPressed: () => _web.reload()),
            TextButton(onPressed: _done, child: const Text('Terminé')),
          ],
          bottom: _progress < 100
              ? PreferredSize(
                  preferredSize: const Size.fromHeight(3),
                  child: LinearProgressIndicator(value: _progress / 100, minHeight: 3))
              : null,
        ),
        body: Column(children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            color: Theme.of(context).colorScheme.surfaceContainerHigh,
            child: const Text(
              'Connecte-toi normalement (et fais toi-même la vérification si on te la demande). '
              'L\'appli ne lit pas ton mot de passe : seule la session reste ouverte.',
              style: TextStyle(fontSize: 12.5),
            ),
          ),
          Expanded(child: WebViewWidget(controller: _web)),
        ]),
      ),
    );
  }
}
