// SPDX-FileCopyrightText: 2026 Hatto Social contributors
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:io';

import 'package:hatto_store/hatto_store.dart';

/// Tries the side-database instance lock and exits.
///
/// `hold` keeps the process alive until stdin closes so a parent can prove
/// a second process is refused.
void main(List<String> args) {
  if (args.isEmpty) {
    stderr.writeln('usage: lock_probe <directory> [hold]');
    exit(2);
  }
  final lock = InstanceLock.tryAcquire(args.first);
  if (lock == null) {
    stderr.writeln(alreadyRunningMessage);
    exit(1);
  }
  stdout.writeln('acquired');
  if (args.length > 1 && args[1] == 'hold') {
    stdin.listen((_) {}, onDone: () => exit(0));
  }
}
