#!/usr/bin/env bash
# Fetch unmodified ankitects/anki tag 26.09.3 into spikes/editor-v0/vendor/anki.
# The tree is gitignored. rslib sources are not patched.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ANKI_SRC="${ANKI_SRC:-$ROOT/vendor/anki}"
ANKI_TAG="26.09.3"
ANKI_COMMIT="29bb700b951e3f0c0cb69b77c0180fc1fe33e6ba"

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
