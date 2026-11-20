// SPDX-FileCopyrightText: 2026 Hatto Social contributors
//
// SPDX-License-Identifier: AGPL-3.0-or-later

// Reviewer: question -> Show Answer -> Again/Hard/Good/Easy (labels from rslib describe_next_states), undo, More menu, congrats.
// Layout measured from reference/ref_review_q.png / ref_review_a.png (bottom bar 68px, pill buttons 80px, interval labels above).
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../editor/anki_ui.dart';
import '../engine/anki_api.dart';
import '../state/app_controller.dart';
import '../state/review_session.dart';
import 'card_html.dart';
import 'common.dart';
import 'copy.dart';

class ReviewerScreen extends StatefulWidget {
  const ReviewerScreen({super.key, required this.app, required this.onEdit});
  final AppController app; final Future<void> Function(int noteId) onEdit;
  @override State<ReviewerScreen> createState() => _ReviewerScreenState();
}

class _ReviewerScreenState extends State<ReviewerScreen> {
  final focus = FocusNode(); bool busy = false; String? avMsg;
  ReviewSession get s => widget.app.session!;
  @override void dispose() { focus.dispose(); super.dispose(); }

  Future<void> _run(Future<void> Function() f) async {
    if (busy) return; busy = true;
    try { await f(); } finally { busy = false; if (mounted) { widget.app.touch(); } }
  }
  void _answer(CardAnswer_Rating r) => _run(() => s.answer(r));
  void _show() { if (s.phase == ReviewPhase.question) { s.showAnswer(); widget.app.touch(); } }

  KeyEventResult _key(FocusNode _, KeyEvent e) {
    if (e is! KeyDownEvent) return KeyEventResult.ignored;
    final k = e.logicalKey; final ctrl = HardwareKeyboard.instance.isControlPressed || HardwareKeyboard.instance.isMetaPressed;
    if (ctrl && k == LogicalKeyboardKey.keyZ) { _run(s.undo); return KeyEventResult.handled; }
    if (s.phase == ReviewPhase.question && (k == LogicalKeyboardKey.space || k == LogicalKeyboardKey.enter)) { _show(); return KeyEventResult.handled; }
    if (s.phase == ReviewPhase.answer) {
      if (k == LogicalKeyboardKey.digit1) { _answer(CardAnswer_Rating.AGAIN); return KeyEventResult.handled; }
      if (k == LogicalKeyboardKey.digit2) { _answer(CardAnswer_Rating.HARD); return KeyEventResult.handled; }
      if (k == LogicalKeyboardKey.digit3 || k == LogicalKeyboardKey.space || k == LogicalKeyboardKey.enter) { _answer(CardAnswer_Rating.GOOD); return KeyEventResult.handled; }
      if (k == LogicalKeyboardKey.digit4) { _answer(CardAnswer_Rating.EASY); return KeyEventResult.handled; }
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final k = AnkiTheme.of(context);
    if (s.phase == ReviewPhase.finished) return _Congrats(app: widget.app);
    final isQ = s.phase == ReviewPhase.question;
    return Focus(focusNode: focus, autofocus: true, onKeyEvent: _key, child: Column(children: [
      Expanded(child: s.current == null ? const SizedBox() : CardView(key: const ValueKey('card-view'), html: isQ ? s.questionHtml : s.answerHtml, css: s.css, mediaDir: widget.app.api.mediaDir, dark: k.dark,
        onPlay: (id) { final n = s.rendered?.soundFor(id); if (n != null) { widget.app.playSound(n); } })),
      if (!isQ && s.answered == 0 && widget.app.fsrsOn) _hint(k),
      Container(height: 68, decoration: BoxDecoration(color: k.canvas, border: Border(top: BorderSide(color: k.border))), padding: const EdgeInsets.symmetric(horizontal: 10),
        child: Stack(alignment: Alignment.center, children: [
          Align(alignment: Alignment.centerLeft, child: PillButton('편집', key: const ValueKey('rv-edit'), width: 80, onTap: () => widget.onEdit(s.noteId))),
          Align(alignment: Alignment.center, child: isQ ? _showAnswerBar(k) : _answerBar(k)),
          Align(alignment: Alignment.centerRight, child: PillButton('더 보기 ▾', key: const ValueKey('rv-more'), width: 80, onTap: () => _more(context, k))),
        ])),
    ]));
  }

  /// First-review hint (PO copy 2026-11-19), only while FSRS is on and only for the first card of the session. No accuracy / memory claims.
  Widget _hint(AnkiColors k) => Container(key: const ValueKey('fsrs-hint'), height: 42, alignment: Alignment.center, color: k.canvas,
    child: Column(mainAxisSize: MainAxisSize.min, children: [
      Text(kFsrsGuidance1, key: const ValueKey('fsrs-hint-1'), style: ankiText(k, size: 12, color: k.fgSubtle).copyWith(height: 1.2)),
      Text(kFsrsGuidance2, key: const ValueKey('fsrs-hint-2'), style: ankiText(k, size: 12, color: k.fgSubtle).copyWith(height: 1.2))]));

  Widget _showAnswerBar(AnkiColors k) {
    TextStyle c(Color col, bool on) => ankiText(k, size: 13, color: col).copyWith(decoration: on ? TextDecoration.underline : null, decorationColor: col, height: 1.2);
    final q = s.queue;
    return Column(mainAxisSize: MainAxisSize.min, children: [
      Row(mainAxisSize: MainAxisSize.min, key: const ValueKey('rv-counts'), children: [
        Text('${s.newCount}', style: c(StateColors.n(k), q == QueuedCards_Queue.NEW)), Text(' + ', style: c(k.fgSubtle, false)),
        Text('${s.learnCount}', style: c(StateColors.l(k), q == QueuedCards_Queue.LEARNING)), Text(' + ', style: c(k.fgSubtle, false)),
        Text('${s.reviewCount}', style: c(StateColors.r(k), q == QueuedCards_Queue.REVIEW))]),
      const SizedBox(height: 3),
      PillButton('정답 보기', key: const ValueKey('show-answer'), width: 200, onTap: _show),
    ]);
  }

  Widget _answerBar(AnkiColors k) {
    Widget b(String key, String label, int i, CardAnswer_Rating r) => Padding(padding: const EdgeInsets.symmetric(horizontal: 10), child: Column(mainAxisSize: MainAxisSize.min, children: [
      Text(s.buttonLabels.length > i ? s.buttonLabels[i] : '', key: ValueKey('interval-$key'), style: ankiText(k, size: 12.5).copyWith(height: 1.2)), const SizedBox(height: 3),
      PillButton(label, key: ValueKey('ans-$key'), width: 80, onTap: () => _answer(r))]));
    return Row(mainAxisSize: MainAxisSize.min, children: [b('again', kBtnAgain, 0, CardAnswer_Rating.AGAIN), b('hard', kBtnHard, 1, CardAnswer_Rating.HARD), b('good', kBtnGood, 2, CardAnswer_Rating.GOOD), b('easy', kBtnEasy, 3, CardAnswer_Rating.EASY)]);
  }

  Future<void> _more(BuildContext context, AnkiColors k) async {
    final act = await chooseFrom<String>(context, k, title: '더 보기', items: [
      (s.canUndo ? '실행 취소: ${s.undoLabel}  (Ctrl+Z)' : '실행 취소 (할 것 없음)', 'undo'), ('카드 보류(suspend)', 'suspend'), ('카드 하루 미루기(bury) — 지원 안 함', 'bury')], disabled: const {'bury'});
    if (act == null) return;
    await _run(() async { switch (act) { case 'undo': await s.undo(); case 'suspend': await s.suspendCurrent(); } });
  }
}

class _Congrats extends StatelessWidget {
  const _Congrats({required this.app});
  final AppController app;
  @override
  Widget build(BuildContext context) {
    final k = AnkiTheme.of(context); final c = app.session!.congrats;
    final lines = <String>[];
    if (c != null && c.learnRemaining > 0 && c.secsUntilNextLearn > 0) { lines.add('다음 학습 카드는 약 ${(c.secsUntilNextLearn / 60).ceil()}분 후에 다시 나와요. (남은 학습 카드 ${c.learnRemaining}장)'); }
    if (c != null && c.haveUserBuried) lines.add('미룬(bury) 카드가 있어요.');
    return Column(children: [
      Expanded(child: Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
        Text('축하합니다! 지금은 이 덱의 학습을 마쳤어요.', key: const ValueKey('congrats'), style: ankiText(k, size: 20, w: FontWeight.w600)),
        const SizedBox(height: 14), Text('이번 세션에서 ${app.session!.answered}장 답했어요.', key: const ValueKey('congrats-count'), style: ankiText(k, size: 15, color: k.fgSubtle)),
        for (final l in lines) Padding(padding: const EdgeInsets.only(top: 6), child: Text(l, style: ankiText(k, size: 15))),
      ]))),
      Padding(padding: const EdgeInsets.only(bottom: 14), child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
        PillButton('덱 목록', key: const ValueKey('congrats-decks'), width: 90, onTap: () => app.go(Screen.decks)),
        const SizedBox(width: 12),
        if (app.session!.canUndo) PillButton('마지막 답 취소', key: const ValueKey('congrats-undo'), width: 120, onTap: () async { await app.session!.undo(); app.touch(); }),
      ])),
    ]);
  }
}
