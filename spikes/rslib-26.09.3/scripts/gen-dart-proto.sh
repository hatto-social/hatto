#!/usr/bin/env bash
# Regenerate Dart protobufs from the fetched Anki tree into mobile/lib/gen_proto.
set -euo pipefail
source "$(dirname "$0")/env.sh"
export PATH="${HOME}/.pub-cache/bin:${PATH}"
if ! command -v protoc-gen-dart >/dev/null; then
  dart pub global activate protoc_plugin 25.1.0
fi
out="$SPIKE_ROOT/mobile/lib/gen_proto"
rm -rf "$out"
mkdir -p "$out"
protoc --dart_out="$out" -I "$ANKI_SRC/proto" "$ANKI_SRC/proto"/anki/*.proto
echo "wrote $out"
