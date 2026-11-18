import 'dart:io';
import 'package:flutter/widgets.dart';
import 'package:pasteboard/pasteboard.dart';
import 'package:desktop_drop/desktop_drop.dart';

Future<void> extMain(String out, void Function(String, Object) w) async {
  w('ext.txt', 'pasteboard+desktop_drop');
  runApp(Directionality(textDirection: TextDirection.ltr, child: DropTarget(onDrop: (d) async => w('drop.json', d.items.map((i) => i.toString()).toList()), child: const SizedBox.expand())));
  while (true) {
    await Future.delayed(const Duration(milliseconds: 400));
    final t = File('$out/trigger'); if (!t.existsSync()) continue;
    final name = t.readAsStringSync().trim(); t.deleteSync();
    final sw = Stopwatch()..start();
    try {
      final img = await Pasteboard.image; final files = await Pasteboard.files(); final html = await Pasteboard.html; final text = await Pasteboard.text;
      w('probe_$name.json', {'imageBytes': img?.length, 'imageMagic': img?.take(8).map((x) => x.toRadixString(16).padLeft(2, '0')).join(), 'files': files, 'htmlLen': html?.length, 'htmlHead': html == null ? null : html.substring(0, html.length < 120 ? 120.clamp(0, html.length) : 120), 'text': text, 'ms': sw.elapsedMilliseconds});
    } catch (e) { w('probe_$name.json', {'error': '$e'}); }
  }
}
