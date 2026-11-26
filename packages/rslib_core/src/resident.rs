// SPDX-FileCopyrightText: 2026 Hatto Social contributors
//
// SPDX-License-Identifier: AGPL-3.0-or-later

//! Read resident note rows for import classification.
//!
//! The desktop allowlist has no guid lookup and does not forward
//! `run_db_command`. This read uses `dispatch`, the same internal channel as
//! the FSRS bootstrap, and only this fixed `SELECT`. It does not write.

use anki_proto::generic;
use prost::Message;

use crate::api::{dispatch_message, AnkiBackend};

/// One `notes` row. `flds` is still the stored `0x1f`-joined text.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ResidentNoteRow {
    pub guid: String,
    pub notetype_id: i64,
    pub mod_secs: i64,
    pub flds: String,
    pub tags: String,
}

const SELECT_PREFIX: &str = "SELECT guid, mid, \"mod\", flds, tags FROM notes WHERE guid IN (";
const SELECT_SUFFIX: &str = ") ORDER BY id";
const CHUNK: usize = 400;

/// Notes whose guid is in `guids`. Absent guids are omitted.
///
/// An import-E backend is rejected. Placeholders are bound; guid text is not
/// concatenated into the statement.
pub fn read_resident_notes(
    backend: &AnkiBackend,
    guids: &[String],
) -> Result<Vec<ResidentNoteRow>, String> {
    if backend.is_import_e() {
        return Err("resident lookup does not read an import E collection".into());
    }
    let mut rows = Vec::new();
    for chunk in guids.chunks(CHUNK) {
        if chunk.is_empty() {
            continue;
        }
        let mut sql = String::from(SELECT_PREFIX);
        for index in 0..chunk.len() {
            if index > 0 {
                sql.push_str(", ");
            }
            sql.push('?');
        }
        sql.push_str(SELECT_SUFFIX);
        let args: Vec<serde_json::Value> = chunk
            .iter()
            .cloned()
            .map(serde_json::Value::String)
            .collect();
        let body = serde_json::json!({
            "kind": "query",
            "sql": sql,
            "args": args,
            "first_row_only": false,
        });
        let encoded = serde_json::to_vec(&body).map_err(|err| format!("resident notes: {err}"))?;
        let bytes = dispatch_message(
            backend,
            "BackendAnkidroidService",
            "run_db_command",
            &generic::Json { json: encoded },
        )?;
        let decoded = generic::Json::decode(bytes.as_slice())
            .map_err(|err| format!("resident notes: {err}"))?;
        if decoded.json.is_empty() {
            continue;
        }
        let value: serde_json::Value = serde_json::from_slice(&decoded.json)
            .map_err(|err| format!("resident notes: {err}"))?;
        let Some(array) = value.as_array() else {
            return Err("resident notes are not rows".into());
        };
        for row in array {
            let cells = row
                .as_array()
                .ok_or_else(|| "resident note row is not an array".to_string())?;
            if cells.len() != 5 {
                return Err("resident note row has the wrong width".into());
            }
            rows.push(ResidentNoteRow {
                guid: cell_string(&cells[0], "guid")?,
                notetype_id: cell_i64(&cells[1], "mid")?,
                mod_secs: cell_i64(&cells[2], "mod")?,
                flds: cell_string(&cells[3], "flds")?,
                tags: cell_string(&cells[4], "tags")?,
            });
        }
    }
    Ok(rows)
}

fn cell_i64(value: &serde_json::Value, label: &str) -> Result<i64, String> {
    value
        .as_i64()
        .or_else(|| value.as_u64().and_then(|number| i64::try_from(number).ok()))
        .ok_or_else(|| format!("resident note {label} is not an integer"))
}

fn cell_string(value: &serde_json::Value, label: &str) -> Result<String, String> {
    value
        .as_str()
        .map(str::to_string)
        .ok_or_else(|| format!("resident note {label} is not a string"))
}
