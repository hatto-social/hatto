import 'dart:io';

import 'package:hatto_store/hatto_store.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('hatto-schema');
  });

  tearDown(() async {
    if (dir.existsSync()) {
      await dir.delete(recursive: true);
    }
  });

  test('documents path is hatto/hatto.sqlite under the given directory', () {
    expect(
      sideDbPath('/data/user/0/social.hatto.hatto_mobile/app_flutter'),
      p.join(
        '/data/user/0/social.hatto.hatto_mobile/app_flutter',
        'hatto',
        'hatto.sqlite',
      ),
    );
  });

  test('open creates the documents file and stamps the draft schema', () {
    final path = sideDbPath(dir.path);
    expect(File(path).existsSync(), isFalse);

    final side = SideDb.open(path: path, deviceId: 'device-a');
    expect(side.schemaVersion, sideDbSchemaVersion);
    side.putRevlogOrigin(revlogId: 4, job: 'import');
    side.markServerUnsynced(unitKind: sideDbUnitDeck, unitKey: 'deck-1');
    side.close();

    final raw = sqlite3.open(path);
    addTearDown(raw.close);
    expect(
      raw.select('PRAGMA user_version').first.values.first,
      sideDbSchemaVersion,
    );
    expect(
      raw
          .select("SELECT value FROM meta WHERE key = 'schema_version'")
          .first['value'],
      '$sideDbSchemaVersion',
    );
    expect(
      raw
          .select("SELECT value FROM meta WHERE key = 'device_id'")
          .first['value'],
      'device-a',
    );
  });

  test('reopen keeps rows and does not duplicate origins', () {
    final path = sideDbPath(dir.path);
    final first = SideDb.open(path: path, deviceId: 'device-a');
    first.putRevlogOrigin(revlogId: 1, job: 'import');
    first.putRevlogOrigin(revlogId: 1, job: 'import');
    first.putRevlogOrigin(revlogId: 1, job: 'fsrs');
    first.markServerUnsynced(unitKind: sideDbUnitImport, unitKey: 'batch-9');
    first.close();

    final second = SideDb.open(path: path, deviceId: 'device-a');
    addTearDown(second.close);
    expect(second.schemaVersion, sideDbSchemaVersion);
    expect(second.revlogOrigins(revlogId: 1).map((row) => row.job), [
      'fsrs',
      'import',
    ]);
    expect(
      second.isServerUnsynced(unitKind: sideDbUnitImport, unitKey: 'batch-9'),
      isTrue,
    );
    second.deleteRevlogOrigin(revlogId: 1, job: 'import');
    expect(second.revlogOrigins().single.job, 'fsrs');
  });

  test('a skeleton file at user_version 0 migrates and keeps the journal', () {
    final path = sideDbPath(dir.path);
    File(path).parent.createSync(recursive: true);
    final raw = sqlite3.open(path);
    raw.execute('''
      CREATE TABLE edit_journal (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        entity_kind TEXT NOT NULL,
        guid TEXT NOT NULL,
        field TEXT,
        hlc TEXT NOT NULL,
        device_id TEXT NOT NULL,
        created_at INTEGER NOT NULL
      )
      ''');
    raw.execute(
      'INSERT INTO edit_journal(entity_kind, guid, field, hlc, device_id, created_at) '
      "VALUES ('note', 'note-guid', 'front', 'device:1:1', 'device', 1)",
    );
    raw.execute('PRAGMA user_version = 0');
    raw.close();

    final side = SideDb.open(path: path, deviceId: 'device-a');
    addTearDown(side.close);
    expect(side.schemaVersion, sideDbSchemaVersion);
    expect(side.journalRows().single.guid, 'note-guid');
    expect(side.revlogOrigins(), isEmpty);
    expect(side.pendingIntentCount(), 0);
  });

  test('user_version 1 runs only the unsynced-marker step', () {
    final path = sideDbPath(dir.path);
    final side = SideDb.open(path: path, deviceId: 'device-a');
    side.putRevlogOrigin(revlogId: 7, job: 'import');
    final intentId = side.beginIntent(op: 'answer', targetKey: 'card-1');
    side.close();

    final raw = sqlite3.open(path);
    raw.execute('DROP TABLE server_unsynced');
    raw.execute('PRAGMA user_version = 1');
    raw.close();

    final again = SideDb.open(path: path, deviceId: 'device-a');
    addTearDown(again.close);
    expect(again.schemaVersion, sideDbSchemaVersion);
    expect(again.revlogOrigins().single.revlogId, 7);
    expect(again.serverUnsyncedRows(), isEmpty);
    expect(again.pendingIntents().single.id, intentId);
    expect(again.pendingIntents().single.op, 'answer');
    expect(again.pendingIntents().single.targetKey, 'card-1');
    expect(again.pendingIntents().single.status, 'pending');
  });

  test('a newer schema than this app is rejected', () {
    final path = sideDbPath(dir.path);
    File(path).parent.createSync(recursive: true);
    final raw = sqlite3.open(path);
    raw.execute('PRAGMA user_version = 99');
    raw.close();

    expect(
      () => SideDb.open(path: path, deviceId: 'device-a'),
      throwsA(isA<SideDbException>()),
    );
  });

  test('deck and import markers are separate rows', () {
    final side = SideDb.openInMemory();
    addTearDown(side.close);
    side.markServerUnsynced(unitKind: sideDbUnitDeck, unitKey: 'shared');
    side.markServerUnsynced(unitKind: sideDbUnitImport, unitKey: 'shared');
    side.markServerUnsynced(unitKind: sideDbUnitDeck, unitKey: 'shared');
    expect(side.serverUnsyncedRows(), hasLength(2));
    expect(
      side.serverUnsyncedRows(unitKind: sideDbUnitDeck).single.unitKind,
      sideDbUnitDeck,
    );

    side.clearServerUnsynced(unitKind: sideDbUnitDeck, unitKey: 'shared');
    expect(
      side.isServerUnsynced(unitKind: sideDbUnitDeck, unitKey: 'shared'),
      isFalse,
    );
    expect(
      side.isServerUnsynced(unitKind: sideDbUnitImport, unitKey: 'shared'),
      isTrue,
    );
    side.clearServerUnsynced(unitKind: sideDbUnitImport, unitKey: 'missing');
    expect(
      side.isServerUnsynced(unitKind: sideDbUnitImport, unitKey: 'shared'),
      isTrue,
    );
  });

  test('draft writes reject an empty origin or an unknown unit', () {
    final side = SideDb.openInMemory();
    addTearDown(side.close);
    expect(
      () => side.putRevlogOrigin(revlogId: 1, job: ''),
      throwsA(isA<SideDbException>()),
    );
    expect(
      () => side.markServerUnsynced(unitKind: 'note', unitKey: 'n'),
      throwsA(isA<SideDbException>()),
    );
    expect(
      () => side.markServerUnsynced(unitKind: sideDbUnitDeck, unitKey: ''),
      throwsA(isA<SideDbException>()),
    );
    expect(side.revlogOrigins(), isEmpty);
    expect(side.serverUnsyncedRows(), isEmpty);
  });

  test('user_version set inside a transaction rolls back with it', () {
    final db = sqlite3.openInMemory();
    addTearDown(db.close);
    db.execute('BEGIN');
    db.execute('PRAGMA user_version = 3');
    db.execute('ROLLBACK');
    expect(db.select('PRAGMA user_version').first.values.first, 0);
  });
}
