// SPDX-FileCopyrightText: 2026 Hatto Social contributors
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hatto_desktop/effect/engine_host.dart';
import 'package:hatto_store/hatto_store.dart';
import 'package:path/path.dart' as p;

void main() {
  test(
    'a second process is already running and the collection stays closed',
    () async {
      final root = Directory.systemTemp.createTempSync('hatto-already');
      addTearDown(() {
        if (root.existsSync()) {
          root.deleteSync(recursive: true);
        }
      });
      final store = p.normalize(
        p.join(Directory.current.path, '..', '..', 'packages', 'hatto_store'),
      );
      final child = await Process.start(dartExecutable(), [
        'run',
        'bin/lock_probe.dart',
        root.path,
        'hold',
      ], workingDirectory: store);
      child.stderr.listen((_) {});
      addTearDown(() async {
        child.stdin.close();
        child.kill();
        await child.exitCode.timeout(const Duration(seconds: 20));
      });
      final lines = child.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter());
      String? acquired;
      await for (final line in lines.timeout(const Duration(minutes: 2))) {
        if (line == 'acquired') {
          acquired = line;
          break;
        }
      }
      expect(acquired, 'acquired');

      await expectLater(
        EngineHost().open(dataDir: root.path),
        throwsA(isA<AlreadyRunningException>()),
      );
      expect(File(p.join(root.path, 'collection.anki2')).existsSync(), isFalse);
      expect(File(p.join(root.path, 'hatto.sqlite')).existsSync(), isFalse);
    },
  );
}

String dartExecutable() {
  final resolved = Platform.resolvedExecutable;
  final base = p.basename(resolved);
  if (base == 'dart' || base == 'dart.exe') {
    return resolved;
  }
  final which = Process.runSync('which', ['dart']);
  if (which.exitCode == 0) {
    final line = (which.stdout as String).trim().split('\n').first.trim();
    if (line.isNotEmpty) {
      return line;
    }
  }
  throw StateError('dart is not on PATH (resolved executable: $resolved)');
}
