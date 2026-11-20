// SPDX-FileCopyrightText: 2026 Hatto Social contributors
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import '../rust/api.dart';
import 'proto_encode.dart';

export 'proto_encode.dart';

/// Dart facade over the protobuf bridge.
///
/// This setup build opens and closes a collection on the desktop profile.
/// Study calls stay for the port that brings the learning flow across.
class AnkiApi {
  AnkiApi(this.backend);

  final AnkiBackend backend;

  static Future<AnkiApi> openDesktop({
    required String dataDir,
    required String collectionPath,
    required String mediaFolderPath,
    required String mediaDbPath,
  }) async {
    final backend = await openDesktopBackend(
      initMsg: encodeBackendInit(),
      dataDir: dataDir,
    );
    final index = _index('BackendCollectionService', 'open_collection');
    final response = await command(
      backend: backend,
      service: index.service,
      method: index.method,
      input: encodeOpenCollection(
        collectionPath: collectionPath,
        mediaFolderPath: mediaFolderPath,
        mediaDbPath: mediaDbPath,
      ),
    );
    if (!response.success) {
      throw StateError('OpenCollection was rejected');
    }
    return AnkiApi(backend);
  }

  Future<void> closeCollection() async {
    final index = _index('BackendCollectionService', 'close_collection');
    final response = await command(
      backend: backend,
      service: index.service,
      method: index.method,
      input: encodeCloseCollection(),
    );
    if (!response.success) {
      throw StateError('CloseCollection was rejected');
    }
  }

  static ServiceMethodIndex _index(String service, String method) {
    final index = serviceMethodIndex(service: service, method: method);
    if (index == null) {
      throw StateError('no index for $service.$method');
    }
    return index;
  }
}
