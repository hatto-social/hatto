use anki::collection::CollectionBuilder;
use anki::prelude::*;

#[flutter_rust_bridge::frb(sync)]
pub fn greet(name: String) -> String { format!("Hello, {name}!") }

/// rslib (unmodified 26.09.3) smoke: open a collection, add a note, count notes.
#[flutter_rust_bridge::frb(sync)]
pub fn rslib_smoke(dir: String) -> String {
    let run = || -> Result<String> {
        std::fs::create_dir_all(&dir).ok();
        let mut col = CollectionBuilder::new(format!("{dir}/collection.anki2")).build()?;
        let nt = col.get_notetype_by_name("Basic")?.or_not_found("Basic")?;
        let mut n = Note::new(&nt);
        n.set_field(0, "front")?; n.set_field(1, "back")?;
        col.add_note(&mut n, DeckId(1))?;
        let c = col.search_notes_unordered("")?.len();
        let _ = col.close(None);
        Ok(format!("rslib ok: notes={c} guid={} build={}", n.guid, anki::version::buildhash()))
    };
    match run() { Ok(s) => s, Err(e) => format!("rslib error: {e:?}") }
}

#[flutter_rust_bridge::frb(init)]
pub fn init_app() { flutter_rust_bridge::setup_default_user_utils(); }
