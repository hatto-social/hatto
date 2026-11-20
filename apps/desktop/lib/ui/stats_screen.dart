// SPDX-FileCopyrightText: 2026 Hatto Social contributors
//
// SPDX-License-Identifier: AGPL-3.0-or-later

// Minimal stats from rslib's `graphs` (today summary, due forecast, card counts, review counts). Values only; no re-computation.
import 'package:flutter/material.dart';
import '../editor/anki_ui.dart';
import '../engine/anki_api.dart';
import '../state/app_controller.dart';
import 'common.dart';
import 'copy.dart';

class StatsScreen extends StatefulWidget {
  const StatsScreen({super.key, required this.app});
  final AppController app;
  @override State<StatsScreen> createState() => _StatsScreenState();
}
class _StatsScreenState extends State<StatsScreen> {
  GraphsResponse? g;
  @override void initState() { super.initState(); widget.app.api.graphs(days: 30).then((r) { if (mounted) setState(() => g = r); }); }
  @override
  Widget build(BuildContext context) {
    final k = AnkiTheme.of(context); final r = g;
    if (r == null) return const SizedBox();
    final t = r.today; final cc = r.cardCounts.excludingInactive;
    final answered = t.answerCount; final pct = answered == 0 ? 0 : (t.correctCount * 100 / answered).round();
    final due = {for (var d = 0; d <= 30; d++) d: r.futureDue.futureDue[d] ?? 0};
    final past = {for (var d = -29; d <= 0; d++) d: (() { final v = r.reviews.count[d]; return v == null ? 0 : v.learn + v.relearn + v.young + v.mature + v.filtered; })()};
    Widget card(String title, Widget child, {double w = 440}) => Container(width: w, margin: const EdgeInsets.only(right: 14, bottom: 14), padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(color: k.canvasElevated, border: Border.all(color: k.borderSubtle), borderRadius: BorderRadius.circular(10), boxShadow: k.dark ? const [] : kShadowSoft),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(title, style: ankiText(k, size: 15, w: FontWeight.w700)), const SizedBox(height: 8), child]));
    Text line(String s, {Key? key}) => Text(s, key: key, style: ankiText(k, size: 14));
    return SingleChildScrollView(padding: const EdgeInsets.all(18), child: Wrap(children: [
      card('오늘', Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        line('오늘 학습한 카드: $answered장', key: const ValueKey('st-today')),
        line('새 카드 ${t.learnCount} · 복습 ${t.reviewCount} · 다시 학습 ${t.relearnCount}', key: const ValueKey('st-today-split')),
        line('정답률(Again 제외): $pct%  ·  걸린 시간: ${(t.answerMillis / 1000).toStringAsFixed(1)}초'),
      ])),
      card('카드 수', Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        line('새 카드 ${cc.newCards} · 학습 ${cc.learn} · 다시 학습 ${cc.relearn}', key: const ValueKey('st-counts')),
        line('젊은 카드 ${cc.young} · 성숙 ${cc.mature}'), line('보류 ${cc.suspended} · 미룸 ${cc.buried}'),
      ])),
      card('스케줄러', Column(crossAxisAlignment: CrossAxisAlignment.start, key: const ValueKey('st-scheduler'), children: [
        line(r.fsrs ? '스케줄러: FSRS (기본 파라미터)' : '스케줄러: SM-2 (기본)', key: const ValueKey('st-scheduler-name')),
        if (r.fsrs) ...[const SizedBox(height: 4),
          Text(kFsrsGuidance1, key: const ValueKey('st-fsrs-1'), style: ankiText(k, size: 12, color: k.fgSubtle)),
          Text(kFsrsGuidance2, key: const ValueKey('st-fsrs-2'), style: ankiText(k, size: 12, color: k.fgSubtle))],
        const SizedBox(height: 10),
        // FSRS optimize is a v1 item: visible but disabled.
        const Tooltip(message: 'FSRS 최적화 — v1에서 제공해요', child: PillButton('FSRS 최적화', key: ValueKey('fsrs-optimize'), width: 110)),
      ]), w: 440),
      card('복습 예정 (앞으로 30일)', _Bars(due, k, k.dark ? const Color(0xff60a5fa) : const Color(0xff3b82f6), key: const ValueKey('st-forecast')), w: 440),
      card('복습 횟수 (지난 30일)', _Bars(past, k, k.dark ? const Color(0xff4ade80) : const Color(0xff16a34a), key: const ValueKey('st-reviews')), w: 440),
    ]));
  }
}

class _Bars extends StatelessWidget {
  const _Bars(this.data, this.k, this.color, {super.key});
  final Map<int, int> data; final AnkiColors k; final Color color;
  @override Widget build(BuildContext context) => SizedBox(height: 120, width: 410, child: CustomPaint(painter: _BarsPainter(data, k, color)));
}
class _BarsPainter extends CustomPainter {
  _BarsPainter(this.data, this.k, this.color); final Map<int, int> data; final AnkiColors k; final Color color;
  @override
  void paint(Canvas c, Size s) {
    final keys = data.keys.toList()..sort(); final mx = data.values.fold<int>(1, (a, b) => a > b ? a : b);
    final bw = s.width / keys.length;
    c.drawLine(Offset(0, s.height - 16), Offset(s.width, s.height - 16), Paint()..color = k.border);
    for (var i = 0; i < keys.length; i++) {
      final v = data[keys[i]]!; final h = (s.height - 30) * v / mx;
      if (v > 0) {
        c.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(i * bw + 1.5, s.height - 16 - h, bw - 3, h), const Radius.circular(2)), Paint()..color = color);
        final tp = TextPainter(text: TextSpan(text: '$v', style: TextStyle(fontSize: 10, color: k.fg)), textDirection: TextDirection.ltr)..layout();
        tp.paint(c, Offset(i * bw + (bw - tp.width) / 2, s.height - 16 - h - 12));
      }
      if (keys[i] % 5 == 0) { final tp = TextPainter(text: TextSpan(text: '${keys[i]}', style: TextStyle(fontSize: 10, color: k.fgSubtle)), textDirection: TextDirection.ltr)..layout(); tp.paint(c, Offset(i * bw + (bw - tp.width) / 2, s.height - 13)); }
    }
  }
  @override bool shouldRepaint(_BarsPainter o) => true;
}
