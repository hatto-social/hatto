#!/bin/bash
# side_by_side.sh <anki.png> <ours.png> <out.png> [crop WxH+X+Y] [scale%]   -> Anki (left) | ours (right), labelled
A=$1; O=$2; OUT=$3; CROP=${4:-}; SC=${5:-100}
T=$(mktemp -d)
if [ -n "$CROP" ]; then convert "$A" -crop $CROP +repage -filter point -resize ${SC}% $T/a.png; convert "$O" -crop $CROP +repage -filter point -resize ${SC}% $T/o.png
else convert "$A" -resize ${SC}% $T/a.png; convert "$O" -resize ${SC}% $T/o.png; fi
convert $T/a.png -background '#222' -fill white -gravity north -splice 0x26 -pointsize 16 -annotate +0+4 'Anki Desktop 26.09.3 (real)' $T/a2.png
convert $T/o.png -background '#222' -fill white -gravity north -splice 0x26 -pointsize 16 -annotate +0+4 'Hatto prototype B (Flutter)' $T/o2.png
convert $T/a2.png \( -size 8x1 xc:'#222' \) $T/o2.png +append -background '#222' "$OUT"
rm -rf $T
