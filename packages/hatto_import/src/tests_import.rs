// SPDX-FileCopyrightText: 2026 Hatto Social contributors
//
// SPDX-License-Identifier: AGPL-3.0-or-later

#![cfg(test)]

use std::fs;
use std::io::{Read, Write};
use std::path::{Path, PathBuf};

use crate::harness::{commit_import, lock_collections, test_limits, tiny_png, ColLookup, TestCol};
use crate::prepare_import;

const MOD: i64 = 1_700_000_000;

fn g(n: u32) -> String {
    format!("00000000-0000-4000-8000-{n:012x}")
}

fn fresh() -> (tempfile::TempDir, PathBuf) {
    let root = tempfile::TempDir::new().unwrap();
    let data = root.path().join("data");
    fs::create_dir_all(&data).unwrap();
    (root, data)
}

fn basic_deck(source: &TestCol, name: &str) -> (i64, i64) {
    let deck = source.add_deck(name).unwrap();
    let nt = source.notetype_id("Basic").unwrap();
    (deck, nt)
}

fn note_mod(col: &TestCol, guid: &str) -> (i64, i64, String) {
    let row = col.note_row(guid).unwrap().unwrap();
    (row.mod_secs, row.usn, row.flds)
}

fn assert_intent_fields(prepared: &crate::PreparedImport) {
    assert_eq!(
        prepared.new_guids.len() as u32,
        prepared.plan.new,
        "new_guids"
    );
    assert_eq!(
        prepared.changed.len() as u32,
        prepared.plan.changed,
        "changed"
    );
    assert_eq!(
        prepared.pre_note_count,
        prepared.plan.new + prepared.plan.changed
    );
    assert!(!prepared.deck_names.iter().any(|name| name == "Default"));
}

fn assert_no_empty_named_decks(col: &TestCol) {
    let rows = col
        .sql(
            "SELECT name FROM decks WHERE id != 1 AND id NOT IN (SELECT did FROM cards)",
            Vec::new(),
        )
        .unwrap();
    assert!(rows.as_array().unwrap().is_empty(), "empty decks: {rows}");
}

#[test]
fn t1_same_file_does_not_call_the_resident_again() {
    let _lock = lock_collections();
    let (root, data) = fresh();
    let file = root.path().join("deck.apkg");
    {
        let source = TestCol::open(&root.path().join("source")).unwrap();
        let (deck, nt) = basic_deck(&source, "Spanish");
        let note = source
            .add_note(nt, deck, &["hola", "hello"], &g(1))
            .unwrap();
        source.set_mod(note, MOD).unwrap();
        source.export(&file, true, true).unwrap();
    }
    let mut resident = TestCol::open(&root.path().join("resident")).unwrap();
    let first = commit_import(&data, &file, &mut resident).unwrap();
    assert_eq!(first.plan.new, 1);
    assert!(!first.plan.no_resident_call);
    assert_intent_fields(&first);
    assert_eq!(first.new_guids, vec![g(1)]);
    assert!(first.changed.is_empty());
    let (mod_secs, usn, _) = note_mod(&resident, &g(1));
    assert_eq!(mod_secs, MOD);
    assert_eq!(usn, -1);
    let before = resident.snapshot().unwrap();
    let calls = resident.import_count();
    let second = commit_import(&data, &file, &mut resident).unwrap();
    assert!(second.plan.no_resident_call, "{:?}", second.plan);
    assert_eq!(second.plan.same, 1);
    assert_eq!(second.plan.local_newer, 0);
    assert_intent_fields(&second);
    assert!(second.new_guids.is_empty());
    assert!(second.changed.is_empty());
    assert_eq!(second.pre_note_count, 0);
    assert_eq!(resident.import_count(), calls);
    assert_eq!(resident.snapshot().unwrap(), before);
}

#[test]
fn t2_same_content_different_bytes_is_same() {
    let _lock = lock_collections();
    let (root, data) = fresh();
    let source_dir = root.path().join("source");
    let file1 = root.path().join("a.apkg");
    let file2 = root.path().join("b.apkg");
    let note = {
        let source = TestCol::open(&source_dir).unwrap();
        let (deck, nt) = basic_deck(&source, "Spanish");
        let note = source
            .add_note(nt, deck, &["hola", "hello"], &g(1))
            .unwrap();
        source.set_mod(note, MOD).unwrap();
        source.export(&file1, true, true).unwrap();
        note
    };
    let mut resident = TestCol::open(&root.path().join("resident")).unwrap();
    commit_import(&data, &file1, &mut resident).unwrap();
    let before = resident.snapshot().unwrap();
    let calls = resident.import_count();
    {
        let source = TestCol::open(&source_dir).unwrap();
        source.set_mod(note, MOD + 50).unwrap();
        source.export(&file2, true, true).unwrap();
    }
    assert_ne!(fs::read(&file1).unwrap(), fs::read(&file2).unwrap());
    let second = commit_import(&data, &file2, &mut resident).unwrap();
    assert!(second.plan.no_resident_call, "{:?}", second.plan);
    assert_eq!(second.plan.same, 1);
    assert_eq!(resident.import_count(), calls);
    assert_eq!(resident.snapshot().unwrap(), before);
}

#[test]
fn t3_t4_mixed_plan_keeps_missing_notes_cards_and_revlog() {
    let _lock = lock_collections();
    let (root, data) = fresh();
    let source_dir = root.path().join("source");
    let file1 = root.path().join("v1.apkg");
    let file2 = root.path().join("v2.apkg");
    {
        let source = TestCol::open(&source_dir).unwrap();
        let (deck, nt) = basic_deck(&source, "Box");
        for (n, front) in [(1, "same"), (2, "changed"), (3, "local"), (4, "missing")] {
            let id = source.add_note(nt, deck, &[front, "back"], &g(n)).unwrap();
            source.set_mod(id, MOD).unwrap();
        }
        source.export(&file1, true, true).unwrap();
    }
    let mut resident = TestCol::open(&root.path().join("resident")).unwrap();
    commit_import(&data, &file1, &mut resident).unwrap();
    let same_id = resident.note_row(&g(1)).unwrap().unwrap().id;
    let card_id = resident.card_rows(same_id).unwrap()[0][0].as_i64().unwrap();
    resident.insert_revlog(4242, card_id, 3).unwrap();
    let cards_before = resident.card_rows(same_id).unwrap();
    let revlog_before = resident.revlog_for_card(card_id).unwrap();
    let missing_before = resident.note_row(&g(4)).unwrap().unwrap().flds;
    {
        let source = TestCol::open(&source_dir).unwrap();
        let changed = source.note_row(&g(2)).unwrap().unwrap().id;
        source
            .set_fields(changed, &["changed-now", "back"])
            .unwrap();
        source.set_mod(changed, MOD + 100).unwrap();
        let local = source.note_row(&g(3)).unwrap().unwrap().id;
        source.set_fields(local, &["local-file", "back"]).unwrap();
        source.set_mod(local, MOD - 1).unwrap();
        let missing = source.note_row(&g(4)).unwrap().unwrap().id;
        source.remove_note(missing).unwrap();
        let (deck, nt) = (
            source.deck_id_by_name("Box").unwrap().unwrap(),
            source.notetype_id("Basic").unwrap(),
        );
        let new_id = source
            .add_note(nt, deck, &["brand-new", "back"], &g(5))
            .unwrap();
        source.set_mod(new_id, MOD).unwrap();
        source.export(&file2, true, true).unwrap();
    }
    let second = commit_import(&data, &file2, &mut resident).unwrap();
    assert_eq!(second.plan.new, 1, "{:?}", second.plan);
    assert_eq!(second.plan.changed, 1, "{:?}", second.plan);
    assert_eq!(second.plan.same, 1, "{:?}", second.plan);
    assert_eq!(second.plan.local_newer, 1, "{:?}", second.plan);
    assert_eq!(second.plan.blocked, 0);
    assert!(!second.plan.no_resident_call);
    assert_intent_fields(&second);
    assert_eq!(second.new_guids, vec![g(5)]);
    assert_eq!(second.changed.len(), 1);
    let changed_hash = second.changed.get(&g(2)).expect("changed hash");
    assert_eq!(
        changed_hash.as_slice(),
        hatto_card_contract::note_content_hash(&["changed-now", "back"], &[] as &[&str])
    );
    assert_eq!(resident.card_rows(same_id).unwrap(), cards_before);
    assert_eq!(resident.revlog_for_card(card_id).unwrap(), revlog_before);
    assert_eq!(
        resident.note_row(&g(4)).unwrap().unwrap().flds,
        missing_before
    );
    let (mod_secs, usn, flds) = note_mod(&resident, &g(2));
    assert_eq!(mod_secs, MOD + 100);
    assert_eq!(usn, -1);
    assert!(flds.contains("changed-now"), "{flds}");
    let local = resident.note_row(&g(3)).unwrap().unwrap();
    assert!(local.flds.starts_with("local\u{1f}"), "{}", local.flds);
    assert!(!local.flds.contains("local-file"), "{}", local.flds);
    assert!(resident.note_row(&g(5)).unwrap().is_some());
}

#[test]
fn t5_local_newer_repeats_without_a_write() {
    let _lock = lock_collections();
    let (root, data) = fresh();
    let file = root.path().join("deck.apkg");
    {
        let source = TestCol::open(&root.path().join("source")).unwrap();
        let (deck, nt) = basic_deck(&source, "Box");
        let note = source.add_note(nt, deck, &["file", "back"], &g(1)).unwrap();
        source.set_mod(note, MOD).unwrap();
        source.export(&file, true, true).unwrap();
    }
    let mut resident = TestCol::open(&root.path().join("resident")).unwrap();
    commit_import(&data, &file, &mut resident).unwrap();
    let id = resident.note_row(&g(1)).unwrap().unwrap().id;
    resident.set_fields(id, &["mine", "back"]).unwrap();
    resident.set_mod(id, MOD + 20).unwrap();
    let before = resident.snapshot().unwrap();
    let calls = resident.import_count();
    let again = commit_import(&data, &file, &mut resident).unwrap();
    assert_eq!(again.plan.local_newer, 1, "{:?}", again.plan);
    assert!(again.plan.no_resident_call);
    let third = commit_import(&data, &file, &mut resident).unwrap();
    assert!(third.plan.no_resident_call);
    assert_eq!(resident.import_count(), calls);
    assert_eq!(resident.snapshot().unwrap(), before);
}

#[test]
fn t6_equal_mod_different_content_is_not_updated() {
    let _lock = lock_collections();
    let (root, data) = fresh();
    let source_dir = root.path().join("source");
    let file1 = root.path().join("v1.apkg");
    let file2 = root.path().join("v2.apkg");
    {
        let source = TestCol::open(&source_dir).unwrap();
        let (deck, nt) = basic_deck(&source, "Box");
        let note = source.add_note(nt, deck, &["aaa", "back"], &g(1)).unwrap();
        source.set_mod(note, MOD).unwrap();
        source.export(&file1, true, true).unwrap();
    }
    let mut resident = TestCol::open(&root.path().join("resident")).unwrap();
    commit_import(&data, &file1, &mut resident).unwrap();
    {
        let source = TestCol::open(&source_dir).unwrap();
        let id = source.note_row(&g(1)).unwrap().unwrap().id;
        source.set_fields(id, &["bbb", "back"]).unwrap();
        source.set_mod(id, MOD).unwrap();
        source.export(&file2, true, true).unwrap();
    }
    let before = resident.snapshot().unwrap();
    let calls = resident.import_count();
    let second = commit_import(&data, &file2, &mut resident).unwrap();
    assert_eq!(second.plan.local_newer, 1, "{:?}", second.plan);
    assert_eq!(second.plan.changed, 0);
    assert!(second.plan.no_resident_call);
    assert_eq!(resident.import_count(), calls);
    assert_eq!(resident.snapshot().unwrap(), before);
    assert!(resident
        .note_row(&g(1))
        .unwrap()
        .unwrap()
        .flds
        .starts_with("aaa"));
}

#[test]
fn t8_empty_and_duplicate_guids_round_trip() {
    let _lock = lock_collections();
    let (root, data) = fresh();
    let file = root.path().join("deck.apkg");
    {
        let source = TestCol::open(&root.path().join("source")).unwrap();
        let (deck, nt) = basic_deck(&source, "Box");
        let empty = source
            .add_note(nt, deck, &["empty", "back"], &g(1))
            .unwrap();
        source.set_guid(empty, "").unwrap();
        source.set_mod(empty, MOD).unwrap();
        let first = source.add_note(nt, deck, &["one", "back"], &g(2)).unwrap();
        let second = source.add_note(nt, deck, &["two", "back"], &g(3)).unwrap();
        source.set_guid(first, "dup-raw").unwrap();
        source.set_guid(second, "dup-raw").unwrap();
        source.set_mod(first, MOD).unwrap();
        source.set_mod(second, MOD + 1).unwrap();
        source.export(&file, true, true).unwrap();
    }
    let mut resident = TestCol::open(&root.path().join("resident")).unwrap();
    let first = commit_import(&data, &file, &mut resident).unwrap();
    assert_eq!(resident.note_count().unwrap(), 3);
    assert_eq!(first.plan.new, 3, "{:?}", first.plan);
    assert_eq!(first.plan.dup, 1, "{:?}", first.plan);
    let before = resident.snapshot().unwrap();
    let calls = resident.import_count();
    let second = commit_import(&data, &file, &mut resident).unwrap();
    assert!(second.plan.no_resident_call, "{:?}", second.plan);
    assert_eq!(resident.note_count().unwrap(), 3);
    assert_eq!(resident.import_count(), calls);
    assert_eq!(resident.snapshot().unwrap(), before);
}

#[test]
fn t9_missing_notetype_leaves_the_resident_unchanged() {
    let _lock = lock_collections();
    let (root, data) = fresh();
    let file = root.path().join("ok.apkg");
    let bad = root.path().join("bad.apkg");
    {
        let source = TestCol::open(&root.path().join("source")).unwrap();
        let (deck, nt) = basic_deck(&source, "Box");
        let note = source
            .add_note(nt, deck, &["hola", "hello"], &g(1))
            .unwrap();
        source.set_mod(note, MOD).unwrap();
        source.export(&file, true, true).unwrap();
    }
    corrupt_notetype(&file, &bad);
    let resident = TestCol::open(&root.path().join("resident")).unwrap();
    let seed = resident.add_deck("Keep").unwrap();
    let nt = resident.notetype_id("Basic").unwrap();
    resident
        .add_note(nt, seed, &["stay", "put"], &g(9))
        .unwrap();
    let before = resident.snapshot().unwrap();
    let mut lookup = ColLookup { col: &resident };
    let err = prepare_import(&data, &bad, test_limits(), &mut lookup).unwrap_err();
    let message = err.message().to_ascii_lowercase();
    assert!(err.is_not_found() && message.contains("notetype"), "{err}");
    assert_eq!(resident.import_count(), 0, "{err}");
    assert_eq!(resident.snapshot().unwrap(), before, "{err}");
    assert_no_batch_leftovers(&data);
}

#[test]
fn t11_renamed_deck_keeps_old_notes_and_puts_new_notes_in_the_original_name() {
    let _lock = lock_collections();
    let (root, data) = fresh();
    let source_dir = root.path().join("source");
    let file1 = root.path().join("v1.apkg");
    let file2 = root.path().join("v2.apkg");
    {
        let source = TestCol::open(&source_dir).unwrap();
        let (deck, nt) = basic_deck(&source, "Original");
        for (n, front) in [(1, "keep"), (2, "edit")] {
            let id = source.add_note(nt, deck, &[front, "back"], &g(n)).unwrap();
            source.set_mod(id, MOD).unwrap();
        }
        source.export(&file1, true, true).unwrap();
    }
    let mut resident = TestCol::open(&root.path().join("resident")).unwrap();
    commit_import(&data, &file1, &mut resident).unwrap();
    let deck_id = resident.deck_id_by_name("Original").unwrap().unwrap();
    resident.rename_deck(deck_id, "Renamed").unwrap();
    {
        let source = TestCol::open(&source_dir).unwrap();
        let edit = source.note_row(&g(2)).unwrap().unwrap().id;
        source.set_fields(edit, &["edit-now", "back"]).unwrap();
        source.set_mod(edit, MOD + 30).unwrap();
        let deck = source.deck_id_by_name("Original").unwrap().unwrap();
        let nt = source.notetype_id("Basic").unwrap();
        let new_id = source
            .add_note(nt, deck, &["fresh", "back"], &g(3))
            .unwrap();
        source.set_mod(new_id, MOD).unwrap();
        source.export(&file2, true, true).unwrap();
    }
    let second = commit_import(&data, &file2, &mut resident).unwrap();
    assert_eq!(second.plan.changed, 1, "{:?}", second.plan);
    assert_eq!(second.plan.new, 1, "{:?}", second.plan);
    let edited = resident.note_row(&g(2)).unwrap().unwrap();
    let edited_did = resident.card_rows(edited.id).unwrap()[0][2]
        .as_i64()
        .unwrap();
    assert_eq!(edited_did, deck_id);
    assert!(edited.flds.contains("edit-now"));
    let fresh_note = resident.note_row(&g(3)).unwrap().unwrap();
    let fresh_did = resident.card_rows(fresh_note.id).unwrap()[0][2]
        .as_i64()
        .unwrap();
    let fresh_name = resident
        .sql(
            "SELECT name FROM decks WHERE id = ?",
            vec![serde_json::json!(fresh_did)],
        )
        .unwrap();
    assert_eq!(fresh_name[0][0].as_str().unwrap(), "Original");
    assert_no_empty_named_decks(&resident);
    assert!(resident
        .deck_names()
        .unwrap()
        .iter()
        .any(|name| name == "Renamed"));
}

#[test]
fn t12_cardless_notes_are_reported_and_filtered_decks_are_removed() {
    let _lock = lock_collections();
    let (root, data) = fresh();
    let file = root.path().join("deck.apkg");
    {
        let source = TestCol::open(&root.path().join("source")).unwrap();
        let (deck, nt) = basic_deck(&source, "Words");
        let kept = source.add_note(nt, deck, &["kept", "back"], &g(1)).unwrap();
        source.set_mod(kept, MOD).unwrap();
        let bare = source.add_note(nt, deck, &["bare", "back"], &g(2)).unwrap();
        source.set_mod(bare, MOD).unwrap();
        source.delete_cards(bare).unwrap();
        source.add_filtered("Due soon", "deck:Words").unwrap();
        source.export(&file, true, true).unwrap();
    }
    let mut resident = TestCol::open(&root.path().join("resident")).unwrap();
    let prepared = commit_import(&data, &file, &mut resident).unwrap();
    assert_eq!(prepared.cardless_notes, 1, "{:?}", prepared.plan);
    assert!(resident.note_row(&g(1)).unwrap().is_some());
    assert!(resident.note_row(&g(2)).unwrap().is_none());
    let names = resident.deck_names().unwrap();
    assert!(names.iter().any(|name| name == "Words"), "{names:?}");
    assert!(!names.iter().any(|name| name == "Due soon"), "{names:?}");
}

#[test]
fn t13_reimport_keeps_the_user_preset_and_description() {
    let _lock = lock_collections();
    let (root, data) = fresh();
    let source_dir = root.path().join("source");
    let file1 = root.path().join("v1.apkg");
    let file2 = root.path().join("v2.apkg");
    {
        let source = TestCol::open(&source_dir).unwrap();
        let (deck, nt) = basic_deck(&source, "Words");
        source.set_description(deck, "file-desc").unwrap();
        source.assign_fresh_preset(deck, 15).unwrap();
        let note = source
            .add_note(nt, deck, &["hola", "hello"], &g(1))
            .unwrap();
        source.set_mod(note, MOD).unwrap();
        source.export(&file1, true, true).unwrap();
    }
    let mut resident = TestCol::open(&root.path().join("resident")).unwrap();
    let first = commit_import(&data, &file1, &mut resident).unwrap();
    assert!(first.first_import, "{:?}", first.plan);
    let deck_id = resident.deck_id_by_name("Words").unwrap().unwrap();
    resident.set_description(deck_id, "user-desc").unwrap();
    resident.set_new_per_day(deck_id, 3).unwrap();
    {
        let source = TestCol::open(&source_dir).unwrap();
        let id = source.note_row(&g(1)).unwrap().unwrap().id;
        source.set_fields(id, &["hola-2", "hello"]).unwrap();
        source.set_mod(id, MOD + 10).unwrap();
        source.export(&file2, true, true).unwrap();
    }
    let second = commit_import(&data, &file2, &mut resident).unwrap();
    assert!(!second.first_import, "{:?}", second.plan);
    assert_eq!(second.plan.changed, 1, "{:?}", second.plan);
    let deck_id = resident.deck_id_by_name("Words").unwrap().unwrap();
    assert_eq!(resident.description(deck_id).unwrap(), "user-desc");
    let config = resident.config_id(deck_id).unwrap();
    assert_eq!(resident.new_per_day(config).unwrap(), 3);
}

#[test]
fn t17_existing_card_revlog_stays_and_only_the_new_card_revlog_arrives() {
    let _lock = lock_collections();
    let (root, data) = fresh();
    let source_dir = root.path().join("source");
    let file1 = root.path().join("v1.apkg");
    let file2 = root.path().join("v2.apkg");
    {
        let source = TestCol::open(&source_dir).unwrap();
        let deck = source.add_deck("ClozeBox").unwrap();
        let nt = source.notetype_id("Cloze").unwrap();
        let note = source
            .add_note(nt, deck, &["{{c1::alpha}}", ""], &g(1))
            .unwrap();
        source.set_mod(note, MOD).unwrap();
        let card = source.card_rows(note).unwrap()[0][0].as_i64().unwrap();
        source.insert_revlog(6100, card, 3).unwrap();
        source.export(&file1, true, true).unwrap();
    }
    let mut resident = TestCol::open(&root.path().join("resident")).unwrap();
    commit_import(&data, &file1, &mut resident).unwrap();
    let resident_note = resident.note_row(&g(1)).unwrap().unwrap().id;
    let old_card = resident.card_rows(resident_note).unwrap()[0][0]
        .as_i64()
        .unwrap();
    resident.insert_revlog(6200, old_card, 4).unwrap();
    let card_before = resident.card_rows(resident_note).unwrap();
    let revlog_before = resident.revlog_for_card(old_card).unwrap();
    {
        let source = TestCol::open(&source_dir).unwrap();
        let note = source.note_row(&g(1)).unwrap().unwrap().id;
        source
            .set_fields(note, &["{{c1::alpha}} {{c2::beta}}", ""])
            .unwrap();
        source.set_mod(note, MOD + 40).unwrap();
        let cards = source.card_rows(note).unwrap();
        assert!(
            cards.as_array().unwrap().len() >= 2,
            "c2 card was not created: {cards}"
        );
        let c1 = cards[0][0].as_i64().unwrap();
        let c2 = cards[1][0].as_i64().unwrap();
        source.insert_revlog(7100, c1, 2).unwrap();
        source.insert_revlog(8100, c2, 3).unwrap();
        source.export(&file2, true, true).unwrap();
    }
    let second = commit_import(&data, &file2, &mut resident).unwrap();
    assert_eq!(second.plan.changed, 1, "{:?}", second.plan);
    assert_eq!(
        resident.card_rows(resident_note).unwrap()[0],
        card_before[0]
    );
    assert_eq!(resident.revlog_for_card(old_card).unwrap(), revlog_before);
    let revlog_text = resident.revlog_for_card(old_card).unwrap().to_string();
    assert!(!revlog_text.contains("7100"), "{revlog_text}");
    let cards_after = resident.card_rows(resident_note).unwrap();
    assert_eq!(cards_after.as_array().unwrap().len(), 2, "{cards_after}");
    let new_card = cards_after[1][0].as_i64().unwrap();
    let new_revlog = resident.revlog_for_card(new_card).unwrap().to_string();
    assert!(new_revlog.contains("8100"), "{new_revlog}");
}

#[test]
fn t20_duplicate_guids_import_update_only_the_second() {
    let _lock = lock_collections();
    let (root, data) = fresh();
    let source_dir = root.path().join("source");
    let file1 = root.path().join("v1.apkg");
    let file2 = root.path().join("v2.apkg");
    {
        let source = TestCol::open(&source_dir).unwrap();
        let (deck, nt) = basic_deck(&source, "Box");
        let low = source
            .add_note(nt, deck, &["first", "back"], &g(1))
            .unwrap();
        let high = source
            .add_note(nt, deck, &["second", "back"], &g(2))
            .unwrap();
        assert!(low < high);
        source.set_guid(low, "dup-raw").unwrap();
        source.set_guid(high, "dup-raw").unwrap();
        source.set_mod(low, MOD).unwrap();
        source.set_mod(high, MOD).unwrap();
        source.export(&file1, true, true).unwrap();
    }
    let mut resident = TestCol::open(&root.path().join("resident")).unwrap();
    let first = commit_import(&data, &file1, &mut resident).unwrap();
    assert_eq!(first.plan.dup, 1, "{:?}", first.plan);
    assert_eq!(first.plan.new, 2);
    assert_eq!(resident.note_count().unwrap(), 2);
    let before = resident.snapshot().unwrap();
    let calls = resident.import_count();
    let noop = commit_import(&data, &file1, &mut resident).unwrap();
    assert!(noop.plan.no_resident_call, "{:?}", noop.plan);
    assert_eq!(resident.import_count(), calls);
    assert_eq!(resident.snapshot().unwrap(), before);
    {
        let source = TestCol::open(&source_dir).unwrap();
        let rows = source
            .sql(
                "SELECT id FROM notes WHERE guid = ? ORDER BY id",
                vec![serde_json::json!("dup-raw")],
            )
            .unwrap();
        let high = rows[1][0].as_i64().unwrap();
        source.set_fields(high, &["second-edited", "back"]).unwrap();
        source.set_mod(high, MOD + 25).unwrap();
        source.export(&file2, true, true).unwrap();
    }
    let third = commit_import(&data, &file2, &mut resident).unwrap();
    assert_eq!(third.plan.changed, 1, "{:?}", third.plan);
    assert_eq!(third.plan.same, 1, "{:?}", third.plan);
    let texts = resident
        .sql("SELECT flds FROM notes ORDER BY id", Vec::new())
        .unwrap();
    let joined = texts.to_string();
    assert!(joined.contains("first"), "{joined}");
    assert!(joined.contains("second-edited"), "{joined}");
    assert!(!joined.contains("\"second\u{1f}"), "{joined}");
}

#[test]
fn t21_deck_name_normalization_and_first_import() {
    let _lock = lock_collections();
    let (root, data) = fresh();
    let nfd = "Cafe\u{301} ";
    let file = root.path().join("nfd.apkg");
    {
        let source = TestCol::open(&root.path().join("nfd-source")).unwrap();
        let (deck, nt) = basic_deck(&source, "Placeholder");
        let note = source.add_note(nt, deck, &["cafe", "back"], &g(1)).unwrap();
        source.set_mod(note, MOD).unwrap();
        source
            .exec(
                "UPDATE decks SET name = ? WHERE id = ?",
                vec![serde_json::json!(nfd), serde_json::json!(deck)],
            )
            .unwrap();
        source.export(&file, true, true).unwrap();
    }
    let mut resident = TestCol::open(&root.path().join("resident")).unwrap();
    let existing = resident.add_deck("Caf\u{e9}").unwrap();
    resident.assign_fresh_preset(existing, 9).unwrap();
    let nt = resident.notetype_id("Basic").unwrap();
    resident
        .add_note(nt, existing, &["already", "here"], &g(8))
        .unwrap();
    let prepared = commit_import(&data, &file, &mut resident).unwrap();
    assert!(!prepared.first_import, "{:?}", prepared.plan);
    let names = resident.deck_names().unwrap();
    assert!(names.iter().any(|name| name == "Caf\u{e9}"), "{names:?}");
    assert!(!names.iter().any(|name| name.contains('+')), "{names:?}");
    assert_eq!(
        resident
            .new_per_day(resident.config_id(existing).unwrap())
            .unwrap(),
        9
    );

    let file_d = root.path().join("d1.apkg");
    {
        let source = TestCol::open(&root.path().join("d-source")).unwrap();
        let (deck, nt) = basic_deck(&source, "D1");
        source.assign_fresh_preset(deck, 15).unwrap();
        let note = source.add_note(nt, deck, &["dee", "back"], &g(2)).unwrap();
        source.set_mod(note, MOD + 5).unwrap();
        source.export(&file_d, true, true).unwrap();
    }
    let d1 = resident.add_deck("d1").unwrap();
    resident.assign_fresh_preset(d1, 4).unwrap();
    let case_fold = commit_import(&data, &file_d, &mut resident).unwrap();
    assert!(!case_fold.first_import, "{:?}", case_fold.plan);
    assert_eq!(
        resident
            .new_per_day(resident.config_id(d1).unwrap())
            .unwrap(),
        4
    );
    assert!(resident
        .deck_names()
        .unwrap()
        .iter()
        .any(|name| name == "d1"));

    let file_new = root.path().join("again.apkg");
    {
        let source = TestCol::open(&root.path().join("del-source")).unwrap();
        let (deck, nt) = basic_deck(&source, "Gone");
        let note = source
            .add_note(nt, deck, &["back-again", "back"], &g(3))
            .unwrap();
        source.set_mod(note, MOD).unwrap();
        source.export(&file_new, true, true).unwrap();
    }
    let first_gone = commit_import(&data, &file_new, &mut resident).unwrap();
    assert!(first_gone.first_import);
    let gone_id = resident.deck_id_by_name("Gone").unwrap().unwrap();
    resident.remove_deck(gone_id).unwrap();
    let again = commit_import(&data, &file_new, &mut resident).unwrap();
    assert!(again.first_import, "{:?}", again.plan);
    assert_eq!(again.plan.new, 1, "{:?}", again.plan);
    let new_id = resident.deck_id_by_name("Gone").unwrap().unwrap();
    assert_ne!(new_id, gone_id);
}

#[test]
fn first_import_stays_true_when_only_an_empty_deck_name_matches() {
    let _lock = lock_collections();
    let (root, data) = fresh();
    let file = root.path().join("deck.apkg");
    {
        let source = TestCol::open(&root.path().join("source")).unwrap();
        let shell = source.add_deck("Shell").unwrap();
        let fresh_deck = source.add_deck("Fresh").unwrap();
        source.set_description(fresh_deck, "from-file").unwrap();
        source.set_new_per_day(fresh_deck, 7).unwrap();
        let nt = source.notetype_id("Basic").unwrap();
        let bare = source
            .add_note(nt, shell, &["bare", "back"], &g(1))
            .unwrap();
        source.set_mod(bare, MOD).unwrap();
        source.delete_cards(bare).unwrap();
        let note = source
            .add_note(nt, fresh_deck, &["hola", "hello"], &g(2))
            .unwrap();
        source.set_mod(note, MOD).unwrap();
        source.export(&file, true, true).unwrap();
    }
    let mut resident = TestCol::open(&root.path().join("resident")).unwrap();
    resident.add_deck("Shell").unwrap();
    let prepared = commit_import(&data, &file, &mut resident).unwrap();
    // Shell is removed with the cardless note before the judgment, so the
    // only exported deck is Fresh. That name is absent, so this is a first
    // import and the package preset is restored.
    assert!(prepared.first_import, "{:?}", prepared.plan);
    assert_eq!(prepared.cardless_notes, 1);
    assert_eq!(prepared.plan.new, 1, "{:?}", prepared.plan);
    assert_eq!(prepared.plan.changed, 0, "{:?}", prepared.plan);
    assert_eq!(resident.new_per_day(1).unwrap(), 20);
    let fresh_id = resident.deck_id_by_name("Fresh").unwrap().unwrap();
    let config = resident.config_id(fresh_id).unwrap();
    assert_ne!(config, 1);
    assert_eq!(resident.new_per_day(config).unwrap(), 7);
    assert_eq!(resident.description(fresh_id).unwrap(), "from-file");
    assert!(resident.deck_id_by_name("Shell").unwrap().is_some());
    assert!(resident.note_row(&g(1)).unwrap().is_none());
    assert!(resident.note_row(&g(2)).unwrap().is_some());
}

#[test]
fn t22_media_suffix_is_same_on_the_second_import() {
    let _lock = lock_collections();
    let (root, data) = fresh();
    let file = root.path().join("media.apkg");
    {
        let source = TestCol::open(&root.path().join("source")).unwrap();
        let (deck, nt) = basic_deck(&source, "Pics");
        source.add_media("m2.png", &tiny_png(2)).unwrap();
        let note = source
            .add_note(nt, deck, &["see <img src=\"m2.png\">", ""], &g(1))
            .unwrap();
        source.set_mod(note, MOD).unwrap();
        source.export(&file, true, true).unwrap();
    }
    let mut resident = TestCol::open(&root.path().join("resident")).unwrap();
    resident.add_media("m2.png", &tiny_png(1)).unwrap();
    commit_import(&data, &file, &mut resident).unwrap();
    let flds = resident.note_row(&g(1)).unwrap().unwrap().flds;
    assert!(flds.contains("m2-"), "{flds}");
    assert!(flds.contains(".png"), "{flds}");
    let before = resident.snapshot().unwrap();
    let calls = resident.import_count();
    let second = commit_import(&data, &file, &mut resident).unwrap();
    assert!(second.plan.no_resident_call, "{:?}", second.plan);
    assert_eq!(second.plan.same, 1, "{:?}", second.plan);
    assert_eq!(second.plan.local_newer, 0);
    assert_eq!(resident.import_count(), calls);
    assert_eq!(resident.snapshot().unwrap(), before);
}

#[test]
fn sp3_removed_same_note_does_not_export_its_media_or_notetype() {
    let _lock = lock_collections();
    let (root, data) = fresh();
    let source_dir = root.path().join("source");
    let file1 = root.path().join("v1.apkg");
    let file2 = root.path().join("v2.apkg");
    {
        let source = TestCol::open(&source_dir).unwrap();
        let deck = source.add_deck("Box").unwrap();
        let basic = source.notetype_id("Basic").unwrap();
        let only = source.add_custom_notetype("OnlySame").unwrap();
        source.add_media("keep.png", &tiny_png(3)).unwrap();
        source.add_media("only-same.png", &tiny_png(4)).unwrap();
        let changed = source
            .add_note(basic, deck, &["keep <img src=\"keep.png\">", ""], &g(1))
            .unwrap();
        let same = source
            .add_note(only, deck, &["same <img src=\"only-same.png\">", ""], &g(2))
            .unwrap();
        source.set_mod(changed, MOD).unwrap();
        source.set_mod(same, MOD).unwrap();
        source.export(&file1, true, true).unwrap();
    }
    let mut resident = TestCol::open(&root.path().join("resident")).unwrap();
    commit_import(&data, &file1, &mut resident).unwrap();
    {
        let source = TestCol::open(&source_dir).unwrap();
        let id = source.note_row(&g(1)).unwrap().unwrap().id;
        source
            .set_fields(id, &["keep2 <img src=\"keep.png\">", ""])
            .unwrap();
        source.set_mod(id, MOD + 15).unwrap();
        source.export(&file2, true, true).unwrap();
    }
    let second = commit_import(&data, &file2, &mut resident).unwrap();
    assert!(!second.plan.no_resident_call, "{:?}", second.plan);
    let checker = TestCol::open(&root.path().join("checker")).unwrap();
    checker.import_for_read(&second.staged_path).unwrap();
    let names = checker.notetype_names().unwrap();
    assert!(
        !names.iter().any(|name| name.contains("OnlySame")),
        "{names:?}"
    );
    let media = checker.snapshot().unwrap().media;
    assert!(media.keys().any(|name| name == "keep.png"), "{media:?}");
    assert!(
        !media.keys().any(|name| name.contains("only-same")),
        "{media:?}"
    );
}

#[test]
fn sp3_media_only_change_is_not_applied() {
    let _lock = lock_collections();
    let (root, data) = fresh();
    let source_dir = root.path().join("source");
    let file1 = root.path().join("v1.apkg");
    let file2 = root.path().join("v2.apkg");
    {
        let source = TestCol::open(&source_dir).unwrap();
        let (deck, nt) = basic_deck(&source, "Pics");
        source.add_media("a.png", &tiny_png(5)).unwrap();
        let note = source
            .add_note(nt, deck, &["see <img src=\"a.png\">", ""], &g(1))
            .unwrap();
        source.set_mod(note, MOD).unwrap();
        source.export(&file1, true, true).unwrap();
    }
    let mut resident = TestCol::open(&root.path().join("resident")).unwrap();
    commit_import(&data, &file1, &mut resident).unwrap();
    let before = resident.snapshot().unwrap();
    {
        let source = TestCol::open(&source_dir).unwrap();
        fs::write(
            source_dir.join("collection.media").join("a.png"),
            tiny_png(6),
        )
        .unwrap();
        source.export(&file2, true, true).unwrap();
    }
    let calls = resident.import_count();
    let second = commit_import(&data, &file2, &mut resident).unwrap();
    assert!(second.plan.no_resident_call, "{:?}", second.plan);
    assert_eq!(second.plan.same, 1);
    assert_eq!(resident.import_count(), calls);
    assert_eq!(resident.snapshot().unwrap().media, before.media);
}

#[test]
fn exp11_first_import_restores_the_package_default_preset() {
    let _lock = lock_collections();
    let (root, data) = fresh();
    let file = root.path().join("deck.apkg");
    {
        let source = TestCol::open(&root.path().join("source")).unwrap();
        let (deck, nt) = basic_deck(&source, "Words");
        source.set_description(deck, "hello").unwrap();
        source.set_new_per_day(deck, 7).unwrap();
        let note = source
            .add_note(nt, deck, &["hola", "hello"], &g(1))
            .unwrap();
        source.set_mod(note, MOD).unwrap();
        source.export(&file, true, true).unwrap();
    }
    let mut resident = TestCol::open(&root.path().join("resident")).unwrap();
    let prepared = commit_import(&data, &file, &mut resident).unwrap();
    assert!(prepared.first_import, "{:?}", prepared.plan);
    assert_eq!(resident.new_per_day(1).unwrap(), 20);
    let deck_id = resident.deck_id_by_name("Words").unwrap().unwrap();
    let config = resident.config_id(deck_id).unwrap();
    assert_ne!(config, 1);
    assert_eq!(resident.new_per_day(config).unwrap(), 7);
    assert_eq!(resident.description(deck_id).unwrap(), "hello");
}

#[test]
fn sp5_fullwidth_and_turkish_i_do_not_match() {
    let _lock = lock_collections();
    let (root, data) = fresh();
    let file = root.path().join("names.apkg");
    {
        let source = TestCol::open(&root.path().join("source")).unwrap();
        let wide = source
            .add_deck("\u{ff33}\u{ff50}\u{ff41}\u{ff4e}\u{ff49}\u{ff53}\u{ff48}")
            .unwrap();
        let istanbul = source.add_deck("\u{130}stanbul").unwrap();
        let nt = source.notetype_id("Basic").unwrap();
        let a = source.add_note(nt, wide, &["wide", "back"], &g(1)).unwrap();
        let b = source
            .add_note(nt, istanbul, &["city", "back"], &g(2))
            .unwrap();
        source.set_mod(a, MOD).unwrap();
        source.set_mod(b, MOD).unwrap();
        source.export(&file, true, true).unwrap();
    }
    let mut resident = TestCol::open(&root.path().join("resident")).unwrap();
    let spanish = resident.add_deck("Spanish").unwrap();
    resident.assign_fresh_preset(spanish, 6).unwrap();
    let city = resident.add_deck("istanbul").unwrap();
    resident.assign_fresh_preset(city, 8).unwrap();
    let prepared = commit_import(&data, &file, &mut resident).unwrap();
    assert!(prepared.first_import, "{:?}", prepared.plan);
    assert_eq!(
        resident
            .new_per_day(resident.config_id(spanish).unwrap())
            .unwrap(),
        6
    );
    assert_eq!(
        resident
            .new_per_day(resident.config_id(city).unwrap())
            .unwrap(),
        8
    );
    let names = resident.deck_names().unwrap();
    assert!(names.iter().any(|name| name == "Spanish"), "{names:?}");
    assert!(names.iter().any(|name| name == "istanbul"), "{names:?}");
    assert!(names.len() >= 4, "{names:?}");
}

#[test]
fn legacy_package_without_protobuf_default_keeps_config_id_1() {
    let _lock = lock_collections();
    let (root, data) = fresh();
    let file = root.path().join("legacy.apkg");
    {
        let source = TestCol::open(&root.path().join("source")).unwrap();
        let (deck, nt) = basic_deck(&source, "Words");
        source.set_description(deck, "hello").unwrap();
        source.set_new_per_day(deck, 7).unwrap();
        let note = source
            .add_note(nt, deck, &["hola", "hello"], &g(1))
            .unwrap();
        source.set_mod(note, MOD).unwrap();
        source.export_legacy(&file).unwrap();
    }
    let mut resident = TestCol::open(&root.path().join("resident")).unwrap();
    let prepared = commit_import(&data, &file, &mut resident).unwrap();
    assert!(prepared.first_import, "{:?}", prepared.plan);
    let deck_id = resident.deck_id_by_name("Words").unwrap().unwrap();
    assert_eq!(resident.config_id(deck_id).unwrap(), 1);
    assert_eq!(resident.description(deck_id).unwrap(), "hello");
    assert!(resident.note_row(&g(1)).unwrap().is_some());
}

fn assert_no_batch_leftovers(data: &Path) {
    for folder in ["raw", "e", "staged"] {
        let dir = data.join("import").join(folder);
        if !dir.exists() {
            continue;
        }
        let entries: Vec<_> = fs::read_dir(&dir)
            .unwrap()
            .map(|entry| entry.unwrap().file_name().to_string_lossy().into_owned())
            .collect();
        assert!(entries.is_empty(), "import/{folder} leftover {entries:?}");
    }
}

fn corrupt_notetype(src: &Path, dest: &Path) {
    let file = fs::File::open(src).unwrap();
    let mut archive = zip::ZipArchive::new(file).unwrap();
    let out = fs::File::create(dest).unwrap();
    let mut writer = zip::ZipWriter::new(out);
    for index in 0..archive.len() {
        let mut entry = archive.by_index(index).unwrap();
        let name = entry.name().to_string();
        let mut data = Vec::new();
        entry.read_to_end(&mut data).unwrap();
        if name == "collection.anki21b" {
            let sqlite = zstd::decode_all(&data[..]).unwrap();
            let scratch = dest.with_extension("sqlite");
            fs::write(&scratch, &sqlite).unwrap();
            {
                let conn = rusqlite::Connection::open(&scratch).unwrap();
                conn.execute(
                    "UPDATE notes SET mid = 999999999 WHERE id = (SELECT max(id) FROM notes)",
                    [],
                )
                .unwrap();
            }
            let sqlite = fs::read(&scratch).unwrap();
            data = zstd::encode_all(&sqlite[..], 0).unwrap();
            fs::remove_file(&scratch).unwrap();
        }
        let options = zip::write::SimpleFileOptions::default()
            .compression_method(zip::CompressionMethod::Deflated);
        writer.start_file(name, options).unwrap();
        writer.write_all(&data).unwrap();
    }
    writer.finish().unwrap();
}
