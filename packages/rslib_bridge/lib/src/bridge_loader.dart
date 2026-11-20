// SPDX-FileCopyrightText: 2026 Hatto Social contributors
//
// SPDX-License-Identifier: AGPL-3.0-or-later

/// Linux host library written by the native-assets hook.
///
/// `flutter test` on Linux is a host process. The default loader does not
/// search `build/native_assets/linux/`, so the bridge opens this file when
/// it is present. Android does not use this path.
const linuxBridgeLibrary = 'build/native_assets/linux/librslib_bridge.so';

/// macOS host library written by the native-assets hook.
const macOsBridgeLibrary = 'build/native_assets/macos/librslib_bridge.dylib';

/// Path to open with `ExternalLibrary.open`, or null for the default loader.
///
/// [platform] is `linux`, `macos`, `android`, or another operating system
/// name. [fileExists] is injected so tests do not touch the disk. Linux and
/// Android keep the paths they had before the macOS branch: Linux opens
/// [linuxBridgeLibrary] only when the file is there, and Android always uses
/// the default loader.
String? resolveBridgeLibrary({
  required String platform,
  required bool Function(String path) fileExists,
}) {
  if (platform == 'linux') {
    if (fileExists(linuxBridgeLibrary)) {
      return linuxBridgeLibrary;
    }
    return null;
  }
  if (platform == 'macos') {
    if (fileExists(macOsBridgeLibrary)) {
      return macOsBridgeLibrary;
    }
    return null;
  }
  return null;
}
