import fs from 'node:fs';
import path from 'node:path';
import type { PrismaService } from './prisma/prisma.service';
import { integrityOf, listSqliteFiles, readManifestFile } from './deck-store/sqlite';

const OUTBOX_TYPE = 'deck.version.published';
const PAYLOAD_KEYS = new Set(['version', 'contentHash', 'byteSize', 'cardCount', 'histCount']);

export type WorldReport = {
  pointerOk: boolean;
  outboxOk: boolean;
  pointerProblems: string[];
  outboxProblems: string[];
  danglingVersionRows: string[];
  orphans: string[];
  temps: string[];
  decks: number;
};

export async function inspectWorld(prisma: PrismaService, root: string): Promise<WorldReport> {
  const pointerProblems: string[] = [];
  const outboxProblems: string[] = [];
  const danglingVersionRows: string[] = [];
  const decks = await prisma.deck.findMany({
    include: { versions: true, outbox: true, activities: true },
  });
  const referenced = new Set<string>();

  for (const deck of decks) {
    if (deck.currentPath) referenced.add(deck.currentPath);
    for (const version of deck.versions) referenced.add(version.path);

    if (deck.currentVersion === 0) {
      if (deck.currentPath) pointerProblems.push(`${deck.id} version 0 has a path`);
      if (deck.outbox.length) outboxProblems.push(`${deck.id} version 0 has outbox rows`);
      continue;
    }
    if (!deck.currentPath || !fs.existsSync(deck.currentPath)) {
      pointerProblems.push(`${deck.id} pointer ${deck.currentVersion} file missing`);
    } else {
      const integrity = integrityOf(deck.currentPath);
      if (!integrity.ok) {
        pointerProblems.push(`${deck.id} pointer file corrupt: ${integrity.detail}`);
      } else {
        const manifest = readManifestFile(deck.currentPath);
        if (!manifest) pointerProblems.push(`${deck.id} pointer file has no manifest`);
        else if (manifest.version !== deck.currentVersion || manifest.hash !== deck.contentHash) {
          pointerProblems.push(
            `${deck.id} pointer v${deck.currentVersion}/${deck.contentHash} but file v${manifest.version}/${manifest.hash}`,
          );
        }
      }
    }

    const published = deck.outbox.filter((row) => row.type === OUTBOX_TYPE);
    const currentOutbox = published.filter((row) => row.version === deck.currentVersion);
    if (currentOutbox.length !== 1) {
      outboxProblems.push(`${deck.id} current outbox count ${currentOutbox.length}`);
    }
    const currentActivity = deck.activities.filter((row) => row.version === deck.currentVersion);
    if (currentActivity.length !== 1) {
      outboxProblems.push(`${deck.id} current activity count ${currentActivity.length}`);
    }
    for (const row of published) {
      if (row.version > deck.currentVersion) {
        outboxProblems.push(`${deck.id} outbox future v${row.version}`);
      }
      if (!deck.versions.some((version) => version.version === row.version)) {
        outboxProblems.push(`${deck.id} outbox v${row.version} without version row`);
      }
      const payload = row.payload as Record<string, unknown>;
      for (const key of Object.keys(payload)) {
        if (!PAYLOAD_KEYS.has(key)) outboxProblems.push(`${deck.id} outbox payload key ${key}`);
      }
    }
    for (const version of deck.versions) {
      if (!published.some((row) => row.version === version.version)) {
        outboxProblems.push(`${deck.id} version v${version.version} without outbox`);
      }
      if (!fs.existsSync(version.path)) {
        danglingVersionRows.push(`${deck.id} v${version.version} ${version.path}`);
        continue;
      }
      const manifest = readManifestFile(version.path);
      if (!manifest || manifest.version !== version.version || manifest.hash !== version.contentHash) {
        pointerProblems.push(`${deck.id} historical v${version.version} bytes do not match the version row`);
      }
    }
  }

  const orphans: string[] = [];
  const temps: string[] = [];
  for (const file of listSqliteFiles(root)) {
    if (referenced.has(file)) continue;
    if (path.basename(file).startsWith('.tmp-')) temps.push(file);
    else orphans.push(file);
  }

  return {
    pointerOk: pointerProblems.length === 0,
    outboxOk: outboxProblems.length === 0,
    pointerProblems,
    outboxProblems,
    danglingVersionRows,
    orphans,
    temps,
    decks: decks.length,
  };
}
