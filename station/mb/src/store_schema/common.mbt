// What every installer here asks of the database (as station/src/store's `exists`, `has`, `made`, a write of its own):
// the schema's names, a table's columns, a row, and a transaction that begins IMMEDIATE and is let go whole on a failure.

///|
/// Whether the schema has a `kind` (table, index, trigger, view) named `name`.
fn exists(db : @sql.Db, kind : String, name : String) -> Bool raise {
  db.all("SELECT 1 FROM sqlite_master WHERE type=? AND name=?", [Json::string(kind), Json::string(name)]).length() > 0
}

///|
/// A schema object's definition (`sqlite_master.sql`), None where there is none of that name.
fn sql_of(db : @sql.Db, kind : String, name : String) -> String? raise {
  match db.all("SELECT sql FROM sqlite_master WHERE type=? AND name=?", [Json::string(kind), Json::string(name)]) {
    [row, ..] =>
      match row.get("sql") {
        Some(String(s)) => Some(s)
        _ => None
      }
    _ => None
  }
}

///|
/// Whether `sql` gives a row.
fn some_row(db : @sql.Db, sql : String, params? : Array[Json] = []) -> Bool raise {
  db.all(sql, params).length() > 0
}

///|
/// The first row `sql` gives.
fn first_row(db : @sql.Db, sql : String, params? : Array[Json] = []) -> Map[String, Json]? raise {
  match db.all(sql, params) {
    [row, ..] => Some(row)
    _ => None
  }
}

///|
/// A column of a table (schema.ts `has`, by pragma_table_info).
fn has(db : @sql.Db, table : String, column : String) -> Bool raise {
  some_row(db, "SELECT 1 FROM pragma_table_info('\{table}') WHERE name = ?", params=[Json::string(column)])
}

///|
/// A table's columns (`PRAGMA table_info`).
fn columns(db : @sql.Db, table : String) -> Array[String] raise {
  db
  .all("PRAGMA table_info(\{table})", [])
  .filter_map(row => match row.get("name") {
    Some(String(name)) => Some(name)
    _ => None
  })
}

///|
/// A number a row holds, None for none (NULL, or no number).
fn num(row : Map[String, Json]?, key : String) -> Double? {
  match row {
    Some(r) =>
      match r.get(key) {
        Some(Number(n, ..)) => Some(n)
        _ => None
      }
    None => None
  }
}

///|
/// Whether a row holds the number `n` at `key` (TypeScript's `row.key === n`).
fn is_num(row : Map[String, Json]?, key : String, n : Int) -> Bool {
  num(row, key) == Some(n.to_double())
}

///|
/// A number as the text JavaScript writes it into an error (`${row.version}`): an integer without its point, a row
/// with no such value "undefined"'s stand-in, `missing` where the TypeScript said so.
fn shown(row : Map[String, Json]?, key : String, missing : String) -> String {
  match row {
    Some(r) =>
      match r.get(key) {
        Some(Number(_, repr=Some(text))) => text
        Some(Number(n, ..)) => if n == n.floor() && n.abs() < 1.0e15 { n.to_int64().to_string() } else { n.to_string() }
        Some(String(s)) => s
        Some(Null) => "null"
        _ => missing
      }
    None => missing
  }
}

///|
/// `body` in a write of its own (BEGIN IMMEDIATE … COMMIT), rolled back where it fails.
fn immediate(db : @sql.Db, body : () -> Unit raise) -> Unit raise {
  db.exec("BEGIN IMMEDIATE")
  errdefer (db.exec("ROLLBACK") catch { _ => () })
  body()
  db.exec("COMMIT")
}

///|
/// What the TypeScript station throws as an Error, its words as they are (no place of the code's in them).
pub(all) suberror Refused {
  Refused(String)
}

///|
/// Its words where it is said (`to_string`, a notice, a log): not its type's name (`station/<package>.<Type>`).
pub impl Show for Refused with output(self, logger) {
  match self {
    Refused(m) => logger.write_string(m)
  }
}

///|
fn[T] refuse(message : String) -> T raise Refused {
  raise Refused(message)
}
