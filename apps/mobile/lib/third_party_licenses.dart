// SPDX-FileCopyrightText: 2026 Hatto Social contributors
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

const rustLicensesAsset = 'assets/licenses/rust-crates.json';
const androidLicensesAsset = 'assets/licenses/android-deps.json';
const materialIconsLicenseAsset = 'assets/licenses/material-icons.json';

bool _registered = false;

/// Loads the committed Rust and Gradle notices as license entries.
///
/// Anki path crates are one entry whose text is the Anki notice, not a
/// third-party license dump. Flutter's own notices stay on [LicenseRegistry]
/// and are not in these assets.
Future<List<LicenseEntryWithLineBreaks>> loadBundledLicenseEntries() async {
  final rust = await rootBundle.loadString(rustLicensesAsset);
  final android = await rootBundle.loadString(androidLicensesAsset);
  final material = await rootBundle.loadString(materialIconsLicenseAsset);
  return [
    ..._entriesFromDocument(jsonDecode(rust)),
    ..._entriesFromDocument(jsonDecode(android)),
    ..._entriesFromDocument(jsonDecode(material)),
  ];
}

/// Registers the bundled notices once, so [LicenseRegistry] shows them beside
/// Flutter's own notices.
Future<void> registerBundledLicenses() async {
  if (_registered) {
    return;
  }
  _registered = true;
  final entries = await loadBundledLicenseEntries();
  LicenseRegistry.addLicense(() async* {
    yield* Stream<LicenseEntry>.fromIterable(entries);
  });
}

List<LicenseEntryWithLineBreaks> _entriesFromDocument(Object? decoded) {
  if (decoded is! Map<String, Object?>) {
    throw const FormatException('license asset is not a JSON object');
  }
  final entries = <LicenseEntryWithLineBreaks>[];
  final anki = decoded['anki'];
  if (anki is Map<String, Object?>) {
    entries.add(_entryFromMap(anki));
  }
  final listed = decoded['entries'];
  if (listed is! List<Object?>) {
    throw const FormatException('license asset is missing entries');
  }
  for (final item in listed) {
    if (item is! Map<String, Object?>) {
      throw const FormatException('license entry is not an object');
    }
    entries.add(_entryFromMap(item));
  }
  return entries;
}

LicenseEntryWithLineBreaks _entryFromMap(Map<String, Object?> entry) {
  final packages = entry['packages'];
  final text = entry['text'];
  if (packages is! List<Object?> || text is! String || text.isEmpty) {
    throw const FormatException('license entry is missing packages or text');
  }
  return LicenseEntryWithLineBreaks([
    for (final package in packages) package as String,
  ], text);
}
