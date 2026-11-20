// SPDX-FileCopyrightText: 2026 Hatto Social contributors
//
// SPDX-License-Identifier: AGPL-3.0-or-later

// TeX in card HTML: \( \) inline and \[ \] display only; `$..$` is NOT math; parse failure -> raw text. Reviewer + preview use CardView.
import 'package:flutter/material.dart';
import 'package:flutter_math_fork/flutter_math.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hatto_desktop/ui/card_html.dart';
import 'package:hatto_desktop/ui/math_html.dart';
import 'test_fonts.dart';

Widget host(String html, {Size size = const Size(560, 300)}) => MaterialApp(debugShowCheckedModeBanner: false, home: Material(child: Center(child: RepaintBoundary(key: const ValueKey('shot'),
  child: SizedBox(width: size.width, height: size.height, child: CardView(html: html, css: '.card { font-size: 22px; text-align: center; }', mediaDir: '/nonexistent'))))));

void main() {
  setUpAll(loadTestFonts);
  group('findMath / preprocessMath (pure)', () {
    test('inline and display are found; dollar signs are not math', () {
      final f = findMath(r'a \(x^2\) b \[\int_0^1 x\,dx\] c $y^2$ and $$z$$');
      expect(f.length, 2);
      expect((f[0].$3.tex, f[0].$3.display), ('x^2', false));
      expect((f[1].$3.tex, f[1].$3.display), (r'\int_0^1 x\,dx', true));
      expect(preprocessMath(r'only $y^2$ and $$z$$'), r'only $y^2$ and $$z$$');
    });
    test('entities and <br> inside TeX are normalised; empty body stays raw', () {
      final f = findMath(r'\(a &lt; b<br>c &amp; d\)');
      expect(f.single.$3.tex, 'a < b c & d');
      expect(findMath(r'\(  \) and \(\)'), isEmpty);
    });
    test('raw text keeps the original delimiters', () {
      expect(findMath(r'\(x\)').single.$3.raw, r'\(x\)');
      expect(findMath(r'\[x\]').single.$3.raw, r'\[x\]');
    });
    test('unmatched delimiters are left alone', () { expect(findMath(r'\(x'), isEmpty); expect(findMath(r'x\]'), isEmpty); });
  });

  group('CardView renders math', () {
    testWidgets('inline + display render as Math; dollar signs stay plain text', (t) async {
      await t.pumpWidget(host(r'속도 \(v = \frac{d}{t}\) 이고 $x^2$ 는 그대로. \[E = mc^2\]'));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('math-inline')), findsOneWidget);
      expect(find.byKey(const ValueKey('math-display')), findsOneWidget);
      expect(find.byType(Math), findsNWidgets(2));
      expect(find.textContaining(r'$x^2$', findRichText: true), findsOneWidget, reason: r'$..$ is not math: shown verbatim');
    });
    testWidgets('parse failure falls back to the raw text (with delimiters)', (t) async {
      await t.pumpWidget(host(r'깨진 수식 \(\frac{1}{\) 끝 \(\badmacro{x}\)'));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('math-raw')), findsNWidgets(2));
      expect(find.text(r'\(\frac{1}{\)'), findsOneWidget);
      expect(find.text(r'\(\badmacro{x}\)'), findsOneWidget);
    });
    testWidgets('golden: card with inline + display math and a dollar sign', skip: true, (t) async {
      await t.pumpWidget(host(r'피타고라스: \(a^2 + b^2 = c^2\)' '<br>' r'\[\sum_{n=1}^{\infty}\frac{1}{n^2}=\frac{\pi^2}{6}\]' '<br>' r'가격은 $5 와 $6 (수식 아님)' '<br>' r'깨진: \(\frac{1}{\)'));
      await t.pumpAndSettle();
      await expectLater(find.byKey(const ValueKey('shot')), matchesGoldenFile('goldens/math_card.png'));
    });
  });
}
