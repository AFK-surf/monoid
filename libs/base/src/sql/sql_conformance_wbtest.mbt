// Conformance tests for `base/sql` (`Sql`, `Burst`, `query_in_chunks`, and `col_*` readers):
// transaction atomicity, rollback, nested savepoints, 64-bit integer precision across 2^53-1,
// double/bool/null/text coercion boundaries, and chunked query edge cases.

///|
test "col_int64, col_opt_int64 and col_text preserve Int64 precision beyond 2^53-1" {
  // Values outside IEEE-754 double exact integer range (+/- (2^53 - 1)) carry exact digits in Json::Number repr.
  let raw = "[0, -1, 2147483647, -2147483648, 2147483648, -2147483649, 9007199254740991, -9007199254740991, 9007199254740993, -9007199254740993, 9223372036854775807, -9223372036854775808]"
  guard (@json.parse(raw) catch { _ => Json::null() }) is Array(row) else {
    fail("expected json array")
  }
  let expected : Array[Int64] = [
    0L,
    -1L,
    2147483647L,
    -2147483648L,
    2147483648L,
    -2147483649L,
    9007199254740991L,
    -9007199254740991L,
    9007199254740993L,
    -9007199254740993L,
    9223372036854775807L,
    -9223372036854775808L,
  ]
  for i, want in expected {
    assert_eq(col_int64(row, i), want)
    assert_eq(col_opt_int64(row, i), Some(want))
    assert_eq(col_text(row, i), want.to_string())
  }
}

///|
test "col_* readers handle null, booleans, doubles, strings and out-of-bounds indices" {
  let row : Array[Json] = [
    Json::null(),
    Json::boolean(true),
    Json::boolean(false),
    Json::number(-0.0),
    Json::number(3.25),
    Json::string(""),
    Json::string("a\u{0}b"),
    Json::array([Json::number(1.0)]),
  ]
  // NULL
  assert_eq(col_text(row, 0), "")
  assert_eq(col_opt_text(row, 0), None)
  assert_eq(col_int(row, 0), 0)
  assert_eq(col_int64(row, 0), 0L)
  assert_eq(col_opt_int64(row, 0), None)
  assert_eq(col_double(row, 0), 0.0)
  assert_eq(col_bool(row, 0), false)
  // Booleans
  assert_eq(col_int(row, 1), 1)
  assert_eq(col_int64(row, 1), 1L)
  assert_eq(col_bool(row, 1), true)
  assert_eq(col_int(row, 2), 0)
  assert_eq(col_int64(row, 2), 0L)
  assert_eq(col_bool(row, 2), false)
  // Doubles (-0.0 and fractional)
  assert_eq(col_double(row, 3), 0.0)
  assert_eq(col_bool(row, 3), false)
  assert_eq(col_double(row, 4), 3.25)
  assert_eq(col_text(row, 4), "3.25")
  assert_eq(col_bool(row, 4), true)
  // Strings (empty and embedded NUL)
  assert_eq(col_text(row, 5), "")
  assert_eq(col_opt_text(row, 5), Some(""))
  assert_eq(col_text(row, 6), "a\u{0}b")
  assert_eq(col_opt_text(row, 6), Some("a\u{0}b"))
  // Non-scalar (array / blob)
  assert_eq(col_text(row, 7), "")
  assert_eq(col_opt_text(row, 7), None)
  assert_eq(col_int(row, 7), 0)
  assert_eq(col_opt_int64(row, 7), None)
  assert_eq(col_bool(row, 7), false)
  // Out-of-bounds
  assert_eq(col_text(row, 99), "")
  assert_eq(col_opt_text(row, 99), None)
  assert_eq(col_int(row, 99), 0)
  assert_eq(col_int64(row, 99), 0L)
  assert_eq(col_opt_int64(row, 99), None)
  assert_eq(col_double(row, 99), 0.0)
  assert_eq(col_bool(row, 99), false)
}

///|
test "Sql::open and Sql::all reject malformed shell answers" {
  let bad_open_shell = @shell.Shell::stood_in(
    @effect.Runtime::new(),
    calls=(_, _, _, _) => (),
    asks=(_, _) => Json::object({ "nope": Json::boolean(true) }),
    draws=n => Bytes::make(n, b'\x00'),
  )
  let open_err = try {
    ignore(Sql::open(bad_open_shell, "broken"))
    ""
  } catch {
    @shell.ShellError(m) => m
  }
  assert_true(open_err.contains("sql.open answered no handle"))

  let bad_all_shell = @shell.Shell::stood_in(
    @effect.Runtime::new(),
    calls=(_, _, _, _) => (),
    asks=(op, _) => match op {
      "sql.open" => { "id": 3 }
      "sql.all" => Json::string("not-an-array")
      "sql.run" => Json::string("not-a-number")
      _ => Json::null()
    },
    draws=n => Bytes::make(n, b'\x00'),
  )
  let db = Sql::open(bad_all_shell, "x")
  assert_eq(db.run("DELETE FROM t"), 0)
  let all_err = try {
    ignore(db.all("SELECT 1"))
    ""
  } catch {
    @shell.ShellError(m) => m
  }
  assert_true(all_err.contains("sql.all answered no rows"))
}

///|
test "Burst handles commit failure, nested savepoints, and rollback errors cleanly" {
  let stand = Stand::new()
  let db = Sql::open(stand.shell, "tx")
  let burst = Burst::new(db)

  // Nested savepoint flow inside a single burst transaction
  burst.in_tx(b => {
    ignore(b.run("INSERT INTO t VALUES (?)", params=[1]))
    b.exec("SAVEPOINT sp1")
    ignore(b.run("INSERT INTO t VALUES (?)", params=[2]))
    b.exec("ROLLBACK TO sp1")
    b.exec("RELEASE sp1")
  })
  assert_false(burst.is_open())
  assert_eq(burst.begun(), 1)
  assert_eq(burst.committed(), 1)
  assert_eq(
    stand.statements(),
    [
      "BEGIN IMMEDIATE",
      "INSERT INTO t VALUES (?)",
      "SAVEPOINT sp1",
      "INSERT INTO t VALUES (?)",
      "ROLLBACK TO sp1",
      "RELEASE sp1",
      "COMMIT",
    ],
  )

  // Commit failure resets open flag so rollback does not run a spurious ROLLBACK
  stand.fails = sql => sql == "COMMIT"
  let commit_failed = try {
    burst.in_tx(b => ignore(b.run("INSERT INTO t VALUES (?)", params=[3])))
    false
  } catch {
    _ => true
  }
  assert_true(commit_failed)
  assert_false(burst.is_open())
  assert_eq(burst.begun(), 2)
  assert_eq(burst.committed(), 1)

  // Rollback failure inside errdefer is swallowed and original error still propagates
  stand.fails = sql => sql == "INSERT INTO fail" || sql == "ROLLBACK"
  let orig_err = try {
    burst.in_tx(b => {
      ignore(b.run("INSERT INTO t VALUES (?)", params=[4]))
      ignore(b.run("INSERT INTO fail", params=[]))
    })
    ""
  } catch {
    @shell.ShellError(m) => m
    _ => ""
  }
  assert_true(orig_err.contains("INSERT INTO fail"))
  assert_false(burst.is_open())
}

///|
test "query_in_chunks clamps non-positive chunk_size and deduplicates across boundaries" {
  let stand = Stand::new()
  stand.rows = (_, params) => params.iter().map(p => Json::array([p])).collect()
  let db = Sql::open(stand.shell, "chunks")
  let got = query_in_chunks(
    db,
    ["a", "b", "a", "c", "b"],
    chunk_size=0,
    make_sql=ph => "SELECT k FROM t WHERE k IN (\{ph})",
    decode=row => Some(col_text(row, 0)),
  )
  assert_eq(got, ["a", "b", "c"])
  let all_calls = stand.asked.filter(a => a.op == "sql.all")
  assert_eq(all_calls.length(), 3)
  assert_eq(placeholders(0), "")
  assert_eq(placeholders(1), "?")
}
