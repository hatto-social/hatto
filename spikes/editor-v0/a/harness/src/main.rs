//! Spike a: ChangeNotetype + guid/note_map preservation through a "write-wrapper-equivalent"
//! (guard -> intent -> rslib call -> verify -> complete) against UNMODIFIED rslib 26.09.3.
//! The wrapper here is a stand-in written for the spike (hatto_store source not available): labelled as such in the report.
use anki::collection::{Collection, CollectionBuilder};
use anki::notetype::ChangeNotetypeInput;
use anki::prelude::*;
use rusqlite::{params, Connection};
use std::collections::HashMap;
use std::process::Command;
use std::time::Instant;

const NS: uuid::Uuid = uuid::Uuid::from_u128(0x6ba7b8119dad11d180b400c04fd430c8); // NAMESPACE_URL

fn guid_of(seed: &str) -> String { uuid::Uuid::new_v5(&NS, format!("hatto-editor-spike:{seed}").as_bytes()).to_string() }

struct W { col: Collection, side: Connection, cap: usize, journal_policy_none: bool }

#[derive(Debug)]
enum Out { Done { ms: u128, field_value_changes: usize, notes: usize }, Rejected(String) }

fn crash_at() -> Option<String> { std::env::var("CRASH_AT").ok() }
fn maybe_crash(p: &str) { if crash_at().as_deref() == Some(p) { eprintln!("CRASH injected at {p}"); std::process::exit(137); } }

fn open(dir: &str) -> W {
    std::fs::create_dir_all(dir).unwrap();
    let col = CollectionBuilder::new(format!("{dir}/collection.anki2")).build().unwrap();
    let side = Connection::open(format!("{dir}/side.db")).unwrap();
    side.execute_batch("
      create table if not exists deck_map(guid text primary key, deck_id integer not null);
      create table if not exists note_map(guid text primary key, note_id integer not null unique, home_deck_guid text);
      create table if not exists edit_journal(id integer primary key autoincrement, entity text, guid text, op text, payload text);
      create table if not exists intent(id integer primary key autoincrement, op text, targets text, expected text, state text);
    ").unwrap();
    W { col, side, cap: 5000, journal_policy_none: true }
}

impl W {
    fn nt(&mut self, name: &str) -> NotetypeId { self.col.get_notetype_by_name(name).unwrap().unwrap().id }
    fn deck(&mut self, name: &str) -> DeckId {
        let d = self.col.get_or_create_normal_deck(name).unwrap();
        self.side.execute("insert or ignore into deck_map values(?,?)", params![guid_of(&format!("deck:{name}")), d.id.0]).unwrap();
        d.id
    }
    fn deck_guid(name: &str) -> String { guid_of(&format!("deck:{name}")) }
    fn add_note(&mut self, seed: &str, nt: NotetypeId, fields: &[&str], did: DeckId, deck_name: &str) -> NoteId {
        let ntype = self.col.get_notetype(nt).unwrap().unwrap();
        let mut n = Note::new(&ntype);
        n.guid = guid_of(&format!("note:{seed}")); // device-issued uuid5 (wrapper-equivalent)
        for (i, f) in fields.iter().enumerate() { n.set_field(i, *f).unwrap(); }
        self.col.add_note(&mut n, did).unwrap();
        self.side.execute("insert into note_map values(?,?,?)", params![n.guid, n.id.0, Self::deck_guid(deck_name)]).unwrap();
        self.side.execute("insert into edit_journal(entity,guid,op,payload) values('note',?, 'add_note','{}')", params![n.guid]).unwrap();
        n.id
    }
    fn journal_rows(&self) -> i64 { self.side.query_row("select count(*) from edit_journal", [], |r| r.get(0)).unwrap() }
    fn snapshot(&mut self, ids: &[NoteId]) -> HashMap<i64, (String, i64, Vec<String>, i64)> {
        ids.iter().map(|id| { let n = self.col.storage.get_note(*id).unwrap().unwrap(); (id.0, (n.guid.clone(), n.notetype_id.0, n.fields().clone(), n.mtime.0)) }).collect()
    }
    fn mapping_check(&mut self) -> Result<(), String> {
        let rows: Vec<(String, i64)> = { let mut s = self.side.prepare("select guid,note_id from note_map").unwrap();
            s.query_map([], |r| Ok((r.get(0)?, r.get(1)?))).unwrap().map(|x| x.unwrap()).collect() };
        for (g, id) in &rows {
            match self.col.storage.get_note(NoteId(*id)).unwrap() {
                None => return Err(format!("note_map row {g} -> {id}: note missing in collection")),
                Some(n) if &n.guid != g => return Err(format!("note_map row {g} -> {id}: collection guid is {}", n.guid)),
                _ => {}
            }
        }
        let total = self.col.search_notes_unordered("").unwrap().len();
        if total != rows.len() { return Err(format!("note_map has {} rows but collection has {} notes", rows.len(), total)); }
        Ok(())
    }
    /// wrapper-equivalent ChangeNotetype
    fn change_notetype(&mut self, ids: &[NoteId], old: NotetypeId, new: NotetypeId, new_fields: Vec<Option<usize>>, new_templates: Option<Vec<Option<usize>>>, schema_override: Option<i64>) -> Out {
        // ---- guard (before any write) ----
        if ids.len() > self.cap { return Out::Rejected(format!("guard: {} notes > cap {}", ids.len(), self.cap)); }
        let info = self.col.notetype_change_info(old, new).unwrap();
        let cur_schema = info.input.current_schema;
        let schema = schema_override.map(TimestampMillis).unwrap_or(cur_schema);
        if schema != cur_schema { return Out::Rejected(format!("guard: stale current_schema {} != {}", schema.0, cur_schema.0)); }
        for id in ids {
            let g: Option<String> = self.side.query_row("select guid from note_map where note_id=?", [id.0], |r| r.get(0)).ok();
            if g.is_none() { return Out::Rejected(format!("guard: note {} not in note_map", id.0)); }
            let n = self.col.storage.get_note(*id).unwrap();
            match n { None => return Out::Rejected(format!("guard: note {} missing", id.0)),
                Some(n) if n.notetype_id != old => return Out::Rejected(format!("guard(N3): note {} has notetype {} != old {}", id.0, n.notetype_id.0, old.0)), _ => {} }
        }
        let before = self.snapshot(ids);
        let guids: Vec<String> = before.values().map(|v| v.0.clone()).collect();
        // ---- intent ----
        self.side.execute("insert into intent(op,targets,expected,state) values('change_notetype',?,?, 'pending')",
            params![serde_json::to_string(&guids).unwrap(), serde_json::json!({"new_mid": new.0, "ids": ids.iter().map(|i| i.0).collect::<Vec<_>>()}).to_string()]).unwrap();
        let intent_id = self.side.last_insert_rowid();
        maybe_crash("after_intent");
        let t = Instant::now();
        let input = ChangeNotetypeInput { current_schema: schema, note_ids: ids.to_vec(), old_notetype_name: info.old_notetype_name.clone(), old_notetype_id: old, new_notetype_id: new, new_fields, new_templates };
        if let Err(e) = self.col.change_notetype_of_notes(input) {
            self.side.execute("update intent set state='failed' where id=?", [intent_id]).unwrap();
            return Out::Rejected(format!("rslib error: {e:?}"));
        }
        let ms = t.elapsed().as_millis();
        maybe_crash("after_rslib");
        // ---- verify ----
        let after = self.snapshot(ids);
        let mut fvc = 0;
        for (id, b) in &before {
            let a = &after[id];
            assert_eq!(a.0, b.0, "GUID CHANGED for note {id}");
            assert_eq!(a.1, new.0, "notetype_id not updated for note {id}");
            if a.2 != b.2 { fvc += 1; }
        }
        maybe_crash("before_complete");
        let tx = self.side.transaction().unwrap();
        tx.execute("update intent set state='done' where id=?", [intent_id]).unwrap();
        // journal policy per scope: 0 rows for ChangeNotetype
        tx.commit().unwrap();
        Out::Done { ms, field_value_changes: fvc, notes: ids.len() }
    }
    /// startup recovery: pending intents -> read collection (M1-equivalent) -> complete or discard
    fn recover(&mut self) -> Vec<String> {
        let rows: Vec<(i64, String)> = { let mut s = self.side.prepare("select id,expected from intent where state='pending'").unwrap();
            s.query_map([], |r| Ok((r.get(0)?, r.get(1)?))).unwrap().map(|x| x.unwrap()).collect() };
        let mut log = vec![];
        for (id, exp) in rows {
            let v: serde_json::Value = serde_json::from_str(&exp).unwrap();
            let new_mid = v["new_mid"].as_i64().unwrap();
            let ids: Vec<i64> = v["ids"].as_array().unwrap().iter().map(|x| x.as_i64().unwrap()).collect();
            let done = ids.iter().filter(|i| self.col.storage.get_note(NoteId(**i)).unwrap().map(|n| n.notetype_id.0 == new_mid).unwrap_or(false)).count();
            let st = if done == ids.len() { "done(recovered)" } else if done == 0 { "discarded" } else { "PARTIAL!" };
            self.side.execute("update intent set state=? where id=?", params![st, id]).unwrap();
            log.push(format!("intent {id}: {done}/{} notes already new -> {st}", ids.len()));
        }
        log
    }
    fn pending(&self) -> i64 { self.side.query_row("select count(*) from intent where state='pending'", [], |r| r.get(0)).unwrap() }
    fn done_intents(&self) -> i64 { self.side.query_row("select count(*) from intent where state like 'done%'", [], |r| r.get(0)).unwrap() }
    fn cards(&mut self, nid: NoteId) -> Vec<(i64, usize, i64)> { self.col.storage.all_cards_of_note(nid).unwrap().iter().map(|c| (c.id().0, c.template_idx() as usize, c.deck_id().0)).collect() }
}

macro_rules! check { ($name:expr, $cond:expr, $($arg:tt)*) => {{ let ok = $cond; println!("[{}] {} :: {}", if ok {"PASS"} else {"FAIL"}, $name, format!($($arg)*)); if !ok { FAILS.fetch_add(1, std::sync::atomic::Ordering::SeqCst); } }}; }
static FAILS: std::sync::atomic::AtomicUsize = std::sync::atomic::AtomicUsize::new(0);

fn fresh(dir: &str) -> W { let _ = std::fs::remove_dir_all(dir); open(dir) }

fn scenarios(base: &str) {
    // ---------- S1..S6: functional
    let mut w = fresh(&format!("{base}/s1"));
    let basic = w.nt("Basic"); let rev = w.nt("Basic (and reversed card)"); let cloze = w.nt("Cloze");
    let d1 = w.deck("D1"); let d2 = w.deck("D2"); let d3 = w.deck("D3");
    let mut ids = vec![];
    for i in 0..5 { let (d, dn) = [(d1,"D1"),(d2,"D2"),(d3,"D3")][i % 3]; ids.push(w.add_note(&format!("b{i}"), basic, &[&format!("Q{i} 한글"), &format!("A{i}")], d, dn)); }
    let before_cards: Vec<_> = ids.iter().map(|i| w.cards(*i)).collect();
    let j0 = w.journal_rows();
    std::thread::sleep(std::time::Duration::from_millis(1100));
    let snap0 = w.snapshot(&ids);
    let r = w.change_notetype(&ids, basic, rev, vec![Some(0), Some(1)], Some(vec![Some(0), None]), None);
    println!("S1 outcome {r:?}");
    let snap1 = w.snapshot(&ids);
    check!("S1 Basic->Reversed guid/id", ids.iter().all(|i| snap0[&i.0].0 == snap1[&i.0].0) && matches!(r, Out::Done{..}), "guids kept for {} notes", ids.len());
    check!("S1 notetype_id==requested", ids.iter().all(|i| snap1[&i.0].1 == rev.0), "all mid==rev");
    check!("S1 note_map unchanged + mapping check", w.mapping_check().is_ok(), "{:?}", w.mapping_check());
    check!("S1 journal rows +0", w.journal_rows() == j0, "journal {} -> {}", j0, w.journal_rows());
    check!("S1 intent done=1,pending=0", w.done_intents() == 1 && w.pending() == 0, "done={} pending={}", w.done_intents(), w.pending());
    let after_cards: Vec<_> = ids.iter().map(|i| w.cards(*i)).collect();
    check!("S1 original card ids kept", before_cards.iter().zip(&after_cards).all(|(b, a)| a.iter().any(|c| c.0 == b[0].0)), "card ids kept");
    println!("S1 data: new-card decks vs home deck (note idx: original card deck, new card deck): {:?}", before_cards.iter().zip(&after_cards).map(|(b, a)| (b[0].2, a.iter().find(|c| c.1 == 1).map(|c| c.2))).collect::<Vec<_>>());
    println!("S1 mtime changed: {:?}", ids.iter().map(|i| snap1[&i.0].3 - snap0[&i.0].3).collect::<Vec<_>>());
    // S1b: Undo/Redo right after
    let o = w.col.undo(); println!("S1b undo -> {:?}", o.as_ref().map(|_| "ok").map_err(|e| format!("{e:?}")));
    let s2 = w.snapshot(&ids);
    check!("S1b undo: guid/id kept, mid back to old", ids.iter().all(|i| s2[&i.0].0 == snap0[&i.0].0 && s2[&i.0].1 == basic.0), "mid after undo = {:?}", ids.iter().map(|i| s2[&i.0].1 == basic.0).collect::<Vec<_>>());
    check!("S1b undo: note_map still consistent", w.mapping_check().is_ok(), "{:?}", w.mapping_check());
    println!("S1b NOTE: wrapper has no intent/journal for rslib undo unless it wraps col.undo(); rslib undo changed notetype_id silently -> side DB cannot know without M1 comparison");
    let o = w.col.redo(); println!("S1b redo -> {:?}", o.as_ref().map(|_| "ok").map_err(|e| format!("{e:?}")));
    let s3 = w.snapshot(&ids);
    check!("S1b redo: guid/id kept, mid==rev", ids.iter().all(|i| s3[&i.0].0 == snap0[&i.0].0 && s3[&i.0].1 == rev.0), "ok");
    check!("S1b redo: mapping", w.mapping_check().is_ok(), "{:?}", w.mapping_check());

    // S2 reversed -> Basic (drop template 1: deletes cards)
    let cards_before: usize = ids.iter().map(|i| w.cards(*i).len()).sum();
    std::thread::sleep(std::time::Duration::from_millis(1100));
    let r = w.change_notetype(&ids, rev, basic, vec![Some(0), Some(1)], Some(vec![Some(0)]), None);
    let cards_after: usize = ids.iter().map(|i| w.cards(*i).len()).sum();
    let s4 = w.snapshot(&ids);
    check!("S2 Reversed->Basic guid/id", matches!(r, Out::Done{..}) && ids.iter().all(|i| s4[&i.0].0 == snap0[&i.0].0 && s4[&i.0].1 == basic.0), "cards {} -> {}", cards_before, cards_after);
    check!("S2 mapping", w.mapping_check().is_ok(), "{:?}", w.mapping_check());

    // S3 Basic -> Cloze ; Cloze -> Basic
    std::thread::sleep(std::time::Duration::from_millis(1100));
    let r = w.change_notetype(&ids[..2], basic, cloze, vec![Some(0), Some(1)], None, None);
    let s5 = w.snapshot(&ids[..2]);
    check!("S3 Basic->Cloze", matches!(r, Out::Done{..}) && ids[..2].iter().all(|i| s5[&i.0].0 == snap0[&i.0].0 && s5[&i.0].1 == cloze.0), "cards after = {:?}", ids[..2].iter().map(|i| w.cards(*i).len()).collect::<Vec<_>>());
    std::thread::sleep(std::time::Duration::from_millis(1100));
    let r = w.change_notetype(&ids[..2], cloze, basic, vec![Some(0), Some(1)], Some(vec![Some(0)]), None);
    check!("S3 Cloze->Basic", matches!(r, Out::Done{..}), "{:?}", r);
    check!("S3 mapping", w.mapping_check().is_ok(), "{:?}", w.mapping_check());

    // S4 field swap (Front<->Back)
    std::thread::sleep(std::time::Duration::from_millis(1100));
    let pre = w.snapshot(&ids[..3]);
    let r = w.change_notetype(&ids[..3], basic, basic, vec![Some(1), Some(0)], Some(vec![Some(0)]), None);
    let post = w.snapshot(&ids[..3]);
    check!("S4 field swap guid/id", ids[..3].iter().all(|i| pre[&i.0].0 == post[&i.0].0), "{:?}", r);
    println!("S4 field values before={:?} after={:?}", pre[&ids[0].0].2, post[&ids[0].0].2);
    check!("S4 FINDING field-level journal gap", true, "field contents changed for {:?} notes but journal rows = {} (field-level LWW would not see this)", if let Out::Done{field_value_changes,..} = r {field_value_changes} else {0}, w.journal_rows() - j0);

    // S5 mixed notetypes -> rslib alone accepts? wrapper guard rejects
    std::thread::sleep(std::time::Duration::from_millis(1100));
    let cl = w.add_note("cl", cloze, &["{{c1::x}} y", ""], d1, "D1");
    let mixed = vec![ids[0], cl];
    let r = w.change_notetype(&mixed, basic, rev, vec![Some(0), Some(1)], Some(vec![Some(0), None]), None);
    check!("S5 guard rejects mixed notetypes (N3)", matches!(&r, Out::Rejected(m) if m.contains("N3")), "{:?}", r);
    check!("S5 no state change after reject", w.col.storage.get_note(cl).unwrap().unwrap().notetype_id == cloze && w.pending() == 0, "cloze note still cloze, pending={}", w.pending());
    // S5b raw rslib (no guard) with mixed
    let info = w.col.notetype_change_info(basic, rev).unwrap();
    let raw = w.col.change_notetype_of_notes(ChangeNotetypeInput { current_schema: info.input.current_schema, note_ids: mixed.clone(), old_notetype_name: "Basic".into(), old_notetype_id: basic, new_notetype_id: rev, new_fields: vec![Some(0), Some(1)], new_templates: Some(vec![Some(0), None]) });
    println!("S5b raw rslib with mixed note_ids -> {:?}; cloze note mid now = {:?}", raw.as_ref().map(|_| "accepted").map_err(|e| format!("{e:?}")), w.col.storage.get_note(cl).unwrap().unwrap().notetype_id == rev);
    // S6 stale schema
    let r = w.change_notetype(&ids[..1], rev, basic, vec![Some(0), Some(1)], Some(vec![Some(0)]), Some(1234));
    check!("S6 guard rejects stale current_schema", matches!(&r, Out::Rejected(m) if m.contains("stale")), "{:?}", r);
    // S6b raw rslib with stale schema
    let info = w.col.notetype_change_info(rev, basic).unwrap();
    let raw = w.col.change_notetype_of_notes(ChangeNotetypeInput { current_schema: TimestampMillis(1234), note_ids: vec![ids[0]], old_notetype_name: "x".into(), old_notetype_id: rev, new_notetype_id: basic, new_fields: vec![Some(0), Some(1)], new_templates: Some(vec![Some(0)]) });
    println!("S6b raw rslib stale schema -> {:?} (info schema {})", raw.as_ref().map(|_| "accepted").map_err(|e| format!("{e:?}")), info.input.current_schema.0);
    let _ = w.col.close(None);
}

fn scale(base: &str, n: usize) {
    let mut w = fresh(&format!("{base}/scale{n}"));
    w.cap = 1_000_000; // lift cap for measurement; default cap tested below
    let basic = w.nt("Basic"); let rev = w.nt("Basic (and reversed card)");
    let d1 = w.deck("D1");
    let t = Instant::now();
    w.side.execute_batch("begin").unwrap();
    let mut ids = vec![];
    for i in 0..n { ids.push(w.add_note(&format!("s{i}"), basic, &[&format!("Q{i}"), &format!("A{i}")], d1, "D1")); }
    w.side.execute_batch("commit").unwrap();
    println!("scale{n}: setup {} notes in {} ms", n, t.elapsed().as_millis());
    std::thread::sleep(std::time::Duration::from_millis(1100));
    let t = Instant::now();
    let j0 = w.journal_rows();
    let r = w.change_notetype(&ids, basic, rev, vec![Some(0), Some(1)], Some(vec![Some(0), None]), None);
    let total = t.elapsed().as_millis();
    println!("scale{n}: Basic->Reversed {:?}; wrapper total {} ms (guard+intent+rslib+verify)", r, total);
    check!(&format!("scale{n} guid kept + mapping"), matches!(r, Out::Done{..}) && w.mapping_check().is_ok(), "journal +{}", w.journal_rows() - j0);
    std::thread::sleep(std::time::Duration::from_millis(1100));
    let t = Instant::now();
    let r = w.change_notetype(&ids, rev, basic, vec![Some(0), Some(1)], Some(vec![Some(0)]), None);
    println!("scale{n}: Reversed->Basic {:?}; wrapper total {} ms", r, t.elapsed().as_millis());
    w.cap = 5000;
    let r = w.change_notetype(&ids, basic, rev, vec![Some(0), Some(1)], Some(vec![Some(0), None]), None);
    check!(&format!("scale{n} default cap(5000) guard"), (n > 5000) == matches!(r, Out::Rejected(_)), "{:?}", r);
    let _ = w.col.close(None);
}

fn self_run(args: &[&str], crash: Option<&str>) -> std::process::ExitStatus {
    let exe = std::env::current_exe().unwrap();
    let mut c = Command::new(exe); c.args(args); if let Some(p) = crash { c.env("CRASH_AT", p); }
    c.status().unwrap()
}

fn crash_prepare(dir: &str) {
    let mut w = fresh(dir);
    let basic = w.nt("Basic"); let d1 = w.deck("D1");
    for i in 0..5 { w.add_note(&format!("c{i}"), basic, &[&format!("Q{i}"), &format!("A{i}")], d1, "D1"); }
    let _ = w.col.close(None);
}
fn crash_run(dir: &str, n_ids: usize) {
    let mut w = open(dir); w.cap = 1_000_000;
    let basic = w.nt("Basic"); let rev = w.nt("Basic (and reversed card)");
    let ids: Vec<NoteId> = w.side.prepare("select note_id from note_map order by note_id").unwrap().query_map([], |r| Ok(NoteId(r.get(0)?))).unwrap().map(|x| x.unwrap()).take(n_ids).collect();
    std::thread::sleep(std::time::Duration::from_millis(1100));
    let r = w.change_notetype(&ids, basic, rev, vec![Some(0), Some(1)], Some(vec![Some(0), None]), None);
    println!("crash_run finished without crash: {r:?}");
    let _ = w.col.close(None);
}
fn crash_check(dir: &str, point: &str) {
    let mut w = open(dir);
    let basic = w.nt("Basic"); let rev = w.nt("Basic (and reversed card)");
    let pend_before = w.pending();
    let log = w.recover();
    let ids: Vec<NoteId> = w.side.prepare("select note_id from note_map").unwrap().query_map([], |r| Ok(NoteId(r.get(0)?))).unwrap().map(|x| x.unwrap()).collect();
    let mids: Vec<i64> = ids.iter().map(|i| w.col.storage.get_note(*i).unwrap().unwrap().notetype_id.0).collect();
    let all_old = mids.iter().all(|m| *m == basic.0); let all_new = mids.iter().all(|m| *m == rev.0);
    let expect_new = point != "after_intent";
    if point.starts_with("kill") { let n_new = mids.iter().filter(|m| **m == rev.0).count(); println!("{point}: notes new={} old={} total={}", n_new, mids.len()-n_new, mids.len()); check!(&format!("{point}: all-or-nothing"), all_old || all_new, "pending after recover={} log={:?}", w.pending(), log); check!(&format!("{point}: mapping"), w.mapping_check().is_ok(), "{:?}", w.mapping_check()); return; }
    check!(&format!("crash@{point}: pending before recover={pend_before}, after={}", w.pending()), w.pending() == 0 && (if expect_new { all_new } else { all_old }), "recover log {:?}; all_old={all_old} all_new={all_new}", log);
    check!(&format!("crash@{point}: mapping consistent"), w.mapping_check().is_ok(), "{:?}", w.mapping_check());
    check!(&format!("crash@{point}: guid preserved"), ids.iter().all(|i| w.col.storage.get_note(*i).unwrap().unwrap().guid.len() == 36), "ok");
    let _ = w.col.close(None);
}

fn render_dump(dir: &str, out: &str) {
    let mut w = fresh(dir);
    let basic = w.nt("Basic"); let cloze = w.nt("Cloze"); let d1 = w.deck("D1");
    let n1 = w.add_note("r1", basic, &["서울은 <b>대한민국</b>의 수도 \\(e^{i\\pi}+1=0\\) <img src=\"paste-1.png\"> [sound:rec-1.m4a]", "H<sub>2</sub>O <span style=\"color: #ff0000\">red</span> {{c9::literal-not-cloze}}"], d1, "D1");
    let n2 = w.add_note("r2", cloze, &["{{c1::서울::수도}}는 {{c2::한국}}의 {{c1::수도}} \\[x^2\\]", "extra <i>info</i>"], d1, "D1");
    let mut s = String::new();
    for (name, nid) in [("basic", n1), ("cloze", n2)] {
        for c in w.col.storage.all_cards_of_note(nid).unwrap() {
            let r = w.col.render_existing_card(c.id(), false, false).unwrap();
            s.push_str(&format!("=== {name} card ord={} latex_svg={} is_empty={}\n--- QUESTION\n{}\n--- ANSWER\n{}\n--- CSS (len {})\n{}\n\n", c.template_idx(), r.latex_svg, r.is_empty, r.question(), r.answer(), r.css.len(), r.css));
        }
    }
    std::fs::write(out, s).unwrap();
    let _ = w.col.close(None);
}

fn main() {
    let a: Vec<String> = std::env::args().collect();
    if a.get(1).map(|s| s.as_str()) == Some("render") { render_dump(&a[2], &a[3]); return; }
    let a: Vec<String> = std::env::args().collect();
    let base = std::env::var("SPIKE_DIR").unwrap_or("/tmp/spike_a".into());
    match a.get(1).map(|s| s.as_str()) {
        Some("crash-prepare") => crash_prepare(&a[2]),
        Some("crash-run") => crash_run(&a[2], a.get(3).map(|s| s.parse().unwrap()).unwrap_or(5)),
        Some("crash-check") => crash_check(&a[2], &a[3]),
        Some("scale") => { let n: usize = a[2].parse().unwrap(); scale(&base, n) }
        Some("kill-during") => {
            // spawn crash-run on a big collection and SIGKILL it after delay ms
            let dir = &a[2]; let delay: u64 = a[3].parse().unwrap();
            let exe = std::env::current_exe().unwrap();
            let mut ch = Command::new(exe).args(["crash-run", dir, "100000"]).spawn().unwrap();
            std::thread::sleep(std::time::Duration::from_millis(delay));
            let _ = ch.kill(); let _ = ch.wait(); println!("killed child after {delay} ms");
        }
        _ => {
            scenarios(&base);
            for p in ["after_intent", "after_rslib", "before_complete"] {
                let d = format!("{base}/crash_{p}");
                self_run(&["crash-prepare", &d], None);
                let st = self_run(&["crash-run", &d], Some(p));
                println!("crash@{p}: child exit {:?}", st.code());
                self_run(&["crash-check", &d, p], None);
            }
            println!("TOTAL FAILS: {}", FAILS.load(std::sync::atomic::Ordering::SeqCst));
        }
    }
}
