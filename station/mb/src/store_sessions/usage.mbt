// What the agents spent (store.ts `// ── usage ──`, store/usage.ts): one row a model call, with the turn it was in and
// whom that worked for; how far each transcript was read; the context a session's calls left; and what is read of it.

///|
pub fn Store::usage_counter(self : Store) -> Json raise {
  match self.one("SELECT since, through FROM usage_counter WHERE id = 1", []) {
    Some(r) => row_json(r)
    None => undefined()
  }
}

///|
pub fn Store::advance_usage_counter(self : Store, through : Json) -> Unit raise {
  ignore(
    self.run(
      "UPDATE usage_counter SET through = MAX(through, ?) WHERE id = 1",
      [through],
    ),
  )
}

///|
/// store/usage.ts `usageCounterFile`.
pub fn Store::usage_counter_file(self : Store, path : Json) -> Json raise {
  match
    self.one(
      "SELECT counter_cutoff AS cutoff, counter_anchor AS anchor FROM usage_files WHERE path = ?",
      [path],
    ) {
    Some(r) if !(col(r, "cutoff") is Null) =>
      { "cutoff": col(r, "cutoff"), "anchor": col(r, "anchor") }
    _ => Json::null()
  }
}

///|
/// store/usage.ts `beginUsageCounterFile`, in a transaction of its own.
pub fn Store::begin_usage_counter_file(
  self : Store,
  path : Json,
  file : Json,
  counter : Json,
  reset : Bool,
) -> Json raise {
  self.tx(() => {
    ignore(
      self.run(
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
          path,
          nullish(field(file, "session")),
          nullish(field(file, "offset")),
          nullish(field(file, "model")),
          nullish(field(counter, "cutoff")),
          nullish(field(counter, "anchor")),
          flag(reset),
          nullish(field(file, "speed")),
        ],
      ),
    )
    self.usage_counter_file(path)
  })
}

///|
fn usage_files_of(rows : Array[Map[String, Json]]) -> Json {
  let out : Array[(String, Json)] = []
  let idx : Map[String, Int] = Map([])
  for r in rows {
    let k = js_string(col(r, "path"))
    let v : Json = {
      "session": col(r, "session"),
      "offset": col(r, "offset"),
      "model": col(r, "model"),
      "speed": col(r, "speed"),
    }
    match idx.get(k) {
      None => {
        idx[k] = out.length()
        out.push((k, v))
      }
      Some(at) => out[at] = (k, v)
    }
  }
  entries(out)
}

///|
pub fn Store::usage_files(self : Store) -> Json raise {
  usage_files_of(self.all("SELECT path, session, offset, model, speed FROM usage_files", []))
}

///|
pub fn Store::usage_file(self : Store, path : Json) -> Json raise {
  match
    self.one("SELECT session, offset, model, speed FROM usage_files WHERE path = ?", [
      path,
    ]) {
    Some(r) => row_json(r)
    None => undefined()
  }
}

///|
/// usage-compact.ts `hasCompactUsage`: once there, known.
fn Store::has_compact(self : Store) -> Bool raise {
  if self.compact {
    return true
  }
  let installed = self.one(
      "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name IN ('usage_contexts', 'usage_compact_since') LIMIT 1",
      [],
    )
    is Some(_)
  if installed {
    self.compact = true
  }
  installed
}

///|
/// A call as test/mb-store-sessions.test.ts gives it (store/usage.ts UsageCall).
fn call_of(c : Json) -> Call {
  let num = (k : String) => num_of(nullish(field(c, k))).unwrap_or(0.0)
  {
    id: js_string(nullish(field(c, "id"))),
    at: num("at"),
    model: str_of(nullish(field(c, "model"))),
    subagent: truthy(nullish(field(c, "subagent"))),
    fast: truthy(nullish(field(c, "fast"))),
    input: num("input"),
    cache_read: num("cacheRead"),
    cache_write: num("cacheWrite"),
    cache_write_long: num("cacheWriteLong"),
    output: num("output"),
    calls: num("calls"),
    context: num_of(nullish(field(c, "context"))),
    window: num_of(nullish(field(c, "window"))),
    gen_ms: num("genMs"),
  }
}

///|
fn for_of(f : Json) -> For {
  {
    turn: nullish(field(f, "turn")),
    person: nullish(field(f, "person")),
    thread: nullish(field(f, "thread")),
    profile: nullish(field(f, "profile")),
  }
}

///|
/// store/usage.ts `recordUsage`: a transcript's calls (`[call, for]` each) read up to `file.offset`; a call recorded
/// before keeps its row (its output grown). How many were new. `options`: `minNewAt`, `changed` (its `from` lowered to
/// the earliest call changed, in place), `counter`.
fn Store::record_usage_in(
  self : Store,
  path : Json,
  file : Json,
  runtime : String,
  calls : Array[Json],
  options : Json,
) -> Int32 raise {
  let mut added = 0
  let compact = self.has_compact()
  let recent : Array[(Call, For)] = []
  let min_new_at = num_of(nullish(field(options, "minNewAt")))
  let changed = field(options, "changed")
  if field(file, "session") is Some(String(session)) {
    let mut seeded = false
    let mut snapshot : Snapshot? = None
    let insert = if compact {
      (
        #|INSERT INTO usage (id, at, session, turn, thread, person, profile, runtime, model, subagent, fast, input, cache_read, cache_write, cache_write_long, output, calls, context, context_window, gen_ms, gen_output, rollup_counted, compact_counted)
        #|       VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16, ?17, ?18, ?19, ?20, CASE WHEN ?20 > 0 THEN ?16 ELSE 0 END, 1, 1)
        #|
      )
    } else {
      (
        #|INSERT INTO usage (id, at, session, turn, thread, person, profile, runtime, model, subagent, fast, input, cache_read, cache_write, cache_write_long, output, calls, context, context_window, gen_ms, gen_output, rollup_counted)
        #|       VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16, ?17, ?18, ?19, ?20, CASE WHEN ?20 > 0 THEN ?16 ELSE 0 END, 1)
        #|       ON CONFLICT (id) DO UPDATE SET output = MAX(output, excluded.output), gen_ms = MAX(gen_ms, excluded.gen_ms),
        #|  gen_output = CASE WHEN MAX(gen_ms, excluded.gen_ms) > 0 THEN MAX(output, excluded.output) ELSE 0 END
      )
    }
    for pair in calls {
      let c = call_of(arr(pair)[0])
      let of = for_of(arr(pair)[1])
      let was = match
        self.one("SELECT output, gen_ms FROM usage WHERE id = ?", [jstr(c.id)]) {
        Some(r) => Some((num_of(col(r, "output")).unwrap_or(0.0), num_of(col(r, "gen_ms")).unwrap_or(0.0)))
        None => None
      }
      if was is None && min_new_at is Some(min) && c.at < min {
        continue
      }
      if was is Some((o, g)) && c.output <= o && c.gen_ms <= g {
        continue
      }
      if compact && !seeded {
        seeded = true
        if self.usage_totals_complete(session) {
          snapshot = seed_context(self.db, session)
        }
      }
      if was is Some(_) && compact {
        ignore(
          self.run(
            (
              #|UPDATE usage SET output = MAX(output, ?1), gen_ms = MAX(gen_ms, ?3),
              #|  gen_output = CASE WHEN MAX(gen_ms, ?3) > 0 THEN MAX(output, ?1) ELSE 0 END
              #|      WHERE id = ?2 AND (output < ?1 OR gen_ms < ?3)
            ),
            [jnum(c.output), jstr(c.id), jnum(c.gen_ms)],
          ),
        )
      } else {
        ignore(
          self.run(insert, [
            jstr(c.id),
            jnum(c.at),
            jstr(session),
            of.turn,
            of.thread,
            of.person,
            of.profile,
            jstr(runtime),
            opt_str(c.model),
            flag(c.subagent),
            flag(c.fast),
            jnum(c.input),
            jnum(c.cache_read),
            jnum(c.cache_write),
            jnum(c.cache_write_long),
            jnum(c.output),
            jnum(c.calls),
            opt_num(c.context),
            opt_num(c.window),
            jnum(c.gen_ms),
          ]),
        )
      }
      if was is None {
        added += 1
        if compact && !c.subagent {
          recent.push((c, of))
        }
      }
      if changed is Some(Object(ch)) {
        let from = num_of(nullish(ch.get("from")))
        ch["from"] = jnum(
          match from {
            Some(f) => if c.at < f { c.at } else { f }
            None => c.at
          },
        )
      }
    }
    if recent.length() > 0 {
      note_contexts(self.db, session, runtime, recent, snapshot)
    }
  }
  let counter = nullish(field(options, "counter"))
  ignore(
    self.run(
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
        path,
        nullish(field(file, "session")),
        nullish(field(file, "offset")),
        nullish(field(file, "model")),
        nullish(field(counter, "cutoff")),
        nullish(field(counter, "anchor")),
        nullish(field(file, "speed")),
      ],
    ),
  )
  added
}

///|
/// Records a transcript's calls: in a transaction of its own, or in the one under way.
pub fn Store::record_usage(
  self : Store,
  path : Json,
  file : Json,
  runtime : String,
  calls : Array[Json],
  options : Json,
) -> Int32 raise {
  if self.in_tx() {
    return self.record_usage_in(path, file, runtime, calls, options)
  }
  self.tx(() => self.record_usage_in(path, file, runtime, calls, options))
}

///|
/// `recordUsage` of each (store.ts UsageWrite: `{path, file, runtime, calls, options?}`), in one transaction.
pub fn Store::record_usage_all(
  self : Store,
  writes : Array[Json],
) -> Array[Int32] raise {
  if writes.length() == 0 {
    return []
  }
  self.tx(() => {
    writes.map(w => {
      self.record_usage(
        nullish(field(w, "path")),
        nullish(field(w, "file")),
        js_string(nullish(field(w, "runtime"))),
        arr(nullish(field(w, "calls"))),
        nullish(field(w, "options")),
      )
    })
  })
}

///|
/// usage-compactions.ts `usageCompactionsReady`.
fn Store::compactions_ready_in(self : Store) -> Bool raise {
  if self.has_compact() {
    return false
  }
  match
    self.one("SELECT done FROM usage_compaction_backfill WHERE id = 1", []) {
    Some(r) => is_n(col(r, "done"), 1.0)
    None =>
      raise store_error("Cannot read properties of undefined (reading 'done')")
  }
}

///|
/// A session's last `limit` main-thread calls, oldest first (store/usage.ts `lastContexts`).
pub fn Store::last_contexts(
  self : Store,
  session : String,
  limit : Int32,
) -> Array[Json] raise {
  if self.has_compact() {
    return compact_contexts(self.db, session, limit)
  }
  if !self.compactions_ready_in() {
    return []
  }
  let rows = self.all(last_contexts, [jstr(session), ints(limit)])
  rows.rev_in_place()
  rows.map(r => {
    "turn": col(r, "turn"),
    "profile": col(r, "profile"),
    "model": col(r, "model"),
    "context": col(r, "context"),
    "window": col(r, "context_window"),
    "at": col(r, "at"),
    "fast": jbool(!is_n(col(r, "fast"), 0.0) && !(col(r, "fast") is Null)),
    "cacheWrite": col(r, "cache_write"),
    "cacheWriteLong": col(r, "cache_write_long"),
  })
}

///|
pub fn Store::recently_compacted(self : Store, session : String) -> Bool raise {
  self.has_compact() && compact_recently_compacted(self.db, session)
}

///|
pub fn Store::saved_compact_context(
  self : Store,
  session : String,
) -> Json raise {
  if self.has_compact() {
    saved_compact_context(self.db, session)
  } else {
    Json::null()
  }
}

///|
/// Where each model's context was compacted since `since` (a Map's entries).
pub fn Store::compaction_points(self : Store, since : Json) -> Json raise {
  if !self.compactions_ready_in() {
    return entries([])
  }
  let out = []
  for
    r in self.all(
      "SELECT model, MAX(point) AS point FROM usage_compaction_events WHERE at >= ? GROUP BY model",
      [since],
    ) {
    out.push((js_string(col(r, "model")), col(r, "point")))
  }
  entries(out)
}

///|
pub fn Store::compactions_ready(self : Store) -> Bool raise {
  self.compactions_ready_in()
}

///|
/// Tell followers about new calls or completed statistics.
pub fn Store::usage_changed(
  self : Store,
  sessions : Array[Json],
  from : Json?,
  statistics_only : Bool,
) -> Unit {
  let o : Map[String, Json] = Map([])
  o["type"] = jstr("usage")
  o["sessions"] = Json::array(sessions)
  if from is Some(f) {
    o["from"] = f
  }
  if statistics_only {
    o["statisticsOnly"] = jbool(true)
  }
  self.send([Json::object(o)])
}

///|
pub fn Store::usage_active_sessions(
  self : Store,
  since : Json,
) -> Array[Json] raise {
  let out = []
  let seen : Set[String] = Set([])
  for r in self.all(active_sessions, [since]) {
    let s = col(r, "session_key")
    let key = s.stringify()
    if !seen.contains(key) {
      seen.add(key)
      out.push(s)
    }
  }
  out
}

///|
/// store/usage.ts EARLIEST.
let earliest : Double = -9007199254740991.0

///|
/// The turns of a session calls made from `from` until `until` were made in, oldest first, each with whom it worked
/// for (store/usage.ts `usageTurns`).
pub fn Store::usage_turns(
  self : Store,
  session : Json,
  from : Json,
  until : Double,
) -> Array[Json] raise {
  let row = self.one("SELECT created_by, profile FROM sessions WHERE key = ?", [
    session,
  ])
  let creator = match row {
    Some(r) => col(r, "created_by")
    None => Json::null()
  }
  let profile = match row {
    Some(r) => col(r, "profile")
    None => jstr("")
  }
  let home = match
    self.one(
      "SELECT id FROM threads WHERE home = ?1 UNION ALL SELECT thread FROM (SELECT thread FROM thread_sessions WHERE session = ?1 ORDER BY joined_at LIMIT 1) LIMIT 1",
      [session],
    ) {
    Some(r) => col(r, "id")
    None => Json::null()
  }
  let begins = match self.one(turns_from, [session, from]) {
    Some(r) => col(r, "at")
    None => Json::null()
  }
  let turns = match begins {
    Null => []
    b => {
      let bv = num_of(b).unwrap_or(0.0)
      self.all(turns_between, [
        session,
        b,
        jnum(if bv > until { bv } else { until }),
      ])
    }
  }
  let delivered = if turns.iter().any(t => col(t, "person") is Null) {
    self
    .all(taken_since, [session, jstr(stillfail_surface), begins])
    .map(r => (col(r, "at"), col(r, "who"), col(r, "thread")))
  } else {
    []
  }
  let out : Array[Json] = []
  let mut next = 0
  let at = (v : Json) => num_of(v).unwrap_or(0.0)
  for n, t in turns {
    let end = if n + 1 < turns.length() {
      at(col(turns[n + 1], "started_at"))
    } else {
      9007199254740991.0
    }
    let started = at(col(t, "started_at"))
    while next < delivered.length() && at(delivered[next].0) < started {
      next += 1
    }
    let first = if col(t, "kind") is String("input") &&
      next < delivered.length() &&
      at(delivered[next].0) < end {
      Some(delivered[next])
    } else {
      None
    }
    let previous = if out.length() > 0 {
      field(out[out.length() - 1], "of")
    } else {
      None
    }
    let prev = (k : String) => {
      match previous {
        Some(p) => nullish(field(p, k))
        None => Json::null()
      }
    }
    let person = or_else(
      or_else(
        col(t, "person"),
        match first {
          Some(f) => f.1
          None => Json::null()
        },
      ),
      or_else(prev("person"), creator),
    )
    let thread = or_else(
      or_else(
        col(t, "thread"),
        match first {
          Some(f) => f.2
          None => Json::null()
        },
      ),
      or_else(prev("thread"), home),
    )
    out.push({
      "id": col(t, "id"),
      "startedAt": col(t, "started_at"),
      "of": {
        "turn": col(t, "id"),
        "person": person,
        "thread": thread,
        "profile": or_else(col(t, "profile"), profile),
      },
    })
  }
  if out.length() == 0 {
    out.push({
      "id": "",
      "startedAt": jnum(earliest),
      "of": {
        "turn": Json::null(),
        "person": creator,
        "thread": home,
        "profile": profile,
      },
    })
  }
  out
}

///|
/// usage-15m.ts I64_MAX's quarter and an exact i64 for a statement.
fn floor_div(n : Int64, d : Int64) -> Int64 {
  if n >= 0L {
    n / d
  } else {
    -1L - (-1L - n) / d
  }
}

///|
/// usage-15m.ts `usage15mQuery` for every workspace (as mb/src/readops/usagegroups.mbt has it, the same statement).
fn usage_15m_query(
  from : Int64,
  to : Int64,
  offset : Int64,
) -> (String, Array[Json])? {
  if from >= to {
    return None
  }
  let q = 900_000L
  let top = 9223372036854775807L
  let args : Array[Json] = []
  let bind = (value : Json) => {
    args.push(value)
    "?\{args.length()}"
  }
  let off = bind(jint(offset))
  let scope = "1"
  let index = " INDEXED BY usage_15m_quarter"
  let open = to == top
  let first = -floor_div(-from, q)
  let last = if open { floor_div(top, q) + 1L } else { floor_div(to, q) }
  let raw = (pairs : String, low : String, high : String) => {
    "SELECT strftime('%Y-%m-%d', (u.at + \{off} * 60000) / 1000.0, 'unixepoch') AS day,\n" +
    "      u.session, COALESCE(u.thread, 0) AS thread, COALESCE(u.person, '') AS person, COALESCE(u.profile, '') AS profile, u.runtime,\n" +
    "      COALESCE(u.model, '') AS model, CASE WHEN u.fast != 0 THEN 1 ELSE 0 END AS fast, u.calls, u.input, u.cache_read, u.cache_write,\n" +
    "      u.cache_write_long, u.output\n" +
    "    FROM (\{pairs}) e CROSS JOIN usage u INDEXED BY usage_session ON u.session = e.session AND u.at >= \{low} AND u.at < \{high}\n" +
    "    WHERE u.rollup_counted = 1"
  }
  let parts : Array[String] = []
  let straddles = if offset * 60_000L % q == 0L {
    None
  } else {
    Some(
      "(((c.quarter * 900000 + \{off} * 60000) % 86400000 + 86400000) % 86400000 > 85500000)",
    )
  }
  if first < last {
    let lo = bind(jint(first))
    let hi = bind(jint(last))
    parts.push(
      "SELECT strftime('%Y-%m-%d', c.quarter * 900 + \{off} * 60, 'unixepoch') AS day, c.session, c.thread, c.person,\n" +
      "      c.profile, c.runtime, c.model, c.fast, c.calls, c.input, c.cache_read, c.cache_write, c.cache_write_long, c.output\n" +
      "      FROM usage_15m c\{index} WHERE \{scope} AND c.quarter >= \{lo} AND c.quarter < \{hi}" +
      (match straddles {
        None => ""
        Some(st) => " AND NOT \{st}"
      }),
    )
    if straddles is Some(st) {
      parts.push(
        raw(
          "SELECT DISTINCT c.session, c.quarter FROM usage_15m c\{index}\n        WHERE \{scope} AND c.quarter >= \{lo} AND c.quarter < \{hi} AND \{st}",
          "e.quarter * 900000",
          "(e.quarter + 1) * 900000",
        ),
      )
    }
  }
  let edge = (quarter : Int64, low : Int64, high : Int64) => {
    if low >= high {
      return
    }
    parts.push(
      raw(
        "SELECT DISTINCT c.session FROM usage_15m c\{index} WHERE \{scope} AND c.quarter = \{bind(jint(quarter))}",
        bind(jint(low)),
        bind(jint(high)),
      ),
    )
  }
  if first > last {
    edge(last, from, to)
  } else {
    edge(first - 1L, from, first * q)
    if !open {
      edge(last, last * q, to)
    }
  }
  if parts.length() == 0 {
    return None
  }
  let sql = "WITH parts AS (\{parts.join("\n  UNION ALL\n  ")})\n" +
    "  SELECT day, session, NULLIF(thread, 0) AS thread, NULLIF(person, '') AS person, NULLIF(profile, '') AS profile, runtime,\n" +
    "    NULLIF(model, '') AS model, fast, SUM(calls) AS calls, SUM(input) AS input, SUM(cache_read) AS cache_read,\n" +
    "    SUM(cache_write) AS cache_write, SUM(cache_write_long) AS cache_write_long, SUM(output) AS output\n" +
    "  FROM parts GROUP BY day, session, thread, person, profile, runtime, model, fast\n" +
    "  ORDER BY day, session, thread, person, profile, runtime, model, fast"
  Some((sql, args))
}

///|
/// store/usage.ts `usageGroupOf`.
fn usage_group_of(r : Map[String, Json]) -> Json {
  {
    "day": or_else(col(r, "day"), jstr("")),
    "session": col(r, "session"),
    "thread": col(r, "thread"),
    "person": col(r, "person"),
    "profile": col(r, "profile"),
    "runtime": col(r, "runtime"),
    "model": col(r, "model"),
    "fast": jbool(!is_n(col(r, "fast"), 0.0) && !(col(r, "fast") is Null)),
    "calls": col(r, "calls"),
    "input": col(r, "input"),
    "cacheRead": col(r, "cache_read"),
    "cacheWrite": col(r, "cache_write"),
    "cacheWriteLong": col(r, "cache_write_long"),
    "output": col(r, "output"),
  }
}

///|
/// `BigInt(Math.trunc(x))`.
fn trunc64(x : Double) -> Int64 {
  if x >= 0.0 {
    x.floor().to_int64()
  } else {
    (-(-x).floor()).to_int64()
  }
}

///|
/// The calls from `from` until `to`, added up by day `offset` minutes east of UTC and by thread, person, profile and
/// model.
pub fn Store::usage_groups(
  self : Store,
  from : Double,
  to : Double,
  offset : Double,
) -> Array[Json] raise {
  match usage_15m_query(trunc64(from), trunc64(to), trunc64(offset)) {
    None => []
    Some((sql, args)) => self.all(sql, args).map(usage_group_of)
  }
}

///|
/// A session's calls, added up by model.
pub fn Store::usage_of_session(
  self : Store,
  session : String,
) -> Array[Json] raise {
  if !self.usage_totals_complete(session) {
    return []
  }
  self
  .all(
    (
      #|SELECT runtime, NULLIF(model, '') AS model, fast, calls, input, cache_read, cache_write, cache_write_long, output
      #|         FROM usage_totals WHERE session = ?1 AND calls > 0 ORDER BY runtime, model, fast
    ),
    [jstr(session)],
  )
  .map(r => {
    let o = r.copy()
    o["session"] = jstr(session)
    usage_group_of(o)
  })
}

///|
/// The first thing a person said in a thread (up to 300 characters).
pub fn Store::first_text(self : Store, thread : Json) -> Json raise {
  match
    self.one(
      "SELECT substr(m.text, 1, 300) AS t FROM thread_state s JOIN merged m ON m.thread = s.thread AND m.n = s.person_n WHERE s.thread = ?",
      [thread],
    ) {
    Some(r) => col(r, "t")
    None => Json::null()
  }
}

///|
/// The threads usage names, each with the first thing a person said in it (`[thread, first]` each).
pub fn Store::usage_threads(
  self : Store,
  ids : Array[Json],
) -> Array[Json] raise {
  let out = []
  for id in ids {
    let thread = self.get_thread(id)
    if thread is Null {
      continue
    }
    let first = if field(thread, "title") is Some(Null) &&
      field(thread, "autoTitle") is Some(Null) {
      self.first_text(id) catch {
        _ => Json::null()
      }
    } else {
      Json::null()
    }
    out.push(Json::array([thread, first]))
  }
  out
}

///|
/// When the earliest call counted was made (store/usage.ts `usageSince`).
pub fn Store::usage_since(self : Store) -> Json raise {
  let first = match
    self.one("SELECT first_at FROM usage_span WHERE id = 1", []) {
    Some(r) => col(r, "first_at")
    None => Json::null()
  }
  let since = match
    self.one("SELECT since FROM usage_15m_meta WHERE id = 1", []) {
    Some(r) => col(r, "since")
    None => Json::null()
  }
  match since {
    Null => first
    Number(s, ..) => {
      let f = num_of(first).unwrap_or(s)
      jnum(if f > s { f } else { s })
    }
    _ => first
  }
}
