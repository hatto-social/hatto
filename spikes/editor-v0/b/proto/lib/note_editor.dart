// Anki-style Add-note window around Prototype B: header (Type/Deck, static mock), toolbar, multi-field note with labels + collapse +
// per-field state icons, tags row (static mock), footer buttons (static mock). Layout numbers: DMITRY_EDITOR_ANKI_DESIGN_REVIEW.md.
import 'package:flutter/material.dart';
import 'anki_ui.dart';
import 'proto_editable.dart';

class NoteFieldSpec { const NoteFieldSpec(this.name, this.html); final String name, html; }

class _F {
  _F(this.name, this.c, this.fn);
  final String name; FieldController c; final FocusNode fn; bool collapsed = false;
}

class NoteEditor extends StatefulWidget {
  const NoteEditor({super.key, required this.fields, this.tags = const [], this.notetype = 'Basic', this.deck = 'Default', this.mediaDir, this.colors = AnkiColors.light,
    this.voluntaryHtmlToggle = false, this.fontFamily = 'Liberation Sans', this.fontFamilyFallback = const ['NanumGothic'], this.onAdd, this.onFocusedChanged, this.showChrome = true, this.autofocus = true});
  final List<NoteFieldSpec> fields; final List<String> tags; final String notetype, deck; final String? mediaDir; final AnkiColors colors;
  /// FLAGGED, default off: per-field "<>" toggle that lets the user open a rich-OK field in HTML source mode on purpose. NOT in contract (Q3).
  final bool voluntaryHtmlToggle;
  final String fontFamily; final List<String> fontFamilyFallback;
  final void Function(List<String> savedHtml)? onAdd; final void Function(int? index)? onFocusedChanged;
  /// false = only toolbar + fields (+ tags), no Type/Deck header and no footer buttons.
  final bool showChrome, autofocus;
  @override State<NoteEditor> createState() => NoteEditorState();
}

class NoteEditorState extends State<NoteEditor> {
  // ignore: library_private_types_in_public_api
  late final List<_F> fs;
  int? focused; int lastFocused = 0; bool tagsCollapsed = false;
  int? hoverIdx;
  FieldController controllerAt(int i) => fs[i].c;
  FocusNode focusNodeAt(int i) => fs[i].fn;
  int? get focusedIndex => focused;

  @override
  void initState() {
    super.initState();
    fs = [for (final f in widget.fields) _F(f.name, FieldController(f.html, mediaDir: widget.mediaDir), FocusNode())];
    for (var i = 0; i < fs.length; i++) { fs[i].fn.addListener(() => _focusChanged(i)); }
    // Anki focuses the first field when the Add window opens
    if (widget.autofocus && fs.isNotEmpty) WidgetsBinding.instance.addPostFrameCallback((_) { if (mounted) fs[0].fn.requestFocus(); });
  }
  void _focusChanged(int i) {
    final has = fs[i].fn.hasFocus;
    final old = focused;
    if (has) { focused = i; lastFocused = i; } else if (focused == i) { focused = null; }
    if (focused != old) { widget.onFocusedChanged?.call(focused); }
    if (mounted) setState(() {});
  }
  @override void dispose() { for (final f in fs) { f.fn.dispose(); f.c.dispose(); } super.dispose(); }

  List<String> saveAll() => [for (final f in fs) f.c.save()];

  /// FLAGGED voluntary toggle (Q3). Rich -> source: keeps current content (save() is the original bytes if untouched). Source -> rich only if the
  /// codec says the field is DOM-equivalent after the (stand-in) sanitizer, otherwise it stays in source mode (contract-forced).
  void _toggleHtml(int i) {
    final f = fs[i]; final old = f.c; final html = old.save();
    final next = FieldController(html, mediaDir: widget.mediaDir, forcedByUser: old.isRich);
    if (!old.isRich && !next.isRich) return; // contract-forced source field: cannot be switched back
    setState(() { f.c = next; });
    WidgetsBinding.instance.addPostFrameCallback((_) { old.dispose(); f.fn.requestFocus(); });
  }

  @override
  Widget build(BuildContext context) {
    final k = widget.colors;
    final active = fs.isEmpty ? null : fs[focused ?? lastFocused].c;
    return AnkiTheme(colors: k, child: DefaultTextStyle(style: ankiText(k), child: ColoredBox(color: k.canvas, child: Padding(
      padding: widget.showChrome ? const EdgeInsets.fromLTRB(12, 6, 12, 12) : const EdgeInsets.fromLTRB(12, 0, 12, 0),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (widget.showChrome) ...[_Header(k, widget.notetype, widget.deck), const SizedBox(height: 12)],
        FieldToolbar(focused == null ? null : active, null, showNotetypeButtons: widget.showChrome),
        Expanded(child: SingleChildScrollView(child: Padding(padding: const EdgeInsets.only(top: 6, bottom: 5), child: Column(children: [
          for (var i = 0; i < fs.length; i++) ...[
            if (i > 0) const SizedBox(height: AnkiMetrics.fieldGap),
            _fieldBlock(i, k),
          ],
        ])))),
        _TagsRow(k, widget.tags, tagsCollapsed, () => setState(() => tagsCollapsed = !tagsCollapsed)),
        if (widget.showChrome) ...[const SizedBox(height: 12), _Footer(k, onAdd: () => widget.onAdd?.call(saveAll()))],
      ])))));
  }

  Widget _fieldBlock(int i, AnkiColors k) {
    final f = fs[i]; final c = f.c;
    final src = !c.isRich;
    return MouseRegion(onEnter: (_) => setState(() => hoverIdx = i), onExit: (_) => setState(() { if (hoverIdx == i) hoverIdx = null; }),
      child: Container(key: ValueKey('field-$i'), decoration: BoxDecoration(color: k.canvas, borderRadius: BorderRadius.circular(AnkiMetrics.radius)), clipBehavior: Clip.hardEdge,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          // LabelContainer.svelte:22-35: flex, space-between, padding 0 3px 1px
          Padding(padding: const EdgeInsets.fromLTRB(3, 0, 3, 1.5), child: Row(children: [
            _Badge(key: ValueKey('collapse-$i'), width: 20, opacity: .4, hoverOpacity: 1, tooltip: f.collapsed ? '펼치기' : '접기', onTap: () => setState(() { f.collapsed = !f.collapsed; if (f.collapsed) f.fn.unfocus(); }),
              child: Transform.rotate(angle: f.collapsed ? -1.5708 : 0, child: AnkiIcon.one('chevronDown', k.fg, size: 16))),
            const SizedBox(width: 3.9),
            Text(f.name, key: ValueKey('label-$i'), style: ankiText(k)),
            const Spacer(),
            // FieldState.svelte: margin 0 3px between badges; StickyBadge/PlainTextBadge opacity .4 (hover .8)
            _Badge(key: ValueKey('pin-$i'), width: 14, opacity: .4, hoverOpacity: .8, tooltip: '고정(Sticky) — 목업, 동작 없음', onTap: null, child: AnkiGlyph('pin', k.fg, size: 14)),
            const SizedBox(width: 6),
            _Badge(key: ValueKey('html-$i'), width: 20, opacity: src ? 1 : .4, hoverOpacity: src ? 1 : .8,
              tooltip: src
                  ? (c.forcedByUser ? 'HTML 편집기 (켜짐, 사용자 선택 — 플래그 옵션)' : '이 필드는 서식 편집기로 안전하게 바꿀 수 없어 HTML 원문 편집으로 열렸어요')
                  : (widget.voluntaryHtmlToggle ? 'HTML 편집기 (Ctrl+Shift+X) — 플래그 옵션' : 'HTML 편집기 — 사용자 선택 토글은 계약 밖(질문 Q3), 비활성'),
              onTap: widget.voluntaryHtmlToggle && (c.isRich || c.forcedByUser) ? () => _toggleHtml(i) : null,
              child: AnkiIcon.one('codeTags', k.fg, size: 16)),
          ])),
          Offstage(offstage: f.collapsed, child: EditableField(c, f.fn, width: null, fontFamily: widget.fontFamily, fontFamilyFallback: widget.fontFamilyFallback)),
        ])));
  }
}

/// Small borderless icon button as Anki's `badge` (Badge.svelte:42-56).
class _Badge extends StatefulWidget {
  const _Badge({super.key, required this.child, required this.width, required this.opacity, required this.hoverOpacity, this.tooltip, this.onTap});
  final Widget child; final double width, opacity, hoverOpacity; final String? tooltip; final VoidCallback? onTap;
  @override State<_Badge> createState() => _BadgeState();
}
class _BadgeState extends State<_Badge> {
  bool h = false;
  @override
  Widget build(BuildContext context) {
    final enabled = widget.onTap != null;
    Widget w = MouseRegion(cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic, onEnter: (_) => setState(() => h = true), onExit: (_) => setState(() => h = false),
      child: GestureDetector(behavior: HitTestBehavior.opaque, onTap: widget.onTap, child: SizedBox(width: widget.width, height: 22.5,
        child: Center(child: Opacity(opacity: h && enabled ? widget.hoverOpacity : widget.opacity, child: widget.child)))));
    if (widget.tooltip != null) w = Tooltip(message: widget.tooltip!, waitDuration: const Duration(milliseconds: 500), child: w);
    return w;
  }
}

class _QtButton extends StatelessWidget {
  const _QtButton(this.k, this.text, {this.enabled = true, this.onTap, this.width});
  final AnkiColors k; final String text; final bool enabled; final VoidCallback? onTap; final double? width;
  @override
  Widget build(BuildContext context) {
    // Qt stylesheet `QPushButton { margin: 1px }` (aqt/stylesheets.py:183-185): 25px widget geometry, 23px painted box
    Widget b(double w) => Padding(padding: const EdgeInsets.all(1), child: AnkiButton(width: w - 2, height: 23, leftRadius: 5, rightRadius: 5, onTap: enabled ? (onTap ?? () {}) : null,
      labelBuilder: (fg) => Text(text, style: ankiText(k, size: 12, color: fg).copyWith(height: 1)), child: const SizedBox()));
    return width != null ? b(width!) : LayoutBuilder(builder: (_, bc) => b(bc.maxWidth));
  }
}

/// Qt part of the Add window: "Type [..]  Deck [..]" row (aqt/addcards.py + qt/aqt/forms) — static mock, no backend.
class _Header extends StatelessWidget {
  const _Header(this.k, this.type, this.deck);
  final AnkiColors k; final String type, deck;
  @override
  Widget build(BuildContext context) => SizedBox(height: 25, child: Row(children: [
    // measured Qt geometry (980px window): Type label x12 w27 | button x47 w440 | Deck label x493 w29 | button x530 w438
    SizedBox(width: 27, child: Text('Type', style: ankiText(k, size: 12))), const SizedBox(width: 8), Expanded(flex: 440, child: _QtButton(k, type)),
    const SizedBox(width: 6), SizedBox(width: 29, child: Text('Deck', style: ankiText(k, size: 12))), const SizedBox(width: 8), Expanded(flex: 438, child: _QtButton(k, deck)),
  ]));
}

class _Footer extends StatelessWidget {
  const _Footer(this.k, {this.onAdd});
  final AnkiColors k; final VoidCallback? onAdd;
  @override
  Widget build(BuildContext context) => SizedBox(height: 25, child: Row(children: [
    _QtButton(k, '도움말', width: 81), const Spacer(),
    _QtButton(k, '추가', width: 77, onTap: onAdd), const SizedBox(width: 6), _QtButton(k, '기록 ▾', width: 104, enabled: false), const SizedBox(width: 6), _QtButton(k, '닫기', width: 85),
  ]));
}

/// Tags row (NoteEditor.svelte:1621-1634 CollapseLabel + TagEditor) — static mock.
class _TagsRow extends StatelessWidget {
  const _TagsRow(this.k, this.tags, this.collapsed, this.onToggle);
  final AnkiColors k; final List<String> tags; final bool collapsed; final VoidCallback onToggle;
  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
    GestureDetector(behavior: HitTestBehavior.opaque, onTap: onToggle, child: SizedBox(height: 23, child: Row(children: [
      const SizedBox(width: 2), Opacity(opacity: .4, child: Transform.rotate(angle: collapsed ? -1.5708 : 0, child: AnkiIcon.one('chevronDown', k.fg, size: 16))), const SizedBox(width: 5),
      Text(tags.isEmpty ? '태그' : '태그 ${tags.length}개', key: const ValueKey('tags-label'), style: ankiText(k))]))),
    if (!collapsed) Container(key: const ValueKey('tag-editor'), height: 39, margin: const EdgeInsets.fromLTRB(1, 1, 3, 3), padding: const EdgeInsets.all(6),
      decoration: BoxDecoration(color: k.canvasElevated, border: Border.all(color: k.border), borderRadius: BorderRadius.circular(AnkiMetrics.radius)),
      child: Row(children: [
        AnkiIcon.one('tag', k.fg, size: 20), const SizedBox(width: 11.3),
        for (final t in tags) Padding(padding: const EdgeInsets.only(right: 2), child: Container(height: 24.5, padding: const EdgeInsets.only(left: 7.5, right: 3.75), alignment: Alignment.center,
          decoration: BoxDecoration(color: k.buttonBg, border: Border.all(color: k.border), borderRadius: BorderRadius.circular(AnkiMetrics.radius)),
          child: Row(mainAxisSize: MainAxisSize.min, children: [Text(t, style: ankiText(k)), const SizedBox(width: 4), AnkiIcon.one('trash', k.fg, size: 16)]))),
      ])),
  ]);
}
