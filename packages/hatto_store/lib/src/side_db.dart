import 'dart:io';

import 'package:sqlite3/sqlite3.dart';

import 'schema.dart';

/// Draft unit kind for [SideDb.markServerUnsynced]. A deck guid.
const String sideDbUnitDeck = 'deck';

/// Draft unit kind for [SideDb.markServerUnsynced]. An import batch id.
const String sideDbUnitImport = 'import';

/// Hatto metadata stored outside the resident Anki collection.
///
/// The collection file stays an rslib database. This file is a draft: schema
/// version, `revlog_origin`, deck/import `server_unsynced` markers, and the
/// write-wrapper intent journal. Skeleton guid maps and media keys are still
/// created and are not a stable contract. `deck_map.server_unsynced` is not
/// written; the marker table is.
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

  List<IntentRow> pendingIntents() {
    final rows = _db.select(
      'SELECT id, op, target_key, expected, status, created_at FROM intent '
      "WHERE status = 'pending' ORDER BY id",
    );
    return [
      for (final row in rows)
        IntentRow(
          id: row['id'] as int,
          op: row['op'] as String,
          targetKey: row['target_key'] as String,
          expected: row['expected'] as String?,
          status: row['status'] as String,
          createdAt: row['created_at'] as int,
        ),
    ];
  }

  /// Records the draft origin label for one revlog id.
  ///
  /// [job] is the import or optimizer job that produced the row. The same
  /// pair is ignored the second time.
  void putRevlogOrigin({required int revlogId, required String job}) {
    if (job.isEmpty) {
      throw const SideDbException('revlog origin job is empty');
    }
    _db.execute(
      'INSERT INTO revlog_origin(revlog_id, job) VALUES (?, ?) '
      'ON CONFLICT(revlog_id, job) DO NOTHING',
      [revlogId, job],
    );
  }

  List<RevlogOriginRow> revlogOrigins({int? revlogId}) {
    final rows = revlogId == null
        ? _db.select(
            'SELECT revlog_id, job FROM revlog_origin ORDER BY revlog_id, job',
          )
        : _db.select(
            'SELECT revlog_id, job FROM revlog_origin WHERE revlog_id = ? ORDER BY job',
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

  void deleteRevlogOrigin({required int revlogId, required String job}) {
    _db.execute('DELETE FROM revlog_origin WHERE revlog_id = ? AND job = ?', [
      revlogId,
      job,
    ]);
  }

  /// Marks a deck guid or an import batch as not reflected on a server.
  ///
  /// v0 has no server. The flag is local state for a later sync. [unitKind]
  /// is [sideDbUnitDeck] or [sideDbUnitImport].
  void markServerUnsynced({required String unitKind, required String unitKey}) {
    _checkUnit(unitKind, unitKey);
    _db.execute(
      'INSERT INTO server_unsynced(unit_kind, unit_key, marked_at) VALUES (?, ?, ?) '
      'ON CONFLICT(unit_kind, unit_key) DO UPDATE SET marked_at = excluded.marked_at',
      [unitKind, unitKey, _now()],
    );
  }

  void clearServerUnsynced({
    required String unitKind,
    required String unitKey,
  }) {
    _checkUnit(unitKind, unitKey);
    _db.execute(
      'DELETE FROM server_unsynced WHERE unit_kind = ? AND unit_key = ?',
      [unitKind, unitKey],
    );
  }

  bool isServerUnsynced({required String unitKind, required String unitKey}) {
    _checkUnit(unitKind, unitKey);
    final rows = _db.select(
      'SELECT 1 AS n FROM server_unsynced WHERE unit_kind = ? AND unit_key = ?',
      [unitKind, unitKey],
    );
    return rows.isNotEmpty;
  }

  List<ServerUnsyncedRow> serverUnsyncedRows({String? unitKind}) {
    if (unitKind != null) {
      _checkUnitKind(unitKind);
    }
    final rows = unitKind == null
        ? _db.select(
            'SELECT unit_kind, unit_key, marked_at FROM server_unsynced '
            'ORDER BY unit_kind, unit_key',
          )
        : _db.select(
            'SELECT unit_kind, unit_key, marked_at FROM server_unsynced '
            'WHERE unit_kind = ? ORDER BY unit_key',
            [unitKind],
          );
    return [
      for (final row in rows)
        ServerUnsyncedRow(
          unitKind: row['unit_kind'] as String,
          unitKey: row['unit_key'] as String,
          markedAt: row['marked_at'] as int,
        ),
    ];
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
    applySideDbMigrations(_db);
    _db.execute(
      "INSERT INTO meta(key, value) VALUES ('device_id', ?) ON CONFLICT(key) DO NOTHING",
      [deviceId],
    );
  }

  void _checkUnit(String unitKind, String unitKey) {
    _checkUnitKind(unitKind);
    if (unitKey.isEmpty) {
      throw const SideDbException('server-unsynced unit key is empty');
    }
  }

  void _checkUnitKind(String unitKind) {
    if (unitKind != sideDbUnitDeck && unitKind != sideDbUnitImport) {
      throw SideDbException('unknown server-unsynced unit kind: $unitKind');
    }
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

class IntentRow {
  const IntentRow({
    required this.id,
    required this.op,
    required this.targetKey,
    required this.expected,
    required this.status,
    required this.createdAt,
  });

  final int id;
  final String op;
  final String targetKey;
  final String? expected;
  final String status;
  final int createdAt;
}

class RevlogOriginRow {
  const RevlogOriginRow({required this.revlogId, required this.job});

  final int revlogId;
  final String job;
}

class ServerUnsyncedRow {
  const ServerUnsyncedRow({
    required this.unitKind,
    required this.unitKey,
    required this.markedAt,
  });

  final String unitKind;
  final String unitKey;
  final int markedAt;
}
