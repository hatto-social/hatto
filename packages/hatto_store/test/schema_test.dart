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
      'tombstoned',
    ]);
    final deckInfo = raw.select('PRAGMA table_info(deck_map)');
    expect(
      deckInfo
          .where((row) => row['name'] == 'server_unsynced')
          .single['dflt_value'],
      '1',
    );
    expect(
      deckInfo.where((row) => row['name'] == 'tombstoned').single['dflt_value'],
      '0',
    );
    expect(_columns(raw, 'note_map'), [
      'note_guid',
      'rslib_note_id',
      'home_deck_guid',
    ]);
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
      'note_map_home_deck_guid',
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

  test('reopen keeps the current schema and pending intents', () {
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

  test('a version 1 database gains home_deck_guid and keeps its rows', () {
    final path = sideDbPath(dir.path);
    File(path).parent.createSync(recursive: true);
    final raw = sqlite3.open(path);
    raw.execute('BEGIN');
    for (final statement in _version1Schema) {
      raw.execute(statement);
    }
    raw.execute(
      "INSERT INTO meta(key, value) VALUES ('device_id', 'device-a')",
    );
    raw.execute(
      'INSERT INTO deck_map(deck_guid, rslib_deck_id, import_batch_id, '
      'origin_kind, origin_role, source_sha256, server_unsynced) '
      "VALUES ('deck-old', 7, 'batch', 'apkg', NULL, NULL, 1)",
    );
    raw.execute(
      'INSERT INTO note_map(note_guid, rslib_note_id) VALUES (?, ?)',
      ['note-old', 42],
    );
    raw.execute(
      'INSERT INTO edit_journal(op, entity_kind, guid, field, hlc, payload) '
      "VALUES ('update_note', 'note', 'note-old', NULL, 'device-a:1:1', NULL)",
    );
    raw.execute('PRAGMA user_version = 1');
    raw.execute('COMMIT');
    raw.close();

    final side = SideDb.open(path: path, deviceId: 'device-b');
    expect(side.schemaVersion, sideDbSchemaVersion);
    expect(side.note('note-old')!.rslibNoteId, 42);
    expect(side.note('note-old')!.homeDeckGuid, isNull);
    final deck = side.deck('deck-old')!;
    expect(deck.rslibDeckId, 7);
    expect(deck.importBatchId, 'batch');
    expect(deck.tombstoned, isFalse);
    expect(side.journalRows().single.guid, 'note-old');
    side.importNote(
      noteGuid: 'note-new',
      rslibNoteId: 43,
      cards: const [ImportedNoteCard(ord: 0, rslibDeckId: 7)],
    );
    expect(side.note('note-new')!.homeDeckGuid, 'deck-old');
    expect(side.note('note-old')!.homeDeckGuid, isNull);
    side.close();

    final again = sqlite3.open(path);
    addTearDown(again.close);
    expect(again.select('PRAGMA user_version').first.values.first, 2);
    expect(_columns(again, 'note_map'), [
      'note_guid',
      'rslib_note_id',
      'home_deck_guid',
    ]);
    expect(
      again.select('SELECT name FROM sqlite_master WHERE name = ?', [
        'note_map_home_deck_guid',
      ]),
      isNotEmpty,
    );
    expect(
      again
          .select("SELECT value FROM meta WHERE key = 'device_id'")
          .first['value'],
      'device-a',
    );
  });

  test('a failed migration from version 1 leaves user_version at 1', () {
    final path = sideDbPath(dir.path);
    File(path).parent.createSync(recursive: true);
    final raw = sqlite3.open(path);
    raw.execute(
      'CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)',
    );
    raw.execute('PRAGMA user_version = 1');
    raw.close();

    expect(
      () => SideDb.open(path: path, deviceId: 'device-a'),
      throwsA(isA<SqliteException>()),
    );
    final again = sqlite3.open(path);
    addTearDown(again.close);
    expect(again.select('PRAGMA user_version').first.values.first, 1);
    expect(_columns(again, 'note_map'), isEmpty);
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

/// Side-database DDL at `user_version` 1, before `home_deck_guid`.
const List<String> _version1Schema = <String>[
  '''
  CREATE TABLE meta (
    key TEXT PRIMARY KEY,
    value TEXT NOT NULL
  )
  ''',
  '''
  CREATE TABLE deck_map (
    deck_guid TEXT PRIMARY KEY,
    rslib_deck_id INTEGER NOT NULL UNIQUE,
    import_batch_id TEXT,
    origin_kind TEXT,
    origin_role TEXT,
    source_sha256 TEXT,
    server_unsynced INTEGER NOT NULL DEFAULT 1
  )
  ''',
  'CREATE INDEX deck_map_import_batch_id ON deck_map(import_batch_id)',
  '''
  CREATE TABLE note_map (
    note_guid TEXT PRIMARY KEY,
    rslib_note_id INTEGER NOT NULL UNIQUE
  )
  ''',
  '''
  CREATE TABLE edit_journal (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    op TEXT NOT NULL,
    entity_kind TEXT NOT NULL,
    guid TEXT NOT NULL,
    field TEXT,
    hlc TEXT NOT NULL,
    payload BLOB
  )
  ''',
  '''
  CREATE TABLE revlog_origin (
    revlog_id INTEGER PRIMARY KEY,
    job TEXT NOT NULL
  )
  ''',
  'CREATE INDEX revlog_origin_job ON revlog_origin(job)',
  '''
  CREATE TABLE media_key (
    filename TEXT PRIMARY KEY,
    content_key TEXT NOT NULL
  )
  ''',
  'CREATE INDEX media_key_content_key ON media_key(content_key)',
  '''
  CREATE TABLE intent (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    op TEXT NOT NULL,
    target_key TEXT NOT NULL,
    expected TEXT
  )
  ''',
];
