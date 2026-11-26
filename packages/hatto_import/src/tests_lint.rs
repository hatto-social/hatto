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

/// Public items must not name a resident collection handle. `lib.rs` text
/// alone would miss a public field in another file.
#[test]
fn public_items_do_not_name_a_resident_handle() {
    let needle = concat!("Anki", "Backend");
    let root = Path::new(env!("CARGO_MANIFEST_DIR")).join("src");
    let mut files = Vec::new();
    walk(&root, &mut files);
    for path in files {
        let text = fs::read_to_string(&path).unwrap();
        if text
            .lines()
            .take(30)
            .any(|line| line.trim() == "#![cfg(test)]")
        {
            continue;
        }
        for (line, item) in public_items(&text) {
            assert!(
                !item.contains(needle),
                "{}:{line} public item names a resident handle",
                path.display()
            );
        }
    }
}

fn public_items(text: &str) -> Vec<(usize, String)> {
    let lines: Vec<&str> = text.lines().collect();
    let mut items = Vec::new();
    let mut index = 0;
    while index < lines.len() {
        let trimmed = lines[index].trim_start();
        if !is_public_item(trimmed) {
            index += 1;
            continue;
        }
        let start = index;
        let mut depth = i32::try_from(lines[index].chars().filter(|ch| *ch == '{').count())
            .unwrap_or(i32::MAX)
            - i32::try_from(lines[index].chars().filter(|ch| *ch == '}').count())
                .unwrap_or(i32::MAX);
        index += 1;
        if depth > 0 {
            while index < lines.len() && depth > 0 {
                depth += i32::try_from(lines[index].chars().filter(|ch| *ch == '{').count())
                    .unwrap_or(i32::MAX);
                depth -= i32::try_from(lines[index].chars().filter(|ch| *ch == '}').count())
                    .unwrap_or(i32::MAX);
                index += 1;
            }
        }
        items.push((start + 1, lines[start..index].join("\n")));
    }
    items
}

fn is_public_item(trimmed: &str) -> bool {
    if trimmed.starts_with("pub(crate)") || trimmed.starts_with("pub(super)") {
        return false;
    }
    trimmed.starts_with("pub ") || trimmed.starts_with("pub(")
}

fn call_sites(files: &[std::path::PathBuf], needle: &str) -> Vec<String> {
    let mut hits = Vec::new();
    for path in files {
        let text = fs::read_to_string(path).unwrap();
        let name = path.file_name().and_then(|name| name.to_str()).unwrap();
        let mut seen = 0;
        while let Some(rel) = text[seen..].find(needle) {
            let at = seen + rel;
            let before = text[..at].chars().next_back();
            let word = before.is_none_or(|ch| !ch.is_ascii_alphanumeric() && ch != '_');
            if word && text[at + needle.len()..].trim_start().starts_with('(') {
                let line = text[..at].bytes().filter(|byte| *byte == b'\n').count() + 1;
                hits.push(format!("{name}:{line}"));
            }
            seen = at + needle.len();
        }
    }
    hits
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

/// `\bopen_backend\s*\(` once, only in the body of
/// `#[cfg(test)] fn open_test_collection` in `channel.rs`.
/// Calls to open a backend with a profile, and the collection smoke helper,
/// do not appear.
#[test]
fn open_backend_call_is_only_inside_the_cfg_test_opener() {
    let needle = concat!("open_", "backend");
    let with_profile = concat!("open_", "backend_with_profile");
    let smoke = concat!("smoke_", "open_collection");
    let root = Path::new(env!("CARGO_MANIFEST_DIR")).join("src");
    let mut files = Vec::new();
    walk(&root, &mut files);
    let hits = call_sites(&files, needle);
    let profile_hits = call_sites(&files, with_profile);
    let smoke_hits = call_sites(&files, smoke);
    assert!(
        profile_hits.is_empty(),
        "{}( must not appear, found {}",
        with_profile,
        profile_hits.join(", ")
    );
    assert!(
        smoke_hits.is_empty(),
        "{}( must not appear, found {}",
        smoke,
        smoke_hits.join(", ")
    );
    let channel = fs::read_to_string(root.join("channel.rs")).unwrap();
    let rows: Vec<&str> = channel.lines().collect();
    let start = rows
        .iter()
        .position(|row| row.contains("fn open_test_collection"))
        .unwrap_or(usize::MAX);
    let cfg = start < rows.len()
        && rows[..start]
            .iter()
            .rev()
            .find(|row| !row.trim().is_empty())
            .is_some_and(|row| row.trim() == "#[cfg(test)]");
    let mut depth = 0i32;
    let mut end = start;
    if start < rows.len() {
        for (offset, row) in rows[start..].iter().enumerate() {
            depth += i32::try_from(row.chars().filter(|ch| *ch == '{').count()).unwrap_or(i32::MAX);
            depth -= i32::try_from(row.chars().filter(|ch| *ch == '}').count()).unwrap_or(i32::MAX);
            if offset > 0 && depth <= 0 {
                end = start + offset;
                break;
            }
        }
    }
    let line = hits
        .first()
        .and_then(|hit| hit.rsplit(':').next()?.parse::<usize>().ok())
        .unwrap_or(0);
    let found = if hits.is_empty() {
        "nothing".to_string()
    } else {
        hits.join(", ")
    };
    let call = concat!("open_", "backend(");
    assert!(
        hits.len() == 1
            && hits[0].starts_with("channel.rs:")
            && cfg
            && line > start + 1
            && line <= end + 1,
        "{call} must appear once, inside #[cfg(test)] fn open_test_collection in channel.rs, found {found}"
    );
}
