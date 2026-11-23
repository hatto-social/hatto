// SPDX-FileCopyrightText: 2026 Hatto Social contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

//! Import-E profile. A second backend for one temporary collection.
//!
//! The resident desktop table is not consulted. `OpenCollection` accepts only
//! `import/e/<uuid v4>/collection.anki2`. Package import reads `import/raw`,
//! and package export writes `import/staged`, both for that same id.

use std::path::Path;

use prost::Message;

use super::desktop::MAX_REQUEST_BYTES;
use super::validators::{
    check_import_options, check_search_order, data_dir, decode, e_collection_batch_id,
    expect_e_sibling, resolve_under_data_dir, uuid_v4_apkg_id, ImportOptionRule,
};
use super::{Access, AllowEntry, Status};
use super::{ANKIDROID, COLLECTION, DECKS, IMPORT_EXPORT, NOTES, SCHEDULER, SEARCH};
use crate::api::{backend_error, dispatch, AnkiBackend, ProtoResponse};

/// `UPDATE notes SET guid = ? WHERE id = ?`, including `executemany`.
pub(crate) const GUID_UPDATE_SQL: &str = "UPDATE notes SET guid = ? WHERE id = ?";

/// The one fixed `SELECT`: notes that have no card row.
pub(crate) const CARDLESS_NOTES_SQL: &str =
    "SELECT id FROM notes WHERE id NOT IN (SELECT nid FROM cards)";

const E_IMPORT_OPTIONS: ImportOptionRule = ImportOptionRule {
    update_notes: anki_proto::import_export::ImportAnkiPackageUpdateCondition::Never as i32,
    with_deck_configs: Some(true),
};

macro_rules! e_row {
    ($service:expr, $method:literal, $access:ident, $status:ident, $validation:expr, $test:expr) => {
        AllowEntry {
            service: $service,
            method: $method,
            access: Access::$access,
            status: Status::$status,
            validation: $validation,
            test_name: $test,
        }
    };
}

/// Calls the import pipeline may make on an E collection.
pub(crate) static E_ALLOWLIST: &[AllowEntry] = &[
    e_row!(COLLECTION, "open_collection", Write, Validated, "collection_path resolves to data_dir/import/e/<uuid v4>/collection.anki2; media folder is collection.media and media db is collection.media.db in that directory", "import_e_open_collection_accepts_only_its_directory"),
    e_row!(IMPORT_EXPORT, "import_anki_package", Write, Validated, "options is present and fixed: merge_notetypes false, update_notes NEVER, update_notetypes NEVER, with_scheduling true, with_deck_configs true; package_path resolves to data_dir/import/raw/<same uuid v4>.apkg", "import_e_import_accepts_only_raw_with_step2_options"),
    e_row!(IMPORT_EXPORT, "export_anki_package", Write, Validated, "options is present: with_scheduling true, with_media true, legacy false, with_deck_configs true or false, limit is the whole collection; out_path resolves to data_dir/import/staged/<same uuid v4>.apkg", "import_e_export_accepts_only_the_staged_path"),
    e_row!(NOTES, "get_note", Read, NameOnly, "없음", "import_e_name_only_calls_are_forwarded"),
    e_row!(SEARCH, "search_notes", Read, Validated, "order is absent, none, or an allowlisted builtin column; a custom order is rejected", "import_e_search_rejects_a_custom_order"),
    e_row!(SEARCH, "search_cards", Read, Validated, "order is absent, none, or an allowlisted builtin column; a custom order is rejected", "import_e_search_rejects_a_custom_order"),
    e_row!(NOTES, "remove_notes", Write, NameOnly, "없음", "import_e_name_only_calls_are_forwarded"),
    e_row!(DECKS, "remove_decks", Write, NameOnly, "없음", "import_e_name_only_calls_are_forwarded"),
    e_row!(SCHEDULER, "empty_filtered_deck", Write, NameOnly, "없음", "import_e_name_only_calls_are_forwarded"),
    e_row!(DECKS, "update_deck", Write, Validated, "normal deck only; description is empty and every other field matches the stored deck", "import_e_update_deck_clears_only_the_description"),
    e_row!(ANKIDROID, "run_db_command", Write, Validated, "executemany UPDATE notes SET guid = ? WHERE id = ?; SELECT id FROM notes WHERE id NOT IN (SELECT nid FROM cards); begin, commit, rollback", "import_e_run_db_command_allows_only_the_statement_whitelist"),
];

pub(crate) fn entry(service: &str, method: &str) -> Option<&'static AllowEntry> {
    E_ALLOWLIST
        .iter()
        .find(|row| row.service == service && row.method == method)
}

fn is_forwarded(service: &str, method: &str) -> bool {
    matches!(
        entry(service, method).map(|row| row.status),
        Some(Status::Validated | Status::NameOnly)
    )
}

pub(crate) fn enforce_import_e(
    backend: &AnkiBackend,
    service_index: u32,
    method_index: u32,
    input: Vec<u8>,
) -> ProtoResponse {
    if input.len() > MAX_REQUEST_BYTES {
        return backend_error(format!(
            "denied: request is {} bytes (exceeds 4 MiB)",
            input.len()
        ));
    }
    if backend.lock_session().poisoned {
        return backend_error("denied: backend poisoned, restart");
    }
    let Some((service, method)) = crate::index::reverse(service_index, method_index) else {
        return backend_error(format!(
            "denied: index {service_index}/{method_index} (not on allowlist)"
        ));
    };
    let full = format!("{service}.{method}");
    if !is_forwarded(service, method) {
        return backend_error(format!("denied: {full} (not on allowlist)"));
    }
    if method == "open_collection" && backend.lock_session().collection_open {
        return backend_error(format!("denied: {full} (collection is already open)"));
    }
    if method != "open_collection" && !backend.lock_session().collection_open {
        return backend_error(format!("denied: {full} (collection is not open)"));
    }
    let bytes = match prepare(backend, service, method, &input) {
        Ok(bytes) => bytes,
        Err(reason) => return backend_error(format!("denied: {full} ({reason})")),
    };
    let response = dispatch(backend, service_index, method_index, &bytes);
    if !response.success {
        return response;
    }
    if service == COLLECTION && method == "open_collection" {
        if let Err(err) = remember_open_batch(backend, &bytes) {
            return backend_error(format!("denied: {full} ({err})"));
        }
    }
    response
}

fn remember_open_batch(backend: &AnkiBackend, bytes: &[u8]) -> Result<(), String> {
    let open = decode::<anki_proto::collection::OpenCollectionRequest>(bytes)?;
    let data_dir = data_dir(backend)?;
    let id = e_collection_batch_id(Path::new(&open.collection_path), &data_dir)?;
    let mut session = backend.lock_session();
    session.collection_open = true;
    session.import_batch_id = Some(id);
    Ok(())
}

fn prepare(
    backend: &AnkiBackend,
    service: &str,
    method: &str,
    input: &[u8],
) -> Result<Vec<u8>, String> {
    match (service, method) {
        (COLLECTION, "open_collection") => validate_open(backend, input),
        (IMPORT_EXPORT, "import_anki_package") => validate_import(backend, input),
        (IMPORT_EXPORT, "export_anki_package") => validate_export(backend, input),
        (SEARCH, "search_notes" | "search_cards") => validate_search(input),
        (DECKS, "update_deck") => validate_update_deck(backend, input),
        (ANKIDROID, "run_db_command") => validate_run_db_command(input),
        (NOTES, "get_note" | "remove_notes")
        | (DECKS, "remove_decks")
        | (SCHEDULER, "empty_filtered_deck") => Ok(input.to_vec()),
        _ => Err("no import-e validator".into()),
    }
}

fn validate_open(backend: &AnkiBackend, input: &[u8]) -> Result<Vec<u8>, String> {
    let mut request = decode::<anki_proto::collection::OpenCollectionRequest>(input)?;
    let data_dir = data_dir(backend)?;
    let collection = resolve_under_data_dir(&request.collection_path, &data_dir)
        .map_err(|err| format!("collection_path: {err}"))?;
    let id = e_collection_batch_id(&collection, &data_dir)
        .map_err(|err| format!("collection_path: {err}"))?;
    let media = resolve_under_data_dir(&request.media_folder_path, &data_dir)
        .map_err(|err| format!("media_folder_path: {err}"))?;
    expect_e_sibling(&media, &data_dir, &id, "collection.media")
        .map_err(|err| format!("media_folder_path: {err}"))?;
    let media_db = resolve_under_data_dir(&request.media_db_path, &data_dir)
        .map_err(|err| format!("media_db_path: {err}"))?;
    expect_e_sibling(&media_db, &data_dir, &id, "collection.media.db")
        .map_err(|err| format!("media_db_path: {err}"))?;
    request.collection_path = collection.to_string_lossy().into_owned();
    request.media_folder_path = media.to_string_lossy().into_owned();
    request.media_db_path = media_db.to_string_lossy().into_owned();
    Ok(request.encode_to_vec())
}

fn validate_import(backend: &AnkiBackend, input: &[u8]) -> Result<Vec<u8>, String> {
    let mut request = decode::<anki_proto::import_export::ImportAnkiPackageRequest>(input)?;
    let Some(options) = request.options.as_ref() else {
        return Err("options must be set".into());
    };
    check_import_options(options, &E_IMPORT_OPTIONS)?;
    let data_dir = data_dir(backend)?;
    let resolved = resolve_under_data_dir(&request.package_path, &data_dir)
        .map_err(|err| format!("package_path: {err}"))?;
    let id = uuid_v4_apkg_id(&resolved, &data_dir, "raw")
        .map_err(|err| format!("package_path: {err}"))?;
    require_open_batch(backend, &id)?;
    request.package_path = resolved.to_string_lossy().into_owned();
    Ok(request.encode_to_vec())
}

fn validate_export(backend: &AnkiBackend, input: &[u8]) -> Result<Vec<u8>, String> {
    let mut request = decode::<anki_proto::import_export::ExportAnkiPackageRequest>(input)?;
    check_export_options(&request)?;
    let data_dir = data_dir(backend)?;
    let resolved = resolve_under_data_dir(&request.out_path, &data_dir)
        .map_err(|err| format!("out_path: {err}"))?;
    let id = uuid_v4_apkg_id(&resolved, &data_dir, "staged")
        .map_err(|err| format!("out_path: {err}"))?;
    require_open_batch(backend, &id)?;
    request.out_path = resolved.to_string_lossy().into_owned();
    Ok(request.encode_to_vec())
}

fn check_export_options(
    request: &anki_proto::import_export::ExportAnkiPackageRequest,
) -> Result<(), String> {
    let Some(options) = request.options.as_ref() else {
        return Err("options must be set".into());
    };
    if !options.with_scheduling {
        return Err("with_scheduling must be true".into());
    }
    if !options.with_media {
        return Err("with_media must be true".into());
    }
    if options.legacy {
        return Err("legacy must be false".into());
    }
    let whole = matches!(
        request
            .limit
            .as_ref()
            .and_then(|limit| limit.limit.as_ref()),
        Some(anki_proto::import_export::export_limit::Limit::WholeCollection(_))
    );
    if !whole {
        return Err("limit must be the whole collection".into());
    }
    Ok(())
}

fn validate_search(input: &[u8]) -> Result<Vec<u8>, String> {
    let request = decode::<anki_proto::search::SearchRequest>(input)?;
    check_search_order(request.order.as_ref())?;
    Ok(input.to_vec())
}

/// `UpdateDeck` may clear `Deck.Normal.description` and change nothing else.
fn validate_update_deck(backend: &AnkiBackend, input: &[u8]) -> Result<Vec<u8>, String> {
    let request = decode::<anki_proto::decks::Deck>(input)?;
    let Some(anki_proto::decks::deck::Kind::Normal(normal)) = request.kind.as_ref() else {
        return Err("deck is not a normal deck".into());
    };
    if !normal.description.is_empty() {
        return Err("description must be empty".into());
    }
    let bytes = crate::api::dispatch_message(
        backend,
        DECKS,
        "get_deck",
        &anki_proto::decks::DeckId { did: request.id },
    )
    .map_err(|_| format!("deck {} does not exist", request.id))?;
    let stored = decode::<anki_proto::decks::Deck>(&bytes)?;
    let expected = description_cleared(&stored)?;
    if request.encode_to_vec() != expected.encode_to_vec() {
        return Err("only the deck description may change, and it must be empty".into());
    }
    Ok(input.to_vec())
}

fn description_cleared(deck: &anki_proto::decks::Deck) -> Result<anki_proto::decks::Deck, String> {
    let mut cleared = deck.clone();
    match cleared.kind.as_mut() {
        Some(anki_proto::decks::deck::Kind::Normal(normal)) => {
            normal.description.clear();
            Ok(cleared)
        }
        _ => Err("deck is not a normal deck".into()),
    }
}

fn validate_run_db_command(input: &[u8]) -> Result<Vec<u8>, String> {
    let request = decode::<anki_proto::generic::Json>(input)?;
    let value: serde_json::Value = serde_json::from_slice(&request.json)
        .map_err(|err| format!("run_db_command json: {err}"))?;
    let Some(obj) = value.as_object() else {
        return Err("run_db_command json must be an object".into());
    };
    let Some(kind) = obj.get("kind").and_then(|kind| kind.as_str()) else {
        return Err("kind is missing".into());
    };
    match kind {
        "begin" | "commit" | "rollback" => exact_keys(obj, &["kind"])?,
        "executemany" => {
            exact_keys(obj, &["kind", "sql", "args"])?;
            let sql = obj
                .get("sql")
                .and_then(|sql| sql.as_str())
                .ok_or("sql is missing")?;
            if sql != GUID_UPDATE_SQL {
                return Err("sql is not on the statement whitelist".into());
            }
            let args = obj
                .get("args")
                .and_then(|args| args.as_array())
                .ok_or("args must be an array")?;
            for (index, row) in args.iter().enumerate() {
                let Some(row) = row.as_array() else {
                    return Err(format!("args[{index}] must be an array"));
                };
                if row.len() != 2 || row[0].as_str().is_none() || row[1].as_i64().is_none() {
                    return Err(format!(
                        "args[{index}] must be a guid string and an integer id"
                    ));
                }
            }
        }
        "query" => {
            exact_keys(obj, &["kind", "sql", "args", "first_row_only"])?;
            let sql = obj
                .get("sql")
                .and_then(|sql| sql.as_str())
                .ok_or("sql is missing")?;
            if sql != CARDLESS_NOTES_SQL {
                return Err("sql is not on the statement whitelist".into());
            }
            let args = obj
                .get("args")
                .and_then(|args| args.as_array())
                .ok_or("args must be an array")?;
            if !args.is_empty() {
                return Err("cardless-note select takes no parameters".into());
            }
            if obj
                .get("first_row_only")
                .and_then(|value| value.as_bool())
                .is_none()
            {
                return Err("first_row_only must be a bool".into());
            }
        }
        other => {
            return Err(format!(
                "sql kind {other} is not on the statement whitelist"
            ))
        }
    }
    Ok(input.to_vec())
}

fn exact_keys(
    obj: &serde_json::Map<String, serde_json::Value>,
    keys: &[&str],
) -> Result<(), String> {
    if obj.len() != keys.len() || keys.iter().any(|key| !obj.contains_key(*key)) {
        return Err(format!("json fields must be exactly {}", keys.join(", ")));
    }
    Ok(())
}

fn require_open_batch(backend: &AnkiBackend, id: &str) -> Result<(), String> {
    match backend.lock_session().import_batch_id.as_deref() {
        Some(open) if open == id => Ok(()),
        Some(_) => Err("import_batch_id does not match the open collection".into()),
        None => Err("import collection is not open".into()),
    }
}
