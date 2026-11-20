// SPDX-FileCopyrightText: 2026 Hatto Social contributors
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:hatto_store/hatto_store.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'fake_collection.dart';

void main() {
  const guid = '11111111-1111-4111-8111-111111111111';

  test('restarting the file database adopts a commit the crash left behind', () async {
    final dir = Directory.systemTemp.createTempSync('hatto-file-restart');
    addTearDown(() {
      if (dir.existsSync()) {
        dir.deleteSync(recursive: true);
      }
    });
    final path = p.join(dir.path, 'hatto.sqlite');
    final first = SideDb.openOrCreate(path);
    final collection = FakeCollection();
    final wrapper = WriteWrapper(
      db: first,
      command: (service, method, input) async {
        collection.addNote(id: 7, guid: guid, cardId: 70);
        return ProtoResponse.emptyOk;
      },
      fault: (phase) {
        if (phase == WritePhase.afterRslibCommit) {
          throw StateError('crash');
        }
      },
    );
    await expectLater(_add(wrapper, guid), throwsStateError);
    expect(first.pendingIntentCount(), 1);
    expect(first.notes(), isEmpty);
    first.close();

    final restarted = SideDb.openOrCreate(path);
    addTearDown(restarted.close);
    expect(restarted.pendingIntentCount(), 1);
    expect(restarted.deviceId, first.deviceId);
    await reconcileCollection(db: restarted, anki: collection);
    expect(restarted.note(guid)!.rslibNoteId, 7);
    expect(restarted.pendingIntentCount(), 0);
  });
}

Future<void> _add(WriteWrapper wrapper, String guid) {
  return wrapper.run(
    op: intentNoteAdd,
    entityKind: 'note',
    guid: guid,
    service: 1,
    method: 1,
    input: Uint8List(0),
    expected: jsonEncode({'v': 0, 'op_id': 'op', 'guid': guid, 'deck_id': 1}),
    journal: false,
  );
}
