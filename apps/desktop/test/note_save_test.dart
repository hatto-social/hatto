// SPDX-FileCopyrightText: 2026 Hatto Social contributors
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hatto_desktop/store/note_bytes.dart';
import 'package:hatto_desktop/store/note_writer.dart';
import 'package:hatto_store/hatto_store.dart' hide AnkiApi;
import 'package:path/path.dart' as p;
import 'package:rslib_bridge/rslib_bridge.dart';

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    await initRslibBridge();
  });

  test('saving a note records the map and a second guid is refused', () async {
    final root = Directory.systemTemp.createTempSync('hatto-note-save');
    addTearDown(() {
      if (root.existsSync()) {
        root.deleteSync(recursive: true);
      }
    });
    final tmp = Directory(p.join(root.path, 'tmp'))..createSync();
    prepareRuntime(tmpDir: tmp.path);
    final dataDir = Directory(p.join(root.path, 'collection'))..createSync();
    final media = Directory(p.join(dataDir.path, 'collection.media'))
      ..createSync();
    final api = await AnkiApi.openDesktop(
      dataDir: dataDir.path,
      collectionPath: p.join(dataDir.path, 'collection.anki2'),
      mediaFolderPath: media.path,
      mediaDbPath: p.join(dataDir.path, 'collection.media.db'),
    );
    addTearDown(api.closeCollection);
    final side = SideDb.openOrCreate(p.join(dataDir.path, 'hatto.sqlite'));
    addTearDown(side.close);
    final writer = NoteWriter(db: side, backend: api.backend);

    final names = serviceMethodIndex(
      service: 'BackendNotetypesService',
      method: 'get_notetype_id_by_name',
    )!;
    final named = await command(
      backend: api.backend,
      service: names.service,
      method: names.method,
      input: encodeString('Basic'),
    );
    expect(named.success, isTrue, reason: String.fromCharCodes(named.payload));
    final notetypeId = fieldVarint(named.payload, 1)!;
    const guid = '11111111-1111-4111-8111-111111111111';

    final saved = await writer.addNote(
      guid: guid,
      notetypeId: notetypeId,
      deckId: 1,
      fields: [
        '<script>alert(1)</script>',
        '<iframe src="https://x"></iframe>',
      ],
      opId: 'op-1',
    );
    expect(saved, isNull);
    final row = side.note(guid)!;
    expect(row.noteGuid, guid);
    expect(side.deckByRslibId(1), isNotNull);
    expect(row.homeDeckGuid, side.deckByRslibId(1)!.deckGuid);
    expect(side.deckByRslibId(1)!.originKind, 'editor');
    expect(side.journalRows(), isEmpty);
    expect(side.pendingIntentCount(), 0);

    final again = await writer.addNote(
      guid: guid,
      notetypeId: notetypeId,
      deckId: 1,
      fields: ['front', 'back'],
      opId: 'op-2',
    );
    expect(again, contains('already mapped'));
  });

  test('a rejected note is a message and the window can stay open', () async {
    final root = Directory('/tmp').createTempSync('hatto-note-reject');
    addTearDown(() {
      if (root.existsSync()) {
        root.deleteSync(recursive: true);
      }
    });
    final tmp = Directory(p.join(root.path, 'tmp'))..createSync();
    prepareRuntime(tmpDir: tmp.path);
    final dataDir = Directory(p.join(root.path, 'collection'))..createSync();
    final media = Directory(p.join(dataDir.path, 'collection.media'))
      ..createSync();
    final api = await AnkiApi.openDesktop(
      dataDir: dataDir.path,
      collectionPath: p.join(dataDir.path, 'collection.anki2'),
      mediaFolderPath: media.path,
      mediaDbPath: p.join(dataDir.path, 'collection.media.db'),
    );
    addTearDown(api.closeCollection);
    final side = SideDb.openOrCreate(p.join(dataDir.path, 'hatto.sqlite'));
    addTearDown(side.close);
    final writer = NoteWriter(db: side, backend: api.backend);
    final message = await writer.addNote(
      guid: 'not-a-uuid',
      notetypeId: 1,
      deckId: 1,
      fields: ['front', 'back'],
      opId: 'op',
    );
    expect(message, isNotNull);
    expect(side.notes(), isEmpty);
    expect(side.pendingIntentCount(), 0);
  });
}
