export type RevRecord = {
  guid: string;
  rev: number;
  digest: string;
  hattoRev: number;
  hattoGuid: string;
};

export type ApplyResult = "applied" | "duplicate" | "older";

/**
 * App-level dedup. Fedify's own inbox dedup is separate and short-lived.
 * The key is (deck guid, rev), not the activity id alone.
 */
export class RevReducer {
  readonly seen = new Set<string>();
  readonly byDeck = new Map<string, Map<number, RevRecord>>();
  readonly order: RevRecord[] = [];
  head = new Map<string, number>();
  applied = 0;
  duplicates = 0;
  olderKept = 0;

  apply(record: RevRecord): ApplyResult {
    const key = `${record.guid}:${record.rev}`;
    if (this.seen.has(key)) {
      this.duplicates += 1;
      return "duplicate";
    }
    this.seen.add(key);
    const versions = this.byDeck.get(record.guid) ?? new Map<number, RevRecord>();
    versions.set(record.rev, record);
    this.byDeck.set(record.guid, versions);
    this.order.push(record);
    const current = this.head.get(record.guid) ?? 0;
    if (record.rev > current) {
      this.head.set(record.guid, record.rev);
      this.applied += 1;
      return "applied";
    }
    this.olderKept += 1;
    return "older";
  }
}
