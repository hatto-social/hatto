#!/bin/bash
# Real Linux desktop build screenshots under Xvfb (no IME needed).
cd "$(dirname "$0")/.."
D=:98; OUT=screenshots/app
APP=build/linux/x64/debug/bundle/editor_proto
export MEDIA_DIR="$PWD/screenshots/media"
launch() { # name, env...
  pkill -f "Xvfb $D" 2>/dev/null; pkill openbox 2>/dev/null; pkill editor_proto 2>/dev/null; sleep 0.8
  Xvfb $D -screen 0 1100x700x24 >/dev/null 2>&1 & sleep 1.2
  export DISPLAY=$D; openbox >/dev/null 2>&1 &
  env "${@:2}" $APP >/tmp/app_shot.log 2>&1 &
  for i in $(seq 1 40); do xdotool search --name editor_proto >/dev/null 2>&1 && break; sleep 0.5; done
  sleep 2.5; WID=$(xdotool search --name editor_proto | head -1); xdotool windowmove $WID 0 0; xdotool windowfocus $WID; sleep 0.6
}
shot() { import -window root $OUT/$1.png; }
done_() { pkill editor_proto; pkill openbox; pkill -f "Xvfb $D"; sleep 0.5; }

# 1 overall v0 demo, mark select via keyboard: click end of line1, shift+Home select, ctrl+b
launch x SAMPLE=v0-demo
xdotool mousemove 300 140 click 1; sleep 0.5
shot app_01_v0_demo_opened
# select "굵게 굵고 기울임" by double-click + ctrl+b -> toggles
xdotool key Home; xdotool key --delay 80 shift+Right shift+Right shift+Right shift+Right shift+Right shift+Right shift+Right; sleep 0.4
shot app_02_selection_toolbar_active_state
xdotool key ctrl+u; sleep 0.4
shot app_02b_selection_underline_toggled_by_shortcut
# hover raw chip <ul>
done_
launch x SAMPLE=v0-demo
xdotool mousemove 300 300; sleep 0.3; xdotool mousemove 117 196; sleep 0.2; xdotool mousemove_relative 1 0; sleep 0.2; xdotool mousemove_relative -- -1 0; sleep 1.5
shot app_03_hover_chip_tooltip
done_
# color palette open
launch x SAMPLE=v0-demo
xdotool mousemove 300 140 click 1; sleep 0.3; xdotool key Home; xdotool key --delay 80 shift+Right shift+Right shift+Right; sleep 0.3
xdotool mousemove 183 101 click 1; sleep 0.6
shot app_04_color_palette_open
xdotool mousemove 70 126 ; sleep 0.2
done_
# source-edit fallback
launch x "INIT_HTML=<div>one</div>
<div>two</div>
<b>bold</b> end"
sleep 0.5; shot app_05_html_source_edit_fallback
done_
# pending bold (English typing) : ctrl+b then type abc
launch x INIT_HTML="hello "
xdotool mousemove 400 140 click 1; sleep 0.4; xdotool key End; xdotool key ctrl+b; sleep 0.3; xdotool type --delay 80 "pending bold"; sleep 0.5
shot app_06_pending_bold_english
done_
