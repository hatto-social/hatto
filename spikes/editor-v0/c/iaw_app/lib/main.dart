import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

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
  final root = spikeRoot();
  final html = File(Platform.environment['CARD_HTML'] ?? '$root/c/card.html').readAsStringSync();
  runApp(MaterialApp(home: Scaffold(body: InAppWebView(
    initialData: InAppWebViewInitialData(data: html, baseUrl: WebUri('file://$root/c/ref/')),
    initialSettings: InAppWebViewSettings(allowFileAccessFromFileURLs: true, allowUniversalAccessFromFileURLs: true),
    onLoadStop: (c, u) => File('/tmp/c_iaw_loaded').writeAsStringSync('stop'),
    onTitleChanged: (c, t) => File('/tmp/c_iaw_title').writeAsStringSync('$t'),
  ))));
}
