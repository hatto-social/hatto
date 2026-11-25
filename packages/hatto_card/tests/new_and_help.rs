// SPDX-FileCopyrightText: 2026 Hatto Social contributors
//
// SPDX-License-Identifier: AGPL-3.0-or-later

//! `hatto-card new` mints fresh ids, help exits 0, and a fresh deck validates.

use std::fs;
use std::path::Path;
use std::process::Command;

use hatto_card_contract::{is_guid_format, parse_uuid};

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

fn assert_uuid_v4(text: &str) {
    assert!(is_guid_format(text), "{text}");
    assert_eq!(parse_uuid(text).unwrap().get_version_num(), 4, "{text}");
}

#[test]
fn help_exits_zero_for_the_top_level_and_each_command() {
    let cases: &[(&[&str], &[&str])] = &[
        (&["--help"], &["new", "validate", "export", "add-note"]),
        (&["-h"], &["hatto-card"]),
        (&["help"], &["--json"]),
        (&["new", "--help"], &["--deck-name", "--output"]),
        (&["new", "-h"], &["--deck-name"]),
        (&["--help", "new"], &["--deck-name"]),
        (&["help", "new"], &["job_id"]),
        (&["validate", "--help"], &["--deck"]),
        (&["validate", "-h"], &["validate"]),
        (&["export", "--help"], &["--output", "--deck"]),
        (&["export", "-h"], &["export"]),
        (
            &["add-note", "--help"],
            &["--field", "--op-id", "--source-guid"],
        ),
        (&["add-note", "-h"], &["--job-id", "--k"]),
        (&["--json", "--help"], &["hatto-card"]),
        (&["new", "--help", "--output"], &["--deck-name"]),
    ];
    for (args, needles) in cases {
        let (code, stdout, stderr) = run(args);
        assert_eq!(code, 0, "args {args:?}\n{stdout}\n{stderr}");
        assert!(stderr.is_empty(), "args {args:?}\n{stderr}");
        for needle in *needles {
            assert!(
                stdout.contains(needle),
                "args {args:?} missing {needle} in:\n{stdout}"
            );
        }
    }

    let (code, stdout, stderr) = run(&["--help"]);
    assert_eq!(code, 0, "{stdout}\n{stderr}");
    assert!(!stderr.contains("unknown command"));
    assert!(!stdout.contains("unknown command"));

    let (code, _stdout, stderr) = run(&["frob"]);
    assert_eq!(code, 2);
    assert!(stderr.contains("unknown command frob"), "{stderr}");

    let (code, _stdout, stderr) = run(&[]);
    assert_eq!(code, 2);
    assert!(stderr.contains("missing command"), "{stderr}");
}

#[test]
fn new_then_validate_add_note_and_export_needs_no_manual_media() {
    let root = tempfile::tempdir().unwrap();
    let deck = root.path().join("deck.json");
    let other = root.path().join("nested").join("other.json");
    fs::create_dir_all(other.parent().unwrap()).unwrap();
    let deck_arg = deck.to_str().unwrap();

    let (code, stdout, stderr) = run(&[
        "--json",
        "new",
        "--output",
        deck_arg,
        "--deck-name",
        "Parent::Child",
    ]);
    assert_eq!(code, 0, "{stdout}\n{stderr}");
    let created: serde_json::Value = serde_json::from_str(&stdout).unwrap();
    assert_eq!(created["ok"], true);
    assert_eq!(created["deck"]["deck_name"], "Parent::Child");
    assert_eq!(created["deck"]["notes"].as_array().unwrap().len(), 3);
    let job = created["deck"]["job_id"].as_str().unwrap().to_string();
    let op = created["deck"]["op_id"].as_str().unwrap().to_string();
    assert_uuid_v4(&job);
    assert_uuid_v4(&op);
    assert_ne!(job, "01234567-89ab-4cde-8fab-0123456789ab");
    assert_ne!(op, "fedcba98-7654-4210-8fed-cba987654321");

    let on_disk: serde_json::Value =
        serde_json::from_str(&fs::read_to_string(&deck).unwrap()).unwrap();
    assert_eq!(on_disk["deck_name"], "Parent::Child");
    assert_eq!(on_disk["job_id"], job);
    assert_eq!(on_disk["op_id"], op);
    let png = root.path().join("media").join("dot.png");
    let example = Path::new(env!("CARGO_MANIFEST_DIR")).join("examples/with-media/media/dot.png");
    assert_eq!(fs::read(&png).unwrap(), fs::read(example).unwrap());

    let (code, stdout, stderr) = run(&["--json", "new", "--output", other.to_str().unwrap()]);
    assert_eq!(code, 0, "{stdout}\n{stderr}");
    let second: serde_json::Value = serde_json::from_str(&stdout).unwrap();
    assert_eq!(second["deck"]["deck_name"], "Example");
    assert_ne!(second["deck"]["job_id"], job);
    assert_ne!(second["deck"]["op_id"], op);
    assert!(other
        .parent()
        .unwrap()
        .join("media")
        .join("dot.png")
        .is_file());

    let (code, stdout, stderr) = run(&["--json", "validate", "--deck", deck_arg]);
    assert_eq!(code, 0, "{stdout}\n{stderr}");
    let checked: serde_json::Value = serde_json::from_str(&stdout).unwrap();
    assert_eq!(checked["ok"], true);
    let guids: Vec<&str> = checked["notes"]
        .as_array()
        .unwrap()
        .iter()
        .map(|note| note["guid"].as_str().unwrap())
        .collect();
    assert_eq!(guids.len(), 3);
    assert!(!guids.contains(&"74a16fcd-b6db-5db5-be79-787c72943de7"));
    assert!(guids.iter().all(|guid| is_guid_format(guid)));
    // Same source_guid on both decks: normalize_import_guid, not job_id.
    assert_eq!(guids[0], "83c5c912-05aa-5d37-bc2b-cd4e9c11a709");

    let (code, other_out, stderr) = run(&["--json", "validate", "--deck", other.to_str().unwrap()]);
    assert_eq!(code, 0, "{other_out}\n{stderr}");
    let other_checked: serde_json::Value = serde_json::from_str(&other_out).unwrap();
    let other_guids: Vec<&str> = other_checked["notes"]
        .as_array()
        .unwrap()
        .iter()
        .map(|note| note["guid"].as_str().unwrap())
        .collect();
    assert_eq!(guids[0], other_guids[0]);
    assert_ne!(guids[1], other_guids[1]);
    assert_ne!(guids[2], other_guids[2]);

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
    ]);
    assert_eq!(code, 0, "{stdout}\n{stderr}");
    let added: serde_json::Value = serde_json::from_str(&stdout).unwrap();
    assert_eq!(added["ok"], true);
    assert_eq!(added["k"], 0);
    assert_uuid_v4(added["op_id"].as_str().unwrap());
    assert_ne!(added["op_id"], op);
    assert_eq!(added["notes"].as_array().unwrap().len(), 4);

    let apkg = root.path().join("out.apkg");
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
    assert_eq!(exported["ok"], true);
    assert_eq!(exported["notes"].as_array().unwrap().len(), 4);
    assert!(apkg.is_file());
    assert!(apkg.metadata().unwrap().len() > 0);

    let rejected = root.path().join("empty-name.json");
    let (code, _stdout, stderr) = run(&[
        "new",
        "--deck-name",
        "",
        "--output",
        rejected.to_str().unwrap(),
    ]);
    assert_eq!(code, 2, "{stderr}");
    assert!(stderr.contains("--deck-name is empty"), "{stderr}");
    assert!(!rejected.exists());

    let (code, _stdout, stderr) = run(&["new", "--deck-name"]);
    assert_eq!(code, 2, "{stderr}");
    assert!(stderr.contains("missing value for --deck-name"), "{stderr}");
}
