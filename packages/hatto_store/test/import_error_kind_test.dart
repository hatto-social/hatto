// SPDX-FileCopyrightText: 2026 Hatto Social contributors
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:hatto_store/hatto_store.dart';
import 'package:test/test.dart';

void main() {
  test('prefixes match the Rust contract', () {
    expect(importFormatPrefix, 'format:');
    expect(importTooLargeCompressedPrefix, 'too_large:compressed');
    expect(importTooLargeUncompressedPrefix, 'too_large:uncompressed');
  });

  test('rust messages map to the same kinds', () {
    expect(
      importErrorKind('format: package extension is not .apkg'),
      ImportErrorKind.format,
    );
    expect(
      importErrorKind('format: package does not start with a zip local header'),
      ImportErrorKind.format,
    );
    expect(
      importErrorKind('format: invalid zip archive: bad'),
      ImportErrorKind.format,
    );
    expect(
      importErrorKind('too_large:compressed package exceeds max_bytes'),
      ImportErrorKind.tooLargeCompressed,
    );
    expect(
      importErrorKind(
        'too_large:uncompressed uncompressed size sum exceeds max_uncompressed_bytes',
      ),
      ImportErrorKind.tooLargeUncompressed,
    );
    expect(
      importErrorKind(
        'too_large:uncompressed uncompressed size sum overflows u64',
      ),
      ImportErrorKind.tooLargeUncompressed,
    );
    expect(
      importErrorKind(StateError('format: package extension is not .apkg')),
      ImportErrorKind.format,
    );
    expect(importErrorKind('package exceeds max_bytes'), isNull);
    expect(importErrorKind(null), isNull);
  });
}
