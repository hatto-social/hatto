#!/usr/bin/env bash

# SPDX-FileCopyrightText: 2026 Hatto Social contributors
#
# SPDX-License-Identifier: AGPL-3.0-or-later

# build-android.sh must fail for an empty tag, a tag that is not HEAD,
# and a dirty work tree. Temporary tags stay local and are deleted.
# They are not release tags and are not pushed.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BUILD="$ROOT/tools/release/build-android.sh"
NOT_HEAD_TAG="hatto-release-guard-not-head"
HEAD_TAG="hatto-release-guard-head"
DIRT="hatto-release-guard-dirty.txt"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

cleanup() {
  git -C "$ROOT" tag -d "$NOT_HEAD_TAG" >/dev/null 2>&1 || true
  git -C "$ROOT" tag -d "$HEAD_TAG" >/dev/null 2>&1 || true
  rm -f "$ROOT/$DIRT"
}
trap cleanup EXIT

echo "== empty tag =="
set +e
empty_out="$(env -u HATTO_RELEASE_TAG "$BUILD" 2>&1)"
empty_code=$?
set -e
if [[ "$empty_code" -eq 0 ]]; then
  fail "empty tag exited 0"
fi
if ! grep -q "release tag is empty" <<<"$empty_out"; then
  fail "empty tag message: $empty_out"
fi

echo "== tag not at HEAD =="
# commit-tree needs an identity. Runners that have not set user.email
# would otherwise fail before the guard under test runs. This object is
# not a branch commit and is not pushed.
other="$(
  GIT_AUTHOR_NAME="Hatto Release Guard" \
    GIT_AUTHOR_EMAIL="hatto-release-guard@example.com" \
    GIT_COMMITTER_NAME="Hatto Release Guard" \
    GIT_COMMITTER_EMAIL="hatto-release-guard@example.com" \
    git -C "$ROOT" commit-tree "HEAD^{tree}" -m "hatto release guard test"
)"
git -C "$ROOT" tag "$NOT_HEAD_TAG" "$other"
set +e
miss_out="$(env -u HATTO_RELEASE_TAG "$BUILD" "$NOT_HEAD_TAG" 2>&1)"
miss_code=$?
set -e
git -C "$ROOT" tag -d "$NOT_HEAD_TAG" >/dev/null
if [[ "$miss_code" -eq 0 ]]; then
  fail "tag not at HEAD exited 0"
fi
if ! grep -q "does not point at HEAD" <<<"$miss_out"; then
  fail "tag not at HEAD message: $miss_out"
fi

echo "== dirty tree =="
git -C "$ROOT" tag "$HEAD_TAG" HEAD
printf 'dirt\n' >"$ROOT/$DIRT"
set +e
dirty_out="$(env -u HATTO_RELEASE_TAG "$BUILD" "$HEAD_TAG" 2>&1)"
dirty_code=$?
set -e
rm -f "$ROOT/$DIRT"
git -C "$ROOT" tag -d "$HEAD_TAG" >/dev/null
if [[ "$dirty_code" -eq 0 ]]; then
  fail "dirty tree exited 0"
fi
if ! grep -q "working tree is dirty" <<<"$dirty_out"; then
  fail "dirty tree message: $dirty_out"
fi

if [[ -z "$(git -C "$ROOT" status --porcelain=v1 --untracked-files=all)" ]]; then
  echo "== clean tree, check only =="
  git -C "$ROOT" tag "$HEAD_TAG" HEAD
  HATTO_RELEASE_CHECK_ONLY=1 env -u HATTO_RELEASE_TAG "$BUILD" "$HEAD_TAG"
  git -C "$ROOT" tag -d "$HEAD_TAG" >/dev/null
fi

echo "build-android guards ok"
