import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import test from "node:test";
import { runFedifyLab } from "../src/fedify/lab";

test("two Fedify instances exchange deck revisions", { timeout: 120_000 }, async () => {
  const report = await runFedifyLab();
  const file = path.join(process.cwd(), "results", "fedify.json");
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, JSON.stringify(report, null, 2));
  const pub = report.publicUpdate as {
    digestOk: boolean;
    dispatcherStatus: number;
    dispatcherBody: { "hatto:rev"?: number; "hatto:guid"?: string };
    deliver: { error: string | null; posts: Array<{ status: number }> };
  };
  assert.equal(pub.deliver.error, null, JSON.stringify(pub.deliver));
  assert.equal(pub.deliver.posts[0]?.status, 202);
  assert.equal(pub.dispatcherStatus, 200);
  assert.equal(pub.dispatcherBody["hatto:rev"], 2);
  assert.equal(pub.dispatcherBody["hatto:guid"], "public-deck");
  assert.equal(pub.digestOk, true);

  const embed = report.embed as {
    singleParse: string;
    singlePost: { status: number; body: string };
    arrayCompact: { type: string; hattoRev: unknown };
    arraySend: { posts: Array<{ status: number; hattoKeys: string[] }> };
    arrayPost: { status: number };
    listener: Array<{ embedded?: { "hatto:rev"?: number; type?: unknown } }>;
  };
  assert.match(embed.singleParse, /Invalid type: hatto:Deck/);
  assert.equal(embed.singlePost.status, 400);
  assert.equal(embed.arrayCompact.type, "Object");
  assert.equal(embed.arrayCompact.hattoRev, null);
  assert.equal(embed.arraySend.posts[0]?.status, 202);
  assert.deepEqual(embed.arraySend.posts[0]?.hattoKeys, []);
  assert.equal(embed.arrayPost.status, 202);
  assert.equal(embed.listener.at(-1)?.embedded?.["hatto:rev"], 2);

  const note = report.createNote as {
    directCompact: { keys: string[]; hatto: string[] };
    separateDispatcher: { status: number; body: Record<string, unknown> };
  };
  assert.deepEqual(note.directCompact.hatto, []);
  assert.ok(note.directCompact.keys.includes("content"));
  assert.equal(note.separateDispatcher.status, 200);
  assert.equal(note.separateDispatcher.body["hatto:event"], "deck-published");
  assert.equal(note.separateDispatcher.body["hatto:streakDays"], 12);

  const dedup = report.dedup as {
    duplicate: { calls: number[]; reducer: { applied: number; duplicates: number; head: number }; inbox: number[] };
    reverse: { arrival: number[]; head: number; olderKept: number };
  };
  assert.deepEqual(dedup.duplicate.calls, [1, 1]);
  assert.equal(dedup.duplicate.reducer.duplicates, 1);
  assert.equal(dedup.duplicate.reducer.head, 1);
  assert.deepEqual(dedup.duplicate.inbox, [202, 202, 202]);
  assert.deepEqual(dedup.reverse.arrival, [3, 1]);
  assert.equal(dedup.reverse.head, 3);
  assert.equal(dedup.reverse.olderKept, 1);

  const priv = report.privateDeck as {
    unsignedStatus: number;
    strangerStatus: number;
    ownerStatus: number;
    digestOk: boolean;
    expiredStatus: number;
    ownerHattoRev: number;
  };
  assert.equal(priv.unsignedStatus, 404);
  assert.equal(priv.strangerStatus, 404);
  assert.equal(priv.ownerStatus, 200);
  assert.equal(priv.ownerHattoRev, 1);
  assert.equal(priv.digestOk, true);
  assert.equal(priv.expiredStatus, 404);
});
