// SPDX-FileCopyrightText: 2026 Hatto Social contributors
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:io';

import 'package:hatto_store/hatto_store.dart' hide AnkiApi;
import 'package:path/path.dart' as p;

import '../engine/anki_api.dart';
import '../engine/engine.dart';
import '../state/bootstrap_state.dart';
import '../store/write_gateway.dart';

/// Opens the side database and the collection. Production and tests use this.
///
/// Order is fixed: the instance lock, then the side database, then the
/// collection. After a successful open the lock is held for the process
/// lifetime. A failed open releases it. A second process gets
/// [AlreadyRunningException] and must not open the collection.
class EngineHost {
  Engine? engine;
  FlowApi? flow;
  SideDb? _side;
  WriteGateway? _gateway;
  InstanceLock? _lock;
  String? _collectionPath;

  /// Engine from a failed open, after [Engine.close] marked it closed.
  /// Null when [Engine.open] itself did not return.
  Engine? markedClosedEngine;

  SideDb? get sideDb => _side;

  WriteGateway? get writes => _gateway;

  bool get holdsInstanceLock => _lock != null;

  Future<BootstrapState> open({
    required String dataDir,
    Future<void> Function(Engine engine, FlowApi api)? openCollection,
  }) async {
    final lock = InstanceLock.tryAcquire(dataDir);
    if (lock == null) {
      throw const AlreadyRunningException();
    }
    _lock = lock;
    markedClosedEngine = null;
    SideDb? side;
    try {
      side = SideDb.openOrCreate(p.join(dataDir, 'hatto.sqlite'));
      _side = side;
      _gateway = WriteGateway(
        db: side,
        command: (service, method, input) async {
          throw StateError('no rslib write is open on this profile');
        },
      );
      final opened = await Engine.open(
        dataDir: dataDir,
        langs: const ['ko', 'en'],
      );
      final api = FlowApi(opened);
      try {
        final inject = openCollection;
        if (inject != null) {
          await inject(opened, api);
        } else {
          await api.openCollection(dataDir);
        }
      } catch (err, stack) {
        opened.close();
        markedClosedEngine = opened;
        if (err is CollectionOpenException) {
          Error.throwWithStackTrace(err, stack);
        }
        Error.throwWithStackTrace(
          CollectionOpenException(err, path: _collectionFile(dataDir)),
          stack,
        );
      }
      engine = opened;
      flow = api;
      final collectionPath = p.join(dataDir, 'collection.anki2');
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
      side?.close();
      _side = null;
      _gateway = null;
      _lock?.release();
      _lock = null;
      rethrow;
    }
  }

  Future<void> close() async {
    final api = flow;
    if (api != null) {
      await api.closeCollection();
      flow = null;
    }
    engine?.close();
    engine = null;
    final side = _side;
    if (side != null) {
      side.close();
      _side = null;
      _gateway = null;
    }
  }

  static String? _collectionFile(String dataDir) {
    if (dataDir.isEmpty) {
      return null;
    }
    return File(p.join(dataDir, 'collection.anki2')).absolute.path;
  }

  bool get markerPresent {
    final path = _collectionPath;
    if (path == null) {
      return false;
    }
    return File('$path.hatto-fsrs-init').existsSync();
  }
}

/// [FlowApi.openCollection] failed after the engine was opened.
///
/// The engine is already marked closed. [path] is the absolute collection
/// file, or null when that path could not be built.
class CollectionOpenException implements Exception {
  CollectionOpenException(this.cause, {this.path});

  final Object cause;
  final String? path;

  @override
  String toString() => 'CollectionOpenException: $cause';
}
