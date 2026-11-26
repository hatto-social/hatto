// SPDX-FileCopyrightText: 2026 Hatto Social contributors
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';

import 'package:hatto_store/hatto_store.dart';

/// In-memory [ImportEngine]. Not a bridge.
class FakeImportEngine implements ImportEngine {
  FakeImportEngine({
    List<ResidentNoteFacts>? notes,
    Map<String, int>? deckIds,
    this.notetypeUseCount = 0,
    this.newNoteIds = const [],
    this.fileNotes = const [],
    this.stagedDeckNames = const [],
    this.plan,
  }) : notes = notes ?? <ResidentNoteFacts>[],
       deckIds = deckIds ?? <String, int>{};

  List<ResidentNoteFacts> notes;
  Map<String, int> deckIds;
  int notetypeUseCount;
  List<int> newNoteIds;
  List<StagedFileNote> fileNotes;
  List<String> stagedDeckNames;
  PreparedPlan? plan;

  final List<List<int>> lookupNoteIds = [];
  final List<List<String>> lookupDeckNames = [];
  String? committedPath;
  bool? committedFirstImport;
  List<String>? scannedBatchIds;
  void Function(List<String> preparedBatchIds)? onScan;
  FutureOr<void> Function()? onStage;
  Object? lookupError;
  int commitCalls = 0;
  int stageCalls = 0;
  FakeStagedImport? lastStaged;
  void Function()? onCommit;
  Future<PreparedPlan> Function(
    StagedImport staged,
    List<ResidentNoteFacts> residentFacts,
    List<String> foundDeckNames,
  )?
  finishWith;

  @override
  Future<StagedImport> stageE({
    required String sourcePath,
    required int maxBytes,
  }) async {
    stageCalls += 1;
    final hook = onStage;
    if (hook != null) {
      await hook();
    }
    final staged = FakeStagedImport(
      sourcePath: sourcePath,
      maxBytes: maxBytes,
      fileNotes: fileNotes,
      deckNames: stagedDeckNames,
    );
    lastStaged = staged;
    return staged;
  }

  @override
  Future<ResidentMatchResult> residentLookup({
    required List<int> noteIds,
    required List<String> deckNames,
  }) async {
    lookupNoteIds.add(List<int>.of(noteIds));
    lookupDeckNames.add(List<String>.of(deckNames));
    final error = lookupError;
    if (error != null) {
      throw error;
    }
    final byId = <int, ResidentNoteFacts>{
      for (final note in notes) note.id: note,
    };
    return ResidentMatchResult(
      notes: [
        for (final id in noteIds)
          if (byId.containsKey(id)) byId[id]!,
      ],
      foundDeckNames: [
        for (final name in deckNames)
          if (deckIds.containsKey(name)) name,
      ],
    );
  }

  @override
  Future<PreparedPlan> finish({
    required StagedImport staged,
    required List<ResidentNoteFacts> residentFacts,
    required List<String> foundDeckNames,
  }) async {
    final custom = finishWith;
    if (custom != null) {
      return custom(staged, residentFacts, foundDeckNames);
    }
    return plan ??
        PreparedPlan(
          batchId: '00000000-0000-4000-8000-000000000000',
          stagedPath: '',
          stagedSha256: '00' * 32,
          firstImport: foundDeckNames.isEmpty,
          newGuids: [for (final note in staged.fileNotes) note.guid],
          changed: {
            for (final note in residentFacts) note.guid: note.contentHashHex,
          },
          deckNames: staged.deckNames,
          counts: ImportPlanCounts(
            newNotes: staged.fileNotes.length,
            same: 0,
            changed: residentFacts.length,
            localNewer: 0,
            blocked: 0,
            dup: 0,
            noResidentCall: staged.fileNotes.isEmpty && residentFacts.isEmpty,
          ),
        );
  }

  @override
  Future<ImportScan> scan({required List<String> preparedBatchIds}) async {
    scannedBatchIds = List<String>.of(preparedBatchIds);
    onScan?.call(preparedBatchIds);
    return const ImportScan(removed: [], keptPrepared: [], ignored: []);
  }

  @override
  Future<int> notetypeUseCountSum() async => notetypeUseCount;

  @override
  Future<ResidentImportResult> commitResident({
    required String stagedPath,
    required bool firstImport,
  }) async {
    committedPath = stagedPath;
    committedFirstImport = firstImport;
    commitCalls += 1;
    onCommit?.call();
    return ResidentImportResult(newNoteIds: newNoteIds);
  }

  @override
  Future<int?> deckIdByName(String name) async => deckIds[name];
}

/// [StagedImport] returned by [FakeImportEngine.stageE].
class FakeStagedImport implements StagedImport {
  FakeStagedImport({
    required this.sourcePath,
    required this.maxBytes,
    required this.fileNotes,
    required this.deckNames,
  });

  final String sourcePath;
  final int maxBytes;

  @override
  final List<StagedFileNote> fileNotes;

  @override
  final List<String> deckNames;

  var disposed = false;
  var disposeCount = 0;

  @override
  void dispose() {
    disposeCount += 1;
    disposed = true;
  }
}
