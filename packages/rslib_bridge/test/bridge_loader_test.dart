// SPDX-FileCopyrightText: 2026 Hatto Social contributors
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter_test/flutter_test.dart';
import 'package:rslib_bridge/src/bridge_loader.dart';

void main() {
  String? resolve(String platform, Set<String> present) {
    return resolveBridgeLibrary(
      platform: platform,
      fileExists: present.contains,
    );
  }

  test('linux with the host library keeps the existing path', () {
    expect(resolve('linux', {linuxBridgeLibrary}), linuxBridgeLibrary);
  });

  test('linux without the host library uses the default loader', () {
    expect(resolve('linux', {}), isNull);
  });

  test('android uses the default loader', () {
    expect(
      resolve('android', {linuxBridgeLibrary, macOsBridgeLibrary}),
      isNull,
    );
  });

  test('macos with the host library opens the dylib', () {
    expect(resolve('macos', {macOsBridgeLibrary}), macOsBridgeLibrary);
  });

  test('macos without the host library uses the default loader', () {
    expect(resolve('macos', {}), isNull);
  });
}
