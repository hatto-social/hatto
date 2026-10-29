import 'dart:io';

import 'package:sqlite3/sqlite3.dart';

/// Hatto metadata stored beside the resident collection.
///
/// The collection file stays an rslib database. Deck/note guid maps, the edit
/// journal, revlog origin, media keys, and crash-recovery intents live here.
class SideDb {
  SideDb._(this._db, this.deviceId);

  final Database _db;
  final String deviceId;
  int _hlcCounter = 0;

  static SideDb open({required String path, required String deviceId}) {
    final file = File(path);
    file.parent.createSync(recursive: true);
    final db = sqlite3.open(path);
    final side = SideDb._(db, deviceId);
    side._migrate();
    return side;
  }

  static SideDb openInMemory({String deviceId = 'test-device'}) {
    final side = SideDb._(sqlite3.openInMemory(), deviceId);
    side._migrate();
    return side;
  }

  void close() => _db.close();

  String nextHlc() {
    _hlcCounter += 1;
    final millis = DateTime.now().millisecondsSinceEpoch;
    return '$deviceId:$millis:$_hlcCounter';
  }

  int beginIntent({
    required String op,
    required String targetKey,
    String? expected,
  }) {
    _db.execute('BEGIN IMMEDIATE');
    try {
      _db.execute(
        'INSERT INTO intent(op, target_key, expected, status, created_at) VALUES (?, ?, ?, ?, ?)',
        [op, targetKey, expected, 'pending', _now()],
      );
      final id = _db.lastInsertRowId;
      _db.execute('COMMIT');
      return id;
    } catch (err) {
      _db.execute('ROLLBACK');
      rethrow;
    }
  }

  void completeIntent({
    required int intentId,
    required String entityKind,
    required String guid,
    String? field,
  }) {
    final hlc = nextHlc();
    _db.execute('BEGIN IMMEDIATE');
    try {
      _db.execute(
        "UPDATE intent SET status = 'done' WHERE id = ? AND status = 'pending'",
        [intentId],
      );
      _db.execute(
        'INSERT INTO edit_journal(entity_kind, guid, field, hlc, device_id, created_at) VALUES (?, ?, ?, ?, ?, ?)',
        [entityKind, guid, field, hlc, deviceId, _now()],
      );
      _db.execute('COMMIT');
    } catch (err) {
      _db.execute('ROLLBACK');
      rethrow;
    }
  }

  void abandonIntent(int intentId) {
    _db.execute(
      "UPDATE intent SET status = 'abandoned' WHERE id = ? AND status = 'pending'",
      [intentId],
    );
  }

  int pendingIntentCount() {
    final rows = _db.select(
      "SELECT COUNT(*) AS n FROM intent WHERE status = 'pending'",
    );
    return rows.first['n'] as int;
  }

  List<JournalRow> journalRows() {
    final rows = _db.select(
      'SELECT id, entity_kind, guid, field, hlc, device_id FROM edit_journal ORDER BY id',
    );
    return [
      for (final row in rows)
        JournalRow(
          id: row['id'] as int,
          entityKind: row['entity_kind'] as String,
          guid: row['guid'] as String,
          field: row['field'] as String?,
          hlc: row['hlc'] as String,
          deviceId: row['device_id'] as String,
        ),
    ];
  }

  void _migrate() {
    const statements = <String>[
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
    ];
    for (final statement in statements) {
      _db.execute(statement);
    }
    _db.execute(
      "INSERT INTO meta(key, value) VALUES ('schema_version', '1') ON CONFLICT(key) DO NOTHING",
    );
    _db.execute(
      "INSERT INTO meta(key, value) VALUES ('device_id', ?) ON CONFLICT(key) DO NOTHING",
      [deviceId],
    );
  }

  int _now() => DateTime.now().millisecondsSinceEpoch;
}

class JournalRow {
  const JournalRow({
    required this.id,
    required this.entityKind,
    required this.guid,
    required this.field,
    required this.hlc,
    required this.deviceId,
  });

  final int id;
  final String entityKind;
  final String guid;
  final String? field;
  final String hlc;
  final String deviceId;
}
