// SPDX-FileCopyrightText: 2026 Hatto Social contributors
//
// SPDX-License-Identifier: AGPL-3.0-or-later

// Shared Anki-look widgets for the Hatto flow prototype. Colours/metrics come from editor/anki_ui.dart (measured on real Anki 26.09.3);
// the pill buttons / panels of the main window (deck browser, overview, reviewer bottom bar) were measured from screenshots of the real
// Anki main window captured on this box (reference/*.png).
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../editor/anki_ui.dart';

/// state colours of the deck list / overview / reviewer counts (Anki web: --state-new / --state-learn / --state-review)
class StateColors {
  static const newC = Color(0xff3b82f6), learn = Color(0xffdc2626), review = Color(0xff16a34a);
  static Color n(AnkiColors k) => k.dark ? const Color(0xff60a5fa) : newC;
  static Color l(AnkiColors k) => k.dark ? const Color(0xfff87171) : learn;
  static Color r(AnkiColors k) => k.dark ? const Color(0xff4ade80) : review;
}

const kShadowSoft = [BoxShadow(color: Color(0x26000000), offset: Offset(0, 1), blurRadius: 3), BoxShadow(color: Color(0x14000000), offset: Offset(0, 1), blurRadius: 1)];

/// Anki main-window web button (`button { border-radius: 16px; ... }`). [primary] = blue "Study Now" style.
class PillButton extends StatefulWidget {
  const PillButton(this.label, {super.key, this.onTap, this.primary = false, this.width, this.height = 32, this.fontSize = 13.5, this.sub});
  final String label; final VoidCallback? onTap; final bool primary; final double? width, height, fontSize; final String? sub;
  @override State<PillButton> createState() => _PillButtonState();
}
class _PillButtonState extends State<PillButton> {
  bool h = false, d = false;
  @override
  Widget build(BuildContext context) {
    final k = AnkiTheme.of(context); final en = widget.onTap != null;
    final bg = widget.primary ? (d ? const Color(0xff2554c7) : (h ? const Color(0xff3a72ee) : k.primary == AnkiColors.light.primary ? const Color(0xff306bec) : k.primary)) : (h && en ? (k.dark ? const Color(0xff484848) : const Color(0xfff0f0f0)) : k.canvasElevated);
    final fg = widget.primary ? Colors.white : (en ? k.fg : k.fgDisabled);
    return MouseRegion(cursor: en ? SystemMouseCursors.click : SystemMouseCursors.basic, onEnter: (_) => setState(() => h = true), onExit: (_) => setState(() { h = false; d = false; }),
      child: GestureDetector(behavior: HitTestBehavior.opaque, onTap: widget.onTap, onTapDown: (_) => setState(() => d = true), onTapUp: (_) => setState(() => d = false), onTapCancel: () => setState(() => d = false),
        child: Container(constraints: BoxConstraints(minWidth: widget.width ?? 0), height: widget.height, padding: const EdgeInsets.symmetric(horizontal: 14),
          decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(16), boxShadow: widget.primary ? const [BoxShadow(color: Color(0x33000000), offset: Offset(0, 1), blurRadius: 3)] : (k.dark ? const [] : kShadowSoft), border: k.dark && !widget.primary ? Border.all(color: k.borderSubtle) : null),
          child: Center(widthFactor: 1, child: Text(widget.label, softWrap: false, style: ankiText(k, size: widget.fontSize!, color: fg, w: FontWeight.w500).copyWith(height: 1.1))))));
  }
}

/// Qt-style push button (the same look as the Add window's footer buttons).
class QtPush extends StatelessWidget {
  const QtPush(this.text, {super.key, this.onTap, this.width = 85});
  final String text; final VoidCallback? onTap; final double width;
  @override
  Widget build(BuildContext context) {
    final k = AnkiTheme.of(context);
    return Padding(padding: const EdgeInsets.all(1), child: AnkiButton(width: width - 2, height: 23, leftRadius: 5, rightRadius: 5, onTap: onTap,
      labelBuilder: (fg) => Text(text, style: ankiText(k, size: 12, color: fg).copyWith(height: 1)), child: const SizedBox()));
  }
}

/// Window-ish modal frame (title bar + content) used for Add / Edit / Import / prompts. Single native window in v0 (Gina: multi-window later).
class WindowFrame extends StatelessWidget {
  const WindowFrame({super.key, required this.title, required this.child, this.width, this.height, this.onClose});
  final String title; final Widget child; final double? width, height; final VoidCallback? onClose;
  @override
  Widget build(BuildContext context) {
    final k = AnkiTheme.of(context);
    return Center(child: Container(width: width, height: height, clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(color: k.canvas, border: Border.all(color: k.border), borderRadius: BorderRadius.circular(6), boxShadow: kAnkiElevation8),
      child: Column(children: [
        Container(height: 28, color: k.dark ? const Color(0xff3a3a3a) : const Color(0xffe9e9e9), alignment: Alignment.center, child: Stack(alignment: Alignment.center, children: [
          Text(title, style: ankiText(k, size: 13)),
          if (onClose != null) Positioned(right: 4, child: GestureDetector(key: const ValueKey('window-close'), onTap: onClose, child: Padding(padding: const EdgeInsets.all(6), child: Icon(Icons.close, size: 15, color: k.fgSubtle)))),
        ])),
        Container(height: 1, color: k.border),
        Expanded(child: child),
      ])));
  }
}

Future<T?> showWindow<T>(BuildContext context, {required WidgetBuilder builder, bool barrier = true}) =>
    showGeneralDialog<T>(context: context, barrierDismissible: false, barrierColor: barrier ? const Color(0x55000000) : Colors.transparent, transitionDuration: Duration.zero,
        pageBuilder: (c, _, _) => builder(c));

/// Simple text prompt (create / rename deck, import path ...). Returns null on cancel.
Future<String?> promptText(BuildContext context, AnkiColors k, {required String title, required String label, String initial = '', String ok = '확인', String? hint}) =>
  showWindow<String>(context, builder: (c) => _PromptDialog(k: k, title: title, label: label, initial: initial, ok: ok, hint: hint));

class _PromptDialog extends StatefulWidget {
  const _PromptDialog({required this.k, required this.title, required this.label, required this.initial, required this.ok, this.hint});
  final AnkiColors k; final String title, label, initial, ok; final String? hint;
  @override State<_PromptDialog> createState() => _PromptDialogState();
}
class _PromptDialogState extends State<_PromptDialog> {
  late final ctl = TextEditingController(text: widget.initial); final fn = FocusNode();
  @override void dispose() { ctl.dispose(); fn.dispose(); super.dispose(); }
  @override
  Widget build(BuildContext c) {
    final k = widget.k;
    return AnkiTheme(colors: k, child: DefaultTextStyle(style: ankiText(k), child: Shortcuts(shortcuts: const {SingleActivator(LogicalKeyboardKey.escape): DismissIntent()},
      child: Actions(actions: {DismissIntent: CallbackAction<DismissIntent>(onInvoke: (_) { Navigator.pop(c); return null; })}, child: WindowFrame(title: widget.title, width: 460, height: 170, onClose: () => Navigator.pop(c),
    child: Padding(padding: const EdgeInsets.all(14), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(widget.label, style: ankiText(k, size: 13)), const SizedBox(height: 6),
      Container(height: 30, padding: const EdgeInsets.symmetric(horizontal: 6), alignment: Alignment.centerLeft, decoration: BoxDecoration(color: k.canvasElevated, border: Border.all(color: k.borderFocus), borderRadius: BorderRadius.circular(5)),
        child: EditableText(key: const ValueKey('prompt-input'), controller: ctl, focusNode: fn, autofocus: true, style: ankiText(k), cursorColor: k.fg, backgroundCursorColor: k.fgFaint, onSubmitted: (v) => Navigator.pop(c, v))),
      if (widget.hint != null) Padding(padding: const EdgeInsets.only(top: 4), child: Text(widget.hint!, style: ankiText(k, size: 11, color: k.fgSubtle))),
      const Spacer(),
      Row(mainAxisAlignment: MainAxisAlignment.end, children: [QtPush('취소', key: const ValueKey('prompt-cancel'), onTap: () => Navigator.pop(c)), const SizedBox(width: 6), QtPush(widget.ok, key: const ValueKey('prompt-ok'), onTap: () => Navigator.pop(c, ctl.text))]),
    ])))))));
  }
}

Future<bool> confirmDialog(BuildContext context, AnkiColors k, {required String title, required String message, String ok = '확인', double height = 160}) async {
  final r = await showWindow<bool>(context, builder: (c) => AnkiTheme(colors: k, child: DefaultTextStyle(style: ankiText(k), child: WindowFrame(title: title, width: 440, height: height, onClose: () => Navigator.pop(c, false),
    child: Padding(padding: const EdgeInsets.all(14), child: Column(children: [
      Expanded(child: Align(alignment: Alignment.centerLeft, child: Text(message, style: ankiText(k, size: 14)))),
      Row(mainAxisAlignment: MainAxisAlignment.end, children: [QtPush('취소', key: const ValueKey('confirm-cancel'), onTap: () => Navigator.pop(c, false)), const SizedBox(width: 6), QtPush(ok, key: const ValueKey('confirm-ok'), onTap: () => Navigator.pop(c, true))]),
    ]))))));
  return r ?? false;
}

/// Chooser list (notetype / deck), like Anki's StudyDeck/ChooseNotetype dialogs: filter box + list.
Future<T?> chooseFrom<T>(BuildContext context, AnkiColors k, {required String title, required List<(String, T)> items, T? selected, Set<T> disabled = const {}}) {
  return showWindow<T>(context, builder: (c) => AnkiTheme(colors: k, child: DefaultTextStyle(style: ankiText(k), child: WindowFrame(title: title, width: 420, height: 380, onClose: () => Navigator.pop(c),
    child: StatefulBuilder(builder: (c, set) {
      return Padding(padding: const EdgeInsets.all(10), child: Column(children: [
        Expanded(child: Container(decoration: BoxDecoration(color: k.canvasElevated, border: Border.all(color: k.border), borderRadius: BorderRadius.circular(5)),
          child: ListView(children: [for (final (label, v) in items) GestureDetector(key: ValueKey('choice-$label'), behavior: HitTestBehavior.opaque, onTap: disabled.contains(v) ? null : () => Navigator.pop(c, v),
            child: Container(height: 26, padding: const EdgeInsets.symmetric(horizontal: 8), alignment: Alignment.centerLeft, color: v == selected ? k.primary : null,
              child: Text(label, style: ankiText(k, size: 13.5, color: disabled.contains(v) ? k.fgDisabled : (v == selected ? Colors.white : k.fg)))))]))),
      ]));
    })))));
}

/// Deck-name display: "A::B" -> indent by depth, last segment.
String deckLeaf(String full) => full.contains('::') ? full.split('::').last : full;
