// SPDX-FileCopyrightText: 2026 Hatto Social contributors
//
// SPDX-License-Identifier: AGPL-3.0-or-later

/// Resident-collection and E-pipeline operations import recovery calls.
///
/// The host implements this with its bridge. This library has no FRB types.
/// Content hashes are lowercase hex strings. Callers do not compare hash
/// bytes.
abstract interface class ImportEngine {
  /// §7.1 steps 1–3. [maxBytes] is the caller's package ceiling.
  Future<StagedImport> stageE({
    required String sourcePath,
    required int maxBytes,
  });

  /// Resident notes for [noteIds], and which of [deckNames] already exist.
  ///
  /// [ResidentMatchResult.notes] follows [noteIds]. Hashes are lowercase hex.
  Future<ResidentMatchResult> residentLookup({
    required List<int> noteIds,
    required List<String> deckNames,
  });

  /// §7.1 steps 4–7. Does not write the resident collection.
  ///
  /// The implementation may consume [staged]. Callers do not use [staged]
  /// after this returns.
  Future<PreparedPlan> finish({
    required StagedImport staged,
    required List<ResidentNoteFacts> residentFacts,
    required List<String> foundDeckNames,
  });

  /// Delete import batches whose id is not in [preparedBatchIds].
  Future<ImportScan> scan({required List<String> preparedBatchIds});

  /// Sum of per-notetype note counts in the resident collection.
  Future<int> notetypeUseCountSum();

  /// Resident package import. [newNoteIds] are `ImportResponse.log.new_1[].id`.
  Future<ResidentImportResult> commitResident({
    required String stagedPath,
    required bool firstImport,
  });

  /// rslib deck id for [name], or null when the deck is absent.
  Future<int?> deckIdByName(String name);
}

/// Open E import. The host keeps the native handle behind this view.
abstract interface class StagedImport {
  /// File notes after guid normalization.
  List<StagedFileNote> get fileNotes;

  /// Normal deck names in E, excluding Default.
  List<String> get deckNames;

  /// Closes E. A second call is safe.
  void dispose();
}

/// One file note on a [StagedImport].
///
/// The hash is lowercase hex, not raw digest bytes. [notetypeId] and [mod]
/// are the E collection's columns. `mod` is Anki's modification time.
class StagedFileNote {
  const StagedFileNote({
    required this.guid,
    required this.notetypeId,
    required this.mod,
    required this.contentHashHex,
  });

  final String guid;
  final int notetypeId;
  final int mod;
  final String contentHashHex;
}

/// One resident note [ImportEngine.residentLookup] returned.
class ResidentNoteFacts {
  const ResidentNoteFacts({
    required this.guid,
    required this.id,
    required this.contentHashHex,
  });

  final String guid;

  /// rslib `notes.id`.
  final int id;

  /// Lowercase hex. Compared as a string, not as bytes.
  final String contentHashHex;
}

/// Notes and deck names from [ImportEngine.residentLookup].
class ResidentMatchResult {
  const ResidentMatchResult({
    required this.notes,
    required this.foundDeckNames,
  });

  final List<ResidentNoteFacts> notes;
  final List<String> foundDeckNames;
}

/// Plan counts from classification. [newNotes] is the NEW class count.
class ImportPlanCounts {
  const ImportPlanCounts({
    required this.newNotes,
    required this.same,
    required this.changed,
    required this.localNewer,
    required this.blocked,
    required this.dup,
    required this.noResidentCall,
  });

  final int newNotes;
  final int same;
  final int changed;
  final int localNewer;
  final int blocked;
  final int dup;

  /// True when [newNotes] and [changed] are both zero.
  final bool noResidentCall;
}

/// Result of [ImportEngine.finish]. The resident collection is not written.
class PreparedPlan {
  const PreparedPlan({
    required this.batchId,
    required this.stagedPath,
    required this.stagedSha256,
    required this.firstImport,
    required this.newGuids,
    required this.changed,
    required this.deckNames,
    required this.counts,
    this.cardlessNotes = 0,
  });

  /// Lowercase UUID version 4. This becomes the intent `target_key`.
  final String batchId;
  final String stagedPath;

  /// Lowercase hex digest of the staged package.
  final String stagedSha256;
  final bool firstImport;
  final List<String> newGuids;

  /// Guid to lowercase hex, in ascending guid order when the engine follows
  /// the prepared-import map.
  final Map<String, String> changed;
  final List<String> deckNames;
  final ImportPlanCounts counts;
  final int cardlessNotes;
}

/// New note ids from a resident package import.
class ResidentImportResult {
  const ResidentImportResult({required this.newNoteIds});

  /// `ImportResponse.log.new_1[].id`, in response order.
  final List<int> newNoteIds;
}

/// One scan of `import/{raw,e,staged}`.
class ImportScan {
  const ImportScan({
    required this.removed,
    required this.keptPrepared,
    required this.ignored,
  });

  final List<String> removed;
  final List<String> keptPrepared;
  final List<String> ignored;
}
