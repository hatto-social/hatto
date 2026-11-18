#!/bin/bash
# Source-only Mac bundle. Output: spikes/editor-v0/mac_bundle/editor-spikes-mac.tgz
# Not required for the in-repo runbook. Signing settings are not included.
set -euo pipefail
S="$(cd "$(dirname "$0")/.." && pwd)"
O="$S/mac_bundle"
rm -rf "$O"
mkdir -p "$O/editor-spikes"
cd "$O/editor-spikes"
EX=(--exclude=build --exclude=.dart_tool --exclude=ephemeral --exclude=target --exclude='*.iml' --exclude=.git --exclude=node_modules --exclude=vendor)
cp_ex() { mkdir -p "$2"; tar -C "$1" "${EX[@]}" -cf - . | tar -C "$2" -xf -; }
if [[ -d "$S/vendor/anki" ]]; then cp_ex "$S/vendor/anki" anki-src; fi
for v in v1_rslib v2_super v3_control; do cp_ex "$S/e/$v" "e/$v"; done
cp_ex "$S/e/fixtures" e/fixtures
rm -f e/fixtures/huge_120mb.bin
cp "$S/e/runprobe.sh" "$S/e/clipset.c" "$S/mac/setclip.swift" e/
cp_ex "$S/b/proto" b/proto
cp_ex "$S/mac/rec_mac" m4a/rec_mac
cp "$S/m4a/"*.m4a m4a/ 2>/dev/null || true
mkdir -p c
cp_ex "$S/mac/web_mac" c/web_mac
cp_ex "$S/c/ref" c/ref
cp "$S/c/evidence/chrome_ref.png" c/ 2>/dev/null || true
cp "$S/mac/prepare.sh" .
cd "$O"
tar czf editor-spikes-mac.tgz editor-spikes
ls -la editor-spikes-mac.tgz
