// Anki-look note editor (lib/note_editor.dart + anki_ui.dart): behaviour gates + screenshots (../screenshots/anki_*.png).
import 'dart:io';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:editor_proto/anki_ui.dart';
import 'package:editor_proto/note_editor.dart';
import 'package:editor_proto/proto_editable.dart';
import 'util.dart';

const front = '<b>굵게 <i>굵고 기울임</i></b> <u>밑줄</u> H<sub>2</sub>O x<sup>2</sup> <span style="color: #d32f2f">빨강</span> 일반 텍스트';
const back = '다음 줄<br>[sound:rec.m4a] <span style="color: #1565c0">파랑</span> 끝';
final key = GlobalKey<NoteEditorState>();

Future<void> pumpNote(WidgetTester tester, {AnkiColors colors = AnkiColors.light, bool voluntary = false, List<NoteFieldSpec>? fields, bool autofocus = false}) async {
  tester.view.physicalSize = const Size(980 * 2, 700 * 2); tester.view.devicePixelRatio = 2;
  addTearDown(() { tester.view.resetPhysicalSize(); tester.view.resetDevicePixelRatio(); });
  await tester.pumpWidget(RepaintBoundary(key: shotKey, child: MaterialApp(debugShowCheckedModeBanner: false, theme: ThemeData(fontFamily: kUiFont, fontFamilyFallback: const ['NanumGothic']),
    home: Scaffold(body: NoteEditor(key: key, colors: colors, tags: const ['korean::vocab', 'noun'], voluntaryHtmlToggle: voluntary, autofocus: autofocus, fontFamily: latinFont,
      fields: fields ?? const [NoteFieldSpec('Front', front), NoteFieldSpec('Back', back)])))));
  await tester.pump();
}

File _fontFile(List<String> candidates, String label) {
  for (final p in candidates) {
    final f = File(p);
    if (f.existsSync()) return f;
  }
  throw StateError('$label not found. Tried: $candidates');
}

Future<void> loadAnkiFonts() async {
  await loadFont();
  final noto = _fontFile([
    '/usr/share/fonts/truetype/sand-box/google/Noto Sans/NotoSans-VariableFont_wdth,wght.ttf',
    '/usr/share/fonts/truetype/noto/NotoSans-Regular.ttf',
  ], 'Noto Sans');
  final n = FontLoader(kUiFont)..addFont(Future.value(ByteData.sublistView(noto.readAsBytesSync())));
  await n.load();
  final mono = _fontFile([
    '/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf',
  ], 'DejaVu Sans Mono');
  final m = FontLoader('DejaVu Sans Mono')..addFont(Future.value(ByteData.sublistView(mono.readAsBytesSync())));
  await m.load();
}

void main() {
  setUpAll(() async { await loadAnkiFonts(); Directory(shotDir).createSync(recursive: true); });
  final log = StringBuffer();
  void L(String s) { log.writeln(s); print(s); }
  tearDownAll(() => File('../evidence/b-anki-design-widget-tests.txt').writeAsStringSync(log.toString()));

  testWidgets('A1 multi-field layout: labels, per-field state icons, tags, header/footer mocks; light + dark screenshots', (tester) async {
    await pumpNote(tester, autofocus: true);
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('Front'), findsOneWidget); expect(find.text('Back'), findsOneWidget);
    expect(find.byKey(const ValueKey('field-0')), findsOneWidget);
    expect(find.byKey(const ValueKey('html-0')), findsOneWidget); expect(find.byKey(const ValueKey('pin-1')), findsOneWidget);
    expect(find.byKey(const ValueKey('tag-editor')), findsOneWidget);
    expect(find.byKey(const ValueKey('focus-ring')), findsOneWidget, reason: 'first field is focused on open (Anki behaviour)');
    await shot(tester, 'anki_01_note_editor_light');
    await pumpNote(tester, colors: AnkiColors.darkTheme, autofocus: true); await tester.pump(const Duration(milliseconds: 50));
    await shot(tester, 'anki_02_note_editor_dark');
    L('A1 ok');
  });

  testWidgets('A2 shared toolbar acts only on the focused field; disabled when no field focused or field in source mode', (tester) async {
    await pumpNote(tester);
    final st = key.currentState!;
    // nothing focused => toolbar disabled
    await tester.tap(find.byKey(const ValueKey('tb-bold')), warnIfMissed: false); await tester.pump();
    expect(st.controllerAt(0).dirty, isFalse);
    // focus Back, select all, bold via toolbar button
    await tester.tap(find.descendant(of: find.byKey(const ValueKey('field-1')), matching: find.byType(EditableText))); await tester.pump();
    final back = st.controllerAt(1);
    back.selection = TextSelection(baseOffset: 0, extentOffset: back.text.length); await tester.pump();
    await tester.tap(find.byKey(const ValueKey('tb-bold'))); await tester.pump();
    expect(back.toHtml().startsWith('<b>'), isTrue); expect(st.controllerAt(0).dirty, isFalse, reason: 'Front untouched');
    expect(st.controllerAt(0).save(), front, reason: 'untouched field saves original bytes');
    // focus Front => toolbar now targets Front
    await tester.tap(find.descendant(of: find.byKey(const ValueKey('field-0')), matching: find.byType(EditableText))); await tester.pump();
    final fr = st.controllerAt(0); fr.selection = const TextSelection(baseOffset: 0, extentOffset: 2); await tester.pump();
    await tester.tap(find.byKey(const ValueKey('tb-underline'))); await tester.pump();
    expect(fr.dirty, isTrue);
    L('A2 ok');
  });

  testWidgets('A3 colour: A applies last colour, arrow opens chooser (key tb-color), choosing a colour updates the bar and applies', (tester) async {
    await pumpNote(tester, fields: const [NoteFieldSpec('Front', '가나다라')]);
    final st = key.currentState!; final c = st.controllerAt(0);
    await tester.tap(find.byType(EditableText)); await tester.pump();
    c.selection = const TextSelection(baseOffset: 0, extentOffset: 2); await tester.pump();
    await tester.tap(find.byKey(const ValueKey('tb-color-apply'))); await tester.pump();
    expect(c.toHtml(), '<span style="color: $kDefaultTextColor">가나</span>다라');
    c.selection = const TextSelection(baseOffset: 2, extentOffset: 4); await tester.pump();
    await tester.tap(find.byKey(const ValueKey('tb-color'))); await tester.pump();
    expect(find.byKey(const ValueKey('palette')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('swatch-#d32f2f'))); await tester.pump();
    expect(find.byKey(const ValueKey('palette')), findsNothing);
    expect(c.toHtml(), '<span style="color: $kDefaultTextColor">가나</span><span style="color: #d32f2f">다라</span>');
    // A now applies the newly chosen colour
    c.selection = const TextSelection(baseOffset: 0, extentOffset: 1); await tester.pump();
    await tester.tap(find.byKey(const ValueKey('tb-color-apply'))); await tester.pump();
    expect(c.toHtml().startsWith('<span style="color: #d32f2f">가</span>'), isTrue);
    L('A3 ok');
  });

  testWidgets('A4 out-of-v0 controls are rendered disabled (highlight, eraser, lists, align, mic, equation), never silently live', (tester) async {
    await pumpNote(tester, autofocus: true); await tester.pump(const Duration(milliseconds: 50));
    for (final k in ['tb-highlight', 'tb-highlight-arrow', 'tb-eraser', 'tb-eraser-arrow', 'tb-ul', 'tb-ol', 'tb-align', 'tb-mic', 'tb-equation']) {
      final g = tester.widget<GestureDetector>(find.byKey(ValueKey(k)));
      expect(g.onTap, isNull, reason: '$k must be disabled');
    }
    for (final k in ['tb-bold', 'tb-italic', 'tb-underline', 'tb-sup', 'tb-sub', 'tb-color-apply', 'tb-color', 'tb-img']) {
      expect(tester.widget<GestureDetector>(find.byKey(ValueKey(k))).onTap, isNotNull, reason: '$k must be live when a rich field is focused');
    }
    L('A4 ok');
  });

  testWidgets('A5 collapse hides the field but keeps its content and marks; save() unaffected', (tester) async {
    await pumpNote(tester);
    final st = key.currentState!; final c = st.controllerAt(1);
    expect(find.byType(EditableText).hitTestable(), findsNWidgets(2));
    await tester.tap(find.byKey(const ValueKey('collapse-1'))); await tester.pump();
    expect(find.byType(EditableText).hitTestable(), findsNWidgets(1), reason: 'collapsed field is not shown');
    expect(c.save(), back);
    await tester.tap(find.byKey(const ValueKey('collapse-1'))); await tester.pump();
    expect(find.byType(EditableText).hitTestable(), findsNWidgets(2));
    L('A5 ok');
  });

  testWidgets('A6 HTML editor badge: contract-forced fields open in source mode and the badge cannot be switched off; voluntary toggle only behind the flag', (tester) async {
    const forced = '<div>one</div>\n<div>two</div>';
    await pumpNote(tester, fields: const [NoteFieldSpec('Front', forced), NoteFieldSpec('Back', back)], voluntary: true);
    final st = key.currentState!;
    expect(st.controllerAt(0).isRich, isFalse, reason: 'DOM-non-equivalent -> forced source mode (contract)');
    expect(st.controllerAt(0).forcedByUser, isFalse);
    await tester.tap(find.byKey(const ValueKey('html-0')), warnIfMissed: false); await tester.pump();
    expect(st.controllerAt(0).isRich, isFalse, reason: 'forced field cannot be switched back to rich by the toggle');
    expect(st.controllerAt(0).save(), forced, reason: 'untouched forced field keeps original bytes');
    expect(find.text('HTML 원문 편집'), findsNothing, reason: 'toolbar chip only when that field has focus');
    // flag ON: rich -> source -> rich round trip on an untouched field is lossless
    expect(st.controllerAt(1).isRich, isTrue);
    final rich1 = st.controllerAt(1);
    await tester.tap(find.byKey(const ValueKey('html-1'))); await tester.pump(); await tester.pump();
    expect(st.controllerAt(1).isRich, isFalse); expect(st.controllerAt(1).forcedByUser, isTrue); expect(st.controllerAt(1).save(), back);
    expect(identical(st.controllerAt(1), rich1), isFalse);
    await tester.tap(find.byKey(const ValueKey('html-1'))); await tester.pump(); await tester.pump();
    expect(st.controllerAt(1).isRich, isTrue); expect(st.controllerAt(1).save(), back);
    await shot(tester, 'anki_03_html_badge_forced_and_voluntary');
    L('A6 ok');
  });

  testWidgets('A7 voluntary HTML toggle is OFF by default (badge inert)', (tester) async {
    await pumpNote(tester);
    final st = key.currentState!;
    await tester.tap(find.byKey(const ValueKey('html-0')), warnIfMissed: false); await tester.pump();
    expect(st.controllerAt(0).isRich, isTrue, reason: 'default: contract behaviour only (flag off)');
    L('A7 ok');
  });

  testWidgets('A8 pending bold (caret only) through the multi-field editor + toolbar click keeps focus and Korean composition marks', (tester) async {
    await pumpNote(tester, fields: const [NoteFieldSpec('Front', '안녕 '), NoteFieldSpec('Back', '')]);
    final st = key.currentState!; final c = st.controllerAt(0);
    await tester.tap(find.descendant(of: find.byKey(const ValueKey('field-0')), matching: find.byType(EditableText))); await tester.pump();
    c.selection = const TextSelection.collapsed(offset: 3); await tester.pump();
    await tester.tap(find.byKey(const ValueKey('tb-bold'))); await tester.pump();
    expect(st.focusedIndex, 0, reason: 'toolbar click must not steal focus');
    ime(tester, '안녕 ㅎ', 3, 4); await tester.pump(); ime(tester, '안녕 한', 3, 4); await tester.pump(); ime(tester, '안녕 한', 0, 0, caret: 4); await tester.pump();
    ime(tester, '안녕 한ㄱ', 4, 5); await tester.pump(); ime(tester, '안녕 한글', 4, 5); await tester.pump(); ime(tester, '안녕 한글', 0, 0, caret: 5); await tester.pump();
    expect(c.toHtml(), '안녕 <b>한글</b>');
    L('A8 ok');
  });

  testWidgets('A9 floating surfaces (colour palette, toolbar tooltip, raw-chip tooltip) share ONE decoration: Anki Popover border-subtle + elevation(8), light and dark; focus untouched', (tester) async {
    for (final k in [AnkiColors.light, AnkiColors.darkTheme]) {
      final want = ankiFloating(k);
      expect(want.boxShadow!.length, 3); expect(want.border, Border.all(color: k.borderSubtle)); expect(want.color, k.canvasElevated);
      await pumpNote(tester, colors: k, fields: const [NoteFieldSpec('Front', '가나다라<ul><li>목록</li></ul>')]);
      final st = key.currentState!; final c = st.controllerAt(0);
      await tester.tap(find.byType(EditableText)); await tester.pump();
      final focused = st.focusNodeAt(0).hasFocus; expect(focused, isTrue);
      // palette
      await tester.tap(find.byKey(const ValueKey('tb-color'))); await tester.pump();
      final pal = tester.widget<Container>(find.byKey(const ValueKey('palette')));
      expect(pal.decoration, want, reason: 'palette uses the shared floating decoration (${k.dark ? 'dark' : 'light'})');
      expect(st.focusNodeAt(0).hasFocus, isTrue, reason: 'opening the palette keeps the field focused');
      await tester.tap(find.byKey(const ValueKey('swatch-none'))); await tester.pump();
      // toolbar tooltip (hover)
      final g = await tester.createGesture(kind: PointerDeviceKind.mouse); await g.addPointer(location: Offset.zero);
      await g.moveTo(tester.getCenter(find.byKey(const ValueKey('tb-bold')))); await tester.pump(const Duration(milliseconds: 700)); await tester.pump();
      final tips = tester.widgetList<Tooltip>(find.byType(Tooltip)).where((t) => (t.message ?? '').contains('Ctrl')).toList();
      expect(tips, isNotEmpty); expect(tips.first.decoration, want, reason: 'toolbar tooltip uses the shared decoration');
      expect(st.focusNodeAt(0).hasFocus, isTrue, reason: 'tooltip does not steal focus');
      await g.moveTo(Offset.zero); await tester.pump(const Duration(milliseconds: 300)); await tester.pump();
      // raw chip tooltip
      final chip = tester.widgetList<Tooltip>(find.byType(Tooltip)).firstWhere((t) => (t.message ?? '').startsWith('<ul'));
      expect(chip.decoration, want, reason: 'raw-chip tooltip uses the shared decoration');
      expect(c.toHtml(), '가나다라<ul><li>목록</li></ul>');
      await g.removePointer();
    }
    L('A9 ok');
  });
}
