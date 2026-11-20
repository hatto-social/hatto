// SPDX-FileCopyrightText: 2026 Hatto Social contributors
//
// SPDX-License-Identifier: AGPL-3.0-or-later

//! `hatto-card new`, then validate, export, and verify, with a media file.

use std::fs;
use std::path::Path;
use std::process::Command;

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
fn new_validate_export_verify_with_media() {
    let root = tempfile::tempdir().unwrap();
    fs::create_dir(root.path().join("media")).unwrap();
    fs::write(root.path().join("media").join("dot.png"), tiny_png()).unwrap();
    let deck = root.path().join("deck.json");
    let apkg = root.path().join("out.apkg");

    let (code, stdout, stderr) = run(&[
        "--json",
        "new",
        "--output",
        deck.to_str().unwrap(),
    ]);
    assert_eq!(code, 0, "{stdout}\n{stderr}");
    let created: serde_json::Value = serde_json::from_str(&stdout).unwrap();
    assert_eq!(created["ok"], true);

    let (code, stdout, stderr) = run(&["--json", "validate", "--deck", deck.to_str().unwrap()]);
    assert_eq!(code, 0, "{stdout}\n{stderr}");
    let validated: serde_json::Value = serde_json::from_str(&stdout).unwrap();
    assert_eq!(validated["ok"], true);
    assert_eq!(validated["notes"].as_array().unwrap().len(), 3);

    let (code, stdout, stderr) = run(&[
        "--json",
        "export",
        "--deck",
        deck.to_str().unwrap(),
        "--output",
        apkg.to_str().unwrap(),
    ]);
    assert_eq!(code, 0, "{stdout}\n{stderr}");
    assert!(apkg.is_file(), "{}", apkg.display());

    let (code, stdout, stderr) = run(&[
        "--json",
        "verify",
        "--deck",
        deck.to_str().unwrap(),
        "--apkg",
        apkg.to_str().unwrap(),
    ]);
    assert_eq!(code, 0, "{stdout}\n{stderr}");
    let verified: serde_json::Value = serde_json::from_str(&stdout).unwrap();
    assert_eq!(verified["ok"], true);
    assert_eq!(verified["notes"], 3);
    assert_eq!(verified["revlog"], 0);
    assert!(verified["cards_new"].as_u64().unwrap() >= 3);
    assert_eq!(verified["deck"], "Example");
    assert_eq!(verified["media"], serde_json::json!(["dot.png"]));

    // The collection files stay in a temp dir the process deletes. The apkg
    // is the only file the command was asked to write.
    assert!(!root.path().join("collection.anki2").exists());
    let _ = Path::new(root.path());
}

fn tiny_png() -> Vec<u8> {
    // 1x1 red PNG. Built here so the test does not depend on another file.
    const PNG: &[u8] = &[
        0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00, 0x00, 0x00, 0x0d, 0x49, 0x48, 0x44,
        0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x08, 0x02, 0x00, 0x00, 0x00, 0x90,
        0x77, 0x53, 0xde, 0x00, 0x00, 0x00, 0x0c, 0x49, 0x44, 0x41, 0x54, 0x08, 0xd7, 0x63, 0xf8,
        0xcf, 0xc0, 0x00, 0x00, 0x00, 0x03, 0x00, 0x01, 0x00, 0x05, 0xfe, 0x02, 0xfe, 0x00, 0x00,
        0x00, 0x00, 0x49, 0x45, 0x4e, 0x44, 0xae, 0x42, 0x60, 0x82,
    ];
    PNG.to_vec()
}
