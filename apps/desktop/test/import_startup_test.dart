// SPDX-FileCopyrightText: 2026 Hatto Social contributors
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hatto_desktop/effect/engine_host.dart';
import 'package:hatto_desktop/store/write_gateway.dart';
import 'package:hatto_store/hatto_store.dart';
import 'package:path/path.dart' as p;
import 'package:rslib_bridge/rslib_bridge.dart';

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    await initRslibBridge();
  });

  test(
    'S2 an empty import tree skips startup and review still opens',
    () async {
      final dataDir = _dataDir('hatto-s2a');
      final host = EngineHost();
      addTearDown(host.close);
      var called = false;
      final state = await host.open(
        dataDir: dataDir,
        importStartup: (_) async {
          called = true;
        },
      );
      expect(state.opened, isTrue);
      expect(host.importStartupRan, isFalse);
      expect(called, isFalse);
      expect(host.importStartupError, isNull);
      final queued = await host.flow!.queuedCards();
      expect(queued.cards, isEmpty);
      expect(host.holdsInstanceLock, isTrue);
    },
  );

  test('S2 a failing startup blocks import entry only', () async {
    final dataDir = _dataDir('hatto-s2b');
    File(p.join(dataDir, 'import', 'raw', 'keep.apkg'))
      ..parent.createSync(recursive: true)
      ..writeAsBytesSync(const [1]);
    final host = EngineHost();
    addTearDown(host.close);
    final state = await host.open(
      dataDir: dataDir,
      importStartup: (_) async {
        throw StateError('startup broke');
      },
    );
    expect(state.opened, isTrue);
    expect(host.importStartupRan, isTrue);
    expect(host.importStartupError, isA<StateError>());
    final queued = await host.flow!.queuedCards();
    expect(queued.cards, isEmpty);
    expect(
      () => host.writes!.importFile(sourcePath: 'missing.apkg', maxBytes: 10),
      throwsA(isA<ImportStartupException>()),
    );
  });

  test('import startup is needed only for an intent or a working file', () {
    final db = SideDb.openInMemory();
    addTearDown(db.close);
    final root = Directory.systemTemp.createTempSync('hatto-s2-need');
    addTearDown(() => root.deleteSync(recursive: true));
    expect(EngineHost.importStartupNeeded(db, root.path), isFalse);
    for (final name in const ['raw', 'e', 'staged']) {
      Directory(p.join(root.path, 'import', name)).createSync(recursive: true);
    }
    expect(EngineHost.importStartupNeeded(db, root.path), isFalse);
    File(p.join(root.path, 'import', 'staged', 'x.apkg'))
        .writeAsBytesSync(const [1]);
    expect(EngineHost.importStartupNeeded(db, root.path), isTrue);
    File(p.join(root.path, 'import', 'staged', 'x.apkg')).deleteSync();
    db.beginIntent(
      op: intentImport,
      targetKey: '11111111-1111-4111-8111-111111111111',
      expected: '{}',
    );
    expect(EngineHost.importStartupNeeded(db, root.path), isTrue);
  });
}

String _dataDir(String name) {
  final root = Directory('/tmp').createTempSync(name);
  addTearDown(() {
    if (root.existsSync()) {
      root.deleteSync(recursive: true);
    }
  });
  final data = Directory(p.join(root.path, 'collection'));
  data.createSync();
  return data.path;
}
