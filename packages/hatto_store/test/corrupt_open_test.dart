// SPDX-FileCopyrightText: 2026 Hatto Social contributors
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:io';

import 'package:hatto_store/hatto_store.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

void main() {
  test(
    'only corrupt and not-a-database codes become SideDbCorruptException',
    () {
      final corrupt = translateSideDbOpenError(
        SqliteException(extendedResultCode: 11, message: 'malformed'),
        path: 'hatto.sqlite',
      );
      expect(corrupt, isA<SideDbCorruptException>());
      expect(
        (corrupt as SideDbCorruptException).path,
        File('hatto.sqlite').absolute.path,
      );

      final extended = translateSideDbOpenError(
        SqliteException(extendedResultCode: 779, message: 'index'),
        path: '/tmp/hatto.sqlite',
      );
      expect(extended, isA<SideDbCorruptException>());

      final notADb = translateSideDbOpenError(
        SqliteException(extendedResultCode: 26, message: 'not a database'),
      );
      expect(notADb, isA<SideDbCorruptException>());
      expect((notADb as SideDbCorruptException).path, isNull);

      final emptyPath = translateSideDbOpenError(
        SqliteException(extendedResultCode: 26, message: 'not a database'),
        path: '',
      );
      expect((emptyPath as SideDbCorruptException).path, isNull);

      for (final code in [3, 8, 10, 13, 14]) {
        final other = translateSideDbOpenError(
          SqliteException(extendedResultCode: code, message: 'other $code'),
          path: '/tmp/hatto.sqlite',
        );
        expect(other, isA<SqliteException>(), reason: 'code $code');
        expect(
          other,
          isNot(isA<SideDbCorruptException>()),
          reason: 'code $code',
        );
      }
    },
  );

  test('a file that is not a database throws SideDbCorruptException', () {
    final dir = Directory.systemTemp.createTempSync('hatto-corrupt');
    addTearDown(() {
      if (dir.existsSync()) {
        dir.deleteSync(recursive: true);
      }
    });
    final path = p.join(dir.path, 'hatto.sqlite');
    File(path).writeAsBytesSync(const [1, 2, 3, 4, 5, 6, 7, 8]);
    expect(
      () => SideDb.openOrCreate(path),
      throwsA(
        isA<SideDbCorruptException>().having(
          (error) => error.path,
          'path',
          File(path).absolute.path,
        ),
      ),
    );
  });
}
