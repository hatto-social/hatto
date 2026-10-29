# rslib 26.09.3 protobuf spike

판정과 숫자는 [`docs/spikes/rslib-26.09.3.md`](../../docs/spikes/rslib-26.09.3.md)에 있다.

```bash
scripts/fetch-anki.sh
scripts/build-napi.sh release
scripts/test-napi.sh
scripts/build-frb-host.sh
scripts/test-dart-host.sh
scripts/build-android.sh arm64-v8a
scripts/build-android.sh x86_64
```

Anki 체크아웃은 `vendor/anki`(gitignore)에만 둔다. 핀은 태그 `26.09.3`, 커밋 `29bb700b951e3f0c0cb69b77c0180fc1fe33e6ba`.
