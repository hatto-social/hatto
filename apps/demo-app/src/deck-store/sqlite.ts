import { createHash } from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import Database from 'better-sqlite3';

export const SCHEMA_VERSION = 2;

export type CardRow = { id: string; ord: number; rev: number };
export type FieldRow = { card_id: string; name: string; value: string; rev: number };
export type HistRow = {
  id: number;
  card_id: string;
  reviewed_at: number;
  rating: number;
  rev: number;
};
export type Manifest = {
  version: number;
  cardCount: number;
  histCount: number;
  hash: string;
  schemaVersion: number;
};

export type Mutation =
  | { type: 'add-cards'; cards: Array<{ id: string; fields: Record<string, string> }> }
  | { type: 'append-hist'; cardId: string; rating: number; reviewedAt: number }
  | { type: 'seed-cards'; count: number; idPrefix: string };

export type Seal = 'delete' | 'wal' | 'wal-uncheckpointed';

export type ReadBody = {
  manifest: Manifest;
  cards: CardRow[];
  fields: FieldRow[];
  hist: HistRow[];
  mixed: boolean;
  bytes: number;
};

const SCHEMA_SQL = `
CREATE TABLE IF NOT EXISTS cards (
  id TEXT PRIMARY KEY,
  ord INTEGER NOT NULL,
  rev INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS fields (
  card_id TEXT NOT NULL,
  name TEXT NOT NULL,
  value TEXT NOT NULL,
  rev INTEGER NOT NULL,
  PRIMARY KEY (card_id, name)
);
CREATE TABLE IF NOT EXISTS hist (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  card_id TEXT NOT NULL,
  reviewed_at INTEGER NOT NULL,
  rating INTEGER NOT NULL,
  rev INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS manifest (
  version INTEGER NOT NULL,
  card_count INTEGER NOT NULL,
  hist_count INTEGER NOT NULL,
  body_hash TEXT NOT NULL,
  schema_version INTEGER NOT NULL
);
`;

export type OpenMode = 'rw' | 'ro' | 'ro-immutable';

export function openDatabase(file: string, mode: OpenMode): Database.Database {
  if (mode === 'rw') {
    const db = new Database(file);
    db.pragma('foreign_keys = ON');
    db.pragma('busy_timeout = 2000');
    return db;
  }
  if (mode === 'ro' || mode === 'ro-immutable') {
    // better-sqlite3 12 does not pass SQLITE_OPEN_URI, so immutable=1 cannot be
    // requested here. ro-immutable is a readonly handle with query_only set.
    const db = new Database(file, { readonly: true, fileMustExist: true });
    if (mode === 'ro-immutable') db.pragma('query_only = ON');
    return db;
  }
  throw new Error(`unknown open mode ${mode}`);
}

export function fsyncPath(file: string): void {
  const fd = fs.openSync(file, 'r');
  try {
    fs.fsyncSync(fd);
  } finally {
    fs.closeSync(fd);
  }
}

export function corruptMagic(file: string): void {
  const fd = fs.openSync(file, 'r+');
  try {
    fs.writeSync(fd, Buffer.from('CORRUPT-FILE!!!!'), 0, 16, 0);
    fs.fsyncSync(fd);
  } finally {
    fs.closeSync(fd);
  }
}

export function userVersion(db: Database.Database): number {
  return Number(db.pragma('user_version', { simple: true }));
}

export function migrate(db: Database.Database): { from: number; to: number } {
  const from = userVersion(db);
  if (from === SCHEMA_VERSION) return { from, to: from };
  if (from !== 1) {
    throw new Error(`unsupported user_version ${from}`);
  }
  const tx = db.transaction(() => {
    const cardCols = (db.prepare(`PRAGMA table_info(cards)`).all() as Array<{ name: string }>).map(
      (c) => c.name,
    );
    if (!cardCols.includes('rev')) {
      db.exec(`ALTER TABLE cards ADD COLUMN rev INTEGER NOT NULL DEFAULT 0`);
    }
    const fieldCols = (db.prepare(`PRAGMA table_info(fields)`).all() as Array<{ name: string }>).map(
      (c) => c.name,
    );
    if (!fieldCols.includes('rev')) {
      db.exec(`ALTER TABLE fields ADD COLUMN rev INTEGER NOT NULL DEFAULT 0`);
    }
    db.exec(`
      CREATE TABLE IF NOT EXISTS hist (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        card_id TEXT NOT NULL,
        reviewed_at INTEGER NOT NULL,
        rating INTEGER NOT NULL,
        rev INTEGER NOT NULL
      );
      CREATE TABLE IF NOT EXISTS manifest (
        version INTEGER NOT NULL,
        card_count INTEGER NOT NULL,
        hist_count INTEGER NOT NULL,
        body_hash TEXT NOT NULL,
        schema_version INTEGER NOT NULL
      );
    `);
    db.pragma(`user_version = ${SCHEMA_VERSION}`);
  });
  tx();
  return { from, to: SCHEMA_VERSION };
}

export function createLegacyV1(file: string, count: number): void {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  const db = new Database(file);
  try {
    db.exec(`
      CREATE TABLE cards (
        id TEXT PRIMARY KEY,
        ord INTEGER NOT NULL
      );
      CREATE TABLE fields (
        card_id TEXT NOT NULL,
        name TEXT NOT NULL,
        value TEXT NOT NULL,
        PRIMARY KEY (card_id, name)
      );
    `);
    const card = db.prepare(`INSERT INTO cards(id, ord) VALUES (?, ?)`);
    const field = db.prepare(`INSERT INTO fields(card_id, name, value) VALUES (?, ?, ?)`);
    const tx = db.transaction(() => {
      for (let i = 0; i < count; i++) {
        const id = `legacy-${i}`;
        card.run(id, i);
        field.run(id, 'front', `f${i}`);
        field.run(id, 'back', `b${i}`);
      }
    });
    tx();
    db.pragma('user_version = 1');
  } finally {
    db.close();
  }
}

function readRows(db: Database.Database): {
  cards: CardRow[];
  fields: FieldRow[];
  hist: HistRow[];
} {
  const cards = db.prepare(`SELECT id, ord, rev FROM cards ORDER BY ord, id`).all() as CardRow[];
  const fields = db
    .prepare(`SELECT card_id, name, value, rev FROM fields ORDER BY card_id, name`)
    .all() as FieldRow[];
  const hist = db
    .prepare(`SELECT id, card_id, reviewed_at, rating, rev FROM hist ORDER BY id`)
    .all() as HistRow[];
  return { cards, fields, hist };
}

export function bodyHash(cards: CardRow[], fields: FieldRow[], hist: HistRow[]): string {
  const payload = JSON.stringify({
    cards: cards.map((c) => [c.id, c.ord, c.rev]),
    fields: fields.map((f) => [f.card_id, f.name, f.value, f.rev]),
    hist: hist.map((h) => [h.id, h.card_id, h.reviewed_at, h.rating, h.rev]),
  });
  return createHash('sha256').update(payload).digest('hex');
}

function readManifest(db: Database.Database): Manifest | null {
  const row = db
    .prepare(
      `SELECT version, card_count, hist_count, body_hash, schema_version FROM manifest LIMIT 1`,
    )
    .get() as
    | {
        version: number;
        card_count: number;
        hist_count: number;
        body_hash: string;
        schema_version: number;
      }
    | undefined;
  if (!row) return null;
  return {
    version: row.version,
    cardCount: row.card_count,
    histCount: row.hist_count,
    hash: row.body_hash,
    schemaVersion: row.schema_version,
  };
}

function writeManifest(db: Database.Database, manifest: Manifest): void {
  db.exec(`DELETE FROM manifest`);
  db.prepare(
    `INSERT INTO manifest(version, card_count, hist_count, body_hash, schema_version)
     VALUES (?, ?, ?, ?, ?)`,
  ).run(manifest.version, manifest.cardCount, manifest.histCount, manifest.hash, manifest.schemaVersion);
}

function applyMutation(db: Database.Database, version: number, mutation: Mutation): void {
  if (mutation.type === 'seed-cards') {
    const card = db.prepare(`INSERT INTO cards(id, ord, rev) VALUES (?, ?, ?)`);
    const field = db.prepare(
      `INSERT INTO fields(card_id, name, value, rev) VALUES (?, ?, ?, ?)`,
    );
    const base = (db.prepare(`SELECT COALESCE(MAX(ord), -1) AS m FROM cards`).get() as { m: number }).m;
    for (let i = 0; i < mutation.count; i++) {
      const id = `${mutation.idPrefix}${i}`;
      const ord = base + 1 + i;
      card.run(id, ord, version);
      field.run(id, 'front', `f${i}`, version);
      field.run(id, 'back', `b${i}`, version);
    }
    return;
  }
  if (mutation.type === 'add-cards') {
    const card = db.prepare(`INSERT INTO cards(id, ord, rev) VALUES (?, ?, ?)`);
    const field = db.prepare(
      `INSERT INTO fields(card_id, name, value, rev) VALUES (?, ?, ?, ?)`,
    );
    let ord = (db.prepare(`SELECT COALESCE(MAX(ord), -1) AS m FROM cards`).get() as { m: number }).m;
    for (const incoming of mutation.cards) {
      ord += 1;
      card.run(incoming.id, ord, version);
      for (const [name, value] of Object.entries(incoming.fields).sort(([a], [b]) =>
        a < b ? -1 : a > b ? 1 : 0,
      )) {
        field.run(incoming.id, name, value, version);
      }
    }
    return;
  }
  const found = db.prepare(`SELECT id FROM cards WHERE id = ?`).get(mutation.cardId) as
    | { id: string }
    | undefined;
  if (!found) throw new Error(`missing card ${mutation.cardId}`);
  db.prepare(
    `INSERT INTO hist(card_id, reviewed_at, rating, rev) VALUES (?, ?, ?, ?)`,
  ).run(mutation.cardId, mutation.reviewedAt, mutation.rating, version);
}

export type BuiltFile = {
  hash: string;
  cardCount: number;
  histCount: number;
  bytes: number;
};

function finishManifest(db: Database.Database, version: number): Omit<BuiltFile, 'bytes'> {
  const rows = readRows(db);
  const hash = bodyHash(rows.cards, rows.fields, rows.hist);
  const manifest: Manifest = {
    version,
    cardCount: rows.cards.length,
    histCount: rows.hist.length,
    hash,
    schemaVersion: SCHEMA_VERSION,
  };
  writeManifest(db, manifest);
  return { hash, cardCount: rows.cards.length, histCount: rows.hist.length };
}

/**
 * Build a private temp file. Callers fsync and rename it into a published path.
 * Journal mode DELETE keeps the result a single file (no -wal sibling).
 */
export function buildTempFile(opts: {
  tmpPath: string;
  previousPath: string | null;
  version: number;
  mutation: Mutation;
  seal: Seal;
}): Omit<BuiltFile, 'bytes'> {
  fs.mkdirSync(path.dirname(opts.tmpPath), { recursive: true });
  if (opts.previousPath) {
    const wal = `${opts.previousPath}-wal`;
    if (fs.existsSync(wal) && fs.statSync(wal).size > 0) {
      throw new Error(`refusing to copy ${opts.previousPath} while a non-empty WAL exists`);
    }
    fs.copyFileSync(opts.previousPath, opts.tmpPath);
  }
  const db = new Database(opts.tmpPath);
  try {
    db.pragma('foreign_keys = ON');
    db.pragma('synchronous = FULL');
    if (!opts.previousPath) {
      db.exec(SCHEMA_SQL);
      db.pragma(`user_version = ${SCHEMA_VERSION}`);
    } else if (userVersion(db) < SCHEMA_VERSION) {
      migrate(db);
    }
    if (opts.seal === 'wal' || opts.seal === 'wal-uncheckpointed') {
      db.pragma('journal_mode = WAL');
    }
    const tx = db.transaction(() => {
      applyMutation(db, opts.version, opts.mutation);
      finishManifest(db, opts.version);
    });
    tx();
    if (opts.seal === 'delete') {
      const mode = String(db.pragma('journal_mode', { simple: true }));
      if (mode === 'wal') {
        db.pragma('wal_checkpoint(TRUNCATE)');
        db.pragma('journal_mode = DELETE');
      }
    } else if (opts.seal === 'wal') {
      db.pragma('wal_checkpoint(TRUNCATE)');
    }
    const manifest = readManifest(db);
    if (!manifest) throw new Error('manifest missing after build');
    return {
      hash: manifest.hash,
      cardCount: manifest.cardCount,
      histCount: manifest.histCount,
    };
  } finally {
    db.close();
  }
}

export function mutateInPlace(opts: {
  file: string;
  version: number;
  mutation: Mutation;
  autocheckpoint?: number;
}): BuiltFile {
  fs.mkdirSync(path.dirname(opts.file), { recursive: true });
  const existed = fs.existsSync(opts.file);
  const db = new Database(opts.file);
  try {
    db.pragma('foreign_keys = ON');
    db.pragma('journal_mode = WAL');
    db.pragma('synchronous = FULL');
    db.pragma('busy_timeout = 2000');
    if (opts.autocheckpoint !== undefined) {
      db.pragma(`wal_autocheckpoint = ${opts.autocheckpoint}`);
    }
    if (!existed || userVersion(db) === 0) {
      db.exec(SCHEMA_SQL);
      db.pragma(`user_version = ${SCHEMA_VERSION}`);
    } else if (userVersion(db) < SCHEMA_VERSION) {
      migrate(db);
    }
    const tx = db.transaction(() => {
      applyMutation(db, opts.version, opts.mutation);
      finishManifest(db, opts.version);
    });
    tx();
    const manifest = readManifest(db);
    if (!manifest) throw new Error('manifest missing after in-place write');
    const bytes = fs.statSync(opts.file).size;
    return {
      hash: manifest.hash,
      cardCount: manifest.cardCount,
      histCount: manifest.histCount,
      bytes,
    };
  } finally {
    db.close();
  }
}

export function fileBytes(file: string): number {
  return fs.statSync(file).size;
}

export type SnapshotHooks = {
  afterManifest?: () => void;
};

export function readSnapshot(
  db: Database.Database,
  mode: 'tx' | 'loose',
  hooks?: SnapshotHooks,
): Omit<ReadBody, 'bytes'> {
  const run = (): Omit<ReadBody, 'bytes'> => {
    const m1 = readManifest(db);
    hooks?.afterManifest?.();
    let cards: CardRow[] = [];
    let fields: FieldRow[] = [];
    let hist: HistRow[] = [];
    if (userVersion(db) >= 2) {
      const rows = readRows(db);
      cards = rows.cards;
      fields = rows.fields;
      hist = rows.hist;
    }
    const m2 = readManifest(db);
    if (!m1 || !m2) {
      return {
        manifest: m1 ?? {
          version: -1,
          cardCount: 0,
          histCount: 0,
          hash: '',
          schemaVersion: userVersion(db),
        },
        cards,
        fields,
        hist,
        mixed: true,
      };
    }
    const mixed =
      m1.version !== m2.version ||
      m1.hash !== m2.hash ||
      cards.some((c) => c.rev > m1.version) ||
      fields.some((f) => f.rev > m1.version) ||
      hist.some((h) => h.rev > m1.version);
    return { manifest: m1, cards, fields, hist, mixed };
  };
  if (mode === 'loose') return run();
  db.exec('BEGIN');
  try {
    return run();
  } finally {
    db.exec('ROLLBACK');
  }
}

export function readFileSnapshot(
  file: string,
  mode: 'tx' | 'loose',
  openMode: OpenMode,
  hooks?: SnapshotHooks,
): ReadBody {
  const db = openDatabase(file, openMode);
  try {
    const body = readSnapshot(db, mode, hooks);
    return { ...body, bytes: fs.statSync(file).size };
  } finally {
    db.close();
  }
}

export function integrityOf(file: string): { ok: boolean; detail: string } {
  let db: Database.Database;
  try {
    db = openDatabase(file, 'ro');
  } catch (error) {
    return { ok: false, detail: error instanceof Error ? error.message : String(error) };
  }
  try {
    const rows = db.pragma('integrity_check') as Array<{ integrity_check: string }>;
    const detail = rows.map((r) => r.integrity_check).join(',');
    return { ok: detail === 'ok', detail };
  } catch (error) {
    return { ok: false, detail: error instanceof Error ? error.message : String(error) };
  } finally {
    try {
      db.close();
    } catch {
      // A torn file can fail again on close. The integrity result still stands.
    }
  }
}

export function journalModeOf(file: string): string {
  const db = openDatabase(file, 'ro');
  try {
    return String(db.pragma('journal_mode', { simple: true }));
  } finally {
    db.close();
  }
}

export function sidecarBytes(file: string): { wal: number; shm: number } {
  const wal = `${file}-wal`;
  const shm = `${file}-shm`;
  return {
    wal: fs.existsSync(wal) ? fs.statSync(wal).size : 0,
    shm: fs.existsSync(shm) ? fs.statSync(shm).size : 0,
  };
}

export function walCheckpoint(
  file: string,
  mode: 'PASSIVE' | 'FULL' | 'RESTART' | 'TRUNCATE',
): { busy: number; log: number; checkpointed: number; ms: number } {
  const db = new Database(file);
  try {
    db.pragma('busy_timeout = 300');
    const started = performance.now();
    const rows = db.pragma(`wal_checkpoint(${mode})`) as Array<{
      busy: number;
      log: number;
      checkpointed: number;
    }>;
    const ms = performance.now() - started;
    const row = rows[0] ?? { busy: -1, log: -1, checkpointed: -1 };
    return { ...row, ms };
  } finally {
    db.close();
  }
}

export function listSqliteFiles(root: string): string[] {
  const out: string[] = [];
  if (!fs.existsSync(root)) return out;
  const stack = [root];
  while (stack.length) {
    const dir = stack.pop();
    if (!dir) break;
    for (const ent of fs.readdirSync(dir, { withFileTypes: true })) {
      const full = path.join(dir, ent.name);
      if (ent.isDirectory()) stack.push(full);
      else if (ent.isFile() && ent.name.endsWith('.sqlite')) out.push(full);
    }
  }
  return out;
}

export function countSqliteFds(): number {
  const dir = '/proc/self/fd';
  let n = 0;
  for (const fd of fs.readdirSync(dir)) {
    try {
      const target = fs.readlinkSync(path.join(dir, fd));
      if (target.includes('.sqlite')) n += 1;
    } catch {
      // fd closed between readdir and readlink
    }
  }
  return n;
}

export function sqliteVersion(): string {
  const db = new Database(':memory:');
  try {
    const row = db.prepare(`SELECT sqlite_version() AS v`).get() as { v: string };
    return row.v;
  } finally {
    db.close();
  }
}

export function holdReadTransaction(file: string): Database.Database {
  const db = openDatabase(file, 'ro');
  db.exec('BEGIN');
  db.prepare(`SELECT count(*) AS n FROM cards`).get();
  return db;
}

export function readManifestFile(file: string): Manifest | null {
  let db: Database.Database;
  try {
    db = openDatabase(file, 'ro');
  } catch {
    return null;
  }
  try {
    return readManifest(db);
  } catch {
    return null;
  } finally {
    try {
      db.close();
    } catch {
      // torn file
    }
  }
}
