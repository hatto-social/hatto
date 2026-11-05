import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'schema.dart';

final RegExp _sha256Hex = RegExp(r'^[0-9a-f]{64}$');

/// Path of a copied original apkg under the app documents directory.
///
/// The file name is [sourceSha256], the same string stored in
/// `deck_map.source_sha256`. The side database has no path column.
String importArchivePath(String documentsDirectory, String sourceSha256) {
  if (!_sha256Hex.hasMatch(sourceSha256)) {
    throw const SideDbException(
      'source_sha256 must be 64 lowercase hex characters',
    );
  }
  return p.join(documentsDirectory, 'hatto', 'imports', sourceSha256);
}

/// Copies [source] to `<documents>/hatto/imports/<sha256>`.
///
/// Returns the content sha256 for `deck_map.source_sha256`. A file already
/// stored under that name is left in place.
String storeImportArchive({
  required String documentsDirectory,
  required File source,
}) {
  if (!source.existsSync()) {
    throw SideDbException('import archive is missing: ${source.path}');
  }
  final digest = _sha256OfFile(source);
  final dest = File(importArchivePath(documentsDirectory, digest));
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
