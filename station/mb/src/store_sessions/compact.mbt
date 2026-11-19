// A session's context as its last calls left it, kept beside its totals (station/src/store/usage-compact.ts): the
// last five main-thread calls and whether the last two turns compacted, read and written as JSON JavaScript reads and
// writes it (@jsjson). The shared writers live in `station/usagecount`; what the store reads of it besides
// (`compactContexts`, `compactRecentlyCompacted`, `savedCompactContext`) lives here.

///|
/// store/usage.ts UsageCall, UsageFor, ContextSnapshot.
using @usagecount {type Call, type For, type Snapshot}

///|
fn one_of(
  db : @sql.Db,
  sql : String,
  params : Array[Json],
) -> Map[String, Json]? raise {
  match db.all(sql, params) {
    [r, ..] => Some(r)
    _ => None
  }
}

///|
fn opt_num(d : Double?) -> Json {
  match d {
    Some(v) => Json::number(v)
    None => Json::null()
  }
}

// ── what the store reads of it ──

///|
/// usage-compact.ts `reliableTail`: after an edit, five new calls later than the old rows' last make a whole tail.
fn reliable_tail(s : Snapshot) -> Bool {
  if !s.invalid {
    return true
  }
  match s.after {
    None => true
    Some(after) => {
      let calls = @jsjson.jval_arr(@jsjson.jval_at(Some(s.state), "calls"))
      calls.length() >= 5 &&
      @jsjson.jval_num_of(@jsjson.jval_at(Some(calls[0]), "at")).unwrap_or(0.0) >
      after
    }
  }
}

///|
/// usage-compact.ts `compactContexts`: a session's last `limit` main-thread calls (store/usage.ts ContextCall).
fn compact_contexts(
  db : @sql.Db,
  session : String,
  limit : Int32,
) -> Array[Json] raise {
  if limit <= 0 {
    return []
  }
  let snapshot = @usagecount.context_snapshot(db, session)
  if !reliable_tail(snapshot) {
    return []
  }
  let calls = @jsjson.jval_arr(@jsjson.jval_at(Some(snapshot.state), "calls"))
  let from = if calls.length() > limit { calls.length() - limit } else { 0 }
  calls[from:]
  .to_array()
  .map(c => {
    let o = of_js(c)
    obj(o).remove("id")
    o
  })
}

///|
/// usage-compact.ts `compactRecentlyCompacted`.
fn compact_recently_compacted(db : @sql.Db, session : String) -> Bool raise {
  let s = @usagecount.context_snapshot(db, session)
  reliable_tail(s) &&
  !(@jsjson.jval_at(Some(s.state), "uncertain") is Some(Bool(true))) &&
  @jsjson.jval_arr(@jsjson.jval_at(Some(s.state), "turns"))
  .iter()
  .any(t => @jsjson.jval_at(Some(t), "compacted") is Some(Bool(true)))
}

///|
/// usage-compact.ts `savedCompactContext`.
fn saved_compact_context(db : @sql.Db, session : String) -> Json raise {
  let s = @usagecount.context_snapshot(db, session)
  if s.invalid {
    return Json::null()
  }
  guard @jsjson.jval_at(Some(s.state), "saved") is Some(saved) else {
    return Json::null()
  }
  let id = match
    one_of(db, "SELECT runtime_session_id AS id FROM sessions WHERE key = ?", [
      Json::string(session),
    ]) {
    Some(r) => col(r, "id")
    None => return Json::null()
  }
  let runtime = @jsjson.jval_at(Some(saved), "runtimeSession")
  let same = match (id, runtime) {
    (String(a), Some(Str(b))) => a == b
    (Null, Some(Null)) => true
    _ => false
  }
  if same {
    of_js(saved)
  } else {
    Json::null()
  }
}
