// A workspace's apps on this station (station apps): `.mbui` widgets and `.wasm` mini-programs its agents make and
// change in place (tools/apps.ts), shown in any chat and on every device (api/routes/apps.ts), each with a store of
// JSON documents of its own that every device and chat showing it shares.
//
// An app is its versions: every save is a new version, kept whole and never changed (`app_versions`, its source in
// the row), and the app points at one of them (`current`). A save names the version it was made on (`base`): one made
// on a version that is no longer the newest is refused, so two agents do not silently overwrite each other. A version
// made current again (a rollback, `publish`) is a step of its history (`app_history`), the versions as they were.
//
// Documents are the app's, shared by all its versions. A version may say which shape of data it reads (`schema`, an
// int, its .mbui's top-level `schema` or the save's): the app keeps the highest made current (`data_schema`), each
// document the one it was written under, and a version reading an older shape is not made current unless forced (it
// would misread newer data).
//
// Kept in stillfail.db (its tables made here as they are first needed, CREATE … IF NOT EXISTS: a migration forward
// only), by workspace: one workspace's apps are not another's. Every read is by its key and bounded; the writes are
// one transaction each, `BEGIN IMMEDIATE`. What changes is said to `told` (the station's event stream: `app`,
// `app-doc`), never polled.
import { createHash } from "node:crypto";
import type { DatabaseSync } from "node:sqlite";

export const APP_TABLES = `
CREATE TABLE IF NOT EXISTS apps (
  ws TEXT NOT NULL,
  id TEXT NOT NULL,
  title TEXT NOT NULL,
  kind TEXT NOT NULL,
  rev INTEGER NOT NULL,
  current INTEGER NOT NULL,
  data_schema INTEGER NOT NULL DEFAULT 0,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  PRIMARY KEY (ws, id)
);
CREATE TABLE IF NOT EXISTS app_versions (
  ws TEXT NOT NULL,
  app TEXT NOT NULL,
  rev INTEGER NOT NULL,
  kind TEXT NOT NULL,
  title TEXT NOT NULL,
  source BLOB NOT NULL,
  size INTEGER NOT NULL,
  sha256 TEXT NOT NULL,
  schema INTEGER NOT NULL DEFAULT 0,
  note TEXT NOT NULL,
  by TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  PRIMARY KEY (ws, app, rev)
);
CREATE TABLE IF NOT EXISTS app_history (
  ws TEXT NOT NULL,
  app TEXT NOT NULL,
  n INTEGER NOT NULL,
  at INTEGER NOT NULL,
  current INTEGER NOT NULL,
  by TEXT NOT NULL,
  note TEXT NOT NULL,
  PRIMARY KEY (ws, app, n)
);
CREATE TABLE IF NOT EXISTS app_docs (
  ws TEXT NOT NULL,
  app TEXT NOT NULL,
  collection TEXT NOT NULL,
  id TEXT NOT NULL,
  json TEXT NOT NULL,
  rev INTEGER NOT NULL,
  schema INTEGER NOT NULL DEFAULT 0,
  by TEXT NOT NULL,
  updated_at INTEGER NOT NULL,
  PRIMARY KEY (ws, app, collection, id)
);
`;

export const APP_ID = /^[a-z0-9][a-z0-9-]{0,39}$/;
/// A collection's name and a document's id.
export const DOC_KEY = /^[A-Za-z0-9_.-]{1,64}$/;
/// The most a version's source is, in bytes.
export const SOURCE_MOST = 4 * 1024 * 1024;
/// The most a document is, as JSON; the most a collection holds; the most collections an app has.
export const DOC_MOST = 64 * 1024;
export const DOCS_MOST = 1000;
export const COLLECTIONS_MOST = 100;
/// The most apps a workspace has here; the most versions and history steps a read gives (the newest).
export const APPS_MOST = 500;
export const VERSIONS_SHOWN = 200;
export const NOTE_MOST = 500;
export const TITLE_MOST = 80;

export type AppKind = "mbui" | "wasm";
export type AppMeta = { id: string; title: string; kind: AppKind; rev: number; current: number; schema: number; updated_at: number };
export type AppVersion = { rev: number; created_at: number; by: string; note: string; size: number; sha256: string; schema: number };
export type AppStep = { at: number; current: number; by: string; note: string };
export type AppDoc = { id: string; data: unknown; rev: number; schema: number; updated_at: number };

/// What `told` hears: an app's source or current version changed, or one of its documents.
export type AppEvent =
  | { kind: "app"; ws: string; id: string; rev: number; current: number }
  | { kind: "app-doc"; ws: string; app: string; collection: string; id: string; rev: number; deleted: boolean };

/// A refusal: its status as an HTTP answer gives it, its message what to do next.
export class AppRefused extends Error {
  readonly status: number;
  constructor(status: number, message: string) {
    super(message);
    this.status = status;
  }
}

/// The schema a .mbui's JSON says it reads (its top-level `schema`, a whole number ≥ 0), or null.
export function declaredSchema(source: Uint8Array, kind: AppKind): number | null {
  if (kind !== "mbui") return null;
  try {
    const s = (JSON.parse(Buffer.from(source).toString("utf8")) as { schema?: unknown } | null)?.schema;
    return typeof s === "number" && Number.isSafeInteger(s) && s >= 0 ? s : null;
  } catch {
    return null;
  }
}

/// A version's source as it may be kept: a .mbui is a JSON object (bound to no other app than `id`), a .wasm a module.
export function checkSource(id: string, kind: AppKind, source: Uint8Array): void {
  if (source.length === 0) throw new AppRefused(400, "the file is empty: write the app's source to it first");
  if (source.length > SOURCE_MOST) throw new AppRefused(413, `the file is over ${SOURCE_MOST} bytes: make the app smaller (move data into its documents)`);
  if (kind === "wasm") {
    if (!(source[0] === 0x00 && source[1] === 0x61 && source[2] === 0x73 && source[3] === 0x6d)) throw new AppRefused(400, "the .wasm file is not a WebAssembly module (no \\0asm header): build it again");
    return;
  }
  let parsed: unknown;
  try {
    parsed = JSON.parse(Buffer.from(source).toString("utf8"));
  } catch (e) {
    throw new AppRefused(400, `the .mbui file is not JSON (${(e as Error).message}): fix it and save again`);
  }
  if (parsed === null || typeof parsed !== "object" || Array.isArray(parsed)) throw new AppRefused(400, "the .mbui file must be a JSON object: fix it and save again");
  const bound = (parsed as { app?: unknown }).app;
  if (bound !== undefined && bound !== id) throw new AppRefused(400, `the .mbui file says "app": ${JSON.stringify(bound)}; set it to "${id}" (or leave it out) and save again`);
}

export class Apps {
  readonly #db: DatabaseSync;
  readonly #now: () => number;
  readonly #told: (event: AppEvent) => void;

  constructor(db: DatabaseSync, now: () => number, told: (event: AppEvent) => void = () => {}) {
    this.#db = db;
    this.#now = now;
    this.#told = told;
    db.exec(APP_TABLES);
  }

  #tx<T>(work: () => T): T {
    this.#db.exec("BEGIN IMMEDIATE");
    try {
      const result = work();
      this.#db.exec("COMMIT");
      return result;
    } catch (error) {
      this.#db.exec("ROLLBACK");
      throw error;
    }
  }

  #row(ws: string, id: string): { title: string; kind: AppKind; rev: number; current: number; data_schema: number; updated_at: number } | undefined {
    return this.#db.prepare("SELECT title, kind, rev, current, data_schema, updated_at FROM apps WHERE ws = ? AND id = ?").get(ws, id) as any;
  }

  #known(ws: string, id: string) {
    if (!APP_ID.test(id)) throw new AppRefused(400, `"${id}" is not an app id: lower-case letters, digits and -, at most 40, starting with a letter or digit`);
    const row = this.#row(ws, id);
    if (row === undefined) throw new AppRefused(404, `no app "${id}" in this workspace on this station: app_list (or GET /apps) lists those there`);
    return row;
  }

  #versionSchema(ws: string, id: string, rev: number): number | undefined {
    return (this.#db.prepare("SELECT schema FROM app_versions WHERE ws = ? AND app = ? AND rev = ?").get(ws, id, rev) as { schema: number } | undefined)?.schema;
  }

  #meta(id: string, r: { title: string; kind: AppKind; rev: number; current: number; data_schema: number; updated_at: number }): AppMeta {
    return { id, title: r.title, kind: r.kind, rev: r.rev, current: r.current, schema: r.data_schema, updated_at: r.updated_at };
  }

  #step(ws: string, id: string, current: number, by: string, note: string, at: number) {
    const n = ((this.#db.prepare("SELECT MAX(n) AS n FROM app_history WHERE ws = ? AND app = ?").get(ws, id) as { n: number | null }).n ?? 0) + 1;
    this.#db.prepare("INSERT INTO app_history (ws, app, n, at, current, by, note) VALUES (?, ?, ?, ?, ?, ?, ?)").run(ws, id, n, at, current, by, note);
  }

  /// A new version of `id` (the app made with it where there is none), made current. `base`: the version it was made on;
  /// refused where the newest is another (someone changed it meanwhile). `schema`: what it reads, else its .mbui's.
  save(ws: string, a: { id: string; title?: string | null; kind: AppKind; source: Uint8Array; note: string; by: string; base?: number | null; schema?: number | null; force?: boolean }): AppMeta {
    const { id, kind, source, by } = a;
    if (!APP_ID.test(id)) throw new AppRefused(400, `"${id}" is not an app id: lower-case letters, digits and -, at most 40, starting with a letter or digit`);
    const note = (a.note ?? "").trim();
    if (note === "") throw new AppRefused(400, "note is required: say in a line what this version changes");
    if ([...note].length > NOTE_MOST) throw new AppRefused(400, `note is over ${NOTE_MOST} characters: say it in a line`);
    checkSource(id, kind, source);
    const schema = a.schema ?? declaredSchema(source, kind) ?? 0;
    if (!Number.isSafeInteger(schema) || schema < 0) throw new AppRefused(400, "schema must be a whole number ≥ 0");
    const meta = this.#tx(() => {
      const now = this.#now();
      const was = this.#row(ws, id);
      if (was === undefined) {
        if (a.base !== undefined && a.base !== null && a.base !== 0) throw new AppRefused(409, `there is no app "${id}" (base_rev ${a.base} is of none): leave base_rev out to make it`);
        const count = (this.#db.prepare("SELECT COUNT(*) AS n FROM apps WHERE ws = ?").get(ws) as { n: number }).n;
        if (count >= APPS_MOST) throw new AppRefused(409, `this workspace has ${APPS_MOST} apps on this station: change one of them instead of making another`);
      } else {
        if (a.base !== undefined && a.base !== null && a.base !== was.rev) {
          throw new AppRefused(409, `app "${id}" is at version ${was.rev}, not ${a.base}: someone changed it meanwhile. Read version ${was.rev} (app_versions, then GET /apps/${id}?rev=${was.rev}), make your change on it and save with base_rev ${was.rev}`);
        }
        if (was.kind !== kind) throw new AppRefused(400, `app "${id}" is a .${was.kind} app; save a .${was.kind} file (or make a new app for the .${kind})`);
        if (schema < was.data_schema && a.force !== true) {
          throw new AppRefused(409, `this version reads schema ${schema} but the app's data is of schema ${was.data_schema}: it would misread newer documents. Raise its "schema" to ${was.data_schema} and read that shape, or force it`);
        }
      }
      const title = ((a.title ?? "").trim() === "" ? (was?.title ?? id) : [...a.title!.trim()].slice(0, TITLE_MOST).join(""));
      const rev = (was?.rev ?? 0) + 1;
      const sha256 = createHash("sha256").update(source).digest("hex");
      this.#db
        .prepare("INSERT INTO app_versions (ws, app, rev, kind, title, source, size, sha256, schema, note, by, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)")
        .run(ws, id, rev, kind, title, source, source.length, sha256, schema, note, by, now);
      const dataSchema = Math.max(was?.data_schema ?? 0, schema);
      if (was === undefined) {
        this.#db.prepare("INSERT INTO apps (ws, id, title, kind, rev, current, data_schema, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)").run(ws, id, title, kind, rev, rev, dataSchema, now, now);
      } else {
        this.#db.prepare("UPDATE apps SET title = ?, rev = ?, current = ?, data_schema = ?, updated_at = ? WHERE ws = ? AND id = ?").run(title, rev, rev, dataSchema, now, ws, id);
      }
      this.#step(ws, id, rev, by, note, now);
      return this.#meta(id, this.#row(ws, id)!);
    });
    this.#told({ kind: "app", ws, id, rev: meta.rev, current: meta.current });
    return meta;
  }

  /// Version `rev` of `id` made current again (or the newest, after a rollback): the versions stay as they are.
  publish(ws: string, a: { id: string; rev: number; by: string; note?: string; force?: boolean }): AppMeta {
    const meta = this.#tx(() => {
      const was = this.#known(ws, a.id);
      if (!Number.isSafeInteger(a.rev) || a.rev < 1 || a.rev > was.rev) throw new AppRefused(404, `app "${a.id}" has versions 1 to ${was.rev}: app_versions lists them`);
      const schema = this.#versionSchema(ws, a.id, a.rev) ?? 0;
      if (schema < was.data_schema && a.force !== true) {
        throw new AppRefused(409, `version ${a.rev} reads schema ${schema} but the app's data is of schema ${was.data_schema}: it would misread newer documents. Save a new version that reads schema ${was.data_schema}, or force it`);
      }
      if (a.rev === was.current) return this.#meta(a.id, was);
      const now = this.#now();
      this.#db.prepare("UPDATE apps SET current = ?, data_schema = ?, updated_at = ? WHERE ws = ? AND id = ?").run(a.rev, Math.max(was.data_schema, schema), now, ws, a.id);
      this.#step(ws, a.id, a.rev, a.by, (a.note ?? "").trim() === "" ? `version ${a.rev} made current` : [...a.note!.trim()].slice(0, NOTE_MOST).join(""), now);
      return this.#meta(a.id, this.#row(ws, a.id)!);
    });
    this.#told({ kind: "app", ws, id: a.id, rev: meta.rev, current: meta.current });
    return meta;
  }

  /// The workspace's apps, by id (at most APPS_MOST, as many as it may have).
  list(ws: string): AppMeta[] {
    const rows = this.#db.prepare("SELECT id, title, kind, rev, current, data_schema, updated_at FROM apps WHERE ws = ? ORDER BY id LIMIT ?").all(ws, APPS_MOST) as any[];
    return rows.map((r) => this.#meta(r.id, r));
  }

  /// One app's meta and the source of its current version, or of `rev`.
  get(ws: string, id: string, rev?: number | null): AppMeta & { source: Uint8Array } {
    const row = this.#known(ws, id);
    const at = rev ?? row.current;
    const v = this.#db.prepare("SELECT source, title FROM app_versions WHERE ws = ? AND app = ? AND rev = ?").get(ws, id, at) as { source: Uint8Array; title: string } | undefined;
    if (v === undefined) throw new AppRefused(404, `app "${id}" has versions 1 to ${row.rev}: app_versions lists them`);
    return { ...this.#meta(id, row), rev: at, source: v.source };
  }

  meta(ws: string, id: string): AppMeta {
    return this.#meta(id, this.#known(ws, id));
  }

  /// Its versions and the steps of what was current, the newest VERSIONS_SHOWN of each, newest first.
  versions(ws: string, id: string): { id: string; current: number; schema: number; versions: AppVersion[]; history: AppStep[] } {
    const row = this.#known(ws, id);
    const versions = this.#db
      .prepare("SELECT rev, created_at, by, note, size, sha256, schema FROM app_versions WHERE ws = ? AND app = ? ORDER BY rev DESC LIMIT ?")
      .all(ws, id, VERSIONS_SHOWN) as AppVersion[];
    const history = this.#db.prepare("SELECT at, current, by, note FROM app_history WHERE ws = ? AND app = ? ORDER BY n DESC LIMIT ?").all(ws, id, VERSIONS_SHOWN) as AppStep[];
    return { id, current: row.current, schema: row.data_schema, versions: versions.map((v) => ({ ...v })), history: history.map((h) => ({ ...h })) };
  }

  #checkDocKeys(collection: string, doc?: string) {
    if (!DOC_KEY.test(collection)) throw new AppRefused(400, `"${collection}" is not a collection name: letters, digits, _ . -, at most 64`);
    if (doc !== undefined && !DOC_KEY.test(doc)) throw new AppRefused(400, `"${doc}" is not a document id: letters, digits, _ . -, at most 64`);
  }

  /// A collection's documents by id (at most DOCS_MOST, as many as it may hold).
  docs(ws: string, app: string, collection: string): AppDoc[] {
    this.#known(ws, app);
    this.#checkDocKeys(collection);
    const rows = this.#db
      .prepare("SELECT id, json, rev, schema, updated_at FROM app_docs WHERE ws = ? AND app = ? AND collection = ? ORDER BY id LIMIT ?")
      .all(ws, app, collection, DOCS_MOST) as { id: string; json: string; rev: number; schema: number; updated_at: number }[];
    return rows.map((r) => ({ id: r.id, data: JSON.parse(r.json), rev: r.rev, schema: r.schema, updated_at: r.updated_at }));
  }

  doc(ws: string, app: string, collection: string, id: string): AppDoc | null {
    this.#known(ws, app);
    this.#checkDocKeys(collection, id);
    const r = this.#db.prepare("SELECT id, json, rev, schema, updated_at FROM app_docs WHERE ws = ? AND app = ? AND collection = ? AND id = ?").get(ws, app, collection, id) as any;
    return r === undefined ? null : { id: r.id, data: JSON.parse(r.json), rev: r.rev, schema: r.schema, updated_at: r.updated_at };
  }

  /// A document written whole, under the schema of the app's current version. `base`: the document's rev it was made
  /// on (0: it is new); refused where it is another.
  putDoc(ws: string, a: { app: string; collection: string; id: string; data: unknown; by: string; base?: number | null }): { rev: number } {
    this.#checkDocKeys(a.collection, a.id);
    const json = JSON.stringify(a.data === undefined ? null : a.data);
    if (Buffer.byteLength(json) > DOC_MOST) throw new AppRefused(413, `the document is over ${DOC_MOST} bytes as JSON: split it into several documents`);
    const rev = this.#tx(() => {
      const app = this.#known(ws, a.app);
      const was = this.#db.prepare("SELECT rev FROM app_docs WHERE ws = ? AND app = ? AND collection = ? AND id = ?").get(ws, a.app, a.collection, a.id) as { rev: number } | undefined;
      if (a.base !== undefined && a.base !== null && a.base !== (was?.rev ?? 0)) {
        throw new AppRefused(409, `document ${a.collection}/${a.id} is at rev ${was?.rev ?? 0}, not ${a.base}: someone changed it meanwhile. Read it again and write your change on it`);
      }
      if (was === undefined) {
        const n = (this.#db.prepare("SELECT COUNT(*) AS n FROM app_docs WHERE ws = ? AND app = ? AND collection = ?").get(ws, a.app, a.collection) as { n: number }).n;
        if (n >= DOCS_MOST) throw new AppRefused(409, `collection "${a.collection}" holds ${DOCS_MOST} documents, as many as it may: delete some or use another collection`);
        if (n === 0) {
          const collections = (this.#db.prepare("SELECT COUNT(DISTINCT collection) AS n FROM app_docs WHERE ws = ? AND app = ?").get(ws, a.app) as { n: number }).n;
          if (collections >= COLLECTIONS_MOST) throw new AppRefused(409, `app "${a.app}" has ${COLLECTIONS_MOST} collections, as many as it may: put this document in one of them`);
        }
      }
      const schema = this.#versionSchema(ws, a.app, app.current) ?? 0;
      const next = (was?.rev ?? 0) + 1;
      this.#db
        .prepare(
          `INSERT INTO app_docs (ws, app, collection, id, json, rev, schema, by, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
           ON CONFLICT (ws, app, collection, id) DO UPDATE SET json = excluded.json, rev = excluded.rev, schema = excluded.schema, by = excluded.by, updated_at = excluded.updated_at`,
        )
        .run(ws, a.app, a.collection, a.id, json, next, schema, a.by, this.#now());
      return next;
    });
    this.#told({ kind: "app-doc", ws, app: a.app, collection: a.collection, id: a.id, rev, deleted: false });
    return { rev };
  }

  /// A document deleted; nothing where there is none (said as `deleted: false`).
  deleteDoc(ws: string, a: { app: string; collection: string; id: string }): { deleted: boolean } {
    this.#checkDocKeys(a.collection, a.id);
    const rev = this.#tx(() => {
      this.#known(ws, a.app);
      const was = this.#db.prepare("SELECT rev FROM app_docs WHERE ws = ? AND app = ? AND collection = ? AND id = ?").get(ws, a.app, a.collection, a.id) as { rev: number } | undefined;
      if (was === undefined) return null;
      this.#db.prepare("DELETE FROM app_docs WHERE ws = ? AND app = ? AND collection = ? AND id = ?").run(ws, a.app, a.collection, a.id);
      return was.rev + 1;
    });
    if (rev === null) return { deleted: false };
    this.#told({ kind: "app-doc", ws, app: a.app, collection: a.collection, id: a.id, rev, deleted: true });
    return { deleted: true };
  }
}
