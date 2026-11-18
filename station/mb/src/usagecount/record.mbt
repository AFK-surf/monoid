// What the counter found, written as the station's store writes it (station/src/store/usage.ts `recordUsage`,
// `beginUsageCounterFile`; store/usage-compact.ts `seedCompactContext`, `noteCompactContexts`, `keepRecent`): the same
// statements, in BEGIN IMMEDIATE transactions of this program's own on the station's database. A session's recent
// contexts are kept as JSON JavaScript would read and write it (@jsjson), so the text kept is the station's.

///|
/// store/usage.ts `UsageFor`: whom a call's turn worked for, as the database gives it.
priv struct For {
  turn : Json
  person : Json
  thread : Json
  profile : Json
}

///|
/// store/usage.ts `UsageFile`.
priv struct File {
  session : String?
  offset : Double
  model : String?
  /// Where its reading stood of its model's time (speed.mbt `speed_text`).
  speed : String?
}

///|
/// One transcript's part for `record_all` (store.ts `UsageWrite`, with its counter's boundary).
priv struct Write {
  path : String
  file : File
  runtime : String
  calls : Array[(Call, For)]
  min_new_at : Double?
  /// When the earliest call it changed was made (Infinity: none).
  changed : Ref[Double]
  cutoff : Double
  anchor : String
}

///|
/// rows.ts COMPACTED_FROM.
let compacted_from : Double = 50000.0

///|
fn opt_str(s : String?) -> Json {
  match s {
    Some(v) => Json::string(v)
    None => Json::null()
  }
}

///|
fn opt_num(d : Double?) -> Json {
  match d {
    Some(v) => Json::number(v)
    None => Json::null()
  }
}

///|
fn field(row : Map[String, Json], k : String) -> Json {
  row.get(k).unwrap_or(Json::null())
}

///|
fn text_of(v : Json) -> String? {
  match v {
    String(s) => Some(s)
    _ => None
  }
}

///|
fn num_of(v : Json) -> Double? {
  match v {
    Number(d, ..) => Some(d)
    _ => None
  }
}

///|
fn one(db : @sql.Db, sql : String, params : Array[Json]) -> Map[String, Json]? raise {
  let rows = db.all(sql, params)
  if rows.length() > 0 {
    Some(rows[0])
  } else {
    None
  }
}

///|
/// What this connection learned of the database's schema once (it migrates forward only): whether the contexts are
/// kept (once there, kept), and whether the totals are incremental (decided as the store opened).
priv struct Schema {
  mut compact : Bool
  mut incremental : Bool?
}

///|
/// store/usage-compact.ts `hasCompactUsage`.
fn Schema::has_compact(self : Schema, db : @sql.Db) -> Bool raise {
  if self.compact {
    return true
  }
  let installed = one(db, "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name IN ('usage_contexts', 'usage_compact_since') LIMIT 1", []) is Some(_)
  if installed {
    self.compact = true
  }
  installed
}

///|
/// store/usage-totals-source.ts `usageTotalsComplete`.
fn Schema::totals_complete(self : Schema, db : @sql.Db, session : String) -> Bool raise {
  let incremental = match self.incremental {
    Some(known) => known
    None => {
      let known = one(db, "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'usage_totals_incremental'", []) is Some(_)
      self.incremental = Some(known)
      known
    }
  }
  if !incremental {
    return true
  }
  match one(db, "SELECT done FROM usage_totals_source_sessions WHERE session = ?", [Json::string(session)]) {
    Some(row) => num_of(field(row, "done")) == Some(1.0)
    None => false
  }
}

// ── JSON as JavaScript keeps it ──

///|
fn jkey(k : String) -> Array[Int] {
  @jsjson.units(k)
}

///|
fn same_units(a : Array[Int], b : Array[Int]) -> Bool {
  if a.length() != b.length() {
    return false
  }
  for i in 0..<a.length() {
    if a[i] != b[i] {
      return false
    }
  }
  true
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
fn jstr(s : String) -> @jsjson.JValue {
  Str(jkey(s))
}

///|
fn jopt_str(s : String?) -> @jsjson.JValue {
  match s {
    Some(v) => jstr(v)
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
fn jnum(v : @jsjson.JValue?) -> Double? {
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
fn units_less(a : Array[Int], b : Array[Int]) -> Bool {
  let m = if a.length() < b.length() { a.length() } else { b.length() }
  for i in 0..<m {
    if a[i] != b[i] {
      return a[i] < b[i]
    }
  }
  a.length() < b.length()
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
  owner : Owner?
}

///|
fn fresh_state(uncertain : Bool) -> @jsjson.JValue {
  Obj([(jkey("calls"), Arr([])), (jkey("turns"), Arr([])), (jkey("uncertain"), Bool(uncertain))])
}

///|
/// usage-compact.ts `contextSnapshot`.
fn context_snapshot(db : @sql.Db, session : String) -> Snapshot raise {
  let row = one(
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
    Some(r) => num_of(field(r, "invalid")) == Some(1.0)
    None => false
  }
  let (state, stored) = match row {
    Some(r) =>
      match field(r, "state") {
        Null => (fresh_state(invalid), false)
        String(text) => (@jsjson.parse(text), true)
        other => (@jsjson.parse(other.stringify()), true)
      }
    None => (fresh_state(invalid), false)
  }
  let owner = match row {
    Some(r) if !(field(r, "runtime") is Null) =>
      Some({ runtime: field(r, "runtime"), model: field(r, "model"), fast: field(r, "fast") })
    _ => None
  }
  { state, stored, invalid, owner }
}

///|
/// usage-compact.ts `keepRecent`: the context put on the totals row the call changed; the pointer moved only when the
/// model, runtime or speed changes.
fn keep_recent(db : @sql.Db, session : String, owner : Owner, state : @jsjson.JValue, previous : Owner?) -> Unit raise {
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
      [s, owner.runtime, owner.model, owner.fast, Json::string(@jsjson.stringify(state))],
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
  let row = one(
    db,
    (
      #|SELECT u.usage, s.runtime_session_id AS runtime, r.at AS began
      #|    FROM session_usage u JOIN sessions s ON s.key = u.session
      #|    LEFT JOIN runtime_sessions r ON r.session_key = s.key AND r.id = s.runtime_session_id WHERE u.session = ?
    ),
    [s],
  )
  guard row is Some(row) else { return Some(snapshot) }
  guard field(row, "runtime") is String(runtime) && num_of(field(row, "began")) is Some(began) else {
    return Some(snapshot)
  }
  let old = match field(row, "usage") {
    String(text) => @jsjson.parse(text)
    _ => fail("a session's usage is not JSON")
  }
  guard old is Obj(_) else { fail("a session's usage is not an object") }
  let total = match one(db, "SELECT COALESCE(SUM(calls), 0) AS n FROM usage_totals WHERE session = ? AND calls > 0", [s]) {
    Some(r) => num_of(field(r, "n")).unwrap_or(0.0)
    None => 0.0
  }
  let model = jget(Some(old), "model")
  let window = jget(Some(old), "contextWindow")
  guard jnum(jget(Some(old), "modelCalls")) == Some(total) &&
    jnum(jget(Some(old), "lastCallAt")) is Some(last) &&
    !(last < began) &&
    (model is Some(Null) || model is Some(Str(_))) &&
    (window is Some(Null) || window is Some(Num(_))) else {
    return Some(snapshot)
  }
  let saved : @jsjson.JValue = Obj([
    (jkey("runtimeSession"), jstr(runtime)),
    (jkey("model"), model.unwrap()),
    (jkey("contextWindow"), window.unwrap()),
    (jkey("lastCallAt"), Num(last)),
  ])
  for name in ["contextTokens", "cacheMs", "rereadCost"] {
    if jget(Some(old), name) is Some(Num(v)) {
      jset(saved, name, Num(v))
    }
  }
  let owner = match one(db, "SELECT runtime, model, fast FROM usage_totals WHERE session = ? ORDER BY runtime, model, fast LIMIT 1", [s]) {
    Some(r) => { runtime: field(r, "runtime"), model: field(r, "model"), fast: field(r, "fast") }
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
  let x = jnum(jget(Some(a), "at")).unwrap_or(0.0)
  let y = jnum(jget(Some(b), "at")).unwrap_or(0.0)
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
fn note_contexts(db : @sql.Db, session : String, runtime : String, calls : Array[(Call, For)], read : Snapshot?) -> Unit raise {
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
      let last = jnum(jget(Some(sv), "lastCallAt"))
      if last is Some(l) && call.at < l {
        if jget(Some(sv), "cacheMs") is Some(_) || jget(Some(sv), "rereadCost") is Some(_) {
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
    let previous = if recent.length() > 0 { Some(recent[recent.length() - 1]) } else { None }
    let turn = text_of(of.turn)
    let next : @jsjson.JValue = Obj([
      (jkey("id"), jstr(call.id)),
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
        match jnum(jget(Some(p), "at")) {
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
      let last_turn = if turns.length() > 0 { Some(turns[turns.length() - 1]) } else { None }
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
        list.push(Obj([(jkey("id"), jopt_str(turn)), (jkey("compacted"), Bool(false))]))
        if list.length() > 2 {
          ignore(list.remove(0))
          jset(state, "uncertain", Bool(false))
        }
      }
      match previous {
        Some(p) =>
          match (jnum(jget(Some(p), "context")), call.context, call.model) {
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

// ── the calls and positions ──

///|
/// store/usage.ts `recordUsage`: a transcript's calls read up to `file.offset`, each with what it was for; a call
/// recorded before keeps its row (its output grown). How many were new. In the caller's transaction.
fn record(db : @sql.Db, schema : Schema, w : Write) -> Int raise {
  let mut added = 0
  let compact = schema.has_compact(db)
  let recent : Array[(Call, For)] = []
  if w.file.session is Some(session) {
    let mut seeded = false
    let mut snapshot : Snapshot? = None
    let insert = if compact {
      (
        #|INSERT INTO usage (id, at, session, turn, thread, person, profile, runtime, model, subagent, fast, input, cache_read, cache_write, cache_write_long, output, calls, context, context_window, gen_ms, gen_output, rollup_counted, compact_counted)
        #|       VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16, ?17, ?18, ?19, ?20, CASE WHEN ?20 > 0 THEN ?16 ELSE 0 END, 1, 1)
      )
    } else {
      (
        #|INSERT INTO usage (id, at, session, turn, thread, person, profile, runtime, model, subagent, fast, input, cache_read, cache_write, cache_write_long, output, calls, context, context_window, gen_ms, gen_output, rollup_counted)
        #|       VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16, ?17, ?18, ?19, ?20, CASE WHEN ?20 > 0 THEN ?16 ELSE 0 END, 1)
        #|       ON CONFLICT (id) DO UPDATE SET output = MAX(output, excluded.output), gen_ms = MAX(gen_ms, excluded.gen_ms),
        #|  gen_output = CASE WHEN MAX(gen_ms, excluded.gen_ms) > 0 THEN MAX(output, excluded.output) ELSE 0 END
      )
    }
    for pair in w.calls {
      let (c, of) = pair
      let was = match one(db, "SELECT output, gen_ms FROM usage WHERE id = ?", [Json::string(c.id)]) {
        Some(r) => Some((num_of(field(r, "output")).unwrap_or(0.0), num_of(field(r, "gen_ms")).unwrap_or(0.0)))
        None => None
      }
      // An old call may grow after the cutover, but an unseen old call is not historical work to fill in.
      if was is None && w.min_new_at is Some(min) && c.at < min {
        continue
      }
      // The same response can occur in several lines or be replayed after an interrupted read.
      if was is Some((o, g)) && c.output <= o && c.gen_ms <= g {
        continue
      }
      if compact && !seeded {
        seeded = true
        if schema.totals_complete(db, session) {
          snapshot = seed_context(db, session)
        }
      }
      if was is Some(_) && compact {
        ignore(
          db.run(
            (
              #|UPDATE usage SET output = MAX(output, ?1), gen_ms = MAX(gen_ms, ?3),
              #|  gen_output = CASE WHEN MAX(gen_ms, ?3) > 0 THEN MAX(output, ?1) ELSE 0 END
              #|      WHERE id = ?2 AND (output < ?1 OR gen_ms < ?3)
            ),
            [Json::number(c.output), Json::string(c.id), Json::number(c.gen_ms)],
          ),
        )
      } else {
        ignore(
          db.run(insert, [
            Json::string(c.id),
            Json::number(c.at),
            Json::string(session),
            of.turn,
            of.thread,
            of.person,
            of.profile,
            Json::string(w.runtime),
            opt_str(c.model),
            Json::number(if c.subagent { 1.0 } else { 0.0 }),
            Json::number(if c.fast { 1.0 } else { 0.0 }),
            Json::number(c.input),
            Json::number(c.cache_read),
            Json::number(c.cache_write),
            Json::number(c.cache_write_long),
            Json::number(c.output),
            Json::number(c.calls),
            opt_num(c.context),
            opt_num(c.window),
            Json::number(c.gen_ms),
          ]),
        )
      }
      if was is None {
        added += 1
        if compact && !c.subagent {
          recent.push((c, of))
        }
      }
      if c.at < w.changed.val {
        w.changed.val = c.at
      }
    }
    if recent.length() > 0 {
      note_contexts(db, session, w.runtime, recent, snapshot)
    }
  }
  ignore(
    db.run(
      (
        #|INSERT INTO usage_files (path, session, offset, model, counter_cutoff, counter_anchor, speed) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)
        #|     ON CONFLICT (path) DO UPDATE SET session = excluded.session, offset = excluded.offset, model = excluded.model,
        #|       counter_cutoff = COALESCE(excluded.counter_cutoff, usage_files.counter_cutoff),
        #|       counter_anchor = CASE WHEN excluded.counter_cutoff IS NULL THEN usage_files.counter_anchor ELSE excluded.counter_anchor END,
        #|       speed = excluded.speed
        #|     WHERE usage_files.session IS NOT excluded.session OR usage_files.offset IS NOT excluded.offset OR usage_files.model IS NOT excluded.model
        #|       OR usage_files.speed IS NOT excluded.speed
        #|       OR (excluded.counter_cutoff IS NOT NULL AND (usage_files.counter_cutoff IS NOT excluded.counter_cutoff OR usage_files.counter_anchor IS NOT excluded.counter_anchor))
      ),
      [
        Json::string(w.path),
        opt_str(w.file.session),
        Json::number(w.file.offset),
        opt_str(w.file.model),
        Json::number(w.cutoff),
        Json::string(w.anchor),
        opt_str(w.file.speed),
      ],
    ),
  )
  added
}

///|
/// store.ts `recordUsageAll`: each write in one BEGIN IMMEDIATE transaction; how many calls each recorded.
fn record_all(db : @sql.Db, schema : Schema, writes : Array[Write]) -> Array[Int] raise {
  if writes.length() == 0 {
    return []
  }
  db.exec("BEGIN IMMEDIATE")
  errdefer (db.exec("ROLLBACK") catch { _ => () })
  let out = writes.map(w => record(db, schema, w))
  db.exec("COMMIT")
  out
}

///|
/// store/usage.ts `CounterFile`.
priv struct CounterFile {
  cutoff : Double
  anchor : String?
}

///|
/// store/usage.ts `usageCounterFile`.
fn counter_file(db : @sql.Db, path : String) -> CounterFile? raise {
  match one(db, "SELECT counter_cutoff AS cutoff, counter_anchor AS anchor FROM usage_files WHERE path = ?", [Json::string(path)]) {
    Some(r) =>
      match num_of(field(r, "cutoff")) {
        Some(cutoff) => Some({ cutoff, anchor: text_of(field(r, "anchor")) })
        None => None
      }
    None => None
  }
}

///|
/// store/usage.ts `usageFile`.
fn usage_file(db : @sql.Db, path : String) -> File? raise {
  match one(db, "SELECT session, offset, model, speed FROM usage_files WHERE path = ?", [Json::string(path)]) {
    Some(r) =>
      Some({
        session: text_of(field(r, "session")),
        offset: num_of(field(r, "offset")).unwrap_or(0.0),
        model: text_of(field(r, "model")),
        speed: text_of(field(r, "speed")),
      })
    None => None
  }
}

///|
/// store/usage.ts `beginUsageCounterFile`, in a BEGIN IMMEDIATE transaction of its own: the boundary and position saved
/// together before reading.
fn begin_counter_file(db : @sql.Db, path : String, file : File, cutoff : Double, anchor : String, reset : Bool) -> CounterFile raise {
  db.exec("BEGIN IMMEDIATE")
  errdefer (db.exec("ROLLBACK") catch { _ => () })
  ignore(
    db.run(
      (
        #|INSERT INTO usage_files (path, session, offset, model, counter_cutoff, counter_anchor, speed)
        #|    VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?8)
        #|    ON CONFLICT(path) DO UPDATE SET
        #|      session = CASE WHEN ?7 THEN excluded.session ELSE usage_files.session END,
        #|      offset = CASE WHEN ?7 THEN excluded.offset ELSE usage_files.offset END,
        #|      model = CASE WHEN ?7 THEN excluded.model ELSE usage_files.model END,
        #|      speed = CASE WHEN ?7 THEN excluded.speed ELSE usage_files.speed END,
        #|      counter_cutoff = CASE WHEN ?7 THEN excluded.counter_cutoff ELSE COALESCE(usage_files.counter_cutoff, excluded.counter_cutoff) END,
        #|      counter_anchor = CASE WHEN ?7 THEN excluded.counter_anchor ELSE COALESCE(usage_files.counter_anchor, excluded.counter_anchor) END
      ),
      [
        Json::string(path),
        opt_str(file.session),
        Json::number(file.offset),
        opt_str(file.model),
        Json::number(cutoff),
        Json::string(anchor),
        Json::number(if reset { 1.0 } else { 0.0 }),
        opt_str(file.speed),
      ],
    ),
  )
  let saved = counter_file(db, path)
  db.exec("COMMIT")
  match saved {
    Some(c) => c
    None => fail("the usage counter's position was not saved")
  }
}
