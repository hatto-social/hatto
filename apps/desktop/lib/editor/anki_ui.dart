// SPDX-FileCopyrightText: 2026 Hatto Social contributors
//
// SPDX-License-Identifier: AGPL-3.0-or-later

// Anki-Desktop-look UI primitives (tokens, icons, toolbar buttons) for Prototype B.
// Every number below was measured from the REAL Anki 26.09.3 Add window (computed styles via QtWebEngine) and
// cross-checked with the Anki source: see /workspace/v0-kickoff/notion-drafts/DMITRY_EDITOR_ANKI_DESIGN_REVIEW.md (section 2, file:line).
import 'package:flutter/material.dart';
import 'package:path_drawing/path_drawing.dart';
import 'anki_icon_data.dart';

/// Colour tokens. Source: anki ts/lib/sass/_vars.scss (light/dark pairs); values read back from :root / :root.night-mode.
class AnkiColors {
  const AnkiColors({
    required this.dark, required this.fg, required this.fgSubtle, required this.fgDisabled, required this.fgFaint,
    required this.canvas, required this.canvasElevated, required this.canvasCode, required this.border, required this.borderSubtle,
    required this.borderFocus, required this.buttonBg, required this.gradStart, required this.gradEnd,
    required this.primary, required this.shadow, required this.highlightBg, required this.selectionBg, required this.danger,
  });
  final bool dark;
  final Color fg, fgSubtle, fgDisabled, fgFaint, canvas, canvasElevated, canvasCode, border, borderSubtle, borderFocus, buttonBg, gradStart, gradEnd, primary, shadow, highlightBg, selectionBg, danger;
  /// selectionBg: text-selection colour actually painted in the Anki editor webview (measured from pixels; selected text turns white).

  static const light = AnkiColors(
    dark: false, fg: Color(0xff020202), fgSubtle: Color(0xff737373), fgDisabled: Color(0xff858585), fgFaint: Color(0xffafafaf),
    canvas: Color(0xfff5f5f5), canvasElevated: Color(0xffffffff), canvasCode: Color(0xffffffff), border: Color(0xffc4c4c4), borderSubtle: Color(0xffe4e4e4),
    borderFocus: Color(0xff3b82f6), buttonBg: Color(0xfffcfcfc), gradStart: Color(0xffffffff), gradEnd: Color(0xfffcfcfc),
    primary: Color(0xff306bec), shadow: Color(0xffc4c4c4), highlightBg: Color(0x802563eb), selectionBg: Color(0xff3367d1), danger: Color(0xffef4444));
  static const darkTheme = AnkiColors(
    dark: true, fg: Color(0xfffcfcfc), fgSubtle: Color(0xff858585), fgDisabled: Color(0xff737373), fgFaint: Color(0xff545454),
    canvas: Color(0xff2c2c2c), canvasElevated: Color(0xff363636), canvasCode: Color(0xff252525), border: Color(0xff202020), borderSubtle: Color(0xff252525),
    borderFocus: Color(0xff3b82f6), buttonBg: Color(0xff404040), gradStart: Color(0xff4a4a4a), gradEnd: Color(0xff404040),
    primary: Color(0xff2652cf), shadow: Color(0xff141414), highlightBg: Color(0x8093c5fd), selectionBg: Color(0xff0a3ea8), danger: Color(0xfff87171));
}

/// Layout/typography constants (CSS px = logical px).
class AnkiMetrics {
  static const fontSize = 15.0; // :root --font-size (_vars.scss:15)
  static const radius = 5.0; // --border-radius (_vars.scss:21-24)
  static const buttonSize = 24.0; // NoteEditor.svelte:119 size = 1.6rem * 15px
  static const buttonMinWidth = 18.0; // IconButton.svelte:52 min-width: buttons-size * .75
  static const iconSize = 16.5; // 1.1 * 15px (measured svg 16.5)
  static const groupGapX = 4.5; // ButtonToolbar.svelte:78 margin-right .3rem
  static const groupGapY = 2.25; // ButtonToolbar.svelte:79 margin-bottom .15rem
  static const fieldFontSize = 20.0; // notetype field default (rslib/src/notetype/fields.rs:45-46: Arial 20)
  static const fieldLineHeight = 1.5; // measured .rich-text-editable line box 30px at 20px
  static const fieldGap = 6.0; // Fields.svelte:24
  static const inputPad = 6.0; // measured .rich-text-input padding
}

class AnkiTheme extends InheritedWidget {
  const AnkiTheme({super.key, required this.colors, required super.child});
  final AnkiColors colors;
  static AnkiColors of(BuildContext c) => c.dependOnInheritedWidgetOfExactType<AnkiTheme>()?.colors ?? AnkiColors.light;
  @override bool updateShouldNotify(AnkiTheme o) => o.colors != colors;
}

/// Floating surfaces (popover/dropdown/palette/tooltip): ONE shared decoration. Source: Anki `Popover.svelte:72-84`
/// (`@include elevation(8)`, `border: 1px solid var(--border-subtle)`, `background: var(--canvas-elevated)`, `border-radius: var(--border-radius)`).
/// Shadow = `elevation.scss:85-87` level 8 with default colour #141414: umbra `0 8px 10px -5px` @.2 (l.29, l.59), penumbra `0 16px 24px 2px` @.14 (l.41, l.60),
/// ambient `0 6px 30px 5px` @.12 (l.55, l.61). Same rgba/offsets read back from real Anki (QtWebEngine computed style, light AND dark).
/// Colours come from the theme (borderSubtle / canvasElevated), so both themes use this one function.
const List<BoxShadow> kAnkiElevation8 = [
  BoxShadow(color: Color(0x33141414), offset: Offset(0, 8), blurRadius: 10, spreadRadius: -5),
  BoxShadow(color: Color(0x24141414), offset: Offset(0, 16), blurRadius: 24, spreadRadius: 2),
  BoxShadow(color: Color(0x1f141414), offset: Offset(0, 6), blurRadius: 30, spreadRadius: 5),
];
BoxDecoration ankiFloating(AnkiColors k) => BoxDecoration(
    color: k.canvasElevated, border: Border.all(color: k.borderSubtle), borderRadius: BorderRadius.circular(AnkiMetrics.radius), boxShadow: kAnkiElevation8);

/// Tooltip with the shared floating decoration. [colors] must be given when no AnkiTheme is above (e.g. chips built inside the text controller).
/// Anki's toolbar tooltips are native Qt QToolTips (`qt/aqt/stylesheets.py:123`: fg on --canvas, 1px frame); we deliberately use the
/// Popover look instead (border + shadow) per design feedback — see review doc.
class AnkiTooltip extends StatelessWidget {
  const AnkiTooltip({super.key, required this.message, required this.child, this.colors, this.waitDuration = const Duration(milliseconds: 500)});
  final String message; final Widget child; final AnkiColors? colors; final Duration waitDuration;
  @override
  Widget build(BuildContext context) {
    final k = colors ?? AnkiTheme.of(context);
    return Tooltip(message: message, waitDuration: waitDuration, decoration: ankiFloating(k),
        textStyle: ankiText(k, size: 12).copyWith(height: 1.3), padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4), margin: const EdgeInsets.all(8), child: child);
  }
}

const kUiFont = 'Noto Sans'; // Anki uses system-ui; on this Linux box that resolves to Noto Sans. macOS would use the system font.
TextStyle ankiText(AnkiColors c, {double size = AnkiMetrics.fontSize, FontWeight? w, Color? color}) =>
    TextStyle(fontSize: size, height: 1.5, color: color ?? c.fg, fontWeight: w, decoration: TextDecoration.none, fontFamily: kUiFont, fontFamilyFallback: const ['NanumGothic']);

// ---------------- icons ----------------
final Map<String, List<Path>> _pathCache = {};
List<Path> _paths(String name) => _pathCache.putIfAbsent(name, () => [for (final d in kAnkiIcons[name]!.paths) parseSvgPathData(d)]);

class _IconPainter extends CustomPainter {
  _IconPainter(this.names, this.colors);
  final List<String> names; final List<Color> colors;
  @override
  void paint(Canvas canvas, Size size) {
    for (var i = 0; i < names.length; i++) {
      final ic = kAnkiIcons[names[i]]!; final s = size.width / ic.viewBox;
      canvas.save(); canvas.scale(s);
      for (final p in _paths(names[i])) { canvas.drawPath(p, Paint()..color = colors[i]..isAntiAlias = true); }
      canvas.restore();
    }
  }
  @override bool shouldRepaint(_IconPainter o) => o.colors.join() != colors.join() || o.names.join() != names.join();
}

/// Layered icon(s) drawn at [size] (square). [names] are keys of kAnkiIcons; [colors] one per layer.
class AnkiIcon extends StatelessWidget {
  const AnkiIcon(this.names, this.colors, {super.key, this.size = AnkiMetrics.iconSize});
  AnkiIcon.one(String name, Color color, {Key? key, double size = AnkiMetrics.iconSize}) : this([name], [color], key: key, size: size);
  final List<String> names; final List<Color> colors; final double size;
  @override Widget build(BuildContext context) => SizedBox(width: size, height: size, child: CustomPaint(painter: _IconPainter(names, colors)));
}

/// Own-drawn glyphs (NOT from Anki): pin (sticky), undo, redo, caret. Simple strokes, no third-party artwork.
class _GlyphPainter extends CustomPainter {
  _GlyphPainter(this.kind, this.color);
  final String kind; final Color color;
  @override
  void paint(Canvas c, Size s) {
    final p = Paint()..color = color..style = PaintingStyle.stroke..strokeWidth = s.width / 12..strokeCap = StrokeCap.round..strokeJoin = StrokeJoin.round..isAntiAlias = true;
    final w = s.width, h = s.height;
    switch (kind) {
      case 'undo':
      case 'redo':
        final f = kind == 'undo' ? 1.0 : -1.0; double x(double v) => f > 0 ? v * w : (1 - v) * w;
        final path = Path()..moveTo(x(.28), h * .22)..lineTo(x(.12), h * .38)..lineTo(x(.28), h * .54);
        final arc = Path()..moveTo(x(.14), h * .38)..lineTo(x(.55), h * .38)..cubicTo(x(.9), h * .38, x(.9), h * .78, x(.55), h * .78)..lineTo(x(.35), h * .78);
        c.drawPath(path, p); c.drawPath(arc, p);
      case 'pin':
        final body = Path()..moveTo(w * .33, h * .1)..lineTo(w * .67, h * .1)..lineTo(w * .62, h * .42)..lineTo(w * .78, h * .56)..lineTo(w * .22, h * .56)..lineTo(w * .38, h * .42)..close();
        c.save(); c.translate(w * .5, h * .5); c.rotate(.6); c.translate(-w * .5, -h * .5); c.drawPath(body, p); c.drawLine(Offset(w * .5, h * .56), Offset(w * .5, h * .92), p); c.restore();
    }
  }
  @override bool shouldRepaint(_GlyphPainter o) => o.color != color || o.kind != kind;
}
class AnkiGlyph extends StatelessWidget {
  const AnkiGlyph(this.kind, this.color, {super.key, this.size = AnkiMetrics.iconSize});
  final String kind; final Color color; final double size;
  @override Widget build(BuildContext context) => SizedBox(width: size, height: size, child: CustomPaint(painter: _GlyphPainter(kind, color)));
}

// ---------------- toolbar button ----------------
class _BtnPainter extends CustomPainter {
  _BtnPainter(this.c, this.l, this.r, this.hover, this.pressed, this.active, this.disabled);
  final AnkiColors c; final double l, r; final bool hover, pressed, active, disabled;
  @override
  void paint(Canvas canvas, Size s) {
    final rr = RRect.fromRectAndCorners(Offset.zero & s, topLeft: Radius.circular(l), bottomLeft: Radius.circular(l), topRight: Radius.circular(r), bottomRight: Radius.circular(r));
    final fill = Paint();
    if (active && !disabled) { fill.color = c.primary; }
    else if (disabled) { fill.color = c.gradEnd; }
    else if (hover) { fill.shader = LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [c.gradStart, c.gradEnd]).createShader(Offset.zero & s); }
    else { fill.color = c.buttonBg; }
    canvas.drawRRect(rr, fill);
    // impressed (inset) shadow: .35 black, 1.6px offset, 4.8px blur (button-mixins.scss:7-10)
    if ((active || pressed) && !disabled) {
      canvas.save(); canvas.clipRRect(rr);
      final outer = Path()..addRect(Rect.fromLTWH(-20, -20, s.width + 40, s.height + 40));
      final hole = Path()..addRRect(rr.shift(const Offset(0, 1.6)));
      canvas.drawPath(Path.combine(PathOperation.difference, outer, hole), Paint()..color = const Color(0x59000000)..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2.4));
      canvas.restore();
    }
    // border: 1px --border-subtle, bottom --shadow (button-mixins.scss:62-63); hover => all --shadow; active => --border
    final bc = active && !disabled ? c.border : (hover && !disabled ? c.shadow : c.borderSubtle);
    canvas.drawRRect(rr.deflate(.5), Paint()..style = PaintingStyle.stroke..strokeWidth = 1..color = bc);
    if (!(hover && !disabled) && !(active && !disabled) && !disabled) {
      canvas.save(); canvas.clipRect(Rect.fromLTWH(l, s.height - 1, s.width - l - r, 1));
      canvas.drawRRect(rr.deflate(.5), Paint()..style = PaintingStyle.stroke..strokeWidth = 1..color = c.shadow);
      canvas.restore();
    }
  }
  @override bool shouldRepaint(_BtnPainter o) => o.c != c || o.hover != hover || o.pressed != pressed || o.active != active || o.disabled != disabled || o.l != l || o.r != r;
}

/// Anki "icon-button" (IconButton.svelte + button-mixins.scss `base`). Disabled when [onTap] is null.
class AnkiButton extends StatefulWidget {
  const AnkiButton({super.key, required this.child, this.onTap, this.active = false, this.leftRadius = 0, this.rightRadius = 0, this.width = AnkiMetrics.buttonSize,
    this.height = AnkiMetrics.buttonSize, this.tooltip, this.buttonKey, this.labelBuilder});
  /// [child] receives the foreground colour via [labelBuilder] (preferred) or is used as is.
  final Widget child; final VoidCallback? onTap; final bool active; final double leftRadius, rightRadius, width, height; final String? tooltip; final Key? buttonKey;
  final Widget Function(Color fg)? labelBuilder;
  @override State<AnkiButton> createState() => _AnkiButtonState();
}
class _AnkiButtonState extends State<AnkiButton> {
  bool hover = false, down = false;
  @override
  Widget build(BuildContext context) {
    final c = AnkiTheme.of(context); final disabled = widget.onTap == null;
    final fg = disabled ? c.fgDisabled : (widget.active ? Colors.white : c.fg);
    Widget b = MouseRegion(
      cursor: disabled ? SystemMouseCursors.forbidden : SystemMouseCursors.click,
      onEnter: (_) => setState(() => hover = true), onExit: (_) => setState(() { hover = false; down = false; }),
      child: GestureDetector(
        key: widget.buttonKey, behavior: HitTestBehavior.opaque, onTap: widget.onTap,
        onTapDown: (_) => setState(() => down = true), onTapUp: (_) => setState(() => down = false), onTapCancel: () => setState(() => down = false),
        child: CustomPaint(painter: _BtnPainter(c, widget.leftRadius, widget.rightRadius, hover, down, widget.active, disabled),
          child: SizedBox(width: widget.width, height: widget.height, child: Center(child: widget.labelBuilder != null ? widget.labelBuilder!(fg) : widget.child)))));
    if (widget.tooltip != null) b = AnkiTooltip(message: widget.tooltip!, child: b);
    return b;
  }
}

/// A row of buttons sharing outer 5px radii (ButtonGroup + `--border-left-radius/-right-radius`, InlineButtons.svelte).
class AnkiGroup extends StatelessWidget {
  const AnkiGroup(this.builders, {super.key});
  /// Each builder gets (leftRadius, rightRadius) for its position in the group.
  final List<Widget Function(double l, double r)> builders;
  @override
  // measured: .button-group is 25px high while its buttons are 24px (buttons top-aligned)
  Widget build(BuildContext context) => SizedBox(height: AnkiMetrics.buttonSize + 1, child: Align(alignment: Alignment.topLeft, widthFactor: 1, child: Row(mainAxisSize: MainAxisSize.min, children: [
    for (var i = 0; i < builders.length; i++) builders[i](i == 0 ? AnkiMetrics.radius : 0, i == builders.length - 1 ? AnkiMetrics.radius : 0)])));
}
