// SPDX-FileCopyrightText: 2026 Hatto Social contributors
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:io';

import 'package:cross_file/cross_file.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:hatto_store/hatto_store.dart' hide AnkiApi;
import 'package:path/path.dart' as p;

import '../store/write_gateway.dart';
import '../ui/import_copy.dart';
import 'import_progress_model.dart';

typedef ApkgImportFile = Future<ImportRunResult> Function({
  required String sourcePath,
  required ImportLimits limits,
  ImportCancellationToken? cancel,
  void Function(ImportPhase phase)? onPhase,
});

/// UI hooks. The session does not build widgets.
class ApkgImportUi {
  const ApkgImportUi({
    required this.toast,
    required this.showSummary,
    required this.showProgress,
    required this.closeProgress,
  });

  final void Function(String message) toast;
  final void Function(ImportSummaryText summary) showSummary;
  final Future<void> Function(ImportProgressModel model) showProgress;
  final void Function() closeProgress;
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

ApkgDrop apkgDropFromItem(DropItem item) {
  switch (item) {
    case DropFileItem(:final name, :final localPath, :final file):
      return ApkgDrop.file(
        name: name,
        localPath: localPath,
        openRead: () async* {
          await for (final chunk in file.openRead()) {
            yield chunk;
          }
        },
      );
    case DropDirectoryItem(:final name, :final localPath):
      return ApkgDrop.directory(name: name, localPath: localPath);
    case DropStringItem():
      return const ApkgDrop.unsupported();
  }
}

/// Native file dialog. Returns null when the user cancels or the selection
/// has no filesystem path.
Future<String?> pickApkgPath() async {
  final picked = await openFile(
    acceptedTypeGroups: const [
      XTypeGroup(label: 'Anki 덱', extensions: ['apkg', 'APKG', 'Apkg']),
    ],
  );
  if (picked is FileSystemXFile) {
    final path = picked.path;
    if (path.isEmpty) {
      return null;
    }
    return path;
  }
  return null;
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
  }) : pickFile = pickFile ?? pickApkgPath;

  final ApkgImportFile importFile;
  final String dataDir;
  final Future<void> Function() refreshDecks;
  final Future<void> Function() flushEditor;
  final Object? startupError;
  final Future<String?> Function() pickFile;
  final void Function(File file)? onTempFile;
  final Directory? tempDirectory;
  final int maxBytes;

  bool running = false;
  bool sessionLocked = false;

  bool get entryBlocked => startupError != null || sessionLocked;

  Future<void> importFromPicker(ApkgImportUi ui) async {
    if (entryBlocked) {
      ui.toast(kStartupBlocked);
      return;
    }
    if (running) {
      return;
    }
    _setRunning(true);
    try {
      final path = await pickFile();
      if (path == null) {
        return;
      }
      await _importLocal(ui, path, importLeafName(path));
    } finally {
      _setRunning(false);
    }
  }

  Future<void> importDropped(ApkgImportUi ui, List<ApkgDrop> items) async {
    if (entryBlocked) {
      ui.toast(kStartupBlocked);
      return;
    }
    if (running) {
      return;
    }
    if (items.isEmpty) {
      return;
    }
    if (items.length > 1) {
      ui.toast(kOneFileOnly);
      return;
    }
    final item = items.single;
    if (!item.supported || item.isDirectory || _isDirectory(item.localPath)) {
      ui.toast(kFormatFailure);
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
      ui.toast(kFormatFailure);
      return;
    }
    final open = item.openRead;
    if (open == null) {
      ui.toast(kFormatFailure);
      return;
    }
    _setRunning(true);
    File? temp;
    try {
      temp = await _materialize(
        openRead: open,
        onCreated: (file) {
          temp = file;
          onTempFile?.call(file);
        },
      );
      if (!fileLooksLikeZip(temp!.path)) {
        ui.toast(kFormatFailure);
        return;
      }
      await _commit(ui, sourcePath: temp!.path, fileName: fileName);
    } on _TooLarge {
      ui.toast(tooLargeCompressedMessage(fileName));
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
      ui.toast(rejected);
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
    } catch (_) {
      ui.toast(preCommitFailureMessage(fileName));
      return;
    }
    final model = ImportProgressModel(ImportCancellationToken());
    ImportRunResult? result;
    var threw = false;
    try {
      await ui.showProgress(model);
      result = await importFile(
        sourcePath: sourcePath,
        limits: kImportLimits,
        cancel: model.token,
        onPhase: model.onPhase,
      );
    } on ImportStartupException {
      ui.toast(kStartupBlocked);
      return;
    } catch (_) {
      threw = true;
    } finally {
      ui.closeProgress();
    }
    if (threw) {
      await _unknownOrPreCommit(
        ui,
        fileName: fileName,
        pastIntent: model.pastIntent,
      );
      return;
    }
    final finished = result;
    if (finished == null) {
      return;
    }
    await _present(ui, finished, fileName);
  }

  Future<void> _present(
    ApkgImportUi ui,
    ImportRunResult result,
    String fileName,
  ) async {
    if (result.outcome == ImportOutcome.committed ||
        result.outcome == ImportOutcome.failedAfterCommit ||
        result.outcome == ImportOutcome.failedUnknown) {
      await refreshDecks();
    }
    if (result.outcome == ImportOutcome.failedUnknown) {
      sessionLocked = true;
      notifyListeners();
    }
    if (result.outcome == ImportOutcome.cancelled) {
      ui.toast(kCancelToast);
      return;
    }
    if (result.outcome == ImportOutcome.committed ||
        result.outcome == ImportOutcome.noop) {
      final plan = result.plan;
      if (plan == null) {
        ui.toast(
          result.outcome == ImportOutcome.committed
              ? importedFileMessage(fileName)
              : kAlreadyImported,
        );
        return;
      }
      final summary = formatImportSummary(plan: plan, fileName: fileName);
      if (summary.isSingleLine) {
        ui.toast(summary.title);
      } else {
        ui.showSummary(summary);
      }
      return;
    }
    final message = messageForImportFailure(
      outcome: result.outcome,
      error: result.error,
      fileName: fileName,
    );
    if (message != null) {
      ui.toast(message);
    }
  }

  Future<void> _unknownOrPreCommit(
    ApkgImportUi ui, {
    required String fileName,
    required bool pastIntent,
  }) async {
    if (!pastIntent) {
      ui.toast(preCommitFailureMessage(fileName));
      return;
    }
    sessionLocked = true;
    notifyListeners();
    await refreshDecks();
    ui.toast(unknownFailureMessage(fileName));
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

  void _setRunning(bool value) {
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
