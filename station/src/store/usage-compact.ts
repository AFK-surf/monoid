// A session's context as its last calls left it, kept bounded beside its totals (usage_totals.compact_context, the
// totals row usage_minute_scope points to): the last five main-thread calls and whether the last two turns compacted,
// so that what a session's context holds is read in a row, not out of its calls (store/usage.ts `lastContexts`,
// store.ts `recentlyCompacted`, `savedContext`). Its writers (`noteCompactContexts`, the MoonBit usage counter's
// mb/src/usagecount/record.mbt) mark each call they recorded so (usage.compact_counted = 1); one any other writer made
// (a station from before) or changed leaves the context uncertain until five calls after it rebuild it.
//
// What the agents spent is added up by quarter hour apart (store/usage-15m.ts); the minute statistics this file kept
// before (usage_compact*, usage_summary_changes) are dropped with the rest of the old statistics (usage-retire.ts).
import type { DatabaseSync } from "node:sqlite";
import { COMPACTED_FROM } from "./rows.ts";
import type { ContextCall, UsageCall, UsageFor } from "./usage.ts";

const invalidateContext = (session: string, when = "1") => `
  UPDATE usage_totals SET compact_context = NULL WHERE session = ${session} AND (${when})
    AND (runtime, model, fast) = (SELECT context_runtime, context_model, context_fast FROM usage_minute_scope WHERE session = ${session})
    AND compact_context IS NOT NULL;
  UPDATE usage_minute_scope SET context_runtime = NULL, context_model = NULL, context_fast = NULL, context_uncertain = 1,
    context_after = (SELECT at FROM usage INDEXED BY usage_session WHERE session = ${session} ORDER BY at DESC LIMIT 1)
    WHERE session = ${session} AND (${when});`;
const contextColumns = ["id", "at", "session", "turn", "profile", "runtime", "model", "subagent", "fast", "context", "context_window", "cache_write", "cache_write_long"];
const contextChanged = contextColumns.map((c) => `OLD.${c} IS NOT NEW.${c}`).join(" OR ");
/// The triggers that leave a context uncertain where a call of its session changed under it.
const CONTEXT_KEPT = `
-- A call another writer recorded (one that does not keep the context) may be the session's latest.
CREATE TRIGGER usage_context_old_add AFTER INSERT ON usage WHEN NEW.compact_counted = 0 AND NEW.subagent = 0 BEGIN
  INSERT INTO usage_minute_scope (session, ws, done) SELECT NEW.session, (SELECT ws FROM sessions WHERE key = NEW.session), 1
    WHERE NOT EXISTS (SELECT 1 FROM usage_minute_scope WHERE session = NEW.session);
  ${invalidateContext("NEW.session")}
END;
-- An insert that meets a main call already there (an INSERT OR REPLACE, an upsert) may change it without a DELETE or
-- UPDATE trigger: the context cannot tell, so it is left uncertain. The station's writers update a call in place.
CREATE TRIGGER usage_context_meet BEFORE INSERT ON usage WHEN EXISTS (SELECT 1 FROM usage WHERE id = NEW.id AND subagent = 0) BEGIN
  ${invalidateContext("NEW.session")}
  ${invalidateContext("(SELECT session FROM usage WHERE id = NEW.id)")}
END;
-- A bounded tail cannot reconstruct a removed or edited main call. Stop presenting the old context as current; later
-- main calls build a new tail without reading the history.
CREATE TRIGGER usage_context_drop AFTER DELETE ON usage WHEN OLD.subagent = 0 BEGIN
  ${invalidateContext("OLD.session")}
END;
CREATE TRIGGER usage_context_change AFTER UPDATE OF ${contextColumns.join(", ")} ON usage
  WHEN (OLD.subagent = 0 OR NEW.subagent = 0) AND (${contextChanged}) BEGIN
  ${invalidateContext("OLD.session")}
  ${invalidateContext("NEW.session")}
END;`;

/// Whether the contexts are kept: installed by this station (usage_contexts), or by one from before as part of its
/// minute statistics (usage_compact_since), whose triggers keep them until `installCompactUsage` takes them over.
export function hasCompactUsage(db: DatabaseSync): boolean {
  if (compactInstalled.has(db)) return true;
  const installed = db.prepare("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name IN ('usage_contexts', 'usage_compact_since') LIMIT 1").get() !== undefined;
  // Once there, known for that connection and not asked again at each usage record: the schema migrates forward only,
  // and nothing drops it before it is taken over. Not there is asked again: another connection (the process before, at
  // a handover) may make it.
  if (installed) compactInstalled.add(db);
  return installed;
}
const compactInstalled = new WeakSet<DatabaseSync>();

// Existing databases can have the older positional totals INSERT. Adding a column without changing that trigger
// would make the next call fail. Keep the old totals logic, but name its columns and retain a row that owns context.
function adaptTotalsWriters(db: DatabaseSync): void {
  for (const name of ["usage_totals_add", "usage_totals_source_aggregate_add", "usage_totals_source_aggregate_change", "usage_totals_source_aggregate_drop"]) {
    const row = db.prepare("SELECT sql FROM sqlite_master WHERE type = 'trigger' AND name = ?").get(name) as { sql: string } | undefined;
    if (!row) continue;
    let sql = row.sql;
    if (name.endsWith("_add")) {
      sql = sql.replace(/INSERT\s+INTO\s+usage_totals\s+VALUES\s*\(/i,
        "INSERT INTO usage_totals (session, runtime, model, fast, calls, input, cache_read, cache_write, cache_write_long, output) VALUES (");
      if (!/INSERT\s+INTO\s+usage_totals\s*\(/i.test(sql)) throw new Error(`cannot adapt ${name}`);
    } else {
      const deletion = /DELETE\s+FROM\s+usage_totals\b[^;]*;/i;
      const match = sql.match(deletion);
      if (!match) throw new Error(`cannot adapt ${name}`);
      if (!/\bcompact_context\b/i.test(match[0])) sql = sql.replace(deletion, (statement) => `${statement.slice(0, -1)} AND compact_context IS NULL;`);
    }
    if (sql !== row.sql) db.exec(`DROP TRIGGER "${name}"; ${sql}`);
  }
}

/// The contexts kept from now on, once the station before has gone (usage/module.ts): no old call read. The triggers
/// of the minute statistics that kept them before, and of the main-call index they replace, go in the same write.
export function installCompactUsage(db: DatabaseSync): void {
  const has = (name: string) => db.prepare("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?").get(name) !== undefined;
  if (has("usage_contexts")) { compactInstalled.add(db); return; }
  db.exec("BEGIN IMMEDIATE");
  try {
    if (!has("usage_contexts")) {
      const columns = (table: string) => new Set((db.prepare(`PRAGMA table_info(${table})`).all() as { name: string }[]).map((c) => c.name));
      if (!columns("usage").has("compact_counted")) db.exec("ALTER TABLE usage ADD COLUMN compact_counted INTEGER NOT NULL DEFAULT 0");
      if (!columns("usage_totals").has("compact_context")) db.exec("ALTER TABLE usage_totals ADD COLUMN compact_context TEXT");
      db.exec(`CREATE TABLE IF NOT EXISTS usage_minute_scope (session TEXT PRIMARY KEY, ws TEXT, done INTEGER NOT NULL) WITHOUT ROWID;
        CREATE INDEX IF NOT EXISTS usage_minute_scope_ws ON usage_minute_scope (ws, done, session);`);
      const scope = columns("usage_minute_scope");
      for (const [column, type] of [["context_runtime", "TEXT"], ["context_model", "TEXT"], ["context_fast", "INTEGER"],
        ["context_uncertain", "INTEGER NOT NULL DEFAULT 0"], ["context_after", "INTEGER"]] as const) {
        if (!scope.has(column)) db.exec(`ALTER TABLE usage_minute_scope ADD COLUMN ${column} ${type}`);
      }
      const triggers = db.prepare(`SELECT name FROM sqlite_master WHERE type = 'trigger' AND
        (name LIKE 'usage_main_calls_%' OR name = 'usage_compactions_add' OR name IN ('usage_compact_legacy_insert',
          'usage_compact_no_replace', 'usage_compact_context_drop', 'usage_compact_context_old_add', 'usage_compact_context_change'))`).all() as { name: string }[];
      for (const { name } of triggers) db.exec(`DROP TRIGGER "${name.replaceAll('"', '""')}"`);
      db.exec(CONTEXT_KEPT);
      adaptTotalsWriters(db);
      db.exec("CREATE TABLE usage_contexts (id INTEGER PRIMARY KEY CHECK (id = 1)); INSERT INTO usage_contexts VALUES (1);");
    }
    db.exec("COMMIT");
    compactInstalled.add(db);
  } catch (error) { db.exec("ROLLBACK"); throw error; }
}

type RecentCall = ContextCall & { id: string };
type SavedContext = { runtimeSession: string; model: string | null; contextWindow: number | null; lastCallAt: number;
  contextTokens?: number; cacheMs?: number; rereadCost?: number };
type Recent = { calls: RecentCall[]; turns: { id: string | null; compacted: boolean }[]; uncertain: boolean; saved?: SavedContext };
type ContextOwner = { runtime: string; model: string; fast: number };
/// `owner`: which totals row holds it now (none: none does).
export type ContextSnapshot = { state: Recent; stored: boolean; invalid: boolean; after: number | null; owner: ContextOwner | null };

function contextOwner(db: DatabaseSync, session: string): ContextOwner | undefined {
  return db.prepare(`SELECT context_runtime AS runtime, context_model AS model, context_fast AS fast
    FROM usage_minute_scope WHERE session = ? AND context_runtime IS NOT NULL`).get(session) as ContextOwner | undefined;
}

function contextSnapshot(db: DatabaseSync, session: string): ContextSnapshot {
  const row = db.prepare(`SELECT t.compact_context AS state, sc.context_uncertain AS invalid, sc.context_after AS after,
      sc.context_runtime AS runtime, sc.context_model AS model, sc.context_fast AS fast
    FROM usage_minute_scope sc LEFT JOIN usage_totals t ON t.session = sc.session AND t.runtime = sc.context_runtime
      AND t.model = sc.context_model AND t.fast = sc.context_fast WHERE sc.session = ?`).get(session) as
    { state: string | null; invalid: number; after: number | null; runtime: string | null; model: string; fast: number } | undefined;
  const invalid = row?.invalid === 1;
  return { state: row?.state == null ? { calls: [], turns: [], uncertain: invalid } : JSON.parse(row.state) as Recent,
    stored: row?.state != null, invalid, after: row?.after ?? null,
    owner: row == null || row.runtime == null ? null : { runtime: row.runtime, model: row.model, fast: row.fast } };
}

// After an edit, there may be a later main call among the old rows. The session/time index gives an upper bound on
// those rows; once five new calls are later than it, they form a complete tail without walking that history.
function reliableTail(snapshot: ContextSnapshot): boolean {
  return !snapshot.invalid || snapshot.after === null
    || (snapshot.state.calls.length >= 5 && snapshot.state.calls[0]!.at > snapshot.after);
}

// Put context on the same totals row that this call already changed. The pointer changes only when the model,
// runtime or speed changes, so recording the next call does not dirty a separate context page.
/// `previous`: the owner as a snapshot of this transaction read it (none given: read here).
function keepRecent(db: DatabaseSync, session: string, owner: ContextOwner, state: Recent, previous: ContextOwner | null = contextOwner(db, session) ?? null): void {
  const same = previous !== null && previous.runtime === owner.runtime && previous.model === owner.model && previous.fast === owner.fast;
  if (previous && !same) {
    db.prepare(`UPDATE usage_totals SET compact_context = NULL WHERE session = ? AND runtime = ? AND model = ? AND fast = ?`)
      .run(session, previous.runtime, previous.model, previous.fast);
  }
  db.prepare(`INSERT INTO usage_totals (session, runtime, model, fast, calls, input, cache_read, cache_write, cache_write_long, output, compact_context)
    VALUES (?, ?, ?, ?, 0, 0, 0, 0, 0, 0, ?)
    ON CONFLICT (session, runtime, model, fast) DO UPDATE SET compact_context = excluded.compact_context`)
    .run(session, owner.runtime, owner.model, owner.fast, JSON.stringify(state));
  // The pointer to it already says it: nothing to write.
  if (same) return;
  db.prepare(`INSERT INTO usage_minute_scope (session, ws, done, context_runtime, context_model, context_fast)
    VALUES (?, (SELECT ws FROM sessions WHERE key = ?), 1, ?, ?, ?)
    ON CONFLICT (session) DO UPDATE SET context_runtime = excluded.context_runtime, context_model = excluded.context_model,
      context_fast = excluded.context_fast
    WHERE context_runtime IS NOT excluded.context_runtime OR context_model IS NOT excluded.context_model OR context_fast IS NOT excluded.context_fast`)
    .run(session, session, owner.runtime, owner.model, owner.fast);
}

/// A saved summary can seed a context only while it still represents every call and the current runtime session.
/// This is one session's existing summary and totals, not a read of its old calls. An uncertain snapshot is left out.
/// The snapshot it read, where it wrote none (the same transaction's next step reads on from it: `noteCompactContexts`).
export function seedCompactContext(db: DatabaseSync, session: string): ContextSnapshot | null {
  const snapshot = contextSnapshot(db, session);
  if (snapshot.stored || snapshot.invalid) return snapshot;
  const row = db.prepare(`SELECT u.usage, s.runtime_session_id AS runtime, r.at AS began
    FROM session_usage u JOIN sessions s ON s.key = u.session
    LEFT JOIN runtime_sessions r ON r.session_key = s.key AND r.id = s.runtime_session_id WHERE u.session = ?`).get(session) as
    { usage: string; runtime: string | null; began: number | null } | undefined;
  if (row === undefined || row.runtime === null || row.began === null) return snapshot;
  const old = JSON.parse(row.usage) as Record<string, unknown>;
  const total = db.prepare("SELECT COALESCE(SUM(calls), 0) AS n FROM usage_totals WHERE session = ? AND calls > 0").get(session) as { n: number };
  if (old.modelCalls !== total.n || typeof old.lastCallAt !== "number" || old.lastCallAt < row.began
    || (old.model !== null && typeof old.model !== "string")
    || (old.contextWindow !== null && typeof old.contextWindow !== "number")) return snapshot;
  const saved: SavedContext = { runtimeSession: row.runtime, model: old.model as string | null,
    contextWindow: old.contextWindow as number | null, lastCallAt: old.lastCallAt };
  for (const name of ["contextTokens", "cacheMs", "rereadCost"] as const) {
    if (typeof old[name] === "number") saved[name] = old[name];
  }
  const owner = db.prepare("SELECT runtime, model, fast FROM usage_totals WHERE session = ? ORDER BY runtime, model, fast LIMIT 1")
    .get(session) as ContextOwner | undefined;
  if (!owner) return snapshot;
  const state: Recent = { calls: [], turns: [], uncertain: false, saved };
  keepRecent(db, session, owner, state, snapshot.owner);
  return null;
}

export function savedCompactContext(db: DatabaseSync, session: string): SavedContext | null {
  const snapshot = contextSnapshot(db, session);
  if (snapshot.invalid) return null;
  const saved = snapshot.state.saved;
  if (saved === undefined) return null;
  const row = db.prepare("SELECT runtime_session_id AS id FROM sessions WHERE key = ?").get(session) as { id: string | null } | undefined;
  return row?.id === saved.runtimeSession ? saved : null;
}

/// The last five contexts and whether the last two turns compacted are bounded session statistics, not a copy of every call.
/// `read`: the snapshot this transaction read of it already (`seedCompactContext`'s), the calls since inserted with
/// compact_counted, which no trigger takes the context back for.
export function noteCompactContexts(db: DatabaseSync, session: string, runtime: string, calls: [UsageCall, UsageFor][], read: ContextSnapshot | null = null): void {
  const snapshot = read ?? contextSnapshot(db, session);
  const state = snapshot.state;
  let changed = false;
  let target: UsageCall | undefined;
  for (const [call, of] of calls) {
    if (state.saved && call.at < state.saved.lastCallAt) {
      // A late call cannot be the saved latest call. It can change which cache write was in the last five, though.
      if (state.saved.cacheMs !== undefined || state.saved.rereadCost !== undefined) {
        delete state.saved.cacheMs;
        delete state.saved.rereadCost;
        changed = true;
      }
      continue;
    }
    if (state.saved && call.at === state.saved.lastCallAt) {
      // The saved summary did not keep an id, so the order of two calls at the same time is unknown.
      delete state.saved;
      state.calls = [];
      state.turns = [];
      state.uncertain = true;
      db.prepare(`UPDATE usage_minute_scope SET context_uncertain = 1,
        context_after = (SELECT at FROM usage INDEXED BY usage_session WHERE session = ? ORDER BY at DESC LIMIT 1)
        WHERE session = ?`).run(session, session);
    }
    const previous = state.calls.at(-1);
    const next: RecentCall = { id: call.id, turn: of.turn, profile: of.profile, model: call.model, context: call.context,
      window: call.window, at: call.at, fast: call.fast, cacheWrite: call.cacheWrite, cacheWriteLong: call.cacheWriteLong };
    const ordered = previous === undefined || call.at > previous.at || (call.at === previous.at && call.id > previous.id);
    if (!ordered) {
      // An out-of-order call cannot prove the transition between turns from a bounded tail; do not use it for moving an account.
      state.uncertain = true;
      state.turns = [];
    } else {
      if (state.turns.at(-1)?.id !== of.turn || state.turns.length === 0) {
        state.turns.push({ id: of.turn, compacted: false });
        if (state.turns.length > 2) { state.turns.shift(); state.uncertain = false; }
      }
      if (previous !== undefined && previous.context !== null && call.context !== null && call.model !== null
        && previous.context >= COMPACTED_FROM && call.context * 2 < previous.context
        && previous.profile === of.profile && previous.model === call.model) {
        state.turns[state.turns.length - 1]!.compacted = true;
      }
    }
    state.calls.push(next);
    state.calls.sort((a, b) => a.at - b.at || (a.id < b.id ? -1 : a.id > b.id ? 1 : 0));
    state.calls = state.calls.slice(-5);
    changed = true;
    target = call;
  }
  const owner = target ? { runtime, model: target.model ?? "", fast: target.fast ? 1 : 0 } : snapshot.owner;
  if (changed && owner) keepRecent(db, session, owner, state, snapshot.owner);
}

export function compactContexts(db: DatabaseSync, session: string, limit: number): ContextCall[] {
  if (limit <= 0) return [];
  const snapshot = contextSnapshot(db, session);
  return reliableTail(snapshot) ? snapshot.state.calls.slice(-limit).map(({ id: _id, ...call }) => call) : [];
}

export function compactRecentlyCompacted(db: DatabaseSync, session: string): boolean {
  const snapshot = contextSnapshot(db, session);
  return reliableTail(snapshot) && !snapshot.state.uncertain && snapshot.state.turns.some((turn) => turn.compacted);
}
