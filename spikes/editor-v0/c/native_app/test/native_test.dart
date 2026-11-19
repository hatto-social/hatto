import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:c_native/native_card.dart';

Future<void> loadNanum() async {
  final file = File('../../fonts/NanumGothic.ttf');
  expect(file.existsSync(), true, reason: 'bundle spikes/editor-v0/fonts/NanumGothic.ttf');
  final fl = FontLoader('NanumGothic')..addFont(Future.value(ByteData.sublistView(file.readAsBytesSync())));
  await fl.load();
}

Future<void> loadKatexFonts() async {
  final roots = <String>[
    if (Platform.environment['PUB_CACHE'] != null) Platform.environment['PUB_CACHE']!,
    '${Platform.environment['HOME']}/.pub-cache',
  ];
  Directory? fonts;
  for (final root in roots) {
    final hosted = Directory('$root/hosted');
    if (!hosted.existsSync()) continue;
    for (final host in hosted.listSync().whereType<Directory>()) {
      for (final pkg in host.listSync().whereType<Directory>()) {
        if (!pkg.path.contains('flutter_math_fork-')) continue;
        final candidate = Directory('${pkg.path}/lib/katex_fonts/fonts');
        if (candidate.existsSync()) fonts = candidate;
      }
    }
  }
  expect(fonts, isNotNull, reason: 'flutter_math_fork katex fonts in the pub cache');
  final fams = <String, List<String>>{};
  for (final f in fonts!.listSync().whereType<File>().where((f) => f.path.endsWith('.ttf'))) {
    fams.putIfAbsent('packages/flutter_math_fork/${f.uri.pathSegments.last.split('-').first}', () => []).add(f.path);
  }
  for (final e in fams.entries) {
    final l = FontLoader(e.key);
    for (final p in e.value) {
      l.addFont(Future.value(ByteData.sublistView(File(p).readAsBytesSync())));
    }
    await l.load();
  }
}

void main() {
  testWidgets('preview render native', (tester) async {
    await loadNanum();
    await loadKatexFonts();
    final img = File('../ref/paste-1.png').absolute;
    expect(img.existsSync(), true);
    tester.view.physicalSize = const Size(640, 520);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final basic =
        '서울은 <b>대한민국</b>의 수도 \\(e^{i\\pi}+1=0\\) <img src="file://${img.path}" width="64"> [sound:rec-1.m4a]<hr id=answer>H<sub>2</sub>O <span style="color: #ff0000">red</span> {{c9::literal-not-cloze}}';
    const cloze =
        '<span class="cloze" data-ordinal="1">서울</span>는 <span class="cloze-inactive" data-ordinal="2">한국</span>의 <span class="cloze" data-ordinal="1">수도</span> \\[x^2\\]<br>\nextra <i>info</i>';
    await tester.pumpWidget(MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Material(
        color: Colors.white,
        child: Align(
          alignment: Alignment.topLeft,
          child: RepaintBoundary(
            key: const Key('preview-native'),
            child: ColoredBox(
              color: Colors.white,
              child: Column(children: [nativeCard(basic), const SizedBox(height: 12), nativeCard(cloze)]),
            ),
          ),
        ),
      ),
    ));
    // FileImage does not finish decoding in the test binding (same limit as the
    // original spike). The golden shows the text, formula, and cloze; the bitmap is absent.
    await tester.runAsync(() async {
      await Future.delayed(const Duration(seconds: 2));
    });
    await tester.pumpAndSettle();
    await expectLater(find.byKey(const Key('preview-native')), matchesGoldenFile('../goldens/preview_native.png'));
    final sw = Stopwatch()..start();
    for (var i = 0; i < 20; i++) {
      await tester.pumpWidget(MaterialApp(home: Material(child: nativeCard(basic))));
      await tester.pump();
    }
    File('../evidence/native_timing.txt').writeAsStringSync('20 rebuilds of basic card: ${sw.elapsedMilliseconds} ms (test binding, CPU raster off)\n');
  });
}
