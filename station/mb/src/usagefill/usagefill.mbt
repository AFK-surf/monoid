// What the station does once the previous station has left its usage statistics (station/src/usage/module.ts
// `retireAfterPrevious`): the statistics of before the quarters freed in bounded deletes (test/reference/backfill/usage-retire.ts
// `dropUsageIndexStep`), then the calls from before the quarters began taken in, newest first, whole quarters at a time
// (test/reference/backfill/usage-retire.ts `fillUsage15mStep`), here for the MoonBit builder; and the chats of the
// sessions that moved between workspaces given their new workspace (`drainUsageChats`).

///|
fn get(row : Map[String, Json], name : String) -> Json {
  row.get(name).unwrap_or(Json::null())
}

///|
fn first(db : @sql.Db, sql : String, params : Array[Json]) -> Map[String, Json]? raise {
  match db.all(sql, params) {
    [r, ..] => Some(r)
    _ => None
  }
}

///|
fn quote(name : String) -> String {
  "\"" + name.replace_all(old="\"", new="\"\"") + "\""
}

///|
/// usage-retire.ts RETIRED_TABLES.
let retired_tables : String = "(name = 'usage_detail' OR name GLOB 'usage_detail_*' OR name = 'usage_main_calls'\n  OR name = 'usage_minute' OR name IN ('usage_minute_all', 'usage_minute_seen', 'usage_minute_sessions')\n  OR name IN ('usage_day_quarters', 'usage_quarters') OR name = 'usage_compact' OR name GLOB 'usage_compact_*'\n  OR name GLOB 'usage_summary_*' OR name = 'usage_history' OR name GLOB 'usage_history_*' OR name = 'usage_retired_detail')"

///|
/// usage-retire.ts RETIRED_TRIGGERS.
let retired_triggers : String = "(name GLOB 'usage_detail_*' OR name GLOB 'usage_daily_detail_*' OR name GLOB 'usage_main_calls_*'\n  OR name = 'usage_compactions_add' OR name GLOB 'usage_minute_*' OR name GLOB 'usage_quarters_*'\n  OR name GLOB 'usage_compact_*' OR name GLOB 'usage_summary_*' OR name GLOB 'usage_history_*')"

///|
/// One bounded delete of a retired table, by its primary key; the table dropped once empty (`dropUsageIndexStep`).
/// Whether none is left; none taken while their writers still run (the station stops them first: then nothing is left
/// to do now, and a later start takes them).
pub fn drop_step(db : @sql.Db, batch? : Int = 256) -> Bool raise {
  if first(db, "SELECT 1 FROM sqlite_master WHERE type = 'trigger' AND \{retired_triggers} LIMIT 1", []) is Some(_) {
    return true
  }
  guard first(
      db,
      "SELECT name FROM sqlite_master WHERE type = 'table' AND \{retired_tables} ORDER BY name LIMIT 1",
      [],
    )
    is Some(row) &&
    get(row, "name") is String(table) else {
    return true
  }
  let columns = db.all("PRAGMA table_info(\{quote(table)})", [])
  let keyed = columns.filter(c => get(c, "pk") is Number(p, ..) && p > 0)
  keyed.sort_by((a, b) => {
    let pa = match get(a, "pk") {
      Number(p, ..) => p
      _ => 0.0
    }
    let pb = match get(b, "pk") {
      Number(p, ..) => p
      _ => 0.0
    }
    pa.compare(pb)
  })
  let keys = keyed.map(c => match get(c, "name") {
    String(n) => quote(n)
    _ => "rowid"
  })
  if keys.length() == 0 {
    keys.push("rowid")
  }
  let tuple = if keys.length() == 1 { keys[0] } else { "(" + keys.join(", ") + ")" }
  let removed = db.run(
    "DELETE FROM \{quote(table)} WHERE \{tuple} IN (SELECT \{keys.join(", ")} FROM \{quote(table)} LIMIT ?)",
    [Json::number(batch.to_double())],
  )
  if removed == 0 {
    db.exec("DROP TABLE IF EXISTS \{quote(table)}")
  }
  false
}

// The fill (test/reference/backfill/usage-retire.ts `fillUsage15mStep`).

///|
let quarter_ms : Double = 900000.0

///|
fn has_table(db : @sql.Db, name : String) -> Bool raise {
  first(db, "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?", [Json::string(name)]) is Some(_)
}

///|
/// One batch of at least `batch` calls from before the quarters, or those left, and whole quarters, newest first, with
/// the `since` it moves back to (`fillUsage15mStep`): true when none is left.
pub fn fill_step(db : @sql.Db, batch? : Int = 256) -> Bool raise {
  if !has_table(db, "usage_15m_meta") {
    return true
  }
  db.exec("BEGIN IMMEDIATE")
  errdefer (db.exec("ROLLBACK") catch { _ => () })
  // (millisecond times, exact in a Double as in JavaScript)
  let since = match first(db, "SELECT since FROM usage_15m_meta WHERE id = 1", []) {
    Some(r) => get(r, "since")
    None => Json::null()
  }
  guard since is Number(c, ..) else {
    db.exec("COMMIT")
    return true
  }
  let before = Json::number((c / quarter_ms).ceil() * quarter_ms)
  let next = match
    first(db, "SELECT at FROM usage INDEXED BY usage_at WHERE at < ? ORDER BY at DESC LIMIT 1 OFFSET ?", [
      before,
      Json::number((batch - 1).to_double()),
    ]) {
    Some(r) => Some(r)
    None => first(db, "SELECT at FROM usage INDEXED BY usage_at WHERE at < ? ORDER BY at LIMIT 1", [before])
  }
  guard next is Some(n) else {
    ignore(db.run("UPDATE usage_15m_meta SET since = NULL WHERE id = 1", []))
    db.exec("COMMIT")
    return true
  }
  let at = match get(n, "at") {
    Number(v, ..) => v
    _ => raise Failure("a call has no time")
  }
  let from = (at / quarter_ms).floor() * quarter_ms
  ignore(
    db.run(
      "UPDATE usage INDEXED BY usage_at SET rollup_counted = 1 WHERE at >= ? AND at < ? AND rollup_counted = 0",
      [Json::number(from), before],
    ),
  )
  ignore(
    db.run("UPDATE usage_15m_meta SET since = ? WHERE id = 1", [
      Json::number(if from < c { from } else { c }),
    ]),
  )
  db.exec("COMMIT")
  false
}

// The chats of sessions that moved (test/reference/backfill/usage-chats.ts `drainUsageChatDirty`).

///|
/// One transaction of the chats of the sessions that moved between workspaces (usage_chat_dirty, which a session's
/// change of workspace, key or token marks; run by station/src/usage/module.ts `drainUsageChats`): at most `limit` of
/// the first waiting session's memberships given its workspace as it is now (none where it is gone), then the session
/// no longer waiting once none is left of them, else waiting after the last. Whether no session waits after it, and
/// how many memberships it went through; none waits where the chats' statistics are not there.
pub fn drain_chat_dirty_step(db : @sql.Db, limit? : Int = 32) -> (Bool, Int) raise {
  if !has_table(db, "usage_chat_dirty") {
    return (true, 0)
  }
  db.exec("BEGIN IMMEDIATE")
  errdefer (db.exec("ROLLBACK") catch { _ => () })
  guard first(
      db,
      "SELECT session, thread_after FROM usage_chat_dirty ORDER BY session LIMIT 1",
      [],
    )
    is Some(dirty) else {
    db.exec("COMMIT")
    return (true, 0)
  }
  let session = get(dirty, "session")
  let after = get(dirty, "thread_after")
  let (ws, present) = match
    first(db, "SELECT ws FROM sessions WHERE key = ?", [session]) {
    Some(row) => (get(row, "ws"), Json::number(1.0))
    None => (Json::null(), Json::number(0.0))
  }
  let size = Json::number(limit.to_double())
  let rows = if after is Null {
    db.all(
      "SELECT thread FROM usage_chat_members INDEXED BY usage_chat_members_session WHERE session = ? ORDER BY thread LIMIT ?",
      [session, size],
    )
  } else {
    db.all(
      "SELECT thread FROM usage_chat_members INDEXED BY usage_chat_members_session WHERE session = ? AND thread > ? ORDER BY thread LIMIT ?",
      [session, after, size],
    )
  }
  for row in rows {
    ignore(
      db.run(
        "UPDATE usage_chat_members SET ws = ?, present = ? WHERE session = ? AND thread = ? AND (ws IS NOT ? OR present IS NOT ?)",
        [ws, present, session, get(row, "thread"), ws, present],
      ),
    )
  }
  if rows.length() < limit {
    ignore(db.run("DELETE FROM usage_chat_dirty_scope WHERE session = ?", [session]))
    ignore(db.run("DELETE FROM usage_chat_dirty WHERE session = ?", [session]))
  } else {
    ignore(
      db.run("UPDATE usage_chat_dirty SET thread_after = ? WHERE session = ?", [
        get(rows[rows.length() - 1], "thread"),
        session,
      ]),
    )
  }
  let done = first(db, "SELECT 1 FROM usage_chat_dirty LIMIT 1", []) is None
  db.exec("COMMIT")
  (done, rows.length())
}
