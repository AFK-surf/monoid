// What the sidebar shows of a chat: the latest message not by the latest person (station/src/store/said-state.ts). An
// old chat's is found by reading back from its newest message in small slices, a guard the chat's writes invalidate,
// and published by a last write that finds its guard, as `saidScanStep` does, on a store with the legacy lookup too
// (store/legacy-said-build.ts: its changed keys folded back for the chat first where they are more than a slice).
// Only the writes take the backfill permit (`may_write`).

///|
pub let batch : Int = 64

///|
/// Whether the store reads its messages through the legacy lookup (`hasLegacySaid`); one of another version is an
/// error, never read as this one.
pub fn legacy(db : @sql.Db) -> Bool raise {
  @readops.has_legacy_said(db)
}

///|
/// More of the chat's keys changed than a slice folds back (`legacySaidThreadNeedsDrain`).
fn legacy_needs_drain(db : @sql.Db, t : Json) -> Bool raise {
  db.all(@readops.legacy_said_needs_drain_sql, [t]).length() > 0
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
  let latest = () => if legacy { @readops.legacy_said_head(db, t) } else { (true, db.first(@readops.said_latest_sql, [t])) }
  let state = () => db.first(@readops.said_state_sql, [t])
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
      Some(Some(db.all(if legacy { @readops.legacy_said_scan_sql } else { @readops.said_scan_sql }, [t, scan.before, Json::number(limit.to_double())])))
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
