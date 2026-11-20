// SPDX-FileCopyrightText: 2026 Hatto Social contributors
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:io';

import 'package:hatto_desktop/state/open_url_policy.dart';

/// Opens [url] with the platform opener.
///
/// macOS uses `open`. Linux uses `xdg-open`. The argument is a list and
/// the shell is not involved. Only https URLs are passed through.
Future<void> openExternalUrl(Uri url) async {
  if (!isHttpsUrl(url.toString())) {
    throw ArgumentError.value(url, 'url', 'only https URLs can be opened');
  }
  final executable = Platform.isMacOS ? 'open' : 'xdg-open';
  final result = await Process.run(executable, [
    url.toString(),
  ], runInShell: false);
  if (result.exitCode != 0) {
    throw StateError(
      'failed to open url (exit ${result.exitCode}): ${result.stderr}',
    );
  }
}
