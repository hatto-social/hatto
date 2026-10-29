import 'dart:convert';
import 'dart:io';

import 'package:fixnum/fixnum.dart';
import 'package:flutter/services.dart';
import 'package:hatto_rslib_spike/gen_proto/anki/backend.pb.dart';
import 'package:hatto_rslib_spike/gen_proto/anki/cards.pb.dart';
import 'package:hatto_rslib_spike/gen_proto/anki/collection.pb.dart';
import 'package:hatto_rslib_spike/gen_proto/anki/decks.pb.dart';
import 'package:hatto_rslib_spike/gen_proto/anki/generic.pb.dart' as generic;
import 'package:hatto_rslib_spike/gen_proto/anki/import_export.pb.dart';
import 'package:hatto_rslib_spike/gen_proto/anki/notes.pb.dart';
import 'package:hatto_rslib_spike/gen_proto/anki/notetypes.pb.dart';
import 'package:hatto_rslib_spike/gen_proto/anki/scheduler.pb.dart';
import 'package:hatto_rslib_spike/gen_proto/anki/search.pb.dart';
import 'package:hatto_rslib_spike/src/byte_backend.dart';
import 'package:protobuf/protobuf.dart';

typedef BackendOpener = Future<ByteBackend> Function(Uint8List init);

class ServiceIds {
  ServiceIds(this.services);
  final Map<String, ({int index, Map<String, int> methods})> services;

  static Future<ServiceIds> loadAsset() async {
    final raw = await rootBundle.loadString('assets/service-ids.json');
    return ServiceIds.parse(raw);
  }

  static ServiceIds parse(String raw) {
    final json = jsonDecode(raw) as Map<String, dynamic>;
    final services = <String, ({int index, Map<String, int> methods})>{};
    for (final entry in (json['services'] as Map<String, dynamic>).entries) {
      final value = entry.value as Map<String, dynamic>;
      services[entry.key] = (
        index: value['index'] as int,
        methods: (value['methods'] as Map<String, dynamic>).map(
          (key, method) => MapEntry(key, method as int),
        ),
      );
    }
    return ServiceIds(services);
  }
}

class RoundtripReport {
  final List<String> fields;
  final int strippedRevlog;
  final int keptRevlog;
  final int importedStrippedReps;
  final int importedKeptReps;
  final int answeredReps;

  const RoundtripReport({
    required this.fields,
    required this.strippedRevlog,
    required this.keptRevlog,
    required this.importedStrippedReps,
    required this.importedKeptReps,
    required this.answeredReps,
  });
}

Future<RoundtripReport> runRoundtrip({
  required Directory work,
  required BackendOpener openBackend,
  String? inspectScript,
}) async {
  final ids = await ServiceIds.loadAsset();
  final init = backendInit().writeToBuffer();
  Future<T> withCol<T>(String name, Future<T> Function(ByteBackend backend) body) async {
    final backend = await openBackend(init);
    try {
      await _openCollection(backend, ids, Directory('${work.path}/$name'));
      return await body(backend);
    } finally {
      try {
        await _call(
          backend,
          ids,
          'backend_collection_service',
          'close_collection',
          CloseCollectionRequest()..downgradeToSchema11 = false,
        );
      } catch (_) {}
      await backend.close();
    }
  }

  final apkg = File('${work.path}/round.apkg');
  // ignore: avoid_print
  print('HATTO_STEP export-source');
  await withCol('src', (backend) async {
    await _addBasic(backend, ids, 'hello', 'world');
    await _addBasic(backend, ids, 'alpha', 'beta');
    await _export(backend, ids, apkg.path, withScheduling: false);
  });
  // ignore: avoid_print
  print('HATTO_STEP import-roundtrip');
  final fields = await withCol('dst', (backend) async {
    final response = ImportResponse.fromBuffer(
      await _call(
        backend,
        ids,
        'backend_import_export_service',
        'import_anki_package',
        ImportAnkiPackageRequest(
          packagePath: apkg.path,
          options: ImportAnkiPackageOptions(withScheduling: false, withDeckConfigs: false),
        ),
      ),
    );
    if (response.log.new_1.length != 2) {
      throw StateError('expected 2 new notes, got ${response.log.new_1.length}');
    }
    return _noteFields(backend, ids);
  });
  fields.sort();
  if (fields.join('|') != 'alpha / beta|hello / world') {
    throw StateError('fields $fields');
  }

  final withFile = File('${work.path}/with.apkg');
  final withoutFile = File('${work.path}/without.apkg');
  // ignore: avoid_print
  print('HATTO_STEP study-and-export');
  final answeredReps = await withCol('study', (backend) async {
    await _addBasic(backend, ids, 'study', 'card');
    final reps = await _answerGood(backend, ids);
    await _export(backend, ids, withFile.path, withScheduling: true, withDeckConfigs: true);
    await _export(backend, ids, withoutFile.path, withScheduling: false, withDeckConfigs: false);
    return reps;
  });

  var strippedRevlog = -1;
  var keptRevlog = -1;
  if (inspectScript != null && File(inspectScript).existsSync()) {
    strippedRevlog = _inspect(inspectScript, withoutFile.path)['revlog_count'] as int;
    keptRevlog = _inspect(inspectScript, withFile.path)['revlog_count'] as int;
    if (strippedRevlog != 0) {
      throw StateError('export with_scheduling=false revlog=$strippedRevlog');
    }
    if (keptRevlog < 1) {
      throw StateError('export with_scheduling=true revlog=$keptRevlog');
    }
  }

  // ignore: avoid_print
  print('HATTO_STEP import-without-scheduling');
  final importedStrippedReps = await withCol('import-stripped', (backend) async {
    await _call(
      backend,
      ids,
      'backend_import_export_service',
      'import_anki_package',
      ImportAnkiPackageRequest(
        packagePath: withFile.path,
        options: ImportAnkiPackageOptions(withScheduling: false, withDeckConfigs: false),
      ),
    );
    return (await _firstCard(backend, ids)).reps;
  });
  if (importedStrippedReps != 0) {
    throw StateError('import with_scheduling=false reps=$importedStrippedReps');
  }

  // ignore: avoid_print
  print('HATTO_STEP import-with-scheduling');
  final importedKeptReps = await withCol('import-kept', (backend) async {
    await _call(
      backend,
      ids,
      'backend_import_export_service',
      'import_anki_package',
      ImportAnkiPackageRequest(
        packagePath: withFile.path,
        options: ImportAnkiPackageOptions(withScheduling: true, withDeckConfigs: true),
      ),
    );
    return (await _firstCard(backend, ids)).reps;
  });
  if (importedKeptReps != answeredReps) {
    throw StateError('kept reps $importedKeptReps != answered $answeredReps');
  }

  return RoundtripReport(
    fields: fields,
    strippedRevlog: strippedRevlog,
    keptRevlog: keptRevlog,
    importedStrippedReps: importedStrippedReps,
    importedKeptReps: importedKeptReps,
    answeredReps: answeredReps,
  );
}

generic.Empty _empty() => generic.Empty();

BackendInit backendInit() {
  return BackendInit(preferredLangs: ['en'], server: true);
}

Future<Uint8List> _call(
  ByteBackend backend,
  ServiceIds ids,
  String service,
  String method,
  GeneratedMessage message,
) async {
  final spec = ids.services[service];
  if (spec == null) throw StateError('missing service $service');
  final methodIndex = spec.methods[method];
  if (methodIndex == null) throw StateError('missing method $service.$method');
  return backend.run(spec.index, methodIndex, Uint8List.fromList(message.writeToBuffer()));
}

Future<void> _openCollection(ByteBackend backend, ServiceIds ids, Directory dir) async {
  await dir.create(recursive: true);
  final media = Directory('${dir.path}/media')..createSync(recursive: true);
  await _call(
    backend,
    ids,
    'backend_collection_service',
    'open_collection',
    OpenCollectionRequest(
      collectionPath: '${dir.path}/collection.anki2',
      mediaFolderPath: media.path,
      mediaDbPath: '${dir.path}/media.mdb',
    ),
  );
}

Future<void> _addBasic(ByteBackend backend, ServiceIds ids, String front, String back) async {
  final notetype = NotetypeId.fromBuffer(
    await _call(
      backend,
      ids,
      'backend_notetypes_service',
      'get_notetype_id_by_name',
      generic.String(val: 'Basic'),
    ),
  );
  final note = Note.fromBuffer(
    await _call(backend, ids, 'backend_notes_service', 'new_note', notetype),
  );
  note.fields
    ..clear()
    ..addAll([front, back]);
  note.id = Int64.ZERO;
  await _call(
    backend,
    ids,
    'backend_notes_service',
    'add_note',
    AddNoteRequest(note: note, deckId: Int64(1)),
  );
}

Future<void> _export(
  ByteBackend backend,
  ServiceIds ids,
  String outPath, {
  required bool withScheduling,
  bool withDeckConfigs = false,
}) async {
  final count = generic.UInt32.fromBuffer(
    await _call(
      backend,
      ids,
      'backend_import_export_service',
      'export_anki_package',
      ExportAnkiPackageRequest(
        outPath: outPath,
        options: ExportAnkiPackageOptions(
          withScheduling: withScheduling,
          withDeckConfigs: withDeckConfigs,
          withMedia: false,
          legacy: false,
        ),
        limit: ExportLimit(wholeCollection: _empty()),
      ),
    ),
  );
  if (count.val == 0) throw StateError('export wrote 0 notes to $outPath');
}

Future<List<String>> _noteFields(ByteBackend backend, ServiceIds ids) async {
  final idsFound = SearchResponse.fromBuffer(
    await _call(
      backend,
      ids,
      'backend_search_service',
      'search_notes',
      SearchRequest(search: 'deck:Default'),
    ),
  ).ids;
  final fields = <String>[];
  for (final nid in idsFound) {
    final note = Note.fromBuffer(
      await _call(backend, ids, 'backend_notes_service', 'get_note', NoteId(nid: nid)),
    );
    fields.add(note.fields.join(' / '));
  }
  return fields;
}

Future<int> _answerGood(ByteBackend backend, ServiceIds ids) async {
  await _call(
    backend,
    ids,
    'backend_decks_service',
    'set_current_deck',
    DeckId(did: Int64(1)),
  );
  final queued = QueuedCards.fromBuffer(
    await _call(
      backend,
      ids,
      'backend_scheduler_service',
      'get_queued_cards',
      GetQueuedCardsRequest(fetchLimit: 1),
    ),
  );
  if (queued.cards.isEmpty) throw StateError('queue empty');
  final card = queued.cards.first;
  await _call(
    backend,
    ids,
    'backend_scheduler_service',
    'answer_card',
    CardAnswer(
      cardId: card.card.id,
      currentState: card.states.current,
      newState: card.states.good,
      rating: CardAnswer_Rating.GOOD,
      answeredAtMillis: Int64(DateTime.now().millisecondsSinceEpoch),
      millisecondsTaken: 400,
    ),
  );
  return (await _firstCard(backend, ids)).reps;
}

Future<Card> _firstCard(ByteBackend backend, ServiceIds ids) async {
  final found = SearchResponse.fromBuffer(
    await _call(
      backend,
      ids,
      'backend_search_service',
      'search_cards',
      SearchRequest(search: 'deck:Default'),
    ),
  ).ids;
  if (found.isEmpty) throw StateError('no cards');
  return Card.fromBuffer(
    await _call(backend, ids, 'backend_cards_service', 'get_card', CardId(cid: found.first)),
  );
}

Map<String, dynamic> _inspect(String script, String apkg) {
  final run = Process.runSync('python3', [script, apkg]);
  if (run.exitCode != 0) {
    throw StateError('inspect failed: ${run.stderr}');
  }
  return jsonDecode(run.stdout as String) as Map<String, dynamic>;
}
