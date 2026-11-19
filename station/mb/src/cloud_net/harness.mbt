// What station/test/mb-cloud-net.test.ts gives the same inputs as the TypeScript it replaces (reader `--builder
// harness-cloud-net`): a JSON line a case on stdin, a JSON line its outcome on stdout (`{"ok": …}` or `{"error": …}`).
// Each case is worked out whole on its own (its cloud, its files in memory, its clock), so its outcome is a function of
// what it was given alone.

///|
fn opt_json(s : String?) -> Json {
  match s {
    Some(t) => Json::string(t)
    None => Json::null()
  }
}

///|
fn rec_json(r : WaysRecord?) -> Json {
  match r {
    Some(r) => r.to_json()
    None => Json::null()
  }
}

///|
fn num(j : Json?) -> Int64 {
  safe_int(j).unwrap_or(0L)
}

///|
/// A case's cloud: its cloud.json (`state`), its roster current or not.
fn case_cloud(c : Json) -> StateCloud {
  let s = StateCloud::new(field(c, "state"))
  match field(c, "peersCurrent") {
    Some(False) => s.peers_current = false
    Some(True) => s.peers_current = true
    _ => ()
  }
  s
}

///|
fn refusal(f : () -> Json raise) -> Json {
  try {
    { "ok": f() }
  } catch {
    e => { "error": Json::string(error_words_all(e)) }
  }
}

///|
/// An error's words, refusals' too.
fn error_words_all(e : Error) -> String {
  match e {
    WaysRefusal(m) => m
    MarkRefusal(m) => m
    _ => error_words(e)
  }
}

///|
fn url_case_json(raw : String) -> Json {
  match parse_url(raw) {
    Some(u) =>
      Json::array(
        [u.href(), u.origin(), u.path, u.search(), u.hash()].map(Json::string),
      )
    None => Json::null()
  }
}

///|
fn spec_json(s : ProviderSpec) -> Json {
  {
    "provider": Json::string(s.provider.name()),
    "name": Json::string(s.name),
    "enrollPath": Json::string(s.enroll_path),
    "enrollPrefixes": Json::array(s.enroll_prefixes.map(Json::string)),
    "joinPath": Json::string(s.join_path),
    "connectPath": Json::string(s.connect_path),
    "connectPrefixes": Json::array(s.connect_prefixes.map(Json::string)),
    "notifyPath": Json::string(s.notify_path),
    "notifyTag": Json::string(s.notify_tag),
    "telemetry": match s.telemetry {
      Some(t) =>
        {
          "path": Json::string(t.path),
          "logs": opt_json(t.logs),
          "prefixes": Json::array(t.prefixes.map(Json::string)),
        }
      None => Json::null()
    },
    "releaseBase": Json::string(s.release_base("https://o.example")),
    "credential": {
      "issuers": Json::array(s.credential.issuers.map(Json::string)),
      "types": Json::array(s.credential.types.map(Json::string)),
    },
    "feedback": Json::boolean(s.feedback),
    "pages": Json::boolean(s.pages),
    "tools": Json::boolean(s.tools),
  }
}

///|
/// The pure functions, each by its TypeScript name.
fn pure_case(c : Json) -> Json raise {
  let args = array_of(field(c, "args")).unwrap_or([])
  let arg = (i : Int) => if i < args.length() { Some(args[i]) } else { None }
  match text_of(field(c, "fn")).unwrap_or("") {
    "url" => url_case_json(text_of(arg(0)).unwrap_or(""))
    "sameUrl" => Json::string(same_url(text_of(arg(0)).unwrap_or("")))
    "relayUrl" =>
      opt_json(
        relay_url(arg(0).unwrap_or(Json::null()), insecure=arg(1) is Some(True)),
      )
    "recordOf" => rec_json(record_of(arg(0)))
    "markName" => opt_json(mark_name(arg(0)))
    "markEmoji" => opt_json(mark_emoji(arg(0)))
    "markIcon" => opt_json(mark_icon(arg(0)))
    "markOf" =>
      match mark_of(arg(0)) {
        Some(r) => r.to_json()
        None => Json::null()
      }
    "signedHeaders" => {
      let prefixes = strings_of(arg(0))
      let station = text_of(arg(1)).unwrap_or("")
      let ts = num(arg(2))
      let extra = match arg(3) {
        Some(Object(m)) =>
          m.to_array().map(kv => (kv.0, text_of(Some(kv.1)).unwrap_or("")))
        _ => []
      }
      signed_headers(prefixes, station, ts, p => "signed:\{p}:\{station}:\{ts}", extra~).to_json()
    }
    "cloudEntry" =>
      match cloud_entry(arg(0).unwrap_or(Json::null())) {
        Some(e) =>
          {
            "origin": Json::string(e.origin),
            "host": Json::string(e.host),
            "port": Json::number(e.port.to_double()),
          }
        None => Json::null()
      }
    "providerOf" => Json::string(provider_of(arg(0)).name())
    "specOf" =>
      spec_json(spec_of(provider_of(Some(arg(0).unwrap_or(Json::null())))))
    "failureText" =>
      Json::string(
        failure_text({
          message: text_of(arg(0)).unwrap_or(""),
          errors: strings_of(arg(1)),
        }),
      )
    "sha256" => Json::string(@hash.sha256_utf8_hex(text_of(arg(0)).unwrap_or("")))
    "rigsOf" => Json::array(rigs_of(arg(0)))
    "joinedOf" => Json::array(joined_of(arg(0)))
    "waysSaidOf" =>
      match ways_said_of(arg(0)) {
        Some(w) => w.to_json()
        None => Json::null()
      }
    "isRevocation" => Json::boolean(is_revocation(arg(0).unwrap_or(Json::null())))
    "cloudSaid" => {
      let told = []
      let said_is = cloud_said(arg(0).unwrap_or(Json::null()), s => told.push(s.to_json()))
      { "is": Json::boolean(said_is), "told": Json::array(told) }
    }
    "otlpBody" =>
      Json::string(
        otlp_body(text_of(arg(0)).unwrap_or(""), array_of(arg(1)).unwrap_or([])),
      )
    f => raise NetError("no such function: \{f}")
  }
}

///|
/// What the ways of a case's cloud come to: each workspace's view and record, its relays on and off, the relays kept,
/// how each peer is dialed and held.
fn ways_summary(ways : Ways, peers : Array[String]) -> Json {
  let per : Map[String, Json] = Map([])
  for m in (ways.cloud.memberships)() {
    per[m.workspace] = {
      "view": ways.view(m.workspace).to_json(),
      "record": rec_json(ways.record(m.workspace)),
      "on": Json::array(workspace_relays(ways, m.workspace).map(Json::string)),
      "off": Json::array(off_relays(ways, m.workspace).map(Json::string)),
    }
  }
  let addr : Map[String, Json] = Map([])
  let held : Map[String, Json] = Map([])
  for p in peers {
    addr[p] = station_addr(ways, p).to_json()
    let d = peer_disabled(ways, p)
    held[p] = {
      "disabled": match d {
        Some(d) => d.to_json()
        None => Json::null()
      },
      "key": Json::string(disabled_key(d)),
    }
  }
  {
    "workspaces": Json::object(per),
    "stillFails": Json::array(still_fails(ways.cloud).map(Json::string)),
    "relays": Json::array(ways.relays().map(Json::string)),
    "wanted": Json::array(wanted_relays(ways).map(Json::string)),
    "oursOff": Json::boolean(ours_off(ways)),
    "addr": Json::object(addr),
    "held": Json::object(held),
  }
}

///|
/// A case of the ways: its steps one after another, each change at its own `now`, each outcome said; then what they
/// came to, and the file as written last.
fn ways_case(c : Json) -> Json {
  let cloud = case_cloud(c)
  let (store, file) = Kept::memory(text?=text_of(field(c, "kept")))
  let clock = Ref(num(field(c, "now")))
  let ways = Ways::new(cloud.view(), store, () => clock.val)
  let told = []
  let stop = ways.listen(ws => told.push(Json::string(ws)))
  let outcomes = []
  for step in array_of(field(c, "steps")).unwrap_or([]) {
    match safe_int(field(step, "now")) {
      Some(n) => clock.val = n
      None => ()
    }
    let ws = text_of(field(step, "ws")).unwrap_or("")
    let by = text_of(field(step, "by"))
    let outcome = refusal(() => match text_of(field(step, "do")).unwrap_or("") {
      "add" =>
        add_relay(ways, ws, text_of(field(step, "url")).unwrap_or(""), by).to_json()
      "remove" =>
        remove_relay(ways, ws, text_of(field(step, "url")).unwrap_or("")).to_json()
      "set" =>
        set_relays(ways, ws, array_of(field(step, "urls")).unwrap_or([]), by).to_json()
      "setWay" =>
        set_way(
          ways,
          ws,
          text_of(field(step, "way")).unwrap_or(""),
          field(step, "on") is Some(True),
        ).to_json()
      "take" =>
        match record_of(field(step, "record")) {
          Some(r) => Json::boolean(ways.take(ws, r))
          None => Json::null()
        }
      "answer" =>
        answer_ways(ways, field(step, "request").unwrap_or(Json::null()), ws)
      "state" => {
        cloud.state.unwrap().clear()
        match field(step, "state") {
          Some(Object(m)) => for k, v in m { cloud.state.unwrap()[k] = v }
          _ => ()
        }
        cloud.tell()
        Json::null()
      }
      d => raise NetError("no such step: \{d}")
    })
    outcomes.push(outcome)
  }
  stop()
  let peers = strings_of(field(c, "peers"))
  {
    "steps": Json::array(outcomes),
    "told": Json::array(told),
    "summary": ways_summary(ways, peers),
    "file": match file.val {
      Some(t) => (try Some(@json.parse(t)) catch { _ => None }).unwrap_or(Json::null())
      None => Json::null()
    },
  }
}

///|
fn marks_of_json(marks : StationMarks) -> Json {
  let per : Map[String, Json] = Map([])
  for m in (marks.cloud.memberships)() {
    per[m.workspace] = {
      "stations": Json::array(marks.stations_of(m.workspace).map(Json::string)),
      "of": marks_json(marks.of(m.workspace)),
    }
  }
  Json::object(per)
}

///|
fn opt_field(step : Json, name : String) -> Json?? {
  match step {
    Object(m) => if m.contains(name) { Some(m.get(name)) } else { None }
    _ => None
  }
}

///|
/// A case of the marks, as of the ways.
fn marks_case(c : Json) -> Json {
  let cloud = case_cloud(c)
  let (store, file) = Kept::memory(text?=text_of(field(c, "kept")))
  let clock = Ref(num(field(c, "now")))
  let marks = StationMarks::new(cloud.view(), store, () => clock.val)
  let told = []
  let stop = marks.listen(s => told.push(Json::string(s)))
  let outcomes = []
  for step in array_of(field(c, "steps")).unwrap_or([]) {
    match safe_int(field(step, "now")) {
      Some(n) => clock.val = n
      None => ()
    }
    let outcome = refusal(() => match text_of(field(step, "do")).unwrap_or("") {
      "change" => {
        let was = field(step, "was").unwrap_or(Json::null())
        let w = (k : String) => text_of(field(was, k)).unwrap_or("")
        marks
        .change(
          name?=opt_field(step, "name"),
          emoji?=opt_field(step, "emoji"),
          icon?=opt_field(step, "icon"),
          (w("name"), w("emoji"), w("icon")),
        )
        .to_json()
      }
      "take" =>
        match mark_of(field(step, "record")) {
          Some(r) =>
            Json::boolean(marks.take(text_of(field(step, "station")).unwrap_or(""), r))
          None => Json::null()
        }
      "answer" =>
        answer_marks(
          marks,
          field(step, "request").unwrap_or(Json::null()),
          text_of(field(step, "ws")).unwrap_or(""),
        )
      d => raise NetError("no such step: \{d}")
    })
    outcomes.push(outcome)
  }
  stop()
  {
    "steps": Json::array(outcomes),
    "told": Json::array(told),
    "of": marks_of_json(marks),
    "file": match file.val {
      Some(t) => (try Some(@json.parse(t)) catch { _ => None }).unwrap_or(Json::null())
      None => Json::null()
    },
  }
}

// ── time a case's own ──

///|
/// A case's clock and timers: what is due fires in the order it was set, `advance` moving the clock.
priv struct FakeTime {
  mut now : Int64
  mut seq : Int
  waits : Array[(Int64, Int, () -> Unit)]
}

///|
fn FakeTime::new() -> FakeTime {
  { now: 0L, seq: 0, waits: [] }
}

///|
fn FakeTime::after(self : FakeTime) -> After {
  {
    after: (ms, f) => {
      self.seq += 1
      let id = self.seq
      self.waits.push((self.now + ms.to_int64(), id, f))
      fn() {
        match self.waits.search_by(w => w.1 == id) {
          Some(i) => ignore(self.waits.remove(i))
          None => ()
        }
      }
    },
  }
}

///|
/// The clock moved on to `to`, each wait due fired at its own time, in order.
fn FakeTime::advance(self : FakeTime, to : Int64) -> Unit {
  while true {
    let mut best = -1
    for i, w in self.waits {
      if w.0 <= to &&
        (best < 0 ||
        w.0 < self.waits[best].0 ||
        (w.0 == self.waits[best].0 && w.1 < self.waits[best].1)) {
        best = i
      }
    }
    if best < 0 {
      break
    }
    let w = self.waits.remove(best)
    if w.0 > self.now {
      self.now = w.0
    }
    (w.2)()
  }
  if to > self.now {
    self.now = to
  }
}

///|
/// A dial's case: its candidates told what the script says at its times; what was dialed, destroyed and the outcome.
fn dial_case(c : Json) -> Json raise {
  let time = FakeTime::new()
  let timers = time.after()
  let entry = match field(c, "entry") {
    Some(Object(_)) as e =>
      cloud_entry({ "cloudEntry": e.unwrap() })
    _ => None
  }
  let budget = num(field(c, "budget")).to_int()
  let throws = strings_of(field(c, "throws"))
  let attempts : Array[(TlsSocket, TlsEvents)] = []
  let trace : Array[Json] = []
  let io = {
    after: timers.after,
    tls: (host, port, servername, events) => {
      let i = attempts.length()
      trace.push({
        "t": int_json(time.now),
        "dial": Json::number(i.to_double()),
        "host": Json::string(host),
        "port": Json::number(port.to_double()),
        "servername": Json::string(servername),
      })
      if i < throws.length() && throws[i] != "" {
        attempts.push(({ id: i, host, port, destroy: () => () }, events))
        raise NetError(throws[i])
      }
      let s = {
        id: i,
        host,
        port,
        destroy: () => trace.push({
          "t": int_json(time.now),
          "destroy": Json::number(i.to_double()),
        }),
      }
      attempts.push((s, events))
      s
    },
  }
  let done = (r : Result[TlsSocket, DialError]) => trace.push(
    match r {
      Ok(s) => { "t": int_json(time.now), "won": Json::number(s.id.to_double()) }
      Err(e) =>
        {
          "t": int_json(time.now),
          "error": Json::string(e.message),
          "errors": Json::array(e.errors.map(Json::string)),
        }
    },
  )
  let cancel = dial_cloud(io, cloud_origin, entry, budget, done)
  for step in array_of(field(c, "script")).unwrap_or([]) {
    time.advance(num(field(step, "at")))
    if field(step, "cancel") is Some(True) {
      cancel()
      continue
    }
    let i = num(field(step, "i")).to_int()
    if i >= attempts.length() {
      trace.push({ "t": int_json(time.now), "missing": Json::number(i.to_double()) })
      continue
    }
    let (_, events) = attempts[i]
    match text_of(field(step, "ev")) {
      Some("secure") => (events.secure)()
      Some("error") => (events.error)(text_of(field(step, "msg")).unwrap_or(""))
      _ => ()
    }
  }
  time.advance(num(field(c, "until")))
  { "trace": Json::array(trace), "waiting": Json::number(time.waits.length().to_double()) }
}

///|
/// A case of bringing stations level (`follow`: "ways" or "marks"): this station and its peers each a store of their
/// own, calls answered by the peer's own answer after `delay` ms unless it is down then (`down`: [from, to) spans) or
/// answers as one from before (`before`); changes made at their times. Every call, its answer and what each came to.
fn follow_case(c : Json) -> Json {
  let time = FakeTime::new()
  let timers = time.after()
  let kind = text_of(field(c, "follow")).unwrap_or("ways")
  let cloud = case_cloud(c)
  let (store, _) = Kept::memory(text?=text_of(field(c, "kept")))
  let ways = Ways::new(cloud.view(), store, () => time.now)
  let marks = StationMarks::new(cloud.view(), Kept::memory(text?=text_of(field(c, "kept"))).0, () => time.now)
  // The peers: each a cloud of its own (its id its station) and its store.
  let peer_ways : Map[String, Ways] = Map([])
  let peer_marks : Map[String, StationMarks] = Map([])
  let peer_cfg : Map[String, Json] = Map([])
  match field(c, "peers") {
    Some(Object(ps)) =>
      for id, cfg in ps {
        let pc = StateCloud::new(field(cfg, "state"))
        peer_ways[id] = Ways::new(pc.view(), Kept::memory(text?=text_of(field(cfg, "kept"))).0, () => time.now)
        peer_marks[id] = StationMarks::new(pc.view(), Kept::memory(text?=text_of(field(cfg, "kept"))).0, () => time.now)
        peer_cfg[id] = cfg
      }
    _ => ()
  }
  let trace : Array[Json] = []
  let call = {
    call: (peer : String, ws : String?, request : Json, done : (Result[Json, String]) -> Unit) => {
      let cfg = peer_cfg.get(peer).unwrap_or(Json::null())
      let at = time.now
      trace.push({
        "t": int_json(at),
        "peer": Json::string(peer),
        "ws": opt_json(ws),
        "request": request,
      })
      let delay = num(field(cfg, "delay")).to_int()
      ignore(
        (timers.after)(delay, fn() {
          let down = array_of(field(cfg, "down"))
            .unwrap_or([])
            .iter()
            .any(span => {
              let s = array_of(Some(span)).unwrap_or([])
              s.length() == 2 && num(Some(s[0])) <= at && at < num(Some(s[1]))
            })
          let answer = if field(cfg, "before") is Some(True) {
            Err("unknown method")
          } else if down {
            Err("the peer is offline")
          } else {
            let asked_in = match ws {
              Some(w) => w
              None => text_of(field(cfg, "home")).unwrap_or("")
            }
            try {
              Ok(
                if kind == "ways" {
                  answer_ways(peer_ways[peer], request, asked_in)
                } else {
                  answer_marks(peer_marks[peer], request, asked_in)
                },
              )
            } catch {
              e => Err(error_words(e))
            }
          }
          trace.push({
            "t": int_json(time.now),
            "peer": Json::string(peer),
            "answer": match answer {
              Ok(a) => a
              Err(e) => { "error": Json::string(e) }
            },
          })
          done(answer)
        }),
      )
    },
  }
  let stop = if kind == "ways" {
    follow_ways(ways, call, timers)
  } else {
    follow_marks(marks, call, timers)
  }
  for ev in array_of(field(c, "events")).unwrap_or([]) {
    time.advance(num(field(ev, "at")))
    let ws = text_of(field(ev, "ws")).unwrap_or("")
    match text_of(field(ev, "do")).unwrap_or("") {
      "add" =>
        ignore(
          (try Some(add_relay(ways, ws, text_of(field(ev, "url")).unwrap_or(""), None)) catch {
            _ => None
          }),
        )
      "mark" =>
        ignore(
          (try Some(marks.change(name=field(ev, "name"), ("", "", ""))) catch {
            _ => None
          }),
        )
      "roster" => {
        match field(ev, "state") {
          Some(Object(m)) => {
            cloud.state.unwrap().clear()
            for k, v in m {
              cloud.state.unwrap()[k] = v
            }
          }
          _ => ()
        }
        match field(ev, "peersCurrent") {
          Some(True) => cloud.peers_current = true
          Some(False) => cloud.peers_current = false
          _ => ()
        }
        cloud.tell()
      }
      "stop" => stop()
      _ => ()
    }
  }
  time.advance(num(field(c, "until")))
  stop()
  let peers_now : Map[String, Json] = Map([])
  for id, w in peer_ways {
    peers_now[id] = if kind == "ways" {
      let per : Map[String, Json] = Map([])
      for m in (w.cloud.memberships)() {
        per[m.workspace] = rec_json(w.record(m.workspace))
      }
      Json::object(per)
    } else {
      marks_of_json(peer_marks[id])
    }
  }
  let mine = if kind == "ways" {
    let per : Map[String, Json] = Map([])
    for m in (ways.cloud.memberships)() {
      per[m.workspace] = rec_json(ways.record(m.workspace))
    }
    Json::object(per)
  } else {
    marks_of_json(marks)
  }
  {
    "trace": Json::array(trace),
    "mine": mine,
    "peers": Json::object(peers_now),
    "waiting": Json::number(time.waits.length().to_double()),
  }
}

///|
/// A case of the plane's frames: each applied in turn at its `now` (s), what the state came to after it, what was sent
/// back, and the roster's flags.
fn frames_case(c : Json) -> Json {
  let cloud = case_cloud(c)
  let clock = Ref(num(field(c, "now")))
  let grants_gone = Ref(0)
  let p = PlaneCloud::new(cloud, () => clock.val, rig_grants_gone=() => grants_gone.val += 1)
  let out : Array[Json] = []
  for f in array_of(field(c, "frames")).unwrap_or([]) {
    match safe_int(field(f, "now")) {
      Some(n) => clock.val = n
      None => ()
    }
    let sent = []
    match field(f, "text") {
      Some(String(t)) => apply_state(p, t, frame => sent.push(frame))
      _ => apply_frame(p, field(f, "frame").unwrap_or(Json::null()), frame => sent.push(frame))
    }
    out.push({
      "state": match cloud.state {
        Some(m) => state_json(m)
        None => Json::null()
      },
      "sent": Json::array(sent),
      "peersCurrent": Json::boolean(cloud.peers_current),
      "reached": Json::boolean(p.reached),
      "rostersSaid": Json::number(p.rosters_said.to_double()),
      "planeLockSeq": match p.plane_lock_seq {
        Some(n) => Json::number(n.to_double())
        None => Json::null()
      },
      "grantsGone": Json::number(grants_gone.val.to_double()),
      "memberships": Json::array(
        cloud.memberships().map(m => Json::string(m.workspace)),
      ),
    })
  }
  Json::array(out)
}

///|
/// cloud.json's object as state.ts writes it (`stateText`): what is empty or absent left out.
pub fn state_json(s : Map[String, Json]) -> Json {
  let out : Map[String, Json] = Map([])
  if s.get("provider") is Some(v) {
    out["provider"] = v
  }
  for k in [
    "origin", "station", "workspace", "workspace_name", "name", "relay_url", "relay_urls",
    "grant_keys", "peers", "revocations",
  ] {
    match s.get(k) {
      Some(v) => out[k] = v
      None => ()
    }
  }
  for k in [
    "stillfail_relays", "mesh_relays", "gateway_keys", "removed_at", "removed_code",
  ] {
    match s.get(k) {
      Some(v) => out[k] = v
      None => ()
    }
  }
  match s.get("joined") {
    Some(Array(a)) if a.length() > 0 => out["joined"] = Json::array(a)
    _ => ()
  }
  match s.get("rigs") {
    Some(Array(a)) if a.length() > 0 => out["rigs"] = Json::array(a)
    _ => ()
  }
  for k in ["ways", "rig", "rig_pending"] {
    match s.get(k) {
      Some(v) => out[k] = v
      None => ()
    }
  }
  if s.get("rig_due") is Some(True) {
    out["rig_due"] = Json::boolean(true)
  }
  if s.get("full_pending") is Some(v) {
    out["full_pending"] = v
  }
  Json::object(out)
}

///|
/// Another station on this key: each socket's end and hold in turn, what it came to and what it told.
fn replaced_case(c : Json) -> Json {
  let told = []
  let r = Replaced::new(told=b => told.push(Json::boolean(b)))
  let out : Array[Json] = []
  for ev in array_of(field(c, "events")).unwrap_or([]) {
    if field(ev, "steady") is Some(True) {
      r.steady()
    } else {
      let code = match field(ev, "code") {
        Some(Number(n, ..)) => Some(n.to_int())
        _ => None
      }
      r.ended(code, field(ev, "held") is Some(True))
    }
    out.push({
      "inARow": Json::number(r.in_a_row.to_double()),
      "conflict": Json::boolean(r.conflict),
    })
  }
  { "after": Json::array(out), "told": Json::array(told) }
}

///|
/// The ways told the plane on one socket: changes made and the socket open or not, at each step what was sent.
fn ways_teller_case(c : Json) -> Json {
  let cloud = case_cloud(c)
  let (store, _) = Kept::memory(text?=text_of(field(c, "kept")))
  let ways = Ways::new(cloud.view(), store, () => num(field(c, "now")))
  let open = Ref(true)
  let sent = []
  let tell = ways_teller(ways, f => sent.push(f), () => open.val)
  let out = []
  for step in array_of(field(c, "steps")).unwrap_or([]) {
    match field(step, "open") {
      Some(True) => open.val = true
      Some(False) => open.val = false
      _ => ()
    }
    match record_of(field(step, "take")) {
      Some(r) => ignore(ways.take(text_of(field(step, "ws")).unwrap_or(""), r))
      None => ()
    }
    tell()
    out.push(Json::array(sent.copy()))
    sent.clear()
  }
  Json::array(out)
}

///|
/// One case by its `op`.
pub fn harness_case(c : Json) -> Json {
  try {
    let ok = match text_of(field(c, "op")).unwrap_or("") {
      "pure" => pure_case(c)
      "ways" => ways_case(c)
      "marks" => marks_case(c)
      "dial" => dial_case(c)
      "follow" => follow_case(c)
      "frames" => frames_case(c)
      "replaced" => replaced_case(c)
      "waysTeller" => ways_teller_case(c)
      op => raise NetError("no such case: \{op}")
    }
    { "ok": ok }
  } catch {
    e => { "error": Json::string(error_words_all(e)) }
  }
}

///|
/// The program's harness: a case a line, answered a line each, until stdin ends.
pub async fn harness(host : @host.Host) -> Unit {
  while true {
    guard host.line() is Some(line) else { break }
    let answer : Json = match (try Some(@json.parse(line)) catch { _ => None }) {
      Some(c) if text_of(field(c, "op")) == Some("hostEntry") =>
        try {
          { "ok": host_entry_case(host, c) }
        } catch {
          e => { "error": Json::string(error_words_all(e)) }
        }
      Some(c) => harness_case(c)
      None => { "error": "not JSON" }
    }
    host.say(answer.stringify())
  }
}

///|
/// A dial, a request and a WebSocket through the real shell (`host_dial_io`, `host_http`, `host_ws`): `origin`'s
/// direct candidate and the case's entry raced as the transport races them, an HTTP request `over` the route that won
/// and a WebSocket opened over it with `headers`, which sends `send` and is read until its first message.
async fn host_entry_case(host : @host.Host, c : Json) -> Json {
  let origin = text_of(field(c, "origin")).unwrap_or(cloud_origin)
  let entry = match field(c, "entry") {
    Some(Object(m)) =>
      Some({
        origin: cloud_origin,
        host: text_of(m.get("host")).unwrap_or(""),
        port: num(m.get("port")).to_int(),
      })
    _ => None
  }
  let got : @effect.Deferred[Result[TlsSocket, DialError]] = @effect.Deferred::new()
  ignore(
    dial_cloud(
      host_dial_io(host, origin~),
      origin,
      entry,
      num(field(c, "budget")).to_int(),
      r => ignore(got.succeed(r)),
    ),
  )
  let socket = match got.wait() {
    Ok(s) => s
    Err(e) =>
      return {
        "dialError": Json::string(e.message),
        "errors": Json::array(e.errors.map(Json::string)),
      }
  }
  let http = host_http(host)
  let answer = (http.over)(
    {
      url: origin + text_of(field(c, "path")).unwrap_or("/"),
      http_method: "GET",
      headers: Headers::new(),
      body: None,
      timeout_ms: 10_000,
    },
    socket,
  )
  let headers = Headers::new()
  for p in array_of(field(c, "headers")).unwrap_or([]) {
    match p {
      Array([String(k), String(v)]) => headers.set(k, v)
      _ => ()
    }
  }
  let heard : @effect.Queue[Json] = @effect.Queue::unbounded()
  let ws = (host_ws(host).open)(
    text_of(field(c, "ws")).unwrap_or(""),
    headers,
    Some(socket),
    {
      open: () => ignore(heard.try_offer({ "open": true })),
      message: m => ignore(heard.try_offer({ "message": Json::string(m) })),
      unexpected: status => ignore(heard.try_offer({ "unexpected": int_json(status.to_int64()) })),
      error: e => ignore(heard.try_offer({ "error": Json::string(e) })),
      close: (code, _) => ignore(heard.try_offer({ "close": int_json(code.to_int64()) })),
    },
  )
  let told : Array[Json] = []
  while true {
    let e = heard.take()
    told.push(e)
    match e {
      Object(m) if m.get("open") is Some(_) =>
        (ws.send)(text_of(field(c, "send")).unwrap_or(""))
      Object(m) if m.get("message") is Some(_) => {
        (ws.close)()
        break
      }
      Object(m) if m.get("close") is Some(_) => break
      _ => ()
    }
  }
  {
    "won": { "host": Json::string(socket.host), "port": int_json(socket.port.to_int64()) },
    "http": { "status": int_json(answer.status.to_int64()), "body": Json::string(answer.body) },
    "ws": Json::array(told),
  }
}
