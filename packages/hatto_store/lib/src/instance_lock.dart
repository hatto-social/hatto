// SPDX-FileCopyrightText: 2026 Hatto Social contributors
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:ffi';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'schema.dart';

/// Text a second process prints before it exits.
const String alreadyRunningMessage = 'already running';

/// Thrown when [InstanceLock.tryAcquire] finds another process holding
/// the lock. The collection must not be opened after this.
class AlreadyRunningException implements Exception {
  const AlreadyRunningException();

  @override
  String toString() => alreadyRunningMessage;
}

/// Exclusive OS file lock on `hatto.lock` beside `hatto.sqlite`.
///
/// Taken before the collection opens and held until process exit (or
/// [release] in a test). A second process gets null and should report
/// [alreadyRunningMessage] and exit. The lock is `flock`, not the file's
/// contents, so a stale pid in the file cannot keep a dead process's claim.
class InstanceLock {
  InstanceLock._(this._key, this._fd);

  static final Map<String, InstanceLock> _held = {};

  final String _key;
  final int _fd;
  var _released = false;

  /// Non-blocking exclusive lock on `hatto.lock` in [directory].
  ///
  /// [directory] is the folder that contains `hatto.sqlite`. A second call
  /// in this process returns the same lock. A second process returns null.
  static InstanceLock? tryAcquire(String directory) {
    final dir = Directory(directory);
    dir.createSync(recursive: true);
    final key = p.normalize(dir.absolute.path);
    final existing = _held[key];
    if (existing != null) {
      return existing;
    }
    final libc = _Libc.instance;
    final path = p.join(key, 'hatto.lock');
    final fd = libc.openLock(path);
    if (fd < 0) {
      throw SideDbException('could not open $path (errno ${libc.errno()})');
    }
    final err = libc.lockExclusive(fd);
    if (err != 0) {
      libc.close(fd);
      if (err == libc.eAgain) {
        return null;
      }
      throw SideDbException('could not lock $path (errno $err)');
    }
    final lock = InstanceLock._(key, fd);
    _held[key] = lock;
    return lock;
  }

  /// Drops the lock. The desktop app does not call this; process exit does.
  void release() {
    if (_released) {
      return;
    }
    _released = true;
    _held.remove(_key);
    final libc = _Libc.instance;
    libc.flock(_fd, _Libc.lockUn);
    libc.close(_fd);
  }
}

class _Libc {
  _Libc(DynamicLibrary lib)
    : malloc = lib
          .lookupFunction<
            Pointer<Uint8> Function(IntPtr),
            Pointer<Uint8> Function(int)
          >('malloc'),
      free = lib
          .lookupFunction<
            Void Function(Pointer<Uint8>),
            void Function(Pointer<Uint8>)
          >('free'),
      _open = lib
          .lookupFunction<
            Int32 Function(Pointer<Uint8>, Int32, Int32),
            int Function(Pointer<Uint8>, int, int)
          >('open'),
      flock = lib
          .lookupFunction<Int32 Function(Int32, Int32), int Function(int, int)>(
            'flock',
          ),
      close = lib.lookupFunction<Int32 Function(Int32), int Function(int)>(
        'close',
      ),
      _errnoLocation = lib
          .lookupFunction<Pointer<Int32> Function(), Pointer<Int32> Function()>(
            Platform.isMacOS ? '__error' : '__errno_location',
          );

  static final _Libc instance = _Libc(_openLib());

  static const int lockEx = 2;
  static const int lockNb = 4;
  static const int lockUn = 8;
  final Pointer<Uint8> Function(int) malloc;
  final void Function(Pointer<Uint8>) free;
  final int Function(Pointer<Uint8>, int, int) _open;
  final int Function(int, int) flock;
  final int Function(int) close;
  final Pointer<Int32> Function() _errnoLocation;

  int get eAgain => Platform.isMacOS ? 35 : 11;

  int errno() => _errnoLocation().value;

  int openLock(String path) {
    final encoded = _utf8(path);
    final ptr = malloc(encoded.length + 1);
    try {
      final view = ptr.asTypedList(encoded.length + 1);
      view.setAll(0, encoded);
      view[encoded.length] = 0;
      return _open(ptr, _oReadWrite | _oCreat | _oCloexec, 0x1a4);
    } finally {
      free(ptr);
    }
  }

  /// Returns 0 when the lock is held, otherwise errno.
  int lockExclusive(int fd) {
    while (true) {
      final rc = flock(fd, lockEx | lockNb);
      if (rc == 0) {
        return 0;
      }
      final err = errno();
      if (err == 4) {
        continue;
      }
      return err;
    }
  }

  int get _oReadWrite => 2;

  int get _oCreat => Platform.isMacOS ? 0x200 : 0x40;

  int get _oCloexec => Platform.isMacOS ? 0x01000000 : 0x80000;
}

DynamicLibrary _openLib() {
  if (Platform.isMacOS) {
    return DynamicLibrary.open('/usr/lib/libSystem.B.dylib');
  }
  if (Platform.isLinux) {
    return DynamicLibrary.open('libc.so.6');
  }
  throw UnsupportedError(
    'instance lock is implemented for Linux and macOS, not ${Platform.operatingSystem}',
  );
}

List<int> _utf8(String text) {
  // Paths the app builds are valid Unicode. Encode without package:ffi.
  final units = <int>[];
  for (final rune in text.runes) {
    if (rune < 0x80) {
      units.add(rune);
    } else if (rune < 0x800) {
      units.add(0xc0 | (rune >> 6));
      units.add(0x80 | (rune & 0x3f));
    } else if (rune < 0x10000) {
      units.add(0xe0 | (rune >> 12));
      units.add(0x80 | ((rune >> 6) & 0x3f));
      units.add(0x80 | (rune & 0x3f));
    } else {
      units.add(0xf0 | (rune >> 18));
      units.add(0x80 | ((rune >> 12) & 0x3f));
      units.add(0x80 | ((rune >> 6) & 0x3f));
      units.add(0x80 | (rune & 0x3f));
    }
  }
  return units;
}
