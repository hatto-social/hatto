// SPDX-FileCopyrightText: 2026 Hatto Social contributors
//
// SPDX-License-Identifier: AGPL-3.0-or-later

//! One-time FSRS setup for a desktop collection.
//!
//! This is not a public bridge call. Dart cannot invoke it. The desktop
//! profile runs it after a successful `OpenCollection`. The calls it makes
//! go through `dispatch_message`, so the profile gate does not see them.
//! An app `UpdateDeckConfigs` stays denied.
//!
//! The three conditions are the contract's: no revlog rows, FSRS off, and no
//! marker file. A newly created collection file is not itself a signal.
//! When the revlog already has a row, FSRS stays off and only the marker is
//! written. The marker is written after `UpdateDeckConfigs` succeeds, by
//! renaming a temporary file in the same directory. The collection is then
//! closed and opened again so the in-memory undo entry from that update is
//! dropped.

use std::fs::File;
use std::io::Write;
use std::path::{Path, PathBuf};

use prost::Message;

use crate::api::{dispatch_message, AnkiBackend};

const DEFAULT_DECK_ID: i64 = 1;
const DESIRED_RETENTION: f32 = 0.90;

#[derive(Debug, PartialEq, Eq)]
pub(crate) enum FsrsInitOutcome {
    AlreadyMarked,
    AlreadyEnabled,
    MarkedExistingReviews,
    EnabledAndMarked,
}

pub(crate) fn marker_path(collection_path: &Path) -> PathBuf {
    let mut name = collection_path
        .file_name()
        .unwrap_or_default()
        .to_os_string();
    name.push(".hatto-fsrs-init");
    collection_path.with_file_name(name)
}

pub(crate) fn maybe_initialize(
    backend: &AnkiBackend,
    open: &anki_proto::collection::OpenCollectionRequest,
) -> Result<FsrsInitOutcome, String> {
    let collection = PathBuf::from(&open.collection_path);
    let marker = marker_path(&collection);
    if marker.is_file() {
        return Ok(FsrsInitOutcome::AlreadyMarked);
    }

    let configs = deck_configs(backend)?;
    if configs.fsrs {
        return Ok(FsrsInitOutcome::AlreadyEnabled);
    }
    let revlog_rows = revlog_count(backend)?;
    if revlog_rows >= 1 {
        write_marker_atomic(&marker)?;
        return Ok(FsrsInitOutcome::MarkedExistingReviews);
    }

    enable_fsrs(backend, &configs)?;
    write_marker_atomic(&marker)?;
    close_collection(backend)?;
    dispatch_message(backend, "BackendCollectionService", "open_collection", open)?;
    Ok(FsrsInitOutcome::EnabledAndMarked)
}

pub(crate) fn close_collection(backend: &AnkiBackend) -> Result<Vec<u8>, String> {
    dispatch_message(
        backend,
        "BackendCollectionService",
        "close_collection",
        &anki_proto::collection::CloseCollectionRequest {
            downgrade_to_schema11: false,
        },
    )
}

fn deck_configs(
    backend: &AnkiBackend,
) -> Result<anki_proto::deck_config::DeckConfigsForUpdate, String> {
    let bytes = dispatch_message(
        backend,
        "BackendDeckConfigService",
        "get_deck_configs_for_update",
        &anki_proto::decks::DeckId {
            did: DEFAULT_DECK_ID,
        },
    )?;
    anki_proto::deck_config::DeckConfigsForUpdate::decode(bytes.as_slice())
        .map_err(|err| format!("deck configs: {err}"))
}

fn enable_fsrs(
    backend: &AnkiBackend,
    configs: &anki_proto::deck_config::DeckConfigsForUpdate,
) -> Result<(), String> {
    let current = configs
        .current_deck
        .as_ref()
        .ok_or("default deck is missing from deck configs")?;
    let mut selected = configs
        .all_config
        .iter()
        .filter_map(|extra| extra.config.clone())
        .find(|config| config.id == current.config_id)
        .ok_or_else(|| format!("deck config {} is missing", current.config_id))?;
    let inner = selected
        .config
        .as_mut()
        .ok_or("deck config has no inner config")?;
    inner.desired_retention = DESIRED_RETENTION;
    inner.fsrs_params_4.clear();
    inner.fsrs_params_5.clear();
    inner.fsrs_params_6.clear();

    let request = anki_proto::deck_config::UpdateDeckConfigsRequest {
        target_deck_id: DEFAULT_DECK_ID,
        configs: vec![selected],
        removed_config_ids: Vec::new(),
        mode: anki_proto::deck_config::UpdateDeckConfigsMode::Normal as i32,
        card_state_customizer: configs.card_state_customizer.clone(),
        limits: current.limits.clone(),
        new_cards_ignore_review_limit: configs.new_cards_ignore_review_limit,
        fsrs: true,
        apply_all_parent_limits: configs.apply_all_parent_limits,
        fsrs_reschedule: false,
        fsrs_health_check: false,
    };
    dispatch_message(
        backend,
        "BackendDeckConfigService",
        "update_deck_configs",
        &request,
    )?;
    Ok(())
}

fn revlog_count(backend: &AnkiBackend) -> Result<i64, String> {
    let query = serde_json::json!({
        "kind": "query",
        "sql": "select count() from revlog",
        "args": [],
        "first_row_only": true,
    });
    let bytes = dispatch_message(
        backend,
        "BackendAnkidroidService",
        "run_db_command",
        &anki_proto::generic::Json {
            json: serde_json::to_vec(&query).map_err(|err| err.to_string())?,
        },
    )?;
    let decoded = anki_proto::generic::Json::decode(bytes.as_slice())
        .map_err(|err| format!("revlog count: {err}"))?;
    let value: serde_json::Value =
        serde_json::from_slice(&decoded.json).map_err(|err| format!("revlog count: {err}"))?;
    value
        .get(0)
        .and_then(|row| row.get(0))
        .and_then(|cell| cell.as_i64())
        .ok_or_else(|| format!("revlog count payload: {value}"))
}

/// Write `marker` by creating a sibling temporary file and renaming it.
pub(crate) fn write_marker_atomic(marker: &Path) -> Result<(), String> {
    let parent = marker
        .parent()
        .filter(|parent| !parent.as_os_str().is_empty())
        .ok_or("marker path has no directory")?;
    std::fs::create_dir_all(parent).map_err(|err| format!("marker dir: {err}"))?;
    let mut temporary_name = marker
        .file_name()
        .ok_or("marker path has no file name")?
        .to_os_string();
    temporary_name.push(".tmp");
    let temporary = marker.with_file_name(temporary_name);
    {
        let mut file = File::create(&temporary).map_err(|err| format!("marker temp: {err}"))?;
        file.write_all(b"hatto-fsrs-init\n")
            .map_err(|err| format!("marker temp: {err}"))?;
        file.sync_all()
            .map_err(|err| format!("marker temp: {err}"))?;
    }
    std::fs::rename(&temporary, marker).map_err(|err| format!("marker rename: {err}"))?;
    Ok(())
}

/// Insert one revlog row. Test setup for an existing SM-2 collection.
#[cfg(test)]
pub(crate) fn insert_revlog_row(backend: &AnkiBackend) -> Result<(), String> {
    let statement = serde_json::json!({
        "kind": "executemany",
        "sql": "insert into revlog (id, cid, usn, ease, ivl, lastIvl, factor, time, type) values (?, ?, ?, ?, ?, ?, ?, ?, ?)",
        "args": [[1, 1, -1, 3, 1, 0, 2500, 1000, 0]],
    });
    dispatch_message(
        backend,
        "BackendAnkidroidService",
        "run_db_command",
        &anki_proto::generic::Json {
            json: serde_json::to_vec(&statement).map_err(|err| err.to_string())?,
        },
    )?;
    Ok(())
}
