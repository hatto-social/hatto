import { getDocumentLoader } from "@fedify/vocab-runtime";
import { INLINE_CONTEXTS } from "./context-doc";
import { digestMatches, digestMultibase } from "./digest";
import { SIGNED_URL_TTL_MS, startPeer, type Peer } from "./peer";
import { RevReducer } from "./reducer";
import { SnapshotCdn } from "./snapshot-cdn";

type Json = Record<string, unknown>;

export async function runFedifyLab(): Promise<Json> {
  await quietLogs();
  const cdn = new SnapshotCdn();
  await cdn.start();
  const alice = await startPeer("alice", cdn);
  const bob = await startPeer("bob", cdn);
  const report: Json = {
    fedify: "2.4.5",
    cdn: "static-file-server",
    cdnOrigin: cdn.origin,
    alice: alice.origin,
    bob: bob.origin,
    signedUrlTtlMs: SIGNED_URL_TTL_MS,
  };
  try {
    report.context = await contextCases(alice);
    report.publicUpdate = await publicUpdate(alice, bob, cdn);
    report.embed = await embeddedUpdates(alice, bob);
    report.createNote = await createNotes(alice, bob);
    report.dedup = await dedupAndOrder(alice, bob, cdn);
    report.privateDeck = await privateDeck(alice, bob, cdn);
    report.forkMr = await forkAndMerge(alice, bob, cdn);
  } finally {
    await alice.stop();
    await bob.stop();
    await cdn.stop();
  }
  return report;
}

async function quietLogs(): Promise<void> {
  const { configure, getConsoleSink } = await import("@logtape/logtape");
  await configure({
    sinks: { console: getConsoleSink() },
    loggers: [
      { category: ["fedify"], lowestLevel: "fatal", sinks: ["console"] },
      { category: ["logtape", "meta"], lowestLevel: "fatal", sinks: ["console"] },
    ],
  }).catch(() => undefined);
}

async function contextCases(alice: Peer): Promise<Json> {
  const missing = await parseError(alice, [
    "https://www.w3.org/ns/activitystreams",
    "https://hatto.invalid/ns.jsonld",
  ]);
  const served = await alice.vocab.Object.fromJsonLd(
    {
      "@context": ["https://www.w3.org/ns/activitystreams", `${alice.origin}/contexts/hatto.jsonld`],
      id: `${alice.origin}/decks/context-probe/revs/1`,
      type: ["hatto:Deck", "Object"],
      "hatto:rev": 1,
    },
    { contextLoader: fetchingContextLoader() },
  )
    .then(async (object) => {
      const json = (await object.toJsonLd()) as Json;
      return { error: null, hattoRev: json["hatto:rev"] ?? null, type: json.type ?? null };
    })
    .catch((error: unknown) => ({ error: message(error), hattoRev: null, type: null }));
  return { missing, served };
}

async function parseError(alice: Peer, context: unknown): Promise<string> {
  try {
    await alice.vocab.Object.fromJsonLd({
      "@context": context,
      id: `${alice.origin}/decks/bad-context`,
      type: "Object",
    });
    return "parsed";
  } catch (error) {
    return message(error);
  }
}

function fetchingContextLoader() {
  const builtin = getDocumentLoader();
  return async (url: string) => {
    if (url.includes("/contexts/hatto.jsonld")) {
      const response = await fetch(url);
      if (!response.ok) throw new Error(`context ${response.status} ${url}`);
      return { contextUrl: null, documentUrl: url, document: await response.json() };
    }
    return builtin(url);
  };
}

async function publicUpdate(alice: Peer, bob: Peer, cdn: SnapshotCdn): Promise<Json> {
  const guid = "public-deck";
  const rev = 2;
  const bytes = Buffer.from("public-snapshot-v2");
  const digest = digestMultibase(bytes);
  cdn.put({ guid, rev, bytes, isPrivate: false });
  alice.revs.set(`${guid}/${rev}`, {
    guid,
    rev,
    title: "공개 덱",
    bytes,
    digest,
    isPrivate: false,
    readers: new Set(),
  });
  const seen: Json[] = [];
  bob.onUpdate(async (ctx, activity) => {
    const json = (await asActivity(activity).toJsonLd()) as Json;
    if (!String(json.id).includes(guid)) return;
    seen.push(await describeActivity(ctx, activity));
  });
  const activity = new alice.vocab.Update({
    id: new URL(activityId(alice, guid, rev)),
    actor: new URL(alice.actorId),
    object: new URL(revUri(alice, guid, rev)),
    to: new URL(bob.actorId),
  });
  const sent = await deliver(alice, bob, activity, guid);
  const fetched = await fetch(revUri(alice, guid, rev), {
    headers: { accept: "application/activity+json" },
  });
  const fetchedBody = (await fetched.json()) as Json;
  const href = linkHref(fetchedBody);
  const snapshot = href ? await fetch(href) : null;
  const snapshotBytes = snapshot ? Buffer.from(await snapshot.arrayBuffer()) : Buffer.alloc(0);
  return {
    deliver: sent,
    listener: seen,
    dispatcherStatus: fetched.status,
    dispatcherBody: fetchedBody,
    snapshotStatus: snapshot?.status ?? null,
    snapshotBytes: snapshotBytes.length,
    digestOk: href ? digestMatches(snapshotBytes, digest) : false,
  };
}

async function embeddedUpdates(alice: Peer, bob: Peer): Promise<Json> {
  const singleDocument = {
    "@context": "https://www.w3.org/ns/activitystreams",
    id: activityId(alice, "embed", 1),
    type: "Update",
    actor: alice.actorId,
    to: bob.actorId,
    object: {
      id: revUri(alice, "embed", 1),
      type: "hatto:Deck",
      "hatto:rev": 1,
      "hatto:guid": "embed",
    },
  };
  const singleParse = await alice.vocab.Update.fromJsonLd(singleDocument)
    .then(() => "parsed")
    .catch((error: unknown) => message(error));
  const singlePost = await signedPost(alice, bob, singleDocument);
  const arrayObject = {
    id: revUri(alice, "embed", 2),
    type: ["hatto:Deck", "Object"],
    name: "임베드",
    "hatto:rev": 2,
    "hatto:guid": "embed",
  };
  const arrayDocument = {
    "@context": INLINE_CONTEXTS,
    id: `${activityId(alice, "embed", 2)}-raw`,
    type: "Update",
    actor: alice.actorId,
    to: bob.actorId,
    object: arrayObject,
  };
  const parsedObject = await alice.vocab.Object.fromJsonLd({
    "@context": INLINE_CONTEXTS,
    ...arrayObject,
  });
  const arrayActivity = new alice.vocab.Update({
    id: new URL(activityId(alice, "embed", 2)),
    actor: new URL(alice.actorId),
    object: parsedObject,
    to: new URL(bob.actorId),
  });
  const compact = (await arrayActivity.toJsonLd({ format: "compact" })) as Json;
  const before = bob.inboxPosts.length;
  const seen: Json[] = [];
  bob.onUpdate(async (ctx, activity) => {
    const json = (await asActivity(activity).toJsonLd()) as Json;
    if (!String(json.id).includes("/embed/")) return;
    seen.push(await describeActivity(ctx, activity));
  });
  const arraySend = await deliver(alice, bob, arrayActivity, "embed");
  const arrayPost = await signedPost(alice, bob, arrayDocument);
  return {
    singleParse,
    singlePost,
    arraySend,
    arrayCompact: {
      type: objectField(compact).type ?? null,
      keys: Object.keys(objectField(compact)),
      hattoRev: objectField(compact)["hatto:rev"] ?? null,
    },
    arrayPost,
    listener: seen,
    wire: bob.inboxPosts.slice(before).map(summarizePost),
  };
}

async function createNotes(alice: Peer, bob: Peer): Promise<Json> {
  const direct = await alice.vocab.Note.fromJsonLd({
    "@context": INLINE_CONTEXTS,
    id: `${alice.origin}/notes/direct`,
    type: "Note",
    content: "덱을 공개했습니다",
    "hatto:deck": `${alice.origin}/decks/social`,
    "hatto:event": "deck-published",
    "hatto:streakDays": 12,
    "hatto:reviewCount": 40,
    "hatto:measurementSource": "self-reported-device",
  });
  const directCreate = new alice.vocab.Create({
    id: new URL(`${alice.origin}/activities/notes/direct`),
    actor: new URL(alice.actorId),
    object: direct,
    to: new URL(bob.actorId),
  });
  const directCompact = (await directCreate.toJsonLd({ format: "compact" })) as Json;
  const directSend = await deliver(alice, bob, directCreate, "social");
  const standard = new alice.vocab.Note({
    id: new URL(`${alice.origin}/notes/standard`),
    content: "덱을 공개했습니다",
    tags: [new alice.vocab.Link({ href: new URL(`${alice.origin}/decks/social`), name: "deck-published" })],
    attachments: [new alice.vocab.PropertyValue({ name: "hatto:event", value: "deck-published" })],
    url: new alice.vocab.Link({
      href: new URL(`${alice.origin}/decks/social`),
      mediaType: "application/activity+json",
      name: "deck",
    }),
  });
  const standardCreate = new alice.vocab.Create({
    id: new URL(`${alice.origin}/activities/notes/standard`),
    actor: new URL(alice.actorId),
    object: standard,
    to: new URL(bob.actorId),
  });
  const standardCompact = (await standardCreate.toJsonLd({ format: "compact" })) as Json;
  const standardSend = await deliver(alice, bob, standardCreate, "social-standard");
  const separateId = "separate";
  alice.notes.set(separateId, {
    "@context": INLINE_CONTEXTS,
    id: `${alice.origin}/notes/${separateId}`,
    type: "Note",
    content: "덱을 공개했습니다",
    "hatto:deck": `${alice.origin}/decks/social`,
    "hatto:event": "deck-published",
    "hatto:streakDays": 12,
    "hatto:reviewCount": 40,
    "hatto:measurementSource": "self-reported-device",
  });
  const separateCreate = new alice.vocab.Create({
    id: new URL(`${alice.origin}/activities/notes/separate`),
    actor: new URL(alice.actorId),
    object: new URL(`${alice.origin}/notes/${separateId}`),
    to: new URL(bob.actorId),
  });
  const fetchedNotes: Json[] = [];
  bob.onCreate(async (ctx, activity) => {
    fetchedNotes.push(await describeActivity(ctx, activity));
  });
  const separateSend = await deliver(alice, bob, separateCreate, "social-separate");
  const separateGet = await fetch(`${alice.origin}/notes/${separateId}`, {
    headers: { accept: "application/activity+json" },
  });
  const separateBody = (await separateGet.json()) as Json;
  return {
    directCompact: summarizeObject(objectField(directCompact)),
    directSend,
    standardCompact: summarizeObject(objectField(standardCompact)),
    standardSend,
    separateSend,
    separateDispatcher: { status: separateGet.status, body: separateBody },
    listener: fetchedNotes,
  };
}

async function dedupAndOrder(alice: Peer, bob: Peer, cdn: SnapshotCdn): Promise<Json> {
  const guid = "ordered-deck";
  const reducer = new RevReducer();
  const calls: number[] = [];
  bob.onUpdate(async (_ctx, activity) => {
    const json = (await asActivity(activity).toJsonLd()) as Json;
    const rev = Number(String(json.id).match(/revs\/(\d+)/)?.[1]);
    if (!String(json.id).includes(guid)) return;
    calls.push(rev);
    reducer.apply({ guid, rev, digest: "", hattoRev: rev, hattoGuid: guid });
  });
  const sendRev = async (rev: number, id: string) => {
    const bytes = Buffer.from(`ordered-${rev}`);
    cdn.put({ guid, rev, bytes, isPrivate: false });
    alice.revs.set(`${guid}/${rev}`, {
      guid,
      rev,
      title: "순서",
      bytes,
      digest: digestMultibase(bytes),
      isPrivate: false,
      readers: new Set(),
    });
    await deliver(
      alice,
      bob,
      new alice.vocab.Update({
        id: new URL(id),
        actor: new URL(alice.actorId),
        object: new URL(revUri(alice, guid, rev)),
        to: new URL(bob.actorId),
      }),
      guid,
    );
  };
  await sendRev(1, activityId(alice, guid, 1));
  await sendRev(1, activityId(alice, guid, 1));
  await sendRev(1, `${activityId(alice, guid, 1)}-retry`);
  const duplicate = {
    calls: [...calls],
    reducer: { applied: reducer.applied, duplicates: reducer.duplicates, head: reducer.head.get(guid) ?? null },
    inbox: bob.inboxPosts.filter((post) => post.body.includes(guid)).map((post) => post.status),
  };
  const reverse: number[] = [];
  const reverseReducer = new RevReducer();
  bob.onUpdate(async (_ctx, activity) => {
    const json = (await asActivity(activity).toJsonLd()) as Json;
    if (!String(json.id).includes("reverse-deck")) return;
    const rev = Number(String(json.id).match(/revs\/(\d+)/)?.[1]);
    reverse.push(rev);
    reverseReducer.apply({ guid: "reverse-deck", rev, digest: "", hattoRev: rev, hattoGuid: "reverse-deck" });
  });
  for (const rev of [3, 1]) {
    const bytes = Buffer.from(`reverse-${rev}`);
    const id = "reverse-deck";
    cdn.put({ guid: id, rev, bytes, isPrivate: false });
    alice.revs.set(`${id}/${rev}`, {
      guid: id,
      rev,
      title: "역순",
      bytes,
      digest: digestMultibase(bytes),
      isPrivate: false,
      readers: new Set(),
    });
    await deliver(
      alice,
      bob,
      new alice.vocab.Update({
        id: new URL(activityId(alice, id, rev)),
        actor: new URL(alice.actorId),
        object: new URL(revUri(alice, id, rev)),
        to: new URL(bob.actorId),
      }),
      id,
    );
  }
  return {
    duplicate,
    reverse: {
      arrival: reverse,
      head: reverseReducer.head.get("reverse-deck") ?? null,
      olderKept: reverseReducer.olderKept,
      stored: [...(reverseReducer.byDeck.get("reverse-deck")?.keys() ?? [])].sort((a, b) => a - b),
    },
  };
}

async function privateDeck(alice: Peer, bob: Peer, cdn: SnapshotCdn): Promise<Json> {
  const guid = "private-deck";
  const rev = 1;
  const bytes = Buffer.from("private-snapshot");
  const digest = digestMultibase(bytes);
  cdn.put({ guid, rev, bytes, isPrivate: true });
  alice.revs.set(`${guid}/${rev}`, {
    guid,
    rev,
    title: "비공개",
    bytes,
    digest,
    isPrivate: true,
    readers: new Set([bob.actorId]),
  });
  const url = revUri(alice, guid, rev);
  const unsigned = await fetch(url, { headers: { accept: "application/activity+json" } });
  const stranger = await signedGet(alice, url);
  const owner = await signedGet(bob, url);
  const ownerText = owner.status === 200 ? await owner.response.text() : "";
  const ownerBody = ownerText ? (JSON.parse(ownerText) as Json) : null;
  const href = ownerBody ? linkHref(ownerBody) : null;
  const fresh = href ? await fetch(href) : null;
  const freshBytes = fresh ? Buffer.from(await fresh.arrayBuffer()) : Buffer.alloc(0);
  await new Promise((resolve) => setTimeout(resolve, SIGNED_URL_TTL_MS + 250));
  const expired = href ? await fetch(href) : null;
  return {
    unsignedStatus: unsigned.status,
    strangerStatus: stranger.status,
    strangerKeyId: stranger.keyId,
    ownerStatus: owner.status,
    ownerKeyId: owner.keyId,
    ownerError: owner.error,
    lastSigner: alice.lastSigner,
    ownerHattoRev: ownerBody?.["hatto:rev"] ?? null,
    ownerHattoGuid: ownerBody?.["hatto:guid"] ?? null,
    snapshotStatus: fresh?.status ?? null,
    digestOk: fresh ? digestMatches(freshBytes, digest) : false,
    expiredStatus: expired?.status ?? null,
    href,
  };
}

async function forkAndMerge(alice: Peer, bob: Peer, cdn: SnapshotCdn): Promise<Json> {
  const sourceGuid = "fork-source";
  const forkGuid = "fork-copy";
  const sourceRev = revUri(alice, sourceGuid, 4);
  const deckUri = `${alice.origin}/decks/${sourceGuid}`;
  const forkRev = revUri(bob, forkGuid, 1);
  const sourceBytes = Buffer.from("fork-source-rev-4");
  const forkBytes = Buffer.from("fork-copy-rev-1");
  const sourceDigest = digestMultibase(sourceBytes);
  const forkDigest = digestMultibase(forkBytes);
  cdn.put({ guid: sourceGuid, rev: 4, bytes: sourceBytes, isPrivate: false });
  cdn.put({ guid: forkGuid, rev: 1, bytes: forkBytes, isPrivate: false });
  alice.revs.set(`${sourceGuid}/4`, revRecord(sourceGuid, 4, "원본", sourceBytes, sourceDigest));
  bob.revs.set(`${forkGuid}/1`, revRecord(forkGuid, 1, "포크", forkBytes, forkDigest));
  const forkDocument = {
    "@context": INLINE_CONTEXTS,
    id: forkRev,
    type: ["hatto:Deck", "Object"],
    name: "포크",
    "hatto:rev": 1,
    "hatto:guid": forkGuid,
    url: {
      type: "Link",
      href: cdn.publicUrl(forkGuid, 1),
      mediaType: "application/octet-stream",
      digestMultibase: forkDigest,
    },
  };
  bob.documents.set(`${forkGuid}/1`, forkDocument);
  const originalText = JSON.stringify(forkDocument);

  const uriCreate = new bob.vocab.Create({
    id: new URL(forkActivityId(bob, forkGuid, 1)),
    actor: new URL(bob.actorId),
    object: new URL(forkRev),
    origin: new URL(sourceRev),
    contexts: [new URL(deckUri)],
    to: new URL(alice.actorId),
  });
  const uriHeard: Json[] = [];
  alice.onCreate(async (_ctx, activity) => {
    const json = (await asActivity(activity).toJsonLd()) as Json;
    if (json.id !== forkActivityId(bob, forkGuid, 1)) return;
    uriHeard.push(activityFields(json));
  });
  const uriSend = await deliver(bob, alice, uriCreate, forkGuid);

  const embeddedObject = await bob.vocab.Object.fromJsonLd(forkDocument);
  const embeddedCreate = new bob.vocab.Create({
    id: new URL(forkActivityId(bob, forkGuid, 2)),
    actor: new URL(bob.actorId),
    object: embeddedObject,
    origin: new URL(sourceRev),
    contexts: [new URL(deckUri)],
    to: new URL(alice.actorId),
  });
  const embeddedHeard: Json[] = [];
  alice.onCreate(async (_ctx, activity) => {
    const json = (await asActivity(activity).toJsonLd()) as Json;
    if (json.id !== forkActivityId(bob, forkGuid, 2)) return;
    embeddedHeard.push(activityFields(json));
  });
  const embeddedSend = await deliver(bob, alice, embeddedCreate, forkGuid);

  const unsigned = await fetch(forkRev, { headers: { accept: "application/activity+json" } });
  const unsignedBody = await unsigned.text();
  const signed = await signedGet(alice, forkRev);
  const signedBody = signed.status === 200 ? await signed.response.text() : "";
  const parsed = parseJson(unsignedBody);
  const schemaErrors = validateRev(parsed, {
    id: forkRev,
    guid: forkGuid,
    rev: 1,
    digest: forkDigest,
  });
  const href = linkHref(parsed);
  const snapshot = href ? await fetch(href) : null;
  const snapshotBytes = snapshot ? Buffer.from(await snapshot.arrayBuffer()) : Buffer.alloc(0);

  const controlDocument = {
    "@context": INLINE_CONTEXTS,
    id: forkActivityId(bob, forkGuid, 9),
    type: "Create",
    actor: bob.actorId,
    to: alice.actorId,
    object: forkRev,
    origin: sourceRev,
    context: deckUri,
    "hatto:origin": sourceRev,
    "hatto:context": deckUri,
  };
  let controlParse: string | null = null;
  let controlSend: Json | null = null;
  try {
    const control = await bob.vocab.Create.fromJsonLd(controlDocument);
    const compact = (await control.toJsonLd({ format: "compact" })) as Json;
    controlParse = JSON.stringify(activityFields(compact));
    controlSend = await deliver(bob, alice, control, forkGuid);
  } catch (error) {
    controlParse = message(error);
  }

  const offerId = `${bob.origin}/activities/mrs/mr-accept`;
  const offer = new bob.vocab.Offer({
    id: new URL(offerId),
    actor: new URL(bob.actorId),
    object: new URL(forkRev),
    target: new URL(deckUri),
    to: new URL(alice.actorId),
  });
  const offerHeard: Json[] = [];
  alice.onOffer(async (_ctx, activity) => {
    const json = (await asActivity(activity).toJsonLd()) as Json;
    if (json.id !== offerId) return;
    offerHeard.push(activityFields(json));
  });
  const offerSend = await deliver(bob, alice, offer, "mr-accept");
  const acceptId = `${alice.origin}/activities/mrs/mr-accept/accept`;
  const accept = new alice.vocab.Accept({
    id: new URL(acceptId),
    actor: new URL(alice.actorId),
    object: new URL(offerId),
    to: new URL(bob.actorId),
  });
  const acceptHeard: Json[] = [];
  bob.onAccept(async (_ctx, activity) => {
    const json = (await asActivity(activity).toJsonLd()) as Json;
    if (json.id !== acceptId) return;
    acceptHeard.push(activityFields(json));
  });
  const acceptSend = await deliver(alice, bob, accept, "mr-accept");

  const rejectOfferId = `${bob.origin}/activities/mrs/mr-reject`;
  const rejectOffer = new bob.vocab.Offer({
    id: new URL(rejectOfferId),
    actor: new URL(bob.actorId),
    object: new URL(forkRev),
    target: new URL(deckUri),
    to: new URL(alice.actorId),
  });
  const rejectOfferHeard: Json[] = [];
  alice.onOffer(async (_ctx, activity) => {
    const json = (await asActivity(activity).toJsonLd()) as Json;
    if (json.id !== rejectOfferId) return;
    rejectOfferHeard.push(activityFields(json));
  });
  const rejectOfferSend = await deliver(bob, alice, rejectOffer, "mr-reject");
  const rejectId = `${alice.origin}/activities/mrs/mr-reject/reject`;
  const reject = new alice.vocab.Reject({
    id: new URL(rejectId),
    actor: new URL(alice.actorId),
    object: new URL(rejectOfferId),
    to: new URL(bob.actorId),
  });
  const rejectHeard: Json[] = [];
  bob.onReject(async (_ctx, activity) => {
    const json = (await asActivity(activity).toJsonLd()) as Json;
    if (json.id !== rejectId) return;
    rejectHeard.push(activityFields(json));
  });
  const rejectSend = await deliver(alice, bob, reject, "mr-reject");

  const dupId = `${bob.origin}/activities/mrs/mr-dup`;
  const dupLog = { offers: 0, duplicates: 0 };
  alice.onOffer(async (_ctx, activity) => {
    const json = (await asActivity(activity).toJsonLd()) as Json;
    if (json.id !== dupId) return;
    if (dupLog.offers === 0) dupLog.offers += 1;
    else dupLog.duplicates += 1;
  });
  const dupOffer = new bob.vocab.Offer({
    id: new URL(dupId),
    actor: new URL(bob.actorId),
    object: new URL(forkRev),
    target: new URL(deckUri),
    to: new URL(alice.actorId),
  });
  const dupFirst = await deliver(bob, alice, dupOffer, "mr-dup");
  const dupSecond = await deliver(bob, alice, dupOffer, "mr-dup");

  const earlyOfferId = `${bob.origin}/activities/mrs/mr-early`;
  const earlyAcceptId = `${alice.origin}/activities/mrs/mr-early/accept`;
  const early: string[] = [];
  alice.onAccept(async (_ctx, activity) => {
    const json = (await asActivity(activity).toJsonLd()) as Json;
    if (json.id !== earlyAcceptId) return;
    early.push("accept");
  });
  alice.onOffer(async (_ctx, activity) => {
    const json = (await asActivity(activity).toJsonLd()) as Json;
    if (json.id !== earlyOfferId) return;
    early.push("offer");
  });
  const earlyAccept = new alice.vocab.Accept({
    id: new URL(earlyAcceptId),
    actor: new URL(alice.actorId),
    object: new URL(earlyOfferId),
    to: new URL(alice.actorId),
  });
  const earlyOffer = new bob.vocab.Offer({
    id: new URL(earlyOfferId),
    actor: new URL(bob.actorId),
    object: new URL(forkRev),
    target: new URL(deckUri),
    to: new URL(alice.actorId),
  });
  const earlyAcceptSend = await deliver(alice, alice, earlyAccept, "mr-early");
  const earlyOfferSend = await deliver(bob, alice, earlyOffer, "mr-early");

  return {
    uriSend,
    uriWire: uriSend,
    uriHeard,
    embeddedSend,
    embeddedHeard,
    fetch: {
      unsignedStatus: unsigned.status,
      signedStatus: signed.status,
      byteEqualToOriginal: unsignedBody === originalText,
      signedByteEqual: signedBody === unsignedBody,
      unsignedBytes: Buffer.byteLength(unsignedBody),
      originalBytes: Buffer.byteLength(originalText),
      schemaErrors,
      snapshotStatus: snapshot?.status ?? null,
      snapshotBytes: snapshotBytes.length,
      digestOk: href ? digestMatches(snapshotBytes, forkDigest) : false,
    },
    control: { parsed: controlParse, send: controlSend },
    acceptFlow: { offerSend, offerHeard, acceptSend, acceptHeard },
    rejectFlow: { offerSend: rejectOfferSend, offerHeard: rejectOfferHeard, rejectSend, rejectHeard },
    duplicateOffer: {
      listenerOffers: dupLog.offers,
      listenerDuplicates: dupLog.duplicates,
      first: dupFirst,
      second: dupSecond,
    },
    acceptBeforeOffer: { order: early, acceptSend: earlyAcceptSend, offerSend: earlyOfferSend },
  };
}

function revRecord(guid: string, rev: number, title: string, bytes: Buffer, digest: string) {
  return { guid, rev, title, bytes, digest, isPrivate: false, readers: new Set<string>() };
}

function forkActivityId(peer: Peer, guid: string, rev: number): string {
  return `${peer.origin}/activities/forks/${guid}/revs/${rev}`;
}

function activityFields(json: Json): Json {
  const objectValue = json.object;
  const embedded = typeof objectValue === "object" && objectValue != null ? (objectValue as Json) : null;
  return {
    type: json.type ?? null,
    object: typeof objectValue === "string" ? objectValue : embedded?.type ?? null,
    embeddedKeys: embedded ? Object.keys(embedded) : [],
    embeddedHatto: embedded ? Object.keys(embedded).filter((key) => key.startsWith("hatto:")) : [],
    embeddedUrl: embedded?.url ?? null,
    origin: json.origin ?? null,
    context: json.context ?? null,
    target: json.target ?? null,
    hatto: Object.keys(json).filter((key) => key.startsWith("hatto:")),
  };
}

function validateRev(json: Json, expected: { id: string; guid: string; rev: number; digest: string }): string[] {
  const errors: string[] = [];
  const types = Array.isArray(json.type) ? json.type.map(String) : [String(json.type ?? "")];
  if (!types.includes("hatto:Deck") || !types.includes("Object")) errors.push("type");
  if (json.id !== expected.id) errors.push("id");
  if (json["hatto:rev"] !== expected.rev) errors.push("rev");
  if (json["hatto:guid"] !== expected.guid) errors.push("guid");
  const url = typeof json.url === "object" && json.url != null ? (json.url as Json) : {};
  if (url.type !== "Link") errors.push("url.type");
  if (typeof url.href !== "string") errors.push("url.href");
  if (url.mediaType !== "application/octet-stream") errors.push("url.mediaType");
  if (url.digestMultibase !== expected.digest) errors.push("url.digestMultibase");
  return errors;
}

async function deliver(
  sender: Peer,
  receiver: Peer,
  activity: { id: URL | null },
  orderingKey: string,
): Promise<Json> {
  const before = receiver.inboxPosts.length;
  const ctx = sender.federation.createContext(new URL(sender.origin), undefined);
  let error: string | null = null;
  try {
    await ctx.sendActivity(
      { identifier: sender.name },
      new sender.vocab.Person({ id: new URL(receiver.actorId), inbox: new URL(receiver.inbox) }),
      activity as never,
      { immediate: true, orderingKey },
    );
  } catch (caught) {
    error = message(caught);
  }
  return { error, posts: receiver.inboxPosts.slice(before).map(summarizePost) };
}

async function signedPost(sender: Peer, receiver: Peer, document: unknown): Promise<Json> {
  const result = await signedRequest(sender, receiver.inbox, "POST", JSON.stringify(document));
  return { status: result.status, keyId: result.keyId, error: result.error, body: result.body };
}

async function signedGet(signer: Peer, url: string): Promise<Json & { response: Response }> {
  return signedRequest(signer, url, "GET");
}

async function signedRequest(
  signer: Peer,
  url: string,
  method: "GET" | "POST",
  body?: string,
): Promise<Json & { response: Response }> {
  const actorResponse = await fetch(signer.actorId, { headers: { accept: "application/activity+json" } });
  const actor = (await actorResponse.json()) as Json;
  const list = Array.isArray(actor.publicKey)
    ? (actor.publicKey as Json[])
    : actor.publicKey
      ? [actor.publicKey as Json]
      : [];
  const keyId = String(list.find((key) => String(key.id ?? "").endsWith("#main-key"))?.id ?? "");
  let error: string | null = null;
  let response: Response | null = null;
  let bodyText = "";
  try {
    const request = new Request(url, {
      method,
      headers: body
        ? { "content-type": "application/activity+json", accept: "application/activity+json" }
        : { accept: "application/activity+json" },
      body,
    });
    const signed = await signer.fedify.signRequest(request, signer.keys.privateKey, new URL(keyId), {
      spec: "draft-cavage-http-signatures-12",
    });
    response = await fetch(signed);
    bodyText = await response.clone().text();
  } catch (caught) {
    error = message(caught);
  }
  return {
    status: response?.status ?? 0,
    keyId,
    error,
    body: bodyText.slice(0, 400),
    response: response ?? new Response(bodyText, { status: 599 }),
  };
}

async function describeActivity(ctx: unknown, activity: unknown): Promise<Json> {
  const json = (await asActivity(activity).toJsonLd()) as Json;
  const objectValue = json.object;
  if (typeof objectValue === "string") {
    const response = await fetch(objectValue, { headers: { accept: "application/activity+json" } });
    const body = await response.text();
    let looked: Json | null = null;
    let lookError: string | null = null;
    try {
      const found = await asLookup(ctx).lookupObject(objectValue);
      looked = found ? ((await found.toJsonLd()) as Json) : null;
    } catch (error) {
      lookError = message(error);
    }
    return {
      id: json.id ?? null,
      object: objectValue,
      fetchStatus: response.status,
      fetchBody: parseJson(body),
      looked,
      lookError,
    };
  }
  return { id: json.id ?? null, embedded: objectValue ?? null };
}

function asActivity(activity: unknown): { toJsonLd: () => Promise<unknown> } {
  return activity as { toJsonLd: () => Promise<unknown> };
}

function asLookup(ctx: unknown): {
  lookupObject: (value: string) => Promise<{ toJsonLd: () => Promise<unknown> } | null>;
} {
  return ctx as {
    lookupObject: (value: string) => Promise<{ toJsonLd: () => Promise<unknown> } | null>;
  };
}

function objectField(json: Json): Json {
  const objectValue = json.object;
  return typeof objectValue === "object" && objectValue != null ? (objectValue as Json) : {};
}

function summarizeObject(json: Json): Json {
  return {
    type: json.type ?? null,
    keys: Object.keys(json),
    hatto: Object.keys(json).filter((key) => key.startsWith("hatto:") || ["rev", "event", "deck", "streakDays", "reviewCount", "measurementSource"].includes(key)),
    tag: json.tag ?? null,
    attachment: json.attachment ?? null,
    url: json.url ?? null,
  };
}

function summarizePost(post: { status: number; body: string }): Json {
  const json = parseJson(post.body);
  const objectValue = json.object;
  const embedded = typeof objectValue === "object" && objectValue != null ? (objectValue as Json) : null;
  return {
    status: post.status,
    type: json.type ?? null,
    object: typeof objectValue === "string" ? objectValue : embedded?.type ?? null,
    origin: json.origin ?? null,
    context: json.context ?? null,
    target: json.target ?? null,
    hattoKeys: embedded ? Object.keys(embedded).filter((key) => key.startsWith("hatto:") || key === "rev" || key === "guid") : [],
    activityHatto: Object.keys(json).filter((key) => key.startsWith("hatto:")),
    objectUrl: embedded?.url ?? null,
  };
}

function linkHref(json: Json): string | null {
  const url = json.url;
  if (typeof url === "string") return url;
  if (typeof url === "object" && url != null && "href" in url) return String((url as Json).href);
  return null;
}

function parseJson(text: string): Json {
  try {
    return JSON.parse(text) as Json;
  } catch {
    return { raw: text };
  }
}

function activityId(peer: Peer, guid: string, rev: number): string {
  return `${peer.origin}/activities/decks/${guid}/revs/${rev}`;
}

function revUri(peer: Peer, guid: string, rev: number): string {
  return `${peer.origin}/decks/${guid}/revs/${rev}`;
}

function message(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}
