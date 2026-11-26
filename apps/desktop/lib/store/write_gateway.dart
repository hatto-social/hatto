// SPDX-FileCopyrightText: 2026 Hatto Social contributors
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';
import 'dart:typed_data';

import 'package:hatto_store/hatto_store.dart';

/// The only desktop file that writes the side database.
///
/// Desktop v0 does not append edit-journal rows. [run] passes `journal:
/// false` and runs [map] in the same side-DB transaction that deletes the
/// intent. Reconciliation is the same module mobile can call.
class WriteGateway {
  WriteGateway({
    required this.db,
    required ProtoCommand command,
    void Function(WritePhase phase)? fault,
  }) : _writes = WriteWrapper(db: db, command: command, fault: fault);

  final SideDb db;
  final WriteWrapper _writes;
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

  Future<ProtoResponse> run({
    required String op,
    required String entityKind,
    required String guid,
    required int service,
    required int method,
    required Uint8List input,
    String? expected,
    MappingCallback? map,
    MediaJournal? media,
  }) {
    return _writes.run(
      op: op,
      entityKind: entityKind,
      guid: guid,
      service: service,
      method: method,
      input: input,
      expected: expected,
      journal: false,
      map: map,
      media: media,
    );
  }

  Future<ReconcileResult> reconcile(AnkiApi anki) {
    return reconcileCollection(db: db, anki: anki);
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
  Future<ImportOutcome> importFile({
    required String sourcePath,
    required int maxBytes,
    ImportCancellationToken? cancel,
    FutureOr<void> Function(ImportPhase phase)? fault,
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
    return pipeline.run(sourcePath: sourcePath, maxBytes: maxBytes);
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

/// Startup recovery failed. Collection open and review stay available.
class ImportStartupException implements Exception {
  ImportStartupException(this.cause);

  final Object cause;

  @override
  String toString() => 'ImportStartupException: $cause';
}
