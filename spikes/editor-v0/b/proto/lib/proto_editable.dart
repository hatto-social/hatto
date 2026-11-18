// Prototype B: EditableText + custom TextEditingController (style ranges + token placeholders).
import 'package:flutter/material.dart';
import 'field_codec.dart';

const _ph = '\uFFFC';
enum RK { bold, italic, underline, sup, sub, color }
class R { R(this.k, this.s, this.e, [this.color]); RK k; int s, e; String? color; R copy() => R(k, s, e, color); }

class FieldController extends TextEditingController {
  FieldController(String html) {
    final segs = parseField(html);
    final sb = StringBuffer(); var i = 0;
    for (final s in segs) {
      if (s.isToken) { sb.write(_ph); tokens.add(s); i++; continue; }
      final st = i; sb.write(s.text); i += s.text.length;
      if (s.text.isEmpty) continue;
      if (s.bold) ranges.add(R(RK.bold, st, i)); if (s.italic) ranges.add(R(RK.italic, st, i));
      if (s.underline) ranges.add(R(RK.underline, st, i)); if (s.sup) ranges.add(R(RK.sup, st, i)); if (s.sub) ranges.add(R(RK.sub, st, i));
      if (s.color != null) ranges.add(R(RK.color, st, i, s.color));
    }
    super.text = sb.toString();
    _prev = text; applying = false;
  }
  final List<R> ranges = [];
  final List<Seg> tokens = [];
  String _prev = '';
  bool applying = true;

  @override
  set value(TextEditingValue v) {
    if (!applying && v.text != _prev) _adjust(_prev, v.text);
    _prev = v.text;
    super.value = v;
  }

  void _adjust(String o, String n) {
    var p = 0; while (p < o.length && p < n.length && o[p] == n[p]) p++;
    var oe = o.length, ne = n.length;
    while (oe > p && ne > p && o[oe - 1] == n[ne - 1]) { oe--; ne--; }
    // tokens removed inside [p, oe)
    var before = 0; for (var i = 0; i < p; i++) { if (o[i] == _ph) before++; }
    var removed = 0; for (var i = p; i < oe; i++) { if (o[i] == _ph) removed++; }
    if (removed > 0) tokens.removeRange(before, before + removed);
    final d = ne - oe; // length delta
    for (final r in ranges.toList()) {
      if (r.e <= p && !(r.e == p && p == oe && ne > p)) { continue; }              // before edit (unless insertion at end -> inherit)
      if (r.e == p && p == oe && ne > p) { r.e += d; continue; }                   // pure insertion at range end: inherit style
      if (r.s >= oe && !(r.s == oe && false)) { r.s += d; r.e += d; continue; }   // after edit
      // overlaps edit region
      final s2 = r.s < p ? r.s : p;
      var e2 = r.e > oe ? r.e + d : ne; // if range fully inside replaced region, keep new text covered only when it started before p
      if (r.s >= p && r.e <= oe) { ranges.remove(r); continue; }
      r.s = s2; r.e = e2;
    }
    ranges.removeWhere((r) => r.e <= r.s);
  }

  List<Seg> toSegs() {
    final out = <Seg>[]; var ti = 0;
    for (var i = 0; i < text.length; i++) {
      if (text[i] == _ph) { out.add(tokens[ti++]); continue; }
      bool has(RK k) => ranges.any((r) => r.k == k && r.s <= i && i < r.e);
      String? col; for (final r in ranges) { if (r.k == RK.color && r.s <= i && i < r.e) col = r.color; }
      final s = Seg.text(text[i], bold: has(RK.bold), italic: has(RK.italic), underline: has(RK.underline), sup: has(RK.sup), sub: has(RK.sub), color: col);
      if (out.isNotEmpty && !out.last.isToken && out.last.sameStyle(s)) { final l = out.removeLast(); out.add(Seg.text(l.text + s.text, bold: l.bold, italic: l.italic, underline: l.underline, sup: l.sup, sub: l.sub, color: l.color)); } else { out.add(s); }
    }
    return out;
  }
  String toHtml() => serializeField(toSegs());

  void toggle(RK k, TextSelection sel) {
    if (sel.isCollapsed) return;
    final s = sel.start, e = sel.end;
    final covered = List.generate(e - s, (i) => ranges.any((r) => r.k == k && r.s <= s + i && s + i < r.e)).every((x) => x);
    if (covered) {
      for (final r in ranges.toList().where((r) => r.k == k && r.s < e && r.e > s)) {
        ranges.remove(r);
        if (r.s < s) ranges.add(R(k, r.s, s, r.color)); if (r.e > e) ranges.add(R(k, e, r.e, r.color));
      }
    } else { ranges.add(R(k, s, e)); }
    notifyListeners();
  }

  // snapshot for custom undo
  (String, List<R>, List<Seg>, TextSelection) snap() => (text, ranges.map((r) => r.copy()).toList(), List.of(tokens), selection);
  void restore((String, List<R>, List<Seg>, TextSelection) s) {
    applying = true; ranges..clear()..addAll(s.$2.map((r) => r.copy())); tokens..clear()..addAll(s.$3);
    value = TextEditingValue(text: s.$1, selection: s.$4); _prev = s.$1; applying = false;
  }

  @override
  TextSpan buildTextSpan({required BuildContext context, TextStyle? style, required bool withComposing}) {
    final base = style ?? const TextStyle();
    final cuts = <int>{0, text.length};
    for (final r in ranges) { cuts..add(r.s.clamp(0, text.length))..add(r.e.clamp(0, text.length)); }
    for (var i = 0; i < text.length; i++) { if (text[i] == _ph) { cuts..add(i)..add(i + 1); } }
    final list = cuts.toList()..sort();
    final kids = <InlineSpan>[]; var ti = 0;
    for (var k = 0; k + 1 < list.length; k++) {
      final a = list[k], b = list[k + 1]; if (a == b) continue;
      final seg = text.substring(a, b);
      if (seg == _ph) {
        final t = tokens[ti++];
        kids.add(WidgetSpan(alignment: PlaceholderAlignment.middle, child: Container(padding: const EdgeInsets.symmetric(horizontal: 3), decoration: BoxDecoration(color: const Color(0xffe0e8ff), borderRadius: BorderRadius.circular(3)),
            child: Text(switch (t.kind!) { TokenKind.img => '[img]', TokenKind.sound => '[sound]', TokenKind.mathInline => '[math]', TokenKind.mathBlock => '[MATH]', TokenKind.raw => '[html]' }, style: base.copyWith(fontSize: 12)))));
        continue;
      }
      var st = base;
      for (final r in ranges.where((r) => r.s <= a && b <= r.e)) {
        st = switch (r.k) { RK.bold => st.copyWith(fontWeight: FontWeight.bold), RK.italic => st.copyWith(fontStyle: FontStyle.italic),
          RK.underline => st.copyWith(decoration: TextDecoration.underline), RK.sup => st.copyWith(fontSize: (st.fontSize ?? 16) * .7), RK.sub => st.copyWith(fontSize: (st.fontSize ?? 16) * .7),
          RK.color => st.copyWith(color: Color(int.parse('ff${r.color!.replaceFirst('#', '')}', radix: 16))) };
      }
      if (withComposing && value.composing.isValid && !value.composing.isCollapsed && a >= value.composing.start && b <= value.composing.end) st = st.copyWith(decoration: TextDecoration.underline);
      kids.add(TextSpan(text: seg, style: st));
    }
    return TextSpan(style: base, children: kids);
  }
}

class EditableField extends StatelessWidget {
  const EditableField(this.c, this.focus, {super.key, this.undo});
  final FieldController c; final FocusNode focus; final UndoHistoryController? undo;
  @override
  Widget build(BuildContext context) => SizedBox(width: 420, child: Container(padding: const EdgeInsets.all(8), decoration: BoxDecoration(border: Border.all(color: Colors.grey)),
      child: EditableText(controller: c, focusNode: focus, style: const TextStyle(fontSize: 16, color: Colors.black, fontFamily: 'NanumGothic'), cursorColor: Colors.blue, backgroundCursorColor: Colors.grey, maxLines: null, undoController: undo,
        selectionColor: Colors.blue.withValues(alpha: .3))));
}
