// SPDX-FileCopyrightText: 2026 Hatto Social contributors
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:io';

import 'package:hatto_store/hatto_store.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  test('import startup is needed only for an intent or a working file', () {
    final db = SideDb.openInMemory();
    addTearDown(db.close);
    final root = Directory.systemTemp.createTempSync('hatto-store-startup');
    addTearDown(() => root.deleteSync(recursive: true));

    expect(importStartupNeeded(db, root.path), isFalse);
    for (final name in const ['raw', 'e', 'staged']) {
      Directory(p.join(root.path, 'import', name)).createSync(recursive: true);
    }
    expect(importStartupNeeded(db, root.path), isFalse);
    File(p.join(root.path, 'import', 'staged', 'x.apkg'))
        .writeAsBytesSync(const [1]);
    expect(importStartupNeeded(db, root.path), isTrue);
    File(p.join(root.path, 'import', 'staged', 'x.apkg')).deleteSync();
    db.beginIntent(
      op: intentImport,
      targetKey: '11111111-1111-4111-8111-111111111111',
      expected: '{}',
    );
    expect(importStartupNeeded(db, root.path), isTrue);
  });
}
