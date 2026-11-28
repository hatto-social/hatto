// SPDX-FileCopyrightText: 2026 Hatto Social contributors
//
// SPDX-License-Identifier: AGPL-3.0-or-later

//! Provisional card-file mapping.
//!
//! No document defines this JSON. It is the thinnest map onto Anki: a deck
//! name, a notetype name, notes that carry either `source_guid` (imported,
//! [`normalize_import_guid`]) or `op_id`/`k` (local), fields, tags, and an
//! optional media directory. A note may set its own `notetype` and
//! `deck_name` (the deck root, or `{root}::...`). A `notetype_legacy` key is
//! rejected. See the package README.

use hatto_card_contract::{
    is_guid_format, local_note_guid, normalize_import_guid, parse_uuid, validate_deck_file,
    CardErrorCode, DeckNote, EmptySourceGuid, NoteGuid, Uuid,
};
use serde::Deserialize;
use serde_json::{json, Value};

/// One validation or derivation failure.
///
/// `code` is a contract id (`GUID_FORMAT` or `NOTE_GUID_DUPLICATE`) when the
/// failure is one of those, or [`NOTETYPE_LEGACY`] when the deck sets that
/// removed key. Other input problems leave `code` empty and set `message`
/// only. [`NOTETYPE_LEGACY`] is a CLI code, not a contract id.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Problem {
    pub code: String,
    pub location: String,
    pub message: String,
}

/// A deck JSON key `notetype_legacy` is rejected with this code.
///
/// The key used to be sent to rslib `add_notetype_legacy`, which assigns a
/// new notetype id on every export. Re-importing that package classifies the
/// existing notes as blocked. Built-in notetype names stay on the seed ids.
/// This is a CLI code, not a `hatto_card_contract` id.
pub const NOTETYPE_LEGACY: &str = "NOTETYPE_LEGACY";

/// The notetype is not a seed name (stock or Hatto). CLI code, not a contract id.
pub const NOTETYPE_UNKNOWN: &str = "NOTETYPE_UNKNOWN";

/// A note's field count is not the seed notetype's field count.
pub const FIELD_COUNT: &str = "FIELD_COUNT";

/// A Cloze note's first field has no `{{cN::...}}` deletion.
pub const CLOZE_MISSING: &str = "CLOZE_MISSING";

/// A local media reference is not a file in `media_dir`.
pub const MEDIA_MISSING: &str = "MEDIA_MISSING";

/// A note `deck_name` is empty, has an empty segment, or is outside the root.
pub const DECK_NAME_INVALID: &str = "DECK_NAME_INVALID";

/// `k` was set and `op_id` was not. The guid would not be deterministic.
pub const OP_ID_REQUIRED: &str = "OP_ID_REQUIRED";

/// A batch note object has a key this command does not accept.
pub const UNKNOWN_FIELD: &str = "UNKNOWN_FIELD";

const NOTETYPE_LEGACY_MESSAGE: &str = "notetype_legacy is not supported";

pub(crate) fn notetype_unknown(location: &str, name: &str) -> Problem {
    Problem {
        code: NOTETYPE_UNKNOWN.into(),
        location: location.into(),
        message: format!(
            "notetype \"{name}\" is not a seed notetype; use one of: {}",
            crate::seed::seed_notetype_names()
        ),
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct DerivedNote {
    pub location: String,
    pub guid: String,
    pub fields: Vec<String>,
    pub tags: Vec<String>,
    /// Effective notetype: the note's override, or the deck default.
    pub notetype: String,
    /// Effective deck: the note's override, or the deck's `deck_name`.
    pub deck_name: String,
}

#[derive(Clone, Debug, Deserialize)]
pub struct DeckFile {
    pub deck_name: String,
    /// Accepted so an existing deck file still parses. Not an input to a guid.
    #[serde(default)]
    pub job_id: Option<String>,
    #[serde(default)]
    pub op_id: Option<String>,
    /// Stock notetype name. Defaults to `Basic` when absent.
    #[serde(default)]
    pub notetype: Option<String>,
    /// Directory of media files, relative to the deck file unless absolute.
    #[serde(default)]
    pub media_dir: Option<String>,
    pub notes: Vec<InputNote>,
}

#[derive(Clone, Debug, Deserialize)]
pub struct InputNote {
    #[serde(default)]
    pub source_guid: Option<String>,
    /// Accepted so an existing deck file still parses. Not an input to a guid.
    #[serde(default)]
    pub job_id: Option<String>,
    #[serde(default)]
    pub op_id: Option<String>,
    #[serde(default)]
    pub k: Option<u32>,
    pub fields: Vec<String>,
    #[serde(default)]
    pub tags: Vec<String>,
    /// Overrides the deck's `notetype` for this note. Absent means the deck default.
    #[serde(default)]
    pub notetype: Option<String>,
    /// `deck_name`, or `{deck_name}::...` with no empty segment. Absent means the deck default.
    #[serde(default)]
    pub deck_name: Option<String>,
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
    let value: Value = serde_json::from_str(text).map_err(json_problem)?;
    // Any value, including null and id 0. The key itself is the removed option.
    if value.get("notetype_legacy").is_some() {
        return Err(Problem {
            code: NOTETYPE_LEGACY.into(),
            location: "notetype_legacy".into(),
            message: NOTETYPE_LEGACY_MESSAGE.into(),
        });
    }
    serde_json::from_value(value).map_err(json_problem)
}

fn json_problem(err: serde_json::Error) -> Problem {
    Problem {
        code: String::new(),
        location: String::new(),
        message: format!("deck json: {err}"),
    }
}

pub fn derive_notes(deck: &DeckFile) -> Result<Vec<DerivedNote>, Vec<Problem>> {
    if deck.deck_name.is_empty() {
        return Err(vec![Problem {
            code: String::new(),
            location: "deck_name".into(),
            message: "deck_name is empty".into(),
        }]);
    }
    let mut problems = Vec::new();
    if let Some(name) = deck.notetype.as_deref() {
        if !crate::seed::is_seed_notetype(name) {
            problems.push(notetype_unknown("notetype", name));
        }
    }
    if deck.notes.is_empty() {
        problems.push(Problem {
            code: String::new(),
            location: "notes".into(),
            message: "notes is empty".into(),
        });
        return Err(problems);
    }
    let mut derived = Vec::new();
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
        // `job_id` on the deck or the note stays in the file and is ignored.
        // The guid is `f` (`IMPORT_NS`), which does not take a job.
        let _job_id_accepted_and_ignored = note.job_id.as_deref().or(deck.job_id.as_deref());
        match normalize_import_guid(source) {
            Ok(guid) => guid,
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
    let notetype = match note.notetype.as_deref() {
        Some(name) if !crate::seed::is_seed_notetype(name) => {
            return Err(notetype_unknown(&format!("{location}.notetype"), name));
        }
        Some(name) => name.to_string(),
        None => deck.notetype_name().to_string(),
    };
    let deck_name = resolve_note_deck(&deck.deck_name, note.deck_name.as_deref(), location)?;
    Ok(DerivedNote {
        location: format!("{location}.guid"),
        guid,
        fields: note.fields.clone(),
        tags: note.tags.clone(),
        notetype,
        deck_name,
    })
}

/// A note deck is the root, or `{root}::...` with no empty segment.
///
/// `Parent` does not accept `ParentExtra` or `Other`. `Root::` and `::Sub`
/// are empty segments. The root itself is not rechecked here.
pub(crate) fn resolve_note_deck(
    root: &str,
    note_deck: Option<&str>,
    location: &str,
) -> Result<String, Problem> {
    let Some(name) = note_deck else {
        return Ok(root.to_string());
    };
    if name.is_empty() || name.split("::").any(|segment| segment.is_empty()) {
        return Err(Problem {
            code: DECK_NAME_INVALID.into(),
            location: format!("{location}.deck_name"),
            message: format!("deck_name \"{name}\" has an empty segment"),
        });
    }
    if name == root || name.starts_with(&format!("{root}::")) {
        return Ok(name.to_string());
    }
    Err(Problem {
        code: DECK_NAME_INVALID.into(),
        location: format!("{location}.deck_name"),
        message: format!("deck_name \"{name}\" is not under \"{root}\""),
    })
}

/// Anki cloze: `{{cN::...}}` where `N` parses as a `u16` greater than 0.
///
/// `{{c1::text}}` and `{{c1::text::hint}}` match. `{{c0::text}}` does not.
/// The scan follows the first `}}`, the same close Anki's cloze regex uses.
pub(crate) fn has_valid_cloze(text: &str) -> bool {
    let mut rest = text;
    while let Some(start) = rest.find("{{c") {
        rest = &rest[start + 3..];
        let digits_end = rest
            .find(|ch: char| !ch.is_ascii_digit())
            .unwrap_or(rest.len());
        if digits_end == 0 {
            continue;
        }
        let digits = &rest[..digits_end];
        let Ok(n) = digits.parse::<u16>() else {
            continue;
        };
        if n < 1 {
            continue;
        }
        if let Some(body) = rest[digits_end..].strip_prefix("::") {
            if body.contains("}}") {
                return true;
            }
        }
    }
    false
}

/// Local media names referenced by one field.
///
/// `<img>` `src` uses either quote. `[sound:name]` runs to the next `]`.
/// Remote `http://`, `https://`, and `data:` values are omitted. Matching
/// is case-insensitive for the tag, the attribute, and the URI scheme.
pub(crate) fn media_references(field: &str) -> Vec<String> {
    let mut names = img_srcs(field);
    names.extend(sound_refs(field));
    names.retain(|name| !is_remote_media(name));
    names
}

pub(crate) fn is_remote_media(name: &str) -> bool {
    let lower = name.trim().to_ascii_lowercase();
    lower.starts_with("http://") || lower.starts_with("https://") || lower.starts_with("data:")
}

fn img_srcs(html: &str) -> Vec<String> {
    let lower = html.to_ascii_lowercase();
    let mut names = Vec::new();
    let mut search_from = 0;
    while let Some(rel) = lower[search_from..].find("<img") {
        let start = search_from + rel;
        let Some(end_rel) = tag_end(&lower[start..]) else {
            break;
        };
        let tag = &html[start..start + end_rel];
        let tag_lower = &lower[start..start + end_rel];
        if let Some(value) = attr_value(tag, tag_lower, "src") {
            let value = value.trim();
            if !value.is_empty() {
                names.push(value.to_string());
            }
        }
        search_from = start + end_rel;
    }
    names
}

/// Byte index just past the tag's `>`, respecting quoted `>`.
fn tag_end(lower: &str) -> Option<usize> {
    let bytes = lower.as_bytes();
    let mut quote: Option<u8> = None;
    for (index, byte) in bytes.iter().copied().enumerate() {
        if let Some(open) = quote {
            if byte == open {
                quote = None;
            }
        } else if byte == b'"' || byte == b'\'' {
            quote = Some(byte);
        } else if byte == b'>' {
            return Some(index + 1);
        }
    }
    None
}

fn attr_value<'a>(tag: &'a str, tag_lower: &str, attr: &str) -> Option<&'a str> {
    let mut rest = tag;
    let mut rest_lower = tag_lower;
    while let Some(rel) = rest_lower.find(attr) {
        let before_ok = rel == 0
            || rest_lower.as_bytes().get(rel - 1).is_some_and(|byte| {
                !byte.is_ascii_alphanumeric() && *byte != b'-' && *byte != b'_' && *byte != b':'
            });
        let after = rel + attr.len();
        if !before_ok || after > rest_lower.len() {
            let next = rel + 1;
            rest = &rest[next..];
            rest_lower = &rest_lower[next..];
            continue;
        }
        let bytes = rest_lower.as_bytes();
        let mut index = after;
        while index < bytes.len() && bytes[index].is_ascii_whitespace() {
            index += 1;
        }
        if index >= bytes.len() || bytes[index] != b'=' {
            let next = rel + 1;
            rest = &rest[next..];
            rest_lower = &rest_lower[next..];
            continue;
        }
        index += 1;
        while index < bytes.len() && bytes[index].is_ascii_whitespace() {
            index += 1;
        }
        if index >= bytes.len() {
            return None;
        }
        let quote = bytes[index];
        if quote != b'"' && quote != b'\'' {
            return None;
        }
        index += 1;
        let value_start = index;
        while index < bytes.len() && bytes[index] != quote {
            index += 1;
        }
        if index >= bytes.len() {
            return None;
        }
        return Some(&rest[value_start..index]);
    }
    None
}

fn sound_refs(field: &str) -> Vec<String> {
    let mut names = Vec::new();
    let mut rest = field;
    while let Some(start) = rest.find("[sound:") {
        rest = &rest[start + "[sound:".len()..];
        let Some(end) = rest.find(']') else {
            break;
        };
        let name = rest[..end].trim();
        if !name.is_empty() {
            names.push(name.to_string());
        }
        rest = &rest[end + 1..];
    }
    names
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
    use hatto_card_contract::normalize_import_guid;

    fn deck(notes: Value) -> DeckFile {
        let mut value = skeleton();
        value["notes"] = notes;
        serde_json::from_value(value).unwrap()
    }

    #[test]
    fn notetype_legacy_is_rejected_for_any_value() {
        let values = [
            json!(null),
            json!("Basic"),
            json!({"name": "Basic"}),
            json!({"id": 0, "name": "Basic"}),
            json!({"id": "0", "name": "Basic"}),
            json!({"id": 1, "name": "Basic"}),
        ];
        for legacy in values {
            let mut with_notetype = skeleton();
            with_notetype["notetype_legacy"] = legacy.clone();
            let mut without_notetype = with_notetype.clone();
            without_notetype.as_object_mut().unwrap().remove("notetype");
            for value in [with_notetype, without_notetype] {
                let err = parse_deck(&serde_json::to_string(&value).unwrap()).unwrap_err();
                assert_eq!(err.code, NOTETYPE_LEGACY);
                assert_eq!(err.location, "notetype_legacy");
                assert_eq!(err.message, "notetype_legacy is not supported");
            }
        }
        let mut extra = skeleton();
        extra["extra"] = json!("keep");
        let parsed = parse_deck(&serde_json::to_string(&extra).unwrap()).unwrap();
        assert_eq!(parsed.notetype_name(), "Basic");
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

    fn file_with_job(job_id: Option<&str>, note_job: Option<&str>, source: &str) -> DeckFile {
        let mut value = skeleton();
        match job_id {
            Some(job) => value["job_id"] = json!(job),
            None => {
                value.as_object_mut().unwrap().remove("job_id");
            }
        }
        let mut note = json!({"source_guid": source, "fields": ["a", "b"]});
        if let Some(job) = note_job {
            note["job_id"] = json!(job);
        }
        value["notes"] = json!([note]);
        serde_json::from_value(value).unwrap()
    }

    #[test]
    fn source_guid_uses_normalize_import_guid_and_job_id_does_not_change_it() {
        // Contract §5.1 golden: base91 is hashed, a lowercase UUID is kept,
        // an uppercase UUID is not a guid.
        let cases = [
            ("oxr*zK@INR", "c15b93d8-6483-5c3c-b94f-1061d53fda92"),
            (
                "3f2b8a64-1c0e-4d5a-9b7e-0a1b2c3d4e5f",
                "3f2b8a64-1c0e-4d5a-9b7e-0a1b2c3d4e5f",
            ),
            (
                "3F2B8A64-1C0E-4D5A-9B7E-0A1B2C3D4E5F",
                "4b08d171-4bd5-5f1f-8e85-1315a11b82e0",
            ),
        ];
        let jobs = [
            (Some("01234567-89ab-4cde-8fab-0123456789ab"), None),
            (
                Some("11111111-2222-4333-8444-555555555555"),
                Some("aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"),
            ),
            (None, None),
            (Some("not-a-uuid"), Some("also-not")),
        ];
        for (source, expect) in cases {
            assert_eq!(normalize_import_guid(source).unwrap(), expect);
            for (deck_job, note_job) in jobs {
                let notes = derive_notes(&file_with_job(deck_job, note_job, source)).unwrap();
                assert_eq!(notes[0].guid, expect);
            }
        }
    }

    #[test]
    fn applying_the_derived_guid_again_does_not_change_it() {
        let once = derive_notes(&deck(json!([{
            "source_guid": "plainGuid3",
            "fields": ["a", "b"]
        }])))
        .unwrap();
        assert_eq!(once[0].guid, "e67308dc-2365-5fc4-900e-4fc19f04c9ab");
        let twice = derive_notes(&deck(json!([{
            "source_guid": once[0].guid,
            "fields": ["a", "b"]
        }])))
        .unwrap();
        assert_eq!(twice[0].guid, once[0].guid);
    }

    #[test]
    fn a_raw_and_its_normalized_form_are_a_duplicate_in_this_file() {
        let raw = "plainGuid3";
        let normalized = normalize_import_guid(raw).unwrap();
        let file = deck(json!([
            {"source_guid": raw, "fields": ["a", "b"]},
            {"source_guid": normalized, "fields": ["c", "d"]}
        ]));
        let errors = derive_notes(&file).unwrap_err();
        assert!(errors
            .iter()
            .all(|error| error.code == "NOTE_GUID_DUPLICATE"));
        assert_eq!(errors.len(), 2);
    }

    #[test]
    fn note_deck_name_must_be_the_root_or_a_child() {
        let ok = deck(json!([{
            "k": 0,
            "fields": ["a", "b"],
            "deck_name": "Example::Sub"
        }]));
        let notes = derive_notes(&ok).unwrap();
        assert_eq!(notes[0].deck_name, "Example::Sub");
        assert_eq!(notes[0].notetype, "Basic");

        let same = deck(json!([{
            "k": 0,
            "fields": ["a", "b"],
            "deck_name": "Example",
            "notetype": "Hatto Basic"
        }]));
        let notes = derive_notes(&same).unwrap();
        assert_eq!(notes[0].deck_name, "Example");
        assert_eq!(notes[0].notetype, "Hatto Basic");

        let nested = deck(json!([{
            "k": 0,
            "fields": ["a", "b"],
            "deck_name": "Example::Sub::Leaf"
        }]));
        assert_eq!(
            derive_notes(&nested).unwrap()[0].deck_name,
            "Example::Sub::Leaf"
        );

        let foreign = deck(json!([{
            "k": 0,
            "fields": ["a", "b"],
            "deck_name": "Other"
        }]));
        let errors = derive_notes(&foreign).unwrap_err();
        assert_eq!(errors[0].location, "notes[0].deck_name");
        assert!(
            errors[0].message.contains("not under"),
            "{}",
            errors[0].message
        );

        for bad in ["Example::", "Example::::Sub", "::Sub", ""] {
            let file = deck(json!([{
                "k": 0,
                "fields": ["a", "b"],
                "deck_name": bad
            }]));
            let errors = derive_notes(&file).unwrap_err();
            assert!(
                errors[0].message.contains("empty segment"),
                "{bad}: {}",
                errors[0].message
            );
        }
    }

    #[test]
    fn cloze_and_media_scanners_match_the_field_text() {
        assert!(has_valid_cloze("{{c1::hole}}"));
        assert!(has_valid_cloze("A {{c12::hole::hint}} B"));
        assert!(has_valid_cloze("{{c01::hole}}"));
        assert!(!has_valid_cloze("{{c0::hole}}"));
        assert!(!has_valid_cloze("{{c1:hole}}"));
        assert!(!has_valid_cloze("{{c1::hole}"));
        assert!(!has_valid_cloze("plain"));
        assert!(!has_valid_cloze("{{C1::hole}}"));

        let field = r#"<img src="dot.png"> <IMG SRC='beep.mp3'> <img src="https://example.com/a.png"> <img src="data:image/png;base64,aa"> <img class="src" src="quoted.png"> [sound:beep.mp3] [sound:https://example.com/a.mp3]"#;
        assert_eq!(
            media_references(field),
            vec![
                "dot.png".to_string(),
                "beep.mp3".to_string(),
                "quoted.png".to_string(),
                "beep.mp3".to_string(),
            ]
        );
        assert!(is_remote_media("HTTP://example.com/a.png"));
        assert!(is_remote_media("data:image/png;base64,aa"));
        assert!(!is_remote_media("dot.png"));
    }
}
