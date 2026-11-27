// SPDX-FileCopyrightText: 2026 Hatto Social contributors
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:hatto_store/hatto_store.dart';

import 'pb.dart';
import 'resident_collection.dart';

/// Mobile [AnkiApi]. Reads the open collection. Does not write the side
/// database.
///
/// `deckTree` uses `get_deck_names` (`include_filtered`, Default kept).
/// Those names are the full paths (`Parent::Child`), which is the
/// `deckTree()` contract.
class MobileAnkiApi implements AnkiApi {
  MobileAnkiApi(this.collection);

  final ResidentCollection collection;

  @override
  Future<List<int>> searchNoteIds() async {
    final built = await collection.command(
      service: 'BackendSearchService',
      method: 'build_search_string',
      input: encodeParsableSearch(''),
    );
    final search = readStringField(built) ?? '';
    final found = await collection.command(
      service: 'BackendSearchService',
      method: 'search_notes',
      input: encodeSearchRequest(search),
    );
    return readInt64s(found);
  }

  @override
  Future<CollectionNote> getNote(int id) async {
    final raw = await collection.command(
      service: 'BackendNotesService',
      method: 'get_note',
      input: encodeInt64Message(id),
    );
    return CollectionNote(id: id, guid: readNoteGuid(raw));
  }

  @override
  Future<List<CollectionCardRef>> cardsOfNote(int noteId) async {
    final raw = await collection.command(
      service: 'BackendNotesService',
      method: 'cards_of_note',
      input: encodeInt64Message(noteId),
    );
    final ids = readInt64s(raw);
    final refs = <CollectionCardRef>[];
    for (final id in ids) {
      final card = await _card(id);
      refs.add(CollectionCardRef(id: id, ord: card.templateIdx));
    }
    return refs;
  }

  @override
  Future<CollectionCard> getCard(int cardId) async {
    final card = await _card(cardId);
    return CollectionCard(
      id: cardId,
      deckId: card.deckId,
      odid: card.originalDeckId,
    );
  }

  @override
  Future<List<CollectionDeck>> deckTree() async {
    final raw = await collection.command(
      service: 'BackendDecksService',
      method: 'get_deck_names',
      input: encodeDeckNamesRequest(includeFiltered: true),
    );
    return [
      for (final deck in readDeckNameEntries(raw))
        CollectionDeck(id: deck.id, name: deck.name),
    ];
  }

  Future<CardColumns> _card(int cardId) async {
    final raw = await collection.command(
      service: 'BackendCardsService',
      method: 'get_card',
      input: encodeInt64Message(cardId),
    );
    return readCardColumns(raw);
  }
}
