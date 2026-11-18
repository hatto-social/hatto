// Spike c (macOS): render the rslib card HTML + MathJax in WKWebView via webview_flutter_wkwebview. Untested on Mac by Dmitry.
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  final file = Platform.environment['CARD_FILE'] ?? '${Directory.current.path}/card.html';
  final c = WebViewController()
    ..setJavaScriptMode(JavaScriptMode.unrestricted)
    ..setNavigationDelegate(NavigationDelegate(
      onPageFinished: (u) async {
        await Future.delayed(const Duration(seconds: 3)); // let MathJax finish
        final title = await c_.runJavaScriptReturningResult('document.title');
        File('/tmp/web_mac_result.txt').writeAsStringSync('finished url=$u title=$title\n');
      }));
  c_ = c;
  c.loadFile(file);
  runApp(MaterialApp(home: Scaffold(body: WebViewWidget(controller: c))));
}
late WebViewController c_;
