// SPDX-FileCopyrightText: 2026 Hatto Social contributors
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../integration_test/smoke_support.dart';

void main() {
  test('sha1 and uuid5 match the RFC and the host generator', () {
    final abc = sha1Bytes(utf8.encode('abc'));
    expect(
      abc.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join(),
      'a9993e364706816aba3e25717850c26c9cd0d89d',
    );
    expect(
      uuid5('6ba7b810-9dad-11d1-80b4-00c04fd430c8', 'python.org'),
      '886313e1-3b8a-5372-9b90-0c9aee199e5d',
    );
    final golden = jsonDecode(
      File(
        p.join(
          _repoRoot()!.path,
          'packages/hatto_card_contract/fixtures/note_guid_golden.json',
        ),
      ).readAsStringSync(),
    ) as Map<String, dynamic>;
    final jobs = (golden['smoke_jobs'] as Map<String, dynamic>).map(
      (key, value) => MapEntry(key, value as String),
    );
    expect(smokeJobIds, jobs);
    // The previous smoke namespace was uuid5(NAMESPACE_URL, 'smoke:job1')
    // = ade39d77-e71f-52e1-bdb9-4d405b7a656c, and uuid5 of that with
    // 'abc123' was 9468cc32-8cb3-58b6-aee2-726cfdd69331. The app rule is
    // uuid5(fixed job id, source guid).
    expect(
      uuid5(smokeJobId('job1'), 'abc123'),
      'a68db4fd-118d-5ad9-b151-638b9431e3a9',
    );
    for (final raw in golden['imported'] as List<dynamic>) {
      final item = raw as Map<String, dynamic>;
      if (item['error'] == 'empty_source_guid') {
        continue;
      }
      expect(
        uuid5(item['job_id'] as String, item['source_guid'] as String),
        item['expect'],
      );
    }
    for (final raw in golden['local'] as List<dynamic>) {
      final item = raw as Map<String, dynamic>;
      expect(
        uuid5(item['op_id'] as String, 'note:${item['k']}'),
        item['expect'],
      );
    }
  });

  test('note protobuf round-trips guid, empty field, and negative usn', () {
    final note = NoteView(
      id: 1700000000000,
      guid: 'original',
      notetypeId: 42,
      mtimeSecs: 1700000000,
      usn: -1,
      tags: const ['alpha'],
      fields: const ['front', ''],
    );
    final decoded = decodeNote(encodeNote(note));
    expect(decoded.id, note.id);
    expect(decoded.guid, note.guid);
    expect(decoded.notetypeId, note.notetypeId);
    expect(decoded.mtimeSecs, note.mtimeSecs);
    expect(decoded.usn, -1);
    expect(decoded.tags, note.tags);
    expect(decoded.fields, note.fields);
  });

  test('fsrs request is only num_of_relearning_steps=1', () {
    expect(computeFsrsRequest(), Uint8List.fromList(const [0x20, 0x01]));
  });

  test('fsrs response reads packed floats and fsrs_items', () {
    final data = ByteData(4)..setFloat32(0, 1e-6, Endian.little);
    final packed = data.buffer.asUint8List(
      data.offsetInBytes,
      data.lengthInBytes,
    );
    final message = PbWriter()
      ..bytesField(1, packed)
      ..varintField(2, 33312);
    final parsed = readFsrsResponse(message.takeBytes());
    expect(parsed.items, 33312);
    expect(parsed.params.single, data.getFloat32(0, Endian.little));
    // 1e-6 is inside (0, 100]. Count is judged separately from the range check.
    expect(fsrsValuesFinite([1e-6]), isTrue);
    expect(fsrsValuesFinite(const <double>[0]), isFalse);
    expect(fsrsValuesFinite(const <double>[100.1]), isFalse);
    expect(fsrsValuesFinite(const <double>[double.nan]), isFalse);
    expect(fsrsValuesFinite(List<double>.filled(21, 0.5)), isTrue);
  });

  test('import log counts new and duplicate notes', () {
    final log = PbWriter()
      ..bytesField(1, Uint8List(0))
      ..bytesField(1, Uint8List(0))
      ..bytesField(3, Uint8List(0));
    final response = PbWriter()..bytesField(2, log.takeBytes());
    final counts = readImportCounts(response.takeBytes());
    expect(counts.created, 2);
    expect(counts.duplicate, 1);
  });

  test('backend error text includes the message and kind', () {
    final writer = PbWriter()
      ..stringField(1, 'locked')
      ..varintField(2, 5);
    expect(describeBackendError(writer.takeBytes()), 'locked (kind=5)');
  });

  test('colpkg and notetype lines match the judge fixtures', () {
    expect(
      formatColLine(
        'collection_nomedia_new.colpkg',
        const ColCounts(notes: 6, cards: 8, revlogTotal: 88, revlogWithCard: 1),
        const ColCounts(notes: 6, cards: 8, revlogTotal: 1, revlogWithCard: 1),
      ),
      'HATTO_SMOKE col:collection_nomedia_new.colpkg '
      'E_notes=6 E_cards=8 E_revlog_total=88 E_revlog_with_card=1 '
      'R_notes=6 R_cards=8 R_revlog_total=1 R_revlog_with_card=1',
    );
    expect(
      formatNotetypeLine(
        job: 'job3',
        before: 8,
        after: 10,
        newNames: const ['Basic++', 'Basic (and reversed card)++'],
        newNotes: 5,
        duplicates: 0,
        notesPerNotetype: formatNotesPerNotetype(const [
          (name: 'Basic++', count: 4),
          (name: 'Basic+', count: 8),
          (name: 'Basic (and reversed card)++', count: 1),
          (name: 'Basic (and reversed card)+', count: 2),
        ]),
      ),
      'HATTO_SMOKE nt:job3 before=8 after=10 '
      'new_names="Basic (and reversed card)++|Basic++" new_notes=5 dup=0 '
      'notes_per_notetype="Basic (and reversed card)+=2|'
      'Basic (and reversed card)++=1|Basic+=8|Basic++=4"',
    );
    expect(
      formatNotetypeLine(
        job: 'job2',
        before: 8,
        after: 8,
        newNames: const [],
        newNotes: 5,
        duplicates: 0,
      ),
      contains('new_names=""'),
    );
  });

  test('judge.py accepts its own log and a log this formatter builds', () {
    final root = _repoRoot();
    expect(
      root,
      isNotNull,
      reason:
          'tools/arm64-smoke/judge.py not found from ${Directory.current.path}',
    );
    final judge = p.join(root!.path, 'tools/arm64-smoke/judge.py');
    final expectedPath = p.join(root.path, 'tools/arm64-smoke/expected.json');
    final selftest = p.join(root.path, 'tools/arm64-smoke/selftest.log');
    final bad = p.join(root.path, 'tools/arm64-smoke/selftest_bad.log');

    final pass = Process.runSync('python3', [judge, selftest, expectedPath]);
    expect(pass.exitCode, 0, reason: '${pass.stdout}\n${pass.stderr}');
    expect(pass.stdout, contains('판정: 통과'));

    final fail = Process.runSync('python3', [judge, bad, expectedPath]);
    expect(fail.exitCode, 1, reason: '${fail.stdout}\n${fail.stderr}');
    expect(fail.stdout, contains('판정: 실패'));
    expect(fail.stdout, contains('6/8/0'));

    final expected = jsonDecode(
      File(expectedPath).readAsStringSync(),
    ) as Map<String, dynamic>;
    final built = File(
      p.join(Directory.systemTemp.path, 'hatto-arm64-smoke-built.log'),
    )..writeAsStringSync(_logFromExpected(expected));
    final builtResult = Process.runSync('python3', [
      judge,
      built.path,
      expectedPath,
    ]);
    expect(
      builtResult.exitCode,
      0,
      reason: '${builtResult.stdout}\n${builtResult.stderr}',
    );
    expect(builtResult.stdout, contains('판정: 통과'));
  });
}

Directory? _repoRoot() {
  var dir = Directory.current;
  for (var i = 0; i < 6; i++) {
    if (File(p.join(dir.path, 'tools/arm64-smoke/judge.py')).existsSync()) {
      return dir;
    }
    final parent = dir.parent;
    if (parent.path == dir.path) {
      return null;
    }
    dir = parent;
  }
  return null;
}

String _logFromExpected(Map<String, dynamic> expected) {
  final lines = <String>[
    'HATTO_SMOKE env abi=arm64-v8a sdk=35 page=16384 model="FORMATTER" emulator=0',
    'FRB_DEVICE_OK fields=[alpha / beta, hello / world] reps=1',
    'All tests passed!',
  ];
  final colpkg = expected['colpkg'] as Map<String, dynamic>;
  for (final entry in colpkg.entries) {
    final value = entry.value as Map<String, dynamic>;
    lines.add(
      formatColLine(
        entry.key,
        _counts(value['E_after_colpkg_import'] as Map<String, dynamic>),
        _counts(value['R_after_apkg_import'] as Map<String, dynamic>),
      ),
    );
  }
  final fsrs = expected['fsrs_synthetic'] as Map<String, dynamic>;
  final imported = fsrs['R_after_apkg_import'] as Map<String, dynamic>;
  final params = (fsrs['params'] as List<dynamic>)
      .map((value) => (value as num).toDouble())
      .toList();
  lines.add(
    formatFsrsLine(
      importNotes: imported['notes'] as int,
      importCards: imported['cards'] as int,
      importRevlog: imported['revlog_total'] as int,
      fsrsItems: fsrs['fsrs_items'] as int,
      params: params,
      secondIdentical: true,
      colUnchanged: true,
      configUnchanged: true,
      seconds: 0.9,
    ),
  );
  final notetype = expected['notetype'] as Map<String, dynamic>;
  for (final job in const [
    ('job1', 'job1_default'),
    ('job2', 'job2_default'),
    ('job3', 'job3_forced'),
  ]) {
    final row = notetype[job.$2] as Map<String, dynamic>;
    final names = (row['new_notetype_names'] as List<dynamic>).cast<String>();
    String? perType;
    if (job.$1 == 'job3') {
      final pairs = (notetype['notes_per_notetype_after'] as List<dynamic>)
          .map(
            (pair) => (
              name: (pair as List<dynamic>)[0] as String,
              count: pair[1] as int,
            ),
          )
          .toList();
      perType = formatNotesPerNotetype(pairs);
    }
    lines.add(
      formatNotetypeLine(
        job: job.$1,
        before: row['notetypes_before'] as int,
        after: row['notetypes_after'] as int,
        newNames: names,
        newNotes: row['new_notes'] as int,
        duplicates: row['duplicate_notes'] as int,
        notesPerNotetype: perType,
      ),
    );
  }
  return lines.join('\n');
}

ColCounts _counts(Map<String, dynamic> row) {
  return ColCounts(
    notes: row['notes'] as int,
    cards: row['cards'] as int,
    revlogTotal: row['revlog_total'] as int,
    revlogWithCard: row['revlog_with_card'] as int,
  );
}
