import { Injectable } from '@nestjs/common';
import type { ReadBody } from '../deck-store/sqlite';

type Slot = { body: ReadBody; bytes: number; last: number };

/** Process-local body cache. Keys are the caller's problem (versioned vs deck id). */
@Injectable()
export class BodyCache {
  readonly capBytes = 32 * 1024 * 1024;
  private readonly slots = new Map<string, Slot>();
  private tick = 0;
  private resident = 0;

  get(key: string): Slot | undefined {
    const slot = this.slots.get(key);
    if (!slot) return undefined;
    slot.last = ++this.tick;
    return slot;
  }

  set(key: string, body: ReadBody, bytes: number): void {
    const existing = this.slots.get(key);
    if (existing) this.resident -= existing.bytes;
    while (this.resident + bytes > this.capBytes && this.slots.size > 0) {
      this.evictOne();
    }
    this.slots.set(key, { body, bytes, last: ++this.tick });
    this.resident += bytes;
  }

  private evictOne(): void {
    let best: string | null = null;
    let bestTick = Infinity;
    for (const [key, slot] of this.slots) {
      if (slot.last < bestTick) {
        bestTick = slot.last;
        best = key;
      }
    }
    if (!best) return;
    const slot = this.slots.get(best);
    if (!slot) return;
    this.resident -= slot.bytes;
    this.slots.delete(best);
  }
}
