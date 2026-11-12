import fs from 'node:fs';
import { Injectable } from '@nestjs/common';
import type Database from 'better-sqlite3';
import { openDatabase, type OpenMode } from './sqlite';

type Entry = {
  db: Database.Database;
  bytes: number;
  last: number;
  pins: number;
  mode: OpenMode;
};

/**
 * Byte-capped LRU of open SQLite handles. A pinned handle is not evicted.
 * One file larger than the cap is still opened: the cap is not a hard deny.
 */
@Injectable()
export class HandleLru {
  private readonly entries = new Map<string, Entry>();
  private tick = 0;
  private resident = 0;
  readonly opens = { count: 0 };
  readonly hits = { count: 0 };
  readonly evictions = { count: 0 };
  overCap = false;

  constructor(readonly capBytes: number) {}

  key(file: string, mode: OpenMode): string {
    return `${mode}\0${file}`;
  }

  open(file: string, mode: OpenMode): Database.Database {
    const key = this.key(file, mode);
    const existing = this.entries.get(key);
    if (existing) {
      existing.last = ++this.tick;
      existing.pins += 1;
      this.hits.count += 1;
      return existing.db;
    }
    const bytes = fs.statSync(file).size;
    this.evictUntil(bytes);
    const db = openDatabase(file, mode);
    this.entries.set(key, { db, bytes, last: ++this.tick, pins: 1, mode });
    this.resident += bytes;
    this.opens.count += 1;
    if (this.resident > this.capBytes) this.overCap = true;
    return db;
  }

  unpin(file: string, mode: OpenMode): void {
    const entry = this.entries.get(this.key(file, mode));
    if (!entry) return;
    entry.pins = Math.max(0, entry.pins - 1);
  }

  isPinnedFile(file: string): boolean {
    for (const [key, entry] of this.entries) {
      if (entry.pins > 0 && (key === file || key.endsWith(`\0${file}`))) return true;
    }
    return false;
  }

  private evictUntil(incoming: number): void {
    while (this.resident + incoming > this.capBytes) {
      const victim = this.oldestUnpinned();
      if (!victim) return;
      this.closeKey(victim);
    }
  }

  private oldestUnpinned(): string | null {
    let best: string | null = null;
    let bestTick = Infinity;
    for (const [key, entry] of this.entries) {
      if (entry.pins > 0) continue;
      if (entry.last < bestTick) {
        bestTick = entry.last;
        best = key;
      }
    }
    return best;
  }

  private closeKey(key: string): void {
    const entry = this.entries.get(key);
    if (!entry) return;
    entry.db.close();
    this.resident -= entry.bytes;
    this.entries.delete(key);
    this.evictions.count += 1;
  }

  stats(): {
    capBytes: number;
    residentBytes: number;
    handles: number;
    pinned: number;
    opens: number;
    hits: number;
    evictions: number;
    overCap: boolean;
  } {
    let pinned = 0;
    for (const entry of this.entries.values()) if (entry.pins > 0) pinned += 1;
    return {
      capBytes: this.capBytes,
      residentBytes: this.resident,
      handles: this.entries.size,
      pinned,
      opens: this.opens.count,
      hits: this.hits.count,
      evictions: this.evictions.count,
      overCap: this.overCap,
    };
  }

  closeAll(): void {
    for (const key of [...this.entries.keys()]) this.closeKey(key);
    this.resident = 0;
  }
}
