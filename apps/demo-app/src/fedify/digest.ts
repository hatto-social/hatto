import { createHash, createHmac, timingSafeEqual } from "node:crypto";

const SHA2_256 = 0x12;
const DIGEST_LENGTH = 0x20;
const MULTIHASH_LENGTH = 2 + DIGEST_LENGTH;
/** Same bound Fedify uses: a base2 spelling of a 34-byte multihash, plus the prefix. */
const MAX_DIGEST_MULTIBASE_LENGTH = 1 + MULTIHASH_LENGTH * 8;
const BASE58_ALPHABET = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz";

/**
 * The only writer of `digestMultibase`.
 *
 * `z` (base58btc) + multihash(sha2-256: `0x12 0x20` || SHA-256).
 * The bytes match Fedify's `computeDigestMultibase`.
 */
export function digestMultibase(bytes: Buffer): string {
  const digest = createHash("sha256").update(bytes).digest();
  const multihash = Buffer.alloc(MULTIHASH_LENGTH);
  multihash[0] = SHA2_256;
  multihash[1] = DIGEST_LENGTH;
  digest.copy(multihash, 2);
  return `z${encodeBase58Btc(multihash)}`;
}

/**
 * True when `digest` is a canonical `u` (base64url) or `z` (base58btc)
 * sha2-256 multihash of `bytes`.
 *
 * A prefix-less value, any other multibase code, or any other hash code is
 * a mismatch. The raw 32-byte digests are compared in constant time.
 */
export function digestMatches(bytes: Buffer, digest: string): boolean {
  const claimed = parseSha256Multihash(digest);
  if (claimed === null) return false;
  const actual = createHash("sha256").update(bytes).digest();
  return timingSafeEqual(actual, claimed);
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

function encodeBase58Btc(data: Buffer): string {
  let zeros = 0;
  while (zeros < data.length && data[zeros] === 0) zeros += 1;
  let value = 0n;
  for (const byte of data) value = (value << 8n) + BigInt(byte);
  let encoded = "";
  while (value > 0n) {
    const index = Number(value % 58n);
    value /= 58n;
    encoded = BASE58_ALPHABET[index] + encoded;
  }
  return "1".repeat(zeros) + encoded;
}

function decodeBase58Btc(text: string): Buffer | null {
  let zeros = 0;
  while (zeros < text.length && text[zeros] === "1") zeros += 1;
  let value = 0n;
  for (let i = zeros; i < text.length; i += 1) {
    const index = BASE58_ALPHABET.indexOf(text[i]);
    if (index < 0) return null;
    value = value * 58n + BigInt(index);
  }
  const body: number[] = [];
  while (value > 0n) {
    body.push(Number(value & 0xffn));
    value >>= 8n;
  }
  body.reverse();
  return Buffer.concat([Buffer.alloc(zeros), Buffer.from(body)]);
}

function decodeBase64Url(text: string): Buffer | null {
  if (text.length === 0 || !/^[A-Za-z0-9_-]+$/.test(text)) return null;
  const bytes = Buffer.from(text, "base64url");
  if (bytes.toString("base64url") !== text) return null;
  return bytes;
}

function parseSha256Multihash(value: string): Buffer | null {
  if (value.length < 2 || value.length > MAX_DIGEST_MULTIBASE_LENGTH) return null;
  const code = value[0];
  const payload = value.slice(1);
  const multihash = code === "z" ? decodeBase58Btc(payload) : code === "u" ? decodeBase64Url(payload) : null;
  if (multihash === null || multihash.length !== MULTIHASH_LENGTH) return null;
  if (multihash[0] !== SHA2_256 || multihash[1] !== DIGEST_LENGTH) return null;
  return Buffer.from(multihash.subarray(2));
}
