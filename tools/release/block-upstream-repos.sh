#!/usr/bin/env bash

# SPDX-FileCopyrightText: 2026 Hatto Social contributors
#
# SPDX-License-Identifier: AGPL-3.0-or-later

# Refuse git access to the hatto and anki GitHub repositories.
# Package registries and other GitHub hosts stay reachable. The sqlite3
# hook downloads from github.com/simolus3/sqlite3.dart, which is not blocked.
# CI runs this in the unpacked archive before the rebuild.

set -euo pipefail

block() {
  local prefix="$1"
  # --add: one url.<base>.insteadOf key holds every prefix. A plain
  # `git config` would keep only the last prefix.
  git config --global --add url."https://invalid.example/blocked/".insteadOf "$prefix"
}

block "https://github.com/hatto-social/hatto"
block "https://github.com/ankitects/anki"
block "ssh://git@github.com/hatto-social/hatto"
block "ssh://git@github.com/ankitects/anki"
block "git@github.com:hatto-social/hatto"
block "git@github.com:ankitects/anki"

refuse() {
  local url="$1"
  if git ls-remote "$url" HEAD >/dev/null 2>&1; then
    echo "git remote was reachable after the block: $url" >&2
    exit 1
  fi
}

refuse "https://github.com/hatto-social/hatto.git"
refuse "https://github.com/ankitects/anki.git"
echo "blocked git access to hatto and anki"
