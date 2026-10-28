#!/usr/bin/env bash
# Field-level re-export fidelity: napi roundtrip, FRB host roundtrip, then napi import of the FRB export.
set -euo pipefail
source "$(dirname "$0")/env.sh"
export PATH="${HOME}/sdk/flutter/bin:${PATH}"
export HATTO_FIDELITY_DIR="${HATTO_FIDELITY_DIR:-/tmp/hatto-fidelity}"
export HATTO_SPIKE_ROOT="$SPIKE_ROOT"
export HATTO_RSLIB_LIB="${HATTO_RSLIB_LIB:-$SPIKE_ROOT/target/release/libhatto_rslib_frb.so}"
rm -rf "$HATTO_FIDELITY_DIR"
mkdir -p "$HATTO_FIDELITY_DIR"
cd "$SPIKE_ROOT/napi"
node test/fidelity.mjs
cd "$SPIKE_ROOT/mobile"
flutter test test/fidelity_test.dart
cp "$HATTO_FIDELITY_DIR/frb-fidelity.json" "$SPIKE_ROOT/results/frb-fidelity.json"
cd "$SPIKE_ROOT/napi"
node test/fidelity.mjs --phase=server
echo "results: $SPIKE_ROOT/results/napi-fidelity.json $SPIKE_ROOT/results/frb-fidelity.json $SPIKE_ROOT/results/server-from-frb.json"
