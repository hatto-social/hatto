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
    let open_backend_call = concat!("open_", "backend(");
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
        // `#[cfg(test)]` items may call the unrestricted opener. Everything
        // else in this file is production source and must not.
        assert!(
            !without_cfg_test_items(&text).contains(open_backend_call),
            "{} calls open_backend outside #[cfg(test)]",
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

/// Source a non-test build compiles. A `#[cfg(test)]` attribute and the item
/// it gates are removed, including doc comments directly above that attribute.
/// Strings and comments are not searched for the attribute.
fn without_cfg_test_items(text: &str) -> String {
    let bytes = text.as_bytes();
    let mut out = String::with_capacity(text.len());
    let mut i = 0;
    while i < bytes.len() {
        if let Some(end) = non_code_end(bytes, i) {
            out.push_str(&text[i..end]);
            i = end;
            continue;
        }
        if is_cfg_test_attribute(bytes, i) {
            trim_preceding_doc_comments(&mut out);
            let end = skip_cfg_test_item(bytes, i);
            if end <= i {
                let ch = text[i..].chars().next().unwrap();
                out.push(ch);
                i += ch.len_utf8();
                continue;
            }
            i = end;
            continue;
        }
        let ch = text[i..].chars().next().unwrap();
        out.push(ch);
        i += ch.len_utf8();
    }
    out
}

fn trim_preceding_doc_comments(out: &mut String) {
    loop {
        let end = out.trim_end_matches([' ', '\t']).len();
        out.truncate(end);
        if !out.ends_with('\n') {
            break;
        }
        let body = &out[..out.len() - 1];
        let line_start = body.rfind('\n').map(|index| index + 1).unwrap_or(0);
        let line = body[line_start..].trim();
        if line.is_empty() || line.starts_with("///") {
            out.truncate(line_start);
            continue;
        }
        break;
    }
}

fn skip_cfg_test_item(bytes: &[u8], hash_at: usize) -> usize {
    let mut index = skip_attribute(bytes, hash_at);
    loop {
        index = skip_whitespace_and_comments(bytes, index);
        if index >= bytes.len() {
            return index;
        }
        if is_attribute(bytes, index) {
            index = skip_attribute(bytes, index);
            continue;
        }
        break;
    }
    skip_one_item(bytes, index)
}

fn skip_one_item(bytes: &[u8], mut index: usize) -> usize {
    let mut braces = 0i32;
    let mut parens = 0i32;
    let mut brackets = 0i32;
    while index < bytes.len() {
        if let Some(end) = non_code_end(bytes, index) {
            index = end;
            continue;
        }
        match bytes[index] {
            b'{' => braces += 1,
            b'}' => {
                if braces == 0 {
                    return index;
                }
                braces -= 1;
                if braces == 0 && parens == 0 && brackets == 0 {
                    return index + 1;
                }
            }
            b'(' => parens += 1,
            b')' => parens = parens.saturating_sub(1),
            b'[' => brackets += 1,
            b']' => brackets = brackets.saturating_sub(1),
            b';' if braces == 0 && parens == 0 && brackets == 0 => return index + 1,
            _ => {}
        }
        index += 1;
    }
    index
}

fn is_cfg_test_attribute(bytes: &[u8], index: usize) -> bool {
    let Some(mut cursor) = attribute_inner(bytes, index) else {
        return false;
    };
    cursor = skip_ascii_ws(bytes, cursor);
    if !starts_with(bytes, cursor, b"cfg") {
        return false;
    }
    cursor = skip_ascii_ws(bytes, cursor + 3);
    if bytes.get(cursor) != Some(&b'(') {
        return false;
    }
    cursor = skip_ascii_ws(bytes, cursor + 1);
    if !starts_with(bytes, cursor, b"test") {
        return false;
    }
    cursor = skip_ascii_ws(bytes, cursor + 4);
    if bytes.get(cursor) != Some(&b')') {
        return false;
    }
    cursor = skip_ascii_ws(bytes, cursor + 1);
    bytes.get(cursor) == Some(&b']')
}

fn is_attribute(bytes: &[u8], index: usize) -> bool {
    attribute_inner(bytes, index).is_some()
}

fn attribute_inner(bytes: &[u8], index: usize) -> Option<usize> {
    if bytes.get(index) != Some(&b'#') {
        return None;
    }
    let cursor = skip_ascii_ws(bytes, index + 1);
    if bytes.get(cursor) == Some(&b'[') {
        Some(cursor + 1)
    } else {
        None
    }
}

fn skip_attribute(bytes: &[u8], index: usize) -> usize {
    let Some(mut cursor) = attribute_inner(bytes, index) else {
        return index + 1;
    };
    let mut depth = 1i32;
    while cursor < bytes.len() {
        if let Some(end) = non_code_end(bytes, cursor) {
            cursor = end;
            continue;
        }
        match bytes[cursor] {
            b'[' => depth += 1,
            b']' => {
                depth -= 1;
                if depth == 0 {
                    return cursor + 1;
                }
            }
            _ => {}
        }
        cursor += 1;
    }
    bytes.len()
}

fn skip_whitespace_and_comments(bytes: &[u8], mut index: usize) -> usize {
    loop {
        index = skip_ascii_ws(bytes, index);
        match comment_end(bytes, index) {
            Some(end) => index = end,
            None => return index,
        }
    }
}

fn skip_ascii_ws(bytes: &[u8], mut index: usize) -> usize {
    while index < bytes.len() && bytes[index].is_ascii_whitespace() {
        index += 1;
    }
    index
}

fn starts_with(bytes: &[u8], index: usize, needle: &[u8]) -> bool {
    bytes
        .get(index..)
        .is_some_and(|rest| rest.starts_with(needle))
}

/// End of a comment or string/char literal starting at `index`, if any.
fn non_code_end(bytes: &[u8], index: usize) -> Option<usize> {
    comment_end(bytes, index)
        .or_else(|| raw_string_end(bytes, index))
        .or_else(|| cooked_string_end(bytes, index))
        .or_else(|| char_literal_end(bytes, index))
}

fn comment_end(bytes: &[u8], index: usize) -> Option<usize> {
    if starts_with(bytes, index, b"//") {
        let mut cursor = index + 2;
        while cursor < bytes.len() && bytes[cursor] != b'\n' {
            cursor += 1;
        }
        if cursor < bytes.len() {
            cursor += 1;
        }
        return Some(cursor);
    }
    if !starts_with(bytes, index, b"/*") {
        return None;
    }
    let mut cursor = index + 2;
    let mut depth = 1i32;
    while cursor + 1 < bytes.len() && depth > 0 {
        if starts_with(bytes, cursor, b"/*") {
            depth += 1;
            cursor += 2;
        } else if starts_with(bytes, cursor, b"*/") {
            depth -= 1;
            cursor += 2;
        } else {
            cursor += 1;
        }
    }
    Some(cursor.min(bytes.len()))
}

fn raw_string_end(bytes: &[u8], index: usize) -> Option<usize> {
    let mut cursor = index;
    if matches!(bytes.get(cursor), Some(&b'b') | Some(&b'c')) {
        cursor += 1;
    }
    if bytes.get(cursor) != Some(&b'r') {
        return None;
    }
    cursor += 1;
    let mut hashes = 0usize;
    while bytes.get(cursor) == Some(&b'#') {
        hashes += 1;
        cursor += 1;
    }
    if bytes.get(cursor) != Some(&b'"') {
        return None;
    }
    cursor += 1;
    while cursor < bytes.len() {
        if bytes[cursor] == b'"' && has_hashes(bytes, cursor + 1, hashes) {
            return Some(cursor + 1 + hashes);
        }
        cursor += 1;
    }
    Some(bytes.len())
}

fn has_hashes(bytes: &[u8], index: usize, hashes: usize) -> bool {
    bytes
        .get(index..index + hashes)
        .is_some_and(|slice| slice.iter().all(|byte| *byte == b'#'))
}

fn cooked_string_end(bytes: &[u8], index: usize) -> Option<usize> {
    let mut cursor = index;
    if matches!(bytes.get(cursor), Some(&b'b') | Some(&b'c'))
        && bytes.get(cursor + 1) == Some(&b'"')
    {
        cursor += 1;
    }
    if bytes.get(cursor) != Some(&b'"') {
        return None;
    }
    cursor += 1;
    while cursor < bytes.len() {
        match bytes[cursor] {
            b'\\' => cursor += 2,
            b'"' => return Some(cursor + 1),
            _ => cursor += 1,
        }
    }
    Some(bytes.len())
}

fn char_literal_end(bytes: &[u8], index: usize) -> Option<usize> {
    let mut cursor = index;
    if bytes.get(cursor) == Some(&b'b') && bytes.get(cursor + 1) == Some(&b'\'') {
        cursor += 1;
    }
    if bytes.get(cursor) != Some(&b'\'') {
        return None;
    }
    cursor += 1;
    if bytes.get(cursor) == Some(&b'\\') {
        cursor += 1;
        if bytes.get(cursor) == Some(&b'u') && bytes.get(cursor + 1) == Some(&b'{') {
            cursor += 2;
            while cursor < bytes.len() && bytes[cursor] != b'}' {
                cursor += 1;
            }
            cursor += 1;
        } else if bytes.get(cursor) == Some(&b'x') {
            cursor += 3;
        } else {
            cursor += 1;
        }
    } else {
        let rest = bytes.get(cursor..)?;
        let ch = std::str::from_utf8(rest).ok()?.chars().next()?;
        if ch == '\'' || ch.is_ascii_whitespace() {
            return None;
        }
        cursor += ch.len_utf8();
        // `'ident` is a lifetime, not a character.
        if bytes.get(cursor) != Some(&b'\'') {
            return None;
        }
    }
    if bytes.get(cursor) == Some(&b'\'') {
        Some(cursor + 1)
    } else {
        None
    }
}
