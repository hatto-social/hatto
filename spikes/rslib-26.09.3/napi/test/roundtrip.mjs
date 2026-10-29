/**
 * Node scenarios for the napi protobuf bridge.
 * Requires artifacts/hatto_rslib_napi.linux-x64-gnu.node, service-ids.json,
 * and vendor/anki/proto (fetched, not committed).
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
const inspectScript = path.join(spike, "scripts/inspect-apkg.py");

const protoRoot = path.join(ankiSrc, "proto");
const protoRootObj = new protobuf.Root();
protoRootObj.resolvePath = (_origin, target) => path.join(protoRoot, target);
await protoRootObj.load(
  fs
    .readdirSync(path.join(protoRoot, "anki"))
    .filter((name) => name.endsWith(".proto"))
    .map((name) => `anki/${name}`),
);
const root = protoRootObj;
const type = (name) => root.lookupType(name);

const results = [];
const work = fs.mkdtempSync(path.join(os.tmpdir(), "hatto-napi-"));

function record(name, status, detail) {
  results.push({ name, status, ...detail });
  const mark = status === "pass" ? "PASS" : "FAIL";
  console.log(`\n[${mark}] ${name}`);
  console.log(JSON.stringify(detail, null, 2).slice(0, 4000));
}

function assert(cond, message) {
  if (!cond) throw new Error(message);
}

function encode(typeName, payload) {
  const messageType = type(typeName);
  return Buffer.from(messageType.encode(messageType.create(payload)).finish());
}

function decode(typeName, bytes) {
  const messageType = type(typeName);
  return messageType.toObject(messageType.decode(bytes), {
    longs: String,
    enums: String,
    defaults: true,
  });
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
  const init = encode("anki.backend.BackendInit", {
    preferredLangs: ["en"],
    server: true,
  });
  return native.open(init);
}

async function call(backend, service, method, payloadBytes) {
  const spec = ids.services[service];
  if (!spec) throw new Error(`unknown service ${service}`);
  const methodIndex = spec.methods[method];
  if (methodIndex === undefined) {
    throw new Error(`unknown method ${service}.${method}`);
  }
  return Buffer.from(await backend.run(spec.index, methodIndex, Buffer.from(payloadBytes)));
}

async function openCollection(backend, dir) {
  fs.mkdirSync(dir, { recursive: true });
  const media = path.join(dir, "media");
  fs.mkdirSync(media, { recursive: true });
  await call(
    backend,
    "backend_collection_service",
    "open_collection",
    encode("anki.collection.OpenCollectionRequest", {
      collectionPath: path.join(dir, "collection.anki2"),
      mediaFolderPath: media,
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
    // Collection may already be closed, or open itself failed.
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

async function basicNotetypeId(backend) {
  const bytes = await call(
    backend,
    "backend_notetypes_service",
    "get_notetype_id_by_name",
    encode("anki.generic.String", { val: "Basic" }),
  );
  return decode("anki.notetypes.NotetypeId", bytes);
}

async function addBasic(backend, front, back) {
  const notetype = await basicNotetypeId(backend);
  const fresh = decode(
    "anki.notes.Note",
    await call(
      backend,
      "backend_notes_service",
      "new_note",
      encode("anki.notetypes.NotetypeId", { ntid: notetype.ntid }),
    ),
  );
  fresh.fields = [front, back];
  fresh.id = "0";
  const added = decode(
    "anki.notes.AddNoteResponse",
    await call(
      backend,
      "backend_notes_service",
      "add_note",
      encode("anki.notes.AddNoteRequest", { note: fresh, deckId: "1" }),
    ),
  );
  const stored = decode(
    "anki.notes.Note",
    await call(
      backend,
      "backend_notes_service",
      "get_note",
      encode("anki.notes.NoteId", { nid: added.noteId }),
    ),
  );
  return stored;
}

async function addMany(backend, count) {
  const notetype = await basicNotetypeId(backend);
  const fresh = decode(
    "anki.notes.Note",
    await call(
      backend,
      "backend_notes_service",
      "new_note",
      encode("anki.notetypes.NotetypeId", { ntid: notetype.ntid }),
    ),
  );
  const requests = [];
  for (let i = 0; i < count; i += 1) {
    requests.push({
      note: { ...fresh, id: "0", guid: "", fields: [`front ${i}`, `back ${i}`], tags: [] },
      deckId: "1",
    });
  }
  return decode(
    "anki.notes.AddNotesResponse",
    await call(
      backend,
      "backend_notes_service",
      "add_notes",
      encode("anki.notes.AddNotesRequest", { requests }),
    ),
  );
}

function exportOptions(flags) {
  return {
    withScheduling: Boolean(flags.withScheduling),
    withDeckConfigs: Boolean(flags.withDeckConfigs),
    withMedia: Boolean(flags.withMedia),
    legacy: false,
  };
}

async function exportApkg(backend, outPath, flags) {
  const bytes = await call(
    backend,
    "backend_import_export_service",
    "export_anki_package",
    encode("anki.import_export.ExportAnkiPackageRequest", {
      outPath,
      options: exportOptions(flags),
      limit: { wholeCollection: {} },
    }),
  );
  return decode("anki.generic.UInt32", bytes).val;
}

async function importApkg(backend, packagePath, flags) {
  const bytes = await call(
    backend,
    "backend_import_export_service",
    "import_anki_package",
    encode("anki.import_export.ImportAnkiPackageRequest", {
      packagePath,
      options: {
        mergeNotetypes: flags.mergeNotetypes !== false,
        updateNotes: flags.updateNotes ?? "IMPORT_ANKI_PACKAGE_UPDATE_CONDITION_IF_NEWER",
        updateNotetypes: flags.updateNotetypes ?? "IMPORT_ANKI_PACKAGE_UPDATE_CONDITION_IF_NEWER",
        withScheduling: Boolean(flags.withScheduling),
        withDeckConfigs: Boolean(flags.withDeckConfigs),
      },
    }),
  );
  return decode("anki.import_export.ImportResponse", bytes);
}

function logCounts(response) {
  const log = response.log || {};
  const count = (key) => (log[key] || []).length;
  return {
    foundNotes: log.foundNotes ?? null,
    new: count("new"),
    updated: count("updated"),
    duplicate: count("duplicate"),
    conflicting: count("conflicting"),
  };
}

function inspect(apkg) {
  const run = spawnSync("python3", [inspectScript, apkg], { encoding: "utf8" });
  if (run.status !== 0) {
    throw new Error(`inspect-apkg failed: ${run.stderr || run.stdout}`);
  }
  return JSON.parse(run.stdout);
}

function fieldSet(pkg) {
  return pkg.notes.map((note) => note.flds.join(" / ")).sort();
}

async function scenarioRoundtrip() {
  const src = path.join(work, "roundtrip-src");
  const dst = path.join(work, "roundtrip-dst");
  const apkg = path.join(work, "roundtrip.apkg");
  const again = path.join(work, "roundtrip-again.apkg");
  let exportedNotes = null;
  await withCollection(src, async (backend) => {
    await addBasic(backend, "hello", "world");
    await addBasic(backend, "alpha", "beta");
    exportedNotes = await exportApkg(backend, apkg, {});
  });
  const imported = await withCollection(dst, async (backend) => {
    const response = await importApkg(backend, apkg, {});
    const reexported = await exportApkg(backend, again, {});
    return { response, reexported };
  });
  const first = inspect(apkg);
  const second = inspect(again);
  assert(exportedNotes === 2 || exportedNotes === "2", `export count ${exportedNotes}`);
  assert(logCounts(imported.response).new === 2, JSON.stringify(logCounts(imported.response)));
  assert(JSON.stringify(fieldSet(first)) === JSON.stringify(["alpha / beta", "hello / world"]), JSON.stringify(first.notes));
  assert(JSON.stringify(fieldSet(first)) === JSON.stringify(fieldSet(second)), "reimport export fields differ");
  assert(first.revlog_count === 0, `revlog leaked into default export: ${first.revlog_count}`);
  return { exportedNotes, counts: logCounts(imported.response), fields: fieldSet(second), schema: first.schema, entries: first.entries };
}

async function scenarioGuidMerge() {
  const src = path.join(work, "guid-src");
  const dst = path.join(work, "guid-dst");
  const older = path.join(work, "older.apkg");
  const newer = path.join(work, "newer.apkg");
  await withCollection(src, async (backend) => {
    const note = await addBasic(backend, "hello", "world");
    await exportApkg(backend, older, {});
    // Note mtime is second resolution. IfNewer needs the edited package to be
    // strictly newer, so the edit must fall in a later unix second.
    await sleep(1100);
    note.fields = ["goodbye", "world"];
    await call(
      backend,
      "backend_notes_service",
      "update_notes",
      encode("anki.notes.UpdateNotesRequest", { notes: [note], skipUndoEntry: false }),
    );
    await exportApkg(backend, newer, {});
  });
  const steps = [];
  await withCollection(dst, async (backend) => {
    const recordStep = async (label, file, flags) => {
      const response = await importApkg(backend, file, flags);
      const counts = logCounts(response);
      const sample = (response.log?.updated?.[0] || response.log?.new?.[0] || response.log?.duplicate?.[0]);
      steps.push({ label, counts, sampleFields: sample?.fields || null });
    };
    await recordStep("import older", older, { updateNotes: 0 });
    await recordStep("import newer if_newer", newer, { updateNotes: 0 });
    await recordStep("reimport older if_newer", older, { updateNotes: 0 });
    await recordStep("reimport older always", older, { updateNotes: 1 });
    await recordStep("reimport newer never", newer, { updateNotes: 2 });
    const noteIds = decode(
      "anki.search.SearchResponse",
      await call(
        backend,
        "backend_search_service",
        "search_notes",
        encode("anki.search.SearchRequest", { search: "deck:Default" }),
      ),
    ).ids;
    assert(noteIds.length === 1, JSON.stringify(noteIds));
    const stored = decode(
      "anki.notes.Note",
      await call(
        backend,
        "backend_notes_service",
        "get_note",
        encode("anki.notes.NoteId", { nid: noteIds[0] }),
      ),
    );
    steps.push({ label: "stored after never", fields: stored.fields });
  });
  const byLabel = Object.fromEntries(steps.map((step) => [step.label, step]));
  assert(byLabel["import older"].counts.new === 1, JSON.stringify(byLabel["import older"]));
  assert(byLabel["import newer if_newer"].counts.updated === 1, JSON.stringify(byLabel["import newer if_newer"]));
  assert(
    JSON.stringify(byLabel["import newer if_newer"].sampleFields) === JSON.stringify(["goodbye", "world"]),
    JSON.stringify(byLabel["import newer if_newer"]),
  );
  assert(byLabel["reimport older if_newer"].counts.duplicate === 1, JSON.stringify(byLabel["reimport older if_newer"]));
  assert(byLabel["reimport older always"].counts.updated === 1, JSON.stringify(byLabel["reimport older always"]));
  assert(
    JSON.stringify(byLabel["reimport older always"].sampleFields) === JSON.stringify(["hello", "world"]),
    JSON.stringify(byLabel["reimport older always"]),
  );
  assert(byLabel["reimport newer never"].counts.duplicate === 1, JSON.stringify(byLabel["reimport newer never"]));
  assert(
    JSON.stringify(byLabel["stored after never"].fields) === JSON.stringify(["hello", "world"]),
    JSON.stringify(byLabel["stored after never"]),
  );
  return { steps };
}

async function answerOne(backend) {
  await call(
    backend,
    "backend_decks_service",
    "set_current_deck",
    encode("anki.decks.DeckId", { did: "1" }),
  );
  const queuedBytes = await call(
    backend,
    "backend_scheduler_service",
    "get_queued_cards",
    encode("anki.scheduler.GetQueuedCardsRequest", { fetchLimit: 1, intradayLearningOnly: false }),
  );
  const queuedMsg = type("anki.scheduler.QueuedCards").decode(queuedBytes);
  const queued = decode("anki.scheduler.QueuedCards", queuedBytes);
  assert((queued.cards || []).length === 1, `queue empty: ${JSON.stringify(queued).slice(0, 800)}`);
  const cardMsg = queuedMsg.cards[0];
  const card = queued.cards[0];
  const before = decode(
    "anki.cards.Card",
    await call(
      backend,
      "backend_cards_service",
      "get_card",
      encode("anki.cards.CardId", { cid: card.card.id }),
    ),
  );
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
  const after = decode(
    "anki.cards.Card",
    await call(
      backend,
      "backend_cards_service",
      "get_card",
      encode("anki.cards.CardId", { cid: card.card.id }),
    ),
  );
  return { before, after, queue: card.queue };
}

async function scenarioSchedulingAndStudy() {
  const src = path.join(work, "sched-src");
  const strippedDst = path.join(work, "sched-stripped");
  const keptDst = path.join(work, "sched-kept");
  const withSched = path.join(work, "with-sched.apkg");
  const withoutSched = path.join(work, "without-sched.apkg");
  const study = await withCollection(src, async (backend) => {
    await addBasic(backend, "study", "card");
    const cycle = await answerOne(backend);
    await exportApkg(backend, withSched, { withScheduling: true, withDeckConfigs: true });
    await exportApkg(backend, withoutSched, { withScheduling: false, withDeckConfigs: false });
    return cycle;
  });
  const keptFile = inspect(withSched);
  const strippedFile = inspect(withoutSched);
  const importedStripped = await withCollection(strippedDst, async (backend) => {
    const response = await importApkg(backend, withSched, { withScheduling: false, withDeckConfigs: false });
    const card = await cardAfterOnlyImport(backend);
    const reexport = path.join(work, "stripped-reexport.apkg");
    await exportApkg(backend, reexport, { withScheduling: true, withDeckConfigs: true });
    return { counts: logCounts(response), card, reexport: inspect(reexport) };
  });
  const importedKept = await withCollection(keptDst, async (backend) => {
    const response = await importApkg(backend, withSched, { withScheduling: true, withDeckConfigs: true });
    const card = await cardAfterOnlyImport(backend);
    return { counts: logCounts(response), card };
  });
  assert(keptFile.revlog_count >= 1, `with_scheduling export revlog ${keptFile.revlog_count}`);
  assert(strippedFile.revlog_count === 0, `without_scheduling export revlog ${strippedFile.revlog_count}`);
  assert(strippedFile.cards.length === 1, "stripped export lost the card");
  assert(strippedFile.cards[0].type === 0, `stripped card type ${strippedFile.cards[0].type}`);
  assert(strippedFile.cards[0].reps === 0, `stripped card reps ${strippedFile.cards[0].reps}`);
  assert(Number(importedStripped.card.reps) === 0, JSON.stringify(importedStripped.card));
  assert(Number(importedStripped.card.ctype) === 0, JSON.stringify(importedStripped.card));
  assert(Number(importedStripped.card.queue) === 0, JSON.stringify(importedStripped.card));
  assert(importedStripped.reexport.revlog_count === 0, `import kept revlog ${importedStripped.reexport.revlog_count}`);
  assert(Number(importedStripped.reexport.cards[0].reps) === 0, JSON.stringify(importedStripped.reexport.cards[0]));
  assert(String(importedKept.card.reps) === String(keptFile.cards[0].reps), JSON.stringify({
    imported: importedKept.card,
    file: keptFile.cards[0],
  }));
  assert(Number(importedKept.card.ctype) === Number(keptFile.cards[0].type), JSON.stringify(importedKept.card));
  assert(Number(study.after.reps) !== Number(study.before.reps) || study.after.queue !== study.before.queue, JSON.stringify(study));
  return {
    studyBefore: study.before,
    studyAfter: study.after,
    withSchedulingFile: summarizePkg(keptFile),
    withoutSchedulingFile: summarizePkg(strippedFile),
    importWithSchedulingFalse: {
      counts: importedStripped.counts,
      card: importedStripped.card,
      reexportRevlog: importedStripped.reexport.revlog_count,
      reexportCard: importedStripped.reexport.cards[0],
    },
    importWithSchedulingTrue: {
      counts: importedKept.counts,
      card: importedKept.card,
    },
  };
}

function summarizePkg(pkg) {
  return {
    entries: pkg.entries,
    collection: pkg.collection,
    schema: pkg.schema,
    revlog_count: pkg.revlog_count,
    deck_config_count: pkg.deck_config_count,
    notes: pkg.notes,
    cards: pkg.cards,
  };
}

async function cardAfterOnlyImport(backend) {
  const cardIds = decode(
    "anki.search.SearchResponse",
    await call(
      backend,
      "backend_search_service",
      "search_cards",
      encode("anki.search.SearchRequest", { search: "deck:Default" }),
    ),
  ).ids || [];
  // Fallback: the import log does not include card ids. Search if the index exists.
  if (cardIds.length) {
    return decode(
      "anki.cards.Card",
      await call(
        backend,
        "backend_cards_service",
        "get_card",
        encode("anki.cards.CardId", { cid: cardIds[0] }),
      ),
    );
  }
  throw new Error("search_cards returned no ids; service index may be missing");
}

async function scenarioSamePathLock() {
  const apkg = path.join(work, "lock.apkg");
  await withCollection(path.join(work, "lock-seed"), async (backend) => {
    await addBasic(backend, "lock", "note");
    await exportApkg(backend, apkg, {});
  });
  const dir = path.join(work, "locked-col");
  await withCollection(dir, async () => {});
  const settled = await Promise.allSettled(
    [0, 1, 2, 3].map(() =>
      withCollection(dir, (backend) => importApkg(backend, apkg, {})),
    ),
  );
  const ok = settled.filter((item) => item.status === "fulfilled");
  const bad = settled
    .filter((item) => item.status === "rejected")
    .map((item) => parseFailure(item.reason));
  assert(ok.length === 1, `expected 1 success, got ${ok.length}: ${JSON.stringify(bad).slice(0, 1500)}`);
  assert(bad.length === 3, `expected 3 failures, got ${bad.length}`);
  assert(
    bad.every((failure) => failure.decoded && (failure.decoded.kind === "DB_ERROR" || String(failure.decoded.message).includes("already open"))),
    JSON.stringify(bad).slice(0, 1500),
  );
  return { success: ok.length, failures: bad };
}

async function scenarioDifferentCollections() {
  const apkg = path.join(work, "parallel.apkg");
  await withCollection(path.join(work, "parallel-seed"), async (backend) => {
    await addBasic(backend, "parallel", "note");
    await exportApkg(backend, apkg, {});
  });
  const settled = await Promise.all(
    [0, 1, 2, 3].map((index) =>
      withCollection(path.join(work, `parallel-${index}`), (backend) => importApkg(backend, apkg, {})),
    ),
  );
  const counts = settled.map(logCounts);
  assert(counts.every((item) => item.new === 1), JSON.stringify(counts));
  return { counts };
}

async function scenarioEventLoop() {
  const apkg = path.join(work, "bulk.apkg");
  const count = 300;
  await withCollection(path.join(work, "bulk-seed"), async (backend) => {
    await addMany(backend, count);
    await exportApkg(backend, apkg, {});
  });
  let maxGapMs = 0;
  let last = Date.now();
  const timer = setInterval(() => {
    const now = Date.now();
    maxGapMs = Math.max(maxGapMs, now - last);
    last = now;
  }, 10);
  const started = Date.now();
  let imported = null;
  try {
    imported = await withCollection(path.join(work, "bulk-dst"), (backend) => importApkg(backend, apkg, {}));
  } finally {
    clearInterval(timer);
  }
  const elapsedMs = Date.now() - started;
  const counts = logCounts(imported);
  assert(counts.new === count, JSON.stringify(counts));
  return {
    notes: count,
    elapsedMs,
    maxTimerGapMs: maxGapMs,
    counts,
  };
}

async function run(name, fn) {
  try {
    const detail = await fn();
    record(name, "pass", { detail });
  } catch (err) {
    record(name, "fail", { error: String(err?.stack || err), parsed: parseFailure(err) });
  }
}

// search_cards is required by the scheduling import check. Fail early with the
// parsed service map if extract-service-ids.py did not see it.
if (!ids.services.backend_search_service?.methods?.search_cards) {
  console.error("service-ids.json is missing backend_search_service.search_cards");
  process.exit(2);
}

await run("import-export-roundtrip", scenarioRoundtrip);
await run("same-guid-reimport", scenarioGuidMerge);
await run("scheduling-exclusion-and-answer", scenarioSchedulingAndStudy);
await run("same-collection-path-concurrent", scenarioSamePathLock);
await run("different-collections-concurrent", scenarioDifferentCollections);
await run("event-loop-during-import", scenarioEventLoop);

const outPath = path.join(spike, "results/napi-roundtrip.json");
fs.mkdirSync(path.dirname(outPath), { recursive: true });
fs.writeFileSync(
  outPath,
  JSON.stringify({ work, ankiCommit: ids.ankiCommit, scenarios: results }, null, 2) + "\n",
);
console.log(`\nwrote ${outPath}`);
const failed = results.filter((item) => item.status !== "pass");
if (failed.length) {
  console.error(`${failed.length} scenario(s) failed`);
  process.exit(1);
}
