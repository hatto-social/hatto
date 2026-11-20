// SPDX-FileCopyrightText: 2026 Hatto Social contributors
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:sqlite3/sqlite3.dart';

/// Draft schema for the Hatto side database. Not a stable contract.
///
/// The current schema is [sideDbSchemaVersion] (v1). A higher
/// `user_version` is refused and the file is left untouched. This runner
/// never deletes rows or tables. A file at `user_version` 0 that already
/// has tables is refused the same way. An empty file is created as v1.
/// `PRAGMA user_version` is the schema version. `meta` stores `device_id`
/// only.
///
/// `edit_journal.field` is null in v0. `deck_map.server_unsynced` defaults to
/// 1 and is the unsynced flag for that deck. Notes, cards, and media do not
/// store their own flag; they follow the deck that owns them.
/// `deck_map.deleted_at` is the deletion time of a soft-deleted deck, null
/// while the deck is live. The row stays so a later guid rewrite can still
/// see it. `import_batch_id` groups decks from one import.
/// `source_sha256` is the file name of the copied apkg under
/// `<documents>/hatto/imports/`, not a path.
///
/// `note_map.note_guid` is the Hatto guid. For a mapped note it is the same
/// value as rslib `notes.guid`; there is no second guid column. Anki notes
/// have no deck column. `home_deck_guid` is chosen when the note is first
/// mapped: the ord-0 card when one exists, otherwise the card with the
/// lowest ord. A card in a filtered deck contributes its original deck
/// (`odid`), not the filtered deck. It is written once and is not updated
/// when cards move. Edit-journal rows for notes key only on the note guid,
/// so the home deck lives here. Rewriting a deck guid updates
/// `note_map.home_deck_guid` in the same transaction, including decks whose
/// `deleted_at` is set.
///
/// The file is opened with `package:sqlite3`, which ships its own SQLite
/// library. rslib 26.09.3 links a different copy (rusqlite 0.36, feature
/// `bundled`) into `librslib_bridge.so`. This package does not open the
/// collection file and does not load SQLite from the process symbol table.
const int sideDbSchemaVersion = 1;

/// Thrown when the side database cannot be opened or a draft write is rejected.
class SideDbException implements Exception {
  const SideDbException(this.message);

  final String message;

  @override
  String toString() => 'SideDbException: $message';
}

/// The file's `user_version` is newer than this build. The file is unchanged.
class NewerSchemaException extends SideDbException {
  NewerSchemaException(int version, int supported)
    : super(
        'side database schema version $version is newer than this app '
        '($supported); refusing to open and leaving data in place',
      );
}

const List<String> _version1 = <String>[
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
    server_unsynced INTEGER NOT NULL DEFAULT 1,
    deleted_at TEXT
  )
  ''',
  'CREATE INDEX deck_map_import_batch_id ON deck_map(import_batch_id)',
  '''
  CREATE TABLE note_map (
    note_guid TEXT PRIMARY KEY,
    rslib_note_id INTEGER NOT NULL UNIQUE,
    home_deck_guid TEXT NOT NULL
  )
  ''',
  'CREATE INDEX note_map_home_deck_guid ON note_map(home_deck_guid)',
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

int readUserVersion(Database db) {
  final rows = db.select('PRAGMA user_version');
  final raw = rows.first.values.first;
  if (raw is int) {
    return raw;
  }
  throw SideDbException('unexpected user_version value: $raw');
}

/// Creates v1 in an empty file.
///
/// The current schema is [sideDbSchemaVersion]. A higher `user_version`
/// throws and does not delete or rewrite anything. Any other non-zero
/// version throws the same way. Callers open the file again only after
/// an app that understands that version is installed.
void applySideDbMigrations(Database db) {
  final current = readUserVersion(db);
  if (current == sideDbSchemaVersion) {
    return;
  }
  if (current > sideDbSchemaVersion) {
    throw NewerSchemaException(current, sideDbSchemaVersion);
  }
  if (current != 0) {
    throw SideDbException(
      'side database schema version $current cannot be opened by this app '
      '($sideDbSchemaVersion); refusing to open and leaving data in place',
    );
  }
  final existing = db.select(
    "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'",
  );
  if (existing.isNotEmpty) {
    throw const SideDbException(
      'side database has tables but user_version is 0',
    );
  }
  db.execute('BEGIN IMMEDIATE');
  try {
    for (final statement in _version1) {
      db.execute(statement);
    }
    db.execute('PRAGMA user_version = $sideDbSchemaVersion');
    db.execute('COMMIT');
  } catch (err) {
    db.execute('ROLLBACK');
    rethrow;
  }
}
