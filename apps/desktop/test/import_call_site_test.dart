// SPDX-FileCopyrightText: 2026 Hatto Social contributors
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// Rule (a) patterns. A hit outside the import adapters fails the lint.
const _ruleA = <String>[
  'Rpcs.importAnkiPackage',
  "'import_anki_package'",
  '"import_anki_package"',
  'importAnkiPackage',
  'ImportAnkiPackageRequest(',
];

const _adapters = <String>{
  'apps/desktop/lib/store/import_engine_desktop.dart',
  'apps/mobile/lib/store/import_engine_mobile.dart',
};
const _commitOnly = 'packages/hatto_store/lib/src/import_pipeline.dart';

const _roots = <String>[
  'apps/desktop/lib',
  'apps/mobile/lib',
  'apps/mobile/integration_test',
  'packages/hatto_store/lib',
  'packages/rslib_bridge/lib',
];

void main() {
  test('import_anki_package and commitResident have one call site', () {
    final repo = Directory.current.parent.parent;
    expect(importCallSiteViolations(repo), isEmpty);
  });

  test('prepare_runtime is called once per app', () {
    final repo = Directory.current.parent.parent;
    expect(prepareRuntimeCallSites(repo, 'apps/desktop'), [
      'apps/desktop/lib/main.dart',
    ]);
    expect(prepareRuntimeCallSites(repo, 'apps/mobile'), [
      'apps/mobile/lib/main.dart',
    ]);
  });

  test('a violating file fails both import call-site rules', () {
    final root = Directory.systemTemp.createTempSync('hatto-import-lint');
    addTearDown(() => root.deleteSync(recursive: true));
    final ruleA = File(p.join(root.path, 'apps/desktop/lib/sneak_a.dart'))
      ..createSync(recursive: true)
      ..writeAsStringSync(
        "final rpc = Rpcs.importAnkiPackage;\n"
        "const name = 'import_anki_package';\n"
        'const other = "import_anki_package";\n'
        'void sneak() => importAnkiPackage();\n'
        'final req = ImportAnkiPackageRequest();\n',
      );
    final ruleB =
        File(p.join(root.path, 'packages/hatto_store/lib/sneak_b.dart'))
          ..createSync(recursive: true)
          ..writeAsStringSync('engine.commitResident(stagedPath: path);\n');

    final violations = importCallSiteViolations(root, files: [ruleA, ruleB]);
    expect(
      violations.where((hit) => hit.startsWith('a ')).map((hit) {
        return hit.split(' ')[1];
      }).toSet(),
      _ruleA.toSet(),
    );
    expect(violations.where((hit) => hit.startsWith('b ')), isNotEmpty);
  });

  test('an extra prepare_runtime call fails the lint', () {
    final root = Directory.systemTemp.createTempSync('hatto-prep-lint');
    addTearDown(() => root.deleteSync(recursive: true));
    File(p.join(root.path, 'apps/desktop/lib/main.dart'))
      ..createSync(recursive: true)
      ..writeAsStringSync('prepareRuntime(tmpDir: cache.path);\n');
    File(p.join(root.path, 'apps/desktop/lib/extra.dart'))
        .writeAsStringSync('prepareRuntime(tmpDir: other.path);\n');

    expect(prepareRuntimeCallSites(root, 'apps/desktop'), [
      'apps/desktop/lib/main.dart',
      'apps/desktop/lib/extra.dart',
    ]);
  });
}

class _Hit {
  _Hit(this.rule, this.pattern, this.path);

  final String rule;
  final String pattern;
  final String path;

  @override
  String toString() => '$rule $pattern $path';
}

List<String> importCallSiteViolations(Directory repo, {List<File>? files}) {
  final scanned = files ?? _dartFiles(repo);
  final hits = <_Hit>[];
  for (final file in scanned) {
    final relative = p
        .relative(file.path, from: repo.path)
        .replaceAll('\\', '/');
    if (_skipped(relative)) {
      continue;
    }
    var text = file.readAsStringSync();
    if (relative == 'apps/desktop/lib/engine/engine.dart') {
      text = _withoutDesktopServices(text);
    }
    if (text.contains('.commitResident(') && relative != _commitOnly) {
      hits.add(_Hit('b', '.commitResident(', relative));
    }
    if (_adapters.contains(relative)) {
      continue;
    }
    for (final pattern in _ruleA) {
      if (pattern.allMatches(text).isEmpty) {
        continue;
      }
      hits.add(_Hit('a', pattern, relative));
    }
  }
  return [for (final hit in hits) hit.toString()];
}

List<String> prepareRuntimeCallSites(Directory repo, String app) {
  final lib = Directory(p.join(repo.path, app, 'lib'));
  final hits = <String>[];
  for (final file in lib.listSync(recursive: true).whereType<File>()) {
    if (!file.path.endsWith('.dart')) {
      continue;
    }
    final text = file.readAsStringSync();
    final count =
        'prepareRuntime('.allMatches(text).length +
        'prepare_runtime('.allMatches(text).length;
    if (count == 0) {
      continue;
    }
    final relative = p
        .relative(file.path, from: repo.path)
        .replaceAll('\\', '/');
    for (var i = 0; i < count; i++) {
      hits.add(relative);
    }
  }
  return hits;
}

List<File> _dartFiles(Directory repo) {
  final out = <File>[];
  for (final root in _roots) {
    final dir = Directory(p.join(repo.path, root));
    if (!dir.existsSync()) {
      continue;
    }
    for (final entity in dir.listSync(recursive: true)) {
      if (entity is File && entity.path.endsWith('.dart')) {
        out.add(entity);
      }
    }
  }
  return out;
}

bool _skipped(String relative) {
  if (relative.contains('/src/gen/')) {
    return true;
  }
  return relative.endsWith('/methods.g.dart') ||
      relative.endsWith('/frb_generated.dart');
}

String _withoutDesktopServices(String source) {
  const mark = 'const desktopServices';
  final start = source.indexOf(mark);
  if (start < 0) {
    return source;
  }
  final end = source.indexOf('};', start);
  if (end < 0) {
    return source;
  }
  return source.replaceRange(start, end + 2, '');
}
