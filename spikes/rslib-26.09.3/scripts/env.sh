#!/usr/bin/env bash
# Shared environment for the 26.09.3 rslib spike. Source, do not execute.
SPIKE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export SPIKE_ROOT
export ANKI_SRC="${ANKI_SRC:-$SPIKE_ROOT/vendor/anki}"
export ANKI_COMMIT="29bb700b951e3f0c0cb69b77c0180fc1fe33e6ba"
export ANKI_TAG="26.09.3"
export PROTOC="${PROTOC:-/usr/bin/protoc}"
export PATH="/usr/local/cargo/bin:${PATH}"
export RUSTUP_HOME="${RUSTUP_HOME:-/usr/local/rustup}"
export CARGO_HOME="${CARGO_HOME:-/usr/local/cargo}"
export CARGO_BUILD_JOBS="${CARGO_BUILD_JOBS:-4}"
# Third-party builds must not reuse a stale descriptor path from the shell.
unset DESCRIPTORS_BIN
unset STRINGS_PY
unset STRINGS_TS
unset STRINGS_JSON
