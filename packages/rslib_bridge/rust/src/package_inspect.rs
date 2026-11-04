//! Read deck configs out of an exported `.apkg` without calling rslib.
//!
//! rslib itself is only reached through `Backend::run_service_method` (the
//! export that produces the package). The package is then ordinary bytes:
//! `collection.anki21b` is a zstd frame around a SQLite file, and the
//! `deck_config.config` column is a `anki.deck_config.DeckConfig.Config`
//! protobuf, not JSON.

use std::io::Read;
use std::path::Path;

use anki_proto::deck_config::deck_config::Config as DeckConfigInner;
use prost::Message;
use rusqlite::Connection;

use crate::api::call;
use crate::api::open_backend;
use crate::api::prepare_runtime;
use crate::api::DeckConfigRow;

const ZSTD_MAGIC: [u8; 4] = [0x28, 0xB5, 0x2F, 0xFD];
const SQLITE_MAGIC: &[u8] = b"SQLite format 3\0";

/// Open `dir` as a collection, export a non-legacy apkg through the protobuf
/// channel, then prost-decode every `deck_config.config` blob inside it.
pub fn inspect_exported_deck_configs(dir: String) -> Result<Vec<DeckConfigRow>, String> {
    let root = Path::new(&dir);
    std::fs::create_dir_all(root).map_err(|err| err.to_string())?;
    let tmp = root.join("tmp");
    std::fs::create_dir_all(&tmp).map_err(|err| err.to_string())?;
    prepare_runtime(tmp.to_string_lossy().into_owned());

    let media = root.join("collection.media");
    std::fs::create_dir_all(&media).map_err(|err| err.to_string())?;
    let collection = root.join("collection.anki2");
    let media_db = root.join("collection.media.db");
    let apkg = root.join("export.apkg");

    let init = anki_proto::backend::BackendInit {
        preferred_langs: vec!["en".into()],
        locale_folder_path: String::new(),
        server: false,
    };
    let backend = open_backend(init.encode_to_vec())?;

    let open = anki_proto::collection::OpenCollectionRequest {
        collection_path: collection.to_string_lossy().into_owned(),
        media_folder_path: media.to_string_lossy().into_owned(),
        media_db_path: media_db.to_string_lossy().into_owned(),
    };
    call(
        &backend,
        "BackendCollectionService",
        "open_collection",
        &open,
    )?;

    let export = anki_proto::import_export::ExportAnkiPackageRequest {
        out_path: apkg.to_string_lossy().into_owned(),
        options: Some(anki_proto::import_export::ExportAnkiPackageOptions {
            with_scheduling: false,
            with_deck_configs: true,
            with_media: false,
            legacy: false,
        }),
        // `None` is the whole collection. Set it explicitly so the request
        // does not depend on that default.
        limit: Some(anki_proto::import_export::ExportLimit {
            limit: Some(
                anki_proto::import_export::export_limit::Limit::WholeCollection(
                    anki_proto::generic::Empty {},
                ),
            ),
        }),
    };
    let exported = call(
        &backend,
        "BackendImportExportService",
        "export_anki_package",
        &export,
    )?;
    let _count = anki_proto::generic::UInt32::decode(exported.as_slice())
        .map_err(|err| format!("export response: {err}"))?;

    let close = anki_proto::collection::CloseCollectionRequest {
        downgrade_to_schema11: false,
    };
    call(
        &backend,
        "BackendCollectionService",
        "close_collection",
        &close,
    )?;
    drop(backend);

    let sqlite = decompress_anki21b(&apkg)?;
    let sqlite_path = tmp.join("collection.anki21b.sqlite");
    deck_configs_from_sqlite(&sqlite, &sqlite_path)
}

fn decompress_anki21b(apkg: &Path) -> Result<Vec<u8>, String> {
    let file = std::fs::File::open(apkg).map_err(|err| err.to_string())?;
    let mut archive = zip::ZipArchive::new(file).map_err(|err| err.to_string())?;
    let mut entry = archive
        .by_name("collection.anki21b")
        .map_err(|err| format!("collection.anki21b: {err}"))?;
    let mut compressed = Vec::new();
    entry
        .read_to_end(&mut compressed)
        .map_err(|err| err.to_string())?;
    if !compressed.starts_with(&ZSTD_MAGIC) {
        return Err(
            "collection.anki21b is not a zstd frame (expected magic 28 b5 2f fd)".into(),
        );
    }
    let sqlite = zstd::decode_all(compressed.as_slice()).map_err(|err| err.to_string())?;
    if !sqlite.starts_with(SQLITE_MAGIC) {
        return Err("decompressed collection.anki21b is not a SQLite database".into());
    }
    Ok(sqlite)
}

fn deck_configs_from_sqlite(sqlite: &[u8], sqlite_path: &Path) -> Result<Vec<DeckConfigRow>, String> {
    if let Some(parent) = sqlite_path.parent() {
        std::fs::create_dir_all(parent).map_err(|err| err.to_string())?;
    }
    std::fs::write(sqlite_path, sqlite).map_err(|err| err.to_string())?;
    let conn = Connection::open(sqlite_path).map_err(|err| err.to_string())?;
    let mut stmt = conn
        .prepare("SELECT id, name, config FROM deck_config ORDER BY id")
        .map_err(|err| err.to_string())?;
    let rows = stmt
        .query_map([], |row| {
            Ok((
                row.get::<_, i64>(0)?,
                row.get::<_, String>(1)?,
                row.get::<_, Vec<u8>>(2)?,
            ))
        })
        .map_err(|err| err.to_string())?;

    let mut decoded = Vec::new();
    for row in rows {
        let (id, name, config) = row.map_err(|err| err.to_string())?;
        if config.first() == Some(&b'{') {
            return Err(format!(
                "deck_config.config for {name} starts with '{{'; expected protobuf"
            ));
        }
        let inner = DeckConfigInner::decode(config.as_slice()).map_err(|err| {
            format!("prost decode of deck_config.config for {name} failed: {err}")
        })?;
        decoded.push(DeckConfigRow {
            id,
            name,
            new_per_day: inner.new_per_day,
            reviews_per_day: inner.reviews_per_day,
        });
    }
    if decoded.is_empty() {
        return Err("export contained no deck_config rows".into());
    }
    Ok(decoded)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn exported_apkg_deck_config_is_protobuf_inside_zstd_sqlite() {
        let dir = tempfile::TempDir::new_in("/tmp").unwrap();
        let rows = inspect_exported_deck_configs(dir.path().to_string_lossy().into_owned())
            .expect("inspect");
        assert!(
            rows.iter().any(|row| row.name == "Default"
                && row.new_per_day == 20
                && row.reviews_per_day == 200),
            "{rows:?}"
        );

        let apkg = dir.path().join("export.apkg");
        let sqlite = decompress_anki21b(&apkg).unwrap();
        assert!(sqlite.starts_with(SQLITE_MAGIC));
    }
}
