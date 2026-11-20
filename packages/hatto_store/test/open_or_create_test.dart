// SPDX-FileCopyrightText: 2026 Hatto Social contributors
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:io';

import 'package:hatto_store/hatto_store.dart';
import 'package:test/test.dart';

void main() {
  test('openOrCreate stores a UUIDv4 device id and keeps it', () async {
    final dir = await Directory.systemTemp.createTemp('hatto-device');
    addTearDown(() => dir.delete(recursive: true));
    final path = '${dir.path}/hatto.sqlite';

    final created = SideDb.openOrCreate(path);
    expect(created.deviceId, matches(uuidVersion4Or5));
    expect(created.deviceId, matches(RegExp(r'-4')));
    final id = created.deviceId;
    created.close();

    final again = SideDb.openOrCreate(path);
    expect(again.deviceId, id);
    again.close();

    final explicit = SideDb.open(path: path, deviceId: 'other-device');
    expect(explicit.deviceId, id);
    explicit.close();
  });

  test('open still records the caller device id on a new file', () async {
    final dir = await Directory.systemTemp.createTemp('hatto-device-open');
    addTearDown(() => dir.delete(recursive: true));
    final path = '${dir.path}/hatto.sqlite';
    final side = SideDb.open(path: path, deviceId: 'device-a');
    expect(side.deviceId, 'device-a');
    side.close();
    final created = SideDb.openOrCreate(path);
    expect(created.deviceId, 'device-a');
    created.close();
  });

  test('a copied side database keeps the same device id', () async {
    final dir = await Directory.systemTemp.createTemp('hatto-device-copy');
    addTearDown(() => dir.delete(recursive: true));
    final path = '${dir.path}/hatto.sqlite';
    final original = SideDb.openOrCreate(path);
    final id = original.deviceId;
    original.close();

    final copyPath = '${dir.path}/restored.sqlite';
    File(path).copySync(copyPath);
    final copy = SideDb.openOrCreate(copyPath);
    expect(copy.deviceId, id);
    copy.close();
  });
}
