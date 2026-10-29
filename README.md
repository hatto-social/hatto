# Hatto

Hatto Social v0 is a local-first Android app. There is no server in this version. Study data lives on the device: one resident [Anki](https://github.com/ankitects/anki) collection, plus a Hatto side database next to it.

The collection engine is Anki's Rust library **rslib**, pinned to **26.09.3** and not patched. The app talks to it only through rslib's protobuf backend (`init_backend` with a `BackendInit` message, then `Backend::run_service_method`). Service and method numbers are generated at build time from that tag's `.proto` files, because those numbers are not a stable ABI.

The app is AGPL-3.0-or-later, the same license as rslib, which it links statically. See `third_party/anki/LICENSE`.

## Layout

```
apps/mobile/                 Flutter app, Android only
packages/rslib_bridge/       flutter_rust_bridge crate and the generated Dart API
  rust/                      Cargo package `rslib_bridge`
  hook/build.dart            Native-assets hook (Flutter builds the Rust library)
  lib/src/rust/              Generated bindings. Do not edit.
packages/hatto_store/        Side SQLite, write wrapper, read-only SQL allowlist
third_party/anki/            Anki git submodule, tag 26.09.3, unmodified
```

Dart packages share one pub workspace (`pubspec.yaml` at the repo root). Rust has one Cargo workspace whose only member is the bridge. Anki stays a separate Cargo workspace; `Cargo.toml` excludes `third_party/anki` so the pin is consumed as a path dependency instead of being edited.

`packages/hatto_store` does not link rslib. Writes will go through one wrapper that records an intent in the side database, calls the bridge, then commits the journal row. The allowlist in front of rslib `RunDbCommand` is empty on purpose: the concrete read list is still open, and every statement is rejected until it is filled in. v0 features beyond opening a collection (import, scheduling, backup) are not implemented here.

## Prerequisites

| Tool | Pin used here |
| --- | --- |
| Rust | 1.97.1 (`rust-toolchain.toml`, same as Anki 26.09.3) |
| protoc | 31.1, on `PATH` as `protoc` |
| Flutter | 3.47.x / Dart 3.13.x (host smoke). Android builds also need the SDK and NDK. |

Anki's own build downloads protoc into `third_party/anki/out/`. This repo does not. Install protoc 31.1 and make sure `protoc` is the executable name Cargo sees (`.cargo/config.toml` sets `PROTOC=protoc`).

Fetch the pinned Anki tree and the translation checkouts its rslib build reads:

```sh
git submodule update --init --recursive
```

The submodule is Anki commit `29bb700b951e3f0c0cb69b77c0180fc1fe33e6ba` (tag `26.09.3`). Do not patch files under `third_party/anki`.

## Host build and smoke

From the repo root, with `protoc` and `flutter` on `PATH`:

```sh
tools/smoke-host.sh
```

That runs:

1. `cargo test -p rslib_bridge` — opens a new collection through `run_service_method`, checks the linked rslib version is 26.09.3, checks the Default deck is listed, and checks a second backend cannot open the same file (`DB_ERROR`, kind 5).
2. `dart test packages/hatto_store` — side database, intent/journal wrapper, SQL allowlist.
3. `flutter test` in `apps/mobile` — the same collection open, through the generated Dart bridge, plus a widget check that the home screen renders. The test process is Linux, so it loads `apps/mobile/build/native_assets/linux/librslib_bridge.so`. An Android build loads `librslib_bridge.so` from the APK by name instead.

`prepare_runtime` sets `TMPDIR` before rslib touches temp files. The smoke helper does that with a directory next to the collection. On Android the app does it with the cache directory before any other bridge call.

Regenerate the bridge after changing `packages/rslib_bridge/rust/src/api.rs`:

```sh
cd packages/rslib_bridge
flutter_rust_bridge_codegen generate   # version 2.13.0
```

Commit the generated Rust and Dart. The `frb_generated.web.dart` file is part of that output (the bridge package's conditional import). The app does not have a web target.

## Android

The Flutter project is created with `--platforms=android` only (`social.hatto.hatto_mobile`, minSdk 24, ABIs `armeabi-v7a`, `arm64-v8a`, `x86_64`). Native code is built by the Dart build hook in `packages/rslib_bridge/hook/build.dart`, which runs Cargo for the Android targets listed in `rust-toolchain.toml`.

Not verified in this workspace: the Android SDK/NDK are not installed, so `flutter build apk` and an emulator were not run. To build an APK locally:

1. Install Android SDK command-line tools and NDK r29 (AnkiDroid's rslib build uses NDK `29.0.14206865`).
2. Set `ANDROID_HOME` and `ANDROID_NDK_HOME`.
3. Accept SDK licenses.
4. From `apps/mobile`: `flutter build apk`.

`.cargo/config.toml` already passes `-Wl,-z,max-page-size=16384` for the Android Rust targets so the `.so` can load on 16KB-page devices. `prepare_runtime` must run before import/export, or rslib writes temp files under a directory the app cannot use.

## What this skeleton does not do

Import, scheduling, note editing, FSRS optimization, and backup/restore are specified for v0 and are not implemented yet. The side database has the tables those features need (guid maps, journal, `revlog_origin`, media keys, intents) and the write wrapper records intent then journal, but nothing calls rslib for those operations yet. Startup reconciliation of a pending intent is not implemented.
