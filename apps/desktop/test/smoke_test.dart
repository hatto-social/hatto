// SPDX-FileCopyrightText: 2026 Hatto Social contributors
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hatto_desktop/effect/engine_host.dart';
import 'package:path/path.dart' as p;
import 'package:rslib_bridge/rslib_bridge.dart';

void main() {
  test('open and close a temp collection, and FSRS init runs once', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    await initRslibBridge();
    final root = Directory.systemTemp.createTempSync('hatto-desktop-smoke');
    addTearDown(() {
      if (root.existsSync()) {
        root.deleteSync(recursive: true);
      }
    });
    final tmp = Directory(p.join(root.path, 'tmp'))..createSync();
    prepareRuntime(tmpDir: tmp.path);
    final dataDir = Directory(p.join(root.path, 'collection'))..createSync();
    final host = EngineHost();

    final first = await host.open(dataDir: dataDir.path);
    expect(first.opened, isTrue);
    expect(first.markerPresent, isTrue);
    final marker = File(
      p.join(dataDir.path, 'collection.anki2.hatto-fsrs-init'),
    );
    expect(marker.existsSync(), isTrue);
    expect(File('${marker.path}.tmp').existsSync(), isFalse);
    final modified = marker.statSync().modified;
    await host.close();

    final second = await host.open(dataDir: dataDir.path);
    expect(second.opened, isTrue);
    expect(second.markerPresent, isTrue);
    expect(marker.statSync().modified, modified);
    await host.close();
  });
}
