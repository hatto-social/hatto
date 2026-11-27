// SPDX-FileCopyrightText: 2026 Hatto Social contributors
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:hatto_store/hatto_store.dart';

const String kStartupBlocked =
    '이전 가져오기를 마무리하지 못해서 지금은 가져올 수 없어요. 앱을 다시 실행해 보세요.';

const String kOneFileOnly = '한 번에 파일 하나만 가져올 수 있어요.';

const String kFormatFailure = '파일을 가져오지 못했어요. Anki 덱 파일(.apkg)인지 확인해 주세요.';

const String kCancelToast = '가져오기를 취소했어요. 컬렉션은 바뀌지 않았어요.';

const String kCancelBlocked = '이 단계는 취소할 수 없어요.';

const String kStageChecking = '파일 확인 중';

const String kStageComparing = '바뀐 내용 비교 중';

const String kStageApplying = '컬렉션에 반영 중';

const String kLearningRecord = '기존 카드의 학습 기록은 그대로예요.';

const String kNoNotes = '가져온 노트가 없어요.';

const String kNoUpdates = '업데이트한 노트가 없어요.';

const String kAlreadyImported = '이미 가져온 덱이에요. 바뀐 내용이 없어서 그대로 뒀어요.';

/// Opening Korean single quote (U+2018).
const String kQuoteOpen = '‘';

/// Closing Korean single quote (U+2019).
const String kQuoteClose = '’';

String quoteName(String name) => '$kQuoteOpen$name$kQuoteClose';

/// Shown when the file exceeds [kImportLimitsV0.maxBytes] (512 MiB).
String tooLargeCompressedMessage(String fileName) =>
    '${quoteName(fileName)} 파일은 너무 커서 가져올 수 없어요. 512 MiB 이하 파일만 가져올 수 있어요.';

/// Shown when the zip entry sum exceeds [kImportLimitsV0.maxUncompressedBytes]
/// (2 GiB).
String tooLargeUncompressedMessage(String fileName) =>
    '${quoteName(fileName)} 파일은 너무 커서 가져올 수 없어요. 2 GiB 이하 파일만 가져올 수 있어요.';

String preCommitFailureMessage(String fileName) =>
    '${quoteName(fileName)}을 가져오지 못했어요. 컬렉션은 바뀌지 않았어요.';

String adoptionFailureMessage(String fileName) =>
    '${quoteName(fileName)}은 컬렉션에 들어갔지만 정리를 끝내지 못했어요. 앱을 다시 실행하면 마무리돼요.';

String unknownFailureMessage(String fileName) =>
    '${quoteName(fileName)}을 가져오지 못했어요.';

String importedFileMessage(String fileName) => '${quoteName(fileName)}을 가져왔어요.';

String importedDeckMessage(String deckName) =>
    '${quoteName(deckName)} 덱을 가져왔어요.';

String updatedDeckMessage(String deckName) =>
    '${quoteName(deckName)} 덱을 업데이트했어요.';

String newNotesLine(int n) => '새 노트 $n개를 추가했어요.';

String changedNotesLine(int n) => '바뀐 노트 $n개를 업데이트했어요.';

String localNewerLine(int n) => '내가 고쳐서 유지 $n개';

String sameNotesLine(int n) => '바뀐 내용이 없는 노트 $n개는 그대로 뒀어요.';

String blockedNotesLine(int n) => '노트타입이 달라 $n개는 업데이트하지 못했어요.';

String noCardsLine(int n) => '카드가 없는 노트 $n개는 가져오지 않았어요.';

String dupNotesLine(int n) => '파일 안에서 ID가 겹친 노트 $n개는 따로따로 가져왔어요.';

/// Leaf name used in quotes. Separators are `/` and `\`.
String importLeafName(String name) {
  final normalized = name.replaceAll('\\', '/');
  final slash = normalized.lastIndexOf('/');
  final leaf = slash < 0 ? normalized : normalized.substring(slash + 1);
  return leaf.isEmpty ? name : leaf;
}

/// `.apkg`, `.APKG`, and `.Apkg` are the same extension.
bool isApkgFileName(String name) {
  final leaf = importLeafName(name);
  final dot = leaf.lastIndexOf('.');
  if (dot < 0) {
    return false;
  }
  return leaf.substring(dot).toLowerCase() == '.apkg';
}

/// Deck names other than the stock `Default` deck.
List<String> nonDefaultDeckNames(List<String> deckNames) {
  return [
    for (final name in deckNames)
      if (name != 'Default') name,
  ];
}

/// Title, detail lines, and the optional learning-record footer.
class ImportSummaryText {
  const ImportSummaryText({
    required this.title,
    required this.details,
    this.footer,
  });

  final String title;
  final List<String> details;
  final String? footer;

  /// A no-op with nothing to list under the title.
  bool get isSingleLine => details.isEmpty && footer == null;

  List<String> get lines => [...details, ?footer];
}

/// Screen-reader text for a multi-line summary. The title comes first.
String spokenImportSummary(ImportSummaryText summary) {
  if (summary.lines.isEmpty) return summary.title;
  return '${summary.title} ${summary.lines.join(' ')}';
}

ImportSummaryText formatImportSummary({
  required PreparedPlan plan,
  required String fileName,
}) {
  final counts = plan.counts;
  final details = <String>[
    if (counts.newNotes > 0) newNotesLine(counts.newNotes),
    if (counts.changed > 0) changedNotesLine(counts.changed),
    if (counts.localNewer > 0) localNewerLine(counts.localNewer),
    if (counts.same > 0) sameNotesLine(counts.same),
    if (counts.blocked > 0) blockedNotesLine(counts.blocked),
    if (plan.cardlessNotes > 0) noCardsLine(plan.cardlessNotes),
    if (counts.dup > 0) dupNotesLine(counts.dup),
  ];
  final footer = counts.changed > 0 || counts.localNewer > 0 || counts.same > 0
      ? kLearningRecord
      : null;
  return ImportSummaryText(
    title: _summaryTitle(plan: plan, fileName: fileName),
    details: details,
    footer: footer,
  );
}

String _summaryTitle({required PreparedPlan plan, required String fileName}) {
  final counts = plan.counts;
  if (counts.newNotes + counts.changed == 0) {
    if (plan.firstImport) {
      return kNoNotes;
    }
    if (counts.blocked > 0) {
      return kNoUpdates;
    }
    return kAlreadyImported;
  }
  final decks = nonDefaultDeckNames(plan.deckNames);
  if (decks.length == 1) {
    return plan.firstImport
        ? importedDeckMessage(decks.single)
        : updatedDeckMessage(decks.single);
  }
  return importedFileMessage(fileName);
}

/// Failure copy. Success and cancellation are presented by the caller.
String? messageForImportFailure({
  required ImportOutcome outcome,
  required Object? error,
  required String fileName,
}) {
  switch (outcome) {
    case ImportOutcome.failedAfterCommit:
      return adoptionFailureMessage(fileName);
    case ImportOutcome.failedUnknown:
      return unknownFailureMessage(fileName);
    case ImportOutcome.failedBeforeCommit:
      return switch (importErrorKind(error)) {
        ImportErrorKind.format => kFormatFailure,
        ImportErrorKind.tooLargeCompressed => tooLargeCompressedMessage(
          fileName,
        ),
        ImportErrorKind.tooLargeUncompressed => tooLargeUncompressedMessage(
          fileName,
        ),
        null => preCommitFailureMessage(fileName),
      };
    case ImportOutcome.cancelled:
    case ImportOutcome.committed:
    case ImportOutcome.noop:
      return null;
  }
}

/// One frame of the progress dialog.
class ImportProgressView {
  const ImportProgressView({
    required this.label,
    required this.cancelEnabled,
    this.blockedNote,
  });

  final String label;
  final bool cancelEnabled;
  final String? blockedNote;
}

/// Stage labels from [onPhase] (G-I5-3).
///
/// Checking is only the moment before [ImportPhase.afterStage]. Comparing
/// starts at [ImportPhase.afterStage] and stays through
/// [ImportPhase.afterNoteMap], [ImportPhase.afterResidentLookup],
/// [ImportPhase.afterFinish], and [ImportPhase.afterPre]. Cancel stays
/// enabled through [ImportPhase.afterPre] and turns off synchronously at
/// [ImportPhase.afterIntent].
ImportProgressView progressForPhase(ImportPhase? phase) {
  switch (phase) {
    case null:
    case ImportPhase.afterReconcile:
      return const ImportProgressView(
        label: kStageChecking,
        cancelEnabled: true,
      );
    case ImportPhase.afterStage:
    case ImportPhase.afterNoteMap:
    case ImportPhase.afterResidentLookup:
    case ImportPhase.afterFinish:
    case ImportPhase.afterPre:
      return const ImportProgressView(
        label: kStageComparing,
        cancelEnabled: true,
      );
    case ImportPhase.afterIntent:
    case ImportPhase.beforeResidentCommit:
    case ImportPhase.afterResidentCommit:
    case ImportPhase.afterArchive:
    case ImportPhase.duringAdoption:
      return const ImportProgressView(
        label: kStageApplying,
        cancelEnabled: false,
        blockedNote: kCancelBlocked,
      );
  }
}
