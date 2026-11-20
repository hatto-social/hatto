# SPDX-FileCopyrightText: 2026 Hatto Social contributors
#
# SPDX-License-Identifier: AGPL-3.0-or-later

# Original host generator. Needs the box harness at /workspace/v0-kickoff/harness; not run in CI.
# ARM64 스모크 기대값 생성 (x86_64 호스트, 무수정 rslib 26.09.3, protobuf 통로만). Hatto 래퍼(prep_E)는 쓰지 않는다: 기기에서도 rslib 호출만으로 재현되도록.
# The three colpkg files are synthetic decks from make_synthetic.py. This script remeasures those files. It does not replace them.
import sys, os, shutil, json, time, zipfile, hashlib, uuid, copy
sys.path.insert(0, '/workspace/v0-kickoff/harness')
from B_lib import *
import rs
from rs import Dev
HERE = '/workspace/v0-kickoff/arm64-smoke'; FILES = HERE + '/files'; W = '/tmp/arm64-smoke'
shutil.rmtree(W, ignore_errors=True); os.makedirs(W)
class Bare(Dev):
    def __init__(self, name):
        self.name = name; init = M('BackendInit')(preferred_langs=['en'], server=False)
        r = rs._send({'op': 'new', 'be': name, 'hex': init.SerializeToString().hex()}); assert r['ok'], r
CARDED = 'select count(*) from revlog where cid in (select id from cards)'
def counts(c): return dict(notes=c.q('select count(*) from notes')[0][0], cards=c.q('select count(*) from cards')[0][0], revlog_total=c.q('select count(*) from revlog')[0][0], revlog_with_card=c.q(CARDED)[0][0], filtered_cards=c.q('select count(*) from cards where odid!=0')[0][0])
def fsrs(R, search=''):
    req = M('ComputeFsrsParamsRequest')(search=search, ignore_revlogs_before_ms=0, num_of_relearning_steps=1, health_check=False)
    t = time.time(); r = M('ComputeFsrsParamsResponse').FromString(R.call('scheduler', 'compute_fsrs_params', req)); dt = time.time() - t
    return dict(fsrs_items=r.fsrs_items, n_params=len(r.params), params=[round(x, 6) for x in r.params], all_finite=all(abs(x) < 1e9 for x in r.params), seconds=round(dt, 3))
out = {'host': 'x86_64 linux, rslib 26.09.3', 'colpkg': {}, 'notetype': {}}
srcs = {'palace.colpkg': FILES + '/palace.colpkg',
        'collection.colpkg': FILES + '/collection.colpkg',
        'collection_nomedia_new.colpkg': FILES + '/collection_nomedia_new.colpkg'}
for i, (name, src) in enumerate(srcs.items()):
    Ed = '%s/E%d' % (W, i); os.makedirs(Ed + '/media', exist_ok=True); bare = Bare('b%d' % i)
    t = time.time()
    bare.call('import_export', 'import_collection_package', M('ImportCollectionPackageRequest')(col_path=Ed + '/collection.anki2', backup_path=src, media_folder=Ed + '/media', media_db=Ed + '/media.db'), backend=True)
    t_col = time.time() - t; rs._send({'op': 'close', 'be': 'b%d' % i})
    E = Col(Ed, fsrs=False); eC = counts(E)
    pk = '%s/E%d.apkg' % (W, i); t = time.time(); export_whole(E, pk); t_exp = time.time() - t; E.close()
    R = Col('%s/R%d' % (W, i)); t = time.time(); rsp = imp(R, pk); t_imp = time.time() - t; rC = counts(R)
    f1 = fsrs(R); f2 = fsrs(R)
    out['colpkg'][name] = dict(bytes=os.path.getsize(src), sha256=hashlib.sha256(open(src, 'rb').read()).hexdigest(), E_after_colpkg_import=eC, R_after_apkg_import=rC, import_new_notes=len(rsp.log.new), host_seconds=dict(colpkg=round(t_col, 3), export=round(t_exp, 3), apkg_import=round(t_imp, 3)),
        fsrs=f1, fsrs_deterministic_on_host=(f1['params'] == f2['params'] and f1['fsrs_items'] == f2['fsrs_items']),
        pass_rule=dict(notes=rC['notes'] == eC['notes'], cards=rC['cards'] == eC['cards'], revlog_with_card=rC['revlog_with_card'] == eC['revlog_with_card']))
    R.close()
# 노트타입: 스톡 apkg + guid 재작성만 하는 최소 준비. x6와 같은 순서 job1(기본) → job2(기본, 같은 apkg 다른 job) → job3(강제 복제)
# Guid rule: imported_note_guid(fixed job UUID, source guid). The old
# uuid5(NAMESPACE_URL, 'smoke:'+job) namespace is not an app rule. Job ids
# are the smoke_jobs object in the shared golden file.
_script_dir = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, _script_dir)
import check_note_guid_golden
_golden = os.path.normpath(os.path.join(
    _script_dir, '..', '..', 'packages', 'hatto_card_contract', 'fixtures', 'note_guid_golden.json'))
_doc = check_note_guid_golden.load_golden(_golden)
_errs = check_note_guid_golden.check(_doc)
if _errs:
    raise SystemExit('\n'.join(_errs))
SMOKE_JOBS = {name: uuid.UUID(value) for name, value in _doc['smoke_jobs'].items()}
apkg = FILES + '/stock-notes.apkg'; st0 = make_fixture(apkg, bulk=0, workdir=W + '/S')
def nts(c): return {r[0]: r[1] for r in c.q('select id,name from notetypes')}
R = Col(W + '/Rnt')
def job(jn, force):
    E = Col(W + '/E' + jn); imp(E, apkg)
    ns = SMOKE_JOBS[jn]
    for nid, g0 in E.q('select id,guid from notes'):
        n = E.note(nid); n.guid = str(uuid.uuid5(ns, g0)); E.update_note(n)
    # 필터 덱 비우기(원본 fixture 에 Filt 가 있다): 카드 상태를 비교하려면 필요
    for did, nm in E.q('select id,name from decks'):
        if deck_get(E, did).get('dyn'):
            E.call('scheduler', 'empty_filtered_deck', M('DeckId')(did=did)); E.call('decks', 'remove_decks', M('DeckIds')(dids=[did]))
    if force:
        for (mid,) in E.q('select distinct mid from notes'):
            j = json.loads(M('generic.Json').FromString(E.call('notetypes', 'get_notetype_legacy', M('NotetypeId')(ntid=mid))).json)
            nf, ntp = len(j['flds']), len(j['tmpls']); oldname = j['name']; j2 = copy.deepcopy(j); j2['id'] = 0
            newid = M('OpChangesWithId').FromString(E.call('notetypes', 'add_notetype_legacy', M('generic.Json')(json=json.dumps(j2).encode()))).id
            nids = [r[0] for r in E.q('select id from notes where mid=?', [mid])]; scm = E.q('select scm from col')[0][0]
            E.call('notetypes', 'change_notetype', M('ChangeNotetypeRequest')(note_ids=nids, new_fields=list(range(nf)), new_templates=list(range(ntp)), old_notetype_id=mid, new_notetype_id=newid, current_schema=scm, old_notetype_name=oldname, is_cloze=False))
            E.call('notetypes', 'remove_notetype', M('NotetypeId')(ntid=mid))
    pk = W + '/E%s.apkg' % jn; export_whole(E, pk); E.close()
    pre = nts(R); rsp = imp(R, pk); post = nts(R)
    return dict(notetypes_before=len(pre), notetypes_after=len(post), new_notetype_names=sorted(post[k] for k in post if k not in pre), new_notes=len(rsp.log.new), duplicate_notes=len(rsp.log.duplicate))
out['notetype']['job1_default'] = job('job1', False)
out['notetype']['job2_default'] = job('job2', False)
out['notetype']['job3_forced'] = job('job3', True)
out['notetype']['notes_per_notetype_after'] = sorted([list(r) for r in R.q('select n.name, count(*) from notes x join notetypes n on n.id=x.mid group by 1')])
out['notetype']['source_apkg'] = dict(bytes=os.path.getsize(apkg), sha256=hashlib.sha256(open(apkg, 'rb').read()).hexdigest())
R.close()
json.dump(out, open(HERE + '/expected.json', 'w'), indent=1, ensure_ascii=False)
print(json.dumps({k: (v if k != 'colpkg' else {n: {kk: vv for kk, vv in d.items() if kk != 'fsrs'} | {'fsrs': {a: b for a, b in d['fsrs'].items() if a != 'params'}} for n, d in v.items()}) for k, v in out.items()}, indent=1, ensure_ascii=False))
