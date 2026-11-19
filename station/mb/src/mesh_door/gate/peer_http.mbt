// Programs on this machine reaching a web service on another station of the workspace as if it were here
// (station/src/mesh/peer-http.ts): on an ALPN of their own, admitted as the station transport admits (`peer_member`).
// One request a stream: a JSON head line `{workspace, port, method, path, headers, body}` and its body as it comes,
// answered with a JSON head line `{status, headers}` (headers as [name, value] pairs) and the service's body as it
// comes; a WebSocket's (`socket: true`) answered 101, then its frames both ways; a forwarded TCP connection's (`tcp:
// true`) answered 200 once the station there connected to its port, then its bytes both ways; `probe: true` only says
// whether it would be taken; a device's (`device`, `session`) let through by the device's own rules. What reaches this
// machine's services (a port, a preview's proxy, a device) is given (`HereLocal`).

///|
pub let peer_http_alpn : String = "stillfail/http/1"

///|
pub let http_max_head : Int = 256 * 1024

///|
pub let connect_ms : Int = 20000

///|
pub let head_ms : Int = 15000

///|
pub let max_refusal : Int = 64 * 1024

///|
pub let http_hop : Array[String] = [
  "connection", "keep-alive", "proxy-connection", "transfer-encoding", "upgrade",
  "te", "trailer", "host", "expect", "sec-websocket-key", "sec-websocket-version",
  "sec-websocket-extensions", "sec-websocket-accept",
]

///|
let timed_out : String = "peer http: no connection in time"

///|
/// Why a request was not passed on: its status and words; `unreachable` when the station itself was not reached.
pub(all) suberror HttpRefusal {
  HttpRefusal(Int, String, Bool)
}

///|
/// Why a chat may not reach a device here (its status).
pub(all) suberror DeviceRefused {
  DeviceRefused(Int, String)
}

///|
/// [name, value] pairs, names lowercase, what is not one left out.
pub fn http_pairs(raw : Json?) -> Array[(String, String)] {
  arr_of(raw).filter_map(p => match p {
    Array([String(k), String(v), ..]) => Some((k.to_lower(), v))
    _ => None
  })
}

///|
fn pairs_json(ps : Array[(String, String)]) -> Json {
  Json::array(ps.map(p => Json::array([Json::string(p.0), Json::string(p.1)])))
}

///|
/// A request's headers to pass on (flat, as Node's rawHeaders): not the hop's, nor those its Connection header names.
pub fn passed(raw : Array[String]) -> Array[(String, String)] {
  let named = []
  let mut i = 0
  while i + 1 < raw.length() {
    if raw[i].to_lower() == "connection" {
      for n in raw[i + 1].split(",") {
        named.push(n.trim(chars=" \t").to_owned().to_lower())
      }
    }
    i += 2
  }
  let out = []
  i = 0
  while i + 1 < raw.length() {
    let name = raw[i].to_lower()
    if !http_hop.contains(name) && !named.contains(name) {
      out.push((name, raw[i + 1]))
    }
    i += 2
  }
  out
}

///|
/// Station `id`'s name in this station's workspaces, or its id when it has none (peer-http.ts `nameOf`).
pub async fn name_of(k : Keeper, id : String) -> String {
  for m in (k.members_all)() {
    for p in arr_of(field(m, "peers")) {
      if str_of(field(p, "id")) == Some(id) {
        match str_of(field(p, "name")) {
          Some(n) if n != "" => return n
          _ => return id
        }
      }
    }
  }
  id
}

///|
/// The station a /peer URL names, by its id or its name, and the workspace it is asked in (peer-http.ts `peerNamed`).
pub async fn peer_named(k : Keeper, given : String) -> (String, String) {
  if !(k.peers_current)() {
    raise HttpRefusal(503, "the workspace's stations are not known right now (still.fail cloud not reached); try again shortly", false)
  }
  let all = (k.members_all)()
  let me = (k.station)()
  let lower = given.to_lower()
  let stations = []
  for m in all {
    for p in arr_of(field(m, "peers")) {
      if str_of(field(p, "id")) is Some(_) {
        stations.push(p)
      }
    }
    for r in (k.rigs)(str_of(field(m, "workspace")).unwrap_or("")) {
      stations.push(r)
    }
  }
  let uniq = (xs : Array[String]) => {
    let out = []
    for x in xs {
      if !out.contains(x) {
        out.push(x)
      }
    }
    out
  }
  let mut ids = uniq(stations.filter_map(p => if str_of(field(p, "id")) == Some(given) { Some(given) } else { None }))
  if ids.length() == 0 {
    ids = uniq(stations.filter_map(p => match str_of(field(p, "name")) {
      Some(n) if n.to_lower() == lower => str_of(field(p, "id"))
      _ => None
    }))
  }
  if ids.length() == 0 &&
    (given == me || all.iter().any(m => str_of(field(m, "name")).unwrap_or("").to_lower() == lower)) {
    ids = [me]
  }
  if ids.length() > 1 {
    raise HttpRefusal(409, "\{given} names \{ids.length()} stations (\{ids.join(", ")}): give the id of the one meant", false)
  }
  if ids.length() == 0 {
    let names = uniq(stations.filter_map(p => {
      let id = str_of(field(p, "id")).unwrap_or("")
      if id == me {
        None
      } else {
        match str_of(field(p, "name")) {
          Some(n) if n != "" => Some(n)
          _ => Some(id)
        }
      }
    }))
    raise HttpRefusal(404, "no station \{given} in this station's workspaces\{if names.length() > 0 { "; its stations: " + names.join(", ") } else { "" }}", false)
  }
  if ids[0] == me {
    raise HttpRefusal(400, "\{given} is this station: reach its services at http://localhost:<port>/ directly", false)
  }
  try {
    match (k.rig_of)(ids[0], None) {
      Some(rig) => (ids[0], str_of(field(rig, "workspace")).unwrap_or(""))
      None => (ids[0], peer_member(k, ids[0], None))
    }
  } catch {
    e => raise HttpRefusal(403, words_of(e), false)
  }
}

///|
/// This station's way to the others' web services (peer-http.ts `PeerHttp`): a connection kept per station, a stream a
/// request.
pub struct PeerHttp {
  priv k : Keeper
  priv dialing : Dialing
  priv rt : @effect.Runtime
  priv connections : Map[String, @effect.Deferred[@door.Connection]]
  priv connect_wait : Int
}

///|
pub fn PeerHttp::new(k : Keeper, dialing : Dialing, rt : @effect.Runtime, connect_wait? : Int = connect_ms) -> PeerHttp {
  { k, dialing, rt, connections: Map([]), connect_wait }
}

///|
/// Its connections end.
pub fn PeerHttp::close(self : PeerHttp) -> Unit {
  for _, made in self.connections {
    if (try { made.poll() } catch { _ => None }) is Some(c) {
      (c.close)(0, "station stopping")
    }
  }
  self.connections.clear()
}

///|
async fn PeerHttp::connect(self : PeerHttp, id : String, given : String, workspace : String) -> @door.Connection {
  let given_up = @effect.Deferred::new()
  if self.dialing.hold is Some(h) {
    h(id)
  }
  let dialed = @effect.timeout(self.connect_wait, () => (self.dialing.connect)(id, Some(workspace), given_up))
  let conn = match (try { Ok(dialed) } catch { e => Err(e) }) {
    Err(e) => raise HttpRefusal(502, "station \{given} cannot be reached: \{words_of(e)}", true)
    Ok(None) => {
      ignore(given_up.succeed(()))
      raise HttpRefusal(504, "station \{given} did not answer within \{(self.connect_wait + 500) / 1000} s: it is offline, or cannot be reached from here", true)
    }
    Ok(Some(c)) => c
  }
  if (conn.alpn)() != peer_http_alpn {
    (conn.close)(0, "web requests unsupported")
    raise HttpRefusal(502, "station \{given} is from before web requests between stations: it needs an update", false)
  }
  conn
}

///|
/// A new stream to station `id`: on the connection kept, or a new one when that one is gone.
async fn PeerHttp::stream(self : PeerHttp, id : String, given : String, workspace : String) -> @door.Stream {
  if self.dialing.hold is Some(h) {
    h(id)
  }
  for attempt = 0; ; attempt = attempt + 1 {
    let made = match self.connections.get(id) {
      Some(m) => m
      None => {
        let d = @effect.Deferred::new()
        self.connections[id] = d
        ignore(self.rt.fork_daemon("peer http dial", on_error=e => {
          if self.connections.get(id) is Some(x) && physical_equal(x, d) {
            self.connections.remove(id)
          }
          ignore(d.fail(e))
        }, () => {
          match (try { Ok(self.connect(id, given, workspace)) } catch { e => Err(e) }) {
            Ok(c) => ignore(d.succeed(c))
            Err(e) => {
              if self.connections.get(id) is Some(x) && physical_equal(x, d) {
                self.connections.remove(id)
              }
              ignore(d.fail(e))
            }
          }
        }))
        d
      }
    }
    let conn = made.wait()
    let off = match self.dialing.goes_off {
      Some(goes) if self.dialing.hold is None => attempt == 0 && !(conn.is_closed)() && goes(conn, id, Some(workspace))
      _ => false
    }
    if off {
      if self.connections.get(id) is Some(x) && physical_equal(x, made) {
        self.connections.remove(id)
      }
      @door.log("info", "mesh", "a station's web connection goes through a relay turned off: closed, dialed anew", { "peer": Json::string(short(id)) })
      (conn.close)(0, "its relay turned off")
      continue
    }
    let opened = try {
      if (conn.is_closed)() {
        raise Refused("connection lost")
      }
      Ok((conn.open_bi)())
    } catch {
      e => Err(e)
    }
    match opened {
      Ok(s) => return s
      Err(e) => {
        if self.connections.get(id) is Some(x) && physical_equal(x, made) {
          self.connections.remove(id)
        }
        if attempt > 0 {
          raise HttpRefusal(502, "station \{given} cannot be reached: \{words_of(e)}", true)
        }
      }
    }
  }
  raise Refused("unreachable")
}

///|
/// A TCP connection to localhost:`port` on `given` (a forward), or to a device attached there for chat `session`: once
/// that station connected, its stream and what came after the answer; with `probe`, only whether it would be taken
/// (None). Raises an HttpRefusal why not (peer-http.ts `tunnel`, `tunnelDevice`).
pub async fn PeerHttp::tunnel(self : PeerHttp, given : String, to : Json, probe? : Bool = false) -> (@door.Stream, Bytes)? {
  let (id, workspace) = peer_named(self.k, given)
  let station = name_of(self.k, id)
  let s = self.stream(id, station, workspace)
  try {
    let m : Map[String, Json] = { "workspace": Json::string(workspace) }
    if to is Object(t) {
      for key, v in t {
        m[key] = v
      }
    }
    m["tcp"] = Json::boolean(true)
    if probe {
      m["probe"] = Json::boolean(true)
    }
    @door.write_line(s, Json::object(m))
    if probe {
      (s.finish)()
    }
    let reader = @door.Reader::new(s, max_line=http_max_head)
    let answer = reader.line()
    let status = match answer { Some({ "status": Number(n, ..), .. }) => Some(n) ; _ => None }
    if status != Some(200.0) {
      let parts = [reader.take_carry()]
      let mut size = parts[0].length()
      while size < max_refusal && (s.read)() is Some(more) {
        parts.push(more)
        size += more.length()
      }
      let said = @door.concat(parts)
      let code = match status { Some(n) if n == n.floor() => n.to_int(); _ => 502 }
      raise HttpRefusal(
        code,
        if said.length() > 0 {
          @utf8.decode_lossy(@door.own(said[0:if said.length() < max_refusal { said.length() } else { max_refusal }]))
        } else {
          "station \{station} ended the connection without an answer"
        },
        false,
      )
    }
    if !probe {
      return Some((s, reader.take_carry()))
    }
    ignore(self.rt.fork_quiet(name="peer http reset", () => (s.reset)(0) catch { _ => () }))
    None
  } catch {
    e => {
      ignore(self.rt.fork_quiet(name="peer http reset", () => (s.reset)(0) catch { _ => () }))
      raise e
    }
  }
}

///|
/// A request of a program here, as the door gives it: its method, path at the service, flat headers (Node's
/// rawHeaders), and its body as it comes (None: none).
pub(all) struct LocalAsk {
  verb : String
  path : String
  raw_headers : Array[String]
  body : Body?
}

///|
/// Where a request's answer goes back to the program here: its head, its body as it comes, its end; whether it is gone.
pub(all) struct LocalAnswer {
  head : (Int, Array[String]) -> Unit
  write : async (Bytes) -> Unit
  end : () -> Unit
  destroy : () -> Unit
  gone : () -> Bool
  sent_head : () -> Bool
}

///|
/// A request to the door's /peer: passed on to the service there, its answer back as it comes (peer-http.ts
/// `request`). `target`: the station as given, its port, the path there.
pub async fn PeerHttp::request(self : PeerHttp, ask : LocalAsk, res : LocalAnswer, station : String, port : Int, path : String) -> Unit {
  let stream : Ref[@door.Stream?] = Ref(None)
  let plain = (status : Int, text : String) => {
    (res.head)(status, ["content-type", "text/plain; charset=utf-8"])
    ignore(self.rt.fork_quiet(name="peer http plain", () => {
      (res.write)(@utf8.encode(text)) catch { _ => () }
      (res.end)()
    }))
  }
  try {
    let (id, workspace) = peer_named(self.k, station)
    let s = self.stream(id, station, workspace)
    stream.val = Some(s)
    @door.write_line(s, {
      "workspace": Json::string(workspace),
      "port": Json::number(port.to_double()),
      "method": Json::string(ask.verb),
      "path": Json::string(path),
      "headers": pairs_json(passed(ask.raw_headers)),
      "body": Json::boolean(ask.body is Some(_)),
    })
    ignore(self.rt.fork_quiet(name="peer http upload", () => {
      if ask.body is Some(b) {
        while (b.next)() is Some(piece) {
          (s.write)(piece)
        }
      }
      (s.finish)()
    } catch { _ => () }))
    let reader = @door.Reader::new(s, max_line=http_max_head)
    let head = reader.line()
    let status = match head { Some({ "status": Number(n, ..), .. }) if n == n.floor() => n.to_int(); _ => -1 }
    if status < 0 {
      raise HttpRefusal(502, "station \{station} ended the request without an answer", false)
    }
    let out = []
    for p in http_pairs(field(head.unwrap(), "headers")) {
      if http_hop.contains(p.0) {
        continue
      }
      let kept = if p.0 == "location" && p.1.has_prefix("/") && !p.1.has_prefix("//") { "/peer/\{station}/\{port}\{p.1}" } else { p.1 }
      out.push(p.0)
      out.push(kept)
    }
    (res.head)(status, out)
    let carry = reader.take_carry()
    if carry.length() > 0 {
      (res.write)(carry)
    }
    while (s.read)() is Some(more) {
      if (res.gone)() {
        return
      }
      (res.write)(more)
    }
    (res.end)()
  } catch {
    e => {
      if stream.val is Some(s) {
        ignore(self.rt.fork_quiet(name="peer http reset", () => (s.reset)(0) catch { _ => () }))
      }
      if (res.sent_head)() {
        (res.destroy)()
      } else {
        match e {
          HttpRefusal(status, words, _) => plain(status, words)
          _ => plain(502, "station \{station}: \{words_of(e)}")
        }
      }
    }
  }
}

///|
/// What a station serving others' requests knows of this machine (peer-http.ts `HereLocal`): its ports reached (the
/// stream carried both ways to 127.0.0.1:`port`, raising why where nothing takes it there), which are its own or its
/// forwards' (refused), whether a station may reach it at all, a device reached for a chat (None: probe answered), a
/// service's answer (status, headers, body) and a WebSocket carried.
pub(all) struct HereLocal {
  reach : (async (Int) -> async (@door.Stream, Bytes) -> Unit)?
  own : (Int) -> Bool
  forwarded : ((Int) -> Bool)?
  allowed : ((String, String) -> String?)?
  device : (async (String, String, String, String, Bool) -> (async (@door.Stream, Bytes) -> Unit)?)?
  proxy : async (String, Array[(String, String)], Body?, Int, String) -> (Int, Array[(String, String)], Body)
  socket : async (Array[(String, String)], Int, String, @door.Stream, Bytes) -> Unit raise HttpRefusal
}

///|
/// An answer's end: what is left of the request is not wanted once it is all there.
async fn http_ended(stream : @door.Stream) -> Unit {
  (stream.finish)()
  ignore(@effect.runtime().fork(() => {
    ignore((stream.stopped)())
    (stream.reset)(0)
  } catch { _ => () }))
}

///|
async fn http_refuse(stream : @door.Stream, status : Int, text : String) -> Unit {
  @door.write_line(stream, { "status": Json::number(status.to_double()), "headers": [["content-type", "text/plain; charset=utf-8"]] })
  (stream.write)(@utf8.encode(text))
  http_ended(stream)
}

///|
async fn http_refusal(stream : @door.Stream, why : String) -> Unit {
  http_refuse(stream, if why.contains("not current") { 503 } else { 403 }, "that station refused: \{why}")
}

///|
/// Another station's connection on this protocol: each stream a request to a web service on this machine, while that
/// station is in a workspace with this one (peer-http.ts `serveHttp`).
pub async fn serve_http(k : Keeper, conn : @door.Connection, here : HereLocal) -> Unit {
  let rt = @effect.runtime()
  let peer = (conn.remote_id)()
  match (try { Ok(peer_member(k, peer, None)) } catch { e => Err(e) }) {
    Ok(_) => ()
    Err(e) => {
      let stream = @effect.timeout(head_ms, () => (conn.accept_bi)()) catch { _ => None }
      if stream is Some(Some(s)) {
        http_refusal(s, words_of(e)) catch {
          _ => ()
        }
        ignore(@effect.timeout(head_ms, () => (s.stopped)())) catch {
          _ => ()
        }
      }
      raise e
    }
  }
  let unlisten = (k.listen)(() => ignore(rt.fork_quiet(name="peer http member", () => {
    if (k.peers_current)() {
      peer_member(k, peer, None) |> ignore
    }
  } catch { _ => (conn.close)(3, "not in the workspace") })))
  defer unlisten()
  while (conn.accept_bi)() is Some(s) {
    ignore(rt.fork_daemon("peer http answer", on_error=_ => (), () => http_answer(k, peer, s, here) catch {
      e => {
        @door.log("info", "mesh", "a web request of another station failed", { "error": Json::string(words_of(e)) })
        (s.reset)(0) catch {
          _ => ()
        }
      }
    }))
  }
}

///|
async fn http_answer(k : Keeper, peer : String, stream : @door.Stream, here : HereLocal) -> Unit {
  let reader = @door.Reader::new(stream, max_line=http_max_head)
  guard within(head_ms, () => reader.line(), "no request head in time") is Some(head) else { return }
  let workspace = match field(head, "workspace") { Some(String(w)) => w; _ => "" }
  match (try { Ok(peer_member(k, peer, Some(workspace))) } catch { e => Err(e) }) {
    Ok(_) => ()
    Err(e) => return http_refusal(stream, words_of(e))
  }
  let is_tcp = field(head, "tcp") == Some(Json::boolean(true))
  let probe = field(head, "probe") == Some(Json::boolean(true))
  if field(head, "device") is Some(String(device)) && is_tcp {
    guard here.device is Some(reach) else { return http_refuse(stream, 404, "that station has no devices: it may need an update") }
    let session = match field(head, "session") { Some(String(s)) => s; _ => "" }
    let piped = try {
      Ok(reach(peer, workspace, session, device, probe))
    } catch {
      DeviceRefused(status, words) => Err((status, "that machine refused: \{words}"))
      e => Err((502, "the device could not be reached there: \{words_of(e)}"))
    }
    match piped {
      Err((status, text)) => return http_refuse(stream, status, text)
      Ok(None) => {
        @door.write_line(stream, { "status": 200 })
        return http_ended(stream)
      }
      Ok(Some(pipe)) => {
        @door.write_line(stream, { "status": 200 })
        return pipe(stream, reader.take_carry())
      }
    }
  }
  if here.allowed is Some(allowed) && allowed(peer, workspace) is Some(barred) {
    return http_refuse(stream, 403, "that machine refused: \{barred}")
  }
  let port = match field(head, "port") {
    Some(Number(n, ..)) if n == n.floor() && n >= 1.0 && n <= 65535.0 => n.to_int()
    _ => return http_refuse(stream, 400, "port: 1 to 65535")
  }
  if (here.own)(port) {
    return http_refuse(stream, 403, "port \{port} is the station's own there, not a service's")
  }
  if here.forwarded is Some(f) && f(port) {
    return http_refuse(stream, 403, "port \{port} there is a port that station forwards from another (peer_forward), not a service's: reach that one directly")
  }
  if is_tcp {
    if probe {
      @door.write_line(stream, { "status": 200 })
      return http_ended(stream)
    }
    guard here.reach is Some(reach) else { return http_refuse(stream, 502, "nothing takes connections on port \{port} there: no way to reach it") }
    let pipe = try {
      reach(port)
    } catch {
      e => return http_refuse(stream, 502, "nothing takes connections on port \{port} there: \{words_of(e)}")
    }
    @door.write_line(stream, { "status": 200 })
    return pipe(stream, reader.take_carry())
  }
  guard field(head, "path") is Some(String(path)) && path.has_prefix("/") else { return http_refuse(stream, 400, "path: from /") }
  let verb = match field(head, "method") { Some(String(m)) => m; _ => "GET" }
  let headers = http_pairs(field(head, "headers"))
  if field(head, "socket") == Some(Json::boolean(true)) {
    return (here.socket)(headers, port, path, stream, reader.take_carry()) catch {
      HttpRefusal(status, words, _) => http_refuse(stream, status, words)
    }
  }
  let body : Body? = if field(head, "body") == Some(Json::boolean(true)) {
    Some({ next: () => reader.chunk(), stop: () => (), check: None })
  } else {
    None
  }
  let (status, out, got) = (here.proxy)(verb, headers, body, port, path)
  let rt = @effect.runtime()
  let watch = rt.fork(() => {
    ignore((stream.stopped)()) catch {
      _ => ()
    }
    (got.stop)()
  })
  defer watch.interrupt()
  @door.write_line(stream, { "status": Json::number(status.to_double()), "headers": pairs_json(out) })
  while (got.next)() is Some(chunk) {
    (stream.write)(chunk)
  }
  http_ended(stream)
}
