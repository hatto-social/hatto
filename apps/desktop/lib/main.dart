// SPDX-FileCopyrightText: 2026 Hatto Social contributors
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:hatto_store/hatto_store.dart' hide AnkiApi;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:rslib_bridge/rslib_bridge.dart';

import 'app.dart';
import 'effect/engine_host.dart';
import 'state/bootstrap_state.dart';
import 'third_party_licenses.dart';

/// Kept for the process lifetime so the instance lock is not released.
final EngineHost desktopHost = EngineHost();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await registerBundledLicenses();
  await initRslibBridge();
  final support = await getApplicationSupportDirectory();
  final dataDir = p.join(support.path, 'hatto');
  final cache = await getTemporaryDirectory();
  prepareRuntime(tmpDir: cache.path);
  final BootstrapState state;
  try {
    state = await desktopHost.open(dataDir: dataDir);
  } on AlreadyRunningException {
    stderr.writeln(alreadyRunningMessage);
    exit(1);
  }
  runApp(HattoDesktopApp(state: state));
}

/// Home screen used by tests that do not open a collection.
class HattoDesktopPreview extends StatelessWidget {
  const HattoDesktopPreview({
    super.key,
    this.state = const BootstrapState.closed(),
  });

  final BootstrapState state;

  @override
  Widget build(BuildContext context) {
    return HattoDesktopApp(state: state);
  }
}
