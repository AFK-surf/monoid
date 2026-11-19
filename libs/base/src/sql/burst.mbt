// One writer's burst: what a turn writes goes in one transaction, begun by its first write and committed once, as the
// device base in TypeScript writes an account's database (client/core-ts/src/db/account.ts: `#write` begins
// `BEGIN IMMEDIATE` at the first write of a turn and commits it once the turn is over). A turn that writes nothing
// runs no SQL for it at all, and a read never begins one.

///|
/// The writes of one burst on `db`, in a transaction begun by the first of them.
pub struct Burst {
  db : Sql
  priv mut open : Bool
  /// How many transactions it began, and committed: for a program's measures and its tests.
  priv mut begun : Int
  priv mut committed : Int
}

///|
/// A burst on `db`, none of it begun.
pub fn Burst::new(db : Sql) -> Burst {
  { db, open: false, begun: 0, committed: 0 }
}

///|
/// Whether a transaction of it is open: something written and not yet committed or rolled back.
pub fn Burst::is_open(self : Burst) -> Bool {
  self.open
}

///|
/// How many transactions it began so far.
pub fn Burst::begun(self : Burst) -> Int {
  self.begun
}

///|
/// How many transactions it committed so far.
pub fn Burst::committed(self : Burst) -> Int {
  self.committed
}

///|
/// Its transaction begun where none is.
fn Burst::begin(self : Burst) -> Unit raise @shell.ShellError {
  if self.open {
    return
  }
  self.db.exec("BEGIN IMMEDIATE")
  self.open = true
  self.begun += 1
}

///|
/// Runs `sql` in the burst (`Sql::exec`), its transaction begun first where none is.
pub fn Burst::exec(self : Burst, sql : String) -> Unit raise @shell.ShellError {
  self.begin()
  self.db.exec(sql)
}

///|
/// Runs one statement in the burst (`Sql::run`), its transaction begun first where none is.
pub fn Burst::run(self : Burst, sql : String, params? : Array[Json] = []) -> Int raise @shell.ShellError {
  self.begin()
  self.db.run(sql, params~)
}

///|
/// Reads in the burst (`Sql::all`): what it wrote so far is seen, and no transaction is begun for it.
pub fn Burst::all(self : Burst, sql : String, params? : Array[Json] = []) -> Array[Array[Json]] raise @shell.ShellError {
  self.db.all(sql, params~)
}

///|
/// Commits what it wrote: nothing is run where it wrote nothing.
pub fn Burst::commit(self : Burst) -> Unit raise @shell.ShellError {
  if !self.open {
    return
  }
  // (closed first: a commit that fails leaves SQLite's transaction to the rollback the caller makes, or to the next
  // begin's failure, never this burst thinking one open that SQLite ended)
  self.open = false
  self.db.exec("COMMIT")
  self.committed += 1
}

///|
/// Undoes what it wrote: nothing is run where it wrote nothing. What SQLite says of a transaction it ended itself
/// (a failed statement that rolled it back) is not raised.
pub fn Burst::rollback(self : Burst) -> Unit {
  if !self.open {
    return
  }
  self.open = false
  self.db.exec("ROLLBACK") catch {
    _ => ()
  }
}

///|
/// Runs `f` as one transaction of the burst, committed once it returns; where it raises, what it wrote is rolled back
/// and its error raised again, so no transaction is left half done.
pub fn[T] Burst::in_tx(self : Burst, f : (Burst) -> T raise) -> T raise {
  errdefer self.rollback()
  let out = f(self)
  self.commit()
  out
}

// ── many keys in few statements ──

///|
/// SQLite's bound on a statement's parameters is 999 in its older builds: a statement takes at most this many keys
/// (as the device base in TypeScript reads many: account.ts `MD_MANY`).
pub let chunk_most : Int = 200

///|
/// `n` placeholders for an `IN (…)`: `?, ?, ?`.
pub fn placeholders(n : Int) -> String {
  let sb = StringBuilder()
  for i in 0..<n {
    if i > 0 {
      sb.write_string(", ")
    }
    sb.write_char('?')
  }
  sb.to_string()
}

///|
/// What `keys` find, read in as few statements as `chunk_size` keys a statement allows: each of `make_sql`'s statements
/// given the placeholders of its keys (`?, ?`), `extra_params` bound before them, its rows each `decode`d (none
/// left out). A key is asked once however often it is given; no keys run no statement.
pub fn[T] query_in_chunks(
  db : Sql,
  keys : Array[String],
  chunk_size? : Int = chunk_most,
  make_sql~ : (String) -> String,
  extra_params? : Array[Json] = [],
  decode~ : (Array[Json]) -> T?,
) -> Array[T] raise @shell.ShellError {
  let out : Array[T] = []
  if keys.is_empty() {
    return out
  }
  let seen : Set[String] = Set([])
  let unique : Array[String] = []
  for k in keys {
    if !seen.contains(k) {
      seen.add(k)
      unique.push(k)
    }
  }
  let size = if chunk_size < 1 { 1 } else { chunk_size }
  let mut at = 0
  while at < unique.length() {
    let end = if at + size < unique.length() { at + size } else { unique.length() }
    let params : Array[Json] = [..extra_params]
    for i in at..<end {
      params.push(Json::string(unique[i]))
    }
    for row in db.all(make_sql(placeholders(end - at)), params~) {
      if decode(row) is Some(v) {
        out.push(v)
      }
    }
    at = end
  }
  out
}
