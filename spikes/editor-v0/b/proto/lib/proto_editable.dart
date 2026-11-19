// Prototype B (v0 "minimum usable editor"): EditableText + custom TextEditingController.
// Model: text with U+FFFC per atom (<img>, opaque raw HTML) + per-code-unit mark flags/color + atom table.
// See v0 scope: GINA_EDITOR_FORMAT_SCOPE.md / DMITRY_EDITOR_FORMAT_SCOPE_TABLE.md.
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'field_codec.dart';
import 'sanitize.dart';

const kPh = '\uFFFC';
enum RK { bold, italic, underline, sup, sub, color }

const _bit = {RK.bold: 1, RK.italic: 2, RK.underline: 4, RK.sup: 8, RK.sub: 16};

/// Immutable mark set (flags + optional color) used for pending style and active-state queries.
class Mks {
  const Mks([this.f = 0, this.c]);
  final int f; final String? c;
  bool has(RK k) => k == RK.color ? c != null : (f & _bit[k]!) != 0;
  Set<RK> get set => {for (final k in RK.values) if (has(k)) k};
  Mks toggled(RK k) {
    if (k == RK.color) return Mks(f, c);
    var nf = f ^ _bit[k]!;
    if (k == RK.sup && has(RK.sup) == false) nf &= ~_bit[RK.sub]!;
    if (k == RK.sub && has(RK.sub) == false) nf &= ~_bit[RK.sup]!;
    return Mks(nf, c);
  }
  Mks withColor(String? col) => Mks(f, col);
  @override bool operator ==(Object o) => o is Mks && o.f == f && o.c == c;
  @override int get hashCode => Object.hash(f, c);
  @override String toString() => 'Mks(${set.map((e) => e.name).join('+')}${c != null ? ' $c' : ''})';
}

class Cell { Cell(this.ch, this.f, this.c, this.a); final String ch; final int f; final String? c; final Seg? a; }
class _Clip { _Clip(this.plain, this.cells); final String plain; final List<Cell> cells; }
class _Snap {
  _Snap(this.text, this.f, this.c, this.a, this.sel, this.pending);
  final String text; final List<int> f; final List<String?> c; final List<Seg?> a; final TextSelection sel; final Mks? pending;
}

bool slidableLeft(String o, String n, int p, int oe, int ne) => p > 0 && o.codeUnitAt(oe - 1) == n.codeUnitAt(ne - 1);

typedef MediaResolver = String? Function(String src);

class FieldController extends TextEditingController {
  FieldController(String html, {bool strict = false, bool wsNormalize = false, this.mediaDir, Sanitizer? sourceSanitizer})
      : original = html, analysis = analyzeField(html, strict: strict, wsNormalize: wsNormalize), _sanitize = sourceSanitizer ?? sanitizer(allowImages: true) {
    final sb = StringBuffer();
    if (analysis.richOk) {
      for (final s in analysis.segs) {
        if (s.isToken) { sb.write(kPh); _f.add(0); _c.add(null); _a.add(s); continue; }
        final fl = (s.bold ? 1 : 0) | (s.italic ? 2 : 0) | (s.underline ? 4 : 0) | (s.sup ? 8 : 0) | (s.sub ? 16 : 0);
        sb.write(s.text);
        for (var i = 0; i < s.text.length; i++) { _f.add(fl); _c.add(s.color); _a.add(null); }
      }
    } else {
      sb.write(html);
      for (var i = 0; i < html.length; i++) { _f.add(0); _c.add(null); _a.add(null); }
    }
    super.value = TextEditingValue(text: sb.toString());
    _initial = _snap();
    _applying = false;
  }

  final String original;
  final Analysis analysis;
  final Sanitizer _sanitize;
  String? mediaDir;
  bool get isRich => analysis.richOk;
  String get modeLabel => isRich ? '서식 편집' : 'HTML 원문 편집';

  final List<int> _f = [];
  final List<String?> _c = [];
  final List<Seg?> _a = [];
  bool _applying = true;
  late final _Snap _initial;

  /// Pending marks (caret-only toggles). Held here, NOT derived from selection. Cleared only by [userMovedCaret].
  Mks? get pending => _pending;
  Mks? _pending;

  // ---- inspection helpers (tests, toolbar) ----
  int flagsAt(int i) => _f[i];
  String? colorAt(int i) => _c[i];
  Seg? atomAt(int i) => _a[i];
  List<Seg> get atoms => _a.whereType<Seg>().toList();
  Set<RK> marksAt(int i) => Mks(_f[i], _c[i]).set;
  String marksDump() {
    final sb = StringBuffer(); String? last;
    for (var i = 0; i < text.length; i++) {
      final k = _a[i] != null ? 'ATOM' : '${Mks(_f[i], _c[i])}';
      if (k != last) { sb.write('[$k]'); last = k; }
      sb.write(_a[i] != null ? '⟨atom⟩' : text[i]);
    }
    return sb.toString();
  }

  // ---- caret / pending ----
  /// Call on explicit user caret moves (pointer down in field, arrows, Home/End...). NOT on IME-driven selection changes.
  void userMovedCaret() {
    _breakCoalesce();
    if (_pending != null) { _pending = null; notifyListeners(); }
  }

  Mks _inheritAt(int p, [int? oe]) {
    final n = _f.length;
    if (oe != null && oe > p && p < n) return _a[p] != null ? const Mks() : Mks(_f[p], _c[p]);
    if (p > 0 && p - 1 < n) return _a[p - 1] != null ? const Mks() : Mks(_f[p - 1], _c[p - 1]);
    if (p < n && _a[p] == null) return Mks(_f[p], _c[p]);
    return const Mks();
  }

  /// Marks the toolbar should show as active.
  Mks get activeMarks {
    if (!isRich) return const Mks();
    final s = selection;
    if (!s.isValid) return _pending ?? const Mks();
    if (s.isCollapsed) return _pending ?? _inheritAt(s.start);
    var f = 31; String? col; var first = true, colorSame = true; var any = false;
    for (var i = s.start; i < s.end && i < _f.length; i++) {
      if (_a[i] != null) continue; any = true;
      f &= _f[i];
      if (first) { col = _c[i]; first = false; } else if (_c[i] != col) { colorSame = false; }
    }
    return any ? Mks(f, colorSame ? col : null) : const Mks();
  }

  // ---- mark editing ----
  void toggleMark(RK k) {
    if (!isRich || !selection.isValid) return;
    final s = selection;
    if (s.isCollapsed) {
      _breakCoalesce();
      _pending = (_pending ?? _inheritAt(s.start)).toggled(k);
      notifyListeners(); return;
    }
    final idx = [for (var i = s.start; i < s.end && i < _f.length; i++) if (_a[i] == null) i];
    if (idx.isEmpty) return;
    _pushHistory('other');
    final on = idx.every((i) => (_f[i] & _bit[k]!) != 0);
    for (final i in idx) {
      if (on) { _f[i] &= ~_bit[k]!; } else {
        _f[i] |= _bit[k]!;
        if (k == RK.sup) _f[i] &= ~_bit[RK.sub]!;
        if (k == RK.sub) _f[i] &= ~_bit[RK.sup]!;
      }
    }
    _pending = null; notifyListeners();
  }

  void setColor(String? hex) {
    if (!isRich || !selection.isValid) return;
    final s = selection;
    if (s.isCollapsed) { _breakCoalesce(); _pending = (_pending ?? _inheritAt(s.start)).withColor(hex); notifyListeners(); return; }
    _pushHistory('other');
    for (var i = s.start; i < s.end && i < _f.length; i++) { if (_a[i] == null) _c[i] = hex; }
    _pending = null; notifyListeners();
  }

  // ---- text change interception (IME / keyboard / programmatic) ----
  @override
  set value(TextEditingValue v) {
    if (!_applying && v.text != text) { v = _onTextChanged(v); }
    super.value = v;
  }

  TextEditingValue _onTextChanged(TextEditingValue v) {
    final o = text; var n = v.text;
    if (isRich && n.contains(kPh)) {
      // atoms enter only via explicit API; drop stray placeholders typed/pasted through the IME path
      final oldCount = _a.where((a) => a != null).length;
      if (kPh.allMatches(n).length > oldCount) {
        final s0 = StringBuffer(); var seen = 0;
        for (var i = 0; i < n.length; i++) { if (n[i] == kPh) { seen++; if (seen > oldCount) continue; } s0.write(n[i]); }
        n = s0.toString();
        if (n == o) return v.copyWith(text: o, selection: TextSelection.collapsed(offset: selection.isValid ? selection.baseOffset.clamp(0, o.length) : 0), composing: TextRange.empty);
        v = v.copyWith(text: n, selection: TextSelection.collapsed(offset: v.selection.baseOffset.clamp(0, n.length)), composing: TextRange.empty);
      }
    }
    final caret = v.selection.isValid && v.selection.isCollapsed ? v.selection.baseOffset.clamp(0, n.length) : -1;
    var p = 0; final lim = o.length < n.length ? o.length : n.length;
    while (p < lim && o.codeUnitAt(p) == n.codeUnitAt(p)) { p++; }
    var oe = o.length, ne = n.length;
    while (oe > p && ne > p && o.codeUnitAt(oe - 1) == n.codeUnitAt(ne - 1)) { oe--; ne--; }
    // Disambiguate equivalent alignments (repeated chars / identical atoms) with the reported caret:
    // slide the edit region left while it stays a valid diff. Never changes the resulting text.
    if (caret >= 0) {
      while ((ne > p ? ne > caret : p > caret) && p > 0 && slidableLeft(o, n, p, oe, ne)) { p--; oe--; ne--; }
    }
    final removedAtom = _a.sublist(p, oe).any((a) => a != null);
    final ins = ne - p;
    final kind = removedAtom ? 'other' : ins > 0 ? 'type' : 'del';
    _pushHistory(kind, p: p, oe: oe, ne: ne, selBefore: selection);
    final mk = isRich ? (_pending ?? _inheritAt(p, oe)) : const Mks();
    _f.replaceRange(p, oe, List.filled(ins, mk.f));
    _c.replaceRange(p, oe, List.filled(ins, mk.c));
    _a.replaceRange(p, oe, List.filled(ins, null));
    return v;
  }

  void _setValueNoDiff(TextEditingValue v) { _applying = true; value = v; _applying = false; }

  /// Replace [s,e) by [cells] (marks/atoms preserved). Used for paste/cut/insert.
  void replaceRange(int s, int e, List<Cell> cells) {
    s = s.clamp(0, text.length); e = e.clamp(s, text.length);
    _pushHistory('other');
    final nt = text.replaceRange(s, e, cells.map((x) => x.ch).join());
    _f.replaceRange(s, e, cells.map((x) => x.f));
    _c.replaceRange(s, e, cells.map((x) => x.c));
    _a.replaceRange(s, e, cells.map((x) => x.a));
    _setValueNoDiff(TextEditingValue(text: nt, selection: TextSelection.collapsed(offset: s + cells.length)));
  }

  List<Cell> _cellsOfText(String t, {Mks? mk}) {
    final m = mk ?? (isRich ? (_pending ?? _inheritAt(selection.isValid ? selection.start : text.length)) : const Mks());
    return [for (var i = 0; i < t.length; i++) Cell(t[i], m.f, m.c, null)];
  }

  TextRange get _selRange => selection.isValid ? TextRange(start: selection.start, end: selection.end) : TextRange(start: text.length, end: text.length);

  void insertPlain(String t) {
    t = t.replaceAll('\r\n', '\n').replaceAll('\r', '\n').replaceAll(kPh, '');
    final r = _selRange; replaceRange(r.start, r.end, _cellsOfText(t));
  }

  /// Insert an <img> atom at the caret/selection (rich mode) or markup text (source mode).
  void insertImage(String src) {
    final markup = '<img src="${src.replaceAll('"', '&quot;')}">';
    final r = _selRange;
    if (!isRich) { replaceRange(r.start, r.end, _cellsOfText(markup)); return; }
    replaceRange(r.start, r.end, [Cell(kPh, 0, null, Seg.token(markup, TokenKind.img))]);
  }

  /// HTML paste hook (sanitised per scope E9(다): media tags stripped). Returns number of removed items to notify.
  int pasteHtml(String html) {
    final res = sanitizer(allowImages: false)(html);
    final r = _selRange;
    if (!isRich) { replaceRange(r.start, r.end, _cellsOfText(res.html)); return res.removed; }
    final issues = <String>[];
    final segs = parseFieldIssues(res.html, false, issues);
    final cells = <Cell>[];
    for (final s in segs) {
      if (s.isToken) { cells.add(Cell(kPh, 0, null, s)); continue; }
      final fl = (s.bold ? 1 : 0) | (s.italic ? 2 : 0) | (s.underline ? 4 : 0) | (s.sup ? 8 : 0) | (s.sub ? 16 : 0);
      for (var i = 0; i < s.text.length; i++) { cells.add(Cell(s.text[i], fl, s.color, null)); }
    }
    replaceRange(r.start, r.end, cells);
    return res.removed;
  }

  static _Clip? _clip;
  String _plainOf(List<Cell> cells) => cells.map((c) => c.a?.token ?? c.ch).join();
  /// Copy selection: returns the system-clipboard plain text; keeps marks/atoms in an in-process clip.
  String? copySelection() {
    final r = _selRange; if (r.isCollapsed) return null;
    final cells = [for (var i = r.start; i < r.end; i++) Cell(text[i], _f[i], _c[i], _a[i])];
    final plain = _plainOf(cells);
    _clip = _Clip(plain, cells);
    return plain;
  }
  String? cutSelection() {
    final p = copySelection(); if (p == null) return null;
    final r = _selRange; replaceRange(r.start, r.end, const []); return p;
  }
  void pasteText(String t) {
    final c = _clip;
    if (c != null && isRich && c.plain == t) { final r = _selRange; replaceRange(r.start, r.end, c.cells); return; }
    insertPlain(t);
  }

  // ---- delete atom with Backspace/Delete is handled by EditableText (atom = 1 code unit) ----

  // ---- history ----
  final List<_Snap> _undo = [];
  final List<_Snap> _redo = [];
  String _lastKind = '';
  int _lastP = 0, _lastEnd = 0;
  void _breakCoalesce() { _lastKind = ''; }
  _Snap _snap() => _Snap(text, List.of(_f), List.of(_c), List.of(_a), selection, _pending);
  void _pushHistory(String kind, {int p = 0, int oe = 0, int ne = 0, TextSelection? selBefore}) {
    var coalesce = false;
    if (kind == 'type' && _lastKind == 'type' && p <= _lastEnd && p >= _lastP) { coalesce = true; }
    if (kind == 'del' && _lastKind == 'del' && (p == _lastP || oe == _lastP)) { coalesce = true; }
    if (!coalesce) { final s = _snap(); _undo.add(selBefore == null ? s : _Snap(s.text, s.f, s.c, s.a, selBefore, s.pending)); if (_undo.length > 200) _undo.removeAt(0); }
    if (kind == 'type') { _lastP = coalesce ? _lastP : p; _lastEnd = ne; } else { _lastP = p; _lastEnd = p; }
    _lastKind = kind;
    _redo.clear();
  }
  bool get canUndo => _undo.isNotEmpty;
  bool get canRedo => _redo.isNotEmpty;
  void _restore(_Snap s) {
    _f..clear()..addAll(s.f); _c..clear()..addAll(s.c); _a..clear()..addAll(s.a);
    _pending = s.pending;
    _setValueNoDiff(TextEditingValue(text: s.text, selection: s.sel.isValid ? s.sel : TextSelection.collapsed(offset: s.text.length)));
    notifyListeners();
  }
  bool undo() { if (_undo.isEmpty) return false; _redo.add(_snap()); _breakCoalesce(); _restore(_undo.removeLast()); return true; }
  bool redo() { if (_redo.isEmpty) return false; _undo.add(_snap()); _breakCoalesce(); _restore(_redo.removeLast()); return true; }

  // ---- encode / save ----
  bool get dirty {
    final i = _initial;
    if (i.text != text) return true;
    for (var k = 0; k < _f.length; k++) { if (i.f[k] != _f[k] || i.c[k] != _c[k] || i.a[k]?.token != _a[k]?.token) return true; }
    return false;
  }

  List<Seg> toSegs() {
    final out = <Seg>[]; final sb = StringBuffer(); int? cf; String? cc;
    void flush() { if (cf != null) { out.add(Seg.text(sb.toString(), bold: cf! & 1 != 0, italic: cf! & 2 != 0, underline: cf! & 4 != 0, sup: cf! & 8 != 0, sub: cf! & 16 != 0, color: cc)); sb.clear(); cf = null; } }
    for (var i = 0; i < text.length; i++) {
      if (_a[i] != null) { flush(); out.add(_a[i]!); continue; }
      if (cf != _f[i] || cc != _c[i]) { flush(); cf = _f[i]; cc = _c[i]; }
      sb.write(text[i]);
    }
    flush();
    return out;
  }
  /// Always-encode (ignores dirty). Rich mode only; source mode returns the text.
  String toHtml() => isRich ? serializeField(toSegs()) : text;

  int lastSaveRemoved = 0;
  /// Untouched => ORIGINAL BYTES. Rich dirty => encode. Source-edit dirty => sanitizer.
  String save() {
    lastSaveRemoved = 0;
    if (!dirty) return original;
    if (isRich) return serializeField(toSegs());
    final r = _sanitize(text); lastSaveRemoved = r.removed; return r.html;
  }

  // ---- rendering ----
  final Map<String, Uint8List?> _thumbCache = {};
  Uint8List? _thumb(String src) {
    final dir = mediaDir; if (dir == null) return null;
    return _thumbCache.putIfAbsent(src, () {
      for (final name in {src, Uri.decodeFull(src)}) { final f = File('$dir/$name'); if (f.existsSync()) { try { return f.readAsBytesSync(); } catch (_) {} } }
      return null;
    });
  }
  /// Test hook: thumbnail bytes to pre-cache.
  List<Uint8List> thumbBytes() => [for (final s in _a.whereType<Seg>().where((s) => s.kind == TokenKind.img)) if (_thumb(imgSrc(s.token!)) != null) _thumb(imgSrc(s.token!))!];

  static String imgSrc(String markup) {
    final m = RegExp(r'''src\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))''', caseSensitive: false).firstMatch(markup);
    return (m?.group(1) ?? m?.group(2) ?? m?.group(3) ?? '').replaceAll('&quot;', '"').replaceAll('&amp;', '&');
  }
  static String rawLabel(String markup) {
    if (markup.startsWith('<!--')) return '<!-- -->';
    final m = RegExp(r'^<\s*([a-zA-Z0-9-]+)').firstMatch(markup);
    return '<${m?.group(1) ?? '?'}>';
  }

  static const thumbW = 64.0, thumbH = 48.0;
  // NOTE: the outermost widget must be a plain sized box: RenderEditable asks inline children for intrinsic
  // sizes, and Tooltip (OverlayPortal) reports 0 height -> the field would not grow for the thumbnail.
  Widget _atomWidget(Seg s, TextStyle base) {
    if (s.kind == TokenKind.img) {
      final src = imgSrc(s.token!); final bytes = _thumb(src);
      return Container(width: thumbW, height: thumbH, margin: const EdgeInsets.symmetric(horizontal: 2),
        decoration: BoxDecoration(color: const Color(0xfff0f0f0), border: Border.all(color: const Color(0xffb0b0b0)), borderRadius: BorderRadius.circular(3)),
        clipBehavior: Clip.antiAlias,
        child: Tooltip(message: src, child: bytes != null
            ? Image.memory(bytes, fit: BoxFit.cover, width: thumbW, height: thumbH, gaplessPlayback: true, errorBuilder: (_, _, _) => _imgPlaceholder(src, base))
            : _imgPlaceholder(src, base)));
    }
    final src = s.token!;
    return Container(margin: const EdgeInsets.symmetric(horizontal: 2), padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
      decoration: BoxDecoration(color: const Color(0xffe0e8ff), border: Border.all(color: const Color(0xff9db0e8)), borderRadius: BorderRadius.circular(3)),
      child: Tooltip(message: src.length > 400 ? '${src.substring(0, 400)}…' : src, waitDuration: const Duration(milliseconds: 300),
        child: Text(rawLabel(src), style: base.copyWith(fontSize: 12, color: const Color(0xff2a3f8a), fontWeight: FontWeight.normal, fontStyle: FontStyle.normal, decoration: TextDecoration.none))));
  }
  Widget _imgPlaceholder(String src, TextStyle base) => Center(child: Padding(padding: const EdgeInsets.all(2), child: Column(mainAxisSize: MainAxisSize.min, children: [
    const Icon(Icons.image_outlined, size: 18, color: Color(0xff888888)),
    Text(src, maxLines: 1, overflow: TextOverflow.ellipsis, style: base.copyWith(fontSize: 9, color: const Color(0xff666666), fontWeight: FontWeight.normal, fontStyle: FontStyle.normal, decoration: TextDecoration.none))])));

  // Flutter TextStyle has no baseline shift. Per character: (1) the font's sups/subs glyph if the font has one
  // (probed by measuring), (2) same-length Unicode super/subscript glyph (digits + - = ( )), (3) smaller size only.
  static final Map<String, bool> _featCache = {};
  static bool _supports(TextStyle base, FontFeature f, String ch) => _featCache.putIfAbsent('${base.fontFamily}|${base.fontFamilyFallback}|${f.feature}|$ch', () {
    double w(TextStyle t) { final tp = TextPainter(text: TextSpan(text: ch, style: t), textDirection: TextDirection.ltr)..layout(); final r = tp.width; tp.dispose(); return r; }
    final b = base.copyWith(fontSize: 16, fontFeatures: const []);
    return (w(b) - w(b.copyWith(fontFeatures: [f]))).abs() > 0.3;
  });
  static const _supU = '⁰¹²³⁴⁵⁶⁷⁸⁹⁺⁻⁼⁽⁾', _subU = '₀₁₂₃₄₅₆₇₈₉₊₋₌₍₎', _srcU = '0123456789+-=()';
  List<InlineSpan> _scriptSpans(String t, TextStyle st, TextStyle base, bool sup) {
    final feat = sup ? const FontFeature.superscripts() : const FontFeature.subscripts();
    final out = <InlineSpan>[]; final sb = StringBuffer(); var mode = -1;
    TextStyle sty(int m) => m == 0 ? st.copyWith(fontFeatures: [feat]) : m == 1 ? st : st.copyWith(fontSize: (st.fontSize ?? 16) * .7);
    void flush() { if (sb.isNotEmpty) { out.add(TextSpan(text: sb.toString(), style: sty(mode))); sb.clear(); } }
    for (var k = 0; k < t.length; k++) {
      final ch = t[k]; final u = _srcU.indexOf(ch);
      final m = _supports(base, feat, ch) ? 0 : (u >= 0 ? 1 : 2);
      if (m != mode) { flush(); mode = m; }
      sb.write(m == 1 ? (sup ? _supU : _subU)[u] : ch);
    }
    flush();
    return out;
  }

  static Color parseColor(String c) {
    var h = c.replaceFirst('#', '');
    if (h.length == 3) h = h.split('').map((x) => x + x).join();
    return Color(int.parse('ff$h', radix: 16));
  }

  @override
  TextSpan buildTextSpan({required BuildContext context, TextStyle? style, required bool withComposing}) {
    final base = style ?? const TextStyle();
    if (!isRich) return super.buildTextSpan(context: context, style: style, withComposing: withComposing);
    final kids = <InlineSpan>[]; final comp = value.composing;
    final hasComp = withComposing && comp.isValid && !comp.isCollapsed;
    var i = 0;
    while (i < text.length) {
      if (_a[i] != null) { kids.add(WidgetSpan(alignment: PlaceholderAlignment.middle, child: _atomWidget(_a[i]!, base))); i++; continue; }
      final f = _f[i]; final c = _c[i]; final ic = hasComp && i >= comp.start && i < comp.end;
      var j = i + 1;
      while (j < text.length && _a[j] == null && _f[j] == f && _c[j] == c && (hasComp && j >= comp.start && j < comp.end) == ic) { j++; }
      var st = base;
      if (f & 1 != 0) st = st.copyWith(fontWeight: FontWeight.bold);
      if (f & 2 != 0) st = st.copyWith(fontStyle: FontStyle.italic);
      if (f & 4 != 0 || ic) st = st.copyWith(decoration: TextDecoration.underline);
      if (c != null) st = st.copyWith(color: parseColor(c));
      if (f & 24 != 0) { kids.addAll(_scriptSpans(text.substring(i, j), st, base, f & 8 != 0)); } else { kids.add(TextSpan(text: text.substring(i, j), style: st)); }
      i = j;
    }
    return TextSpan(style: base, children: kids);
  }
}

// ======================= widgets =======================

class _BoldIntent extends Intent { const _BoldIntent(this.k); final RK k; }
class _UndoI extends Intent { const _UndoI(); }
class _RedoI extends Intent { const _RedoI(); }

final _caretKeys = <LogicalKeyboardKey>{LogicalKeyboardKey.arrowLeft, LogicalKeyboardKey.arrowRight, LogicalKeyboardKey.arrowUp, LogicalKeyboardKey.arrowDown,
  LogicalKeyboardKey.home, LogicalKeyboardKey.end, LogicalKeyboardKey.pageUp, LogicalKeyboardKey.pageDown};

Map<ShortcutActivator, Intent> _shortcuts() {
  final m = <ShortcutActivator, Intent>{};
  for (final mod in [(true, false), (false, true)]) {
    SingleActivator a(LogicalKeyboardKey k, {bool shift = false}) => SingleActivator(k, control: mod.$1, meta: mod.$2, shift: shift);
    m[a(LogicalKeyboardKey.keyB)] = const _BoldIntent(RK.bold);
    m[a(LogicalKeyboardKey.keyI)] = const _BoldIntent(RK.italic);
    m[a(LogicalKeyboardKey.keyU)] = const _BoldIntent(RK.underline);
    // Anki convention: Ctrl+= subscript, Ctrl+Shift+= superscript
    m[a(LogicalKeyboardKey.equal)] = const _BoldIntent(RK.sub);
    m[a(LogicalKeyboardKey.equal, shift: true)] = const _BoldIntent(RK.sup);
    m[a(LogicalKeyboardKey.add, shift: true)] = const _BoldIntent(RK.sup);
    m[a(LogicalKeyboardKey.keyZ)] = const _UndoI();
    m[a(LogicalKeyboardKey.keyZ, shift: true)] = const _RedoI();
  }
  m[const SingleActivator(LogicalKeyboardKey.keyY, control: true)] = const _RedoI();
  return m;
}

/// The bare editable surface (no toolbar). Keeps the old (c, focus) constructor used by the IME probe apps.
class EditableField extends StatefulWidget {
  const EditableField(this.c, this.focus, {super.key, this.undo, this.width = 420, this.minLines = 2, this.fontFamily = 'NanumGothic', this.fontFamilyFallback, this.onClipboardNotice});
  final FieldController c; final FocusNode focus; final UndoHistoryController? undo; final double width; final int minLines; final String fontFamily; final List<String>? fontFamilyFallback;
  final void Function(String)? onClipboardNotice;
  @override State<EditableField> createState() => _EditableFieldState();
}

class _EditableFieldState extends State<EditableField> {
  FieldController get c => widget.c;
  FocusNode get focus => widget.focus;
  @override
  Widget build(BuildContext context) {
    final width = widget.width, minLines = widget.minLines, fontFamily = widget.fontFamily, fontFamilyFallback = widget.fontFamilyFallback, undo = widget.undo;
    final editStyle = TextStyle(fontSize: 16, color: Colors.black, fontFamily: fontFamily, fontFamilyFallback: fontFamilyFallback);
    return SizedBox(width: width, child: Container(padding: const EdgeInsets.all(8), decoration: BoxDecoration(border: Border.all(color: c.isRich ? Colors.grey : const Color(0xffd08000), width: c.isRich ? 1 : 1.5), color: Colors.white),
      child: Shortcuts(shortcuts: _shortcuts(), child: Actions(actions: {
        _BoldIntent: CallbackAction<_BoldIntent>(onInvoke: (i) { c.toggleMark(i.k); return null; }),
        _UndoI: CallbackAction<_UndoI>(onInvoke: (_) { c.undo(); return null; }),
        _RedoI: CallbackAction<_RedoI>(onInvoke: (_) { c.redo(); return null; }),
        UndoTextIntent: CallbackAction<UndoTextIntent>(onInvoke: (_) { c.undo(); return null; }),
        RedoTextIntent: CallbackAction<RedoTextIntent>(onInvoke: (_) { c.redo(); return null; }),
        CopySelectionTextIntent: CallbackAction<CopySelectionTextIntent>(onInvoke: (i) {
          final t = i.collapseSelection ? c.cutSelection() : c.copySelection();
          if (t != null) Clipboard.setData(ClipboardData(text: t));
          return null;
        }),
        PasteTextIntent: CallbackAction<PasteTextIntent>(onInvoke: (_) async {
          final d = await Clipboard.getData(Clipboard.kTextPlain);
          if (d?.text != null) c.pasteText(d!.text!);
          return null;
        }),
      }, child: Focus(canRequestFocus: false, skipTraversal: true,
        onKeyEvent: (n, e) { if ((e is KeyDownEvent || e is KeyRepeatEvent) && _caretKeys.contains(e.logicalKey)) c.userMovedCaret(); return KeyEventResult.ignored; },
        child: Listener(onPointerDown: (_) => c.userMovedCaret(),
          child: EditableText(controller: c, focusNode: focus, style: editStyle,
            // EditableText defaults to forceStrutHeight:true, which clamps every line to text height so inline thumbnails overflow.
            strutStyle: StrutStyle.fromTextStyle(editStyle, forceStrutHeight: false), cursorColor: Colors.blue, backgroundCursorColor: Colors.grey,
            maxLines: null, minLines: minLines, selectionColor: Colors.blue.withValues(alpha: .3), undoController: undo)))))));
  }
}

const kPalette = <String?>[null, '#d32f2f', '#ef6c00', '#2e7d32', '#1565c0', '#6a1b9a', '#757575'];

/// Minimal toolbar: active state reflects selection marks or pending marks.
class FieldToolbar extends StatefulWidget {
  const FieldToolbar(this.c, this.focus, {super.key, this.onImage, this.initialPaletteOpen = false});
  final FieldController c; final FocusNode focus; final VoidCallback? onImage; final bool initialPaletteOpen;
  @override State<FieldToolbar> createState() => _FieldToolbarState();
}
class _FieldToolbarState extends State<FieldToolbar> {
  late bool open = widget.initialPaletteOpen;
  Widget _b(String key, Widget child, bool active, VoidCallback? onTap, String tip) => Tooltip(message: tip, child: GestureDetector(
    key: ValueKey(key), behavior: HitTestBehavior.opaque, onTap: onTap,
    child: Container(width: 30, height: 28, alignment: Alignment.center, margin: const EdgeInsets.only(right: 3),
      decoration: BoxDecoration(color: active ? const Color(0xffd6e4ff) : Colors.transparent, border: Border.all(color: active ? const Color(0xff4a78d0) : const Color(0xffcccccc)), borderRadius: BorderRadius.circular(4)),
      child: child)));
  @override
  Widget build(BuildContext context) {
    final c = widget.c;
    return TextFieldTapRegion(child: ExcludeFocus(child: ListenableBuilder(listenable: c, builder: (_, __) {
      final m = c.activeMarks; final rich = c.isRich;
      TextStyle t(TextStyle s) => s.copyWith(fontSize: 14, color: Colors.black, fontFamily: 'NanumGothic', decoration: TextDecoration.none);
      void tog(RK k) { c.toggleMark(k); }
      return Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        Row(mainAxisSize: MainAxisSize.min, children: [
          if (!rich) Container(padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3), decoration: BoxDecoration(color: const Color(0xfffff0d6), borderRadius: BorderRadius.circular(4)), child: Text('HTML 원문 편집', style: t(const TextStyle()))),
          if (rich) ...[
            _b('tb-bold', Text('B', style: t(const TextStyle(fontWeight: FontWeight.bold))), m.has(RK.bold), () => tog(RK.bold), '굵게 (Ctrl/Cmd+B)'),
            _b('tb-italic', Text('I', style: t(const TextStyle(fontStyle: FontStyle.italic))), m.has(RK.italic), () => tog(RK.italic), '기울임 (Ctrl/Cmd+I)'),
            _b('tb-underline', Text('U', style: t(const TextStyle(decoration: TextDecoration.underline))), m.has(RK.underline), () => tog(RK.underline), '밑줄 (Ctrl/Cmd+U)'),
            _b('tb-sup', Text('x²', style: t(const TextStyle())), m.has(RK.sup), () => tog(RK.sup), '위첨자 (Ctrl/Cmd+Shift+=)'),
            _b('tb-sub', Text('x₂', style: t(const TextStyle())), m.has(RK.sub), () => tog(RK.sub), '아래첨자 (Ctrl/Cmd+=)'),
            _b('tb-color', Column(mainAxisSize: MainAxisSize.min, children: [Text('A', style: t(const TextStyle(fontWeight: FontWeight.bold))), Container(width: 16, height: 3, color: m.c != null ? FieldController.parseColor(m.c!) : Colors.black)]), m.c != null || open, () => setState(() => open = !open), '글자색'),
            const SizedBox(width: 6),
            _b('tb-img', const Icon(Icons.image_outlined, size: 16), false, widget.onImage ?? () => c.insertImage('paste-new.png'), '이미지 넣기'),
            const SizedBox(width: 6),
            _b('tb-undo', const Icon(Icons.undo, size: 16), false, c.canUndo ? c.undo : null, '되돌리기'),
            _b('tb-redo', const Icon(Icons.redo, size: 16), false, c.canRedo ? c.redo : null, '다시 실행'),
          ],
        ]),
        if (open && rich) Padding(padding: const EdgeInsets.only(top: 4), child: Container(key: const ValueKey('palette'), padding: const EdgeInsets.all(4), decoration: BoxDecoration(color: Colors.white, border: Border.all(color: const Color(0xffcccccc)), borderRadius: BorderRadius.circular(4)),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            for (final col in kPalette) GestureDetector(key: ValueKey('swatch-${col ?? 'none'}'), onTap: () { c.setColor(col); setState(() => open = false); },
              child: Container(width: 22, height: 22, margin: const EdgeInsets.only(right: 4), alignment: Alignment.center,
                decoration: BoxDecoration(color: col == null ? Colors.white : FieldController.parseColor(col), border: Border.all(color: m.c == col ? Colors.black : const Color(0xffaaaaaa), width: m.c == col ? 2 : 1), borderRadius: BorderRadius.circular(11)),
                child: col == null ? const Text('✕', style: TextStyle(fontSize: 11, color: Colors.black87, decoration: TextDecoration.none)) : null)),
          ]))),
      ]);
    })));
  }
}

/// Toolbar + surface.
class FieldEditor extends StatelessWidget {
  const FieldEditor(this.c, this.focus, {super.key, this.width = 420, this.onImage, this.paletteOpen = false, this.fontFamily = 'NanumGothic', this.fontFamilyFallback});
  final String fontFamily; final List<String>? fontFamilyFallback; final FieldController c; final FocusNode focus; final double width; final VoidCallback? onImage; final bool paletteOpen;
  @override
  Widget build(BuildContext context) => SizedBox(width: width, child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
    FieldToolbar(c, focus, onImage: onImage, initialPaletteOpen: paletteOpen), const SizedBox(height: 6), EditableField(c, focus, width: width, fontFamily: fontFamily, fontFamilyFallback: fontFamilyFallback)]));
}
