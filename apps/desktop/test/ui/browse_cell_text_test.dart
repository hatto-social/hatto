// SPDX-FileCopyrightText: 2026 Hatto Social contributors
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter_test/flutter_test.dart';
import 'package:hatto_desktop/ui/browse_screen.dart';
import 'package:hatto_desktop/ui/card_html.dart';

void main() {
  test('a tag is flattened and a non-breaking space becomes a space', () {
    expect(browseCellText('<b>hi</b>'), 'hi');
    expect(browseCellText('x&nbsp;y'), 'x y');
  });

  test('a long run of angle brackets stays fast', () {
    final watch = Stopwatch()..start();
    final angles = browseCellText('<' * 40000);
    expect(watch.elapsed, lessThan(const Duration(milliseconds: 200)));
    expect(angles, '<' * kCardHtmlPlainPrefix);
  });

  test('decoded &lt; runs take the angle-bracket path', () {
    final decoded = ('&lt;' * 40000).replaceAll('&lt;', '<');
    expect(decoded, '<' * 40000);
    final watch = Stopwatch()..start();
    final text = browseCellText(decoded);
    expect(watch.elapsed, lessThan(const Duration(milliseconds: 200)));
    expect(text, '<' * kCardHtmlPlainPrefix);
  });
}
