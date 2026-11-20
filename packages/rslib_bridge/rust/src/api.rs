// SPDX-FileCopyrightText: 2026 Hatto Social contributors
//
// SPDX-License-Identifier: AGPL-3.0-or-later

use std::path::PathBuf;
use std::sync::{Mutex, MutexGuard};

use anki::backend::init_backend;
use prost::Message;

use crate::index;
use crate::policy::{prepare_data_dir, DesktopSession};

/// Which calls an open backend will forward.
///
/// The profile is fixed for the life of the backend.
///
/// Not exported to Dart: flutter_rust_bridge 2.13 emits a freezed enum for
/// a variant that carries data, and this package does not take that
/// dependency. Dart opens a desktop backend through [open_desktop_backend].
#[flutter_rust_bridge::frb(ignore)]
#[derive(Debug, Clone)]
pub enum BridgeProfile {
    /// No allowlist yet. Every `(service, method)` is forwarded to rslib,
    /// which is the behavior `open_backend` has always had. The mobile
    /// allowlist is a later PR, before the mobile v0 release.
    MobileUnrestricted,
    /// Desktop v0. Calls are checked against the name table. A call with no
    /// implemented validator is denied and is not sent to rslib.
    Desktop { data_dir: String },
}

/// One rslib backend. Open at most one of these against a given collection file;
/// a second open fails with `DB_ERROR` (kind 5) because rslib takes an exclusive lock.
#[flutter_rust_bridge::frb(opaque)]
pub struct AnkiBackend {
    inner: anki::backend::Backend,
    profile: BridgeProfile,
    session: Mutex<DesktopSession>,
}

impl AnkiBackend {
    pub(crate) fn is_unrestricted(&self) -> bool {
        matches!(self.profile, BridgeProfile::MobileUnrestricted)
    }

    pub(crate) fn lock_session(&self) -> MutexGuard<'_, DesktopSession> {
        self.session.lock().unwrap_or_else(|err| err.into_inner())
    }
}

/// Bytes returned by `run_service_method`.
///
/// On failure, `payload` is an encoded `anki.backend.BackendError`.
pub struct ProtoResponse {
    pub success: bool,
    pub payload: Vec<u8>,
}

/// Index of one backend service method for this rslib build.
pub struct ServiceMethodIndex {
    pub service: u32,
    pub method: u32,
}

/// Called by the generated bridge when the Dart library loads.
#[flutter_rust_bridge::frb(init)]
pub fn init_app() {
    flutter_rust_bridge::setup_default_user_utils();
    // Logging is process setup, not a collection call. Ignore a second init.
    let _ = anki::log::set_global_logger(None);
}

/// Point rslib's temp files at an app-writable directory.
///
/// AnkiDroid sets `TMPDIR` to the cache dir for the same reason: export and
/// import call `std::env::temp_dir()`, which is not usable on Android.
/// Call this before other bridge functions, and not concurrently with them.
pub fn prepare_runtime(tmp_dir: String) {
    // SAFETY: the environment is process-global and not synchronized. The app
    // calls this once at startup, before rslib creates temp files.
    unsafe {
        std::env::set_var("TMPDIR", &tmp_dir);
        std::env::set_var("TMP", &tmp_dir);
        std::env::set_var("TEMP", &tmp_dir);
    }
}

/// `init_msg` is an encoded `anki.backend.BackendInit`. v0 passes `server = false`.
///
/// This stays unrestricted: it opens a [BridgeProfile::MobileUnrestricted]
/// backend. Existing mobile and `hatto_store` callers keep that behavior.
pub fn open_backend(init_msg: Vec<u8>) -> Result<AnkiBackend, String> {
    open_backend_with_profile(init_msg, BridgeProfile::MobileUnrestricted)
}

/// Open a backend and fix its call profile.
///
/// `Desktop` requires `data_dir` to be an existing absolute directory with no
/// `..` component. Later `command` calls on that backend use the desktop table.
///
/// Rust tests call this. Dart uses [open_desktop_backend] so the generated
/// bindings do not need a freezed enum.
#[flutter_rust_bridge::frb(ignore)]
pub fn open_backend_with_profile(
    init_msg: Vec<u8>,
    profile: BridgeProfile,
) -> Result<AnkiBackend, String> {
    let data_dir = match &profile {
        BridgeProfile::MobileUnrestricted => None,
        BridgeProfile::Desktop { data_dir } => Some(prepare_data_dir(data_dir)?),
    };
    let inner = init_backend(&init_msg).map_err(|err| err)?;
    Ok(AnkiBackend {
        inner,
        profile,
        session: Mutex::new(DesktopSession::new(data_dir)),
    })
}

/// Open a desktop-profile backend.
///
/// `data_dir` is the collection directory. This calls
/// [open_backend_with_profile] with [BridgeProfile::Desktop].
pub fn open_desktop_backend(init_msg: Vec<u8>, data_dir: String) -> Result<AnkiBackend, String> {
    open_backend_with_profile(init_msg, BridgeProfile::Desktop { data_dir })
}

/// One protobuf backend call. `service` and `method` come from [service_method_index].
///
/// An unrestricted backend forwards the bytes. A desktop backend denies the
/// call, without sending it to rslib, when the name is not allowed or its
/// validator is not implemented.
pub fn command(backend: &AnkiBackend, service: u32, method: u32, input: Vec<u8>) -> ProtoResponse {
    if backend.is_unrestricted() {
        return dispatch(backend, service, method, &input);
    }
    crate::policy::enforce(backend, service, method, input)
}

#[cfg(test)]
pub(crate) static LAST_OPEN_COLLECTION_INPUT: std::sync::Mutex<Option<Vec<u8>>> =
    std::sync::Mutex::new(None);

pub(crate) fn dispatch(
    backend: &AnkiBackend,
    service: u32,
    method: u32,
    input: &[u8],
) -> ProtoResponse {
    #[cfg(test)]
    if crate::index::reverse(service, method).is_some_and(|(_, method)| method == "open_collection")
    {
        *LAST_OPEN_COLLECTION_INPUT.lock().unwrap() = Some(input.to_vec());
    }
    // rslib can panic on a missing notetype (`GetClozeFieldOrds`). Catch that
    // here so the panic becomes a BackendError instead of killing the process.
    // A panic while rslib holds its collection mutex can still poison that
    // mutex; callers that can check the input first should do so.
    let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        backend.inner.run_service_method(service, method, input)
    }));
    match result {
        Ok(Ok(payload)) => ProtoResponse {
            success: true,
            payload,
        },
        Ok(Err(payload)) => ProtoResponse {
            success: false,
            payload,
        },
        Err(_) => {
            backend.lock_session().poisoned = true;
            backend_error("rslib panicked")
        }
    }
}

pub(crate) fn dispatch_message(
    backend: &AnkiBackend,
    service: &str,
    method: &str,
    message: &impl Message,
) -> Result<Vec<u8>, String> {
    let Some((service_index, method_index)) = index::lookup(service, method) else {
        return Err(format!(
            "no index for {service}.{method}; {}",
            index::describe_service(service)
        ));
    };
    let response = dispatch(
        backend,
        service_index,
        method_index,
        &message.encode_to_vec(),
    );
    if response.success {
        Ok(response.payload)
    } else {
        Err(decode_backend_error(&response.payload))
    }
}

pub(crate) fn backend_error(message: impl Into<String>) -> ProtoResponse {
    let err = anki_proto::backend::BackendError {
        message: message.into(),
        kind: anki_proto::backend::backend_error::Kind::InvalidInput as i32,
        help_page: None,
        context: String::new(),
        backtrace: String::new(),
    };
    ProtoResponse {
        success: false,
        payload: err.encode_to_vec(),
    }
}

/// Look up the dispatcher index for this pinned rslib tag.
///
/// Names are the protobuf service name (`BackendCollectionService`) and the
/// snake_case method name (`open_collection`).
#[flutter_rust_bridge::frb(sync)]
pub fn service_method_index(service: String, method: String) -> Option<ServiceMethodIndex> {
    index::lookup(&service, &method).map(|(service, method)| ServiceMethodIndex { service, method })
}

/// The rslib version string compiled into this binary (`26.09.3` for the pin).
#[flutter_rust_bridge::frb(sync)]
pub fn anki_version() -> String {
    anki::version::version().to_string()
}

/// `uuid5(namespace = job_id, name = source_guid UTF-8)`.
///
/// `job_id` is a UUID string. `source_guid` is not trimmed or normalized.
/// The returned text is the canonical lowercase hyphenated form. An empty
/// `source_guid` is an error. This calls `hatto_card_contract` and does not
/// reimplement the hash.
#[flutter_rust_bridge::frb(sync)]
pub fn imported_note_guid(job_id: String, source_guid: String) -> Result<String, String> {
    let job = hatto_card_contract::parse_uuid(&job_id).map_err(|err| err.to_string())?;
    let id = hatto_card_contract::imported_note_guid(job, &source_guid)
        .map_err(|err| err.to_string())?;
    Ok(hatto_card_contract::NoteGuid::from(id).to_string())
}

/// `uuid5(namespace = op_id, name = "note:{k}")`.
///
/// `op_id` is a UUID string. `k` is the zero-based index inside one write.
/// The returned text is the canonical lowercase hyphenated form.
#[flutter_rust_bridge::frb(sync)]
pub fn local_note_guid(op_id: String, k: u32) -> Result<String, String> {
    let op = hatto_card_contract::parse_uuid(&op_id).map_err(|err| err.to_string())?;
    Ok(hatto_card_contract::NoteGuid::from(hatto_card_contract::local_note_guid(op, k)).to_string())
}

/// Canonical lowercase hyphenated UUID with version nibble 4 or 5
/// and the RFC 4122 variant.
///
/// An AddNote guid check should call this instead of a separate pattern.
#[flutter_rust_bridge::frb(sync)]
pub fn is_guid_format(text: String) -> bool {
    hatto_card_contract::is_guid_format(&text)
}

/// One row of `deck_config` after prost-decoding the `config` blob.
///
/// `new_per_day` and `reviews_per_day` come from `DeckConfig.Config`. The
/// column is not JSON.
#[derive(Debug)]
pub struct DeckConfigRow {
    pub id: i64,
    pub name: String,
    pub new_per_day: u32,
    pub reviews_per_day: u32,
}

/// Export the collection in `dir` through `run_service_method`, then read the
/// package offline.
///
/// `collection.anki21b` is zstd-compressed SQLite. Each `deck_config.config`
/// value is a `DeckConfig.Config` protobuf.
pub fn inspect_exported_deck_configs(dir: String) -> Result<Vec<DeckConfigRow>, String> {
    crate::package_inspect::inspect_exported_deck_configs(dir)
}

/// Open a collection at `dir`, read deck names, and close it.
///
/// This is the host/Android smoke path: `BackendInit` and `OpenCollection` go
/// through the protobuf channel, then `GetDeckNames` confirms the collection is open.
/// `server` is false. Returns `anki <version>; server=false; decks=<names>`.
pub fn smoke_open_collection(dir: String) -> Result<String, String> {
    let root = PathBuf::from(&dir);
    std::fs::create_dir_all(&root).map_err(|err| err.to_string())?;
    let tmp = root.join("tmp");
    std::fs::create_dir_all(&tmp).map_err(|err| err.to_string())?;
    prepare_runtime(tmp.to_string_lossy().into_owned());

    let media = root.join("collection.media");
    std::fs::create_dir_all(&media).map_err(|err| err.to_string())?;
    let collection = root.join("collection.anki2");
    let media_db = root.join("collection.media.db");

    let init = anki_proto::backend::BackendInit {
        preferred_langs: vec!["en".into()],
        locale_folder_path: String::new(),
        server: false,
    };
    let backend = open_backend(init.encode_to_vec())?;

    let open = anki_proto::collection::OpenCollectionRequest {
        collection_path: collection.to_string_lossy().into_owned(),
        media_folder_path: media.to_string_lossy().into_owned(),
        media_db_path: media_db.to_string_lossy().into_owned(),
    };
    call(
        &backend,
        "BackendCollectionService",
        "open_collection",
        &open,
    )?;

    let names_req = anki_proto::decks::GetDeckNamesRequest {
        skip_empty_default: false,
        include_filtered: true,
    };
    let name_bytes = call(
        &backend,
        "BackendDecksService",
        "get_deck_names",
        &names_req,
    )?;
    let decoded = anki_proto::decks::DeckNames::decode(name_bytes.as_slice())
        .map_err(|err| err.to_string())?;
    let deck_names: Vec<String> = decoded
        .entries
        .into_iter()
        .map(|entry| entry.name)
        .collect();

    let close = anki_proto::collection::CloseCollectionRequest {
        downgrade_to_schema11: false,
    };
    call(
        &backend,
        "BackendCollectionService",
        "close_collection",
        &close,
    )?;

    Ok(format!(
        "anki {}; server=false; decks={}",
        anki::version::version(),
        deck_names.join(",")
    ))
}

pub(crate) fn call(
    backend: &AnkiBackend,
    service: &str,
    method: &str,
    message: &impl Message,
) -> Result<Vec<u8>, String> {
    let Some((service_index, method_index)) = index::lookup(service, method) else {
        return Err(format!(
            "no index for {service}.{method}; {}",
            index::describe_service(service)
        ));
    };
    let response = command(
        backend,
        service_index,
        method_index,
        message.encode_to_vec(),
    );
    if response.success {
        Ok(response.payload)
    } else {
        Err(decode_backend_error(&response.payload))
    }
}

pub(crate) fn decode_backend_error(bytes: &[u8]) -> String {
    match anki_proto::backend::BackendError::decode(bytes) {
        Ok(err) => format!("{} (kind={:?})", err.message, err.kind),
        Err(_) => format!("undecodable backend error ({} bytes)", bytes.len()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use prost::Message;

    #[test]
    fn opens_collection_through_protobuf_channel() {
        // The smoke helper points TMPDIR at the collection. Later tests must
        // not create their directories through that process-global temp dir.
        let dir = tempfile::TempDir::new_in("/tmp").unwrap();
        let summary =
            smoke_open_collection(dir.path().to_string_lossy().into_owned()).expect("smoke open");
        assert!(
            summary.starts_with("anki 26.09.3; server=false;"),
            "{summary}"
        );
        assert!(
            summary.contains("decks=")
                && summary
                    .split("decks=")
                    .nth(1)
                    .unwrap()
                    .split(',')
                    .any(|name| name == "Default"),
            "{summary}"
        );
        let collection = dir.path().join("collection.anki2");
        assert!(collection.is_file());
        assert!(std::fs::metadata(&collection).unwrap().len() > 0);
    }

    #[test]
    fn second_backend_cannot_open_the_same_collection() {
        let dir = tempfile::TempDir::new_in("/tmp").unwrap();
        let root = dir.path();
        std::fs::create_dir_all(root.join("collection.media")).unwrap();
        std::fs::create_dir_all(root.join("tmp")).unwrap();
        prepare_runtime(root.join("tmp").to_string_lossy().into_owned());

        let init = anki_proto::backend::BackendInit {
            preferred_langs: vec!["en".into()],
            locale_folder_path: String::new(),
            server: false,
        };
        let init_bytes = init.encode_to_vec();
        let open = anki_proto::collection::OpenCollectionRequest {
            collection_path: root.join("collection.anki2").to_string_lossy().into_owned(),
            media_folder_path: root.join("collection.media").to_string_lossy().into_owned(),
            media_db_path: root
                .join("collection.media.db")
                .to_string_lossy()
                .into_owned(),
        };
        let open_bytes = open.encode_to_vec();
        let index =
            service_method_index("BackendCollectionService".into(), "open_collection".into())
                .expect("open_collection index");

        let first = open_backend(init_bytes.clone()).unwrap();
        let opened = command(&first, index.service, index.method, open_bytes.clone());
        assert!(opened.success, "{}", decode_backend_error(&opened.payload));

        let second = open_backend(init_bytes).unwrap();
        let denied = command(&second, index.service, index.method, open_bytes);
        assert!(!denied.success, "second open should fail");
        let err = anki_proto::backend::BackendError::decode(denied.payload.as_slice()).unwrap();
        assert_eq!(err.kind, 5, "DB_ERROR, message={}", err.message);
    }

    #[test]
    fn note_guid_bridge_matches_the_contract_golden_file() {
        let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../../hatto_card_contract/fixtures/note_guid_golden.json");
        let text = std::fs::read_to_string(&path).unwrap_or_else(|err| panic!("{path:?}: {err}"));
        let file: serde_json::Value = serde_json::from_str(&text).unwrap();
        for case in file["imported"].as_array().unwrap() {
            let job_id = case["job_id"].as_str().unwrap().to_string();
            let source = case["source_guid"].as_str().unwrap().to_string();
            let derived = imported_note_guid(job_id, source);
            if case["error"] == "empty_source_guid" {
                assert!(derived.is_err(), "{}", case["label"]);
                continue;
            }
            assert_eq!(
                derived.unwrap(),
                case["expect"].as_str().unwrap(),
                "{}",
                case["label"]
            );
        }
        for case in file["local"].as_array().unwrap() {
            let op_id = case["op_id"].as_str().unwrap().to_string();
            let k = case["k"].as_u64().unwrap() as u32;
            assert_eq!(
                local_note_guid(op_id, k).unwrap(),
                case["expect"].as_str().unwrap()
            );
        }
        assert!(is_guid_format(
            "886313e1-3b8a-5372-9b90-0c9aee199e5d".into()
        ));
        assert!(!is_guid_format("hattoDummy".into()));
    }
}
