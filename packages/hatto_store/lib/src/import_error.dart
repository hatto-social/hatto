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
/// The prefix must start the message. [error] may be the Rust string itself
/// or an exception whose [Object.toString] is `Type: message` (`Exception: `,
/// `FormatException: `, `Bad state: `, and the same shape). One wrapper is
/// skipped, then the remainder is matched with [String.startsWith]. A prefix
/// later in a path or IO message does not match.
ImportErrorKind? importErrorKind(Object? error) {
  if (error == null) {
    return null;
  }
  final text = error.toString();
  final direct = _kindAtStart(text);
  if (direct != null) {
    return direct;
  }
  final split = text.indexOf(': ');
  if (split < 0) {
    return null;
  }
  return _kindAtStart(text.substring(split + 2));
}

ImportErrorKind? _kindAtStart(String text) {
  if (text.startsWith(importTooLargeUncompressedPrefix)) {
    return ImportErrorKind.tooLargeUncompressed;
  }
  if (text.startsWith(importTooLargeCompressedPrefix)) {
    return ImportErrorKind.tooLargeCompressed;
  }
  if (text.startsWith(importFormatPrefix)) {
    return ImportErrorKind.format;
  }
  return null;
}
