import 'dart:convert';
import 'dart:io';
import 'package:flutter/widgets.dart';
import 'package:e_app/src/rust/api/simple.dart';
import 'package:e_app/src/rust/frb_generated.dart';
import 'smoke_ext.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final variant = Platform.environment['VARIANT'] ?? 'v1';
  final out = Platform.environment['E_OUT'] ?? '/tmp/e_$variant';
  Directory(out).createSync(recursive: true);
  void w(String name, Object data) => File('$out/$name').writeAsStringSync(data is String ? data : jsonEncode(data));
  await RustLib.init();
  w('rslib.txt', rslibSmoke(dir: '$out/col'));
  w('greet.txt', greet(name: 'x'));
  w('pid.txt', '$pid');
  runApp(const SizedBox());
  await extMain(out, w); // clipboard probes (variant specific)
}
