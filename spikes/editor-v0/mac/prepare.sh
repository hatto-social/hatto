#!/bin/bash
# Run on the Mac inside the extracted editor-spikes/ folder. Adds macOS runners to the spike projects. No signing settings are touched.
# NOT executed on a Mac by Dmitry (no macOS available) - if a step fails, send the error text back.
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
# Bundle copies this script to the spike root. In the repo it lives in mac/.
if [[ -d "$HERE/e" ]]; then ROOT="$HERE"; else ROOT="$(cd "$HERE/.." && pwd)"; fi
nosandbox() { # $1 = project dir : turn the sandbox off so the probe can write /tmp and read arbitrary clipboard files
  for f in "$1"/macos/Runner/DebugProfile.entitlements "$1"/macos/Runner/Release.entitlements; do
    /usr/libexec/PlistBuddy -c "Set :com.apple.security.app-sandbox false" "$f" 2>/dev/null || /usr/libexec/PlistBuddy -c "Add :com.apple.security.app-sandbox bool false" "$f"
  done
}
for v in v1_rslib v2_super v3_control; do
  ( cd "$ROOT/e/$v" && flutter create --platforms=macos --project-name e_app . >/dev/null && nosandbox . )
done
for v in v1_rslib v2_super; do # allow macOS targets in the pinned toolchain
  sed -i '' 's#^targets = .*#targets = ["x86_64-unknown-linux-gnu", "aarch64-apple-darwin", "x86_64-apple-darwin"]#' "$ROOT/e/$v/rust/rust-toolchain.toml"
done
( cd "$ROOT/b/proto" && flutter create --platforms=macos --project-name editor_proto . >/dev/null && nosandbox . )
( cd "$ROOT/m4a/rec_mac" && flutter create --platforms=macos --project-name rec_mac . >/dev/null && nosandbox .
  /usr/libexec/PlistBuddy -c "Add :NSMicrophoneUsageDescription string spike recording test" macos/Runner/Info.plist 2>/dev/null || true
  for f in macos/Runner/DebugProfile.entitlements macos/Runner/Release.entitlements; do /usr/libexec/PlistBuddy -c "Add :com.apple.security.device.audio-input bool true" "$f" 2>/dev/null || true; done )
( cd "$ROOT/c/web_mac" && flutter create --platforms=macos --project-name web_mac . >/dev/null && nosandbox . )
echo "prepare done"
