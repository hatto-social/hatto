// SPDX-FileCopyrightText: 2026 Hatto Social contributors
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:convert';
import 'dart:io';

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
