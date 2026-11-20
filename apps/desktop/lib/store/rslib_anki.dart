// SPDX-FileCopyrightText: 2026 Hatto Social contributors
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:hatto_store/hatto_store.dart' as store;

import '../engine/anki_api.dart';

/// Reads a live collection for reconciliation.
///
/// This is the desktop [store.AnkiApi]. It does not write the side database.
class RslibAnkiApi implements store.AnkiApi {
  RslibAnkiApi(this.flow);

  final FlowApi flow;

  @override
  Future<List<int>> searchNoteIds() {
    return flow.searchNotes('');
  }

  @override
  Future<store.CollectionNote> getNote(int id) async {
    final note = await flow.getNote(id);
    return store.CollectionNote(id: note.id.toInt(), guid: note.guid);
  }

  @override
  Future<List<store.CollectionCardRef>> cardsOfNote(int noteId) async {
    final ids = await flow.cardsOfNote(noteId);
    final refs = <store.CollectionCardRef>[];
    for (final id in ids) {
      final card = await flow.getCard(id);
      refs.add(store.CollectionCardRef(id: id, ord: card.templateIdx));
    }
    return refs;
  }

  @override
  Future<store.CollectionCard> getCard(int cardId) async {
    final card = await flow.getCard(cardId);
    return store.CollectionCard(
      id: card.id.toInt(),
      deckId: card.deckId.toInt(),
      odid: card.originalDeckId.toInt(),
    );
  }

  @override
  Future<List<store.CollectionDeck>> deckTree() async {
    final out = <store.CollectionDeck>[];
    _flatten(await flow.deckTree(), '', out);
    return out;
  }
}

void _flatten(DeckTreeNode node, String parent, List<store.CollectionDeck> out) {
  final name = node.name;
  final full = name.isEmpty
      ? parent
      : (parent.isEmpty ? name : '$parent::$name');
  if (name.isNotEmpty) {
    out.add(store.CollectionDeck(id: node.deckId.toInt(), name: full));
  }
  for (final child in node.children) {
    _flatten(child, name.isEmpty ? parent : full, out);
  }
}
