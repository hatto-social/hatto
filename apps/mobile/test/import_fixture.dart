// SPDX-FileCopyrightText: 2026 Hatto Social contributors
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:hatto_mobile/main.dart';
import 'package:hatto_mobile/store/import_engine_mobile.dart';
import 'package:hatto_mobile/store/mobile_anki.dart';
import 'package:hatto_mobile/store/mobile_write_gateway.dart';
import 'package:hatto_mobile/store/pb.dart';
import 'package:hatto_mobile/store/resident_collection.dart';
import 'package:hatto_store/hatto_store.dart';
import 'package:path/path.dart' as p;
import 'package:rslib_bridge/rslib_bridge.dart' as bridge;

import '../integration_test/smoke_support.dart';

/// Ceilings for the checked-in arm64 fixtures. The 37k package is about
/// 1.4 MB compressed.
const fixtureLimits = ImportLimits(
  maxBytes: 20 * 1024 * 1024,
  maxUncompressedBytes: 512 * 1024 * 1024,
);

Directory repoRoot() {
  var dir = Directory.current;
  for (var i = 0; i < 6; i++) {
    if (File(p.join(dir.path, 'tools/arm64-smoke/expected.json'))
        .existsSync()) {
      return dir;
    }
    final parent = dir.parent;
    if (parent.path == dir.path) {
      break;
    }
    dir = parent;
  }
  throw StateError('repo root not found from ${Directory.current.path}');
}

File fixtureFile(String name) {
  final file = File(p.join(repoRoot().path, 'tools/arm64-smoke/files', name));
  if (!file.existsSync()) {
    throw StateError('missing fixture ${file.path}');
  }
  return file;
}

Map<String, dynamic> loadExpected() {
  final raw = File(p.join(repoRoot().path, 'tools/arm64-smoke/expected.json'))
      .readAsStringSync();
  return jsonDecode(raw) as Map<String, dynamic>;
}

List<File> workFiles(String dataDir) {
  final out = <File>[];
  for (final name in const ['raw', 'e', 'staged']) {
    final dir = Directory(p.join(dataDir, 'import', name));
    if (!dir.existsSync()) {
      continue;
    }
    for (final entity in dir.listSync(recursive: true, followLinks: false)) {
      if (entity is File) {
        out.add(entity);
      }
    }
  }
  return out;
}

Future<List<List<Object?>>> query(
  ResidentCollection collection,
  String sql, [
  List<Object?> args = const [],
]) async {
  final raw = await SqlAllowlist.run(
    sql: sql,
    args: args,
    command: (jsonBody) => collection.command(
      service: 'BackendAnkidroidService',
      method: 'run_db_command',
      input: pbJson(jsonBody),
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

Future<int> scalar(
  ResidentCollection collection,
  String sql, [
  List<Object?> args = const [],
]) async {
  final rows = await query(collection, sql, args);
  if (rows.isEmpty || rows.first.isEmpty) {
    throw StateError('no row for [$sql]');
  }
  return asInt(rows.first.first);
}

Future<ColCounts> collectionCounts(ResidentCollection collection) async {
  return ColCounts(
    notes: await scalar(collection, 'select count(*) from notes'),
    cards: await scalar(collection, 'select count(*) from cards'),
    revlogTotal: await scalar(collection, 'select count(*) from revlog'),
    revlogWithCard: await scalar(collection, cardedRevlogSql),
  );
}

Future<ImportRunResult> importWithPipeline({
  required ResidentCollection collection,
  required SideDb side,
  required String dataDir,
  required String sourcePath,
  ImportEngine? engine,
  Future<void> Function(ImportPhase phase)? fault,
}) {
  final gateway = MobileWriteGateway(db: side);
  gateway.attachImport(
    anki: MobileAnkiApi(collection),
    engine:
        engine ??
        MobileImportEngine(backend: collection.backend, dataDir: dataDir),
    dataDir: dataDir,
  );
  return gateway.importFile(
    sourcePath: sourcePath,
    limits: fixtureLimits,
    fault: fault,
  );
}

PreparedPlan requirePlan(ImportRunResult result) {
  final plan = result.plan;
  if (result.outcome != ImportOutcome.committed &&
      result.outcome != ImportOutcome.noop) {
    throw StateError('${result.outcome}: ${result.error}');
  }
  if (plan == null) {
    throw StateError('${result.outcome} returned no plan');
  }
  return plan;
}

Future<void> importCollectionPackage(String colpkgPath, Directory dir) async {
  dir.createSync(recursive: true);
  final media = Directory(p.join(dir.path, 'collection.media'))
    ..createSync(recursive: true);
  final backend = await bridge.openBackend(initMsg: encodeBackendInit());
  try {
    await callBackend(
      backend: backend,
      service: 'BackendImportExportService',
      method: 'import_collection_package',
      input: importCollectionPackageRequest(
        colPath: p.join(dir.path, 'collection.anki2'),
        backupPath: colpkgPath,
        mediaFolder: media.path,
        mediaDb: p.join(dir.path, 'collection.media.db'),
      ),
    );
  } finally {
    try {
      await callBackend(
        backend: backend,
        service: 'BackendCollectionService',
        method: 'close_collection',
        input: Uint8List(0),
      );
    } catch (_) {
      // The package import may already have closed the collection.
    }
    backend.dispose();
  }
}

Future<void> exportWhole(ResidentCollection collection, String outPath) async {
  final raw = await collection.command(
    service: 'BackendImportExportService',
    method: 'export_anki_package',
    input: exportWholeCollectionRequest(outPath),
  );
  if (readVarintField(raw) == 0) {
    throw StateError('export wrote 0 notes to $outPath');
  }
}

/// Replaces every note guid with a fresh lowercase UUID version 4.
Future<List<String>> assignUuidV4Guids(ResidentCollection collection) async {
  final rows = await query(collection, 'select id, guid from notes');
  final guids = <String>[];
  for (final row in rows) {
    final id = asInt(row[0]);
    final note = decodeNote(
      await collection.command(
        service: 'BackendNotesService',
        method: 'get_note',
        input: idMessage(id),
      ),
    );
    final guid = newUuidV4();
    if (!uuidVersion4Or5.hasMatch(guid) || guid[14] != '4') {
      throw StateError('minted guid is not a lowercase UUID version 4');
    }
    note.guid = guid;
    await collection.command(
      service: 'BackendNotesService',
      method: 'update_notes',
      input: updateNotesRequest([note]),
    );
    guids.add(guid);
  }
  if (guids.toSet().length != guids.length) {
    throw StateError('uuid v4 guids collided');
  }
  return guids;
}

Future<void> dropFilteredDecks(ResidentCollection collection) async {
  final ids = (await query(
    collection,
    'select id from decks',
  )).map((row) => asInt(row.first)).toList();
  for (final did in ids) {
    final raw = await collection.command(
      service: 'BackendDecksService',
      method: 'get_deck_legacy',
      input: idMessage(did),
    );
    final decoded = jsonDecode(readJsonString(raw));
    if (decoded is! Map || !isFilteredDeck(decoded['dyn'])) {
      continue;
    }
    await collection.command(
      service: 'BackendSchedulerService',
      method: 'empty_filtered_deck',
      input: idMessage(did),
    );
    await collection.command(
      service: 'BackendDecksService',
      method: 'remove_decks',
      input: deckIdsMessage([did]),
    );
  }
}

Future<void> forceCloneNotetypes(ResidentCollection collection) async {
  final mids = (await query(
    collection,
    'select distinct mid from notes order by mid',
  )).map((row) => asInt(row.first)).toList();
  for (final mid in mids) {
    final legacy = jsonDecode(
      readJsonString(
        await collection.command(
          service: 'BackendNotetypesService',
          method: 'get_notetype_legacy',
          input: idMessage(mid),
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
    final added = await collection.command(
      service: 'BackendNotetypesService',
      method: 'add_notetype_legacy',
      input: pbJson(jsonEncode(copy)),
    );
    final newId = readVarintField(added, number: 2);
    if (newId == 0) {
      throw StateError('add_notetype_legacy returned id 0 for $oldName');
    }
    final noteIds = (await query(
      collection,
      'select id from notes where mid = ?',
      [mid],
    )).map((row) => asInt(row.first)).toList();
    final schema = await scalar(collection, 'select scm from col');
    await collection.command(
      service: 'BackendNotetypesService',
      method: 'change_notetype',
      input: changeNotetypeRequest(
        noteIds: noteIds,
        newFields: [for (var i = 0; i < fields.length; i++) i],
        newTemplates: [for (var i = 0; i < templates.length; i++) i],
        oldNotetypeId: mid,
        newNotetypeId: newId,
        currentSchema: schema,
        oldNotetypeName: oldName,
      ),
    );
    await collection.command(
      service: 'BackendNotetypesService',
      method: 'remove_notetype',
      input: idMessage(mid),
    );
  }
}

Future<List<String>> notetypeNames(ResidentCollection collection) async {
  final raw = await collection.command(
    service: 'BackendNotetypesService',
    method: 'get_notetype_names',
    input: Uint8List(0),
  );
  return readNotetypeNames(raw);
}

class NotetypeJobResult {
  NotetypeJobResult({
    required this.before,
    required this.after,
    required this.newNames,
    required this.newNotes,
    required this.dup,
    required this.guids,
    this.notesPerNotetype,
  });

  final int before;
  final int after;
  final List<String> newNames;
  final int newNotes;
  final int dup;
  final List<String> guids;
  final String? notesPerNotetype;
}

/// Prepares [job] in its own collection, then imports that package into
/// [resident]. [dataDir] and [documents] are fresh for this job and are not
/// the app side database. [resident] is the shared notetype collection.
Future<NotetypeJobResult> runNotetypeJob({
  required Directory root,
  required ResidentCollection resident,
  required String job,
  required bool rewriteGuids,
  required bool forceClone,
  required bool notesPerNotetype,
}) async {
  final source = fixtureFile('stock-notes.apkg');
  final prepDir = Directory(p.join(root.path, 'prep-$job'))..createSync();
  final prepDocs = Directory(p.join(root.path, 'prep-docs-$job'))..createSync();
  final outPath = p.join(root.path, 'nt-$job.apkg');
  final prep = await ResidentCollection.open(prepDir.path);
  final prepSide = openSideDatabase(prepDocs.path);
  List<String> guids;
  try {
    final seeded = await importWithPipeline(
      collection: prep,
      side: prepSide,
      dataDir: prepDir.path,
      sourcePath: source.path,
    );
    requirePlan(seeded);
    if (seeded.outcome != ImportOutcome.committed) {
      throw StateError('prep $job: ${seeded.outcome}');
    }
    guids = rewriteGuids ? await assignUuidV4Guids(prep) : const [];
    await dropFilteredDecks(prep);
    if (forceClone) {
      await forceCloneNotetypes(prep);
    }
    await exportWhole(prep, outPath);
  } finally {
    await prep.close();
    prepSide.close();
  }

  final before = await notetypeNames(resident);
  final dataDir = Directory(p.join(root.path, 'data-$job'))..createSync();
  final docs = Directory(p.join(root.path, 'docs-$job'))..createSync();
  final side = openSideDatabase(docs.path);
  try {
    final imported = await importWithPipeline(
      collection: resident,
      side: side,
      dataDir: dataDir.path,
      sourcePath: outPath,
    );
    final plan = requirePlan(imported);
    if (imported.outcome != ImportOutcome.committed) {
      throw StateError('$job: ${imported.outcome}');
    }
    final after = await notetypeNames(resident);
    String? perType;
    if (notesPerNotetype) {
      final rows = await query(
        resident,
        'select n.name, count(*) from notes x join notetypes n '
        'on n.id = x.mid group by n.name',
      );
      perType = formatNotesPerNotetype([
        for (final row in rows) (name: row[0].toString(), count: asInt(row[1])),
      ]);
    }
    return NotetypeJobResult(
      before: before.length,
      after: after.length,
      newNames: after.where((name) => !before.contains(name)).toList()..sort(),
      newNotes: plan.counts.newNotes,
      dup: plan.counts.dup,
      guids: guids,
      notesPerNotetype: perType,
    );
  } finally {
    side.close();
  }
}
