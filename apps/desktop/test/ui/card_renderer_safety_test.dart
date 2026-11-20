// SPDX-FileCopyrightText: 2026 Hatto Social contributors
//
// SPDX-License-Identifier: AGPL-3.0-or-later

// Reviewer HTML must not execute or fetch. HttpOverrides does not see
// NetworkImage: that class keeps one HttpClient created on first use.
// debugNetworkImageHttpClientProvider is consulted on every load in debug
// and test builds, so the recorder below is the interception point.
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_widget_from_html_core/flutter_widget_from_html_core.dart';
import 'package:hatto_desktop/ui/card_html.dart';

final _requests = <Uri>[];

class _RecordingClient implements HttpClient {
  _RecordingClient(this.urls, [this.seen]);
  final List<Uri> urls;
  final Completer<Uri>? seen;

  @override
  Future<HttpClientRequest> getUrl(Uri url) async {
    urls.add(url);
    if (seen != null && !seen!.isCompleted) seen!.complete(url);
    throw StateError('recorded $url');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

const _png = <int>[
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, 0x49,
  0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x08, 0x02,
  0x00, 0x00, 0x00, 0x90, 0x77, 0x53, 0xDE, 0x00, 0x00, 0x00, 0x0C, 0x49, 0x44,
  0x41, 0x54, 0x08, 0xD7, 0x63, 0xF8, 0xCF, 0xC0, 0x00, 0x00, 0x00, 0x03, 0x00,
  0x01, 0x00, 0x05, 0xFE, 0x02, 0xFE, 0xDC, 0xCC, 0x59, 0xE7, 0x00, 0x00, 0x00,
  0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
];

Widget host(String html, String mediaDir, {String css = ''}) => MaterialApp(
  debugShowCheckedModeBanner: false,
  home: Material(
    child: SizedBox(
      width: 420,
      height: 280,
      child: CardView(html: html, css: css, mediaDir: mediaDir),
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

Future<void> show(WidgetTester tester, String html, String mediaDir, {String css = ''}) async {
  debugNetworkImageHttpClientProvider = () => _RecordingClient(_requests);
  await tester.pumpWidget(host(html, mediaDir, css: css));
  await tester.pump();
  // Image resolves are scheduled as microtasks. An extra frame lets them
  // record, and the hook is cleared before the test callback returns.
  await tester.pump(Duration.zero);
  debugNetworkImageHttpClientProvider = null;
}

void main() {
  late Directory root;
  late Directory media;
  late File outside;

  setUp(() async {
    resetCardHtmlFallbackCache();
    _requests.clear();
    root = await Directory.systemTemp.createTemp('hatto-card-html-');
    media = Directory('${root.path}/media')..createSync();
    outside = File('${root.path}/outside.png')..writeAsBytesSync(_png);
    File('${media.path}/inside.png').writeAsBytesSync(_png);
    Link('${media.path}/escape.png').createSync(outside.path);
  });

  tearDown(() async {
    debugNetworkImageHttpClientProvider = null;
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  test('HttpOverrides misses NetworkImage; the debug client records it', () async {
    final missed = <Uri>[];
    debugNetworkImageHttpClientProvider = () => _RecordingClient(_requests);
    await HttpOverrides.runZoned(() async {
      final stream = NetworkImage(
        'https://example.test/proof.png',
      ).resolve(ImageConfiguration.empty);
      final done = Completer<void>();
      late ImageStreamListener listener;
      listener = ImageStreamListener(
        (_, _) {
          if (!done.isCompleted) done.complete();
          stream.removeListener(listener);
        },
        onError: (_, _) {
          if (!done.isCompleted) done.complete();
          stream.removeListener(listener);
        },
      );
      stream.addListener(listener);
      await done.future.timeout(const Duration(seconds: 3));
    }, createHttpClient: (_) => _RecordingClient(missed));
    expect(missed, isEmpty, reason: 'HttpOverrides saw a NetworkImage request');
    expect(
      _requests.map((uri) => uri.toString()),
      contains('https://example.test/proof.png'),
      reason: 'debugNetworkImageHttpClientProvider did not see NetworkImage',
    );
    debugNetworkImageHttpClientProvider = null;
    _requests.clear();
  });

  testWidgets('R1 script is not executed or shown', (tester) async {
    await show(tester, "a<script>document.title='x'</script>b", media.path);
    final text = visibleText(tester);
    expect(text, contains('a'));
    expect(text, contains('b'));
    expect(text, isNot(contains('document.title')));
    expect(_requests, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('R2 iframe is not loaded and its fallback text is shown', (tester) async {
    await show(tester, '<iframe src="https://example.test/x">대체</iframe>', media.path);
    expect(visibleText(tester), contains('대체'));
    expect(find.byType(HtmlWidget), findsOneWidget);
    expect(_requests, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('R3 remote img, srcset, and picture make no request', (tester) async {
    await show(
      tester,
      '<img src="https://example.test/a.png">'
      '<img srcset="https://example.test/a.png 1x">'
      '<picture><source srcset="https://example.test/a.png"><img src="https://example.test/a.png"></picture>',
      media.path,
    );
    expect(find.byKey(const ValueKey('card-img')), findsNothing);
    expect(find.byKey(const ValueKey('card-img-placeholder')), findsWidgets);
    expect(_requests, isEmpty);
  });

  testWidgets('notetype CSS background images do not fetch', (tester) async {
    const cases = <String>[
      '.card { background-image: url(https://example.test/card.png); } div { background-image: url(https://example.test/div.png); }',
      'div { background-image: url(HTTPS://example.test/up.png); }',
      'div { background-image: url(//example.test/rel.png); }',
    ];
    for (final css in cases) {
      _requests.clear();
      await show(tester, '<div>x</div>', media.path, css: css);
      expect(visibleText(tester), contains('x'), reason: css);
      expect(_requests, isEmpty, reason: css);
      expect(tester.takeException(), isNull, reason: css);
    }
  });

  testWidgets('a data image and a NUL src stay local placeholders', (tester) async {
    await show(tester, '<img src="data:image/png;base64,AAAA">', media.path);
    expect(find.byKey(const ValueKey('card-img-placeholder')), findsOneWidget);
    expect(find.byKey(const ValueKey('card-img')), findsNothing);
    expect(_requests, isEmpty);
    expect(tester.takeException(), isNull);
    await show(tester, '<img src="inside.png\u0000.png">', media.path);
    expect(find.byKey(const ValueKey('card-img-placeholder')), findsOneWidget);
    expect(_requests, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('R4 fails without the factory override', (tester) async {
    final seen = Completer<Uri>();
    debugNetworkImageHttpClientProvider = () => _RecordingClient(_requests, seen);
    await tester.pumpWidget(MaterialApp(
      debugShowCheckedModeBanner: false,
      home: HtmlWidget('<div style="background-image:url(https://example.test/plain.png)">x</div>'),
    ));
    await tester.pump();
    await tester.pump(Duration.zero);
    expect(seen.isCompleted, isTrue, reason: 'the stock factory did not request the background image');
    expect(_requests.single.toString(), 'https://example.test/plain.png');
    while (tester.takeException() != null) {}
    debugNetworkImageHttpClientProvider = null;
    _requests.clear();
    await show(
      tester,
      '<div style="background-image:url(https://example.test/plain.png)">x</div>',
      media.path,
    );
    expect(_requests, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('R4 inline background-image does not fetch', (tester) async {
    await show(
      tester,
      '<div style="background-image:url(https://example.test/b.png)">x</div>'
      '<div style="background:url(https://example.test/b.png)">y</div>',
      media.path,
    );
    expect(visibleText(tester), contains('x'));
    expect(visibleText(tester), contains('y'));
    expect(_requests, isEmpty);
  });

  testWidgets('R5 links do not open and do not fetch', (tester) async {
    await show(
      tester,
      '<a href="https://example.test">https</a>'
      '<a href="javascript:alert(1)">js</a>'
      '<a href="file:///etc/hosts">file</a>',
      media.path,
    );
    expect(tester.widget<HtmlWidget>(find.byType(HtmlWidget)).onTapUrl, isNull);
    expect(visibleText(tester), isNot(contains('alert')));
    expect(_requests, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('R6 replaced and form elements do not fetch', (tester) async {
    await show(
      tester,
      '<video src="https://example.test/v.mp4"></video>'
      '<audio src="https://example.test/a.mp3"></audio>'
      '<embed src="https://example.test/e.swf">'
      '<object data="https://example.test/o.pdf"></object>'
      '<link rel="stylesheet" href="https://example.test/c.css">'
      '<meta http-equiv="refresh" content="0;url=https://example.test">'
      '<form action="https://example.test"><input name="q"></form>',
      media.path,
    );
    expect(_requests, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('R7 a style import is not fetched', (tester) async {
    await show(
      tester,
      '<style>@import url(https://example.test/c.css);</style>kept',
      media.path,
    );
    expect(visibleText(tester), contains('kept'));
    expect(visibleText(tester), isNot(contains('@import')));
    expect(_requests, isEmpty);
  });

  testWidgets('R8 paths outside the media folder are not drawn', (tester) async {
    final fileUrl = outside.uri.toString();
    for (final src in [
      '../outside.png',
      outside.path,
      fileUrl,
      '..%2F..%2Foutside.png',
      'escape.png',
    ]) {
      _requests.clear();
      await show(tester, '<img src="$src">', media.path);
      expect(find.byKey(const ValueKey('card-img')), findsNothing, reason: src);
      expect(find.byKey(const ValueKey('card-img-placeholder')), findsOneWidget, reason: src);
      expect(_requests, isEmpty, reason: src);
    }
  });

  testWidgets('R9 svg and math do not fetch', (tester) async {
    await show(
      tester,
      '<svg onload="alert(1)"><image href="https://example.test/s.png"></image></svg><math><mi>x</mi></math>',
      media.path,
    );
    expect(_requests, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('R10 TeX href and includegraphics do not fetch', (tester) async {
    await show(
      tester,
      r'\(\href{https://example.test}{x}\) \(\includegraphics{x}\)',
      media.path,
    );
    expect(tester.widget<HtmlWidget>(find.byType(HtmlWidget)).onTapUrl, isNull);
    expect(_requests, isEmpty);
    expect(tester.takeException(), isNull);
  });

  test('four unmatched closers nest four elements deep', () {
    expect(cardHtmlTagDepth('<div></b>' * 4), 4);
  });

  test('oversized tag lists are rejected before a parse', () {
    resetCardHtmlFallbackCache();
    final nested = '<div>' * 50000;
    final flat = '<b>x</b>' * 100000;
    final watch = Stopwatch()..start();
    expect(cardHtmlNeedsPlainFallback(nested), isTrue);
    expect(cardHtmlNeedsPlainFallback(flat), isTrue);
    expect(watch.elapsed, lessThan(const Duration(milliseconds: 500)));
    expect(cardHtmlParseCount, 0);
  });

  bool loneHighSurrogate(String value) {
    if (value.isEmpty) return false;
    final unit = value.codeUnitAt(value.length - 1);
    return unit >= 0xD800 && unit <= 0xDBFF;
  }

  String splitAt(int cut) {
    final high = String.fromCharCode(0xD800);
    final low = String.fromCharCode(0xDC00);
    return 'a' * (cut - 1) + high + low;
  }

  test('the 4000-unit fallback cut drops a split surrogate', () {
    final text = cardHtmlFallbackText(splitAt(kCardHtmlPlainPrefix));
    expect(loneHighSurrogate(text), isFalse);
    expect(text.length, kCardHtmlPlainPrefix - 1);
  });

  test('the 200-unit display cut drops a split surrogate', () {
    final text = cardHtmlLimit(splitAt(200), 200);
    expect(loneHighSurrogate(text), isFalse);
    expect(text.length, 199);
  });

  testWidgets('a shown fallback does not end on a high surrogate', (tester) async {
    final high = String.fromCharCode(0xD800);
    final low = String.fromCharCode(0xDC00);
    final html = '<' * 199 + high + low + '<' * 1900;
    await show(tester, html, media.path);
    final shown = tester.widget<Text>(find.byKey(const ValueKey('card-html-fallback'))).data!;
    expect(loneHighSurrogate(shown), isFalse);
    expect(shown.length, 199);
  });

  test('the fallback decision is cached for one HTML string', () {
    final html = '<b>x</b>';
    resetCardHtmlFallbackCache();
    expect(cardHtmlNeedsPlainFallback(html), isFalse);
    expect(cardHtmlNeedsPlainFallback(html), isFalse);
    expect(cardHtmlParseCount, 1);
  });

  testWidgets('R11 unmatched closers still count as nested elements', (tester) async {
    final html = '<div></b>' * (kCardHtmlMaxDepth + 8);
    expect(cardHtmlTagDepth(html), greaterThan(kCardHtmlMaxDepth));
    await show(tester, html, media.path);
    expect(find.byKey(const ValueKey('card-html-fallback')), findsOneWidget);
    expect(_requests, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a megabyte of angle brackets falls back quickly', (tester) async {
    final html = '<' * (1 << 20);
    final watch = Stopwatch()..start();
    await show(tester, html, media.path);
    expect(watch.elapsed, lessThan(const Duration(seconds: 2)));
    expect(find.byKey(const ValueKey('card-html-fallback')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('R11 deep, huge, and wide HTML falls back', (tester) async {
    final deep = '${'<div>' * 5000}x${'</div>' * 5000}';
    final huge = 'a' * (kCardHtmlMaxBytes + 1);
    final table = '<table>${'<tr><td>x</td></tr>' * 10000}</table>';
    for (final html in [deep, huge, table]) {
      final watch = Stopwatch()..start();
      await show(tester, html, media.path);
      expect(watch.elapsed, lessThan(const Duration(seconds: 2)));
      expect(find.byKey(const ValueKey('card-html-fallback')), findsOneWidget);
      expect(_requests, isEmpty);
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('R12 a media image decodes through ResizeImage', (tester) async {
    await show(tester, '<img src="inside.png">', media.path);
    final image = tester.widget<Image>(find.byKey(const ValueKey('card-img')));
    expect(image.image, isA<ResizeImage>());
    expect((image.image as ResizeImage).width, kCardImageCacheWidth);
    expect(_requests, isEmpty);
  });

  test('R13 this branch has no editor raw-chip HTML surface', () {
    expect(File('lib/editor/sanitize.dart').existsSync(), isFalse);
    expect(File('lib/editor/field_codec.dart').existsSync(), isFalse);
    expect(File('lib/editor/note_editor.dart').existsSync(), isFalse);
    final sources = Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((file) => file.path.endsWith('.dart'));
    for (final file in sources) {
      final text = file.readAsStringSync();
      expect(text.contains('raw chip'), isFalse, reason: file.path);
    }
  });
}
