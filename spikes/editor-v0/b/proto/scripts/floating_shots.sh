#!/bin/bash
# floating_shots.sh <before|after>  -> screenshots/anki_compare/float_<tag>_<area>_<theme>.png (palette, toolbar tooltip, raw-chip tooltip)
source "$(dirname "$0")/lib_shots.sh"
TAG=$1; OUT="$ROOT/screenshots/anki_compare"; mkdir -p $OUT
click() { xdotool mousemove --window $WID $1 $2 click 1; sleep 0.5; }
hover() { xdotool mousemove --window $WID $(($1-3)) $(($2-2)); sleep .3; xdotool mousemove --window $WID $1 $2; sleep 1.6; }
for T in light dark; do
  launch "INIT_HTML=$FRONT" "INIT_HTML2=$BACK" THEME=$T; click 700 128; click 365 55; shot $OUT/float_${TAG}_palette_$T.png; done_
  launch "INIT_HTML=$FRONT" "INIT_HTML2=$BACK" THEME=$T; click 700 128; hover 216 55; shot $OUT/float_${TAG}_toolbar_tooltip_$T.png; done_
  launch X=1 SAMPLE=v0-demo THEME=$T; click 700 128; hover 112 167; shot $OUT/float_${TAG}_chip_tooltip_$T.png; done_
done
