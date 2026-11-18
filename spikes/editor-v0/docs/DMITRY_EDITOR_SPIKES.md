# 에디터 v0 구현 전 스파이크 결과 (Dmitry)

> 저장소에 올린 위치는 `spikes/editor-v0/`이다. 본문의 `/workspace/editor-spikes`(이하 `ES/`)는 그 경로를 말한다. 아래 문장은 스파이크 당시 그대로다.

작성: Dmitry · 2026-11-18 KST · 초안(진행 중, 스파이크 한 개 끝날 때마다 갱신). 저장소·Notion·메시지에는 아무것도 쓰거나 보내지 않았다. 모든 산출물은 `/workspace/editor-spikes/`(이하 `ES/`)에 있다.
표기: **[확인]** 이번에 실행·열람해 직접 확인 / **[추정]** 근거에서 추론, 미검증 / **[모름]** 확인 수단 없음. 합격선 수치는 범위 문서 §7의 것을 따른다.

## 0. 환경과 한계

| 항목 | 값 |
|---|---|
| 상자 | Debian 13 x86_64, 8코어, Xvfb(가상 X11), 실제 GPU·오디오 장치·macOS 없음 |
| Flutter / Dart | 3.50.0 stable / 3.14.0 [확인] |
| Rust | rslib 핀 1.97.1(`rust-toolchain.toml`), 상자 기본 stable 1.100.0 [확인] |
| rslib | Anki 26.09.3 무수정. 번역 서브모듈 `ftl/core-repo`(49925703)는 복사본 `ES/anki-src/`에 채웠고 `ftl/qt-repo`는 빈 폴더로 둠 → 번역 문자열만 줄어듦, 코드는 무수정 [확인] |
| 입력기 | fcitx5 5.1.12 + fcitx5-hangul 5.1.6, ibus 1.5.32 + ibus-hangul 1.5.5 (실제 GTK 입력기 경로) [확인] |
| 못 한 것 | `hatto_store`·`rslib_bridge` 실제 소스는 접근 권한이 없어 열지 못했다(저장소 클론 불가) [확인]. 아래 래퍼·브리지는 **스탠드인**이며 해당 칸마다 표시했다. macOS는 전부 미실행(런북 참조) |
| 중단 이력 | 중간에 한 번 끊겼다가 이어서 했다. 결과 파일은 모두 `ES/`에 남아 있다 |

## 1. 요약

| 스파이크 | 판정 | 한 줄 |
|---|---|---|
| a `ChangeNotetype` guid | **PASS(스탠드인 래퍼 기준)** | 모든 시나리오에서 guid·note id·`note_map` 불변, 크래시 3지점+3만 노트 도중 강제 종료에서도 전부-또는-전무. 단 필드 순서 교환은 필드 값이 바뀌는데 저널 행 0 → v1 필드 LWW와 충돌(§2.4) |
| b 편집 표면 | **EditableText 직접 구현 쪽이 근거가 더 많음(잠정)** | 두 쪽 모두 코덱·토큰·골든 통과. `super_editor`는 안정판이 2024-06(0.2.7)에서 멈췄고 0.3.0-dev만 갱신, 빠른 입력 경합 발견. EditableText는 스타일 범위·Undo를 직접 짜야 함 |
| c 미리보기 | **Linux 웹뷰 두 가지 모두 불가, 네이티브는 부분 가능** | `webview_flutter_linux`는 WPE 2.52+ 필요(상자 2.48.3)로 실행 실패, `flutter_inappwebview` Linux beta는 빌드 실패. Flutter 네이티브(KaTeX)는 수식 14/20, 임의 템플릿 CSS 불가. rslib 렌더는 `\(..\)`를 그대로 내보냄 |
| d 한글 IME | **Linux 부분 PASS, macOS 미검증** | fcitx5/ibus 실제 조합: 정상 속도에서 두 표면 모두 정확. 초고속(10ms/키)에서 `super_editor`만 글자 누락·순서 뒤바뀜 재현 |
| e `super_*` 공존 | **Linux: G1·G2·G4·G5·G6·G8 PASS, G9 부분, G7·macOS 미결** | 도구체인 2벌(1.97.1+1.100.0) 공존, 심볼 충돌 0, 크기 +2.1MB. 대조군 `pasteboard`는 HTML+PNG 동시 읽기 불가, 20000² PNG에서 11초·1.4GB |
| m4a | **PASS(Linux 녹음 가능, 모바일 재생 규격 충족)** | `record_linux`가 parecord+ffmpeg로 AAC-LC `.m4a`를 만든다. 단 런타임에 ffmpeg·parecord 필요 |

## 2. 스파이크 a — `ChangeNotetype`과 guid·side DB

### 2.1 질문
`ChangeNotetype`이 쓰기 래퍼와 side DB를 낀 상태에서도 노트 guid와 `note_map`을 보존하는가. (범위 문서 §7 a)

### 2.2 실제로 한 것
- `ES/a/harness/`: Rust 단독 하네스(`spike_a`). `anki`·`anki_proto`를 경로 의존으로 무수정 rslib 26.09.3에 연결, rusqlite로 side DB(`deck_map`, `note_map`, `edit_journal`, `intent`)를 만들고 **래퍼 스탠드인**(가드 → intent 기록 → rslib 호출 → 검증 → intent 완료 → 저널 0행)을 구현했다. 래퍼 순서(가드 → intent → 호출 → 검증 → intent 완료)는 앞선 문서들의 설명을 따른 **내 재구성**이다 [추정]. `hatto_store` 코드는 못 열었다 [모름].
- rslib 호출은 `Collection::change_notetype_of_notes`(= protobuf 통로 `NotetypesService.ChangeNotetype`이 부르는 같은 함수 [확인: `rslib/src/notetype/service.rs`])를 직접 불렀다. protobuf 경로 자체는 앞선 napi 프로브로 확인했다(`/workspace/v0-kickoff/editor-probe/probe_editor.out`) [확인].
- 실행: `cd ES/a/harness && cargo build --release` 후 `target/release/spike_a`(인자 없이 기능 시나리오 S1~S6+크래시 3지점, `scale <N>`, `kill-during <dir> <ms>`, `render <dir> <out>`; 내부용 `crash-prepare|crash-run|crash-check`). 툴체인 1.97.1.

### 2.3 결과 (증거: `ES/a/evidence/`)
| 시나리오 | 결과 | 증거 |
|---|---|---|
| S1 Basic→Reversed(5노트, 덱 3개에 분산) | PASS: guid·note id·카드 id 불변, `notetype_id`=요청값, `note_map` 불변, 저널 +0, intent 완료 1·미완료 0. 새 카드의 덱 = 같은 노트 기존 카드의 덱(5/5 일치), 노트 `mtime`은 5개 모두 갱신 | a-scenarios.log |
| S1b 직후 Undo/Redo | PASS: Undo 후 mid 원복·guid 유지, Redo 후 다시 변경. **래퍼가 `col.undo()`를 감싸지 않으면 side DB는 notetype 변경 취소를 알 수 없음**(M1 대조 필요) | 동일 |
| S2 Reversed→Basic(템플릿 삭제) | PASS: 카드 10→5, guid 유지 | 동일 |
| S3 Basic↔Cloze | PASS | 동일 |
| S4 필드 순서 교환 | guid·id 불변 PASS. **필드 값이 3노트에서 바뀌었는데 저널 행 0** [확인]. v1 필드 단위 LWW에서는 이 변경이 동기화에서 보이지 않는다 | 동일 |
| S5 다른 노트타입 섞기 | 가드가 호출 전 거부(N3). **rslib 단독은 수락**하고 cloze 노트의 mid를 바꿔 버림 [확인] | 동일 |
| S6 낡은 `current_schema` | 가드 거부. rslib 단독도 `schema changed`로 거부 [확인] | 동일 |
| 크래시 3지점(intent 뒤 / rslib 뒤 / 완료 전) | PASS: 재시작 복구가 미완료 intent를 각각 폐기·완료 처리, 매핑 대조 일치, guid 유지 | a-scenarios.log |
| 5,000노트 | rslib 61ms, 래퍼 합계 126ms, 최대 RSS 25MB | a-scale5000.log |
| 30,000노트 | rslib 470ms, 래퍼 합계 902ms(검증 포함), 역방향 967ms, RSS 88MB. 기본 상한 5,000이면 가드가 거부 | a-scale30000.log |
| 자식 프로세스 SIGKILL(3만 노트, 1.15~2.2초 9개 시점) | PASS 9/9: 전부-또는-전무(일부만 바뀐 상태 0건), 매핑 일치. 1.15~1.45초는 셋업 중(래퍼 호출 전), 1.55~1.8초 3곳은 intent 기록 뒤 rslib 호출 중(노트는 전부 old, 복구가 intent 폐기), 2.2초는 완료 뒤(전부 new) | a-kill-during.log |

### 2.4 게이트 판정과 해석
- 합격 기준(범위 §7 a): guid·id 불변, `note_map` 불변, 재조회 `notetype_id`=요청, 저널 0, intent 완료 1, 매핑 대조 일치, 가드가 N3·낡은 스키마를 호출 전 거부, 종료 뒤 복구 → **전부 PASS** (스탠드인 래퍼) [확인].
- **발견 1(결정 필요)**: "저널 행 0"은 필드 매핑이 항등일 때만 맞다. 필드 순서 교환·삭제는 필드 값 자체를 바꾼다. 합격 기준 "저널 0행"을 "항등 매핑이면 0행, 아니면 노트별·필드별 저널 행 필요"로 고쳐야 한다. 담당: Gina(저널 op 어휘), Justin(필드 순서 교환을 v0에 넣을지).
- **발견 2**: 래퍼가 Undo/Redo를 `intent`로 감싸야 한다. 아니면 M1 대조로만 잡힌다.
- **발견 3**: `note_ids`가 `old_notetype_id` 소속인지 rslib은 검사하지 않는다 → 가드 필수(앞선 N3를 실행으로 재확인).
- 허용목록에 `change_notetype`을 넣어도 된다는 근거: 이 스파이크 범위에서 guid·`note_map` 파손 0건 [확인]. 단 실제 `WriteWrapper`로는 미검증 [모름] → 저장소 작업 후 같은 시나리오를 Dart 호스트 테스트로 옮겨야 한다.
- 한계: 호출이 약 0.5초라 SIGKILL이 rslib 트랜잭션 **안**에 들어간 것은 3회다(1.55~1.8초 구간). 기본 상한 5,000은 경계값이 포함이라 정확히 5,000건은 통과한다. 크래시 3지점은 자식 프로세스가 스스로 SIGKILL(종료 코드 137)하는 주입이다. 프로세스 종료는 보지만 전원 차단·디스크 쓰기 순서(fsync)까지는 보지 못한다 [모름].

## 3. 스파이크 b — 편집 표면

### 3.1 질문
`super_editor`와 `EditableText` 직접 구현 중 어느 쪽인가. (Anki 필드 HTML 왕복, 클로즈, 미디어·MathJax 토큰, Undo, 선택, 골든 테스트 가능성, 라이선스, 유지보수)

### 3.2 실제로 한 것 (`ES/b/proto/`, Flutter 3.50, `flutter test`로 헤드리스 Linux)
- 공통 코덱 `lib/field_codec.dart`: Anki 필드 HTML ↔ 구간 모델(굵게·기울임·밑줄·위/아래첨자·색상 + 불투명 토큰 `<img>`·`[sound:]`·`\(..\)`·`\[..\]`·미지원 요소 원문). 코덱은 두 프로토타입이 공유하므로 **코덱 충실도는 표면 비교가 아니다**.
- 프로토타입 A `lib/proto_super.dart`: `super_editor 0.3.0-dev.52`(2026-06-11)의 `MutableDocument`+`AttributedText`(플레이스홀더로 토큰)+`SuperEditor`. 프로토타입 B `lib/proto_editable.dart`: `EditableText`+자체 `TextEditingController`(스타일 범위 추적, `WidgetSpan`으로 토큰).
- 코퍼스 33건(`lib/corpus.dart`): 한글·NFD 한글·굵게/중첩/색/첨자·`<br>`·`<img>`·`[sound:x.m4a]`·MathJax·클로즈·엔티티·`<div>`·목록·표·링크·`<font>`·`<script>`·`onerror` 등.
- 명령: `cd ES/b/proto && flutter test test/codec_test.dart test/super_test.dart test/editable_test.dart`(전부 통과, 골든 2장 `goldens/`).
- 버전 사실: pub.dev에서 `super_editor` 안정판 최신은 0.2.7(2024-06-11), 0.3.0-dev.45~52(2025-12~2026-06)만 갱신 중, MIT, pub points 60, 좋아요 782 [확인: pub.dev API].

### 3.3 결과 (증거: `ES/b/evidence/`)
| 항목 | A `super_editor` | B `EditableText` 직접 |
|---|---|---|
| HTML 왕복(코덱 출력 보존) | 33/33, 의미 동일 33/33 | 33/33, 33/33 |
| 코덱 자체 충실도 | 정확 25 / DOM 동등 32 / 차이 1(중첩 스타일이 구간으로 쪼개짐, 의미 동일) / 불투명 원문 9건. `<script>`·`onerror`는 그대로 보존됨(정화 필요) — b-codec-roundtrip.txt | 같음 |
| 내장 HTML 직렬화 | `Document.toHtml()`은 `<p>`/`<strong>`로 감싸고 줄바꿈이 `\n`: Anki 필드에 못 씀. **HTML 파서는 없음**(직렬화만) [확인] → 코덱을 어차피 직접 써야 함 | 해당 없음 |
| 토큰 원자성(뒤에서 Backspace) | PASS(`\uFFFC` 1글자) | PASS |
| 클로즈 감싸기 | PASS, 되돌리기 1단계로 복원 | PASS(텍스트 삽입, 스타일 범위 자동 이동) |
| Undo | 내장 이력 있음. 입력은 글자 단위로 쌓임(병합 정책 조정 필요), 서식 토글은 1단계 [확인: super_test A4] | **내장 `UndoHistoryController`는 텍스트만 되돌려 스타일 범위가 어긋남**(굵게가 사라짐) [확인: editable_test B4]. 스냅샷 방식 자체 이력으로 해결 가능(검증: 굵게 복원 PASS)하나 직접 짜야 함 |
| 선택·서식 토글 | 내장 `ToggleTextAttributionsRequest` | 직접(`toggle()` 40줄). 삽입 시 앞 글자 서식 상속은 구현함 |
| 골든(Linux, 한글 폰트 로드) | PASS 재현(`super_a2.png`) | PASS 재현(`editable_b2.png`) |
| 코드량 | 89줄(+ 내부 복잡도는 패키지) | 128줄 |
| 의존성 | 프로토타입 프로젝트 전체 잠금 파일은 106개 패키지(두 표면·`html`·테스트 도구 합산, 표면별 차이는 미측정) [확인: pubspec.lock] | `html`(코덱 공용) 외 추가 없음 |
| 라이선스 | MIT [확인] | Flutter BSD |

### 3.4 해석과 권고(Dmitry 의견)
- [확인] 두 표면 모두 Anki 필드 HTML을 **코덱을 거치면** 의미 동일하게 왕복한다. 표면 선택의 차이는 코덱이 아니라 편집 동작(Undo, 서식 상속, IME)과 유지보수에서 난다.
- [확인] `super_editor`의 안정판이 2년 반 멈춰 있고 쓸 수 있는 버전은 `0.3.0-dev`뿐이다(게이트 G9 유사 위험). 프리릴리스 의존은 API 변경 위험이 있다 [추정].
- [확인] 빠른 입력 경합(§스파이크 d)은 `super_editor`에서만 재현됐다.
- [추정] EditableText 쪽 비용은 Undo 자체 이력·서식 범위 유지·다중 줄 블록(목록 등) 확장이다. 필드는 대부분 한 줄~몇 줄 인라인 HTML이라 v0 범위에서는 감당 가능하다고 본다(근거: B 프로토타입 128줄로 위 시험을 통과).
- **권고(잠정)**: v0 편집 표면은 `EditableText` 기반 직접 구현 + 공통 코덱. `super_editor`는 블록 편집(목록·표)이 v1에서 필요해질 때 재평가. 결정 필요: Justin(블록 요소 v0 포함 여부), Gina(프리릴리스 의존 금지 정책).
- 열린 문제: IME 조합 중 서식 토글, 큰 필드 성능, 접근성(스크린리더), macOS 시각 확인은 시험하지 않았다 [모름].

## 4. 스파이크 c — 미리보기 표면

### 4.1 질문
카드 템플릿 렌더 결과(HTML+CSS+MathJax)를 보여 줄 미리보기를 웹뷰로 할지 Flutter 네이티브로 할지. Linux 웹뷰 선택지가 실제로 동작하는가, 골든 테스트가 되는가.

### 4.2 실제로 한 것
1. **rslib 출력 덤프**: 스파이크 a 하네스에 `render` 하위 명령을 넣어 `render_existing_card`(= `RenderExistingCard`가 부르는 함수)로 Basic 1장·Cloze 2장을 렌더. 한글·굵게·`<sub>`·색 span·`\(..\)`·`\[..\]`·`<img>`·`[sound:]`·클로즈 비활성/활성 포함. `cd ES/a/harness && ./target/release/spike_a render /tmp/r ES/c/evidence/rslib_render.txt` → `ES/c/evidence/rslib_render.txt` [확인].
2. **기준 렌더(참조)**: 같은 HTML+CSS를 Anki 리뷰어와 같은 방식(`mathjax@3.2.2` `tex-chtml-full`)으로 Chrome headless에서 렌더 → `ES/c/evidence/chrome_ref.png` [확인]. 이것이 "웹뷰라면 이렇게 나온다"의 대리 기준이다(웹뷰 자체가 아니라 Chromium이라는 점 주의).
3. **Flutter 네이티브**: `ES/c/native_app/`에 `flutter_widget_from_html_core 0.17.4`(HTML/CSS 일부) + `flutter_math_fork 0.7.4`(KaTeX 계열 수식)로 미리보기 렌더러(`lib/native_card.dart`, 약 45줄). `flutter test --update-goldens` → `ES/c/evidence/native_flutter.png` (골든 `native_app/goldens/native.png`) [확인].
4. **Linux 웹뷰 두 가지 실제 빌드·실행**: (가) `webview_flutter 4.14.1` + `webview_flutter_linux 0.1.0-dev.2`(WPE WebKit) 빌드 후 Xvfb에서 실행 → `ES/c/evidence/webview_wpe.png`, `web_app.log`. (나) `flutter_inappwebview 6.2.0-beta.3` + `flutter_inappwebview_linux 0.1.0-beta.1`(WebKitGTK) 빌드 → `ES/logs/c-iaw-build.log`.

### 4.3 결과
| 항목 | 결과 |
|---|---|
| rslib 렌더 출력 | HTML 문자열 + CSS 문자열. **MathJax 구분자 `\(..\)`·`\[..\]`는 변환 없이 그대로** 나오고 `latex_svg=false`(LaTeX `[latex]`가 없을 때). 클로즈는 `<span class="cloze" data-cloze=... data-ordinal=...>`로 나옴. 즉 렌더 후 수식 처리는 표면(웹뷰 또는 Dart)이 해야 한다 [확인] |
| Chrome+MathJax 기준 | 수식(`e^{iπ}+1=0`, `x^2`), 한글, 클로즈 색(`.cloze` 파랑 굵게), `<hr id=answer>`, 이미지 모두 정상. `[sound:...]`는 글자 그대로 남는다(Anki는 렌더 전에 AV 태그를 따로 뽑으므로 표면이 처리할 일) [확인] |
| (가) `webview_flutter_linux` | **실패**. 빌드는 됨(사전 빌드 브리지 사용). 실행하면 화면에 `Linux WebView failed ... undefined symbol: webkit_context_menu_get_position`. 이 플러그인은 **WPE WebKit 2.52 이상 + WPE Platform**을 시스템에 요구하는데(README 확인) 이 상자의 `libwpewebkit`은 2.48.3. 브라우저 엔진을 번들하지 않으므로 사용자 시스템에 WPE 2.52+ 설치가 전제된다 [확인]. 또한 이 패키지가 `irondash_engine_context`를 끌고 와서 번들에 `libirondash_engine_context_plugin.so`가 들어온다 [확인: bundle/lib] |
| (나) `flutter_inappwebview` Linux | **빌드 실패**: `in_app_webview.cc:6214: use of undeclared identifier 'webkit_web_view_get_theme_color'`. 상자의 `webkit2gtk-4.1`은 2.54.0, 헤더에 해당 선언이 없다. 안정판 6.1.5에는 Linux가 없고 Linux는 `0.1.0-beta.1`(2026-02-04)이다 [확인]. 원인이 WebKitGTK 버전 불일치인지 플러그인 버그인지는 모름 [모름] |
| Flutter 네이티브 | 한글·굵게·`<sub>`·색·클로즈 색·`<hr>`·`<br>`·기울임 OK, 수식 두 개 OK(KaTeX 폰트 로드 시). 골든 테스트 가능 [확인]. 이미지는 골든에서 미확인(테스트 바인딩에서 파일 이미지 비동기 디코딩 미해결) [모름]. 20회 재빌드 179ms(테스트 바인딩 기준, 실측 아님) |
| 네이티브 수식 범위 | `flutter_math_fork`(KaTeX 문법): MathJax 대비 20개 표현 중 14개 파싱 성공. 실패는 `\ce`(mhchem), `\require`, `\bbox`, `\unicode`, `\href`, `\newcommand{\R}` 재정의(KaTeX가 `\R`을 미리 정의). `aligned`·`array`·`pmatrix`·`\text{한글}`·`\cancel`·`\color`·`\xrightarrow`는 통과 — `ES/c/evidence/native_tex_coverage.txt`. MathJax 쪽 20/20은 `tex-chtml-full`이 해당 확장을 포함한다는 문서에 근거한 [추정] |
| 미지원 CSS | 네이티브는 카드 템플릿의 임의 CSS(`<style>`, 클래스 규칙, 폰트, `float`, 미디어쿼리)를 해석하지 못한다. 위 렌더러는 `.cloze`와 `hr`만 하드코딩했다 [확인: native_card.dart]. 사용자 노트타입 CSS를 그대로 보여 주려면 웹뷰가 필요하다 [추정] |

### 4.4 판정과 권고(Dmitry 의견)
- **확정된 것**: (1) 미리보기는 렌더 후 수식 처리를 직접 해야 한다. (2) 임의 템플릿 CSS의 충실한 표시는 Flutter 네이티브로는 불가능하다. (3) Linux 웹뷰는 **이 상자에서 두 선택지 모두 동작하지 않았다**. 따라서 "Linux에서 웹뷰 골든" 경로는 지금 근거가 없다.
- **권고(잠정)**: v0 미리보기를 "필드 편집 확인용" 수준으로 한정하면 Flutter 네이티브(수식은 KaTeX 부분집합, 실패 시 원문 `\(..\)` 표시 + 경고) + 임의 CSS는 무시가 현실적이다. 사용자 노트타입 CSS의 충실한 미리보기는 macOS WKWebView(`webview_flutter_wkwebview 3.27.2`)로만 제공하고 Linux에서는 비활성화하는 안이 있으나 **Mac에서의 검증이 없어** 런북 C 항목으로 넘긴다. 결정 필요: Justin(미리보기 충실도 요구 수준), Gina(웹뷰 의존을 플랫폼 서비스 층 인터페이스로 둘지).
- 다시 시험할 조건: WPE 2.52+가 들어간 배포판(Debian testing 등)에서 (가) 재시도, WebKitGTK 헤더 버전별로 (나) 재시도. 시간 상한 때문에 하지 않았다.
- 골든 안정성: Linux 골든은 폰트 로드 후 재현됐다(스파이크 b와 같음). 웹뷰는 텍스처 렌더라 `flutter test` 골든 대상이 아니고 화면 캡처 비교가 되어 불안정하다 [추정].

## 5. 스파이크 d — 한글 IME

### 5.1 질문
한글 2벌식 조합이 Flutter 데스크톱 입력 경로에서 글자를 중복·소실시키는가.

### 5.2 실제로 한 것 (`ES/d/`)
- 실제 프로세스: 위 프로토타입을 `flutter build linux --debug`로 빌드해 Xvfb(:99) + openbox + dbus 세션 + **fcitx5(hangul)** 또는 **ibus(hangul)** 데몬을 띄우고, `GTK_IM_MODULE=fcitx|ibus` 상태에서 `xdotool key`로 두벌식 키를 쳤다. 앱은 상태 변화마다 JSON 한 줄을 로그로 남긴다(`app.jsonl`). 스크립트 `ES/d/run_ime.sh <fcitx5|ibus> <a|b> <시나리오>`. a=`super_editor`, b=`EditableText`.
- 시나리오: basic(`한글 데이터`), enter(조합 중 Shift+Enter), arrow(조합 중 ←), bs(Backspace 3번으로 자모 분해), toggle(Ctrl/Shift+Space로 영문 전환 후 복귀), fast(키 간격 10ms), med(40ms), med80(80ms).
- 헤드리스 재생: `flutter test`에서 조합 델타열(ㅎ→하→한→한ㄱ→한그→한글)을 직접 보내 두 표면을 검증(`ES/b/evidence/*.txt` A6·B6). 이 재생은 내가 만든 열이므로 [추정]이고, 실제 입력기가 보낸 열은 `ES/d/evidence/fcitx5_b_basic/app.jsonl`에 기록돼 같은 패턴(삽입→치환→치환→조합 해제→다음 글자 삽입)이다 [확인].

### 5.3 결과 (`ES/d/evidence/`)
| 시나리오 | fcitx5·A | fcitx5·B | ibus·A | ibus·B |
|---|---|---|---|---|
| basic `한글 데이터` | OK | OK | OK | OK |
| enter (`한` 확정 후 줄바꿈 `글`) | OK | OK | OK | OK |
| arrow (`글한`) | OK | OK | OK | OK |
| bs (빈 문자열) | OK | OK | OK | OK |
| toggle (`하ab하`) | OK | OK | OK | OK |
| med80 (80ms/키) ×3 | 3/3 OK | 3/3 OK | 미실행 | 미실행 |
| med (40ms/키) ×3 | 1/1 OK(2회는 하네스 기동 경합으로 로그 없음) | 3/3 OK | 미실행 | 미실행 |
| fast (10ms/키) | `한글데이 `(2/2 틀림, 글자 `터` 누락·공백 위치 이동) | 3/3 OK | 1 OK, 2 틀림(`한글데 이터`, `한글데이 `) | 2/2 OK(1회 기동 경합) |

- 초고속에서 `super_editor`만 틀린다 [확인]. 10ms 간격은 약 100키/초라 사람 입력 속도를 넘는다. 40ms(25키/초)부터는 정상이다. 따라서 일반 사용에서의 위험은 낮다고 본다 [추정]. 원인은 `super_editor` IME 델타 처리 순서로 보이나 코드를 파지 않았다 [모름].
- 하네스 한계: 앱 기동 직후 첫 키가 먹히지 않는 기동 경합이 몇 번 있었고 그 회차는 표에서 제외·표기했다. ibus는 첫 실행에서 한글 모드가 꺼져 있어(ibus-hangul 기본) Shift+Space를 선행해야 했다.
- **검증 못 한 것**: macOS(Korean 2-Set 입력 소스), fcitx5의 다른 모드(Hanja 변환), 일본어/중국어 IME, Wayland, 실제 사람의 타이핑 지터. 이는 런북 항목이다.
- 조합 중 복사·붙여넣기, 마우스 클릭으로 조합 커서 이동은 시험하지 않았다 [모름].

### 5.4 알려진 이슈 인용 (웹 검색, 검색 요약 + 일부 본문 확인)
- super_editor #2757 — "Korean IME: Character duplication when pressing Shift+Enter in composing state"(macOS 15.5 + Chrome, 열림): https://github.com/Flutter-Bounty-Hunters/super_editor/issues/2757. 우리 Linux 시험(`enter` 시나리오, fcitx5·ibus 모두)에서는 재현되지 않았다 [확인]. macOS에서는 런북에서 재현 시도해야 한다 [모름].
- flutter/flutter #92060 — macOS에서 조합 중 필드를 옮기면 입력 중복(2022-03 `engine#31849`로 수정됨, 닫힘): https://github.com/flutter/flutter/issues/92060 [확인: 이슈 본문].
- flutter/engine PR #31813 — Linux CJK(한글) 조합 중 커밋 직후 상태가 조합 종료로 오해되는 문제 수정: https://github.com/flutter/engine/pull/31813 [확인: PR 본문]. 이 수정이 Linux 한글 정상 동작의 근거로 보인다 [추정].
- flutter/flutter #91798 — Linux에서 iBus/fcitx 켜면 입력이 안 되는 사례(열림, 2021 보고·2024 갱신): https://github.com/flutter/flutter/issues/91798. 우리 환경(Flutter 3.50, GTK 입력기 경로)에서는 재현되지 않았다 [확인].
- flutter/flutter #172270 — Windows Flutter 데스크톱에서 한글 조합 중 커서 위치 이상(닫힘): https://github.com/flutter/flutter/issues/172270. Windows는 범위 밖이므로 참고만.
- flutter/flutter #156380 — 웹(macOS Chrome)에서 한글 조합 중 Tab으로 포커스가 한 칸 건너뜀: https://github.com/flutter/flutter/issues/156380. 웹 에디터는 범위 밖.
- ghostty #6779 — fcitx5-hangul은 글자 사이 이동 때 preedit 종료/시작 없이 preedit만 갱신한다는 관찰: https://github.com/ghostty-org/ghostty/pull/6779. Flutter에는 직접 관련 없음, 입력기 동작 설명으로만 [추정].
- 결론: **한글 조합이 macOS에서 안전하다는 근거는 없다**. 이 보고서의 IME 결과는 Linux 한정이다.

## 6. 스파이크 e — `super_clipboard`·`super_drag_and_drop`과 `rslib_bridge` 공존

### 6.1 질문
`super_clipboard 0.9.1`+`super_drag_and_drop 0.9.1`(cargokit로 Rust 빌드)이 `rslib_bridge`(FRB native-assets, rslib 링크)와 한 앱에서 빌드·로드·실행되는가. 게이트 G1~G9(Gina, `GINA_EDITOR_V0_DECISIONS.md` §4). **G3(서명·공증)은 범위에서 제외**. 붙여넣기 정책은 `GINA_EDITOR_V0_PASTE.md`(비트맵 허용, 원본 파일명 미사용).

### 6.2 실제로 한 것 (`ES/e/`, Linux x86_64 release 빌드)
네 변형을 같은 구조로 만들었다. 모두 `flutter_rust_bridge 2.13.0`, native-assets 방식(`hook/build.dart`), 상자의 Flutter 3.50.
| 변형 | 구성 |
|---|---|
| V0 `e_app` | FRB 기본(rslib 없음) — 기준선 |
| V1 `v1_rslib` | V0 + 무수정 rslib 26.09.3 링크(`rust-toolchain.toml` 1.97.1), 시작 시 컬렉션 열고 노트 1개 추가하는 `rslib_smoke` |
| V2 `v2_super` | V1 + `super_clipboard`·`super_drag_and_drop`(+ `DropRegion` 마운트, 클립보드 읽기 프로브) |
| V3 `v3_control` | V1 + 대조군 `pasteboard 0.6.1`·`desktop_drop 0.9.2` |
클립보드 시험: Xvfb에서 상대 클립보드 소유자를 `ES/e/clipset.c`(GTK3, 파일 관리자·브라우저 복사의 대용)로 띄워 케이스별로 X11 CLIPBOARD를 점유하고, 앱 프로브가 읽은 결과를 JSON으로 기록(`ES/e/runprobe.sh v2_super|v3_control`). 케이스: 파일 복사(uri-list+gnome-copied-files), 텍스트만, 파일+텍스트, PNG, PNG+HTML(브라우저식), 잘린 PNG, 무작위 5KB, 20000×20000 PNG(438KB), 120MB 더미 PNG. (이전 시도는 Python GTK 바인딩에 `set_with_data`가 없어 빈 결과였고, C로 다시 만들어 해결했다.) 증거: `ES/e/evidence/v2_super/*.json`, `v3_control/*.json`, `summary.txt`, `ES/e/evidence/size/`.

### 6.3 결과 — 게이트별
| 게이트 | 판정 | 근거 |
|---|---|---|
| G1 클린 빌드, 툴체인 충돌 없음 | **Linux PASS(조건부) / macOS 미실행** | V1·V2 `flutter build linux --release` 성공(`ES/logs/e-v1-build.log`, `e-v2_super-build.log`). 단 **한 앱에 Rust 툴체인 두 벌**이 쓰였다: FRB는 `rust-toolchain.toml` 핀 **1.97.1**, `super_native_extensions`는 cargokit가 rustup 기본 **1.100.0**으로 빌드(두 `.so`의 `.comment`에서 `rustc 1.100.0`/`1.97.1` 확인) [확인]. "충돌 없음"은 빌드가 성공했다는 뜻이고, **핀을 포함한 충돌이 없다**는 합격 문구에는 못 미친다: cargokit는 핀을 따르지 않고 기본 툴체인을 쓰므로 CI에서 `rustup default`가 바뀌면 `super_*` 쪽이 조용히 달라진다 → 권고: CI에서 `rustup default 1.97.1` 고정 또는 `cargokit_options.yaml`/툴체인 파일 도입 검토 [추정]. 빌드 시간은 V2 약 3.5분(병렬 빌드 중) |
| G2 한 프로세스에서 각자 호출 | **Linux PASS / macOS 미실행** | V2 한 프로세스에서 `rslib ok: notes=1 guid=...`와 클립보드 읽기 모두 성공(`ES/e/evidence/v2_super/rslib.txt`, 프로브 JSON). **심볼 충돌 없음**: `libsuper_native_extensions.so` 내보낸 심볼 6개(`irondash_*`, `super_native_extensions_*`), `librust_lib_e_app.so` 25개(FRB), 교집합 0 [확인: `nm -D`] |
| G3 서명·공증 | **제외(범위에서 뺌)** | |
| G4 파일 URI와 텍스트 분리 | **Linux PASS** | 파일 복사: `fileUri=true`, `text=false`, 값 `file:///.../red.png`. 텍스트만: `fileUri=false`, `text=true`. 둘 다: `fileUri=true`·`text=true`, 각 값 분리됨. **주의**: 파일만 복사했는데 `Formats.png`도 `true`로 보이고 PNG 155바이트가 읽혔다(플러그인이 파일 내용을 이미지로 노출) [확인]. 붙여넣기 정책 구현은 **fileUri를 먼저 보고 png는 그다음**으로 우선순위를 둬서 같은 이미지가 이중 처리되지 않게 해야 한다. 이미지가 아닌 파일 확장자·비이미지 파일 동작은 시험하지 않았다 [모름]. 대조군 `pasteboard`도 `files`와 `text`를 분리한다 |
| G5 HTML+PNG 동시 | **Linux PASS / macOS 브라우저 3종 미실행** | PNG+HTML 클립보드에서 `html=true`(`<meta charset="utf-8"><img src="https://example.com/a.png" ...>`)와 PNG 155바이트를 한 번에 읽음. **대조군 `pasteboard`는 같은 상황에서 `html=null`, 이미지만** → 이 게이트에서 `super_clipboard`가 우위 [확인]. Chrome/Safari/Firefox 실제 복사는 Linux 상자에서 재현할 수 없어(브라우저가 클립보드에 어떤 타입을 넣는지는 `clipset` 합성 데이터일 뿐) 목록은 런북으로 [모름] |
| G6 실패 격리 | **Linux PASS(플러그인 단계) / 디코딩 단계 정책 필요** | 잘린 PNG(77B)·무작위 5KB·20000×20000 PNG·120MB 데이터 모두 프로세스 생존(`summary.txt` 전부 `alive`). `super_clipboard`는 **바이트를 디코딩하지 않고 그대로 전달**(120MB는 0.5초, RSS 약 221→467MB로 +247MB). 따라서 깨진 비트맵으로 `super_*`가 죽는 경로는 안 나왔다 [확인]. **대조군 `pasteboard`는 GdkPixbuf로 디코딩·재인코딩해서 20000×20000에서 11.4초, RSS 약 1.39GB**(디컴프레션 폭탄 취약), 120MB 가짜 PNG는 null, 잘린 PNG는 180바이트로 "복구"해 돌려줌 [확인]. 결론: 크기 상한은 읽기 **전**에 `DataReaderFile.fileSize`(널 가능)로 걸고, 널이면 스트림을 상한까지만 읽는 식이 필요하다(우리 프로브는 `readAll`이라 +247MB가 났음). IHDR 크기 검사 후 Flutter 디코딩을 해야 한다 — 이 Dart 쪽 가드는 만들지 않았다 [모름]. `panic=abort`로 죽는 입력(의도적 Rust 패닉)은 유도하지 못했다 [모름] |
| G7 irondash#81 / #570 재현 | **미결(macOS 전용)** | 두 이슈 모두 macOS 시작 시 크래시(`irondash_engine_context` 비동기 등록 경합, `getFlutterView`에 nil 검사 없음). 이슈 #81은 2026-10-20에도 열림, 우회 커밋(`orestesgaolin/irondash@220bd91`, PR #264 참조)이 있고 nil 검사 추가로 두 번째 엔진 창 크래시도 7/7→0/10으로 줄었다는 댓글이 있다 [확인: 이슈 본문]. Linux에서는 해당 코드 경로가 없어 재현 불가 → **Mac에서 `DropRegion`을 시작 화면에 둔 V2를 20회 기동하는 시험**을 런북 B에 넣었다. 참고: `irondash_engine_context 0.6.0-dev.0`(2026-08-05)이 있다 |
| G8 바이너리 출처·MIT | **Linux PASS** | 사전 빌드 없이 소스 빌드: cargokit 문서상 `cargokit_options.yaml`이 없고 rustup이 있으면 소스 빌드(`docs/precompiled_binaries.md`), 실제로 상자 빌드에서 `cargo build --manifest-path .../super_native_extensions-0.9.1/rust/Cargo.toml`이 rustc 1.100.0으로 돌았다 [확인]. G1·G2 재통과는 위 V2가 곧 소스 빌드 결과다. MIT 고지 포함은 앱 packaging 작업이라 미실행 [모름]. 오프라인 CI에서 crates 소스 확보(vendoring)는 시험 안 함 [모름] |
| G9 유지보수 | **부분 PASS** | pub.dev: `super_clipboard`·`super_drag_and_drop`·`super_native_extensions` 안정판 0.9.1(2025-06-11), 0.10.0-dev.1·dev.2가 2026-08-07, `irondash_engine_context 0.6.0-dev.0`이 2026-08-05 — "0.10 개발이 진행 중"이라는 사실은 확인(안정판 전망 문서는 없음 → 이 근거가 G9의 "문서"로 인정되는지 Gina 판단 필요) [확인]. 포크 계획 문서는 없음 |

### 6.4 크기 (G2 부속, 합격선 20MB 증가 아님 — Linux x86_64 release 번들)
| 변형 | 번들 | 기준선 대비 |
|---|---|---|
| V0 FRB만 | 22.9MB | — |
| V1 +rslib | 36.4MB | +13.5MB (`librust_lib_e_app.so` 16.1MB) |
| V2 +`super_*` | 38.6MB | V1 대비 **+2.1MB** (`libsuper_native_extensions.so` 1.7MB 포함) |
| V3 +`pasteboard`+`desktop_drop` | 36.8MB | V1 대비 +0.4MB |
macOS 유니버설(arm64+x86_64)은 미측정 [모름]; 대략 두 배로 보면 `super_*`가 +4MB 안팎일 것이라는 추정 [추정].

### 6.5 판정과 권고(Dmitry 의견)
- G3을 빼고 Linux에서 볼 수 있는 게이트(G1·G2·G4·G5·G6·G8)는 통과했다. G7과 G5의 macOS 브라우저 3종, G1·G2의 macOS, 크기 측정은 Mac 없이 닫을 수 없다 → **채택 확정은 보류, 런북 B 후**. 현재 증거로는 F1 후퇴(`pasteboard`)보다 `super_clipboard`가 낫다: 대조군은 HTML+PNG 동시 읽기(G5)를 못 하고 디코딩 폭탄에 취약(G6).
- 위험 3가지: (1) 툴체인 2벌(재현성) (2) 안정판 정체와 irondash macOS 크래시(Mac 확인 전 [모름]) (3) 파일 복사 때 PNG로도 보이는 동작에 맞춘 우선순위 규칙.
- 드래그앤드롭은 `DropRegion`이 Linux에서 마운트되는 것까지만 확인했고 실제 파일 끌어놓기(Xvfb에서 XDND 시뮬레이션)는 못 했다 [모름] → 런북 B의 Finder 끌어놓기.
- 붙여넣기 정책과의 정합(확인): Gina 정책의 상한(파일 20 MiB, 50 Mpx·한 변 16384, 헤더 해석 후 디코드, 격리 isolate에서 청크 읽기 — `GINA_EDITOR_V0_PASTE.md` P3·P5·표)은 이번 프로브의 최악 케이스를 모두 디코드 전에 거른다: 20000×20000(한 변 16384 초과·400 Mpx)·120MB(20 MiB 초과)는 거부 대상이다. `DataReaderFile`은 `fileSize`(널 가능)와 `getStream()`(한 번만 호출, `onFile` 콜백 안에서)을 제공해 청크 읽기가 가능하다(`super_clipboard-0.9.1/lib/src/reader.dart`). 우리 프로브가 쓴 `readAll`은 정책 위반 방식이었고 그래서 +247MB가 났다. **정책의 P3~P5 구현은 이번에 만들지 않았다** [모름].
- 파일 이름: `DataReaderFile.fileName`이 노출되지만 정책상 원본 파일명은 쓰지 않으므로 읽지 않는다. 래퍼가 이름을 만드는 `paste-<sha1>.<확장자>` 규칙은 이번 범위 밖.

## 7. 녹음 형식 `.m4a` 점검

### 7.1 질문
(1) Linux에서 Flutter로 `.m4a`(AAC-LC)를 녹음할 수 있는가. (2) 그 파일이 Android/iOS에서 재생되는 규격인가. (3) Anki의 `[sound:...]`와 rslib 미디어 처리가 `.m4a`를 어떻게 다루는가.

### 7.2 실제로 한 것 (`ES/m4a/`)
- **Linux 녹음 가능성**: `record` 패키지의 Linux 구현 `record_linux 2.2.0`(pub.dev)을 `ES/m4a/rec_test/`에서 `flutter test`로 실행. 구현은 **`parecord`(PulseAudio)로 PCM을 캡처 → `ffmpeg`로 인코딩**한다(`lib/src/capture_pipeline.dart`). AAC-LC는 `-c:a aac -b:a 128k <경로>` 인자(`lib/src/process_args.dart`). 상자에는 오디오 장치가 없어 PulseAudio **null sink**(무음)를 모니터링해 실제로 `RecordLinux.start/stop`을 돌렸다 → `ES/m4a/plugin_rec.m4a`(4.6초, 무음) [확인].
- **규격 점검(ffprobe)**: 같은 ffmpeg AAC 인코더 경로로 표본률·채널을 바꿔 5개 생성(`rec_<Hz>_<ch>.m4a`) [스탠드인: 플러그인이 쓰는 `ffmpeg -c:a aac`를 직접 호출].
- **중단 내성**: 일반 m4a(`moov`가 끝에 쓰임)를 비정상 종료 시뮬레이션으로 자르면 어떻게 되는지, `-movflags +frag_keyframe+empty_moov` 단편화 m4a(`frag.m4a`)와 비교.

### 7.3 결과
| 항목 | 결과 |
|---|---|
| 플러그인 경로 산출물 | `plugin_rec.m4a`: `codec=aac`, `profile=LC`, 44.1kHz mono, 컨테이너 `major_brand=M4A`, compatible `M4A isomiso2`, 인코더 태그 `Lavf61.7.103`; `ffmpeg -f null`로 전체 디코딩 오류 없음 [확인] |
| 표본률·채널 | 16k/22.05k/44.1k/48k mono, 44.1k stereo 모두 `aac LC`, 브랜드 `M4A ` [확인] |
| 모바일 문서 근거 | **Android**: 플랫폼 지원 형식 표에서 AAC LC는 디코드 YES, 컨테이너 3GPP·MPEG-4(`.mp4`, `.m4a`), "mono/stereo/5.0/5.1, 표본률 8–48kHz" — https://developer.android.com/media/platform/supported-formats [확인: 페이지 본문]. ExoPlayer(Media3) 컨테이너 표에 `MP4 YES`, `M4A YES` — https://developer.android.com/media/media3/exoplayer/supported-formats [확인: 페이지 본문]. **iOS**: WWDC16 507 슬라이드 "AVAudioPlayer plays file types supported by AudioFile API, e.g. wav, caf, m4a, aac, mp3, aif" [확인: PDF 본문 요약], Apple Core Audio 문서 표에서 MPEG 4 Audio(`.m4a`) = `'aac '`, `alac` [확인: 문서]. iOS 재생 형식 중 AAC(AAC-LC) 포함 [확인: Apple 문서를 인용한 검색 결과]. 위 파일의 표본률·채널은 모두 Android 표 범위 안이다. 실제 기기 재생은 **미실행** [모름] |
| rslib·Anki의 `.m4a` | rslib은 확장자와 무관: `[sound:...]`는 `rslib/src/text.rs:156-167`의 정규식(`\[sound:(.+?)\]`, `\[sound:([^]]+)\]`)으로 파일명만 뽑고, 확장자 목록이 없다 [확인]. `m4a`는 Anki 쪽 UI 목록에만 있다: `qt/aqt/sound.py:90`, `qt/aqt/editor_legacy.py:95`(첨부 가능 확장자), `ts/routes/editor/rich-text-input/data-transfer.ts:31`(드롭 허용), 재생 시험 `qt/tests/test_sound.py:19` [확인]. 즉 `[sound:rec-xxxx.m4a]`는 그대로 쓸 수 있고, 미디어 점검(`CheckMedia`)도 참조 파일로 센다 [추정: 정규식·확장자 필터 없음에서 추론] |
| 크래시 내성 | **일반 m4a는 녹음 중 SIGKILL되면 `moov`가 없어 재생 불가**(재현: ffmpeg `-re` 4초 후 `kill -9` → `moov atom not found`, `ES/m4a/evidence/k_plain.m4a`). SIGINT로 종료하면 정상(`killedint.m4a`, 4.48초). **단편화 m4a**(`-movflags +frag_keyframe+empty_moov -frag_duration 1000000 -flush_packets 1`)는 SIGKILL 후에도 4.09초가 읽힌다(`k_frag3.m4a`, 66,041B). 단 `-frag_duration`·`-flush_packets` 없이는 처음 4초 동안 712B만 써져 쓸모가 없었다(`k_frag.m4a`) [확인]. 이전 실험: 완성된 단편화 파일을 30,000B에서 자른 `trunc_frag.m4a`도 앞부분이 디코딩됨, 일반 파일을 자른 `trunc_nomoov.m4a`는 안 열림 [확인]. `record_linux`는 `movflags`를 넘길 수 없다(`process_args.dart`가 `-c:a aac -b:a ...`로 고정) → 앱 비정상 종료 시 녹음 손실. 우회: 임시 파일에 단편화로 녹음 후 완료 시 정상 mp4로 리먹스, 또는 포크 [추정] |
| 런타임 의존 | `parecord`(pulseaudio-utils)와 `ffmpeg`(AAC 인코더 `aac`)가 **사용자 시스템에 있어야** 한다. 번들되지 않는다 [확인: 소스]. 데스크톱 첫 설치에서 없으면 녹음 불가 처리가 필요 |
| 마이크 장치 | 상자에는 실제 마이크가 없어 실제 음성·권한 흐름·장치 열거는 시험하지 못했다 [모름] |

### 7.4 판정과 권고
- **Linux 녹음 `.m4a`: 가능(조건부)** — `record_linux` + `ffmpeg`/`parecord` 설치 전제. 모바일 재생 규격(AAC-LC, MP4/M4A 브랜드, 8–48kHz, mono/stereo)은 문서상 충족. **권고 규격**: AAC-LC, 44.1kHz(또는 48kHz), mono(음성), 64–128kbps, 컨테이너 `M4A `. HE-AAC·xHE-AAC는 쓰지 않는다.
- macOS는 `record_darwin`(AVAudioRecorder 계열)이 네이티브 AAC를 쓰는 것으로 알려져 있으나 시험하지 못했다 [모름] → 런북 항목.
- 결정 필요: Gina — 파일 이름 규칙(`rec-<해시>.m4a`)과 미디어 키; Justin — 녹음 중 비정상 종료 시 손실 허용 여부.

## 8. 결정이 필요한 것과 다음 단계

| # | 내용 | 담당 | 근거 |
|---|---|---|---|
| 1 | `ChangeNotetype` 합격 기준 "저널 0행"을 "항등 매핑일 때만"으로 수정하고, 필드 순서 교환·삭제를 v0에 둘지 | Gina(저널 op 어휘)·Justin | §2.4 발견 1 |
| 2 | 래퍼가 rslib Undo/Redo를 `intent`로 감싸는지(감싸지 않으면 side DB가 모름) | Gina | §2.4 발견 2 |
| 3 | 편집 표면: `EditableText` 직접 구현 vs `super_editor 0.3.0-dev`(안정판 2024-06에서 정지) | Justin(블록 요소 범위)·Gina(프리릴리스 의존 정책) | §3.4 |
| 4 | 미리보기 충실도 수준(임의 노트타입 CSS를 보여 줄지)과 Linux 웹뷰 포기 여부 | Justin·Gina | §4.4 |
| 5 | `super_*` 채택: Mac 측 G1·G2·G5·G7 결과 후 확정. 툴체인 2벌(1.97.1+1.100.0) 재현성 처리 | Gina | §6.3 G1·G7 |
| 6 | G9 "문서화된 전망"으로 pub.dev 0.10.0-dev 게시를 인정할지 | Gina | §6.3 G9 |
| 7 | 파일 복사 시 PNG로도 보이는 동작에 맞춘 입력 우선순위(`fileUri` 우선) 명문화 | Gina(붙여넣기 정책) | §6.3 G4 |
| 8 | 녹음: 단편화 m4a 임시 파일 + 완료 시 리먹스 또는 포크, 사용자 시스템의 `ffmpeg`·`parecord` 의존 허용 여부 | Justin·Gina | §7.3 |

다음 단계(승인 시): (a) 재열님 Mac에서 런북 A~F 실행 후 결과 회수 → 이 문서 §5~§7과 §6.3의 [모름] 칸 채움, (b) 저장소 작업 승인이 나면 스파이크 a의 시나리오를 실제 `WriteWrapper`로 옮김(`hatto_store` 소스를 못 열어 이번에는 스탠드인).

## 9. 산출물 위치

| 종류 | 경로 |
|---|---|
| 이 문서 / macOS 런북 | `/workspace/v0-kickoff/notion-drafts/DMITRY_EDITOR_SPIKES.md`, `DMITRY_EDITOR_SPIKES_MACOS_RUNBOOK.md` |
| Mac용 소스 묶음(14MB, 소스 전용) | `/workspace/editor-spikes/mac_bundle/editor-spikes-mac.tgz` (재생성: `ES/mac/make_bundle.sh`) |
| a | `ES/a/harness/`, `ES/a/evidence/` |
| b | `ES/b/proto/`(코덱·두 프로토타입·테스트), `ES/b/evidence/` |
| c | `ES/c/native_app/`, `ES/c/web_app/`(WPE), `ES/c/iaw_app/`(inappwebview), `ES/c/ref/`(MathJax 기준), `ES/c/evidence/` |
| d | `ES/d/run_ime.sh`, `ES/d/evidence/` |
| e | `ES/e/{e_app,v1_rslib,v2_super,v3_control}/`, `ES/e/clipset.c`, `ES/e/runprobe.sh`, `ES/e/evidence/` |
| m4a | `ES/m4a/`(샘플 파일, `rec_test/`, `evidence/`) |
| 로그 | `ES/logs/` |
