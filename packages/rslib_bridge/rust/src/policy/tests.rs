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

#[test]
fn validates_undo_and_redo() {
    let dir = tempfile::TempDir::new_in("/tmp").unwrap();
    let paths = col_paths(dir.path());
    let backend = open_desktop_collection(&paths);
    undo_is_empty(&backend);
    let nonempty = call(
        &backend,
        "BackendCollectionService",
        "undo",
        &anki_proto::generic::String { val: "no".into() },
    );
    assert!(
        message_of(&nonempty).contains("empty"),
        "{}",
        message_of(&nonempty)
    );
    let idle = call(
        &backend,
        "BackendCollectionService",
        "undo",
        &anki_proto::generic::Empty {},
    );
    assert!(!idle.success, "undo with an empty stack succeeded");
    assert!(
        !message_of(&idle).contains("panicked") && !message_of(&idle).contains("backend poisoned"),
        "{}",
        message_of(&idle)
    );
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
    // Resident table after ImportAnkiPackage: 15 validated + 57 name-only
    // = 72 forwarded. 16 pending and 1 deferred stay. 89 rows in all.
    assert_eq!(validated, 15);
    assert_eq!(name_only, 57);
    assert_eq!(pending, 16);
    assert_eq!(deferred, 1);
    assert_eq!(ALLOWLIST.len(), 89);
    assert_eq!(forwarded_names().len(), 72);
    let mut e_validated = 0;
    let mut e_name_only = 0;
    let mut e_seen = std::collections::HashSet::new();
    for row in super::import_e::E_ALLOWLIST {
        assert!(
            e_seen.insert((row.service, row.method)),
            "duplicate import-e {}.{}",
            row.service,
            row.method
        );
        assert!(
            index::lookup(row.service, row.method).is_some(),
            "import-e {}.{} is not in this rslib build",
            row.service,
            row.method
        );
        match row.status {
            Status::Validated => e_validated += 1,
            Status::NameOnly => e_name_only += 1,
            Status::Pending | Status::Deferred => panic!("import-e has no pending row"),
        }
    }
    // Import-E is 16 rows (9 validated, 7 name-only), all forwarded.
    // Combined rows: 89 + 16 = 105. Combined forwarded: 72 + 16 = 88.
    assert_eq!(e_validated, 9);
    assert_eq!(e_name_only, 7);
    assert_eq!(super::import_e::E_ALLOWLIST.len(), 16);
    assert_eq!(ALLOWLIST.len() + super::import_e::E_ALLOWLIST.len(), 105);
    assert_eq!(
        forwarded_names().len() + super::import_e::E_ALLOWLIST.len(),
        88
    );

    let pending_methods: std::collections::HashSet<_> = ALLOWLIST
        .iter()
        .filter(|row| row.status == Status::Pending)
        .map(|row| row.method)
        .collect();
    for method in [
        "add_deck",
        "reparent_decks",
        "remove_decks",
        "add_note",
        "add_notes",
        "update_notes",
        "add_notetype",
        "update_notetype",
        "remove_notetype",
        "change_notetype",
        "remove_notes",
        "add_media_file",
        "add_image_occlusion_notetype",
        "update_image_occlusion_note",
        "get_image_occlusion_note",
        "export_anki_package",
    ] {
        assert!(pending_methods.contains(method), "{method}");
    }
    assert_eq!(pending_methods.len(), 16);
}

#[test]
fn print_allowlist_table() {
    let table = allowlist_markdown();
    println!("{table}");
    assert_eq!(
        table.lines().filter(|line| line.starts_with("| ")).count(),
        90
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
fn desktop_denies_calls_outside_the_allowed_72() {
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
    assert_eq!(pending, 16);
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
        ("BackendImportExportService", "import_csv"),
        ("BackendImportExportService", "import_json_file"),
        ("BackendImportExportService", "import_json_string"),
        ("BackendImportExportService", "import_collection_package"),
        ("BackendImportExportService", "export_note_csv"),
        ("BackendImportExportService", "export_card_csv"),
        ("BackendMediaService", "add_media_from_url"),
        ("BackendMediaService", "add_media_from_path"),
        ("BackendSearchService", "set_active_browser_columns"),
        ("BackendCollectionService", "check_database"),
        ("BackendAnkidroidService", "run_db_command"),
        ("BackendDecksService", "update_deck"),
        ("BackendSchedulerService", "empty_filtered_deck"),
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
    answer_rated(
        card_id,
        current,
        new_state,
        anki_proto::scheduler::card_answer::Rating::Good as i32,
        milliseconds_taken,
        answered_at_millis,
    )
}

fn answer_rated(
    card_id: i64,
    current: Option<anki_proto::scheduler::SchedulingState>,
    new_state: anki_proto::scheduler::SchedulingState,
    rating: i32,
    milliseconds_taken: u32,
    answered_at_millis: i64,
) -> anki_proto::scheduler::CardAnswer {
    anki_proto::scheduler::CardAnswer {
        card_id,
        current_state: current,
        new_state: Some(new_state),
        rating,
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

    let mut none = request.clone();
    none.order = Some(anki_proto::search::SortOrder {
        value: Some(anki_proto::search::sort_order::Value::None(
            anki_proto::generic::Empty {},
        )),
    });
    let mut builtin = request.clone();
    builtin.order = Some(anki_proto::search::SortOrder {
        value: Some(anki_proto::search::sort_order::Value::Builtin(
            anki_proto::search::sort_order::Builtin {
                column: "noteFld".into(),
                reverse: true,
            },
        )),
    });
    let mut custom = request.clone();
    custom.order = Some(anki_proto::search::SortOrder {
        value: Some(anki_proto::search::sort_order::Value::Custom(
            "due desc".into(),
        )),
    });
    let mut unknown = request;
    unknown.order = Some(anki_proto::search::SortOrder {
        value: Some(anki_proto::search::sort_order::Value::Builtin(
            anki_proto::search::sort_order::Builtin {
                column: "not_a_column".into(),
                reverse: false,
            },
        )),
    });
    for method in ["search_notes", "search_cards"] {
        let allowed = call(&backend, "BackendSearchService", method, &none);
        assert!(allowed.success, "{method} none: {}", message_of(&allowed));
        let allowed = call(&backend, "BackendSearchService", method, &builtin);
        assert!(
            allowed.success,
            "{method} builtin: {}",
            message_of(&allowed)
        );
        let denied = call(&backend, "BackendSearchService", method, &custom);
        assert!(
            message_of(&denied).contains("custom sort order"),
            "{method}: {}",
            message_of(&denied)
        );
        let denied = call(&backend, "BackendSearchService", method, &unknown);
        assert!(
            message_of(&denied).contains("not allowlisted"),
            "{method}: {}",
            message_of(&denied)
        );
    }
}

#[test]
fn undo_restores_an_answered_card_and_rejects_the_stale_answer() {
    let dir = tempfile::TempDir::new_in("/tmp").unwrap();
    let paths = col_paths(dir.path());
    let backend = open_desktop_collection(&paths);
    let card_id = add_basic_card(&backend);
    let current = call(
        &backend,
        "BackendDecksService",
        "set_current_deck",
        &anki_proto::decks::DeckId { did: 1 },
    );
    assert!(current.success, "{}", message_of(&current));
    assert_eq!(
        queued_ids(&backend),
        vec![card_id],
        "the new card was not offered before the answer"
    );
    let offered = scheduling_states(&backend, card_id);
    let easy = offered.easy.clone().unwrap();
    let easy_rating = anki_proto::scheduler::card_answer::Rating::Easy as i32;
    let answered = call(
        &backend,
        "BackendSchedulerService",
        "answer_card",
        &answer_rated(
            card_id,
            offered.current,
            easy.clone(),
            easy_rating,
            1_000,
            0,
        ),
    );
    assert!(answered.success, "{}", message_of(&answered));
    let after_answer = queued_ids(&backend);
    assert!(
        after_answer.is_empty(),
        "answered card stayed in the queue: {after_answer:?} queue={}",
        card_queue(&backend, card_id)
    );

    let undone = call(
        &backend,
        "BackendCollectionService",
        "undo",
        &anki_proto::generic::Empty {},
    );
    assert!(undone.success, "{}", message_of(&undone));
    let stale = call(
        &backend,
        "BackendSchedulerService",
        "answer_card",
        &answer_rated(card_id, None, easy, easy_rating, 1_000, 0),
    );
    assert!(
        message_of(&stale).contains("was not offered"),
        "{}",
        message_of(&stale)
    );
    let restored = queued_ids(&backend);
    assert_eq!(
        restored,
        vec![card_id],
        "after undo queue={restored:?} card_queue={}",
        card_queue(&backend, card_id)
    );

    let redone = call(
        &backend,
        "BackendCollectionService",
        "redo",
        &anki_proto::generic::Empty {},
    );
    assert!(redone.success, "{}", message_of(&redone));
    assert!(
        queued_ids(&backend).is_empty(),
        "redo did not take the card back out of the queue"
    );
}

#[test]
fn undo_clears_the_offer_for_a_card_that_was_not_answered() {
    let dir = tempfile::TempDir::new_in("/tmp").unwrap();
    let paths = col_paths(dir.path());
    let backend = open_desktop_collection(&paths);
    let first = add_basic_card(&backend);
    let second = add_basic_card(&backend);
    let current = call(
        &backend,
        "BackendDecksService",
        "set_current_deck",
        &anki_proto::decks::DeckId { did: 1 },
    );
    assert!(current.success, "{}", message_of(&current));
    let offered_first = scheduling_states(&backend, first);
    let offered_second = scheduling_states(&backend, second);
    let easy = offered_first.easy.clone().unwrap();
    let easy_rating = anki_proto::scheduler::card_answer::Rating::Easy as i32;
    let answered = call(
        &backend,
        "BackendSchedulerService",
        "answer_card",
        &answer_rated(first, offered_first.current, easy, easy_rating, 1_000, 0),
    );
    assert!(answered.success, "{}", message_of(&answered));
    let undone = call(
        &backend,
        "BackendCollectionService",
        "undo",
        &anki_proto::generic::Empty {},
    );
    assert!(undone.success, "{}", message_of(&undone));
    let stale = call(
        &backend,
        "BackendSchedulerService",
        "answer_card",
        &answer_rated(
            second,
            offered_second.current,
            offered_second.easy.unwrap(),
            easy_rating,
            1_000,
            0,
        ),
    );
    assert!(
        message_of(&stale).contains("was not offered"),
        "{}",
        message_of(&stale)
    );
    assert_eq!(card_queue(&backend, second), 0);
}

fn card_queue(backend: &crate::api::AnkiBackend, card_id: i64) -> i32 {
    let response = call(
        backend,
        "BackendCardsService",
        "get_card",
        &anki_proto::cards::CardId { cid: card_id },
    );
    assert!(response.success, "{}", message_of(&response));
    anki_proto::cards::Card::decode(response.payload.as_slice())
        .unwrap()
        .queue
}

fn queued_ids(backend: &crate::api::AnkiBackend) -> Vec<i64> {
    let response = call(
        backend,
        "BackendSchedulerService",
        "get_queued_cards",
        &anki_proto::scheduler::GetQueuedCardsRequest {
            fetch_limit: 10,
            intraday_learning_only: false,
        },
    );
    assert!(response.success, "{}", message_of(&response));
    let queued = anki_proto::scheduler::QueuedCards::decode(response.payload.as_slice()).unwrap();
    queued
        .cards
        .into_iter()
        .filter_map(|card| card.card.map(|card| card.id))
        .collect()
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

#[test]
fn validates_rename_deck() {
    let dir = tempfile::TempDir::new_in("/tmp").unwrap();
    let paths = col_paths(dir.path());
    let backend = open_desktop_collection(&paths);
    // The default deck exists without AddDeck, which stays closed in this PR.
    let id = 1_i64;
    let existing = dispatch_message(
        &backend,
        "BackendDecksService",
        "get_deck",
        &anki_proto::decks::DeckId { did: id },
    );
    assert!(existing.is_ok(), "{:?}", existing.err());
    let renamed = call(
        &backend,
        "BackendDecksService",
        "rename_deck",
        &anki_proto::decks::RenameDeckRequest {
            deck_id: id,
            new_name: "Deutsch".into(),
        },
    );
    assert!(renamed.success, "{}", message_of(&renamed));
    for name in ["", "A::::B", "::A", "A::"] {
        let denied = call(
            &backend,
            "BackendDecksService",
            "rename_deck",
            &anki_proto::decks::RenameDeckRequest {
                deck_id: id,
                new_name: name.into(),
            },
        );
        assert!(!denied.success, "{name} was allowed");
    }
    let long = "a".repeat(256);
    let denied = call(
        &backend,
        "BackendDecksService",
        "rename_deck",
        &anki_proto::decks::RenameDeckRequest {
            deck_id: id,
            new_name: long,
        },
    );
    assert!(
        message_of(&denied).contains("255"),
        "{}",
        message_of(&denied)
    );
    let missing = call(
        &backend,
        "BackendDecksService",
        "rename_deck",
        &anki_proto::decks::RenameDeckRequest {
            deck_id: 0,
            new_name: "Nope".into(),
        },
    );
    assert!(
        message_of(&missing).contains("does not exist"),
        "{}",
        message_of(&missing)
    );
}

const BATCH_V4: &str = "3f2b8a64-1c0e-4d5a-9b7e-0a1b2c3d4e5f";
const OTHER_V4: &str = "11111111-1111-4111-8111-111111111111";
const THIRD_V4: &str = "22222222-2222-4222-8222-222222222222";
const BATCH_V5: &str = "ec425e06-0eeb-5cbc-b4c8-3818366d46e9";

fn policy_denied(response: &ProtoResponse) -> bool {
    !response.success && message_of(response).contains("denied:")
}

fn resident_import(
    path: String,
    with_deck_configs: bool,
) -> anki_proto::import_export::ImportAnkiPackageRequest {
    anki_proto::import_export::ImportAnkiPackageRequest {
        package_path: path,
        options: Some(import_options(
            anki_proto::import_export::ImportAnkiPackageUpdateCondition::IfNewer as i32,
            with_deck_configs,
        )),
    }
}

fn e_import(path: String) -> anki_proto::import_export::ImportAnkiPackageRequest {
    anki_proto::import_export::ImportAnkiPackageRequest {
        package_path: path,
        options: Some(import_options(
            anki_proto::import_export::ImportAnkiPackageUpdateCondition::Never as i32,
            true,
        )),
    }
}

fn import_options(
    update_notes: i32,
    with_deck_configs: bool,
) -> anki_proto::import_export::ImportAnkiPackageOptions {
    anki_proto::import_export::ImportAnkiPackageOptions {
        merge_notetypes: false,
        update_notes,
        update_notetypes: anki_proto::import_export::ImportAnkiPackageUpdateCondition::Never as i32,
        with_scheduling: true,
        with_deck_configs,
    }
}

fn whole_collection_export(
    path: String,
    with_deck_configs: bool,
) -> anki_proto::import_export::ExportAnkiPackageRequest {
    anki_proto::import_export::ExportAnkiPackageRequest {
        out_path: path,
        options: Some(anki_proto::import_export::ExportAnkiPackageOptions {
            with_scheduling: true,
            with_deck_configs,
            with_media: true,
            legacy: false,
        }),
        limit: Some(anki_proto::import_export::ExportLimit {
            limit: Some(
                anki_proto::import_export::export_limit::Limit::WholeCollection(
                    anki_proto::generic::Empty {},
                ),
            ),
        }),
    }
}

fn export_package(backend: &crate::api::AnkiBackend, out: &Path) {
    dispatch_message(
        backend,
        "BackendImportExportService",
        "export_anki_package",
        &whole_collection_export(out.to_string_lossy().into_owned(), true),
    )
    .unwrap_or_else(|err| panic!("export {}: {err}", out.display()));
}

fn assert_denied(response: &ProtoResponse, needle: &str) {
    assert!(policy_denied(response), "{}", message_of(response));
    assert!(
        message_of(response).contains(needle),
        "expected {needle} in {}",
        message_of(response)
    );
}

#[test]
fn validates_resident_import_anki_package() {
    let dir = tempfile::TempDir::new_in("/tmp").unwrap();
    let paths = col_paths(dir.path());
    let backend = open_desktop_collection(&paths);
    let _card = add_basic_card(&backend);
    let staged_dir = dir.path().join("import").join("staged");
    let raw_dir = dir.path().join("import").join("raw");
    std::fs::create_dir_all(&staged_dir).unwrap();
    std::fs::create_dir_all(&raw_dir).unwrap();
    let staged = staged_dir.join(format!("{BATCH_V4}.apkg"));
    export_package(&backend, &staged);

    let imported = call(
        &backend,
        "BackendImportExportService",
        "import_anki_package",
        &resident_import(staged.to_string_lossy().into_owned(), true),
    );
    assert!(imported.success, "{}", message_of(&imported));
    let again = call(
        &backend,
        "BackendImportExportService",
        "import_anki_package",
        &resident_import(staged.to_string_lossy().into_owned(), false),
    );
    assert!(again.success, "{}", message_of(&again));

    let mut missing_options = resident_import(staged.to_string_lossy().into_owned(), true);
    missing_options.options = None;
    assert_denied(
        &call(
            &backend,
            "BackendImportExportService",
            "import_anki_package",
            &missing_options,
        ),
        "options must be set",
    );

    let mut merged = resident_import(staged.to_string_lossy().into_owned(), true);
    merged.options.as_mut().unwrap().merge_notetypes = true;
    assert_denied(
        &call(
            &backend,
            "BackendImportExportService",
            "import_anki_package",
            &merged,
        ),
        "merge_notetypes must be false",
    );

    let mut notes = resident_import(staged.to_string_lossy().into_owned(), true);
    notes.options.as_mut().unwrap().update_notes =
        anki_proto::import_export::ImportAnkiPackageUpdateCondition::Always as i32;
    assert_denied(
        &call(
            &backend,
            "BackendImportExportService",
            "import_anki_package",
            &notes,
        ),
        "update_notes must be IF_NEWER",
    );

    let mut notetypes = resident_import(staged.to_string_lossy().into_owned(), true);
    notetypes.options.as_mut().unwrap().update_notetypes =
        anki_proto::import_export::ImportAnkiPackageUpdateCondition::IfNewer as i32;
    assert_denied(
        &call(
            &backend,
            "BackendImportExportService",
            "import_anki_package",
            &notetypes,
        ),
        "update_notetypes must be NEVER",
    );

    let mut scheduling = resident_import(staged.to_string_lossy().into_owned(), true);
    scheduling.options.as_mut().unwrap().with_scheduling = false;
    assert_denied(
        &call(
            &backend,
            "BackendImportExportService",
            "import_anki_package",
            &scheduling,
        ),
        "with_scheduling must be true",
    );

    assert_denied(
        &call(
            &backend,
            "BackendImportExportService",
            "import_anki_package",
            &resident_import(format!("import/staged/{BATCH_V4}.apkg"), true),
        ),
        "not absolute",
    );
    let raw = raw_dir.join(format!("{BATCH_V4}.apkg"));
    std::fs::copy(&staged, &raw).unwrap();
    assert_denied(
        &call(
            &backend,
            "BackendImportExportService",
            "import_anki_package",
            &resident_import(raw.to_string_lossy().into_owned(), true),
        ),
        "import/staged",
    );
    let outside = tempfile::TempDir::new_in("/tmp").unwrap();
    let outside_file = outside.path().join(format!("{BATCH_V4}.apkg"));
    std::fs::copy(&staged, &outside_file).unwrap();
    assert_denied(
        &call(
            &backend,
            "BackendImportExportService",
            "import_anki_package",
            &resident_import(outside_file.to_string_lossy().into_owned(), true),
        ),
        "outside data_dir",
    );
    assert_denied(
        &call(
            &backend,
            "BackendImportExportService",
            "import_anki_package",
            &resident_import(
                staged_dir
                    .join(format!("{BATCH_V5}.apkg"))
                    .to_string_lossy()
                    .into_owned(),
                true,
            ),
        ),
        "uuid v4",
    );
    assert_denied(
        &call(
            &backend,
            "BackendImportExportService",
            "import_anki_package",
            &resident_import(
                staged_dir
                    .join(format!("{}.apkg", BATCH_V4.to_ascii_uppercase()))
                    .to_string_lossy()
                    .into_owned(),
                true,
            ),
        ),
        "uuid v4",
    );

    let evil = outside.path().join("evil.apkg");
    std::fs::copy(&staged, &evil).unwrap();
    let escape_link = staged_dir.join(format!("{OTHER_V4}.apkg"));
    std::os::unix::fs::symlink(&evil, &escape_link).unwrap();
    assert_denied(
        &call(
            &backend,
            "BackendImportExportService",
            "import_anki_package",
            &resident_import(escape_link.to_string_lossy().into_owned(), true),
        ),
        "escapes data_dir",
    );
    let raw_target = raw_dir.join(format!("{THIRD_V4}.apkg"));
    std::fs::copy(&staged, &raw_target).unwrap();
    let raw_link = staged_dir.join(format!("{THIRD_V4}.apkg"));
    std::os::unix::fs::symlink(&raw_target, &raw_link).unwrap();
    assert_denied(
        &call(
            &backend,
            "BackendImportExportService",
            "import_anki_package",
            &resident_import(raw_link.to_string_lossy().into_owned(), true),
        ),
        "import/staged",
    );
}

fn e_root(dir: &tempfile::TempDir) -> crate::api::AnkiBackend {
    std::fs::create_dir_all(dir.path().join("tmp")).unwrap();
    crate::api::prepare_runtime(dir.path().join("tmp").to_string_lossy().into_owned());
    crate::api::open_import_e_backend(init_bytes(), dir.path().to_string_lossy().into_owned())
        .expect("import-e backend")
}

fn e_collection_request(root: &Path, id: &str) -> anki_proto::collection::OpenCollectionRequest {
    let dir = root.join("import").join("e").join(id);
    std::fs::create_dir_all(dir.join("collection.media")).unwrap();
    anki_proto::collection::OpenCollectionRequest {
        collection_path: dir.join("collection.anki2").to_string_lossy().into_owned(),
        media_folder_path: dir.join("collection.media").to_string_lossy().into_owned(),
        media_db_path: dir
            .join("collection.media.db")
            .to_string_lossy()
            .into_owned(),
    }
}

#[test]
fn import_e_open_collection_accepts_only_its_directory() {
    let dir = tempfile::TempDir::new_in("/tmp").unwrap();
    let backend = e_root(&dir);
    let resident = col_paths(dir.path());
    assert_denied(
        &call(
            &backend,
            "BackendCollectionService",
            "open_collection",
            &open_request(&resident),
        ),
        "import/e",
    );
    let v5 = e_collection_request(dir.path(), BATCH_V5);
    assert_denied(
        &call(&backend, "BackendCollectionService", "open_collection", &v5),
        "uuid v4",
    );
    let relative = anki_proto::collection::OpenCollectionRequest {
        collection_path: format!("import/e/{BATCH_V4}/collection.anki2"),
        media_folder_path: format!("import/e/{BATCH_V4}/collection.media"),
        media_db_path: format!("import/e/{BATCH_V4}/collection.media.db"),
    };
    assert_denied(
        &call(
            &backend,
            "BackendCollectionService",
            "open_collection",
            &relative,
        ),
        "not absolute",
    );

    std::fs::write(dir.path().join("collection.anki2"), b"resident").unwrap();
    let linked = e_collection_request(dir.path(), OTHER_V4);
    std::fs::remove_file(
        dir.path()
            .join("import")
            .join("e")
            .join(OTHER_V4)
            .join("collection.anki2"),
    )
    .ok();
    std::os::unix::fs::symlink(
        dir.path().join("collection.anki2"),
        dir.path()
            .join("import")
            .join("e")
            .join(OTHER_V4)
            .join("collection.anki2"),
    )
    .unwrap();
    assert_denied(
        &call(
            &backend,
            "BackendCollectionService",
            "open_collection",
            &linked,
        ),
        "import/e",
    );

    let mut media_escapes = e_collection_request(dir.path(), BATCH_V4);
    media_escapes.media_folder_path = resident.media.to_string_lossy().into_owned();
    assert_denied(
        &call(
            &backend,
            "BackendCollectionService",
            "open_collection",
            &media_escapes,
        ),
        "collection.media",
    );

    let opened = call(
        &backend,
        "BackendCollectionService",
        "open_collection",
        &e_collection_request(dir.path(), BATCH_V4),
    );
    assert!(opened.success, "{}", message_of(&opened));
    assert!(!fsrs_enabled(&backend));
    assert!(!marker_path(
        &dir.path()
            .join("import")
            .join("e")
            .join(BATCH_V4)
            .join("collection.anki2")
    )
    .is_file());
    let second = call(
        &backend,
        "BackendCollectionService",
        "open_collection",
        &e_collection_request(dir.path(), OTHER_V4),
    );
    assert_denied(&second, "already open");

    for (service, method) in [
        ("BackendImportExportService", "import_csv"),
        ("BackendImportExportService", "import_json_file"),
        ("BackendImportExportService", "import_collection_package"),
        ("BackendImportExportService", "export_note_csv"),
        ("BackendNotesService", "update_notes"),
        ("BackendAnkidroidService", "get_column_names_from_query"),
    ] {
        let response = call(&backend, service, method, &anki_proto::generic::Empty {});
        assert_denied(&response, "not on allowlist");
    }
}

#[test]
fn import_e_import_accepts_only_raw_with_step2_options() {
    let dir = tempfile::TempDir::new_in("/tmp").unwrap();
    let backend = e_root(&dir);
    let opened = call(
        &backend,
        "BackendCollectionService",
        "open_collection",
        &e_collection_request(dir.path(), BATCH_V4),
    );
    assert!(opened.success, "{}", message_of(&opened));
    let raw_dir = dir.path().join("import").join("raw");
    let staged_dir = dir.path().join("import").join("staged");
    std::fs::create_dir_all(&raw_dir).unwrap();
    std::fs::create_dir_all(&staged_dir).unwrap();
    let raw = raw_dir.join(format!("{BATCH_V4}.apkg"));
    export_package(&backend, &raw);
    let imported = call(
        &backend,
        "BackendImportExportService",
        "import_anki_package",
        &e_import(raw.to_string_lossy().into_owned()),
    );
    assert!(imported.success, "{}", message_of(&imported));

    let mut newer = e_import(raw.to_string_lossy().into_owned());
    newer.options.as_mut().unwrap().update_notes =
        anki_proto::import_export::ImportAnkiPackageUpdateCondition::IfNewer as i32;
    assert_denied(
        &call(
            &backend,
            "BackendImportExportService",
            "import_anki_package",
            &newer,
        ),
        "update_notes must be NEVER",
    );
    let mut configs = e_import(raw.to_string_lossy().into_owned());
    configs.options.as_mut().unwrap().with_deck_configs = false;
    assert_denied(
        &call(
            &backend,
            "BackendImportExportService",
            "import_anki_package",
            &configs,
        ),
        "with_deck_configs must be true",
    );
    let staged = staged_dir.join(format!("{BATCH_V4}.apkg"));
    std::fs::copy(&raw, &staged).unwrap();
    assert_denied(
        &call(
            &backend,
            "BackendImportExportService",
            "import_anki_package",
            &e_import(staged.to_string_lossy().into_owned()),
        ),
        "import/raw",
    );
    let other = raw_dir.join(format!("{OTHER_V4}.apkg"));
    std::fs::copy(&raw, &other).unwrap();
    assert_denied(
        &call(
            &backend,
            "BackendImportExportService",
            "import_anki_package",
            &e_import(other.to_string_lossy().into_owned()),
        ),
        "does not match the open collection",
    );
}

#[test]
fn import_e_export_accepts_only_the_staged_path() {
    let dir = tempfile::TempDir::new_in("/tmp").unwrap();
    let backend = e_root(&dir);
    let opened = call(
        &backend,
        "BackendCollectionService",
        "open_collection",
        &e_collection_request(dir.path(), BATCH_V4),
    );
    assert!(opened.success, "{}", message_of(&opened));
    std::fs::create_dir_all(dir.path().join("import").join("staged")).unwrap();
    std::fs::create_dir_all(dir.path().join("import").join("raw")).unwrap();
    let staged = dir
        .path()
        .join("import")
        .join("staged")
        .join(format!("{BATCH_V4}.apkg"));
    let exported = call(
        &backend,
        "BackendImportExportService",
        "export_anki_package",
        &whole_collection_export(staged.to_string_lossy().into_owned(), false),
    );
    assert!(exported.success, "{}", message_of(&exported));
    assert!(staged.is_file());

    let raw = dir
        .path()
        .join("import")
        .join("raw")
        .join(format!("{BATCH_V4}.apkg"));
    assert_denied(
        &call(
            &backend,
            "BackendImportExportService",
            "export_anki_package",
            &whole_collection_export(raw.to_string_lossy().into_owned(), true),
        ),
        "import/staged",
    );
    let other = dir
        .path()
        .join("import")
        .join("staged")
        .join(format!("{OTHER_V4}.apkg"));
    assert_denied(
        &call(
            &backend,
            "BackendImportExportService",
            "export_anki_package",
            &whole_collection_export(other.to_string_lossy().into_owned(), true),
        ),
        "does not match the open collection",
    );
    let mut legacy = whole_collection_export(staged.to_string_lossy().into_owned(), true);
    legacy.options.as_mut().unwrap().legacy = true;
    assert_denied(
        &call(
            &backend,
            "BackendImportExportService",
            "export_anki_package",
            &legacy,
        ),
        "legacy must be false",
    );
    let mut bare = whole_collection_export(staged.to_string_lossy().into_owned(), true);
    bare.options = None;
    assert_denied(
        &call(
            &backend,
            "BackendImportExportService",
            "export_anki_package",
            &bare,
        ),
        "options must be set",
    );
    let mut deck_limit = whole_collection_export(staged.to_string_lossy().into_owned(), true);
    deck_limit.limit = Some(anki_proto::import_export::ExportLimit {
        limit: Some(anki_proto::import_export::export_limit::Limit::DeckId(1)),
    });
    assert_denied(
        &call(
            &backend,
            "BackendImportExportService",
            "export_anki_package",
            &deck_limit,
        ),
        "whole collection",
    );
}

#[test]
fn import_e_run_db_command_allows_only_the_statement_whitelist() {
    let dir = tempfile::TempDir::new_in("/tmp").unwrap();
    let backend = e_root(&dir);
    let opened = call(
        &backend,
        "BackendCollectionService",
        "open_collection",
        &e_collection_request(dir.path(), BATCH_V4),
    );
    assert!(opened.success, "{}", message_of(&opened));

    let begin = db_call(&backend, serde_json::json!({"kind": "begin"}));
    assert!(begin.success, "{}", message_of(&begin));
    let updated = db_call(
        &backend,
        serde_json::json!({
            "kind": "executemany",
            "sql": super::import_e::GUID_UPDATE_SQL,
            "args": [[BATCH_V4, 1]],
        }),
    );
    assert!(updated.success, "{}", message_of(&updated));
    for sql in [
        super::import_e::SELECT_NOTES_ID_GUID_SQL,
        super::import_e::SELECT_CARDLESS_NOTES_SQL,
        super::import_e::SELECT_NOTE_FACTS_SQL,
        super::import_e::SELECT_CARD_COUNTS_SQL,
    ] {
        let selected = db_call(
            &backend,
            serde_json::json!({
                "kind": "query",
                "sql": sql,
                "args": [],
                "first_row_only": false,
            }),
        );
        assert!(selected.success, "{sql}: {}", message_of(&selected));
    }
    assert_denied(
        &db_call(
            &backend,
            serde_json::json!({
                "kind": "query",
                "sql": "SELECT id FROM notes WHERE id NOT IN (SELECT nid FROM cards)",
                "args": [],
                "first_row_only": false,
            }),
        ),
        "whitelist",
    );
    let committed = db_call(&backend, serde_json::json!({"kind": "commit"}));
    assert!(committed.success, "{}", message_of(&committed));
    let rolled = db_call(&backend, serde_json::json!({"kind": "rollback"}));
    assert!(rolled.success, "{}", message_of(&rolled));

    assert_denied(
        &db_call(
            &backend,
            serde_json::json!({
                "kind": "executemany",
                "sql": "DELETE FROM notes WHERE id = ?",
                "args": [[1]],
            }),
        ),
        "whitelist",
    );
    assert_denied(
        &db_call(
            &backend,
            serde_json::json!({
                "kind": "executemany",
                "sql": "update notes set guid = ? where id = ?",
                "args": [[BATCH_V4, 1]],
            }),
        ),
        "whitelist",
    );
    assert_denied(
        &db_call(
            &backend,
            serde_json::json!({
                "kind": "query",
                "sql": super::import_e::GUID_UPDATE_SQL,
                "args": [],
                "first_row_only": true,
            }),
        ),
        "whitelist",
    );
    assert_denied(
        &db_call(
            &backend,
            serde_json::json!({
                "kind": "query",
                "sql": "SELECT id FROM notes",
                "args": [],
                "first_row_only": true,
            }),
        ),
        "whitelist",
    );
    assert_denied(
        &db_call(
            &backend,
            serde_json::json!({"kind": "begin", "sql": "select 1"}),
        ),
        "json fields",
    );
    assert_denied(
        &db_call(
            &backend,
            serde_json::json!({
                "kind": "executemany",
                "sql": super::import_e::GUID_UPDATE_SQL,
                "args": [[BATCH_V4]],
            }),
        ),
        "guid string",
    );

    let desktop_dir = tempfile::TempDir::new_in("/tmp").unwrap();
    let desktop = desktop_backend(desktop_dir.path());
    assert_denied(
        &db_call_on(&desktop, serde_json::json!({"kind": "begin"})),
        "not on allowlist",
    );
}

fn db_call(backend: &crate::api::AnkiBackend, value: serde_json::Value) -> ProtoResponse {
    db_call_on(backend, value)
}

fn db_call_on(backend: &crate::api::AnkiBackend, value: serde_json::Value) -> ProtoResponse {
    call(
        backend,
        "BackendAnkidroidService",
        "run_db_command",
        &anki_proto::generic::Json {
            json: serde_json::to_vec(&value).unwrap(),
        },
    )
}

#[test]
fn import_e_search_rejects_a_custom_order() {
    let dir = tempfile::TempDir::new_in("/tmp").unwrap();
    let backend = e_root(&dir);
    let opened = call(
        &backend,
        "BackendCollectionService",
        "open_collection",
        &e_collection_request(dir.path(), BATCH_V4),
    );
    assert!(opened.success, "{}", message_of(&opened));
    let listed = call(
        &backend,
        "BackendSearchService",
        "search_notes",
        &anki_proto::search::SearchRequest {
            search: String::new(),
            order: None,
        },
    );
    assert!(listed.success, "{}", message_of(&listed));
    let custom = call(
        &backend,
        "BackendSearchService",
        "search_cards",
        &anki_proto::search::SearchRequest {
            search: String::new(),
            order: Some(anki_proto::search::SortOrder {
                value: Some(anki_proto::search::sort_order::Value::Custom(
                    "id; drop table notes".into(),
                )),
            }),
        },
    );
    assert_denied(&custom, "custom sort order");
}

#[test]
fn import_e_name_only_calls_are_forwarded() {
    let dir = tempfile::TempDir::new_in("/tmp").unwrap();
    let backend = e_root(&dir);
    let opened = call(
        &backend,
        "BackendCollectionService",
        "open_collection",
        &e_collection_request(dir.path(), BATCH_V4),
    );
    assert!(opened.success, "{}", message_of(&opened));
    let missing_note = call(
        &backend,
        "BackendNotesService",
        "get_note",
        &anki_proto::notes::NoteId { nid: 1 },
    );
    assert!(
        !policy_denied(&missing_note),
        "{}",
        message_of(&missing_note)
    );
    let removed = call(
        &backend,
        "BackendNotesService",
        "remove_notes",
        &anki_proto::notes::RemoveNotesRequest {
            note_ids: vec![1],
            card_ids: Vec::new(),
        },
    );
    assert!(!policy_denied(&removed), "{}", message_of(&removed));
    let decks = call(
        &backend,
        "BackendDecksService",
        "remove_decks",
        &anki_proto::decks::DeckIds { dids: vec![] },
    );
    assert!(!policy_denied(&decks), "{}", message_of(&decks));
    let filtered = call(
        &backend,
        "BackendSchedulerService",
        "empty_filtered_deck",
        &anki_proto::decks::DeckId { did: 1 },
    );
    assert!(!policy_denied(&filtered), "{}", message_of(&filtered));
    let read_deck = call(
        &backend,
        "BackendDecksService",
        "get_deck",
        &anki_proto::decks::DeckId { did: 1 },
    );
    assert!(read_deck.success, "{}", message_of(&read_deck));
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
    let configs = call(
        &backend,
        "BackendDeckConfigService",
        "get_deck_configs_for_update",
        &anki_proto::decks::DeckId { did: 1 },
    );
    assert!(configs.success, "{}", message_of(&configs));
}

#[test]
fn import_e_update_deck_allows_one_field() {
    let dir = tempfile::TempDir::new_in("/tmp").unwrap();
    let backend = e_root(&dir);
    let opened = call(
        &backend,
        "BackendCollectionService",
        "open_collection",
        &e_collection_request(dir.path(), BATCH_V4),
    );
    assert!(opened.success, "{}", message_of(&opened));
    let original = deck_proto(&backend, 1);
    let mut described = original.clone();
    match described.kind.as_mut().unwrap() {
        anki_proto::decks::deck::Kind::Normal(normal) => {
            normal.description = "from the file".into();
        }
        other => panic!("default deck is not normal: {other:?}"),
    }
    dispatch_message(&backend, "BackendDecksService", "update_deck", &described)
        .expect("set description");
    let stored = deck_proto(&backend, 1);
    let mut cleared = stored.clone();
    match cleared.kind.as_mut().unwrap() {
        anki_proto::decks::deck::Kind::Normal(normal) => normal.description.clear(),
        other => panic!("default deck is not normal: {other:?}"),
    }
    let updated = call(&backend, "BackendDecksService", "update_deck", &cleared);
    assert!(updated.success, "{}", message_of(&updated));
    let after = deck_proto(&backend, 1);
    match after.kind.unwrap() {
        anki_proto::decks::deck::Kind::Normal(normal) => assert!(normal.description.is_empty()),
        other => panic!("default deck is not normal: {other:?}"),
    }

    let mut config_only = deck_proto(&backend, 1);
    match config_only.kind.as_mut().unwrap() {
        anki_proto::decks::deck::Kind::Normal(normal) => normal.config_id = 2,
        other => panic!("default deck is not normal: {other:?}"),
    }
    let config_updated = call(&backend, "BackendDecksService", "update_deck", &config_only);
    assert!(config_updated.success, "{}", message_of(&config_updated));

    let mut renamed = deck_proto(&backend, 1);
    renamed.name = "Renamed".into();
    assert_denied(
        &call(&backend, "BackendDecksService", "update_deck", &renamed),
        "clear the description or change only config_id",
    );
    let mut nonempty = deck_proto(&backend, 1);
    match nonempty.kind.as_mut().unwrap() {
        anki_proto::decks::deck::Kind::Normal(normal) => {
            normal.description = "still there".into();
        }
        other => panic!("default deck is not normal: {other:?}"),
    }
    assert_denied(
        &call(&backend, "BackendDecksService", "update_deck", &nonempty),
        "clear the description or change only config_id",
    );
    let mut markdown = deck_proto(&backend, 1);
    match markdown.kind.as_mut().unwrap() {
        anki_proto::decks::deck::Kind::Normal(normal) => {
            normal.markdown_description = !normal.markdown_description;
        }
        other => panic!("default deck is not normal: {other:?}"),
    }
    assert_denied(
        &call(&backend, "BackendDecksService", "update_deck", &markdown),
        "clear the description or change only config_id",
    );
    let mut limited = deck_proto(&backend, 1);
    match limited.kind.as_mut().unwrap() {
        anki_proto::decks::deck::Kind::Normal(normal) => normal.review_limit = Some(5),
        other => panic!("default deck is not normal: {other:?}"),
    }
    assert_denied(
        &call(&backend, "BackendDecksService", "update_deck", &limited),
        "clear the description or change only config_id",
    );
    dispatch_message(&backend, "BackendDecksService", "update_deck", &described)
        .expect("set description again");
    let stored = deck_proto(&backend, 1);
    let mut cleared_and_renamed = stored.clone();
    cleared_and_renamed.name = "Also renamed".into();
    match cleared_and_renamed.kind.as_mut().unwrap() {
        anki_proto::decks::deck::Kind::Normal(normal) => normal.description.clear(),
        other => panic!("default deck is not normal: {other:?}"),
    }
    assert_denied(
        &call(
            &backend,
            "BackendDecksService",
            "update_deck",
            &cleared_and_renamed,
        ),
        "other deck fields",
    );
    let mut both = stored.clone();
    match both.kind.as_mut().unwrap() {
        anki_proto::decks::deck::Kind::Normal(normal) => {
            normal.description.clear();
            normal.config_id = 3;
        }
        other => panic!("default deck is not normal: {other:?}"),
    }
    assert_denied(
        &call(&backend, "BackendDecksService", "update_deck", &both),
        "clear the description or change only config_id",
    );
    let unchanged = deck_proto(&backend, 1);
    assert_denied(
        &call(&backend, "BackendDecksService", "update_deck", &unchanged),
        "clear the description or change only config_id",
    );
}

fn deck_proto(backend: &crate::api::AnkiBackend, id: i64) -> anki_proto::decks::Deck {
    let bytes = dispatch_message(
        backend,
        "BackendDecksService",
        "get_deck",
        &anki_proto::decks::DeckId { did: id },
    )
    .expect("get deck");
    anki_proto::decks::Deck::decode(bytes.as_slice()).unwrap()
}

#[test]
fn import_e_close_collection_rejects_downgrade() {
    let dir = tempfile::TempDir::new_in("/tmp").unwrap();
    let backend = e_root(&dir);
    let opened = call(
        &backend,
        "BackendCollectionService",
        "open_collection",
        &e_collection_request(dir.path(), BATCH_V4),
    );
    assert!(opened.success, "{}", message_of(&opened));
    assert_denied(
        &call(
            &backend,
            "BackendCollectionService",
            "close_collection",
            &anki_proto::collection::CloseCollectionRequest {
                downgrade_to_schema11: true,
            },
        ),
        "downgrade_to_schema11",
    );
    let still_open = call(
        &backend,
        "BackendNotesService",
        "get_note",
        &anki_proto::notes::NoteId { nid: 1 },
    );
    assert!(!policy_denied(&still_open), "{}", message_of(&still_open));
    let closed = call(
        &backend,
        "BackendCollectionService",
        "close_collection",
        &anki_proto::collection::CloseCollectionRequest {
            downgrade_to_schema11: false,
        },
    );
    assert!(closed.success, "{}", message_of(&closed));
    assert_denied(
        &call(
            &backend,
            "BackendNotesService",
            "get_note",
            &anki_proto::notes::NoteId { nid: 1 },
        ),
        "collection is not open",
    );
    let reopened = call(
        &backend,
        "BackendCollectionService",
        "open_collection",
        &e_collection_request(dir.path(), BATCH_V4),
    );
    assert!(reopened.success, "{}", message_of(&reopened));
}

#[test]
fn import_e_update_deck_configs_accepts_only_a_new_config() {
    let dir = tempfile::TempDir::new_in("/tmp").unwrap();
    let backend = e_root(&dir);
    let opened = call(
        &backend,
        "BackendCollectionService",
        "open_collection",
        &e_collection_request(dir.path(), BATCH_V4),
    );
    assert!(opened.success, "{}", message_of(&opened));
    let deck_id = add_named_deck(&backend, "Source");
    let allowed = new_config_request(&backend, deck_id);
    let updated = call(
        &backend,
        "BackendDeckConfigService",
        "update_deck_configs",
        &allowed,
    );
    assert!(updated.success, "{}", message_of(&updated));

    let mut default_deck = allowed.clone();
    default_deck.target_deck_id = 1;
    assert_denied(
        &call(
            &backend,
            "BackendDeckConfigService",
            "update_deck_configs",
            &default_deck,
        ),
        "target_deck_id must not be 1",
    );
    let mut existing = allowed.clone();
    existing.configs[0].id = 1;
    assert_denied(
        &call(
            &backend,
            "BackendDeckConfigService",
            "update_deck_configs",
            &existing,
        ),
        "one new config",
    );
    let mut two = allowed.clone();
    two.configs.push(allowed.configs[0].clone());
    assert_denied(
        &call(
            &backend,
            "BackendDeckConfigService",
            "update_deck_configs",
            &two,
        ),
        "one new config",
    );
    let mut removed = allowed.clone();
    removed.removed_config_ids = vec![1];
    assert_denied(
        &call(
            &backend,
            "BackendDeckConfigService",
            "update_deck_configs",
            &removed,
        ),
        "removed_config_ids must be empty",
    );
    let mut children = allowed.clone();
    children.mode = anki_proto::deck_config::UpdateDeckConfigsMode::ApplyToChildren as i32;
    assert_denied(
        &call(
            &backend,
            "BackendDeckConfigService",
            "update_deck_configs",
            &children,
        ),
        "mode must be NORMAL",
    );
    let mut reschedule = allowed.clone();
    reschedule.fsrs_reschedule = true;
    assert_denied(
        &call(
            &backend,
            "BackendDeckConfigService",
            "update_deck_configs",
            &reschedule,
        ),
        "fsrs_reschedule must be false",
    );
}

fn add_named_deck(backend: &crate::api::AnkiBackend, name: &str) -> i64 {
    let bytes = dispatch_message(
        backend,
        "BackendDecksService",
        "new_deck",
        &anki_proto::generic::Empty {},
    )
    .expect("new deck");
    let mut deck = anki_proto::decks::Deck::decode(bytes.as_slice()).unwrap();
    deck.name = name.into();
    let saved =
        dispatch_message(backend, "BackendDecksService", "add_deck", &deck).expect("add deck");
    anki_proto::collection::OpChangesWithId::decode(saved.as_slice())
        .unwrap()
        .id
}

fn new_config_request(
    backend: &crate::api::AnkiBackend,
    target_deck_id: i64,
) -> anki_proto::deck_config::UpdateDeckConfigsRequest {
    let bytes = dispatch_message(
        backend,
        "BackendDeckConfigService",
        "get_deck_configs_for_update",
        &anki_proto::decks::DeckId { did: 1 },
    )
    .expect("deck configs");
    let update = anki_proto::deck_config::DeckConfigsForUpdate::decode(bytes.as_slice()).unwrap();
    let mut config = update
        .defaults
        .or_else(|| update.all_config.first().and_then(|row| row.config.clone()))
        .expect("a deck config to copy");
    config.id = 0;
    config.name = format!("Restored {target_deck_id}");
    anki_proto::deck_config::UpdateDeckConfigsRequest {
        target_deck_id,
        configs: vec![config],
        removed_config_ids: Vec::new(),
        mode: anki_proto::deck_config::UpdateDeckConfigsMode::Normal as i32,
        card_state_customizer: String::new(),
        limits: None,
        new_cards_ignore_review_limit: false,
        fsrs: false,
        apply_all_parent_limits: false,
        fsrs_reschedule: false,
        fsrs_health_check: false,
    }
}

fn db_call_raw(backend: &crate::api::AnkiBackend, json: &str) -> ProtoResponse {
    call(
        backend,
        "BackendAnkidroidService",
        "run_db_command",
        &anki_proto::generic::Json {
            json: json.as_bytes().to_vec(),
        },
    )
}

#[test]
fn import_e_run_db_command_rejects_duplicate_keys() {
    let dir = tempfile::TempDir::new_in("/tmp").unwrap();
    let backend = e_root(&dir);
    let opened = call(
        &backend,
        "BackendCollectionService",
        "open_collection",
        &e_collection_request(dir.path(), BATCH_V4),
    );
    assert!(opened.success, "{}", message_of(&opened));
    let allowed = super::import_e::GUID_UPDATE_SQL;
    let delete_then_allowed = format!(
        r#"{{"kind":"executemany","sql":"DELETE FROM notes","sql":"{allowed}","args":[["{BATCH_V4}",1]]}}"#
    );
    let allowed_then_delete = format!(
        r#"{{"kind":"executemany","sql":"{allowed}","sql":"DELETE FROM notes","args":[["{BATCH_V4}",1]]}}"#
    );
    assert_denied(
        &db_call_raw(&backend, &delete_then_allowed),
        "duplicate key",
    );
    assert_denied(
        &db_call_raw(&backend, &allowed_then_delete),
        "duplicate key",
    );
    assert_denied(
        &db_call_raw(&backend, r#"{"kind":"begin","kind":"rollback"}"#),
        "duplicate key",
    );
    let duplicate_in_args =
        format!(r#"{{"kind":"executemany","sql":"{allowed}","args":[[{{"a":1,"a":2}},1]]}}"#);
    assert_denied(&db_call_raw(&backend, &duplicate_in_args), "duplicate key");
}

#[test]
fn import_e_run_db_command_rejects_excessive_nesting() {
    let dir = tempfile::TempDir::new_in("/tmp").unwrap();
    let backend = e_root(&dir);
    let opened = call(
        &backend,
        "BackendCollectionService",
        "open_collection",
        &e_collection_request(dir.path(), BATCH_V4),
    );
    assert!(opened.success, "{}", message_of(&opened));
    let json = format!("{}0{}", "[".repeat(100_000), "]".repeat(100_000));
    assert_denied(&db_call_raw(&backend, &json), "recursion limit");
}

#[test]
fn import_e_run_db_command_rejects_unescaped_duplicate_keys() {
    let dir = tempfile::TempDir::new_in("/tmp").unwrap();
    let backend = e_root(&dir);
    let opened = call(
        &backend,
        "BackendCollectionService",
        "open_collection",
        &e_collection_request(dir.path(), BATCH_V4),
    );
    assert!(opened.success, "{}", message_of(&opened));
    let allowed = super::import_e::GUID_UPDATE_SQL;
    // `\u0071` is `q`, so the second key is `sql` after unescape.
    let json = format!(
        r#"{{"kind":"executemany","sql":"DELETE FROM notes","s\u0071l":"{allowed}","args":[["{BATCH_V4}",1]]}}"#
    );
    assert_denied(&db_call_raw(&backend, &json), "duplicate key");
}

fn with_unknown_field(bytes: &[u8]) -> Vec<u8> {
    let mut out = bytes.to_vec();
    let mut tag = (20_000u64 << 3) | 2;
    while tag > 0x7f {
        out.push(((tag as u8) & 0x7f) | 0x80);
        tag >>= 7;
    }
    out.push(tag as u8);
    let payload = b"hatto-unknown-field";
    out.push(u8::try_from(payload.len()).unwrap());
    out.extend_from_slice(payload);
    out
}

fn assert_unknown_field_dropped(forwarded: &[u8], clean: &[u8], extra: &[u8]) {
    assert_eq!(forwarded, clean);
    assert_ne!(forwarded, extra);
    assert!(!forwarded
        .windows(b"hatto-unknown-field".len())
        .any(|window| window == b"hatto-unknown-field"));
}

#[test]
fn import_e_search_drops_unknown_protobuf_fields() {
    let request = anki_proto::search::SearchRequest {
        search: String::new(),
        order: None,
    };
    let clean = request.encode_to_vec();
    let extra = with_unknown_field(&clean);
    let forwarded = super::import_e::validate_search(&extra).expect("search");
    assert_unknown_field_dropped(&forwarded, &clean, &extra);
}

#[test]
fn import_e_update_deck_drops_unknown_protobuf_fields() {
    let dir = tempfile::TempDir::new_in("/tmp").unwrap();
    let backend = e_root(&dir);
    let opened = call(
        &backend,
        "BackendCollectionService",
        "open_collection",
        &e_collection_request(dir.path(), BATCH_V4),
    );
    assert!(opened.success, "{}", message_of(&opened));
    let mut described = deck_proto(&backend, 1);
    match described.kind.as_mut().unwrap() {
        anki_proto::decks::deck::Kind::Normal(normal) => {
            normal.description = "from the file".into();
        }
        other => panic!("default deck is not normal: {other:?}"),
    }
    dispatch_message(&backend, "BackendDecksService", "update_deck", &described)
        .expect("set description");
    let mut cleared = deck_proto(&backend, 1);
    match cleared.kind.as_mut().unwrap() {
        anki_proto::decks::deck::Kind::Normal(normal) => normal.description.clear(),
        other => panic!("default deck is not normal: {other:?}"),
    }
    let clean = cleared.encode_to_vec();
    let extra = with_unknown_field(&clean);
    let forwarded = super::import_e::validate_update_deck(&backend, &extra).expect("update deck");
    assert_unknown_field_dropped(&forwarded, &clean, &extra);
}

#[test]
fn import_e_update_deck_configs_drops_unknown_protobuf_fields() {
    let request = anki_proto::deck_config::UpdateDeckConfigsRequest {
        target_deck_id: 2,
        configs: vec![anki_proto::deck_config::DeckConfig::default()],
        removed_config_ids: Vec::new(),
        mode: anki_proto::deck_config::UpdateDeckConfigsMode::Normal as i32,
        card_state_customizer: String::new(),
        limits: None,
        new_cards_ignore_review_limit: false,
        fsrs: false,
        apply_all_parent_limits: false,
        fsrs_reschedule: false,
        fsrs_health_check: false,
    };
    let clean = request.encode_to_vec();
    let extra = with_unknown_field(&clean);
    let forwarded = super::import_e::validate_update_deck_configs(&extra).expect("configs");
    assert_unknown_field_dropped(&forwarded, &clean, &extra);
}

#[test]
fn resident_import_accepts_a_symlinked_ancestor() {
    // macOS spells the temp dir as /var, which is a symlink to /private/var.
    // The desktop profile stores the canonical data_dir, and the app passes
    // import/staged with the symlink spelling.
    let dir = tempfile::TempDir::new_in("/tmp").unwrap();
    let real = dir.path().join("real");
    std::fs::create_dir_all(&real).unwrap();
    let link = dir.path().join("link");
    std::os::unix::fs::symlink(&real, &link).unwrap();
    let root = link.join("collection");
    let paths = col_paths(&root);
    let backend = open_desktop_collection(&paths);
    let _card = add_basic_card(&backend);
    let staged = root
        .join("import")
        .join("staged")
        .join(format!("{BATCH_V4}.apkg"));
    std::fs::create_dir_all(staged.parent().unwrap()).unwrap();
    export_package(&backend, &staged);
    let spelled = staged.to_string_lossy().into_owned();
    assert_ne!(
        spelled.as_str(),
        staged.canonicalize().unwrap().to_string_lossy().as_ref()
    );
    let imported = call(
        &backend,
        "BackendImportExportService",
        "import_anki_package",
        &resident_import(spelled, true),
    );
    assert!(imported.success, "{}", message_of(&imported));
}

#[test]
fn import_e_accepts_a_symlinked_ancestor() {
    // Same /var -> /private/var shape for E open, raw import, and staged export.
    let dir = tempfile::TempDir::new_in("/tmp").unwrap();
    let real = dir.path().join("real");
    std::fs::create_dir_all(&real).unwrap();
    let link = dir.path().join("link");
    std::os::unix::fs::symlink(&real, &link).unwrap();
    let root = link.join("collection");
    std::fs::create_dir_all(root.join("tmp")).unwrap();
    crate::api::prepare_runtime(root.join("tmp").to_string_lossy().into_owned());
    assert_ne!(
        root.to_string_lossy().as_ref(),
        root.canonicalize().unwrap().to_string_lossy().as_ref()
    );
    let backend =
        crate::api::open_import_e_backend(init_bytes(), root.to_string_lossy().into_owned())
            .expect("import-e backend");
    let opened = call(
        &backend,
        "BackendCollectionService",
        "open_collection",
        &e_collection_request(&root, BATCH_V4),
    );
    assert!(opened.success, "{}", message_of(&opened));

    let raw = root
        .join("import")
        .join("raw")
        .join(format!("{BATCH_V4}.apkg"));
    let staged = root
        .join("import")
        .join("staged")
        .join(format!("{BATCH_V4}.apkg"));
    std::fs::create_dir_all(raw.parent().unwrap()).unwrap();
    std::fs::create_dir_all(staged.parent().unwrap()).unwrap();
    export_package(&backend, &raw);
    let imported = call(
        &backend,
        "BackendImportExportService",
        "import_anki_package",
        &e_import(raw.to_string_lossy().into_owned()),
    );
    assert!(imported.success, "{}", message_of(&imported));
    let exported = call(
        &backend,
        "BackendImportExportService",
        "export_anki_package",
        &whole_collection_export(staged.to_string_lossy().into_owned(), false),
    );
    assert!(exported.success, "{}", message_of(&exported));
    assert!(staged.is_file());
}
