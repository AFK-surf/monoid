// Sessions and threads tables, membership sync, read positions, and turn-diffing helpers (account.ts).
import type { SqlRow, SqlValue } from "../host.ts";
import { equal, isObject } from "../util.ts";
import { type DbEnv, type J, K, OWN_IN, frozen, get, membersOf, num, parse, placesFor, str, u64 } from "./collection.ts";
import { ensureSessionDetail } from "./schema.ts";

export type SessionsThreadsHooks = {
  summaryCame(station: string, key: string, summary: J): void;
  readRows(station: string, thread: number, n: number): void;
  tellLog(table: string, station: string, id: string, put?: number[] | null): void;
  forgetEntries(station: string, thread: number): void;
};

export class SessionsThreadsStore {
  readonly #env: DbEnv;
  readonly #hooks: SessionsThreadsHooks;
  /// Whether `session_detail` is kept apart from `session` so summary updates never rewrite large detail overflow pages.
  #detailTable = false;

  constructor(env: DbEnv, hooks: SessionsThreadsHooks) {
    this.#env = env;
    this.#hooks = hooks;
  }

  openDetail(readOnly: boolean): void {
    const sql = this.#env.sql;
    if (!readOnly) {
      try {
        ensureSessionDetail(sql);
        this.#detailTable = true;
      } catch {
        // No room to make it: fall back to inline `session.detail`.
      }
      return;
    }
    this.#detailTable = sql.all("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'session_detail'").length > 0;
  }

  forgetStation(station: string): void {
    if (this.#detailTable) this.#env.sql.run("DELETE FROM session_detail WHERE station = ?", [station]);
  }

  #readDetailRaw(station: string, key: string): string | null {
    if (this.#detailTable) {
      const r = this.#env.sql.all(
        "SELECT coalesce(s.detail, d.detail) FROM session s LEFT JOIN session_detail d ON d.station = s.station AND d.key = s.key WHERE s.station = ? AND s.key = ?",
        [station, key],
      )[0];
      return r && r[0] !== null ? String(r[0]) : null;
    }
    const r = this.#env.sql.all("SELECT detail FROM session WHERE station = ? AND key = ?", [station, key])[0];
    return r && r[0] !== null ? String(r[0]) : null;
  }

  #writeDetailRaw(station: string, key: string, json: string, clearLegacy = true): void {
    if (this.#detailTable) {
      this.#env.run("INSERT OR REPLACE INTO session_detail (station, key, detail) VALUES (?, ?, ?)", [station, key, json]);
      if (clearLegacy) this.#env.run("UPDATE session SET detail = NULL WHERE station = ? AND key = ? AND detail IS NOT NULL", [station, key]);
      return;
    }
    this.#env.run("UPDATE session SET detail = ? WHERE station = ? AND key = ?", [json, station, key]);
  }

  // ── sessions ──

  #sessionCols(summary: J): SqlValue[] {
    return [num(get(summary, "lastActiveAt")), str(get(summary, "process")), str(get(summary, "connect")), num(get(summary, "archivedAt")), u64(get(summary, "turns"))];
  }

  /// A session's summary.
  summary(station: string, key: string): J {
    const kept = this.#env.cache.get(K("sum", station, key));
    if (kept !== undefined && kept !== null) return kept;
    const r = this.#env.sql.all("SELECT summary FROM session WHERE station = ? AND key = ?", [station, key])[0];
    return r && r[0] !== null ? this.#env.cached(K("sum", station, key), r[0]) : undefined;
  }

  /// A session's summary if its station lists it (it is not archived).
  listedSummary(station: string, key: string): J {
    const r = this.#env.sql.all("SELECT summary FROM session WHERE station = ? AND key = ? AND listed = 1", [station, key])[0];
    return r && r[0] !== null ? this.#env.cached(K("sum", station, key), r[0]) : undefined;
  }

  /// A station's sessions as read: summaries written where they changed, those no longer listed unlisted. `changed`: the
  /// keys of those its station said changed from the ones held (sync.ts #whole), the rest as written: then only those
  /// are compared with what is written, the others' places alone read.
  setSessions(station: string, list: J[], confirmed: number | null, changed?: ReadonlySet<string>): void {
    this.#env.write(() => {
      const was = new Map<string, SqlRow>();
      // Only listed sessions need comparing with the list. Unlisted ones keep their details but cannot be removed from
      // this list, and the details of listed ones are not needed to compare their summaries either.
      const read = changed === undefined ? "SELECT key, ord, summary, listed FROM session WHERE station = ? AND listed = 1" : "SELECT key, ord FROM session WHERE station = ? AND listed = 1";
      for (const r of this.#env.sql.all(read, [station])) was.set(String(r[0]), r);
      const items: [string, J][] = [];
      const seen = new Set<string>();
      for (const s of list) {
        const key = str(get(s, "key"));
        if (key === null || seen.has(key)) continue;
        seen.add(key);
        items.push([key, s]);
      }
      const places = placesFor(items.map(([key]) => (was.has(key) ? (was.get(key)![1] as number) : null)));
      let wrote = false;
      items.forEach(([key, s], i) => {
        const r = was.get(key);
        // (as written, where it stays: none of it to compare)
        if (r && r[1] === places[i] && changed !== undefined && !changed.has(key)) return;
        const json = JSON.stringify(s);
        const summary = changed === undefined ? r?.[2] : r && changed.has(key) ? this.#env.sql.all("SELECT summary FROM session WHERE station = ? AND key = ?", [station, key])[0]?.[0] : undefined;
        if (r && r[1] === places[i] && summary === json) return;
        wrote = true;
        this.#putSummary(station, key, s, json, 1, places[i]);
      });
      for (const [key] of was) {
        if (seen.has(key)) continue;
        wrote = true;
        this.#env.run("UPDATE session SET listed = 0 WHERE station = ? AND key = ?", [station, key]);
        this.#env.loadedList(station, "sessions")?.delete(key);
        this.#env.tell({ topic: "sessions", station });
        this.#tellSession(station, key);
      }
      this.#env.markListed(station, "sessions", confirmed, wrote);
    });
  }

  #putSummary(station: string, key: string, summary: J, json: string, listed: number, ord: number): void {
    const cols = this.#sessionCols(summary);
    // A newly listed session may already be held unlisted. Update the summary in place without replacing its detail.
    this.#env.run(
      `INSERT INTO session (station, key, listed, ord, last_active, process, connect, archived_at, turns, summary)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
       ON CONFLICT (station, key) DO UPDATE SET listed = excluded.listed, ord = excluded.ord,
       last_active = excluded.last_active, process = excluded.process, connect = excluded.connect,
       archived_at = excluded.archived_at, turns = excluded.turns, summary = excluded.summary`,
      [station, key, listed, ord, ...cols, json],
    );
    const kept = frozen(JSON.parse(json));
    this.#env.cache.set(K("sum", station, key), kept);
    const list = this.#env.loadedList(station, "sessions");
    if (listed) list?.set(key, kept, [ord]);
    else list?.delete(key);
    this.#env.tell({ topic: "sessions", station });
    this.#tellSession(station, key);
    this.#hooks.summaryCame(station, key, kept);
  }

  #tellSession(station: string, key: string): void {
    this.#env.cache.delete(K("detail", station, key));
    this.#env.tell({ topic: "session", station, key });
  }

  /// A session's summary as an event has it: in place among the listed (first when new) while it is not archived,
  /// out of the list once it is. Answers whether its detail is to be read again (its turns changed, or none is held).
  putSummary(station: string, summary: J): boolean {
    const key = str(get(summary, "key"));
    if (key === null) return false;
    let again = false;
    this.#env.write(() => {
      const r = this.#env.sql.all("SELECT ord, summary, listed, detail IS NOT NULL FROM session WHERE station = ? AND key = ?", [station, key])[0];
      const shown = (get(summary, "archivedAt") ?? null) === null;
      const listKnown = this.#env.listed(station, "sessions");
      const listed = shown && listKnown ? 1 : r && !shown ? 0 : ((r?.[2] as number | undefined) ?? 0);
      let ord = r ? (r[0] as number) : 0;
      if (listed === 1 && r?.[2] !== 1) ord = ((this.#env.sql.all("SELECT min(ord) FROM session WHERE station = ? AND listed = 1", [station])[0]?.[0] as number | null) ?? 1) - 1;
      const json = JSON.stringify(summary);
      const hasLegacy = r?.[3] === 1;
      const hasTable = this.#detailTable && this.#env.sql.all("SELECT 1 FROM session_detail WHERE station = ? AND key = ?", [station, key]).length > 0;
      const hasDetail = hasTable || hasLegacy;
      if (!hasDetail) {
        again = true;
      } else if (counted(summary)) {
        // Counted summaries already carry turns/workMs, so the large detail JSON never needs to be read or parsed.
        again = false;
      } else {
        const raw = this.#readDetailRaw(station, key);
        const detail = raw !== null ? parse(raw) : undefined;
        again = detail === undefined || !sameTurns(get(detail, "turns"), summary);
        // One more turn, or the last one gone on, as the summary says it: put in place, not all its turns read again.
        const placed = again && detail !== undefined && placeTurn(detail, summary);
        if (placed) {
          again = false;
          this.#writeDetailRaw(station, key, JSON.stringify(detail), hasLegacy);
          this.#tellSession(station, key);
        }
      }
      if (r && r[1] === json && r[2] === listed) return;
      // Move any legacy inline detail out of the session row once so this and future summary updates stay small.
      if (hasLegacy && this.#detailTable) {
        this.#env.run("INSERT OR REPLACE INTO session_detail (station, key, detail) SELECT station, key, detail FROM session WHERE station = ? AND key = ? AND detail IS NOT NULL", [station, key]);
        this.#env.run("UPDATE session SET detail = NULL WHERE station = ? AND key = ? AND detail IS NOT NULL", [station, key]);
      }
      // Its detail shows it as it is now too (`detail`).
      this.#putSummary(station, key, summary, json, listed, ord);
    });
    return again;
  }

  /// A session gone from its station: its summary, detail, transcript and membership of threads; threads it alone took
  /// part in go too.
  dropSession(station: string, key: string): void {
    this.#env.write(() => {
      const r = this.#env.sql.all("SELECT listed FROM session WHERE station = ? AND key = ?", [station, key])[0];
      if (this.#detailTable) this.#env.run("DELETE FROM session_detail WHERE station = ? AND key = ?", [station, key]);
      if (r) {
        this.#env.run("DELETE FROM session WHERE station = ? AND key = ?", [station, key]);
        this.#env.cache.delete(K("sum", station, key));
        this.#env.loadedList(station, "sessions")?.delete(key);
        this.#env.tell({ topic: "sessions", station });
        this.#tellSession(station, key);
      }
      for (const t of this.#env.sql.all("SELECT thread FROM thread_member WHERE station = ? AND session = ?", [station, key])) {
        const id = t[0] as number;
        const row = this.thread(station, id);
        if (!row) continue;
        const sessions = (Array.isArray(row.sessions) ? row.sessions : []).filter((m: J) => get(m, "session") !== key);
        if (sessions.length === 0) this.#deleteThread(station, id);
        else this.#putThreadRow(station, { ...row, sessions }, null);
      }
      this.#env.run("DELETE FROM thread_member WHERE station = ? AND session = ?", [station, key]);
      if (this.#env.run("DELETE FROM transcript WHERE station = ? AND session = ?", [station, key]) > 0) this.#hooks.tellLog("transcript", station, key);
    });
  }

  /// A session's detail as a topic shows it: its turns and jobs as read, its summary as the station last said it (in its
  /// list or an event: one summary, so a field a station says since is in both; read with the detail alone, the detail's),
  /// and its threads as their rows are now: those it read as its own and those whose members it is among.
  detail(station: string, key: string): J {
    const ck = K("detail", station, key);
    const hit = this.#env.cache.get(ck);
    if (hit !== undefined) return hit ?? undefined;
    const raw = this.#readDetailRaw(station, key);
    if (raw === null) {
      this.#env.cache.set(ck, null);
      return undefined;
    }
    const detail = parse(raw);
    const sum = this.#env.sql.all("SELECT summary FROM session WHERE station = ? AND key = ?", [station, key])[0]?.[0];
    if (sum !== undefined && sum !== null) detail.session = parse(sum);
    detail.threads = this.#detailThreads(station, key, Array.isArray(detail.threadIds) ? detail.threadIds : []);
    delete detail.threadIds;
    const v = frozen(detail);
    this.#env.cache.set(ck, v);
    return v;
  }

  /// Whether a session's detail is held.
  hasDetail(station: string, key: string): boolean {
    if (this.#detailTable) {
      return this.#env.sql.all(
        "SELECT 1 FROM session s LEFT JOIN session_detail d ON d.station = s.station AND d.key = s.key WHERE s.station = ? AND s.key = ? AND (s.detail IS NOT NULL OR d.detail IS NOT NULL)",
        [station, key],
      ).length > 0;
    }
    return this.#env.sql.all("SELECT 1 FROM session WHERE station = ? AND key = ? AND detail IS NOT NULL", [station, key]).length > 0;
  }

  #detailThreads(station: string, key: string, ids: number[]): J[] {
    const where = `station = ? AND (id IN (SELECT thread FROM thread_member WHERE station = ? AND session = ?)${ids.length > 0 ? ` OR id IN (${ids.map(() => "?").join(", ")})` : ""}) ORDER BY sort_at DESC, created_at DESC, id DESC`;
    const found = this.#env.sql.all(`SELECT id FROM thread WHERE ${where}`, [station, station, key, ...ids]);
    const made = this.threadsFound(station, found, () => this.#env.sql.all(`SELECT id, json, last, read, unread FROM thread WHERE ${where}`, [station, station, key, ...ids]));
    return made.filter((t) => t !== undefined);
  }

  /// A session's detail as read (GET /sessions/:key): its threads into their rows (the ids it named kept), the rest
  /// kept as it came.
  setDetail(station: string, key: string, answer: J): void {
    this.#env.write(() => {
      const rest: J = { ...answer };
      const threads = Array.isArray(rest.threads) ? rest.threads : [];
      delete rest.threads;
      rest.threadIds = threads.flatMap((t: J) => (u64(get(t, "id")) === null ? [] : [t.id]));
      const json = JSON.stringify(rest);
      const r = this.#env.sql.all("SELECT detail IS NOT NULL FROM session WHERE station = ? AND key = ?", [station, key])[0];
      if (!r) this.#env.run("INSERT INTO session (station, key, listed, ord) VALUES (?, ?, 0, 0)", [station, key]);
      const prev = this.#readDetailRaw(station, key);
      const changed = prev !== json;
      if (changed || (r?.[0] === 1 && this.#detailTable)) this.#writeDetailRaw(station, key, json, r?.[0] === 1);
      for (const view of threads) this.#upsertThread(station, view, false);
      if (changed) this.#tellSession(station, key);
    });
  }

  /// A thread a session is no longer in: out of the ids its detail named.
  #leftThread(station: string, key: string, id: number): void {
    const raw = this.#readDetailRaw(station, key);
    if (raw === null) return;
    const detail = parse(raw);
    if (!Array.isArray(detail.threadIds) || !detail.threadIds.includes(id)) return;
    detail.threadIds = detail.threadIds.filter((t: number) => t !== id);
    this.#writeDetailRaw(station, key, JSON.stringify(detail));
  }

  /// Changes a session's detail in place (a job's event); nothing while none is held.
  patchDetail(station: string, key: string, change: (detail: J) => void): void {
    this.#env.write(() => {
      const raw = this.#readDetailRaw(station, key);
      if (raw === null) return;
      const detail = parse(raw);
      change(detail);
      const json = JSON.stringify(detail);
      if (json === raw) return;
      this.#writeDetailRaw(station, key, json);
      this.#tellSession(station, key);
    });
  }

  /// The listed session keys, in order, so a sweep can inspect their details in bounded groups.
  sessionKeys(station: string): string[] {
    return this.#env.sql.all("SELECT key FROM session WHERE station = ? AND listed = 1 ORDER BY ord", [station]).map((r) => String(r[0]));
  }

  /// A station's sessions with whether each one's detail is to be read again (none held, or its turns changed).
  /// Only the last turn matters; earlier turns and the rest of each detail stay in the database.
  sessionsToRead(station: string, keys?: readonly string[]): [string, boolean][] {
    if (keys?.length === 0) return [];
    const only = keys === undefined ? "" : ` AND s.key IN (${keys.map(() => "?").join(", ")})`;
    const join = this.#detailTable ? " LEFT JOIN session_detail d ON d.station = s.station AND d.key = s.key" : "";
    const detailExpr = this.#detailTable ? "coalesce(s.detail, d.detail)" : "s.detail";
    return this.#env.sql.all(
      `SELECT s.key, s.summary, ${detailExpr} IS NOT NULL,
         CASE WHEN json_type(${detailExpr}, '$.turns') = 'array' THEN json_array_length(${detailExpr}, '$.turns') ELSE 0 END,
         CASE WHEN json_type(${detailExpr}, '$.turns') = 'array' AND json_array_length(${detailExpr}, '$.turns') > 0
              THEN json_quote(json_extract(${detailExpr}, '$.turns[#-1]')) END
       FROM session s${join} WHERE s.station = ? AND s.listed = 1${only} ORDER BY s.ord`,
      [station, ...(keys ?? [])],
    ).map((r) => {
      const summary = parse(r[1]);
      return [String(r[0]), r[2] !== 1 || (!counted(summary) && !sameTurnEnd(Number(r[3]), r[4] === null ? null : parse(r[4]), summary))];
    });
  }

  // ── threads ──

  /// `fromDb` false: `json` as written here, not read.
  #threadRow(station: string, id: number, json: SqlValue, last: SqlValue, read: SqlValue, unread: SqlValue, fromDb = true): J {
    return this.#env.cached(K("thread", station, id), json, (t) => {
      if (last !== null) t.last = last;
      if (read !== null) t.read = read;
      if (unread !== null) t.unread = unread;
      return t;
    }, fromDb);
  }

  /// A station's thread rows a query found (`found`: their ids first), in its order (account.ts #byKey); `all` the
  /// query again with their JSON (id, json, last, read, unread). A thread's `last`, `read` and `unread`, columns only,
  /// are in its row as kept: a change of them lets the row go (#threadChanged).
  threadsFound(station: string, found: SqlRow[], all: () => SqlRow[]): (J | undefined)[] {
    const key = (r: SqlRow) => K("thread", station, r[0] as number);
    return this.#env.byKey(
      found.map((r) => [key(r), r[0]]),
      all,
      (keys) => this.#env.sql.all("SELECT t.id, t.json, t.last, t.read, t.unread FROM json_each(?) AS k CROSS JOIN thread AS t WHERE t.station = ? AND t.id = k.value", [keys, station]),
      key,
      (r) => this.#threadRow(station, r[0] as number, r[1], r[2], r[3], r[4]),
    );
  }

  /// A thread's summary, listed or not.
  thread(station: string, id: number): J {
    const hit = this.#env.cache.get(K("thread", station, id));
    if (hit) return hit;
    const r = this.#env.sql.all("SELECT json, last, read, unread FROM thread WHERE station = ? AND id = ?", [station, id])[0];
    return r ? this.#threadRow(station, id, r[0], r[1], r[2], r[3]) : undefined;
  }

  /// A thread's summary if its station lists it.
  listedThread(station: string, id: number): J {
    const r = this.#env.sql.all("SELECT json, last, read, unread FROM thread WHERE station = ? AND id = ? AND listed = 1", [station, id])[0];
    return r ? this.#threadRow(station, id, r[0], r[1], r[2], r[3]) : undefined;
  }

  /// The station's chat bound to an agent: the still.fail thread it started.
  threadOf(station: string, session: string): number | null {
    const r = this.#env.sql.all(`SELECT id FROM thread WHERE station = ? AND listed = 1 AND first_member = ? AND surface IN (${OWN_IN}) ORDER BY sort_at DESC, created_at DESC, id DESC LIMIT 1`, [station, session])[0];
    return r ? (r[0] as number) : null;
  }

  /// A station's listed threads' ids.
  threadIds(station: string): number[] {
    return this.#env.sql.all("SELECT id FROM thread WHERE station = ? AND listed = 1 ORDER BY sort_at DESC, created_at DESC, id DESC", [station]).map((r) => r[0] as number);
  }

  /// A station's listed threads whose summary goes further than the entries held of them (none held, or fewer at the
  /// end): what the device has yet to bring of each one's latest.
  threadsBehind(station: string): number[] {
    return this.#env.sql.all("SELECT id FROM thread WHERE station = ? AND listed = 1 AND last > COALESCE((SELECT max(n) FROM entry WHERE entry.station = thread.station AND entry.thread = thread.id), 0)", [station]).map((r) => r[0] as number);
  }

  /// How far a thread goes as its summary says (0 when none is held).
  threadLast(station: string, id: number): number {
    const v = this.#env.sql.all("SELECT last FROM thread WHERE station = ? AND id = ?", [station, id])[0]?.[0];
    return typeof v === "number" ? v : 0;
  }

  #threadCols(view: J): { json: string; last: number | null; read: number | null; unread: number | null; sortAt: number; createdAt: number; surface: string | null; first: string | null } {
    const rest = { ...view };
    delete rest.last;
    delete rest.read;
    delete rest.unread;
    return {
      json: JSON.stringify(rest),
      last: u64(view.last),
      read: u64(view.read),
      unread: u64(view.unread),
      sortAt: num(get(view.lastMessage, "createdAt")) ?? 0,
      createdAt: num(view.createdAt) ?? 0,
      surface: str(view.surface),
      first: membersOf(view)[0] ?? null,
    };
  }

  /// Writes a thread's row (`listed` null: as it was), its membership and what shows it.
  #putThreadRow(station: string, view: J, listed: number | null): void {
    const id = u64(view.id)!;
    const c = this.#threadCols(view);
    const r = this.#env.sql.all("SELECT listed, json, last, read, unread FROM thread WHERE station = ? AND id = ?", [station, id])[0];
    const isListed = listed ?? ((r?.[0] as number | undefined) ?? 0);
    if (r && r[0] === isListed && r[1] === c.json && r[2] === c.last && r[3] === c.read && r[4] === c.unread) return;
    const before = r ? this.thread(station, id) : undefined;
    this.#env.run(
      "INSERT OR REPLACE INTO thread (station, id, listed, last, read, unread, sort_at, created_at, surface, first_member, json) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
      [station, id, isListed, c.last, c.read, c.unread, c.sortAt, c.createdAt, c.surface, c.first, c.json],
    );
    this.#env.cache.delete(K("thread", station, id));
    const row = this.#threadRow(station, id, c.json, c.last, c.read, c.unread, false);
    const members = membersOf(view);
    const was = before ? membersOf(before) : [];
    if (members.join("\u0001") !== was.join("\u0001")) {
      this.#env.run("DELETE FROM thread_member WHERE station = ? AND thread = ?", [station, id]);
      for (const m of new Set(members)) this.#env.run("INSERT OR IGNORE INTO thread_member (station, session, thread) VALUES (?, ?, ?)", [station, m, id]);
      for (const m of was) if (!members.includes(m)) this.#leftThread(station, m, id);
    }
    const list = this.#env.loadedList(station, "threads");
    if (isListed) list?.set(String(id), row, [c.sortAt, c.createdAt, id]);
    else list?.delete(String(id));
    if (isListed || r?.[0] === 1) this.#env.tell({ topic: "threads", station });
    for (const m of new Set([...members, ...was])) this.#tellSession(station, m);
    this.#env.tell({ topic: "thread", station, thread: id });
  }

  #upsertThread(station: string, view: J, list: boolean): void {
    if (u64(get(view, "id")) === null) return;
    this.#putThreadRow(station, view, list ? 1 : null);
  }

  #deleteThread(station: string, id: number): void {
    const before = this.thread(station, id);
    const r = this.#env.sql.all("SELECT listed FROM thread WHERE station = ? AND id = ?", [station, id])[0];
    if (!r) return;
    this.#env.run("DELETE FROM thread WHERE station = ? AND id = ?", [station, id]);
    this.#env.run("DELETE FROM thread_member WHERE station = ? AND thread = ?", [station, id]);
    this.#env.cache.delete(K("thread", station, id));
    this.#env.loadedList(station, "threads")?.delete(String(id));
    if (r[0] === 1) this.#env.tell({ topic: "threads", station });
    for (const m of new Set(membersOf(before))) this.#tellSession(station, m);
    this.#env.tell({ topic: "thread", station, thread: id });
  }

  /// A station's threads as read. `changed`: the ids of those its station said changed from the ones held (sync.ts
  /// #whole), the rest as written: only those are compared with what is written.
  setThreads(station: string, list: J[], confirmed: number | null, changed?: ReadonlySet<string>): void {
    this.#env.write(() => {
      const seen = new Set<number>();
      for (const view of list) {
        const id = u64(get(view, "id"));
        if (id === null || seen.has(id)) continue;
        seen.add(id);
        if (changed === undefined || changed.has(String(id))) this.#putThreadRow(station, view, 1);
      }
      let wrote = false;
      for (const r of this.#env.sql.all("SELECT id FROM thread WHERE station = ? AND listed = 1", [station])) {
        const id = r[0] as number;
        if (seen.has(id)) continue;
        wrote = true;
        const before = this.thread(station, id);
        this.#env.run("UPDATE thread SET listed = 0 WHERE station = ? AND id = ?", [station, id]);
        this.#env.loadedList(station, "threads")?.delete(String(id));
        this.#env.tell({ topic: "threads", station });
        this.#env.tell({ topic: "thread", station, thread: id });
        for (const member of membersOf(before)) this.#tellSession(station, member);
      }
      this.#env.markListed(station, "threads", confirmed, wrote);
    });
  }

  /// A thread's summary into the station's threads (listed from now on) and the sessions taking part.
  putThread(station: string, view: J): void {
    this.#env.write(() => this.#upsertThread(station, view, this.#env.listed(station, "threads")));
  }

  /// A thread gone: its row and its entries.
  dropThread(station: string, id: number): void {
    this.#env.write(() => {
      this.#deleteThread(station, id);
      this.#hooks.forgetEntries(station, id);
    });
  }

  /// A thread goes at least to `n` (an event, a message sent).
  raiseLast(station: string, id: number, n: number): void {
    this.#env.write(() => {
      const r = this.#env.sql.all("SELECT last FROM thread WHERE station = ? AND id = ?", [station, id])[0];
      if (!r || (typeof r[0] === "number" && r[0] >= n)) return;
      this.#env.run("UPDATE thread SET last = ? WHERE station = ? AND id = ?", [n, station, id]);
      this.#threadChanged(station, id);
    });
  }

  #threadChanged(station: string, id: number): void {
    this.#env.cache.delete(K("thread", station, id));
    const row = this.thread(station, id);
    if (!row) return;
    const r = this.#env.sql.all("SELECT listed, sort_at, created_at FROM thread WHERE station = ? AND id = ?", [station, id])[0];
    if (r?.[0] === 1) {
      this.#env.loadedList(station, "threads")?.set(String(id), row, [r[1] as number, r[2] as number, id]);
      this.#env.tell({ topic: "threads", station });
    }
    for (const m of new Set(membersOf(row))) this.#tellSession(station, m);
    this.#env.tell({ topic: "thread", station, thread: id });
  }

  /// The viewer read a thread up to `n`: its position moves there, nothing unread once that covers its last entry.
  /// Answers whether the count of what is unread is to be read again.
  setRead(station: string, id: number, n: number): boolean {
    let stale = false;
    this.#env.write(() => {
      const r = this.#env.sql.all("SELECT read, last FROM thread WHERE station = ? AND id = ?", [station, id])[0];
      if (r && !(typeof r[0] === "number" && r[0] >= n)) {
        const last = r[1];
        if (last === null || n >= (last as number)) this.#env.run("UPDATE thread SET read = ?, unread = 0 WHERE station = ? AND id = ?", [n, station, id]);
        else {
          this.#env.run("UPDATE thread SET read = ? WHERE station = ? AND id = ?", [n, station, id]);
          stale = true;
        }
        this.#threadChanged(station, id);
      }
      this.#hooks.readRows(station, id, n);
    });
    return stale;
  }

  /// How far the viewer has read a thread, as its summary says.
  readPosition(station: string, id: number): number | null {
    const v = this.#env.sql.all("SELECT read FROM thread WHERE station = ? AND id = ?", [station, id])[0]?.[0];
    return typeof v === "number" ? v : null;
  }

  /// The sessions of a chat (a thread), in order: by its key alone.
  threadSessions(station: string, thread: number): string[] {
    return this.#env.sql.all("SELECT session FROM thread_member WHERE station = ? AND thread = ? ORDER BY session", [station, thread]).map((r) => r[0] as string);
  }
}

/// A session detail's turns brought to what its summary says, where that is one more turn or the last one gone on (the
/// summary's last turn, with its id); whether they were. A station from before names no last turn: they are read again.
export function placeTurn(detail: J, summary: unknown): boolean {
  const list = Array.isArray(detail?.turns) ? (detail.turns as unknown[]) : null;
  const last = get(summary, "lastTurn");
  const n = get(summary, "turns");
  if (list === null || !isObject(last) || typeof last.id !== "string" || typeof n !== "number") return false;
  if (n === list.length + 1 && !list.some((t) => get(t, "id") === last.id)) list.push(last);
  else if (n === list.length && list.length > 0 && get(list[list.length - 1], "id") === last.id) list[list.length - 1] = last;
  else return false;
  return true;
}

/// Whether a session's summary says what is shown of its turns (how many, how long they ran: `turns`, `workMs`, none for
/// one with turns from before that was kept, which shows how many alone), so
/// that its detail, read once, needs no reading again as they start and end: a detail listed every turn for that, read
/// again after each one, many of one session in 25 s on a station (2026-11-03). A station from before says none.
export function counted(summary: unknown): boolean {
  if (!isObject(summary) || !("workMs" in summary)) return false;
  return (typeof summary.workMs === "number" || summary.workMs === null) && typeof summary.turns === "number";
}

/// Whether the turns a session detail lists still end as its summary says.
export function sameTurns(turns: unknown, summary: unknown): boolean {
  const list = Array.isArray(turns) ? turns : [];
  return sameTurnEnd(list.length, list.length > 0 ? list[list.length - 1] : null, summary);
}

function sameTurnEnd(length: number, record: unknown, summary: unknown): boolean {
  if (get(summary, "turns") !== length) return false;
  const lastTurn = get(summary, "lastTurn") ?? null;
  if (record === null && lastTurn === null) return true;
  if (record === null || lastTurn === null) return false;
  return ["kind", "outcome", "declared", "detail", "startedAt", "endedAt"].every((k) => equal(get(record, k), get(lastTurn, k)));
}
