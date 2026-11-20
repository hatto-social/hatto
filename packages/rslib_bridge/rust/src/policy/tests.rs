// SPDX-FileCopyrightText: 2026 Hatto Social contributors
//
// SPDX-License-Identifier: AGPL-3.0-or-later

use std::path::{Path, PathBuf};
use std::time::SystemTime;

use prost::Message;

use super::{
    access_label, allowlist_markdown, camel_method, entry, forwarded_names, service_short_name,
    status_label, Access, Status, ALLOWLIST, ANSWER_TAKEN_MAX_MILLIS, GRAPHS_DAYS_MAX,
};
use crate::api::{
    command, decode_backend_error, dispatch_message, open_backend, open_backend_with_profile,
    BridgeProfile, ProtoResponse,
};
use crate::fsrs_init::{self, marker_path, FsrsInitOutcome};
use crate::index;

struct ColPaths {
    root: PathBuf,
    collection: PathBuf,
    media: PathBuf,
    media_db: PathBuf,
}

fn col_paths(root: &Path) -> ColPaths {
    std::fs::create_dir_all(root.join("collection.media")).unwrap();
    std::fs::create_dir_all(root.join("tmp")).unwrap();
    crate::api::prepare_runtime(root.join("tmp").to_string_lossy().into_owned());
    ColPaths {
        root: root.to_path_buf(),
        collection: root.join("collection.anki2"),
        media: root.join("collection.media"),
        media_db: root.join("collection.media.db"),
    }
}

fn init_bytes() -> Vec<u8> {
    anki_proto::backend::BackendInit {
        preferred_langs: vec!["en".into()],
        locale_folder_path: String::new(),
        server: false,
    }
    .encode_to_vec()
}

fn desktop_backend(root: &Path) -> crate::api::AnkiBackend {
    open_backend_with_profile(
        init_bytes(),
        BridgeProfile::Desktop {
            data_dir: root.to_string_lossy().into_owned(),
        },
    )
    .expect("desktop backend")
}

fn open_request(paths: &ColPaths) -> anki_proto::collection::OpenCollectionRequest {
    anki_proto::collection::OpenCollectionRequest {
        collection_path: paths.collection.to_string_lossy().into_owned(),
        media_folder_path: paths.media.to_string_lossy().into_owned(),
        media_db_path: paths.media_db.to_string_lossy().into_owned(),
    }
}

fn call(
    backend: &crate::api::AnkiBackend,
    service: &str,
    method: &str,
    message: &impl Message,
) -> ProtoResponse {
    let (service_index, method_index) = index::lookup(service, method).expect("index");
    command(
        backend,
        service_index,
        method_index,
        message.encode_to_vec(),
    )
}

fn message_of(response: &ProtoResponse) -> String {
    decode_backend_error(&response.payload)
}

fn open_desktop_collection(paths: &ColPaths) -> crate::api::AnkiBackend {
    let backend = desktop_backend(&paths.root);
    let response = call(
        &backend,
        "BackendCollectionService",
        "open_collection",
        &open_request(paths),
    );
    assert!(response.success, "{}", message_of(&response));
    backend
}

fn add_basic_card(backend: &crate::api::AnkiBackend) -> i64 {
    let id_bytes = dispatch_message(
        backend,
        "BackendNotetypesService",
        "get_notetype_id_by_name",
        &anki_proto::generic::String {
            val: "Basic".into(),
        },
    )
    .expect("basic notetype");
    let notetype = anki_proto::notetypes::NotetypeId::decode(id_bytes.as_slice()).unwrap();
    let note_bytes =
        dispatch_message(backend, "BackendNotesService", "new_note", &notetype).expect("new note");
    let mut note = anki_proto::notes::Note::decode(note_bytes.as_slice()).unwrap();
    assert!(
        note.fields.len() >= 2,
        "basic note fields: {:?}",
        note.fields
    );
    note.fields[0] = "front".into();
    note.fields[1] = "back".into();
    let added = dispatch_message(
        backend,
        "BackendNotesService",
        "add_note",
        &anki_proto::notes::AddNoteRequest {
            note: Some(note),
            deck_id: 1,
        },
    )
    .expect("add note");
    let response = anki_proto::notes::AddNoteResponse::decode(added.as_slice()).unwrap();
    let cards = dispatch_message(
        backend,
        "BackendNotesService",
        "cards_of_note",
        &anki_proto::notes::NoteId {
            nid: response.note_id,
        },
    )
    .expect("cards of note");
    let ids = anki_proto::cards::CardIds::decode(cards.as_slice()).unwrap();
    *ids.cids.first().expect("new note has a card")
}

fn add_basic_note(backend: &crate::api::AnkiBackend) -> i64 {
    let id_bytes = dispatch_message(
        backend,
        "BackendNotetypesService",
        "get_notetype_id_by_name",
        &anki_proto::generic::String {
            val: "Basic".into(),
        },
    )
    .expect("basic notetype");
    let notetype = anki_proto::notetypes::NotetypeId::decode(id_bytes.as_slice()).unwrap();
    let note_bytes =
        dispatch_message(backend, "BackendNotesService", "new_note", &notetype).expect("new note");
    let mut note = anki_proto::notes::Note::decode(note_bytes.as_slice()).unwrap();
    note.fields[0] = "front".into();
    note.fields[1] = "back".into();
    let added = dispatch_message(
        backend,
        "BackendNotesService",
        "add_note",
        &anki_proto::notes::AddNoteRequest {
            note: Some(note),
            deck_id: 1,
        },
    )
    .expect("add note");
    anki_proto::notes::AddNoteResponse::decode(added.as_slice())
        .unwrap()
        .note_id
}

fn fsrs_enabled(backend: &crate::api::AnkiBackend) -> bool {
    let bytes = dispatch_message(
        backend,
        "BackendDeckConfigService",
        "get_deck_configs_for_update",
        &anki_proto::decks::DeckId { did: 1 },
    )
    .expect("deck configs");
    anki_proto::deck_config::DeckConfigsForUpdate::decode(bytes.as_slice())
        .unwrap()
        .fsrs
}

fn undo_is_empty(backend: &crate::api::AnkiBackend) {
    let response = call(
        backend,
        "BackendCollectionService",
        "get_undo_status",
        &anki_proto::generic::Empty {},
    );
    assert!(response.success, "{}", message_of(&response));
    let status = anki_proto::collection::UndoStatus::decode(response.payload.as_slice()).unwrap();
    assert!(
        status.undo.is_empty() && status.redo.is_empty(),
        "{status:?}"
    );
}

#[test]
fn allowlist_names_resolve_and_counts_match() {
    let mut seen = std::collections::HashSet::new();
    let mut validated = 0;
    let mut name_only = 0;
    let mut pending = 0;
    let mut deferred = 0;
    for row in ALLOWLIST {
        assert!(
            seen.insert((row.service, row.method)),
            "duplicate {}.{}",
            row.service,
            row.method
        );
        assert!(
            index::lookup(row.service, row.method).is_some(),
            "{}.{} is not in this rslib build",
            row.service,
            row.method
        );
        match row.status {
            Status::Validated => validated += 1,
            Status::NameOnly => name_only += 1,
            Status::Pending => pending += 1,
            Status::Deferred => deferred += 1,
        }
    }
    assert_eq!(validated, 16);
    assert_eq!(name_only, 58);
    assert_eq!(pending, 13);
    assert_eq!(deferred, 1);
    assert_eq!(ALLOWLIST.len(), 88);
    assert_eq!(forwarded_names().len(), 74);

    let pending_methods: std::collections::HashSet<_> = ALLOWLIST
        .iter()
        .filter(|row| row.status == Status::Pending)
        .map(|row| row.method)
        .collect();
    for method in [
        "undo",
        "redo",
        "rename_deck",
        "reparent_decks",
        "remove_decks",
        "add_notes",
        "add_notetype",
        "update_notetype",
        "remove_notetype",
        "change_notetype",
        "add_media_file",
        "update_image_occlusion_note",
        "get_image_occlusion_note",
    ] {
        assert!(pending_methods.contains(method), "{method}");
    }
    assert_eq!(pending_methods.len(), 13);
}

#[test]
fn print_allowlist_table() {
    let table = allowlist_markdown();
    println!("{table}");
    assert_eq!(
        table.lines().filter(|line| line.starts_with("| ")).count(),
        89
    );
    assert!(table.contains("| Collection | OpenCollection |"));
    assert!(table.contains("검증 미구현, 이 PR에서는 거부"));
    assert!(table.contains("| Search | SetActiveBrowserColumns |"));
    assert!(table.contains("이월"));
    assert_eq!(status_label(Status::Validated), "허용(검증 있음)");
    assert_eq!(status_label(Status::NameOnly), "허용(이름만)");
    assert_eq!(access_label(Access::Read), "읽기");
    assert_eq!(camel_method("get_config_bool"), "GetConfigBool");
    assert_eq!(
        service_short_name("BackendImageOcclusionService"),
        "ImageOcclusion"
    );
    assert!(entry("BackendSearchService", "set_active_browser_columns").is_some());
}

#[test]
fn desktop_denies_calls_outside_the_allowed_70() {
    let dir = tempfile::TempDir::new_in("/tmp").unwrap();
    let backend = desktop_backend(dir.path());
    let allowed = forwarded_names();
    let mut denied = 0;
    let mut pending = 0;
    for entry in index::iter_methods() {
        if allowed.contains(&(entry.service, entry.method)) {
            continue;
        }
        let response = command(
            &backend,
            entry.service_index,
            entry.method_index,
            Vec::new(),
        );
        assert!(
            !response.success,
            "{}.{} was forwarded",
            entry.service, entry.method
        );
        let message = message_of(&response);
        assert!(
            message.contains(&format!("denied: {}.{}", entry.service, entry.method)),
            "{message}"
        );
        let row = super::entry(entry.service, entry.method);
        if row.is_some_and(|row| row.status == Status::Pending) {
            assert!(message.contains("(validator not implemented)"), "{message}");
            pending += 1;
        } else {
            assert!(message.contains("(not on allowlist)"), "{message}");
        }
        denied += 1;
    }
    assert!(denied > 14, "denied {denied}");
    assert_eq!(pending, 13);
}

#[test]
fn pending_validators_are_denied() {
    let dir = tempfile::TempDir::new_in("/tmp").unwrap();
    let backend = desktop_backend(dir.path());
    for row in ALLOWLIST.iter().filter(|row| row.status == Status::Pending) {
        let response = call(
            &backend,
            row.service,
            row.method,
            &anki_proto::generic::Empty {},
        );
        assert!(!response.success, "{}.{}", row.service, row.method);
        let message = message_of(&response);
        assert!(
            message.contains("(validator not implemented)"),
            "{}.{}: {message}",
            row.service,
            row.method
        );
    }
}

#[test]
fn denied_calls_stay_denied() {
    let dir = tempfile::TempDir::new_in("/tmp").unwrap();
    let backend = desktop_backend(dir.path());
    let cases = [
        ("BackendSchedulerService", "unbury_deck"),
        ("BackendSchedulerService", "set_due_date"),
        ("BackendDeckConfigService", "update_deck_configs"),
        ("BackendImportExportService", "import_anki_package"),
        ("BackendMediaService", "add_media_from_url"),
        ("BackendMediaService", "add_media_from_path"),
        ("BackendSearchService", "set_active_browser_columns"),
        ("BackendCollectionService", "check_database"),
        ("BackendAnkidroidService", "run_db_command"),
    ];
    for (service, method) in cases {
        let response = call(&backend, service, method, &anki_proto::generic::Empty {});
        assert!(!response.success, "{service}.{method}");
        let message = message_of(&response);
        assert!(
            message.contains(&format!("denied: {service}.{method} (not on allowlist)")),
            "{message}"
        );
    }
}

#[test]
fn set_active_browser_columns_is_outside_the_profile() {
    let row = entry("BackendSearchService", "set_active_browser_columns").unwrap();
    assert_eq!(row.status, Status::Deferred);
    assert!(!super::is_forwarded(row.service, row.method));
}

#[test]
fn mobile_unrestricted_forwards_calls_that_desktop_denies() {
    let dir = tempfile::TempDir::new_in("/tmp").unwrap();
    std::fs::create_dir_all(dir.path()).unwrap();
    let backend = open_backend(init_bytes()).unwrap();
    let explicit =
        open_backend_with_profile(init_bytes(), BridgeProfile::MobileUnrestricted).unwrap();
    for backend in [&backend, &explicit] {
        let response = call(
            backend,
            "BackendDeckConfigService",
            "update_deck_configs",
            &anki_proto::generic::Empty {},
        );
        if !response.success {
            let message = message_of(&response);
            assert!(!message.contains("(not on allowlist)"), "{message}");
            assert!(
                !message.contains("(validator not implemented)"),
                "{message}"
            );
        }
    }
}

#[test]
fn name_only_calls_are_not_denied_by_the_desktop_profile() {
    let dir = tempfile::TempDir::new_in("/tmp").unwrap();
    let paths = col_paths(dir.path());
    let backend = open_desktop_collection(&paths);
    // Empty protobuf is not a valid request for every name-only call. rslib
    // returns an error for most of them. `get_cloze_field_ords` is checked
    // for a real notetype first, and `dispatch` turns any remaining panic
    // into an error, so none of these calls should unwind.
    for row in ALLOWLIST
        .iter()
        .filter(|row| row.status == Status::NameOnly)
    {
        let response = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            call(
                &backend,
                row.service,
                row.method,
                &anki_proto::generic::Empty {},
            )
        }));
        let response = response
            .unwrap_or_else(|_| panic!("{}.{} panicked past the bridge", row.service, row.method));
        if !response.success {
            let message = message_of(&response);
            assert!(
                !message.contains("(not on allowlist)")
                    && !message.contains("(validator not implemented)")
                    && !message.contains("collection is not open")
                    && !message.contains("panicked")
                    && !message.contains("backend poisoned"),
                "{}.{}: {message}",
                row.service,
                row.method
            );
        }
    }
}

#[test]
fn validates_open_collection() {
    let dir = tempfile::TempDir::new_in("/tmp").unwrap();
    let paths = col_paths(dir.path());
    let backend = desktop_backend(&paths.root);

    let mut outside = open_request(&paths);
    outside.collection_path = "/tmp/not-the-data-dir/collection.anki2".into();
    let denied = call(
        &backend,
        "BackendCollectionService",
        "open_collection",
        &outside,
    );
    assert!(!denied.success, "outside path");
    assert!(
        message_of(&denied).contains("outside data_dir"),
        "{}",
        message_of(&denied)
    );

    let mut parent = open_request(&paths);
    parent.media_folder_path = paths
        .root
        .join("..")
        .join("elsewhere")
        .to_string_lossy()
        .into_owned();
    let denied = call(
        &backend,
        "BackendCollectionService",
        "open_collection",
        &parent,
    );
    assert!(!denied.success, "parent segment");
    assert!(
        message_of(&denied).contains(".."),
        "{}",
        message_of(&denied)
    );

    let mut relative = open_request(&paths);
    relative.media_db_path = "collection.media.db".into();
    let denied = call(
        &backend,
        "BackendCollectionService",
        "open_collection",
        &relative,
    );
    assert!(!denied.success, "relative path");
    assert!(
        message_of(&denied).contains("not absolute"),
        "{}",
        message_of(&denied)
    );

    let outside_dir = tempfile::TempDir::new_in("/tmp").unwrap();
    let link = paths.root.join("escape");
    std::os::unix::fs::symlink(outside_dir.path(), &link).unwrap();
    let mut via_link = open_request(&paths);
    via_link.collection_path = link.join("collection.anki2").to_string_lossy().into_owned();
    let denied = call(
        &backend,
        "BackendCollectionService",
        "open_collection",
        &via_link,
    );
    assert!(!denied.success, "symlink escape");
    assert!(
        message_of(&denied).contains("escapes data_dir"),
        "{}",
        message_of(&denied)
    );

    let opened = call(
        &backend,
        "BackendCollectionService",
        "open_collection",
        &open_request(&paths),
    );
    assert!(opened.success, "{}", message_of(&opened));
    assert!(marker_path(&paths.collection).is_file());
}

#[test]
fn open_collection_accepts_a_symlinked_ancestor() {
    // macOS spells the temp dir as /var, which is a symlink to /private/var.
    // The desktop profile stores the canonical data_dir, and the app passes
    // collection paths with the symlink spelling.
    let dir = tempfile::TempDir::new_in("/tmp").unwrap();
    let real = dir.path().join("real");
    std::fs::create_dir_all(&real).unwrap();
    let link = dir.path().join("link");
    std::os::unix::fs::symlink(&real, &link).unwrap();
    let root = link.join("collection");
    let paths = col_paths(&root);
    let backend = desktop_backend(&paths.root);
    let opened = call(
        &backend,
        "BackendCollectionService",
        "open_collection",
        &open_request(&paths),
    );
    assert!(opened.success, "{}", message_of(&opened));
    assert!(marker_path(&paths.collection).is_file());
}

#[test]
fn open_collection_rejects_a_sideways_symlink() {
    let dir = tempfile::TempDir::new_in("/tmp").unwrap();
    let paths = col_paths(dir.path());
    let backend = desktop_backend(&paths.root);
    let elsewhere = tempfile::TempDir::new_in("/tmp").unwrap();
    let alias = elsewhere.path().join("alias");
    std::os::unix::fs::symlink(&paths.root, &alias).unwrap();
    let mut via_alias = open_request(&paths);
    via_alias.collection_path = alias
        .join("collection.anki2")
        .to_string_lossy()
        .into_owned();
    let denied = call(
        &backend,
        "BackendCollectionService",
        "open_collection",
        &via_alias,
    );
    assert!(!denied.success, "sideways symlink");
    assert!(
        message_of(&denied).contains("outside data_dir"),
        "{}",
        message_of(&denied)
    );
}

#[test]
fn validates_close_collection() {
    let dir = tempfile::TempDir::new_in("/tmp").unwrap();
    let paths = col_paths(dir.path());
    let backend = open_desktop_collection(&paths);
    let denied = call(
        &backend,
        "BackendCollectionService",
        "close_collection",
        &anki_proto::collection::CloseCollectionRequest {
            downgrade_to_schema11: true,
        },
    );
    assert!(!denied.success);
    assert!(
        message_of(&denied).contains("downgrade_to_schema11"),
        "{}",
        message_of(&denied)
    );
    let closed = call(
        &backend,
        "BackendCollectionService",
        "close_collection",
        &anki_proto::collection::CloseCollectionRequest {
            downgrade_to_schema11: false,
        },
    );
    assert!(closed.success, "{}", message_of(&closed));
}

#[test]
fn validates_get_config_bool() {
    let dir = tempfile::TempDir::new_in("/tmp").unwrap();
    let paths = col_paths(dir.path());
    let backend = open_desktop_collection(&paths);
    let denied = call(
        &backend,
        "BackendConfigService",
        "get_config_bool",
        &anki_proto::config::GetConfigBoolRequest {
            key: anki_proto::config::config_key::Bool::Sched2021 as i32,
        },
    );
    assert!(!denied.success);
    assert!(
        message_of(&denied).contains("NormalizeNoteText"),
        "{}",
        message_of(&denied)
    );
    let allowed = call(
        &backend,
        "BackendConfigService",
        "get_config_bool",
        &anki_proto::config::GetConfigBoolRequest {
            key: anki_proto::config::config_key::Bool::NormalizeNoteText as i32,
        },
    );
    assert!(allowed.success, "{}", message_of(&allowed));
}

#[test]
fn validates_export_anki_package() {
    let dir = tempfile::TempDir::new_in("/tmp").unwrap();
    let paths = col_paths(dir.path());
    let backend = open_desktop_collection(&paths);
    let mut request = export_request(&paths);
    request.options.as_mut().unwrap().with_scheduling = true;
    let denied = call(
        &backend,
        "BackendImportExportService",
        "export_anki_package",
        &request,
    );
    assert!(!denied.success);
    assert!(
        message_of(&denied).contains("with_scheduling"),
        "{}",
        message_of(&denied)
    );

    let mut request = export_request(&paths);
    request.options.as_mut().unwrap().with_deck_configs = true;
    let denied = call(
        &backend,
        "BackendImportExportService",
        "export_anki_package",
        &request,
    );
    assert!(!denied.success);
    assert!(
        message_of(&denied).contains("with_deck_configs"),
        "{}",
        message_of(&denied)
    );

    let mut whole = export_request(&paths);
    whole.limit = Some(anki_proto::import_export::ExportLimit {
        limit: Some(
            anki_proto::import_export::export_limit::Limit::WholeCollection(
                anki_proto::generic::Empty {},
            ),
        ),
    });
    let denied = call(
        &backend,
        "BackendImportExportService",
        "export_anki_package",
        &whole,
    );
    assert!(
        message_of(&denied).contains("note id list"),
        "{}",
        message_of(&denied)
    );

    let mut cards = export_request(&paths);
    cards.limit = Some(anki_proto::import_export::ExportLimit {
        limit: Some(anki_proto::import_export::export_limit::Limit::CardIds(
            anki_proto::cards::CardIds { cids: vec![1] },
        )),
    });
    let denied = call(
        &backend,
        "BackendImportExportService",
        "export_anki_package",
        &cards,
    );
    assert!(
        message_of(&denied).contains("note id list"),
        "{}",
        message_of(&denied)
    );

    let mut empty_notes = export_request(&paths);
    empty_notes.limit = Some(anki_proto::import_export::ExportLimit {
        limit: Some(anki_proto::import_export::export_limit::Limit::NoteIds(
            anki_proto::notes::NoteIds { note_ids: vec![] },
        )),
    });
    let denied = call(
        &backend,
        "BackendImportExportService",
        "export_anki_package",
        &empty_notes,
    );
    assert!(
        message_of(&denied).contains("note id list"),
        "{}",
        message_of(&denied)
    );

    let exported = call(
        &backend,
        "BackendImportExportService",
        "export_anki_package",
        &export_request(&paths),
    );
    assert!(exported.success, "{}", message_of(&exported));
    assert!(paths.root.join("out.apkg").is_file());
}

fn export_request(paths: &ColPaths) -> anki_proto::import_export::ExportAnkiPackageRequest {
    anki_proto::import_export::ExportAnkiPackageRequest {
        out_path: paths.root.join("out.apkg").to_string_lossy().into_owned(),
        options: Some(anki_proto::import_export::ExportAnkiPackageOptions {
            with_scheduling: false,
            with_deck_configs: false,
            with_media: true,
            legacy: false,
        }),
        limit: Some(anki_proto::import_export::ExportLimit {
            limit: Some(anki_proto::import_export::export_limit::Limit::DeckId(1)),
        }),
    }
}

#[test]
fn validates_get_queued_cards() {
    let dir = tempfile::TempDir::new_in("/tmp").unwrap();
    let paths = col_paths(dir.path());
    let backend = open_desktop_collection(&paths);
    let denied = call(
        &backend,
        "BackendSchedulerService",
        "get_queued_cards",
        &anki_proto::scheduler::GetQueuedCardsRequest {
            fetch_limit: 51,
            intraday_learning_only: false,
        },
    );
    assert!(!denied.success);
    assert!(
        message_of(&denied).contains("fetch_limit"),
        "{}",
        message_of(&denied)
    );
    let allowed = call(
        &backend,
        "BackendSchedulerService",
        "get_queued_cards",
        &anki_proto::scheduler::GetQueuedCardsRequest {
            fetch_limit: 50,
            intraday_learning_only: false,
        },
    );
    assert!(allowed.success, "{}", message_of(&allowed));
}

#[test]
fn validates_answer_card() {
    let dir = tempfile::TempDir::new_in("/tmp").unwrap();
    let paths = col_paths(dir.path());
    let backend = open_desktop_collection(&paths);
    let card_id = add_basic_card(&backend);
    let offered = scheduling_states(&backend, card_id);
    let good = offered.good.clone().unwrap();
    let current = offered.current.clone();

    let tweaked = one_byte_different_state(&good);
    let denied = call(
        &backend,
        "BackendSchedulerService",
        "answer_card",
        &answer(card_id, current.clone(), tweaked, 1_000, 0),
    );
    assert!(!denied.success);
    assert!(
        message_of(&denied).contains("does not match"),
        "{}",
        message_of(&denied)
    );

    let mut custom = good.clone();
    custom.custom_data = Some("x".into());
    let denied = call(
        &backend,
        "BackendSchedulerService",
        "answer_card",
        &answer(card_id, current.clone(), custom, 1_000, 0),
    );
    assert!(
        message_of(&denied).contains("custom_data"),
        "{}",
        message_of(&denied)
    );

    let denied = call(
        &backend,
        "BackendSchedulerService",
        "answer_card",
        &answer(
            card_id,
            current.clone(),
            good.clone(),
            ANSWER_TAKEN_MAX_MILLIS + 1,
            0,
        ),
    );
    assert!(
        message_of(&denied).contains("milliseconds_taken"),
        "{}",
        message_of(&denied)
    );

    let denied = call(
        &backend,
        "BackendSchedulerService",
        "answer_card",
        &answer(999_999, current.clone(), good.clone(), 1_000, 0),
    );
    assert!(
        message_of(&denied).contains("was not offered"),
        "{}",
        message_of(&denied)
    );

    let mut filled = answer(card_id, current.clone(), good.clone(), 1_000, 0);
    assert_eq!(filled.answered_at_millis, 0);
    super::validators::fill_answered_at_millis(&mut filled, 1_700_000_000_000);
    assert_eq!(filled.answered_at_millis, 1_700_000_000_000);

    let before = SystemTime::now()
        .duration_since(SystemTime::UNIX_EPOCH)
        .unwrap()
        .as_millis() as i64;
    let answered = call(
        &backend,
        "BackendSchedulerService",
        "answer_card",
        &answer(card_id, current, good, 1_000, 0),
    );
    assert!(answered.success, "{}", message_of(&answered));
    let revlog_id = latest_revlog_id(&backend);
    let after = SystemTime::now()
        .duration_since(SystemTime::UNIX_EPOCH)
        .unwrap()
        .as_millis() as i64;
    assert!(
        revlog_id >= before.saturating_sub(2_000) && revlog_id <= after.saturating_add(2_000),
        "wrapper clock {revlog_id} not in {before}..={after}"
    );
}

fn scheduling_states(
    backend: &crate::api::AnkiBackend,
    card_id: i64,
) -> anki_proto::scheduler::SchedulingStates {
    let response = call(
        backend,
        "BackendSchedulerService",
        "get_scheduling_states",
        &anki_proto::cards::CardId { cid: card_id },
    );
    assert!(response.success, "{}", message_of(&response));
    anki_proto::scheduler::SchedulingStates::decode(response.payload.as_slice()).unwrap()
}

fn answer(
    card_id: i64,
    current: Option<anki_proto::scheduler::SchedulingState>,
    new_state: anki_proto::scheduler::SchedulingState,
    milliseconds_taken: u32,
    answered_at_millis: i64,
) -> anki_proto::scheduler::CardAnswer {
    anki_proto::scheduler::CardAnswer {
        card_id,
        current_state: current,
        new_state: Some(new_state),
        rating: anki_proto::scheduler::card_answer::Rating::Good as i32,
        answered_at_millis,
        milliseconds_taken,
    }
}

fn one_byte_different_state(
    state: &anki_proto::scheduler::SchedulingState,
) -> anki_proto::scheduler::SchedulingState {
    let original = state.encode_to_vec();
    let mut bytes = original.clone();
    for index in (0..bytes.len()).rev() {
        let saved = bytes[index];
        for delta in [1_u8, 2, 255] {
            bytes[index] = saved.wrapping_add(delta);
            if let Ok(parsed) = anki_proto::scheduler::SchedulingState::decode(bytes.as_slice()) {
                if parsed.encode_to_vec() != original {
                    return parsed;
                }
            }
        }
        bytes[index] = saved;
    }
    panic!("no one-byte mutation decoded to a different state");
}

fn latest_revlog_id(backend: &crate::api::AnkiBackend) -> i64 {
    let query = serde_json::json!({
        "kind": "query",
        "sql": "select id from revlog order by id desc limit 1",
        "args": [],
        "first_row_only": true,
    });
    let bytes = dispatch_message(
        backend,
        "BackendAnkidroidService",
        "run_db_command",
        &anki_proto::generic::Json {
            json: serde_json::to_vec(&query).unwrap(),
        },
    )
    .unwrap();
    let decoded = anki_proto::generic::Json::decode(bytes.as_slice()).unwrap();
    let value: serde_json::Value = serde_json::from_slice(&decoded.json).unwrap();
    value[0][0].as_i64().unwrap()
}

#[test]
fn validates_set_current_deck() {
    let dir = tempfile::TempDir::new_in("/tmp").unwrap();
    let paths = col_paths(dir.path());
    let backend = open_desktop_collection(&paths);
    let missing = call(
        &backend,
        "BackendDecksService",
        "set_current_deck",
        &anki_proto::decks::DeckId { did: 999_999 },
    );
    assert!(!missing.success);
    assert!(
        message_of(&missing).contains("does not exist"),
        "{}",
        message_of(&missing)
    );

    let _card_id = add_basic_card(&backend);
    let filtered_id = create_filtered_deck(&backend);
    let filtered = call(
        &backend,
        "BackendDecksService",
        "set_current_deck",
        &anki_proto::decks::DeckId { did: filtered_id },
    );
    assert!(!filtered.success);
    assert!(
        message_of(&filtered).contains("not a normal deck"),
        "{}",
        message_of(&filtered)
    );

    let normal = call(
        &backend,
        "BackendDecksService",
        "set_current_deck",
        &anki_proto::decks::DeckId { did: 1 },
    );
    assert!(normal.success, "{}", message_of(&normal));
}

fn create_filtered_deck(backend: &crate::api::AnkiBackend) -> i64 {
    let bytes = dispatch_message(
        backend,
        "BackendDecksService",
        "get_or_create_filtered_deck",
        &anki_proto::decks::DeckId { did: 0 },
    )
    .unwrap();
    let mut template = anki_proto::decks::FilteredDeckForUpdate::decode(bytes.as_slice()).unwrap();
    template.name = "Filtered".into();
    template.allow_empty = true;
    if let Some(config) = template.config.as_mut() {
        config.search_terms = vec![anki_proto::decks::deck::filtered::SearchTerm {
            search: "deck:Default".into(),
            limit: 10,
            order: 1,
        }];
    }
    let saved = dispatch_message(
        backend,
        "BackendDecksService",
        "add_or_update_filtered_deck",
        &template,
    )
    .unwrap();
    anki_proto::collection::OpChangesWithId::decode(saved.as_slice())
        .unwrap()
        .id
}

#[test]
fn validates_graphs() {
    let dir = tempfile::TempDir::new_in("/tmp").unwrap();
    let paths = col_paths(dir.path());
    let backend = open_desktop_collection(&paths);
    let built = call(
        &backend,
        "BackendSearchService",
        "build_search_string",
        &anki_proto::search::SearchNode {
            filter: Some(anki_proto::search::search_node::Filter::Deck(
                "Default".into(),
            )),
        },
    );
    assert!(built.success, "{}", message_of(&built));
    let search = anki_proto::generic::String::decode(built.payload.as_slice())
        .unwrap()
        .val;

    let unknown = call(
        &backend,
        "BackendStatsService",
        "graphs",
        &anki_proto::stats::GraphsRequest {
            search: "deck:Nope".into(),
            days: 1,
        },
    );
    assert!(!unknown.success);
    assert!(
        message_of(&unknown).contains("search"),
        "{}",
        message_of(&unknown)
    );

    let too_many_days = call(
        &backend,
        "BackendStatsService",
        "graphs",
        &anki_proto::stats::GraphsRequest {
            search: search.clone(),
            days: GRAPHS_DAYS_MAX + 1,
        },
    );
    assert!(!too_many_days.success);
    assert!(
        message_of(&too_many_days).contains("days"),
        "{}",
        message_of(&too_many_days)
    );

    let allowed = call(
        &backend,
        "BackendStatsService",
        "graphs",
        &anki_proto::stats::GraphsRequest { search, days: 0 },
    );
    assert!(allowed.success, "{}", message_of(&allowed));
}

#[test]
fn validates_bury_or_suspend_cards() {
    let dir = tempfile::TempDir::new_in("/tmp").unwrap();
    let paths = col_paths(dir.path());
    let backend = open_desktop_collection(&paths);
    let card_id = add_basic_card(&backend);
    let suspend = anki_proto::scheduler::bury_or_suspend_cards_request::Mode::Suspend as i32;
    let bury = anki_proto::scheduler::bury_or_suspend_cards_request::Mode::BuryUser as i32;

    let denied = call(
        &backend,
        "BackendSchedulerService",
        "bury_or_suspend_cards",
        &bury_request(vec![card_id], vec![], bury),
    );
    assert!(
        message_of(&denied).contains("SUSPEND"),
        "{}",
        message_of(&denied)
    );

    let denied = call(
        &backend,
        "BackendSchedulerService",
        "bury_or_suspend_cards",
        &bury_request(vec![], vec![], suspend),
    );
    assert!(
        message_of(&denied).contains("card_ids"),
        "{}",
        message_of(&denied)
    );

    let denied = call(
        &backend,
        "BackendSchedulerService",
        "bury_or_suspend_cards",
        &bury_request(vec![card_id], vec![1], suspend),
    );
    assert!(
        message_of(&denied).contains("note_ids"),
        "{}",
        message_of(&denied)
    );

    let denied = call(
        &backend,
        "BackendSchedulerService",
        "bury_or_suspend_cards",
        &bury_request(vec![999_999], vec![], suspend),
    );
    assert!(
        message_of(&denied).contains("does not exist"),
        "{}",
        message_of(&denied)
    );

    let suspended = call(
        &backend,
        "BackendSchedulerService",
        "bury_or_suspend_cards",
        &bury_request(vec![card_id], vec![], suspend),
    );
    assert!(suspended.success, "{}", message_of(&suspended));
}

fn bury_request(
    card_ids: Vec<i64>,
    note_ids: Vec<i64>,
    mode: i32,
) -> anki_proto::scheduler::BuryOrSuspendCardsRequest {
    anki_proto::scheduler::BuryOrSuspendCardsRequest {
        card_ids,
        note_ids,
        mode,
    }
}

#[test]
fn validates_restore_buried_and_suspended_cards() {
    let dir = tempfile::TempDir::new_in("/tmp").unwrap();
    let paths = col_paths(dir.path());
    let backend = open_desktop_collection(&paths);
    let card_id = add_basic_card(&backend);
    let not_suspended = call(
        &backend,
        "BackendSchedulerService",
        "restore_buried_and_suspended_cards",
        &anki_proto::cards::CardIds {
            cids: vec![card_id],
        },
    );
    assert!(!not_suspended.success);
    assert!(
        message_of(&not_suspended).contains("queue"),
        "{}",
        message_of(&not_suspended)
    );

    let suspended = call(
        &backend,
        "BackendSchedulerService",
        "bury_or_suspend_cards",
        &bury_request(
            vec![card_id],
            vec![],
            anki_proto::scheduler::bury_or_suspend_cards_request::Mode::Suspend as i32,
        ),
    );
    assert!(suspended.success, "{}", message_of(&suspended));
    let restored = call(
        &backend,
        "BackendSchedulerService",
        "restore_buried_and_suspended_cards",
        &anki_proto::cards::CardIds {
            cids: vec![card_id],
        },
    );
    assert!(restored.success, "{}", message_of(&restored));
}

#[test]
fn fsrs_init_runs_once_on_an_empty_collection() {
    let dir = tempfile::TempDir::new_in("/tmp").unwrap();
    let paths = col_paths(dir.path());
    let backend = desktop_backend(&paths.root);
    let open = open_request(&paths);
    let err = fsrs_init::maybe_initialize(&backend, &open).unwrap_err();
    assert!(
        !marker_path(&paths.collection).exists(),
        "marker written before success: {err}"
    );

    let opened = call(
        &backend,
        "BackendCollectionService",
        "open_collection",
        &open,
    );
    assert!(opened.success, "{}", message_of(&opened));
    let marker = marker_path(&paths.collection);
    assert!(marker.is_file());
    assert!(
        !marker
            .with_file_name(format!(
                "{}.tmp",
                marker.file_name().unwrap().to_string_lossy()
            ))
            .exists(),
        "temporary marker file was left behind"
    );
    assert!(fsrs_enabled(&backend));
    undo_is_empty(&backend);
    let modified = marker.metadata().unwrap().modified().unwrap();
    assert_eq!(
        fsrs_init::maybe_initialize(&backend, &open).unwrap(),
        FsrsInitOutcome::AlreadyMarked
    );
    assert_eq!(marker.metadata().unwrap().modified().unwrap(), modified);

    let closed = call(
        &backend,
        "BackendCollectionService",
        "close_collection",
        &anki_proto::collection::CloseCollectionRequest {
            downgrade_to_schema11: false,
        },
    );
    assert!(closed.success, "{}", message_of(&closed));
    let reopened = call(
        &backend,
        "BackendCollectionService",
        "open_collection",
        &open,
    );
    assert!(reopened.success, "{}", message_of(&reopened));
    assert_eq!(marker.metadata().unwrap().modified().unwrap(), modified);
    assert!(fsrs_enabled(&backend));
}

#[test]
fn fsrs_init_marks_existing_reviews_without_enabling_fsrs() {
    let dir = tempfile::TempDir::new_in("/tmp").unwrap();
    let paths = col_paths(dir.path());
    let mobile = open_backend(init_bytes()).unwrap();
    let open = open_request(&paths);
    let opened = call(
        &mobile,
        "BackendCollectionService",
        "open_collection",
        &open,
    );
    assert!(opened.success, "{}", message_of(&opened));
    fsrs_init::insert_revlog_row(&mobile).unwrap();
    let closed = call(
        &mobile,
        "BackendCollectionService",
        "close_collection",
        &anki_proto::collection::CloseCollectionRequest {
            downgrade_to_schema11: false,
        },
    );
    assert!(closed.success, "{}", message_of(&closed));
    drop(mobile);

    let desktop = desktop_backend(&paths.root);
    let opened = call(
        &desktop,
        "BackendCollectionService",
        "open_collection",
        &open,
    );
    assert!(opened.success, "{}", message_of(&opened));
    assert!(marker_path(&paths.collection).is_file());
    assert!(!fsrs_enabled(&desktop));
    assert_eq!(
        fsrs_init::maybe_initialize(&desktop, &open).unwrap(),
        FsrsInitOutcome::AlreadyMarked
    );
}

#[test]
fn app_update_deck_configs_is_denied() {
    let dir = tempfile::TempDir::new_in("/tmp").unwrap();
    let paths = col_paths(dir.path());
    let backend = open_desktop_collection(&paths);
    assert!(fsrs_enabled(&backend), "internal init enables FSRS");
    let denied = call(
        &backend,
        "BackendDeckConfigService",
        "update_deck_configs",
        &anki_proto::generic::Empty {},
    );
    assert!(!denied.success);
    assert!(
        message_of(&denied)
            .contains("denied: BackendDeckConfigService.update_deck_configs (not on allowlist)"),
        "{}",
        message_of(&denied)
    );
}

#[test]
fn desktop_rejects_requests_over_4_mib_and_calls_before_open() {
    let dir = tempfile::TempDir::new_in("/tmp").unwrap();
    let paths = col_paths(dir.path());
    let backend = desktop_backend(&paths.root);
    let (service, method) = index::lookup("BackendDecksService", "get_deck_names").unwrap();
    let huge = command(&backend, service, method, vec![0; 4 * 1024 * 1024 + 1]);
    assert!(
        message_of(&huge).contains("exceeds 4 MiB"),
        "{}",
        message_of(&huge)
    );

    let closed = call(
        &backend,
        "BackendDecksService",
        "get_deck_names",
        &anki_proto::generic::Empty {},
    );
    assert!(
        message_of(&closed).contains("collection is not open"),
        "{}",
        message_of(&closed)
    );
    let close_while_closed = call(
        &backend,
        "BackendCollectionService",
        "close_collection",
        &anki_proto::collection::CloseCollectionRequest {
            downgrade_to_schema11: false,
        },
    );
    if !close_while_closed.success {
        assert!(
            !message_of(&close_while_closed).contains("denied:"),
            "{}",
            message_of(&close_while_closed)
        );
    }

    let opened = call(
        &backend,
        "BackendCollectionService",
        "open_collection",
        &open_request(&paths),
    );
    assert!(opened.success, "{}", message_of(&opened));
    let names = call(
        &backend,
        "BackendDecksService",
        "get_deck_names",
        &anki_proto::decks::GetDeckNamesRequest {
            skip_empty_default: false,
            include_filtered: true,
        },
    );
    assert!(names.success, "{}", message_of(&names));
}

#[test]
fn get_cloze_field_ords_rejects_a_missing_notetype_without_panicking() {
    let dir = tempfile::TempDir::new_in("/tmp").unwrap();
    let paths = col_paths(dir.path());
    let backend = open_desktop_collection(&paths);
    let response = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        call(
            &backend,
            "BackendNotetypesService",
            "get_cloze_field_ords",
            &anki_proto::notetypes::NotetypeId { ntid: 0 },
        )
    }));
    let response = response.expect("panic escaped the bridge");
    assert!(!response.success);
    assert!(
        message_of(&response).contains("does not exist"),
        "{}",
        message_of(&response)
    );
}

#[test]
fn answer_card_compares_new_state_before_filling_the_clock() {
    let source = include_str!("validators.rs");
    let check = source
        .find("new_state.encode_to_vec() != expected")
        .expect("byte compare");
    let fill = source
        .find("fill_answered_at_millis(&mut answer")
        .expect("clock fill");
    assert!(
        check < fill,
        "new_state is compared before answered_at_millis is overwritten"
    );

    let dir = tempfile::TempDir::new_in("/tmp").unwrap();
    let paths = col_paths(dir.path());
    let backend = open_desktop_collection(&paths);
    let card_id = add_basic_card(&backend);
    let offered = scheduling_states(&backend, card_id);
    let good = offered.good.clone().unwrap();
    let year_ago = 1_600_000_000_000;
    let tweaked = one_byte_different_state(&good);
    let denied = call(
        &backend,
        "BackendSchedulerService",
        "answer_card",
        &answer(card_id, offered.current.clone(), tweaked, 1_000, year_ago),
    );
    assert!(
        message_of(&denied).contains("does not match"),
        "{}",
        message_of(&denied)
    );

    let before = SystemTime::now()
        .duration_since(SystemTime::UNIX_EPOCH)
        .unwrap()
        .as_millis() as i64;
    let answered = call(
        &backend,
        "BackendSchedulerService",
        "answer_card",
        &answer(card_id, offered.current, good, 1_000, year_ago),
    );
    assert!(answered.success, "{}", message_of(&answered));
    let revlog_id = latest_revlog_id(&backend);
    assert!(
        revlog_id >= before.saturating_sub(2_000),
        "revlog id {revlog_id} kept the client clock {year_ago}"
    );
}

#[test]
fn fsrs_init_writes_no_marker_when_update_deck_configs_fails() {
    let dir = tempfile::TempDir::new_in("/tmp").unwrap();
    let paths = col_paths(dir.path());
    let backend = desktop_backend(&paths.root);
    let open = open_request(&paths);
    // Open through the raw channel so init has not run yet.
    dispatch_message(
        &backend,
        "BackendCollectionService",
        "open_collection",
        &open,
    )
    .unwrap();
    fsrs_init::fail_next_fsrs_update();
    let err = fsrs_init::maybe_initialize(&backend, &open).unwrap_err();
    assert!(
        !marker_path(&paths.collection).exists(),
        "marker written after a failed update: {err}"
    );
    assert!(!fsrs_enabled(&backend), "{err}");
}

#[test]
fn fsrs_init_writes_a_marker_when_fsrs_is_already_on() {
    let dir = tempfile::TempDir::new_in("/tmp").unwrap();
    let paths = col_paths(dir.path());
    let backend = open_desktop_collection(&paths);
    let marker = marker_path(&paths.collection);
    assert!(marker.is_file());
    assert!(fsrs_enabled(&backend));
    std::fs::remove_file(&marker).unwrap();
    let open = open_request(&paths);
    assert_eq!(
        fsrs_init::maybe_initialize(&backend, &open).unwrap(),
        FsrsInitOutcome::AlreadyEnabled
    );
    assert!(
        marker.is_file(),
        "already-on collection did not get a marker"
    );
    assert!(fsrs_enabled(&backend));
}

#[test]
fn validates_search_requires_a_built_string() {
    let dir = tempfile::TempDir::new_in("/tmp").unwrap();
    let paths = col_paths(dir.path());
    let backend = open_desktop_collection(&paths);
    let raw = anki_proto::search::SearchRequest {
        search: "deck:Default".into(),
        order: None,
    };
    for method in ["search_notes", "search_cards"] {
        let denied = call(&backend, "BackendSearchService", method, &raw);
        assert!(!denied.success, "{method}");
        assert!(
            message_of(&denied).contains("search builder"),
            "{method}: {}",
            message_of(&denied)
        );
    }
    let built = call(
        &backend,
        "BackendSearchService",
        "build_search_string",
        &anki_proto::search::SearchNode {
            filter: Some(anki_proto::search::search_node::Filter::Deck(
                "Default".into(),
            )),
        },
    );
    assert!(built.success, "{}", message_of(&built));
    let search = anki_proto::generic::String::decode(built.payload.as_slice())
        .unwrap()
        .val;
    let request = anki_proto::search::SearchRequest {
        search,
        order: None,
    };
    for method in ["search_notes", "search_cards"] {
        let allowed = call(&backend, "BackendSearchService", method, &request);
        assert!(allowed.success, "{method}: {}", message_of(&allowed));
    }
}

#[test]
fn validates_add_deck() {
    let dir = tempfile::TempDir::new_in("/tmp").unwrap();
    let paths = col_paths(dir.path());
    let backend = open_desktop_collection(&paths);
    let mut deck = new_deck(&backend);
    deck.name.clear();
    let denied = call(&backend, "BackendDecksService", "add_deck", &deck);
    assert!(
        message_of(&denied).contains("empty"),
        "{}",
        message_of(&denied)
    );

    let mut nested = new_deck(&backend);
    nested.name = "Missing::Child".into();
    let created = call(&backend, "BackendDecksService", "add_deck", &nested);
    assert!(created.success, "{}", message_of(&created));

    let mut added = new_deck(&backend);
    added.name = "German".into();
    let ok = call(&backend, "BackendDecksService", "add_deck", &added);
    assert!(ok.success, "{}", message_of(&ok));
}

fn new_deck(backend: &crate::api::AnkiBackend) -> anki_proto::decks::Deck {
    let bytes = dispatch_message(
        backend,
        "BackendDecksService",
        "new_deck",
        &anki_proto::generic::Empty {},
    )
    .expect("new deck");
    anki_proto::decks::Deck::decode(bytes.as_slice()).unwrap()
}

#[test]
fn validates_remove_notes() {
    let dir = tempfile::TempDir::new_in("/tmp").unwrap();
    let paths = col_paths(dir.path());
    let backend = open_desktop_collection(&paths);
    let empty = call(
        &backend,
        "BackendNotesService",
        "remove_notes",
        &anki_proto::notes::RemoveNotesRequest {
            note_ids: vec![],
            card_ids: vec![],
        },
    );
    assert!(
        message_of(&empty).contains("note_ids is empty"),
        "{}",
        message_of(&empty)
    );
    let missing = call(
        &backend,
        "BackendNotesService",
        "remove_notes",
        &anki_proto::notes::RemoveNotesRequest {
            note_ids: vec![99],
            card_ids: vec![],
        },
    );
    assert!(
        message_of(&missing).contains("does not exist"),
        "{}",
        message_of(&missing)
    );
    let note_id = add_basic_note(&backend);
    let removed = call(
        &backend,
        "BackendNotesService",
        "remove_notes",
        &anki_proto::notes::RemoveNotesRequest {
            note_ids: vec![note_id],
            card_ids: vec![],
        },
    );
    assert!(removed.success, "{}", message_of(&removed));
}

#[test]
fn open_collection_rejects_symlink_targets_outside_data_dir() {
    let dir = tempfile::TempDir::new_in("/tmp").unwrap();
    let root = dir.path().join("data");
    std::fs::create_dir_all(root.join("tmp")).unwrap();
    crate::api::prepare_runtime(root.join("tmp").to_string_lossy().into_owned());
    std::fs::create_dir_all(root.join("collection.media")).unwrap();
    let outside = tempfile::TempDir::new_in("/tmp").unwrap();
    std::fs::create_dir_all(outside.path().join("media")).unwrap();
    std::fs::write(outside.path().join("db"), b"x").unwrap();
    std::fs::write(outside.path().join("col"), b"x").unwrap();
    let backend = desktop_backend(&root);

    let media = root.join("collection.media");
    std::fs::remove_dir_all(&media).unwrap();
    std::os::unix::fs::symlink(outside.path().join("media"), &media).unwrap();
    let denied = call(
        &backend,
        "BackendCollectionService",
        "open_collection",
        &open_paths(&root),
    );
    assert!(
        message_of(&denied).contains("escapes data_dir"),
        "media folder: {}",
        message_of(&denied)
    );
    std::fs::remove_file(&media).unwrap();
    std::fs::create_dir_all(&media).unwrap();

    let db = root.join("collection.media.db");
    std::os::unix::fs::symlink(outside.path().join("db"), &db).unwrap();
    let denied = call(
        &backend,
        "BackendCollectionService",
        "open_collection",
        &open_paths(&root),
    );
    assert!(
        message_of(&denied).contains("escapes data_dir"),
        "media db: {}",
        message_of(&denied)
    );
    std::fs::remove_file(&db).unwrap();

    let collection = root.join("collection.anki2");
    std::os::unix::fs::symlink(outside.path().join("col"), &collection).unwrap();
    let denied = call(
        &backend,
        "BackendCollectionService",
        "open_collection",
        &open_paths(&root),
    );
    assert!(
        message_of(&denied).contains("escapes data_dir"),
        "collection file: {}",
        message_of(&denied)
    );
    std::fs::remove_file(&collection).unwrap();

    std::os::unix::fs::symlink(outside.path().join("missing"), &collection).unwrap();
    let denied = call(
        &backend,
        "BackendCollectionService",
        "open_collection",
        &open_paths(&root),
    );
    assert!(!denied.success, "dangling collection symlink was allowed");
    assert!(
        message_of(&denied).contains("collection_path"),
        "dangling: {}",
        message_of(&denied)
    );
}

fn open_paths(root: &Path) -> anki_proto::collection::OpenCollectionRequest {
    anki_proto::collection::OpenCollectionRequest {
        collection_path: root.join("collection.anki2").to_string_lossy().into_owned(),
        media_folder_path: root.join("collection.media").to_string_lossy().into_owned(),
        media_db_path: root
            .join("collection.media.db")
            .to_string_lossy()
            .into_owned(),
    }
}

#[test]
fn open_collection_sends_the_canonical_path() {
    let dir = tempfile::TempDir::new_in("/tmp").unwrap();
    let real = dir.path().join("real");
    std::fs::create_dir_all(&real).unwrap();
    let link = dir.path().join("link");
    std::os::unix::fs::symlink(&real, &link).unwrap();
    let root = link.join("collection");
    let paths = col_paths(&root);
    let stored = paths.root.canonicalize().unwrap();
    let spelled = paths.collection.to_string_lossy().into_owned();
    let canonical = super::desktop::require_inside_data_dir(&spelled, &stored).unwrap();
    assert_eq!(canonical, stored.join("collection.anki2"));
    assert_ne!(canonical.to_string_lossy().as_ref(), spelled.as_str());
    let backend = desktop_backend(&paths.root);
    let opened = call(
        &backend,
        "BackendCollectionService",
        "open_collection",
        &open_request(&paths),
    );
    assert!(opened.success, "{}", message_of(&opened));
    let sent = crate::api::LAST_OPEN_COLLECTION_INPUT
        .lock()
        .unwrap()
        .clone()
        .expect("open_collection was not dispatched");
    let request = anki_proto::collection::OpenCollectionRequest::decode(sent.as_slice()).unwrap();
    let expected_collection = stored.join("collection.anki2");
    let expected_media = stored.join("collection.media");
    let expected_db = stored.join("collection.media.db");
    assert_eq!(
        request.collection_path,
        expected_collection.to_string_lossy()
    );
    assert_eq!(request.media_folder_path, expected_media.to_string_lossy());
    assert_eq!(request.media_db_path, expected_db.to_string_lossy());
    assert_ne!(request.collection_path, spelled);
}

#[test]
fn a_caught_panic_poisons_the_session() {
    let dir = tempfile::TempDir::new_in("/tmp").unwrap();
    let paths = col_paths(dir.path());
    let backend = open_desktop_collection(&paths);
    let panicked = dispatch_message(
        &backend,
        "BackendNotetypesService",
        "get_cloze_field_ords",
        &anki_proto::notetypes::NotetypeId { ntid: 999_999 },
    );
    let message = panicked.unwrap_err();
    assert!(
        message.contains("panicked"),
        "missing notetype did not panic: {message}"
    );
    let later = call(
        &backend,
        "BackendDecksService",
        "get_deck_names",
        &anki_proto::decks::GetDeckNamesRequest {
            skip_empty_default: false,
            include_filtered: false,
        },
    );
    assert!(
        message_of(&later).contains("backend poisoned"),
        "{}",
        message_of(&later)
    );
}

fn fresh_basic_note(backend: &crate::api::AnkiBackend) -> anki_proto::notes::Note {
    let id_bytes = dispatch_message(
        backend,
        "BackendNotetypesService",
        "get_notetype_id_by_name",
        &anki_proto::generic::String {
            val: "Basic".into(),
        },
    )
    .unwrap();
    let notetype = anki_proto::notetypes::NotetypeId::decode(id_bytes.as_slice()).unwrap();
    let bytes = dispatch_message(backend, "BackendNotesService", "new_note", &notetype).unwrap();
    let mut note = anki_proto::notes::Note::decode(bytes.as_slice()).unwrap();
    note.fields[0] = "앞".into();
    note.fields[1] = "<b>뒤</b> <img src=\"paste-abc.png\">".into();
    note
}

fn add_request(note: anki_proto::notes::Note, deck_id: i64) -> anki_proto::notes::AddNoteRequest {
    anki_proto::notes::AddNoteRequest {
        note: Some(note),
        deck_id,
    }
}

#[test]
fn validates_add_note() {
    let dir = tempfile::TempDir::new_in("/tmp").unwrap();
    let paths = col_paths(dir.path());
    let backend = open_desktop_collection(&paths);
    let added = call(
        &backend,
        "BackendNotesService",
        "add_note",
        &add_request(fresh_basic_note(&backend), 1),
    );
    assert!(added.success, "{}", message_of(&added));

    let mut with_id = fresh_basic_note(&backend);
    with_id.id = 7;
    let denied = call(
        &backend,
        "BackendNotesService",
        "add_note",
        &add_request(with_id, 1),
    );
    assert!(
        message_of(&denied).contains("id"),
        "{}",
        message_of(&denied)
    );

    let mut short = fresh_basic_note(&backend);
    short.fields.pop();
    let denied = call(
        &backend,
        "BackendNotesService",
        "add_note",
        &add_request(short, 1),
    );
    assert!(
        message_of(&denied).contains("field count"),
        "{}",
        message_of(&denied)
    );

    let denied = call(
        &backend,
        "BackendNotesService",
        "add_note",
        &add_request(fresh_basic_note(&backend), 99),
    );
    assert!(
        message_of(&denied).contains("deck"),
        "{}",
        message_of(&denied)
    );

    let filtered = create_filtered_deck(&backend);
    let denied = call(
        &backend,
        "BackendNotesService",
        "add_note",
        &add_request(fresh_basic_note(&backend), filtered),
    );
    assert!(
        message_of(&denied).contains("normal"),
        "{}",
        message_of(&denied)
    );

    for (label, field) in [
        ("control", "a\u{0001}b"),
        ("script", "<SCRIPT>x</script>"),
        ("event", "<b onerror =alert(1)>x</b>"),
        ("url", "<a href=\"java&#115;cript:alert(1)\">x</a>"),
        ("img-abs", "<img src=\"/etc/x.png\">"),
        ("img-dot", "<img src=\"../x.png\">"),
        ("sound", "[sound:../evil.mp3]"),
        ("space-tag", "ok"),
    ] {
        let mut note = fresh_basic_note(&backend);
        if label == "space-tag" {
            note.tags = vec!["bad tag".into()];
        } else {
            note.fields[0] = field.into();
        }
        let denied = call(
            &backend,
            "BackendNotesService",
            "add_note",
            &add_request(note, 1),
        );
        assert!(
            !denied.success,
            "{label} was allowed: {}",
            message_of(&denied)
        );
    }

    let mut huge = fresh_basic_note(&backend);
    huge.fields[0] = "a".repeat(512 * 1024 + 1);
    let denied = call(
        &backend,
        "BackendNotesService",
        "add_note",
        &add_request(huge, 1),
    );
    assert!(
        message_of(&denied).contains("512"),
        "{}",
        message_of(&denied)
    );
}

#[test]
fn validates_update_notes() {
    let dir = tempfile::TempDir::new_in("/tmp").unwrap();
    let paths = col_paths(dir.path());
    let backend = open_desktop_collection(&paths);
    let note_id = add_basic_note(&backend);
    let mut current = load_saved_note(&backend, note_id);
    current.fields[0] = "고친 앞".into();
    let updated = call(
        &backend,
        "BackendNotesService",
        "update_notes",
        &anki_proto::notes::UpdateNotesRequest {
            notes: vec![current.clone()],
            skip_undo_entry: false,
        },
    );
    assert!(updated.success, "{}", message_of(&updated));

    let again = load_saved_note(&backend, note_id);
    let noop = call(
        &backend,
        "BackendNotesService",
        "update_notes",
        &anki_proto::notes::UpdateNotesRequest {
            notes: vec![again.clone()],
            skip_undo_entry: false,
        },
    );
    assert!(noop.success, "{}", message_of(&noop));

    let mut scripted = fresh_basic_note(&backend);
    scripted.fields[1] = "<script>kept</script>".into();
    let stored = dispatch_message(
        &backend,
        "BackendNotesService",
        "add_note",
        &add_request(scripted, 1),
    )
    .unwrap();
    let stored_id = anki_proto::notes::AddNoteResponse::decode(stored.as_slice())
        .unwrap()
        .note_id;
    let mut legacy = load_saved_note(&backend, stored_id);
    assert!(legacy.fields[1].to_ascii_lowercase().contains("script"));
    legacy.fields[0] = "다른 필드만".into();
    let kept = call(
        &backend,
        "BackendNotesService",
        "update_notes",
        &anki_proto::notes::UpdateNotesRequest {
            notes: vec![legacy.clone()],
            skip_undo_entry: false,
        },
    );
    assert!(kept.success, "{}", message_of(&kept));

    let mut skip = load_saved_note(&backend, note_id);
    let denied = call(
        &backend,
        "BackendNotesService",
        "update_notes",
        &anki_proto::notes::UpdateNotesRequest {
            notes: vec![skip.clone()],
            skip_undo_entry: true,
        },
    );
    assert!(
        message_of(&denied).contains("skip_undo_entry"),
        "{}",
        message_of(&denied)
    );

    skip.guid = "changed".into();
    let denied = call(
        &backend,
        "BackendNotesService",
        "update_notes",
        &anki_proto::notes::UpdateNotesRequest {
            notes: vec![skip],
            skip_undo_entry: false,
        },
    );
    assert!(
        message_of(&denied).contains("guid"),
        "{}",
        message_of(&denied)
    );

    let mut changed = load_saved_note(&backend, note_id);
    changed.fields[0] = "<script>no</script>".into();
    let denied = call(
        &backend,
        "BackendNotesService",
        "update_notes",
        &anki_proto::notes::UpdateNotesRequest {
            notes: vec![changed],
            skip_undo_entry: false,
        },
    );
    assert!(
        message_of(&denied).contains("script"),
        "{}",
        message_of(&denied)
    );
}

fn load_saved_note(backend: &crate::api::AnkiBackend, id: i64) -> anki_proto::notes::Note {
    let bytes = dispatch_message(
        backend,
        "BackendNotesService",
        "get_note",
        &anki_proto::notes::NoteId { nid: id },
    )
    .unwrap();
    anki_proto::notes::Note::decode(bytes.as_slice()).unwrap()
}
