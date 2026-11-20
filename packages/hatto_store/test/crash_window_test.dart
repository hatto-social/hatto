// SPDX-FileCopyrightText: 2026 Hatto Social contributors
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:convert';
import 'dart:typed_data';

import 'package:hatto_store/hatto_store.dart';
import 'package:test/test.dart';

import 'fake_collection.dart';

void main() {
  const guid = '11111111-1111-4111-8111-111111111111';

  test(
    'C1: crash after the intent and before rslib drops the intent',
    () async {
      final db = SideDb.openInMemory();
      addTearDown(db.close);
      final collection = FakeCollection();
      final wrapper = WriteWrapper(
        db: db,
        command: (service, method, input) async {
          collection.addNote(id: 7, guid: guid, cardId: 70);
          return ProtoResponse.emptyOk;
        },
        fault: (phase) {
          if (phase == WritePhase.afterIntent) {
            throw StateError('C1');
          }
        },
      );
      await expectLater(_add(wrapper, guid), throwsStateError);
      expect(collection.notes, isEmpty);
      expect(db.notes(), isEmpty);
      expect(db.pendingIntentCount(), 1);

      await reconcileCollection(db: db, anki: collection);
      expect(db.pendingIntentCount(), 0);
      expect(db.notes(), isEmpty);
      expect(db.deckByRslibId(1), isNotNull);
    },
  );

  test('C2: crash between the rslib commit and the side database commit is adopted', () async {
    final db = SideDb.openInMemory();
    addTearDown(db.close);
    final collection = FakeCollection();
    final wrapper = WriteWrapper(
      db: db,
      command: (service, method, input) async {
        collection.addNote(id: 7, guid: guid, cardId: 70);
        return ProtoResponse.emptyOk;
      },
      fault: (phase) {
        if (phase == WritePhase.afterRslibCommit) {
          throw StateError('C2');
        }
      },
    );
    await expectLater(_add(wrapper, guid), throwsStateError);
    expect(collection.notes.containsKey(7), isTrue);
    expect(db.notes(), isEmpty);
    expect(db.pendingIntents().single.op, intentNoteAdd);
    expect(db.journalRows(), isEmpty);

    await reconcileCollection(db: db, anki: collection);
    expect(db.note(guid)!.rslibNoteId, 7);
    expect(db.note(guid)!.homeDeckGuid, db.deckByRslibId(1)!.deckGuid);
    expect(db.pendingIntentCount(), 0);

    final again = _snapshot(db);
    await reconcileCollection(db: db, anki: collection);
    expect(_snapshot(db), again);
  });

  test('C3: a crash inside the side transaction ends like C2', () async {
    final db = SideDb.openInMemory();
    addTearDown(db.close);
    final collection = FakeCollection();
    final wrapper = WriteWrapper(
      db: db,
      command: (service, method, input) async {
        collection.addNote(id: 7, guid: guid, cardId: 70);
        return ProtoResponse.emptyOk;
      },
      fault: (phase) {
        if (phase == WritePhase.duringSideCommit) {
          throw StateError('C3');
        }
      },
    );
    await expectLater(
      wrapper.run(
        op: intentNoteAdd,
        entityKind: 'note',
        guid: guid,
        service: 1,
        method: 1,
        input: Uint8List(0),
        expected: jsonEncode({
          'v': 0,
          'op_id': 'op',
          'guid': guid,
          'deck_id': 1,
        }),
        journal: false,
        map: (_) {
          db.putDeck(deckGuid: 'partial', rslibDeckId: 42);
        },
      ),
      throwsStateError,
    );
    expect(collection.notes.containsKey(7), isTrue);
    expect(db.deck('partial'), isNull);
    expect(db.notes(), isEmpty);
    expect(db.pendingIntentCount(), 1);

    await reconcileCollection(db: db, anki: collection);
    expect(db.note(guid)!.rslibNoteId, 7);
    expect(db.deck('partial'), isNull);
    expect(db.pendingIntentCount(), 0);
  });
}

Future<void> _add(WriteWrapper wrapper, String guid) {
  return wrapper.run(
    op: intentNoteAdd,
    entityKind: 'note',
    guid: guid,
    service: 1,
    method: 1,
    input: Uint8List(0),
    expected: jsonEncode({'v': 0, 'op_id': 'op', 'guid': guid, 'deck_id': 1}),
    journal: false,
  );
}

String _snapshot(SideDb db) {
  return [
    for (final row in db.notes()) '${row.rslibNoteId}:${row.noteGuid}',
    for (final row in db.decks()) '${row.rslibDeckId}:${row.deckGuid}',
  ].join('|');
}
