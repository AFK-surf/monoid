// The cases the harness takes (harness.mbt says the lines): each by its `op`, as the test names the TypeScript it holds
// the program to.

///|
fn sa(v : J?) -> String {
  match v {
    Some(Str(u)) => @jsjson.sanitize_str(u)
    Some(Null) | None => ""
    other => js_text(other)
  }
}

///|
fn so(v : J?) -> String? {
  match v {
    Some(Str(u)) => Some(@jsjson.sanitize_str(u))
    _ => None
  }
}

///|
fn na(v : J?) -> Double {
  num_of(v).unwrap_or(0.0)
}

///|
fn ia(v : J?) -> Int {
  num_of(v).unwrap_or(0.0).to_int()
}

///|
fn args_of(m : J?) -> Array[J] {
  arr_of(at(m, "args")).unwrap_or([])
}

///|
fn opt_j(v : String?) -> J {
  jopt(v)
}

///|
/// What a stale test says (`{olderThan}`, `{noPicture}`, `{nameNot}`), as the test's TypeScript says it too.
fn stale_of(v : J?) -> (J, Double) -> Bool {
  match v {
    Some(Obj(_)) as s =>
      match (at(s, "olderThan"), at(s, "noPicture"), at(s, "nameNot")) {
        (Some(Num(ms)), _, _) => (_, age) => age > ms
        (_, Some(Bool(true)), _) => (known, _) => at(Some(known), "picture") is None
        (_, _, Some(Str(u))) => (known, _) => !(str_of(at(Some(known), "name")) == Some(@jsjson.sanitize_str(u)))
        _ => (_, _) => false
      }
    _ => (_, _) => false
  }
}

///|
fn answer_j(a : Answer) -> J {
  jo([("json", a.json), ("bytes", match a.bytes { Some(b) => js(hex(b)); None => Null })])
}

///|
fn body_j(b : Body) -> J {
  match b {
    NoBody => Null
    FileBody(path, offset, size) => jo([("file", js(path)), ("offset", jn(offset)), ("size", jn(size))])
    DataBody(bytes) => jo([("hex", js(hex(bytes)))])
  }
}

///|
fn Harness::asker(self : Harness) -> Asker {
  {
    ask: async fn(station, request, body) {
      let got = self.ask("bus.ask", [js(station), request, body_j(body)])
      { json: at(Some(got), "json").unwrap_or(Null), bytes: match at(Some(got), "bytes") { Some(Str(u)) => Some(unhex(@jsjson.sanitize_str(u))); _ => None } }
    },
  }
}

///|
fn Harness::book(self : Harness, v : J?) -> NameBook? {
  match v {
    Some(Num(n)) => self.books.get(n.to_int())
    _ => None
  }
}

///|
fn Harness::cards(self : Harness) -> Cards {
  {
    get_thread: async fn(id) { self.ask("store.getThread", [jn(id)]) },
    thread_sessions: async fn(id) { arr_of(Some(self.ask("store.threadSessions", [jn(id)]))).unwrap_or([]) },
    card_ended_by_message: async fn(id, n) { self.ask("store.cardEndedByMessage", [jn(id), jn(n)]) },
    card_replaced_by: async fn(id, n) { self.ask("store.cardReplacedBy", [jn(id), jn(n)]) },
    closed_card: async fn(id, n) { self.ask("store.closedCard", [jn(id), jn(n)]) },
  }
}

///|
/// A generic platform's connects for the tests (the TypeScript twin is the test's): its connects config.json's of its
/// kind, what each connects with its `token`, its connection the test's, what it is known by its `botName`.
fn Harness::platform(self : Harness, kind : String) -> Platform {
  {
    kind,
    names: names_file(kind).unwrap_or("\{kind}-names.json"),
    connects: raw => arr_of(at(Some(raw), "connects")).unwrap_or([]).filter(c => (match at(Some(c), "kind") { Some(Null) | None => "slack"; k => js_text(k) }) == kind),
    credentials: c => so(at(Some(c), "token")),
    create: async fn(c, _) {
      let got = self.ask("conn.create", [js(kind), c])
      self.fake_conn(ia(Some(got)))
    },
    seen: (c, i) => if @session_chats.jeq(at(Some(c), "botName").unwrap_or(Null), at(Some(i), "botName").unwrap_or(Null)) {
      None
    } else {
      let name = at(Some(i), "botName").unwrap_or(Null)
      Some(entry => set_field(entry, "botName", name))
    },
  }
}

///|
fn Harness::connects_options(self : Harness, data : String) -> ConnectsOptions {
  {
    data,
    store: { live_sessions: () => self.live, notify: key => self.note("store.notify", [js(key)]) },
    config: self.config(),
    receive: async fn(connect, event) { ignore(self.ask("hub.receive", [js(connect), event])) },
    bound: () => self.bound,
    in_workspace: Some(ws => match ws { None => true; Some(w) => self.workspaces.contains(w) }),
    fs: self.fs(),
    clock: self.clock(),
    log: self.log(),
  }
}

///|
fn Harness::stations_of(self : Harness, ws : String) -> Array[J] {
  arr_of(at(Some(self.stations), ws)).unwrap_or([])
}

///|
fn Harness::workspace_deps(self : Harness, data : String, made : Ref[WorkspaceConnects?]) -> WorkspaceDeps {
  let unit = async fn(name : String, args : Array[J]) { ignore(self.ask(name, args)) }
  {
    data,
    hub: {
      chat_of: async fn(id) {
        let got = self.ask("hub.chatOf", [js(id)])
        match got {
          Null => None
          g if at(Some(g), "remote") is Some(Bool(true)) =>
            match made.val {
              Some(w) => w.remote.surface(id).map(r => r.surface())
              None => None
            }
          g => Some(self.chat_surface(id, g))
        }
      },
      config_connects: async fn() { arr_of(Some(self.ask("hub.configConnects", []))).unwrap_or([]) },
      receive: async fn(id, event) { unit("hub.receive", [js(id), event]) },
      moved_to: async fn(id, channel, ts) { so(Some(self.ask("hub.movedTo", [js(id), js(channel), js(ts)]))) },
      quiet_in: async fn(ws) { self.ask("hub.quietIn", [js(ws)]) is Bool(true) },
      surface: async fn(id) { sa(Some(self.ask("hub.surface", [js(id)]))) },
      told_bots: async fn(peer, bots) { unit("hub.toldBots", [js(peer), jsa(bots)]) },
    },
    store: {
      drop_connect_thread_station: async fn(id, c, t) { unit("store.dropConnectThreadStation", [js(id), js(c), js(t)]) },
      set_connect_thread_station: async fn(id, c, t, s) { unit("store.setConnectThreadStation", [js(id), js(c), js(t), js(s)]) },
      connect_thread_station: async fn(id, c, t) { so(Some(self.ask("store.connectThreadStation", [js(id), js(c), js(t)]))) },
      drop_connect_threads: async fn(id) { unit("store.dropConnectThreads", [js(id)]) },
      connect_threads: async fn(id) { arr_of(Some(self.ask("store.connectThreads", [js(id)]))).unwrap_or([]) },
      connect_local_threads: async fn(id) { arr_of(Some(self.ask("store.connectLocalThreads", [js(id)]))).unwrap_or([]) },
      thread_at: async fn(s, c, t) { self.ask("store.threadAt", [js(s), js(c), js(t)]) },
    },
    config: self.config(),
    here: () => self.here,
    home: () => self.home,
    stations: ws => self.stations_of(ws),
    bus: {
      ask: self.asker().ask,
      on: (name, f) => self.handlers[name] = f,
      heard: Some(f => self.heard.push(f)),
    },
    names: kind => match self.kind_books.get(kind) { Some(b) => self.books.get(b); None => None },
    fs: self.fs(),
    log: self.log(),
    speech: self.speech(),
    uuid: () => self.uuid(),
  }
}

///|
fn Harness::group_options(self : Harness, h : Int, m : J?, threads : GroupThreads) -> GroupSurfaceOptions {
  let strs = (k : String) => arr_of(at(m, k)).unwrap_or([]).map(x => js_text(Some(x)))
  {
    connect: sa(at(m, "connect")),
    server: sa(at(m, "server")),
    relays: strs("relays"),
    ips: strs("ips"),
    key: sa(at(m, "key")),
    code: so(at(m, "code")),
    bot_name: so(at(m, "botName")),
    threads,
    book: self.book(at(m, "book")),
    endpoints: self.endpoints(),
    clock: self.clock(),
    ping_ms: num_of(at(m, "pingMs")),
    stale_ms: num_of(at(m, "staleMs")),
    backoff_ms: num_of(at(m, "backoffMs")),
    on_heard: () => self.note("gsurf.heard", [ji(h)]),
    log: self.log(),
    fs: self.fs(),
    speech: self.speech(),
    uuid: () => self.uuid(),
    signer: self.signer(),
  }
}

///|
/// One case.
async fn Harness::op(self : Harness, msg : J) -> J {
  let m = Some(msg)
  let h = ia(at(m, "h"))
  let args = args_of(m)
  let arg = (i : Int) => args.get(i).unwrap_or(Null)
  let s = (i : Int) => sa(args.get(i))
  match sa(at(m, "op")) {
    "env" => {
      match at(m, "here") {
        Some(Str(u)) => self.here = @jsjson.sanitize_str(u)
        _ => ()
      }
      match at(m, "home") {
        Some(Str(u)) => self.home = Some(@jsjson.sanitize_str(u))
        Some(Null) => self.home = None
        _ => ()
      }
      match at(m, "stations") {
        Some(v) => self.stations = v
        None => ()
      }
      match at(m, "bound") {
        Some(Bool(b)) => self.bound = b
        _ => ()
      }
      match at(m, "workspaces") {
        Some(Arr(ws)) => self.workspaces = ws.map(x => js_text(Some(x)))
        _ => ()
      }
      match at(m, "live") {
        Some(Arr(ls)) => self.live = ls.map(x => js_text(Some(x)))
        _ => ()
      }
      match at(m, "lang") {
        Some(Str(u)) => self.lang.val = @jsjson.sanitize_str(u)
        _ => ()
      }
      match at(m, "words") {
        Some(w) => self.words = @session_chats.Words::new(at(Some(w), "zh").unwrap_or(jo([])), at(Some(w), "en").unwrap_or(jo([])), product=sa(at(Some(w), "product")))
        None => ()
      }
      match at(m, "raw") {
        Some(v) => self.raw = v
        None => ()
      }
      Null
    }
    "settle" => {
      for _ in 0..<10000 {
        @effect.pause()
        if @effect.runtime().holding().1 == 0 {
          break
        }
      }
      Null
    }
    "config.set" => {
      self.raw = at(m, "raw").unwrap_or(jo([]))
      self.config_listeners.tell()
      Null
    }
    "config.raw" => self.raw
    "fn" => self.pure(sa(at(m, "name")), args)
    // ── status lines ──
    "status.new" => {
      let id = self.handle()
      let line = StatusLine::new(f => spawn(f), self.clock(), na(at(m, "interval")), async fn(l, status, now) {
        self.ask("status.show", [ji(id), js(status), jn(now), opt_j(l.message_ts), opt_j(l.page)]) is Bool(true)
      })
      self.lines[id] = line
      ji(id)
    }
    "status.say" => {
      guard self.lines.get(h) is Some(line) else { raise fail_("no line") }
      line.say(sa(at(m, "status")), message_ts=so(at(m, "messageTs")), page=so(at(m, "page")))
      Null
    }
    // ── the names book ──
    "names.open" => {
      let options = { save_after_ms: num_of(at(m, "saveAfterMs")).unwrap_or(2000.0), learn_after_ms: num_of(at(m, "learnAfterMs")).unwrap_or(200.0) }
      let book = NameBook::open(sa(at(m, "path")), self.fs(), self.clock(), self.log(), options~)
      let id = self.handle()
      self.books[id] = book
      ji(id)
    }
    "names.person" => {
      guard self.books.get(h) is Some(book) else { raise fail_("no book") }
      let key = sa(at(m, "key"))
      book.person(key, async fn() { match self.ask("names.fetch", [ji(h), js(key)]) { Null => None; p => Some(p) } }, stale=stale_of(at(m, "stale"))).unwrap_or(Null)
    }
    "names.channel" => {
      guard self.books.get(h) is Some(book) else { raise fail_("no book") }
      let key = sa(at(m, "key"))
      book.channel(key, async fn() { self.ask("names.fetchChannel", [ji(h), js(key)]) })
    }
    "names.onLearn" => {
      guard self.books.get(h) is Some(book) else { raise fail_("no book") }
      book.on_learn(() => self.note("names.learned", [ji(h)]))
      Null
    }
    "names.close" => {
      guard self.books.get(h) is Some(book) else { raise fail_("no book") }
      book.close()
      Null
    }
    // ── a platform's connections ──
    "connections.new" => {
      let kind = sa(at(m, "kind"))
      let id = self.handle()
      let c = Connections::new(
        kind,
        async fn(connect) { self.fake_conn(ia(Some(self.ask("conn.create", [js(kind), connect])))) },
        async fn(connect, event) { ignore(self.ask("connections.event", [ji(id), js(connect), event])) },
        c => so(at(Some(c), "token")),
        self.log(),
      )
      self.connections[id] = c
      ji(id)
    }
    "connections.reconcile" => {
      guard self.connections.get(h) is Some(c) else { raise fail_("no connections") }
      c.reconcile(arr_of(at(m, "connects")).unwrap_or([]))
      Null
    }
    "connections.stopAll" => {
      guard self.connections.get(h) is Some(c) else { raise fail_("no connections") }
      c.stop_all()
      Null
    }
    "connections.state" => {
      guard self.connections.get(h) is Some(c) else { raise fail_("no connections") }
      c.state(at(m, "connect").unwrap_or(Null))
    }
    "connections.refreshIdentity" => {
      guard self.connections.get(h) is Some(c) else { raise fail_("no connections") }
      c.refresh_identity(sa(at(m, "who")))
      Null
    }
    "connections.ids" => {
      guard self.connections.get(h) is Some(c) else { raise fail_("no connections") }
      jsa(c.ids())
    }
    "connections.onChange" => {
      guard self.connections.get(h) is Some(c) else { raise fail_("no connections") }
      ignore(c.on_change(() => self.note("connections.changed", [ji(h)])))
      Null
    }
    "conn.set" => {
      guard self.conns.get(ia(at(m, "c"))) is Some(c) else { raise fail_("no conn") }
      match at(m, "botUserId") {
        Some(Str(u)) => c.bot_user_id = @jsjson.sanitize_str(u)
        _ => ()
      }
      match at(m, "socket") {
        Some(v) => c.socket = v
        None => ()
      }
      match at(m, "identity") {
        Some(v) => c.identity = v
        None => ()
      }
      Null
    }
    "conn.changed" => {
      guard self.conns.get(ia(at(m, "c"))) is Some(c) else { raise fail_("no conn") }
      c.listeners.tell()
      Null
    }
    "conn.event" => {
      guard self.conns.get(ia(at(m, "c"))) is Some(c) && c.handler is Some(handler) else { raise fail_("no conn") }
      handler(at(m, "event").unwrap_or(Null))
      Null
    }
    // ── a platform's connects ──
    "connects.make" => {
      let kind = sa(at(m, "kind"))
      let c = make_connects(self.connects_options(sa(at(m, "data"))), self.platform(kind))
      let id = self.handle()
      self.connects[id] = c
      self.books[id + 100000] = c.names
      ji(id)
    }
    "connects.call" => {
      guard self.connects.get(h) is Some(c) else { raise fail_("no connects") }
      match sa(at(m, "name")) {
        "reconcile" => c.reconcile()
        "stopAll" => c.stop_all()
        "close" => c.close()
        "refreshIdentity" => c.refresh_identity(s(0))
        "state" => return c.state(arg(0)).unwrap_or(Null)
        "connects" => return ja(c.connects())
        "chat" => return jb(c.chat(s(0)) is Some(_))
        "onChange" => ignore(c.on_change(() => self.note("connects.changed", [ji(h)])))
        "tell" => c.tell()
        n => raise fail_("no such call \{n}")
      }
      Null
    }
    // ── the part ──
    "part.make" => {
      guard self.connects.get(h) is Some(c) else { raise fail_("no connects") }
      let kind = sa(at(m, "kind"))
      let deps : PartDeps = {
        cards: self.cards(),
        recent_people: async fn(connect) { sa(Some(self.ask("readers.recentConnectPeople", [js(connect)]))) },
        overview_changed: () => self.note("events.overviewChanged", []),
        rows_changed: () => self.note("events.rowsChanged", []),
        log: self.log(),
      }
      let own : KindOf = {
        kind,
        shown: (cs, raw) => jo([("name", match at(Some(raw), "name") { Some(Str(_) as n) => n; _ => at(Some(raw), "id").unwrap_or(undefined()) }), ("connection", cs.state(raw).unwrap_or(Null))]),
        taken: Some(_ => self.note("part.taken", [])),
      }
      let p = connects_part(deps, c, own)
      let id = self.handle()
      self.parts[id] = p
      ji(id)
    }
    "part.call" => {
      guard self.parts.get(h) is Some(p) else { raise fail_("no part") }
      match sa(at(m, "name")) {
        "storeChanged" => p.store_changed(arg(0))
        "connection" => return p.connection(arg(0))
        "shown" => return p.shown(arg(0))
        "reconnect" => p.reconnect(s(0))
        "taken" => p.taken()
        "changed" => p.changed()
        "left" => p.left()
        n => raise fail_("no such call \{n}")
      }
      Null
    }
    // ── cards that end ──
    "cards.ended" => ja(cards_ended(self.cards(), arg(0)))
    "cards.show" => {
      let chats = at(m, "chats")
      show_ended(self.cards(), connect => match at(chats, connect) { Some(Null) | None => None; Some(snap) => Some(self.chat_surface(connect, snap)) }, arg(0), self.log())
      Null
    }
    // ── a connected surface ──
    "surface.new" => self.surface_new(m)
    "surface.call" => self.surface_call(h, sa(at(m, "name")), args)
    "ws.event" => {
      guard self.sockets.get(h) is Some(q) else { raise fail_("no socket") }
      let e = at(m, "event")
      let ev = match sa(at(e, "type")) {
        "open" => Opened
        "message" => Said(unhex(sa(at(e, "hex"))), at(e, "binary") is Some(Bool(true)))
        "pong" => Pong
        "ping" => Pinged
        "close" => Closed
        "error" => Failed(sa(at(e, "message")))
        _ => Refused(ia(at(e, "status")), sa(at(e, "said")))
      }
      ignore(q.try_offer(ev))
      Null
    }
    // ── another station's connects ──
    "remote.new" => {
      let id = self.handle()
      let r = RemoteConnects::new(sa(at(m, "data")), () => self.here, self.asker(), kind => match self.kind_books.get(kind) { Some(b) => self.books.get(b); None => None }, self.fs(), self.log())
      self.remotes[id] = r
      ji(id)
    }
    "remote.names" => {
      self.kind_books[sa(at(m, "kind"))] = ia(at(m, "book"))
      Null
    }
    "remote.call" => self.remote_call(h, sa(at(m, "name")), args)
    "remote.read" => from_entries(read_remote(self.fs(), sa(at(m, "data"))))
    "answer.new" => {
      let id = self.handle()
      self.answerers[id] = {
        surface: async fn(known, ws) {
          match self.ask("answer.surface", [known.to_j(), opt_j(ws)]) {
            Null => None
            snap => Some(self.chat_surface(known.id, snap))
          }
        },
        uploads: sa(at(m, "uploads")),
        cleared: async fn() { ignore(self.ask("answer.cleared", [])) },
        fs: self.fs(),
        uuid: () => self.uuid(),
      }
      ji(id)
    }
    "answer.call" => {
      guard self.answerers.get(h) is Some(a) else { raise fail_("no answerer") }
      let body = match at(m, "body") {
        Some(Str(u)) => Some(unhex(@jsjson.sanitize_str(u)))
        _ => None
      }
      answer_j(a.answer(at(m, "request").unwrap_or(Null), body, so(at(m, "workspace"))))
    }
    // ── the workspace's connects ──
    "ws.new" => {
      let made : Ref[WorkspaceConnects?] = Ref(None)
      let w = WorkspaceConnects::new(self.workspace_deps(sa(at(m, "data")), made))
      made.val = Some(w)
      let id = self.handle()
      self.workspaces_made[id] = w
      self.remotes[id] = w.remote
      ji(id)
    }
    "bus.handle" => {
      guard self.handlers.get(sa(at(m, "method"))) is Some(f) else { raise fail_("no such method") }
      let body = match at(m, "body") {
        Some(Str(u)) => Some(unhex(@jsjson.sanitize_str(u)))
        _ => None
      }
      answer_j(f(sa(at(m, "peer")), at(m, "request").unwrap_or(Null), so(at(m, "workspace")), body))
    }
    "bus.heard" => {
      for f in self.heard {
        f(sa(at(m, "peer")))
      }
      Null
    }
    "ws.call" => self.workspace_call(h, sa(at(m, "name")), args)
    // ── the group connects ──
    "group.make" => {
      let data = sa(at(m, "data"))
      let parts = make_group({
        connects: self.connects_options(data),
        endpoints: () => self.endpoints(),
        create: None,
        public_key: key => self.public_key(key),
        speech: self.speech(),
        uuid: () => self.uuid(),
        signer: self.signer(),
      })
      let id = self.handle()
      self.groups[id] = parts
      self.connects[id] = parts.connects
      self.threads[id] = parts.threads
      ji(id)
    }
    "group.call" => {
      guard self.groups.get(h) is Some(g) else { raise fail_("no group") }
      match sa(at(m, "name")) {
        "close" => g.close()
        "shown" => return g.shown(arg(0))
        "kept" => return g.threads.kept()
        "surface" => {
          guard g.connects.chat(s(0)) is Some(c) else { raise fail_("no such connect") }
          return (c.surface.call)(s(1), arr_of(args.get(2)).unwrap_or([]))
        }
        n => raise fail_("no such call \{n}")
      }
      Null
    }
    "threads.open" => {
      let t = GroupThreads::open(sa(at(m, "path")), self.fs(), self.log())
      let id = self.handle()
      self.threads[id] = t
      ji(id)
    }
    "threads.call" => {
      guard self.threads.get(h) is Some(t) else { raise fail_("no threads") }
      match sa(at(m, "name")) {
        "spaces" => return from_entries(t.spaces(s(0)).map(e => (e.0, jo([("aseq", jn(e.1.aseq)), ("dseq", jn(e.1.dseq)), ("prev", js(e.1.prev))]))))
        "space" =>
          return match t.space(s(0), s(1)) {
            Some(k) => jo([("aseq", jn(k.aseq)), ("dseq", jn(k.dseq)), ("prev", js(k.prev))])
            None => Null
          }
        "took" => t.took(s(0), s(1), na(args.get(2)), stream=so(args.get(3)))
        "last" => return jn(t.last(s(0), s(1)))
        "said" => t.said(s(0), s(1), na(args.get(2)), s(3))
        "forget" => t.forget(s(0), s(1))
        "drop" => t.drop(s(0))
        "flushed" => t.flushed()
        "kept" => return t.kept()
        n => raise fail_("no such call \{n}")
      }
      Null
    }
    "link.new" => {
      let strs = (k : String) => arr_of(at(m, k)).unwrap_or([]).map(x => js_text(Some(x)))
      let l = GroupLink::new({ endpoints: self.endpoints(), secret_key: sa(at(m, "key")), server: sa(at(m, "server")), relays: strs("relays"), ips: strs("ips") })
      let id = self.handle()
      self.links[id] = l
      ji(id)
    }
    "link.call" => self.link_call(h, sa(at(m, "name")), args)
    "sse.new" => {
      let id = self.handle()
      self.sses[id] = SseLines::new()
      ji(id)
    }
    "sse.feed" => {
      guard self.sses.get(h) is Some(sse) else { raise fail_("no sse") }
      ja(sse.feed(unhex(s(0))).map(e => ja([js(e.0), js(e.1), opt_j(e.2)])))
    }
    "gsurface.new" => {
      let id = self.handle()
      guard self.threads.get(ia(at(m, "threads"))) is Some(t) else { raise fail_("no threads") }
      let g = GroupSurface::new(self.group_options(id, m, t))
      self.group_surfaces[id] = g
      ji(id)
    }
    "gsurface.call" => self.gsurface_call(h, sa(at(m, "name")), args)
    op => raise fail_("no such op: \{op}")
  }
}

///|
/// A pure function of these parts, by its TypeScript name.
fn Harness::pure(self : Harness, name : String, args : Array[J]) -> J raise {
  let arg = (i : Int) => args.get(i).unwrap_or(Null)
  let s = (i : Int) => sa(args.get(i))
  match name {
    "personKey" => js(person_key(s(0), s(1)))
    "channelKey" => js(channel_key(s(0), s(1)))
    "namesFile" => opt_j(names_file(s(0)))
    "localOf" => js(local_of({ id: sa(at(args.get(0), "id")), origin: sa(at(args.get(0), "origin")) }, s(1)))
    "knownOf" => known_of(s(0), s(1)).to_j()
    "knownIn" =>
      match known_in(args.get(0)) {
        Some(k) => k.to_j()
        None => Null
      }
    "describe" => describe(arg(0), s(1), self.chat_surface("", arg(2)))
    "connectOf" => connect_of(s(0), arg(1))
    "threadOfEvent" => thread_of_event(arg(0))
    "fingerprint" => opt_j(fingerprint(s(0), args.get(1)))
    "shownIdentity" => shown_identity(arg(0))
    "endedWords" => js(ended_words(self.speech(), arg(0), arg(1), so(args.get(2)), s(3)))
    "segment" => js(segment(s(0)))
    "percentDecode" => js(request_percent_decode(s(0)))
    "input" => request_input(s(0))
    "groupConnects" => ja(group_connects(arg(0)))
    "codeHash" => js(code_hash(s(0)))
    "credentials" => opt_j(group_credentials(arg(0)))
    "deviceOf" => opt_j(device_of(s(0), k => self.public_key(k)))
    "mentions" => jb(mentions(s(0), s(1)))
    "cardWords" => {
      let (words, options) = card_words(self.speech(), s(0), arg(1), s(2))
      jo([("words", js(words)), ("options", jsa(options))])
    }
    "imageSize" =>
      match image_size(unhex(s(0))) {
        Some((w, h)) => jo([("width", jn(w)), ("height", jn(h))])
        None => Null
      }
    "mimeOf" => js(mime_of(s(0)))
    "unanswered" => jb(unanswered(@session_chats.Thrown(s(0), s(1))))
    "jsUpper" => js(js_upper(s(0)))
    "canonicalJson" => js(canonical_json(arg(0)))
    "moonOrder" => ji(moon_order(s(0), s(1)))
    "directId" => js(direct_id(s(0), s(1)))
    "isSpaceId" => jb(is_space_id(s(0)))
    "isTopicId" => jb(is_topic_id(s(0)))
    "eventOf" =>
      match event_of(args.get(0)) {
        Some(e) => e.to_j()
        None => Null
      }
    "eventId" =>
      match event_of(args.get(0)) {
        Some(e) => js(event_id(e))
        None => Null
      }
    "verified" =>
      match event_of(args.get(0)) {
        Some(e) => jb(verified(self.signer(), e))
        None => Null
      }
    "signEvent" => {
      let p = args.get(1)
      let hlc = arr_of(at(p, "hlc")).unwrap_or([])
      let e : GroupEvent = {
        space: sa(at(p, "space")),
        author: sa(at(p, "author")),
        device: sa(at(p, "device")),
        dseq: na(at(p, "dseq")),
        hlc: (na(hlc.get(0)), na(hlc.get(1))),
        prev: sa(at(p, "prev")),
        topic: sa(at(p, "topic")),
        kind: sa(at(p, "kind")),
        body: at(p, "body").unwrap_or(Null),
        sig: "",
      }
      sign_event(self.signer(), s(0), e).to_j()
    }
    "stampedOf" =>
      match stamped_of(self.signer(), args.get(0)) {
        Some(st) => jo([("id", js(st.id)), ("event", st.event.to_j()), ("aseq", jn(st.aseq)), ("n", jn(st.n)), ("at", jn(st.at))])
        None => Null
      }
    "hlc" => {
      let h = Hlc::new()
      let out : Array[J] = []
      for step in arr_of(args.get(0)).unwrap_or([]) {
        match sa(at(Some(step), "op")) {
          "next" => {
            let (a, b) = h.next(na(at(Some(step), "wall")))
            out.push(ja([jn(a), jn(b)]))
          }
          _ => h.saw(na(at(Some(step), "ms")), na(at(Some(step), "n")))
        }
      }
      ja(out)
    }
    "decisionBody" => decision_body(s(0), arg(1))
    "threadOf" => thread_of(s(0), s(1))
    "streamOf" => {
      let (a, b) = stream_of(arg(0))
      jo([("space", js(a)), ("topic", js(b))])
    }
    "streamKey" => js(stream_key(s(0), s(1)))
    _ => raise fail_("no such function \{name}")
  }
}

///|
fn Harness::surface_new(self : Harness, m : J?) -> J {
  let id = self.handle()
  let open_socket = fn(url : String, headers : Array[(String, String)]) -> Socket {
    let sh = self.handle()
    let q : @effect.Queue[SocketEvent] = @effect.Queue::unbounded()
    self.sockets[sh] = q
    self.note("ws.open", [ji(id), ji(sh), js(url), jo(headers.map(p => (p.0, js(p.1))))])
    {
      events: q,
      send: b => self.note("ws.send", [ji(sh), js(hex(b))]),
      ping: () => self.note("ws.ping", [ji(sh)]),
      terminate: () => self.note("ws.terminate", [ji(sh)]),
    }
  }
  let base = ConnectedSurface::new(sa(at(m, "kind")), {
    connect: so(at(m, "connect")),
    book: self.book(at(m, "book")),
    ping_ms: na(at(m, "pingMs")),
    stale_ms: na(at(m, "staleMs")),
    backoff_ms: num_of(at(m, "backoffMs")).unwrap_or(1000.0),
    clock: self.clock(),
    on_heard: () => self.note("surf.heard", [ji(id)]),
    log: self.log(),
    open_socket: Some(open_socket),
  })
  base.identify = async fn() { self.ask("surf.identify", [ji(id)]) }
  base.address = async fn() { sa(Some(self.ask("surf.address", [ji(id)]))) }
  base.run_socket = async fn(url, handler) {
    let run = self.ask("surf.runSocket", [ji(id), js(url)])
    // (the events the test's socket says, handed on one at a time, until it says it ended)
    for e in arr_of(Some(run)).unwrap_or([]) {
      handler(e)
    }
  }
  base.look_up = async fn(user) { match self.ask("surf.lookUp", [ji(id), js(user)]) { Null => None; p => Some(p) } }
  base.look_up_email = async fn(email) { so(Some(self.ask("surf.lookUpEmail", [ji(id), js(email)]))) }
  base.status_line = thread => {
    let key = "\{sa(at(Some(thread), "channel"))}/\{sa(at(Some(thread), "threadTs"))}"
    StatusLine::new(f => base.run(f), base.clock, na(at(m, "statusMs")), async fn(l, status, now) {
      self.ask("surf.show", [ji(id), js(key), js(status), jn(now), opt_j(l.message_ts), opt_j(l.page)]) is Bool(true)
    })
  }
  self.surfaces[id] = base
  ji(id)
}

///|
async fn Harness::surface_call(self : Harness, h : Int, name : String, args : Array[J]) -> J {
  guard self.surfaces.get(h) is Some(base) else { raise fail_("no surface") }
  let s = (i : Int) => sa(args.get(i))
  match name {
    "start" => base.start(async fn(e) { ignore(self.ask("surf.handled", [ji(h), e])) })
    "stop" => base.stop()
    "kept" => return base.kept(s(0), na(args.get(1)), async fn() { self.ask("surf.read", [ji(h), js(s(0))]) })
    "forget" => return jb(base.forget(s(0), na(args.get(1))))
    "userName" => return opt_j(base.user_name(s(0)))
    "userEmail" => return opt_j(base.user_email(s(0)))
    "userOf" => return opt_j(base.user_of(s(0)))
    "working" => base.working(args.get(0).unwrap_or(Null), so(args.get(1)), s(2), so(args.get(3)))
    "refreshIdentity" => base.refresh_identity()
    "onChange" => ignore(base.on_change(() => self.note("surf.changed", [ji(h)])))
    "state" =>
      return jo([
        ("identity", base.identity()),
        ("socket", base.socket()),
        ("botUserId", js(base.bot_user_id())),
        ("botName", js(base.bot_name())),
        ("workspace", opt_j(base.workspace())),
        ("lines", ji(base.lines.length())),
      ])
    "socketTo" => {
      let hooks : SocketHooks = {
        opened: _ => self.note("surf.opened", [ji(h)]),
        message: fn(_, data, binary, now, end) {
          let text = text_of(data)
          self.note("surf.message", [ji(h), js(text), jb(binary), jn(now)])
          if text == "end" {
            end(None)
          } else if text.has_prefix("fail:") {
            end(Some(@session_chats.slice(text, 5)))
          }
        },
        ping: _ => self.note("surf.ping", [ji(h)]),
      }
      let headers = fields_of(args.get(1)).map(f => (f.0, js_text(Some(f.1))))
      base.socket_to(s(0), hooks, headers~)
    }
    n => raise fail_("no such call \{n}")
  }
  Null
}

///|
async fn Harness::remote_call(self : Harness, h : Int, name : String, args : Array[J]) -> J {
  guard self.remotes.get(h) is Some(r) else { raise fail_("no remote") }
  let s = (i : Int) => sa(args.get(i))
  match name {
    "learn" => r.learn(s(0), s(1), args.get(2).unwrap_or(Null))
    "moved" => r.moved(s(0), s(1))
    "connects" => return ja(r.connects())
    "ready" => r.ready()
    "written" => r.written()
    "surface" =>
      return match r.surface(s(0)) {
        Some(rs) => jo([("id", js(rs.id)), ("known", rs.known.to_j()), ("station", js(rs.station)), ("described", rs.described)])
        None => Null
      }
    "has" => {
      guard r.surface(s(0)) is Some(rs) else { return Null }
      return jb((rs.surface().has)(s(1)))
    }
    "get" => {
      guard r.surface(s(0)) is Some(rs) else { return Null }
      return (rs.surface().get)(s(1), arr_of(args.get(2)).unwrap_or([]))
    }
    "call" => {
      guard r.surface(s(0)) is Some(rs) else { return Null }
      return (rs.surface().call)(s(1), arr_of(args.get(2)).unwrap_or([]))
    }
    n => raise fail_("no such call \{n}")
  }
  Null
}

///|
async fn Harness::workspace_call(self : Harness, h : Int, name : String, args : Array[J]) -> J {
  guard self.workspaces_made.get(h) is Some(w) else { raise fail_("no workspace connects") }
  let s = (i : Int) => sa(args.get(i))
  let strs = (i : Int) => arr_of(args.get(i)).unwrap_or([]).map(x => js_text(Some(x)))
  match name {
    "route" => w.route(s(0), s(1), s(2), s(3))
    "describedFor" =>
      return match w.described_for(s(0)) {
        Some((station, d)) => jo([("station", js(station)), ("described", d)])
        None => Null
      }
    "learnOf" => w.learn_of({ id: sa(at(args.get(0), "id")), origin: sa(at(args.get(0), "origin")) }, s(1), args.get(2).unwrap_or(Null))
    "receive" => w.receive(s(0), args.get(1).unwrap_or(Null))
    "heldBy" => return opt_j(w.held_by(so(args.get(0)), s(1), args.get(2)))
    "ownIn" => return jsa(w.own_in(s(0)))
    "ownKinds" => return ja(w.own_kinds(s(0)))
    "movedAway" => return ja(w.moved_away(s(0)))
    "ownIds" => return jsa(w.own_ids())
    "kindOf" => return w.kind_mode(s(0)).unwrap_or(Null)
    "runsOn" => return opt_j(w.runs_on(s(0)))
    "namedIn" => return ja(w.named_in(s(0)))
    "moveAll" => w.move_all(s(0), s(1))
    "takeHeld" => w.take_held(s(0))
    "move" => w.move_to(s(0), s(1), so(args.get(2)), lang=so(args.get(3)), locals_to=so(args.get(4)), awaiting=strs(5))
    "settleMoving" => w.settle_moving(peer=so(args.get(0)))
    "arrived" => w.arrived(strs(0))
    "moveRoute" => {
      let email = match args.get(4) {
        Some(Null) | None => undefined()
        Some(e) => e
      }
      let (status, body) = w.move_route(s(0), s(1), s(2), so(args.get(3)), email, s(5), async fn() {
        self.ask("agents.overview", [])
      })
      return jo([("status", ji(status)), ("body", body)])
    }
    n => raise fail_("no such call \{n}")
  }
  Null
}

///|
async fn Harness::link_call(self : Harness, h : Int, name : String, args : Array[J]) -> J {
  if name == "next" || name == "cancel" {
    guard self.streams.get(h) is Some(st) else { raise fail_("no stream") }
    if name == "cancel" {
      (st.cancel)()
      return Null
    }
    return match (st.next)() {
      Some(b) => js(hex(b))
      None => Null
    }
  }
  guard self.links.get(h) is Some(l) else { raise fail_("no link") }
  let s = (i : Int) => sa(args.get(i))
  let body = fn(v : J?) -> Asked {
    match v {
      Some(Obj(_)) as o if at(o, "hex") is Some(Str(u)) => BytesAsked(unhex(@jsjson.sanitize_str(u)))
      Some(Obj(_)) as o if at(o, "json") is Some(j) => JsonAsked(j)
      _ => NoAsked
    }
  }
  let answered = (a : Answered) => jo([("status", ji(a.status)), ("headers", jo(a.headers.to_array().map(p => (p.0, js(p.1))))), ("body", js(text_of(a.body)))])
  match name {
    "device" => return js(l.device())
    "open" => return jb(l.open())
    "connect" => {
      let me = l.connect(args.get(0).unwrap_or(Null))
      return jo([("member", js(me.member_id)), ("name", js(me.name)), ("owner", jb(me.owner)), ("joined", jb(me.joined))])
    }
    "ping" => l.ping()
    "ask" => return answered(l.ask(s(0), s(1), body=body(args.get(2))))
    "stream" => {
      let st = l.stream(s(0), s(1))
      let id = self.handle()
      self.streams[id] = st
      return jo([("h", ji(id)), ("status", ji(st.status)), ("headers", jo(st.headers.to_array().map(p => (p.0, js(p.1)))))])
    }
    "drop" => l.drop(s(0))
    "close" => l.close()
    n => raise fail_("no such call \{n}")
  }
  Null
}

///|
async fn Harness::gsurface_call(self : Harness, h : Int, name : String, args : Array[J]) -> J {
  guard self.group_surfaces.get(h) is Some(g) else { raise fail_("no group surface") }
  let s = (i : Int) => sa(args.get(i))
  let handler = async fn(e : J) { ignore(self.ask("gsurf.handled", [ji(h), e])) }
  let conn = g.connection()
  match name {
    "start" => (conn.start)(handler)
    "stop" => (conn.stop)()
    "device" => return js(g.device())
    "take" => g.take(s(0), s(1), handler)
    "sync" => g.sync(handler)
    "onChange" => ignore((conn.on_change)(() => self.note("gsurf.changed", [ji(h)])))
    "state" => return jo([("identity", (conn.identity)()), ("socket", (conn.socket)())])
    "has" => return jb((conn.surface.has)(s(0)))
    "get" => return (conn.surface.get)(s(0), arr_of(args.get(1)).unwrap_or([]))
    "call" => return (conn.surface.call)(s(0), arr_of(args.get(1)).unwrap_or([]))
    n => raise fail_("no such call \{n}")
  }
  Null
}
