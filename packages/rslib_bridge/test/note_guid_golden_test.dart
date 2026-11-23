// SPDX-FileCopyrightText: 2026 Hatto Social contributors
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:rslib_bridge/rslib_bridge.dart';

void main() {
  test('bridge note-guid functions match the shared golden file', () async {
    final file = _goldenFile();
    final document =
        jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
    final imported = document['imported'] as List<dynamic>;
    expect(
      imported.any((raw) {
        final source = (raw as Map<String, dynamic>)['source_guid'] as String;
        return source.contains('한');
      }),
      isTrue,
    );
    expect(
      imported.any((raw) {
        final source = (raw as Map<String, dynamic>)['source_guid'] as String;
        return source.contains("'") &&
            source.contains('"') &&
            source.contains('`') &&
            source.contains('\\');
      }),
      isTrue,
    );
    expect(
      (document['local'] as List<dynamic>).map(
        (raw) => (raw as Map<String, dynamic>)['k'],
      ),
      containsAll(<int>[0, 4294967295]),
    );

    await initRslibBridge();
    for (final raw in imported) {
      final item = raw as Map<String, dynamic>;
      final jobId = item['job_id'] as String;
      final source = item['source_guid'] as String;
      if (item['error'] == 'empty_source_guid') {
        expect(
          () => importedNoteGuid(jobId: jobId, sourceGuid: source),
          throwsA(anything),
        );
        continue;
      }
      expect(
        importedNoteGuid(jobId: jobId, sourceGuid: source),
        item['expect'],
      );
    }
    for (final raw in document['local'] as List<dynamic>) {
      final item = raw as Map<String, dynamic>;
      expect(
        localNoteGuid(opId: item['op_id'] as String, k: item['k'] as int),
        item['expect'],
      );
    }
    expect(isGuidFormat(text: '886313e1-3b8a-5372-9b90-0c9aee199e5d'), isTrue);
    expect(isGuidFormat(text: 'hattoDummy'), isFalse);
    expect(isGuidFormat(text: '886313E1-3B8A-5372-9B90-0C9AEE199E5D'), isFalse);

    const importNs = 'ec425e06-0eeb-5cbc-b4c8-3818366d46e9';
    final importF = document['import_f'] as List<dynamic>;
    expect(
      importF.map((raw) => (raw as Map<String, dynamic>)['raw'] as String),
      containsAll(<String>[
        'oxr*zK@INR',
        'b91/guid#2',
        'plainGuid3',
        '3f2b8a64-1c0e-4d5a-9b7e-0a1b2c3d4e5f',
        '3F2B8A64-1C0E-4D5A-9B7E-0A1B2C3D4E5F',
        'a  ',
      ]),
    );
    for (final raw in importF) {
      final item = raw as Map<String, dynamic>;
      final source = item['raw'] as String;
      final once = isGuidFormat(text: source)
          ? source
          : importedNoteGuid(jobId: importNs, sourceGuid: source);
      expect(once, item['expect'], reason: item['label'] as String);
      expect(isGuidFormat(text: once), isTrue, reason: item['label'] as String);
      final twice = isGuidFormat(text: once)
          ? once
          : importedNoteGuid(jobId: importNs, sourceGuid: once);
      expect(twice, once, reason: item['label'] as String);
    }

    final assignCases = document['assign_import_guids'] as List<dynamic>;
    expect(
      assignCases.map((raw) => (raw as Map<String, dynamic>)['label']),
      containsAll(<String>[
        'empty-raw',
        'same-raw-three',
        'different-raw-same-f',
        'empty-raw-collides-with-nid-name',
        'kth-candidate-claimed-by-pass1',
      ]),
    );
    for (final raw in assignCases) {
      final item = raw as Map<String, dynamic>;
      final notes = (item['notes'] as List<dynamic>)
          .map(
            (note) => ImportSourceNote(
              sourceNoteId:
                  (note as Map<String, dynamic>)['source_note_id'] as int,
              rawGuid: note['raw_guid'] as String,
            ),
          )
          .toList();
      final assigned = assignImportGuids(notes: notes);
      final expectRows = item['expect'] as List<dynamic>;
      expect(
        assigned,
        hasLength(expectRows.length),
        reason: item['label'] as String,
      );
      expect(
        assigned,
        hasLength(notes.length),
        reason: item['label'] as String,
      );
      for (var i = 0; i < assigned.length; i++) {
        final want = expectRows[i] as Map<String, dynamic>;
        expect(
          assigned[i].sourceNoteId,
          want['source_note_id'],
          reason: item['label'] as String,
        );
        expect(assigned[i].guid, want['guid'], reason: item['label'] as String);
        expect(
          assigned[i].dupIndex,
          want['dup_index'],
          reason: item['label'] as String,
        );
      }
      final dup = assigned
          .where((row) => row.dupIndex >= 1 || row.reassigned)
          .length;
      expect(dup, item['dup'], reason: item['label'] as String);
      expect(
        assigned.map((row) => row.guid).toSet(),
        hasLength(assigned.length),
        reason: item['label'] as String,
      );
    }

    for (final raw in document['note_content_hash'] as List<dynamic>) {
      final item = raw as Map<String, dynamic>;
      final digest = noteContentHash(
        fields: (item['fields'] as List<dynamic>).cast<String>(),
        tags: (item['tags'] as List<dynamic>).cast<String>(),
      );
      expect(_hex(digest), item['expect'], reason: item['label'] as String);
    }

    final classes = document['classify'] as List<dynamic>;
    expect(
      classes.map((raw) => (raw as Map<String, dynamic>)['expect']),
      containsAll(<String>['NEW', 'SAME', 'CHANGED', 'LOCAL_NEWER', 'BLOCKED']),
    );
    for (final raw in classes) {
      final item = raw as Map<String, dynamic>;
      final resident = item['resident'];
      final result = classify(
        file: _facts(item['file'] as Map<String, dynamic>),
        resident: resident == null
            ? null
            : _facts(resident as Map<String, dynamic>),
      );
      expect(
        _className(result),
        item['expect'],
        reason: item['label'] as String,
      );
    }

    for (final raw in document['plans'] as List<dynamic>) {
      final item = raw as Map<String, dynamic>;
      final plan = summarizePlan(
        classes: (item['classes'] as List<dynamic>)
            .map((name) => _classFromName(name as String))
            .toList(),
        dup: item['dup'] as int,
      );
      final want = item['expect'] as Map<String, dynamic>;
      expect(plan.new_, want['new'], reason: item['label'] as String);
      expect(plan.same, want['same'], reason: item['label'] as String);
      expect(plan.changed, want['changed'], reason: item['label'] as String);
      expect(
        plan.localNewer,
        want['local_newer'],
        reason: item['label'] as String,
      );
      expect(plan.blocked, want['blocked'], reason: item['label'] as String);
      expect(plan.dup, want['dup'], reason: item['label'] as String);
      expect(
        plan.noResidentCall,
        want['no_resident_call'],
        reason: item['label'] as String,
      );
    }
  });
}

File _goldenFile() {
  var dir = Directory.current;
  for (var i = 0; i < 8; i++) {
    final nested = File(
      '${dir.path}/packages/hatto_card_contract/fixtures/note_guid_golden.json',
    );
    if (nested.existsSync()) {
      return nested;
    }
    final sibling = File(
      '${dir.path}/../hatto_card_contract/fixtures/note_guid_golden.json',
    );
    if (sibling.existsSync()) {
      return sibling;
    }
    final parent = dir.parent;
    if (parent.path == dir.path) {
      break;
    }
    dir = parent;
  }
  fail('note_guid_golden.json not found from ${Directory.current.path}');
}

NoteFacts _facts(Map<String, dynamic> value) {
  return NoteFacts(
    guid: value['guid'] as String,
    notetypeId: value['notetype_id'] as int,
    mod: value['mod'] as int,
    contentHash: _hexToBytes(value['content_hash'] as String),
  );
}

String _hex(Uint8List bytes) {
  return bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
}

Uint8List _hexToBytes(String text) {
  final bytes = Uint8List(text.length ~/ 2);
  for (var i = 0; i < bytes.length; i++) {
    bytes[i] = int.parse(text.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return bytes;
}

String _className(Class value) {
  switch (value) {
    case Class.new_:
      return 'NEW';
    case Class.same:
      return 'SAME';
    case Class.changed:
      return 'CHANGED';
    case Class.localNewer:
      return 'LOCAL_NEWER';
    case Class.blocked:
      return 'BLOCKED';
  }
}

Class _classFromName(String name) {
  switch (name) {
    case 'NEW':
      return Class.new_;
    case 'SAME':
      return Class.same;
    case 'CHANGED':
      return Class.changed;
    case 'LOCAL_NEWER':
      return Class.localNewer;
    case 'BLOCKED':
      return Class.blocked;
    default:
      fail('unknown class $name');
  }
}
