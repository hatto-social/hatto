// SPDX-FileCopyrightText: 2026 Hatto Social contributors
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:convert';

import 'intent_ops.dart';
import 'schema.dart';
import 'side_db.dart';
import 'uuid.dart';

/// Collection reads reconciliation needs.
///
/// Desktop and mobile inject their own Anki facade. This module does not
/// open rslib and does not import the bridge, so a host test can pass a fake.
abstract interface class AnkiApi {
  /// Every note id. An empty search, built by the host's search builder.
  Future<List<int>> searchNoteIds();

  Future<CollectionNote> getNote(int id);

  Future<List<CollectionCardRef>> cardsOfNote(int noteId);

  Future<CollectionCard> getCard(int cardId);

  /// Every deck as `(id, full name path)`.
  Future<List<CollectionDeck>> deckTree();
}

class CollectionNote {
  const CollectionNote({required this.id, required this.guid});

  final int id;

  /// rslib `notes.guid`. For a mapped note this is `note_map.note_guid`.
  final String guid;
}

class CollectionCardRef {
  const CollectionCardRef({required this.id, required this.ord});

  final int id;
  final int ord;
}

class CollectionCard {
  const CollectionCard({required this.id, required this.deckId, this.odid = 0});

  final int id;

  /// Anki `cards.did`.
  final int deckId;

  /// Anki `cards.odid`. Non-zero when the card sits in a filtered deck.
  final int odid;
}

class CollectionDeck {
  const CollectionDeck({required this.id, required this.name});

  final int id;

  /// Full name, with `::` between parents and the deck.
  final String name;
}

/// Adopts [rslibDeckId] when `deck_map` has no row for it.
///
/// A deck that is already mapped is returned unchanged, including its guid.
/// A new row uses [reservedGuids] (name → guid from a pending `deck.add`
/// intent) or a new UUIDv4. [originKind] is `editor` unless the caller
/// passes another value. Running this twice returns the same row.
Future<DeckMapRow> ensureDeckMapped({
  required SideDb db,
  required AnkiApi anki,
  required int rslibDeckId,
  List<CollectionDeck>? decks,
  Map<String, String>? reservedGuids,
  String originKind = 'editor',
}) {
  return adoptDeck(
    db: db,
    anki: anki,
    rslibDeckId: rslibDeckId,
    decks: decks,
    reservedGuids: reservedGuids,
    originKind: originKind,
  );
}

/// Inserts a `deck_map` row for [rslibDeckId], or returns the existing row.
Future<DeckMapRow> adoptDeck({
  required SideDb db,
  required AnkiApi anki,
  required int rslibDeckId,
  List<CollectionDeck>? decks,
  Map<String, String>? reservedGuids,
  String originKind = 'editor',
}) async {
  final existing = db.deckByRslibId(rslibDeckId);
  if (existing != null) {
    return existing;
  }
  final tree = decks ?? await anki.deckTree();
  CollectionDeck? match;
  for (final deck in tree) {
    if (deck.id == rslibDeckId) {
      match = deck;
      break;
    }
  }
  if (match == null) {
    throw SideDbException('deck $rslibDeckId is not in the deck tree');
  }
  final reserved = reservedGuids?[match.name];
  final guid = (reserved != null && reserved.isNotEmpty)
      ? reserved
      : newUuidV4();
  if (db.deck(guid) != null) {
    throw SideDbException('deck guid $guid is already mapped');
  }
  db.putDeck(deckGuid: guid, rslibDeckId: rslibDeckId, originKind: originKind);
  return db.deck(guid)!;
}

/// A note search returned that has no cards.
///
/// Reconciliation records it and continues. `home_deck_guid` stays required,
/// so the note is not inserted.
class CardlessNote extends SideDbException {
  const CardlessNote(this.rslibNoteId)
    : super('note $rslibNoteId has no cards');

  final int rslibNoteId;
}

/// One note left out of `note_map` during a reconcile pass.
class SkippedNote {
  const SkippedNote({required this.rslibNoteId, required this.reason});

  final int rslibNoteId;

  /// Why the note was not adopted. v0 uses `no cards`.
  final String reason;
}

/// Result of one [reconcileCollection] pass.
class ReconcileResult {
  const ReconcileResult({required this.skippedNotes});

  final List<SkippedNote> skippedNotes;
}

/// Maps [rslibNoteId] to rslib's guid and a home deck.
///
/// The home deck is the ord-0 card's deck, or the lowest ord when there is
/// no ord-0 card. A filtered card contributes `odid`. That deck is adopted
/// first. A second call with the same guid does not change the home deck.
/// The same id with a different guid replaces the row: the old row belonged
/// to a note that is no longer in the collection. A note with no cards
/// throws [CardlessNote] and writes nothing.
Future<NoteMapRow> adoptNote({
  required SideDb db,
  required AnkiApi anki,
  required int rslibNoteId,
  List<CollectionDeck>? decks,
  Map<String, String>? reservedGuids,
}) async {
  final note = await anki.getNote(rslibNoteId);
  final existing = db.noteByRslibId(rslibNoteId);
  if (existing != null && existing.noteGuid == note.guid) {
    return existing;
  }
  final refs = await anki.cardsOfNote(rslibNoteId);
  if (refs.isEmpty) {
    throw CardlessNote(rslibNoteId);
  }
  final imported = <ImportedNoteCard>[];
  for (final ref in refs) {
    final card = await anki.getCard(ref.id);
    imported.add(
      ImportedNoteCard(ord: ref.ord, rslibDeckId: card.deckId, odid: card.odid),
    );
  }
  for (final card in imported) {
    await ensureDeckMapped(
      db: db,
      anki: anki,
      rslibDeckId: card.rslibDeckId,
      decks: decks,
      reservedGuids: reservedGuids,
    );
    if (card.odid != 0) {
      await ensureDeckMapped(
        db: db,
        anki: anki,
        rslibDeckId: card.odid,
        decks: decks,
        reservedGuids: reservedGuids,
      );
    }
  }
  if (existing != null) {
    db.replaceNote(
      noteGuid: note.guid,
      rslibNoteId: rslibNoteId,
      homeDeckGuid: db.homeDeckGuidFor(imported),
    );
  } else {
    final byGuid = db.note(note.guid);
    if (byGuid != null && byGuid.rslibNoteId != rslibNoteId) {
      throw SideDbException(
        'guid ${note.guid} is already mapped to rslib note ${byGuid.rslibNoteId}',
      );
    }
    db.importNote(
      noteGuid: note.guid,
      rslibNoteId: rslibNoteId,
      cards: imported,
    );
  }
  return db.note(note.guid)!;
}

/// One pass over the collection and the side database.
///
/// A note with no cards is recorded on [ReconcileResult.skippedNotes] and
/// does not abort the pass. It is not inserted, because `home_deck_guid`
/// is required.
///
/// Unmapped decks are adopted (a pending `deck.add` intent supplies the guid
/// when its name matches). Unmapped notes are adopted from `GetNote`'s guid.
/// A mapped id whose guid differs is replaced. Mapped ids that are gone stay
/// in the map. Known intents are then dropped. An intent whose `expected`
/// JSON is not the v0 object is left in place.
///
/// A second call sees the same rows. The module does not delete user data
/// to get there.
///
/// Guid conflicts are found by reading `GetNote` for mapped ids as well as
/// unmapped ones. The contract also says the normal path only reads unmapped
/// notes. Both sentences are implemented as the conflict line: every live
/// mapped id is compared. The cost of that read on a large collection is
/// still an open question.
Future<ReconcileResult> reconcileCollection({
  required SideDb db,
  required AnkiApi anki,
}) {
  return db.exclusive(() => _reconcile(db: db, anki: anki));
}

Future<ReconcileResult> _reconcile({
  required SideDb db,
  required AnkiApi anki,
}) async {
  final tree = await anki.deckTree();
  final reserved = _reservedDeckGuids(db.pendingIntents());
  final mappedDeckIds = {for (final row in db.decks()) row.rslibDeckId};
  for (final deck in tree) {
    if (mappedDeckIds.contains(deck.id)) {
      continue;
    }
    await adoptDeck(
      db: db,
      anki: anki,
      rslibDeckId: deck.id,
      decks: tree,
      reservedGuids: reserved,
    );
  }
  final liveIds = (await anki.searchNoteIds()).toSet();
  final skipped = <SkippedNote>[];
  for (final id in liveIds) {
    final row = db.noteByRslibId(id);
    if (row == null) {
      await _adoptOrSkip(
        skipped: skipped,
        db: db,
        anki: anki,
        rslibNoteId: id,
        decks: tree,
        reservedGuids: reserved,
      );
      continue;
    }
    final note = await anki.getNote(id);
    if (note.guid != row.noteGuid) {
      await _adoptOrSkip(
        skipped: skipped,
        db: db,
        anki: anki,
        rslibNoteId: id,
        decks: tree,
        reservedGuids: reserved,
      );
    }
  }
  for (final intent in db.pendingIntents()) {
    if (_intentIsSettled(db, intent, tree, liveIds)) {
      db.abandonIntent(intent.id);
    }
  }
  return ReconcileResult(skippedNotes: skipped);
}

/// Adopts [rslibNoteId]. A cardless note is recorded in [skipped] and does
/// not fail the pass. Returns false when the note was skipped.
Future<bool> _adoptOrSkip({
  required List<SkippedNote> skipped,
  required SideDb db,
  required AnkiApi anki,
  required int rslibNoteId,
  required List<CollectionDeck> decks,
  required Map<String, String> reservedGuids,
}) async {
  try {
    await adoptNote(
      db: db,
      anki: anki,
      rslibNoteId: rslibNoteId,
      decks: decks,
      reservedGuids: reservedGuids,
    );
    return true;
  } on CardlessNote catch (err) {
    skipped.add(SkippedNote(rslibNoteId: err.rslibNoteId, reason: 'no cards'));
    return false;
  }
}

Map<String, String> _reservedDeckGuids(List<IntentRow> intents) {
  final reserved = <String, String>{};
  for (final intent in intents) {
    if (intent.op != intentDeckAdd) {
      continue;
    }
    final expected = _expectedObject(intent.expected);
    if (expected == null) {
      continue;
    }
    final name = expected['name'];
    final guid = expected['deck_guid'];
    if (name is String &&
        name.isNotEmpty &&
        guid is String &&
        guid.isNotEmpty) {
      reserved.putIfAbsent(name, () => guid);
    }
  }
  return reserved;
}

/// True when the intent is a known v0 op that reconcile has already
/// accounted for. Unknown ops, and `note.add` / `deck.add` rows whose
/// `expected` is not a v0 object, stay pending.
///
/// `note.add` / `deck.add` are dropped both when the rslib change is
/// missing (the call never committed) and when the new row was adopted.
/// They stay if a live row of that name or guid is still unmapped.
bool _intentIsSettled(
  SideDb db,
  IntentRow intent,
  List<CollectionDeck> tree,
  Set<int> liveIds,
) {
  switch (intent.op) {
    case intentNoteAdd:
      final expected = _expectedObject(intent.expected);
      final guid = expected?['guid'];
      if (guid is! String || guid.isEmpty) {
        return false;
      }
      final row = db.note(guid);
      if (row != null && liveIds.contains(row.rslibNoteId)) {
        return true;
      }
      for (final id in liveIds) {
        if (db.noteByRslibId(id) == null) {
          return false;
        }
      }
      return true;
    case intentDeckAdd:
      final expected = _expectedObject(intent.expected);
      final name = expected?['name'];
      if (name is! String || name.isEmpty) {
        return false;
      }
      CollectionDeck? match;
      for (final deck in tree) {
        if (deck.name == name) {
          match = deck;
          break;
        }
      }
      if (match == null) {
        return true;
      }
      return db.deckByRslibId(match.id) != null;
    case intentNoteUpdate:
    case intentMediaAdd:
    case intentUndo:
    case intentRedo:
      return true;
    default:
      return false;
  }
}

Map<String, Object?>? _expectedObject(String? raw) {
  if (raw == null || raw.isEmpty) {
    return null;
  }
  final Object? decoded;
  try {
    decoded = jsonDecode(raw);
  } on FormatException {
    return null;
  }
  if (decoded is! Map) {
    return null;
  }
  final object = Map<String, Object?>.from(decoded);
  if (object['v'] != 0) {
    return null;
  }
  return object;
}
