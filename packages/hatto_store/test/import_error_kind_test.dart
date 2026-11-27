// SPDX-FileCopyrightText: 2026 Hatto Social contributors
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:io';

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
    expect(
      importErrorKind(Exception('format: package extension is not .apkg')),
      ImportErrorKind.format,
    );
    expect(
      importErrorKind(
        const FormatException('too_large:compressed package exceeds max_bytes'),
      ),
      ImportErrorKind.tooLargeCompressed,
    );
    expect(
      importErrorKind(
        Exception('too_large:uncompressed uncompressed size sum overflows u64'),
      ),
      ImportErrorKind.tooLargeUncompressed,
    );
    expect(importErrorKind('package exceeds max_bytes'), isNull);
    expect(importErrorKind(null), isNull);
  });

  test('a path containing format: is not a format error', () {
    const pathMessage =
        "FileSystemException: Cannot open file, path = '/tmp/format: notes.apkg' "
        '(OS Error: No such file or directory, errno = 2)';
    expect(importErrorKind(pathMessage), isNull);
    expect(
      importErrorKind(
        const FileSystemException(
          'Cannot open file',
          '/tmp/format: notes.apkg',
        ),
      ),
      isNull,
    );
    expect(importErrorKind('open /var/tmp/format: deck.apkg failed'), isNull);
  });
}
