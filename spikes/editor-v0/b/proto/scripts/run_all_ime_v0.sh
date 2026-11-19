#!/bin/bash
# runs all pending-style IME scenarios on fcitx5 and ibus; writes evidence-ime/summary.txt
cd "$(dirname "$0")/.."
: > evidence-ime/summary.txt
for IM in fcitx5 ibus; do
 for SC in bold_ko bi_ko arrow_clear home_clear; do
  for DL in 120 40; do
   OUTN=${SC}_d${DL}
   DELAY=$DL scripts/run_ime_v0.sh $IM $SC >/tmp/ime_run.log 2>&1
   mv evidence-ime/${IM}_${SC} evidence-ime/${IM}_${OUTN}
   echo "$IM $SC delay=${DL}ms: $(tail -1 evidence-ime/${IM}_${OUTN}/app.jsonl | python3 -c 'import sys,json; d=json.loads(sys.stdin.read()); print(d["html"], "| pending=", d["pending"], "| marks=", d["marks"])')" | tee -a evidence-ime/summary.txt
  done
 done
done
