#!/usr/bin/env bash
# Build the napi cdylib against the fetched Anki tree. Profile: release (default) or dev.
set -euo pipefail
source "$(dirname "$0")/env.sh"
profile="${1:-release}"
cd "$SPIKE_ROOT"
if [[ ! -d "$ANKI_SRC/rslib/src" ]]; then
  "$(dirname "$0")/fetch-anki.sh"
fi

start=$(date +%s)
if [[ "$profile" == "release" ]]; then
  cargo build -p hatto-rslib-napi --release
  so="$SPIKE_ROOT/target/release/libhatto_rslib_napi.so"
else
  cargo build -p hatto-rslib-napi
  so="$SPIKE_ROOT/target/debug/libhatto_rslib_napi.so"
fi
end=$(date +%s)
elapsed=$((end - start))

mkdir -p "$SPIKE_ROOT/napi/artifacts" "$SPIKE_ROOT/results"
cp "$so" "$SPIKE_ROOT/napi/artifacts/hatto_rslib_napi.linux-x64-gnu.node"
python3 "$SPIKE_ROOT/scripts/extract-service-ids.py" \
  --search "$SPIKE_ROOT" \
  --search "$ANKI_SRC" \
  --out "$SPIKE_ROOT/napi/service-ids.json" \
  --anki-commit "$ANKI_COMMIT"

python3 - "$profile" "$elapsed" "$so" "$SPIKE_ROOT" << 'PY'
import json, pathlib, subprocess, sys
profile, elapsed, so, spike = sys.argv[1:]
so = pathlib.Path(so)
node = pathlib.Path(spike) / "napi/artifacts/hatto_rslib_napi.linux-x64-gnu.node"
stripped = pathlib.Path(spike) / "results" / f"napi-{profile}.stripped.so"
subprocess.check_call(["strip", "--strip-unneeded", "-o", str(stripped), str(node)])
ldd = subprocess.check_output(["ldd", str(node)], text=True).strip().splitlines()
payload = {
    "profile": profile,
    "elapsed_sec": int(elapsed),
    "so_bytes": so.stat().st_size,
    "node_bytes": node.stat().st_size,
    "stripped_bytes": stripped.stat().st_size,
    "ldd": ldd,
}
out = pathlib.Path(spike) / "results" / f"napi-build-{profile}.json"
out.write_text(json.dumps(payload, indent=2) + "\n")
print(json.dumps(payload, indent=2))
PY

echo "rslib tracked diff:"
git -C "$ANKI_SRC" diff --stat -- rslib proto
git -C "$ANKI_SRC" status --short -- rslib proto | head
