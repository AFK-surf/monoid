// A session's totals (usage_totals) on a database from before they were kept: an incremental source of one bucket level
// (usage_totals_source*) that follows the calls written since, without treating an old row (one an older station
// replaces among them) as a newly recorded call, and says which sessions' totals are whole (`usageTotalsComplete`).
// Its tables are made by the same statements the per-call details of before were (those details are retired:
// usage-retire.ts), under its own names.
import type { DatabaseSync, StatementSync } from "node:sqlite";

const SIZES = [900_000, 60_000, 1_000, 1] as const;
const COLUMNS = ["calls", "input", "cache_read", "cache_write", "cache_write_long", "output"] as const;
const CHANGES = ["id", "at", "session", "thread", "person", "profile", "runtime", "model", "fast", ...COLUMNS];
const CHANGED = CHANGES.map((c) => `OLD.${c} IS NOT NEW.${c}`).join(" OR ");
const bucket = (row: string, size: number) => size === 1 ? `${row}.at`
  : `(CASE WHEN ${row}.at >= 0 THEN ${row}.at / ${size} ELSE -1 - ((-1 - ${row}.at) / ${size}) END)`;
const fields = (row: string) => `${row}.session, COALESCE(${row}.thread, 0), COALESCE(${row}.person, ''),
  COALESCE(${row}.profile, ''), ${row}.runtime, COALESCE(${row}.model, ''), ${row}.fast`;
const key = (row: string, level: number, sizes: readonly number[] = SIZES) => `usage_detail.session = ${row}.session AND usage_detail.level = ${level} AND usage_detail.bucket = ${bucket(row, sizes[level]!)}
  AND usage_detail.thread = COALESCE(${row}.thread, 0) AND usage_detail.person = COALESCE(${row}.person, '') AND usage_detail.profile = COALESCE(${row}.profile, '')
  AND usage_detail.runtime = ${row}.runtime AND usage_detail.model = COALESCE(${row}.model, '') AND usage_detail.fast = ${row}.fast`;
const indexed = (row: string, live = false) => `${live ? `NOT EXISTS (SELECT 1 FROM usage_detail_ignored WHERE id = ${row}.id) AND ` : ""}EXISTS (SELECT 1 FROM usage_detail_sessions st WHERE st.session = ${row}.session AND
  (st.done = 1 OR (st.after_at IS NOT NULL AND (${row}.at, ${row}.rowid) <= (st.after_at, st.after_rowid))
    OR (st.end_at IS NOT NULL AND (${row}.at, ${row}.rowid) > (st.end_at, st.end_rowid))
    OR EXISTS (SELECT 1 FROM usage_detail_seen WHERE id = ${row}.id)))`;

// An explicit upsert adds a contribution to an existing bucket without replacing its accumulated total.
const add = (row: string, when = "1", sizes: readonly number[] = SIZES) => sizes.map((size, level) => `
  INSERT INTO usage_detail (session, thread, person, profile, runtime, model, fast, level, bucket, records, ${COLUMNS.join(", ")})
    SELECT ${fields(row)}, ${level}, ${bucket(row, size)}, 1, ${COLUMNS.map((c) => `${row}.${c}`).join(", ")}
    WHERE ${when}
    ON CONFLICT (session, level, bucket, thread, person, profile, runtime, model, fast) DO UPDATE SET
      records = records + 1, ${COLUMNS.map((c) => `${c} = ${c} + excluded.${c}`).join(", ")};`).join("");
const remove = (row: string, live = false, sizes: readonly number[] = SIZES) => sizes.map((_, level) => `
  UPDATE usage_detail SET records = records - 1, ${COLUMNS.map((c) => `${c} = ${c} - ${row}.${c}`).join(", ")}
    WHERE ${key(row, level, sizes)} AND ${indexed(row, live)};
  DELETE FROM usage_detail WHERE ${key(row, level, sizes)} AND records = 0;`).join("");
// REPLACE can remove the old row without a DELETE trigger on an older connection. A single staging row captures it
// before INSERT; UPSERT's UPDATE consumes it without using it, while an ignored INSERT can leave at most that one row.
function removeReplacedStatements(id: string, live = false, sizes: readonly number[] = SIZES): string[] {
  const value = (expression: string) => `(SELECT ${expression} FROM usage_detail_replace x WHERE x.id = ${id} AND x.counted = 1${live ? " AND x.removed = 0" : ""})`;
  return sizes.flatMap((size, level) => {
    const match = `session = ${value("x.session")} AND level = ${level} AND bucket = ${value(bucket("x", size))}
      AND thread = ${value("COALESCE(x.thread, 0)")} AND person = ${value("COALESCE(x.person, '')")}
      AND profile = ${value("COALESCE(x.profile, '')")} AND runtime = ${value("x.runtime")}
      AND model = ${value("COALESCE(x.model, '')")} AND fast = ${value("x.fast")}`;
    return [
      `UPDATE usage_detail SET records = records - 1, ${COLUMNS.map((c) => `${c} = ${c} - ${value(`x.${c}`)}`).join(", ")} WHERE ${match}`,
      `DELETE FROM usage_detail WHERE ${match} AND records = 0`,
    ];
  });
}
const removeReplaced = (live: boolean, sizes: readonly number[]) => removeReplacedStatements("NEW.id", live, sizes).map((sql) => `${sql};`).join("\n");
const ensureSession = (row: string, when = "1") => `
  INSERT INTO usage_detail_sessions
    SELECT ${row}.session, NULL, NULL,
      (SELECT at FROM usage WHERE session = ${row}.session ORDER BY at DESC, rowid DESC LIMIT 1),
      (SELECT rowid FROM usage WHERE session = ${row}.session ORDER BY at DESC, rowid DESC LIMIT 1),
      NOT EXISTS (SELECT 1 FROM usage WHERE session = ${row}.session AND id <> ${row}.id LIMIT 1)
    WHERE (${when}) AND NOT EXISTS (SELECT 1 FROM usage_detail_sessions WHERE session = ${row}.session);
  INSERT INTO usage_detail_seen SELECT ${row}.id FROM usage_detail_sessions st
    WHERE (${when}) AND st.session = ${row}.session AND st.done = 0
      AND (st.after_at IS NULL OR (${row}.at, ${row}.rowid) > (st.after_at, st.after_rowid))
      AND (${row}.at, ${row}.rowid) <= (st.end_at, st.end_rowid)
      AND NOT EXISTS (SELECT 1 FROM usage_detail_seen WHERE id = ${row}.id);
  INSERT INTO usage_detail_scope SELECT ${row}.session, (SELECT ws FROM sessions WHERE key = ${row}.session),
    (SELECT done FROM usage_detail_sessions WHERE session = ${row}.session) WHERE ${when}
    ON CONFLICT (session) DO UPDATE SET ws = excluded.ws, done = excluded.done;`;
const scope = (ws: string) => `(CASE WHEN ${ws} IS NULL THEN 'H' ELSE 'W' || ${ws} END)`;
const dirty = (session: string, oldWs: string, newWs: string, when = "1") => `
  INSERT INTO usage_detail_dirty SELECT ${session}, NULL, NULL
    WHERE (${when}) AND EXISTS (SELECT 1 FROM usage_detail_lookup WHERE session = ${session})
    ON CONFLICT (session) DO UPDATE SET after_level = NULL, after_bucket = NULL;
  INSERT INTO usage_detail_dirty_scope SELECT ${session}, ${scope(oldWs)}
    WHERE (${when}) AND EXISTS (SELECT 1 FROM usage_detail_dirty WHERE session = ${session})
      AND NOT EXISTS (SELECT 1 FROM usage_detail_dirty_scope WHERE session = ${session} AND scope = ${scope(oldWs)});
  INSERT INTO usage_detail_dirty_scope SELECT ${session}, ${scope(newWs)}
    WHERE (${when}) AND EXISTS (SELECT 1 FROM usage_detail_dirty WHERE session = ${session})
      AND NOT EXISTS (SELECT 1 FROM usage_detail_dirty_scope WHERE session = ${session} AND scope = ${scope(newWs)});`;

const schema = (live: boolean, sizes: readonly number[] = SIZES) => `
CREATE TABLE usage_detail (
  session TEXT NOT NULL, thread INTEGER NOT NULL, person TEXT NOT NULL, profile TEXT NOT NULL,
  runtime TEXT NOT NULL, model TEXT NOT NULL, fast INTEGER NOT NULL, level INTEGER NOT NULL, bucket INTEGER NOT NULL,
  records INTEGER NOT NULL, calls INTEGER NOT NULL, input INTEGER NOT NULL, cache_read INTEGER NOT NULL,
  cache_write INTEGER NOT NULL, cache_write_long INTEGER NOT NULL, output INTEGER NOT NULL,
  PRIMARY KEY (session, level, bucket, thread, person, profile, runtime, model, fast)
) WITHOUT ROWID;
CREATE TABLE usage_detail_scope (session TEXT PRIMARY KEY, ws TEXT, done INTEGER NOT NULL) WITHOUT ROWID;
CREATE INDEX usage_detail_scope_ws ON usage_detail_scope (ws, done, session);
CREATE TABLE usage_detail_lookup (session TEXT NOT NULL, level INTEGER NOT NULL, bucket INTEGER NOT NULL, scope TEXT NOT NULL,
  PRIMARY KEY (session, level, bucket)) WITHOUT ROWID;
CREATE INDEX usage_detail_lookup_scope ON usage_detail_lookup (scope, level, bucket, session);
CREATE INDEX usage_detail_lookup_time ON usage_detail_lookup (level, bucket, session);
CREATE TABLE usage_detail_dirty (session TEXT PRIMARY KEY, after_level INTEGER, after_bucket INTEGER) WITHOUT ROWID;
CREATE TABLE usage_detail_dirty_scope (session TEXT NOT NULL, scope TEXT NOT NULL, PRIMARY KEY (session, scope)) WITHOUT ROWID;
CREATE INDEX usage_detail_dirty_by_scope ON usage_detail_dirty_scope (scope, session);
CREATE TABLE usage_detail_sessions (session TEXT PRIMARY KEY, after_at INTEGER, after_rowid INTEGER,
  end_at INTEGER, end_rowid INTEGER, done INTEGER NOT NULL) WITHOUT ROWID;
CREATE TABLE usage_detail_seen (id TEXT PRIMARY KEY) WITHOUT ROWID;
${live ? "CREATE TABLE usage_detail_ignored (id TEXT PRIMARY KEY) WITHOUT ROWID;" : ""}
${live ? "CREATE TABLE usage_detail_update (id TEXT PRIMARY KEY, counted INTEGER NOT NULL) WITHOUT ROWID;" : ""}
CREATE TABLE usage_detail_replace (id TEXT PRIMARY KEY, at INTEGER NOT NULL, session TEXT NOT NULL, thread INTEGER,
  person TEXT, profile TEXT, runtime TEXT NOT NULL, model TEXT, fast INTEGER NOT NULL, calls INTEGER NOT NULL,
  input INTEGER NOT NULL, cache_read INTEGER NOT NULL, cache_write INTEGER NOT NULL, cache_write_long INTEGER NOT NULL,
  output INTEGER NOT NULL, counted INTEGER NOT NULL${live ? ", removed INTEGER NOT NULL" : ""}) WITHOUT ROWID;
CREATE TABLE usage_detail_ready (ws TEXT PRIMARY KEY) WITHOUT ROWID;
CREATE TABLE usage_detail_all (id INTEGER PRIMARY KEY CHECK (id = 1), after_session TEXT, done INTEGER NOT NULL);
INSERT INTO usage_detail_all VALUES (1, NULL, NOT EXISTS (SELECT 1 FROM usage LIMIT 1));

CREATE TRIGGER usage_detail_bucket_add AFTER INSERT ON usage_detail BEGIN
  INSERT INTO usage_detail_lookup SELECT NEW.session, NEW.level, NEW.bucket,
    ${scope("(SELECT ws FROM sessions WHERE key = NEW.session)")}
    WHERE NOT EXISTS (SELECT 1 FROM usage_detail_lookup WHERE session = NEW.session AND level = NEW.level AND bucket = NEW.bucket);
END;
CREATE TRIGGER usage_detail_bucket_drop AFTER DELETE ON usage_detail BEGIN
  DELETE FROM usage_detail_lookup WHERE session = OLD.session AND level = OLD.level AND bucket = OLD.bucket
    AND NOT EXISTS (SELECT 1 FROM usage_detail WHERE session = OLD.session AND level = OLD.level AND bucket = OLD.bucket);
END;
CREATE TRIGGER usage_detail_session_token_add BEFORE INSERT ON sessions
  WHEN EXISTS (SELECT 1 FROM sessions WHERE token = NEW.token AND key <> NEW.key) BEGIN
  ${dirty("(SELECT key FROM sessions WHERE token = NEW.token)", "(SELECT ws FROM sessions WHERE token = NEW.token)", "NULL",
    "(SELECT ws FROM sessions WHERE token = NEW.token) IS NOT NULL")}
  UPDATE usage_detail_scope SET ws = NULL WHERE session = (SELECT key FROM sessions WHERE token = NEW.token AND key <> NEW.key);
END;
CREATE TRIGGER usage_detail_session_token_change BEFORE UPDATE OF token ON sessions
  WHEN OLD.token IS NOT NEW.token AND EXISTS (SELECT 1 FROM sessions WHERE token = NEW.token AND key <> NEW.key) BEGIN
  ${dirty("(SELECT key FROM sessions WHERE token = NEW.token)", "(SELECT ws FROM sessions WHERE token = NEW.token)", "NULL",
    "(SELECT ws FROM sessions WHERE token = NEW.token) IS NOT NULL")}
  UPDATE usage_detail_scope SET ws = NULL WHERE session = (SELECT key FROM sessions WHERE token = NEW.token AND key <> NEW.key);
END;
CREATE TRIGGER usage_detail_session_add AFTER INSERT ON sessions BEGIN
  ${dirty("NEW.key", "(SELECT ws FROM usage_detail_scope WHERE session = NEW.key)", "NEW.ws",
    "EXISTS (SELECT 1 FROM usage_detail_scope WHERE session = NEW.key AND ws IS NOT NEW.ws)")}
  INSERT INTO usage_detail_sessions SELECT NEW.key, NULL, NULL,
    (SELECT at FROM usage WHERE session = NEW.key ORDER BY at DESC, rowid DESC LIMIT 1),
    (SELECT rowid FROM usage WHERE session = NEW.key ORDER BY at DESC, rowid DESC LIMIT 1),
    NOT EXISTS (SELECT 1 FROM usage WHERE session = NEW.key LIMIT 1)
    WHERE NOT EXISTS (SELECT 1 FROM usage_detail_sessions WHERE session = NEW.key);
  INSERT INTO usage_detail_scope SELECT NEW.key, NEW.ws, done FROM usage_detail_sessions WHERE session = NEW.key
    AND EXISTS (SELECT 1 FROM ${live ? "usage_detail_lookup" : "usage"} WHERE session = NEW.key LIMIT 1)
    ON CONFLICT (session) DO UPDATE SET ws = excluded.ws, done = excluded.done;
END;
CREATE TRIGGER usage_detail_session_move AFTER UPDATE OF key, ws ON sessions BEGIN
  ${dirty("OLD.key", "OLD.ws", "NULL", "OLD.key IS NOT NEW.key AND OLD.ws IS NOT NULL")}
  UPDATE usage_detail_scope SET ws = NULL WHERE session = OLD.key AND OLD.key IS NOT NEW.key;
  ${dirty("NEW.key", "(SELECT ws FROM usage_detail_scope WHERE session = NEW.key)", "NEW.ws",
    "EXISTS (SELECT 1 FROM usage_detail_scope WHERE session = NEW.key AND ws IS NOT NEW.ws)")}
  INSERT INTO usage_detail_sessions SELECT NEW.key, NULL, NULL,
    (SELECT at FROM usage WHERE session = NEW.key ORDER BY at DESC, rowid DESC LIMIT 1),
    (SELECT rowid FROM usage WHERE session = NEW.key ORDER BY at DESC, rowid DESC LIMIT 1),
    NOT EXISTS (SELECT 1 FROM usage WHERE session = NEW.key LIMIT 1)
    WHERE NOT EXISTS (SELECT 1 FROM usage_detail_sessions WHERE session = NEW.key);
  INSERT INTO usage_detail_scope SELECT NEW.key, NEW.ws, done FROM usage_detail_sessions WHERE session = NEW.key
    AND EXISTS (SELECT 1 FROM ${live ? "usage_detail_lookup" : "usage"} WHERE session = NEW.key LIMIT 1)
    ON CONFLICT (session) DO UPDATE SET ws = excluded.ws, done = excluded.done;
END;
CREATE TRIGGER usage_detail_session_drop AFTER DELETE ON sessions BEGIN
  ${dirty("OLD.key", "OLD.ws", "NULL", "OLD.ws IS NOT NULL")}
  UPDATE usage_detail_scope SET ws = NULL WHERE session = OLD.key;
END;
CREATE TRIGGER usage_detail_before_add BEFORE INSERT ON usage
  WHEN EXISTS (SELECT 1 FROM usage WHERE id = NEW.id) OR EXISTS (SELECT 1 FROM usage_detail_replace) BEGIN
  DELETE FROM usage_detail_replace;
  INSERT INTO usage_detail_replace SELECT u.id, u.at, u.session, u.thread, u.person, u.profile, u.runtime, u.model, u.fast,
    u.calls, u.input, u.cache_read, u.cache_write, u.cache_write_long, u.output, ${indexed("u", live)}${live ? ", 0" : ""}
    FROM usage u WHERE u.id = NEW.id;
END;
CREATE TRIGGER usage_detail_add AFTER INSERT ON usage BEGIN
  ${removeReplaced(live, sizes)}
  DELETE FROM usage_detail_seen WHERE id IN (SELECT id FROM usage_detail_replace WHERE id = NEW.id);
  ${live ? `DELETE FROM usage_detail_ignored WHERE id = NEW.id
    AND NOT EXISTS (SELECT 1 FROM usage_detail_replace WHERE id = NEW.id AND counted = 0);
  INSERT INTO usage_detail_ignored SELECT NEW.id
    WHERE EXISTS (SELECT 1 FROM usage_detail_replace WHERE id = NEW.id AND counted = 0)
      AND NOT EXISTS (SELECT 1 FROM usage_detail_ignored WHERE id = NEW.id);` : ""}
  ${live ? "" : "DELETE FROM usage_detail_replace;"}
  ${ensureSession("NEW", live ? "NOT EXISTS (SELECT 1 FROM usage_detail_replace WHERE id = NEW.id AND counted = 0)" : "1")}
  ${add("NEW", live ? "NOT EXISTS (SELECT 1 FROM usage_detail_replace WHERE id = NEW.id AND counted = 0)" : "1", sizes)}
  ${live ? "DELETE FROM usage_detail_replace;" : ""}
END;
CREATE TRIGGER usage_detail_drop BEFORE DELETE ON usage BEGIN
  ${remove("OLD", live, sizes)}
  DELETE FROM usage_detail_seen WHERE id = OLD.id;
  ${live ? "DELETE FROM usage_detail_ignored WHERE id = OLD.id AND NOT EXISTS (SELECT 1 FROM usage_detail_replace WHERE id = OLD.id);" : ""}
  ${live ? "UPDATE usage_detail_replace SET removed = 1 WHERE id = OLD.id;" : "DELETE FROM usage_detail_replace WHERE id = OLD.id;"}
END;
CREATE TRIGGER usage_detail_change BEFORE UPDATE OF ${CHANGES.join(", ")} ON usage WHEN ${CHANGED} BEGIN
  ${live ? `DELETE FROM usage_detail_update;
  INSERT INTO usage_detail_update VALUES (OLD.id, ${indexed("OLD", true)});` : ""}
  ${remove("OLD", live, sizes)}
  ${live ? "" : "DELETE FROM usage_detail_seen WHERE id = OLD.id;"}
END;
CREATE TRIGGER usage_detail_changed AFTER UPDATE OF ${CHANGES.join(", ")} ON usage
  WHEN (${CHANGED}) BEGIN
  DELETE FROM usage_detail_replace WHERE id = NEW.id;
  ${live ? `DELETE FROM usage_detail_seen WHERE id = OLD.id;
  DELETE FROM usage_detail_ignored WHERE id = OLD.id AND OLD.id IS NOT NEW.id;
  DELETE FROM usage_detail_ignored WHERE id = NEW.id AND EXISTS (SELECT 1 FROM usage_detail_update WHERE counted = 1);
  INSERT INTO usage_detail_ignored SELECT NEW.id
    WHERE EXISTS (SELECT 1 FROM usage_detail_update WHERE counted = 0)
      AND NOT EXISTS (SELECT 1 FROM usage_detail_ignored WHERE id = NEW.id);` : ""}
  ${ensureSession("NEW", live ? "EXISTS (SELECT 1 FROM usage_detail_update WHERE counted = 1)" : "1")}
  ${add("NEW", live ? "EXISTS (SELECT 1 FROM usage_detail_update WHERE counted = 1)" : "1", sizes)}
  ${live ? "DELETE FROM usage_detail_update;" : ""}
END;
CREATE TRIGGER usage_detail_unchanged AFTER UPDATE ON usage WHEN NOT (${CHANGED}) BEGIN
  DELETE FROM usage_detail_replace WHERE id = NEW.id;
END;
`;

/// An old database without session totals starts a separate, empty source. It uses the same replacement and update
/// accounting as live detail but only one bucket level. Totals therefore follow later writes without treating an old
/// row, including one an older station replaces, as a newly recorded call.
export function installIncrementalUsageTotals(db: DatabaseSync): void {
  const has = (name: string) => db.prepare("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?").get(name) !== undefined;
  if (!has("usage_totals_incremental") || has("usage_totals_source_all")) return;
  db.exec("BEGIN IMMEDIATE");
  try {
    if (!has("usage_totals_source_all")) {
      db.exec(schema(true, [SIZES[0]]).replace(/\busage_detail(?=_|\b)/g, "usage_totals_source"));
      // A compact station can keep its bounded context on a totals row. Do not delete that row while it owns it.
      const keepContext = db.prepare("SELECT 1 FROM pragma_table_info('usage_totals') WHERE name = 'compact_context'").get()
        ? " AND compact_context IS NULL" : "";
      db.exec(`UPDATE usage_totals_source_all SET done = 1 WHERE id = 1;
        CREATE TRIGGER usage_totals_source_aggregate_add AFTER INSERT ON usage_totals_source BEGIN
          INSERT INTO usage_totals (session, runtime, model, fast, calls, input, cache_read, cache_write, cache_write_long, output)
          VALUES (NEW.session, NEW.runtime, NEW.model, NEW.fast, NEW.calls, NEW.input,
            NEW.cache_read, NEW.cache_write, NEW.cache_write_long, NEW.output)
          ON CONFLICT (session, runtime, model, fast) DO UPDATE SET
            calls = calls + excluded.calls, input = input + excluded.input, cache_read = cache_read + excluded.cache_read,
            cache_write = cache_write + excluded.cache_write, cache_write_long = cache_write_long + excluded.cache_write_long,
            output = output + excluded.output;
        END;
        CREATE TRIGGER usage_totals_source_aggregate_change AFTER UPDATE ON usage_totals_source BEGIN
          UPDATE usage_totals SET calls = calls + NEW.calls - OLD.calls, input = input + NEW.input - OLD.input,
            cache_read = cache_read + NEW.cache_read - OLD.cache_read, cache_write = cache_write + NEW.cache_write - OLD.cache_write,
            cache_write_long = cache_write_long + NEW.cache_write_long - OLD.cache_write_long, output = output + NEW.output - OLD.output
            WHERE session = OLD.session AND runtime = OLD.runtime AND model = OLD.model AND fast = OLD.fast;
          DELETE FROM usage_totals WHERE session = OLD.session AND runtime = OLD.runtime AND model = OLD.model AND fast = OLD.fast
            AND calls = 0 AND input = 0 AND cache_read = 0 AND cache_write = 0 AND cache_write_long = 0 AND output = 0${keepContext};
        END;
        CREATE TRIGGER usage_totals_source_aggregate_drop AFTER DELETE ON usage_totals_source BEGIN
          UPDATE usage_totals SET calls = calls - OLD.calls, input = input - OLD.input, cache_read = cache_read - OLD.cache_read,
            cache_write = cache_write - OLD.cache_write, cache_write_long = cache_write_long - OLD.cache_write_long, output = output - OLD.output
            WHERE session = OLD.session AND runtime = OLD.runtime AND model = OLD.model AND fast = OLD.fast;
          DELETE FROM usage_totals WHERE session = OLD.session AND runtime = OLD.runtime AND model = OLD.model AND fast = OLD.fast
            AND calls = 0 AND input = 0 AND cache_read = 0 AND cache_write = 0 AND cache_write_long = 0 AND output = 0${keepContext};
        END;`);
    }
    db.exec("COMMIT");
  } catch (error) {
    db.exec("ROLLBACK");
    throw error;
  }
}

/// A session total is complete if the total existed before the upgrade, or the new source saw no earlier calls of it.
export function usageTotalsComplete(db: DatabaseSync, session: string): boolean {
  if (!incrementalTotals(db)) return true;
  return (totalsStatement(db, "SELECT done FROM usage_totals_source_sessions WHERE session = ?").get(session) as { done: number } | undefined)?.done === 1;
}

/// Whether the totals were made incremental by the upgrade (schema.ts): decided once, as the schema migrated when the
/// store opened, and never changed after (the table is made then or never, and not dropped). Learned once a connection,
/// not at each usage record.
function incrementalTotals(db: DatabaseSync): boolean {
  let known = incremental.get(db);
  if (known === undefined) {
    known = totalsStatement(db, "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'usage_totals_incremental'").get() !== undefined;
    incremental.set(db, known);
  }
  return known;
}
const incremental = new WeakMap<DatabaseSync, boolean>();
/// The upgrade decided it on this connection (schema.ts `addUsageTotals`): asked again.
export function incrementalTotalsDecided(db: DatabaseSync): void {
  incremental.delete(db);
}

/// usageTotalsComplete's statements, each prepared once a connection (it is asked at every usage record and summary).
const totalsStatements = new WeakMap<DatabaseSync, Map<string, StatementSync>>();
function totalsStatement(db: DatabaseSync, sql: string): StatementSync {
  let kept = totalsStatements.get(db);
  if (kept === undefined) totalsStatements.set(db, (kept = new Map()));
  let statement = kept.get(sql);
  if (statement === undefined) kept.set(sql, (statement = db.prepare(sql)));
  return statement;
}

