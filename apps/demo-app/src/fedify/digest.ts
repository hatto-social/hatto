import { createHash, createHmac, timingSafeEqual } from "node:crypto";

/** Multibase base64url (`u`) of the raw SHA-256 digest. Both sides use this. */
export function digestMultibase(bytes: Buffer): string {
  const hash = createHash("sha256").update(bytes).digest();
  return `u${hash.toString("base64url")}`;
}

export function digestMatches(bytes: Buffer, digest: string): boolean {
  const expected = digestMultibase(bytes);
  const left = Buffer.from(expected);
  const right = Buffer.from(digest);
  return left.length === right.length && timingSafeEqual(left, right);
}

export function signSnapshot(secret: string, guid: string, rev: number, exp: number): string {
  return createHmac("sha256", secret).update(`${guid}/${rev}/${exp}`).digest("base64url");
}

export function verifySnapshot(
  secret: string,
  guid: string,
  rev: number,
  exp: number,
  sig: string,
  now = Date.now(),
): boolean {
  if (!Number.isFinite(exp) || exp < now) return false;
  const expected = signSnapshot(secret, guid, rev, exp);
  const left = Buffer.from(expected);
  const right = Buffer.from(sig);
  return left.length === right.length && timingSafeEqual(left, right);
}
