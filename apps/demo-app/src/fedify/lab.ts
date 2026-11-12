import { getDocumentLoader } from "@fedify/vocab-runtime";
import { INLINE_CONTEXTS } from "./context-doc";
import { digestMatches, digestMultibase } from "./digest";
import { SIGNED_URL_TTL_MS, startPeer, type Peer } from "./peer";
import { OfferDedup, RevReducer } from "./reducer";
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
    if (typeof json.object !== "string" || !json.object.includes(`/decks/${guid}/`)) return;
    const rev = await revFromDocument(json.object);
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
    if (typeof json.object !== "string" || !json.object.includes("/decks/reverse-deck/")) return;
    const rev = await revFromDocument(json.object);
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
    revSource: "hatto:rev",
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
  const mergedBytes = Buffer.from("fork-source-rev-5");
  const sourceDigest = digestMultibase(sourceBytes);
  const forkDigest = digestMultibase(forkBytes);
  const mergedDigest = digestMultibase(mergedBytes);
  cdn.put({ guid: sourceGuid, rev: 4, bytes: sourceBytes, isPrivate: false });
  cdn.put({ guid: forkGuid, rev: 1, bytes: forkBytes, isPrivate: false });
  cdn.put({ guid: sourceGuid, rev: 5, bytes: mergedBytes, isPrivate: false });
  alice.revs.set(`${sourceGuid}/4`, { ...revRecord(sourceGuid, 4, "원본", sourceBytes, sourceDigest), owner: alice.actorId });
  alice.revs.set(`${sourceGuid}/5`, { ...revRecord(sourceGuid, 5, "병합", mergedBytes, mergedDigest), owner: alice.actorId });
  bob.revs.set(`${forkGuid}/1`, { ...revRecord(forkGuid, 1, "포크", forkBytes, forkDigest), owner: bob.actorId });
  const forkDocument = {
    "@context": INLINE_CONTEXTS,
    id: forkRev,
    type: ["hatto:Deck", "Object"],
    name: "포크",
    attributedTo: bob.actorId,
    origin: sourceRev,
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
  const offerTarget = deckUri;
  const offerId = offerActivityId(bob, forkGuid, 1, offerTarget, 1);
  const resubmitId = offerActivityId(bob, forkGuid, 1, offerTarget, 2);
  const rejectOfferId = offerActivityId(bob, forkGuid, 1, offerTarget, 3);
  const earlyOfferId = offerActivityId(bob, forkGuid, 1, offerTarget, 4);
  const hostMismatchId = offerActivityId(bob, forkGuid, 1, offerTarget, 5);
  const sharedOfferId = offerActivityId(bob, forkGuid, 1, `${alice.origin}/decks/shared-target`, 1);
  const closedOfferId = offerActivityId(bob, forkGuid, 1, `${alice.origin}/decks/closed-target`, 1);
  const dupId = offerActivityId(bob, forkGuid, 1, offerTarget, 9);
  const acceptId = acceptActivityId(alice, forkGuid, 1, offerTarget, 1);
  const revAcceptId = acceptActivityId(alice, forkGuid, 1, offerTarget, 2);
  const rejectId = rejectActivityId(alice, forkGuid, 1, offerTarget, 3);
  const earlyAcceptId = acceptActivityId(alice, forkGuid, 1, offerTarget, 4);
  const forgedAcceptId = acceptActivityId(bob, forkGuid, 1, offerTarget, 8);
  const mergeId = `${alice.origin}/activities/merges/${forkGuid}/revs/1/n/1`;
  const mergedRev = revUri(alice, sourceGuid, 5);
  const targets = new Map<string, string>([
    [offerId, offerTarget],
    [rejectOfferId, offerTarget],
    [earlyOfferId, offerTarget],
    [hostMismatchId, offerTarget],
    [dupId, offerTarget],
    [forgedAcceptId, offerTarget],
  ]);

  const withContext = new bob.vocab.Create({
    id: new URL(forkActivityId(bob, forkGuid, "1/context")),
    actor: new URL(bob.actorId),
    object: new URL(forkRev),
    origin: new URL(sourceRev),
    contexts: [new URL(deckUri)],
    to: new URL(alice.actorId),
  });
  const withoutContext = new bob.vocab.Create({
    id: new URL(forkActivityId(bob, forkGuid, "1/plain")),
    actor: new URL(bob.actorId),
    object: new URL(forkRev),
    origin: new URL(sourceRev),
    to: new URL(alice.actorId),
  });
  const embeddedObject = await bob.vocab.Object.fromJsonLd(forkDocument);
  const embeddedCreate = new bob.vocab.Create({
    id: new URL(forkActivityId(bob, forkGuid, "1/embedded")),
    actor: new URL(bob.actorId),
    object: embeddedObject,
    origin: new URL(sourceRev),
    contexts: [new URL(deckUri)],
    to: new URL(alice.actorId),
  });
  const creates: Json[] = [];
  alice.onCreate(async (_ctx, activity) => {
    const json = (await asActivity(activity).toJsonLd()) as Json;
    if (!String(json.id ?? "").includes(`/activities/forks/${forkGuid}/`) && !String(json.id ?? "").includes("/activities/forks/fork-order/")) return;
    creates.push(activityFields(json));
  });
  const withCompact = await publish(bob, withContext);
  const withSend = await deliver(bob, alice, withContext, forkGuid);
  const withoutCompact = await publish(bob, withoutContext);
  const withoutSend = await deliver(bob, alice, withoutContext, forkGuid);
  const embeddedCompact = await publish(bob, embeddedCreate);
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
    origin: sourceRev,
  });
  const href = linkHref(parsed);
  const snapshot = href ? await fetch(href) : null;
  const snapshotBytes = snapshot ? Buffer.from(await snapshot.arrayBuffer()) : Buffer.alloc(0);

  const controlId = forkActivityId(bob, forkGuid, "9/control");
  const controlDocument = {
    "@context": INLINE_CONTEXTS,
    id: controlId,
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
    bob.activities.set(new URL(String(compact.id ?? controlId)).pathname, compact);
    controlParse = JSON.stringify(activityFields(compact));
    controlSend = await deliver(bob, alice, control, forkGuid);
  } catch (error) {
    controlParse = message(error);
  }

  const offerText = { summary: "포크를 머지해 주세요", content: "fork-copy의 rev 1을 원본에 반영하고 싶습니다" };
  const offer = new bob.vocab.Offer({
    id: new URL(offerId),
    actor: new URL(bob.actorId),
    object: new URL(forkRev),
    target: new URL(offerTarget),
    summary: offerText.summary,
    content: offerText.content,
    to: new URL(alice.actorId),
  });
  const offers: Json[] = [];
  const offerDedup = new OfferDedup();
  alice.onOffer(async (_ctx, activity) => {
    const json = (await asActivity(activity).toJsonLd()) as Json;
    const actor = typeof json.actor === "string" ? json.actor : "";
    const objectUrl = typeof json.object === "string" ? json.object : "";
    const target = typeof json.target === "string" ? json.target : "";
    const guid = target.split("/").filter(Boolean).pop() ?? "";
    const rev = [...alice.revs.values()].find((item) => item.guid === guid);
    const readable = rev == null ? null : !rev.isPrivate || rev.readers.has(actor);
    offers.push({
      ...activityFields(json),
      hostMatch: objectUrl !== "" && actor !== "" && new URL(objectUrl).host === new URL(actor).host,
      readable,
    });
    if (json.id === dupId || json.id === resubmitId) offerDedup.apply(String(json.id));
  });
  const offerCompact = await publish(bob, offer);
  const offerSend = await deliver(bob, alice, offer, offerId);

  const mergeDocument = {
    "@context": "https://www.w3.org/ns/activitystreams",
    id: mergeId,
    type: "Article",
    name: "포크 병합",
    content: "fork-copy의 rev 1을 원본 rev 5로 병합했습니다",
    attributedTo: alice.actorId,
  };
  alice.activities.set(new URL(mergeId).pathname, mergeDocument);
  const accept = new alice.vocab.Accept({
    id: new URL(acceptId),
    actor: new URL(alice.actorId),
    object: new URL(offerId),
    result: new URL(mergeId),
    to: new URL(bob.actorId),
  });
  const revAccept = new alice.vocab.Accept({
    id: new URL(revAcceptId),
    actor: new URL(alice.actorId),
    object: new URL(offerId),
    result: new URL(mergedRev),
    to: new URL(bob.actorId),
  });
  const accepts: Json[] = [];
  bob.onAccept(async (_ctx, activity) => {
    const json = (await asActivity(activity).toJsonLd()) as Json;
    const actor = typeof json.actor === "string" ? json.actor : "";
    const offerUrl = typeof json.object === "string" ? json.object : "";
    const target = targets.get(offerUrl) ?? null;
    let targetStatus: number | null = null;
    let attributedTo: string | null = null;
    if (target) {
      const response = await fetch(target, { headers: { accept: "application/activity+json" } });
      targetStatus = response.status;
      const body = parseJson(await response.text());
      attributedTo = typeof body.attributedTo === "string" ? body.attributedTo : null;
    }
    accepts.push({
      ...activityFields(json),
      targetStatus,
      attributedTo,
      ownerMatch: attributedTo == null ? null : attributedTo === actor,
    });
  });
  const acceptCompact = await publish(alice, accept);
  const acceptSend = await deliver(alice, bob, accept, offerId);
  const revAcceptCompact = await publish(alice, revAccept);
  const revAcceptSend = await deliver(alice, bob, revAccept, offerId);

  const rejectOffer = new bob.vocab.Offer({
    id: new URL(rejectOfferId),
    actor: new URL(bob.actorId),
    object: new URL(forkRev),
    target: new URL(offerTarget),
    summary: offerText.summary,
    content: offerText.content,
    to: new URL(alice.actorId),
  });
  const rejectOfferCompact = await publish(bob, rejectOffer);
  const rejectOfferSend = await deliver(bob, alice, rejectOffer, rejectOfferId);
  const rejectReason = "범위가 원본과 다릅니다";
  const reject = new alice.vocab.Reject({
    id: new URL(rejectId),
    actor: new URL(alice.actorId),
    object: new URL(rejectOfferId),
    content: rejectReason,
    to: new URL(bob.actorId),
  });
  const rejects: Json[] = [];
  bob.onReject(async (_ctx, activity) => {
    const json = (await asActivity(activity).toJsonLd()) as Json;
    rejects.push(activityFields(json));
  });
  const rejectCompact = await publish(alice, reject);
  const rejectSend = await deliver(alice, bob, reject, rejectOfferId);

  const mismatch = new bob.vocab.Offer({
    id: new URL(hostMismatchId),
    actor: new URL(bob.actorId),
    object: new URL(sourceRev),
    target: new URL(offerTarget),
    summary: "다른 호스트",
    content: "object가 actor와 다른 호스트에 있습니다",
    to: new URL(alice.actorId),
  });
  const mismatchCompact = await publish(bob, mismatch);
  const mismatchSend = await deliver(bob, alice, mismatch, hostMismatchId);
  const forged = new bob.vocab.Accept({
    id: new URL(forgedAcceptId),
    actor: new URL(bob.actorId),
    object: new URL(offerId),
    result: new URL(mergeId),
    to: new URL(bob.actorId),
  });
  targets.set(offerId, offerTarget);
  const forgedCompact = await publish(bob, forged);
  const forgedSend = await deliver(bob, bob, forged, offerId);

  const sharedBytes = Buffer.from("shared-target");
  const closedBytes = Buffer.from("closed-target");
  cdn.put({ guid: "shared-target", rev: 1, bytes: sharedBytes, isPrivate: true });
  cdn.put({ guid: "closed-target", rev: 1, bytes: closedBytes, isPrivate: true });
  alice.revs.set("shared-target/1", {
    ...revRecord("shared-target", 1, "공유", sharedBytes, digestMultibase(sharedBytes)),
    isPrivate: true,
    readers: new Set([bob.actorId]),
    owner: alice.actorId,
  });
  alice.revs.set("closed-target/1", {
    ...revRecord("closed-target", 1, "비공개", closedBytes, digestMultibase(closedBytes)),
    isPrivate: true,
    readers: new Set<string>(),
    owner: alice.actorId,
  });
  const sharedOffer = new bob.vocab.Offer({
    id: new URL(sharedOfferId),
    actor: new URL(bob.actorId),
    object: new URL(forkRev),
    target: new URL(`${alice.origin}/decks/shared-target`),
    summary: "공유 덱",
    content: "읽을 수 있는 비공개 덱",
    to: new URL(alice.actorId),
  });
  const closedOffer = new bob.vocab.Offer({
    id: new URL(closedOfferId),
    actor: new URL(bob.actorId),
    object: new URL(forkRev),
    target: new URL(`${alice.origin}/decks/closed-target`),
    summary: "닫힌 덱",
    content: "읽을 수 없는 비공개 덱",
    to: new URL(alice.actorId),
  });
  await publish(bob, sharedOffer);
  const sharedSend = await deliver(bob, alice, sharedOffer, sharedOfferId);
  await publish(bob, closedOffer);
  const closedSend = await deliver(bob, alice, closedOffer, closedOfferId);
  const sharedGet = await signedGet(bob, revUri(alice, "shared-target", 1));
  const closedGet = await signedGet(bob, revUri(alice, "closed-target", 1));
  const closedUnsigned = await fetch(revUri(alice, "closed-target", 1), { headers: { accept: "application/activity+json" } });

  const orderGuid = "fork-order";
  const orderReducer = new RevReducer();
  const orderHatto: number[] = [];
  const orderIdNumbers: number[] = [];
  const orderDocs = [
    { rev: 2, idRev: 9 },
    { rev: 1, idRev: 8 },
  ];
  for (const item of orderDocs) {
    const bytes = Buffer.from(`fork-order-${item.rev}`);
    const digest = digestMultibase(bytes);
    cdn.put({ guid: orderGuid, rev: item.rev, bytes, isPrivate: false });
    const id = revUri(bob, orderGuid, item.rev);
    bob.revs.set(`${orderGuid}/${item.rev}`, { ...revRecord(orderGuid, item.rev, "순서", bytes, digest), owner: bob.actorId });
    bob.documents.set(`${orderGuid}/${item.rev}`, {
      "@context": INLINE_CONTEXTS,
      id,
      type: ["hatto:Deck", "Object"],
      name: "순서",
      attributedTo: bob.actorId,
      origin: sourceRev,
      "hatto:rev": item.rev,
      "hatto:guid": orderGuid,
      url: {
        type: "Link",
        href: cdn.publicUrl(orderGuid, item.rev),
        mediaType: "application/octet-stream",
        digestMultibase: digest,
      },
    });
  }
  alice.onCreate(async (_ctx, activity) => {
    const json = (await asActivity(activity).toJsonLd()) as Json;
    if (!String(json.id ?? "").includes("/activities/forks/fork-order/")) return;
    if (typeof json.object !== "string") return;
    const hattoRev = await revFromDocument(json.object);
    orderHatto.push(hattoRev);
    orderIdNumbers.push(Number(String(json.id).match(/revs\/(\d+)/)?.[1]));
    orderReducer.apply({ guid: orderGuid, rev: hattoRev, digest: "", hattoRev, hattoGuid: orderGuid });
  });
  const orderSends: Json[] = [];
  for (const item of orderDocs) {
    const activity = new bob.vocab.Create({
      id: new URL(forkActivityId(bob, orderGuid, String(item.idRev))),
      actor: new URL(bob.actorId),
      object: new URL(revUri(bob, orderGuid, item.rev)),
      origin: new URL(sourceRev),
      to: new URL(alice.actorId),
    });
    await publish(bob, activity);
    orderSends.push(await deliver(bob, alice, activity, orderGuid));
  }

  const dupOffer = new bob.vocab.Offer({
    id: new URL(dupId),
    actor: new URL(bob.actorId),
    object: new URL(forkRev),
    target: new URL(offerTarget),
    summary: offerText.summary,
    content: offerText.content,
    to: new URL(alice.actorId),
  });
  await publish(bob, dupOffer);
  const dupFirst = await deliver(bob, alice, dupOffer, dupId);
  const dupSecond = await deliver(bob, alice, dupOffer, dupId);
  const ttlBefore = alice.clock.lastIdempotenceTtl;
  const kvBefore = await idempotenceLive(alice, dupId);
  const listenerBefore = offers.filter((item) => item.id === dupId).length;
  const nowBefore = alice.clock.now;
  alice.clock.advance({ hours: 24 });
  const nowAt24 = alice.clock.now;
  const kvAt24 = await idempotenceLive(alice, dupId);
  const dupAt24 = await deliver(bob, alice, dupOffer, dupId);
  const listenerAt24 = offers.filter((item) => item.id === dupId).length;
  alice.clock.advance({ hours: 1 });
  const nowAt25 = alice.clock.now;
  const kvAt25 = await idempotenceLive(alice, dupId);
  const dupAt25 = await deliver(bob, alice, dupOffer, dupId);
  const listenerAt25 = offers.filter((item) => item.id === dupId).length;
  const dedupAt25 = { applied: offerDedup.applied, duplicates: offerDedup.duplicates };
  const resubmit = new bob.vocab.Offer({
    id: new URL(resubmitId),
    actor: new URL(bob.actorId),
    object: new URL(forkRev),
    target: new URL(offerTarget),
    summary: offerText.summary,
    content: "같은 포크의 두 번째 제출",
    to: new URL(alice.actorId),
  });
  await publish(bob, resubmit);
  const resubmitSend = await deliver(bob, alice, resubmit, resubmitId);

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
    target: new URL(offerTarget),
    summary: offerText.summary,
    content: offerText.content,
    to: new URL(alice.actorId),
  });
  await publish(alice, earlyAccept);
  const earlyAcceptSend = await deliver(alice, alice, earlyAccept, earlyOfferId);
  await publish(bob, earlyOffer);
  const earlyOfferSend = await deliver(bob, alice, earlyOffer, earlyOfferId);

  const activityIds = [
    forkActivityId(bob, forkGuid, "1/context"),
    forkActivityId(bob, forkGuid, "1/plain"),
    forkActivityId(bob, forkGuid, "1/embedded"),
    controlId,
    offerId,
    resubmitId,
    rejectOfferId,
    earlyOfferId,
    hostMismatchId,
    sharedOfferId,
    closedOfferId,
    dupId,
    acceptId,
    revAcceptId,
    rejectId,
    earlyAcceptId,
    forgedAcceptId,
    mergeId,
    mergedRev,
    forkActivityId(bob, orderGuid, "9"),
    forkActivityId(bob, orderGuid, "8"),
  ];
  const gets = [];
  for (const id of activityIds) gets.push(await readPublished(id));

  const heard = (id: string) => creates.find((item) => item.id === id) ?? null;
  const heardOffer = (id: string) => offers.find((item) => item.id === id) ?? null;
  return {
    withContext: { compact: activityFields(withCompact), send: withSend, heard: heard(forkActivityId(bob, forkGuid, "1/context")) },
    withoutContext: { compact: activityFields(withoutCompact), send: withoutSend, heard: heard(forkActivityId(bob, forkGuid, "1/plain")) },
    embedded: { compact: activityFields(embeddedCompact), send: embeddedSend, heard: heard(forkActivityId(bob, forkGuid, "1/embedded")) },
    fetch: {
      unsignedStatus: unsigned.status,
      signedStatus: signed.status,
      byteEqualToOriginal: unsignedBody === originalText,
      signedByteEqual: signedBody === unsignedBody,
      unsignedBytes: Buffer.byteLength(unsignedBody),
      originalBytes: Buffer.byteLength(originalText),
      origin: parsed.origin ?? null,
      schemaErrors,
      snapshotStatus: snapshot?.status ?? null,
      snapshotBytes: snapshotBytes.length,
      digestOk: href ? digestMatches(snapshotBytes, forkDigest) : false,
    },
    control: { parsed: controlParse, send: controlSend },
    acceptFlow: {
      offerCompact: activityFields(offerCompact),
      offerSend,
      offerHeard: heardOffer(offerId),
      acceptCompact: activityFields(acceptCompact),
      acceptSend,
      acceptHeard: accepts.find((item) => item.id === acceptId) ?? null,
      revAcceptCompact: activityFields(revAcceptCompact),
      revAcceptSend,
      revAcceptHeard: accepts.find((item) => item.id === revAcceptId) ?? null,
      mergeGet: gets.find((item) => item.id === mergeId) ?? null,
    },
    rejectFlow: {
      offerCompact: activityFields(rejectOfferCompact),
      offerSend: rejectOfferSend,
      offerHeard: heardOffer(rejectOfferId),
      rejectCompact: activityFields(rejectCompact),
      rejectSend,
      rejectHeard: rejects.find((item) => item.id === rejectId) ?? null,
    },
    checks: {
      hostMatch: heardOffer(offerId),
      hostMismatch: heardOffer(hostMismatchId),
      hostMismatchSend: mismatchSend,
      hostMismatchCompact: activityFields(mismatchCompact),
      ownerMatch: accepts.find((item) => item.id === acceptId) ?? null,
      ownerMismatch: accepts.find((item) => item.id === forgedAcceptId) ?? null,
      ownerMismatchSend: forgedSend,
      ownerMismatchCompact: activityFields(forgedCompact),
      readPublic: heardOffer(offerId),
      readShared: heardOffer(sharedOfferId),
      readClosed: heardOffer(closedOfferId),
      sharedSend,
      closedSend,
      sharedGet: sharedGet.status,
      closedGet: closedGet.status,
      closedUnsigned: closedUnsigned.status,
    },
    order: {
      hattoRev: orderHatto,
      idNumbers: orderIdNumbers,
      head: orderReducer.head.get(orderGuid) ?? null,
      olderKept: orderReducer.olderKept,
      stored: [...(orderReducer.byDeck.get(orderGuid)?.keys() ?? [])].sort((a, b) => a - b),
      sends: orderSends,
    },
    dedup: {
      ttl: ttlBefore,
      clockAtStart: "virtual",
      wallClockWaitMs: 0,
      sameId: { listener: listenerBefore, kv: kvBefore, first: dupFirst, second: dupSecond, applied: 1, now: nowBefore },
      at24h: { listener: listenerAt24, kv: kvAt24, send: dupAt24, now: nowAt24 },
      at25h: { listener: listenerAt25, kv: kvAt25, send: dupAt25, app: dedupAt25, now: nowAt25 },
      resubmit: {
        id: resubmitId,
        sameAsDup: resubmitId === dupId,
        send: resubmitSend,
        listener: offers.filter((item) => item.id === resubmitId).length,
        app: { applied: offerDedup.applied, duplicates: offerDedup.duplicates },
      },
    },
    acceptBeforeOffer: { order: early, acceptSend: earlyAcceptSend, offerSend: earlyOfferSend },
    gets,
  };
}

function offerActivityId(sender: Peer, forkGuid: string, rev: number, target: string, seq: number): string {
  const targetUrl = new URL(target);
  const deckGuid = targetUrl.pathname.split("/").filter(Boolean).pop();
  return `${sender.origin}/activities/offers/${forkGuid}/revs/${rev}/targets/${targetUrl.host}/${deckGuid}/${seq}`;
}

function acceptActivityId(sender: Peer, forkGuid: string, rev: number, target: string, seq: number): string {
  return offerActivityId(sender, forkGuid, rev, target, seq).replace("/activities/offers/", "/activities/accepts/");
}

function rejectActivityId(sender: Peer, forkGuid: string, rev: number, target: string, seq: number): string {
  return offerActivityId(sender, forkGuid, rev, target, seq).replace("/activities/offers/", "/activities/rejects/");
}

function forkActivityId(peer: Peer, guid: string, rev: string): string {
  return `${peer.origin}/activities/forks/${guid}/revs/${rev}`;
}

async function publish(
  peer: Peer,
  activity: { id: URL | null; toJsonLd: (options: { format: "compact" }) => Promise<unknown> },
): Promise<Json> {
  const json = (await activity.toJsonLd({ format: "compact" })) as Json;
  const id = String(json.id ?? activity.id?.href ?? "");
  peer.activities.set(new URL(id).pathname, json);
  return json;
}

async function readPublished(id: string): Promise<Json> {
  const response = await fetch(id, { headers: { accept: "application/activity+json" } });
  const text = await response.text();
  const body = text ? parseJson(text) : {};
  return { status: response.status, id: body.id ?? null, requested: id, type: body.type ?? null };
}

async function idempotenceLive(peer: Peer, activityId: string): Promise<boolean | null> {
  for await (const entry of peer.clock.list(["_fedify", "activityIdempotence"])) {
    if (entry.key.some((part) => String(part).includes(activityId))) return entry.value === true;
  }
  return null;
}

async function revFromDocument(url: string): Promise<number> {
  const response = await fetch(url, { headers: { accept: "application/activity+json" } });
  const body = (await response.json()) as Json;
  const rev = body["hatto:rev"];
  if (typeof rev !== "number") throw new Error(`hatto:rev missing at ${url} (${response.status})`);
  return rev;
}

function revRecord(guid: string, rev: number, title: string, bytes: Buffer, digest: string) {
  return { guid, rev, title, bytes, digest, isPrivate: false, readers: new Set<string>() };
}

function activityFields(json: Json): Json {
  const objectValue = json.object;
  const embedded = typeof objectValue === "object" && objectValue != null ? (objectValue as Json) : null;
  return {
    id: json.id ?? null,
    type: json.type ?? null,
    summary: json.summary ?? null,
    content: json.content ?? null,
    result: json.result ?? null,
    object: typeof objectValue === "string" ? objectValue : embedded?.type ?? null,
    embeddedKeys: embedded ? Object.keys(embedded) : [],
    embeddedHatto: embedded ? Object.keys(embedded).filter((key) => key.startsWith("hatto:")) : [],
    embeddedOrigin: embedded?.origin ?? null,
    embeddedUrl: embedded?.url ?? null,
    origin: json.origin ?? null,
    context: json.context ?? null,
    target: json.target ?? null,
    hatto: Object.keys(json).filter((key) => key.startsWith("hatto:")),
  };
}

function validateRev(json: Json, expected: { id: string; guid: string; rev: number; digest: string; origin: string }): string[] {
  const errors: string[] = [];
  const types = Array.isArray(json.type) ? json.type.map(String) : [String(json.type ?? "")];
  if (!types.includes("hatto:Deck") || !types.includes("Object")) errors.push("type");
  if (json.id !== expected.id) errors.push("id");
  if (json.origin !== expected.origin) errors.push("origin");
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
    summary: json.summary ?? null,
    content: json.content ?? null,
    result: json.result ?? null,
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
