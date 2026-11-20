// SPDX-FileCopyrightText: 2026 Hatto Social contributors
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hatto_desktop/effect/engine_host.dart';
import 'package:path/path.dart' as p;
import 'package:rslib_bridge/rslib_bridge.dart';

void main() {
  test('main opens the collection only through EngineHost', () {
    final text = File('lib/main.dart').readAsStringSync();
    expect(text, contains('desktopHost.open'));
    expect(text, isNot(contains('InstanceLock.tryAcquire')));
    expect(text, isNot(contains('SideDb.openOrCreate')));
    expect(text, isNot(contains('Engine.open')));
    expect(text, isNot(contains('openCollection(')));
  });

  test('open takes the lock, then the side database, then the collection', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    await initRslibBridge();
    final root = Directory.systemTemp.createTempSync('hatto-open-order');
    addTearDown(() {
      if (root.existsSync()) {
        root.deleteSync(recursive: true);
      }
    });
    final tmp = Directory(p.join(root.path, 'tmp'))..createSync();
    prepareRuntime(tmpDir: tmp.path);
    final dataDir = Directory(p.join(root.path, 'collection'))..createSync();
    final host = EngineHost();
    addTearDown(host.close);

    final state = await host.open(dataDir: dataDir.path);
    expect(state.opened, isTrue);
    expect(host.openOrder, ['lock', 'sideDb', 'collection']);
    expect(host.holdsInstanceLock, isTrue);
    expect(host.sideDb, isNotNull);
    expect(host.flow, isNotNull);
    expect(File(p.join(dataDir.path, 'collection.anki2')).existsSync(), isTrue);
    expect(File(p.join(dataDir.path, 'hatto.sqlite')).existsSync(), isTrue);
  });
}
