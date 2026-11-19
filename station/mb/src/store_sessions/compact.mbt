// A session's context as its last calls left it, kept beside its totals (station/src/store/usage-compact.ts): the
// last five main-thread calls and whether the last two turns compacted, read and written as JSON JavaScript reads and
// writes it (@jsjson), so the text kept is the station's. The writers here are the usage counter's
// (mb/src/usagecount/record.mbt), the same statements; what the store reads of it besides (`compactContexts`,
// `compactRecentlyCompacted`, `savedCompactContext`) is at the end.

///|
/// store/usage.ts `UsageFor`: whom a call's turn worked for.
priv struct For {
  turn : Json
  person : Json
  thread : Json
  profile : Json
}

///|
/// store/usage.ts UsageCall.
using @usagecount {type Call}

///|
/// rows.ts COMPACTED_FROM.
let compacted_from : Double = 50000.0

// ── JSON as JavaScript keeps it ──

///|
fn jkey(k : String) -> String {
  k
}

///|
fn same_units(a : String, b : String) -> Bool {
  a == b
}

///|
fn jget(v : @jsjson.JValue?, k : String) -> @jsjson.JValue? {
  match v {
    Some(Obj(entries)) => {
      let key = jkey(k)
      for e in entries {
        if same_units(e.0, key) {
          return Some(e.1)
        }
      }
      None
    }
    _ => None
  }
}

///|
/// `obj[k] = v`: in its place where it is, else last.
fn jset(obj : @jsjson.JValue, k : String, v : @jsjson.JValue) -> Unit {
  guard obj is Obj(entries) else { return }
  let key = jkey(k)
  for i in 0..<entries.length() {
    if same_units(entries[i].0, key) {
      entries[i] = (entries[i].0, v)
      return
    }
  }
  entries.push((key, v))
}

///|
/// `delete obj[k]`.
fn jdel(obj : @jsjson.JValue, k : String) -> Unit {
  guard obj is Obj(entries) else { return }
  let key = jkey(k)
  for i in 0..<entries.length() {
    if same_units(entries[i].0, key) {
      ignore(entries.remove(i))
      return
    }
  }
}

///|
fn vstr(s : String) -> @jsjson.JValue {
  Str(jkey(s))
}

///|
fn jopt_str(s : String?) -> @jsjson.JValue {
  match s {
    Some(v) => vstr(v)
    None => Null
  }
}

///|
fn jopt_num(d : Double?) -> @jsjson.JValue {
  match d {
    Some(v) => Num(v)
    None => Null
  }
}

///|
/// A JSON value's number, as JavaScript compares one (none: not a number).
fn vnum(v : @jsjson.JValue?) -> Double? {
  match v {
    Some(Num(d)) => Some(d)
    _ => None
  }
}

///|
/// `a === b` of what JSON holds against a string or null.
fn jis(v : @jsjson.JValue?, s : String?) -> Bool {
  match (v, s) {
    (Some(Null), None) => true
    (Some(Str(u)), Some(t)) => same_units(u, jkey(t))
    _ => false
  }
}

///|
/// JavaScript's `<` of two strings: by their UTF-16 code units.
fn units_less(a : String, b : String) -> Bool {
  @jsjson.js_less(a, b)
}

///|
fn jarray(v : @jsjson.JValue?) -> Array[@jsjson.JValue] {
  match v {
    Some(Arr(items)) => items
    _ => []
  }
}

// ── a session's recent contexts ──

///|
/// usage-compact.ts `ContextOwner`: the totals row that holds a session's context.
priv struct Owner {
  runtime : Json
  model : Json
  fast : Json
}

///|
fn same_owner(a : Owner, b : Owner) -> Bool {
  a.runtime == b.runtime && a.model == b.model && a.fast == b.fast
}

///|
/// usage-compact.ts `ContextSnapshot`.
priv struct Snapshot {
  state : @jsjson.JValue
  stored : Bool
  invalid : Bool
  after : Double?
  owner : Owner?
}

///|
fn fresh_state(uncertain : Bool) -> @jsjson.JValue {
  Obj([
    (jkey("calls"), Arr([])),
    (jkey("turns"), Arr([])),
    (jkey("uncertain"), Bool(uncertain)),
  ])
}

///|
/// usage-compact.ts `contextSnapshot`.
fn context_snapshot(db : @sql.Db, session : String) -> Snapshot raise {
  let row = one_of(
    db,
    (
      #|SELECT t.compact_context AS state, sc.context_uncertain AS invalid, sc.context_after AS after,
      #|      sc.context_runtime AS runtime, sc.context_model AS model, sc.context_fast AS fast
      #|    FROM usage_minute_scope sc LEFT JOIN usage_totals t ON t.session = sc.session AND t.runtime = sc.context_runtime
      #|      AND t.model = sc.context_model AND t.fast = sc.context_fast WHERE sc.session = ?
    ),
    [Json::string(session)],
  )
  let invalid = match row {
    Some(r) => num_of(col(r, "invalid")) == Some(1.0)
    None => false
  }
  let (state, stored) = match row {
    Some(r) =>
      match col(r, "state") {
        Null => (fresh_state(invalid), false)
        String(text) => (@jsjson.parse(text), true)
        other => (@jsjson.JValue::of_json(other), true)
      }
    None => (fresh_state(invalid), false)
  }
  let owner = match row {
    Some(r) if !(col(r, "runtime") is Null) =>
      Some({
        runtime: col(r, "runtime"),
        model: col(r, "model"),
        fast: col(r, "fast"),
      })
    _ => None
  }
  let after = match row {
    Some(r) => num_of(col(r, "after"))
    None => None
  }
  { state, stored, invalid, after, owner, }
}

///|
/// usage-compact.ts `keepRecent`: the context put on the totals row the call changed; the pointer moved only when the
/// model, runtime or speed changes.
fn keep_recent(
  db : @sql.Db,
  session : String,
  owner : Owner,
  state : @jsjson.JValue,
  previous : Owner?,
) -> Unit raise {
  let s = Json::string(session)
  let same = match previous {
    Some(p) => same_owner(p, owner)
    None => false
  }
  if previous is Some(p) && !same {
    ignore(
      db.run(
        "UPDATE usage_totals SET compact_context = NULL WHERE session = ? AND runtime = ? AND model = ? AND fast = ?",
        [s, p.runtime, p.model, p.fast],
      ),
    )
  }
  ignore(
    db.run(
      (
        #|INSERT INTO usage_totals (session, runtime, model, fast, calls, input, cache_read, cache_write, cache_write_long, output, compact_context)
        #|    VALUES (?, ?, ?, ?, 0, 0, 0, 0, 0, 0, ?)
        #|    ON CONFLICT (session, runtime, model, fast) DO UPDATE SET compact_context = excluded.compact_context
      ),
      [
        s,
        owner.runtime,
        owner.model,
        owner.fast,
        Json::string(@jsjson.stringify(state)),
      ],
    ),
  )
  if same {
    return
  }
  ignore(
    db.run(
      (
        #|INSERT INTO usage_minute_scope (session, ws, done, context_runtime, context_model, context_fast)
        #|    VALUES (?, (SELECT ws FROM sessions WHERE key = ?), 1, ?, ?, ?)
        #|    ON CONFLICT (session) DO UPDATE SET context_runtime = excluded.context_runtime, context_model = excluded.context_model,
        #|      context_fast = excluded.context_fast
        #|    WHERE context_runtime IS NOT excluded.context_runtime OR context_model IS NOT excluded.context_model OR context_fast IS NOT excluded.context_fast
      ),
      [s, s, owner.runtime, owner.model, owner.fast],
    ),
  )
}

///|
/// usage-compact.ts `seedCompactContext`: a saved summary seeds the context while it still represents every call and
/// the current runtime session; the snapshot it read where it wrote none.
fn seed_context(db : @sql.Db, session : String) -> Snapshot? raise {
  let snapshot = context_snapshot(db, session)
  if snapshot.stored || snapshot.invalid {
    return Some(snapshot)
  }
  let s = Json::string(session)
  let row = one_of(
    db,
    (
      #|SELECT u.usage, s.runtime_session_id AS runtime, r.at AS began
      #|    FROM session_usage u JOIN sessions s ON s.key = u.session
      #|    LEFT JOIN runtime_sessions r ON r.session_key = s.key AND r.id = s.runtime_session_id WHERE u.session = ?
    ),
    [s],
  )
  guard row is Some(row) else { return Some(snapshot) }
  guard col(row, "runtime") is String(runtime) &&
    num_of(col(row, "began")) is Some(began) else {
    return Some(snapshot)
  }
  let old = match col(row, "usage") {
    String(text) => @jsjson.parse(text)
    _ => fail("a session's usage is not JSON")
  }
  guard old is Obj(_) else { fail("a session's usage is not an object") }
  let total = match
    one_of(
      db,
      "SELECT COALESCE(SUM(calls), 0) AS n FROM usage_totals WHERE session = ? AND calls > 0",
      [s],
    ) {
    Some(r) => num_of(col(r, "n")).unwrap_or(0.0)
    None => 0.0
  }
  let model = jget(Some(old), "model")
  let window = jget(Some(old), "contextWindow")
  guard vnum(jget(Some(old), "modelCalls")) == Some(total) &&
    vnum(jget(Some(old), "lastCallAt")) is Some(last) &&
    !(last < began) &&
    (model is Some(Null) || model is Some(Str(_))) &&
    (window is Some(Null) || window is Some(Num(_))) else {
    return Some(snapshot)
  }
  let saved : @jsjson.JValue = Obj([
    (jkey("runtimeSession"), vstr(runtime)),
    (jkey("model"), model.unwrap()),
    (jkey("contextWindow"), window.unwrap()),
    (jkey("lastCallAt"), Num(last)),
  ])
  for name in ["contextTokens", "cacheMs", "rereadCost"] {
    if jget(Some(old), name) is Some(Num(v)) {
      jset(saved, name, Num(v))
    }
  }
  let owner = match
    one_of(
      db,
      "SELECT runtime, model, fast FROM usage_totals WHERE session = ? ORDER BY runtime, model, fast LIMIT 1",
      [s],
    ) {
    Some(r) =>
      {
        runtime: col(r, "runtime"),
        model: col(r, "model"),
        fast: col(r, "fast"),
      }
    None => return Some(snapshot)
  }
  let state : @jsjson.JValue = Obj([
    (jkey("calls"), Arr([])),
    (jkey("turns"), Arr([])),
    (jkey("uncertain"), Bool(false)),
    (jkey("saved"), saved),
  ])
  keep_recent(db, session, owner, state, snapshot.owner)
  None
}

///|
/// A recent call's place: by when it was made, then by its id.
fn call_before(a : @jsjson.JValue, b : @jsjson.JValue) -> Bool {
  let x = vnum(jget(Some(a), "at")).unwrap_or(0.0)
  let y = vnum(jget(Some(b), "at")).unwrap_or(0.0)
  if x != y {
    return x < y
  }
  match (jget(Some(a), "id"), jget(Some(b), "id")) {
    (Some(Str(p)), Some(Str(q))) => units_less(p, q)
    _ => false
  }
}

///|
/// usage-compact.ts `noteCompactContexts`: the last five contexts and whether the last two turns compacted.
fn note_contexts(
  db : @sql.Db,
  session : String,
  runtime : String,
  calls : Array[(Call, For)],
  read : Snapshot?,
) -> Unit raise {
  let snapshot = match read {
    Some(s) => s
    None => context_snapshot(db, session)
  }
  let state = snapshot.state
  let mut changed = false
  let mut target : Call? = None
  for pair in calls {
    let (call, of) = pair
    let saved = match jget(Some(state), "saved") {
      Some(Obj(_) as o) => Some(o)
      _ => None
    }
    if saved is Some(sv) {
      let last = vnum(jget(Some(sv), "lastCallAt"))
      if last is Some(l) && call.at < l {
        if jget(Some(sv), "cacheMs") is Some(_) ||
          jget(Some(sv), "rereadCost") is Some(_) {
          jdel(sv, "cacheMs")
          jdel(sv, "rereadCost")
          changed = true
        }
        continue
      }
      if last is Some(l) && call.at == l {
        jdel(state, "saved")
        jset(state, "calls", Arr([]))
        jset(state, "turns", Arr([]))
        jset(state, "uncertain", Bool(true))
        ignore(
          db.run(
            (
              #|UPDATE usage_minute_scope SET context_uncertain = 1,
              #|        context_after = (SELECT at FROM usage INDEXED BY usage_session WHERE session = ? ORDER BY at DESC LIMIT 1)
              #|        WHERE session = ?
            ),
            [Json::string(session), Json::string(session)],
          ),
        )
      }
    }
    let recent = jarray(jget(Some(state), "calls"))
    let previous = if recent.length() > 0 {
      Some(recent[recent.length() - 1])
    } else {
      None
    }
    let turn = text_of(of.turn)
    let next : @jsjson.JValue = Obj([
      (jkey("id"), vstr(call.id)),
      (jkey("turn"), jopt_str(turn)),
      (jkey("profile"), jopt_str(text_of(of.profile))),
      (jkey("model"), jopt_str(call.model)),
      (jkey("context"), jopt_num(call.context)),
      (jkey("window"), jopt_num(call.window)),
      (jkey("at"), Num(call.at)),
      (jkey("fast"), Bool(call.fast)),
      (jkey("cacheWrite"), Num(call.cache_write)),
      (jkey("cacheWriteLong"), Num(call.cache_write_long)),
    ])
    let ordered = match previous {
      None => true
      Some(p) =>
        match vnum(jget(Some(p), "at")) {
          Some(pat) =>
            call.at > pat ||
            (
              call.at == pat &&
              (match jget(Some(p), "id") {
                Some(Str(pid)) => units_less(pid, jkey(call.id))
                _ => false
              })
            )
          None => false
        }
    }
    if !ordered {
      jset(state, "uncertain", Bool(true))
      jset(state, "turns", Arr([]))
    } else {
      let turns = jarray(jget(Some(state), "turns"))
      let last_turn = if turns.length() > 0 {
        Some(turns[turns.length() - 1])
      } else {
        None
      }
      let differs = match last_turn {
        None => true
        Some(t) => !jis(jget(Some(t), "id"), turn)
      }
      if differs || turns.length() == 0 {
        let list = match jget(Some(state), "turns") {
          Some(Arr(items)) => items
          _ => {
            let items = []
            jset(state, "turns", Arr(items))
            items
          }
        }
        list.push(
          Obj([(jkey("id"), jopt_str(turn)), (jkey("compacted"), Bool(false))]),
        )
        if list.length() > 2 {
          ignore(list.remove(0))
          jset(state, "uncertain", Bool(false))
        }
      }
      match previous {
        Some(p) =>
          match (vnum(jget(Some(p), "context")), call.context, call.model) {
            (Some(pc), Some(cc), Some(model)) =>
              if pc >= compacted_from &&
                cc * 2.0 < pc &&
                jis(jget(Some(p), "profile"), text_of(of.profile)) &&
                jis(jget(Some(p), "model"), Some(model)) {
                let list = jarray(jget(Some(state), "turns"))
                if list.length() > 0 {
                  jset(list[list.length() - 1], "compacted", Bool(true))
                }
              }
            _ => ()
          }
        None => ()
      }
    }
    let list = match jget(Some(state), "calls") {
      Some(Arr(items)) => items
      _ => {
        let items = []
        jset(state, "calls", Arr(items))
        items
      }
    }
    list.push(next)
    // (stable, as Array.prototype.sort: a few calls)
    for i in 1..<list.length() {
      let mut j = i
      while j > 0 && call_before(list[j], list[j - 1]) {
        let t = list[j]
        list[j] = list[j - 1]
        list[j - 1] = t
        j -= 1
      }
    }
    if list.length() > 5 {
      jset(state, "calls", Arr(list[list.length() - 5:].to_array()))
    }
    changed = true
    target = Some(call)
  }
  let owner : Owner? = match target {
    Some(t) =>
      Some({
        runtime: Json::string(runtime),
        model: Json::string(t.model.unwrap_or("")),
        fast: Json::number(if t.fast { 1.0 } else { 0.0 }),
      })
    None => snapshot.owner
  }
  if changed && owner is Some(o) {
    keep_recent(db, session, o, state, snapshot.owner)
  }
}

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
fn text_of(v : Json) -> String? {
  str_of(v)
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
      let calls = jarray(jget(Some(s.state), "calls"))
      calls.length() >= 5 &&
      vnum(jget(Some(calls[0]), "at")).unwrap_or(0.0) > after
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
  let snapshot = context_snapshot(db, session)
  if !reliable_tail(snapshot) {
    return []
  }
  let calls = jarray(jget(Some(snapshot.state), "calls"))
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
  let s = context_snapshot(db, session)
  reliable_tail(s) &&
  !(jget(Some(s.state), "uncertain") is Some(Bool(true))) &&
  jarray(jget(Some(s.state), "turns"))
  .iter()
  .any(t => jget(Some(t), "compacted") is Some(Bool(true)))
}

///|
/// usage-compact.ts `savedCompactContext`.
fn saved_compact_context(db : @sql.Db, session : String) -> Json raise {
  let s = context_snapshot(db, session)
  if s.invalid {
    return Json::null()
  }
  guard jget(Some(s.state), "saved") is Some(saved) else { return Json::null() }
  let id = match
    one_of(db, "SELECT runtime_session_id AS id FROM sessions WHERE key = ?", [
      Json::string(session),
    ]) {
    Some(r) => col(r, "id")
    None => return Json::null()
  }
  let runtime = jget(Some(saved), "runtimeSession")
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
