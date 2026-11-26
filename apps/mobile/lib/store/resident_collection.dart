// SPDX-FileCopyrightText: 2026 Hatto Social contributors
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:rslib_bridge/rslib_bridge.dart' as bridge;

import 'pb.dart';

/// One protobuf call failed. [kind] is `BackendError.kind` when the payload
/// decoded.
class BackendCallException implements Exception {
  BackendCallException({
    required this.service,
    required this.method,
    required this.message,
    this.kind,
  });

  final String service;
  final String method;
  final String message;
  final int? kind;

  @override
  String toString() {
    final kindText = kind == null ? '' : ' (kind=$kind)';
    return '$service.$method failed: $message$kindText';
  }
}

/// One `command` call. Throws [BackendCallException] when rslib rejects it.
Future<Uint8List> callBackend({
  required bridge.AnkiBackend backend,
  required String service,
  required String method,
  required Uint8List input,
}) async {
  final index = bridge.serviceMethodIndex(service: service, method: method);
  if (index == null) {
    throw StateError('no protobuf index for $service.$method');
  }
  final response = await bridge.command(
    backend: backend,
    service: index.service,
    method: index.method,
    input: input,
  );
  if (!response.success) {
    final error = readBackendError(response.payload);
    throw BackendCallException(
      service: service,
      method: method,
      message: error.message ?? 'undecodable backend error',
      kind: error.kind,
    );
  }
  return response.payload;
}

/// An open resident collection. Paths match `smoke_open_collection`:
/// `collection.anki2`, `collection.media`, and `collection.media.db`.
class ResidentCollection {
  ResidentCollection._(this.backend);

  final bridge.AnkiBackend backend;
  var _closed = false;

  static Future<ResidentCollection> open(String directory) async {
    final root = Directory(directory)..createSync(recursive: true);
    final media = Directory(p.join(root.path, 'collection.media'))
      ..createSync(recursive: true);
    final backend = await bridge.openBackend(initMsg: encodeBackendInit());
    var opened = false;
    try {
      await callBackend(
        backend: backend,
        service: 'BackendCollectionService',
        method: 'open_collection',
        input: encodeOpenCollection(
          collectionPath: p.join(root.path, 'collection.anki2'),
          mediaFolderPath: media.path,
          mediaDbPath: p.join(root.path, 'collection.media.db'),
        ),
      );
      opened = true;
      return ResidentCollection._(backend);
    } catch (err) {
      if (opened) {
        await _closeQuietly(backend);
      }
      rethrow;
    }
  }

  Future<Uint8List> command({
    required String service,
    required String method,
    required Uint8List input,
  }) {
    return callBackend(
      backend: backend,
      service: service,
      method: method,
      input: input,
    );
  }

  /// Closes the collection. A second call is safe.
  Future<void> close() {
    if (_closed) {
      return Future<void>.value();
    }
    _closed = true;
    return callBackend(
      backend: backend,
      service: 'BackendCollectionService',
      method: 'close_collection',
      input: Uint8List(0),
    );
  }
}

Future<void> _closeQuietly(bridge.AnkiBackend backend) async {
  try {
    await callBackend(
      backend: backend,
      service: 'BackendCollectionService',
      method: 'close_collection',
      input: Uint8List(0),
    );
  } catch (_) {
    // Open failed after the collection call returned. Best-effort close.
  }
}
