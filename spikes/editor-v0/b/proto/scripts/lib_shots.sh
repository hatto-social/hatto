# shared helpers: real Linux build under Xvfb :98, window forced to 980x700 (same as the Anki Add window reference capture)
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
D=:98; APP="$ROOT/build/linux/x64/debug/bundle/editor_proto"
export MEDIA_DIR="$ROOT/screenshots/media"
launch() { # env assignments...
  pkill -f "Xvfb $D" 2>/dev/null; pkill openbox 2>/dev/null; pkill editor_proto 2>/dev/null; sleep 0.8
  Xvfb $D -screen 0 1400x900x24 >/dev/null 2>&1 & sleep 1.2
  export DISPLAY=$D; openbox >/dev/null 2>&1 &
  env "$@" $APP >/tmp/app_shot.log 2>&1 &
  for i in $(seq 1 40); do xdotool search --onlyvisible --name editor_proto >/dev/null 2>&1 && break; sleep 0.5; done
  sleep 1.5; WID=$(xdotool search --onlyvisible --name editor_proto | head -1)
  xdotool windowmove $WID 0 0; xdotool windowsize $WID 980 700; xdotool windowfocus $WID; sleep 1.5
}
shot() { import -window $WID "$1"; }
done_() { pkill editor_proto; pkill openbox; pkill -f "Xvfb $D"; sleep 0.5; }
# common comparison content (identical text goes into real Anki via anki-run/set_compare_note.py)
FRONT='<b>굵게 <i>굵고 기울임</i></b> <u>밑줄</u> H<sub>2</sub>O x<sup>2</sup> <span style="color: #d32f2f">빨강</span> 일반 텍스트<br><img src="demo.png"> [sound:rec.m4a]'
BACK='다음 줄<br>[sound:rec.m4a] <span style="color: #1565c0">파랑</span> 끝'
