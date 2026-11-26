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
  var refreshes = 0;
  var flushes = 0;
  ImportProgressModel? progress;
  var pickerCalls = 0;

  ApkgImportUi get ui => ApkgImportUi(
    toast: toasts.add,
    showSummary: summaries.add,
    showProgress: (model) async {
      progress = model;
    },
    closeProgress: () {},
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
  }) {
    return ApkgImportSession(
      importFile: ({required sourcePath, required limits, cancel, onPhase}) {
        return onImport(_Call(sourcePath, limits, onPhase, cancel));
      },
      dataDir: p.join(root.path, 'data'),
      refreshDecks: () async {
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
    expect(calls.first.limits.maxBytes, kImportMaxBytes);
    expect(
      calls.first.limits.maxUncompressedBytes,
      kImportMaxUncompressedBytes,
    );
    expect(kImportMaxBytes, 512 * 1024 * 1024);
    expect(kImportMaxUncompressedBytes, 2 * 1024 * 1024 * 1024);
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
}
