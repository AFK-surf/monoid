// The station's store of threads in MoonBit (station/src/store/store.ts, its threads, messages and their edits, letters,
// deliveries, a viewer's marks, the archive's decisions and the cards with their queued outcomes), on the station's
// database: method by method the same statements, in the same order, the same values given back and the same changes
// told (store.ts `#with`: each method's, as its writes are done, also where it failed part way). Its time is the one
// it is given (`now`: a test's clock, as the store's Clock); what it tells goes to `sent`, in the order the store would
// tell its followers. `harness.mbt` answers a line protocol on it, which station/test/mb-store-threads.test.ts plays
// against the TypeScript store on a twin database.

///|
/// A message's write could not begin its transaction: another connection writes. Nothing was written (store.ts
/// `MessageWriteBusy`).
pub(all) suberror MessageWriteBusy

///|
/// Its words where it is said (`to_string`, a notice, a log): not its type's name (`station/<package>.<Type>`).
pub impl Show for MessageWriteBusy with output(self, logger) {
  match self {
    MessageWriteBusy => logger.write_string("another connection writes: the message was not written, and is tried again")
  }
}

///|
/// An older store's session lookup of the decision checks is still being prepared (legacy-decision-session.ts).
pub(all) suberror DecisionSessionsUnavailable

///|
/// Its words where it is said (`to_string`, a notice, a log): not its type's name (`station/<package>.<Type>`).
pub impl Show for DecisionSessionsUnavailable with output(self, logger) {
  match self {
    DecisionSessionsUnavailable => logger.write_string("decision session lookup is not ready")
  }
}

///|
/// An old session's chat order is still being prepared (session-chat-index.ts).
pub(all) suberror SessionChatUnavailable

///|
/// Its words where it is said (`to_string`, a notice, a log): not its type's name (`station/<package>.<Type>`).
pub impl Show for SessionChatUnavailable with output(self, logger) {
  match self {
    SessionChatUnavailable => logger.write_string("session chat is still being prepared")
  }
}

///|
/// The copy destinations of these sessions are still being prepared (cc-thread-index.ts).
pub(all) suberror CcSessionsUnavailable {
  CcSessionsUnavailable(Array[String])
}

///|
/// Its words where it is said (`to_string`, a notice, a log): not its type's name (`station/<package>.<Type>`).
pub impl Show for CcSessionsUnavailable with output(self, logger) {
  match self {
    CcSessionsUnavailable(_) => logger.write_string("copy destinations are still being prepared")
  }
}

///|
/// What the store throws as a plain Error, its words as the TypeScript's.
pub(all) suberror StoreError {
  StoreError(String)
}

///|
/// Its words where it is said (`to_string`, a notice, a log): not its type's name (`station/<package>.<Type>`).
pub impl Show for StoreError with output(self, logger) {
  match self {
    StoreError(m) => logger.write_string(m)
  }
}

///|
pub struct Store {
  db : @sql.Db
  /// Now, by the store's clock (ms).
  mut now : Double
  legacy_said : Bool
  legacy_agent : Bool
  legacy_login_cards : Bool
  legacy_archive_policy : Bool
  legacy_decision_time : Bool
  mut legacy_decision_session : String?
  mut decision_session_index_was_missing : Bool
  /// store.ts `#decisions`: decision checks or archive policies written by this store.
  mut decisions : Int
  /// store.ts `#movedUntold`.
  moved_untold : Map[String, Bool]
  /// How deep in transactions this connection is (node:sqlite's `isTransaction`).
  mut depth : Int
  /// What was told, in order (the store's `#send`).
  sent : Array[Json]
  /// What a synchronous caller asked to be prepared (store.ts `requestLatestThread`, `requestSessionChat`).
  requested : Array[Json]
  /// card-scan-guard.ts and restate-guard.ts `cached`: the schema each guard was found installed at.
  mut scan_guard_schema : Int?
  mut restate_guard_schema : Int?
  /// card-outbox.ts `installed`.
  mut outbox_schema : Int?
  /// archive-last.ts `checked`.
  mut archive_last_schema : Int?
  /// Random tokens: a guard's (store.ts `randomBytes(16)`), made of this.
  mut seed : UInt64
}

///|
fn exists(db : @sql.Db, kind : String, name : String) -> Bool raise {
  !db.all("SELECT 1 FROM sqlite_master WHERE type=? AND name=?", [Json::string(kind), Json::string(name)]).is_empty()
}

///|
fn one(db : @sql.Db, sql : String, params : Array[Json]) -> Map[String, Json]? raise {
  let rows = db.all(sql, params)
  if rows.is_empty() {
    None
  } else {
    Some(rows[0])
  }
}

///|
fn col(r : Map[String, Json], name : String) -> Json {
  r.get(name).unwrap_or(Json::null())
}

///|
fn is_num(v : Json, n : Double) -> Bool {
  v is Number(x, ..) && x == n
}

///|
fn num(v : Json) -> Double {
  match v {
    Number(x, ..) => x
    _ => 0.0
  }
}

///|
using @jsjson {
  json_num as jnum, json_int as jint, json_str as jstr, json_bool as jbool, json_opt_str as jopt,
  jval_of_json as of_json, stringify, jval_str_of as jtext, jval_obj as jobj,
}

///|
using @readops {to_json}

///|
fn text_of(v : Json) -> String? {
  match v {
    String(s) => Some(s)
    _ => None
  }
}

///|
fn sql_message(e : Error) -> String {
  match e {
    @wire.ShellError(m) => m
    StoreError(m) => m
    Failure(m) => m
    e => e.to_string()
  }
}

///|
/// A store on `db`, opened as store.ts's constructor and `open` read what they read once (which old lookups this
/// database has, the sessions with a note of their chat's move untold).
pub fn Store::new(db : @sql.Db, now : Double) -> Store raise {
  let decision_session = if exists(db, "index", "decision_checks_session") {
    None
  } else if has_shared_decision_session(db) {
    Some("shared")
  } else if has_session_lookup(db, "legacy_decision_session") {
    Some("separate")
  } else if has_session_lookup(db, "legacy_decision_session_repair") {
    Some("repair")
  } else {
    None
  }
  let store = {
    db,
    now,
    legacy_said: has_legacy_said(db),
    legacy_agent: @legacy.has_legacy_agent(db),
    legacy_login_cards: has_legacy_login_cards(db),
    legacy_archive_policy: has_legacy_archive_policy(db),
    legacy_decision_time: has_legacy_decision_time(db),
    legacy_decision_session: decision_session,
    decision_session_index_was_missing: false,
    decisions: 0,
    moved_untold: Map([]),
    depth: 0,
    sent: [],
    requested: [],
    scan_guard_schema: None,
    restate_guard_schema: None,
    outbox_schema: None,
    archive_last_schema: None,
    seed: (now.to_int64().reinterpret_as_uint64() ^ 0x9E3779B97F4A7C15UL) | 1UL,
  }
  for r in db.all("SELECT session FROM moved_notes WHERE told_at IS NULL", []) {
    if col(r, "session") is String(s) {
      store.moved_untold[s] = true
    }
  }
  store
}

///|
/// store.ts `#with`: runs `run`, then tells what it says changed, also when it failed part way.
fn[T] Store::with_(self : Store, run : (Array[Json]) -> T raise) -> T raise {
  let changes : Array[Json] = []
  let result = run(changes) catch {
    e => {
      self.sent.push_iter(changes.iter())
      raise e
    }
  }
  self.sent.push_iter(changes.iter())
  result
}

///|
fn Store::busy_timeout(self : Store) -> Int raise {
  match one(self.db, "PRAGMA busy_timeout", []) {
    Some(r) => num(col(r, "timeout")).to_int()
    None => 0
  }
}

///|
/// store.ts `#tx`: a transaction that writes, committed when `run` returns, rolled back when it raises; `try_write`
/// begins it without waiting for another writer (MessageWriteBusy).
fn[T] Store::tx(self : Store, run : () -> T raise, try_write? : Bool = false) -> T raise {
  if try_write {
    let timeout = self.busy_timeout()
    self.db.exec("PRAGMA busy_timeout=0")
    let mut begun = false
    let mut failed : Error? = None
    (try self.db.exec("BEGIN IMMEDIATE") catch {
      e => failed = Some(if @sql.busy(e) { (MessageWriteBusy : Error) } else { e })
    } noraise {
      _ => begun = true
    })
    self.db.exec("PRAGMA busy_timeout=\{timeout}") catch {
      e => {
        if begun {
          self.db.exec("ROLLBACK") catch {
            _ => ()
          }
        }
        raise e
      }
    }
    if failed is Some(e) {
      raise e
    }
  } else {
    self.db.exec("BEGIN IMMEDIATE")
  }
  self.depth += 1
  let result = run() catch {
    e => {
      self.depth -= 1
      self.db.exec("ROLLBACK") catch {
        _ => ()
      }
      raise e
    }
  }
  self.depth -= 1
  self.db.exec("COMMIT")
  result
}

///|
/// store.ts `#tryNow`: background work yields where another connection has the write lock.
fn[T] Store::try_now(self : Store, run : () -> T raise) -> T raise {
  let timeout = self.busy_timeout()
  self.db.exec("PRAGMA busy_timeout=0")
  let result = run() catch {
    e => {
      self.db.exec("PRAGMA busy_timeout=\{timeout}")
      if @sql.busy(e) {
        raise MessageWriteBusy
      }
      raise e
    }
  }
  self.db.exec("PRAGMA busy_timeout=\{timeout}")
  result
}

///|
/// A savepoint held while `run` reads, released after it whatever it does.
fn[T] Store::snapshot(self : Store, name : String, run : () -> T raise) -> T raise {
  self.db.exec("SAVEPOINT \{name}")
  self.depth += 1
  let result = run() catch {
    e => {
      self.depth -= 1
      self.db.exec("RELEASE \{name}") catch {
        _ => ()
      }
      raise e
    }
  }
  self.depth -= 1
  self.db.exec("RELEASE \{name}")
  result
}

///|
fn Store::one(self : Store, sql : String, params : Array[Json]) -> Map[String, Json]? raise {
  one(self.db, sql, params)
}

///|
fn Store::all(self : Store, sql : String, params : Array[Json]) -> Array[Map[String, Json]] raise {
  self.db.all(sql, params)
}

///|
fn Store::run(self : Store, sql : String, params : Array[Json]) -> Int raise {
  self.db.run(sql, params)
}

///|
fn Store::now_json(self : Store) -> Json {
  Json::number(self.now)
}

///|
/// 16 random bytes in hex, as `randomBytes(16).toString("hex")`.
fn Store::token(self : Store) -> String {
  let out = StringBuilder()
  for _ in 0..<2 {
    // xorshift64*
    let mut x = self.seed
    x = x ^ (x >> 12)
    x = x ^ (x << 25)
    x = x ^ (x >> 27)
    self.seed = x
    let v = x * 0x2545F4914F6CDD1DUL
    out.write_string(@codec.hex_encode(Bytes::makei(8, i => ((v >> (56 - i * 8)) & 255UL).to_int().to_byte())))
  }
  out.to_string()
}

///|
/// `PRAGMA schema_version` (restate-guard.ts `restateGuardSchema`).
fn schema_version(db : @sql.Db) -> Int raise {
  match one(db, "PRAGMA schema_version", []) {
    Some(r) => num(col(r, "schema_version")).to_int()
    None => 0
  }
}

///|
/// `JSON.parse` of a column, or none where it is not text that parses (rows.ts `parsed`).
fn parsed(v : Json) -> @jsjson.JValue? {
  match v {
    String(s) => @jsjson.jval_try_parse(s)
    _ => None
  }
}

///|
fn jget(v : @jsjson.JValue, k : String) -> @jsjson.JValue? {
  @jsjson.jval_at(Some(v), k)
}

///|
/// `{ ...v, [k]: x }`: `k` replaced where it is, else put last (JavaScript's spread keeps a key's first place).
fn jset(v : @jsjson.JValue, k : String, x : @jsjson.JValue) -> @jsjson.JValue {
  let key = @jsjson.units(k)
  let fields : Array[(Array[Int], @jsjson.JValue)] = match v {
    Obj(fs) => fs.copy()
    Arr(xs) => xs.mapi((i, x) => (@jsjson.units(i.to_string()), x))
    Str(s) => s.mapi((i, c) => (@jsjson.units(i.to_string()), @jsjson.JValue::Str([c])))
    _ => []
  }
  match fields.search_by(f => f.0 == key) {
    Some(i) => fields[i] = (key, x)
    None => fields.push((key, x))
  }
  // JSON.parse of JSON.stringify puts integer-like keys first, as the object itself holds them
  @jsjson.parse(stringify(Obj(fields))) catch {
    _ => Obj(fields)
  }
}
