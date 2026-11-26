// SPDX-FileCopyrightText: 2026 Hatto Social contributors
//
// SPDX-License-Identifier: AGPL-3.0-or-later

//! flutter_rust_bridge surface. The channel and the call policy live in
//! `rslib_core`. These functions keep the names and signatures the Dart
//! bindings and `hatto_card` already call.

use prost::Message;

pub use rslib_core::api::BridgeProfile;
pub use rslib_core::AnkiBackend;

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

fn bridge_response(response: rslib_core::ProtoResponse) -> ProtoResponse {
    ProtoResponse {
        success: response.success,
        payload: response.payload,
    }
}

fn bridge_index(index: rslib_core::ServiceMethodIndex) -> ServiceMethodIndex {
    ServiceMethodIndex {
        service: index.service,
        method: index.method,
    }
}

/// Called by the generated bridge when the Dart library loads.
#[flutter_rust_bridge::frb(init)]
pub fn init_app() {
    flutter_rust_bridge::setup_default_user_utils();
    // Logging is process setup, not a collection call. Ignore a second init.
    rslib_core::api::install_anki_logger();
}

/// Point rslib's temp files at an app-writable directory.
///
/// AnkiDroid sets `TMPDIR` to the cache dir for the same reason: export and
/// import call `std::env::temp_dir()`, which is not usable on Android.
/// Call this before other bridge functions, and not concurrently with them.
pub fn prepare_runtime(tmp_dir: String) {
    rslib_core::api::prepare_runtime(tmp_dir);
}

/// `init_msg` is an encoded `anki.backend.BackendInit`. v0 passes `server = false`.
///
/// This stays unrestricted: it opens a [BridgeProfile::MobileUnrestricted]
/// backend. Existing mobile and `hatto_store` callers keep that behavior.
pub fn open_backend(init_msg: Vec<u8>) -> Result<AnkiBackend, String> {
    rslib_core::api::open_backend(init_msg)
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
    rslib_core::api::open_backend_with_profile(init_msg, profile)
}

/// Open a desktop-profile backend.
///
/// `data_dir` is the collection directory. This calls
/// [open_backend_with_profile] with [BridgeProfile::Desktop].
pub fn open_desktop_backend(init_msg: Vec<u8>, data_dir: String) -> Result<AnkiBackend, String> {
    rslib_core::api::open_desktop_backend(init_msg, data_dir)
}

/// Open an import-E backend.
///
/// `data_dir` is the collection directory, the same value a desktop backend
/// uses. This handle cannot open the resident collection. App call sites are
/// a later slice; this signature is the Rust entry.
#[flutter_rust_bridge::frb(ignore)]
pub fn open_import_e_backend(init_msg: Vec<u8>, data_dir: String) -> Result<AnkiBackend, String> {
    rslib_core::api::open_import_e_backend(init_msg, data_dir)
}

/// One protobuf backend call. `service` and `method` come from [service_method_index].
///
/// An unrestricted backend forwards the bytes. A desktop backend denies the
/// call, without sending it to rslib, when the name is not allowed or its
/// validator is not implemented.
pub fn command(backend: &AnkiBackend, service: u32, method: u32, input: Vec<u8>) -> ProtoResponse {
    bridge_response(rslib_core::api::command(backend, service, method, input))
}

/// Look up the dispatcher index for this pinned rslib tag.
///
/// Names are the protobuf service name (`BackendCollectionService`) and the
/// snake_case method name (`open_collection`).
#[flutter_rust_bridge::frb(sync)]
pub fn service_method_index(service: String, method: String) -> Option<ServiceMethodIndex> {
    rslib_core::api::service_method_index(service, method).map(bridge_index)
}

/// The rslib version string compiled into this binary (`26.09.3` for the pin).
#[flutter_rust_bridge::frb(sync)]
pub fn anki_version() -> String {
    rslib_core::api::anki_version()
}

/// `uuid5(namespace = job_id, name = source_guid UTF-8)`.
///
/// `job_id` is a UUID string. `source_guid` is not trimmed or normalized.
/// The returned text is the canonical lowercase hyphenated form. An empty
/// `source_guid` is an error. This calls `hatto_card_contract` and does not
/// reimplement the hash. Import calls this only with `job_id` equal to
/// `IMPORT_NS`. A per-job namespace is not used for import.
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
    Ok(
        hatto_card_contract::NoteGuid::from(hatto_card_contract::local_note_guid(op, k))
            .to_string(),
    )
}

/// Canonical lowercase hyphenated UUID with version nibble 4 or 5
/// and the RFC 4122 variant.
///
/// An AddNote guid check should call this instead of a separate pattern.
#[flutter_rust_bridge::frb(sync)]
pub fn is_guid_format(text: String) -> bool {
    hatto_card_contract::is_guid_format(&text)
}

/// One note from an import file, before guid assignment.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ImportSourceNote {
    pub source_note_id: i64,
    pub raw_guid: String,
}

/// Assigned guid for one import note.
///
/// `dup_index >= 1` or `reassigned` marks a duplicate.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct AssignedImportGuid {
    pub source_note_id: i64,
    pub guid: String,
    pub dup_index: u32,
    pub reassigned: bool,
}

/// Assign canonical import guids. Thin wrapper over `hatto_card_contract`.
///
/// The contract crate stays free of I/O and rslib. This does not open a
/// collection.
#[flutter_rust_bridge::frb(sync)]
pub fn assign_import_guids(notes: Vec<ImportSourceNote>) -> Vec<AssignedImportGuid> {
    let input: Vec<hatto_card_contract::ImportSourceNote> = notes
        .into_iter()
        .map(|note| hatto_card_contract::ImportSourceNote {
            source_note_id: note.source_note_id,
            raw_guid: note.raw_guid,
        })
        .collect();
    hatto_card_contract::assign_import_guids(&input)
        .into_iter()
        .map(|row| AssignedImportGuid {
            source_note_id: row.source_note_id,
            guid: row.guid,
            dup_index: row.dup_index,
            reassigned: row.reassigned,
        })
        .collect()
}

/// SHA-256 of normalized fields and tags. 32 bytes. Media bytes are not hashed.
#[flutter_rust_bridge::frb(sync)]
pub fn note_content_hash(fields: Vec<String>, tags: Vec<String>) -> Vec<u8> {
    hatto_card_contract::note_content_hash(&fields, &tags).to_vec()
}

/// Facts for one note after guid normalization.
///
/// `r#mod` is Anki's `mod` column. `mod` is a Rust keyword.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct NoteFacts {
    pub guid: String,
    pub notetype_id: i64,
    pub r#mod: i64,
    pub content_hash: Vec<u8>,
}

/// How one file note relates to the resident collection.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Class {
    New,
    Same,
    Changed,
    LocalNewer,
    Blocked,
}

/// Classify one file note. `content_hash` must be 32 bytes.
///
/// The order is the contract order: missing resident, notetype, content
/// hash, then `mod`.
#[flutter_rust_bridge::frb(sync)]
pub fn classify(file: NoteFacts, resident: Option<NoteFacts>) -> Result<Class, String> {
    let file = bridge_facts(file)?;
    let resident = resident.map(bridge_facts).transpose()?;
    Ok(from_contract_class(hatto_card_contract::classify(
        &file,
        resident.as_ref(),
    )))
}

/// Counts for one file. `no_resident_call` is `new == 0 && changed == 0`.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct Plan {
    pub new: u32,
    pub same: u32,
    pub changed: u32,
    pub local_newer: u32,
    pub blocked: u32,
    pub dup: u32,
    pub no_resident_call: bool,
}

/// Count classes and keep `dup`. Thin wrapper over `summarize_plan`.
#[flutter_rust_bridge::frb(sync)]
pub fn summarize_plan(classes: Vec<Class>, dup: u32) -> Plan {
    let classes: Vec<hatto_card_contract::Class> =
        classes.into_iter().map(to_contract_class).collect();
    let plan = hatto_card_contract::summarize_plan(&classes, dup);
    Plan {
        new: plan.new,
        same: plan.same,
        changed: plan.changed,
        local_newer: plan.local_newer,
        blocked: plan.blocked,
        dup: plan.dup,
        no_resident_call: plan.no_resident_call,
    }
}

fn bridge_facts(facts: NoteFacts) -> Result<hatto_card_contract::NoteFacts, String> {
    let len = facts.content_hash.len();
    let content_hash: [u8; 32] = facts
        .content_hash
        .try_into()
        .map_err(|_bytes: Vec<u8>| format!("content_hash must be 32 bytes, got {len}"))?;
    Ok(hatto_card_contract::NoteFacts {
        guid: facts.guid,
        notetype_id: facts.notetype_id,
        r#mod: facts.r#mod,
        content_hash,
    })
}

fn to_contract_class(class: Class) -> hatto_card_contract::Class {
    match class {
        Class::New => hatto_card_contract::Class::New,
        Class::Same => hatto_card_contract::Class::Same,
        Class::Changed => hatto_card_contract::Class::Changed,
        Class::LocalNewer => hatto_card_contract::Class::LocalNewer,
        Class::Blocked => hatto_card_contract::Class::Blocked,
    }
}

pub(crate) fn from_contract_class(class: hatto_card_contract::Class) -> Class {
    match class {
        hatto_card_contract::Class::New => Class::New,
        hatto_card_contract::Class::Same => Class::Same,
        hatto_card_contract::Class::Changed => Class::Changed,
        hatto_card_contract::Class::LocalNewer => Class::LocalNewer,
        hatto_card_contract::Class::Blocked => Class::Blocked,
    }
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
    rslib_core::api::smoke_open_collection(dir)
}

/// Protobuf call for this crate.
///
/// `rslib_core`'s helper stays `pub(crate)`. This one uses the public
/// `command` path, so a desktop backend still passes the allowlist.
pub(crate) fn call(
    backend: &AnkiBackend,
    service: &str,
    method: &str,
    message: &impl Message,
) -> Result<Vec<u8>, String> {
    let Some(index) = service_method_index(service.to_string(), method.to_string()) else {
        return Err(format!("no index for {service}.{method}"));
    };
    let response = command(
        backend,
        index.service,
        index.method,
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
        Ok(err) => format!("{} (kind={})", err.message, err.kind),
        Err(_) => format!("undecodable backend error ({} bytes)", bytes.len()),
    }
}

/// Open E collection for one batch. Drop closes E and deletes the batch
/// folder unless [`import_stage_finish`] kept a non-empty staged package.
///
/// E is opened inside `hatto_import`. This handle is not a resident backend.
/// [`file_notes`] and [`deck_names`] are the §7.1 step-3 facts: every file
/// note, and every normal deck except Default, before empty decks are removed.
#[flutter_rust_bridge::frb(opaque)]
pub struct PendingImport {
    inner: Option<hatto_import::PendingImport>,
    notes: Vec<NoteFacts>,
    deck_names: Vec<String>,
}

impl PendingImport {
    pub(crate) fn new(
        inner: hatto_import::PendingImport,
        notes: Vec<NoteFacts>,
        deck_names: Vec<String>,
    ) -> Self {
        Self {
            inner: Some(inner),
            notes,
            deck_names,
        }
    }

    pub(crate) fn take(mut self) -> Result<hatto_import::PendingImport, String> {
        self.inner
            .take()
            .ok_or_else(|| "E is already closed".to_string())
    }

    /// File note facts after guid normalization, in note-id order.
    pub fn file_notes(&self) -> Vec<NoteFacts> {
        self.notes.clone()
    }

    /// Normal deck names in E, excluding Default.
    pub fn deck_names(&self) -> Vec<String> {
        self.deck_names.clone()
    }
}

impl Drop for PendingImport {
    fn drop(&mut self) {
        self.inner.take();
    }
}

/// One changed note. `content_hash` is the file hash the resident import
/// should land. `hatto_import::PreparedImport` keeps these in a `BTreeMap`;
/// this list is that map in guid order, because a `BTreeMap` does not cross
/// the bridge as readable entries.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ChangedNote {
    pub guid: String,
    pub content_hash: Vec<u8>,
}

/// Plan for one import. The resident collection is not written here.
///
/// `new_guids` and `changed` are the intent expected lists. `deck_names` is
/// the exported package's normal decks.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct PreparedImport {
    pub import_batch_id: String,
    pub plan: Plan,
    pub staged_path: String,
    pub staged_sha256: String,
    pub first_import: bool,
    pub cardless_notes: u32,
    pub new_guids: Vec<String>,
    pub changed: Vec<ChangedNote>,
    pub deck_names: Vec<String>,
}

/// Notes [`resident_lookup`] read, and the deck names that already exist.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ResidentMatch {
    pub notes: Vec<NoteFacts>,
    pub found_deck_names: Vec<String>,
}

/// One startup scan of `import/{raw,e,staged}`.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ImportFolderScan {
    pub removed: Vec<String>,
    pub kept_prepared: Vec<String>,
    pub ignored: Vec<String>,
}

/// §7.1 steps 1–3. Does not take a resident collection.
///
/// `max_bytes` is the caller's package ceiling. Between this and
/// [`import_stage_finish`] only the E folder exists.
pub fn import_stage_e(
    data_dir: String,
    source_path: String,
    max_bytes: u64,
) -> Result<PendingImport, String> {
    #[cfg(frb_expand)]
    {
        let _ = (data_dir, source_path, max_bytes);
        return Err(String::new());
    }
    #[cfg(not(frb_expand))]
    {
        crate::import_stage::import_stage_e(data_dir, source_path, max_bytes)
    }
}

/// Read resident notes by id and which deck names already exist.
///
/// Uses `GetNote` and `GetDeckIdByName` through [`command`], so a desktop
/// backend still passes the allowlist. This does not write. `notes` follows
/// `note_ids` and `found_deck_names` follows `deck_names`, each name once.
pub fn resident_lookup(
    backend: &AnkiBackend,
    note_ids: Vec<i64>,
    deck_names: Vec<String>,
) -> Result<ResidentMatch, String> {
    #[cfg(frb_expand)]
    {
        let _ = (backend, note_ids, deck_names);
        return Err(String::new());
    }
    #[cfg(not(frb_expand))]
    {
        crate::import_stage::resident_lookup(backend, note_ids, deck_names)
    }
}

/// §7.1 steps 4–7. Does not write the resident collection.
///
/// `resident_facts` and `found_deck_names` are the result of
/// [`resident_lookup`]. Classification uses that map. A no-op deletes the
/// batch folder when `pending` drops.
pub fn import_stage_finish(
    pending: PendingImport,
    resident_facts: Vec<NoteFacts>,
    found_deck_names: Vec<String>,
) -> Result<PreparedImport, String> {
    #[cfg(frb_expand)]
    {
        let _ = (pending, resident_facts, found_deck_names);
        return Err(String::new());
    }
    #[cfg(not(frb_expand))]
    {
        crate::import_stage::import_stage_finish(pending, resident_facts, found_deck_names)
    }
}

/// Delete import batches whose id is not in `prepared_batch_ids`.
///
/// A prepared id is kept. There is no callback.
pub fn scan_import_folders(
    data_dir: String,
    prepared_batch_ids: Vec<String>,
) -> Result<ImportFolderScan, String> {
    #[cfg(frb_expand)]
    {
        let _ = (data_dir, prepared_batch_ids);
        return Err(String::new());
    }
    #[cfg(not(frb_expand))]
    {
        crate::import_stage::scan_import_folders(data_dir, prepared_batch_ids)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use prost::Message;

    #[test]
    fn opens_collection_through_protobuf_channel() {
        let _runtime = crate::lock_bridge_runtime();
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
        let _runtime = crate::lock_bridge_runtime();
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

    #[test]
    fn import_contract_wrappers_match_the_golden_file() {
        let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../../hatto_card_contract/fixtures/note_guid_golden.json");
        let text = std::fs::read_to_string(&path).unwrap_or_else(|err| panic!("{path:?}: {err}"));
        let file: serde_json::Value = serde_json::from_str(&text).unwrap();

        for case in file["assign_import_guids"].as_array().unwrap() {
            let notes = case["notes"]
                .as_array()
                .unwrap()
                .iter()
                .map(|note| ImportSourceNote {
                    source_note_id: note["source_note_id"].as_i64().unwrap(),
                    raw_guid: note["raw_guid"].as_str().unwrap().to_string(),
                })
                .collect();
            let assigned = assign_import_guids(notes);
            let rendered: Vec<serde_json::Value> = assigned
                .iter()
                .map(|row| {
                    serde_json::json!({
                        "source_note_id": row.source_note_id,
                        "guid": row.guid,
                        "dup_index": row.dup_index,
                    })
                })
                .collect();
            assert_eq!(
                serde_json::Value::Array(rendered),
                case["expect"],
                "{}",
                case["label"]
            );
            let dup = assigned
                .iter()
                .filter(|row| row.dup_index >= 1 || row.reassigned)
                .count() as u64;
            assert_eq!(dup, case["dup"].as_u64().unwrap(), "{}", case["label"]);
            let mut guids: Vec<_> = assigned.iter().map(|row| row.guid.clone()).collect();
            guids.sort();
            guids.dedup();
            assert_eq!(guids.len(), assigned.len(), "{}", case["label"]);
        }

        for case in file["note_content_hash"].as_array().unwrap() {
            let fields: Vec<String> = case["fields"]
                .as_array()
                .unwrap()
                .iter()
                .map(|field| field.as_str().unwrap().to_string())
                .collect();
            let tags: Vec<String> = case["tags"]
                .as_array()
                .unwrap()
                .iter()
                .map(|tag| tag.as_str().unwrap().to_string())
                .collect();
            let digest = note_content_hash(fields, tags);
            let text: String = digest.iter().map(|byte| format!("{byte:02x}")).collect();
            assert_eq!(text, case["expect"].as_str().unwrap(), "{}", case["label"]);
        }

        for case in file["classify"].as_array().unwrap() {
            let class = classify(
                facts_from(&case["file"]),
                facts_from_option(&case["resident"]),
            )
            .unwrap_or_else(|err| panic!("{}: {err}", case["label"]));
            assert_eq!(
                class_name(class),
                case["expect"].as_str().unwrap(),
                "{}",
                case["label"]
            );
        }

        for case in file["plans"].as_array().unwrap() {
            let classes = case["classes"]
                .as_array()
                .unwrap()
                .iter()
                .map(|name| class_from_name(name.as_str().unwrap()))
                .collect();
            let plan = summarize_plan(classes, case["dup"].as_u64().unwrap() as u32);
            let expect = &case["expect"];
            assert_eq!(
                plan.new,
                expect["new"].as_u64().unwrap() as u32,
                "{}",
                case["label"]
            );
            assert_eq!(plan.same, expect["same"].as_u64().unwrap() as u32);
            assert_eq!(plan.changed, expect["changed"].as_u64().unwrap() as u32);
            assert_eq!(
                plan.local_newer,
                expect["local_newer"].as_u64().unwrap() as u32
            );
            assert_eq!(plan.blocked, expect["blocked"].as_u64().unwrap() as u32);
            assert_eq!(plan.dup, expect["dup"].as_u64().unwrap() as u32);
            assert_eq!(
                plan.no_resident_call,
                expect["no_resident_call"].as_bool().unwrap()
            );
        }
    }

    fn facts_from(value: &serde_json::Value) -> NoteFacts {
        NoteFacts {
            guid: value["guid"].as_str().unwrap().to_string(),
            notetype_id: value["notetype_id"].as_i64().unwrap(),
            r#mod: value["mod"].as_i64().unwrap(),
            content_hash: decode_hex(value["content_hash"].as_str().unwrap()),
        }
    }

    fn facts_from_option(value: &serde_json::Value) -> Option<NoteFacts> {
        if value.is_null() {
            None
        } else {
            Some(facts_from(value))
        }
    }

    fn decode_hex(text: &str) -> Vec<u8> {
        (0..text.len())
            .step_by(2)
            .map(|index| u8::from_str_radix(&text[index..index + 2], 16).unwrap())
            .collect()
    }

    fn class_name(class: Class) -> &'static str {
        match class {
            Class::New => "NEW",
            Class::Same => "SAME",
            Class::Changed => "CHANGED",
            Class::LocalNewer => "LOCAL_NEWER",
            Class::Blocked => "BLOCKED",
        }
    }

    fn class_from_name(name: &str) -> Class {
        match name {
            "NEW" => Class::New,
            "SAME" => Class::Same,
            "CHANGED" => Class::Changed,
            "LOCAL_NEWER" => Class::LocalNewer,
            "BLOCKED" => Class::Blocked,
            other => panic!("unknown class {other}"),
        }
    }
}
