// SPDX-FileCopyrightText: 2026 Hatto Social contributors
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;

import 'schema.dart';

/// Journal payload for `media.add`.
///
/// The side database stores this metadata, not the file bytes: the final
/// filename rslib returned, the byte length, and the sha1 of those bytes.
/// sha1 identifies the file; it is not a security hash. Mobile and desktop
/// both use this shape.
class MediaJournal {
  MediaJournal({
    required this.filename,
    required this.size,
    required this.sha1,
  }) {
    if (filename.isEmpty) {
      throw const SideDbException('media filename is empty');
    }
    if (size < 0) {
      throw SideDbException('media size $size is negative');
    }
    if (!RegExp(r'^[0-9a-f]{40}$').hasMatch(sha1)) {
      throw SideDbException('media sha1 is not 40 lowercase hex characters');
    }
  }

  /// [filename] is the name rslib stored. [bytes] are the file contents
  /// that were sent; only the length and sha1 are kept.
  factory MediaJournal.of({
    required String filename,
    required List<int> bytes,
  }) {
    return MediaJournal(
      filename: filename,
      size: bytes.length,
      sha1: crypto.sha1.convert(bytes).toString(),
    );
  }

  final String filename;
  final int size;

  /// Lowercase hex sha1 of the file bytes.
  final String sha1;

  /// UTF-8 JSON: `v`, `filename`, `size`, `sha1`. No file bytes.
  Uint8List encode() {
    final text = jsonEncode({
      'v': 0,
      'filename': filename,
      'size': size,
      'sha1': sha1,
    });
    return Uint8List.fromList(utf8.encode(text));
  }
}
