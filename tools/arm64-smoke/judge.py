#!/usr/bin/env python3

# SPDX-FileCopyrightText: 2026 Hatto Social contributors
#
# SPDX-License-Identifier: AGPL-3.0-or-later

"""ARM64 스모크 판정기. 사용법: judge.py <logfile> [expected.json]
로그 줄 형식: HATTO_SMOKE <id> key=value ... (값에 공백이 있으면 큰따옴표). 스파이크 기존 테스트 줄(FRB_DEVICE_OK, All tests passed!)도 읽는다.
revlog 합격 기준: '카드가 있는 revlog 행 수'(where cid in (select id from cards))가 E(colpkg 가져온 직후)와 R(apkg 경유 상주)에서 같을 것.
revlog 총 행 수는 판정하지 않는다(고아 revlog는 apkg export에서 빠지며, 이 손실은 받아들이고 문서로만 남기기로 했다)."""
import sys, re, json, os
log = open(sys.argv[1], encoding='utf-8', errors='replace').read()
exp = json.load(open(sys.argv[2] if len(sys.argv) > 2 else os.path.dirname(os.path.abspath(__file__)) + '/expected.json'))
rows = {}
for m in re.finditer(r'HATTO_SMOKE (\S+)((?: \w+=(?:"[^"]*"|\S+))*)', log):
    rows[m.group(1)] = {k: v.strip('"') for k, v in re.findall(r'(\w+)=("[^"]*"|\S+)', m.group(2))}
res = []
def chk(name, ok, detail=''): res.append((name, bool(ok), detail))
def I(d, k, default=None):
    try: return int(d[k])
    except Exception: return default
env = rows.get('env', {})
chk('env: arm64-v8a 실기기', env.get('abi') == 'arm64-v8a' and env.get('emulator', '0') != '1', 'abi=%s sdk=%s page=%s model=%s' % (env.get('abi'), env.get('sdk'), env.get('page'), env.get('model')))
chk('A1 스파이크 기존 테스트: FRB_DEVICE_OK + reps=1', re.search(r'FRB_DEVICE_OK fields=\[alpha / beta, hello / world\] reps=1', log) is not None)
chk('A1 All tests passed!', 'All tests passed!' in log)
for name, e in exp['colpkg'].items():
    r = rows.get('col:' + name)
    if not r: chk('B %s: 줄 없음' % name, False); continue
    eE, eR = e['E_after_colpkg_import'], e['R_after_apkg_import']
    chk('B %s E(colpkg 직후) 노트/카드/카드있는revlog' % name, (I(r, 'E_notes'), I(r, 'E_cards'), I(r, 'E_revlog_with_card')) == (eE['notes'], eE['cards'], eE['revlog_with_card']),
        '기기 %s/%s/%s, 기대 %s/%s/%s' % (r.get('E_notes'), r.get('E_cards'), r.get('E_revlog_with_card'), eE['notes'], eE['cards'], eE['revlog_with_card']))
    chk('B %s R(apkg 경유) = E (노트, 카드, 카드있는 revlog)' % name, (I(r, 'R_notes'), I(r, 'R_cards'), I(r, 'R_revlog_with_card')) == (I(r, 'E_notes'), I(r, 'E_cards'), I(r, 'E_revlog_with_card')),
        'R %s/%s/%s vs E %s/%s/%s' % (r.get('R_notes'), r.get('R_cards'), r.get('R_revlog_with_card'), r.get('E_notes'), r.get('E_cards'), r.get('E_revlog_with_card')))
    if name == 'collection_nomedia_new.colpkg':
        res.append(('B nomedia_new: 알려진 고아 손실 (정보용, 합격 기준 아님)', True, 'E 총=%s, E 카드 있는=%s, R 총=%s. R 총 1은 정상(고아 87행 손실을 받아들이기로 함)' % (r.get('E_revlog_total'), r.get('E_revlog_with_card'), r.get('R_revlog_total'))))
f = rows.get('fsrs'); ef = exp['fsrs_synthetic']
if not f: chk('C FSRS: 줄 없음', False)
else:
    chk('C FSRS import 노트/카드/revlog', (I(f, 'import_notes'), I(f, 'import_cards'), I(f, 'import_revlog')) == (ef['R_after_apkg_import']['notes'], ef['R_after_apkg_import']['cards'], ef['R_after_apkg_import']['revlog_total']), str(f.get('import_notes')) + '/' + str(f.get('import_cards')) + '/' + str(f.get('import_revlog')))
    chk('C FSRS fsrs_items == %d' % ef['fsrs_items'], I(f, 'fsrs_items') == ef['fsrs_items'], 'items=%s' % f.get('fsrs_items'))
    chk('C FSRS 파라미터 21개, 전부 유한, 0 < p <= 100', I(f, 'n_params') == 21 and f.get('finite') == '1', 'n=%s finite=%s' % (f.get('n_params'), f.get('finite')))
    chk('C FSRS 같은 기기 2회 결과 동일', f.get('second_identical') == '1')
    chk('C FSRS 읽기 전용(col 행, config 불변)', f.get('col_unchanged') == '1' and f.get('config_unchanged') == '1')
    if f.get('params'):
        p = [float(x) for x in f['params'].split(',')]; d = max(abs(a - b) for a, b in zip(p, ef['params'])) if len(p) == len(ef['params']) else None
        res.append(('C FSRS 호스트(x86) 대비 최대 절대 차이 (정보용, 합격 기준 아님)', True, 'max|Δ|=%s' % d))
    res.append(('C FSRS 소요(정보용)', True, 'device %ss / host %ss' % (f.get('seconds'), ef['host_seconds'][0])))
for jn, key in (('job1', 'job1_default'), ('job2', 'job2_default'), ('job3', 'job3_forced')):
    r = rows.get('nt:' + jn); e = exp['notetype'][key]
    if not r: chk('D 노트타입 %s: 줄 없음' % jn, False); continue
    chk('D 노트타입 %s (%s): 개수 %d→%d, 새 이름 %s' % (jn, key, e['notetypes_before'], e['notetypes_after'], e['new_notetype_names']),
        (I(r, 'before'), I(r, 'after'), sorted(r.get('new_names', '').split('|')) if r.get('new_names') else [], I(r, 'new_notes'), I(r, 'dup')) == (e['notetypes_before'], e['notetypes_after'], e['new_notetype_names'], e['new_notes'], e['duplicate_notes']),
        '기기 %s→%s %s new=%s dup=%s' % (r.get('before'), r.get('after'), r.get('new_names'), r.get('new_notes'), r.get('dup')))
if 'nt:job3' in rows:
    chk('D 강제 복제 후 노트타입별 노트 수', rows['nt:job3'].get('notes_per_notetype') == '|'.join('%s=%d' % (n, c) for n, c in exp['notetype']['notes_per_notetype_after']), rows['nt:job3'].get('notes_per_notetype', ''))
bad = re.findall(r'(UnsatisfiedLinkError|dlopen failed|SIGSEGV|SIGBUS|SIGILL|Fatal signal|HATTO_SMOKE_FAIL[^\n]*|ELF alignment[^\n]*)', log)
chk('로그에 크래시/로드 실패 흔적 없음', not bad, ', '.join(sorted(set(bad)))[:200])
w = max(len(n) for n, _, _ in res)
for n, ok, d in res: print(('PASS ' if ok else 'FAIL ') + n.ljust(w) + ('  | ' + d if d else ''))
fails = [n for n, ok, _ in res if not ok]
print('\n판정: %s (%d/%d)' % ('통과' if not fails else '실패', len(res) - len(fails), len(res)))
sys.exit(1 if fails else 0)
