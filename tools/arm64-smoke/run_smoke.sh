#!/usr/bin/env bash
# One-shot ARM64 device smoke for the Hatto app.
#
# Build first, from the repo root, with NDK r29 (29.0.14206865):
#
#   export ANDROID_HOME="${ANDROID_HOME:-$HOME/sdk/android}"
#   export ANDROID_NDK_HOME="$ANDROID_HOME/ndk/29.0.14206865"
#   # Stage A uses the spike cdylib. Do not commit vendor/anki.
#   ( cd spikes/rslib-26.09.3 && scripts/fetch-anki.sh && scripts/build-android.sh arm64-v8a )
#   # Stage B–D uses librslib_bridge.so. `flutter test` builds it with the
#   # same NDK through packages/rslib_bridge/hook/build.dart. Rust 1.97.1 comes
#   # from rust-toolchain.toml. Also: rustup target add aarch64-linux-android,
#   # protoc 31.1, Flutter 3.47.x.
#
# Then, with the phone in USB debugging (arm64-v8a, not an emulator):
#
#   adb devices
#   tools/arm64-smoke/run_smoke.sh
#   # optional: SERIAL=<adb serial> PKG=social.hatto.hatto_mobile
#
# Pass criteria are in judge.py. Revlog total is recorded and not judged.
# The judged revlog count is rows whose cid is still in cards. Orphan revlog
# dropped by apkg export is an accepted loss (collection_nomedia_new.colpkg
# goes from 88 total rows to 1; the carded count stays 1). FSRS is judged on
# fsrs-synthetic-37k.apkg only (fsrs_items=33312, 21 finite params, two runs
# on the same device identical). palace.colpkg is not an FSRS case.
#
# fsrs_items counts reviews by the device's local Anki day (4:00 rollover).
# expected.json was produced in UTC+9: the same calls on a UTC host returned
# 33109, and TZ=Asia/Seoul returned 33312 with parameters that round to the
# host list. Set the phone to Korea time before running, or a mismatch is the
# day boundary, not an arm64/x86 numeric difference.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
MOBILE="$ROOT/apps/mobile"
SPIKE="$ROOT/spikes/rslib-26.09.3"
export ANDROID_HOME="${ANDROID_HOME:-$HOME/sdk/android}"
if [[ -z "${ANDROID_NDK_HOME:-}" && -d "$ANDROID_HOME/ndk/29.0.14206865" ]]; then
  export ANDROID_NDK_HOME="$ANDROID_HOME/ndk/29.0.14206865"
fi
if [[ -z "${PKG:-}" ]]; then
  PKG=$(grep -E 'applicationId[[:space:]]*=' "$MOBILE/android/app/build.gradle.kts" | head -1 | sed -E 's/.*"([^"]+)".*/\1/')
fi
if [[ -z "$PKG" ]]; then
  echo "PKG(applicationId) missing. Set PKG or check $MOBILE/android/app/build.gradle.kts" >&2
  exit 2
fi

ADB=(adb)
if [[ -n "${SERIAL:-}" ]]; then
  ADB+=(-s "$SERIAL")
fi

OUT="$HERE/run-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$OUT"
LOG="$OUT/smoke.log"

"${ADB[@]}" get-state >/dev/null
ABI=$("${ADB[@]}" shell getprop ro.product.cpu.abi | tr -d '\r')
SDK=$("${ADB[@]}" shell getprop ro.build.version.sdk | tr -d '\r')
MODEL=$("${ADB[@]}" shell getprop ro.product.model | tr -d '\r')
PAGE=$("${ADB[@]}" shell getconf PAGE_SIZE | tr -d '\r')
EMU=$("${ADB[@]}" shell getprop ro.kernel.qemu | tr -d '\r')
if [[ "$EMU" != "1" ]]; then
  EMU=0
fi
echo "HATTO_SMOKE env abi=$ABI sdk=$SDK page=$PAGE model=\"$MODEL\" emulator=$EMU" | tee "$LOG"
( cd "$HERE/files" && sha256sum -c SHA256SUMS ) | tee -a "$OUT/files-check.txt"

SERIAL_NOW="${SERIAL:-$("${ADB[@]}" get-serialno | tr -d '\r')}"

# A. Unchanged spike roundtrip. Its log must contain FRB_DEVICE_OK and
# "All tests passed!" or judge.py fails the run. A missing .so does not
# skip B–D; the failure stays in the log.
if [[ -f "$SPIKE/mobile/integration_test/roundtrip_test.dart" ]]; then
  (
    cd "$SPIKE/mobile"
    flutter pub get
    timeout 1800 flutter test integration_test/roundtrip_test.dart -d "$SERIAL_NOW"
  ) 2>&1 | tee -a "$LOG" || true
else
  echo "HATTO_SMOKE_FAIL roundtrip_test.dart missing (A stage)" | tee -a "$LOG"
fi

# B–D. Install the product app so run-as can see its files dir, copy the
# fixtures in, then run the integration test. `flutter test` reinstalls with
# adb install -r, which keeps the copied files.
(
  cd "$MOBILE"
  flutter pub get
  flutter install -d "$SERIAL_NOW"
)
"${ADB[@]}" shell rm -rf /data/local/tmp/hatto-smoke
"${ADB[@]}" push "$HERE/files" /data/local/tmp/hatto-smoke >/dev/null
"${ADB[@]}" shell "run-as $PKG sh -c 'rm -rf files/smoke && mkdir -p files/smoke && cp /data/local/tmp/hatto-smoke/* files/smoke/'"
SMOKE_DIR="/data/user/0/$PKG/files/smoke"
if [[ -f "$MOBILE/integration_test/arm64_smoke_test.dart" ]]; then
  (
    cd "$MOBILE"
    timeout 3600 flutter test integration_test/arm64_smoke_test.dart -d "$SERIAL_NOW" \
      --dart-define=SMOKE_DIR="$SMOKE_DIR"
  ) 2>&1 | tee -a "$LOG" || true
else
  echo "HATTO_SMOKE_FAIL arm64_smoke_test.dart missing (B/C/D)" | tee -a "$LOG"
fi

"${ADB[@]}" logcat -d -b all >"$OUT/logcat.txt" || true
"${ADB[@]}" shell getprop >"$OUT/getprop.txt" || true
python3 "$HERE/judge.py" "$LOG" "$HERE/expected.json" | tee "$OUT/judge.txt"
echo "결과 폴더: $OUT"
