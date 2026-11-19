// A port of another station's machine forwarded to one of this machine's 127.0.0.1 (station/src/mesh/peer-forward.ts):
// each connection to it carried over the mesh (peer_http.mbt's `tcp: true`) to that station's localhost port, its bytes
// both ways as they are; let go once idle `idle_ms` with no connection, with its job's end, its session's, the
// station's stop. A station found unreachable is not dialed again for `down_ms` (its connections refused at once). The
// sockets of this machine are the program's (`Sockets`: the shell's `tcp.*`, `tcp.pipe` and `istream.pipe`).

///|
pub let forward_idle_ms : Int = 30 * 60000

///|
pub let down_ms : Int = 10000

///|
let probe_ms : Int = 5000

///|
/// A connection a program here made to a forwarded port.
pub(all) struct Socket {
  remote_port : Int?
  abort : () -> Unit
  destroyed : () -> Bool
  closed : async () -> Unit
  /// Its bytes carried both ways with `stream` (what came after the answer first), till either ends.
  pipe : async (@door.Stream, Bytes) -> Unit
  /// Its bytes carried both ways with another socket (a device here).
  join : async (Socket) -> Unit
}

///|
/// A port listened on at 127.0.0.1: the port it has, what closes it.
pub(all) struct Server {
  port : Int
  close : () -> Unit
}

///|
pub(all) struct Sockets {
  /// Listens at 127.0.0.1:`port` (0: any free one), each connection given `take`; None where it is taken (by
  /// something else at 127.0.0.1 or [::1]; `mine`: by this station's own forward).
  listen : async (Int, Bool, (Socket) -> Unit) -> Server?
  /// The processes holding the other end of a connection from `port` here (a device's admission).
  holders : async (Int) -> Array[Int]
}

///|
/// The way to another station's ports and devices (peer_http.mbt `PeerHttp::tunnel`).
pub(all) struct Tunnels {
  tunnel : async (String, Int, Bool) -> (@door.Stream, Bytes)?
  tunnel_device : (async (String, String, String, Bool) -> (@door.Stream, Bytes)?)?
}

///|
/// A device forwarded: its id and name, how it is reached when it is attached here, who may (None: anyone).
pub(all) struct DeviceTarget {
  id : String
  name : String
  here : (async () -> Socket)?
  admit : (async (Array[Int]) -> String?)?
}

///|
/// A job a forward goes with.
pub(all) struct JobState {
  session : String
  state : String
  port : Int?
}

///|
priv struct Forward {
  session : String
  id : String
  name : String
  port : Int
  mut local : Int
  job : String?
  mut server : Server?
  sockets : Array[Socket]
  mut served : Int
  mut quiet_since : Int64
  mut idle : (() -> Unit)?
  mut down_until : Int64?
  mut failed : String?
  device : DeviceTarget?
}

///|
pub struct Forwards {
  priv rt : @effect.Runtime
  priv route : () -> Tunnels?
  priv resolve : async (String) -> (String, String)
  priv sockets : Sockets
  priv job : ((String) -> JobState?)?
  priv idle_ms : Int
  priv down_wait : Int
  priv by_local : Map[Int, Forward]
  priv mut closed : Bool
}

///|
pub fn Forwards::new(
  rt : @effect.Runtime,
  route : () -> Tunnels?,
  resolve : async (String) -> (String, String),
  sockets : Sockets,
  job? : (String) -> JobState?,
  idle_ms? : Int = forward_idle_ms,
  down_wait? : Int = down_ms,
) -> Forwards {
  { rt, route, resolve, sockets, job, idle_ms, down_wait, by_local: Map([]), closed: false }
}

///|
/// A job changed: the forwards that go with it let go where it is over.
pub fn Forwards::job_changed(self : Forwards, id : String) -> Unit {
  for _, f in self.by_local.copy() {
    if f.job == Some(id) && self.job_over(id) {
      self.shut(f, "its job ended")
    }
  }
}

///|
fn Forwards::job_over(self : Forwards, id : String) -> Bool {
  match self.job {
    None => true
    Some(j) =>
      match j(id) {
        None => true
        Some(s) => s.state == "stopped" || s.state == "failed" || (s.state == "exited" && s.port is None)
      }
  }
}

///|
fn Forwards::view(_self : Forwards, f : Forward) -> Map[String, Json] {
  let v : Map[String, Json] = {
    "local": Json::string("127.0.0.1:\{f.local}"),
    "url": Json::string("http://127.0.0.1:\{f.local}/"),
    "station": Json::string(f.name),
    "port": Json::number(f.port.to_double()),
    "connections": Json::number(f.sockets.length().to_double()),
    "served": Json::number(f.served.to_double()),
  }
  if f.device is Some(d) {
    v["device"] = Json::string(d.name)
  }
  if f.job is Some(j) {
    v["job"] = Json::string(j)
  }
  v
}

///|
fn Forwards::way(self : Forwards) -> Tunnels raise {
  match (self.route)() {
    Some(r) => r
    None => raise Refused("this station is not on the mesh yet; try again shortly")
  }
}

///|
/// Port `port` of `station` forwarded for `session` to 127.0.0.1:`local` (its own number where free, else another)
/// (peer-forward.ts `open`).
pub async fn Forwards::open(self : Forwards, session : String, station : String, port : Int, local? : Int, job? : String) -> Json {
  if self.closed {
    raise Refused("the station is stopping")
  }
  if port < 1 || port > 65535 {
    raise Refused("port: 1 to 65535")
  }
  if local is Some(l) && (l < 1 || l > 65535) {
    raise Refused("local_port: 1 to 65535")
  }
  if job is Some(j) {
    match self.job.bind(f => f(j)) {
      Some(s) if s.session == session => ()
      _ => raise Refused("no job \{j} of this session: job_list names them")
    }
    if self.job_over(j) {
      raise Refused("job \{j} has ended")
    }
  }
  let route = self.way()
  let (id, name) = (self.resolve)(station)
  for _, f in self.by_local {
    if f.session == session && f.id == id && f.port == port && f.job == job && (local is None || Some(f.local) == local) {
      let v = self.view(f)
      v["note"] = "already forwarded"
      return Json::object(v)
    }
  }
  ignore((route.tunnel)(id, port, true))
  let f : Forward = {
    session,
    id,
    name,
    port,
    local: 0,
    job,
    server: None,
    sockets: [],
    served: 0,
    quiet_since: self.rt.now(),
    idle: None,
    down_until: None,
    failed: None,
    device: None,
  }
  let take = (s : Socket) => self.connection(f, s)
  let want = local.unwrap_or(port)
  let mut server = (self.sockets.listen)(want, self.by_local.contains(want), take)
  if server is None && local is Some(l) {
    raise Refused("127.0.0.1:\{l} is taken here (something listens on it, at 127.0.0.1 or [::1]); give another local_port, or none")
  }
  if server is None {
    server = (self.sockets.listen)(0, false, take)
    if server is None {
      raise Refused("no port could be had on 127.0.0.1")
    }
  }
  let srv = server.unwrap()
  f.server = Some(srv)
  f.local = srv.port
  let note = if local is None && f.local != port { Some("port \{port} is taken here, so it is at \{f.local}") } else { None }
  if self.closed || (job is Some(j) && self.job_over(j)) {
    (srv.close)()
    raise Refused(if self.closed { "the station is stopping" } else { "job \{job.unwrap()} has ended" })
  }
  self.by_local[f.local] = f
  self.quiet(f)
  @door.log("info", "mesh", "a port forwarded", {
    "session": Json::string(session),
    "station": Json::string(id),
    "port": Json::number(port.to_double()),
    "local": Json::number(f.local.to_double()),
  })
  let v = self.view(f)
  if note is Some(n) {
    v["note"] = Json::string(n)
  }
  Json::object(v)
}

///|
/// A device attached to `station` (or this one, `self_`) forwarded for `session` (peer-forward.ts `openDevice`).
pub async fn Forwards::open_device(self : Forwards, session : String, station : String, device : DeviceTarget, self_ : Bool) -> Json {
  if self.closed {
    raise Refused("the station is stopping")
  }
  let (id, name) = if self_ { (station, "this station") } else { (self.resolve)(station) }
  for _, f in self.by_local {
    if f.session == session && f.id == id && f.device.map(d => d.id) == Some(device.id) {
      let v = self.view(f)
      v["note"] = "already forwarded"
      return Json::object(v)
    }
  }
  if !self_ {
    let route = self.way()
    guard route.tunnel_device is Some(td) else { raise Refused("this station cannot reach devices over the mesh") }
    ignore(td(id, device.id, session, true))
  }
  let f : Forward = {
    session,
    id,
    name,
    port: 0,
    local: 0,
    job: None,
    server: None,
    sockets: [],
    served: 0,
    quiet_since: self.rt.now(),
    idle: None,
    down_until: None,
    failed: None,
    device: Some(device),
  }
  guard (self.sockets.listen)(0, false, s => self.connection(f, s)) is Some(srv) else {
    raise Refused("no port could be had on 127.0.0.1")
  }
  f.server = Some(srv)
  f.local = srv.port
  if self.closed {
    (srv.close)()
    raise Refused("the station is stopping")
  }
  self.by_local[f.local] = f
  self.quiet(f)
  @door.log("info", "mesh", "a device forwarded", {
    "session": Json::string(session),
    "station": Json::string(id),
    "device": Json::string(device.id),
    "local": Json::number(f.local.to_double()),
  })
  Json::object(self.view(f))
}

///|
pub fn Forwards::close_device(self : Forwards, session : String?, device : String?, why : String) -> Unit {
  for _, f in self.by_local.copy() {
    if f.device is Some(d) && (device is None || device == Some(d.id)) && (session is None || session == Some(f.session)) {
      self.shut(f, why)
    }
  }
}

///|
fn Forwards::current(self : Forwards, f : Forward) -> Bool {
  match self.by_local.get(f.local) {
    Some(x) => physical_equal(x, f)
    None => false
  }
}

///|
fn Forwards::connection(self : Forwards, f : Forward, socket : Socket) -> Unit {
  if !self.by_local.contains(f.local) {
    (socket.abort)()
    return
  }
  f.sockets.push(socket)
  f.served += 1
  if f.idle is Some(off) {
    off()
  }
  f.idle = None
  ignore(self.rt.fork_daemon("forward socket closed", on_error=_ => (), () => {
    (socket.closed)() catch {
      _ => ()
    }
    match f.sockets.search_by(s => physical_equal(s, socket)) {
      Some(i) => ignore(f.sockets.remove(i))
      None => ()
    }
    if f.sockets.length() == 0 && self.current(f) {
      self.quiet(f)
    }
  }))
  if f.device is Some(device) {
    ignore(self.rt.fork_daemon("forward device", on_error=_ => (socket.abort)(), () => self.device_connection(f, device, socket) catch {
      e => {
        f.failed = Some(words_of(e))
        (socket.abort)()
      }
    }))
    return
  }
  let now = self.rt.now()
  if f.down_until is Some(until) && now < until {
    (socket.abort)()
    return
  }
  guard (self.route)() is Some(route) else {
    f.failed = Some("this station is not on the mesh")
    (socket.abort)()
    return
  }
  ignore(self.rt.fork_daemon("forward tunnel", on_error=e => {
    f.failed = Some(words_of(e))
    (socket.abort)()
  }, () => {
    match (try { Ok((route.tunnel)(f.id, f.port, false)) } catch { e => Err(e) }) {
      Ok(tunnel) => {
        f.down_until = None
        guard tunnel is Some((stream, carry)) else { return (socket.abort)() }
        if (socket.destroyed)() || !self.current(f) {
          return (stream.reset)(0) catch { _ => () }
        }
        (socket.pipe)(stream, carry) catch {
          _ => ()
        }
      }
      Err(e) => {
        let why = words_of(e)
        f.failed = Some(why)
        if e is HttpRefusal(_, _, true) {
          f.down_until = Some(self.rt.now() + self.down_wait.to_int64())
        }
        (socket.abort)()
      }
    }
  }))
}

///|
async fn Forwards::device_connection(self : Forwards, f : Forward, device : DeviceTarget, socket : Socket) -> Unit {
  let why = match device.admit {
    None => None
    Some(admit) => {
      let holders = match socket.remote_port {
        Some(p) => (self.sockets.holders)(p) catch { _ => [] }
        None => []
      }
      admit(holders)
    }
  }
  if why is Some(w) {
    f.failed = Some(w)
    return (socket.abort)()
  }
  if (socket.destroyed)() || !self.current(f) {
    return
  }
  if device.here is Some(here) {
    let d = here()
    if (socket.destroyed)() {
      return (d.abort)()
    }
    return (socket.join)(d)
  }
  guard (self.route)() is Some(route) && route.tunnel_device is Some(td) else {
    f.failed = Some("this station is not on the mesh")
    return (socket.abort)()
  }
  guard td(f.id, device.id, f.session, false) is Some((stream, carry)) else { return (socket.abort)() }
  if (socket.destroyed)() || !self.current(f) {
    return (stream.reset)(0) catch { _ => () }
  }
  (socket.pipe)(stream, carry)
}

///|
fn Forwards::quiet(self : Forwards, f : Forward) -> Unit {
  f.quiet_since = self.rt.now()
  if f.idle is Some(off) {
    off()
  }
  f.idle = Some(@door.after(self.rt, self.idle_ms, () => if f.sockets.length() == 0 { self.shut(f, "idle") }))
}

///|
fn Forwards::shut(self : Forwards, f : Forward, why : String) -> Unit {
  if !self.current(f) {
    return
  }
  self.by_local.remove(f.local)
  if f.idle is Some(off) {
    off()
  }
  f.idle = None
  if f.server is Some(s) {
    (s.close)()
  }
  for s in f.sockets.copy() {
    (s.abort)()
  }
  @door.log("info", "mesh", "a forwarded port closed", {
    "session": Json::string(f.session),
    "station": Json::string(f.id),
    "port": Json::number(f.port.to_double()),
    "local": Json::number(f.local.to_double()),
    "why": Json::string(why),
  })
}

///|
/// A session's forwards, each with how its station is now (probed) (peer-forward.ts `list`).
pub async fn Forwards::list(self : Forwards, session : String) -> Array[Json] {
  let mine = []
  for _, f in self.by_local {
    if f.session == session {
      mine.push(f)
    }
  }
  mine.sort_by((a, b) => a.local - b.local)
  let route = (self.route)()
  let out = []
  for f in mine {
    let v = self.view(f)
    if f.device is Some({ here: Some(_), .. }) {
      v["station_state"] = "online"
    } else {
      match route {
        None => v["station_state"] = "unknown: this station is not on the mesh"
        Some(r) => {
          let probed = try {
            let p = match f.device {
              Some(d) => match r.tunnel_device { Some(td) => @effect.timeout(probe_ms, () => ignore(td(f.id, d.id, f.session, true))); None => Some(()) }
              None => @effect.timeout(probe_ms, () => ignore((r.tunnel)(f.id, f.port, true)))
            }
            match p {
              Some(_) => Ok(())
              None => Err((false, "offline: no answer within \{probe_ms / 1000} s"))
            }
          } catch {
            HttpRefusal(_, w, unreachable) => Err((unreachable, w))
            e => Err((false, words_of(e)))
          }
          match probed {
            Ok(_) => {
              v["station_state"] = "online"
              f.down_until = None
            }
            Err((unreachable, why)) =>
              v["station_state"] = Json::string(if unreachable && !why.has_prefix("offline") { "offline: \{why}" } else { why })
          }
        }
      }
    }
    if f.failed is Some(w) {
      v["last_error"] = Json::string(w)
    }
    if f.sockets.length() == 0 {
      v["idle_minutes"] = Json::number(((self.rt.now() - f.quiet_since) / 60000L).to_double())
    }
    out.push(Json::object(v))
  }
  out
}

///|
pub fn Forwards::remove(self : Forwards, session : String, local : Int) -> Json raise {
  match self.by_local.get(local) {
    Some(f) if f.session == session => {
      let v = self.view(f)
      self.shut(f, "closed")
      Json::object(v)
    }
    _ => raise Refused("no forward of this session at 127.0.0.1:\{local}: peer_forward {} lists them")
  }
}

///|
pub fn Forwards::close_session(self : Forwards, session : String) -> Unit {
  for _, f in self.by_local.copy() {
    if f.session == session {
      self.shut(f, "its session ended")
    }
  }
}

///|
pub fn Forwards::forwarded(self : Forwards, port : Int) -> Bool {
  self.by_local.contains(port)
}

///|
pub fn Forwards::count(self : Forwards, session? : String) -> Int {
  let mut n = 0
  for _, f in self.by_local {
    if session is None || session == Some(f.session) {
      n += 1
    }
  }
  n
}

///|
pub fn Forwards::close(self : Forwards) -> Unit {
  self.closed = true
  for _, f in self.by_local.copy() {
    self.shut(f, "the station stopped")
  }
}
