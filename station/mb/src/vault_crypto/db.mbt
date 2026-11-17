// A database of the station's as the shell keeps it (client/shell `sql.*`): the plain library's tables and the vault's
// indexes' schemas are written through it (plain.mbt, schema.mbt).

///|
/// What the database refused, in SQLite's words.
pub suberror DbError {
  DbError(String)
}

///|
pub impl Show for DbError with output(self, logger) {
  match self {
    DbError(m) => logger.write_string(m)
  }
}

///|
/// A connection the shell holds (`sql.attach`), by its id.
pub(all) struct Db {
  ask : (String, Json) -> Result[Json, String]
  id : Int
}

///|
/// The database at `path` (made where it is not), waiting `wait` ms for another writer.
pub fn Db::attach(c : Crypto, path : String, wait? : Int = 5000) -> Db raise DbError {
  match (c.ask)("sql.attach", Json::object({ "path": Json::string(path), "create": Json::boolean(true), "wait": Json::number(wait.to_double()) })) {
    Ok({ "id": Number(id, ..), .. }) => { ask: c.ask, id: id.to_int() }
    Ok(_) => raise DbError("sql.attach: no id")
    Err(e) => raise DbError(e)
  }
}

///|
fn Db::call(self : Db, op : String, sql : String, params : Array[Json]) -> Json raise DbError {
  match (self.ask)(op, Json::object({ "id": Json::number(self.id.to_double()), "sql": Json::string(sql), "params": Json::array(params) })) {
    Ok(v) => v
    Err(e) => raise DbError(e)
  }
}

///|
/// Runs `sql` (statements, none with parameters).
pub fn Db::exec(self : Db, sql : String) -> Unit raise DbError {
  ignore(self.call("sql.exec", sql, []))
}

///|
/// Runs one statement with `params`: the rows it changed.
pub fn Db::run(self : Db, sql : String, params : Array[Json]) -> Int raise DbError {
  match self.call("sql.run", sql, params) {
    Number(n, ..) => n.to_int()
    _ => 0
  }
}

///|
/// The rows of one statement, each its columns' values.
pub fn Db::all(self : Db, sql : String, params : Array[Json]) -> Array[Array[Json]] raise DbError {
  let out : Array[Array[Json]] = []
  if self.call("sql.all", sql, params) is Array(rows) {
    for r in rows {
      if r is Array(cols) {
        out.push(cols)
      }
    }
  }
  out
}

///|
/// The first row, or None.
pub fn Db::get(self : Db, sql : String, params : Array[Json]) -> Array[Json]? raise DbError {
  let rows = self.all(sql, params)
  if rows.is_empty() {
    None
  } else {
    Some(rows[0])
  }
}

///|
/// Whether a transaction is open on it (node:sqlite's `isTransaction`).
pub fn Db::in_transaction(self : Db) -> Bool raise DbError {
  match (self.ask)("sql.inTransaction", Json::object({ "id": Json::number(self.id.to_double()) })) {
    Ok(True) => true
    Ok(_) => false
    Err(e) => raise DbError(e)
  }
}

///|
/// Lets the connection go.
pub fn Db::close(self : Db) -> Unit {
  ignore((self.ask)("sql.close", Json::object({ "id": Json::number(self.id.to_double()) })))
}
