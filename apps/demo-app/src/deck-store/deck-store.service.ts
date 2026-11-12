import fs from 'node:fs';
import path from 'node:path';
import { Injectable } from '@nestjs/common';
import { HandleLru } from './handle-lru';
import {
  buildTempFile,
  corruptMagic,
  createLegacyV1,
  fileBytes,
  fsyncPath,
  holdReadTransaction,
  integrityOf,
  journalModeOf,
  mutateInPlace,
  readFileSnapshot,
  readSnapshot,
  sidecarBytes,
  walCheckpoint,
  type BuiltFile,
  type Mutation,
  type OpenMode,
  type ReadBody,
  type Seal,
  type SnapshotHooks,
} from './sqlite';

export type PreparedFile = {
  tmpPath: string;
  finalPath: string;
  hash: string;
  cardCount: number;
  histCount: number;
  bytes: number;
};

@Injectable()
export class DeckStoreService {
  constructor(readonly lru: HandleLru) {}

  /** Private temp file. Not visible at the published path yet. */
  prepareTemp(opts: {
    tmpPath: string;
    previousPath: string | null;
    version: number;
    mutation: Mutation;
    seal: Seal;
  }): Omit<PreparedFile, 'finalPath' | 'bytes'> & { bytes: number } {
    const built = buildTempFile(opts);
    return { ...built, tmpPath: opts.tmpPath, bytes: fileBytes(opts.tmpPath) };
  }

  fsyncFile(file: string): void {
    fsyncPath(file);
  }

  fsyncDir(dir: string): void {
    fsyncPath(dir);
  }

  publishRename(tmpPath: string, finalPath: string): void {
    fs.mkdirSync(path.dirname(finalPath), { recursive: true });
    fs.renameSync(tmpPath, finalPath);
  }

  corrupt(file: string): void {
    corruptMagic(file);
  }

  integrity(file: string): { ok: boolean; detail: string } {
    return integrityOf(file);
  }

  bytes(file: string): number {
    return fileBytes(file);
  }

  commitMutable(opts: {
    file: string;
    version: number;
    mutation: Mutation;
    autocheckpoint?: number;
  }): BuiltFile {
    return mutateInPlace(opts);
  }

  read(file: string, mode: 'tx' | 'loose', openMode: OpenMode, hooks?: SnapshotHooks): ReadBody {
    const db = this.lru.open(file, openMode);
    try {
      const body = readSnapshot(db, mode, hooks);
      return { ...body, bytes: fs.statSync(file).size };
    } finally {
      this.lru.unpin(file, openMode);
    }
  }

  /** Opens its own connection. Used when the caller must not share the LRU handle. */
  readDedicated(
    file: string,
    mode: 'tx' | 'loose',
    openMode: OpenMode,
    hooks?: SnapshotHooks,
  ): ReadBody {
    return readFileSnapshot(file, mode, openMode, hooks);
  }

  journalMode(file: string): string {
    return journalModeOf(file);
  }

  sidecars(file: string): { wal: number; shm: number } {
    return sidecarBytes(file);
  }

  checkpoint(file: string, mode: 'PASSIVE' | 'FULL' | 'RESTART' | 'TRUNCATE') {
    return walCheckpoint(file, mode);
  }

  holdReader(file: string) {
    return holdReadTransaction(file);
  }

  writeLegacy(file: string, count: number): void {
    createLegacyV1(file, count);
  }

  /**
   * Copy a deck file out. Checkpoint first when the source is WAL, or the
   * copy of the main file can miss commits that still live in the WAL.
   */
  exportFile(src: string, dest: string, checkpoint: boolean): void {
    if (checkpoint) {
      walCheckpoint(src, 'TRUNCATE');
    }
    fs.copyFileSync(src, dest);
  }

  isPinned(file: string): boolean {
    return this.lru.isPinnedFile(file);
  }
}
