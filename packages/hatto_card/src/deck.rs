// SPDX-FileCopyrightText: 2026 Hatto Social contributors
//
// SPDX-License-Identifier: AGPL-3.0-or-later

//! Provisional card-file mapping.
//!
//! No document defines this JSON. It is the thinnest map onto Anki: a deck
//! name, a notetype name or a legacy notetype object, notes that carry either
//! `source_guid` (imported) or `op_id`/`k` (local), fields, tags, and an
//! optional media directory. See the package README.

use hatto_card_contract::{
    imported_note_guid, is_guid_format, local_note_guid, parse_uuid, validate_deck_file,
    CardErrorCode, DeckNote, EmptySourceGuid, NoteGuid, Uuid,
};
use serde::Deserialize;
use serde_json::{json, Value};

/// One validation or derivation failure.
///
/// `code` is a contract id (`GUID_FORMAT` or `NOTE_GUID_DUPLICATE`) when the
/// failure is one of those. Other input problems leave `code` empty and set
/// `message` only, so this CLI does not invent a third contract code.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Problem {
    pub code: String,
    pub location: String,
    pub message: String,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct DerivedNote {
    pub location: String,
    pub guid: String,
    pub fields: Vec<String>,
    pub tags: Vec<String>,
}

#[derive(Clone, Debug, Deserialize)]
pub struct DeckFile {
    pub deck_name: String,
    #[serde(default)]
    pub job_id: Option<String>,
    #[serde(default)]
    pub op_id: Option<String>,
    /// Stock notetype name. Ignored when [Self::notetype_legacy] is set.
    /// Defaults to `Basic` when both are absent.
    #[serde(default)]
    pub notetype: Option<String>,
    /// Anki legacy notetype JSON passed to `add_notetype_legacy`.
    #[serde(default)]
    pub notetype_legacy: Option<Value>,
    /// Directory of media files, relative to the deck file unless absolute.
    #[serde(default)]
    pub media_dir: Option<String>,
    pub notes: Vec<InputNote>,
}

#[derive(Clone, Debug, Deserialize)]
pub struct InputNote {
    #[serde(default)]
    pub source_guid: Option<String>,
    #[serde(default)]
    pub job_id: Option<String>,
    #[serde(default)]
    pub op_id: Option<String>,
    #[serde(default)]
    pub k: Option<u32>,
    pub fields: Vec<String>,
    #[serde(default)]
    pub tags: Vec<String>,
}

impl DeckFile {
    pub fn notetype_name(&self) -> &str {
        self.notetype.as_deref().unwrap_or("Basic")
    }
}

/// Fixed example shape shared with `examples/with-media/deck.json`.
///
/// `hatto-card new` starts from this and then replaces `job_id` and `op_id`
/// with new UUIDv4 values. These constants stay so the checked-in example and
/// the golden guid tests keep one known deck. `source_guid` includes quotes,
/// a backtick, a backslash, and Hangul so the roundtrip keeps those bytes out
/// of any normalization. `k` is 0 and the largest `u32`.
pub fn skeleton() -> Value {
    let source_guid = concat!("'\"`", "\\", "한글");
    json!({
        "deck_name": "Example",
        "job_id": "01234567-89ab-4cde-8fab-0123456789ab",
        "op_id": "fedcba98-7654-4210-8fed-cba987654321",
        "notetype": "Basic",
        "media_dir": "media",
        "notes": [
            {
                "source_guid": source_guid,
                "fields": ["front <img src=\"dot.png\">", "back"],
                "tags": ["example"]
            },
            {
                "k": 0,
                "fields": ["local zero", "back"],
                "tags": ["local"]
            },
            {
                "k": 4294967295u32,
                "fields": ["local max", "back"],
                "tags": ["local", "max"]
            }
        ]
    })
}

pub fn parse_deck(text: &str) -> Result<DeckFile, Problem> {
    serde_json::from_str(text).map_err(|err| Problem {
        code: String::new(),
        location: String::new(),
        message: format!("deck json: {err}"),
    })
}

pub fn derive_notes(deck: &DeckFile) -> Result<Vec<DerivedNote>, Vec<Problem>> {
    if deck.deck_name.is_empty() {
        return Err(vec![Problem {
            code: String::new(),
            location: "deck_name".into(),
            message: "deck_name is empty".into(),
        }]);
    }
    if deck.notes.is_empty() {
        return Err(vec![Problem {
            code: String::new(),
            location: "notes".into(),
            message: "notes is empty".into(),
        }]);
    }
    let mut derived = Vec::new();
    let mut problems = Vec::new();
    for (index, note) in deck.notes.iter().enumerate() {
        let location = format!("notes[{index}]");
        match derive_one(deck, note, &location) {
            Ok(item) => derived.push(item),
            Err(problem) => problems.push(problem),
        }
    }
    let file_notes: Vec<DeckNote<'_>> = derived
        .iter()
        .map(|note| DeckNote {
            guid: note.guid.as_str(),
            location: note.location.as_str(),
        })
        .collect();
    for error in validate_deck_file(&file_notes) {
        problems.push(Problem {
            code: error.code.as_str().to_string(),
            location: error.location,
            message: error.code.as_str().to_string(),
        });
    }
    if problems.is_empty() {
        Ok(derived)
    } else {
        problems.sort_by(|left, right| {
            left.code
                .cmp(&right.code)
                .then_with(|| left.location.cmp(&right.location))
        });
        Err(problems)
    }
}

fn derive_one(deck: &DeckFile, note: &InputNote, location: &str) -> Result<DerivedNote, Problem> {
    let has_source = note.source_guid.is_some();
    let has_k = note.k.is_some();
    if has_source == has_k {
        return Err(Problem {
            code: String::new(),
            location: location.into(),
            message: "set source_guid or k, not both and not neither".into(),
        });
    }
    let guid = if let Some(source) = note.source_guid.as_deref() {
        let job_text = note
            .job_id
            .as_deref()
            .or(deck.job_id.as_deref())
            .ok_or_else(|| Problem {
                code: String::new(),
                location: format!("{location}.job_id"),
                message: "imported note needs job_id".into(),
            })?;
        let job = require_uuid(job_text, &format!("{location}.job_id"))?;
        match imported_note_guid(job, source) {
            Ok(id) => NoteGuid::from(id).into_string(),
            Err(EmptySourceGuid) => {
                return Err(Problem {
                    code: CardErrorCode::GUID_FORMAT.into(),
                    location: format!("{location}.source_guid"),
                    message: "source_guid is empty".into(),
                });
            }
        }
    } else {
        let k = note.k.expect("k is set when source_guid is not");
        let op_text = note
            .op_id
            .as_deref()
            .or(deck.op_id.as_deref())
            .ok_or_else(|| Problem {
                code: String::new(),
                location: format!("{location}.op_id"),
                message: "local note needs op_id".into(),
            })?;
        let op = require_uuid(op_text, &format!("{location}.op_id"))?;
        NoteGuid::from(local_note_guid(op, k)).into_string()
    };
    if note.fields.is_empty() {
        return Err(Problem {
            code: String::new(),
            location: format!("{location}.fields"),
            message: "fields is empty".into(),
        });
    }
    Ok(DerivedNote {
        location: format!("{location}.guid"),
        guid,
        fields: note.fields.clone(),
        tags: note.tags.clone(),
    })
}

fn require_uuid(text: &str, location: &str) -> Result<Uuid, Problem> {
    if parse_uuid(text).is_err() || !is_guid_format(text) {
        return Err(Problem {
            code: CardErrorCode::GUID_FORMAT.into(),
            location: location.into(),
            message: "expected a lowercase hyphenated UUID version 4 or 5".into(),
        });
    }
    parse_uuid(text).map_err(|err| Problem {
        code: CardErrorCode::GUID_FORMAT.into(),
        location: location.into(),
        message: err.to_string(),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn deck(notes: Value) -> DeckFile {
        let mut value = skeleton();
        value["notes"] = notes;
        serde_json::from_value(value).unwrap()
    }

    #[test]
    fn skeleton_derives_three_canonical_guids() {
        let file: DeckFile = serde_json::from_value(skeleton()).unwrap();
        let notes = derive_notes(&file).unwrap();
        assert_eq!(notes.len(), 3);
        assert!(notes.iter().all(|note| is_guid_format(&note.guid)));
        assert_ne!(notes[0].guid, notes[1].guid);
        assert_ne!(notes[1].guid, notes[2].guid);
    }

    #[test]
    fn empty_source_guid_is_guid_format() {
        let file = deck(json!([{
            "source_guid": "",
            "fields": ["a", "b"]
        }]));
        let errors = derive_notes(&file).unwrap_err();
        assert_eq!(errors[0].code, "GUID_FORMAT");
        assert_eq!(errors[0].location, "notes[0].source_guid");
    }

    #[test]
    fn duplicate_source_guids_are_only_inside_this_file() {
        let file = deck(json!([
            {"source_guid": "same", "fields": ["a", "b"]},
            {"source_guid": "same", "fields": ["c", "d"]}
        ]));
        let errors = derive_notes(&file).unwrap_err();
        assert!(errors
            .iter()
            .all(|error| error.code == "NOTE_GUID_DUPLICATE"));
        assert_eq!(errors.len(), 2);
    }

    #[test]
    fn untrimmed_source_guid_differs_from_trimmed() {
        let spaced = deck(json!([{"source_guid": "  same  ", "fields": ["a", "b"]}]));
        let trimmed = deck(json!([{"source_guid": "same", "fields": ["a", "b"]}]));
        let spaced = derive_notes(&spaced).unwrap();
        let trimmed = derive_notes(&trimmed).unwrap();
        assert_ne!(spaced[0].guid, trimmed[0].guid);
    }
}
