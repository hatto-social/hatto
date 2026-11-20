// SPDX-FileCopyrightText: 2026 Hatto Social contributors
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:typed_data';

import 'package:hatto_store/hatto_store.dart';
import 'package:test/test.dart';

void main() {
  test(
    'journal defaults to true and the mapping callback sees the response',
    () async {
      final db = SideDb.openInMemory();
      addTearDown(db.close);
      final wrapper = WriteWrapper(
        db: db,
        command: (_, _, _) async =>
            ProtoResponse(success: true, payload: Uint8List.fromList([1, 2])),
      );
      await wrapper.run(
        op: 'update_note',
        entityKind: 'note',
        guid: 'note-guid',
        service: 1,
        method: 2,
        input: Uint8List.fromList([9]),
        expected: '{"v":0}',
        map: (response) {
          expect(response.payload, [1, 2]);
          expect(db.pendingIntentCount(), 1);
          db.putDeck(deckGuid: 'deck-1', rslibDeckId: 4);
        },
      );
      expect(db.pendingIntentCount(), 0);
      expect(db.deck('deck-1')!.rslibDeckId, 4);
      expect(db.journalRows().single.payload, Uint8List.fromList([9]));
      expect(db.pendingIntents(), isEmpty);
    },
  );

  test('journal false writes the mapping and no journal row', () async {
    final db = SideDb.openInMemory();
    addTearDown(db.close);
    final wrapper = WriteWrapper(
      db: db,
      command: (_, _, _) async => ProtoResponse.emptyOk,
    );
    await wrapper.run(
      op: 'note.add',
      entityKind: 'note',
      guid: 'g',
      service: 0,
      method: 0,
      input: Uint8List.fromList([7, 7, 7]),
      journal: false,
      map: (_) {
        db.putDeck(deckGuid: 'deck-1', rslibDeckId: 1);
      },
    );
    expect(db.journalRows(), isEmpty);
    expect(db.pendingIntentCount(), 0);
    expect(db.deck('deck-1'), isNotNull);
  });

  test(
    'a throw from the mapping callback rolls back and keeps the intent',
    () async {
      final db = SideDb.openInMemory();
      addTearDown(db.close);
      final wrapper = WriteWrapper(
        db: db,
        command: (_, _, _) async => ProtoResponse.emptyOk,
      );
      await expectLater(
        wrapper.run(
          op: 'note.add',
          entityKind: 'note',
          guid: 'g',
          service: 0,
          method: 0,
          input: Uint8List(0),
          map: (_) {
            db.putDeck(deckGuid: 'temp', rslibDeckId: 99);
            throw StateError('side commit failed');
          },
        ),
        throwsStateError,
      );
      expect(db.deck('temp'), isNull);
      expect(db.pendingIntentCount(), 1);
      expect(db.journalRows(), isEmpty);
    },
  );

  test(
    'a fault after the intent and before rslib does not call rslib',
    () async {
      final db = SideDb.openInMemory();
      addTearDown(db.close);
      var calls = 0;
      final wrapper = WriteWrapper(
        db: db,
        command: (_, _, _) async {
          calls += 1;
          return ProtoResponse.emptyOk;
        },
        fault: (phase) {
          if (phase == WritePhase.afterIntent) {
            throw StateError('crash before rslib');
          }
        },
      );
      await expectLater(
        wrapper.run(
          op: 'note.add',
          entityKind: 'note',
          guid: 'g',
          service: 0,
          method: 0,
          input: Uint8List(0),
        ),
        throwsStateError,
      );
      expect(calls, 0);
      expect(db.pendingIntentCount(), 1);
      expect(db.journalRows(), isEmpty);
    },
  );

  test('a fault between the rslib commit and the side database commit leaves the intent', () async {
    final db = SideDb.openInMemory();
    addTearDown(db.close);
    var calls = 0;
    var mapped = false;
    final wrapper = WriteWrapper(
      db: db,
      command: (_, _, _) async {
        calls += 1;
        return ProtoResponse.emptyOk;
      },
      fault: (phase) {
        if (phase == WritePhase.afterRslibCommit) {
          throw StateError('crash after rslib commit');
        }
      },
    );
    await expectLater(
      wrapper.run(
        op: 'note.add',
        entityKind: 'note',
        guid: 'g',
        service: 0,
        method: 0,
        input: Uint8List(0),
        map: (_) {
          mapped = true;
        },
      ),
      throwsStateError,
    );
    expect(calls, 1);
    expect(mapped, isFalse);
    expect(db.pendingIntentCount(), 1);
    expect(db.journalRows(), isEmpty);
  });

  test('a fault during the side transaction rolls back', () async {
    final db = SideDb.openInMemory();
    addTearDown(db.close);
    final wrapper = WriteWrapper(
      db: db,
      command: (_, _, _) async => ProtoResponse.emptyOk,
      fault: (phase) {
        if (phase == WritePhase.duringSideCommit) {
          throw StateError('crash during side commit');
        }
      },
    );
    await expectLater(
      wrapper.run(
        op: 'note.add',
        entityKind: 'note',
        guid: 'g',
        service: 0,
        method: 0,
        input: Uint8List(0),
        map: (_) {
          db.putDeck(deckGuid: 'temp', rslibDeckId: 3);
        },
      ),
      throwsStateError,
    );
    expect(db.deck('temp'), isNull);
    expect(db.pendingIntentCount(), 1);
    expect(db.journalRows(), isEmpty);
  });
}
