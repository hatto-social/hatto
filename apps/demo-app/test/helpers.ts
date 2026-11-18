import 'reflect-metadata';
import { spawn, type ChildProcess } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { scriptPath, compose, type Services } from '../src/compose';
import { loadEnv } from '../src/load-env';
import type { Mutation } from '../src/deck-store/sqlite';
import type { PublishRequest } from '../src/publish/publish.service';

loadEnv();

export const DATABASE_URL =
  process.env.DATABASE_URL ?? 'postgresql://ubuntu@localhost/hatto_spike?host=/var/run/postgresql';

export type Harness = Services & { root: string };

export async function createHarness(capBytes?: number): Promise<Harness> {
  process.env.DATABASE_URL = DATABASE_URL;
  const services = compose(capBytes);
  await services.prisma.$connect();
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'hatto-spike-'));
  return { ...services, root };
}

export async function reset(h: Harness): Promise<void> {
  await h.prisma.$executeRawUnsafe(
    `TRUNCATE TABLE read_leases, outbox, activities, deck_versions, deck_acl, decks, users RESTART IDENTITY CASCADE`,
  );
  h.lru.closeAll();
  fs.rmSync(h.root, { recursive: true, force: true });
  fs.mkdirSync(h.root, { recursive: true });
}

export async function closeHarness(h: Harness): Promise<void> {
  h.lru.closeAll();
  await h.prisma.$disconnect();
  fs.rmSync(h.root, { recursive: true, force: true });
}

export function publishInput(
  h: Harness,
  extra: Partial<PublishRequest> & Pick<PublishRequest, 'deckId' | 'actorId'>,
): PublishRequest {
  return {
    root: h.root,
    strategy: 'immutable',
    pathStyle: 'unique',
    processLock: true,
    advisoryLock: false,
    mutation: { type: 'seed-cards', count: 2, idPrefix: 'card-' },
    ...extra,
  };
}

export async function makeDeck(
  h: Harness,
  opts?: { strategy?: PublishRequest['strategy']; mutation?: Mutation; handle?: string },
) {
  const created = await h.publish.createDeck({
    ownerHandle: opts?.handle ?? `owner-${Date.now()}-${Math.random().toString(16).slice(2)}`,
    title: 'spike',
    root: h.root,
    strategy: opts?.strategy ?? 'immutable',
  });
  const published = await h.publish.publish(
    publishInput(h, {
      deckId: created.deckId,
      actorId: created.ownerId,
      strategy: opts?.strategy ?? 'immutable',
      mutation: opts?.mutation ?? { type: 'seed-cards', count: 2, idPrefix: 'card-' },
    }),
  );
  if (published.status !== 'ok') throw new Error(`seed publish failed: ${published.status}`);
  return { ...created, published };
}

export function runNode(
  script: string,
  env: Record<string, string | undefined>,
  timeoutMs = 20_000,
): Promise<{ code: number | null; signal: NodeJS.Signals | null; stdout: string; stderr: string }> {
  return new Promise((resolve, reject) => {
    const child: ChildProcess = spawn(process.execPath, [scriptPath(script)], {
      env: { ...process.env, ...env },
      stdio: ['ignore', 'pipe', 'pipe'],
    });
    let stdout = '';
    let stderr = '';
    child.stdout?.setEncoding('utf8');
    child.stderr?.setEncoding('utf8');
    child.stdout?.on('data', (chunk: string) => {
      stdout += chunk;
    });
    child.stderr?.on('data', (chunk: string) => {
      stderr += chunk;
    });
    const timer = setTimeout(() => {
      child.kill('SIGKILL');
      reject(new Error(`child timeout\nstdout=${stdout}\nstderr=${stderr}`));
    }, timeoutMs);
    child.on('exit', (code, signal) => {
      clearTimeout(timer);
      resolve({ code, signal, stdout, stderr });
    });
  });
}

export function lastJson(stdout: string): unknown {
  const line = stdout
    .trim()
    .split('\n')
    .map((item) => item.trim())
    .filter(Boolean)
    .at(-1);
  if (!line) throw new Error('child produced no stdout');
  return JSON.parse(line);
}

export function record(name: string, data: unknown): void {
  const file = path.join(process.cwd(), 'results', 'checks.json');
  fs.mkdirSync(path.dirname(file), { recursive: true });
  const prev = fs.existsSync(file) ? (JSON.parse(fs.readFileSync(file, 'utf8')) as Record<string, unknown>) : {};
  prev[name] = data;
  fs.writeFileSync(file, JSON.stringify(prev, null, 2));
}
