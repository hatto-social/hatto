import 'package:sqlite3/sqlite3.dart';

/// Draft schema for the Hatto side database. Not a stable contract.
///
/// Append a step and bump [sideDbSchemaVersion]. Do not rewrite a step that
/// may already be on a device. Statements stay idempotent (`IF NOT EXISTS`)
/// because a file created by the skeleton has `user_version` 0 even though
/// its tables already exist.
///
/// The file is opened with `package:sqlite3`, which ships its own SQLite
/// library. rslib 26.09.3 links a different copy (rusqlite 0.36, feature
/// `bundled`) into `librslib_bridge.so`. This package does not open the
/// collection file and does not load SQLite from the process symbol table.
const int sideDbSchemaVersion = 2;

/// Thrown when the side database cannot be opened or a draft write is rejected.
class SideDbException implements Exception {
  const SideDbException(this.message);

  final String message;

  @override
  String toString() => 'SideDbException: $message';
}

/// Version 1 is the skeleton. Version 2 is the deck/import unsynced marker.
///
/// `deck_map.server_unsynced` is the skeleton column. It needs an rslib deck
/// id, so an import batch cannot be recorded there on its own. The draft
/// marker is the `server_unsynced` table in version 2. This code does not
/// write the skeleton column.
const List<List<String>> _migrations = <List<String>>[
  <String>[
    '''
    CREATE TABLE IF NOT EXISTS meta (
      key TEXT PRIMARY KEY,
      value TEXT NOT NULL
    )
    ''',
    '''
    CREATE TABLE IF NOT EXISTS deck_map (
      deck_guid TEXT PRIMARY KEY,
      rslib_deck_id INTEGER NOT NULL,
      import_batch_id TEXT,
      origin_kind TEXT,
      origin_role TEXT,
      server_unsynced INTEGER NOT NULL DEFAULT 1,
      source_sha256 TEXT
    )
    ''',
    '''
    CREATE TABLE IF NOT EXISTS note_map (
      note_guid TEXT PRIMARY KEY,
      rslib_note_id INTEGER NOT NULL
    )
    ''',
    '''
    CREATE TABLE IF NOT EXISTS edit_journal (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      entity_kind TEXT NOT NULL,
      guid TEXT NOT NULL,
      field TEXT,
      hlc TEXT NOT NULL,
      device_id TEXT NOT NULL,
      created_at INTEGER NOT NULL
    )
    ''',
    '''
    CREATE TABLE IF NOT EXISTS revlog_origin (
      revlog_id INTEGER NOT NULL,
      job TEXT NOT NULL,
      PRIMARY KEY (revlog_id, job)
    )
    ''',
    '''
    CREATE TABLE IF NOT EXISTS media_key (
      filename TEXT PRIMARY KEY,
      content_key TEXT NOT NULL
    )
    ''',
    '''
    CREATE TABLE IF NOT EXISTS intent (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      op TEXT NOT NULL,
      target_key TEXT NOT NULL,
      expected TEXT,
      status TEXT NOT NULL,
      created_at INTEGER NOT NULL
    )
    ''',
  ],
  <String>[
    '''
    CREATE TABLE IF NOT EXISTS server_unsynced (
      unit_kind TEXT NOT NULL CHECK (unit_kind IN ('deck', 'import')),
      unit_key TEXT NOT NULL CHECK (length(unit_key) > 0),
      marked_at INTEGER NOT NULL,
      PRIMARY KEY (unit_kind, unit_key)
    )
    ''',
  ],
];

int readUserVersion(Database db) {
  final rows = db.select('PRAGMA user_version');
  final raw = rows.first.values.first;
  if (raw is int) {
    return raw;
  }
  throw SideDbException('unexpected user_version value: $raw');
}

void applySideDbMigrations(Database db) {
  if (_migrations.length != sideDbSchemaVersion) {
    throw SideDbException(
      'side database has ${_migrations.length} migrations, expected $sideDbSchemaVersion',
    );
  }
  final current = readUserVersion(db);
  if (current > sideDbSchemaVersion) {
    throw SideDbException(
      'side database schema version $current is newer than this app ($sideDbSchemaVersion)',
    );
  }
  for (var version = current + 1; version <= sideDbSchemaVersion; version++) {
    db.execute('BEGIN IMMEDIATE');
    try {
      for (final statement in _migrations[version - 1]) {
        db.execute(statement);
      }
      db.execute('PRAGMA user_version = $version');
      db.execute(
        'INSERT INTO meta(key, value) VALUES (?, ?) '
        'ON CONFLICT(key) DO UPDATE SET value = excluded.value',
        ['schema_version', '$version'],
      );
      db.execute('COMMIT');
    } catch (err) {
      db.execute('ROLLBACK');
      rethrow;
    }
  }
}
