// SPDX-FileCopyrightText: 2026 Hatto Social contributors
//
// SPDX-License-Identifier: AGPL-3.0-or-later

//! `hatto-card` library: validate a provisional deck file, write it into a
//! temp collection, export one deck, and read that package back.

mod collection;
mod deck;

use std::fs;
use std::path::{Path, PathBuf};

use serde::Serialize;
use serde_json::{json, Value};

use crate::collection::Session;
use crate::deck::{derive_notes, parse_deck, skeleton, DeckFile, DerivedNote, Problem};

pub use crate::deck::Problem as DeckProblem;

pub use crate::deck::skeleton as skeleton_deck;

#[derive(Debug)]
pub struct ToolFailure {
    pub message: Option<String>,
    pub errors: Vec<DeckProblem>,
}

impl ToolFailure {
    fn message(message: impl Into<String>) -> Self {
        Self {
            message: Some(message.into()),
            errors: Vec::new(),
        }
    }

    fn problems(errors: Vec<Problem>) -> Self {
        Self {
            message: None,
            errors,
        }
    }
}

#[derive(Debug, Serialize)]
pub struct NoteOut {
    pub location: String,
    pub guid: String,
}

pub fn failure_json(failure: &ToolFailure) -> Value {
    let errors: Vec<Value> = failure
        .errors
        .iter()
        .map(|problem| {
            let mut value = json!({
                "location": problem.location,
                "message": problem.message,
            });
            if !problem.code.is_empty() {
                value["code"] = json!(problem.code);
            }
            value
        })
        .collect();
    let mut value = json!({ "ok": false, "errors": errors });
    if let Some(message) = &failure.message {
        value["message"] = json!(message);
    }
    value
}

pub fn write_skeleton(path: Option<&Path>) -> Result<Value, ToolFailure> {
    let value = skeleton();
    let pretty = serde_json::to_string_pretty(&value).map_err(|err| ToolFailure::message(err.to_string()))?;
    if let Some(path) = path {
        fs::write(path, pretty + "\n").map_err(|err| {
            ToolFailure::message(format!("write {}: {err}", path.display()))
        })?;
    }
    Ok(json!({ "ok": true, "deck": value }))
}

pub fn validate_path(deck_path: &Path) -> Result<Value, ToolFailure> {
    let derived = load_derived(deck_path)?;
    Ok(json!({
        "ok": true,
        "notes": note_outs(&derived),
    }))
}

pub fn export_path(deck_path: &Path, out_path: &Path) -> Result<Value, ToolFailure> {
    let (deck, derived) = load(deck_path)?;
    let tmp = tempfile::TempDir::new().map_err(|err| ToolFailure::message(err.to_string()))?;
    let session = Session::open(tmp.path()).map_err(ToolFailure::message)?;
    let notetype = resolve_notetype(&session, &deck)?;
    let deck_id = session
        .add_deck(&deck.deck_name)
        .map_err(ToolFailure::message)?;
    add_media(&session, deck_path, &deck)?;
    for note in &derived {
        session
            .add_note(notetype, deck_id, note)
            .map_err(ToolFailure::message)?;
    }
    if let Some(parent) = out_path.parent() {
        if !parent.as_os_str().is_empty() {
            fs::create_dir_all(parent).map_err(|err| ToolFailure::message(err.to_string()))?;
        }
    }
    session
        .export_deck(out_path, deck_id)
        .map_err(ToolFailure::message)?;
    Ok(json!({
        "ok": true,
        "apkg": out_path,
        "deck_id": deck_id,
        "notes": note_outs(&derived),
    }))
}

pub fn verify_path(deck_path: &Path, apkg: &Path) -> Result<Value, ToolFailure> {
    let (deck, derived) = load(deck_path)?;
    if !apkg.is_file() {
        return Err(ToolFailure::message(format!(
            "apkg does not exist: {}",
            apkg.display()
        )));
    }
    let tmp = tempfile::TempDir::new().map_err(|err| ToolFailure::message(err.to_string()))?;
    let session = Session::open(tmp.path()).map_err(ToolFailure::message)?;
    let imported = session.import_apkg(apkg).map_err(ToolFailure::message)?;
    let log = imported
        .log
        .ok_or_else(|| ToolFailure::message("import returned no log"))?;
    if log.new.len() != derived.len() || !log.duplicate.is_empty() {
        return Err(ToolFailure::message(format!(
            "import new={} duplicate={} expected new={} duplicate=0",
            log.new.len(),
            log.duplicate.len(),
            derived.len()
        )));
    }
    let names = session.deck_names().map_err(ToolFailure::message)?;
    if !names.iter().any(|name| name == &deck.deck_name) {
        return Err(ToolFailure::message(format!(
            "deck {} not in imported names {names:?}",
            deck.deck_name
        )));
    }
    let rows = session
        .query("select id, guid from notes order by id")
        .map_err(ToolFailure::message)?;
    let rows = rows
        .as_array()
        .ok_or_else(|| ToolFailure::message("notes query was not a list"))?;
    let mut by_guid = std::collections::BTreeMap::new();
    for row in rows {
        let id = row[0]
            .as_i64()
            .ok_or_else(|| ToolFailure::message(format!("note id {row}")))?;
        let guid = row[1]
            .as_str()
            .ok_or_else(|| ToolFailure::message(format!("note guid {row}")))?
            .to_string();
        let note = session.get_note(id).map_err(ToolFailure::message)?;
        by_guid.insert(guid, note);
    }
    for expected in &derived {
        let Some(note) = by_guid.get(&expected.guid) else {
            return Err(ToolFailure::message(format!(
                "imported collection has no guid {}",
                expected.guid
            )));
        };
        if note.fields != expected.fields {
            return Err(ToolFailure::message(format!(
                "{} fields {:?} != {:?}",
                expected.guid, note.fields, expected.fields
            )));
        }
        let mut tags = note.tags.clone();
        let mut expect_tags = expected.tags.clone();
        tags.sort();
        expect_tags.sort();
        if tags != expect_tags {
            return Err(ToolFailure::message(format!(
                "{} tags {tags:?} != {expect_tags:?}",
                expected.guid
            )));
        }
    }
    let cards = session
        .query("select type, queue from cards")
        .map_err(ToolFailure::message)?;
    let cards = cards
        .as_array()
        .ok_or_else(|| ToolFailure::message("cards query was not a list"))?;
    if cards.is_empty() {
        return Err(ToolFailure::message("imported package has no cards"));
    }
    for card in cards {
        let card_type = card[0].as_i64().unwrap_or(-1);
        let queue = card[1].as_i64().unwrap_or(-1);
        if card_type != 0 || queue != 0 {
            return Err(ToolFailure::message(format!(
                "card is not new: type={card_type} queue={queue}"
            )));
        }
    }
    let revlog = session
        .query("select count(*) from revlog")
        .map_err(ToolFailure::message)?;
    let revlog = revlog[0][0].as_i64().unwrap_or(-1);
    if revlog != 0 {
        return Err(ToolFailure::message(format!("revlog rows: {revlog}")));
    }
    let media = compare_media(&session, deck_path, &deck)?;
    Ok(json!({
        "ok": true,
        "notes": derived.len(),
        "cards_new": cards.len(),
        "revlog": revlog,
        "deck": deck.deck_name,
        "media": media,
    }))
}

fn load(deck_path: &Path) -> Result<(DeckFile, Vec<DerivedNote>), ToolFailure> {
    let text = fs::read_to_string(deck_path).map_err(|err| {
        ToolFailure::message(format!("read {}: {err}", deck_path.display()))
    })?;
    let deck = parse_deck(&text).map_err(|problem| ToolFailure::problems(vec![problem]))?;
    let derived = derive_notes(&deck).map_err(ToolFailure::problems)?;
    Ok((deck, derived))
}

fn load_derived(deck_path: &Path) -> Result<Vec<DerivedNote>, ToolFailure> {
    Ok(load(deck_path)?.1)
}

fn note_outs(notes: &[DerivedNote]) -> Vec<NoteOut> {
    notes
        .iter()
        .map(|note| NoteOut {
            location: note.location.clone(),
            guid: note.guid.clone(),
        })
        .collect()
}

fn resolve_notetype(session: &Session, deck: &DeckFile) -> Result<i64, ToolFailure> {
    if let Some(model) = &deck.notetype_legacy {
        return session
            .add_notetype_legacy(model)
            .map_err(ToolFailure::message);
    }
    session
        .notetype_id(deck.notetype_name())
        .map_err(ToolFailure::message)
}

fn media_root(deck_path: &Path, deck: &DeckFile) -> Option<PathBuf> {
    let raw = deck.media_dir.as_deref()?;
    let path = PathBuf::from(raw);
    if path.is_absolute() {
        Some(path)
    } else {
        Some(deck_path.parent().unwrap_or(Path::new(".")).join(path))
    }
}

fn add_media(session: &Session, deck_path: &Path, deck: &DeckFile) -> Result<(), ToolFailure> {
    let Some(dir) = media_root(deck_path, deck) else {
        return Ok(());
    };
    if !dir.is_dir() {
        return Err(ToolFailure::message(format!(
            "media_dir does not exist: {}",
            dir.display()
        )));
    }
    let mut names = fs::read_dir(&dir)
        .map_err(|err| ToolFailure::message(err.to_string()))?
        .map(|entry| entry.map_err(|err| ToolFailure::message(err.to_string())))
        .collect::<Result<Vec<_>, _>>()?;
    names.sort_by_key(|entry| entry.file_name());
    for entry in names {
        let path = entry.path();
        if !path.is_file() {
            continue;
        }
        let name = entry.file_name();
        let Some(name) = name.to_str() else {
            return Err(ToolFailure::message(format!(
                "media name is not utf-8: {}",
                path.display()
            )));
        };
        let bytes = fs::read(&path).map_err(|err| ToolFailure::message(err.to_string()))?;
        session
            .add_media_file(name, &bytes)
            .map_err(ToolFailure::message)?;
    }
    Ok(())
}

fn compare_media(
    session: &Session,
    deck_path: &Path,
    deck: &DeckFile,
) -> Result<Vec<String>, ToolFailure> {
    let Some(dir) = media_root(deck_path, deck) else {
        return Ok(Vec::new());
    };
    let mut expected = Vec::new();
    for entry in fs::read_dir(&dir).map_err(|err| ToolFailure::message(err.to_string()))? {
        let entry = entry.map_err(|err| ToolFailure::message(err.to_string()))?;
        if !entry.path().is_file() {
            continue;
        }
        let name = entry.file_name();
        let Some(name) = name.to_str() else {
            return Err(ToolFailure::message(
                "media name is not utf-8".to_string(),
            ));
        };
        let source = fs::read(entry.path()).map_err(|err| ToolFailure::message(err.to_string()))?;
        let imported = session.media_dir().join(name);
        let got = fs::read(&imported).map_err(|_| {
            ToolFailure::message(format!("imported media missing {name}"))
        })?;
        if got != source {
            return Err(ToolFailure::message(format!(
                "media {name} bytes differ"
            )));
        }
        expected.push(name.to_string());
    }
    expected.sort();
    Ok(expected)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn legacy_notetype_roundtrip_has_new_cards_and_no_revlog() {
        let model = collection::stock_notetype_legacy("Basic", "Example Vocab")
            .expect("legacy notetype");
        let dir = tempfile::TempDir::new().unwrap();
        let deck_path = dir.path().join("deck.json");
        let mut deck = skeleton();
        deck.as_object_mut().unwrap().remove("notetype");
        deck.as_object_mut().unwrap().remove("media_dir");
        deck["notetype_legacy"] = model;
        fs::write(&deck_path, serde_json::to_vec_pretty(&deck).unwrap()).unwrap();
        let apkg = dir.path().join("out.apkg");
        export_path(&deck_path, &apkg).expect("export");
        let report = verify_path(&deck_path, &apkg).expect("verify");
        assert_eq!(report["ok"], json!(true));
        assert_eq!(report["notes"], json!(3));
        assert_eq!(report["revlog"], json!(0));
        assert!(report["cards_new"].as_u64().unwrap() >= 3);
    }
}
