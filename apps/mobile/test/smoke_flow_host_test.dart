// SPDX-FileCopyrightText: 2026 Hatto Social contributors
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../integration_test/smoke_flow.dart';
import 'import_fixture.dart';

void main() {
  test('device smoke flow runs the shared pipeline on the fixtures', () async {
    final smoke = await Directory.systemTemp.createTemp('hatto-device-smoke');
    addTearDown(() => smoke.delete(recursive: true));
    for (final name in const [
      'palace.colpkg',
      'collection.colpkg',
      'collection_nomedia_new.colpkg',
      'fsrs-synthetic-37k.apkg',
      'stock-notes.apkg',
    ]) {
      await Link(p.join(smoke.path, name)).create(fixtureFile(name).path);
    }
    final lines = <String>[];
    await runZoned(
      () => runArm64Smoke(smoke.path),
      zoneSpecification: ZoneSpecification(
        print: (self, parent, zone, line) {
          lines.add(line);
          parent.print(zone, line);
        },
      ),
    );
    final text = lines.join('\n');
    expect(text, contains('HATTO_SMOKE col:palace.colpkg'));
    expect(text, contains('E_notes=4'));
    expect(text, contains('R_notes=6'));
    _expectFsrs(text, loadExpected()['fsrs_synthetic'] as Map<String, dynamic>);
    expect(text, contains('HATTO_SMOKE nt:job1'));
    expect(text, contains('before=6 after=8'));
    expect(text, contains('HATTO_SMOKE nt:job2'));
    expect(text, contains('before=8 after=8'));
    expect(text, contains('new_notes=5 dup=0'));
    expect(text, contains('HATTO_SMOKE nt:job3'));
    expect(text, contains('before=8 after=10'));
    expect(text, contains('HATTO_SMOKE t15 second=noop'));
    expect(text, contains('mod_unchanged=1'));
    expect(text, isNot(contains('HATTO_SMOKE_FAIL')));
  }, timeout: const Timeout(Duration(minutes: 8)));
}

/// `fsrs_items` follows the device's local Anki day (04:00 rollover).
/// `expected.json` is the Asia/Seoul baseline. UTC is 203 reviews shorter.
void _expectFsrs(String text, Map<String, dynamic> fsrs) {
  final line = RegExp(r'HATTO_SMOKE fsrs\b.*').firstMatch(text)?.group(0);
  expect(line, isNotNull);
  final fields = <String, String>{
    for (final match in RegExp(r'(\w+)=("[^"]*"|\S+)').allMatches(line!))
      match.group(1)!: match.group(2)!.replaceAll('"', ''),
  };
  final offset = DateTime.now().timeZoneOffset;
  if (offset == const Duration(hours: 9)) {
    expect(int.parse(fields['fsrs_items']!), 33312);
    final golden = (fsrs['params'] as List<dynamic>)
        .map((value) => (value as num).toDouble())
        .toList();
    final got = fields['params']!
        .split(',')
        .map((value) => double.parse(value))
        .toList();
    expect(got, hasLength(golden.length));
    for (var i = 0; i < golden.length; i++) {
      expect(
        (got[i] - golden[i]).abs(),
        lessThan(5e-7),
        reason: 'param $i ${got[i]} vs ${golden[i]}',
      );
    }
  } else if (offset == Duration.zero) {
    expect(int.parse(fields['fsrs_items']!), 33109);
    expect(int.parse(fields['n_params']!), 21);
    expect(fields['finite'], '1');
  } else {
    expect(int.parse(fields['n_params']!), 21);
    expect(fields['finite'], '1');
  }
}
