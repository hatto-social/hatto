// SPDX-FileCopyrightText: 2026 Hatto Social contributors
//
// SPDX-License-Identifier: AGPL-3.0-or-later

// Device smoke for colpkg round-trip, one FSRS fit, and notetype cloning.
//
// Every collection call goes through rslib_bridge (`openBackend` + `command`),
// which is `init_backend` and `Backend::run_service_method`. rslib 26.09.3 is
// not patched. Counts use `BackendAnkidroidService.run_db_command` on that
// same channel, after `SqlAllowlist.run` accepts the statement and pins
// `kind` to `query`. The pass/fail decision is judge.py, not this file: revlog
// *total* is printed and then ignored, because orphan revlog rows dropped by
// apkg export are an accepted loss. The judged revlog number is
// `count(*) from revlog where cid in (select id from cards)`.
//
// palace.colpkg is not used for the FSRS judgment. The host fit on that file
// returned zero parameters.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:hatto_store/hatto_store.dart';
import 'package:path/path.dart' as p;
import 'package:rslib_bridge/rslib_bridge.dart';

import 'smoke_support.dart';

const colpkgNames = <String>[
  'palace.colpkg',
  'collection.colpkg',
  'collection_nomedia_new.colpkg',
];

const fsrsPackageName = 'fsrs-synthetic-37k.apkg';
const stockNotesName = 'stock-notes.apkg';

Future<void> runArm64Smoke(String smokeDirPath) async {
  final smokeDir = Directory(smokeDirPath);
  if (!smokeDir.existsSync()) {
    throw StateError('SMOKE_DIR does not exist: $smokeDirPath');
  }
  await initRslibBridge();
  final tmp = Directory(p.join(smokeDir.path, 'tmp'))
    ..createSync(recursive: true);
  await prepareRuntime(tmpDir: tmp.path);
  final work = Directory(p.join(smokeDir.path, 'work'))
    ..createSync(recursive: true);

  for (final name in colpkgNames) {
    await _step('col:$name', () => _colpkgRoundTrip(smokeDir, work, name));
  }
  await _step('fsrs', () => _fsrs(smokeDir, work));
  await _step('nt', () => _notetypeJobs(smokeDir, work));
}

Future<void> _step(String step, Future<void> Function() body) async {
  try {
    await body();
  } catch (err) {
    smokeLog('HATTO_SMOKE_FAIL $step $err');
    rethrow;
  }
}

void smokeLog(String line) {
  // ignore: avoid_print
  print(line);
}

File _fixture(Directory dir, String name) {
  final file = File(p.join(dir.path, name));
  if (!file.existsSync()) {
    throw StateError('missing fixture ${file.path}');
  }
  return file;
}

class _Collection {
  _Collection(this.backend);

  final AnkiBackend backend;

  Future<List<List<Object?>>> q(
    String sql, [
    List<Object?> args = const [],
  ]) async {
    final raw = await SqlAllowlist.run(
      sql: sql,
      args: args,
      command: (jsonBody) => _invoke(
        backend,
        'BackendAnkidroidService',
        'run_db_command',
        pbJson(jsonBody),
      ),
    );
    final decoded = jsonDecode(readJsonString(raw));
    if (decoded == null) {
      return const [];
    }
    if (decoded is! List) {
      throw StateError('db result for [$sql] is ${decoded.runtimeType}');
    }
    return decoded.map((row) {
      if (row is! List) {
        throw StateError('db row for [$sql] is ${row.runtimeType}');
      }
      return row.cast<Object?>();
    }).toList();
  }

  Future<int> scalar(String sql, [List<Object?> args = const []]) async {
    final rows = await q(sql, args);
    if (rows.isEmpty || rows.first.isEmpty) {
      throw StateError('no row for [$sql]');
    }
    return asInt(rows.first.first);
  }
}

Future<Uint8List> _invoke(
  AnkiBackend backend,
  String service,
  String method,
  Uint8List input,
) async {
  final index = serviceMethodIndex(service: service, method: method);
  if (index == null) {
    throw StateError('no protobuf index for $service.$method');
  }
  final response = await command(
    backend: backend,
    service: index.service,
    method: index.method,
    input: input,
  );
  if (!response.success) {
    throw StateError(
      '$service.$method failed: ${describeBackendError(response.payload)}',
    );
  }
  return response.payload;
}

Future<T> _withCollection<T>(
  Directory dir,
  Future<T> Function(_Collection col) body,
) async {
  final media = Directory(p.join(dir.path, 'media'))
    ..createSync(recursive: true);
  final backend = await openBackend(initMsg: backendInit());
  var opened = false;
  try {
    await _invoke(
      backend,
      'BackendCollectionService',
      'open_collection',
      openCollectionRequest(
        collectionPath: p.join(dir.path, 'collection.anki2'),
        mediaFolderPath: media.path,
        mediaDbPath: p.join(dir.path, 'media.db'),
      ),
    );
    opened = true;
    return await body(_Collection(backend));
  } finally {
    if (opened) {
      try {
        await _invoke(
          backend,
          'BackendCollectionService',
          'close_collection',
          Uint8List(0),
        );
      } catch (_) {
        // The collection call already failed or finished. Closing is best-effort
        // so the next collection can take the file.
      }
    }
  }
}

Future<void> _importCollectionPackage(String colpkgPath, Directory dir) async {
  dir.createSync(recursive: true);
  final media = Directory(p.join(dir.path, 'media'))
    ..createSync(recursive: true);
  final backend = await openBackend(initMsg: backendInit());
  await _invoke(
    backend,
    'BackendImportExportService',
    'import_collection_package',
    importCollectionPackageRequest(
      colPath: p.join(dir.path, 'collection.anki2'),
      backupPath: colpkgPath,
      mediaFolder: media.path,
      mediaDb: p.join(dir.path, 'media.db'),
    ),
  );
}

Future<void> _exportWhole(_Collection col, String outPath) async {
  final raw = await _invoke(
    col.backend,
    'BackendImportExportService',
    'export_anki_package',
    exportWholeCollectionRequest(outPath),
  );
  if (readVarintField(raw) == 0) {
    throw StateError('export wrote 0 notes to $outPath');
  }
}

Future<ImportCounts> _importApkg(_Collection col, String packagePath) async {
  final raw = await _invoke(
    col.backend,
    'BackendImportExportService',
    'import_anki_package',
    importAnkiPackageRequest(packagePath),
  );
  return readImportCounts(raw);
}

Future<ColCounts> _counts(_Collection col) async {
  return ColCounts(
    notes: await col.scalar('select count(*) from notes'),
    cards: await col.scalar('select count(*) from cards'),
    revlogTotal: await col.scalar('select count(*) from revlog'),
    revlogWithCard: await col.scalar(cardedRevlogSql),
  );
}

Future<void> _colpkgRoundTrip(
  Directory smokeDir,
  Directory work,
  String filename,
) async {
  final source = _fixture(smokeDir, filename);
  final stem = p.basenameWithoutExtension(filename);
  final extractedDir = Directory(p.join(work.path, '$stem-E'));
  await _importCollectionPackage(source.path, extractedDir);
  final apkgPath = p.join(work.path, '$stem.apkg');
  final extracted = await _withCollection(extractedDir, (col) async {
    final counts = await _counts(col);
    await _exportWhole(col, apkgPath);
    return counts;
  });
  final residentDir = Directory(p.join(work.path, '$stem-R'))
    ..createSync(recursive: true);
  final resident = await _withCollection(residentDir, (col) async {
    await _importApkg(col, apkgPath);
    return _counts(col);
  });
  smokeLog(formatColLine(filename, extracted, resident));
}

Future<void> _fsrs(Directory smokeDir, Directory work) async {
  final source = _fixture(smokeDir, fsrsPackageName);
  final dir = Directory(p.join(work.path, 'fsrs-R'))
    ..createSync(recursive: true);
  await _withCollection(dir, (col) async {
    await _importApkg(col, source.path);
    final counts = await _counts(col);
    final beforeCol = await col.q('select crt, mod, scm, usn from col');
    final beforeConfig = await col.q(
      'select count(*), sum(length(val)) from config',
    );
    final watch = Stopwatch()..start();
    final first = await _computeFsrs(col);
    final seconds = watch.elapsedMicroseconds / 1e6;
    final second = await _computeFsrs(col);
    final afterCol = await col.q('select crt, mod, scm, usn from col');
    final afterConfig = await col.q(
      'select count(*), sum(length(val)) from config',
    );
    smokeLog(
      formatFsrsLine(
        importNotes: counts.notes,
        importCards: counts.cards,
        importRevlog: counts.revlogTotal,
        fsrsItems: first.items,
        params: first.params,
        secondIdentical: fsrsRunsMatch(
          itemsA: first.items,
          paramsA: first.params,
          itemsB: second.items,
          paramsB: second.params,
        ),
        colUnchanged: sameSqlRows(beforeCol, afterCol),
        configUnchanged: sameSqlRows(beforeConfig, afterConfig),
        seconds: seconds,
      ),
    );
  });
}

Future<FsrsParams> _computeFsrs(_Collection col) async {
  final raw = await _invoke(
    col.backend,
    'BackendSchedulerService',
    'compute_fsrs_params',
    computeFsrsRequest(),
  );
  return readFsrsResponse(raw);
}

Future<void> _notetypeJobs(Directory smokeDir, Directory work) async {
  final source = _fixture(smokeDir, stockNotesName);
  final residentDir = Directory(p.join(work.path, 'nt-R'))
    ..createSync(recursive: true);
  await _withCollection(residentDir, (resident) async {
    const jobs = <(String, bool)>[
      ('job1', false),
      ('job2', false),
      ('job3', true),
    ];
    for (final (job, force) in jobs) {
      final before = await _notetypeNames(resident);
      final exported = await _prepareJob(work, source.path, job, force);
      final imported = await _importApkg(resident, exported);
      final after = await _notetypeNames(resident);
      final newNames = after.where((name) => !before.contains(name)).toList();
      String? perType;
      if (force) {
        perType = await _notesPerNotetype(resident);
      }
      smokeLog(
        formatNotetypeLine(
          job: job,
          before: before.length,
          after: after.length,
          newNames: newNames,
          newNotes: imported.created,
          duplicates: imported.duplicate,
          notesPerNotetype: perType,
        ),
      );
    }
  });
}

Future<List<String>> _notetypeNames(_Collection col) async {
  final raw = await _invoke(
    col.backend,
    'BackendNotetypesService',
    'get_notetype_names',
    Uint8List(0),
  );
  return readNotetypeNames(raw);
}

Future<String> _notesPerNotetype(_Collection col) async {
  final rows = await col.q(
    'select n.name, count(*) from notes x join notetypes n on n.id = x.mid group by n.name',
  );
  final parsed = rows
      .map((row) => (name: row[0].toString(), count: asInt(row[1])))
      .toList();
  return formatNotesPerNotetype(parsed);
}

Future<String> _prepareJob(
  Directory work,
  String apkgPath,
  String job,
  bool force,
) async {
  final dir = Directory(p.join(work.path, 'nt-E-$job'))
    ..createSync(recursive: true);
  final outPath = p.join(work.path, 'nt-$job.apkg');
  await _withCollection(dir, (col) async {
    await _importApkg(col, apkgPath);
    await _rewriteGuids(col, job);
    await _dropFilteredDecks(col);
    if (force) {
      await _forceCloneNotetypes(col);
    }
    await _exportWhole(col, outPath);
  });
  return outPath;
}

Future<void> _rewriteGuids(_Collection col, String job) async {
  // Fixed job id from the shared golden file. The old
  // uuid5(NAMESPACE_URL, 'smoke:'+job) namespace is not an app rule.
  final jobId = smokeJobId(job);
  final rows = await col.q('select id, guid from notes');
  for (final row in rows) {
    final id = asInt(row[0]);
    final guid = row[1];
    if (guid is! String) {
      throw StateError('note $id guid is ${guid.runtimeType}');
    }
    final note = decodeNote(
      await _invoke(
        col.backend,
        'BackendNotesService',
        'get_note',
        idMessage(id),
      ),
    );
    note.guid = importedNoteGuid(jobId: jobId, sourceGuid: guid);
    await _invoke(
      col.backend,
      'BackendNotesService',
      'update_notes',
      updateNotesRequest([note]),
    );
  }
}

Future<void> _dropFilteredDecks(_Collection col) async {
  final ids = (await col.q('select id from decks'))
      .map((row) => asInt(row.first))
      .toList();
  for (final did in ids) {
    final raw = await _invoke(
      col.backend,
      'BackendDecksService',
      'get_deck_legacy',
      idMessage(did),
    );
    final decoded = jsonDecode(readJsonString(raw));
    if (decoded is! Map || !isFilteredDeck(decoded['dyn'])) {
      continue;
    }
    await _invoke(
      col.backend,
      'BackendSchedulerService',
      'empty_filtered_deck',
      idMessage(did),
    );
    await _invoke(
      col.backend,
      'BackendDecksService',
      'remove_decks',
      deckIdsMessage([did]),
    );
  }
}

Future<void> _forceCloneNotetypes(_Collection col) async {
  final mids = (await col.q('select distinct mid from notes order by mid'))
      .map((row) => asInt(row.first))
      .toList();
  for (final mid in mids) {
    final legacy = jsonDecode(
      readJsonString(
        await _invoke(
          col.backend,
          'BackendNotetypesService',
          'get_notetype_legacy',
          idMessage(mid),
        ),
      ),
    );
    if (legacy is! Map) {
      throw StateError('notetype $mid legacy JSON is ${legacy.runtimeType}');
    }
    final copy = jsonDecode(jsonEncode(legacy)) as Map<String, dynamic>;
    final oldName = copy['name'];
    final fields = copy['flds'];
    final templates = copy['tmpls'];
    if (oldName is! String || fields is! List || templates is! List) {
      throw StateError('notetype $mid is missing name, flds, or tmpls');
    }
    copy['id'] = 0;
    final added = await _invoke(
      col.backend,
      'BackendNotetypesService',
      'add_notetype_legacy',
      pbJson(jsonEncode(copy)),
    );
    final newId = readVarintField(added, number: 2);
    if (newId == 0) {
      throw StateError('add_notetype_legacy returned id 0 for $oldName');
    }
    final noteIds = (await col.q('select id from notes where mid = ?', [
      mid,
    ])).map((row) => asInt(row.first)).toList();
    final schema = await col.scalar('select scm from col');
    await _invoke(
      col.backend,
      'BackendNotetypesService',
      'change_notetype',
      changeNotetypeRequest(
        noteIds: noteIds,
        newFields: [for (var i = 0; i < fields.length; i++) i],
        newTemplates: [for (var i = 0; i < templates.length; i++) i],
        oldNotetypeId: mid,
        newNotetypeId: newId,
        currentSchema: schema,
        oldNotetypeName: oldName,
      ),
    );
    await _invoke(
      col.backend,
      'BackendNotetypesService',
      'remove_notetype',
      idMessage(mid),
    );
  }
}
