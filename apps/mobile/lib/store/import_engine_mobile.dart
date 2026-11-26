// SPDX-FileCopyrightText: 2026 Hatto Social contributors
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:typed_data';

import 'package:hatto_store/hatto_store.dart';
import 'package:rslib_bridge/rslib_bridge.dart' as bridge;

import 'pb.dart';
import 'resident_collection.dart';

/// Mobile [ImportEngine]. Staging goes through `rslib_bridge`. The resident
/// package write is the one `import_anki_package` call in this file.
class MobileImportEngine implements ImportEngine {
  MobileImportEngine({required this.backend, required this.dataDir});

  final bridge.AnkiBackend backend;
  final String dataDir;

  @override
  Future<StagedImport> stageE({
    required String sourcePath,
    required ImportLimits limits,
  }) async {
    final pending = await bridge.importStageE(
      dataDir: dataDir,
      sourcePath: sourcePath,
      maxBytes: BigInt.from(limits.maxBytes),
      maxUncompressedBytes: BigInt.from(limits.maxUncompressedBytes),
    );
    final notes = await pending.fileNotes();
    final names = await pending.deckNames();
    return _MobileStaged(
      pending: pending,
      fileNotes: [
        for (final note in notes)
          StagedFileNote(
            guid: note.guid,
            notetypeId: _asInt(note.notetypeId),
            mod: _asInt(note.mod),
            contentHashHex: _hex(note.contentHash),
          ),
      ],
      deckNames: names,
    );
  }

  @override
  Future<ResidentMatchResult> residentLookup({
    required List<int> noteIds,
    required List<String> deckNames,
  }) async {
    final match = await bridge.residentLookup(
      backend: backend,
      noteIds: bridge.Int64List.fromList(noteIds),
      deckNames: deckNames,
    );
    if (match.notes.length != noteIds.length) {
      throw StateError(
        'resident lookup returned ${match.notes.length} notes '
        'for ${noteIds.length} ids',
      );
    }
    final notes = <ResidentNoteFacts>[];
    for (var i = 0; i < match.notes.length; i++) {
      final note = match.notes[i];
      notes.add(
        ResidentNoteFacts(
          guid: note.guid,
          id: noteIds[i],
          contentHashHex: _hex(note.contentHash),
          notetypeId: _asInt(note.notetypeId),
          mod: _asInt(note.mod),
        ),
      );
    }
    return ResidentMatchResult(
      notes: notes,
      foundDeckNames: match.foundDeckNames,
    );
  }

  @override
  Future<PreparedPlan> finish({
    required StagedImport staged,
    required List<ResidentNoteFacts> residentFacts,
    required List<String> foundDeckNames,
  }) async {
    if (staged is! _MobileStaged) {
      throw StateError('staged import was not opened by this engine');
    }
    final prepared = await bridge.importStageFinish(
      pending: staged.take(),
      residentFacts: [
        for (final note in residentFacts)
          bridge.NoteFacts(
            guid: note.guid,
            notetypeId: note.notetypeId,
            mod: note.mod,
            contentHash: _bytes(note.contentHashHex),
          ),
      ],
      foundDeckNames: foundDeckNames,
    );
    return PreparedPlan(
      batchId: prepared.importBatchId,
      stagedPath: prepared.stagedPath,
      stagedSha256: prepared.stagedSha256,
      firstImport: prepared.firstImport,
      newGuids: prepared.newGuids,
      changed: {
        for (final note in prepared.changed) note.guid: _hex(note.contentHash),
      },
      deckNames: prepared.deckNames,
      counts: ImportPlanCounts(
        newNotes: prepared.plan.new_,
        same: prepared.plan.same,
        changed: prepared.plan.changed,
        localNewer: prepared.plan.localNewer,
        blocked: prepared.plan.blocked,
        dup: prepared.plan.dup,
        noResidentCall: prepared.plan.noResidentCall,
      ),
      cardlessNotes: prepared.cardlessNotes,
    );
  }

  @override
  Future<ImportScan> scan({required List<String> preparedBatchIds}) async {
    final scan = await bridge.scanImportFolders(
      dataDir: dataDir,
      preparedBatchIds: preparedBatchIds,
    );
    return ImportScan(
      removed: scan.removed,
      keptPrepared: scan.keptPrepared,
      ignored: scan.ignored,
    );
  }

  @override
  Future<int> notetypeUseCountSum() async {
    final raw = await callBackend(
      backend: backend,
      service: 'BackendNotetypesService',
      method: 'get_notetype_names_and_counts',
      input: emptyMessage(),
    );
    return readNotetypeUseCountSum(raw);
  }

  @override
  Future<ResidentImportResult> commitResident({
    required String stagedPath,
    required bool firstImport,
  }) async {
    final raw = await callBackend(
      backend: backend,
      service: 'BackendImportExportService',
      method: 'import_anki_package',
      input: encodeResidentPackageImport(
        packagePath: stagedPath,
        withDeckConfigs: firstImport,
      ),
    );
    return ResidentImportResult(newNoteIds: readImportedNewNoteIds(raw));
  }

  @override
  Future<int?> deckIdByName(String name) async {
    try {
      final raw = await callBackend(
        backend: backend,
        service: 'BackendDecksService',
        method: 'get_deck_id_by_name',
        input: encodeStringValue(name),
      );
      final id = readInt64Field1(raw);
      if (id == 0) {
        return null;
      }
      return id;
    } on BackendCallException catch (err) {
      if (err.kind == backendNotFoundKind) {
        return null;
      }
      rethrow;
    }
  }
}

class _MobileStaged implements StagedImport {
  _MobileStaged({
    required bridge.PendingImport pending,
    required this.fileNotes,
    required this.deckNames,
  }) {
    _pending = pending;
  }

  bridge.PendingImport? _pending;

  @override
  final List<StagedFileNote> fileNotes;

  @override
  final List<String> deckNames;

  bridge.PendingImport take() {
    final pending = _pending;
    if (pending == null) {
      throw StateError('E is already closed');
    }
    _pending = null;
    return pending;
  }

  @override
  void dispose() {
    final pending = _pending;
    if (pending == null) {
      return;
    }
    _pending = null;
    pending.dispose();
  }
}

int _asInt(Object value) {
  if (value is int) {
    return value;
  }
  if (value is BigInt) {
    return value.toInt();
  }
  throw StateError('expected an integer, got $value');
}

String _hex(Uint8List bytes) {
  final out = StringBuffer();
  for (final byte in bytes) {
    out.write(byte.toRadixString(16).padLeft(2, '0'));
  }
  return out.toString();
}

Uint8List _bytes(String hex) {
  if (hex.length.isOdd) {
    throw StateError('content hash hex has an odd length');
  }
  final out = Uint8List(hex.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}
