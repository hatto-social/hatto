#!/bin/bash
# record_demos.sh [uc01 uc02 ... | all]  -> videos/ucNN_*.mp4 (+ reel_all.mp4 when all)
# Real Linux debug build of b/proto under Xvfb, ffmpeg x11grab 30fps, xdotool at human pace, real fcitx5 for uc02.
# Build first: flutter build linux --debug -t lib/main.dart
source "$(dirname "$0")/rec_lib.sh"
mkmedia
CHIP='<ul><li>목록</li></ul>'

run() { # run <id> <name> <caption> <im> <ENV...> ; the scenario body is function scn_<id>
  local id=$1 name=$2 cap=$3 im=$4; shift 4
  echo "== $id $name"; start_env $im; launch_app "$@"; rec_start; scn_$id; rec_stop; finish $VID/${id}_$name.mp4 "$cap"; stop_env
}

scn_uc01() {
  note "필드를 클릭"; clk 700 128
  note "툴바 B 위에 마우스 — 툴팁"; hover 215 55 0.6 1.6
  note "툴바 B 클릭 → 입력"; clk 215 55 0.3; typ "Bold "
  note "툴바 B 다시 클릭 → 해제"; clk 215 55 0.3; typ "plain "
  note "Ctrl+B, Ctrl+I"; key ctrl+b; key ctrl+i; typ "bold-italic "
  note "Ctrl+U 추가 → 겹친 서식 (B·I·U 모두 활성)"; key ctrl+u; typ "all-three "
  note "Ctrl+B, I, U 해제"; key ctrl+b; key ctrl+i; key ctrl+u; typ "end "
  note "Ctrl+= 아래첨자"; key ctrl+equal; typ "2"; key ctrl+equal
  note "Ctrl+Shift+= 위첨자"; key ctrl+shift+equal; typ "2"; key ctrl+shift+equal; typ " done"
  note "캐럿을 왼쪽으로 이동 — 툴바 상태가 캐럿을 따라감"; keys Left Left Left Left Left Left Left Left Left Left
}
scn_uc02() {
  note "필드 클릭, 한글 입력기(fcitx5 hangul) 켜기"; clk 700 128; key End; ime_hangul
  note "Ctrl+B — 선택 없이 토글 (pending bold, 툴바 B 활성)"; key ctrl+b; sleep 0.8
  note "한글 조합 중 (ㅎ ㅏ ㄴ ㄱ ㅡ ㄹ)"; ktyp g k s r m f; sleep 0.6
  note "스페이스로 확정 → 굵게 유지"; key space
  note "계속 입력 (ㅇ ㅣ ㅂ ㄹ ㅕ ㄱ)"; ktyp d l q f u r; sleep 0.8
  note "문장 맨 앞으로 이동 (Home) → Ctrl+I: 새 pending (기울임, 툴바 I 활성)"; key Home; key ctrl+i; sleep 1.1
  note "캐럿 이동(→) → pending 해제, 툴바 I 꺼짐"; key Right; sleep 1.1
  note "이어서 입력 → 서식 없음 (ㅎ ㅏ)"; ktyp g k; sleep 0.5; key space; sleep 0.9
}
scn_uc03() {
  note "첫 단어 선택 (Shift+→)"; clk 700 128; key ctrl+Home; keys shift+Right shift+Right shift+Right shift+Right shift+Right
  note "A 버튼에 마우스 — 툴팁"; hover 344 55 0.5 1.3
  note "A 클릭 → 마지막 색(기본 파랑) 적용"; clk 344 55 0.2; sleep 0.9
  note "다른 단어 선택"; key ctrl+Home; key ctrl+Right; key ctrl+shift+Right; key shift+Left
  note "A 옆 드롭다운 화살표 → 색 팔레트 팝오버 (border + shadow)"; clk 365 55 0.5; sleep 1.4
  note "스와치 위로 마우스 이동"; mv 408 88 0.5; mv 434 88 0.4; mv 382 88 0.4; sleep 0.5
  note "빨강 선택 → 적용"; clk 382 88 0.3; sleep 0.9
  note "마지막 단어 선택 후 A 클릭 → 방금 고른 빨강 적용"; key ctrl+End; keys shift+Left shift+Left shift+Left shift+Left shift+Left shift+Left; clk 344 55 0.4; sleep 1.2
}
scn_uc04() {
  note "이미지 토큰은 썸네일로 표시 (마우스 올리면 src 툴팁)"; clk 700 128; key ctrl+Home; hover 90 128 0.6 1.6
  note "→ 로 이동: 이미지는 한 번에 건너뜀 (원자적)"; keys Right Right Right Right Right
  note "툴바 클립 버튼 → 이미지 삽입 (데모 파일)"; key ctrl+End; clk 556 55 0.5; sleep 1.0
  note "← ← : 삽입한 이미지 앞뒤로 이동"; keys Left Left Right Right
  note "Backspace → 이미지 1개 삭제"; key BackSpace; sleep 1.0
  note "Ctrl+Z → 되돌리기 (이미지 복구)"; key ctrl+z; sleep 1.2
}
scn_uc05() {
  note "수식 \\( … \\) 입력 — 평문으로 유지"; clk 700 128; typ '\(e^{i\pi}+1=0\)'; typ " "
  note "클로즈 {{c1::…}} 입력 — 평문"; typ '{{c1::cloze::hint}}'; typ " "
  note "[sound:…] 입력 — 평문"; typ '[sound:rec.m4a]'; sleep 0.6
  note "←: 글자 단위로 이동 (칩/위젯 없음)"; keys Left Left Left Left Left Left Left Left
  note "전체 선택 → 툴바는 일반 서식 그대로"; key ctrl+a; sleep 1.0
}
scn_uc06() {
  note "raw chip — 지원 밖 태그(<ul>)는 읽기 전용 칩으로 표시"; sleep 0.8; clk 700 128; key ctrl+Home
  note "칩에 마우스 → 원본 HTML 툴팁"; hover 62 128 0.6 1.8
  note "→ 로 이동: 칩은 한 번에 건너뜀 (안쪽 편집 불가)"; keys Right Right Right Right
  note "칩 선택 (Shift+→) 후 잘라내기 Ctrl+X"; key ctrl+Home; keys Right Right shift+Right; key ctrl+x; sleep 0.9
  note "문장 끝으로 이동 후 붙여넣기 Ctrl+V"; key ctrl+End; key ctrl+v; sleep 1.2
}
scn_uc07() {
  note "DOM 비등가 필드(<div> 사이 줄바꿈)는 HTML 원문 편집으로 열림"; sleep 0.8; hover 954 93 0.6 1.8
  note "원문 편집: 클릭 후 태그 입력"; clk 700 140; key ctrl+End; key Return; typ '<div>three</div>'; sleep 0.6
  note "툴바 서식 버튼은 비활성 (원문 모드)"; hover 215 55 0.5 1.2
  note "[플래그 옵션 VOLUNTARY_HTML=1, 기본 꺼짐·계약 밖] Back 필드 클릭"; clk 700 240 0.6
  note "[플래그 옵션] Back의 <> 클릭 → HTML 원문 편집"; clk 954 202 0.6; sleep 1.0
  note "[플래그 옵션] 원문에 <i>it</i> 입력"; clk 700 232 0.4; key ctrl+End; typ ' <i>it</i>'; sleep 0.6
  note "[플래그 옵션] <> 다시 클릭 → 서식 편집으로 복귀 (굵게·기울임 반영)"; clk 954 202 0.6; sleep 1.6
  note "※ 계약상 강제된 Front 필드는 원문 모드에서 되돌릴 수 없음"; sleep 1.8
}
scn_uc08() {
  note "Front 클릭 후 입력"; clk 700 120; typ "Front text "
  note "툴바 B (Front에만 적용)"; clk 215 55 0.4; typ "bold"
  note "Tab → Back 필드로 이동"; key Tab; sleep 0.6
  note "Back은 서식 없음 — 툴바 B 꺼짐 (포커스 필드 기준)"; typ "Back text "; sleep 0.5
  note "Ctrl+I → Back에만 기울임"; key ctrl+i; typ "italic"; sleep 0.5
  note "Back 접기 (왼쪽 화살표 클릭)"; clk 24 169 0.5; sleep 1.0
  note "다시 펼치기"; clk 24 169 0.4; sleep 0.8
  note "Back 클릭 후 Shift+Tab → Front로 돌아감 (툴바가 Front 상태로 전환)"; clk 700 202 0.5; key shift+Tab; sleep 1.4
}
scn_uc09() {
  note "라이트 테마에서 시작"; clk 700 128; typ "Light "; clk 215 55 0.3; typ "bold"
  note "Ctrl+Alt+D → 다크 테마"; key ctrl+alt+d; sleep 1.2
  note "다크에서 서식·팔레트 확인"; key ctrl+b; key ctrl+i; typ " dark italic"; key ctrl+i
  note "팔레트 팝오버 (다크 border + shadow)"; keys shift+Left shift+Left shift+Left shift+Left; clk 365 55 0.5; sleep 1.2
  note "파랑 선택"; clk 460 88 0.4; sleep 0.9
  note "툴바 툴팁 (다크)"; hover 241 55 0.5 1.6
  note "Ctrl+Alt+D → 다시 라이트"; key ctrl+alt+d; sleep 1.2
}

[ "$1" = reel ] && set -- none
ALL="uc01 uc02 uc03 uc04 uc05 uc06 uc07 uc08 uc09"
want=${@:-all}; [ "$want" = none ] && want=""; [ "$want" = all ] && want=$ALL
for u in $want; do case $u in
 uc01) run uc01 marks_toggle "1. 서식 토글: 툴바·단축키, 겹친 서식, 캐럿 따라 툴바 상태" "" INIT_HTML= "INIT_HTML2=Back 필드는 그대로" ;;
 uc02) run uc02 pending_korean_ime "2. 선택 없이 굵게 + 한글 IME 조합(fcitx5), 캐럿 이동 시 해제" fcitx5 "INIT_HTML=안녕 " "INIT_HTML2=Back" ;;
 uc03) run uc03 font_color "3. 글자색: 마지막 색 버튼 + 팔레트 팝오버(border·shadow)" "" "INIT_HTML=color test 색상 데모 text sample" "INIT_HTML2=Back" ;;
 uc04) run uc04 image_token "4. 이미지 토큰: 썸네일, 원자적 캐럿, Backspace 삭제, Undo" "" "INIT_HTML=앞 <img src=\"demo.png\"> 뒤 끝" "INIT_HTML2=Back" ;;
 uc05) run uc05 math_cloze_sound_plain "5. 수식·클로즈·[sound:]는 입력 중에도 평문 유지" "" INIT_HTML= "INIT_HTML2=Back" ;;
 uc06) run uc06 raw_chip "6. Raw chip: 툴팁, 읽기 전용, 캐럿 건너뜀, 잘라내기/붙여넣기" "" "INIT_HTML=앞 $CHIP 뒤 끝" "INIT_HTML2=Back" ;;
 uc07) run uc07 html_source_mode "7. DOM 비등가 필드 → HTML 원문 편집 모드" "" $'INIT_HTML=<div>one</div>\n<div>two</div>' "INIT_HTML2=Back <b>bold</b> text" VOLUNTARY_HTML=1 ;;
 uc08) run uc08 multi_field_nav "8. 멀티필드: Tab 이동, 접기/펼치기, 툴바는 포커스 필드에만" "" "INIT_HTML=" "INIT_HTML2=" ;;
 uc09) run uc09 dark_theme "9. 다크 테마 전환 (Ctrl+Alt+D) + 서식·팔레트" "" "INIT_HTML=" "INIT_HTML2=Back" ;;
esac; done
if [ "$1" = all ] || [ -z "$1" ] || [ "$1" = none ]; then
  ls $VID/uc0*.mp4 | sed "s/.*/file '&'/" > $WORK/list.txt
  ffmpeg -y -loglevel error -f concat -safe 0 -i $WORK/list.txt -c:v libx264 -preset medium -crf 27 -r 30 -pix_fmt yuv420p -movflags +faststart -an $VID/reel_all.mp4
fi
ls -la $VID
