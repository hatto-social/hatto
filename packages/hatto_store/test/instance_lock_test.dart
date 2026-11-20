// SPDX-FileCopyrightText: 2026 Hatto Social contributors
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:convert';
import 'dart:io';

import 'package:hatto_store/hatto_store.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  test('the same process reacquires the lock it already holds', () async {
    final dir = await Directory.systemTemp.createTemp('hatto-lock-same');
    addTearDown(() async {
      if (dir.existsSync()) {
        await dir.delete(recursive: true);
      }
    });
    final first = InstanceLock.tryAcquire(dir.path);
    addTearDown(() => first?.release());
    final second = InstanceLock.tryAcquire(dir.path);
    expect(second, same(first));
    final lockFile = File(p.join(dir.path, 'hatto.lock'));
    expect(lockFile.existsSync(), isTrue);
    final mode = lockFile.statSync().mode & 0x1ff;
    expect(mode & 0x180, 0x180);
  });

  test('a second process reports already running and exits', () async {
    final dir = await Directory.systemTemp.createTemp('hatto-lock-other');
    final held = InstanceLock.tryAcquire(dir.path);
    addTearDown(() async {
      held?.release();
      if (dir.existsSync()) {
        await dir.delete(recursive: true);
      }
    });
    expect(held, isNotNull);

    final child = await Process.start(dartExecutable(), [
      'run',
      'bin/lock_probe.dart',
      dir.path,
    ], workingDirectory: Directory.current.path);
    final stderrText = await child.stderr.transform(utf8.decoder).join();
    final code = await child.exitCode.timeout(const Duration(minutes: 2));
    expect(code, 1);
    expect(stderrText, contains(alreadyRunningMessage));
  });

  test('releasing the lock lets another process acquire it', () async {
    final dir = await Directory.systemTemp.createTemp('hatto-lock-release');
    addTearDown(() async {
      if (dir.existsSync()) {
        await dir.delete(recursive: true);
      }
    });
    final held = InstanceLock.tryAcquire(dir.path);
    expect(held, isNotNull);
    held!.release();

    final child = await Process.start(dartExecutable(), [
      'run',
      'bin/lock_probe.dart',
      dir.path,
    ], workingDirectory: Directory.current.path);
    final stdoutText = await child.stdout.transform(utf8.decoder).join();
    final code = await child.exitCode.timeout(const Duration(minutes: 2));
    expect(code, 0);
    expect(stdoutText, contains('acquired'));
  });
}

String dartExecutable() {
  final resolved = Platform.resolvedExecutable;
  final base = p.basename(resolved);
  if (base == 'dart' || base == 'dart.exe') {
    return resolved;
  }
  final which = Process.runSync('which', ['dart']);
  if (which.exitCode == 0) {
    final line = (which.stdout as String).trim().split('\n').first.trim();
    if (line.isNotEmpty) {
      return line;
    }
  }
  throw StateError('dart is not on PATH (resolved executable: $resolved)');
}
