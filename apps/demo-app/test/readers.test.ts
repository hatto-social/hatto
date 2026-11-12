import assert from 'node:assert/strict';
import fs from 'node:fs';
import { after, before, beforeEach, test } from 'node:test';
import { openDatabase } from '../src/deck-store/sqlite';
import { finishJob, signal, startJob } from '../src/jobs';
import { inspectWorld } from '../src/invariants';
import { sleep } from '../src/stats';
import {
  DATABASE_URL,
  closeHarness,
  createHarness,
  makeDeck,
  publishInput,
  record,
  reset,
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

async function until(events: Array<{ type: string }>, type: string): Promise<void> {
  const deadline = Date.now() + 5000;
  while (!events.some((event) => event.type === type)) {
    if (Date.now() > deadline) throw new Error(`timed out waiting for ${type}`);
    await sleep(5);
  }
}

test('an immutable file does not mix versions when the pointer moves mid-read', async () => {
  const deck = await makeDeck(h);
  const sab = new SharedArrayBuffer(4);
  const job = startJob({
    type: 'split',
    path: deck.published.path,
    snapshot: 'loose',
    uriMode: 'ro',
    sab,
  });
  await until(job.events, 'paused');
  await h.publish.publish(
    publishInput(h, {
      deckId: deck.deckId,
      actorId: deck.ownerId,
      mutation: { type: 'append-hist', cardId: 'card-0', rating: 1, reviewedAt: 1 },
    }),
  );
  signal(sab);
  const result = await finishJob<{ mixed: boolean; version: number }>(job);
  assert.equal(result.mixed, false);
  assert.equal(result.version, 1);
});

test('a mutable file mixes two statements unless the read is one snapshot', async () => {
  const deck = await makeDeck(h, { strategy: 'mutable' });
  const looseSab = new SharedArrayBuffer(4);
  const loose = startJob({
    type: 'split',
    path: deck.published.path,
    snapshot: 'loose',
    uriMode: 'ro',
    sab: looseSab,
  });
  await until(loose.events, 'paused');
  await h.publish.publish(
    publishInput(h, {
      deckId: deck.deckId,
      actorId: deck.ownerId,
      strategy: 'mutable',
      mutation: { type: 'append-hist', cardId: 'card-0', rating: 1, reviewedAt: 1 },
    }),
  );
  signal(looseSab);
  const looseResult = await finishJob<{ mixed: boolean; version: number; histMax: number }>(loose);
  record('mutable-split-loose', looseResult);
  assert.equal(looseResult.mixed, true);

  const txSab = new SharedArrayBuffer(4);
  const tx = startJob({
    type: 'split',
    path: deck.published.path,
    snapshot: 'tx',
    uriMode: 'ro',
    sab: txSab,
  });
  await until(tx.events, 'paused');
  await h.publish.publish(
    publishInput(h, {
      deckId: deck.deckId,
      actorId: deck.ownerId,
      strategy: 'mutable',
      mutation: { type: 'append-hist', cardId: 'card-0', rating: 2, reviewedAt: 2 },
    }),
  );
  signal(txSab);
  const txResult = await finishJob<{ mixed: boolean; histMax: number; version: number }>(tx);
  record('mutable-split-tx', txResult);
  assert.equal(txResult.mixed, false);
  assert.ok(txResult.histMax <= txResult.version);
});

test('joining two successful reads from different versions mixes the body', async () => {
  const deck = await makeDeck(h);
  const first = await h.read.read({
    deckId: deck.deckId,
    readerId: deck.ownerId,
    snapshot: 'tx',
    uriMode: 'ro-immutable',
    cache: 'none',
    pin: 'none',
  });
  await h.publish.publish(
    publishInput(h, {
      deckId: deck.deckId,
      actorId: deck.ownerId,
      mutation: { type: 'append-hist', cardId: 'card-0', rating: 1, reviewedAt: 1 },
    }),
  );
  const second = await h.read.read({
    deckId: deck.deckId,
    readerId: deck.ownerId,
    snapshot: 'tx',
    uriMode: 'ro-immutable',
    cache: 'none',
    pin: 'none',
  });
  const mixed =
    first.manifest.version !== second.manifest.version &&
    second.hist.some((row) => row.rev > first.manifest.version) &&
    first.cards.length > 0;
  record('application-mix', {
    mixed,
    first: first.manifest.version,
    second: second.manifest.version,
  });
  assert.equal(mixed, true);
  assert.equal(first.skew, false);
  assert.equal(second.skew, false);
});

test('naive GC unlinks the previous file while an open reader can still read it', async () => {
  const deck = await makeDeck(h);
  const previous = deck.published.path;
  const sab = new SharedArrayBuffer(4);
  const job = startJob({ type: 'hold', path: previous, uriMode: 'ro', sab });
  await until(job.events, 'held');
  await h.publish.publish(
    publishInput(h, {
      deckId: deck.deckId,
      actorId: deck.ownerId,
      mutation: { type: 'append-hist', cardId: 'card-0', rating: 1, reviewedAt: 1 },
    }),
  );
  const removed = await h.gc.collect({
    root: h.root,
    mode: 'naive-current',
    graceMs: 0,
    respectLeases: false,
    respectPins: false,
  });
  assert.equal(removed.deleted.includes(previous), true);
  assert.equal(fs.existsSync(previous), false);
  signal(sab);
  const result = await finishJob<{ stillMatches: boolean; readError: string | null; version: number }>(job);
  record('gc-open-fd', result);
  assert.equal(result.readError, null);
  assert.equal(result.stillMatches, true);
  assert.equal(result.version, 1);
  assert.throws(() => openDatabase(previous, 'ro'));
  const world = await inspectWorld(h.prisma, h.root);
  assert.equal(world.pointerOk, true, world.pointerProblems.join('; '));
  assert.ok(world.danglingVersionRows.some((row) => row.includes(previous)));
});

test('a live lease stops GC from unlinking the previous version', async () => {
  const deck = await makeDeck(h);
  const previous = deck.published.path;
  await h.publish.publish(
    publishInput(h, {
      deckId: deck.deckId,
      actorId: deck.ownerId,
      mutation: { type: 'append-hist', cardId: 'card-0', rating: 1, reviewedAt: 1 },
    }),
  );
  const leaseId = await h.catalog.acquireLease({
    deckId: deck.deckId,
    version: 1,
    path: previous,
    holder: 'reader',
    ttlMs: 30_000,
  });
  const held = await h.gc.collect({
    root: h.root,
    mode: 'naive-current',
    graceMs: 0,
    respectLeases: true,
    respectPins: false,
  });
  assert.equal(held.deleted.includes(previous), false);
  assert.equal(fs.existsSync(previous), true);
  await h.catalog.releaseLease(leaseId);
  const dropped = await h.gc.collect({
    root: h.root,
    mode: 'naive-current',
    graceMs: 0,
    respectLeases: true,
    respectPins: false,
  });
  assert.equal(dropped.deleted.includes(previous), true);
});

test('immutable readers never see a skew or a mixed body while the owner publishes', async () => {
  const deck = await makeDeck(h);
  const jobs = Array.from({ length: 4 }, () =>
    startJob({
      type: 'hammer',
      databaseUrl: DATABASE_URL,
      deckId: deck.deckId,
      readerId: deck.ownerId,
      durationMs: 1200,
      snapshot: 'tx',
      uriMode: 'ro-immutable',
      followPointer: true,
      part: 'both',
    }),
  );
  const writing = (async () => {
    for (let i = 0; i < 6; i++) {
      await h.publish.publish(
        publishInput(h, {
          deckId: deck.deckId,
          actorId: deck.ownerId,
          mutation: { type: 'append-hist', cardId: 'card-0', rating: i + 1, reviewedAt: i + 1 },
        }),
      );
      await sleep(40);
    }
  })();
  const results = await Promise.all(jobs.map((job) => finishJob<{
    reads: number;
    errors: number;
    mixed: number;
    skew: number;
    sampleErrors: string[];
  }>(job)));
  await writing;
  const totals = results.reduce(
    (sum, item) => ({
      reads: sum.reads + item.reads,
      errors: sum.errors + item.errors,
      mixed: sum.mixed + item.mixed,
      skew: sum.skew + item.skew,
    }),
    { reads: 0, errors: 0, mixed: 0, skew: 0 },
  );
  record('immutable-readers', { totals, sampleErrors: results.flatMap((item) => item.sampleErrors) });
  assert.ok(totals.reads > 0);
  assert.equal(totals.errors, 0, JSON.stringify(results.map((item) => item.sampleErrors)));
  assert.equal(totals.mixed, 0);
  assert.equal(totals.skew, 0);
  const world = await inspectWorld(h.prisma, h.root);
  assert.equal(world.pointerOk, true, world.pointerProblems.join('; '));
  assert.equal(world.outboxOk, true, world.outboxProblems.join('; '));
});

test('mutable readers observe pointer skew while the owner delays the commit', async () => {
  const deck = await makeDeck(h, { strategy: 'mutable' });
  const jobs = Array.from({ length: 4 }, () =>
    startJob({
      type: 'hammer',
      databaseUrl: DATABASE_URL,
      deckId: deck.deckId,
      readerId: deck.ownerId,
      durationMs: 1000,
      snapshot: 'tx',
      uriMode: 'ro',
      followPointer: true,
      part: 'both',
    }),
  );
  const writing = (async () => {
    for (let i = 0; i < 8; i++) {
      await h.publish.publish(
        publishInput(h, {
          deckId: deck.deckId,
          actorId: deck.ownerId,
          strategy: 'mutable',
          pointerDelayMs: 40,
          mutation: { type: 'append-hist', cardId: 'card-0', rating: i + 1, reviewedAt: i + 1 },
        }),
      );
    }
  })();
  const results = await Promise.all(jobs.map((job) => finishJob<{
    reads: number;
    errors: number;
    mixed: number;
    skew: number;
    sampleErrors: string[];
  }>(job)));
  await writing;
  const skew = results.reduce((sum, item) => sum + item.skew, 0);
  const mixed = results.reduce((sum, item) => sum + item.mixed, 0);
  const errors = results.reduce((sum, item) => sum + item.errors, 0);
  record('mutable-skew', { skew, mixed, errors, reads: results.reduce((sum, item) => sum + item.reads, 0) });
  assert.equal(errors, 0, JSON.stringify(results.map((item) => item.sampleErrors)));
  assert.ok(skew > 0, `expected pointer skew, got ${skew}`);
  assert.equal(mixed, 0);
});
