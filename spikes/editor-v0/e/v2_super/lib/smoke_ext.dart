import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/widgets.dart';
import 'package:super_clipboard/super_clipboard.dart';
import 'package:super_drag_and_drop/super_drag_and_drop.dart';

Future<Uint8List?> _file(DataReader r, FileFormat f) {
  final c = Completer<Uint8List?>();
  final p = r.getFile(f, (file) async { try { c.complete(await file.readAll()); } catch (e) { c.complete(null); } }, onError: (e) { if (!c.isCompleted) c.complete(null); });
  if (p == null) return Future.value(null);
  return c.future.timeout(const Duration(seconds: 30), onTimeout: () => null);
}

Future<void> extMain(String out, void Function(String, Object) w) async {
  final clip = SystemClipboard.instance;
  w('ext.txt', clip == null ? 'SystemClipboard.instance == null' : 'super_clipboard ok');
  // DropRegion mounted to prove super_drag_and_drop loads in-process
  runApp(Directionality(textDirection: TextDirection.ltr, child: DropRegion(formats: Formats.standardFormats, onDropOver: (e) async => DropOperation.copy, onPerformDrop: (e) async {
    final res = <String>[]; for (final it in e.session.items) { res.add(it.platformFormats.join(',')); } w('drop.json', res);
  }, child: const SizedBox.expand())));
  if (clip == null) return;
  while (true) {
    await Future.delayed(const Duration(milliseconds: 400));
    final t = File('$out/trigger'); if (!t.existsSync()) continue;
    final name = t.readAsStringSync().trim(); t.deleteSync();
    final sw = Stopwatch()..start();
    try {
      final r = await clip.read();
      final res = <String, Object?>{'items': r.items.length};
      final items = [];
      for (final it in r.items) {
        final m = <String, Object?>{'platformFormats': it.platformFormats};
        m['png'] = it.canProvide(Formats.png); m['jpeg'] = it.canProvide(Formats.jpeg); m['gif'] = it.canProvide(Formats.gif); m['webp'] = it.canProvide(Formats.webp);
        m['fileUri'] = it.canProvide(Formats.fileUri); m['html'] = it.canProvide(Formats.htmlText); m['text'] = it.canProvide(Formats.plainText);
        if (it.canProvide(Formats.fileUri)) { final c = Completer<Uri?>(); it.getValue<Uri>(Formats.fileUri, (v) => c.complete(v), onError: (e) => c.complete(null)); m['fileUriValue'] = (await c.future.timeout(const Duration(seconds: 10), onTimeout: () => null))?.toString(); }
        if (it.canProvide(Formats.plainText)) { final c = Completer<String?>(); it.getValue<String>(Formats.plainText, (v) => c.complete(v), onError: (e) => c.complete(null)); m['textValue'] = (await c.future.timeout(const Duration(seconds: 10), onTimeout: () => null)); }
        if (it.canProvide(Formats.htmlText)) { final c = Completer<String?>(); it.getValue<String>(Formats.htmlText, (v) => c.complete(v), onError: (e) => c.complete(null)); final h = await c.future.timeout(const Duration(seconds: 10), onTimeout: () => null); m['htmlLen'] = h?.length; m['htmlHead'] = h?.substring(0, h.length < 120 ? h.length : 120); }
        for (final (n, f) in [('png', Formats.png), ('jpeg', Formats.jpeg)]) { if (it.canProvide(f)) { final b = await _file(it, f); m['${n}Bytes'] = b?.length; m['${n}Magic'] = b == null ? null : b.take(8).map((x) => x.toRadixString(16).padLeft(2, '0')).join(); } }
        items.add(m);
      }
      res['itemsDetail'] = items; res['ms'] = sw.elapsedMilliseconds;
      w('probe_$name.json', res);
    } catch (e) { w('probe_$name.json', {'error': '$e'}); }
  }
}
