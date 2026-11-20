#!/usr/bin/env bash

# SPDX-FileCopyrightText: 2026 Hatto Social contributors
#
# SPDX-License-Identifier: AGPL-3.0-or-later

# Release BUILD_INFO fails closed without the toolchain. Determinism mode
# labels those lines as placeholders and is stable across two writes.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PY="$ROOT/tools/release/stage_source_tree.py"
SHA="$(git -C "$ROOT" rev-parse HEAD)"
TAG="v0.0.0-build-info-test"
VER="0.0.0-build-info-test"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

bare_env() {
  env -u ANDROID_NDK_HOME -u ANDROID_NDK_ROOT -u ANDROID_HOME -u ANDROID_SDK_ROOT \
    PATH="/usr/bin:/bin" \
    "$@"
}

echo "== determinism placeholders, twice =="
one="$(mktemp)"
two="$(mktemp)"
trap 'rm -f "$one" "$two"' EXIT
bare_env python3 "$PY" \
  --root "$ROOT" \
  --write-only \
  --output "$one" \
  --mode determinism \
  --tag "$TAG" \
  --version "$VER" \
  --sha "$SHA"
bare_env python3 "$PY" \
  --root "$ROOT" \
  --write-only \
  --output "$two" \
  --mode determinism \
  --tag "$TAG" \
  --version "$VER" \
  --sha "$SHA"
cmp "$one" "$two"
grep -q '^build_info_mode: determinism$' "$one" || fail "mode line"
grep -q '^rustc: placeholder:' "$one" || fail "rustc placeholder"
grep -q '^cargo: placeholder:' "$one" || fail "cargo placeholder"
grep -q '^protoc: placeholder:' "$one" || fail "protoc placeholder"
grep -q '^ndk: placeholder:' "$one" || fail "ndk placeholder"
grep -q '^flutter: placeholder:' "$one" || fail "flutter placeholder"
grep -q '^submodule third_party/anki ' "$one" || fail "anki submodule"
grep -q 'native.sqlite3.file.libsqlite3.arm64.android.so.sha256: ' "$one" || fail "sqlite sha"
grep -q 'native.sqlite3.file.libsqlite3.arm64.android.so.url: https://' "$one" || fail "sqlite url"

echo "== release mode refuses a missing toolchain =="
set +e
bare_env python3 "$PY" \
  --root "$ROOT" \
  --write-only \
  --output "$one" \
  --mode release \
  --tag "$TAG" \
  --version "$VER" \
  --sha "$SHA"
code=$?
set -e
if [[ "$code" -eq 0 ]]; then
  fail "release mode exited 0 without the toolchain"
fi

echo "build-info modes ok"
