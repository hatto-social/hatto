import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import test from "node:test";
import { digestMatches, digestMultibase } from "../src/fedify/digest";

const W3C_EMPTY = "zQmdfTbBqBPQ7VNxZEYEj14VmRuZBkqFbiwReogJgS1zR1n";
const HASHLINK_HELLO = "zQmWvQxTqbG2Z9HPJgG57jjwR154cKhbtJenbyYTWkjgF3e";

interface Vector {
  name: string;
  utf8: string;
  z: string;
  u: string;
  digestHex: string;
  legacyPrefixlessU: string;
}

interface Fixture {
  w3cDataIntegrityExample: string;
  hashlinkDraftHelloWorld: string;
  vectors: Vector[];
  rejectedByThisCode: {
    emptyBase64: string;
    emptyBase16: string;
    sha1Base58btc: string;
    emptyOverlongVarint: string;
  };
}

const fixture = JSON.parse(
  fs.readFileSync(path.join(process.cwd(), "test", "fixtures", "fedify-digest-multibase.json"), "utf8"),
) as Fixture;

function bytesOf(vector: Vector): Buffer {
  return Buffer.from(vector.utf8, "utf8");
}

test("digestMultibase matches the Fedify 2.5.0-dev computeDigestMultibase fixture", () => {
  assert.equal(fixture.w3cDataIntegrityExample, W3C_EMPTY);
  assert.equal(fixture.hashlinkDraftHelloWorld, HASHLINK_HELLO);
  for (const vector of fixture.vectors) {
    const bytes = bytesOf(vector);
    assert.equal(createHash("sha256").update(bytes).digest("hex"), vector.digestHex, vector.name);
    assert.equal(digestMultibase(bytes), vector.z, vector.name);
    assert.notEqual(vector.u, vector.z, vector.name);
  }
  assert.equal(digestMultibase(Buffer.alloc(0)), W3C_EMPTY);
  assert.equal(digestMultibase(Buffer.from("Hello World!")), HASHLINK_HELLO);
});

test("the same digest matches when written as u or as z", () => {
  for (const vector of fixture.vectors) {
    const bytes = bytesOf(vector);
    assert.equal(digestMatches(bytes, vector.z), true, vector.name);
    assert.equal(digestMatches(bytes, vector.u), true, vector.name);
    assert.equal(digestMatches(Buffer.from(`${vector.utf8}!`), vector.z), false, vector.name);
  }
  const empty = fixture.vectors[0];
  const hello = fixture.vectors.find((vector) => vector.name === "hello-world");
  assert.ok(hello);
  assert.equal(digestMatches(Buffer.alloc(0), hello.z), false);
  assert.equal(digestMatches(Buffer.from("Hello World!"), empty.u), false);
});

test("a prefix-less legacy value, or an unsupported multibase or hash, is not accepted", () => {
  const rejected = fixture.rejectedByThisCode;
  for (const vector of fixture.vectors) {
    const bytes = bytesOf(vector);
    assert.equal(digestMatches(bytes, vector.legacyPrefixlessU), false, vector.name);
  }
  assert.equal(
    digestMatches(Buffer.from("public-snapshot-v2"), "u2Y_RqSYPhXGpTkVKD__xPDb0M7suBcYiPgp7PcMnx1Q"),
    false,
  );
  assert.equal(digestMatches(Buffer.alloc(0), rejected.emptyBase64), false);
  assert.equal(digestMatches(Buffer.alloc(0), rejected.emptyBase16), false);
  assert.equal(digestMatches(Buffer.alloc(0), rejected.sha1Base58btc), false);
  assert.equal(digestMatches(Buffer.alloc(0), rejected.emptyOverlongVarint), false);
  assert.equal(digestMatches(Buffer.alloc(0), ""), false);
  assert.equal(digestMatches(Buffer.alloc(0), "z"), false);
  assert.equal(digestMatches(Buffer.alloc(0), "u"), false);
  assert.equal(digestMatches(Buffer.alloc(0), `${W3C_EMPTY}=`), false);
  assert.equal(digestMatches(Buffer.alloc(0), `u${fixture.vectors[0].u.slice(1)}=`), false);
});
