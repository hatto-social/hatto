#!/usr/bin/env bash

# SPDX-FileCopyrightText: 2026 Hatto Social contributors
#
# SPDX-License-Identifier: AGPL-3.0-or-later

# Rebuild THIRD_PARTY_NOTICES.md and the app license JSON.
#
# Requires, on PATH:
#   cargo-about 0.9.3, cargo-deny 0.21.0, python3, flutter, gradle 9.3.1
# and ANDROID_HOME pointing at an SDK that can resolve the Android app.
# cargo-deny fails the script when a crate license is outside the allow list.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

need_version() {
  local cmd="$1"
  local expected="$2"
  local actual
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "$cmd is not on PATH." >&2
    exit 1
  fi
  actual="$("$cmd" --version | awk 'NR == 1 { print $2 }')"
  if [[ "$actual" != "$expected" ]]; then
    echo "$cmd is $actual; this script expects $expected." >&2
    exit 1
  fi
}

need_version cargo-about 0.9.3
need_version cargo-deny 0.21.0

if ! command -v flutter >/dev/null 2>&1; then
  echo "flutter is not on PATH." >&2
  exit 1
fi
if ! command -v gradle >/dev/null 2>&1; then
  echo "gradle is not on PATH (9.3.1, matching the Android wrapper)." >&2
  exit 1
fi
if [[ -z "${ANDROID_HOME:-}" && -z "${ANDROID_SDK_ROOT:-}" ]]; then
  echo "ANDROID_HOME is not set." >&2
  exit 1
fi

SDK_DIR="${ANDROID_HOME:-$ANDROID_SDK_ROOT}"
FLUTTER_BIN="$(command -v flutter)"
FLUTTER_ROOT="$(cd "$(dirname "$FLUTTER_BIN")/.." && pwd)"

LOCAL_PROPS="$ROOT/apps/mobile/android/local.properties"
python3 - "$LOCAL_PROPS" "$FLUTTER_ROOT" "$SDK_DIR" <<'PY'
import sys
from pathlib import Path

path, flutter_sdk, android_sdk = sys.argv[1:]
file = Path(path)
lines = file.read_text(encoding="utf-8").splitlines() if file.exists() else []
kept = [
    line
    for line in lines
    if not line.startswith("flutter.sdk=") and not line.startswith("sdk.dir=")
]
kept.append(f"sdk.dir={android_sdk}")
kept.append(f"flutter.sdk={flutter_sdk}")
file.write_text("\n".join(kept) + "\n", encoding="utf-8")
PY

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "cargo-deny check licenses"
cargo deny --locked \
  --manifest-path packages/rslib_bridge/rust/Cargo.toml \
  --config tools/license/deny.toml \
  check licenses

echo "cargo-about generate"
cargo about generate --fail --locked --format json \
  --manifest-path packages/rslib_bridge/rust/Cargo.toml \
  --config tools/license/about.toml \
  -o "$WORK/about.json"

echo "gradle licenseReleaseReport"
(
  cd apps/mobile/android
  gradle :app:licenseReleaseReport --no-daemon --console=plain
)

ANDROID_JSON="apps/mobile/build/app/reports/licenses/licenseReleaseReport.full.json"
if [[ ! -f "$ANDROID_JSON" ]]; then
  echo "Gradle full license JSON was not produced at $ANDROID_JSON." >&2
  find apps/mobile/build -iname '*license*' -o -iname '*open_source*' | head -n 50 >&2 || true
  exit 1
fi
echo "gradle report: $ANDROID_JSON"

MATERIAL_LICENSE="$FLUTTER_ROOT/bin/cache/artifacts/material_fonts/MaterialIcons_LICENSE.txt"
if [[ ! -f "$MATERIAL_LICENSE" ]]; then
  echo "Material Icons license is missing at $MATERIAL_LICENSE." >&2
  echo "Run 'flutter precache' so the material_fonts artifact is present." >&2
  exit 1
fi

python3 tools/license/render_notices.py \
  "$ROOT" "$WORK/about.json" "$ANDROID_JSON" "$FLUTTER_ROOT/LICENSE" \
  "$MATERIAL_LICENSE"
