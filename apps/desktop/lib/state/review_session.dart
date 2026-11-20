// SPDX-FileCopyrightText: 2026 Hatto Social contributors
//
// SPDX-License-Identifier: AGPL-3.0-or-later

// Study session state machine. All scheduling decisions (queue order, next-interval labels, answer effects, undo) come from rslib;
// this class only sequences calls and keeps what the UI needs.
import '../engine/anki_api.dart';
import 'card_preview.dart';

enum ReviewPhase { loading, question, answer, finished }

class ReviewSession {
  ReviewSession(this.api);
  final FlowApi api;
  ReviewPhase phase = ReviewPhase.loading;
  QueuedCards_QueuedCard? current;
  int newCount = 0, learnCount = 0, reviewCount = 0;
  String questionHtml = '', answerHtml = '', css = '';
  List<String> avQuestion = [], avAnswer = [];
  List<String> buttonLabels = const ['', '', '', ''];
  String? undoLabel; // non-null => rslib has something to undo
  String? redoLabel;
  int answered = 0;
  final _clock = Stopwatch();
  CongratsInfoResponse? congrats;
  RenderedCard? rendered;
  bool get canUndo => undoLabel != null && undoLabel!.isNotEmpty;
  bool get canRedo => redoLabel != null && redoLabel!.isNotEmpty;
  int get cardId => current?.card.id.toInt() ?? 0;
  int get noteId => current?.card.noteId.toInt() ?? 0;
  QueuedCards_Queue get queue => current?.queue ?? QueuedCards_Queue.NEW;

  Future<void> loadNext() async {
    final q = await api.queuedCards(limit: 1);
    newCount = q.newCount; learnCount = q.learningCount; reviewCount = q.reviewCount;
    final status = await api.undoStatus();
    undoLabel = status.undo;
    redoLabel = status.redo;
    if (q.cards.isEmpty) {
      current = null; phase = ReviewPhase.finished; congrats = await api.congratsInfo(); return;
    }
    current = q.cards.first;
    rendered = await RenderedCard.load(api, cardId);
    css = rendered!.css; questionHtml = rendered!.questionHtml; answerHtml = rendered!.answerHtml;
    avQuestion = rendered!.avQuestion; avAnswer = rendered!.avAnswer;
    buttonLabels = await api.describeNextStates(current!.states);
    phase = ReviewPhase.question;
    _clock..reset()..start();
  }

  void showAnswer() { if (phase == ReviewPhase.question) phase = ReviewPhase.answer; }

  Future<void> answer(CardAnswer_Rating r) async {
    if (phase != ReviewPhase.answer || current == null) return;
    final ms = _clock.elapsedMilliseconds.clamp(0, 60000);
    await api.answerCard(current!, r, millisTaken: ms);
    answered++;
    await loadNext();
  }

  /// rslib undo (of the last undoable op, normally the last answer), then re-fetch the queue (the card comes back at the front).
  Future<void> undo() async {
    if (!canUndo) return;
    await api.undo();
    if (answered > 0) answered--;
    await loadNext();
  }

  Future<void> redo() async {
    if (!canRedo) return;
    await api.redo();
    answered++;
    await loadNext();
  }

  Future<void> suspendCurrent() async { await api.suspendCards([cardId]); await loadNext(); }
  // Bury is denied by the call policy (2026-11-19); the reviewer shows it greyed out.
}
