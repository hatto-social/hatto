// SPDX-FileCopyrightText: 2026 Hatto Social contributors
//
// SPDX-License-Identifier: AGPL-3.0-or-later

/// Dart API for the rslib bridge.
///
/// Generated bindings live in `src/rust/` and are produced by
/// `flutter_rust_bridge_codegen generate`. Collection calls are protobuf bytes.
library;

import 'dart:io';

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated_io.dart';

import 'src/bridge_loader.dart';
import 'src/rust/frb_generated.dart';

export 'src/anki_api/anki_api.dart';
export 'src/bridge_loader.dart';
export 'src/rust/api.dart';
export 'src/rust/frb_generated.dart' show RustLib;

/// Load the bridge library and run its Rust initializer.
///
/// On Android the APK contains `librslib_bridge.so` and the process linker
/// finds it by name. A host test or desktop build drops the library under
/// `build/native_assets/<os>/`, which the default loader does not search, so
/// [resolveBridgeLibrary] opens that file when it is present. Linux and
/// Android keep the paths they had before the macOS branch.
Future<void> initRslibBridge() async {
  final platform = Platform.isLinux
      ? 'linux'
      : Platform.isMacOS
      ? 'macos'
      : Platform.isAndroid
      ? 'android'
      : Platform.operatingSystem;
  final relative = resolveBridgeLibrary(
    platform: platform,
    fileExists: (path) => File(path).existsSync(),
  );
  if (relative != null) {
    await RustLib.init(
      externalLibrary: ExternalLibrary.open(File(relative).absolute.path),
    );
    return;
  }
  await RustLib.init();
}
