// These parts asked line by line (reader `--builder harness-comma`), as station/test/mb-comma.test.ts asks the
// TypeScript's on the same cases. A case is `{op, id, args}`, answered `{done: id, ok}` or `{done: id, error, kind}`.
// While one asks the station, the program says `{call, id, args}` and is answered `{answer: id, result}` or
// `{answer: id, threw, kind}`; asked to run a callback it gave (`{$cb: n}` in what it said), as `{cb: n, call: k,
// args}`, it answers `{cbDone: k, ok}` or `{cbDone: k, error, kind, data}`. What it only tells (its log, the frames it
// sends Comma) is `{tell, ...}`. Its clock is the test's: `clock` ops move it, its timers firing in order.

///|
priv struct H {
  host : @host.Host
  waiting : Map[Int, @effect.Deferred[J]]
  /// Done as an answer of the test's comes (and made anew).
  mut answered : @effect.Deferred[Unit]
  mut next_call : Int
  callbacks : Map[Int, async (Array[J]) -> J]
  mut next_cb : Int
  mut now : Double
  timers : Array[(Double, Int, () -> Unit)]
  mut timer_seq : Int
  mut random_seq : Int
  mut words : Words
  mut lang : String
  stats : Map[Int, CommaStats]
  dbs : Map[Int, @sql.Db]
  tasks : Map[Int, CommaTasks]
  syncs : Map[Int, IndexSync]
  surfaces : Map[Int, CommaSurface]
  close_listeners : Map[Int, Map[Int, () -> Unit]]
  holders : Map[Int, Holder]
  wsindexes : Map[Int, (CommaIndexes, Ref[Bool], Ref[Int])]
  parts : Map[Int, (CommaParts, PartsState)]
  lives : Map[Int, (CommaLive, LiveState)]
  mut next_handle : Int
  mut io : Io?
}

///|
fn H::say(self : H, v : J) -> Unit {
  self.host.say(stringify(v))
}

///|
/// Asks the test, and waits for its answer.
async fn H::call(self : H, name : String, args : Array[J]) -> J {
  self.next_call += 1
  let id = self.next_call
  let d : @effect.Deferred[J] = @effect.Deferred::new()
  self.waiting[id] = d
  self.say(jobj([("call", jstr(name)), ("id", ji(id)), ("args", Arr(args))]))
  d.wait()
}

///|
/// A callback the test can run, as what is said of it.
fn H::callback(self : H, f : async (Array[J]) -> J) -> J {
  self.next_cb += 1
  let id = self.next_cb
  self.callbacks[id] = f
  jobj([("$cb", ji(id))])
}

///|
fn H::handle(self : H) -> Int {
  self.next_handle += 1
  self.next_handle
}

///|
/// The clock moved on to `to`: each timer due by then fired in its turn, what it set going let run.
async fn H::advance(self : H, to : Double) -> Array[J] {
  let fired : Array[J] = []
  while true {
    let mut best = -1
    for i, t in self.timers {
      if t.0 <= to && (best < 0 || t.0 < self.timers[best].0 || (t.0 == self.timers[best].0 && t.1 < self.timers[best].1)) {
        best = i
      }
    }
    if best < 0 {
      break
    }
    let (due, _, f) = self.timers.remove(best)
    if due > self.now {
      self.now = due
    }
    fired.push(Num(due))
    f()
    self.drain()
  }
  if to > self.now {
    self.now = to
  }
  fired
}

///|
/// What is set going let run till all of it waits on a timer or on nothing: what asks the test waits for its answer
/// (which the test, reading till this ends, gives), what is ready runs a pause at a time.
async fn H::drain(self : H) -> Unit {
  let mut quiet = 0
  while quiet < 64 {
    if self.waiting.length() > 0 {
      self.answered.wait()
      quiet = 0
      continue
    }
    @effect.pause()
    quiet += 1
  }
}

///|
fn H::make_io(self : H) -> Io {
  let base = host_io(self.host)
  {
    now: () => self.now,
    after: (ms, f) => {
      self.timer_seq += 1
      let seq = self.timer_seq
      self.timers.push((self.now + (if ms < 0 { 0 } else { ms }).to_double(), seq, f))
      () => match self.timers.search_by(t => t.1 == seq) {
        Some(i) => ignore(self.timers.remove(i))
        None => ()
      }
    },
    sleep: async fn(ms) {
      let d : @effect.Deferred[Unit] = @effect.Deferred::new()
      self.timer_seq += 1
      let seq = self.timer_seq
      self.timers.push((self.now + (if ms < 0 { 0 } else { ms }).to_double(), seq, () => ignore(d.succeed(()))))
      d.wait()
    },
    turn: async fn() { @effect.pause() },
    random_hex: n => {
      self.random_seq += 1
      test_random(self.random_seq, n)
    },
    uuid: () => {
      self.random_seq += 1
      test_uuid(self.random_seq)
    },
    log: (level, message, fields) => self.say(
      jobj([("tell", jstr("log")), ("level", jstr(level)), ("message", jstr(message)), ("fields", fields)]),
    ),
    read_text: base.read_text,
    write_private: base.write_private,
    mkdir: base.mkdir,
    file_part: base.file_part,
    open_db: base.open_db,
    platform: "linux",
    arch: "x64",
    hostname: "test-host",
    version: "0.0.0-test",
    words: self.words,
    lang: () => self.lang,
  }
}

///|
/// The test's randomness, the same on both sides: `n` bytes of the hash of the count.
pub fn test_random(seq : Int, n : Int) -> String {
  let h = sha256_hex(utf8_of("random \{seq}"))
  let mut out = h
  while out.length() < n * 2 {
    out = out + h
  }
  out.unsafe_substring(start=0, end=n * 2)
}

///|
/// The test's UUIDs, the same on both sides.
pub fn test_uuid(seq : Int) -> String {
  let digits = seq.to_string()
  let mut pad = digits
  while pad.length() < 12 {
    pad = "0" + pad
  }
  "00000000-0000-4000-8000-\{pad}"
}

///|
fn H::io_now(self : H) -> Io {
  match self.io {
    Some(io) => io
    None => {
      let io = self.make_io()
      self.io = Some(io)
      io
    }
  }
}

///|
fn arg(args : Array[J], i : Int) -> J {
  if i < args.length() {
    args[i]
  } else {
    Null
  }
}

///|
fn sarg(args : Array[J], i : Int) -> String {
  str_of(Some(arg(args, i))).unwrap_or("")
}

///|
fn narg(args : Array[J], i : Int) -> Double {
  num_of(Some(arg(args, i))).unwrap_or(0.0)
}

///|
fn opt_s(v : String?) -> J {
  v.map(jstr).unwrap_or(Null)
}

///|
fn opt_n(v : Double?) -> J {
  v.map(jn).unwrap_or(Null)
}

///|
fn station_rows_of(v : J) -> StationRows {
  {
    station: str_of(prop(Some(v), "station")),
    usage: or_null(prop(Some(v), "usage")),
    chats: arr_of(prop(Some(v), "chats")).unwrap_or([]),
  }
}

///|
fn rows_j(rows : Map[String, (String, String)]) -> J {
  let out : Array[J] = []
  for k, v in rows {
    out.push(Arr([jstr(k), jstr(v.0), jstr(v.1)]))
  }
  Arr(out)
}

///|
fn held_of(v : J) -> Held {
  { epoch: str_of(prop(Some(v), "epoch")), through: num_of(prop(Some(v), "through")).unwrap_or(0.0) }
}

///|
fn wire_of(name : String) -> Wire {
  if name == "task" {
    TaskWire
  } else {
    StatsWire
  }
}

///|
fn index_row_of(v : J) -> IndexRow {
  let r = Some(v)
  {
    key: str_of(prop(r, "key")).unwrap_or(""),
    source: str_of(prop(r, "source")).unwrap_or(""),
    kind: str_of(prop(r, "kind")).unwrap_or(""),
    rev: num_of(prop(r, "rev")).unwrap_or(0.0),
    removed: prop(r, "removed") is Some(Bool(true)),
    json: str_of(prop(r, "json")).unwrap_or(""),
  }
}

///|
fn H::holder_of(self : H, v : J) -> Holder {
  match v {
    Num(n) => self.holders.get(n.to_int()).unwrap_or(Token(-1))
    Str(u) => Named(utext(u))
    _ => Named("")
  }
}

///|
fn page_j(p : Page?) -> J {
  match p {
    Some(p) => p.to_j()
    None => Null
  }
}

///|
/// What a build is given to read: the test's answer to `read` for that handle.
fn H::read_for(self : H, handle : Int) -> async (Double, Double) -> ReadRows {
  async fn(from, to) {
    let got = self.call("read", [ji(handle), Num(from), Num(to)])
    {
      stations: arr_of(prop(Some(got), "stations")).unwrap_or([]).map(station_rows_of),
      unread: arr_of(prop(Some(got), "unread")).unwrap_or([]).filter_map(x => str_of(Some(x))),
      valid: match prop(Some(got), "valid") {
        Some(Bool(false)) => Some(() => false)
        _ => None
      },
    }
  }
}

///|
/// What tells a build that something changed: the test's listeners for that handle.
fn H::changes_for(self : H, handle : Int) -> ((Bool) -> Unit) -> () -> Unit {
  changed => {
    let cb = self.callback(async fn(a) {
      changed(arg(a, 0) is Bool(true))
      Null
    })
    ignore(self.host.rt.fork(async fn() { ignore(self.call("changes.listen", [ji(handle), cb])) }))
    () => ignore(self.host.rt.fork(async fn() { ignore(self.call("changes.stop", [ji(handle), cb])) }))
  }
}

///|
fn H::stats_of(self : H, args : Array[J]) -> CommaStats raise {
  match self.stats.get(narg(args, 0).to_int()) {
    Some(s) => s
    None => raise fail_("no such statistics")
  }
}

///|
fn H::index_of(self : H, args : Array[J]) -> RevIndex raise {
  let s = self.stats_of(args)
  if sarg(args, 1) == "task" {
    s.tasks
  } else {
    s.stats
  }
}

///|
fn H::db_of(self : H, args : Array[J]) -> @sql.Db raise {
  match self.dbs.get(narg(args, 0).to_int()) {
    Some(d) => d
    None => raise fail_("no such database")
  }
}

///|
fn H::tasks_of(self : H, args : Array[J]) -> CommaTasks raise {
  match self.tasks.get(narg(args, 0).to_int()) {
    Some(t) => t
    None => raise fail_("no such tasks")
  }
}

///|
fn H::surface_of(self : H, args : Array[J]) -> CommaSurface raise {
  match self.surfaces.get(narg(args, 0).to_int()) {
    Some(s) => s
    None => raise fail_("no such surface")
  }
}

///|
fn sql_params(v : J) -> Array[Json] {
  arr_of(Some(v)).unwrap_or([]).map(to_json)
}

///|
fn sql_rows(rows : Array[Map[String, Json]]) -> J {
  Arr(rows.map(r => Obj(r.to_array().map(e => (@jsjson.units(e.0), from_json(e.1))))))
}

///|
/// The program's Router hub: each of its asks the test's.
fn H::router_hub(self : H) -> RouterHub {
  {
    get: async fn(sql, params) { self.call("hub.get", [jstr(sql), Arr(params)]) },
    all: async fn(sql, params) { arr_of(Some(self.call("hub.all", [jstr(sql), Arr(params)]))).unwrap_or([]) },
    run: async fn(sql, params) { ignore(self.call("hub.run", [jstr(sql), Arr(params)])) },
    thread_sessions: async fn(thread) { arr_of(Some(self.call("hub.threadSessions", [Num(thread)]))).unwrap_or([]) },
    get_session: async fn(key) { self.call("hub.getSession", [jstr(key)]) },
    ws_of: async fn(row) { str_of(Some(self.call("hub.wsOf", [row]))) },
    deliver: async fn(thread, n, sessions, text, workspace) {
      ignore(
        self.call("hub.deliver", [Num(thread), Num(n), Arr(sessions.map(jstr)), jstr(text), opt_s(workspace)]),
      )
    },
    complete_router_write: async fn(id) { self.call("hub.complete", [jstr(id)]) is Bool(true) },
    say: async fn(thread, author, text, hooks) {
      let h : J = match hooks {
        None => Null
        Some(k) =>
          jobj([
            ("workspace", opt_s(k.workspace)),
            ("before", self.callback(async fn(_) { (k.before)(); Null })),
            ("inserted", self.callback(async fn(a) { (k.inserted)(narg(a, 0)); Null })),
            ("targets", self.callback(async fn(_) { Arr((k.targets)().map(jstr)) })),
          ])
      }
      num_of(Some(self.call("hub.say", [Num(thread), jstr(author), jstr(text), h]))).unwrap_or(0.0)
    },
  }
}

///|
/// What a build reads of the workspace's stations: each read the test's.
fn H::workspace_reads(self : H, of : J) -> WorkspaceReads {
  {
    of: () => match of {
      Null => None
      v => Some((str_of(prop(Some(v), "workspace")).unwrap_or(""), prop(Some(v), "home") is Some(Bool(true))))
    },
    here: async fn(op, args) { str_of(Some(self.call("reads.here", [jstr(op), args]))).unwrap_or("") },
    others: async fn() {
      arr_of(Some(self.call("reads.others", []))).unwrap_or([]).filter_map(x => str_of(Some(x)))
    },
    there: async fn(station, op, args) {
      str_of(Some(self.call("reads.there", [jstr(station), jstr(op), args]))).unwrap_or("")
    },
  }
}

///|
fn H::surface_store(self : H, handle : Int) -> SurfaceStore {
  {
    get_session: async fn(key) { self.call("store.getSession", [ji(handle), jstr(key)]) },
    pending_count: async fn(key) {
      num_of(Some(self.call("store.pendingCount", [ji(handle), jstr(key)]))).unwrap_or(0.0)
    },
    thread_at: async fn(surface, channel, ts) {
      self.call("store.threadAt", [ji(handle), jstr(surface), jstr(channel), jstr(ts)])
    },
    leave_thread: async fn(thread, session) {
      ignore(self.call("store.leaveThread", [ji(handle), Num(thread), jstr(session)]))
    },
    handler: async fn(event) { ignore(self.call("handler", [ji(handle), event])) },
    book_person: Some(async fn(key, person) { ignore(self.call("book.person", [ji(handle), jstr(key), person])) }),
    book_known: Some(async fn(key) { self.call("book.known", [ji(handle), jstr(key)]) }),
  }
}

///|
/// A socket the test keeps: what it is sent told, its close the test's.
fn H::socket(self : H, id : Int) -> Socket {
  {
    id,
    send: text => self.say(jobj([("tell", jstr("sent")), ("socket", ji(id)), ("frame", parse_json(text))])),
    on_close: f => {
      let listeners = match self.close_listeners.get(id) {
        Some(l) => l
        None => {
          let l : Map[Int, () -> Unit] = {}
          self.close_listeners[id] = l
          l
        }
      }
      self.next_cb += 1
      let k = self.next_cb
      listeners[k] = f
      () => listeners.remove(k)
    },
  }
}

///|
/// One case, by its TypeScript name.
async fn H::case(self : H, op : String, args : Array[J]) -> J {
  let io = self.io_now()
  match op {
    // ── pure ──
    "chatRef" => jstr(chat_ref(narg(args, 0), str_of(Some(arg(args, 1)))))
    "chatOf" =>
      match chat_of(sarg(args, 0)) {
        Some((t, s)) => jobj([("thread", Num(t)), ("station", opt_s(s))])
        None => Null
      }
    "statsRowsOf" => rows_j(stats_rows_of(station_rows_of(arg(args, 0)), sarg(args, 1)))
    "taskRowsOf" => rows_j(task_rows_of(station_rows_of(arg(args, 0))))
    "statsWire" => stats_wire(index_row_of(arg(args, 0))).unwrap_or(Null)
    "taskWire" => task_wire(index_row_of(arg(args, 0))).unwrap_or(Null)
    "heldFrom" =>
      match held_from(Some(arg(args, 0))) {
        Some(h) => jobj([("epoch", opt_s(h.epoch)), ("through", Num(h.through))])
        None => Null
      }
    "questionOf" => question_of(Some(arg(args, 0)), sarg(args, 1)).unwrap_or(Null)
    "connectUrl" =>
      jstr(connect_url(sarg(args, 0), sarg(args, 1), str_of(Some(arg(args, 2))), sarg(args, 3), sarg(args, 4)))
    "commaLine" =>
      match comma_line(sarg(args, 0)) {
        Some((server, token)) => jobj([("server", jstr(server)), ("token", jstr(token))])
        None => Null
      }
    "maskToken" => jstr(mask_token(sarg(args, 0)))
    "commaConnects" => Arr(comma_connects(arg(args, 0)).map(c => c.to_j()))
    "credentials" => {
      let c = arg(args, 0)
      let cc = Some(c)
      opt_s(
        credentials({
          connect: {
            id: str_of(prop(cc, "id")).unwrap_or(""),
            enabled: true,
            server: str_of(prop(cc, "server")).unwrap_or(""),
            token: str_of(prop(cc, "token")).unwrap_or(""),
            workspace: str_of(prop(cc, "workspace")),
          },
          scope: str_of(prop(cc, "scope")),
          scope_version: num_of(prop(cc, "scopeVersion")).unwrap_or(0.0).to_int(),
        }),
      )
    }
    "shown" => shown(arg(args, 0))
    "threadTsOf" => jstr(thread_ts_of(sarg(args, 0)))
    "seqTs" => jstr(seq_ts(narg(args, 0)))
    "dayKey" => jstr(day_key(sarg(args, 0)))
    "classify" => {
      let (kind, day) = classify(sarg(args, 0), arg(args, 1) is Bool(true))
      jobj([("kind", ji(kind)), ("day", jstr(day))])
    }
    "isoDay" => jstr(iso_day(narg(args, 0)))
    "workspaceDbName" => jstr(workspace_db_name(sarg(args, 0)))
    "base64" => {
      let xs = arr_of(Some(arg(args, 0))).unwrap_or([])
      jstr(base64(Bytes::from_array(FixedArray::makei(xs.length(), i => num_of(Some(xs[i])).unwrap_or(0.0).to_int().to_byte()))))
    }
    "unbase64" => Arr(unbase64(sarg(args, 0)).to_array().map(b => ji(b.to_int())))
    // ── the world ──
    "words" => {
      self.words = Words::new(arg(args, 0), arg(args, 1), product=str_of(Some(arg(args, 2))).unwrap_or("still.fail"))
      self.io = None
      Null
    }
    "lang" => {
      self.lang = sarg(args, 0)
      Null
    }
    "random.reset" => {
      self.random_seq = 0
      Null
    }
    "clock.set" => {
      self.now = narg(args, 0)
      Null
    }
    "clock.advance" => Arr(self.advance(self.now + narg(args, 0)))
    "clock.timers" => Arr(self.timers.map(t => Num(t.0)))
    "drain" => {
      self.drain()
      Null
    }
    // ── databases ──
    "db.open" => {
      let h = self.handle()
      self.dbs[h] = (io.open_db)(sarg(args, 0), busy_ms)
      ji(h)
    }
    "db.exec" => {
      self.db_of(args).exec(sarg(args, 1))
      Null
    }
    "db.all" => sql_rows(self.db_of(args).all(sarg(args, 1), sql_params(arg(args, 2))))
    "db.close" => {
      self.db_of(args).close()
      Null
    }
    "age.install" => {
      install_stats_age(self.db_of(args))
      Null
    }
    "age.step" => {
      let (visited, done) = stats_age_step(self.db_of(args), limit=narg(args, 1).to_int())
      jobj([("visited", ji(visited)), ("done", Bool(done))])
    }
    "age.ready" =>
      Bool(
        stats_age_ready(self.db_of(args), max_dirty=match arg(args, 1) {
          Null => None
          v => Some(num_of(Some(v)).unwrap_or(0.0).to_int())
        }),
      )
    "age.candidates" =>
      Arr(
        stats_age_candidates(self.db_of(args), sarg(args, 1)).map(k => jobj([
          ("key", jstr(hex(k.key))),
          ("json", jstr(k.json)),
        ])),
      )
    // ── the statistics ──
    "stats.open" => {
      let h = self.handle()
      let path = sarg(args, 0)
      let s = CommaStats::new(path, self.read_for(h), self.changes_for(h), io, self.host.rt, busy=match arg(args, 1) {
        Num(n) => n.to_int()
        _ => busy_ms
      })
      self.stats[h] = s
      ji(h)
    }
    "stats.at" => {
      let h = self.handle()
      self.stats[h] = CommaStats::at(sarg(args, 0), self.read_for(h), self.changes_for(h), io, self.host.rt)
      ji(h)
    }
    "stats.inWorkspace" => {
      let h = self.handle()
      self.stats[h] = CommaStats::in_workspace(
        sarg(args, 0),
        sarg(args, 1),
        self.read_for(h),
        self.changes_for(h),
        io,
        self.host.rt,
      )
      ji(h)
    }
    "wsindex.open" => {
      let h = self.handle()
      let inside = Ref(true)
      let version = Ref(0)
      let (stats, indexes) = workspace_index(
        sarg(args, 0),
        sarg(args, 1),
        () => inside.val,
        () => version.val,
        self.read_for(h),
        self.changes_for(h),
        io,
        self.host.rt,
      )
      self.stats[h] = stats
      self.wsindexes[h] = (indexes, inside, version)
      ji(h)
    }
    "wsindex.set" => {
      match self.wsindexes.get(narg(args, 0).to_int()) {
        Some((_, inside, version)) => {
          inside.val = arg(args, 1) is Bool(true)
          version.val = narg(args, 2).to_int()
        }
        None => raise fail_("no such workspace index")
      }
      Null
    }
    "wsindex.start" => {
      match self.wsindexes.get(narg(args, 0).to_int()) {
        Some((indexes, _, _)) => (indexes.start)()
        None => raise fail_("no such workspace index")
      }
      Null
    }
    "stats.makeDirs" => {
      CommaStats::make_dirs(io, sarg(args, 0))
      Null
    }
    "stats.apply" => {
      let (s, t) = self
        .stats_of(args)
        .apply(
          arr_of(Some(arg(args, 1))).unwrap_or([]).map(station_rows_of),
          arr_of(Some(arg(args, 2))).unwrap_or([]).filter_map(x => str_of(Some(x))),
          narg(args, 3),
        )
      jobj([("stats", ji(s)), ("tasks", ji(t))])
    }
    "stats.said" => opt_n(self.stats_of(args).said(sarg(args, 1)))
    "stats.remember" => {
      self.stats_of(args).remember(sarg(args, 1), narg(args, 2))
      Null
    }
    "stats.taskTitle" =>
      match self.stats_of(args).task_title(sarg(args, 1)) {
        Some(v) => jobj([("title", v)])
        None => Obj([])
      }
    "stats.start" => {
      self.stats_of(args).start()
      Null
    }
    "stats.build" => {
      self.stats_of(args).build()
      Null
    }
    "stats.nudge" => {
      self.stats_of(args).nudge()
      Null
    }
    "stats.settled" => {
      self.stats_of(args).settled()
      Null
    }
    "stats.close" => {
      self.stats_of(args).close()
      Null
    }
    "index.epoch" => jstr(self.index_of(args).epoch())
    "index.rev" => Num(self.index_of(args).rev())
    "index.pruned" => Num(self.index_of(args).pruned())
    "index.since" =>
      Arr(
        self
        .index_of(args)
        .since(narg(args, 2), narg(args, 3).to_int(), omit_removed_bodies=arg(args, 4) is Bool(true))
        .map(r => r.to_j()),
      )
    "index.held" => {
      self.index_of(args).held(self.holder_of(arg(args, 2)), narg(args, 3))
      Null
    }
    "index.following" => {
      let t = self.index_of(args).following()
      let h = self.handle()
      self.holders[h] = t
      ji(h)
    }
    "index.observed" => {
      self.index_of(args).observed(self.holder_of(arg(args, 2)), narg(args, 3))
      Null
    }
    "index.gone" => {
      self.index_of(args).gone(self.holder_of(arg(args, 2)))
      Null
    }
    "index.listen" => {
      let index = self.index_of(args)
      let h = self.handle()
      ignore(index.listen(() => self.say(jobj([("tell", jstr("changed")), ("listener", ji(h))]))))
      ji(h)
    }
    "page.probe" => probe_page(self.index_of(args)).to_j()
    "page.next" => page_j(next_page(self.index_of(args), held_of(arg(args, 2)), wire=wire_of(sarg(args, 3))))
    "sync.new" => {
      let s = IndexSync::new(self.index_of(args), wire=wire_of(sarg(args, 2)))
      let h = self.handle()
      self.syncs[h] = s
      ji(h)
    }
    "sync.next" =>
      match self.syncs.get(narg(args, 0).to_int()) {
        Some(s) => page_j(s.next(held_of(arg(args, 1))))
        None => raise fail_("no such sync")
      }
    "sync.close" => {
      match self.syncs.get(narg(args, 0).to_int()) {
        Some(s) => s.close()
        None => ()
      }
      Null
    }
    // ── the Tasks ──
    "tasks.open" => {
      let h = self.handle()
      self.tasks[h] = CommaTasks::new(sarg(args, 0), io, self.host.rt)
      ji(h)
    }
    "tasks.get" => self.tasks_of(args).get_j(sarg(args, 1), sarg(args, 2)).unwrap_or(Null)
    "tasks.byThread" => self.tasks_of(args).by_thread_j(sarg(args, 1), sarg(args, 2)).unwrap_or(Null)
    "tasks.taking" => Arr(self.tasks_of(args).taking_j(sarg(args, 1)))
    "tasks.invited" =>
      self.tasks_of(args).invited(sarg(args, 1), sarg(args, 2), Start::of_j(Some(arg(args, 3))), narg(args, 4))
    "tasks.given" => {
      self
      .tasks_of(args)
      .given(sarg(args, 1), sarg(args, 2), num_of(Some(arg(args, 3))), num_of(Some(arg(args, 4))))
      Null
    }
    "tasks.left" => {
      self.tasks_of(args).left(sarg(args, 1), sarg(args, 2))
      Null
    }
    "tasks.forget" => {
      self.tasks_of(args).forget(sarg(args, 1))
      Null
    }
    "tasks.written" => {
      self.tasks_of(args).written()
      Null
    }
    // ── peers ──
    "peer.read" => {
      let answer = peer_read(
        async fn(op, a, lang) { str_of(Some(self.call("peer.read", [jstr(op), a, jstr(lang)]))).unwrap_or("") },
        () => str_of(Some(arg(args, 2))),
        () => self.lang,
        () => narg(args, 3).to_int(),
        fn(peer, ws) raise {
          match arg(args, 4) {
            Arr(refused) if refused.iter().any(r => str_of(Some(r)) == Some(peer)) =>
              raise fail_("\{peer} is not of \{ws}")
            _ => ()
          }
        },
      )(sarg(args, 0), arg(args, 1), str_of(Some(arg(args, 5))))
      jobj([("head", answer.head), ("text", jstr(text_of_utf8(answer.bytes)))])
    }
    "peer.textOf" => {
      let chunks = arr_of(Some(arg(args, 0))).unwrap_or([]).map(c => utf8_of(str_of(Some(c)).unwrap_or("")))
      let at = Ref(0)
      jstr(
        text_of(async fn() {
          if at.val < chunks.length() {
            at.val += 1
            Some(chunks[at.val - 1])
          } else {
            None
          }
        }),
      )
    }
    "workspace.read" => {
      let got = workspace_read(self.workspace_reads(arg(args, 0)))(narg(args, 1), narg(args, 2))
      jobj([
        (
          "stations",
          Arr(
            got.stations.map(s => jo([
              ("station", s.station.map(jstr)),
              ("usage", Some(s.usage)),
              ("chats", Some(Arr(s.chats))),
            ])),
          ),
        ),
        ("unread", Arr(got.unread.map(jstr))),
      ])
    }
    // ── the Router ──
    "router.reads" =>
      router_reads(self.stats_of(args), self.workspace_reads(arg(args, 1)), sarg(args, 2), narg(args, 3), narg(args, 4))
    "router.says" => {
      let w = Some(arg(args, 2))
      Num(
        router_says(
          self.router_hub(),
          self.stats_of(args),
          str_of(Some(arg(args, 1))),
          {
            thread: num_of(prop(w, "thread")).unwrap_or(0.0),
            text: str_of(prop(w, "text")).unwrap_or(""),
            key: str_of(prop(w, "key")).unwrap_or(""),
            requester: str_of(prop(w, "requester")).unwrap_or(""),
            connect: str_of(prop(w, "connect")).unwrap_or(""),
          },
          io,
        ),
      )
    }
    // ── Comma's parts ──
    "comma.make" => ji(self.make_parts(arg(args, 0)))
    "comma.set" => {
      let (_, state) = self.parts_of(args)
      let o = Some(arg(args, 1))
      match prop(o, "raw") {
        Some(v) => {
          state.raw.val = v
          for f in state.config_listeners {
            f(v)
          }
        }
        None => ()
      }
      match prop(o, "home") {
        Some(v) => state.home.val = str_of(Some(v))
        None => ()
      }
      match prop(o, "within") {
        Some(v) => state.within.val = strings_of(v)
        None => ()
      }
      match prop(o, "version") {
        Some(Num(n)) => state.version.val = n.to_int()
        _ => ()
      }
      if prop(o, "previousExited") is Some(Bool(true)) {
        ignore(state.previous.succeed(()))
      }
      Null
    }
    "comma.scopeChanged" => {
      let (_, state) = self.parts_of(args)
      for f in state.scope_listeners {
        f()
      }
      Null
    }
    "comma.connects" => {
      let (parts, state) = self.parts_of(args)
      Arr(parts.connects(state.raw.val).map(c => c.to_j()))
    }
    "comma.credentials" => {
      let (parts, state) = self.parts_of(args)
      Arr(parts.connects(state.raw.val).map(c => opt_s(credentials(c))))
    }
    "comma.create" => {
      let (parts, state) = self.parts_of(args)
      let id = sarg(args, 1)
      match parts.connects(state.raw.val).search_by(c => c.connect.id == id) {
        Some(i) => {
          let s = parts.create(parts.connects(state.raw.val)[i])
          let h = self.handle()
          self.surfaces[h] = s
          ji(h)
        }
        None => raise fail_("no such connect")
      }
    }
    "comma.probe" => {
      let (_, state) = self.parts_of(args)
      let s = self.surface_of([arg(args, 1)])
      let stats = match (try { Ok(s.indexes_now()) } catch { e => Err(e) }) {
        Ok(None) => jobj([("none", Bool(true))])
        Ok(Some(i)) =>
          jobj([("is", jstr(if physical_equal(i.stats, state.empty.stats) { "empty" } else { "scoped" }))])
        Err(e) => jobj([("error", jstr(message_of(e)))])
      }
      jobj([
        ("inScope", Bool(s.in_scope_now())),
        ("stats", stats),
        ("chats", Bool(s.chats_now() is Some(_))),
        ("name", jstr(s.name())),
        ("workspace", opt_s(s.of_workspace())),
      ])
    }
    "comma.read" => {
      let s = self.surface_of(args)
      match s.chats_now() {
        Some(c) => (c.read)(sarg(args, 1), narg(args, 2), narg(args, 3))
        None => raise fail_("no chats")
      }
    }
    "comma.say" => {
      let s = self.surface_of(args)
      match s.chats_now() {
        Some(c) => (c.say)(sarg(args, 1), sarg(args, 2), sarg(args, 3), sarg(args, 4), sarg(args, 5))
        None => raise fail_("no chats")
      }
    }
    "comma.shown" => shown(arg(args, 0))
    "comma.close" => {
      let (parts, _) = self.parts_of(args)
      parts.close()
      Null
    }
    "comma.tasksFile" => {
      let (parts, _) = self.parts_of(args)
      jstr(parts.tasks.path)
    }
    // ── the Comma part of the station ──
    "live.new" => ji(self.make_live(arg(args, 0)))
    "live.set" => {
      let (_, state) = self.live_of(args)
      let o = Some(arg(args, 1))
      match prop(o, "home") {
        Some(v) => state.home.val = str_of(Some(v))
        None => ()
      }
      match prop(o, "memberships") {
        Some(v) => state.memberships.val = v
        None => ()
      }
      match prop(o, "station") {
        Some(v) => state.station.val = str_of(Some(v)).unwrap_or("")
        None => ()
      }
      match prop(o, "refused") {
        Some(v) => state.refused.val = strings_of(v)
        None => ()
      }
      if prop(o, "previousExited") is Some(Bool(true)) {
        ignore(state.previous.succeed(()))
      }
      // the cloud's state told it changed
      let all = []
      for _, f in state.cloud_listeners {
        all.push(f)
      }
      for f in all {
        f()
      }
      Null
    }
    "live.changed" => {
      let (_, state) = self.live_of(args)
      let all = []
      for _, f in state.subscribers {
        all.push(f)
      }
      for f in all {
        f(sarg(args, 1))
      }
      Null
    }
    "live.scopeVersion" => ji(self.live_of(args).0.scope_version())
    "live.within" => Bool(self.live_of(args).0.within(sarg(args, 1)))
    "live.name" => jstr(self.live_of(args).0.name(str_of(Some(arg(args, 1)))))
    "live.say" => self.live_of(args).0.say_handler(sarg(args, 1), arg(args, 2), str_of(Some(arg(args, 3))))
    "live.peerChanged" => self.live_of(args).0.changed_handler(sarg(args, 1), str_of(Some(arg(args, 2))))
    "live.peerRead" => {
      let answer = (self.live_of(args).0.peer_read())(sarg(args, 1), arg(args, 2), str_of(Some(arg(args, 3))))
      jobj([("head", answer.head), ("text", jstr(text_of_utf8(answer.bytes)))])
    }
    "live.others" => Arr((self.live_of(args).0.reads_for(sarg(args, 1)).others)().map(jstr))
    "live.here" => jstr((self.live_of(args).0.reads_for(sarg(args, 1)).here)(sarg(args, 2), arg(args, 3)))
    "live.there" =>
      jstr((self.live_of(args).0.reads_for(sarg(args, 1)).there)(sarg(args, 2), sarg(args, 3), arg(args, 4)))
    "live.scopeRead" => {
      let (_, chats) = self.live_of(args).0.scope(sarg(args, 1))
      (chats.read)(sarg(args, 2), narg(args, 3), narg(args, 4))
    }
    "live.scopeSay" => {
      let (_, chats) = self.live_of(args).0.scope(sarg(args, 1))
      (chats.say)(sarg(args, 2), sarg(args, 3), sarg(args, 4), sarg(args, 5), sarg(args, 6))
    }
    "live.scopeStart" => {
      let (indexes, _) = self.live_of(args).0.scope(sarg(args, 1))
      (indexes.start)()
      Null
    }
    "live.emptyEpoch" => jstr(self.live_of(args).0.empty.stats.epoch())
    "live.close" => {
      self.live_of(args).0.close()
      Null
    }
    // ── a connect's surface ──
    "surface.new" => {
      let o = Some(arg(args, 0))
      let h = self.handle()
      let tasks = self.tasks_of([or_null(prop(o, "tasks"))])
      let stats = match prop(o, "stats") {
        Some(Num(s)) => {
          let cs = self.stats_of([Num(s)])
          // (started as the test's TypeScript one is: by nothing, its builds the test's own)
          Some(fn() raise { { stats: cs.stats, tasks: cs.tasks, start: () => () } })
        }
        _ => None
      }
      let in_scope = prop(o, "inScope") is (None | Some(Bool(true)))
      let chats : CommaChats? = match prop(o, "chats") {
        Some(Bool(true)) =>
          Some({
            read: async fn(ref_, after, limit) { self.call("chats.read", [ji(h), jstr(ref_), Num(after), Num(limit)]) },
            say: async fn(ref_, text, key, requester, connect) {
              self.call("chats.say", [ji(h), jstr(ref_), jstr(text), jstr(key), jstr(requester), jstr(connect)])
            },
          })
        _ => None
      }
      let models = arr_of(prop(o, "models")).unwrap_or([])
      let scope = Ref(in_scope)
      let s = CommaSurface::new(
        {
          connect: str_of(prop(o, "connect")).unwrap_or(""),
          server: str_of(prop(o, "server")).unwrap_or(""),
          token: str_of(prop(o, "token")).unwrap_or(""),
          name: str_of(prop(o, "name")).unwrap_or(""),
          workspace: str_of(prop(o, "workspace")),
          tasks,
          store: self.surface_store(h),
          models: () => models,
          lang: str_of(prop(o, "lang")),
          stats,
          chats,
          previous_exited: async fn() { () },
          in_scope: () => scope.val,
        },
        io,
        self.host.rt,
      )
      self.surfaces[h] = s
      ji(h)
    }
    "surface.frame" => {
      let s = self.surface_of(args)
      let socket = self.socket(narg(args, 1).to_int())
      s.frame(socket, arg(args, 2), () => self.say(jobj([("tell", jstr("end")), ("socket", ji(socket.id))])))
      Null
    }
    "surface.message" => {
      let s = self.surface_of(args)
      let socket = self.socket(narg(args, 1).to_int())
      s.message(socket, sarg(args, 2), () => self.say(jobj([("tell", jstr("end")), ("socket", ji(socket.id))])))
      Null
    }
    "surface.closed" => {
      self.surface_of(args).closed()
      Null
    }
    "socket.close" => {
      match self.close_listeners.get(narg(args, 0).to_int()) {
        Some(listeners) => {
          let all = []
          for _, f in listeners {
            all.push(f)
          }
          listeners.clear()
          for f in all {
            f()
          }
        }
        None => ()
      }
      Null
    }
    "surface.post" =>
      jstr(
        self
        .surface_of(args)
        .post(
          sarg(args, 1),
          sarg(args, 2),
          sarg(args, 3),
          arr_of(Some(arg(args, 4))).unwrap_or([]).map(Attachment::of_j),
          card=match arg(args, 5) {
            Null => None
            c => Some(c)
          },
        ),
      )
    "surface.standsAt" => {
      self.surface_of(args).stands_at(sarg(args, 1), sarg(args, 2), sarg(args, 3), str_of(Some(arg(args, 4))))
      Null
    }
    "surface.download" =>
      Arr(
        self
        .surface_of(args)
        .download(sarg(args, 1), sarg(args, 2), narg(args, 3))
        .to_array()
        .map(b => ji(b.to_int())),
      )
    "surface.mention" => jstr(self.surface_of(args).mention(sarg(args, 1)))
    "surface.knownPerson" => self.surface_of(args).known_person(sarg(args, 1))
    "surface.lookUp" => self.surface_of(args).look_up(sarg(args, 1))
    "surface.lookUpEmail" => opt_s(self.surface_of(args).look_up_email(sarg(args, 1)))
    "surface.address" => jstr(self.surface_of(args).address())
    "surface.identify" => self.surface_of(args).identify()
    "surface.headers" => Arr(self.surface_of(args).headers().map(h => Arr([jstr(h.0), jstr(h.1)])))
    "surface.instance" => jstr(self.surface_of(args).instance)
    _ => raise fail_("no such case: \{op}")
  }
}

///|
/// What a test's Comma parts are made with, set by the test as the station's state moves.
priv struct PartsState {
  raw : Ref[J]
  home : Ref[String?]
  within : Ref[Array[String]]
  in_workspace : Ref[Array[String]?]
  version : Ref[Int]
  previous : @effect.Deferred[Unit]
  empty : CommaIndexes
  scoped : CommaIndexes
  scope_listeners : Array[() -> Unit]
  config_listeners : Array[(J) -> Unit]
}

///|
fn strings_of(v : J) -> Array[String] {
  arr_of(Some(v)).unwrap_or([]).filter_map(x => str_of(Some(x)))
}

///|
fn H::parts_of(self : H, args : Array[J]) -> (CommaParts, PartsState) raise {
  match self.parts.get(narg(args, 0).to_int()) {
    Some(p) => p
    None => raise fail_("no such parts")
  }
}

///|
/// Comma's parts (index.mbt `make_comma`) over the test's state, their scopes' Routers the test's.
fn H::make_parts(self : H, o : J) -> Int raise {
  let io = self.io_now()
  let h = self.handle()
  let db = (io.open_db)(":memory:", busy_ms)
  db.exec("CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)")
  let oo = Some(o)
  let state : PartsState = {
    raw: Ref(or_null(prop(oo, "raw"))),
    home: Ref(str_of(prop(oo, "home"))),
    within: Ref(strings_of(or_null(prop(oo, "within")))),
    in_workspace: Ref(
      match prop(oo, "inWorkspace") {
        Some(Arr(_) as v) => Some(strings_of(v))
        _ => None
      },
    ),
    version: Ref(num_of(prop(oo, "version")).unwrap_or(0.0).to_int()),
    previous: @effect.Deferred::new(),
    empty: { stats: RevIndex::new(db, "stats_index", io), tasks: RevIndex::new(db, "task_index", io), start: () => () },
    scoped: { stats: RevIndex::new(db, "stats_index", io), tasks: RevIndex::new(db, "task_index", io), start: () => () },
    scope_listeners: [],
    config_listeners: [],
  }
  let parts = make_comma(
    {
      data: str_of(prop(oo, "data")).unwrap_or(""),
      config_raw: () => state.raw.val,
      config_listen: f => {
        state.config_listeners.push(f)
        () => ()
      },
      in_workspace: match state.in_workspace.val {
        Some(_) =>
          Some(ws => match ws {
            None => true
            Some(w) => state.in_workspace.val.unwrap_or([]).contains(w)
          })
        None => None
      },
      store: self.surface_store(h),
      models: _ => [],
      scope: ws => {
        self.say(jobj([("tell", jstr("scope")), ("workspace", jstr(ws))]))
        (
          state.scoped,
          {
            read: async fn(ref_, after, limit) { self.call("scope.read", [jstr(ws), jstr(ref_), Num(after), Num(limit)]) },
            say: async fn(ref_, text, key, requester, connect) {
              self.call("scope.say", [jstr(ws), jstr(ref_), jstr(text), jstr(key), jstr(requester), jstr(connect)])
            },
          },
        )
      },
      empty: state.empty,
      home: () => state.home.val,
      within: ws => state.within.val.contains(ws),
      scope_version: () => state.version.val,
      on_scope_change: f => {
        state.scope_listeners.push(f)
        () => ()
      },
      previous_exited: async fn() { state.previous.wait() },
      name: match prop(oo, "named") {
        Some(Bool(true)) => Some(ws => "named \{ws.unwrap_or("home")}")
        _ => None
      },
      reconcile: async fn() { ignore(self.call("comma.reconcile", [ji(h)])) },
      close_connects: async fn() { () },
    },
    io,
    self.host.rt,
  )
  self.parts[h] = (parts, state)
  h
}

///|
/// The station as a test's CommaLive sees it, set by the test.
priv struct LiveState {
  home : Ref[String?]
  /// Its workspaces' memberships (`{workspace, workspace_name, name}`), by workspace.
  memberships : Ref[J]
  station : Ref[String]
  refused : Ref[Array[String]]
  previous : @effect.Deferred[Unit]
  cloud_listeners : Map[Int, () -> Unit]
  subscribers : Map[Int, (String) -> Unit]
  mut next : Int
}

///|
fn H::live_of(self : H, args : Array[J]) -> (CommaLive, LiveState) raise {
  match self.lives.get(narg(args, 0).to_int()) {
    Some(l) => l
    None => raise fail_("no such live")
  }
}

///|
async fn H::make_live(self : H, o : J) -> Int {
  let io = self.io_now()
  let oo = Some(o)
  let state : LiveState = {
    home: Ref(str_of(prop(oo, "home"))),
    memberships: Ref(or_null(prop(oo, "memberships"))),
    station: Ref(str_of(prop(oo, "station")).unwrap_or("")),
    refused: Ref([]),
    previous: @effect.Deferred::new(),
    cloud_listeners: {},
    subscribers: {},
    next: 0,
  }
  let live = CommaLive::new(
    {
      data: str_of(prop(oo, "data")).unwrap_or(""),
      home: () => state.home.val,
      memberships: () => match state.memberships.val {
        Obj(entries) => entries.map(e => utext(e.0))
        _ => []
      },
      membership: ws => or_null(prop(Some(state.memberships.val), ws)),
      station: () => state.station.val,
      cloud_listen: f => {
        state.next += 1
        let k = state.next
        state.cloud_listeners[k] = f
        () => state.cloud_listeners.remove(k)
      },
      pages: () => jobj([("origin", jstr("https://app.example")), ("station", jstr("st-here"))]),
      read: async fn(op, args, lang, background) {
        str_of(Some(self.call("live.read", [jstr(op), args, jstr(lang), Bool(background)]))).unwrap_or("")
      },
      ask: async fn(station, request) { self.call("live.ask", [jstr(station), request]) },
      ask_text: async fn(station, request) {
        str_of(Some(self.call("live.askText", [jstr(station), request]))).unwrap_or("")
      },
      member: fn(peer, ws) raise {
        if state.refused.val.contains(peer) {
          raise fail_("\{peer} is not a station of \{ws}")
        }
      },
      subscribe: f => {
        state.next += 1
        let k = state.next
        state.subscribers[k] = f
        () => state.subscribers.remove(k)
      },
      hub: self.router_hub(),
      previous_exited: async fn() { state.previous.wait() },
    },
    io,
    self.host.rt,
  )
  let h = self.handle()
  self.lives[h] = (live, state)
  h
}

///|
fn H::threw(e : Error) -> Array[(String, J)] {
  let base = [("error", jstr(message_of(e))), ("kind", jstr(kind_of(e)))]
  match already_said_j(e) {
    Some(w) => [("error", jstr(stringify(w))), ("kind", jstr("AlreadySaid")), ("data", w)]
    None => base
  }
}

///|
/// The program's harness: cases a line each, answered as they end, until stdin ends.
pub async fn harness(host : @host.Host) -> Unit {
  let h : H = {
    host,
    waiting: {},
    answered: @effect.Deferred::new(),
    next_call: 0,
    callbacks: {},
    next_cb: 0,
    now: 0.0,
    timers: [],
    timer_seq: 0,
    random_seq: 0,
    words: Words::empty(),
    lang: "zh",
    stats: {},
    dbs: {},
    tasks: {},
    syncs: {},
    surfaces: {},
    close_listeners: {},
    holders: {},
    wsindexes: {},
    parts: {},
    lives: {},
    next_handle: 0,
    io: None,
  }
  while host.line() is Some(line) {
    let msg = try {
      parse_json(line)
    } catch {
      _ => continue
    }
    let m = Some(msg)
    match prop(m, "answer") {
      Some(Num(id)) => {
        let told = h.answered
        h.answered = @effect.Deferred::new()
        ignore(told.succeed(()))
        match h.waiting.get(id.to_int()) {
          Some(d) => {
            h.waiting.remove(id.to_int())
            match prop(m, "threw") {
              Some(said) => ignore(d.fail(Thrown(str_of(prop(m, "kind")).unwrap_or(""), js_text(said))))
              None => ignore(d.succeed(or_null(prop(m, "result"))))
            }
          }
          None => ()
        }
        continue
      }
      _ => ()
    }
    match prop(m, "cb") {
      Some(Num(cb)) => {
        let k = or_null(prop(m, "call"))
        let a = arr_of(prop(m, "args")).unwrap_or([])
        ignore(
          host.rt.fork(async fn() {
            let reply = match h.callbacks.get(cb.to_int()) {
              Some(f) =>
                try {
                  let v = f(a)
                  jobj([("cbDone", k), ("ok", v)])
                } catch {
                  e => Obj([(@jsjson.units("cbDone"), k)] + H::threw(e).map(x => (@jsjson.units(x.0), x.1)))
                }
              None => jobj([("cbDone", k), ("error", jstr("no callback \{cb}")), ("kind", jstr(""))])
            }
            h.say(reply)
          }),
        )
        continue
      }
      _ => ()
    }
    let id = or_null(prop(m, "id"))
    let op = str_of(prop(m, "op")).unwrap_or("")
    let args = arr_of(prop(m, "args")).unwrap_or([])
    ignore(
      host.rt.fork(async fn() {
        let reply = try {
          let v = h.case(op, args)
          jobj([("done", id), ("ok", v)])
        } catch {
          e => Obj([(@jsjson.units("done"), id)] + H::threw(e).map(x => (@jsjson.units(x.0), x.1)))
        }
        h.say(reply)
      }),
    )
  }
}
