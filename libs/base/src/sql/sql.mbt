// A database in the shell (SQLite), asked synchronously: the shell's `sql.*` ops, answered at once (`Shell::ask`), as
// the device base in TypeScript asks them (client/core-ts/src/hosts/bridge.ts `BridgeSql`):
//   sql.open {name} → {id} (`:memory:` one in memory); sql.attach {path, create, wait} → {id};
//   sql.exec {id, sql}; sql.run {id, sql, params} → changes; sql.all {id, sql, params} → rows (arrays);
//   sql.close {id}; sql.delete {name}.
// A row is an array of JSON values: SQLite's integers and reals as numbers, text as strings, a blob as an array of
// its bytes, NULL as null. What a program keeps in its database, and its schema, are the program's.

///|
/// One database the shell holds open, by its handle there.
pub struct Sql {
  shell : @shell.Shell
  id : Int
  priv mut closed : Bool
}

///|
/// The handle a `sql.open` or `sql.attach` answered.
fn handle_of(op : String, answer : Json) -> Int raise @shell.ShellError {
  match answer {
    { "id": Number(n, ..), .. } => n.to_int()
    _ => raise @shell.ShellError("\{op} answered no handle: \{answer.stringify()}")
  }
}

///|
/// The database `name` of the program's (a file of its own beside the shell's others), or one in memory
/// (`:memory:`): held for this process alone.
pub fn Sql::open(shell : @shell.Shell, name : String) -> Sql raise @shell.ShellError {
  let id = handle_of("sql.open", shell.ask("sql.open", { "name": Json::string(name) }))
  { shell, id, closed: false }
}

///|
/// A database another process keeps and writes as well, by its path: made only with `create`, waited for `wait_ms`
/// while it is busy.
pub fn Sql::attach(
  shell : @shell.Shell,
  path : String,
  create? : Bool = true,
  wait_ms? : Int = 5000,
) -> Sql raise @shell.ShellError {
  let args : Json = {
    "path": Json::string(path),
    "create": Json::boolean(create),
    "wait": Json::number(wait_ms.to_double()),
  }
  let id = handle_of("sql.attach", shell.ask("sql.attach", args))
  { shell, id, closed: false }
}

///|
/// Whether it was closed (`Sql::close`): asked of after, the shell says it has no such database.
pub fn Sql::is_closed(self : Sql) -> Bool {
  self.closed
}

///|
/// Runs `sql`, one statement or several, binding nothing.
pub fn Sql::exec(self : Sql, sql : String) -> Unit raise @shell.ShellError {
  ignore(
    self.shell.ask("sql.exec", { "id": Json::number(self.id.to_double()), "sql": Json::string(sql) }),
  )
}

///|
/// Runs one statement with `params` bound: how many rows it changed.
pub fn Sql::run(self : Sql, sql : String, params? : Array[Json] = []) -> Int raise @shell.ShellError {
  let answer = self.shell.ask("sql.run", {
    "id": Json::number(self.id.to_double()),
    "sql": Json::string(sql),
    "params": Json::array(params),
  })
  match answer {
    Number(n, ..) => n.to_int()
    _ => 0
  }
}

///|
/// The rows of one statement with `params` bound, each an array of its columns' values.
pub fn Sql::all(self : Sql, sql : String, params? : Array[Json] = []) -> Array[Array[Json]] raise @shell.ShellError {
  let answer = self.shell.ask("sql.all", {
    "id": Json::number(self.id.to_double()),
    "sql": Json::string(sql),
    "params": Json::array(params),
  })
  match answer {
    Array(rows) =>
      rows.map(row => match row {
        Array(cols) => cols
        _ => []
      })
    _ => raise @shell.ShellError("sql.all answered no rows: \{answer.stringify()}")
  }
}

///|
/// Closes it, once: again does nothing, and what the shell says of closing it is not waited on.
pub fn Sql::close(self : Sql) -> Unit {
  if self.closed {
    return
  }
  self.closed = true
  ignore(self.shell.ask("sql.close", { "id": Json::number(self.id.to_double()) })) catch {
    _ => ()
  }
}

///|
/// Removes the program's database `name` (its file and the files SQLite keeps beside it); handles to it are let go.
pub fn delete_db(shell : @shell.Shell, name : String) -> Unit raise @shell.ShellError {
  ignore(shell.ask("sql.delete", { "name": Json::string(name) }))
}

// ── reading a row ──

///|
/// Column `i` as text: a number written out, anything else (NULL, past the row) empty.
pub fn col_text(row : Array[Json], i : Int) -> String {
  match row.get(i) {
    Some(String(s)) => s
    Some(Number(n, ..)) => if n == n.to_int64().to_double() { n.to_int64().to_string() } else { n.to_string() }
    _ => ""
  }
}

///|
/// Column `i` as text, none where it is NULL or not text.
pub fn col_opt_text(row : Array[Json], i : Int) -> String? {
  match row.get(i) {
    Some(String(s)) => Some(s)
    _ => None
  }
}

///|
/// Column `i` as an integer, 0 where it is none.
pub fn col_int(row : Array[Json], i : Int) -> Int {
  match row.get(i) {
    Some(Number(n, ..)) => n.to_int()
    Some(True) => 1
    _ => 0
  }
}

///|
/// Column `i` as a 64-bit integer (a time in ms), 0 where it is none.
pub fn col_int64(row : Array[Json], i : Int) -> Int64 {
  match row.get(i) {
    Some(Number(n, ..)) => n.to_int64()
    Some(True) => 1L
    _ => 0L
  }
}

///|
/// Column `i` as a 64-bit integer, none where it is NULL or no number.
pub fn col_opt_int64(row : Array[Json], i : Int) -> Int64? {
  match row.get(i) {
    Some(Number(n, ..)) => Some(n.to_int64())
    _ => None
  }
}

///|
/// Column `i` as a real, 0 where it is none.
pub fn col_double(row : Array[Json], i : Int) -> Double {
  match row.get(i) {
    Some(Number(n, ..)) => n
    _ => 0.0
  }
}

///|
/// Column `i` as SQLite keeps a flag: true where it is a number other than 0 (or JSON's true).
pub fn col_bool(row : Array[Json], i : Int) -> Bool {
  match row.get(i) {
    Some(Number(n, ..)) => n != 0.0
    Some(True) => true
    _ => false
  }
}
