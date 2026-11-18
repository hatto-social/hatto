#!/bin/bash
# usage: runprobe.sh <variant dir> ; sets clipboard via clipset for each case, triggers probe, collects JSON
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
V=$1; APP="$ROOT/e/$V/build/linux/x64/release/bundle/e_app"
OUT="$ROOT/e/evidence/$V"; rm -rf "$OUT" /tmp/e_$V; mkdir -p "$OUT"
D=:97; pkill -f "Xvfb $D" 2>/dev/null; Xvfb $D -screen 0 800x600x24 >/dev/null 2>&1 & sleep 1.5; export DISPLAY=$D
eval $(dbus-launch --sh-syntax)
VARIANT=$V $APP > $OUT/app.log 2>&1 & APPPID=$!
for i in $(seq 1 30); do [ -f /tmp/e_$V/ext.txt ] && break; sleep 0.5; done; sleep 1
echo "ext: $(cat /tmp/e_$V/ext.txt)"; cat /tmp/e_$V/rslib.txt; echo
for c in file text filetext png png_html truncated random hugedims huge120; do
  "$ROOT/e/clipset" "$c" "$ROOT/e/fixtures" > "$OUT/clipset_$c.log" 2>&1 & CP=$!; sleep 1.5
  echo $c > /tmp/e_$V/trigger
  for i in $(seq 1 60); do [ -f /tmp/e_$V/probe_$c.json ] && break; sleep 0.5; done
  alive=$(kill -0 $APPPID 2>/dev/null && echo alive || echo DEAD)
  echo "[$c] app=$alive $(cat /tmp/e_$V/probe_$c.json 2>/dev/null | cut -c1-600)"
  cp /tmp/e_$V/probe_$c.json $OUT/ 2>/dev/null; echo "$c app=$alive rss_kb=$(grep VmHWM /proc/$APPPID/status 2>/dev/null | awk '{print $2}')" >> $OUT/summary.txt
  kill $CP 2>/dev/null; sleep 0.5
done
cp /tmp/e_$V/*.txt $OUT/ 2>/dev/null
kill $APPPID 2>/dev/null; pkill -f "Xvfb $D"; kill $DBUS_SESSION_BUS_PID 2>/dev/null
