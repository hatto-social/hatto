#!/usr/bin/env bash
# Cross-compile the FRB cdylib for Android. One ABI per invocation: arm64-v8a or x86_64.
set -euo pipefail
source "$(dirname "$0")/env.sh"
abi="${1:?abi arm64-v8a or x86_64}"
case "$abi" in
  arm64-v8a) target=aarch64-linux-android ;;
  x86_64) target=x86_64-linux-android ;;
  *) echo "unsupported abi $abi" >&2; exit 2 ;;
esac

export ANDROID_HOME="${ANDROID_HOME:-$HOME/sdk/android}"
export ANDROID_NDK_HOME="${ANDROID_NDK_HOME:-$ANDROID_HOME/ndk/29.0.14206865}"
export PATH="/usr/local/cargo/bin:$PATH"
# 16KB page alignment required by Android 15+ for 64-bit ELF.
export RUSTFLAGS="${RUSTFLAGS:-} -C link-arg=-Wl,-z,max-page-size=16384"
rustup target add "$target" >/dev/null

jni="$SPIKE_ROOT/mobile/android/app/src/main/jniLibs/$abi"
mkdir -p "$jni" "$SPIKE_ROOT/results"
start=$(date +%s)
cd "$SPIKE_ROOT"
cargo ndk -t "$abi" --platform 24 -o "$SPIKE_ROOT/mobile/android/app/src/main/jniLibs" \
  build --release -p hatto_rslib_frb
end=$(date +%s)
so="$jni/libhatto_rslib_frb.so"
if [[ ! -f "$so" ]]; then
  echo "missing $so" >&2
  find "$SPIKE_ROOT/mobile/android/app/src/main/jniLibs" -name '*.so' -print >&2 || true
  exit 1
fi
python3 - "$so" "$abi" "$target" "$((end - start))" "$SPIKE_ROOT/results/android-$abi.json" << 'PY'
import json, pathlib, subprocess, sys
so, abi, target, elapsed, out = sys.argv[1:]
so = pathlib.Path(so)
text = subprocess.check_output(["readelf", "-l", str(so)], text=True)
lines = text.splitlines()
aligns = []
for index, line in enumerate(lines):
    if line.strip().startswith("LOAD") and index + 1 < len(lines):
        # GNU readelf splits each program header across two lines; Align is last on the second.
        aligns.append(lines[index + 1].split()[-1])
needed = subprocess.check_output(["readelf", "-d", str(so)], text=True)
needed = [line.strip() for line in needed.splitlines() if "NEEDED" in line]
payload = {
    "abi": abi,
    "target": target,
    "elapsed_sec": int(elapsed),
    "so_bytes": so.stat().st_size,
    "load_align": aligns,
    "needed": needed,
    "page_16k": all(int(a, 16) >= 0x4000 for a in aligns) if aligns else False,
}
pathlib.Path(out).write_text(json.dumps(payload, indent=2) + "\n")
print(json.dumps(payload, indent=2))
PY
