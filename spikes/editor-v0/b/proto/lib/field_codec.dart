// Spike b: Anki field HTML <-> segment model. Shared by both prototypes.
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as hp;

enum TokenKind { img, sound, mathInline, mathBlock, raw }

class Seg {
  Seg.text(this.text, {this.bold = false, this.italic = false, this.underline = false, this.sup = false, this.sub = false, this.color})
      : token = null, kind = null;
  Seg.token(this.token, this.kind)
      : text = '', bold = false, italic = false, underline = false, sup = false, sub = false, color = null;
  final String text;
  final bool bold, italic, underline, sup, sub;
  final String? color;
  final String? token; // raw original markup, preserved byte-exact
  final TokenKind? kind;
  bool get isToken => token != null;
  bool sameStyle(Seg o) => !isToken && !o.isToken && bold == o.bold && italic == o.italic && underline == o.underline && sup == o.sup && sub == o.sub && color == o.color;
  @override
  String toString() => isToken ? 'T($kind:$token)' : 'S(${text.replaceAll('\n', '⏎')}${bold ? ',b' : ''}${italic ? ',i' : ''}${underline ? ',u' : ''}${sup ? ',sup' : ''}${sub ? ',sub' : ''}${color != null ? ',c=$color' : ''})';
}

final _tok = RegExp(r'\[sound:[^\]]+\]|\\\((?:.|\n)+?\\\)|\\\[(?:.|\n)+?\\\]');

List<Seg> parseField(String html) {
  final frag = hp.parseFragment(html);
  final out = <Seg>[];
  void walk(dom.Node n, {bool b = false, bool i = false, bool u = false, bool sup = false, bool sub = false, String? color}) {
    if (n is dom.Text) {
      var s = n.data; var pos = 0;
      for (final m in _tok.allMatches(s)) {
        if (m.start > pos) out.add(Seg.text(s.substring(pos, m.start), bold: b, italic: i, underline: u, sup: sup, sub: sub, color: color));
        final t = m.group(0)!;
        out.add(Seg.token(t, t.startsWith('[sound') ? TokenKind.sound : t.startsWith(r'\(') ? TokenKind.mathInline : TokenKind.mathBlock));
        pos = m.end;
      }
      if (pos < s.length) out.add(Seg.text(s.substring(pos), bold: b, italic: i, underline: u, sup: sup, sub: sub, color: color));
      return;
    }
    if (n is dom.Element) {
      final t = n.localName;
      if (t == 'br' && n.attributes.isEmpty) { out.add(Seg.text('\n', bold: b, italic: i, underline: u, sup: sup, sub: sub, color: color)); return; }
      if (t == 'img') { out.add(Seg.token(n.outerHtml, TokenKind.img)); return; }
      final styleOnly = n.attributes.keys.every((k) => k == 'style');
      if ((t == 'b' || t == 'strong') && n.attributes.isEmpty) { n.nodes.forEach((c) => walk(c, b: true, i: i, u: u, sup: sup, sub: sub, color: color)); return; }
      if ((t == 'i' || t == 'em') && n.attributes.isEmpty) { n.nodes.forEach((c) => walk(c, b: b, i: true, u: u, sup: sup, sub: sub, color: color)); return; }
      if (t == 'u' && n.attributes.isEmpty) { n.nodes.forEach((c) => walk(c, b: b, i: i, u: true, sup: sup, sub: sub, color: color)); return; }
      if (t == 'sup' && n.attributes.isEmpty) { n.nodes.forEach((c) => walk(c, b: b, i: i, u: u, sup: true, sub: sub, color: color)); return; }
      if (t == 'sub' && n.attributes.isEmpty) { n.nodes.forEach((c) => walk(c, b: b, i: i, u: u, sup: sup, sub: true, color: color)); return; }
      if (t == 'span' && styleOnly && RegExp(r'^color:\s*#?[0-9a-fA-F]{3,8};?$').hasMatch(n.attributes['style'] ?? '')) {
        final c = RegExp(r'color:\s*(#?[0-9a-fA-F]{3,8})').firstMatch(n.attributes['style']!)!.group(1)!;
        n.nodes.forEach((x) => walk(x, b: b, i: i, u: u, sup: sup, sub: sub, color: c)); return;
      }
      out.add(Seg.token(n.outerHtml, TokenKind.raw)); // everything else: opaque, preserved
    }
  }
  frag.nodes.forEach(walk);
  // merge adjacent same-style text
  final merged = <Seg>[];
  for (final s in out) {
    if (merged.isNotEmpty && !s.isToken && merged.last.sameStyle(s)) {
      final l = merged.removeLast();
      merged.add(Seg.text(l.text + s.text, bold: l.bold, italic: l.italic, underline: l.underline, sup: l.sup, sub: l.sub, color: l.color));
    } else { merged.add(s); }
  }
  return merged;
}

String _esc(String s) => s.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;').replaceAll('\u00a0', '&nbsp;');

String serializeField(List<Seg> segs) {
  final sb = StringBuffer();
  for (final s in segs) {
    if (s.isToken) { sb.write(s.token); continue; }
    final parts = s.text.split('\n');
    for (var k = 0; k < parts.length; k++) {
      if (k > 0) sb.write('<br>');
      if (parts[k].isEmpty) continue;
      var h = _esc(parts[k]);
      if (s.color != null) h = '<span style="color: ${s.color}">$h</span>';
      if (s.sup) h = '<sup>$h</sup>';
      if (s.sub) h = '<sub>$h</sub>';
      if (s.underline) h = '<u>$h</u>';
      if (s.italic) h = '<i>$h</i>';
      if (s.bold) h = '<b>$h</b>';
      sb.write(h);
    }
  }
  return sb.toString();
}

/// Normalized DOM string for equivalence comparison (what a browser contenteditable round trip would also canonicalize).
String canon(String html) {
  final f = hp.parseFragment(html);
  // merge adjacent text nodes & normalise b/strong,i/em
  String ser(dom.Node n) {
    if (n is dom.Text) return n.data;
    if (n is dom.Element) {
      var t = n.localName!; if (t == 'strong') t = 'b'; if (t == 'em') t = 'i';
      final attrs = (n.attributes.entries.map((e) => '${e.key}="${e.value.replaceAll(RegExp(r';\s*$'), '').replaceAll(RegExp(r':\s+'), ':')}"').toList()..sort()).join(' ');
      final inner = n.nodes.map(ser).join();
      if (t == 'br' || t == 'img') return '<$t${attrs.isEmpty ? '' : ' $attrs'}>';
      return '<$t${attrs.isEmpty ? '' : ' $attrs'}>$inner</$t>';
    }
    return '';
  }
  return f.nodes.map(ser).join();
}
