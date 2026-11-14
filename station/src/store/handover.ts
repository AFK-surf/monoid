// A chat handed from one station to another while both are up (replica/handover.ts): the rows of its sessions and of
// the threads they take part in, read here a bounded page at a time on the station it leaves, and put in there through
// the store (store.ts `importRows`, in its transaction, its triggers keeping what is made of them), hidden until it is
// shown. A thread there is the one of the same surface, channel and ts (a still.fail chat of another's home given the
// next free ts); its entries go on past what that one has: ownership of a chat's log is one station's at a time, so a
// log handed back goes on from where it was left (n kept), and one both followed meanwhile (a platform's thread two
// bots are in) takes what it lacks by ts, numbered on. What was put in is said (`Made`), so that a hand-over that fails
// takes it out again, and counted, so that the station it leaves can compare it with what it sent.
import type { DatabaseSync, SQLInputValue } from "node:sqlite";
import { join, sep } from "node:path";
import { STILLFAIL_SURFACE } from "./rows.ts";

type Json = any;
type Row = Record<string, unknown>;

/// The tables a chat's rows are in, in the order they are put in (what a row names before it).
export const CHAT_TABLES = ["threads", "sessions", "thread_sessions", "entries", "letters", "turns", "runtime_sessions", "closed_cards", "reads", "hidden_chats", "muted_chats", "kept_chats", "dismissed", "pins", "opened_chats", "deliveries"] as const;
export type ChatTable = (typeof CHAT_TABLES)[number];
/// Of each thread: its own rows (by its log's number), and each viewer's marks of it.
export const BY_N: readonly ChatTable[] = ["entries", "letters", "closed_cards"];
export const MARKS: readonly ChatTable[] = ["reads", "hidden_chats", "muted_chats", "kept_chats", "dismissed"];
/// The most rows of a page.
export const PAGE = 500;

/// Where a page goes on from: the thread (or session) it is of, and its last row's key.
export type After = Json;

/// The viewers of a mark table, one at a time by its key (none scanned beyond them): what a thread's marks are found by.
const viewers = (table: string) => `WITH RECURSIVE viewers(viewer) AS MATERIALIZED (
    SELECT (SELECT viewer FROM ${table} ORDER BY viewer LIMIT 1)
    UNION ALL SELECT (SELECT viewer FROM ${table} WHERE viewer > v.viewer ORDER BY viewer LIMIT 1)
      FROM viewers v WHERE v.viewer IS NOT NULL
  )`;

/// A page of `table`'s rows of thread `thread` (BY_N, MARKS, thread_sessions of `keys`) or of session `key` (the rest),
/// after `after` (a key of the last row of the page before; null: the first), at most `limit`, by an index.
export function chatPage(db: DatabaseSync, table: ChatTable, of: number | string, after: After, limit = PAGE, keys: readonly string[] = []): Row[] {
  const all = (sql: string, ...args: SQLInputValue[]) => db.prepare(sql).all(...args) as Row[];
  switch (table) {
    case "threads":
      return all("SELECT * FROM threads WHERE id = ?", of as number);
    case "thread_sessions":
      return all("SELECT * FROM thread_sessions WHERE thread = ? AND session IN (SELECT value FROM json_each(?))", of as number, JSON.stringify(keys));
    case "entries":
    case "letters":
    case "closed_cards":
      return all(`SELECT * FROM ${table} WHERE thread = ? AND n > ? ORDER BY n LIMIT ?`, of as number, (after as number | null) ?? -1, limit);
    case "reads":
    case "hidden_chats":
    case "muted_chats":
    case "kept_chats":
      return all(`${viewers(table)} SELECT * FROM ${table} WHERE viewer IN (SELECT viewer FROM viewers WHERE viewer IS NOT NULL) AND thread = ? AND viewer > ? ORDER BY viewer LIMIT ?`, of as number, (after as string | null) ?? "", limit);
    case "dismissed": {
      const [v, n] = (after as [string, number] | null) ?? ["", -1];
      return all(`${viewers(table)} SELECT * FROM dismissed WHERE viewer IN (SELECT viewer FROM viewers WHERE viewer IS NOT NULL) AND thread = ? AND (viewer > ? OR (viewer = ? AND n > ?)) ORDER BY viewer, n LIMIT ?`, of as number, v, v, n, limit);
    }
    case "sessions":
      return all("SELECT * FROM sessions WHERE key = ?", of as string);
    case "turns": {
      const [at, id] = (after as [number, string] | null) ?? [-1, ""];
      return all("SELECT * FROM turns WHERE session_key = ? AND (started_at > ? OR (started_at = ? AND id > ?)) ORDER BY started_at, id LIMIT ?", of as string, at, at, id, limit);
    }
    case "runtime_sessions":
      return all("SELECT * FROM runtime_sessions WHERE session_key = ? AND id > ? ORDER BY id LIMIT ?", of as string, (after as string | null) ?? "", limit);
    case "pins":
      return all(`${viewers("pins")} SELECT * FROM pins WHERE viewer IN (SELECT viewer FROM viewers WHERE viewer IS NOT NULL) AND session = ? AND viewer > ? ORDER BY viewer LIMIT ?`, of as string, (after as string | null) ?? "", limit);
    case "opened_chats":
      return all("SELECT * FROM opened_chats WHERE child_station = '' AND child = ?", of as string);
    case "deliveries": {
      const [t, n] = (after as [number, number] | null) ?? [-1, -1];
      return all("SELECT * FROM deliveries WHERE session = ? AND delivered_at IS NULL AND (thread > ? OR (thread = ? AND n > ?)) ORDER BY thread, n LIMIT ?", of as string, t, t, n, limit);
    }
  }
}

/// The key a page goes on after, of its last row.
export function afterOf(table: ChatTable, row: Row): After {
  switch (table) {
    case "entries":
    case "letters":
    case "closed_cards":
      return row.n;
    case "reads":
    case "hidden_chats":
    case "muted_chats":
    case "kept_chats":
    case "pins":
      return row.viewer;
    case "dismissed":
      return [row.viewer, row.n];
    case "turns":
      return [row.started_at, row.id];
    case "runtime_sessions":
      return row.id;
    case "deliveries":
      return [row.thread, row.n];
    default:
      return null;
  }
}

/// The threads sessions `keys` take part in, after thread `after`, at most `limit`, by the index of a session's.
export function chatThreads(db: DatabaseSync, keys: readonly string[], after: number, limit = PAGE): number[] {
  const out = new Set<number>();
  for (const key of keys) {
    for (const r of db.prepare("SELECT thread FROM thread_sessions WHERE session = ? AND thread > ? ORDER BY thread LIMIT ?").all(key, after, limit) as { thread: number }[]) out.add(r.thread);
  }
  return [...out].sort((a, b) => a - b).slice(0, limit);
}

/// A thread of the copy as it is put in here: its id here, whether this put it in (`fresh`), and how its log goes on:
/// `linear` while each entry put in kept its number (its log here was this chat's own as it was left, or none), the
/// numbers it was given where not (`ns`, `ls`: the copy's to here's, of entries and of letters).
export type ThreadThere = { id: number; fresh: boolean; linear: boolean; lettersLinear: boolean; ns: Record<string, number>; ls: Record<string, number> };

/// What was put in, kept on the station it goes to until it is shown (so that a hand-over that fails takes it out):
/// each session (as it was before: null, put in anew), the entries and letters (by thread, ranges of numbers), the
/// threads put in anew, the memberships, and the other rows by table and their key.
export type Made = {
  sessions: { key: string; before: Row | null }[];
  entries: [number, number, number][];
  letters: [number, number, number][];
  members: [number, string][];
  rows: Record<string, Row[]>;
};

/// How a chat's rows are put in here: the station it came from and its data directory, this one's; how its connects'
/// ids and its accounts go here (by the ids there, to the ids here); what its sessions' `ws` is until shown; its threads
/// here (by their id there), what was put in, and counted.
export type ImportCtx = {
  from: string;
  /// This station (where it began, its row says none of where it came from).
  here?: string;
  fromData: string;
  toData: string;
  connects: Record<string, string>;
  profiles: Record<string, string>;
  ws: string;
  threads: Record<string, ThreadThere>;
  made: Made;
  counts: Counts;
};
/// What was put in or found there already (counted alike): sessions, and of each thread (by its id there) its entries
/// and letters, and the rows of the rest by table.
export type Counts = { sessions: number; entries: Record<string, number>; letters: Record<string, number>; rows: Record<string, number> };

export const newCtx = (c: Omit<ImportCtx, "threads" | "made" | "counts">): ImportCtx => ({
  ...c, threads: {}, made: { sessions: [], entries: [], letters: [], members: [], rows: {} }, counts: { sessions: 0, entries: {}, letters: {}, rows: {} },
});

const moved = (path: unknown, from: string, to: string): unknown => {
  if (typeof path !== "string" || from === "" || from === to) return path;
  const f = from.endsWith(sep) ? from.slice(0, -1) : from;
  if (path === f) return to;
  return path.startsWith(f + sep) || path.startsWith(`${f}/`) ? join(to, path.slice(f.length + 1)) : path;
};

/// A surface naming a connect (`feishu:<id>`, `comma:<id>`, a Slack connect's while its team is not known) as it is here.
export function surfaceHere(surface: string, connects: Record<string, string>): string {
  const at = surface.indexOf(":");
  if (at < 0) return surface;
  const id = surface.slice(at + 1);
  return connects[id] !== undefined ? `${surface.slice(0, at + 1)}${connects[id]}` : surface;
}

/// The columns `table` has here.
function columnsOf(db: DatabaseSync, table: string): Set<string> {
  return new Set((db.prepare(`SELECT name FROM pragma_table_info('${table}')`).all() as { name: string }[]).map((x) => x.name));
}

function insert(db: DatabaseSync, table: string, row: Row, or: "" | " OR IGNORE" = ""): { changes: number; id: number } {
  const have = columnsOf(db, table);
  const cols = Object.keys(row).filter((c) => have.has(c));
  const r = db.prepare(`INSERT${or} INTO ${table} (${cols.join(", ")}) VALUES (${cols.map(() => "?").join(", ")})`).run(...cols.map((c) => row[c] as SQLInputValue));
  return { changes: Number(r.changes), id: Number(r.lastInsertRowid) };
}

const bump = (ts: string): string => {
  let i = ts.length;
  while (i > 0 && ts.charCodeAt(i - 1) >= 48 && ts.charCodeAt(i - 1) <= 57) i--;
  if (i === ts.length) return `${ts}1`;
  return ts.slice(0, i) + String(BigInt(ts.slice(i)) + 1n).padStart(ts.length - i, "0");
};

/// What a page touched here, for the changes the store tells: sessions, threads (with entries put in), and each mark
/// as its own change says it (what the copies' export reads again by: replica/copies.ts `tell`).
export type Touched = { sessions: Set<string>; threads: Set<number>; marks?: Json[] };

/// A page of `table`'s rows of the copy put in (inside a transaction of the store's): what it touched.
export function importRows(db: DatabaseSync, ctx: ImportCtx, table: ChatTable, rows: Row[], touched: Touched): void {
  const thread = (was: unknown): ThreadThere | undefined => ctx.threads[String(was)];
  const n = (t: ThreadThere | undefined, was: unknown) => (t === undefined ? undefined : t.ns[String(was)] ?? (was as number));
  const told = (change: Json) => void (touched.marks ??= []).push(change);
  const keep = (key: Row) => {
    (ctx.made.rows[table] ??= []).push(key);
    ctx.counts.rows[table] = (ctx.counts.rows[table] ?? 0) + 1;
    const k = key as Json;
    if (table === "reads") told({ type: "read", viewer: k.viewer, thread: k.thread, n: null });
    else if (table === "hidden_chats") told({ type: "hidden", viewer: k.viewer, thread: k.thread, hidden: true });
    else if (table === "muted_chats") told({ type: "muted", viewer: k.viewer, thread: k.thread, muted: true });
    else if (table === "kept_chats") told({ type: "dismissed", viewer: k.viewer, kept: { thread: k.thread, kept: true } });
    else if (table === "dismissed") told({ type: "dismissed", viewer: k.viewer, card: { thread: k.thread, n: k.n } });
    else if (table === "pins") told({ type: "pins", viewer: k.viewer, session: k.session, at: null });
    else if (table === "closed_cards") told({ type: "thread", id: k.thread, entries: [], closed: k.n });
    else if (table === "turns" || table === "runtime_sessions") touched.sessions.add(String(k.session_key ?? ""));
  };
  for (const r0 of rows) {
    const r: Row = { ...r0 };
    switch (table) {
      case "threads": {
        const was = Number(r.id);
        delete r.id;
        r.surface = surfaceHere(String(r.surface), ctx.connects);
        const at = (ts: unknown) => db.prepare("SELECT id, home FROM threads WHERE surface = ? AND channel = ? AND thread_ts = ?").get(r.surface as string, r.channel as string, ts as string) as { id: number; home: string | null } | undefined;
        let here = at(r.thread_ts);
        // (a still.fail chat is each station's own: one of the same ts there that is another's is not it)
        if (here !== undefined && r.surface === STILLFAIL_SURFACE && here.home !== r.home) {
          let ts = String(r.thread_ts);
          do ts = bump(ts);
          while (at(ts) !== undefined);
          r.thread_ts = ts;
          here = undefined;
        }
        if (here !== undefined) {
          ctx.threads[String(was)] = { id: here.id, fresh: false, linear: true, lettersLinear: true, ns: {}, ls: {} };
        } else {
          const made = insert(db, "threads", r);
          ctx.threads[String(was)] = { id: made.id, fresh: true, linear: true, lettersLinear: true, ns: {}, ls: {} };
        }
        touched.threads.add(ctx.threads[String(was)]!.id);
        break;
      }
      case "sessions": {
        if (typeof r.connect === "string" && ctx.connects[r.connect] !== undefined) r.connect = ctx.connects[r.connect];
        r.workspace = moved(r.workspace, ctx.fromData, ctx.toData);
        r.cwd = moved(r.cwd, ctx.fromData, ctx.toData);
        r.running = 0;
        r.ws = ctx.ws;
        // (where it came from and where it began: none where it comes back to where it began)
        const began = typeof r.began_on === "string" && r.began_on !== "" ? r.began_on : ctx.from;
        if (ctx.here !== undefined && began === ctx.here) {
          r.began_on = null;
          r.came_from = null;
        } else {
          r.began_on = began;
          r.came_from = ctx.from;
        }
        if (typeof r.profile === "string" && ctx.profiles[r.profile] !== undefined) r.profile = ctx.profiles[r.profile];
        if (typeof r.profiles === "string") {
          try {
            const list = JSON.parse(r.profiles);
            if (Array.isArray(list)) r.profiles = JSON.stringify(list.map((p) => ctx.profiles[p] ?? p));
          } catch {}
        }
        const before = db.prepare("SELECT * FROM sessions WHERE key = ?").get(r.key as string) as Row | undefined;
        if (before === undefined) insert(db, "sessions", r);
        else {
          const have = columnsOf(db, "sessions");
          const cols = Object.keys(r).filter((c) => have.has(c) && c !== "key");
          db.prepare(`UPDATE sessions SET ${cols.map((c) => `${c} = ?`).join(", ")} WHERE key = ?`).run(...cols.map((c) => r[c] as SQLInputValue), r.key as string);
        }
        if (!ctx.made.sessions.some((s) => s.key === r.key)) ctx.made.sessions.push({ key: String(r.key), before: before ?? null });
        ctx.counts.sessions++;
        touched.sessions.add(String(r.key));
        break;
      }
      case "thread_sessions": {
        const t = thread(r.thread);
        if (t === undefined) break;
        r.thread = t.id;
        if (typeof r.connect === "string" && ctx.connects[r.connect] !== undefined) r.connect = ctx.connects[r.connect];
        if (insert(db, "thread_sessions", r, " OR IGNORE").changes > 0) ctx.made.members.push([t.id, String(r.session)]);
        ctx.counts.rows.thread_sessions = (ctx.counts.rows.thread_sessions ?? 0) + 1;
        touched.threads.add(t.id);
        touched.sessions.add(String(r.session));
        break;
      }
      case "entries":
      case "letters": {
        const t = thread(r.thread);
        if (t === undefined) break;
        const was = Number(r.n);
        const map = table === "entries" ? t.ns : t.ls;
        const last = (db.prepare(`SELECT MAX(n) AS n FROM ${table} WHERE thread = ?`).get(t.id) as { n: number | null }).n ?? 0;
        const same = db.prepare(`SELECT ts, author FROM ${table} WHERE thread = ? AND n = ?`).get(t.id, was) as { ts: string | null; author: string } | undefined;
        const counts = table === "entries" ? ctx.counts.entries : ctx.counts.letters;
        counts[String(r0.thread)] = (counts[String(r0.thread)] ?? 0) + 1;
        const linear = table === "entries" ? t.linear : t.lettersLinear;
        // (this chat's own log as it was left there: what it has is the copy's, and the rest goes on from its last)
        if (linear && same !== undefined && same.ts === (r.ts ?? null) && same.author === r.author) break;
        let to: number;
        if (linear && same === undefined && was === last + 1) to = was;
        else {
          if (table === "entries") t.linear = false;
          else t.lettersLinear = false;
          // (one with no ts, an edit of a message (store.ts #editMessage): found by what it is, its target as it is
          // here, through entries_edits, so that a chat handed forth and back again does not get it twice; letters
          // always have one, store.ts insertLetter)
          const target = table === "entries" && typeof r.target === "number" ? n(t, r.target) : undefined;
          const byTs = r.ts !== null && r.ts !== undefined
            ? (db.prepare(`SELECT n FROM ${table} WHERE thread = ? AND ts = ?`).get(t.id, r.ts as string) as { n: number } | undefined)
            : target === undefined ? undefined
            : (db.prepare("SELECT n FROM entries WHERE thread = ? AND target = ? AND ts IS NULL AND kind IS ? AND author = ? AND at IS ? AND text IS ? LIMIT 1")
              .get(t.id, target, (r.kind ?? null) as SQLInputValue, String(r.author), (r.at ?? null) as SQLInputValue, (r.text ?? null) as SQLInputValue) as { n: number } | undefined);
          if (byTs !== undefined) {
            map[String(was)] = byTs.n;
            break;
          }
          to = last + 1;
          map[String(was)] = to;
        }
        r.thread = t.id;
        r.n = to;
        if (table === "entries" && typeof r.target === "number") r.target = n(t, r.target);
        if (typeof r.attachments === "string" && r.attachments !== "") {
          try {
            const list = JSON.parse(r.attachments);
            if (Array.isArray(list)) r.attachments = JSON.stringify(list.map((a) => (a !== null && typeof a === "object" && typeof a.path === "string" ? { ...a, path: moved(a.path, ctx.fromData, ctx.toData) } : a)));
          } catch {}
        }
        insert(db, table, r);
        const ranges = table === "entries" ? ctx.made.entries : ctx.made.letters;
        const end = ranges.at(-1);
        if (end !== undefined && end[0] === t.id && end[2] === to - 1) end[2] = to;
        else ranges.push([t.id, to, to]);
        touched.threads.add(t.id);
        break;
      }
      case "turns": {
        const t = thread(r.about_thread);
        if (r.about_thread !== null && r.about_thread !== undefined) {
          if (t === undefined) (r.about_thread = null), (r.about_n = null);
          else (r.about_n = n(t, r.about_n) ?? null), (r.about_thread = t.id);
        }
        if (insert(db, "turns", r, " OR IGNORE").changes > 0) keep({ id: r.id, session_key: r.session_key });
        else ctx.counts.rows.turns = (ctx.counts.rows.turns ?? 0) + 1;
        touched.sessions.add(String(r.session_key));
        break;
      }
      case "runtime_sessions": {
        if (typeof r.profile === "string" && ctx.profiles[r.profile] !== undefined) r.profile = ctx.profiles[r.profile];
        if (insert(db, "runtime_sessions", r, " OR IGNORE").changes > 0) keep({ session_key: r.session_key, id: r.id });
        else {
          db.prepare("UPDATE runtime_sessions SET profile = COALESCE(?, profile) WHERE session_key = ? AND id = ?").run(r.profile as string | null, r.session_key as string, r.id as string);
          ctx.counts.rows.runtime_sessions = (ctx.counts.rows.runtime_sessions ?? 0) + 1;
        }
        break;
      }
      case "closed_cards":
      case "dismissed": {
        const t = thread(r.thread);
        if (t === undefined) break;
        r.thread = t.id;
        r.n = n(t, r.n);
        if (insert(db, table, r, " OR IGNORE").changes > 0) keep(table === "dismissed" ? { viewer: r.viewer, thread: r.thread, n: r.n } : { thread: r.thread, n: r.n });
        else ctx.counts.rows[table] = (ctx.counts.rows[table] ?? 0) + 1;
        break;
      }
      case "reads": {
        const t = thread(r.thread);
        if (t === undefined) break;
        r.thread = t.id;
        r.n = n(t, r.n);
        if (insert(db, "reads", r, " OR IGNORE").changes > 0) keep({ viewer: r.viewer, thread: r.thread });
        else {
          told({ type: "read", viewer: r.viewer, thread: r.thread, n: r.n });
          db.prepare("UPDATE reads SET n = MAX(n, ?) WHERE viewer = ? AND thread = ?").run(r.n as number, r.viewer as string, r.thread as number);
          ctx.counts.rows.reads = (ctx.counts.rows.reads ?? 0) + 1;
        }
        break;
      }
      case "hidden_chats":
      case "muted_chats":
      case "kept_chats": {
        const t = thread(r.thread);
        if (t === undefined) break;
        r.thread = t.id;
        if (insert(db, table, r, " OR IGNORE").changes > 0) keep({ viewer: r.viewer, thread: r.thread });
        else ctx.counts.rows[table] = (ctx.counts.rows[table] ?? 0) + 1;
        break;
      }
      case "pins":
        if (insert(db, "pins", r, " OR IGNORE").changes > 0) keep({ viewer: r.viewer, session: r.session });
        else ctx.counts.rows.pins = (ctx.counts.rows.pins ?? 0) + 1;
        break;
      case "opened_chats": {
        // (its parent named by its station: this one's own is '')
        if (r.parent_station === "") r.parent_station = ctx.from;
        if (insert(db, "opened_chats", r, " OR IGNORE").changes > 0) keep({ child_station: r.child_station, child: r.child });
        else ctx.counts.rows.opened_chats = (ctx.counts.rows.opened_chats ?? 0) + 1;
        break;
      }
      case "deliveries": {
        const t = thread(r.thread);
        if (t === undefined) break;
        r.thread = t.id;
        r.n = n(t, r.n);
        r.delivered_at = null;
        if (insert(db, "deliveries", r, " OR IGNORE").changes > 0) keep({ thread: r.thread, n: r.n, session: r.session });
        else ctx.counts.rows.deliveries = (ctx.counts.rows.deliveries ?? 0) + 1;
        touched.sessions.add(String(r.session));
        break;
      }
    }
  }
}

/// What a hand-over that failed put in, taken out again (inside a transaction of the store's), but the sessions put in
/// anew: those the store deletes as it deletes a session (`deleteSession`), said back. Those there before are as they
/// were.
export function dropImport(db: DatabaseSync, ctx: ImportCtx): string[] {
  const run = (sql: string, ...args: SQLInputValue[]) => db.prepare(sql).run(...args);
  for (const [thread, from, to] of ctx.made.entries) run("DELETE FROM entries WHERE thread = ? AND n BETWEEN ? AND ?", thread, from, to);
  for (const [thread, from, to] of ctx.made.letters) run("DELETE FROM letters WHERE thread = ? AND n BETWEEN ? AND ?", thread, from, to);
  for (const [table, keys] of Object.entries(ctx.made.rows)) {
    for (const key of keys) {
      const cols = Object.keys(key);
      run(`DELETE FROM ${table} WHERE ${cols.map((c) => `${c} = ?`).join(" AND ")}`, ...cols.map((c) => key[c] as SQLInputValue));
    }
  }
  for (const [thread, session] of ctx.made.members) run("DELETE FROM thread_sessions WHERE thread = ? AND session = ?", thread, session);
  for (const s of ctx.made.sessions) {
    if (s.before === null) continue;
    const have = columnsOf(db, "sessions");
    const cols = Object.keys(s.before).filter((c) => have.has(c) && c !== "key");
    run(`UPDATE sessions SET ${cols.map((c) => `${c} = ?`).join(", ")} WHERE key = ?`, ...cols.map((c) => s.before![c] as SQLInputValue), s.key);
  }
  // (a thread put in anew that none of the sessions there before takes part in goes with the sessions put in anew)
  return ctx.made.sessions.filter((s) => s.before === null).map((s) => s.key);
}

/// The threads put in anew left with no session (their sessions taken out): gone, with what is of them.
export function dropEmptyThreads(db: DatabaseSync, ctx: ImportCtx): number[] {
  const gone: number[] = [];
  for (const t of Object.values(ctx.threads)) {
    if (!t.fresh || db.prepare("SELECT 1 FROM thread_sessions WHERE thread = ? LIMIT 1").get(t.id) !== undefined) continue;
    for (const table of ["entries", "letters", "closed_cards", "deliveries"]) db.prepare(`DELETE FROM ${table} WHERE thread = ?`).run(t.id);
    db.prepare("DELETE FROM threads WHERE id = ?").run(t.id);
    gone.push(t.id);
  }
  return gone;
}
