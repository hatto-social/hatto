import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:hatto_store/hatto_store.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('hatto-imports');
  });

  tearDown(() async {
    if (dir.existsSync()) {
      await dir.delete(recursive: true);
    }
  });

  test('stores a copy named by the content sha256', () {
    final source = File(p.join(dir.path, 'original.apkg'))
      ..writeAsBytesSync(Uint8List.fromList([1, 2, 3, 4]));
    final expected = sha256.convert(source.readAsBytesSync()).toString();

    final digest = storeImportArchive(
      documentsDirectory: dir.path,
      source: source,
    );

    expect(digest, expected);
    expect(digest, hasLength(64));
    final stored = File(importArchivePath(dir.path, digest));
    expect(stored.path, p.join(dir.path, 'hatto', 'imports', digest));
    expect(p.basename(stored.path), digest);
    expect(stored.readAsBytesSync(), source.readAsBytesSync());
    expect(source.existsSync(), isTrue);
  });

  test('a second store of the same bytes keeps the existing file', () {
    final source = File(p.join(dir.path, 'original.apkg'))
      ..writeAsBytesSync(const [9, 9]);
    final digest = storeImportArchive(
      documentsDirectory: dir.path,
      source: source,
    );
    final stored = File(importArchivePath(dir.path, digest));
    stored.writeAsBytesSync(const [9, 9, 0]);

    final again = storeImportArchive(
      documentsDirectory: dir.path,
      source: source,
    );

    expect(again, digest);
    expect(stored.readAsBytesSync(), [9, 9, 0]);
  });

  test('path lookup rejects a value that is not a sha256', () {
    expect(
      () => importArchivePath(dir.path, '../hatto.sqlite'),
      throwsA(isA<SideDbException>()),
    );
    expect(
      () => importArchivePath(dir.path, 'A' * 64),
      throwsA(isA<SideDbException>()),
    );
    expect(
      () => importArchivePath(dir.path, 'ab'),
      throwsA(isA<SideDbException>()),
    );
  });

  test('a missing source is rejected', () {
    expect(
      () => storeImportArchive(
        documentsDirectory: dir.path,
        source: File(p.join(dir.path, 'missing.apkg')),
      ),
      throwsA(isA<SideDbException>()),
    );
  });

  test('sha256 of abc matches the known digest', () {
    final source = File(p.join(dir.path, 'abc.apkg'))..writeAsStringSync('abc');
    expect(
      storeImportArchive(documentsDirectory: dir.path, source: source),
      'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
    );
  });
}
