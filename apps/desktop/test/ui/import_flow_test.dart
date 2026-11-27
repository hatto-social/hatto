// SPDX-FileCopyrightText: 2026 Hatto Social contributors
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hatto_desktop/effect/apkg_import.dart';
import 'package:hatto_desktop/effect/import_progress_model.dart';
import 'package:hatto_desktop/ui/import_copy.dart';
import 'package:hatto_store/hatto_store.dart';
import 'package:path/path.dart' as p;

class _LenList extends ListBase<int> {
  _LenList(this._length);

  final int _length;

  @override
  int get length => _length;

  @override
  set length(int value) => throw UnsupportedError('length');

  @override
  int operator [](int index) => 0;

  @override
  void operator []=(int index, int value) {}
}

class _Rec {
  final toasts = <String>[];
  final summaries = <ImportSummaryText>[];
  final announcements = <String>[];
  var refreshes = 0;
  var flushes = 0;
  var deckLists = 0;
  ImportProgressModel? progress;
  var pickerCalls = 0;

  ApkgImportUi get ui => ApkgImportUi(
    toast: toasts.add,
    showSummary: summaries.add,
    showProgress: (model) async {
      progress = model;
    },
    closeProgress: () {},
    onCommitted: () async {
      deckLists++;
    },
    announce: (message) async {
      announcements.add(message);
    },
  );
}

class _Call {
  _Call(this.path, this.limits, this.onPhase, this.cancel);

  final String path;
  final ImportLimits limits;
  final void Function(ImportPhase phase)? onPhase;
  final ImportCancellationToken? cancel;
}

void main() {
  late Directory root;

  setUp(() {
    root = Directory.systemTemp.createTempSync('hatto-i5-flow');
  });

  tearDown(() {
    if (root.existsSync()) {
      root.deleteSync(recursive: true);
    }
  });

  ApkgImportSession open({
    required _Rec rec,
    required Future<ImportRunResult> Function(_Call call) onImport,
    Object? startupError,
    Future<String?> Function()? pickFile,
    int? maxBytes,
    void Function(File file)? onTempFile,
    Directory? tempDirectory,
    Future<void> Function()? flush,
    Future<void> Function()? refresh,
    List<String>? log,
  }) {
    return ApkgImportSession(
      importFile: ({required sourcePath, required limits, cancel, onPhase}) {
        return onImport(_Call(sourcePath, limits, onPhase, cancel));
      },
      dataDir: p.join(root.path, 'data'),
      refreshDecks:
          refresh ??
          () async {
            rec.refreshes++;
          },
      flushEditor:
          flush ??
          () async {
            rec.flushes++;
          },
      startupError: startupError,
      pickFile: () async {
        rec.pickerCalls++;
        final pick = pickFile;
        if (pick == null) {
          return null;
        }
        return pick();
      },
      onTempFile: onTempFile,
      tempDirectory: tempDirectory ?? Directory(p.join(root.path, 'tmp')),
      maxBytes: maxBytes ?? kImportMaxBytes,
      log: log?.add,
    );
  }

  File writeFile(String name, List<int> bytes) {
    final file = File(p.join(root.path, name));
    file.parent.createSync(recursive: true);
    file.writeAsBytesSync(bytes);
    return file;
  }

  const zip = <int>[0x50, 0x4b, 0x03, 0x04, 0, 0];

  PreparedPlan sample({int newNotes = 1, bool firstImport = true}) {
    return PreparedPlan(
      batchId: '11111111-1111-4111-8111-111111111111',
      stagedPath: '/tmp/staged.apkg',
      stagedSha256: 'ab',
      firstImport: firstImport,
      newGuids: const ['g'],
      changed: const {},
      deckNames: const ['한국어'],
      counts: ImportPlanCounts(
        newNotes: newNotes,
        same: 0,
        changed: 0,
        localNewer: 0,
        blocked: 0,
        dup: 0,
        noResidentCall: newNotes == 0,
      ),
    );
  }

  test(
    'T16 rejects a bad extension, a non-zip, and an oversize file',
    () async {
      final rec = _Rec();
      final calls = <_Call>[];
      final session = open(
        rec: rec,
        onImport: (call) async {
          calls.add(call);
          return const ImportRunResult(outcome: ImportOutcome.committed);
        },
      );
      final ui = rec.ui;

      await session.importDropped(ui, [
        ApkgDrop.file(
          name: 'deck.json',
          localPath: writeFile('deck.json', zip).path,
        ),
      ]);
      await session.importDropped(ui, [
        ApkgDrop.file(
          name: 'notes.apkg',
          localPath: writeFile('notes.apkg', [0x7b, 0x7d]).path,
        ),
      ]);

      final huge = writeFile('huge.apkg', zip);
      huge.openSync(mode: FileMode.write).truncateSync(kImportMaxBytes + 1);
      await session.importDropped(ui, [
        ApkgDrop.file(name: 'huge.apkg', localPath: huge.path),
      ]);

      expect(calls, isEmpty);
      expect(rec.toasts, [
        kFormatFailure,
        kFormatFailure,
        tooLargeCompressedMessage('huge.apkg'),
      ]);
      expect(rec.refreshes, 0);
    },
  );

  test('T16 accepts .APKG and .Apkg and passes the O4 limits', () async {
    final rec = _Rec();
    final calls = <_Call>[];
    final session = open(
      rec: rec,
      onImport: (call) async {
        calls.add(call);
        return ImportRunResult(
          outcome: ImportOutcome.noop,
          plan: sample(newNotes: 0),
        );
      },
    );
    final upper = writeFile('Deck.APKG', zip);
    final mixed = writeFile('Deck.Apkg', zip);
    await session.importDropped(rec.ui, [
      ApkgDrop.file(name: 'Deck.APKG', localPath: upper.path),
    ]);
    await session.importDropped(rec.ui, [
      ApkgDrop.file(name: 'Deck.Apkg', localPath: mixed.path),
    ]);
    expect(calls, hasLength(2));
    expect(calls.first.limits.maxBytes, kImportLimitsV0.maxBytes);
    expect(
      calls.first.limits.maxUncompressedBytes,
      kImportLimitsV0.maxUncompressedBytes,
    );
    expect(kImportLimitsV0.maxBytes, 512 * 1024 * 1024);
    expect(kImportLimitsV0.maxUncompressedBytes, 2 * 1024 * 1024 * 1024);
    expect(kImportMaxBytes, kImportLimitsV0.maxBytes);
    expect(kImportMaxUncompressedBytes, kImportLimitsV0.maxUncompressedBytes);
  });

  test(
    'T16 a file of exactly 512 MiB is not the compressed-size failure',
    () async {
      final rec = _Rec();
      final calls = <_Call>[];
      final session = open(
        rec: rec,
        onImport: (call) async {
          calls.add(call);
          return ImportRunResult(
            outcome: ImportOutcome.noop,
            plan: sample(newNotes: 0),
          );
        },
      );
      final exact = writeFile('exact.apkg', zip);
      final exactHandle = exact.openSync(mode: FileMode.append);
      exactHandle.truncateSync(kImportMaxBytes);
      exactHandle.closeSync();
      await session.importDropped(rec.ui, [
        ApkgDrop.file(name: 'exact.apkg', localPath: exact.path),
      ]);
      expect(calls, hasLength(1));
    },
  );

  test('uncompressed failure uses the 2 GiB toast', () async {
    final rec = _Rec();
    final session = open(
      rec: rec,
      onImport: (call) async {
        return const ImportRunResult(
          outcome: ImportOutcome.failedBeforeCommit,
          error: 'too_large:uncompressed: sum',
        );
      },
    );
    final file = writeFile('wide.apkg', zip);
    await session.importDropped(rec.ui, [
      ApkgDrop.file(name: 'wide.apkg', localPath: file.path),
    ]);
    expect(rec.toasts, [tooLargeUncompressedMessage('wide.apkg')]);
    expect(rec.refreshes, 0);
  });

  test('T-I5-S startup failure blocks before the file picker', () async {
    final rec = _Rec();
    var picked = false;
    final session = open(
      rec: rec,
      startupError: StateError('recover'),
      pickFile: () async {
        picked = true;
        return null;
      },
      onImport: (call) async =>
          const ImportRunResult(outcome: ImportOutcome.noop),
    );
    await session.importFromPicker(rec.ui);
    await session.importDropped(rec.ui, [
      ApkgDrop.file(
        name: 'Deck.apkg',
        localPath: writeFile('Deck.apkg', zip).path,
      ),
    ]);
    expect(picked, isFalse);
    expect(rec.pickerCalls, 0);
    expect(rec.toasts, [kStartupBlocked, kStartupBlocked]);
  });

  test('T-I5-J2 failedAdoption refreshes and does not claim the collection is unchanged', () async {
    final rec = _Rec();
    final session = open(
      rec: rec,
      onImport: (call) async {
        return const ImportRunResult(outcome: ImportOutcome.failedAfterCommit);
      },
    );
    final file = writeFile('adopt.apkg', zip);
    await session.importDropped(rec.ui, [
      ApkgDrop.file(name: 'adopt.apkg', localPath: file.path),
    ]);
    expect(rec.toasts.single, adoptionFailureMessage('adopt.apkg'));
    expect(rec.toasts.single, isNot(contains('바뀌지 않았어요')));
    expect(rec.refreshes, 1);
    expect(session.sessionLocked, isFalse);
    expect(session.entryBlocked, isFalse);
  });

  test(
    'T-I5-X failedUnknown locks the session and a new session imports again',
    () async {
      final rec = _Rec();
      final session = open(
        rec: rec,
        onImport: (call) async {
          return const ImportRunResult(outcome: ImportOutcome.failedUnknown);
        },
      );
      final file = writeFile('lost.apkg', zip);
      await session.importDropped(rec.ui, [
        ApkgDrop.file(name: 'lost.apkg', localPath: file.path),
      ]);
      expect(rec.toasts.single, '‘lost.apkg’을 가져오지 못했어요.');
      expect(rec.toasts.single.contains('바뀌지 않았어요'), isFalse);
      expect(rec.refreshes, 1);
      expect(session.sessionLocked, isTrue);

      final before = rec.pickerCalls;
      await session.importFromPicker(rec.ui);
      expect(rec.pickerCalls, before);
      expect(rec.toasts.last, kStartupBlocked);

      final restarted = _Rec();
      var restartedCalls = 0;
      final again = open(
        rec: restarted,
        pickFile: () async => file.path,
        onImport: (call) async {
          restartedCalls++;
          return ImportRunResult(
            outcome: ImportOutcome.noop,
            plan: sample(newNotes: 0),
          );
        },
      );
      await again.importFromPicker(restarted.ui);
      expect(restartedCalls, 1);
    },
  );

  test(
    'T-I5-X an exception after afterIntent locks like failedUnknown',
    () async {
      final rec = _Rec();
      final session = open(
        rec: rec,
        onImport: (call) async {
          call.onPhase?.call(ImportPhase.afterIntent);
          throw StateError('after intent');
        },
      );
      final file = writeFile('boom.apkg', zip);
      await session.importDropped(rec.ui, [
        ApkgDrop.file(name: 'boom.apkg', localPath: file.path),
      ]);
      expect(rec.toasts.single, unknownFailureMessage('boom.apkg'));
      expect(rec.refreshes, 1);
      expect(session.entryBlocked, isTrue);

      final before = rec.toasts.length;
      await session.importDropped(rec.ui, [
        ApkgDrop.file(name: 'boom.apkg', localPath: file.path),
      ]);
      expect(rec.toasts.length, before + 1);
      expect(rec.toasts.last, kStartupBlocked);
      expect(rec.refreshes, 1);
    },
  );

  test(
    'an exception before afterIntent says the collection is unchanged',
    () async {
      final rec = _Rec();
      final session = open(
        rec: rec,
        onImport: (call) async {
          call.onPhase?.call(ImportPhase.afterFinish);
          throw StateError('early');
        },
      );
      final file = writeFile('early.apkg', zip);
      await session.importDropped(rec.ui, [
        ApkgDrop.file(name: 'early.apkg', localPath: file.path),
      ]);
      expect(rec.toasts.single, preCommitFailureMessage('early.apkg'));
      expect(rec.refreshes, 0);
      expect(session.sessionLocked, isFalse);
    },
  );

  test('cancel toast is shown only for ImportOutcome.cancelled', () async {
    final rec = _Rec();
    final session = open(
      rec: rec,
      onImport: (call) async {
        call.onPhase?.call(ImportPhase.afterReconcile);
        expect(rec.toasts, isEmpty);
        rec.progress!.requestCancel();
        expect(call.cancel!.isCancelled, isTrue);
        expect(rec.toasts, isEmpty);
        return const ImportRunResult(outcome: ImportOutcome.cancelled);
      },
    );
    final file = writeFile('cancel.apkg', zip);
    await session.importDropped(rec.ui, [
      ApkgDrop.file(name: 'cancel.apkg', localPath: file.path),
    ]);
    expect(rec.toasts, [kCancelToast]);
    expect(rec.refreshes, 0);

    final kept = _Rec();
    final keptSession = open(
      rec: kept,
      onImport: (call) async {
        call.onPhase?.call(ImportPhase.afterIntent);
        kept.progress!.requestCancel();
        expect(call.cancel!.isCancelled, isFalse);
        return ImportRunResult(
          outcome: ImportOutcome.committed,
          plan: sample(),
        );
      },
    );
    await keptSession.importDropped(kept.ui, [
      ApkgDrop.file(name: 'cancel.apkg', localPath: file.path),
    ]);
    expect(kept.toasts, isEmpty);
    expect(kept.summaries, isNotEmpty);
    expect(kept.refreshes, 1);
  });

  test('editor edits are flushed before importFile', () async {
    final order = <String>[];
    final rec = _Rec();
    final session = open(
      rec: rec,
      flush: () async {
        order.add('flush');
      },
      onImport: (call) async {
        order.add('import');
        expect(rec.flushes, 0);
        return ImportRunResult(
          outcome: ImportOutcome.noop,
          plan: sample(newNotes: 0),
        );
      },
    );
    final file = writeFile('flush.apkg', zip);
    await session.importDropped(rec.ui, [
      ApkgDrop.file(name: 'flush.apkg', localPath: file.path),
    ]);
    expect(order, ['flush', 'import']);
  });

  test('T-I5-J5 multi-file and folder drops do not import', () async {
    final rec = _Rec();
    final calls = <_Call>[];
    final session = open(
      rec: rec,
      onImport: (call) async {
        calls.add(call);
        return const ImportRunResult(outcome: ImportOutcome.noop);
      },
    );
    final a = writeFile('a.apkg', zip);
    final b = writeFile('b.apkg', zip);
    final folder = Directory(p.join(root.path, 'folder.apkg'))..createSync();
    await session.importDropped(rec.ui, [
      ApkgDrop.file(name: 'a.apkg', localPath: a.path),
      ApkgDrop.file(name: 'b.apkg', localPath: b.path),
    ]);
    await session.importDropped(rec.ui, [
      ApkgDrop.directory(name: 'folder.apkg', localPath: folder.path),
    ]);
    expect(calls, isEmpty);
    expect(rec.toasts, [kOneFileOnly, kFormatFailure]);
  });

  test('T-I5-J5 a drop is ignored while an import is running', () async {
    final rec = _Rec();
    final calls = <_Call>[];
    final gate = Completer<String?>();
    final session = open(
      rec: rec,
      pickFile: () => gate.future,
      onImport: (call) async {
        calls.add(call);
        return const ImportRunResult(outcome: ImportOutcome.noop);
      },
    );
    final pending = session.importFromPicker(rec.ui);
    await Future<void>.delayed(Duration.zero);
    expect(session.running, isTrue);
    final file = writeFile('later.apkg', zip);
    await session.importDropped(rec.ui, [
      ApkgDrop.file(name: 'later.apkg', localPath: file.path),
    ]);
    expect(calls, isEmpty);
    gate.complete(null);
    await pending;
    expect(calls, isEmpty);
  });

  test(
    'T-I5-J5 a drop without localPath is streamed and the temp file is removed',
    () async {
      final rec = _Rec();
      final calls = <_Call>[];
      File? temp;
      final dataDir = p.join(root.path, 'data');
      final session = open(
        rec: rec,
        onTempFile: (file) => temp = file,
        onImport: (call) async {
          calls.add(call);
          expect(File(call.path).existsSync(), isTrue);
          expect(p.isWithin(p.join(dataDir, 'import'), call.path), isFalse);
          expect(
            call.path,
            isNot(contains('${p.join(dataDir, 'import')}${p.separator}')),
          );
          return ImportRunResult(
            outcome: ImportOutcome.noop,
            plan: sample(newNotes: 0),
          );
        },
      );
      final bytes = <int>[0x50, 0x4b, 0x03, 0x04, 1, 2, 3];
      await session.importDropped(rec.ui, [
        ApkgDrop.file(
          name: 'stream.apkg',
          openRead: () async* {
            yield bytes;
          },
        ),
      ]);
      expect(calls, hasLength(1));
      expect(calls.single.path, temp!.path);
      expect(temp!.existsSync(), isFalse);
      expect(p.isWithin(p.join(dataDir, 'import'), temp!.path), isFalse);
    },
  );

  test('T-I5-J5 a stream past 512 MiB aborts with no import and deletes the temp file', () async {
    final rec = _Rec();
    final calls = <_Call>[];
    File? temp;
    final session = open(
      rec: rec,
      onTempFile: (file) => temp = file,
      onImport: (call) async {
        calls.add(call);
        return const ImportRunResult(outcome: ImportOutcome.noop);
      },
    );
    await session.importDropped(rec.ui, [
      ApkgDrop.file(
        name: 'big.apkg',
        openRead: () async* {
          yield _LenList(kImportMaxBytes + 1);
        },
      ),
    ]);
    expect(calls, isEmpty);
    expect(rec.toasts, [tooLargeCompressedMessage('big.apkg')]);
    expect(temp, isNotNull);
    expect(temp!.existsSync(), isFalse);
  });

  test(
    'a committed import refreshes and a single-line no-op uses a toast',
    () async {
      final rec = _Rec();
      var which = 0;
      final session = open(
        rec: rec,
        onImport: (call) async {
          which++;
          if (which == 1) {
            return ImportRunResult(
              outcome: ImportOutcome.committed,
              plan: sample(),
            );
          }
          return ImportRunResult(
            outcome: ImportOutcome.noop,
            plan: sample(newNotes: 0, firstImport: false),
          );
        },
      );
      final file = writeFile('ok.apkg', zip);
      await session.importDropped(rec.ui, [
        ApkgDrop.file(name: 'ok.apkg', localPath: file.path),
      ]);
      expect(rec.summaries.single.title, '‘한국어’ 덱을 가져왔어요.');
      expect(rec.refreshes, 1);
      await session.importDropped(rec.ui, [
        ApkgDrop.file(name: 'ok.apkg', localPath: file.path),
      ]);
      expect(rec.toasts.single, '이미 가져온 덱이에요. 바뀐 내용이 없어서 그대로 뒀어요.');
      expect(rec.refreshes, 1);
    },
  );

  test('the file picker lists every ASCII case of apkg', () {
    final cases = <String>{};
    for (final a in ['a', 'A']) {
      for (final letterP in ['p', 'P']) {
        for (final k in ['k', 'K']) {
          for (final g in ['g', 'G']) {
            cases.add('$a$letterP$k$g');
          }
        }
      }
    }
    expect(kApkgPickerExtensions.toSet(), cases);
    for (final extension in kApkgPickerExtensions) {
      expect(isApkgFileName('Deck.$extension'), isTrue);
    }
  });

  test(
    'a drop stream IO error toasts, logs, and deletes the temp file',
    () async {
      final rec = _Rec();
      final log = <String>[];
      final calls = <_Call>[];
      File? temp;
      final session = open(
        rec: rec,
        log: log,
        onTempFile: (file) => temp = file,
        onImport: (call) async {
          calls.add(call);
          return const ImportRunResult(outcome: ImportOutcome.noop);
        },
      );
      await session.importDropped(rec.ui, [
        ApkgDrop.file(
          name: 'stream.apkg',
          openRead: () => throw const FileSystemException(
            'SECRET-IO',
            '/tmp/format: notes.apkg',
          ),
        ),
      ]);
      expect(calls, isEmpty);
      expect(rec.toasts, [preCommitFailureMessage('stream.apkg')]);
      expect(rec.toasts.single.contains('SECRET-IO'), isFalse);
      expect(rec.toasts.single.contains('format:'), isFalse);
      expect(log, hasLength(1));
      expect(log.single, contains('SECRET-IO'));
      expect(log.single, contains('format:'));
      expect(log.single.contains('\n'), isFalse);
      expect(temp, isNotNull);
      expect(temp!.existsSync(), isFalse);
      expect(session.running, isFalse);
    },
  );

  test('a drop directory create failure toasts and clears running', () async {
    final rec = _Rec();
    final log = <String>[];
    final calls = <_Call>[];
    final occupied = File(p.join(root.path, 'blocked'))..writeAsStringSync('x');
    final session = open(
      rec: rec,
      log: log,
      tempDirectory: Directory(occupied.path),
      onImport: (call) async {
        calls.add(call);
        return const ImportRunResult(outcome: ImportOutcome.noop);
      },
    );
    await session.importDropped(rec.ui, [
      ApkgDrop.file(
        name: 'stream.apkg',
        openRead: () async* {
          yield zip;
        },
      ),
    ]);
    expect(calls, isEmpty);
    expect(rec.toasts, [preCommitFailureMessage('stream.apkg')]);
    expect(rec.toasts.single.contains('FileSystemException'), isFalse);
    expect(log, isNotEmpty);
    expect(log.single.contains('\n'), isFalse);
    expect(session.running, isFalse);
  });

  test(
    'refreshDecks throwing still shows the adoption toast and clears running',
    () async {
      final rec = _Rec();
      final log = <String>[];
      final session = open(
        rec: rec,
        log: log,
        refresh: () async {
          throw StateError('SECRET-REFRESH');
        },
        onImport: (call) async {
          return const ImportRunResult(
            outcome: ImportOutcome.failedAfterCommit,
            error: 'SECRET-ADOPT',
          );
        },
      );
      final file = writeFile('adopt.apkg', zip);
      await session.importDropped(rec.ui, [
        ApkgDrop.file(name: 'adopt.apkg', localPath: file.path),
      ]);
      expect(rec.toasts, [adoptionFailureMessage('adopt.apkg')]);
      expect(rec.toasts.single.contains('SECRET'), isFalse);
      expect(log.join('\n'), contains('SECRET-REFRESH'));
      expect(log.join('\n'), contains('SECRET-ADOPT'));
      expect(log.every((line) => !line.contains('\n')), isTrue);
      expect(session.running, isFalse);
      expect(session.sessionLocked, isFalse);
    },
  );

  test(
    'refreshDecks throwing after a streamed commit deletes the temp file',
    () async {
      final rec = _Rec();
      final log = <String>[];
      File? temp;
      final session = open(
        rec: rec,
        log: log,
        onTempFile: (file) => temp = file,
        refresh: () async {
          throw StateError('SECRET-REFRESH');
        },
        onImport: (call) async {
          return ImportRunResult(
            outcome: ImportOutcome.committed,
            plan: sample(),
            commitError: StateError('SECRET-COMMIT'),
          );
        },
      );
      await session.importDropped(rec.ui, [
        ApkgDrop.file(
          name: 'stream.apkg',
          openRead: () async* {
            yield zip;
          },
        ),
      ]);
      expect(rec.summaries, isNotEmpty);
      expect(rec.summaries.single.title.contains('SECRET'), isFalse);
      expect(rec.toasts.every((toast) => !toast.contains('SECRET')), isTrue);
      expect(log.join('\n'), contains('SECRET-REFRESH'));
      expect(log.join('\n'), contains('SECRET-COMMIT'));
      expect(temp, isNotNull);
      expect(temp!.existsSync(), isFalse);
      expect(session.running, isFalse);
    },
  );

  test(
    'a caught import exception is logged and stays out of the toast',
    () async {
      final rec = _Rec();
      final log = <String>[];
      final session = open(
        rec: rec,
        log: log,
        onImport: (call) async {
          call.onPhase?.call(ImportPhase.afterFinish);
          throw StateError('SECRET-EARLY');
        },
      );
      final file = writeFile('early.apkg', zip);
      await session.importDropped(rec.ui, [
        ApkgDrop.file(name: 'early.apkg', localPath: file.path),
      ]);
      expect(rec.toasts, [preCommitFailureMessage('early.apkg')]);
      expect(rec.toasts.single.contains('SECRET-EARLY'), isFalse);
      expect(log.single, contains('SECRET-EARLY'));
      expect(log.single, contains('failedBeforeCommit'));
      expect(log.single.contains('\n'), isFalse);
      expect(session.running, isFalse);
      expect(session.sessionLocked, isFalse);
    },
  );

  test('an exception after afterIntent is logged as failedUnknown', () async {
    final rec = _Rec();
    final log = <String>[];
    final session = open(
      rec: rec,
      log: log,
      onImport: (call) async {
        call.onPhase?.call(ImportPhase.afterIntent);
        Error.throwWithStackTrace(
          StateError('SECRET-LATE'),
          StackTrace.fromString('SECRET-STACK\nline two'),
        );
      },
    );
    final file = writeFile('late.apkg', zip);
    await session.importDropped(rec.ui, [
      ApkgDrop.file(name: 'late.apkg', localPath: file.path),
    ]);
    expect(rec.toasts, [unknownFailureMessage('late.apkg')]);
    expect(rec.toasts.single.contains('SECRET'), isFalse);
    expect(log.single, contains('SECRET-LATE'));
    expect(log.single, contains('SECRET-STACK'));
    expect(log.single, contains('line two'));
    expect(log.single.contains('\n'), isFalse);
    expect(session.sessionLocked, isTrue);
    expect(session.running, isFalse);
  });

  test('a flush failure is logged and does not show the raw error', () async {
    final rec = _Rec();
    final log = <String>[];
    final calls = <_Call>[];
    final session = open(
      rec: rec,
      log: log,
      flush: () async {
        throw StateError('SECRET-FLUSH');
      },
      onImport: (call) async {
        calls.add(call);
        return const ImportRunResult(outcome: ImportOutcome.noop);
      },
    );
    final file = writeFile('flush.apkg', zip);
    await session.importDropped(rec.ui, [
      ApkgDrop.file(name: 'flush.apkg', localPath: file.path),
    ]);
    expect(calls, isEmpty);
    expect(rec.toasts, [preCommitFailureMessage('flush.apkg')]);
    expect(rec.toasts.single.contains('SECRET-FLUSH'), isFalse);
    expect(log.single, contains('SECRET-FLUSH'));
    expect(log.single, contains('flushEditor'));
    expect(session.running, isFalse);
  });

  test(
    'only a committed import opens the deck list; other outcomes are announced',
    () async {
      final rec = _Rec();
      final log = <String>[];
      var outcome = ImportOutcome.cancelled;
      Object? error;
      ImportPhase? explode;
      PreparedPlan? plan;
      final session = open(
        rec: rec,
        log: log,
        onImport: (call) async {
          final phase = explode;
          if (phase != null) {
            call.onPhase?.call(phase);
            throw StateError('SECRET-BOOM');
          }
          return ImportRunResult(outcome: outcome, error: error, plan: plan);
        },
      );
      final file = writeFile('deck.apkg', zip);

      Future<void> dropNamed(String name) {
        return session.importDropped(rec.ui, [
          ApkgDrop.file(name: name, localPath: file.path),
        ]);
      }

      Future<void> expectStay(String spoken) async {
        expect(rec.deckLists, 0);
        expect(rec.announcements, [spoken]);
        expect(rec.announcements.single.contains('SECRET'), isFalse);
        rec.announcements.clear();
        rec.toasts.clear();
      }

      await dropNamed('notes.txt');
      await expectStay(kFormatFailure);

      outcome = ImportOutcome.cancelled;
      await dropNamed('deck.apkg');
      await expectStay(kCancelToast);

      outcome = ImportOutcome.failedBeforeCommit;
      error = StateError('SECRET-BEFORE');
      await dropNamed('deck.apkg');
      await expectStay(preCommitFailureMessage('deck.apkg'));

      outcome = ImportOutcome.failedAfterCommit;
      error = StateError('SECRET-AFTER');
      await dropNamed('deck.apkg');
      await expectStay(adoptionFailureMessage('deck.apkg'));

      outcome = ImportOutcome.noop;
      error = null;
      plan = sample(newNotes: 0, firstImport: false);
      await dropNamed('deck.apkg');
      await expectStay(kAlreadyImported);
      plan = null;

      explode = ImportPhase.afterFinish;
      await dropNamed('deck.apkg');
      await expectStay(preCommitFailureMessage('deck.apkg'));
      explode = null;

      outcome = ImportOutcome.committed;
      final committed = sample();
      plan = committed;
      final summary = formatImportSummary(
        plan: committed,
        fileName: 'deck.apkg',
      );
      await dropNamed('deck.apkg');
      expect(rec.deckLists, 1);
      expect(rec.announcements, [spokenImportSummary(summary)]);
      expect(rec.summaries, hasLength(1));
      rec.announcements.clear();

      plan = null;
      await dropNamed('plain.apkg');
      expect(rec.deckLists, 2);
      expect(rec.announcements, [importedFileMessage('plain.apkg')]);
      rec.announcements.clear();

      outcome = ImportOutcome.failedUnknown;
      error = StateError('SECRET-UNKNOWN');
      plan = null;
      await dropNamed('deck.apkg');
      expect(rec.deckLists, 2);
      expect(rec.announcements, [unknownFailureMessage('deck.apkg')]);
      expect(rec.announcements.single.contains('SECRET'), isFalse);
      expect(log.any((line) => line.contains('SECRET-UNKNOWN')), isTrue);
      expect(log.every((line) => !line.contains('\n')), isTrue);
      expect(session.sessionLocked, isTrue);
      expect(session.running, isFalse);

      final late = _Rec();
      final lateLog = <String>[];
      final later = open(
        rec: late,
        log: lateLog,
        onImport: (call) async {
          call.onPhase?.call(ImportPhase.afterIntent);
          throw StateError('SECRET-BOOM');
        },
      );
      await later.importDropped(late.ui, [
        ApkgDrop.file(name: 'deck.apkg', localPath: file.path),
      ]);
      expect(late.deckLists, 0);
      expect(late.announcements, [unknownFailureMessage('deck.apkg')]);
      expect(late.announcements.single.contains('SECRET'), isFalse);
      expect(lateLog.single, contains('SECRET-BOOM'));
      expect(lateLog.single.contains('\n'), isFalse);
      expect(later.sessionLocked, isTrue);
    },
  );
}
