# SPDX-FileCopyrightText: 2026 Hatto Social contributors
#
# SPDX-License-Identifier: AGPL-3.0-or-later

# Original host generator for the synthetic FSRS package. Needs the box harness; not run in CI.
# fsrs-synthetic-37k.apkg 기대값(호스트 x86_64). 합성 revlog 37,312행(카드 4,000장), 하네스 x4_fsrs.py(4000 20)가 만든 파일.
import sys, json, shutil, hashlib, time, os
sys.path.insert(0, '/workspace/v0-kickoff/harness')
from B_lib import *
HERE = '/workspace/v0-kickoff/arm64-smoke'; W = '/tmp/arm64-smoke-fsrs'; shutil.rmtree(W, ignore_errors=True); os.makedirs(W)
apkg = HERE + '/files/fsrs-synthetic-37k.apkg'
R = Col(W + '/R'); t = time.time(); rsp = imp(R, apkg); ti = time.time() - t
c = dict(notes=R.q('select count(*) from notes')[0][0], cards=R.q('select count(*) from cards')[0][0], revlog_total=R.q('select count(*) from revlog')[0][0], revlog_with_card=R.q('select count(*) from revlog where cid in (select id from cards)')[0][0])
def run():
    req = M('ComputeFsrsParamsRequest')(search='', ignore_revlogs_before_ms=0, num_of_relearning_steps=1, health_check=False)
    t = time.time(); r = M('ComputeFsrsParamsResponse').FromString(R.call('scheduler', 'compute_fsrs_params', req)); return r, time.time() - t
before = R.q('select crt,mod,scm,usn from col')[0]; cfg0 = R.q('select count(*), sum(length(val)) from config')[0]
r1, t1 = run(); r2, t2 = run()
after = R.q('select crt,mod,scm,usn from col')[0]; cfg1 = R.q('select count(*), sum(length(val)) from config')[0]
d = json.load(open(HERE + '/expected.json'))
d['fsrs_synthetic'] = dict(bytes=os.path.getsize(apkg), sha256=hashlib.sha256(open(apkg, 'rb').read()).hexdigest(), R_after_apkg_import=c, import_new_notes=len(rsp.log.new), host_import_seconds=round(ti, 3),
    fsrs_items=r1.fsrs_items, n_params=len(r1.params), params=[round(x, 6) for x in r1.params], host_seconds=[round(t1, 3), round(t2, 3)], deterministic_on_host=[round(x, 9) for x in r1.params] == [round(x, 9) for x in r2.params],
    col_row_unchanged=(before == after), config_unchanged=(cfg0 == cfg1))
json.dump(d, open(HERE + '/expected.json', 'w'), indent=1, ensure_ascii=False)
f = d['fsrs_synthetic']; print({k: v for k, v in f.items() if k != 'params'}); print(f['params'])
