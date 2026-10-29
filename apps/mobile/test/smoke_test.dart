import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
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

    final side = SideDb.open(
      path: p.join(dir.path, 'hatto.sqlite'),
      deviceId: 'smoke-device',
    );
    addTearDown(side.close);
    expect(side.pendingIntentCount(), 0);
    expect(File(p.join(dir.path, 'hatto.sqlite')).existsSync(), isTrue);
  });
}
