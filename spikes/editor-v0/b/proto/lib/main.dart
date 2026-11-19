// Prototype B desktop app (v0 minimum usable editor). Env: INIT_HTML | SAMPLE=<corpus key>, MEDIA_DIR, IME_LOG.
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'corpus.dart';
import 'proto_editable.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const EditorApp());
}

class EditorApp extends StatelessWidget {
  const EditorApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
        debugShowCheckedModeBanner: false, title: 'editor_proto',
        theme: ThemeData(fontFamily: 'Liberation Sans', fontFamilyFallback: const ['NanumGothic']),
        home: const Scaffold(backgroundColor: Color(0xfff6f6f8), body: Padding(padding: EdgeInsets.all(16), child: _Home())));
}

const _extra = <String, String>{
  'v0-demo': '<b>굵게 <i>굵고 기울임</i></b> <u>밑줄</u> H<sub>2</sub>O x<sup>2</sup> <span style="color: #d32f2f">빨강</span> \\(e^{i\\pi}+1=0\\) {{c1::서울::수도}} [sound:rec.m4a]<br><img src="demo.png"> <ul><li>목록은 v1</li></ul> 끝',
  'empty': '',
};

class _Home extends StatefulWidget { const _Home(); @override State<_Home> createState() => _HomeState(); }
class _HomeState extends State<_Home> {
  late String sample = Platform.environment['SAMPLE'] ?? (Platform.environment['INIT_HTML'] != null ? '(INIT_HTML)' : 'v0-demo');
  late FieldController c = _make();
  final fn = FocusNode();
  String? savedHtml;
  final logPath = Platform.environment['IME_LOG'];

  Map<String, String> get samples => {..._extra, ...corpus};
  FieldController _make() {
    final html = sample == '(INIT_HTML)' ? Platform.environment['INIT_HTML']! : samples[sample] ?? '';
    final k = FieldController(html, mediaDir: Platform.environment['MEDIA_DIR'] ?? 'screenshots/media');
    if (logPath != null) {
      k.addListener(() => File(logPath!).writeAsStringSync('${jsonEncode({'text': k.text, 'html': k.toHtml(), 'save': k.save(), 'pending': k.pending?.toString(), 'sel': [k.selection.start, k.selection.end], 'composing': [k.value.composing.start, k.value.composing.end], 'dirty': k.dirty, 'rich': k.isRich, 'marks': k.isRich ? k.marksDump() : null})}\n', mode: FileMode.append));
    }
    return k;
  }

  @override
  void initState() { super.initState(); WidgetsBinding.instance.addPostFrameCallback((_) => fn.requestFocus()); }

  @override
  Widget build(BuildContext context) {
    final names = ['(INIT_HTML)', ...samples.keys].where((n) => n != '(INIT_HTML)' || Platform.environment['INIT_HTML'] != null).toList();
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        const Text('필드 샘플: '),
        DropdownButton<String>(value: sample, items: [for (final n in names) DropdownMenuItem(value: n, child: Text(n))], onChanged: (v) => setState(() { sample = v!; c = _make(); savedHtml = null; WidgetsBinding.instance.addPostFrameCallback((_) => fn.requestFocus()); })),
        const SizedBox(width: 12),
        FilledButton(onPressed: () => setState(() => savedHtml = c.save()), child: const Text('저장(save)')),
      ]),
      const SizedBox(height: 8),
      FieldEditor(c, fn, width: 560, fontFamily: 'Liberation Sans', fontFamilyFallback: const ['NanumGothic']),
      const SizedBox(height: 12),
      ListenableBuilder(listenable: c, builder: (_, _) => Container(width: 560, padding: const EdgeInsets.all(8), color: const Color(0xffeceff4), child: Text(
        '모드: ${c.modeLabel}   dirty: ${c.dirty}   pending: ${c.pending ?? '-'}\n저장 결과(HTML): ${savedHtml ?? '(저장 안 함)'}\n현재 인코딩: ${c.toHtml()}',
        style: const TextStyle(fontSize: 12, fontFamily: 'NanumGothicCoding')))),
    ]);
  }
}
