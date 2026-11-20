// SPDX-FileCopyrightText: 2026 Hatto Social contributors
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:hatto_store/hatto_store.dart';

/// In-memory collection for reconcile tests. Not a bridge.
class FakeCollection implements AnkiApi {
  final Map<int, CollectionNote> notes = {};
  final Map<int, CollectionCard> cards = {};
  final Map<int, List<CollectionCardRef>> noteCards = {};
  List<CollectionDeck> decks = const [CollectionDeck(id: 1, name: 'Default')];
  var noteReads = 0;

  void addNote({
    required int id,
    required String guid,
    required int cardId,
    int ord = 0,
    int deckId = 1,
    int odid = 0,
  }) {
    notes[id] = CollectionNote(id: id, guid: guid);
    cards[cardId] = CollectionCard(id: cardId, deckId: deckId, odid: odid);
    noteCards[id] = [CollectionCardRef(id: cardId, ord: ord)];
  }

  @override
  Future<List<int>> searchNoteIds() async {
    final ids = notes.keys.toList()..sort();
    return ids;
  }

  @override
  Future<CollectionNote> getNote(int id) async {
    noteReads += 1;
    final note = notes[id];
    if (note == null) {
      throw StateError('missing note $id');
    }
    return note;
  }

  @override
  Future<List<CollectionCardRef>> cardsOfNote(int noteId) async {
    return noteCards[noteId] ?? const [];
  }

  @override
  Future<CollectionCard> getCard(int cardId) async {
    final card = cards[cardId];
    if (card == null) {
      throw StateError('missing card $cardId');
    }
    return card;
  }

  @override
  Future<List<CollectionDeck>> deckTree() async => decks;
}
