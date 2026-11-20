// SPDX-FileCopyrightText: 2026 Hatto Social contributors
//
// SPDX-License-Identifier: AGPL-3.0-or-later

//! `hatto-card` library: validate a provisional deck file, append one note,
//! and export one deck from a temporary collection.

mod collection;
mod deck;

use std::fs;
use std::path::{Path, PathBuf};

use hatto_card_contract::NoteGuid;
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

/// One note to append. `notetype` is the deck's notetype name, not a new field.
#[derive(Clone, Debug)]
pub struct AddNoteRequest {
    pub notetype: String,
    pub fields: Vec<String>,
    pub tags: Vec<String>,
    pub guid: AddNoteGuid,
}

/// How to derive the new note's guid. The two arms cannot be combined.
#[derive(Clone, Debug)]
pub enum AddNoteGuid {
    /// `local_note_guid(op_id, k)`. A missing `op_id` is a new UUIDv4.
    /// A missing `k` is 0, the index of the only note in this write.
    Local {
        op_id: Option<String>,
        k: Option<u32>,
    },
    /// `imported_note_guid(job_id, source_guid)`.
    Imported { job_id: String, source_guid: String },
}

enum AddedNote {
    Local { op_id: String, k: u32 },
    Imported { job_id: String, source_guid: String },
}

pub fn validate_path(deck_path: &Path) -> Result<Value, ToolFailure> {
    let (deck, derived) = load(deck_path)?;
    require_media(deck_path, &deck)?;
    Ok(json!({
        "ok": true,
        "notes": note_outs(&derived),
    }))
}

/// Appends one note. The deck file is written only after [validate_path]'s
/// checks succeed: guid format, an in-file duplicate, and a missing media
/// directory. `output` defaults to `deck_path`.
pub fn add_note_path(
    deck_path: &Path,
    output: Option<&Path>,
    request: &AddNoteRequest,
) -> Result<Value, ToolFailure> {
    let text = fs::read_to_string(deck_path)
        .map_err(|err| ToolFailure::message(format!("read {}: {err}", deck_path.display())))?;
    let deck = parse_deck(&text).map_err(|problem| ToolFailure::problems(vec![problem]))?;
    if deck.notetype_name() != request.notetype {
        return Err(ToolFailure::message(format!(
            "notetype is {}; add-note got {}",
            deck.notetype_name(),
            request.notetype
        )));
    }
    let added = resolve_added(&request.guid);
    let updated = append_note(&text, &note_json(request, &added))?;
    let updated_deck =
        parse_deck(&updated).map_err(|problem| ToolFailure::problems(vec![problem]))?;
    let derived = derive_notes(&updated_deck).map_err(ToolFailure::problems)?;
    let dest = output.unwrap_or(deck_path);
    require_media(dest, &updated_deck)?;
    fs::write(dest, &updated)
        .map_err(|err| ToolFailure::message(format!("write {}: {err}", dest.display())))?;
    Ok(added_json(dest, &added, &derived))
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

fn resolve_added(guid: &AddNoteGuid) -> AddedNote {
    match guid {
        AddNoteGuid::Local { op_id, k } => AddedNote::Local {
            op_id: op_id.clone().unwrap_or_else(new_op_id),
            k: k.unwrap_or(0),
        },
        AddNoteGuid::Imported {
            job_id,
            source_guid,
        } => AddedNote::Imported {
            job_id: job_id.clone(),
            source_guid: source_guid.clone(),
        },
    }
}

fn new_op_id() -> String {
    NoteGuid::from_uuid(uuid::Uuid::new_v4()).into_string()
}

fn note_json(request: &AddNoteRequest, added: &AddedNote) -> Value {
    // The id used for this guid is stored on the note. The deck-level op_id
    // or job_id belongs to notes that omit their own, and this write must
    // not change those notes.
    let mut note = match added {
        AddedNote::Local { op_id, k } => json!({
            "op_id": op_id,
            "k": k,
            "fields": request.fields,
        }),
        AddedNote::Imported {
            job_id,
            source_guid,
        } => json!({
            "job_id": job_id,
            "source_guid": source_guid,
            "fields": request.fields,
        }),
    };
    if !request.tags.is_empty() {
        note["tags"] = json!(request.tags);
    }
    note
}

fn append_note(text: &str, note: &Value) -> Result<String, ToolFailure> {
    let mut value: Value = serde_json::from_str(text)
        .map_err(|err| ToolFailure::message(format!("deck json: {err}")))?;
    let Some(notes) = value.get_mut("notes").and_then(Value::as_array_mut) else {
        return Err(ToolFailure::message("notes is not an array"));
    };
    notes.push(note.clone());
    let pretty = serde_json::to_string_pretty(&value)
        .map_err(|err| ToolFailure::message(err.to_string()))?;
    Ok(pretty + "\n")
}

fn added_json(path: &Path, added: &AddedNote, notes: &[DerivedNote]) -> Value {
    let mut value = json!({
        "ok": true,
        "path": path,
        "notes": note_outs(notes),
    });
    match added {
        AddedNote::Local { op_id, k } => {
            value["op_id"] = json!(op_id);
            value["k"] = json!(k);
        }
        AddedNote::Imported {
            job_id,
            source_guid,
        } => {
            value["job_id"] = json!(job_id);
            value["source_guid"] = json!(source_guid);
        }
    }
    value
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

#[cfg(test)]
mod tests {
    use super::*;
    use hatto_card_contract::{imported_note_guid, is_guid_format, local_note_guid, parse_uuid};

    fn bare_skeleton() -> Value {
        let mut value = skeleton();
        value.as_object_mut().unwrap().remove("media_dir");
        value
    }

    fn write_deck(dir: &Path, value: &Value) -> PathBuf {
        let path = dir.join("deck.json");
        fs::write(&path, serde_json::to_string_pretty(value).unwrap() + "\n").unwrap();
        path
    }

    fn local(op_id: Option<&str>, k: Option<u32>) -> AddNoteRequest {
        AddNoteRequest {
            notetype: "Basic".into(),
            fields: vec!["front".into(), "back".into()],
            tags: Vec::new(),
            guid: AddNoteGuid::Local {
                op_id: op_id.map(str::to_string),
                k,
            },
        }
    }

    fn imported(job_id: &str, source_guid: &str) -> AddNoteRequest {
        AddNoteRequest {
            notetype: "Basic".into(),
            fields: vec!["front".into(), "back".into()],
            tags: Vec::new(),
            guid: AddNoteGuid::Imported {
                job_id: job_id.into(),
                source_guid: source_guid.into(),
            },
        }
    }

    fn read_deck(path: &Path) -> Value {
        serde_json::from_str(&fs::read_to_string(path).unwrap()).unwrap()
    }

    fn last_guid(value: &Value) -> &str {
        value["notes"].as_array().unwrap().last().unwrap()["guid"]
            .as_str()
            .unwrap()
    }

    #[test]
    fn explicit_local_guid_matches_the_contract() {
        let root = tempfile::tempdir().unwrap();
        let path = write_deck(root.path(), &bare_skeleton());
        let before =
            derive_notes(&parse_deck(&fs::read_to_string(&path).unwrap()).unwrap()).unwrap();
        let op_id = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee";
        let added = add_note_path(&path, None, &local(Some(op_id), Some(1))).unwrap();
        let expect =
            NoteGuid::from_uuid(local_note_guid(parse_uuid(op_id).unwrap(), 1)).into_string();
        assert_eq!(last_guid(&added), expect);
        assert_eq!(added["op_id"], op_id);
        assert_eq!(added["k"], 1);
        assert_eq!(added["notes"].as_array().unwrap().len(), 4);
        let file = read_deck(&path);
        assert_eq!(file["op_id"], "fedcba98-7654-4210-8fed-cba987654321");
        let notes = file["notes"].as_array().unwrap();
        assert!(notes[0].get("op_id").is_none());
        assert_eq!(notes[3]["op_id"], op_id);
        assert_eq!(notes[3]["k"], 1);
        assert!(notes[3].get("tags").is_none());
        assert!(notes[3].get("source_guid").is_none());
        let after =
            derive_notes(&parse_deck(&fs::read_to_string(&path).unwrap()).unwrap()).unwrap();
        assert_eq!(after[0].guid, before[0].guid);
        assert_eq!(after[1].guid, before[1].guid);
        assert_eq!(after[2].guid, before[2].guid);
        let checked = validate_path(&path).unwrap();
        assert_eq!(checked["ok"], true);
        assert_eq!(last_guid(&checked), expect);
    }

    #[test]
    fn fresh_op_id_is_uuid_v4_and_k_defaults_to_zero() {
        let root = tempfile::tempdir().unwrap();
        let path = write_deck(root.path(), &bare_skeleton());
        let first = add_note_path(&path, None, &local(None, None)).unwrap();
        let second = add_note_path(&path, None, &local(None, Some(4))).unwrap();
        let first_op = first["op_id"].as_str().unwrap();
        let second_op = second["op_id"].as_str().unwrap();
        assert_ne!(first_op, second_op);
        assert_ne!(first_op, "fedcba98-7654-4210-8fed-cba987654321");
        assert!(is_guid_format(first_op));
        assert_eq!(parse_uuid(first_op).unwrap().get_version_num(), 4);
        assert_eq!(first["k"], 0);
        assert_eq!(second["k"], 4);
        let expect =
            NoteGuid::from_uuid(local_note_guid(parse_uuid(first_op).unwrap(), 0)).into_string();
        assert_eq!(last_guid(&first), expect);
        let file = read_deck(&path);
        let notes = file["notes"].as_array().unwrap();
        assert_eq!(notes.len(), 5);
        assert_eq!(notes[3]["k"], 0);
        assert_eq!(notes[4]["k"], 4);
        assert_eq!(notes[4]["fields"], json!(["front", "back"]));
    }

    #[test]
    fn imported_guid_keeps_the_source_bytes() {
        let root = tempfile::tempdir().unwrap();
        let path = write_deck(root.path(), &bare_skeleton());
        let job_id = "11111111-2222-4333-8444-555555555555";
        let source = "  note  ";
        let added = add_note_path(&path, None, &imported(job_id, source)).unwrap();
        let expect =
            NoteGuid::from_uuid(imported_note_guid(parse_uuid(job_id).unwrap(), source).unwrap())
                .into_string();
        assert_eq!(last_guid(&added), expect);
        assert_eq!(added["source_guid"], source);
        let note = read_deck(&path)["notes"][3].clone();
        assert_eq!(note["source_guid"], source);
        assert_eq!(note["job_id"], job_id);
        assert!(note.get("op_id").is_none());
        assert!(note.get("k").is_none());
    }

    #[test]
    fn failed_checks_do_not_write() {
        let root = tempfile::tempdir().unwrap();
        let mut deck = skeleton();
        deck.as_object_mut().unwrap().remove("media_dir");
        let path = write_deck(root.path(), &deck);
        let source = deck["notes"][0]["source_guid"]
            .as_str()
            .unwrap()
            .to_string();
        let job_id = deck["job_id"].as_str().unwrap().to_string();
        let before = fs::read(&path).unwrap();

        let duplicate = add_note_path(&path, None, &imported(&job_id, &source)).unwrap_err();
        assert!(duplicate
            .errors
            .iter()
            .any(|error| error.code == "NOTE_GUID_DUPLICATE"));
        assert_eq!(fs::read(&path).unwrap(), before);

        let empty = add_note_path(&path, None, &imported(&job_id, "")).unwrap_err();
        assert!(empty
            .errors
            .iter()
            .any(|error| error.code == "GUID_FORMAT" && error.location.ends_with("source_guid")));
        assert_eq!(fs::read(&path).unwrap(), before);

        let upper = add_note_path(
            &path,
            None,
            &local(Some("AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE"), Some(0)),
        )
        .unwrap_err();
        assert!(upper.errors.iter().any(|error| error.code == "GUID_FORMAT"));
        assert_eq!(fs::read(&path).unwrap(), before);

        let mut wrong_type = local(None, None);
        wrong_type.notetype = "Cloze".into();
        let mismatch = add_note_path(&path, None, &wrong_type).unwrap_err();
        assert_eq!(
            mismatch.message.as_deref(),
            Some("notetype is Basic; add-note got Cloze")
        );
        assert!(mismatch.errors.is_empty());
        assert_eq!(fs::read(&path).unwrap(), before);

        let mut missing_media = skeleton();
        missing_media["media_dir"] = json!("missing-media");
        let media_root = root.path().join("media-case");
        fs::create_dir(&media_root).unwrap();
        let media_path = write_deck(&media_root, &missing_media);
        let media_before = fs::read(&media_path).unwrap();
        let media = add_note_path(&media_path, None, &local(None, None)).unwrap_err();
        assert!(media
            .message
            .as_deref()
            .is_some_and(|message| message.contains("media file missing")));
        assert_eq!(fs::read(&media_path).unwrap(), media_before);
    }

    #[test]
    fn output_path_and_tags_leave_the_input_shape() {
        let root = tempfile::tempdir().unwrap();
        let mut value = bare_skeleton();
        value.as_object_mut().unwrap().remove("notetype");
        value["notetype_legacy"] = json!({"id": 1, "name": "Basic"});
        value["extra"] = json!("keep");
        let path = write_deck(root.path(), &value);
        let before = fs::read(&path).unwrap();
        let out = root.path().join("copy.json");
        let mut request = local(Some("aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"), None);
        request.tags = vec!["one".into(), "two".into()];
        let added = add_note_path(&path, Some(&out), &request).unwrap();
        assert_eq!(fs::read(&path).unwrap(), before);
        assert_eq!(added["path"], out.to_str().unwrap());
        let copy = read_deck(&out);
        assert!(copy.get("notetype").is_none());
        assert_eq!(copy["notetype_legacy"]["id"], 1);
        assert_eq!(copy["extra"], "keep");
        let note = &copy["notes"][3];
        assert_eq!(note["tags"], json!(["one", "two"]));
        assert_eq!(note["k"], 0);
        assert_eq!(copy["notes"].as_array().unwrap().len(), 4);
    }
}
