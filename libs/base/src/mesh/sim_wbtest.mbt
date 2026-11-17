// Two meshes over a network of the test's: a device's mesh (`client`) dialling a peer's (`server`), whose endpoint
// takes connections on the protocol (`Binding.takes`) and whose program (`Door`) lets them in, answers their control
// lines and serves their streams, as a peer's door does. Each mesh has a shell stood in (`@shell.Shell::stood_in`),
// and both shells are one network's (`SimNet`): what one writes the other reads, on one runtime of the test's own
// clock (`@effect.Runtime::new`), so nothing here waits on real time and it runs the same on native and on js.
//
// The network's ways (`SimNet::relay`, `SimNet::direct`): relays, which an endpoint bound on them reaches a peer on
// them through, and addresses a peer is reached at straight (its LAN's, its tailnet's). Each way takes `ms` each
// way, carries `bps` bytes a second (0: no bound), and may be `down`: a dial on it goes unanswered, and what is sent
// on a connection over it is lost, the connection not ending. A dial goes the way its endpoint and its peer's
// address give: at an address said where the endpoint may go straight and the way is up (quickest first), else
// through the first relay of its endpoint's that is up and that the peer is on; none, it waits until given up. Its
// handshake takes a round trip; its connection says that way as its path (`conn.paths`: the relay, or the address),
// and counts what crossed it each way (`conn.stats`). What is sent on a stream comes a way's time later, after what
// went on that connection before it took its turn at the way's speed: a long body comes in pieces over time.
//
// The handles are each shell's own, numbered as given out, and let go of as both shells let go of them: a stream
// once reset, or read to its end and finished; a connection, its streams with it, closed with `forget`; an endpoint,
// its connections with it, closed with `forget`. So a test sees what either shell still holds. A stream is offered its peer (`conn.acceptBi`) as the
// first of what is sent on it comes. A connection closed at one end ends at the other a way's time later with the
// reason given (its way down: by the transport's idle time, `sim_idle_ms`); an endpoint closed ends its connections.

///|
/// How long a connection whose way is down takes to end at the far end once the near end closed it.
let sim_idle_ms : Int = 30_000

///|
/// The protocol both meshes are on.
let sim_alpn : String = "sim/1"

///|
let sim_r1 : String = "https://r1.sim/"

///|
let sim_r2 : String = "https://r2.sim/"

///|
/// A way of the network.
priv struct SimWay {
  /// A relay (as a key), or an address `a.b.c.d:port`.
  name : String
  relay : Bool
  mut ms : Int
  bps : Double
  mut down : Bool
  /// Whose endpoint an address reaches (its id); none for a relay.
  owner : String?
}

///|
/// An endpoint bound at one of the shells.
priv struct SimEnd {
  side : Int
  id : String
  relays : Array[String]
  relay_only : Bool
  alpns : Array[String]
  mut closed : Bool
  /// The waits for a connection dialled to it (`iroh.accept`), and those that came with nobody waiting.
  accepts : Array[Int64]
  coming : Array[SimConn]
  conns : Array[SimConn]
}

///|
/// A connection: its two ends by role (0 the dialler, 1 the one dialled).
priv struct SimConn {
  ends : FixedArray[SimEnd]
  handles : FixedArray[Int]
  way : SimWay
  alpn : String
  ended : FixedArray[Json?]
  forgot : FixedArray[Bool]
  waits : FixedArray[Array[Int64]]
  rx : FixedArray[Double]
  tx : FixedArray[Double]
  /// Until when what each end sends is still going out at the way's speed.
  busy : FixedArray[Int64]
  /// The streams the other end opened that this end has not taken, and its wait for the next.
  offered : FixedArray[Array[SimStream]]
  accepting : FixedArray[Array[Int64]]
  streams : Array[SimStream]
}

///|
/// What one end sends on a stream, at the other end.
priv struct SimFlow {
  came : Array[Bytes?]
  mut reader : Int64?
  mut reset : Bool
  /// The other end read it to its end; and the sender's wait to be told it was taken or stopped.
  mut read_end : Bool
  mut stopper : Int64?
}

///|
priv struct SimStream {
  conn : SimConn
  handles : FixedArray[Int]
  /// By the role that sends it.
  flows : FixedArray[SimFlow]
  /// By role: finished its sending.
  finished : FixedArray[Bool]
  mut announced : Bool
}

///|
priv enum SimHandle {
  End(SimEnd)
  Conn(SimConn, Int)
  Stream(SimStream, Int)
}

///|
priv struct SimNet {
  rt : @effect.Runtime
  shells : Array[@shell.Shell]
  handles : Array[Map[Int, SimHandle]]
  last : Array[Int]
  ways : Map[String, SimWay]
  /// The dials under way that no way answers: the side, the call, the endpoint.
  dials : Array[(Int, Int64, SimEnd)]
  /// Every op asked at each side: `<op> <handle>`.
  said : Array[Array[String]]
  /// What `istream.tap` answers (none: no such op), and each asked.
  mut taps : Bool?
  tapped : Array[String]
  /// The keys each side's binds were given.
  keys : Array[Array[Bytes]]
}

///|
fn sim_hex(bytes : Bytes) -> String {
  hex_bytes(bytes)
}

///|
fn SimNet::new() -> SimNet {
  let rt = @effect.Runtime::new()
  let net : SimNet = {
    rt,
    shells: [],
    handles: [Map([]), Map([])],
    last: [0, 0],
    ways: Map([]),
    dials: [],
    said: [[], []],
    taps: None,
    tapped: [],
    keys: [[], []],
  }
  for side in 0..<2 {
    let shell = @shell.Shell::stood_in(
      rt,
      calls=(id, op, args, bytes) => net.call(side, id, op, args, bytes),
      asks=(op, args) => net.ask(side, op, args),
      draws=n => Bytes::make(n, (0x40 + side).to_byte()),
    )
    net.shells.push(shell)
  }
  net
}

///|
/// A relay of the network, `ms` each way, `bps` bytes a second.
fn SimNet::relay(self : SimNet, url : String, ms~ : Int, bps? : Double = 0.0) -> SimWay {
  let way : SimWay = { name: relay_key(url), relay: true, ms, bps, down: false, owner: None }
  self.ways[way.name] = way
  way
}

///|
/// An address the endpoint `owner` is reached at straight.
fn SimNet::direct(self : SimNet, addr : String, owner : String, ms~ : Int, bps? : Double = 0.0) -> SimWay {
  let way : SimWay = { name: addr, relay: false, ms, bps, down: false, owner: Some(owner) }
  self.ways[addr] = way
  way
}

///|
fn SimNet::give(self : SimNet, side : Int, handle : SimHandle) -> Int {
  self.last[side] += 1
  self.handles[side][self.last[side]] = handle
  self.last[side]
}

///|
fn SimNet::answer(self : SimNet, side : Int, id : Int64, json : Json, bytes? : Bytes) -> Unit {
  self.shells[side].answer(id, json, bytes?)
}

///|
fn SimNet::refuse(self : SimNet, side : Int, id : Int64, why : String) -> Unit {
  self.shells[side].refuse(id, why)
}

///|
fn id_json(n : Int) -> Json {
  Json::number(n.to_double())
}

///|
/// `f` after `ms` on the test's clock (at once where none).
fn SimNet::later(self : SimNet, ms : Int64, f : () -> Unit) -> Unit {
  if ms <= 0L {
    f()
  } else {
    self.rt.after(ms.to_int(), f)
  }
}

///|
/// The way a dial from `end` to `addr` goes, and the endpoint it reaches; none where none is up.
fn SimNet::route(self : SimNet, end : SimEnd, addr : Json) -> (SimWay, SimEnd)? {
  let id = match addr {
    { "id": String(id), .. } => id
    _ => return None
  }
  let target = self.ends().iter().find_first(one => one.id == id && !one.closed && one.side != end.side)
  guard target is Some(target) else { return None }
  if !end.relay_only && addr is { "ips": Array(ips), .. } {
    let mut best : SimWay? = None
    for ip in ips {
      guard ip is String(ip) && self.ways.get(ip) is Some(way) && !way.down && way.owner == Some(id) else {
        continue
      }
      if best is None || way.ms < best.unwrap().ms {
        best = Some(way)
      }
    }
    if best is Some(way) {
      return Some((way, target))
    }
  }
  let asked : Array[String] = match addr {
    { "relays": Array(relays), .. } => relays.filter_map(r => if r is String(r) { Some(relay_key(r)) } else { None })
    _ => []
  }
  for relay in end.relays {
    guard asked.contains(relay) && target.relays.contains(relay) else { continue }
    guard self.ways.get(relay) is Some(way) && !way.down else { continue }
    return Some((way, target))
  }
  None
}

///|
/// Every endpoint bound, at either side.
fn SimNet::ends(self : SimNet) -> Array[SimEnd] {
  let out : Array[SimEnd] = []
  for side in 0..<2 {
    for _, h in self.handles[side] {
      if h is End(end) {
        out.push(end)
      }
    }
  }
  out
}

///|
/// `piece` sent by `role` on `stream`: it comes at the other end after what went before it on the connection, at
/// the way's speed, and the way's time; on a way down it is lost.
fn SimNet::send(self : SimNet, stream : SimStream, role : Int, piece : Bytes?) -> Unit {
  let conn = stream.conn
  let length = match piece {
    Some(b) => b.length()
    None => 0
  }
  conn.tx[role] += length.to_double()
  let way = conn.way
  guard !way.down else { return }
  let now = self.rt.now()
  let start = if conn.busy[role] > now { conn.busy[role] } else { now }
  let takes = if way.bps > 0.0 { (length.to_double() * 1000.0 / way.bps).to_int64() } else { 0L }
  conn.busy[role] = start + takes
  let at = start + takes + way.ms.to_int64()
  self.later(at - now, () => {
    let other = 1 - role
    guard conn.ended[other] is None else { return }
    if !stream.announced {
      stream.announced = true
      self.offer(stream, other)
    }
    conn.rx[other] += length.to_double()
    let flow = stream.flows[role]
    guard !flow.reset else { return }
    flow.came.push(piece)
    self.wake_reader(stream, role)
  })
}

///|
/// The stream offered to the end `role` of its connection: to its wait for one, else kept for the next.
fn SimNet::offer(self : SimNet, stream : SimStream, role : Int) -> Unit {
  let conn = stream.conn
  if conn.accepting[role].length() > 0 {
    let id = conn.accepting[role].remove(0)
    let side = conn.ends[role].side
    stream.handles[role] = self.give(side, Stream(stream, role))
    self.answer(side, id, { "id": id_json(stream.handles[role]) })
  } else {
    conn.offered[role].push(stream)
  }
}

///|
/// The reader of what `role` sends on `stream` given what came, where it waits.
fn SimNet::wake_reader(self : SimNet, stream : SimStream, role : Int) -> Unit {
  let flow = stream.flows[role]
  guard flow.reader is Some(id) && flow.came.length() > 0 else { return }
  flow.reader = None
  let side = stream.conn.ends[1 - role].side
  match flow.came.remove(0) {
    Some(bytes) => self.answer(side, id, {}, bytes~)
    None => {
      flow.read_end = true
      self.answer(side, id, { "end": true })
      self.settle(stream, 1 - role)
      if stream.flows[role].stopper is Some(stopper) {
        stream.flows[role].stopper = None
        self.answer(stream.conn.ends[role].side, stopper, { "code": Json::null() })
      }
    }
  }
}

///|
/// The handle of `stream` at its end `role` let go of where both shells let go of one: read to its end and finished.
fn SimNet::settle(self : SimNet, stream : SimStream, role : Int) -> Unit {
  guard stream.finished[role] && stream.flows[1 - role].read_end && stream.handles[role] != 0 else { return }
  self.handles[stream.conn.ends[role].side].remove(stream.handles[role])
}

///|
/// `conn` let go of at its end `role` (closed with `forget`, or with its endpoint so): its handle there, and its
/// streams', as both shells let them go.
fn SimNet::forget_conn(self : SimNet, conn : SimConn, role : Int) -> Unit {
  conn.forgot[role] = true
  let side = conn.ends[role].side
  if conn.handles[role] != 0 {
    self.handles[side].remove(conn.handles[role])
  }
  for stream in conn.streams {
    if stream.handles[role] != 0 {
      self.handles[side].remove(stream.handles[role])
    }
  }
}

///|
/// The end `role` of `conn` ended, `why`: its waits told, its reads and waits for streams answered.
fn SimNet::end_side(self : SimNet, conn : SimConn, role : Int, why : Json) -> Unit {
  guard conn.ended[role] is None else { return }
  conn.ended[role] = Some(why)
  let side = conn.ends[role].side
  let waits = conn.waits[role].copy()
  conn.waits[role].clear()
  for id in waits {
    self.answer(side, id, why)
  }
  for stream in conn.streams {
    let flow = stream.flows[1 - role]
    if flow.reader is Some(id) {
      flow.reader = None
      self.refuse(side, id, "connection closed")
    }
    if stream.flows[role].stopper is Some(id) {
      stream.flows[role].stopper = None
      self.refuse(side, id, "connection closed")
    }
  }
  let accepting = conn.accepting[role].copy()
  conn.accepting[role].clear()
  for id in accepting {
    self.answer(side, id, { "end": true })
  }
}

///|
/// `conn` closed by its end `role`, saying `reason`: ended there at once, at the other end a way's time later (by
/// the idle time where its way is down).
fn SimNet::close_conn(self : SimNet, conn : SimConn, role : Int, reason : String) -> Unit {
  guard conn.ended[role] is None else { return }
  self.end_side(conn, role, { "kind": "local", "reason": "closed" })
  let other = 1 - role
  if conn.way.down {
    self.later(sim_idle_ms.to_int64(), () => self.end_side(conn, other, { "kind": "timeout", "reason": "" }))
  } else {
    self.later(conn.way.ms.to_int64(), () => self.end_side(conn, other, {
      "kind": "application",
      "reason": Json::string(reason),
    }))
  }
}

///|
fn SimNet::handle(self : SimNet, side : Int, args : Json) -> SimHandle? {
  self.handles[side].get(handle_of(args))
}

///|
fn SimNet::call(self : SimNet, side : Int, id : Int64, op : String, args : Json, bytes : Bytes?) -> Unit {
  let h = self.handle(side, args)
  self.said[side].push("\{op} \{handle_of(args)}")
  match (op, h) {
    ("iroh.bind", _) => {
      let key = bytes.unwrap_or(b"")
      self.keys[side].push(key)
      let strings_of = (json : Json?) => match json {
        Some(Array(items)) => items.filter_map(one => if one is String(s) { Some(s) } else { None })
        _ => []
      }
      let fields = match args {
        Object(fields) => fields
        _ => Map([])
      }
      let end : SimEnd = {
        side,
        id: sim_hex(sha256(key)),
        relays: strings_of(fields.get("relayUrls")).map(relay_key),
        relay_only: fields.get("relayOnly") is Some(True),
        alpns: strings_of(fields.get("alpns")),
        closed: false,
        accepts: [],
        coming: [],
        conns: [],
      }
      self.answer(side, id, { "id": id_json(self.give(side, End(end))) })
    }
    ("iroh.close", Some(End(end))) => {
      end.closed = true
      for conn in end.conns {
        let role = if physical_equal(conn.ends[0], end) { 0 } else { 1 }
        self.close_conn(conn, role, "endpoint closed")
      }
      for dial in self.dials.copy() {
        if physical_equal(dial.2, end) {
          self.dials.retain(one => one.1 != dial.1)
          self.refuse(dial.0, dial.1, "the endpoint is closed")
        }
      }
      for wait in end.accepts {
        self.answer(side, wait, { "end": true })
      }
      end.accepts.clear()
      if args is { "forget": True, .. } {
        self.handles[side].remove(handle_of(args))
        for conn in end.conns {
          self.forget_conn(conn, if physical_equal(conn.ends[0], end) { 0 } else { 1 })
        }
      }
      self.answer(side, id, {})
    }
    ("iroh.connect", Some(End(end))) => {
      guard !end.closed else { return self.refuse(side, id, "the endpoint is closed") }
      let alpn = sim_hex(bytes.unwrap_or(b""))
      let addr = match args {
        { "addr": addr, .. } => addr
        _ => Json::null()
      }
      match self.route(end, addr) {
        Some((way, target)) if target.alpns.contains(alpn) =>
          self.later((2 * way.ms).to_int64(), () => {
            guard !end.closed && !target.closed && !way.down else {
              // (the way went down, or an end closed, during the handshake: unanswered, as a dial on none)
              self.dials.push((side, id, end))
              return
            }
            let conn : SimConn = {
              ends: [end, target],
              handles: [0, 0],
              way,
              alpn,
              ended: [None, None],
              forgot: [false, false],
              waits: [[], []],
              rx: [0.0, 0.0],
              tx: [0.0, 0.0],
              busy: [0L, 0L],
              offered: [[], []],
              accepting: [[], []],
              streams: [],
            }
            end.conns.push(conn)
            target.conns.push(conn)
            conn.handles[0] = self.give(side, Conn(conn, 0))
            self.answer(side, id, { "id": id_json(conn.handles[0]) })
            self.arrive(target, conn)
          })
        _ => self.dials.push((side, id, end))
      }
    }
    ("iroh.accept", Some(End(end))) =>
      if end.closed {
        self.answer(side, id, { "end": true })
      } else if end.coming.length() > 0 {
        let conn = end.coming.remove(0)
        conn.handles[1] = self.give(side, Conn(conn, 1))
        self.answer(side, id, { "id": id_json(conn.handles[1]), "alpn": Json::string(conn.alpn) })
      } else {
        end.accepts.push(id)
      }
    ("iroh.networkChange" | "iroh.setRelayEntries", _) => self.answer(side, id, {})
    ("conn.openBi", Some(Conn(conn, role))) =>
      match conn.ended[role] {
        Some(why) => self.refuse(side, id, "connection closed: \{why.stringify()}")
        None => {
          let stream : SimStream = {
            conn,
            handles: [0, 0],
            flows: [SimFlow::new(), SimFlow::new()],
            finished: [false, false],
            announced: false,
          }
          conn.streams.push(stream)
          stream.handles[role] = self.give(side, Stream(stream, role))
          self.answer(side, id, { "id": id_json(stream.handles[role]) })
        }
      }
    ("conn.acceptBi", Some(Conn(conn, role))) =>
      if conn.ended[role] is Some(_) {
        self.answer(side, id, { "end": true })
      } else if conn.offered[role].length() > 0 {
        let stream = conn.offered[role].remove(0)
        stream.handles[role] = self.give(side, Stream(stream, role))
        self.answer(side, id, { "id": id_json(stream.handles[role]) })
      } else {
        conn.accepting[role].push(id)
      }
    ("conn.closed", Some(Conn(conn, role))) =>
      match conn.ended[role] {
        Some(why) => self.answer(side, id, why)
        None => conn.waits[role].push(id)
      }
    ("conn.close", Some(Conn(conn, role))) => {
      let reason = match args {
        { "reason": String(reason), .. } => reason
        _ => ""
      }
      self.close_conn(conn, role, reason)
      if args is { "forget": True, .. } {
        self.forget_conn(conn, role)
      }
      self.answer(side, id, {})
    }
    ("istream.write" | "istream.finish", Some(Stream(stream, role))) => {
      let conn = stream.conn
      if conn.ended[role] is Some(_) {
        return self.refuse(side, id, "connection closed")
      }
      if stream.flows[role].reset {
        return self.refuse(side, id, "stream stopped")
      }
      self.send(stream, role, if op == "istream.write" { Some(bytes.unwrap_or(b"")) } else { None })
      self.answer(side, id, {})
      if op == "istream.finish" {
        stream.finished[role] = true
        self.settle(stream, role)
      }
    }
    ("istream.read", Some(Stream(stream, role))) => {
      let flow = stream.flows[1 - role]
      if flow.came.length() > 0 {
        flow.reader = Some(id)
        self.wake_reader(stream, 1 - role)
      } else if flow.reset {
        self.refuse(side, id, "stream reset")
      } else if stream.conn.ended[role] is Some(_) {
        self.refuse(side, id, "connection closed")
      } else {
        flow.reader = Some(id)
      }
    }
    ("istream.reset", Some(Stream(stream, role))) => {
      self.handles[side].remove(handle_of(args))
      let code = match args {
        { "code": Number(code, ..), .. } => code
        _ => 0.0
      }
      // (here at once: nothing more read, nothing more sent)
      for flow in stream.flows {
        flow.reset = true
      }
      let mine = stream.flows[1 - role]
      if mine.reader is Some(reader) {
        mine.reader = None
        self.refuse(side, reader, "stream reset")
      }
      let other = 1 - role
      let conn = stream.conn
      if !conn.way.down {
        self.later(conn.way.ms.to_int64(), () => {
          let theirs = stream.flows[role]
          if theirs.reader is Some(reader) {
            theirs.reader = None
            self.refuse(conn.ends[other].side, reader, "stream reset by peer")
          }
          if stream.flows[other].stopper is Some(stopper) {
            stream.flows[other].stopper = None
            self.answer(conn.ends[other].side, stopper, { "code": Json::number(code) })
          }
        })
      }
      self.answer(side, id, {})
    }
    ("istream.stopped", Some(Stream(stream, role))) => {
      let flow = stream.flows[role]
      if flow.read_end {
        self.answer(side, id, { "code": Json::null() })
      } else if flow.reset {
        self.answer(side, id, { "code": 0 })
      } else {
        flow.stopper = Some(id)
      }
    }
    ("istream.tap", Some(Stream(_, _))) =>
      match self.taps {
        None => self.refuse(side, id, "no such op")
        Some(taps) => {
          let call = match args {
            { "call": Number(n, ..), .. } => n.to_int64()
            _ => -1L
          }
          self.tapped.push("\{handle_of(args)} \{call} \{bytes.unwrap_or(b"").length()}")
          self.answer(side, id, { "tapped": Json::boolean(taps) })
        }
      }
    _ => self.refuse(side, id, "no handle for \{op}")
  }
}

///|
fn SimFlow::new() -> SimFlow {
  { came: [], reader: None, reset: false, read_end: false, stopper: None }
}

///|
/// A connection dialled to `end` comes: to its wait for one, else kept for the next.
fn SimNet::arrive(self : SimNet, end : SimEnd, conn : SimConn) -> Unit {
  if end.accepts.length() > 0 {
    let id = end.accepts.remove(0)
    conn.handles[1] = self.give(end.side, Conn(conn, 1))
    self.answer(end.side, id, { "id": id_json(conn.handles[1]), "alpn": Json::string(conn.alpn) })
  } else {
    end.coming.push(conn)
  }
}

///|
fn SimNet::ask(self : SimNet, side : Int, op : String, args : Json) -> Json raise @shell.ShellError {
  let h = self.handle(side, args)
  match (op, h) {
    ("iroh.endpointId", Some(End(end))) => Json::string(end.id)
    ("iroh.relayStatus", Some(End(end))) =>
      Json::array(
        end.relays.map(relay => {
          "url": Json::string(relay),
          "connected": Json::boolean(self.ways.get(relay) is Some(way) && !way.down),
        }),
      )
    ("iroh.addAddr", Some(End(_))) => {
      self.said[side].push("iroh.addAddr \{handle_of(args)} \{json_at(args, ["addr"]).unwrap_or(Json::null()).stringify()}")
      Json::null()
    }
    ("conn.paths", Some(Conn(conn, _))) => {
      let way = conn.way
      [
        {
          "id": "0",
          "selected": true,
          "relay": if way.relay { Json::string(way.name) } else { Json::null() },
          "ip": if way.relay { Json::null() } else { Json::string(way.name) },
          "rttMs": Json::number((2 * way.ms).to_double()),
        },
      ]
    }
    ("conn.stats", Some(Conn(conn, role))) =>
      { "rxBytes": Json::number(conn.rx[role]), "txBytes": Json::number(conn.tx[role]) }
    ("conn.remoteId", Some(Conn(conn, role))) => Json::string(conn.ends[1 - role].id)
    ("conn.closeReason", Some(Conn(conn, role))) => conn.ended[role].unwrap_or(Json::null())
    ("fetch.cancel", _) => {
      let call = handle_of(args).to_int64()
      for dial in self.dials {
        if dial.0 == side && dial.1 == call {
          self.dials.retain(one => !(one.0 == side && one.1 == call))
          self.refuse(side, call, "cancelled")
          return Json::boolean(true)
        }
      }
      Json::boolean(false)
    }
    _ => raise @shell.ShellError("no handle for \{op}")
  }
}

///|
/// `f` as a fiber of the test's runtime, run as far as it goes by itself.
fn[X] SimNet::go(self : SimNet, f : async () -> X) -> @effect.Fiber[X] {
  let fiber = self.rt.fork(f)
  ignore(self.rt.run_ready())
  fiber
}

///|
/// Time goes on `ms`: what is due meanwhile happens at its own time.
fn SimNet::pass(self : SimNet, ms : Int) -> Unit {
  self.rt.advance(ms)
}

///|
/// What a fiber gave, the test's mistake where it has not.
fn[X] given(fiber : @effect.Fiber[X]) -> X raise {
  match fiber.poll() {
    Some(Succeeded(x)) => x
    Some(Failed(e)) => fail("failed: \{said(e)}")
    Some(Interrupted) => fail("interrupted")
    None => fail("still waiting")
  }
}

// ── the peer's program ──

///|
/// The server's program: what it lets in, says of where it is, serves, and what it saw.
priv struct Door {
  net : SimNet
  /// What a hello is answered: None lets it in; Some(answer) refuses with that answer (an object with `error`).
  mut judge : (Json) -> Json?
  mut lan : Array[String]
  mut tailnet : Array[String]
  /// Each hello: `<credential> <its other fields as written>`; each control line after; each request
  /// `<method> <path> <body length>`; each connection's end, as it saw it: `<kind> <reason>`.
  hellos : Array[String]
  lines : Array[String]
  asked : Array[String]
  ends : Array[String]
  /// The connections it let in, and what each request is answered: its status and body, by path.
  conns : Array[Incoming]
  replies : Map[String, (Int, Bytes)]
  /// The connections dialled to it on another protocol than the mesh's: its program's own, taken as they came.
  others : Array[Incoming]
}

///|
fn Door::new(net : SimNet) -> Door {
  {
    net,
    judge: _ => None,
    lan: [],
    tailnet: [],
    hellos: [],
    lines: [],
    asked: [],
    ends: [],
    conns: [],
    replies: Map([]),
    others: [],
  }
}

///|
/// What came on `inbound`, line by line: each line handed to `f` as it comes, until the stream ends.
async fn each_line(inbound : Inbound, carry : @wire.Carry, f : async (String) -> Unit) -> Unit {
  while true {
    while carry.line() is Some(line) {
      f(line)
    }
    guard inbound.take() is Some(chunk) else { return }
    carry.push(chunk)
  }
}

///|
async fn write_line(out : Out, json : Json) -> Unit {
  out.write(@utf8.encode(json.stringify() + "\n"))
}

///|
/// The door serves: each connection dialled to it let in or refused by its hello, its control lines answered, its
/// streams served.
fn Door::open(self : Door, mesh : Mesh) -> Unit {
  ignore(
    self.net.rt.fork(() => {
      while true {
        let next = attempt(() => mesh.incoming())
        guard next is Did(Some(incoming)) else { return }
        ignore(self.net.rt.fork(() => self.take(incoming)))
      }
    }),
  )
}

///|
async fn Door::take(self : Door, incoming : Incoming) -> Unit {
  if incoming.alpn != sim_alpn {
    self.others.push(incoming)
    return
  }
  let first = attempt(() => incoming.first())
  guard first is Did((line, control)) else { return }
  self.conns.push(incoming)
  ignore(
    self.net.rt.fork(() => {
      let closed = incoming.closed()
      self.ends.push("\{closed.kind} \{closed.reason}")
    }),
  )
  let hello : Json = @json.parse(line) catch { _ => Json::null() }
  let credential = match hello {
    { "credential": String(c), .. } => c
    _ => ""
  }
  let others = match hello {
    Object(fields) => {
      let rest = Map::from_array(fields.to_array().filter(kv => kv.0 != "credential"))
      Json::object(rest).stringify()
    }
    _ => ""
  }
  self.hellos.push("\{credential} \{others}")
  match (self.judge)(hello) {
    Some(refusal) => {
      ignore(attempt(() => write_line(control.out, refusal)))
      return
    }
    None =>
      ignore(
        attempt(() => write_line(control.out, {
          "ok": true,
          "lan": Json::array(self.lan.map(s => Json::string(s))),
          "tailnet": Json::array(self.tailnet.map(s => Json::string(s))),
        })),
      )
  }
  // Its control lines after: each a ping or a renewal, answered.
  ignore(
    self.net.rt.fork(() => ignore(attempt(() => each_line(control, @wire.Carry::new(), line => {
      self.lines.push(line)
      write_line(control.out, { "ok": true })
    })))),
  )
  // Its streams: each a request, or a duplex; taken by two askers side by side, as a door's workers take them.
  let taking = () => {
    while true {
      guard attempt(() => incoming.accept()) is Did(Some(inbound)) else { return }
      ignore(self.net.rt.fork(() => ignore(attempt(() => self.serve(inbound)))))
    }
  }
  ignore(self.net.rt.fork(taking))
  taking()
}

///|
/// One stream: a request's head, its body to its end, and its reply, in pieces of `body_step`; or, a duplex
/// (`"duplex": true` in its head), its reply's head at once and what comes sent back, until it ends.
async fn Door::serve(self : Door, inbound : Inbound) -> Unit {
  let carry = @wire.Carry::new()
  let mut head : String? = None
  while head is None {
    head = carry.line()
    if head is Some(_) {
      break
    }
    guard inbound.take() is Some(chunk) else { return }
    carry.push(chunk)
  }
  let head : Json = @json.parse(head.unwrap()) catch { _ => Json::null() }
  let (method_, path) = match head {
    { "method": String(m), "path": String(p), .. } => (m, p)
    _ => ("", "")
  }
  if head is { "duplex": True, .. } {
    self.asked.push("\{method_} \{path} duplex")
    write_line(inbound.out, { "status": 200, "headers": {} })
    let rest = carry.take()
    if rest.length() > 0 {
      inbound.out.write(rest)
    }
    while inbound.take() is Some(chunk) {
      inbound.out.write(chunk)
    }
    inbound.out.finish()
    return
  }
  let mut length = carry.take().length()
  while inbound.take() is Some(chunk) {
    length += chunk.length()
  }
  self.asked.push("\{method_} \{path} \{length}")
  let (status, body) = self.replies.get(path).unwrap_or((200, b"ok"))
  // (its head and the first of its body in one write, as a door's buffered writer sends them: what the reader takes
  // past its head comes with it)
  let head = @utf8.encode(({ "status": status, "headers": {} } : Json).stringify() + "\n")
  let first = if body.length() < body_step { body.length() } else { body_step }
  let joined = Array::from_fixed_array(head.to_fixedarray())
  joined.append(Array::from_fixed_array(body[0:first].to_owned().to_fixedarray()))
  inbound.out.write(Bytes::from_array(joined))
  for at = first; at < body.length(); at = at + body_step {
    let end = if at + body_step < body.length() { at + body_step } else { body.length() }
    inbound.out.write(body[at:end].to_owned())
  }
  inbound.out.finish()
}

///|
/// The peer opens a stream on its connection `conn` (one it let in) and sends `bytes` on it, finished.
async fn push(conn : Incoming, bytes : Bytes) -> Unit {
  let opened = conn.open()
  opened.out.write(bytes)
  opened.out.finish()
}

// ── the two meshes ──

///|
/// A store in memory: what each mesh keeps.
fn kept_in(values : Map[String, Bytes]) -> Store {
  { get: key => values.get(key), set: (key, value) => values[key] = value }
}

///|
/// Spans as told: `<name> <attribute>=<value> …` as each ends, the mesh's own attributes in the order said.
fn spans_in(told : Array[String]) -> Trace {
  {
    peer_key: "peer",
    start: (name, _) => {
      let attrs : Array[String] = []
      let ended = Ref(false)
      {
        traceparent: Some("00-" + "1".repeat(32) + "-" + "2".repeat(16) + "-01"),
        set: (_, _) => (),
        own: (key, value) => {
          let v = match value {
            Str(s) => s
            Int(n) => n.to_string()
            Num(n) => n.to_string()
            Flag(b) => b.to_string()
          }
          attrs.push("\{key}=\{v}")
        },
        fail: () => attrs.push("failed"),
        end: () => {
          if !ended.val {
            ended.val = true
            told.push(([name, ..attrs] : Array[String]).join(" "))
          }
        },
      }
    },
  }
}

///|
/// A world of two meshes on the network: its ways as the test made them before (`ways`), the server's mesh bound
/// on both relays taking the protocol, its door open, and the client's mesh dialling through both relays.
priv struct World {
  net : SimNet
  door : Door
  server : Mesh
  client : Mesh
  /// What the client keeps, the spans it told and the lines of its record.
  kept : Map[String, Bytes]
  spans : Array[String]
  record : Array[String]
  /// Each credential the client's source gave: `<scope> <fresh> <id's first 8>`.
  given : Array[String]
}

///|
fn World::new(
  ways : (SimNet) -> Unit,
  relay_only? : Bool = false,
  refusal? : (Json, String) -> Error?,
  takes? : Array[String] = [sim_alpn],
) -> World raise {
  let net = SimNet::new()
  ways(net)
  let door = Door::new(net)
  let server_kept : Map[String, Bytes] = { "device": Bytes::make(32, b'\x02') }
  let server = given(
    net.go(() => Mesh::make(
      net.shells[1],
      kept_in(server_kept),
      { alpn: sim_alpn, relays: [sim_r1, sim_r2], relay_only: false, says: None, refusal: None },
      binding={ lookup: false, takes, entries: [] },
    )),
  )
  door.open(server)
  let kept : Map[String, Bytes] = { "device": Bytes::make(32, b'\x01') }
  let spans = []
  let record = []
  let client = given(
    net.go(() => Mesh::make(
      net.shells[0],
      kept_in(kept),
      { alpn: sim_alpn, relays: [sim_r1, sim_r2], relay_only, says: Some({ "app": "sim" }), refusal },
      trace=spans_in(spans),
      recorder={ on: () => true, line: line => record.push(line) },
    )),
  )
  ignore(net.rt.run_ready())
  { net, door, server, client, kept, spans, record, given: [] }
}

///|
/// The credentials of the client's links in `scope`: `cred-<scope>-<n>` for this device's id, a new one each
/// asking.
fn World::source(self : World, scope? : String = "") -> async (String, Bool) -> Presented {
  (id, fresh) => {
    self.given.push("\{scope} \{fresh} \{id.exact_view(end=8)}")
    { credential: "cred-\{scope}-\{self.given.length()}-\{id.exact_view(end=8)}", also: Some({ "who": "sim" }) }
  }
}

///|
/// Both meshes closed: what either shell still holds after (none, where nothing was left behind).
fn World::close_all(self : World) -> (Int, Int) raise {
  let closed = self.net.go(() => {
    self.client.close()
    self.server.close()
  })
  self.net.pass(1_000)
  given(closed)
  (self.net.handles[0].length(), self.net.handles[1].length())
}

///|
/// The client's link to the server in `scope`, opened as far as it goes by itself.
fn World::link(self : World, scope? : String = "") -> @effect.Fiber[Link] {
  let peer = self.server.device_id()
  self.net.go(() => self.client.link(peer, self.source(scope~), scope~))
}

///|
/// What the client's link to the server in `scope` goes through now: the relay's key, the address, or none.
fn World::via(self : World, scope? : String = "") -> String {
  match self.client.current(self.server.device_id(), scope~) {
    Some(link) =>
      match link.paths() {
        [{ "relay": String(relay), .. }, ..] => relay
        [{ "ip": String(ip), .. }, ..] => ip
        _ => "none"
      }
    None => "none"
  }
}

///|
/// Spans told so far of `name`.
fn World::spans_of(self : World, name : String) -> Array[String] {
  self.spans.filter(span => span.has_prefix(name + " ") || span == name)
}

///|
/// Lines recorded so far that start with `what`.
fn World::records_of(self : World, what : String) -> Array[String] {
  self.record.filter(line => line.has_prefix(what))
}

///|
/// What is at `path` in `json`, key after key.
fn json_at(json : Json, path : Array[String]) -> Json? {
  let mut at = json
  for key in path {
    guard at is Object(fields) && fields.get(key) is Some(next) else { return None }
    at = next
  }
  Some(at)
}

// ── what happens between them ──

///|
test "sim: requests, a body told of as it goes, a duplex, a reply handed to the shell, a stream the peer opens, and scopes apart" {
  let world = World::new(
    net => {
      ignore(net.relay(sim_r1, ms=10))
      ignore(net.relay(sim_r2, ms=30))
    },
    refusal=(answer, reason) => if answer is { "code": "busy", .. } {
      Some(MeshError(code="busy", message=reason, cause=""))
    } else {
      None
    },
  )
  let net = world.net
  let door = world.door
  let a = world.link(scope="a")
  let b = world.link(scope="b")
  net.pass(1_000)
  let a = given(a)
  let b = given(b)
  // Each scope its own link, its own connection, let in by its own credential; both through the endpoint's first
  // relay, the quickest that both are on.
  assert_false(physical_equal(a, b))
  assert_eq(door.conns.length(), 2)
  assert_eq(door.hellos.map(h => h.split(" ").next().unwrap().to_owned()), ["cred-a-1-72cd6e84", "cred-b-2-72cd6e84"])
  assert_eq(world.via(scope="a"), "https://r1.sim/")
  assert_eq(given(net.go(() => a.admitted())), { "ok": true, "lan": [], "tailnet": [] })
  // A body told of as it goes: a step at a time, each said as the stream took it.
  let steps : Array[Int] = []
  let upload = net.go(() => a.request("POST", "/upload", body=Bytes::make(200 * 1024, b'u'), wrote=n => steps.push(n)).rest())
  net.pass(1_000)
  assert_eq(@utf8.decode(given(upload)), "ok")
  assert_eq(steps, [65536, 131072, 196608, 204800])
  assert_eq(door.asked, ["POST /upload 204800"])
  // A duplex: what goes comes back as it goes, until it is finished.
  let echoed : Array[String] = []
  let duplex = net.go(() => {
    let (reply, out) = a.duplex("POST", "/echo", more={ "duplex": true })
    out.write(b"one")
    echoed.push(@utf8.decode(reply.take().unwrap()))
    out.write(b"two")
    echoed.push(@utf8.decode(reply.take().unwrap()))
    out.finish()
    reply.take() is None
  })
  net.pass(1_000)
  assert_true(given(duplex))
  assert_eq(echoed, ["one", "two"])
  // A reply handed to the shell to read: what came with its head (the first piece of its body, written with it)
  // goes with it, and what follows is read as ever by the program, whose reads the shell let be.
  net.taps = Some(true)
  door.replies["/screen"] = (200, Bytes::make(100_000, b's'))
  let tapped = net.go(() => {
    let reply = a.request("GET", "/screen")
    (reply.tap(7L), reply.rest().length())
  })
  net.pass(1_000)
  let (taken, rest) = given(tapped)
  assert_true(taken)
  assert_eq(net.tapped.length(), 1)
  assert_true(net.tapped[0].has_suffix(" 7 \{body_step}"))
  assert_eq(body_step + rest, 100_000)
  // A stream the peer opens, on scope a's connection alone.
  let pushed = net.go(() => {
    let inbound = a.accept().unwrap()
    let got = inbound.take().unwrap()
    (@utf8.decode(got), inbound.take() is None)
  })
  ignore(net.go(() => push(door.conns[0], b"news")))
  net.pass(1_000)
  assert_eq(given(pushed), ("news", true))
  // Scope a let go of: its connection closed with the reason given, b's left as it was and still answering.
  world.client.drop_link(world.server.device_id(), scope="a", reason="done with a")
  net.pass(1_000)
  assert_eq(door.ends, ["application done with a"])
  assert_true(b.usable())
  let on_b = net.go(() => b.request("GET", "/b").rest())
  net.pass(1_000)
  assert_eq(@utf8.decode(given(on_b)), "ok")
  // A refusal its program names (`Options.refusal`): the credential was fine, and the next is asked as not new.
  door.judge = hello => if hello is { "credential": String(c), .. } && c.has_prefix("cred-a-") {
    Some({ "error": "too many", "code": "busy" })
  } else {
    None
  }
  let busy = world.link(scope="a")
  net.pass(1_000)
  let refused = net.go(() => given(busy).admitted())
  net.pass(1_000)
  assert_eq(ended_as(refused), "busy: too many")
  let again = world.link(scope="a")
  net.pass(1_000)
  ignore(given(again))
  // The credential refused: the next is asked as new.
  door.judge = hello => if hello is { "credential": String(c), .. } && c.has_prefix("cred-a-") {
    Some({ "error": "expired" })
  } else {
    None
  }
  let expired = world.link(scope="a")
  net.pass(1_000)
  let refused = net.go(() => given(expired).admitted())
  net.pass(1_000)
  assert_true(ended_as(refused).has_prefix("credential_refused: "))
  let fresh = world.link(scope="a")
  net.pass(1_000)
  ignore(given(fresh))
  assert_eq(world.given.filter(g => g.has_prefix("a ")), [
    "a false 72cd6e84", "a false 72cd6e84", "a false 72cd6e84", "a false 72cd6e84", "a true 72cd6e84",
  ])
  // Scope b went on through it all: one connection, let in once.
  assert_true(b.usable())
  assert_true(physical_equal(world.client.current(world.server.device_id(), scope="b").unwrap(), b))
  // Held now at each shell: the endpoint, scope b's connection, its control stream; every request's stream and
  // every connection that ended let go of already. Both closed, nothing is left behind at either.
  assert_eq((net.handles[0].length(), net.handles[1].length()), (3, 3))
  assert_eq(world.close_all(), (0, 0))
}

///|
test "sim: one connection a peer dialled carries many streams at once both ways: requests side by side taken by the door's askers side by side, streams the door opens taken by the device's, an asker given up losing none, and nothing left behind" {
  let world = World::new(net => ignore(net.relay(sim_r1, ms=10)))
  let net = world.net
  let door = world.door
  let a = world.link()
  net.pass(1_000)
  let a = given(a)
  // Six requests at once, each its own stream on the one connection: each answered its own.
  for i in 0..<6 {
    door.replies["/n\{i}"] = (200, @utf8.encode("r\{i}"))
  }
  let asked = Array::makei(6, i => net.go(() => @utf8.decode(a.request("GET", "/n\{i}").rest())))
  net.pass(1_000)
  assert_eq(asked.map(f => given(f)), ["r0", "r1", "r2", "r3", "r4", "r5"])
  let served = door.asked.copy()
  served.sort()
  assert_eq(served, ["GET /n0 0", "GET /n1 0", "GET /n2 0", "GET /n3 0", "GET /n4 0", "GET /n5 0"])
  // An asker of the door's that gives up while it waits loses none: the next request is still served.
  let gave_up = net.go(() => door.conns[0].accept())
  gave_up.interrupt()
  net.pass(10)
  let after = net.go(() => @utf8.decode(a.request("GET", "/n0").rest()))
  net.pass(1_000)
  assert_eq((ended_as(gave_up), given(after)), ("interrupted", "r0"))
  // Three streams the door opens at once, each written and finished, and answered back read to its end: taken by
  // three askers of the device's side by side, each its own.
  let taken = Array::makei(3, _ => net.go(() => {
    let inbound = a.accept().unwrap()
    let carry = @wire.Carry::new()
    while inbound.take() is Some(chunk) {
      carry.push(chunk)
    }
    let got = @utf8.decode(carry.take())
    inbound.out.write(@utf8.encode("got " + got))
    inbound.out.finish()
    got
  }))
  let pushed = Array::makei(3, i => net.go(() => {
    let opened = door.conns[0].open()
    opened.out.write(@utf8.encode("p\{i}"))
    opened.out.finish()
    let carry = @wire.Carry::new()
    while opened.take() is Some(chunk) {
      carry.push(chunk)
    }
    @utf8.decode(carry.take())
  }))
  net.pass(1_000)
  let got = taken.map(f => given(f))
  got.sort()
  assert_eq(got, ["p0", "p1", "p2"])
  assert_eq(pushed.map(f => given(f)), ["got p0", "got p1", "got p2"])
  // Every stream let go of at both shells: the endpoint, the connection and its control stream held at each.
  assert_eq((net.handles[0].length(), net.handles[1].length()), (3, 3))
  assert_eq(world.close_all(), (0, 0))
}

///|
test "sim: the quicker relay found slow by a reply timed on it, and requests moved at once to the one that brings more" {
  let world = World::new(net => {
    // r1: the quicker round trip, a slow line; r2: twice as far, a hundred times the speed
    ignore(net.relay(sim_r1, ms=10, bps=50_000.0))
    ignore(net.relay(sim_r2, ms=22, bps=5_000_000.0))
  })
  let net = world.net
  let peer = world.server.device_id()
  let opening = world.link()
  net.pass(1_000)
  let link = given(opening)
  assert_eq(world.via(), "https://r1.sim/")
  // Measured as a person asks: r2 dialled on its own endpoint and every way pinged; r1 stays, the quicker.
  let measured = net.go(() => world.client.remeasure_peer(peer))
  net.pass(30_000)
  ignore(given(measured))
  let ways = world.client.measured(peer)
  assert_eq(ways.map(w => (w.way, w.kind, w.active)), [
    ("https://r1.sim/", "main", true),
    ("https://r2.sim/", "relay", false),
  ])
  assert_eq(world.via(), "https://r1.sim/")
  assert_eq(world.client.moves(peer), 0)
  // A reply timed on r1, long enough to tell its speed: it comes at r1's speed, and requests move to r2 at once.
  world.door.replies["/big"] = (200, Bytes::make(640 * 1024, b'b'))
  let big = net.go(() => world.client.timed(peer, sim_r1, link.request("GET", "/big")).rest().length())
  net.pass(20_000)
  assert_eq(given(big), 640 * 1024)
  let speed = world.client.speed(peer, sim_r1).unwrap()
  assert_true(speed > 45_000.0 && speed < 55_000.0)
  assert_eq(world.via(), "https://r2.sim/")
  assert_eq(world.client.moves(peer), 1)
  assert_eq(world.client.moved(peer), Some("r2.sim"))
  let route = world.spans_of("mesh.route")
  assert_eq(route.length(), 1)
  // (r1 costs its round trip and what a typical reply takes at its speed; r2 its round trip alone, its speed unknown)
  assert_eq(route, [
    "mesh.route peer=\{peer} why=slow from=https://r1.sim/ from.score=7123 from.missed=0 from.paths=*r1.sim 20ms 0/0 to=https://r2.sim/ to.score=44 to.paths=*r2.sim 44ms 0/0",
  ])
  assert_true(world.spans_of("mesh.speed").length() >= 1)
  // The speed kept under its key; the day's bytes counted, and kept as the tally comes.
  let kept : Json = @json.parse(@utf8.decode(world.kept[speed_key]))
  assert_eq(json_at(kept, [peer, "https://r1.sim/", "bps"]), Some(Json::number(speed)))
  net.pass(tally_every_ms)
  let (rx, tx) = world.client.today(peer)
  // (what r1 brought until requests left it, counted as they did, and what r2 carried: the rest of the reply came on
  // r1, a way beside now, counted once that is let go of)
  assert_true(rx >= speed_min_bytes.to_int64() && rx < (640 * 1024).to_int64())
  assert_true(tx > 0L)
  let days : Json = @json.parse(@utf8.decode(world.kept[net_day_key]))
  guard json_at(days, [peer, "rx"]) is Some(Number(kept_rx, ..)) else { fail("not kept: \{days.stringify()}") }
  // (as the last tally counted it: what came since, pings, is counted by `today` as it is asked)
  assert_true(kept_rx >= speed_min_bytes.to_double() && kept_rx <= rx.to_double())
}

///|
/// The client's ways to the server as measured: `<way>/<kind>` each, `*` on the one requests go on, `!` on one not
/// answering; not the relays it has no way open on (`Mesh::measured` lists those too, healthy for none).
fn World::ways(self : World, scope? : String = "") -> String {
  self.client
  .measured(self.server.device_id(), scope~)
  .filter(w => !(w.kind == "relay" && w.samples == 0 && !w.healthy))
  .map(w => (if w.active { "*" } else { "" }) + w.way + "/" + w.kind + (if w.healthy { "" } else { "!" }))
  .join(" ")
}

///|
test "sim: where the peer is straight, its LAN first, ways direct held off for flapping, the endpoint kept off while the LAN answers, and its tailnet with every relay down" {
  let lan_at = "192.168.1.2:4000"
  let tail_at = "100.64.0.2:4000"
  let lan_way : Ref[SimWay?] = Ref(None)
  let world = World::new(net => {
    ignore(net.relay(sim_r1, ms=20))
    ignore(net.relay(sim_r2, ms=30))
  })
  let net = world.net
  let peer = world.server.device_id()
  lan_way.val = Some(net.direct(lan_at, peer, ms=1))
  let tail_way = net.direct(tail_at, peer, ms=5)
  world.door.lan = [lan_at]
  world.door.tailnet = [tail_at]
  let opening = world.link()
  net.pass(1_000)
  ignore(given(opening))
  // Its hello's answer says where it is straight: kept, by place, and told the endpoint.
  assert_eq(world.client.lan(peer), [lan_at])
  assert_eq(world.client.tailnet(peer), [tail_at])
  assert_eq(json_at(@json.parse(@utf8.decode(world.kept[addresses_key])), [peer]), Some({ "lan": [lan_at], "tailnet": [tail_at] }))
  let log : Array[String] = []
  let note = (what : String) => log.push("\{what}: \{world.ways()} via \{world.via()}")
  note("start")
  // Its program turns the endpoint's punched ways off: every way is raced, and its LAN comes first.
  world.client.set_ways(peer, off=["direct"])
  net.pass(1_000)
  note("direct off")
  net.pass(30_000)
  note("30s")
  // The LAN goes down: requests go on its tailnet, then quickest.
  lan_way.val.unwrap().down = true
  net.pass(20_000)
  note("lan down")
  lan_way.val.unwrap().down = false
  net.pass(40_000)
  note("lan up")
  lan_way.val.unwrap().down = true
  net.pass(20_000)
  note("lan down again")
  lan_way.val.unwrap().down = false
  net.pass(40_000)
  note("lan up again")
  net.pass(120_000)
  note("held over")
  // Lost soon after requests moved to it, twice in a row: ways direct held off `direct_hold_ms`, the LAN avoided
  // while up meanwhile, and gone back to once the hold is over.
  let routes = world.spans_of("mesh.route").map(s => s.split(" from.score").next().unwrap().to_owned())
  assert_eq(routes, [
    "mesh.route peer=\{peer} why=lost from=lan", "mesh.route peer=\{peer} why=lan from=tailnet", "mesh.route peer=\{peer} why=lost from=lan",
    "mesh.route peer=\{peer} why=lan from=tailnet",
  ])
  let spans = world.spans_of("mesh.route")
  assert_false(spans[0].contains("direct_held_ms"))
  assert_true(spans[2].has_suffix(" direct_held_ms=\{direct_hold_ms}"))
  // The endpoint's ways on again: while the LAN answers, requests keep off the endpoint, which is not dialled.
  world.client.set_ways(peer, off=[])
  net.pass(explore_ms + redial_main_ms)
  note("direct on")
  // The LAN and every relay down: its tailnet alone reaches it.
  lan_way.val.unwrap().down = true
  net.ways[relay_key(sim_r1)].down = true
  net.ways[relay_key(sim_r2)].down = true
  net.pass(20_000)
  note("tailnet alone")
  // Once the LAN has not answered for `lan_recall_ms`, the endpoint is dialled again: at the addresses said, its
  // tailnet's the one up.
  net.pass(lan_recall_ms + 2 * redial_main_ms)
  note("lan forgotten")
  let asked = net.go(() => world.client.current(peer).unwrap().request("GET", "/far").rest())
  net.pass(1_000)
  assert_eq(@utf8.decode(given(asked)), "ok")
  // The endpoint was dialled twice in all: first, and once the LAN was forgotten, at its tailnet.
  let dials = world.records_of("conn dial").map(l => l.split(" onto=").next().unwrap().to_owned() + " -> " + l.split(" -> ").last().unwrap().to_owned())
  assert_eq(dials.filter(d => d.contains("via=main")), ["conn dial: #1 75877bb4 via=main -> ok", "conn dial: #14 75877bb4 via=main+addresses -> ok"])
  assert_eq(log, [
    "start: *https://r1.sim//main via https://r1.sim/",
    "direct off: *lan/lan tailnet/tailnet https://r1.sim//relay https://r2.sim//relay via 192.168.1.2:4000",
    "30s: *lan/lan tailnet/tailnet via 192.168.1.2:4000",
    "lan down: *tailnet/tailnet via 100.64.0.2:4000",
    "lan up: *lan/lan tailnet/tailnet via 192.168.1.2:4000",
    "lan down again: *tailnet/tailnet via 100.64.0.2:4000",
    "lan up again: lan/lan *tailnet/tailnet via 100.64.0.2:4000",
    "held over: *lan/lan tailnet/tailnet via 192.168.1.2:4000",
    "direct on: *lan/lan tailnet/tailnet via 192.168.1.2:4000",
    "tailnet alone: *tailnet/tailnet lan/lan! via 100.64.0.2:4000",
    "lan forgotten: *tailnet/tailnet direct/main via 100.64.0.2:4000",
  ])

  ignore(tail_way)
}

///|
test "sim: a link gone silent raced at its first missed ping and moved off cleanly, and a slow read asked on the other way and counted" {
  // A relay goes silent under the link: nothing comes and its connection does not end.
  let world = World::new(net => {
    ignore(net.relay(sim_r1, ms=10))
    ignore(net.relay(sim_r2, ms=20))
  })
  let net = world.net
  let peer = world.server.device_id()
  let opening = world.link()
  net.pass(1_000)
  let old = given(opening)
  net.pass(3 * tick_ms)
  assert_eq(old.pings().missed, 0)
  let replaced = net.go(() => world.client.replaced(old))
  net.ways[relay_key(sim_r1)].down = true
  net.pass(tick_ms + ping_timeout_ms + 1_000)
  // Missed once, having answered quickly: raced at once, and the new link through the relay that is up won.
  assert_eq(ended_as(replaced), "ok")
  assert_eq(world.via(), "https://r2.sim/")
  let new = world.client.current(peer).unwrap()
  assert_false(physical_equal(new, old))
  let races = world.spans_of("mesh.race")
  assert_eq(races, ["mesh.race peer=\{peer} race=new"])
  let asked = net.go(() => new.request("GET", "/after").rest())
  net.pass(1_000)
  assert_eq(@utf8.decode(given(asked)), "ok")
  // The old one closed `retire_ms` after; the peer, its way silent, sees it end by the transport's idle time.
  assert_true(old.usable())
  net.pass(retire_ms)
  assert_false(old.usable())
  assert_eq(world.door.ends, [])
  net.pass(sim_idle_ms)
  assert_eq(world.door.ends, ["timeout "])
  // A read slow on its way, asked on the other as well after `hedge_after`: answered there first, and how long it
  // had waited counted as a ping of the slow one.
  let world = World::new(net => {
    ignore(net.relay(sim_r1, ms=10))
    ignore(net.relay(sim_r2, ms=20))
  })
  let net = world.net
  let peer = world.server.device_id()
  let opening = world.link()
  net.pass(1_000)
  let link = given(opening)
  let measured = net.go(() => world.client.remeasure_peer(peer))
  net.pass(30_000)
  ignore(given(measured))
  let standby = world.client.standby(link).unwrap()
  assert_eq(standby.via(), Some("https://r2.sim/"))
  assert_eq(world.ways(), "*https://r1.sim//main https://r2.sim//relay")
  let after = world.client.hedge_after(link)
  assert_eq(after, hedge_floor_ms)
  let before = link.pings()
  net.ways[relay_key(sim_r1)].ms = 2_000
  let slow = net.go(() => link.request("GET", "/read").rest())
  net.pass(after)
  assert_eq(ended_as(slow), "waiting")
  let asked_at = net.rt.now() - after.to_int64()
  let quick = net.go(() => standby.request("GET", "/read").rest())
  net.pass(100)
  assert_eq(@utf8.decode(given(quick)), "ok")
  let waited = (net.rt.now() - asked_at).to_int()
  world.client.outran(link, waited)
  let counted = link.pings()
  assert_eq(counted.samples, before.samples + 1)
  assert_true(counted.srtt > before.srtt)
  net.pass(5_000)
  assert_eq(@utf8.decode(given(slow)), "ok")
  assert_eq(world.door.asked, ["GET /read 0", "GET /read 0"])
}

///|
test "sim: every relay down, the dial unanswered and the endpoint taken for stuck, bound anew before the next, which reaches the peer once a relay is back" {
  let world = World::new(net => {
    net.relay(sim_r1, ms=10).down = true
    net.relay(sim_r2, ms=20).down = true
  })
  let net = world.net
  let peer = world.server.device_id()
  let first = world.link()
  net.pass(onto_max_ms + connect_timeout_ms + 1_000)
  assert_eq(ended_as(first), said(failed("no_answer")))
  assert_eq(net.said[0].filter(s => s.has_prefix("iroh.bind")).length(), 1)
  net.ways[relay_key(sim_r2)].down = false
  let second = world.link()
  net.pass(1_000)
  let link = given(second)
  assert_eq(world.via(), "https://r2.sim/")
  // Bound anew with the same key, the endpoint of before closed and let go of, before the dial was made.
  assert_eq(net.said[0].filter(s => s.has_prefix("iroh.bind") || s.has_prefix("iroh.close")), [
    "iroh.bind 0", "iroh.bind 0", "iroh.close 1",
  ])
  assert_eq(net.keys[0][0], net.keys[0][1])
  assert_eq(world.records_of("conn rebind"), ["conn rebind: a dial unanswered, nothing open -> bound"])
  let connects = world.spans_of("mesh.connect")
  assert_eq(connects.length(), 2)
  assert_false(connects[0].contains("rebound=true"))
  assert_true(connects[1].contains(" rebound=true"))
  let asked = net.go(() => link.request("GET", "/back").rest())
  net.pass(1_000)
  assert_eq(@utf8.decode(given(asked)), "ok")
  assert_eq(world.door.hellos.length(), 1)
  assert_eq(world.door.conns[0].peer, world.client.device_id())
  ignore(peer)
}

///|
test "sim: on another network, the speeds seen forgotten, the addresses tried again, and every open link raced" {
  let lan_at = "192.168.1.2:4000"
  let world = World::new(net => {
    ignore(net.relay(sim_r1, ms=10))
    ignore(net.relay(sim_r2, ms=20))
  })
  let net = world.net
  let peer = world.server.device_id()
  ignore(net.direct(lan_at, peer, ms=1))
  world.door.lan = [lan_at]
  let a = world.link(scope="a")
  let b = world.link(scope="b")
  net.pass(1_000)
  ignore(given(a))
  let b = given(b)
  // On the LAN for scope a, its address tried; a speed seen through r1.
  world.client.set_ways(peer, scope="a", off=["direct"])
  net.pass(10_000)
  let a = world.client.current(peer, scope="a").unwrap()
  assert_eq(a.pin, Some("lan"))
  let place_a : Place = { scope: "a", peer }
  assert_eq(world.client.ways_at(place_a).tried.get("lan"), Some(lan_at))
  world.client.note_speed(peer, sim_r1, speed_min_bytes, 1_000)
  assert_true(world.client.speed(peer, sim_r1) is Some(_))
  net.pass(1_000)
  assert_true(world.kept[speed_key].length() > 2)
  let told = net.said[0].filter(s => s.has_prefix("iroh.networkChange")).length()
  world.client.wake(network=true)
  // At once: the speeds forgotten (and kept so), the addresses to be tried again, the shell told, and each link
  // that is its place's raced against a new one.
  assert_eq(world.client.speed(peer, sim_r1), None)
  assert_eq(world.client.ways_at(place_a).tried.length(), 0)
  assert_false(world.client.ways_at(place_a).tailnet_answered)
  assert_eq(world.client.racing.length(), 2)
  assert_eq(net.said[0].filter(s => s.has_prefix("iroh.networkChange")).length(), told + 1)
  assert_eq(world.records_of("conn network-change"), [
    "conn network-change: told the main endpoint (the network changed), 4 link(s) open, 3 relay endpoint(s) not told",
  ])
  net.pass(1_000)
  assert_eq(@utf8.decode(world.kept[speed_key]), "{}")
  // Scope a's link, on its LAN, answered its probe before a new one opened: kept, the new one let go of. Scope b's
  // new link, on the endpoint dialled at the address its peer said, went straight and opened before the old one's
  // probe through r1 came back: it takes the place.
  net.pass(probe_ms)
  assert_eq(world.spans_of("mesh.race"), ["mesh.race peer=\{peer} race=new", "mesh.race peer=\{peer} race=old"])
  assert_eq(world.client.racing.length(), 0)
  assert_true(physical_equal(world.client.current(peer, scope="a").unwrap(), a))
  let now_b = world.client.current(peer, scope="b").unwrap()
  assert_false(physical_equal(now_b, b))
  assert_eq((now_b.path(), json_at(now_b.paths()[0], ["ip"])), (Some("direct"), Some(Json::string(lan_at))))
}

///|
test "sim: the device key taken over with links open on two ways: all let go of, the peer told why, the day's bytes kept, and the next link let in as the new key" {
  let world = World::new(net => {
    ignore(net.relay(sim_r1, ms=10))
    ignore(net.relay(sim_r2, ms=20))
  })
  let net = world.net
  let peer = world.server.device_id()
  world.client.add_addr(peer, relays=[sim_r1])
  let opening = world.link()
  net.pass(1_000)
  let link = given(opening)
  let measured = net.go(() => world.client.remeasure_peer(peer))
  net.pass(30_000)
  ignore(given(measured))
  assert_eq(world.ways(), "*https://r1.sim//main https://r2.sim//relay")
  world.door.replies["/data"] = (200, Bytes::make(100_000, b'd'))
  let asked = net.go(() => link.request("GET", "/data").rest().length())
  net.pass(1_000)
  assert_eq(given(asked), 100_000)
  let (rx_before, _) = world.client.today(peer)
  assert_true(rx_before >= 100_000L)
  let old_id = world.client.device_id()
  let replaced = net.go(() => world.client.replaced(link))
  let key = Bytes::make(32, b'\x09')
  let migrated = net.go(() => world.client.migrate(key))
  net.pass(1_000)
  assert_eq(ended_as(migrated), "ok")
  assert_eq(ended_as(replaced), "ok")
  // The new key kept, the endpoint bound on it and told where the peer is, as its program said.
  assert_eq(world.kept["device"], key)
  let new_id = world.client.device_id()
  assert_true(new_id != old_id)
  assert_eq(new_id, sim_hex(sha256(key)))
  assert_eq(net.said[0].filter(s => s.has_prefix("iroh.addAddr")).length(), 2)
  // Every connection on the key of before let go of, the peer told why: the link's, the other way's.
  assert_eq(world.door.ends, ["application device key replaced", "application device key replaced"])
  assert_true(world.client.current(peer) is None)
  assert_false(link.usable())
  // What its links carried is still today's.
  let (rx_after, _) = world.client.today(peer)
  assert_true(rx_after >= rx_before)
  // The next link is dialled from the new key, and let in as it.
  let again = world.link()
  net.pass(1_000)
  let next = given(again)
  assert_eq(world.door.conns.last().unwrap().peer, new_id)
  assert_true(world.door.hellos.last().unwrap().has_prefix("cred--"))
  assert_true(world.door.hellos.last().unwrap().contains("-\{new_id.exact_view(end=8)} "))
  let asked = net.go(() => next.request("GET", "/as-new").rest())
  net.pass(1_000)
  assert_eq(@utf8.decode(given(asked)), "ok")
  assert_eq(world.door.asked, ["GET /data 0", "GET /as-new 0"])
  // Held now at each shell: the endpoint, the link's connection and its control stream; all of the key before let
  // go of. Both closed, nothing is left behind at either.
  assert_eq((net.handles[0].length(), net.handles[1].length()), (3, 3))
  assert_eq(world.close_all(), (0, 0))
}

///|
test "sim: a connection dialled once on a second protocol the peer takes, on an endpoint of its own beside the link, streams both ways, closed: the link never touched, and nothing left behind" {
  let world = World::new(net => ignore(net.relay(sim_r1, ms=10)), takes=[sim_alpn, "side/1"])
  let net = world.net
  let door = world.door
  let a = world.link()
  net.pass(1_000)
  let a = given(a)
  assert_eq(door.conns.length(), 1)
  // Dialled once on the other protocol: the peer takes it as its program's, from an endpoint whose id is not the
  // device's, drawn for it (the shell's draws here: 0x40 each), on the relay the link is on too.
  let dialling = net.go(() => world.client.dial_once(world.server.device_id(), "side/1"))
  net.pass(1_000)
  let out = given(dialling)
  assert_eq(door.others.length(), 1)
  let theirs = door.others[0]
  assert_eq(theirs.alpn, "side/1")
  assert_eq(theirs.peer, sim_hex(sha256(Bytes::make(32, b'\x40'))))
  assert_true(theirs.peer != world.client.device_id())
  assert_eq(net.keys[0].length(), 2)
  // A stream from here, answered; one from the peer, taken and answered back.
  let served = net.go(() => {
    let inbound = theirs.accept().unwrap()
    let carry = @wire.Carry::new()
    while inbound.take() is Some(chunk) {
      carry.push(chunk)
    }
    inbound.out.write(@utf8.encode("pong " + @utf8.decode(carry.take())))
    inbound.out.finish()
  })
  let asked = net.go(() => {
    let opened = out.open()
    opened.out.write(b"ping")
    opened.out.finish()
    let carry = @wire.Carry::new()
    while opened.take() is Some(chunk) {
      carry.push(chunk)
    }
    @utf8.decode(carry.take())
  })
  net.pass(1_000)
  given(served)
  assert_eq(given(asked), "pong ping")
  let taken = net.go(() => {
    let inbound = out.accept().unwrap()
    let got = inbound.take().unwrap()
    (@utf8.decode(got), inbound.take() is None)
  })
  ignore(net.go(() => push(theirs, b"news")))
  net.pass(1_000)
  assert_eq(given(taken), ("news", true))
  // The link went on beside it all the while: its one connection, answering.
  let on_a = net.go(() => a.request("GET", "/a").rest())
  net.pass(1_000)
  assert_eq(@utf8.decode(given(on_a)), "ok")
  // Closed here: the peer told why; its connection and endpoint let go of at this shell, the peer's connection at
  // its; the link still the one there, never ended, its peer never told an end.
  out.close(reason="done")
  net.pass(1_000)
  assert_eq(given(net.go(() => theirs.closed())).reason, "done")
  assert_true(a.usable())
  assert_true(physical_equal(world.client.current(world.server.device_id()).unwrap(), a))
  assert_eq((door.conns.length(), door.ends), (1, []))
  assert_eq((net.handles[0].length(), net.handles[1].length()), (3, 3))
  assert_eq(world.close_all(), (0, 0))
}

///|
test "sim: a connection dialled from the device's own endpoint on a second protocol the peer takes, beside the link and while it carries requests: the peer sees the device's id, streams both ways, closed: the link never touched, nothing bound anew, and nothing left behind" {
  let world = World::new(net => ignore(net.relay(sim_r1, ms=10)), takes=[sim_alpn, "second/1"])
  let net = world.net
  let door = world.door
  let a = world.link()
  net.pass(1_000)
  let a = given(a)
  assert_eq(door.conns.length(), 1)
  // Dialled on the device's endpoint while a request goes on the link: the peer takes it as its program's, from the
  // device's own id; no endpoint was bound for it.
  let on_a = net.go(() => a.request("GET", "/during").rest())
  let dialling = net.go(() => world.client.connect(world.server.device_id(), "second/1"))
  net.pass(1_000)
  let conn = given(dialling)
  assert_eq(@utf8.decode(given(on_a)), "ok")
  assert_eq((conn.peer, conn.alpn), (world.server.device_id(), "second/1"))
  assert_eq(door.others.length(), 1)
  let theirs = door.others[0]
  assert_eq((theirs.peer, theirs.alpn), (world.client.device_id(), "second/1"))
  assert_eq(net.keys[0].length(), 1)
  // A stream from here, answered; one from the peer, taken and answered back.
  let served = net.go(() => {
    let inbound = theirs.accept().unwrap()
    let carry = @wire.Carry::new()
    while inbound.take() is Some(chunk) {
      carry.push(chunk)
    }
    inbound.out.write(@utf8.encode("pong " + @utf8.decode(carry.take())))
    inbound.out.finish()
  })
  let asked = net.go(() => {
    let opened = conn.open()
    opened.out.write(b"ping")
    opened.out.finish()
    let carry = @wire.Carry::new()
    while opened.take() is Some(chunk) {
      carry.push(chunk)
    }
    @utf8.decode(carry.take())
  })
  net.pass(1_000)
  given(served)
  assert_eq(given(asked), "pong ping")
  let taken = net.go(() => {
    let inbound = conn.accept().unwrap()
    let got = inbound.take().unwrap()
    (@utf8.decode(got), inbound.take() is None)
  })
  ignore(net.go(() => push(theirs, b"news")))
  net.pass(1_000)
  assert_eq(given(taken), ("news", true))
  // The link went on beside it all the while: its one connection, answering.
  let after = net.go(() => a.request("GET", "/after").rest())
  net.pass(1_000)
  assert_eq(@utf8.decode(given(after)), "ok")
  // Closed here: the peer told why, the connection let go of at both shells; the link still the one there, never
  // ended, its peer never told an end, and the endpoint never bound anew.
  conn.close(reason="done")
  net.pass(1_000)
  assert_eq(given(net.go(() => theirs.closed())).reason, "done")
  assert_true(a.usable())
  assert_true(physical_equal(world.client.current(world.server.device_id()).unwrap(), a))
  assert_eq((door.conns.length(), door.ends, net.keys[0].length()), (1, [], 1))
  assert_eq(world.client.incomings.length(), 0)
  assert_eq((net.handles[0].length(), net.handles[1].length()), (3, 3))
  assert_eq(world.close_all(), (0, 0))
}
