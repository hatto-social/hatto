// SPDX-FileCopyrightText: 2026 Hatto Social contributors
//
// SPDX-License-Identifier: AGPL-3.0-or-later

//! Temp-collection access for generating a package.
//!
//! Every collection is a `tempfile` directory created here. There is no
//! argument that points at a user's collection. Calls go through
//! `rslib_bridge`'s unrestricted backend (`open_backend`, then
//! `run_service_method` by service and method name).

use std::fs;
use std::path::Path;
use std::sync::{Mutex, MutexGuard};

use anki_proto::generic;
use prost::Message;
use rslib_bridge::api::{
    command, open_backend, prepare_runtime, service_method_index, AnkiBackend,
};
use rslib_bridge::export_contract::anki_package_export_request;
use serde_json::Value;

use crate::deck::DerivedNote;

pub(crate) struct Session {
    // Declared first so it drops last, after the temp dir is restored.
    _lock: MutexGuard<'static, ()>,
    // Restores TMPDIR after `backend` drops and before `_lock` drops.
    _tmp_env: TmpEnv,
    backend: AnkiBackend,
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
    pub(crate) fn open(root: &Path) -> Result<Self, String> {
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
        };
        let open = anki_proto::collection::OpenCollectionRequest {
            collection_path: root.join("collection.anki2").to_string_lossy().into_owned(),
            media_folder_path: media_dir.to_string_lossy().into_owned(),
            media_db_path: root.join("media.db").to_string_lossy().into_owned(),
        };
        session.call_raw("BackendCollectionService", "open_collection", &open)?;
        Ok(session)
    }

    pub(crate) fn notetype_id(&self, name: &str) -> Result<i64, String> {
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

    pub(crate) fn add_notetype_legacy(&self, model: &Value) -> Result<i64, String> {
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

    pub(crate) fn add_deck(&self, name: &str) -> Result<i64, String> {
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

    pub(crate) fn add_note(
        &self,
        notetype: i64,
        deck: i64,
        note: &DerivedNote,
    ) -> Result<i64, String> {
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

    pub(crate) fn add_media_file(&self, name: &str, data: &[u8]) -> Result<(), String> {
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
        Ok(())
    }

    /// Desktop-contract export: one deck, flags from [anki_package_export_request].
    pub(crate) fn export_deck(&self, path: &Path, deck_id: i64) -> Result<(), String> {
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
