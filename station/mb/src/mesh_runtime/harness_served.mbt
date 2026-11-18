// The served programs' keeper in the harness (station/test/mb-mesh-runtime.test.ts plays the same to the TypeScript's
// `Served`): programs, time and the station's answers of the test's, every message each program is told and every
// call made kept, given the test after each step it says (`served` `{op}`).

///|
priv struct ServedWorld {
  rt : @effect.Runtime
  served : Served
  processes : Array[(Array[String], Array[Json], Ref[Bool], Ref[((Json) -> Unit, (Int) -> Unit)?])]
  calls : Array[Json]
  logs : Array[Json]
  now : Ref[Double]
  due : Array[(Double, () -> Unit, Ref[Bool])]
  relays : Map[Int, ((String) -> Unit, () -> Unit)]
  pieces : Map[Int, Array[Json]]
  piece_waiting : Map[Int, @effect.Deferred[Json]]
  settles : Map[String, (Handled?) -> Unit]
  mut claims : Int
  mut started : Json?
}

///|
fn served_world(a : Json) -> ServedWorld {
  let rt = @effect.Runtime::new()
  let processes = []
  let calls = []
  let logs = []
  let now = Ref(num_of(arg(a, "now")).unwrap_or(0.0))
  let due : Array[(Double, () -> Unit, Ref[Bool])] = []
  let relays : Map[Int, ((String) -> Unit, () -> Unit)] = Map([])
  let pieces : Map[Int, Array[Json]] = Map([])
  let piece_waiting : Map[Int, @effect.Deferred[Json]] = Map([])
  let wall = num_of(arg(a, "wall")).unwrap_or(0.0)
  let w : ServedWith = {
    spawn: (binary, args, said, exited) => {
      let told = []
      let ended = Ref(false)
      let hooks = Ref(Some((said, exited)))
      let index = processes.length()
      processes.push((args, told, ended, hooks))
      calls.push(Json::array([jstr("spawn"), jstr(binary), Json::array(args.map(jstr))]))
      {
        post: m => told.push(m),
        terminate: async fn() {
          calls.push(Json::array([jstr("terminate"), jnum(index.to_double())]))
          // (a test's program ends as it is told to: its exit said at once, 0)
          if hooks.val is Some((_, exit)) {
            exit(0)
          }
        },
      }
    },
    now: () => now.val,
    after: (ms, f) => {
      let off = Ref(false)
      due.push((now.val + ms, f, off))
      () => off.val = true
    },
    wall: () => wall,
    answer: async fn(viewer, head, body) {
      calls.push(Json::array([jstr("answer"), viewer, head, jstr(@utf8.decode_lossy(body[:]))]))
      if field(head, "fail") is Some(String(m)) {
        raise Failure(m)
      }
      { status: 200, headers: jobj([("x", jstr("y"))]), body: @utf8.encode("answered") }
    },
    built: (viewer, build) => calls.push(Json::array([jstr("built"), viewer, opt_json(build)])),
    stream: Some(async fn(viewer, head, body) {
      calls.push(Json::array([jstr("stream"), viewer, head, jstr(@utf8.decode_lossy(body[:]))]))
      let n = num_of(field(head, "n")).unwrap_or(0.0).to_int()
      match str_of(field(head, "kind")).unwrap_or("") {
        "fail" => raise Failure("no stream here")
        "whole" => { status: 200, headers: jobj([]), body: Whole(@utf8.encode(str_of(field(head, "text")).unwrap_or(""))) }
        "relay" =>
          {
            status: 200,
            headers: jobj([("content-type", jstr("text/event-stream"))]),
            body: Relay((send, ended) => relays[n] = (send, ended), () => calls.push(Json::array([jstr("relay stopped"), jnum(n.to_double())]))),
          }
        _ => {
          pieces[n] = []
          {
            status: 200,
            headers: jobj([]),
            body: Pieces(
              async fn() -> Bytes? {
                let q = pieces.get(n).unwrap_or([])
                let next = if q.length() > 0 {
                  q.remove(0)
                } else {
                  let d : @effect.Deferred[Json] = @effect.Deferred::new()
                  piece_waiting[n] = d
                  d.wait()
                }
                match next {
                  String(t) => Some(@utf8.encode(t))
                  _ => None
                }
              },
              async fn() { calls.push(Json::array([jstr("pieces stopped"), jnum(n.to_double())])) },
            ),
          }
        }
      }
    }),
    prepare: _ => (),
    remove: async fn(_) {  },
    set: () => jstr("<set>"),
    pid: num_of(arg(a, "pid")).unwrap_or(0.0).to_int(),
    sep: str_of(arg(a, "sep")).unwrap_or("/"),
    log: (level, part, words, with_) => logs.push(jobj([("level", jstr(level)), ("at", jstr(part)), ("words", jstr(words)), ("with", with_)])),
  }
  let served = Served::new(str_of(arg(a, "binary")).unwrap_or(""), str_of(arg(a, "data")).unwrap_or(""), w, rt)
  let world : ServedWorld = {
    rt,
    served,
    processes,
    calls,
    logs,
    now,
    due,
    relays,
    pieces,
    piece_waiting,
    settles: Map([]),
    claims: 0,
    started: None,
  }
  served.set_on_routes(paths => calls.push(Json::array([jstr("routes"), Json::array(paths.map(jstr))])))
  served.set_changed((changes, titled) => calls.push(Json::array([jstr("changed"), changes, titled])))
  served.set_says({
    claim: async fn(viewer, path, key, lang) {
      calls.push(Json::array([jstr("claim"), viewer, jstr(path), opt_str(key), jstr(lang)]))
      match path {
        "/kept" => Kept({ status: 200, headers: jobj([]), body: @utf8.encode("{\"kept\":1}") })
        "/refused" => Refused({ status: 409, headers: jobj([]), body: @utf8.encode("no") })
        "/throw" => raise Failure("the store is busy")
        _ => {
          let by = "\{path}#\{world.claims}"
          world.claims += 1
          Claim(by, answer => calls.push(
            Json::array([
              jstr("settled"),
              jstr(by),
              match answer {
                Some(h) => handled_text(h)
                None => Json::null()
              },
            ]),
          ))
        }
      }
    },
    said: (thread, n, text, row) => calls.push(Json::array([jstr("said"), jnum(thread), jnum(n), jstr(text), row])),
  })
  world
}

///|
/// What the world came to since asked last: each program's told messages, the calls, the lines said.
fn ServedWorld::told(self : ServedWorld) -> Json {
  let programs = self.processes.map(p => {
    let out = Json::array(p.1.copy())
    p.1.clear()
    out
  })
  let out = jobj([
    ("told", Json::array(programs)),
    ("calls", Json::array(self.calls.copy())),
    ("logs", Json::array(self.logs.copy())),
    ("started", self.started.unwrap_or(Json::null())),
  ])
  self.calls.clear()
  self.logs.clear()
  out
}

///|
fn ServedWorld::step(self : ServedWorld, a : Json) -> Unit {
  let p = (k : String) => num_of(field(a, k)).unwrap_or(0.0).to_int()
  let hooks = (i : Int) => match self.processes.get(i) {
    Some((_, _, _, h)) => h.val
    None => None
  }
  match str_of(field(a, "op")).unwrap_or("") {
    "start" =>
      ignore(
        self.rt.fork(() => {
          let live = self.served.start() catch {
            e => {
              self.started = Some(jobj([("error", jstr(message_of(e)))]))
              return
            }
          }
          self.started = Some(Json::array(live.map(jstr)))
        }),
      )
    "listen" =>
      if hooks(p("p")) is Some((said, _)) {
        let path = self.processes[p("p")].0[5]
        said(jobj([("listening", jstr(path))]))
      }
    "say" => if hooks(p("p")) is Some((said, _)) { said(field(a, "said").unwrap_or(Json::null())) }
    "exit" =>
      if hooks(p("p")) is Some((_, exit)) {
        exit(p("code"))
      }
    "pass" => {
      self.now.val += num_of(field(a, "ms")).unwrap_or(0.0)
      let ready = self.due.filter(d => d.0 <= self.now.val)
      self.due.retain(d => d.0 > self.now.val)
      ready.sort_by((x, y) => x.0.compare(y.0))
      for d in ready {
        if !d.2.val {
          (d.1)()
        }
      }
    }
    "viewer" =>
      self.served.viewer(
        p("conn"),
        match field(a, "viewer") {
          None | Some(Null) => None
          v => v
        },
        moved=field(a, "moved") is Some(True),
        floor=num_of(field(a, "floor")),
      )
    "relaySend" => if self.relays.get(p("n")) is Some((send, _)) { send(str_of(field(a, "text")).unwrap_or("")) }
    "relaySends" =>
      for x in arr(field(a, "sends")) {
        if x is Array([Number(n, ..), String(t)]) && self.relays.get(n.to_int()) is Some((send, _)) {
          send(t)
        }
      }
    "relayEnd" => if self.relays.get(p("n")) is Some((_, ended)) { ended() }
    "piece" => {
      let n = p("n")
      let v = field(a, "text").unwrap_or(Json::null())
      match self.piece_waiting.get(n) {
        Some(d) => {
          self.piece_waiting.remove(n)
          ignore(d.succeed(v))
        }
        None => if self.pieces.get(n) is Some(q) { q.push(v) }
      }
    }
    "close" => ignore(self.rt.fork(() => self.served.close()))
    _ => ()
  }
  ignore(self.rt.run_ready())
}
