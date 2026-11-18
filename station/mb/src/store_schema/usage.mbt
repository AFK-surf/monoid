// What the agents spent, as the store keeps it by the database itself (station/src/store/usage-15m.ts, usage-span.ts,
// usage-compactions.ts, usage-totals-source.ts, usage-compact.ts, usage-retire.ts, usage.ts `installUsageCounter`,
// profile-hours.ts): their tables and the triggers that keep them, made as the store opens without reading an old call.

///|
fn joined(parts : Array[String], sep : String) -> String {
  let out = StringBuilder()
  for i, p in parts {
    if i > 0 {
      out.write_string(sep)
    }
    out.write_string(p)
  }
  out.to_string()
}

///|
let metrics : Array[String] = ["calls", "input", "cache_read", "cache_write", "cache_write_long", "output"]

///|
/// The quarters' (usage-15m.ts METRICS): gen_ms and gen_output, how long the calls whose time is known took and what
/// they wrote (usagecount/speed.mbt).
let q15_metrics : Array[String] = [..metrics, "gen_ms", "gen_output"]

///|
fn each_q15_metric(f : (String) -> String) -> String {
  joined(q15_metrics.map(f), ", ")
}

///|
let dimensions : Array[String] = ["scope", "quarter", "session", "thread", "person", "profile", "runtime", "model", "fast"]

///|
fn each_metric(f : (String) -> String) -> String {
  joined(metrics.map(f), ", ")
}

///|
let dimensions_list : String = joined(dimensions, ", ")

///|
let metrics_list : String = joined(metrics, ", ")

///|
let quarter_ms : String = "900000"

///|
let quarter_ms_less : String = "899999"

///|
/// The quarter hour `r.at` is in, rounded down (also before 1970).
fn q15_quarter_of(r : String) -> String {
(
  $|(CASE WHEN \{r}.at >= 0 THEN \{r}.at / \{quarter_ms} ELSE (\{r}.at - \{quarter_ms_less}) / \{quarter_ms} END)
)
}

///|
fn q15_tokens_of(r : String) -> String {
(
  $|(\{r}.input + \{r}.cache_read + \{r}.cache_write + \{r}.cache_write_long + \{r}.output)
)
}

///|
/// The workspace a session's calls are counted in.
fn q15_scope_of(session : String) -> String {
(
  $|COALESCE((SELECT COALESCE(ws, '') FROM sessions WHERE key = \{session}),
  $|  (SELECT scope FROM usage_15m INDEXED BY usage_15m_session WHERE session = \{session} LIMIT 1),
  $|  (SELECT scope FROM usage_15m_replace WHERE session = \{session} LIMIT 1), '')
)
}

///|
fn q15_values(r : String) -> Array[String] {
  [
    q15_scope_of("\{r}.session"),
    q15_quarter_of(r),
    "\{r}.session",
    "COALESCE(\{r}.thread, 0)",
    "COALESCE(\{r}.person, '')",
    "COALESCE(\{r}.profile, '')",
    "\{r}.runtime",
    "COALESCE(\{r}.model, '')",
    "(CASE WHEN \{r}.fast != 0 THEN 1 ELSE 0 END)",
  ]
}

///|
fn q15_key_of(r : String) -> String {
  let values = q15_values(r)
  joined(dimensions.mapi((i, d) => "\{d} = \{values[i]}"), " AND ")
}

///|
/// A call added to its quarter (an upsert).
fn q15_add(r : String, when : String) -> String {
(
  $|INSERT INTO usage_15m (\{dimensions_list}, records, \{joined(q15_metrics, ", ")})
  $|  SELECT \{joined(q15_values(r), ", ")}, 1, \{each_q15_metric(m => r + "." + m)} WHERE \{when}
  $|  ON CONFLICT (\{dimensions_list}) DO UPDATE SET records = records + 1, \{each_q15_metric(m => m + " = " + m + " + excluded." + m)};
)
}

///|
/// A call taken out of its quarter, the quarter's row gone with its last call.
fn q15_remove(r : String, when : String) -> String {
(
  $|UPDATE usage_15m SET records = records - 1, \{each_q15_metric(m => m + " = " + m + " - " + r + "." + m)}
  $|  WHERE (\{when}) AND \{q15_key_of(r)};
  $|  DELETE FROM usage_15m WHERE (\{when}) AND \{q15_key_of(r)} AND records = 0;
)
}

///|
let q15_adjust : String = "UPDATE usage_15m SET " +
  each_q15_metric(m => m + " = " + m + " + NEW." + m + " - OLD." + m) +
  " WHERE " +
  q15_key_of("NEW") +
  ";"

///|
let place : Array[String] = ["at", "session", "thread", "person", "profile", "runtime", "model", "fast"]

///|
let q15_place_changed : String = joined(place.map(c => "OLD.\{c} IS NOT NEW.\{c}"), " OR ")

///|
let q15_values_changed : String = joined(q15_metrics.map(c => "OLD.\{c} IS NOT NEW.\{c}"), " OR ")

///|
let staged_columns : Array[String] = ["id", ..place, ..q15_metrics]

///|
let q15_staged : String = "(SELECT * FROM usage_15m_replace WHERE id = NEW.id AND counted = 1)"

///|
let q15_remove_staged : String =
(
  $|UPDATE usage_15m SET records = usage_15m.records - 1,
  $|    \{each_q15_metric(m => m + " = usage_15m." + m + " - x." + m)}
  $|  FROM \{q15_staged} x WHERE \{joined(dimensions.mapi((i, d) => "usage_15m." + d + " = " + q15_values("x")[i]), " AND ")};
  $|  DELETE FROM usage_15m WHERE records = 0 AND (\{dimensions_list}) IN (SELECT \{joined(q15_values("x"), ", ")} FROM \{q15_staged} x);
)

///|
fn q15_totals_add(r : String, sign : String) -> String {
(
  $|
  $|  INSERT INTO usage_quarter_totals (scope, quarter, calls, tokens) VALUES (\{r}.scope, \{r}.quarter, \{sign}\{r}.calls, \{sign}\{q15_tokens_of(r)})
  $|    ON CONFLICT (scope, quarter) DO UPDATE SET calls = calls + excluded.calls, tokens = tokens + excluded.tokens;
  $|  INSERT INTO usage_scope_totals (scope, calls, tokens) VALUES (\{r}.scope, \{sign}\{r}.calls, \{sign}\{q15_tokens_of(r)})
  $|    ON CONFLICT (scope) DO UPDATE SET calls = calls + excluded.calls, tokens = tokens + excluded.tokens;
)
}

///|
fn q15_totals_clean(r : String) -> String {
(
  $|
  $|  DELETE FROM usage_quarter_totals WHERE scope = \{r}.scope AND quarter = \{r}.quarter
  $|    AND NOT EXISTS (SELECT 1 FROM usage_15m WHERE scope = \{r}.scope AND quarter = \{r}.quarter);
  $|  DELETE FROM usage_scope_totals WHERE scope = \{r}.scope AND NOT EXISTS (SELECT 1 FROM usage_15m WHERE scope = \{r}.scope);
)
}

///|
fn q15_move_session(key : String, ws : String) -> String {
(
  $|UPDATE usage_15m SET scope = COALESCE(\{ws}, '')
  $|  WHERE session = \{key} AND scope <> COALESCE(\{ws}, '');
)
}

///|
/// The staging of a call an INSERT meets and the triggers on `usage` that keep its quarters (usage-15m.ts USAGE_KEPT):
/// made again whole where the metrics grew (`install_usage_15m_gen`).
let usage_15m_kept : String =
(
  $|
  $|-- The call an INSERT is about to meet, as it is, and its workspace: an INSERT OR REPLACE removes it without its DELETE
  $|-- triggers (unless recursive_triggers is on), and the insert's own trigger takes it out of its quarter then, the new
  $|-- call counted where it was. An upsert or an ignored insert leaves it, taken away by the next write.
  $|CREATE TABLE usage_15m_replace (\{joined(staged_columns.map(c => if c == "id" { c + " TEXT PRIMARY KEY" } else { c }), ", ")}, counted INTEGER NOT NULL,
  $|  scope TEXT NOT NULL) WITHOUT ROWID;
  $|
  $|CREATE TRIGGER usage_15m_before_add BEFORE INSERT ON usage
  $|  WHEN EXISTS (SELECT 1 FROM usage_15m_replace) OR EXISTS (SELECT 1 FROM usage WHERE id = NEW.id) BEGIN
  $|  DELETE FROM usage_15m_replace;
  $|  INSERT INTO usage_15m_replace SELECT \{joined(staged_columns, ", ")}, rollup_counted, \{q15_scope_of("usage.session")} FROM usage WHERE id = NEW.id;
  $|END;
  $|CREATE TRIGGER usage_15m_add AFTER INSERT ON usage BEGIN
  $|  \{q15_add("NEW", "NEW.rollup_counted = 1")}
  $|  \{q15_remove_staged}
  $|  DELETE FROM usage_15m_replace;
  $|  UPDATE usage SET rollup_counted = 1 WHERE id = NEW.id AND NEW.rollup_counted = 0;
  $|END;
  $|CREATE TRIGGER usage_15m_change AFTER UPDATE ON usage
  $|  WHEN (OLD.rollup_counted = 1 OR NEW.rollup_counted = 1) AND (OLD.rollup_counted IS NOT NEW.rollup_counted OR \{q15_place_changed}) BEGIN
  $|  \{q15_add("NEW", "NEW.rollup_counted = 1")}
  $|  \{q15_remove("OLD", "OLD.rollup_counted = 1")}
  $|END;
  $|CREATE TRIGGER usage_15m_grow AFTER UPDATE ON usage
  $|  WHEN OLD.rollup_counted = 1 AND NEW.rollup_counted = 1 AND NOT (\{q15_place_changed}) AND (\{q15_values_changed}) BEGIN
  $|  \{q15_adjust}
  $|END;
  $|CREATE TRIGGER usage_15m_updated AFTER UPDATE ON usage WHEN EXISTS (SELECT 1 FROM usage_15m_replace) BEGIN
  $|  DELETE FROM usage_15m_replace;
  $|END;
  $|CREATE TRIGGER usage_15m_drop AFTER DELETE ON usage BEGIN
  $|  \{q15_remove("OLD", "OLD.rollup_counted = 1")}
  $|  -- (an INSERT OR REPLACE's removal, where recursive_triggers is on: taken out here, its workspace kept for the insert)
  $|  UPDATE usage_15m_replace SET counted = 0 WHERE id = OLD.id;
  $|END;
  $|
)

///|
let usage_15m_schema : String =
(
  $|
  $|CREATE TABLE usage_15m (scope TEXT NOT NULL, quarter INTEGER NOT NULL, session TEXT NOT NULL, thread INTEGER NOT NULL,
  $|  person TEXT NOT NULL, profile TEXT NOT NULL, runtime TEXT NOT NULL, model TEXT NOT NULL, fast INTEGER NOT NULL,
  $|  records INTEGER NOT NULL, calls INTEGER NOT NULL, input INTEGER NOT NULL, cache_read INTEGER NOT NULL,
  $|  cache_write INTEGER NOT NULL, cache_write_long INTEGER NOT NULL, output INTEGER NOT NULL,
  $|  PRIMARY KEY (\{dimensions_list})) WITHOUT ROWID;
  $|ALTER TABLE usage_15m ADD COLUMN gen_ms INTEGER NOT NULL DEFAULT 0;
  $|ALTER TABLE usage_15m ADD COLUMN gen_output INTEGER NOT NULL DEFAULT 0;
  $|CREATE INDEX usage_15m_session ON usage_15m (session, scope, quarter);
  $|CREATE INDEX usage_15m_quarter ON usage_15m (quarter, scope);
  $|CREATE TABLE usage_quarter_totals (scope TEXT NOT NULL, quarter INTEGER NOT NULL, calls INTEGER NOT NULL, tokens INTEGER NOT NULL,
  $|  PRIMARY KEY (scope, quarter)) WITHOUT ROWID;
  $|CREATE TABLE usage_scope_totals (scope TEXT PRIMARY KEY, calls INTEGER NOT NULL, tokens INTEGER NOT NULL) WITHOUT ROWID;
  $|-- since: from when every call is counted (ms); NULL, from the first.
  $|CREATE TABLE usage_15m_meta (id INTEGER PRIMARY KEY CHECK (id = 1), since INTEGER);
  $|CREATE TRIGGER usage_15m_totals_add AFTER INSERT ON usage_15m BEGIN \{q15_totals_add("NEW", "")} END;
  $|CREATE TRIGGER usage_15m_totals_grow AFTER UPDATE ON usage_15m WHEN OLD.scope = NEW.scope AND OLD.quarter = NEW.quarter BEGIN
  $|  UPDATE usage_quarter_totals SET calls = calls + NEW.calls - OLD.calls, tokens = tokens + \{q15_tokens_of("NEW")} - \{q15_tokens_of("OLD")}
  $|    WHERE scope = NEW.scope AND quarter = NEW.quarter;
  $|  UPDATE usage_scope_totals SET calls = calls + NEW.calls - OLD.calls, tokens = tokens + \{q15_tokens_of("NEW")} - \{q15_tokens_of("OLD")}
  $|    WHERE scope = NEW.scope;
  $|END;
  $|CREATE TRIGGER usage_15m_totals_move AFTER UPDATE ON usage_15m WHEN OLD.scope <> NEW.scope OR OLD.quarter <> NEW.quarter BEGIN
  $|  \{q15_totals_add("OLD", "-")}
  $|  \{q15_totals_add("NEW", "")}
  $|  \{q15_totals_clean("OLD")}
  $|END;
  $|CREATE TRIGGER usage_15m_totals_drop AFTER DELETE ON usage_15m BEGIN
  $|  \{q15_totals_add("OLD", "-")}
  $|  \{q15_totals_clean("OLD")}
  $|END;
  $|
  $|\{usage_15m_kept}
  $|CREATE TRIGGER usage_15m_session_add AFTER INSERT ON sessions BEGIN \{q15_move_session("NEW.key", "NEW.ws")} END;
  $|CREATE TRIGGER usage_15m_session_move AFTER UPDATE OF key, ws ON sessions
  $|  WHEN OLD.key IS NOT NEW.key OR OLD.ws IS NOT NEW.ws BEGIN \{q15_move_session("NEW.key", "NEW.ws")} END;
  $|
)

///|
pub fn has_usage_15m(db : @sql.Db) -> Bool raise {
  exists(db, "table", "usage_15m_meta")
}

///|
/// The quarters installed in one short write as the store opens, reading no call: a new database counts from its first
/// (since NULL); one with calls already from now (`now`, ms, or past its latest call).
fn install_usage_15m(db : @sql.Db, now : Int64) -> Unit raise {
  if has_usage_15m(db) {
    return
  }
  immediate(db, () => if !has_usage_15m(db) {
    if !columns(db, "usage").contains("rollup_counted") {
      db.exec("ALTER TABLE usage ADD COLUMN rollup_counted INTEGER NOT NULL DEFAULT 0")
    }
    add_gen_columns(db)
    db.exec(usage_15m_schema)
    let old = some_row(db, "SELECT 1 FROM usage LIMIT 1")
    let since = if old {
      let latest = first_row(db, "SELECT MAX(at) AS at FROM usage INDEXED BY usage_at").unwrap().get("at").unwrap()
      let latest = match latest {
        Number(_, repr=Some(text)) => @string.parse_int64(text)
        Number(n, ..) => n.to_int64()
        _ => 0L
      }
      let at = if now > latest + 1L { now } else { latest + 1L }
      Json::number(at.to_double(), repr=at.to_string())
    } else {
      Json::null()
    }
    ignore(db.run("INSERT INTO usage_15m_meta (id, since) VALUES (1, ?)", [since]))
  })
}

///|
/// A call's time taken and what it wrote then (usage-15m.ts `addGenColumns`): 0 where its time is not known.
fn add_gen_columns(db : @sql.Db) -> Unit raise {
  let have = columns(db, "usage")
  if !have.contains("gen_ms") {
    db.exec("ALTER TABLE usage ADD COLUMN gen_ms INTEGER NOT NULL DEFAULT 0")
  }
  if !have.contains("gen_output") {
    db.exec("ALTER TABLE usage ADD COLUMN gen_output INTEGER NOT NULL DEFAULT 0")
  }
}

///|
/// The quarters of a database from before a call's time was kept given its two metrics (usage-15m.ts
/// `installUsage15mGen`), in one short write as the store opens.
fn install_usage_15m_gen(db : @sql.Db) -> Unit raise {
  let done = () => columns(db, "usage_15m").contains("gen_ms")
  if !has_usage_15m(db) || done() {
    return
  }
  immediate(db, () => if !done() {
    add_gen_columns(db)
    db.exec(
      (
        $|ALTER TABLE usage_15m ADD COLUMN gen_ms INTEGER NOT NULL DEFAULT 0;
        $|        ALTER TABLE usage_15m ADD COLUMN gen_output INTEGER NOT NULL DEFAULT 0;
        $|        DROP TRIGGER usage_15m_before_add; DROP TRIGGER usage_15m_add; DROP TRIGGER usage_15m_change; DROP TRIGGER usage_15m_grow;
        $|        DROP TRIGGER usage_15m_updated; DROP TRIGGER usage_15m_drop; DROP TABLE usage_15m_replace;
        $|        \{usage_15m_kept}
      ),
    )
  })
}

///|
let span_first : String = "(SELECT MIN(at) FROM usage INDEXED BY usage_at)"

///|
let span_table : String =
(
  $|
  $|CREATE TABLE IF NOT EXISTS usage_span (id INTEGER PRIMARY KEY CHECK (id = 1), first_at INTEGER);
  $|INSERT OR REPLACE INTO usage_span VALUES (1, \{span_first});
)

///|
let span_triggers : String =
(
  $|
  $|CREATE TRIGGER usage_span_add AFTER INSERT ON usage WHEN
  $|  (SELECT first_at FROM usage_span WHERE id = 1) IS NULL
  $|  OR NEW.at < (SELECT first_at FROM usage_span WHERE id = 1)
  $|  OR NOT EXISTS (SELECT 1 FROM usage INDEXED BY usage_at WHERE at = (SELECT first_at FROM usage_span WHERE id = 1)) BEGIN
  $|  -- REPLACE can remove the earliest conflicting row without firing its delete trigger. Check that it still exists.
  $|  UPDATE usage_span SET first_at = \{span_first} WHERE id = 1;
  $|END;
  $|CREATE TRIGGER usage_span_drop AFTER DELETE ON usage WHEN OLD.at = (SELECT first_at FROM usage_span WHERE id = 1) BEGIN
  $|  UPDATE usage_span SET first_at = \{span_first} WHERE id = 1;
  $|END;
  $|CREATE TRIGGER usage_span_move AFTER UPDATE OF at ON usage WHEN OLD.at <> NEW.at AND
  $|  (OLD.at = (SELECT first_at FROM usage_span WHERE id = 1) OR NEW.at < (SELECT first_at FROM usage_span WHERE id = 1)) BEGIN
  $|  UPDATE usage_span SET first_at = \{span_first} WHERE id = 1;
  $|END;
  $|
)

///|
/// The earliest recorded usage, kept by its triggers (usage-span.ts `installUsageSpan`).
fn install_usage_span(db : @sql.Db) -> Unit raise {
  let installed = () => exists(db, "trigger", "usage_span_add")
  if installed() {
    return
  }
  immediate(db, () => if !installed() {
    db.exec("DROP TRIGGER IF EXISTS usage_span_drop; DROP TRIGGER IF EXISTS usage_span_move; \{span_table} \{span_triggers}")
  })
}

///|
let ucp_keep_new_calls : String =
(
  $|
  $|DROP TRIGGER IF EXISTS usage_compactions_add;
  $|CREATE TRIGGER usage_compactions_add AFTER INSERT ON usage WHEN NEW.subagent = 0 BEGIN
  $|  INSERT OR IGNORE INTO usage_main_calls VALUES (NEW.session, NEW.at, NEW.id, NEW.profile, NEW.model, NEW.context);
  $|  INSERT INTO usage_compactions SELECT at, model, point FROM usage_compaction_events WHERE id = NEW.id;
  $|END;
  $|
)

///|
let usage_compaction_schema : String =
(
  $|
  $|CREATE TABLE usage_main_calls (
  $|  session TEXT NOT NULL, at INTEGER NOT NULL, id TEXT NOT NULL, profile TEXT, model TEXT, context INTEGER,
  $|  PRIMARY KEY (session, at, id)
  $|) WITHOUT ROWID;
  $|CREATE TABLE usage_compaction_events (id TEXT PRIMARY KEY, at INTEGER NOT NULL, model TEXT NOT NULL, point INTEGER NOT NULL) WITHOUT ROWID;
  $|CREATE INDEX usage_compaction_events_at ON usage_compaction_events (at);
  $|CREATE TABLE usage_compaction_backfill (id INTEGER PRIMARY KEY CHECK (id = 1), after_rowid INTEGER, end_rowid INTEGER, done INTEGER NOT NULL);
  $|INSERT INTO usage_compaction_backfill SELECT 1, NULL, MAX(rowid), COUNT(*) = 0 FROM (SELECT rowid FROM usage ORDER BY rowid DESC LIMIT 1);
  $|
  $|CREATE TRIGGER usage_main_calls_add AFTER INSERT ON usage_main_calls BEGIN
  $|  INSERT INTO usage_compaction_events
  $|    SELECT NEW.id, NEW.at, NEW.model, p.context FROM (
  $|      SELECT context, profile, model FROM usage_main_calls
  $|      WHERE session = NEW.session AND (at, id) < (NEW.at, NEW.id) ORDER BY at DESC, id DESC LIMIT 1) p
  $|    WHERE NEW.model IS NOT NULL AND p.context >= \{compacted_from} AND NEW.context * 2 < p.context
  $|      AND p.profile IS NEW.profile AND p.model IS NEW.model;
  $|  DELETE FROM usage_compaction_events WHERE id = (
  $|    SELECT id FROM usage_main_calls WHERE session = NEW.session AND (at, id) > (NEW.at, NEW.id) ORDER BY at, id LIMIT 1);
  $|  INSERT INTO usage_compaction_events
  $|    SELECT n.id, n.at, n.model, NEW.context FROM (
  $|      SELECT id, at, model, profile, context FROM usage_main_calls
  $|      WHERE session = NEW.session AND (at, id) > (NEW.at, NEW.id) ORDER BY at, id LIMIT 1) n
  $|    WHERE n.model IS NOT NULL AND NEW.context >= \{compacted_from} AND n.context * 2 < NEW.context
  $|      AND NEW.profile IS n.profile AND NEW.model IS n.model;
  $|END;
  $|CREATE TRIGGER usage_main_calls_drop AFTER DELETE ON usage_main_calls BEGIN
  $|  DELETE FROM usage_compaction_events WHERE id = OLD.id;
  $|  DELETE FROM usage_compaction_events WHERE id = (
  $|    SELECT id FROM usage_main_calls WHERE session = OLD.session AND (at, id) > (OLD.at, OLD.id) ORDER BY at, id LIMIT 1);
  $|  INSERT INTO usage_compaction_events
  $|    SELECT n.id, n.at, n.model, p.context FROM (
  $|      SELECT id, at, model, profile, context FROM usage_main_calls
  $|      WHERE session = OLD.session AND (at, id) > (OLD.at, OLD.id) ORDER BY at, id LIMIT 1) n,
  $|    (SELECT context, profile, model FROM usage_main_calls
  $|      WHERE session = OLD.session AND (at, id) < (OLD.at, OLD.id) ORDER BY at DESC, id DESC LIMIT 1) p
  $|    WHERE n.model IS NOT NULL AND p.context >= \{compacted_from} AND n.context * 2 < p.context
  $|      AND p.profile IS n.profile AND p.model IS n.model;
  $|END;
  $|CREATE TRIGGER usage_main_calls_usage_drop AFTER DELETE ON usage WHEN OLD.subagent = 0 BEGIN
  $|  DELETE FROM usage_main_calls WHERE session = OLD.session AND at = OLD.at AND id = OLD.id;
  $|END;
  $|CREATE TRIGGER usage_main_calls_usage_change AFTER UPDATE OF id, session, at, profile, model, context, subagent ON usage BEGIN
  $|  DELETE FROM usage_main_calls WHERE OLD.subagent = 0 AND session = OLD.session AND at = OLD.at AND id = OLD.id;
  $|  INSERT OR IGNORE INTO usage_main_calls
  $|    SELECT NEW.session, NEW.at, NEW.id, NEW.profile, NEW.model, NEW.context WHERE NEW.subagent = 0;
  $|END;
  $|\{ucp_keep_new_calls}
  $|
)

///|
/// Not where the contexts are kept (usage-compact.ts), nor where a station from before stopped it in an emergency.
fn compactions_replaced(db : @sql.Db) -> Bool raise {
  has_compact_usage(db) || exists(db, "table", "usage_retired_detail")
}

///|
/// The main calls' index and its compactions: only empty tables and triggers (usage-compactions.ts).
fn install_usage_compactions(db : @sql.Db) -> Unit raise {
  if compactions_replaced(db) {
    return
  }
  let installed = () => exists(db, "table", "usage_compaction_backfill")
  let trigger_current = () => sql_of(db, "trigger", "usage_compactions_add")
    .unwrap_or("")
    .contains("INSERT OR IGNORE INTO usage_main_calls")
  if installed() && trigger_current() {
    return
  }
  immediate(db, () => if !installed() {
    db.exec(usage_compaction_schema)
  } else if !trigger_current() {
    db.exec(ucp_keep_new_calls)
  })
}

///|
let allowances_schema : String =
(
  $|
  $|CREATE TABLE IF NOT EXISTS profile_quota_hours (
  $|  profile TEXT NOT NULL,
  $|  hour INTEGER NOT NULL,
  $|  windows_json TEXT NOT NULL,
  $|  at INTEGER NOT NULL,
  $|  PRIMARY KEY (profile, hour)
  $|) WITHOUT ROWID;
  $|CREATE INDEX IF NOT EXISTS profile_quota_hours_hour ON profile_quota_hours (hour);
  $|
)

///|
/// The allowances' hours (profile-hours.ts `installProfileHours`).
fn install_profile_hours(db : @sql.Db) -> Unit raise {
  db.exec(allowances_schema)
}

///|
/// The counter records from its installation (usage.ts `installUsageCounter`).
fn install_usage_counter(db : @sql.Db, now : Int64) -> Unit raise {
  let had = exists(db, "table", "usage_counter")
  let files = columns(db, "usage_files")
  if had && files.contains("counter_cutoff") && files.contains("counter_anchor") && files.contains("speed") {
    return
  }
  immediate(db, () => {
    db.exec("CREATE TABLE IF NOT EXISTS usage_counter (id INTEGER PRIMARY KEY CHECK (id = 1), since INTEGER NOT NULL, through INTEGER NOT NULL)")
    let at = Json::number(now.to_double(), repr=now.to_string())
    ignore(db.run("INSERT OR IGNORE INTO usage_counter VALUES (1, ?, ?)", [at, at]))
    let current = columns(db, "usage_files")
    if !current.contains("counter_cutoff") {
      db.exec("ALTER TABLE usage_files ADD COLUMN counter_cutoff INTEGER")
    }
    if !current.contains("counter_anchor") {
      db.exec("ALTER TABLE usage_files ADD COLUMN counter_anchor TEXT")
    }
    if !current.contains("speed") {
      db.exec("ALTER TABLE usage_files ADD COLUMN speed TEXT")
    }
  })
}

///|
let changes_columns : Array[String] = [
  "id", "at", "session", "thread", "person", "profile", "runtime", "model", "fast", ..metrics,
]

///|
let changes_list : String = joined(changes_columns, ", ")

///|
let ts_changed : String = joined(changes_columns.map(c => "OLD.\{c} IS NOT NEW.\{c}"), " OR ")

///|
fn ts_bucket(row : String, size : Int) -> String {
  if size == 1 {
    "\{row}.at"
  } else {
(
  $|(CASE WHEN \{row}.at >= 0 THEN \{row}.at / \{size} ELSE -1 - ((-1 - \{row}.at) / \{size}) END)
)
  }
}

///|
fn ts_fields(row : String) -> String {
(
  $|\{row}.session, COALESCE(\{row}.thread, 0), COALESCE(\{row}.person, ''),
  $|  COALESCE(\{row}.profile, ''), \{row}.runtime, COALESCE(\{row}.model, ''), \{row}.fast
)
}

///|
fn ts_key(row : String, level : Int, sizes : Array[Int]) -> String {
(
  $|usage_detail.session = \{row}.session AND usage_detail.level = \{level} AND usage_detail.bucket = \{ts_bucket(row, sizes[level])}
  $|  AND usage_detail.thread = COALESCE(\{row}.thread, 0) AND usage_detail.person = COALESCE(\{row}.person, '') AND usage_detail.profile = COALESCE(\{row}.profile, '')
  $|  AND usage_detail.runtime = \{row}.runtime AND usage_detail.model = COALESCE(\{row}.model, '') AND usage_detail.fast = \{row}.fast
)
}

///|
fn ts_indexed(row : String, live : Bool) -> String {
  let ignored = if live {
(
  $|NOT EXISTS (SELECT 1 FROM usage_detail_ignored WHERE id = \{row}.id) AND 
)
  } else {
    ""
  }
(
  $|\{ignored}EXISTS (SELECT 1 FROM usage_detail_sessions st WHERE st.session = \{row}.session AND
  $|  (st.done = 1 OR (st.after_at IS NOT NULL AND (\{row}.at, \{row}.rowid) <= (st.after_at, st.after_rowid))
  $|    OR (st.end_at IS NOT NULL AND (\{row}.at, \{row}.rowid) > (st.end_at, st.end_rowid))
  $|    OR EXISTS (SELECT 1 FROM usage_detail_seen WHERE id = \{row}.id)))
)
}

///|
fn ts_add(row : String, when : String, sizes : Array[Int]) -> String {
  joined(
    sizes.mapi((level, size) => {
(
  $|
  $|  INSERT INTO usage_detail (session, thread, person, profile, runtime, model, fast, level, bucket, records, \{metrics_list})
  $|    SELECT \{ts_fields(row)}, \{level}, \{ts_bucket(row, size)}, 1, \{each_metric(c => row + "." + c)}
  $|    WHERE \{when}
  $|    ON CONFLICT (session, level, bucket, thread, person, profile, runtime, model, fast) DO UPDATE SET
  $|      records = records + 1, \{each_metric(c => c + " = " + c + " + excluded." + c)};
)
    }),
    "",
  )
}

///|
fn ts_remove(row : String, live : Bool, sizes : Array[Int]) -> String {
  joined(
    sizes.mapi((level, _) => {
(
  $|
  $|  UPDATE usage_detail SET records = records - 1, \{each_metric(c => c + " = " + c + " - " + row + "." + c)}
  $|    WHERE \{ts_key(row, level, sizes)} AND \{ts_indexed(row, live)};
  $|  DELETE FROM usage_detail WHERE \{ts_key(row, level, sizes)} AND records = 0;
)
    }),
    "",
  )
}

///|
fn ts_remove_replaced(live : Bool, sizes : Array[Int]) -> String {
  let id = "NEW.id"
  let removed = if live { " AND x.removed = 0" } else { "" }
  let value = (expression : String) => "(SELECT \{expression} FROM usage_detail_replace x WHERE x.id = \{id} AND x.counted = 1\{removed})"
  let statements = []
  for level, size in sizes {
    let match_ =
(
  $|session = \{value("x.session")} AND level = \{level} AND bucket = \{value(ts_bucket("x", size))}
  $|      AND thread = \{value("COALESCE(x.thread, 0)")} AND person = \{value("COALESCE(x.person, '')")}
  $|      AND profile = \{value("COALESCE(x.profile, '')")} AND runtime = \{value("x.runtime")}
  $|      AND model = \{value("COALESCE(x.model, '')")} AND fast = \{value("x.fast")}
)
    statements.push(
      "UPDATE usage_detail SET records = records - 1, " +
      each_metric(c => c + " = " + c + " - " + value("x." + c)) +
      " WHERE " +
      match_,
    )
    statements.push("DELETE FROM usage_detail WHERE " + match_ + " AND records = 0")
  }
  joined(statements.map(sql => sql + ";"), "\n")
}

///|
fn ts_ensure_session(row : String, when : String) -> String {
(
  $|
  $|  INSERT INTO usage_detail_sessions
  $|    SELECT \{row}.session, NULL, NULL,
  $|      (SELECT at FROM usage WHERE session = \{row}.session ORDER BY at DESC, rowid DESC LIMIT 1),
  $|      (SELECT rowid FROM usage WHERE session = \{row}.session ORDER BY at DESC, rowid DESC LIMIT 1),
  $|      NOT EXISTS (SELECT 1 FROM usage WHERE session = \{row}.session AND id <> \{row}.id LIMIT 1)
  $|    WHERE (\{when}) AND NOT EXISTS (SELECT 1 FROM usage_detail_sessions WHERE session = \{row}.session);
  $|  INSERT INTO usage_detail_seen SELECT \{row}.id FROM usage_detail_sessions st
  $|    WHERE (\{when}) AND st.session = \{row}.session AND st.done = 0
  $|      AND (st.after_at IS NULL OR (\{row}.at, \{row}.rowid) > (st.after_at, st.after_rowid))
  $|      AND (\{row}.at, \{row}.rowid) <= (st.end_at, st.end_rowid)
  $|      AND NOT EXISTS (SELECT 1 FROM usage_detail_seen WHERE id = \{row}.id);
  $|  INSERT INTO usage_detail_scope SELECT \{row}.session, (SELECT ws FROM sessions WHERE key = \{row}.session),
  $|    (SELECT done FROM usage_detail_sessions WHERE session = \{row}.session) WHERE \{when}
  $|    ON CONFLICT (session) DO UPDATE SET ws = excluded.ws, done = excluded.done;
)
}

///|
fn ts_scope(ws : String) -> String {
(
  $|(CASE WHEN \{ws} IS NULL THEN 'H' ELSE 'W' || \{ws} END)
)
}

///|
fn ts_dirty(session : String, old_ws : String, new_ws : String, when : String) -> String {
(
  $|
  $|  INSERT INTO usage_detail_dirty SELECT \{session}, NULL, NULL
  $|    WHERE (\{when}) AND EXISTS (SELECT 1 FROM usage_detail_lookup WHERE session = \{session})
  $|    ON CONFLICT (session) DO UPDATE SET after_level = NULL, after_bucket = NULL;
  $|  INSERT INTO usage_detail_dirty_scope SELECT \{session}, \{ts_scope(old_ws)}
  $|    WHERE (\{when}) AND EXISTS (SELECT 1 FROM usage_detail_dirty WHERE session = \{session})
  $|      AND NOT EXISTS (SELECT 1 FROM usage_detail_dirty_scope WHERE session = \{session} AND scope = \{ts_scope(old_ws)});
  $|  INSERT INTO usage_detail_dirty_scope SELECT \{session}, \{ts_scope(new_ws)}
  $|    WHERE (\{when}) AND EXISTS (SELECT 1 FROM usage_detail_dirty WHERE session = \{session})
  $|      AND NOT EXISTS (SELECT 1 FROM usage_detail_dirty_scope WHERE session = \{session} AND scope = \{ts_scope(new_ws)});
)
}

///|
/// The per-call detail's schema (usage-totals-source.ts `schema`), as the totals' source takes it: `live`, of `sizes`.
fn ts_schema(live : Bool, sizes : Array[Int]) -> String {
  let ignored_table = if live { "CREATE TABLE usage_detail_ignored (id TEXT PRIMARY KEY) WITHOUT ROWID;" } else { "" }
  let update_table = if live {
    "CREATE TABLE usage_detail_update (id TEXT PRIMARY KEY, counted INTEGER NOT NULL) WITHOUT ROWID;"
  } else {
    ""
  }
  let removed_column = if live { ", removed INTEGER NOT NULL" } else { "" }
  let token_dirty = ts_dirty(
    "(SELECT key FROM sessions WHERE token = NEW.token)",
    "(SELECT ws FROM sessions WHERE token = NEW.token)",
    "NULL",
    "(SELECT ws FROM sessions WHERE token = NEW.token) IS NOT NULL",
  )
  let new_dirty = ts_dirty(
    "NEW.key",
    "(SELECT ws FROM usage_detail_scope WHERE session = NEW.key)",
    "NEW.ws",
    "EXISTS (SELECT 1 FROM usage_detail_scope WHERE session = NEW.key AND ws IS NOT NEW.ws)",
  )
  let scope_source = if live { "usage_detail_lookup" } else { "usage" }
  let zero = if live { ", 0" } else { "" }
  let ignored_add = if live {
(
  $|DELETE FROM usage_detail_ignored WHERE id = NEW.id
  $|    AND NOT EXISTS (SELECT 1 FROM usage_detail_replace WHERE id = NEW.id AND counted = 0);
  $|  INSERT INTO usage_detail_ignored SELECT NEW.id
  $|    WHERE EXISTS (SELECT 1 FROM usage_detail_replace WHERE id = NEW.id AND counted = 0)
  $|      AND NOT EXISTS (SELECT 1 FROM usage_detail_ignored WHERE id = NEW.id);
)
  } else {
    ""
  }
  let replace_before = if live { "" } else { "DELETE FROM usage_detail_replace;" }
  let inserted = if live { "NOT EXISTS (SELECT 1 FROM usage_detail_replace WHERE id = NEW.id AND counted = 0)" } else { "1" }
  let replace_after = if live { "DELETE FROM usage_detail_replace;" } else { "" }
  let ignored_drop = if live {
    "DELETE FROM usage_detail_ignored WHERE id = OLD.id AND NOT EXISTS (SELECT 1 FROM usage_detail_replace WHERE id = OLD.id);"
  } else {
    ""
  }
  let replace_drop = if live {
    "UPDATE usage_detail_replace SET removed = 1 WHERE id = OLD.id;"
  } else {
    "DELETE FROM usage_detail_replace WHERE id = OLD.id;"
  }
  let update_stage = if live {
(
  $|DELETE FROM usage_detail_update;
  $|  INSERT INTO usage_detail_update VALUES (OLD.id, \{ts_indexed("OLD", true)});
)
  } else {
    ""
  }
  let seen_drop = if live { "" } else { "DELETE FROM usage_detail_seen WHERE id = OLD.id;" }
  let changed_ignored = if live {
(
  $|DELETE FROM usage_detail_seen WHERE id = OLD.id;
  $|  DELETE FROM usage_detail_ignored WHERE id = OLD.id AND OLD.id IS NOT NEW.id;
  $|  DELETE FROM usage_detail_ignored WHERE id = NEW.id AND EXISTS (SELECT 1 FROM usage_detail_update WHERE counted = 1);
  $|  INSERT INTO usage_detail_ignored SELECT NEW.id
  $|    WHERE EXISTS (SELECT 1 FROM usage_detail_update WHERE counted = 0)
  $|      AND NOT EXISTS (SELECT 1 FROM usage_detail_ignored WHERE id = NEW.id);
)
  } else {
    ""
  }
  let counted = if live { "EXISTS (SELECT 1 FROM usage_detail_update WHERE counted = 1)" } else { "1" }
  let update_clear = if live { "DELETE FROM usage_detail_update;" } else { "" }
(
  $|
  $|CREATE TABLE usage_detail (
  $|  session TEXT NOT NULL, thread INTEGER NOT NULL, person TEXT NOT NULL, profile TEXT NOT NULL,
  $|  runtime TEXT NOT NULL, model TEXT NOT NULL, fast INTEGER NOT NULL, level INTEGER NOT NULL, bucket INTEGER NOT NULL,
  $|  records INTEGER NOT NULL, calls INTEGER NOT NULL, input INTEGER NOT NULL, cache_read INTEGER NOT NULL,
  $|  cache_write INTEGER NOT NULL, cache_write_long INTEGER NOT NULL, output INTEGER NOT NULL,
  $|  PRIMARY KEY (session, level, bucket, thread, person, profile, runtime, model, fast)
  $|) WITHOUT ROWID;
  $|CREATE TABLE usage_detail_scope (session TEXT PRIMARY KEY, ws TEXT, done INTEGER NOT NULL) WITHOUT ROWID;
  $|CREATE INDEX usage_detail_scope_ws ON usage_detail_scope (ws, done, session);
  $|CREATE TABLE usage_detail_lookup (session TEXT NOT NULL, level INTEGER NOT NULL, bucket INTEGER NOT NULL, scope TEXT NOT NULL,
  $|  PRIMARY KEY (session, level, bucket)) WITHOUT ROWID;
  $|CREATE INDEX usage_detail_lookup_scope ON usage_detail_lookup (scope, level, bucket, session);
  $|CREATE INDEX usage_detail_lookup_time ON usage_detail_lookup (level, bucket, session);
  $|CREATE TABLE usage_detail_dirty (session TEXT PRIMARY KEY, after_level INTEGER, after_bucket INTEGER) WITHOUT ROWID;
  $|CREATE TABLE usage_detail_dirty_scope (session TEXT NOT NULL, scope TEXT NOT NULL, PRIMARY KEY (session, scope)) WITHOUT ROWID;
  $|CREATE INDEX usage_detail_dirty_by_scope ON usage_detail_dirty_scope (scope, session);
  $|CREATE TABLE usage_detail_sessions (session TEXT PRIMARY KEY, after_at INTEGER, after_rowid INTEGER,
  $|  end_at INTEGER, end_rowid INTEGER, done INTEGER NOT NULL) WITHOUT ROWID;
  $|CREATE TABLE usage_detail_seen (id TEXT PRIMARY KEY) WITHOUT ROWID;
  $|\{ignored_table}
  $|\{update_table}
  $|CREATE TABLE usage_detail_replace (id TEXT PRIMARY KEY, at INTEGER NOT NULL, session TEXT NOT NULL, thread INTEGER,
  $|  person TEXT, profile TEXT, runtime TEXT NOT NULL, model TEXT, fast INTEGER NOT NULL, calls INTEGER NOT NULL,
  $|  input INTEGER NOT NULL, cache_read INTEGER NOT NULL, cache_write INTEGER NOT NULL, cache_write_long INTEGER NOT NULL,
  $|  output INTEGER NOT NULL, counted INTEGER NOT NULL\{removed_column}) WITHOUT ROWID;
  $|CREATE TABLE usage_detail_ready (ws TEXT PRIMARY KEY) WITHOUT ROWID;
  $|CREATE TABLE usage_detail_all (id INTEGER PRIMARY KEY CHECK (id = 1), after_session TEXT, done INTEGER NOT NULL);
  $|INSERT INTO usage_detail_all VALUES (1, NULL, NOT EXISTS (SELECT 1 FROM usage LIMIT 1));
  $|
  $|CREATE TRIGGER usage_detail_bucket_add AFTER INSERT ON usage_detail BEGIN
  $|  INSERT INTO usage_detail_lookup SELECT NEW.session, NEW.level, NEW.bucket,
  $|    \{ts_scope("(SELECT ws FROM sessions WHERE key = NEW.session)")}
  $|    WHERE NOT EXISTS (SELECT 1 FROM usage_detail_lookup WHERE session = NEW.session AND level = NEW.level AND bucket = NEW.bucket);
  $|END;
  $|CREATE TRIGGER usage_detail_bucket_drop AFTER DELETE ON usage_detail BEGIN
  $|  DELETE FROM usage_detail_lookup WHERE session = OLD.session AND level = OLD.level AND bucket = OLD.bucket
  $|    AND NOT EXISTS (SELECT 1 FROM usage_detail WHERE session = OLD.session AND level = OLD.level AND bucket = OLD.bucket);
  $|END;
  $|CREATE TRIGGER usage_detail_session_token_add BEFORE INSERT ON sessions
  $|  WHEN EXISTS (SELECT 1 FROM sessions WHERE token = NEW.token AND key <> NEW.key) BEGIN
  $|  \{token_dirty}
  $|  UPDATE usage_detail_scope SET ws = NULL WHERE session = (SELECT key FROM sessions WHERE token = NEW.token AND key <> NEW.key);
  $|END;
  $|CREATE TRIGGER usage_detail_session_token_change BEFORE UPDATE OF token ON sessions
  $|  WHEN OLD.token IS NOT NEW.token AND EXISTS (SELECT 1 FROM sessions WHERE token = NEW.token AND key <> NEW.key) BEGIN
  $|  \{token_dirty}
  $|  UPDATE usage_detail_scope SET ws = NULL WHERE session = (SELECT key FROM sessions WHERE token = NEW.token AND key <> NEW.key);
  $|END;
  $|CREATE TRIGGER usage_detail_session_add AFTER INSERT ON sessions BEGIN
  $|  \{new_dirty}
  $|  INSERT INTO usage_detail_sessions SELECT NEW.key, NULL, NULL,
  $|    (SELECT at FROM usage WHERE session = NEW.key ORDER BY at DESC, rowid DESC LIMIT 1),
  $|    (SELECT rowid FROM usage WHERE session = NEW.key ORDER BY at DESC, rowid DESC LIMIT 1),
  $|    NOT EXISTS (SELECT 1 FROM usage WHERE session = NEW.key LIMIT 1)
  $|    WHERE NOT EXISTS (SELECT 1 FROM usage_detail_sessions WHERE session = NEW.key);
  $|  INSERT INTO usage_detail_scope SELECT NEW.key, NEW.ws, done FROM usage_detail_sessions WHERE session = NEW.key
  $|    AND EXISTS (SELECT 1 FROM \{scope_source} WHERE session = NEW.key LIMIT 1)
  $|    ON CONFLICT (session) DO UPDATE SET ws = excluded.ws, done = excluded.done;
  $|END;
  $|CREATE TRIGGER usage_detail_session_move AFTER UPDATE OF key, ws ON sessions BEGIN
  $|  \{ts_dirty("OLD.key", "OLD.ws", "NULL", "OLD.key IS NOT NEW.key AND OLD.ws IS NOT NULL")}
  $|  UPDATE usage_detail_scope SET ws = NULL WHERE session = OLD.key AND OLD.key IS NOT NEW.key;
  $|  \{new_dirty}
  $|  INSERT INTO usage_detail_sessions SELECT NEW.key, NULL, NULL,
  $|    (SELECT at FROM usage WHERE session = NEW.key ORDER BY at DESC, rowid DESC LIMIT 1),
  $|    (SELECT rowid FROM usage WHERE session = NEW.key ORDER BY at DESC, rowid DESC LIMIT 1),
  $|    NOT EXISTS (SELECT 1 FROM usage WHERE session = NEW.key LIMIT 1)
  $|    WHERE NOT EXISTS (SELECT 1 FROM usage_detail_sessions WHERE session = NEW.key);
  $|  INSERT INTO usage_detail_scope SELECT NEW.key, NEW.ws, done FROM usage_detail_sessions WHERE session = NEW.key
  $|    AND EXISTS (SELECT 1 FROM \{scope_source} WHERE session = NEW.key LIMIT 1)
  $|    ON CONFLICT (session) DO UPDATE SET ws = excluded.ws, done = excluded.done;
  $|END;
  $|CREATE TRIGGER usage_detail_session_drop AFTER DELETE ON sessions BEGIN
  $|  \{ts_dirty("OLD.key", "OLD.ws", "NULL", "OLD.ws IS NOT NULL")}
  $|  UPDATE usage_detail_scope SET ws = NULL WHERE session = OLD.key;
  $|END;
  $|CREATE TRIGGER usage_detail_before_add BEFORE INSERT ON usage
  $|  WHEN EXISTS (SELECT 1 FROM usage WHERE id = NEW.id) OR EXISTS (SELECT 1 FROM usage_detail_replace) BEGIN
  $|  DELETE FROM usage_detail_replace;
  $|  INSERT INTO usage_detail_replace SELECT u.id, u.at, u.session, u.thread, u.person, u.profile, u.runtime, u.model, u.fast,
  $|    u.calls, u.input, u.cache_read, u.cache_write, u.cache_write_long, u.output, \{ts_indexed("u", live)}\{zero}
  $|    FROM usage u WHERE u.id = NEW.id;
  $|END;
  $|CREATE TRIGGER usage_detail_add AFTER INSERT ON usage BEGIN
  $|  \{ts_remove_replaced(live, sizes)}
  $|  DELETE FROM usage_detail_seen WHERE id IN (SELECT id FROM usage_detail_replace WHERE id = NEW.id);
  $|  \{ignored_add}
  $|  \{replace_before}
  $|  \{ts_ensure_session("NEW", inserted)}
  $|  \{ts_add("NEW", inserted, sizes)}
  $|  \{replace_after}
  $|END;
  $|CREATE TRIGGER usage_detail_drop BEFORE DELETE ON usage BEGIN
  $|  \{ts_remove("OLD", live, sizes)}
  $|  DELETE FROM usage_detail_seen WHERE id = OLD.id;
  $|  \{ignored_drop}
  $|  \{replace_drop}
  $|END;
  $|CREATE TRIGGER usage_detail_change BEFORE UPDATE OF \{changes_list} ON usage WHEN \{ts_changed} BEGIN
  $|  \{update_stage}
  $|  \{ts_remove("OLD", live, sizes)}
  $|  \{seen_drop}
  $|END;
  $|CREATE TRIGGER usage_detail_changed AFTER UPDATE OF \{changes_list} ON usage
  $|  WHEN (\{ts_changed}) BEGIN
  $|  DELETE FROM usage_detail_replace WHERE id = NEW.id;
  $|  \{changed_ignored}
  $|  \{ts_ensure_session("NEW", counted)}
  $|  \{ts_add("NEW", counted, sizes)}
  $|  \{update_clear}
  $|END;
  $|CREATE TRIGGER usage_detail_unchanged AFTER UPDATE ON usage WHEN NOT (\{ts_changed}) BEGIN
  $|  DELETE FROM usage_detail_replace WHERE id = NEW.id;
  $|END;
  $|
)
}

///|
/// `/\busage_detail(?=_|\b)/g` replaced by `to`: each usage_detail not inside a longer word.
fn renamed_detail(sql : String, to : String) -> String {
  let word = (c : Char) => (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_'
  let chars = sql.to_array()
  let name = "usage_detail".to_array()
  let out = StringBuilder()
  let mut i = 0
  while i < chars.length() {
    let mut matches = i + name.length() <= chars.length() && (i == 0 || !word(chars[i - 1]))
    if matches {
      for j, c in name {
        if chars[i + j] != c {
          matches = false
          break
        }
      }
    }
    if matches {
      let after = i + name.length()
      matches = after == chars.length() || chars[after] == '_' || !word(chars[after])
    }
    if matches {
      out.write_string(to)
      i += name.length()
    } else {
      out.write_char(chars[i])
      i += 1
    }
  }
  out.to_string()
}

///|
/// An old database without session totals: a separate, empty source of one bucket level that follows later writes
/// (usage-totals-source.ts `installIncrementalUsageTotals`).
fn install_incremental_usage_totals(db : @sql.Db) -> Unit raise {
  let has_table = (name : String) => exists(db, "table", name)
  if !has_table("usage_totals_incremental") || has_table("usage_totals_source_all") {
    return
  }
  immediate(db, () => if !has_table("usage_totals_source_all") {
    db.exec(renamed_detail(ts_schema(true, [900000]), "usage_totals_source"))
    let keep_context = if some_row(db, "SELECT 1 FROM pragma_table_info('usage_totals') WHERE name = 'compact_context'") {
      " AND compact_context IS NULL"
    } else {
      ""
    }
    db.exec(
(
  $|UPDATE usage_totals_source_all SET done = 1 WHERE id = 1;
  $|        CREATE TRIGGER usage_totals_source_aggregate_add AFTER INSERT ON usage_totals_source BEGIN
  $|          INSERT INTO usage_totals (session, runtime, model, fast, calls, input, cache_read, cache_write, cache_write_long, output)
  $|          VALUES (NEW.session, NEW.runtime, NEW.model, NEW.fast, NEW.calls, NEW.input,
  $|            NEW.cache_read, NEW.cache_write, NEW.cache_write_long, NEW.output)
  $|          ON CONFLICT (session, runtime, model, fast) DO UPDATE SET
  $|            calls = calls + excluded.calls, input = input + excluded.input, cache_read = cache_read + excluded.cache_read,
  $|            cache_write = cache_write + excluded.cache_write, cache_write_long = cache_write_long + excluded.cache_write_long,
  $|            output = output + excluded.output;
  $|        END;
  $|        CREATE TRIGGER usage_totals_source_aggregate_change AFTER UPDATE ON usage_totals_source BEGIN
  $|          UPDATE usage_totals SET calls = calls + NEW.calls - OLD.calls, input = input + NEW.input - OLD.input,
  $|            cache_read = cache_read + NEW.cache_read - OLD.cache_read, cache_write = cache_write + NEW.cache_write - OLD.cache_write,
  $|            cache_write_long = cache_write_long + NEW.cache_write_long - OLD.cache_write_long, output = output + NEW.output - OLD.output
  $|            WHERE session = OLD.session AND runtime = OLD.runtime AND model = OLD.model AND fast = OLD.fast;
  $|          DELETE FROM usage_totals WHERE session = OLD.session AND runtime = OLD.runtime AND model = OLD.model AND fast = OLD.fast
  $|            AND calls = 0 AND input = 0 AND cache_read = 0 AND cache_write = 0 AND cache_write_long = 0 AND output = 0\{keep_context};
  $|        END;
  $|        CREATE TRIGGER usage_totals_source_aggregate_drop AFTER DELETE ON usage_totals_source BEGIN
  $|          UPDATE usage_totals SET calls = calls - OLD.calls, input = input - OLD.input, cache_read = cache_read - OLD.cache_read,
  $|            cache_write = cache_write - OLD.cache_write, cache_write_long = cache_write_long - OLD.cache_write_long, output = output - OLD.output
  $|            WHERE session = OLD.session AND runtime = OLD.runtime AND model = OLD.model AND fast = OLD.fast;
  $|          DELETE FROM usage_totals WHERE session = OLD.session AND runtime = OLD.runtime AND model = OLD.model AND fast = OLD.fast
  $|            AND calls = 0 AND input = 0 AND cache_read = 0 AND cache_write = 0 AND cache_write_long = 0 AND output = 0\{keep_context};
  $|        END;
)
    )
  })
}

///|
fn uc_invalidate_context(session : String, when? : String = "1") -> String {
(
  $|
  $|  UPDATE usage_totals SET compact_context = NULL WHERE session = \{session} AND (\{when})
  $|    AND (runtime, model, fast) = (SELECT context_runtime, context_model, context_fast FROM usage_minute_scope WHERE session = \{session})
  $|    AND compact_context IS NOT NULL;
  $|  UPDATE usage_minute_scope SET context_runtime = NULL, context_model = NULL, context_fast = NULL, context_uncertain = 1,
  $|    context_after = (SELECT at FROM usage INDEXED BY usage_session WHERE session = \{session} ORDER BY at DESC LIMIT 1)
  $|    WHERE session = \{session} AND (\{when});
)
}

///|
let uc_context_columns : Array[String] = [
  "id", "at", "session", "turn", "profile", "runtime", "model", "subagent", "fast", "context", "context_window", "cache_write",
  "cache_write_long",
]

///|
let uc_context_changed : String = joined(uc_context_columns.map(c => "OLD.\{c} IS NOT NEW.\{c}"), " OR ")

///|
let context_kept : String =
(
  $|
  $|-- A call another writer recorded (one that does not keep the context) may be the session's latest.
  $|CREATE TRIGGER usage_context_old_add AFTER INSERT ON usage WHEN NEW.compact_counted = 0 AND NEW.subagent = 0 BEGIN
  $|  INSERT INTO usage_minute_scope (session, ws, done) SELECT NEW.session, (SELECT ws FROM sessions WHERE key = NEW.session), 1
  $|    WHERE NOT EXISTS (SELECT 1 FROM usage_minute_scope WHERE session = NEW.session);
  $|  \{uc_invalidate_context("NEW.session")}
  $|END;
  $|-- An insert that meets a main call already there (an INSERT OR REPLACE, an upsert) may change it without a DELETE or
  $|-- UPDATE trigger: the context cannot tell, so it is left uncertain. The station's writers update a call in place.
  $|CREATE TRIGGER usage_context_meet BEFORE INSERT ON usage WHEN EXISTS (SELECT 1 FROM usage WHERE id = NEW.id AND subagent = 0) BEGIN
  $|  \{uc_invalidate_context("NEW.session")}
  $|  \{uc_invalidate_context("(SELECT session FROM usage WHERE id = NEW.id)")}
  $|END;
  $|-- A bounded tail cannot reconstruct a removed or edited main call. Stop presenting the old context as current; later
  $|-- main calls build a new tail without reading the history.
  $|CREATE TRIGGER usage_context_drop AFTER DELETE ON usage WHEN OLD.subagent = 0 BEGIN
  $|  \{uc_invalidate_context("OLD.session")}
  $|END;
  $|CREATE TRIGGER usage_context_change AFTER UPDATE OF \{joined(uc_context_columns, ", ")} ON usage
  $|  WHEN (OLD.subagent = 0 OR NEW.subagent = 0) AND (\{uc_context_changed}) BEGIN
  $|  \{uc_invalidate_context("OLD.session")}
  $|  \{uc_invalidate_context("NEW.session")}
  $|END;
)

///|
/// Whether the contexts are kept (usage-compact.ts `hasCompactUsage`).
pub fn has_compact_usage(db : @sql.Db) -> Bool raise {
  some_row(db, "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name IN ('usage_contexts', 'usage_compact_since') LIMIT 1")
}

///|
/// Where `word` (ASCII, any case) is at `at` of `chars`.
fn word_at(chars : Array[Char], at : Int, word : String) -> Bool {
  let w = word.to_array()
  if at + w.length() > chars.length() {
    return false
  }
  for i, c in w {
    if lower(chars[at + i]) != lower(c) {
      return false
    }
  }
  true
}

///|
fn lower(c : Char) -> Char {
  if c >= 'A' && c <= 'Z' {
    Int::unsafe_to_char(c.to_int() + 32)
  } else {
    c
  }
}

///|
/// JavaScript's `\s`.
fn js_white(c : Char) -> Bool {
  js_space(c)
}

///|
/// Where, from `at`, the words `words` follow one another with white space between (at least one where `gaps[i]`),
/// the end of what matched; None where they do not.
fn words_at(chars : Array[Char], at : Int, words : Array[String], gaps : Array[Bool]) -> Int? {
  let mut p = at
  for i, w in words {
    if i > 0 {
      let start = p
      while p < chars.length() && js_white(chars[p]) {
        p += 1
      }
      if gaps[i - 1] && p == start {
        return None
      }
    }
    if !word_at(chars, p, w) {
      return None
    }
    p += w.to_array().length()
  }
  Some(p)
}

///|
/// Whether a word character (`\w`) is at `at`.
fn word_char_at(chars : Array[Char], at : Int) -> Bool {
  at < chars.length() &&
  {
    let c = chars[at]
    (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_'
  }
}

///|
/// An older positional totals INSERT given its columns, and a totals DELETE kept off a row that owns a context
/// (usage-compact.ts `adaptTotalsWriters`).
fn adapt_totals_writers(db : @sql.Db) -> Unit raise {
  for name in [
    "usage_totals_add", "usage_totals_source_aggregate_add", "usage_totals_source_aggregate_change", "usage_totals_source_aggregate_drop",
  ] {
    guard sql_of(db, "trigger", name) is Some(original) else { continue }
    let mut sql = original
    let chars = sql.to_array()
    if name.has_suffix("_add") {
      // /INSERT\s+INTO\s+usage_totals\s+VALUES\s*\(/i, its first match
      let mut replaced = None
      for at = 0; at < chars.length(); at = at + 1 {
        match words_at(chars, at, ["INSERT", "INTO", "usage_totals", "VALUES"], [true, true, true]) {
          Some(end) => {
            let mut p = end
            while p < chars.length() && js_white(chars[p]) {
              p += 1
            }
            if p < chars.length() && chars[p] == '(' {
              replaced = Some((at, p + 1))
              break
            }
          }
          None => ()
        }
      }
      if replaced is Some((from, to)) {
        sql = String::from_array(chars[0:from]) +
          "INSERT INTO usage_totals (session, runtime, model, fast, calls, input, cache_read, cache_write, cache_write_long, output) VALUES (" +
          String::from_array(chars[to:])
      }
      // /INSERT\s+INTO\s+usage_totals\s*\(/i
      let now = sql.to_array()
      let mut named = false
      for at = 0; at < now.length(); at = at + 1 {
        if words_at(now, at, ["INSERT", "INTO", "usage_totals"], [true, true]) is Some(end) {
          let mut p = end
          while p < now.length() && js_white(now[p]) {
            p += 1
          }
          if p < now.length() && now[p] == '(' {
            named = true
            break
          }
        }
      }
      if !named {
        refuse("cannot adapt \{name}")
      }
    } else {
      // /DELETE\s+FROM\s+usage_totals\b[^;]*;/i, its first match
      let mut found = None
      for at = 0; at < chars.length(); at = at + 1 {
        if words_at(chars, at, ["DELETE", "FROM", "usage_totals"], [true, true]) is Some(end) && !word_char_at(chars, end) {
          let mut p = end
          while p < chars.length() && chars[p] != ';' {
            p += 1
          }
          if p < chars.length() {
            found = Some((at, p + 1))
            break
          }
        }
      }
      guard found is Some((from, to)) else { refuse("cannot adapt \{name}") }
      let statement = String::from_array(chars[from:to])
      // /\bcompact_context\b/i
      let st = statement.to_array()
      let mut mentions = false
      for at = 0; at < st.length(); at = at + 1 {
        if (at == 0 || !word_char_at(st, at - 1)) &&
          word_at(st, at, "compact_context") &&
          !word_char_at(st, at + "compact_context".length()) {
          mentions = true
          break
        }
      }
      if !mentions {
        sql = String::from_array(chars[0:from]) +
          String::from_array(chars[from:to - 1]) +
          " AND compact_context IS NULL;" +
          String::from_array(chars[to:])
      }
    }
    if sql != original {
      db.exec("DROP TRIGGER \"\{name}\"; \{sql}")
    }
  }
}

///|
/// The contexts kept from now on, once the station before has gone (usage-compact.ts `installCompactUsage`, run by
/// usage/module.ts after the store opened): no old call read; the triggers of the minute statistics that kept them
/// before, and of the main-call index they replace, go in the same write.
pub fn install_compact_usage(db : @sql.Db) -> Unit raise {
  if exists(db, "table", "usage_contexts") {
    return
  }
  immediate(db, () => if !exists(db, "table", "usage_contexts") {
    if !columns(db, "usage").contains("compact_counted") {
      db.exec("ALTER TABLE usage ADD COLUMN compact_counted INTEGER NOT NULL DEFAULT 0")
    }
    if !columns(db, "usage_totals").contains("compact_context") {
      db.exec("ALTER TABLE usage_totals ADD COLUMN compact_context TEXT")
    }
    db.exec(
(
  $|CREATE TABLE IF NOT EXISTS usage_minute_scope (session TEXT PRIMARY KEY, ws TEXT, done INTEGER NOT NULL) WITHOUT ROWID;
  $|        CREATE INDEX IF NOT EXISTS usage_minute_scope_ws ON usage_minute_scope (ws, done, session);
)
    )
    let scope = columns(db, "usage_minute_scope")
    for column in [
      ("context_runtime", "TEXT"),
      ("context_model", "TEXT"),
      ("context_fast", "INTEGER"),
      ("context_uncertain", "INTEGER NOT NULL DEFAULT 0"),
      ("context_after", "INTEGER"),
    ] {
      let (name, kind) = column
      if !scope.contains(name) {
        db.exec("ALTER TABLE usage_minute_scope ADD COLUMN \{name} \{kind}")
      }
    }
    let triggers = db.all(
(
  $|SELECT name FROM sqlite_master WHERE type = 'trigger' AND
  $|        (name LIKE 'usage_main_calls_%' OR name = 'usage_compactions_add' OR name IN ('usage_compact_legacy_insert',
  $|          'usage_compact_no_replace', 'usage_compact_context_drop', 'usage_compact_context_old_add', 'usage_compact_context_change'))
)
      , [],
    )
    for t in triggers {
      if t.get("name") is Some(String(name)) {
        db.exec("DROP TRIGGER \"\{name.replace_all(old="\"", new="\"\"")}\"")
      }
    }
    db.exec(context_kept)
    adapt_totals_writers(db)
    db.exec("CREATE TABLE usage_contexts (id INTEGER PRIMARY KEY CHECK (id = 1)); INSERT INTO usage_contexts VALUES (1);")
  })
}

///|
let retired_tables : String =
(
  $|(name = 'usage_detail' OR name GLOB 'usage_detail_*' OR name = 'usage_main_calls'
  $|  OR name = 'usage_minute' OR name IN ('usage_minute_all', 'usage_minute_seen', 'usage_minute_sessions')
  $|  OR name IN ('usage_day_quarters', 'usage_quarters') OR name = 'usage_compact' OR name GLOB 'usage_compact_*'
  $|  OR name GLOB 'usage_summary_*' OR name = 'usage_history' OR name GLOB 'usage_history_*' OR name = 'usage_retired_detail')
)

///|
let retired_triggers : String =
(
  $|(name GLOB 'usage_detail_*' OR name GLOB 'usage_daily_detail_*' OR name GLOB 'usage_main_calls_*'
  $|  OR name = 'usage_compactions_add' OR name GLOB 'usage_minute_*' OR name GLOB 'usage_quarters_*'
  $|  OR name GLOB 'usage_compact_*' OR name GLOB 'usage_summary_*' OR name GLOB 'usage_history_*')
)

///|
/// Whether the writers of the old statistics are stopped (usage-retire.ts `usageIndexesStopped`).
pub fn usage_indexes_stopped(db : @sql.Db) -> Bool raise {
  !some_row(db, "SELECT 1 FROM sqlite_master WHERE type = 'trigger' AND \{retired_triggers} LIMIT 1")
}

///|
/// The old statistics' writers stopped, all in one write, once the station before has gone (`stopUsageIndexes`).
pub fn stop_usage_indexes(db : @sql.Db) -> Unit raise {
  if usage_indexes_stopped(db) {
    return
  }
  immediate(db, () => {
    let triggers = db.all("SELECT name FROM sqlite_master WHERE type = 'trigger' AND \{retired_triggers}", [])
    for t in triggers {
      if t.get("name") is Some(String(name)) {
        db.exec("DROP TRIGGER \"\{name.replace_all(old="\"", new="\"\"")}\"")
      }
    }
  })
}

///|
/// Whether a retired table is still to be freed (`usageIndexesLeft`).
pub fn usage_indexes_left(db : @sql.Db) -> Bool raise {
  some_row(db, "SELECT 1 FROM sqlite_master WHERE type = 'table' AND \{retired_tables} LIMIT 1")
}
