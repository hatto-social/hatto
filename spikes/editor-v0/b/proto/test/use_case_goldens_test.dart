// One golden per editor use case, for both spike surfaces.
// The repo-owner decision after this spike is EditableText. super_editor stays as evidence.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_test_robots/flutter_test_robots.dart';
import 'package:super_editor/super_editor.dart';
import 'package:super_editor/super_editor_test.dart';
import 'package:editor_proto/proto_editable.dart';
import 'package:editor_proto/proto_super.dart';

Future<void> loadFont() async {
  final file = File('../../fonts/NanumGothic.ttf');
  expect(file.existsSync(), true, reason: 'bundle spikes/editor-v0/fonts/NanumGothic.ttf');
  final fl = FontLoader('NanumGothic')..addFont(Future.value(ByteData.sublistView(file.readAsBytesSync())));
  await fl.load();
}

Widget stage(String title, Widget editor) => MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(fontFamily: 'NanumGothic'),
      home: Scaffold(
        backgroundColor: const Color(0xfff7f7f7),
        body: Align(
          alignment: Alignment.topLeft,
            child: RepaintBoundary(
            key: const Key('use-case-golden'),
            child: SizedBox(
              width: 500,
              height: 200,
              child: ColoredBox(
                color: Colors.white,
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title, style: const TextStyle(fontFamily: 'NanumGothic', fontSize: 13, color: Color(0xff444444))),
                      const SizedBox(height: 8),
                      editor,
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );

Future<void> shoot(WidgetTester tester, String name, String title, Widget editor) async {
  tester.view.physicalSize = const Size(500, 200);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(stage(title, editor));
  await tester.pumpAndSettle();
  await expectLater(find.byKey(const Key('use-case-golden')), matchesGoldenFile('goldens/use_cases/$name.png'));
}

DocumentPosition at(int offset) => DocumentPosition(nodeId: 'p', nodePosition: TextNodePosition(offset: offset));

void superToggle(SuperField f, int start, int end, Set<Attribution> attrs) {
  f.editor.execute([
    ToggleTextAttributionsRequest(
      documentRange: DocumentSelection(base: at(start), extent: at(end)),
      attributions: attrs,
    ),
  ]);
}

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    await loadFont();
  });

  testWidgets('editable plain field edit', (tester) async {
    final c = FieldController('안녕');
    c.value = const TextEditingValue(text: '안녕하세요', selection: TextSelection.collapsed(offset: 5));
    expect(c.toHtml(), '안녕하세요');
    await shoot(tester, 'plain_editable', 'EditableText · plain field edit', EditableField(c, FocusNode()));
  });

  testWidgets('super plain field edit', (tester) async {
    final f = SuperField('안녕');
    f.editor.execute([
      InsertTextRequest(documentPosition: at(2), textToInsert: '하세요', attributions: {}),
    ]);
    expect(f.toHtml(), '안녕하세요');
    await shoot(tester, 'plain_super', 'super_editor · plain field edit', superFieldWidget(SuperField(f.toHtml())));
  });

  testWidgets('editable rich formatting', (tester) async {
    final c = FieldController('굵게 기울임 밑줄 빨강 H2O');
    c.toggle(RK.bold, const TextSelection(baseOffset: 0, extentOffset: 2));
    c.toggle(RK.italic, const TextSelection(baseOffset: 3, extentOffset: 6));
    c.toggle(RK.underline, const TextSelection(baseOffset: 7, extentOffset: 9));
    c.ranges.add(R(RK.color, 10, 12, '#cc0000'));
    c.ranges.add(R(RK.sub, 14, 15));
    c.notifyListeners();
    expect(c.toHtml(), '<b>굵게</b> <i>기울임</i> <u>밑줄</u> <span style="color: #cc0000">빨강</span> H<sub>2</sub>O');
    await shoot(tester, 'rich_editable', 'EditableText · bold italic underline color sub', EditableField(c, FocusNode()));
  });

  testWidgets('super rich formatting', (tester) async {
    final f = SuperField('굵게 기울임 밑줄 빨강 H2O');
    superToggle(f, 0, 2, {boldAttribution});
    superToggle(f, 3, 6, {italicsAttribution});
    superToggle(f, 7, 9, {underlineAttribution});
    superToggle(f, 10, 12, {ColorAttribution(const Color(0xffcc0000))});
    superToggle(f, 14, 15, {const NamedAttribution('sub')});
    expect(f.toHtml(), '<b>굵게</b> <i>기울임</i> <u>밑줄</u> <span style="color: #cc0000">빨강</span> H<sub>2</sub>O');
    await shoot(tester, 'rich_super', 'super_editor · bold italic underline color sub', superFieldWidget(SuperField(f.toHtml())));
  });

  testWidgets('editable cloze insert', (tester) async {
    final c = FieldController('서울은 수도');
    c.value = const TextEditingValue(text: '{{c1::서울}}은 수도', selection: TextSelection.collapsed(offset: 11));
    expect(c.toHtml(), '{{c1::서울}}은 수도');
    await shoot(tester, 'cloze_editable', 'EditableText · cloze insert', EditableField(c, FocusNode()));
  });

  testWidgets('super cloze insert', (tester) async {
    final f = SuperField('서울은 수도');
    f.editor.execute([
      InsertTextRequest(documentPosition: at(2), textToInsert: '}}', attributions: {}),
      InsertTextRequest(documentPosition: at(0), textToInsert: '{{c1::', attributions: {}),
    ]);
    expect(f.toHtml(), '{{c1::서울}}은 수도');
    await shoot(tester, 'cloze_super', 'super_editor · cloze insert', superFieldWidget(SuperField(f.toHtml())));
  });

  testWidgets('editable image token', (tester) async {
    final c = FieldController('앞 <img src="paste-1.png"> 뒤');
    expect(c.toHtml().contains('<img src="paste-1.png">'), true);
    await shoot(tester, 'image_token_editable', 'EditableText · image token (opaque chip)', EditableField(c, FocusNode()));
  });

  testWidgets('super image token', (tester) async {
    final f = SuperField('앞 <img src="paste-1.png"> 뒤');
    expect(f.toHtml().contains('<img src="paste-1.png">'), true);
    await shoot(tester, 'image_token_super', 'super_editor · image token (opaque chip)', superFieldWidget(SuperField(f.toHtml())));
  });

  testWidgets('editable mathjax token', (tester) async {
    final c = FieldController(r'수식 \(e^{i\pi}+1=0\) 그리고 \[x^2\]');
    expect(c.toHtml().contains(r'\(e^{i\pi}+1=0\)'), true);
    expect(c.toHtml().contains(r'\[x^2\]'), true);
    await shoot(tester, 'mathjax_editable', 'EditableText · MathJax inline and display tokens', EditableField(c, FocusNode()));
  });

  testWidgets('super mathjax token', (tester) async {
    final f = SuperField(r'수식 \(e^{i\pi}+1=0\) 그리고 \[x^2\]');
    expect(f.toHtml().contains(r'\(e^{i\pi}+1=0\)'), true);
    expect(f.toHtml().contains(r'\[x^2\]'), true);
    await shoot(tester, 'mathjax_super', 'super_editor · MathJax inline and display tokens', superFieldWidget(SuperField(f.toHtml())));
  });

  testWidgets('editable undo snapshot restores bold', (tester) async {
    final c = FieldController('<b>hello</b> world');
    final snap = c.snap();
    c.value = const TextEditingValue(text: ' world', selection: TextSelection.collapsed(offset: 0));
    expect(c.toHtml().contains('<b>'), false);
    c.restore(snap);
    expect(c.toHtml(), '<b>hello</b> world');
    await shoot(tester, 'undo_editable', 'EditableText · undo snapshot restores bold', EditableField(c, FocusNode()));
  });

  testWidgets('super undo restores typed text', (tester) async {
    final f = SuperField('원문');
    f.editor.execute([
      InsertTextRequest(documentPosition: at(2), textToInsert: ' 추가', attributions: {}),
    ]);
    expect(f.toHtml(), '원문 추가');
    f.editor.undo();
    expect(f.toHtml(), '원문');
    await shoot(tester, 'undo_super', 'super_editor · undo restores 원문', superFieldWidget(SuperField(f.toHtml())));
  });

  testWidgets('editable korean ime composed text', (tester) async {
    final c = FieldController('<b>굵</b>');
    final fn = FocusNode();
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: EditableField(c, fn))));
    await tester.tap(find.byType(EditableText));
    await tester.pump();
    c.selection = const TextSelection.collapsed(offset: 1);
    await tester.pump();
    void ime(String t, int cs, int ce) => tester.testTextInput.updateEditingValue(TextEditingValue(
          text: t,
          selection: TextSelection.collapsed(offset: ce),
          composing: ce > cs ? TextRange(start: cs, end: ce) : TextRange.empty,
        ));
    for (final st in [('굵ㅎ', 1, 2), ('굵하', 1, 2), ('굵한', 1, 2), ('굵한ㄱ', 2, 3), ('굵한그', 2, 3), ('굵한글', 2, 3), ('굵한글', 0, 0)]) {
      ime(st.$1, st.$2, st.$3);
      await tester.pump();
    }
    expect(c.text, '굵한글');
    expect(c.toHtml(), '<b>굵한글</b>');
    await shoot(tester, 'ime_korean_editable', 'EditableText · Korean IME composed 굵한글', EditableField(FieldController(c.toHtml()), FocusNode()));
  });

  testWidgets('super korean ime composed text', (tester) async {
    final f = SuperField('');
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: superFieldWidget(f))));
    await tester.placeCaretInParagraph('p', 0);
    final cl = imeClientGetter();
    Future<void> comp(String oldContent, String newContent, int start, int end, {required bool insertion}) async {
      final cur = cl.currentTextEditingValue!;
      final prefix = cur.text.length - oldContent.length;
      final oldText = cur.text;
      final composing = end > start ? TextRange(start: prefix + start, end: prefix + end) : TextRange.empty;
      final TextEditingDelta d = insertion
          ? TextEditingDeltaInsertion(
              oldText: oldText,
              textInserted: newContent.substring(start, end),
              insertionOffset: prefix + start,
              selection: TextSelection.collapsed(offset: prefix + end),
              composing: composing,
            )
          : TextEditingDeltaReplacement(
              oldText: oldText,
              replacementText: newContent.substring(start, end),
              replacedRange: TextRange(start: prefix + start, end: prefix + start + (oldContent.length - start).clamp(0, 1)),
              selection: TextSelection.collapsed(offset: prefix + end),
              composing: composing,
            );
      await tester.ime.sendDeltas([d], getter: imeClientGetter);
    }

    await comp('', 'ㅎ', 0, 1, insertion: true);
    await comp('ㅎ', '하', 0, 1, insertion: false);
    await comp('하', '한', 0, 1, insertion: false);
    await comp('한', '한ㄱ', 1, 2, insertion: true);
    await comp('한ㄱ', '한그', 1, 2, insertion: false);
    await comp('한그', '한글', 1, 2, insertion: false);
    final cur = cl.currentTextEditingValue!;
    final prefix = cur.text.length - 2;
    await tester.ime.sendDeltas(
      [TextEditingDeltaNonTextUpdate(oldText: cur.text, selection: TextSelection.collapsed(offset: prefix + 2), composing: TextRange.empty)],
      getter: imeClientGetter,
    );
    expect(f.toHtml(), '한글');
    await shoot(tester, 'ime_korean_super', 'super_editor · Korean IME composed 한글', superFieldWidget(SuperField(f.toHtml())));
  });
}
