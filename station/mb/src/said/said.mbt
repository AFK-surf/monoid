// What the sidebar shows of a chat: the latest message not by the latest person (station/src/store/said-state.ts). An
// old chat's is found by reading back from its newest message in small slices, a guard the chat's writes invalidate,
// and published by a last write that finds its guard, as `saidScanStep` does, on a store with the legacy lookup too
// (store/legacy-said-build.ts: its changed keys folded back for the chat first where they are more than a slice).
// Only the writes take the backfill permit (`may_write`).

///|
pub let batch : Int = 64

///|
let latest_sql : String = "SELECT n, author_kind, author FROM entries INDEXED BY entries_said WHERE thread = ?1 AND kind = 'message' AND letter IS NULL ORDER BY n DESC LIMIT 1"

///|
let state_sql : String = "SELECT s.said_n, s.said_other_n, s.said_other_known, g.author AS guard_author, g.other_n AS guard_other_n, g.ready AS guard_ready FROM thread_state s LEFT JOIN said_state_guard g ON g.thread = s.thread WHERE s.thread = ?1 UNION ALL SELECT NULL, NULL, NULL, g.author, g.other_n, g.ready FROM said_state_guard g WHERE g.thread = ?1 AND NOT EXISTS (SELECT 1 FROM thread_state s WHERE s.thread = ?1) LIMIT 1"

///|
let scan_sql : String = "SELECT n, author_kind, author FROM entries INDEXED BY entries_said WHERE thread = ?1 AND kind = 'message' AND letter IS NULL AND n < ?2 ORDER BY n DESC LIMIT ?3"

///|
/// legacy-said-build.ts LEGACY_SAID_SCAN.
let legacy_scan_sql : String = "SELECT n, author_kind, author FROM legacy_said WHERE thread = ?1 AND n < ?2 ORDER BY n DESC LIMIT ?3"

///|
/// legacy-said-build.ts LEGACY_SAID_LATEST.
let legacy_latest_sql : String =
  #|WITH dirty_latest AS MATERIALIZED (
  #|    SELECT e.n,e.author_kind,e.author FROM legacy_said_meta m CROSS JOIN legacy_said_dirty d
  #|      CROSS JOIN entries e ON e.thread=d.thread AND e.n=d.n
  #|    WHERE m.id=1 AND m.scanned=1 AND d.thread=?1 AND e.kind='message' AND e.letter IS NULL
  #|    ORDER BY d.n DESC LIMIT 1
  #|  )
  #|  SELECT n,author_kind,author FROM dirty_latest
  #|  UNION ALL
  #|  SELECT n,author_kind,author FROM (
  #|    SELECT s.n,s.author_kind,s.author FROM legacy_said_meta m CROSS JOIN legacy_said_build s
  #|    WHERE m.id=1 AND m.scanned=1 AND s.thread=?1
  #|      AND s.n >= COALESCE((SELECT n FROM dirty_latest), -9223372036854775808)
  #|      AND NOT EXISTS (SELECT 1 FROM legacy_said_dirty d WHERE d.thread=s.thread AND d.n=s.n)
  #|    ORDER BY s.n DESC LIMIT 1
  #|  )
  #|  UNION ALL
  #|  SELECT n,author_kind,author FROM (
  #|    SELECT e.n,e.author_kind,e.author FROM legacy_said_meta m CROSS JOIN entries e
  #|    WHERE m.id=1 AND m.scanned=0 AND e.thread=?1 AND e.kind='message' AND e.letter IS NULL
  #|    ORDER BY e.n DESC LIMIT 1
  #|  )
  #|  ORDER BY n DESC LIMIT 1

///|
/// legacy-said-build.ts LEGACY_SAID_NEEDS_DRAIN.
let legacy_needs_drain_sql : String = "SELECT 1 FROM legacy_said_meta m WHERE m.id=1 AND m.scanned=1 AND EXISTS (SELECT 1 FROM legacy_said_dirty WHERE thread=?1 LIMIT 1 OFFSET 64)"

///|
/// legacy-said-build.ts LEGACY_SAID_HEAD_FIRST.
let legacy_head_first_sql : String = "SELECT CASE WHEN e.kind='message' AND e.letter IS NULL THEN e.n END AS n, CASE WHEN e.kind='message' AND e.letter IS NULL THEN e.author_kind END AS author_kind, CASE WHEN e.kind='message' AND e.letter IS NULL THEN e.author END AS author FROM entries e WHERE e.thread=? ORDER BY e.n DESC LIMIT 1"

///|
/// legacy-said-build.ts LEGACY_SAID_HEAD_TAIL.
let legacy_head_tail_sql : String =
  #|WITH tail AS MATERIALIZED (
  #|      SELECT n,kind,letter,author_kind,author FROM entries WHERE thread=? ORDER BY n DESC LIMIT 65
  #|    ), latest AS MATERIALIZED (
  #|      SELECT n,author_kind,author FROM tail WHERE kind='message' AND letter IS NULL ORDER BY n DESC LIMIT 1
  #|    ) SELECT (SELECT n FROM latest) AS n,(SELECT author_kind FROM latest) AS author_kind,
  #|      (SELECT author FROM latest) AS author,(SELECT COUNT(*) FROM tail) AS count

///|
/// Whether the store reads its messages through the legacy lookup (`hasLegacySaid`); one of another version is an
/// error, never read as this one.
pub fn legacy(db : @sql.Db) -> Bool raise {
  if db.all("SELECT 1 FROM sqlite_master WHERE type='view' AND name='legacy_said'", []).length() == 0 {
    return false
  }
  if db.all("SELECT 1 FROM sqlite_master WHERE type='table' AND name='legacy_said_meta'", []).length() == 0 {
    fail("legacy said view has no metadata")
  }
  guard db.all("SELECT version,scanned FROM legacy_said_meta WHERE id=1", []) is [m, ..] &&
    @sql.row_val(m, "version") == Json::number(1.0) &&
    (@sql.row_val(m, "scanned") == Json::number(0.0) || @sql.row_val(m, "scanned") == Json::number(1.0)) else {
    fail("legacy said view has an unsupported version")
  }
  true
}

///|
/// More of the chat's keys changed than a slice folds back (`legacySaidThreadNeedsDrain`).
fn legacy_needs_drain(db : @sql.Db, t : Json) -> Bool raise {
  db.all(legacy_needs_drain_sql, [t]).length() > 0
}

///|
/// The chat's latest message by the legacy lookup (`legacySaidReadHead`): whether it is known, and it (None: none). Not
/// known while more keys changed than the raw tail can stand for.
fn legacy_head(db : @sql.Db, t : Json) -> (Bool, Map[String, Json]?) raise {
  guard db.first(legacy_head_first_sql, [t]) is Some(first) else { return (true, None) }
  if !(@sql.row_val(first, "n") is Null) {
    return (true, Some(first))
  }
  if !legacy_needs_drain(db, t) {
    return (true, db.first(legacy_latest_sql, [t]))
  }
  guard db.first(legacy_head_tail_sql, [t]) is Some(tail) else { return (true, None) }
  if !(@sql.row_val(tail, "n") is Null) {
    return (true, Some(tail))
  }
  (@sql.row_val(tail, "count") is Number(c, ..) && c < 65.0, None)
}

///|
/// At most `limit` of the chat's changed keys folded back into the legacy lookup (`legacySaidDrainThread`).
fn legacy_drain(db : @sql.Db, t : Json, limit : Int) -> Unit raise {
  db.exec("BEGIN IMMEDIATE")
  errdefer (db.exec("ROLLBACK") catch { _ => () })
  guard db.all("SELECT version FROM legacy_said_meta WHERE id=1", []) is [m, ..] else {
    fail("legacy said metadata is missing")
  }
  if @sql.row_val(m, "version") != Json::number(1.0) {
    fail("legacy said version \{@sql.row_val(m, "version").stringify()} is incompatible with 1")
  }
  let keys = db.all(
    "SELECT CAST(d.thread AS TEXT) thread,CAST(d.n AS TEXT) n FROM legacy_said_dirty d WHERE d.thread=? ORDER BY d.n LIMIT ?",
    [t, Json::number(limit.to_double())],
  )
  for key in keys {
    let k = [@sql.row_val(key, "thread"), @sql.row_val(key, "n")]
    ignore(db.run("DELETE FROM legacy_said_build WHERE thread=CAST(? AS INTEGER) AND n=CAST(? AS INTEGER)", k))
    ignore(
      db.run(
        "INSERT INTO legacy_said_build(thread,n,author_kind,author) SELECT thread,n,author_kind,author FROM entries WHERE thread=CAST(? AS INTEGER) AND n=CAST(? AS INTEGER) AND kind='message' AND letter IS NULL",
        k,
      ),
    )
    ignore(db.run("DELETE FROM legacy_said_dirty WHERE thread=CAST(? AS INTEGER) AND n=CAST(? AS INTEGER)", k))
  }
  db.exec("COMMIT")
}

///|
/// Whether the boundary is known for `latest` from the chat's state or a finished guard (`saidBoundary`).
fn known(state : Map[String, Json]?, latest : Map[String, Json]) -> Bool {
  if @sql.row_val(latest, "author_kind") != Json::string("person") {
    return true
  }
  guard state is Some(s) else { return false }
  (@sql.row_val(s, "said_n") == @sql.row_val(latest, "n") && @sql.row_val(s, "said_other_known") == Json::number(1.0)) ||
  (@sql.row_val(s, "guard_ready") == Json::number(1.0) && @sql.row_val(s, "guard_author") == @sql.row_val(latest, "author"))
}

///|
/// A search under way: the chat, the latest person's name, its guard's token, how far back it has read, and what it
/// found (the newest message by another, or none: `Some(Null)`).
pub struct Scan {
  priv thread : Int64
  priv author : Json
  priv token : String
  priv mut before : Json
  priv mut found : Json?
}

///|
pub fn Scan::token(self : Scan) -> String {
  self.token
}

///|
/// One step of `thread`'s search from `scan` (None: none begun); whether it is known, and the scan to go on with.
pub async fn step(
  db : @sql.Db,
  thread : Int64,
  scan : Scan?,
  token~ : () -> String,
  may_write~ : async () -> Bool,
  limit? : Int = batch,
) -> (Bool, Scan?) {
  guard limit >= 1 && limit <= batch else { fail("said scan batch must be between 1 and 64") }
  let t = Json::number(thread.to_double())
  let legacy = legacy(db)
  // (whether the latest message is known, and it)
  let latest = () => if legacy { legacy_head(db, t) } else { (true, db.first(latest_sql, [t])) }
  let state = () => db.first(state_sql, [t])
  let draining = () => legacy && legacy_needs_drain(db, t)
  // (the chat's changed keys folded back a slice, the search where it was)
  let drain = async fn(scan : Scan?) -> (Bool, Scan?) {
    if may_write() {
      legacy_drain(db, t, limit)
    }
    (false, scan)
  }
  if draining() {
    return drain(scan)
  }
  guard scan is Some(scan) else {
    // (the check and the read in one snapshot: an old writer's changes between them are seen together)
    db.exec("SAVEPOINT said_scan")
    let (head_known, head, boundary_known) = {
      defer (db.exec("RELEASE said_scan") catch { _ => () })
      let (known_, head) = latest()
      (known_, head, head is Some(h) && known(state(), h))
    }
    if !head_known {
      return drain(None)
    }
    if head is None || boundary_known {
      return (true, None)
    }
    if !may_write() {
      return (false, None)
    }
    db.exec("BEGIN IMMEDIATE")
    errdefer (db.exec("ROLLBACK") catch { _ => () })
    let (current_known, current) = latest()
    if !current_known || draining() {
      db.exec("COMMIT")
      return (false, None)
    }
    guard current is Some(current) && !known(state(), current) else {
      db.exec("COMMIT")
      return (true, None)
    }
    let token = token()
    ignore(
      db.run(
        "INSERT INTO said_state_guard(thread,token,author,other_n,ready) VALUES (?,?,?,NULL,0) ON CONFLICT(thread) DO UPDATE SET token=excluded.token,author=excluded.author,other_n=NULL,ready=0",
        [t, Json::string(token), @sql.row_val(current, "author")],
      ),
    )
    db.exec("COMMIT")
    return (
      false,
      Some({ thread, token, author: @sql.row_val(current, "author"), before: @sql.row_val(current, "n"), found: None }),
    )
  }
  guard scan.thread == thread else { fail("said scan belongs to another chat") }
  let guarded = () => db.first("SELECT token FROM said_state_guard WHERE thread=?", [t]) is Some(g) &&
    @sql.row_val(g, "token") == Json::string(scan.token)
  db.exec("SAVEPOINT said_scan")
  // (None: the guard lost; Some(None): changed keys to fold back first; else the slice read)
  let rows = {
    defer (db.exec("RELEASE said_scan") catch { _ => () })
    if !guarded() {
      None
    } else if draining() {
      Some(None)
    } else if scan.found is None {
      Some(Some(db.all(if legacy { legacy_scan_sql } else { scan_sql }, [t, scan.before, Json::number(limit.to_double())])))
    } else {
      Some(Some([]))
    }
  }
  guard rows is Some(rows) else { return (false, None) }
  guard rows is Some(rows) else { return drain(Some(scan)) }
  if scan.found is None {
    let other = rows.iter().find_first(r => @sql.row_val(r, "author_kind") != Json::string("person") ||
      @sql.row_val(r, "author") != scan.author)
    match other {
      Some(o) => scan.found = Some(@sql.row_val(o, "n"))
      None =>
        if rows.length() < limit {
          scan.found = Some(Json::null())
        } else {
          scan.before = @sql.row_val(rows[rows.length() - 1], "n")
        }
    }
  }
  guard scan.found is Some(found) else { return (false, Some(scan)) }
  if !may_write() {
    return (false, Some(scan))
  }
  db.exec("BEGIN IMMEDIATE")
  errdefer (db.exec("ROLLBACK") catch { _ => () })
  if !guarded() {
    db.exec("COMMIT")
    return (false, None)
  }
  let (current_known, current) = latest()
  if !current_known || draining() {
    db.exec("COMMIT")
    return (false, Some(scan))
  }
  if current is Some(c) &&
    (@sql.row_val(c, "author_kind") != Json::string("person") || @sql.row_val(c, "author") != scan.author) {
    db.exec("COMMIT")
    return (false, None)
  }
  let tok = Json::string(scan.token)
  match current {
    None => ignore(db.run("DELETE FROM said_state_guard WHERE thread=? AND token=?", [t, tok]))
    Some(c) => {
      let wrote = db.run("UPDATE thread_state SET said_other_n=?, said_other_known=1 WHERE thread=? AND said_n=?", [
        found,
        t,
        @sql.row_val(c, "n"),
      ])
      if wrote > 0 {
        ignore(db.run("DELETE FROM said_state_guard WHERE thread=? AND token=?", [t, tok]))
      } else {
        ignore(
          db.run("UPDATE said_state_guard SET author=?, other_n=?, ready=1 WHERE thread=? AND token=?", [
            scan.author,
            found,
            t,
            tok,
          ]),
        )
      }
    }
  }
  db.exec("COMMIT")
  (true, None)
}
