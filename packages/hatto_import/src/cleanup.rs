// SPDX-FileCopyrightText: 2026 Hatto Social contributors
//
// SPDX-License-Identifier: AGPL-3.0-or-later

//! Folder-side cleanup from the import contract §15.5.
//!
//! Intent rows live in the side database (I4). This module only receives the
//! intent state and deletes `raw`, `e`, and `staged` for a batch. A name that
//! is not the §15.5 grammar is left in place.

use std::collections::{BTreeMap, BTreeSet};
use std::fs;
use std::path::Path;

use uuid::Uuid;

use crate::error::ImportError;
use crate::paths::{
    batch_id_from_apkg_name, batch_id_from_e_dir_name, check_data_dir, e_dir, e_directory_path,
    raw_apkg_path, raw_dir, staged_apkg_path, staged_dir,
};

/// What the caller knows about one batch's intent row.
///
/// `None` from the scan callback means there is no intent row.
/// With the v1 side DB, a present row means `Prepared` (`NotPrepared` is not used by Dart).
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum BatchIntent {
    /// Side-database row is still `prepared`. The files stay.
    Prepared,
    /// The row exists and is not `prepared` (done or failed).
    NotPrepared,
}

/// What one scan did to `import/{raw,e,staged}`.
#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct ImportScan {
    pub removed: Vec<Uuid>,
    pub kept_prepared: Vec<Uuid>,
    /// Names that are not the batch grammar, relative to `import/`.
    pub ignored: Vec<String>,
}

/// Delete `raw`, `e`, and `staged` for one batch. Missing paths are not an error.
pub fn remove_import_batch(data_dir: &Path, batch_id: Uuid) -> Result<(), ImportError> {
    check_data_dir(data_dir)?;
    remove_path(&raw_apkg_path(data_dir, batch_id)?)?;
    remove_path(&staged_apkg_path(data_dir, batch_id)?)?;
    remove_path(&e_directory_path(data_dir, batch_id)?)?;
    Ok(())
}

/// [`scan_import_folders`] with the batches whose intent row is still prepared.
///
/// Any other recognized batch is deleted. A string that is not a lowercase
/// uuid v4 is an error. This is the form the bridge exposes, because the
/// scan does not take a callback.
pub fn scan_prepared_batches(
    data_dir: &Path,
    prepared_batch_ids: &[String],
) -> Result<ImportScan, ImportError> {
    let mut prepared = BTreeSet::new();
    for text in prepared_batch_ids {
        if !crate::paths::is_import_batch_id(text) {
            return Err(ImportError::new(
                "prepared batch id is not a lowercase uuid v4",
            ));
        }
        let id = Uuid::parse_str(text)
            .map_err(|_| ImportError::new("prepared batch id is not a uuid"))?;
        prepared.insert(id);
    }
    scan_import_folders(data_dir, |batch_id| {
        prepared
            .contains(&batch_id)
            .then_some(BatchIntent::Prepared)
    })
}

/// Startup scan. `intent` is called once per recognized batch id.
///
/// A missing intent and [`BatchIntent::NotPrepared`] delete that batch's
/// three paths. [`BatchIntent::Prepared`] is left for I4. Children whose
/// names are not the grammar are listed in [`ImportScan::ignored`] and are
/// not deleted. A missing `import/` directory is an empty scan.
pub fn scan_import_folders(
    data_dir: &Path,
    mut intent: impl FnMut(Uuid) -> Option<BatchIntent>,
) -> Result<ImportScan, ImportError> {
    check_data_dir(data_dir)?;
    if !data_dir.is_dir() {
        return Err(ImportError::new("data_dir is not a directory"));
    }

    let mut found: BTreeMap<Uuid, ()> = BTreeMap::new();
    let mut ignored = Vec::new();
    collect_apkg_dir(&raw_dir(data_dir)?, "raw", &mut found, &mut ignored)?;
    collect_e_dir(&e_dir(data_dir)?, &mut found, &mut ignored)?;
    collect_apkg_dir(&staged_dir(data_dir)?, "staged", &mut found, &mut ignored)?;
    ignored.sort();

    let mut removed = Vec::new();
    let mut kept_prepared = Vec::new();
    for batch_id in found.into_keys() {
        match intent(batch_id) {
            Some(BatchIntent::Prepared) => kept_prepared.push(batch_id),
            Some(BatchIntent::NotPrepared) | None => {
                remove_import_batch(data_dir, batch_id)?;
                removed.push(batch_id);
            }
        }
    }
    Ok(ImportScan {
        removed,
        kept_prepared,
        ignored,
    })
}

fn collect_apkg_dir(
    dir: &Path,
    label: &str,
    found: &mut BTreeMap<Uuid, ()>,
    ignored: &mut Vec<String>,
) -> Result<(), ImportError> {
    let Some(entries) = read_children(dir)? else {
        return Ok(());
    };
    for name in entries {
        match batch_id_from_apkg_name(&name) {
            Some(batch_id) => {
                found.insert(batch_id, ());
            }
            None => ignored.push(format!("{label}/{name}")),
        }
    }
    Ok(())
}

fn collect_e_dir(
    dir: &Path,
    found: &mut BTreeMap<Uuid, ()>,
    ignored: &mut Vec<String>,
) -> Result<(), ImportError> {
    let Some(entries) = read_children(dir)? else {
        return Ok(());
    };
    for name in entries {
        match batch_id_from_e_dir_name(&name) {
            Some(batch_id) if dir.join(&name).is_dir() => {
                found.insert(batch_id, ());
            }
            Some(_) | None => ignored.push(format!("e/{name}")),
        }
    }
    Ok(())
}

fn read_children(dir: &Path) -> Result<Option<Vec<String>>, ImportError> {
    if !dir.exists() {
        return Ok(None);
    }
    if !dir.is_dir() {
        return Err(ImportError::new(format!(
            "{} is not a directory",
            dir.display()
        )));
    }
    let mut names = Vec::new();
    let entries =
        fs::read_dir(dir).map_err(|err| ImportError::new(format!("{}: {err}", dir.display())))?;
    for entry in entries {
        let entry = entry.map_err(|err| ImportError::new(err.to_string()))?;
        let name = entry.file_name();
        // §15.5 item 3: a name outside the grammar is ignored. Non-UTF-8
        // cannot be a batch id, so the scan skips it instead of failing.
        let Some(name) = name.to_str() else {
            continue;
        };
        names.push(name.to_string());
    }
    Ok(Some(names))
}

fn remove_path(path: &Path) -> Result<(), ImportError> {
    // `exists` follows links and is false for a dangling symlink, so it would
    // leave the link in place. `symlink_metadata` sees the link itself.
    let meta = match fs::symlink_metadata(path) {
        Ok(meta) => meta,
        Err(err) if err.kind() == std::io::ErrorKind::NotFound => return Ok(()),
        Err(err) => return Err(ImportError::new(format!("{}: {err}", path.display()))),
    };
    // Never follow a symlink. `remove_dir_all` can remove the target; remove
    // the link itself.
    if meta.file_type().is_symlink() {
        fs::remove_file(path)
            .map_err(|err| ImportError::new(format!("{}: {err}", path.display())))?;
        return Ok(());
    }
    if meta.is_dir() {
        fs::remove_dir_all(path)
            .map_err(|err| ImportError::new(format!("{}: {err}", path.display())))?;
    } else {
        fs::remove_file(path)
            .map_err(|err| ImportError::new(format!("{}: {err}", path.display())))?;
    }
    Ok(())
}
