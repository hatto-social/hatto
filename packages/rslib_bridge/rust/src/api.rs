use std::path::PathBuf;

use anki::backend::init_backend;
use prost::Message;

use crate::index;

/// One rslib backend. Open at most one of these against a given collection file;
/// a second open fails with `DB_ERROR` (kind 5) because rslib takes an exclusive lock.
#[flutter_rust_bridge::frb(opaque)]
pub struct AnkiBackend {
    inner: anki::backend::Backend,
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
pub fn open_backend(init_msg: Vec<u8>) -> Result<AnkiBackend, String> {
    init_backend(&init_msg)
        .map(|inner| AnkiBackend { inner })
        .map_err(|err| err)
}

/// One protobuf backend call. `service` and `method` come from [service_method_index].
pub fn command(backend: &AnkiBackend, service: u32, method: u32, input: Vec<u8>) -> ProtoResponse {
    match backend.inner.run_service_method(service, method, &input) {
        Ok(payload) => ProtoResponse {
            success: true,
            payload,
        },
        Err(payload) => ProtoResponse {
            success: false,
            payload,
        },
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

fn call(
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

fn decode_backend_error(bytes: &[u8]) -> String {
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
}
