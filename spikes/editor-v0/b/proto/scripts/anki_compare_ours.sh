#!/bin/bash
# Real Linux build captures matching the Anki reference scenarios (see anki-run/anki_compare_anki.sh). Output: screenshots/anki_compare/ours_*.png
source "$(dirname "$0")/lib_shots.sh"
OUT="$ROOT/screenshots/anki_compare"; mkdir -p $OUT
click() { xdotool mousemove --window $WID $1 $2 click 1; sleep 0.5; }
sel7() { click 700 128; xdotool key ctrl+Home; sleep 0.3; xdotool key --delay 80 shift+Right shift+Right shift+Right shift+Right shift+Right shift+Right shift+Right; sleep 0.8; }
# 01 overall light, Front focused, caret at start
launch "INIT_HTML=$FRONT" "INIT_HTML2=$BACK"; click 700 128; xdotool key ctrl+Home; sleep .6; shot $OUT/ours_01_overall_light.png
# 02 selection => toolbar active states (hover italic afterwards for 07)
sel7; shot $OUT/ours_02_selection_toolbar_light.png
xdotool mousemove --window $WID 241 55; sleep 0.8; shot $OUT/ours_07_toolbar_hover_italic_light.png
# 06 colour chooser open with the selection
click 365 55; sleep .5; shot $OUT/ours_06_color_chooser_light.png
done_
# 03 dark
launch "INIT_HTML=$FRONT" "INIT_HTML2=$BACK" THEME=dark; sel7; shot $OUT/ours_03_overall_dark_selection.png; done_
# 04 collapsed Back
launch "INIT_HTML=$FRONT" "INIT_HTML2=$BACK"; click 700 128; click 24 216; shot $OUT/ours_04_back_collapsed_light.png; done_
# 05 html source: (a) FLAGGED voluntary toggle on a normal field, (b) contract-forced field (non-DOM-equivalent)
launch "INIT_HTML=$FRONT" "INIT_HTML2=$BACK" VOLUNTARY_HTML=1; click 700 128; click 955 93; sleep .5; shot $OUT/ours_05a_html_toggle_flagged_light.png; done_
launch "INIT_HTML=<div>one</div>
<div>two</div>
<b>bold</b> end" "INIT_HTML2=$BACK"; click 700 128; sleep .5; shot $OUT/ours_05b_html_forced_by_contract_light.png; done_
# 08 v0 demo content (raw chip, img thumbnail, plain math/cloze/sound)
launch X=1 SAMPLE=v0-demo; click 700 128; sleep .5; shot $OUT/ours_08_v0_demo_light.png; done_
