// SPDX-FileCopyrightText: 2026 Hatto Social contributors
//
// SPDX-License-Identifier: AGPL-3.0-or-later

// v0 "minimum usable editor" widget tests + per-use-case screenshots (../screenshots/*.png).
import 'dart:io';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hatto_desktop/editor/field_codec.dart';
import 'package:hatto_desktop/editor/proto_editable.dart';
import 'util.dart';

final log = StringBuffer();
void L(String s) { log.writeln(s); print(s); }

Future<void> focusAt(WidgetTester tester, FieldController c, int caret) async {
  await tester.tap(find.byType(EditableText)); await tester.pump();
  c.selection = TextSelection.collapsed(offset: caret); await tester.pump();
}

void main() {
  setUpAll(() async { await loadFont(); Directory(shotDir).createSync(recursive: true); });
  tearDownAll(() {
    Directory('test_out/evidence').createSync(recursive: true);
    File('test_out/evidence/b-v0-widget-tests.txt').writeAsStringSync(log.toString());
  });

  testWidgets('01 overlapping marks render + roundtrip', (tester) async {
    final c = FieldController('<b>굵게 <i>굵고 기울임 <u>밑줄까지</u></i></b> 보통 H<sub>2</sub>O x<sup>2</sup> <span style="color: #d32f2f">빨강 <b>굵은빨강</b></span>'); final fn = FocusNode();
    expect(c.isRich, isTrue);
    await pumpEditor(tester, c, fn, caption: '① 서식 겹치기 (굵게·기울임·밑줄·위/아래첨자·글자색)');
    log.writeln('01 marks: ${c.marksDump()}');
    expect(c.flagsAt(4), 3); // bold+italic
    expect(c.save(), c.original);
    expect(canonFlat(c.toHtml()), canonFlat(c.original));
    await shot(tester, '01_overlapping_marks');
  });

  testWidgets('02 toolbar active state follows selection', (tester) async {
    final c = FieldController('plain <b>bold <i>both</i></b> end'); final fn = FocusNode();
    await pumpEditor(tester, c, fn, caption: '② 툴바 활성 표시: "both" 선택 → B, I 활성');
    await tester.tap(find.byType(EditableText)); await tester.pump();
    c.selection = const TextSelection(baseOffset: 11, extentOffset: 15); await tester.pump();
    expect(c.text.substring(11, 15), 'both');
    expect(c.activeMarks.set, {RK.bold, RK.italic});
    c.selection = const TextSelection(baseOffset: 0, extentOffset: 15); await tester.pump();
    expect(c.activeMarks.set, isEmpty, reason: 'mixed selection -> not all bold');
    c.selection = const TextSelection(baseOffset: 11, extentOffset: 15); await tester.pump();
    await shot(tester, '02_toolbar_active_state');
    // click toolbar B: toggles off bold for selection; toolbar click must keep focus + selection
    await tester.tap(find.byKey(const ValueKey('tb-bold'))); await tester.pump();
    expect(fn.hasFocus, isTrue); expect(c.selection, const TextSelection(baseOffset: 11, extentOffset: 15));
    expect(c.save(), 'plain <b>bold </b><i>both</i> end');
    await tester.tap(find.byKey(const ValueKey('tb-undo'))); await tester.pump();
    expect(c.save(), c.original, reason: 'undo restores; clean => original bytes');
  });

  testWidgets('03 keyboard shortcuts', (tester) async {
    final c = FieldController('abcdef'); final fn = FocusNode();
    await pumpEditor(tester, c, fn);
    await tester.tap(find.byType(EditableText)); await tester.pump();
    Future<void> sel(int a, int b) async { c.selection = TextSelection(baseOffset: a, extentOffset: b); await tester.pump(); }
    Future<void> combo(LogicalKeyboardKey k, {bool shift = false, bool meta = false}) async {
      if (meta) await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft); else await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      if (shift) await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(k);
      if (shift) await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      if (meta) await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft); else await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
    }
    await sel(0, 1); await combo(LogicalKeyboardKey.keyB);
    await sel(1, 2); await combo(LogicalKeyboardKey.keyI, meta: true);
    await sel(2, 3); await combo(LogicalKeyboardKey.keyU);
    await sel(3, 4); await combo(LogicalKeyboardKey.equal);                 // sub (Anki)
    await sel(4, 5); await combo(LogicalKeyboardKey.equal, shift: true);    // sup (Anki)
    expect(c.toHtml(), '<b>a</b><i>b</i><u>c</u><sub>d</sub><sup>e</sup>f');
    L('03 shortcuts -> ${c.toHtml()}');
    await sel(0, 6); await combo(LogicalKeyboardKey.keyZ); // undo
    await combo(LogicalKeyboardKey.keyZ, shift: true);     // redo
    expect(c.toHtml(), '<b>a</b><i>b</i><u>c</u><sub>d</sub><sup>e</sup>f');
  });

  testWidgets('04 pending style: toggle -> Korean composing -> commit -> keep typing (Gina gate c)', (tester) async {
    final c = FieldController('안녕 '); final fn = FocusNode();
    await pumpEditor(tester, c, fn, caption: '③-a 굵게 토글 직후(캐럿만, 입력 전): B 활성(pending)');
    await focusAt(tester, c, 3);
    await tester.tap(find.byKey(const ValueKey('tb-bold'))); await tester.pump();
    expect(c.pending?.has(RK.bold), isTrue); expect(fn.hasFocus, isTrue);
    await shot(tester, '03a_pending_style_before_korean_input');
    final trail = <String>[];
    // composing: ㅎ 하 한 | 한ㄱ 한그 한글 | commit
    for (final st in [('안녕 ㅎ', 3, 4), ('안녕 하', 3, 4), ('안녕 한', 3, 4), ('안녕 한ㄱ', 4, 5), ('안녕 한그', 4, 5), ('안녕 한글', 4, 5), ('안녕 한글', 0, 0)]) {
      ime(tester, st.$1, st.$2, st.$3); await tester.pump(); trail.add('${st.$1}: ${c.save()}');
      expect(c.pending, isNotNull, reason: 'IME composing must not clear pending');
    }
    L('04 composing trail:\n  ${trail.join('\n  ')}');
    expect(c.toHtml(), '안녕 <b>한글</b>');
    // IME-driven selection-only changes must not clear pending either
    c.selection = const TextSelection.collapsed(offset: 5); await tester.pump(); expect(c.pending, isNotNull);
    // continue typing: plain char, then another composition
    ime(tester, '안녕 한글 ', 0, 0, caret: 6); await tester.pump();
    for (final st in [('안녕 한글 ㅇ', 6, 7), ('안녕 한글 이', 6, 7), ('안녕 한글 입', 6, 7), ('안녕 한글 입ㄹ', 7, 8), ('안녕 한글 입력', 7, 8), ('안녕 한글 입력', 0, 0)]) { ime(tester, st.$1, st.$2, st.$3, caret: st.$3 == 0 ? 8 : null); await tester.pump(); }
    L('04 final: ${c.marksDump()}  html=${c.toHtml()}');
    expect(c.toHtml(), '안녕 <b>한글 입력</b>');
    expect(c.pending?.has(RK.bold), isTrue);
    await shot(tester, '03b_pending_style_after_korean_input');
    // explicit user caret move clears pending: arrow key, then type -> not bold
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft); await tester.pump();
    expect(c.pending, isNull);
  });

  testWidgets('05 pending cleared only by explicit user caret moves (click/arrows/Home/End); toggle off at bold edge', (tester) async {
    final c = FieldController('<b>굵</b>'); final fn = FocusNode();
    await pumpEditor(tester, c, fn);
    await focusAt(tester, c, 1);
    // at end of bold text, inherited bold -> toggle bold = pending "bold off"
    expect(c.activeMarks.has(RK.bold), isTrue);
    await tester.tap(find.byKey(const ValueKey('tb-bold'))); await tester.pump();
    expect(c.activeMarks.has(RK.bold), isFalse); expect(c.pending, isNotNull);
    ime(tester, '굵ㅎ', 1, 2); await tester.pump(); ime(tester, '굵한', 1, 2); await tester.pump(); ime(tester, '굵한', 0, 0); await tester.pump();
    expect(c.toHtml(), '<b>굵</b>한');
    for (final k in [LogicalKeyboardKey.arrowRight, LogicalKeyboardKey.home, LogicalKeyboardKey.end, LogicalKeyboardKey.arrowUp]) {
      await tester.tap(find.byKey(const ValueKey('tb-italic'))); await tester.pump();
      expect(c.pending, isNotNull, reason: 'toolbar click sets pending');
      await tester.sendKeyEvent(k); await tester.pump();
      expect(c.pending, isNull, reason: '${k.keyLabel} clears pending');
    }
    await tester.tap(find.byKey(const ValueKey('tb-italic'))); await tester.pump();
    await tester.tapAt(tester.getTopLeft(find.byType(EditableText)) + const Offset(2, 2)); await tester.pump();
    expect(c.pending, isNull, reason: 'click in field clears pending');
  });

  testWidgets('06 img token: thumbnail, atomic caret, IME outside, whole delete', (tester) async {
    final dir = Directory.systemTemp.createTempSync('hatto-media');
    await tester.runAsync(() => makePng('${dir.path}/cat.png'));
    final c = FieldController('앞 <img src="cat.png"> 뒤 <img src="missing-file.png"> 끝', mediaDir: dir.path); final fn = FocusNode();
    expect(c.atoms.map((a) => a.kind), [TokenKind.img, TokenKind.img]);
    await pumpEditor(tester, c, fn, caption: '④ <img> 원자 토큰: 썸네일(파일 있음) / 자리표시(파일 없음), 커서는 앞뒤만', h: 250);
    await preloadThumbs(tester, c);
    await focusAt(tester, c, 0);
    await shot(tester, '04_img_thumbnail_token');
    // caret moves over token with ONE arrow press each (no inner positions)
    c.selection = const TextSelection.collapsed(offset: 2); await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight); await tester.pump();
    expect(c.selection.baseOffset, 3, reason: 'one arrow press crosses the whole token');
    // Korean composing right after token: composed text outside the token, token intact
    final base0 = c.text; ime(tester, base0.replaceRange(3, 3, 'ㅎ'), 3, 4); await tester.pump(); ime(tester, base0.replaceRange(3, 3, '한'), 3, 4); await tester.pump(); ime(tester, base0.replaceRange(3, 3, '한'), 0, 0, caret: 4); await tester.pump();
    expect(c.atoms.length, 2); expect(c.text.contains('한'), isTrue);
    // backspace right after token deletes it entirely
    c.selection = const TextSelection.collapsed(offset: 3); await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.backspace); await tester.pump();
    expect(c.atoms.length, 1); expect(c.toHtml().contains('cat.png'), isFalse);
    expect(c.toHtml().contains('missing-file.png'), isTrue);
    c.undo(); await tester.pump();
    expect(c.atoms.length, 2, reason: 'undo restores whole token');
    expect(c.toHtml().contains('<img src="cat.png">'), isTrue);
    // forward delete before token
    c.selection = const TextSelection.collapsed(offset: 2); await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.delete); await tester.pump();
    expect(c.atoms.length, 1);
    // insert image from toolbar
    c.undo(); await tester.pump();
    c.selection = const TextSelection.collapsed(offset: 0); await tester.pump();
    await tester.tap(find.byKey(const ValueKey('tb-img'))); await tester.pump();
    expect(c.atoms.length, 3); expect(c.toHtml().startsWith('<img src="paste-new.png">'), isTrue);
  });

  testWidgets('07 math/cloze/sound are PLAIN TEXT in editor, codec still round-trips', (tester) async {
    const h = '{{c1::서울::수도}}는 \\(x^2+1\\) 그리고 [sound:rec-1.m4a] 와 \\[\\sum_k k\\]';
    final c = FieldController(h); final fn = FocusNode();
    expect(c.isRich, isTrue); expect(c.atoms, isEmpty);
    expect(c.text, h);
    await pumpEditor(tester, c, fn, caption: '⑤ 수식·cloze·[sound:]는 편집기에서 평문(토큰 아님)');
    await shot(tester, '05_math_cloze_sound_plain_text');
    expect(c.save(), h);
    // edit inside the math text works like any text
    final mp = c.text.indexOf('x^'); await focusAt(tester, c, mp);
    ime(tester, c.text.replaceRange(mp, mp, 'ZZ'), 0, 0, caret: mp + 2); await tester.pump();
    expect(c.toHtml().contains('\\(ZZx^'), isTrue);
    // legacy token mode of the codec still round-trips these
    final legacy = parseField(h);
    expect(legacy.where((s) => s.isToken).length, 3);
    expect(serializeField(legacy), h.replaceAll('\\[\\sum_k k\\]', '\\[\\sum_k k\\]'));
    // editor path round trip (specials as text): lt in math
    final c2 = FieldController('if \\(a < b\\) then'); expect(c2.text, 'if \\(a < b\\) then'); expect(c2.atoms, isEmpty);
    c2.value = c2.value.copyWith(text: 'if \\(a < b\\) then!', selection: const TextSelection.collapsed(offset: 19)); // edit => encode
    expect(c2.save(), 'if \\(a &lt; b\\) then!');
  });

  testWidgets('08 raw chip: tooltip with source, byte-exact, delete/move only, no warning', (tester) async {
    const raw1 = '<ul class=x><li>가<li>나</ul>'; const raw2 = '<table border=1><tr><td>1</td></table>';
    final h = '목록: $raw1 그리고 $raw2 끝';
    final c = FieldController(h); final fn = FocusNode();
    expect(c.isRich, isTrue); expect(c.atoms.map((a) => a.token), [raw1, raw2]);
    await pumpEditor(tester, c, fn, caption: '⑥ 범위 밖 HTML(ul/table): 읽기 전용 raw 칩 + 툴팁(원문). 경고 없음', h: 290);
    await focusAt(tester, c, 0);
    expect(find.descendant(of: find.byType(FieldEditor), matching: find.textContaining('경고')), findsNothing);
    // hover tooltip (mouse)
    final chip = find.byWidgetPredicate((w) => w is Tooltip && (w.message ?? '').startsWith('<ul'));
    expect(chip, findsOneWidget);
    final g = await tester.createGesture(kind: PointerDeviceKind.mouse); await g.addPointer(location: Offset.zero); addTearDown(g.removePointer);
    await g.moveTo(tester.getCenter(chip)); await tester.pump(const Duration(milliseconds: 100)); await tester.pump(const Duration(milliseconds: 600)); await tester.pump(const Duration(milliseconds: 400));
    expect(find.text(raw1), findsOneWidget, reason: 'tooltip shows source');
    await shot(tester, '06_raw_chip_tooltip');
    await g.moveTo(Offset.zero); await tester.pump(const Duration(seconds: 2));
    // typing next to chips does not touch bytes; save has both raw bytes verbatim
    c.selection = const TextSelection.collapsed(offset: 3); await tester.pump();
    ime(tester, c.text.replaceRange(3, 3, '추가'), 0, 0, caret: 5); await tester.pump();
    final out = c.save();
    expect(out.contains(raw1) && out.contains(raw2), isTrue); L('08 after edit: $out');
    // delete whole chip (backspace after it), undo, then MOVE via cut/paste
    final chipPos = c.text.indexOf('\uFFFC');
    c.selection = TextSelection.collapsed(offset: chipPos + 1); await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.backspace); await tester.pump();
    expect(c.save().contains(raw1), isFalse); expect(c.save().contains(raw2), isTrue);
    c.undo(); await tester.pump(); expect(c.save().contains(raw1), isTrue);
    // move: cut chip, paste at end (clipboard mocked)
    String? clip;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') { clip = (call.arguments as Map)['text'] as String; return null; }
      if (call.method == 'Clipboard.getData') return <String, dynamic>{'text': clip};
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
    c.selection = TextSelection(baseOffset: chipPos, extentOffset: chipPos + 1); await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft); await tester.sendKeyEvent(LogicalKeyboardKey.keyX); await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft); await tester.pump();
    expect(c.atoms.length, 1); expect(clip, raw1);
    c.selection = TextSelection.collapsed(offset: c.text.length); await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft); await tester.sendKeyEvent(LogicalKeyboardKey.keyV); await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft); await tester.pump(); await tester.pump();
    expect(c.atoms.map((a) => a.token), [raw2, raw1], reason: 'moved chip keeps bytes, now after raw2');
  });

  testWidgets('09 source-edit fallback (non-equivalent field) + sanitizer on save', (tester) async {
    const h = '<div>one</div>\n<div>two</div>\n<script>alert(1)</script><b>x</b>';
    final c = FieldController(h); final fn = FocusNode();
    expect(c.isRich, isFalse); L('09 reasons: ${c.analysis.reasons}');
    await pumpEditor(tester, c, fn, caption: '⑦ decode→encode가 DOM 동치가 아닌 필드 → "HTML 원문 편집" (평문)', h: 280);
    expect(c.text, h);
    expect(find.text('HTML 원문 편집'), findsOneWidget);
    await shot(tester, '07_html_source_edit_fallback');
    expect(c.save(), h, reason: 'untouched -> original bytes (even the script)');
    // toolbar marks disabled in source mode
    await focusAt(tester, c, 0);
    c.toggleMark(RK.bold); expect(c.dirty, isFalse);
    // edit then save -> stand-in sanitizer removes <script>, reports count
    c.value = c.value.copyWith(text: '${c.text}!', selection: TextSelection.collapsed(offset: c.text.length + 1)); await tester.pump();
    final out = c.save();
    expect(out.contains('<script'), isFalse); expect(c.lastSaveRemoved, 1);
    expect(out.contains('<div>one</div>\n<div>two</div>'), isTrue); L('09 saved: ${jsonLike(out)} removed=${c.lastSaveRemoved}');
    // clean source edit: no removal => bytes as typed
    final c2 = FieldController('a\n<b>b</b>'); c2.value = c2.value.copyWith(text: 'a\n<b>b</b>c'); expect(c2.save(), 'a\n<b>b</b>c'); expect(c2.lastSaveRemoved, 0);
  });

  testWidgets('10 color picker + color on selection + pending color', (tester) async {
    final c = FieldController('가나다라마바'); final fn = FocusNode();
    await pumpEditor(tester, c, fn, caption: '⑧ 글자색 팔레트 ("나다" 선택 상태에서 열림)', h: 270);
    await tester.tap(find.byType(EditableText)); await tester.pump();
    c.selection = const TextSelection(baseOffset: 1, extentOffset: 3); await tester.pump();
    await tester.tap(find.byKey(const ValueKey('tb-color'))); await tester.pump();
    expect(find.byKey(const ValueKey('palette')), findsOneWidget);
    await shot(tester, '08_color_picker_open');
    await tester.tap(find.byKey(const ValueKey('swatch-#d32f2f'))); await tester.pump();
    expect(find.byKey(const ValueKey('palette')), findsNothing);
    expect(c.toHtml(), '가<span style="color: #d32f2f">나다</span>라마바');
    expect(c.activeMarks.c, '#d32f2f');
    // pending color at caret, Korean after it
    c.selection = const TextSelection.collapsed(offset: 6); await tester.pump();
    await tester.tap(find.byKey(const ValueKey('tb-color'))); await tester.pump();
    await tester.tap(find.byKey(const ValueKey('swatch-#1565c0'))); await tester.pump();
    ime(tester, '가나다라마바ㅎ', 6, 7); await tester.pump(); ime(tester, '가나다라마바한', 6, 7); await tester.pump(); ime(tester, '가나다라마바한', 0, 0); await tester.pump();
    expect(c.toHtml(), '가<span style="color: #d32f2f">나다</span>라마바<span style="color: #1565c0">한</span>');
    await tester.tap(find.byKey(const ValueKey('tb-color'))); await tester.pump();
    await tester.tap(find.byKey(const ValueKey('swatch-none'))); await tester.pump();
    c.selection = const TextSelection(baseOffset: 1, extentOffset: 3); await tester.pump();
    await tester.tap(find.byKey(const ValueKey('tb-color'))); await tester.pump();
    await tester.tap(find.byKey(const ValueKey('swatch-none'))); await tester.pump();
    expect(c.toHtml().contains('#d32f2f'), isFalse);
  });

  testWidgets('11 undo/redo coherent with marks, tokens and typing', (tester) async {
    final c = FieldController('ab<img src="x.png">cd'); final fn = FocusNode();
    await pumpEditor(tester, c, fn);
    await tester.tap(find.byType(EditableText)); await tester.pump();
    c.selection = const TextSelection(baseOffset: 0, extentOffset: 2); await tester.pump();
    c.toggleMark(RK.bold); expect(c.toHtml(), '<b>ab</b><img src="x.png">cd');
    c.selection = const TextSelection.collapsed(offset: 4); await tester.pump();
    ime(tester, 'ab\uFFFCcdX', 0, 0, caret: 5); await tester.pump(); ime(tester, 'ab\uFFFCcdXY', 0, 0, caret: 6); await tester.pump();
    expect(c.toHtml(), '<b>ab</b><img src="x.png">cdXY');
    c.selection = const TextSelection.collapsed(offset: 3); await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.backspace); await tester.pump(); // delete token
    expect(c.toHtml(), '<b>ab</b>cdXY');
    expect(c.undo(), isTrue); expect(c.toHtml(), '<b>ab</b><img src="x.png">cdXY');
    expect(c.undo(), isTrue); expect(c.toHtml(), '<b>ab</b><img src="x.png">cd', reason: 'XY typed together coalesce into one undo step');
    expect(c.undo(), isTrue); expect(c.toHtml(), 'ab<img src="x.png">cd');
    expect(c.dirty, isFalse); expect(c.save(), c.original);
    expect(c.redo(), isTrue); expect(c.toHtml(), '<b>ab</b><img src="x.png">cd');
    expect(c.redo(), isTrue); expect(c.redo(), isTrue); expect(c.toHtml(), '<b>ab</b>cdXY');
    // keyboard undo (Ctrl+Z / Ctrl+Y)
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft); await tester.sendKeyEvent(LogicalKeyboardKey.keyZ); await tester.pump();
    expect(c.toHtml(), '<b>ab</b><img src="x.png">cdXY');
    await tester.sendKeyEvent(LogicalKeyboardKey.keyY); await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft); await tester.pump();
    expect(c.toHtml(), '<b>ab</b>cdXY');
    // pending style also coherent: toggle on undo history
    c.selection = const TextSelection.collapsed(offset: 6); c.toggleMark(RK.italic); ime(tester, '${c.text}i', 0, 0, caret: 7); await tester.pump();
    expect(c.toHtml(), '<b>ab</b>cdXY<i>i</i>'); c.undo(); expect(c.toHtml(), '<b>ab</b>cdXY');
  });

  testWidgets('12 paste: plain text, internal clip keeps marks/atoms, HTML paste hook sanitises', (tester) async {
    final c = FieldController('<b>굵게</b> 끝'); final fn = FocusNode();
    await pumpEditor(tester, c, fn);
    String? clip; tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') { clip = (call.arguments as Map)['text'] as String; return null; }
      if (call.method == 'Clipboard.getData') return <String, dynamic>{'text': clip};
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
    await focusAt(tester, c, 4);
    clip = 'line1\r\nline2 <tag> & \uFFFC';
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft); await tester.sendKeyEvent(LogicalKeyboardKey.keyV); await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft); await tester.pump(); await tester.pump();
    expect(c.toHtml(), '<b>굵게</b> 끝line1<br>line2 &lt;tag&gt; &amp; ');
    // copy a marked range and paste it elsewhere: marks preserved
    c.selection = const TextSelection(baseOffset: 0, extentOffset: 2); await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft); await tester.sendKeyEvent(LogicalKeyboardKey.keyC); await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft); await tester.pump();
    expect(clip, '굵게');
    c.selection = const TextSelection.collapsed(offset: 0); await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft); await tester.sendKeyEvent(LogicalKeyboardKey.keyV); await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft); await tester.pump(); await tester.pump();
    expect(c.toHtml().startsWith('<b>굵게굵게</b> 끝'), isTrue);
    // HTML paste hook (not wired to system clipboard: needs super_clipboard; see report)
    final c2 = FieldController('x'); c2.selection = const TextSelection.collapsed(offset: 1);
    final removed = c2.pasteHtml('<b>B</b><i onclick="evil()">I</i><script>1</script><img src="p.png"><ul><li>l</li></ul>');
    L('12 pasteHtml removed=$removed -> ${c2.toHtml()}');
    expect(removed, 3); expect(c2.toHtml(), 'x<b>B</b><i>I</i><ul><li>l</li></ul>');
  });
}

String jsonLike(String s) => s.replaceAll('\n', '\\n');
