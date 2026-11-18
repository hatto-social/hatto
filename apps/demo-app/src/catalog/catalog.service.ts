import { randomUUID } from 'node:crypto';
import { Injectable } from '@nestjs/common';
import { Prisma } from '@prisma/client';
import { Client } from 'pg';
import {
  ConflictError,
  FaultInjected,
  FileMissingError,
  ForbiddenError,
  type FaultPoint,
} from '../faults';
import { pgConfig } from '../pg-config';
import { PrismaService } from '../prisma/prisma.service';

export type PointerRow = {
  version: number;
  path: string | null;
  hash: string | null;
  bytes: number;
  strategy: string;
  ownerId: string;
};

const PUBLISHED = 'deck.version.published';

@Injectable()
export class CatalogService {
  constructor(private readonly prisma: PrismaService) {}

  async ensureUser(handle: string): Promise<{ id: string; handle: string }> {
    const existing = await this.prisma.user.findUnique({ where: { handle } });
    if (existing) return existing;
    return this.prisma.user.create({ data: { id: randomUUID(), handle } });
  }

  async createDeck(input: {
    id: string;
    ownerId: string;
    title: string;
    strategy: string;
  }): Promise<void> {
    await this.prisma.$transaction(async (tx) => {
      await tx.deck.create({
        data: {
          id: input.id,
          ownerId: input.ownerId,
          title: input.title,
          strategy: input.strategy,
          currentVersion: 0,
          byteSize: 0,
        },
      });
      await tx.deckAcl.create({
        data: { deckId: input.id, userId: input.ownerId, role: 'owner' },
      });
    });
  }

  async grant(deckId: string, userId: string, role: 'reader' | 'owner'): Promise<void> {
    await this.prisma.deckAcl.upsert({
      where: { deckId_userId: { deckId, userId } },
      create: { deckId, userId, role },
      update: { role },
    });
  }

  async revoke(deckId: string, userId: string): Promise<void> {
    await this.prisma.deckAcl.deleteMany({ where: { deckId, userId } });
  }

  async getDeck(deckId: string): Promise<PointerRow> {
    const deck = await this.prisma.deck.findUnique({ where: { id: deckId } });
    if (!deck) throw new Error(`deck ${deckId} not found`);
    return {
      version: deck.currentVersion,
      path: deck.currentPath,
      hash: deck.contentHash,
      bytes: deck.byteSize,
      strategy: deck.strategy,
      ownerId: deck.ownerId,
    };
  }

  /** Authorization source is the ACL row, not the owner_id column. */
  async assertRole(deckId: string, userId: string, role: 'owner' | 'reader'): Promise<void> {
    const row = await this.prisma.deckAcl.findUnique({
      where: { deckId_userId: { deckId, userId } },
    });
    if (!row) throw new ForbiddenError('no acl row');
    if (role === 'owner' && row.role !== 'owner') throw new ForbiddenError('not owner');
  }

  async resolve(deckId: string, userId: string): Promise<PointerRow | null> {
    const row = await this.prisma.deckAcl.findUnique({
      where: { deckId_userId: { deckId, userId } },
    });
    if (!row) return null;
    return this.getDeck(deckId);
  }

  /**
   * Session advisory locks are pinned to one connection. Prisma's pool can
   * lock on connection A and unlock on connection B, so this uses a dedicated
   * `pg` client for the whole critical section.
   */
  async withAdvisoryLock<T>(databaseUrl: string, deckId: string, fn: () => Promise<T>): Promise<T> {
    const client = new Client(pgConfig(databaseUrl));
    await client.connect();
    await client.query(`SELECT pg_advisory_lock(hashtextextended($1, 0))`, [deckId]);
    try {
      return await fn();
    } finally {
      try {
        await client.query(`SELECT pg_advisory_unlock(hashtextextended($1, 0))`, [deckId]);
      } finally {
        await client.end();
      }
    }
  }

  async commitPointer(input: {
    deckId: string;
    actorId: string;
    expectedVersion: number;
    version: number;
    path: string;
    hash: string;
    bytes: number;
    cardCount: number;
    histCount: number;
    delayMs?: number;
    skipExistenceCheck?: boolean;
    fileReady: () => boolean;
    onTxStart?: () => void;
    inside?: () => void;
  }): Promise<'ok' | 'conflict'> {
    try {
      await this.prisma.$transaction(
        async (tx) => {
          input.onTxStart?.();
          if (input.delayMs && input.delayMs > 0) {
            await tx.$executeRaw`SELECT pg_sleep(${input.delayMs / 1000})`;
          }
          if (!input.skipExistenceCheck && !input.fileReady()) {
            throw new FileMissingError(`version file missing: ${input.path}`);
          }
          const updated = await tx.deck.updateMany({
            where: { id: input.deckId, currentVersion: input.expectedVersion },
            data: {
              currentVersion: input.version,
              currentPath: input.path,
              contentHash: input.hash,
              byteSize: input.bytes,
            },
          });
          if (updated.count !== 1) throw new ConflictError();
          await tx.deckVersion.create({
            data: {
              deckId: input.deckId,
              version: input.version,
              path: input.path,
              contentHash: input.hash,
              byteSize: input.bytes,
            },
          });
          const payload = {
            version: input.version,
            contentHash: input.hash,
            byteSize: input.bytes,
            cardCount: input.cardCount,
            histCount: input.histCount,
          } satisfies Prisma.InputJsonValue;
          await tx.outbox.create({
            data: {
              id: randomUUID(),
              deckId: input.deckId,
              version: input.version,
              type: PUBLISHED,
              payload,
            },
          });
          await tx.activity.create({
            data: {
              id: randomUUID(),
              deckId: input.deckId,
              actorId: input.actorId,
              type: input.expectedVersion === 0 ? 'Create' : 'Update',
              version: input.version,
              payload,
            },
          });
          input.inside?.();
        },
        { timeout: 20_000, maxWait: 5_000 },
      );
    } catch (error) {
      if (error instanceof ConflictError || messageChain(error).includes('version conflict')) {
        return 'conflict';
      }
      if (messageChain(error).includes('version file missing')) {
        throw new FileMissingError(messageChain(error));
      }
      if (messageChain(error).includes('fault:')) {
        const point = messageChain(error).match(/fault:([A-Za-z]+)/)?.[1] ?? 'insidePointerTx';
        throw new FaultInjected(point as FaultPoint);
      }
      throw error;
    }
    return 'ok';
  }

  async referencedPaths(): Promise<Set<string>> {
    const rows = await this.prisma.deckVersion.findMany({ select: { path: true } });
    const current = await this.prisma.deck.findMany({
      where: { currentPath: { not: null } },
      select: { currentPath: true },
    });
    const set = new Set<string>();
    for (const row of rows) set.add(row.path);
    for (const row of current) if (row.currentPath) set.add(row.currentPath);
    return set;
  }

  async currentPaths(): Promise<Set<string>> {
    const current = await this.prisma.deck.findMany({
      where: { currentPath: { not: null } },
      select: { currentPath: true },
    });
    const set = new Set<string>();
    for (const row of current) if (row.currentPath) set.add(row.currentPath);
    return set;
  }

  async activeLeasePaths(): Promise<Set<string>> {
    const rows = await this.prisma.readLease.findMany({
      where: { expiresAt: { gt: new Date() } },
      select: { path: true },
    });
    return new Set(rows.map((r) => r.path));
  }

  async acquireLease(input: {
    deckId: string;
    version: number;
    path: string;
    holder: string;
    ttlMs: number;
  }): Promise<string> {
    const id = randomUUID();
    await this.prisma.readLease.create({
      data: {
        id,
        deckId: input.deckId,
        version: input.version,
        path: input.path,
        holder: input.holder,
        expiresAt: new Date(Date.now() + input.ttlMs),
      },
    });
    return id;
  }

  async releaseLease(id: string): Promise<void> {
    await this.prisma.readLease.delete({ where: { id } }).catch(() => undefined);
  }

  /**
   * Delivery is at-least-once. The row is marked only after `effect`.
   * A crash between them redelivers. Callers that need exactly-once must
   * make `effect` idempotent on (deckId, version, type).
   */
  async deliverOutbox(id: string, effect: (row: { id: string; version: number }) => void): Promise<'delivered' | 'already'> {
    const row = await this.prisma.outbox.findUnique({ where: { id } });
    if (!row) throw new Error(`outbox ${id} missing`);
    if (row.deliveredAt) return 'already';
    effect({ id: row.id, version: row.version });
    await this.prisma.outbox.update({ where: { id }, data: { deliveredAt: new Date() } });
    return 'delivered';
  }
}

export const OUTBOX_PUBLISHED = PUBLISHED;

function messageChain(error: unknown): string {
  const parts: string[] = [];
  let current: unknown = error;
  const seen = new Set<unknown>();
  while (current && typeof current === 'object' && !seen.has(current)) {
    seen.add(current);
    if (current instanceof Error) parts.push(current.name, current.message);
    current = (current as { cause?: unknown }).cause;
  }
  return parts.join('\n');
}
