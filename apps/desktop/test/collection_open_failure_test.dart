// SPDX-FileCopyrightText: 2026 Hatto Social contributors
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hatto_desktop/effect/engine_host.dart';
import 'package:hatto_desktop/engine/engine.dart';
import 'package:path/path.dart' as p;
import 'package:rslib_bridge/rslib_bridge.dart';

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    await initRslibBridge();
  });

  test(
    'a failed collection open closes the engine and the side database',
    () async {
      final root = Directory('/tmp').createTempSync('hatto-open-fail');
      addTearDown(() {
        if (root.existsSync()) {
          root.deleteSync(recursive: true);
        }
      });
      final tmp = Directory(p.join(root.path, 'tmp'))..createSync();
      prepareRuntime(tmpDir: tmp.path);
      final dataDir = Directory(p.join(root.path, 'collection'))..createSync();
      final host = EngineHost();
      Engine? opened;
      await expectLater(
        host.open(
          dataDir: dataDir.path,
          openCollection: (engine, api) async {
            opened = engine;
            throw StateError('injected openCollection failure');
          },
        ),
        throwsA(
          isA<CollectionOpenException>()
              .having(
                (error) => error.cause,
                'cause',
                isA<StateError>().having(
                  (error) => error.message,
                  'message',
                  'injected openCollection failure',
                ),
              )
              .having(
                (error) => error.path,
                'path',
                File(p.join(dataDir.path, 'collection.anki2')).absolute.path,
              ),
        ),
      );
      expect(opened, isNotNull);
      expect(opened!.isOpen, isFalse);
      expect(host.engine, isNull);
      expect(host.flow, isNull);
      expect(host.sideDb, isNull);
    },
  );
}
