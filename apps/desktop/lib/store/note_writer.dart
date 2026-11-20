// SPDX-FileCopyrightText: 2026 Hatto Social contributors
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:convert';
import 'dart:typed_data';

import 'package:hatto_store/hatto_store.dart' as store;
import 'package:rslib_bridge/rslib_bridge.dart';

import 'note_bytes.dart';
import 'write_gateway.dart';

/// Saves one note through [WriteGateway].
///
/// A failure is a returned message. Callers can show it and stay open.
class NoteWriter {
  NoteWriter({required store.SideDb db, required this.backend})
    : gateway = WriteGateway(
        db: db,
        command: (service, method, input) async {
          final response = await command(
            backend: backend,
            service: service,
            method: method,
            input: input,
          );
          return store.ProtoResponse(
            success: response.success,
            payload: response.payload,
          );
        },
      );

  final AnkiBackend backend;
  final WriteGateway gateway;

  store.SideDb get db => gateway.db;

  /// Null when the note was saved. Otherwise a message for the window.
  Future<String?> addNote({
    required String guid,
    required int notetypeId,
    required int deckId,
    required List<String> fields,
    required String opId,
    List<String> tags = const [],
  }) async {
    if (db.note(guid) != null) {
      return 'a note with this guid is already mapped';
    }
    final index = serviceMethodIndex(
      service: 'BackendNotesService',
      method: 'add_note',
    );
    if (index == null) {
      return 'add_note is not in this bridge';
    }
    try {
      final response = await gateway.run(
        op: store.intentNoteAdd,
        entityKind: 'note',
        guid: guid,
        service: index.service,
        method: index.method,
        input: encodeAddNote(
          guid: guid,
          notetypeId: notetypeId,
          deckId: deckId,
          fields: fields,
          tags: tags,
        ),
        expected: jsonEncode({
          'v': 0,
          'op_id': opId,
          'guid': guid,
          'deck_id': deckId,
        }),
        map: (response) async {
          final noteId = fieldVarint(response.payload, 2);
          if (noteId == null) {
            throw StateError('add_note response has no note id');
          }
          final home = await _homeDeck(noteId);
          await gateway.recordSavedNote(
            anki: _Reads(backend),
            guid: guid,
            rslibNoteId: noteId,
            homeDeckId: home,
          );
        },
      );
      if (!response.success) {
        return _message(response.payload);
      }
      return null;
    } catch (err) {
      return err.toString();
    }
  }

  Future<int> _homeDeck(int noteId) async {
    final cardsIndex = serviceMethodIndex(
      service: 'BackendNotesService',
      method: 'cards_of_note',
    );
    final cardIndex = serviceMethodIndex(
      service: 'BackendCardsService',
      method: 'get_card',
    );
    if (cardsIndex == null || cardIndex == null) {
      throw StateError('card reads are not in this bridge');
    }
    final cards = await command(
      backend: backend,
      service: cardsIndex.service,
      method: cardsIndex.method,
      input: encodeId(noteId),
    );
    if (!cards.success) {
      throw StateError(_message(cards.payload));
    }
    final ids = fieldVarints(cards.payload, 1);
    if (ids.isEmpty) {
      throw StateError('note $noteId has no cards');
    }
    final card = await command(
      backend: backend,
      service: cardIndex.service,
      method: cardIndex.method,
      input: encodeId(ids.first),
    );
    if (!card.success) {
      throw StateError(_message(card.payload));
    }
    final original = fieldVarint(card.payload, 16) ?? 0;
    if (original != 0) {
      return original;
    }
    return fieldVarint(card.payload, 3) ?? 0;
  }

  String _message(Uint8List payload) {
    final text = String.fromCharCodes(
      payload.where((byte) => byte >= 32 && byte < 127),
    );
    if (text.isEmpty) {
      return 'the note was not saved';
    }
    return text;
  }
}

class _Reads implements store.AnkiApi {
  _Reads(this.backend);

  final AnkiBackend backend;

  @override
  Future<List<store.CollectionDeck>> deckTree() async {
    final index = serviceMethodIndex(
      service: 'BackendDecksService',
      method: 'deck_tree',
    );
    if (index == null) {
      throw StateError('deck_tree is not in this bridge');
    }
    final response = await command(
      backend: backend,
      service: index.service,
      method: index.method,
      input: const [],
    );
    if (!response.success) {
      throw StateError('deck tree was rejected');
    }
    return _decks(response.payload);
  }

  List<store.CollectionDeck> _decks(List<int> bytes) {
    // DeckTreeNode: name = 2, deck_id = 4, children = 5.
    final found = <store.CollectionDeck>[];
    void walk(List<int> node, String parent) {
      final reader = _Tree(node);
      String? name;
      int? id;
      final children = <List<int>>[];
      while (!reader.done) {
        final key = reader.varint();
        final field = key >> 3;
        final wire = key & 7;
        if (field == 1 && wire == 0) {
          id = reader.varint();
        } else if (field == 2 && wire == 2) {
          name = utf8.decode(reader.take());
        } else if (field == 3 && wire == 2) {
          children.add(reader.take());
        } else {
          reader.skip(wire);
        }
      }
      final part = name ?? '';
      final full = part.isEmpty
          ? parent
          : (parent.isEmpty ? part : '$parent::$part');
      if (id != null && part.isNotEmpty) {
        found.add(store.CollectionDeck(id: id, name: full));
      }
      for (final child in children) {
        walk(child, full);
      }
    }

    walk(bytes, '');
    return found;
  }

  @override
  Future<store.CollectionNote> getNote(int id) async =>
      throw UnimplementedError();

  @override
  Future<List<int>> searchNoteIds() async => throw UnimplementedError();

  @override
  Future<store.CollectionCard> getCard(int cardId) async =>
      throw UnimplementedError();

  @override
  Future<List<store.CollectionCardRef>> cardsOfNote(int noteId) async =>
      throw UnimplementedError();
}

class _Tree {
  _Tree(this.bytes);

  final List<int> bytes;
  var index = 0;

  bool get done => index >= bytes.length;

  int varint() {
    var result = 0;
    var shift = 0;
    while (!done) {
      final byte = bytes[index++];
      result |= (byte & 0x7f) << shift;
      if (byte & 0x80 == 0) {
        return result;
      }
      shift += 7;
    }
    throw const FormatException('truncated varint');
  }

  List<int> take() {
    final length = varint();
    final start = index;
    index += length;
    return bytes.sublist(start, index);
  }

  void skip(int wire) {
    switch (wire) {
      case 0:
        varint();
      case 1:
        index += 8;
      case 2:
        final length = varint();
        index += length;
      case 5:
        index += 4;
      default:
        throw FormatException('unsupported wire type $wire');
    }
  }
}
