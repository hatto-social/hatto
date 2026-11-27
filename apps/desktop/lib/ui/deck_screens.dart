// SPDX-FileCopyrightText: 2026 Hatto Social contributors
//
// SPDX-License-Identifier: AGPL-3.0-or-later

// Deck browser + deck overview (Anki main window look; layout measured from reference/ref_decks.png, ref_overview.png).
import 'package:flutter/material.dart';
import '../editor/anki_ui.dart';
import '../engine/anki_api.dart';
import '../state/app_controller.dart';
import '../state/deck_view.dart';
import 'common.dart';

class DeckBrowserScreen extends StatelessWidget {
  const DeckBrowserScreen({super.key, required this.app, required this.onImport});
  final AppController app; final VoidCallback? onImport;

  @override
  Widget build(BuildContext context) {
    final k = AnkiTheme.of(context);
    final root = app.tree; final rows = root == null ? <DeckTreeNode>[] : visibleDeckRows(root);
    return Column(children: [
      Expanded(child: SingleChildScrollView(child: Padding(padding: const EdgeInsets.only(top: 34), child: Center(child: Column(children: [
        Container(key: const ValueKey('deck-panel'), width: 516, padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
          decoration: BoxDecoration(color: k.dark ? const Color(0xff333333) : const Color(0xfffafafa), border: Border.all(color: k.borderSubtle), borderRadius: BorderRadius.circular(12), boxShadow: k.dark ? const [] : kShadowSoft),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            SizedBox(height: 30, child: Row(children: [
              const SizedBox(width: 2), Expanded(child: Text('덱', style: ankiText(k, size: 14, w: FontWeight.w700))),
              _hdr(k, '새 카드', 66), _hdr(k, '학습', 66), _hdr(k, '복습', 66), const SizedBox(width: 26),
            ])),
            Container(height: 1, color: k.borderSubtle), const SizedBox(height: 12),
            if (rows.isEmpty) Padding(padding: const EdgeInsets.all(18), child: Text('덱이 없어요. 덱 만들기는 이 버전에 없습니다.', key: const ValueKey('no-decks'), style: ankiText(k, color: k.fgSubtle)))
            else for (final n in rows) _DeckRow(app: app, node: n),
          ])),
        const SizedBox(height: 44),
        Text(app.studiedToday, key: const ValueKey('studied-today'), style: ankiText(k, size: 15)),
      ]))))),
      Padding(padding: const EdgeInsets.only(bottom: 14), child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
        const Tooltip(message: 'AnkiWeb 공유 덱 — 서버 연동 범위 밖', child: PillButton('공유 덱 받기', width: 90)), const SizedBox(width: 14),
        const Tooltip(message: '덱 만들기는 이 버전에 없습니다', child: PillButton('덱 만들기', key: ValueKey('create-deck'), width: 86)), const SizedBox(width: 14),
        PillButton('파일 가져오기', key: const ValueKey('import-file'), width: 96, onTap: onImport),
      ])),
    ]);
  }
  Widget _hdr(AnkiColors k, String t, double w) => SizedBox(width: w, child: Text(t, textAlign: TextAlign.center, style: ankiText(k, size: 14, w: FontWeight.w700)));
}

class _DeckRow extends StatefulWidget {
  const _DeckRow({required this.app, required this.node});
  final AppController app; final DeckTreeNode node;
  @override State<_DeckRow> createState() => _DeckRowState();
}
class _DeckRowState extends State<_DeckRow> {
  bool hover = false;
  @override
  Widget build(BuildContext context) {
    final k = AnkiTheme.of(context); final n = widget.node; final app = widget.app;
    final id = n.deckId.toInt(); final current = app.deckId == id;
    Widget cnt(int v, Color c, int w) => SizedBox(width: w.toDouble(), child: Text('$v', textAlign: TextAlign.center, style: ankiText(k, size: 15, color: v == 0 ? k.fgFaint : c)));
    return MouseRegion(onEnter: (_) => setState(() => hover = true), onExit: (_) => setState(() => hover = false), child: Container(
      key: ValueKey('deck-row-${n.name}'), height: 30, margin: const EdgeInsets.only(bottom: 0), decoration: BoxDecoration(color: current ? (k.dark ? const Color(0xff3e3e3e) : const Color(0xffececec)) : (hover ? (k.dark ? const Color(0xff3a3a3a) : const Color(0xfff2f2f2)) : null), borderRadius: BorderRadius.circular(14)),
      child: Row(children: [
        // The list stays expanded. There is no collapse control: SetDeckCollapsed
        // is not one of the desktop calls.
        SizedBox(width: 10.0 + (n.level - 1) * 18),
        const SizedBox(width: 6),
        Expanded(child: GestureDetector(key: ValueKey('deck-${n.name}'), behavior: HitTestBehavior.opaque, onTap: () => app.openDeck(id, n.name), child: Align(alignment: Alignment.centerLeft, child: Text(deckLeaf(n.name), overflow: TextOverflow.ellipsis, style: ankiText(k, size: 15))))),
        cnt(n.newCount, StateColors.n(k), 66), cnt(n.learnCount, StateColors.l(k), 66), cnt(n.reviewCount, StateColors.r(k), 66),
        SizedBox(width: 26, child: Opacity(opacity: hover ? .9 : .45, child: GestureDetector(key: ValueKey('gear-${n.name}'), onTap: () => _gear(context, k, n), child: AnkiIcon.one('gear', k.fg, size: 14)))),
      ])));
  }
  Future<void> _gear(BuildContext context, AnkiColors k, DeckTreeNode n) async {
    final id = n.deckId.toInt();
    // RemoveDecks stays closed until the product owner decides. The menu has no delete item.
    final act = await chooseFrom<String>(context, k, title: '덱: ${n.name}', items: const [('이름 바꾸기', 'rename')]);
    if (!context.mounted || act == null) return;
    if (act == 'rename') {
      final name = await promptText(context, k, title: '덱 이름 바꾸기', label: '새 이름:', initial: n.name);
      if (name != null && name.trim().isNotEmpty && name.trim() != n.name) {
        try { await widget.app.renameDeck(id, name.trim()); } catch (e) { widget.app.toast('이름을 바꾸지 못했어요: $e'); }
      }
    }
  }
}

class OverviewScreen extends StatelessWidget {
  const OverviewScreen({super.key, required this.app});
  final AppController app;
  @override
  Widget build(BuildContext context) {
    final k = AnkiTheme.of(context); final n = app.overview;
    final nc = n?.newCount ?? 0, lc = n?.learnCount ?? 0, rc = n?.reviewCount ?? 0; final due = nc + lc + rc;
    Widget line(String l, int v, Color c) => SizedBox(height: 27, child: Row(children: [SizedBox(width: 85, child: Text(l, style: ankiText(k, size: 15))), Text('$v', key: ValueKey('ov-$l'), style: ankiText(k, size: 15, color: c, w: FontWeight.w700))]));
    return Column(children: [
      Expanded(child: Padding(padding: const EdgeInsets.only(top: 40), child: Column(children: [
        Text(app.deckName, key: const ValueKey('ov-title'), style: ankiText(k, size: 19, w: FontWeight.w700)), const SizedBox(height: 24),
        Row(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.center, children: [
          Column(crossAxisAlignment: CrossAxisAlignment.start, children: [line('새 카드:', nc, StateColors.n(k)), line('학습 중:', lc, StateColors.l(k)), line('복습할 카드:', rc, StateColors.r(k))]),
          const SizedBox(width: 74),
          PillButton('지금 학습', key: const ValueKey('study-now'), primary: true, width: 90, height: 34, onTap: due > 0 || (n?.totalInDeck ?? 0) > 0 ? () => app.startStudy() : null),
        ]),
        if (due == 0) Padding(padding: const EdgeInsets.only(top: 26), child: Text('오늘 이 덱에서 학습할 카드가 없어요.', key: const ValueKey('ov-empty'), style: ankiText(k, color: k.fgSubtle))),
      ]))),
      Padding(padding: const EdgeInsets.only(bottom: 14), child: Row(mainAxisAlignment: MainAxisAlignment.center, children: const [
        Tooltip(message: '덱 옵션 — 범위 밖(스텁)', child: PillButton('옵션', width: 72)), SizedBox(width: 12),
        Tooltip(message: '사용자 지정 학습 — 범위 밖(스텁)', child: PillButton('사용자 지정 학습', width: 124)), SizedBox(width: 12),
        Tooltip(message: '설명 — 범위 밖(스텁)', child: PillButton('설명', width: 96)),
      ])),
    ]);
  }
}
