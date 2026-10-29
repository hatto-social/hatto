import 'dart:io';
import 'dart:typed_data';

import 'package:hatto_store/hatto_store.dart';
import 'package:test/test.dart';

void main() {
  test('schema survives reopen and records a journal row', () async {
    final dir = await Directory.systemTemp.createTemp('hatto-store');
    addTearDown(() => dir.delete(recursive: true));
    final path = '${dir.path}/hatto.sqlite';

    final first = SideDb.open(path: path, deviceId: 'device-a');
    final wrapper = WriteWrapper(
      db: first,
      command: (service, method, input) async {
        expect(service, 1);
        expect(method, 2);
        expect(input, [9]);
        return ProtoResponse.emptyOk;
      },
    );
    final response = await wrapper.run(
      op: 'update_note',
      entityKind: 'note',
      guid: 'note-guid',
      field: 'front',
      service: 1,
      method: 2,
      input: Uint8List.fromList([9]),
    );
    expect(response.success, isTrue);
    expect(first.pendingIntentCount(), 0);
    first.close();

    final second = SideDb.open(path: path, deviceId: 'device-a');
    final rows = second.journalRows();
    expect(rows, hasLength(1));
    expect(rows.single.entityKind, 'note');
    expect(rows.single.guid, 'note-guid');
    expect(rows.single.field, 'front');
    expect(rows.single.hlc, startsWith('device-a:'));
    expect(second.pendingIntentCount(), 0);
    second.close();
  });

  test(
    'a failed rslib call abandons the intent and writes no journal row',
    () async {
      final db = SideDb.openInMemory();
      addTearDown(db.close);
      final wrapper = WriteWrapper(
        db: db,
        command: (_, _, _) async =>
            ProtoResponse(success: false, payload: Uint8List(0)),
      );
      final response = await wrapper.run(
        op: 'add_note',
        entityKind: 'note',
        guid: 'n',
        service: 0,
        method: 0,
        input: Uint8List(0),
      );
      expect(response.success, isFalse);
      expect(db.pendingIntentCount(), 0);
      expect(db.journalRows(), isEmpty);
    },
  );

  test('a thrown rslib call leaves the intent pending', () async {
    final db = SideDb.openInMemory();
    addTearDown(db.close);
    final wrapper = WriteWrapper(
      db: db,
      command: (_, _, _) async => throw StateError('bridge died'),
    );
    await expectLater(
      wrapper.run(
        op: 'answer',
        entityKind: 'card',
        guid: 'c',
        service: 0,
        method: 0,
        input: Uint8List(0),
      ),
      throwsStateError,
    );
    expect(db.pendingIntentCount(), 1);
    expect(db.journalRows(), isEmpty);
  });

  test('allowlist rejects writes and unknown reads', () {
    expect(
      () => SqlAllowlist.check('INSERT INTO notes VALUES (1)'),
      throwsA(isA<SqlRejected>()),
    );
    expect(
      () => SqlAllowlist.check('update cards set reps = 1'),
      throwsA(isA<SqlRejected>()),
    );
    expect(
      () => SqlAllowlist.check('DELETE FROM revlog'),
      throwsA(isA<SqlRejected>()),
    );
    expect(
      () => SqlAllowlist.check('SELECT * FROM cards'),
      throwsA(isA<SqlRejected>()),
    );
    expect(
      () => SqlAllowlist.check('SELECT 1; DROP TABLE cards'),
      throwsA(isA<SqlRejected>()),
    );
  });
}
