// SPDX-FileCopyrightText: 2026 Hatto Social contributors
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:hatto_store/hatto_store.dart';
import 'package:test/test.dart';

import 'fake_collection.dart';

void main() {
  const guid = '11111111-1111-4111-8111-111111111111';

  test('a write and reconcile do not run at the same time', () async {
    final db = SideDb.openInMemory();
    addTearDown(db.close);
    final collection = FakeCollection();
    final hold = Completer<void>();
    var writing = false;
    var reconcileEntered = false;
    final wrapper = WriteWrapper(
      db: db,
      command: (service, method, input) async {
        writing = true;
        await hold.future;
        writing = false;
        collection.addNote(id: 7, guid: guid, cardId: 70);
        return ProtoResponse.emptyOk;
      },
    );
    final write = wrapper.run(
      op: intentNoteAdd,
      entityKind: 'note',
      guid: guid,
      service: 1,
      method: 1,
      input: Uint8List(0),
      expected: jsonEncode({'v': 0, 'guid': guid}),
      journal: false,
    );
    while (!writing) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    final reconcile = reconcileCollection(
      db: db,
      anki: _Probe(collection, () => reconcileEntered = true),
    );
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(reconcileEntered, isFalse);
    expect(writing, isTrue);
    hold.complete();
    await write;
    await reconcile;
    expect(reconcileEntered, isTrue);
    expect(db.note(guid)!.rslibNoteId, 7);
  });

  test('reconcile inside a write throws instead of deadlocking', () async {
    final db = SideDb.openInMemory();
    addTearDown(db.close);
    final collection = FakeCollection();
    final wrapper = WriteWrapper(
      db: db,
      command: (service, method, input) async {
        await reconcileCollection(db: db, anki: collection);
        return ProtoResponse.emptyOk;
      },
    );
    await expectLater(
      wrapper
          .run(
            op: intentNoteAdd,
            entityKind: 'note',
            guid: guid,
            service: 1,
            method: 1,
            input: Uint8List(0),
            journal: false,
          )
          .timeout(const Duration(seconds: 2)),
      throwsA(isA<StateError>()),
    );
  });
}

class _Probe implements AnkiApi {
  _Probe(this.inner, this.onSearch);

  final FakeCollection inner;
  final void Function() onSearch;

  @override
  Future<List<int>> searchNoteIds() async {
    onSearch();
    return inner.searchNoteIds();
  }

  @override
  Future<CollectionNote> getNote(int id) => inner.getNote(id);

  @override
  Future<List<CollectionCardRef>> cardsOfNote(int noteId) =>
      inner.cardsOfNote(noteId);

  @override
  Future<CollectionCard> getCard(int cardId) => inner.getCard(cardId);

  @override
  Future<List<CollectionDeck>> deckTree() => inner.deckTree();
}
