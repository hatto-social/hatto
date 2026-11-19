# Prototype B — v0 "minimum usable editor"

This copy is on `spikes/editor-v0/b/proto`.
Backup of the previous state: ../proto.bak-20261119. Old tests moved to test/_old/.
- lib/field_codec.dart  codec (raw atoms sliced byte-exact from source; analyzeField decides rich vs source-edit)
- lib/proto_editable.dart  FieldController (per-code-unit marks, atoms, pending style, undo/redo, clip) + EditableField/FieldToolbar/FieldEditor
- lib/sanitize.dart  STAND-IN sanitizer (gap: no Hatto Dart sanitizer exists)
- lib/main.dart  desktop app (flutter build linux --debug -t lib/main.dart); lib/main_ime_probe.dart = old spike-d probe
- test/: v0_editor_test (widget + screenshots -> screenshots/), v0_model_test, corpus_gate_test (gates a/b over ~148k public-deck fields; WS=1 variant), codec_test (legacy)
- scripts/run_ime_v0.sh, run_all_ime_v0.sh (real fcitx5/ibus under Xvfb), app_shots.sh (real app screenshots); tool/chip_stats.dart
- evidence: ../evidence/b-v0-*.txt, evidence-ime/ (summary.txt + per-run app.jsonl/screen.png)
