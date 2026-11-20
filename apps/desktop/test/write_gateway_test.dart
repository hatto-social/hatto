// SPDX-FileCopyrightText: 2026 Hatto Social contributors
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hatto_desktop/store/write_gateway.dart';
import 'package:hatto_store/hatto_store.dart';

void main() {
  test('desktop writes do not append a journal row', () async {
    final db = SideDb.openInMemory();
    addTearDown(db.close);
    final gateway = WriteGateway(
      db: db,
      command: (_, _, _) async => ProtoResponse.emptyOk,
    );
    await gateway.run(
      op: intentNoteAdd,
      entityKind: 'note',
      guid: 'note-1',
      service: 1,
      method: 1,
      input: Uint8List.fromList([1, 2, 3]),
      map: (_) {
        db.putDeck(deckGuid: 'deck-1', rslibDeckId: 1, originKind: 'editor');
      },
    );
    expect(db.journalRows(), isEmpty);
    expect(db.pendingIntentCount(), 0);
    expect(db.deck('deck-1')!.originKind, 'editor');
  });
}
