// SPDX-FileCopyrightText: 2026 Hatto Social contributors
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hatto_mobile/main.dart';
import 'package:hatto_mobile/store/import_engine_mobile.dart';
import 'package:hatto_mobile/store/mobile_anki.dart';
import 'package:hatto_mobile/store/mobile_startup.dart';
import 'package:hatto_mobile/store/mobile_write_gateway.dart';
import 'package:hatto_mobile/store/resident_collection.dart';
import 'package:hatto_store/hatto_store.dart';
import 'package:path/path.dart' as p;
import 'package:rslib_bridge/rslib_bridge.dart' hide ProtoResponse;

import '../integration_test/smoke_flow.dart';
import '../integration_test/smoke_support.dart';
import 'import_fixture.dart';

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    await initRslibBridge();
    final tmp = await Directory.systemTemp.createTemp('hatto-fixture-tmp');
    addTearDown(() => tmp.delete(recursive: true));
    prepareRuntime(tmpDir: tmp.path);
  });

  test('colpkg variants match the staged-E golden counts', () async {
    final expected = loadExpected()['colpkg'] as Map<String, dynamic>;
    for (final name in colpkgNames) {
      final row = expected[name] as Map<String, dynamic>;
      final counts = await _colpkgRoundTrip(name);
      _expectCounts(counts.extracted, row['E_after_colpkg_import']);
      _expectCounts(counts.resident, row['R_after_apkg_import']);
    }
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('fsrs synthetic 37k matches the golden import and fit', () async {
    final fsrs = loadExpected()['fsrs_synthetic'] as Map<String, dynamic>;
    final want = fsrs['R_after_apkg_import'] as Map<String, dynamic>;
    final root = await Directory.systemTemp.createTemp('hatto-fsrs');
    addTearDown(() => root.delete(recursive: true));
    final residentDir = Directory(p.join(root.path, 'resident'))..createSync();
    final docs = Directory(p.join(root.path, 'documents'))..createSync();
    final collection = await ResidentCollection.open(residentDir.path);
    addTearDown(collection.close);
    final side = openSideDatabase(docs.path);
    addTearDown(side.close);
    final result = await importWithPipeline(
      collection: collection,
      side: side,
      dataDir: residentDir.path,
      sourcePath: fixtureFile(fsrsPackageName).path,
    );
    expect(result.outcome, ImportOutcome.committed);
    expect(requirePlan(result).counts.newNotes, fsrs['import_new_notes']);
    final counts = await collectionCounts(collection);
    _expectCounts(counts, want);

    final beforeCol = await query(
      collection,
      'select crt, mod, scm, usn from col',
    );
    final beforeConfig = await query(
      collection,
      'select count(*), sum(length(val)) from config',
    );
    final first = await _fsrs(collection);
    final second = await _fsrs(collection);
    final afterCol = await query(
      collection,
      'select crt, mod, scm, usn from col',
    );
    final afterConfig = await query(
      collection,
      'select count(*), sum(length(val)) from config',
    );
    // Staged-E fit. Direct import of this package trains 33312 items; the
    // staged package trains 33109. expected.json holds the staged number.
    expect(first.items, fsrs['fsrs_items']);
    expect(first.params, hasLength(fsrs['n_params']));
    expect(fsrsValuesFinite(first.params), isTrue);
    expect(
      fsrsRunsMatch(
        itemsA: first.items,
        paramsA: first.params,
        itemsB: second.items,
        paramsB: second.params,
      ),
      isTrue,
    );
    expect(sameSqlRows(beforeCol, afterCol), isTrue);
    expect(sameSqlRows(beforeConfig, afterConfig), isTrue);
    final golden = (fsrs['params'] as List<dynamic>)
        .map((value) => (value as num).toDouble())
        .toList();
    expect(first.params, hasLength(golden.length));
    for (var i = 0; i < golden.length; i++) {
      expect(
        (first.params[i] - golden[i]).abs(),
        lessThan(5e-7),
        reason: 'param $i ${first.params[i]} vs ${golden[i]}',
      );
    }
  }, timeout: const Timeout(Duration(minutes: 10)));

  test('nt jobs keep the golden notetype counts', () async {
    final root = await Directory.systemTemp.createTemp('hatto-nt');
    addTearDown(() => root.delete(recursive: true));
    final residentDir = Directory(p.join(root.path, 'resident'))..createSync();
    final resident = await ResidentCollection.open(residentDir.path);
    addTearDown(resident.close);
    final notetype = loadExpected()['notetype'] as Map<String, dynamic>;
    final jobs = await _notetypeJobs(root, resident);
    for (final spec in const [
      ('job1', 'job1_default'),
      ('job2', 'job2_default'),
      ('job3', 'job3_forced'),
    ]) {
      final got = jobs[spec.$1]!;
      final want = notetype[spec.$2] as Map<String, dynamic>;
      expect(got.before, want['notetypes_before'], reason: spec.$1);
      expect(got.after, want['notetypes_after'], reason: spec.$1);
      expect(
        got.newNames,
        (want['new_notetype_names'] as List<dynamic>).cast<String>(),
        reason: spec.$1,
      );
      expect(got.newNotes, want['new_notes'], reason: spec.$1);
      expect(got.dup, want['duplicate_notes'], reason: spec.$1);
    }
    final job2 = jobs['job2']!.guids;
    final job3 = jobs['job3']!.guids;
    expect(job2, isNotEmpty);
    expect(job3, isNotEmpty);
    expect(job2.toSet().intersection(job3.toSet()), isEmpty);
    for (final guid in [...job2, ...job3]) {
      expect(
        uuidVersion4Or5.hasMatch(guid) && guid[14] == '4',
        isTrue,
        reason: guid,
      );
    }
    final pairs = (notetype['notes_per_notetype_after'] as List<dynamic>)
        .map(
          (pair) => (
            name: (pair as List<dynamic>)[0] as String,
            count: pair[1] as int,
          ),
        )
        .toList();
    expect(jobs['job3']!.notesPerNotetype, formatNotesPerNotetype(pairs));
  }, timeout: const Timeout(Duration(minutes: 8)));

  test(
    'T15 a second import is a noop and does not call commitResident',
    () async {
      final root = await Directory.systemTemp.createTemp('hatto-t15');
      addTearDown(() => root.delete(recursive: true));
      final residentDir = Directory(p.join(root.path, 'resident'))
        ..createSync();
      final docs = Directory(p.join(root.path, 'documents'))..createSync();
      final source = fixtureFile('stock-notes.apkg');
      final collection = await ResidentCollection.open(residentDir.path);
      addTearDown(collection.close);
      final side = openSideDatabase(docs.path);
      var sideClosed = false;
      addTearDown(() {
        if (!sideClosed) {
          side.close();
        }
      });
      final counter = _CountingEngine(
        MobileImportEngine(
          backend: collection.backend,
          dataDir: residentDir.path,
        ),
      );
      final gateway = MobileWriteGateway(db: side);
      gateway.attachImport(
        anki: MobileAnkiApi(collection),
        engine: counter,
        dataDir: residentDir.path,
      );

      final first = await gateway.importFile(
        sourcePath: source.path,
        limits: fixtureLimits,
      );
      expect(first.outcome, ImportOutcome.committed);
      expect(counter.commitResidentCalls, 1);
      final notes = await scalar(collection, 'select count(*) from notes');
      final cards = await scalar(collection, 'select count(*) from cards');
      final revlog = await scalar(collection, 'select count(*) from revlog');
      final mappedNotes = side.notes().length;
      final mappedDecks = side.decks().length;
      expect(mappedNotes, notes);
      expect(mappedNotes, greaterThan(0));
      expect(mappedDecks, greaterThan(0));
      expect(side.pendingIntentCount(), 0);
      expect(workFiles(residentDir.path), isEmpty);
      final archive = File(
        importArchivePath(residentDir.path, sha256OfFile(source)),
      );
      expect(archive.existsSync(), isTrue);
      expect(archive.readAsBytesSync(), source.readAsBytesSync());
      final sideFile = File(sideDbPath(docs.path));
      expect(
        p.canonicalize(sideFile.path),
        isNot(p.canonicalize(archive.path)),
      );
      expect(p.basename(sideFile.path), 'hatto.sqlite');
      expect(p.basename(archive.parent.path), 'imports');
      expect(p.isWithin(archive.parent.path, sideFile.path), isFalse);

      final before = await query(
        collection,
        'select crt, mod, scm, usn from col',
      );
      final second = await gateway.importFile(
        sourcePath: source.path,
        limits: fixtureLimits,
      );
      expect(second.outcome, ImportOutcome.noop);
      expect(counter.commitResidentCalls, 1);
      expect(requirePlan(second).counts.noResidentCall, isTrue);
      expect(await scalar(collection, 'select count(*) from notes'), notes);
      expect(await scalar(collection, 'select count(*) from cards'), cards);
      expect(await scalar(collection, 'select count(*) from revlog'), revlog);
      expect(
        sameSqlRows(
          before,
          await query(collection, 'select crt, mod, scm, usn from col'),
        ),
        isTrue,
      );
      expect(side.notes(), hasLength(mappedNotes));
      expect(side.decks(), hasLength(mappedDecks));
      expect(side.pendingIntentCount(), 0);
      expect(workFiles(residentDir.path), isEmpty);
      expect(archive.readAsBytesSync(), source.readAsBytesSync());
      await collection.close();
      side.close();
      sideClosed = true;

      File(
          p.join(
            residentDir.path,
            'import',
            'raw',
            '33333333-3333-4333-8333-333333333333.apkg',
          ),
        )
        ..createSync(recursive: true)
        ..writeAsBytesSync(const [1]);
      final startup = await openResidentAndRecover(
        documentsDirectory: docs.path,
        residentDirectory: residentDir.path,
      );
      expect(startup.startupError, isNull);
      expect(archive.readAsBytesSync(), source.readAsBytesSync());
      expect(workFiles(residentDir.path), isEmpty);
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}

class _CountingEngine implements ImportEngine {
  _CountingEngine(this.inner);

  final ImportEngine inner;
  int commitResidentCalls = 0;

  @override
  Future<StagedImport> stageE({
    required String sourcePath,
    required ImportLimits limits,
  }) {
    return inner.stageE(sourcePath: sourcePath, limits: limits);
  }

  @override
  Future<ResidentMatchResult> residentLookup({
    required List<int> noteIds,
    required List<String> deckNames,
  }) {
    return inner.residentLookup(noteIds: noteIds, deckNames: deckNames);
  }

  @override
  Future<PreparedPlan> finish({
    required StagedImport staged,
    required List<ResidentNoteFacts> residentFacts,
    required List<String> foundDeckNames,
  }) {
    return inner.finish(
      staged: staged,
      residentFacts: residentFacts,
      foundDeckNames: foundDeckNames,
    );
  }

  @override
  Future<ImportScan> scan({required List<String> preparedBatchIds}) {
    return inner.scan(preparedBatchIds: preparedBatchIds);
  }

  @override
  Future<int> notetypeUseCountSum() => inner.notetypeUseCountSum();

  @override
  Future<ResidentImportResult> commitResident({
    required String stagedPath,
    required bool firstImport,
  }) {
    commitResidentCalls += 1;
    return inner.commitResident(
      stagedPath: stagedPath,
      firstImport: firstImport,
    );
  }

  @override
  Future<int?> deckIdByName(String name) => inner.deckIdByName(name);
}

class _RoundTrip {
  _RoundTrip(this.extracted, this.resident);

  final ColCounts extracted;
  final ColCounts resident;
}

Future<_RoundTrip> _colpkgRoundTrip(String filename) async {
  final root = await Directory.systemTemp.createTemp('hatto-colpkg');
  addTearDown(() => root.delete(recursive: true));
  final extractedDir = Directory(p.join(root.path, 'E'));
  await importCollectionPackage(fixtureFile(filename).path, extractedDir);
  final apkg = p.join(root.path, 'out.apkg');
  final extractedCol = await ResidentCollection.open(extractedDir.path);
  final ColCounts extracted;
  try {
    extracted = await collectionCounts(extractedCol);
    await exportWhole(extractedCol, apkg);
  } finally {
    await extractedCol.close();
  }
  final residentDir = Directory(p.join(root.path, 'R'))..createSync();
  final docs = Directory(p.join(root.path, 'docs'))..createSync();
  final resident = await ResidentCollection.open(residentDir.path);
  final side = openSideDatabase(docs.path);
  try {
    final result = await importWithPipeline(
      collection: resident,
      side: side,
      dataDir: residentDir.path,
      sourcePath: apkg,
    );
    expect(result.outcome, ImportOutcome.committed);
    return _RoundTrip(extracted, await collectionCounts(resident));
  } finally {
    await resident.close();
    side.close();
  }
}

void _expectCounts(ColCounts got, Object? raw) {
  final want = raw as Map<String, dynamic>;
  expect(got.notes, want['notes']);
  expect(got.cards, want['cards']);
  expect(got.revlogTotal, want['revlog_total']);
  expect(got.revlogWithCard, want['revlog_with_card']);
}

Future<FsrsParams> _fsrs(ResidentCollection collection) async {
  final raw = await collection.command(
    service: 'BackendSchedulerService',
    method: 'compute_fsrs_params',
    input: computeFsrsRequest(),
  );
  return readFsrsResponse(raw);
}

Future<Map<String, NotetypeJobResult>> _notetypeJobs(
  Directory root,
  ResidentCollection resident,
) async {
  final out = <String, NotetypeJobResult>{};
  const jobs = <(String, bool, bool, bool)>[
    ('job1', false, false, false),
    ('job2', true, false, false),
    ('job3', true, true, true),
  ];
  for (final (job, rewrite, force, perType) in jobs) {
    out[job] = await runNotetypeJob(
      root: root,
      resident: resident,
      job: job,
      rewriteGuids: rewrite,
      forceClone: force,
      notesPerNotetype: perType,
    );
  }
  return out;
}
