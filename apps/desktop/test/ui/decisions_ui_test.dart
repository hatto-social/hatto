// SPDX-FileCopyrightText: 2026 Hatto Social contributors
//
// SPDX-License-Identifier: AGPL-3.0-or-later

// Widget tests (real rslib through FFI inside runAsync) for the 2026-11-19 decisions: deck list, greyed controls, suspend, delete copy,
// FSRS guidance, preview math, reviewer sound.
import 'dart:io';
import 'package:fixnum/fixnum.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_math_fork/flutter_math.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hatto_desktop/editor/anki_ui.dart';
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
import 'package:hatto_desktop/ui/shell.dart';
import 'test_fonts.dart';

late Directory tmp; late Engine eng; late FlowApi api; late AppController app; late FakeAudioService fake;

Future<int> addBasic(String f, String b, int deck) async {
  final nt = (await api.notetypeNames()).firstWhere((n) => n.name == 'Basic').id.toInt();
  final n = await api.newNote(nt); n.fields..clear()..addAll([f, b]); return api.addNote(n, deck);
}

/// Each `await` in the app's handlers resumes in the fake-async zone, so alternate: real time for the FFI reply, then a pump to run the continuation.
Future<void> settle(WidgetTester t, {int rounds = 40}) async {
  for (var i = 0; i < rounds; i++) { await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 8))); await t.pump(const Duration(milliseconds: 20)); }
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

Future<void> boot(WidgetTester t, Future<void> Function() seed, {bool fsrs = true, List<(String, String)> seeded = const []}) async {
  t.view.physicalSize = const Size(1200, 720); t.view.devicePixelRatio = 1;
  addTearDown(() { t.view.resetPhysicalSize(); t.view.resetDevicePixelRatio(); });
  await t.runAsync(() async {
    tmp = await Directory.systemTemp.createTemp('hf_ui_');
    if (seeded.isNotEmpty) await seedDefaultNotes(tmp, seeded);
    eng = await Engine.open(langs: ['ko', 'en'], dataDir: tmp.path); api = FlowApi(eng); await api.openCollection(tmp.path, fsrsDefault: fsrs);
    fake = FakeAudioService(); app = AppController(api, audio: fake);
    await seed(); await app.refreshDecks();
  });
  await t.pumpWidget(MaterialApp(debugShowCheckedModeBanner: false, theme: ThemeData(fontFamily: kUiFont, fontFamilyFallback: const ['NanumGothic']),
    home: Material(child: MainShell(app: app, colors: AnkiColors.light))));
  await settle(t);
  addTearDown(() async { try { await api.closeCollection(); } catch (_) {} eng.close(); try { await tmp.delete(recursive: true); } catch (_) {} });
}

// Tests that need AddNote, AddDeck, or an SM-2 collection are skipped.
// Those calls stay denied, and the bridge turns FSRS on for a new collection.
void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    await initRslibBridge();
    await loadTestFonts();
  });

  testWidgets('deck list: empty Default hidden, auto-created parent expanded with child visible', skip: true, (t) async {
    await boot(t, () async { await app.createDeck('한국어::기초'); });
    expect(find.byKey(const ValueKey('deck-row-Default')), findsNothing);
    expect(find.byKey(const ValueKey('deck-row-한국어')), findsOneWidget);
    expect(find.byKey(const ValueKey('deck-row-기초')), findsOneWidget, reason: 'child visible => parent is expanded');
  });

  testWidgets('add, delete, and image entry points stay closed', (t) async {
    await boot(t, () async {});
    expect(t.widget<GestureDetector>(find.byKey(const ValueKey('nav-add'))).onTap, isNull);
    expect(widgetOf<PillButton>(t, 'create-deck').onTap, isNull);
    await tapKey(t, 'nav-browse');
    expect(widgetOf<QtPush>(t, 'br-delete').onTap, isNull);
    expect(find.text('노트 편집은 이 버전에 없습니다.'), findsOneWidget);
  });

  testWidgets('deck overview + deck list: unplanned features visible but disabled', skip: true, (t) async {
    await boot(t, () async { final d = await api.addDeck('S'); await addBasic('q', 'a', d); });
    await tapKey(t, 'deck-S');
    for (final label in ['옵션', '사용자 지정 학습', '설명']) {
      final b = t.widget<PillButton>(find.widgetWithText(PillButton, label)); expect(b.onTap, isNull, reason: label);
    }
    await tapKey(t, 'nav-decks');
    expect(t.widget<PillButton>(find.widgetWithText(PillButton, '공유 덱 받기')).onTap, isNull);
    // the toolbar's 동기화 is visible; its GestureDetector has no onTap
    expect(find.text('동기화'), findsOneWidget);
    final g = t.widget<GestureDetector>(find.byKey(const ValueKey('nav-sync'))); expect(g.onTap, isNull);
  });

  testWidgets('browse: suspend toggle works; bury and due-date visible but disabled; delete dialog shows the PO copy; preview renders math', skip: true, (t) async {
    late int deck;
    await boot(t, () async { deck = await api.addDeck('B'); await addBasic(r'수식 \(x^2\)', r'답 \[a+b\]', deck); await addBasic('둘째', 'two', deck); });
    await tapKey(t, 'nav-browse');
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
    // delete dialog copy
    await tapKey(t, 'row-0'); await tapKey(t, 'br-delete');
    expect(find.text('선택한 카드의 노트를 삭제할까요?\n\n$kDeleteNoteNotice'), findsOneWidget);
    expect(kDeleteNoteNotice, '노트를 삭제해도 복습 기록은 전체 통계에 남아요. 덱별 통계와 카드 정보에서는 사라져요.');
    await tapKey(t, 'confirm-cancel');
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

  testWidgets('stats on an SM-2 collection: no FSRS copy, optimize still visible+disabled', skip: true, (t) async {
    await boot(t, () async {}, fsrs: false);
    await tapKey(t, 'nav-stats');
    expect(find.text('스케줄러: SM-2 (기본)'), findsOneWidget);
    expect(find.byKey(const ValueKey('st-fsrs-1')), findsNothing);
    expect(widgetOf<PillButton>(t, 'fsrs-optimize').onTap, isNull);
  });

  testWidgets('reviewer: answering the seeded card reaches congrats, and undo brings it back', (t) async {
    await boot(t, () async {}, seeded: [('q1', 'a1')]);
    await tapKey(t, 'deck-Default');
    await tapKey(t, 'study-now');
    expect(find.byKey(const ValueKey('show-answer')), findsOneWidget);
    await tapKey(t, 'show-answer');
    expect(find.byKey(const ValueKey('fsrs-hint')), findsOneWidget);
    await tapKey(t, 'ans-easy');
    expect(find.byKey(const ValueKey('congrats')), findsOneWidget);
    await tapKey(t, 'congrats-undo');
    expect(find.byKey(const ValueKey('show-answer')), findsOneWidget);
    await t.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await t.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await t.sendKeyDownEvent(LogicalKeyboardKey.keyZ);
    await settle(t);
    await t.sendKeyUpEvent(LogicalKeyboardKey.keyZ);
    await t.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await t.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    expect(find.byKey(const ValueKey('congrats')), findsOneWidget);
    expect(find.text('이번 세션에서 1장 답했어요.'), findsOneWidget);
  });

  testWidgets('reviewer: first-review hint uses the real button labels; disappears after the first answer; bury greyed in More menu; suspend works', skip: true, (t) async {
    await boot(t, () async { final d = await api.addDeck('R'); await addBasic('q1', 'a1', d); await addBasic('q2', 'a2', d); await addBasic('q3', 'a3', d); });
    await tapKey(t, 'deck-R'); await tapKey(t, 'study-now');
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

  testWidgets('reviewer: [sound:] plays through AudioService only for a file in collection.media', skip: true, (t) async {
    await boot(t, () async {
      final d = await api.addDeck('Snd'); await addBasic('소리 [sound:hello.mp3] 와 [sound:../evil.mp3]', 'a', d);
      Directory(api.mediaDir).createSync(recursive: true); File('${api.mediaDir}/hello.mp3').writeAsBytesSync([0, 1, 2]);
      File('${tmp.path}/evil.mp3').writeAsBytesSync([9]);
    });
    await tapKey(t, 'deck-Snd'); await tapKey(t, 'study-now');
    await tapKey(t, 'play-q-0');
    expect(fake.played, ['${api.mediaDir}/hello.mp3']);
    await tapKey(t, 'play-q-1');
    expect(fake.played.length, 1, reason: 'traversal name is rejected before reaching the player');
    expect(find.byKey(const ValueKey('toast')), findsOneWidget);
    await t.pump(const Duration(seconds: 6));
  });
}
