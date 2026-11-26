// SPDX-FileCopyrightText: 2026 Hatto Social contributors
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:convert';

import 'package:hatto_store/hatto_store.dart';
import 'package:test/test.dart';

void main() {
  const source =
      '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';
  const staged =
      'fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210';
  const hashA =
      'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
  const hashB =
      'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
  const preA =
      'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc';
  const preB =
      'dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd';

  ImportIntentExpected sample({
    Map<String, String>? changed,
    Map<String, String>? preChanged,
    int noteCount = 2,
  }) {
    final changedMap = changed ?? {'guid-b': hashB, 'guid-a': hashA};
    return ImportIntentExpected(
      sourceSha256: source,
      stagedSha256: staged,
      firstImport: false,
      newGuids: const ['new-b', 'new-a'],
      changed: changedMap,
      deckNames: const ['Spanish', 'Old'],
      pre: ImportIntentPre(
        noteCount: noteCount,
        changed: preChanged ?? {'guid-b': preB, 'guid-a': preA},
      ),
    );
  }

  test('round trip keeps values and sorts hash keys', () {
    final original = sample();
    final encoded = encodeImportIntentExpected(original);
    final decoded = decodeImportIntentExpected(encoded);

    expect(decoded, original);
    expect(encodeImportIntentExpected(decoded), encoded);
    expect(decoded.changed.keys.toList(), ['guid-a', 'guid-b']);
    expect(decoded.pre.changed.keys.toList(), ['guid-a', 'guid-b']);
    expect(decoded.newGuids, ['new-b', 'new-a']);
    expect(decoded.pre.noteCount, 2);
    expect(decoded.firstImport, isFalse);
  });

  test('encoding is byte-for-byte identical when hash keys are reordered', () {
    final first = encodeImportIntentExpected(sample());
    final second = encodeImportIntentExpected(
      sample(
        changed: const {'guid-a': hashA, 'guid-b': hashB},
        preChanged: const {'guid-a': preA, 'guid-b': preB},
      ),
    );

    expect(utf8.encode(first), utf8.encode(second));
    var last = -1;
    for (final key in [
      'source_sha256',
      'staged_sha256',
      'first_import',
      'new_guids',
      'changed',
      'deck_names',
      'pre',
    ]) {
      final at = first.indexOf('"$key"');
      expect(at, greaterThan(last), reason: key);
      last = at;
    }
    final preAt = first.indexOf('"pre"');
    final preBody = first.substring(preAt);
    expect(
      preBody.indexOf('"note_count"'),
      lessThan(preBody.indexOf('"changed"')),
    );
    expect(first.indexOf('"guid-a"'), lessThan(first.indexOf('"guid-b"')));
  });

  test('uppercase hex is rejected', () {
    expect(
      () => ImportIntentExpected(
        sourceSha256: source.replaceRange(0, 1, 'A'),
        stagedSha256: staged,
        firstImport: true,
        newGuids: const [],
        changed: const {},
        deckNames: const [],
        pre: ImportIntentPre(noteCount: 0, changed: const {}),
      ),
      throwsA(isA<SideDbException>()),
    );
    final encoded = encodeImportIntentExpected(
      ImportIntentExpected(
        sourceSha256: source,
        stagedSha256: staged,
        firstImport: true,
        newGuids: const [],
        changed: const {},
        deckNames: const [],
        pre: ImportIntentPre(noteCount: 0, changed: const {}),
      ),
    );
    final upper = encoded.replaceFirst(staged, staged.replaceRange(0, 2, 'FE'));
    expect(
      () => decodeImportIntentExpected(upper),
      throwsA(isA<SideDbException>()),
    );
  });

  test('wrong hex length is rejected', () {
    expect(
      () => decodeImportIntentExpected(
        encodeImportIntentExpected(
          ImportIntentExpected(
            sourceSha256: source,
            stagedSha256: staged,
            firstImport: true,
            newGuids: const ['n'],
            changed: const {'g': hashA},
            deckNames: const ['Spanish'],
            pre: ImportIntentPre(noteCount: 1, changed: const {'g': preA}),
          ),
        ).replaceFirst(hashA, 'a' * 63),
      ),
      throwsA(isA<SideDbException>()),
    );
    expect(
      () => decodeImportIntentExpected(
        '{"source_sha256":"${'ab' * 32}","staged_sha256":"${'a' * 65}",'
        '"first_import":true,"new_guids":[],"changed":{},"deck_names":[],'
        '"pre":{"note_count":0,"changed":{}}}',
      ),
      throwsA(isA<SideDbException>()),
    );
  });

  test('pre.changed key set must match changed', () {
    expect(
      () => ImportIntentExpected(
        sourceSha256: source,
        stagedSha256: staged,
        firstImport: true,
        newGuids: const [],
        changed: const {'guid-a': hashA},
        deckNames: const [],
        pre: ImportIntentPre(noteCount: 0, changed: const {'guid-b': preB}),
      ),
      throwsA(isA<SideDbException>()),
    );
    final encoded = encodeImportIntentExpected(
      ImportIntentExpected(
        sourceSha256: source,
        stagedSha256: staged,
        firstImport: true,
        newGuids: const [],
        changed: const {'guid-a': hashA, 'guid-b': hashB},
        deckNames: const [],
        pre: ImportIntentPre(
          noteCount: 4,
          changed: const {'guid-a': preA, 'guid-b': preB},
        ),
      ),
    );
    final dropped = encoded
        .replaceFirst('"$preB"', '"$preB"')
        .replaceFirst('"guid-b":"$preB"', '"guid-c":"$preB"');
    expect(
      () => decodeImportIntentExpected(dropped),
      throwsA(isA<SideDbException>()),
    );
  });

  test('pre.note_count is a non-negative 64-bit integer', () {
    expect(
      () => ImportIntentPre(noteCount: -1, changed: const {}),
      throwsA(isA<SideDbException>()),
    );
    const maxSigned = 9223372036854775807;
    final high = ImportIntentPre(noteCount: maxSigned, changed: const {});
    expect(high.noteCount, maxSigned);
    final encoded = encodeImportIntentExpected(
      ImportIntentExpected(
        sourceSha256: source,
        stagedSha256: staged,
        firstImport: true,
        newGuids: const [],
        changed: const {},
        deckNames: const [],
        pre: high,
      ),
    );
    expect(decodeImportIntentExpected(encoded).pre.noteCount, maxSigned);
    expect(
      () => decodeImportIntentExpected(
        '{"source_sha256":"$source","staged_sha256":"$staged",'
        '"first_import":true,"new_guids":[],"changed":{},"deck_names":[],'
        '"pre":{"note_count":-1,"changed":{}}}',
      ),
      throwsA(isA<SideDbException>()),
    );
    expect(
      () => decodeImportIntentExpected(
        '{"source_sha256":"$source","staged_sha256":"$staged",'
        '"first_import":true,"new_guids":[],"changed":{},"deck_names":[],'
        '"pre":{"note_count":1.0,"changed":{}}}',
      ),
      throwsA(isA<SideDbException>()),
    );
    expect(
      () => decodeImportIntentExpected(
        '{"source_sha256":"$source","staged_sha256":"$staged",'
        '"first_import":true,"new_guids":[],"changed":{},"deck_names":[],'
        '"pre":{"note_count":9223372036854775808,"changed":{}}}',
      ),
      throwsA(isA<SideDbException>()),
    );
  });

  test('unknown fields are rejected', () {
    final encoded = encodeImportIntentExpected(
      ImportIntentExpected(
        sourceSha256: source,
        stagedSha256: staged,
        firstImport: true,
        newGuids: const [],
        changed: const {},
        deckNames: const [],
        pre: ImportIntentPre(noteCount: 0, changed: const {}),
      ),
    );
    final withVersion = encoded.replaceFirst('{', '{"v":0,');
    expect(
      () => decodeImportIntentExpected(withVersion),
      throwsA(isA<SideDbException>()),
    );
    expect(tryDecodeImportIntentExpected(withVersion), isNull);
    expect(tryDecodeImportIntentExpected('not-json'), isNull);
    expect(tryDecodeImportIntentExpected(null), isNull);
  });
}
