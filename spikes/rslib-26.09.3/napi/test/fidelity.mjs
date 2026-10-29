/**
 * Field-level apkg roundtrip. Creates sample decks, exports with option
 * combinations, reimports, and compares sqlite snapshots.
 *
 *   node test/fidelity.mjs            # build originals + napi roundtrip + napi mutation
 *   node test/fidelity.mjs --phase=server
 *       # import the FRB app re-export and check delete/guid/notetype behaviour
 */
import { createRequire } from "node:module";
import { spawnSync } from "node:child_process";
import { setTimeout as sleep } from "node:timers/promises";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import protobuf from "protobufjs";

const require = createRequire(import.meta.url);
const here = path.dirname(fileURLToPath(import.meta.url));
const spike = path.resolve(here, "../..");
const ankiSrc = process.env.ANKI_SRC || path.join(spike, "vendor/anki");
const ids = JSON.parse(fs.readFileSync(path.join(here, "../service-ids.json"), "utf8"));
const native = require(path.join(here, "../artifacts/hatto_rslib_napi.linux-x64-gnu.node"));
const snapshotPy = path.join(spike, "scripts/fidelity_snapshot.py");
const comparePy = path.join(spike, "scripts/fidelity_compare.py");
const work = process.env.HATTO_FIDELITY_DIR || fs.mkdtempSync(path.join(os.tmpdir(), "hatto-fidelity-"));
const originals = path.join(work, "originals");
fs.mkdirSync(originals, { recursive: true });

const protoRoot = path.join(ankiSrc, "proto");
const root = new protobuf.Root();
root.resolvePath = (_origin, target) => path.join(protoRoot, target);
await root.load(
  fs.readdirSync(path.join(protoRoot, "anki")).filter((name) => name.endsWith(".proto")).map((name) => `anki/${name}`),
);
const type = (name) => root.lookupType(name);
const IF_NEWER = 0;
const ALWAYS = 1;
const NEVER = 2;

function encode(typeName, payload) {
  const messageType = type(typeName);
  return Buffer.from(messageType.encode(messageType.create(payload)).finish());
}
function decode(typeName, bytes) {
  const messageType = type(typeName);
  return messageType.toObject(messageType.decode(bytes), { longs: String, enums: String, defaults: true });
}
function parseFailure(err) {
  const message = String(err?.message || err);
  const hex = message.match(/bytes_hex=([0-9a-f]*)/)?.[1];
  let decoded = null;
  if (hex) {
    try {
      decoded = decode("anki.backend.BackendError", Buffer.from(hex, "hex"));
    } catch (decodeErr) {
      decoded = { decodeError: String(decodeErr) };
    }
  }
  return { message, decoded };
}

async function openBackend() {
  return native.open(encode("anki.backend.BackendInit", { preferredLangs: ["en"], server: true }));
}
async function call(backend, service, method, payload) {
  const spec = ids.services[service];
  const methodIndex = spec.methods[method];
  if (methodIndex === undefined) throw new Error(`missing ${service}.${method}`);
  return Buffer.from(await backend.run(spec.index, methodIndex, Buffer.from(payload)));
}
async function openCollection(backend, dir) {
  fs.mkdirSync(path.join(dir, "media"), { recursive: true });
  await call(
    backend,
    "backend_collection_service",
    "open_collection",
    encode("anki.collection.OpenCollectionRequest", {
      collectionPath: path.join(dir, "collection.anki2"),
      mediaFolderPath: path.join(dir, "media"),
      mediaDbPath: path.join(dir, "media.mdb"),
    }),
  );
}
async function closeBackend(backend) {
  try {
    await call(
      backend,
      "backend_collection_service",
      "close_collection",
      encode("anki.collection.CloseCollectionRequest", { downgradeToSchema11: false }),
    );
  } catch {
    /* already closed */
  }
  await backend.close();
}
async function withCollection(dir, fn) {
  const backend = await openBackend();
  try {
    await openCollection(backend, dir);
    return await fn(backend);
  } finally {
    await closeBackend(backend);
  }
}

const PNG = Buffer.from(
  "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==",
  "base64",
);
function wavSilence() {
  const samples = 160;
  const data = Buffer.alloc(44 + samples * 2);
  data.write("RIFF", 0);
  data.writeUInt32LE(36 + samples * 2, 4);
  data.write("WAVEfmt ", 8);
  data.writeUInt32LE(16, 16);
  data.writeUInt16LE(1, 20);
  data.writeUInt16LE(1, 22);
  data.writeUInt32LE(8000, 24);
  data.writeUInt32LE(16000, 28);
  data.writeUInt16LE(2, 32);
  data.writeUInt16LE(16, 34);
  data.write("data", 36);
  data.writeUInt32LE(samples * 2, 40);
  return data;
}

async function notetypeIdByName(backend, name) {
  const bytes = await call(
    backend,
    "backend_notetypes_service",
    "get_notetype_id_by_name",
    encode("anki.generic.String", { val: name }),
  );
  return decode("anki.notetypes.NotetypeId", bytes).ntid;
}
async function ensureDeck(backend, name) {
  const created = decode(
    "anki.decks.Deck",
    await call(backend, "backend_decks_service", "new_deck", encode("anki.generic.Empty", {})),
  );
  created.name = name;
  created.id = "0";
  const added = decode(
    "anki.collection.OpChangesWithId",
    await call(backend, "backend_decks_service", "add_deck", encode("anki.decks.Deck", created)),
  );
  return added.id;
}
async function addNote(backend, notetypeId, fields, deckId, tags = [], guid = "") {
  const fresh = decode(
    "anki.notes.Note",
    await call(
      backend,
      "backend_notes_service",
      "new_note",
      encode("anki.notetypes.NotetypeId", { ntid: notetypeId }),
    ),
  );
  fresh.fields = fields;
  fresh.tags = tags;
  fresh.id = "0";
  if (guid) fresh.guid = guid;
  const added = decode(
    "anki.notes.AddNoteResponse",
    await call(
      backend,
      "backend_notes_service",
      "add_note",
      encode("anki.notes.AddNoteRequest", { note: fresh, deckId }),
    ),
  );
  return decode(
    "anki.notes.Note",
    await call(backend, "backend_notes_service", "get_note", encode("anki.notes.NoteId", { nid: added.noteId })),
  );
}
async function addMedia(backend, name, bytes) {
  const stored = decode(
    "anki.generic.String",
    await call(
      backend,
      "backend_media_service",
      "add_media_file",
      encode("anki.media.AddMediaFileRequest", { desiredName: name, data: bytes }),
    ),
  );
  return stored.val;
}
async function exportApkg(backend, outPath, flags) {
  const bytes = await call(
    backend,
    "backend_import_export_service",
    "export_anki_package",
    encode("anki.import_export.ExportAnkiPackageRequest", {
      outPath,
      options: {
        withScheduling: Boolean(flags.withScheduling),
        withDeckConfigs: Boolean(flags.withDeckConfigs),
        withMedia: flags.withMedia !== false,
        legacy: Boolean(flags.legacy),
      },
      limit: { wholeCollection: {} },
    }),
  );
  return decode("anki.generic.UInt32", bytes).val;
}
async function importApkg(backend, packagePath, flags = {}) {
  const bytes = await call(
    backend,
    "backend_import_export_service",
    "import_anki_package",
    encode("anki.import_export.ImportAnkiPackageRequest", {
      packagePath,
      options: {
        mergeNotetypes: flags.mergeNotetypes !== false,
        updateNotes: flags.updateNotes ?? IF_NEWER,
        updateNotetypes: flags.updateNotetypes ?? IF_NEWER,
        withScheduling: Boolean(flags.withScheduling),
        withDeckConfigs: Boolean(flags.withDeckConfigs),
      },
    }),
  );
  const response = decode("anki.import_export.ImportResponse", bytes);
  const log = response.log || {};
  const count = (key) => (log[key] || []).length;
  return {
    foundNotes: log.foundNotes ?? null,
    new: count("new"),
    updated: count("updated"),
    duplicate: count("duplicate"),
    conflicting: count("conflicting"),
    newGuids: (log.new || []).map((note) => note.fields),
    updatedFields: (log.updated || []).map((note) => note.fields),
  };
}
async function answerFirst(backend) {
  await call(backend, "backend_decks_service", "set_current_deck", encode("anki.decks.DeckId", { did: "1" }));
  const queuedBytes = await call(
    backend,
    "backend_scheduler_service",
    "get_queued_cards",
    encode("anki.scheduler.GetQueuedCardsRequest", { fetchLimit: 1, intradayLearningOnly: false }),
  );
  const queuedMsg = type("anki.scheduler.QueuedCards").decode(queuedBytes);
  const queued = decode("anki.scheduler.QueuedCards", queuedBytes);
  if (!(queued.cards || []).length) return { answered: false };
  const card = queued.cards[0];
  const cardMsg = queuedMsg.cards[0];
  await call(
    backend,
    "backend_scheduler_service",
    "answer_card",
    encode("anki.scheduler.CardAnswer", {
      cardId: card.card.id,
      currentState: cardMsg.states.current,
      newState: cardMsg.states.good,
      rating: "GOOD",
      answeredAtMillis: String(Date.now()),
      millisecondsTaken: 400,
    }),
  );
  return { answered: true, cardId: card.card.id };
}
async function searchNotes(backend, search) {
  const found = decode(
    "anki.search.SearchResponse",
    await call(
      backend,
      "backend_search_service",
      "search_notes",
      encode("anki.search.SearchRequest", { search }),
    ),
  );
  const notes = [];
  for (const nid of found.ids || []) {
    notes.push(
      decode(
        "anki.notes.Note",
        await call(backend, "backend_notes_service", "get_note", encode("anki.notes.NoteId", { nid })),
      ),
    );
  }
  return notes;
}

function snap(file) {
  const run = spawnSync("python3", [snapshotPy, file], { encoding: "utf8" });
  if (run.status !== 0) throw new Error(`snapshot ${file}: ${run.stderr || run.stdout}`);
  return JSON.parse(run.stdout);
}
function compare(a, b) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "hatto-cmp-"));
  const left = path.join(dir, "a.json");
  const right = path.join(dir, "b.json");
  fs.writeFileSync(left, JSON.stringify(a));
  fs.writeFileSync(right, JSON.stringify(b));
  const run = spawnSync("python3", [comparePy, left, right], { encoding: "utf8" });
  if (run.status !== 0) throw new Error(run.stderr || run.stdout);
  return JSON.parse(run.stdout);
}
function summarize(diff) {
  const n = diff.notes;
  const c = diff.cards;
  return {
    notes: `${n.dst}/${n.src}`,
    missing: n.missing_guids,
    extra: n.extra_guids,
    fieldMismatch: n.field_mismatch.length,
    tagMismatch: n.tag_mismatch.length,
    noteIdChanged: n.id_changed.length,
    midChanged: n.mid_changed.length,
    mtimeChanged: n.mtime_changed.length,
    usnChanged: n.usn_changed.length,
    csumChanged: n.csum_changed.length,
    sfldChanged: n.sfld_changed.length,
    cardMissing: c.missing.length,
    cardExtra: c.extra.length,
    cardIdChanged: c.id_changed.length,
    cardDeckChanged: c.deck_id_changed.length,
    scheduleDiffs: c.schedule_or_state_diff.length,
    notetypeMissing: diff.notetypes.missing,
    notetypeExtra: diff.notetypes.extra,
    notetypeIdChanged: diff.notetypes.id_changed.map((item) => item.name),
    notetypeSchema: diff.notetypes.schema_mismatch.length,
    deckMissing: diff.decks.missing,
    deckExtra: diff.decks.extra,
    deckIdChanged: diff.decks.id_changed.map((item) => item.name),
    mediaMissing: diff.media.missing,
    mediaExtra: diff.media.extra,
    mediaHash: diff.media.hash_mismatch.length,
    revlog: diff.revlog,
  };
}

const HATTO_EXPORT = { withScheduling: false, withDeckConfigs: false, withMedia: true, legacy: false };
const OPTION_MATRIX = [
  ["hatto", HATTO_EXPORT],
  ["no-media", { ...HATTO_EXPORT, withMedia: false }],
  ["with-scheduling", { withScheduling: true, withDeckConfigs: true, withMedia: true, legacy: false }],
  ["legacy", { ...HATTO_EXPORT, legacy: true }],
];

async function buildSamples() {
  const dir = path.join(work, "src-rich");
  const manifest = { guids: {}, notetypes: {}, media: {} };
  await withCollection(dir, async (backend) => {
    const basic = await notetypeIdByName(backend, "Basic");
    const reversedId = await notetypeIdByName(backend, "Basic (and reversed card)");
    const clozeId = await notetypeIdByName(backend, "Cloze");
    const reversedNt = decode(
      "anki.notetypes.Notetype",
      await call(backend, "backend_notetypes_service", "get_notetype", encode("anki.notetypes.NotetypeId", { ntid: reversedId })),
    );
    const clozeNt = decode(
      "anki.notetypes.Notetype",
      await call(backend, "backend_notetypes_service", "get_notetype", encode("anki.notetypes.NotetypeId", { ntid: clozeId })),
    );
    manifest.notetypes = {
      basic,
      reversed: { id: reversedId, templates: (reversedNt.templates || []).map((t) => t.name), kind: reversedNt.config?.kind },
      cloze: { id: clozeId, templates: (clozeNt.templates || []).map((t) => t.name), fields: (clozeNt.fields || []).map((f) => f.name), kind: clozeNt.config?.kind },
    };
    const korean = await ensureDeck(backend, "Languages::한국어");
    const child = await ensureDeck(backend, "Languages::한국어::Hangul");
    manifest.decks = { korean, child };

    const long = "가".repeat(4000) + "<b>end</b>";
    const notes = [];
    notes.push(await addNote(backend, basic, ["hello", "world"], "1", ["custom", "custom::child"]));
    notes.push(
      await addNote(
        backend,
        basic,
        [`한글 日本語 café 🇺🇸 <b>bold</b> &amp;`, `עברית <script>no</script>`],
        "1",
        ["marked", "leech", "유니코드"],
      ),
    );
    notes.push(await addNote(backend, basic, [long, "tail"], "1", []));
    notes.push(await addNote(backend, basic, ["odd-guid", "kept"], "1", [], "odd guid 한글 \"quote\" \\"));
    notes.push(await addNote(backend, reversedId, ["front-rev", "back-rev"], korean, ["reversed"]));
    notes.push(await addNote(backend, clozeId, ["{{c1::숨김}} 그리고 {{c2::둘째}}", "extra"], child, ["cloze"]));
    const imageName = await addMedia(backend, "pixel.png", PNG);
    const audioName = await addMedia(backend, "beep.wav", wavSilence());
    manifest.media = { imageName, audioName };
    notes.push(
      await addNote(
        backend,
        basic,
        [`<img src="${imageName}">`, `[sound:${audioName}]`],
        "1",
        ["media"],
      ),
    );

    const basicNt = decode(
      "anki.notetypes.Notetype",
      await call(backend, "backend_notetypes_service", "get_notetype", encode("anki.notetypes.NotetypeId", { ntid: basic })),
    );
    basicNt.name = "Hatto";
    basicNt.id = "0";
    basicNt.fields.push({ name: "Extra", ord: { val: basicNt.fields.length } });
    const hattoAdded = decode(
      "anki.collection.OpChangesWithId",
      await call(backend, "backend_notetypes_service", "add_notetype", encode("anki.notetypes.Notetype", basicNt)),
    );
    manifest.notetypes.hatto = hattoAdded.id;
    notes.push(await addNote(backend, hattoAdded.id, ["has-extra", "back", "third"], "1", ["extra-field"]));

    await answerFirst(backend);
    manifest.guids = Object.fromEntries(notes.map((note) => [note.guid, { fields: note.fields, tags: note.tags, notetypeId: note.notetypeId }]));
    manifest.noteCount = notes.length;
    await exportApkg(backend, path.join(originals, "rich.apkg"), HATTO_EXPORT);
    await exportApkg(backend, path.join(originals, "rich-with-scheduling.apkg"), {
      withScheduling: true,
      withDeckConfigs: true,
      withMedia: true,
    });
  });
  // Copy the closed collection snapshot via a scheduling-true export already written.
  // Also publish the source collection file for id/mtime comparison.
  fs.copyFileSync(path.join(dir, "collection.anki2"), path.join(work, "src-rich.anki2"));
  fs.cpSync(path.join(dir, "media"), path.join(work, "src-rich.media"), { recursive: true });
  return manifest;
}

async function roundtripOne(name, apkg, flags) {
  const out = path.join(work, "round", `${name}.apkg`);
  fs.mkdirSync(path.dirname(out), { recursive: true });
  const importedDir = path.join(work, "round", name);
  let log = null;
  await withCollection(importedDir, async (backend) => {
    log = await importApkg(backend, apkg, {
      withScheduling: Boolean(flags.withScheduling),
      withDeckConfigs: Boolean(flags.withDeckConfigs),
    });
    await exportApkg(backend, out, flags);
  });
  const srcSnap = snap(apkg);
  const dstSnap = snap(out);
  const diff = compare(srcSnap, dstSnap);
  return {
    name,
    flags,
    importLog: log,
    schema: { src: srcSnap.schema, dst: dstSnap.schema },
    summary: summarize(diff),
    diff,
  };
}

async function mutateAndReimport(baseApkg) {
  const appDir = path.join(work, "app-napi");
  const changed = path.join(work, "app-napi-changed.apkg");
  const actions = {};
  await withCollection(appDir, async (backend) => {
    await importApkg(backend, baseApkg, HATTO_EXPORT);
    const notes = await searchNotes(backend, "deck:*");
    const editable = notes.find((note) => (note.fields || [])[0] === "hello");
    const basicNtNow = decode(
      "anki.notetypes.Notetype",
      await call(backend, "backend_notetypes_service", "get_notetype", encode("anki.notetypes.NotetypeId", { ntid: editable.notetypeId })),
    );
    while (editable.fields.length < (basicNtNow.fields || []).length) editable.fields.push("");
    await sleep(1100);
    editable.fields[0] = "hello-edited";
    editable.tags = ["custom", "renamed-tag"];
    await call(
      backend,
      "backend_notes_service",
      "update_notes",
      encode("anki.notes.UpdateNotesRequest", { notes: [editable], skipUndoEntry: false }),
    );
    actions.editedGuid = editable.guid;
    const basic = await notetypeIdByName(backend, "Basic");
    const added = await addNote(backend, basic, ["brand-new", "from-app"], "1", ["added"]);
    actions.addedGuid = added.guid;
    const victim = notes.find((note) => (note.fields || [])[0] === "odd-guid");
    actions.deletedGuid = victim?.guid || null;
    if (victim) {
      await call(
        backend,
        "backend_notes_service",
        "remove_notes",
        encode("anki.notes.RemoveNotesRequest", { noteIds: [victim.id], cardIds: [] }),
      );
    }
    const hattoNote = notes.find((note) => (note.fields || [])[0] === "has-extra");
    const nt = decode(
      "anki.notetypes.Notetype",
      await call(
        backend,
        "backend_notetypes_service",
        "get_notetype",
        encode("anki.notetypes.NotetypeId", { ntid: hattoNote.notetypeId }),
      ),
    );
    const beforeNames = (nt.fields || []).map((field) => field.name);
    nt.fields = (nt.fields || []).filter((field) => field.name !== "Extra");
    nt.fields.push({ name: "AddedLater", ord: { val: nt.fields.length } });
    let after = null;
    try {
      await call(backend, "backend_notetypes_service", "update_notetype", encode("anki.notetypes.Notetype", nt));
      after = decode(
        "anki.notetypes.Notetype",
        await call(
          backend,
          "backend_notetypes_service",
          "get_notetype",
          encode("anki.notetypes.NotetypeId", { ntid: hattoNote.notetypeId }),
        ),
      );
      actions.notetype = { beforeNames, afterNames: (after.fields || []).map((field) => field.name), updateError: null };
    } catch (err) {
      actions.notetype = { beforeNames, updateError: parseFailure(err) };
    }
    try {
      if (!after) throw new Error("skipped resize");
      const wanted = actions.notetype.afterNames.length;
      const all = await searchNotes(backend, "deck:*");
      const hattoId = String(hattoNote.notetypeId);
      const resized = all.filter((note) => String(note.notetypeId) === hattoId);
      for (const note of resized) {
        const fields = [...(note.fields || [])];
        while (fields.length < wanted) fields.push("");
        note.fields = fields.slice(0, wanted);
      }
      if (resized.length) {
        await call(
          backend,
          "backend_notes_service",
          "update_notes",
          encode("anki.notes.UpdateNotesRequest", { notes: resized, skipUndoEntry: true }),
        );
      }
    } catch (err) {
      actions.notetype.resizeError = parseFailure(err);
    }
    await exportApkg(backend, changed, HATTO_EXPORT);
  });

  const serverResults = [];
  for (const updateNotes of [IF_NEWER, ALWAYS, NEVER]) {
    const serverDir = path.join(work, `server-u${updateNotes}`);
    fs.cpSync(path.join(work, "src-rich"), serverDir, { recursive: true });
    // src-rich was closed; reopen the copied collection by importing into a fresh one that
    // already contains the original package, so the deleted guid still exists.
    const fresh = path.join(work, `server-fresh-u${updateNotes}`);
    let ontoOriginal = null;
    let ontoEmpty = null;
    await withCollection(fresh, async (backend) => {
      await importApkg(backend, path.join(originals, "rich-with-scheduling.apkg"), {
        withScheduling: true,
        withDeckConfigs: true,
      });
      ontoOriginal = await importApkg(backend, changed, { ...HATTO_EXPORT, updateNotes, updateNotetypes: updateNotes });
      const remaining = await searchNotes(backend, "deck:*");
      ontoOriginal.guidsAfter = remaining.map((note) => note.guid);
      ontoOriginal.deletedStillPresent = actions.deletedGuid
        ? remaining.some((note) => note.guid === actions.deletedGuid)
        : null;
      ontoOriginal.addedPresent = remaining.some((note) => note.guid === actions.addedGuid);
      const edited = remaining.find((note) => note.guid === actions.editedGuid);
      ontoOriginal.editedFields = edited?.fields || null;
      ontoOriginal.editedTags = edited?.tags || null;
      const names = decode(
        "anki.notetypes.NotetypeNames",
        await call(backend, "backend_notetypes_service", "get_notetype_names", encode("anki.generic.Empty", {})),
      );
      ontoOriginal.notetypeNames = (names.entries || []).map((entry) => entry.name);
    });
    const emptyDir = path.join(work, `server-empty-u${updateNotes}`);
    await withCollection(emptyDir, async (backend) => {
      ontoEmpty = await importApkg(backend, changed, { ...HATTO_EXPORT, updateNotes, updateNotetypes: updateNotes });
      const remaining = await searchNotes(backend, "deck:*");
      ontoEmpty.guidCount = remaining.length;
      ontoEmpty.deletedPresent = actions.deletedGuid
        ? remaining.some((note) => note.guid === actions.deletedGuid)
        : null;
    });
    serverResults.push({ updateNotes, ontoOriginal, ontoEmpty });
  }

  // Bidirectional: server imports app package into empty, exports, app-side reimport into the mutated app collection.
  const serverEmpty = path.join(work, "bidi-server");
  const serverExport = path.join(work, "bidi-server.apkg");
  await withCollection(serverEmpty, async (backend) => {
    await importApkg(backend, changed, HATTO_EXPORT);
    await exportApkg(backend, serverExport, HATTO_EXPORT);
  });
  const appAgain = path.join(work, "bidi-app");
  fs.cpSync(appDir, appAgain, { recursive: true });
  let bidi = null;
  await withCollection(appAgain, async (backend) => {
    bidi = await importApkg(backend, serverExport, HATTO_EXPORT);
    const notes = await searchNotes(backend, "deck:*");
    bidi.guidCount = notes.length;
    bidi.uniqueGuids = new Set(notes.map((note) => note.guid)).size;
  });
  const emptySnap = snap(changed);
  const backSnap = snap(serverExport);
  return {
    actions,
    serverResults,
    bidirectional: { importLog: bidi, compareAppExportToServerExport: summarize(compare(emptySnap, backSnap)) },
  };
}

function copyPublicSamples() {
  const support = path.join(ankiSrc, "pylib/tests/support");
  const copied = [];
  for (const name of ["media.apkg", "update1.apkg", "update2.apkg", "diffmodels2-1.apkg"]) {
    const src = path.join(support, name);
    if (!fs.existsSync(src)) continue;
    const dest = path.join(originals, `public-${name}`);
    fs.copyFileSync(src, dest);
    copied.push(dest);
  }
  return copied;
}

async function phaseBuild() {
  const manifest = await buildSamples();
  fs.writeFileSync(path.join(work, "manifest.json"), JSON.stringify(manifest, null, 2));
  const publicFiles = copyPublicSamples();
  const targets = [path.join(originals, "rich.apkg"), path.join(originals, "rich-with-scheduling.apkg"), ...publicFiles];
  const rounds = [];
  for (const apkg of targets) {
    for (const [label, flags] of OPTION_MATRIX) {
      const name = `${path.basename(apkg, ".apkg")}__${label}`;
      try {
        rounds.push({ apkg: path.basename(apkg), ...(await roundtripOne(name, apkg, flags)) });
        console.log("PASS", name);
      } catch (err) {
        rounds.push({ apkg: path.basename(apkg), name, error: parseFailure(err) });
        console.log("FAIL", name, parseFailure(err).message.slice(0, 240));
      }
    }
  }
  let mutation = null;
  try {
    mutation = await mutateAndReimport(path.join(originals, "rich-with-scheduling.apkg"));
    console.log("PASS mutation");
  } catch (err) {
    mutation = { error: parseFailure(err) };
    console.log("FAIL mutation", parseFailure(err).message.slice(0, 400));
  }
  const report = { work, manifest, rounds, mutation };
  const out = path.join(spike, "results/napi-fidelity.json");
  fs.mkdirSync(path.dirname(out), { recursive: true });
  fs.writeFileSync(out, JSON.stringify(report, null, 2));
  fs.writeFileSync(path.join(work, "napi-fidelity.json"), JSON.stringify(report, null, 2));
  console.log("wrote", out);
  console.log("work", work);
}

async function phaseServer() {
  const changed = path.join(work, "app-frb-changed.apkg");
  const frbManifestPath = path.join(work, "frb-manifest.json");
  if (!fs.existsSync(changed)) {
    const out = path.join(spike, "results/server-from-frb.json");
    fs.writeFileSync(out, JSON.stringify({ error: `missing ${changed}` }, null, 2));
    console.log("FAIL missing FRB export", changed);
    process.exitCode = 1;
    return;
  }
  const frbManifest = fs.existsSync(frbManifestPath) ? JSON.parse(fs.readFileSync(frbManifestPath, "utf8")) : {};
  const base = path.join(originals, "rich-with-scheduling.apkg");
  const results = [];
  for (const updateNotes of [IF_NEWER, ALWAYS, NEVER]) {
    const dir = path.join(work, `frb-server-u${updateNotes}`);
    let log = null;
    await withCollection(dir, async (backend) => {
      await importApkg(backend, base, { withScheduling: true, withDeckConfigs: true });
      log = await importApkg(backend, changed, { ...HATTO_EXPORT, updateNotes, updateNotetypes: updateNotes });
      const notes = await searchNotes(backend, "deck:*");
      log.guidCount = notes.length;
      log.deletedStillPresent = frbManifest.deletedGuid
        ? notes.some((note) => note.guid === frbManifest.deletedGuid)
        : null;
      log.addedPresent = frbManifest.addedGuid ? notes.some((note) => note.guid === frbManifest.addedGuid) : null;
      const edited = notes.find((note) => note.guid === frbManifest.editedGuid);
      log.editedFields = edited?.fields || null;
      log.editedTags = edited?.tags || null;
      const names = decode(
        "anki.notetypes.NotetypeNames",
        await call(backend, "backend_notetypes_service", "get_notetype_names", encode("anki.generic.Empty", {})),
      );
      log.notetypeNames = (names.entries || []).map((entry) => entry.name);
    });
    results.push({ updateNotes, log });
    console.log("server", updateNotes, JSON.stringify(log).slice(0, 300));
  }
  const serverExport = path.join(work, "frb-server-reexport.apkg");
  const empty = path.join(work, "frb-server-empty");
  await withCollection(empty, async (backend) => {
    await importApkg(backend, changed, HATTO_EXPORT);
    await exportApkg(backend, serverExport, HATTO_EXPORT);
  });
  const appAgain = path.join(work, "frb-app-again");
  // The FRB test leaves its mutated collection at work/frb-app.
  const appSrc = path.join(work, "frb-app");
  let bidi = { skipped: !fs.existsSync(path.join(appSrc, "collection.anki2")) };
  if (!bidi.skipped) {
    fs.cpSync(appSrc, appAgain, { recursive: true });
    await withCollection(appAgain, async (backend) => {
      const log = await importApkg(backend, serverExport, HATTO_EXPORT);
      const notes = await searchNotes(backend, "deck:*");
      bidi = { importLog: log, guidCount: notes.length, uniqueGuids: new Set(notes.map((note) => note.guid)).size };
    });
  }
  const report = {
    frbManifest,
    serverResults: results,
    bidirectional: bidi,
    compare: summarize(compare(snap(changed), snap(serverExport))),
  };
  const out = path.join(spike, "results/server-from-frb.json");
  fs.writeFileSync(out, JSON.stringify(report, null, 2));
  console.log("wrote", out);
}

const phase = process.argv.includes("--phase=server") ? "server" : "build";
if (phase === "server") await phaseServer();
else await phaseBuild();
