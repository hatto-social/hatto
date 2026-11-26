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
///    [ReconcileResult.reservedImportNotes] or `note_map`. The resident
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
/// write `edit_journal`. A second pass sees the same rows: the intent is
/// already gone, and a deck that is already mapped is not inserted again.
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
    final committed = await _importCommitted(
      db: db,
      engine: engine,
      reconcile: reconcile,
      expected: expected,
    );
    if (!committed) {
      db.abandonIntent(intent.id);
      continue;
    }
    await _adoptImport(
      db: db,
      anki: anki,
      engine: engine,
      reconcile: reconcile,
      expected: expected,
      batchId: intent.targetKey,
      intentId: intent.id,
      dataDir: dataDir,
    );
  }
}

Future<bool> _importCommitted({
  required SideDb db,
  required ImportEngine engine,
  required ReconcileResult reconcile,
  required ImportIntentExpected expected,
}) async {
  if (expected.newGuids.isNotEmpty) {
    for (final guid in expected.newGuids) {
      if (reconcile.reservedImportNotes.containsKey(guid) ||
          db.note(guid) != null) {
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

Future<void> _adoptImport({
  required SideDb db,
  required AnkiApi anki,
  required ImportEngine engine,
  required ReconcileResult reconcile,
  required ImportIntentExpected expected,
  required String batchId,
  required int intentId,
  required String dataDir,
}) async {
  _copyRawArchive(
    dataDir: dataDir,
    batchId: batchId,
    sourceSha256: expected.sourceSha256,
  );
  final guidByDeckId = <int, String>{};
  final inserts = <_PendingDeck>[];
  final seenDeckIds = <int>{};
  for (final name in expected.deckNames) {
    final reserved = reconcile.reservedImportDecks[name];
    final id = reserved ?? await engine.deckIdByName(name);
    if (id == null) {
      throw SideDbException('import deck "$name" is not in the collection');
    }
    if (!seenDeckIds.add(id)) {
      continue;
    }
    final existing = db.deckByRslibId(id);
    if (existing != null) {
      // A live row is reused. A soft-deleted row keeps this rslib id, so a
      // second row cannot be inserted. The soft-deleted row is not updated.
      guidByDeckId[id] = existing.deckGuid;
      continue;
    }
    final guid = newUuidV4();
    guidByDeckId[id] = guid;
    inserts.add(_PendingDeck(guid, id));
  }

  final notes = <_PendingNote>[];
  final seenGuids = <String>{};
  for (final guid in [...expected.newGuids, ...expected.changed.keys]) {
    if (!seenGuids.add(guid)) {
      continue;
    }
    final id =
        reconcile.reservedImportNotes[guid] ?? db.note(guid)?.rslibNoteId;
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
    for (final note in notes) {
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

void _copyRawArchive({
  required String dataDir,
  required String batchId,
  required String sourceSha256,
}) {
  final raw = File(importRawApkgPath(dataDir, batchId));
  if (!raw.existsSync()) {
    return;
  }
  final digest = storeImportArchive(dataDir: dataDir, source: raw);
  if (digest != sourceSha256) {
    throw SideDbException(
      'raw apkg sha256 does not match expected.source_sha256',
    );
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
