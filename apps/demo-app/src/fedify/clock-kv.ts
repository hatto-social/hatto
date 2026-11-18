import { MemoryKvStore, type KvKey, type KvStore, type KvStoreSetOptions } from "@fedify/fedify";
import { Temporal } from "temporal-polyfill";

/**
 * MemoryKvStore expiry for Fedify's activity idempotence keys, driven by a
 * clock the test can move. Other keys keep the inner store's wall clock.
 * Fedify writes those keys with a one-day TTL and treats the expiration
 * instant as still live.
 */
export class IdempotenceClock implements KvStore {
  readonly #inner = new MemoryKvStore();
  #now = Temporal.Now.instant();
  #expirations = new Map<string, Temporal.Instant>();
  lastIdempotenceTtl: string | null = null;

  get now(): string {
    return this.#now.toString();
  }

  advance(duration: Temporal.DurationLike): void {
    this.#now = this.#now.add(Temporal.Duration.from(duration));
  }

  async get<T = unknown>(key: KvKey): Promise<T | undefined> {
    if (await this.#dropIfExpired(key)) return undefined;
    return this.#inner.get<T>(key);
  }

  async set(key: KvKey, value: unknown, options?: KvStoreSetOptions): Promise<void> {
    if (this.#isIdempotence(key)) {
      const encoded = JSON.stringify(key);
      if (options?.ttl == null) this.#expirations.delete(encoded);
      else {
        const rounded = options.ttl.round({ largestUnit: "hour" });
        this.lastIdempotenceTtl = rounded.toString();
        this.#expirations.set(encoded, this.#now.add(rounded));
      }
      await this.#inner.set(key, value);
      return;
    }
    await this.#inner.set(key, value, options);
  }

  async delete(key: KvKey): Promise<void> {
    this.#expirations.delete(JSON.stringify(key));
    await this.#inner.delete(key);
  }

  async cas(key: KvKey, expectedValue: unknown, newValue: unknown, options?: KvStoreSetOptions): Promise<boolean> {
    await this.#dropIfExpired(key);
    if (!this.#isIdempotence(key)) return this.#inner.cas(key, expectedValue, newValue, options);
    const swapped = await this.#inner.cas(key, expectedValue, newValue);
    if (swapped) await this.set(key, newValue, options);
    return swapped;
  }

  async *list(prefix?: KvKey): AsyncIterable<{ key: KvKey; value: unknown }> {
    const expired: KvKey[] = [];
    for (const [encoded, expiration] of this.#expirations) {
      if (Temporal.Instant.compare(this.#now, expiration) > 0) expired.push(JSON.parse(encoded) as KvKey);
    }
    for (const key of expired) await this.delete(key);
    yield* this.#inner.list(prefix);
  }

  async idempotenceValues(): Promise<unknown[]> {
    const values: unknown[] = [];
    for await (const entry of this.list(["_fedify", "activityIdempotence"])) values.push(entry.value);
    return values;
  }

  #isIdempotence(key: KvKey): boolean {
    return key[0] === "_fedify" && key[1] === "activityIdempotence";
  }

  async #dropIfExpired(key: KvKey): Promise<boolean> {
    if (!this.#isIdempotence(key)) return false;
    const expiration = this.#expirations.get(JSON.stringify(key));
    if (expiration == null) return false;
    if (Temporal.Instant.compare(this.#now, expiration) <= 0) return false;
    await this.delete(key);
    return true;
  }
}
