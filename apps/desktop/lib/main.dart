// SPDX-FileCopyrightText: 2026 Hatto Social contributors
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:rslib_bridge/rslib_bridge.dart';

import 'app.dart';
import 'effect/engine_host.dart';
import 'state/bootstrap_state.dart';
import 'third_party_licenses.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await registerBundledLicenses();
  await initRslibBridge();
  final support = await getApplicationSupportDirectory();
  final dataDir = p.join(support.path, 'hatto');
  final cache = await getTemporaryDirectory();
  prepareRuntime(tmpDir: cache.path);
  final state = await EngineHost().open(dataDir: dataDir);
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
