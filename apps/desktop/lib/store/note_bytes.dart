// SPDX-FileCopyrightText: 2026 Hatto Social contributors
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:convert';
import 'dart:typed_data';

/// Hand-written protobuf for the note calls the desktop writer sends.
/// Field numbers match Anki 26.09.3.

Uint8List encodeAddNote({
  required String guid,
  required int notetypeId,
  required int deckId,
  required List<String> fields,
  List<String> tags = const [],
}) {
  final note = BytesBuilder();
  _string(note, 2, guid);
  _varintField(note, 3, notetypeId);
  for (final tag in tags) {
    _string(note, 6, tag);
  }
  for (final field in fields) {
    _string(note, 7, field);
  }
  final out = BytesBuilder();
  _bytes(out, 1, note.takeBytes());
  _varintField(out, 2, deckId);
  return out.takeBytes();
}

Uint8List encodeString(String value) {
  final out = BytesBuilder();
  _string(out, 1, value);
  return out.takeBytes();
}

Uint8List encodeId(int id) {
  final out = BytesBuilder();
  _varintField(out, 1, id);
  return out.takeBytes();
}

int? fieldVarint(List<int> bytes, int fieldNumber) {
  final reader = _Reader(bytes);
  while (!reader.done) {
    final key = reader.varint();
    final field = key >> 3;
    final wire = key & 7;
    if (field == fieldNumber && wire == 0) {
      return reader.varint();
    }
    reader.skip(wire);
  }
  return null;
}

List<int> fieldVarints(List<int> bytes, int fieldNumber) {
  final reader = _Reader(bytes);
  final values = <int>[];
  while (!reader.done) {
    final key = reader.varint();
    final field = key >> 3;
    final wire = key & 7;
    if (field == fieldNumber && wire == 0) {
      values.add(reader.varint());
    } else if (field == fieldNumber && wire == 2) {
      final end = reader.index + reader.varint();
      while (reader.index < end) {
        values.add(reader.varint());
      }
    } else {
      reader.skip(wire);
    }
  }
  return values;
}

void _varintField(BytesBuilder out, int field, int value) {
  _key(out, field, 0);
  _varint(out, value);
}

void _string(BytesBuilder out, int field, String value) {
  _bytes(out, field, utf8.encode(value));
}

void _bytes(BytesBuilder out, int field, List<int> value) {
  _key(out, field, 2);
  _varint(out, value.length);
  out.add(value);
}

void _key(BytesBuilder out, int field, int wire) {
  _varint(out, (field << 3) | wire);
}

void _varint(BytesBuilder out, int value) {
  var rest = value;
  if (rest == 0) {
    out.addByte(0);
    return;
  }
  while (rest > 0x7f) {
    out.addByte((rest & 0x7f) | 0x80);
    rest >>= 7;
  }
  out.addByte(rest & 0x7f);
}

class _Reader {
  _Reader(this.bytes);

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
