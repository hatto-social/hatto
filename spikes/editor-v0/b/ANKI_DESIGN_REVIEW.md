# Editor Prototype B — Anki Desktop 디자인 정렬 리뷰 (DRAFT)

이 사본은 스파이크 브랜치의 `spikes/editor-v0/b/ANKI_DESIGN_REVIEW.md`다. 아래 본문은 첨부 초안과 같다. 초안의 "git push 없음"은 작성 시점 기준이다.

작성: Dmitry / 대상: Gina, Justin / 상태: **초안 (box copy only, git push·branch·PR 없음)**
근거 라벨: **[확인]** = 이번에 실물/소스에서 직접 확인, **[추정]** = 정황 기반, **[모름]** = 확인 못 함.
계약 문서(`DMITRY_EDITOR_FORMAT_SCOPE_TABLE.md`, `GINA_EDITOR_FORMAT_SCOPE.md`)는 수정하지 않았다.

---
## 1. 레퍼런스를 어떻게 얻었나

- **[확인] 실제 Anki Desktop 26.09.3을 box(Linux)에서 실행**했다. `pip install aqt` → venv `/workspace/editor-spikes/anki-run/venv`, Xvfb :97 (1400x900) + openbox, `QTWEBENGINE_CHROMIUM_FLAGS="--no-sandbox --disable-gpu"`. `aqt.run()`을 호출하는 드라이버(`anki-run/drive.py`)가 Qt 메인스레드에서 명령 파일을 exec 한다. 프로필 "User 1".
- **[확인] 숫자는 렌더링된 DOM의 computed style**(`editor.web.page().runJavaScript`)에서 읽고, 소스(`/workspace/editor-spikes/anki-src`)와 대조했다. 다크는 `mw.pm.set_theme(Theme.DARK)` + `theme_manager.apply_style()`.
- **[확인] 측정한 창은 기본(legacy) Add 창** (`aqt.dialogs.open("AddCards")`). Qt 셸(Type/Deck 선택, 하단 Help/Add/History/Close) + 안쪽 Svelte 웹뷰(툴바·필드·태그). 26.09.3 소스에는 전체 Svelte `NewAddCards`도 있으나 `ExperimentFlag.SVELTE_EDITOR`가 켜져 있거나 Shift 로 열 때만 뜬다 (`qt/aqt/main.py:1304-1319`). 즉 "기본 Anki 모양"은 legacy 창 기준. Type/Deck·푸터는 Qt 위젯이라 **픽셀 측정으로** 맞췄다.
- 레퍼런스 캡처: `/workspace/editor-spikes/anki-run/shots/` (01 light, 02 html toggle, 03 back collapsed, 04 selection, 05 color dialog(Qt), 06 highlight dropdown, 07 mathjax menu, 08 removeformat, 10 dark, 11–13 tags/cloze).
- 재현: `anki-run/start.sh` → 업데이트 다이얼로그 "Ignore this update" → `/tmp/c1.py` 로 Add 창 열기 (→ `anki_compare_anki.sh`).

---
## 2. 토큰 (Anki 실측 + 소스 cite)

| 항목 | 값 (light / dark) | 근거 |
|---|---|---|
| 기본 폰트 크기 | 15px, 줄 높이 1.5, system-ui (이 box에서는 Noto Sans) | `ts/lib/sass/_vars.scss` `--font-size`; 실측 [확인] |
| border-radius | 5px | `_vars.scss:21` `border-radius` 맵 [확인] |
| 캔버스 / 필드 배경 / 코드 배경 | #f5f5f5 / #fff / #fff — dark #2c2c2c / #363636 / #252525 | `_vars.scss:108~` canvas 계열, 실측 [확인] |
| 글자 / 흐린 글자 / 비활성 | #020202 / #737373 / #858585 — dark #fcfcfc / #858585 / #737373 | `_vars.scss:71~` fg 계열 [확인] |
| border / border-subtle | #c4c4c4 / #e4e4e4 — dark #202020 / #252525 | 실측 [확인] |
| 포커스 링 | #3b82f6 (2px, 바깥쪽) | 실측 [확인] |
| 버튼 | 높이 24px, min-width 18px(=24×0.75), 아이콘 16.5px(=1.1×15), 그라디언트 #fff→#fcfcfc (dark #4a4a4a→#404040) | `ts/routes/editor/NoteEditor.svelte:119` `size = 1.6`(rem); `ts/lib/components/IconButton.svelte:51-52` [확인] |
| 버튼 그룹 간격 | 가로 4.5px(.3rem), 세로 2.25px(.15rem), 좌측 패딩 .15rem | `ts/lib/components/ButtonToolbar.svelte:41-46` [확인] |
| 필드 영역 | 위 5px 마진 / grid-gap 6px / 아래 패딩 5px | `ts/routes/editor/Fields.svelte:21,24,27` [확인] |
| 필드 라벨 행 | 패딩 `0 3px 1px` | `ts/routes/editor/LabelContainer.svelte:29` [확인] |
| 필드 외곽선 | margin 1px, 1px border, radius 5, 포커스 시 2px 링 | `ts/routes/editor/EditorField.svelte:152`; 실측 [확인] |
| 리치 입력 패딩 | 6px | `ts/routes/editor/rich-text-input/RichTextInput.svelte:267` [확인] |
| 필드 기본 글꼴 | Arial 20px, 줄높이 1.5(측정 30px) | `rslib/src/notetype/fields.rs:45-46`; 실측 [확인] |
| 텍스트 선택색 | light #3367d1 / dark #0a3ea8 (배경), **선택된 글자는 흰색** | 렌더 픽셀에서 측정 [확인] (CSS 토큰 `--highlight-bg` 와 값이 다르다 → 웹뷰 기본 선택색이 적용되는 것으로 [추정]) |
| 아이콘 | @mdi/svg 7.4.47 (Apache-2.0), bootstrap-icons 1.11.3 (MIT) | `ts/licenses.json:37-42, 109-114` [확인: Anki 기재]; **우리 쪽 라이선스 승인은 미정 (Q4)** |

우리 구현에서의 대응: `lib/anki_ui.dart` (`AnkiColors`, `AnkiMetrics`).

---
## 3. 갭 테이블 (Anki Desktop | 우리 프로토타입 | 수정 | 우선순위)

"before" = `/workspace/editor-spikes/b/proto.bak-prereview/screenshots/` (1100x700 이전 앱), "after" = `screenshots/anki_compare/ours_*.png`, 비교 = `sbs_*.png`(왼쪽 Anki, 오른쪽 우리).

| # | 요소 | Anki Desktop | 이전 프로토타입 (before) | 수정 (after 상태) | 우선순위 |
|---|---|---|---|---|---|
| 1 | 전체 레이아웃 | Type/Deck 헤더 → 툴바 → 필드 목록 → 태그 → 푸터 | 단일 필드 + 임시 툴바 | **멀티필드 NoteEditor**(`lib/note_editor.dart`) 로 동일 구조. 픽셀 행/열 분석(`tool/rows.py`, `tool/cols.py`)으로 헤더·툴바·라벨·링·태그·푸터 위치 일치 확인 — `sbs_01` | P0 (done) |
| 2 | 필드 라벨 + 접기 | 필드명 라벨, 접기 chevron, 접으면 본문 숨김 | 없음 | 라벨 행 + `collapse-i` 배지, 접어도 내용·마크 유지(Offstage). 테스트 A5 — `sbs_04` | P0 (done) |
| 3 | 툴바 그룹 | Fields…/Cards… · 톱니 · B I U · x² x₂ · A▾ 형광▾ · 지우개▾ · 목록/정렬 · 클립/마이크/ƒx | 텍스트 버튼 몇 개 | Anki 그룹·간격·24px 버튼·16.5px 아이콘·hover/pressed/active/disabled 상태. 아이콘은 Anki DOM에서 추출한 SVG path(`anki_icon_data.dart`) — `sbs_09`, `sbs_07` | P0 (done) |
| 4 | 툴바 포커스 유지 | 클릭해도 필드 포커스 유지 | (단일 필드) | `TextFieldTapRegion` + `ExcludeFocus`. 하나의 공유 툴바가 **포커스된 필드에만** 작동, 포커스 없음/소스모드면 disabled (A2). 실제 fcitx5/ibus 16 시나리오 재실행 결과 **이전과 동일** | P0 (done) |
| 5 | 글자색 | A(적용) + ▾(색 선택 대화상자: Qt QColorDialog) | 팔레트 칩 | `A` = 마지막 색 적용, ▾ = 우리 팝오버 팔레트. **Qt 네이티브 대화상자는 재현 안 함**, 기본색 #1565c0(계약 팔레트) vs Anki #0000ff — `sbs_06` | P1 (done, 차이 명시) |
| 6 | 형광펜(highlight) | 배경색 마커 + ▾ | 없음 | **disabled 로만 표시** (계약에 없음) → Q1 | P1 (flagged) |
| 7 | 서식 지우기/목록/정렬/마이크/수식 | 모두 활성 | 없음 | **disabled + 툴팁** (v0 범위 밖, 몰래 동작하지 않음) (A4) → Q2/Q5 | P2 (flagged) |
| 8 | 이미지 첨부(클립) | 파일 선택 + 이미지 삽입 | 있음 | 라이브 유지 (`tb-img`). 썸네일은 계약상 64x48 고정 (Anki는 자연 크기, 최대 250x125 정도로 관찰 [확인]) | P2 (계약 차이) |
| 9 | HTML 에디터 토글 `<>` | 필드별 토글, 리치 아래에 소스 패널이 **함께** 표시 | 비율 있는 "원문 편집" 모드만 | `<>` 배지: **계약상 강제 필드는 켜져 있고 끌 수 없음**(A6). 자발적 토글은 `voluntaryHtmlToggle`/`VOLUNTARY_HTML=1` 플래그 뒤에서만 동작, 기본 off(A7) → Q3. 소스 모드 동안 호박색 "HTML 원문 편집" 칩 표시. 소스 패널이 리치를 대체(Anki는 동시 표시) — `sbs_05a` | P1 (flagged) |
| 10 | Sticky 핀 | 필드별 핀(상태 저장) | 없음 | **비동작 목업**, 아이콘은 직접 그린 것(Anki 핀 SVG는 AGPL 소스라 미사용) | P3 (mock) |
| 11 | Type/Deck 헤더 | Qt 콤보 2개 | 없음 | 정적 목업(클릭 시 아무 일 없음) | P2 (mock) |
| 12 | 태그 행 | 접기 + 태그 칩(휴지통) + 입력 | 없음 | 정적 목업: 접기·칩 `tag`/`trash` 아이콘, 높이 39px — `sbs_01` | P2 (mock) |
| 13 | 푸터 | Help / Add / History▾(disabled) / Close | 없음 | 목업(한글 라벨: 도움말/추가/기록/닫기) | P3 (mock) |
| 14 | 라이트/다크 | `--canvas` 등 토큰 쌍 | 라이트만 | `AnkiTheme` + 토큰 2벌, `THEME=dark` 또는 Ctrl+Alt+D — `sbs_03`, `sbs_10` | P0 (done) |
| 15 | 선택 모양 | 진한 파랑 배경 + 흰 글자 | 연한 파랑 | `selectionBg` 측정값 + 선택 구간 글자 흰색(`FieldController.selectionFg`, 포커스·리치 모드일 때만) — `sbs_02`, `sbs_03` | P1 (done) |
| 16 | 위/아래첨자 | 실제 baseline shift | — | 폰트 feature/유니코드 근사 — 시각 차이 약간 | P3 (known gap) |
| 17 | 소스 패널 | CodeMirror 구문 강조 + fold gutter | — | 모노스페이스 단색, 강조·gutter 없음 | P3 (known gap) |
| 18 | UI 언어 | 영어 | — | 한국어 라벨(필드…, 카드…, 태그 N개 등) → Q6 | P3 (question) |
| 19 | 툴바에서 우리만 있는 것 | 없음(undo/redo 는 Ctrl+Z) | undo/redo | **유지**(자체 제작 글리프, 테스트·마우스용) → Q5 | P3 |
| 20 | **Floating 표면 전체 (팔레트 팝오버, 툴바 툴팁, raw-chip/이미지 툴팁)** | 웹 Popover: 1px `--border-subtle` + `elevation(8)` 3중 그림자 + `--canvas-elevated` + radius 5 (`Popover.svelte:72-84`, `elevation.scss:29,41,55,59-61,85-87`). 실측(light/dark 동일 rgba): `0 8px 10px -5px rgba(20,20,20,.2), 0 16px 24px 2px rgba(20,20,20,.14), 0 6px 30px 5px rgba(20,20,20,.12)`, border `#e4e4e4`/`#252525`, bg `#fff`/`#363636`. 툴바 툴팁은 **네이티브 Qt QToolTip**(fg 색 1px 테두리, `--canvas` 배경, 그림자 없음 — `qt/aqt/stylesheets.py:123`) | 팔레트: 임의 border(`--border`)·약한 단일 그림자. 툴팁 3종: Flutter 기본(어두운 회색, border/그림자 없음) | 공통 토큰 `kAnkiElevation8` + `ankiFloating(k)` + `AnkiTooltip`(`anki_ui.dart`)을 팔레트·툴바/배지 툴팁·chip/이미지 툴팁에 일괄 적용, 두 테마 동일. 툴팁은 Qt 네이티브와 달리 Popover 외형으로 통일(재열 피드백). 컨텍스트 메뉴는 현재 없음(EditableText에 `contextMenuBuilder` 미설정) — `sbs_10_floating_*`, `ba_10_floating_*` | P1 (done) |

before/after 비교용 이전 이미지: `proto.bak-prereview/screenshots/app/*`.

---
## 4. 구현 요약 (b/proto, v0 범위 안)

- `lib/anki_ui.dart` (신규): `AnkiColors`(light/dark), `AnkiMetrics`, `AnkiTheme`, `AnkiIcon`, `AnkiGlyph`(자체 핀/undo/redo), `AnkiButton`(CustomPainter), `AnkiGroup`.
- `lib/anki_icon_data.dart` (생성물, `tool/gen_anki_icons.py`): Anki DOM에서 뽑은 SVG path. 색 막대 사각형은 @mdi/svg·bootstrap-icons에 없어 맵에서 뺐고, `anki_ui.dart`가 직접 그린다.
- `lib/note_editor.dart` (신규): `NoteEditor` / `NoteFieldSpec` (헤더·공유 툴바·필드·태그·푸터).
- `lib/proto_editable.dart`: `AnkiFieldFrame`, `EditableField`, `FieldToolbar`(그룹/팔레트 팝오버), `FieldController.selectionFg`, `forcedByUser`(**비계약, 플래그**).
- `lib/main.dart`: env `SAMPLE, INIT_HTML(Front), INIT_HTML2(Back), MEDIA_DIR, IME_LOG, THEME, VOLUNTARY_HTML, DEV_PANEL, TAGS, NOTETYPE, DECK`.
- 의존성 추가: `path_drawing ^1.0.1` (MIT) — 승인 필요 (Q4).
- 코덱/컨트롤러 계약 로직(`field_codec.dart` 등) **무변경**.

---
## 5. 테스트 결과 [확인]

- `flutter test` 전체: **38개 통과** (기존 29 + 신규 `anki_ui_test.dart` 9; A9 = floating 표면 공통 decoration). 포함: `corpus_gate_test`
  - 코퍼스 148,231 필드: GATE (a) 미편집 저장==원본 **148231/148231**, (b1) **141344/141344**, (b2) **141344/141344**. 리치 141,344 / 소스 폴백 6,887(4.65%) — 이전과 동일.
- 신규 A1–A8: 레이아웃/라이트·다크 스크린샷, 공유 툴바가 포커스 필드에만 작용, 색 적용·팔레트, 범위 밖 컨트롤 disabled, 접기, HTML 배지(강제/자발), 자발 토글 기본 off, **멀티필드 + 툴바 클릭 후 pending bold + 한글 조합 마크 유지**.
- **실제 fcitx5 / ibus 16 시나리오** (`scripts/run_all_ime_v0.sh`): 레이아웃 변경 후, 그리고 선택 글자색 변경 후 두 번 재실행 → `evidence-ime/summary.txt` **이전 결과(`summary_before_anki_design.txt`)와 동일**.
- 알려진 미설명 현상 [모름]: IME 하네스 중 한 번 툴바 클릭 후 Back 필드에 포커스가 안 보인 적이 있으나 이후 같은 시퀀스에서 재현 안 됨(하네스 아티팩트로 [추정]).
- 한계 [확인]: 테스트 스크린샷 폰트에는 ▾ 글리프가 없어 두부로 보임(실제 앱은 정상).

---
## 6. 스크린샷 (`/workspace/editor-spikes/b/proto/screenshots/anki_compare/`)

- `sbs_01_overall_light.png` 전체 / `sbs_02_selection_toolbar_light.png` 선택+툴바 상태 / `sbs_03_overall_dark_selection.png` 다크
- `sbs_09_toolbar_zoom_light.png`, `sbs_10_toolbar_zoom_dark.png` 툴바 3배 확대
- `sbs_04_back_collapsed_light.png` 접기 / `sbs_05a_html_toggle_light.png` HTML 토글 / `sbs_06_color_chooser_light.png` 색 선택 / `sbs_07_toolbar_hover_italic_light.png` hover
- 개별: `anki_*.png`(실제 Anki), `ours_*.png`(우리), `ours_05b_html_forced_by_contract_light.png`, `ours_08_v0_demo_light.png`
- **Floating 표면** (light/dark 각각): `sbs_10_floating_palette_*.png`, `sbs_10_floating_toolbar_tooltip_*.png`, `sbs_10_floating_chip_tooltip_*.png` (Anki|우리), `ba_10_floating_*_*.png` (before|after), 원본 `float_before_*` / `float_after_*` / `anki_floating_*`
- 위젯 테스트 캡처: `screenshots/anki_01_note_editor_light.png`, `anki_02_note_editor_dark.png`, `anki_03_html_badge_forced_and_voluntary.png`

---
## 7. 결정 필요 / 질문 (내가 정하지 않은 것)

1. **Q1 형광펜(highlight)**: 계약에 없는 서식. 지금은 disabled 로만 표시. v0에 넣을지? (넣으면 `background-color` 마크·코덱 계약 변경 필요)
2. **Q2 서식 지우기(eraser)**: 범위표에 없음 → disabled. 넣을지 / 숨길지?
3. **Q3 자발적 HTML 토글**: 계약은 "DOM 비등가 필드만 소스 모드 강제". 사용자가 임의로 `<>`로 전환하는 건 새 동작. 플래그(기본 off) 뒤에만 구현. 허용 여부, 그리고 Anki처럼 리치+소스 **동시 표시** vs 모드 전환?
4. **Q4 라이선스/의존성**: 아이콘 SVG 추출(Apache-2.0 @mdi/svg, MIT bootstrap-icons — Anki `licenses.json` 기재) 사용 승인, NOTICE 기재 방식, 의존성 `path_drawing`(MIT) 추가 승인. Anki 자체 AGPL 아이콘은 쓰지 않음.
5. **Q5 v0 밖 컨트롤 표시 방식**: 목록/정렬/마이크/수식 disabled 자리표시를 보일지 숨길지. undo/redo 버튼 유지 여부(Anki 에는 없음).
6. **Q6 UI 라벨 언어**: 한국어 vs Anki 영어.
7. **Q7 Type/Deck 선택, 태그 에디터, sticky 핀**: 지금은 정적 목업. 실제 동작 범위(v0 포함 여부)?
8. **Q8 글자색 UX/기본색**: 네이티브 대화상자 vs 팔레트, 기본색 #1565c0 vs Anki #0000ff.
9. **Q9 이미지 표시**: 계약의 64x48 고정 썸네일 vs Anki 자연 크기.

10. **Q10 툴팁 외형**: Anki 툴바 툴팁은 네이티브 Qt(검은 1px 테두리, 그림자 없음 — OS가 그림자 부여)인데, 우리는 요청에 따라 Popover 외형(border-subtle + elevation 8)으로 통일했다. 이대로 둘지, Qt 외형(fg 테두리)으로 맞출지?
