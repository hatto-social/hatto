# Prototype B — v0 "minimum usable editor" (box only, not pushed)
Backup of the previous state: ../proto.bak-20261119. Old tests moved to test/_old/.
- lib/field_codec.dart  codec (raw atoms sliced byte-exact from source; analyzeField decides rich vs source-edit)
- lib/proto_editable.dart  FieldController (per-code-unit marks, atoms, pending style, undo/redo, clip) + EditableField/FieldToolbar/FieldEditor
- lib/sanitize.dart  STAND-IN sanitizer (gap: no Hatto Dart sanitizer exists)
- lib/main.dart  desktop app (flutter build linux --debug -t lib/main.dart); lib/main_ime_probe.dart = old spike-d probe
- test/: v0_editor_test (widget + screenshots -> screenshots/), v0_model_test, corpus_gate_test (gates a/b over ~148k public-deck fields; WS=1 variant), codec_test (legacy)
- scripts/run_ime_v0.sh, run_all_ime_v0.sh (real fcitx5/ibus under Xvfb), app_shots.sh (real app screenshots); tool/chip_stats.dart
- evidence: ../evidence/b-v0-*.txt, evidence-ime/ (summary.txt + per-run app.jsonl/screen.png)

## Anki Desktop design alignment (added)
See /workspace/v0-kickoff/notion-drafts/DMITRY_EDITOR_ANKI_DESIGN_REVIEW.md. New: lib/anki_ui.dart, lib/note_editor.dart, lib/anki_icon_data.dart; FieldController.selectionFg.
Flagged non-contract: `forcedByUser` / VOLUNTARY_HTML=1 (default off). highlight/eraser/lists/align/mic/equation are disabled placeholders only.
Tests: `flutter test` = 37 pass (incl. 8 in test/anki_ui_test.dart); IME 16 scenarios identical to before. Screenshots: screenshots/anki_compare/.
