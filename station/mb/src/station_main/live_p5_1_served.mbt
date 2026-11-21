// The reads and fast-path writes a device asks that the MoonBit program answers itself, not this process
// (`stillfail-reader --serve`, `reader/serve.mbt`, matching station/src/mesh/served.ts): the front hands each
// routed request stream to one of `served_servers` child processes over its Unix socket, and this process tells
// them who each connection's member is (`viewer`), people's names (`names`), the language words and floors (`set`),
// claims idempotency keys & timestamps for `POST /threads/:id/messages` (`claim`/`said`), handles fallbacks &
// SSE event relays (`fallback`/`answered`/`chunk`/`done`/`stop`), and fans out `changes`/`titled` to the store.

///|
/// The routes answered by `--serve` child processes (station/src/mesh/served.ts `SERVED_ROUTES`).
let served_routes : Array[String] = [
  "GET /admin/api/chats",
  "GET /admin/api/sessions",
  "GET /admin/api/sessions/*",
  "GET /admin/api/sessions/*/timeline",
  "GET /admin/api/threads",
  "GET /admin/api/threads/*",
  "GET /admin/api/threads/*/entries",
  "GET /admin/api/threads/*/letters",
  "GET /admin/api/jobs",
  "GET /admin/api/jobs/*",
  "GET /admin/api/jobs/*/log",
  "POST /admin/api/changed/chats",
  "POST /admin/api/changed/sessions",
  "POST /admin/api/changed/threads",
  "GET /admin/api/events",
  "PUT /admin/api/threads/*/read",
  "PUT /admin/api/threads/*/hidden",
  "PUT /admin/api/threads/*/muted",
  "PUT /admin/api/threads/*/keep",
  "DELETE /admin/api/threads/*/keep",
  "PUT /admin/api/sessions/*/pin",
  "DELETE /admin/api/sessions/*/pin",
  "POST /admin/api/threads/*/messages",
  "POST /admin/api/sessions/*/title",
  "PUT /admin/api/threads/*/title",
  "PUT /admin/api/threads/*/dismissed",
]

///|
/// How many `--serve` child processes run concurrently (served.ts `SERVERS`).
let served_servers : Int = 2

///|
/// A child that ran this long before exiting is restarted at once; sooner, after `served_again_ms`.
let served_steady_ms : Int64 = 5000L

///|
let served_again_ms : Int = 1000

///|
/// How long children are given to emit `listening` during startup (served.ts `SERVED_LISTEN_MS`).
let served_listen_ms : Int = 15000

///|
/// Refusal prefixes whose reads must fall back to the main process so its builders prepare old state
/// (station/src/read/pool.ts `READS_PENDING`).
let served_reads_pending : Array[String] = [
  "legacy edit lookup pending",
  "legacy said lookup pending",
  "page letter lookup pending: ",
  "last message pending: ",
  "session binding index is still being prepared",
  "copy destination sessions pending:",
  "job name first member pending: ",
  "card posts pending:",
  "closed cards pending:",
  "people time pending:",
  "turn count pending: ",
  "sidebar said state pending: ",
  "usage chat statistics are still being filled",
  "remote task statistics are still being filled",
  "outflow chat order is still being prepared",
  "recent chat order is still being prepared",
  "session list index is still being prepared",
]

///|
/// Fallback `MAX(n)` SQL when `entries` is empty for a thread (station/src/store/store.ts `LAST_KNOWN`).
let served_last_known_sql : String =
  #|SELECT MAX(n) AS n FROM (WITH RECURSIVE few(viewer, count) AS (
  #|  SELECT (SELECT viewer FROM reads ORDER BY viewer LIMIT 1), 1
  #|  UNION ALL SELECT (SELECT viewer FROM reads WHERE viewer > v.viewer ORDER BY viewer LIMIT 1), v.count + 1
  #|    FROM few v WHERE v.viewer IS NOT NULL AND v.count < 33
  #|), more(viewer, count) AS (
  #|  SELECT (SELECT viewer FROM reads ORDER BY viewer LIMIT 1), 1
  #|  UNION ALL SELECT (SELECT viewer FROM reads WHERE viewer > v.viewer ORDER BY viewer LIMIT 1), v.count + 1
  #|    FROM more v WHERE v.viewer IS NOT NULL AND v.count < 257
  #|), all_viewers(viewer) AS (
  #|  SELECT (SELECT viewer FROM reads ORDER BY viewer LIMIT 1)
  #|  UNION ALL SELECT (SELECT viewer FROM reads WHERE viewer > v.viewer ORDER BY viewer LIMIT 1)
  #|    FROM all_viewers v WHERE v.viewer IS NOT NULL
  #|), bounds(span) AS (
  #|  SELECT (SELECT MAX(rowid) FROM reads) - (SELECT MIN(rowid) FROM reads)
  #|)
  #|SELECT CASE WHEN (SELECT COUNT(*) FROM few WHERE viewer IS NOT NULL) <= 32
  #|  THEN (SELECT MAX((SELECT n FROM reads WHERE viewer = v.viewer AND thread = ?1)) FROM few v WHERE v.viewer IS NOT NULL)
  #|  WHEN (SELECT span FROM bounds) < 512
  #|  THEN (SELECT MAX(n) FROM reads WHERE thread = ?1)
  #|  WHEN (SELECT COUNT(*) FROM more WHERE viewer IS NOT NULL) <= 256
  #|  THEN (SELECT MAX((SELECT n FROM reads WHERE viewer = v.viewer AND thread = ?1)) FROM more v WHERE v.viewer IS NOT NULL)
  #|  WHEN (SELECT span FROM bounds) < 16384
  #|  THEN (SELECT MAX(n) FROM reads WHERE thread = ?1)
  #|  ELSE (SELECT MAX((SELECT n FROM reads WHERE viewer = v.viewer AND thread = ?1)) FROM all_viewers v WHERE v.viewer IS NOT NULL) END AS n UNION ALL SELECT MAX(n) FROM deliveries WHERE thread = ?1)

///|
priv struct ServedServer {
  proc : MbProc
  sock : String
  listening : @effect.Deferred[Result[Unit, String]]
  started_at : Int64
  mut ready : Bool
  mut ended : Bool
  /// Active streaming relays on this child, by fallback request number: stops the upstream stream.
  streaming : Map[Int, () -> Unit]
  /// In-flight `POST /threads/:id/messages` claims on this child, by claim number: settles idempotency slot.
  claims : Map[Int, async (@api_routes.Kept?) -> Unit]
}

///|
priv struct Served {
  host : @host.Host
  binary : String
  data : String
  build : String
  answer : async (@gate.Viewer, Json, Bytes) -> @door.Answer
  built : async (@gate.Viewer, Int?) -> Unit
  claim : async (@gate.Viewer, String, String?, String) -> @api_routes.Claim
  said : async (Double, Double, String, Json) -> Unit
  changed : (Array[Json], Array[Json]) -> Unit
  on_routes : (Array[String]) -> Unit
  servers : Array[ServedServer]
  /// Last viewer message sent per connection id: `(canonical_key, message_json, Viewer)`.
  told : Map[Int, (String, Json, @gate.Viewer)]
  names : Map[String, String]
  mut closed : Bool
  mut started : Bool
  retry_stops : Array[() -> Unit]
}

///|
fn served_words_for(lang : String) -> Json {
  {
    "updateApp": Json::string(tr(lang, "station.admin.updateApp")),
    "badN": Json::string(tr(lang, "station.admin.badN")),
    "postOnlyStillfail": Json::string(tr(lang, "station.admin.postOnlyStillfail")),
    "emptyMessage": Json::string(tr(lang, "station.admin.emptyMessage")),
    "renameOnlyStillfail": Json::string(tr(lang, "station.admin.renameOnlyStillfail")),
    "nothingWaiting": Json::string(tr(lang, "station.admin.nothingWaiting")),
    "updateClientForOption": Json::string(tr(lang, "station.admin.updateClientForOption")),
    "movedThere": Json::string(tr(lang, "station.move.movedThere")),
  }
}

///|
fn headers_to_json(headers : Array[(String, String)]) -> Json {
  let out : Map[String, Json] = {}
  for kv in headers {
    out[kv.0] = Json::string(kv.1)
  }
  Json::object(out)
}

///|
fn kept_to_json(k : @api_routes.Kept) -> Json {
  let hs : Map[String, Json] = {}
  for name, value in k.headers {
    hs[name] = Json::string(value)
  }
  {
    "status": Json::number(k.status.to_double()),
    "headers": Json::object(hs),
    "text": Json::string(@utf8.decode_lossy(k.body)),
  }
}

///|
fn P51::served_live(
  self : P51,
  keeper : @gate.Keeper,
  admin_live : AdminLive,
  members_ref : Ref[@gate.Members?],
  on_routes : (Array[String]) -> Unit,
) -> Served {
  let bus = self.bus
  let names : Map[String, String] = {}
  if self.readers is Some(r) {
    for email, name in r.names {
      names[email] = name
    }
  }
  {
    host: self.host,
    binary: bus.argv0,
    data: bus.data,
    build: bus.version,
    answer: async fn(viewer, head, body) {
      match members_ref.val {
        Some(m) => @gate.answer_given(m, viewer, head, body)
        None =>
          {
            status: 503,
            headers: [("content-type", "application/json")],
            body: Whole(@utf8.encode("{\"error\":\"station starting\"}")),
          }
      }
    },
    built: async fn(viewer, build) {
      let hs : Json = match build {
        Some(b) => { "stillfail-build": Json::string(b.to_string()) }
        None => Json::object({})
      }
      ignore(@gate.saw_build(keeper, viewer, hs))
    },
    claim: async fn(viewer, req_path, key, lang) {
      admin_live.admin.claim_say(to_jv(viewer.to_json()), req_path, key, lang)
    },
    said: async fn(thread, n, text, row) {
      admin_live.admin.said_elsewhere(thread, n, text, to_jv(row))
    },
    changed: (changes, titled) => {
      for t in titled {
        bus.store.retitled(t)
      }
      bus.store.told(changes)
    },
    on_routes,
    servers: [],
    told: {},
    names,
    closed: false,
    started: false,
    retry_stops: [],
  }
}

///|
/// Starts `served_servers` `--serve` child processes and waits up to `served_listen_ms` for them to listen.
/// Returns the socket paths that are listening; raises if none listen in time.
async fn Served::start(self : Served) -> Array[String] {
  for i = 0; i < served_servers; i = i + 1 {
    if self.closed {
      break
    }
    if self.spawn_one(i) is Some(s) {
      self.servers.push(s)
    }
  }
  if self.servers.length() > 0 {
    let done : @effect.Deferred[Unit] = @effect.Deferred::new()
    let left = Ref(self.servers.length())
    for s in self.servers {
      fork_bg(self.host, "served listen wait", async fn() {
        ignore(s.listening.wait())
        left.val -= 1
        if left.val <= 0 {
          ignore(done.succeed(()))
        }
      })
    }
    ignore(@effect.timeout(served_listen_ms, async fn() { done.wait() })) // timer: a deadline on child processes starting
  }
  if self.closed {
    return []
  }
  self.started = true
  for s in self.servers {
    if !s.ready && !s.ended {
      p51_log("WARN", "served", "a serving program did not listen in time; ending it", fields={ "path": Json::string(s.sock) })
      s.proc.stop()
    }
  }
  let live = self.live_paths()
  if live.length() == 0 {
    raise BusError("no serving program listens")
  }
  live
}

///|
fn Served::live_paths(self : Served) -> Array[String] {
  self.servers.filter(s => s.ready).map(s => s.sock)
}

///|
fn Served::pids(self : Served) -> Array[Int] {
  let out : Array[Int] = []
  for s in self.servers {
    if !s.proc.gone {
      out.push(s.proc.proc.pid)
    }
  }
  out
}

///|
async fn Served::spawn_one(self : Served, i : Int) -> ServedServer? {
  let run_dir = path([self.data, "run"])
  ignore(self.host.shell("fs.mkdir", { "path": Json::string(run_dir), "recursive": true })) catch {
    _ => ()
  }
  let sock = path([run_dir, "serve-\{@host.pid()}-\{i}.sock"])
  ignore(self.host.shell("fs.remove", { "path": Json::string(sock) })) catch {
    _ => ()
  }
  if self.closed {
    return None
  }
  let proc = mb_spawn(self.host, self.binary, ["--data", self.data, "--sep", sep(), "--serve", sock]) catch {
    SysError(e) => {
      p51_log("WARN", "served", "a serving program failed to start", fields={ "error": Json::string(e), "path": Json::string(sock) })
      return None
    }
  }
  if self.closed {
    proc.stop()
    ignore(self.host.shell("fs.remove", { "path": Json::string(sock) })) catch {
      _ => ()
    }
    return None
  }
  let server : ServedServer = {
    proc,
    sock,
    listening: @effect.Deferred::new(),
    started_at: @host.now(),
    ready: false,
    ended: false,
    streaming: {},
    claims: {},
  }
  fork_bg(self.host, "served child", async fn() {
    while proc.next() is Some((said, _)) {
      self.on_message(server, said)
    }
    self.on_exit(server, i)
  })
  Some(server)
}

///|
fn Served::on_message(self : Served, server : ServedServer, said : Json) -> Unit {
  match said {
    { "listening": String(_), .. } => {
      self.settle(server)
      server.ready = true
      ignore(server.listening.succeed(Ok(())))
      if self.started && !self.closed {
        (self.on_routes)(self.live_paths())
      }
    }
    { "build": { "conn": Number(conn, ..), .. } as b, .. } => {
      let build_num = match jfield(b, "build") {
        Number(n, ..) => Some(n.to_int())
        _ => None
      }
      if self.told.get(conn.to_int()) is Some((_, _, viewer)) {
        fork_bg(self.host, "served build", async fn() {
          (self.built)(viewer, build_num) catch {
            _ => ()
          }
        })
      }
    }
    { "fallback": Number(n, ..), "stream": True, .. } =>
      fork_bg(self.host, "served relay", async fn() {
        self.handle_relay(server, n.to_int(), said)
      })
    { "fallback": Number(n, ..), .. } =>
      fork_bg(self.host, "served fallback", async fn() {
        self.handle_fallback(server, n.to_int(), said)
      })
    { "changes": Array(changes), .. } => {
      let titled = match said {
        { "titled": Array(t), .. } => t
        _ => []
      }
      (self.changed)(changes, titled)
    }
    { "claim": Number(n, ..), .. } =>
      fork_bg(self.host, "served claim", async fn() {
        self.handle_claim(server, n.to_int(), said)
      })
    { "of": Number(of_n, ..), .. } if said is Object(m) && m.contains("said") =>
      self.handle_said(server, of_n.to_int(), said)
    { "stop": Number(n, ..), .. } => {
      let id = n.to_int()
      if server.streaming.get(id) is Some(stop) {
        server.streaming.remove(id)
        stop()
      }
    }
    _ => ()
  }
}

///|
fn Served::on_exit(self : Served, server : ServedServer, i : Int) -> Unit {
  for _, stop in server.streaming {
    stop()
  }
  server.streaming.clear()
  let pending_claims = server.claims.values().collect()
  server.claims.clear()
  for settle in pending_claims {
    fork_bg(self.host, "served claim drop", async fn() {
      settle(None) catch {
        _ => ()
      }
    })
  }
  server.ready = false
  server.ended = true
  ignore(server.listening.succeed(Err("a serving program ended")))
  if self.closed {
    let sock = server.sock
    fork_bg(self.host, "served sock cleanup", async fn() {
      ignore(self.host.shell("fs.remove", { "path": Json::string(sock) })) catch {
        _ => ()
      }
    })
    return
  }
  guard self.servers.search_by(s => physical_equal(s, server)) is Some(at) else { return }
  if self.started {
    (self.on_routes)(self.live_paths())
  }
  let again = () => {
    fork_bg(self.host, "served respawn", async fn() {
      if !self.closed && at < self.servers.length() && physical_equal(self.servers[at], server) {
        if self.spawn_one(i) is Some(next) {
          if !self.closed && at < self.servers.length() && physical_equal(self.servers[at], server) {
            self.servers[at] = next
          } else {
            next.proc.stop()
            ignore(self.host.shell("fs.remove", { "path": Json::string(next.sock) })) catch {
              _ => ()
            }
          }
        }
      }
    })
  }
  if @host.now() - server.started_at >= served_steady_ms {
    p51_log("WARN", "served", "a serving program ended; starting it again", fields={ "path": Json::string(server.sock) })
    again()
  } else {
    p51_log("WARN", "served", "a serving program ended soon after it started; starting it again in a second", fields={ "path": Json::string(server.sock) })
    let fiber = self.host.rt.fork(name="served restart", async fn() {
      @effect.sleep(served_again_ms) // timer: a retry after a failure, with a backoff (one that keeps ending is started again each second at most)
      again()
    })
    self.retry_stops.push(() => fiber.interrupt())
  }
}

///|
/// Sends initial configuration, names, and active connection viewers to a newly listening child.
fn Served::settle(self : Served, server : ServedServer) -> Unit {
  let words : Json = { "zh": served_words_for("zh"), "en": served_words_for("en") }
  let set_msg : Json = {
    "set": {
      "lastKnown": Json::string(served_last_known_sql),
      "words": words,
      "oldestCore": Json::number(@events.oldest_core.to_double()),
      "countedFrom": Json::number(@cloud_lock.counted_from.to_double()),
      "movedFromBuild": Json::number(@cloud_lock.moved_from_build.to_double()),
      "build": Json::string(self.build),
      "runtimes": Json::array(@events.runtime_kinds.map(Json::string)),
      "pending": Json::array(served_reads_pending.map(Json::string)),
    },
    "wall": Json::number(wall_ms().to_double()),
  }
  ignore(server.proc.post(set_msg))
  if self.names.length() > 0 {
    let pairs = self.names.to_array().map(kv => Json::array([Json::string(kv.0), Json::string(kv.1)]))
    ignore(server.proc.post({ "names": Json::array(pairs) }))
  }
  for _, entry in self.told {
    ignore(server.proc.post(entry.1))
  }
}

///|
/// Updates a member's display name across all `--serve` children when learned outside `viewer`.
fn Served::remember_name(self : Served, email : String, name : String) -> Unit {
  if name != "" && self.names.get(email) != Some(name) {
    self.names[email] = name
    self.tell({ "names": Json::array([Json::array([Json::string(email), Json::string(name)])]) })
  }
}

///|
/// Tells all `--serve` children who connection `conn`'s member is (None: gone or no longer admitted).
fn Served::viewer(self : Served, conn : Int, viewer : @gate.Viewer?, moved : Bool, floor : Int?) -> Unit {
  if viewer is Some(v) {
    self.remember_name(v.email, v.name)
  }
  let entry : Map[String, Json] = {
    "conn": Json::number(conn.to_double()),
    "viewer": match viewer {
      Some(v) => v.to_json()
      None => Json::null()
    },
    "moved": Json::boolean(moved),
    "floor": match floor {
      Some(f) => Json::number(f.to_double())
      None => Json::null()
    },
  }
  let canonical : Json = { "viewer": Json::object(entry) }
  let key = canonical.stringify()
  if self.told.get(conn) is Some((prev, _, _)) && prev == key {
    return
  }
  match viewer {
    None => self.told.remove(conn)
    Some(v) => self.told[conn] = (key, canonical, v)
  }
  self.tell({ "viewer": Json::object(entry), "wall": Json::number(wall_ms().to_double()) })
}

///|
fn Served::tell(self : Served, msg : Json) -> Unit {
  for s in self.servers {
    ignore(s.proc.post(msg))
  }
}

///|
async fn Served::handle_fallback(self : Served, server : ServedServer, n : Int, said : Json) -> Unit {
  let conn = match said {
    { "conn": Number(c, ..), .. } => c.to_int()
    _ => -1
  }
  let head = match said {
    { "head": h, .. } => h
    _ => Json::object({})
  }
  let body_str = match said {
    { "body": String(b), .. } => b
    _ => ""
  }
  let (status, headers, text) = match self.told.get(conn) {
    None =>
      (502, ({ "content-type": "application/json" } : Json), "{\"error\":\"the connection is gone\"}")
    Some((_, _, viewer)) => {
      let res = try {
        Ok((self.answer)(viewer, head, @utf8.encode(body_str)))
      } catch {
        e => Err(said_of(e))
      }
      match res {
        Err(m) =>
          (500, ({ "content-type": "application/json" } : Json), ({ "error": Json::string(m) } : Json).stringify())
        Ok(ans) => {
          let bytes = match ans.body {
            Whole(b) => b
            Coming(s) => {
              let buf = @buffer.new()
              while (try { (s.next)() } catch { _ => None }) is Some(chunk) {
                buf.write_bytes(chunk)
              }
              buf.to_bytes()
            }
          }
          (ans.status, headers_to_json(ans.headers), @utf8.decode_lossy(bytes))
        }
      }
    }
  }
  ignore(
    server.proc.post({
      "answered": Json::number(n.to_double()),
      "status": Json::number(status.to_double()),
      "headers": headers,
      "text": Json::string(text),
    }),
  )
}

///|
async fn Served::handle_relay(self : Served, server : ServedServer, n : Int, said : Json) -> Unit {
  let conn = match said {
    { "conn": Number(c, ..), .. } => c.to_int()
    _ => -1
  }
  let head = match said {
    { "head": h, .. } => h
    _ => Json::object({})
  }
  let body_str = match said {
    { "body": String(b), .. } => b
    _ => ""
  }
  let fail_stream = (m : String) => {
    ignore(
      server.proc.post({
        "answered": Json::number(n.to_double()),
        "status": 500,
        "headers": { "content-type": "application/json" },
      }),
    )
    ignore(server.proc.post({ "chunk": Json::number(n.to_double()), "text": Json::string(({ "error": Json::string(m) } : Json).stringify()) }))
    ignore(server.proc.post({ "done": Json::number(n.to_double()) }))
  }
  guard self.told.get(conn) is Some((_, _, viewer)) else {
    fail_stream("the connection is gone")
    return
  }
  let ans = match (try { Ok((self.answer)(viewer, head, @utf8.encode(body_str))) } catch { e => Err(said_of(e)) }) {
    Ok(a) => a
    Err(m) => {
      fail_stream(m)
      return
    }
  }
  ignore(
    server.proc.post({
      "answered": Json::number(n.to_double()),
      "status": Json::number(ans.status.to_double()),
      "headers": headers_to_json(ans.headers),
    }),
  )
  match ans.body {
    Whole(b) => {
      if b.length() > 0 {
        ignore(server.proc.post({ "chunk": Json::number(n.to_double()), "text": Json::string(@utf8.decode_lossy(b)) }))
      }
      ignore(server.proc.post({ "done": Json::number(n.to_double()) }))
    }
    Coming(s) => {
      let stopped = Ref(false)
      server.streaming[n] = () => {
        stopped.val = true
        (s.stop)()
      }
      while !stopped.val && !server.ended {
        match (try { Ok((s.next)()) } catch { e => Err(e) }) {
          Ok(Some(chunk)) =>
            if !stopped.val && !server.ended {
              ignore(server.proc.post({ "chunk": Json::number(n.to_double()), "text": Json::string(@utf8.decode_lossy(chunk)) }))
            }
          _ => break
        }
      }
      server.streaming.remove(n)
      if !stopped.val && !server.ended {
        ignore(server.proc.post({ "done": Json::number(n.to_double()) }))
      }
    }
  }
}

///|
async fn Served::handle_claim(self : Served, server : ServedServer, n : Int, said : Json) -> Unit {
  let conn = match said {
    { "conn": Number(c, ..), .. } => c.to_int()
    _ => -1
  }
  let req_path = match said {
    { "path": String(p), .. } => p
    _ => ""
  }
  let key = match said {
    { "key": String(k), .. } => Some(k)
    _ => None
  }
  let lang = match said {
    { "lang": String("en"), .. } => "en"
    _ => "zh"
  }
  let give = (field : String, value : Json) => {
    let m : Map[String, Json] = { "claimed": Json::number(n.to_double()) }
    m[field] = value
    ignore(server.proc.post(Json::object(m)))
  }
  guard self.told.get(conn) is Some((_, _, viewer)) else {
    give(
      "refused",
      { "status": 503, "headers": { "content-type": "application/json" }, "text": "{\"error\":\"station starting\"}" },
    )
    return
  }
  let got = try {
    Ok((self.claim)(viewer, req_path, key, lang))
  } catch {
    e => Err(said_of(e))
  }
  match got {
    Err(m) =>
      give(
        "refused",
        { "status": 500, "headers": { "content-type": "application/json" }, "text": Json::string(({ "error": Json::string(m) } : Json).stringify()) },
      )
    Ok(KeptAnswer(k)) => give("kept", kept_to_json(k))
    Ok(RefusedAnswer(k)) => give("refused", kept_to_json(k))
    Ok(Write(ts, settle)) => {
      if server.ended {
        settle(None) catch {
          _ => ()
        }
        return
      }
      server.claims[n] = settle
      give("ts", Json::string(ts))
    }
  }
}

///|
fn Served::handle_said(self : Served, server : ServedServer, of_n : Int, said : Json) -> Unit {
  let settle = server.claims.get(of_n)
  server.claims.remove(of_n)
  let answer : @api_routes.Kept? = match said {
    { "answer": { "status": Number(st, ..), "headers": Object(hs), "text": String(txt), .. }, .. } => {
      let headers : Map[String, String] = {}
      for k, v in hs {
        if v is String(s) {
          headers[k] = s
        }
      }
      Some(@api_routes.Kept::{ status: st.to_int(), headers, body: @utf8.encode(txt) })
    }
    _ => None
  }
  let posted : (Double, Double, String, Json)? = match said {
    { "said": { "thread": Number(t, ..), "n": Number(msg_n, ..), "text": String(text), "row": row, .. }, .. } =>
      Some((t, msg_n, text, row))
    _ => None
  }
  if posted is None && settle is None {
    return
  }
  fork_bg(self.host, "served said", async fn() {
    if posted is Some((t, msg_n, text, row)) {
      (self.said)(t, msg_n, text, row) catch {
        e => p51_log("WARN", "served", "delivering a message written by the serving program failed", fields={ "error": Json::string(said_of(e)) })
      }
    }
    if settle is Some(s) {
      s(answer) catch {
        _ => ()
      }
    }
  })
}

///|
/// Stops all `--serve` children and removes their socket files immediately (synchronous, safe for `scope_stops`).
fn Served::close_sync(self : Served) -> Unit {
  if self.closed {
    return
  }
  self.closed = true
  for stop in self.retry_stops {
    stop()
  }
  self.retry_stops.clear()
  for s in self.servers {
    for _, stop in s.streaming {
      stop()
    }
    s.streaming.clear()
    s.proc.stop()
    let sock = s.sock
    fork_bg(self.host, "served sock cleanup", async fn() {
      ignore(self.host.shell("fs.remove", { "path": Json::string(sock) })) catch {
        _ => ()
      }
    })
  }
}

///|
/// Waits briefly for all `--serve` children to exit and ensures their socket files are removed.
async fn Served::wait_closed(self : Served) -> Unit {
  self.close_sync()
  ignore(
    @effect.timeout(3_000, async fn() { // timer: a deadline to serving children stopping on shutdown
      for s in self.servers {
        if !s.proc.gone {
          s.proc.ended.wait()
        }
      }
    }),
  )
  for s in self.servers {
    if !s.proc.gone {
      ignore(kill(s.proc.proc.pid, "SIGKILL"))
    }
    ignore(self.host.shell("fs.remove", { "path": Json::string(s.sock) })) catch {
      _ => ()
    }
  }
}
