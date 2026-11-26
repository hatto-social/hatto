// SPDX-FileCopyrightText: 2026 Hatto Social contributors
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hatto_mobile/store/pb.dart';

void main() {
  test('package import options use IF_NEWER and NEVER', () {
    final withConfigs = encodeResidentPackageImport(
      packagePath: 'a.apkg',
      withDeckConfigs: true,
    );
    final options = _field(withConfigs, 2);
    expect(options, isNotNull);
    // update_notes is IF_NEWER (0) and is omitted. update_notetypes is
    // NEVER (2). with_scheduling and with_deck_configs are true.
    expect(_varint(options!, 2), isNull);
    expect(_varint(options, 3), packageUpdateNever);
    expect(_varint(options, 4), 1);
    expect(_varint(options, 5), 1);
    expect(packageUpdateIfNewer, 0);
    expect(packageUpdateNever, 2);

    final without = encodeResidentPackageImport(
      packagePath: 'a.apkg',
      withDeckConfigs: false,
    );
    final bare = _field(without, 2)!;
    expect(_varint(bare, 5), isNull);
    expect(_varint(bare, 3), packageUpdateNever);
  });

  test('import log new notes expose id.nid in order', () {
    final first = PbWriter()..int64Field(1, 7);
    final firstNote = PbWriter()..bytesField(1, first.takeBytes());
    final second = PbWriter()..int64Field(1, 9);
    final secondNote = PbWriter()..bytesField(1, second.takeBytes());
    final skipped = PbWriter()..stringField(2, 'no-id');
    final log = PbWriter()
      ..bytesField(1, firstNote.takeBytes())
      ..bytesField(1, skipped.takeBytes())
      ..bytesField(1, secondNote.takeBytes());
    final response = PbWriter()..bytesField(2, log.takeBytes());

    expect(readImportedNewNoteIds(response.takeBytes()), [7, 9]);
  });

  test('notetype use_count is a uint32 sum', () {
    final basic = PbWriter()
      ..int64Field(1, 1)
      ..stringField(2, 'Basic')
      ..varintField(3, 4);
    final cloze = PbWriter()
      ..stringField(2, 'Cloze')
      ..varintField(3, 6);
    final message = PbWriter()
      ..bytesField(1, basic.takeBytes())
      ..bytesField(1, cloze.takeBytes());
    expect(readNotetypeUseCountSum(message.takeBytes()), 10);
  });

  test('deck id, note guid, card columns, and deck paths decode', () {
    final deckId = PbWriter()..int64Field(1, 42);
    expect(readInt64Field1(deckId.takeBytes()), 42);
    expect(readInt64Field1(Uint8List(0)), 0);

    final note = PbWriter()
      ..int64Field(1, 5)
      ..stringField(2, 'abc');
    expect(readNoteGuid(note.takeBytes()), 'abc');

    final card = PbWriter()
      ..int64Field(3, 11)
      ..varintField(4, 2)
      ..int64Field(16, 8);
    final columns = readCardColumns(card.takeBytes());
    expect(columns.deckId, 11);
    expect(columns.templateIdx, 2);
    expect(columns.originalDeckId, 8);
    final plain = readCardColumns(Uint8List(0));
    expect(plain.templateIdx, 0);
    expect(plain.originalDeckId, 0);

    final child = PbWriter()
      ..int64Field(1, 3)
      ..stringField(2, 'Parent::Child');
    final names = PbWriter()..bytesField(1, child.takeBytes());
    final parsed = readDeckNameEntries(names.takeBytes());
    expect(parsed.single.id, 3);
    expect(parsed.single.name, 'Parent::Child');
  });

  test('search ids are packed int64s and an empty search is written', () {
    final packed = PbWriter()..packedVarints(1, [4, 5]);
    expect(readInt64s(packed.takeBytes()), [4, 5]);

    final node = encodeParsableSearch('');
    expect(readStringField(node, number: 3), '');
    final request = encodeSearchRequest('deck:*');
    expect(readStringField(request), 'deck:*');

    final names = encodeDeckNamesRequest(includeFiltered: true);
    expect(_varint(names, 1), isNull);
    expect(_varint(names, 2), 1);
  });

  test('backend not-found kind is the Anki 26.09.3 value', () {
    final writer = PbWriter()
      ..stringField(1, 'missing')
      ..varintField(2, backendNotFoundKind);
    final error = readBackendError(writer.takeBytes());
    expect(error.message, 'missing');
    expect(error.kind, 11);
    expect(backendNotFoundKind, 11);
  });
}

Uint8List? _field(Uint8List message, int number) {
  for (final field in parseFields(message)) {
    if (field.number == number && field.wire == 2) {
      return field.bytes;
    }
  }
  return null;
}

int? _varint(Uint8List message, int number) {
  for (final field in parseFields(message)) {
    if (field.number == number && field.wire == 0) {
      return field.varintValue;
    }
  }
  return null;
}
