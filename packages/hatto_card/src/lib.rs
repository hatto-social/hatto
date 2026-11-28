// SPDX-FileCopyrightText: 2026 Hatto Social contributors
//
// SPDX-License-Identifier: AGPL-3.0-or-later

//! `hatto-card` library: validate a provisional deck file, append notes,
//! export one deck (and its subdecks) from a temporary collection, and
//! inspect an apkg through Stage E without opening a user collection.

mod collection;
mod deck;
mod inspect;
mod seed;

use std::collections::HashMap;
use std::fs;
use std::path::{Component, Path, PathBuf};

use hatto_card_contract::NoteGuid;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};

use crate::collection::{FieldCheckError, Session};
use crate::deck::{
    derive_notes, notetype_unknown, parse_deck, skeleton, DeckFile, DerivedNote, Problem,
    CLOZE_MISSING, FIELD_COUNT, MEDIA_MISSING,
};

pub use crate::deck::Problem as DeckProblem;

pub use crate::deck::skeleton as skeleton_deck;

pub use crate::inspect::{
    inspect_path, INSPECT_MAX_BYTES, INSPECT_MAX_UNCOMPRESSED_BYTES, INSPECT_TEMP_PREFIX,
};

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

/// Options for [`write_new_deck`].
pub struct NewDeck<'a> {
    pub deck_name: Option<&'a str>,
    pub notetype: Option<&'a str>,
    /// `notes: []` instead of the three example notes.
    pub empty: bool,
}

/// Writes the example deck with a new UUIDv4 `job_id` and `op_id`.
///
/// `deck_name` replaces the example name when set. An empty name is rejected
/// so the file is not written in a shape `validate` already refuses. With
/// `path` set, `media/dot.png` is created beside the file when that file is
/// missing. The note still references that image, and `validate` requires the
/// media directory. This is [`write_new_deck`] with the example notetype and
/// the three sample notes.
pub fn write_skeleton(path: Option<&Path>, deck_name: Option<&str>) -> Result<Value, ToolFailure> {
    write_new_deck(
        path,
        NewDeck {
            deck_name,
            notetype: None,
            empty: false,
        },
    )
}

/// Writes a deck file. Without [`NewDeck::empty`], the three example notes
/// stay and `notetype` stays `Basic` unless `notetype` is set. `--empty`
/// writes `notes: []` and, when `notetype` is omitted, `Hatto Basic`.
///
/// `notetype`, when set, must be a seed notetype name (stock or Hatto). An
/// unknown name does not write the file.
pub fn write_new_deck(path: Option<&Path>, spec: NewDeck<'_>) -> Result<Value, ToolFailure> {
    let mut value = skeleton();
    if let Some(name) = spec.deck_name {
        if name.is_empty() {
            return Err(ToolFailure::message("deck_name is empty"));
        }
        value["deck_name"] = json!(name);
    }
    if let Some(notetype) = spec.notetype {
        if notetype.is_empty() {
            return Err(ToolFailure::message("notetype is empty"));
        }
        require_seed_notetype(notetype, "--notetype")?;
        value["notetype"] = json!(notetype);
    } else if spec.empty {
        value["notetype"] = json!("Hatto Basic");
    }
    if spec.empty {
        value["notes"] = json!([]);
    }
    value["job_id"] = json!(new_op_id());
    value["op_id"] = json!(new_op_id());
    let pretty = serde_json::to_string_pretty(&value)
        .map_err(|err| ToolFailure::message(err.to_string()))?;
    if let Some(path) = path {
        fs::write(path, pretty + "\n")
            .map_err(|err| ToolFailure::message(format!("write {}: {err}", path.display())))?;
        write_example_media(path, &value)?;
    }
    Ok(json!({ "ok": true, "deck": value }))
}

/// Bytes of `examples/with-media/media/dot.png`. `new` references this file.
const EXAMPLE_DOT_PNG: &[u8] = include_bytes!("../examples/with-media/media/dot.png");

/// Creates the skeleton's media file. An existing `dot.png` is left as-is so
/// a caller that already placed bytes there keeps them.
fn write_example_media(deck_path: &Path, deck: &Value) -> Result<(), ToolFailure> {
    let Some(raw) = deck.get("media_dir").and_then(Value::as_str) else {
        return Ok(());
    };
    let relative = PathBuf::from(raw);
    if relative.is_absolute() {
        return Err(ToolFailure::message(
            "skeleton media_dir must stay relative to the deck file",
        ));
    }
    let parent = deck_path
        .parent()
        .filter(|path| !path.as_os_str().is_empty())
        .unwrap_or(Path::new("."));
    let dir = parent.join(relative);
    fs::create_dir_all(&dir)
        .map_err(|err| ToolFailure::message(format!("write {}: {err}", dir.display())))?;
    let png = dir.join("dot.png");
    if png.exists() {
        return Ok(());
    }
    fs::write(&png, EXAMPLE_DOT_PNG)
        .map_err(|err| ToolFailure::message(format!("write {}: {err}", png.display())))
}

/// One note to append. `notetype` must be the deck's notetype (either spelling).
/// `deck_name`, when set, is stored on the note and must be the deck root or a child.
#[derive(Clone, Debug)]
pub struct AddNoteRequest {
    pub notetype: String,
    pub fields: Vec<String>,
    pub tags: Vec<String>,
    pub guid: AddNoteGuid,
    pub deck_name: Option<String>,
}

/// One batch of notes for [`add_notes_path`].
///
/// Notes whose [`BatchGuid`] is [`BatchGuid::Omitted`] share one `op_id`
/// (the request's, or one new UUIDv4 for the call) and take `k` from
/// `start_k` upward.
#[derive(Clone, Debug)]
pub struct AddNotesRequest {
    pub notetype: Option<String>,
    pub op_id: Option<String>,
    pub start_k: u32,
    pub notes: Vec<BatchNote>,
}

/// One note inside [`AddNotesRequest`].
#[derive(Clone, Debug)]
pub struct BatchNote {
    pub fields: Vec<String>,
    pub tags: Vec<String>,
    pub notetype: Option<String>,
    pub deck_name: Option<String>,
    pub guid: BatchGuid,
}

/// How a batch note chooses its guid.
#[derive(Clone, Debug)]
pub enum BatchGuid {
    /// No `op_id`, `k`, `job_id`, or `source_guid` on the item.
    Omitted,
    /// The item named a local or imported guid.
    Specified(AddNoteGuid),
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
    /// `normalize_import_guid(source_guid)`. `job_id` is stored on the note
    /// and ignored for the guid.
    Imported { job_id: String, source_guid: String },
}

enum AddedNote {
    Local { op_id: String, k: u32 },
    Imported { job_id: String, source_guid: String },
}

pub fn validate_path(deck_path: &Path) -> Result<Value, ToolFailure> {
    let text = read_deck_file(deck_path)?;
    validate_text(&text, media_base_of(deck_path))
}

/// Checks `text` the same way as [`validate_path`].
///
/// A relative `media_dir` is resolved from `media_base`. For a deck file that
/// is the file's parent. For stdin it is the current directory.
pub fn validate_text(text: &str, media_base: &Path) -> Result<Value, ToolFailure> {
    let (deck, derived) = load_text(text)?;
    let _checked = check_deck(media_base, &deck, &derived)?;
    Ok(json!({
        "ok": true,
        "notes": note_outs(&derived),
    }))
}

/// Appends one note. The deck file is written only after the same checks as
/// [`validate_path`]: guid format, an in-file duplicate, the media directory,
/// media references, the seed notetype, the field count, and cloze syntax.
/// `output` defaults to `deck_path`. `--notetype` must name the deck's notetype.
pub fn add_note_path(
    deck_path: &Path,
    output: Option<&Path>,
    request: &AddNoteRequest,
) -> Result<Value, ToolFailure> {
    let text = read_deck_file(deck_path)?;
    let deck = parse_deck(&text).map_err(|problem| ToolFailure::problems(vec![problem]))?;
    if let Some(name) = deck.notetype.as_deref() {
        require_seed_notetype(name, "notetype")?;
    }
    require_seed_notetype(&request.notetype, "--notetype")?;
    if seed::canonical_notetype(deck.notetype_name()) != seed::canonical_notetype(&request.notetype)
    {
        return Err(ToolFailure::message(format!(
            "notetype is {}; add-note got {}",
            deck.notetype_name(),
            request.notetype
        )));
    }
    let added = resolve_added(&request.guid);
    let updated = append_notes(&text, &[note_json(request, &added)])?;
    let updated_deck =
        parse_deck(&updated).map_err(|problem| ToolFailure::problems(vec![problem]))?;
    let derived = derive_notes(&updated_deck).map_err(ToolFailure::problems)?;
    let dest = output.unwrap_or(deck_path);
    checked_write(dest, &updated, &updated_deck, &derived)?;
    Ok(added_json(dest, &added, &derived))
}

/// Appends every note in `request`, or writes nothing.
///
/// A failure of any note (guid, subdeck, notetype, field count, cloze, or
/// media) leaves `deck_path` and `output` unchanged.
pub fn add_notes_path(
    deck_path: &Path,
    output: Option<&Path>,
    request: &AddNotesRequest,
) -> Result<Value, ToolFailure> {
    if request.notes.is_empty() {
        return Err(ToolFailure::message("input is empty"));
    }
    if let Some(notetype) = request.notetype.as_deref() {
        if notetype.is_empty() {
            return Err(ToolFailure::message("notetype is empty"));
        }
        require_seed_notetype(notetype, "--notetype")?;
    }
    let text = read_deck_file(deck_path)?;
    let deck = parse_deck(&text).map_err(|problem| ToolFailure::problems(vec![problem]))?;
    let base = deck.notes.len();
    let mut auto_op = request.op_id.clone();
    let mut next_k = Some(request.start_k);
    let mut used_auto = false;
    let mut reported_op = None;
    let mut notes = Vec::with_capacity(request.notes.len());
    for (index, item) in request.notes.iter().enumerate() {
        let requested = item.notetype.clone().or_else(|| request.notetype.clone());
        let stored_notetype = stored_notetype(&deck, requested, &format!("input[{index}]"))?;
        let added = resolve_batch_guid(
            index,
            &item.guid,
            &request.op_id,
            &mut auto_op,
            &mut next_k,
            &mut used_auto,
            &mut reported_op,
        )?;
        notes.push(batch_note_json(item, &added, stored_notetype.as_deref()));
    }
    let updated = append_notes(&text, &notes)?;
    let updated_deck =
        parse_deck(&updated).map_err(|problem| ToolFailure::problems(vec![problem]))?;
    let derived = derive_notes(&updated_deck)
        .map_err(|problems| ToolFailure::problems(remap_added_locations(problems, base)))?;
    let dest = output.unwrap_or(deck_path);
    checked_write(dest, &updated, &updated_deck, &derived).map_err(|failure| ToolFailure {
        message: failure
            .message
            .map(|message| remap_note_ref(&message, base)),
        errors: remap_added_locations(failure.errors, base),
    })?;
    let mut value = json!({
        "ok": true,
        "path": dest,
        "added": request.notes.len(),
        "notes": note_outs(&derived),
    });
    if let Some(op_id) = reported_op {
        value["op_id"] = json!(op_id);
    }
    if used_auto {
        value["start_k"] = json!(request.start_k);
    }
    Ok(value)
}

/// Parses a JSON array or JSONL batch. Blank JSONL lines are skipped.
pub fn parse_notes_input(text: &str) -> Result<Vec<BatchNote>, ToolFailure> {
    let values = parse_note_values(text)?;
    values
        .into_iter()
        .enumerate()
        .map(|(index, value)| {
            let raw: BatchNoteJson = serde_json::from_value(value)
                .map_err(|err| input_problem(index, format!("input json: {err}")))?;
            batch_from_json(index, raw)
        })
        .collect()
}

fn parse_note_values(text: &str) -> Result<Vec<Value>, ToolFailure> {
    let trimmed = text.trim();
    if trimmed.is_empty() {
        return Err(ToolFailure::message("input is empty"));
    }
    if trimmed.starts_with('[') {
        let values: Vec<Value> = serde_json::from_str(trimmed).map_err(|err| {
            ToolFailure::problems(vec![Problem {
                code: String::new(),
                location: "input".into(),
                message: format!("input json: {err}"),
            }])
        })?;
        if values.is_empty() {
            return Err(ToolFailure::message("input is empty"));
        }
        return Ok(values);
    }
    let mut values = Vec::new();
    for (line_index, line) in text.lines().enumerate() {
        let line = line.trim();
        if line.is_empty() {
            continue;
        }
        let value: Value = serde_json::from_str(line).map_err(|err| {
            input_problem(
                values.len(),
                format!("input line {}: {err}", line_index + 1),
            )
        })?;
        values.push(value);
    }
    if values.is_empty() {
        return Err(ToolFailure::message("input is empty"));
    }
    Ok(values)
}

fn input_problem(index: usize, message: String) -> ToolFailure {
    ToolFailure::problems(vec![Problem {
        code: String::new(),
        location: format!("input[{index}]"),
        message,
    }])
}

pub fn export_path(deck_path: &Path, out_path: &Path) -> Result<Value, ToolFailure> {
    let text = read_deck_file(deck_path)?;
    export_text(&text, media_base_of(deck_path), out_path)
}

/// Exports `text`. A relative `media_dir` is resolved from `media_base`.
///
/// The root deck id is what `export_anki_package` receives. rslib turns that
/// id into `DeckIdWithChildren`, so notes on `{root}::...` are in the package
/// with the root.
pub fn export_text(text: &str, media_base: &Path, out_path: &Path) -> Result<Value, ToolFailure> {
    let (deck, derived) = load_text(text)?;
    let (session_root, media_dir) = check_deck(media_base, &deck, &derived)?;
    let (_tmp, session) = session_root;
    let deck_ids = ensure_decks(&session, &deck.deck_name, &derived)?;
    if let Some(dir) = media_dir {
        add_media(&session, &dir)?;
    }
    for note in &derived {
        let notetype = session
            .notetype_id(seed::canonical_notetype(&note.notetype))
            .map_err(ToolFailure::message)?;
        let deck_id = deck_ids.get(&note.deck_name).copied().ok_or_else(|| {
            ToolFailure::message(format!("deck {} was not created", note.deck_name))
        })?;
        session
            .add_note(notetype, deck_id, note)
            .map_err(ToolFailure::message)?;
    }
    let root_id = *deck_ids
        .get(&deck.deck_name)
        .ok_or_else(|| ToolFailure::message(format!("deck {} was not created", deck.deck_name)))?;
    if let Some(parent) = out_path.parent() {
        if !parent.as_os_str().is_empty() {
            fs::create_dir_all(parent).map_err(|err| ToolFailure::message(err.to_string()))?;
        }
    }
    session
        .export_deck(out_path, root_id)
        .map_err(ToolFailure::message)?;
    Ok(json!({
        "ok": true,
        "apkg": out_path,
        "deck_id": root_id,
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
    // Store the id this note was given. A local note stores `op_id` and `k`.
    // An imported note stores `source_guid` and, when passed, `job_id`.
    // `job_id` is not an input to the guid. The deck-level op_id or job_id
    // belongs to notes that omit their own, and this write must not change
    // those notes.
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
    if let Some(name) = &request.deck_name {
        note["deck_name"] = json!(name);
    }
    note
}

fn batch_note_json(item: &BatchNote, added: &AddedNote, notetype: Option<&str>) -> Value {
    let request = AddNoteRequest {
        notetype: String::new(),
        fields: item.fields.clone(),
        tags: item.tags.clone(),
        guid: AddNoteGuid::Local {
            op_id: None,
            k: None,
        },
        deck_name: item.deck_name.clone(),
    };
    let mut note = note_json(&request, added);
    if let Some(notetype) = notetype {
        note["notetype"] = json!(notetype);
    }
    note
}

fn append_notes(text: &str, notes: &[Value]) -> Result<String, ToolFailure> {
    let mut value: Value = serde_json::from_str(text)
        .map_err(|err| ToolFailure::message(format!("deck json: {err}")))?;
    let Some(existing) = value.get_mut("notes").and_then(Value::as_array_mut) else {
        return Err(ToolFailure::message("notes is not an array"));
    };
    for note in notes {
        existing.push(note.clone());
    }
    let pretty = serde_json::to_string_pretty(&value)
        .map_err(|err| ToolFailure::message(err.to_string()))?;
    Ok(pretty + "\n")
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct BatchNoteJson {
    fields: Vec<String>,
    #[serde(default)]
    tags: Vec<String>,
    #[serde(default)]
    notetype: Option<String>,
    #[serde(default)]
    deck_name: Option<String>,
    #[serde(default)]
    op_id: Option<String>,
    #[serde(default)]
    k: Option<u32>,
    #[serde(default)]
    job_id: Option<String>,
    #[serde(default)]
    source_guid: Option<String>,
}

fn batch_from_json(index: usize, raw: BatchNoteJson) -> Result<BatchNote, ToolFailure> {
    if raw.fields.is_empty() {
        return Err(input_problem(index, "fields is empty".into()));
    }
    let local = raw.op_id.is_some() || raw.k.is_some();
    let imported = raw.job_id.is_some() || raw.source_guid.is_some();
    if local && imported {
        return Err(input_problem(
            index,
            "sets op_id/k and job_id/source_guid".into(),
        ));
    }
    let guid = if imported {
        let job_id = raw
            .job_id
            .ok_or_else(|| input_problem(index, "missing job_id".into()))?;
        let source_guid = raw
            .source_guid
            .ok_or_else(|| input_problem(index, "missing source_guid".into()))?;
        BatchGuid::Specified(AddNoteGuid::Imported {
            job_id,
            source_guid,
        })
    } else if local {
        BatchGuid::Specified(AddNoteGuid::Local {
            op_id: raw.op_id,
            k: raw.k,
        })
    } else {
        BatchGuid::Omitted
    };
    Ok(BatchNote {
        fields: raw.fields,
        tags: raw.tags,
        notetype: raw.notetype,
        deck_name: raw.deck_name,
        guid,
    })
}

fn resolve_batch_guid(
    index: usize,
    guid: &BatchGuid,
    command_op: &Option<String>,
    auto_op: &mut Option<String>,
    next_k: &mut Option<u32>,
    used_auto: &mut bool,
    reported_op: &mut Option<String>,
) -> Result<AddedNote, ToolFailure> {
    match guid {
        BatchGuid::Omitted => {
            let op_id = auto_op.get_or_insert_with(new_op_id).clone();
            let k = next_k.ok_or_else(|| ToolFailure::message("k overflowed u32"))?;
            *next_k = k.checked_add(1);
            *used_auto = true;
            *reported_op = Some(op_id.clone());
            Ok(AddedNote::Local { op_id, k })
        }
        BatchGuid::Specified(AddNoteGuid::Local { op_id: None, k }) => {
            let Some(op_id) = command_op.clone() else {
                return Err(input_problem(index, "k without op_id needs --op-id".into()));
            };
            *reported_op = Some(op_id.clone());
            Ok(AddedNote::Local {
                op_id,
                k: k.unwrap_or(0),
            })
        }
        BatchGuid::Specified(specified) => Ok(resolve_added(specified)),
    }
}

/// Stores a notetype on the note only when it is not the deck's notetype.
fn stored_notetype(
    deck: &DeckFile,
    requested: Option<String>,
    location: &str,
) -> Result<Option<String>, ToolFailure> {
    let Some(name) = requested else {
        return Ok(None);
    };
    require_seed_notetype(&name, &format!("{location}.notetype"))?;
    if seed::canonical_notetype(&name) == seed::canonical_notetype(deck.notetype_name()) {
        return Ok(None);
    }
    Ok(Some(name))
}

fn require_seed_notetype(name: &str, location: &str) -> Result<(), ToolFailure> {
    if seed::is_seed_notetype(name) {
        return Ok(());
    }
    Err(ToolFailure::problems(vec![notetype_unknown(
        location, name,
    )]))
}

fn checked_write(
    dest: &Path,
    text: &str,
    deck: &DeckFile,
    derived: &[DerivedNote],
) -> Result<(), ToolFailure> {
    let _checked = check_deck(media_base_of(dest), deck, derived)?;
    fs::write(dest, text)
        .map_err(|err| ToolFailure::message(format!("write {}: {err}", dest.display())))
}

/// The notetype, field-count, cloze, and media gates shared by validate,
/// export, add-note, and add-notes. The session stays open so export can
/// add the same notes without importing the seed twice.
fn check_deck(
    media_base: &Path,
    deck: &DeckFile,
    derived: &[DerivedNote],
) -> Result<((tempfile::TempDir, Session), Option<PathBuf>), ToolFailure> {
    let media = require_media(media_base, deck)?;
    let opened = open_seeded()?;
    match opened.1.check_note_fields(derived) {
        Ok(()) => {}
        Err(FieldCheckError::Backend(message)) => return Err(ToolFailure::message(message)),
        Err(FieldCheckError::Counts(mismatches)) => {
            return Err(ToolFailure::problems(
                mismatches
                    .into_iter()
                    .map(|mismatch| Problem {
                        code: FIELD_COUNT.into(),
                        location: mismatch.location.clone(),
                        message: format!(
                            "{} has {} fields and the notetype has {}",
                            mismatch.location, mismatch.found, mismatch.expected
                        ),
                    })
                    .collect(),
            ));
        }
    }
    check_cloze(derived)?;
    check_media_refs(media.as_deref(), derived)?;
    Ok((opened, media))
}

/// `notes[base + i]` in an add-notes failure is the input item `input[i]`.
fn remap_added_locations(problems: Vec<Problem>, base: usize) -> Vec<Problem> {
    problems
        .into_iter()
        .map(|problem| Problem {
            code: problem.code,
            location: remap_note_ref(&problem.location, base),
            message: remap_note_ref(&problem.message, base),
        })
        .collect()
}

fn remap_note_ref(text: &str, base: usize) -> String {
    let mut out = String::new();
    let mut rest = text;
    while let Some(start) = rest.find("notes[") {
        out.push_str(&rest[..start]);
        let after = &rest[start + "notes[".len()..];
        let Some(end) = after.find(']') else {
            out.push_str(&rest[start..]);
            return out;
        };
        let index_text = &after[..end];
        if let Ok(index) = index_text.parse::<usize>() {
            if index >= base {
                out.push_str(&format!("input[{}]", index - base));
                rest = &after[end + 1..];
                continue;
            }
        }
        out.push_str(&rest[start..start + "notes[".len() + end + 1]);
        rest = &after[end + 1..];
    }
    out.push_str(rest);
    out
}

fn check_cloze(notes: &[DerivedNote]) -> Result<(), ToolFailure> {
    let mut problems = Vec::new();
    for note in notes {
        if !seed::is_cloze_notetype(&note.notetype) {
            continue;
        }
        let field = note.fields.first().map(String::as_str).unwrap_or("");
        if deck::has_valid_cloze(field) {
            continue;
        }
        let note_at = note
            .location
            .strip_suffix(".guid")
            .unwrap_or(note.location.as_str());
        problems.push(Problem {
            code: CLOZE_MISSING.into(),
            location: format!("{note_at}.fields[0]"),
            message: "no cloze deletion; Hatto Cloze needs {{c1::...}} in the first field".into(),
        });
    }
    if problems.is_empty() {
        Ok(())
    } else {
        Err(ToolFailure::problems(problems))
    }
}

fn check_media_refs(media_dir: Option<&Path>, notes: &[DerivedNote]) -> Result<(), ToolFailure> {
    let mut problems = Vec::new();
    for note in notes {
        let note_at = note
            .location
            .strip_suffix(".guid")
            .unwrap_or(note.location.as_str());
        for (index, field) in note.fields.iter().enumerate() {
            for name in deck::media_references(field) {
                let location = format!("{note_at}.fields[{index}]");
                let Some(dir) = media_dir else {
                    problems.push(Problem {
                        code: MEDIA_MISSING.into(),
                        location,
                        message: format!("media file missing: {name} (media_dir is not set)"),
                    });
                    continue;
                };
                if !local_media_file(dir, &name).is_some_and(|path| path.is_file()) {
                    problems.push(Problem {
                        code: MEDIA_MISSING.into(),
                        location,
                        message: format!("media file missing: {name}"),
                    });
                }
            }
        }
    }
    if problems.is_empty() {
        Ok(())
    } else {
        Err(ToolFailure::problems(problems))
    }
}

fn local_media_file(dir: &Path, name: &str) -> Option<PathBuf> {
    if name.is_empty() {
        return None;
    }
    let path = Path::new(name);
    if path.is_absolute() {
        return None;
    }
    if path.components().any(|component| {
        matches!(
            component,
            Component::ParentDir | Component::RootDir | Component::Prefix(_)
        )
    }) {
        return None;
    }
    Some(dir.join(path))
}

fn ensure_decks(
    session: &Session,
    root: &str,
    notes: &[DerivedNote],
) -> Result<HashMap<String, i64>, ToolFailure> {
    let mut names: Vec<&str> = notes.iter().map(|note| note.deck_name.as_str()).collect();
    names.push(root);
    names.sort_by_key(|name| (name.matches("::").count(), *name));
    names.dedup();
    let mut ids = HashMap::new();
    for name in names {
        let id = session.add_deck(name).map_err(ToolFailure::message)?;
        ids.insert(name.to_string(), id);
    }
    Ok(ids)
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

fn read_deck_file(deck_path: &Path) -> Result<String, ToolFailure> {
    fs::read_to_string(deck_path)
        .map_err(|err| ToolFailure::message(format!("read {}: {err}", deck_path.display())))
}

fn load_text(text: &str) -> Result<(DeckFile, Vec<DerivedNote>), ToolFailure> {
    let deck = parse_deck(text).map_err(|problem| ToolFailure::problems(vec![problem]))?;
    let derived = derive_notes(&deck).map_err(ToolFailure::problems)?;
    Ok((deck, derived))
}

fn media_base_of(deck_path: &Path) -> &Path {
    deck_path
        .parent()
        .filter(|path| !path.as_os_str().is_empty())
        .unwrap_or(Path::new("."))
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

/// Opens the temporary collection, loads the seed, and deletes the seed notes.
/// A deck that sets `notetype_legacy` never reaches this: [parse_deck] rejects it first.
fn open_seeded() -> Result<(tempfile::TempDir, Session), ToolFailure> {
    let tmp = tempfile::TempDir::new().map_err(|err| ToolFailure::message(err.to_string()))?;
    let session = Session::open(tmp.path()).map_err(ToolFailure::message)?;
    session
        .load_seed(seed::SEED)
        .map_err(ToolFailure::message)?;
    Ok((tmp, session))
}

/// `media_dir`, when set, must exist. A relative path is joined to `media_base`.
/// Files inside it are copied as-is. There is no type, magic-byte, or size check.
fn require_media(media_base: &Path, deck: &DeckFile) -> Result<Option<PathBuf>, ToolFailure> {
    let Some(raw) = deck.media_dir.as_deref() else {
        return Ok(None);
    };
    let path = PathBuf::from(raw);
    let dir = if path.is_absolute() {
        path
    } else {
        media_base.join(path)
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
    use hatto_card_contract::{is_guid_format, local_note_guid, normalize_import_guid, parse_uuid};

    fn bare_skeleton() -> Value {
        let mut value = skeleton();
        value.as_object_mut().unwrap().remove("media_dir");
        // The sample note references dot.png. These tests are not about media.
        value["notes"][0]["fields"][0] = json!("front");
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
            deck_name: None,
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
            deck_name: None,
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
        let expect = normalize_import_guid(source).unwrap();
        assert_eq!(expect, "b5c01858-bc45-5ce7-9d27-8ee126feb56b");
        assert_eq!(last_guid(&added), expect);
        assert_eq!(added["source_guid"], source);
        let note = read_deck(&path)["notes"][3].clone();
        assert_eq!(note["source_guid"], source);
        assert_eq!(note["job_id"], job_id);
        assert!(note.get("op_id").is_none());
        assert!(note.get("k").is_none());

        let other_job = add_note_path(
            &path,
            None,
            &imported("aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee", source),
        )
        .unwrap_err();
        assert!(other_job
            .errors
            .iter()
            .any(|error| error.code == "NOTE_GUID_DUPLICATE"));
        assert_eq!(read_deck(&path)["notes"].as_array().unwrap().len(), 4);

        let ignored = add_note_path(&path, None, &imported("not-a-uuid", "oxr*zK@INR")).unwrap();
        assert_eq!(last_guid(&ignored), "c15b93d8-6483-5c3c-b94f-1061d53fda92");
        assert_eq!(read_deck(&path)["notes"][4]["job_id"], "not-a-uuid");
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
        assert!(copy.get("notetype_legacy").is_none());
        assert_eq!(copy["extra"], "keep");
        let note = &copy["notes"][3];
        assert_eq!(note["tags"], json!(["one", "two"]));
        assert_eq!(note["k"], 0);
        assert_eq!(copy["notes"].as_array().unwrap().len(), 4);
    }

    #[test]
    fn empty_notes_are_still_rejected_before_the_notetype_gate() {
        let root = tempfile::tempdir().unwrap();
        let mut deck = bare_skeleton();
        deck["notes"] = json!([]);
        let path = write_deck(root.path(), &deck);
        let err = validate_path(&path).unwrap_err();
        assert!(err
            .errors
            .iter()
            .any(|error| { error.location == "notes" && error.message == "notes is empty" }));
        assert!(err.message.is_none());
        let err = export_path(&path, &root.path().join("out.apkg")).unwrap_err();
        assert!(err
            .errors
            .iter()
            .any(|error| error.message == "notes is empty"));
        assert!(!root.path().join("out.apkg").exists());
    }

    #[test]
    fn notetype_legacy_is_rejected_by_validate_export_and_add_note() {
        let root = tempfile::tempdir().unwrap();
        let cases = [
            json!(null),
            json!({"id": 0, "name": "Basic"}),
            json!({"id": 1, "name": "Basic"}),
            json!({"name": "Basic"}),
        ];
        for legacy in cases {
            let mut deck = bare_skeleton();
            deck.as_object_mut().unwrap().remove("notetype");
            deck["notetype_legacy"] = legacy;
            let path = write_deck(root.path(), &deck);
            let before = fs::read(&path).unwrap();
            let apkg = root.path().join("out.apkg");
            let failures = [
                validate_path(&path).unwrap_err(),
                export_path(&path, &apkg).unwrap_err(),
                add_note_path(&path, None, &local(None, None)).unwrap_err(),
            ];
            for err in &failures {
                assert!(err.message.is_none(), "{err:?}");
                assert_eq!(err.errors.len(), 1, "{err:?}");
                assert_eq!(err.errors[0].code, "NOTETYPE_LEGACY");
                assert_eq!(err.errors[0].location, "notetype_legacy");
                assert_eq!(err.errors[0].message, "notetype_legacy is not supported");
            }
            assert_eq!(fs::read(&path).unwrap(), before);
            assert!(!apkg.exists());
        }
    }

    #[test]
    fn field_count_mismatch_fails_validate_and_export() {
        let root = tempfile::tempdir().unwrap();
        let mut deck = bare_skeleton();
        deck["notes"] = json!([{
            "k": 0,
            "fields": ["one", "two", "three"]
        }]);
        let path = write_deck(root.path(), &deck);
        let message = "notes[0].guid has 3 fields and the notetype has 2";
        let err = validate_path(&path).unwrap_err();
        assert_eq!(err.errors[0].code, FIELD_COUNT);
        assert_eq!(err.errors[0].message, message);
        let err = export_path(&path, &root.path().join("out.apkg")).unwrap_err();
        assert_eq!(err.errors[0].code, FIELD_COUNT);
        assert_eq!(err.errors[0].message, message);
        assert!(!root.path().join("out.apkg").exists());
    }

    #[test]
    fn unknown_notetype_fails_validate_and_export_the_same_way() {
        let root = tempfile::tempdir().unwrap();
        let mut deck = bare_skeleton();
        deck["notetype"] = json!("Nope");
        let path = write_deck(root.path(), &deck);
        let validate = validate_path(&path).unwrap_err();
        let export = export_path(&path, &root.path().join("out.apkg")).unwrap_err();
        assert_eq!(validate.errors, export.errors);
        assert_eq!(validate.errors[0].code, "NOTETYPE_UNKNOWN");
        assert_eq!(validate.errors[0].location, "notetype");
        assert!(validate.errors[0].message.contains("Nope"), "{validate:?}");
        assert!(
            validate.errors[0].message.contains("Hatto Basic"),
            "{validate:?}"
        );
        assert!(
            !validate.errors[0].message.contains("Check Database"),
            "{validate:?}"
        );
        assert!(!root.path().join("out.apkg").exists());
    }

    fn assert_uuid_v4(text: &str) {
        assert!(is_guid_format(text), "{text}");
        assert_eq!(parse_uuid(text).unwrap().get_version_num(), 4, "{text}");
    }

    /// F4: two decks from `new` must not share the skeleton's constant ids,
    /// or the k:0 note guid those ids always produced.
    #[test]
    fn new_decks_get_fresh_ids_and_a_chosen_name() {
        let root = tempfile::tempdir().unwrap();
        let alpha_path = root.path().join("alpha.json");
        let beta_path = root.path().join("beta.json");
        let alpha = write_skeleton(Some(&alpha_path), Some("Parent::Child")).unwrap();
        let beta = write_skeleton(Some(&beta_path), None).unwrap();
        assert_eq!(alpha["deck"]["deck_name"], "Parent::Child");
        assert_eq!(beta["deck"]["deck_name"], "Example");
        assert_eq!(alpha["deck"]["notes"].as_array().unwrap().len(), 3);

        let alpha_job = alpha["deck"]["job_id"].as_str().unwrap();
        let alpha_op = alpha["deck"]["op_id"].as_str().unwrap();
        let beta_job = beta["deck"]["job_id"].as_str().unwrap();
        let beta_op = beta["deck"]["op_id"].as_str().unwrap();
        assert_uuid_v4(alpha_job);
        assert_uuid_v4(alpha_op);
        assert_ne!(alpha_job, beta_job);
        assert_ne!(alpha_op, beta_op);
        assert_ne!(alpha_job, "01234567-89ab-4cde-8fab-0123456789ab");
        assert_ne!(alpha_op, "fedcba98-7654-4210-8fed-cba987654321");

        let alpha_notes =
            derive_notes(&parse_deck(&fs::read_to_string(&alpha_path).unwrap()).unwrap()).unwrap();
        let beta_notes =
            derive_notes(&parse_deck(&fs::read_to_string(&beta_path).unwrap()).unwrap()).unwrap();
        let local_zero = |notes: &[DerivedNote]| {
            notes
                .iter()
                .find(|note| note.fields.as_slice() == ["local zero", "back"])
                .unwrap()
                .guid
                .clone()
        };
        let alpha_zero = local_zero(&alpha_notes);
        let beta_zero = local_zero(&beta_notes);
        assert_ne!(alpha_zero, beta_zero);
        assert_ne!(alpha_zero, "74a16fcd-b6db-5db5-be79-787c72943de7");
        // Imported notes use normalize_import_guid. A fresh job_id does not
        // change that guid. Local notes still follow the fresh op_id.
        let source = alpha["deck"]["notes"][0]["source_guid"].as_str().unwrap();
        assert_eq!(alpha_notes[0].guid, beta_notes[0].guid);
        assert_eq!(alpha_notes[0].guid, normalize_import_guid(source).unwrap());
        assert_ne!(alpha_notes[2].guid, beta_notes[2].guid);

        let on_disk = read_deck(&alpha_path);
        assert_eq!(on_disk["deck_name"], "Parent::Child");
        assert_eq!(on_disk["job_id"], alpha_job);
        let empty_name = write_skeleton(None, Some("")).unwrap_err();
        assert_eq!(empty_name.message.as_deref(), Some("deck_name is empty"));
    }

    /// The skeleton references dot.png. `new` must create it, and must not
    /// replace a file the caller already put there.
    #[test]
    fn new_writes_missing_media_and_then_validates() {
        let root = tempfile::tempdir().unwrap();
        let fresh = root.path().join("fresh");
        fs::create_dir(&fresh).unwrap();
        let deck = fresh.join("deck.json");
        write_skeleton(Some(&deck), Some("Fresh")).unwrap();
        let png = fresh.join("media").join("dot.png");
        assert_eq!(fs::read(&png).unwrap(), EXAMPLE_DOT_PNG);
        let checked = validate_path(&deck).unwrap();
        assert_eq!(checked["ok"], true);
        assert_eq!(checked["notes"].as_array().unwrap().len(), 3);

        let kept = root.path().join("kept");
        fs::create_dir_all(kept.join("media")).unwrap();
        let sentinel = kept.join("media").join("dot.png");
        fs::write(&sentinel, b"already-there").unwrap();
        let kept_deck = kept.join("deck.json");
        write_skeleton(Some(&kept_deck), None).unwrap();
        assert_eq!(fs::read(&sentinel).unwrap(), b"already-there");
        assert_eq!(validate_path(&kept_deck).unwrap()["ok"], true);
    }

    #[test]
    fn empty_deck_is_still_rejected() {
        let root = tempfile::tempdir().unwrap();
        let mut value = skeleton();
        value["notes"] = json!([]);
        value.as_object_mut().unwrap().remove("media_dir");
        let path = write_deck(root.path(), &value);
        let err = validate_path(&path).unwrap_err();
        assert!(
            err.errors
                .iter()
                .any(|error| error.location == "notes" && error.message == "notes is empty"),
            "{err:?}"
        );
    }

    #[test]
    fn empty_new_deck_uses_hatto_basic_and_rejects_unknown_notetypes() {
        let empty = write_new_deck(
            None,
            NewDeck {
                deck_name: Some("Root"),
                notetype: None,
                empty: true,
            },
        )
        .unwrap();
        assert_eq!(empty["deck"]["notes"], json!([]));
        assert_eq!(empty["deck"]["notetype"], "Hatto Basic");
        assert_eq!(empty["deck"]["deck_name"], "Root");
        assert_uuid_v4(empty["deck"]["op_id"].as_str().unwrap());

        let err = write_new_deck(
            None,
            NewDeck {
                deck_name: None,
                notetype: Some("Nope"),
                empty: true,
            },
        )
        .unwrap_err();
        assert_eq!(err.errors[0].code, "NOTETYPE_UNKNOWN");
        assert_eq!(err.errors[0].location, "--notetype");
        assert!(err.errors[0].message.contains("Nope"), "{err:?}");

        let named = write_new_deck(
            None,
            NewDeck {
                deck_name: None,
                notetype: Some("Cloze"),
                empty: false,
            },
        )
        .unwrap();
        assert_eq!(named["deck"]["notetype"], "Cloze");
        assert_eq!(named["deck"]["notes"].as_array().unwrap().len(), 3);
    }

    #[test]
    fn add_note_checks_fields_cloze_media_and_subdeck_before_writing() {
        let root = tempfile::tempdir().unwrap();
        let path = write_deck(root.path(), &bare_skeleton());
        let before = fs::read(&path).unwrap();

        let mut short = local(None, None);
        short.fields = vec!["only".into()];
        let err = add_note_path(&path, None, &short).unwrap_err();
        assert_eq!(err.errors[0].code, "FIELD_COUNT");
        assert!(err.errors[0].message.contains("has 1 fields"), "{err:?}");
        assert_eq!(fs::read(&path).unwrap(), before);

        let mut foreign = local(None, None);
        foreign.deck_name = Some("Other".into());
        let err = add_note_path(&path, None, &foreign).unwrap_err();
        assert!(
            err.errors
                .iter()
                .any(|error| error.message.contains("not under")),
            "{err:?}"
        );
        assert_eq!(fs::read(&path).unwrap(), before);

        let mut child = local(Some("aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"), Some(2));
        child.deck_name = Some("Example::Sub".into());
        let added = add_note_path(&path, None, &child).unwrap();
        assert_eq!(added["k"], 2);
        let note = read_deck(&path)["notes"][3].clone();
        assert_eq!(note["deck_name"], "Example::Sub");
        assert!(note.get("notetype").is_none());

        let cloze_dir = root.path().join("cloze");
        fs::create_dir(&cloze_dir).unwrap();
        let mut cloze = bare_skeleton();
        cloze["notetype"] = json!("Hatto Cloze");
        cloze["notes"] = json!([{ "k": 0, "fields": ["{{c1::a}}", "extra"] }]);
        let cloze_path = write_deck(&cloze_dir, &cloze);
        let cloze_before = fs::read(&cloze_path).unwrap();
        let mut bad = local(None, Some(1));
        bad.notetype = "Cloze".into();
        bad.fields = vec!["no deletion".into(), "extra".into()];
        let err = add_note_path(&cloze_path, None, &bad).unwrap_err();
        assert!(
            err.errors
                .iter()
                .any(|error| error.message.contains("no cloze deletion")),
            "{err:?}"
        );
        assert_eq!(fs::read(&cloze_path).unwrap(), cloze_before);
        assert_eq!(validate_path(&cloze_path).unwrap()["ok"], true);

        let media_dir = root.path().join("refs");
        fs::create_dir(&media_dir).unwrap();
        let mut media = bare_skeleton();
        media["notes"] = json!([{
            "k": 0,
            "fields": ["see <img src=\"missing.png\"> and [sound:beep.mp3]", "b"]
        }]);
        let media_path = write_deck(&media_dir, &media);
        let err = validate_path(&media_path).unwrap_err();
        let messages: Vec<_> = err
            .errors
            .iter()
            .map(|error| format!("{} {}", error.location, error.message))
            .collect();
        assert!(
            messages.iter().any(|message| {
                message.contains("notes[0].fields[0]")
                    && message.contains("missing.png")
                    && message.contains("media_dir is not set")
            }),
            "{messages:?}"
        );
        assert!(
            messages.iter().any(|message| message.contains("beep.mp3")),
            "{messages:?}"
        );

        let remote_dir = root.path().join("remote");
        fs::create_dir(&remote_dir).unwrap();
        let mut remote = bare_skeleton();
        remote["notes"] = json!([{
            "k": 0,
            "fields": ["<img src=\"https://example.com/a.png\">", "b"]
        }]);
        let remote_path = write_deck(&remote_dir, &remote);
        assert_eq!(validate_path(&remote_path).unwrap()["ok"], true);
    }

    #[test]
    fn add_notes_is_atomic_and_numbers_omitted_items_from_start_k() {
        let parsed = parse_notes_input(
            "\n{\"fields\":[\"a\",\"b\"],\"tags\":[\"t\"]}\n\n{\"fields\":[\"c\",\"d\"],\"job_id\":\"j\",\"source_guid\":\"src\"}\n",
        )
        .unwrap();
        assert!(matches!(parsed[0].guid, BatchGuid::Omitted));
        assert!(matches!(
            parsed[1].guid,
            BatchGuid::Specified(AddNoteGuid::Imported { .. })
        ));
        let array = parse_notes_input(r#"[{"fields":["a","b"],"k":1}]"#).unwrap();
        assert!(matches!(
            array[0].guid,
            BatchGuid::Specified(AddNoteGuid::Local { k: Some(1), .. })
        ));
        let both =
            parse_notes_input(r#"[{"fields":["a","b"],"k":1,"source_guid":"x"}]"#).unwrap_err();
        assert_eq!(both.errors[0].location, "input[0]");
        assert!(both.errors[0]
            .message
            .contains("sets op_id/k and job_id/source_guid"));
        let typo =
            parse_notes_input(r#"[{"fields":["a","b"],"tag":["x"],"deckname":"Example::Sub"}]"#)
                .unwrap_err();
        assert_eq!(typo.errors[0].location, "input[0]");
        assert!(typo.errors[0].message.contains("unknown field"), "{typo:?}");

        let root = tempfile::tempdir().unwrap();
        let path = write_deck(root.path(), &bare_skeleton());
        let before = fs::read(&path).unwrap();
        let op = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee";
        let bad = AddNotesRequest {
            notetype: None,
            op_id: Some(op.into()),
            start_k: 3,
            notes: vec![
                BatchNote {
                    fields: vec!["one".into(), "two".into()],
                    tags: vec!["t".into()],
                    notetype: None,
                    deck_name: Some("Example::Sub".into()),
                    guid: BatchGuid::Omitted,
                },
                BatchNote {
                    fields: vec!["no cloze".into(), "extra".into()],
                    tags: Vec::new(),
                    notetype: Some("Cloze".into()),
                    deck_name: None,
                    guid: BatchGuid::Omitted,
                },
            ],
        };
        let err = add_notes_path(&path, None, &bad).unwrap_err();
        assert!(
            err.errors
                .iter()
                .any(|error| error.message.contains("no cloze deletion")),
            "{err:?}"
        );
        assert_eq!(fs::read(&path).unwrap(), before);

        let request = AddNotesRequest {
            notetype: Some("Basic".into()),
            op_id: Some(op.into()),
            start_k: 3,
            notes: vec![
                BatchNote {
                    fields: vec!["one".into(), "two".into()],
                    tags: vec!["t".into()],
                    notetype: None,
                    deck_name: Some("Example::Sub".into()),
                    guid: BatchGuid::Omitted,
                },
                BatchNote {
                    fields: vec!["keep".into(), "me".into()],
                    tags: Vec::new(),
                    notetype: None,
                    deck_name: None,
                    guid: BatchGuid::Specified(AddNoteGuid::Local {
                        op_id: Some(op.into()),
                        k: Some(9),
                    }),
                },
                BatchNote {
                    fields: vec!["A {{c1::hole}}".into(), "extra".into()],
                    tags: vec!["cloze".into()],
                    notetype: Some("Hatto Cloze".into()),
                    deck_name: Some("Example".into()),
                    guid: BatchGuid::Omitted,
                },
            ],
        };
        let added = add_notes_path(&path, None, &request).unwrap();
        assert_eq!(added["op_id"], op);
        assert_eq!(added["start_k"], 3);
        assert_eq!(added["added"], 3);
        assert_eq!(added["notes"].as_array().unwrap().len(), 6);
        let file = read_deck(&path);
        let notes = file["notes"].as_array().unwrap();
        assert_eq!(notes[3]["k"], 3);
        assert_eq!(notes[3]["deck_name"], "Example::Sub");
        assert!(notes[3].get("notetype").is_none());
        assert_eq!(notes[4]["k"], 9);
        assert_eq!(notes[5]["k"], 4);
        assert_eq!(notes[5]["notetype"], "Hatto Cloze");
        let op_id = parse_uuid(op).unwrap();
        assert_eq!(
            added["notes"][3]["guid"],
            NoteGuid::from_uuid(local_note_guid(op_id, 3)).into_string()
        );
        assert_eq!(
            added["notes"][5]["guid"],
            NoteGuid::from_uuid(local_note_guid(op_id, 4)).into_string()
        );
        assert_eq!(validate_path(&path).unwrap()["ok"], true);
    }

    #[test]
    fn image_occlusion_is_rejected_on_the_deck_and_on_a_note() {
        let root = tempfile::tempdir().unwrap();
        let mut deck = bare_skeleton();
        deck["notetype"] = json!("Image Occlusion");
        let path = write_deck(root.path(), &deck);
        let before = fs::read(&path).unwrap();
        for err in [
            validate_path(&path).unwrap_err(),
            export_path(&path, &root.path().join("out.apkg")).unwrap_err(),
            add_note_path(&path, None, &local(None, None)).unwrap_err(),
        ] {
            assert_eq!(err.errors[0].code, "NOTETYPE_UNKNOWN", "{err:?}");
            assert_eq!(err.errors[0].location, "notetype");
            assert!(err.errors[0].message.contains("Image Occlusion"), "{err:?}");
            assert!(err.errors[0].message.contains("Hatto Cloze"), "{err:?}");
            assert!(!err.errors[0].message.contains("Check Database"), "{err:?}");
        }
        assert_eq!(fs::read(&path).unwrap(), before);
        assert!(!root.path().join("out.apkg").exists());

        let basic = write_deck(root.path(), &bare_skeleton());
        let basic_before = fs::read(&basic).unwrap();
        let request = AddNotesRequest {
            notetype: None,
            op_id: None,
            start_k: 0,
            notes: vec![BatchNote {
                fields: vec!["a".into(), "b".into(), "c".into(), "d".into(), "e".into()],
                tags: Vec::new(),
                notetype: Some("Image Occlusion".into()),
                deck_name: None,
                guid: BatchGuid::Omitted,
            }],
        };
        let err = add_notes_path(&basic, None, &request).unwrap_err();
        assert_eq!(err.errors[0].code, "NOTETYPE_UNKNOWN");
        assert_eq!(err.errors[0].location, "input[0].notetype");
        assert!(err.errors[0].message.contains("Image Occlusion"));
        assert!(!err.errors[0].message.contains("Check Database"));
        assert_eq!(fs::read(&basic).unwrap(), basic_before);
    }

    #[test]
    fn k_only_uses_the_call_op_id_and_rejects_without_it() {
        let root = tempfile::tempdir().unwrap();
        let op = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee";
        let notes = parse_notes_input(r#"[{"fields":["k1","y"],"k":50}]"#).unwrap();
        let request = AddNotesRequest {
            notetype: None,
            op_id: Some(op.into()),
            start_k: 0,
            notes: notes.clone(),
        };
        let first_path = write_deck(root.path(), &bare_skeleton());
        let first = add_notes_path(&first_path, None, &request).unwrap();
        let second_dir = root.path().join("second");
        fs::create_dir(&second_dir).unwrap();
        let second_path = write_deck(&second_dir, &bare_skeleton());
        let second = add_notes_path(&second_path, None, &request).unwrap();
        let expect =
            NoteGuid::from_uuid(local_note_guid(parse_uuid(op).unwrap(), 50)).into_string();
        assert_eq!(first["op_id"], op);
        assert_eq!(second["op_id"], op);
        assert_eq!(first["notes"][3]["guid"], expect);
        assert_eq!(second["notes"][3]["guid"], expect);
        assert_eq!(read_deck(&first_path)["notes"][3]["op_id"], op);
        assert_eq!(read_deck(&first_path)["notes"][3]["k"], 50);

        let bare = root.path().join("bare");
        fs::create_dir(&bare).unwrap();
        let bare_path = write_deck(&bare, &bare_skeleton());
        let before = fs::read(&bare_path).unwrap();
        let missing = AddNotesRequest {
            op_id: None,
            ..request
        };
        let err = add_notes_path(&bare_path, None, &missing).unwrap_err();
        assert_eq!(err.errors[0].location, "input[0]");
        assert!(err.errors[0].message.contains("needs --op-id"), "{err:?}");
        assert_eq!(fs::read(&bare_path).unwrap(), before);
    }

    #[test]
    fn add_notes_field_errors_use_the_input_index() {
        let root = tempfile::tempdir().unwrap();
        let path = write_deck(root.path(), &bare_skeleton());
        let before = fs::read(&path).unwrap();
        let request = AddNotesRequest {
            notetype: None,
            op_id: Some("aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee".into()),
            start_k: 0,
            notes: vec![
                BatchNote {
                    fields: vec!["ok".into(), "ok".into()],
                    tags: Vec::new(),
                    notetype: None,
                    deck_name: None,
                    guid: BatchGuid::Omitted,
                },
                BatchNote {
                    fields: vec!["only".into()],
                    tags: Vec::new(),
                    notetype: None,
                    deck_name: None,
                    guid: BatchGuid::Omitted,
                },
            ],
        };
        let err = add_notes_path(&path, None, &request).unwrap_err();
        assert_eq!(err.errors[0].code, FIELD_COUNT);
        assert_eq!(err.errors[0].location, "input[1].guid");
        assert!(
            err.errors[0]
                .message
                .starts_with("input[1].guid has 1 fields"),
            "{err:?}"
        );
        assert_eq!(fs::read(&path).unwrap(), before);
    }
}
