// SPDX-FileCopyrightText: 2026 Hatto Social contributors
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';
import 'dart:io';

import 'import_archive.dart';
import 'import_engine.dart';
import 'import_error.dart';
import 'import_intent.dart';
import 'import_recovery.dart';
import 'intent_ops.dart';
import 'reconcile.dart';
import 'schema.dart';
import 'side_db.dart';

/// How one import turn finished.
///
/// Classification only. Toast copy is I5.
enum ImportOutcome {
  /// The file had no NEW and no CHANGED notes. The resident collection
  /// was not written.
  noop,

  /// The resident import committed and the side database adopted it.
  committed,

  /// The resident import was not called, or the turn stopped before it.
  failedBeforeCommit,

  /// [ImportEngine.commitResident] returned, then adoption did not finish.
  /// The intent row is still there for the next startup.
  failedAfterCommit,

  /// An exception happened after the intent was persisted, and it is not
  /// known whether the resident collection changed. The intent stays for
  /// the next startup. Callers must not claim the collection is unchanged.
  failedUnknown,

  /// A pre-commit boundary saw [ImportCancellationToken.isCancelled].
  cancelled,
}

/// Points where a test can throw to simulate a crash, or where cancel is
/// checked.
///
/// Cancel is read only on the pre-commit values. It is not read at
/// [afterResidentCommit], [afterArchive], or [duringAdoption].
enum ImportPhase {
  /// [reconcileInTurn] has returned. [ImportEngine.stageE] has not run.
  afterReconcile,

  /// [ImportEngine.stageE] has returned. `note_map` has not been read.
  afterStage,

  /// `notesByGuids` has returned. [ImportEngine.residentLookup] has not run.
  afterNoteMap,

  /// [ImportEngine.residentLookup] has returned. [ImportEngine.finish] has
  /// not run.
  afterResidentLookup,

  /// [ImportEngine.finish] has returned. The no-op decision has not run.
  afterFinish,

  /// `pre` has been read. The intent row has not been inserted.
  afterPre,

  /// The intent row is committed. The resident import has not been called.
  afterIntent,

  /// The staged-hash check passed. [ImportEngine.commitResident] is next.
  beforeResidentCommit,

  /// [ImportEngine.commitResident] has returned. The archive copy has not
  /// started.
  afterResidentCommit,

  /// The archive copy has finished. The adoption transaction has not started.
  afterArchive,

  /// Inside the adoption transaction, before its writes.
  duringAdoption,
}

/// Set [cancel] to stop an import at the next pre-commit boundary.
class ImportCancellationToken {
  bool _cancelled = false;

  bool get isCancelled => _cancelled;

  void cancel() {
    _cancelled = true;
  }
}

/// `target_key` of each pending `op = 'import'` row.
List<String> preparedImportBatchIds(SideDb db) {
  return [
    for (final intent in db.pendingIntents())
      if (intent.op == intentImport) intent.targetKey,
  ];
}

/// One import, inside a single [SideDb.exclusive] turn.
///
/// The turn never calls [WriteWrapper.run]. Folder cleanup is only
/// [ImportEngine.scan] of the remaining import target keys. This class does
/// not delete `import/` paths with `dart:io`.
class ImportPipeline {
  ImportPipeline({
    required this.db,
    required this.anki,
    required this.engine,
    required this.dataDir,
    this.fault,
    this.cancel,
  });

  final SideDb db;
  final AnkiApi anki;
  final ImportEngine engine;
  final String dataDir;

  /// Test hook. Production callers leave this null.
  ///
  /// [ImportPhase.duringAdoption] runs inside the side-database transaction,
  /// so that callback must not return a [Future].
  final FutureOr<void> Function(ImportPhase phase)? fault;

  final ImportCancellationToken? cancel;

  /// UI progress for the current [run]. Not called inside the adoption
  /// transaction. A throw is ignored.
  void Function(ImportPhase phase)? _onPhase;

  Future<ImportRunResult> run({
    required String sourcePath,
    required ImportLimits limits,
    void Function(ImportPhase phase)? onPhase,
  }) {
    return db.exclusive(() async {
      _onPhase = onPhase;
      try {
        return await _run(sourcePath: sourcePath, limits: limits);
      } finally {
        _onPhase = null;
      }
    });
  }

  Future<ImportRunResult> _run({
    required String sourcePath,
    required ImportLimits limits,
  }) async {
    db.requireExclusiveTurn('ImportPipeline');
    StagedImport? staged;
    PreparedPlan? plan;
    var stagedTaken = false;
    var intentId = 0;
    var inserted = false;
    var residentCommitted = false;
    Future<void> releaseThenScan() async {
      if (!stagedTaken) {
        final open = staged;
        staged = null;
        open?.dispose();
      }
      await _scan();
    }

    try {
      await reconcileInTurn(db: db, anki: anki);
      if (await _cancelled(ImportPhase.afterReconcile)) {
        return _result(outcome: ImportOutcome.cancelled);
      }

      staged = await engine.stageE(sourcePath: sourcePath, limits: limits);
      final opened = staged!;
      if (await _cancelled(ImportPhase.afterStage)) {
        return await _cancelTurn(
          inserted: inserted,
          intentId: intentId,
          scan: releaseThenScan,
          plan: plan,
        );
      }

      final mapped = db.notesByGuids([
        for (final note in opened.fileNotes) note.guid,
      ]);
      if (await _cancelled(ImportPhase.afterNoteMap)) {
        return await _cancelTurn(
          inserted: inserted,
          intentId: intentId,
          scan: releaseThenScan,
          plan: plan,
        );
      }

      final ids = _residentIds(opened.fileNotes, mapped);
      final match = await engine.residentLookup(
        noteIds: ids,
        deckNames: opened.deckNames,
      );
      if (await _cancelled(ImportPhase.afterResidentLookup)) {
        return await _cancelTurn(
          inserted: inserted,
          intentId: intentId,
          scan: releaseThenScan,
          plan: plan,
        );
      }

      plan = await engine.finish(
        staged: opened,
        residentFacts: match.notes,
        foundDeckNames: match.foundDeckNames,
      );
      final prepared = plan;
      stagedTaken = true;
      if (await _cancelled(ImportPhase.afterFinish)) {
        return await _cancelTurn(
          inserted: inserted,
          intentId: intentId,
          scan: releaseThenScan,
          plan: plan,
        );
      }
      if (prepared.counts.noResidentCall) {
        await releaseThenScan();
        return _result(outcome: ImportOutcome.noop, plan: prepared);
      }

      final noteCount = await engine.notetypeUseCountSum();
      final preChanged = _preChanged(prepared.changed.keys, match.notes);
      if (preChanged == null) {
        await releaseThenScan();
        return _result(
          outcome: ImportOutcome.failedBeforeCommit,
          plan: prepared,
        );
      }
      if (await _cancelled(ImportPhase.afterPre)) {
        return await _cancelTurn(
          inserted: inserted,
          intentId: intentId,
          scan: releaseThenScan,
          plan: plan,
        );
      }

      final sourceSha = sha256OfFile(
        File(importRawApkgPath(dataDir, prepared.batchId)),
      );
      final expected = ImportIntentExpected(
        sourceSha256: sourceSha,
        stagedSha256: prepared.stagedSha256,
        firstImport: prepared.firstImport,
        newGuids: prepared.newGuids,
        changed: prepared.changed,
        deckNames: prepared.deckNames,
        pre: ImportIntentPre(noteCount: noteCount, changed: preChanged),
      );
      intentId = db.beginIntent(
        op: intentImport,
        targetKey: prepared.batchId,
        expected: encodeImportIntentExpected(expected),
      );
      inserted = true;
      if (await _cancelled(ImportPhase.afterIntent)) {
        return await _cancelTurn(
          inserted: inserted,
          intentId: intentId,
          scan: releaseThenScan,
          plan: plan,
        );
      }
      if (!_layerW(
        batchId: prepared.batchId,
        stagedSha256: prepared.stagedSha256,
        stagedPath: prepared.stagedPath,
      )) {
        _abandon(intentId);
        await releaseThenScan();
        return _result(
          outcome: ImportOutcome.failedBeforeCommit,
          plan: prepared,
        );
      }
      if (await _cancelled(ImportPhase.beforeResidentCommit)) {
        return await _cancelTurn(
          inserted: inserted,
          intentId: intentId,
          scan: releaseThenScan,
          plan: plan,
        );
      }

      final ResidentImportResult committed;
      try {
        committed = await engine.commitResident(
          stagedPath: prepared.stagedPath,
          firstImport: prepared.firstImport,
        );
      } on _FaultEscape {
        rethrow;
      } catch (err, stack) {
        return await _settleRejectedCommit(
          expected: expected,
          intentId: intentId,
          batchId: prepared.batchId,
          scan: releaseThenScan,
          plan: prepared,
          error: err,
          stack: stack,
        );
      }
      residentCommitted = true;
      await _fault(ImportPhase.afterResidentCommit);

      try {
        final landed = await _landedNewNotes(
          ids: committed.newNoteIds,
          newGuids: expected.newGuids,
        );
        await adoptCommittedImport(
          db: db,
          anki: anki,
          engine: engine,
          expected: expected,
          batchId: prepared.batchId,
          intentId: intentId,
          dataDir: dataDir,
          noteIdsByGuid: landed,
          afterArchive: () => _fault(ImportPhase.afterArchive),
          beforeWrites: () {
            try {
              _faultSync(ImportPhase.duringAdoption);
            } catch (err, stack) {
              throw _FaultEscape(err, stack);
            }
          },
        );
      } on _FaultEscape {
        rethrow;
      } catch (err, stack) {
        await releaseThenScan();
        return _result(
          outcome: ImportOutcome.failedAfterCommit,
          plan: prepared,
          error: err,
          stack: stack,
        );
      }
      await releaseThenScan();
      return _result(outcome: ImportOutcome.committed, plan: prepared);
    } on _FaultEscape catch (err) {
      Error.throwWithStackTrace(err.cause, err.stack);
    } catch (err, stack) {
      if (residentCommitted) {
        await releaseThenScan();
        return _result(
          outcome: ImportOutcome.failedAfterCommit,
          plan: plan,
          error: err,
          stack: stack,
        );
      }
      if (inserted) {
        return _result(
          outcome: ImportOutcome.failedUnknown,
          plan: plan,
          error: err,
          stack: stack,
        );
      }
      await releaseThenScan();
      return _result(
        outcome: ImportOutcome.failedBeforeCommit,
        error: err,
        stack: stack,
      );
    } finally {
      staged?.dispose();
    }
  }

  Future<ImportRunResult> _cancelTurn({
    required bool inserted,
    required int intentId,
    required Future<void> Function() scan,
    PreparedPlan? plan,
  }) async {
    if (inserted) {
      _abandon(intentId);
    }
    await scan();
    return _result(outcome: ImportOutcome.cancelled, plan: plan);
  }

  /// [commitResident] threw. Reconcile and either drop the intent or adopt.
  ///
  /// A throw from reconcile is [ImportOutcome.failedUnknown]: the intent
  /// stays, because it is not known whether the resident collection changed.
  /// The original commit error stays on [ImportRunResult.commitError] when
  /// the outcome is [ImportOutcome.committed], [ImportOutcome.failedAfterCommit],
  /// or this unknown settlement. It is not copied into user-facing text.
  Future<ImportRunResult> _settleRejectedCommit({
    required ImportIntentExpected expected,
    required int intentId,
    required String batchId,
    required Future<void> Function() scan,
    required PreparedPlan plan,
    required Object error,
    required StackTrace stack,
  }) async {
    final ReconcileResult again;
    try {
      again = await reconcileInTurn(db: db, anki: anki);
    } catch (err, reconcileStack) {
      return _result(
        outcome: ImportOutcome.failedUnknown,
        plan: plan,
        error: err,
        stack: reconcileStack,
        commitError: error,
        commitStack: stack,
      );
    }
    final didCommit = await importCommitted(
      db: db,
      engine: engine,
      reconcile: again,
      expected: expected,
    );
    if (!didCommit) {
      _abandon(intentId);
      await scan();
      return _result(
        outcome: ImportOutcome.failedBeforeCommit,
        plan: plan,
        error: error,
        stack: stack,
      );
    }
    try {
      await adoptCommittedImport(
        db: db,
        anki: anki,
        engine: engine,
        expected: expected,
        batchId: batchId,
        intentId: intentId,
        dataDir: dataDir,
        noteIdsByGuid: again.residentImportNotes,
        reservedDeckIds: again.reservedImportDecks,
        afterArchive: () => _fault(ImportPhase.afterArchive),
        beforeWrites: () {
          try {
            _faultSync(ImportPhase.duringAdoption);
          } catch (err, adoptStack) {
            throw _FaultEscape(err, adoptStack);
          }
        },
      );
    } on _FaultEscape {
      rethrow;
    } catch (err, adoptStack) {
      await scan();
      return _result(
        outcome: ImportOutcome.failedAfterCommit,
        plan: plan,
        error: err,
        stack: adoptStack,
        commitError: error,
        commitStack: stack,
      );
    }
    await scan();
    return _result(
      outcome: ImportOutcome.committed,
      plan: plan,
      commitError: error,
      commitStack: stack,
    );
  }

  Future<bool> _cancelled(ImportPhase phase) async {
    await _fault(phase);
    if (!_preCommit.contains(phase)) {
      return false;
    }
    return cancel?.isCancelled ?? false;
  }

  Future<void> _fault(ImportPhase phase) async {
    _emitPhase(phase);
    final hook = fault;
    if (hook == null) {
      return;
    }
    try {
      await hook(phase);
    } catch (err, stack) {
      Error.throwWithStackTrace(_FaultEscape(err, stack), stack);
    }
  }

  void _emitPhase(ImportPhase phase) {
    if (phase == ImportPhase.duringAdoption) {
      return;
    }
    final hook = _onPhase;
    if (hook == null) {
      return;
    }
    try {
      hook(phase);
    } catch (_) {
      // The screen owns this callback. A throw must not stop the import.
    }
  }

  ImportRunResult _result({
    required ImportOutcome outcome,
    PreparedPlan? plan,
    Object? error,
    StackTrace? stack,
    Object? commitError,
    StackTrace? commitStack,
  }) {
    return ImportRunResult(
      outcome: outcome,
      plan: plan,
      error: error,
      stack: stack,
      commitError: commitError,
      commitStack: commitStack,
    );
  }

  void _faultSync(ImportPhase phase) {
    final hook = fault;
    if (hook == null) {
      return;
    }
    final result = hook(phase);
    if (result is Future) {
      throw StateError('${phase.name} fault must be synchronous');
    }
  }

  bool _layerW({
    required String batchId,
    required String stagedSha256,
    required String stagedPath,
  }) {
    var found = false;
    for (final intent in db.pendingIntents()) {
      if (intent.op == intentImport && intent.targetKey == batchId) {
        found = true;
        break;
      }
    }
    if (!found) {
      return false;
    }
    final staged = File(stagedPath);
    if (!staged.existsSync()) {
      return false;
    }
    try {
      return sha256OfFile(staged) == stagedSha256;
    } on SideDbException {
      return false;
    }
  }

  void _abandon(int intentId) {
    for (final intent in db.pendingIntents()) {
      if (intent.id == intentId) {
        db.abandonIntent(intentId);
        return;
      }
    }
  }

  Future<void> _scan() {
    return engine.scan(preparedBatchIds: preparedImportBatchIds(db));
  }

  Future<Map<String, int>> _landedNewNotes({
    required List<int> ids,
    required List<String> newGuids,
  }) async {
    final wanted = newGuids.toSet();
    final landed = <String, int>{};
    for (final id in ids) {
      final note = await anki.getNote(id);
      if (wanted.contains(note.guid)) {
        landed[note.guid] = id;
      }
    }
    return landed;
  }
}

const Set<ImportPhase> _preCommit = {
  ImportPhase.afterReconcile,
  ImportPhase.afterStage,
  ImportPhase.afterNoteMap,
  ImportPhase.afterResidentLookup,
  ImportPhase.afterFinish,
  ImportPhase.afterPre,
  ImportPhase.afterIntent,
  ImportPhase.beforeResidentCommit,
};

List<int> _residentIds(
  List<StagedFileNote> notes,
  Map<String, NoteMapRow> mapped,
) {
  final ids = <int>[];
  final seen = <int>{};
  for (final note in notes) {
    final row = mapped[note.guid];
    if (row != null && seen.add(row.rslibNoteId)) {
      ids.add(row.rslibNoteId);
    }
  }
  return ids;
}

/// Resident hashes for [changedGuids], or null when one guid is missing.
Map<String, String>? _preChanged(
  Iterable<String> changedGuids,
  List<ResidentNoteFacts> notes,
) {
  final byGuid = <String, String>{
    for (final note in notes) note.guid: note.contentHashHex,
  };
  final changed = <String, String>{};
  for (final guid in changedGuids) {
    final hash = byGuid[guid];
    if (hash == null || !sha256Hex.hasMatch(hash)) {
      return null;
    }
    changed[guid] = hash;
  }
  return changed;
}

/// One import turn. [plan] is set once [ImportEngine.finish] has returned.
class ImportRunResult {
  const ImportRunResult({
    required this.outcome,
    this.plan,
    this.error,
    this.stack,
    this.commitError,
    this.commitStack,
  });

  final ImportOutcome outcome;

  /// Populated for [ImportOutcome.noop], [ImportOutcome.committed],
  /// [ImportOutcome.failedAfterCommit], and [ImportOutcome.failedUnknown]
  /// when finish has returned. Null for a pre-finish cancellation or failure.
  final PreparedPlan? plan;

  /// Set when the turn stopped because something threw.
  ///
  /// User-facing copy may classify this with [errorKind]. It must not show
  /// [error] or [stack] as text.
  final Object? error;
  final StackTrace? stack;

  /// The [ImportEngine.commitResident] failure, when settlement does not
  /// return it as [error].
  ///
  /// Set for [ImportOutcome.committed] and [ImportOutcome.failedAfterCommit]
  /// after a rejected commit, and for [ImportOutcome.failedUnknown] when
  /// reconcile throws during that settlement. A rejected commit that did
  /// not land keeps the failure on [error] and leaves this null. User-facing
  /// copy does not read this.
  final Object? commitError;
  final StackTrace? commitStack;

  /// Rust prefix on [error], when the message carries one.
  ImportErrorKind? get errorKind => importErrorKind(error);
}

class _FaultEscape implements Exception {
  _FaultEscape(this.cause, this.stack);

  final Object cause;
  final StackTrace stack;
}
