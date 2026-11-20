// SPDX-FileCopyrightText: 2026 Hatto Social contributors
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:io';

import 'package:fixnum/fixnum.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hatto_desktop/effect/engine_host.dart';
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
    // rslib 26.09.3 does not return a note that has no cards from an empty search.
    expect(guids, isNot(contains(cardlessGuid)));
    expect(notes, isNotEmpty);
    final decks = await api.deckTree();
    expect(decks.map((deck) => deck.name), contains('Default'));
    final live = notes.single;
    final cards = await api.cardsOfNote(live.id);
    expect(cards, isNotEmpty);
    final card = await api.getCard(cards.first.id);
    expect(card.deckId, isNonZero);
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
