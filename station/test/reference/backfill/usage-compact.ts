// The steps src/store/usage-compact.ts built its lookup by before the MoonBit builder took them over, kept to compare
// the program with: the station has no step in TypeScript to fall back to. What it still runs is
// src/store/usage-compact.ts's.
import type { DatabaseSync } from "node:sqlite";
import type { InWorkspace } from "../../../src/store/rows.ts";
import { MINUTE_BIAS, tokens, contextChange } from "../../../src/store/usage-compact.ts";

export * from "../../../src/store/usage-compact.ts";

type Moving = { session: string; target: string; phase: number; after_minute: number | null; after_thread: number | null;
  after_person: string | null; after_profile: string | null; after_runtime: string | null; after_model: string | null; after_fast: number | null };
type Bucket = { minute: number; thread: number; person: string; profile: string; runtime: string; model: string; fast: number; scope: string };
type PendingBucket = Bucket & { session: string; records: number; calls: number; tokens: number;
  accounted_scope: string | null; accounted_calls: number; accounted_tokens: number };

const TREE_LEVELS = 7;
const TOTALS_BATCH = 64;
export function setCompactCoverageSince(db: DatabaseSync, since: number): void {
  db.prepare("UPDATE usage_compact_since SET since = ? WHERE id = 1").run(since);
}
/// An old call taken in (the fill, station/mb src/usagefill; test/reference/usage-fill.ts) says nothing new of a
/// session's context. A station whose trigger came before this would lose the context of every session it has old
/// calls of. In the caller's write.
export function keepContextOnFill(db: DatabaseSync): void {
  const trigger = db.prepare("SELECT sql FROM sqlite_master WHERE type = 'trigger' AND name = 'usage_compact_context_change'").get() as { sql: string } | undefined;
  if (trigger === undefined || !trigger.sql.includes("compact_counted")) return;
  db.exec(`DROP TRIGGER usage_compact_context_change; ${contextChange}`);
}
/// The lifetime total of compacted calls alone, with readiness and value read from the same snapshot: what accounting
/// the pending buckets (compactTotalsStep) keeps, which the summary cache relies on (usage-batched.ts).
export function compactTotalQuery(viewer: InWorkspace | null, before?: bigint): { sql: string; args: string[] } {
  const scope = viewer === null ? "scope = 'G'" : viewer.home !== false ? "scope IN (?1, 'H')" : "scope = ?1";
  const moving = viewer === null ? "SELECT 1 FROM usage_compact_moving LIMIT 1"
    : `SELECT 1 FROM usage_compact_moving_scope WHERE ${scope} LIMIT 1`;
  const dirty = viewer === null ? "SELECT 1 FROM usage_compact INDEXED BY usage_compact_pending_session WHERE pending = 1 LIMIT 1"
    : `SELECT 1 FROM usage_compact INDEXED BY usage_compact_pending_scope WHERE pending = 1 AND ${scope} LIMIT 1`;
  // Cover [the earliest possible minute, before) with at most seven runs of at most 255 tree nodes. A request
  // therefore does not visit either earlier calls or arbitrarily many future-dated buckets.
  const bias = BigInt(MINUTE_BIAS);
  const edge = before === undefined ? 2n * bias : before + bias;
  const ranges: [number, number, number][] | null = edge >= 2n * bias ? null : [];
  if (ranges !== null) {
    const end = edge < 0n ? 0n : edge;
    let covered = 0n;
    for (let level = TREE_LEVELS - 1; level >= 0; level--) {
      const width = 1n << BigInt(8 * level);
      const count = (end - covered) / width;
      if (count > 0n) ranges.push([level, Number(covered / width), Number(covered / width + count)]);
      covered += count * width;
    }
  }
  const treeScope = viewer === null ? "t.scope = 'G'" : viewer.home !== false ? "t.scope IN (?1, 'H')" : "t.scope = ?1";
  const treeRanges = viewer === null ? "?1" : "?2";
  const prefix = ranges === null ? "" : `WITH ranges AS MATERIALIZED (
    SELECT json_extract(value, '$[0]') AS level, json_extract(value, '$[1]') AS lo, json_extract(value, '$[2]') AS hi
    FROM json_each(${treeRanges})
  ), prefix AS MATERIALIZED (
    SELECT COALESCE(SUM(t.calls), 0) AS calls, COALESCE(SUM(t.tokens), 0) AS tokens
    FROM ranges r CROSS JOIN usage_compact_total_tree t
    WHERE ${treeScope} AND t.level = r.level AND t.bucket >= r.lo AND t.bucket < r.hi
  )`;
  const value = (column: string) => ranges === null
    ? `(SELECT COALESCE(SUM(${column}), 0) FROM usage_compact_total WHERE ${scope})` : `(SELECT ${column} FROM prefix)`;
  return {
    sql: `${prefix} SELECT NOT EXISTS (${moving}) AND NOT EXISTS (${dirty}) AS ready,
      ${value("calls")} AS calls, ${value("tokens")} AS tokens`,
    args: [...(viewer === null ? [] : [`W${viewer.workspace}`]), ...(ranges === null ? [] : [JSON.stringify(ranges)])],
  };
}
/// Never serve a total until its pending buckets and scope moves finish.
export function compactTotal(db: DatabaseSync, viewer: InWorkspace | null, before?: bigint): { calls: number; tokens: number } | null {
  const query = compactTotalQuery(viewer, before);
  const row = db.prepare(query.sql).get(...query.args) as { ready: number; calls: number; tokens: number };
  return row.ready ? { calls: Number(row.calls), tokens: Number(row.tokens) } : null;
}
// Called within an IMMEDIATE transaction. Each bucket keeps its previously applied contribution, so repeated writes
// coalesce and a removed bucket remains as a tombstone until its contribution is subtracted.
function accountCompactBuckets(db: DatabaseSync, batch: number, session?: string, scope?: string): { count: number; sessions: string[]; from?: number } {
  const selected = session !== undefined ? `INDEXED BY usage_compact_pending_session WHERE pending = 1 AND session = ? LIMIT ?`
    : scope !== undefined ? `INDEXED BY usage_compact_pending_scope WHERE pending = 1 AND scope = ? LIMIT ?`
    : `INDEXED BY usage_compact_pending_scope WHERE pending = 1 LIMIT ?`;
  const rows = db.prepare(`SELECT session, minute, thread, person, profile, runtime, model, fast, scope, records, calls,
    ${tokens("usage_compact")} AS tokens, accounted_scope, accounted_calls, accounted_tokens FROM usage_compact ${selected}`)
    .all(...(session !== undefined ? [session, batch] : scope !== undefined ? [scope, batch] : [batch])) as PendingBucket[];
  type Delta = { calls: number; tokens: number };
  const changes = new Map<string, Delta>();
  const trees = new Map<string, Map<string, Delta & { level: number; bucket: number }>>();
  const add = (scope: string, calls: number, tokens: number, minute: number) => {
    if (calls === 0 && tokens === 0) return;
    const prior = changes.get(scope) ?? { calls: 0, tokens: 0 };
    prior.calls += calls;
    prior.tokens += tokens;
    changes.set(scope, prior);
    let nodes = trees.get(scope);
    if (nodes === undefined) { nodes = new Map(); trees.set(scope, nodes); }
    const shifted = minute + MINUTE_BIAS;
    for (let level = 0; level < TREE_LEVELS; level++) {
      const bucket = Math.floor(shifted / 256 ** level);
      const key = `${level}:${bucket}`;
      const node = nodes.get(key) ?? { level, bucket, calls: 0, tokens: 0 };
      node.calls += calls;
      node.tokens += tokens;
      nodes.set(key, node);
    }
  };
  const update = db.prepare(`UPDATE usage_compact SET accounted_scope = scope, accounted_calls = calls,
    accounted_tokens = ${tokens("usage_compact")}, pending = 0 WHERE session = ? AND minute = ? AND thread = ?
    AND person = ? AND profile = ? AND runtime = ? AND model = ? AND fast = ?`);
  const drop = db.prepare(`DELETE FROM usage_compact WHERE session = ? AND minute = ? AND thread = ? AND person = ?
    AND profile = ? AND runtime = ? AND model = ? AND fast = ? AND records = 0`);
  for (const row of rows) {
    if (row.accounted_scope !== null) {
      add(row.accounted_scope, -row.accounted_calls, -row.accounted_tokens, row.minute);
      add("G", -row.accounted_calls, -row.accounted_tokens, row.minute);
    }
    add(row.scope, row.calls, row.tokens, row.minute);
    add("G", row.calls, row.tokens, row.minute);
    const key = [row.session, row.minute, row.thread, row.person, row.profile, row.runtime, row.model, row.fast] as const;
    update.run(...key);
    if (row.records === 0) drop.run(...key);
  }
  const put = db.prepare(`INSERT INTO usage_compact_total (scope, calls, tokens) VALUES (?, ?, ?)
    ON CONFLICT (scope) DO UPDATE SET calls = calls + excluded.calls, tokens = tokens + excluded.tokens`);
  const clean = db.prepare("DELETE FROM usage_compact_total WHERE scope = ? AND calls = 0 AND tokens = 0");
  for (const [scope, delta] of changes) {
    if (delta.calls !== 0 || delta.tokens !== 0) put.run(scope, delta.calls, delta.tokens);
    clean.run(scope);
  }
  const putNode = db.prepare(`INSERT INTO usage_compact_total_tree (scope, level, bucket, calls, tokens) VALUES (?, ?, ?, ?, ?)
    ON CONFLICT (scope, level, bucket) DO UPDATE SET calls = calls + excluded.calls, tokens = tokens + excluded.tokens`);
  const cleanNode = db.prepare("DELETE FROM usage_compact_total_tree WHERE scope = ? AND level = ? AND bucket = ? AND calls = 0 AND tokens = 0");
  for (const [scope, nodes] of trees) for (const node of nodes.values()) {
    if (node.calls === 0 && node.tokens === 0) continue;
    putNode.run(scope, node.level, node.bucket, node.calls, node.tokens);
    cleanNode.run(scope, node.level, node.bucket);
  }
  const from = rows.length === 0 ? undefined : Math.min(...rows.map((row) => row.minute * 60_000));
  return { count: rows.length, sessions: [...new Set(rows.map((row) => row.session))],
    ...(from !== undefined && Number.isSafeInteger(from) ? { from } : {}) };
}
/// Apply at most one batch of new buckets; this never reads or reconstructs original calls.
export function compactTotalsStep(db: DatabaseSync, batch = 256, scope?: string): { done: boolean; sessions: string[]; from?: number } {
  if (!Number.isSafeInteger(batch) || batch < 1) throw new RangeError("compact totals batch must be positive");
  batch = Math.min(batch, TOTALS_BATCH);
  db.exec("BEGIN IMMEDIATE");
  try {
    const { count, sessions, from } = accountCompactBuckets(db, batch, undefined, scope);
    db.exec("COMMIT");
    return { done: count < batch, sessions, ...(from !== undefined ? { from } : {}) };
  } catch (error) { db.exec("ROLLBACK"); throw error; }
}
/// Re-scope at most one batch. The cursor is reset if the session moves again; writes during a move use its current scope.
export function moveCompactStep(db: DatabaseSync, batch = 256, scope?: string): { done: boolean; session?: string } {
  if (!Number.isSafeInteger(batch) || batch < 1) throw new RangeError("compact workspace batch must be positive");
  batch = Math.min(batch, 256);
  db.exec("BEGIN IMMEDIATE");
  try {
    const move = (scope === undefined ? db.prepare("SELECT * FROM usage_compact_moving ORDER BY session LIMIT 1").get()
      : db.prepare(`SELECT m.* FROM usage_compact_moving_scope sc CROSS JOIN usage_compact_moving m ON m.session = sc.session
          WHERE sc.scope = ? ORDER BY sc.session LIMIT 1`).get(scope)) as Moving | undefined;
    if (move === undefined) { db.exec("COMMIT"); return { done: true }; }
    if (move.phase === 1) {
      // Keep every old scope unavailable until the session's pending contributions have actually left its totals.
      if (accountCompactBuckets(db, Math.min(batch, TOTALS_BATCH), move.session).count > 0) {
        db.exec("COMMIT");
        return { done: false };
      }
      const removed = db.prepare(`DELETE FROM usage_compact_moving_scope WHERE (scope, session) IN (
        SELECT scope, session FROM usage_compact_moving_scope INDEXED BY usage_compact_moving_by_session
        WHERE session = ? AND scope <> ? LIMIT ?)`).run(move.session, move.target, batch).changes;
      if (removed === 0) {
        db.prepare("DELETE FROM usage_compact_moving_scope WHERE scope = ? AND session = ?").run(move.target, move.session);
        db.prepare("DELETE FROM usage_compact_moving WHERE session = ?").run(move.session);
        db.exec("COMMIT");
        return { done: false, session: move.session };
      }
      db.exec("COMMIT");
      return { done: false };
    }
    const after = move.after_minute === null ? "" : " AND (minute, thread, person, profile, runtime, model, fast) > (?, ?, ?, ?, ?, ?, ?)";
    const args = move.after_minute === null ? [move.session, batch] : [move.session, move.after_minute, move.after_thread,
      move.after_person, move.after_profile, move.after_runtime, move.after_model, move.after_fast, batch];
    const rows = db.prepare(`SELECT minute, thread, person, profile, runtime, model, fast, scope FROM usage_compact
      WHERE session = ?${after} ORDER BY minute, thread, person, profile, runtime, model, fast LIMIT ?`).all(...args) as Bucket[];
    const update = db.prepare(`UPDATE usage_compact SET scope = ? WHERE session = ? AND minute = ? AND thread = ?
      AND person = ? AND profile = ? AND runtime = ? AND model = ? AND fast = ?`);
    for (const row of rows) if (row.scope !== move.target) update.run(move.target, move.session, row.minute, row.thread,
      row.person, row.profile, row.runtime, row.model, row.fast);
    if (rows.length < batch) {
      db.prepare("UPDATE usage_compact_moving SET phase = 1 WHERE session = ?").run(move.session);
      db.exec("COMMIT");
      return { done: false };
    }
    const last = rows.at(-1)!;
    db.prepare(`UPDATE usage_compact_moving SET after_minute = ?, after_thread = ?, after_person = ?, after_profile = ?,
      after_runtime = ?, after_model = ?, after_fast = ? WHERE session = ?`).run(last.minute, last.thread, last.person,
      last.profile, last.runtime, last.model, last.fast, move.session);
    db.exec("COMMIT");
    return { done: false };
  } catch (error) { db.exec("ROLLBACK"); throw error; }
}