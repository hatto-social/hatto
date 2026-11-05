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

  test('open stamps user_version and device_id only', () {
    final path = sideDbPath(dir.path);
    final side = SideDb.open(path: path, deviceId: 'device-a');
    expect(side.schemaVersion, sideDbSchemaVersion);
    side.close();

    final raw = sqlite3.open(path);
    addTearDown(raw.close);
    expect(
      raw.select('PRAGMA user_version').first.values.first,
      sideDbSchemaVersion,
    );
    expect(
      raw.select("SELECT value FROM meta WHERE key = 'schema_version'"),
      isEmpty,
    );
    expect(
      raw
          .select("SELECT value FROM meta WHERE key = 'device_id'")
          .first['value'],
      'device-a',
    );
    expect(_columns(raw, 'meta'), ['key', 'value']);
    expect(_columns(raw, 'deck_map'), [
      'deck_guid',
      'rslib_deck_id',
      'import_batch_id',
      'origin_kind',
      'origin_role',
      'source_sha256',
      'server_unsynced',
    ]);
    expect(
      raw
          .select("PRAGMA table_info(deck_map)")
          .where((row) => row['name'] == 'server_unsynced')
          .single['dflt_value'],
      '1',
    );
    expect(_columns(raw, 'note_map'), ['note_guid', 'rslib_note_id']);
    expect(_columns(raw, 'edit_journal'), [
      'id',
      'op',
      'entity_kind',
      'guid',
      'field',
      'hlc',
      'payload',
    ]);
    expect(_columns(raw, 'revlog_origin'), ['revlog_id', 'job']);
    expect(_columns(raw, 'media_key'), ['filename', 'content_key']);
    expect(_columns(raw, 'intent'), ['id', 'op', 'target_key', 'expected']);
    for (final name in [
      'deck_map_import_batch_id',
      'revlog_origin_job',
      'media_key_content_key',
    ]) {
      expect(
        raw.select('SELECT name FROM sqlite_master WHERE name = ?', [name]),
        isNotEmpty,
        reason: name,
      );
    }
  });

  test('one revlog id keeps a single job', () {
    final side = SideDb.openInMemory();
    addTearDown(side.close);
    side.putRevlogOrigin(revlogId: 1, job: 'a');
    side.putRevlogOrigin(revlogId: 1, job: 'a');
    side.putRevlogOrigin(revlogId: 1, job: 'b');
    expect(side.revlogOrigins().single.job, 'b');
    side.deleteRevlogOrigin(1);
    expect(side.revlogOrigins(), isEmpty);
    expect(
      () => side.putRevlogOrigin(revlogId: 1, job: ''),
      throwsA(isA<SideDbException>()),
    );
  });

  test('deck flag defaults to unsynced and imports group by batch id', () {
    final side = SideDb.openInMemory();
    addTearDown(side.close);
    side.putDeck(deckGuid: 'deck-b', rslibDeckId: 2, importBatchId: 'batch');
    side.putDeck(
      deckGuid: 'deck-a',
      rslibDeckId: 1,
      importBatchId: 'batch',
      originKind: 'apkg',
    );
    side.putDeck(deckGuid: 'deck-c', rslibDeckId: 3, importBatchId: 'other');

    expect(side.deckServerUnsynced('deck-a'), isTrue);
    expect(side.unsyncedDecks().map((row) => row.deckGuid), [
      'deck-a',
      'deck-b',
      'deck-c',
    ]);
    expect(side.decksForImport('batch').map((row) => row.deckGuid), [
      'deck-a',
      'deck-b',
    ]);
    expect(side.decksForImport('batch').first.originKind, 'apkg');

    side.setDeckServerUnsynced(deckGuid: 'deck-a', unsynced: false);
    expect(side.deckServerUnsynced('deck-a'), isFalse);
    expect(side.decksForImport('batch').map((row) => row.serverUnsynced), [
      false,
      true,
    ]);

    side.putDeck(deckGuid: 'deck-a', rslibDeckId: 1, importBatchId: 'batch-2');
    expect(side.decksForImport('batch').map((row) => row.deckGuid), ['deck-b']);
    expect(side.decksForImport('batch-2').single.deckGuid, 'deck-a');

    expect(
      () => side.putDeck(deckGuid: 'deck-d', rslibDeckId: 1),
      throwsA(isA<SqliteException>()),
    );
    expect(
      () => side.setDeckServerUnsynced(deckGuid: 'missing', unsynced: false),
      throwsA(isA<SideDbException>()),
    );
  });

  test('user_version 0 with existing tables is rejected', () {
    final path = sideDbPath(dir.path);
    File(path).parent.createSync(recursive: true);
    final raw = sqlite3.open(path);
    raw.execute('CREATE TABLE edit_journal (id INTEGER PRIMARY KEY)');
    raw.close();

    expect(
      () => SideDb.open(path: path, deviceId: 'device-a'),
      throwsA(isA<SideDbException>()),
    );
    final again = sqlite3.open(path);
    addTearDown(again.close);
    expect(again.select('PRAGMA user_version').first.values.first, 0);
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

  test('reopen keeps a version 1 file', () {
    final path = sideDbPath(dir.path);
    final first = SideDb.open(path: path, deviceId: 'device-a');
    final intentId = first.beginIntent(op: 'answer', targetKey: 'card-1');
    first.close();

    final second = SideDb.open(path: path, deviceId: 'device-a');
    addTearDown(second.close);
    expect(second.schemaVersion, sideDbSchemaVersion);
    expect(second.pendingIntents().single.id, intentId);
    expect(second.pendingIntents().single.op, 'answer');
    expect(second.pendingIntents().single.targetKey, 'card-1');
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

List<String> _columns(Database db, String table) {
  return [
    for (final row in db.select('PRAGMA table_info($table)'))
      row['name'] as String,
  ];
}
