import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { after, before, beforeEach, test } from 'node:test';
import { Client } from 'pg';
import { HandleLru } from '../src/deck-store/handle-lru';
import {
  buildTempFile,
  countSqliteFds,
  fileBytes,
  holdReadTransaction,
  migrate,
  openDatabase,
  readFileSnapshot,
  sidecarBytes,
  userVersion,
} from '../src/deck-store/sqlite';
import { pgConfig } from '../src/pg-config';
import { sleep } from '../src/stats';
import {
  DATABASE_URL,
  closeHarness,
  createHarness,
  lastJson,
  makeDeck,
  publishInput,
  record,
  reset,
  runNode,
  type Harness,
} from './helpers';

let h: Harness;

before(async () => {
  h = await createHarness();
});

beforeEach(async () => {
  await reset(h);
});

after(async () => {
  await closeHarness(h);
});

test('handle LRU evicts idle files, keeps a pin, and allows one oversize file', async () => {
  const dir = path.join(h.root, 'lru');
  fs.mkdirSync(dir, { recursive: true });
  const files: string[] = [];
  for (let i = 0; i < 24; i++) {
    const tmp = path.join(dir, `.tmp-${i}.sqlite`);
    const final = path.join(dir, `f${i}.sqlite`);
    buildTempFile({
      tmpPath: tmp,
      previousPath: null,
      version: 1,
      mutation: { type: 'seed-cards', count: 1, idPrefix: `p${i}-` },
      seal: 'delete',
    });
    fs.renameSync(tmp, final);
    files.push(final);
  }
  const lru = new HandleLru(fileBytes(files[0]) * 4);
  const pinned = lru.open(files[0], 'ro');
  assert.ok(pinned);
  for (const file of files.slice(1)) {
    lru.open(file, 'ro');
    lru.unpin(file, 'ro');
  }
  const stats = lru.stats();
  record('lru-small', { ...stats, fds: countSqliteFds() });
  assert.ok(stats.evictions > 0);
  assert.ok(stats.handles < files.length);
  assert.equal(lru.isPinnedFile(files[0]), true);
  assert.ok(stats.handles <= 5);
  lru.unpin(files[0], 'ro');
  lru.closeAll();

  const bigTmp = path.join(dir, '.tmp-big.sqlite');
  const big = path.join(dir, 'big.sqlite');
  buildTempFile({
    tmpPath: bigTmp,
    previousPath: null,
    version: 1,
    mutation: { type: 'seed-cards', count: 400, idPrefix: 'big-' },
    seal: 'delete',
  });
  fs.renameSync(bigTmp, big);
  const tiny = new HandleLru(1024);
  tiny.open(big, 'ro');
  const over = tiny.stats();
  assert.equal(over.handles, 1);
  assert.equal(over.overCap, true);
  assert.ok(over.residentBytes > 1024);
  tiny.closeAll();
});

test('lazy migration on a shared file fights a reader; a copied version does not', async () => {
  const source = path.join(h.root, 'legacy.sqlite');
  h.decks.writeLegacy(source, 4);
  const reader = openDatabase(source, 'ro');
  reader.exec('BEGIN');
  reader.prepare(`SELECT count(*) AS n FROM cards`).get();
  let inPlace = 'ok';
  const writer = openDatabase(source, 'rw');
  try {
    writer.pragma('busy_timeout = 200');
    migrate(writer);
  } catch (error) {
    inPlace = error instanceof Error ? error.message : String(error);
  } finally {
    writer.close();
  }
  reader.exec('ROLLBACK');
  reader.close();
  const sourceAfterHold = openAndClose(source);
  const copied = path.join(h.root, 'legacy-v2.sqlite');
  const fresh = path.join(h.root, 'legacy-fresh.sqlite');
  h.decks.writeLegacy(fresh, 4);
  buildTempFile({
    tmpPath: copied,
    previousPath: fresh,
    version: 2,
    mutation: { type: 'append-hist', cardId: 'legacy-0', rating: 1, reviewedAt: 1 },
    seal: 'delete',
  });
  const freshVersion = openAndClose(fresh);
  const copiedVersion = openAndClose(copied);
  const copiedBody = readFileSnapshot(copied, 'tx', 'ro');
  record('migration', { inPlace, sourceAfterHold, freshVersion, copiedVersion, hist: copiedBody.hist.length });
  assert.equal(freshVersion, 1);
  assert.equal(copiedVersion, 2);
  assert.equal(copiedBody.hist.length, 1);
  assert.match(inPlace, /database is locked|ok/);
});

function openAndClose(file: string) {
  const db = openDatabase(file, 'ro');
  try {
    return userVersion(db);
  } finally {
    db.close();
  }
}

test('export without a WAL checkpoint drops commits that are still in the WAL', async () => {
  const src = path.join(h.root, 'wal-export.sqlite');
  h.decks.commitMutable({
    file: src,
    version: 1,
    mutation: { type: 'seed-cards', count: 3, idPrefix: 'card-' },
    autocheckpoint: 0,
  });
  const holder = h.decks.holdReader(src);
  try {
    h.decks.commitMutable({
      file: src,
      version: 2,
      mutation: { type: 'append-hist', cardId: 'card-0', rating: 5, reviewedAt: 5 },
      autocheckpoint: 0,
    });
    const plain = path.join(h.root, 'export-plain.sqlite');
    const before = sidecarBytes(src);
    h.decks.exportFile(src, plain, false);
    holder.exec('ROLLBACK');
    holder.close();
    const flushed = path.join(h.root, 'export-flushed.sqlite');
    h.decks.exportFile(src, flushed, true);
    const plainBody = readFileSnapshot(plain, 'tx', 'ro');
    const flushedBody = readFileSnapshot(flushed, 'tx', 'ro');
    record('export-checkpoint', {
      walBefore: before.wal,
      plainHist: plainBody.hist.length,
      plainVersion: plainBody.manifest.version,
      flushedHist: flushedBody.hist.length,
      flushedVersion: flushedBody.manifest.version,
    });
    assert.ok(before.wal > 0);
    assert.equal(flushedBody.hist.length, 1);
    assert.equal(flushedBody.manifest.version, 2);
    assert.notEqual(plainBody.hist.length, flushedBody.hist.length);
  } finally {
    try {
      holder.exec('ROLLBACK');
      holder.close();
    } catch {
      // closed after the plain copy
    }
  }
});

test('readers holding a snapshot keep the WAL from truncating', async () => {
  const file = path.join(h.root, 'wal-hold.sqlite');
  h.decks.commitMutable({
    file,
    version: 1,
    mutation: { type: 'seed-cards', count: 10, idPrefix: 'card-' },
    autocheckpoint: 0,
  });
  const control = path.join(h.root, 'wal-control.sqlite');
  fs.copyFileSync(file, control);
  for (let i = 0; i < 40; i++) {
    h.decks.commitMutable({
      file: control,
      version: i + 2,
      mutation: { type: 'append-hist', cardId: 'card-0', rating: 1, reviewedAt: i },
      autocheckpoint: 0,
    });
  }
  const controlCheckpoint = h.decks.checkpoint(control, 'TRUNCATE');
  const controlWal = sidecarBytes(control).wal;

  const readers = [h.decks.holdReader(file), h.decks.holdReader(file)];
  try {
    for (let i = 0; i < 40; i++) {
      h.decks.commitMutable({
        file,
        version: i + 2,
        mutation: { type: 'append-hist', cardId: 'card-0', rating: 1, reviewedAt: i },
        autocheckpoint: 0,
      });
    }
    const grown = sidecarBytes(file).wal;
    const passive = h.decks.checkpoint(file, 'PASSIVE');
    const truncate = h.decks.checkpoint(file, 'TRUNCATE');
    const walWhileHeld = sidecarBytes(file).wal;
    for (const reader of readers) {
      reader.exec('ROLLBACK');
      reader.close();
    }
    readers.length = 0;
    const released = h.decks.checkpoint(file, 'TRUNCATE');
    const walAfter = sidecarBytes(file).wal;
    record('wal-readers', {
      grown,
      walWhileHeld,
      walAfter,
      controlWal,
      controlBusy: controlCheckpoint.busy,
      passive,
      truncate,
      released,
    });
    assert.ok(grown > 0);
    assert.ok(walWhileHeld > 0);
    assert.equal(walAfter, 0);
    assert.equal(controlWal, 0);
  } finally {
    for (const reader of readers) {
      try {
        reader.exec('ROLLBACK');
        reader.close();
      } catch {
        // already closed
      }
    }
  }
});

test('a versioned body cache stays aligned and a deck-id cache goes stale', async () => {
  const deck = await makeDeck(h);
  const first = await h.read.read({
    deckId: deck.deckId,
    readerId: deck.ownerId,
    snapshot: 'tx',
    uriMode: 'ro-immutable',
    cache: 'versioned',
    pin: 'none',
  });
  const hit = await h.read.read({
    deckId: deck.deckId,
    readerId: deck.ownerId,
    snapshot: 'tx',
    uriMode: 'ro-immutable',
    cache: 'versioned',
    pin: 'none',
  });
  assert.equal(hit.cache, 'hit');
  assert.equal(hit.skew, false);
  assert.equal(hit.manifest.hash, first.manifest.hash);
  await h.publish.publish(
    publishInput(h, {
      deckId: deck.deckId,
      actorId: deck.ownerId,
      mutation: { type: 'append-hist', cardId: 'card-0', rating: 1, reviewedAt: 1 },
    }),
  );
  const next = await h.read.read({
    deckId: deck.deckId,
    readerId: deck.ownerId,
    snapshot: 'tx',
    uriMode: 'ro-immutable',
    cache: 'versioned',
    pin: 'none',
  });
  assert.equal(next.cache, 'miss');
  assert.equal(next.manifest.version, 2);
  assert.equal(next.skew, false);

  await h.read.read({
    deckId: deck.deckId,
    readerId: deck.ownerId,
    snapshot: 'tx',
    uriMode: 'ro-immutable',
    cache: 'by-deck',
    pin: 'none',
  });
  await h.publish.publish(
    publishInput(h, {
      deckId: deck.deckId,
      actorId: deck.ownerId,
      mutation: { type: 'append-hist', cardId: 'card-0', rating: 2, reviewedAt: 2 },
    }),
  );
  const stale = await h.read.read({
    deckId: deck.deckId,
    readerId: deck.ownerId,
    snapshot: 'tx',
    uriMode: 'ro-immutable',
    cache: 'by-deck',
    pin: 'none',
  });
  record('cache', { staleVersion: stale.manifest.version, pointer: stale.pointerVersion, skew: stale.skew });
  assert.equal(stale.cache, 'hit');
  assert.equal(stale.skew, true);
  assert.equal(stale.manifest.version, 2);
  assert.equal(stale.pointerVersion, 3);
});

test('pooled Prisma advisory lock/unlock can leave the lock behind', async () => {
  const child = await runNode('pool-lock-child.js', {}, 20_000);
  assert.equal(child.code, 0, child.stderr);
  const pooled = lastJson(child.stdout) as { leftovers: number };
  const client = new Client({ ...pgConfig(DATABASE_URL), application_name: 'dedicated-lock' });
  await client.connect();
  await client.query(`SELECT pg_advisory_lock(hashtextextended($1, 0))`, ['dedicated-demo']);
  const during = await h.prisma.$queryRaw<Array<{ n: number }>>`
    SELECT count(*)::int AS n
    FROM pg_locks l
    JOIN pg_stat_activity a ON a.pid = l.pid
    WHERE l.locktype = 'advisory' AND a.application_name = 'dedicated-lock'
  `;
  await client.query(`SELECT pg_advisory_unlock(hashtextextended($1, 0))`, ['dedicated-demo']);
  const after = await h.prisma.$queryRaw<Array<{ n: number }>>`
    SELECT count(*)::int AS n
    FROM pg_locks l
    JOIN pg_stat_activity a ON a.pid = l.pid
    WHERE l.locktype = 'advisory' AND a.application_name = 'dedicated-lock'
  `;
  await client.end();
  record('advisory-lock', { pooledLeftovers: pooled.leftovers, dedicatedDuring: during[0].n, dedicatedAfter: after[0].n });
  assert.equal(Number(during[0].n), 1);
  assert.equal(Number(after[0].n), 0);
  await sleep(1);
});

test('node:sqlite immutable=1 is a separate read path from better-sqlite3', async () => {
  const { DatabaseSync } = await import('node:sqlite');
  const dir = path.join(h.root, 'uri');
  fs.mkdirSync(dir, { recursive: true });
  const live = path.join(dir, 'deck.sqlite');
  const firstTmp = path.join(dir, '.tmp-v1.sqlite');
  const secondTmp = path.join(dir, '.tmp-v2.sqlite');
  buildTempFile({
    tmpPath: firstTmp,
    previousPath: null,
    version: 1,
    mutation: { type: 'seed-cards', count: 1, idPrefix: 'card-' },
    seal: 'delete',
  });
  fs.renameSync(firstTmp, live);
  const uri = `file:${live}?mode=ro&immutable=1`;
  const held = new DatabaseSync(uri, { readOnly: true });
  const first = held.prepare(`SELECT version FROM manifest`).get() as { version: number };
  buildTempFile({
    tmpPath: secondTmp,
    previousPath: null,
    version: 2,
    mutation: { type: 'seed-cards', count: 1, idPrefix: 'card-' },
    seal: 'delete',
  });
  fs.renameSync(secondTmp, live);
  let second: { version: number } | null = null;
  let heldError: string | null = null;
  try {
    second = held.prepare(`SELECT version FROM manifest`).get() as { version: number };
  } catch (error) {
    heldError = error instanceof Error ? error.message : String(error);
  }
  held.close();
  const reopened = new DatabaseSync(uri, { readOnly: true });
  const third = reopened.prepare(`SELECT version FROM manifest`).get() as { version: number };
  reopened.close();
  record('immutable-uri', {
    heldBefore: first.version,
    heldAfter: second?.version ?? null,
    heldError,
    reopened: third.version,
  });
  assert.equal(first.version, 1);
  assert.equal(third.version, 2);
});

test('a synchronous publish stalls the owner process event loop', async () => {
  const deck = await makeDeck(h);
  let maxGap = 0;
  let last = performance.now();
  const timer = setInterval(() => {
    const now = performance.now();
    maxGap = Math.max(maxGap, now - last);
    last = now;
  }, 5);
  const started = performance.now();
  await h.publish.publish(
    publishInput(h, {
      deckId: deck.deckId,
      actorId: deck.ownerId,
      mutation: { type: 'seed-cards', count: 8000, idPrefix: 'bulk-' },
    }),
  );
  const publishMs = performance.now() - started;
  clearInterval(timer);
  record('event-loop', { publishMs, maxGapMs: maxGap, intervalMs: 5 });
  assert.ok(maxGap > 20, `expected the event loop to stall, max gap ${maxGap}ms during ${publishMs}ms publish`);
});
