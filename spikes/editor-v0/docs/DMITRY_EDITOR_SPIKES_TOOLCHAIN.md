# 에디터 스파이크 — Rust 툴체인 한 벌 검증 (Gina #5 G1 / #6 / #7 후속)

> 저장소 위치는 `spikes/editor-v0/docs/DMITRY_EDITOR_SPIKES_TOOLCHAIN.md`다. 래퍼는 `spikes/editor-v0/e/toolchain/`(`rustup_shim_home`, `rustup_shim_path`)다. 본문의 `/workspace/editor-spikes`는 `spikes/editor-v0`다. 박스의 evidence 로그와 `pin_shim` 빌드 트리, MathJax 번들, Anki 소스는 이 브랜치에 없다.


작성: Dmitry · 2026-11-18 KST · 환경: 박스(Linux x64), 코드/증거는 모두 `/workspace/editor-spikes/e/toolchain/` 아래
라벨: **[확인]** 이번에 직접 실행/관측 · **[추정]** 코드 읽기·문서 근거로 추론 · **[모름]** 검증 못 함

## 0. 한 줄 결론
- **[확인]** `RUSTUP_TOOLCHAIN=1.97.1`만으로는 **한 벌이 안 된다.** rslib(`flutter_rust_bridge`)는 1.97.1, `super_native_extensions`(cargokit)는 여전히 `stable`(1.100.0)으로 빌드된다. → **G1은 계속 "미통과"가 맞다** (Gina 판단 동일).
- **[확인]** cargokit이 호출하는 `rustup`을 `$HOME/.cargo/bin/rustup` 래퍼로 바꿔 `rustup run stable` → `rustup run 1.97.1`로 치환하면, 두 .so 모두 `rustc 1.97.1`로 나온다 (빌드 rc=0, 스모크 프로브 결과 기존과 동일). 앱 코드/플러그인 수정 없이 **CI/개발 환경 설정만으로** 가능.
- **[확인]** `super_native_extensions 0.9.1`은 1.97.1에서 컴파일된다. crate는 `rust-version`을 선언하지 않고, 의존 크레이트 중 최고 MSRV는 1.70 → 1.97.1 제약 없음.
- **[확인]** pub 패키지 0.9.1에 `rust/Cargo.lock`(206 패키지, lock v4)이 **포함**돼 있고 cargokit이 이를 그대로 사용한다 → Rust 의존성 버전은 이미 고정. 단, **툴체인은 고정되지 않는다**(`rust-toolchain` 파일 없음).
- **[확인]** `super_clipboard`/`super_drag_and_drop` 둘 다 `0.9.1`(정확 핀)이면 `super_native_extensions 0.9.1`, `irondash_engine_context 0.5.5`, `irondash_message_channel 0.7.0`로 해석된다 (-dev 아님).

## 1. 환경/버전
| 항목 | 값 |
|---|---|
| rustup | 1.29.3 (edbc831ce 2026-11-02) |
| 설치된 툴체인 | `stable`=rustc 1.100.0 (0ef1bc386, 2026-11-09), `1.97.1` (8bab26f4f, 2026-07-14), 1.93.1 |
| Flutter | 3.50.0 (stable, 2026-11-09 revision ab2912035e) |
| rslib 업스트림 핀 | `anki-src/rust-toolchain.toml` = 1.97.1 (주석: "older versions may fail to compile; newer versions may fail the clippy tests") |
| 앱 pubspec 핀 | `super_clipboard: 0.9.1`, `super_drag_and_drop: 0.9.1` (캐럿 제거, `e/v2_super/pubspec.yaml`) |
| pubspec.lock 해석 결과 | super_native_extensions 0.9.1 · super_clipboard 0.9.1 · super_drag_and_drop 0.9.1 · irondash_message_channel 0.7.0 · irondash_engine_context 0.5.5 (`toolchain/pin_shim/pubspec.lock`) |

## 2. ① env var가 cargokit에도 먹히나 — `.comment` 비교
확인 방법: `readelf -p .comment <so> | grep rustc`.

| 실행 | rslib `librust_lib_e_app.so` | `libsuper_native_extensions.so` | 증거 |
|---|---|---|---|
| 기준선: env/래퍼 없음 (`e/v2_super`) | 1.97.1 | **1.100.0** | `evidence/comment_compare.txt` |
| `RUSTUP_TOOLCHAIN=1.97.1` (`pin_env`) | 1.97.1 | **1.100.0** (변화 없음) | `comment_compare.txt`, `pin_env_build.log` |
| HOME 래퍼 + `PIN_TOOLCHAIN=1.97.1` (`pin_shim`) | 1.97.1 | **1.97.1** | `comment_compare.txt`, `pin_shim_build.log`, `pin_shim_rustup_calls.log` |

(주의: `comment_compare.txt`는 pin_shim 재빌드 후 2026-11-18 17:54 KST에 재생성함. 이전 버전에는 재빌드 전 값이 섞여 있었음.)

**[확인]** rslib가 1.97.1인 이유는 env var가 아니라 `native_toolchain_rust` 훅이 크레이트의 `rust-toolchain.toml`을 읽어 `rustup run 1.97.1 cargo build`를 직접 호출하기 때문(기준선도 env 없이 1.97.1).

## 3. cargokit의 툴체인 결정 방식과 우선순위
코드 위치(pub 캐시): `super_native_extensions-0.9.1/cargokit/build_tool/lib/src/{builder.dart,rustup.dart,options.dart}`.

1. **[확인]** 빌드 명령이 `rustup run <toolchain> cargo build …`로 고정. `<toolchain>` = 크레이트의 `cargokit.yaml`(`cargo.release.toolchain`)에서 오며 **기본값 `stable`**. 실제 호출 로그: `rustup run stable cargo build --manifest-path …/super_native_extensions-0.9.1/rust/Cargo.toml -p super_native_extensions --release --target x86_64-unknown-linux-gnu …` (`pin_shim_rustup_calls.log`).
2. **[확인]** `Toolchain` enum은 `stable | beta | nightly` 셋뿐 → 옵션으로 `1.97.1` 같은 구체 버전을 지정할 수 없다. 앱 쪽 `cargokit_options.yaml`에서 쓸 수 있는 키도 `use_precompiled_binaries`, `verbose_logging` 둘뿐(`options.dart`). 툴체인 오버라이드 없음.
3. **[확인]** `rustup run stable …`은 `RUSTUP_TOOLCHAIN` env와 `rust-toolchain.toml`을 **모두 무시**한다(명시 툴체인 인자가 최우선). CLI로 직접 확인함. 따라서 cargokit 경로의 우선순위는 사실상 "cargokit이 박은 `stable` > env > toml". (일반 `cargo` 직접 호출이면 rustup 문서상 `+toolchain` > `RUSTUP_TOOLCHAIN` > 디렉터리 오버라이드 > `rust-toolchain.toml` > 기본값 — 이 순서 자체는 문서 근거 **[추정]**, 이번에 cargokit 경로가 아니므로 미실험.)
4. **[확인]** `Rustup.executablePath()`는 **`$HOME/.cargo/bin/rustup`을 먼저**, 그다음 PATH를 본다. 그래서 PATH 앞에 둔 래퍼는 호출되지 않았고(첫 시도 실패), `HOME`을 바꿔 그 아래 `.cargo/bin/rustup` 래퍼를 둔 방식만 동작했다. 이때 `RUSTUP_HOME`/`CARGO_HOME`/`PUB_CACHE`는 실제 경로로 유지해야 함.
5. **[확인]** 래퍼(`toolchain/fakehome/.cargo/bin/rustup`):
```bash
#!/bin/bash
REAL=/home/box/.cargo/bin/rustup
echo "rustup $*" >> "${SHIM_LOG:-/tmp/rustup_shim2.log}"
if [ "$1" = run ] && [ "$2" = stable ] && [ -n "$PIN_TOOLCHAIN" ]; then shift 2; exec "$REAL" run "$PIN_TOOLCHAIN" "$@"; fi
exec "$REAL" "$@"
```
   사용: `HOME=<fakehome> RUSTUP_HOME=~/.rustup CARGO_HOME=~/.cargo PUB_CACHE=~/.pub-cache PIN_TOOLCHAIN=1.97.1 flutter build linux`. (Mac용 `mac/toolchain/rustup-pin-shim.sh`는 번들에 포함, 러너북 A0 참조.)
6. **[확인, 부수 발견]** cargokit은 **rustup이 없으면 프리컴파일 바이너리를 내려받아 쓴다**(크레이트 `cargokit.yaml`의 URL/키; 서명 검증은 함). CI에 rustup이 없거나 PATH 사고가 나면 툴체인 한 벌 원칙·G8 재현성과 무관한 바이너리가 섞일 수 있다. 앱 루트에 `cargokit_options.yaml`: `use_precompiled_binaries: false`를 두면 대신 빌드를 중단시킨다 **[추정: 문서 근거, 미실험]**.

## 4. ② 0.9.1이 1.97.1에서 컴파일되나
- **[확인]** 실제 빌드 성공: `pin_shim_build.log`(rc=0), `libsuper_native_extensions.so`가 `rustc 1.97.1`. 같은 앱의 스모크 프로브(file/text/filetext/png/png_html/truncated/random/hugedims/huge120)가 1.100.0 빌드와 동일 결과(`e/evidence/pin_shim` vs 기존, `evidence/smoke_pin_shim`).
- **[확인]** 선언 MSRV: `super_native_extensions` 자체는 `rust-version` 없음. linux-x64로 해석되는 113개 패키지 중 75개가 선언, **최고 1.70** (`cfg-expr 0.15.8`, `colored 2.1.0`; `evidence/msrv_scan.txt`) → 1.97.1과 충돌 없음.
- **[모름]** 다른 플랫폼(macOS/Windows/Android) 타깃의 의존 트리 MSRV와 빌드는 Linux에서 검증 못 함 (Mac은 러너북 A0/B에서 확인).
- **[확인]** 반대 방향(rslib를 `stable` 1.100.0으로 올리기)은 이번에 **판정 불가**: `RUSTUP_TOOLCHAIN=stable cargo build --release`로 약 330개 크레이트까지 컴파일 후, `anki` 크레이트의 build script가 `Error: No such file or directory`로 종료(`evidence/rslib_on_stable_build.log`, rc=101). 컴파일러 오류가 아니라 build.rs의 파일 부재(별도 `--target-dir`로 돌려서 `out/` 산출물 부재 추정 **[추정]**)로 보이며, 툴체인 문제라는 증거는 없다. 따라서 "둘 다 1.100으로 올리기"(Gina 3순위)의 가능 여부는 **[모름]**; 재시도하려면 rslib 정식 빌드 경로(`flutter build`의 훅)로 `rust-toolchain.toml`을 임시로 stable로 바꿔 돌려야 함(업스트림 주석상 clippy 쪽 리스크 별도).

## 5. ③ Cargo.lock
- **[확인]** pub tarball(`evidence/sne-0.9.1.tar.gz`)에 `rust/Cargo.lock`, `rust/Cargo.toml`, `rust/cargokit.yaml` 포함 (`evidence/sne_tarball_cargo_files.txt`). `Cargo.lock`은 206 패키지, lock v4. `rust-toolchain(.toml)`은 **없음**.
- **[확인]** cargokit은 pub 캐시의 매니페스트 경로로 `cargo build`를 하며 `--locked`는 없지만, 빌드 전후 `Cargo.lock`이 바뀌지 않았다 → 동봉 lock이 실제 사용됨.
- 재현성 함의: (a) Rust **의존성**은 `super_native_extensions` 버전 = 정확 핀이면 고정됨. (b) **rustc 버전**은 고정 안 됨 → 2절처럼 같은 소스가 1.97.1/1.100.0으로 달라짐. (c) pub 캐시 파일이 아니라 `pubspec.lock`의 `sha256`이 패키지 무결성을 담보하므로 **앱의 `pubspec.lock` 커밋**이 필수.
- 핀 방법 정리: ① `pubspec.yaml`에 세 패키지 모두 정확 버전(캐럿 금지), ② `pubspec.lock` 커밋, ③ CI에서 `dart pub get --enforce-lockfile`, ④ 위 rustup 래퍼로 툴체인 고정, ⑤ `cargokit_options.yaml`로 프리컴파일 차단, ⑥ 빌드 후 `.comment` 게이트(아래).

## 6. 권장: 툴체인 한 벌(1.97.1) 구성
1. **기준 툴체인 = 1.97.1** (rslib 업스트림 핀과 동일, super_native_extensions도 컴파일됨). `rust-toolchain.toml`(rslib 쪽)이 단일 진실원천.
2. **빌드 환경(개발자/CI)에 rustup 래퍼 설치**: `PIN_TOOLCHAIN`을 `rust-toolchain.toml`에서 읽도록 스크립트화(`grep channel`). 앱/플러그인 소스 수정 없음. 위험: cargokit 내부 동작(HOME 우선 탐색, 하드코딩 `stable`)에 의존 → cargokit 업그레이드 시 깨질 수 있음 → 0.9.1 정확 핀 + 게이트로 감지.
3. **CI 게이트(필수)**: 빌드 산출물 전체 `.so`에 `readelf -p .comment`를 돌려 `rustc version` 값이 **정확히 한 종류(1.97.1)** 인지 검사, 아니면 실패. 이 게이트가 G1 통과의 객관 기준. (macOS는 `.dylib`에 `.comment`가 없을 수 있어 `strings | grep "rustc version"` 대안 **[모름, Mac 미검증]**.)
4. **중기 대안**: cargokit을 `dependency_overrides` git SHA로 포크/패치해 툴체인을 env/`rust-toolchain.toml`에서 읽게 함. (G9 포크 계획과 같은 트랙. hatto-social 포크 저장소 생성은 재열님 승인 필요 — 이번엔 만들지 않음.)
5. **3순위(Gina 순서 유지)**: 양쪽을 최신 stable로 — rslib 쪽 검증이 이번에 불완전(4절)이라 보류. **최후 수단**: 두 툴체인 공존(현 상태; G1 문서에 "2개 공존" 명시 + 게이트를 "허용 목록 2종"으로).
6. 위험 요약: 래퍼 방식은 cargokit 구현 의존(추정 안정도 보통), `stable` 부동 상태에서 다른 개발자가 래퍼 없이 빌드하면 조용히 1.100이 섞임 → 게이트가 막아주지만 **로컬 개발 경험은 가이드 필요**.

## 7. macOS 주의
- **[추정]** Mac도 같은 cargokit Dart 도구를 쓰므로 동일 동작(하드코딩 `stable`, `$HOME/.cargo/bin/rustup` 우선). Mac 래퍼는 `mac/toolchain/rustup-pin-shim.sh`, 설치/사용은 `DMITRY_EDITOR_SPIKES_MACOS_RUNBOOK.md`의 "갱신 메모(2026-11-18) A0"에 반영. **[모름]** Mac에서의 실제 동작은 미검증.
- Gina #7 ②(문서 편집기 복사 시 이미지+HTML 동반 여부) 확인 절차는 같은 러너북 **섹션 G**(2026-11-18 추가).

## 8. 증거 경로
- `/workspace/editor-spikes/e/toolchain/evidence/` — `comment_compare.txt`, `pin_env_build.log`, `pin_shim_build.log`, `pin_*_pubget.log`, `pin_shim_rustup_calls.log`, `sne-0.9.1.tar.gz`, `sne_tarball_cargo_files.txt`, `msrv_scan.txt`, `rslib_on_stable_build.log`, `smoke_pin_shim/`
- 빌드 앱: `toolchain/pin_env/`, `toolchain/pin_shim/` (pubspec.lock 포함) · 래퍼: `toolchain/fakehome/.cargo/bin/rustup`(동작), `toolchain/shim/rustup`(PATH 방식, 실패)
- Mac 번들: `/workspace/editor-spikes/mac_bundle/editor-spikes-mac.tgz` (핀된 `v2_super/pubspec.yaml` + 래퍼 포함)
