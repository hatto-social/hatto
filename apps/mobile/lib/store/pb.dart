// SPDX-FileCopyrightText: 2026 Hatto Social contributors
//
// SPDX-License-Identifier: AGPL-3.0-or-later

// Hand-written protobuf codec for the mobile app.
//
// apps/mobile has no generated Anki protobuf library. Field numbers are the
// Anki 26.09.3 messages the import engine and [AnkiApi] call. rslib is not
// modified; the bytes go through rslib_bridge `command`.

import 'dart:convert';
import 'dart:typed_data';

/// `ImportAnkiPackageUpdateCondition.IF_NEWER`. Proto3 default, so it is
/// omitted on the wire. Desktop passes this for `update_notes`.
const int packageUpdateIfNewer = 0;

/// `ImportAnkiPackageUpdateCondition.NEVER`. Desktop passes this for
/// `update_notetypes`.
const int packageUpdateNever = 2;

/// `BackendError.Kind.NOT_FOUND_ERROR` in Anki 26.09.3.
const int backendNotFoundKind = 11;

class PbWriter {
  final BytesBuilder _bytes = BytesBuilder(copy: false);

  void varint(int value) {
    // Dart's `<<` is a wrapping 64-bit shift, so a negative int64 is written
    // as nine low groups plus the sign bit. Protobuf sign-extends to 64 bits.
    if (value >= 0) {
      var rest = value;
      while (rest > 0x7f) {
        _bytes.addByte((rest & 0x7f) | 0x80);
        rest >>= 7;
      }
      _bytes.addByte(rest);
      return;
    }
    var rest = value;
    for (var i = 0; i < 9; i++) {
      _bytes.addByte((rest & 0x7f) | 0x80);
      rest >>= 7;
    }
    _bytes.addByte(0x01);
  }

  void _key(int field, int wire) => varint((field << 3) | wire);

  void varintField(int field, int value) {
    _key(field, 0);
    varint(value);
  }

  /// Proto3 scalar. Zero is the default and is not written.
  void int64Field(int field, int value) {
    if (value == 0) {
      return;
    }
    varintField(field, value);
  }

  void boolField(int field, bool value) {
    if (!value) {
      return;
    }
    varintField(field, 1);
  }

  void bytesField(int field, List<int> payload) {
    _key(field, 2);
    varint(payload.length);
    _bytes.add(payload);
  }

  void stringField(int field, String value, {bool omitEmpty = true}) {
    if (omitEmpty && value.isEmpty) {
      return;
    }
    bytesField(field, utf8.encode(value));
  }

  void packedVarints(int field, List<int> values) {
    if (values.isEmpty) {
      return;
    }
    final inner = PbWriter();
    for (final value in values) {
      inner.varint(value);
    }
    bytesField(field, inner.takeBytes());
  }

  Uint8List takeBytes() => _bytes.takeBytes();
}

class PbField {
  PbField({
    required this.number,
    required this.wire,
    this.varintValue = 0,
    Uint8List? bytes,
  }) : bytes = bytes ?? Uint8List(0);

  final int number;
  final int wire;
  final int varintValue;
  final Uint8List bytes;
}

List<PbField> parseFields(Uint8List data) {
  final out = <PbField>[];
  var index = 0;

  int readVarint() {
    // Multiply by 128 instead of shifting. `1 << 63` is negative on the Dart
    // VM, and that wrapping is what turns a 10-byte sign-extended varint
    // (usn = -1) back into a negative int.
    var result = 0;
    var place = 1;
    for (var i = 0; i < 10; i++) {
      if (index >= data.length) {
        throw const FormatException('truncated varint');
      }
      final byte = data[index++];
      result += (byte & 0x7f) * place;
      if ((byte & 0x80) == 0) {
        return result;
      }
      place *= 128;
    }
    throw const FormatException('varint too long');
  }

  while (index < data.length) {
    final key = readVarint();
    final number = key >> 3;
    final wire = key & 7;
    switch (wire) {
      case 0:
        out.add(PbField(number: number, wire: wire, varintValue: readVarint()));
      case 1:
        if (index + 8 > data.length) {
          throw const FormatException('truncated fixed64');
        }
        out.add(
          PbField(
            number: number,
            wire: wire,
            bytes: Uint8List.fromList(data.sublist(index, index + 8)),
          ),
        );
        index += 8;
      case 2:
        final length = readVarint();
        if (length < 0 || index + length > data.length) {
          throw const FormatException('truncated length-delimited field');
        }
        out.add(
          PbField(
            number: number,
            wire: wire,
            bytes: Uint8List.fromList(data.sublist(index, index + length)),
          ),
        );
        index += length;
      case 5:
        if (index + 4 > data.length) {
          throw const FormatException('truncated fixed32');
        }
        out.add(
          PbField(
            number: number,
            wire: wire,
            bytes: Uint8List.fromList(data.sublist(index, index + 4)),
          ),
        );
        index += 4;
      default:
        throw FormatException('unsupported wire type $wire');
    }
  }
  return out;
}

/// `anki.backend.BackendInit` with `preferred_langs = ["en"]` and
/// `server = false`.
Uint8List encodeBackendInit() {
  final writer = PbWriter()..stringField(1, 'en');
  return writer.takeBytes();
}

/// `anki.collection.OpenCollectionRequest`.
Uint8List encodeOpenCollection({
  required String collectionPath,
  required String mediaFolderPath,
  required String mediaDbPath,
}) {
  final writer = PbWriter()
    ..stringField(1, collectionPath)
    ..stringField(2, mediaFolderPath)
    ..stringField(3, mediaDbPath);
  return writer.takeBytes();
}

/// `anki.generic.String`.
Uint8List encodeStringValue(String value) {
  final writer = PbWriter()..stringField(1, value, omitEmpty: false);
  return writer.takeBytes();
}

/// `anki.search.SearchNode` with the `parsable_text` oneof set.
///
/// An empty string is written. `BuildSearchString("")` is the empty search
/// reconciliation uses, which rslib turns into `deck:*`.
Uint8List encodeParsableSearch(String text) {
  final writer = PbWriter()..stringField(3, text, omitEmpty: false);
  return writer.takeBytes();
}

/// `anki.search.SearchRequest` with no sort order.
Uint8List encodeSearchRequest(String search) {
  final writer = PbWriter()..stringField(1, search, omitEmpty: false);
  return writer.takeBytes();
}

/// A message whose only field is an int64 id (`NoteId`, `CardId`, ...).
Uint8List encodeInt64Message(int id) {
  final writer = PbWriter()..int64Field(1, id);
  return writer.takeBytes();
}

/// `GetDeckNamesRequest`. [includeFiltered] false is omitted.
///
/// `skip_empty_default` stays false. Unset `include_filtered` would imply
/// skipping an empty Default, so a full deck list sets it.
Uint8List encodeDeckNamesRequest({required bool includeFiltered}) {
  final writer = PbWriter()..boolField(2, includeFiltered);
  return writer.takeBytes();
}

/// Resident package import request.
///
/// `update_notes` is [packageUpdateIfNewer] (0) and is omitted.
/// `update_notetypes` is [packageUpdateNever] (2). `with_scheduling` is
/// true. `with_deck_configs` is [withDeckConfigs] (`firstImport` on the
/// desktop adapter). `merge_notetypes` stays false and is omitted.
Uint8List encodeResidentPackageImport({
  required String packagePath,
  required bool withDeckConfigs,
}) {
  final options = PbWriter()
    ..varintField(3, packageUpdateNever)
    ..boolField(4, true)
    ..boolField(5, withDeckConfigs);
  final writer = PbWriter()
    ..stringField(1, packagePath)
    ..bytesField(2, options.takeBytes());
  return writer.takeBytes();
}

class BackendErrorView {
  const BackendErrorView({this.message, this.kind});

  final String? message;
  final int? kind;
}

/// `anki.backend.BackendError`. Field 1 is the message, field 2 is the kind.
BackendErrorView readBackendError(Uint8List bytes) {
  String? message;
  int? kind;
  for (final field in parseFields(bytes)) {
    if (field.number == 1 && field.wire == 2) {
      message = utf8.decode(field.bytes);
    } else if (field.number == 2 && field.wire == 0) {
      kind = field.varintValue;
    }
  }
  return BackendErrorView(message: message, kind: kind);
}

/// First length-delimited field [number], or null when it is absent.
String? readStringField(Uint8List message, {int number = 1}) {
  for (final field in parseFields(message)) {
    if (field.number == number && field.wire == 2) {
      return utf8.decode(field.bytes);
    }
  }
  return null;
}

/// Repeated int64 field [number], packed or unpacked.
List<int> readInt64s(Uint8List message, {int number = 1}) {
  final out = <int>[];
  for (final field in parseFields(message)) {
    if (field.number != number) {
      continue;
    }
    if (field.wire == 0) {
      out.add(field.varintValue);
    } else if (field.wire == 2) {
      out.addAll(_varints(field.bytes));
    }
  }
  return out;
}

/// `notes.Note.guid` (field 2).
String readNoteGuid(Uint8List message) {
  final guid = readStringField(message, number: 2);
  if (guid == null) {
    throw const FormatException('note guid is missing');
  }
  return guid;
}

/// `cards.Card` columns reconciliation reads.
class CardColumns {
  const CardColumns({
    required this.deckId,
    required this.originalDeckId,
    required this.templateIdx,
  });

  /// Field 3, `deck_id`.
  final int deckId;

  /// Field 16, `original_deck_id`. Zero when the card is not filtered.
  final int originalDeckId;

  /// Field 4, `template_idx`. This is the card ord.
  final int templateIdx;
}

CardColumns readCardColumns(Uint8List message) {
  var deckId = 0;
  var originalDeckId = 0;
  var templateIdx = 0;
  for (final field in parseFields(message)) {
    if (field.wire != 0) {
      continue;
    }
    switch (field.number) {
      case 3:
        deckId = field.varintValue;
      case 4:
        templateIdx = field.varintValue;
      case 16:
        originalDeckId = field.varintValue;
    }
  }
  return CardColumns(
    deckId: deckId,
    originalDeckId: originalDeckId,
    templateIdx: templateIdx,
  );
}

/// Field 1 varint. Zero when the field is absent.
///
/// `decks.DeckId.did` and `notes.NoteId.nid` are both this shape.
int readInt64Field1(Uint8List message) {
  for (final field in parseFields(message)) {
    if (field.number == 1 && field.wire == 0) {
      return field.varintValue;
    }
  }
  return 0;
}

/// One `get_deck_names` entry. [name] is the full path (`Parent::Child`).
class DeckNameEntry {
  const DeckNameEntry({required this.id, required this.name});

  final int id;
  final String name;
}

List<DeckNameEntry> readDeckNameEntries(Uint8List message) {
  final out = <DeckNameEntry>[];
  for (final entry in parseFields(message)) {
    if (entry.number != 1 || entry.wire != 2) {
      continue;
    }
    var id = 0;
    var name = '';
    for (final field in parseFields(entry.bytes)) {
      if (field.number == 1 && field.wire == 0) {
        id = field.varintValue;
      } else if (field.number == 2 && field.wire == 2) {
        name = utf8.decode(field.bytes);
      }
    }
    if (name.isEmpty) {
      continue;
    }
    out.add(DeckNameEntry(id: id, name: name));
  }
  return out;
}

/// Sum of `NotetypeNameIdUseCount.use_count` (field 3, uint32).
int readNotetypeUseCountSum(Uint8List message) {
  var sum = 0;
  for (final entry in parseFields(message)) {
    if (entry.number != 1 || entry.wire != 2) {
      continue;
    }
    for (final field in parseFields(entry.bytes)) {
      if (field.number == 3 && field.wire == 0) {
        sum += field.varintValue;
      }
    }
  }
  return sum;
}

/// `ImportResponse.log.new[].id.nid`, in response order.
///
/// A new-note entry whose `id` submessage is absent is skipped. That matches
/// the desktop adapter's `note.hasId()` check.
List<int> readImportedNewNoteIds(Uint8List message) {
  final ids = <int>[];
  for (final top in parseFields(message)) {
    if (top.number != 2 || top.wire != 2) {
      continue;
    }
    for (final logField in parseFields(top.bytes)) {
      if (logField.number != 1 || logField.wire != 2) {
        continue;
      }
      Uint8List? idBytes;
      for (final noteField in parseFields(logField.bytes)) {
        if (noteField.number == 1 && noteField.wire == 2) {
          idBytes = noteField.bytes;
        }
      }
      if (idBytes == null) {
        continue;
      }
      ids.add(readInt64Field1(idBytes));
    }
  }
  return ids;
}

/// `generic.Empty`, and a close request that leaves every field default.
Uint8List emptyMessage() => Uint8List(0);

List<int> _varints(Uint8List data) {
  final out = <int>[];
  var index = 0;
  while (index < data.length) {
    var result = 0;
    var place = 1;
    var done = false;
    for (var i = 0; i < 10; i++) {
      if (index >= data.length) {
        throw const FormatException('truncated varint');
      }
      final byte = data[index++];
      result += (byte & 0x7f) * place;
      if ((byte & 0x80) == 0) {
        done = true;
        break;
      }
      place *= 128;
    }
    if (!done) {
      throw const FormatException('varint too long');
    }
    out.add(result);
  }
  return out;
}
