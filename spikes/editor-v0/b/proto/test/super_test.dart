import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_test_robots/flutter_test_robots.dart';
import 'package:super_editor/super_editor.dart';
import 'package:super_editor/super_editor_test.dart';
import 'package:editor_proto/field_codec.dart';
import 'package:editor_proto/corpus.dart';
import 'package:editor_proto/proto_super.dart';

final log = StringBuffer();
void L(String s) { log.writeln(s); print(s); }

Future<void> loadFont() async {
  final nanum = File('/usr/share/fonts/truetype/nanum/NanumGothic.ttf').existsSync()
      ? File('/usr/share/fonts/truetype/nanum/NanumGothic.ttf')
      : File('../../fonts/NanumGothic.ttf');
  final fl = FontLoader('NanumGothic')..addFont(Future.value(ByteData.sublistView(nanum.readAsBytesSync())));
  await fl.load();
}

void main() {
  tearDownAll(() => File('../evidence/b-super_editor.txt').writeAsStringSync(log.toString()));

  test('A1 model round trip (corpus -> AttributedText -> html)', () {
    var same = 0, semantic = 0;
    corpus.forEach((name, html) {
      final f = SuperField(html);
      final out = f.toHtml();
      final ok = out == serializeField(parseField(html));
      final sem = parseField(out).toString() == parseField(html).toString();
      if (ok) same++; if (sem) semantic++;
      if (!ok) L('A1 DIFF $name: ${serializeField(parseField(html))} -> $out');
    });
    L('A1 super_editor model preserves codec output for $same/${corpus.length}; semantic-equal $semantic/${corpus.length}');
    expect(same, corpus.length);
  });

  test('A1b super_editor built-in toHtml() output (what we would get without custom serializer)', () {
    final f = SuperField('<b>굵게</b> and <i>it</i> line1<br>line2');
    L('A1b built-in Document.toHtml(): ${f.doc.toHtml()}');
  });

  testWidgets('A2 render + golden (Korean font, styles, tokens, cloze text)', (tester) async {
    await loadFont();
    final f = SuperField('<b>굵은 한글</b> <i>기울임</i> <u>밑줄</u> {{c1::서울::수도}} \\(x^2\\) <img src="paste-1.png"> [sound:r.m4a] <span style="color: #ff0000">빨강</span> H<sub>2</sub>O');
    await tester.pumpWidget(MaterialApp(theme: ThemeData(fontFamily: 'NanumGothic'), home: Scaffold(body: Center(child: RepaintBoundary(child: superFieldWidget(f))))));
    await tester.pumpAndSettle();
    await expectLater(find.byType(SuperEditor), matchesGoldenFile('goldens/super_a2.png'));
    L('A2 golden written goldens/super_a2.png');
  });

  testWidgets('A3 token atomic backspace, caret never inside token', (tester) async {
    final f = SuperField('ab<img src="x.png">cd');
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: superFieldWidget(f))));
    await tester.placeCaretInParagraph('p', 3); // right after the token (index 2 is token)
    await tester.pressBackspace();
    L('A3 after backspace html=${f.toHtml()} (token removed whole: ${!f.toHtml().contains('img')})');
    expect(f.toHtml().contains('img'), false);
    expect(f.toHtml(), 'abcd');
  });

  testWidgets('A4 undo/redo of typing and format toggle', (tester) async {
    final f = SuperField('hello');
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: superFieldWidget(f))));
    await tester.placeCaretInParagraph('p', 5);
    await tester.typeImeText(' world');
    L('A4 typed: ${f.toHtml()}');
    // bold toggle on 'hello'
    f.editor.execute([ToggleTextAttributionsRequest(documentRange: DocumentSelection(base: DocumentPosition(nodeId: 'p', nodePosition: const TextNodePosition(offset: 0)), extent: DocumentPosition(nodeId: 'p', nodePosition: const TextNodePosition(offset: 5))), attributions: {boldAttribution})]);
    await tester.pump();
    L('A4 bold: ${f.toHtml()}');
    f.editor.undo(); await tester.pump();
    L('A4 undo#1: ${f.toHtml()}');
    f.editor.undo(); await tester.pump();
    L('A4 undo#2: ${f.toHtml()}');
    f.editor.redo(); await tester.pump();
    L('A4 redo#1: ${f.toHtml()}');
  });

  testWidgets('A5 cloze wrap via selection (Ctrl+Shift+C equivalent)', (tester) async {
    final f = SuperField('서울은 수도');
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: superFieldWidget(f))));
    DocumentPosition p(int o) => DocumentPosition(nodeId: 'p', nodePosition: TextNodePosition(offset: o));
    // wrap [0,2) -> {{c1::서울}}
    f.editor.execute([
      InsertTextRequest(documentPosition: p(2), textToInsert: '}}', attributions: {}),
      InsertTextRequest(documentPosition: p(0), textToInsert: '{{c1::', attributions: {}),
    ]);
    L('A5 cloze: ${f.toHtml()}');
    expect(f.toHtml(), '{{c1::서울}}은 수도');
    f.editor.undo(); await tester.pump();
    L('A5 undo (one step?): ${f.toHtml()}');
  });

  testWidgets('A6 Korean IME composing replay (Linux-style delta sequence)', (tester) async {
    final f = SuperField('');
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: superFieldWidget(f))));
    await tester.placeCaretInParagraph('p', 0);
    final cl = imeClientGetter();
    L('A6 initial IME value: ${cl.currentTextEditingValue}');
    // helper: content-space edit with composing range; prefix = serializer prefix length
    Future<void> comp(String oldContent, String newContent, int start, int end, {required bool insertion}) async {
      final cur = cl.currentTextEditingValue!;
      final prefix = cur.text.length - oldContent.length;
      final oldText = cur.text;
      final composing = end > start ? TextRange(start: prefix + start, end: prefix + end) : TextRange.empty;
      final TextEditingDelta d = insertion
          ? TextEditingDeltaInsertion(oldText: oldText, textInserted: newContent.substring(start, end), insertionOffset: prefix + start, selection: TextSelection.collapsed(offset: prefix + end), composing: composing)
          : TextEditingDeltaReplacement(oldText: oldText, replacementText: newContent.substring(start, end), replacedRange: TextRange(start: prefix + start, end: prefix + start + (oldContent.length - start).clamp(0, 1)), selection: TextSelection.collapsed(offset: prefix + end), composing: composing);
      await tester.ime.sendDeltas([d], getter: imeClientGetter);
    }
    await comp('', 'ㅎ', 0, 1, insertion: true);   L('A6 ㅎ  -> "${f.toHtml()}"');
    await comp('ㅎ', '하', 0, 1, insertion: false); L('A6 하  -> "${f.toHtml()}"');
    await comp('하', '한', 0, 1, insertion: false); L('A6 한  -> "${f.toHtml()}"');
    await comp('한', '한ㄱ', 1, 2, insertion: true); L('A6 한ㄱ -> "${f.toHtml()}"');
    await comp('한ㄱ', '한그', 1, 2, insertion: false); L('A6 한그 -> "${f.toHtml()}"');
    await comp('한그', '한글', 1, 2, insertion: false); L('A6 한글 -> "${f.toHtml()}"');
    final cur = cl.currentTextEditingValue!; final prefix = cur.text.length - 2;
    await tester.ime.sendDeltas([TextEditingDeltaNonTextUpdate(oldText: cur.text, selection: TextSelection.collapsed(offset: prefix + 2), composing: TextRange.empty)], getter: imeClientGetter);
    L('A6 final (commit): "${f.toHtml()}"');
    expect(f.toHtml(), '한글');
  });
}
