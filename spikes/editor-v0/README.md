# 에디터 v0 스파이크

실험 코드다. 제품 패키지(`apps/`, `packages/`, `third_party/`)와 계약 파일을 바꾸지 않는다. 판정과 숫자의 원문은 [`docs/DMITRY_EDITOR_SPIKES.md`](docs/DMITRY_EDITOR_SPIKES.md)다. 툴체인 한 벌 후속은 [`docs/DMITRY_EDITOR_SPIKES_TOOLCHAIN.md`](docs/DMITRY_EDITOR_SPIKES_TOOLCHAIN.md)다. macOS 절차는 [`docs/DMITRY_EDITOR_SPIKES_MACOS_RUNBOOK.md`](docs/DMITRY_EDITOR_SPIKES_MACOS_RUNBOOK.md)이고, 그 문서는 이 브랜치 체크아웃만으로 시작한다(tarball 없음). 서명·공증은 하지 않는다.

Mac에서 시작:

```bash
git clone https://github.com/hatto-social/hatto.git ~/hatto
cd ~/hatto && git fetch origin cursor/editor-v0-spikes-18f8 && git checkout cursor/editor-v0-spikes-18f8
export SPIKE_ROOT="$HOME/hatto/spikes/editor-v0"
export PATH="$HOME/flutter-3.50/bin:$PATH"
cd "$SPIKE_ROOT" && ./scripts/fetch-anki.sh && mac/prepare.sh
```

그다음 런북 A0(별도 HOME의 `e/toolchain/rustup_shim_home`)를 하고 `pinned flutter build macos`를 돌린다. 사용자의 `~/.cargo/bin/rustup`은 바꾸지 않는다.

보고서의 `/workspace/editor-spikes`는 이 디렉터리다. rslib은 Anki **26.09.3** (`29bb700`) 무수정이며 `vendor/anki`에만 받는다(gitignore).

## 결정 (저장소 주인, 2026-11-18)

스파이크 결과를 본 뒤의 결정이다. 두 편집 표면 프로토타입은 근거로 둘 다 남아 있다.

- 편집 표면은 `EditableText` 직접 구현이다. `super_editor`는 채택하지 않는다.
- 미리보기는 Flutter 네이티브만 쓴다. 임의 템플릿 CSS는 보여 주지 않는다. 웹뷰 앱(`c/web_app`, `c/iaw_app`)은 참고용이다.
- 필드 순서 변경·삭제는 v0에 남긴다. 저널 0행은 항등 매핑일 때만 합격이다.
- 녹음은 캡처 중 단편화 m4a 임시 파일이고, 멈추면 일반 m4a로 바꾼다. 이 변환은 여기 구현되어 있지 않다(`record_linux`가 `movflags`를 받지 않음).

## 준비

Flutter **3.50.0** / Dart **3.14.0**, Rust **1.97.1** (하네스 `rust-toolchain.toml`), `protoc` 31.1. 골든은 `fonts/NanumGothic.ttf`를 쓴다.

```bash
scripts/fetch-anki.sh
```

## 돌리는 법

a. `ChangeNotetype` guid / `note_map` (Rust 스탠드인 래퍼):

```bash
cd a/harness && cargo build --release
./target/release/spike_a                 # S1–S6 + 크래시 3지점
./target/release/spike_a scale 5000
./target/release/spike_a render /tmp/spike_a_render ../c/evidence/rslib_render.txt
```

b. 편집 표면 두 개. 유즈케이스 골든은 `test/use_case_goldens_test.dart` (`test/goldens/use_cases/`).

```bash
cd b/proto && flutter test
```

c. 미리보기. 네이티브 골든은 `c/native_app/goldens/preview_native.png`. Linux 웹뷰 둘은 이 상자에서 실패했고, 앱은 재현용으로만 둔다.

```bash
cd c/native_app && flutter test
```

d. 한글 IME. 헤드리스 재생은 b의 테스트다. 실제 fcitx5/ibus 키 입력은 `d/run_ime.sh`이고, 이미 찍힌 화면은 `d/evidence/*/screen.png`다. macOS 2벌식은 런북 D.

```bash
cd b/proto && flutter build linux --debug
d/run_ime.sh fcitx5 b basic
```

e. `super_clipboard` + `super_drag_and_drop` + rslib 공존. 빌드가 길다. macOS G1·G2·G5·G7은 런북.

```bash
cd e/v2_super && flutter build linux --release
gcc -o e/clipset e/clipset.c $(pkg-config --cflags --libs gtk+-3.0)
e/runprobe.sh v2_super
```

m4a. 오디오 장치가 없으면 Pulse null sink가 필요하다. 형식 권고는 보고서 §7. 단편화 임시 파일 후 리먹스는 위의 결정이고, 이 테스트는 `record_linux`의 일반 m4a만 확인한다.

```bash
cd m4a/rec_test && flutter test test/rec_test.dart
```

노트타입 필드 추가·순서 변경 **화면**은 만들지 않았다. 순서 교환은 하네스 S4(데이터)다.
