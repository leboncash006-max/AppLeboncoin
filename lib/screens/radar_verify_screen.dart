import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../radar/radar_bridge.dart';
import '../radar/radar_db.dart';

/// Vérification Leboncoin faite À LA MAIN dans une WebView visible. Le radar
/// ne contourne ni ne résout jamais lui-même une vérification.
class RadarVerifyScreen extends StatefulWidget {
  final String url;
  const RadarVerifyScreen({super.key, required this.url});

  @override
  State<RadarVerifyScreen> createState() => _RadarVerifyScreenState();
}

class _RadarVerifyScreenState extends State<RadarVerifyScreen> {
  late final _web = WebViewController()
    ..setJavaScriptMode(JavaScriptMode.unrestricted)
    ..loadRequest(Uri.parse(widget.url));

  Future<void> _done() async {
    await RadarDb.set('state', null);
    await RadarDb.set('verify_url', null);
    await RadarDb.setInt('failures', 0);
    await RadarDb.log('Vérification faite : le radar reprend');
    await RadarBridge.start('resume');
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Vérification Leboncoin')),
      body: Column(children: [
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 0, 16, 10),
          child: Text('Fais la vérification ci-dessous, attends que l\'annonce ou la recherche '
              's\'affiche, puis appuie sur « C\'est fait ».'),
        ),
        Expanded(child: WebViewWidget(controller: _web)),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: _done,
                icon: const Icon(Icons.check),
                label: const Text('C\'est fait, reprendre le radar'),
              ),
            ),
          ),
        ),
      ]),
    );
  }
}
