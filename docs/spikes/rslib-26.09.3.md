# rslib 26.09.3 protobuf 통로 스파이크

검증일이다. 서버(napi-rs)와 Android(Flutter + flutter_rust_bridge)가 **수정하지 않은** Anki `rslib`를 protobuf 바이트 통로(`Backend::run_service_method`)로만 부를 수 있는지를, 릴리스 **26.09.3** 소스로 다시 실행했다. 웹 WASM, 공유 diff crate, 동기화·병합, iOS는 하지 않았다.

표기: **[실행]** 이 환경에서 명령이 끝나 결과를 확인함. **[코드]** 소스를 읽고 확인함. **[추정]** 실행하지 않음.

재현 명령은 아래 [재현](#재현)에 있다. 숫자는 `spikes/rslib-26.09.3/results/`의 JSON과 테스트 로그에서 옮겼다.

## 소스가 가리키는 곳

**[실행]** `git ls-remote https://github.com/ankitects/anki.git refs/tags/26.09.3` 는 한 줄이다.

`29bb700b951e3f0c0cb69b77c0180fc1fe33e6ba refs/tags/26.09.3`

GitHub 태그 객체 타입은 `commit`이다. 주석 태그(annotated tag)가 아니므로 peel 커밋이 따로 없다. 릴리스 API의 `target_commitish`도 같은 SHA다. 커밋 메시지는 `Prepare release 26.09.3`(Fernando Lins, 2026-09-22). 체크아웃의 `.version` 첫 줄은 `26.09.3`이다.

이전 실험 커밋 `1b48429de2d188e64fce46c9635620e3767a6879`는 이 태그가 아니다. **[실행]** 그 커밋 메시지는 2026-10-23의 `chore(ci): clear caches when pull requests close`. 릴리스보다 나중 main이다. 이번 빌드와 테스트는 전부 `29bb700`이다.

이 태그의 `rust-toolchain.toml` 채널은 **1.97.1**이다. **[코드]** 이전 문서의 Rust 1.99는 그 이후 트리 기준이다. 이번 박스에서 쓴 `rustc`는 `1.97.1 (8bab26f4f 2026-07-14)`.

번역 서브모듈 gitlink **[실행]** `git submodule status`:

| 경로 | 커밋 |
|---|---|
| `ftl/core-repo` | `49925703d0e1c2328cae2b7f7ade286ed147976d` |
| `ftl/qt-repo` | `8a58eb9663b6f78528198a1be9a72a4896ec2c83` |

얕은 클론만으로는 서브모듈 내용이 비어 있다. 실제 라이브러리 빌드는 위 SHA를 `git submodule update --init`으로 채운 뒤 했다. `.ftl` 파일 2300개.

## 어디에 두었는지

저장소는 README 한 줄뿐인 모노리포다. 제품 앱 디렉터리가 아직 없으므로, 검증 코드를 `apps/mobile`에 넣으면 제품 골격처럼 보인다. 서버 래퍼와 Android 래퍼가 같은 커밋·같은 fetch 스크립트를 쓰게 `spikes/rslib-26.09.3/` 한곳에 두었다.

```
spikes/rslib-26.09.3/
  bridge/          Backend::run_service_method 만 감쌈
  napi/            async open / run / close
  mobile/          Flutter + flutter_rust_bridge (Android만)
  scripts/         fetch, 빌드, 테스트
  vendor/anki/     gitignore. 빌드 때 태그를 받는다. 커밋하지 않음
docs/spikes/rslib-26.09.3.md
```

`rslib` 소스는 커밋하지 않았다. 빌드 산출물(`.node`, `.so`, `target/`, `jniLibs/`)도 커밋하지 않았다.

## 시나리오

| 시나리오 | 결과 | 근거 |
|---|---|---|
| 태그 26.09.3 = `29bb700` | 통과 | [실행] ls-remote, `.version`, 커밋 메시지 |
| 서브모듈 없이 `anki_i18n` 빌드 | 실패 | [실행] `gather.rs:78` `read_dir` NotFound |
| 빈 `ftl/core-repo/core`, `ftl/qt-repo/desktop`로 `anki_i18n` | 통과 | [실행] 증분 0.69초 |
| 체크아웃 안에서 `cargo check -p anki` (rslib 무수정, tokio feature 추가 없음) | 실패 | [실행] 73초, 오류 7개. 모두 `tokio` `io-util` |
| 래퍼가 `tokio` feature `io-util`만 켠 채 release `.node` | 통과 | [실행] 110초, 테스트 6/6 |
| napi import → export → 재import 필드 동일 | 통과 | [실행] `alpha / beta`, `hello / world`, 스키마 18 |
| 같은 guid 재import (`if_newer` / `always` / `never`) | 통과 | [실행] 아래 표 |
| 같은 컬렉션 경로 동시 4호출 | 통과 | [실행] 성공 1, 실패 3, `DB_ERROR` + "already open" |
| 서로 다른 컬렉션 4개 동시 import | 통과 | [실행] 전부 `new=1` |
| 300노트 import 중 이벤트 루프 | 통과 | [실행] 48ms, 10ms 타이머 최대 간격 11ms |
| `GetQueuedCards` + `AnswerCard` 한 사이클 | 통과 | [실행] reps 0→1, queue 0→1, revlog 1 |
| `with_scheduling=false` export의 revlog | 통과(0건) | [실행] sqlite `revlog` count 0 |
| `with_scheduling=false`가 카드 상태를 전부 지움 | 여기까지 | [실행] type/queue/reps/ivl은 새 카드로 리셋. `left`와 `lrt`는 남음. 결정 필요 |
| `with_scheduling=false` import가 스케줄 포함 패키지를 리셋 | 통과(같은 한계) | [실행] 재export revlog 0, reps 0. `lastReviewTimeSecs`와 `remainingSteps=1`은 남음 |
| 호스트 `flutter test` import/export | 통과 | [실행] |
| `aarch64-linux-android` / `x86_64-linux-android` `.so`, LOAD align ≥ 0x4000 | 통과 | [실행] 둘 다 `0x4000` |
| x86_64 에뮬레이터(16KB 페이지) integration test, 파일 경로 | 통과 | [실행] `PAGE_SIZE=16384`, `FRB_DEVICE_OK`, reps=1 |
| 실기기 ARM | 안 함 | 기기 없음. 했다고 쓰지 않음 |
| KVM 가속 에뮬레이터 | 실패 | [실행] `/dev/kvm`이 `root:103` `0660`, 이 사용자는 그룹에 없고 쓰기가 거절됨. TCG(`-accel off`)로 대체 |

## A. napi-rs

### 무수정 네이티브 빌드

**[실행]** `PROTOC=/usr/bin/protoc`(libprotoc 3.21.12)로 체크아웃 안에서 `cargo check -p anki`. 73초, exit 101. 오류 7개:

- `tokio::io::AsyncReadExt`를 못 찾음 (`sync/http_client/io_monitor.rs`, `sync/request/header_and_stream.rs`)
- `tokio::io::AsyncWriteExt`를 못 찾음 (`updates.rs`)
- `read_to_end`, `take`, `write_all`, `flush` 메서드 없음

**[코드]** 워크스페이스 `tokio` feature는 `fs`, `rt-multi-thread`, `macros`, `signal`뿐이다 (`Cargo.toml`). `io-util`이 없다. `rslib` 파일은 고치지 않았다. 래퍼 `bridge/Cargo.toml`이 `tokio = { version = "1.45", features = ["io-util"] }`를 의존해 feature unification으로 넘긴다. 그 상태로 release 빌드가 끝났다.

**[실행]** `ftl` 서브모듈 디렉터리가 없을 때 `anki_i18n` 빌드 스크립트는 영어 템플릿(`ftl/core/*.ftl`)을 읽은 뒤 `ftl/core-repo/core`에서 패닉한다. `gather.rs:78` `fs::read_dir(root).unwrap()`. 빈 디렉터리 두 개(`core-repo/core`, `qt-repo/desktop`)만 만들어도 `anki_i18n`은 통과했다(증분 0.69초). 이후 라이브러리 빌드는 빈 디렉터리 대신 릴리스 gitlink SHA의 서브모듈을 썼다.

**[실행]** 서드파티 크레이트에서 `DESCRIPTORS_BIN`을 비우고 빌드했다. `anki_proto`의 `build.rs`가 protoc로 descriptor를 만들고, `descriptors_path()`의 기본값 `OUT_DIR/../../anki_descriptors.bin`으로 `rslib`가 같은 `target/debug/build/` 아래 파일을 읽는다. **[코드]** `rslib/proto_gen/src/lib.rs`의 그 분기. 미리 만들어 둔 `descriptors.bin`은 필요 없었다. `STRINGS_PY` / `STRINGS_TS`도 비운 채 빌드가 끝났다. **[코드]** `option_env!`가 없으면 파이썬/TS 파일을 쓰지 않고 넘어간다. 체크아웃 안에서 빌드하면 `.cargo/config.toml`이 `PROTOC`를 `out/extracted/protoc/bin/protoc`로 가리킨다. 그 파일은 없다. 환경 변수 `PROTOC`가 이미 있으면 cargo config는 덮어쓰지 않는다(`force` 없음). 그래서 시스템 protoc를 썼다.

**[실행]** `git -C vendor/anki diff --stat -- rslib proto`는 비어 있다. Anki 워크스페이스 `Cargo.toml`에도 멤버를 추가하지 않았다. 스파이크 워크스페이스는 `exclude = ["vendor"]`라서 받아 온 트리를 자기 멤버로 오인하지 않고 path 의존만 한다.

| 항목 | 값 |
|---|---|
| 머신 | Linux x86_64, 코어 4, rustc 1.97.1, Node v22.23.4 |
| dev `cargo build -p hatto-rslib-napi` | 61초. `.so` 249,664,584바이트. 레지스트리 워밍 후, dev target은 처음 |
| release | 110초(`Finished ... in 1m 50s`). `.so`/`.node` 36,700,528바이트. `strip --strip-unneeded` 후 32,261,880바이트. release target은 처음, 레지스트리는 dev 빌드로 이미 받아 둔 상태 |
| `ldd` | `libgcc_s`, `libm`, `libc` |

콜드 레지스트리(crate 다운로드 포함) 시간은 재지 않았다. **[추정]** 그 경우 더 길다.

### protobuf 래퍼와 Node 테스트

**[코드]** `bridge`는 `init_backend`와 `Backend::run_service_method`만 호출한다. `Collection::import_apkg` / `export_apkg`는 호출하지 않는다. napi는 `open(initBytes)`, `run(service, method, input)`, `close`를 모두 async로 노출하고, 블로킹 호출은 `tokio::task::spawn_blocking`에 넣는다. 실패 바이트는 `BackendError` protobuf다.

`BackendInit`은 `preferred_langs=["en"]`, `server=true`로 넣었다. **[코드]** `server=true`이면 USN은 `col.usn`이고, `false`이면 -1이다.

서비스/메서드 번호는 이 커밋의 생성 코드 `backend.rs`에서 뽑았다. 버전 사이 안정성은 없다. **[코드]** `proto_gen` 주석이 인덱스 불변을 보장하지 말라고 한다. 이 커밋에서 확인한 값:

| 서비스 | index | 메서드 |
|---|---|---|
| `backend_collection_service` | 3 | `open_collection` 0, `close_collection` 1 |
| `backend_import_export_service` | 39 | `import_anki_package` 2, `export_anki_package` 4 |
| `backend_scheduler_service` | 13 | `get_queued_cards` 3, `answer_card` 4 |

**[실행]** release `.node`로 `node test/roundtrip.mjs`. 6개 전부 통과.

왕복: 노트 2개 export(반환 2) → 새 컬렉션 import `new=2` → 다시 export. 필드 집합 `alpha / beta`, `hello / world`. zip 엔트리는 `meta`, `collection.anki21b`, `collection.anki2`, `media`. 컬렉션 스키마 18. 이 기본 export의 revlog는 0.

같은 guid (`update_notes` 정수. protobufjs에 enum 이름 문자열을 넣으면 `ALWAYS`가 0으로 인코드되어 `if_newer`처럼 동작했다. 정수 0/1/2로 통과):

| 단계 | 결과 | 필드 |
|---|---|---|
| older import | `new=1` | hello / world |
| newer, if_newer(0) | `updated=1` | goodbye / world |
| older 다시, if_newer | `duplicate=1` | 저장된 값은 goodbye |
| older, always(1) | `updated=1` | hello / world |
| newer, never(2) | `duplicate=1` | 저장 필드는 hello / world로 유지 |

노트 mtime은 초 단위다. **[코드]** `should_update`의 `IfNewer`는 `existing < incoming`, `Always`는 `existing != incoming`, `Never`는 항상 거짓. 같은 초에 고치고 export하면 if_newer가 duplicate가 된다. 테스트는 update 전에 1.1초 쉰다.

동시성 **[실행]**: 같은 경로에 컬렉션을 연 채 4개가 동시에 import. 성공 1, 실패 3. 실패 protobuf는 `kind=DB_ERROR`(5), `message=Anki already open, or media currently syncing.`, `context` 빈 문자열. **[코드]** `DbErrorKind::Locked`는 `into_protobuf`에서 전부 `Kind::DbError`로 접히고, Locked의 문장만 저 문자열이다. 호출부는 `kind`만으로 Locked를 구분할 수 없다. **[코드]** `locking_mode=exclusive`, `busy_timeout` 0초(`storage/sqlite.rs`). 다른 경로 4개는 동시에 모두 `new=1`.

이벤트 루프 **[실행]**: 300노트 패키지 import 48ms 동안 `setInterval(10ms)` 최대 간격 11ms. async `run`이 그 구간에서 libuv를 막지 않았다. 더 큰 패키지로 상한을 재지는 않았다.

공부 한 사이클 **[실행]**: 새 카드 `ctype=0 queue=0 due=1 reps=0` → `AnswerCard` GOOD 이후 `ctype=1 queue=1 reps=1`. `with_scheduling=true` export의 revlog 1, 카드 type 1 reps 1. `with_scheduling=false` export의 revlog 0, type 0, queue 0, due 1, reps 0, ivl 0, factor 0, lapses 0.

### revlog와 카드 상태

프로젝트 결정은 revlog와 카드 상태를 들이거나 내보내지 않는 것이다. 옵션 이름과 실제 파일을 둘 다 봤다.

**[코드]** `ExportAnkiPackageOptions.with_scheduling` / `ImportAnkiPackageOptions.with_scheduling`이 `ExchangeData::gather_data`로 간다. `false`이면 revlog를 모으지 않고 `reset_cards` → `schedule_as_new(position, reset_counts=true, restore_position=true)`를 탄다. `schedule_as_new`는 ctype/queue를 New로, interval/ease/reps/lapses/memory_state를 지운다. `remaining_steps`(`cards.left`)는 건드리지 않는다. 카드 `data`의 마지막 복습 시각(`lrt`)도 지우지 않는다.

**[실행]** 공부한 카드를 `with_scheduling=false`, `with_deck_configs=false`로 export한 sqlite:

- revlog 0
- 카드 `type=0 queue=0 due=1 ivl=0 factor=0 reps=0 lapses=0 left=1`
- `data`는 `{"lrt":1793195212}`

같은 패키지를 `with_scheduling=true`로 export하면 revlog 1, type 1, reps 1, due는 학습 시각.

스케줄이 **들어 있는** 패키지를 `with_scheduling=false`로 import한 뒤 카드를 읽으면 `ctype=0 queue=0 reps=0 interval=0`, `remainingSteps=1`, `lastReviewTimeSecs`는 그대로다. 그 컬렉션을 `with_scheduling=true`로 다시 export하면 revlog는 0이다. import 옵션이 revlog를 넣지 않은 결과다.

`with_scheduling=true`로 import하면 reps 1, ctype 1, due가 파일과 같다.

`with_deck_configs=false` export의 `deck_config` 행은 1이다. true export도 1이다. **[코드]** 플래그가 false면 gather한 deck config를 넣지 않지만, 새 최소 컬렉션 스키마가 기본 deck config를 만든다. 커스텀 deck config를 만들어 빠지는지까지는 실행하지 않았다.

정리: 옵션만으로 revlog는 빼고, 카드의 스케줄 열(type, queue, due, interval, ease, reps, lapses, FSRS memory)은 새 카드로 리셋한다. `left`와 마지막 복습 시각은 남는다. 그 두 필드까지 없애야 하면 이 옵션으로는 안 되고, rslib를 고치지 않는 한 호출 뒤에 별도 처리가 필요하다. **결정 필요.**

## B. Android (flutter_rust_bridge)

Flutter 프로젝트는 위 스파이크 디렉터리의 `mobile/`이다. iOS 플랫폼은 `flutter create --platforms android`로 만들지 않았다. CargoKit은 쓰지 않았다. 이전 실험에서 CargoKit이 `rustup run stable`로 툴체인을 바꿔 Anki의 `rust-toolchain.toml`(1.97.1)과 어긋날 수 있었기 때문이다. 바인딩은 `flutter_rust_bridge_codegen` 2.13.0이 만들고, `.so`는 스파이크 스크립트가 같은 `PROTOC`와 1.97.1로 빌드한 뒤 테스트가 `ExternalLibrary.open`으로 연다. 통로는 napi와 같은 `open` / `run` / `close`다.

| 항목 | 값 |
|---|---|
| Flutter | 3.47.8 (stable), Dart 3.13.7, FRB 2.13.0 |
| 호스트 release `.so` | 57초(Anki release 오브젝트는 이미 있었음). 36,726,728바이트, strip 후 32,272,960. `ldd`는 libgcc_s, libm, libc |
| 호스트 `flutter test test/roundtrip_test.dart` | 통과. 필드 일치, revlog 0 vs ≥1, import 시 reps 0 vs 보존 |
| NDK | 29.0.14206865, cargo-ndk 4.1.2, platform 24, `RUSTFLAGS=-C link-arg=-Wl,-z,max-page-size=16384` |
| arm64-v8a | 92초. 36,796,616바이트. LOAD align 세 개 모두 `0x4000`. NEEDED `libdl`, `libm`, `libc` |
| x86_64 | 101초. 36,676,104바이트. LOAD align `0x4000` 세 개. NEEDED 동일 |

`liblog`는 NEEDED에 없다.

### 에뮬레이터

**[실행]** `/dev/kvm`은 `crw-rw---- root 103`. 이 사용자 그룹에 103이 없고 장치 쓰기가 실패한다. 가속은 쓰지 못했다.

시스템 이미지 `system-images;android-35;google_apis_ps16k;x86_64`로 AVD `hatto_ps16k`를 만들고 `emulator -accel off -no-window`(TCG)로 부팅했다. `getprop ro.product.cpu.abi`는 `x86_64`, `ro.build.version.sdk`는 35, `getconf PAGE_SIZE`는 **16384**.

부팅 완료 전에 `adb install`하면 `PackageManagerInternal.freeStorage` NPE로 설치가 실패했다(`sys.boot_completed`가 아직 빈 값). `sys.boot_completed=1` 이후 첫 `flutter test`는 테스트 본문이 7분 21초에 "did not complete"로 끊겼다. 타임아웃을 20분으로 올리고 다시 실행했을 때 통과했다.

```
HATTO_STEP import-roundtrip
HATTO_STEP study-and-export
HATTO_STEP import-without-scheduling
HATTO_STEP import-with-scheduling
FRB_DEVICE_OK fields=[alpha / beta, hello / world] reps=1
All tests passed!
```

입력은 앱 캐시 아래 파일 경로다. `content://`는 쓰지 않았다. 테스트가 `set_temp_dir`로 `TMPDIR`을 그 디렉터리로 둔 뒤 export했다. TCG라 걸린 시간은 기기 성능 대표값이 아니다.

디버그 APK 안의 `lib/x86_64/libhatto_rslib_frb.so`도 LOAD align `0x4000`이었다. arm64 `.so`도 APK에 들어갔다(`abiFilters`가 미리 넣어 둔 `jniLibs`를 빼지는 않았다).

실기기 ARM에서는 실행하지 않았다.

## 결정 필요

1. `with_scheduling=false`는 revlog를 빼고 카드 스케줄 열을 새 카드로 리셋한다. `cards.left`(remaining steps)와 마지막 복습 시각(`lrt` / `lastReviewTimeSecs`)은 남는다. 제품이 이 두 값까지 없어야 하면 옵션만으로는 부족하다. rslib는 고치지 않았다.
2. 락 실패의 protobuf `kind`는 `DB_ERROR` 하나다. Locked는 메시지 문장으로만 구분된다. 같은 경로 직렬화는 호출부 몫이다.
3. 서비스 인덱스는 26.09.3(`29bb700`) 생성 결과다. Anki를 올리면 서버와 앱이 같은 커밋으로 인덱스를 다시 뽑아야 한다.

## 하지 않은 것

- iOS, 웹 WASM, 동기화·병합, colpkg
- 실기기 ARM
- KVM 가속
- 커스텀 deck config가 export에서 빠지는지 분리 실행
- 콜드 cargo 레지스트리 기준 빌드 시간, NestJS 프로세스, 장시간 메모리
- content:// / SAF

## re-export 왕복에서 남는 것 (후속)

앱에만 있는 변경을 apkg로 다시 내보내 서버가 받는 흐름을, 같은 protobuf 통로로 napi와 FRB 호스트에서 실행했다. 샘플은 한 컬렉션에 같이 넣었다. **[실행]** 노트 8개, 카드 10개.

| 종류 | 만든 방법 |
|---|---|
| Basic | 스톡 노트타입. 필드에 한글·일본어·café·🇺🇸·`<b>`·`&amp;`·`<script>`, 4000자 `가`+`<b>end</b>`, base91 밖 문자(공백·`"`·`\`·한글)가 들어간 guid |
| Basic (and reversed card) | 새 컬렉션에 이미 있는 스톡. 템플릿 Card 1·Card 2, 카드 2장 |
| Cloze | 스톡 `KIND_CLOZE`. `{{c1::숨김}}` `{{c2::둘째}}`, 카드 ord 0·1 |
| 미디어 | `AddMediaFile`로 `pixel.png`, `beep.wav`. 필드는 `<img src>`와 `[sound:]` |
| 태그 | `custom`, `custom::child`, `marked`, `leech`, `유니코드` |
| 서브덱 | `Languages::한국어::Hangul`. DB 이름은 `Languages`, `Languages\x1f한국어`, `Languages\x1f한국어\x1fHangul` |
| 커스텀 노트타입 Hatto | Basic을 복사해 필드 Extra를 추가. 노트 필드 3개 |
| 스케줄 | 카드 하나 AnswerCard GOOD. revlog 1, type 1, reps 1, `left` 1, data `{"pos":1,"lrt":…}` |
| 공개 샘플 | Anki 트리 `pylib/tests/support`의 `media.apkg`, `update1.apkg`, `update2.apkg`, `diffmodels2-1.apkg` (스키마 11) |

비교는 export한 apkg의 sqlite·미디어를 `scripts/fidelity_snapshot.py`로 읽고 `scripts/fidelity_compare.py`로 맞췄다. FRB는 같은 originals를 import한 뒤 `with_scheduling=false`, `with_deck_configs=false`, `with_media=true`로 다시 export했다. **[실행]** `flutter test test/fidelity_test.dart` 통과. napi 왕복 24조합(샘플 6 × 옵션 4)도 예외 없이 끝났다.

### 보존 / 유실

Hatto 정책 export는 `with_scheduling=false`, `with_deck_configs=false`, `with_media=true`, `legacy=false`다. 아래 “정책”은 그 옵션으로 `rich-with-scheduling.apkg`를 빈 컬렉션에 넣었다가 다시 내보낸 결과다. napi와 FRB가 같았다.

| 항목 | 정책 왕복 | 근거 | Hatto 결정과의 관계 |
|---|---|---|---|
| 필드 값·순서 | 보존 | [실행] field mismatch 0. 유니코드, HTML, 4000자, cloze 표기, 미디어 참조 포함 | 본문. 유지해야 함 |
| guid | 보존 | [실행] missing/extra guid 0. base91 밖 guid도 유지 | 외부 덱을 병합하지 않으려면 guid 일치를 꺼야 하는데 옵션이 없다. 결정 필요 |
| note id | 보존 | [실행] id_changed 0 | 새 인스턴스여도 이 경로에서는 유지됨 |
| mtime (`notes.mod`) | 보존 | [실행] mtime_changed 0 | |
| csum, sfld | 보존 | [실행] 둘 다 changed 0. sfld는 HTML이 벗겨진 첫 필드(` pixel.png `, `한글 … bold &`) | [코드] `prepare_for_update`가 다시 계산. 입력이 같으면 값도 같음 |
| 태그(일반) | 보존 | [실행] `custom`, `custom::child`, `유니코드`, `reversed`, `cloze`, `media` | |
| `marked`, `leech` | 유실 | [실행] `with_scheduling=false`에서 `["leech","marked","유니코드"]` → `["유니코드"]`. true면 유지 | [코드] `gather.rs` `remove_system_tags`는 스케줄 제외일 때만. 옵션으로 이 둘만 남길 수는 없다 |
| 노트타입 필드 이름·순서, 템플릿 이름·ord | 보존 | [실행] Hatto는 Front/Back/Extra, Card 1. Cloze는 Text/Back Extra, 카드 2장. reversed는 Card 1·Card 2 | |
| 스톡 노트타입 이름 | 바뀜 | [실행] 대상에 이미 Basic/Cloze/reversed가 있으면 들어온 쪽 이름이 `Basic+`, `Cloze+`, `Basic (and reversed card)+`. 노트 mid(그 id)는 그대로 | [코드] `NoteField::is_match`는 양쪽 config id가 있으면 이름이 같아도 id가 다르면 불일치 → `equal_schema` 실패 → 새 이름. 이름으로 강제 병합하는 옵션은 없다. 결정 필요 |
| 커스텀 노트타입 이름 Hatto | 보존 | [실행] 충돌하는 스톡 이름이 없어서 `Hatto`로 남음 | |
| 덱 이름·계층 | 보존 | [실행] Default와 `\x1f` 계층 이름이 양쪽에 있음 | API에 넘긴 `::`는 DB에서 `\x1f` |
| 덱 id | Default=1만 유지, 만든 덱은 새 id | [실행] `deckIdChanged`에 Languages 3개. 그 카드 4장의 `cards.did`도 바뀜. 카드 id는 유지 | 계층 문자열은 남고 id는 남기지 않음 |
| 미디어 파일명·sha1 | 보존 | [실행] `pixel.png`, `beep.wav` 해시 불일치 0. 공개 `foo.wav`도 `with_media=true`면 유지 | `with_media=false`면 파일은 빠지고 필드 문자열의 참조는 남음 [실행] |
| usn | 대상 값으로 덮임 | [실행] 이번 컬렉션은 server=true라 처음부터 0이라 변화 없음. 스키마 11 샘플은 -1 → 0 | [코드] import가 `note.usn = self.usn` |
| revlog | 유실 | [실행] 1 → 0. `with_scheduling=true`면 1 → 1 | 기존 결정과 일치. 옵션으로 빠짐 |
| type, queue, due, reps, ease(`factor`), data의 `pos` | 리셋 | [실행] type 1→0, queue 1→0, due 1793200262→1, reps 1→0, data에서 `pos` 삭제. true면 이 차이는 없음 | 기존 결정(카드 상태 제외)과 일치 |
| `cards.left`, data의 `lrt` | 남음 | [실행] 정책 export 뒤에도 `left=1`, `data={"lrt":1793199529}` | 옵션이 이걸 지우지 않음. [코드] `schedule_as_new`는 left와 data JSON을 안 지움. 결정 필요(이전 절과 동일) |
| legacy=true | 스키마 11으로 다운그레이드 | [실행] dst schema 11. 노트 필드는 8/8 유지. `notetypes`/`decks` 테이블은 없음 | 정책 옵션이 아님. 이름 비교는 v18 테이블 기준이라 legacy 행의 “노트타입 없음”은 테이블이 없는 것이다 |

`with_scheduling=true`여도 스톡 노트타입 `+` 접미사와 커스텀 덱 id 변경은 그대로다. 그 둘은 스케줄 옵션과 무관하다.

### 앱에서 고친 뒤 서버가 받을 때

napi와 FRB 각각이 원본을 import하고, 필드 수정·태그 교체·노트 추가·노트 삭제를 한 다음 정책 옵션으로 export했다. napi는 거기에 Hatto 필드 `Extra`를 빼고 `AddedLater`를 넣는 `UpdateNotetype`까지 했다. **[실행]** 그 호출은 성공했고 이후 노트타입 필드 이름은 `Front, Back, AddedLater`였다. FRB 쪽 노트타입 필드 편집은 이번 테스트에 넣지 않았다.

서버(napi)가 **이미 원본이 들어 있는** 컬렉션에 그 apkg를 다시 import한 결과. FRB가 만든 패키지 기준이다. napi가 만든 패키지도 같은 방향이었다.

| updateNotes | 편집된 guid | 추가된 guid | 삭제한 guid |
|---|---|---|---|
| if_newer (0) | `updated=1`, 필드는 `hello-from-frb` | `new=1` | 컬렉션에 **그대로 있음** (`deletedStillPresent=true`) |
| always (1) | `updated=1`, 같은 새 필드 | `new=1` | 그대로 있음 |
| never (2) | `duplicate`, 필드는 원래 `hello` / `world`, 태그도 원래 `custom` `custom::child` | `new=1` (guid가 없으므로 never와 무관하게 추가) | 그대로 있음 |

빈 컬렉션에 넣으면 삭제된 guid는 없다. **[실행]** `deletedPresent=false`, 노트 8개(원본 8 − 삭제 1 + 추가 1). 삭제는 “패키지에 없다”로만 표현되고, 이미 있는 컬렉션의 노트를 지우는 동작은 없다.

**[코드]** `import_notes`는 guid가 있으면 갱신하거나 duplicate로 남기고, 패키지에 없는 guid는 보지 않는다. 삭제를 전파하는 플래그는 없다.

양방향: 서버가 앱 패키지를 빈 컬렉션에 import한 뒤 다시 export하고, 그 파일을 앱 컬렉션에 다시 import. **[실행]** `new=0`, `duplicate=8`, guid 개수 8, 고유 guid 8. 노트가 두 배로 늘지 않았다. 앱 export와 서버 re-export의 필드·태그·csum·mtime·note id 차이는 0이었다. 카드의 덱 id 4개와 스톡 노트타입 이름 `+`는 위와 같이 달랐다.

### 설계상 위험

- 삭제는 기존 컬렉션으로 전파되지 않는다. 앱 re-export를 서버의 기존 컬렉션에 병합하면 앱에서 지운 노트가 서버에 남는다. 전체를 갈아끼우지 않는 한 rslib 옵션으로 막을 수 없다.
- guid가 같으면 갱신된다. “외부 guid는 병합하지 않는다”와 충돌한다. import 쪽에 그 스위치를 끄는 필드는 없다. 빈 컬렉션에 넣거나, import 전에 guid를 바꿔야 한다.
- 서버 컬렉션에 같은 이름의 스톡 노트타입이 있으면 들어온 노트타입은 `+`가 붙은 새 이름이 된다. 노트는 그 id를 따라가서 필드 값은 유지되지만, 이름·id를 서버의 원래 Basic/Cloze와 공유하지 않는다. 필드 config id가 양쪽 다 있으면 이름이 같아도 스키마가 다르다고 본다.
- `marked`/`leech`와 `left`·`lrt`는 정책 옵션과 어긋나게 빠지거나 남는다. 한 플래그가 시스템 태그는 지우고 스케줄 잔재 일부는 남긴다.

## 재현

Anki 소스는 `spikes/rslib-26.09.3/vendor/anki`에만 받는다. 커밋하지 않는다.

```bash
spikes/rslib-26.09.3/scripts/fetch-anki.sh
spikes/rslib-26.09.3/scripts/build-napi.sh release
spikes/rslib-26.09.3/scripts/test-napi.sh
spikes/rslib-26.09.3/scripts/build-frb-host.sh
spikes/rslib-26.09.3/scripts/test-dart-host.sh
spikes/rslib-26.09.3/scripts/build-android.sh arm64-v8a
spikes/rslib-26.09.3/scripts/build-android.sh x86_64
spikes/rslib-26.09.3/scripts/run-fidelity.sh
```

필요 도구: Rust 1.97.1(스크립트가 `rust-toolchain.toml`로 선택), protoc, zstd, Node 22, Flutter 3.47.x, Android NDK 29.0.14206865, cargo-ndk 4.1.2. Dart protobuf는 `scripts/gen-dart-proto.sh`(protoc-gen-dart 25.1.0). 받아 온 트리의 `rslib/`와 `proto/`는 빌드 전후에 diff가 없어야 한다.
