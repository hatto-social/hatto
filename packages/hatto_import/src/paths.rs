// SPDX-FileCopyrightText: 2026 Hatto Social contributors
//
// SPDX-License-Identifier: AGPL-3.0-or-later

//! Folder grammar from the import contract §15.5.
//!
//! ```text
//! <data_dir>/import/
//!   raw/<import_batch_id>.apkg
//!   e/<import_batch_id>/collection.anki2
//!   e/<import_batch_id>/collection.media/
//!   staged/<import_batch_id>.apkg
//! ```
//!
//! `import_batch_id` is a lowercase RFC 4122 UUID version 4. It is not an
//! input to guid derivation. This module does not resolve symlinks.

use std::path::{Component, Path, PathBuf};

use uuid::Uuid;

use crate::error::ImportError;

const IMPORT_DIR: &str = "import";
const RAW_DIR: &str = "raw";
const E_DIR: &str = "e";
const STAGED_DIR: &str = "staged";
const COLLECTION_FILE: &str = "collection.anki2";
const MEDIA_DIR: &str = "collection.media";
const MEDIA_DB_FILE: &str = "collection.media.db";

/// Lowercase hyphenated UUID version 4, RFC 4122 variant.
pub fn is_import_batch_id(text: &str) -> bool {
    let Ok(id) = Uuid::parse_str(text) else {
        return false;
    };
    id.as_hyphenated().to_string() == text
        && id.get_variant() == uuid::Variant::RFC4122
        && id.get_version_num() == 4
}

pub fn raw_apkg_path(data_dir: &Path, batch_id: Uuid) -> Result<PathBuf, ImportError> {
    Ok(import_root(data_dir)?
        .join(RAW_DIR)
        .join(batch_file_name(batch_id)?))
}

pub fn staged_apkg_path(data_dir: &Path, batch_id: Uuid) -> Result<PathBuf, ImportError> {
    Ok(import_root(data_dir)?
        .join(STAGED_DIR)
        .join(batch_file_name(batch_id)?))
}

pub fn e_directory_path(data_dir: &Path, batch_id: Uuid) -> Result<PathBuf, ImportError> {
    Ok(import_root(data_dir)?
        .join(E_DIR)
        .join(batch_text(batch_id)?))
}

pub fn e_collection_path(data_dir: &Path, batch_id: Uuid) -> Result<PathBuf, ImportError> {
    Ok(e_directory_path(data_dir, batch_id)?.join(COLLECTION_FILE))
}

pub fn e_media_directory_path(data_dir: &Path, batch_id: Uuid) -> Result<PathBuf, ImportError> {
    Ok(e_directory_path(data_dir, batch_id)?.join(MEDIA_DIR))
}

pub fn e_media_db_path(data_dir: &Path, batch_id: Uuid) -> Result<PathBuf, ImportError> {
    Ok(e_directory_path(data_dir, batch_id)?.join(MEDIA_DB_FILE))
}

pub(crate) fn import_root(data_dir: &Path) -> Result<PathBuf, ImportError> {
    check_data_dir(data_dir)?;
    Ok(data_dir.join(IMPORT_DIR))
}

pub(crate) fn check_data_dir(data_dir: &Path) -> Result<(), ImportError> {
    if !data_dir.is_absolute() {
        return Err(ImportError::new("data_dir is not absolute"));
    }
    if data_dir
        .components()
        .any(|component| matches!(component, Component::ParentDir | Component::CurDir))
    {
        return Err(ImportError::new("data_dir contains '.' or '..'"));
    }
    Ok(())
}

pub(crate) fn batch_text(batch_id: Uuid) -> Result<String, ImportError> {
    let text = batch_id.as_hyphenated().to_string();
    if !is_import_batch_id(&text) {
        return Err(ImportError::new(
            "import_batch_id is not a lowercase UUID version 4",
        ));
    }
    Ok(text)
}

fn batch_file_name(batch_id: Uuid) -> Result<String, ImportError> {
    Ok(format!("{}.apkg", batch_text(batch_id)?))
}

/// A direct child of `import/raw` or `import/staged` that is `<uuid-v4>.apkg`.
pub(crate) fn batch_id_from_apkg_name(file_name: &str) -> Option<Uuid> {
    let stem = file_name.strip_suffix(".apkg")?;
    if file_name.len() != stem.len() + ".apkg".len() {
        return None;
    }
    if !is_import_batch_id(stem) {
        return None;
    }
    Uuid::parse_str(stem).ok()
}

/// A direct child of `import/e` whose name is a lowercase UUID version 4.
pub(crate) fn batch_id_from_e_dir_name(file_name: &str) -> Option<Uuid> {
    if !is_import_batch_id(file_name) {
        return None;
    }
    Uuid::parse_str(file_name).ok()
}

pub(crate) fn raw_dir(data_dir: &Path) -> Result<PathBuf, ImportError> {
    Ok(import_root(data_dir)?.join(RAW_DIR))
}

pub(crate) fn e_dir(data_dir: &Path) -> Result<PathBuf, ImportError> {
    Ok(import_root(data_dir)?.join(E_DIR))
}

pub(crate) fn staged_dir(data_dir: &Path) -> Result<PathBuf, ImportError> {
    Ok(import_root(data_dir)?.join(STAGED_DIR))
}
