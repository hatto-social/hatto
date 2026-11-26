// SPDX-FileCopyrightText: 2026 Hatto Social contributors
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'schema.dart';
import 'uuid.dart';

/// Path of a copied original apkg: `<dataDir>/imports/<sourceSha256>`.
///
/// The file name is [sourceSha256], the same string stored in
/// `deck_map.source_sha256`. The side database has no path column. This file
/// is not under the working tree `<dataDir>/import/{raw,e,staged}`.
String importArchivePath(String dataDir, String sourceSha256) {
  if (!sha256Hex.hasMatch(sourceSha256)) {
    throw const SideDbException(
      'source_sha256 must be 64 lowercase hex characters',
    );
  }
  return p.join(dataDir, 'imports', sourceSha256);
}

/// `<dataDir>/import/raw/<batchId>.apkg`.
///
/// The working copy of the original package. [batchId] is a lowercase UUID
/// version 4. The content-addressed archive is [importArchivePath].
String importRawApkgPath(String dataDir, String batchId) {
  if (!uuidVersion4.hasMatch(batchId)) {
    throw const SideDbException(
      'import_batch_id must be a lowercase UUID version 4',
    );
  }
  return p.join(dataDir, 'import', 'raw', '$batchId.apkg');
}

/// Lowercase hex SHA-256 of [source].
String sha256OfFile(File source) {
  if (!source.existsSync()) {
    throw SideDbException('import archive is missing: ${source.path}');
  }
  return _sha256OfFile(source);
}

/// Copies [source] to `<dataDir>/imports/<sha256>`.
///
/// Returns the content sha256 for `deck_map.source_sha256`. A file already
/// stored under that name is left in place.
String storeImportArchive({required String dataDir, required File source}) {
  final digest = sha256OfFile(source);
  final dest = File(importArchivePath(dataDir, digest));
  if (p.equals(source.absolute.path, dest.absolute.path)) {
    return digest;
  }
  dest.parent.createSync(recursive: true);
  if (!dest.existsSync()) {
    source.copySync(dest.path);
  }
  return digest;
}

String _sha256OfFile(File source) {
  final sink = _DigestSink();
  final input = sha256.startChunkedConversion(sink);
  final raf = source.openSync();
  try {
    final buffer = Uint8List(64 * 1024);
    while (true) {
      final n = raf.readIntoSync(buffer);
      if (n <= 0) {
        break;
      }
      input.add(Uint8List.sublistView(buffer, 0, n));
    }
  } finally {
    raf.closeSync();
  }
  input.close();
  final digest = sink.digest;
  if (digest == null) {
    throw SideDbException('sha256 produced no digest for ${source.path}');
  }
  return digest.toString();
}

class _DigestSink implements Sink<Digest> {
  Digest? digest;

  @override
  void add(Digest data) {
    digest = data;
  }

  @override
  void close() {}
}
