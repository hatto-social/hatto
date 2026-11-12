import http from "node:http";
import type { Federation } from "@fedify/fedify";
import { INLINE_CONTEXTS, contextDocument } from "./context-doc";
import type { SnapshotCdn } from "./snapshot-cdn";

type FedifyModule = typeof import("@fedify/fedify");
type VocabModule = typeof import("@fedify/vocab");

export type DeckRev = {
  guid: string;
  rev: number;
  title: string;
  bytes: Buffer;
  digest: string;
  isPrivate: boolean;
  readers: Set<string>;
};

export type InboxPost = {
  path: string;
  status: number;
  body: string;
};

export type PeerListener = (ctx: unknown, activity: unknown) => Promise<void>;

export type Peer = {
  origin: string;
  actorId: string;
  name: string;
  inbox: string;
  federation: Federation<void>;
  fedify: FedifyModule;
  vocab: VocabModule;
  keys: CryptoKeyPair;
  inboxPosts: InboxPost[];
  /** Signer href observed by the object dispatcher, if the GET was signed. */
  lastSigner: string | null;
  revs: Map<string, DeckRev>;
  notes: Map<string, unknown>;
  /** Exact JSON object the rev dispatcher parses, when the caller wants a stable body. */
  documents: Map<string, unknown>;
  onUpdate: (listener: PeerListener) => void;
  onCreate: (listener: PeerListener) => void;
  onOffer: (listener: PeerListener) => void;
  onAccept: (listener: PeerListener) => void;
  onReject: (listener: PeerListener) => void;
  stop: () => Promise<void>;
};

export async function startPeer(name: string, cdn: SnapshotCdn): Promise<Peer> {
  const fedify = await import("@fedify/fedify");
  const vocab = await import("@fedify/vocab");
  const keys = await fedify.generateCryptoKeyPair("RSASSA-PKCS1-v1_5");
  const ed = await fedify.generateCryptoKeyPair("Ed25519");
  const revs = new Map<string, DeckRev>();
  const notes = new Map<string, unknown>();
  const documents = new Map<string, unknown>();
  const inboxPosts: InboxPost[] = [];
  const state: { lastSigner: string | null; federation: Peer["federation"] | null } = {
    lastSigner: null,
    federation: null,
  };

  const server = http.createServer(async (req, res) => {
    try {
      const origin = state.federation == null ? "http://127.0.0.1" : peerOrigin(server);
      const url = new URL(req.url ?? "/", origin);
      if (url.pathname === "/contexts/hatto.jsonld") {
        const body = JSON.stringify(contextDocument());
        res.writeHead(200, { "content-type": "application/ld+json" });
        res.end(body);
        return;
      }
      const chunks: Buffer[] = [];
      for await (const chunk of req) chunks.push(Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk));
      const raw = Buffer.concat(chunks);
      const headers = new Headers();
      for (const [key, value] of Object.entries(req.headers)) {
        if (typeof value === "string") headers.set(key, value);
        else if (Array.isArray(value)) for (const item of value) headers.append(key, item);
      }
      const request = new Request(new URL(req.url ?? "/", origin), {
        method: req.method,
        headers,
        body: req.method === "GET" || req.method === "HEAD" ? undefined : raw,
      });
      const response = await state.federation!.fetch(request, { contextData: undefined });
      const text = await response.text();
      if (url.pathname.endsWith("/inbox") && req.method === "POST") {
        inboxPosts.push({ path: url.pathname, status: response.status, body: raw.toString("utf8") });
      }
      const out = new Headers(response.headers);
      res.writeHead(response.status, Object.fromEntries(out));
      res.end(text);
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      res.writeHead(500, { "content-type": "text/plain" }).end(message);
    }
  });
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  const origin = peerOrigin(server);
  const federation = fedify.createFederation<void>({
    kv: new fedify.MemoryKvStore(),
    origin,
    allowPrivateAddress: true,
  });
  state.federation = federation;
  federation
    .setActorDispatcher("/users/{identifier}", async (ctx, identifier) => {
      if (identifier !== name) return null;
      const pairs = await ctx.getActorKeyPairs(identifier);
      return new vocab.Person({
        id: ctx.getActorUri(identifier),
        preferredUsername: identifier,
        name,
        inbox: ctx.getInboxUri(identifier),
        publicKeys: pairs.map((pair) => pair.cryptographicKey),
      });
    })
    .setKeyPairsDispatcher(async () => [keys, ed]);
  const updateListeners: PeerListener[] = [];
  const createListeners: PeerListener[] = [];
  const offerListeners: PeerListener[] = [];
  const acceptListeners: PeerListener[] = [];
  const rejectListeners: PeerListener[] = [];
  federation.setInboxListeners("/users/{identifier}/inbox")
    .on(vocab.Update, async (ctx, activity) => {
      for (const listener of updateListeners) await listener(ctx, activity);
    })
    .on(vocab.Create, async (ctx, activity) => {
      for (const listener of createListeners) await listener(ctx, activity);
    })
    .on(vocab.Offer, async (ctx, activity) => {
      for (const listener of offerListeners) await listener(ctx, activity);
    })
    .on(vocab.Accept, async (ctx, activity) => {
      for (const listener of acceptListeners) await listener(ctx, activity);
    })
    .on(vocab.Reject, async (ctx, activity) => {
      for (const listener of rejectListeners) await listener(ctx, activity);
    });
  federation.setObjectDispatcher(vocab.Object, "/decks/{+key}", async (ctx, values) => {
      const parsed = parseDeckKey(String(values.key));
      if (!parsed) return null;
      const rev = revs.get(`${parsed.guid}/${parsed.rev}`);
      if (!rev) return null;
      let signerHref: string | null = null;
      try {
        const signer = await ctx.getSignedKeyOwner();
        signerHref = signer?.id?.href ?? null;
      } catch {
        signerHref = null;
      }
      state.lastSigner = signerHref;
      if (rev.isPrivate) {
        if (state.lastSigner == null || !rev.readers.has(state.lastSigner)) return null;
      }
      const href = rev.isPrivate
        ? cdn.signedUrl(rev.guid, rev.rev, SIGNED_URL_TTL_MS).url
        : cdn.publicUrl(rev.guid, rev.rev);
      const document = documents.get(`${parsed.guid}/${parsed.rev}`) ?? {
        "@context": INLINE_CONTEXTS,
        id: `${origin}/decks/${rev.guid}/revs/${rev.rev}`,
        type: ["hatto:Deck", "Object"],
        name: rev.title,
        "hatto:rev": rev.rev,
        "hatto:guid": rev.guid,
        url: {
          type: "Link",
          href,
          mediaType: "application/octet-stream",
          digestMultibase: rev.digest,
        },
      };
      return vocab.Object.fromJsonLd(document);
    });
  federation.setObjectDispatcher(vocab.Note, "/notes/{id}", async (_ctx, values) => {
    const document = notes.get(String(values.id));
    if (!document) return null;
    return vocab.Note.fromJsonLd(document);
  });

  const actorId = `${origin}/users/${name}`;
  return {
    origin,
    actorId,
    name,
    inbox: `${origin}/users/${name}/inbox`,
    federation,
    fedify,
    vocab,
    keys,
    inboxPosts,
    get lastSigner() {
      return state.lastSigner;
    },
    revs,
    notes,
    documents,
    onUpdate(listener) {
      updateListeners.push(listener);
    },
    onCreate(listener) {
      createListeners.push(listener);
    },
    onOffer(listener) {
      offerListeners.push(listener);
    },
    onAccept(listener) {
      acceptListeners.push(listener);
    },
    onReject(listener) {
      rejectListeners.push(listener);
    },
    async stop() {
      await new Promise<void>((resolve, reject) => server.close((error) => (error ? reject(error) : resolve())));
    },
  };
}

function peerOrigin(server: http.Server): string {
  const address = server.address();
  if (address == null || typeof address === "string") throw new Error("peer did not bind");
  return `http://127.0.0.1:${address.port}`;
}

export function parseDeckKey(key: string): { guid: string; rev: number } | null {
  const match = key.match(/^([^/]+)\/revs\/(\d+)$/);
  if (!match) return null;
  return { guid: match[1], rev: Number(match[2]) };
}

export const SIGNED_URL_TTL_MS = 1500;
