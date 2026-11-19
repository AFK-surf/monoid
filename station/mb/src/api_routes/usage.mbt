// What the agents spent, the machine's own sessions, the agents' memory and the machine itself (routes/usage.ts:
// GET /usage, /usage/calls/:session, /machine-sessions, /machine-sessions/:runtime/:id, /memory, /host), and what
// still.fail uses of the machine (GET /resources, POST /resources/processes/:pid/end).

///|
const I64_MAX_TEXT : String = "9223372036854775807"

///|
const I64_MIN_TEXT : String = "-9223372036854775808"

///|
/// `v.parse::<f64>().ok().map(|v| v as i64)`: Rust's float syntax, then as an i64 (NaN 0, beyond its range its ends,
/// the fraction dropped). None when it does not read.
fn number_param(r : Request, name : String) -> Int64? {
  guard r.param(name) is Some(v) else { return None }
  if !re(
      "^[+-]?(?:inf|infinity|nan|(?:[0-9]+\\.?[0-9]*|\\.[0-9]+)(?:[eE][+-]?[0-9]+)?)$",
      flags="i",
    ).matches(v) {
    return None
  }
  let body = re("^[+-]").replace_all(v, _ => "").to_lower()
  let x = if body == "nan" {
    @double.not_a_number
  } else if body == "inf" || body == "infinity" {
    if v.has_prefix("-") {
      @double.neg_infinity
    } else {
      @double.infinity
    }
  } else {
    js_number(v)
  }
  if x.is_nan() {
    return Some(0L)
  }
  if x >= 9223372036854775808.0 {
    return Some(9223372036854775807L)
  }
  if x < -9223372036854775808.0 {
    return Some(-9223372036854775807L - 1L)
  }
  Some((if x < 0.0 { x.ceil() } else { x.floor() }).to_int64())
}

///|
/// A page cursor: an exact SQLite i64 (never through a double).
fn cursor_integer(r : Request, name : String) -> Int64? raise Refused {
  guard r.param(name) is Some(value) else { return None }
  if !re("^[+-]?\\d{1,19}$").matches(value) {
    raise Refused(400, "\{name} must be an integer")
  }
  let neg = value.has_prefix("-")
  let digits = re("^[+-]").replace_all(value, _ => "")
  let mut start = 0
  while start < digits.length() - 1 && digits.unsafe_charcode_at(start) == '0' {
    start += 1
  }
  let d = digits.unsafe_substring(start~, end=digits.length())
  let limit = if neg { "9223372036854775808" } else { I64_MAX_TEXT }
  if d.length() > limit.length() ||
    (d.length() == limit.length() && js_compare(d, limit) > 0) {
    raise Refused(400, "\{name} is out of range")
  }
  if neg && d == "9223372036854775808" {
    return Some(-9223372036854775807L - 1L)
  }
  let mut n = 0L
  for i in 0..<d.length() {
    n = n * 10L + (d.unsafe_charcode_at(i) - '0').to_int64()
  }
  Some(if neg { -n } else { n })
}

///|
fn i64_text(n : Int64?, fallback : String) -> String {
  match n {
    Some(v) => v.to_string()
    None => fallback
  }
}

///|
fn Admin::usage_routes(self : Admin) -> Array[Route] {
  [
    // Sessions this machine's own Claude Code and Codex kept (in a terminal), to go on with one in a chat.
    route("GET", "^\\/machine-sessions$", async fn(r, _) {
      self.read(r, "machineSessions", Obj([]))
    }),
    route("GET", "^\\/+machine-sessions\\/+([^/]+)\\/+([^/]+)(?:\\/.*)?$", async fn(
      r,
      m,
    ) {
      self.read(
        r,
        "machineSession",
        params_obj(
          r,
          [
            ("lang", js(r.lang)),
            ("runtime", js(segment(m[0].unwrap()))),
            ("id", js(segment(m[1].unwrap()))),
          ],
          ["limit"],
        ),
      )
    }),
    // The agents' memory, for the pages to show. A member of a workspace the station joined sees that workspace's.
    route("GET", "^\\/memory$", async fn(r, _) {
      if !(r.who("home") is Some(Bool(false))) {
        return self.read(r, "memory", Obj([]))
      }
      if !self.setup.has("agents") {
        return error(503, "station starting")
      }
      guard r.who("workspace") is Some(Str(ws)) else {
        return error(400, "not a workspace id")
      }
      self.read(r, "memory", jobj([("workspace", js(ws))]))
    }),
    // The machine's state, at most ten seconds old.
    route("GET", "^\\/host$", async fn(r, _) {
      ok(self.backend.ask("host.sample", [js(r.lang)])) catch {
        e => error(500, message_of(e))
      }
    }),
  ]
}

///|
/// GET /usage and a session's calls, the usage part's.
fn Admin::usage_part_routes(self : Admin) -> Array[Route] {
  [
    route("GET", "^\\/usage\\/calls\\/([^/]+)\\/?$", async fn(r, m) {
      let session = segment(m[0].unwrap())
      let from = i64_text(cursor_integer(r, "from"), I64_MIN_TEXT)
      let to = i64_text(cursor_integer(r, "to"), I64_MAX_TEXT)
      let before_at = i64_text(cursor_integer(r, "beforeAt"), I64_MAX_TEXT)
      let before_seq = i64_text(cursor_integer(r, "beforeSeq"), I64_MAX_TEXT)
      let limit = number_param(r, "limit").unwrap_or(100L)
      self.read(
        r,
        "usageCalls",
        jobj([
          ("session", js(session)),
          ("from", js(from)),
          ("to", js(to)),
          ("beforeAt", js(before_at)),
          ("beforeSeq", js(before_seq)),
          ("limit", jnum(limit.to_double())),
          ("viewer", r.viewer),
        ]),
      )
    }),
    route("GET", "^\\/usage$", async fn(r, _) {
      let to = number_param(r, "to").unwrap_or(9223372036854775807L)
      let from = number_param(r, "from").unwrap_or(0L)
      let tz = number_param(r, "tz").unwrap_or(0L)
      let clamped = if tz < -1440L {
        -1440L
      } else if tz > 1440L {
        1440L
      } else {
        tz
      }
      let remote_from = cursor_integer(r, "remoteFrom")
      let history_from = cursor_integer(r, "historyFrom")
      let history_to = cursor_integer(r, "historyTo")
      if (history_from is None) != (history_to is None) {
        raise Refused(400, "history range needs both bounds")
      }
      match (history_from, history_to) {
        (Some(hf), Some(ht)) => {
          let day = 86400000L
          let span = 370L * day
          let bad_order = hf > ht
          let too_long = !bad_order &&
            hf <= 9223372036854775807L - span &&
            ht > hf + span
          let local_end = ht + clamped * 60000L
          let wrapped = clamped > 0L && local_end < ht
          if bad_order ||
            too_long ||
            hf % 60000L != 0L ||
            ht % 60000L != 0L ||
            wrapped ||
            local_end % day != 0L ||
            local_end < -8640000000000000L ||
            local_end > 8640000000000000L {
            raise Refused(400, "invalid history range")
          }
        }
        _ => ()
      }
      let history = r.param("history") == Some("1")
      let reading = self.backend.ask("usage.readingAll", [])
      let args = jobj(
        [
          ("lang", js(r.lang)),
          ("from", js(from.to_string())),
          ("to", js(to.to_string())),
          ("tz", js(clamped.to_string())),
          ("reading", reading),
          ("viewer", r.viewer),
          ("history", jbool(history)),
        ] +
        (match remote_from {
          Some(rf) => [("remoteFrom", js(rf.to_string()))]
          None => []
        }) +
        (match (history_from, history_to) {
          (Some(hf), Some(ht)) =>
            [
              (
                "historyRange",
                jobj([("from", js(hf.to_string())), ("to", js(ht.to_string()))]),
              ),
            ]
          _ => []
        }),
      )
      // A client from before asks it as a stream: its one answer, told as the event it waits for.
      if header_exact(r.headers, "accept")
        .unwrap_or("")
        .contains("text/event-stream") {
        return self.followed_usage(r, args)
      }
      self.read(r, "usage", args)
    }),
  ]
}

///|
const HEARTBEAT_MS : Int32 = 15000

///|
fn event_headers() -> Map[String, String] {
  {
    "content-type": "text/event-stream",
    "cache-control": "no-store",
    "x-accel-buffering": "no",
  }
}

///|
/// The usage as an event stream, for a client from before that asks it so: the answer as a `usage` event (an `error`
/// one where it failed), then the end; its heartbeats while it is read (the wall's, ops/fibers.ts `wall.every`).
async fn Admin::followed_usage(self : Admin, r : Request, args : JV) -> Answer {
  let queue : Array[Bytes] = []
  let closed = Ref(false)
  let finished = Ref(false)
  let wake : Ref[@effect.Deferred[Unit]?] = Ref(None)
  let signal = Signal::new()
  let notify = () => {
    match wake.val {
      Some(w) => {
        wake.val = None
        ignore(w.succeed(()))
      }
      None => ()
    }
  }
  let tell = (answer : Answer) => {
    if closed.val {
      return
    }
    match answer.body {
      Whole(b) if answer.status == 200 =>
        queue.push(utf8("event: usage\ndata: \{utf8_text(b)}\n\n"))
      body => {
        let parsed = match body {
          Whole(b) => try_parse(utf8_text(b)).unwrap_or(Obj([]))
          _ => Obj([])
        }
        queue.push(
          utf8(
            "event: error\ndata: \{stringify(jobj([("status", jint(answer.status)), ("body", parsed)]))}\n\n",
          ),
        )
      }
    }
    notify()
  }
  let beat = self.callback(async fn(_) {
    if !closed.val && !finished.val && queue.length() == 0 {
      queue.push(utf8(": ping\n\n"))
      notify()
    }
  })
  let stop = ref_of(
    self.backend.ask("ops/fibers.wall.every", [jint(HEARTBEAT_MS), beat]),
  )
  let stop_heartbeat = async fn() {
    match stop {
      Some(s) => self.backend.tell(s, [])
      None => ()
    }
  }
  let end = async fn() {
    if closed.val {
      return
    }
    closed.val = true
    stop_heartbeat()
    signal.abort()
    queue.clear()
    notify()
  }
  match r.signal {
    Some(s) if s.aborted => end()
    _ => ()
  }
  self.later(async fn() {
    let a = self.read({ ..r, signal: Some(signal), }, "usage", args) catch {
      e => error(500, message_of(e))
    }
    tell(a)
    finished.val = true
    stop_heartbeat()
    notify()
  })
  let next = async fn() {
    while !closed.val && !finished.val && queue.length() == 0 {
      let w = @effect.Deferred::new()
      wake.val = Some(w)
      w.wait()
    }
    if queue.length() > 0 {
      return Some(queue.remove(0))
    }
    end()
    None
  }
  { status: 200, headers: event_headers(), body: Streamed(next, end), }
}

///|
/// What still.fail uses of this machine now as `r`'s asker sees it (GET /resources).
async fn Admin::shown_to(self : Admin, r : Request) -> Answer {
  let shot = if self.setup.has("resources.watch") {
    self.backend.ask("resources.watch.snapshot", [])
  } else {
    jundef
  }
  let shot = if nullish(shot) {
    jobj([
      ("at", Null),
      ("everyMs", jint(0)),
      ("counted", jbool(false)),
      ("net", jbool(false)),
      ("disk", jbool(false)),
      (
        "total",
        jobj([
          ("cpu", jint(0)),
          ("memory", jint(0)),
          ("netIn", jint(0)),
          ("netOut", jint(0)),
          ("diskRead", jint(0)),
          ("diskWrite", jint(0)),
        ]),
      ),
      ("groups", jarr([])),
      ("history", jarr([])),
    ])
  } else {
    shot
  }
  let shot_groups = jitems(shot.get("groups"))
  let sessions = []
  for g in shot_groups {
    match g.get("session") {
      Some(Str(s)) if s != "" && !sessions.contains(s) => sessions.push(s)
      _ => ()
    }
  }
  let named = self.read(
    r,
    "resourceChats",
    jobj([("sessions", jstrs(sessions)), ("viewer", r.viewer)]),
  )
  if named.status != 200 {
    return named
  }
  let chats = parse(named.text())
  let seen = (key : String) => {
    !key.has_prefix("chat:") ||
    !nullish(
      chats
      .get(key.unsafe_substring(start=5, end=key.length()))
      .unwrap_or(jundef),
    )
  }
  let groups : Array[JV] = []
  let unendable = (ps : JV?) => {
    jitems(ps).map(p => jset(p, "endable", jbool(false)))
  }
  for g in shot_groups {
    let key = jstr(g.get("key")).unwrap_or("")
    if seen(key) {
      groups.push(g)
      continue
    }
    let mut at = -1
    for i, d in groups {
      if d.get("key") == Some(js("agents")) {
        at = i
        break
      }
    }
    if at >= 0 {
      let mut agents = groups[at]
      for f in ["cpu", "memory", "netIn", "netOut", "diskRead", "diskWrite"] {
        let sum = jnumber(agents.get(f)).unwrap_or(@double.not_a_number) +
          jnumber(g.get(f)).unwrap_or(@double.not_a_number)
        agents = jset(agents, f, jnum(sum))
      }
      agents = jset(
        agents,
        "processes",
        jarr(jitems(agents.get("processes")) + unendable(g.get("processes"))),
      )
      groups[at] = agents
    } else {
      let mut a = jset(g, "key", js("agents"))
      a = jset(a, "kind", js("agents"))
      a = jset(a, "session", Null)
      a = jset(a, "processes", jarr(unendable(g.get("processes"))))
      groups.push(a)
    }
  }
  let shown = JV::Obj(jfields(Some(chats)).filter(c => !nullish(c.1)))
  let cores = jitems(Some(self.backend.ask("os.cpus", []))).length()
  let memory = self.backend.ask("os.totalmem", [])
  let out = jset(
    jset(jset(shot, "groups", jarr(groups)), "chats", shown),
    "machine",
    jobj([("cores", jint(cores)), ("memory", memory)]),
  )
  ok(out)
}

///|
/// GET /resources as events: a `resources` event after each look while the stream is open.
async fn Admin::followed_resources(self : Admin, r : Request) -> Answer {
  let queue : Array[String] = []
  let closed = Ref(false)
  let telling = Ref(false)
  let again = Ref(false)
  let wake : Ref[@effect.Deferred[Unit]?] = Ref(None)
  let notify = () => {
    match wake.val {
      Some(w) => {
        wake.val = None
        ignore(w.succeed(()))
      }
      None => ()
    }
  }
  let tell = async fn() {
    if telling.val {
      again.val = true
      return
    }
    telling.val = true
    while true {
      again.val = false
      let a = Some(self.shown_to(r)) catch { _ => None }
      if !closed.val {
        match a {
          Some(a) if a.status == 200 => {
            queue.push("event: resources\ndata: \{a.text()}\n\n")
            notify()
          }
          _ => ()
        }
      }
      if !(again.val && !closed.val) {
        break
      }
    }
    telling.val = false
  }
  // Where processes are not read: what there is, once.
  let stop : Ref[JV?] = Ref(None)
  if self.setup.has("resources.watch") {
    stop.val = Some(
      self.backend.ask("resources.watch.follow", [
        self.callback(async fn(_) { tell() }),
      ]),
    )
  } else {
    self.later(tell)
  }
  let end = async fn() {
    if closed.val {
      return
    }
    closed.val = true
    match stop.val {
      Some(s) => self.backend.tell(ref_of(s).unwrap_or(""), [])
      None => ()
    }
    notify()
  }
  let next = async fn() {
    while !closed.val && queue.length() == 0 {
      let w = @effect.Deferred::new()
      wake.val = Some(w)
      w.wait()
    }
    wake.val = None
    if queue.length() == 0 {
      return None
    }
    Some(utf8(queue.remove(0)))
  }
  ignore(r)
  { status: 200, headers: event_headers(), body: Streamed(next, end), }
}

///|
/// GET /resources and the end of a chat's process, the resources part's.
fn Admin::resource_routes(self : Admin) -> Array[Route] {
  [
    route("GET", "^\\/resources$", async fn(r, _) {
      if header_exact(r.headers, "accept")
        .unwrap_or("")
        .contains("text/event-stream") {
        return self.followed_resources(r)
      }
      if self.setup.has("resources.watch") {
        self.backend.tell("resources.watch.want", [])
      }
      self.shown_to(r)
    }),
    route("POST", "^\\/resources\\/processes\\/(\\d+)\\/end$", async fn(r, m) {
      if !self.setup.has("resources.watch") {
        return error(404, "processes are not read here")
      }
      let session = if r.body.length() > 0 {
        match body_json(r) {
          Some(v) => jget(Some(v), "session")
          None => return error(400, "invalid JSON")
        }
      } else {
        None
      }
      guard session is Some(Str(session)) && session != "" else {
        return error(400, "session required")
      }
      // Its chat as the asker sees it: none (another workspace's), no such process for them.
      let named = self.read(
        r,
        "resourceChats",
        jobj([("sessions", jstrs([session])), ("viewer", r.viewer)]),
      )
      if named.status != 200 {
        return named
      }
      let chats = parse(named.text())
      if nullish(chats.get(session).unwrap_or(jundef)) {
        return error(404, "no such process")
      }
      let pid = js_number(m[0].unwrap())
      let ended = self.backend.ask("resources.watch.end", [
        jnum(pid),
        js(session),
      ]) catch {
        e =>
          match thrown_as(e, "NotEndable") {
            Some(_) => return error(409, message_of(e))
            None => raise e
          }
      }
      self.log(
        "info",
        "resources",
        "a chat's process ended from its station's page",
        jobj([
          ("pid", jnum(pid)),
          ("name", ended.get("name").unwrap_or(jundef)),
          ("session", js(session)),
          ("by", js(r.email())),
        ]),
      )
      ok(jspread(jobj([("pid", jnum(pid))]), ended))
    }),
  ]
}
