// What the agents spent, added up by quarter hour: the one statistic of the `usage` table the usage page and a Comma
// connect read (mb/src/readops/usagegroups.mbt, usagepage.mbt; test/reference/usage.ts the TypeScript they are held to).
// Kept by the database itself, in the same write as each call recorded, grown, moved or removed, whichever process
// writes it (the triggers below), so a read never waits for a statistic to be prepared:
// - usage_15m: each quarter's calls by workspace (`scope`: its session's `ws`, '' the home one's), session, chat,
//   person, account, runtime, model and speed;
// - usage_quarter_totals: each workspace's quarters in all (the page's year);
// - usage_scope_totals: each workspace in all.
// A session's rows are all of one workspace: its own while it is there, and where they were once it is gone (deleted,
// its key changed), until a session of that key is there again. `setSessionsWs` moves those of a whole workspace.
//
// Installed as the store opens, without reading old calls (`installUsage15m`): a database with calls from before keeps
// them out (usage.rollup_counted = 0) and says from when every call is counted (usage_15m_meta.since); the station takes
// them in afterwards, newest first, a few quarters at a time, off the main thread (the MoonBit builder's: station/mb
// src/usagefill `fill_step`; the TypeScript it is held to, test/reference/backfill/usage-retire.ts).
//
// What the 37 tables before it kept (usage_detail*, usage_minute*, usage_day_quarters, usage_quarters, usage_compact*,
// usage_summary*, usage_history*) is dropped once the station before has gone (store/usage-retire.ts).
import type { DatabaseSync } from "node:sqlite";

export const QUARTER_MS = 900_000;
/// gen_ms and gen_output: how long the calls whose time it took is known took (ms) and what they wrote (the usage
/// counter's, usage/speed: what Profile overview's 输出速度 is read of, `SPEED_READ`).
const METRICS = ["calls", "input", "cache_read", "cache_write", "cache_write_long", "output", "gen_ms", "gen_output"] as const;
const DIMENSIONS = ["scope", "quarter", "session", "thread", "person", "profile", "runtime", "model", "fast"] as const;

/// The quarter hour `r.at` is in, rounded down (also before 1970).
export const quarterOf = (r: string): string => `(CASE WHEN ${r}.at >= 0 THEN ${r}.at / ${QUARTER_MS} ELSE (${r}.at - ${QUARTER_MS - 1}) / ${QUARTER_MS} END)`;
/// What a row's tokens add up to (as the year counts them).
const tokensOf = (r: string): string => `(${r}.input + ${r}.cache_read + ${r}.cache_write + ${r}.cache_write_long + ${r}.output)`;
/// The workspace a session's calls are counted in: its own ('' the home one's), else where its calls already are (a
/// session gone; or the call an INSERT OR REPLACE is replacing was, usage_15m_replace), else ''.
const scopeOf = (session: string): string => `COALESCE((SELECT COALESCE(ws, '') FROM sessions WHERE key = ${session}),
  (SELECT scope FROM usage_15m INDEXED BY usage_15m_session WHERE session = ${session} LIMIT 1),
  (SELECT scope FROM usage_15m_replace WHERE session = ${session} LIMIT 1), '')`;
const values = (r: string): string[] => [scopeOf(`${r}.session`), quarterOf(r), `${r}.session`, `COALESCE(${r}.thread, 0)`,
  `COALESCE(${r}.person, '')`, `COALESCE(${r}.profile, '')`, `${r}.runtime`, `COALESCE(${r}.model, '')`,
  `(CASE WHEN ${r}.fast != 0 THEN 1 ELSE 0 END)`];
const keyOf = (r: string): string => DIMENSIONS.map((d, i) => `${d} = ${values(r)[i]}`).join(" AND ");

/// A call added to its quarter. An upsert, not OR IGNORE: SQLite gives a trigger's own conflict clause up for the outer
/// statement's (an INSERT OR REPLACE of a call), but not an upsert's DO UPDATE.
const add = (r: string, when: string): string => `INSERT INTO usage_15m (${DIMENSIONS.join(", ")}, records, ${METRICS.join(", ")})
  SELECT ${values(r).join(", ")}, 1, ${METRICS.map((m) => `${r}.${m}`).join(", ")} WHERE ${when}
  ON CONFLICT (${DIMENSIONS.join(", ")}) DO UPDATE SET records = records + 1, ${METRICS.map((m) => `${m} = ${m} + excluded.${m}`).join(", ")};`;
/// A call taken out of its quarter (never a row made for it), the quarter's row gone with its last call.
const remove = (r: string, when: string): string => `UPDATE usage_15m SET records = records - 1, ${METRICS.map((m) => `${m} = ${m} - ${r}.${m}`).join(", ")}
  WHERE (${when}) AND ${keyOf(r)};
  DELETE FROM usage_15m WHERE (${when}) AND ${keyOf(r)} AND records = 0;`;
/// A call's values changed where it stays: its quarter's row by the difference.
const adjust = `UPDATE usage_15m SET ${METRICS.map((m) => `${m} = ${m} + NEW.${m} - OLD.${m}`).join(", ")} WHERE ${keyOf("NEW")};`;
/// The columns a call's quarter row is told by.
const PLACE = ["at", "session", "thread", "person", "profile", "runtime", "model", "fast"] as const;
const placeChanged = PLACE.map((c) => `OLD.${c} IS NOT NEW.${c}`).join(" OR ");
const valuesChanged = METRICS.map((c) => `OLD.${c} IS NOT NEW.${c}`).join(" OR ");
const STAGED = ["id", ...PLACE, ...METRICS] as const;
/// The call an INSERT OR REPLACE removed (usage_15m_replace) taken out of its quarter.
const staged = "(SELECT * FROM usage_15m_replace WHERE id = NEW.id AND counted = 1)";
const removeStaged = `UPDATE usage_15m SET records = usage_15m.records - 1,
    ${METRICS.map((m) => `${m} = usage_15m.${m} - x.${m}`).join(", ")}
  FROM ${staged} x WHERE ${DIMENSIONS.map((d, i) => `usage_15m.${d} = ${values("x")[i]}`).join(" AND ")};
  DELETE FROM usage_15m WHERE records = 0 AND (${DIMENSIONS.join(", ")}) IN (SELECT ${values("x").join(", ")} FROM ${staged} x);`;

const totalsAdd = (r: string, sign: string) => `
  INSERT INTO usage_quarter_totals (scope, quarter, calls, tokens) VALUES (${r}.scope, ${r}.quarter, ${sign}${r}.calls, ${sign}${tokensOf(r)})
    ON CONFLICT (scope, quarter) DO UPDATE SET calls = calls + excluded.calls, tokens = tokens + excluded.tokens;
  INSERT INTO usage_scope_totals (scope, calls, tokens) VALUES (${r}.scope, ${sign}${r}.calls, ${sign}${tokensOf(r)})
    ON CONFLICT (scope) DO UPDATE SET calls = calls + excluded.calls, tokens = tokens + excluded.tokens;`;
const totalsClean = (r: string) => `
  DELETE FROM usage_quarter_totals WHERE scope = ${r}.scope AND quarter = ${r}.quarter
    AND NOT EXISTS (SELECT 1 FROM usage_15m WHERE scope = ${r}.scope AND quarter = ${r}.quarter);
  DELETE FROM usage_scope_totals WHERE scope = ${r}.scope AND NOT EXISTS (SELECT 1 FROM usage_15m WHERE scope = ${r}.scope);`;
/// A session's calls to the workspace it is in now.
const moveSession = (key: string, ws: string) => `UPDATE usage_15m SET scope = COALESCE(${ws}, '')
  WHERE session = ${key} AND scope <> COALESCE(${ws}, '');`;

/// The staging of a call an INSERT meets and the triggers on \`usage\` that keep its quarters: made again whole where the
/// metrics grew (installUsage15mGen).
const USAGE_KEPT = `
-- The call an INSERT is about to meet, as it is, and its workspace: an INSERT OR REPLACE removes it without its DELETE
-- triggers (unless recursive_triggers is on), and the insert's own trigger takes it out of its quarter then, the new
-- call counted where it was. An upsert or an ignored insert leaves it, taken away by the next write.
CREATE TABLE usage_15m_replace (${STAGED.map((c) => `${c}${c === "id" ? " TEXT PRIMARY KEY" : ""}`).join(", ")}, counted INTEGER NOT NULL,
  scope TEXT NOT NULL) WITHOUT ROWID;

CREATE TRIGGER usage_15m_before_add BEFORE INSERT ON usage
  WHEN EXISTS (SELECT 1 FROM usage_15m_replace) OR EXISTS (SELECT 1 FROM usage WHERE id = NEW.id) BEGIN
  DELETE FROM usage_15m_replace;
  INSERT INTO usage_15m_replace SELECT ${STAGED.join(", ")}, rollup_counted, ${scopeOf("usage.session")} FROM usage WHERE id = NEW.id;
END;
CREATE TRIGGER usage_15m_add AFTER INSERT ON usage BEGIN
  ${add("NEW", "NEW.rollup_counted = 1")}
  ${removeStaged}
  DELETE FROM usage_15m_replace;
  UPDATE usage SET rollup_counted = 1 WHERE id = NEW.id AND NEW.rollup_counted = 0;
END;
CREATE TRIGGER usage_15m_change AFTER UPDATE ON usage
  WHEN (OLD.rollup_counted = 1 OR NEW.rollup_counted = 1) AND (OLD.rollup_counted IS NOT NEW.rollup_counted OR ${placeChanged}) BEGIN
  ${add("NEW", "NEW.rollup_counted = 1")}
  ${remove("OLD", "OLD.rollup_counted = 1")}
END;
CREATE TRIGGER usage_15m_grow AFTER UPDATE ON usage
  WHEN OLD.rollup_counted = 1 AND NEW.rollup_counted = 1 AND NOT (${placeChanged}) AND (${valuesChanged}) BEGIN
  ${adjust}
END;
CREATE TRIGGER usage_15m_updated AFTER UPDATE ON usage WHEN EXISTS (SELECT 1 FROM usage_15m_replace) BEGIN
  DELETE FROM usage_15m_replace;
END;
CREATE TRIGGER usage_15m_drop AFTER DELETE ON usage BEGIN
  ${remove("OLD", "OLD.rollup_counted = 1")}
  -- (an INSERT OR REPLACE's removal, where recursive_triggers is on: taken out here, its workspace kept for the insert)
  UPDATE usage_15m_replace SET counted = 0 WHERE id = OLD.id;
END;

`;

const SCHEMA = `
CREATE TABLE usage_15m (scope TEXT NOT NULL, quarter INTEGER NOT NULL, session TEXT NOT NULL, thread INTEGER NOT NULL,
  person TEXT NOT NULL, profile TEXT NOT NULL, runtime TEXT NOT NULL, model TEXT NOT NULL, fast INTEGER NOT NULL,
  records INTEGER NOT NULL, calls INTEGER NOT NULL, input INTEGER NOT NULL, cache_read INTEGER NOT NULL,
  cache_write INTEGER NOT NULL, cache_write_long INTEGER NOT NULL, output INTEGER NOT NULL,
  PRIMARY KEY (${DIMENSIONS.join(", ")})) WITHOUT ROWID;
ALTER TABLE usage_15m ADD COLUMN gen_ms INTEGER NOT NULL DEFAULT 0;
ALTER TABLE usage_15m ADD COLUMN gen_output INTEGER NOT NULL DEFAULT 0;
CREATE INDEX usage_15m_session ON usage_15m (session, scope, quarter);
CREATE INDEX usage_15m_quarter ON usage_15m (quarter, scope);
CREATE TABLE usage_quarter_totals (scope TEXT NOT NULL, quarter INTEGER NOT NULL, calls INTEGER NOT NULL, tokens INTEGER NOT NULL,
  PRIMARY KEY (scope, quarter)) WITHOUT ROWID;
CREATE TABLE usage_scope_totals (scope TEXT PRIMARY KEY, calls INTEGER NOT NULL, tokens INTEGER NOT NULL) WITHOUT ROWID;
-- since: from when every call is counted (ms); NULL, from the first.
CREATE TABLE usage_15m_meta (id INTEGER PRIMARY KEY CHECK (id = 1), since INTEGER);
CREATE TRIGGER usage_15m_totals_add AFTER INSERT ON usage_15m BEGIN ${totalsAdd("NEW", "")} END;
CREATE TRIGGER usage_15m_totals_grow AFTER UPDATE ON usage_15m WHEN OLD.scope = NEW.scope AND OLD.quarter = NEW.quarter BEGIN
  UPDATE usage_quarter_totals SET calls = calls + NEW.calls - OLD.calls, tokens = tokens + ${tokensOf("NEW")} - ${tokensOf("OLD")}
    WHERE scope = NEW.scope AND quarter = NEW.quarter;
  UPDATE usage_scope_totals SET calls = calls + NEW.calls - OLD.calls, tokens = tokens + ${tokensOf("NEW")} - ${tokensOf("OLD")}
    WHERE scope = NEW.scope;
END;
CREATE TRIGGER usage_15m_totals_move AFTER UPDATE ON usage_15m WHEN OLD.scope <> NEW.scope OR OLD.quarter <> NEW.quarter BEGIN
  ${totalsAdd("OLD", "-")}
  ${totalsAdd("NEW", "")}
  ${totalsClean("OLD")}
END;
CREATE TRIGGER usage_15m_totals_drop AFTER DELETE ON usage_15m BEGIN
  ${totalsAdd("OLD", "-")}
  ${totalsClean("OLD")}
END;

${USAGE_KEPT}
CREATE TRIGGER usage_15m_session_add AFTER INSERT ON sessions BEGIN ${moveSession("NEW.key", "NEW.ws")} END;
CREATE TRIGGER usage_15m_session_move AFTER UPDATE OF key, ws ON sessions
  WHEN OLD.key IS NOT NEW.key OR OLD.ws IS NOT NEW.ws BEGIN ${moveSession("NEW.key", "NEW.ws")} END;
`;

const has = (db: DatabaseSync, table: string) =>
  db.prepare("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?").get(table) !== undefined;

export const hasUsage15m = (db: DatabaseSync): boolean => has(db, "usage_15m_meta");

/// Installs the quarters in one short write as the store opens, reading no call: a new database counts from its first
/// (since NULL); one with calls already counts from now (`now`, ms, or past its latest call, by the index on their
/// time), the calls before taken in later (station/mb src/usagefill `fill_step`).
export function installUsage15m(db: DatabaseSync, now: number): void {
  if (hasUsage15m(db)) return;
  db.exec("BEGIN IMMEDIATE");
  try {
    if (!hasUsage15m(db)) {
      const columns = new Set((db.prepare("PRAGMA table_info(usage)").all() as { name: string }[]).map((c) => c.name));
      if (!columns.has("rollup_counted")) db.exec("ALTER TABLE usage ADD COLUMN rollup_counted INTEGER NOT NULL DEFAULT 0");
      addGenColumns(db, columns);
      db.exec(SCHEMA);
      const old = db.prepare("SELECT 1 FROM usage LIMIT 1").get() !== undefined;
      // (a call recorded ahead of the clock is one of those to take in too: its time by the index, one entry)
      const latest = old ? (db.prepare("SELECT MAX(at) AS at FROM usage INDEXED BY usage_at").get() as { at: number }).at : null;
      db.prepare("INSERT INTO usage_15m_meta (id, since) VALUES (1, ?)").run(old ? Math.max(now, latest! + 1) : null);
    }
    db.exec("COMMIT");
  } catch (error) { db.exec("ROLLBACK"); throw error; }
}

/// A call's time taken and what it wrote then (usage/speed): 0 where its time is not known.
function addGenColumns(db: DatabaseSync, columns: Set<string>): void {
  if (!columns.has("gen_ms")) db.exec("ALTER TABLE usage ADD COLUMN gen_ms INTEGER NOT NULL DEFAULT 0");
  if (!columns.has("gen_output")) db.exec("ALTER TABLE usage ADD COLUMN gen_output INTEGER NOT NULL DEFAULT 0");
}

/// The quarters of a database from before a call's time was kept given its two metrics, in one short write as the
/// store opens: the columns added (0 for every call and quarter there, none read) and the staging and the triggers on
/// `usage` made again with them, as a new database makes them (`installUsage15m`).
export function installUsage15mGen(db: DatabaseSync): void {
  const has15m = () => (db.prepare("PRAGMA table_info(usage_15m)").all() as { name: string }[]).some((c) => c.name === "gen_ms");
  if (!hasUsage15m(db) || has15m()) return;
  db.exec("BEGIN IMMEDIATE");
  try {
    if (!has15m()) {
      addGenColumns(db, new Set((db.prepare("PRAGMA table_info(usage)").all() as { name: string }[]).map((c) => c.name)));
      db.exec(`ALTER TABLE usage_15m ADD COLUMN gen_ms INTEGER NOT NULL DEFAULT 0;
        ALTER TABLE usage_15m ADD COLUMN gen_output INTEGER NOT NULL DEFAULT 0;
        DROP TRIGGER usage_15m_before_add; DROP TRIGGER usage_15m_add; DROP TRIGGER usage_15m_change; DROP TRIGGER usage_15m_grow;
        DROP TRIGGER usage_15m_updated; DROP TRIGGER usage_15m_drop; DROP TABLE usage_15m_replace;
        ${USAGE_KEPT}`);
    }
    db.exec("COMMIT");
  } catch (error) { db.exec("ROLLBACK"); throw error; }
}

/// From when every call is counted (ms); null, from the first.
export function usage15mSince(db: DatabaseSync): number | null {
  return (db.prepare("SELECT since FROM usage_15m_meta WHERE id = 1").get() as { since: number | null } | undefined)?.since ?? null;
}

/// The calls of workspace `from` ('' the home one) are `to`'s from now on, those of its sessions gone too: when the
/// station's home workspace changes, all its sessions go together (store.ts setSessionsWs). In the caller's write,
/// after the sessions moved (their triggers moved their own).
export function moveUsage15m(db: DatabaseSync, from: string, to: string): void {
  if (from === to || !hasUsage15m(db)) return;
  db.prepare("UPDATE usage_15m SET scope = ? WHERE scope = ?").run(to, from);
}

const I64_MAX = 9223372036854775807n;
const Q = BigInt(QUARTER_MS);
const DAY_MS = 86_400_000n;
const floorDiv = (n: bigint, d: bigint) => (n >= 0n ? n / d : -1n - ((-1n - n) / d));

/// The workspaces a viewer's reads take (rows.ts `sees`): their workspace's, and the home one's ('') where it is theirs;
/// null, every one.
export type UsageViewer = { workspace: string; home?: boolean } | null;

/// The calls from `from` until `to` (ms; `to` I64_MAX: on, with no end), added up by day `offset` minutes east of UTC
/// and by session, chat, person, account, runtime and model, as the usage page and a Comma connect read them
/// (mb/src/readops/usagegroups.mbt `usage_groups`, the same statement): the whole quarters from usage_15m by its
/// primary key (a viewer's) or its time index (all), and the calls themselves only where a quarter is not wholly in the
/// span or in one local day: the span's two partial edges, and, where the offset is not of whole quarters, the quarter
/// each local midnight falls in. Those are found by the quarters (which sessions have calls there), then read by the
/// index on a session's calls; each is counted where its quarter is (rollup_counted), so the two never disagree.
export function usage15mQuery(from: bigint, to: bigint, offset: bigint, viewer: UsageViewer): { sql: string; args: (string | bigint)[] } | null {
  if (from >= to) return null;
  const args: (string | bigint)[] = [];
  const bind = (value: string | bigint) => { args.push(value); return `?${args.length}`; };
  const off = bind(offset);
  const scope = viewer === null ? "1" : viewer.home !== false ? `c.scope IN (${bind(viewer.workspace)}, '')` : `c.scope = ${bind(viewer.workspace)}`;
  // (a viewer's by the primary key, its workspace first; all by the time index)
  const index = viewer === null ? " INDEXED BY usage_15m_quarter" : "";
  const open = to === I64_MAX;
  const first = -floorDiv(-from, Q); // the first whole quarter
  const last = open ? floorDiv(I64_MAX, Q) + 1n : floorDiv(to, Q); // the end of the whole quarters
  const raw = (pairs: string, low: string, high: string) => `SELECT strftime('%Y-%m-%d', (u.at + ${off} * 60000) / 1000.0, 'unixepoch') AS day,
      u.session, COALESCE(u.thread, 0) AS thread, COALESCE(u.person, '') AS person, COALESCE(u.profile, '') AS profile, u.runtime,
      COALESCE(u.model, '') AS model, CASE WHEN u.fast != 0 THEN 1 ELSE 0 END AS fast, u.calls, u.input, u.cache_read, u.cache_write,
      u.cache_write_long, u.output
    FROM (${pairs}) e CROSS JOIN usage u INDEXED BY usage_session ON u.session = e.session AND u.at >= ${low} AND u.at < ${high}
    WHERE u.rollup_counted = 1`;
  const parts: string[] = [];
  // (a quarter local midnight falls within: none where the offset is of whole quarters)
  const straddles = (offset * 60_000n) % Q === 0n ? null
    : `(((c.quarter * ${QUARTER_MS} + ${off} * 60000) % 86400000 + 86400000) % 86400000 > ${DAY_MS - Q})`;
  if (first < last) {
    const lo = bind(first), hi = bind(last);
    parts.push(`SELECT strftime('%Y-%m-%d', c.quarter * 900 + ${off} * 60, 'unixepoch') AS day, c.session, c.thread, c.person,
      c.profile, c.runtime, c.model, c.fast, c.calls, c.input, c.cache_read, c.cache_write, c.cache_write_long, c.output
      FROM usage_15m c${index} WHERE ${scope} AND c.quarter >= ${lo} AND c.quarter < ${hi}${straddles === null ? "" : ` AND NOT ${straddles}`}`);
    if (straddles !== null) {
      parts.push(raw(`SELECT DISTINCT c.session, c.quarter FROM usage_15m c${index}
        WHERE ${scope} AND c.quarter >= ${lo} AND c.quarter < ${hi} AND ${straddles}`,
        `e.quarter * ${QUARTER_MS}`, `(e.quarter + 1) * ${QUARTER_MS}`));
    }
  }
  // A part of a quarter: its calls from `low` until `high`.
  const edge = (quarter: bigint, low: bigint, high: bigint) => {
    if (low >= high) return;
    parts.push(raw(`SELECT DISTINCT c.session FROM usage_15m c${index} WHERE ${scope} AND c.quarter = ${bind(quarter)}`,
      bind(low), bind(high)));
  };
  if (first > last) edge(last, from, to); // within one quarter
  else {
    edge(first - 1n, from, first * Q);
    if (!open) edge(last, last * Q, to);
  }
  if (parts.length === 0) return null;
  const sql = `WITH parts AS (${parts.join("\n  UNION ALL\n  ")})
  SELECT day, session, NULLIF(thread, 0) AS thread, NULLIF(person, '') AS person, NULLIF(profile, '') AS profile, runtime,
    NULLIF(model, '') AS model, fast, SUM(calls) AS calls, SUM(input) AS input, SUM(cache_read) AS cache_read,
    SUM(cache_write) AS cache_write, SUM(cache_write_long) AS cache_write_long, SUM(output) AS output
  FROM parts GROUP BY day, session, thread, person, profile, runtime, model, fast
  ORDER BY day, session, thread, person, profile, runtime, model, fast`;
  return { sql, args };
}

/// The page's year: one workspace's quarters from `?2` until `?3` (quarters), added up by day `?4` minutes east of UTC,
/// by their primary key. Where the offset is not of whole quarters, a quarter local midnight falls within is its
/// start's day.
export const HISTORY_DAYS = `SELECT strftime('%Y-%m-%d', quarter * 900 + ?4 * 60, 'unixepoch') AS day, SUM(calls) AS calls, SUM(tokens) AS tokens
  FROM usage_quarter_totals WHERE scope = ?1 AND quarter >= ?2 AND quarter < ?3 GROUP BY day`;
/// One workspace's tokens from quarter `?2` on: what its total holds of the days after the page's.
export const HISTORY_AFTER = "SELECT SUM(tokens) AS tokens FROM usage_quarter_totals WHERE scope = ?1 AND quarter >= ?2";
export const HISTORY_SCOPES = "SELECT scope, tokens FROM usage_scope_totals ORDER BY scope";
export const HISTORY_TOTAL = "SELECT tokens FROM usage_scope_totals WHERE scope = ?1";

/// The quarter `at` (ms) is in.
export const quarter = (at: bigint): bigint => floorDiv(at, Q);
