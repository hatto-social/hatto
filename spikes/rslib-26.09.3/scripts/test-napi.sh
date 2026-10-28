#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/env.sh"
cd "$SPIKE_ROOT/napi"
if [[ ! -d node_modules/protobufjs ]]; then
  npm install --no-audit --no-fund
fi
node test/roundtrip.mjs
