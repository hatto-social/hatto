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
