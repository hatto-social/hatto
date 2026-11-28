// SPDX-FileCopyrightText: 2026 Hatto Social contributors
//
// SPDX-License-Identifier: AGPL-3.0-or-later

//! Flag values that start with `-`, `add-notes`, and stdin deck JSON.

use std::fs;
use std::io::Write;
use std::path::Path;
use std::process::{Command, Stdio};

use hatto_card_contract::{local_note_guid, parse_uuid, NoteGuid};

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

fn run_stdin(dir: &Path, args: &[&str], stdin: &[u8]) -> (i32, String, String) {
    let mut child = bin()
        .args(args)
        .current_dir(dir)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .expect("spawn hatto-card");
    child
        .stdin
        .take()
        .unwrap()
        .write_all(stdin)
        .expect("write stdin");
    let output = child.wait_with_output().expect("wait hatto-card");
    let code = output.status.code().unwrap_or(1);
    let stdout = String::from_utf8(output.stdout).unwrap();
    let stderr = String::from_utf8(output.stderr).unwrap();
    (code, stdout, stderr)
}

#[test]
fn hyphen_values_and_equals_flags_parse() {
    let root = tempfile::tempdir().unwrap();
    let deck = root.path().join("deck.json");
    let deck_arg = deck.to_str().unwrap();
    let (code, stdout, stderr) = run(&[
        "--json",
        "new",
        "--empty",
        "--deck-name=Example",
        "--notetype=Hatto Basic",
        "--output",
        deck_arg,
    ]);
    assert_eq!(code, 0, "{stdout}\n{stderr}");
    let created: serde_json::Value = serde_json::from_str(&stdout).unwrap();
    assert_eq!(created["deck"]["notes"], serde_json::json!([]));
    assert_eq!(created["deck"]["notetype"], "Hatto Basic");
    assert_eq!(created["deck"]["deck_name"], "Example");

    let (code, stdout, stderr) = run(&[
        "--json",
        "add-note",
        "--deck",
        deck_arg,
        "--notetype",
        "Hatto Basic",
        "--field",
        "--foo",
        "--field=--bar",
        "--tag",
        "-v",
        "--tag=--keep",
        "--deck-name=Example::Sub",
    ]);
    assert_eq!(code, 0, "{stdout}\n{stderr}");
    let on_disk: serde_json::Value =
        serde_json::from_str(&fs::read_to_string(&deck).unwrap()).unwrap();
    let note = &on_disk["notes"][0];
    assert_eq!(note["fields"], serde_json::json!(["--foo", "--bar"]));
    assert_eq!(note["tags"], serde_json::json!(["-v", "--keep"]));
    assert_eq!(note["deck_name"], "Example::Sub");

    let (code, _stdout, stderr) = run(&["new", "--deck-name"]);
    assert_eq!(code, 2, "{stderr}");
    assert!(stderr.contains("missing value for --deck-name"), "{stderr}");

    let (code, stdout, stderr) = run(&[
        "--json",
        "add-note",
        "--deck",
        deck_arg,
        "--notetype",
        "Basic",
        "--field",
    ]);
    assert_eq!(code, 2, "{stdout}\n{stderr}");
    let failure: serde_json::Value = serde_json::from_str(&stdout).unwrap();
    assert_eq!(failure["ok"], false);
    assert!(
        failure["message"]
            .as_str()
            .unwrap()
            .contains("missing value for --field"),
        "{stdout}"
    );
    assert!(stderr.is_empty(), "{stderr}");

    let (code, stdout, stderr) = run(&["--json", "new", "--notetype", "Nope", "--empty"]);
    assert_eq!(code, 1, "{stdout}\n{stderr}");
    let failure: serde_json::Value = serde_json::from_str(&stdout).unwrap();
    assert_eq!(failure["errors"][0]["code"], "NOTETYPE_UNKNOWN");
    assert!(
        failure["errors"][0]["message"]
            .as_str()
            .unwrap()
            .contains("not a seed notetype"),
        "{stdout}"
    );
}

#[test]
fn field_and_tag_values_are_not_help_or_json() {
    let root = tempfile::tempdir().unwrap();
    let deck = root.path().join("deck.json");
    let deck_arg = deck.to_str().unwrap();
    let (code, stdout, stderr) = run(&[
        "--json",
        "new",
        "--empty",
        "--output",
        deck_arg,
        "--notetype",
        "Hatto Basic",
    ]);
    assert_eq!(code, 0, "{stdout}\n{stderr}");

    let (code, stdout, stderr) = run(&[
        "--json",
        "add-note",
        "--deck",
        deck_arg,
        "--notetype",
        "Hatto Basic",
        "--field",
        "-h",
        "--field",
        "--json",
        "--tag",
        "--help",
    ]);
    assert_eq!(code, 0, "{stdout}\n{stderr}");
    assert!(!stdout.contains("usage:"), "{stdout}");
    let added: serde_json::Value = serde_json::from_str(&stdout).unwrap();
    assert_eq!(added["ok"], true);
    let on_disk: serde_json::Value =
        serde_json::from_str(&fs::read_to_string(&deck).unwrap()).unwrap();
    assert_eq!(
        on_disk["notes"][0]["fields"],
        serde_json::json!(["-h", "--json"])
    );
    assert_eq!(on_disk["notes"][0]["tags"], serde_json::json!(["--help"]));

    let (code, stdout, stderr) = run(&[
        "--json",
        "add-note",
        "--deck",
        deck_arg,
        "--notetype",
        "Basic",
        "--field",
        "help",
        "--field",
        "back",
        "--tag",
        "-h",
    ]);
    assert_eq!(code, 0, "{stdout}\n{stderr}");
    let on_disk: serde_json::Value =
        serde_json::from_str(&fs::read_to_string(&deck).unwrap()).unwrap();
    assert_eq!(
        on_disk["notes"][1]["fields"],
        serde_json::json!(["help", "back"])
    );
    assert_eq!(on_disk["notes"][1]["tags"], serde_json::json!(["-h"]));
}

#[test]
fn add_notes_jsonl_and_stdin_deck_roundtrip_flags() {
    let root = tempfile::tempdir().unwrap();
    let deck = root.path().join("deck.json");
    let deck_arg = deck.to_str().unwrap();
    let (code, stdout, stderr) = run(&[
        "--json",
        "new",
        "--empty",
        "--output",
        deck_arg,
        "--deck-name",
        "Root",
    ]);
    assert_eq!(code, 0, "{stdout}\n{stderr}");

    let input = root.path().join("notes.jsonl");
    fs::write(
        &input,
        concat!(
            "{\"fields\":[\"one\",\"two\"],\"deck_name\":\"Root::Sub\"}\n",
            "{\"fields\":[\"{{c1::hole}}\",\"extra\"],\"notetype\":\"Cloze\"}\n",
        ),
    )
    .unwrap();
    let op = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee";
    let (code, stdout, stderr) = run(&[
        "--json",
        "add-notes",
        "--deck",
        deck_arg,
        "--input",
        input.to_str().unwrap(),
        "--op-id",
        op,
        "--start-k",
        "4",
    ]);
    assert_eq!(code, 0, "{stdout}\n{stderr}");
    let added: serde_json::Value = serde_json::from_str(&stdout).unwrap();
    assert_eq!(added["added"], 2);
    assert_eq!(added["start_k"], 4);
    let op_id = parse_uuid(op).unwrap();
    assert_eq!(
        added["notes"][0]["guid"],
        NoteGuid::from_uuid(local_note_guid(op_id, 4)).into_string()
    );
    assert_eq!(
        added["notes"][1]["guid"],
        NoteGuid::from_uuid(local_note_guid(op_id, 5)).into_string()
    );
    let on_disk: serde_json::Value =
        serde_json::from_str(&fs::read_to_string(&deck).unwrap()).unwrap();
    assert_eq!(on_disk["notes"][0]["deck_name"], "Root::Sub");
    assert_eq!(on_disk["notes"][1]["notetype"], "Cloze");

    let bad = root.path().join("bad.json");
    fs::write(&bad, r#"[{"fields":["nope"],"deck_name":"Other"}]"#).unwrap();
    let snapshot = fs::read(&deck).unwrap();
    let (code, stdout, stderr) = run(&[
        "--json",
        "add-notes",
        "--deck",
        deck_arg,
        "--input",
        bad.to_str().unwrap(),
    ]);
    assert_eq!(code, 1, "{stdout}\n{stderr}");
    assert_eq!(fs::read(&deck).unwrap(), snapshot);

    fs::write(root.path().join("media").join("dot.png"), b"png").unwrap();
    let mut stdin_deck = on_disk;
    stdin_deck["media_dir"] = serde_json::json!("media");
    stdin_deck["notes"][0]["fields"][0] = serde_json::json!("one <img src=\"dot.png\">");
    let bytes = serde_json::to_vec(&stdin_deck).unwrap();
    let (code, stdout, stderr) =
        run_stdin(root.path(), &["--json", "validate", "--deck", "-"], &bytes);
    assert_eq!(code, 0, "{stdout}\n{stderr}");
    let checked: serde_json::Value = serde_json::from_str(&stdout).unwrap();
    assert_eq!(checked["ok"], true);
    assert_eq!(checked["notes"].as_array().unwrap().len(), 2);

    let apkg = root.path().join("out.apkg");
    let (code, stdout, stderr) = run_stdin(
        root.path(),
        &[
            "--json",
            "export",
            "--deck",
            "-",
            "--output",
            apkg.to_str().unwrap(),
        ],
        &bytes,
    );
    assert_eq!(code, 0, "{stdout}\n{stderr}");
    assert!(apkg.is_file());
    let exported: serde_json::Value = serde_json::from_str(&stdout).unwrap();
    assert_eq!(exported["notes"].as_array().unwrap().len(), 2);

    let mut missing_deck = stdin_deck;
    missing_deck["notes"][0]["fields"][0] = serde_json::json!("<img src=\"gone.png\">");
    let (code, stdout, stderr) = run_stdin(
        root.path(),
        &["--json", "validate", "--deck=-"],
        &serde_json::to_vec(&missing_deck).unwrap(),
    );
    assert_eq!(code, 1, "{stdout}\n{stderr}");
    let failure: serde_json::Value = serde_json::from_str(&stdout).unwrap();
    let rendered = failure.to_string();
    assert!(
        rendered.contains("gone.png") && rendered.contains("notes[0].fields[0]"),
        "{rendered}"
    );
}

#[test]
fn k_without_op_id_and_unknown_fields_keep_the_deck() {
    let root = tempfile::tempdir().unwrap();
    let deck = root.path().join("deck.json");
    let deck_arg = deck.to_str().unwrap();
    let (code, stdout, stderr) = run(&[
        "--json",
        "new",
        "--empty",
        "--output",
        deck_arg,
        "--notetype",
        "Hatto Basic",
    ]);
    assert_eq!(code, 0, "{stdout}\n{stderr}");
    let before = fs::read(&deck).unwrap();

    let (code, stdout, stderr) = run(&[
        "--json",
        "add-note",
        "--deck",
        deck_arg,
        "--notetype",
        "Hatto Basic",
        "--field",
        "front",
        "--field",
        "back",
        "--k",
        "7",
    ]);
    assert_eq!(code, 1, "{stdout}\n{stderr}");
    let failure: serde_json::Value = serde_json::from_str(&stdout).unwrap();
    assert_eq!(failure["ok"], false);
    assert_eq!(failure["errors"][0]["code"], "OP_ID_REQUIRED");
    assert_eq!(failure["errors"][0]["location"], "--k");
    assert_eq!(fs::read(&deck).unwrap(), before);

    let input = root.path().join("k-only.json");
    fs::write(&input, r#"[{"fields":["a","b"],"k":7}]"#).unwrap();
    let (code, stdout, stderr) = run(&[
        "--json",
        "add-notes",
        "--deck",
        deck_arg,
        "--input",
        input.to_str().unwrap(),
    ]);
    assert_eq!(code, 1, "{stdout}\n{stderr}");
    let failure: serde_json::Value = serde_json::from_str(&stdout).unwrap();
    assert_eq!(failure["errors"][0]["code"], "OP_ID_REQUIRED");
    assert_eq!(failure["errors"][0]["location"], "input[0]");
    assert_eq!(fs::read(&deck).unwrap(), before);

    let unknown = root.path().join("unknown.json");
    fs::write(
        &unknown,
        r#"[{"fields":["a","b"],"tag":["x"],"deckname":"Example::Sub"}]"#,
    )
    .unwrap();
    let (code, stdout, stderr) = run(&[
        "--json",
        "add-notes",
        "--deck",
        deck_arg,
        "--input",
        unknown.to_str().unwrap(),
    ]);
    assert_eq!(code, 1, "{stdout}\n{stderr}");
    let failure: serde_json::Value = serde_json::from_str(&stdout).unwrap();
    let codes: Vec<_> = failure["errors"]
        .as_array()
        .unwrap()
        .iter()
        .map(|error| error["code"].as_str().unwrap())
        .collect();
    assert_eq!(codes, ["UNKNOWN_FIELD", "UNKNOWN_FIELD"]);
    assert_eq!(fs::read(&deck).unwrap(), before);
}
