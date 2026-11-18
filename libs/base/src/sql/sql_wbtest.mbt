// The database's tests on a shell stood in (`@shell.Shell::stood_in`): no SQLite is linked, and the same tests run
// natively and on js. The stand-in keeps every `sql.*` op asked of it, in order, and answers `sql.all` from what the
// test says (`rows`), so each test holds how many statements were run and which.

///|
/// One op asked: its name, its statement (none for open/close/delete), its parameters.
priv struct Asked {
  op : String
  sql : String
  params : Array[Json]
}

///|
priv struct Stand {
  shell : @shell.Shell
  asked : Array[Asked]
  /// What `sql.all` answers a statement and its parameters.
  mut rows : (String, Array[Json]) -> Array[Json]
  /// A statement that fails as SQLite would fail it.
  mut fails : (String) -> Bool
}

///|
fn Stand::new() -> Stand {
  let asked : Array[Asked] = []
  let stand : Ref[Stand?] = Ref(None)
  let shell = @shell.Shell::stood_in(
    @effect.Runtime::new(),
    calls=(_, _, _, _) => (),
    asks=(op, args) => {
      let sql = match args {
        { "sql": String(s), .. } => s
        _ => ""
      }
      let params = match args {
        { "params": Array(p), .. } => p
        _ => []
      }
      asked.push({ op, sql, params })
      let s = stand.val.unwrap()
      if (s.fails)(sql) {
        raise @shell.ShellError("SQLITE_ERROR: \{sql}")
      }
      match op {
        "sql.open" | "sql.attach" => { "id": 7 }
        "sql.run" => Json::number(1.0)
        "sql.all" => Json::array((s.rows)(sql, params).map(r => r))
        _ => Json::null()
      }
    },
    draws=n => Bytes::make(n, b'\x00'),
  )
  let s : Stand = { shell, asked, rows: (_, _) => [], fails: _ => false }
  stand.val = Some(s)
  s
}

///|
/// The statements run (`sql.exec`, `sql.run`, `sql.all`), in order.
fn Stand::statements(self : Stand) -> Array[String] {
  self.asked.filter(a => a.op is ("sql.exec" | "sql.run" | "sql.all")).map(a => a.sql)
}

///|
test "open, run, read and close ask the shell's ops with the handle it gave" {
  let stand = Stand::new()
  stand.rows = (_, _) => [[1, "a", Json::null()], [2, "b", 1.5]]
  let db = Sql::open(stand.shell, "acct")
  assert_eq(db.id, 7)
  db.exec("CREATE TABLE t (k INTEGER, v TEXT, x REAL)")
  assert_eq(db.run("INSERT INTO t VALUES (?, ?, ?)", params=[1, "a", Json::null()]), 1)
  let rows = db.all("SELECT k, v, x FROM t WHERE k > ?", params=[0])
  assert_eq(rows.length(), 2)
  assert_eq(col_int(rows[0], 0), 1)
  assert_eq(col_text(rows[0], 1), "a")
  assert_eq(col_opt_text(rows[0], 2), None)
  assert_eq(col_double(rows[1], 2), 1.5)
  assert_eq(col_int64(rows[1], 0), 2L)
  assert_eq(col_bool(rows[1], 0), true)
  assert_eq(col_bool(rows[0], 2), false)
  assert_eq(col_text(rows[1], 0), "2")
  db.close()
  db.close()
  assert_true(db.is_closed())
  assert_eq(
    stand.asked.map(a => a.op),
    ["sql.open", "sql.exec", "sql.run", "sql.all", "sql.close"],
  )
  assert_eq(stand.asked[2].params, [1, "a", Json::null()])
  delete_db(stand.shell, "acct")
  assert_eq(stand.asked.last().unwrap().op, "sql.delete")
}

///|
test "attach says its path, whether to make it and how long to wait" {
  let stand = Stand::new()
  let db = Sql::attach(stand.shell, "/x/y.db", create=false, wait_ms=250)
  assert_eq(db.id, 7)
  assert_eq(
    stand.asked.map(a => a.op),
    ["sql.attach"],
  )
}

///|
test "a burst of several writes begins one transaction and commits it once" {
  let stand = Stand::new()
  let db = Sql::open(stand.shell, "acct")
  let burst = Burst::new(db)
  ignore(burst.all("SELECT 1"))
  assert_false(burst.is_open())
  ignore(burst.run("INSERT INTO t VALUES (?)", params=[1]))
  ignore(burst.run("INSERT INTO t VALUES (?)", params=[2]))
  burst.exec("UPDATE t SET k = k + 1")
  ignore(burst.all("SELECT k FROM t"))
  burst.commit()
  assert_eq(
    stand.statements(),
    ["SELECT 1", "BEGIN IMMEDIATE", "INSERT INTO t VALUES (?)", "INSERT INTO t VALUES (?)", "UPDATE t SET k = k + 1", "SELECT k FROM t", "COMMIT"],
  )
  assert_eq(burst.begun(), 1)
  assert_eq(burst.committed(), 1)
}

///|
test "a burst that wrote nothing commits and rolls back with no statement" {
  let stand = Stand::new()
  let db = Sql::open(stand.shell, "acct")
  let burst = Burst::new(db)
  let before = stand.asked.length()
  burst.commit()
  burst.rollback()
  assert_eq(burst.in_tx(_ => 5), 5)
  assert_eq(stand.asked.length(), before)
  assert_eq(burst.begun(), 0)
}

///|
test "a transaction whose work raises is rolled back and its error raised again" {
  let stand = Stand::new()
  let db = Sql::open(stand.shell, "acct")
  let burst = Burst::new(db)
  stand.fails = sql => sql.has_prefix("INSERT INTO bad")
  let failed = try {
    burst.in_tx(b => {
      ignore(b.run("INSERT INTO t VALUES (?)", params=[1]))
      ignore(b.run("INSERT INTO bad VALUES (?)", params=[2]))
      ignore(b.run("INSERT INTO t VALUES (?)", params=[3]))
    })
    false
  } catch {
    _ => true
  }
  assert_true(failed)
  assert_false(burst.is_open())
  assert_eq(
    stand.statements(),
    ["BEGIN IMMEDIATE", "INSERT INTO t VALUES (?)", "INSERT INTO bad VALUES (?)", "ROLLBACK"],
  )
  // (the next write begins a transaction anew)
  burst.in_tx(b => ignore(b.run("INSERT INTO t VALUES (?)", params=[4])))
  assert_eq(stand.statements().length(), 7)
  assert_eq(stand.statements()[6], "COMMIT")
  assert_eq(burst.begun(), 2)
  assert_eq(burst.committed(), 1)
}

///|
/// The keys `n` asks for, `k0` .. `k<n-1>`, with every tenth given twice.
fn keys_of(n : Int) -> Array[String] {
  let out : Array[String] = []
  for i in 0..<n {
    out.push("k\{i}")
    if i % 10 == 0 {
      out.push("k\{i}")
    }
  }
  out
}

///|
test "keys are read in one statement a chunk, each once, none for no keys" {
  let stand = Stand::new()
  stand.rows = (_, params) => params[1:].iter().map(p => Json::array([p, Json::string("tree")])).collect()
  let db = Sql::open(stand.shell, "acct")
  let make = (ph : String) => "SELECT key, json FROM md_kept WHERE owner = ? AND key IN (\{ph})"
  let decode = (row : Array[Json]) => Some(col_text(row, 0))
  let asked = () => stand.asked.filter(a => a.op == "sql.all")
  // none
  let none = query_in_chunks(db, [], make_sql=make, extra_params=["s1"], decode~)
  assert_eq(none.length(), 0)
  assert_eq(asked().length(), 0)
  // 50, in one
  let fifty = query_in_chunks(db, keys_of(50), make_sql=make, extra_params=["s1"], decode~)
  assert_eq(fifty.length(), 50)
  assert_eq(asked().length(), 1)
  assert_eq(asked()[0].params.length(), 51)
  assert_eq(asked()[0].params[0], Json::string("s1"))
  assert_eq(asked()[0].params[1], Json::string("k0"))
  assert_eq(asked()[0].params[2], Json::string("k1"))
  // 450 (and 45 given twice), in three: 200, 200, 50
  let many = query_in_chunks(db, keys_of(450), make_sql=make, extra_params=["s1"], decode~)
  assert_eq(many.length(), 450)
  let all = asked()
  assert_eq(all.length(), 4)
  assert_eq(all[1].params.length(), 201)
  assert_eq(all[2].params.length(), 201)
  assert_eq(all[3].params.length(), 51)
  assert_eq(all[3].params[50], Json::string("k449"))
  assert_true(all[1].sql.has_suffix("IN (\{placeholders(200)})"))
  assert_true(all[3].sql.has_suffix("IN (\{placeholders(50)})"))
  assert_eq(placeholders(3), "?, ?, ?")
}

///|
test "rows a decoder does not take are left out" {
  let stand = Stand::new()
  stand.rows = (_, _) => [["a", 1], ["b", Json::null()], ["c", 3]]
  let db = Sql::open(stand.shell, "acct")
  let got = query_in_chunks(db, ["a", "b", "c"], make_sql=ph => "SELECT k, n FROM t WHERE k IN (\{ph})", decode=row => {
    match col_opt_int64(row, 1) {
      Some(n) => Some((col_text(row, 0), n))
      None => None
    }
  })
  assert_eq(got, [("a", 1L), ("c", 3L)])
}
