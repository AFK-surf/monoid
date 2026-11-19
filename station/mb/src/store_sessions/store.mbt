// The station's store of its sessions, as station/src/store/store.ts keeps them (the methods of `Store` but a thread's
// messages, letters, deliveries and cards, and the schema's making): the same statements, in the same order, on the
// same database, each change told as the TypeScript tells it (`StoreChange`, in its words), at the same points, and
// what it keeps in memory (a session's workspace, a token's session, where a chat was handed, the notes of chats moved
// here not told, the titles named by hand) kept and forgotten as it does. A write that is more than one statement is
// one transaction begun BEGIN IMMEDIATE, as station/AGENTS.md says every one is.

///|
pub struct Store {
  db : @sql.Db
  /// Now, in ms (store.ts `now`: its Clock's).
  priv clock : () -> Int64
  /// The last migration note there is (agents/migrations.ts `latest`): what a new session begins told.
  mut latest_note : Int64
  priv efforts_index : Bool
  priv mut listeners : Array[(Int32, (Json) -> Unit)]
  priv mut workspace_listeners : Array[(Int32, () -> Unit)]
  priv mut next_listener : Int32
  /// A session's workspace (null: the home one's), as `sessionWs` keeps it.
  priv ws_of : Map[String, Json]
  /// A tool call's token's session (`sessionKeyByToken`).
  priv token_key : Map[String, String]
  /// Where a session was handed (null: nowhere), as `handedTo` keeps it.
  priv handed : Map[String, Json]
  /// The sessions with a note of their chat having moved here not told yet.
  priv moved_untold : Map[String, Unit]
  /// Titles named by hand in this process (`titleRevision`).
  priv title_revisions : Map[Int64, Int32]
  /// How deep in a transaction (or a savepoint) this connection is: `db.isTransaction`.
  priv mut depth : Int32
  /// Whether the chats' shares are indexed (chat-share-index.ts `presence`), once asked.
  priv mut share_index : Bool?
  /// Whether the contexts are kept (usage-compact.ts `hasCompactUsage`), once they are.
  priv mut compact : Bool
  /// Whether the totals were made incremental (usage-totals-source.ts `incrementalTotals`), once asked.
  priv mut incremental : Bool?
}

///|
/// The store on database `db` (its schema made: store.ts `Store.open`), its time `clock`'s, a new session told the
/// notes up to `latest_note`.
pub fn Store::open(
  db : @sql.Db,
  clock : () -> Int64,
  latest_note : Int64,
) -> Store raise {
  let efforts_index = db
    .all(
      "SELECT 1 FROM sqlite_master WHERE type = 'index' AND name = 'sessions_efforts'",
      [],
    )
    .length() >
    0
  let store = {
    db,
    clock,
    latest_note,
    efforts_index,
    listeners: [],
    workspace_listeners: [],
    next_listener: 0,
    ws_of: Map([]),
    token_key: Map([]),
    handed: Map([]),
    moved_untold: Map([]),
    title_revisions: Map([]),
    depth: 0,
    share_index: None,
    compact: false,
    incremental: None,
  }
  // (read once here, so that a turn asks nothing of it unless its session has one)
  for r in db.all("SELECT session FROM moved_notes WHERE told_at IS NULL", []) {
    if col(r, "session") is String(s) {
      store.moved_untold[s] = ()
    }
  }
  store
}

///|
/// Now, by its clock.
pub fn Store::now(self : Store) -> Int64 {
  (self.clock)()
}

///|
fn Store::now_json(self : Store) -> Json {
  jint(self.now())
}

///|
/// Hears what changes from now on; the function returned stops it.
pub fn Store::subscribe(self : Store, listener : (Json) -> Unit) -> () -> Unit {
  let id = self.next_listener
  self.next_listener += 1
  self.listeners = self.listeners + [(id, listener)]
  () => self.listeners = self.listeners.filter(l => l.0 != id)
}

///|
/// Tells internal workers when session ownership changes, after the database write has committed.
pub fn Store::on_session_workspace_change(
  self : Store,
  listener : () -> Unit,
) -> () -> Unit {
  let id = self.next_listener
  self.next_listener += 1
  self.workspace_listeners = self.workspace_listeners + [(id, listener)]
  () => {
    self.workspace_listeners = self.workspace_listeners.filter(l => l.0 != id)
  }
}

///|
fn Store::session_workspace_changed(self : Store) -> Unit {
  for l in self.workspace_listeners {
    (l.1)()
  }
}

///|
/// What another writer of the database wrote, told those who follow the store as its own writes are.
pub fn Store::told(self : Store, changes : Array[Json]) -> Unit {
  self.send(changes)
}

///|
fn Store::send(self : Store, changes : Array[Json]) -> Unit {
  let listeners = self.listeners
  for change in changes {
    for l in listeners {
      (l.1)(change)
    }
  }
}

///|
/// Store::with: runs `run`, then tells what it says changed (also when it failed part way).
fn[T] Store::with_changes(
  self : Store,
  run : (Array[Json]) -> T raise,
) -> T raise {
  let changes = []
  errdefer self.send(changes)
  let result = run(changes)
  self.send(changes)
  result
}

///|
/// A transaction that writes (BEGIN IMMEDIATE), committed when `run` returns, rolled back when it raises.
fn[T] Store::tx(self : Store, run : () -> T raise) -> T raise {
  self.db.exec("BEGIN IMMEDIATE")
  self.depth += 1
  errdefer {
    self.depth -= 1
    self.db.exec("ROLLBACK") catch {
      _ => ()
    }
  }
  let result = run()
  self.depth -= 1
  self.db.exec("COMMIT")
  result
}

///|
/// `run` in a savepoint `name`, released however it ends (store.ts's `SAVEPOINT …` … `finally RELEASE`).
fn[T] Store::savepoint(
  self : Store,
  name : String,
  run : () -> T raise,
) -> T raise {
  self.db.exec("SAVEPOINT \{name}")
  self.depth += 1
  errdefer {
    self.depth -= 1
    self.db.exec("RELEASE \{name}") catch {
      _ => ()
    }
  }
  let result = run()
  self.depth -= 1
  self.db.exec("RELEASE \{name}")
  result
}

///|
/// A read-only transaction of its own (BEGIN, deferred: it writes nothing), committed as `run` returns.
fn[T] Store::reading(self : Store, run : () -> T raise) -> T raise {
  self.db.exec("BEGIN") // deferred: it only reads (chat-share-index.ts `snapshot`)
  self.depth += 1
  errdefer {
    self.depth -= 1
    self.db.exec("ROLLBACK") catch {
      _ => ()
    }
  }
  let result = run()
  self.depth -= 1
  self.db.exec("COMMIT")
  result
}

///|
fn Store::in_tx(self : Store) -> Bool {
  self.depth > 0
}

///|
fn Store::one(
  self : Store,
  sql : String,
  args : Array[Json],
) -> Map[String, Json]? raise {
  let rows = self.db.all(sql, args)
  if rows.length() > 0 {
    Some(rows[0])
  } else {
    None
  }
}

///|
fn Store::all(
  self : Store,
  sql : String,
  args : Array[Json],
) -> Array[Map[String, Json]] raise {
  self.db.all(sql, args)
}

///|
/// How many rows it changed.
fn Store::run(self : Store, sql : String, args : Array[Json]) -> Int32 raise {
  self.db.run(sql, args)
}

///|
fn Store::table(self : Store, name : String) -> Bool raise {
  self.one("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?", [
    jstr(name),
  ])
  is Some(_)
}

///|
/// Announces a change the station keeps outside the database (e.g. a runtime process ending).
pub fn Store::notify(self : Store, session : String) -> Unit {
  self.send([{ "type": "session", "key": jstr(session) }])
}

///|
fn session_change(key : Json) -> Json {
  { "type": "session", "key": key }
}

///|
fn thread_change(id : Json) -> Json {
  { "type": "thread", "id": id, "entries": [] }
}

///|
/// store.ts `#updateSession`.
fn Store::update_session(
  self : Store,
  key : String,
  sql : String,
  args : Array[Json],
) -> Unit raise {
  self.with_changes(changes => {
    ignore(self.run(sql, args))
    changes.push(session_change(jstr(key)))
  })
}

///|
/// What a raised error says (the harness's `error`).
pub(all) suberror StoreError {
  StoreError(String, Json)
}

///|
/// Its words where it is said (`to_string`, a notice, a log): not its type's name (`station/<package>.<Type>`).
pub impl Show for StoreError with output(self, logger) {
  match self {
    StoreError(m, _) => logger.write_string(m)
  }
}

///|
fn store_error(message : String) -> StoreError {
  StoreError(message, Json::null())
}
