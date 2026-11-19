#!/bin/bash
# usage: run_ime_v0.sh <fcitx5|ibus> <scenario>   (adapted from /workspace/editor-survey/run_ime.sh; app = lib/main.dart v0 editor)
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IM=$1; SC=$2; D=:99
OUT="$ROOT/evidence-ime/${IM}_${SC}"
APP="$ROOT/build/linux/x64/debug/bundle/editor_proto"
mkdir -p $OUT; rm -f $OUT/*
pkill -f "Xvfb $D" 2>/dev/null; pkill fcitx5 2>/dev/null; pkill ibus-daemon 2>/dev/null; pkill editor_proto 2>/dev/null; pkill openbox 2>/dev/null; sleep 1
Xvfb $D -screen 0 1100x700x24 >$OUT/xvfb.log 2>&1 &
sleep 1.5
export DISPLAY=$D
eval $(dbus-launch --sh-syntax)
openbox >$OUT/wm.log 2>&1 &
if [ "$IM" = fcitx5 ]; then
  mkdir -p ~/.config/fcitx5; cat > ~/.config/fcitx5/profile <<'P'
[Groups/0]
Name=Default
Default Layout=us
DefaultIM=hangul

[Groups/0/Items/0]
Name=keyboard-us
Layout=

[Groups/0/Items/1]
Name=hangul
Layout=

[GroupOrder]
0=Default
P
  export GTK_IM_MODULE=fcitx XMODIFIERS=@im=fcitx QT_IM_MODULE=fcitx
  fcitx5 -d >$OUT/im.log 2>&1; sleep 2
else
  export GTK_IM_MODULE=ibus XMODIFIERS=@im=ibus QT_IM_MODULE=ibus
  ibus-daemon -drx >$OUT/im.log 2>&1; sleep 3
  ibus engine hangul >>$OUT/im.log 2>&1
fi
export IME_LOG=$OUT/app.jsonl INIT_HTML="${INIT_HTML:-안녕 }" MEDIA_DIR="$ROOT/screenshots/media"
: > $IME_LOG
$APP >$OUT/app.log 2>&1 &
APPPID=$!
for i in $(seq 1 40); do xdotool search --name editor_proto >/dev/null 2>&1 && break; sleep 0.5; done
sleep 2.5
WID=$(xdotool search --name editor_proto | head -1)
xdotool windowfocus $WID 2>>$OUT/xdo.log; xdotool windowmove $WID 0 0; sleep 0.5
xdotool getwindowgeometry $WID >> $OUT/xdo.log 2>&1
# click inside the field (far right of first text line) then End => caret at end of text
CX=${CLICKX:-420}; CY=${CLICKY:-175}
xdotool mousemove $CX $CY click 1; sleep 0.7
xdotool key End; sleep 0.4
if [ "$IM" = fcitx5 ]; then fcitx5-remote -o >>$OUT/im.log 2>&1; fcitx5-remote -s hangul >>$OUT/im.log 2>&1; echo "fcitx5-remote state: $(fcitx5-remote)" >> $OUT/im.log; fi
if [ "$IM" = ibus ]; then xdotool key shift+space; sleep 0.6; fi
DL=${DELAY:-120}
k() { xdotool key --delay $DL "$@"; sleep 0.35; }
case $SC in
  # toggle bold with caret only, then Korean "한글", space, "입력"
  bold_ko)     k ctrl+b; k g k s r m f; k space; k d l q f u r ;;
  # bold, Korean, commit by space, keep typing without re-toggle (same as above but longer)  + English afterwards
  bold_ko_en)  k ctrl+b; k g k s r m f; k space; xdotool key ctrl+space; sleep 0.3 ; k a b ;;
  # italic+bold pending, Korean
  bi_ko)       k ctrl+b ctrl+i; k g k s r m f ;;
  # toggle bold then explicit caret move (Left) must clear pending; typing afterwards is plain
  arrow_clear) k ctrl+b; k Left; k g k s ;;
  # underline + Korean then Home/End
  home_clear)  k ctrl+u; k Home; k g k s ;;
esac
sleep 1
import -window root $OUT/screen.png 2>>$OUT/xdo.log
kill $APPPID 2>/dev/null; sleep 0.5
echo "== $IM sc=$SC: last log line:"; tail -1 $IME_LOG
pkill fcitx5; pkill ibus-daemon; pkill openbox; pkill -f "Xvfb $D"; kill $DBUS_SESSION_BUS_PID 2>/dev/null
