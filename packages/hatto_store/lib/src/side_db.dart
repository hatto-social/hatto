// SPDX-FileCopyrightText: 2026 Hatto Social contributors
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:sqlite3/sqlite3.dart';

import 'schema.dart';
import 'uuid.dart';

/// Hatto metadata stored outside the resident Anki collection.
///
/// The collection file stays an rslib database. This file is a draft at
/// [sideDbSchemaVersion]. `deck_map.server_unsynced` is the unsynced flag for
/// that deck. Notes, cards, and media do not store their own flag; they follow
/// the deck that owns them. For a note, that deck is `note_map.home_deck_guid`:
/// the ord-0 card's deck at import, or the lowest ord when there is no ord-0
/// card. A filtered card uses its original deck. `import_batch_id` groups
/// decks from one import. `source_sha256` names the copied apkg under
/// `<documents>/hatto/imports/`.
class SideDb {
  SideDb._(this._db, this.deviceId);

  final Database _db;
  final String deviceId;
  int _hlcCounter = 0;

  static const Object _exclusiveZone = Object();

  /// Tail of the write/reconcile queue. The next caller waits for this.
  Future<void> _turn = Future<void>.value();

  /// Runs [action] only after earlier writes and reconciles on this file.
  ///
  /// A call made from inside [action] throws. That call would wait for the
  /// outer one, and the outer one would wait for it. A call from another
  /// task waits its turn instead.
  Future<T> exclusive<T>(Future<T> Function() action) {
    if (Zone.current[_exclusiveZone] == true) {
      throw StateError('the side database queue is not reentrant');
    }
    final result = _turn.then((_) {
      return runZoned(action, zoneValues: {_exclusiveZone: true});
    });
    _turn = result.then((_) {}, onError: (_) {});
    return result;
  }

  static SideDb open({required String path, required String deviceId}) {
    File(path).parent.createSync(recursive: true);
    return _openHandle(sqlite3.open(path), providedDeviceId: deviceId);
  }

  /// Opens [path], creating the file and a UUIDv4 `meta.device_id` when
  /// that row is missing.
  ///
  /// The id already stored in the file is kept. Copying or restoring the
  /// data folder copies it, so two installs can share a device id. v0 does
  /// not sync and does not regenerate an id that is present. Doing so after
  /// a copy is a v1 question.
  static SideDb openOrCreate(String path) {
    File(path).parent.createSync(recursive: true);
    return _openHandle(sqlite3.open(path), providedDeviceId: null);
  }

  static SideDb openInMemory({String deviceId = 'test-device'}) {
    return _openHandle(sqlite3.openInMemory(), providedDeviceId: deviceId);
  }

  static SideDb _openHandle(Database db, {required String? providedDeviceId}) {
    try {
      applySideDbMigrations(db);
      final existing = _readDeviceId(db);
      final String id;
      if (existing != null) {
        id = existing;
      } else if (providedDeviceId != null) {
        if (providedDeviceId.isEmpty) {
          throw const SideDbException('device_id is empty');
        }
        id = providedDeviceId;
        _insertDeviceId(db, id);
      } else {
        id = newUuidV4();
        _insertDeviceId(db, id);
      }
      return SideDb._(db, id);
    } catch (err) {
      db.close();
      rethrow;
    }
  }

  static String? _readDeviceId(Database db) {
    final rows = db.select("SELECT value FROM meta WHERE key = 'device_id'");
    if (rows.isEmpty) {
      return null;
    }
    final value = rows.first['value'];
    if (value is! String || value.isEmpty) {
      throw const SideDbException('meta.device_id is empty');
    }
    return value;
  }

  static void _insertDeviceId(Database db, String deviceId) {
    db.execute("INSERT INTO meta(key, value) VALUES ('device_id', ?)", [
      deviceId,
    ]);
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

  /// Deletes the intent and, when [journal] is true, appends one journal row.
  ///
  /// [map] runs inside the same transaction, after the rslib response has
  /// been read by the caller and before the intent row is deleted. A throw
  /// rolls the transaction back and leaves the intent pending. [journal]
  /// defaults to true so existing mobile callers still append a row and an
  /// HLC. `field` is null in v0. When [journal] is false, no journal row and
  /// no HLC are written.
  Future<void> completeIntent({
    required int intentId,
    required String op,
    required String entityKind,
    required String guid,
    Uint8List? payload,
    bool journal = true,
    FutureOr<void> Function()? map,
  }) async {
    _db.execute('BEGIN IMMEDIATE');
    try {
      if (map != null) {
        await map();
      }
      final rows = _db.select('SELECT id FROM intent WHERE id = ?', [intentId]);
      if (rows.isEmpty) {
        throw SideDbException('intent $intentId is not pending');
      }
      _db.execute('DELETE FROM intent WHERE id = ?', [intentId]);
      if (journal) {
        final hlc = nextHlc();
        _db.execute(
          'INSERT INTO edit_journal(op, entity_kind, guid, field, hlc, payload) '
          'VALUES (?, ?, ?, NULL, ?, ?)',
          [op, entityKind, guid, hlc, payload],
        );
      }
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
  /// default, 1. [sourceSha256] is the imports file name, not a path.
  ///
  /// A note, card, or media file has no unsynced column. Use the flag of the
  /// deck that owns it. For a note, that is [NoteMapRow.homeDeckGuid].
  /// Replacing a row does not clear [DeckMapRow.deletedAt].
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

  /// Records [deletedAt] on [deckGuid]. The row stays in `deck_map`.
  ///
  /// A deleted deck is still a deck guid. [rewriteDeckGuid] and [importNote]
  /// match it, including when `deleted_at` is set. [putDeck] does not clear
  /// the time.
  void markDeckDeleted({required String deckGuid, required String deletedAt}) {
    if (deckGuid.isEmpty) {
      throw const SideDbException('deck guid is empty');
    }
    if (deletedAt.isEmpty) {
      throw const SideDbException('deleted_at is empty');
    }
    final rows = _db.select(
      'SELECT deck_guid FROM deck_map WHERE deck_guid = ?',
      [deckGuid],
    );
    if (rows.isEmpty) {
      throw SideDbException('deck $deckGuid is not in deck_map');
    }
    _db.execute('UPDATE deck_map SET deleted_at = ? WHERE deck_guid = ?', [
      deletedAt,
      deckGuid,
    ]);
  }

  /// Replaces [fromGuid] with [toGuid] on `deck_map` and on every note whose
  /// home deck is still [fromGuid].
  ///
  /// v1 upload calls this when a provisional deck guid becomes the server
  /// guid. One transaction: the note update is applied first, then the deck
  /// row, and a constraint failure rolls both back. The deck predicate is the
  /// guid only, so a deck with `deleted_at` set is rewritten with its notes.
  void rewriteDeckGuid({required String fromGuid, required String toGuid}) {
    if (fromGuid.isEmpty || toGuid.isEmpty) {
      throw const SideDbException('deck guid is empty');
    }
    _db.execute('BEGIN IMMEDIATE');
    try {
      final rows = _db.select(
        'SELECT deck_guid FROM deck_map WHERE deck_guid = ?',
        [fromGuid],
      );
      if (rows.isEmpty) {
        throw SideDbException('deck $fromGuid is not in deck_map');
      }
      _db.execute(
        'UPDATE note_map SET home_deck_guid = ? WHERE home_deck_guid = ?',
        [toGuid, fromGuid],
      );
      _db.execute('UPDATE deck_map SET deck_guid = ? WHERE deck_guid = ?', [
        toGuid,
        fromGuid,
      ]);
      _db.execute('COMMIT');
    } catch (err) {
      _db.execute('ROLLBACK');
      rethrow;
    }
  }

  DeckMapRow? deck(String deckGuid) {
    final rows = _db.select(
      'SELECT deck_guid, rslib_deck_id, import_batch_id, origin_kind, '
      'origin_role, source_sha256, server_unsynced, deleted_at FROM deck_map '
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
      'origin_role, source_sha256, server_unsynced, deleted_at FROM deck_map '
      'WHERE server_unsynced != 0 ORDER BY deck_guid',
    );
    return [for (final row in rows) _deckRow(row)];
  }

  /// Decks that share one import batch.
  List<DeckMapRow> decksForImport(String importBatchId) {
    final rows = _db.select(
      'SELECT deck_guid, rslib_deck_id, import_batch_id, origin_kind, '
      'origin_role, source_sha256, server_unsynced, deleted_at FROM deck_map '
      'WHERE import_batch_id = ? ORDER BY deck_guid',
      [importBatchId],
    );
    return [for (final row in rows) _deckRow(row)];
  }

  /// Maps an Anki note to a Hatto guid and records its home deck.
  ///
  /// [cards] are the note's cards at import. The home deck is the Hatto guid
  /// of the ord-0 card's deck when that card exists, otherwise the deck of the
  /// card with the lowest ord. A card in a filtered deck (`odid` not 0)
  /// contributes that original deck instead of its current deck. The deck id
  /// is resolved through `deck_map`.
  /// [noteGuid] is the Hatto guid and, for notes this app maps, the same
  /// value as rslib `notes.guid`. This method does not read the collection.
  ///
  /// The home deck is written only on the first insert. Calling this again
  /// for the same note after a card has moved does not change it. A second
  /// call with a different [rslibNoteId] is rejected.
  void importNote({
    required String noteGuid,
    required int rslibNoteId,
    required List<ImportedNoteCard> cards,
  }) {
    if (noteGuid.isEmpty) {
      throw const SideDbException('note guid is empty');
    }
    final existing = note(noteGuid);
    if (existing != null) {
      if (existing.rslibNoteId != rslibNoteId) {
        throw SideDbException(
          'note $noteGuid is already mapped to rslib note ${existing.rslibNoteId}',
        );
      }
      return;
    }
    final homeDeckGuid = _homeDeckGuidAtImport(cards);
    _db.execute(
      'INSERT INTO note_map(note_guid, rslib_note_id, home_deck_guid) '
      'VALUES (?, ?, ?)',
      [noteGuid, rslibNoteId, homeDeckGuid],
    );
  }

  NoteMapRow? note(String noteGuid) {
    final rows = _db.select(
      'SELECT note_guid, rslib_note_id, home_deck_guid FROM note_map '
      'WHERE note_guid = ?',
      [noteGuid],
    );
    if (rows.isEmpty) {
      return null;
    }
    return _noteRow(rows.first);
  }

  NoteMapRow? noteByRslibId(int rslibNoteId) {
    final rows = _db.select(
      'SELECT note_guid, rslib_note_id, home_deck_guid FROM note_map '
      'WHERE rslib_note_id = ?',
      [rslibNoteId],
    );
    if (rows.isEmpty) {
      return null;
    }
    return _noteRow(rows.first);
  }

  List<NoteMapRow> notes() {
    final rows = _db.select(
      'SELECT note_guid, rslib_note_id, home_deck_guid FROM note_map '
      'ORDER BY rslib_note_id',
    );
    return [for (final row in rows) _noteRow(row)];
  }

  List<DeckMapRow> decks() {
    final rows = _db.select(
      'SELECT deck_guid, rslib_deck_id, import_batch_id, origin_kind, '
      'origin_role, source_sha256, server_unsynced, deleted_at FROM deck_map '
      'ORDER BY rslib_deck_id',
    );
    return [for (final row in rows) _deckRow(row)];
  }

  DeckMapRow? deckByRslibId(int rslibDeckId) {
    final rows = _db.select(
      'SELECT deck_guid, rslib_deck_id, import_batch_id, origin_kind, '
      'origin_role, source_sha256, server_unsynced, deleted_at FROM deck_map '
      'WHERE rslib_deck_id = ?',
      [rslibDeckId],
    );
    if (rows.isEmpty) {
      return null;
    }
    return _deckRow(rows.first);
  }

  /// Home deck guid for [cards], using the same rule as [importNote].
  ///
  /// The deck must already be in `deck_map`.
  String homeDeckGuidFor(List<ImportedNoteCard> cards) {
    return _homeDeckGuidAtImport(cards);
  }

  /// Replaces the `note_map` row for [rslibNoteId].
  ///
  /// Used when the collection id is still there but its guid changed, so
  /// the old row is stale. One transaction: the old row is removed and the
  /// new one inserted, or neither is.
  void replaceNote({
    required String noteGuid,
    required int rslibNoteId,
    required String homeDeckGuid,
  }) {
    if (noteGuid.isEmpty) {
      throw const SideDbException('note guid is empty');
    }
    _db.execute('BEGIN IMMEDIATE');
    try {
      final rows = _db.select(
        'SELECT note_guid FROM note_map WHERE rslib_note_id = ?',
        [rslibNoteId],
      );
      if (rows.isEmpty) {
        throw SideDbException('rslib note $rslibNoteId is not in note_map');
      }
      _db.execute('DELETE FROM note_map WHERE rslib_note_id = ?', [
        rslibNoteId,
      ]);
      _db.execute(
        'INSERT INTO note_map(note_guid, rslib_note_id, home_deck_guid) '
        'VALUES (?, ?, ?)',
        [noteGuid, rslibNoteId, homeDeckGuid],
      );
      _db.execute('COMMIT');
    } catch (err) {
      _db.execute('ROLLBACK');
      rethrow;
    }
  }

  String _homeDeckGuidAtImport(List<ImportedNoteCard> cards) {
    final home = _homeCardAtImport(cards);
    final deckId = home.odid != 0 ? home.odid : home.rslibDeckId;
    final rows = _db.select(
      'SELECT deck_guid FROM deck_map WHERE rslib_deck_id = ?',
      [deckId],
    );
    if (rows.isEmpty) {
      throw SideDbException('home card deck $deckId is not in deck_map');
    }
    return rows.single['deck_guid'] as String;
  }

  /// Ord 0 when that card exists. Otherwise the unique lowest ord.
  ImportedNoteCard _homeCardAtImport(List<ImportedNoteCard> cards) {
    if (cards.isEmpty) {
      throw const SideDbException('note import has no cards');
    }
    final ord0 = [
      for (final card in cards)
        if (card.ord == 0) card,
    ];
    if (ord0.length > 1) {
      throw SideDbException(
        'note import needs exactly one ord-0 card, found ${ord0.length}',
      );
    }
    if (ord0.length == 1) {
      return ord0.single;
    }
    var lowest = cards.first;
    var ties = 1;
    for (final card in cards.skip(1)) {
      if (card.ord < lowest.ord) {
        lowest = card;
        ties = 1;
      } else if (card.ord == lowest.ord) {
        ties += 1;
      }
    }
    if (ties != 1) {
      throw SideDbException(
        'note import has $ties cards at the lowest ord ${lowest.ord}',
      );
    }
    return lowest;
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

  DeckMapRow _deckRow(Row row) {
    return DeckMapRow(
      deckGuid: row['deck_guid'] as String,
      rslibDeckId: row['rslib_deck_id'] as int,
      importBatchId: row['import_batch_id'] as String?,
      originKind: row['origin_kind'] as String?,
      originRole: row['origin_role'] as String?,
      sourceSha256: row['source_sha256'] as String?,
      serverUnsynced: (row['server_unsynced'] as int) != 0,
      deletedAt: row['deleted_at'] as String?,
    );
  }

  NoteMapRow _noteRow(Row row) {
    return NoteMapRow(
      noteGuid: row['note_guid'] as String,
      rslibNoteId: row['rslib_note_id'] as int,
      homeDeckGuid: row['home_deck_guid'] as String,
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
    required this.deletedAt,
  });

  final String deckGuid;
  final int rslibDeckId;
  final String? importBatchId;
  final String? originKind;
  final String? originRole;
  final String? sourceSha256;
  final bool serverUnsynced;

  /// Deletion time. Null while the deck is live.
  final String? deletedAt;
}

/// One card of a note at the moment that note is first imported.
class ImportedNoteCard {
  const ImportedNoteCard({
    required this.ord,
    required this.rslibDeckId,
    this.odid = 0,
  });

  /// Template ordinal. Import prefers ord 0, then the lowest ord on the note.
  final int ord;

  /// Anki `cards.did`, the deck the card is in now.
  final int rslibDeckId;

  /// Anki `cards.odid`. Non-zero when the card is in a filtered deck: the
  /// original deck, which is the one used for the home deck.
  final int odid;
}

/// `note_map` row. [noteGuid] is the Hatto guid. For a mapped note it is
/// the same value as rslib `notes.guid`.
class NoteMapRow {
  const NoteMapRow({
    required this.noteGuid,
    required this.rslibNoteId,
    required this.homeDeckGuid,
  });

  final String noteGuid;
  final int rslibNoteId;

  /// Hatto deck guid chosen at import. [SideDb.rewriteDeckGuid] is the only
  /// later writer.
  final String homeDeckGuid;
}
