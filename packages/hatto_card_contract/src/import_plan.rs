// SPDX-FileCopyrightText: 2026 Hatto Social contributors
//
// SPDX-License-Identifier: AGPL-3.0-or-later

//! Pure import guid assignment, content hash, and note classification.
//!
//! No I/O. [`imported_note_guid`] is called from here only with [`IMPORT_NS`].

use std::collections::{BTreeMap, BTreeSet};

use regex::Regex;
use sha2::{Digest, Sha256};

use crate::{imported_note_guid, is_guid_format, EmptySourceGuid, NoteGuid};
use uuid::Uuid;

/// Fixed import namespace. Permanent.
///
/// `uuid5(NAMESPACE_URL, "urn:hatto:import-note:v1")`.
/// Import calls [`imported_note_guid`] with this value only.
pub const IMPORT_NS: Uuid = Uuid::from_u128(0xec425e06_0eeb_5cbc_b4c8_3818366d46e9);

/// `f(raw)`. A canonical version-4 or version-5 guid is kept.
/// Anything else is [`imported_note_guid`] with [`IMPORT_NS`].
///
/// An empty string is [`EmptySourceGuid`]. Whitespace is not trimmed.
/// `f(f(x)) == f(x)` when `f(x)` is `Ok`, because a uuid5 result passes
/// [`is_guid_format`].
pub fn normalize_import_guid(raw: &str) -> Result<String, EmptySourceGuid> {
    if is_guid_format(raw) {
        return Ok(raw.to_string());
    }
    imported_note_guid(IMPORT_NS, raw).map(|id| NoteGuid::from(id).into_string())
}

/// One note from an import file, before guid assignment.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ImportSourceNote {
    pub source_note_id: i64,
    pub raw_guid: String,
}

/// Assigned guid for one import note.
///
/// `dup_index` is 0 for the first note of a duplicate group and for an empty
/// raw, and `k` for each later note. `reassigned` is true when pass 2 moved
/// off a guid that was already used. [`import_dup_count`] counts a row when
/// `dup_index >= 1` or `reassigned` is true.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct AssignedImportGuid {
    pub source_note_id: i64,
    pub guid: String,
    pub dup_index: u32,
    pub reassigned: bool,
}

/// Assign a canonical guid to every note.
///
/// Non-empty raws are grouped by [`normalize_import_guid`], not by the raw
/// string. Inside a group, notes are ordered by `(source_note_id, raw_guid)`
/// as UTF-8 bytes.
///
/// Pass 1 gives the 0th note of each group `f(raw)`. Those guids stay put.
///
/// Pass 2 walks empty raws and the `k >= 1` notes in
/// `(source_note_id, raw_guid, k)` order. The candidate name is
/// `"\x1fnid:" + decimal id` for an empty raw, and `raw + "\x1f" + decimal k`
/// otherwise. The candidate guid is `uuid5(IMPORT_NS, candidate_name)`. When
/// that guid is already used, the note takes the first free
/// `uuid5(IMPORT_NS, candidate_name + "\x1f#" + decimal j)` for `j = 1, 2, …`
/// and `reassigned` is set. A file with no such collision keeps the candidate
/// guids.
///
/// The returned vec has one row per input note. It is sorted by
/// `(source_note_id, dup_index, guid)`, so a shuffled input returns the same
/// vec.
pub fn assign_import_guids(notes: &[ImportSourceNote]) -> Vec<AssignedImportGuid> {
    struct Row {
        source_note_id: i64,
        raw: String,
        group_key: Option<String>,
    }

    let rows: Vec<Row> = notes
        .iter()
        .map(|note| {
            let group_key = if note.raw_guid.is_empty() {
                None
            } else {
                Some(normalize_import_guid(&note.raw_guid).expect("non-empty raw guid normalizes"))
            };
            Row {
                source_note_id: note.source_note_id,
                raw: note.raw_guid.clone(),
                group_key,
            }
        })
        .collect();

    let mut groups: BTreeMap<String, Vec<usize>> = BTreeMap::new();
    for (index, row) in rows.iter().enumerate() {
        if let Some(key) = &row.group_key {
            groups.entry(key.clone()).or_default().push(index);
        }
    }

    let mut assigned: Vec<Option<AssignedImportGuid>> = (0..rows.len()).map(|_| None).collect();
    let mut used: BTreeSet<String> = BTreeSet::new();
    let mut pass2: Vec<Pass2> = Vec::new();
    for (key, mut indexes) in groups {
        indexes.sort_by(|&left, &right| {
            rows[left]
                .source_note_id
                .cmp(&rows[right].source_note_id)
                .then_with(|| rows[left].raw.cmp(&rows[right].raw))
        });
        let first = indexes[0];
        assigned[first] = Some(AssignedImportGuid {
            source_note_id: rows[first].source_note_id,
            guid: key.clone(),
            dup_index: 0,
            reassigned: false,
        });
        used.insert(key);
        for (k, index) in indexes.into_iter().enumerate().skip(1) {
            let dup_index = u32::try_from(k).expect("duplicate index fits in u32");
            pass2.push(Pass2 {
                index,
                source_note_id: rows[index].source_note_id,
                raw: rows[index].raw.clone(),
                dup_index,
                candidate_name: format!("{}\x1f{k}", rows[index].raw),
            });
        }
    }
    for (index, row) in rows.iter().enumerate() {
        if row.group_key.is_some() {
            continue;
        }
        pass2.push(Pass2 {
            index,
            source_note_id: row.source_note_id,
            raw: row.raw.clone(),
            dup_index: 0,
            candidate_name: format!("\x1fnid:{}", row.source_note_id),
        });
    }
    pass2.sort_by(|left, right| {
        left.source_note_id
            .cmp(&right.source_note_id)
            .then_with(|| left.raw.cmp(&right.raw))
            .then_with(|| left.dup_index.cmp(&right.dup_index))
    });
    for item in pass2 {
        let (guid, reassigned) = take_unused_guid(&mut used, &item.candidate_name);
        assigned[item.index] = Some(AssignedImportGuid {
            source_note_id: item.source_note_id,
            guid,
            dup_index: item.dup_index,
            reassigned,
        });
    }

    let mut assigned: Vec<AssignedImportGuid> = assigned
        .into_iter()
        .map(|row| row.expect("every input note is assigned"))
        .collect();
    assigned.sort_by(|left, right| {
        left.source_note_id
            .cmp(&right.source_note_id)
            .then_with(|| left.dup_index.cmp(&right.dup_index))
            .then_with(|| left.guid.cmp(&right.guid))
    });
    assigned
}

/// How many assigned notes are duplicates.
///
/// A row counts when `dup_index >= 1` or pass 2 set `reassigned`. A note that
/// is both is counted once.
pub fn import_dup_count(assigned: &[AssignedImportGuid]) -> u32 {
    let count = assigned
        .iter()
        .filter(|row| row.dup_index >= 1 || row.reassigned)
        .count();
    u32::try_from(count).expect("duplicate count fits in u32")
}

struct Pass2 {
    index: usize,
    source_note_id: i64,
    raw: String,
    dup_index: u32,
    candidate_name: String,
}

fn guid_text(name: &str) -> String {
    NoteGuid::from(Uuid::new_v5(&IMPORT_NS, name.as_bytes())).into_string()
}

/// `uuid5(IMPORT_NS, candidate_name)`, or the first free
/// `uuid5(IMPORT_NS, candidate_name + "\x1f#" + j)` when that guid is taken.
fn take_unused_guid(used: &mut BTreeSet<String>, candidate_name: &str) -> (String, bool) {
    let candidate = guid_text(candidate_name);
    if used.insert(candidate.clone()) {
        return (candidate, false);
    }
    let mut bump = 1u32;
    loop {
        let name = format!("{candidate_name}\x1f#{bump}");
        let guid = guid_text(&name);
        if used.insert(guid.clone()) {
            return (guid, true);
        }
        bump = bump.checked_add(1).expect("guid collision bump");
    }
}

/// SHA-256 of the normalized fields and tags. Media bytes are not an input.
///
/// A media-collision suffix is removed from each field only when
/// `-[0-9a-f]{40}` is immediately followed by `\.[A-Za-z0-9]+`. The
/// replacement keeps the extension: `-[0-9a-f]{40}(\.[A-Za-z0-9]+)` → `$1`.
/// Uppercase hex, a run that is not 40 digits, and a hash with no extension
/// stay in the field.
///
/// The hashed bytes are the normalized fields joined by `0x1f`, then `0x1e`,
/// then the tags joined by a single space. Tags are deduplicated and sorted
/// by UTF-8 bytes. There is no case fold, no trim, and no Unicode
/// normalization.
pub fn note_content_hash<F, T>(fields: &[F], tags: &[T]) -> [u8; 32]
where
    F: AsRef<str>,
    T: AsRef<str>,
{
    let pattern = Regex::new(r"-[0-9a-f]{40}(\.[A-Za-z0-9]+)").expect("media suffix pattern");
    let normalized: Vec<String> = fields
        .iter()
        .map(|field| pattern.replace_all(field.as_ref(), "$1").into_owned())
        .collect();
    let mut unique_tags: Vec<&str> = tags.iter().map(AsRef::as_ref).collect();
    unique_tags.sort_unstable();
    unique_tags.dedup();

    let mut body = Vec::new();
    for (index, field) in normalized.iter().enumerate() {
        if index > 0 {
            body.push(0x1f);
        }
        body.extend_from_slice(field.as_bytes());
    }
    body.push(0x1e);
    for (index, tag) in unique_tags.iter().enumerate() {
        if index > 0 {
            body.push(b' ');
        }
        body.extend_from_slice(tag.as_bytes());
    }
    let digest = Sha256::digest(&body);
    let mut out = [0u8; 32];
    out.copy_from_slice(digest.as_slice());
    out
}

/// Facts for one note after guid normalization.
///
/// `guid` is not read by [`classify`]. The caller matches a file note to a
/// resident note before calling it. `r#mod` is Anki's `mod` column.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct NoteFacts {
    pub guid: String,
    pub notetype_id: i64,
    pub r#mod: i64,
    pub content_hash: [u8; 32],
}

/// How one file note relates to the resident collection.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Class {
    New,
    Same,
    Changed,
    LocalNewer,
    Blocked,
}

impl Class {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::New => "NEW",
            Self::Same => "SAME",
            Self::Changed => "CHANGED",
            Self::LocalNewer => "LOCAL_NEWER",
            Self::Blocked => "BLOCKED",
        }
    }
}

/// Classify one file note against an optional resident note.
///
/// Order: no resident is `New`; a different `notetype_id` is `Blocked` even
/// when the content hash matches; equal content hashes are `Same`; a greater
/// file `mod` is `Changed`; every other difference is `LocalNewer`, including
/// equal `mod` with a different content hash.
pub fn classify(file: &NoteFacts, resident: Option<&NoteFacts>) -> Class {
    let Some(resident) = resident else {
        return Class::New;
    };
    if file.notetype_id != resident.notetype_id {
        return Class::Blocked;
    }
    if file.content_hash == resident.content_hash {
        return Class::Same;
    }
    if file.r#mod > resident.r#mod {
        return Class::Changed;
    }
    Class::LocalNewer
}

/// Counts for one file. `dup` is the number of notes with `dup_index >= 1`.
///
/// `no_resident_call` is true when `new == 0` and `changed == 0`.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct Plan {
    pub new: u32,
    pub same: u32,
    pub changed: u32,
    pub local_newer: u32,
    pub blocked: u32,
    pub dup: u32,
    pub no_resident_call: bool,
}

/// Count `classes` and record `dup`. Does not look at note contents.
pub fn summarize_plan(classes: &[Class], dup: u32) -> Plan {
    let mut plan = Plan {
        new: 0,
        same: 0,
        changed: 0,
        local_newer: 0,
        blocked: 0,
        dup,
        no_resident_call: false,
    };
    for class in classes {
        match class {
            Class::New => plan.new = plan.new.checked_add(1).expect("new count"),
            Class::Same => plan.same = plan.same.checked_add(1).expect("same count"),
            Class::Changed => {
                plan.changed = plan.changed.checked_add(1).expect("changed count");
            }
            Class::LocalNewer => {
                plan.local_newer = plan.local_newer.checked_add(1).expect("local_newer count");
            }
            Class::Blocked => {
                plan.blocked = plan.blocked.checked_add(1).expect("blocked count");
            }
        }
    }
    plan.no_resident_call = plan.new == 0 && plan.changed == 0;
    plan
}

#[cfg(test)]
mod tests {
    use std::collections::BTreeSet;

    use super::*;

    const IMPORT_F: &[(&str, &str, &str)] = &[
        (
            "base91-anki-default",
            "oxr*zK@INR",
            "c15b93d8-6483-5c3c-b94f-1061d53fda92",
        ),
        (
            "base91-slash-hash",
            "b91/guid#2",
            "51aed07c-7668-5726-9830-b3eab77dcb92",
        ),
        (
            "plain-text",
            "plainGuid3",
            "e67308dc-2365-5fc4-900e-4fc19f04c9ab",
        ),
        (
            "lowercase-uuid-v4-preserved",
            "3f2b8a64-1c0e-4d5a-9b7e-0a1b2c3d4e5f",
            "3f2b8a64-1c0e-4d5a-9b7e-0a1b2c3d4e5f",
        ),
        (
            "uppercase-uuid-is-not-a-guid",
            "3F2B8A64-1C0E-4D5A-9B7E-0A1B2C3D4E5F",
            "4b08d171-4bd5-5f1f-8e85-1315a11b82e0",
        ),
        (
            "untrimmed-two-trailing-spaces",
            "a  ",
            "490ca485-3c6e-5cd4-82ab-174a4023134b",
        ),
    ];

    fn golden() -> serde_json::Value {
        let path = concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/fixtures/note_guid_golden.json"
        );
        let text = std::fs::read_to_string(path).unwrap();
        serde_json::from_str(&text).unwrap()
    }

    fn hex_bytes(text: &str) -> [u8; 32] {
        assert_eq!(text.len(), 64, "{text}");
        let bytes: Vec<u8> = (0..text.len())
            .step_by(2)
            .map(|index| u8::from_str_radix(&text[index..index + 2], 16).unwrap())
            .collect();
        bytes.try_into().unwrap()
    }

    fn facts(value: &serde_json::Value) -> NoteFacts {
        NoteFacts {
            guid: value["guid"].as_str().unwrap().to_string(),
            notetype_id: value["notetype_id"].as_i64().unwrap(),
            r#mod: value["mod"].as_i64().unwrap(),
            content_hash: hex_bytes(value["content_hash"].as_str().unwrap()),
        }
    }

    #[test]
    fn import_ns_is_the_fixed_uuid5_of_the_urn() {
        assert_eq!(
            IMPORT_NS.as_hyphenated().to_string(),
            "ec425e06-0eeb-5cbc-b4c8-3818366d46e9"
        );
        let derived = Uuid::new_v5(&Uuid::NAMESPACE_URL, b"urn:hatto:import-note:v1");
        assert_eq!(derived, IMPORT_NS);
    }

    #[test]
    fn normalize_matches_the_six_spec_rows_and_the_golden_file() {
        let file = golden();
        let rows = file["import_f"].as_array().unwrap();
        assert_eq!(rows.len(), IMPORT_F.len());
        for (label, raw, expect) in IMPORT_F {
            assert!(
                rows.iter().any(|row| {
                    row["label"] == *label && row["raw"] == *raw && row["expect"] == *expect
                }),
                "{label}"
            );
            let derived = normalize_import_guid(raw).unwrap();
            assert_eq!(&derived, expect, "{label}");
            assert!(is_guid_format(&derived));
            assert_eq!(normalize_import_guid(&derived).unwrap(), derived);
        }
        let preserved = "3f2b8a64-1c0e-4d5a-9b7e-0a1b2c3d4e5f";
        let upper = "3F2B8A64-1C0E-4D5A-9B7E-0A1B2C3D4E5F";
        assert!(is_guid_format(preserved));
        assert!(!is_guid_format(upper));
        assert_ne!(
            normalize_import_guid(upper).unwrap(),
            preserved,
            "uppercase is derived, not case-folded"
        );
        assert_eq!(normalize_import_guid(""), Err(EmptySourceGuid));
        let spaced = normalize_import_guid("a  ").unwrap();
        assert_ne!(spaced, normalize_import_guid("a").unwrap());
    }

    #[test]
    fn assign_hash_classify_and_plan_match_the_golden_file() {
        let file = golden();

        let assign_cases = file["assign_import_guids"].as_array().unwrap();
        assert!(assign_cases.iter().any(|case| case["label"] == "empty-raw"));
        assert!(assign_cases
            .iter()
            .any(|case| case["label"] == "same-raw-three"));
        assert!(assign_cases
            .iter()
            .any(|case| case["label"] == "different-raw-same-f"));
        assert!(assign_cases
            .iter()
            .any(|case| case["label"] == "empty-raw-collides-with-nid-name"));
        assert!(assign_cases
            .iter()
            .any(|case| case["label"] == "kth-candidate-claimed-by-pass1"));
        for case in assign_cases {
            let notes: Vec<ImportSourceNote> = case["notes"]
                .as_array()
                .unwrap()
                .iter()
                .map(|note| ImportSourceNote {
                    source_note_id: note["source_note_id"].as_i64().unwrap(),
                    raw_guid: note["raw_guid"].as_str().unwrap().to_string(),
                })
                .collect();
            let assigned = assign_import_guids(&notes);
            assert_eq!(assigned.len(), notes.len(), "{}", case["label"]);
            let again = assign_import_guids(&notes);
            assert_eq!(assigned, again, "{}", case["label"]);
            let mut reversed = notes.clone();
            reversed.reverse();
            assert_eq!(
                assign_import_guids(&reversed),
                assigned,
                "{}",
                case["label"]
            );
            let mut rotated = notes.clone();
            if rotated.len() > 1 {
                rotated.rotate_left(1);
                assert_eq!(assign_import_guids(&rotated), assigned, "{}", case["label"]);
            }
            let rendered: Vec<serde_json::Value> = assigned
                .iter()
                .map(|row| {
                    serde_json::json!({
                        "source_note_id": row.source_note_id,
                        "guid": row.guid,
                        "dup_index": row.dup_index,
                    })
                })
                .collect();
            assert_eq!(
                &serde_json::Value::Array(rendered),
                &case["expect"],
                "{}",
                case["label"]
            );
            assert!(assigned.iter().all(|row| is_guid_format(&row.guid)));
            let mut distinct = BTreeSet::new();
            assert!(assigned.iter().all(|row| distinct.insert(row.guid.clone())));
            assert_eq!(
                import_dup_count(&assigned),
                case["dup"].as_u64().unwrap() as u32,
                "{}",
                case["label"]
            );
        }

        let hash_cases = file["note_content_hash"].as_array().unwrap();
        let mut by_label = BTreeMap::new();
        for case in hash_cases {
            let fields: Vec<&str> = case["fields"]
                .as_array()
                .unwrap()
                .iter()
                .map(|field| field.as_str().unwrap())
                .collect();
            let tags: Vec<&str> = case["tags"]
                .as_array()
                .unwrap()
                .iter()
                .map(|tag| tag.as_str().unwrap())
                .collect();
            let digest = note_content_hash(&fields, &tags);
            let text: String = digest.iter().map(|byte| format!("{byte:02x}")).collect();
            assert_eq!(text, case["expect"].as_str().unwrap(), "{}", case["label"]);
            by_label.insert(case["label"].as_str().unwrap(), text);
        }
        assert_eq!(by_label["suffix-stripped"], by_label["plain-field"]);
        assert_ne!(by_label["short-hex"], by_label["plain-field"]);
        assert_ne!(by_label["upper-hex"], by_label["plain-field"]);
        assert_ne!(by_label["no-extension"], by_label["word"]);
        assert_eq!(by_label["tags-reordered"], by_label["tags-duplicated"]);
        assert_ne!(by_label["tag-uppercase"], by_label["tag-lowercase"]);
        assert_ne!(by_label["nfc-field"], by_label["nfd-field"]);
        assert_ne!(by_label["untrimmed-field"], by_label["trimmed-field"]);

        let classes = file["classify"].as_array().unwrap();
        for name in ["NEW", "SAME", "CHANGED", "LOCAL_NEWER", "BLOCKED"] {
            assert!(classes.iter().any(|case| case["expect"] == name), "{name}");
        }
        assert!(classes.iter().any(|case| {
            case["label"] == "notetype-differs-same-content" && case["expect"] == "BLOCKED"
        }));
        assert!(classes.iter().any(|case| {
            case["label"] == "same-mod-different-content" && case["expect"] == "LOCAL_NEWER"
        }));
        for case in classes {
            let file_facts = facts(&case["file"]);
            let resident = if case["resident"].is_null() {
                None
            } else {
                Some(facts(&case["resident"]))
            };
            let class = classify(&file_facts, resident.as_ref());
            assert_eq!(
                class.as_str(),
                case["expect"].as_str().unwrap(),
                "{}",
                case["label"]
            );
        }

        for case in file["plans"].as_array().unwrap() {
            let classes: Vec<Class> = case["classes"]
                .as_array()
                .unwrap()
                .iter()
                .map(|name| match name.as_str().unwrap() {
                    "NEW" => Class::New,
                    "SAME" => Class::Same,
                    "CHANGED" => Class::Changed,
                    "LOCAL_NEWER" => Class::LocalNewer,
                    "BLOCKED" => Class::Blocked,
                    other => panic!("unknown class {other}"),
                })
                .collect();
            let dup = case["dup"].as_u64().unwrap() as u32;
            let plan = summarize_plan(&classes, dup);
            let expect = &case["expect"];
            assert_eq!(
                plan.new,
                expect["new"].as_u64().unwrap() as u32,
                "{}",
                case["label"]
            );
            assert_eq!(plan.same, expect["same"].as_u64().unwrap() as u32);
            assert_eq!(plan.changed, expect["changed"].as_u64().unwrap() as u32);
            assert_eq!(
                plan.local_newer,
                expect["local_newer"].as_u64().unwrap() as u32
            );
            assert_eq!(plan.blocked, expect["blocked"].as_u64().unwrap() as u32);
            assert_eq!(plan.dup, expect["dup"].as_u64().unwrap() as u32);
            assert_eq!(
                plan.no_resident_call,
                expect["no_resident_call"].as_bool().unwrap(),
                "{}",
                case["label"]
            );
            assert_eq!(plan.no_resident_call, plan.new == 0 && plan.changed == 0);
        }
    }

    #[test]
    fn content_hash_joins_fields_then_sorted_unique_tags() {
        let hash = note_content_hash(&["front", "back"], &["b", "a", "a"]);
        let mut body = Vec::new();
        body.extend_from_slice(b"front");
        body.push(0x1f);
        body.extend_from_slice(b"back");
        body.push(0x1e);
        body.extend_from_slice(b"a b");
        assert_eq!(hash.as_slice(), Sha256::digest(&body).as_slice());

        let empty = note_content_hash(&[] as &[&str], &[] as &[&str]);
        assert_eq!(empty.as_slice(), Sha256::digest([0x1e]).as_slice());
    }

    #[test]
    fn assign_keeps_every_note_when_empty_raw_sits_beside_duplicates() {
        let notes = vec![
            ImportSourceNote {
                source_note_id: 5,
                raw_guid: String::new(),
            },
            ImportSourceNote {
                source_note_id: 3,
                raw_guid: "plainGuid3".into(),
            },
            ImportSourceNote {
                source_note_id: 4,
                raw_guid: "plainGuid3".into(),
            },
            ImportSourceNote {
                source_note_id: 1,
                raw_guid: String::new(),
            },
        ];
        let assigned = assign_import_guids(&notes);
        assert_eq!(assigned.len(), notes.len());
        assert_eq!(import_dup_count(&assigned), 1);
        assert_eq!(assign_import_guids(&notes), assigned);
        let mut flipped = notes.clone();
        flipped.reverse();
        assert_eq!(assign_import_guids(&flipped), assigned);
        assert_eq!(assigned[0].source_note_id, 1);
        assert_eq!(assigned[0].dup_index, 0);
        assert_eq!(assigned[1].source_note_id, 3);
        assert_eq!(assigned[1].dup_index, 0);
        assert_eq!(assigned[1].guid, "e67308dc-2365-5fc4-900e-4fc19f04c9ab");
        assert_eq!(assigned[2].source_note_id, 4);
        assert_eq!(assigned[2].dup_index, 1);
        assert_ne!(assigned[0].guid, assigned[3].guid);
    }
}

#[cfg(test)]
mod prop_tests {
    use super::*;
    use proptest::prelude::*;

    proptest! {
        #![proptest_config(ProptestConfig { cases: 128, .. ProptestConfig::default() })]

        #[test]
        fn normalize_import_guid_is_idempotent(
            raw in proptest::collection::vec(any::<char>(), 0..48)
                .prop_map(|chars| chars.into_iter().collect::<String>())
        ) {
            match normalize_import_guid(&raw) {
                Ok(once) => {
                    prop_assert!(is_guid_format(&once));
                    let twice = normalize_import_guid(&once).unwrap();
                    prop_assert_eq!(once, twice);
                }
                Err(error) => {
                    prop_assert_eq!(error, EmptySourceGuid);
                    prop_assert!(raw.is_empty());
                }
            }
        }

        #[test]
        fn planted_collisions_stay_unique_and_stable(
            (notes, keys) in with_shuffle_keys(prop_oneof![
                planted_empty_collision().boxed(),
                planted_kth_collision().boxed(),
            ])
        ) {
            let assigned = assign_import_guids(&notes);
            prop_assert!(assigned.iter().any(|row| row.reassigned));
            assert_stable_unique(&notes, &keys)?;
        }

        #[test]
        fn random_assignment_stays_unique_and_stable(
            (notes, keys) in with_shuffle_keys(random_notes())
        ) {
            assert_stable_unique(&notes, &keys)?;
        }
    }

    fn lowercase_uuid(mut bytes: [u8; 16], version: u8) -> String {
        bytes[6] = (bytes[6] & 0x0f) | (version << 4);
        bytes[8] = (bytes[8] & 0x3f) | 0x80;
        Uuid::from_bytes(bytes).as_hyphenated().to_string()
    }

    fn sixteen_bytes() -> impl Strategy<Value = [u8; 16]> {
        prop::collection::vec(any::<u8>(), 16).prop_map(|bytes| {
            let mut out = [0u8; 16];
            out.copy_from_slice(&bytes);
            out
        })
    }

    fn raw_strategy() -> impl Strategy<Value = String> {
        prop_oneof![
            2 => Just(String::new()).boxed(),
            2 => (1i64..40).prop_map(|id| format!("\x1fnid:{id}")).boxed(),
            2 => sixteen_bytes().prop_map(|bytes| lowercase_uuid(bytes, 4)).boxed(),
            1 => sixteen_bytes().prop_map(|bytes| lowercase_uuid(bytes, 5)).boxed(),
            2 => proptest::string::string_regex("[A-Za-z0-9]{1,10}")
                .unwrap()
                .boxed(),
            2 => proptest::string::string_regex("[A-Za-z0-9]{1,10}")
                .unwrap()
                .prop_map(|text| {
                    Uuid::new_v5(&IMPORT_NS, format!("{text}\x1f1").as_bytes())
                        .as_hyphenated()
                        .to_string()
                })
                .boxed(),
        ]
    }

    fn random_notes() -> impl Strategy<Value = Vec<ImportSourceNote>> {
        prop::collection::vec((0i64..40, raw_strategy()), 1..8).prop_map(|pairs| {
            pairs
                .into_iter()
                .map(|(id, raw_guid)| ImportSourceNote {
                    source_note_id: id,
                    raw_guid,
                })
                .collect()
        })
    }

    fn planted_empty_collision() -> impl Strategy<Value = Vec<ImportSourceNote>> {
        (1i64..500, 1i64..500).prop_map(|(empty_id, other_id)| {
            let other_id = if other_id == empty_id {
                other_id + 1
            } else {
                other_id
            };
            vec![
                ImportSourceNote {
                    source_note_id: empty_id,
                    raw_guid: String::new(),
                },
                ImportSourceNote {
                    source_note_id: other_id,
                    raw_guid: format!("\x1fnid:{empty_id}"),
                },
            ]
        })
    }

    fn planted_kth_collision() -> impl Strategy<Value = Vec<ImportSourceNote>> {
        (
            1i64..400,
            proptest::string::string_regex("[A-Za-z0-9]{1,12}").unwrap(),
        )
            .prop_map(|(id, raw)| {
                let derived = Uuid::new_v5(&IMPORT_NS, format!("{raw}\x1f1").as_bytes())
                    .as_hyphenated()
                    .to_string();
                vec![
                    ImportSourceNote {
                        source_note_id: id,
                        raw_guid: raw.clone(),
                    },
                    ImportSourceNote {
                        source_note_id: id + 1,
                        raw_guid: raw,
                    },
                    ImportSourceNote {
                        source_note_id: id + 2,
                        raw_guid: derived,
                    },
                ]
            })
    }

    fn with_shuffle_keys(
        notes: impl Strategy<Value = Vec<ImportSourceNote>>,
    ) -> impl Strategy<Value = (Vec<ImportSourceNote>, Vec<u64>)> {
        notes.prop_flat_map(|notes| {
            let len = notes.len();
            (Just(notes), prop::collection::vec(any::<u64>(), len))
        })
    }

    fn assert_stable_unique(notes: &[ImportSourceNote], keys: &[u64]) -> Result<(), TestCaseError> {
        let assigned = assign_import_guids(notes);
        prop_assert_eq!(assigned.len(), notes.len());
        let mut guids: Vec<&str> = assigned.iter().map(|row| row.guid.as_str()).collect();
        guids.sort_unstable();
        let mut distinct = guids.clone();
        distinct.dedup();
        prop_assert_eq!(distinct.len(), guids.len());
        prop_assert!(assigned.iter().all(|row| is_guid_format(&row.guid)));
        let mut shuffled: Vec<(u64, ImportSourceNote)> =
            keys.iter().copied().zip(notes.iter().cloned()).collect();
        shuffled.sort_by_key(|(key, _)| *key);
        let shuffled: Vec<ImportSourceNote> = shuffled.into_iter().map(|(_, note)| note).collect();
        prop_assert_eq!(assign_import_guids(&shuffled), assigned);
        Ok(())
    }
}
