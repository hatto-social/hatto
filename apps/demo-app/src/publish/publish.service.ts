import { randomUUID } from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { Injectable } from '@nestjs/common';
import { CatalogService } from '../catalog/catalog.service';
import { DeckLock } from '../deck-store/deck-lock';
import { DeckStoreService } from '../deck-store/deck-store.service';
import type { Mutation, Seal } from '../deck-store/sqlite';
import {
  CorruptFileError,
  FaultInjected,
  type FaultPoint,
  type Gate,
} from '../faults';

export type BodyStrategy = 'immutable' | 'replace' | 'mutable';

export type PublishRequest = {
  deckId: string;
  actorId: string;
  root: string;
  mutation: Mutation;
  strategy: BodyStrategy;
  /** `unique` names the file with a token so two writers cannot clobber one path. */
  pathStyle: 'unique' | 'version';
  processLock: boolean;
  advisoryLock: boolean;
  databaseUrl?: string;
  fault?: FaultPoint | null;
  faultMode?: 'throw' | 'kill';
  gate?: Gate;
  pointerDelayMs?: number;
  skipFsync?: boolean;
  skipIntegrity?: boolean;
  skipExistenceCheck?: boolean;
  tearBeforeCommit?: boolean;
  seal?: Seal;
  autocheckpoint?: number;
  beforePointer?: () => unknown;
  onTxStart?: () => void;
};

export type PublishResult =
  | {
      status: 'ok';
      version: number;
      path: string;
      hash: string;
      bytes: number;
      cardCount: number;
      histCount: number;
    }
  | { status: 'conflict'; version: number; orphanPath: string; hash: string };

@Injectable()
export class PublishService {
  constructor(
    private readonly decks: DeckStoreService,
    private readonly catalog: CatalogService,
    private readonly locks: DeckLock,
  ) {}

  async createDeck(input: {
    ownerHandle: string;
    title: string;
    root: string;
    strategy?: BodyStrategy;
  }): Promise<{ deckId: string; ownerId: string }> {
    const owner = await this.catalog.ensureUser(input.ownerHandle);
    const deckId = randomUUID();
    const strategy = input.strategy ?? 'immutable';
    await this.catalog.createDeck({
      id: deckId,
      ownerId: owner.id,
      title: input.title,
      strategy,
    });
    fs.mkdirSync(path.join(input.root, deckId), { recursive: true });
    return { deckId, ownerId: owner.id };
  }

  async publish(req: PublishRequest): Promise<PublishResult> {
    const run = () => this.publishBody(req);
    if (req.advisoryLock) {
      const url = req.databaseUrl ?? process.env.DATABASE_URL;
      if (!url) throw new Error('DATABASE_URL is required for advisory locks');
      return this.catalog.withAdvisoryLock(url, req.deckId, () =>
        req.processLock ? this.locks.with(req.deckId, run) : run(),
      );
    }
    if (req.processLock) return this.locks.with(req.deckId, run);
    return run();
  }

  private async publishBody(req: PublishRequest): Promise<PublishResult> {
    await this.catalog.assertRole(req.deckId, req.actorId, 'owner');
    const deck = await this.catalog.getDeck(req.deckId);
    const next = deck.version + 1;
    const dir = path.join(req.root, req.deckId);
    fs.mkdirSync(dir, { recursive: true });
    const token = randomUUID();
    const finalPath = this.finalPath(dir, req, next, token);

    let hash: string;
    let bytes: number;
    let cardCount: number;
    let histCount: number;

    if (req.strategy === 'mutable') {
      const written = this.decks.commitMutable({
        file: finalPath,
        version: next,
        mutation: req.mutation,
        autocheckpoint: req.autocheckpoint,
      });
      hash = written.hash;
      bytes = written.bytes;
      cardCount = written.cardCount;
      histCount = written.histCount;
      this.hit(req, 'afterTempWrite');
      this.hit(req, 'afterRename');
    } else {
      const tmpPath = path.join(dir, `.tmp-${next}-${token}.sqlite`);
      const seal = req.seal ?? 'delete';
      const prepared = this.decks.prepareTemp({
        tmpPath,
        previousPath: deck.path,
        version: next,
        mutation: req.mutation,
        seal,
      });
      hash = prepared.hash;
      cardCount = prepared.cardCount;
      histCount = prepared.histCount;
      this.hit(req, 'afterTempWrite');
      this.hit(req, 'beforeFsync');
      if (!req.skipFsync) this.decks.fsyncFile(tmpPath);
      this.hit(req, 'afterFsync');
      this.hit(req, 'beforeRename');
      this.decks.publishRename(tmpPath, finalPath);
      if (!req.skipFsync) this.decks.fsyncDir(dir);
      bytes = this.decks.bytes(finalPath);
      this.hit(req, 'afterRename');
    }

    if (req.tearBeforeCommit) this.decks.corrupt(finalPath);
    if (!req.skipIntegrity) {
      const integrity = this.decks.integrity(finalPath);
      if (!integrity.ok) throw new CorruptFileError(integrity.detail);
    }
    if (req.beforePointer) await req.beforePointer();
    this.hit(req, 'beforePointerTx');

    const status = await this.catalog.commitPointer({
      deckId: req.deckId,
      actorId: req.actorId,
      expectedVersion: deck.version,
      version: next,
      path: finalPath,
      hash,
      bytes,
      cardCount,
      histCount,
      delayMs: req.pointerDelayMs,
      skipExistenceCheck: req.skipExistenceCheck,
      fileReady: () => fs.existsSync(finalPath),
      onTxStart: req.onTxStart,
      inside: () => this.hit(req, 'insidePointerTx'),
    });
    if (status === 'conflict') {
      return { status: 'conflict', version: next, orphanPath: finalPath, hash };
    }
    this.hit(req, 'afterPointerCommit');
    return { status: 'ok', version: next, path: finalPath, hash, bytes, cardCount, histCount };
  }

  private finalPath(dir: string, req: PublishRequest, version: number, token: string): string {
    if (req.strategy === 'mutable' || req.strategy === 'replace') {
      if (req.pathStyle === 'version' && req.strategy === 'replace') {
        return path.join(dir, `v${version}.sqlite`);
      }
      return path.join(dir, 'deck.sqlite');
    }
    if (req.pathStyle === 'version') return path.join(dir, `v${version}.sqlite`);
    return path.join(dir, `v${version}-${token}.sqlite`);
  }

  private hit(req: PublishRequest, point: FaultPoint): void {
    if (req.gate?.at === point) {
      fs.writeFileSync(req.gate.readyPath, point);
      const deadline = Date.now() + (req.gate.timeoutMs ?? 15_000);
      while (!fs.existsSync(req.gate.waitPath)) {
        if (Date.now() > deadline) throw new Error(`gate timeout at ${point}`);
        Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 10);
      }
    }
    if (req.fault !== point) return;
    if (req.faultMode === 'kill') {
      process.kill(process.pid, 'SIGKILL');
    }
    throw new FaultInjected(point);
  }
}
