// Prototype A: super_editor 0.3.0-dev.52 as the field editing surface.
import 'package:flutter/material.dart';
import 'package:super_editor/super_editor.dart';
import 'field_codec.dart';

class TokenPlaceholder {
  TokenPlaceholder(this.seg);
  final Seg seg;
}

AttributedText attributedFromSegs(List<Seg> segs) {
  final full = StringBuffer();
  final placeholders = <int, Object>{};
  final ranges = <(Attribution, int, int)>[];
  var idx = 0;
  for (final s in segs) {
    if (s.isToken) { placeholders[idx] = TokenPlaceholder(s); full.write(AttributedText.placeholderCharacter); idx++; continue; }
    final start = idx; full.write(s.text); idx += s.text.length;
    if (s.text.isEmpty) continue;
    if (s.bold) ranges.add((boldAttribution, start, idx - 1));
    if (s.italic) ranges.add((italicsAttribution, start, idx - 1));
    if (s.underline) ranges.add((underlineAttribution, start, idx - 1));
    if (s.sup) ranges.add((const NamedAttribution('sup'), start, idx - 1));
    if (s.sub) ranges.add((const NamedAttribution('sub'), start, idx - 1));
    if (s.color != null) ranges.add((ColorAttribution(_parse(s.color!)), start, idx - 1));
  }
  final plain = StringBuffer();
  final f = full.toString();
  for (var i = 0; i < f.length; i++) { if (!placeholders.containsKey(i)) plain.write(f[i]); }
  final at = AttributedText(plain.toString(), null, placeholders);
  for (final (a, s, e) in ranges) { at.addAttribution(a, SpanRange(s, e)); }
  return at;
}

Color _parse(String hex) { var h = hex.replaceFirst('#', ''); if (h.length == 3) h = h.split('').map((c) => '$c$c').join(); return Color(int.parse('ff$h', radix: 16)); }
String _hex(Color c) => '#${(c.toARGB32() & 0xffffff).toRadixString(16).padLeft(6, '0')}';

List<Seg> segsFromAttributed(AttributedText at) {
  final out = <Seg>[];
  final plain = at.toPlainText(includePlaceholders: true);
  for (var i = 0; i < plain.length; i++) {
    final ph = at.placeholders[i];
    if (ph is TokenPlaceholder) { out.add(ph.seg); continue; }
    final a = at.getAllAttributionsAt(i);
    Color? col; for (final x in a) { if (x is ColorAttribution) col = x.color; }
    final s = Seg.text(plain[i], bold: a.contains(boldAttribution), italic: a.contains(italicsAttribution), underline: a.contains(underlineAttribution),
        sup: a.contains(const NamedAttribution('sup')), sub: a.contains(const NamedAttribution('sub')), color: col == null ? null : _hex(col));
    if (out.isNotEmpty && !out.last.isToken && out.last.sameStyle(s)) {
      final l = out.removeLast();
      out.add(Seg.text(l.text + s.text, bold: l.bold, italic: l.italic, underline: l.underline, sup: l.sup, sub: l.sub, color: l.color));
    } else { out.add(s); }
  }
  return out;
}

class SuperField {
  SuperField(String html, {bool history = true}) {
    doc = MutableDocument(nodes: [ParagraphNode(id: 'p', text: attributedFromSegs(parseField(html)))]);
    composer = MutableDocumentComposer();
    editor = createDefaultDocumentEditor(document: doc, composer: composer, isHistoryEnabled: history);
  }
  late final MutableDocument doc;
  late final MutableDocumentComposer composer;
  late final Editor editor;
  AttributedText get text => (doc.getNodeById('p') as ParagraphNode).text;
  String toHtml() => serializeField(segsFromAttributed(text));
}

Widget superFieldWidget(SuperField f, {double width = 420}) => SizedBox(
      width: width, height: 110,
      child: SuperEditor(
        editor: f.editor,
        stylesheet: defaultStylesheet.copyWith(
          addRulesAfter: [StyleRule(BlockSelector.all, (doc, node) => {Styles.textStyle: const TextStyle(fontFamily: 'NanumGothic', fontSize: 16, color: Colors.black, height: 1.4)})],
          documentPadding: const EdgeInsets.all(8),
          inlineTextStyler: (attrs, base) {
            var s = defaultInlineTextStyler(attrs, base);
            if (attrs.contains(const NamedAttribution('sup'))) s = s.copyWith(fontSize: (s.fontSize ?? 16) * 0.7);
            return s;
          },
          inlineWidgetBuilders: [
            (ctx, style, ph) => ph is TokenPlaceholder
                ? Container(padding: const EdgeInsets.symmetric(horizontal: 3), decoration: BoxDecoration(color: const Color(0xffe0e8ff), borderRadius: BorderRadius.circular(3)),
                    child: Text(switch (ph.seg.kind!) { TokenKind.img => '[img]', TokenKind.sound => '[sound]', TokenKind.mathInline => '[math]', TokenKind.mathBlock => '[MATH]', TokenKind.raw => '[html]' }, style: style.copyWith(fontSize: 12)))
                : null,
          ],
        ),
      ),
    );
