import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { after, before, test } from 'node:test';
import 'reflect-metadata';
import { NestFactory } from '@nestjs/core';
import { AppModule } from '../src/app.module';
import { ForbiddenFilter } from '../src/deck.controller';
import { closeHarness, createHarness, reset, type Harness } from './helpers';

let h: Harness;

before(async () => {
  h = await createHarness();
  await reset(h);
});

after(async () => {
  await closeHarness(h);
});

test('postgres schema is the only Prisma datasource and has no card body', async () => {
  const schema = fs.readFileSync(path.join(process.cwd(), 'prisma', 'schema.prisma'), 'utf8');
  assert.equal([...schema.matchAll(/^datasource /gm)].length, 1);
  assert.match(schema, /provider\s*=\s*"postgresql"/);
  assert.equal(schema.includes('sqlite'), false);
  const tables = await h.prisma.$queryRaw<Array<{ tablename: string }>>`
    SELECT tablename FROM pg_tables WHERE schemaname = 'public'
  `;
  const names = new Set(tables.map((row) => row.tablename));
  for (const required of ['users', 'decks', 'deck_versions', 'deck_acl', 'activities', 'outbox']) {
    assert.equal(names.has(required), true, required);
  }
  for (const absent of ['cards', 'fields', 'hist']) {
    assert.equal(names.has(absent), false, absent);
  }
});

test('Nest module serves the owner and refuses a stranger', async () => {
  const app = await NestFactory.create(AppModule, { logger: false });
  app.useGlobalFilters(new ForbiddenFilter());
  await app.listen(0);
  try {
    const base = await app.getUrl();
    const health = await fetch(`${base}/health`);
    assert.equal((await health.json()).spike, true);
    const created = await fetch(`${base}/decks`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ handle: 'ada', title: 'demo' }),
    });
    const deck = (await created.json()) as { deckId: string };
    const added = await fetch(`${base}/decks/${deck.deckId}/cards`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ handle: 'ada', cardId: 'c1', front: 'front', back: 'back' }),
    });
    assert.equal(added.ok, true);
    const own = await fetch(`${base}/decks/${deck.deckId}?handle=ada`);
    const body = (await own.json()) as { cards: number; skew: boolean; mixed: boolean };
    assert.equal(body.cards, 1);
    assert.equal(body.skew, false);
    assert.equal(body.mixed, false);
    const stranger = await fetch(`${base}/decks/${deck.deckId}?handle=eve`);
    assert.equal(stranger.status, 403);
  } finally {
    await app.close();
  }
});
