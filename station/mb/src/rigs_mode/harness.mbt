// These parts asked line by line (reader `--builder harness-rigs-mode`), as station/test/mb-rigs-mode.test.ts asks the
// TypeScript's (src/rig, src/rigs, src/elevation) the same cases. The test says `{id, op, ...}`, answered `{re: id, ok}`
// or `{re: id, error, kind, status?}`; several may be under way at once. Where a part asks the station (a world's call),
// the program says `{call, name, args}` and is answered `{re: call, result}` or `{re: call, threw, kind}`; asked
// meanwhile to run a callback it gave (`{cb, cid, args}`), it answers `{cbre: cid, result}` or `{cbre: cid, threw}`.
// What its parts tell the station that answers nothing (a grant ended, what stops, a socket ended, a script run) is kept
// as events the test takes (`events`). Time is the test's: `now` sets it, `pass` moves it on, firing what is due in turn.

///|
priv struct Timer {
  due : Double
  seq : Int
  f : () -> Unit
  mut off : Bool
}

///|
priv struct H {
  host : @host.Host
  crypto : @cloud_lock.Crypto
  now : Ref[Double]
  timers : Array[Timer]
  mut seq : Int
  pending : Map[Int, @effect.Deferred[Json]]
  mut next_call : Int
  callbacks : Map[Int, async (Array[Json]) -> Json]
  mut next_cb : Int
  events : Array[Json]
  // what the test's fakes are, mirrored (what the TypeScript asks of them at once)
  mut self_ : Json
  busy : Array[String]
  running : Array[Json]
  mut cloud : @cloud_lock.Cloud?
  mut grants : RigGrants?
  mut rig : Rig?
  mut rigs : Rigs?
  mut elev : Elevation?
  sockets : Map[String, Array[() -> Unit]]
  mut next_child : Int
  child_errors : Map[Int, Array[() -> Unit]]
  child_exits : Map[Int, Array[(Int?) -> Unit]]
  mut zh : Json
  mut en : Json
  mut random_text : String
}

///|
fn H::event(self : H, e : Array[Json]) -> Unit {
  self.events.push(jarr(e))
}

///|
fn H::spawn(self : H, f : async () -> Unit) -> Unit {
  self.host.rt.fork(f) |> ignore
}

///|
fn H::clock(self : H) -> Clock {
  {
    now: () => self.now.val,
    after: (ms, f) => {
      self.seq += 1
      let t : Timer = { due: self.now.val + ms, seq: self.seq, f, off: false }
      self.timers.push(t)
      () => t.off = true
    },
  }
}

///|
async fn H::call(self : H, name : String, args : Array[Json]) -> Json {
  self.next_call += 1
  let id = self.next_call
  let d : @effect.Deferred[Json] = @effect.Deferred::new()
  self.pending[id] = d
  self.host.say(stringify(jobj([("call", jnum(id.to_double())), ("name", jstr(name)), ("args", jarr(args))])))
  let answer = Some(d.wait())
  match get(answer, "threw") {
    Some(m) => {
      let kind = str_at(answer, "kind").unwrap_or("Error")
      let message = js_string_of(Some(m))
      if kind == "Refused" || kind == "Refusal" {
        raise Refused(message)
      }
      raise Thrown(kind, message)
    }
    None => get(answer, "result").unwrap_or(undefined_json())
  }
}

///|
fn H::world(self : H) -> World {
  {
    call: (name, args) => self.call(name, args),
    callback: f => {
      self.next_cb += 1
      self.callbacks[self.next_cb] = f
      jobj([("$cb", jnum(self.next_cb.to_double()))])
    },
  }
}

///|
/// Until nothing the program set going waits for the test: no call unanswered across some turns of its fibers.
async fn H::settle(self : H) -> Unit {
  let mut quiet = 0
  while quiet < 3 {
    for _ in 0..<50 {
      @effect.pause()
    }
    if self.pending.is_empty() {
      quiet += 1
    } else {
      quiet = 0
      @effect.sleep(1)
    }
  }
}

///|
/// The clock moved on `ms`, what falls due meanwhile fired in turn (each settled before the next).
async fn H::pass(self : H, ms : Double) -> Unit {
  let end = self.now.val + ms
  while true {
    let mut next : Timer? = None
    for t in self.timers {
      if !t.off && t.due <= end {
        match next {
          Some(n) if n.due < t.due || (n.due == t.due && n.seq < t.seq) => ()
          _ => next = Some(t)
        }
      }
    }
    match next {
      None => break
      Some(t) => {
        if t.due > self.now.val {
          self.now.val = t.due
        }
        t.off = true
        (t.f)()
        self.settle()
      }
    }
  }
  self.now.val = end
  let live = self.timers.filter(t => !t.off)
  self.timers.clear()
  self.timers.append(live)
}

///|
fn H::cloud_of(self : H) -> @cloud_lock.Cloud raise {
  match self.cloud {
    Some(c) => c
    None => raise Failure("no cloud opened")
  }
}

///|
fn arg(ask : Json, k : String) -> Json? {
  get(Some(ask), k)
}

///|
fn sarg(ask : Json, k : String) -> String {
  match arg(ask, k) {
    Some(String(s)) => s
    _ => ""
  }
}

///|
fn opt_arg(ask : Json, k : String) -> Json? {
  match arg(ask, k) {
    None | Some(Null) => None
    v => v
  }
}

///|
fn args_of(ask : Json) -> Array[Json] {
  arr_at(Some(ask), "args").unwrap_or([])
}

///|
fn nth(args : Array[Json], i : Int) -> Json? {
  match args.get(i) {
    None => None
    Some(v) => if is_undefined(v) { None } else { Some(v) }
  }
}

///|
fn nth_s(args : Array[Json], i : Int) -> String {
  match nth(args, i) {
    Some(String(s)) => s
    _ => ""
  }
}

///|
fn opt_s_json(s : String?) -> Json {
  match s {
    Some(x) => jstr(x)
    None => Json::null()
  }
}

///|
fn viewer_of(v : Json?) -> Viewer {
  {
    workspace: str_at(v, "workspace").unwrap_or(""),
    sub: str_at(v, "sub").unwrap_or(""),
    role: str_at(v, "role").unwrap_or(""),
    email: str_at(v, "email"),
    name: str_at(v, "name"),
  }
}

///|
fn answer_json(a : Answer?) -> Json {
  match a {
    None => Json::null()
    Some(x) => jobj([("status", jnum(x.status.to_double())), ("body", jstr(x.body))])
  }
}

///|
/// A number in base 36, as `n.toString(36)` writes a whole one.
pub fn base36(n : Double) -> String {
  let digits = "0123456789abcdefghijklmnopqrstuvwxyz"
  let mut v = n.floor().to_int64()
  if v == 0L {
    return "0"
  }
  let neg = v < 0L
  if neg {
    v = -v
  }
  let out = []
  while v > 0L {
    out.push(digits.unsafe_charcode_at((v % 36L).to_int()))
    v = v / 36L
  }
  let b = StringBuilder()
  if neg {
    b.write_char('-')
  }
  for i = out.length() - 1; i >= 0; i = i - 1 {
    b.write_char(out[i].unsafe_to_char())
  }
  b.to_string()
}

///|
/// A request's id as the station makes one (rigs/requests.ts): `r_`, the time in base 36, then six random letters.
pub fn request_id_of(now : Double, random : String) -> String {
  "r_\{base36(now)}\{random}"
}

///|
fn H::grants_deps(self : H, path : String) -> GrantsDeps {
  {
    path,
    self_: () => {
      let s = Some(self.self_)
      if self.self_ is Null {
        None
      } else {
        Some({
          id: str_at(s, "id").unwrap_or(""),
          workspace: str_at(s, "workspace").unwrap_or(""),
          owner: str_at(s, "owner").unwrap_or(""),
          person: str_at(s, "person").unwrap_or(""),
        })
      }
    },
    busy: (station, session) => self.busy.contains("\{station}/\{session}"),
    stop: (station, session) => self.event([jstr("stop"), jstr(station), jstr(session)]),
    running: () => {
      let out = []
      for r in self.running {
        if r is Array(xs) {
          out.push((nth_s(xs, 0), nth_s(xs, 1)))
        }
      }
      out
    },
    ended: e => self.event([jstr("ended"), e]),
    cut: Some((device, station, session) => self.event([jstr("cut"), jstr(device), opt_s_json(station), opt_s_json(session)])),
    changed: () => self.event([jstr("changed")]),
    clock: self.clock(),
    files: Files::of_host(self.host),
    crypto: self.crypto,
  }
}

///|
fn H::rig_deps(self : H, data : String) -> RigDeps raise {
  {
    data,
    cloud: self.cloud_of(),
    ask: (station, request) => self.call("bus.ask", [jstr(station), request]),
    busy: (ws, station, session) => self.busy.contains("\{ws}/\{station}/\{session}"),
    stop: (ws, station, session) => self.event([jstr("stop"), jstr(ws), jstr(station), jstr(session)]),
    running: () => {
      let out = []
      for r in self.running {
        if r is Array(xs) {
          out.push((nth_s(xs, 0), nth_s(xs, 1), nth_s(xs, 2)))
        }
      }
      out
    },
    reach: async fn(device) {
      let got = self.call("reach", [device])
      let id = js_string_of(Some(got))
      self.sockets[id] = []
      {
        destroy: () => self.event([jstr("destroy"), jstr(id)]),
        on_close: f => match self.sockets.get(id) {
          Some(fs) => fs.push(f)
          None => self.sockets[id] = [f]
        },
      }
    },
    spawn: f => self.spawn(f),
    clock: self.clock(),
    files: Files::of_host(self.host),
    crypto: self.crypto,
    host: self.host,
  }
}

///|
fn grants_of(h : H, inside : Bool) -> RigGrants raise {
  if inside {
    match h.rig {
      Some(r) => r.grants
      None => raise Failure("no rig")
    }
  } else {
    match h.grants {
      Some(g) => g
      None => raise Failure("no grants")
    }
  }
}

///|
fn grants_call(g : RigGrants, name : String, args : Array[Json]) -> Json raise {
  match name {
    "grant" => jobj([("until", jnum(g.grant(nth_s(args, 0), nth(args, 1), nth(args, 2))))])
    "revoke" => {
      g.revoke(nth(args, 0), nth(args, 1))
      undefined_json()
    }
    "release" => jbool(g.release(nth_s(args, 0), nth_s(args, 1)))
    "settings" => {
      g.take_settings(nth(args, 0), nth(args, 1))
      undefined_json()
    }
    "device" => {
      g.device(nth(args, 0), nth(args, 1))
      undefined_json()
    }
    "devices" => jarr(g.devices())
    "deviceRefusal" =>
      opt_s_json(
        g.device_refusal(nth_s(args, 0), nth_s(args, 1), nth_s(args, 2), nth_s(args, 3), use_=!(nth(args, 4) is Some(False))),
      )
    "added" => {
      g.added(nth(args, 0))
      undefined_json()
    }
    "full" => g.full(nth(args, 0), nth(args, 1))
    "proof" => g.proof().unwrap_or(Json::null())
    "open" => jbool(g.open())
    "refusal" => opt_s_json(g.refusal(nth_s(args, 0), nth_s(args, 1), nth_s(args, 2)))
    "stationRefusal" => opt_s_json(g.station_refusal(nth_s(args, 0), nth_s(args, 1)))
    "view" => g.view().unwrap_or(Json::null())
    "takeChain" => {
      g.take_chain(nth(args, 0))
      undefined_json()
    }
    "close" => {
      g.close()
      undefined_json()
    }
    _ => raise Failure("no such grants method \{name}")
  }
}

///|
fn requests_of(h : H) -> RigRequests raise {
  match h.rigs {
    Some(r) => r.requests
    None => raise Failure("no rigs")
  }
}

///|
fn rigs_of(h : H) -> Rigs raise {
  match h.rigs {
    Some(r) => r
    None => raise Failure("no rigs")
  }
}

///|
fn device_sel(v : Json?) -> DeviceSel {
  match v {
    None => RigItself
    Some(Null) => Either
    Some(String("*")) => AnyDevice
    Some(x) => OneDevice(js_string_of(Some(x)))
  }
}

///|
async fn H::requests_call(self : H, name : String, args : Array[Json]) -> Json {
  let q = requests_of(self)
  let list = (rs : Array[RigRequest]) => jarr(rs.map(request_json))
  match name {
    "get" =>
      match q.get(nth_s(args, 0)) {
        Some(r) => request_json(r)
        None => Json::null()
      }
    "of" => list(q.of(nth_s(args, 0), nth_s(args, 1), device=nth(args, 2).map(v => js_string_of(Some(v)))))
    "ofRig" => list(q.of_rig(nth_s(args, 0), nth_s(args, 1)))
    "undelivered" => list(q.undelivered(nth_s(args, 0), nth_s(args, 1)))
    "deliver" =>
      match nth(args, 0) {
        Some(Object(m)) => {
          q.deliver(m)
          undefined_json()
        }
        _ => raise Failure("no request")
      }
    "decide" =>
      opt_s_json(q.decide(nth_s(args, 0), nth_s(args, 1), nth_s(args, 2), opt_null(nth(args, 3)), nth(args, 4)))
    "revoke" =>
      opt_s_json(q.revoke(nth_s(args, 0), nth_s(args, 1), nth_s(args, 2), opt_null(nth(args, 3)), nth(args, 4)))
    "release" => {
      let rig = match nth(args, 1) {
        Some(String(s)) => Some(s)
        _ => None
      }
      let sel = if args.length() > 2 { device_sel(nth(args, 2)) } else { Either }
      let sel = if args.length() > 2 && args[2] is Null { Either } else { sel }
      list(q.release(nth_s(args, 0), rig, device=sel))
    }
    "endedThere" => {
      q.ended_there(nth_s(args, 0), nth_s(args, 1))
      undefined_json()
    }
    "heldThere" => {
      let until = match nth(args, 1) {
        Some(Number(n, ..)) => n
        _ => 0.0
      }
      q.held_there(nth_s(args, 0), until)
      undefined_json()
    }
    "cardPending" =>
      match nth(args, 0) {
        Some(Object(m)) =>
          match q.card_pending(m) {
            None => Json::null()
            Some(b) => jbool(b)
          }
        _ => raise Failure("no request")
      }
    "ask" => {
      let device = match nth(args, 5) {
        Some(d) => Some((str_at(Some(d), "id").unwrap_or(""), str_at(Some(d), "name").unwrap_or("")))
        None => None
      }
      request_json(
        q.ask(nth_s(args, 0), nth(args, 1).unwrap_or(Json::null()), nth_s(args, 2), nth_s(args, 3), nth(args, 4), device~),
      )
    }
    "said" =>
      match nth(args, 0) {
        Some(Object(m)) => jstr(said(m))
        _ => raise Failure("no request")
      }
    _ => raise Failure("no such requests method \{name}")
  }
}

///|
fn opt_null(v : Json?) -> Json? {
  match v {
    Some(Null) => None
    _ => v
  }
}

///|
async fn H::op(self : H, op : String, ask : Json) -> Json {
  let args = args_of(ask)
  match op {
    // ── the harness ──
    "now" => {
      self.now.val = num_at(Some(ask), "ms").unwrap_or(0.0)
      Json::null()
    }
    "pass" => {
      self.pass(num_at(Some(ask), "ms").unwrap_or(0.0))
      Json::null()
    }
    "settle" => {
      self.settle()
      Json::null()
    }
    "events" => {
      let out = self.events.copy()
      self.events.clear()
      jarr(out)
    }
    "mirror" => {
      if arg(ask, "self") is Some(s) {
        self.self_ = s
      }
      if arr_at(Some(ask), "busy") is Some(b) {
        self.busy.clear()
        for x in b {
          self.busy.push(js_string_of(Some(x)))
        }
      }
      if arr_at(Some(ask), "running") is Some(r) {
        self.running.clear()
        self.running.append(r)
      }
      if sarg(ask, "random") != "" {
        self.random_text = sarg(ask, "random")
      }
      Json::null()
    }
    "words" => {
      self.zh = arg(ask, "zh").unwrap_or(jobj([]))
      self.en = arg(ask, "en").unwrap_or(jobj([]))
      Json::null()
    }
    // ── what is pure ──
    "wellFormed" => jbool(well_formed(sarg(ask, "kind"), opt_arg(ask, "signed")))
    "timeoutRefusal" => opt_s_json(timeout_refusal(arg(ask, "t")))
    "deviceRefusal" => opt_s_json(device_refusal(arg(ask, "d")))
    "latest" => jnum(latest(num_at(Some(ask), "at").unwrap_or(0.0), arg(ask, "timeout")))
    "signatureHolds" => jbool(signature_holds(self.crypto, sarg(ask, "kind"), arg(ask, "signed")))
    "signedBytes" => jstr(@cloud_lock.hex_of(signed_bytes(sarg(ask, "kind"), arg(ask, "body").unwrap_or(Json::null()))))
    "lasting" => jstr(lasting(arg(ask, "t")))
    "said" =>
      match arg(ask, "r") {
        Some(Object(m)) => jstr(said(m))
        _ => Json::null()
      }
    "ownerOf" => jstr(owner_of(sarg(ask, "workspace"), sarg(ask, "station"), sarg(ask, "session")))
    "owned" =>
      match owned(sarg(ask, "key")) {
        Some((w, s, x)) => jobj([("workspace", jstr(w)), ("station", jstr(s)), ("session", jstr(x))])
        None => Json::null()
      }
    "diskTier" => jstr(disk_tier(num_at(Some(ask), "free").unwrap_or(0.0), num_at(Some(ask), "total").unwrap_or(0.0)))
    "diskSoft" => jnum(disk_soft(num_at(Some(ask), "total").unwrap_or(0.0)))
    "diskEvery" => jnum(disk_every(sarg(ask, "tier")))
    "portsToTry" => {
      let int = (k : String) => num_at(Some(ask), k).map(n => n.to_int())
      jarr(
        ports_to_try(int("named"), int("remembered"), int("usual").unwrap_or(0), bool_at(Some(ask), "own") == Some(true)).map(p => jnum(
          p.to_double(),
        )),
      )
    }
    "askScript" => jstr(ask_script(sarg(ask, "apply"), bool_at(Some(ask), "elevate") == Some(true)))
    "applyScript" =>
      jstr(
        apply_script(
          run=sarg(ask, "run"),
          data=sarg(ask, "data"),
          task=sarg(ask, "task"),
          on=bool_at(Some(ask), "on") == Some(true),
          deadline=num_at(Some(ask), "deadline").unwrap_or(0.0),
          restart=bool_at(Some(ask), "restart") == Some(true),
          runner=sarg(ask, "runner"),
        ),
      )
    "restartScript" =>
      jstr(
        restart_script(
          run=sarg(ask, "run"),
          data=sarg(ask, "data"),
          app=sarg(ask, "app"),
          task=sarg(ask, "task"),
          on=bool_at(Some(ask), "on") == Some(true),
        ),
      )
    "pathJoin" => jstr(path_join(arr_at(Some(ask), "parts").unwrap_or([]).map(p => js_string_of(Some(p)))))
    "iso" => jstr(iso(num_at(Some(ask), "ms").unwrap_or(0.0)))
    "requestId" => jstr(request_id_of(num_at(Some(ask), "now").unwrap_or(0.0), sarg(ask, "random")))
    "rigUse" => rig_use()
    "addRefusal" => {
      let entries = arr_at(Some(ask), "entries").unwrap_or([])
      let lock = @cloud_lock.fold(self.crypto, entries, None)
      let keys = arg(ask, "personKeys")
      opt_s_json(
        add_refusal(
          self.crypto,
          opt_arg(ask, "signed"),
          sarg(ask, "ws"),
          arg(ask, "rig").unwrap_or(Json::null()),
          lock,
          (g, _) => arr_at(keys, g).unwrap_or([]).map(k => js_string_of(Some(k))),
          num_at(Some(ask), "now").unwrap_or(0.0),
        ),
      )
    }
    // ── a Cloud on a data directory ──
    "cloud.open" => {
      let now = self.now
      self.cloud = Some(@cloud_lock.Cloud::new(self.host, sarg(ask, "data"), self.crypto, () => now.val))
      Json::null()
    }
    "cloud.update" => {
      let c = self.cloud_of()
      let set = match arg(ask, "set") {
        Some(Object(m)) => js_entries(m)
        _ => []
      }
      let remove = arr_at(Some(ask), "remove").unwrap_or([]).map(k => js_string_of(Some(k)))
      c.update(st => {
        for e in set {
          st.fields[e.0] = e.1
        }
        for k in remove {
          st.fields.remove(k)
        }
      })
      Json::null()
    }
    "cloud.takeLock" => {
      let c = self.cloud_of()
      let ws = opt_arg(ask, "ws").map(w => js_string_of(Some(w)))
      jnum(c.take_lock(arr_at(Some(ask), "entries").unwrap_or([]), ws~).to_double())
    }
    "cloud.state" =>
      match self.cloud_of().state {
        Some(s) => s.to_json()
        None => Json::null()
      }
    // ── the rig's grants on their own ──
    "grants.new" => {
      self.grants = Some(RigGrants::new(self.grants_deps(sarg(ask, "path"))))
      Json::null()
    }
    "grants" => grants_call(grants_of(self, false), sarg(ask, "name"), args)
    // ── the rig ──
    "rig.new" => {
      self.rig = Some(Rig::new(self.rig_deps(sarg(ask, "data"))))
      Json::null()
    }
    "rig.grants" => grants_call(grants_of(self, true), sarg(ask, "name"), args)
    "rig.attached" => {
      self.rig.unwrap().attached()
      Json::null()
    }
    "rig.self" =>
      match self.rig.unwrap().self_() {
        Some(s) =>
          jobj([("id", jstr(s.id)), ("workspace", jstr(s.workspace)), ("owner", jstr(s.owner)), ("person", jstr(s.person))])
        None => Json::null()
      }
    "rig.described" => self.rig.unwrap().described()
    "rig.guard" => {
      self.rig.unwrap().guarded(sarg(ask, "workspace"), sarg(ask, "peer"), arg(ask, "request").unwrap_or(Json::null()))
      undefined_json()
    }
    "rig.heard" =>
      self.rig.unwrap().heard(sarg(ask, "peer"), arg(ask, "request").unwrap_or(Json::null()), sarg(ask, "workspace"))
    "rig.stationRefusal" => opt_s_json(self.rig.unwrap().station_refusal(sarg(ask, "peer"), sarg(ask, "workspace")))
    "rig.device" =>
      match
        mesh_device(
          self.rig,
          sarg(ask, "peer"),
          sarg(ask, "workspace"),
          sarg(ask, "session"),
          sarg(ask, "device"),
          bool_at(Some(ask), "probe") == Some(true),
        ) {
        Some(_) => jbool(true)
        None => Json::null()
      }
    "rig.socketClosed" => {
      match self.sockets.get(sarg(ask, "socket")) {
        Some(fs) => {
          self.sockets.remove(sarg(ask, "socket"))
          for f in fs {
            f()
          }
        }
        None => ()
      }
      Json::null()
    }
    "rig.log" => jarr(self.rig.unwrap().commands.last(num_at(Some(ask), "limit").unwrap_or(50.0).to_int()))
    "rig.written" => {
      self.rig.unwrap().commands.written()
      Json::null()
    }
    "rig.close" => {
      self.rig.unwrap().close()
      Json::null()
    }
    "mesh.allowed" => opt_s_json(mesh_allowed(self.rig, sarg(ask, "peer"), sarg(ask, "workspace")))
    // ── the workspace's rigs ──
    "rigs.new" => {
      let db = @sql.Db::create(self.host, sarg(ask, "db"), wait=5000)
      let now = self.now
      let rigs = Rigs::new({
        cloud: self.cloud_of(),
        db,
        world: self.world(),
        card_outcomes: bool_at(Some(ask), "cardOutcomes") == Some(true),
        crypto: self.crypto,
        now: () => now.val,
        within: async fn(_, f, _) { f() },
        spawn: f => self.spawn(f),
        id: () => request_id_of(now.val, self.random_text),
      })
      self.rigs = Some(rigs)
      // (as RigsLive is wired: the cloud's changes, the bus attached)
      rigs.listen() |> ignore
      Json::null()
    }
    "rigs.look" => {
      rigs_of(self).look()
      Json::null()
    }
    "rigs.heardRig" => rigs_of(self).heard_rig(sarg(ask, "peer"), arg(ask, "request").unwrap_or(Json::null()), opt_arg(ask, "workspace").map(w => js_string_of(Some(w))))
    "rigs.rigAdd" => rigs_of(self).rig_add(arg(ask, "request").unwrap_or(Json::null()), opt_arg(ask, "workspace").map(w => js_string_of(Some(w))))
    "rigs.tool" => {
      let rigs = rigs_of(self)
      let use_ : RigUse = {
        ask: (session, rig, reason, timeout) => rigs.use_ask(session, rig, reason, timeout),
        done: (session, rig) => rigs.use_done(session, rig),
      }
      jstr(rig_use_run(use_, sarg(ask, "session"), arg(ask, "args").unwrap_or(jobj([]))))
    }
    "rigs.stationListed" =>
      rigs_of(self).station_listed(sarg(ask, "workspace"), sarg(ask, "session"), arg(ask, "rig").unwrap_or(Json::null()), opt_arg(ask, "answer"))
    "rigs.deviceList" => jarr(rigs_of(self).device_entries(sarg(ask, "workspace"), sarg(ask, "session")))
    "rigs.deviceUse" =>
      jstr(
        rigs_of(self).device_use(sarg(ask, "workspace"), sarg(ask, "session"), arg(ask, "entry").unwrap_or(Json::null()), sarg(ask, "reason"), opt_arg(ask, "timeout")),
      )
    "rigs.deviceDone" =>
      jarr(rigs_of(self).device_done(sarg(ask, "session"), opt_arg(ask, "entry")).map(jstr))
    "rigs.listed" => jarr(rigs_of(self).listed(sarg(ask, "workspace")))
    "rigs.route" => {
      let query = arr_at(Some(ask), "query").unwrap_or([]).map(q => match q {
        Array(xs) => (nth_s(xs, 0), nth_s(xs, 1))
        _ => ("", "")
      })
      let body = sarg(ask, "body")
      answer_json(
        rigs_of(self).route(sarg(ask, "method"), sarg(ask, "path"), query, body, @cloud_lock.utf8_of(body).length(), viewer_of(arg(ask, "viewer"))),
      )
    }
    "rigs.storeChanged" => {
      requests_of(self).store_changed(arg(ask, "change").unwrap_or(Json::null()))
      Json::null()
    }
    "rigs.requests" => self.requests_call(sarg(ask, "name"), args)
    "rigs.flush" => jbool(rigs_of(self).flush(sarg(ask, "ws"), sarg(ask, "rig")))
    "rigs.vouched" => {
      let rigs = rigs_of(self)
      jbool(rigs.adds.holds(sarg(ask, "ws"), arg(ask, "rig").unwrap_or(Json::null())))
    }
    "rigs.close" => {
      rigs_of(self).close()
      Json::null()
    }
    // ── running as administrator ──
    "elev.new" => {
      let now = self.now
      self.elev = Some(
        Elevation::new({
          data: sarg(ask, "data"),
          app: sarg(ask, "app"),
          now: () => now.val,
          after: self.clock().after,
          changed: () => self.event([jstr("changed")]),
          probe: async fn() {
            let got = Some(self.call("probe", []))
            (bool_at(got, "elevated") == Some(true), bool_at(got, "admin") == Some(true))
          },
          run: script => {
            self.next_child += 1
            let id = self.next_child
            self.event([jstr("run"), jnum(id.to_double()), jstr(script)])
            self.child_errors[id] = []
            self.child_exits[id] = []
            {
              kill: () => self.event([jstr("kill"), jnum(id.to_double())]),
              on_error: f => self.child_errors.get(id).unwrap().push(f),
              on_exit: f => self.child_exits.get(id).unwrap().push(f),
            }
          },
          files: ElevationFiles::of_host(self.host),
        }),
      )
      Json::null()
    }
    "elev.start" => {
      self.elev.unwrap().start()
      Json::null()
    }
    "elev.stop" => {
      self.elev.unwrap().stop()
      Json::null()
    }
    "elev.view" => self.elev.unwrap().view(bool_at(Some(ask), "manage") == Some(true))
    "elev.on" => jbool(self.elev.unwrap().on())
    "elev.kept" => self.elev.unwrap().kept().unwrap_or(Json::null())
    "elev.change" => {
      self.elev.unwrap().change(bool_at(Some(ask), "on") == Some(true))
      Json::null()
    }
    "elev.exit" => {
      let id = num_at(Some(ask), "child").unwrap_or(0.0).to_int()
      let code = num_at(Some(ask), "code").map(n => n.to_int())
      for f in self.child_exits.get(id).unwrap_or([]) {
        f(code)
      }
      Json::null()
    }
    "elev.error" => {
      let id = num_at(Some(ask), "child").unwrap_or(0.0).to_int()
      for f in self.child_errors.get(id).unwrap_or([]) {
        f()
      }
      Json::null()
    }
    "elev.route" => {
      let lang = sarg(ask, "lang")
      let tr = (key : String) => {
        let words = if lang == "en" { self.en } else { self.zh }
        match get(Some(words), key) {
          Some(String(t)) => t
          _ =>
            match get(Some(self.zh), key) {
              Some(String(t)) => t
              _ => key
            }
        }
      }
      answer_json(
        elevation_route(self.elev.unwrap(), sarg(ask, "method"), sarg(ask, "path"), sarg(ask, "body"), viewer_of(arg(ask, "viewer")), tr),
      )
    }
    "elev.overview" => elevation_overview(self.elev.unwrap(), viewer_of(arg(ask, "viewer")))
    _ => raise Failure("no such op: \{op}")
  }
}

///|
fn error_kind(e : Error) -> String {
  match e {
    Refused(_) => "Refused"
    Thrown(k, _) => k
    DeviceRefused(_, _) => "DeviceRefused"
    ChangeRefused(_) => "ChangeRefused"
    _ => "Error"
  }
}

///|
fn error_json(re : Json, e : Error) -> Json {
  let out = [("re", re), ("error", jstr(error_message(e))), ("kind", jstr(error_kind(e)))]
  match e {
    DeviceRefused(status, m) => {
      out[1] = ("error", jstr(m))
      out.push(("status", jnum(status.to_double())))
    }
    ChangeRefused(key) => out.push(("key", jstr(key)))
    _ => ()
  }
  jobj(out)
}

///|
/// The program's harness: what the test says, a line at a time, until stdin ends.
pub async fn harness(host : @host.Host) -> Unit {
  let h : H = {
    host,
    crypto: @cloud_lock.Crypto::of_host(host),
    now: Ref(0.0),
    timers: [],
    seq: 0,
    pending: Map([]),
    next_call: 0,
    callbacks: Map([]),
    next_cb: 0,
    events: [],
    self_: Json::null(),
    busy: [],
    running: [],
    cloud: None,
    grants: None,
    rig: None,
    rigs: None,
    elev: None,
    sockets: Map([]),
    next_child: 0,
    child_errors: Map([]),
    child_exits: Map([]),
    zh: jobj([]),
    en: jobj([]),
    random_text: "",
  }
  while host.line() is Some(line) {
    guard parse(line) is Some(msg) else { continue }
    let m = Some(msg)
    if num_at(m, "re") is Some(re) {
      match h.pending.get(re.to_int()) {
        Some(d) => {
          h.pending.remove(re.to_int())
          d.succeed(msg) |> ignore
        }
        None => ()
      }
      continue
    }
    if num_at(m, "cb") is Some(cb) {
      let cid = get(m, "cid").unwrap_or(Json::null())
      let args = arr_at(m, "args").unwrap_or([])
      h.spawn(async fn() {
        let reply = match h.callbacks.get(cb.to_int()) {
          Some(f) =>
            try {
              jobj([("cbre", cid), ("result", f(args))])
            } catch {
              e => jobj([("cbre", cid), ("threw", jstr(error_message(e))), ("kind", jstr(error_kind(e)))])
            }
          None => jobj([("cbre", cid), ("threw", jstr("no callback \{cb}")), ("kind", jstr("Error"))])
        }
        h.host.say(stringify(reply))
      })
      continue
    }
    let re = get(m, "id").unwrap_or(Json::null())
    let op = str_at(m, "op").unwrap_or("")
    h.spawn(async fn() {
      let answer = try {
        jobj([("re", re), ("ok", h.op(op, msg))])
      } catch {
        e => error_json(re, e)
      }
      h.host.say(stringify(answer))
    })
  }
}
