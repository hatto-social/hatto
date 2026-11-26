// SPDX-FileCopyrightText: 2026 Hatto Social contributors
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:io';

import 'package:fixnum/fixnum.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hatto_desktop/effect/engine_host.dart';
import 'package:hatto_desktop/store/import_engine_desktop.dart';
import 'package:hatto_desktop/src/gen/anki/cards.pb.dart';
import 'package:hatto_desktop/src/gen/anki/collection.pb.dart';
import 'package:hatto_desktop/src/gen/anki/generic.pb.dart' as generic;
import 'package:hatto_desktop/src/gen/anki/import_export.pb.dart';
import 'package:hatto_desktop/src/gen/anki/notes.pb.dart';
import 'package:hatto_desktop/src/gen/anki/notetypes.pb.dart';
import 'package:hatto_store/hatto_store.dart';
import 'package:path/path.dart' as p;
import 'package:protobuf/protobuf.dart';
import 'package:rslib_bridge/rslib_bridge.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    await initRslibBridge();
  });

  test('T-A3 scan does not delete the content-addressed archive', () async {
    final root = Directory.systemTemp.createTempSync('hatto-ta3').absolute;
    addTearDown(() => root.deleteSync(recursive: true));
    final sha = 'ab' * 32;
    final archive = File(p.join(root.path, 'imports', sha))
      ..createSync(recursive: true)
      ..writeAsStringSync('keep-me');
    const batch = '11111111-1111-4111-8111-111111111111';
    final raw = File(p.join(root.path, 'import', 'raw', '$batch.apkg'))
      ..createSync(recursive: true)
      ..writeAsBytesSync(const [1, 2, 3]);

    final scan = await scanImportFolders(
      dataDir: root.path,
      preparedBatchIds: const [],
    );

    expect(archive.readAsStringSync(), 'keep-me');
    expect(raw.existsSync(), isFalse);
    expect(scan.removed, contains(batch));
  });

  test('T18 a revived card reattaches an orphan revlog', () async {
    final root = Directory.systemTemp.createTempSync('hatto-t18').absolute;
    addTearDown(() => root.deleteSync(recursive: true));
    final sourceDir = Directory(p.join(root.path, 'source'))..createSync();
    final apkg = File(p.join(root.path, 'deck.apkg'));
    final cardId = await _exportNotedRevlog(sourceDir, apkg);

    final dataDir = Directory(p.join(root.path, 'resident'))..createSync();
    final host = EngineHost();
    await host.open(dataDir: dataDir.path);
    final first = await host.writes!.importFile(
      sourcePath: apkg.path,
      maxBytes: 20 * 1024 * 1024,
    );
    expect(first, ImportOutcome.committed);
    await host.close();

    final collectionPath = p.join(dataDir.path, 'collection.anki2');
    final residentCard = _orphanTheCard(collectionPath, cardId);
    final side = sqlite3.open(p.join(dataDir.path, 'hatto.sqlite'));
    side.execute('DELETE FROM note_map');
    side.close();

    final again = EngineHost();
    addTearDown(again.close);
    await again.open(dataDir: dataDir.path);
    final second = await again.writes!.importFile(
      sourcePath: apkg.path,
      maxBytes: 20 * 1024 * 1024,
    );
    expect(second, ImportOutcome.committed);
    await again.close();

    final db = sqlite3.open(collectionPath);
    try {
      final revlog = db.select('SELECT cid FROM revlog WHERE id = ?', [
        residentCard.revlogId,
      ]);
      expect(revlog, isNotEmpty);
      final cid = revlog.single['cid'] as int;
      final cards = db.select('SELECT id FROM cards WHERE id = ?', [cid]);
      expect(cards, isNotEmpty, reason: 'orphan revlog cid $cid has no card');
    } finally {
      db.close();
    }
  });

  test(
    'pre note_count matches the resident sum and grows by new guids',
    () async {
      final root = Directory.systemTemp.createTempSync('hatto-pre').absolute;
      addTearDown(() => root.deleteSync(recursive: true));
      final sourceDir = Directory(p.join(root.path, 'source'))..createSync();
      final v1 = File(p.join(root.path, 'v1.apkg'));
      final v2 = File(p.join(root.path, 'v2.apkg'));
      await _exportChangedPair(sourceDir, v1, v2);

      final dataDir = Directory(p.join(root.path, 'resident'))..createSync();
      final host = EngineHost();
      addTearDown(host.close);
      await host.open(dataDir: dataDir.path);
      final counter = DesktopImportEngine(
        engine: host.engine!,
        dataDir: dataDir.path,
      );
      final first = await host.writes!.importFile(
        sourcePath: v1.path,
        maxBytes: 20 * 1024 * 1024,
      );
      expect(first, ImportOutcome.committed);
      final before = await counter.notetypeUseCountSum();

      ImportIntentExpected? seen;
      final second = await host.writes!.importFile(
        sourcePath: v2.path,
        maxBytes: 20 * 1024 * 1024,
        fault: (phase) {
          if (phase == ImportPhase.afterIntent) {
            seen = decodeImportIntentExpected(
              host.sideDb!.pendingIntents().single.expected!,
            );
          }
        },
      );
      expect(second, ImportOutcome.committed);
      expect(seen, isNotNull);
      expect(seen!.pre.noteCount, before);
      expect(seen!.newGuids, hasLength(1));
      expect(seen!.changed, isNotEmpty);
      expect(
        await counter.notetypeUseCountSum(),
        before + seen!.newGuids.length,
      );
    },
  );
}

class _Orphan {
  _Orphan(this.revlogId);
  final int revlogId;
}

Future<int> _exportNotedRevlog(Directory dir, File apkg) async {
  final media = Directory(p.join(dir.path, 'collection.media'))..createSync();
  final backend = await openBackend(initMsg: encodeBackendInit());
  Future<List<int>> invoke(
    String service,
    String method,
    GeneratedMessage req,
  ) async {
    final index = serviceMethodIndex(service: service, method: method);
    if (index == null) {
      throw StateError('no index for $service.$method');
    }
    final response = await command(
      backend: backend,
      service: index.service,
      method: index.method,
      input: req.writeToBuffer(),
    );
    if (!response.success) {
      throw StateError('$service.$method failed');
    }
    return response.payload;
  }

  await invoke(
    'BackendCollectionService',
    'open_collection',
    OpenCollectionRequest(
      collectionPath: p.join(dir.path, 'collection.anki2'),
      mediaFolderPath: media.path,
      mediaDbPath: p.join(dir.path, 'collection.media.db'),
    ),
  );
  final notetype = NotetypeId.fromBuffer(
    await invoke(
      'BackendNotetypesService',
      'get_notetype_id_by_name',
      generic.String(val: 'Basic'),
    ),
  );
  final fresh = Note.fromBuffer(
    await invoke('BackendNotesService', 'new_note', notetype),
  );
  fresh.fields
    ..clear()
    ..addAll(['front', 'back']);
  final added = AddNoteResponse.fromBuffer(
    await invoke(
      'BackendNotesService',
      'add_note',
      AddNoteRequest(note: fresh, deckId: Int64(1)),
    ),
  );
  final cards = CardIds.fromBuffer(
    await invoke(
      'BackendNotesService',
      'cards_of_note',
      NoteId(nid: added.noteId),
    ),
  );
  final cardId = cards.cids.single.toInt();
  await invoke(
    'BackendCollectionService',
    'close_collection',
    CloseCollectionRequest(),
  );
  final db = sqlite3.open(p.join(dir.path, 'collection.anki2'));
  db.execute(
    'INSERT INTO revlog (id, cid, usn, ease, ivl, lastIvl, factor, time, type) '
    'VALUES (?, ?, -1, 3, 1, 0, 2500, 1000, 1)',
    [88001, cardId],
  );
  db.close();
  final again = await openBackend(initMsg: encodeBackendInit());
  Future<void> send(String service, String method, GeneratedMessage req) async {
    final index = serviceMethodIndex(service: service, method: method);
    if (index == null) {
      throw StateError('no index for $service.$method');
    }
    final response = await command(
      backend: again,
      service: index.service,
      method: index.method,
      input: req.writeToBuffer(),
    );
    if (!response.success) {
      throw StateError('$service.$method failed');
    }
  }

  await send(
    'BackendCollectionService',
    'open_collection',
    OpenCollectionRequest(
      collectionPath: p.join(dir.path, 'collection.anki2'),
      mediaFolderPath: media.path,
      mediaDbPath: p.join(dir.path, 'collection.media.db'),
    ),
  );
  await send(
    'BackendImportExportService',
    'export_anki_package',
    ExportAnkiPackageRequest(
      outPath: apkg.path,
      options: ExportAnkiPackageOptions(
        withScheduling: true,
        withDeckConfigs: true,
        withMedia: true,
        legacy: false,
      ),
      limit: ExportLimit(wholeCollection: generic.Empty()),
    ),
  );
  await send(
    'BackendCollectionService',
    'close_collection',
    CloseCollectionRequest(),
  );
  return cardId;
}

_Orphan _orphanTheCard(String collectionPath, int sourceCardId) {
  final db = sqlite3.open(collectionPath);
  try {
    final rows = db.select('SELECT id, cid FROM revlog');
    expect(rows, isNotEmpty);
    final revlogId = rows.single['id'] as int;
    final cid = rows.single['cid'] as int;
    expect(cid, sourceCardId);
    db.execute('DELETE FROM cards');
    db.execute('DELETE FROM notes');
    return _Orphan(revlogId);
  } finally {
    db.close();
  }
}

const _changedGuid = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc';

Future<void> _exportChangedPair(Directory dir, File v1, File v2) async {
  final media = Directory(p.join(dir.path, 'collection.media'))..createSync();
  final collectionPath = p.join(dir.path, 'collection.anki2');
  final mediaDb = p.join(dir.path, 'collection.media.db');

  Future<List<int>> invoke(
    AnkiBackend backend,
    String service,
    String method,
    GeneratedMessage req,
  ) async {
    final index = serviceMethodIndex(service: service, method: method);
    if (index == null) {
      throw StateError('no index for $service.$method');
    }
    final response = await command(
      backend: backend,
      service: index.service,
      method: index.method,
      input: req.writeToBuffer(),
    );
    if (!response.success) {
      throw StateError('$service.$method failed: ${response.payload}');
    }
    return response.payload;
  }

  Future<void> open(AnkiBackend backend) {
    return invoke(
      backend,
      'BackendCollectionService',
      'open_collection',
      OpenCollectionRequest(
        collectionPath: collectionPath,
        mediaFolderPath: media.path,
        mediaDbPath: mediaDb,
      ),
    );
  }

  Future<void> close(AnkiBackend backend) {
    return invoke(
      backend,
      'BackendCollectionService',
      'close_collection',
      CloseCollectionRequest(),
    );
  }

  Future<void> export(AnkiBackend backend, File out) {
    return invoke(
      backend,
      'BackendImportExportService',
      'export_anki_package',
      ExportAnkiPackageRequest(
        outPath: out.path,
        options: ExportAnkiPackageOptions(
          withScheduling: true,
          withDeckConfigs: true,
          withMedia: true,
          legacy: false,
        ),
        limit: ExportLimit(wholeCollection: generic.Empty()),
      ),
    );
  }

  final created = await openBackend(initMsg: encodeBackendInit());
  await open(created);
  final notetype = NotetypeId.fromBuffer(
    await invoke(
      created,
      'BackendNotetypesService',
      'get_notetype_id_by_name',
      generic.String(val: 'Basic'),
    ),
  );
  final fresh = Note.fromBuffer(
    await invoke(created, 'BackendNotesService', 'new_note', notetype),
  );
  fresh.fields
    ..clear()
    ..addAll(['front', 'back']);
  final added = AddNoteResponse.fromBuffer(
    await invoke(
      created,
      'BackendNotesService',
      'add_note',
      AddNoteRequest(note: fresh, deckId: Int64(1)),
    ),
  );
  final noteId = added.noteId.toInt();
  await close(created);

  final sql = sqlite3.open(collectionPath);
  sql.execute('UPDATE notes SET guid = ?, mod = 1000 WHERE id = ?', [
    _changedGuid,
    noteId,
  ]);
  sql.close();

  final first = await openBackend(initMsg: encodeBackendInit());
  await open(first);
  await export(first, v1);
  await close(first);

  final second = await openBackend(initMsg: encodeBackendInit());
  await open(second);
  final stored = Note.fromBuffer(
    await invoke(
      second,
      'BackendNotesService',
      'get_note',
      NoteId(nid: Int64(noteId)),
    ),
  );
  stored.fields[0] = 'front-changed';
  await invoke(
    second,
    'BackendNotesService',
    'update_notes',
    UpdateNotesRequest(notes: [stored], skipUndoEntry: true),
  );
  final extra = Note.fromBuffer(
    await invoke(second, 'BackendNotesService', 'new_note', notetype),
  );
  extra.fields
    ..clear()
    ..addAll(['new-front', 'new-back']);
  await invoke(
    second,
    'BackendNotesService',
    'add_note',
    AddNoteRequest(note: extra, deckId: Int64(1)),
  );
  await export(second, v2);
  await close(second);
}
