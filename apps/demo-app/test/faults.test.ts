import assert from 'node:assert/strict';
import { after, before, beforeEach, test } from 'node:test';
import { FAULT_POINTS, type FaultPoint } from '../src/faults';
import { inspectWorld } from '../src/invariants';
import {
  closeHarness,
  createHarness,
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

test('process kill at each publish point leaves the pointer on a complete version', async () => {
  const outcomes: unknown[] = [];
  for (const point of FAULT_POINTS) {
    await reset(h);
    const deck = await makeDeck(h);
    const killed = await runNode('fault-child.js', {
      FAULT_POINT: point,
      DECK_ID: deck.deckId,
      ACTOR_ID: deck.ownerId,
      DECK_ROOT: h.root,
      CARD_ID: 'card-0',
      PATH_STYLE: 'unique',
      RATING: '7',
      REVIEWED_AT: '7',
    });
    assert.equal(killed.signal, 'SIGKILL', `${point} stderr=${killed.stderr} stdout=${killed.stdout}`);
    const world = await inspectWorld(h.prisma, h.root);
    const version = (await h.catalog.getDeck(deck.deckId)).version;
    outcomes.push({
      point,
      version,
      pointerOk: world.pointerOk,
      outboxOk: world.outboxOk,
      orphans: world.orphans.length,
      temps: world.temps.length,
      pointerProblems: world.pointerProblems,
      outboxProblems: world.outboxProblems,
    });
    assert.equal(world.pointerOk, true, `${point} ${world.pointerProblems.join('; ')}`);
    assert.equal(world.outboxOk, true, `${point} ${world.outboxProblems.join('; ')}`);
    if (point === 'afterPointerCommit') {
      assert.equal(version, 2);
      assert.equal(world.orphans.length, 0);
    } else {
      assert.equal(version, 1);
    }
  }
  record('kill-points', outcomes);
});

test('a kill inside the pointer transaction releases the advisory lock', async () => {
  const deck = await makeDeck(h);
  const killed = await runNode('fault-child.js', {
    FAULT_POINT: 'insidePointerTx',
    ADVISORY_LOCK: '1',
    DECK_ID: deck.deckId,
    ACTOR_ID: deck.ownerId,
    DECK_ROOT: h.root,
    CARD_ID: 'card-0',
    RATING: '1',
    REVIEWED_AT: '1',
  });
  assert.equal(killed.signal, 'SIGKILL', killed.stderr);
  const next = await h.publish.publish(
    publishInput(h, {
      deckId: deck.deckId,
      actorId: deck.ownerId,
      advisoryLock: true,
      databaseUrl: process.env.DATABASE_URL,
      mutation: { type: 'append-hist', cardId: 'card-0', rating: 2, reviewedAt: 2 },
    }),
  );
  assert.equal(next.status, 'ok');
  const world = await inspectWorld(h.prisma, h.root);
  assert.equal(world.pointerOk, true, world.pointerProblems.join('; '));
  assert.equal(world.outboxOk, true, world.outboxProblems.join('; '));
});

test('a thrown fault inside the pointer transaction rolls the outbox back', async () => {
  const deck = await makeDeck(h);
  const point: FaultPoint = 'insidePointerTx';
  await assert.rejects(
    () =>
      h.publish.publish(
        publishInput(h, {
          deckId: deck.deckId,
          actorId: deck.ownerId,
          fault: point,
          faultMode: 'throw',
          mutation: { type: 'append-hist', cardId: 'card-0', rating: 1, reviewedAt: 1 },
        }),
      ),
    /fault:insidePointerTx/,
  );
  const world = await inspectWorld(h.prisma, h.root);
  assert.equal((await h.catalog.getDeck(deck.deckId)).version, 1);
  assert.equal(world.pointerOk, true, world.pointerProblems.join('; '));
  assert.equal(world.outboxOk, true, world.outboxProblems.join('; '));
  assert.equal(world.orphans.length, 1);
});
