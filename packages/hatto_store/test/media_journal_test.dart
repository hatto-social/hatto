// SPDX-FileCopyrightText: 2026 Hatto Social contributors
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:convert';
import 'dart:typed_data';

import 'package:hatto_store/hatto_store.dart';
import 'package:test/test.dart';

void main() {
  test('media.add journals filename, size, and sha1, not the bytes', () async {
    final db = SideDb.openInMemory();
    addTearDown(db.close);
    final bytes = Uint8List.fromList(List<int>.filled(256, 0xab));
    final media = MediaJournal.of(filename: 'paste-name.png', bytes: bytes);
    final wrapper = WriteWrapper(
      db: db,
      command: (_, _, input) async {
        expect(input, bytes);
        return ProtoResponse(
          success: true,
          payload: Uint8List.fromList(utf8.encode('paste-name.png')),
        );
      },
    );
    await wrapper.run(
      op: intentMediaAdd,
      entityKind: 'media',
      guid: 'paste-name.png',
      service: 8,
      method: 1,
      input: bytes,
      media: media,
    );
    final payload = db.journalRows().single.payload!;
    expect(payload.length < bytes.length, isTrue);
    expect(payload, isNot(contains(0xab)));
    final decoded = jsonDecode(utf8.decode(payload)) as Map<String, Object?>;
    expect(decoded['v'], 0);
    expect(decoded['filename'], 'paste-name.png');
    expect(decoded['size'], bytes.length);
    expect(decoded['sha1'], media.sha1);
    expect(media.sha1, hasLength(40));
  });

  test(
    'media.add without metadata is refused before an intent is written',
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
      );
      await expectLater(
        wrapper.run(
          op: intentMediaAdd,
          entityKind: 'media',
          guid: 'x',
          service: 0,
          method: 0,
          input: Uint8List.fromList([1, 2, 3]),
        ),
        throwsA(isA<SideDbException>()),
      );
      expect(calls, 0);
      expect(db.pendingIntentCount(), 0);
      expect(db.journalRows(), isEmpty);
    },
  );

  test(
    'journal false still refuses a media.add that has no metadata',
    () async {
      final db = SideDb.openInMemory();
      addTearDown(db.close);
      final wrapper = WriteWrapper(
        db: db,
        command: (_, _, _) async => ProtoResponse.emptyOk,
      );
      await expectLater(
        wrapper.run(
          op: intentMediaAdd,
          entityKind: 'media',
          guid: 'x',
          service: 0,
          method: 0,
          input: Uint8List(0),
          journal: false,
        ),
        throwsA(isA<SideDbException>()),
      );
      expect(db.journalRows(), isEmpty);
    },
  );
}
