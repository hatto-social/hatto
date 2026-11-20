// SPDX-FileCopyrightText: 2026 Hatto Social contributors
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:convert';
import 'dart:typed_data';

/// Protobuf bytes for the few messages the desktop shell sends.
///
/// The field numbers match Anki 26.09.3. This is not a general codec.

List<int> encodeBackendInit() {
  final out = BytesBuilder();
  _string(out, 1, 'en');
  return out.takeBytes();
}

List<int> encodeOpenCollection({
  required String collectionPath,
  required String mediaFolderPath,
  required String mediaDbPath,
}) {
  final out = BytesBuilder();
  _string(out, 1, collectionPath);
  _string(out, 2, mediaFolderPath);
  _string(out, 3, mediaDbPath);
  return out.takeBytes();
}

/// `downgrade_to_schema11` stays at its default, false.
List<int> encodeCloseCollection() => const [];

/// `CardAnswer` bytes. [answeredAtMillis] is filled from [now] when omitted.
List<int> encodeCardAnswer({
  required int cardId,
  required List<int> currentState,
  required List<int> newState,
  required int rating,
  required int millisecondsTaken,
  int? answeredAtMillis,
  DateTime? now,
}) {
  final answered =
      answeredAtMillis ?? (now ?? DateTime.now()).millisecondsSinceEpoch;
  final out = BytesBuilder();
  _varintField(out, 1, cardId);
  _bytes(out, 2, currentState);
  _bytes(out, 3, newState);
  _varintField(out, 4, rating);
  _varintField(out, 5, answered);
  _varintField(out, 6, millisecondsTaken);
  return out.takeBytes();
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
  while (rest > 0x7f) {
    out.addByte((rest & 0x7f) | 0x80);
    rest >>= 7;
  }
  out.addByte(rest & 0x7f);
}
