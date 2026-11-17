// The program of one workspace's Comma indexes (reader `--builder comma-stats --db <file>`, src/comma/stats.ts): each
// line an ask `{id, op, …}`, each answered `{id, …}`, or `{id, error, busy?}` (`busy`: another process holds the
// database; asked again later). It keeps a build's rows between its turns and nothing of a connection.
//   build {build, stations, unread, fromDay}  a build's rows made, and its first turn: {done, stats?, tasks?}
//   turn {build}                              its next turn: {done, stats?, tasks?}
//   cancel {build}                            a build let go
//   apply {stations, unread, fromDay}         the rows written at once, the age index not used: {stats, tasks}
//   probe {index}                             {epoch, rev, pruned}
//   page {index, epoch, through, rows, resetting, resetFloor, wire}
//                                             {page, reset, floor, taken, byteLimited}
//   guard {index}                             the prunes' trigger installed
//   held {index, through}                     the tombstones every connection holds removed
//   since {index, since, limit}               the rows past a revision (tests): {rows}
//   title {ref}                               a Task's title: {found, title?}

///|
fn field(ask : @jsjson.JValue, name : String) -> @jsjson.JValue {
  ask.get(name).unwrap_or(Null)
}

///|
fn text_field(ask : @jsjson.JValue, name : String) -> String raise {
  match ask.get(name) {
    Some(Str(s)) => @jsjson.text(s)
    _ => raise Failure("no \{name}")
  }
}

///|
fn units_field(ask : @jsjson.JValue, name : String) -> Array[Int32] raise {
  match ask.get(name) {
    Some(Str(s)) => s
    _ => raise Failure("no \{name}")
  }
}

///|
fn int_field(ask : @jsjson.JValue, name : String) -> Int64 {
  match ask.get(name) {
    Some(Num(n)) if !n.is_nan() && !n.is_inf() => n.to_int64()
    _ => 0L
  }
}

///|
fn changed(c : (Int32, Int32)?) -> Array[(String, @jsjson.JValue?)] {
  match c {
    None => [("done", Some(Bool(false)))]
    Some((stats, tasks)) =>
      [
        ("done", Some(Bool(true))),
        ("stats", Some(Num(stats.to_double()))),
        ("tasks", Some(Num(tasks.to_double()))),
      ]
  }
}

///|
/// What one ask is answered (its id added by `serve`).
fn answer(
  db : @sql.Db,
  builds : Map[Int64, Build],
  ask : @jsjson.JValue,
) -> Array[(String, @jsjson.JValue?)] raise {
  let op = text_field(ask, "op")
  match op {
    "build" => {
      let b = Build::new(
        field(ask, "stations"),
        field(ask, "unread"),
        units_field(ask, "fromDay"),
      )
      // (one build at a time: a new one takes the place of what was left)
      builds.clear()
      builds[int_field(ask, "build")] = b
      let c = b.turn(db)
      if c is Some(_) {
        builds.remove(int_field(ask, "build"))
      }
      changed(c)
    }
    "turn" => {
      let id = int_field(ask, "build")
      guard builds.get(id) is Some(b) else { raise Failure("no such build") }
      let c = b.turn(db)
      if c is Some(_) {
        builds.remove(id)
      }
      changed(c)
    }
    "cancel" => {
      builds.remove(int_field(ask, "build"))
      []
    }
    "apply" => {
      let b = Build::new(
        field(ask, "stations"),
        field(ask, "unread"),
        units_field(ask, "fromDay"),
      )
      let (stats, tasks) = b.apply(db, false, Some(0)).unwrap()
      [
        ("stats", Some(Num(stats.to_double()))),
        ("tasks", Some(Num(tasks.to_double()))),
      ]
    }
    "probe" => {
      let name = index_name(text_field(ask, "index"))
      db.exec("SAVEPOINT comma_index_probe")
      let (e, r, p) = try {
        let got = (epoch(db, name), rev(db, name), pruned(db, name))
        db.exec("RELEASE comma_index_probe")
        got
      } catch {
        e => {
          db.exec("ROLLBACK TO comma_index_probe; RELEASE comma_index_probe") catch {
            _ => ()
          }
          raise e
        }
      }
      [("epoch", Some(str(e))), ("rev", Some(num(r))), ("pruned", Some(num(p)))]
    }
    "page" => {
      let name = index_name(text_field(ask, "index"))
      let epoch = match ask.get("epoch") {
        Some(Str(s)) => Some(@jsjson.raw_text(s))
        _ => None
      }
      let rows = int_field(ask, "rows").to_int()
      let read = next_page(db, name, {
        epoch,
        through: int_field(ask, "through"),
        rows: if rows < 1 || rows > PAGE_ROWS {
          PAGE_ROWS
        } else {
          rows
        },
        resetting: ask.get("resetting") is Some(Bool(true)),
        reset_floor: int_field(ask, "resetFloor"),
        task: ask.get("wire") is Some(Str(w)) && @jsjson.raw_text(w) == "task",
      })
      [
        ("page", Some(read.page.unwrap_or(Null))),
        ("reset", Some(Bool(read.reset))),
        ("floor", Some(num(read.floor))),
        ("taken", Some(Num(read.taken.to_double()))),
        ("byteLimited", Some(Bool(read.byte_limited))),
      ]
    }
    "guard" => {
      guard_prunes(db, index_name(text_field(ask, "index")))
      []
    }
    "held" => {
      prune(db, index_name(text_field(ask, "index")), int_field(ask, "through"))
      []
    }
    "since" => {
      let name = index_name(text_field(ask, "index"))
      let rows = rows_since(
        db,
        name,
        int_field(ask, "since"),
        int_field(ask, "limit").to_int(),
        false,
      )
      [
        (
          "rows",
          Some(
            Arr(
              rows.map(r => {
                obj([
                  ("key", Some(Str(decoded(r.key)))),
                  ("source", Some(jtext(r.source))),
                  ("kind", Some(jtext(r.kind))),
                  ("rev", Some(num(r.rev))),
                  ("removed", Some(Bool(r.removed))),
                  ("json", Some(jtext(r.json))),
                ])
              }),
            ),
          ),
        ),
      ]
    }
    "title" =>
      match task_title(db, units_field(ask, "ref")) {
        None => [("found", Some(Bool(false)))]
        Some(title) => [("found", Some(Bool(true))), ("title", title)]
      }
    _ => raise Failure("no such ask: \{op}")
  }
}

///|
fn message(e : Error) -> String {
  match e {
    Failure(m) => m
    @wire.ShellError(m) => m
    @jsjson.SyntaxError(m) => "SyntaxError: \{m}"
    e => e.to_string()
  }
}

///|
/// Answers the asks on stdin until it ends, with the database at `path` (made where it is not), each statement waiting
/// BUSY_MS (`--wait`, a test's less) for another
/// process's write (a handover's) before it is refused.
pub async fn serve(host : @host.Host, path : String) -> Unit {
  let args = @host.args()
  let mut wait = 5000
  for i = 0; i + 1 < args.length(); i = i + 1 {
    if args[i] == "--wait" {
      wait = @string.parse_int(args[i + 1]) catch { _ => 5000 }
    }
  }
  // (opened at the first ask, again at the next where it could not be: another process may hold it a while)
  let opened : Ref[@sql.Db?] = Ref(None)
  let builds : Map[Int64, Build] = Map([])
  while host.line() is Some(line) {
    if line == "" {
      continue
    }
    let ask = @jsjson.parse(line) catch { _ => Null }
    let id = field(ask, "id")
    let fields = try {
      let db = match opened.val {
        Some(db) => db
        None => {
          let db = @sql.Db::create(host, path, wait~)
          prepare(db) catch {
            e => {
              db.close()
              raise e
            }
          }
          opened.val = Some(db)
          db
        }
      }
      answer(db, builds, ask)
    } catch {
      e =>
        [
          ("error", Some(str(message(e)))),
          ("busy", if @sql.busy(e) { Some(Bool(true)) } else { None }),
          (
            "syntax",
            if e is @jsjson.SyntaxError(_) {
              Some(Bool(true))
            } else {
              None
            },
          ),
        ]
    }
    host.say(@jsjson.stringify(obj([("id", Some(id))] + fields)))
  }
}
