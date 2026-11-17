// The pages a connection sends Comma of an index (`stats.index`, `task.index`), as the TypeScript station read them
// (station/test/reference/comma-stats.ts readNextPage, IndexSync.next, statsWire, taskWire). The socket's own state
// (what its Comma acknowledged, whether it is resetting, the rows a page it learnt to take) is Node's and given with
// each ask: this program keeps nothing of a connection, so it can be let go between any two asks.

///|
/// Comma's bounds on a page: rows, and bytes of its rows as JSON.
pub const PAGE_ROWS : Int32 = 200

///|
pub const PAGE_BYTES : Int32 = 61440

///|
fn obj(fields : Array[(String, @jsjson.JValue?)]) -> @jsjson.JValue {
  object(fields)
}

///|
fn num(v : Int64) -> @jsjson.JValue {
  Num(v.to_double())
}

///|
/// A column's text as a JavaScript string (null where it is null).
fn jtext(v : Json) -> @jsjson.JValue {
  match v {
    String(s) => Str(units(s))
    Number(n, ..) => Num(n)
    _ => Null
  }
}

///|
/// A Stats index row as `stats.index` carries it: its key opaque to Comma (PostgreSQL text cannot contain NUL and its
/// key is limited to 512 bytes); none where its JSON is not JSON.
fn stats_wire(row : IndexRow) -> @jsjson.JValue? {
  let key = "sf1:" + @memory.sha256_hex(utf8_of(decoded(row.key)))
  if row.removed {
    return Some(
      obj([
        ("key", Some(str(key))),
        ("source", Some(jtext(row.source))),
        ("kind", Some(jtext(row.kind))),
        ("rev", Some(num(row.rev))),
        ("removed", Some(Bool(true))),
      ]),
    )
  }
  let (text, _) = body_text(Some(row.json))
  match parsed(text) {
    None => None
    Some(body) =>
      Some(
        obj([
          ("key", Some(str(key))),
          ("source", Some(jtext(row.source))),
          ("kind", Some(jtext(row.kind))),
          ("rev", Some(num(row.rev))),
          ("row", Some(body)),
        ]),
      )
  }
}

///|
/// A Task index row as `task.index` carries it: the Task's facts, never its messages; what it asks of whom only when
/// it asks something, its link when there is one, and `router` only when a Comma Router wrote in it.
fn task_wire(row : IndexRow) -> @jsjson.JValue? {
  let thread = @jsjson.Str(decoded(row.key))
  if row.removed {
    return Some(
      obj([
        ("thread", Some(thread)),
        ("rev", Some(num(row.rev))),
        ("removed", Some(Bool(true))),
      ]),
    )
  }
  let (text, _) = body_text(Some(row.json))
  let t = match parsed(text) {
    None | Some(Null) => return None
    Some(t) => Some(t)
  }
  let attention = prop(t, "attention")
  let asks = attention is Some(Str(_))
  Some(
    obj([
      ("thread", Some(thread)),
      ("rev", Some(num(row.rev))),
      ("task", prop(t, "task")),
      ("title", prop(t, "title")),
      ("status", prop(t, "status")),
      ("created_by", prop(t, "created_by")),
      ("created_at", prop(t, "created_at")),
      ("last_activity_at", prop(t, "last_activity_at")),
      ("runtime", prop(t, "runtime")),
      ("model", prop(t, "model")),
      ("labels", Some(Arr([]))),
      ("attention", if asks { attention } else { None }),
      (
        "waits_for",
        match prop(t, "waits_for") {
          Some(Arr(items) as w) if asks && items.length() > 0 => Some(w)
          _ => None
        },
      ),
      (
        "note",
        match prop(t, "note") {
          Some(Str(_) as n) if asks => Some(n)
          _ => None
        },
      ),
      (
        "url",
        match prop(t, "url") {
          Some(Str(_) as u) => Some(u)
          _ => None
        },
      ),
      (
        "router",
        if prop(t, "router") is Some(Bool(true)) {
          Some(Bool(true))
        } else {
          None
        },
      ),
    ]),
  )
}

///|
/// What a connection asks a page with: what its Comma holds (`epoch` none where it holds nothing), the rows it takes a
/// page now, and whether it is resetting from a floor.
pub(all) struct Ask {
  epoch : String?
  through : Int64
  rows : Int32
  resetting : Bool
  reset_floor : Int64
  task : Bool
}

///|
/// One read: the page (none once Comma holds the index whole), the floor the reset was decided by, and what the
/// connection learns of its rows.
pub(all) struct Read {
  page : @jsjson.JValue?
  reset : Bool
  floor : Int64
  limit : Int32
  taken : Int32
  byte_limited : Bool
  row_limited : Bool
}

///|
/// One snapshot a page, with a lower row limit for a sender that has recently seen large wire rows.
fn read_page(
  db : @sql.Db,
  name : String,
  ask : Ask,
  requested : Int32,
) -> Read raise {
  // A different connection can prune between reads. The floor, revision and rows must describe the same database
  // snapshot; it is released before the bodies are parsed and encoded.
  db.exec("SAVEPOINT comma_index_page")
  let (epoch, rev, reset, since, limit, changed, floor) = try {
    let epoch = epoch(db, name)
    let rev = rev(db, name)
    // A restored or damaged database may have a floor ahead of its current revision; never restart a reset forever.
    let pruned = pruned(db, name)
    let floor = if pruned < rev { pruned } else { rev }
    let same = ask.epoch is Some(e) && e == epoch
    let forced = same &&
      (
        ask.through > rev ||
        (ask.through < floor && (!ask.resetting || floor > ask.reset_floor))
      )
    let reset = !same || forced
    let since = if reset { 0L } else { ask.through }
    let mut limit = if reset { PAGE_ROWS } else { requested }
    let mut changed = if !reset && since >= rev {
      None
    } else {
      Some(rows_since(db, name, since, limit + 1, true))
    }
    // Do not introduce an earlier boundary within equal revisions: the receiver acknowledges only a revision. Fall
    // back in this same snapshot to the original page size when the adaptive boundary would split one.
    if changed is Some(rows) &&
      limit < PAGE_ROWS &&
      rows.length() > limit &&
      rows[limit - 1].rev == rows[limit].rev {
      limit = PAGE_ROWS
      changed = Some(rows_since(db, name, since, limit + 1, true))
    }
    db.exec("RELEASE comma_index_page")
    (epoch, rev, reset, since, limit, changed, floor)
  } catch {
    e => {
      db.exec("ROLLBACK TO comma_index_page; RELEASE comma_index_page") catch {
        _ => ()
      }
      raise e
    }
  }
  guard changed is Some(changed) else {
    return {
      page: None,
      reset,
      floor,
      limit,
      taken: 0,
      byte_limited: false,
      row_limited: false,
    }
  }
  let rows = []
  let mut bytes = 2
  let mut taken = 0
  let mut last = since
  let mut byte_limited = false
  for i, row in changed {
    if i >= limit {
      break
    }
    let sent = if ask.task { task_wire(row) } else { stats_wire(row) }
    let size = match sent {
      None => 0
      Some(s) => utf8_length(@jsjson.stringify(s)) + 1
    }
    if rows.length() > 0 && bytes + size > PAGE_BYTES {
      byte_limited = true
      break
    }
    if sent is Some(s) {
      rows.push(s)
    }
    bytes += size
    taken += 1
    last = row.rev
  }
  // A page short of the end brings Comma to its last row; the last page to the index's rev, past pruned tombstones.
  let through = if taken < changed.length() { last } else { rev }
  {
    page: Some(
      obj([
        ("epoch", Some(str(epoch))),
        ("reset", Some(Bool(reset))),
        ("since", Some(num(since))),
        ("through", Some(num(through))),
        ("rows", Some(Arr(rows))),
      ]),
    ),
    reset,
    floor,
    limit,
    taken,
    byte_limited,
    row_limited: !byte_limited && taken == limit && changed.length() > limit,
  }
}

///|
/// The next page to send a connection after its Comma answered (IndexSync.next's read): one of a row limit it learnt,
/// read again whole where small rows came after all.
pub fn next_page(db : @sql.Db, name : String, ask : Ask) -> Read raise {
  let first = read_page(db, name, ask, ask.rows)
  if first.limit < PAGE_ROWS && first.row_limited {
    // Small rows have arrived. Discard the tentative page and read a complete page in a new snapshot, so the
    // receiver does not pay an extra page wait and no rows from different snapshots are combined.
    read_page(db, name, ask, PAGE_ROWS)
  } else {
    first
  }
}
