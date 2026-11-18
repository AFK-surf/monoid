// The functions the test holds to their TypeScript by name (harness.mbt `call`), on the keeper that asks the test.

///|
/// The keeper that asks the test (`{"keeper": n, "fn", "args"}` said, `{"op": "kept", "n", "value"|"error"}` heard).
fn Harness::the_keeper(self : Harness) -> @gate.Keeper {
  match self.keeper {
    Some(k) => k
    None => {
      let host = self.host
      let k = @gate.Keeper::asking(
        async fn(name, args) {
          self.asks += 1
          let n = self.asks
          let d = @effect.Deferred::new()
          self.asked[n] = d
          host.say(({ "keeper": Json::number(n.to_double()), "fn": Json::string(name), "args": args } : Json).stringify())
          d.wait()
        },
        () => self.now,
        {
          oldest_core: floor_of(self.floors, "oldest_core"),
          counted_from: floor_of(self.floors, "counted_from"),
          moved_from: floor_of(self.floors, "moved_from"),
          root_out_from: floor_of(self.floors, "root_out_from"),
          logs_before: floor_of(self.floors, "logs_before"),
          logs_any_from: floor_of(self.floors, "logs_any_from"),
        },
        (message, key, sig) => {
          let said = host.shell_sync("crypto.verify", {
            "alg": "Ed25519",
            "key": Json::string(@hex.encode(key)),
            "signature": Json::string(@hex.encode(sig)),
            "message": Json::string(@hex.encode(message)),
          }) catch {
            _ => Json::boolean(false)
          }
          said == Json::boolean(true)
        },
        @gate.SeenDevices::new(None, _ => ()),
        f => {
          self.listeners.push(f)
          () => match self.listeners.search_by(g => physical_equal(g, f)) {
            Some(i) => ignore(self.listeners.remove(i))
            None => ()
          }
        },
        f => {
          self.listeners.push(f)
          () => match self.listeners.search_by(g => physical_equal(g, f)) {
            Some(i) => ignore(self.listeners.remove(i))
            None => ()
          }
        },
      )
      self.keeper = Some(k)
      k
    }
  }
}

///|
fn arg(line : Json, k : String) -> Json {
  match line {
    { "args": Object(m), .. } => m.get(k).unwrap_or(Json::null())
    _ => Json::null()
  }
}

///|
fn arg_str(line : Json, k : String) -> String {
  match arg(line, k) {
    String(s) => s
    _ => ""
  }
}

///|
fn arg_opt(line : Json, k : String) -> String? {
  match arg(line, k) {
    String(s) => Some(s)
    _ => None
  }
}

///|
fn status_json(said : (Int, Json)) -> Json {
  [Json::number(said.0.to_double()), said.1]
}

///|
fn query_of(j : Json) -> Array[(String, String)] {
  match j {
    Array(a) =>
      a.filter_map(p => match p {
        Array([String(k), String(v)]) => Some((k, v))
        _ => None
      })
    _ => []
  }
}

///|
async fn Harness::calls(self : Harness, line : Json) -> Json {
  let k = self.the_keeper()
  let f = match line { { "fn": String(f), .. } => f; _ => "" }
  let viewer = () => @gate.Viewer::from_json(arg(line, "viewer"))
  let admitted = () => @gate.Admitted::from_json(arg(line, "admitted"))
  let body = () => @utf8.encode(arg_str(line, "body"))
  match f {
    "inLock" => @gate.in_lock(k, admitted(), arg_str(line, "named"), arg_str(line, "endpoint"), hello=arg(line, "hello")).to_json()
    "stillIn" => @gate.still_in(k, admitted(), arg_str(line, "named"), arg_str(line, "endpoint")).to_json()
    "inLockBringing" => @gate.in_lock_bringing(k, admitted(), arg_str(line, "named"), arg_str(line, "endpoint"), arg(line, "hello")).to_json()
    "lockRoute" => status_json(@gate.lock_route(k, arg_str(line, "method"), query_of(arg(line, "query")), body(), viewer()))
    "lockPartRoute" => status_json(@gate.lock_part_route(k, arg_str(line, "part"), arg_str(line, "method"), body(), viewer()))
    "waysRoute" => status_json(@gate.ways_route(k, arg_str(line, "method"), body(), viewer()))
    "stationMarksRoute" => status_json(@gate.station_marks_route(k, arg_str(line, "method"), body(), viewer(), arg(line, "own") == Json::boolean(true)))
    "ownChainsOf" =>
      Json::array(
        @gate.own_chains_of(k, arg_str(line, "sub"), arg_opt(line, "workspace")).map(c => Json::array([Json::string(c.0), Json::array(c.1)])),
      )
    "movedFloor" =>
      match @gate.moved_floor(k, arg_str(line, "workspace")) {
        Some(f) => Json::number(f.to_double())
        None => Json::null()
      }
    "refusalOf" => {
      let e : Error = match arg(line, "error") {
        { "lock": True, "message": String(m), .. } => @gate.LockRefusal(m)
        { "message": String(m), .. } => @gate.Refused(m)
        _ => @gate.Refused("")
      }
      @gate.refusal_of(k, arg(line, "hello"), arg_str(line, "device"), e, (k.accepted)(), arg_opt(line, "sub"))
    }
    "verifyMemberOf" => {
      let keys = arg(line, "keys")
      let memberships = match arg(line, "memberships") {
        Array(a) =>
          a.map(m => ({
            workspace: match m { { "workspace": String(w), .. } => w; _ => "" },
            revocations: match m {
              { "revocations": Array(rs), .. } =>
                rs.map(r => ({
                  kind: match r { { "kind": String(s), .. } => s; _ => "" },
                  id: match r { { "id": String(s), .. } => s; _ => "" },
                  at: match r { { "at": Number(t, ..), .. } => t.to_int64(); _ => 0L },
                } : @gate.Revocation))
              _ => []
            },
          } : @gate.Membership))
        _ => []
      }
      @gate.verify_member_of(arg_str(line, "credential"), _ => keys, memberships, arg_str(line, "device"), self.now, k.verify).to_json()
    }
    "buildOf" =>
      match @gate.build_of(arg_opt(line, "said")) {
        Some(b) => Json::number(b.to_double())
        None => Json::null()
      }
    "route" => Json::string(@gate.route_of(arg_str(line, "path")))
    "readsOf" => Json::boolean(@gate.reads_of(arg_str(line, "method"), arg_str(line, "path")))
    "queryPairs" => Json::array(@gate.query_pairs(arg_str(line, "query")).map(p => Json::array([Json::string(p.0), Json::string(p.1)])))
    "lowerRole" => Json::string(@gate.lower_role(arg_str(line, "a"), arg_str(line, "b")))
    "answerLock" => @gate.answer_lock(k, arg(line, "request"), arg_opt(line, "workspace"), arg_opt(line, "peer"))
    "member" => Json::string(@gate.peer_member(k, arg_str(line, "peer"), arg_opt(line, "workspace")))
    "roster" => @gate.roster(k, arg_opt(line, "workspace"))
    "heardWaiting" => Json::boolean(@gate.heard_waiting(k, Some(arg(line, "method"))))
    "syncWith" => {
      @gate.sync_with(k, self.peer_asking(), arg_str(line, "peer"), arg_opt(line, "ws"))
      Json::null()
    }
    "personSyncWith" => {
      @gate.person_sync_with(k, self.peer_asking(), arg_str(line, "peer"), arg_str(line, "ws"))
      Json::null()
    }
    "bodiesSyncWith" => {
      @gate.bodies_sync_with(k, self.peer_asking(), arg_str(line, "peer"), arg_str(line, "ws"))
      Json::null()
    }
    "storms" => storms_run(line)
    "superseded" => superseded_run(line)
    "seen" => seen_run(line)
    _ => raise @door.DoorError("no function \{f}")
  }
}

///|
fn floor_of(floors : Json, k : String) -> Int {
  match floors {
    Object(m) => match m.get(k) { Some(Number(n, ..)) => n.to_int(); _ => 0 }
    _ => 0
  }
}

///|
/// A connection of the test's: its id, and what it says of itself as the script goes (its stats at each look, whether it
/// answers), what was done to it written down.
fn scripted(id : String, stats : Ref[Map[String, Double]?], answers : Bool, closes : Array[Json], log_id : String) -> @door.Connection {
  let closed = Ref(false)
  let done : @effect.Deferred[String] = @effect.Deferred::new()
  {
    remote_id: () => id,
    alpn: () => "",
    via: () => None,
    paths: Some(() => [{ selected: true, relay: None, ip: Some("10.0.0.1:1"), rtt_ms: Some(12.4), tx_packets: 3.0, lost_packets: 0.0 }]),
    accept_bi: async fn() -> @door.Stream? { None },
    open_bi: async fn() -> @door.Stream { raise @door.DoorError("none") },
    answers: Some(async fn(_ms : Int) -> Bool { answers }),
    stats: match stats.val {
      Some(_) => Some(() => stats.val.unwrap_or(Map([])))
      None => None
    },
    close: (code, reason) => if !closed.val {
      closed.val = true
      closes.push(({ "conn": Json::string(log_id), "code": Json::number(code.to_double()), "reason": Json::string(reason) } : Json))
      ignore(done.succeed(reason))
    },
    is_closed: () => closed.val,
    closed: async fn() -> String { done.wait() },
    close_reason: None,
    handed: None,
  }
}

///|
fn stats_of(j : Json) -> Map[String, Double]? {
  match j {
    Object(m) => {
      let out = Map([])
      for k, v in m {
        if v is Number(n, ..) {
          out[k] = n
        }
      }
      Some(out)
    }
    _ => None
  }
}

///|
/// Storms (storms.mbt) over a script: connections each with its stats at each look (`looks[i]`, by connection, at
/// the ms given); what was closed and said.
fn storms_run(line : Json) -> Json {
  let now = Ref(0L)
  let said = []
  @door.set_log((level, _part, words, with_) => said.push(([Json::string(level), Json::string(words), with_] : Json)))
  let storms = @gate.Storms::new(() => now.val)
  let closes = []
  let conns = match arg(line, "conns") { Array(a) => a; _ => [] }
  let refs = []
  for c in conns {
    let id = match c { { "id": String(s), .. } => s; _ => "" }
    let first = match c { { "first": f, .. } => stats_of(f); _ => None }
    let r = Ref(first)
    refs.push(r)
    storms.watch(scripted(id, r, true, closes, id))
  }
  let watched = storms.size()
  for look in match arg(line, "looks") { Array(a) => a; _ => [] } {
    now.val = match look { { "at": Number(t, ..), .. } => t.to_int64(); _ => now.val }
    match look {
      { "stats": Array(ss), .. } =>
        for i, st in ss {
          if i < refs.length() {
            refs[i].val = stats_of(st)
          }
        }
      _ => ()
    }
    storms.look()
  }
  @door.set_log((_, _, _, _) => ())
  { "watched": Json::number(watched.to_double()), "closes": Json::array(closes), "said": Json::array(said) }
}

///|
/// Superseded (superseded.mbt): connections arriving in turn, each of an id and answering or not; what was closed.
async fn superseded_run(line : Json) -> Json {
  let sup = @gate.Superseded::new()
  let closes = []
  let said = []
  @door.set_log((level, _part, words, with_) => said.push(([Json::string(level), Json::string(words), with_] : Json)))
  let made = []
  for c in match arg(line, "arrive") { Array(a) => a; _ => [] } {
    let id = match c { { "id": String(s), .. } => s; _ => "" }
    let name = match c { { "name": String(s), .. } => s; _ => "" }
    let answers = c is { "answers": True, .. }
    let conn = scripted(id, Ref(None), answers, closes, name)
    made.push(conn)
    match c {
      { "closeBefore": Number(i, ..), .. } => (made[i.to_int()].close)(0, "done")
      _ => ()
    }
    sup.arrived(conn)
  }
  @door.set_log((_, _, _, _) => ())
  let open = Map([])
  for c in made {
    let id = (c.remote_id)()
    open[id] = Json::number(sup.of(id).to_double())
  }
  { "closes": Json::array(closes), "said": Json::array(said), "open": Json::object(open) }
}

///|
/// SeenDevices (seen.mbt): what came, then what is read, and what was written last.
fn seen_run(line : Json) -> Json {
  let written = Ref("")
  let kept = match arg(line, "kept") { String(s) => Some(s); _ => None }
  let seen = @gate.SeenDevices::new(kept, text => written.val = text)
  let reads = []
  for step in match arg(line, "steps") { Array(a) => a; _ => [] } {
    let s = (k : String) => match step { Object(m) => match m.get(k) { Some(String(v)) => v; _ => "" }; _ => "" }
    let t = match step { { "at": Number(n, ..), .. } => n.to_int64(); _ => 0L }
    match step {
      { "saw": True, .. } =>
        seen.saw(t, s("workspace"), s("sub"), s("email"), s("device"), match step { { "base": String(b), .. } => Some(b); _ => None }, match step { { "said": v, .. } => v; _ => Json::null() })
      _ =>
        reads.push(Json::array(seen.of(s("workspace"), t, s("sub"), step is { "manages": True, .. }).map(r => r.to_json())))
    }
  }
  { "reads": Json::array(reads), "written": if written.val == "" { Json::null() } else { @json.parse(written.val) catch { _ => Json::null() } } }
}

///|
/// What the station's admin API is in the member scenario (the test's twin, word for word): what it was asked, said
/// back; with `big` in its query, that many items more.
pub async fn echo_admin(ask : @gate.AdminAsk) -> @door.Answer {
  let big = match ask.query.iter().find_first(kv => kv.0 == "big") {
    Some(kv) => @string.parse_int(kv.1) catch { _ => 0 }
    None => 0
  }
  let hs : Map[String, Json] = Map([])
  for kv in ask.headers {
    hs[kv.0] = Json::string(kv.1)
  }
  let said : Json = {
    "method": Json::string(ask.verb),
    "path": Json::string(ask.path),
    "query": Json::array(ask.query.map(p => Json::array([Json::string(p.0), Json::string(p.1)]))),
    "search": Json::string(ask.search),
    "headers": Json::object(hs),
    "body": Json::string(@utf8.decode_lossy(ask.body)),
    "viewer": ask.viewer.to_json(),
    "lang": Json::string(ask.lang),
    "items": Json::array(Array::makei(big, i => Json::string("item \{i} said again and again"))),
  }
  { status: 200, headers: [("content-type", "application/json")], body: Whole(@utf8.encode(said.stringify())) }
}

///|
/// The station's members as the member scenario serves them: the keeper that asks the test, the echoing admin API.
fn Harness::members(self : Harness, words : Map[String, Json]) -> @gate.Members {
  {
    keeper: self.the_keeper(),
    packer: shell_packer(self.host),
    up: () => true,
    admin: ask => echo_admin(ask),
    remember_name: (_, _) => (),
    streams: None,
    screens: None,
    socket: None,
    traces: None,
    lan: () => [],
    tailnet: () => ["100.64.0.9:7"],
    connected: () => (),
    served: None,
    lang_of: hs => @gate.lang_of_core(hs),
    update_words: lang => match words.get(lang) { Some(String(w)) => w; _ => "" },
    leaves: None,
  }
}

///|
/// A station call answered by the test (its keeper's `peerAsk`: another TypeScript station answering it).
fn Harness::peer_asking(self : Harness) -> @gate.PeerCall {
  let k = self.the_keeper()
  ignore(k)
  async fn(station, ws, request, _bytes) {
    self.asks += 1
    let n = self.asks
    let d = @effect.Deferred::new()
    self.asked[n] = d
    self.host.say(({
      "keeper": Json::number(n.to_double()),
      "fn": "peerAsk",
      "args": { "station": Json::string(station), "ws": match ws { Some(w) => Json::string(w); None => Json::null() }, "request": request },
    } : Json).stringify())
    let said = d.wait() catch { e => raise @gate.PeerRefused(@gate.words_of(e)) }
    (said, None)
  }
}
