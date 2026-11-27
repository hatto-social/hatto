// SPDX-FileCopyrightText: 2026 Hatto Social contributors
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';
import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:hatto_store/hatto_store.dart' hide AnkiApi;
import 'package:path/path.dart' as p;

import '../state/import_copy.dart';
import '../store/write_gateway.dart';
import 'import_progress_model.dart';

typedef ApkgImportFile = Future<ImportRunResult> Function({
  required String sourcePath,
  required ImportLimits limits,
  ImportCancellationToken? cancel,
  void Function(ImportPhase phase)? onPhase,
});

/// How long a stage label must stay current before it is spoken.
const Duration kImportStageAnnounceDelay = Duration(milliseconds: 250);

/// Schedules one stage announcement. Tests record [callback] instead of waiting.
typedef ImportStageSchedule = void Function(
  Duration delay,
  void Function() callback,
);

/// UI hooks. The session does not build widgets.
class ApkgImportUi {
  const ApkgImportUi({
    required this.toast,
    required this.showSummary,
    required this.showProgress,
    required this.closeProgress,
    required this.showDeckList,
    required this.announce,
  });

  final void Function(String message) toast;
  final void Function(ImportSummaryText summary) showSummary;
  final Future<void> Function(ImportProgressModel model) showProgress;
  final void Function() closeProgress;

  /// Deck list after the collection may have changed. Unchanged imports stay.
  final Future<void> Function() showDeckList;

  /// Speaks [message]. The session does not wait for it.
  final Future<void> Function(String message) announce;
}

/// The collection may have changed, so the deck list replaces a stale screen.
///
/// [ImportOutcome.cancelled], [ImportOutcome.failedBeforeCommit], and
/// [ImportOutcome.noop] stay where they are. So does a drop rejected before
/// the import starts.
bool _opensDeckList(ImportOutcome outcome) {
  return outcome == ImportOutcome.committed ||
      outcome == ImportOutcome.failedAfterCommit ||
      outcome == ImportOutcome.failedUnknown;
}

/// One dropped item, after the desktop drop plugin has been unwrapped.
class ApkgDrop {
  const ApkgDrop.file({required this.name, this.localPath, this.openRead})
    : isDirectory = false,
      supported = true;

  const ApkgDrop.directory({required this.name, this.localPath})
    : isDirectory = true,
      supported = true,
      openRead = null;

  const ApkgDrop.unsupported({this.name = ''})
    : isDirectory = false,
      supported = false,
      localPath = null,
      openRead = null;

  final String name;
  final String? localPath;
  final bool isDirectory;
  final bool supported;
  final Stream<List<int>> Function()? openRead;
}

/// `desktop_drop` 0.8.4 hands back a [DropItem], which is an [XFile].
///
/// Linux reports a directory as [DropItemFile] whose path is the folder.
/// macOS uses [DropItemDirectory]. On dart:io, [XFile.name] is the path's
/// last segment, and a missing path is streamed from [XFile.openRead].
ApkgDrop apkgDropFromItem(XFile item) {
  final path = item.path;
  final localPath = path.isEmpty ? null : path;
  if (item is DropItemDirectory) {
    return ApkgDrop.directory(name: item.name, localPath: localPath);
  }
  return ApkgDrop.file(
    name: item.name,
    localPath: localPath,
    openRead: () => item.openRead(),
  );
}

/// Every ASCII case of `apkg`.
///
/// Some file dialogs match [XTypeGroup.extensions] case-sensitively. A drop
/// uses [isApkgFileName], which accepts any ASCII case of `.apkg`.
const List<String> kApkgPickerExtensions = [
  'apkg',
  'apkG',
  'apKg',
  'apKG',
  'aPkg',
  'aPkG',
  'aPKg',
  'aPKG',
  'Apkg',
  'ApkG',
  'ApKg',
  'ApKG',
  'APkg',
  'APkG',
  'APKg',
  'APKG',
];

/// Native file dialog. Returns null when the user cancels or the selection
/// has no filesystem path.
Future<String?> pickApkgPath() async {
  final picked = await openFile(
    acceptedTypeGroups: const [
      XTypeGroup(label: 'Anki 덱', extensions: kApkgPickerExtensions),
    ],
  );
  if (picked == null || picked.path.isEmpty) {
    return null;
  }
  return picked.path;
}

/// Frames kept from a diagnostic stack. Later frames become `...`.
const int _kDiagnosticStackFrames = 8;

/// One stderr line for an import failure. Newlines in the values are folded.
///
/// A stack trace keeps the first [_kDiagnosticStackFrames] non-empty lines.
/// This is a diagnostic. Callers must not put it in a toast or a dialog.
String importDiagnosticLine({
  required String where,
  Object? error,
  StackTrace? stack,
  Object? commitError,
  StackTrace? commitStack,
}) {
  final parts = <String>[];
  final errorText = _diagnosticText(error);
  if (errorText.isNotEmpty) {
    parts.add(errorText);
  }
  final stackText = _diagnosticText(stack);
  if (stackText.isNotEmpty) {
    parts.add(stackText);
  }
  final commitText = _diagnosticText(commitError);
  if (commitText.isNotEmpty) {
    parts.add('commit: $commitText');
  }
  final commitStackText = _diagnosticText(commitStack);
  if (commitStackText.isNotEmpty) {
    parts.add(commitStackText);
  }
  if (parts.isEmpty) {
    return 'import $where';
  }
  return 'import $where: ${parts.join(' | ')}';
}

String _diagnosticText(Object? value) {
  if (value == null) {
    return '';
  }
  if (value is StackTrace) {
    return _capStack(value);
  }
  return value.toString().replaceAll(RegExp(r'\s+'), ' ').trim();
}

/// One line, at most [_kDiagnosticStackFrames] non-empty frames.
String _capStack(StackTrace stack) {
  final lines = <String>[];
  var truncated = false;
  for (final raw in stack.toString().split('\n')) {
    final line = raw.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (line.isEmpty) {
      continue;
    }
    if (lines.length == _kDiagnosticStackFrames) {
      truncated = true;
      break;
    }
    lines.add(line);
  }
  if (lines.isEmpty) {
    return '';
  }
  final text = lines.join(' ');
  if (!truncated) {
    return text;
  }
  return '$text ...';
}

void _defaultImportLog(String line) {
  stderr.writeln(line);
}

/// One desktop import session. [startupError] is the gateway's startup
/// failure. [sessionLocked] stays set after [ImportOutcome.failedUnknown]
/// until the process is replaced.
class ApkgImportSession extends ChangeNotifier {
  ApkgImportSession({
    required this.importFile,
    required this.dataDir,
    required this.refreshDecks,
    required this.flushEditor,
    this.startupError,
    Future<String?> Function()? pickFile,
    this.onTempFile,
    this.tempDirectory,
    this.maxBytes = kImportMaxBytes,
    void Function(String line)? log,
    this.stageAnnounceDelay = kImportStageAnnounceDelay,
    this.scheduleStageAnnounce,
  }) : pickFile = pickFile ?? pickApkgPath,
       log = log ?? _defaultImportLog;

  final ApkgImportFile importFile;
  final String dataDir;
  final Future<void> Function() refreshDecks;
  final Future<void> Function() flushEditor;
  final Object? startupError;
  final Future<String?> Function() pickFile;
  final void Function(File file)? onTempFile;
  final Directory? tempDirectory;
  final int maxBytes;
  final void Function(String line) log;
  final Duration stageAnnounceDelay;
  final ImportStageSchedule? scheduleStageAnnounce;

  bool running = false;
  bool sessionLocked = false;
  bool _disposed = false;
  int _stageGeneration = 0;
  Timer? _stageTimer;
  String? _pendingStage;
  String? _spokenStage;

  @override
  void dispose() {
    _disposed = true;
    _cancelStageAnnounce();
    super.dispose();
  }

  bool get entryBlocked => startupError != null || sessionLocked;

  Future<void> importFromPicker(ApkgImportUi ui) async {
    if (entryBlocked) {
      _tell(ui, kStartupBlocked);
      return;
    }
    if (running) {
      return;
    }
    _setRunning(true);
    try {
      final path = await pickFile();
      if (_disposed || path == null) {
        return;
      }
      await _importLocal(ui, path, importLeafName(path));
    } finally {
      _setRunning(false);
    }
  }

  Future<void> importDropped(ApkgImportUi ui, List<ApkgDrop> items) async {
    if (entryBlocked) {
      _tell(ui, kStartupBlocked);
      return;
    }
    if (running) {
      return;
    }
    if (items.isEmpty) {
      return;
    }
    if (items.length > 1) {
      _tell(ui, kOneFileOnly);
      return;
    }
    final item = items.single;
    if (!item.supported || item.isDirectory || _isDirectory(item.localPath)) {
      _tell(ui, kFormatFailure);
      return;
    }
    final local = _usableFile(item.localPath);
    if (local != null) {
      _setRunning(true);
      try {
        await _importLocal(ui, local, _leaf(item.name, local));
      } finally {
        _setRunning(false);
      }
      return;
    }
    final fileName = importLeafName(item.name);
    if (!isApkgFileName(fileName)) {
      _tell(ui, kFormatFailure);
      return;
    }
    final open = item.openRead;
    if (open == null) {
      _tell(ui, kFormatFailure);
      return;
    }
    _setRunning(true);
    File? temp;
    try {
      try {
        temp = await _materialize(
          openRead: open,
          onCreated: (file) {
            temp = file;
            onTempFile?.call(file);
          },
        );
        if (!fileLooksLikeZip(temp!.path)) {
          _tell(ui, kFormatFailure);
          return;
        }
      } on _TooLarge {
        _tell(ui, tooLargeCompressedMessage(fileName));
        return;
      } on Object catch (err, stack) {
        // PlatformException and StateError are not IOExceptions. They still
        // toast, log, delete the temp file, and clear `running`.
        _logDiagnostic('materialize', err, stack);
        _tell(ui, preCommitFailureMessage(fileName));
        return;
      }
      if (_disposed) {
        return;
      }
      await _commit(ui, sourcePath: temp!.path, fileName: fileName);
    } finally {
      _deleteQuiet(temp);
      _setRunning(false);
    }
  }

  Future<void> _importLocal(
    ApkgImportUi ui,
    String path,
    String fileName,
  ) async {
    final rejected = _rejectLocal(path, fileName);
    if (rejected != null) {
      _tell(ui, rejected);
      return;
    }
    await _commit(ui, sourcePath: path, fileName: fileName);
  }

  String? _rejectLocal(String path, String fileName) {
    if (!isApkgFileName(fileName)) {
      return kFormatFailure;
    }
    if (_isDirectory(path)) {
      return kFormatFailure;
    }
    if (_usableFile(path) == null) {
      return kFormatFailure;
    }
    if (File(path).lengthSync() > maxBytes) {
      return tooLargeCompressedMessage(fileName);
    }
    if (!fileLooksLikeZip(path)) {
      return kFormatFailure;
    }
    return null;
  }

  Future<void> _commit(
    ApkgImportUi ui, {
    required String sourcePath,
    required String fileName,
  }) async {
    try {
      await flushEditor();
    } catch (err, stack) {
      _logDiagnostic('flushEditor', err, stack);
      _tell(ui, preCommitFailureMessage(fileName));
      return;
    }
    if (_disposed) {
      return;
    }
    final model = ImportProgressModel(ImportCancellationToken());
    ImportRunResult? result;
    Object? thrown;
    StackTrace? thrownStack;
    try {
      await ui.showProgress(model);
      _noteStage(ui, model.view.label);
      result = await importFile(
        sourcePath: sourcePath,
        limits: kImportLimitsV0,
        cancel: model.token,
        onPhase: (phase) {
          model.onPhase(phase);
          _noteStage(ui, model.view.label);
        },
      );
    } on ImportStartupException catch (err, stack) {
      _logDiagnostic('startup', err, stack);
      _tell(ui, kStartupBlocked);
      return;
    } catch (err, stack) {
      thrown = err;
      thrownStack = stack;
    } finally {
      // Drop a stage that did not stay on screen. It must not follow the result.
      _cancelStageAnnounce();
      if (!_disposed) {
        ui.closeProgress();
      }
    }
    if (_disposed) {
      return;
    }
    if (thrown != null) {
      await _unknownOrPreCommit(
        ui,
        fileName: fileName,
        pastIntent: model.pastIntent,
        error: thrown,
        stack: thrownStack,
      );
      return;
    }
    final finished = result;
    if (_disposed || finished == null) {
      return;
    }
    await _present(ui, finished, fileName);
  }

  Future<void> _present(
    ApkgImportUi ui,
    ImportRunResult result,
    String fileName,
  ) async {
    if (_disposed) {
      return;
    }
    final openDeckList = _opensDeckList(result.outcome);
    if (openDeckList) {
      try {
        await refreshDecks();
      } catch (err, stack) {
        _logDiagnostic('refreshDecks', err, stack);
      }
    }
    if (_disposed) {
      return;
    }
    _logResult(result);
    if (result.outcome == ImportOutcome.failedUnknown) {
      sessionLocked = true;
      _notify();
    }
    if (_disposed) {
      return;
    }
    if (openDeckList) {
      try {
        await ui.showDeckList();
      } catch (err, stack) {
        _logDiagnostic('deckList', err, stack);
      }
    }
    if (_disposed) {
      return;
    }
    if (result.outcome == ImportOutcome.cancelled) {
      _tell(ui, kCancelToast);
      return;
    }
    if (result.outcome == ImportOutcome.committed ||
        result.outcome == ImportOutcome.noop) {
      final plan = result.plan;
      if (plan == null) {
        _tell(
          ui,
          result.outcome == ImportOutcome.committed
              ? importedFileMessage(fileName)
              : kAlreadyImported,
        );
        return;
      }
      final summary = formatImportSummary(plan: plan, fileName: fileName);
      if (summary.isSingleLine) {
        _tell(ui, summary.title);
      } else {
        ui.showSummary(summary);
        _speak(ui, spokenImportSummary(summary));
      }
      return;
    }
    final message = messageForImportFailure(
      outcome: result.outcome,
      error: result.error,
      fileName: fileName,
    );
    if (message != null) {
      _tell(ui, message);
    }
  }

  Future<void> _unknownOrPreCommit(
    ApkgImportUi ui, {
    required String fileName,
    required bool pastIntent,
    required Object error,
    required StackTrace? stack,
  }) async {
    _logDiagnostic(
      pastIntent ? 'failedUnknown' : 'failedBeforeCommit',
      error,
      stack,
    );
    if (_disposed) {
      return;
    }
    if (!pastIntent) {
      _tell(ui, preCommitFailureMessage(fileName));
      return;
    }
    sessionLocked = true;
    _notify();
    if (_disposed) {
      return;
    }
    try {
      await refreshDecks();
    } catch (err, refreshStack) {
      _logDiagnostic('refreshDecks', err, refreshStack);
    }
    if (_disposed) {
      return;
    }
    try {
      await ui.showDeckList();
    } catch (err, deckStack) {
      _logDiagnostic('deckList', err, deckStack);
    }
    _tell(ui, unknownFailureMessage(fileName));
  }

  void _logResult(ImportRunResult result) {
    final failed =
        result.outcome == ImportOutcome.failedBeforeCommit ||
        result.outcome == ImportOutcome.failedAfterCommit ||
        result.outcome == ImportOutcome.failedUnknown;
    if (!failed && result.commitError == null) {
      return;
    }
    log(
      importDiagnosticLine(
        where: result.outcome.name,
        error: failed ? result.error : null,
        stack: failed ? result.stack : null,
        commitError: result.commitError,
        commitStack: result.commitStack,
      ),
    );
  }

  void _logDiagnostic(String where, Object? error, StackTrace? stack) {
    log(importDiagnosticLine(where: where, error: error, stack: stack));
  }

  /// Shows [message], then speaks it. Announcement failures are logged
  /// and do not delay the toast or the caller.
  void _tell(ApkgImportUi ui, String message) {
    if (_disposed) {
      return;
    }
    ui.toast(message);
    _speak(ui, message);
  }

  /// Speaks [label] only after it has stayed current for [stageAnnounceDelay].
  ///
  /// A later label replaces the pending one. The same label does not schedule
  /// a second announcement.
  void _noteStage(ApkgImportUi ui, String label) {
    if (_disposed || label.isEmpty) return;
    if (label == _spokenStage || label == _pendingStage) return;
    _stageTimer?.cancel();
    _stageTimer = null;
    _stageGeneration++;
    final generation = _stageGeneration;
    _pendingStage = label;
    void fire() {
      if (_disposed || generation != _stageGeneration) return;
      _stageTimer = null;
      if (_pendingStage != label) return;
      _pendingStage = null;
      _spokenStage = label;
      _speak(ui, label);
    }

    if (stageAnnounceDelay <= Duration.zero) {
      fire();
      return;
    }
    final schedule = scheduleStageAnnounce;
    if (schedule != null) {
      schedule(stageAnnounceDelay, fire);
      return;
    }
    _stageTimer = Timer(stageAnnounceDelay, fire);
  }

  void _cancelStageAnnounce() {
    _stageGeneration++;
    _stageTimer?.cancel();
    _stageTimer = null;
    _pendingStage = null;
    _spokenStage = null;
  }

  void _speak(ApkgImportUi ui, String message) {
    if (_disposed || message.isEmpty) return;
    Future<void> pending;
    try {
      pending = ui.announce(message);
    } catch (err, stack) {
      _logDiagnostic('announce', err, stack);
      return;
    }
    unawaited(
      pending.catchError((Object err, StackTrace stack) {
        _logDiagnostic('announce', err, stack);
        return Future<void>.value();
      }),
    );
  }

  Future<File> _materialize({
    required Stream<List<int>> Function() openRead,
    required void Function(File file) onCreated,
  }) async {
    final dir = _tempRoot();
    if (!dir.existsSync()) {
      dir.createSync(recursive: true);
    }
    final file = File(p.join(dir.path, 'hatto-drop-${_nextTempId()}.apkg'));
    _assertOutsideImport(file.path);
    onCreated(file);
    final sink = file.openWrite();
    try {
      var total = 0;
      await for (final chunk in openRead()) {
        final next = total + chunk.length;
        if (next > maxBytes) {
          throw const _TooLarge();
        }
        total = next;
        sink.add(chunk);
      }
    } finally {
      await sink.close();
    }
    return file;
  }

  Directory _tempRoot() {
    final preferred = tempDirectory ?? Directory.systemTemp;
    final forbidden = p.normalize(p.join(dataDir, 'import'));
    final candidate = p.normalize(preferred.path);
    if (candidate == forbidden || p.isWithin(forbidden, candidate)) {
      return Directory(p.join(Directory.systemTemp.path, 'hatto-apkg-drop'));
    }
    return preferred;
  }

  void _assertOutsideImport(String path) {
    final forbidden = p.normalize(p.join(dataDir, 'import'));
    final normalized = p.normalize(path);
    if (normalized == forbidden || p.isWithin(forbidden, normalized)) {
      throw StateError('import temp file must not live under import/');
    }
  }

  void _notify() {
    if (_disposed) {
      return;
    }
    notifyListeners();
  }

  void _setRunning(bool value) {
    if (_disposed) {
      running = value;
      return;
    }
    if (running == value) {
      return;
    }
    running = value;
    notifyListeners();
  }

  static int _tempSeq = 0;

  static int _nextTempId() => _tempSeq++;

  static String _leaf(String name, String path) {
    final fromName = importLeafName(name);
    if (fromName.isNotEmpty) {
      return fromName;
    }
    return importLeafName(path);
  }

  static String? _usableFile(String? path) {
    if (path == null || path.isEmpty) {
      return null;
    }
    if (FileSystemEntity.typeSync(path) != FileSystemEntityType.file) {
      return null;
    }
    return path;
  }

  static bool _isDirectory(String? path) {
    if (path == null || path.isEmpty) {
      return false;
    }
    return FileSystemEntity.typeSync(path) == FileSystemEntityType.directory;
  }

  static void _deleteQuiet(File? file) {
    if (file == null) {
      return;
    }
    try {
      if (file.existsSync()) {
        file.deleteSync();
      }
    } catch (_) {
      // The import already finished. A leftover temp file is outside import/.
    }
  }
}

bool fileLooksLikeZip(String path) {
  final raf = File(path).openSync();
  try {
    return looksLikeZipHeader(raf.readSync(4));
  } finally {
    raf.closeSync();
  }
}

bool looksLikeZipHeader(List<int> header) {
  if (header.length < 4) {
    return false;
  }
  if (header[0] != 0x50 || header[1] != 0x4b) {
    return false;
  }
  final third = header[2];
  final fourth = header[3];
  return (third == 0x03 && fourth == 0x04) ||
      (third == 0x05 && fourth == 0x06) ||
      (third == 0x07 && fourth == 0x08);
}

class _TooLarge implements Exception {
  const _TooLarge();
}
