// SPDX-FileCopyrightText: 2026 Hatto Social contributors
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'import_engine.dart';

/// Machine-readable kind of an import failure from `hatto_import`.
///
/// The Rust side prefixes the message. Callers match these values and not
/// the prose that follows.
enum ImportErrorKind {
  /// Wrong extension, missing zip local header, or an invalid zip archive.
  format,

  /// Compressed file size exceeds [ImportLimits.maxBytes].
  tooLargeCompressed,

  /// Uncompressed zip entry sizes exceed [ImportLimits.maxUncompressedBytes]
  /// or overflow `u64`.
  tooLargeUncompressed,
}

/// `format:` from `hatto_import`.
const String importFormatPrefix = 'format:';

/// `too_large:compressed` from `hatto_import`.
const String importTooLargeCompressedPrefix = 'too_large:compressed';

/// `too_large:uncompressed` from `hatto_import`.
const String importTooLargeUncompressedPrefix = 'too_large:uncompressed';

/// The kind named by [error], or null when the text has none of the prefixes.
///
/// [error] may be the Rust string itself or an exception whose [Object.toString]
/// contains that string.
ImportErrorKind? importErrorKind(Object? error) {
  if (error == null) {
    return null;
  }
  final text = error.toString();
  final found = <int, ImportErrorKind>{};
  void consider(String prefix, ImportErrorKind kind) {
    final index = text.indexOf(prefix);
    if (index >= 0) {
      found[index] = kind;
    }
  }

  consider(
    importTooLargeUncompressedPrefix,
    ImportErrorKind.tooLargeUncompressed,
  );
  consider(importTooLargeCompressedPrefix, ImportErrorKind.tooLargeCompressed);
  consider(importFormatPrefix, ImportErrorKind.format);
  if (found.isEmpty) {
    return null;
  }
  final earliest = found.keys.reduce(
    (left, right) => left < right ? left : right,
  );
  return found[earliest];
}
