// SPDX-FileCopyrightText: 2026 Hatto Social contributors
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter_test/flutter_test.dart';
import 'package:hatto_desktop/ui/card_html.dart';

void main() {
  test('a rule, a comment, and an at-rule still yield the simple declaration', () {
    final rules = CssRules.parse('/* hidden */ .card, .night { color: red !important; font-size: 20px } @media { .inner { color: blue } }');
    expect(rules.forSelector('.card')['color'], 'red');
    expect(rules.forSelector('.night')['font-size'], '20px');
    expect(rules.forSelector('.inner')['color'], 'blue');
  });

  test('a stylesheet with no brace stays linear as it grows', () {
    int steps(int count) {
      final scan = CssScan();
      expect(CssRules.parse('a' * count, scan: scan).rules, isEmpty);
      return scan.steps;
    }
    final small = steps(2000);
    final large = steps(8000);
    expect(small, greaterThanOrEqualTo(2000));
    expect(large, lessThanOrEqualTo(small * 8));
  });

  test('opening braces before one closer stay linear as they grow', () {
    int steps(int count) {
      final scan = CssScan();
      CssRules.parse('{' * count + '}', scan: scan);
      return scan.steps;
    }
    final small = steps(2000);
    final large = steps(8000);
    expect(small, greaterThanOrEqualTo(2000));
    expect(large, lessThanOrEqualTo(small * 8));
  });

  test('a megabyte of opening braces finishes quickly', () {
    final watch = Stopwatch()..start();
    CssRules.parse('{' * (1 << 20) + '}');
    expect(watch.elapsed, lessThan(const Duration(seconds: 2)));
  });
}
