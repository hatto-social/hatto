# Demo-recording helpers: real Linux build under Xvfb, ffmpeg x11grab, xdotool at human pace, optional real fcitx5.
# source this file; see record_demos.sh
xdotool() { timeout 10 /usr/bin/xdotool "$@"; }
PROTO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP=$PROTO/build/linux/x64/debug/bundle/editor_proto
D=:96
VID=$PROTO/videos; WORK=/tmp/rec_work; mkdir -p $VID $WORK
DEMO_MEDIA=$WORK/media
FONT_B=/usr/share/fonts/opentype/noto/NotoSansCJK-Bold.ttc
# 30 fps, window client area is cropped (WxH = 980x700), caption bar added on top
W=980; H=700; BAR=76

mkmedia() { mkdir -p $DEMO_MEDIA; cp $PROTO/screenshots/media/demo.png $DEMO_MEDIA/demo.png
  convert $PROTO/screenshots/media/demo.png -modulate 100,100,40 -fill 'rgba(255,200,0,0.25)' -colorize 25% $DEMO_MEDIA/paste-new.png 2>/dev/null || cp $PROTO/screenshots/media/demo.png $DEMO_MEDIA/paste-new.png; }

# usage: start_env [im]   -> Xvfb + openbox (+ dbus/fcitx5 when im=fcitx5)
start_env() {
  pkill -f "Xvfb $D" 2>/dev/null; pkill openbox 2>/dev/null; pkill editor_proto 2>/dev/null; pkill fcitx5 2>/dev/null; sleep 0.8
  Xvfb $D -screen 0 1400x900x24 >/dev/null 2>&1 & sleep 1.2
  export DISPLAY=$D
  eval $(dbus-launch --sh-syntax)
  openbox >/dev/null 2>&1 &
  if [ "$1" = fcitx5 ]; then
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
    fcitx5 -d >$WORK/fcitx.log 2>&1; sleep 2
  else
    unset GTK_IM_MODULE XMODIFIERS QT_IM_MODULE
  fi
}
stop_env() { pkill editor_proto; pkill fcitx5; pkill openbox; pkill -f "Xvfb $D"; kill $DBUS_SESSION_BUS_PID 2>/dev/null; sleep 0.5; }

# usage: launch_app VAR=val ...   (window 980x700 at 0,0; computes client offset AX,AY)
launch_app() {
  env MEDIA_DIR=$DEMO_MEDIA "$@" $APP >$WORK/app.log 2>&1 &
  for i in $(seq 1 40); do xdotool search --onlyvisible --name editor_proto >/dev/null 2>&1 && break; sleep 0.5; done
  sleep 1.5; WID=$(xdotool search --onlyvisible --name editor_proto | head -1)
  xdotool windowmove $WID 0 0; xdotool windowsize $WID $W $H; xdotool windowfocus $WID; sleep 1.5
  eval $(xwininfo -id $WID | awk '/Absolute upper-left X/{print "AX="$NF} /Absolute upper-left Y/{print "AY="$NF}')
  xdotool mousemove $((AX+700)) $((AY+400)); sleep 0.3
}

# ---- recording ----
T0=0; NOTES=$WORK/notes.txt
now() { date +%s.%N; }
rec_start() { : > $NOTES; ffmpeg -y -loglevel error -f x11grab -framerate 30 -video_size ${W}x${H} -i $D+$AX,$AY -c:v libx264 -preset ultrafast -crf 18 -pix_fmt yuv420p $WORK/raw.mkv </dev/null 2>$WORK/ff.log & FFPID=$!
  sleep 0.8; T0=$(now); }
rec_stop() { sleep 1.0; note ""; kill -INT $FFPID; wait $FFPID 2>/dev/null; }
# note "text": subtitle line (key/mouse action hint) from now until the next note
note() { printf '%s\t%s\n' "$(awk -v a=$(now) -v b=$T0 'BEGIN{printf "%.3f", a-b}')" "$1" >> $NOTES; }

# finish <outfile> "<korean caption>"  -> caption bar (title + action notes) burned in, H.264 yuv420p 30fps faststart
finish() {
  local out=$1 cap=$2; local end; end=$(ffprobe -v error -show_entries format=duration -of csv=p=0 $WORK/raw.mkv)
  python3 - "$NOTES" "$WORK/notes.ass" "$end" "$W" "$((H+BAR))" <<'PY'
import sys
rows=[l.rstrip('\n').split('\t',1) for l in open(sys.argv[1]) if l.strip()]
end=float(sys.argv[3]); w=sys.argv[4]; h=sys.argv[5]
def ts(t):
    t=max(0,t); return '%d:%02d:%05.2f'%(int(t//3600),int(t%3600//60),t%60)
hdr=f"""[Script Info]
ScriptType: v4.00+
PlayResX: {w}
PlayResY: {h}
WrapStyle: 2

[V4+ Styles]
Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
Style: Default,Noto Sans CJK KR,22,&H0000D7FF,&H000000FF,&H00111827,&H00000000,0,0,0,0,100,100,0,0,1,1,0,8,10,10,46,1

[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
"""
ev=[]
for i,(t,txt) in enumerate(rows):
    if not txt: continue
    t0=float(t); t1=float(rows[i+1][0]) if i+1<len(rows) else end
    txt=txt.replace('{','\\{').replace('}','\\}')
    ev.append('Dialogue: 0,%s,%s,Default,,0,0,0,,%s'%(ts(t0),ts(t1),txt))
open(sys.argv[2],'w').write(hdr+'\n'.join(ev)+'\n')
PY
  printf '%s' "$cap" > $WORK/cap.txt
  ffmpeg -y -loglevel error -i $WORK/raw.mkv -vf "pad=${W}:$((H+BAR)):0:${BAR}:color=0x111827,drawtext=fontfile=$FONT_B:textfile=$WORK/cap.txt:fontcolor=white:fontsize=26:x=(w-text_w)/2:y=10,ass=$WORK/notes.ass" \
    -r 30 -c:v libx264 -preset medium -crf 27 -pix_fmt yuv420p -movflags +faststart -an $out
}

# ---- human-pace input ----
rnd() { awk -v a=$1 -v b=$2 'BEGIN{srand(); printf "%.3f", a+rand()*(b-a)}'; }
pause() { sleep ${1:-0.6}; }
# mv X Y [secs]  (window-relative, smooth visible mouse path)
mv() {
  local tx=$((AX+$1)) ty=$((AY+$2)) dur=${3:-0.5}; eval $(xdotool getmouselocation --shell); local sx=$X sy=$Y n=18 i
  for i in $(seq 1 $n); do
    local f; f=$(awk -v i=$i -v n=$n 'BEGIN{t=i/n; printf "%.4f", t*t*(3-2*t)}')
    xdotool mousemove $(awk -v a=$sx -v b=$tx -v f=$f 'BEGIN{printf "%d", a+(b-a)*f}') $(awk -v a=$sy -v b=$ty -v f=$f 'BEGIN{printf "%d", a+(b-a)*f}')
    sleep $(awk -v d=$dur -v n=$n 'BEGIN{printf "%.4f", d/n}')
  done
}
clk() { mv $1 $2 ${3:-0.5}; sleep 0.25; xdotool click 1; sleep 0.6; }
hover() { mv $1 $2 ${3:-0.5}; sleep ${4:-1.6}; }   # waits for tooltip (500ms) + reading time
key() { xdotool key --delay 60 "$@"; sleep 0.6; }
keys() { for k in "$@"; do xdotool key --delay 60 $k; sleep $(rnd 0.35 0.55); done; sleep 0.3; }   # steady one-by-one keys (arrows etc.)
# typ "text": ~10 chars/s
typ() { local s=$1 i ch; for ((i=0;i<${#s};i++)); do ch=${s:i:1}; if [ "$ch" = " " ]; then xdotool key space; else xdotool type --delay 0 -- "$ch"; fi; sleep $(rnd 0.07 0.12); done; sleep 0.4; }
# ktyp "g k s ...": Korean via fcitx5 hangul (QWERTY jamo keys), ~8 keys/s
ktyp() { for k in "$@"; do xdotool key --delay 40 $k; sleep $(rnd 0.09 0.15); done; sleep 0.5; }
ime_hangul() { fcitx5-remote -o >/dev/null 2>&1; fcitx5-remote -s hangul >/dev/null 2>&1; sleep 0.5; }
