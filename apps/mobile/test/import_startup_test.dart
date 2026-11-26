// SPDX-FileCopyrightText: 2026 Hatto Social contributors
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hatto_mobile/main.dart';
import 'package:hatto_mobile/store/import_engine_mobile.dart';
import 'package:hatto_mobile/store/mobile_anki.dart';
import 'package:hatto_mobile/store/mobile_startup.dart';
import 'package:hatto_mobile/store/mobile_write_gateway.dart';
import 'package:hatto_mobile/store/resident_collection.dart';
import 'package:hatto_store/hatto_store.dart';
import 'package:path/path.dart' as p;
import 'package:rslib_bridge/rslib_bridge.dart' hide ProtoResponse;

import 'import_fixture.dart';

late Directory _stableTmp;

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    await initRslibBridge();
    _stableTmp = await Directory.systemTemp.createTemp('hatto-mobile-tmp');
    addTearDown(() => _stableTmp.delete(recursive: true));
    prepareRuntime(tmpDir: _stableTmp.path);
  });

  // smokeOpenCollection points TMPDIR at the collection. Put it back before
  // the next test creates a directory.
  setUp(() {
    prepareRuntime(tmpDir: _stableTmp.path);
  });

  test(
    'S2 an empty import tree skips recovery and the collection reopens',
    () async {
      final layout = await _layout('hatto-s2-empty');
      final report = await openResidentAndRecover(
        documentsDirectory: layout.documents.path,
        residentDirectory: layout.resident.path,
      );
      expect(report.recoveryRan, isFalse);
      expect(report.startupError, isNull);
      expect(report.pendingIntents, 0);
      expect(report.statusLine, isNot(contains('import startup failed')));

      final summary = await smokeOpenCollection(dir: layout.resident.path);
      expect(summary, startsWith('anki 26.09.3; server=false;'));
    },
  );

  test(
    'S2 a failed startup is one status line and importFile throws',
    () async {
      final layout = await _layout('hatto-s2-fail');
      final side = openSideDatabase(layout.documents.path);
      side.beginIntent(
        op: intentImport,
        targetKey: '11111111-1111-4111-8111-111111111111',
        expected: '{}',
      );
      side.close();

      final report = await openResidentAndRecover(
        documentsDirectory: layout.documents.path,
        residentDirectory: layout.resident.path,
      );
      expect(report.recoveryRan, isTrue);
      expect(report.startupError, isA<SideDbException>());
      expect(report.statusLine, contains('\nimport startup failed:'));
      expect('\n'.allMatches(report.statusLine), hasLength(1));

      final summary = await smokeOpenCollection(dir: layout.resident.path);
      expect(summary, startsWith('anki 26.09.3; server=false;'));

      final reopened = openSideDatabase(layout.documents.path);
      addTearDown(reopened.close);
      final gateway = MobileWriteGateway(db: reopened);
      gateway.noteImportStartupFailure(report.startupError!);
      expect(
        () => gateway.importFile(
          sourcePath: 'missing.apkg',
          limits: const ImportLimits(maxBytes: 10, maxUncompressedBytes: 10),
        ),
        throwsA(
          isA<ImportStartupException>().having(
            (err) => err.cause,
            'cause',
            same(report.startupError),
          ),
        ),
      );
    },
  );

  test(
    'S2 startup adopts a post-commit import and leaves the archive',
    () async {
      final layout = await _layout('hatto-s2-adopt');
      final source = fixtureFile('stock-notes.apkg');
      final collection = await ResidentCollection.open(layout.resident.path);
      final side = openSideDatabase(layout.documents.path);
      final gateway = MobileWriteGateway(db: side);
      gateway.attachImport(
        anki: MobileAnkiApi(collection),
        engine: MobileImportEngine(
          backend: collection.backend,
          dataDir: layout.resident.path,
        ),
        dataDir: layout.resident.path,
      );
      await expectLater(
        gateway.importFile(
          sourcePath: source.path,
          limits: fixtureLimits,
          fault: (phase) {
            if (phase == ImportPhase.afterResidentCommit) {
              throw StateError('crash in the post-commit window');
            }
          },
        ),
        throwsA(isA<StateError>()),
      );
      expect(side.pendingIntentCount(), 1);
      expect(side.notes(), isEmpty);
      final notesBefore = await scalar(
        collection,
        'select count(*) from notes',
      );
      expect(notesBefore, greaterThan(0));
      await collection.close();
      side.close();

      final report = await openResidentAndRecover(
        documentsDirectory: layout.documents.path,
        residentDirectory: layout.resident.path,
      );
      expect(report.startupError, isNull);
      expect(report.recoveryRan, isTrue);
      expect(report.pendingIntents, 0);

      final adopted = openSideDatabase(layout.documents.path);
      addTearDown(adopted.close);
      expect(adopted.notes(), hasLength(notesBefore));
      expect(adopted.decks(), isNotEmpty);
      expect(adopted.pendingIntentCount(), 0);
      expect(workFiles(layout.resident.path), isEmpty);

      final archive = File(
        importArchivePath(layout.resident.path, sha256OfFile(source)),
      );
      expect(archive.existsSync(), isTrue);
      expect(archive.lengthSync(), source.lengthSync());
      expect(
        p.canonicalize(sideDbPath(layout.documents.path)),
        isNot(p.canonicalize(archive.path)),
      );
      expect(
        p.isWithin(
          p.join(layout.resident.path, 'imports'),
          sideDbPath(layout.documents.path),
        ),
        isFalse,
      );

      File(
          p.join(
            layout.resident.path,
            'import',
            'raw',
            '22222222-2222-4222-8222-222222222222.apkg',
          ),
        )
        ..createSync(recursive: true)
        ..writeAsBytesSync(const [9]);
      final again = await openResidentAndRecover(
        documentsDirectory: layout.documents.path,
        residentDirectory: layout.resident.path,
      );
      expect(again.startupError, isNull);
      expect(archive.existsSync(), isTrue);
      expect(archive.readAsBytesSync(), source.readAsBytesSync());
      expect(workFiles(layout.resident.path), isEmpty);
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}

class _Layout {
  _Layout(this.documents, this.resident);

  final Directory documents;
  final Directory resident;
}

Future<_Layout> _layout(String name) async {
  final root = await Directory.systemTemp.createTemp(name);
  addTearDown(() => root.delete(recursive: true));
  final documents = Directory(p.join(root.path, 'documents'))..createSync();
  final resident = Directory(p.join(root.path, 'resident'))..createSync();
  return _Layout(documents, resident);
}
