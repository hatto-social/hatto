// IME probe app (spike d): FIELD=a -> super_editor, FIELD=b -> EditableText. Logs every state change to $IME_LOG.
import 'dart:io';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:super_editor/super_editor.dart';
import 'proto_editable.dart';
import 'proto_super.dart';

void main() {
  final which = Platform.environment['FIELD'] ?? 'b';
  final logPath = Platform.environment['IME_LOG'] ?? '/tmp/ime.log';
  final init = Platform.environment['INIT_HTML'] ?? '';
  void log(Map<String, Object?> m) { File(logPath).writeAsStringSync('${jsonEncode(m)}\n', mode: FileMode.append); }
  WidgetsFlutterBinding.ensureInitialized();
  runApp(MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: ThemeData(fontFamily: "NanumGothic"),
    home: Scaffold(body: Padding(padding: const EdgeInsets.all(20), child: which == 'a' ? _A(init, log) : _B(init, log))),
  ));
}

class _B extends StatefulWidget { const _B(this.init, this.log); final String init; final void Function(Map<String, Object?>) log; @override State<_B> createState() => _BS(); }
class _BS extends State<_B> {
  late final c = FieldController(widget.init); final fn = FocusNode();
  @override void initState() { super.initState(); c.addListener(() => widget.log({'f': 'B', 'text': c.text, 'html': c.toHtml(), 'sel': [c.selection.start, c.selection.end], 'composing': [c.value.composing.start, c.value.composing.end]})); WidgetsBinding.instance.addPostFrameCallback((_) => fn.requestFocus()); }
  @override Widget build(BuildContext context) => Align(alignment: Alignment.topLeft, child: EditableField(c, fn));
}
class _A extends StatefulWidget { const _A(this.init, this.log); final String init; final void Function(Map<String, Object?>) log; @override State<_A> createState() => _AS(); }
class _AS extends State<_A> {
  late final f = SuperField(widget.init);
  @override void initState() { super.initState(); f.doc.addListener((_) => widget.log({'f': 'A', 'html': f.toHtml(), 'text': f.text.toPlainText(), 'sel': f.composer.selection?.extent.nodePosition.toString()})); }
  @override Widget build(BuildContext context) => Align(alignment: Alignment.topLeft, child: Focus(autofocus: true, child: superFieldWidget(f)));
}
