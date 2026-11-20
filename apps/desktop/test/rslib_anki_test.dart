// SPDX-FileCopyrightText: 2026 Hatto Social contributors
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:io';

import 'package:fixnum/fixnum.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hatto_desktop/effect/engine_host.dart';
import 'package:hatto_desktop/src/gen/anki/cards.pb.dart';
import 'package:hatto_desktop/src/gen/anki/collection.pb.dart';
import 'package:hatto_desktop/src/gen/anki/generic.pb.dart' as g;
import 'package:hatto_desktop/src/gen/anki/notes.pb.dart';
import 'package:hatto_desktop/src/gen/anki/notetypes.pb.dart';
import 'package:hatto_desktop/store/rslib_anki.dart';
import 'package:path/path.dart' as p;
import 'package:protobuf/protobuf.dart';
import 'package:rslib_bridge/rslib_bridge.dart';
import 'package:sqlite3/sqlite3.dart';

/// Guid inserted with no card row. T-R1 asks whether an empty search sees it.
const cardlessGuid = 'cardless-note-for-search';

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    await initRslibBridge();
  });

  test('T-R1 empty search against a real collection', () async {
    final root = Directory('/tmp').createTempSync('hatto-tr1');
    addTearDown(() {
      if (root.existsSync()) {
        root.deleteSync(recursive: true);
      }
    });
    final tmp = Directory(p.join(root.path, 'tmp'))..createSync();
    prepareRuntime(tmpDir: tmp.path);
    final dataDir = Directory(p.join(root.path, 'collection'))..createSync();
    await _seedBasicNote(dataDir);
    _insertCardlessNote(p.join(dataDir.path, 'collection.anki2'));

    final host = EngineHost();
    addTearDown(host.close);
    await host.open(dataDir: dataDir.path);
    final api = RslibAnkiApi(host.flow!);
    final ids = await api.searchNoteIds();
    final notes = [for (final id in ids) await api.getNote(id)];
    final guids = notes.map((note) => note.guid).toSet();
    // BuildSearchString("") is deck:*, which joins through cards.
    expect(guids, isNot(contains(cardlessGuid)));
    expect(notes, isNotEmpty);
    final starred = await host.flow!.searchNotes('note:*');
    final starredGuids = <String>{
      for (final id in starred) (await api.getNote(id)).guid,
    };
    expect(starredGuids, contains(cardlessGuid));
    final decks = await api.deckTree();
    expect(decks.map((deck) => deck.name), contains('Default'));
    final live = notes.single;
    final cards = await api.cardsOfNote(live.id);
    expect(cards, isNotEmpty);
    final card = await api.getCard(cards.first.id);
    expect(card.deckId, isNonZero);
  });

  test('T-R2 add and update leave the note with a card', () async {
    final root = Directory('/tmp').createTempSync('hatto-tr2');
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
        collectionPath: p.join(dataDir.path, 'collection.anki2'),
        mediaFolderPath: media.path,
        mediaDbPath: p.join(dataDir.path, 'collection.media.db'),
      ),
    );
    final notetype = NotetypeId.fromBuffer(
      await invoke(
        'BackendNotetypesService',
        'get_notetype_id_by_name',
        g.String(val: 'Basic'),
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
    Future<int> cardCount() async {
      final cards = CardIds.fromBuffer(
        await invoke(
          'BackendNotesService',
          'cards_of_note',
          NoteId(nid: added.noteId),
        ),
      );
      return cards.cids.length;
    }

    expect(await cardCount(), greaterThan(0));
    final stored = Note.fromBuffer(
      await invoke(
        'BackendNotesService',
        'get_note',
        NoteId(nid: added.noteId),
      ),
    );
    stored.fields[0] = 'changed';
    await invoke(
      'BackendNotesService',
      'update_notes',
      UpdateNotesRequest(notes: [stored], skipUndoEntry: false),
    );
    expect(await cardCount(), greaterThan(0));
    await invoke(
      'BackendCollectionService',
      'close_collection',
      CloseCollectionRequest(),
    );
  });

  // Observed against rslib 26.09.3: AddNote of a Basic note whose fields are
  // both empty succeeds, creates exactly one card, and stores a non-empty
  // guid. I1 covers notes that have at least one card, so this note is in
  // scope. The call is not rejected and it does not leave a cardless note.
  // This backend is the unrestricted profile; the desktop allowlist still
  // leaves AddNote pending.
  test('T-R2 empty fields are accepted and the note has one card', () async {
    final root = Directory('/tmp').createTempSync('hatto-tr2-empty');
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
    final backend = await openBackend(initMsg: encodeBackendInit());
    Future<ProtoResponse> call(
      String service,
      String method,
      GeneratedMessage req,
    ) async {
      final index = serviceMethodIndex(service: service, method: method);
      if (index == null) {
        throw StateError('no index for $service.$method');
      }
      return command(
        backend: backend,
        service: index.service,
        method: index.method,
        input: req.writeToBuffer(),
      );
    }

    final opened = await call(
      'BackendCollectionService',
      'open_collection',
      OpenCollectionRequest(
        collectionPath: p.join(dataDir.path, 'collection.anki2'),
        mediaFolderPath: media.path,
        mediaDbPath: p.join(dataDir.path, 'collection.media.db'),
      ),
    );
    expect(opened.success, isTrue);
    final notetype = NotetypeId.fromBuffer(
      (await call(
        'BackendNotetypesService',
        'get_notetype_id_by_name',
        g.String(val: 'Basic'),
      )).payload,
    );
    final fresh = Note.fromBuffer(
      (await call('BackendNotesService', 'new_note', notetype)).payload,
    );
    fresh.fields
      ..clear()
      ..addAll(['', '']);
    final added = await call(
      'BackendNotesService',
      'add_note',
      AddNoteRequest(note: fresh, deckId: Int64(1)),
    );
    expect(added.success, isTrue);
    final noteId = AddNoteResponse.fromBuffer(added.payload).noteId;
    final cards = CardIds.fromBuffer(
      (await call(
        'BackendNotesService',
        'cards_of_note',
        NoteId(nid: noteId),
      )).payload,
    );
    expect(cards.cids, hasLength(1));
    final stored = Note.fromBuffer(
      (await call(
        'BackendNotesService',
        'get_note',
        NoteId(nid: noteId),
      )).payload,
    );
    expect(stored.guid, isNotEmpty);
    expect(stored.fields, ['', '']);
    await call(
      'BackendCollectionService',
      'close_collection',
      CloseCollectionRequest(),
    );
  });
}

Future<void> _seedBasicNote(Directory dir) async {
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
      throw StateError('$service.$method failed while seeding');
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
      g.String(val: 'Basic'),
    ),
  );
  final note = Note.fromBuffer(
    await invoke('BackendNotesService', 'new_note', notetype),
  );
  note.fields
    ..clear()
    ..addAll(['front', 'back']);
  await invoke(
    'BackendNotesService',
    'add_note',
    AddNoteRequest(note: note, deckId: Int64(1)),
  );
  await invoke(
    'BackendCollectionService',
    'close_collection',
    CloseCollectionRequest(),
  );
}

void _insertCardlessNote(String collectionPath) {
  final db = sqlite3.open(collectionPath);
  try {
    db.execute(
      '''
      INSERT INTO notes (id, guid, mid, mod, usn, tags, flds, sfld, csum, flags, data)
      SELECT 999001, ?, mid, mod, -1, tags, flds, sfld, csum, flags, data
      FROM notes
      LIMIT 1
      ''',
      [cardlessGuid],
    );
  } finally {
    db.close();
  }
}
