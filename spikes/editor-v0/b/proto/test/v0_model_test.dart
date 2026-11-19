import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:editor_proto/field_codec.dart';
import 'package:editor_proto/proto_editable.dart';

void main() {
  test('adjacent atoms (identical placeholder chars): caret decides which atom a delete removed', () {
    final fwd = FieldController('<img src="a.png"><img src="b.png">');
    fwd.value = const TextEditingValue(text: '\uFFFC', selection: TextSelection.collapsed(offset: 0)); // Delete at caret 0
    expect(fwd.toHtml(), '<img src="b.png">');
    final back = FieldController('<img src="a.png"><img src="b.png">');
    back.value = const TextEditingValue(text: '\uFFFC', selection: TextSelection.collapsed(offset: 1)); // Backspace at caret 2
    expect(back.toHtml(), '<img src="a.png">');
  });
  test('surrogate pairs keep marks together, selection marks over emoji', () {
    final c = FieldController('a😀b');
    c.selection = const TextSelection(baseOffset: 1, extentOffset: 3); c.toggleMark(RK.bold);
    expect(c.toHtml(), 'a<b>😀</b>b'); expect(c.save(), 'a<b>😀</b>b');
  });
  test('untouched = original bytes even when content is weird; touched+reverted = original bytes', () {
    const weird = '<DIV class=x>A &amp; B</div>\n<br class="y">&nbsp;';
    final c = FieldController(weird); expect(c.save(), weird);
    final d = FieldController('<b>x</b>y'); d.selection = const TextSelection(baseOffset: 1, extentOffset: 2); d.toggleMark(RK.italic);
    expect(d.dirty, isTrue); d.undo(); expect(d.dirty, isFalse); expect(d.save(), '<b>x</b>y');
  });
  test('raw atom bytes preserved (attribute quoting, entities, case)', () {
    const raw = "<TABLE border=1 class='a'><tr><td>&lt;1&gt;</td></tr></TABLE>";
    final c = FieldController('가 $raw 나');
    expect(c.atoms.single.token, raw);
    c.value = c.value.copyWith(text: '가! \uFFFC 나', selection: const TextSelection.collapsed(offset: 2));
    expect(c.save(), '가! $raw 나');
  });
  test('sup and sub are mutually exclusive in the editor', () {
    final c = FieldController('x2'); c.selection = const TextSelection(baseOffset: 1, extentOffset: 2);
    c.toggleMark(RK.sup); c.toggleMark(RK.sub);
    expect(c.toHtml(), 'x<sub>2</sub>');
  });
  test('toggle on selection spanning atom skips atom; newline marks serialise inside tags', () {
    final c = FieldController('a<img src="i.png">b<br>c');
    c.selection = const TextSelection(baseOffset: 0, extentOffset: 5); c.toggleMark(RK.bold);
    expect(c.toHtml(), '<b>a</b><img src="i.png"><b>b<br>c</b>');
    expect(canonFlat(c.toHtml()), canonFlat('<b>a</b><img src="i.png"><b>b<br>c</b>'));
  });
  test('strict vs flat DOM equivalence knobs', () {
    const h = '<i><b>x</b></i>';
    expect(analyzeField(h).richOk, isTrue);              // flat: nesting order insensitive
    expect(analyzeField(h, strict: true).richOk, isFalse); // strict literal DOM: opens in source mode
  });
  test('pending: toggled twice returns to inherited; setColor pending', () {
    final c = FieldController('<b>x</b>'); c.selection = const TextSelection.collapsed(offset: 1);
    expect(c.activeMarks.has(RK.bold), isTrue);
    c.toggleMark(RK.bold); c.toggleMark(RK.bold); expect(c.activeMarks.has(RK.bold), isTrue);
    c.userMovedCaret(); expect(c.pending, isNull);
  });
}
