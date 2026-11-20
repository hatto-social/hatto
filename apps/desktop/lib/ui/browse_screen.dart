// SPDX-FileCopyrightText: 2026 Hatto Social contributors
//
// SPDX-License-Identifier: AGPL-3.0-or-later

// Browse: rslib search syntax -> cards table (cells computed by rslib's browser_table), sidebar of decks/states, editor pane, suspend/bury/delete/set due.
// Layout after reference/ref_browse.png (sidebar | table | editor).
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../editor/anki_ui.dart';
import '../engine/anki_api.dart';
import '../state/app_controller.dart';
import '../state/browse_actions.dart';
import '../state/card_preview.dart';
import 'card_html.dart';
import 'common.dart';

const _colLabels = {'noteFld': '정렬 필드', 'template': '카드', 'deck': '덱', 'cardDue': '기한', 'cardIvl': '간격', 'noteTags': '태그'};
const _colWidths = {'noteFld': 170.0, 'template': 56.0, 'deck': 100.0, 'cardDue': 92.0, 'cardIvl': 62.0, 'noteTags': 100.0};

class BrowseScreen extends StatefulWidget {
  const BrowseScreen({super.key, required this.app, this.initialQuery = ''});
  final AppController app; final String initialQuery;
  @override State<BrowseScreen> createState() => _BrowseScreenState();
}

class _BrowseScreenState extends State<BrowseScreen> {
  FlowApi get api => widget.app.api;
  late final TextEditingController q = TextEditingController(text: widget.initialQuery);
  final qFocus = FocusNode();
  List<int> ids = []; final rows = <int, BrowserRow>{}; final sel = <int>{}; int? anchor; String? error; String info = '';
  List<DeckNameId> decks = []; int sortCol = 0; bool sortRev = false;

  @override void initState() { super.initState(); _init(); }
  Future<void> _init() async { decks = await api.deckNames(); await _search(); }
  @override void dispose() { q.dispose(); qFocus.dispose(); super.dispose(); }

  Future<void> _search() async {
    try {
      final ids2 = await api.searchCards(q.text.trim(), column: kBrowserColumns[sortCol], reverse: sortRev);
      final shown = ids2.take(400).toList();
      final rs = await Future.wait(shown.map(api.browserRow));
      rows..clear()..addAll({for (var i = 0; i < shown.length; i++) shown[i]: rs[i]});
      ids = shown; error = null; info = '${ids2.length}장 중 ${shown.length}장 표시';
      sel.removeWhere((e) => !rows.containsKey(e));
    } on BackendException catch (e) { error = e.error.message; ids = []; }
    if (mounted) setState(() {});
  }

  Future<void> _select(int id) async {
    final ctrl = HardwareKeyboard.instance.isControlPressed, shift = HardwareKeyboard.instance.isShiftPressed;
    if (shift && anchor != null) { final a = ids.indexOf(anchor!), b = ids.indexOf(id); sel..clear()..addAll(ids.sublist(a < b ? a : b, (a < b ? b : a) + 1)); }
    else if (ctrl) { sel.contains(id) ? sel.remove(id) : sel.add(id); anchor = id; }
    else { sel..clear()..add(id); anchor = id; }
    if (mounted) setState(() {});
  }

  Future<void> _act(Future<void> Function() f) async {
    try { await f(); } catch (e) { widget.app.toast('실행하지 못했어요: $e'); }
    await widget.app.refreshDecks(); final keep = Set.of(sel); await _search(); sel..clear()..addAll(keep.where(rows.containsKey)); if (mounted) setState(() {});
  }


  @override
  Widget build(BuildContext context) {
    final k = AnkiTheme.of(context);
    return Row(children: [
      SizedBox(width: 200, child: _Sidebar(k, decks, (s) { q.text = s; _search(); })), Container(width: 1, color: k.border),
      SizedBox(width: 600, child: Column(children: [_searchBar(k), _toolbar(k), Expanded(child: _table(k)), Container(height: 22, padding: const EdgeInsets.symmetric(horizontal: 8), alignment: Alignment.centerLeft, color: k.canvas,
        child: Text(error ?? '$info${sel.isEmpty ? '' : ' · ${sel.length}장 선택'}', key: const ValueKey('browse-info'), style: ankiText(k, size: 12, color: error != null ? k.danger : k.fgSubtle).copyWith(height: 1)))])),
      Container(width: 1, color: k.border),
      Expanded(child: _pane(k)),
    ]);
  }

  Widget _searchBar(AnkiColors k) => Padding(padding: const EdgeInsets.fromLTRB(8, 8, 8, 4), child: Row(children: [
    Expanded(child: Container(height: 28, padding: const EdgeInsets.symmetric(horizontal: 8), alignment: Alignment.centerLeft, decoration: BoxDecoration(color: k.canvasElevated, border: Border.all(color: k.border), borderRadius: BorderRadius.circular(5)),
      child: EditableText(key: const ValueKey('browse-search'), controller: q, focusNode: qFocus, style: ankiText(k, size: 14), cursorColor: k.fg, backgroundCursorColor: k.fgFaint, onSubmitted: (_) => _search()))),
    const SizedBox(width: 6), QtPush('검색', key: const ValueKey('browse-go'), width: 60, onTap: _search)]));

  Widget _toolbar(AnkiColors k) => Padding(padding: const EdgeInsets.fromLTRB(8, 0, 8, 6), child: Wrap(spacing: 4, runSpacing: 4, children: [
    QtPush('보류 토글', key: const ValueKey('br-suspend'), width: 78, onTap: sel.isEmpty ? null : () => _act(() async { await BrowseActions(api).toggleSuspend(sel); })),
    // Bury (UnburyDeck / BURY_*) and SetDueDate are denied by the call policy in v0: visible but greyed out.
    Tooltip(message: '미루기 — v0에서는 지원하지 않아요', child: const QtPush('미루기(bury)', key: ValueKey('br-bury'), width: 90)),
    Tooltip(message: '기한 설정 — v0에서는 지원하지 않아요', child: const QtPush('기한 설정…', key: ValueKey('br-due'), width: 86)),
    QtPush('미리보기', key: const ValueKey('br-preview'), width: 70, onTap: sel.length == 1 ? _preview : null),
    const Tooltip(message: '노트 삭제는 이 버전에 없습니다', child: QtPush('노트 삭제', key: ValueKey('br-delete'), width: 78)),
  ]));

  /// Card preview (question / answer) with TeX rendered; same CardView as the reviewer.
  Future<void> _preview() async {
    final k = AnkiTheme.of(context); final rc = await RenderedCard.load(api, sel.first, browser: true);
    if (!mounted) return;
    await showWindow<void>(context, builder: (c) => AnkiTheme(colors: k, child: DefaultTextStyle(style: ankiText(k), child: _PreviewWindow(app: widget.app, card: rc, k: k, onClose: () => Navigator.pop(c)))));
  }

  Color? _rowBg(AnkiColors k, BrowserRow r) => switch (r.color) {
    BrowserRow_Color.COLOR_SUSPENDED => k.dark ? const Color(0xff55501e) : const Color(0xffffffb2),
    BrowserRow_Color.COLOR_BURIED => k.dark ? const Color(0xff4b3b22) : const Color(0xffe8d9c4),
    BrowserRow_Color.COLOR_MARKED => k.dark ? const Color(0xff44335a) : const Color(0xffe0d4f5),
    _ => null };

  Widget _table(AnkiColors k) => Container(color: k.canvasElevated, child: Column(children: [
    Container(height: 24, color: k.canvas, child: Row(children: [for (var i = 0; i < kBrowserColumns.length; i++) GestureDetector(behavior: HitTestBehavior.opaque, onTap: () { if (sortCol == i) { sortRev = !sortRev; } else { sortCol = i; sortRev = false; } _search(); },
      child: Container(width: _colWidths[kBrowserColumns[i]], padding: const EdgeInsets.symmetric(horizontal: 6), decoration: BoxDecoration(border: Border(right: BorderSide(color: k.borderSubtle))), alignment: Alignment.centerLeft,
        child: Text('${_colLabels[kBrowserColumns[i]]}${sortCol == i ? (sortRev ? ' ▼' : ' ▲') : ''}', style: ankiText(k, size: 12.5, w: FontWeight.w600).copyWith(height: 1))))])),
    Container(height: 1, color: k.border),
    Expanded(child: ListView.builder(key: const ValueKey('browse-list'), itemCount: ids.length, itemExtent: 24, itemBuilder: (_, i) {
      final id = ids[i]; final r = rows[id]!; final selected = sel.contains(id);
      return GestureDetector(key: ValueKey('row-$i'), behavior: HitTestBehavior.opaque, onTap: () => _select(id), child: Container(color: selected ? (k.dark ? const Color(0xff2652cf) : const Color(0xffcfe0ff)) : _rowBg(k, r), child: Row(children: [
        for (var c = 0; c < kBrowserColumns.length; c++) Container(width: _colWidths[kBrowserColumns[c]], padding: const EdgeInsets.symmetric(horizontal: 6), alignment: Alignment.centerLeft,
          child: Text(_clean(r.cells[c].text), maxLines: 1, overflow: TextOverflow.ellipsis, style: ankiText(k, size: 12.5).copyWith(height: 1)))])));
    })),
  ]));
  static String _clean(String s) => s.replaceAll(RegExp(r'<[^>]*>'), ' ').replaceAll('&nbsp;', ' ').trim();

  Widget _pane(AnkiColors k) {
    return Center(child: Text('노트 편집은 이 버전에 없습니다.', key: const ValueKey('browse-pane-empty'), style: ankiText(k, color: k.fgSubtle)));
  }
}

class _PreviewWindow extends StatefulWidget {
  const _PreviewWindow({required this.app, required this.card, required this.k, required this.onClose});
  final AppController app; final RenderedCard card; final AnkiColors k; final VoidCallback onClose;
  @override State<_PreviewWindow> createState() => _PreviewWindowState();
}
class _PreviewWindowState extends State<_PreviewWindow> {
  bool back = false;
  @override
  Widget build(BuildContext context) {
    final k = widget.k; final rc = widget.card;
    return WindowFrame(title: '미리보기', width: 640, height: 440, onClose: widget.onClose, child: Column(children: [
      Expanded(child: CardView(key: const ValueKey('preview-card'), html: back ? rc.answerHtml : rc.questionHtml, css: rc.css, mediaDir: widget.app.api.mediaDir, dark: k.dark,
        onPlay: (id) { final n = rc.soundFor(id); if (n != null) widget.app.playSound(n); })),
      Container(height: 40, decoration: BoxDecoration(color: k.canvas, border: Border(top: BorderSide(color: k.border))), child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
        QtPush('앞면', key: const ValueKey('preview-front'), width: 70, onTap: () => setState(() => back = false)), const SizedBox(width: 6),
        QtPush('뒷면', key: const ValueKey('preview-back'), width: 70, onTap: () => setState(() => back = true)), const SizedBox(width: 6),
        QtPush('닫기', key: const ValueKey('preview-close'), width: 70, onTap: widget.onClose)])),
    ]));
  }
}

class _Sidebar extends StatelessWidget {
  const _Sidebar(this.k, this.decks, this.onPick);
  final AnkiColors k; final List<DeckNameId> decks; final void Function(String) onPick;
  @override
  Widget build(BuildContext context) {
    Widget item(String label, String search, {double indent = 0, String? key}) => GestureDetector(key: ValueKey(key ?? 'side-$label'), behavior: HitTestBehavior.opaque, onTap: () => onPick(search),
      child: Container(height: 24, padding: EdgeInsets.only(left: 12 + indent), alignment: Alignment.centerLeft, child: Text(label, style: ankiText(k, size: 13))));
    Widget head(String t) => Container(height: 26, padding: const EdgeInsets.only(left: 8), alignment: Alignment.centerLeft, child: Text(t, style: ankiText(k, size: 13, w: FontWeight.w600)));
    return Container(color: k.canvas, child: ListView(children: [
      head('전체'), item('모든 카드', '', key: 'side-all'), item('현재 덱', 'deck:current'),
      head('카드 상태'), item('새 카드', 'is:new'), item('학습 중', 'is:learn'), item('복습', 'is:review'), item('오늘 기한', 'is:due'), item('보류됨', 'is:suspended'), item('미룸', 'is:buried'),
      head('덱'), for (final d in decks) item(deckLeaf(d.name), 'deck:"${d.name}"', indent: 8.0 * (d.name.split('::').length - 1), key: 'side-deck-${d.name}'),
    ]));
  }
}
