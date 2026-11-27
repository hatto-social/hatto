// SPDX-FileCopyrightText: 2026 Hatto Social contributors
//
// SPDX-License-Identifier: AGPL-3.0-or-later

//! Q-J5 and O4. Prefixes are the contract Dart matches.

#![cfg(test)]

use std::fs;
use std::io::Write;
use std::path::Path;

use crate::pipeline::{clear_after_raw_copy_hook, set_after_raw_copy_hook, validate_source};
use crate::stage_import;
use crate::ImportLimits;
use crate::FORMAT_ERROR_PREFIX;
use crate::TOO_LARGE_COMPRESSED_PREFIX;
use crate::TOO_LARGE_UNCOMPRESSED_PREFIX;

#[test]
fn error_prefixes_are_the_stable_codes() {
    assert_eq!(FORMAT_ERROR_PREFIX, "format:");
    assert_eq!(TOO_LARGE_COMPRESSED_PREFIX, "too_large:compressed");
    assert_eq!(TOO_LARGE_UNCOMPRESSED_PREFIX, "too_large:uncompressed");
}

#[test]
fn apkg_extension_is_ascii_case_insensitive() {
    let root = tempfile::TempDir::new().unwrap();
    let limits = generous();
    for name in ["Deck.apkg", "Deck.APKG", "Deck.Apkg"] {
        let path = root.path().join(name);
        write_stored_zip(&path, &[4]);
        validate_source(&path, limits).unwrap();
    }
}

#[test]
fn non_apkg_and_non_zip_are_format_errors() {
    let root = tempfile::TempDir::new().unwrap();
    let limits = generous();

    let text = root.path().join("notes.txt");
    fs::write(&text, b"PK\x03\x04not-an-apkg-name").unwrap();
    let err = validate_source(&text, limits).unwrap_err();
    assert!(err.to_string().starts_with(FORMAT_ERROR_PREFIX), "{err}");
    assert!(err.to_string().contains(".apkg"), "{err}");

    let bad = root.path().join("bad.apkg");
    fs::write(&bad, b"not a zip file at all").unwrap();
    let err = validate_source(&bad, limits).unwrap_err();
    assert!(err.to_string().starts_with(FORMAT_ERROR_PREFIX), "{err}");
    assert!(err.to_string().contains("zip"), "{err}");

    let short = root.path().join("short.apkg");
    fs::write(&short, b"PK").unwrap();
    let err = validate_source(&short, limits).unwrap_err();
    assert!(err.to_string().starts_with(FORMAT_ERROR_PREFIX), "{err}");

    let corrupt = root.path().join("corrupt.apkg");
    let mut bytes = b"PK\x03\x04".to_vec();
    bytes.extend(std::iter::repeat_n(0, 32));
    fs::write(&corrupt, &bytes).unwrap();
    let err = validate_source(&corrupt, limits).unwrap_err();
    assert!(err.to_string().starts_with(FORMAT_ERROR_PREFIX), "{err}");
    assert!(err.to_string().contains("zip"), "{err}");
}

#[test]
fn compressed_size_over_the_limit_is_too_large_compressed() {
    let root = tempfile::TempDir::new().unwrap();
    let data = root.path().join("data");
    fs::create_dir_all(&data).unwrap();
    let source = root.path().join("big.apkg");
    write_stored_zip(&source, &[32]);
    let limits = ImportLimits {
        max_bytes: 8,
        max_uncompressed_bytes: u64::MAX,
    };
    let err = stage_err(&data, &source, limits);
    assert!(
        err.to_string().starts_with(TOO_LARGE_COMPRESSED_PREFIX),
        "{err}"
    );
    assert!(err.to_string().contains("max_bytes"), "{err}");
    assert!(!data.join("import").exists());
}

#[test]
fn uncompressed_sum_over_the_limit_leaves_no_batch() {
    let root = tempfile::TempDir::new().unwrap();
    let data = root.path().join("data");
    fs::create_dir_all(&data).unwrap();
    let source = root.path().join("wide.apkg");
    // Two entries, so the check is a sum and not the first size alone.
    write_stored_zip(&source, &[40, 40]);
    let limits = ImportLimits {
        max_bytes: 1_000_000,
        max_uncompressed_bytes: 50,
    };
    let err = stage_err(&data, &source, limits);
    assert!(
        err.to_string().starts_with(TOO_LARGE_UNCOMPRESSED_PREFIX),
        "{err}"
    );
    assert!(err.to_string().contains("max_uncompressed_bytes"), "{err}");
    assert!(!data.join("import").exists());

    let one = root.path().join("one.apkg");
    write_stored_zip(&one, &[40]);
    validate_source(&one, limits).unwrap();
}

#[test]
fn uncompressed_limit_is_enforced_on_the_raw_copy() {
    let root = tempfile::TempDir::new().unwrap();
    let data = root.path().join("data");
    fs::create_dir_all(&data).unwrap();
    let source = root.path().join("ok.apkg");
    write_stored_zip(&source, &[8]);
    let swapped = root.path().join("swapped.apkg");
    write_stored_zip(&swapped, &[200]);
    let limits = ImportLimits {
        max_bytes: 1_000_000,
        max_uncompressed_bytes: 64,
    };
    let _clear = ClearHook;
    set_after_raw_copy_hook(Box::new(move |raw| {
        fs::copy(&swapped, raw).unwrap();
    }));
    let err = stage_err(&data, &source, limits);
    assert!(
        err.to_string().starts_with(TOO_LARGE_UNCOMPRESSED_PREFIX),
        "{err}"
    );
    // The source passed, so the import directories exist. The batch does not.
    assert!(data.join("import").is_dir());
    assert_no_batch_entries(&data);
}

#[test]
fn unsupported_compression_still_checks_the_uncompressed_sum() {
    let root = tempfile::TempDir::new().unwrap();
    // Method 12 is bzip2. This crate does not enable that decompressor, so
    // `by_index` fails before it can read the central-directory size.
    let path = root.path().join("bzip2.apkg");
    fs::write(&path, zip_with_method(12, 80)).unwrap();
    let over = ImportLimits {
        max_bytes: 1_000_000,
        max_uncompressed_bytes: 10,
    };
    let err = validate_source(&path, over).unwrap_err();
    assert!(
        err.to_string().starts_with(TOO_LARGE_UNCOMPRESSED_PREFIX),
        "{err}"
    );
    assert!(err.to_string().contains("max_uncompressed_bytes"), "{err}");
    assert!(!err.to_string().contains("Compression method"), "{err}");

    let under = ImportLimits {
        max_bytes: 1_000_000,
        max_uncompressed_bytes: 80,
    };
    validate_source(&path, under).unwrap();
}

#[test]
fn uncompressed_size_sum_overflow_is_too_large_uncompressed() {
    let root = tempfile::TempDir::new().unwrap();
    let path = root.path().join("overflow.apkg");
    fs::write(&path, zip_with_declared_sizes(&[u64::MAX, 1])).unwrap();
    let err = validate_source(&path, generous()).unwrap_err();
    assert!(
        err.to_string().starts_with(TOO_LARGE_UNCOMPRESSED_PREFIX),
        "{err}"
    );
    assert!(err.to_string().contains("overflows u64"), "{err}");
}

fn stage_err(data: &Path, source: &Path, limits: ImportLimits) -> crate::ImportError {
    match stage_import(data, source, limits) {
        Ok(_output) => panic!("stage_import succeeded"),
        Err(err) => err,
    }
}

fn generous() -> ImportLimits {
    ImportLimits {
        max_bytes: 1_000_000,
        max_uncompressed_bytes: u64::MAX,
    }
}

fn write_stored_zip(path: &Path, lengths: &[usize]) {
    let file = fs::File::create(path).unwrap();
    let mut writer = zip::ZipWriter::new(file);
    let options =
        zip::write::SimpleFileOptions::default().compression_method(zip::CompressionMethod::Stored);
    for (index, len) in lengths.iter().enumerate() {
        writer.start_file(format!("f{index}"), options).unwrap();
        writer.write_all(&vec![0u8; *len]).unwrap();
    }
    writer.finish().unwrap();
}

fn assert_no_batch_entries(data: &Path) {
    for folder in ["raw", "e", "staged"] {
        let dir = data.join("import").join(folder);
        if !dir.exists() {
            continue;
        }
        let entries: Vec<_> = fs::read_dir(&dir)
            .unwrap()
            .map(|entry| entry.unwrap().file_name())
            .collect();
        assert!(entries.is_empty(), "import/{folder} leftover {entries:?}");
    }
}

struct ClearHook;

impl Drop for ClearHook {
    fn drop(&mut self) {
        clear_after_raw_copy_hook();
    }
}

fn push_u16(buf: &mut Vec<u8>, value: u16) {
    buf.extend_from_slice(&value.to_le_bytes());
}

fn push_u32(buf: &mut Vec<u8>, value: u32) {
    buf.extend_from_slice(&value.to_le_bytes());
}

fn push_u64(buf: &mut Vec<u8>, value: u64) {
    buf.extend_from_slice(&value.to_le_bytes());
}

/// One entry stored with [`method`] and a declared uncompressed size.
///
/// The payload is not valid compressed data. Callers that only read the
/// central-directory size must not try to decompress it.
fn zip_with_method(method: u16, uncompressed: u32) -> Vec<u8> {
    let name = b"e0";
    let payload = [0u8; 4];
    let mut local = Vec::new();
    push_u32(&mut local, 0x0403_4b50);
    push_u16(&mut local, 20);
    push_u16(&mut local, 0);
    push_u16(&mut local, method);
    push_u16(&mut local, 0);
    push_u16(&mut local, 0);
    push_u32(&mut local, 0);
    push_u32(&mut local, payload.len() as u32);
    push_u32(&mut local, uncompressed);
    push_u16(&mut local, name.len() as u16);
    push_u16(&mut local, 0);
    local.extend_from_slice(name);
    local.extend_from_slice(&payload);

    let mut central = Vec::new();
    push_u32(&mut central, 0x0201_4b50);
    push_u16(&mut central, 20);
    push_u16(&mut central, 20);
    push_u16(&mut central, 0);
    push_u16(&mut central, method);
    push_u16(&mut central, 0);
    push_u16(&mut central, 0);
    push_u32(&mut central, 0);
    push_u32(&mut central, payload.len() as u32);
    push_u32(&mut central, uncompressed);
    push_u16(&mut central, name.len() as u16);
    push_u16(&mut central, 0);
    push_u16(&mut central, 0);
    push_u16(&mut central, 0);
    push_u16(&mut central, 0);
    push_u32(&mut central, 0);
    push_u32(&mut central, 0);
    central.extend_from_slice(name);

    let cd_offset = local.len() as u32;
    let cd_size = central.len() as u32;
    let mut out = local;
    out.extend_from_slice(&central);
    push_u32(&mut out, 0x0605_4b50);
    push_u16(&mut out, 0);
    push_u16(&mut out, 0);
    push_u16(&mut out, 1);
    push_u16(&mut out, 1);
    push_u32(&mut out, cd_size);
    push_u32(&mut out, cd_offset);
    push_u16(&mut out, 0);
    out
}

/// Two stored entries whose central-directory uncompressed sizes are
/// [`sizes`]. Compressed size is zero, so the file stays small.
fn zip_with_declared_sizes(sizes: &[u64]) -> Vec<u8> {
    let mut locals = Vec::new();
    let mut central = Vec::new();
    for (index, uncompressed) in sizes.iter().copied().enumerate() {
        let name = format!("e{index}");
        let name = name.as_bytes();
        let mut extra = Vec::new();
        push_u16(&mut extra, 0x0001);
        push_u16(&mut extra, 16);
        push_u64(&mut extra, uncompressed);
        push_u64(&mut extra, 0);
        let local_start = locals.len() as u32;
        push_u32(&mut locals, 0x0403_4b50);
        push_u16(&mut locals, 45);
        push_u16(&mut locals, 0);
        push_u16(&mut locals, 0);
        push_u16(&mut locals, 0);
        push_u16(&mut locals, 0);
        push_u32(&mut locals, 0);
        push_u32(&mut locals, 0xFFFF_FFFF);
        push_u32(&mut locals, 0xFFFF_FFFF);
        push_u16(&mut locals, name.len() as u16);
        push_u16(&mut locals, extra.len() as u16);
        locals.extend_from_slice(name);
        locals.extend_from_slice(&extra);

        push_u32(&mut central, 0x0201_4b50);
        push_u16(&mut central, 45);
        push_u16(&mut central, 45);
        push_u16(&mut central, 0);
        push_u16(&mut central, 0);
        push_u16(&mut central, 0);
        push_u16(&mut central, 0);
        push_u32(&mut central, 0);
        push_u32(&mut central, 0xFFFF_FFFF);
        push_u32(&mut central, 0xFFFF_FFFF);
        push_u16(&mut central, name.len() as u16);
        push_u16(&mut central, extra.len() as u16);
        push_u16(&mut central, 0);
        push_u16(&mut central, 0);
        push_u16(&mut central, 0);
        push_u32(&mut central, 0);
        push_u32(&mut central, local_start);
        central.extend_from_slice(name);
        central.extend_from_slice(&extra);
    }
    let cd_offset = locals.len() as u32;
    let cd_size = central.len() as u32;
    let mut out = locals;
    let count = u16::try_from(sizes.len()).unwrap();
    out.extend_from_slice(&central);
    push_u32(&mut out, 0x0605_4b50);
    push_u16(&mut out, 0);
    push_u16(&mut out, 0);
    push_u16(&mut out, count);
    push_u16(&mut out, count);
    push_u32(&mut out, cd_size);
    push_u32(&mut out, cd_offset);
    push_u16(&mut out, 0);
    out
}
