// SPDX-FileCopyrightText: 2026 Hatto Social contributors
//
// SPDX-License-Identifier: AGPL-3.0-or-later

//! Temp-collection access for the CLI.
//!
//! Every collection is a `tempfile` directory created here. There is no
//! argument that points at a user's collection. Calls go through
//! `rslib_bridge`'s unrestricted backend (`open_backend`, then
//! `run_service_method` by service and method name).

use std::fs;
use std::path::{Path, PathBuf};
use std::sync::{Mutex, MutexGuard};

use anki_proto::generic;
use prost::Message;
use rslib_bridge::api::{command, open_backend, prepare_runtime, service_method_index, AnkiBackend};
use rslib_bridge::export_contract::{anki_package_export_request, anki_package_import_options};
use serde_json::{json, Value};

use crate::deck::DerivedNote;

pub struct Session {
    // Declared first so it drops last, after the temp dir is restored.
    _lock: MutexGuard<'static, ()>,
    // Restores TMPDIR after `backend` drops and before `_lock` drops.
    _tmp_env: TmpEnv,
    backend: AnkiBackend,
    media_dir: PathBuf,
}

/// `prepare_runtime` points the process temp dir at the collection. Put the
/// previous values back so the next `tempfile` directory is not created
/// inside a folder this session is about to delete.
struct TmpEnv {
    saved: [(&'static str, Option<String>); 3],
}

impl TmpEnv {
    fn set(dir: &Path) -> Self {
        let saved = ["TMPDIR", "TMP", "TEMP"].map(|key| (key, std::env::var(key).ok()));
        prepare_runtime(dir.to_string_lossy().into_owned());
        Self { saved }
    }
}

impl Drop for TmpEnv {
    fn drop(&mut self) {
        for (key, value) in &self.saved {
            // SAFETY: the environment is process-global. The session lock is
            // still held (this value drops before the lock), and no other
            // collection call is in progress.
            match value {
                Some(value) => unsafe { std::env::set_var(key, value) },
                None => unsafe { std::env::remove_var(key) },
            }
        }
    }
}

fn runtime_lock() -> MutexGuard<'static, ()> {
    static LOCK: Mutex<()> = Mutex::new(());
    LOCK.lock().unwrap_or_else(|err| err.into_inner())
}

impl Session {
    pub fn open(root: &Path) -> Result<Self, String> {
        let guard = runtime_lock();
        let media_dir = root.join("media");
        fs::create_dir_all(&media_dir).map_err(|err| err.to_string())?;
        let tmp = root.join("tmp");
        fs::create_dir_all(&tmp).map_err(|err| err.to_string())?;
        let tmp_env = TmpEnv::set(&tmp);
        let init = anki_proto::backend::BackendInit {
            preferred_langs: vec!["en".into()],
            locale_folder_path: String::new(),
            server: false,
        };
        let backend = open_backend(init.encode_to_vec())?;
        let session = Self {
            _tmp_env: tmp_env,
            _lock: guard,
            backend,
            media_dir,
        };
        let open = anki_proto::collection::OpenCollectionRequest {
            collection_path: root.join("collection.anki2").to_string_lossy().into_owned(),
            media_folder_path: session.media_dir.to_string_lossy().into_owned(),
            media_db_path: root.join("media.db").to_string_lossy().into_owned(),
        };
        session.call_raw("BackendCollectionService", "open_collection", &open)?;
        Ok(session)
    }

    pub fn media_dir(&self) -> &Path {
        &self.media_dir
    }

    pub fn notetype_id(&self, name: &str) -> Result<i64, String> {
        let found: anki_proto::notetypes::NotetypeId = self.call(
            "BackendNotetypesService",
            "get_notetype_id_by_name",
            &generic::String { val: name.into() },
        )?;
        if found.ntid == 0 {
            return Err(format!("notetype {name} is missing"));
        }
        Ok(found.ntid)
    }

    #[cfg(test)]
    pub fn notetype_legacy(&self, notetype_id: i64) -> Result<Value, String> {
        let raw: generic::Json = self.call(
            "BackendNotetypesService",
            "get_notetype_legacy",
            &anki_proto::notetypes::NotetypeId { ntid: notetype_id },
        )?;
        serde_json::from_slice(&raw.json).map_err(|err| err.to_string())
    }

    pub fn add_notetype_legacy(&self, model: &Value) -> Result<i64, String> {
        let added: anki_proto::collection::OpChangesWithId = self.call(
            "BackendNotetypesService",
            "add_notetype_legacy",
            &generic::Json {
                json: serde_json::to_vec(model).map_err(|err| err.to_string())?,
            },
        )?;
        if added.id == 0 {
            return Err("add_notetype_legacy returned id 0".into());
        }
        Ok(added.id)
    }

    pub fn add_deck(&self, name: &str) -> Result<i64, String> {
        let mut deck: anki_proto::decks::Deck =
            self.call("BackendDecksService", "new_deck", &generic::Empty {})?;
        deck.name = name.into();
        let added: anki_proto::collection::OpChangesWithId =
            self.call("BackendDecksService", "add_deck", &deck)?;
        if added.id == 0 {
            return Err(format!("add_deck {name} returned id 0"));
        }
        Ok(added.id)
    }

    pub fn add_note(&self, notetype: i64, deck: i64, note: &DerivedNote) -> Result<i64, String> {
        let mut fresh: anki_proto::notes::Note = self.call(
            "BackendNotesService",
            "new_note",
            &anki_proto::notetypes::NotetypeId { ntid: notetype },
        )?;
        if fresh.fields.len() != note.fields.len() {
            return Err(format!(
                "{} has {} fields and the notetype has {}",
                note.location,
                note.fields.len(),
                fresh.fields.len()
            ));
        }
        // Replace the random guid before insert so the collection never stores it.
        fresh.guid = note.guid.clone();
        fresh.fields = note.fields.clone();
        fresh.tags = note.tags.clone();
        let added: anki_proto::notes::AddNoteResponse = self.call(
            "BackendNotesService",
            "add_note",
            &anki_proto::notes::AddNoteRequest {
                note: Some(fresh),
                deck_id: deck,
            },
        )?;
        if added.note_id == 0 {
            return Err(format!("add_note {} returned id 0", note.guid));
        }
        Ok(added.note_id)
    }

    pub fn add_media_file(&self, name: &str, data: &[u8]) -> Result<String, String> {
        let stored: generic::String = self.call(
            "BackendMediaService",
            "add_media_file",
            &anki_proto::media::AddMediaFileRequest {
                desired_name: name.into(),
                data: data.to_vec(),
            },
        )?;
        if stored.val != name {
            return Err(format!("media {name} was stored as {}", stored.val));
        }
        Ok(stored.val)
    }

    /// Desktop-contract export: one deck, flags from [anki_package_export_request].
    pub fn export_deck(&self, path: &Path, deck_id: i64) -> Result<(), String> {
        let request = anki_package_export_request(path.to_string_lossy().into_owned(), deck_id);
        self.call_raw(
            "BackendImportExportService",
            "export_anki_package",
            &request,
        )?;
        if !path.is_file() {
            return Err(format!("export did not write {}", path.display()));
        }
        Ok(())
    }

    pub fn import_apkg(
        &self,
        path: &Path,
    ) -> Result<anki_proto::import_export::ImportResponse, String> {
        self.call(
            "BackendImportExportService",
            "import_anki_package",
            &anki_proto::import_export::ImportAnkiPackageRequest {
                package_path: path.to_string_lossy().into_owned(),
                options: Some(anki_package_import_options()),
            },
        )
    }

    pub fn deck_names(&self) -> Result<Vec<String>, String> {
        let names: anki_proto::decks::DeckNames = self.call(
            "BackendDecksService",
            "get_deck_names",
            &anki_proto::decks::GetDeckNamesRequest {
                skip_empty_default: false,
                include_filtered: true,
            },
        )?;
        Ok(names.entries.into_iter().map(|entry| entry.name).collect())
    }

    pub fn get_note(&self, note_id: i64) -> Result<anki_proto::notes::Note, String> {
        self.call(
            "BackendNotesService",
            "get_note",
            &anki_proto::notes::NoteId { nid: note_id },
        )
    }

    /// Read-only SQL through `run_db_command`. Used for card queue and revlog
    /// counts, which have no protobuf counter.
    pub fn query(&self, sql: &str) -> Result<Value, String> {
        let request = json!({
            "kind": "query",
            "sql": sql,
            "args": [],
            "first_row_only": false,
        });
        let response: generic::Json = self.call(
            "BackendAnkidroidService",
            "run_db_command",
            &generic::Json {
                json: serde_json::to_vec(&request).map_err(|err| err.to_string())?,
            },
        )?;
        serde_json::from_slice(&response.json).map_err(|err| format!("db json {sql}: {err}"))
    }

    fn call<M: Message + Default>(
        &self,
        service: &str,
        method: &str,
        input: &impl Message,
    ) -> Result<M, String> {
        let bytes = self.call_raw(service, method, input)?;
        M::decode(bytes.as_slice()).map_err(|err| format!("decode {service}.{method}: {err}"))
    }

    fn call_raw(
        &self,
        service: &str,
        method: &str,
        input: &impl Message,
    ) -> Result<Vec<u8>, String> {
        let Some(index) = service_method_index(service.to_string(), method.to_string()) else {
            return Err(format!("no protobuf index for {service}.{method}"));
        };
        let response = command(
            &self.backend,
            index.service,
            index.method,
            input.encode_to_vec(),
        );
        if response.success {
            return Ok(response.payload);
        }
        Err(format!(
            "{service}.{method} failed: {}",
            decode_backend_error(&response.payload)
        ))
    }
}

impl Drop for Session {
    fn drop(&mut self) {
        let close = anki_proto::collection::CloseCollectionRequest {
            downgrade_to_schema11: false,
        };
        let _ = self.call_raw("BackendCollectionService", "close_collection", &close);
    }
}

fn decode_backend_error(bytes: &[u8]) -> String {
    match anki_proto::backend::BackendError::decode(bytes) {
        Ok(err) => format!("{} (kind={:?})", err.message, err.kind),
        Err(_) => "undecodable backend error".into(),
    }
}

/// Copy of a stock notetype, with `id` 0 and a new name, for
/// `add_notetype_legacy`. Opens a temp collection and closes it.
#[cfg(test)]
pub fn stock_notetype_legacy(from: &str, name: &str) -> Result<Value, String> {
    let tmp = tempfile::TempDir::new().map_err(|err| err.to_string())?;
    let session = Session::open(tmp.path())?;
    let id = session.notetype_id(from)?;
    let mut model = session.notetype_legacy(id)?;
    model["id"] = json!(0);
    model["name"] = json!(name);
    Ok(model)
}
