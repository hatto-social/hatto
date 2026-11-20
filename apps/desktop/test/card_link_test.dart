// SPDX-FileCopyrightText: 2026 Hatto Social contributors
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hatto_desktop/ui/card_link.dart';

void main() {
  test('non-https schemes are ignored and https is one argument', () async {
    final opened = <String>[];
    Future<void> open(Uri url) async {
      opened.add(url.toString());
    }

    expect(await openCardLink('javascript:alert(1)', open), isFalse);
    expect(await openCardLink('http://example.test/a', open), isFalse);
    expect(await openCardLink('file:///etc/passwd', open), isFalse);
    expect(await openCardLink('data:text/html,hi', open), isFalse);
    expect(opened, isEmpty);

    const href = 'https://example.test/a?x=1;rm';
    expect(await openCardLink(href, open), isTrue);
    expect(opened, [href]);
  });

  testWidgets('a card opens https only when the link is tapped', (
    tester,
  ) async {
    final opened = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: CardHtmlView(
          html:
              '<a href="https://example.test/ok">ok</a>'
              '<a href="javascript:alert(1)">bad</a>'
              '<script>alert(1)</script>',
          openUrl: (url) async {
            opened.add(url.toString());
          },
        ),
      ),
    );
    expect(opened, isEmpty);
    expect(find.text('alert(1)'), findsNothing);

    await tester.tap(find.text('bad'));
    await tester.pump();
    expect(opened, isEmpty);

    await tester.tap(find.text('ok'));
    await tester.pump();
    expect(opened, ['https://example.test/ok']);
  });
}
