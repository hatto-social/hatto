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

  const fork = report.forkMr as {
    uriHeard: Array<{ origin: string; context: string; object: string; hatto: string[] }>;
    uriSend: { error: string | null; posts: Array<{ status: number }> };
    embeddedHeard: Array<{ origin: string; context: string; embeddedHatto: string[]; embeddedUrl: { digestMultibase?: string } | null }>;
    fetch: { byteEqualToOriginal: boolean; signedByteEqual: boolean; schemaErrors: string[]; digestOk: boolean; unsignedBytes: number };
    control: { parsed: string; send: { posts: Array<{ activityHatto: string[]; origin: string }> } };
    acceptFlow: { offerHeard: Array<{ type: string; target: string }>; acceptHeard: Array<{ type: string; object: string }>; offerSend: { posts: Array<{ status: number }> }; acceptSend: { posts: Array<{ status: number }> } };
    rejectFlow: { rejectHeard: Array<{ type: string; object: string }>; rejectSend: { posts: Array<{ status: number }> } };
    duplicateOffer: { listenerOffers: number; listenerDuplicates: number; first: { posts: Array<{ status: number }> }; second: { posts: Array<{ status: number }> } };
    acceptBeforeOffer: { order: string[] };
  };
  assert.equal(fork.uriSend.error, null);
  assert.equal(fork.uriSend.posts[0]?.status, 202);
  assert.equal(fork.uriHeard[0]?.origin.endsWith("/decks/fork-source/revs/4"), true);
  assert.equal(fork.uriHeard[0]?.context.endsWith("/decks/fork-source"), true);
  assert.equal(fork.uriHeard[0]?.object.endsWith("/decks/fork-copy/revs/1"), true);
  assert.deepEqual(fork.uriHeard[0]?.hatto, []);
  assert.equal(fork.embeddedHeard[0]?.origin.endsWith("/decks/fork-source/revs/4"), true);
  assert.equal(fork.embeddedHeard[0]?.context.endsWith("/decks/fork-source"), true);
  assert.deepEqual(fork.embeddedHeard[0]?.embeddedHatto, []);
  assert.equal(fork.embeddedHeard[0]?.embeddedUrl?.digestMultibase, undefined);
  assert.equal(fork.fetch.byteEqualToOriginal, true);
  assert.equal(fork.fetch.signedByteEqual, true);
  assert.equal(fork.fetch.unsignedBytes, 624);
  assert.deepEqual(fork.fetch.schemaErrors, []);
  assert.equal(fork.fetch.digestOk, true);
  assert.deepEqual(JSON.parse(fork.control.parsed).hatto, []);
  assert.equal(fork.control.send.posts[0]?.origin.endsWith("/decks/fork-source/revs/4"), true);
  assert.deepEqual(fork.control.send.posts[0]?.activityHatto, []);
  assert.equal(fork.acceptFlow.offerSend.posts[0]?.status, 202);
  assert.equal(fork.acceptFlow.offerHeard[0]?.type, "Offer");
  assert.equal(fork.acceptFlow.offerHeard[0]?.target.endsWith("/decks/fork-source"), true);
  assert.equal(fork.acceptFlow.acceptSend.posts[0]?.status, 202);
  assert.equal(fork.acceptFlow.acceptHeard[0]?.type, "Accept");
  assert.equal(fork.acceptFlow.acceptHeard[0]?.object.endsWith("/activities/mrs/mr-accept"), true);
  assert.equal(fork.rejectFlow.rejectSend.posts[0]?.status, 202);
  assert.equal(fork.rejectFlow.rejectHeard[0]?.type, "Reject");
  assert.equal(fork.duplicateOffer.listenerOffers, 1);
  assert.equal(fork.duplicateOffer.listenerDuplicates, 0);
  assert.equal(fork.duplicateOffer.first.posts[0]?.status, 202);
  assert.equal(fork.duplicateOffer.second.posts[0]?.status, 202);
  assert.deepEqual(fork.acceptBeforeOffer.order, ["accept", "offer"]);
});
