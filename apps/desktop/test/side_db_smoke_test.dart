// SPDX-FileCopyrightText: 2026 Hatto Social contributors
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hatto_desktop/effect/engine_host.dart';
import 'package:hatto_store/hatto_store.dart';
import 'package:path/path.dart' as p;
import 'package:rslib_bridge/rslib_bridge.dart';

void main() {
  test('opens the collection and the side database in one process', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    await initRslibBridge();
    final root = Directory.systemTemp.createTempSync('hatto-side-smoke');
    addTearDown(() {
      if (root.existsSync()) {
        root.deleteSync(recursive: true);
      }
    });
    final tmp = Directory(p.join(root.path, 'tmp'))..createSync();
    prepareRuntime(tmpDir: tmp.path);
    final dataDir = Directory(p.join(root.path, 'collection'))..createSync();
    final host = EngineHost();

    final state = await host.open(dataDir: dataDir.path);
    expect(state.opened, isTrue);
    expect(host.holdsInstanceLock, isTrue);
    expect(File(p.join(dataDir.path, 'collection.anki2')).existsSync(), isTrue);
    expect(File(p.join(dataDir.path, 'hatto.sqlite')).existsSync(), isTrue);
    expect(File(p.join(dataDir.path, 'hatto.lock')).existsSync(), isTrue);
    final side = host.sideDb!;
    expect(side.schemaVersion, 1);
    expect(side.deviceId, matches(uuidVersion4Or5));
    expect(host.writes, isNotNull);
    await host.close();
    expect(host.sideDb, isNull);
    expect(host.holdsInstanceLock, isTrue);
  });
}
