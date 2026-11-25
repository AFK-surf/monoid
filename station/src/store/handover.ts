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
import { FORMER_OWN_NAMES, STILLFAIL_CONNECT, STILLFAIL_SURFACE } from "./rows.ts";

type Json = any;
type Row = Record<string, unknown>;

/// The tables a chat's rows are in, in the order they are put in (what a row names before it).
/// What its agents spent (`usage`, `usage_files`, `session_usage`) last, sent only to a station that says it takes them
/// (`handover.begin`'s `usage`).
export const CHAT_TABLES = ["threads", "sessions", "thread_sessions", "entries", "letters", "turns", "runtime_sessions", "closed_cards", "entry_proposals", "proposal_outcomes", "reads", "hidden_chats", "muted_chats", "kept_chats", "dismissed", "pins", "opened_chats", "deliveries", "usage", "usage_files", "session_usage"] as const;
export type ChatTable = (typeof CHAT_TABLES)[number];
/// Of each thread: its own rows (by its log's number), and each viewer's marks of it.
export const BY_N: readonly ChatTable[] = ["entries", "letters", "closed_cards", "entry_proposals", "proposal_outcomes"];
export const MARKS: readonly ChatTable[] = ["reads", "hidden_chats", "muted_chats", "kept_chats", "dismissed"];
/// What a session's calls are, sent after its other rows: their threads there are known by then.
export const USAGE_TABLES: readonly ChatTable[] = ["usage", "usage_files", "session_usage"];
/// The columns of a call (`usage`) a station sends and puts in: what was spent, never a station's own marks of how it
/// counted it (`compact_counted` and those after it), which the station it goes to sets as it puts each in, its
/// triggers counting it there.
export const USAGE_COLUMNS = ["id", "at", "session", "turn", "thread", "person", "profile", "runtime", "model", "subagent", "fast", "input", "cache_read", "cache_write", "cache_write_long", "output", "calls", "context", "context_window"] as const;
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
    case "entry_proposals":
    case "proposal_outcomes":
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
    case "usage": {
      // (by its session's index, usage_session (session, at), then its id)
      const [at, id] = (after as [number, string] | null) ?? [Number.MIN_SAFE_INTEGER, ""];
      const have = columnsOf(db, "usage");
      const cols = USAGE_COLUMNS.filter((c) => have.has(c)).join(", ");
      return all(`SELECT ${cols} FROM usage INDEXED BY usage_session WHERE session = ? AND (at > ? OR (at = ? AND id > ?)) ORDER BY at, id LIMIT ?`, of as string, at, at, id, limit);
    }
    case "usage_files":
      // (a session's transcripts, by their paths: no index of a session's, the table walked in its paths' order once
      // over a chat's pages)
      return all("SELECT * FROM usage_files WHERE session = ? AND path > ? ORDER BY path LIMIT ?", of as string, (after as string | null) ?? "", limit);
    case "session_usage":
      return all("SELECT * FROM session_usage WHERE session = ?", of as string);
  }
}

/// The key a page goes on after, of its last row.
export function afterOf(table: ChatTable, row: Row): After {
  switch (table) {
    case "entries":
    case "letters":
    case "closed_cards":
    case "entry_proposals":
    case "proposal_outcomes":
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
    case "usage":
      return [row.at, row.id];
    case "usage_files":
      return row.path;
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
export type ThreadThere = {
  id: number;
  fresh: boolean;
  linear: boolean;
  lettersLinear: boolean;
  preLocked?: boolean;
  lastProject?: string | null;
  lastLocked?: number;
  lastTags?: string | null;
  ns: Record<string, number>;
  ls: Record<string, number>;
};

/// What was put in, kept on the station it goes to until it is shown (so that a hand-over that fails takes it out):
/// each session (as it was before: null, put in anew), the entries and letters (by thread, ranges of numbers), the
/// threads put in anew, the memberships, and the other rows by table and their key.
export type Made = {
  sessions: { key: string; before: Row | null }[];
  entries: [number, number, number][];
  letters: [number, number, number][];
  members: [number, string][];
  rows: Record<string, Row[]>;
  /// Rows there before that a row put in replaced (a transcript's place read further, a session's usage newer), as
  /// they were: put back where it fails.
  before?: Record<string, Row[]>;
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

/// A connect as it is here: one the move maps, the station's own chats' as named now.
export function connectHere(connect: string, connects: Record<string, string>): string {
  if (FORMER_OWN_NAMES.includes(connect)) return STILLFAIL_CONNECT;
  return connects[connect] ?? connect;
}

/// A surface naming a connect (`feishu:<id>`, `comma:<id>`, a Slack connect's while its team is not known) as it is here.
export function surfaceHere(surface: string, connects: Record<string, string>): string {
  // (the station's own chats, as a station from before the rename names them)
  if (FORMER_OWN_NAMES.includes(surface)) return STILLFAIL_SURFACE;
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
    else if (table === "entry_proposals" || table === "proposal_outcomes") told({ type: "thread", id: k.thread, entries: [] });
    else if (table === "turns" || table === "runtime_sessions") touched.sessions.add(String(k.session_key ?? ""));
  };
  for (const r0 of rows) {
    const r: Row = { ...r0 };
    switch (table) {
      case "threads": {
        const was = Number(r.id);
        delete r.id;
        const already = ctx.threads[String(was)];
        if (already !== undefined) {
          // Catch-up re-send: preserve `ctx.threads[was]` (id, fresh, linear, lettersLinear, ns, ls, preLocked)!
          // Skip if target was already locked before round 1 (`preLocked`), OR if a target member newly locked/changed
          // classification during handover (`curLocked === 1` and differs from our post-round-1 snapshot).
          if (already.preLocked !== true) {
            const have = columnsOf(db, "threads");
            if (have.has("project") && have.has("project_locked") && have.has("tags")) {
              const cur = db.prepare("SELECT * FROM threads WHERE id = ?").get(already.id) as Row | undefined;
              if (cur !== undefined) {
                const curLocked = Number(cur.project_locked ?? 0) === 1 ? 1 : 0;
                const curProject = cur.project === undefined ? null : (cur.project as string | null);
                const curTags = typeof cur.tags === "string" && cur.tags !== "" ? cur.tags : null;
                const targetLockedDuringMove = curLocked === 1 && (
                  curProject !== (already.lastProject ?? null)
                  || curLocked !== (already.lastLocked ?? 0)
                  || curTags !== (already.lastTags ?? null)
                );
                if (!targetLockedDuringMove) {
                  const inLocked = Number(r.project_locked ?? 0) === 1 ? 1 : 0;
                  const inProject = r.project === undefined ? null : (r.project as string | null);
                  const inTags = typeof r.tags === "string" && r.tags !== "" ? r.tags : null;
                  if (inProject !== curProject || inLocked !== curLocked || inTags !== curTags) {
                    if (!already.fresh) madeBefore(ctx, "threads", "id", cur);
                    db.prepare("UPDATE threads SET project = ?, project_locked = ?, tags = ? WHERE id = ?").run(inProject, inLocked, inTags, already.id);
                  }
                  already.lastProject = inProject;
                  already.lastLocked = inLocked;
                  already.lastTags = inTags;
                }
              }
            }
          }
          touched.threads.add(already.id);
          break;
        }
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
          // Merge classification columns on an existing external thread: `project_locked = 1` wins.
          let preLocked = false;
          let lastProject: string | null = null;
          let lastLocked = 0;
          let lastTags: string | null = null;
          const have = columnsOf(db, "threads");
          if (have.has("project") && have.has("project_locked") && have.has("tags")) {
            const cur = db.prepare("SELECT * FROM threads WHERE id = ?").get(here.id) as Row | undefined;
            if (cur !== undefined) {
              const curLocked = Number(cur.project_locked ?? 0) === 1;
              preLocked = curLocked;
              const inLocked = Number(r.project_locked ?? 0) === 1;
              const inProject = r.project === undefined ? null : (r.project as string | null);
              const curProject = cur.project === undefined ? null : (cur.project as string | null);
              const curTags = typeof cur.tags === "string" && cur.tags !== "" ? cur.tags : null;
              const inTags = typeof r.tags === "string" && r.tags !== "" ? r.tags : null;
              // When either side is locked, take that side's (project, tags) as a whole (including NULL tags!).
              const nextProject = curLocked ? curProject : (inLocked ? inProject : (curProject !== null ? curProject : inProject));
              const nextLocked = curLocked || inLocked ? 1 : 0;
              const nextTags = curLocked ? curTags : (inLocked ? inTags : (curTags ?? inTags));
              if (nextProject !== curProject || nextLocked !== (curLocked ? 1 : 0) || nextTags !== curTags) {
                madeBefore(ctx, "threads", "id", cur);
                db.prepare("UPDATE threads SET project = ?, project_locked = ?, tags = ? WHERE id = ?").run(nextProject, nextLocked, nextTags, here.id);
              }
              lastProject = nextProject;
              lastLocked = nextLocked;
              lastTags = nextTags;
            }
          }
          ctx.threads[String(was)] = { id: here.id, fresh: false, linear: true, lettersLinear: true, preLocked, lastProject, lastLocked, lastTags, ns: {}, ls: {} };
        } else {
          const made = insert(db, "threads", r);
          const lastProject = r.project === undefined ? null : (r.project as string | null);
          const lastLocked = Number(r.project_locked ?? 0) === 1 ? 1 : 0;
          const lastTags = typeof r.tags === "string" && r.tags !== "" ? r.tags : null;
          ctx.threads[String(was)] = { id: made.id, fresh: true, linear: true, lettersLinear: true, preLocked: false, lastProject, lastLocked, lastTags, ns: {}, ls: {} };
        }
        touched.threads.add(ctx.threads[String(was)]!.id);
        break;
      }
      case "sessions": {
        if (typeof r.connect === "string") r.connect = connectHere(r.connect, ctx.connects);
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
        if (typeof r.connect === "string") r.connect = connectHere(r.connect, ctx.connects);
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
        // (an entry's ts is the message's own, one a thread (entries_ts): a thread found there, not put in by this copy,
        // may have the arriving one already at another number of its own (heard there itself, a retirement's leftover's).
        // Looked for by its ts before it is numbered on, as off the linear path; a fresh thread's own log has none and
        // pays nothing for it. Not a letter: two of one ts are two (another machine's clock), kept by number)
        const onward = linear && same === undefined && was === last + 1;
        const there = onward && table === "entries" && !t.fresh && r.ts !== null && r.ts !== undefined
          ? (db.prepare("SELECT n FROM entries WHERE thread = ? AND ts = ?").get(t.id, r.ts as string) as { n: number } | undefined)
          : undefined;
        if (there !== undefined) {
          // (the copy's numbers are not this log's from here: what follows is found as off the linear path)
          t.linear = false;
          map[String(was)] = there.n;
          break;
        }
        if (onward) to = was;
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
      case "entry_proposals":
      case "proposal_outcomes":
      case "dismissed": {
        const t = thread(r.thread);
        if (t === undefined) break;
        r.thread = t.id;
        r.n = n(t, r.n);
        if (insert(db, table, r, " OR IGNORE").changes > 0) keep(table === "dismissed" ? { viewer: r.viewer, thread: r.thread, n: r.n } : { thread: r.thread, n: r.n });
        else {
          if (table === "proposal_outcomes" && Number(r.info_synced ?? 0) === 1 && columnsOf(db, "proposal_outcomes").has("info_synced")) {
            const existing = db.prepare("SELECT * FROM proposal_outcomes WHERE thread = ? AND n = ?").get(r.thread as number, r.n as number) as Row | undefined;
            if (
              existing !== undefined
              && Number(existing.info_synced ?? 0) === 0
              && existing.status === r.status
              && (existing.project ?? null) === (r.project ?? null)
              && (existing.info_note ?? null) === (r.info_note ?? null)
              && (existing.info_refs ?? null) === (r.info_refs ?? null)
              && (existing.resolved_at ?? null) === (r.resolved_at ?? null)
            ) {
              const existingOpId = typeof existing.info_op_id === "string" && existing.info_op_id !== "" ? existing.info_op_id : null;
              const incomingOpId = typeof r.info_op_id === "string" && r.info_op_id !== "" ? r.info_op_id : null;
              // Propagate confirmation only when both rows represent the exact same decision:
              // if either side carries a UUID `info_op_id`, both must match verbatim; legacy opId-less rows match by full metadata.
              const sameDecision = existingOpId !== null || incomingOpId !== null ? existingOpId === incomingOpId : true;
              if (sameDecision) {
                madeBeforeKeys(ctx, "proposal_outcomes", ["thread", "n"], existing);
                db.prepare("UPDATE proposal_outcomes SET info_synced = 1 WHERE thread = ? AND n = ? AND info_synced = 0").run(r.thread as number, r.n as number);
              }
            }
          }
          ctx.counts.rows[table] = (ctx.counts.rows[table] ?? 0) + 1;
        }
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
      case "usage": {
        // (its thread as it is here, none where it is not one of the chat's; its account as it is here)
        if (r.thread !== null && r.thread !== undefined) r.thread = thread(r.thread)?.id ?? null;
        if (typeof r.profile === "string" && ctx.profiles[r.profile] !== undefined) r.profile = ctx.profiles[r.profile];
        // (only what this put in is taken out as it fails: a call here already, of a chat handed back, stays)
        if (putUsage(db, r)) (ctx.made.rows.usage ??= []).push({ id: r.id });
        ctx.counts.rows.usage = (ctx.counts.rows.usage ?? 0) + 1;
        break;
      }
      case "usage_files": {
        r.path = moved(r.path, ctx.fromData, ctx.toData);
        const was = putUsageFile(db, r);
        if (was === null) (ctx.made.rows.usage_files ??= []).push({ path: r.path });
        else if (was !== false) madeBefore(ctx, "usage_files", "path", was);
        ctx.counts.rows.usage_files = (ctx.counts.rows.usage_files ?? 0) + 1;
        break;
      }
      case "session_usage": {
        const was = db.prepare("SELECT * FROM session_usage WHERE session = ?").get(r.session as string) as Row | undefined;
        if (typeof r.session === "string" && typeof r.usage === "string" && was?.usage !== r.usage) {
          db.prepare("INSERT INTO session_usage (session, usage) VALUES (?1, ?2) ON CONFLICT (session) DO UPDATE SET usage = excluded.usage").run(r.session, r.usage);
          if (was === undefined) (ctx.made.rows.session_usage ??= []).push({ session: r.session });
          else madeBefore(ctx, "session_usage", "session", was);
        }
        ctx.counts.rows.session_usage = (ctx.counts.rows.session_usage ?? 0) + 1;
        touched.sessions.add(String(r.session));
        break;
      }
    }
  }
}

/// Row `was` of `table` (by its key `key`) as it was before this hand-over first put one of its key in: kept once, so
/// that what was there before, not what a page of this one put, is put back.
function madeBefore(ctx: ImportCtx, table: string, key: string, was: Row): void {
  madeBeforeKeys(ctx, table, [key], was);
}

function madeBeforeKeys(ctx: ImportCtx, table: string, keys: readonly string[], was: Row): void {
  const ours = (rows: Row[] | undefined) => rows?.some((x) => keys.every((k) => x[k] === was[k])) === true;
  if (ours(ctx.made.rows[table]) || ours(ctx.made.before?.[table])) return;
  ((ctx.made.before ??= {})[table] ??= []).push(was);
}

/// A call put in (`r`, as `USAGE_COLUMNS` say it), where none of its id is here: whether this put it in. Its columns
/// only, so that the marks of how this station counts it are its own defaults and its triggers count it (one that
/// rewrites a plain insert into its own, as usage-compact.ts `usage_compact_legacy_insert` does, says no change of the
/// statement's: so it is looked for after).
export function putUsage(db: DatabaseSync, r: Row): boolean {
  if (typeof r.id !== "string" || typeof r.session !== "string" || typeof r.at !== "number" || typeof r.runtime !== "string") return false;
  if (db.prepare("SELECT 1 FROM usage WHERE id = ?").get(r.id) !== undefined) return false;
  const have = columnsOf(db, "usage");
  const cols = USAGE_COLUMNS.filter((c) => have.has(c) && r[c] !== undefined);
  db.prepare(`INSERT INTO usage (${cols.join(", ")}) SELECT ${cols.map(() => "?").join(", ")} WHERE NOT EXISTS (SELECT 1 FROM usage WHERE id = ?)`)
    .run(...cols.map((c) => r[c] as SQLInputValue), r.id);
  return db.prepare("SELECT 1 FROM usage WHERE id = ?").get(r.id) !== undefined;
}

/// How far a transcript was read (`usage_files`), put in: never back from further than it was read here. Null: put in
/// anew; false: here already as far or further; else the row as it was before.
export function putUsageFile(db: DatabaseSync, r: Row): Row | null | false {
  if (typeof r.path !== "string" || typeof r.offset !== "number") return false;
  const was = db.prepare("SELECT * FROM usage_files WHERE path = ?").get(r.path) as Row | undefined;
  if (was !== undefined && Number(was.offset) >= r.offset) return false;
  if (was === undefined) {
    insert(db, "usage_files", r);
    return null;
  }
  const have = columnsOf(db, "usage_files");
  const cols = Object.keys(r).filter((c) => have.has(c) && c !== "path");
  db.prepare(`UPDATE usage_files SET ${cols.map((c) => `${c} = ?`).join(", ")} WHERE path = ?`).run(...cols.map((c) => r[c] as SQLInputValue), r.path);
  return was;
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
  // (what a row put in replaced, as it was — for threads, preserve any classification/lock a target member changed during handover)
  for (const [table, rows] of Object.entries(ctx.made.before ?? {})) {
    for (const row of rows) {
      const have = columnsOf(db, table);
      if (table === "threads" && have.has("project") && have.has("project_locked") && have.has("tags")) {
        const cur = db.prepare("SELECT * FROM threads WHERE id = ?").get(row.id as SQLInputValue) as Row | undefined;
        const meta = Object.values(ctx.threads).find((t) => t.id === Number(row.id));
        if (cur !== undefined && meta !== undefined) {
          const curProj = cur.project === undefined ? null : (cur.project as string | null);
          const curLocked = Number(cur.project_locked ?? 0) === 1 ? 1 : 0;
          const curTags = typeof cur.tags === "string" && cur.tags !== "" ? cur.tags : null;
          const untouchedLocally = curProj === (meta.lastProject ?? null)
            && curLocked === (meta.lastLocked ?? 0)
            && curTags === (meta.lastTags ?? null);
          if (untouchedLocally) {
            run(
              "UPDATE threads SET project = ?, project_locked = ?, tags = ? WHERE id = ?",
              (row.project ?? null) as SQLInputValue,
              Number(row.project_locked ?? 0),
              (row.tags ?? null) as SQLInputValue,
              row.id as SQLInputValue,
            );
          }
          continue;
        }
      }
      const cols = Object.keys(row).filter((c) => have.has(c));
      run(`INSERT OR REPLACE INTO ${table} (${cols.join(", ")}) VALUES (${cols.map(() => "?").join(", ")})`, ...cols.map((c) => row[c] as SQLInputValue));
    }
  }
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
    for (const table of ["entries", "letters", "closed_cards", "entry_proposals", "proposal_outcomes", "deliveries"]) db.prepare(`DELETE FROM ${table} WHERE thread = ?`).run(t.id);
    db.prepare("DELETE FROM threads WHERE id = ?").run(t.id);
    gone.push(t.id);
  }
  return gone;
}

// ── the calls of chats handed away before their calls went with them (replica/handover.ts `#syncHandedUsage`) ──

/// A chat handed from here (`handed_over`) to `station` with calls kept here, of a session after `after`, at most
/// `limit`, by session: only those with a call or a session's usage (by usage_session, session_usage's key), so a
/// station with none of them looks at nothing more.
export type HandedUsage = { session: string; ws: string | null; thread: number | null; there: number | null };
export function handedWithUsage(db: DatabaseSync, station: string, after: string, limit = 10): HandedUsage[] {
  return db.prepare(`SELECT h.session, h.ws, h.thread, h.there FROM handed_over h WHERE h.session > ? AND h.station = ?
    AND (EXISTS (SELECT 1 FROM usage u INDEXED BY usage_session WHERE u.session = h.session LIMIT 1)
      OR EXISTS (SELECT 1 FROM session_usage su WHERE su.session = h.session LIMIT 1))
    ORDER BY h.session LIMIT ?`).all(after, station, limit) as HandedUsage[];
}

/// The stations chats were handed to from here.
export function handedStations(db: DatabaseSync): string[] {
  return (db.prepare("SELECT DISTINCT station FROM handed_over").all() as { station: string }[]).map((r) => r.station);
}

/// A thread a call names, as the station it goes to finds it: its place (surface, channel, ts), its home, and the
/// connect the session took part in it by.
export type ThreadRef = { id: number; surface: string; channel: string; threadTs: string; home: string | null; connect: string | null };
export function threadRefs(db: DatabaseSync, session: string, ids: readonly number[]): ThreadRef[] {
  const out: ThreadRef[] = [];
  for (const id of new Set(ids)) {
    const t = db.prepare("SELECT id, surface, channel, thread_ts, home FROM threads WHERE id = ?").get(id) as Row | undefined;
    if (t === undefined) continue;
    const m = db.prepare("SELECT connect FROM thread_sessions WHERE thread = ? AND session = ?").get(id, session) as Row | undefined;
    out.push({ id, surface: String(t.surface), channel: String(t.channel), threadTs: String(t.thread_ts), home: (t.home as string | null) ?? null, connect: (m?.connect as string | null) ?? null });
  }
  return out;
}

/// The thread here of `ref` for session `session`: of the same place (its connect's surface as it is here), else one
/// of the session's of the same channel and ts (a surface named otherwise here); null: none.
export function threadOfRef(db: DatabaseSync, session: string, ref: ThreadRef, connects: Record<string, string>): number | null {
  const at = db.prepare("SELECT id FROM threads WHERE surface = ? AND channel = ? AND thread_ts = ?").get(surfaceHere(ref.surface, connects), ref.channel, ref.threadTs) as { id: number } | undefined;
  if (at !== undefined && (ref.surface !== STILLFAIL_SURFACE || db.prepare("SELECT 1 FROM thread_sessions WHERE thread = ? AND session = ?").get(at.id, session) !== undefined)) return at.id;
  const own = db.prepare("SELECT t.id FROM thread_sessions m JOIN threads t ON t.id = m.thread WHERE m.session = ? AND t.channel = ? AND t.thread_ts = ? LIMIT 1").get(session, ref.channel, ref.threadTs) as { id: number } | undefined;
  return own?.id ?? null;
}

/// What a page of a handed chat's calls put in here (`importHandedUsage`).
export type HandedImport = { added: number; files: number };

/// Whether session `session` has a call here (by usage_session).
export function hasUsage(db: DatabaseSync, session: string): boolean {
  return db.prepare("SELECT 1 FROM usage INDEXED BY usage_session WHERE session = ? LIMIT 1").get(session) !== undefined;
}

/// A page of the calls of session `session` (here, and this station's), and of how far its transcripts were read, put
/// in, in a transaction of its own: each call of an id not here (its thread by `threads`, the ids there to here, none
/// where not found; its account by `profiles`), each transcript's place further than here (its path by the data
/// directories). Its usage as kept there is the caller's (replica/handover.ts `#takeUsage`).
export function importHandedUsage(db: DatabaseSync, a: { session: string; threads: Record<string, number | null>; profiles: Record<string, string>; fromData: string; toData: string; usage: Row[]; files: Row[] }): HandedImport {
  const out: HandedImport = { added: 0, files: 0 };
  const run = () => {
    for (const r0 of a.usage) {
      if (r0?.session !== a.session) continue;
      const r: Row = { ...r0 };
      if (r.thread !== null && r.thread !== undefined) r.thread = a.threads[String(r.thread)] ?? null;
      if (typeof r.profile === "string" && a.profiles[r.profile] !== undefined) r.profile = a.profiles[r.profile];
      if (putUsage(db, r)) out.added++;
    }
    for (const f0 of a.files) {
      if (f0?.session !== a.session) continue;
      const f: Row = { ...f0, path: moved(f0.path, a.fromData, a.toData) };
      if (putUsageFile(db, f) !== false) out.files++;
    }
  };
  if (db.isTransaction) {
    run();
    return out;
  }
  db.exec("BEGIN IMMEDIATE");
  try {
    run();
    db.exec("COMMIT");
  } catch (e) {
    db.exec("ROLLBACK");
    throw e;
  }
  return out;
}
