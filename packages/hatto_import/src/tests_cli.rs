// SPDX-FileCopyrightText: 2026 Hatto Social contributors
//
// SPDX-License-Identifier: AGPL-3.0-or-later

//! Imports `.apkg` files built by the `hatto-card` binary.
//!
//! `HATTO_CARD_BIN` is the path of that binary. The crate does not depend
//! on `hatto_card`: that edge would cycle through `rslib_bridge`. When the
//! variable is unset these tests print a reason and return. When `CI` is
//! set, an unset path is a failure.
//!
//! Note `mod` is unix seconds. A second export in that same second keeps
//! `mod`, and a content change with equal `mod` is `LOCAL_NEWER`. The
//! changed-package exports wait until more than one second has passed.

#![cfg(test)]

use std::collections::{BTreeMap, BTreeSet};
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::{Duration, SystemTime};

use sha2::{Digest, Sha256};

use crate::finish_import;
use crate::harness::{commit_import, lock_collections, test_limits, tiny_png, ColLookup, TestCol};
use crate::stage_import;
use crate::Plan;
use crate::PreparedImport;

const TREE: &str = "Tree";
const TREE_DECKS: &[&str] = &["Tree", "Tree::Sub", "Tree::Sub::Leaf", "Tree::Other"];

struct SeedNote {
    k: u32,
    fields: &'static [&'static str],
    tag: &'static str,
    deck_name: Option<&'static str>,
    notetype: Option<&'static str>,
}

struct Built {
    dir: tempfile::TempDir,
    deck: PathBuf,
    op_id: String,
    notetype: String,
    ks: Vec<u32>,
}

fn cli_bin() -> Option<PathBuf> {
    match std::env::var("HATTO_CARD_BIN") {
        Ok(value) if !value.is_empty() => Some(PathBuf::from(value)),
        _ => {
            if std::env::var_os("CI").is_some() {
                panic!("HATTO_CARD_BIN is unset and CI is set");
            }
            eprintln!(
                "skipping hatto-card import test: HATTO_CARD_BIN is unset (set it to the hatto-card binary)"
            );
            None
        }
    }
}

fn cli_ok(bin: &Path, args: impl IntoIterator<Item = impl AsRef<str>>) -> serde_json::Value {
    let args: Vec<String> = args
        .into_iter()
        .map(|arg| arg.as_ref().to_string())
        .collect();
    let output = Command::new(bin)
        .args(&args)
        .output()
        .unwrap_or_else(|err| panic!("spawn {}: {err}", bin.display()));
    let code = output.status.code().unwrap_or(1);
    let stdout = String::from_utf8(output.stdout).expect("hatto-card stdout is utf-8");
    let stderr = String::from_utf8(output.stderr).expect("hatto-card stderr is utf-8");
    assert_eq!(
        code, 0,
        "hatto-card {args:?} exited {code}\n{stdout}\n{stderr}"
    );
    let value: serde_json::Value = serde_json::from_str(&stdout)
        .unwrap_or_else(|err| panic!("hatto-card json: {err}\n{stdout}"));
    assert_eq!(value["ok"].as_bool(), Some(true), "{value}");
    value
}

fn path_arg(path: &Path) -> String {
    path.to_str().expect("utf-8 path").to_string()
}

fn guid_of(op_id: &str, k: u32) -> String {
    let op = hatto_card_contract::parse_uuid(op_id).unwrap();
    hatto_card_contract::NoteGuid::from_uuid(hatto_card_contract::local_note_guid(op, k))
        .into_string()
}

fn guid_set(op_id: &str, ks: &[u32]) -> BTreeSet<String> {
    ks.iter().copied().map(|k| guid_of(op_id, k)).collect()
}

fn note_value(op_id: &str, note: &SeedNote) -> serde_json::Value {
    let mut value = serde_json::json!({
        "op_id": op_id,
        "k": note.k,
        "fields": note.fields,
        "tags": [note.tag],
    });
    if let Some(name) = note.deck_name {
        value["deck_name"] = serde_json::json!(name);
    }
    if let Some(name) = note.notetype {
        value["notetype"] = serde_json::json!(name);
    }
    value
}

fn write_jsonl(path: &Path, notes: &[serde_json::Value]) {
    let mut text = String::new();
    for note in notes {
        text.push_str(&serde_json::to_string(note).unwrap());
        text.push('\n');
    }
    fs::write(path, text).unwrap();
}

fn build_deck(bin: &Path, deck_name: &str, notetype: &str, notes: &[SeedNote]) -> Built {
    assert!(!notes.is_empty());
    let mut ks: Vec<u32> = notes.iter().map(|note| note.k).collect();
    let count = ks.len();
    ks.sort_unstable();
    ks.dedup();
    assert_eq!(ks.len(), count, "duplicate k");
    assert!(!ks.contains(&7), "k 7 is reserved for the added note");

    let dir = tempfile::tempdir().unwrap();
    let deck = dir.path().join("deck.json");
    let deck_arg = path_arg(&deck);
    let created = cli_ok(
        bin,
        &[
            "--json",
            "new",
            "--empty",
            "--output",
            deck_arg.as_str(),
            "--deck-name",
            deck_name,
            "--notetype",
            notetype,
        ],
    );
    let op_id = created["deck"]["op_id"]
        .as_str()
        .expect("new deck op_id")
        .to_string();
    let jsonl = dir.path().join("notes.jsonl");
    let rows: Vec<_> = notes.iter().map(|note| note_value(&op_id, note)).collect();
    write_jsonl(&jsonl, &rows);
    let jsonl_arg = path_arg(&jsonl);
    cli_ok(
        bin,
        &[
            "--json",
            "add-notes",
            "--deck",
            deck_arg.as_str(),
            "--input",
            jsonl_arg.as_str(),
            "--op-id",
            op_id.as_str(),
        ],
    );
    cli_ok(bin, ["--json", "validate", "--deck", deck_arg.as_str()]);
    Built {
        dir,
        deck,
        op_id,
        notetype: notetype.to_string(),
        ks,
    }
}

fn export_apkg(bin: &Path, deck: &Path, out: &Path) -> serde_json::Value {
    let deck_arg = path_arg(deck);
    let out_arg = path_arg(out);
    cli_ok(
        bin,
        &[
            "--json",
            "export",
            "--deck",
            deck_arg.as_str(),
            "--output",
            out_arg.as_str(),
        ],
    )
}

fn assert_export_guids(exported: &serde_json::Value, op_id: &str, ks: &[u32]) {
    let got: BTreeSet<String> = exported["notes"]
        .as_array()
        .unwrap()
        .iter()
        .map(|note| note["guid"].as_str().unwrap().to_string())
        .collect();
    assert_eq!(got, guid_set(op_id, ks), "{exported}");
}

fn add_note_k7(bin: &Path, built: &Built, fields: &[&str]) {
    let mut args = vec![
        "--json".to_string(),
        "add-note".to_string(),
        "--deck".to_string(),
        path_arg(&built.deck),
        "--notetype".to_string(),
        built.notetype.clone(),
        "--op-id".to_string(),
        built.op_id.clone(),
        "--k".to_string(),
        "7".to_string(),
        "--tag".to_string(),
        "added".to_string(),
    ];
    for field in fields {
        args.push("--field".to_string());
        args.push((*field).to_string());
    }
    let added = cli_ok(bin, args);
    assert_eq!(added["k"].as_u64(), Some(7), "{added}");
    assert_eq!(
        added["op_id"].as_str(),
        Some(built.op_id.as_str()),
        "{added}"
    );
    let expect = guid_of(&built.op_id, 7);
    let notes = added["notes"].as_array().unwrap();
    assert_eq!(
        notes.last().unwrap()["guid"].as_str(),
        Some(expect.as_str()),
        "{added}"
    );
}

/// `mod` is recorded during export, before this returns. Sleep only the
/// remainder so the next export cannot land in that same unix second.
fn wait_until_mod_can_differ(exported_at: SystemTime) {
    let gap = Duration::from_millis(1_100);
    let elapsed = exported_at.elapsed().unwrap_or(Duration::ZERO);
    if let Some(rest) = gap.checked_sub(elapsed) {
        std::thread::sleep(rest + Duration::from_millis(50));
    }
}

fn read_deck(deck: &Path) -> serde_json::Value {
    serde_json::from_str(&fs::read_to_string(deck).unwrap()).unwrap()
}

fn mutate_field_and_tag(deck: &Path, field_k: u32, field: &str, tag_k: u32, tag: &str) {
    assert_ne!(field_k, tag_k);
    let mut value = read_deck(deck);
    let notes = value["notes"].as_array_mut().unwrap();
    let mut saw_field = false;
    let mut saw_tag = false;
    for note in notes {
        let k = note["k"].as_u64().unwrap() as u32;
        if k == field_k {
            let old = note["fields"][0].as_str().unwrap();
            assert_ne!(old, field);
            note["fields"][0] = serde_json::json!(field);
            saw_field = true;
        }
        if k == tag_k {
            let old = note["tags"][0].as_str().unwrap();
            assert_ne!(old, tag);
            note["tags"][0] = serde_json::json!(tag);
            saw_tag = true;
        }
    }
    assert!(saw_field && saw_tag);
    fs::write(deck, serde_json::to_string_pretty(&value).unwrap() + "\n").unwrap();
}

fn file_hash(deck: &Path, k: u32) -> Vec<u8> {
    let value = read_deck(deck);
    let note = value["notes"]
        .as_array()
        .unwrap()
        .iter()
        .find(|note| note["k"].as_u64() == Some(u64::from(k)))
        .unwrap_or_else(|| panic!("deck has no k {k}"));
    let fields: Vec<&str> = note["fields"]
        .as_array()
        .unwrap()
        .iter()
        .map(|field| field.as_str().unwrap())
        .collect();
    let tags: Vec<&str> = note["tags"]
        .as_array()
        .unwrap()
        .iter()
        .map(|tag| tag.as_str().unwrap())
        .collect();
    hatto_card_contract::note_content_hash(&fields, &tags).to_vec()
}

fn assert_plan(plan: &Plan, new: u32, same: u32, changed: u32, local_newer: u32, blocked: u32) {
    assert_eq!(plan.dup, 0, "{plan:?}");
    assert_eq!(
        (
            plan.new,
            plan.same,
            plan.changed,
            plan.local_newer,
            plan.blocked
        ),
        (new, same, changed, local_newer, blocked),
        "{plan:?}"
    );
    assert_eq!(plan.no_resident_call, new == 0 && changed == 0, "{plan:?}");
}

fn assert_deck_set(names: &[String], expect: &[&str]) {
    let found: BTreeSet<&str> = names.iter().map(String::as_str).collect();
    let expect: BTreeSet<&str> = expect.iter().copied().collect();
    assert_eq!(found, expect, "{names:?}");
    assert!(!names.iter().any(|name| name == "Default"));
}

fn sorted_ids(ids: &[String]) -> Vec<String> {
    let mut ids = ids.to_vec();
    ids.sort();
    ids
}

fn open_resident(dir: &Path) -> (PathBuf, TestCol) {
    let data = dir.join("data");
    fs::create_dir_all(&data).unwrap();
    let resident = TestCol::open(&dir.join("resident")).unwrap();
    (data, resident)
}

fn assert_no_plus_notetype(col: &TestCol) {
    let names = col.notetype_names().unwrap();
    assert!(names.iter().all(|name| !name.contains('+')), "{names:?}");
}

fn sql_count(col: &TestCol, table: &str) -> i64 {
    let rows = col
        .sql(&format!("SELECT count(*) FROM {table}"), Vec::new())
        .unwrap();
    rows[0][0].as_i64().unwrap()
}

fn sha256_hex(bytes: &[u8]) -> String {
    Sha256::digest(bytes)
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect()
}

fn found_deck_names(col: &TestCol, names: &[String]) -> Vec<String> {
    names
        .iter()
        .filter(|name| col.deck_id_by_name(name).unwrap().is_some())
        .cloned()
        .collect()
}

fn card_deck(col: &TestCol, guid: &str) -> String {
    let note = col.note_row(guid).unwrap().expect(guid);
    let cards = col.card_rows(note.id).unwrap();
    let cards = cards.as_array().unwrap();
    assert!(!cards.is_empty(), "{guid} has no cards");
    let mut names = BTreeSet::new();
    for card in cards {
        let did = card[2].as_i64().unwrap();
        let row = col
            .sql(
                "SELECT name FROM decks WHERE id = ?",
                vec![serde_json::json!(did)],
            )
            .unwrap();
        names.insert(row[0][0].as_str().unwrap().replace('\u{1f}', "::"));
    }
    assert_eq!(names.len(), 1, "{guid} cards span {names:?}");
    names.into_iter().next().unwrap()
}

fn basic_notes() -> Vec<SeedNote> {
    vec![
        SeedNote {
            k: 0,
            fields: &["front-a", "back"],
            tag: "keep",
            deck_name: None,
            notetype: None,
        },
        SeedNote {
            k: 1,
            fields: &["front-b", "back"],
            tag: "alpha",
            deck_name: None,
            notetype: None,
        },
        SeedNote {
            k: 2,
            fields: &["front-c", "back"],
            tag: "still",
            deck_name: None,
            notetype: None,
        },
    ]
}

fn cloze_notes() -> Vec<SeedNote> {
    vec![
        SeedNote {
            k: 0,
            fields: &["{{c1::alpha}}", "extra"],
            tag: "keep",
            deck_name: None,
            notetype: None,
        },
        SeedNote {
            k: 1,
            fields: &["{{c1::beta}}", "extra"],
            tag: "alpha",
            deck_name: None,
            notetype: None,
        },
        SeedNote {
            k: 2,
            fields: &["{{c1::gamma}}", "extra"],
            tag: "still",
            deck_name: None,
            notetype: None,
        },
    ]
}

fn media_notes() -> Vec<SeedNote> {
    vec![
        SeedNote {
            k: 0,
            fields: &["see <img src=\"dot.png\">", "back"],
            tag: "pic",
            deck_name: None,
            notetype: None,
        },
        SeedNote {
            k: 1,
            fields: &["plain", "back"],
            tag: "alpha",
            deck_name: None,
            notetype: None,
        },
        SeedNote {
            k: 2,
            fields: &["steady", "back"],
            tag: "still",
            deck_name: None,
            notetype: None,
        },
    ]
}

fn subdeck_notes() -> Vec<SeedNote> {
    vec![
        SeedNote {
            k: 0,
            fields: &["root front", "root back"],
            tag: "root",
            deck_name: Some("Tree"),
            notetype: None,
        },
        SeedNote {
            k: 1,
            fields: &["sub front", "sub back"],
            tag: "sub",
            deck_name: Some("Tree::Sub"),
            notetype: None,
        },
        SeedNote {
            k: 2,
            fields: &["leaf front", "leaf back"],
            tag: "leaf",
            deck_name: Some("Tree::Sub::Leaf"),
            notetype: None,
        },
        SeedNote {
            k: 3,
            fields: &["other front", "other back"],
            tag: "other",
            deck_name: Some("Tree::Other"),
            notetype: None,
        },
        SeedNote {
            k: 4,
            fields: &["{{c1::leaf cloze}}", "extra"],
            tag: "cloze",
            deck_name: Some("Tree::Sub::Leaf"),
            notetype: Some("Cloze"),
        },
    ]
}

fn mixed_notes() -> Vec<SeedNote> {
    vec![
        SeedNote {
            k: 0,
            fields: &["front", "back"],
            tag: "basic",
            deck_name: None,
            notetype: None,
        },
        SeedNote {
            k: 1,
            fields: &["{{c1::hole}}", "extra"],
            tag: "cloze",
            deck_name: None,
            notetype: Some("Cloze"),
        },
        SeedNote {
            k: 2,
            fields: &["front", "back"],
            tag: "rev",
            deck_name: None,
            notetype: Some("Basic (and reversed card)"),
        },
        SeedNote {
            k: 3,
            fields: &["front", "back", "y"],
            tag: "opt",
            deck_name: None,
            notetype: Some("Basic (optional reversed card)"),
        },
        SeedNote {
            k: 4,
            fields: &["front", "back"],
            tag: "type",
            deck_name: None,
            notetype: Some("Basic (type in the answer)"),
        },
    ]
}

fn classify_package(
    bin: &Path,
    built: &Built,
    decks: &[&str],
    field_k: u32,
    new_field: &str,
    tag_k: u32,
    new_tag: &str,
    new_fields: &[&str],
) {
    let n = u32::try_from(built.ks.len()).unwrap();
    let v1 = built.dir.path().join("v1.apkg");
    let again = built.dir.path().join("again.apkg");
    let v2 = built.dir.path().join("v2.apkg");
    let exported = export_apkg(bin, &built.deck, &v1);
    assert_export_guids(&exported, &built.op_id, &built.ks);
    let exported_at = SystemTime::now();
    let reexported = export_apkg(bin, &built.deck, &again);
    assert_export_guids(&reexported, &built.op_id, &built.ks);

    mutate_field_and_tag(&built.deck, field_k, new_field, tag_k, new_tag);
    add_note_k7(bin, built, new_fields);
    wait_until_mod_can_differ(exported_at);
    let mut changed_ks = built.ks.clone();
    changed_ks.push(7);
    let revised = export_apkg(bin, &built.deck, &v2);
    assert_export_guids(&revised, &built.op_id, &changed_ks);

    let (data, mut resident) = open_resident(built.dir.path());
    let first = commit_import(&data, &v1, &mut resident).unwrap();
    assert!(first.first_import, "{:?}", first.plan);
    assert_eq!(first.cardless_notes, 0);
    assert_plan(&first.plan, n, 0, 0, 0, 0);
    assert!(!first.plan.no_resident_call);
    let expect_ids: Vec<String> = guid_set(&built.op_id, &built.ks).into_iter().collect();
    assert_eq!(sorted_ids(&first.new_guids), sorted_ids(&expect_ids));
    assert!(first.changed.is_empty());
    assert_deck_set(&first.deck_names, decks);
    assert_no_plus_notetype(&resident);
    for guid in guid_set(&built.op_id, &built.ks) {
        assert!(
            resident.note_row(&guid).unwrap().is_some(),
            "missing {guid}"
        );
    }

    let snap = resident.snapshot().unwrap();
    let calls = resident.import_count();
    let identical = commit_import(&data, &v1, &mut resident).unwrap();
    assert_plan(&identical.plan, 0, n, 0, 0, 0);
    assert!(identical.new_guids.is_empty());
    assert!(identical.changed.is_empty());
    assert_eq!(resident.import_count(), calls);
    assert_eq!(resident.snapshot().unwrap(), snap);

    let reexport = commit_import(&data, &again, &mut resident).unwrap();
    assert_plan(&reexport.plan, 0, n, 0, 0, 0);
    assert!(reexport.plan.no_resident_call, "{:?}", reexport.plan);
    assert_eq!(resident.import_count(), calls);
    assert_eq!(resident.snapshot().unwrap(), snap);

    let field_guid = guid_of(&built.op_id, field_k);
    let tag_guid = guid_of(&built.op_id, tag_k);
    let field_before = resident.note_row(&field_guid).unwrap().unwrap();
    let tag_before = resident.note_row(&tag_guid).unwrap().unwrap();
    let mut unchanged = Vec::new();
    for k in &built.ks {
        if *k == field_k || *k == tag_k {
            continue;
        }
        let guid = guid_of(&built.op_id, *k);
        let row = resident.note_row(&guid).unwrap().unwrap();
        unchanged.push((guid, row.flds, row.tags));
    }

    let modified = commit_import(&data, &v2, &mut resident).unwrap();
    assert_plan(&modified.plan, 1, n - 2, 2, 0, 0);
    assert!(
        modified.plan.local_newer == 0,
        "equal mod classifies a content change as LOCAL_NEWER: {modified:?}"
    );
    assert!(!modified.first_import, "{:?}", modified.plan);
    assert_eq!(modified.new_guids, vec![guid_of(&built.op_id, 7)]);
    let changed_ids = sorted_ids(&modified.changed.keys().cloned().collect::<Vec<_>>());
    assert_eq!(
        changed_ids,
        sorted_ids(&vec![field_guid.clone(), tag_guid.clone()])
    );
    assert_eq!(
        modified.changed.get(&field_guid).unwrap(),
        &file_hash(&built.deck, field_k)
    );
    assert_eq!(
        modified.changed.get(&tag_guid).unwrap(),
        &file_hash(&built.deck, tag_k)
    );
    assert_eq!(resident.import_count(), calls + 1);

    let field_after = resident.note_row(&field_guid).unwrap().unwrap();
    assert!(field_after.flds.contains(new_field), "{}", field_after.flds);
    assert_eq!(field_after.tags, field_before.tags);
    assert!(
        field_after.mod_secs > field_before.mod_secs,
        "mod did not advance ({} -> {})",
        field_before.mod_secs,
        field_after.mod_secs
    );
    let tag_after = resident.note_row(&tag_guid).unwrap().unwrap();
    assert_eq!(
        tag_after.flds, tag_before.flds,
        "tag-only edit changed fields"
    );
    assert_ne!(tag_after.tags, tag_before.tags);
    assert!(
        tag_after.tags.split_whitespace().any(|tag| tag == new_tag),
        "{}",
        tag_after.tags
    );
    for (guid, flds, tags) in unchanged {
        let row = resident.note_row(&guid).unwrap().unwrap();
        assert_eq!(row.flds, flds, "{guid}");
        assert_eq!(row.tags, tags, "{guid}");
    }
    let added = resident
        .note_row(&guid_of(&built.op_id, 7))
        .unwrap()
        .unwrap();
    assert!(added.flds.contains(new_fields[0]), "{}", added.flds);
}

#[test]
fn b1_basic_package_classifies_new_noop_same_and_changed() {
    let Some(bin) = cli_bin() else {
        return;
    };
    let _lock = lock_collections();
    let built = build_deck(&bin, "BasicBox", "Basic", &basic_notes());
    classify_package(
        &bin,
        &built,
        &["BasicBox"],
        0,
        "front-a-edited",
        1,
        "beta",
        &["added front", "added back"],
    );
}

#[test]
fn b1_cloze_package_classifies_new_noop_same_and_changed() {
    let Some(bin) = cli_bin() else {
        return;
    };
    let _lock = lock_collections();
    let built = build_deck(&bin, "ClozeBox", "Cloze", &cloze_notes());
    classify_package(
        &bin,
        &built,
        &["ClozeBox"],
        0,
        "{{c1::alpha edited}}",
        1,
        "beta",
        &["{{c1::added}}", "extra"],
    );
}

#[test]
fn b1_media_package_classifies_new_noop_same_and_changed() {
    let Some(bin) = cli_bin() else {
        return;
    };
    let _lock = lock_collections();
    let built = build_deck(&bin, "MediaBox", "Basic", &media_notes());
    classify_package(
        &bin,
        &built,
        &["MediaBox"],
        0,
        "seen <img src=\"dot.png\">",
        1,
        "beta",
        &["added front", "added back"],
    );
}

#[test]
fn b1_subdeck_package_classifies_new_noop_same_and_changed() {
    let Some(bin) = cli_bin() else {
        return;
    };
    let _lock = lock_collections();
    let built = build_deck(&bin, TREE, "Basic", &subdeck_notes());
    classify_package(
        &bin,
        &built,
        TREE_DECKS,
        0,
        "root front edited",
        1,
        "retagged",
        &["added front", "added back"],
    );
}

#[test]
fn b1_media_only_change_is_same_and_noop() {
    let Some(bin) = cli_bin() else {
        return;
    };
    let _lock = lock_collections();
    let built = build_deck(
        &bin,
        "Pics",
        "Basic",
        &[
            SeedNote {
                k: 0,
                fields: &["see <img src=\"dot.png\">", "caption"],
                tag: "pic",
                deck_name: None,
                notetype: None,
            },
            SeedNote {
                k: 1,
                fields: &["plain", "back"],
                tag: "plain",
                deck_name: None,
                notetype: None,
            },
        ],
    );
    let media = built.dir.path().join("media").join("dot.png");
    fs::write(&media, tiny_png(1)).unwrap();
    let v1 = built.dir.path().join("v1.apkg");
    let v2 = built.dir.path().join("v2.apkg");
    export_apkg(&bin, &built.deck, &v1);
    let exported_at = SystemTime::now();
    fs::write(&media, tiny_png(2)).unwrap();
    wait_until_mod_can_differ(exported_at);
    export_apkg(&bin, &built.deck, &v2);
    assert_ne!(fs::read(&v1).unwrap(), fs::read(&v2).unwrap());

    let (data, mut resident) = open_resident(built.dir.path());
    let first = commit_import(&data, &v1, &mut resident).unwrap();
    assert!(first.first_import, "{:?}", first.plan);
    assert_plan(&first.plan, 2, 0, 0, 0, 0);
    let before = resident.snapshot().unwrap();
    let media_hash = sha256_hex(&tiny_png(1));
    assert_eq!(
        before.media.get("dot.png").map(String::as_str),
        Some(media_hash.as_str()),
        "{:?}",
        before.media.keys().collect::<Vec<_>>()
    );
    let calls = resident.import_count();
    let second = commit_import(&data, &v2, &mut resident).unwrap();
    assert_plan(&second.plan, 0, 2, 0, 0, 0);
    assert!(second.plan.no_resident_call, "{:?}", second.plan);
    assert_eq!(resident.import_count(), calls);
    assert_eq!(resident.snapshot().unwrap(), before);
}

#[test]
fn b3_subdeck_import_commits_notes_and_decks() {
    let Some(bin) = cli_bin() else {
        return;
    };
    let _lock = lock_collections();
    // note_map and deck_map are written by Dart adoption in hatto_store.
    // This crate's collection is the resident notes and deck names that
    // adoption would record.
    let built = build_deck(&bin, TREE, "Basic", &subdeck_notes());
    let apkg = built.dir.path().join("tree.apkg");
    let exported = export_apkg(&bin, &built.deck, &apkg);
    assert_export_guids(&exported, &built.op_id, &built.ks);

    let (data, mut resident) = open_resident(built.dir.path());
    let first = commit_import(&data, &apkg, &mut resident).unwrap();
    assert!(first.first_import, "{:?}", first.plan);
    assert_eq!(first.cardless_notes, 0);
    assert_plan(&first.plan, 5, 0, 0, 0, 0);
    assert!(!first.plan.no_resident_call);
    assert_deck_set(&first.deck_names, TREE_DECKS);
    assert_no_plus_notetype(&resident);

    let expect: BTreeMap<String, &str> = [
        (0, TREE),
        (1, "Tree::Sub"),
        (2, "Tree::Sub::Leaf"),
        (3, "Tree::Other"),
        (4, "Tree::Sub::Leaf"),
    ]
    .into_iter()
    .map(|(k, deck)| (guid_of(&built.op_id, k), deck))
    .collect();
    let mut homes = BTreeMap::new();
    for (guid, deck) in &expect {
        let home = card_deck(&resident, guid);
        assert_eq!(&home, *deck, "{guid}");
        homes.insert(guid.clone(), home);
    }
    let mut deck_ids = BTreeSet::new();
    for name in TREE_DECKS {
        let id = resident
            .deck_id_by_name(name)
            .unwrap()
            .unwrap_or_else(|| panic!("missing deck {name}"));
        assert!(deck_ids.insert(id), "{name} reused an id");
    }
    assert_eq!(sql_count(&resident, "notes"), 5);
    assert_eq!(sql_count(&resident, "cards"), 5);
    assert_eq!(sql_count(&resident, "decks"), 5);

    let snap = resident.snapshot().unwrap();
    let calls = resident.import_count();
    let again = commit_import(&data, &apkg, &mut resident).unwrap();
    assert_plan(&again.plan, 0, 5, 0, 0, 0);
    assert!(again.plan.no_resident_call, "{:?}", again.plan);
    assert_eq!(sql_count(&resident, "notes"), 5);
    assert_eq!(sql_count(&resident, "cards"), 5);
    assert_eq!(sql_count(&resident, "decks"), 5);
    for (guid, deck) in &expect {
        assert_eq!(&card_deck(&resident, guid), deck);
    }
    let mut ids_again = BTreeSet::new();
    for name in TREE_DECKS {
        ids_again.insert(resident.deck_id_by_name(name).unwrap().unwrap());
    }
    assert_eq!(ids_again, deck_ids);
    assert_eq!(homes.len(), 5);
    assert_eq!(resident.import_count(), calls);
    assert_eq!(resident.snapshot().unwrap(), snap);
}

#[test]
fn b4_stage_e_deck_names_and_first_import_flip() {
    let Some(bin) = cli_bin() else {
        return;
    };
    let _lock = lock_collections();
    let built = build_deck(&bin, TREE, "Basic", &subdeck_notes());
    let apkg = built.dir.path().join("tree.apkg");
    export_apkg(&bin, &built.deck, &apkg);

    let (data, mut resident) = open_resident(built.dir.path());
    let staged = stage_import(&data, &apkg, test_limits()).unwrap();
    assert_deck_set(&staged.deck_names, TREE_DECKS);
    assert!(
        found_deck_names(&resident, &staged.deck_names).is_empty(),
        "fresh resident already had a package deck"
    );
    let prepared = {
        let mut lookup = ColLookup { col: &resident };
        finish_import(staged.pending, &mut lookup).unwrap()
    };
    assert!(prepared.first_import, "{prepared:?}");
    assert_deck_set(&prepared.deck_names, TREE_DECKS);
    assert_plan(&prepared.plan, 5, 0, 0, 0, 0);
    import_prepared(&mut resident, &prepared);
    assert_eq!(sql_count(&resident, "notes"), 5);

    let staged = stage_import(&data, &apkg, test_limits()).unwrap();
    assert_deck_set(&staged.deck_names, TREE_DECKS);
    assert_eq!(
        name_set(&found_deck_names(&resident, &staged.deck_names)),
        name_set_owned(TREE_DECKS)
    );
    // SAME notes are removed before the flag is judged, and the empty
    // decks go with them. An empty name list is a first import. The plan
    // is a noop, so the resident collection is not written.
    let noop = {
        let mut lookup = ColLookup { col: &resident };
        finish_import(staged.pending, &mut lookup).unwrap()
    };
    assert_plan(&noop.plan, 0, 5, 0, 0, 0);
    assert!(noop.first_import, "{noop:?}");
    assert!(noop.deck_names.is_empty(), "{:?}", noop.deck_names);
    assert_eq!(sql_count(&resident, "notes"), 5);
    drop(resident);

    let bare_dir = built.dir.path().join("bare");
    let data_bare = built.dir.path().join("data-bare");
    fs::create_dir_all(&data_bare).unwrap();
    let bare = TestCol::open(&bare_dir).unwrap();
    bare.add_deck(TREE).unwrap();
    let staged = stage_import(&data_bare, &apkg, test_limits()).unwrap();
    assert_deck_set(&staged.deck_names, TREE_DECKS);
    assert_eq!(
        found_deck_names(&bare, &staged.deck_names),
        vec![TREE.to_string()]
    );
    for name in ["Tree::Sub", "Tree::Sub::Leaf", "Tree::Other"] {
        assert!(bare.deck_id_by_name(name).unwrap().is_none(), "{name}");
    }
    let flipped = {
        let mut lookup = ColLookup { col: &bare };
        finish_import(staged.pending, &mut lookup).unwrap()
    };
    // One surviving deck name is enough. The child decks are still absent
    // and every note is NEW.
    assert!(!flipped.first_import, "{flipped:?}");
    assert_plan(&flipped.plan, 5, 0, 0, 0, 0);
    assert!(flipped.deck_names.iter().any(|name| name == TREE));
}

fn import_prepared(resident: &mut TestCol, prepared: &PreparedImport) {
    assert!(!prepared.plan.no_resident_call, "{:?}", prepared.plan);
    let response = resident
        .import_resident(&prepared.staged_path, prepared.first_import)
        .unwrap();
    let log = response.log.unwrap_or_default();
    assert!(
        log.conflicting.is_empty(),
        "conflicting {}",
        log.conflicting.len()
    );
}

fn name_set(names: &[String]) -> BTreeSet<String> {
    names.iter().cloned().collect()
}

fn name_set_owned(names: &[&str]) -> BTreeSet<String> {
    names.iter().map(|name| (*name).to_string()).collect()
}

#[test]
fn b5_mixed_notetype_reimport_blocked_is_zero() {
    let Some(bin) = cli_bin() else {
        return;
    };
    let _lock = lock_collections();
    let built = build_deck(&bin, "MixedBox", "Basic", &mixed_notes());
    let v1 = built.dir.path().join("v1.apkg");
    let v2 = built.dir.path().join("v2.apkg");
    let first_export = export_apkg(&bin, &built.deck, &v1);
    assert_export_guids(&first_export, &built.op_id, &built.ks);
    let second_export = export_apkg(&bin, &built.deck, &v2);
    assert_export_guids(&second_export, &built.op_id, &built.ks);

    let (data, mut resident) = open_resident(built.dir.path());
    let first = commit_import(&data, &v1, &mut resident).unwrap();
    assert!(first.first_import, "{:?}", first.plan);
    assert_plan(&first.plan, 5, 0, 0, 0, 0);
    assert_eq!(first.plan.blocked, 0);
    assert_no_plus_notetype(&resident);
    let mids = notetype_ids(&resident, &built.op_id, &built.ks);
    let distinct: BTreeSet<i64> = mids.iter().map(|(_, id)| *id).collect();
    assert_eq!(distinct.len(), 5, "notetypes collapsed: {mids:?}");

    let snap = resident.snapshot().unwrap();
    let calls = resident.import_count();
    let identical = commit_import(&data, &v1, &mut resident).unwrap();
    assert_plan(&identical.plan, 0, 5, 0, 0, 0);
    assert_eq!(identical.plan.blocked, 0, "{:?}", identical.plan);
    assert_eq!(resident.import_count(), calls);
    assert_eq!(resident.snapshot().unwrap(), snap);

    let reexport = commit_import(&data, &v2, &mut resident).unwrap();
    assert_plan(&reexport.plan, 0, 5, 0, 0, 0);
    assert_eq!(reexport.plan.blocked, 0, "{:?}", reexport.plan);
    assert!(reexport.plan.no_resident_call, "{:?}", reexport.plan);
    assert_eq!(notetype_ids(&resident, &built.op_id, &built.ks), mids);
    assert_eq!(resident.import_count(), calls);
    assert_eq!(resident.snapshot().unwrap(), snap);
}

fn notetype_ids(col: &TestCol, op_id: &str, ks: &[u32]) -> Vec<(String, i64)> {
    let mut rows: Vec<_> = ks
        .iter()
        .map(|k| {
            let guid = guid_of(op_id, *k);
            let id = col.note_row(&guid).unwrap().unwrap().notetype_id;
            (guid, id)
        })
        .collect();
    rows.sort();
    rows
}
