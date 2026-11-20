// SPDX-FileCopyrightText: 2026 Hatto Social contributors
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:convert';

import 'package:hatto_store/hatto_store.dart';
import 'package:test/test.dart';

import 'fake_collection.dart';

void main() {
  test('adoptDeck and adoptNote are idempotent', () async {
    final db = SideDb.openInMemory();
    addTearDown(db.close);
    final collection = FakeCollection()
      ..addNote(id: 10, guid: 'note-guid', cardId: 100, deckId: 1);
    final firstDeck = await adoptDeck(db: db, anki: collection, rslibDeckId: 1);
    final secondDeck = await ensureDeckMapped(
      db: db,
      anki: collection,
      rslibDeckId: 1,
    );
    expect(secondDeck.deckGuid, firstDeck.deckGuid);
    expect(secondDeck.originKind, 'editor');
    expect(db.decks(), hasLength(1));

    final firstNote = await adoptNote(
      db: db,
      anki: collection,
      rslibNoteId: 10,
    );
    expect(firstNote.noteGuid, 'note-guid');
    expect(firstNote.homeDeckGuid, firstDeck.deckGuid);

    collection.cards[100] = const CollectionCard(id: 100, deckId: 5, odid: 0);
    collection.decks = const [
      CollectionDeck(id: 1, name: 'Default'),
      CollectionDeck(id: 5, name: 'Moved'),
    ];
    final again = await adoptNote(db: db, anki: collection, rslibNoteId: 10);
    expect(again.homeDeckGuid, firstNote.homeDeckGuid);
    expect(again.noteGuid, 'note-guid');
  });

  test('a filtered card homes on odid', () async {
    final db = SideDb.openInMemory();
    addTearDown(db.close);
    final collection = FakeCollection()
      ..decks = const [
        CollectionDeck(id: 1, name: 'Default'),
        CollectionDeck(id: 5, name: 'Languages'),
        CollectionDeck(id: 9, name: 'Filtered'),
      ]
      ..addNote(id: 10, guid: 'filtered-note', cardId: 100, deckId: 9, odid: 5);
    final row = await adoptNote(db: db, anki: collection, rslibNoteId: 10);
    expect(row.homeDeckGuid, db.deckByRslibId(5)!.deckGuid);
    expect(row.homeDeckGuid, isNot(db.deckByRslibId(9)!.deckGuid));
  });

  test('running reconcile twice leaves the same rows', () async {
    final db = SideDb.openInMemory();
    addTearDown(db.close);
    db.putDeck(deckGuid: 'kept-default', rslibDeckId: 1, originKind: 'apkg');
    db.importNote(
      noteGuid: 'already',
      rslibNoteId: 2,
      cards: const [ImportedNoteCard(ord: 0, rslibDeckId: 1)],
    );
    db.putDeck(deckGuid: 'stale-deck', rslibDeckId: 50);
    // The stale note id is not in the collection. Its home deck is.
    db.importNote(
      noteGuid: 'stale-note',
      rslibNoteId: 99,
      cards: const [ImportedNoteCard(ord: 0, rslibDeckId: 1)],
    );
    db.importNote(
      noteGuid: 'old-guid',
      rslibNoteId: 4,
      cards: const [ImportedNoteCard(ord: 0, rslibDeckId: 1)],
    );

    final collection = FakeCollection()
      ..decks = const [
        CollectionDeck(id: 1, name: 'Default'),
        CollectionDeck(id: 2, name: 'A'),
        CollectionDeck(id: 3, name: 'A::B'),
      ]
      ..addNote(id: 2, guid: 'already', cardId: 20)
      ..addNote(id: 4, guid: 'new-guid', cardId: 40)
      ..addNote(id: 7, guid: 'fresh-guid', cardId: 70, deckId: 3);

    db.beginIntent(
      op: intentDeckAdd,
      targetKey: 'fixed-deck-guid',
      expected: jsonEncode({
        'v': 0,
        'op_id': 'op-deck',
        'deck_guid': 'fixed-deck-guid',
        'name': 'A::B',
      }),
    );
    db.beginIntent(
      op: intentDeckAdd,
      targetKey: 'missing-deck',
      expected: jsonEncode({
        'v': 0,
        'op_id': 'op-missing',
        'deck_guid': 'missing-deck',
        'name': 'No::Such',
      }),
    );
    db.beginIntent(
      op: intentNoteAdd,
      targetKey: 'fresh-guid',
      expected: jsonEncode({
        'v': 0,
        'op_id': 'op-note',
        'guid': 'fresh-guid',
        'deck_id': 3,
      }),
    );
    db.beginIntent(
      op: intentNoteAdd,
      targetKey: 'never-created',
      expected: jsonEncode({
        'v': 0,
        'op_id': 'op-absent',
        'guid': 'never-created',
        'deck_id': 1,
      }),
    );
    db.beginIntent(
      op: intentNoteUpdate,
      targetKey: 'already',
      expected: '{"v":0,"note_id":2}',
    );
    db.beginIntent(
      op: intentMediaAdd,
      targetKey: 'paste.png',
      expected: '{"v":0,"size":4}',
    );
    db.beginIntent(op: intentUndo, targetKey: 'col', expected: '{"v":0}');
    db.beginIntent(
      op: intentDeckRename,
      targetKey: 'kept-default',
      expected: '{"v":0,"deck_id":1,"new_name":"Renamed"}',
    );
    db.beginIntent(op: 'not.a.real.op', targetKey: 'x', expected: '{"v":0}');
    db.beginIntent(op: intentNoteAdd, targetKey: 'bad', expected: 'not-json');

    await reconcileCollection(db: db, anki: collection);
    final once = _snapshot(db);
    await reconcileCollection(db: db, anki: collection);
    expect(_snapshot(db), once);

    expect(db.deckByRslibId(1)!.deckGuid, 'kept-default');
    expect(db.deckByRslibId(1)!.originKind, 'apkg');
    expect(db.deckByRslibId(3)!.deckGuid, 'fixed-deck-guid');
    expect(db.deckByRslibId(3)!.originKind, 'editor');
    expect(db.deckByRslibId(3)!.serverUnsynced, isTrue);
    expect(db.deckByRslibId(2)!.deckGuid, matches(uuidVersion4Or5));
    expect(db.deckByRslibId(2)!.deckGuid, isNot('fixed-deck-guid'));
    expect(db.note('fresh-guid')!.rslibNoteId, 7);
    expect(db.note('fresh-guid')!.homeDeckGuid, 'fixed-deck-guid');
    expect(db.note('new-guid')!.rslibNoteId, 4);
    expect(db.note('old-guid'), isNull);
    expect(db.note('already')!.homeDeckGuid, 'kept-default');
    expect(db.noteByRslibId(99)!.noteGuid, 'stale-note');
    expect(db.deckByRslibId(50)!.deckGuid, 'stale-deck');

    final pending = db.pendingIntents();
    expect(pending.map((row) => row.op), [
      intentDeckRename,
      'not.a.real.op',
      intentNoteAdd,
    ]);
    expect(pending.last.expected, 'not-json');
    expect(db.journalRows(), isEmpty);
  });

  test('a note with no cards is recorded and does not abort reconcile', () async {
    final db = SideDb.openInMemory();
    addTearDown(db.close);
    final collection = FakeCollection()
      ..addNote(id: 10, guid: 'has-cards', cardId: 100);
    collection.notes[11] = const CollectionNote(id: 11, guid: 'lonely');

    final result = await reconcileCollection(db: db, anki: collection);
    expect(result.skippedNotes, hasLength(1));
    expect(result.skippedNotes.single.rslibNoteId, 11);
    expect(result.skippedNotes.single.reason, 'no cards');
    expect(db.note('has-cards'), isNotNull);
    expect(db.note('lonely'), isNull);
    expect(db.deckByRslibId(1), isNotNull);

    final only = FakeCollection();
    only.notes[11] = const CollectionNote(id: 11, guid: 'lonely');
    final alone = SideDb.openInMemory();
    addTearDown(alone.close);
    final skipped = await reconcileCollection(db: alone, anki: only);
    expect(skipped.skippedNotes.single.rslibNoteId, 11);
    expect(alone.notes(), isEmpty);
  });
}

String _snapshot(SideDb db) {
  final notes = [
    for (final row in db.notes())
      '${row.rslibNoteId}:${row.noteGuid}:${row.homeDeckGuid}',
  ].join('|');
  final decks = [
    for (final row in db.decks())
      '${row.rslibDeckId}:${row.deckGuid}:${row.originKind}:${row.serverUnsynced}',
  ].join('|');
  final intents = [
    for (final row in db.pendingIntents())
      '${row.id}:${row.op}:${row.targetKey}:${row.expected}',
  ].join('|');
  return '$notes#$decks#$intents';
}
