import fs from 'node:fs';
import path from 'node:path';
import { Injectable } from '@nestjs/common';
import { CatalogService } from '../catalog/catalog.service';
import { DeckStoreService } from '../deck-store/deck-store.service';
import { listSqliteFiles } from '../deck-store/sqlite';

export type GcMode = 'naive-current' | 'recheck' | 'stale-list';

export type GcRequest = {
  root: string;
  mode: GcMode;
  graceMs: number;
  respectLeases: boolean;
  respectPins: boolean;
  /** Buggy mode: unlink against a snapshot taken earlier, not the live catalog. */
  stalePaths?: Set<string>;
};

export type GcReport = {
  deleted: string[];
  kept: string[];
};

@Injectable()
export class GcService {
  constructor(
    private readonly decks: DeckStoreService,
    private readonly catalog: CatalogService,
  ) {}

  async collect(req: GcRequest): Promise<GcReport> {
    const files = listSqliteFiles(req.root);
    if (req.mode === 'stale-list' && !req.stalePaths) {
      throw new Error('stale-list GC requires the snapshot it is going to misuse');
    }
    let referenced =
      req.mode === 'stale-list'
        ? req.stalePaths!
        : req.mode === 'naive-current'
          ? await this.catalog.currentPaths()
          : await this.catalog.referencedPaths();
    const leases = req.respectLeases ? await this.catalog.activeLeasePaths() : new Set<string>();
    const deleted: string[] = [];
    const kept: string[] = [];
    for (const file of files) {
      if (req.mode === 'recheck') {
        referenced = await this.catalog.referencedPaths();
      }
      const age = Date.now() - fs.statSync(file).mtimeMs;
      const base = path.basename(file);
      const temp = base.startsWith('.tmp-');
      const live =
        referenced.has(file) ||
        leases.has(file) ||
        (req.respectPins && this.decks.isPinned(file));
      if (live || age < req.graceMs || (temp && age < req.graceMs)) {
        kept.push(file);
        continue;
      }
      fs.unlinkSync(file);
      for (const suffix of ['-wal', '-shm']) {
        const side = `${file}${suffix}`;
        if (fs.existsSync(side)) fs.unlinkSync(side);
      }
      deleted.push(file);
    }
    return { deleted, kept };
  }
}
