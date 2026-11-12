import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { after, before, beforeEach, test } from 'node:test';
import { Client } from 'pg';
import { OUTBOX_PUBLISHED } from '../src/catalog/catalog.service';
import { listSqliteFiles, readManifestFile } from '../src/deck-store/sqlite';
import { CorruptFileError, FileMissingError, ForbiddenError } from '../src/faults';
import { inspectWorld } from '../src/invariants';
import { pgConfig } from '../src/pg-config';
import { sleep } from '../src/stats';
import {
  closeHarness,
  createHarness,
  DATABASE_URL,
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

test('a publish commits the file, the pointer, the activity, and one outbox row together', async () => {
  const deck = await makeDeck(h);
  const world = await inspectWorld(h.prisma, h.root);
  assert.equal(world.pointerOk, true);
  assert.equal(world.outboxOk, true);
  assert.equal(world.orphans.length, 0);
  assert.equal(world.danglingVersionRows.length, 0);
  assert.equal(h.decks.journalMode(deck.published.path), 'delete');
  const reader = await h.catalog.ensureUser('reader');
  await h.catalog.grant(deck.deckId, reader.id, 'reader');
  const view = await h.read.read({
    deckId: deck.deckId,
    readerId: reader.id,
    snapshot: 'tx',
    uriMode: 'ro-immutable',
    cache: 'none',
    pin: 'none',
    verifyRehash: true,
  });
  assert.equal(view.skew, false);
  assert.equal(view.mixed, false);
  assert.equal(view.cards.length, 2);
  await assert.rejects(
    () => h.catalog.assertRole(deck.deckId, reader.id, 'owner'),
    ForbiddenError,
  );
  await assert.rejects(
    () =>
      h.publish.publish(
        publishInput(h, {
          deckId: deck.deckId,
          actorId: reader.id,
          mutation: { type: 'append-hist', cardId: 'card-0', rating: 1, reviewedAt: 1 },
        }),
      ),
    ForbiddenError,
  );
  await h.catalog.revoke(deck.deckId, deck.ownerId);
  await assert.rejects(
    () =>
      h.publish.publish(
        publishInput(h, {
          deckId: deck.deckId,
          actorId: deck.ownerId,
          mutation: { type: 'append-hist', cardId: 'card-0', rating: 1, reviewedAt: 1 },
        }),
      ),
    ForbiddenError,
  );
  const still = await h.catalog.getDeck(deck.deckId);
  assert.equal(still.ownerId, deck.ownerId);
});

test('the outbox row is invisible until the pointer transaction commits', async () => {
  const deck = await makeDeck(h);
  const ready = path.join(h.root, 'tx-ready');
  const pending = h.publish.publish(
    publishInput(h, {
      deckId: deck.deckId,
      actorId: deck.ownerId,
      pointerDelayMs: 1500,
      onTxStart: () => fs.writeFileSync(ready, '1'),
      mutation: { type: 'append-hist', cardId: 'card-0', rating: 3, reviewedAt: 10 },
    }),
  );
  const deadline = Date.now() + 5000;
  while (!fs.existsSync(ready)) {
    if (Date.now() > deadline) throw new Error('pointer transaction did not start');
    await sleep(5);
  }
  const client = new Client(pgConfig(DATABASE_URL));
  await client.connect();
  const version = await client.query<{ current_version: number }>(
    `SELECT current_version FROM decks WHERE id = $1`,
    [deck.deckId],
  );
  const outbox = await client.query<{ n: number }>(
    `SELECT count(*)::int AS n FROM outbox WHERE deck_id = $1 AND version = 2`,
    [deck.deckId],
  );
  await client.end();
  assert.equal(Number(version.rows[0].current_version), 1);
  assert.equal(Number(outbox.rows[0].n), 0);
  const staged = listSqliteFiles(h.root).filter((file) => path.basename(file).includes('-') && file.includes('/v2-'));
  assert.equal(staged.length, 1);
  assert.equal(readManifestFile(staged[0])?.version, 2);
  const result = await pending;
  assert.equal(result.status, 'ok');
  const after = await h.catalog.getDeck(deck.deckId);
  assert.equal(after.version, 2);
  const world = await inspectWorld(h.prisma, h.root);
  assert.equal(world.pointerOk, true);
  assert.equal(world.outboxOk, true);
});

test('redelivering an unmarked outbox row duplicates the effect', async () => {
  const deck = await makeDeck(h);
  const row = await h.prisma.outbox.findFirstOrThrow({
    where: { deckId: deck.deckId, type: OUTBOX_PUBLISHED },
  });
  const sink: string[] = [];
  sink.push(row.id);
  const second = await h.catalog.deliverOutbox(row.id, () => sink.push(row.id));
  const third = await h.catalog.deliverOutbox(row.id, () => sink.push('again'));
  assert.equal(second, 'delivered');
  assert.equal(third, 'already');
  assert.deepEqual(sink, [row.id, row.id]);
});

test('unique paths keep the pointer intact when two publishes race', async () => {
  const deck = await makeDeck(h);
  const ready = path.join(h.root, 'ready-unique');
  const wait = path.join(h.root, 'wait-unique');
  const child = runNode('fault-child.js', {
    DECK_ID: deck.deckId,
    ACTOR_ID: deck.ownerId,
    DECK_ROOT: h.root,
    CARD_ID: 'card-0',
    PATH_STYLE: 'unique',
    RATING: '1',
    REVIEWED_AT: '1',
    GATE_AT: 'beforeRename',
    GATE_READY: ready,
    GATE_WAIT: wait,
  });
  const deadline = Date.now() + 5000;
  while (!fs.existsSync(ready)) {
    if (Date.now() > deadline) throw new Error('unique-path child did not reach rename');
    await sleep(5);
  }
  const winner = await h.publish.publish(
    publishInput(h, {
      deckId: deck.deckId,
      actorId: deck.ownerId,
      pathStyle: 'unique',
      processLock: false,
      mutation: { type: 'append-hist', cardId: 'card-0', rating: 2, reviewedAt: 2 },
    }),
  );
  fs.writeFileSync(wait, '1');
  const loser = await child;
  assert.equal(winner.status, 'ok');
  assert.equal(loser.code, 0, loser.stderr);
  assert.equal((lastJson(loser.stdout) as { status: string }).status, 'conflict');
  const world = await inspectWorld(h.prisma, h.root);
  assert.equal(world.pointerOk, true, world.pointerProblems.join('; '));
  assert.equal(world.outboxOk, true, world.outboxProblems.join('; '));
  assert.equal(world.orphans.length, 1);
  record('unique-path-race', { pointerOk: world.pointerOk, orphans: world.orphans.length });
});

test('two processes that share a version path clobber the committed file', async () => {
  const deck = await makeDeck(h);
  const ready = path.join(h.root, 'ready-clobber');
  const wait = path.join(h.root, 'wait-clobber');
  const child = runNode('fault-child.js', {
    DECK_ID: deck.deckId,
    ACTOR_ID: deck.ownerId,
    DECK_ROOT: h.root,
    CARD_ID: 'card-0',
    PATH_STYLE: 'version',
    RATING: '4',
    REVIEWED_AT: '4',
    GATE_AT: 'beforeRename',
    GATE_READY: ready,
    GATE_WAIT: wait,
  });
  const deadline = Date.now() + 5000;
  while (!fs.existsSync(ready)) {
    if (Date.now() > deadline) throw new Error('clobber child did not reach rename');
    await sleep(5);
  }
  const winner = await h.publish.publish(
    publishInput(h, {
      deckId: deck.deckId,
      actorId: deck.ownerId,
      pathStyle: 'version',
      processLock: false,
      mutation: { type: 'append-hist', cardId: 'card-0', rating: 5, reviewedAt: 5 },
    }),
  );
  fs.writeFileSync(wait, '1');
  const loser = await child;
  assert.equal(winner.status, 'ok');
  assert.equal((lastJson(loser.stdout) as { status: string }).status, 'conflict');
  const world = await inspectWorld(h.prisma, h.root);
  record('same-path-clobber', {
    pointerOk: world.pointerOk,
    pointerProblems: world.pointerProblems,
  });
  assert.equal(world.pointerOk, false);
});

test('a dedicated connection advisory lock serializes two publishers', async () => {
  const deck = await makeDeck(h);
  const env = {
    DECK_ID: deck.deckId,
    ACTOR_ID: deck.ownerId,
    DECK_ROOT: h.root,
    CARD_ID: 'card-0',
    ADVISORY_LOCK: '1',
    PATH_STYLE: 'unique',
  };
  const [first, second] = await Promise.all([
    runNode('fault-child.js', { ...env, RATING: '1', REVIEWED_AT: '11' }),
    runNode('fault-child.js', { ...env, RATING: '2', REVIEWED_AT: '12' }),
  ]);
  assert.equal(first.code, 0, first.stderr);
  assert.equal(second.code, 0, second.stderr);
  const results = [lastJson(first.stdout), lastJson(second.stdout)] as Array<{
    status: string;
    version: number;
  }>;
  assert.deepEqual(
    results.map((item) => item.status),
    ['ok', 'ok'],
  );
  assert.deepEqual(
    results.map((item) => item.version).sort(),
    [2, 3],
  );
  const world = await inspectWorld(h.prisma, h.root);
  assert.equal(world.pointerOk, true, world.pointerProblems.join('; '));
  assert.equal(world.orphans.length, 0);
});

test('skipping the integrity check lets a torn file become the pointer', async () => {
  const deck = await makeDeck(h);
  await assert.rejects(
    () =>
      h.publish.publish(
        publishInput(h, {
          deckId: deck.deckId,
          actorId: deck.ownerId,
          tearBeforeCommit: true,
          mutation: { type: 'append-hist', cardId: 'card-0', rating: 1, reviewedAt: 1 },
        }),
      ),
    (error: unknown) => error instanceof CorruptFileError,
  );
  const safe = await inspectWorld(h.prisma, h.root);
  assert.equal(safe.pointerOk, true, safe.pointerProblems.join('; '));
  assert.equal((await h.catalog.getDeck(deck.deckId)).version, 1);

  const unsafe = await h.publish.publish(
    publishInput(h, {
      deckId: deck.deckId,
      actorId: deck.ownerId,
      tearBeforeCommit: true,
      skipIntegrity: true,
      mutation: { type: 'append-hist', cardId: 'card-0', rating: 2, reviewedAt: 2 },
    }),
  );
  assert.equal(unsafe.status, 'ok');
  const broken = await inspectWorld(h.prisma, h.root);
  record('torn-without-integrity', { pointerOk: broken.pointerOk, problems: broken.pointerProblems });
  assert.equal(broken.pointerOk, false);
});

test('grace 0 GC during the pointer gap aborts the commit instead of publishing a hole', async () => {
  const deck = await makeDeck(h);
  await assert.rejects(
    () =>
      h.publish.publish(
        publishInput(h, {
          deckId: deck.deckId,
          actorId: deck.ownerId,
          mutation: { type: 'append-hist', cardId: 'card-0', rating: 1, reviewedAt: 1 },
          beforePointer: () =>
            h.gc.collect({
              root: h.root,
              mode: 'recheck',
              graceMs: 0,
              respectLeases: false,
              respectPins: false,
            }),
        }),
      ),
    (error: unknown) => error instanceof FileMissingError,
  );
  const world = await inspectWorld(h.prisma, h.root);
  assert.equal(world.pointerOk, true, world.pointerProblems.join('; '));
  assert.equal((await h.catalog.getDeck(deck.deckId)).version, 1);
});

test('a stale path list deletes the file that the pointer just committed', async () => {
  const deck = await makeDeck(h);
  const stale = await h.catalog.referencedPaths();
  const published = await h.publish.publish(
    publishInput(h, {
      deckId: deck.deckId,
      actorId: deck.ownerId,
      mutation: { type: 'append-hist', cardId: 'card-0', rating: 1, reviewedAt: 1 },
    }),
  );
  assert.equal(published.status, 'ok');
  const removed = await h.gc.collect({
    root: h.root,
    mode: 'stale-list',
    graceMs: 0,
    respectLeases: false,
    respectPins: false,
    stalePaths: stale,
  });
  const world = await inspectWorld(h.prisma, h.root);
  record('stale-gc', {
    deleted: removed.deleted.length,
    pointerOk: world.pointerOk,
    problems: world.pointerProblems,
  });
  assert.equal(world.pointerOk, false);
});

test('recheck GC removes an orphan and keeps committed versions', async () => {
  const deck = await makeDeck(h);
  const orphan = path.join(h.root, deck.deckId, 'orphan.sqlite');
  fs.writeFileSync(orphan, 'not a database');
  const kept = await h.gc.collect({
    root: h.root,
    mode: 'recheck',
    graceMs: 60_000,
    respectLeases: false,
    respectPins: false,
  });
  assert.equal(kept.deleted.includes(orphan), false);
  const swept = await h.gc.collect({
    root: h.root,
    mode: 'recheck',
    graceMs: 0,
    respectLeases: false,
    respectPins: false,
  });
  assert.equal(swept.deleted.includes(orphan), true);
  const world = await inspectWorld(h.prisma, h.root);
  assert.equal(world.pointerOk, true, world.pointerProblems.join('; '));
  assert.equal(world.orphans.length, 0);
  assert.equal(fs.existsSync(deck.published.path), true);
});
