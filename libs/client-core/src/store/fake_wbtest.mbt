// An account's database stood in for the store's tests: a shell (`@shell.Shell::stood_in`) answering the `sql.*` ops
// this package runs from tables in memory (`entry`, `md_kept`, `log_use`), so the tests run natively and on js with
// no SQLite linked. It answers the statements the store runs (md.mbt, open.mbt) and no other: one it does not know
// fails the test, naming it. It keeps every statement run, so a test counts them: all, writes, and those that read
// `md_kept`. A transaction is counted, not modelled: what is written is written at once.

///|
priv struct MdRow {
  size : Int
  used : Int64
  json : String
}

///|
priv struct FakeDb {
  shell : @shell.Shell
  /// A chat's entries, by `station thread`: their numbers and JSON, in order.
  entries : Map[String, Array[(Int, String)]]
  /// `md_kept`, by `station key`; in the order put (its `ORDER BY used` sorts them).
  md : Map[String, MdRow]
  log_use : Map[String, Int64]
  /// Every statement run, in order.
  ran : Array[String]
}

///|
fn FakeDb::new() -> FakeDb {
  let db : Ref[FakeDb?] = Ref(None)
  let shell = @shell.Shell::stood_in(
    @effect.Runtime::new(),
    calls=(_, _, _, _) => (),
    asks=(op, args) => db.val.unwrap().answer(op, args),
    draws=n => Bytes::make(n, b'\x00'),
  )
  let fake : FakeDb = { shell, entries: Map([]), md: Map([]), log_use: Map([]), ran: [] }
  db.val = Some(fake)
  fake
}

///|
fn str_at(params : Array[Json], i : Int) -> String {
  match params.get(i) {
    Some(String(s)) => s
    Some(Number(n, ..)) => n.to_int64().to_string()
    _ => ""
  }
}

///|
fn int_at(params : Array[Json], i : Int) -> Int64 {
  match params.get(i) {
    Some(Number(n, ..)) => n.to_int64()
    _ => 0L
  }
}

///|
fn FakeDb::answer(self : FakeDb, op : String, args : Json) -> Json raise @shell.ShellError {
  match op {
    "sql.open" => return { "id": 1 }
    "sql.close" => return Json::null()
    _ => ()
  }
  let sql = match args {
    { "sql": String(s), .. } => s
    _ => raise @shell.ShellError("no statement")
  }
  let p = match args {
    { "params": Array(a), .. } => a
    _ => []
  }
  self.ran.push(sql)
  if op == "sql.exec" {
    if sql == "BEGIN IMMEDIATE" || sql == "COMMIT" || sql == "ROLLBACK" || sql == sql_md_make {
      return Json::null()
    }
    raise @shell.ShellError("the fake database does not know: \{sql}")
  }
  let rows : Array[Json] = []
  let changed = Ref(0)
  if sql == sql_window_end {
    let all = self.entries.get("\{str_at(p, 0)} \{str_at(p, 1)}").unwrap_or([])
    let most = int_at(p, 2).to_int()
    for i = all.length() - 1; i >= 0 && rows.length() < most; i = i - 1 {
      rows.push([Json::number(all[i].0.to_double()), Json::string(all[i].1)])
    }
  } else if sql == sql_window_at {
    let all = self.entries.get("\{str_at(p, 0)} \{str_at(p, 1)}").unwrap_or([])
    let (lo, hi) = (int_at(p, 2).to_int(), int_at(p, 3).to_int())
    for e in all {
      if e.0 >= lo && e.0 <= hi {
        rows.push([Json::number(e.0.to_double()), Json::string(e.1)])
      }
    }
  } else if sql.has_prefix(sql_md_many_head) {
    let station = str_at(p, 0)
    for i in 1..<p.length() {
      let key = str_at(p, i)
      if self.md.get("\{station} \{key}") is Some(r) {
        rows.push([Json::string(key), Json::number(r.used.to_double()), Json::string(r.json)])
      }
    }
  } else if sql == sql_md_one {
    if self.md.get("\{str_at(p, 0)} \{str_at(p, 1)}") is Some(r) {
      rows.push([Json::number(r.used.to_double()), Json::string(r.json)])
    }
  } else if sql == sql_opened {
    if self.log_use.get("\{str_at(p, 0)} \{str_at(p, 1)} \{str_at(p, 2)}") is Some(at) {
      rows.push([Json::number(at.to_double())])
    }
  } else if sql == sql_note_opened {
    self.log_use.set("\{str_at(p, 0)} \{str_at(p, 1)} \{str_at(p, 2)}", int_at(p, 3))
    changed.val = 1
  } else if sql == sql_md_touch {
    let k = "\{str_at(p, 1)} \{str_at(p, 2)}"
    if self.md.get(k) is Some(r) {
      self.md.set(k, { ..r, used: int_at(p, 0) })
      changed.val = 1
    }
  } else if sql == sql_md_total {
    let mut sum = 0
    for _, r in self.md {
      sum += r.size
    }
    rows.push([Json::number(sum.to_double())])
  } else if sql == sql_md_size {
    if self.md.get("\{str_at(p, 0)} \{str_at(p, 1)}") is Some(r) {
      rows.push([Json::number(r.size.to_double())])
    }
  } else if sql == sql_md_drop {
    let k = "\{str_at(p, 0)} \{str_at(p, 1)}"
    if self.md.contains(k) {
      self.md.remove(k)
      changed.val = 1
    }
  } else if sql == sql_md_put {
    self.md.set("\{str_at(p, 0)} \{str_at(p, 1)}", {
      size: int_at(p, 3).to_int(),
      used: int_at(p, 4),
      json: str_at(p, 5),
    })
    changed.val = 1
  } else if sql == sql_md_by_use {
    let all : Array[(String, MdRow)] = self.md.iter().collect()
    all.sort_by((a, b) => a.1.used.compare(b.1.used))
    for e in all {
      guard e.0.find(" ") is Some(sp) else { continue }
      rows.push([
        Json::string(e.0.clamped_view(end=sp).to_owned()),
        Json::string(e.0.clamped_view(start=sp + 1).to_owned()),
        Json::number(e.1.size.to_double()),
      ])
    }
  } else {
    raise @shell.ShellError("the fake database does not know: \{sql}")
  }
  if op == "sql.run" {
    Json::number(changed.val.to_double())
  } else {
    Json::array(rows)
  }
}

///|
/// Whether a statement writes.
fn writes(sql : String) -> Bool {
  sql.has_prefix("INSERT") ||
  sql.has_prefix("UPDATE") ||
  sql.has_prefix("DELETE") ||
  sql.has_prefix("CREATE") ||
  sql.has_prefix("BEGIN") ||
  sql.has_prefix("COMMIT")
}

///|
/// What ran since `from`: all, writes, reads of `md_kept`, transactions begun and committed.
fn FakeDb::since(self : FakeDb, from : Int) -> (Int, Int, Int, Int, Int) {
  let ran = self.ran[from:]
  let mut w = 0
  let mut md = 0
  let mut begun = 0
  let mut committed = 0
  for s in ran {
    if writes(s) {
      w += 1
    }
    if s.has_prefix("SELECT") && s.contains("FROM md_kept") {
      md += 1
    }
    if s == "BEGIN IMMEDIATE" {
      begun += 1
    }
    if s == "COMMIT" {
      committed += 1
    }
  }
  (ran.length(), w, md, begun, committed)
}

///|
fn FakeDb::put_entry(self : FakeDb, station : String, thread : Int, n : Int, json : Json) -> Unit {
  let k = "\{station} \{thread}"
  let all = match self.entries.get(k) {
    Some(a) => a
    None => {
      let a = []
      self.entries.set(k, a)
      a
    }
  }
  all.push((n, json.stringify()))
}

///|
fn FakeDb::put_tree(self : FakeDb, station : String, key : String, json : String, used : Int64) -> Unit {
  self.md.set("\{station} \{key}", { size: json.length(), used, json })
}
