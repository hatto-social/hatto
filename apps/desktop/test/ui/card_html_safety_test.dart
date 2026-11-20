// SPDX-FileCopyrightText: 2026 Hatto Social contributors
//
// SPDX-License-Identifier: AGPL-3.0-or-later

// The reviewer renders card HTML with flutter_widget_from_html_core.
// Saved field HTML may contain script and iframe. This surface must not
// execute or load them. The contract cases, including remote images, are
// in card_renderer_safety_test.dart.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_widget_from_html_core/flutter_widget_from_html_core.dart';
import 'package:hatto_desktop/ui/card_html.dart';

Widget host(String html) => MaterialApp(
  debugShowCheckedModeBanner: false,
  home: Material(
    child: SizedBox(
      width: 400,
      height: 240,
      child: CardView(html: html, css: '', mediaDir: '/nonexistent'),
    ),
  ),
);

String visibleText(WidgetTester tester) {
  final buffer = StringBuffer();
  for (final widget in tester.widgetList<RichText>(find.byType(RichText))) {
    buffer.write(widget.text.toPlainText());
  }
  for (final widget in tester.widgetList<Text>(find.byType(Text))) {
    buffer.write(widget.data ?? '');
  }
  return buffer.toString();
}

void main() {
  testWidgets('script is not executed or shown', (tester) async {
    await tester.pumpWidget(host("a<script>document.title='x'</script>b"));
    await tester.pump();
    final text = visibleText(tester);
    expect(text, contains('a'));
    expect(text, contains('b'));
    expect(text, isNot(contains('document.title')));
    expect(tester.takeException(), isNull);
  });

  testWidgets('iframe is not loaded and its fallback text is shown', (tester) async {
    await tester.pumpWidget(
      host('<iframe src="https://example.test/x">대체</iframe>'),
    );
    await tester.pump();
    expect(visibleText(tester), contains('대체'));
    expect(find.byType(HtmlWidget), findsOneWidget);
    expect(tester.widget<HtmlWidget>(find.byType(HtmlWidget)).onTapUrl, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('event attributes and javascript urls are not handlers', (tester) async {
    await tester.pumpWidget(
      host(
        '<img src="x" onerror="alert(1)"><a href="javascript:alert(1)">링크</a>',
      ),
    );
    await tester.pump();
    expect(visibleText(tester), contains('링크'));
    expect(visibleText(tester), isNot(contains('alert')));
    expect(tester.widget<HtmlWidget>(find.byType(HtmlWidget)).onTapUrl, isNull);
    expect(tester.takeException(), isNull);
  });
}
