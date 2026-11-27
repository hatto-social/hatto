// SPDX-FileCopyrightText: 2026 Hatto Social contributors
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';
import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hatto_desktop/editor/anki_ui.dart';
import 'package:hatto_desktop/effect/apkg_import.dart';
import 'package:hatto_desktop/state/app_controller.dart';
import 'package:hatto_desktop/ui/common.dart';
import 'package:hatto_desktop/ui/import_copy.dart';
import 'package:hatto_desktop/ui/import_progress.dart';
import 'package:hatto_desktop/ui/shell.dart';
import 'package:hatto_store/hatto_store.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory root;

  setUp(() {
    root = Directory.systemTemp.createTempSync('hatto-i5-shell');
  });

  tearDown(() {
    if (root.existsSync()) {
      root.deleteSync(recursive: true);
    }
  });

  File writeApkg(String name) {
    final file = File(p.join(root.path, name));
    file.writeAsBytesSync(const [0x50, 0x4b, 0x03, 0x04, 0, 0]);
    return file;
  }

  Future<void> pumpShell(
    WidgetTester tester,
    AppController app,
    ApkgImportSession session,
  ) async {
    tester.view.physicalSize = const Size(1200, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: MainShell(app: app, colors: AnkiColors.light, imports: session),
      ),
    );
    await tester.pump();
  }

  ApkgImportSession sessionFor({
    required AppController app,
    required ApkgImportFile importFile,
    Future<String?> Function()? pickFile,
    void Function(File file)? onTempFile,
  }) {
    return ApkgImportSession(
      importFile: importFile,
      dataDir: p.join(root.path, 'data'),
      refreshDecks: () async {},
      flushEditor: app.flushPendingEdits,
      pickFile: pickFile ?? () async => null,
      onTempFile: onTempFile,
      tempDirectory: Directory(p.join(root.path, 'tmp')),
    );
  }

  testWidgets('T-I5-S the shell does not open the picker when startup failed', (
    tester,
  ) async {
    final app = AppController.bare();
    var picked = 0;
    final session = ApkgImportSession(
      importFile:
          ({required sourcePath, required limits, cancel, onPhase}) async {
            return const ImportRunResult(outcome: ImportOutcome.noop);
          },
      dataDir: p.join(root.path, 'data'),
      refreshDecks: () async {},
      flushEditor: app.flushPendingEdits,
      startupError: StateError('recover'),
      pickFile: () async {
        picked++;
        return null;
      },
      tempDirectory: Directory(p.join(root.path, 'tmp')),
    );
    await pumpShell(tester, app, session);
    await tester.tap(find.byKey(const ValueKey('import-file')));
    await tester.pump();
    expect(picked, 0);
    expect(find.text(kStartupBlocked), findsOneWidget);
    await tester.pump(const Duration(seconds: 5));
    expect(find.text(kStartupBlocked), findsNothing);
  });

  testWidgets('the progress route locks focus and flushes the editor first', (
    tester,
  ) async {
    final app = AppController.bare();
    final order = <String>[];
    final gate = Completer<ImportRunResult>();
    final file = writeApkg('focus.apkg');
    app.flushEditor = () async {
      order.add('flush');
    };
    final session = sessionFor(
      app: app,
      pickFile: () async => file.path,
      importFile: ({required sourcePath, required limits, cancel, onPhase}) {
        order.add('import');
        onPhase?.call(ImportPhase.afterFinish);
        return gate.future;
      },
    );
    await pumpShell(tester, app, session);
    await tester.tap(find.byKey(const ValueKey('import-file')));
    for (var i = 0; i < 20 && order.length < 2; i++) {
      await tester.pump();
    }
    await tester.pump();

    expect(order, ['flush', 'import']);
    expect(find.text(kStageComparing), findsOneWidget);
    expect(session.running, isTrue);
    expect(tester.widget<DropTarget>(find.byType(DropTarget)).enable, isFalse);
    expect(
      tester
          .widget<PillButton>(find.byKey(const ValueKey('import-file')))
          .onTap,
      isNull,
    );

    final route = ModalRoute.of(
      tester.element(find.byKey(const ValueKey('import-progress'))),
    );
    expect(route, isNotNull);
    expect(route!.barrierDismissible, isFalse);
    final pop = tester
        .element(find.byKey(const ValueKey('import-progress')))
        .findAncestorWidgetOfExactType<PopScope>();
    expect(pop, isNotNull);
    expect(pop!.canPop, isFalse);
    final focusContext = FocusManager.instance.primaryFocus?.context;
    expect(focusContext, isNotNull);
    expect(
      focusContext!.findAncestorWidgetOfExactType<ImportProgressDialog>(),
      isNotNull,
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(find.byKey(const ValueKey('import-progress')), findsOneWidget);

    gate.complete(const ImportRunResult(outcome: ImportOutcome.cancelled));
    await tester.pump();
    await tester.pump();
    expect(find.text(kCancelToast), findsOneWidget);
    expect(find.byKey(const ValueKey('import-progress')), findsNothing);
  });

  testWidgets(
    'T-I5-J5 the shell rejects a multi-file drop, a folder, and streams a path-less file',
    (tester) async {
      final app = AppController.bare();
      var calls = 0;
      File? temp;
      final session = sessionFor(
        app: app,
        onTempFile: (file) => temp = file,
        importFile:
            ({required sourcePath, required limits, cancel, onPhase}) async {
              calls++;
              expect(File(sourcePath).existsSync(), isTrue);
              expect(
                p.isWithin(p.join(root.path, 'data', 'import'), sourcePath),
                isFalse,
              );
              return ImportRunResult(
                outcome: ImportOutcome.noop,
                plan: PreparedPlan(
                  batchId: '11111111-1111-4111-8111-111111111111',
                  stagedPath: sourcePath,
                  stagedSha256: 'ab',
                  firstImport: false,
                  newGuids: const [],
                  changed: const {},
                  deckNames: const ['Default'],
                  counts: const ImportPlanCounts(
                    newNotes: 0,
                    same: 0,
                    changed: 0,
                    localNewer: 0,
                    blocked: 0,
                    dup: 0,
                    noResidentCall: true,
                  ),
                ),
              );
            },
      );
      await pumpShell(tester, app, session);
      final drop = tester.widget<DropTarget>(find.byType(DropTarget));
      final a = writeApkg('a.apkg');
      final b = writeApkg('b.apkg');
      drop.onDragDone!(
        DropDoneDetails(
          files: [DropItemFile(a.path), DropItemFile(b.path)],
          localPosition: Offset.zero,
          globalPosition: Offset.zero,
        ),
      );
      await tester.pump();
      expect(calls, 0);
      expect(find.text(kOneFileOnly), findsOneWidget);

      final folder = Directory(p.join(root.path, 'folder'))..createSync();
      drop.onDragDone!(
        DropDoneDetails(
          files: [DropItemDirectory(folder.path, const [])],
          localPosition: Offset.zero,
          globalPosition: Offset.zero,
        ),
      );
      await tester.pump();
      expect(calls, 0);
      expect(find.text(kFormatFailure), findsOneWidget);

      // Linux reports a directory as DropItemFile whose path is the folder.
      drop.onDragDone!(
        DropDoneDetails(
          files: [DropItemFile(folder.path)],
          localPosition: Offset.zero,
          globalPosition: Offset.zero,
        ),
      );
      await tester.pump();
      expect(calls, 0);
      expect(find.text(kFormatFailure), findsOneWidget);

      // dart:io XFile.name is the path's last segment, and `name:` is ignored.
      // A path that is not a local file falls through to openRead.
      final streamed = writeApkg('stream.apkg');
      await tester.runAsync(() async {
        drop.onDragDone!(
          DropDoneDetails(
            files: [
              DropItemFile.fromData(
                streamed.readAsBytesSync(),
                path: 'virtual/stream.apkg',
              ),
            ],
            localPosition: Offset.zero,
            globalPosition: Offset.zero,
          ),
        );
        for (var i = 0; i < 50 && calls == 0; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
      });
      await tester.pump();
      expect(calls, 1);
      expect(temp, isNotNull);
      expect(temp!.existsSync(), isFalse);
      expect(find.text(kAlreadyImported), findsOneWidget);
    },
  );
}
