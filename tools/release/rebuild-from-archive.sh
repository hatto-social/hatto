#!/usr/bin/env bash

# SPDX-FileCopyrightText: 2026 Hatto Social contributors
#
# SPDX-License-Identifier: AGPL-3.0-or-later

# Rebuild from an unpacked source archive. The archive has no .git.
# A git checkout uses tools/release/build-android.sh, which checks the tag.
#
# HATTO_REBUILD_DROP_HOST_TARGET=1 deletes the host target/ directory after
# librslib_bridge.so has been built, before the Android build. CI sets it
# so the two compiles do not share one runner disk. The commands are the
# same either way.
#
# The procedure is SOURCE.md. This script is that procedure.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

if [[ -e .git || -e third_party/anki/.git ]]; then
  echo "This script rebuilds an unpacked source archive. A git checkout uses tools/release/build-android.sh." >&2
  exit 1
fi
if [[ ! -f BUILD_INFO.txt ]]; then
  echo "BUILD_INFO.txt is missing. Unpack hatto-<version>-source.tar.gz and run this there." >&2
  exit 1
fi
if [[ ! -f third_party/anki/rslib/Cargo.toml ]]; then
  echo "third_party/anki/rslib is missing from this tree." >&2
  exit 1
fi
if [[ ! -d third_party/anki/ftl/core-repo || ! -d third_party/anki/ftl/qt-repo ]]; then
  echo "Anki ftl translation checkouts are missing." >&2
  exit 1
fi

TAG="$(awk -F': ' '$1 == "hatto_release_tag" { print $2; exit }' BUILD_INFO.txt)"
SHA="$(awk -F': ' '$1 == "hatto_git_sha" { print $2; exit }' BUILD_INFO.txt)"
VER="$(awk -F': ' '$1 == "hatto_version" { print $2; exit }' BUILD_INFO.txt)"
if [[ -z "$TAG" || -z "$SHA" || -z "$VER" ]]; then
  echo "BUILD_INFO.txt has no hatto_release_tag, hatto_git_sha, or hatto_version." >&2
  exit 1
fi
# Submodule commits are recorded in the archive. This tree has no .git.
cp BUILD_INFO.txt /tmp/hatto-archive-build-info.txt

echo "host bridge library for ${TAG} (${SHA})"
cargo build --release --locked -p rslib_bridge
if [[ ! -f target/release/librslib_bridge.so ]]; then
  echo "cargo did not write target/release/librslib_bridge.so" >&2
  exit 1
fi

if [[ "${HATTO_REBUILD_DROP_HOST_TARGET:-}" == 1 ]]; then
  echo "removing host target/ after the library check"
  rm -rf target
fi

echo "android apk"
flutter pub get
(
  cd apps/mobile
  flutter build apk --release \
    --dart-define="HATTO_RELEASE_TAG=${TAG}" \
    --dart-define="HATTO_GIT_SHA=${SHA}"
)

APK="apps/mobile/build/app/outputs/flutter-apk/app-release.apk"
if [[ ! -f "$APK" ]]; then
  echo "flutter build apk did not write $APK" >&2
  exit 1
fi
echo "wrote $APK"

# Replace the archive's record with the toolchain that just built the binaries.
python3 "$ROOT/tools/release/stage_source_tree.py" \
  --root "$ROOT" \
  --write-only \
  --output "$ROOT/BUILD_INFO.txt" \
  --mode release \
  --tag "$TAG" \
  --version "$VER" \
  --sha "$SHA" \
  --inherit-submodules-from /tmp/hatto-archive-build-info.txt
echo "----- BUILD_INFO.txt -----"
cat "$ROOT/BUILD_INFO.txt"
echo "----- end BUILD_INFO.txt -----"
