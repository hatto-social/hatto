// SPDX-FileCopyrightText: 2026 Hatto Social contributors
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:io';

import 'package:hatto_store/hatto_store.dart' hide AnkiApi;
import 'package:path/path.dart' as p;
import 'package:rslib_bridge/rslib_bridge.dart';

import '../state/bootstrap_state.dart';
import '../store/write_gateway.dart';

/// Opens the side database and the collection. The UI does not call the bridge.
///
/// The instance lock is taken before either database is used, and it is held
/// for the process lifetime. A second process gets [AlreadyRunningException]
/// and must not open the collection.
class EngineHost {
  AnkiApi? _api;
  String? _collectionPath;
  SideDb? _side;
  WriteGateway? _gateway;
  InstanceLock? _lock;

  SideDb? get sideDb => _side;

  WriteGateway? get writes => _gateway;

  bool get holdsInstanceLock => _lock != null;

  Future<BootstrapState> open({required String dataDir}) async {
    final lock = InstanceLock.tryAcquire(dataDir);
    if (lock == null) {
      throw const AlreadyRunningException();
    }
    _lock = lock;
    final side = SideDb.openOrCreate(p.join(dataDir, 'hatto.sqlite'));
    _side = side;
    _gateway = WriteGateway(
      db: side,
      command: (service, method, input) async {
        throw StateError('no rslib write is open on this profile');
      },
    );
    try {
      final root = Directory(dataDir)..createSync(recursive: true);
      final media = Directory(p.join(root.path, 'collection.media'))
        ..createSync(recursive: true);
      final collectionPath = p.join(root.path, 'collection.anki2');
      final mediaDbPath = p.join(root.path, 'collection.media.db');
      final api = await AnkiApi.openDesktop(
        dataDir: root.path,
        collectionPath: collectionPath,
        mediaFolderPath: media.path,
        mediaDbPath: mediaDbPath,
      );
      _api = api;
      _collectionPath = collectionPath;
      final marker = File('$collectionPath.hatto-fsrs-init');
      final markerPresent = marker.existsSync();
      return BootstrapState(
        opened: true,
        markerPresent: markerPresent,
        message: markerPresent
            ? '컬렉션이 열려 있습니다. FSRS 초기화 마커가 있습니다.'
            : '컬렉션이 열려 있습니다.',
      );
    } catch (err) {
      side.close();
      _side = null;
      _gateway = null;
      rethrow;
    }
  }

  Future<void> close() async {
    final api = _api;
    if (api != null) {
      await api.closeCollection();
      _api = null;
    }
    final side = _side;
    if (side != null) {
      side.close();
      _side = null;
      _gateway = null;
    }
  }

  bool get markerPresent {
    final path = _collectionPath;
    if (path == null) {
      return false;
    }
    return File('$path.hatto-fsrs-init').existsSync();
  }
}
