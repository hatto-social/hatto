// SPDX-FileCopyrightText: 2026 Hatto Social contributors
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Loads the repository's OFL fonts before any test runs.
///
/// Flutter's test binding would otherwise draw with Ahem. Golden
/// comparisons on Linux use these files, which are committed next to
/// this config.
Future<void> testExecutable(Future<void> Function() testMain) async {
  TestWidgetsFlutterBinding.ensureInitialized();
  await _load('Noto Sans', 'test/fonts/NotoSans-Regular.ttf');
  await _load('Noto Sans KR', 'test/fonts/NotoSansKR-Regular.otf');
  await testMain();
}

Future<void> _load(String family, String path) async {
  final bytes = File(path).readAsBytesSync();
  final loader = FontLoader(family)
    ..addFont(Future<ByteData>.value(ByteData.sublistView(bytes)));
  await loader.load();
}
