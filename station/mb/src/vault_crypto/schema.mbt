// A vault index's schema put in as the vault is made (station/src/vault/schema-install.ts): what is there already only
// read, what is missing put in with the write taken first (BEGIN IMMEDIATE, waiting its turn), or in the transaction
// the caller has open. A schema is told installed only by what it names, so it may hold nothing else: `CREATE
// TABLE|INDEX|TRIGGER IF NOT EXISTS` and the `INSERT OR IGNORE INTO` of a table a query of `rows` looks in; anything
// else is refused, saying which. The same reading of a schema as schema-install.ts's regular expressions.

///|
/// A schema holding a statement `install_schema` cannot tell is done.
pub suberror UnaccountedSchema {
  UnaccountedSchema(String)
}

///|
pub impl Show for UnaccountedSchema with output(self, logger) {
  match self {
    UnaccountedSchema(m) => logger.write_string(m)
  }
}

///|
fn word_char(c : Int) -> Bool {
  (c >= 48 && c <= 57) || (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95
}

///|
fn upper(c : Int) -> Int {
  if c >= 97 && c <= 122 {
    c - 32
  } else {
    c
  }
}

///|
/// Whether `w` (upper case) is at `i`, of any case.
fn word_at(s : String, i : Int, w : String) -> Bool {
  if i + w.length() > s.length() {
    return false
  }
  for k in 0..<w.length() {
    if upper(s.code_unit_at(i + k).to_int()) != w.code_unit_at(k).to_int() {
      return false
    }
  }
  true
}

///|
/// Past `\s+` at `i`; None where there is none.
fn spaces(s : String, i : Int) -> Int? {
  let mut j = i
  while j < s.length() && js_space(s.code_unit_at(j).to_int()) {
    j = j + 1
  }
  if j > i {
    Some(j)
  } else {
    None
  }
}

///|
/// Past `\w+` at `i`; None where there is none.
fn word(s : String, i : Int) -> Int? {
  let mut j = i
  while j < s.length() && word_char(s.code_unit_at(j).to_int()) {
    j = j + 1
  }
  if j > i {
    Some(j)
  } else {
    None
  }
}

///|
/// `CREATE\s+<kind>\s+IF\s+NOT\s+EXISTS\s+(\w+)` at `i`, of any case: where its name starts and ends.
fn created_at(s : String, i : Int, kinds : Array[String]) -> (Int, Int)? {
  guard word_at(s, i, "CREATE") && spaces(s, i + 6) is Some(k) else { return None }
  let mut at = None
  for kind in kinds {
    if word_at(s, k, kind) {
      at = Some(k + kind.length())
      break
    }
  }
  guard at is Some(a) && spaces(s, a) is Some(a) else { return None }
  guard word_at(s, a, "IF") && spaces(s, a + 2) is Some(a) else { return None }
  guard word_at(s, a, "NOT") && spaces(s, a + 3) is Some(a) else { return None }
  guard word_at(s, a, "EXISTS") && spaces(s, a + 6) is Some(a) else { return None }
  guard word(s, a) is Some(end) else { return None }
  Some((a, end))
}

///|
/// `\bEND\s*;` at `i`: where it ends.
fn end_at(s : String, i : Int) -> Int? {
  if i > 0 && word_char(s.code_unit_at(i - 1).to_int()) {
    return None
  }
  guard word_at(s, i, "END") else { return None }
  let mut j = i + 3
  while j < s.length() && js_space(s.code_unit_at(j).to_int()) {
    j = j + 1
  }
  if j < s.length() && s.code_unit_at(j) == ';' {
    Some(j + 1)
  } else {
    None
  }
}

///|
/// `schema` without its `--` comments and its triggers (`CREATE TRIGGER IF NOT EXISTS method … END;`).
fn statements_of(schema : String) -> Array[String] {
  let b = StringBuilder()
  let mut i = 0
  while i < schema.length() {
    if schema.code_unit_at(i) == '-' && i + 1 < schema.length() && schema.code_unit_at(i + 1) == '-' {
      while i < schema.length() && schema.code_unit_at(i) != '\n' {
        i = i + 1
      }
    } else {
      b.write_char(schema.code_unit_at(i).to_int().unsafe_to_char())
      i = i + 1
    }
  }
  let s = b.to_string()
  let kept = StringBuilder()
  let mut at = 0
  while at < s.length() {
    let mut ended = None
    if created_at(s, at, ["TRIGGER"]) is Some((_, name_end)) {
      let mut j = name_end
      while j < s.length() {
        if end_at(s, j) is Some(e) {
          ended = Some(e)
          break
        }
        j = j + 1
      }
    }
    match ended {
      Some(e) => at = e
      None => {
        kept.write_char(s.code_unit_at(at).to_int().unsafe_to_char())
        at = at + 1
      }
    }
  }
  let out : Array[String] = []
  for part in kept.to_string().split(";") {
    // trimmed, its white space made one space each
    let w = StringBuilder()
    let mut gap = false
    let mut started = false
    for k in 0..<part.length() {
      let c = part.code_unit_at(k).to_int()
      if js_space(c) {
        gap = started
      } else {
        if gap {
          w.write_char(' ')
          gap = false
        }
        started = true
        w.write_char(c.unsafe_to_char())
      }
    }
    let st = w.to_string()
    if st != "" {
      out.push(st)
    }
  }
  out
}

///|
/// Whether `\bFROM <table>\b` is in `q`, of any case.
fn reads_from(q : String, table : String) -> Bool {
  let t = table.to_upper()
  for i in 0..<q.length() {
    if (i == 0 || !word_char(q.code_unit_at(i - 1).to_int())) && word_at(q, i, "FROM ") && word_at(q, i + 5, t) {
      let e = i + 5 + t.length()
      if e >= q.length() || !word_char(q.code_unit_at(e).to_int()) {
        return true
      }
    }
  }
  false
}

///|
let accounted : Map[String, Unit] = Map([])

///|
fn account(name : String, schema : String, rows : Array[String]) -> Unit raise UnaccountedSchema {
  if accounted.contains(schema) {
    return
  }
  for st in statements_of(schema) {
    if created_at(st, 0, ["TABLE", "INDEX", "UNIQUE INDEX"]) is Some(_) {
      continue
    }
    if word_at(st, 0, "INSERT OR IGNORE INTO ") && word(st, 22) is Some(e) {
      let table = st.unsafe_substring(start=22, end=e)
      if rows.iter().any(q => reads_from(q, table)) {
        continue
      }
    }
    let shown = if st.length() > 80 { st.unsafe_substring(start=0, end=80) } else { st }
    raise UnaccountedSchema(
      "the vault's schema \{name} holds a statement installSchema cannot tell is done: \{shown} (vault/schema-install.ts)",
    )
  }
  accounted[schema] = ()
}

///|
/// The names `schema` makes (`CREATE TABLE|INDEX|TRIGGER IF NOT EXISTS <name>`), each once.
fn named(schema : String) -> Array[String] {
  let names : Array[String] = []
  let mut i = 0
  while i < schema.length() {
    match created_at(schema, i, ["TABLE", "INDEX", "TRIGGER"]) {
      Some((a, e)) => {
        let n = schema.unsafe_substring(start=a, end=e)
        if !names.contains(n) {
          names.push(n)
        }
        i = e
      }
      None => i = i + 1
    }
  }
  names
}

///|
fn installed(db : Db, schema : String, rows : Array[String]) -> Bool raise DbError {
  let names = named(schema)
  let marks = names.map(_ => "?").join(",")
  let found = match db.get("SELECT count(*) AS n FROM sqlite_master WHERE name IN (\{marks})", names.map(Json::string)) {
    Some([Number(n, ..), ..]) => n.to_int()
    _ => -1
  }
  if found != names.length() {
    return false
  }
  for q in rows {
    if db.get(q, []) is None {
      return false
    }
  }
  true
}

///|
/// `schema`'s tables, indexes and triggers made where missing, and the rows `rows` look for (a query each, answering a
/// row when it is there) put in by it, all at once: nothing written where all of them are there.
pub fn install_schema(db : Db, name : String, schema : String, rows? : Array[String] = []) -> Unit raise {
  account(name, schema, rows)
  if db.in_transaction() {
    db.exec("SAVEPOINT \{name}")
    try {
      db.exec(schema)
      db.exec("RELEASE \{name}")
    } catch {
      error => {
        db.exec("ROLLBACK TO \{name}; RELEASE \{name}")
        raise error
      }
    }
    return
  }
  if installed(db, schema, rows) {
    return
  }
  db.exec("BEGIN IMMEDIATE")
  try {
    db.exec(schema)
    db.exec("COMMIT")
  } catch {
    error => {
      db.exec("ROLLBACK") catch {
        _ => ()
      }
      raise error
    }
  }
}
