import { parentPort } from 'node:worker_threads';
import { Client } from 'pg';
import { RESOLVE_POINTER_SQL } from './catalog/queries';
import { openDatabase, readSnapshot, type OpenMode } from './deck-store/sqlite';
import { pgConfig } from './pg-config';

type HammerJob = {
  type: 'hammer';
  databaseUrl: string;
  deckId: string;
  readerId: string;
  durationMs: number;
  snapshot: 'tx' | 'loose';
  uriMode: OpenMode;
  followPointer: boolean;
  fixedPath?: string;
  part: 'both' | 'pointer' | 'body';
};

type SplitJob = {
  type: 'split';
  path: string;
  snapshot: 'tx' | 'loose';
  uriMode: OpenMode;
  sab: SharedArrayBuffer;
};

type HoldJob = {
  type: 'hold';
  path: string;
  uriMode: OpenMode;
  sab: SharedArrayBuffer;
};

type Job = HammerJob | SplitJob | HoldJob;

function waitFlag(sab: SharedArrayBuffer): void {
  const flag = new Int32Array(sab);
  const woke = Atomics.wait(flag, 0, 0, 20_000);
  if (woke === 'timed-out') throw new Error('worker timed out waiting for the parent');
}

async function hammer(job: HammerJob) {
  const client = job.part === 'body' ? null : new Client(pgConfig(job.databaseUrl));
  if (client) await client.connect();
  const latencies: number[] = [];
  let sampled = false;
  let reads = 0;
  let errors = 0;
  let mixed = 0;
  let skew = 0;
  let sum = 0;
  let min = Number.POSITIVE_INFINITY;
  let max = 0;
  const versions: Record<string, number> = {};
  const sampleErrors: string[] = [];
  const end = performance.now() + job.durationMs;
  try {
    while (performance.now() < end) {
      const started = performance.now();
      try {
        let pointerVersion: number | null = null;
        let pointerHash: string | null = null;
        let file = job.fixedPath;
        if (job.followPointer) {
          const result = await client!.query(RESOLVE_POINTER_SQL, [job.deckId, job.readerId]);
          if (result.rowCount !== 1) throw new Error(`pointer rows ${result.rowCount}`);
          const row = result.rows[0] as {
            current_version: number;
            current_path: string;
            content_hash: string;
          };
          pointerVersion = Number(row.current_version);
          pointerHash = row.content_hash;
          file = row.current_path;
        }
        if (job.part !== 'pointer') {
          if (!file) throw new Error('no file');
          const db = openDatabase(file, job.uriMode);
          try {
            const body = readSnapshot(db, job.snapshot);
            if (body.mixed) mixed += 1;
            const key = String(body.manifest.version);
            versions[key] = (versions[key] ?? 0) + 1;
            if (
              pointerVersion !== null &&
              (body.manifest.version !== pointerVersion || body.manifest.hash !== pointerHash)
            ) {
              skew += 1;
            }
          } finally {
            db.close();
          }
        }
        reads += 1;
      } catch (error) {
        errors += 1;
        if (sampleErrors.length < 5) {
          sampleErrors.push(error instanceof Error ? error.message : String(error));
        }
      }
      const dt = performance.now() - started;
      sum += dt;
      if (dt < min) min = dt;
      if (dt > max) max = dt;
      const observed = reads + errors;
      if (latencies.length < 20_000) latencies.push(dt);
      else {
        sampled = true;
        const slot = Math.floor(Math.random() * observed);
        if (slot < latencies.length) latencies[slot] = dt;
      }
    }
  } finally {
    await client?.end();
  }
  return {
    type: 'result' as const,
    reads,
    errors,
    mixed,
    skew,
    versions,
    sampleErrors,
    sampled,
    sum,
    min: reads + errors === 0 ? 0 : min,
    max,
    latencies,
  };
}

async function run(job: Job) {
  if (job.type === 'hammer') return hammer(job);
  if (job.type === 'split') {
    const db = openDatabase(job.path, job.uriMode);
    try {
      const body = readSnapshot(db, job.snapshot, {
        afterManifest: () => {
          parentPort?.postMessage({ type: 'paused' });
          waitFlag(job.sab);
        },
      });
      const histMax = body.hist.reduce((max, row) => Math.max(max, row.rev), 0);
      return {
        type: 'result' as const,
        mixed: body.mixed,
        version: body.manifest.version,
        histMax,
        hash: body.manifest.hash,
      };
    } finally {
      db.close();
    }
  }
  const db = openDatabase(job.path, job.uriMode);
  const first = readSnapshot(db, 'tx');
  parentPort?.postMessage({
    type: 'held',
    version: first.manifest.version,
    hash: first.manifest.hash,
  });
  waitFlag(job.sab);
  let second: ReturnType<typeof readSnapshot> | null = null;
  let readError: string | null = null;
  try {
    second = readSnapshot(db, 'tx');
  } catch (error) {
    readError = error instanceof Error ? error.message : String(error);
  }
  db.close();
  return {
    type: 'result' as const,
    mixed: second?.mixed ?? true,
    version: second?.manifest.version ?? -1,
    hash: second?.manifest.hash ?? '',
    stillMatches: second !== null && second.manifest.hash === first.manifest.hash,
    readError,
  };
}

void (async () => {
  const job = await new Promise<Job>((resolve) => {
    parentPort?.once('message', (message: Job) => resolve(message));
  });
  try {
    const result = await run(job);
    parentPort?.postMessage(result);
  } catch (error) {
    parentPort?.postMessage({
      type: 'error',
      message: error instanceof Error ? error.message : String(error),
    });
  }
})();
