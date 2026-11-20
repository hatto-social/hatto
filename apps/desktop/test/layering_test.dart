// SPDX-FileCopyrightText: 2026 Hatto Social contributors
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final sources = Directory('lib')
      .listSync(recursive: true)
      .whereType<File>()
      .where((file) => file.path.endsWith('.dart'))
      .toList();

  test('ui and state do not import io or the bridge', () {
    final forbidden = [
      "import 'dart:io'",
      'package:rslib_bridge',
      'package:path_provider',
    ];
    for (final file in sources) {
      final path = file.path.replaceAll('\\', '/');
      final guarded =
          path.contains('/about/') ||
          path.contains('/state/') ||
          path.endsWith('/app.dart');
      if (!guarded) {
        continue;
      }
      final text = file.readAsStringSync();
      for (final needle in forbidden) {
        expect(
          _imports(text, needle),
          isFalse,
          reason: '${file.path} imports $needle',
        );
      }
    }
  });

  test('note_html stays free of Flutter', () {
    for (final file in sources) {
      final path = file.path.replaceAll('\\', '/');
      if (!path.contains('/note_html/')) {
        continue;
      }
      final text = file.readAsStringSync();
      expect(_imports(text, 'package:flutter'), isFalse, reason: path);
      expect(_imports(text, 'dart:ui'), isFalse, reason: path);
      expect(noteHtmlDeclaresALibrary(text), isTrue, reason: path);
    }
  });

  test('desktop code does not open the mobile-unrestricted backend', () {
    final opener = RegExp(r'\bopenBackend\b');
    final construct = RegExp(r'\bAnkiApi\s*\(');
    for (final file in sources) {
      final text = file.readAsStringSync();
      expect(
        opener.hasMatch(text),
        isFalse,
        reason: '${file.path} names openBackend',
      );
      expect(
        construct.hasMatch(text),
        isFalse,
        reason: '${file.path} constructs AnkiApi',
      );
    }
  });

  test(
    'the desktop package does not depend on hatto_store or url_launcher',
    () {
      final pubspec = File('pubspec.yaml').readAsStringSync();
      expect(pubspec, isNot(contains('hatto_store')));
      expect(pubspec, isNot(contains('url_launcher')));
    },
  );

  test('the desktop app does not take a webview, url_launcher, or HttpClient', () {
    const packages = [
      'webview_flutter',
      'flutter_inappwebview',
      'webview_windows',
      'url_launcher',
    ];
    final pubspec = File('pubspec.yaml').readAsStringSync();
    for (final name in packages) {
      expect(pubspec, isNot(contains('$name:')), reason: name);
    }
    expect(pubspec, isNot(contains('flutter_widget_from_html:')));
    final httpClient = RegExp(r'\bHttpClient\b');
    final processRun = RegExp(r'\bProcess\.run\b');
    for (final file in sources) {
      final path = file.path.replaceAll('\\', '/');
      final text = file.readAsStringSync();
      expect(httpClient.hasMatch(text), isFalse, reason: '$path names HttpClient');
      expect(_imports(text, 'package:http'), isFalse, reason: path);
      expect(_imports(text, 'package:url_launcher'), isFalse, reason: path);
      for (final name in packages) {
        expect(_imports(text, 'package:$name'), isFalse, reason: '$path imports $name');
      }
      expect(
        _imports(text, 'package:flutter_widget_from_html/'),
        isFalse,
        reason: path,
      );
      if (processRun.hasMatch(text)) {
        expect(path, endsWith('lib/effect/open_url.dart'));
      }
    }
    expect(
      File('lib/effect/open_url.dart').readAsStringSync(),
      contains('Process.run'),
    );
  });
}

bool noteHtmlDeclaresALibrary(String source) {
  return source.contains('library;') || source.contains('library ');
}

bool _imports(String source, String needle) {
  for (final line in source.split('\n')) {
    final trimmed = line.trimLeft();
    if (!trimmed.startsWith('import ') && !trimmed.startsWith('export ')) {
      continue;
    }
    if (trimmed.contains(needle)) {
      return true;
    }
  }
  return false;
}
