// A requested old chat's letter-message keys (station/src/store/page-letter-index.ts): a shadow of them, scanned in
// bounded batches and its changed keys reconciled, as `pageLetterStep` does, here for the MoonBit builder. Its tables
// and triggers (each marked `page_letter_v1`) made when missing or one is gone, with a new epoch, as
// `installPageLetterIndex` does.

///|
let version : Int = 1

///|
let mark : String = "page_letter_v1"

///|
let names : Array[String] = ["page_letter_insert", "page_letter_update", "page_letter_delete", "page_letter_thread_delete"]

///|
/// What a write may displace (REPLACE, through rowid even in another chat): marked before any write.
let conflicts : String = "SELECT e.thread,e.n FROM ( SELECT rowid AS id FROM entries WHERE thread=NEW.thread AND n=NEW.n UNION SELECT rowid FROM entries WHERE NEW.ts IS NOT NULL AND thread=NEW.thread AND ts=NEW.ts UNION SELECT rowid FROM entries WHERE rowid=NEW.rowid ) p CROSS JOIN entries e ON e.rowid=p.id WHERE e.kind='message' AND e.letter IS NOT NULL"

///|
let new_key : String = "SELECT NEW.thread AS thread,NEW.n AS n WHERE NEW.kind='message' AND NEW.letter IS NOT NULL"

///|
let old_key : String = "SELECT OLD.thread AS thread,OLD.n AS n WHERE OLD.kind='message' AND OLD.letter IS NOT NULL"

///|
fn mark_keys(keys : String) -> String {
  "INSERT INTO page_letter_dirty(thread,token,n) SELECT k.thread,s.token,k.n FROM (\{keys}) k CROSS JOIN page_letter_scopes s ON s.thread=k.thread CROSS JOIN page_letter_meta m ON m.id=1 AND s.epoch=m.epoch WHERE NOT EXISTS (SELECT 1 FROM page_letter_dirty d WHERE d.thread=k.thread AND d.token=s.token AND d.n=k.n);"
}

///|
let changed : String = "OLD.thread IS NOT NEW.thread OR OLD.n IS NOT NEW.n OR OLD.rowid IS NOT NEW.rowid OR OLD.kind IS NOT NEW.kind OR OLD.letter IS NOT NEW.letter OR OLD.ts IS NOT NEW.ts"

///|
let tracked_new : String = "EXISTS (SELECT 1 FROM page_letter_scopes WHERE thread=NEW.thread) OR EXISTS (SELECT 1 FROM entries e JOIN page_letter_scopes s ON s.thread=e.thread WHERE e.rowid=NEW.rowid)"

///|
let queue_old : String = "INSERT INTO page_letter_garbage(thread,token) SELECT s.thread,s.token FROM page_letter_scopes s WHERE s.thread=OLD.id AND NOT EXISTS (SELECT 1 FROM page_letter_garbage g WHERE g.thread=s.thread AND g.token=s.token);"

///|
let triggers : String = [
  "CREATE TRIGGER page_letter_insert BEFORE INSERT ON entries WHEN \{tracked_new} BEGIN -- \{mark}\n\{mark_keys("\{new_key} UNION \{conflicts}")} END;",
  "CREATE TRIGGER page_letter_update BEFORE UPDATE ON entries WHEN (\{changed}) AND ((\{tracked_new}) OR EXISTS (SELECT 1 FROM page_letter_scopes WHERE thread=OLD.thread)) BEGIN -- \{mark}\n\{mark_keys("\{old_key} UNION \{new_key} UNION \{conflicts}")} END;",
  "CREATE TRIGGER page_letter_delete BEFORE DELETE ON entries WHEN OLD.kind='message' AND OLD.letter IS NOT NULL AND EXISTS (SELECT 1 FROM page_letter_scopes WHERE thread=OLD.thread) BEGIN -- \{mark}\n\{mark_keys(old_key)} END;",
  "CREATE TRIGGER page_letter_thread_delete AFTER DELETE ON threads BEGIN -- \{mark}\n\{queue_old} DELETE FROM page_letter_scopes WHERE thread=OLD.id; END;",
].join("\n")

///|
fn current(db : @sql.Db) -> Bool raise {
  for name in ["page_letter_meta", "page_letter_scopes", "page_letter_rows", "page_letter_dirty", "page_letter_garbage"] {
    if db.sqlite_master_sql("table", name) is None {
      return false
    }
  }
  if db.sqlite_master_sql("index", "page_letter_scope_epoch") is None {
    return false
  }
  guard db.first("SELECT version FROM page_letter_meta WHERE id=1", []) is Some(meta) else { return false }
  guard @sql.row_val(meta, "version") is Number(n, ..) && n.to_int() == version else {
    fail("page letter version \{@sql.row_val(meta, "version").stringify()} is incompatible")
  }
  for name in names {
    guard db.sqlite_master_sql("trigger", name) is Some(sql) && sql.contains(mark) else { return false }
  }
  true
}

///|
/// The builder's state: the schema version its install was checked at.
pub struct Letters {
  priv db : @sql.Db
  priv mut checked : Json?
}

///|
pub fn Letters::new(db : @sql.Db) -> Letters {
  { db, checked: None }
}

///|
fn Letters::install(self : Letters) -> Bool raise {
  let db = self.db
  let initial = db.schema_version()
  if self.checked == Some(initial) {
    return true
  }
  if current(db) {
    self.checked = Some(initial)
    return true
  }
  db.exec("BEGIN IMMEDIATE")
  errdefer (db.exec("ROLLBACK") catch { _ => () })
  if !current(db) {
    db.exec(
      "CREATE TABLE IF NOT EXISTS page_letter_meta(id INTEGER PRIMARY KEY CHECK(id=1),version INTEGER NOT NULL, epoch INTEGER NOT NULL) WITHOUT ROWID; CREATE TABLE IF NOT EXISTS page_letter_scopes(thread INTEGER PRIMARY KEY,token TEXT NOT NULL,epoch INTEGER NOT NULL, cursor_n INTEGER,end_n INTEGER,complete INTEGER NOT NULL) WITHOUT ROWID; CREATE INDEX IF NOT EXISTS page_letter_scope_epoch ON page_letter_scopes(epoch,thread); CREATE TABLE IF NOT EXISTS page_letter_rows(thread INTEGER NOT NULL,token TEXT NOT NULL,n INTEGER NOT NULL, PRIMARY KEY(thread,token,n)) WITHOUT ROWID; CREATE TABLE IF NOT EXISTS page_letter_dirty(thread INTEGER NOT NULL,token TEXT NOT NULL,n INTEGER NOT NULL, PRIMARY KEY(thread,token,n)) WITHOUT ROWID; CREATE TABLE IF NOT EXISTS page_letter_garbage(thread INTEGER NOT NULL,token TEXT NOT NULL, PRIMARY KEY(thread,token)) WITHOUT ROWID;",
    )
    if db.first("SELECT version FROM page_letter_meta WHERE id=1", []) is Some(m) &&
      !(@sql.row_val(m, "version") is Number(n, ..) && n.to_int() == version) {
      fail("page letter version \{@sql.row_val(m, "version").stringify()} is incompatible")
    }
    ignore(
      db.run("INSERT INTO page_letter_meta VALUES(1,?,1) ON CONFLICT(id) DO UPDATE SET epoch=epoch+1", [
        Json::number(version.to_double()),
      ]),
    )
    for name in names {
      db.exec("DROP TRIGGER IF EXISTS \{name}")
    }
    db.exec(triggers)
  }
  db.exec("COMMIT")
  self.checked = Some(db.schema_version())
  true
}

///|
fn dirty_overflow(db : @sql.Db, thread : Json, token : Json) -> Bool raise {
  db.all("SELECT 1 FROM page_letter_dirty WHERE thread=? AND token=? LIMIT 1 OFFSET 64", [thread, token]).length() > 0
}

///|
fn scope_of(db : @sql.Db, thread : Json) -> Map[String, Json]? raise {
  db.first(
    "SELECT token,epoch, CAST(cursor_n AS TEXT) AS cursor_n,CAST(end_n AS TEXT) AS end_n,complete FROM page_letter_scopes WHERE thread=?",
    [thread],
  )
}

///|
/// Scans at most `limit` (64 at most) source keys or reconciles at most `limit` changes; whether the chat's keys are
/// ready then. A handover resumes its scope.
pub fn Letters::step(self : Letters, thread : Int64, limit? : Int = 64) -> Bool raise {
  guard limit >= 1 && limit <= 64 else { fail("page letter batch must be 1–64") }
  let db = self.db
  if !self.install() {
    return false
  }
  let t = Json::number(thread.to_double())
  db.exec("BEGIN IMMEDIATE")
  errdefer (db.exec("ROLLBACK") catch { _ => () })
  let epoch = db.first("SELECT epoch FROM page_letter_meta WHERE id=1", []).map(r => @sql.row_val(r, "epoch")).unwrap_or(
    Json::null(),
  )
  let s = match scope_of(db, t) {
    Some(s) if @sql.row_val(s, "epoch") == epoch => s
    old => {
      if old is Some(o) {
        let token = @sql.row_val(o, "token")
        ignore(
          db.run(
            "INSERT INTO page_letter_garbage(thread,token) SELECT ?,? WHERE NOT EXISTS (SELECT 1 FROM page_letter_garbage WHERE thread=? AND token=?)",
            [t, token, t, token],
          ),
        )
        ignore(db.run("DELETE FROM page_letter_scopes WHERE thread=?", [t]))
      }
      ignore(
        db.run(
          "INSERT INTO page_letter_scopes(thread,token,epoch,cursor_n,end_n,complete) VALUES(?,lower(hex(randomblob(16))),?,NULL,(SELECT n FROM entries WHERE thread=? ORDER BY n DESC LIMIT 1),0)",
          [t, epoch, t],
        ),
      )
      guard scope_of(db, t) is Some(s) else { fail("page letter scope is missing") }
      s
    }
  }
  let token = @sql.row_val(s, "token")
  let lim = Json::number(limit.to_double())
  if @sql.row_val(s, "complete") is Number(0.0, ..) {
    let indexed = db.sqlite_master_sql("index", "entries_letters") is Some(_)
    let cursor = @sql.row_val(s, "cursor_n")
    let sql = "SELECT CAST(e.n AS TEXT) AS n,e.kind,e.letter FROM entries e \{if indexed { "INDEXED BY entries_letters" } else { "" }} WHERE e.thread=?1 AND e.n<=CAST(?2 AS INTEGER) \{if cursor is Null { "" } else { "AND e.n>CAST(?3 AS INTEGER)" }} \{if indexed { "AND e.letter IS NOT NULL" } else { "" }} ORDER BY e.n LIMIT ?\{if cursor is Null { 3 } else { 4 }}"
    let rows = if cursor is Null {
      db.all(sql, [t, @sql.row_val(s, "end_n"), lim])
    } else {
      db.all(sql, [t, @sql.row_val(s, "end_n"), cursor, lim])
    }
    for row in rows {
      if @sql.row_val(row, "kind") == Json::string("message") && !(@sql.row_val(row, "letter") is Null) {
        ignore(
          db.run(
            "INSERT INTO page_letter_rows(thread,token,n) VALUES(?,?,CAST(? AS INTEGER)) ON CONFLICT(thread,token,n) DO NOTHING",
            [t, token, @sql.row_val(row, "n")],
          ),
        )
      }
    }
    let reached = match rows.last() {
      Some(r) => @sql.row_val(r, "n")
      None => cursor
    }
    ignore(
      db.run("UPDATE page_letter_scopes SET cursor_n=CAST(? AS INTEGER),complete=? WHERE thread=? AND token=?", [
        reached,
        Json::number(if rows.length() < limit { 1.0 } else { 0.0 }),
        t,
        token,
      ]),
    )
    let done = rows.length() < limit && !dirty_overflow(db, t, token)
    db.exec("COMMIT")
    return done
  }
  let keys = db.all("SELECT CAST(d.n AS TEXT) AS n FROM page_letter_dirty d WHERE d.thread=? AND d.token=? ORDER BY d.n LIMIT ?", [
    t, token, lim,
  ])
  for key in keys {
    let n = @sql.row_val(key, "n")
    ignore(db.run("DELETE FROM page_letter_rows WHERE thread=? AND token=? AND n=CAST(? AS INTEGER)", [t, token, n]))
    ignore(
      db.run(
        "INSERT INTO page_letter_rows(thread,token,n) SELECT e.thread,?,e.n FROM entries e WHERE e.thread=? AND e.n=CAST(? AS INTEGER) AND e.kind='message' AND e.letter IS NOT NULL",
        [token, t, n],
      ),
    )
    ignore(db.run("DELETE FROM page_letter_dirty WHERE thread=? AND token=? AND n=CAST(? AS INTEGER)", [t, token, n]))
  }
  let ready = !dirty_overflow(db, t, token)
  db.exec("COMMIT")
  ready
}

///|
/// One batch of reclaiming orphaned scopes and rows (`pageLetterGcStep`): a scope of an older epoch queued as garbage,
/// then at most `limit` of one garbage scope's rows and changed keys removed; whether nothing is left then.
pub fn Letters::gc_step(self : Letters, limit? : Int = 64) -> Bool raise {
  guard limit >= 1 && limit <= 64 else { raise Failure("page letter batch must be 1–64") }
  let db = self.db
  if !self.install() {
    return true
  }
  db.exec("BEGIN IMMEDIATE")
  errdefer (db.exec("ROLLBACK") catch { _ => () })
  let older = "FROM page_letter_scopes WHERE epoch<(SELECT epoch FROM page_letter_meta WHERE id=1)"
  if db.first("SELECT CAST(thread AS TEXT) AS thread,token \{older} ORDER BY page_letter_scopes.epoch,page_letter_scopes.thread LIMIT 1", [])
    is Some(stale) {
    let key = [@sql.row_val(stale, "thread"), @sql.row_val(stale, "token")]
    ignore(
      db.run(
        "INSERT INTO page_letter_garbage(thread,token) SELECT CAST(?1 AS INTEGER),?2 WHERE NOT EXISTS (SELECT 1 FROM page_letter_garbage WHERE thread=CAST(?1 AS INTEGER) AND token=?2)",
        key,
      ),
    )
    ignore(db.run("DELETE FROM page_letter_scopes WHERE thread=CAST(? AS INTEGER) AND token=?", key))
  }
  guard db.first("SELECT CAST(thread AS TEXT) AS thread,token FROM page_letter_garbage ORDER BY page_letter_garbage.thread,page_letter_garbage.token LIMIT 1", [])
    is Some(garbage) else {
    db.exec("COMMIT")
    return true
  }
  let key = [@sql.row_val(garbage, "thread"), @sql.row_val(garbage, "token")]
  let remove = (table : String, count : Int) => db.run(
    "DELETE FROM \{table} WHERE thread=CAST(?1 AS INTEGER) AND token=?2 AND n IN (SELECT n FROM \{table} WHERE thread=CAST(?1 AS INTEGER) AND token=?2 ORDER BY n LIMIT ?3)",
    key + [Json::number(count.to_double())],
  )
  let rows = remove("page_letter_rows", limit)
  let dirty = if rows < limit { remove("page_letter_dirty", limit - rows) } else { 0 }
  if rows + dirty < limit {
    ignore(db.run("DELETE FROM page_letter_garbage WHERE thread=CAST(? AS INTEGER) AND token=?", key))
  }
  let remaining = db.first("SELECT 1 FROM page_letter_garbage LIMIT 1", []) is Some(_) ||
    db.first("SELECT 1 \{older} ORDER BY epoch,thread LIMIT 1", []) is Some(_)
  db.exec("COMMIT")
  !remaining
}

///|
/// page-letter-index.ts `pageLetterReady`: the chat's prepared letter keys' token, none while they are not (or the
/// index's triggers are not as this version makes them: a reader never repairs them).
pub fn ready_token(db : @sql.Db, thread : Json) -> String? raise {
  if !current(db) {
    return None
  }
  guard scope_of(db, thread) is Some(s) else { return None }
  let epoch = db.first("SELECT epoch FROM page_letter_meta WHERE id=1", []).map(m => @sql.row_val(m, "epoch")).unwrap_or(Json::null())
  guard @sql.row_val(s, "epoch") == epoch && @sql.row_val(s, "complete") is Number(1.0, ..) && @sql.row_val(s, "token") is String(token) else {
    return None
  }
  if dirty_overflow(db, thread, @sql.row_val(s, "token")) {
    return None
  }
  Some(token)
}
