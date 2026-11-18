import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:editor_proto/field_codec.dart';
import 'package:editor_proto/corpus.dart';
import 'package:editor_proto/proto_editable.dart';

final log = StringBuffer();
void L(String s) { log.writeln(s); print(s); }
Future<void> loadFont() async {
  final fl = FontLoader('NanumGothic')..addFont(Future.value(ByteData.sublistView(File('../../fonts/NanumGothic.ttf').readAsBytesSync())));
  await fl.load();
}

void main() {
  tearDownAll(() => File('../evidence/b-editabletext.txt').writeAsStringSync(log.toString()));

  test('B1 model round trip (corpus -> controller -> html)', () {
    var same = 0, sem = 0;
    corpus.forEach((n, h) { final c = FieldController(h); final o = c.toHtml(); if (o == serializeField(parseField(h))) same++; else L('B1 DIFF $n: $o'); if (parseField(o).toString() == parseField(h).toString()) sem++; });
    L('B1 EditableText model preserves codec output for $same/${corpus.length}; semantic $sem/${corpus.length}');
    expect(same, corpus.length);
  });

  testWidgets('B2 render + golden', (tester) async {
    await loadFont();
    final c = FieldController('<b>굵은 한글</b> <i>기울임</i> <u>밑줄</u> {{c1::서울::수도}} \\(x^2\\) <img src="paste-1.png"> [sound:r.m4a] <span style="color: #ff0000">빨강</span> H<sub>2</sub>O');
    final fn = FocusNode();
    await tester.pumpWidget(MaterialApp(theme: ThemeData(fontFamily: 'NanumGothic'), home: Scaffold(body: Center(child: RepaintBoundary(child: EditableField(c, fn))))));
    await tester.pumpAndSettle();
    await expectLater(find.byType(EditableField), matchesGoldenFile('goldens/editable_b2.png'));
    L('B2 golden written goldens/editable_b2.png');
  });

  testWidgets('B3 token atomic backspace (WidgetSpan = 1 char)', (tester) async {
    final c = FieldController('ab<img src="x.png">cd'); final fn = FocusNode();
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: EditableField(c, fn))));
    await tester.tap(find.byType(EditableText)); await tester.pump();
    c.selection = const TextSelection.collapsed(offset: 3);
    await tester.sendKeyEvent(LogicalKeyboardKey.backspace); await tester.pump();
    L('B3 after backspace: ${c.toHtml()}');
    expect(c.toHtml(), 'abcd');
  });

  testWidgets('B4 built-in UndoHistoryController vs style ranges (desync?) + custom snapshot undo', (tester) async {
    final c = FieldController('hello'); final fn = FocusNode(); final u = UndoHistoryController();
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: EditableField(c, fn, undo: u))));
    await tester.tap(find.byType(EditableText)); await tester.pump();
    c.selection = const TextSelection.collapsed(offset: 5);
    tester.testTextInput.updateEditingValue(const TextEditingValue(text: 'hello world', selection: TextSelection.collapsed(offset: 11)));
    await tester.pump(const Duration(milliseconds: 600));
    c.selection = const TextSelection(baseOffset: 0, extentOffset: 5); c.toggle(RK.bold, c.selection); await tester.pump();
    L('B4 after typing+bold: ${c.toHtml()}  undoValue.canUndo=${u.value.canUndo}');
    // delete 'hello ' (style range shrinks), then built-in undo
    tester.testTextInput.updateEditingValue(const TextEditingValue(text: 'world', selection: TextSelection.collapsed(offset: 0)));
    await tester.pump(const Duration(milliseconds: 600));
    L('B4 after deleting "hello ": ${c.toHtml()} ranges=${c.ranges.map((r) => '${r.k.name}[${r.s},${r.e})').toList()}');
    u.undo(); await tester.pump();
    L('B4 built-in undo -> text="${c.text}" html=${c.toHtml()} ranges=${c.ranges.map((r) => '${r.k.name}[${r.s},${r.e})').toList()}  (expected <b>hello</b> world)');
    // custom snapshot undo
    final c2 = FieldController('<b>hello</b> world'); final h = <(String, List<R>, List<Seg>, TextSelection)>[c2.snap()];
    c2.value = const TextEditingValue(text: ' world', selection: TextSelection.collapsed(offset: 0)); h.add(c2.snap());
    L('B4 custom: after delete ${c2.toHtml()}');
    c2.restore(h.first);
    L('B4 custom snapshot restore -> ${c2.toHtml()}');
    expect(c2.toHtml(), '<b>hello</b> world');
  });

  testWidgets('B5 cloze wrap + inherit style at insertion', (tester) async {
    final c = FieldController('서울은 <b>수도</b>');
    c.value = TextEditingValue(text: '{{c1::서울}}은 수도'.replaceFirst('수도', '수도'), selection: const TextSelection.collapsed(offset: 0));
    L('B5 plain-text wrap result html: ${c.toHtml()}');
    final c3 = FieldController('<b>굵게</b>'); c3.value = const TextEditingValue(text: '굵게한', selection: TextSelection.collapsed(offset: 3));
    L('B5 typing at end of bold inherits bold: ${c3.toHtml()}');
  });

  testWidgets('B6 Korean IME composing replay through TextInput channel', (tester) async {
    final c = FieldController('<b>굵</b>'); final fn = FocusNode();
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: EditableField(c, fn))));
    await tester.tap(find.byType(EditableText)); await tester.pump();
    c.selection = const TextSelection.collapsed(offset: 1); await tester.pump();
    void ime(String t, int cs, int ce) => tester.testTextInput.updateEditingValue(TextEditingValue(text: t, selection: TextSelection.collapsed(offset: ce), composing: ce > cs ? TextRange(start: cs, end: ce) : TextRange.empty));
    for (final st in [('굵ㅎ', 1, 2), ('굵하', 1, 2), ('굵한', 1, 2), ('굵한ㄱ', 2, 3), ('굵한그', 2, 3), ('굵한글', 2, 3), ('굵한글', 0, 0)]) { ime(st.$1, st.$2, st.$3); await tester.pump(); L('B6 ${st.$1} -> html=${c.toHtml()} ranges=${c.ranges.map((r) => '${r.k.name}[${r.s},${r.e})').toList()}'); }
    expect(c.text, '굵한글');
    expect(c.toHtml(), '<b>굵한글</b>');
  });
}
