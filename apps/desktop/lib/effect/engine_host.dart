// SPDX-FileCopyrightText: 2026 Hatto Social contributors
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:rslib_bridge/rslib_bridge.dart';

import '../state/bootstrap_state.dart';

/// Opens and closes the desktop collection. The UI does not call the bridge.
class EngineHost {
  AnkiApi? _api;
  String? _collectionPath;

  Future<BootstrapState> open({required String dataDir}) async {
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
  }

  Future<void> close() async {
    final api = _api;
    if (api == null) {
      return;
    }
    await api.closeCollection();
    _api = null;
  }

  bool get markerPresent {
    final path = _collectionPath;
    if (path == null) {
      return false;
    }
    return File('$path.hatto-fsrs-init').existsSync();
  }
}
