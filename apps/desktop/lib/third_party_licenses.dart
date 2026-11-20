// SPDX-FileCopyrightText: 2026 Hatto Social contributors
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

const rustLicensesAsset = 'assets/licenses/rust-crates.json';
const materialIconsLicenseAsset = 'assets/licenses/material-icons.json';
const flutterSdkLicenseAsset = 'assets/licenses/flutter-sdk.json';

bool _registered = false;

/// Loads the committed desktop notices as license entries.
Future<List<LicenseEntryWithLineBreaks>> loadBundledLicenseEntries() async {
  final rust = await rootBundle.loadString(rustLicensesAsset);
  final material = await rootBundle.loadString(materialIconsLicenseAsset);
  final flutterSdk = await rootBundle.loadString(flutterSdkLicenseAsset);
  return [
    ..._entriesFromDocument(jsonDecode(rust)),
    ..._entriesFromDocument(jsonDecode(material)),
    ..._entriesFromDocument(jsonDecode(flutterSdk)),
  ];
}

/// Registers the bundled notices once, beside Flutter's own notices.
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
