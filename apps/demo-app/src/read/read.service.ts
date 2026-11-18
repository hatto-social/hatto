import { Injectable } from '@nestjs/common';
import { CatalogService } from '../catalog/catalog.service';
import { DeckStoreService } from '../deck-store/deck-store.service';
import { bodyHash, type OpenMode, type ReadBody } from '../deck-store/sqlite';
import { ForbiddenError } from '../faults';
import { BodyCache } from './body-cache';

export type CacheMode = 'none' | 'versioned' | 'by-deck';

export type ReadRequest = {
  deckId: string;
  readerId: string;
  snapshot: 'tx' | 'loose';
  uriMode: OpenMode;
  cache: CacheMode;
  pin: 'none' | 'fd' | 'lease';
  leaseTtlMs?: number;
  holder?: string;
  verifyRehash?: boolean;
};

export type ReadView = ReadBody & {
  pointerVersion: number;
  pointerHash: string | null;
  pointerPath: string;
  skew: boolean;
  cache: 'miss' | 'hit';
  leaseId?: string;
};

@Injectable()
export class ReadService {
  constructor(
    private readonly decks: DeckStoreService,
    private readonly catalog: CatalogService,
    private readonly cache: BodyCache,
  ) {}

  async read(req: ReadRequest): Promise<ReadView> {
    const pointer = await this.catalog.resolve(req.deckId, req.readerId);
    if (!pointer || !pointer.path || !pointer.hash) throw new ForbiddenError('no published version');

    if (req.cache === 'by-deck') {
      const hit = this.cache.get(req.deckId);
      if (hit) {
        return {
          ...hit.body,
          pointerVersion: pointer.version,
          pointerHash: pointer.hash,
          pointerPath: pointer.path,
          skew: hit.body.manifest.version !== pointer.version || hit.body.manifest.hash !== pointer.hash,
          cache: 'hit',
        };
      }
    }
    const versionKey = `${pointer.path}:${pointer.hash}`;
    if (req.cache === 'versioned') {
      const hit = this.cache.get(versionKey);
      if (hit) {
        return {
          ...hit.body,
          pointerVersion: pointer.version,
          pointerHash: pointer.hash,
          pointerPath: pointer.path,
          skew: false,
          cache: 'hit',
        };
      }
    }

    let leaseId: string | undefined;
    if (req.pin === 'lease') {
      leaseId = await this.catalog.acquireLease({
        deckId: req.deckId,
        version: pointer.version,
        path: pointer.path,
        holder: req.holder ?? req.readerId,
        ttlMs: req.leaseTtlMs ?? 10_000,
      });
    }

    try {
      const openMode: OpenMode = req.uriMode === 'rw' ? 'ro' : req.uriMode;
      const body = this.decks.read(pointer.path, req.snapshot, openMode);
      let skew = body.manifest.version !== pointer.version || body.manifest.hash !== pointer.hash;
      if (req.verifyRehash) {
        const again = bodyHash(body.cards, body.fields, body.hist);
        if (again !== body.manifest.hash) skew = true;
      }
      const view: ReadView = {
        ...body,
        pointerVersion: pointer.version,
        pointerHash: pointer.hash,
        pointerPath: pointer.path,
        skew,
        cache: 'miss',
        leaseId,
      };
      if (req.cache === 'versioned') this.cache.set(versionKey, body, body.bytes);
      if (req.cache === 'by-deck') this.cache.set(req.deckId, body, body.bytes);
      return view;
    } finally {
      if (leaseId && req.pin === 'lease') {
        // The pin covers the open+read. Callers that need the lease to outlive
        // the call should use CatalogService.acquireLease themselves.
        await this.catalog.releaseLease(leaseId);
      }
    }
  }
}
