import 'reflect-metadata';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { randomUUID } from 'node:crypto';
import { buildTempFile, countSqliteFds, fileBytes, fsyncPath, readManifestFile, sidecarBytes, sqliteVersion } from '../src/deck-store/sqlite';
import { finishJob, signal, startJob } from '../src/jobs';
import { percentile, sleep } from '../src/stats';
import {
  DATABASE_URL,
  closeHarness,
  createHarness,
  makeDeck,
  publishInput,
  reset,
  type Harness,
} from '../test/helpers';

type Scenario = { name: string; ms: number; data?: unknown; error?: string };

type HammerRow = {
  reads: number;
  errors: number;
  mixed: number;
  skew: number;
  sum: number;
  min: number;
  max: number;
  sampled: boolean;
  latencies: number[];
  versions: Record<string, number>;
  sampleErrors: string[];
};

const HOT_MS = 2500;

async function main(): Promise<void> {
  const startedAt = new Date().toISOString();
  const h = await createHarness();
  await reset(h);
  const scenarios: Scenario[] = [];
  const pgVersion = await h.prisma.$queryRaw<Array<{ v: string }>>`SELECT version() AS v`;
  try {
    scenarios.push(await run('bulk-lru', () => bulkLru(h)));
    scenarios.push(await run('hot-immutable', () => hotImmutable(h)));
    scenarios.push(await run('hot-mutable', () => hotMutable(h)));
    scenarios.push(await run('hot-replace', () => hotReplace(h)));
    scenarios.push(await run('spread', () => spread(h)));
    scenarios.push(await run('read-path-split', () => readPathSplit(h)));
    scenarios.push(await run('lease-cost', () => leaseCost(h)));
    scenarios.push(await run('cache-ceiling', () => cacheCeiling(h)));
    scenarios.push(await run('wal-growth', () => walGrowth(h)));
    scenarios.push(await run('large-deck', () => largeDeck(h)));
    scenarios.push(await run('gc-holders', () => gcHolders(h)));
  } finally {
    const summary = {
      startedAt,
      finishedAt: new Date().toISOString(),
      env: {
        node: process.version,
        cpus: os.cpus().length,
        cpuModel: os.cpus()[0]?.model,
        memTotalBytes: os.totalmem(),
        platform: `${os.platform()} ${os.release()}`,
        postgres: pgVersion[0]?.v,
        sqlite: sqliteVersion(),
        databaseUrl: DATABASE_URL.replace(/:[^:@/]+@/, ':***@'),
        docker: false,
        postgresNote: 'local PostgreSQL, not testcontainers',
      },
      scenarios,
    };
    const out = path.join(process.cwd(), 'results', 'summary.json');
    fs.mkdirSync(path.dirname(out), { recursive: true });
    fs.writeFileSync(out, JSON.stringify(summary, null, 2));
    await closeHarness(h);
    const failed = scenarios.filter((item) => item.error);
    console.log(`wrote ${out}`);
    if (failed.length) {
      console.error(failed.map((item) => `${item.name}: ${item.error}`).join('\n'));
      process.exitCode = 1;
    }
  }
}

async function run(name: string, fn: () => Promise<unknown>): Promise<Scenario> {
  const started = performance.now();
  console.log(`\n== ${name}`);
  try {
    const data = await fn();
    const ms = performance.now() - started;
    console.log(`ok ${name} ${ms.toFixed(0)}ms`);
    return { name, ms, data };
  } catch (error) {
    const ms = performance.now() - started;
    const message = error instanceof Error ? error.stack ?? error.message : String(error);
    console.error(`FAIL ${name}\n${message}`);
    return { name, ms, error: message };
  }
}

async function bulkLru(h: Harness) {
  const count = 2500;
  const owner = await h.catalog.ensureUser('bulk-owner');
  const reader = await h.catalog.ensureUser('bulk-reader');
  const now = new Date();
  const files: Array<{ id: string; path: string; hash: string; bytes: number }> = [];
  const buildStarted = performance.now();
  for (let i = 0; i < count; i++) {
    const id = randomUUID();
    const dir = path.join(h.root, id);
    const tmp = path.join(dir, '.tmp-build.sqlite');
    const finalPath = path.join(dir, 'v1.sqlite');
    const built = buildTempFile({
      tmpPath: tmp,
      previousPath: null,
      version: 1,
      mutation: { type: 'seed-cards', count: 1, idPrefix: 'c' },
      seal: 'delete',
    });
    fsyncPath(tmp);
    fs.renameSync(tmp, finalPath);
    files.push({ id, path: finalPath, hash: built.hash, bytes: fileBytes(finalPath) });
    if ((i + 1) % 500 === 0) console.log(`  built ${i + 1}/${count}`);
  }
  const buildMs = performance.now() - buildStarted;
  const insertStarted = performance.now();
  for (let offset = 0; offset < files.length; offset += 250) {
    const chunk = files.slice(offset, offset + 250);
    await h.prisma.deck.createMany({
      data: chunk.map((row) => ({
        id: row.id,
        ownerId: owner.id,
        title: 'bulk',
        strategy: 'immutable',
        currentVersion: 1,
        currentPath: row.path,
        contentHash: row.hash,
        byteSize: row.bytes,
        updatedAt: now,
      })),
    });
    await h.prisma.deckVersion.createMany({
      data: chunk.map((row) => ({
        deckId: row.id,
        version: 1,
        path: row.path,
        contentHash: row.hash,
        byteSize: row.bytes,
        createdAt: now,
      })),
    });
    await h.prisma.deckAcl.createMany({
      data: chunk.flatMap((row) => [
        { deckId: row.id, userId: owner.id, role: 'owner' },
        { deckId: row.id, userId: reader.id, role: 'reader' },
      ]),
    });
    await h.prisma.outbox.createMany({
      data: chunk.map((row) => ({
        id: randomUUID(),
        deckId: row.id,
        version: 1,
        type: 'deck.version.published',
        payload: { version: 1, contentHash: row.hash, byteSize: row.bytes, cardCount: 1, histCount: 0 },
        createdAt: now,
      })),
    });
    await h.prisma.activity.createMany({
      data: chunk.map((row) => ({
        id: randomUUID(),
        deckId: row.id,
        actorId: owner.id,
        type: 'Create',
        version: 1,
        payload: { version: 1, contentHash: row.hash, byteSize: row.bytes, cardCount: 1, histCount: 0 },
        createdAt: now,
      })),
    });
  }
  const insertMs = performance.now() - insertStarted;
  const lruBytes = 4 * 1024 * 1024;
  const { HandleLru } = await import('../src/deck-store/handle-lru');
  const lru = new HandleLru(lruBytes);
  const scanStarted = performance.now();
  for (const row of files) {
    lru.open(row.path, 'ro');
    lru.unpin(row.path, 'ro');
  }
  const scanMs = performance.now() - scanStarted;
  const stats = lru.stats();
  const fds = countSqliteFds();
  const reopenStarted = performance.now();
  const manifest = readManifestFile(files[0].path);
  lru.open(files[0].path, 'ro');
  lru.unpin(files[0].path, 'ro');
  const reopenMs = performance.now() - reopenStarted;
  lru.closeAll();
  let bad = 0;
  for (const row of files.slice(0, 30)) {
    const body = readManifestFile(row.path);
    if (!body || body.hash !== row.hash || body.version !== 1) bad += 1;
  }
  return {
    count,
    fileBytes: files[0].bytes,
    totalFileBytes: files.reduce((sum, row) => sum + row.bytes, 0),
    buildMs,
    insertMs,
    scanMs,
    reopenMs,
    lru: stats,
    fdsAfterScan: fds,
    sampleMismatches: bad,
    firstManifest: manifest?.version ?? null,
  };
}

async function hotImmutable(h: Harness) {
  const deck = await makeDeck(h, { mutation: { type: 'seed-cards', count: 40, idPrefix: 'card-' } });
  const rows = [];
  for (const readers of [1, 4, 16, 32]) {
    rows.push(await hammer(h, {
      label: `immutable-${readers}`,
      deckId: deck.deckId,
      readerId: deck.ownerId,
      readers,
      durationMs: HOT_MS,
      strategy: 'immutable',
      snapshot: 'tx',
      uriMode: 'ro-immutable',
      followPointer: true,
      part: 'both',
      publishEveryMs: 150,
      pointerDelayMs: 0,
    }));
  }
  return rows;
}

async function hotMutable(h: Harness) {
  const deck = await makeDeck(h, {
    strategy: 'mutable',
    mutation: { type: 'seed-cards', count: 40, idPrefix: 'card-' },
  });
  const plain = await hammer(h, {
    label: 'mutable-delay0',
    deckId: deck.deckId,
    readerId: deck.ownerId,
    readers: 8,
    durationMs: HOT_MS,
    strategy: 'mutable',
    snapshot: 'tx',
    uriMode: 'ro',
    followPointer: true,
    part: 'both',
    publishEveryMs: 0,
    pointerDelayMs: 0,
  });
  const delayed = await hammer(h, {
    label: 'mutable-delay30',
    deckId: deck.deckId,
    readerId: deck.ownerId,
    readers: 8,
    durationMs: HOT_MS,
    strategy: 'mutable',
    snapshot: 'tx',
    uriMode: 'ro',
    followPointer: true,
    part: 'both',
    publishEveryMs: 0,
    pointerDelayMs: 30,
  });
  const loose = await hammer(h, {
    label: 'mutable-loose',
    deckId: deck.deckId,
    readerId: deck.ownerId,
    readers: 8,
    durationMs: HOT_MS,
    strategy: 'mutable',
    snapshot: 'loose',
    uriMode: 'ro',
    followPointer: true,
    part: 'both',
    publishEveryMs: 0,
    pointerDelayMs: 30,
  });
  return { plain, delayed, loose, wal: sidecarBytes(deck.published.path) };
}

async function hotReplace(h: Harness) {
  const deck = await makeDeck(h, {
    strategy: 'replace',
    mutation: { type: 'seed-cards', count: 40, idPrefix: 'card-' },
  });
  return hammer(h, {
    label: 'replace-delay30',
    deckId: deck.deckId,
    readerId: deck.ownerId,
    readers: 8,
    durationMs: HOT_MS,
    strategy: 'replace',
    snapshot: 'tx',
    uriMode: 'ro',
    followPointer: true,
    part: 'both',
    publishEveryMs: 0,
    pointerDelayMs: 30,
  });
}

async function spread(h: Harness) {
  const decks = await h.prisma.deck.findMany({
    where: { title: 'bulk', strategy: 'immutable' },
    take: 32,
    select: { id: true, currentPath: true },
  });
  const reader = await h.catalog.ensureUser('bulk-reader');
  if (decks.length < 32 || decks.some((deck) => !deck.currentPath)) {
    throw new Error(`spread needs 32 bulk decks, found ${decks.length}`);
  }
  const started = performance.now();
  const jobs = decks.map((deck) =>
    startJob({
      type: 'hammer',
      databaseUrl: DATABASE_URL,
      deckId: deck.id,
      readerId: reader.id,
      durationMs: HOT_MS,
      snapshot: 'tx',
      uriMode: 'ro-immutable',
      followPointer: true,
      part: 'both',
    }),
  );
  const results = await Promise.all(jobs.map((job) => finishJob<HammerRow>(job)));
  return { ...fold(results, performance.now() - started), decks: decks.length };
}

async function readPathSplit(h: Harness) {
  const deck = await makeDeck(h, { mutation: { type: 'seed-cards', count: 40, idPrefix: 'card-' } });
  const both = await hammer(h, {
    label: 'split-both',
    deckId: deck.deckId,
    readerId: deck.ownerId,
    readers: 8,
    durationMs: 2000,
    strategy: 'immutable',
    snapshot: 'tx',
    uriMode: 'ro-immutable',
    followPointer: true,
    part: 'both',
    publishEveryMs: 0,
    pointerDelayMs: 0,
    publish: false,
  });
  const pointer = await hammer(h, {
    label: 'split-pointer',
    deckId: deck.deckId,
    readerId: deck.ownerId,
    readers: 8,
    durationMs: 2000,
    strategy: 'immutable',
    snapshot: 'tx',
    uriMode: 'ro-immutable',
    followPointer: true,
    part: 'pointer',
    publishEveryMs: 0,
    pointerDelayMs: 0,
    publish: false,
  });
  const body = await hammer(h, {
    label: 'split-body',
    deckId: deck.deckId,
    readerId: deck.ownerId,
    readers: 8,
    durationMs: 2000,
    strategy: 'immutable',
    snapshot: 'tx',
    uriMode: 'ro-immutable',
    followPointer: false,
    fixedPath: deck.published.path,
    part: 'body',
    publishEveryMs: 0,
    pointerDelayMs: 0,
    publish: false,
  });
  return { both, pointer, body };
}

async function leaseCost(h: Harness) {
  const deck = await makeDeck(h);
  const rounds = 80;
  const plainStarted = performance.now();
  for (let i = 0; i < rounds; i++) {
    await h.read.read({
      deckId: deck.deckId,
      readerId: deck.ownerId,
      snapshot: 'tx',
      uriMode: 'ro-immutable',
      cache: 'none',
      pin: 'none',
    });
  }
  const plainMs = performance.now() - plainStarted;
  const leasedStarted = performance.now();
  for (let i = 0; i < rounds; i++) {
    await h.read.read({
      deckId: deck.deckId,
      readerId: deck.ownerId,
      snapshot: 'tx',
      uriMode: 'ro-immutable',
      cache: 'none',
      pin: 'lease',
      holder: `lease-${i}`,
    });
  }
  const leasedMs = performance.now() - leasedStarted;
  const leasesLeft = await h.prisma.readLease.count();
  return {
    rounds,
    plainMs,
    leasedMs,
    plainPerReadMs: plainMs / rounds,
    leasedPerReadMs: leasedMs / rounds,
    leasesLeft,
  };
}

async function cacheCeiling(h: Harness) {
  const deck = await makeDeck(h, { mutation: { type: 'seed-cards', count: 40, idPrefix: 'card-' } });
  const base = {
    deckId: deck.deckId,
    readerId: deck.ownerId,
    snapshot: 'tx' as const,
    uriMode: 'ro-immutable' as const,
    pin: 'none' as const,
  };
  await h.read.read({ ...base, cache: 'versioned' });
  const cached = await timedReads(1000, () => h.read.read({ ...base, cache: 'versioned' }));
  const cold = await timedReads(1000, () => h.read.read({ ...base, cache: 'none' }));
  const hit = await h.read.read({ ...base, cache: 'versioned' });
  const objectStarted = performance.now();
  let objectReads = 0;
  while (performance.now() - objectStarted < 1000) {
    if (hit.cards.length !== 40) throw new Error('cache body changed');
    objectReads += 1;
  }
  const objectMs = performance.now() - objectStarted;
  return {
    cached,
    cold,
    inProcessObject: { reads: objectReads, ms: objectMs, perReadMs: objectMs / objectReads },
  };
}

async function timedReads(ms: number, fn: () => Promise<unknown>) {
  const started = performance.now();
  let reads = 0;
  while (performance.now() - started < ms) {
    await fn();
    reads += 1;
  }
  const elapsed = performance.now() - started;
  return { reads, ms: elapsed, perReadMs: elapsed / reads };
}

async function walGrowth(h: Harness) {
  const file = path.join(h.root, 'stress-wal.sqlite');
  h.decks.commitMutable({
    file,
    version: 1,
    mutation: { type: 'seed-cards', count: 20, idPrefix: 'card-' },
    autocheckpoint: 0,
  });
  const readers = Array.from({ length: 8 }, () => h.decks.holdReader(file));
  const writes = 200;
  try {
    const started = performance.now();
    for (let i = 0; i < writes; i++) {
      h.decks.commitMutable({
        file,
        version: i + 2,
        mutation: { type: 'append-hist', cardId: 'card-0', rating: 1, reviewedAt: i },
        autocheckpoint: 0,
      });
    }
    const writeMs = performance.now() - started;
    const grown = sidecarBytes(file);
    const passive = h.decks.checkpoint(file, 'PASSIVE');
    const truncate = h.decks.checkpoint(file, 'TRUNCATE');
    const whileHeld = sidecarBytes(file);
    for (const reader of readers) {
      reader.exec('ROLLBACK');
      reader.close();
    }
    readers.length = 0;
    const released = h.decks.checkpoint(file, 'TRUNCATE');
    return {
      writes,
      writeMs,
      grown,
      whileHeld,
      afterRelease: sidecarBytes(file),
      passive,
      truncate,
      released,
    };
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
}

async function largeDeck(h: Harness) {
  const sizes = [1000, 10_000, 30_000];
  const rows = [];
  for (const count of sizes) {
    const immutable = await timePublish(h, 'immutable', count);
    const mutable = await timePublish(h, 'mutable', count);
    rows.push({ count, immutable, mutable });
  }
  const deck = await makeDeck(h, { mutation: { type: 'seed-cards', count: 10_000, idPrefix: 'card-' } });
  let maxGap = 0;
  let last = performance.now();
  const timer = setInterval(() => {
    const now = performance.now();
    maxGap = Math.max(maxGap, now - last);
    last = now;
  }, 5);
  const jobs = Array.from({ length: 4 }, () =>
    startJob({
      type: 'hammer',
      databaseUrl: DATABASE_URL,
      deckId: deck.deckId,
      readerId: deck.ownerId,
      durationMs: 4000,
      snapshot: 'tx',
      uriMode: 'ro-immutable',
      followPointer: true,
      part: 'both',
    }),
  );
  const publishStarted = performance.now();
  const published = await h.publish.publish(
    publishInput(h, {
      deckId: deck.deckId,
      actorId: deck.ownerId,
      mutation: { type: 'append-hist', cardId: 'card-0', rating: 1, reviewedAt: 1 },
    }),
  );
  const publishMs = performance.now() - publishStarted;
  clearInterval(timer);
  const readers = fold(await Promise.all(jobs.map((job) => finishJob<HammerRow>(job))), 4000);
  return {
    sizes: rows,
    readersDuringCopy: {
      publishMs,
      maxEventLoopGapMs: maxGap,
      status: published.status,
      bytes: published.status === 'ok' ? published.bytes : null,
      readers,
    },
  };
}

async function timePublish(h: Harness, strategy: 'immutable' | 'mutable', count: number) {
  const deck = await h.publish.createDeck({
    ownerHandle: `large-${strategy}-${count}-${randomUUID()}`,
    title: 'large',
    root: h.root,
    strategy,
  });
  const started = performance.now();
  const result = await h.publish.publish(
    publishInput(h, {
      deckId: deck.deckId,
      actorId: deck.ownerId,
      strategy,
      mutation: { type: 'seed-cards', count, idPrefix: 'card-' },
    }),
  );
  const createMs = performance.now() - started;
  if (result.status !== 'ok') throw new Error(`${strategy} ${count} publish ${result.status}`);
  const secondStarted = performance.now();
  const second = await h.publish.publish(
    publishInput(h, {
      deckId: deck.deckId,
      actorId: deck.ownerId,
      strategy,
      mutation: { type: 'append-hist', cardId: 'card-0', rating: 1, reviewedAt: 1 },
    }),
  );
  const appendMs = performance.now() - secondStarted;
  if (second.status !== 'ok') throw new Error(`${strategy} ${count} append ${second.status}`);
  return { createMs, appendMs, bytes: second.bytes, path: second.path };
}

async function gcHolders(h: Harness) {
  const deck = await makeDeck(h, { mutation: { type: 'seed-cards', count: 20, idPrefix: 'card-' } });
  const previous = deck.published.path;
  const sab = new SharedArrayBuffer(4);
  const holders = Array.from({ length: 8 }, () =>
    startJob({ type: 'hold', path: previous, uriMode: 'ro', sab }),
  );
  const deadline = Date.now() + 10_000;
  while (holders.some((job) => !job.events.some((event) => event.type === 'held'))) {
    if (Date.now() > deadline) throw new Error('holders did not open');
    await sleep(5);
  }
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
  const unlinked = !fs.existsSync(previous);
  signal(sab);
  const results = await Promise.all(holders.map((job) => finishJob<{
    stillMatches: boolean;
    readError: string | null;
    version: number;
  }>(job)));
  let openError: string | null = null;
  try {
    const db = (await import('../src/deck-store/sqlite')).openDatabase(previous, 'ro');
    db.close();
  } catch (error) {
    openError = error instanceof Error ? error.message : String(error);
  }
  return {
    deletedPrevious: removed.deleted.includes(previous),
    unlinked,
    holders: results.length,
    stillMatched: results.filter((item) => item.stillMatches && item.readError === null).length,
    newOpenError: openError,
  };
}

async function hammer(
  h: Harness,
  opts: {
    label: string;
    deckId: string;
    readerId: string;
    readers: number;
    durationMs: number;
    strategy: 'immutable' | 'mutable' | 'replace';
    snapshot: 'tx' | 'loose';
    uriMode: 'ro' | 'ro-immutable';
    followPointer: boolean;
    fixedPath?: string;
    part: 'both' | 'pointer' | 'body';
    publishEveryMs: number;
    pointerDelayMs: number;
    publish?: boolean;
  },
) {
  const jobs = Array.from({ length: opts.readers }, () =>
    startJob(
      {
        type: 'hammer',
        databaseUrl: DATABASE_URL,
        deckId: opts.deckId,
        readerId: opts.readerId,
        durationMs: opts.durationMs,
        snapshot: opts.snapshot,
        uriMode: opts.uriMode,
        followPointer: opts.followPointer,
        fixedPath: opts.fixedPath,
        part: opts.part,
      },
      opts.durationMs + 30_000,
    ),
  );
  let publishes = 0;
  let publishErrors = 0;
  const publishMs: number[] = [];
  const writer = (async () => {
    if (opts.publish === false) return;
    const end = performance.now() + opts.durationMs;
    let n = 0;
    while (performance.now() < end) {
      const started = performance.now();
      try {
        const result = await h.publish.publish(
          publishInput(h, {
            deckId: opts.deckId,
            actorId: opts.readerId,
            strategy: opts.strategy,
            processLock: true,
            pointerDelayMs: opts.pointerDelayMs,
            mutation: { type: 'append-hist', cardId: 'card-0', rating: (n % 5) + 1, reviewedAt: n + 1 },
          }),
        );
        if (result.status !== 'ok') publishErrors += 1;
        else publishes += 1;
      } catch {
        publishErrors += 1;
      }
      publishMs.push(performance.now() - started);
      n += 1;
      if (opts.publishEveryMs > 0) await sleep(opts.publishEveryMs);
    }
  })();
  const results = await Promise.all(jobs.map((job) => finishJob<HammerRow>(job)));
  await writer;
  return {
    label: opts.label,
    ...fold(results, opts.durationMs),
    publishes,
    publishErrors,
    publishP50Ms: percentile(publishMs, 50),
    publishMaxMs: publishMs.length ? Math.max(...publishMs) : 0,
  };
}

function fold(results: HammerRow[], durationMs: number) {
  const latencies = results.flatMap((item) => item.latencies);
  const reads = results.reduce((sum, item) => sum + item.reads, 0);
  const errors = results.reduce((sum, item) => sum + item.errors, 0);
  const versions: Record<string, number> = {};
  for (const item of results) {
    for (const [key, value] of Object.entries(item.versions)) versions[key] = (versions[key] ?? 0) + value;
  }
  return {
    readers: results.length,
    reads,
    errors,
    mixed: results.reduce((sum, item) => sum + item.mixed, 0),
    skew: results.reduce((sum, item) => sum + item.skew, 0),
    throughputPerSec: reads / (durationMs / 1000),
    p50Ms: percentile(latencies, 50),
    p99Ms: percentile(latencies, 99),
    minMs: results.length ? Math.min(...results.map((item) => item.min)) : null,
    maxMs: results.length ? Math.max(...results.map((item) => item.max)) : null,
    sampled: results.some((item) => item.sampled),
    sampleErrors: [...new Set(results.flatMap((item) => item.sampleErrors))].slice(0, 6),
    versions,
  };
}

void main().catch((error: unknown) => {
  console.error(error);
  process.exit(1);
});
