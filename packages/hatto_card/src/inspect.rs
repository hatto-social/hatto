// SPDX-FileCopyrightText: 2026 Hatto Social contributors
//
// SPDX-License-Identifier: AGPL-3.0-or-later

//! Read one `.apkg` through Stage E and print its file-note facts.
//!
//! The source file is only read. Stage E copies it under a temporary data
//! directory. This module does not call `resident_lookup` or
//! `import_stage_finish`, and it does not open a user collection.

use std::fs;
use std::path::{Path, PathBuf};

use rslib_bridge::api::{import_stage_e, NoteFacts, PendingImport};
use serde_json::{json, Value};

use crate::ToolFailure;

/// Compressed `.apkg` ceiling for [`inspect_path`].
///
/// v0 desktop product limit: 512 MiB.
pub const INSPECT_MAX_BYTES: u64 = 512 * 1024 * 1024;

/// Sum of zip-entry uncompressed sizes for [`inspect_path`].
///
/// v0 desktop product limit: 2 GiB. An inner zstd frame is not part of this
/// sum; Stage E counts the outer zip only.
pub const INSPECT_MAX_UNCOMPRESSED_BYTES: u64 = 2 * 1024 * 1024 * 1024;

/// Prefix of the temporary data directory [`inspect_path`] creates.
pub const INSPECT_TEMP_PREFIX: &str = "hatto-card-inspect-";

/// Stage `apkg` and return its file notes.
///
/// `guid` is the normalized import guid. `content_hash` is lowercase hex.
/// `notetype_id` and `mod` are the Stage E facts. Notes stay in the note-id
/// order [`PendingImport::file_notes`] returns.
///
/// The temporary data directory is removed before this returns, on success
/// and on error. [`PendingImport`] is dropped first so the E collection is
/// closed before the directory goes away.
pub fn inspect_path(apkg: &Path) -> Result<Value, ToolFailure> {
    // Declared first so it drops last: after `PendingImport`, and after the
    // process temp dir is pointed back at whatever it was.
    let data_dir = tempfile::Builder::new()
        .prefix(INSPECT_TEMP_PREFIX)
        .tempdir()
        .map_err(|err| ToolFailure::message(format!("temp dir: {err}")))?;
    let saved_tmp = TmpEnv::capture();
    let scratch = data_dir.path().join("tmp");
    fs::create_dir_all(&scratch).map_err(|err| ToolFailure::message(format!("temp dir: {err}")))?;
    // Stage E and rslib ask `temp_dir()` for scratch files. Keep those inside
    // this data directory so removing it leaves nothing behind.
    rslib_bridge::api::prepare_runtime(path_string(&scratch, "temp dir")?);
    let value = inspect_staged(data_dir.path(), apkg)?;
    drop(saved_tmp);
    drop(data_dir);
    Ok(value)
}

fn inspect_staged(data_dir: &Path, apkg: &Path) -> Result<Value, ToolFailure> {
    let pending = open_stage_e(data_dir, apkg)?;
    let value = notes_json(&pending.file_notes());
    // Close E and delete the batch folder before the caller removes data_dir.
    drop(pending);
    Ok(value)
}

fn open_stage_e(data_dir: &Path, apkg: &Path) -> Result<PendingImport, ToolFailure> {
    let data_dir = absolute_data_dir(data_dir)?;
    import_stage_e(
        path_string(&data_dir, "temp dir")?,
        path_string(apkg, "apkg")?,
        INSPECT_MAX_BYTES,
        INSPECT_MAX_UNCOMPRESSED_BYTES,
    )
    .map_err(ToolFailure::message)
}

fn absolute_data_dir(data_dir: &Path) -> Result<PathBuf, ToolFailure> {
    // Canonicalize drops `.` and `..`, which Stage E rejects, and yields the
    // absolute path `import_stage_e` requires.
    data_dir
        .canonicalize()
        .map_err(|err| ToolFailure::message(format!("temp dir: {err}")))
}

fn path_string(path: &Path, label: &str) -> Result<String, ToolFailure> {
    path.to_str()
        .map(str::to_string)
        .ok_or_else(|| ToolFailure::message(format!("{label} path is not utf-8")))
}

fn notes_json(notes: &[NoteFacts]) -> Value {
    let notes: Vec<Value> = notes
        .iter()
        .map(|note| {
            json!({
                "guid": note.guid,
                "content_hash": hex_encode(&note.content_hash),
                "notetype_id": note.notetype_id,
                "mod": note.r#mod,
            })
        })
        .collect();
    json!({
        "ok": true,
        "notes": notes,
    })
}

fn hex_encode(bytes: &[u8]) -> String {
    const HEX: &[u8; 16] = b"0123456789abcdef";
    let mut out = String::with_capacity(bytes.len() * 2);
    for byte in bytes {
        out.push(HEX[(byte >> 4) as usize] as char);
        out.push(HEX[(byte & 0x0f) as usize] as char);
    }
    out
}

/// Previous `TMPDIR` / `TMP` / `TEMP`. Restored when dropped so a caller that
/// keeps running does not point temp files at a directory we are about to
/// delete.
struct TmpEnv {
    saved: [(&'static str, Option<String>); 3],
}

impl TmpEnv {
    fn capture() -> Self {
        Self {
            saved: ["TMPDIR", "TMP", "TEMP"].map(|key| (key, std::env::var(key).ok())),
        }
    }
}

impl Drop for TmpEnv {
    fn drop(&mut self) {
        for (key, value) in &self.saved {
            // SAFETY: the environment is process-global. `inspect_path` is the
            // only caller, it runs on the CLI thread, and it drops this value
            // before it removes the temporary data directory.
            match value {
                Some(value) => unsafe { std::env::set_var(key, value) },
                None => unsafe { std::env::remove_var(key) },
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn limits_are_the_v0_desktop_product_ceilings() {
        assert_eq!(INSPECT_MAX_BYTES, 512 * 1024 * 1024);
        assert_eq!(INSPECT_MAX_UNCOMPRESSED_BYTES, 2 * 1024 * 1024 * 1024);
        assert!(INSPECT_TEMP_PREFIX.starts_with("hatto-card-inspect-"));
    }
}
