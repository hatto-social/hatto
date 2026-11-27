// SPDX-FileCopyrightText: 2026 Hatto Social contributors
//
// SPDX-License-Identifier: AGPL-3.0-or-later

// Widget tests (real rslib through FFI inside runAsync) for the 2026-11-19 decisions: deck list, greyed controls, suspend, delete copy,
// FSRS guidance, preview math, reviewer sound.
import 'dart:io';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:fixnum/fixnum.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_math_fork/flutter_math.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hatto_desktop/editor/anki_ui.dart';
import 'package:hatto_desktop/effect/apkg_import.dart';
import 'package:hatto_desktop/engine/anki_api.dart';
import 'package:hatto_desktop/engine/engine.dart';
import 'package:hatto_desktop/src/gen/anki/collection.pb.dart';
import 'package:hatto_desktop/src/gen/anki/generic.pb.dart' as g;
import 'package:hatto_desktop/src/gen/anki/notes.pb.dart';
import 'package:hatto_desktop/src/gen/anki/notetypes.pb.dart';
import 'package:path/path.dart' as p;
import 'package:protobuf/protobuf.dart';
import 'package:rslib_bridge/rslib_bridge.dart';
import 'package:hatto_desktop/services/audio_service.dart';
import 'package:hatto_desktop/state/app_controller.dart';
import 'package:hatto_desktop/ui/common.dart';
import 'package:hatto_desktop/ui/copy.dart';
import 'package:hatto_desktop/ui/import_copy.dart';
import 'package:hatto_desktop/ui/shell.dart';
import 'package:hatto_store/hatto_store.dart';
import 'test_fonts.dart';

late Directory tmp; late Engine eng; late FlowApi api; late AppController app; late FakeAudioService fake;

/// Each `await` in the app's handlers resumes in the fake-async zone, so alternate: real time for the FFI reply, then a pump to run the continuation.
Future<void> settle(WidgetTester t, {int rounds = 40}) async {
  for (var i = 0; i < rounds; i++) { await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 8))); await t.pump(const Duration(milliseconds: 20)); }
}

/// Returns as soon as [finder] matches. A fixed [settle] can finish before a
/// slow FFI answer paints, which flaked the congrats check on a busy runner.
Future<void> untilFound(WidgetTester t, Finder finder, {int rounds = 400}) async {
  for (var i = 0; i < rounds; i++) {
    if (finder.evaluate().isNotEmpty) return;
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 8)));
    await t.pump(const Duration(milliseconds: 20));
  }
}
Future<void> tapKey(WidgetTester t, String key, {int rounds = 40}) async { await t.tap(find.byKey(ValueKey(key))); await settle(t, rounds: rounds); }
T widgetOf<T extends Widget>(WidgetTester t, String key) => t.widget<T>(find.byKey(ValueKey(key)));

/// Writes notes with the unrestricted backend, then the test opens that
/// collection on the desktop profile. AddNote stays closed there.
Future<void> seedDefaultNotes(Directory dir, List<(String, String)> notes) async {
  final media = Directory(p.join(dir.path, 'collection.media'))..createSync(recursive: true);
  final backend = await openBackend(initMsg: encodeBackendInit());
  Future<List<int>> invoke(String service, String method, GeneratedMessage req) async {
    final index = serviceMethodIndex(service: service, method: method);
    if (index == null) throw StateError('no index for $service.$method');
    final response = await command(
      backend: backend,
      service: index.service,
      method: index.method,
      input: req.writeToBuffer(),
    );
    if (!response.success) {
      throw StateError('$service.$method failed while seeding');
    }
    return response.payload;
  }
  await invoke('BackendCollectionService', 'open_collection', OpenCollectionRequest(
    collectionPath: p.join(dir.path, 'collection.anki2'),
    mediaFolderPath: media.path,
    mediaDbPath: p.join(dir.path, 'collection.media.db'),
  ));
  final notetype = NotetypeId.fromBuffer(await invoke(
    'BackendNotetypesService', 'get_notetype_id_by_name', g.String(val: 'Basic'),
  ));
  for (final (front, back) in notes) {
    final note = Note.fromBuffer(await invoke('BackendNotesService', 'new_note', notetype));
    note.fields..clear()..addAll([front, back]);
    await invoke('BackendNotesService', 'add_note', AddNoteRequest(note: note, deckId: Int64(1)));
  }
  await invoke('BackendCollectionService', 'close_collection', CloseCollectionRequest());
}

Future<void> boot(
  WidgetTester t,
  Future<void> Function() seed, {
  List<(String, String)> seeded = const [],
  ApkgImportSession Function(AppController app)? imports,
}) async {
  t.view.physicalSize = const Size(1200, 720); t.view.devicePixelRatio = 1;
  addTearDown(() { t.view.resetPhysicalSize(); t.view.resetDevicePixelRatio(); });
  ApkgImportSession? session;
  await t.runAsync(() async {
    tmp = await Directory.systemTemp.createTemp('hf_ui_');
    if (seeded.isNotEmpty) await seedDefaultNotes(tmp, seeded);
    eng = await Engine.open(langs: ['ko', 'en'], dataDir: tmp.path); api = FlowApi(eng); await api.openCollection(tmp.path);
    fake = FakeAudioService(); app = AppController(api, audio: fake);
    await seed(); await app.refreshDecks();
    session = imports?.call(app);
  });
  await t.pumpWidget(MaterialApp(debugShowCheckedModeBanner: false, theme: ThemeData(fontFamily: kUiFont, fontFamilyFallback: const ['NanumGothic']),
    home: Material(child: MainShell(app: app, colors: AnkiColors.light, imports: session))));
  await settle(t);
  addTearDown(() async { try { await api.closeCollection(); } catch (_) {} eng.close(); try { await tmp.delete(recursive: true); } catch (_) {} });
}

// Browse stays skipped: SetActiveBrowserColumns is deferred and the table
// reports "Active browser columns not set." The math golden stays skipped
// in math_test because pixel output moves with the font rasterizer.
void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    await initRslibBridge();
    await loadTestFonts();
  });

  testWidgets('add, delete, and image entry points stay closed', (t) async {
    await boot(t, () async {});
    expect(t.widget<GestureDetector>(find.byKey(const ValueKey('nav-add'))).onTap, isNull);
    expect(widgetOf<PillButton>(t, 'create-deck').onTap, isNull);
    await tapKey(t, 'nav-browse');
    expect(widgetOf<QtPush>(t, 'br-delete').onTap, isNull);
    expect(find.text('노트 편집은 이 버전에 없습니다.'), findsOneWidget);
  });

  testWidgets('deck overview + deck list: unplanned features visible but disabled', (t) async {
    await boot(t, () async {}, seeded: [('q', 'a')]);
    await tapKey(t, 'deck-Default');
    for (final label in ['옵션', '사용자 지정 학습', '설명']) {
      final b = t.widget<PillButton>(find.widgetWithText(PillButton, label)); expect(b.onTap, isNull, reason: label);
    }
    await tapKey(t, 'nav-decks');
    expect(t.widget<PillButton>(find.widgetWithText(PillButton, '공유 덱 받기')).onTap, isNull);
    // the toolbar's 동기화 is visible; its GestureDetector has no onTap
    expect(find.text('동기화'), findsOneWidget);
    final g = t.widget<GestureDetector>(find.byKey(const ValueKey('nav-sync'))); expect(g.onTap, isNull);
  });

  // SetActiveBrowserColumns stays deferred, so the table answers
  // "Active browser columns not set." Seeding notes does not unblock it.
  testWidgets('browse: suspend toggle works; bury and due-date stay disabled; delete stays closed; preview renders math', skip: true, (t) async {
    await boot(t, () async {}, seeded: [(r'수식 \(x^2\)', r'답 \[a+b\]'), ('둘째', 'two')]);
    await tapKey(t, 'nav-browse');
    await tapKey(t, 'side-deck-Default');
    expect(widgetOf<QtPush>(t, 'br-bury').onTap, isNull); expect(widgetOf<QtPush>(t, 'br-due').onTap, isNull);
    expect(find.text('미루기(bury)'), findsOneWidget); expect(find.text('기한 설정…'), findsOneWidget);
    expect(widgetOf<QtPush>(t, 'br-suspend').onTap, isNull, reason: 'nothing selected');
    await tapKey(t, 'row-0');
    expect(widgetOf<QtPush>(t, 'br-suspend').onTap, isNotNull);
    expect(widgetOf<QtPush>(t, 'br-bury').onTap, isNull); expect(widgetOf<QtPush>(t, 'br-due').onTap, isNull);
    await tapKey(t, 'br-suspend');
    expect((await t.runAsync(() => api.searchCards('is:suspended')))!.length, 1);
    await tapKey(t, 'br-suspend');
    expect((await t.runAsync(() => api.searchCards('is:suspended')))!.length, 0, reason: 'toggle: all selected suspended -> unsuspend');
    // preview with math
    await tapKey(t, 'row-0');
    final rows = await t.runAsync(() => api.searchCards('수식'));
    expect(rows!.length, 1);
    // select the math card (sorted by sort field: "둘째" < "수식"?), so click whichever row holds it
    for (var i = 0; i < 2; i++) { await tapKey(t, 'row-$i'); await tapKey(t, 'br-preview'); if (find.byKey(const ValueKey('preview-card')).evaluate().isNotEmpty && find.byType(Math).evaluate().isNotEmpty) break; await tapKey(t, 'preview-close'); }
    expect(find.byKey(const ValueKey('math-inline')), findsOneWidget);
    await tapKey(t, 'preview-back');
    expect(find.byKey(const ValueKey('math-display')), findsOneWidget);
    await tapKey(t, 'preview-close');
    // RemoveNotes stays closed, so the delete control cannot open a dialog.
    expect(widgetOf<QtPush>(t, 'br-delete').onTap, isNull);
    expect(kDeleteNoteNotice, '노트를 삭제해도 복습 기록은 전체 통계에 남아요. 덱별 통계와 카드 정보에서는 사라져요.');
  });

  testWidgets('stats: scheduler card shows the FSRS guidance (PO copy) and a disabled FSRS-optimize button', (t) async {
    await boot(t, () async {});
    await tapKey(t, 'nav-stats');
    expect(find.text('스케줄러: FSRS (기본 파라미터)'), findsOneWidget);
    expect(widgetOf<Text>(t, 'st-fsrs-1').data, 'FSRS가 복습 기록을 바탕으로 다음 복습 날짜를 정해요. 목표 유지율은 90%예요.');
    expect(widgetOf<Text>(t, 'st-fsrs-2').data, "답이 떠오르지 않았다면 '어려움' 대신 '다시'를 눌러 주세요.");
    expect(widgetOf<PillButton>(t, 'fsrs-optimize').onTap, isNull); expect(find.text('FSRS 최적화'), findsOneWidget);
    for (final bad in ['정확도', '보장', '더 많이 배']) { expect(kFsrsGuidance1.contains(bad) || kFsrsGuidance2.contains(bad), isFalse, reason: 'no accuracy / guarantee claims'); }
  });

  testWidgets('reviewer: answering the seeded card reaches congrats, and undo brings it back', (t) async {
    await boot(t, () async {}, seeded: [('q1', 'a1')]);
    await tapKey(t, 'deck-Default');
    await tapKey(t, 'study-now');
    expect(find.byKey(const ValueKey('show-answer')), findsOneWidget);
    await tapKey(t, 'show-answer');
    expect(find.byKey(const ValueKey('fsrs-hint')), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('ans-easy')));
    await untilFound(t, find.byKey(const ValueKey('congrats')));
    expect(find.byKey(const ValueKey('congrats')), findsOneWidget);
    await tapKey(t, 'congrats-undo');
    expect(find.byKey(const ValueKey('show-answer')), findsOneWidget);
    await t.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await t.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await t.sendKeyDownEvent(LogicalKeyboardKey.keyZ);
    await untilFound(t, find.byKey(const ValueKey('congrats')));
    await t.sendKeyUpEvent(LogicalKeyboardKey.keyZ);
    await t.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await t.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    expect(find.byKey(const ValueKey('congrats')), findsOneWidget);
    expect(find.text('이번 세션에서 1장 답했어요.'), findsOneWidget);
  });

  testWidgets('undo leaves a non-answer on the stack and keeps the answered count', (t) async {
    await boot(t, () async { await api.renameDeck(1, '이름바꿈'); }, seeded: [('q1', 'a1')]);
    await tapKey(t, 'deck-이름바꿈');
    await tapKey(t, 'study-now');
    await tapKey(t, 'rv-more');
    expect(find.text('실행 취소 (할 것 없음)'), findsOneWidget);
    await tapKey(t, 'window-close');
    await t.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await t.sendKeyDownEvent(LogicalKeyboardKey.keyZ);
    await settle(t);
    await t.sendKeyUpEvent(LogicalKeyboardKey.keyZ);
    await t.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    expect(find.byKey(const ValueKey('show-answer')), findsOneWidget);
    expect(app.session!.answered, 0);
    await tapKey(t, 'show-answer');
    await tapKey(t, 'ans-easy');
    expect(find.text('이번 세션에서 1장 답했어요.'), findsOneWidget);
    await tapKey(t, 'congrats-undo');
    expect(app.session!.answered, 0);
    expect(find.byKey(const ValueKey('show-answer')), findsOneWidget);
    await tapKey(t, 'rv-more');
    expect(find.text('실행 취소 (할 것 없음)'), findsOneWidget);
    await tapKey(t, 'window-close');
    await tapKey(t, 'nav-decks');
    expect(find.byKey(const ValueKey('deck-이름바꿈')), findsOneWidget);
    expect(find.byKey(const ValueKey('deck-Default')), findsNothing);
  });

  testWidgets('reviewer: first-review hint uses the real button labels; disappears after the first answer; bury greyed in More menu; suspend works', (t) async {
    await boot(t, () async {}, seeded: [('q1', 'a1'), ('q2', 'a2'), ('q3', 'a3')]);
    await tapKey(t, 'deck-Default'); await tapKey(t, 'study-now');
    expect(find.byKey(const ValueKey('fsrs-hint')), findsNothing, reason: 'hint only next to the answer buttons');
    await tapKey(t, 'show-answer');
    expect(find.byKey(const ValueKey('fsrs-hint')), findsOneWidget);
    // the labels quoted in the copy are the real button labels
    final again = find.descendant(of: find.byKey(const ValueKey('ans-again')), matching: find.byType(Text)).first;
    final hard = find.descendant(of: find.byKey(const ValueKey('ans-hard')), matching: find.byType(Text)).first;
    expect(t.widget<Text>(again).data, '다시'); expect(t.widget<Text>(hard).data, '어려움');
    expect(kFsrsGuidance2, contains("'${t.widget<Text>(hard).data}'")); expect(kFsrsGuidance2, contains("'${t.widget<Text>(again).data}'"));
    await tapKey(t, 'ans-good');
    await tapKey(t, 'show-answer');
    expect(find.byKey(const ValueKey('fsrs-hint')), findsNothing, reason: 'first card of the session only');
    // More menu: bury visible, disabled (tapping does nothing)
    await tapKey(t, 'rv-more');
    expect(find.textContaining('미루기(bury)'), findsOneWidget);
    await t.tap(find.textContaining('미루기(bury)')); await settle(t);
    expect(find.text('더 보기'), findsOneWidget, reason: 'menu still open: disabled item did not close it');
    expect((await t.runAsync(() => api.searchCards('is:buried')))!.length, 0);
    await tapKey(t, 'choice-카드 보류(suspend)');
    expect((await t.runAsync(() => api.searchCards('is:suspended')))!.length, 1);
  });

  testWidgets('reviewer: [sound:] plays through AudioService only for a file in collection.media', (t) async {
    await boot(t, () async {
      File('${api.mediaDir}/hello.mp3').writeAsBytesSync([0, 1, 2]);
      File('${tmp.path}/evil.mp3').writeAsBytesSync([9]);
    }, seeded: [('소리 [sound:hello.mp3] 와 [sound:../evil.mp3]', 'a')]);
    await tapKey(t, 'deck-Default'); await tapKey(t, 'study-now');
    await tapKey(t, 'play-q-0');
    expect(fake.played, ['${api.mediaDir}/hello.mp3']);
    await tapKey(t, 'play-q-1');
    expect(fake.played.length, 1, reason: 'traversal name is rejected before reaching the player');
    expect(find.byKey(const ValueKey('toast')), findsOneWidget);
    await t.pump(const Duration(seconds: 6));
  });

  testWidgets(
    'an import from the reviewer opens the deck list only after the collection changes',
    (t) async {
      var outcome = ImportOutcome.committed;
      var refreshes = 0;
      ApkgImportSession? imports;
      await boot(t, () async {}, seeded: [('q1', 'a1')], imports: (controller) {
        final session = ApkgImportSession(
          importFile: ({required sourcePath, required limits, cancel, onPhase}) {
            return Future.value(ImportRunResult(outcome: outcome));
          },
          dataDir: tmp.path,
          refreshDecks: () async {
            refreshes++;
            await controller.refreshDecks();
          },
          flushEditor: controller.flushPendingEdits,
          pickFile: () async => null,
          tempDirectory: Directory(p.join(tmp.path, 'drop-tmp')),
          log: (_) {},
        );
        imports = session;
        return session;
      });

      Future<void> study() async {
        await tapKey(t, 'deck-Default');
        await tapKey(t, 'study-now');
        expect(find.byKey(const ValueKey('show-answer')), findsOneWidget);
        expect(app.screen, Screen.review);
        expect(t.takeException(), isNull);
      }

      void drop(String name) {
        final file = File(p.join(tmp.path, name))
          ..writeAsBytesSync(const [0x50, 0x4b, 0x03, 0x04, 0, 0]);
        final target = t.widget<DropTarget>(find.byType(DropTarget));
        target.onDragDone!(
          DropDoneDetails(
            files: [DropItemFile(file.path)],
            localPosition: Offset.zero,
            globalPosition: Offset.zero,
          ),
        );
      }

      await study();
      final beforeCommit = refreshes;
      drop('added.apkg');
      await settle(t);
      expect(t.takeException(), isNull);
      expect(app.screen, Screen.decks);
      expect(find.byKey(const ValueKey('show-answer')), findsNothing);
      expect(find.byKey(const ValueKey('deck-panel')), findsOneWidget);
      expect(find.text(importedFileMessage('added.apkg')), findsOneWidget);
      expect(refreshes, beforeCommit + 1);

      outcome = ImportOutcome.cancelled;
      await study();
      final beforeCancel = refreshes;
      drop('cancel.apkg');
      await settle(t);
      expect(t.takeException(), isNull);
      expect(app.screen, Screen.review);
      expect(find.byKey(const ValueKey('show-answer')), findsOneWidget);
      expect(find.text(kCancelToast), findsOneWidget);
      expect(refreshes, beforeCancel);

      outcome = ImportOutcome.failedBeforeCommit;
      final beforeEarly = refreshes;
      drop('early.apkg');
      await settle(t);
      expect(t.takeException(), isNull);
      expect(app.screen, Screen.review);
      expect(find.byKey(const ValueKey('show-answer')), findsOneWidget);
      expect(refreshes, beforeEarly);

      outcome = ImportOutcome.noop;
      drop('same.apkg');
      await settle(t);
      expect(t.takeException(), isNull);
      expect(app.screen, Screen.review);
      expect(find.byKey(const ValueKey('show-answer')), findsOneWidget);
      expect(find.text(kAlreadyImported), findsOneWidget);

      outcome = ImportOutcome.failedAfterCommit;
      final beforeAdopt = refreshes;
      drop('adopt.apkg');
      await settle(t);
      expect(t.takeException(), isNull);
      expect(app.screen, Screen.decks);
      expect(find.byKey(const ValueKey('show-answer')), findsNothing);
      expect(find.byKey(const ValueKey('deck-panel')), findsOneWidget);
      expect(find.text(adoptionFailureMessage('adopt.apkg')), findsOneWidget);
      expect(find.byKey(const ValueKey('toast')), findsOneWidget);
      expect(refreshes, beforeAdopt + 1);

      outcome = ImportOutcome.failedUnknown;
      await study();
      final beforeUnknown = refreshes;
      drop('unknown.apkg');
      await settle(t);
      expect(t.takeException(), isNull);
      expect(app.screen, Screen.decks);
      expect(find.byKey(const ValueKey('show-answer')), findsNothing);
      expect(find.byKey(const ValueKey('deck-panel')), findsOneWidget);
      expect(find.text(unknownFailureMessage('unknown.apkg')), findsOneWidget);
      expect(find.byKey(const ValueKey('toast')), findsOneWidget);
      expect(refreshes, beforeUnknown + 1);
      expect(imports!.sessionLocked, isTrue);
    },
  );
}
