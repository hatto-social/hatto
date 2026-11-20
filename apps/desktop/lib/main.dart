// SPDX-FileCopyrightText: 2026 Hatto Social contributors
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:rslib_bridge/rslib_bridge.dart';

import 'app.dart';
import 'editor/anki_ui.dart';
import 'effect/engine_host.dart';
import 'services/audio_service.dart';
import 'state/app_controller.dart';
import 'state/bootstrap_state.dart';
import 'third_party_licenses.dart';
import 'ui/shell.dart';
import 'ui/startup_failure.dart';

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
  try {
    await desktopHost.open(dataDir: dataDir);
  } catch (err) {
    final message = startupDialogMessage(err);
    if (message != null) {
      stderr.writeln(message);
      runApp(StartupFailureApp(message: message));
      return;
    }
    rethrow;
  }
  final api = desktopHost.flow!;
  final controller = AppController(api, audio: AudioplayersAudioService());
  await controller.refreshDecks();
  runApp(FlowDesktopApp(controller: controller));
}

class FlowDesktopApp extends StatelessWidget {
  const FlowDesktopApp({super.key, required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    const colors = AnkiColors.light;
    return MaterialApp(
      title: 'Hatto',
      theme: ThemeData(
        fontFamily: kUiFont,
        fontFamilyFallback: const ['Noto Sans KR'],
      ),
      home: MainShell(app: controller, colors: colors),
    );
  }
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
