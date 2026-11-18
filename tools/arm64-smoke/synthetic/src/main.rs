// SPDX-FileCopyrightText: 2026 Hatto Social contributors
//
// SPDX-License-Identifier: AGPL-3.0-or-later

//! Build the three arm64-smoke colpkg fixtures and measure their round trip.
//!
//! rslib is reached only through `Backend::run_service_method`. The binary is
//! the `make_synthetic_decks` target of `rslib_bridge`. `make_synthetic.py`
//! freezes the clock before it runs this program; do not invoke it directly.

use std::fs;
use std::io::Read;
use std::io::Write;
use std::path::Path;
use std::path::PathBuf;
use std::time::Instant;
use std::time::SystemTime;
use std::time::UNIX_EPOCH;

use anki_proto::generic;
use prost::Message;
use rslib_bridge::api::command;
use rslib_bridge::api::open_backend;
use rslib_bridge::api::prepare_runtime;
use rslib_bridge::api::service_method_index;
use rslib_bridge::api::AnkiBackend;
use rusqlite::Connection;
use serde_json::json;
use serde_json::Value;

/// 2026-01-15 12:00:00 Asia/Seoul. Noon is after Anki's 04:00 day rollover.
const FROZEN_UNIX_SECS: u64 = 1_768_446_000;
const FROZEN_UNIX_MILLIS: i64 = 1_768_446_000_000;
const DUMMY_GUID: &str = "hattoDummy";

struct Counts {
    notes: i64,
    cards: i64,
    revlog_total: i64,
    revlog_with_card: i64,
    filtered_cards: i64,
}

struct Fsrs {
    items: u32,
    params: Vec<f64>,
    seconds: f64,
    deterministic: bool,
}

struct Measured {
    counts_e: Counts,
    counts_r: Counts,
    import_new_notes: usize,
    seconds_colpkg: f64,
    seconds_export: f64,
    seconds_apkg: f64,
    fsrs: Fsrs,
    media_files: usize,
}

fn main() {
    let mut args = std::env::args().skip(1);
    let mut out_dir = None;
    let mut measure_path = None;
    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--out" => out_dir = args.next(),
            "--measure" => measure_path = args.next(),
            other => panic!("unknown argument {other}"),
        }
    }
    let out_dir = PathBuf::from(out_dir.expect("--out <files dir>"));
    let measure_path = PathBuf::from(measure_path.expect("--measure <json path>"));
    assert_frozen_clock();
    fs::create_dir_all(&out_dir).unwrap();

    let work = PathBuf::from("/tmp/hatto-synthetic-decks");
    let _ = fs::remove_dir_all(&work);
    fs::create_dir_all(work.join("tmp")).unwrap();
    prepare_runtime(work.join("tmp").to_string_lossy().into_owned());

    let mut report = serde_json::Map::new();
    report.insert(
        "collection.colpkg".into(),
        build_collection(&work, &out_dir),
    );
    report.insert(
        "collection_nomedia_new.colpkg".into(),
        build_nomedia(&work, &out_dir),
    );
    report.insert("palace.colpkg".into(), build_palace(&work, &out_dir));

    let payload = Value::Object(report);
    fs::write(&measure_path, serde_json::to_vec_pretty(&payload).unwrap()).unwrap();
    println!("{}", serde_json::to_string_pretty(&payload).unwrap());
}

fn assert_frozen_clock() {
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_secs();
    let tz = std::env::var("TZ").unwrap_or_default();
    if now != FROZEN_UNIX_SECS || tz != "Asia/Seoul" {
        panic!(
            "clock must be frozen at unix {FROZEN_UNIX_SECS} with TZ=Asia/Seoul (got unix {now}, TZ={tz}). Run tools/arm64-smoke/make_synthetic.py."
        );
    }
}

struct Col {
    backend: AnkiBackend,
}

impl Col {
    fn open(root: PathBuf) -> Self {
        fs::create_dir_all(root.join("media")).unwrap();
        let init = anki_proto::backend::BackendInit {
            preferred_langs: vec!["en".into()],
            locale_folder_path: String::new(),
            server: false,
        };
        let backend =
            open_backend(init.encode_to_vec()).unwrap_or_else(|err| panic!("backend: {err}"));
        let open = anki_proto::collection::OpenCollectionRequest {
            collection_path: root.join("collection.anki2").to_string_lossy().into_owned(),
            media_folder_path: root.join("media").to_string_lossy().into_owned(),
            media_db_path: root.join("media.db").to_string_lossy().into_owned(),
        };
        call_raw(
            &backend,
            "BackendCollectionService",
            "open_collection",
            &open,
        );
        Self { backend }
    }

    fn call<M: Message + Default>(&self, service: &str, method: &str, input: &impl Message) -> M {
        let bytes = call_raw(&self.backend, service, method, input);
        M::decode(bytes.as_slice()).unwrap_or_else(|err| panic!("decode {service}.{method}: {err}"))
    }

    fn close(&self) {
        let close = anki_proto::collection::CloseCollectionRequest {
            downgrade_to_schema11: false,
        };
        call_raw(
            &self.backend,
            "BackendCollectionService",
            "close_collection",
            &close,
        );
    }
}

fn call_raw(backend: &AnkiBackend, service: &str, method: &str, input: &impl Message) -> Vec<u8> {
    let Some(index) = service_method_index(service.to_string(), method.to_string()) else {
        panic!("no protobuf index for {service}.{method}");
    };
    let response = command(backend, index.service, index.method, input.encode_to_vec());
    if response.success {
        return response.payload;
    }
    let detail = anki_proto::backend::BackendError::decode(response.payload.as_slice())
        .map(|err| format!("{} (kind={:?})", err.message, err.kind))
        .unwrap_or_else(|_| "undecodable backend error".into());
    panic!("{service}.{method} failed: {detail}");
}

fn notetype_id(col: &Col, name: &str) -> i64 {
    let found: anki_proto::notetypes::NotetypeId = col.call(
        "BackendNotetypesService",
        "get_notetype_id_by_name",
        &generic::String { val: name.into() },
    );
    if found.ntid == 0 {
        panic!("notetype {name} is missing");
    }
    found.ntid
}

fn add_deck(col: &Col, name: &str) -> i64 {
    let mut deck: anki_proto::decks::Deck =
        col.call("BackendDecksService", "new_deck", &generic::Empty {});
    deck.name = name.into();
    let added: anki_proto::collection::OpChangesWithId =
        col.call("BackendDecksService", "add_deck", &deck);
    if added.id == 0 {
        panic!("add_deck {name} returned id 0");
    }
    added.id
}

fn add_hatto_vocab(col: &Col) -> i64 {
    let basic = notetype_id(col, "Basic");
    let raw: generic::Json = col.call(
        "BackendNotetypesService",
        "get_notetype_legacy",
        &anki_proto::notetypes::NotetypeId { ntid: basic },
    );
    let mut model: Value = serde_json::from_slice(&raw.json).unwrap();
    model["id"] = json!(0);
    model["name"] = json!("Hatto Vocab");
    model["flds"][0]["name"] = json!("Word");
    model["flds"][1]["name"] = json!("Meaning");
    let mut card2 = model["tmpls"][0].clone();
    card2["name"] = json!("Meaning first");
    card2["ord"] = json!(1);
    card2["qfmt"] = json!("{{Meaning}}");
    card2["afmt"] = json!("{{FrontSide}}\n\n<hr id=answer>\n\n{{Word}}");
    model["tmpls"].as_array_mut().unwrap().push(card2);
    model["tmpls"][0]["name"] = json!("Word first");
    model["tmpls"][0]["qfmt"] = json!("{{Word}}");
    model["tmpls"][0]["afmt"] = json!("{{FrontSide}}\n\n<hr id=answer>\n\n{{Meaning}}");
    let added: anki_proto::collection::OpChangesWithId = col.call(
        "BackendNotetypesService",
        "add_notetype_legacy",
        &generic::Json {
            json: serde_json::to_vec(&model).unwrap(),
        },
    );
    if added.id == 0 {
        panic!("add_notetype_legacy returned id 0: {model}");
    }
    added.id
}

fn add_note(
    col: &Col,
    notetype: i64,
    deck: i64,
    guid: &str,
    fields: &[&str],
    tags: &[&str],
) -> i64 {
    let mut note: anki_proto::notes::Note = col.call(
        "BackendNotesService",
        "new_note",
        &anki_proto::notetypes::NotetypeId { ntid: notetype },
    );
    // Replace the random guid before insert so the database never stores it.
    note.guid = guid.into();
    note.fields = fields.iter().map(|field| (*field).to_string()).collect();
    note.tags = tags.iter().map(|tag| (*tag).to_string()).collect();
    let added: anki_proto::notes::AddNoteResponse = col.call(
        "BackendNotesService",
        "add_note",
        &anki_proto::notes::AddNoteRequest {
            note: Some(note),
            deck_id: deck,
        },
    );
    if added.note_id == 0 {
        panic!("add_note {guid} returned id 0");
    }
    added.note_id
}

fn set_current_deck(col: &Col, deck: i64) {
    let _: anki_proto::collection::OpChanges = col.call(
        "BackendDecksService",
        "set_current_deck",
        &anki_proto::decks::DeckId { did: deck },
    );
}

fn answer_good(col: &Col, at_millis: i64) -> i64 {
    let queued: anki_proto::scheduler::QueuedCards = col.call(
        "BackendSchedulerService",
        "get_queued_cards",
        &anki_proto::scheduler::GetQueuedCardsRequest {
            fetch_limit: 1,
            intraday_learning_only: false,
        },
    );
    let Some(queued_card) = queued.cards.first() else {
        panic!("no queued card to answer");
    };
    let card = queued_card.card.as_ref().expect("queued card missing card");
    let states = queued_card
        .states
        .as_ref()
        .expect("queued card missing states");
    let _: anki_proto::collection::OpChanges = col.call(
        "BackendSchedulerService",
        "answer_card",
        &anki_proto::scheduler::CardAnswer {
            card_id: card.id,
            current_state: states.current.clone(),
            new_state: states.good.clone(),
            rating: anki_proto::scheduler::card_answer::Rating::Good as i32,
            answered_at_millis: at_millis,
            milliseconds_taken: 1200,
        },
    );
    card.id
}

fn suspend_cards(col: &Col, card_ids: &[i64]) {
    if card_ids.is_empty() {
        return;
    }
    let _: anki_proto::collection::OpChangesWithCount = col.call(
        "BackendSchedulerService",
        "bury_or_suspend_cards",
        &anki_proto::scheduler::BuryOrSuspendCardsRequest {
            card_ids: card_ids.to_vec(),
            note_ids: Vec::new(),
            mode: anki_proto::scheduler::bury_or_suspend_cards_request::Mode::Suspend as i32,
        },
    );
}

fn add_filtered(col: &Col, name: &str, search: &str, limit: u32) {
    let mut deck: anki_proto::decks::FilteredDeckForUpdate = col.call(
        "BackendDecksService",
        "get_or_create_filtered_deck",
        &anki_proto::decks::DeckId { did: 0 },
    );
    deck.name = name.into();
    deck.allow_empty = false;
    let config = deck.config.as_mut().expect("filtered deck config");
    config.reschedule = true;
    config.search_terms = vec![anki_proto::decks::deck::filtered::SearchTerm {
        search: search.into(),
        limit,
        order: anki_proto::decks::deck::filtered::search_term::Order::Added as i32,
    }];
    let added: anki_proto::collection::OpChangesWithId =
        col.call("BackendDecksService", "add_or_update_filtered_deck", &deck);
    if added.id == 0 {
        panic!("filtered deck {name} was not saved");
    }
}

fn query(col: &Col, sql: &str) -> Value {
    let request = json!({
        "kind": "query",
        "sql": sql,
        "args": [],
        "first_row_only": false,
    });
    let response: generic::Json = col.call(
        "BackendAnkidroidService",
        "run_db_command",
        &generic::Json {
            json: serde_json::to_vec(&request).unwrap(),
        },
    );
    serde_json::from_slice(&response.json).unwrap_or_else(|err| panic!("db json {sql}: {err}"))
}

fn scalar(col: &Col, sql: &str) -> i64 {
    let rows = query(col, sql);
    rows[0][0]
        .as_i64()
        .unwrap_or_else(|| panic!("scalar {sql} from {rows}"))
}

fn counts_of(col: &Col) -> Counts {
    Counts {
        notes: scalar(col, "select count(*) from notes"),
        cards: scalar(col, "select count(*) from cards"),
        revlog_total: scalar(col, "select count(*) from revlog"),
        revlog_with_card: scalar(
            col,
            "select count(*) from revlog where cid in (select id from cards)",
        ),
        filtered_cards: scalar(col, "select count(*) from cards where odid != 0"),
    }
}

fn insert_orphan_revlog(col: &Col, rows: i64) {
    let mut args = Vec::new();
    for index in 0..rows {
        // Ids sit far from millisecond card ids. cid 42 matches no card.
        args.push(json!([9_100_000 + index, 42, -1, 3, 1, 0, 2500, 1000, 1]));
    }
    let request = json!({
        "kind": "executemany",
        "sql": "insert into revlog (id, cid, usn, ease, ivl, lastIvl, factor, time, type) values (?, ?, ?, ?, ?, ?, ?, ?, ?)",
        "args": args,
    });
    let _: generic::Json = col.call(
        "BackendAnkidroidService",
        "run_db_command",
        &generic::Json {
            json: serde_json::to_vec(&request).unwrap(),
        },
    );
}

/// Multi-card notes get template ordinals in hash order. Pin the lowest card
/// id to the lowest ordinal before any review or filtered-deck move.
fn canonicalize_new_siblings(col: &Col) {
    let rows = query(col, "select id, nid, ord, due from cards order by nid, id");
    let rows = rows.as_array().expect("card rows");
    let mut index = 0;
    let mut args = Vec::new();
    while index < rows.len() {
        let nid = rows[index][1].as_i64().unwrap();
        let start = index;
        while index < rows.len() && rows[index][1].as_i64().unwrap() == nid {
            index += 1;
        }
        let group = &rows[start..index];
        let mut pairs: Vec<(i64, i64)> = group
            .iter()
            .map(|row| (row[2].as_i64().unwrap(), row[3].as_i64().unwrap()))
            .collect();
        pairs.sort();
        for (row, (ord, due)) in group.iter().zip(pairs) {
            args.push(json!([ord, due, row[0].as_i64().unwrap()]));
        }
    }
    if args.is_empty() {
        return;
    }
    db_exec(col, "update cards set ord = ?, due = ? where id = ?", args);
}

fn db_exec(col: &Col, sql: &str, args: Vec<Value>) {
    let request = json!({
        "kind": "executemany",
        "sql": sql,
        "args": args,
    });
    let _: generic::Json = col.call(
        "BackendAnkidroidService",
        "run_db_command",
        &generic::Json {
            json: serde_json::to_vec(&request).unwrap(),
        },
    );
}

fn card_ids(col: &Col) -> Vec<i64> {
    let rows = query(col, "select id from cards order by id");
    rows.as_array()
        .unwrap()
        .iter()
        .map(|row| row[0].as_i64().unwrap())
        .collect()
}

fn add_media(col: &Col, name: &str, data: &[u8]) -> String {
    let stored: generic::String = col.call(
        "BackendMediaService",
        "add_media_file",
        &anki_proto::media::AddMediaFileRequest {
            desired_name: name.into(),
            data: data.to_vec(),
        },
    );
    if stored.val != name {
        panic!("media {name} was stored as {}", stored.val);
    }
    stored.val
}

fn export_colpkg(col: &Col, path: &Path) {
    let _: generic::Empty = col.call(
        "BackendImportExportService",
        "export_collection_package",
        &anki_proto::import_export::ExportCollectionPackageRequest {
            out_path: path.to_string_lossy().into_owned(),
            include_media: true,
            legacy: false,
        },
    );
}

fn build_collection(work: &Path, out_dir: &Path) -> Value {
    let root = work.join("collection");
    let col = Col::open(root);
    let parent = add_deck(&col, "Synthetic");
    let core = add_deck(&col, "Synthetic::Core");
    let extra = add_deck(&col, "Synthetic::Extra");
    let _ = parent;
    let basic = notetype_id(&col, "Basic");
    let reversed = notetype_id(&col, "Basic (and reversed card)");
    let cloze = notetype_id(&col, "Cloze");
    let vocab = add_hatto_vocab(&col);
    add_note(
        &col,
        basic,
        core,
        "hColBasic01",
        &["synthetic front alpha", "synthetic back alpha"],
        &["synthetic"],
    );
    add_note(
        &col,
        basic,
        core,
        "hColBasic02",
        &["synthetic front beta", "synthetic back beta"],
        &["synthetic", "cram"],
    );
    add_note(
        &col,
        basic,
        core,
        "hColBasic03",
        &["synthetic front gamma", "synthetic back gamma"],
        &["synthetic", "cram"],
    );
    add_note(
        &col,
        reversed,
        core,
        "hColRev0001",
        &["synthetic reversed front", "synthetic reversed back"],
        &["synthetic"],
    );
    add_note(
        &col,
        cloze,
        extra,
        "hColCloze01",
        &[
            "{{c1::Hatto}} writes {{c2::synthetic}} collection decks",
            "cloze extra written for the smoke",
        ],
        &["synthetic", "cram"],
    );
    add_note(
        &col,
        vocab,
        extra,
        "hColVocab01",
        &["hatto-word", "a word written for this deck"],
        &["synthetic", "cram"],
    );
    canonicalize_new_siblings(&col);
    set_current_deck(&col, parent);
    let _answered = answer_good(&col, FROZEN_UNIX_MILLIS);
    let _answered = answer_good(&col, FROZEN_UNIX_MILLIS + 1000);
    let ids = card_ids(&col);
    suspend_cards(&col, &ids[ids.len() - 2..]);
    add_filtered(&col, "Cram", "tag:cram", 20);
    let destination = out_dir.join("collection.colpkg");
    export_colpkg(&col, &destination);
    drop(col);
    normalize_colpkg(&destination);
    measure(&destination, "collection")
}

fn build_nomedia(work: &Path, out_dir: &Path) -> Value {
    let root = work.join("nomedia");
    let col = Col::open(root);
    let basic = notetype_id(&col, "Basic");
    let vocab = add_hatto_vocab(&col);
    for index in 1..=4 {
        add_note(
            &col,
            basic,
            1,
            &format!("hNomBasic{index:02}"),
            &[
                &format!("nomedia front {index}"),
                &format!("nomedia back {index}"),
            ],
            &["synthetic"],
        );
    }
    add_note(
        &col,
        vocab,
        1,
        "hNomVocab01",
        &["nomedia word one", "nomedia meaning one"],
        &["synthetic"],
    );
    add_note(
        &col,
        vocab,
        1,
        "hNomVocab02",
        &["nomedia word two", "nomedia meaning two"],
        &["synthetic"],
    );
    canonicalize_new_siblings(&col);
    set_current_deck(&col, 1);
    answer_good(&col, FROZEN_UNIX_MILLIS);
    insert_orphan_revlog(&col, 87);
    let before = counts_of(&col);
    assert_eq!(
        (
            before.notes,
            before.cards,
            before.revlog_total,
            before.revlog_with_card,
            before.filtered_cards
        ),
        (6, 8, 88, 1, 0),
        "nomedia fixture must keep the orphan-revlog shape the smoke documents"
    );
    let destination = out_dir.join("collection_nomedia_new.colpkg");
    export_colpkg(&col, &destination);
    drop(col);
    normalize_colpkg(&destination);
    let measured = measure(&destination, "nomedia");
    let revlog_total = measured["E_after_colpkg_import"]["revlog_total"]
        .as_i64()
        .unwrap();
    let revlog_carded = measured["E_after_colpkg_import"]["revlog_with_card"]
        .as_i64()
        .unwrap();
    let round_total = measured["R_after_apkg_import"]["revlog_total"]
        .as_i64()
        .unwrap();
    assert_eq!(
        (revlog_total, revlog_carded, round_total),
        (88, 1, 1),
        "apkg export must drop the 87 orphan revlog rows and keep the one carded row"
    );
    measured
}

fn build_palace(work: &Path, out_dir: &Path) -> Value {
    let root = work.join("palace");
    let col = Col::open(root);
    let png = add_media(&col, "hatto-dot.png", &png_dot());
    let wav = add_media(&col, "hatto-tone.wav", &wav_tone());
    let languages = add_deck(&col, "Languages");
    let examples = add_deck(&col, "Languages::Examples");
    let science = add_deck(&col, "Science");
    let basic = notetype_id(&col, "Basic");
    let reversed = notetype_id(&col, "Basic (and reversed card)");
    let cloze = notetype_id(&col, "Cloze");
    add_note(
        &col,
        basic,
        examples,
        "hPalBasic01",
        &[
            &format!("synthetic picture <img src=\"{png}\">"),
            "the picture is a generated 8 by 8 PNG",
        ],
        &["synthetic", "drill"],
    );
    add_note(
        &col,
        basic,
        examples,
        "hPalBasic02",
        &[
            &format!("synthetic tone [sound:{wav}]"),
            "the tone is a generated PCM WAV",
        ],
        &["synthetic", "drill"],
    );
    add_note(
        &col,
        reversed,
        languages,
        "hPalRev0001",
        &["synthetic palace front", "synthetic palace back"],
        &["synthetic"],
    );
    add_note(
        &col,
        cloze,
        science,
        "hPalCloze01",
        &[
            "{{c1::synthetic}} media stays inside the {{c2::colpkg}}",
            "cloze extra written for the smoke",
        ],
        &["synthetic", "drill"],
    );
    canonicalize_new_siblings(&col);
    set_current_deck(&col, languages);
    answer_good(&col, FROZEN_UNIX_MILLIS);
    answer_good(&col, FROZEN_UNIX_MILLIS + 1000);
    let ids = card_ids(&col);
    suspend_cards(&col, &[ids[0]]);
    add_filtered(&col, "Drill", "tag:drill", 10);
    let destination = out_dir.join("palace.colpkg");
    export_colpkg(&col, &destination);
    drop(col);
    normalize_colpkg(&destination);
    let measured = measure(&destination, "palace");
    assert_eq!(
        measured["media_files_after_colpkg_import"]
            .as_u64()
            .unwrap(),
        2,
        "palace import must restore both generated media files"
    );
    measured
}

fn measure(colpkg: &Path, label: &str) -> Value {
    let root = PathBuf::from("/tmp/hatto-synthetic-decks").join(format!("round-{label}"));
    let _ = fs::remove_dir_all(&root);
    let extracted = root.join("E");
    fs::create_dir_all(extracted.join("media")).unwrap();
    let started = Instant::now();
    import_colpkg(colpkg, &extracted);
    let seconds_colpkg = started.elapsed().as_secs_f64();
    let media_files = fs::read_dir(extracted.join("media"))
        .unwrap()
        .filter(|entry| {
            entry
                .as_ref()
                .map(|item| item.path().is_file())
                .unwrap_or(false)
        })
        .count();
    if label == "palace" {
        let png = fs::read(extracted.join("media").join("hatto-dot.png")).expect("png restored");
        let wav = fs::read(extracted.join("media").join("hatto-tone.wav")).expect("wav restored");
        assert_eq!(png, png_dot());
        assert_eq!(wav, wav_tone());
    } else {
        assert_eq!(media_files, 0, "{label} must import no media files");
    }

    let opened = Col::open(extracted.clone());
    let counts_e = counts_of(&opened);
    let apkg = root.join("round.apkg");
    let started = Instant::now();
    export_apkg(&opened, &apkg);
    let seconds_export = started.elapsed().as_secs_f64();
    opened.close();

    let resident_root = root.join("R");
    let resident = Col::open(resident_root);
    let started = Instant::now();
    let imported = import_apkg(&resident, &apkg);
    let seconds_apkg = started.elapsed().as_secs_f64();
    let counts_r = counts_of(&resident);
    let fsrs = fsrs_twice(&resident);
    resident.close();

    assert_eq!(counts_e.notes, counts_r.notes, "{label} notes");
    assert_eq!(counts_e.cards, counts_r.cards, "{label} cards");
    assert_eq!(
        counts_e.revlog_with_card, counts_r.revlog_with_card,
        "{label} carded revlog"
    );

    let measured = Measured {
        counts_e,
        counts_r,
        import_new_notes: imported,
        seconds_colpkg,
        seconds_export,
        seconds_apkg,
        fsrs,
        media_files,
    };
    measured_json(&measured)
}

fn import_colpkg(colpkg: &Path, dir: &Path) {
    let init = anki_proto::backend::BackendInit {
        preferred_langs: vec!["en".into()],
        locale_folder_path: String::new(),
        server: false,
    };
    let backend = open_backend(init.encode_to_vec()).unwrap();
    call_raw(
        &backend,
        "BackendImportExportService",
        "import_collection_package",
        &anki_proto::import_export::ImportCollectionPackageRequest {
            col_path: dir.join("collection.anki2").to_string_lossy().into_owned(),
            backup_path: colpkg.to_string_lossy().into_owned(),
            media_folder: dir.join("media").to_string_lossy().into_owned(),
            media_db: dir.join("media.db").to_string_lossy().into_owned(),
        },
    );
}

fn export_apkg(col: &Col, path: &Path) {
    let _: generic::UInt32 = col.call(
        "BackendImportExportService",
        "export_anki_package",
        &anki_proto::import_export::ExportAnkiPackageRequest {
            out_path: path.to_string_lossy().into_owned(),
            options: Some(anki_proto::import_export::ExportAnkiPackageOptions {
                with_scheduling: true,
                with_deck_configs: true,
                with_media: true,
                legacy: false,
            }),
            limit: Some(anki_proto::import_export::ExportLimit {
                limit: Some(
                    anki_proto::import_export::export_limit::Limit::WholeCollection(
                        generic::Empty {},
                    ),
                ),
            }),
        },
    );
}

fn import_apkg(col: &Col, path: &Path) -> usize {
    let response: anki_proto::import_export::ImportResponse = col.call(
        "BackendImportExportService",
        "import_anki_package",
        &anki_proto::import_export::ImportAnkiPackageRequest {
            package_path: path.to_string_lossy().into_owned(),
            options: Some(anki_proto::import_export::ImportAnkiPackageOptions {
                merge_notetypes: false,
                update_notes: anki_proto::import_export::ImportAnkiPackageUpdateCondition::Never
                    as i32,
                update_notetypes: anki_proto::import_export::ImportAnkiPackageUpdateCondition::Never
                    as i32,
                with_scheduling: true,
                with_deck_configs: true,
            }),
        },
    );
    response.log.map(|log| log.new.len()).unwrap_or(0)
}

fn fsrs_twice(col: &Col) -> Fsrs {
    let started = Instant::now();
    let first = compute_fsrs(col);
    let seconds = started.elapsed().as_secs_f64();
    let second = compute_fsrs(col);
    Fsrs {
        items: first.0,
        params: first.1.clone(),
        seconds,
        deterministic: first.0 == second.0 && first.1 == second.1,
    }
}

fn compute_fsrs(col: &Col) -> (u32, Vec<f64>) {
    let response: anki_proto::scheduler::ComputeFsrsParamsResponse = col.call(
        "BackendSchedulerService",
        "compute_fsrs_params",
        &anki_proto::scheduler::ComputeFsrsParamsRequest {
            search: String::new(),
            current_params: Vec::new(),
            ignore_revlogs_before_ms: 0,
            num_of_relearning_steps: 1,
            health_check: false,
        },
    );
    let params = response
        .params
        .iter()
        .map(|value| (*value as f64 * 1_000_000.0).round() / 1_000_000.0)
        .collect();
    (response.fsrs_items, params)
}

fn counts_json(counts: &Counts) -> Value {
    json!({
        "notes": counts.notes,
        "cards": counts.cards,
        "revlog_total": counts.revlog_total,
        "revlog_with_card": counts.revlog_with_card,
        "filtered_cards": counts.filtered_cards,
    })
}

fn measured_json(measured: &Measured) -> Value {
    let finite = measured
        .fsrs
        .params
        .iter()
        .all(|value| value.is_finite() && value.abs() < 1e9);
    json!({
        "E_after_colpkg_import": counts_json(&measured.counts_e),
        "R_after_apkg_import": counts_json(&measured.counts_r),
        "import_new_notes": measured.import_new_notes,
        "host_seconds": {
            "colpkg": round3(measured.seconds_colpkg),
            "export": round3(measured.seconds_export),
            "apkg_import": round3(measured.seconds_apkg),
        },
        "fsrs": {
            "fsrs_items": measured.fsrs.items,
            "n_params": measured.fsrs.params.len(),
            "params": measured.fsrs.params,
            "all_finite": finite,
            "seconds": round3(measured.fsrs.seconds),
        },
        "fsrs_deterministic_on_host": measured.fsrs.deterministic,
        "pass_rule": {
            "notes": measured.counts_e.notes == measured.counts_r.notes,
            "cards": measured.counts_e.cards == measured.counts_r.cards,
            "revlog_with_card": measured.counts_e.revlog_with_card == measured.counts_r.revlog_with_card,
        },
        "media_files_after_colpkg_import": measured.media_files,
    })
}

fn round3(value: f64) -> f64 {
    (value * 1000.0).round() / 1000.0
}

/// rslib's legacy `collection.anki2` stub gets a random note guid. Rewrite that
/// guid, vacuum, and restamp the zip so a second run matches byte for byte.
fn normalize_colpkg(path: &Path) {
    let file = fs::File::open(path).unwrap();
    let mut archive = zip::ZipArchive::new(file).unwrap();
    let mut entries = Vec::new();
    for index in 0..archive.len() {
        let mut entry = archive.by_index(index).unwrap();
        let name = entry.name().to_string();
        let mut data = Vec::new();
        entry.read_to_end(&mut data).unwrap();
        if name == "collection.anki2" {
            data = normalize_dummy_sqlite(&data);
        } else if name == "collection.anki21b" {
            data = normalize_schema18(&data);
        }
        entries.push((name, data));
    }
    drop(archive);
    let file = fs::File::create(path).unwrap();
    let mut writer = zip::ZipWriter::new(file);
    let stamp = zip::DateTime::from_date_and_time(2026, 1, 15, 12, 0, 0).unwrap();
    let options = zip::write::SimpleFileOptions::default()
        .compression_method(zip::CompressionMethod::Stored)
        .last_modified_time(stamp);
    for (name, data) in entries {
        writer.start_file(name, options).unwrap();
        writer.write_all(&data).unwrap();
    }
    writer.finish().unwrap();
}

fn normalize_dummy_sqlite(bytes: &[u8]) -> Vec<u8> {
    // The stub's schema-11 JSON stores random field ids, and vacuum keeps the
    // old page layout. Rebuild the file from its rows with those ids pinned.
    let dir = PathBuf::from("/tmp/hatto-synthetic-decks/dummy-sqlite");
    let _ = fs::remove_dir_all(&dir);
    fs::create_dir_all(&dir).unwrap();
    let src_path = dir.join("source.anki2");
    let db_path = dir.join("collection.anki2");
    fs::write(&src_path, bytes).unwrap();
    let src = Connection::open(&src_path).unwrap();
    register_unicase(&src);
    let statements = schema_sql(&src);
    let mut col_row = table_rows(&src, "select * from col");
    let col_names = column_names(&src, "col");
    assert_eq!(col_row.len(), 1, "legacy stub should contain one col row");
    let mut id_counter = 0i64;
    for (name, value) in col_names.iter().zip(col_row[0].iter_mut()) {
        if !matches!(
            name.as_str(),
            "conf" | "models" | "decks" | "dconf" | "tags"
        ) {
            continue;
        }
        let rusqlite::types::Value::Text(text) = value else {
            continue;
        };
        if let Ok(parsed) = serde_json::from_str::<Value>(text) {
            *value = rusqlite::types::Value::Text(
                serde_json::to_string(&pin_json_ids(parsed, &mut id_counter)).unwrap(),
            );
        }
    }
    let note_names = column_names(&src, "notes");
    let mut note_rows = table_rows(&src, "select * from notes");
    assert_eq!(
        note_rows.len(),
        1,
        "legacy stub should contain one dummy note"
    );
    let guid_index = note_names.iter().position(|name| name == "guid").unwrap();
    note_rows[0][guid_index] = rusqlite::types::Value::Text(DUMMY_GUID.into());
    let card_rows = table_rows(&src, "select * from cards");
    drop(src);

    let dst = Connection::open(&db_path).unwrap();
    register_unicase(&dst);
    dst.execute_batch("pragma page_size=512").unwrap();
    for sql in statements {
        dst.execute(&sql, []).unwrap();
    }
    insert_rows(&dst, "col", &col_row);
    insert_rows(&dst, "notes", &note_rows);
    insert_rows(&dst, "cards", &card_rows);
    dst.execute_batch("vacuum").unwrap();
    drop(dst);
    fs::read(db_path).unwrap()
}

fn schema_sql(conn: &Connection) -> Vec<String> {
    let mut out = Vec::new();
    for kind in ["table", "index"] {
        let mut stmt = conn
            .prepare(&format!(
                "select sql from sqlite_master where type = ?1 and sql is not null and name not like 'sqlite_%' order by name"
            ))
            .unwrap();
        let rows = stmt
            .query_map([kind], |row| row.get::<_, String>(0))
            .unwrap();
        for sql in rows {
            out.push(sql.unwrap());
        }
    }
    out
}

fn column_names(conn: &Connection, table: &str) -> Vec<String> {
    conn.prepare(&format!("pragma table_info({table})"))
        .unwrap()
        .query_map([], |row| row.get::<_, String>(1))
        .unwrap()
        .map(|name| name.unwrap())
        .collect()
}

fn table_rows(conn: &Connection, sql: &str) -> Vec<Vec<rusqlite::types::Value>> {
    let mut stmt = conn.prepare(sql).unwrap();
    let columns = stmt.column_count();
    stmt.query_map([], |row| {
        let mut values = Vec::with_capacity(columns);
        for index in 0..columns {
            values.push(row.get(index)?);
        }
        Ok(values)
    })
    .unwrap()
    .map(|row| row.unwrap())
    .collect()
}

fn insert_rows(conn: &Connection, table: &str, rows: &[Vec<rusqlite::types::Value>]) {
    if rows.is_empty() {
        return;
    }
    let placeholders = vec!["?"; rows[0].len()].join(", ");
    let sql = format!("insert into {table} values ({placeholders})");
    for row in rows {
        conn.execute(&sql, rusqlite::params_from_iter(row.iter()))
            .unwrap();
    }
}

fn pin_json_ids(value: Value, counter: &mut i64) -> Value {
    match value {
        Value::Array(items) => Value::Array(
            items
                .into_iter()
                .map(|item| pin_json_ids(item, counter))
                .collect(),
        ),
        Value::Object(map) => {
            let mut keys: Vec<_> = map.into_iter().collect();
            keys.sort_by(|left, right| left.0.cmp(&right.0));
            let mut out = serde_json::Map::new();
            for (key, item) in keys {
                let item = if key == "id" {
                    if let Some(number) = item.as_i64() {
                        if number.unsigned_abs() > 1_000_000_000_000_000 {
                            *counter += 1;
                            Value::from(*counter)
                        } else {
                            pin_json_ids(item, counter)
                        }
                    } else {
                        pin_json_ids(item, counter)
                    }
                } else {
                    pin_json_ids(item, counter)
                };
                out.insert(key, item);
            }
            Value::Object(out)
        }
        other => other,
    }
}

fn normalize_schema18(compressed: &[u8]) -> Vec<u8> {
    let sqlite = zstd::stream::decode_all(compressed).expect("anki21b zstd");
    let dir = PathBuf::from("/tmp/hatto-synthetic-decks/schema18");
    let _ = fs::remove_dir_all(&dir);
    fs::create_dir_all(&dir).unwrap();
    let db_path = dir.join("collection.anki21");
    fs::write(&db_path, sqlite).unwrap();
    let conn = Connection::open(&db_path).unwrap();
    register_unicase(&conn);
    stabilize_field_ids(&conn);
    stabilize_template_ids(&conn);
    vacuum_clean(&conn);
    drop(conn);
    let sqlite = fs::read(db_path).unwrap();
    zstd::stream::encode_all(std::io::Cursor::new(sqlite), 0).expect("zstd encode")
}

fn stabilize_field_ids(conn: &Connection) {
    let rows: Vec<(i64, i64, Vec<u8>)> = conn
        .prepare("select ntid, ord, config from fields")
        .unwrap()
        .query_map([], |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)))
        .unwrap()
        .map(|row| row.unwrap())
        .collect();
    for (ntid, ord, bytes) in rows {
        let mut config = anki_proto::notetypes::notetype::field::Config::decode(bytes.as_slice())
            .expect("field config");
        config.id = Some(ntid.wrapping_add(ord));
        conn.execute(
            "update fields set config = ?1 where ntid = ?2 and ord = ?3",
            rusqlite::params![config.encode_to_vec(), ntid, ord],
        )
        .unwrap();
    }
}

fn stabilize_template_ids(conn: &Connection) {
    let rows: Vec<(i64, i64, Vec<u8>)> = conn
        .prepare("select ntid, ord, config from templates")
        .unwrap()
        .query_map([], |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)))
        .unwrap()
        .map(|row| row.unwrap())
        .collect();
    for (ntid, ord, bytes) in rows {
        let mut config =
            anki_proto::notetypes::notetype::template::Config::decode(bytes.as_slice())
                .expect("template config");
        config.id = Some(ntid.wrapping_add(1_000_000).wrapping_add(ord));
        conn.execute(
            "update templates set config = ?1 where ntid = ?2 and ord = ?3",
            rusqlite::params![config.encode_to_vec(), ntid, ord],
        )
        .unwrap();
    }
}

fn vacuum_clean(conn: &Connection) {
    conn.execute_batch("delete from sqlite_stat1; delete from sqlite_stat4; vacuum;")
        .unwrap();
}

fn register_unicase(conn: &Connection) {
    conn.create_collation("unicase", |left, right| {
        left.to_lowercase().cmp(&right.to_lowercase())
    })
    .unwrap();
}

fn png_dot() -> Vec<u8> {
    // 8x8 RGB, filter byte 0, a block letter H drawn with two colours we chose.
    let mut raw = Vec::new();
    for y in 0..8 {
        raw.push(0);
        for x in 0..8 {
            let ink = x == 1 || x == 6 || (y == 3 && (1..=6).contains(&x));
            if ink {
                raw.extend_from_slice(&[0x1f, 0x6b, 0x4a]);
            } else {
                raw.extend_from_slice(&[0xf4, 0xef, 0xe6]);
            }
        }
    }
    png_rgb(8, 8, &raw)
}

fn png_rgb(width: u32, height: u32, raw: &[u8]) -> Vec<u8> {
    let mut ihdr = Vec::new();
    ihdr.extend_from_slice(&width.to_be_bytes());
    ihdr.extend_from_slice(&height.to_be_bytes());
    ihdr.extend_from_slice(&[8, 2, 0, 0, 0]);
    let mut png = vec![0x89, b'P', b'N', b'G', b'\r', b'\n', 0x1a, b'\n'];
    png.extend(png_chunk(b"IHDR", &ihdr));
    png.extend(png_chunk(b"IDAT", &zlib_store(raw)));
    png.extend(png_chunk(b"IEND", &[]));
    png
}

fn png_chunk(kind: &[u8; 4], data: &[u8]) -> Vec<u8> {
    let mut chunk = Vec::new();
    chunk.extend_from_slice(&(data.len() as u32).to_be_bytes());
    chunk.extend_from_slice(kind);
    chunk.extend_from_slice(data);
    let mut crc_input = kind.to_vec();
    crc_input.extend_from_slice(data);
    chunk.extend_from_slice(&crc32(&crc_input).to_be_bytes());
    chunk
}

fn zlib_store(data: &[u8]) -> Vec<u8> {
    assert!(data.len() <= 65535);
    let mut out = vec![0x78, 0x01, 0x01];
    let len = data.len() as u16;
    out.extend_from_slice(&len.to_le_bytes());
    out.extend_from_slice(&(!len).to_le_bytes());
    out.extend_from_slice(data);
    out.extend_from_slice(&adler32(data).to_be_bytes());
    out
}

fn crc32(data: &[u8]) -> u32 {
    let mut crc = 0xffff_ffffu32;
    for &byte in data {
        crc ^= u32::from(byte);
        for _ in 0..8 {
            let mask = 0u32.wrapping_sub(crc & 1);
            crc = (crc >> 1) ^ (0xedb8_8320 & mask);
        }
    }
    !crc
}

fn adler32(data: &[u8]) -> u32 {
    let mut a = 1u32;
    let mut b = 0u32;
    for &byte in data {
        a = (a + u32::from(byte)) % 65521;
        b = (b + a) % 65521;
    }
    (b << 16) | a
}

fn wav_tone() -> Vec<u8> {
    // 8-bit mono PCM, 8000 Hz, 32 samples of a square wave. No borrowed audio.
    let samples: Vec<u8> = (0..32)
        .map(|index| if (index / 4) % 2 == 0 { 192 } else { 64 })
        .collect();
    let data_len = samples.len() as u32;
    let mut wav = Vec::new();
    wav.extend_from_slice(b"RIFF");
    wav.extend_from_slice(&(36 + data_len).to_le_bytes());
    wav.extend_from_slice(b"WAVE");
    wav.extend_from_slice(b"fmt ");
    wav.extend_from_slice(&16u32.to_le_bytes());
    wav.extend_from_slice(&1u16.to_le_bytes());
    wav.extend_from_slice(&1u16.to_le_bytes());
    wav.extend_from_slice(&8000u32.to_le_bytes());
    wav.extend_from_slice(&8000u32.to_le_bytes());
    wav.extend_from_slice(&1u16.to_le_bytes());
    wav.extend_from_slice(&8u16.to_le_bytes());
    wav.extend_from_slice(b"data");
    wav.extend_from_slice(&data_len.to_le_bytes());
    wav.extend_from_slice(&samples);
    wav
}
