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
    for (final file in sources) {
      final text = file.readAsStringSync();
      expect(
        text.contains('openBackend('),
        isFalse,
        reason: '${file.path} calls openBackend',
      );
    }
  });

  test('side database writes stay in write_gateway.dart', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    expect(pubspec, contains('hatto_store'));
    expect(pubspec, isNot(contains('url_launcher')));
    const needles = [
      'WriteWrapper',
      'beginIntent',
      'completeIntent',
      'abandonIntent',
      'putDeck(',
      'importNote(',
      'putRevlogOrigin(',
      'markDeckDeleted(',
      'rewriteDeckGuid(',
      'setDeckServerUnsynced(',
      'deleteRevlogOrigin(',
      'replaceNote(',
      'reconcileCollection(',
    ];
    for (final file in sources) {
      final path = file.path.replaceAll('\\', '/');
      if (path.endsWith('/store/write_gateway.dart')) {
        continue;
      }
      final text = file.readAsStringSync();
      for (final needle in needles) {
        expect(
          text.contains(needle),
          isFalse,
          reason: '$path contains $needle',
        );
      }
    }
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
