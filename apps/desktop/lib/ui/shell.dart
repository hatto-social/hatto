// SPDX-FileCopyrightText: 2026 Hatto Social contributors
//
// SPDX-License-Identifier: AGPL-3.0-or-later

// Main window shell: Anki-like top toolbar (Decks / Add / Browse / Stats / Sync) + current screen + one-line status.
import 'dart:async';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';

import '../about/about_page.dart';
import '../editor/anki_ui.dart';
import '../effect/apkg_import.dart';
import '../effect/import_progress_model.dart';
import '../state/app_controller.dart';
import 'browse_screen.dart';
import 'common.dart';
import 'deck_screens.dart';
import 'import_copy.dart';
import 'import_progress.dart';
import 'reviewer_screen.dart';
import 'stats_screen.dart';

class MainShell extends StatefulWidget {
  const MainShell({
    super.key,
    required this.app,
    required this.colors,
    this.demoImage = '',
    this.demoApkg = '',
    this.imports,
  });
  final AppController app;
  final AnkiColors colors;
  final String demoImage, demoApkg;
  final ApkgImportSession? imports;
  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> {
  AppController get app => widget.app;
  Timer? _toastTimer;
  bool _progressOpen = false;
  @override
  void initState() {
    super.initState();
    app.addListener(_on);
    widget.imports?.addListener(_on);
  }

  @override
  void dispose() {
    app.removeListener(_on);
    widget.imports?.removeListener(_on);
    _toastTimer?.cancel();
    super.dispose();
  }

  void _on() {
    if (!mounted) return;
    if (app.message != null) {
      _toastTimer?.cancel();
      _toastTimer = Timer(const Duration(seconds: 5), () {
        app.clearToast();
        if (mounted) setState(() {});
      });
    }
    setState(() {});
  }

  ApkgImportUi get _ui => ApkgImportUi(
    toast: app.toast,
    showSummary: _showSummary,
    showProgress: _showProgress,
    closeProgress: _closeProgress,
  );

  void _import() {
    final imports = widget.imports;
    if (imports == null || imports.running) return;
    unawaited(imports.importFromPicker(_ui));
  }

  Future<void> _showProgress(ImportProgressModel model) async {
    if (!mounted) return;
    _progressOpen = true;
    unawaited(
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (context) => AnkiTheme(
          colors: widget.colors,
          child: DefaultTextStyle(
            style: ankiText(widget.colors),
            child: ImportProgressDialog(
              model: model,
              onCancel: model.requestCancel,
            ),
          ),
        ),
      ).whenComplete(() {
        _progressOpen = false;
      }),
    );
  }

  void _closeProgress() {
    if (!_progressOpen || !mounted) return;
    Navigator.of(context, rootNavigator: true).pop();
    _progressOpen = false;
  }

  void _showSummary(ImportSummaryText summary) {
    if (!mounted) return;
    showDialog<void>(
      context: context,
      barrierDismissible: true,
      builder: (context) => AnkiTheme(
        colors: widget.colors,
        child: DefaultTextStyle(
          style: ankiText(widget.colors),
          child: ImportSummaryDialog(summary: summary),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final k = widget.colors;
    final s = app.screen;
    final imports = widget.imports;
    final body = switch (s) {
      Screen.decks => DeckBrowserScreen(
        app: app,
        onImport: imports != null && !imports.running ? _import : null,
      ),
      Screen.overview => OverviewScreen(app: app),
      Screen.review => ReviewerScreen(app: app),
      Screen.browse => BrowseScreen(app: app),
      Screen.stats => StatsScreen(app: app),
    };
    Widget link(String label, String key, bool cur, VoidCallback? onTap) =>
        MouseRegion(
          cursor: onTap == null
              ? SystemMouseCursors.basic
              : SystemMouseCursors.click,
          child: GestureDetector(
            key: ValueKey(key),
            behavior: HitTestBehavior.opaque,
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
              child: Text(
                label,
                style: ankiText(
                  k,
                  size: 14.5,
                  w: FontWeight.w700,
                  color: onTap == null ? k.fgDisabled : k.fg,
                ),
              ),
            ),
          ),
        );
    final shell = AnkiTheme(
      colors: k,
      child: DefaultTextStyle(
        style: ankiText(k),
        child: ColoredBox(
          color: k.canvas,
          child: Stack(
            children: [
              Column(
                children: [
                  Center(
                    child: Container(
                      key: const ValueKey('toolbar'),
                      height: 33,
                      padding: const EdgeInsets.symmetric(horizontal: 6),
                      decoration: BoxDecoration(
                        color: k.dark
                            ? const Color(0xff363636)
                            : const Color(0xfffafafa),
                        borderRadius: const BorderRadius.vertical(
                          bottom: Radius.circular(14),
                        ),
                        boxShadow: k.dark ? const [] : kShadowSoft,
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          link(
                            '덱',
                            'nav-decks',
                            s == Screen.decks || s == Screen.overview,
                            () => app.go(Screen.decks),
                          ),
                          link('추가', 'nav-add', false, null),
                          link(
                            '찾아보기',
                            'nav-browse',
                            s == Screen.browse,
                            () => app.go(Screen.browse),
                          ),
                          link(
                            '통계',
                            'nav-stats',
                            s == Screen.stats,
                            () => app.go(Screen.stats),
                          ),
                          link('동기화', 'nav-sync', false, null),
                          link('라이선스', 'nav-about', false, () {
                            Navigator.of(context).push(
                              MaterialPageRoute<void>(
                                builder: (_) => const AboutPage(),
                              ),
                            );
                          }),
                        ],
                      ),
                    ),
                  ),
                  Expanded(child: body),
                ],
              ),
              if (app.message != null)
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: s == Screen.review ? 76 : 56,
                  child: Center(
                    child: Container(
                      key: const ValueKey('toast'),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 7,
                      ),
                      decoration: ankiFloating(k),
                      child: Text(app.message!, style: ankiText(k, size: 13)),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
    if (imports == null) return shell;
    return DropTarget(
      enabled: !imports.running,
      acceptedKinds: const {DropItemKind.file, DropItemKind.directory},
      onDrop: (details) {
        return imports.importDropped(_ui, [
          for (final item in details.items) apkgDropFromItem(item),
        ]);
      },
      child: shell,
    );
  }
}
