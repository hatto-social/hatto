// SPDX-FileCopyrightText: 2026 Hatto Social contributors
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:io';

import 'import_archive.dart';
import 'import_engine.dart';
import 'import_intent.dart';
import 'intent_ops.dart';
import 'reconcile.dart';
import 'schema.dart';
import 'side_db.dart';
import 'uuid.dart';

/// Adopts committed import intents and deletes the rest.
///
/// The caller is inside [SideDb.exclusive], after [reconcileInTurn]. For
/// each pending `import` row this reads `expected` and not `pre`:
///
/// 1. `new_guids` is non-empty and at least one guid is in
///    [ReconcileResult.residentImportNotes]. That map is live resident
///    notes only. A stale `note_map` row does not count. The resident
///    import committed. Copy the raw package when it exists, then run the
///    adoption transaction.
/// 2. `new_guids` is empty, `changed` is not, and every resident content
///    hash equals `changed`. Same adoption.
/// 3. Otherwise the resident import did not commit, including when the
///    staged package is missing. Delete the intent. Leave `note_map` and
///    `deck_map` unchanged.
///
/// Adoption copies `<dataDir>/import/raw/<batch>.apkg` to
/// `<dataDir>/imports/<source_sha256>` before the database transaction, and
/// only when that raw file exists. The transaction upserts notes, inserts
/// decks with `INSERT OR IGNORE`, then deletes the intent. It does not
/// write `edit_journal`. `note_map` is upserted only for `new_guids`.
/// `changed` notes keep the home deck written at first mapping. A second
/// pass sees the same rows: the intent is already gone, and a deck that is
/// already mapped is not inserted again.
Future<void> recoverImports({
  required SideDb db,
  required AnkiApi anki,
  required ImportEngine engine,
  required ReconcileResult reconcile,
  required String dataDir,
}) async {
  db.requireExclusiveTurn('recoverImports');
  final pending = [
    for (final intent in db.pendingIntents())
      if (intent.op == intentImport) intent,
  ];
  for (final intent in pending) {
    final expected = decodeImportIntentExpected(intent.expected ?? '');
    // staged_sha256 and first_import are validated by the codec. Schema v1
    // has no column for them. pre is not read.
    final committed = await importCommitted(
      db: db,
      engine: engine,
      reconcile: reconcile,
      expected: expected,
    );
    if (!committed) {
      db.abandonIntent(intent.id);
      continue;
    }
    await adoptCommittedImport(
      db: db,
      anki: anki,
      engine: engine,
      expected: expected,
      batchId: intent.targetKey,
      intentId: intent.id,
      dataDir: dataDir,
      noteIdsByGuid: reconcile.residentImportNotes,
      reservedDeckIds: reconcile.reservedImportDecks,
    );
  }
}

/// Copies the archive, then upserts `new_guids` and inserts decks.
///
/// [recoverImports] and the import pipeline both use this. `note_map` is
/// upserted only for guids in [ImportIntentExpected.newGuids] that appear
/// in [noteIdsByGuid]. A `changed` note is not written, so its home deck
/// stays as first mapped. A `note_map` row that still holds the rslib id
/// under a different guid is removed in the same transaction before the
/// upsert. `deck_map` is `INSERT OR IGNORE` with `origin_kind` `import`,
/// `origin_role` null, `server_unsynced` 1, [batchId], and
/// `expected.source_sha256`. The intent row is deleted. `edit_journal` is
/// not written.
///
/// The archive copy runs before the database transaction. [sourceFile] is
/// the caller's original package. When it is null, the raw working copy
/// `<dataDir>/import/raw/<batchId>.apkg` is copied if that file exists.
/// [afterArchive] runs after that copy and before the transaction.
/// [beforeWrites] runs inside the transaction before those writes. It must
/// not start another transaction.
Future<void> adoptCommittedImport({
  required SideDb db,
  required AnkiApi anki,
  required ImportEngine engine,
  required ImportIntentExpected expected,
  required String batchId,
  required int intentId,
  required String dataDir,
  required Map<String, int> noteIdsByGuid,
  Map<String, int> reservedDeckIds = const {},
  File? sourceFile,
  Future<void> Function()? afterArchive,
  void Function()? beforeWrites,
}) async {
  db.requireExclusiveTurn('adoptCommittedImport');
  _archiveImport(
    dataDir: dataDir,
    batchId: batchId,
    sourceSha256: expected.sourceSha256,
    sourceFile: sourceFile,
  );
  final afterCopy = afterArchive;
  if (afterCopy != null) {
    await afterCopy();
  }
  final guidByDeckId = <int, String>{};
  final inserts = <_PendingDeck>[];
  final seenDeckIds = <int>{};
  for (final name in expected.deckNames) {
    final reserved = reservedDeckIds[name];
    final id = reserved ?? await engine.deckIdByName(name);
    if (id == null) {
      throw SideDbException('import deck "$name" is not in the collection');
    }
    if (!seenDeckIds.add(id)) {
      continue;
    }
    final existing = db.deckByRslibId(id);
    if (existing != null) {
      // v0 reuses this soft-deleted row; clearing deleted_at waits for v1 sync.
      guidByDeckId[id] = existing.deckGuid;
      continue;
    }
    final guid = newUuidV4();
    guidByDeckId[id] = guid;
    inserts.add(_PendingDeck(guid, id));
  }

  final notes = <_PendingNote>[];
  final seenGuids = <String>{};
  for (final guid in expected.newGuids) {
    if (!seenGuids.add(guid)) {
      continue;
    }
    final id = noteIdsByGuid[guid];
    if (id == null) {
      continue;
    }
    final cards = await _cardsOf(anki, id);
    final homeId = db.homeRslibDeckIdFor(cards);
    final homeGuid = guidByDeckId[homeId] ?? db.deckByRslibId(homeId)?.deckGuid;
    if (homeGuid == null) {
      throw SideDbException('home card deck $homeId is not in deck_map');
    }
    notes.add(_PendingNote(guid, id, homeGuid));
  }

  db.inImmediateTransaction(() {
    beforeWrites?.call();
    for (final note in notes) {
      final holder = db.noteByRslibId(note.id);
      if (holder != null && holder.noteGuid != note.guid) {
        db.deleteNoteMapByRslibId(note.id);
      }
      db.upsertImportedNote(
        noteGuid: note.guid,
        rslibNoteId: note.id,
        homeDeckGuid: note.homeGuid,
      );
    }
    for (final deck in inserts) {
      db.insertImportedDeck(
        deckGuid: deck.guid,
        rslibDeckId: deck.rslibDeckId,
        importBatchId: batchId,
        sourceSha256: expected.sourceSha256,
      );
    }
    db.abandonIntent(intentId);
  });
}

/// Whether [expected] is already in the resident collection.
///
/// [recoverImports] and [ImportPipeline] both use this after
/// [reconcileInTurn]. Branch 1 is a live guid in
/// [ReconcileResult.residentImportNotes]. Branch 2 is an empty `new_guids`
/// list whose `changed` hashes all match the resident notes.
Future<bool> importCommitted({
  required SideDb db,
  required ImportEngine engine,
  required ReconcileResult reconcile,
  required ImportIntentExpected expected,
}) async {
  if (expected.newGuids.isNotEmpty) {
    for (final guid in expected.newGuids) {
      if (reconcile.residentImportNotes.containsKey(guid)) {
        return true;
      }
    }
    return false;
  }
  if (expected.changed.isEmpty) {
    return false;
  }
  final rows = db.notesByGuids(expected.changed.keys.toList());
  if (rows.length != expected.changed.length) {
    return false;
  }
  final ids = <int>[
    for (final guid in expected.changed.keys) rows[guid]!.rslibNoteId,
  ];
  final match = await engine.residentLookup(
    noteIds: ids,
    deckNames: expected.deckNames,
  );
  final hashes = <String, String>{
    for (final note in match.notes) note.guid: note.contentHashHex,
  };
  for (final entry in expected.changed.entries) {
    final resident = hashes[entry.key];
    if (resident == null || resident != entry.value) {
      return false;
    }
  }
  return true;
}

void _archiveImport({
  required String dataDir,
  required String batchId,
  required String sourceSha256,
  File? sourceFile,
}) {
  final File source;
  if (sourceFile != null) {
    source = sourceFile;
    if (!source.existsSync()) {
      throw SideDbException('import source is missing: ${source.path}');
    }
  } else {
    final raw = File(importRawApkgPath(dataDir, batchId));
    if (!raw.existsSync()) {
      return;
    }
    source = raw;
  }
  final digest = storeImportArchive(dataDir: dataDir, source: source);
  if (digest != sourceSha256) {
    // v0 leaves the orphan copy under the actual digest.
    throw SideDbException('apkg sha256 does not match expected.source_sha256');
  }
}

Future<List<ImportedNoteCard>> _cardsOf(AnkiApi anki, int noteId) async {
  final refs = await anki.cardsOfNote(noteId);
  final cards = <ImportedNoteCard>[];
  for (final ref in refs) {
    final card = await anki.getCard(ref.id);
    cards.add(
      ImportedNoteCard(ord: ref.ord, rslibDeckId: card.deckId, odid: card.odid),
    );
  }
  return cards;
}

class _PendingDeck {
  const _PendingDeck(this.guid, this.rslibDeckId);

  final String guid;
  final int rslibDeckId;
}

class _PendingNote {
  const _PendingNote(this.guid, this.id, this.homeGuid);

  final String guid;
  final int id;
  final String homeGuid;
}
