// SPDX-FileCopyrightText: 2026 Hatto Social contributors
//
// SPDX-License-Identifier: AGPL-3.0-or-later

// Main window shell: Anki-like top toolbar (Decks / Add / Browse / Stats / Sync) + current screen + one-line status.
import 'dart:async';
import 'package:flutter/material.dart';
import '../editor/anki_ui.dart';
import '../state/app_controller.dart';
import 'browse_screen.dart';
import 'common.dart';
import 'deck_screens.dart';
import 'note_windows.dart';
import 'reviewer_screen.dart';
import 'stats_screen.dart';

class MainShell extends StatefulWidget {
  const MainShell({super.key, required this.app, required this.colors, this.demoImage = '', this.demoApkg = ''});
  final AppController app; final AnkiColors colors; final String demoImage, demoApkg;
  @override State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> {
  AppController get app => widget.app;
  Timer? _toastTimer;
  @override void initState() { super.initState(); app.addListener(_on); }
  @override void dispose() { app.removeListener(_on); _toastTimer?.cancel(); super.dispose(); }
  void _on() { if (!mounted) return; if (app.message != null) { _toastTimer?.cancel(); _toastTimer = Timer(const Duration(seconds: 5), () { app.clearToast(); if (mounted) setState(() {}); }); } setState(() {}); }

  Future<void> _add() async {
    await showWindow<void>(context, builder: (c) => AddNoteWindow(app: app, colors: widget.colors, demoImage: widget.demoImage));
    await app.refreshDecks();
  }
  Future<void> _edit(int noteId) async {
    await showWindow<void>(context, builder: (c) => EditNoteWindow(app: app, colors: widget.colors, noteId: noteId));
    if (app.session != null) { await app.session!.loadNext(); app.touch(); }
  }
  Future<void> _import() async {
    app.toast('가져오기는 이 버전에 없습니다.');
  }

  @override
  Widget build(BuildContext context) {
    final k = widget.colors; final s = app.screen;
    final body = switch (s) {
      Screen.decks => DeckBrowserScreen(app: app, onImport: _import),
      Screen.overview => OverviewScreen(app: app),
      Screen.review => ReviewerScreen(app: app, onEdit: _edit),
      Screen.browse => BrowseScreen(app: app),
      Screen.stats => StatsScreen(app: app),
    };
    Widget link(String label, String key, bool cur, VoidCallback? onTap) => MouseRegion(cursor: onTap == null ? SystemMouseCursors.basic : SystemMouseCursors.click, child: GestureDetector(key: ValueKey(key), behavior: HitTestBehavior.opaque, onTap: onTap,
      child: Padding(padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7), child: Text(label, style: ankiText(k, size: 14.5, w: FontWeight.w700, color: onTap == null ? k.fgDisabled : k.fg)))));
    return AnkiTheme(colors: k, child: DefaultTextStyle(style: ankiText(k), child: ColoredBox(color: k.canvas, child: Stack(children: [
      Column(children: [
        Center(child: Container(key: const ValueKey('toolbar'), height: 33, padding: const EdgeInsets.symmetric(horizontal: 6),
          decoration: BoxDecoration(color: k.dark ? const Color(0xff363636) : const Color(0xfffafafa), borderRadius: const BorderRadius.vertical(bottom: Radius.circular(14)), boxShadow: k.dark ? const [] : kShadowSoft),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            link('덱', 'nav-decks', s == Screen.decks || s == Screen.overview, () => app.go(Screen.decks)), link('추가', 'nav-add', false, _add),
            link('찾아보기', 'nav-browse', s == Screen.browse, () => app.go(Screen.browse)), link('통계', 'nav-stats', s == Screen.stats, () => app.go(Screen.stats)), link('동기화', 'nav-sync', false, null)]))),
        Expanded(child: body),
      ]),
      if (app.message != null) Positioned(left: 0, right: 0, bottom: s == Screen.review ? 76 : 56, child: Center(child: Container(key: const ValueKey('toast'), padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7), decoration: ankiFloating(k),
        child: Text(app.message!, style: ankiText(k, size: 13))))),
    ]))));
  }
}
