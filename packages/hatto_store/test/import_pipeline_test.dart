// SPDX-FileCopyrightText: 2026 Hatto Social contributors
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:hatto_store/hatto_store.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'fake_collection.dart';
import 'fake_import_engine.dart';

const batch = '11111111-1111-4111-8111-111111111111';
const newGuid = 'new-guid';
const changedGuid = 'changed-guid';
const residentHash =
    '1111111111111111111111111111111111111111111111111111111111111111';
const fileHash =
    '2222222222222222222222222222222222222222222222222222222222222222';

void main() {
  test('T1 a second import of the same file is a no-op', () async {
    final ctx = await _open();
    final plan = _commitPlan(ctx);
    ctx.engine.plan = plan;
    _armNewNote(ctx);
    ctx.engine.fileNotes = [
      const StagedFileNote(
        guid: newGuid,
        notetypeId: 1,
        mod: 1,
        contentHashHex: fileHash,
      ),
    ];

    final first = await _pipeline(ctx)
        .run(sourcePath: ctx.source.path, maxBytes: 1000);
    expect(first, ImportOutcome.committed);
    expect(ctx.engine.commitCalls, 1);
    final snapshot = _dump(ctx.db);
    final archived = File(importArchivePath(ctx.dataDir, ctx.sourceSha));
    expect(archived.readAsBytesSync(), ctx.sourceBytes);
    final archiveBytes = archived.readAsBytesSync();

    ctx.engine.plan = _noopPlan(ctx);
    final second = await _pipeline(ctx)
        .run(sourcePath: ctx.source.path, maxBytes: 1000);
    expect(second, ImportOutcome.noop);
    expect(ctx.engine.commitCalls, 1);
    expect(_dump(ctx.db), snapshot);
    expect(archived.readAsBytesSync(), archiveBytes);
    expect(Directory(p.join(ctx.dataDir, 'imports')).listSync(), hasLength(1));
    expect(ctx.db.journalRows(), isEmpty);
    expect(ctx.db.pendingIntents(), isEmpty);
  });

  test('T9 missing notetype fails before commit', () async {
    final ctx = await _open();
    ctx.engine.onStage = () => throw StateError('missing notetype');
    _watchBatches(ctx);

    final outcome = await _pipeline(ctx)
        .run(sourcePath: ctx.source.path, maxBytes: 1000);

    expect(outcome, ImportOutcome.failedBeforeCommit);
    expect(ctx.engine.commitCalls, 0);
    expect(ctx.db.pendingIntents(), isEmpty);
    expect(ctx.collection.notes.containsKey(20), isFalse);
    _expectNoBatch(ctx);
  });

  test('T9 fault after the resident commit is adopted on startup', () async {
    final ctx = await _open();
    ctx.engine.plan = _commitPlan(ctx);
    _armNewNote(ctx);
    _watchBatches(ctx);
    final pipeline = _pipeline(
      ctx,
      fault: (phase) {
        if (phase == ImportPhase.afterResidentCommit) {
          throw StateError('T9b');
        }
      },
    );
    await expectLater(
      pipeline.run(sourcePath: ctx.source.path, maxBytes: 1000),
      throwsA(isA<StateError>().having((e) => e.message, 'message', 'T9b')),
    );
    expect(ctx.engine.commitCalls, 1);
    expect(ctx.db.pendingIntents(), hasLength(1));
    expect(ctx.db.notes(), isEmpty);

    final path = ctx.dbPath;
    ctx.db.close();
    final reopened = SideDb.open(path: path, deviceId: 'dev');
    addTearDown(reopened.close);
    await _startup(reopened, ctx);
    expect(reopened.pendingIntents(), isEmpty);
    final note = reopened.note(newGuid)!;
    expect(note.rslibNoteId, 20);
    final deck = reopened.deckByRslibId(7)!;
    expect(deck.importBatchId, batch);
    expect(deck.sourceSha256, ctx.sourceSha);
    expect(deck.originKind, 'import');
    expect(reopened.journalRows(), isEmpty);
    expect(
      File(importArchivePath(ctx.dataDir, ctx.sourceSha)).readAsBytesSync(),
      ctx.sourceBytes,
    );

    ctx.engine.plan = _noopPlan(ctx);
    final again = ImportPipeline(
      db: reopened,
      anki: ctx.collection,
      engine: ctx.engine,
      dataDir: ctx.dataDir,
    );
    final second = await again.run(sourcePath: ctx.source.path, maxBytes: 1000);
    expect(second, ImportOutcome.noop);
    expect(ctx.engine.commitCalls, 1);
  });

  test('T9 adoption throwing after commit keeps the intent', () async {
    final ctx = await _open();
    ctx.engine.plan = _commitPlan(ctx);
    ctx.engine.deckIds = const {};
    _armNewNote(ctx);

    final outcome = await _pipeline(ctx)
        .run(sourcePath: ctx.source.path, maxBytes: 1000);

    expect(outcome, ImportOutcome.failedAfterCommit);
    expect(ctx.engine.commitCalls, 1);
    expect(ctx.db.pendingIntents(), hasLength(1));
    expect(ctx.db.pendingIntents().single.op, intentImport);
    expect(ctx.db.notes(), isEmpty);
    expect(ctx.collection.notes.containsKey(20), isTrue);
  });

  test('T19 a missing intent does not call the resident import', () async {
    final ctx = await _open();
    ctx.engine.plan = _commitPlan(ctx);
    final outcome = await _pipeline(
      ctx,
      fault: (phase) {
        if (phase == ImportPhase.afterIntent) {
          final row = ctx.db.pendingIntents().single;
          ctx.db.abandonIntent(row.id);
        }
      },
    ).run(sourcePath: ctx.source.path, maxBytes: 1000);

    expect(outcome, ImportOutcome.failedBeforeCommit);
    expect(ctx.engine.commitCalls, 0);
    expect(ctx.db.pendingIntents(), isEmpty);
  });

  test(
    'T19 a staged hash mismatch does not call the resident import',
    () async {
      final ctx = await _open();
      final plan = _commitPlan(ctx);
      ctx.engine.plan = PreparedPlan(
        batchId: plan.batchId,
        stagedPath: plan.stagedPath,
        stagedSha256: 'ab' * 32,
        firstImport: plan.firstImport,
        newGuids: plan.newGuids,
        changed: plan.changed,
        deckNames: plan.deckNames,
        counts: plan.counts,
      );

      final outcome = await _pipeline(ctx)
          .run(sourcePath: ctx.source.path, maxBytes: 1000);

      expect(outcome, ImportOutcome.failedBeforeCommit);
      expect(ctx.engine.commitCalls, 0);
      expect(ctx.db.pendingIntents(), isEmpty);
    },
  );

  test('T23 every phase boundary leaves no orphan batch or intent', () async {
    const afterCommit = {
      ImportPhase.afterResidentCommit,
      ImportPhase.afterArchive,
      ImportPhase.duringAdoption,
    };
    for (final phase in ImportPhase.values) {
      final ctx = await _open();
      ctx.engine.plan = _commitPlan(ctx);
      _armNewNote(ctx);
      _watchBatches(ctx);
      ctx.engine.onStage = () {
        _createBatch(ctx);
      };
      await expectLater(
        _pipeline(
          ctx,
          fault: (hit) {
            if (hit == phase) {
              throw StateError('T23 ${phase.name}');
            }
          },
        ).run(sourcePath: ctx.source.path, maxBytes: 1000),
        throwsA(
          isA<StateError>().having(
            (err) => err.message,
            'message',
            'T23 ${phase.name}',
          ),
        ),
        reason: phase.name,
      );

      final path = ctx.dbPath;
      ctx.db.close();
      final reopened = SideDb.open(path: path, deviceId: 'dev');
      addTearDown(reopened.close);
      await _startup(reopened, ctx);

      expect(reopened.pendingIntents(), isEmpty, reason: phase.name);
      _expectNoBatch(ctx, reason: phase.name);
      if (afterCommit.contains(phase)) {
        expect(
          ctx.collection.notes.containsKey(20),
          isTrue,
          reason: phase.name,
        );
        expect(reopened.note(newGuid)!.rslibNoteId, 20, reason: phase.name);
        expect(
          reopened.deckByRslibId(7)!.importBatchId,
          batch,
          reason: phase.name,
        );
      } else {
        expect(
          ctx.collection.notes.containsKey(20),
          isFalse,
          reason: phase.name,
        );
        expect(reopened.note(newGuid), isNull, reason: phase.name);
      }
    }
  });

  test('pre records the resident count and changed hashes', () async {
    final ctx = await _open();
    ctx.engine.notetypeUseCount = 4;
    ctx.engine.fileNotes = [
      const StagedFileNote(
        guid: newGuid,
        notetypeId: 1,
        mod: 3,
        contentHashHex: fileHash,
      ),
      const StagedFileNote(
        guid: changedGuid,
        notetypeId: 1,
        mod: 4,
        contentHashHex: fileHash,
      ),
    ];
    ctx.engine.notes = const [
      ResidentNoteFacts(guid: changedGuid, id: 5, contentHashHex: residentHash),
    ];
    ctx.db.putDeck(deckGuid: 'home', rslibDeckId: 1, originKind: 'editor');
    ctx.db.importNote(
      noteGuid: changedGuid,
      rslibNoteId: 5,
      cards: const [ImportedNoteCard(ord: 0, rslibDeckId: 1)],
    );
    ctx.collection
      ..decks = const [CollectionDeck(id: 1, name: 'Old')]
      ..addNote(id: 5, guid: changedGuid, cardId: 50, deckId: 1);
    ctx.engine.plan = PreparedPlan(
      batchId: batch,
      stagedPath: ctx.staged.path,
      stagedSha256: ctx.stagedSha,
      firstImport: false,
      newGuids: const [newGuid],
      changed: const {changedGuid: fileHash},
      deckNames: const ['Spanish'],
      counts: const ImportPlanCounts(
        newNotes: 1,
        same: 0,
        changed: 1,
        localNewer: 0,
        blocked: 0,
        dup: 0,
        noResidentCall: false,
      ),
    );
    ImportIntentExpected? seen;
    ctx.engine.onCommit = () {
      seen = decodeImportIntentExpected(
        ctx.db.pendingIntents().single.expected!,
      );
      ctx.collection.decks = [
        ...ctx.collection.decks,
        const CollectionDeck(id: 7, name: 'Spanish'),
      ];
      ctx.collection.addNote(id: 20, guid: newGuid, cardId: 200, deckId: 7);
    };
    ctx.engine.newNoteIds = const [20];

    final selects = ctx.db.notesByGuidsSelects;
    final outcome = await _pipeline(ctx)
        .run(sourcePath: ctx.source.path, maxBytes: 1000);

    expect(outcome, ImportOutcome.committed);
    expect(ctx.db.notesByGuidsSelects, selects + 1);
    expect(seen!.pre.noteCount, 4);
    expect(seen!.pre.changed.keys.toList(), seen!.changed.keys.toList());
    expect(seen!.pre.changed[changedGuid], residentHash);
    expect(seen!.changed[changedGuid], fileHash);
    expect(ctx.db.note(changedGuid)!.homeDeckGuid, 'home');
    expect(
      ctx.db.note(newGuid)!.homeDeckGuid,
      ctx.db.deckByRslibId(7)!.deckGuid,
    );
  });

  test(
    'pre fails when a changed guid is missing from the resident match',
    () async {
      final ctx = await _open();
      ctx.engine.plan = PreparedPlan(
        batchId: batch,
        stagedPath: ctx.staged.path,
        stagedSha256: ctx.stagedSha,
        firstImport: false,
        newGuids: const [newGuid],
        changed: const {changedGuid: fileHash},
        deckNames: const ['Spanish'],
        counts: const ImportPlanCounts(
          newNotes: 1,
          same: 0,
          changed: 1,
          localNewer: 0,
          blocked: 0,
          dup: 0,
          noResidentCall: false,
        ),
      );

      final outcome = await _pipeline(ctx)
          .run(sourcePath: ctx.source.path, maxBytes: 1000);

      expect(outcome, ImportOutcome.failedBeforeCommit);
      expect(ctx.engine.commitCalls, 0);
      expect(ctx.db.pendingIntents(), isEmpty);
    },
  );

  test('T-L1 a write requested during the import runs after it', () async {
    final ctx = await _open();
    ctx.engine.plan = _commitPlan(ctx);
    _armNewNote(ctx);
    final hold = Completer<void>();
    final entered = Completer<void>();
    ctx.engine.onStage = () async {
      entered.complete();
      await hold.future;
    };
    var wrote = false;
    final wrapper = WriteWrapper(
      db: ctx.db,
      command: (_, _, _) async {
        wrote = true;
        return ProtoResponse.emptyOk;
      },
    );
    final importFuture = _pipeline(ctx)
        .run(sourcePath: ctx.source.path, maxBytes: 1000);
    await entered.future;
    final writeFuture = wrapper.run(
      op: intentNoteAdd,
      entityKind: 'note',
      guid: 'other',
      service: 1,
      method: 1,
      input: Uint8List(0),
    );
    await Future<void>.delayed(Duration.zero);
    expect(wrote, isFalse);
    hold.complete();
    expect(await importFuture, ImportOutcome.committed);
    await writeFuture;
    expect(wrote, isTrue);
  });

  test('T-L2 a no-op releases the lock after finish', () async {
    final ctx = await _open();
    ctx.engine.plan = _noopPlan(ctx);
    final hold = Completer<void>();
    final entered = Completer<void>();
    ctx.engine.finishWith = (staged, facts, found) async {
      entered.complete();
      await hold.future;
      return _noopPlan(ctx);
    };
    var wrote = false;
    final wrapper = WriteWrapper(
      db: ctx.db,
      command: (_, _, _) async {
        wrote = true;
        return ProtoResponse.emptyOk;
      },
    );
    final importFuture = _pipeline(ctx)
        .run(sourcePath: ctx.source.path, maxBytes: 1000);
    await entered.future;
    final writeFuture = wrapper.run(
      op: intentNoteAdd,
      entityKind: 'note',
      guid: 'other',
      service: 1,
      method: 1,
      input: Uint8List(0),
    );
    await Future<void>.delayed(Duration.zero);
    expect(wrote, isFalse);
    hold.complete();
    expect(await importFuture, ImportOutcome.noop);
    await writeFuture;
    expect(wrote, isTrue);
    expect(ctx.engine.commitCalls, 0);
    expect(ctx.db.pendingIntents(), isEmpty);
    expect(Directory(p.join(ctx.dataDir, 'imports')).existsSync(), isFalse);
  });

  test('T-N1 dispose runs once on cancel and on lookup failure', () async {
    final cancelCtx = await _open();
    final token = ImportCancellationToken();
    cancelCtx.engine.onStage = () {
      token.cancel();
    };
    final cancelled = await _pipeline(
      cancelCtx,
      cancel: token,
    ).run(sourcePath: cancelCtx.source.path, maxBytes: 1000);
    expect(cancelled, ImportOutcome.cancelled);
    expect(cancelCtx.engine.lastStaged!.disposeCount, 1);
    expect(cancelCtx.engine.commitCalls, 0);

    final failCtx = await _open();
    failCtx.engine.lookupError = StateError('resident lookup');
    final failed = await _pipeline(failCtx)
        .run(sourcePath: failCtx.source.path, maxBytes: 1000);
    expect(failed, ImportOutcome.failedBeforeCommit);
    expect(failCtx.engine.lastStaged!.disposeCount, 1);
    expect(failCtx.engine.commitCalls, 0);
  });

  test('T-N3 a stale note id fails before an intent row', () async {
    final ctx = await _open();
    ctx.db.putDeck(deckGuid: 'home', rslibDeckId: 1, originKind: 'editor');
    ctx.db.importNote(
      noteGuid: 'stale',
      rslibNoteId: 99,
      cards: const [ImportedNoteCard(ord: 0, rslibDeckId: 1)],
    );
    ctx.engine.fileNotes = const [
      StagedFileNote(
        guid: 'stale',
        notetypeId: 1,
        mod: 1,
        contentHashHex: fileHash,
      ),
    ];
    ctx.engine.lookupError = StateError('missing note 99');

    final outcome = await _pipeline(ctx)
        .run(sourcePath: ctx.source.path, maxBytes: 1000);

    expect(outcome, ImportOutcome.failedBeforeCommit);
    expect(ctx.engine.commitCalls, 0);
    expect(ctx.db.pendingIntents(), isEmpty);
    expect(ctx.engine.lastStaged!.disposeCount, 1);
    expect(ctx.db.note('stale')!.rslibNoteId, 99);
  });

  test('B1 a rejected commit with no mutation drops the intent', () async {
    final ctx = await _open();
    ctx.engine.plan = _commitPlan(ctx);
    ctx.engine.commitError = StateError('rejected');
    _watchBatches(ctx);
    ctx.engine.onStage = () {
      _createBatch(ctx);
    };

    final outcome = await _pipeline(ctx)
        .run(sourcePath: ctx.source.path, maxBytes: 1000);

    expect(outcome, ImportOutcome.failedBeforeCommit);
    expect(ctx.engine.commitCalls, 1);
    expect(ctx.db.pendingIntents(), isEmpty);
    expect(ctx.collection.notes.containsKey(20), isFalse);
    _expectNoBatch(ctx);
  });

  test('B1 a commit that mutates and then throws is adopted', () async {
    final ctx = await _open();
    ctx.engine.plan = _commitPlan(ctx);
    _armNewNote(ctx);
    ctx.engine.commitError = StateError('rejected after write');
    ctx.engine.applyCommitBeforeError = true;
    _watchBatches(ctx);
    ctx.engine.onStage = () {
      _createBatch(ctx);
    };

    final outcome = await _pipeline(ctx)
        .run(sourcePath: ctx.source.path, maxBytes: 1000);

    expect(outcome, ImportOutcome.committed);
    expect(ctx.db.pendingIntents(), isEmpty);
    expect(ctx.db.note(newGuid)!.rslibNoteId, 20);
    expect(ctx.collection.notes.containsKey(20), isTrue);
    _expectNoBatch(ctx);
  });

  test(
    'B1 a rejected import does not rewrite home after a later move',
    () async {
      final ctx = await _open();
      ctx.engine.plan = _commitPlan(ctx);
      ctx.engine.commitError = StateError('rejected');
      _watchBatches(ctx);
      final first = await _pipeline(ctx)
          .run(sourcePath: ctx.source.path, maxBytes: 1000);
      expect(first, ImportOutcome.failedBeforeCommit);
      expect(ctx.db.pendingIntents(), isEmpty);
      expect(ctx.collection.notes.containsKey(20), isFalse);

      ctx.engine.commitError = null;
      _armNewNote(ctx);
      _ensureRaw(ctx);
      final second = await _pipeline(ctx)
          .run(sourcePath: ctx.source.path, maxBytes: 1000);
      expect(second, ImportOutcome.committed);
      final home = ctx.db.note(newGuid)!.homeDeckGuid;

      ctx.collection.cards[200] = const CollectionCard(id: 200, deckId: 9);
      ctx.collection.decks = [
        ...ctx.collection.decks,
        const CollectionDeck(id: 9, name: 'other'),
      ];
      ctx.db.putDeck(
        deckGuid: 'other-deck',
        rslibDeckId: 9,
        originKind: 'editor',
      );

      final path = ctx.dbPath;
      ctx.db.close();
      final reopened = SideDb.open(path: path, deviceId: 'dev');
      addTearDown(reopened.close);
      await _startup(reopened, ctx);

      expect(reopened.note(newGuid)!.homeDeckGuid, home);
      expect(reopened.note(newGuid)!.homeDeckGuid, isNot('other-deck'));
      expect(reopened.pendingIntents(), isEmpty);
    },
  );
}

class _Ctx {
  _Ctx({
    required this.db,
    required this.dbPath,
    required this.dataDir,
    required this.collection,
    required this.engine,
    required this.source,
    required this.staged,
    required this.sourceBytes,
    required this.sourceSha,
    required this.stagedSha,
  });

  final SideDb db;
  final String dbPath;
  final String dataDir;
  final FakeCollection collection;
  final FakeImportEngine engine;
  final File source;
  final File staged;
  final List<int> sourceBytes;
  final String sourceSha;
  final String stagedSha;
}

Future<_Ctx> _open() async {
  final root = await Directory.systemTemp.createTemp('hatto-pipe');
  addTearDown(() => root.delete(recursive: true));
  final dbPath = p.join(root.path, 'hatto.sqlite');
  final db = SideDb.open(path: dbPath, deviceId: 'dev');
  addTearDown(() {
    try {
      db.close();
    } on Object {
      // A test may already have closed this handle.
    }
  });
  final sourceBytes = <int>[1, 2, 3, 4];
  final stagedBytes = <int>[9, 9, 9];
  final source = File(p.join(root.path, 'source.apkg'))
    ..writeAsBytesSync(sourceBytes);
  File(importRawApkgPath(root.path, batch))
    ..parent.createSync(recursive: true)
    ..writeAsBytesSync(sourceBytes);
  final staged = File(p.join(root.path, 'staged.apkg'))
    ..writeAsBytesSync(stagedBytes);
  final engine = FakeImportEngine(
    deckIds: const {'Spanish': 7},
    newNoteIds: const [20],
  );
  return _Ctx(
    db: db,
    dbPath: dbPath,
    dataDir: root.path,
    collection: FakeCollection(),
    engine: engine,
    source: source,
    staged: staged,
    sourceBytes: sourceBytes,
    sourceSha: sha256.convert(sourceBytes).toString(),
    stagedSha: sha256.convert(stagedBytes).toString(),
  );
}

ImportPipeline _pipeline(
  _Ctx ctx, {
  FutureOr<void> Function(ImportPhase phase)? fault,
  ImportCancellationToken? cancel,
}) {
  return ImportPipeline(
    db: ctx.db,
    anki: ctx.collection,
    engine: ctx.engine,
    dataDir: ctx.dataDir,
    fault: fault,
    cancel: cancel,
  );
}

PreparedPlan _commitPlan(_Ctx ctx) {
  return PreparedPlan(
    batchId: batch,
    stagedPath: ctx.staged.path,
    stagedSha256: ctx.stagedSha,
    firstImport: true,
    newGuids: const [newGuid],
    changed: const {},
    deckNames: const ['Spanish'],
    counts: const ImportPlanCounts(
      newNotes: 1,
      same: 0,
      changed: 0,
      localNewer: 0,
      blocked: 0,
      dup: 0,
      noResidentCall: false,
    ),
  );
}

PreparedPlan _noopPlan(_Ctx ctx) {
  return PreparedPlan(
    batchId: batch,
    stagedPath: ctx.staged.path,
    stagedSha256: ctx.stagedSha,
    firstImport: false,
    newGuids: const [],
    changed: const {},
    deckNames: const ['Spanish'],
    counts: const ImportPlanCounts(
      newNotes: 0,
      same: 1,
      changed: 0,
      localNewer: 0,
      blocked: 0,
      dup: 0,
      noResidentCall: true,
    ),
  );
}

void _ensureRaw(_Ctx ctx) {
  final raw = File(importRawApkgPath(ctx.dataDir, batch));
  raw.parent.createSync(recursive: true);
  raw.writeAsBytesSync(ctx.sourceBytes);
}

void _armNewNote(_Ctx ctx) {
  ctx.engine.onCommit = () {
    ctx.collection.decks = [
      ...ctx.collection.decks,
      const CollectionDeck(id: 7, name: 'Spanish'),
    ];
    ctx.collection.addNote(id: 20, guid: newGuid, cardId: 200, deckId: 7);
    final raw = File(importRawApkgPath(ctx.dataDir, batch));
    raw.parent.createSync(recursive: true);
    raw.writeAsBytesSync(ctx.sourceBytes);
  };
}

void _watchBatches(_Ctx ctx) {
  ctx.engine.onScan = (prepared) {
    for (final name in const ['raw', 'e', 'staged']) {
      final dir = Directory(p.join(ctx.dataDir, 'import', name));
      if (!dir.existsSync()) {
        continue;
      }
      for (final entity in dir.listSync()) {
        final base = p.basename(entity.path);
        final id = base.endsWith('.apkg')
            ? base.substring(0, base.length - 5)
            : base;
        if (prepared.contains(id)) {
          continue;
        }
        if (entity is Directory) {
          entity.deleteSync(recursive: true);
        } else if (entity is File) {
          entity.deleteSync();
        }
      }
    }
  };
}

void _createBatch(_Ctx ctx) {
  File(p.join(ctx.dataDir, 'import', 'raw', '$batch.apkg'))
    ..parent.createSync(recursive: true)
    ..writeAsBytesSync(ctx.sourceBytes);
  Directory(p.join(ctx.dataDir, 'import', 'e', batch))
      .createSync(recursive: true);
  File(p.join(ctx.dataDir, 'import', 'staged', '$batch.apkg'))
    ..parent.createSync(recursive: true)
    ..writeAsBytesSync([9, 9, 9]);
}

void _expectNoBatch(_Ctx ctx, {String? reason}) {
  for (final name in const ['raw', 'e', 'staged']) {
    final dir = Directory(p.join(ctx.dataDir, 'import', name));
    if (!dir.existsSync()) {
      continue;
    }
    expect(dir.listSync(), isEmpty, reason: '${reason ?? ''} $name');
  }
}

Future<void> _startup(SideDb db, _Ctx ctx) {
  return db.exclusive(() async {
    final reconcile = await reconcileInTurn(db: db, anki: ctx.collection);
    await recoverImports(
      db: db,
      anki: ctx.collection,
      engine: ctx.engine,
      reconcile: reconcile,
      dataDir: ctx.dataDir,
    );
    await ctx.engine.scan(preparedBatchIds: preparedImportBatchIds(db));
  });
}

String _dump(SideDb db) {
  final notes = [
    for (final row in db.notes())
      '${row.noteGuid}:${row.rslibNoteId}:${row.homeDeckGuid}',
  ].join('|');
  final decks = [
    for (final row in db.decks())
      '${row.rslibDeckId}:${row.importBatchId}:${row.sourceSha256}:${row.originKind}',
  ].join('|');
  return '$notes#$decks#${db.pendingIntentCount()}#${db.journalRows().length}';
}
