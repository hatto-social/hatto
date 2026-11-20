// SPDX-FileCopyrightText: 2026 Hatto Social contributors
//
// SPDX-License-Identifier: AGPL-3.0-or-later

// Loads real fonts into flutter_test (otherwise everything renders as Ahem blocks): KaTeX (from the flutter_math_fork package), UI + Korean fonts of this box.
import 'dart:io';
import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:hatto_desktop/editor/anki_ui.dart' show kUiFont;

ByteData _b(String path) => ByteData.sublistView(File(path).readAsBytesSync());

File? _packageConfig() {
  var dir = Directory.current;
  for (var i = 0; i < 5; i++) {
    final file = File('${dir.path}/.dart_tool/package_config.json');
    if (file.existsSync()) return file;
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  return null;
}

Future<void> loadTestFonts() async {
  final config = _packageConfig();
  if (config != null) {
    final cfg = jsonDecode(config.readAsStringSync()) as Map<String, dynamic>;
    final pkg = (cfg['packages'] as List).firstWhere((p) => p['name'] == 'flutter_math_fork');
    final dir = Directory.fromUri(config.absolute.uri.resolve('${pkg['rootUri']}/lib/katex_fonts/fonts/'));
    if (dir.existsSync()) {
      final byFamily = <String, List<File>>{};
      for (final f in dir.listSync().whereType<File>().where((f) => f.path.endsWith('.ttf'))) {
        final base = f.uri.pathSegments.last;
        byFamily.putIfAbsent(base.split('-').first, () => []).add(f);
      }
      for (final e in byFamily.entries) {
        final loader = FontLoader('packages/flutter_math_fork/${e.key}');
        for (final f in e.value) {
          loader.addFont(Future.value(_b(f.path)));
        }
        await loader.load();
      }
    }
  }
  const noto = 'test/fonts/NotoSans-Regular.ttf';
  if (File(noto).existsSync()) {
    final bytes = Future.value(_b(noto));
    for (final family in ['NanumGothic', 'Liberation Sans', kUiFont]) {
      final loader = FontLoader(family)..addFont(bytes);
      await loader.load();
    }
  }
  final icons = File('${File(Platform.resolvedExecutable).parent.path}/../../artifacts/material_fonts/MaterialIcons-Regular.otf');
  if (icons.existsSync()) {
    final loader = FontLoader('MaterialIcons')..addFont(Future.value(_b(icons.path)));
    await loader.load();
  }
}
