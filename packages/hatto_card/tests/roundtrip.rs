// SPDX-FileCopyrightText: 2026 Hatto Social contributors
//
// SPDX-License-Identifier: AGPL-3.0-or-later

//! Export with `hatto-card`, then import the apkg in this test only.

use std::fs;
use std::path::Path;
use std::process::Command;

use anki_proto::generic;
use prost::Message;
use rslib_bridge::api::{
    command, open_backend, prepare_runtime, service_method_index, AnkiBackend,
};
use rslib_bridge::export_contract::anki_package_import_options;

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

fn import_apkg(apkg: &Path) -> Imported {
    let root = tempfile::tempdir().unwrap();
    let media = root.path().join("media");
    fs::create_dir_all(root.path().join("tmp")).unwrap();
    prepare_runtime(root.path().join("tmp").to_string_lossy().into_owned());
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
