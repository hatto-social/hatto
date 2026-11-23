// SPDX-FileCopyrightText: 2026 Hatto Social contributors
//
// SPDX-License-Identifier: AGPL-3.0-or-later

//! Test collections. The resident collection is opened only here, with
//! [`crate::channel::open_test_collection`] (unrestricted `open_backend`).
//! Resident `import_anki_package` lives only in this file.

#![cfg(test)]

use std::collections::BTreeMap;
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::{Mutex, MutexGuard};

use anki_proto::generic;
use hatto_card_contract::NoteFacts;
use sha2::{Digest, Sha256};

use crate::channel::{open_test_collection, Session};
use crate::error::ImportError;
use crate::facts_from_stored_note;
use crate::prepare_import;
use crate::ImportLimits;
use crate::PreparedImport;
use crate::ResidentLookup;

pub(crate) fn lock_collections() -> MutexGuard<'static, ()> {
    static LOCK: Mutex<()> = Mutex::new(());
    LOCK.lock().unwrap_or_else(|err| err.into_inner())
}

pub(crate) fn test_limits() -> ImportLimits {
    // A test ceiling, not the product cap (O4).
    ImportLimits {
        max_bytes: 32 * 1024 * 1024,
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub(crate) struct Snapshot {
    pub tables: BTreeMap<String, String>,
    pub media: BTreeMap<String, String>,
}

pub(crate) struct TestCol {
    root: PathBuf,
    session: Session,
    imports: u32,
}

impl TestCol {
    pub(crate) fn open(root: &Path) -> Result<Self, ImportError> {
        let session = open_test_collection(root)?;
        Ok(Self {
            root: root.to_path_buf(),
            session,
            imports: 0,
        })
    }

    pub(crate) fn import_count(&self) -> u32 {
        self.imports
    }

    pub(crate) fn sql(
        &self,
        sql: &str,
        args: Vec<serde_json::Value>,
    ) -> Result<serde_json::Value, ImportError> {
        self.session.db_json(&serde_json::json!({
            "kind": "query",
            "sql": sql,
            "args": args,
            "first_row_only": false,
        }))
    }

    pub(crate) fn exec(&self, sql: &str, args: Vec<serde_json::Value>) -> Result<(), ImportError> {
        self.session.db_json(&serde_json::json!({
            "kind": "executemany",
            "sql": sql,
            "args": [args],
        }))?;
        Ok(())
    }

    pub(crate) fn add_deck(&self, name: &str) -> Result<i64, ImportError> {
        let mut deck: anki_proto::decks::Deck =
            self.session
                .call("BackendDecksService", "new_deck", &generic::Empty {})?;
        deck.name = name.to_string();
        let added: anki_proto::collection::OpChangesWithId =
            self.session
                .call("BackendDecksService", "add_deck", &deck)?;
        Ok(added.id)
    }

    pub(crate) fn notetype_id(&self, name: &str) -> Result<i64, ImportError> {
        let found: anki_proto::notetypes::NotetypeId = self.session.call(
            "BackendNotetypesService",
            "get_notetype_id_by_name",
            &generic::String { val: name.into() },
        )?;
        if found.ntid == 0 {
            return Err(ImportError::new(format!("notetype {name} is missing")));
        }
        Ok(found.ntid)
    }

    pub(crate) fn add_note(
        &self,
        notetype: i64,
        deck: i64,
        fields: &[&str],
        guid: &str,
    ) -> Result<i64, ImportError> {
        let mut note: anki_proto::notes::Note = self.session.call(
            "BackendNotesService",
            "new_note",
            &anki_proto::notetypes::NotetypeId { ntid: notetype },
        )?;
        if note.fields.len() != fields.len() {
            return Err(ImportError::new(format!(
                "notetype has {} fields, got {}",
                note.fields.len(),
                fields.len()
            )));
        }
        note.guid = guid.to_string();
        note.fields = fields.iter().map(|field| (*field).to_string()).collect();
        let added: anki_proto::notes::AddNoteResponse = self.session.call(
            "BackendNotesService",
            "add_note",
            &anki_proto::notes::AddNoteRequest {
                note: Some(note),
                deck_id: deck,
            },
        )?;
        Ok(added.note_id)
    }

    pub(crate) fn set_guid(&self, note_id: i64, guid: &str) -> Result<(), ImportError> {
        self.exec(
            "UPDATE notes SET guid = ? WHERE id = ?",
            vec![
                serde_json::Value::String(guid.into()),
                serde_json::json!(note_id),
            ],
        )
    }

    pub(crate) fn set_mod(&self, note_id: i64, mod_secs: i64) -> Result<(), ImportError> {
        self.exec(
            "UPDATE notes SET \"mod\" = ? WHERE id = ?",
            vec![serde_json::json!(mod_secs), serde_json::json!(note_id)],
        )
    }

    pub(crate) fn set_fields(&self, note_id: i64, fields: &[&str]) -> Result<(), ImportError> {
        let mut note: anki_proto::notes::Note = self.session.call(
            "BackendNotesService",
            "get_note",
            &anki_proto::notes::NoteId { nid: note_id },
        )?;
        if note.fields.len() != fields.len() {
            return Err(ImportError::new("field count does not match the note"));
        }
        note.fields = fields.iter().map(|field| (*field).to_string()).collect();
        let _changes: anki_proto::collection::OpChanges = self.session.call(
            "BackendNotesService",
            "update_notes",
            &anki_proto::notes::UpdateNotesRequest {
                notes: vec![note],
                skip_undo_entry: true,
            },
        )?;
        Ok(())
    }

    pub(crate) fn delete_cards(&self, note_id: i64) -> Result<(), ImportError> {
        self.exec(
            "DELETE FROM cards WHERE nid = ?",
            vec![serde_json::json!(note_id)],
        )
    }

    pub(crate) fn add_media(&self, name: &str, data: &[u8]) -> Result<(), ImportError> {
        let stored: generic::String = self.session.call(
            "BackendMediaService",
            "add_media_file",
            &anki_proto::media::AddMediaFileRequest {
                desired_name: name.into(),
                data: data.to_vec(),
            },
        )?;
        if stored.val != name {
            return Err(ImportError::new(format!(
                "media {name} was stored as {}",
                stored.val
            )));
        }
        Ok(())
    }

    pub(crate) fn export(
        &self,
        path: &Path,
        with_scheduling: bool,
        with_deck_configs: bool,
    ) -> Result<(), ImportError> {
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent).map_err(|err| ImportError::new(err.to_string()))?;
        }
        let request = anki_proto::import_export::ExportAnkiPackageRequest {
            out_path: path.to_string_lossy().into_owned(),
            options: Some(anki_proto::import_export::ExportAnkiPackageOptions {
                with_scheduling,
                with_deck_configs,
                with_media: true,
                legacy: false,
            }),
            limit: Some(anki_proto::import_export::ExportLimit {
                limit: Some(
                    anki_proto::import_export::export_limit::Limit::WholeCollection(
                        generic::Empty {},
                    ),
                ),
            }),
        };
        let _count: generic::UInt32 = self.session.call(
            "BackendImportExportService",
            "export_anki_package",
            &request,
        )?;
        Ok(())
    }

    /// Resident import with the contract's fixed options. Counts one call.
    pub(crate) fn import_resident(
        &mut self,
        path: &Path,
        with_deck_configs: bool,
    ) -> Result<anki_proto::import_export::ImportResponse, ImportError> {
        self.imports += 1;
        self.import_with(
            path,
            anki_proto::import_export::ImportAnkiPackageUpdateCondition::IfNewer as i32,
            with_deck_configs,
        )
    }

    pub(crate) fn import_for_read(&self, path: &Path) -> Result<(), ImportError> {
        let _response = self.import_with(
            path,
            anki_proto::import_export::ImportAnkiPackageUpdateCondition::Never as i32,
            true,
        )?;
        Ok(())
    }

    fn import_with(
        &self,
        path: &Path,
        update_notes: i32,
        with_deck_configs: bool,
    ) -> Result<anki_proto::import_export::ImportResponse, ImportError> {
        let request = anki_proto::import_export::ImportAnkiPackageRequest {
            package_path: path.to_string_lossy().into_owned(),
            options: Some(anki_proto::import_export::ImportAnkiPackageOptions {
                merge_notetypes: false,
                update_notes,
                update_notetypes: anki_proto::import_export::ImportAnkiPackageUpdateCondition::Never
                    as i32,
                with_scheduling: true,
                with_deck_configs,
            }),
        };
        self.session.call(
            "BackendImportExportService",
            "import_anki_package",
            &request,
        )
    }

    pub(crate) fn note_row(&self, guid: &str) -> Result<Option<NoteRow>, ImportError> {
        let rows = self.sql(
            "SELECT id, mid, \"mod\", usn, flds, tags FROM notes WHERE guid = ? ORDER BY id",
            vec![serde_json::Value::String(guid.into())],
        )?;
        let Some(rows) = rows.as_array() else {
            return Ok(None);
        };
        if rows.is_empty() {
            return Ok(None);
        }
        if rows.len() != 1 {
            return Err(ImportError::new(format!(
                "guid {guid} has {} resident notes",
                rows.len()
            )));
        }
        let cells = rows[0]
            .as_array()
            .ok_or_else(|| ImportError::new("note row"))?;
        Ok(Some(NoteRow {
            id: cells[0].as_i64().unwrap(),
            notetype_id: cells[1].as_i64().unwrap(),
            mod_secs: cells[2].as_i64().unwrap(),
            usn: cells[3].as_i64().unwrap(),
            flds: cells[4].as_str().unwrap().to_string(),
            tags: cells[5].as_str().unwrap().to_string(),
        }))
    }

    pub(crate) fn facts_for_guid(&self, guid: &str) -> Result<Option<NoteFacts>, ImportError> {
        let Some(row) = self.note_row(guid)? else {
            return Ok(None);
        };
        Ok(Some(facts_from_stored_note(
            guid,
            row.notetype_id,
            row.mod_secs,
            &row.flds,
            &row.tags,
        )))
    }

    pub(crate) fn deck_id_by_name(&self, name: &str) -> Result<Option<i64>, ImportError> {
        match self.session.call::<anki_proto::decks::DeckId>(
            "BackendDecksService",
            "get_deck_id_by_name",
            &generic::String { val: name.into() },
        ) {
            Ok(id) if id.did != 0 => Ok(Some(id.did)),
            Ok(_) => Ok(None),
            Err(err) if err.is_not_found() => Ok(None),
            Err(err) => Err(err),
        }
    }

    pub(crate) fn deck_names(&self) -> Result<Vec<String>, ImportError> {
        let names: anki_proto::decks::DeckNames = self.session.call(
            "BackendDecksService",
            "get_deck_names",
            &anki_proto::decks::GetDeckNamesRequest {
                skip_empty_default: false,
                include_filtered: true,
            },
        )?;
        Ok(names.entries.into_iter().map(|entry| entry.name).collect())
    }

    pub(crate) fn rename_deck(&self, deck_id: i64, name: &str) -> Result<(), ImportError> {
        let _changes: anki_proto::collection::OpChanges = self.session.call(
            "BackendDecksService",
            "rename_deck",
            &anki_proto::decks::RenameDeckRequest {
                deck_id,
                new_name: name.into(),
            },
        )?;
        Ok(())
    }

    pub(crate) fn set_description(
        &self,
        deck_id: i64,
        description: &str,
    ) -> Result<(), ImportError> {
        let mut deck: anki_proto::decks::Deck = self.session.call(
            "BackendDecksService",
            "get_deck",
            &anki_proto::decks::DeckId { did: deck_id },
        )?;
        match deck.kind {
            Some(anki_proto::decks::deck::Kind::Normal(ref mut normal)) => {
                normal.description = description.to_string();
            }
            _ => return Err(ImportError::new("deck is not normal")),
        }
        let _changes: anki_proto::collection::OpChanges =
            self.session
                .call("BackendDecksService", "update_deck", &deck)?;
        Ok(())
    }

    pub(crate) fn description(&self, deck_id: i64) -> Result<String, ImportError> {
        let deck: anki_proto::decks::Deck = self.session.call(
            "BackendDecksService",
            "get_deck",
            &anki_proto::decks::DeckId { did: deck_id },
        )?;
        match deck.kind {
            Some(anki_proto::decks::deck::Kind::Normal(normal)) => Ok(normal.description),
            _ => Ok(String::new()),
        }
    }

    pub(crate) fn config_id(&self, deck_id: i64) -> Result<i64, ImportError> {
        let deck: anki_proto::decks::Deck = self.session.call(
            "BackendDecksService",
            "get_deck",
            &anki_proto::decks::DeckId { did: deck_id },
        )?;
        match deck.kind {
            Some(anki_proto::decks::deck::Kind::Normal(normal)) => Ok(normal.config_id),
            _ => Err(ImportError::new("deck is not normal")),
        }
    }

    pub(crate) fn new_per_day(&self, config_id: i64) -> Result<u32, ImportError> {
        let config: anki_proto::deck_config::DeckConfig = self.session.call(
            "BackendDeckConfigService",
            "get_deck_config",
            &anki_proto::deck_config::DeckConfigId { dcid: config_id },
        )?;
        Ok(config.config.unwrap_or_default().new_per_day)
    }

    pub(crate) fn set_new_per_day(&self, deck_id: i64, per_day: u32) -> Result<(), ImportError> {
        let current: anki_proto::deck_config::DeckConfigsForUpdate = self.session.call(
            "BackendDeckConfigService",
            "get_deck_configs_for_update",
            &anki_proto::decks::DeckId { did: deck_id },
        )?;
        let config_id = current
            .current_deck
            .as_ref()
            .map(|deck| deck.config_id)
            .unwrap_or(1);
        let mut selected = current
            .all_config
            .iter()
            .filter_map(|extra| extra.config.clone())
            .find(|config| config.id == config_id)
            .ok_or_else(|| ImportError::new("deck config missing"))?;
        selected.config.as_mut().unwrap().new_per_day = per_day;
        let limits = current
            .current_deck
            .and_then(|deck| deck.limits)
            .unwrap_or_default();
        let _changes: anki_proto::collection::OpChanges = self.session.call(
            "BackendDeckConfigService",
            "update_deck_configs",
            &anki_proto::deck_config::UpdateDeckConfigsRequest {
                target_deck_id: deck_id,
                configs: vec![selected],
                removed_config_ids: Vec::new(),
                mode: anki_proto::deck_config::UpdateDeckConfigsMode::Normal as i32,
                card_state_customizer: current.card_state_customizer,
                limits: Some(limits),
                new_cards_ignore_review_limit: current.new_cards_ignore_review_limit,
                fsrs: current.fsrs,
                apply_all_parent_limits: current.apply_all_parent_limits,
                fsrs_reschedule: false,
                fsrs_health_check: current.fsrs_health_check,
            },
        )?;
        Ok(())
    }

    pub(crate) fn assign_fresh_preset(
        &self,
        deck_id: i64,
        per_day: u32,
    ) -> Result<i64, ImportError> {
        let current: anki_proto::deck_config::DeckConfigsForUpdate = self.session.call(
            "BackendDeckConfigService",
            "get_deck_configs_for_update",
            &anki_proto::decks::DeckId { did: deck_id },
        )?;
        let config_id = current
            .current_deck
            .as_ref()
            .map(|deck| deck.config_id)
            .unwrap_or(1);
        let mut selected = current
            .all_config
            .iter()
            .filter_map(|extra| extra.config.clone())
            .find(|config| config.id == config_id)
            .ok_or_else(|| ImportError::new("deck config missing"))?;
        selected.id = 0;
        selected.name = format!("Preset {per_day}");
        selected.config.as_mut().unwrap().new_per_day = per_day;
        let limits = current
            .current_deck
            .as_ref()
            .and_then(|deck| deck.limits)
            .unwrap_or_default();
        let _changes: anki_proto::collection::OpChanges = self.session.call(
            "BackendDeckConfigService",
            "update_deck_configs",
            &anki_proto::deck_config::UpdateDeckConfigsRequest {
                target_deck_id: deck_id,
                configs: vec![selected],
                removed_config_ids: Vec::new(),
                mode: anki_proto::deck_config::UpdateDeckConfigsMode::Normal as i32,
                card_state_customizer: current.card_state_customizer.clone(),
                limits: Some(limits),
                new_cards_ignore_review_limit: current.new_cards_ignore_review_limit,
                fsrs: current.fsrs,
                apply_all_parent_limits: current.apply_all_parent_limits,
                fsrs_reschedule: false,
                fsrs_health_check: current.fsrs_health_check,
            },
        )?;
        self.config_id(deck_id)
    }

    pub(crate) fn remove_deck(&self, deck_id: i64) -> Result<(), ImportError> {
        let _removed: anki_proto::collection::OpChangesWithCount = self.session.call(
            "BackendDecksService",
            "remove_decks",
            &anki_proto::decks::DeckIds {
                dids: vec![deck_id],
            },
        )?;
        Ok(())
    }

    pub(crate) fn remove_note(&self, note_id: i64) -> Result<(), ImportError> {
        let _removed: anki_proto::collection::OpChangesWithCount = self.session.call(
            "BackendNotesService",
            "remove_notes",
            &anki_proto::notes::RemoveNotesRequest {
                note_ids: vec![note_id],
                card_ids: Vec::new(),
            },
        )?;
        Ok(())
    }

    pub(crate) fn card_rows(&self, note_id: i64) -> Result<serde_json::Value, ImportError> {
        self.sql(
            "SELECT id, nid, did, ord, \"mod\", usn, type, queue, due, ivl, factor, reps, lapses, left, odue, odid, flags, data FROM cards WHERE nid = ? ORDER BY ord",
            vec![serde_json::json!(note_id)],
        )
    }

    pub(crate) fn revlog_for_card(&self, card_id: i64) -> Result<serde_json::Value, ImportError> {
        self.sql(
            "SELECT id, cid, usn, ease, ivl, lastIvl, factor, time, type FROM revlog WHERE cid = ? ORDER BY id",
            vec![serde_json::json!(card_id)],
        )
    }

    pub(crate) fn insert_revlog(
        &self,
        id: i64,
        card_id: i64,
        ease: i64,
    ) -> Result<(), ImportError> {
        self.exec(
            "INSERT INTO revlog (id, cid, usn, ease, ivl, lastIvl, factor, time, type) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
            vec![
                serde_json::json!(id),
                serde_json::json!(card_id),
                serde_json::json!(-1),
                serde_json::json!(ease),
                serde_json::json!(5),
                serde_json::json!(0),
                serde_json::json!(2500),
                serde_json::json!(1000),
                serde_json::json!(1),
            ],
        )?;
        self.exec(
            "UPDATE cards SET type = 2, queue = 2, due = 10, ivl = 5, factor = 2500, reps = 1, \"mod\" = 1700000000 WHERE id = ?",
            vec![serde_json::json!(card_id)],
        )?;
        Ok(())
    }

    pub(crate) fn snapshot(&self) -> Result<Snapshot, ImportError> {
        let mut tables = BTreeMap::new();
        for (name, sql) in SNAPSHOT_SQL {
            let value = self.sql(sql, Vec::new())?;
            tables.insert((*name).to_string(), serde_json::to_string(&value).unwrap());
        }
        let mut media = BTreeMap::new();
        let media_dir = self.root.join("collection.media");
        if media_dir.is_dir() {
            for entry in
                fs::read_dir(&media_dir).map_err(|err| ImportError::new(err.to_string()))?
            {
                let entry = entry.map_err(|err| ImportError::new(err.to_string()))?;
                if !entry
                    .file_type()
                    .map(|kind| kind.is_file())
                    .unwrap_or(false)
                {
                    continue;
                }
                let bytes =
                    fs::read(entry.path()).map_err(|err| ImportError::new(err.to_string()))?;
                let digest = Sha256::digest(&bytes);
                let name = entry.file_name().to_string_lossy().into_owned();
                media.insert(name, hex_encode(&digest));
            }
        }
        Ok(Snapshot { tables, media })
    }

    pub(crate) fn note_count(&self) -> Result<i64, ImportError> {
        let rows = self.sql("SELECT count(*) FROM notes", Vec::new())?;
        Ok(rows[0][0].as_i64().unwrap())
    }

    pub(crate) fn add_custom_notetype(&self, name: &str) -> Result<i64, ImportError> {
        let basic = self.notetype_id("Basic")?;
        let legacy: generic::Json = self.session.call(
            "BackendNotetypesService",
            "get_notetype_legacy",
            &anki_proto::notetypes::NotetypeId { ntid: basic },
        )?;
        let mut value: serde_json::Value = serde_json::from_slice(&legacy.json)
            .map_err(|err| ImportError::new(err.to_string()))?;
        value["id"] = serde_json::json!(0);
        value["name"] = serde_json::Value::String(name.into());
        let bytes = serde_json::to_vec(&value).map_err(|err| ImportError::new(err.to_string()))?;
        let added: anki_proto::collection::OpChangesWithId = self.session.call(
            "BackendNotetypesService",
            "add_notetype_legacy",
            &generic::Json { json: bytes },
        )?;
        Ok(added.id)
    }

    pub(crate) fn notetype_names(&self) -> Result<Vec<String>, ImportError> {
        let rows = self.sql("SELECT name FROM notetypes ORDER BY name", Vec::new())?;
        Ok(rows
            .as_array()
            .unwrap()
            .iter()
            .map(|row| row[0].as_str().unwrap().to_string())
            .collect())
    }

    pub(crate) fn add_filtered(&self, name: &str, search: &str) -> Result<i64, ImportError> {
        let mut fresh: anki_proto::decks::FilteredDeckForUpdate = self.session.call(
            "BackendDecksService",
            "get_or_create_filtered_deck",
            &anki_proto::decks::DeckId { did: 0 },
        )?;
        fresh.name = name.to_string();
        fresh.allow_empty = true;
        if let Some(config) = fresh.config.as_mut() {
            config.search_terms = vec![anki_proto::decks::deck::filtered::SearchTerm {
                search: search.to_string(),
                limit: 100,
                order: 5,
            }];
        }
        let added: anki_proto::collection::OpChangesWithId =
            self.session
                .call("BackendDecksService", "add_or_update_filtered_deck", &fresh)?;
        Ok(added.id)
    }
}

#[derive(Clone, Debug)]
pub(crate) struct NoteRow {
    pub id: i64,
    pub notetype_id: i64,
    pub mod_secs: i64,
    pub usn: i64,
    pub flds: String,
    pub tags: String,
}

pub(crate) struct ColLookup<'a> {
    pub col: &'a TestCol,
}

impl ResidentLookup for ColLookup<'_> {
    fn note_facts(&mut self, guid: &str) -> Result<Option<NoteFacts>, ImportError> {
        self.col.facts_for_guid(guid)
    }

    fn deck_id_by_name(&mut self, name: &str) -> Result<Option<i64>, ImportError> {
        self.col.deck_id_by_name(name)
    }
}

pub(crate) fn commit_import(
    data_dir: &Path,
    source: &Path,
    resident: &mut TestCol,
) -> Result<PreparedImport, ImportError> {
    let mut lookup = ColLookup { col: resident };
    let prepared = prepare_import(data_dir, source, test_limits(), &mut lookup)?;
    if !prepared.plan.no_resident_call {
        let response = resident.import_resident(&prepared.staged_path, prepared.first_import)?;
        let log = response.log.unwrap_or_default();
        if !log.conflicting.is_empty() {
            return Err(ImportError::new(format!(
                "resident import conflicting {}",
                log.conflicting.len()
            )));
        }
    }
    Ok(prepared)
}

const SNAPSHOT_SQL: &[(&str, &str)] = &[
    ("notes", "SELECT id, guid, mid, \"mod\", usn, tags, flds, sfld, csum, flags, data FROM notes ORDER BY id"),
    ("cards", "SELECT id, nid, did, ord, \"mod\", usn, type, queue, due, ivl, factor, reps, lapses, left, odue, odid, flags, data FROM cards ORDER BY id"),
    ("revlog", "SELECT id, cid, usn, ease, ivl, lastIvl, factor, time, type FROM revlog ORDER BY id"),
    ("decks", "SELECT id, name, mtime_secs, usn, common, kind FROM decks ORDER BY id"),
    ("notetypes", "SELECT id, name, mtime_secs, usn, config FROM notetypes ORDER BY id"),
    ("fields", "SELECT ntid, ord, name, config FROM fields ORDER BY ntid, ord"),
    ("templates", "SELECT ntid, ord, name, mtime_secs, usn, config FROM templates ORDER BY ntid, ord"),
    ("deck_config", "SELECT id, name, mtime_secs, usn, config FROM deck_config ORDER BY id"),
    ("config", "SELECT key, usn, mtime_secs, val FROM config ORDER BY key"),
    ("col", "SELECT id, crt, \"mod\", scm, ver, dty, usn, ls, conf, models, decks, dconf, tags FROM col"),
];

fn hex_encode(bytes: &[u8]) -> String {
    const HEX: &[u8; 16] = b"0123456789abcdef";
    let mut out = String::with_capacity(bytes.len() * 2);
    for byte in bytes {
        out.push(HEX[(byte >> 4) as usize] as char);
        out.push(HEX[(byte & 0x0f) as usize] as char);
    }
    out
}

pub(crate) fn tiny_png(byte: u8) -> Vec<u8> {
    let mut png = vec![
        0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00, 0x00, 0x00, 0x0d, 0x49, 0x48, 0x44,
        0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x08, 0x02, 0x00, 0x00, 0x00, 0x90,
        0x77, 0x53, 0xde, 0x00, 0x00, 0x00, 0x0c, 0x49, 0x44, 0x41, 0x54, 0x08, 0xd7, 0x63, 0xf8,
        0xcf, 0xc0, 0x00, 0x00, 0x00, 0x03, 0x00, 0x01, 0x00, 0x05, 0xfe, 0x02, 0xfe, 0x00, 0x00,
        0x00, 0x00, 0x49, 0x45, 0x4e, 0x44, 0xae, 0x42, 0x60, 0x82,
    ];
    png[40] = byte;
    png
}
