// The package's harness (reader `--builder harness-share-sync`): a world of stations, each with its sharing, its memory
// and its chats shared with other workspaces, on a clock of the world's own and over a transport that calls the other
// station directly, driven by a case a line and answered a line each until stdin ends, for station/test/
// mb-share-sync.test.ts to run the same world in the TypeScript it replaces and compare them (their answers, their
// state.json and config.json, their files and their chat_shares rows). A case is `{op, …}`, answered `{ok}` or
// `{error, kind}`.

///|
priv struct VTimer {
  due : Double
  seq : Int
  f : () -> Unit
  mut off : Bool
}

///|
/// The world's clock: what time it is, and the timers due as it is moved on (`advance`).
priv struct VClock {
  mut now : Double
  timers : Array[VTimer]
  mut seq : Int
}

///|
fn VClock::clock(self : VClock) -> Clock {
  {
    now: () => self.now,
    after: (ms, f) => {
      self.seq += 1
      let t = { due: self.now + (if ms > 0.0 { ms } else { 0.0 }), seq: self.seq, f, off: false }
      self.timers.push(t)
      () => t.off = true
    },
  }
}

///|
/// The earliest timer due by `until`, taken off the list.
fn VClock::next_due(self : VClock, until : Double) -> VTimer? {
  let mut best : Int? = None
  for i, t in self.timers {
    if t.off || t.due > until {
      continue
    }
    match best {
      Some(b) => {
        let bt = self.timers[b]
        if t.due < bt.due || (t.due == bt.due && t.seq < bt.seq) {
          best = Some(i)
        }
      }
      None => best = Some(i)
    }
  }
  match best {
    Some(i) => Some(self.timers.remove(i))
    None => None
  }
}

///|
/// A station's config.json as ops/config.ts keeps it: taken at once, written behind it (the latest), listeners told.
priv struct HConfig {
  files : Files
  path : String
  mut value : Json
  listeners : Array[(Int, () -> Unit)]
  mut next : Int
  mut latest : String?
  mut writing : @effect.Deferred[Unit]?
  tasks : Tasks
}

///|
fn HConfig::config(self : HConfig) -> Config {
  {
    raw: () => self.value,
    update_soon: async fn(edit) {
      let next = clone(self.value)
      edit(next)
      self.value = next
      for l in self.listeners.copy() {
        (l.1)()
      }
      self.latest = Some(js_stringify2(next) + "\n")
      if self.writing is None {
        let done : @effect.Deferred[Unit] = @effect.Deferred::new()
        self.writing = Some(done)
        self.tasks.spawn(async fn() {
          defer {
            self.writing = None
            ignore(done.succeed(()))
          }
          while self.latest is Some(t) {
            self.latest = None
            self.files.write_private_text(self.path, t)
          }
        })
      }
      match self.writing {
        Some(d) => d.wait() catch { _ => () }
        None => ()
      }
      next
    },
    listen: f => {
      let id = self.next
      self.next += 1
      self.listeners.push((id, f))
      () => match self.listeners.search_by(l => l.0 == id) {
        Some(i) => ignore(self.listeners.remove(i))
        None => ()
      }
    },
  }
}

///|
priv struct HStation {
  config : HConfig
  mut sharing : Sharing?
  mut memory : MemorySync?
  mut xshare : ChatShares?
  mut store : SqlChatShares?
  mut db_path : String?
  inbox : Array[Json]
  /// What its deps were asked (`lent`: Claude tokens lent; `changed`: copies changed; `resets`, `gone`, `hosted`).
  said : Map[String, Array[Json]]
}

///|
priv struct World {
  host : @host.Host
  rt : @effect.Runtime
  files : Files
  clock : VClock
  stations : Map[String, HStation]
  order : Array[String]
  rosters : Map[String, Array[Json]]
  homes : Map[String, String]
  ws_names : Map[String, String]
  names : Map[String, String]
  machine_emails : Map[String, String]
  down : Set[String]
  listeners : Array[(Int, () -> Unit)]
  mut next : Int
  mut peers_current : Bool
  mut renew_running : Bool
  mut token_url : String
  logs : Array[Json]
}

///|
fn World::home_of(self : World, station : String) -> String {
  self.homes.get(station).unwrap_or("w")
}

///|
fn World::in_roster(self : World, ws : String, station : String) -> Bool {
  match self.rosters.get(ws) {
    Some(peers) => peers.iter().any(p => get(Some(p), "id") is Some(String(x)) && x == station)
    None => false
  }
}

///|
fn World::memberships(self : World, station : String) -> Array[Membership] {
  let home = self.home_of(station)
  let out : Array[Membership] = [
    { workspace: home, workspace_name: self.ws_names.get(home).unwrap_or(home), peers: self.rosters.get(home).unwrap_or([]) },
  ]
  for ws, peers in self.rosters {
    if ws != home && self.in_roster(ws, station) {
      out.push({ workspace: ws, workspace_name: self.ws_names.get(ws).unwrap_or(ws), peers })
    }
  }
  out
}

///|
fn World::cloud(self : World, station : String) -> Cloud {
  {
    has_state: () => true,
    station: () => Some(station),
    name: () => self.names.get(station),
    rig: () => false,
    peers_current: () => self.peers_current,
    memberships: () => self.memberships(station),
    membership: ws => {
      for m in self.memberships(station) {
        if m.workspace == ws {
          return Some(m)
        }
      }
      None
    },
    home: () => Some(self.home_of(station)),
    removed: () => false,
    listen: f => {
      let id = self.next
      self.next += 1
      self.listeners.push((id, f))
      () => match self.listeners.search_by(l => l.0 == id) {
        Some(i) => ignore(self.listeners.remove(i))
        None => ()
      }
    },
  }
}

///|
fn World::station(self : World, id : String) -> HStation raise {
  match self.stations.get(id) {
    Some(s) => s
    None => raise Failed("no station \{id}")
  }
}

///|
fn HStation::note(self : HStation, what : String, v : Json) -> Unit {
  match self.said.get(what) {
    Some(a) => a.push(v)
    None => self.said[what] = [v]
  }
}

///|
/// The transport between the stations of the world (as the TypeScript tests' `ask`, a handler's failure the asker's
/// refusal).
async fn World::share_ask(self : World, from : String, to : String, ws : String?, request : Json) -> Json {
  guard self.stations.get(to) is Some(other) && !self.down.contains(to) && other.sharing is Some(sharing) else {
    raise Failed("peer unavailable")
  }
  let both = (w : String) => self.in_roster(w, from) && self.in_roster(w, to)
  let w = match ws {
    Some(w) => Some(w)
    None =>
      match self.memberships(from).search_by(m => both(m.workspace)) {
        Some(i) => Some(self.memberships(from)[i].workspace)
        None => None
      }
  }
  guard w is Some(at) && both(at) else { raise Failed("peer is not another station in this workspace") }
  let answer = sharing.handle(from, clone(request), workspace=Some(at)) catch {
    e => raise Refused(error_words(e))
  }
  clone(answer)
}

///|
async fn World::memory_ask(self : World, from : String, to : String, ws : String, request : Json) -> Json {
  guard self.stations.get(to) is Some(other) && !self.down.contains(to) && other.memory is Some(memory) else {
    raise Failed("peer unavailable")
  }
  let answer = memory.handle(from, clone(request), Some(ws)) catch { e => raise Refused(error_words(e)) }
  clone(answer)
}

///|
async fn World::xshare_ask(self : World, from : String, to : String, request : Json) -> Json {
  guard self.stations.get(to) is Some(other) && !self.down.contains(to) && other.xshare is Some(theirs) else {
    raise Failed("peer unavailable")
  }
  let mine = self.station(from).xshare.unwrap()
  let own = self.home_of(from)
  let workspace = match get(Some(request), "workspace") {
    Some(String(w)) => w
    _ => own
  }
  if workspace == own {
    if !self.in_roster(own, to) || self.home_of(to) != own {
      raise Failed("peer is not another station in this workspace")
    }
    return clone(theirs.inside(from, clone(request)))
  }
  if !mine.reaches(to, workspace) {
    raise Failed("that station is of another workspace that shares no chat with this one")
  }
  if self.home_of(to) != workspace {
    raise Failed("station is outside this workspace")
  }
  let answer = theirs.outside(from, clone(request)) catch { e => raise Refused(error_words(e)) }
  clone(answer)
}

///|
fn World::log(self : World) -> Log {
  { say: (level, what, words, fields) => self.logs.push(jobj([("level", jstr(level)), ("part", jstr(what)), ("msg", jstr(words)), ("fields", fields)])) }
}

///|
/// A station of the world made: its config read from its data, its parts made on the world's clock.
async fn World::add(self : World, c : Json) -> Unit {
  let id = js_string(get(Some(c), "id"))
  let data = js_string(get(Some(c), "data"))
  let agent_home = js_string(get(Some(c), "agentHome"))
  let log = self.log()
  let tasks = Tasks::new(self.rt, log, "config")
  let path = self.files.join([data, "config.json"])
  let value = match self.files.read_text(path) {
    Some(t) => js_parse(t)
    None => jobj([])
  }
  let config : HConfig = { files: self.files, path, value, listeners: [], next: 0, latest: None, writing: None, tasks }
  let st : HStation = {
    config,
    sharing: None,
    memory: None,
    xshare: None,
    store: None,
    db_path: None,
    inbox: [],
    said: Map([]),
  }
  self.stations[id] = st
  self.order.push(id)
  let clock = self.clock.clock()
  let sharing = Sharing::new(
    {
      data,
      config: config.config(),
      cloud: self.cloud(id),
      ask: (to, ws, request) => self.share_ask(id, to, ws, request),
      agent_home: () => agent_home,
      codex_auth_file: () => self.files.join([data, "machine", "codex", "auth.json"]),
      machine_email: Some(runtime => self.machine_emails.get("\{id}/\{runtime}")),
      claude_token: async fn(p, _rejected) {
        st.note("lent", get(Some(p), "id").unwrap_or(jnull()))
        ("token-of-\{js_string(get(Some(p), "id"))}", self.clock.now + 7200000.0)
      },
      codex_renew_running: async fn(_) { self.renew_running },
      agy_renew: None,
      status: async fn(pid) {
        jobj([
          ("check", jobj([("state", jstr("ok")), ("detail", jstr("checked \{pid}")), ("models", jnull()), ("checkedAt", jnum(1.0))])),
          ("quota", jnull()),
        ])
      },
      changed: () => (),
      recheck: None,
      profile_changed: Some(async fn(pid, reset) { st.note("changed", jarr([jstr(pid), jbool(reset)])) }),
      quota_reset: Some(async fn(pid) { st.note("resets", jstr(pid)) }),
      profile_gone: Some(async fn(pid) { st.note("gone", jstr(pid)) }),
      itself: None,
      codex_token_url: self.token_url,
      fetch: async fn(url, body) {
        let r = self.host.fetch(
          url,
          method_="POST",
          headers=[("content-type", "application/json")],
          body=@utf8.encode(body),
        )
        (r.status, r.text())
      },
      account_email: async fn(_, _) { None },
      lang: () => "zh",
      random_hex: async fn(n) {
        match self.host.shell_sync("crypto.random", jobj([("bytes", jnum(n.to_double()))])) {
          String(h) => h
          _ => raise Failed("no random bytes")
        }
      },
      watching: Watching::none(),
      clock,
      log,
      files: self.files,
    },
    self.rt,
  )
  sharing.load()
  sharing.set_on_hosted(Some((share, peer) => st.note("hosted", jarr([jstr(share), jstr(peer)]))))
  st.sharing = Some(sharing)
  // (a joined workspace's agent home made as the station makes it: its own skills from `skillsSource`)
  let skills_source = js_string(get(Some(c), "skillsSource"))
  let storage = @session_storage.Storage::new(
    @session_storage.Station::new(async fn(_, _) { jnull() }),
    @session_storage.Files::new(self.host),
  )
  let memory = MemorySync::new(
    {
      data,
      cloud: self.cloud(id),
      ask: (to, ws, request) => self.memory_ask(id, to, ws, request),
      agent_home: () => agent_home,
      workspace_agent_home: (a, ws, home) => storage.workspace_agent_home(a, ws, home, skills_source, None),
      still: true,
      watching: Watching::none(),
      clock,
      log,
      files: self.files,
    },
    self.rt,
  )
  st.memory = Some(memory)
  if get(Some(c), "db") is Some(String(db_path)) {
    let db = @sql.Db::attach(self.host, db_path, wait=5000)
    let store = SqlChatShares::new(db, () => self.clock.now)
    st.store = Some(store)
    st.db_path = Some(db_path)
    let xshare = ChatShares::new(
      {
        data,
        store: store.store(),
        cloud: self.cloud(id),
        chat_ws: None,
        ask: (to, request) => self.xshare_ask(id, to, request),
        link: chat => Some("https://app.still.fail/o/\{self.home_of(id)}/\{id}/\{chat}"),
        title: chat => "title of \{chat}",
        touches: request => {
          let c = match gets(Some(request), ["args", "chat"]) {
            None | Some(Null) =>
              match get(Some(request), "chat") {
                None | Some(Null) => get(Some(request), "to")
                v => v
              }
            v => v
          }
          match c {
            Some(String(s)) => [s]
            _ => []
          }
        },
        inbox: async fn(peer, request) {
          st.inbox.push(jobj([("peer", jstr(peer)), ("request", request)]))
          jobj([("ok", jbool(true))])
        },
        prepare_index: None,
        clock,
        log,
        files: self.files,
      },
      self.rt,
    )
    xshare.load()
    st.xshare = Some(xshare)
  }
}

///|
fn World::busy(self : World) -> Int {
  let mut n = 0
  for _, s in self.stations {
    n += s.config.tasks.busy
    if s.sharing is Some(x) {
      n += x.busy()
    }
    if s.memory is Some(x) {
      n += x.busy()
    }
    if s.xshare is Some(x) {
      n += x.busy()
    }
  }
  n
}

///|
/// Until nothing set going is still going.
async fn World::idle(self : World) -> Unit {
  // (a wait of the machine's: what is going waits on the shell, which answers between the runtime's turns)
  while self.busy() > 0 {
    @effect.sleep(1)
  }
}

///|
/// Each station's shares brought in line four times over (as the TypeScript tests' `settle`), then nothing going.
async fn World::settle(self : World, only : Array[String]) -> Unit {
  let which = if only.is_empty() { self.order.copy() } else { only }
  for _ in 0..<4 {
    @effect.pause()
    let all : Array[async () -> Unit] = []
    for id in which {
      let s = self.station(id)
      if s.sharing is Some(x) {
        all.push(async fn() { x.reconcile() })
      }
      if s.xshare is Some(x) {
        all.push(async fn() { x.reconcile() })
      }
    }
    ignore(@effect.all(all))
  }
  self.idle()
  for id in which {
    let s = self.station(id)
    if s.sharing is Some(x) {
      x.state_written()
    }
    if s.xshare is Some(x) {
      x.written()
    }
    if s.memory is Some(x) {
      x.written()
    }
  }
}

///|
/// The world's clock moved on by `ms`, each timer due fired in its turn, what it set going done before the next.
async fn World::advance(self : World, ms : Double) -> Unit {
  let until = self.clock.now + ms
  while self.clock.next_due(until) is Some(t) {
    if t.due > self.clock.now {
      self.clock.now = t.due
    }
    (t.f)()
    self.idle()
  }
  self.clock.now = until
}

///|
fn arg(args : Array[Json], i : Int) -> Json? {
  match args.get(i) {
    None | Some(Null) => None
    v => v
  }
}

///|
fn arg_str(args : Array[Json], i : Int) -> String? {
  str_of(arg(args, i))
}

///|
fn need_str(args : Array[Json], i : Int) -> String raise {
  match arg_str(args, i) {
    Some(s) => s
    None => raise Failed("argument \{i} is no string")
  }
}

///|
fn str_array(v : Json?) -> Array[String] {
  match v {
    Some(Array(a)) => str_list(a)
    _ => []
  }
}

///|
fn HStation::profile(self : HStation, id : String) -> Json raise {
  match get(Some((self.config.config().raw)()), "profiles") {
    Some(Array(a)) =>
      match a.search_by(p => id_is(p, id)) {
        Some(i) => a[i]
        None => raise Failed("no profile \{id}")
      }
    _ => raise Failed("no profile \{id}")
  }
}

///|
async fn World::call_share(self : World, st : HStation, asked : String, args : Array[Json]) -> Json {
  ignore(self)
  let s = st.sharing.unwrap()
  match asked {
    "shareProfile" => {
      s.share_profile(
        need_str(args, 0),
        arg(args, 1) is Some(True),
        arg(args, 2).unwrap_or(jnull()),
        among=match arg(args, 3) {
          Some(Array(a)) => Some(str_list(a))
          _ => None
        },
        by=arg_str(args, 4),
      )
      jnull()
    }
    "shareSkill" => {
      s.share_skill(need_str(args, 0), arg(args, 1) is Some(True), arg(args, 2).unwrap_or(jnull()))
      jnull()
    }
    "moveProfile" => {
      let first = if arg(args, 3) is Some(True) {
        Some(async fn(share : String) { st.note("shareFirst", jstr(share)) })
      } else {
        None
      }
      let (id, share) = s.move_profile(need_str(args, 0), need_str(args, 1), lang=arg_str(args, 2), share_first=first)
      match share {
        Some(sh) => jobj([("id", jstr(id)), ("share", jstr(sh))])
        None => jobj([("id", jstr(id))])
      }
    }
    "lendTo" => {
      let (share, made, widened) = s.lend_to(need_str(args, 0), need_str(args, 1))
      jobj([("share", jstr(share)), ("made", jbool(made)), ("widened", jbool(widened))])
    }
    "unlend" => {
      s.unlend(need_str(args, 0), need_str(args, 1), arg(args, 2) is Some(True), arg(args, 3) is Some(True))
      jnull()
    }
    "unshareMoved" => jbool(s.unshare_moved(need_str(args, 0), str_array(arg(args, 1))))
    "lendClaude" => {
      let (token, at) = s.lend_claude(st.profile(need_str(args, 0)), rejected=arg_str(args, 1))
      jobj([("token", jstr(token)), ("expiresAt", jnum(at))])
    }
    "lendCodex" => jnum(s.lend_codex(st.profile(need_str(args, 0)), rejected=arg(args, 1) is Some(True)))
    "lendAgy" => jnum(s.lend_agy(st.profile(need_str(args, 0)), rejected=arg(args, 1) is Some(True)))
    "status" => s.status(st.profile(need_str(args, 0)))
    "loginUpdated" => {
      s.login_updated(profile_id=arg_str(args, 0))
      jnull()
    }
    "quotaReset" => {
      s.quota_reset(need_str(args, 0), need_str(args, 1))
      jnull()
    }
    "profileView" => s.profile_view(st.profile(need_str(args, 0)), workspace=arg_str(args, 1)).unwrap_or(jnull())
    "skillView" => s.skill_view(need_str(args, 0)).unwrap_or(jnull())
    "borrowedSubscription" => jbool(s.borrowed_subscription(st.profile(need_str(args, 0))))
    "handle" => s.handle(need_str(args, 0), arg(args, 1).unwrap_or(jnull()), workspace=arg_str(args, 2))
    "reconcile" => {
      s.reconcile()
      jnull()
    }
    "renewedBehind" => {
      s.renewed_behind(need_str(args, 0))
      jnull()
    }
    "trimIdle" => jnum(s.trim_idle().to_double())
    _ => raise Failed("no share method \{asked}")
  }
}

///|
async fn World::call_memory(self : World, st : HStation, asked : String, args : Array[Json]) -> Json {
  ignore(self)
  let m = st.memory.unwrap()
  match asked {
    "levelNow" => {
      m.level_now()
      jnull()
    }
    "handle" => m.handle(need_str(args, 0), arg(args, 1).unwrap_or(jnull()), arg_str(args, 2))
    "kept" => m.kept_json(need_str(args, 0)).unwrap_or(jnull())
    _ => raise Failed("no memory method \{asked}")
  }
}

///|
async fn World::call_xshare(self : World, st : HStation, asked : String, args : Array[Json]) -> Json {
  let x = st.xshare.unwrap()
  match asked {
    "share" =>
      x
      .share(need_str(args, 0), match arg(args, 1) { Some(Array(a)) => a; _ => [] }, arg(args, 2) is Some(True), need_str(args, 3))
      .unwrap_or(jnull())
    "trust" => {
      x.trust(need_str(args, 0), need_str(args, 1), need_str(args, 2), need_str(args, 3), as_=arg_str(args, 4))
      jnull()
    }
    "borrowed" => jarr(x.borrowed(as_=arg_str(args, 0)))
    "inside" => x.inside(need_str(args, 0), arg(args, 1).unwrap_or(jnull()), workspace=arg_str(args, 2))
    "outside" => x.outside(need_str(args, 0), arg(args, 1).unwrap_or(jnull()), workspace=arg_str(args, 2))
    "address" => x.address(need_str(args, 0), arg(args, 1).unwrap_or(jnull()))
    "reaches" => jbool(x.reaches(need_str(args, 0), need_str(args, 1)))
    "workspaceOf" =>
      match
        x.workspace_of(
          need_str(args, 0),
          as_=match args.get(1) {
            None => None
            Some(Null) => Some(None)
            Some(v) => Some(str_of(Some(v)))
          },
        ) {
        Some(w) => jstr(w)
        None => jnull()
      }
    "send" => {
      let fail = arg(args, 2) is Some(True)
      x.send(need_str(args, 0), arg(args, 1).unwrap_or(jnull()), async fn(addressed) {
        st.note("sent", addressed)
        if fail {
          raise Failed("not taken")
        }
        jobj([("sent", addressed)])
      })
    }
    "start" => {
      x.start()
      jnull()
    }
    "reconcile" => {
      x.reconcile()
      jnull()
    }
    "indexBuild" => {
      // (the deadlines' lookup prepared as the station prepares it once the one before let go)
      let store = st.store.unwrap()
      let previous : @effect.Deferred[Bool] = @effect.Deferred::new()
      ignore(previous.succeed(true))
      let path = st.db_path.unwrap()
      let builder = ChatShareIndexBuilder::new(store, () => Some(@sql.Db::attach(self.host, path, wait=5000)), previous, self.rt, self.log())
      builder.request()
      builder.settled()
      let answer = jarr([jbool(store.has_index()), jbool(store.index_ready())])
      builder.close()
      answer
    }
    "chatShares" => {
      let store = st.store.unwrap().store()
      jarr((store.chat_shares)().map(s => jarr([jstr(s.0), s.1])))
    }
    "sessionRemoved" => {
      ignore(self)
      let store = st.store.unwrap()
      store.tell([jobj([("type", jstr("sessionRemoved")), ("key", jstr(need_str(args, 0)))])])
      jnull()
    }
    _ => raise Failed("no xshare method \{asked}")
  }
}

///|
/// A station's state as the test compares it.
fn World::snapshot(self : World, id : String) -> Json raise {
  let st = self.station(id)
  let said : Map[String, Json] = Map([])
  for k, v in st.said {
    said[k] = jarr(v)
  }
  let memory : Map[String, Json] = Map([])
  if st.memory is Some(m) {
    for ms in self.memberships(id) {
      if m.kept_json(ms.workspace) is Some(k) {
        memory[ms.workspace] = k
      }
    }
  }
  jobj([
    ("config", (st.config.config().raw)()),
    ("share", match st.sharing { Some(s) => s.state_json(); None => jnull() }),
    ("xshare", match st.xshare { Some(x) => x.state_json(); None => jnull() }),
    ("memory", Json::object(memory)),
    ("inbox", jarr(st.inbox)),
    ("said", Json::object(said)),
  ])
}

///|
async fn World::case(self : World, op : String, c : Json) -> Json {
  let cj = Some(c)
  match op {
    "station" => {
      self.add(c)
      jnull()
    }
    "cloud" => {
      if get(cj, "rosters") is Some(Object(r)) {
        self.rosters.clear()
        for ws in js_keys(r) {
          self.rosters[ws] = match r[ws] {
            Array(a) => a
            _ => []
          }
        }
      }
      if get(cj, "homes") is Some(Object(h)) {
        for k in js_keys(h) {
          self.homes[k] = js_string(Some(h[k]))
        }
      }
      if get(cj, "wsNames") is Some(Object(h)) {
        for k in js_keys(h) {
          self.ws_names[k] = js_string(Some(h[k]))
        }
      }
      if get(cj, "names") is Some(Object(h)) {
        for k in js_keys(h) {
          self.names[k] = js_string(Some(h[k]))
        }
      }
      if get(cj, "peersCurrent") is Some(True | False as b) {
        self.peers_current = b is True
      }
      if get(cj, "tell") is Some(True) {
        for l in self.listeners.copy() {
          (l.1)()
        }
        self.idle()
      }
      jnull()
    }
    "set" => {
      if get(cj, "renewRunning") is Some(True | False as b) {
        self.renew_running = b is True
      }
      if get(cj, "tokenUrl") is Some(String(u)) {
        self.token_url = u
      }
      if get(cj, "machineEmail") is Some(Object(m)) {
        for k in js_keys(m) {
          match m[k] {
            String(e) => self.machine_emails[k] = e
            _ => self.machine_emails.remove(k)
          }
        }
      }
      jnull()
    }
    "now" => {
      self.clock.now = num_or0(get(cj, "at"))
      jnull()
    }
    "down" => {
      self.down.add(js_string(get(cj, "station")))
      jnull()
    }
    "up" => {
      self.down.remove(js_string(get(cj, "station")))
      jnull()
    }
    "call" => {
      let st = self.station(js_string(get(cj, "station")))
      let asked = js_string(get(cj, "method"))
      let args = match get(cj, "args") {
        Some(Array(a)) => a
        _ => []
      }
      let answer = match get(cj, "part") {
        Some(String("share")) => self.call_share(st, asked, args)
        Some(String("memory")) => self.call_memory(st, asked, args)
        Some(String("xshare")) => self.call_xshare(st, asked, args)
        _ => raise Failed("no such part")
      }
      self.idle()
      answer
    }
    "settle" => {
      self.settle(str_array(get(cj, "stations")))
      jnull()
    }
    "advance" => {
      self.advance(num_or0(get(cj, "ms")))
      jnull()
    }
    "snapshot" => self.snapshot(js_string(get(cj, "station")))
    "logs" => jarr(self.logs)
    "close" => {
      for id in self.order {
        let st = self.station(id)
        if st.sharing is Some(s) {
          s.close()
        }
        if st.memory is Some(m) {
          m.stop()
        }
        if st.xshare is Some(x) {
          x.close()
        }
      }
      self.idle()
      jnull()
    }
    "pure" => pure_case(c)
    _ => raise Failed("no op \{op}")
  }
}

///|
/// The package's pure functions on the TypeScript's own inputs.
fn pure_case(c : Json) -> Json raise {
  let cj = Some(c)
  let v = get(cj, "value").unwrap_or(jnull())
  match js_string(get(cj, "fn")) {
    "signInFiles" => jstrs(sign_in_files(v, "/"))
    "portable" => portable(v)
    "shareRefusal" =>
      match share_refusal(v) {
        Some(r) => jstr(r)
        None => jnull()
      }
    "allowedIn" => jbool(allowed_in(v, str_of(get(cj, "ws")), str_of(get(cj, "home"))))
    "memoryPath" => jbool(memory_path(Some(v)))
    "recOf" => rec_of_peer(Some(v)).unwrap_or(jnull())
    "memoryFollowed" => jbool(memory_followed(js_string(Some(v))))
    "asideSkill" =>
      jstr(@utf8.decode_lossy(aside_skill(@utf8.encode(js_string(Some(v))), js_string(get(cj, "name")), js_string(get(cj, "station")))))
    "linkParts" =>
      match link_parts(js_string(Some(v))) {
        Some((w, s, chat)) => jobj([("workspace", jstr(w)), ("station", jstr(s)), ("chat", jstr(chat))])
        None => jnull()
      }
    "jwtExpiry" =>
      match jwt_expiry(Some(v)) {
        Some(d) => jnum(d)
        None => jnull()
      }
    "agyExpiryIn" => jnum(agy_expiry_in(js_string(Some(v))))
    "agyLentFile" => jstr(agy_lent_file(v))
    "isoString" => jstr(iso_string(js_num(Some(v))))
    "stringify" => jstr(js_stringify(v))
    "stringify2" => jstr(js_stringify2(v))
    "toChatShare" =>
      match v {
        Object(m) => to_chat_share(m)
        _ => jnull()
      }
    other => raise Failed("no fn \{other}")
  }
}

///|
/// The program's harness: a case a line, answered a line each, until stdin ends.
pub async fn harness(host : @host.Host) -> Unit {
  let world : World = {
    host,
    rt: host.rt,
    files: { host, sep: "/" },
    clock: { now: 0.0, timers: [], seq: 0 },
    stations: Map([]),
    order: [],
    rosters: Map([]),
    homes: Map([]),
    ws_names: Map([]),
    names: Map([]),
    machine_emails: Map([]),
    down: Set::new(),
    listeners: [],
    next: 0,
    peers_current: true,
    renew_running: false,
    token_url: codex_token_url,
    logs: [],
  }
  while host.line() is Some(line) {
    if line == "" {
      continue
    }
    let answer = try {
      let c = js_parse(line)
      let op = js_string(get(Some(c), "op"))
      jobj([("ok", world.case(op, c))])
    } catch {
      e => {
        let kind = match e {
          Refused(_) => "refused"
          Said(_) => "said"
          _ => "error"
        }
        jobj([("error", jstr(error_words(e))), ("kind", jstr(kind))])
      }
    }
    host.say(js_stringify(answer))
  }
}
