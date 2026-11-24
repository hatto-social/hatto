// SPDX-FileCopyrightText: 2026 Hatto Social contributors
//
// SPDX-License-Identifier: AGPL-3.0-or-later

//! Read the package's Default deck config (id 1) and, on a first import,
//! attach that protobuf to a new preset on E.
//!
//! The package's id 1 row does not replace E's Default (`INSERT OR IGNORE`).
//! Deck id 1 on E stays on config id 1, so a whole-collection export does not
//! retarget the resident Default deck. Other decks that still use config id 1
//! are pointed at the new preset.

use std::fs;
use std::io::{Cursor, Read};
use std::path::{Path, PathBuf};

use anki_proto::deck_config::deck_config::Config as DeckConfigInner;
use prost::Message;
use rusqlite::Connection;
use uuid::Uuid;

use crate::channel::ESession;
use crate::error::ImportError;
use crate::paths::e_directory_path;

const ZSTD_MAGIC: [u8; 4] = [0x28, 0xB5, 0x2F, 0xFD];
const SQLITE_MAGIC: &[u8] = b"SQLite format 3\0";
const DEFAULT_CONFIG_ID: i64 = 1;
const DEFAULT_DECK_ID: i64 = 1;

pub(crate) fn restore_original_default_preset(
    session: &ESession,
    data_dir: &Path,
    batch_id: Uuid,
) -> Result<(), ImportError> {
    let targets = decks_using_default_config(session)?;
    if targets.is_empty() {
        return Ok(());
    }
    let Some((name, inner)) = read_default_preset(
        &crate::paths::raw_apkg_path(data_dir, batch_id)?,
        &e_directory_path(data_dir, batch_id)?,
    )?
    else {
        // Schema 11 (no deck_config, no id 1 row, or a JSON blob) has nothing
        // to copy. Decks that still point at config id 1 stay on E's Default.
        return Ok(());
    };
    let new_id = add_preset(session, targets[0], &name, inner)?;
    if new_id == DEFAULT_CONFIG_ID {
        return Err(ImportError::new("restored default preset kept config id 1"));
    }
    for deck_id in targets.iter().skip(1) {
        set_deck_config(session, *deck_id, new_id)?;
    }
    Ok(())
}

fn decks_using_default_config(session: &ESession) -> Result<Vec<i64>, ImportError> {
    let mut targets = Vec::new();
    for (deck_id, _name) in crate::pipeline::deck_entries(session)? {
        if deck_id == DEFAULT_DECK_ID {
            continue;
        }
        let deck = get_deck(session, deck_id)?;
        if normal_config_id(&deck) == Some(DEFAULT_CONFIG_ID) {
            targets.push(deck_id);
        }
    }
    Ok(targets)
}

fn add_preset(
    session: &ESession,
    target_deck_id: i64,
    name: &str,
    inner: DeckConfigInner,
) -> Result<i64, ImportError> {
    let current: anki_proto::deck_config::DeckConfigsForUpdate = session.call(
        "BackendDeckConfigService",
        "get_deck_configs_for_update",
        &anki_proto::decks::DeckId {
            did: target_deck_id,
        },
    )?;
    let limits = current
        .current_deck
        .as_ref()
        .and_then(|deck| deck.limits)
        .unwrap_or_default();
    let request = anki_proto::deck_config::UpdateDeckConfigsRequest {
        target_deck_id,
        configs: vec![anki_proto::deck_config::DeckConfig {
            id: 0,
            name: name.to_string(),
            mtime_secs: 0,
            usn: 0,
            config: Some(inner),
        }],
        removed_config_ids: Vec::new(),
        mode: anki_proto::deck_config::UpdateDeckConfigsMode::Normal as i32,
        card_state_customizer: current.card_state_customizer,
        limits: Some(limits),
        new_cards_ignore_review_limit: current.new_cards_ignore_review_limit,
        fsrs: current.fsrs,
        apply_all_parent_limits: current.apply_all_parent_limits,
        fsrs_reschedule: false,
        fsrs_health_check: current.fsrs_health_check,
    };
    let _changes: anki_proto::collection::OpChanges =
        session.call("BackendDeckConfigService", "update_deck_configs", &request)?;
    let deck = get_deck(session, target_deck_id)?;
    normal_config_id(&deck).ok_or_else(|| {
        ImportError::new(format!(
            "deck {target_deck_id} has no normal config after restore"
        ))
    })
}

pub(crate) fn get_deck(
    session: &ESession,
    deck_id: i64,
) -> Result<anki_proto::decks::Deck, ImportError> {
    session.call(
        "BackendDecksService",
        "get_deck",
        &anki_proto::decks::DeckId { did: deck_id },
    )
}

pub(crate) fn set_deck_config(
    session: &ESession,
    deck_id: i64,
    config_id: i64,
) -> Result<(), ImportError> {
    let mut deck = get_deck(session, deck_id)?;
    match deck.kind {
        Some(anki_proto::decks::deck::Kind::Normal(ref mut normal)) => {
            normal.config_id = config_id;
        }
        _ => {
            return Err(ImportError::new(format!(
                "deck {deck_id} is not a normal deck"
            )));
        }
    }
    let _changes: anki_proto::collection::OpChanges =
        session.call("BackendDecksService", "update_deck", &deck)?;
    Ok(())
}

pub(crate) fn normal_config_id(deck: &anki_proto::decks::Deck) -> Option<i64> {
    match deck.kind {
        Some(anki_proto::decks::deck::Kind::Normal(ref normal)) => Some(normal.config_id),
        _ => None,
    }
}

pub(crate) fn clear_deck_description(session: &ESession, deck_id: i64) -> Result<(), ImportError> {
    let mut deck = get_deck(session, deck_id)?;
    match deck.kind {
        Some(anki_proto::decks::deck::Kind::Normal(ref mut normal)) => {
            if normal.description.is_empty() {
                return Ok(());
            }
            normal.description.clear();
        }
        _ => return Ok(()),
    }
    let _changes: anki_proto::collection::OpChanges =
        session.call("BackendDecksService", "update_deck", &deck)?;
    Ok(())
}

fn read_default_preset(
    apkg: &Path,
    scratch_dir: &Path,
) -> Result<Option<(String, DeckConfigInner)>, ImportError> {
    let sqlite = read_package_sqlite(apkg)?;
    if !sqlite.starts_with(SQLITE_MAGIC) {
        return Err(ImportError::new(
            "package collection is not a SQLite database",
        ));
    }
    let scratch: PathBuf = scratch_dir.join("_preset_src.sqlite");
    fs::write(&scratch, &sqlite)
        .map_err(|err| ImportError::new(format!("{}: {err}", scratch.display())))?;
    let read = (|| {
        let conn = Connection::open(&scratch)
            .map_err(|err| ImportError::new(format!("open package collection: {err}")))?;
        let prepared = conn.prepare("SELECT name, config FROM deck_config WHERE id = 1");
        let mut stmt = match prepared {
            Ok(stmt) => stmt,
            Err(err) if missing_deck_config_table(&err) => return Ok(None),
            Err(err) => {
                return Err(ImportError::new(format!("deck_config id 1: {err}")));
            }
        };
        let mut rows = stmt
            .query([])
            .map_err(|err| ImportError::new(format!("deck_config id 1: {err}")))?;
        let Some(row) = rows
            .next()
            .map_err(|err| ImportError::new(format!("deck_config id 1: {err}")))?
        else {
            return Ok(None);
        };
        let name: String = row
            .get(0)
            .map_err(|err| ImportError::new(format!("deck_config name: {err}")))?;
        let config: Vec<u8> = row
            .get(1)
            .map_err(|err| ImportError::new(format!("deck_config config: {err}")))?;
        if config.first() == Some(&b'{') {
            return Ok(None);
        }
        let inner = DeckConfigInner::decode(config.as_slice())
            .map_err(|err| ImportError::new(format!("decode package default preset: {err}")))?;
        Ok(Some((name, inner)))
    })();
    let _ = fs::remove_file(&scratch);
    read
}

fn missing_deck_config_table(err: &rusqlite::Error) -> bool {
    err.to_string().contains("no such table")
}

fn read_package_sqlite(apkg: &Path) -> Result<Vec<u8>, ImportError> {
    let file = fs::File::open(apkg)
        .map_err(|err| ImportError::new(format!("{}: {err}", apkg.display())))?;
    let mut archive =
        zip::ZipArchive::new(file).map_err(|err| ImportError::new(format!("open apkg: {err}")))?;
    for name in [
        "collection.anki21b",
        "collection.anki21",
        "collection.anki2",
    ] {
        let mut entry = match archive.by_name(name) {
            Ok(entry) => entry,
            Err(_) => continue,
        };
        let mut bytes = Vec::new();
        entry
            .read_to_end(&mut bytes)
            .map_err(|err| ImportError::new(format!("{name}: {err}")))?;
        if name.ends_with("anki21b") {
            if !bytes.starts_with(&ZSTD_MAGIC) {
                return Err(ImportError::new("collection.anki21b is not a zstd frame"));
            }
            let sqlite = zstd::decode_all(Cursor::new(bytes))
                .map_err(|err| ImportError::new(format!("zstd: {err}")))?;
            return Ok(sqlite);
        }
        return Ok(bytes);
    }
    Err(ImportError::new(
        "apkg has no collection.anki21b, collection.anki21, or collection.anki2",
    ))
}

#[cfg(test)]
mod preset_reader_tests {
    use std::io::Write;

    use rusqlite::Connection;

    use super::read_default_preset;

    fn package(setup: impl FnOnce(&Connection)) -> tempfile::TempDir {
        let dir = tempfile::TempDir::new().unwrap();
        let db_path = dir.path().join("col.sqlite");
        {
            let conn = Connection::open(&db_path).unwrap();
            conn.execute_batch("CREATE TABLE IF NOT EXISTS hatto_touch (id integer)")
                .unwrap();
            setup(&conn);
        }
        let sqlite = std::fs::read(&db_path).unwrap();
        assert!(
            sqlite.starts_with(b"SQLite format 3"),
            "sqlite header missing, {} bytes",
            sqlite.len()
        );
        let apkg_path = dir.path().join("in.apkg");
        let file = std::fs::File::create(&apkg_path).unwrap();
        let mut zip = zip::ZipWriter::new(file);
        let options = zip::write::SimpleFileOptions::default()
            .compression_method(zip::CompressionMethod::Stored);
        zip.start_file("collection.anki2", options).unwrap();
        zip.write_all(&sqlite).unwrap();
        zip.finish().unwrap();
        dir
    }

    #[test]
    fn missing_table_missing_row_and_json_skip_and_bad_protobuf_fails() {
        let no_table = package(|_| {});
        let read = read_default_preset(&no_table.path().join("in.apkg"), no_table.path()).unwrap();
        assert!(read.is_none());

        let no_row = package(|conn| {
            conn.execute_batch("CREATE TABLE deck_config (id integer, name text, config blob)")
                .unwrap();
        });
        let read = read_default_preset(&no_row.path().join("in.apkg"), no_row.path()).unwrap();
        assert!(read.is_none());

        let json = package(|conn| {
            conn.execute_batch("CREATE TABLE deck_config (id integer, name text, config blob)")
                .unwrap();
            conn.execute(
                "INSERT INTO deck_config (id, name, config) VALUES (1, 'Default', ?1)",
                [br#"{"name":"Default"}"#.as_slice()],
            )
            .unwrap();
        });
        let read = read_default_preset(&json.path().join("in.apkg"), json.path()).unwrap();
        assert!(read.is_none());

        let garbage = package(|conn| {
            conn.execute_batch("CREATE TABLE deck_config (id integer, name text, config blob)")
                .unwrap();
            conn.execute(
                "INSERT INTO deck_config (id, name, config) VALUES (1, 'Default', ?1)",
                [b"not-protobuf".as_slice()],
            )
            .unwrap();
        });
        let err = read_default_preset(&garbage.path().join("in.apkg"), garbage.path()).unwrap_err();
        assert!(err.to_string().contains("decode"), "{err}");
    }
}
