// SPDX-FileCopyrightText: 2026 Hatto Social contributors
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:hatto_store/hatto_store.dart';
import 'package:test/test.dart';

void main() {
  test('notesByGuids is one SELECT and omits missing guids', () {
    final db = SideDb.openInMemory();
    addTearDown(db.close);
    db.putDeck(deckGuid: 'deck-a', rslibDeckId: 1);
    db.importNote(
      noteGuid: 'a',
      rslibNoteId: 10,
      cards: const [ImportedNoteCard(ord: 0, rslibDeckId: 1)],
    );
    db.importNote(
      noteGuid: 'b',
      rslibNoteId: 11,
      cards: const [ImportedNoteCard(ord: 0, rslibDeckId: 1)],
    );

    expect(db.notesByGuids(const []), isEmpty);
    expect(db.notesByGuidsSelects, 0);

    final before = db.notesByGuidsSelects;
    final found = db.notesByGuids(['missing', 'b', 'a', 'b']);
    expect(db.notesByGuidsSelects - before, 1);
    expect(found.keys.toSet(), {'a', 'b'});
    expect(found.containsKey('missing'), isFalse);
    expect(found['a']!.rslibNoteId, 10);
    expect(found['b']!.rslibNoteId, 11);
    expect(found['b']!.homeDeckGuid, 'deck-a');
    expect(db.note('a')!.rslibNoteId, 10);
    expect(db.note('missing'), isNull);

    final many = [
      for (var i = 0; i < SideDb.notesByGuidsChunk + 1; i++) 'none-$i',
    ];
    final beforeChunk = db.notesByGuidsSelects;
    expect(db.notesByGuids(many), isEmpty);
    expect(db.notesByGuidsSelects - beforeChunk, 2);
  });
}
