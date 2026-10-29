#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/env.sh"
export PATH="${HOME}/sdk/flutter/bin:${PATH}"
export HATTO_RSLIB_LIB="$SPIKE_ROOT/target/release/libhatto_rslib_frb.so"
export HATTO_INSPECT_APKG="$SPIKE_ROOT/scripts/inspect-apkg.py"
cd "$SPIKE_ROOT/mobile"
flutter test test/roundtrip_test.dart
