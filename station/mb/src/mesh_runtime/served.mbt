// The reads a device asks that the MoonBit program answers itself (station/src/mesh/served.ts; reader `--serve`,
// reader/serve.mbt): the routes the front hands it, and what the station that keeps those programs decides of them:
// when one that ended is started again, what each is told of a connection's member (said again only as it changes),
// and the pieces of the streams it relays, a piece told several of its streams at once given once.

///|
/// The routes answered there; `*` a segment.
pub let served_routes : Array[String] = [
  "GET /admin/api/chats", "GET /admin/api/sessions", "GET /admin/api/sessions/*", "GET /admin/api/sessions/*/timeline",
  "GET /admin/api/threads", "GET /admin/api/threads/*", "GET /admin/api/threads/*/entries", "GET /admin/api/threads/*/letters",
  "GET /admin/api/jobs", "GET /admin/api/jobs/*", "GET /admin/api/jobs/*/log", "POST /admin/api/changed/chats",
  "POST /admin/api/changed/sessions", "POST /admin/api/changed/threads", "GET /admin/api/events", "PUT /admin/api/threads/*/read",
  "PUT /admin/api/threads/*/hidden", "PUT /admin/api/threads/*/muted", "PUT /admin/api/threads/*/keep", "DELETE /admin/api/threads/*/keep",
  "PUT /admin/api/sessions/*/pin", "DELETE /admin/api/sessions/*/pin", "POST /admin/api/threads/*/messages", "POST /admin/api/sessions/*/title",
  "PUT /admin/api/threads/*/title", "PUT /admin/api/threads/*/dismissed",
]

///|
/// How many of the program answer at once.
pub let servers : Int = 2

///|
/// A program that ran this long before it ended is started again at once; one that ends sooner, SERVED_AGAIN_MS after.
pub let served_steady_ms : Double = 5_000.0

///|
pub let served_again_ms : Double = 1_000.0

///|
/// How long the programs are given to listen as the station starts.
pub let served_listen_ms : Double = 15_000.0

///|
/// How long after a program ended it is started again, it having run `ran` ms.
pub fn served_again_after(ran : Double) -> Double {
  if ran >= served_steady_ms {
    0.0
  } else {
    served_again_ms
  }
}

///|
/// What the programs are told of each connection's member and of people's names (`Served.viewer`), as told last.
pub struct ServedTold {
  told : Map[Int, String]
  names : Map[String, String]
}

///|
pub fn ServedTold::new() -> ServedTold {
  { told: Map([]), names: Map([]) }
}

///|
/// Connection `conn`'s member is now `viewer` (None: gone, or no longer let in; else `{email, name?, …}`), its
/// workspace's chain moved or not, a core too old under `floor` there: what each program is to be told, in order
/// (`{names}`, then `{viewer}`; each program's own wall clock added by who tells it).
pub fn ServedTold::viewer(self : ServedTold, conn : Int, viewer : Json?, moved : Bool, floor : Double?) -> Array[Json] {
  let out = []
  if viewer is Some(v) &&
    field(v, "name") is Some(String(name)) &&
    name != "" &&
    field(v, "email") is Some(String(email)) &&
    self.names.get(email) != Some(name) {
    self.names[email] = name
    out.push(jobj([("names", Json::array([Json::array([jstr(email), jstr(name)])]))]))
  }
  let said = jobj([
    (
      "viewer",
      jobj([
        ("conn", jnum(conn.to_double())),
        ("viewer", viewer.unwrap_or(Json::null())),
        ("moved", Json::boolean(moved)),
        ("floor", match floor { Some(f) => jnum(f); None => Json::null() }),
      ]),
    ),
  ])
  let text = js_stringify(said)
  if self.told.get(conn) == Some(text) {
    return out
  }
  match viewer {
    None => self.told.remove(conn)
    Some(_) => self.told[conn] = text
  }
  out.push(said)
  out
}

///|
/// Connection `conn`'s member as told last; None for none.
pub fn ServedTold::viewer_of(self : ServedTold, conn : Int) -> Json? {
  guard self.told.get(conn) is Some(text) else { return None }
  let v = payload_json(@utf8.encode(text))
  match v {
    Some(said) =>
      match field(said, "viewer") {
        Some(inner) =>
          match field(inner, "viewer") {
            Some(Null) | None => None
            x => x
          }
        None => None
      }
    None => None
  }
}

///|
/// What a program that listens again is told of the members (each as told last), and the names first.
pub fn ServedTold::again(self : ServedTold) -> Array[Json] {
  let out = []
  if self.names.length() > 0 {
    out.push(jobj([("names", Json::array(self.names.to_array().map(kv => Json::array([jstr(kv.0), jstr(kv.1)]))))]))
  }
  for _, text in self.told {
    if payload_json(@utf8.encode(text)) is Some(v) {
      out.push(v)
    }
  }
  out
}

///|
/// What is to be told one program till its turn ends (`#piece`): a piece told several of its streams in a row is the
/// one text, given once with them all; None, a stream's end.
pub struct PieceQueue {
  pending : Array[(String?, Array[Int])]
}

///|
pub fn PieceQueue::new() -> PieceQueue {
  { pending: [] }
}

///|
/// Stream `n`'s next piece (None: its end).
pub fn PieceQueue::piece(self : PieceQueue, n : Int, text : String?) -> Unit {
  if self.pending.length() > 0 {
    let last = self.pending[self.pending.length() - 1]
    if text is Some(t) && last.0 == Some(t) {
      last.1.push(n)
      return
    }
  }
  self.pending.push((text, [n]))
}

///|
/// What is told the program as the turn ends (`{done}`, `{chunk, text}` or `{pieces, to}`), in order.
pub fn PieceQueue::drain(self : PieceQueue) -> Array[Json] {
  let out = []
  for p in self.pending {
    match p.0 {
      None =>
        for k in p.1 {
          out.push(jobj([("done", jnum(k.to_double()))]))
        }
      Some(text) =>
        if p.1.length() == 1 {
          out.push(jobj([("chunk", jnum(p.1[0].to_double())), ("text", jstr(text))]))
        } else {
          out.push(jobj([("pieces", jstr(text)), ("to", Json::array(p.1.map(k => jnum(k.to_double()))))]))
        }
    }
  }
  self.pending.clear()
  out
}

///|
/// What a request given back is answered with (`Handled`).
pub(all) struct Handled {
  status : Int
  headers : Json
  body : Bytes
}

///|
fn handled_text(h : Handled) -> Json {
  jobj([("status", jnum(h.status.to_double())), ("headers", h.headers), ("text", jstr(@utf8.decode_lossy(h.body[:])))])
}

///|
/// The body of a request answered as it comes (GET /events): whole, told as it is made (`relay`: each piece given at
/// once, its end; and what stops it), or a piece at a time.
pub(all) enum StreamBody {
  Whole(Bytes)
  Relay(((String) -> Unit, () -> Unit) -> Unit, () -> Unit)
  Pieces(async () -> Bytes?, async () -> Unit)
}

///|
pub(all) struct StreamAnswer {
  status : Int
  headers : Json
  body : StreamBody
}

///|
/// A message's claim (`says.claim`): kept already, refused, or claimed with its timestamp and what settles it.
pub(all) enum Claimed {
  Kept(Handled)
  Refused(Handled)
  Claim(String, (Handled?) -> Unit)
}

///|
/// A person's message the program writes (`Served.says`): claimed before, told once written.
pub(all) struct Says {
  claim : async (Json, String, String?, String) -> Claimed
  said : (Double, Double, String, Json) -> Unit
}

///|
/// A program answering, as it is started (an `MbProcess`; a test's own).
pub(all) struct ServingProcess {
  post : (Json) -> Unit
  terminate : async () -> Unit
}

///|
/// What the programs stand on: started with what they say given (`spawn(binary, args, said, exited)`), the machine's
/// time and its timers, the requests given back, the run directory made ready for a socket and its socket let go, and
/// what each program is told as it listens (`set`: the station's words and floors).
pub(all) struct ServedWith {
  spawn : (String, Array[String], (Json) -> Unit, (Int) -> Unit) -> ServingProcess
  now : () -> Double
  after : (Double, () -> Unit) -> () -> Unit
  wall : () -> Double
  answer : async (Json, Json, Bytes) -> Handled
  built : (Json, Double?) -> Unit
  stream : (async (Json, Json, Bytes) -> StreamAnswer)?
  /// (before it is started: the run directory there, no socket left at the path; at once, as the TypeScript's `sync:`)
  prepare : (String) -> Unit
  remove : async (String) -> Unit
  set : () -> Json
  pid : Int
  sep : String
  log : Said
}

///|
priv struct Server {
  n : Int
  process : ServingProcess
  path : String
  listening : @effect.Deferred[Bool]
  started_at : Double
  mut ready : Bool
  mut ended : Bool
}

///|
/// The programs that answer a device's served reads, as the station keeps them (`Served`).
pub struct Served {
  priv binary : String
  priv data : String
  priv w : ServedWith
  priv rt : @effect.Runtime
  priv servers : Array[Server]
  priv streaming : Map[Int, Map[Int, () -> Unit]]
  priv claims : Map[Int, Map[Int, (Handled?) -> Unit]]
  priv queued : Map[Int, PieceQueue]
  priv told : ServedTold
  priv mut closed : Bool
  priv mut started : Bool
  priv mut spawned : Int
  /// The sockets of the programs listening now, said each time that changes after `start`.
  priv mut on_routes : ((Array[String]) -> Unit)?
  priv mut says : Says?
  /// What a program wrote (a device's marks), and the chats it named by hand.
  priv mut changed : ((Json, Json) -> Unit)?
}

///|
pub fn Served::new(binary : String, data : String, w : ServedWith, rt : @effect.Runtime) -> Served {
  {
    binary,
    data,
    w,
    rt,
    servers: [],
    streaming: Map([]),
    claims: Map([]),
    queued: Map([]),
    told: ServedTold::new(),
    closed: false,
    started: false,
    spawned: 0,
    on_routes: None,
    says: None,
    changed: None,
  }
}

///|
/// Told the sockets of the programs listening each time that changes after `start` (`onRoutes`).
pub fn Served::set_on_routes(self : Served, f : (Array[String]) -> Unit) -> Unit {
  self.on_routes = Some(f)
}

///|
pub fn Served::set_says(self : Served, says : Says) -> Unit {
  self.says = Some(says)
}

///|
pub fn Served::set_changed(self : Served, f : (Json, Json) -> Unit) -> Unit {
  self.changed = Some(f)
}

///|
fn Served::live_paths(self : Served) -> Array[String] {
  self.servers.filter(s => s.ready).map(s => s.path)
}

///|
fn Served::routes_changed(self : Served) -> Unit {
  if self.on_routes is Some(f) {
    f(self.live_paths())
  }
}

///|
/// Where the programs listen, once each listened or ended, or SERVED_LISTEN_MS passed (`start`); none listening fails.
pub async fn Served::start(self : Served) -> Array[String] {
  for i in 0..<servers {
    self.servers.push(self.start_one(i))
  }
  let late : @effect.Deferred[Unit] = @effect.Deferred::new()
  let stop = (self.w.after)(served_listen_ms, () => ignore(late.succeed(())))
  let all : @effect.Deferred[Unit] = @effect.Deferred::new()
  let left = Ref(self.servers.length())
  for s in self.servers {
    ignore(
      self.rt.fork_quiet(name="served listening", () => {
        ignore(s.listening.wait()) catch { _ => () }
        left.val -= 1
        if left.val == 0 {
          ignore(all.succeed(()))
        }
      }),
    )
  }
  ignore(self.rt.fork_quiet(name="served late", () => late.wait() catch { _ => () } noraise { _ => ignore(all.succeed(())) }))
  all.wait()
  stop()
  self.started = true
  for s in self.servers {
    if !s.ready && !s.ended {
      (self.w.log)("warn", "served", "a serving program did not listen in time; ending it", jobj([("path", jstr(s.path))]))
      let p = s.process
      ignore(self.rt.fork_quiet(name="served terminate", () => (p.terminate)() catch { _ => () }))
    }
  }
  let live = self.live_paths()
  if live.length() == 0 {
    raise Failure("no serving program listens")
  }
  live
}

///|
fn Served::start_one(self : Served, i : Int) -> Server {
  let path = "\{self.data}\{self.w.sep}run\{self.w.sep}serve-\{self.w.pid}-\{i}.sock"
  (self.w.prepare)(path)
  self.spawned += 1
  let n = self.spawned
  let server_ref : Ref[Server?] = Ref(None)
  let process = (self.w.spawn)(
    self.binary,
    ["--data", self.data, "--sep", self.w.sep, "--serve", path],
    said => if server_ref.val is Some(s) { self.heard(s, said) },
    code => if server_ref.val is Some(s) { self.exited(s, i, code) },
  )
  let server : Server = {
    n,
    process,
    path,
    listening: @effect.Deferred::new(),
    started_at: (self.w.now)(),
    ready: false,
    ended: false,
  }
  server_ref.val = Some(server)
  server
}

///|
fn Served::heard(self : Served, server : Server, said : Json) -> Unit {
  match said {
    { "listening": String(_), .. } => {
      self.settle(server)
      server.ready = true
      ignore(server.listening.succeed(true))
      if self.started && !self.closed {
        self.routes_changed()
      }
    }
    { "build": b, .. } if !(b is Null) => {
      let conn = js_number(
        match field(b, "conn") {
          Some(Number(c, ..)) => js_num(c)
          Some(String(s)) => s
          _ => "x"
        },
      )
      if js_is_integer(conn) && self.told.viewer_of(conn.to_int()) is Some(viewer) {
        (self.w.built)(viewer, num_of(field(b, "build")))
      }
    }
    { "fallback": Number(_, ..), .. } =>
      ignore(
        self.rt.fork_daemon("served fallback", on_error=e => self.failed(server, "a serving program's request was not answered", e), () => if field(said, "stream") is Some(True) { self.relay(server, said) } else { self.fallback(server, said) }),
      )
    { "changes": Array(_) as changes, .. } =>
      if self.changed is Some(f) {
        f(changes, match field(said, "titled") { Some(Array(_) as t) => t; _ => Json::array([]) })
      }
    { "claim": Number(_, ..), .. } =>
      ignore(self.rt.fork_daemon("served claim", on_error=e => self.failed(server, "a serving program's claim was not answered", e), () => self.claim(server, said)))
    { "said": _, .. } => self.said(server, said)
    { "stop": Number(k, ..), .. } =>
      if self.streaming.get(server.n) is Some(m) && m.get(k.to_int()) is Some(stop) {
        stop()
      }
    _ => ()
  }
}

///|
fn Served::exited(self : Served, server : Server, i : Int, code : Int) -> Unit {
  if self.streaming.get(server.n) is Some(m) {
    for _, stop in m {
      stop()
    }
  }
  self.streaming.remove(server.n)
  let claims = self.claims.get(server.n)
  self.claims.remove(server.n)
  if claims is Some(c) {
    for _, settle in c {
      settle(None)
    }
  }
  self.queued.remove(server.n)
  server.ready = false
  server.ended = true
  ignore(server.listening.succeed(false))
  if self.closed {
    return
  }
  guard self.servers.search_by(s => physical_equal(s, server)) is Some(at) else { return }
  if self.started {
    self.routes_changed()
  }
  let again = () => if !self.closed && physical_equal(self.servers[at], server) {
    self.servers[at] = self.start_one(i)
  }
  if (self.w.now)() - server.started_at >= served_steady_ms {
    (self.w.log)("warn", "served", "a serving program ended; starting it again", jobj([("code", jnum(code.to_double()))]))
    again()
  } else {
    (self.w.log)(
      "warn",
      "served",
      "a serving program ended soon after it started; starting it again in a second",
      jobj([("code", jnum(code.to_double()))]),
    )
    ignore((self.w.after)(served_again_ms, again))
  }
}

///|
/// A program that listens told all it is to know (`#settle`).
fn Served::settle(self : Served, server : Server) -> Unit {
  (server.process.post)(jobj([("set", (self.w.set)()), ("wall", jnum((self.w.wall)()))]))
  for m in self.told.again() {
    (server.process.post)(m)
  }
}

///|
fn Served::tell(self : Served, said : Json) -> Unit {
  for s in self.servers {
    (s.process.post)(said)
  }
}

///|
/// Connection `conn`'s member now (`viewer`): told the programs as it changes.
pub fn Served::viewer(self : Served, conn : Int, viewer : Json?, moved? : Bool = false, floor? : Double? = None) -> Unit {
  for m in self.told.viewer(conn, viewer, moved, floor) {
    match m {
      Object(o) if o.contains("viewer") => self.tell(with_fields(m, [("wall", jnum((self.w.wall)()))]))
      _ => self.tell(m)
    }
  }
}

///|
fn said_conn(said : Json) -> Int? {
  let n = match field(said, "conn") {
    Some(Number(c, ..)) => c
    Some(String(s)) => js_number(s)
    None => @double.not_a_number
    _ => @double.not_a_number
  }
  if js_is_integer(n) {
    Some(n.to_int())
  } else {
    None
  }
}

///|
fn Served::viewer_of(self : Served, said : Json) -> Json? {
  match said_conn(said) {
    Some(c) => self.told.viewer_of(c)
    None => None
  }
}

///|
fn json_answer(status : Int, text : String) -> Handled {
  { status, headers: jobj([("content-type", jstr("application/json"))]), body: @utf8.encode(text) }
}

///|
/// What a fiber for `server` let escape, said.
fn Served::failed(self : Served, server : Server, what : String, e : Error) -> Unit {
  (self.w.log)("warn", "served", what, jobj([("path", jstr(server.path)), ("error", jstr(message_of(e)))]))
}

///|
async fn Served::fallback(self : Served, server : Server, said : Json) -> Unit {
  let n = field(said, "fallback").unwrap_or(Json::null())
  let handled = match self.viewer_of(said) {
    None => json_answer(502, "{\"error\":\"the connection is gone\"}")
    Some(viewer) =>
      (self.w.answer)(viewer, field(said, "head").unwrap_or(Json::null()), @utf8.encode(str_of(field(said, "body")).unwrap_or(""))) catch {
        e => json_answer(500, js_stringify(jobj([("error", jstr(message_of(e)))])))
      }
  }
  (server.process.post)(
    jobj([
      ("answered", n),
      ("status", jnum(handled.status.to_double())),
      ("headers", handled.headers),
      ("text", jstr(@utf8.decode_lossy(handled.body[:]))),
    ]),
  )
}

///|
fn Served::streams_of(self : Served, server : Server) -> Map[Int, () -> Unit] {
  match self.streaming.get(server.n) {
    Some(m) => m
    None => {
      let m = Map([])
      self.streaming[server.n] = m
      m
    }
  }
}

///|
/// A request the program writes as it comes (`#relay`): its head, then each piece, then its end.
async fn Served::relay(self : Served, server : Server, said : Json) -> Unit {
  let n = num_of(field(said, "fallback")).unwrap_or(0.0).to_int()
  let nj = jnum(n.to_double())
  let post = server.process.post
  let viewer = self.viewer_of(said)
  let answer = (async fn() -> StreamAnswer {
    guard viewer is Some(v) && self.w.stream is Some(stream) else { raise Failure("the connection is gone") }
    stream(v, field(said, "head").unwrap_or(Json::null()), @utf8.encode(str_of(field(said, "body")).unwrap_or("")))
  })() catch {
    e => {
      post(jobj([("answered", nj), ("status", jnum(500.0)), ("headers", jobj([("content-type", jstr("application/json"))]))]))
      post(jobj([("chunk", nj), ("text", jstr(js_stringify(jobj([("error", jstr(message_of(e)))]))))]))
      post(jobj([("done", nj)]))
      return
    }
  }
  post(jobj([("answered", nj), ("status", jnum(answer.status.to_double())), ("headers", answer.headers)]))
  match answer.body {
    Whole(b) => {
      if b.length() > 0 {
        post(jobj([("chunk", nj), ("text", jstr(@utf8.decode_lossy(b[:])))]))
      }
      post(jobj([("done", nj)]))
    }
    Relay(relay, stop_it) => {
      let streams = self.streams_of(server)
      let over = Ref(false)
      streams[n] = () => {
        over.val = true
        stop_it()
      }
      relay(text => self.piece(server, n, Some(text)), () => {
        streams.remove(n)
        if !over.val {
          self.piece(server, n, None)
        }
      })
    }
    Pieces(next, stop_it) => {
      let streams = self.streams_of(server)
      let stopped = Ref(false)
      streams[n] = () => {
        stopped.val = true
        ignore(self.rt.fork_quiet(name="served stream stop", () => stop_it() catch { _ => () }))
      }
      // (what fails it ends it as its end does)
      (async fn() {
        while true {
          let got = next()
          guard got is Some(b) && !stopped.val else { break }
          post(jobj([("chunk", nj), ("text", jstr(@utf8.decode_lossy(b[:])))]))
        }
      })() catch {
        _ => ()
      }
      streams.remove(n)
      if !stopped.val {
        post(jobj([("done", nj)]))
      }
    }
  }
}

///|
/// A piece of stream `n` (None: its end), told the program as the turn ends (`#piece`).
fn Served::piece(self : Served, server : Server, n : Int, text : String?) -> Unit {
  let q = match self.queued.get(server.n) {
    Some(q) => q
    None => {
      let q = PieceQueue::new()
      self.queued[server.n] = q
      ignore(
        self.rt.fork_daemon("served pieces", on_error=e => self.failed(server, "pieces were not posted to a serving program", e), () => {
          if self.queued.get(server.n) is Some(mine) && physical_equal(mine, q) {
            self.queued.remove(server.n)
          }
          for m in q.drain() {
            (server.process.post)(m)
          }
        }),
      )
      q
    }
  }
  q.piece(n, text)
}

///|
async fn Served::claim(self : Served, server : Server, said : Json) -> Unit {
  let n = field(said, "claim").unwrap_or(Json::null())
  let give = (fields : Array[(String, Json)]) => (server.process.post)(jobj([("claimed", n), ..fields]))
  guard self.viewer_of(said) is Some(viewer) && self.says is Some(says) else {
    return give([("refused", handled_text(json_answer(503, "{\"error\":\"station starting\"}")))])
  }
  let key = match field(said, "key") {
    Some(String(k)) => Some(k)
    _ => None
  }
  let lang = if field(said, "lang") is Some(String("en")) { "en" } else { "zh" }
  let got = (says.claim)(viewer, str_of(field(said, "path")).unwrap_or(""), key, lang) catch {
    e => return give([("refused", handled_text(json_answer(500, js_stringify(jobj([("error", jstr(message_of(e)))])))))])
  }
  match got {
    Kept(h) => give([("kept", handled_text(h))])
    Refused(h) => give([("refused", handled_text(h))])
    Claim(ts, settle) => {
      if server.ended {
        return settle(None)
      }
      let claims = match self.claims.get(server.n) {
        Some(m) => m
        None => {
          let m = Map([])
          self.claims[server.n] = m
          m
        }
      }
      claims[num_of(Some(n)).unwrap_or(0.0).to_int()] = settle
      give([("ts", jstr(ts))])
    }
  }
}

///|
fn Served::said(self : Served, server : Server, said : Json) -> Unit {
  match field(said, "said") {
    Some(Object(_) as s) =>
      if self.says is Some(says) {
        (says.said)(
          num_of(field(s, "thread")).unwrap_or(0.0),
          num_of(field(s, "n")).unwrap_or(0.0),
          str_of(field(s, "text")).unwrap_or(""),
          field(s, "row").unwrap_or(Json::null()),
        )
      }
    _ => ()
  }
  let of = num_of(field(said, "of")).map(o => o.to_int())
  let claims = self.claims.get(server.n)
  let settle = match (claims, of) {
    (Some(c), Some(o)) => {
      let s = c.get(o)
      c.remove(o)
      s
    }
    _ => None
  }
  if settle is Some(f) {
    f(
      match field(said, "answer") {
        Some(Object(_) as a) =>
          Some({
            status: num_of(field(a, "status")).unwrap_or(0.0).to_int(),
            headers: field(a, "headers").unwrap_or(jobj([])),
            body: @utf8.encode(str_of(field(a, "text")).unwrap_or("")),
          })
        _ => None
      },
    )
  }
}

///|
/// Every program ended, its socket let go.
pub async fn Served::close(self : Served) -> Unit {
  self.closed = true
  let ps = self.servers.map(s => s.process)
  for p in ps {
    (p.terminate)() catch { _ => () }
  }
  for s in self.servers {
    (self.w.remove)(s.path) catch { _ => () }
  }
}
