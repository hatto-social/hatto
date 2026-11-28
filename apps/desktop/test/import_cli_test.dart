// SPDX-FileCopyrightText: 2026 Hatto Social contributors
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hatto_desktop/effect/engine_host.dart';
import 'package:hatto_desktop/engine/methods.g.dart';
import 'package:hatto_desktop/src/gen/anki/decks.pb.dart';
import 'package:hatto_store/hatto_store.dart';
import 'package:path/path.dart' as p;
import 'package:rslib_bridge/rslib_bridge.dart';

// Mobile's `apps/mobile/test/import_cli_test.dart` is the same harness.
// Only `_Session` differs: Desktop opens [EngineHost], Mobile opens
// [MobileWriteGateway]. Both compare against `tools/cli-import/expected.json`.

const _timeout = Timeout(Duration(minutes: 10));

/// `HATTO_CARD_BIN`, or null when the variable is unset or empty.
String? get _bin {
  final raw = Platform.environment['HATTO_CARD_BIN'];
  if (raw == null || raw.isEmpty) {
    return null;
  }
  return raw;
}

/// GitHub Actions sets `CI`. An empty value does not count as set.
bool get _ci => (Platform.environment['CI'] ?? '').isNotEmpty;

/// Skip locally when the CLI is not configured. CI must fail instead.
String? get _skipReason {
  if (_bin == null && !_ci) {
    return 'HATTO_CARD_BIN is unset';
  }
  return null;
}

Map<String, dynamic>? _expected;
Directory? _work;
Future<_Built>? _pending;

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    await initRslibBridge();
  });

  tearDownAll(() {
    final work = _work;
    if (work != null && work.existsSync()) {
      work.deleteSync(recursive: true);
    }
  });

  group('hatto-card ImportPipeline', () {
    test('builds the pinned scenarios with hatto-card', () async {
      await _ensureBuilt();
    }, timeout: _timeout);

    test('basic import matches the pinned result', () async {
      await _importOnce('basic');
    }, timeout: _timeout);

    test('cloze import matches the pinned result', () async {
      await _importOnce('cloze');
    }, timeout: _timeout);

    test('media import matches the pinned result', () async {
      await _importOnce('media');
    }, timeout: _timeout);

    test('subdeck import adopts every note and all four decks, then '
        're-import is a noop', () async {
      final built = await _ensureBuilt();
      final scenario = _scenario('subdeck');
      final session = await _Session.open();
      final first = await session.importFile(built.apkg('subdeck'));
      final snap = await session.snapshot();
      _expectPinned(first, snap, _map(scenario['expect']));
      final notesBefore = snap.noteGuids.length;
      final decksBefore = snap.deckNames.length;

      final second = await session.importFile(built.apkg('subdeck'));
      final again = await session.snapshot();
      _expectPinned(second, again, _map(scenario['reimport']));
      expect(again.noteGuids.length, notesBefore, reason: 'note_map rows');
      expect(again.deckNames.length, decksBefore, reason: 'deck_map rows');
    }, timeout: _timeout);

    test('a field edit, a tag edit, and add-note k=7 re-import as '
        'NEW 1 and CHANGED 2', () async {
      final built = await _ensureBuilt();
      final scenario = _scenario('reimport');
      final session = await _Session.open();
      final first = await session.importFile(built.apkg('reimport'));
      final snap = await session.snapshot();
      _expectPinned(first, snap, _map(scenario['expect']));

      final second = await session.importFile(built.apkg('reimport', 1));
      final again = await session.snapshot();
      _expectPinned(second, again, _map(scenario['second']));
      final added = again.noteGuids.toSet().difference(snap.noteGuids.toSet());
      expect(second.plan!.newGuids.toSet(), added, reason: 'new guid');
      expect(added, hasLength(1), reason: 'new guid');
      final changed = second.plan!.changed.keys.toSet();
      expect(changed, hasLength(2), reason: 'changed guids');
      expect(
        snap.noteGuids.toSet().containsAll(changed),
        isTrue,
        reason: 'changed guids were already mapped',
      );
    }, timeout: _timeout);
  }, skip: _skipReason);
}

Future<void> _importOnce(String name) async {
  final built = await _ensureBuilt();
  final session = await _Session.open();
  final result = await session.importFile(built.apkg(name));
  final snap = await session.snapshot();
  _expectPinned(result, snap, _map(_scenario(name)['expect']));
}

void _expectPinned(
  ImportRunResult result,
  _Snapshot snapshot,
  Map<String, dynamic> pinned,
) {
  final plan = result.plan;
  expect(result.outcome.name, pinned['outcome'], reason: '${result.error}');
  if (plan == null) {
    fail('${result.outcome.name} returned no plan: ${result.error}');
  }
  final counts = plan.counts;
  final want = _map(pinned['counts']);
  expect(counts.newNotes, want['newNotes'], reason: 'newNotes');
  expect(counts.same, want['same'], reason: 'same');
  expect(counts.changed, want['changed'], reason: 'changed');
  expect(counts.localNewer, want['localNewer'], reason: 'localNewer');
  expect(counts.blocked, want['blocked'], reason: 'blocked');
  expect(counts.dup, want['dup'], reason: 'dup');
  expect(
    counts.noResidentCall,
    want['noResidentCall'],
    reason: 'noResidentCall',
  );
  final wantGuids = (pinned['noteGuids'] as List<dynamic>).cast<String>();
  final wantDecks = (pinned['deckNames'] as List<dynamic>).cast<String>();
  expect(snapshot.noteGuids.toSet(), wantGuids.toSet(), reason: 'note_map');
  expect(snapshot.noteGuids, hasLength(wantGuids.length), reason: 'note_map');
  expect(snapshot.deckNames.toSet(), wantDecks.toSet(), reason: 'deck_map');
  expect(snapshot.deckNames, hasLength(wantDecks.length), reason: 'deck_map');
}

Map<String, dynamic> _loadExpected() {
  final cached = _expected;
  if (cached != null) {
    return cached;
  }
  final raw = File(p.join(_repoRoot().path, 'tools/cli-import/expected.json'))
      .readAsStringSync();
  final decoded = jsonDecode(raw);
  if (decoded is! Map<String, dynamic>) {
    fail('tools/cli-import/expected.json is not an object');
  }
  _expected = decoded;
  return decoded;
}

Map<String, dynamic> _scenario(String name) {
  final scenarios = _map(_loadExpected()['scenarios']);
  return _map(scenarios[name]);
}

Map<String, dynamic> _map(Object? value) {
  if (value is Map<String, dynamic>) {
    return value;
  }
  if (value is Map) {
    return value.cast<String, dynamic>();
  }
  fail('expected a JSON object, got $value');
}

Directory _repoRoot() {
  var dir = Directory.current.absolute;
  for (var i = 0; i < 8; i++) {
    if (File(p.join(dir.path, 'tools/cli-import/expected.json')).existsSync()) {
      return dir;
    }
    final parent = dir.parent;
    if (parent.path == dir.path) {
      break;
    }
    dir = parent;
  }
  fail('repo root not found from ${Directory.current.path}');
}

Future<_Built> _ensureBuilt() {
  final pending = _pending;
  if (pending != null) {
    return pending;
  }
  final future = _build();
  _pending = future;
  return future;
}

Future<_Built> _build() async {
  final bin = _bin;
  if (bin == null) {
    fail('HATTO_CARD_BIN is unset and CI is set');
  }
  if (!File(bin).existsSync()) {
    fail('HATTO_CARD_BIN is not a file: $bin');
  }
  _work = Directory.systemTemp.createTempSync('hatto-cli-pkg').absolute;
  final scenarios = _map(_loadExpected()['scenarios']);
  final paths = <String, List<String>>{};
  for (final entry in scenarios.entries) {
    final dir = Directory(p.join(_work!.path, entry.key))..createSync();
    paths[entry.key] = await _buildScenario(
      bin,
      dir,
      entry.key,
      _map(entry.value),
    );
  }
  return _Built(paths);
}

Future<List<String>> _buildScenario(
  String bin,
  Directory dir,
  String name,
  Map<String, dynamic> scenario,
) async {
  final deck = File(p.join(dir.path, 'deck.json'));
  await _hatto(bin, [
    'new',
    '--empty',
    '--output',
    deck.path,
    '--deck-name',
    scenario['deck_name'] as String,
    '--notetype',
    scenario['notetype'] as String,
  ]);
  final notes = File(p.join(dir.path, 'notes.jsonl'));
  final lines = (scenario['notes'] as List<dynamic>).map(jsonEncode).join('\n');
  notes.writeAsStringSync('$lines\n');
  await _hatto(bin, [
    'add-notes',
    '--deck',
    deck.path,
    '--input',
    notes.path,
    '--op-id',
    scenario['op_id'] as String,
  ]);
  final pinned = _map(scenario['expect']);
  await _validateGuids(bin, deck.path, pinned['noteGuids'] as List<dynamic>);
  final v1 = File(p.join(dir.path, '$name.apkg'));
  final exportedAt = await _export(bin, deck.path, v1.path);
  await _inspectGuids(bin, v1.path, pinned['noteGuids'] as List<dynamic>);

  final second = scenario['second'];
  if (second is! Map) {
    return [v1.path];
  }
  _applyEdits(deck, scenario['edits'] as List<dynamic>);
  await _addNote(bin, deck.path, _map(scenario['add_note']));
  final pinnedSecond = _map(second);
  await _validateGuids(
    bin,
    deck.path,
    pinnedSecond['noteGuids'] as List<dynamic>,
  );
  // Anki stores note mod in unix seconds. A later export in the same
  // second keeps that mod, and a different hash is then LOCAL_NEWER.
  // v2 waits until the unix second is at least two past v1.
  await _waitForNewerMod(exportedAt);
  final v2 = File(p.join(dir.path, '$name-v2.apkg'));
  await _export(bin, deck.path, v2.path);
  await _inspectGuids(bin, v2.path, pinnedSecond['noteGuids'] as List<dynamic>);
  return [v1.path, v2.path];
}

Future<int> _export(String bin, String deck, String apkg) async {
  await _hatto(bin, ['export', '--deck', deck, '--output', apkg]);
  return DateTime.now().millisecondsSinceEpoch ~/ 1000;
}

Future<void> _waitForNewerMod(int exportedUnixSeconds) async {
  final earliest = exportedUnixSeconds + 2;
  final giveUp = DateTime.now().add(const Duration(seconds: 15));
  while (DateTime.now().millisecondsSinceEpoch ~/ 1000 < earliest) {
    if (DateTime.now().isAfter(giveUp)) {
      fail('clock did not advance two unix seconds after the v1 export');
    }
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
}

void _applyEdits(File deck, List<dynamic> edits) {
  final value = _map(jsonDecode(deck.readAsStringSync()));
  final notes = value['notes'];
  if (notes is! List<dynamic>) {
    fail('deck notes are not a list');
  }
  for (final edit in edits) {
    final change = _map(edit);
    final k = change['k'];
    Map<String, dynamic>? note;
    for (final raw in notes) {
      final row = _map(raw);
      if (row['k'] == k) {
        note = row;
        break;
      }
    }
    if (note == null) {
      fail('deck has no note with k=$k');
    }
    if (change.containsKey('fields')) {
      note['fields'] = change['fields'];
    }
    if (change.containsKey('tags')) {
      note['tags'] = change['tags'];
    }
  }
  deck.writeAsStringSync(
    '${const JsonEncoder.withIndent('  ').convert(value)}\n',
  );
}

Future<void> _addNote(
  String bin,
  String deckPath,
  Map<String, dynamic> spec,
) async {
  final fields = (spec['fields'] as List<dynamic>).cast<String>();
  final tags = (spec['tags'] as List<dynamic>).cast<String>();
  await _hatto(bin, [
    'add-note',
    '--deck',
    deckPath,
    '--notetype',
    spec['notetype'] as String,
    for (final field in fields) ...['--field', field],
    for (final tag in tags) ...['--tag', tag],
    '--op-id',
    spec['op_id'] as String,
    '--k',
    '${spec['k']}',
  ]);
}

Future<void> _validateGuids(String bin, String deck, List<dynamic> want) async {
  final value = await _hatto(bin, ['validate', '--deck', deck]);
  _expectGuids('validate $deck', value['notes'], want);
}

Future<void> _inspectGuids(String bin, String apkg, List<dynamic> want) async {
  final value = await _hatto(bin, ['inspect', apkg]);
  _expectGuids('inspect $apkg', value['notes'], want);
}

void _expectGuids(String label, Object? notes, List<dynamic> want) {
  if (notes is! List<dynamic>) {
    fail('$label notes are not a list');
  }
  final guids = <String>[
    for (final note in notes) _map(note)['guid'] as String,
  ];
  final wanted = want.cast<String>();
  expect(guids.toSet(), wanted.toSet(), reason: label);
  expect(guids, hasLength(wanted.length), reason: label);
}

Future<Map<String, dynamic>> _hatto(String bin, List<String> args) async {
  final result = await Process.run(
    bin,
    ['--json', ...args],
    stdoutEncoding: utf8,
    stderrEncoding: utf8,
  );
  final stdout = result.stdout as String;
  final stderr = result.stderr as String;
  final parsed = _parseJson(stdout);
  if (result.exitCode != 0 ||
      parsed is! Map<String, dynamic> ||
      parsed['ok'] != true) {
    fail(
      'hatto-card ${args.join(' ')} exited ${result.exitCode}\n'
      '$stdout\n$stderr',
    );
  }
  return parsed;
}

Object? _parseJson(String text) {
  try {
    return jsonDecode(text);
  } on FormatException {
    return null;
  }
}

class _Built {
  _Built(this.paths);

  final Map<String, List<String>> paths;

  String apkg(String name, [int index = 0]) {
    final files = paths[name];
    if (files == null || index >= files.length) {
      fail('no apkg for $name at $index');
    }
    return files[index];
  }
}

class _Snapshot {
  const _Snapshot({required this.noteGuids, required this.deckNames});

  final List<String> noteGuids;
  final List<String> deckNames;
}

class _Session {
  _Session(this._host);

  final EngineHost _host;

  static Future<_Session> open() async {
    final dataDir = Directory.systemTemp
        .createTempSync('hatto-cli-desk')
        .absolute;
    addTearDown(() {
      if (dataDir.existsSync()) {
        dataDir.deleteSync(recursive: true);
      }
    });
    final host = EngineHost();
    addTearDown(host.close);
    await host.open(dataDir: dataDir.path);
    return _Session(host);
  }

  Future<ImportRunResult> importFile(String sourcePath) {
    return _host.writes!.importFile(
      sourcePath: sourcePath,
      limits: kImportLimitsV0,
    );
  }

  Future<_Snapshot> snapshot() async {
    final db = _host.sideDb!;
    expect(db.pendingIntentCount(), 0, reason: 'import intent still open');
    // `deck_tree` hides an empty Default once another deck exists. Reconcile
    // mapped Default while it was the only deck, so the name lookup must
    // keep that empty deck. Mobile's deckTree uses this same RPC.
    final listed = await _host.engine!.call(
      Rpcs.getDeckNames,
      GetDeckNamesRequest(skipEmptyDefault: false, includeFiltered: true),
      DeckNames.fromBuffer,
    );
    final byId = <int, String>{
      for (final entry in listed.entries) entry.id.toInt(): entry.name,
    };
    final deckNames = <String>[];
    for (final row in db.decks()) {
      final name = byId[row.rslibDeckId];
      if (name == null) {
        fail(
          'deck_map id ${row.rslibDeckId} has no collection name; '
          'names=${byId.entries.map((e) => '${e.key}:${e.value}').join(', ')}',
        );
      }
      deckNames.add(name);
    }
    return _Snapshot(
      noteGuids: [for (final row in db.notes()) row.noteGuid],
      deckNames: deckNames,
    );
  }
}
