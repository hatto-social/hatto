// SPDX-FileCopyrightText: 2026 Hatto Social contributors
//
// SPDX-License-Identifier: AGPL-3.0-or-later

//! `hatto-card` library: validate a provisional deck file and export one deck
//! from a temporary collection.

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
    let pretty = serde_json::to_string_pretty(&value)
        .map_err(|err| ToolFailure::message(err.to_string()))?;
    if let Some(path) = path {
        fs::write(path, pretty + "\n")
            .map_err(|err| ToolFailure::message(format!("write {}: {err}", path.display())))?;
    }
    Ok(json!({ "ok": true, "deck": value }))
}

pub fn validate_path(deck_path: &Path) -> Result<Value, ToolFailure> {
    let (deck, derived) = load(deck_path)?;
    require_media(deck_path, &deck)?;
    Ok(json!({
        "ok": true,
        "notes": note_outs(&derived),
    }))
}

pub fn export_path(deck_path: &Path, out_path: &Path) -> Result<Value, ToolFailure> {
    let (deck, derived) = load(deck_path)?;
    let media_dir = require_media(deck_path, &deck)?;
    let tmp = tempfile::TempDir::new().map_err(|err| ToolFailure::message(err.to_string()))?;
    let session = Session::open(tmp.path()).map_err(ToolFailure::message)?;
    let notetype = resolve_notetype(&session, &deck)?;
    let deck_id = session
        .add_deck(&deck.deck_name)
        .map_err(ToolFailure::message)?;
    if let Some(dir) = media_dir {
        add_media(&session, &dir)?;
    }
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

fn load(deck_path: &Path) -> Result<(DeckFile, Vec<DerivedNote>), ToolFailure> {
    let text = fs::read_to_string(deck_path)
        .map_err(|err| ToolFailure::message(format!("read {}: {err}", deck_path.display())))?;
    let deck = parse_deck(&text).map_err(|problem| ToolFailure::problems(vec![problem]))?;
    let derived = derive_notes(&deck).map_err(ToolFailure::problems)?;
    Ok((deck, derived))
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

/// `media_dir`, when set, must exist. Files inside it are copied as-is.
/// There is no type, magic-byte, or size check.
fn require_media(deck_path: &Path, deck: &DeckFile) -> Result<Option<PathBuf>, ToolFailure> {
    let Some(dir) = media_root(deck_path, deck) else {
        return Ok(None);
    };
    if !dir.is_dir() {
        return Err(ToolFailure::message(format!(
            "media file missing: {}",
            dir.display()
        )));
    }
    Ok(Some(dir))
}

fn add_media(session: &Session, dir: &Path) -> Result<(), ToolFailure> {
    let mut names = fs::read_dir(dir)
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
        let bytes = fs::read(&path).map_err(|err| {
            ToolFailure::message(format!("media file missing: {}: {err}", path.display()))
        })?;
        session
            .add_media_file(name, &bytes)
            .map_err(ToolFailure::message)?;
    }
    Ok(())
}
