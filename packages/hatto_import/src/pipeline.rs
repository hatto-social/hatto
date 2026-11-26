// SPDX-FileCopyrightText: 2026 Hatto Social contributors
//
// SPDX-License-Identifier: AGPL-3.0-or-later

//! Steps 1–7 of the import contract §7.1.
//!
//! The resident collection is not opened here. Note and deck facts come from
//! [`ResidentLookup`]. When the plan's `no_resident_call` is true, the raw,
//! E, and staged files are removed before this function returns.

use std::collections::BTreeMap;
use std::fs;
use std::io::Read;
use std::path::{Path, PathBuf};

use hatto_card_contract::{
    assign_import_guids, classify, import_dup_count, note_content_hash, summarize_plan, Class,
    ImportSourceNote, NoteFacts, Plan,
};
use sha2::{Digest, Sha256};
use uuid::Uuid;

use crate::channel::ESession;
use crate::cleanup::remove_import_batch;
use crate::error::ImportError;
use crate::paths::{e_dir, raw_dir, staged_dir};
use crate::preset::{self, clear_deck_description};

const ZIP_LOCAL_MAGIC: [u8; 4] = [0x50, 0x4b, 0x03, 0x04];
const DEFAULT_DECK_ID: i64 = 1;

/// Size ceiling for one package. The number is the caller's (O4). This crate
/// does not pick one.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct ImportLimits {
    pub max_bytes: u64,
}

/// What the caller can read about the resident collection.
///
/// [`ResidentLookup::note_facts`] is one batch for every guid in the file.
/// A guid with no resident note is absent from the map. `deck_id_by_name` is
/// the same comparison as `GetDeckIdByName`: `None` means that call's NotFound.
pub trait ResidentLookup {
    fn note_facts(&mut self, guids: &[String]) -> Result<BTreeMap<String, NoteFacts>, ImportError>;
    fn deck_id_by_name(&mut self, name: &str) -> Result<Option<i64>, ImportError>;
}

/// One note the UI can show before the resident write.
///
/// `class` is the contract class that put the note in its list.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct NoteIntent {
    pub guid: String,
    pub class: Class,
}

/// The three lists from [`partition_intents`].
///
/// This is a plan. It does not name a collection or a path.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ImportIntents {
    pub added: Vec<NoteIntent>,
    pub updated: Vec<NoteIntent>,
    pub skipped: Vec<NoteIntent>,
}

/// `New` is added, `Changed` is updated, and `Same`, `LocalNewer`, and
/// `Blocked` are skipped.
///
/// Order is the input order. This function does not read or write a collection.
pub fn partition_intents(notes: &[(&str, Class)]) -> ImportIntents {
    let mut added = Vec::new();
    let mut updated = Vec::new();
    let mut skipped = Vec::new();
    for (guid, class) in notes {
        let intent = NoteIntent {
            guid: (*guid).to_string(),
            class: *class,
        };
        match class {
            Class::New => added.push(intent),
            Class::Changed => updated.push(intent),
            Class::Same | Class::LocalNewer | Class::Blocked => skipped.push(intent),
        }
    }
    ImportIntents {
        added,
        updated,
        skipped,
    }
}

/// E pipeline output. `staged_path` is where the export was written.
///
/// `added`, `updated`, and `skipped` are the plan for the resident write.
/// On a no-op (`plan.no_resident_call`) the file is deleted before return.
/// `staged_sha256` is still the digest of the bytes that were written.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct PreparedImport {
    pub import_batch_id: Uuid,
    pub plan: Plan,
    pub staged_path: PathBuf,
    pub staged_sha256: String,
    pub first_import: bool,
    pub cardless_notes: u32,
    pub added: Vec<NoteIntent>,
    pub updated: Vec<NoteIntent>,
    pub skipped: Vec<NoteIntent>,
}

/// Run §7.1 steps 1–7 for `source` under `data_dir`.
pub fn prepare_import(
    data_dir: &Path,
    source: &Path,
    limits: ImportLimits,
    lookup: &mut dyn ResidentLookup,
) -> Result<PreparedImport, ImportError> {
    crate::paths::check_data_dir(data_dir)?;
    if !data_dir.is_dir() {
        return Err(ImportError::new("data_dir is not a directory"));
    }
    validate_source(source, limits)?;
    let batch_id = Uuid::new_v4();
    let guard = BatchGuard {
        data_dir: data_dir.to_path_buf(),
        batch_id,
        armed: true,
    };
    let prepared = prepare_with_id(data_dir, source, limits, batch_id, lookup)?;
    if prepared.plan.no_resident_call {
        // §15.5: a no-op deletes raw, e, and staged. The guard does that.
        Ok(prepared)
    } else {
        guard.disarm();
        Ok(prepared)
    }
}

fn prepare_with_id(
    data_dir: &Path,
    source: &Path,
    limits: ImportLimits,
    batch_id: Uuid,
    lookup: &mut dyn ResidentLookup,
) -> Result<PreparedImport, ImportError> {
    fs::create_dir_all(raw_dir(data_dir)?).map_err(|err| ImportError::new(err.to_string()))?;
    fs::create_dir_all(e_dir(data_dir)?).map_err(|err| ImportError::new(err.to_string()))?;
    fs::create_dir_all(staged_dir(data_dir)?).map_err(|err| ImportError::new(err.to_string()))?;

    let raw = crate::paths::raw_apkg_path(data_dir, batch_id)?;
    fs::copy(source, &raw).map_err(|err| ImportError::new(format!("copy source: {err}")))?;
    validate_source(&raw, limits)?;

    let cardless_notes = {
        let session = ESession::open(data_dir, batch_id)?;
        session.import_source_package(data_dir, batch_id)?;
        let assigned = rewrite_guids(&session)?;
        let cardless_notes = delete_cardless_notes(&session)?;
        delete_filtered_decks(&session)?;
        let classified = classify_notes(&session, lookup)?;
        let dup = import_dup_count(&assigned);
        let intent_input: Vec<(&str, Class)> = classified
            .iter()
            .map(|note| (note.guid.as_str(), note.class))
            .collect();
        let intents = partition_intents(&intent_input);
        let class_list: Vec<Class> = classified.iter().map(|note| note.class).collect();
        let plan = summarize_plan(&class_list, dup);
        // The plan is fixed before these writes. They do not classify again.
        remove_skipped_notes(&session, &classified)?;
        remove_empty_decks(&session)?;
        // The staged package only contains decks that are still here. This one
        // judgment is the preset branch, the export flag, and `first_import`.
        let names = deck_names_except_default(&session)?;
        let first_import = judge_first_import(lookup, &names)?;
        if !first_import {
            clear_matched_descriptions(&session, lookup, &names)?;
        } else {
            preset::restore_original_default_preset(&session, data_dir, batch_id)?;
        }
        session.export_staged(data_dir, batch_id, first_import)?;
        let staged = crate::paths::staged_apkg_path(data_dir, batch_id)?;
        let staged_sha256 = sha256_file(&staged)?;
        Ok(PreparedImport {
            import_batch_id: batch_id,
            plan,
            staged_path: staged,
            staged_sha256,
            first_import,
            cardless_notes,
            added: intents.added,
            updated: intents.updated,
            skipped: intents.skipped,
        })
    }?;
    Ok(cardless_notes)
}

struct BatchGuard {
    data_dir: PathBuf,
    batch_id: Uuid,
    armed: bool,
}

impl BatchGuard {
    fn disarm(mut self) {
        self.armed = false;
    }
}

impl Drop for BatchGuard {
    fn drop(&mut self) {
        if self.armed {
            let _ = remove_import_batch(&self.data_dir, self.batch_id);
        }
    }
}

fn validate_source(path: &Path, limits: ImportLimits) -> Result<(), ImportError> {
    let name = path
        .file_name()
        .and_then(|name| name.to_str())
        .unwrap_or("");
    if !name.ends_with(".apkg") || path.extension().and_then(|ext| ext.to_str()) != Some("apkg") {
        return Err(ImportError::new("package extension is not .apkg"));
    }
    let meta =
        fs::metadata(path).map_err(|err| ImportError::new(format!("{}: {err}", path.display())))?;
    if !meta.is_file() {
        return Err(ImportError::new("package path is not a file"));
    }
    if meta.len() > limits.max_bytes {
        return Err(ImportError::new("package exceeds max_bytes"));
    }
    let mut file = fs::File::open(path)
        .map_err(|err| ImportError::new(format!("{}: {err}", path.display())))?;
    let mut magic = [0u8; 4];
    file.read_exact(&mut magic)
        .map_err(|_| ImportError::new("package is shorter than a zip local header"))?;
    if magic != ZIP_LOCAL_MAGIC {
        return Err(ImportError::new(
            "package does not start with a zip local header",
        ));
    }
    Ok(())
}

fn rewrite_guids(
    session: &ESession,
) -> Result<Vec<hatto_card_contract::AssignedImportGuid>, ImportError> {
    let rows = session.db_json(&serde_json::json!({
        "kind": "query",
        "sql": "SELECT id, guid FROM notes ORDER BY id",
        "args": [],
        "first_row_only": false,
    }))?;
    let mut sources = Vec::new();
    for row in rows.as_array().unwrap_or(&Vec::new()) {
        let cells = row
            .as_array()
            .ok_or_else(|| ImportError::new("notes row is not an array"))?;
        let id = cell_i64(&cells[0], "notes.id")?;
        let guid = cell_string(&cells[1], "notes.guid")?;
        sources.push(ImportSourceNote {
            source_note_id: id,
            raw_guid: guid,
        });
    }
    let assigned = assign_import_guids(&sources);
    if assigned.is_empty() {
        return Ok(assigned);
    }
    let args: Vec<Vec<serde_json::Value>> = assigned
        .iter()
        .map(|row| {
            vec![
                serde_json::Value::String(row.guid.clone()),
                serde_json::json!(row.source_note_id),
            ]
        })
        .collect();
    session.db_json(&serde_json::json!({"kind": "begin"}))?;
    for chunk in guid_update_chunks(&args) {
        let updated = session.db_json(&serde_json::json!({
            "kind": "executemany",
            "sql": GUID_UPDATE_SQL,
            "args": chunk,
        }));
        if let Err(err) = updated {
            let _ = session.db_json(&serde_json::json!({"kind": "rollback"}));
            return Err(err);
        }
    }
    session.db_json(&serde_json::json!({"kind": "commit"}))?;
    Ok(assigned)
}

const GUID_UPDATE_SQL: &str = "UPDATE notes SET guid = ? WHERE id = ?";

/// Empty executemany body: the prefix
/// `{"kind":"executemany","sql":"UPDATE notes SET guid = ? WHERE id = ?","args":[`
/// plus `]}`. serde_json sorts object keys, so the bytes on the wire are
/// `{"args":[],"kind":…,"sql":…}`, which is the same length.
const GUID_UPDATE_ENVELOPE: &str =
    r#"{"kind":"executemany","sql":"UPDATE notes SET guid = ? WHERE id = ?","args":[]}"#;
const GUID_UPDATE_OUTER_BYTES: usize = GUID_UPDATE_ENVELOPE.len();

/// I3's 4 MiB cap is the protobuf `run_db_command` request. The protobuf
/// wrapper is at most 5 bytes. The JSON body stays at or under 4 MiB - 16.
const GUID_UPDATE_LIMIT: usize = 4 * 1024 * 1024 - 16;

fn guid_update_chunks(args: &[Vec<serde_json::Value>]) -> Vec<&[Vec<serde_json::Value>]> {
    let row_lens: Vec<usize> = args.iter().map(|row| json_row_len(row)).collect();
    let mut chunks = Vec::new();
    let mut start = 0;
    while start < row_lens.len() {
        let mut end = start;
        let mut wire = GUID_UPDATE_OUTER_BYTES;
        while end < row_lens.len() {
            // A comma sits between rows. The first row has no comma, which is
            // the same as counting `len + 1` for every row and then dropping
            // the comma after the last one.
            let add = row_lens[end] + usize::from(end != start);
            let next = wire.saturating_add(add);
            if end > start && next > GUID_UPDATE_LIMIT {
                break;
            }
            wire = next;
            end += 1;
            if wire > GUID_UPDATE_LIMIT {
                break;
            }
        }
        chunks.push(&args[start..end]);
        start = end;
    }
    chunks
}

fn json_row_len(row: &[serde_json::Value]) -> usize {
    serde_json::to_vec(row)
        .map(|bytes| bytes.len())
        .unwrap_or(usize::MAX)
}

/// Byte length of one executemany body. One pass over the rows.
#[cfg(test)]
fn guid_update_wire_len(args: &[Vec<serde_json::Value>]) -> usize {
    if args.is_empty() {
        return GUID_UPDATE_OUTER_BYTES;
    }
    let mut wire = GUID_UPDATE_OUTER_BYTES;
    for (index, row) in args.iter().enumerate() {
        wire = wire.saturating_add(json_row_len(row) + usize::from(index != 0));
    }
    wire
}

fn delete_cardless_notes(session: &ESession) -> Result<u32, ImportError> {
    let rows = session.db_json(&serde_json::json!({
        "kind": "query",
        "sql": "SELECT id FROM notes WHERE id NOT IN (SELECT nid FROM cards) ORDER BY id",
        "args": [],
        "first_row_only": false,
    }))?;
    let mut ids = Vec::new();
    for row in rows.as_array().unwrap_or(&Vec::new()) {
        let cells = row
            .as_array()
            .ok_or_else(|| ImportError::new("cardless row is not an array"))?;
        ids.push(cell_i64(&cells[0], "notes.id")?);
    }
    let count = u32::try_from(ids.len())
        .map_err(|_| ImportError::new("cardless note count does not fit in u32"))?;
    if ids.is_empty() {
        return Ok(0);
    }
    let _changes: anki_proto::collection::OpChangesWithCount = session.call(
        "BackendNotesService",
        "remove_notes",
        &anki_proto::notes::RemoveNotesRequest {
            note_ids: ids,
            card_ids: Vec::new(),
        },
    )?;
    Ok(count)
}

fn delete_filtered_decks(session: &ESession) -> Result<(), ImportError> {
    let mut filtered = Vec::new();
    for (deck_id, name) in deck_entries(session)? {
        let deck = preset::get_deck(session, deck_id)?;
        if matches!(deck.kind, Some(anki_proto::decks::deck::Kind::Filtered(_))) {
            filtered.push((name.matches("::").count(), deck_id));
        }
    }
    filtered.sort_by(|left, right| right.0.cmp(&left.0).then(left.1.cmp(&right.1)));
    for (_depth, deck_id) in filtered {
        let _empty: anki_proto::collection::OpChanges = session.call(
            "BackendSchedulerService",
            "empty_filtered_deck",
            &anki_proto::decks::DeckId { did: deck_id },
        )?;
        let _removed: anki_proto::collection::OpChangesWithCount = session.call(
            "BackendDecksService",
            "remove_decks",
            &anki_proto::decks::DeckIds {
                dids: vec![deck_id],
            },
        )?;
    }
    Ok(())
}

struct ClassifiedNote {
    id: i64,
    guid: String,
    class: Class,
}

fn classify_notes(
    session: &ESession,
    lookup: &mut dyn ResidentLookup,
) -> Result<Vec<ClassifiedNote>, ImportError> {
    let rows = session.db_json(&serde_json::json!({
        "kind": "query",
        "sql": "SELECT id, guid, mid, \"mod\", flds, tags FROM notes ORDER BY id",
        "args": [],
        "first_row_only": false,
    }))?;
    let mut pending = Vec::new();
    let mut guids = Vec::new();
    for row in rows.as_array().unwrap_or(&Vec::new()) {
        let cells = row
            .as_array()
            .ok_or_else(|| ImportError::new("note row is not an array"))?;
        let id = cell_i64(&cells[0], "notes.id")?;
        let guid = cell_string(&cells[1], "notes.guid")?;
        let notetype_id = cell_i64(&cells[2], "notes.mid")?;
        let mod_secs = cell_i64(&cells[3], "notes.mod")?;
        let flds = cell_string(&cells[4], "notes.flds")?;
        let tags = cell_string(&cells[5], "notes.tags")?;
        guids.push(guid);
        pending.push((id, notetype_id, mod_secs, flds, tags));
    }
    let resident = lookup.note_facts(&guids)?;
    let mut classes = Vec::new();
    for (index, (id, notetype_id, mod_secs, flds, tags)) in pending.into_iter().enumerate() {
        let guid = &guids[index];
        let file = facts_from_stored_note(guid, notetype_id, mod_secs, &flds, &tags);
        let class = classify(&file, resident.get(guid));
        classes.push(ClassifiedNote {
            id,
            guid: guid.clone(),
            class,
        });
    }
    Ok(classes)
}

fn remove_skipped_notes(session: &ESession, classes: &[ClassifiedNote]) -> Result<(), ImportError> {
    let ids: Vec<i64> = classes
        .iter()
        .filter(|note| matches!(note.class, Class::Same | Class::LocalNewer | Class::Blocked))
        .map(|note| note.id)
        .collect();
    if ids.is_empty() {
        return Ok(());
    }
    let _changes: anki_proto::collection::OpChangesWithCount = session.call(
        "BackendNotesService",
        "remove_notes",
        &anki_proto::notes::RemoveNotesRequest {
            note_ids: ids,
            card_ids: Vec::new(),
        },
    )?;
    Ok(())
}

fn remove_empty_decks(session: &ESession) -> Result<(), ImportError> {
    loop {
        let decks = deck_entries(session)?;
        let counts = card_counts_by_deck(session)?;
        let names: Vec<String> = decks.iter().map(|(_, name)| name.clone()).collect();
        let mut leaves = Vec::new();
        for (deck_id, name) in &decks {
            if *deck_id == DEFAULT_DECK_ID {
                continue;
            }
            if counts.get(deck_id).copied().unwrap_or(0) > 0 {
                continue;
            }
            let prefix = format!("{name}::");
            if names.iter().any(|other| other.starts_with(&prefix)) {
                continue;
            }
            leaves.push(*deck_id);
        }
        if leaves.is_empty() {
            break;
        }
        let _removed: anki_proto::collection::OpChangesWithCount = session.call(
            "BackendDecksService",
            "remove_decks",
            &anki_proto::decks::DeckIds { dids: leaves },
        )?;
    }
    Ok(())
}

pub(crate) fn deck_entries(session: &ESession) -> Result<Vec<(i64, String)>, ImportError> {
    let names: anki_proto::decks::DeckNames = session.call(
        "BackendDecksService",
        "get_deck_names",
        &anki_proto::decks::GetDeckNamesRequest {
            skip_empty_default: false,
            include_filtered: true,
        },
    )?;
    let mut entries = Vec::new();
    for entry in names.entries {
        entries.push((entry.id, entry.name));
    }
    Ok(entries)
}

fn deck_names_except_default(session: &ESession) -> Result<Vec<String>, ImportError> {
    let mut names = Vec::new();
    for (deck_id, name) in deck_entries(session)? {
        if deck_id != DEFAULT_DECK_ID {
            names.push(name);
        }
    }
    Ok(names)
}

fn judge_first_import(
    lookup: &mut dyn ResidentLookup,
    names: &[String],
) -> Result<bool, ImportError> {
    for name in names {
        if lookup.deck_id_by_name(name)?.is_some() {
            return Ok(false);
        }
    }
    Ok(true)
}

fn clear_matched_descriptions(
    session: &ESession,
    lookup: &mut dyn ResidentLookup,
    names: &[String],
) -> Result<(), ImportError> {
    let decks = deck_entries(session)?;
    for name in names {
        if lookup.deck_id_by_name(name)?.is_none() {
            continue;
        }
        let Some((deck_id, _)) = decks.iter().find(|(_, deck_name)| deck_name == name) else {
            continue;
        };
        clear_deck_description(session, *deck_id)?;
    }
    Ok(())
}

fn card_counts_by_deck(
    session: &ESession,
) -> Result<std::collections::BTreeMap<i64, i64>, ImportError> {
    let rows = session.db_json(&serde_json::json!({
        "kind": "query",
        "sql": "SELECT did, count(*) FROM cards GROUP BY did",
        "args": [],
        "first_row_only": false,
    }))?;
    let mut counts = std::collections::BTreeMap::new();
    for row in rows.as_array().unwrap_or(&Vec::new()) {
        let cells = row
            .as_array()
            .ok_or_else(|| ImportError::new("card count row is not an array"))?;
        counts.insert(
            cell_i64(&cells[0], "cards.did")?,
            cell_i64(&cells[1], "count")?,
        );
    }
    Ok(counts)
}

/// Facts for one stored note. Fields are split on `\\x1f` and empty fields are
/// kept. Tags are split on ASCII spaces and empty pieces are dropped.
pub fn facts_from_stored_note(
    guid: &str,
    notetype_id: i64,
    mod_secs: i64,
    flds: &str,
    tags: &str,
) -> NoteFacts {
    let fields: Vec<&str> = flds.split('\u{1f}').collect();
    let tag_list: Vec<&str> = tags.split(' ').filter(|tag| !tag.is_empty()).collect();
    NoteFacts {
        guid: guid.to_string(),
        notetype_id,
        r#mod: mod_secs,
        content_hash: note_content_hash(&fields, &tag_list),
    }
}

fn sha256_file(path: &Path) -> Result<String, ImportError> {
    let bytes =
        fs::read(path).map_err(|err| ImportError::new(format!("{}: {err}", path.display())))?;
    let digest = Sha256::digest(&bytes);
    Ok(hex_encode(&digest))
}

fn hex_encode(bytes: &[u8]) -> String {
    const HEX: &[u8; 16] = b"0123456789abcdef";
    let mut out = String::with_capacity(bytes.len() * 2);
    for byte in bytes {
        out.push(HEX[(byte >> 4) as usize] as char);
        out.push(HEX[(byte & 0x0f) as usize] as char);
    }
    out
}

fn cell_i64(value: &serde_json::Value, label: &str) -> Result<i64, ImportError> {
    value
        .as_i64()
        .or_else(|| value.as_u64().and_then(|number| i64::try_from(number).ok()))
        .ok_or_else(|| ImportError::new(format!("{label} is not an integer")))
}

fn cell_string(value: &serde_json::Value, label: &str) -> Result<String, ImportError> {
    value
        .as_str()
        .map(str::to_string)
        .ok_or_else(|| ImportError::new(format!("{label} is not a string")))
}

#[cfg(test)]
mod chunk_tests {
    use super::{
        guid_update_chunks, guid_update_wire_len, partition_intents, Class, GUID_UPDATE_ENVELOPE,
        GUID_UPDATE_LIMIT, GUID_UPDATE_OUTER_BYTES, GUID_UPDATE_SQL,
    };

    fn serialized_len(args: &[Vec<serde_json::Value>]) -> usize {
        serde_json::to_vec(&serde_json::json!({
            "kind": "executemany",
            "sql": GUID_UPDATE_SQL,
            "args": args,
        }))
        .unwrap()
        .len()
    }

    fn string_row(chars: usize) -> Vec<serde_json::Value> {
        vec![serde_json::Value::String("x".repeat(chars))]
    }

    fn assert_chunks_match_wire(args: &[Vec<serde_json::Value>]) {
        let chunks = guid_update_chunks(args);
        let mut rows = 0;
        for chunk in &chunks {
            let wire = guid_update_wire_len(chunk);
            assert_eq!(wire, serialized_len(chunk), "chunk of {}", chunk.len());
            assert!(wire <= GUID_UPDATE_LIMIT || chunk.len() == 1);
            rows += chunk.len();
        }
        assert_eq!(rows, args.len());
    }

    #[test]
    fn intents_follow_the_class_buckets_in_input_order() {
        let notes = [
            ("n", Class::New),
            ("s", Class::Same),
            ("c", Class::Changed),
            ("l", Class::LocalNewer),
            ("b", Class::Blocked),
            ("n2", Class::New),
        ];
        let intents = partition_intents(&notes);
        assert_eq!(intent_guids(&intents.added), ["n", "n2"]);
        assert_eq!(intent_guids(&intents.updated), ["c"]);
        assert_eq!(intent_guids(&intents.skipped), ["s", "l", "b"]);
        assert_eq!(intents.added[0].class, Class::New);
        assert_eq!(intents.updated[0].class, Class::Changed);
        assert_eq!(intents.skipped[0].class, Class::Same);
        assert_eq!(intents.skipped[1].class, Class::LocalNewer);
        assert_eq!(intents.skipped[2].class, Class::Blocked);
    }

    fn intent_guids(rows: &[crate::NoteIntent]) -> Vec<&str> {
        rows.iter().map(|row| row.guid.as_str()).collect()
    }

    #[test]
    fn envelope_is_the_empty_executemany_body() {
        assert_eq!(
            GUID_UPDATE_ENVELOPE,
            format!(r#"{{"kind":"executemany","sql":"{GUID_UPDATE_SQL}","args":[]}}"#)
        );
        assert_eq!(GUID_UPDATE_OUTER_BYTES, serialized_len(&[]));
        assert_eq!(guid_update_wire_len(&[]), serialized_len(&[]));
    }

    #[test]
    fn guid_updates_are_split_under_the_db_request_cap() {
        let row = vec![
            serde_json::Value::String("g".repeat(1_000_000)),
            serde_json::json!(1),
        ];
        let args = vec![row; 5];
        let chunks = guid_update_chunks(&args);
        assert!(chunks.len() > 1);
        assert_chunks_match_wire(&args);
    }

    #[test]
    fn chunks_split_on_either_side_of_the_limit() {
        let filler = string_row(996);
        let filler_len = serde_json::to_vec(&filler).unwrap().len();
        assert_eq!(filler_len, 1000);
        let mut count = 0;
        let mut wire = GUID_UPDATE_OUTER_BYTES + filler_len;
        while wire + filler_len + 1 + 64 <= GUID_UPDATE_LIMIT {
            count += 1;
            wire += filler_len + 1;
        }
        count += 1;
        assert_eq!(guid_update_wire_len(&vec![filler.clone(); count]), wire);

        let tail_for = |total: usize| -> usize {
            let need = total - wire - 1;
            assert!(need >= 4, "tail {need} cannot be a one-string row");
            need - 4
        };
        let mut under = vec![filler.clone(); count];
        under.push(string_row(tail_for(GUID_UPDATE_LIMIT - 1)));
        let mut exact = vec![filler.clone(); count];
        exact.push(string_row(tail_for(GUID_UPDATE_LIMIT)));
        let mut over = vec![filler; count];
        over.push(string_row(tail_for(GUID_UPDATE_LIMIT + 1)));

        assert_eq!(serialized_len(&under), GUID_UPDATE_LIMIT - 1);
        assert_eq!(guid_update_wire_len(&under), GUID_UPDATE_LIMIT - 1);
        assert_eq!(guid_update_chunks(&under).len(), 1);

        assert_eq!(serialized_len(&exact), GUID_UPDATE_LIMIT);
        assert_eq!(guid_update_wire_len(&exact), GUID_UPDATE_LIMIT);
        assert_eq!(guid_update_chunks(&exact).len(), 1);

        assert_eq!(serialized_len(&over), GUID_UPDATE_LIMIT + 1);
        assert_eq!(guid_update_wire_len(&over), GUID_UPDATE_LIMIT + 1);
        let chunks = guid_update_chunks(&over);
        assert_eq!(chunks.len(), 2);
        assert_eq!(chunks[0].len(), count);
        assert_eq!(chunks[1].len(), 1);
        assert_chunks_match_wire(&under);
        assert_chunks_match_wire(&exact);
        assert_chunks_match_wire(&over);
    }
}
