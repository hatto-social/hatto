// SPDX-FileCopyrightText: 2026 Hatto Social contributors
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:convert';

import 'schema.dart';

/// `expected` JSON for an import intent row.
///
/// Field names and encode order are fixed. `changed` and `pre.changed` are
/// stored in ascending guid order so the encoded bytes do not depend on
/// insertion order. Hash fields are 64 lowercase hex characters.
/// `pre.changed` has the same keys as [changed]. Recovery uses every field
/// except [pre]. [pre] is checked here and then ignored.
class ImportIntentExpected {
  ImportIntentExpected({
    required this.sourceSha256,
    required this.stagedSha256,
    required this.firstImport,
    required List<String> newGuids,
    required Map<String, String> changed,
    required List<String> deckNames,
    required this.pre,
  }) : newGuids = List<String>.unmodifiable(newGuids),
       changed = _sortedHashes(changed),
       deckNames = List<String>.unmodifiable(deckNames) {
    _checkHash(sourceSha256, 'source_sha256');
    _checkHash(stagedSha256, 'staged_sha256');
    _checkNames(this.newGuids, 'new_guids');
    _checkNames(this.deckNames, 'deck_names');
    _checkHashes(this.changed, 'changed');
    if (!_sameKeys(this.changed, pre.changed)) {
      throw const SideDbException('pre.changed keys must match changed keys');
    }
  }

  /// Original `.apkg` digest, stored when the intent row is inserted.
  final String sourceSha256;

  /// Digest of the staged package. Schema v1 has no column for it.
  final String stagedSha256;

  final bool firstImport;

  final List<String> newGuids;

  /// Guid to the file content hash the resident import should land.
  final Map<String, String> changed;

  final List<String> deckNames;

  /// Diagnostic snapshot. Recovery does not read this.
  final ImportIntentPre pre;

  @override
  bool operator ==(Object other) {
    return other is ImportIntentExpected &&
        sourceSha256 == other.sourceSha256 &&
        stagedSha256 == other.stagedSha256 &&
        firstImport == other.firstImport &&
        _listEq(newGuids, other.newGuids) &&
        _mapEq(changed, other.changed) &&
        _listEq(deckNames, other.deckNames) &&
        pre == other.pre;
  }

  @override
  int get hashCode => Object.hash(
    sourceSha256,
    stagedSha256,
    firstImport,
    Object.hashAll(newGuids),
    Object.hashAll([
      for (final entry in changed.entries) Object.hash(entry.key, entry.value),
    ]),
    Object.hashAll(deckNames),
    pre,
  );
}

/// `pre` object on an import intent. Diagnostic only.
class ImportIntentPre {
  ImportIntentPre({
    required this.noteCount,
    required Map<String, String> changed,
  }) : changed = _sortedHashes(changed) {
    // Dart's int is signed 64-bit, so every non-negative value fits in 64
    // bits. A JSON number above 2^63-1 decodes as a double and is rejected.
    if (noteCount < 0) {
      throw const SideDbException(
        'pre.note_count must be a non-negative 64-bit integer',
      );
    }
    _checkHashes(this.changed, 'pre.changed');
  }

  final int noteCount;

  /// Guid to the resident content hash from before the import.
  final Map<String, String> changed;

  @override
  bool operator ==(Object other) {
    return other is ImportIntentPre &&
        noteCount == other.noteCount &&
        _mapEq(changed, other.changed);
  }

  @override
  int get hashCode => Object.hash(
    noteCount,
    Object.hashAll([
      for (final entry in changed.entries) Object.hash(entry.key, entry.value),
    ]),
  );
}

/// Encodes [expected] with a fixed key order and sorted hash maps.
String encodeImportIntentExpected(ImportIntentExpected expected) {
  return jsonEncode(<String, Object?>{
    'source_sha256': expected.sourceSha256,
    'staged_sha256': expected.stagedSha256,
    'first_import': expected.firstImport,
    'new_guids': expected.newGuids,
    'changed': expected.changed,
    'deck_names': expected.deckNames,
    'pre': <String, Object?>{
      'note_count': expected.pre.noteCount,
      'changed': expected.pre.changed,
    },
  });
}

/// Decodes [raw]. Unknown fields, bad hashes, and a `pre.changed` key set
/// that differs from `changed` throw [SideDbException].
ImportIntentExpected decodeImportIntentExpected(String raw) {
  final Object? decoded;
  try {
    decoded = jsonDecode(raw);
  } on FormatException catch (err) {
    throw SideDbException('import intent expected is not JSON: $err');
  }
  if (decoded is! Map) {
    throw const SideDbException('import intent expected must be a JSON object');
  }
  final object = Map<String, Object?>.from(decoded);
  _exactKeys(object, _expectedKeys, 'import intent expected');
  final preRaw = object['pre'];
  if (preRaw is! Map) {
    throw const SideDbException('import intent pre must be a JSON object');
  }
  final preObject = Map<String, Object?>.from(preRaw);
  _exactKeys(preObject, _preKeys, 'import intent pre');
  final firstImport = object['first_import'];
  if (firstImport is! bool) {
    throw const SideDbException('first_import must be a boolean');
  }
  return ImportIntentExpected(
    sourceSha256: _hashField(object['source_sha256'], 'source_sha256'),
    stagedSha256: _hashField(object['staged_sha256'], 'staged_sha256'),
    firstImport: firstImport,
    newGuids: _stringList(object['new_guids'], 'new_guids'),
    changed: _hashObject(object['changed'], 'changed'),
    deckNames: _stringList(object['deck_names'], 'deck_names'),
    pre: ImportIntentPre(
      noteCount: _noteCount(preObject['note_count']),
      changed: _hashObject(preObject['changed'], 'pre.changed'),
    ),
  );
}

/// [decodeImportIntentExpected], or null when [raw] is empty or invalid.
///
/// Reconcile uses this so one bad import row does not abort the pass.
ImportIntentExpected? tryDecodeImportIntentExpected(String? raw) {
  if (raw == null || raw.isEmpty) {
    return null;
  }
  try {
    return decodeImportIntentExpected(raw);
  } on SideDbException {
    return null;
  }
}

const List<String> _expectedKeys = <String>[
  'source_sha256',
  'staged_sha256',
  'first_import',
  'new_guids',
  'changed',
  'deck_names',
  'pre',
];

const List<String> _preKeys = <String>['note_count', 'changed'];

void _exactKeys(Map<String, Object?> object, List<String> keys, String what) {
  if (object.length != keys.length || !object.keys.toSet().containsAll(keys)) {
    throw SideDbException('$what fields must be ${keys.join(', ')}');
  }
}

int _noteCount(Object? value) {
  if (value is! int || value < 0) {
    throw const SideDbException(
      'pre.note_count must be a non-negative 64-bit integer',
    );
  }
  return value;
}

String _hashField(Object? value, String field) {
  if (value is! String) {
    throw SideDbException('$field must be 64 lowercase hex characters');
  }
  _checkHash(value, field);
  return value;
}

void _checkHash(String value, String field) {
  if (!sha256Hex.hasMatch(value)) {
    throw SideDbException('$field must be 64 lowercase hex characters');
  }
}

List<String> _stringList(Object? value, String field) {
  if (value is! List) {
    throw SideDbException('$field must be a list');
  }
  final out = <String>[];
  for (final item in value) {
    if (item is! String || item.isEmpty) {
      throw SideDbException('$field entries must be non-empty strings');
    }
    out.add(item);
  }
  return out;
}

void _checkNames(List<String> names, String field) {
  for (final name in names) {
    if (name.isEmpty) {
      throw SideDbException('$field entries must be non-empty strings');
    }
  }
}

Map<String, String> _hashObject(Object? value, String field) {
  if (value is! Map) {
    throw SideDbException('$field must be an object');
  }
  final out = <String, String>{};
  for (final entry in value.entries) {
    final key = entry.key;
    if (key is! String || key.isEmpty) {
      throw SideDbException('$field keys must be non-empty strings');
    }
    final hash = entry.value;
    if (hash is! String) {
      throw SideDbException(
        '$field values must be 64 lowercase hex characters',
      );
    }
    _checkHash(hash, field);
    out[key] = hash;
  }
  return out;
}

void _checkHashes(Map<String, String> hashes, String field) {
  for (final entry in hashes.entries) {
    if (entry.key.isEmpty) {
      throw SideDbException('$field keys must be non-empty strings');
    }
    _checkHash(entry.value, field);
  }
}

Map<String, String> _sortedHashes(Map<String, String> hashes) {
  final keys = hashes.keys.toList()..sort();
  return Map<String, String>.unmodifiable({
    for (final key in keys) key: hashes[key]!,
  });
}

bool _sameKeys(Map<String, String> a, Map<String, String> b) {
  if (a.length != b.length) {
    return false;
  }
  for (final key in a.keys) {
    if (!b.containsKey(key)) {
      return false;
    }
  }
  return true;
}

bool _listEq(List<String> a, List<String> b) {
  if (a.length != b.length) {
    return false;
  }
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) {
      return false;
    }
  }
  return true;
}

bool _mapEq(Map<String, String> a, Map<String, String> b) {
  if (a.length != b.length) {
    return false;
  }
  for (final key in a.keys) {
    if (a[key] != b[key]) {
      return false;
    }
  }
  return true;
}
