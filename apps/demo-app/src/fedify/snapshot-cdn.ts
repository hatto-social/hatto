import http from "node:http";
import { signSnapshot, verifySnapshot } from "./digest";

export type SnapshotFile = {
  guid: string;
  rev: number;
  bytes: Buffer;
  isPrivate: boolean;
};

/**
 * Stand-in for the CDN in front of immutable snapshot objects.
 * Docker is not available here, so this is a static file server, not MinIO or S3.
 * Public objects are fetched with no query. Private objects require a short HMAC URL.
 */
export class SnapshotCdn {
  readonly files = new Map<string, SnapshotFile>();
  readonly secret = "hatto-spike-cdn";
  private server: http.Server | null = null;
  origin = "";

  put(file: SnapshotFile): void {
    this.files.set(this.key(file.guid, file.rev), file);
  }

  key(guid: string, rev: number): string {
    return `${guid}/${rev}`;
  }

  publicUrl(guid: string, rev: number): string {
    return `${this.origin}/snapshots/${guid}/${rev}`;
  }

  signedUrl(guid: string, rev: number, ttlMs: number): { url: string; exp: number } {
    const exp = Date.now() + ttlMs;
    const sig = signSnapshot(this.secret, guid, rev, exp);
    return { url: `${this.publicUrl(guid, rev)}?exp=${exp}&sig=${sig}`, exp };
  }

  async start(): Promise<void> {
    this.server = http.createServer((req, res) => {
      const url = new URL(req.url ?? "/", "http://127.0.0.1");
      const match = url.pathname.match(/^\/snapshots\/([^/]+)\/(\d+)$/);
      if (req.method !== "GET" || !match) {
        res.writeHead(404).end("not found");
        return;
      }
      const guid = decodeURIComponent(match[1]);
      const rev = Number(match[2]);
      const file = this.files.get(this.key(guid, rev));
      if (!file) {
        res.writeHead(404).end("not found");
        return;
      }
      if (file.isPrivate) {
        const exp = Number(url.searchParams.get("exp"));
        const sig = url.searchParams.get("sig") ?? "";
        if (!verifySnapshot(this.secret, guid, rev, exp, sig)) {
          res.writeHead(404).end("not found");
          return;
        }
      }
      res.writeHead(200, { "content-type": "application/octet-stream" });
      res.end(file.bytes);
    });
    await new Promise<void>((resolve) => this.server!.listen(0, "127.0.0.1", resolve));
    const address = this.server.address();
    if (address == null || typeof address === "string") throw new Error("cdn did not bind");
    this.origin = `http://127.0.0.1:${address.port}`;
  }

  async stop(): Promise<void> {
    if (!this.server) return;
    await new Promise<void>((resolve, reject) => this.server!.close((error) => (error ? reject(error) : resolve())));
    this.server = null;
  }
}
