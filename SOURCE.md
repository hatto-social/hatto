# Building Hatto from the source bundle

This is the rebuild procedure for `hatto-<version>-source.tar.gz`.

The bundle is this repository at one tag, including `third_party/anki` at
`29bb700b951e3f0c0cb69b77c0180fc1fe33e6ba` and the nested checkouts that tag
records (`ftl/core-repo`, `ftl/qt-repo`, and the Qt installer templates).
It does not contain a `.git` directory. Do not clone `hatto-social/hatto` or
`ankitects/anki` to fill the tree in. Those checkouts are already in the
bundle.

Rust crates and Dart/Flutter packages are not in the bundle. `cargo` and
`flutter` fetch them from crates.io and pub.dev using the versions and
hashes in `Cargo.lock` and `pubspec.lock`. There is no mirror of those
registries.

A release bundle's `BUILD_INFO.txt` is the copy `tools/release/build-android.sh`
wrote next to the APK, from the environment that built it. It records rustc,
cargo, Flutter (framework version and engine hash), the NDK revision, protoc,
the submodule commits, and the URL and sha256 of each prebuilt SQLite library
the Dart `sqlite3` hook downloads. `build_info_mode: release` is that record.
A CI determinism archive can instead contain `build_info_mode: determinism`
and toolchain lines that start with `placeholder:`. Those lines are not
versions. rslib's own SQLite is the copy bundled inside the `rusqlite` crate
from crates.io. The tag and the commit in either file are still the version
this tree was packed from.

Bit-identical rebuilds are not required. The same commands must produce a
working `librslib_bridge.so` and an Android APK.

## Tools

| Tool | Version |
| --- | --- |
| Rust | 1.97.1 (`rust-toolchain.toml`, same as Anki 26.09.3). Targets: `x86_64-unknown-linux-gnu`, `aarch64-linux-android`, `armv7-linux-androideabi`, `x86_64-linux-android`, `aarch64-apple-darwin`, `x86_64-apple-darwin`. |
| protoc | 31.1, on `PATH` as `protoc`. `.cargo/config.toml` sets `PROTOC=protoc`. |
| Flutter | 3.47.9 (Dart 3.13.7). |
| Android SDK | `platforms;android-36`, `build-tools;36.0.0`. |
| Android NDK | Flutter 3.47.9 requests `28.2.13676358` (`flutter.ndkVersion` in the Flutter SDK). `apps/mobile/android/app/build.gradle.kts` uses that value. |
| JDK | 17 or newer. The Gradle wrapper is 9.3.1. |
| C toolchain | A host C compiler, `pkg-config`, and `cmake` for crate build scripts. |

`tools/release/build-android.sh` is the maintainer path from a git checkout.
It refuses to run in this bundle because there is no `.git` directory, and
it is what writes the release `dist/BUILD_INFO.txt`. Use the commands below,
or `tools/release/rebuild-from-archive.sh`, which runs them and then writes
a release `BUILD_INFO.txt` for the toolchain that just compiled. The tag and
the commit come from the archive's `BUILD_INFO.txt`. Submodule commits are
copied from that file because this tree has no `.git` directory.

## Unpack

```sh
tar -xzf hatto-<version>-source.tar.gz
cd hatto-<version>
test ! -e .git
test -f third_party/anki/rslib/Cargo.toml
test -d third_party/anki/ftl/core-repo
test -d third_party/anki/ftl/qt-repo
```

## Host bridge library

From the unpacked directory, with `protoc` 31.1 on `PATH`:

```sh
cargo build --release --locked -p rslib_bridge
```

Expected output: `target/release/librslib_bridge.so`.

## Android APK

Set `ANDROID_HOME` to the SDK and install the NDK version above into that
SDK. Accept the SDK licenses. Then, from the unpacked directory:

```sh
tag=$(awk -F': ' '$1 == "hatto_release_tag" { print $2; exit }' BUILD_INFO.txt)
sha=$(awk -F': ' '$1 == "hatto_git_sha" { print $2; exit }' BUILD_INFO.txt)
flutter pub get
cd apps/mobile
flutter build apk --release \
  --dart-define="HATTO_RELEASE_TAG=${tag}" \
  --dart-define="HATTO_GIT_SHA=${sha}"
```

Expected output: `build/app/outputs/flutter-apk/app-release.apk`.

The APK's native library is `librslib_bridge.so` for `armeabi-v7a`,
`arm64-v8a`, and `x86_64`. The Dart `sqlite3` hook downloads the three
Android libraries named in `BUILD_INFO.txt` and checks their sha256. Signing
is whatever `apps/mobile/android/app/build.gradle.kts` already says. This
procedure does not change it. As of this tree, release builds still use the
debug key. See `docs/release/CHECKLIST.md` before handing an APK to anyone.

`tools/release/rebuild-from-archive.sh` runs the host build and then this
APK build. It exits if `.git` is present.
