#!/usr/bin/env bash
# Host smoke: rslib collection open, side DB, and the Flutter bridge test.
# Android/NDK is not part of this script. See the README.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

if [[ -x "${HOME}/.local/protoc/bin/protoc" ]]; then
  export PATH="${HOME}/.local/protoc/bin:${PATH}"
fi
if ! command -v flutter >/dev/null 2>&1 && [[ -x "${HOME}/sdk/flutter/bin/flutter" ]]; then
  export PATH="${HOME}/sdk/flutter/bin:${PATH}"
fi

if ! command -v protoc >/dev/null 2>&1; then
  echo "protoc is required (Anki 26.09.3 uses protoc 31.1). Install it and put it on PATH." >&2
  exit 1
fi
if ! protoc --version | grep -q 'libprotoc 31\.'; then
  echo "warning: expected protoc 31.x (Anki pins 31.1); found: $(protoc --version)" >&2
fi

export CARGO_BUILD_JOBS="${CARGO_BUILD_JOBS:-2}"
export CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-$ROOT/target}"

echo "== cargo test -p rslib_bridge =="
cargo test -p rslib_bridge -- --test-threads=1

echo "== dart test packages/hatto_store =="
# Run inside the package so Dart builds its native-asset hooks. From the
# workspace root, `dart test <path>` skips dependency hooks.
(cd packages/hatto_store && dart test)

echo "== flutter test apps/mobile =="
(cd apps/mobile && flutter test)
