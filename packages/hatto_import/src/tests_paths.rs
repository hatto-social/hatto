// SPDX-FileCopyrightText: 2026 Hatto Social contributors
//
// SPDX-License-Identifier: AGPL-3.0-or-later

#![cfg(test)]

use std::collections::BTreeMap;
use std::fs;
use std::path::Path;

use uuid::Uuid;

use crate::cleanup::BatchIntent;
use crate::paths::{
    e_collection_path, e_directory_path, is_import_batch_id, raw_apkg_path, staged_apkg_path,
};
use crate::prepare_import;
use crate::remove_import_batch;
use crate::scan_import_folders;
use crate::ImportError;
use crate::ImportLimits;
use crate::NoteFacts;
use crate::ResidentLookup;
use crate::FORMAT_ERROR_PREFIX;
use crate::TOO_LARGE_COMPRESSED_PREFIX;

struct DenyLookup;

impl ResidentLookup for DenyLookup {
    fn note_facts(&mut self, _: &[String]) -> Result<BTreeMap<String, NoteFacts>, ImportError> {
        Err(ImportError::new("resident lookup was called"))
    }

    fn deck_id_by_name(&mut self, _: &str) -> Result<Option<i64>, ImportError> {
        Err(ImportError::new("resident lookup was called"))
    }
}

#[test]
fn batch_id_is_lowercase_uuid_v4_only() {
    let id = Uuid::new_v4();
    let text = id.as_hyphenated().to_string();
    assert!(is_import_batch_id(&text));
    assert!(!is_import_batch_id(&text.to_uppercase()));
    assert!(!is_import_batch_id("11111111-1111-5111-8111-111111111111"));
    assert!(!is_import_batch_id("not-a-uuid"));
    let collection = e_collection_path(Path::new("/data"), id).unwrap();
    let rendered = collection.to_string_lossy();
    assert!(rendered.contains("/import/e/"));
    assert!(rendered.ends_with("/collection.anki2"));
    assert!(raw_apkg_path(Path::new("/data"), id)
        .unwrap()
        .to_string_lossy()
        .ends_with(".apkg"));
    assert!(staged_apkg_path(Path::new("/data"), id)
        .unwrap()
        .to_string_lossy()
        .contains("/import/staged/"));
}

#[test]
fn data_dir_rejects_relative_and_parent_components() {
    assert!(e_directory_path(Path::new("relative"), Uuid::new_v4()).is_err());
    assert!(e_directory_path(Path::new("/tmp/../data"), Uuid::new_v4()).is_err());
}

#[test]
fn t23_scan_deletes_batches_without_prepared_intent_and_keeps_strange_names() {
    let root = tempfile::TempDir::new().unwrap();
    let data = root.path().join("data");
    fs::create_dir_all(&data).unwrap();
    let gone = Uuid::new_v4();
    let kept = Uuid::new_v4();
    fs::create_dir_all(raw_apkg_path(&data, gone).unwrap().parent().unwrap()).unwrap();
    fs::create_dir_all(staged_apkg_path(&data, gone).unwrap().parent().unwrap()).unwrap();
    fs::create_dir_all(e_directory_path(&data, gone).unwrap()).unwrap();
    fs::write(raw_apkg_path(&data, gone).unwrap(), b"raw").unwrap();
    fs::write(staged_apkg_path(&data, gone).unwrap(), b"staged").unwrap();
    fs::write(
        e_directory_path(&data, gone)
            .unwrap()
            .join("collection.anki2"),
        b"db",
    )
    .unwrap();
    fs::write(raw_apkg_path(&data, kept).unwrap(), b"keep-raw").unwrap();
    let raw_dir = raw_apkg_path(&data, gone)
        .unwrap()
        .parent()
        .unwrap()
        .to_path_buf();
    let staged_dir = staged_apkg_path(&data, gone)
        .unwrap()
        .parent()
        .unwrap()
        .to_path_buf();
    let e_parent = e_directory_path(&data, gone)
        .unwrap()
        .parent()
        .unwrap()
        .to_path_buf();
    fs::write(raw_dir.join("notes.txt"), b"strange").unwrap();
    fs::write(raw_dir.join("NOTE.APKG"), b"upper").unwrap();
    fs::write(
        staged_dir.join("11111111-1111-5111-8111-111111111111.apkg"),
        b"v5",
    )
    .unwrap();
    fs::write(
        e_parent.join("11111111-1111-4111-8111-111111111111"),
        b"file-not-dir",
    )
    .unwrap();

    let scan = scan_import_folders(&data, |batch| {
        if batch == kept {
            Some(BatchIntent::Prepared)
        } else {
            None
        }
    })
    .unwrap();
    assert_eq!(scan.removed, vec![gone]);
    assert_eq!(scan.kept_prepared, vec![kept]);
    assert!(scan.ignored.iter().any(|name| name == "raw/notes.txt"));
    assert!(scan.ignored.iter().any(|name| name == "raw/NOTE.APKG"));
    assert!(scan.ignored.iter().any(|name| name.contains("5111")));
    assert!(scan
        .ignored
        .iter()
        .any(|name| name.contains("file") || name.contains("11111111-1111-4111")));
    assert!(!raw_apkg_path(&data, gone).unwrap().exists());
    assert!(!e_directory_path(&data, gone).unwrap().exists());
    assert!(!staged_apkg_path(&data, gone).unwrap().exists());
    assert_eq!(
        fs::read(raw_apkg_path(&data, kept).unwrap()).unwrap(),
        b"keep-raw"
    );
    assert_eq!(fs::read(raw_dir.join("notes.txt")).unwrap(), b"strange");

    let again = scan_import_folders(&data, |_| Some(BatchIntent::NotPrepared)).unwrap();
    assert_eq!(again.removed, vec![kept]);
    assert!(!raw_apkg_path(&data, kept).unwrap().exists());
    assert!(raw_dir.join("notes.txt").is_file());
}

#[cfg(unix)]
#[test]
fn scan_ignores_non_utf8_names() {
    use std::ffi::OsStr;
    use std::os::unix::ffi::OsStrExt;

    let root = tempfile::TempDir::new().unwrap();
    let data = root.path().join("data");
    fs::create_dir_all(&data).unwrap();
    let batch = Uuid::new_v4();
    let raw_dir = raw_apkg_path(&data, batch)
        .unwrap()
        .parent()
        .unwrap()
        .to_path_buf();
    let staged_dir = staged_apkg_path(&data, batch)
        .unwrap()
        .parent()
        .unwrap()
        .to_path_buf();
    let e_parent = e_directory_path(&data, batch)
        .unwrap()
        .parent()
        .unwrap()
        .to_path_buf();
    fs::create_dir_all(&raw_dir).unwrap();
    fs::create_dir_all(&staged_dir).unwrap();
    fs::create_dir_all(&e_parent).unwrap();
    fs::write(raw_apkg_path(&data, batch).unwrap(), b"raw").unwrap();

    let raw_bad = raw_dir.join(OsStr::from_bytes(b"raw-\xff.apkg"));
    let staged_bad = staged_dir.join(OsStr::from_bytes(b"staged-\xff.apkg"));
    let e_bad = e_parent.join(OsStr::from_bytes(b"e-\xff"));
    let raw_ok = fs::write(&raw_bad, b"weird");
    let staged_ok = fs::write(&staged_bad, b"weird-staged");
    let dir_ok = fs::create_dir(&e_bad);
    if raw_ok.is_err() || staged_ok.is_err() || dir_ok.is_err() {
        if cfg!(target_os = "linux") {
            panic!("linux must accept a non-utf8 name: {raw_ok:?} {staged_ok:?} {dir_ok:?}");
        }
        return;
    }

    let scan = scan_import_folders(&data, |_| None).unwrap();
    assert_eq!(scan.removed, vec![batch]);
    assert!(scan.kept_prepared.is_empty());
    assert!(!raw_apkg_path(&data, batch).unwrap().exists());
    assert_eq!(fs::read(&raw_bad).unwrap(), b"weird");
    assert_eq!(fs::read(&staged_bad).unwrap(), b"weird-staged");
    assert!(e_bad.is_dir());
}

#[cfg(unix)]
#[test]
fn remove_import_batch_unlinks_dangling_symlinks() {
    use std::os::unix::fs::symlink;

    let root = tempfile::TempDir::new().unwrap();
    let data = root.path().join("data");
    fs::create_dir_all(&data).unwrap();
    let batch = Uuid::new_v4();
    let raw = raw_apkg_path(&data, batch).unwrap();
    let staged = staged_apkg_path(&data, batch).unwrap();
    let e_path = e_directory_path(&data, batch).unwrap();
    fs::create_dir_all(raw.parent().unwrap()).unwrap();
    fs::create_dir_all(staged.parent().unwrap()).unwrap();
    fs::create_dir_all(e_path.parent().unwrap()).unwrap();
    let outside = root.path().join("keep-target");
    fs::write(&outside, b"keep").unwrap();
    symlink(root.path().join("missing-raw"), &raw).unwrap();
    symlink(&outside, &staged).unwrap();
    symlink(root.path().join("missing-e"), &e_path).unwrap();
    assert!(!raw.exists(), "dangling raw link must not look present");
    assert!(fs::symlink_metadata(&raw).unwrap().file_type().is_symlink());

    remove_import_batch(&data, batch).unwrap();
    assert!(fs::symlink_metadata(&raw).is_err());
    assert!(fs::symlink_metadata(&staged).is_err());
    assert!(fs::symlink_metadata(&e_path).is_err());
    assert_eq!(fs::read(&outside).unwrap(), b"keep");
}

#[test]
fn format_errors_do_not_call_the_resident_lookup() {
    let root = tempfile::TempDir::new().unwrap();
    let data = root.path().join("data");
    fs::create_dir_all(&data).unwrap();
    let mut lookup = DenyLookup;

    let text = root.path().join("notes.txt");
    fs::write(&text, b"PK\x03\x04not-an-apkg-name").unwrap();
    let err = prepare_import(&data, &text, limits(1000), &mut lookup).unwrap_err();
    assert!(err.to_string().starts_with(FORMAT_ERROR_PREFIX), "{err}");
    assert!(err.to_string().contains(".apkg"), "{err}");

    let bad = root.path().join("bad.apkg");
    fs::write(&bad, b"not a zip file at all").unwrap();
    let err = prepare_import(&data, &bad, limits(1000), &mut lookup).unwrap_err();
    assert!(err.to_string().starts_with(FORMAT_ERROR_PREFIX), "{err}");
    assert!(err.to_string().contains("zip"), "{err}");

    let big = root.path().join("big.apkg");
    let mut bytes = b"PK\x03\x04".to_vec();
    bytes.extend(std::iter::repeat_n(1, 40));
    fs::write(&big, &bytes).unwrap();
    let err = prepare_import(&data, &big, limits(8), &mut lookup).unwrap_err();
    assert!(
        err.to_string().starts_with(TOO_LARGE_COMPRESSED_PREFIX),
        "{err}"
    );
    assert!(err.to_string().contains("max_bytes"), "{err}");
    assert!(!data.join("import").exists());
}

fn limits(max_bytes: u64) -> ImportLimits {
    ImportLimits {
        max_bytes,
        max_uncompressed_bytes: u64::MAX,
    }
}
