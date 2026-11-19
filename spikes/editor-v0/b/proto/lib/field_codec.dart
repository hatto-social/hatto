// Anki field HTML <-> segment model (v0 editor contract).
//  - Tier 1 marks: b/i/u/sub/sup/color (overlapping), <br> as '\n'
//  - <img> is an atom token; everything else out of scope is an opaque RAW atom whose bytes are sliced
//    from the ORIGINAL source (byte-exact), not re-serialised.
//  - Math \(..\), [sound:..], cloze are plain text in the editor path (specialsAsTokens: false).
//    The legacy token mode (specialsAsTokens: true) is kept so the old round-trip spike still passes.
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

const _void = {'area', 'base', 'br', 'col', 'embed', 'hr', 'img', 'input', 'link', 'meta', 'param', 'source', 'track', 'wbr'};
final _tok = RegExp(r'\[sound:[^\]]+\]|\\\((?:.|\n)+?\\\)|\\\[(?:.|\n)+?\\\]');
final _colorRe = RegExp(r'^\s*color:\s*(#[0-9a-fA-F]{3}|#[0-9a-fA-F]{6})\s*;?\s*$');

/// Result of opening a field.
class Analysis {
  Analysis(this.segs, this.reasons);
  final List<Seg> segs;
  /// Non-empty => field must open in "HTML source edit" mode.
  final List<String> reasons;
  bool get richOk => reasons.isEmpty;
}

List<Seg> parseField(String html, {bool specialsAsTokens = true, bool wsNormalize = false}) => _parse(html, specialsAsTokens, [], wsNormalize);

List<Seg> parseFieldIssues(String html, bool specials, List<String> issues, [bool ws = false]) => _parse(html, specials, issues, ws);
List<Seg> _parse(String html, bool specials, List<String> issues, [bool ws = false]) {
  final frag = hp.parseFragment(html, generateSpans: true);
  final out = <Seg>[];
  String? rawOf(dom.Node n, int idx, List<dom.Node> siblings) {
    if (n is dom.Comment) { final s = n.sourceSpan; return s == null ? null : html.substring(s.start.offset, s.end.offset); }
    final e = n as dom.Element; final ss = e.sourceSpan; if (ss == null) return null;
    int end;
    if (e.endSourceSpan != null) { end = e.endSourceSpan!.end.offset; }
    else if (e.nodes.isEmpty && _void.contains(e.localName)) { end = ss.end.offset; }
    else { return null; } // dangling/implicitly closed non-void element: slice boundary is ambiguous -> source-edit mode
    if (end < ss.start.offset || end > html.length) return null;
    final raw = html.substring(ss.start.offset, end);
    // isolation check: the slice must re-parse to exactly this one element (guards mis-nested markup)
    final re = hp.parseFragment(raw);
    if (re.nodes.length != 1 || canon(raw) != canon(e.outerHtml)) return null;
    return raw;
  }
  void walk(dom.Node n, int idx, List<dom.Node> siblings, {bool b = false, bool i = false, bool u = false, bool sup = false, bool sub = false, String? color}) {
    Seg t(String s) => Seg.text(s, bold: b, italic: i, underline: u, sup: sup, sub: sub, color: color);
    void kids(dom.Element e, {bool? nb, bool? ni, bool? nu, bool? nsup, bool? nsub, String? ncolor}) {
      for (var k = 0; k < e.nodes.length; k++) {
        walk(e.nodes[k], k, e.nodes, b: nb ?? b, i: ni ?? i, u: nu ?? u, sup: nsup ?? sup, sub: nsub ?? sub, color: ncolor ?? color);
      }
    }
    if (n is dom.Text) {
      var s = n.data;
      if (s.contains('\n') || s.contains('\r')) { if (ws) { s = s.replaceAll('\r\n', ' ').replaceAll('\n', ' ').replaceAll('\r', ' '); } else { issues.add('literal newline in text (whitespace, not <br>)'); } }
      if (s.contains('\uFFFC')) issues.add('contains U+FFFC');
      var pos = 0;
      if (specials) {
        for (final m in _tok.allMatches(s)) {
          if (m.start > pos) out.add(t(s.substring(pos, m.start)));
          final tk = m.group(0)!;
          out.add(Seg.token(tk, tk.startsWith('[sound') ? TokenKind.sound : tk.startsWith(r'\(') ? TokenKind.mathInline : TokenKind.mathBlock));
          pos = m.end;
        }
      }
      if (pos < s.length) out.add(t(s.substring(pos)));
      return;
    }
    if (n is dom.Comment) {
      final r = rawOf(n, idx, siblings); if (r == null) { issues.add('comment without source span'); out.add(Seg.token('<!--${n.data}-->', TokenKind.raw)); return; }
      out.add(Seg.token(r, TokenKind.raw)); return;
    }
    if (n is dom.Element) {
      final tag = n.localName;
      final noAttr = n.attributes.isEmpty;
      if (tag == 'br' && noAttr) { out.add(t('\n')); return; }
      if (tag == 'img') {
        final r = rawOf(n, idx, siblings); if (r == null) { issues.add('img without source span'); out.add(Seg.token(n.outerHtml, TokenKind.img)); return; }
        out.add(Seg.token(r, TokenKind.img)); return;
      }
      if ((tag == 'b' || tag == 'strong') && noAttr) { kids(n, nb: true); return; }
      if ((tag == 'i' || tag == 'em') && noAttr) { kids(n, ni: true); return; }
      if (tag == 'u' && noAttr) { kids(n, nu: true); return; }
      if (tag == 'sup' && noAttr) { kids(n, nsup: true); return; }
      if (tag == 'sub' && noAttr) { kids(n, nsub: true); return; }
      if (tag == 'span' && n.attributes.length == 1 && n.attributes.containsKey('style')) {
        final m = _colorRe.firstMatch(n.attributes['style']!);
        if (m != null) { kids(n, ncolor: m.group(1)!); return; }
      }
      final r = rawOf(n, idx, siblings); if (r == null) { issues.add('<$tag> without sliceable source'); out.add(Seg.token(n.outerHtml, TokenKind.raw)); return; } // never drop silently; analyzeField sends such fields to source mode
      out.add(Seg.token(r, TokenKind.raw));
    }
  }
  for (var k = 0; k < frag.nodes.length; k++) { walk(frag.nodes[k], k, frag.nodes); }
  final merged = <Seg>[];
  for (final s in out) {
    if (merged.isNotEmpty && !s.isToken && merged.last.sameStyle(s)) {
      final l = merged.removeLast();
      merged.add(Seg.text(l.text + s.text, bold: l.bold, italic: l.italic, underline: l.underline, sup: l.sup, sub: l.sub, color: l.color));
    } else { merged.add(s); }
  }
  return merged;
}

/// Open-time analysis: decides rich vs "HTML source edit". [strict] uses the literal DOM canon,
/// otherwise the flattened (nesting-order-insensitive) canon.
Analysis analyzeField(String html, {bool strict = false, bool wsNormalize = false}) {
  final issues = <String>[];
  final segs = _parse(html, false, issues, wsNormalize);
  if (issues.isEmpty) {
    final out = serializeField(segs);
    final same = strict ? canon(out) == canon(html) : canonFlat(out, collapseNewlines: wsNormalize) == canonFlat(html, collapseNewlines: wsNormalize);
    if (!same) issues.add(strict ? 'decode->encode not DOM-equivalent (strict)' : 'decode->encode not DOM-equivalent (flat)');
  }
  return Analysis(segs, issues);
}

String _esc(String s) => s.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;').replaceAll('\u00a0', '&nbsp;');

// Fixed nesting order => adjacent runs re-use open tags (b>i>u>sub>sup>color).
List<String> _marksOf(Seg s) => [if (s.bold) 'b', if (s.italic) 'i', if (s.underline) 'u', if (s.sub) 'sub', if (s.sup) 'sup', if (s.color != null) 'c:${s.color}'];
String _open(String m) => m.startsWith('c:') ? '<span style="color: ${m.substring(2)}">' : '<$m>';
String _close(String m) => m.startsWith('c:') ? '</span>' : '</$m>';

String serializeField(List<Seg> segs) {
  final sb = StringBuffer();
  var stack = <String>[];
  void retarget(List<String> want) {
    var k = 0; while (k < stack.length && k < want.length && stack[k] == want[k]) { k++; }
    while (stack.length > k) { sb.write(_close(stack.removeLast())); }
    for (var j = k; j < want.length; j++) { sb.write(_open(want[j])); stack.add(want[j]); }
  }
  for (final s in segs) {
    if (s.isToken) { retarget(const []); sb.write(s.token); continue; }
    final want = _marksOf(s);
    var pos = 0;
    while (pos < s.text.length) {
      final nl = s.text.indexOf('\n', pos);
      final end = nl < 0 ? s.text.length : nl;
      if (end > pos) { retarget(want); sb.write(_esc(s.text.substring(pos, end))); }
      if (nl >= 0) { retarget(want); sb.write('<br>'); pos = nl + 1; } else { pos = end; }
    }
  }
  retarget(const []);
  return sb.toString();
}

String _normColor(String c) {
  c = c.toLowerCase();
  if (c.length == 4) c = '#${c[1]}${c[1]}${c[2]}${c[2]}${c[3]}${c[3]}';
  return c;
}

/// Strict normalized DOM string (spike canon): literal tree compare, modulo attr order / style punctuation / strong,em.
String canon(String html) {
  final f = hp.parseFragment(html);
  String ser(dom.Node n) {
    if (n is dom.Text) return n.data;
    if (n is dom.Comment) return '<!--${n.data}-->';
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

/// Flattened canon (independent DOM walker, not parseField): every character with its mark set,
/// '\n' for attr-less <br>, anything else as an atom compared by strict canon. Insensitive to nesting
/// order / adjacent identical wrappers / empty inline wrappers.
String canonFlat(String html, {bool collapseNewlines = false}) {
  final f = hp.parseFragment(html);
  final sb = StringBuffer(); String? cur;
  void emit(String marks, String text) {
    if (cur != marks) { sb.write('«$marks»'); cur = marks; }
    sb.write(text);
  }
  void walk(dom.Node n, Set<String> m) {
    if (n is dom.Text) { if (n.data.isNotEmpty) emit((m.toList()..sort()).join(','), collapseNewlines ? n.data.replaceAll('\r\n', ' ').replaceAll('\n', ' ').replaceAll('\r', ' ') : n.data); return; }
    if (n is dom.Comment) { emit('atom', '<!--${n.data}-->'); cur = null; return; }
    if (n is dom.Element) {
      final t = n.localName!;
      Set<String>? add;
      if (n.attributes.isEmpty) {
        add = switch (t) { 'b' || 'strong' => {'b'}, 'i' || 'em' => {'i'}, 'u' => {'u'}, 'sup' => {'sup'}, 'sub' => {'sub'}, _ => null };
        if (t == 'br') { emit((m.toList()..sort()).join(','), '\n'); return; }
      }
      if (t == 'span' && n.attributes.length == 1 && n.attributes.containsKey('style')) {
        final mm = _colorRe.firstMatch(n.attributes['style']!);
        if (mm != null) add = {'c=${_normColor(mm.group(1)!)}'};
      }
      if (add != null) {
        final nm = {...m};
        if (add.first.startsWith('c=')) nm.removeWhere((x) => x.startsWith('c='));
        nm.addAll(add);
        for (final c in n.nodes) { walk(c, nm); }
        return;
      }
      emit('atom', canon(n.outerHtml)); cur = null;
    }
  }
  for (final n in f.nodes) { walk(n, {}); }
  return sb.toString();
}
