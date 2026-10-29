#!/usr/bin/env bash
# Fetch ankitects/anki tag 26.09.3 and the two FTL submodules pinned by that commit.
# Does not modify rslib sources. The tree is gitignored.
set -euo pipefail
source "$(dirname "$0")/env.sh"

if [[ ! -d "$ANKI_SRC/.git" ]]; then
  mkdir -p "$(dirname "$ANKI_SRC")"
  git clone --depth 1 --branch "$ANKI_TAG" https://github.com/ankitects/anki.git "$ANKI_SRC"
fi

cd "$ANKI_SRC"
head="$(git rev-parse HEAD)"
if [[ "$head" != "$ANKI_COMMIT" ]]; then
  echo "expected $ANKI_TAG at $ANKI_COMMIT, got $head" >&2
  exit 1
fi
version="$(tr -d '[:space:]' < .version)"
if [[ "$version" != "$ANKI_TAG" ]]; then
  echo ".version is '$version', expected $ANKI_TAG" >&2
  exit 1
fi

git submodule update --init --depth 1 ftl/core-repo ftl/qt-repo
echo "anki $ANKI_TAG $head"
echo "ftl/core-repo $(git -C ftl/core-repo rev-parse HEAD)"
echo "ftl/qt-repo $(git -C ftl/qt-repo rev-parse HEAD)"
echo "rslib diff (should be empty):"
git diff --stat -- rslib proto Cargo.toml Cargo.lock || true
git status --short -- rslib proto | head
