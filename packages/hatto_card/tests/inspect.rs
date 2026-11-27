// SPDX-FileCopyrightText: 2026 Hatto Social contributors
//
// SPDX-License-Identifier: AGPL-3.0-or-later

//! `hatto-card inspect` prints Stage E file notes and removes its temp dir.

use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;

use hatto_card_contract::{
    local_note_guid, normalize_import_guid, note_content_hash, parse_uuid, NoteGuid,
};
use rslib_bridge::api::import_stage_e;

fn run(args: &[&str]) -> (i32, String, String) {
    let output = Command::new(env!("CARGO_BIN_EXE_hatto-card"))
        .args(args)
        .output()
        .expect("run hatto-card");
    let code = output.status.code().unwrap_or(1);
    let stdout = String::from_utf8(output.stdout).unwrap();
    let stderr = String::from_utf8(output.stderr).unwrap();
    (code, stdout, stderr)
}

/// Run `hatto-card` with temp files pointed at `dir`. Returns status and output.
fn run_in(dir: &Path, args: &[&str]) -> (i32, String, String) {
    let output = Command::new(env!("CARGO_BIN_EXE_hatto-card"))
        .args(args)
        .env("TMPDIR", dir)
        .env("TMP", dir)
        .env("TEMP", dir)
        .output()
        .expect("run hatto-card");
    let code = output.status.code().unwrap_or(1);
    let stdout = String::from_utf8(output.stdout).unwrap();
    let stderr = String::from_utf8(output.stderr).unwrap();
    (code, stdout, stderr)
}

fn assert_no_temp_left(dir: &Path, args: &[&str], stdout: &str, stderr: &str) {
    let left: Vec<_> = fs::read_dir(dir)
        .unwrap()
        .map(|entry| entry.unwrap().file_name().to_string_lossy().into_owned())
        .collect();
    assert!(
        left.is_empty(),
        "temporary data_dir left behind after {args:?}: {left:?}\nstdout:\n{stdout}\nstderr:\n{stderr}"
    );
}

fn export_example(root: &Path) -> PathBuf {
    let deck = Path::new(env!("CARGO_MANIFEST_DIR")).join("examples/with-media/deck.json");
    let apkg = root.join("with-media.apkg");
    let (code, stdout, stderr) = run(&[
        "--json",
        "export",
        "--deck",
        deck.to_str().unwrap(),
        "--output",
        apkg.to_str().unwrap(),
    ]);
    assert_eq!(code, 0, "{stdout}\n{stderr}");
    assert!(apkg.is_file());
    apkg
}

fn hex_hash(fields: &[&str], tags: &[&str]) -> String {
    note_content_hash(fields, tags)
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect()
}

/// Guids the example deck exports, each passed through `normalize_import_guid`,
/// and the content hash of that note's fields and tags.
fn expected_example_notes() -> Vec<(String, String)> {
    let source = concat!("'\"`", "\\", "한글");
    let source_guid = normalize_import_guid(source).unwrap();
    let op = parse_uuid("fedcba98-7654-4210-8fed-cba987654321").unwrap();
    let local = |k: u32| {
        let guid = NoteGuid::from_uuid(local_note_guid(op, k)).into_string();
        normalize_import_guid(&guid).unwrap()
    };
    vec![
        (
            source_guid,
            hex_hash(&["front <img src=\"dot.png\">", "back"], &["example"]),
        ),
        (local(0), hex_hash(&["local zero", "back"], &["local"])),
        (
            local(u32::MAX),
            hex_hash(&["local max", "back"], &["local", "max"]),
        ),
    ]
}

fn parse_notes(stdout: &str) -> Vec<serde_json::Value> {
    let value: serde_json::Value = serde_json::from_str(stdout).unwrap();
    assert_eq!(value["ok"], true, "{stdout}");
    value["notes"].as_array().cloned().unwrap()
}

fn assert_note_facts(notes: &[serde_json::Value], expected: &[(String, String)]) {
    assert_eq!(notes.len(), expected.len(), "{notes:?}");
    for note in notes {
        let guid = note["guid"].as_str().unwrap();
        assert_eq!(
            guid,
            normalize_import_guid(guid).unwrap(),
            "reported guid is not the normalized import guid"
        );
        let content_hash = note["content_hash"].as_str().unwrap();
        assert_eq!(content_hash.len(), 64, "{content_hash}");
        assert!(
            content_hash
                .chars()
                .all(|ch| ch.is_ascii_hexdigit() && !ch.is_ascii_uppercase()),
            "{content_hash}"
        );
        let notetype_id = note["notetype_id"].as_i64().unwrap();
        assert_eq!(notetype_id, 1_767_225_600_001, "{note}");
        assert!(note["mod"].is_i64() || note["mod"].is_u64(), "{note}");
        let (_, hash) = expected
            .iter()
            .find(|(expect_guid, _)| expect_guid == guid)
            .unwrap_or_else(|| panic!("unexpected guid {guid}"));
        assert_eq!(content_hash, hash, "{guid}");
    }
    for (guid, _) in expected {
        assert!(
            notes.iter().any(|note| note["guid"] == guid.as_str()),
            "missing {guid} in {notes:?}"
        );
    }
}

/// Direct Stage E read, so the CLI order can be checked against `file_notes()`.
fn stage_file_notes(apkg: &Path) -> Vec<rslib_bridge::api::NoteFacts> {
    let data = tempfile::Builder::new()
        .prefix(hatto_card::INSPECT_TEMP_PREFIX)
        .tempdir()
        .unwrap();
    let data_path = data.path().canonicalize().unwrap();
    let pending = import_stage_e(
        data_path.to_str().unwrap().to_owned(),
        apkg.to_str().unwrap().to_owned(),
        hatto_card::INSPECT_MAX_BYTES,
        hatto_card::INSPECT_MAX_UNCOMPRESSED_BYTES,
    )
    .unwrap_or_else(|err| panic!("import_stage_e: {err}"));
    let notes = pending.file_notes();
    drop(pending);
    drop(data);
    assert!(!data_path.exists(), "stage e left {}", data_path.display());
    notes
}

#[test]
fn inspect_example_reports_normalized_guids_and_leaves_the_apkg_and_temp_dir() {
    let root = tempfile::tempdir().unwrap();
    let apkg = export_example(root.path());
    let before = fs::read(&apkg).unwrap();
    let modified = fs::metadata(&apkg).unwrap().modified().unwrap();
    let mut perms = fs::metadata(&apkg).unwrap().permissions();
    perms.set_readonly(true);
    fs::set_permissions(&apkg, perms).unwrap();

    let expected = expected_example_notes();
    let apkg_arg = apkg.to_str().unwrap();

    let watch = tempfile::tempdir().unwrap();
    let watch_dir = watch.path().canonicalize().unwrap();
    let (code, stdout, stderr) = run_in(&watch_dir, &["inspect", apkg_arg]);
    assert_eq!(code, 0, "{stdout}\n{stderr}");
    assert!(stderr.is_empty(), "{stderr}");
    assert!(stdout.lines().count() > 1, "{stdout}");
    assert_no_temp_left(&watch_dir, &["inspect", apkg_arg], &stdout, &stderr);
    let pretty = parse_notes(&stdout);
    assert_note_facts(&pretty, &expected);
    assert_eq!(fs::read(&apkg).unwrap(), before);
    assert_eq!(fs::metadata(&apkg).unwrap().modified().unwrap(), modified);

    let watch_json = tempfile::tempdir().unwrap();
    let watch_json_dir = watch_json.path().canonicalize().unwrap();
    let (code, json_stdout, stderr) = run_in(&watch_json_dir, &["--json", "inspect", apkg_arg]);
    assert_eq!(code, 0, "{json_stdout}\n{stderr}");
    assert!(stderr.is_empty(), "{stderr}");
    assert_eq!(json_stdout.lines().count(), 1, "{json_stdout}");
    assert_no_temp_left(
        &watch_json_dir,
        &["--json", "inspect", apkg_arg],
        &json_stdout,
        &stderr,
    );
    let compact = parse_notes(&json_stdout);
    assert_note_facts(&compact, &expected);
    assert_eq!(compact, pretty);
    assert_eq!(fs::read(&apkg).unwrap(), before);

    let staged = stage_file_notes(&apkg);
    assert_eq!(staged.len(), pretty.len());
    for (reported, facts) in pretty.iter().zip(&staged) {
        assert_eq!(reported["guid"], facts.guid);
        let hash: String = facts
            .content_hash
            .iter()
            .map(|byte| format!("{byte:02x}"))
            .collect();
        assert_eq!(reported["content_hash"], hash);
        assert_eq!(reported["notetype_id"], facts.notetype_id);
        assert_eq!(reported["mod"], facts.r#mod);
    }
    assert_eq!(fs::read(&apkg).unwrap(), before);
    assert_eq!(fs::metadata(&apkg).unwrap().modified().unwrap(), modified);
    assert!(fs::metadata(&apkg).unwrap().permissions().readonly());
}

#[test]
fn inspect_missing_and_invalid_apkg_exit_nonzero_and_leave_no_temp_dir() {
    let root = tempfile::tempdir().unwrap();
    let missing = root.path().join("missing.apkg");
    let missing_arg = missing.to_str().unwrap();

    let watch = tempfile::tempdir().unwrap();
    let watch_dir = watch.path().canonicalize().unwrap();
    let (code, stdout, stderr) = run_in(&watch_dir, &["inspect", missing_arg]);
    assert_eq!(code, 1, "{stdout}\n{stderr}");
    assert!(stdout.is_empty(), "{stdout}");
    assert!(stderr.contains("hatto-card:"), "{stderr}");
    assert!(!stderr.contains("unexpected argument"), "{stderr}");
    assert!(!missing.exists());
    assert_no_temp_left(&watch_dir, &["inspect", missing_arg], &stdout, &stderr);

    let bad = root.path().join("bad.apkg");
    let bytes = b"this is not a zip";
    fs::write(&bad, bytes).unwrap();
    let bad_arg = bad.to_str().unwrap();
    let watch_bad = tempfile::tempdir().unwrap();
    let watch_bad_dir = watch_bad.path().canonicalize().unwrap();
    let (code, stdout, stderr) = run_in(&watch_bad_dir, &["--json", "inspect", bad_arg]);
    assert_eq!(code, 1, "{stdout}\n{stderr}");
    let failure: serde_json::Value = serde_json::from_str(&stdout).unwrap();
    assert_eq!(failure["ok"], false, "{stdout}");
    assert!(failure["message"].is_string(), "{stdout}");
    assert_eq!(fs::read(&bad).unwrap(), bytes);
    assert_no_temp_left(
        &watch_bad_dir,
        &["--json", "inspect", bad_arg],
        &stdout,
        &stderr,
    );

    let watch_usage = tempfile::tempdir().unwrap();
    let watch_usage_dir = watch_usage.path().canonicalize().unwrap();
    let (code, _stdout, stderr) = run_in(&watch_usage_dir, &["inspect"]);
    assert_eq!(code, 2, "{stderr}");
    assert!(stderr.contains("missing apkg"), "{stderr}");
    assert_no_temp_left(&watch_usage_dir, &["inspect"], "", &stderr);
}
