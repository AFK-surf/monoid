// Kept small files (`file_kept`), parsed Markdown trees (`md_kept`), log byte counts (`log_bytes`), and cache usage (account.ts).
import type { SqlRow } from "../host.ts";
import { TITLED } from "../titles.ts";
import { type DbEnv, type J, type MdPut, parse } from "./collection.ts";
import { ensureFilesKept, ensureLogBytes, ensureMdKept, LOG_TABLES } from "./schema.ts";

/// What chats show small, kept (`file_kept`, in characters of base64): at most this much, let go to FILES_KEPT_TO of it
/// past that; one larger than FILE_KEPT_MOST is not kept (a thumbnail is a few dozen KB). When one was shown is noted
/// at most once in FILE_SHOWN_EVERY: a note writes its row again, the image with it.
const FILES_KEPT = 64 * 1024 * 1024;
const FILES_KEPT_TO = 0.8;
/// The agents' sessions whose kept files' names are held in memory (`#keptOf`), the first read let go first.
const KEPT_OF_MOST = 256;
const FILE_KEPT_MOST = 1024 * 1024;
const FILE_SHOWN_EVERY = 86_400_000;
/// The trees of agents' words kept (`md_kept`, in characters of their JSON), as file_kept's: at most this much, let go
/// to MD_KEPT_TO of it past that, when one was shown noted at most once in MD_SHOWN_EVERY.
const MD_KEPT = 32 * 1024 * 1024;
const MD_KEPT_TO = 0.8;
/// How many trees one statement reads (`keptMdMany`): under SQLite's bound on a statement's parameters.
const MD_MANY = 200;

export type KeptCacheLogs = {
  clearLogCache(): void;
  forgetEntries(station: string, thread: number): void;
  tellLog(table: string, station: string, id: string, put?: number[] | null): void;
};

export class KeptCacheStore {
  readonly #env: DbEnv;
  readonly #logs: KeptCacheLogs;
  /// Whether `file_kept` is there (made as the first file is kept).
  #filesKept = false;
  /// What is kept of each agent's session (`station␁session`): its files' `name␁kind`, read in one statement as the first
  /// of them is asked (by the primary key's first columns), then kept level with every write and deletion of `file_kept`
  /// here, and let go of whole where a burst is rolled back. A chat drawn again asks of each of its files twice
  /// (views.ts `held`: a thumbnail, a poster), on every chat topic rebuild while an agent is working: 1,500 statements a
  /// change for a chat of 25 files over 30 changes, now none once its sessions are read.
  readonly #keptOf = new Map<string, Set<string>>();
  /// Whether `md_kept` is there (made as the first tree is kept), and what its trees take (counted at the first kept).
  #mdKept = false;
  #mdSize: number | null = null;
  /// Whether `log_bytes` is kept (schema.ts ensureLogBytes).
  #logBytes = false;
  /// The tables whose every station's logs are counted in `log_bytes` (countLogs), as far as this core knows.
  #logsCounted = new Set<string>();

  constructor(env: DbEnv, logs: KeptCacheLogs) {
    this.#env = env;
    this.#logs = logs;
  }

  openLogBytes(): void {
    try {
      ensureLogBytes(this.#env.sql);
      this.#logBytes = true;
    } catch {
      // No room to make it: what each chat keeps is counted of its rows this time.
    }
  }

  openMediaTables(): void {
    // Made as the first file is kept: a database that keeps none has no room taken for it.
    this.#filesKept = this.#env.sql.all("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'file_kept'").length > 0;
    this.#mdKept = this.#env.sql.all("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'md_kept'").length > 0;
  }

  onRollback(): void {
    this.#keptOf.clear();
    // (what was counted in it is not either)
    this.#logsCounted.clear();
  }

  forgetStation(station: string): void {
    if (this.#filesKept) {
      this.#env.sql.run("DELETE FROM file_kept WHERE station = ?", [station]);
      for (const of of [...this.#keptOf.keys()]) if (of.startsWith(`${station}\u0001`)) this.#keptOf.delete(of);
    }
    if (this.#mdKept) {
      this.#env.sql.run("DELETE FROM md_kept WHERE station = ?", [station]);
      this.#mdSize = null;
    }
  }

  // ── what chats show small (thumbnails, posters) ──

  /// What a chat shows small, as kept here (`kind`: thumb, poster): its type and bytes (base64), noted as shown `at`;
  /// null when it is not kept.
  keptFile(station: string, session: string, name: string, kind: string, at: number): { type: string; bytes: string } | null {
    if (!this.#filesKept) return null;
    let r: SqlRow | undefined;
    try {
      r = this.#env.sql.all("SELECT type, used, bytes FROM file_kept WHERE station = ? AND session = ? AND name = ? AND kind = ?", [station, session, name, kind])[0];
    } catch {
      // Not made after all (the write that made it could not be kept): made again with the next one kept.
      this.#filesKept = false;
      this.#keptOf.clear();
      return null;
    }
    if (r === undefined) return null;
    if (at - Number(r[1]) >= FILE_SHOWN_EVERY) this.#env.write(() => this.#env.sql.run("UPDATE file_kept SET used = ? WHERE station = ? AND session = ? AND name = ? AND kind = ?", [at, station, session, name, kind]));
    return { type: String(r[0]), bytes: String(r[2]) };
  }

  /// Whether what a chat shows small is kept here (`kind`: thumb, poster), not noting it as shown.
  hasKeptFile(station: string, session: string, name: string, kind: string): boolean {
    if (!this.#filesKept) return false;
    const of = `${station}\u0001${session}`;
    let names = this.#keptOf.get(of);
    if (names === undefined) {
      try {
        names = new Set(this.#env.sql.all("SELECT name, kind FROM file_kept WHERE station = ? AND session = ?", [station, session]).map((r) => `${String(r[0])}\u0001${String(r[1])}`));
      } catch {
        return false;
      }
      if (this.#keptOf.size >= KEPT_OF_MOST) this.#keptOf.delete(this.#keptOf.keys().next().value!);
      this.#keptOf.set(of, names);
    }
    return names.has(`${name}\u0001${kind}`);
  }

  /// `#keptOf` told of a row of `file_kept` put (`kept`) or deleted, where its session's are held.
  #keptFileTold(station: unknown, session: unknown, name: unknown, kind: unknown, kept: boolean): void {
    const names = this.#keptOf.get(`${String(station)}\u0001${String(session)}`);
    if (names === undefined) return;
    if (kept) names.add(`${String(name)}\u0001${String(kind)}`);
    else names.delete(`${String(name)}\u0001${String(kind)}`);
  }

  /// Keeps what a chat shows small as its station sent it; past FILES_KEPT, the least lately shown go.
  keepFile(station: string, session: string, name: string, kind: string, type: string, bytes: string, at: number): void {
    if (this.#env.readOnly || bytes.length > FILE_KEPT_MOST) return;
    this.#env.write(() => {
      if (!this.#filesKept) {
        ensureFilesKept(this.#env.sql);
        this.#filesKept = true;
      }
      this.#env.sql.run("INSERT OR REPLACE INTO file_kept (station, session, name, kind, type, size, used, bytes) VALUES (?, ?, ?, ?, ?, ?, ?, ?)", [station, session, name, kind, type, bytes.length, at, bytes]);
      this.#keptFileTold(station, session, name, kind, true);
      let total = Number(this.#env.sql.all("SELECT coalesce(sum(size), 0) FROM file_kept")[0]?.[0] ?? 0);
      if (total <= FILES_KEPT) return;
      for (const r of this.#env.sql.all("SELECT station, session, name, kind, size FROM file_kept ORDER BY used")) {
        if (total <= FILES_KEPT * FILES_KEPT_TO) break;
        this.#env.sql.run("DELETE FROM file_kept WHERE station = ? AND session = ? AND name = ? AND kind = ?", [r[0], r[1], r[2], r[3]]);
        this.#keptFileTold(r[0], r[1], r[2], r[3], false);
        total -= Number(r[4] ?? 0);
      }
    });
  }

  // ── the trees of what agents said (markdown.ts) ──

  /// Whether the tree of the text keyed `key` is kept here.
  hasMd(station: string, key: string): boolean {
    if (!this.#mdKept) return false;
    try {
      return this.#env.sql.all("SELECT 1 FROM md_kept WHERE station = ? AND key = ?", [station, key]).length > 0;
    } catch {
      this.#mdKept = false;
      return false;
    }
  }

  /// Owners with cached trees from an older reading, in bounded pages, so updating them does not hold up the app.
  oldMdOwners(reading: number, after: { station: string; of: string }): { station: string; of: string }[] {
    if (!this.#mdKept) return [];
    return this.#env.sql.all(
      `SELECT station, of FROM md_kept
       WHERE (station > ? OR (station = ? AND of > ?))
         AND CAST(substr(key, 1, instr(key, '.') - 1) AS INTEGER) < ?
       GROUP BY station, of ORDER BY station, of LIMIT 20`,
      [after.station, after.station, after.of, reading],
    ).map((r) => ({ station: String(r[0]), of: String(r[1]) }));
  }

  /// Stop looking through an owner's sources once none of its older trees remain.
  hasOldMd(station: string, of: string, reading: number): boolean {
    if (!this.#mdKept) return false;
    return this.#env.sql.all("SELECT 1 FROM md_kept WHERE station = ? AND of = ? AND CAST(substr(key, 1, instr(key, '.') - 1) AS INTEGER) < ? LIMIT 1", [station, of, reading]).length > 0;
  }

  /// A bounded page of a cached tree owner's source entries, newest first. Sequence numbers need not be contiguous.
  mdSourcePage(station: string, of: string, before: number): { n: number; json: unknown }[] {
    const thread = of.startsWith("t:") ? Number(of.slice(2)) : null;
    const session = of.startsWith("s:") ? of.slice(2) : null;
    if (thread !== null && Number.isSafeInteger(thread)) {
      return this.#env.sql.all("SELECT n, json FROM entry WHERE station = ? AND thread = ? AND n < ? ORDER BY n DESC LIMIT 50", [station, thread, before]).map((r) => ({ n: Number(r[0]), json: parse(r[1]) }));
    }
    if (session !== null) {
      return this.#env.sql.all("SELECT i, json FROM transcript WHERE station = ? AND session = ? AND i < ? ORDER BY i DESC LIMIT 50", [station, session, before]).map((r) => ({ n: Number(r[0]), json: parse(r[1]) }));
    }
    return [];
  }

  /// The tree of the text keyed `key` (its JSON) and when it was last noted shown; null when it is not kept. Reads only:
  /// noting it shown again is the caller's to write later (`flushMd`), never on the path that shows it.
  keptMd(station: string, key: string): { used: number; json: string } | null {
    if (!this.#mdKept) return null;
    let r: SqlRow | undefined;
    try {
      r = this.#env.sql.all("SELECT used, json FROM md_kept WHERE station = ? AND key = ?", [station, key])[0];
    } catch {
      // Not made after all (the write that made it could not be kept): made again with the next one kept.
      this.#mdKept = false;
      return null;
    }
    return r === undefined ? null : { used: Number(r[0]), json: String(r[1]) };
  }

  /// The trees of the texts keyed `keys` that are kept, in one statement for each MD_MANY of them: what a chat's page
  /// shows read at once as it is drawn (views.ts `drawn`), not one statement a reply. Reads only.
  keptMdMany(station: string, keys: readonly string[]): Map<string, { used: number; json: string }> {
    const out = new Map<string, { used: number; json: string }>();
    if (!this.#mdKept || keys.length === 0) return out;
    const unique = [...new Set(keys)];
    try {
      for (let i = 0; i < unique.length; i += MD_MANY) {
        const some = unique.slice(i, i + MD_MANY);
        const rows = this.#env.sql.all("SELECT m.key, m.used, m.json FROM json_each(?) AS k CROSS JOIN md_kept AS m WHERE m.station = ? AND m.key = k.value", [JSON.stringify(some), station]);
        for (const r of rows) out.set(String(r[0]), { used: Number(r[1]), json: String(r[2]) });
      }
    } catch {
      this.#mdKept = false;
      return new Map();
    }
    return out;
  }

  /// Keeps the tree of the text keyed `key`, read for `of` (a chat, `t:<thread>`; an agent, `s:<session>`); past
  /// MD_KEPT, the least lately shown go.
  keepMd(station: string, of: string, key: string, json: string, at: number, replaces?: string): void {
    this.flushMd(station, [{ of, key, json, at, ...(replaces === undefined ? {} : { replaces }) }], []);
  }

  /// What was read and shown of a station's trees since the last flush, written in one transaction: the trees read
  /// (`puts`, each in place of the one it `replaces`), those shown again (`touches`: when, for MD_SHOWN_EVERY's
  /// order of what goes past MD_KEPT); past MD_KEPT, the least lately shown go, once at its end.
  flushMd(station: string, puts: readonly MdPut[], touches: readonly { key: string; at: number }[]): void {
    if (this.#env.readOnly || (puts.length === 0 && touches.length === 0)) return;
    this.#env.write(() => {
      if (!this.#mdKept) {
        ensureMdKept(this.#env.sql);
        this.#mdKept = true;
      }
      const put = new Set(puts.map((p) => p.key));
      for (const t of touches) if (!put.has(t.key)) this.#env.sql.run("UPDATE md_kept SET used = ? WHERE station = ? AND key = ?", [t.at, station, t.key]);
      if (puts.length === 0) return;
      // (what all of them take, counted once and then kept count of: a tree is kept with each reply read)
      this.#mdSize ??= Number(this.#env.sql.all("SELECT coalesce(sum(size), 0) FROM md_kept")[0]?.[0] ?? 0);
      for (const p of puts) {
        const was = Number(this.#env.sql.all("SELECT size FROM md_kept WHERE station = ? AND key = ?", [station, p.key])[0]?.[0] ?? 0);
        if (p.replaces !== undefined && p.replaces !== p.key) {
          const old = Number(this.#env.sql.all("SELECT size FROM md_kept WHERE station = ? AND key = ?", [station, p.replaces])[0]?.[0] ?? 0);
          this.#env.sql.run("DELETE FROM md_kept WHERE station = ? AND key = ?", [station, p.replaces]);
          this.#mdSize -= old;
        }
        this.#env.sql.run("INSERT OR REPLACE INTO md_kept (station, key, of, size, used, json) VALUES (?, ?, ?, ?, ?, ?)", [station, p.key, p.of, p.json.length, p.at, p.json]);
        this.#mdSize += p.json.length - was;
      }
      if (this.#mdSize <= MD_KEPT) return;
      for (const r of this.#env.sql.all("SELECT station, key, size FROM md_kept ORDER BY used")) {
        if (this.#mdSize <= MD_KEPT * MD_KEPT_TO) break;
        this.#env.sql.run("DELETE FROM md_kept WHERE station = ? AND key = ?", [r[0], r[1]]);
        this.#mdSize -= Number(r[2] ?? 0);
      }
    });
  }

  // ── cache usage and per-chat eviction ──

  /// One step of counting the logs not counted yet (schema.ts ensureLogBytes: each station's of a table, whole, once):
  /// answers whether any is left. A step reads one station's rows of one table, so the caller can let other work in
  /// between (station/calls.ts cache.usage); what is written meanwhile the triggers count, and a station counted anew
  /// is counted whole. Nothing to count where the counts are not kept (a database a newer core wrote) or cannot be
  /// written (no room, a write of this burst that failed): a step that cannot write says none is left, so a caller's
  /// loop ends, and what is not counted is read of its rows (cacheUsage).
  countLogs(): boolean {
    if (!this.#logBytes || this.#env.readOnly) return false;
    for (const [table, key] of Object.entries(LOG_TABLES) as [keyof typeof LOG_TABLES, string][]) {
      if (this.#logsCounted.has(table)) continue;
      const done = new Set(this.#env.sql.all("SELECT station FROM log_bytes_done WHERE tbl = ?", [table]).map((r) => String(r[0])));
      if (done.has("")) {
        this.#logsCounted.add(table);
        continue;
      }
      // (each station of the table, seeking to the next in its key: DISTINCT would walk every row)
      const stations = this.#env.sql.all(
        `WITH RECURSIVE s(station) AS (
           SELECT min(station) FROM ${table}
           UNION ALL
           SELECT (SELECT min(t.station) FROM ${table} t WHERE t.station > s.station) FROM s WHERE s.station IS NOT NULL
         ) SELECT station FROM s WHERE station IS NOT NULL`,
      ).map((r) => String(r[0]));
      const next = stations.find((st) => !done.has(st));
      if (this.#env.full() || this.#env.failed()) return false;
      let wrote = false;
      this.#env.write(() => {
        if (next === undefined) {
          // (every station of the table counted, listed in this same step: from now on all of them are; a count of one
          // not counted, were there one, goes)
          this.#env.sql.run("DELETE FROM log_bytes WHERE tbl = ? AND station NOT IN (SELECT station FROM log_bytes_done WHERE tbl = ?)", [table, table]);
          this.#env.sql.run("INSERT OR IGNORE INTO log_bytes_done (tbl, station) VALUES (?, '')", [table]);
          this.#env.sql.run("DELETE FROM log_bytes_done WHERE tbl = ? AND station <> ''", [table]);
          wrote = true;
          return;
        }
        this.#env.sql.run("DELETE FROM log_bytes WHERE tbl = ? AND station = ?", [table, next]);
        this.#env.sql.run(`INSERT INTO log_bytes (tbl, station, id, bytes) SELECT ?, station, ${key}, sum(length(json)) FROM ${table} WHERE station = ? GROUP BY ${key} HAVING sum(length(json)) <> 0`, [table, next]);
        this.#env.sql.run("INSERT OR IGNORE INTO log_bytes_done (tbl, station) VALUES (?, ?)", [table, next]);
        wrote = true;
      });
      if (!wrote || this.#env.failed()) return false;
      if (next === undefined) this.#logsCounted.add(table);
      return true;
    }
    return false;
  }

  /// What this database keeps of each chat (a thread): its entries, its sessions' transcripts and what it shows small, in
  /// characters of their JSON (near enough their bytes), with its sessions and what of its row says what it is called
  /// (`view`: format.ts chatTitle's fields, null when no row is held); what a session has counted with its first
  /// thread. For the device's page of what it keeps (`cache.usage`). Its logs are read of what they are counted at
  /// (`log_bytes`, counted first where they are not: countLogs), never of their rows.
  cacheUsage(): { station: string; thread: number; view: J | null; sessions: string[]; bytes: number }[] {
    while (this.countLogs());
    // (read of the counts only where every table's are whole: where a step could not be written, of the rows)
    const counted = this.#logBytes && !this.#env.readOnly && Object.keys(LOG_TABLES).every((t) => this.#logsCounted.has(t));
    const out = new Map<string, { station: string; thread: number; view: J | null; sessions: string[]; bytes: number }>();
    const of = (station: string, thread: number) => {
      const k = `${station}\0${thread}`;
      let row = out.get(k);
      if (row === undefined) out.set(k, (row = { station, thread, view: null, sessions: [], bytes: 0 }));
      return row;
    };
    const logs = counted
      ? this.#env.sql.all("SELECT tbl, station, id, bytes FROM log_bytes")
      : [
          ...this.#env.sql.all("SELECT 'entry', station, thread, sum(length(json)) FROM entry GROUP BY station, thread"),
          ...this.#env.sql.all("SELECT 'transcript', station, session, sum(length(json)) FROM transcript GROUP BY station, session"),
        ];
    for (const r of logs) if (r[0] === "entry") of(r[1] as string, Number(r[2])).bytes += Number(r[3] ?? 0);
    const firstThread = new Map<string, number>();
    for (const r of this.#env.sql.all("SELECT station, session, thread FROM thread_member ORDER BY station, session, thread")) {
      const [station, session, thread] = [r[0] as string, r[1] as string, r[2] as number];
      of(station, thread).sessions.push(session);
      if (!firstThread.has(`${station}\0${session}`)) firstThread.set(`${station}\0${session}`, thread);
    }
    for (const r of logs) {
      if (r[0] !== "transcript") continue;
      const thread = firstThread.get(`${r[1] as string}\0${r[2] as string}`);
      if (thread !== undefined) of(r[1] as string, thread).bytes += Number(r[3] ?? 0);
    }
    if (this.#filesKept) {
      for (const r of this.#env.sql.all("SELECT station, session, sum(size) FROM file_kept GROUP BY station, session")) {
        const thread = firstThread.get(`${r[0] as string}\0${r[1] as string}`);
        if (thread !== undefined) of(r[0] as string, thread).bytes += Number(r[2] ?? 0);
      }
    }
    if (this.#mdKept) {
      for (const r of this.#env.sql.all("SELECT station, of, sum(size) FROM md_kept GROUP BY station, of")) {
        const [station, at] = [r[0] as string, r[1] as string];
        const thread = at.startsWith("t:") ? Number(at.slice(2)) : firstThread.get(`${station}\0${at.slice(2)}`);
        if (thread !== undefined && Number.isInteger(thread)) of(station, thread).bytes += Number(r[2] ?? 0);
      }
    }
    const shown = [...out.values()].filter((r) => r.bytes > 0);
    // (each row's fields its title is made of, by SQLite, in one statement: neither a statement nor a whole row parsed
    // here a chat)
    if (shown.length > 0) {
      const keys = JSON.stringify(shown.map((r) => [r.station, r.thread]));
      const rows = this.#env.sql.all(
        `SELECT t.station, t.id, json_type(t.json), ${TITLED.map((k) => `CASE json_type(t.json, '$.${k}') WHEN 'text' THEN json_extract(t.json, '$.${k}') END`).join(", ")}
         FROM json_each(?) AS k JOIN thread AS t ON t.station = k.value ->> 0 AND t.id = k.value ->> 1`,
        [keys],
      );
      // (each a text, or not there: what is not a text is nothing to chatTitle; a record that is JSON's null, none)
      for (const r of rows) {
        const row = out.get(`${r[0] as string}\0${r[1] as number}`);
        if (row === undefined || r[2] === "null") continue;
        const view: Record<string, string> = {};
        TITLED.forEach((k, i) => {
          const v = r[3 + i];
          if (typeof v === "string") view[k] = v;
        });
        row.view = view;
      }
    }
    return shown;
  }

  /// Forgets what is kept of a chat: its entries, its sessions' transcripts and what it shows small (read again from its
  /// station when it is opened). What waits to be sent, drafts and the chat's row stay.
  forgetChat(station: string, thread: number): void {
    this.#env.write(() => {
      const sessions = this.#env.sql.all("SELECT session FROM thread_member WHERE station = ? AND thread = ?", [station, thread]).map((r) => r[0] as string);
      this.#logs.clearLogCache();
      this.#logs.forgetEntries(station, thread);
      for (const session of sessions) if (this.#env.sql.run("DELETE FROM transcript WHERE station = ? AND session = ?", [station, session]) > 0) this.#logs.tellLog("transcript", station, session);
      if (this.#filesKept) for (const session of sessions) {
        this.#env.sql.run("DELETE FROM file_kept WHERE station = ? AND session = ?", [station, session]);
        this.#keptOf.delete(`${station}\u0001${session}`);
      }
      if (this.#mdKept) {
        for (const of of [`t:${thread}`, ...sessions.map((s) => `s:${s}`)]) this.#env.sql.run("DELETE FROM md_kept WHERE station = ? AND of = ?", [station, of]);
        this.#mdSize = null;
      }
    });
  }
}
