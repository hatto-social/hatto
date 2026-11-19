#!/usr/bin/env bash

# SPDX-FileCopyrightText: 2026 Hatto Social contributors
#
# SPDX-License-Identifier: AGPL-3.0-or-later

# Build hatto-<version>-source.tar.gz for a tag that points at HEAD.
# The archive includes third_party/anki and its nested submodules
# (ftl/core-repo, ftl/qt-repo, and the installer templates). It does not
# vendor crates or Dart packages. GitHub's automatic source zip omits
# submodule contents, so a release attaches this archive instead.
#
# Two runs from the same commit, tools, and lockfiles produce the same
# sha256. The checksum file is next to the archive, not inside it.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=require_release_tree.sh
source "$ROOT/tools/release/require_release_tree.sh"

export LC_ALL=C

TAG="${1:-${HATTO_RELEASE_TAG:-}}"
require_release_tree "$ROOT" "$TAG"
VER="$(release_version_from_tag "$TAG")"

echo "checking out submodules"
git -C "$ROOT" submodule update --init --recursive
require_release_tree "$ROOT" "$TAG"

DIST="$ROOT/dist"
STAGE="$DIST/stage"
NAME="hatto-${VER}"
rm -rf "$STAGE"
mkdir -p "$STAGE"

python3 "$ROOT/tools/release/stage_source_tree.py" \
  --root "$ROOT" \
  --dest "$STAGE/$NAME" \
  --tag "$TAG" \
  --version "$VER" \
  --sha "$RELEASE_SHA"

EPOCH="$(git -C "$ROOT" log -1 --format=%ct)"
ARCHIVE="$DIST/${NAME}-source.tar.gz"
mkdir -p "$DIST"
tar -C "$STAGE" \
  --sort=name \
  --mtime="@${EPOCH}" \
  --owner=0 \
  --group=0 \
  --numeric-owner \
  --format=gnu \
  -cf - "$NAME" | gzip -n >"${ARCHIVE}.tmp"
mv "${ARCHIVE}.tmp" "$ARCHIVE"

(
  cd "$DIST"
  files=("${NAME}-source.tar.gz")
  if [[ -f "${NAME}-android.apk" ]]; then
    files+=("${NAME}-android.apk")
  fi
  sha256sum "${files[@]}" >SHA256SUMS
)
rm -rf "$STAGE"

echo "wrote $ARCHIVE"
sha256sum "$ARCHIVE"
