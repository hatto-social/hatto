import 'dart:io';
import 'dart:typed_data';

import 'package:sqlite3/sqlite3.dart';

import 'schema.dart';

/// Hatto metadata stored outside the resident Anki collection.
///
/// The collection file stays an rslib database. This file is a draft at
/// [sideDbSchemaVersion]. `deck_map.server_unsynced` is the unsynced flag.
/// `import_batch_id` groups decks from one import.
class SideDb {
  SideDb._(this._db, this.deviceId);

  final Database _db;
  final String deviceId;
  int _hlcCounter = 0;

  static SideDb open({required String path, required String deviceId}) {
    final file = File(path);
    file.parent.createSync(recursive: true);
    return _finishOpen(sqlite3.open(path), deviceId);
  }

  static SideDb openInMemory({String deviceId = 'test-device'}) {
    return _finishOpen(sqlite3.openInMemory(), deviceId);
  }

  static SideDb _finishOpen(Database db, String deviceId) {
    try {
      final side = SideDb._(db, deviceId);
      side._migrate();
      return side;
    } catch (err) {
      db.close();
      rethrow;
    }
  }

  void close() => _db.close();

  /// `PRAGMA user_version` after migrations. Matches [sideDbSchemaVersion]
  /// for a file this build opened.
  int get schemaVersion => readUserVersion(_db);

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
        'INSERT INTO intent(op, target_key, expected) VALUES (?, ?, ?)',
        [op, targetKey, expected],
      );
      final id = _db.lastInsertRowId;
      _db.execute('COMMIT');
      return id;
    } catch (err) {
      _db.execute('ROLLBACK');
      rethrow;
    }
  }

  /// Deletes the intent and appends one journal row. `field` is null in v0.
  void completeIntent({
    required int intentId,
    required String op,
    required String entityKind,
    required String guid,
    Uint8List? payload,
  }) {
    final hlc = nextHlc();
    _db.execute('BEGIN IMMEDIATE');
    try {
      final rows = _db.select('SELECT id FROM intent WHERE id = ?', [intentId]);
      if (rows.isEmpty) {
        throw SideDbException('intent $intentId is not pending');
      }
      _db.execute('DELETE FROM intent WHERE id = ?', [intentId]);
      _db.execute(
        'INSERT INTO edit_journal(op, entity_kind, guid, field, hlc, payload) '
        'VALUES (?, ?, ?, NULL, ?, ?)',
        [op, entityKind, guid, hlc, payload],
      );
      _db.execute('COMMIT');
    } catch (err) {
      _db.execute('ROLLBACK');
      rethrow;
    }
  }

  void abandonIntent(int intentId) {
    final rows = _db.select('SELECT id FROM intent WHERE id = ?', [intentId]);
    if (rows.isEmpty) {
      throw SideDbException('intent $intentId is not pending');
    }
    _db.execute('DELETE FROM intent WHERE id = ?', [intentId]);
  }

  int pendingIntentCount() {
    final rows = _db.select('SELECT COUNT(*) AS n FROM intent');
    return rows.first['n'] as int;
  }

  List<IntentRow> pendingIntents() {
    final rows = _db.select(
      'SELECT id, op, target_key, expected FROM intent ORDER BY id',
    );
    return [
      for (final row in rows)
        IntentRow(
          id: row['id'] as int,
          op: row['op'] as String,
          targetKey: row['target_key'] as String,
          expected: row['expected'] as String?,
        ),
    ];
  }

  void putRevlogOrigin({required int revlogId, required String job}) {
    if (job.isEmpty) {
      throw const SideDbException('revlog origin job is empty');
    }
    _db.execute(
      'INSERT INTO revlog_origin(revlog_id, job) VALUES (?, ?) '
      'ON CONFLICT(revlog_id) DO UPDATE SET job = excluded.job',
      [revlogId, job],
    );
  }

  List<RevlogOriginRow> revlogOrigins({int? revlogId}) {
    final rows = revlogId == null
        ? _db.select(
            'SELECT revlog_id, job FROM revlog_origin ORDER BY revlog_id',
          )
        : _db.select(
            'SELECT revlog_id, job FROM revlog_origin WHERE revlog_id = ?',
            [revlogId],
          );
    return [
      for (final row in rows)
        RevlogOriginRow(
          revlogId: row['revlog_id'] as int,
          job: row['job'] as String,
        ),
    ];
  }

  void deleteRevlogOrigin(int revlogId) {
    _db.execute('DELETE FROM revlog_origin WHERE revlog_id = ?', [revlogId]);
  }

  /// Inserts or replaces one deck. [serverUnsynced] defaults to the column
  /// default, 1.
  void putDeck({
    required String deckGuid,
    required int rslibDeckId,
    String? importBatchId,
    String? originKind,
    String? originRole,
    String? sourceSha256,
    bool serverUnsynced = true,
  }) {
    if (deckGuid.isEmpty) {
      throw const SideDbException('deck guid is empty');
    }
    _db.execute(
      'INSERT INTO deck_map(deck_guid, rslib_deck_id, import_batch_id, '
      'origin_kind, origin_role, source_sha256, server_unsynced) '
      'VALUES (?, ?, ?, ?, ?, ?, ?) '
      'ON CONFLICT(deck_guid) DO UPDATE SET '
      'rslib_deck_id = excluded.rslib_deck_id, '
      'import_batch_id = excluded.import_batch_id, '
      'origin_kind = excluded.origin_kind, '
      'origin_role = excluded.origin_role, '
      'source_sha256 = excluded.source_sha256, '
      'server_unsynced = excluded.server_unsynced',
      [
        deckGuid,
        rslibDeckId,
        importBatchId,
        originKind,
        originRole,
        sourceSha256,
        serverUnsynced ? 1 : 0,
      ],
    );
  }

  void setDeckServerUnsynced({
    required String deckGuid,
    required bool unsynced,
  }) {
    if (deckGuid.isEmpty) {
      throw const SideDbException('deck guid is empty');
    }
    _db.execute('UPDATE deck_map SET server_unsynced = ? WHERE deck_guid = ?', [
      unsynced ? 1 : 0,
      deckGuid,
    ]);
    if (_db.updatedRows == 0) {
      throw SideDbException('deck $deckGuid is not in deck_map');
    }
  }

  DeckMapRow? deck(String deckGuid) {
    final rows = _db.select(
      'SELECT deck_guid, rslib_deck_id, import_batch_id, origin_kind, '
      'origin_role, source_sha256, server_unsynced FROM deck_map '
      'WHERE deck_guid = ?',
      [deckGuid],
    );
    if (rows.isEmpty) {
      return null;
    }
    return _deckRow(rows.first);
  }

  bool deckServerUnsynced(String deckGuid) {
    final row = deck(deckGuid);
    if (row == null) {
      throw SideDbException('deck $deckGuid is not in deck_map');
    }
    return row.serverUnsynced;
  }

  List<DeckMapRow> unsyncedDecks() {
    final rows = _db.select(
      'SELECT deck_guid, rslib_deck_id, import_batch_id, origin_kind, '
      'origin_role, source_sha256, server_unsynced FROM deck_map '
      'WHERE server_unsynced != 0 ORDER BY deck_guid',
    );
    return [for (final row in rows) _deckRow(row)];
  }

  /// Decks that share one import batch.
  List<DeckMapRow> decksForImport(String importBatchId) {
    final rows = _db.select(
      'SELECT deck_guid, rslib_deck_id, import_batch_id, origin_kind, '
      'origin_role, source_sha256, server_unsynced FROM deck_map '
      'WHERE import_batch_id = ? ORDER BY deck_guid',
      [importBatchId],
    );
    return [for (final row in rows) _deckRow(row)];
  }

  List<JournalRow> journalRows() {
    final rows = _db.select(
      'SELECT id, op, entity_kind, guid, field, hlc, payload '
      'FROM edit_journal ORDER BY id',
    );
    return [
      for (final row in rows)
        JournalRow(
          id: row['id'] as int,
          op: row['op'] as String,
          entityKind: row['entity_kind'] as String,
          guid: row['guid'] as String,
          field: row['field'] as String?,
          hlc: row['hlc'] as String,
          payload: row['payload'] as Uint8List?,
        ),
    ];
  }

  void _migrate() {
    applySideDbMigrations(_db);
    _db.execute(
      "INSERT INTO meta(key, value) VALUES ('device_id', ?) "
      'ON CONFLICT(key) DO NOTHING',
      [deviceId],
    );
  }

  DeckMapRow _deckRow(Row row) {
    return DeckMapRow(
      deckGuid: row['deck_guid'] as String,
      rslibDeckId: row['rslib_deck_id'] as int,
      importBatchId: row['import_batch_id'] as String?,
      originKind: row['origin_kind'] as String?,
      originRole: row['origin_role'] as String?,
      sourceSha256: row['source_sha256'] as String?,
      serverUnsynced: (row['server_unsynced'] as int) != 0,
    );
  }
}

class JournalRow {
  const JournalRow({
    required this.id,
    required this.op,
    required this.entityKind,
    required this.guid,
    required this.field,
    required this.hlc,
    required this.payload,
  });

  final int id;
  final String op;
  final String entityKind;
  final String guid;
  final String? field;
  final String hlc;
  final Uint8List? payload;
}

class IntentRow {
  const IntentRow({
    required this.id,
    required this.op,
    required this.targetKey,
    required this.expected,
  });

  final int id;
  final String op;
  final String targetKey;
  final String? expected;
}

class RevlogOriginRow {
  const RevlogOriginRow({required this.revlogId, required this.job});

  final int revlogId;
  final String job;
}

class DeckMapRow {
  const DeckMapRow({
    required this.deckGuid,
    required this.rslibDeckId,
    required this.importBatchId,
    required this.originKind,
    required this.originRole,
    required this.sourceSha256,
    required this.serverUnsynced,
  });

  final String deckGuid;
  final int rslibDeckId;
  final String? importBatchId;
  final String? originKind;
  final String? originRole;
  final String? sourceSha256;
  final bool serverUnsynced;
}
