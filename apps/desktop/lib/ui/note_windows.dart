// SPDX-FileCopyrightText: 2026 Hatto Social contributors
//
// SPDX-License-Identifier: AGPL-3.0-or-later

// Add-note window (Type/Deck choosers + editable tags + real add through rslib) and Edit-note window.
// The editor itself is Prototype B (lib/editor): untouched fields keep their original bytes (field_codec gate a).
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../editor/anki_ui.dart';
import '../editor/note_editor.dart';
import '../engine/anki_api.dart';
import '../state/app_controller.dart';
import 'common.dart';

/// Image attach: the native file dialog needs a platform plugin (file_selector) - not wired in this prototype.
/// Stub = path prompt (default: env HATTO_DEMO_IMAGE or ~/Pictures). rslib copies the file into collection.media and returns the final name.
Future<String?> pickAndImportImage(BuildContext context, AnkiColors k, FlowApi api, {String initial = ''}) async {
  final path = await promptText(context, k, title: '이미지 넣기', label: '이미지 파일 경로:', initial: initial, ok: '넣기', hint: '(파일 선택 대화상자는 플랫폼 서비스로 후속 — 이 프로토타입은 경로 입력)');
  if (path == null || path.trim().isEmpty) return null;
  try { return await api.addMediaFromPath(path.trim()); } on BackendException catch (e) { if (context.mounted) { ScaffoldMessenger.maybeOf(context); } debugPrint('addMedia failed: $e'); return null; }
}

class AddNoteWindow extends StatefulWidget {
  const AddNoteWindow({super.key, required this.app, required this.colors, this.demoImage = ''});
  final AppController app; final AnkiColors colors; final String demoImage;
  @override State<AddNoteWindow> createState() => _AddNoteWindowState();
}

class _AddNoteWindowState extends State<AddNoteWindow> {
  FlowApi get api => widget.app.api;
  List<NotetypeNameId> types = []; List<DeckNameId> decks = [];
  int ntid = 0, deckId = 0; String ntName = '', deckName = ''; List<String> fieldNames = []; List<String> tags = [];
  List<String> carry = []; int gen = 0, added = 0; String status = ''; bool ready = false;
  var edKey = GlobalKey<NoteEditorState>();

  @override void initState() { super.initState(); _load(); }
  Future<void> _load() async {
    types = await api.notetypeNames(); decks = await api.deckNames();
    final d = await api.defaultsForAdding();
    await _setType(d.notetypeId.toInt(), keep: false);
    deckId = d.deckId.toInt(); deckName = decks.where((e) => e.id.toInt() == deckId).map((e) => e.name).firstOrNull ?? (decks.isEmpty ? '' : decks.first.name);
    if (deckName.isNotEmpty && decks.every((e) => e.id.toInt() != deckId)) deckId = decks.first.id.toInt();
    ready = true; if (mounted) setState(() {});
  }
  Future<void> _setType(int id, {bool keep = true}) async {
    final old = keep && edKey.currentState != null ? edKey.currentState!.saveAll() : <String>[];
    ntid = id; ntName = types.firstWhere((t) => t.id.toInt() == id, orElse: () => types.first).name; fieldNames = await api.fieldNames(id);
    carry = [for (var i = 0; i < fieldNames.length; i++) i < old.length ? old[i] : '']; gen++; edKey = GlobalKey<NoteEditorState>();
    if (mounted) setState(() {});
  }

  Future<void> _add(List<String> htmls) async {
    final n = await api.newNote(ntid); n.fields.clear(); n.fields.addAll(htmls); n.tags.clear(); n.tags.addAll(tags);
    final st = await api.checkNote(n);
    if (st == NoteFieldsCheckResponse_State.EMPTY) { setState(() => status = '첫 번째 필드가 비어 있어서 추가할 수 없어요'); return; }
    if (st == NoteFieldsCheckResponse_State.MISSING_CLOZE) { setState(() => status = '클로즈 노트에는 {{c1::…}} 가 하나 이상 필요해요'); return; }
    final dup = st == NoteFieldsCheckResponse_State.DUPLICATE;
    await api.addNote(n, deckId); added++;
    await widget.app.refreshDecks();
    carry = [for (final _ in fieldNames) '']; gen++; edKey = GlobalKey<NoteEditorState>();
    setState(() => status = '노트 추가됨 ($added번째)${dup ? ' — 같은 첫 필드의 노트가 이미 있었어요(중복 허용)' : ''}');
  }

  @override
  Widget build(BuildContext context) {
    final k = widget.colors;
    return AnkiTheme(colors: k, child: DefaultTextStyle(style: ankiText(k), child: WindowFrame(title: '추가', width: 980, height: 690, onClose: () => Navigator.pop(context),
      child: !ready ? const SizedBox() : Column(children: [
        Expanded(child: CallbackShortcuts(bindings: {const SingleActivator(LogicalKeyboardKey.enter, control: true): () { final s = edKey.currentState; if (s != null) _add(s.saveAll()); }},
          child: KeyedSubtree(key: ValueKey('add-ed-$gen-$ntid'), child: NoteEditor(key: edKey, colors: k, mediaDir: api.mediaDir, notetype: ntName, deck: deckName, tags: tags, editableTags: true, onTagsChanged: (t) => tags = t,
            fields: [for (var i = 0; i < fieldNames.length; i++) NoteFieldSpec(fieldNames[i], carry[i])], addLabel: '추가', footerHelp: false,
            onChooseType: () async { final r = await chooseFrom<int>(context, k, title: '노트 유형 선택', items: [for (final t in types) (t.name, t.id.toInt())], selected: ntid); if (r != null && r != ntid) await _setType(r); },
            onChooseDeck: () async { final r = await chooseFrom<int>(context, k, title: '덱 선택', items: [for (final d in decks) (d.name, d.id.toInt())], selected: deckId); if (r != null) setState(() { deckId = r; deckName = decks.firstWhere((d) => d.id.toInt() == r).name; }); },
            onImage: () => pickAndImportImage(context, k, api, initial: widget.demoImage), onAdd: _add, onClose: () => Navigator.pop(context))))),
        Container(height: 22, color: k.canvas, padding: const EdgeInsets.symmetric(horizontal: 14), alignment: Alignment.centerLeft, child: Text(status, key: const ValueKey('add-status'), style: ankiText(k, size: 12, color: k.fgSubtle).copyWith(height: 1))),
      ]))));
  }
}

/// Edit an existing note (reviewer "Edit", browser). Saves on close.
class EditNoteWindow extends StatefulWidget {
  const EditNoteWindow({super.key, required this.app, required this.colors, required this.noteId});
  final AppController app; final AnkiColors colors; final int noteId;
  @override State<EditNoteWindow> createState() => _EditNoteWindowState();
}
class _EditNoteWindowState extends State<EditNoteWindow> {
  Note? note; List<String> names = []; final key = GlobalKey<NoteEditorState>();
  @override void initState() { super.initState(); () async { final n = await widget.app.api.getNote(widget.noteId); names = await widget.app.api.fieldNames(n.notetypeId.toInt()); setState(() => note = n); }(); }
  Future<void> _save() async {
    final st = key.currentState; final n = note; if (st == null || n == null) return;
    n.fields..clear()..addAll(st.saveAll()); n.tags..clear()..addAll(st.currentTags);
    await widget.app.api.updateNote(n);
  }
  @override
  Widget build(BuildContext context) {
    final k = widget.colors; final n = note;
    return AnkiTheme(colors: k, child: DefaultTextStyle(style: ankiText(k), child: WindowFrame(title: '노트 편집', width: 820, height: 560, onClose: () async { await _save(); if (context.mounted) Navigator.pop(context); },
      child: n == null ? const SizedBox() : Column(children: [
        Expanded(child: NoteEditor(key: key, colors: k, mediaDir: widget.app.api.mediaDir, showChrome: false, tags: n.tags.toList(), editableTags: true, fields: [for (var i = 0; i < names.length; i++) NoteFieldSpec(names[i], n.fields[i])])),
        Padding(padding: const EdgeInsets.all(8), child: Row(mainAxisAlignment: MainAxisAlignment.end, children: [QtPush('닫기(저장)', key: const ValueKey('edit-close'), width: 110, onTap: () async { await _save(); if (context.mounted) Navigator.pop(context); })])),
      ]))));
  }
}
