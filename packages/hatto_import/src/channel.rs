// SPDX-FileCopyrightText: 2026 Hatto Social contributors
//
// SPDX-License-Identifier: AGPL-3.0-or-later

//! Protobuf channel to rslib 26.09.3.
//!
//! Production code opens a collection only through [`ESession::open`], which
//! builds `import/e/<id>/collection.anki2` and opens it with
//! [`open_import_e_backend`] (the ImportE profile). It does not take a
//! collection path from the caller. The test harness opens its resident
//! collection with [`open_test_collection`] and the unrestricted backend.
//! This file does not point the process temp directory at an E folder.

use std::fs;
use std::path::{Path, PathBuf};

use anki_proto::collection::OpenCollectionRequest;
use anki_proto::generic;
use prost::Message;
#[cfg(test)]
use rslib_core::api::open_backend;
use rslib_core::api::{command, open_import_e_backend, service_method_index, AnkiBackend};
use serde_json::Value;
use uuid::Uuid;

use crate::error::ImportError;
use crate::paths::{e_collection_path, e_media_db_path, e_media_directory_path};

pub(crate) struct Session {
    backend: AnkiBackend,
    collection_path: PathBuf,
}

impl Session {
    fn open(
        backend: AnkiBackend,
        collection: &Path,
        media: &Path,
        media_db: &Path,
    ) -> Result<Self, ImportError> {
        if let Some(parent) = collection.parent() {
            fs::create_dir_all(parent)
                .map_err(|err| ImportError::new(format!("{}: {err}", parent.display())))?;
        }
        fs::create_dir_all(media)
            .map_err(|err| ImportError::new(format!("{}: {err}", media.display())))?;
        let session = Self {
            backend,
            collection_path: collection.to_path_buf(),
        };
        let open = OpenCollectionRequest {
            collection_path: collection.to_string_lossy().into_owned(),
            media_folder_path: media.to_string_lossy().into_owned(),
            media_db_path: media_db.to_string_lossy().into_owned(),
        };
        session.call_raw("BackendCollectionService", "open_collection", &open)?;
        Ok(session)
    }

    pub(crate) fn call<M: Message + Default>(
        &self,
        service: &str,
        method: &str,
        input: &impl Message,
    ) -> Result<M, ImportError> {
        let bytes = self.call_raw(service, method, input)?;
        M::decode(bytes.as_slice())
            .map_err(|err| ImportError::new(format!("decode {service}.{method}: {err}")))
    }

    pub(crate) fn call_raw(
        &self,
        service: &str,
        method: &str,
        input: &impl Message,
    ) -> Result<Vec<u8>, ImportError> {
        let Some(index) = service_method_index(service.to_string(), method.to_string()) else {
            return Err(ImportError::new(format!(
                "no protobuf index for {service}.{method}"
            )));
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
        Err(decode_backend_error(&response.payload, service, method))
    }

    pub(crate) fn db_json(&self, body: &Value) -> Result<Value, ImportError> {
        let encoded = serde_json::to_vec(body)
            .map_err(|err| ImportError::new(format!("db request: {err}")))?;
        let response: generic::Json = self.call(
            "BackendAnkidroidService",
            "run_db_command",
            &generic::Json { json: encoded },
        )?;
        if response.json.is_empty() {
            return Ok(Value::Null);
        }
        serde_json::from_slice(&response.json)
            .map_err(|err| ImportError::new(format!("db response: {err}")))
    }

    fn close(&self) {
        let close = anki_proto::collection::CloseCollectionRequest {
            downgrade_to_schema11: false,
        };
        let _ = self.call_raw("BackendCollectionService", "close_collection", &close);
    }
}

impl Drop for Session {
    fn drop(&mut self) {
        self.close();
    }
}

/// E collection. The only production opener. It opens
/// `import/e/<id>/collection.anki2` and nothing else.
pub(crate) struct ESession {
    inner: Session,
}

impl ESession {
    pub(crate) fn open(data_dir: &Path, batch_id: Uuid) -> Result<Self, ImportError> {
        let collection = e_collection_path(data_dir, batch_id)?;
        let media = e_media_directory_path(data_dir, batch_id)?;
        let media_db = e_media_db_path(data_dir, batch_id)?;
        let data_dir_text = data_dir
            .to_str()
            .ok_or_else(|| ImportError::new("data_dir is not utf-8"))?;
        let backend =
            open_import_e_backend(backend_init().encode_to_vec(), data_dir_text.to_owned())
                .map_err(ImportError::new)?;
        let inner = Session::open(backend, &collection, &media, &media_db)?;
        if inner.collection_path != collection {
            return Err(ImportError::new(
                "E session opened a path other than import/e/<id>/collection.anki2",
            ));
        }
        Ok(Self { inner })
    }

    pub(crate) fn call<M: Message + Default>(
        &self,
        service: &str,
        method: &str,
        input: &impl Message,
    ) -> Result<M, ImportError> {
        self.inner.call(service, method, input)
    }

    pub(crate) fn db_json(&self, body: &Value) -> Result<Value, ImportError> {
        self.inner.db_json(body)
    }

    /// Import the raw copy for this batch into this E collection.
    ///
    /// The package path is `import/raw/<id>.apkg` from the grammar. This is
    /// not a resident import.
    pub(crate) fn import_source_package(
        &self,
        data_dir: &Path,
        batch_id: Uuid,
    ) -> Result<(), ImportError> {
        let package = crate::paths::raw_apkg_path(data_dir, batch_id)?;
        let request = anki_proto::import_export::ImportAnkiPackageRequest {
            package_path: package.to_string_lossy().into_owned(),
            options: Some(anki_proto::import_export::ImportAnkiPackageOptions {
                merge_notetypes: false,
                update_notes: anki_proto::import_export::ImportAnkiPackageUpdateCondition::Never
                    as i32,
                update_notetypes: anki_proto::import_export::ImportAnkiPackageUpdateCondition::Never
                    as i32,
                with_scheduling: true,
                with_deck_configs: true,
            }),
        };
        let _response: anki_proto::import_export::ImportResponse = self.call(
            "BackendImportExportService",
            "import_anki_package",
            &request,
        )?;
        Ok(())
    }

    pub(crate) fn export_staged(
        &self,
        data_dir: &Path,
        batch_id: Uuid,
        with_deck_configs: bool,
    ) -> Result<(), ImportError> {
        let out = crate::paths::staged_apkg_path(data_dir, batch_id)?;
        if let Some(parent) = out.parent() {
            fs::create_dir_all(parent)
                .map_err(|err| ImportError::new(format!("{}: {err}", parent.display())))?;
        }
        let request = anki_proto::import_export::ExportAnkiPackageRequest {
            out_path: out.to_string_lossy().into_owned(),
            options: Some(anki_proto::import_export::ExportAnkiPackageOptions {
                with_scheduling: true,
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
        let _count: generic::UInt32 = self.call(
            "BackendImportExportService",
            "export_anki_package",
            &request,
        )?;
        if !out.is_file() {
            return Err(ImportError::new(format!(
                "export did not write {}",
                out.display()
            )));
        }
        Ok(())
    }
}

/// Resident collection for tests. Opens with the unrestricted backend.
///
/// Test harness only. Production [`ESession::open`] uses the ImportE profile.
#[cfg(test)]
pub(crate) fn open_test_collection(root: &Path) -> Result<Session, ImportError> {
    fs::create_dir_all(root)
        .map_err(|err| ImportError::new(format!("{}: {err}", root.display())))?;
    let collection = root.join("collection.anki2");
    let media = root.join("collection.media");
    let media_db = root.join("collection.media.db");
    let backend = open_backend(backend_init().encode_to_vec()).map_err(ImportError::new)?;
    Session::open(backend, &collection, &media, &media_db)
}

fn backend_init() -> anki_proto::backend::BackendInit {
    anki_proto::backend::BackendInit {
        preferred_langs: vec!["en".into()],
        locale_folder_path: String::new(),
        server: false,
    }
}

fn decode_backend_error(bytes: &[u8], service: &str, method: &str) -> ImportError {
    match anki_proto::backend::BackendError::decode(bytes) {
        Ok(err) => ImportError::from_backend(
            format!(
                "{service}.{method} failed: {} (kind={})",
                err.message, err.kind
            ),
            err.kind,
        ),
        Err(_) => ImportError::new(format!(
            "{service}.{method} failed: undecodable backend error"
        )),
    }
}
