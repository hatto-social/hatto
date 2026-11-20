// SPDX-FileCopyrightText: 2026 Hatto Social contributors
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:io';

import 'package:hatto_store/hatto_store.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

void main() {
  test('a higher user_version is refused and its rows stay', () async {
    final dir = await Directory.systemTemp.createTemp('hatto-migrate');
    addTearDown(() => dir.delete(recursive: true));
    final path = '${dir.path}/hatto.sqlite';
    final raw = sqlite3.open(path);
    raw.execute('PRAGMA user_version = 2');
    raw.execute('CREATE TABLE keep_me (id INTEGER PRIMARY KEY, value TEXT)');
    raw.execute("INSERT INTO keep_me(value) VALUES ('safe')");
    raw.close();

    expect(() => SideDb.openOrCreate(path), throwsA(isA<SideDbException>()));
    expect(
      () => SideDb.open(path: path, deviceId: 'device-a'),
      throwsA(isA<SideDbException>()),
    );

    final again = sqlite3.open(path);
    addTearDown(again.close);
    expect(again.select('PRAGMA user_version').first.values.first, 2);
    expect(again.select('SELECT value FROM keep_me').single['value'], 'safe');
    expect(
      again.select("SELECT name FROM sqlite_master WHERE name = 'keep_me'"),
      isNotEmpty,
    );
  });

  test('user_version 0 with a row is refused and the row stays', () async {
    final dir = await Directory.systemTemp.createTemp('hatto-migrate-zero');
    addTearDown(() => dir.delete(recursive: true));
    final path = '${dir.path}/hatto.sqlite';
    final raw = sqlite3.open(path);
    raw.execute('CREATE TABLE keep_me (value TEXT)');
    raw.execute("INSERT INTO keep_me(value) VALUES ('old')");
    raw.close();

    expect(() => SideDb.openOrCreate(path), throwsA(isA<SideDbException>()));

    final again = sqlite3.open(path);
    addTearDown(again.close);
    expect(again.select('PRAGMA user_version').first.values.first, 0);
    expect(again.select('SELECT value FROM keep_me').single['value'], 'old');
  });

  test('the current schema is version 1', () {
    expect(sideDbSchemaVersion, 1);
  });
}
