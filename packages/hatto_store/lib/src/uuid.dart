// SPDX-FileCopyrightText: 2026 Hatto Social contributors
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:math';
import 'dart:typed_data';

/// Lowercase hyphenated UUIDv4 from a CSPRNG.
///
/// Version nibble is 4 and the variant bits are 10xx. The side database
/// uses this for `meta.device_id` and for deck guids issued at adoption.
String newUuidV4([Random? random]) {
  final source = random ?? Random.secure();
  final bytes = Uint8List(16);
  for (var i = 0; i < 16; i++) {
    bytes[i] = source.nextInt(256);
  }
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  return formatUuid(bytes);
}

/// Formats 16 bytes as `8-4-4-4-12` lowercase hex.
String formatUuid(Uint8List bytes) {
  if (bytes.length != 16) {
    throw ArgumentError.value(bytes.length, 'bytes', 'UUID is 16 bytes');
  }
  final hex = [for (final byte in bytes) byte.toRadixString(16).padLeft(2, '0')]
      .join();
  return '${hex.substring(0, 8)}-'
      '${hex.substring(8, 12)}-'
      '${hex.substring(12, 16)}-'
      '${hex.substring(16, 20)}-'
      '${hex.substring(20)}';
}

/// Lowercase hyphenated UUID whose version nibble is 4 or 5.
final RegExp uuidVersion4Or5 = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-[45][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
);
