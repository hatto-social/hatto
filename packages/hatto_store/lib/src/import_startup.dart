// SPDX-FileCopyrightText: 2026 Hatto Social contributors
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:io';

import 'package:path/path.dart' as p;

import 'intent_ops.dart';
import 'side_db.dart';

/// True when an import intent exists or a working import folder is not empty.
///
/// Absent directories count as empty. This does not take the side-database
/// lock and does not delete anything. Desktop and mobile share this check.
bool importStartupNeeded(SideDb db, String dataDir) {
  for (final intent in db.pendingIntents()) {
    if (intent.op == intentImport) {
      return true;
    }
  }
  for (final name in const ['raw', 'e', 'staged']) {
    final dir = Directory(p.join(dataDir, 'import', name));
    if (!dir.existsSync()) {
      continue;
    }
    if (dir.listSync(followLinks: false).isNotEmpty) {
      return true;
    }
  }
  return false;
}
