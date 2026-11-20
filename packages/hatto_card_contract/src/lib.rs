// SPDX-FileCopyrightText: 2026 Hatto Social contributors
//
// SPDX-License-Identifier: AGPL-3.0-or-later

//! Note-guid derivation and guid format checks.
//!
//! This crate is pure. It does no I/O, has no global state, and does not
//! depend on rslib or protobuf. Desktop and mobile call it through
//! `rslib_bridge`. The `hatto-card` CLI calls it directly.
//!
//! Agreed rules (do not extend them here):
//! - Imported notes: `uuid5(namespace = job_id, name = source_guid UTF-8 bytes)`.
//!   No trim and no Unicode normalization. An empty `source_guid` is rejected.
//!   `job_id` is an app-issued UUID. There is no second hash and no constant
//!   namespace string.
//! - Local notes: `uuid5(namespace = op_id, name = "note:" + k)` where `k` is
//!   the zero-based index inside one write. `op_id` is a CSPRNG UUIDv4 stored
//!   on the intent before the write.
//! - Deck guids are not derived. Something else issues a UUIDv4 after rslib
//!   creates the deck.
//! - The canonical text form is lowercase, hyphenated, and 36 characters.
//! - A guid string is accepted when it is that canonical form and its version
//!   nibble is 4 or 5.
//! - `NOTE_GUID_DUPLICATE` is only a duplicate inside the deck file passed to
//!   [validate_deck_file]. Collection and `note_map` duplicates are Dart
//!   `hatto_store`'s job. This crate does not know `note_map`.
//!
//! Sources: proposal 개정 2 and 개정 3 (2026-11-20), Gina desktop contract
//! §1.3 (op_id and the AddNote validator row), ADR 2026-11-18 (note guid is
//! uuid5 of the job and the original guid; the server does not reissue it).

use std::collections::BTreeMap;
use std::fmt;

pub use uuid::Uuid;

/// Canonical Anki guid text: lowercase, hyphenated, 36 characters.
#[derive(Clone, Debug, Eq, PartialEq, Hash, Ord, PartialOrd)]
pub struct NoteGuid(String);

impl NoteGuid {
    /// Formats `id` with [Uuid::as_hyphenated], which is lowercase.
    pub fn from_uuid(id: Uuid) -> Self {
        Self(id.as_hyphenated().to_string())
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }

    pub fn into_string(self) -> String {
        self.0
    }
}

impl From<Uuid> for NoteGuid {
    fn from(id: Uuid) -> Self {
        Self::from_uuid(id)
    }
}

impl fmt::Display for NoteGuid {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.0)
    }
}

impl AsRef<str> for NoteGuid {
    fn as_ref(&self) -> &str {
        self.as_str()
    }
}

/// `source_guid` was empty. Whitespace is not empty and is not stripped.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct EmptySourceGuid;

impl fmt::Display for EmptySourceGuid {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("source_guid is empty")
    }
}

impl std::error::Error for EmptySourceGuid {}

/// `text` is not a UUID string.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct UuidParseError {
    text: String,
}

impl fmt::Display for UuidParseError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "not a uuid: {}", self.text)
    }
}

impl std::error::Error for UuidParseError {}

/// Parses `text` as a UUID. The uuid crate accepts uppercase and unhyphenated
/// forms here. [is_guid_format] is the stricter canonical check.
pub fn parse_uuid(text: &str) -> Result<Uuid, UuidParseError> {
    Uuid::parse_str(text).map_err(|_| UuidParseError {
        text: text.to_string(),
    })
}

/// `uuid5(namespace = job_id, name = source_guid as UTF-8)`.
///
/// The name bytes are `source_guid` unchanged: no trim, no case fold, no NFC.
pub fn imported_note_guid(job_id: Uuid, source_guid: &str) -> Result<Uuid, EmptySourceGuid> {
    if source_guid.is_empty() {
        return Err(EmptySourceGuid);
    }
    Ok(derive(job_id, source_guid.as_bytes()))
}

/// `uuid5(namespace = op_id, name = "note:{k}")`.
///
/// `k` is printed in decimal with no padding. `0` is `"note:0"`.
pub fn local_note_guid(op_id: Uuid, k: u32) -> Uuid {
    let name = format!("note:{k}");
    derive(op_id, name.as_bytes())
}

fn derive(namespace: Uuid, name: &[u8]) -> Uuid {
    Uuid::new_v5(&namespace, name)
}

/// Lowercase hyphenated UUID whose version nibble is 4 or 5.
///
/// The text must already be the canonical 8-4-4-4-12 form. Uppercase hex and
/// strings without hyphens parse as UUIDs and are rejected. The version
/// nibble is 4 (random) or 5 (SHA-1). The variant must be RFC 4122, which is
/// what [Uuid::new_v5] and a UUIDv4 write into the clock-seq nibble. A
/// version nibble of 4 with a non-RFC variant is not a UUID this crate
/// issues.
pub fn is_guid_format(text: &str) -> bool {
    let Ok(id) = Uuid::parse_str(text) else {
        return false;
    };
    if id.as_hyphenated().to_string() != text {
        return false;
    }
    if id.get_variant() != uuid::Variant::RFC4122 {
        return false;
    }
    matches!(id.get_version_num(), 4 | 5)
}

/// Stable string ids. New codes may be added. Existing ids do not change.
#[non_exhaustive]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum CardErrorCode {
    GuidFormat,
    NoteGuidDuplicate,
}

impl CardErrorCode {
    pub const GUID_FORMAT: &'static str = "GUID_FORMAT";
    pub const NOTE_GUID_DUPLICATE: &'static str = "NOTE_GUID_DUPLICATE";

    pub fn as_str(self) -> &'static str {
        match self {
            Self::GuidFormat => Self::GUID_FORMAT,
            Self::NoteGuidDuplicate => Self::NOTE_GUID_DUPLICATE,
        }
    }
}

impl fmt::Display for CardErrorCode {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.as_str())
    }
}

/// One deck-file failure. `location` is whatever the caller uses to point at
/// the note (for example `notes[1].guid`).
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct CardError {
    pub code: CardErrorCode,
    pub location: String,
}

/// One note guid inside a deck file, with the caller's location string.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct DeckNote<'a> {
    pub guid: &'a str,
    pub location: &'a str,
}

/// Format and in-file duplicate checks.
///
/// Duplicates are exact string matches inside `notes` only. The same guid in
/// some other deck, or in `note_map`, is not visible here. Output is sorted
/// by `(code string, location)`. Equal keys keep input order.
pub fn validate_deck_file(notes: &[DeckNote<'_>]) -> Vec<CardError> {
    let mut errors = Vec::new();
    let mut seen: BTreeMap<&str, Vec<usize>> = BTreeMap::new();
    for (index, note) in notes.iter().enumerate() {
        seen.entry(note.guid).or_default().push(index);
        if !is_guid_format(note.guid) {
            errors.push(CardError {
                code: CardErrorCode::GuidFormat,
                location: note.location.to_string(),
            });
        }
    }
    for indexes in seen.values() {
        if indexes.len() < 2 {
            continue;
        }
        for index in indexes {
            errors.push(CardError {
                code: CardErrorCode::NoteGuidDuplicate,
                location: notes[*index].location.to_string(),
            });
        }
    }
    errors.sort_by(|left, right| {
        left.code
            .as_str()
            .cmp(right.code.as_str())
            .then_with(|| left.location.cmp(&right.location))
    });
    errors
}

#[cfg(test)]
mod tests {
    use super::*;

    fn guid(text: &str) -> Uuid {
        parse_uuid(text).unwrap()
    }

    #[test]
    fn golden_fixture_matches_both_functions() {
        let path = concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/fixtures/note_guid_golden.json"
        );
        let text = std::fs::read_to_string(path).unwrap();
        let file: serde_json::Value = serde_json::from_str(&text).unwrap();
        let imported = file["imported"].as_array().unwrap();
        assert!(
            imported.iter().any(|case| case["source_guid"] == "한글"
                || case["label"] == "non-ascii-hangul"),
            "non-ascii case missing"
        );
        assert!(
            imported.iter().any(|case| {
                case["source_guid"]
                    .as_str()
                    .is_some_and(|text| text.contains('\'')
                        && text.contains('"')
                        && text.contains('`')
                        && text.contains('\\'))
            }),
            "base91 specials missing"
        );
        assert!(
            imported
                .iter()
                .any(|case| case["error"] == "empty_source_guid"),
            "empty source_guid reject missing"
        );
        for case in imported {
            let job = guid(case["job_id"].as_str().unwrap());
            let source = case["source_guid"].as_str().unwrap();
            let derived = imported_note_guid(job, source);
            if case["error"] == "empty_source_guid" {
                assert_eq!(derived, Err(EmptySourceGuid), "{}", case["label"]);
                assert!(source.is_empty());
                continue;
            }
            let expect = case["expect"].as_str().unwrap();
            let id = derived.unwrap();
            let text = NoteGuid::from(id);
            assert_eq!(text.as_str(), expect, "{}", case["label"]);
            assert_eq!(text.as_str().len(), 36);
            assert!(is_guid_format(text.as_str()));
        }

        let local = file["local"].as_array().unwrap();
        assert!(local.iter().any(|case| case["k"] == 0));
        assert!(local.iter().any(|case| case["k"] == 4_294_967_295u64));
        for case in local {
            let op = guid(case["op_id"].as_str().unwrap());
            let k = case["k"].as_u64().unwrap() as u32;
            let id = local_note_guid(op, k);
            let text = NoteGuid::from(id);
            assert_eq!(text.as_str(), case["expect"].as_str().unwrap(), "k={k}");
            assert!(is_guid_format(text.as_str()));
        }
    }

    #[test]
    fn format_check_accepts_only_canonical_version_4_or_5() {
        let v5 = "886313e1-3b8a-5372-9b90-0c9aee199e5d";
        let v4 = "11111111-2222-4333-8444-555555555555";
        assert!(is_guid_format(v5));
        assert!(is_guid_format(v4));
        assert!(!is_guid_format(&v5.to_ascii_uppercase()));
        assert!(!is_guid_format("886313e13b8a53729b900c9aee199e5d"));
        assert!(!is_guid_format("6ba7b810-9dad-11d1-80b4-00c04fd430c8"));
        assert!(!is_guid_format("11111111-2222-3333-8444-555555555555"));
        assert!(!is_guid_format("hattoDummy"));
        assert!(!is_guid_format(""));
        assert!(!is_guid_format("11111111-2222-4333-0444-555555555555"));
    }

    #[test]
    fn deck_file_errors_are_sorted_and_local_to_the_file() {
        let notes = [
            DeckNote {
                guid: "not-a-uuid",
                location: "notes[1]",
            },
            DeckNote {
                guid: "886313e1-3b8a-5372-9b90-0c9aee199e5d",
                location: "notes[0]",
            },
            DeckNote {
                guid: "886313e1-3b8a-5372-9b90-0c9aee199e5d",
                location: "notes[2]",
            },
            DeckNote {
                guid: "not-a-uuid",
                location: "notes[3]",
            },
        ];
        let errors = validate_deck_file(&notes);
        let rendered: Vec<_> = errors
            .iter()
            .map(|error| (error.code.as_str(), error.location.as_str()))
            .collect();
        assert_eq!(
            rendered,
            vec![
                ("GUID_FORMAT", "notes[1]"),
                ("GUID_FORMAT", "notes[3]"),
                ("NOTE_GUID_DUPLICATE", "notes[0]"),
                ("NOTE_GUID_DUPLICATE", "notes[1]"),
                ("NOTE_GUID_DUPLICATE", "notes[2]"),
                ("NOTE_GUID_DUPLICATE", "notes[3]"),
            ]
        );
    }

    #[test]
    fn nfd_and_nfc_are_different_names() {
        let job = guid("11111111-2222-4333-8444-555555555555");
        let nfc = imported_note_guid(job, "é").unwrap();
        let nfd = imported_note_guid(job, "e\u{0301}").unwrap();
        assert_ne!(nfc, nfd);
    }
}
