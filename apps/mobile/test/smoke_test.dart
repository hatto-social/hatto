import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hatto_mobile/main.dart';
import 'package:hatto_store/hatto_store.dart';
import 'package:path/path.dart' as p;
import 'package:rslib_bridge/rslib_bridge.dart' hide ProtoResponse;

void main() {
  test('opens a resident collection through the bridge', () async {
    await initRslibBridge();
    final dir = await Directory.systemTemp.createTemp('hatto-smoke');
    addTearDown(() => dir.delete(recursive: true));

    prepareRuntime(tmpDir: p.join(dir.path, 'tmp'));
    final summary = await smokeOpenCollection(dir: dir.path);

    expect(summary, startsWith('anki 26.09.3; server=false;'));
    expect(summary.split('decks=').last.split(','), contains('Default'));
    expect(File(p.join(dir.path, 'collection.anki2')).existsSync(), isTrue);

    final docs = Directory(p.join(dir.path, 'documents'))..createSync();
    final side = openSideDatabase(docs.path);
    addTearDown(side.close);
    expect(side.schemaVersion, sideDbSchemaVersion);
    expect(side.pendingIntentCount(), 0);
    final sideFile = File(sideDbPath(docs.path));
    expect(sideFile.existsSync(), isTrue);
    expect(p.basename(sideFile.path), 'hatto.sqlite');
    expect(sideFile.path, isNot(p.join(dir.path, 'collection.anki2')));

    final rows = await inspectExportedDeckConfigs(dir: dir.path);
    final preset = rows.singleWhere((row) => row.name == 'Default');
    expect(preset.newPerDay, 20);
    expect(preset.reviewsPerDay, 200);
    expect(File(p.join(dir.path, 'export.apkg')).existsSync(), isTrue);
  });
}
