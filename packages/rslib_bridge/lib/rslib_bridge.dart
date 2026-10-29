/// Dart API for the rslib bridge.
///
/// Generated bindings live in `src/rust/` and are produced by
/// `flutter_rust_bridge_codegen generate`. Collection calls are protobuf bytes.
library;

import 'dart:io';

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated_io.dart';

import 'src/rust/frb_generated.dart';

export 'src/rust/api.dart';
export 'src/rust/frb_generated.dart' show RustLib;

/// Load the bridge library and run its Rust initializer.
///
/// On Android the APK contains `librslib_bridge.so` and the process linker
/// finds it by name. Host `flutter test` is a Linux process: the native-assets
/// hook drops that same library under `build/native_assets/linux/`, which the
/// default loader does not search, so open that file when it is present.
Future<void> initRslibBridge() async {
  final hostAsset = File('build/native_assets/linux/librslib_bridge.so');
  if (Platform.isLinux && hostAsset.existsSync()) {
    await RustLib.init(
      externalLibrary: ExternalLibrary.open(hostAsset.absolute.path),
    );
    return;
  }
  await RustLib.init();
}
