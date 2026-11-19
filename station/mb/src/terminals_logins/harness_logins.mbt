// The logins' cases of the harness (harness.mbt): the logins and their part of the station, on commands, a station
// browser, a callback's server and the station's other parts of the test's. Each command started is a child of the
// world's: what it writes and when it ends are the case's steps, what is typed into it and the signals it is sent are
// written down, as the test's stand-in command reports them on the TypeScript's side.

///|
priv struct FakeChild {
  k : Int
  spawned : J
  typed : StringBuilder
  outs : Array[(Int, Bytes) -> Unit]
  closes : Array[(Int?, String?) -> Unit]
  mut closed : Bool
}

///|
priv struct LoginsWorld {
  w : World
  case_ : J
  files : Map[String, String]
  children : Array[FakeChild]
  signals : Array[J]
  requests : Array[J]
  opened_tabs : Array[J]
  closed_tabs : Array[J]
  tabs : Map[String, String?]
  screen_watchers : Array[() -> Unit]
  notes : Array[J]
  events : Array[J]
  event_seen : Map[String, Bool]
  cards_closed : Array[J]
  asks : Array[J]
  randoms : Array[String]
}

///|
fn LoginsWorld::platform(self : LoginsWorld, k : String) -> J? {
  get(get(Some(self.case_), "platform"), k)
}

///|
fn LoginsWorld::close_child(self : LoginsWorld, child : FakeChild, code : Int?, signal : String?) -> Unit {
  if child.closed {
    return
  }
  child.closed = true
  for f in child.closes.copy() {
    f(code, signal)
  }
}

///|
fn LoginsWorld::run_io(self : LoginsWorld) -> RunIo {
  let w = self.w
  {
    ..plain_run_io(w, self.files, []),
    prepend_path: (env, dir) => {
      let out = env.copy()
      out["PATH"] = dir + ":" + env.get("PATH").unwrap_or("")
      out
    },
    terminal: async fn(_, _, _, _) {
      match self.platform("terminal") {
        Some(Arr([Str(f), Arr(a)])) => Some((f, a.map(x => text(Some(x)).unwrap_or(""))))
        _ => None
      }
    },
    start_command: (file, args, cwd, env) => {
      match text(self.platform("spawnFails")) {
        Some(m) => raise Failure(m)
        None => ()
      }
      let child : FakeChild = {
        k: self.children.length(),
        spawned: jo([("file", js(file)), ("args", jstrs(args)), ("cwd", js(cwd)), ("env", env_json(env))]),
        typed: StringBuilder::new(),
        outs: [],
        closes: [],
        closed: false,
      }
      self.children.push(child)
      {
        pid: Some(4000 + child.k),
        writable: () => true,
        write: t => child.typed.write_string(t),
        end_stdin: () => (),
        on_output: f => child.outs.push(f),
        on_close: f => child.closes.push(f),
      }
    },
    started: async fn(_) { text(self.platform("startedFails")) },
    end_command: (c, signal) => {
      let k = match c.pid {
        Some(p) => p - 4000
        None => -1
      }
      self.signals.push(jo([("child", ji(k)), ("signal", js(signal))]))
      // (the stand-in ends on it, as a process told SIGTERM or SIGKILL does)
      if k >= 0 && k < self.children.length() {
        let child = self.children[k]
        w.spawn(async fn() { self.close_child(child, None, Some(signal)) })
      }
    },
    echoes: async fn(_) {
      match self.platform("echoes") {
        Some(Bool(b)) => Some(b)
        _ => None
      }
    },
    commands: async fn(_) {
      match self.platform("commands") {
        Some(Arr(cs)) => cs.map(x => text(Some(x)).unwrap_or(""))
        _ => []
      }
    },
    descendants: async fn(_) { [] },
  }
}

///|
fn LoginsWorld::relay_io(self : LoginsWorld) -> RelayIo {
  {
    listening: async fn(_, _) {
      match self.platform("listening") {
        Some(Arr(a)) => Some(a.map(x => text(Some(x)).unwrap_or("")))
        _ => None
      }
    },
    send: async fn(host, port, method_, path, headers, body) {
      self.requests.push(
        jo([
          ("host", js(host)),
          ("port", ji(port)),
          ("method", js(method_)),
          ("path", js(path)),
          ("headers", jo(headers.map(h => (h.0, js(h.1))))),
          ("body", js(base64_of(body))),
        ]),
      )
      let answer = get(get(Some(self.case_), "answers"), host)
      match text(get(answer, "code")) {
        Some(code) => raise SendFailed(code, text(get(answer, "message")).unwrap_or(code))
        None => ()
      }
      {
        status: int_of(get(answer, "status")),
        headers: match get(answer, "headers") {
          Some(Obj(ps)) => ps.map(p => (p.0, text(Some(p.1)).unwrap_or("")))
          _ => []
        },
        body: text(get(answer, "body")).unwrap_or(""),
      }
    },
  }
}

///|
fn person_from(j : J?) -> Person? {
  match j {
    Some(Obj(_)) => Some({ email: text(get(j, "email")).unwrap_or(""), name: text(get(j, "name")).unwrap_or("") })
    _ => None
  }
}

///|
fn starter_from(j : J?) -> Starter {
  {
    by: person_from(get(j, "by")).unwrap_or({ email: "", name: "" }),
    workspace: text(get(j, "workspace")),
    chat: text(get(j, "chat")),
    chat_title: text(get(j, "chatTitle")),
    peer: match get(j, "peer") {
      Some(Obj(_) as p) => Some((text(get(Some(p), "station")).unwrap_or(""), text(get(Some(p), "session")).unwrap_or("")))
      _ => None
    },
  }
}

///|
fn refused_json(e : Error) -> J {
  match e {
    Refused(status, message) => jo([("refused", ja([ji(status), js(message)]))])
    BusRefused(message) => jo([("busRefused", js(message))])
    _ => jo([("error", js(error_message(e)))])
  }
}

///|
fn LoginsWorld::host(self : LoginsWorld) -> LoginsHost {
  let c = Some(self.case_)
  {
    session_ws: s => text(get(get(get(c, "sessions"), s), "ws")),
    session_row: s => match get(get(c, "sessions"), s) {
      Some(Obj(_) as row) => Some((text(get(Some(row), "createdBy")), text(get(Some(row), "ws"))))
      _ => None
    },
    close_login_cards: id => {
      self.cards_closed.push(js(id))
      match get(get(c, "cards"), id) {
        Some(Arr(ss)) => ss.map(x => text(Some(x)).unwrap_or(""))
        Some(Str(_)) => raise Failure("the cards could not be closed")
        _ => []
      }
    },
    machine_logins: (full, lim, key) => {
      let e = ja([js(key), full, lim])
      let k = stringify(e)
      if !self.event_seen.contains(k) {
        self.event_seen[k] = true
        self.events.push(e)
      }
    },
    notify: (session, t) => {
      match get(c, "notifyFails") {
        Some(Arr(ss)) if ss.iter().any(x => text(Some(x)) == Some(session)) => raise Failure("no such session")
        _ => ()
      }
      self.notes.push(ja([js(session), js(t)]))
    },
    chat_title: _ => None,
    name_of: email => text(get(get(c, "names"), email)),
    place: () => match get(c, "place") {
      Some(Obj(_) as p) => Some((text(get(Some(p), "station")).unwrap_or(""), text(get(Some(p), "workspace")).unwrap_or("")))
      _ => None
    },
    page_base: () => match get(c, "pages") {
      Some(Obj(_) as p) =>
        Some(
          (
            text(get(Some(p), "origin")).unwrap_or(""),
            text(get(Some(p), "workspace")).unwrap_or(""),
            text(get(Some(p), "station")).unwrap_or(""),
          ),
        )
      _ => None
    },
    station_name: id => match get(c, "stations") {
      Some(Arr(ss)) =>
        for s in ss {
          if text(get(Some(s), "id")) == Some(id) {
            match text(get(Some(s), "name")) {
              Some(n) if n != "" => break n
              _ => break id
            }
          }
        } nobreak {
          id
        }
      _ => id
    },
    peer_named: given => {
      // (peer-http.ts peerNamed as these cases name stations: by id, else by name as cased anywhere)
      let stations = match get(c, "stations") {
        Some(Arr(ss)) => ss
        _ => []
      }
      for s in stations {
        if text(get(Some(s), "id")) == Some(given) {
          return given
        }
      }
      let low = @jscase.lower(given)
      for s in stations {
        match text(get(Some(s), "name")) {
          Some(n) if @jscase.lower(n) == low => return text(get(Some(s), "id")).unwrap_or("")
          _ => ()
        }
      }
      let names = stations.map(s => match text(get(Some(s), "name")) {
        Some(n) if n != "" => n
        _ => text(get(Some(s), "id")).unwrap_or("")
      })
      raise Failure(
        "no station \{given} in this station's workspaces" +
        (if names.length() > 0 { "; its stations: " + names.join(", ") } else { "" }),
      )
    },
    ask: async fn(station, request) {
      self.asks.push(ja([js(station), request]))
      let answers = match get(c, "bus") {
        Some(Arr(a)) => a
        _ => []
      }
      let n = self.asks.length() - 1
      let answer = if n < answers.length() { Some(answers[n]) } else { None }
      match text(get(answer, "refused")) {
        Some(m) => raise BusRefused(m)
        None => ()
      }
      match text(get(answer, "error")) {
        Some(m) => raise Failure(m)
        None => ()
      }
      or_null(get(answer, "answer"))
    },
    spawn: f => self.w.spawn(f),
    log: (_, _) => (),
  }
}

///|
/// `IDOF<k>` in what a step gives: the k-th login told.
fn put_ids(v : J, started : Array[String]) -> J {
  match v {
    Str(u) => {
      let t = u
      if !t.contains("IDOF") {
        return v
      }
      let out = StringBuilder::new()
      let mut i = 0
      while i < t.length() {
        if t.unsafe_substring(start=i, end=t.length()).has_prefix("IDOF") {
          let mut j = i + 4
          let mut k = 0
          while j < t.length() && t.code_unit_at(j).to_int() >= '0'.to_int() && t.code_unit_at(j).to_int() <= '9'.to_int() {
            k = k * 10 + t.code_unit_at(j).to_int() - '0'.to_int()
            j += 1
          }
          if j > i + 4 {
            if k < started.length() {
              out.write_string(started[k])
            }
            i = j
            continue
          }
        }
        out.write_string(t.unsafe_substring(start=i, end=i + 1))
        i += 1
      }
      js(out.to_string())
    }
    Arr(items) => Arr(items.map(x => put_ids(x, started)))
    Obj(ps) => Obj(ps.map(p => (p.0, put_ids(p.1, started))))
    other => other
  }
}

///|
fn logins_case(c : J) -> J raise {
  let w = World::new(num(get(Some(c), "now")).unwrap_or(0.0))
  let lw : LoginsWorld = {
    w,
    case_: c,
    files: {},
    children: [],
    signals: [],
    requests: [],
    opened_tabs: [],
    closed_tabs: [],
    tabs: {},
    screen_watchers: [],
    notes: [],
    events: [],
    event_seen: {},
    cards_closed: [],
    asks: [],
    randoms: match get(Some(c), "randoms") {
      Some(Arr(rs)) => rs.map(r => text(Some(r)).unwrap_or(""))
      _ => []
    },
  }
  let data = text(get(Some(c), "data")).unwrap_or("/data")
  match text(get(Some(c), "history")) {
    Some(h) => lw.files[data + "/logins/history.json"] = h
    None => ()
  }
  let env = env_from(get(Some(c), "env"))
  let run_io = lw.run_io()
  let io : LoginsIo = {
    data,
    env: () => env.copy(),
    lang: () => text(get(Some(c), "lang")).unwrap_or("en"),
    run: run_io,
    mkdir: async fn(_) { () },
    make_command: async fn(path, t) { lw.files[path] = t },
    write_private: async fn(path, t) { lw.files[path] = t },
    sleep: async fn(ms) { @effect.sleep(ms) },
    // (past the case's, as the test's Math.random gives then: 0.5)
    random4: () => if lw.randoms.length() > 0 { lw.randoms.remove(0) } else { "i" },
    relay: lw.relay_io(),
  }
  // (the station's browser is always there to ask; one the case has none of says it is not available)
  let browser = get(Some(c), "browser")
  let next_tab = Ref(0)
  let pages = LoginPages::new(
    {
      available: () => browser is Some(Obj(_)) && !(get(browser, "available") is Some(Bool(false))),
      open_tab: async fn(url, _) {
        match text(get(browser, "openFails")) {
          Some(m) => raise Failure(m)
          None => ()
        }
        next_tab.val += 1
        let id = "t\{next_tab.val}"
        lw.opened_tabs.push(ja([js(id), js(url)]))
        lw.tabs[id] = None
        id
      },
      has_tab: id => lw.tabs.contains(id),
      close_tab: id => {
        lw.closed_tabs.push(js(id))
        lw.tabs.remove(id)
      },
      tab_url: Some(id => lw.tabs.get(id).unwrap_or(None)),
    },
    f => lw.screen_watchers.push(f),
    (_, _) => (),
  )
  let holder : Ref[Logins?] = Ref(None)
  w.spawn(async fn() { holder.val = Some(Logins::new(io, pages~)) })
  w.settle()
  let logins = holder.val.unwrap()
  let part = LoginsPart::new(logins, lw.host())
  // the logins by the order they were first told (`of: k`, `IDOF<k>` in what a step gives)
  let started : Array[String] = []
  logins.changes(id => if !started.contains(id) { started.push(id) }) |> ignore
  let asyncs : Map[String, J] = {}
  let follows : Map[String, (Array[J], () -> Unit)] = {}
  let id_of = (s : J?) => match get(s, "id") {
    Some(Str(u)) => u
    _ =>
      match get(s, "of") {
        Some(Num(k)) if k.to_int() < started.length() => started[k.to_int()]
        _ => ""
      }
  }
  let later = (s : J?, f : async () -> J) => {
    let name = text(get(s, "as")).unwrap_or("")
    w.spawn(async fn() {
      let r = try { jo([("ok", f())]) } catch { e => refused_json(e) }
      asyncs[name] = r
    })
  }
  let results = []
  match get(Some(c), "steps") {
    Some(Arr(steps)) =>
      for given in steps {
        let s = Some(put_ids(given, started))
        let result : J = match text(get(s, "do")) {
          Some("start") => {
            let got : Ref[J] = Ref(Null)
            let command = or_null(get(s, "command"))
            let starter = starter_from(get(s, "starter"))
            w.spawn(async fn() {
              got.val = try {
                logins.start(command, starter)
              } catch {
                e => refused_json(e)
              }
            })
            w.settle()
            got.val
          }
          Some("say") => {
            match get(s, "opened") {
              Some(Str(t)) => lw.files[data + "/run/logins/\{id_of(s)}.opened"] = t
              _ => ()
            }
            let child = lw.children[int_of(get(s, "child"))]
            let bytes = utf8_of(text(get(s, "text")).unwrap_or(""))
            for f in child.outs.copy() {
              f(int_of(get(s, "stream")), bytes)
            }
            Null
          }
          Some("exit") => {
            let child = lw.children[int_of(get(s, "child"))]
            lw.close_child(
              child,
              match get(s, "code") {
                Some(Num(n)) => Some(n.to_int())
                _ => None
              },
              text(get(s, "signal")),
            )
            Null
          }
          Some("advance") => {
            w.advance(int_of(get(s, "ms")))
            Null
          }
          Some("get") => or_null(logins.get(id_of(s)))
          Some("logins") => ja(logins.logins())
          Some("history") => ja(logins.history())
          Some("starter") =>
            match logins.starter_of(id_of(s)) {
              Some(st) =>
                jo([
                  ("by", st.by.to_json()),
                  ("workspace", opt_str(st.workspace)),
                  ("chat", opt_str(st.chat)),
                  ("chatTitle", opt_str(st.chat_title)),
                ])
              None => Null
            }
          Some("cancel") =>
            try logins.cancel(id_of(s), by?=person_from(get(s, "by"))) catch {
              e => refused_json(e)
            }
          Some("input") =>
            try {
              logins.input(id_of(s), text?=get(s, "text"), key?=get(s, "key"))
              js("ok")
            } catch {
              e => refused_json(e)
            }
          Some("answer") =>
            try logins.answer(id_of(s), get(s, "text"), by?=person_from(get(s, "by"))) catch {
              e => refused_json(e)
            }
          Some("paste") =>
            try logins.paste(id_of(s), get(s, "on") is Some(Bool(true))) catch {
              e => refused_json(e)
            }
          Some("openPage") => {
            let id = id_of(s)
            let by = person_from(get(s, "by"))
            later(s, async fn() { js(logins.open_page(id, by?)) })
            Null
          }
          Some("callback") => {
            let id = id_of(s)
            let by = person_from(get(s, "by"))
            let cb = callback_from(get(s, "callback"))
            later(s, async fn() { logins.callback(id, cb, by?).to_json() })
            Null
          }
          Some("tool") => {
            let session = text(get(s, "session")).unwrap_or("")
            let args = or_null(get(s, "args"))
            later(s, async fn() { js(run_login_tool(part.tool(), session, args)) })
            Null
          }
          Some("peer") => {
            let peer = text(get(s, "peer")).unwrap_or("")
            let request = or_null(get(s, "request"))
            let ws = or_null(get(s, "workspace"))
            later(s, async fn() { part.heard_peer(peer, request, ws) })
            Null
          }
          Some("await") =>
            match asyncs.get(text(get(s, "as")).unwrap_or("")) {
              Some(r) => r
              None => jo([("pending", jb(true))])
            }
          Some("follow") => {
            let seen = []
            let stop = logins.follow(id_of(s), screen => seen.push(screen.to_json()))
            follows[text(get(s, "as")).unwrap_or("")] = (seen, stop)
            Null
          }
          Some("unfollow") => {
            match follows.get(text(get(s, "as")).unwrap_or("")) {
              Some((_, stop)) => stop()
              None => ()
            }
            Null
          }
          Some("slackPage") => or_null(part.slack_card(id_of(s)))
          Some("slackAnswer") =>
            try {
              part.slack_answer(id_of(s), text(get(s, "code")).unwrap_or(""), person_from(get(s, "by")).unwrap())
              js("ok")
            } catch {
              e => refused_json(e)
            }
          Some("tabGone") => {
            lw.tabs.remove(text(get(s, "tab")).unwrap_or(""))
            for f in lw.screen_watchers.copy() {
              f()
            }
            Null
          }
          Some("tabUrl") => {
            lw.tabs[text(get(s, "tab")).unwrap_or("")] = text(get(s, "url"))
            for f in lw.screen_watchers.copy() {
              f()
            }
            Null
          }
          Some("heard") => jb(logins.heard(id_of(s)))
          Some("close") => {
            w.spawn(async fn() { logins.close() })
            w.settle()
            Null
          }
          _ => Null
        }
        w.settle()
        results.push(result)
      }
    _ => ()
  }
  // what was written down, once all is written
  w.spawn(async fn() { logins.written() })
  w.settle()
  let shims = data + "/run/login-shims/"
  jo([
    ("results", ja(results)),
    (
      "children",
      ja(lw.children.map(ch => jo([("spawned", ch.spawned), ("typed", js(ch.typed.to_string()))]))),
    ),
    ("signals", ja(lw.signals)),
    ("requests", ja(lw.requests)),
    ("tabs", jo([("opened", ja(lw.opened_tabs)), ("closed", ja(lw.closed_tabs))])),
    ("notes", ja(lw.notes)),
    ("events", ja(lw.events)),
    ("cardsClosed", ja(lw.cards_closed)),
    ("asks", ja(lw.asks)),
    ("follows", jo(follows.iter().map(kv => (kv.0, ja((kv.1).0))).collect())),
    ("history", opt_str(lw.files.get(data + "/logins/history.json"))),
    (
      "shims",
      jo(
        lw.files
        .iter()
        .filter(kv => kv.0.has_prefix(shims))
        .map(kv => (kv.0.unsafe_substring(start=shims.length(), end=kv.0.length()), js(kv.1)))
        .collect(),
      ),
    ),
    ("defects", jstrs(w.defects)),
  ])
}
