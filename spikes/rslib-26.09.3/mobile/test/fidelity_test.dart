import 'dart:convert';
import 'dart:io';

import 'package:fixnum/fixnum.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hatto_rslib_spike/gen_proto/anki/collection.pb.dart';
import 'package:hatto_rslib_spike/gen_proto/anki/generic.pb.dart' as generic;
import 'package:hatto_rslib_spike/gen_proto/anki/import_export.pb.dart';
import 'package:hatto_rslib_spike/gen_proto/anki/notes.pb.dart';
import 'package:hatto_rslib_spike/gen_proto/anki/notetypes.pb.dart';
import 'package:hatto_rslib_spike/gen_proto/anki/search.pb.dart';
import 'package:hatto_rslib_spike/src/byte_backend.dart';
import 'package:hatto_rslib_spike/src/frb_backend.dart';
import 'package:hatto_rslib_spike/src/roundtrip_flow.dart';
import 'package:protobuf/protobuf.dart';

/// Host FRB half of the fidelity spike. Reads originals produced by
/// `napi/test/fidelity.mjs` and re-exports them through flutter_rust_bridge.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('FRB re-exports the napi fixtures and applies app-side edits', () async {
    final library = Platform.environment['HATTO_RSLIB_LIB'];
    final work = Platform.environment['HATTO_FIDELITY_DIR'];
    final spike = Platform.environment['HATTO_SPIKE_ROOT'];
    expect(library, isNotNull);
    expect(work, isNotNull);
    expect(spike, isNotNull);
    await initFrb(library!);
    await setTempDir(work!);
    final ids = ServiceIds.parse(File('$spike/napi/service-ids.json').readAsStringSync());
    final originals = Directory('$work/originals');
    final outDir = Directory('$work/frb-round')..createSync(recursive: true);
    final rounds = <Map<String, dynamic>>[];
    for (final entity in originals.listSync().whereType<File>()) {
      if (!entity.path.endsWith('.apkg')) continue;
      final name = entity.uri.pathSegments.last;
      final exported = File('${outDir.path}/$name');
      final col = Directory('$work/frb-cols/${name.replaceAll('.apkg', '')}')..createSync(recursive: true);
      final backend = await FrbByteBackend.open(backendInit().writeToBuffer());
      try {
        await _open(backend, ids, col);
        await _call(
          backend,
          ids,
          'backend_import_export_service',
          'import_anki_package',
          ImportAnkiPackageRequest(
            packagePath: entity.path,
            options: ImportAnkiPackageOptions(withScheduling: false, withDeckConfigs: false),
          ),
        );
        await _call(
          backend,
          ids,
          'backend_import_export_service',
          'export_anki_package',
          ExportAnkiPackageRequest(
            outPath: exported.path,
            options: ExportAnkiPackageOptions(withScheduling: false, withDeckConfigs: false, withMedia: true),
            limit: ExportLimit(wholeCollection: generic.Empty()),
          ),
        );
      } finally {
        await _close(backend, ids);
      }
      final diff = _compare(spike!, entity.path, exported.path);
      rounds.add({'apkg': name, 'summary': _summarize(diff)});
      // ignore: avoid_print
      print('FRB ${diff['notes']['dst']}/${diff['notes']['src']} $name');
    }

    final manifest = await _mutate(work, spike!, ids);
    File('$work/frb-fidelity.json').writeAsStringSync(jsonEncode({'rounds': rounds, 'manifest': manifest}));
    expect(rounds, isNotEmpty);
    final rich = rounds.cast<Map<String, dynamic>>().firstWhere((row) => row['apkg'] == 'rich-with-scheduling.apkg');
    expect(rich['summary']['fieldMismatch'], 0);
    expect(rich['summary']['revlog']['dst'], 0);
  });
}

Future<Map<String, dynamic>> _mutate(String work, String spike, ServiceIds ids) async {
  final col = Directory('$work/frb-app')..createSync(recursive: true);
  final backend = await FrbByteBackend.open(backendInit().writeToBuffer());
  final manifest = <String, dynamic>{};
  try {
    await _open(backend, ids, col);
    await _call(
      backend,
      ids,
      'backend_import_export_service',
      'import_anki_package',
      ImportAnkiPackageRequest(
        packagePath: '$work/originals/rich-with-scheduling.apkg',
        options: ImportAnkiPackageOptions(withScheduling: false, withDeckConfigs: false),
      ),
    );
    final notes = await _notes(backend, ids);
    final editable = notes.firstWhere((note) => note.fields.isNotEmpty && note.fields.first == 'hello');
    await Future<void>.delayed(const Duration(milliseconds: 1100));
    editable.fields[0] = 'hello-from-frb';
    editable.tags
      ..clear()
      ..addAll(['from-frb', 'renamed']);
    await _call(
      backend,
      ids,
      'backend_notes_service',
      'update_notes',
      UpdateNotesRequest(notes: [editable], skipUndoEntry: false),
    );
    final basicId = NotetypeId.fromBuffer(
      await _call(
        backend,
        ids,
        'backend_notetypes_service',
        'get_notetype_id_by_name',
        generic.String(val: 'Basic'),
      ),
    );
    final fresh = Note.fromBuffer(
      await _call(backend, ids, 'backend_notes_service', 'new_note', basicId),
    );
    fresh.fields
      ..clear()
      ..addAll(['added-on-frb', 'yes']);
    fresh.tags.add('added');
    fresh.id = Int64.ZERO;
    final added = AddNoteResponse.fromBuffer(
      await _call(
        backend,
        ids,
        'backend_notes_service',
        'add_note',
        AddNoteRequest(note: fresh, deckId: Int64(1)),
      ),
    );
    final addedNote = Note.fromBuffer(
      await _call(backend, ids, 'backend_notes_service', 'get_note', NoteId(nid: added.noteId)),
    );
    final victim = notes.cast<Note?>().firstWhere(
          (note) => note!.fields.isNotEmpty && note.fields.first == 'odd-guid',
          orElse: () => null,
        );
    if (victim != null) {
      await _call(
        backend,
        ids,
        'backend_notes_service',
        'remove_notes',
        RemoveNotesRequest(noteIds: [victim.id]),
      );
    }
    manifest['editedGuid'] = editable.guid;
    manifest['addedGuid'] = addedNote.guid;
    manifest['deletedGuid'] = victim?.guid;
    await _call(
      backend,
      ids,
      'backend_import_export_service',
      'export_anki_package',
      ExportAnkiPackageRequest(
        outPath: '$work/app-frb-changed.apkg',
        options: ExportAnkiPackageOptions(withScheduling: false, withDeckConfigs: false, withMedia: true),
        limit: ExportLimit(wholeCollection: generic.Empty()),
      ),
    );
  } finally {
    await _close(backend, ids);
  }
  File('$work/frb-manifest.json').writeAsStringSync(jsonEncode(manifest));
  // ignore: avoid_print
  print('FRB_MANIFEST ${jsonEncode(manifest)}');
  return manifest;
}

Future<List<Note>> _notes(ByteBackend backend, ServiceIds ids) async {
  final found = SearchResponse.fromBuffer(
    await _call(
      backend,
      ids,
      'backend_search_service',
      'search_notes',
      SearchRequest(search: 'deck:*'),
    ),
  );
  final notes = <Note>[];
  for (final nid in found.ids) {
    notes.add(Note.fromBuffer(await _call(backend, ids, 'backend_notes_service', 'get_note', NoteId(nid: nid))));
  }
  return notes;
}

Future<void> _open(ByteBackend backend, ServiceIds ids, Directory dir) async {
  await Directory('${dir.path}/media').create(recursive: true);
  await _call(
    backend,
    ids,
    'backend_collection_service',
    'open_collection',
    OpenCollectionRequest(
      collectionPath: '${dir.path}/collection.anki2',
      mediaFolderPath: '${dir.path}/media',
      mediaDbPath: '${dir.path}/media.mdb',
    ),
  );
}

Future<void> _close(ByteBackend backend, ServiceIds ids) async {
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

Future<List<int>> _call(
  ByteBackend backend,
  ServiceIds ids,
  String service,
  String method,
  GeneratedMessage message,
) {
  final spec = ids.services[service]!;
  return backend.run(spec.index, spec.methods[method]!, message.writeToBuffer());
}

Map<String, dynamic> _compare(String spike, String src, String dst) {
  final snap = '$spike/scripts/fidelity_snapshot.py';
  final cmp = '$spike/scripts/fidelity_compare.py';
  final a = Process.runSync('python3', [snap, src]);
  final b = Process.runSync('python3', [snap, dst]);
  if (a.exitCode != 0 || b.exitCode != 0) {
    throw StateError('${a.stderr}${b.stderr}');
  }
  final dir = Directory.systemTemp.createTempSync('hatto-frb-cmp');
  File('${dir.path}/a.json').writeAsStringSync(a.stdout as String);
  File('${dir.path}/b.json').writeAsStringSync(b.stdout as String);
  final diff = Process.runSync('python3', [cmp, '${dir.path}/a.json', '${dir.path}/b.json']);
  if (diff.exitCode != 0) throw StateError(diff.stderr as String);
  return jsonDecode(diff.stdout as String) as Map<String, dynamic>;
}

Map<String, dynamic> _summarize(Map<String, dynamic> diff) {
  final notes = diff['notes'] as Map<String, dynamic>;
  final cards = diff['cards'] as Map<String, dynamic>;
  return {
    'notes': '${notes['dst']}/${notes['src']}',
    'fieldMismatch': (notes['field_mismatch'] as List).length,
    'tagMismatch': (notes['tag_mismatch'] as List).length,
    'missing': notes['missing_guids'],
    'noteIdChanged': (notes['id_changed'] as List).length,
    'mtimeChanged': (notes['mtime_changed'] as List).length,
    'usnChanged': (notes['usn_changed'] as List).length,
    'csumChanged': (notes['csum_changed'] as List).length,
    'scheduleDiffs': (cards['schedule_or_state_diff'] as List).length,
    'cardDeckChanged': (cards['deck_id_changed'] as List).length,
    'notetypeMissing': diff['notetypes']['missing'],
    'notetypeExtra': diff['notetypes']['extra'],
    'deckIdChanged': (diff['decks']['id_changed'] as List).length,
    'mediaMissing': diff['media']['missing'],
    'revlog': diff['revlog'],
  };
}
