#!/usr/bin/env bash

# SPDX-FileCopyrightText: 2026 Hatto Social contributors
#
# SPDX-License-Identifier: AGPL-3.0-or-later

# Shared checks for a release build from a git checkout.
# Source this file. It does not run anything on its own.

# Prints the archive/APK version for a tag. A leading "v" before a digit
# is dropped so tag v1.2.3 and the file hatto-1.2.3-* name the same version.
release_version_from_tag() {
  local tag="$1"
  if [[ "$tag" =~ ^v[0-9] ]]; then
    printf '%s\n' "${tag#v}"
  else
    printf '%s\n' "$tag"
  fi
}

# Exits 2, 3, or 4 when the checkout must not be built.
# Sets RELEASE_SHA to HEAD on success.
require_release_tree() {
  local root="$1"
  local tag="$2"

  if [[ -z "$tag" ]]; then
    echo "release tag is empty" >&2
    exit 2
  fi
  if [[ ! "$tag" =~ ^[A-Za-z0-9._+-]+$ ]]; then
    echo "release tag contains characters this script does not accept: $tag" >&2
    exit 2
  fi

  local head tag_commit
  head="$(git -C "$root" rev-parse HEAD)"
  if ! tag_commit="$(git -C "$root" rev-parse --verify "${tag}^{commit}" 2>/dev/null)"; then
    echo "tag ${tag} does not point at HEAD (${head})" >&2
    exit 3
  fi
  if [[ "$tag_commit" != "$head" ]]; then
    echo "tag ${tag} does not point at HEAD (${head}); tag is ${tag_commit}" >&2
    exit 3
  fi

  local dirty
  dirty="$(git -C "$root" status --porcelain=v1 --untracked-files=all)"
  if [[ -n "$dirty" ]]; then
    echo "working tree is dirty" >&2
    exit 4
  fi

  RELEASE_SHA="$head"
}
