# 에디터 스파이크 macOS 실행 절차 (재열님 Mac용)

작성: Dmitry · 2026-11-18 KST · 초안. 이 문서의 모든 명령은 **Mac에서 실행해 본 적이 없다**(상자는 Linux). Linux에서 같은 코드를 돌린 결과는 `DMITRY_EDITOR_SPIKES.md`에 있다. 소스는 브랜치 `cursor/editor-v0-spikes-18f8`의 `spikes/editor-v0`다. 압축 파일은 없다. 명령이 실패하면 오류 문장 그대로 돌려주세요. 서명·공증·Developer ID 단계는 **없다**(전부 서명 없는 로컬 빌드, 샌드박스는 시험용으로 꺼 둔다). 총 소요 약 1.5~2시간(첫 빌드가 길다), 손이 필요한 항목은 C·D·E다.

## 0. 보낼 것(마지막에 한 번)
`~/Desktop/spike-results/` 폴더 하나를 압축해 돌려주세요. 각 항목 끝의 "보낼 파일"을 이 폴더에 모읍니다. 화면 캡처는 `⌘⇧4`.
```bash
mkdir -p ~/Desktop/spike-results
```

## 1. 준비물
| 항목 | 값 | 확인 명령 |
|---|---|---|
| macOS / 칩 | 버전과 Apple Silicon 여부를 기록 | `sw_vers; uname -m` |
| Xcode | 설치 + 첫 실행 동의 완료 | `xcodebuild -version` |
| CocoaPods | | `brew install cocoapods` |
| protoc | rslib 빌드용 | `brew install protobuf` |
| Rust | 상자와 같은 1.97.1(앱 핀) | `curl https://sh.rustup.rs -sSf | sh` 후 `rustup toolchain install 1.97.1 && rustup target add aarch64-apple-darwin x86_64-apple-darwin --toolchain 1.97.1` |
| cargokit | `rustup default`는 바꾸지 않는다. A0의 별도 HOME 래퍼가 `rustup run stable`만 1.97.1로 바꾼다 | `rustc --version` 기록. 타깃만 추가: `rustup target add aarch64-apple-darwin x86_64-apple-darwin --toolchain 1.97.1` |
| Flutter | **3.50.0 stable**(revision `ab2912035e`, Dart 3.14.0) | `git clone https://github.com/flutter/flutter.git ~/flutter-3.50 && cd ~/flutter-3.50 && git checkout ab2912035e && export PATH=$HOME/flutter-3.50/bin:$PATH && flutter --version && flutter config --enable-macos-desktop` |
| 한글 입력 | 시스템 설정 → 키보드 → 입력 소스에 "한국어 → 2벌식" 추가 | |
| 선택 | ffmpeg(파일 검사용) | `brew install ffmpeg` |
| 브라우저 | Chrome, Safari, Firefox 모두 | |

## 2. 소스 받기와 준비
소스는 이 저장소 브랜치다. `editor-spikes-mac.tgz`는 쓰지 않는다.
```bash
git clone https://github.com/hatto-social/hatto.git ~/hatto
cd ~/hatto
git fetch origin cursor/editor-v0-spikes-18f8
git checkout cursor/editor-v0-spikes-18f8
export REPO="$HOME/hatto"
export SPIKE_ROOT="$REPO/spikes/editor-v0"
export PATH="$HOME/flutter-3.50/bin:$PATH"
cd "$SPIKE_ROOT"
./scripts/fetch-anki.sh 2>&1 | tee ~/Desktop/spike-results/fetch-anki.log   # vendor/anki, gitignore, tag 26.09.3
mac/prepare.sh 2>&1 | tee ~/Desktop/spike-results/prepare.log   # macOS 러너 생성, 샌드박스 끔, rust-toolchain 타깃에 apple-darwin 추가
# 120MB 가짜 PNG (저장소에 없음)
(printf '\x89PNG\r\n\x1a\n'; head -c 125829120 /dev/zero) > e/fixtures/huge_120mb.bin
```
이미 클론이 있으면 `cd ~/hatto && git fetch origin cursor/editor-v0-spikes-18f8 && git checkout cursor/editor-v0-spikes-18f8` 만 하고 위의 `export`부터 이어간다.

`mac/prepare.sh`가 하는 일: `e/v1_rslib`·`e/v2_super`·`e/v3_control`·`b/proto`·`mac/rec_mac`·`mac/web_mac`에 `flutter create --platforms=macos .`, `macos/Runner/*.entitlements`의 `app-sandbox`를 `false`로, 세 변형의 `rust/rust-toolchain.toml` `targets`에 `aarch64-apple-darwin`·`x86_64-apple-darwin` 추가, 녹음 앱에 마이크 사용 설명 추가. 서명 설정은 건드리지 않는다. rslib 경로는 이미 `vendor/anki` 상대 경로다.

## A. 빌드 (게이트 G1·G2, 크기)
**무엇을 보나**: V1(FRB+rslib), V2(V1+`super_clipboard`+`super_drag_and_drop`), V3(대조군 `pasteboard`+`desktop_drop`)이 macOS에서 `flutter build macos --release`로 빌드되고, 시작 시 rslib 호출이 성공하는가. Rust 툴체인이 한 벌(1.97.1)인가. 상자 첫 빌드는 FRB 1.97.1 + cargokit `stable`(1.100.0)이었고, A0 래퍼로 둘 다 1.97.1이 됐다.

> **A0 (2026-11-18, Dmitry)**: `RUSTUP_TOOLCHAIN=1.97.1`만으로는 `super_native_extensions`가 1.97.1로 빌드되지 않았다. cargokit가 `rustup run stable`을 고정 호출하고 `$HOME/.cargo/bin/rustup`을 PATH보다 먼저 찾는다. 아래 래퍼는 그 호출만 1.97.1로 바꾼다. Mac에서 실행해 본 적은 없다. 상세는 `DMITRY_EDITOR_SPIKES_TOOLCHAIN.md`. `e/v2_super/pubspec.yaml`의 `super_clipboard`·`super_drag_and_drop`은 `0.9.1` 정확 핀이다(`^` 없음).
```bash
# A0. 실제 ~/.cargo/bin/rustup 은 바꾸지 않는다. 별도 HOME에만 둔다.
# 되돌리기: rm -rf "$HOME/spike-pinhome"
mkdir -p "$HOME/spike-pinhome/.cargo/bin"
cp "$SPIKE_ROOT/e/toolchain/rustup_shim_home" "$HOME/spike-pinhome/.cargo/bin/rustup"
chmod +x "$HOME/spike-pinhome/.cargo/bin/rustup"
REAL="$HOME"
PIN_HOME="$HOME/spike-pinhome"
pinned() { env HOME="$PIN_HOME" REAL_HOME="$REAL" RUSTUP_HOME="$REAL/.rustup" CARGO_HOME="$REAL/.cargo" PUB_CACHE="$REAL/.pub-cache" PIN_TOOLCHAIN=1.97.1 SHIM_LOG="$REAL/Desktop/spike-results/rustup_shim_calls.log" "$@"; }
# PATH 변형 e/toolchain/rustup_shim_path 는 cargokit이 호출하지 않는다. 쓰지 않는다.
```
`pinned`로 빌드하면 `rustup_shim_calls.log`에 `rustup run stable cargo build …`가 찍혀야 한다. `flutter`가 `~/Library`·`~/.config`를 `HOME` 기준으로 찾으므로 첫 실행에 설정 재초기화가 나올 수 있다. 문제가 있으면 V2만 `pinned`로 빌드한다. 두 `.dylib`의 rustc가 모두 1.97.1인지 `sizes.txt`에 남긴다.

```bash
# 같은 터미널에서 위의 A0를 먼저 실행해 pinned가 정의돼 있어야 한다.
cd "$SPIKE_ROOT/e"
for v in v1_rslib v2_super v3_control; do
  ( cd "$v" && flutter pub get && /usr/bin/time -p pinned flutter build macos --release 2>&1 | tee ~/Desktop/spike-results/build_$v.log | tail -5 )
done
for v in v1_rslib v2_super v3_control; do
  A=$v/build/macos/Build/Products/Release/e_app.app
  echo "== $v"; du -sk $A; find $A -name '*.dylib' -o -name '*.so' | xargs -I{} sh -c 'echo {}; lipo -archs {} 2>/dev/null; ls -la {}'
done | tee ~/Desktop/spike-results/sizes.txt
# V2 앱이 포함한 rustc 버전(두 벌인지): 라이브러리 이름은 빌드마다 다를 수 있어 .dylib/.framework 안을 모두 훑는다
find v2_super/build/macos/Build/Products/Release/e_app.app \( -name '*.dylib' -o -perm +111 -type f \) 2>/dev/null | while read f; do r=$(strings "$f" 2>/dev/null | grep -m1 "rustc version"); [ -n "$r" ] && echo "$f: $r"; done | tee -a ~/Desktop/spike-results/sizes.txt
```
- **기록**: 세 빌드 성공 여부, 빌드 시간(`real`), `.app` 크기(`du -sk`), `lipo -archs`(arm64 단독인지 유니버설인지), 두 Rust 라이브러리의 rustc 버전.
- **통과 기준(상자 기준과 동일)**: 세 빌드가 모두 성공, V2−V1 크기 증가를 보고(상자 Linux는 +2.1MB), 오류가 나면 전체 로그.
- 실패하기 쉬운 곳: `rust-toolchain.toml` 타깃 누락, `protoc` 없음, CocoaPods 오류, FRB 빌드 훅의 macOS 타깃 이름. **서명 오류는 이 절차의 범위가 아니다** — Flutter가 기본 ad-hoc 서명을 쓰는 것은 그대로 둔다.
- **보낼 파일**: `build_*.log`, `sizes.txt`, `prepare.log`, `fetch-anki.log`, `rustup_shim_calls.log`.

## B. 기동 안정성: irondash#81 / super_native_extensions#570 (게이트 G7)
**무엇을 보나**: V2는 시작 화면에 `DropRegion`이 있다. irondash_engine_context의 비동기 등록 경합(이슈 #81: https://github.com/irondash/irondash/issues/81)으로 기동 직후 SIGSEGV(`objc_loadWeakRetained`)가 나는가. 상자 Linux에서는 해당 코드가 없어 시험하지 못했다.
```bash
cd "$SPIKE_ROOT/e/v2_super"
APP=build/macos/Build/Products/Release/e_app.app/Contents/MacOS/e_app
rm -rf /tmp/e_v2_super; ok=0; fail=0
for i in $(seq 1 20); do
  VARIANT=v2_super $APP >/tmp/b_run_$i.log 2>&1 & P=$!
  sleep 4
  if kill -0 $P 2>/dev/null; then ok=$((ok+1)); kill $P; else fail=$((fail+1)); echo "run $i: DIED"; fi
  wait $P 2>/dev/null; sleep 1
done
echo "alive=$ok died=$fail" | tee ~/Desktop/spike-results/B_irondash81.txt
cat /tmp/e_v2_super/rslib.txt /tmp/e_v2_super/ext.txt | tee -a ~/Desktop/spike-results/B_irondash81.txt
ls -t ~/Library/Logs/DiagnosticReports/ | grep -i e_app | head
# 같은 방식 5회를 Finder 더블클릭 경로(open)로도 — 타이밍이 다르다
for i in 1 2 3 4 5; do open build/macos/Build/Products/Release/e_app.app; sleep 5; pgrep -x e_app >/dev/null && echo "open run $i: alive" || echo "open run $i: DIED"; pkill -x e_app; sleep 1; done | tee -a ~/Desktop/spike-results/B_irondash81.txt
```
- **통과 기준**: 20회 + 5회에서 `DIED` 0, 진단 리포트 없음. 한 번이라도 죽으면 **G7 FAIL** — `~/Library/Logs/DiagnosticReports/e_app*.ips`와 `/tmp/b_run_*.log`를 첨부.
- #570(Flutter master 크래시)은 master가 아니라 3.50.0 stable로만 시험한다 [모름: master 시험은 안 함].
- 선택(재현이 안 되는 경우 우회 확인): 문제가 있을 때만, `~/.pub-cache/hosted/pub.dev/irondash_engine_context-0.5.5/macos/Classes/EngineContextPlugin.m`의 `getFlutterView:`에 `if (context == nil) return nil;`을 넣고 다시 빌드·반복. 일반 시험에서는 패치하지 않는다.
- **보낼 파일**: `B_irondash81.txt`, 크래시 리포트(있으면).

## C. 붙여넣기·끌어놓기 (게이트 G4·G5·G6, 붙여넣기 정책 입력원)
앱은 `/tmp/e_<variant>/trigger` 파일이 생기면 클립보드를 읽어 `probe_<이름>.json`을 쓴다(상자와 같은 프로브). V2와 V3 각각 반복한다.
```bash
cd "$SPIKE_ROOT/e"
FX=$PWD/fixtures
# 앱은 별도 터미널 탭에서 켜 둔다:  cd "$SPIKE_ROOT/e/v2_super" && rm -rf /tmp/e_v2_super && VARIANT=v2_super build/macos/Build/Products/Release/e_app.app/Contents/MacOS/e_app
probe() { # $1 variant $2 name  : 클립보드가 준비된 뒤 실행
  echo $2 > /tmp/e_$1/trigger; for i in $(seq 1 40); do [ -f /tmp/e_$1/probe_$2.json ] && break; sleep 0.5; done
  cat /tmp/e_$1/probe_$2.json | tee ~/Desktop/spike-results/C_$1_$2.json; echo
  pgrep -x e_app >/dev/null && echo "app alive" || echo "APP DIED"
}
```
**C1. 합성 클립보드 케이스**(상자와 같은 케이스; `setclip.swift`가 NSPasteboard에 넣음):
```bash
for c in file text filetext png png_html truncated random hugedims huge120; do
  swift "$SPIKE_ROOT/mac/setclip.swift" "$c" "$FX" && probe v2_super "$c"
done
```
(`probe v2_super …`는 V2 앱이 위 방식으로 다른 탭에서 켜져 있어야 한다. V3는 앱을 바꿔 켜고 `v3_control`로 반복. `setclip.swift`가 안 돌아가면(`xcode-select -p` 확인) 케이스 `file`·`text`는 Finder/메모에서 직접 복사해 대체한다.)
**C2. 실제 앱에서 복사**(이게 G5의 본 시험이다). 각각 복사한 뒤 `probe v2_super <이름>`:
| 이름 | 어떻게 복사 |
|---|---|
| `finderfile` | Finder에서 `fixtures/red.png` 선택 → ⌘C |
| `finderfile_jpg` | `fixtures/blue.jpg` 선택 → ⌘C |
| `screenshot` | `⌃⌘⇧4`로 영역 캡처(클립보드로) |
| `chrome_img` | Chrome에서 아무 웹 이미지 우클릭 → "이미지 복사" |
| `safari_img` | Safari에서 같은 이미지 → "이미지 복사" |
| `firefox_img` | Firefox에서 같은 이미지 → "이미지 복사" |
| `text` | 메모 앱에서 텍스트 복사 |
| `html_rich` | 웹 문단을 선택해 복사(이미지 없는 서식 글) |
| `preview_img` | 미리보기 앱에서 이미지 열고 ⌘A, ⌘C |
**읽는 법(프로브 JSON)**: `platformFormats`(OS가 준 형식 목록), `png/jpeg/gif/webp`, `fileUri`·`fileUriValue`, `html`·`htmlHead`, `text`·`textValue`, `pngBytes`·`pngMagic`. 상자 Linux 기대값은 `DMITRY_EDITOR_SPIKES.md` §6.3.
- **G4 통과 기준**: Finder 파일 복사에서 `fileUri=true`(값이 `file:///…`)이고 `text`와 구분됨; 텍스트 복사에서 `fileUri=false`; `filetext`에서 둘 다 구분됨. 파일 복사에서 `png`도 `true`로 나오는지(Linux에서는 나왔다) 기록.
- **G5 통과 기준**: Chrome·Safari·Firefox 각각에서 `html=true`와 `png=true`(또는 `tiff`만 있고 `png`가 변환으로 제공되는지) **동시에** 읽히는가. 못 읽는 조합은 표로 남긴다: 브라우저 × (html, png, jpeg, fileUri, text). 이 표가 게이트의 산출물이다.
- **G6 통과 기준**: `truncated`, `random`, `hugedims`, `huge120` 모두 `app alive`. 앱이 죽으면 FAIL(상자 Linux: 전부 생존, 20000×20000에서 `pasteboard` 대조군은 11초·1.4GB). V2와 V3 각각의 `Activity Monitor` 최대 메모리를 `huge120`·`hugedims` 후에 적어 두면 좋다(`ps -o rss= -p $(pgrep -x e_app)`).
**C3. Finder에서 끌어놓기**(`super_drag_and_drop`): V2 앱 창(전체가 DropRegion)에 (a) Finder의 `red.png`, (b) Safari/Chrome의 웹 이미지, (c) 파일 3개를 한 번에 끌어다 놓는다. 그때마다 `cat /tmp/e_v2_super/drop.json`을 `~/Desktop/spike-results/C_drop_<설명>.json`으로 저장(마지막 드롭만 남으므로 드롭 사이사이 저장). V3(`desktop_drop`)에서도 같은 드롭을 하고 `/tmp/e_v3_control/drop.json`을 저장.
- **보낼 파일**: `C_*.json`, 표(브라우저 × 형식), 앱이 죽은 경우 크래시 리포트.

## D. 한글 IME 조합 (스파이크 d의 macOS 쪽, 수동)
**무엇을 보나**: macOS "2벌식"에서 두 편집 표면(A `super_editor`, B `EditableText` 직접)이 조합 중 글자를 중복·소실시키는가. 알려진 이슈: super_editor#2757(조합 중 Shift+Enter에서 마지막 글자 복제, macOS 15.5 보고).
```bash
cd "$SPIKE_ROOT/b/proto" && flutter pub get && flutter build macos --release 2>&1 | tee ~/Desktop/spike-results/build_proto.log | tail -3
APP=$PWD/build/macos/Build/Products/Release/editor_proto.app/Contents/MacOS/editor_proto
# 표면 B(EditableText)
rm -f /tmp/ime_B.jsonl; FIELD=b IME_LOG=/tmp/ime_B.jsonl $APP
# (종료 후) 표면 A(super_editor): 창을 열고 필드를 한 번 클릭한 뒤 입력
rm -f /tmp/ime_A.jsonl; FIELD=a IME_LOG=/tmp/ime_A.jsonl $APP
```
각 표면에서 **입력 소스를 2벌식으로 바꾸고** 아래를 순서대로 친 뒤, 시나리오마다 `tail -1 /tmp/ime_X.jsonl`(마지막 상태)을 적고 화면을 캡처한다. 시나리오마다 앱을 껐다 켜거나, 필드를 비운 뒤 진행(`⌘A` `Delete`).
| # | 입력 | 기대 결과 |
|---|---|---|
| 1 | `g k s r m f`, `space`, `e p d l x j` | `한글 데이터` |
| 2 | `g k s` 후 `shift+Return`, `r m f` | `한` 줄바꿈 `글` (#2757이면 `한` 복제) |
| 3 | `g k s` 후 `←`, `r m f` | `글한` |
| 4 | `g k s` 후 Backspace 3번 | 빈 필드(자모 분해 후 삭제) |
| 5 | 빠르게(손이 닿는 가장 빠른 속도로) `한글 데이터` 5회 | 매번 `한글 데이터`; 틀린 횟수를 적는다 |
| 6 | `g k` 후 입력 소스를 영문으로 전환(⌃Space 또는 Caps Lock)하고 `a b`, 다시 한글로 `g k` | `하ab하` |
| 7 | 조합 중(`g k s` 직후) 마우스로 같은 필드의 다른 위치 클릭 후 계속 입력 | 조합이 확정되고 중복 없음 |
| 8 | 굵게 처리한 글자 뒤에서 이어 쓰기: 필드 초기값 `<b>굵</b>`(환경변수 `INIT_HTML='<b>굵</b>'`)로 시작해 `g k s r m f` | `굵한글`이 굵게(`html`이 `<b>굵한글</b>`) |
- **통과 기준**: 1~4, 6~8에서 기대와 같고 5에서 틀림 0(상자 Linux: 정상 속도 0 오류, 10ms/키에서만 `super_editor` 오류). 틀린 경우 키 입력 순서·속도를 적는다.
- **보낼 파일**: `/tmp/ime_A.jsonl`, `/tmp/ime_B.jsonl`, 캡처, 시나리오별 결과표.

## E. 녹음 `.m4a`와 모바일 재생
**무엇을 보나**: macOS의 `record` 플러그인(`record_darwin`)이 AAC-LC `.m4a`를 만드는가, 규격이 상자 Linux 파일(AAC-LC, 44.1kHz mono, 브랜드 `M4A `)과 같은가, 휴대폰에서 재생되는가.
```bash
cd "$SPIKE_ROOT/mac/rec_mac" && flutter pub get && flutter run -d macos 2>&1 | tee ~/Desktop/spike-results/E_rec_run.log
```
창의 `Record`를 누르고 5초 말한 뒤 기다린다(마이크 권한 허용 창이 뜨면 허용). 결과는 `~/Desktop/rec_mac_result.txt`(`afinfo` 출력 포함), 파일은 `~/Desktop/rec_mac_test.m4a`.
```bash
cat ~/Desktop/rec_mac_result.txt | tee ~/Desktop/spike-results/E_afinfo.txt
ffprobe -hide_banner ~/Desktop/rec_mac_test.m4a 2>&1 | tee ~/Desktop/spike-results/E_ffprobe.txt   # ffmpeg를 설치한 경우
cp ~/Desktop/rec_mac_test.m4a ~/Desktop/spike-results/
```
- **확인 항목**: `aacLc supported=true`; `afinfo`의 `Data format`이 `aac`(`mp4a`)·표본률·채널; `afplay`가 소리를 냄; 파일 앞 `ftyp`가 `M4A `(`ffprobe`의 `major_brand`).
- **모바일 재생(손이 필요)**: ① `rec_mac_test.m4a`와 이 브랜치의 `m4a/plugin_rec.m4a`(무음)·`m4a/rec_44100_1.m4a`를 AirDrop으로 iPhone에 보내 파일 앱에서 재생. ② Android 기기가 있으면 같은 파일을 옮겨 재생(없으면 "없음"으로 기록). 재생되면 O, 안 되면 오류 문구.
- **보낼 파일**: `E_afinfo.txt`, `E_ffprobe.txt`, `rec_mac_test.m4a`, 모바일 재생 O/X 표.

## F. 미리보기: WKWebView (스파이크 c의 macOS 쪽)
**무엇을 보나**: `webview_flutter`(macOS는 `webview_flutter_wkwebview`)로 rslib 렌더 HTML+CSS+MathJax가 상자의 Chrome 기준 이미지(`c/evidence/chrome_ref.png`)와 같게 나오는가.
```bash
cd "$SPIKE_ROOT/mac/web_mac" && flutter pub get
CARD_FILE="$SPIKE_ROOT/c/ref/card.html" flutter run -d macos 2>&1 | tee ~/Desktop/spike-results/F_web_run.log
cat /tmp/web_mac_result.txt | tee ~/Desktop/spike-results/F_web_result.txt
```
창 화면을 캡처(`F_wkwebview.png`)해 `c/evidence/chrome_ref.png`와 비교: 한글, 굵은 `대한민국`, 수식 `e^{iπ}+1=0`(MathJax), `x^2`, 빨간 이미지, 클로즈 파란 굵은 글씨, `H₂O`. `c/ref/card.html`은 `package/es5/tex-chtml-full.js`를 상대 경로로 읽는다. 그 MathJax 번들은 용량이 커서 이 브랜치에 없다. `file://`로 못 읽으면 수식이 원문 `\( … \)`로 남는다 → 그 사실만 기록한다. 비교 기준 이미지는 `c/evidence/chrome_ref.png`다.
- **보낼 파일**: `F_wkwebview.png`, `F_web_result.txt`.

## G. 문서 편집기에서 복사할 때의 클립보드 구성 (Gina #7 ② 확인용) — *2026-11-18 추가*

> **갱신 메모(2026-11-18 KST, Dmitry)**: `GINA_EDITOR_SPIKES_REVIEW.md` #7 ②의 "문서 편집기에서 서식 있는 문단을 복사하면 HTML 옆에 렌더 이미지가 같이 오는 경우가 있다 [추정]"를 macOS 실제 앱으로 확인하는 항목이다. 이전 A~F 항목은 바뀌지 않았다. 이 항목도 Mac에서 실행해 본 적이 없다.

**무엇을 보나**: (1) 복사 직후 `NSPasteboard`에 어떤 형식이 실리는가(특히 HTML/RTF와 함께 `public.png`·`public.tiff` 같은 렌더 이미지가 같은 항목에 오는가, 아니면 별도 항목인가). (2) `super_clipboard` 프로브가 그것을 어떻게 읽는가. (3) Gina의 입력 우선순위(① `fileUri` → ② 비트맵(+텍스트 없는 HTML) → ③ HTML → ④ 평문)에서 어느 단계로 떨어지는가.

**G0. 형식 목록 도구**(프로브와 별개로 OS가 실제로 준 형식을 본다):
```bash
cd "$SPIKE_ROOT/e"
# 소스는 e/listclip.swift 에 있다. 복사할 때마다 실행하고, 그 전에 "## 케이스 이름" 줄을 남긴다.
echo "## case-name" >> ~/Desktop/spike-results/G_types.txt
swift "$SPIKE_ROOT/e/listclip.swift" | tee -a ~/Desktop/spike-results/G_types.txt
```
**G1. 케이스**(각각 복사 직후 위 두 줄, 이어서 V2 앱이 떠 있으면 `probe v2_super <이름>`; C절의 `probe` 함수 사용):
| 이름 | 앱 | 내용과 복사 방법 |
|---|---|---|
| `pages_text` | Pages | 굵은 글씨·색 글씨가 섞인 문단만 선택해 ⌘C |
| `pages_img` | Pages | 이미지 하나를 클릭 선택해 ⌘C |
| `pages_mixed` | Pages | 문단 + 인라인 이미지가 함께 든 영역을 드래그 선택해 ⌘C |
| `textedit_rtf` | TextEdit(서식 있는 텍스트) | 서식 문단 선택해 ⌘C |
| `textedit_rtfd` | TextEdit | 이미지를 끼워 넣은 문단 선택해 ⌘C(RTFD 첨부) |
| `gdocs_safari_text` | Google Docs(Safari) | 서식 문단만 복사 |
| `gdocs_safari_mixed` | Google Docs(Safari) | 문단 + 이미지가 든 영역 복사 |
| `gdocs_chrome_text` / `gdocs_chrome_mixed` | Google Docs(Chrome) | 위와 같음 |
| `word_text` / `word_mixed` | Word(설치된 경우) | 위와 같음. 없으면 "없음" |
| `notes_mixed` | 메모 | 문단 + 이미지 선택 복사 (참고용) |
| `finder_doc` | Finder | `.pages`/`.docx` 파일 자체를 ⌘C — 이때 `fileUri`가 오는지, 렌더 이미지가 같이 오는지 |
**기록할 것(케이스마다)**:
1. `G_types.txt`의 형식 목록과 항목 수. 주목: `public.html`, `public.rtf`, `com.apple.flat-rtfd`, `public.utf8-plain-text`, `public.png`, `public.tiff`, `com.apple.webarchive`, `public.file-url`, `dyn.*`(Office/Docs 전용).
2. 프로브 JSON의 `items`(항목 수), 항목별 `png`/`jpeg`/`html`/`text`/`fileUri`, `pngBytes`.
3. **이미지가 같은 항목에 HTML 옆으로 오는가**: `true/false`와, true면 이미지가 문서의 실제 이미지인지 **문단 전체를 렌더한 그림**인지(`pngBytes`로 저장해 열어 보려면 프로브 앱에 저장 기능이 없으니, 대신 `swift` 목록의 `public.png`/`public.tiff` 바이트 수와 `pbpaste -Prefer png > /tmp/x.png`로 꺼내 미리보기로 열어 확인).
4. **정책 적용 결과**: 위 순서에 대입해 어느 단계(① 파일, ② 비트맵, ③ HTML, ④ 평문)로 처리되는지 적는다. 기대: `*_text` 케이스(텍스트 있는 HTML + 렌더 이미지)는 ③이어야 한다(②의 "HTML에 보이는 텍스트가 없을 때만"). `*_img` 케이스는 ②. `finder_doc`은 ①이고 비이미지 파일이면 거부.
5. **어긋나는 케이스**(정책이 의도와 다르게 분류하는 경우): 예) 텍스트 있는 문단인데 HTML이 없고 렌더 이미지만 와서 ②로 가는 경우, 이미지 하나만 복사했는데 HTML에 `<img>`만 있어 ②로 가는지 ③으로 가는지. 형식 목록과 함께 그대로 적는다.
- **보낼 파일**: `G_types.txt`, `C_v2_super_<이름>.json`(위 케이스), 어긋나는 케이스 설명.
- 참고(상자에서 확인된 사실): `super_clipboard`는 파일만 복사해도 `png=true`로 보인다(Linux GTK). macOS에서 같은 현상이 나는지는 `finder_doc`/`finderfile`(C2)에서 함께 본다 [모름].

## 3. 정리
```bash
pkill -x e_app; pkill -x editor_proto; pkill -x rec_mac
cd ~/Desktop && zip -r spike-results.zip spike-results
```
`spike-results.zip`을 돌려주세요. 각 항목에서 "안 됐다"도 결과입니다 — 오류 로그와 함께 그대로 보내 주세요.

## 4. 이 절차가 하지 않는 것
서명·Hardened Runtime·공증·entitlement 점검(게이트 G3, 출시 직전 점검으로 미룸), 실제 사람 타이핑 지터 통계, iOS 시뮬레이터, 안정판이 아닌 Flutter master 시험.
