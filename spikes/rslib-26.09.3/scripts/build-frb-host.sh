#!/usr/bin/env bash
# Host cdylib used by `flutter test`. Does not use CargoKit.
set -euo pipefail
source "$(dirname "$0")/env.sh"
cd "$SPIKE_ROOT"
start=$(date +%s)
cargo build -p hatto_rslib_frb --release
end=$(date +%s)
so="$SPIKE_ROOT/target/release/libhatto_rslib_frb.so"
mkdir -p "$SPIKE_ROOT/results"
python3 - "$so" "$((end - start))" "$SPIKE_ROOT/results/frb-host-build.json" << 'PY'
import json, pathlib, subprocess, sys
so, elapsed, out = sys.argv[1:]
so = pathlib.Path(so)
stripped = pathlib.Path(out).with_suffix(".stripped.so")
subprocess.check_call(["strip", "--strip-unneeded", "-o", str(stripped), str(so)])
ldd = subprocess.check_output(["ldd", str(so)], text=True).strip().splitlines()
payload = {
    "elapsed_sec": int(elapsed),
    "so_bytes": so.stat().st_size,
    "stripped_bytes": stripped.stat().st_size,
    "ldd": ldd,
}
pathlib.Path(out).write_text(json.dumps(payload, indent=2) + "\n")
print(json.dumps(payload, indent=2))
PY
