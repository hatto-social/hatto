# Release checklist

Do this for every version that is handed to anyone, including one tester.
Creating the first real tag is a separate decision. This file is the order,
not that decision.

## Order

1. Tag the release commit. The tag must point at that commit. Do not move a tag that already shipped.
2. From a clean checkout of that tag, with Rust 1.97.1, protoc 31.1, Flutter 3.47.9, and the NDK on the machine (`ANDROID_NDK_HOME`, or exactly one NDK under `ANDROID_HOME/ndk`), run `tools/release/build-android.sh <tag>`. That is the only release APK path. It injects `HATTO_RELEASE_TAG` and `HATTO_GIT_SHA`, refuses an empty tag, a tag that is not HEAD, or a dirty tree, and writes `dist/BUILD_INFO.txt` from the toolchain that just built the APK. That file is the release record: rustc, cargo, Flutter including the engine hash, NDK, protoc, submodule commits, and the URL and sha256 of each sqlite3 native library the hook downloads.
3. Run `tools/release/make-source-archive.sh <tag>`. It copies `dist/BUILD_INFO.txt` into the archive. If that file is missing, the script probes the same tools and fails when one of them is missing. Do not pass `--determinism` for a release. That mode is only for the CI hash check, and its toolchain lines are labeled `placeholder:`.
4. Attach `dist/hatto-<version>-source.tar.gz`, `dist/hatto-<version>-android.apk`, `dist/BUILD_INFO.txt`, and `dist/SHA256SUMS` to the GitHub release for that tag. Do not rely on GitHub's automatic source zip. It leaves out submodule contents, including `third_party/anki` and the ftl checkouts.
5. Set the release body from `docs/release/RELEASE_BODY.md`. Replace `<version>`. The first line points at the source archive.

`<version>` is the tag with one leading `v` removed when the tag looks like `v1.2.3`.

## Shipped versions

Never delete the GitHub release, or the attached files, of a version that has shipped. The source archive is the corresponding source for that binary. If a file is wrong, ship a new version and leave the old release in place.

## Signing key

Not decided. `apps/mobile/android/app/build.gradle.kts` still signs release builds with the debug key. Do not hand someone a debug-signed APK as a finished release. Decide the signing key before the first binary goes out. The legal-notices work does not change that config.

## Store listings and desktop installers

The Play Store description and a desktop dmg README are not written here. When a channel is chosen, use the same source sentence as the first line of `docs/release/RELEASE_BODY.md`.

## When the desktop app lands

`apps/desktop` is not in this repository. The change that adds it is done only when all four of these are true:

1. The desktop About screen uses `LegalNoticesSection` from `packages/hatto_legal`.
2. `tools/license/gen-notices.sh` grows a macOS target so the desktop third-party notices are generated.
3. `tools/release/build-macos.sh` exists and refuses to build when the tag is empty, the tag does not point at HEAD, or the tree is dirty.
4. The dmg contains `LICENSE` and a README, and that README includes the source sentence from `docs/release/RELEASE_BODY.md`.

## What is not in the source archive

Rust crates and Dart/Flutter packages are fetched from their registries by `Cargo.lock` and `pubspec.lock`. They are not vendored. There is no mirror repository.
