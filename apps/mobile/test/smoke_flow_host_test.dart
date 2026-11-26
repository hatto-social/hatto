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
    expect(text, contains('fsrs_items=33109'));
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
