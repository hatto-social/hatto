#!/usr/bin/env bash

# SPDX-FileCopyrightText: 2026 Hatto Social contributors
#
# SPDX-License-Identifier: AGPL-3.0-or-later

# The only path for a release APK. Refuses to build unless the tag is
# non-empty, the tag points at HEAD, and the work tree is clean.
# Injects HATTO_RELEASE_TAG and HATTO_GIT_SHA. Does not change signing.
#
# HATTO_RELEASE_CHECK_ONLY=1 stops after the checks. The guard test uses that.
# A rebuild from the source tarball has no git metadata; that path is
# tools/release/rebuild-from-archive.sh, not this script.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=require_release_tree.sh
source "$ROOT/tools/release/require_release_tree.sh"

TAG="${1:-${HATTO_RELEASE_TAG:-}}"
require_release_tree "$ROOT" "$TAG"
VER="$(release_version_from_tag "$TAG")"

if [[ "${HATTO_RELEASE_CHECK_ONLY:-}" == 1 ]]; then
  echo "release tree ok ${TAG} ${RELEASE_SHA}"
  exit 0
fi

echo "building release APK for ${TAG} (${RELEASE_SHA})"
(
  cd "$ROOT/apps/mobile"
  flutter build apk --release \
    --dart-define="HATTO_RELEASE_TAG=${TAG}" \
    --dart-define="HATTO_GIT_SHA=${RELEASE_SHA}"
)

APK_SRC="$ROOT/apps/mobile/build/app/outputs/flutter-apk/app-release.apk"
if [[ ! -f "$APK_SRC" ]]; then
  echo "flutter build apk did not write $APK_SRC" >&2
  exit 1
fi

mkdir -p "$ROOT/dist"
APK_NAME="hatto-${VER}-android.apk"
cp "$APK_SRC" "$ROOT/dist/$APK_NAME"

# Checksums cover the APK and, when the source archive is already in dist/,
# that archive too. make-source-archive.sh writes the archive line first.
(
  cd "$ROOT/dist"
  files=()
  if [[ -f "hatto-${VER}-source.tar.gz" ]]; then
    files+=("hatto-${VER}-source.tar.gz")
  fi
  files+=("$APK_NAME")
  sha256sum "${files[@]}" > SHA256SUMS
)

echo "wrote $ROOT/dist/$APK_NAME"
