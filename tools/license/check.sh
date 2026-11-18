#!/usr/bin/env bash

# SPDX-FileCopyrightText: 2026 Hatto Social contributors
#
# SPDX-License-Identifier: AGPL-3.0-or-later

# License check: REUSE lint, then byte identity of the two AGPL copies.
#
# Install once. reuse 6.3.0 raises NoEncodingModuleError unless
# charset-normalizer is present:
#
#   pipx install 'reuse==6.3.0'
#   pipx inject reuse charset-normalizer
#
# `reuse lint` skips Git submodules by default. Do not pass
# --include-submodules. third_party/anki is unmodified Anki and is not
# declared in this repository's REUSE.toml.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

if ! command -v reuse >/dev/null 2>&1; then
  echo "reuse is not on PATH." >&2
  echo "Install: pipx install 'reuse==6.3.0' && pipx inject reuse charset-normalizer" >&2
  exit 1
fi

reuse lint

if ! cmp -s LICENSE LICENSES/AGPL-3.0-or-later.txt; then
  echo "LICENSE and LICENSES/AGPL-3.0-or-later.txt are not byte-identical." >&2
  exit 1
fi
