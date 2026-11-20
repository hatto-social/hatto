// SPDX-FileCopyrightText: 2026 Hatto Social contributors
//
// SPDX-License-Identifier: AGPL-3.0-or-later

// Prototype B (v0 "minimum usable editor"): EditableText + custom TextEditingController.
// Model: text with U+FFFC per atom (<img>, opaque raw HTML) + per-code-unit mark flags/color + atom table.
// See v0 scope: GINA_EDITOR_FORMAT_SCOPE.md / DMITRY_EDITOR_FORMAT_SCOPE_TABLE.md.
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'field_codec.dart';
import 'sanitize.dart';
import 'anki_ui.dart';

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
  @override bool operator ==(Object other) => other is Mks && other.f == f && other.c == c;
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
  FieldController(String html, {bool strict = false, bool wsNormalize = false, this.mediaDir, this.forcedByUser = false})
      : original = html, analysis = forcedByUser ? Analysis(const [], const ['user-requested HTML source edit (FLAGGED option, not in contract)']) : analyzeField(html, strict: strict, wsNormalize: wsNormalize) {
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
  /// FLAGGED (not contract): true only when the UI's voluntary "HTML editor" toggle opened this field in source mode.
  final bool forcedByUser;
  String? mediaDir;
  /// When non-null, selected text is drawn in this colour (Anki's webview paints selected text white). Set by the field widget while focused.
  Color? selectionFg;
  /// Theme for tooltips of inline atoms (chips/thumbnails are built here, below no BuildContext). Set by EditableField.
  AnkiColors tipColors = AnkiColors.light;
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
  /// Untouched => original bytes. Rich dirty => encode. Source-edit dirty =>
  /// the editor text unchanged. Clipboard HTML paste is the only sanitizer.
  String save() {
    lastSaveRemoved = 0;
    if (!dirty) return original;
    if (isRich) return serializeField(toSegs());
    return text;
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
        child: AnkiTooltip(message: src, colors: tipColors, child: bytes != null
            ? Image.memory(bytes, fit: BoxFit.cover, width: thumbW, height: thumbH, gaplessPlayback: true, errorBuilder: (_, _, _) => _imgPlaceholder(src, base))
            : _imgPlaceholder(src, base)));
    }
    final src = s.token!;
    return Container(margin: const EdgeInsets.symmetric(horizontal: 2), padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
      decoration: BoxDecoration(color: const Color(0xffe0e8ff), border: Border.all(color: const Color(0xff9db0e8)), borderRadius: BorderRadius.circular(3)),
      child: AnkiTooltip(message: src.length > 400 ? '${src.substring(0, 400)}…' : src, colors: tipColors, waitDuration: const Duration(milliseconds: 300),
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
    final sl = selection; final hasSel = selectionFg != null && sl.isValid && !sl.isCollapsed;
    bool inSel(int k) => hasSel && k >= sl.start && k < sl.end;
    var i = 0;
    while (i < text.length) {
      if (_a[i] != null) { kids.add(WidgetSpan(alignment: PlaceholderAlignment.middle, child: _atomWidget(_a[i]!, base))); i++; continue; }
      final f = _f[i]; final c = _c[i]; final ic = hasComp && i >= comp.start && i < comp.end; final isl = inSel(i);
      var j = i + 1;
      while (j < text.length && _a[j] == null && _f[j] == f && _c[j] == c && (hasComp && j >= comp.start && j < comp.end) == ic && inSel(j) == isl) { j++; }
      var st = base;
      if (f & 1 != 0) st = st.copyWith(fontWeight: FontWeight.bold);
      if (f & 2 != 0) st = st.copyWith(fontStyle: FontStyle.italic);
      if (f & 4 != 0 || ic) st = st.copyWith(decoration: TextDecoration.underline);
      if (c != null) st = st.copyWith(color: parseColor(c));
      if (isl) st = st.copyWith(color: selectionFg);
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

/// Anki field frame (EditorField.svelte:149-167 `.editor-field`): 1px --border, radius 5, elevation(1), 2px --border-focus ring
/// drawn as an outline that covers the border and sticks 1px out (outline-offset:-1px; margin:1px makes room).
class AnkiFieldFrame extends StatelessWidget {
  const AnkiFieldFrame({super.key, required this.focused, required this.child, this.bg, this.dupe = false});
  final bool focused, dupe; final Widget child; final Color? bg;
  @override
  Widget build(BuildContext context) {
    final c = AnkiTheme.of(context);
    return Padding(padding: const EdgeInsets.all(1), child: Stack(clipBehavior: Clip.none, children: [
      Container(
        decoration: BoxDecoration(color: bg ?? c.canvasElevated, borderRadius: BorderRadius.circular(AnkiMetrics.radius), border: Border.all(color: c.border),
          boxShadow: const [BoxShadow(color: Color(0x33141414), offset: Offset(0, 2), blurRadius: 1, spreadRadius: -1), BoxShadow(color: Color(0x24141414), offset: Offset(0, 1), blurRadius: 1), BoxShadow(color: Color(0x1f141414), offset: Offset(0, 1), blurRadius: 3)]),
        clipBehavior: Clip.antiAlias, child: child),
      if (focused || dupe) Positioned(left: -1, top: -1, right: -1, bottom: -1, child: IgnorePointer(child: DecoratedBox(key: const ValueKey('focus-ring'),
        decoration: BoxDecoration(borderRadius: BorderRadius.circular(AnkiMetrics.radius + 1), border: Border.all(color: dupe ? c.danger : c.borderFocus, width: 2))))),
    ]));
  }
}

/// The editable surface (Anki `.rich-text-input` / CodeMirror source pane look). Keeps the (c, focus) constructor used by the IME probes.
class EditableField extends StatefulWidget {
  const EditableField(this.c, this.focus, {super.key, this.undo, this.width = 420, this.minLines = 1, this.fontFamily = 'NanumGothic', this.fontFamilyFallback, this.onClipboardNotice});
  final FieldController c; final FocusNode focus; final UndoHistoryController? undo; final double? width; final int minLines; final String fontFamily; final List<String>? fontFamilyFallback;
  final void Function(String)? onClipboardNotice;
  @override State<EditableField> createState() => _EditableFieldState();
}

class _EditableFieldState extends State<EditableField> {
  FieldController get c => widget.c;
  FocusNode get focus => widget.focus;
  @override void initState() { super.initState(); focus.addListener(_f); }
  @override void didUpdateWidget(EditableField o) { super.didUpdateWidget(o); if (o.focus != focus) { o.focus.removeListener(_f); focus.addListener(_f); } }
  @override void dispose() { focus.removeListener(_f); super.dispose(); }
  void _f() => setState(() {});
  @override
  Widget build(BuildContext context) {
    final k = AnkiTheme.of(context);
    final width = widget.width, minLines = widget.minLines, undo = widget.undo;
    c.selectionFg = focus.hasFocus && c.isRich ? Colors.white : null;
    c.tipColors = k;
    final rich = c.isRich;
    // Rich: field font from the notetype (Anki default Arial 20px, line box 30px). Source mode: Anki CodeMirror = monospace 15px.
    final editStyle = rich
        ? TextStyle(fontSize: AnkiMetrics.fieldFontSize, height: AnkiMetrics.fieldLineHeight, color: k.fg, fontFamily: widget.fontFamily, fontFamilyFallback: widget.fontFamilyFallback)
        : TextStyle(fontSize: 15, height: 1.5, color: k.fg, fontFamily: 'DejaVu Sans Mono', fontFamilyFallback: const ['NanumGothicCoding', 'NanumGothic']);
    final surface = Container(color: rich ? k.canvasElevated : k.canvasCode, padding: const EdgeInsets.all(AnkiMetrics.inputPad),
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
            strutStyle: StrutStyle.fromTextStyle(editStyle, forceStrutHeight: false), cursorColor: k.fg, backgroundCursorColor: Colors.grey,
            maxLines: null, minLines: minLines, selectionColor: k.selectionBg, undoController: undo))))));
    final framed = AnkiFieldFrame(focused: focus.hasFocus, child: surface);
    return width == null ? framed : SizedBox(width: width, child: framed);
  }
}

void _noop() {}
const kPalette = <String?>[null, '#d32f2f', '#ef6c00', '#2e7d32', '#1565c0', '#6a1b9a', '#757575'];
const kDefaultTextColor = '#1565c0'; // initial "last used" colour shown in the A button's bar (Anki shows blue)

/// Anki editor toolbar (editor-toolbar/*.svelte) for ONE focused field controller. Disabled when [c] is null or the field is in source mode
/// (CommandIconButton.svelte:33 `disabled = !$focusedInput || !editingInputIsRichText`). v0 scope: only Tier-1 marks + image are live;
/// everything else Anki shows is rendered disabled (or omitted when [showNotetypeButtons] is false) and listed in the design review.
class FieldToolbar extends StatefulWidget {
  const FieldToolbar(this.c, this.focus, {super.key, this.onImage, this.initialPaletteOpen = false, this.showNotetypeButtons = false});
  final FieldController? c; final FocusNode? focus; final VoidCallback? onImage; final bool initialPaletteOpen, showNotetypeButtons;
  @override State<FieldToolbar> createState() => _FieldToolbarState();
}
class _FieldToolbarState extends State<FieldToolbar> {
  final _ctl = OverlayPortalController();
  final _link = LayerLink();
  String lastColor = kDefaultTextColor;
  @override void initState() { super.initState(); if (widget.initialPaletteOpen) WidgetsBinding.instance.addPostFrameCallback((_) { if (mounted) _ctl.show(); }); }

  Widget _icon(Color fg, String n, {double size = AnkiMetrics.iconSize}) => AnkiIcon.one(n, fg, size: size);
  AnkiButton _b(String key, Widget Function(Color) icon, bool active, VoidCallback? onTap, String tip, double l, double r, {double w = AnkiMetrics.buttonSize}) =>
      AnkiButton(buttonKey: ValueKey(key), labelBuilder: icon, active: active, onTap: onTap, tooltip: tip, leftRadius: l, rightRadius: r, width: w, child: const SizedBox());

  @override
  Widget build(BuildContext context) {
    final k = AnkiTheme.of(context);
    final c = widget.c;
    Widget content(FieldController? c) {
      final rich = c?.isRich ?? false; final live = c != null && rich;
      final m = live ? c.activeMarks : const Mks();
      void tog(RK r) => c!.toggleMark(r);
      VoidCallback? on(VoidCallback f) => live ? f : null;
      Widget grp(List<Widget Function(double, double)> b) => AnkiGroup(b);
      final items = <Widget>[
        if (widget.showNotetypeButtons) ...[
          grp([(l, r) => AnkiButton(width: 70, leftRadius: l, rightRadius: 0, tooltip: '필드 편집 (목업, 백엔드 없음)', onTap: _noop, labelBuilder: (fg) => Text('필드…', style: ankiText(k, color: fg).copyWith(height: 1)), child: const SizedBox()),
               (l, r) => AnkiButton(width: 70, leftRadius: 0, rightRadius: r, tooltip: '카드 편집 (목업, 백엔드 없음)', onTap: _noop, labelBuilder: (fg) => Text('카드…', style: ankiText(k, color: fg).copyWith(height: 1)), child: const SizedBox())]),
          grp([(l, r) => AnkiButton(width: 40, leftRadius: l, rightRadius: r, tooltip: '옵션 (목업, 백엔드 없음)', onTap: _noop, labelBuilder: (fg) => _icon(fg, 'gear'), child: const SizedBox())]),
        ],
        grp([
          (l, r) => _b('tb-bold', (fg) => _icon(fg, 'bold'), m.has(RK.bold), on(() => tog(RK.bold)), '굵게 (Ctrl/Cmd+B)', l, 0),
          (l, r) => _b('tb-italic', (fg) => _icon(fg, 'italic'), m.has(RK.italic), on(() => tog(RK.italic)), '기울임 (Ctrl/Cmd+I)', 0, 0),
          (l, r) => _b('tb-underline', (fg) => _icon(fg, 'underline'), m.has(RK.underline), on(() => tog(RK.underline)), '밑줄 (Ctrl/Cmd+U)', 0, r),
        ]),
        grp([
          (l, r) => _b('tb-sup', (fg) => _icon(fg, 'superscript'), m.has(RK.sup), on(() => tog(RK.sup)), '위첨자 (Ctrl/Cmd+Shift+=)', l, 0),
          (l, r) => _b('tb-sub', (fg) => _icon(fg, 'subscript'), m.has(RK.sub), on(() => tog(RK.sub)), '아래첨자 (Ctrl/Cmd+=)', 0, r),
        ]),
        grp([
          // A = apply the colour shown in the bar; dropdown arrow = choose colour (Anki TextColorButton.svelte); key 'tb-color' stays on the chooser.
          (l, r) => _b('tb-color-apply', (fg) => AnkiIcon([ 'textColor', 'colorBar'], [fg, FieldController.parseColor(lastColor)]), false, on(() => c!.setColor(lastColor)), '글자색 적용', l, 0),
          (l, r) => CompositedTransformTarget(link: _link, child: _b('tb-color', (fg) => _icon(fg, 'chevronDown', size: 13.2), _ctl.isShowing, on(() { _ctl.toggle(); setState(() {}); }), '글자색 선택', 0, 0, w: AnkiMetrics.buttonMinWidth)),
          (l, r) => _b('tb-highlight', (fg) => AnkiIcon(['highlight', 'colorBar'], [fg, k.fgFaint]), false, null, '형광펜 — v0 계약에 없음(배경색 마크). 질문 Q1', 0, 0),
          (l, r) => _b('tb-highlight-arrow', (fg) => _icon(fg, 'chevronDown', size: 13.2), false, null, '형광펜 색 — v0 계약에 없음', 0, r, w: AnkiMetrics.buttonMinWidth),
        ]),
        grp([
          (l, r) => _b('tb-eraser', (fg) => _icon(fg, 'eraser'), false, null, '서식 지우기 — 범위표에 명시 없음. 질문 Q2', l, 0),
          (l, r) => _b('tb-eraser-arrow', (fg) => _icon(fg, 'chevronDown', size: 13.2), false, null, '지울 서식 선택 — 질문 Q2', 0, r, w: AnkiMetrics.buttonMinWidth),
        ]),
        grp([
          (l, r) => _b('tb-ul', (fg) => _icon(fg, 'listUl'), false, null, '목록 — v1', l, 0),
          (l, r) => _b('tb-ol', (fg) => _icon(fg, 'listOl'), false, null, '번호 목록 — v1', 0, 0),
          (l, r) => _b('tb-align', (fg) => _icon(fg, 'align'), false, null, '정렬 — v1(범위 밖)', 0, r),
        ]),
        grp([
          (l, r) => _b('tb-img', (fg) => _icon(fg, 'attach'), false, live ? (widget.onImage ?? () => c.insertImage('paste-new.png')) : null, '이미지 넣기 (데모 파일)', l, 0),
          (l, r) => _b('tb-mic', (fg) => _icon(fg, 'mic'), false, null, '녹음 — v0 범위이지만 이 프로토타입 밖(미구현)', 0, 0),
          (l, r) => _b('tb-equation', (fg) => _icon(fg, 'equation'), false, null, '수식 메뉴 — 에디터에서는 평문(\\(..\\)), 미리보기 몫', 0, r),
        ]),
        // not in Anki: undo/redo buttons (v0 requires its own undo; kept for mouse-only use and the existing tests)
        grp([
          (l, r) => _b('tb-undo', (fg) => AnkiGlyph('undo', fg), false, c != null && c.canUndo ? c.undo : null, '되돌리기 (Ctrl/Cmd+Z)', l, 0),
          (l, r) => _b('tb-redo', (fg) => AnkiGlyph('redo', fg), false, c != null && c.canRedo ? c.redo : null, '다시 실행 (Ctrl/Cmd+Shift+Z)', 0, r),
        ]),
        if (c != null && !rich) Container(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3.5),
          decoration: BoxDecoration(color: k.dark ? const Color(0xff5a4420) : const Color(0xfffff0d6), borderRadius: BorderRadius.circular(AnkiMetrics.radius)),
          child: Text('HTML 원문 편집', style: ankiText(k, size: 13).copyWith(height: 1.3))),
      ];
      return Padding(padding: const EdgeInsets.only(left: 2.25), child: Wrap(spacing: AnkiMetrics.groupGapX, runSpacing: AnkiMetrics.groupGapY, crossAxisAlignment: WrapCrossAlignment.center, children: items));
    }
    return TextFieldTapRegion(child: ExcludeFocus(child: ListenableBuilder(listenable: c ?? ValueNotifier(0), builder: (_, _) => OverlayPortal(
      controller: _ctl,
      overlayChildBuilder: (_) => CompositedTransformFollower(link: _link, targetAnchor: Alignment.bottomLeft, followerAnchor: Alignment.topLeft, offset: const Offset(-24, 3),
        child: Align(alignment: Alignment.topLeft, child: TextFieldTapRegion(child: _Palette(c: c, k: k, onPick: (col) { if (col != null) lastColor = col; c?.setColor(col); _ctl.hide(); setState(() {}); }, onClose: () { _ctl.hide(); setState(() {}); })))),
      child: Container(
        padding: const EdgeInsets.only(bottom: 6), // 4px toolbar padding + 2.25px group margin, rounded so the 1px border lands on a pixel row (Anki: border at y=74)
        decoration: BoxDecoration(border: Border(bottom: BorderSide(color: k.border))),
        child: content(c))))));
  }
}

/// Colour chooser popover. Anki opens a native Qt colour dialog here; the prototype keeps its own small palette (contract colours only).
class _Palette extends StatelessWidget {
  const _Palette({required this.c, required this.k, required this.onPick, required this.onClose});
  final FieldController? c; final AnkiColors k; final void Function(String?) onPick; final VoidCallback onClose;
  @override
  Widget build(BuildContext context) => TapRegion(onTapOutside: (_) => onClose(), child: Container(key: const ValueKey('palette'), padding: const EdgeInsets.all(6),
    decoration: ankiFloating(k),
    child: Row(mainAxisSize: MainAxisSize.min, children: [
      for (final col in kPalette) GestureDetector(key: ValueKey('swatch-${col ?? 'none'}'), onTap: () => onPick(col),
        child: MouseRegion(cursor: SystemMouseCursors.click, child: Container(width: 22, height: 22, margin: const EdgeInsets.symmetric(horizontal: 2), alignment: Alignment.center,
          decoration: BoxDecoration(color: col == null ? k.canvasElevated : FieldController.parseColor(col), border: Border.all(color: c?.activeMarks.c == col ? k.fg : k.border, width: c?.activeMarks.c == col ? 2 : 1), borderRadius: BorderRadius.circular(11)),
          child: col == null ? Text('✕', style: TextStyle(fontSize: 11, color: k.fg, decoration: TextDecoration.none)) : null))),
    ])));
}

/// Single-field harness (toolbar + surface); the note editor (note_editor.dart) composes the same pieces for many fields.
class FieldEditor extends StatelessWidget {
  const FieldEditor(this.c, this.focus, {super.key, this.width = 420, this.onImage, this.paletteOpen = false, this.fontFamily = 'NanumGothic', this.fontFamilyFallback});
  final String fontFamily; final List<String>? fontFamilyFallback; final FieldController c; final FocusNode focus; final double width; final VoidCallback? onImage; final bool paletteOpen;
  @override
  Widget build(BuildContext context) => SizedBox(width: width, child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
    FieldToolbar(c, focus, onImage: onImage, initialPaletteOpen: paletteOpen), const SizedBox(height: 6), EditableField(c, focus, width: width, fontFamily: fontFamily, fontFamilyFallback: fontFamilyFallback)]));
}
