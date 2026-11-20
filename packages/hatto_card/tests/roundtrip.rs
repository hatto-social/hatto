// SPDX-FileCopyrightText: 2026 Hatto Social contributors
//
// SPDX-License-Identifier: AGPL-3.0-or-later

//! Export with `hatto-card`, then import the apkg in this test only.

use std::fs;
use std::path::Path;
use std::process::Command;
use std::sync::{Mutex, MutexGuard};

use anki_proto::generic;
use hatto_card_contract::{imported_note_guid, local_note_guid, parse_uuid, NoteGuid};
use prost::Message;
use rslib_bridge::api::{
    command, open_backend, prepare_runtime, service_method_index, AnkiBackend,
};
use rslib_bridge::export_contract::anki_package_import_options;

/// `import_apkg` calls `prepare_runtime`, which sets TMPDIR/TMP/TEMP for the
/// whole process, and `run` spawns children that inherit them. Two tests on two
/// threads would point each other's temp files at a directory the other one is
/// about to delete. Hold this for the whole test body so tests never overlap.
fn serial() -> MutexGuard<'static, ()> {
    static LOCK: Mutex<()> = Mutex::new(());
    LOCK.lock().unwrap_or_else(|err| err.into_inner())
}

fn bin() -> Command {
    Command::new(env!("CARGO_BIN_EXE_hatto-card"))
}

fn run(args: &[&str]) -> (i32, String, String) {
    let output = bin().args(args).output().expect("run hatto-card");
    let code = output.status.code().unwrap_or(1);
    let stdout = String::from_utf8(output.stdout).unwrap();
    let stderr = String::from_utf8(output.stderr).unwrap();
    (code, stdout, stderr)
}

#[test]
fn export_then_import_matches_guids_fields_and_media() {
    let _serial = serial();
    let root = tempfile::tempdir().unwrap();
    fs::create_dir(root.path().join("media")).unwrap();
    let png = tiny_png();
    fs::write(root.path().join("media").join("dot.png"), &png).unwrap();
    let deck = root.path().join("deck.json");
    let apkg = root.path().join("out.apkg");

    let (code, stdout, stderr) = run(&["--json", "new", "--output", deck.to_str().unwrap()]);
    assert_eq!(code, 0, "{stdout}\n{stderr}");

    let (code, stdout, stderr) = run(&[
        "--json",
        "export",
        "--deck",
        deck.to_str().unwrap(),
        "--output",
        apkg.to_str().unwrap(),
    ]);
    assert_eq!(code, 0, "{stdout}\n{stderr}");
    let exported: serde_json::Value = serde_json::from_str(&stdout).unwrap();
    assert_eq!(exported["ok"], true);
    let expected: Vec<(String, Vec<String>)> = exported["notes"]
        .as_array()
        .unwrap()
        .iter()
        .zip(deck_fields(&deck))
        .map(|(note, fields)| (note["guid"].as_str().unwrap().to_string(), fields))
        .collect();
    assert_eq!(expected.len(), 3);

    let imported = import_apkg(&apkg);
    assert_eq!(imported.notes.len(), expected.len());
    for (guid, fields) in &expected {
        let found = imported
            .notes
            .iter()
            .find(|note| &note.guid == guid)
            .unwrap_or_else(|| panic!("imported collection has no guid {guid}"));
        assert_eq!(&found.fields, fields, "{guid}");
    }
    assert_eq!(imported.media, png);
    assert!(!root.path().join("collection.anki2").exists());
}

#[test]
fn add_note_then_export_imports_the_added_notes() {
    let _serial = serial();
    let root = tempfile::tempdir().unwrap();
    fs::create_dir(root.path().join("media")).unwrap();
    let png = tiny_png();
    fs::write(root.path().join("media").join("dot.png"), &png).unwrap();
    let deck = root.path().join("deck.json");
    let apkg = root.path().join("out.apkg");
    let deck_arg = deck.to_str().unwrap();

    let (code, stdout, stderr) = run(&["--json", "new", "--output", deck_arg]);
    assert_eq!(code, 0, "{stdout}\n{stderr}");

    let op_id = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee";
    let (code, stdout, stderr) = run(&[
        "--json",
        "add-note",
        "--deck",
        deck_arg,
        "--notetype",
        "Basic",
        "--field",
        "added front",
        "--field",
        "added back",
        "--tag",
        "added",
        "--op-id",
        op_id,
        "--k",
        "1",
    ]);
    assert_eq!(code, 0, "{stdout}\n{stderr}");
    let added: serde_json::Value = serde_json::from_str(&stdout).unwrap();
    assert_eq!(added["ok"], true);
    assert_eq!(added["k"], 1);
    let local = NoteGuid::from_uuid(local_note_guid(parse_uuid(op_id).unwrap(), 1)).into_string();
    assert_eq!(added["notes"][3]["guid"], local);

    let job_id = "11111111-2222-4333-8444-555555555555";
    let source = "  roundtrip  ";
    let (code, stdout, stderr) = run(&[
        "--json",
        "add-note",
        "--deck",
        deck_arg,
        "--notetype",
        "Basic",
        "--field",
        "imported front",
        "--field",
        "imported back",
        "--job-id",
        job_id,
        "--source-guid",
        source,
    ]);
    assert_eq!(code, 0, "{stdout}\n{stderr}");
    let added: serde_json::Value = serde_json::from_str(&stdout).unwrap();
    let imported_guid =
        NoteGuid::from_uuid(imported_note_guid(parse_uuid(job_id).unwrap(), source).unwrap())
            .into_string();
    assert_eq!(added["notes"][4]["guid"], imported_guid);
    assert_eq!(added["source_guid"], source);

    let (code, stdout, stderr) = run(&[
        "--json",
        "add-note",
        "--deck",
        deck_arg,
        "--notetype",
        "Basic",
        "--field",
        "nope",
        "--field",
        "nope",
        "--op-id",
        op_id,
        "--k",
        "1",
        "--job-id",
        job_id,
        "--source-guid",
        source,
    ]);
    assert_eq!(code, 2, "{stdout}\n{stderr}");
    let rejected: serde_json::Value = serde_json::from_str(&stdout).unwrap();
    assert_eq!(rejected["ok"], false);

    let (code, stdout, stderr) = run(&[
        "--json",
        "add-note",
        "--deck",
        deck_arg,
        "--notetype",
        "Basic",
        "--field",
        "dup",
        "--field",
        "dup",
        "--op-id",
        op_id,
        "--k",
        "1",
    ]);
    assert_eq!(code, 1, "{stdout}\n{stderr}");
    let duplicate: serde_json::Value = serde_json::from_str(&stdout).unwrap();
    assert_eq!(duplicate["ok"], false);
    assert!(duplicate["errors"]
        .as_array()
        .unwrap()
        .iter()
        .any(|error| error["code"] == "NOTE_GUID_DUPLICATE"));
    let on_disk: serde_json::Value =
        serde_json::from_str(&fs::read_to_string(&deck).unwrap()).unwrap();
    assert_eq!(on_disk["notes"].as_array().unwrap().len(), 5);

    let (code, stdout, stderr) = run(&[
        "--json",
        "add-note",
        "--deck",
        deck_arg,
        "--notetype",
        "Basic",
    ]);
    assert_eq!(code, 2, "{stdout}\n{stderr}");
    let (code, stdout, stderr) = run(&[
        "--json",
        "add-note",
        "--deck",
        deck_arg,
        "--notetype",
        "Basic",
        "--field",
        "a",
        "--field",
        "b",
        "--k",
        "-1",
    ]);
    assert_eq!(code, 2, "{stdout}\n{stderr}");
    assert!(stdout.contains("not a u32") || stderr.contains("not a u32"));

    let (code, stdout, stderr) = run(&[
        "--json",
        "export",
        "--deck",
        deck_arg,
        "--output",
        apkg.to_str().unwrap(),
    ]);
    assert_eq!(code, 0, "{stdout}\n{stderr}");
    let exported: serde_json::Value = serde_json::from_str(&stdout).unwrap();
    let expected: Vec<(String, Vec<String>)> = exported["notes"]
        .as_array()
        .unwrap()
        .iter()
        .zip(deck_fields(&deck))
        .map(|(note, fields)| (note["guid"].as_str().unwrap().to_string(), fields))
        .collect();
    assert_eq!(expected.len(), 5);
    assert!(expected.iter().any(|(guid, _)| guid == &local));
    assert!(expected.iter().any(|(guid, _)| guid == &imported_guid));

    let imported = import_apkg(&apkg);
    assert_eq!(imported.notes.len(), expected.len());
    for (guid, fields) in &expected {
        let found = imported
            .notes
            .iter()
            .find(|note| &note.guid == guid)
            .unwrap_or_else(|| panic!("imported collection has no guid {guid}"));
        assert_eq!(&found.fields, fields, "{guid}");
    }
    let local_fields = imported
        .notes
        .iter()
        .find(|note| note.guid == local)
        .unwrap();
    assert_eq!(local_fields.fields, ["added front", "added back"]);
    assert_eq!(imported.media, png);
    assert!(!root.path().join("collection.anki2").exists());
}

fn deck_fields(path: &Path) -> Vec<Vec<String>> {
    let value: serde_json::Value =
        serde_json::from_str(&fs::read_to_string(path).unwrap()).unwrap();
    value["notes"]
        .as_array()
        .unwrap()
        .iter()
        .map(|note| {
            note["fields"]
                .as_array()
                .unwrap()
                .iter()
                .map(|field| field.as_str().unwrap().to_string())
                .collect()
        })
        .collect()
}

struct Imported {
    notes: Vec<ImportedNote>,
    media: Vec<u8>,
}

struct ImportedNote {
    guid: String,
    fields: Vec<String>,
}

/// `prepare_runtime` points the process temp dir at this collection. Put the
/// previous values back before `root` is deleted, or the next test creates
/// its directory inside a folder that is already gone.
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
            // SAFETY: every test holds `serial()` for its whole body, so no
            // other thread reads or writes the environment. This value is
            // dropped before the temp dir that `prepare_runtime` pointed at.
            match value {
                Some(value) => unsafe { std::env::set_var(key, value) },
                None => unsafe { std::env::remove_var(key) },
            }
        }
    }
}

fn import_apkg(apkg: &Path) -> Imported {
    let root = tempfile::tempdir().unwrap();
    let media = root.path().join("media");
    fs::create_dir_all(root.path().join("tmp")).unwrap();
    let _tmp_env = TmpEnv::set(&root.path().join("tmp"));
    let init = anki_proto::backend::BackendInit {
        preferred_langs: vec!["en".into()],
        locale_folder_path: String::new(),
        server: false,
    };
    let backend = open_backend(init.encode_to_vec()).unwrap();
    call_raw(
        &backend,
        "BackendCollectionService",
        "open_collection",
        &anki_proto::collection::OpenCollectionRequest {
            collection_path: root
                .path()
                .join("collection.anki2")
                .to_string_lossy()
                .into_owned(),
            media_folder_path: media.to_string_lossy().into_owned(),
            media_db_path: root.path().join("media.db").to_string_lossy().into_owned(),
        },
    );
    call_raw(
        &backend,
        "BackendImportExportService",
        "import_anki_package",
        &anki_proto::import_export::ImportAnkiPackageRequest {
            package_path: apkg.to_string_lossy().into_owned(),
            options: Some(anki_package_import_options()),
        },
    );
    let rows = query(&backend, "select id from notes order by id");
    let mut notes = Vec::new();
    for row in rows.as_array().unwrap() {
        let id = row[0].as_i64().unwrap();
        let note: anki_proto::notes::Note = call(
            &backend,
            "BackendNotesService",
            "get_note",
            &anki_proto::notes::NoteId { nid: id },
        );
        notes.push(ImportedNote {
            guid: note.guid,
            fields: note.fields,
        });
    }
    let stored = fs::read(media.join("dot.png")).expect("imported dot.png");
    call_raw(
        &backend,
        "BackendCollectionService",
        "close_collection",
        &anki_proto::collection::CloseCollectionRequest {
            downgrade_to_schema11: false,
        },
    );
    Imported {
        notes,
        media: stored,
    }
}

fn query(backend: &AnkiBackend, sql: &str) -> serde_json::Value {
    let request = serde_json::json!({
        "kind": "query",
        "sql": sql,
        "args": [],
        "first_row_only": false,
    });
    let response: generic::Json = call(
        backend,
        "BackendAnkidroidService",
        "run_db_command",
        &generic::Json {
            json: serde_json::to_vec(&request).unwrap(),
        },
    );
    serde_json::from_slice(&response.json).unwrap()
}

fn call<M: Message + Default>(
    backend: &AnkiBackend,
    service: &str,
    method: &str,
    input: &impl Message,
) -> M {
    let bytes = call_raw(backend, service, method, input);
    M::decode(bytes.as_slice()).unwrap()
}

fn call_raw(backend: &AnkiBackend, service: &str, method: &str, input: &impl Message) -> Vec<u8> {
    let index = service_method_index(service.to_string(), method.to_string()).unwrap();
    let response = command(backend, index.service, index.method, input.encode_to_vec());
    assert!(response.success, "{service}.{method}");
    response.payload
}

fn tiny_png() -> Vec<u8> {
    const PNG: &[u8] = &[
        0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00, 0x00, 0x00, 0x0d, 0x49, 0x48, 0x44,
        0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x08, 0x02, 0x00, 0x00, 0x00, 0x90,
        0x77, 0x53, 0xde, 0x00, 0x00, 0x00, 0x0c, 0x49, 0x44, 0x41, 0x54, 0x08, 0xd7, 0x63, 0xf8,
        0xcf, 0xc0, 0x00, 0x00, 0x00, 0x03, 0x00, 0x01, 0x00, 0x05, 0xfe, 0x02, 0xfe, 0x00, 0x00,
        0x00, 0x00, 0x49, 0x45, 0x4e, 0x44, 0xae, 0x42, 0x60, 0x82,
    ];
    PNG.to_vec()
}
