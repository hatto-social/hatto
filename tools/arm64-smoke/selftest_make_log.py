# judge.py 자체 검증용: expected.json 값으로 '이상적인 기기 로그'를 만든다. (기기 로그가 아니다. 판정기가 잘 읽는지만 확인)
import json, os, sys
HERE = os.path.dirname(os.path.abspath(__file__))
e = json.load(open(os.path.join(HERE, 'expected.json'))); L = []
L.append('HATTO_SMOKE env abi=arm64-v8a sdk=35 page=16384 model="SELFTEST" emulator=0')
L.append('FRB_DEVICE_OK fields=[alpha / beta, hello / world] reps=1'); L.append('All tests passed!')
for n, v in e['colpkg'].items():
    a, b = v['E_after_colpkg_import'], v['R_after_apkg_import']
    L.append('HATTO_SMOKE col:%s E_notes=%d E_cards=%d E_revlog_total=%d E_revlog_with_card=%d R_notes=%d R_cards=%d R_revlog_total=%d R_revlog_with_card=%d' % (n, a['notes'], a['cards'], a['revlog_total'], a['revlog_with_card'], b['notes'], b['cards'], b['revlog_total'], b['revlog_with_card']))
f = e['fsrs_synthetic']; r = f['R_after_apkg_import']
L.append('HATTO_SMOKE fsrs import_notes=%d import_cards=%d import_revlog=%d fsrs_items=%d n_params=%d finite=1 second_identical=1 col_unchanged=1 config_unchanged=1 seconds=0.9 params=%s' % (r['notes'], r['cards'], r['revlog_total'], f['fsrs_items'], f['n_params'], ','.join(map(str, f['params']))))
for jn, k in (('job1', 'job1_default'), ('job2', 'job2_default'), ('job3', 'job3_forced')):
    t = e['notetype'][k]; L.append('HATTO_SMOKE nt:%s before=%d after=%d new_names="%s" new_notes=%d dup=%d' % (jn, t['notetypes_before'], t['notetypes_after'], '|'.join(t['new_notetype_names']), t['new_notes'], t['duplicate_notes']) + (' notes_per_notetype="%s"' % '|'.join('%s=%d' % (n, c) for n, c in e['notetype']['notes_per_notetype_after']) if jn == 'job3' else ''))
print('\n'.join(L))
