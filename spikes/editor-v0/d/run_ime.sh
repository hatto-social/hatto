#!/bin/bash
# usage: run_ime.sh <fcitx5|ibus> <a|b> <scenario> ; writes evidence in ./evidence/
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IM=$1; FIELD=$2; SC=$3; D=:99
OUT="$ROOT/d/evidence/${IM}_${FIELD}_${SC}"
APP="$ROOT/b/proto/build/linux/x64/debug/bundle/editor_proto"
mkdir -p $OUT; rm -f $OUT/*
pkill -f "Xvfb $D" 2>/dev/null; pkill fcitx5 2>/dev/null; pkill ibus-daemon 2>/dev/null; pkill editor_proto 2>/dev/null; pkill openbox 2>/dev/null; sleep 1
Xvfb $D -screen 0 900x500x24 >$OUT/xvfb.log 2>&1 &
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
export IME_LOG=$OUT/app.jsonl FIELD=$FIELD INIT_HTML="${INIT_HTML:-}"
: > $IME_LOG
$APP >$OUT/app.log 2>&1 &
APPPID=$!
for i in $(seq 1 40); do xdotool search --name editor_proto >/dev/null 2>&1 && break; sleep 0.5; done
sleep 2
WID=$(xdotool search --name editor_proto | head -1)
xdotool windowfocus $WID 2>>$OUT/xdo.log; sleep 0.5
if [ "$FIELD" = a ]; then xdotool mousemove 80 62 click 1; sleep 0.7; fi
if [ "$IM" = fcitx5 ]; then fcitx5-remote -o >>$OUT/im.log 2>&1; fcitx5-remote -s hangul >>$OUT/im.log 2>&1; echo "fcitx5-remote state: $(fcitx5-remote)" >> $OUT/im.log; fi
type() { xdotool key --delay 120 "$@"; sleep 0.4; }
if [ "$IM" = ibus ]; then TK=shift+space; xdotool key $TK; sleep 0.6; else TK=ctrl+space; fi
case $SC in
  basic)   # "한글" = g k s r m f ; then space ; then "데이터" = e p d k x j
    type g k s r m f; type space; type e p d l x j ;;
  enter)   # compose then Shift+Enter then continue
    type g k s; xdotool key --delay 120 shift+Return; sleep 0.4; type r m f ;;
  arrow)   # compose "한" then Left arrow in middle of composition, then type
    type g k s; xdotool key Left; sleep 0.4; type r m f ;;
  bs)      # backspace decomposes jamo: type 한 then 3 backspaces
    type g k s; type BackSpace; type BackSpace; type BackSpace ;;
  fast)    # no delay burst
    xdotool key --delay 10 g k s r m f space e p d l x j; sleep 0.5 ;;
  med)     # 40ms between keys (~25 keys/s)
    xdotool key --delay 40 g k s r m f space e p d l x j; sleep 0.8 ;;
  med80)   # 80ms between keys (~12 keys/s, fast human)
    xdotool key --delay 80 g k s r m f space e p d l x j; sleep 0.8 ;;
  toggle)  # toggle IME to English and back
    type g k; xdotool key $TK; sleep 0.3; type a b; xdotool key $TK; type g k ;;
esac
sleep 1
import -window root $OUT/screen.png 2>>$OUT/xdo.log
kill $APPPID 2>/dev/null; sleep 0.5
echo "== $IM field=$FIELD sc=$SC: last log line:"; tail -1 $IME_LOG
pkill fcitx5; pkill ibus-daemon; pkill openbox; pkill -f "Xvfb $D"; kill $DBUS_SESSION_BUS_PID 2>/dev/null
