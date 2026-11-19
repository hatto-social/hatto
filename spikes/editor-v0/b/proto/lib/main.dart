// Prototype B desktop app: Anki-look Add-note window around the v0 editor.
// Env: SAMPLE=<corpus key> | INIT_HTML (Front field html), INIT_HTML2 (Back), MEDIA_DIR, IME_LOG (logs Front), THEME=light|dark,
//      VOLUNTARY_HTML=1 (FLAGGED option), DEV_PANEL=1 (side debug panel), TAGS="a,b", NOTETYPE, DECK, PALETTE_OPEN=1.
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'anki_ui.dart';
import 'corpus.dart';
import 'note_editor.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const EditorApp());
}

const _extra = <String, String>{
  'v0-demo': '<b>굵게 <i>굵고 기울임</i></b> <u>밑줄</u> H<sub>2</sub>O x<sup>2</sup> <span style="color: #d32f2f">빨강</span> \\(e^{i\\pi}+1=0\\) {{c1::서울::수도}} [sound:rec.m4a]<br><img src="demo.png"> <ul><li>목록은 v1</li></ul> 끝',
  'empty': '',
};
const _back = '다음 줄 \\(e^{i\\pi}+1=0\\)<br>[sound:rec.m4a] <span style="color: #1565c0">파랑</span> 끝';

class EditorApp extends StatefulWidget { const EditorApp({super.key}); @override State<EditorApp> createState() => _EditorAppState(); }
class _EditorAppState extends State<EditorApp> {
  final env = Platform.environment;
  late bool dark = env['THEME'] == 'dark';
  final key = GlobalKey<NoteEditorState>();
  List<String>? saved; int? focusedIdx;
  Map<String, String> get samples => {..._extra, ...corpus};
  String get frontHtml { final sample = env['SAMPLE'] ?? (env['INIT_HTML'] != null ? '(INIT_HTML)' : 'v0-demo'); return sample == '(INIT_HTML)' ? env['INIT_HTML']! : samples[sample] ?? ''; }
  late final String mediaDir = env['MEDIA_DIR'] ?? 'screenshots/media';

  @override
  void initState() {
    super.initState();
    final logPath = env['IME_LOG'];
    if (logPath != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final k = key.currentState!.controllerAt(0);
        k.addListener(() => File(logPath).writeAsStringSync('${jsonEncode({'text': k.text, 'html': k.toHtml(), 'save': k.save(), 'pending': k.pending?.toString(), 'sel': [k.selection.start, k.selection.end], 'composing': [k.value.composing.start, k.value.composing.end], 'dirty': k.dirty, 'rich': k.isRich, 'marks': k.isRich ? k.marksDump() : null})}\n', mode: FileMode.append));
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = dark ? AnkiColors.darkTheme : AnkiColors.light;
    final tags = (env['TAGS'] ?? 'korean::vocab,noun').split(',').where((e) => e.isNotEmpty).toList();
    final editor = NoteEditor(key: key, colors: colors, mediaDir: mediaDir, tags: tags, notetype: env['NOTETYPE'] ?? 'Basic', deck: env['DECK'] ?? 'Default',
      voluntaryHtmlToggle: env['VOLUNTARY_HTML'] == '1', onAdd: (h) => setState(() => saved = h), onFocusedChanged: (i) => setState(() => focusedIdx = i),
      fields: [NoteFieldSpec('Front', frontHtml), NoteFieldSpec('Back', env['INIT_HTML2'] ?? (env['INIT_HTML'] != null ? '' : _back))]);
    return MaterialApp(
      debugShowCheckedModeBanner: false, title: 'editor_proto',
      theme: ThemeData(fontFamily: kUiFont, fontFamilyFallback: const ['NanumGothic'], brightness: dark ? Brightness.dark : Brightness.light),
      home: Shortcuts(
        shortcuts: {const SingleActivator(LogicalKeyboardKey.keyD, control: true, alt: true): VoidCallbackIntent(() => setState(() => dark = !dark))},
        child: Actions(actions: {VoidCallbackIntent: VoidCallbackAction()}, child: Scaffold(backgroundColor: colors.canvas, body: Row(children: [
          Expanded(child: editor),
          if (env['DEV_PANEL'] == '1') Container(width: 340, padding: const EdgeInsets.all(8), color: const Color(0xffeceff4), child: _Dev(key, saved, focusedIdx)),
        ])))));
  }
}

class _Dev extends StatelessWidget {
  const _Dev(this.k, this.saved, this.focusedIdx);
  final GlobalKey<NoteEditorState> k; final List<String>? saved; final int? focusedIdx;
  @override
  Widget build(BuildContext context) {
    final st = k.currentState;
    final c = st == null ? null : st.controllerAt(focusedIdx ?? 0);
    return DefaultTextStyle(style: const TextStyle(fontSize: 11, color: Colors.black, fontFamily: 'NanumGothicCoding', decoration: TextDecoration.none),
      child: SingleChildScrollView(child: c == null ? const Text('...') : ListenableBuilder(listenable: c, builder: (_, _) => Text(
        '필드 #${focusedIdx ?? 0}  모드: ${c.modeLabel}  dirty: ${c.dirty}  pending: ${c.pending ?? '-'}\n\n저장(추가 버튼) 결과: ${saved ?? '(없음)'}\n\n현재 인코딩: ${c.toHtml()}'))));
  }
}
