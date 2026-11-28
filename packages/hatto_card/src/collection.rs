// SPDX-FileCopyrightText: 2026 Hatto Social contributors
//
// SPDX-License-Identifier: AGPL-3.0-or-later

//! Temp-collection access for generating a package.
//!
//! Every collection is a `tempfile` directory created here. There is no
//! argument that points at a user's collection. Calls go through
//! `rslib_bridge`'s unrestricted backend (`open_backend`, then
//! `run_service_method` by service and method name).

use std::collections::HashMap;
use std::fs;
use std::path::Path;
use std::sync::{Mutex, MutexGuard};

use anki_proto::generic;
use prost::Message;
use rslib_bridge::api::{
    command, open_backend, prepare_runtime, service_method_index, AnkiBackend,
};
use rslib_bridge::export_contract::anki_package_export_request;

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
///
/// `inspect` uses the same guard. Both callers hold [`runtime_lock`]
/// until after this value drops.
pub(crate) struct TmpEnv {
    saved: [(&'static str, Option<String>); 3],
}

impl TmpEnv {
    pub(crate) fn set(dir: &Path) -> Self {
        let saved = ["TMPDIR", "TMP", "TEMP"].map(|key| (key, std::env::var(key).ok()));
        prepare_runtime(dir.to_string_lossy().into_owned());
        Self { saved }
    }
}

impl Drop for TmpEnv {
    fn drop(&mut self) {
        for (key, value) in &self.saved {
            // SAFETY: the environment is process-global. Callers hold
            // `runtime_lock` until after this value drops (`Session` and
            // `inspect_path`), and no other collection or inspect call is
            // in progress.
            match value {
                Some(value) => unsafe { std::env::set_var(key, value) },
                None => unsafe { std::env::remove_var(key) },
            }
        }
    }
}

pub(crate) fn runtime_lock() -> MutexGuard<'static, ()> {
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

    /// Import the committed seed package into this empty temporary collection,
    /// then delete its notes. The notetypes stay, with their fixed ids.
    pub(crate) fn load_seed(&self, seed: &[u8]) -> Result<(), String> {
        let dir = tempfile::TempDir::new().map_err(|err| err.to_string())?;
        let path = dir.path().join("hatto-seed.apkg");
        fs::write(&path, seed).map_err(|err| err.to_string())?;
        let request = anki_proto::import_export::ImportAnkiPackageRequest {
            package_path: path.to_string_lossy().into_owned(),
            options: Some(anki_proto::import_export::ImportAnkiPackageOptions {
                merge_notetypes: false,
                update_notes: anki_proto::import_export::ImportAnkiPackageUpdateCondition::Never
                    as i32,
                update_notetypes: anki_proto::import_export::ImportAnkiPackageUpdateCondition::Never
                    as i32,
                with_scheduling: false,
                with_deck_configs: false,
            }),
        };
        self.call_raw(
            "BackendImportExportService",
            "import_anki_package",
            &request,
        )?;
        let found: anki_proto::search::SearchResponse = self.call(
            "BackendSearchService",
            "search_notes",
            &anki_proto::search::SearchRequest {
                search: String::new(),
                order: None,
            },
        )?;
        self.call_raw(
            "BackendNotesService",
            "remove_notes",
            &anki_proto::notes::RemoveNotesRequest {
                note_ids: found.ids,
                card_ids: Vec::new(),
            },
        )?;
        Ok(())
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
        field_count_matches(note, fresh.fields.len())?;
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

    /// Rejects notes whose field count is not the one rslib builds for that
    /// note's notetype. Each distinct notetype is resolved once.
    ///
    /// Callers must already have rejected non-seed notetype names. A lookup
    /// failure is still a backend string. A count mismatch is [`FieldCountError`].
    pub(crate) fn check_note_fields(&self, notes: &[DerivedNote]) -> Result<(), FieldCheckError> {
        let mut counts: HashMap<String, usize> = HashMap::new();
        let mut mismatches = Vec::new();
        for note in notes {
            let name = crate::seed::canonical_notetype(&note.notetype);
            let count = if let Some(count) = counts.get(name) {
                *count
            } else {
                let ntid = self.notetype_id(name).map_err(FieldCheckError::Backend)?;
                let fresh: anki_proto::notes::Note = self
                    .call(
                        "BackendNotesService",
                        "new_note",
                        &anki_proto::notetypes::NotetypeId { ntid },
                    )
                    .map_err(FieldCheckError::Backend)?;
                let count = fresh.fields.len();
                counts.insert(name.to_string(), count);
                count
            };
            if note.fields.len() != count {
                mismatches.push(FieldCountError {
                    location: note.location.clone(),
                    found: note.fields.len(),
                    expected: count,
                });
            }
        }
        if mismatches.is_empty() {
            Ok(())
        } else {
            Err(FieldCheckError::Counts(mismatches))
        }
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

fn field_count_matches(note: &DerivedNote, count: usize) -> Result<(), String> {
    if note.fields.len() == count {
        return Ok(());
    }
    Err(format!(
        "{} has {} fields and the notetype has {}",
        note.location,
        note.fields.len(),
        count
    ))
}

pub(crate) struct FieldCountError {
    pub location: String,
    pub found: usize,
    pub expected: usize,
}

pub(crate) enum FieldCheckError {
    Backend(String),
    Counts(Vec<FieldCountError>),
}

fn decode_backend_error(bytes: &[u8]) -> String {
    match anki_proto::backend::BackendError::decode(bytes) {
        Ok(err) => format!("{} (kind={:?})", err.message, err.kind),
        Err(_) => "undecodable backend error".into(),
    }
}
