// SPDX-FileCopyrightText: 2026 Hatto Social contributors
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';

import 'package:hatto_store/hatto_store.dart';

/// Mobile import entry. The shared pipeline is the only writer.
class MobileWriteGateway {
  MobileWriteGateway({required this.db});

  final SideDb db;
  AnkiApi? _anki;
  ImportEngine? _engine;
  String? _dataDir;
  Object? _importStartupError;

  /// Set when startup recovery failed. Import entry stays closed.
  Object? get importStartupError => _importStartupError;

  /// Binds the open collection so [importFile] and
  /// [recoverImportsAtStartup] can run. Does not write.
  void attachImport({
    required AnkiApi anki,
    required ImportEngine engine,
    required String dataDir,
  }) {
    _anki = anki;
    _engine = engine;
    _dataDir = dataDir;
  }

  void noteImportStartupFailure(Object error) {
    _importStartupError = error;
  }

  /// Startup: exclusive lock, reconcile, adopt committed imports, scan.
  Future<void> recoverImportsAtStartup() {
    final bound = _bound();
    return db.exclusive(() async {
      final reconcile = await reconcileInTurn(db: db, anki: bound.anki);
      await recoverImports(
        db: db,
        anki: bound.anki,
        engine: bound.engine,
        reconcile: reconcile,
        dataDir: bound.dataDir,
      );
      await bound.engine.scan(preparedBatchIds: preparedImportBatchIds(db));
    });
  }

  /// One import turn. Refuses when startup recovery failed.
  Future<ImportRunResult> importFile({
    required String sourcePath,
    required ImportLimits limits,
    ImportCancellationToken? cancel,
    FutureOr<void> Function(ImportPhase phase)? fault,
    void Function(ImportPhase phase)? onPhase,
  }) {
    final blocked = _importStartupError;
    if (blocked != null) {
      throw ImportStartupException(blocked);
    }
    final bound = _bound();
    final pipeline = ImportPipeline(
      db: db,
      anki: bound.anki,
      engine: bound.engine,
      dataDir: bound.dataDir,
      fault: fault,
      cancel: cancel,
    );
    return pipeline.run(
      sourcePath: sourcePath,
      limits: limits,
      onPhase: onPhase,
    );
  }

  ({AnkiApi anki, ImportEngine engine, String dataDir}) _bound() {
    final anki = _anki;
    final engine = _engine;
    final dataDir = _dataDir;
    if (anki == null || engine == null || dataDir == null) {
      throw StateError('import is not attached on this profile');
    }
    return (anki: anki, engine: engine, dataDir: dataDir);
  }
}

/// Startup recovery failed. Collection open stays available.
class ImportStartupException implements Exception {
  ImportStartupException(this.cause);

  final Object cause;

  @override
  String toString() => 'ImportStartupException: $cause';
}
