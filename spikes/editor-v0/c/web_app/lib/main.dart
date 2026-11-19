import 'dart:io';
import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

String spikeRoot() {
  final env = Platform.environment['EDITOR_SPIKE_ROOT'];
  if (env != null && env.isNotEmpty) return env;
  var dir = Directory.current.absolute;
  for (var i = 0; i < 8; i++) {
    if (File('${dir.path}/docs/DMITRY_EDITOR_SPIKES.md').existsSync()) return dir.path;
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  throw StateError('Set EDITOR_SPIKE_ROOT to spikes/editor-v0');
}

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  final html = File(Platform.environment['CARD_HTML'] ?? '${spikeRoot()}/c/card.html').readAsStringSync();
  final c = WebViewController()..setJavaScriptMode(JavaScriptMode.unrestricted)
    ..setNavigationDelegate(NavigationDelegate(onPageFinished: (u) => File('/tmp/c_web_loaded').writeAsStringSync('finished $u')))
    ..loadHtmlString(html);
  runApp(MaterialApp(home: Scaffold(body: WebViewWidget(controller: c))));
}
