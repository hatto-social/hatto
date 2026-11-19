import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:editor_proto/proto_editable.dart';

File _font(List<String> candidates, String label) {
  for (final p in candidates) {
    final f = File(p);
    if (f.existsSync()) return f;
  }
  throw StateError('$label not found. Tried: $candidates');
}

ByteData _bytes(File f) => ByteData.sublistView(f.readAsBytesSync());

Future<void> loadFont() async {
  final nanum = _font([
    '/usr/share/fonts/truetype/nanum/NanumGothic.ttf',
    '../../fonts/NanumGothic.ttf',
  ], 'NanumGothic');
  final nanumBold = _font([
    '/usr/share/fonts/truetype/nanum/NanumGothicBold.ttf',
    '../../fonts/NanumGothic.ttf',
  ], 'NanumGothicBold');
  final fl = FontLoader('NanumGothic')
    ..addFont(Future.value(_bytes(nanum)))
    ..addFont(Future.value(_bytes(nanumBold)));
  await fl.load();
  final lib = FontLoader('LiberationSans');
  for (final n in ['Regular', 'Bold', 'Italic', 'BoldItalic']) {
    lib.addFont(Future.value(_bytes(_font([
      '/usr/share/fonts/truetype/liberation/LiberationSans-$n.ttf',
    ], 'LiberationSans-$n'))));
  }
  await lib.load();
  final flutterRoot = Platform.environment['FLUTTER_ROOT'] ?? '/opt/flutter-3.50';
  final icons = _font([
    '$flutterRoot/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
    '/opt/flutter-3.50/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
  ], 'MaterialIcons');
  final mi = FontLoader('MaterialIcons')..addFont(Future.value(_bytes(icons)));
  await mi.load();
}

// Latin font that has OpenType sups/subs (NanumGothic lacks them); Korean falls back to NanumGothic.
const latinFont = 'LiberationSans';
final shotKey = GlobalKey();
/// Committed captures live in screenshots/. Tests write beside them only when
/// SHOT_DIR is set; otherwise they write under the system temp dir so a test
/// run does not replace the box captures.
final shotDir = Platform.environment['SHOT_DIR'] ?? '${Directory.systemTemp.path}/editor-proto-shots';

/// Build a captioned editor surface for screenshots.
Future<void> pumpEditor(WidgetTester tester, FieldController c, FocusNode fn, {String? caption, bool paletteOpen = false, double width = 460, double w = 520, double h = 230, List<Widget> below = const []}) async {
  tester.view.physicalSize = Size(w * 2, h * 2); tester.view.devicePixelRatio = 2;
  addTearDown(() { tester.view.resetPhysicalSize(); tester.view.resetDevicePixelRatio(); });
  await tester.pumpWidget(RepaintBoundary(key: shotKey, child: MaterialApp(debugShowCheckedModeBanner: false, theme: ThemeData(fontFamily: 'NanumGothic'),
    home: Scaffold(backgroundColor: const Color(0xfff6f6f8), body: Align(alignment: Alignment.topLeft, child: Container(color: const Color(0xfff6f6f8), padding: const EdgeInsets.all(16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        if (caption != null) Padding(padding: const EdgeInsets.only(bottom: 8), child: Text(caption, style: const TextStyle(fontSize: 13, color: Color(0xff555555), fontFamily: 'NanumGothic', decoration: TextDecoration.none))),
        FieldEditor(c, fn, width: width, paletteOpen: paletteOpen, fontFamily: latinFont, fontFamilyFallback: const ['NanumGothic']), ...below])))))));
  await tester.pump();
}

Future<void> preloadThumbs(WidgetTester tester, FieldController c) async {
  await tester.runAsync(() async {
    final ctx = tester.element(find.byType(EditableText));
    for (final b in c.thumbBytes()) { await precacheImage(MemoryImage(b), ctx); }
  });
  await tester.pump();
}

Future<void> shot(WidgetTester tester, String name) async {
  await tester.pump();
  await tester.runAsync(() async {
    final ro = shotKey.currentContext!.findRenderObject() as RenderRepaintBoundary;
    final img = await ro.toImage(pixelRatio: 2);
    final bd = await img.toByteData(format: ui.ImageByteFormat.png);
    File('$shotDir/$name.png').writeAsBytesSync(bd!.buffer.asUint8List());
  });
}

/// Replay a Korean-IME-like update through the TextInput channel.
void ime(WidgetTester tester, String t, int cs, int ce, {int? caret}) => tester.testTextInput.updateEditingValue(TextEditingValue(
    text: t, selection: TextSelection.collapsed(offset: caret ?? (ce > cs ? ce : t.length)), composing: ce > cs ? TextRange(start: cs, end: ce) : TextRange.empty));

Future<File> makePng(String path, {Color a = const Color(0xff4a90d9), Color b = const Color(0xffe94f37)}) async {
  final rec = ui.PictureRecorder(); final cv = Canvas(rec);
  cv.drawRect(const Rect.fromLTWH(0, 0, 128, 96), Paint()..shader = ui.Gradient.linear(Offset.zero, const Offset(128, 96), [a, b]));
  cv.drawCircle(const Offset(64, 48), 22, Paint()..color = Colors.white70);
  final img = await rec.endRecording().toImage(128, 96);
  final bd = await img.toByteData(format: ui.ImageByteFormat.png);
  return File(path)..writeAsBytesSync(bd!.buffer.asUint8List());
}
