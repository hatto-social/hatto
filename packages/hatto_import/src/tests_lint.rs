// SPDX-FileCopyrightText: 2026 Hatto Social contributors
//
// SPDX-License-Identifier: AGPL-3.0-or-later

//! Source lint for the temp-directory hook and for where the package import
//! method name is allowed to appear.

#![cfg(test)]

use std::fs;
use std::path::Path;

#[test]
fn source_has_no_temp_hook_and_limits_package_import() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR")).join("src");
    let prepare = concat!("prepare_", "runtime");
    let tmp = concat!("TMP", "DIR");
    let assign = concat!("set_", "var");
    let resident_import = concat!("import_", "anki_package");
    let mut files = Vec::new();
    walk(&root, &mut files);
    for path in files {
        let text = fs::read_to_string(&path).unwrap();
        let test_only = text
            .lines()
            .take(30)
            .any(|line| line.trim() == "#![cfg(test)]");
        if test_only {
            assert!(
                !text.contains(prepare) && !text.contains(tmp) && !text.contains(assign),
                "{} mentions the temp-dir hook",
                path.display()
            );
            continue;
        }
        assert!(
            !text.contains(prepare),
            "{} mentions the temp-dir hook",
            path.display()
        );
        assert!(
            !text.contains(tmp),
            "{} mentions the temp env name",
            path.display()
        );
        assert!(
            !text.contains(assign),
            "{} sets a process environment variable",
            path.display()
        );
        let name = path.file_name().and_then(|name| name.to_str()).unwrap();
        if text.contains(resident_import) {
            assert_eq!(
                name,
                "channel.rs",
                "{} calls import_anki_package outside the E session",
                path.display()
            );
        }
    }
    let lib = fs::read_to_string(root.join("lib.rs")).unwrap();
    assert!(
        !lib.contains("AnkiBackend"),
        "the public crate root names a collection handle type"
    );
}

fn walk(dir: &Path, out: &mut Vec<std::path::PathBuf>) {
    for entry in fs::read_dir(dir).unwrap() {
        let path = entry.unwrap().path();
        if path.is_dir() {
            walk(&path, out);
        } else if path.extension().and_then(|ext| ext.to_str()) == Some("rs") {
            out.push(path);
        }
    }
}
