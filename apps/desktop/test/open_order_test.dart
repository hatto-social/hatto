// SPDX-FileCopyrightText: 2026 Hatto Social contributors
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hatto_desktop/effect/engine_host.dart';
import 'package:hatto_store/hatto_store.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

void main() {
  test('main opens the collection only through EngineHost', () {
    final text = File('lib/main.dart').readAsStringSync();
    expect(text, contains('desktopHost.open'));
    expect(text, isNot(contains('InstanceLock.tryAcquire')));
    expect(text, isNot(contains('SideDb.openOrCreate')));
    expect(text, isNot(contains('Engine.open')));
    expect(text, isNot(contains('openCollection(')));
  });

  test('a held lock leaves the collection unopened', () async {
    final root = Directory.systemTemp.createTempSync('hatto-order-lock');
    addTearDown(() {
      if (root.existsSync()) {
        root.deleteSync(recursive: true);
      }
    });
    final child = await Process.start(dartExecutable(), [
      'run',
      'bin/lock_probe.dart',
      root.path,
      'hold',
    ], workingDirectory: _storePackage());
    child.stderr.listen((_) {});
    addTearDown(() async {
      child.stdin.close();
      child.kill();
      await child.exitCode.timeout(const Duration(seconds: 20));
    });
    await _waitUntilAcquired(child.stdout);

    await expectLater(
      EngineHost().open(dataDir: root.path),
      throwsA(isA<AlreadyRunningException>()),
    );
    expect(File(p.join(root.path, 'collection.anki2')).existsSync(), isFalse);
    expect(File(p.join(root.path, 'hatto.sqlite')).existsSync(), isFalse);
  });

  test('a newer side database leaves the collection unopened', () async {
    final root = Directory.systemTemp.createTempSync('hatto-order-schema');
    addTearDown(() {
      if (root.existsSync()) {
        root.deleteSync(recursive: true);
      }
    });
    final side = sqlite3.open(p.join(root.path, 'hatto.sqlite'));
    side.execute('PRAGMA user_version = 99');
    side.close();

    await expectLater(
      EngineHost().open(dataDir: root.path),
      throwsA(isA<NewerSchemaException>()),
    );
    expect(File(p.join(root.path, 'collection.anki2')).existsSync(), isFalse);
    final reopened = sqlite3.open(p.join(root.path, 'hatto.sqlite'));
    try {
      final version = reopened.select('PRAGMA user_version').first.values.first;
      expect(version, 99);
    } finally {
      reopened.close();
    }
  });
}

String _storePackage() {
  return p.normalize(
    p.join(Directory.current.path, '..', '..', 'packages', 'hatto_store'),
  );
}

Future<void> _waitUntilAcquired(Stream<List<int>> stdout) async {
  final lines = stdout.transform(utf8.decoder).transform(const LineSplitter());
  await for (final line in lines.timeout(const Duration(minutes: 2))) {
    if (line == 'acquired') {
      return;
    }
  }
  fail('lock probe did not acquire');
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
