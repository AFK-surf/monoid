// The workspace's stations calling each other (station/src/mesh/peer.ts): their own ALPN, and the peer's key for who
// it is. Who belongs is only what the roster said last (current while the control plane's socket holds): until a fresh
// roster comes, calls fail closed. One request a stream. On `stillfail/station/2`: a JSON head line `{workspace,
// request, bytes?}` and, with `bytes: true`, the request's bytes until the stream finishes; answered by a JSON head line
// `{result, bytes?}` or `{error}` and, with `bytes: true`, the answer's bytes. On `stillfail/station/1`: a JSON
// `{workspace, request}` the caller finishes, a JSON `{result}` or `{error}` back, and nothing else.

///|
pub let peer_alpn : String = "stillfail/station/1"

///|
pub let peer_bytes_alpn : String = "stillfail/station/2"

///|
/// A head at most (on `/1`: a whole request or answer).
pub let max_message : Int = 1024 * 1024

///|
/// How long bytes may not move on before their stream is given up.
pub let bytes_idle_ms : Int = 30000

///|
let stopped_code : Int = 1

///|
let failed_code : Int = 2

///|
/// A request answered later than this is said in the log.
let slow_ms : Int64 = 10000L

///|
/// What a rig tells the stations of its workspace besides a task's change.
pub let rig_tells : Array[String] = ["rig.hello", "rig.changed", "vault.used", "vault.done"]

///|
pub let unprotected_words : String = "that station is in this workspace but not protected by its safe mode (安全模式): it was offline or too old when safe mode was turned on. It is not a bug: stations safe mode protects run no remote tasks for an unprotected one, nor share with it, and it cannot be called from here. An owner or admin of the workspace protects it in the app's Settings → Security (设置 → 安全) with Protect (保护), updating it first if it is too old."

///|
/// What a station is answered while this machine waits for what a moved chain's state is made of (peer.ts
/// `heardWaiting`).
pub async fn heard_waiting(k : Keeper, verb : Json?) -> Bool {
  guard verb is Some(String(m)) else { return false }
  m.has_prefix("lock.") || ((k.is_rig)() && (m == "rig.added" || m == "rig.proof"))
}

///|
fn peers_of(m : Json) -> Array[String] {
  arr_of(field(m, "peers")).filter_map(p => str_of(field(p, "id")))
}

///|
/// The workspace a peer is asked or heard in, if it is another station of it now; raises why not (peer.ts `member`).
pub async fn peer_member(k : Keeper, peer : String, workspace : String?) -> String {
  if !(k.peers_current)() {
    raise Refused("workspace peer roster is not current; waiting for the control plane")
  }
  let of = match workspace {
    None => {
      let first = match (k.home)() { Some(h) => (k.member_of)(h); None => None }
      match first {
        Some(f) if peers_of(f).contains(peer) => Some(f)
        _ => {
          let all = (k.members_all)()
          match all.iter().find_first(m => peers_of(m).contains(peer)) {
            Some(m) => Some(m)
            None => all.get(0)
          }
        }
      }
    }
    Some(w) => (k.member_of)(w)
  }
  guard (k.has_state)() && of is Some(of) else { raise Refused("station is outside this workspace") }
  let me = (k.station)()
  if !peers_of(of).contains(peer) || peer == me {
    let where_ = match workspace { None => (k.members_all)(); Some(_) => [of] }
    if peer != me {
      for m in where_ {
        let w = str_of(field(m, "workspace")).unwrap_or("")
        if (k.unprotected)(w).iter().any(p => str_of(field(p, "id")) == Some(peer)) {
          raise Refused(unprotected_words)
        }
      }
    }
    raise Refused("peer is not another station in this workspace")
  }
  str_of(field(of, "workspace")).unwrap_or("")
}

///|
/// What `peers` answers (the transport's own roster) (peer.ts `roster`).
pub async fn roster(k : Keeper, workspace : String?) -> Json {
  let of = match workspace {
    None => (k.members_all)().get(0)
    Some(w) => (k.member_of)(w)
  }
  let ws = match of { Some(o) => str_of(field(o, "workspace")).unwrap_or(""); None => "" }
  let unprotected = match of { Some(_) => (k.unprotected)(ws); None => [] }
  let m : Map[String, Json] = {
    "workspace": Json::string(ws),
    "stations": match of { Some(o) => field(o, "peers").unwrap_or(Json::array([])); None => Json::array([]) },
    "current": Json::boolean((k.peers_current)()),
  }
  if unprotected.length() > 0 {
    m["unprotected"] = Json::array(unprotected)
  }
  Json::object(m)
}

///|
/// All of a stream, at most `limit` bytes.
async fn read_all(stream : @door.Stream, limit : Int) -> Bytes {
  let parts = []
  let mut size = 0
  while (stream.read)() is Some(more) {
    size += more.length()
    if size > limit {
      raise Refused("peer message too large")
    }
    parts.push(more)
  }
  @door.concat(parts)
}

///|
/// `f` within `ms`, else raises `why`.
pub async fn[X] within(ms : Int, f : async () -> X, why : String) -> X {
  match @effect.timeout(ms, f) {
    Some(x) => x
    None => raise Refused(why)
  }
}

///|
/// What follows a head on a reader's stream, as it comes, each piece within `bytes_idle_ms` (peer.ts `Incoming`).
struct Incoming {
  reader : @door.Reader
  mut ended : Bool
  mut held : Bool
  mut over : Bool
  mut stop_later : Bool
  idle_ms : Int
}

///|
fn Incoming::new(reader : @door.Reader, idle_ms? : Int = bytes_idle_ms) -> Incoming {
  { reader, ended: false, held: false, over: false, stop_later: false, idle_ms }
}

///|
async fn Incoming::next(self : Incoming) -> Bytes? {
  if self.over {
    return None
  }
  if self.reader.carry.length() > 0 {
    return Some(self.reader.take_carry())
  }
  let more = try {
    within(self.idle_ms, () => (self.reader.stream.read)(), "the other station sent nothing for 30 s")
  } catch {
    e => {
      self.stop()
      raise e
    }
  }
  match more {
    None => {
      self.ended = true
      self.over = true
      None
    }
    Some(b) => Some(b)
  }
}

///|
async fn Incoming::stop(self : Incoming) -> Unit {
  if !self.over {
    self.over = true
    if self.held {
      self.stop_later = true
    } else {
      (self.reader.stream.reset)(stopped_code) catch {
        _ => ()
      }
    }
  }
}

///|
/// The answer through: what was not read of it stopped now.
async fn Incoming::let_go(self : Incoming) -> Unit {
  self.held = false
  if self.stop_later || (!self.over && !self.ended) {
    self.stop_later = false
    self.over = true
    (self.reader.stream.reset)(stopped_code) catch {
      _ => ()
    }
  }
}

///|
fn Incoming::body(self : Incoming) -> Body {
  { next: () => self.next(), stop: () => self.stop(), check: None }
}

///|
/// What a request's bytes fail with when the other end took none of them for `bytes_idle_ms`.
pub let stalled : String = "the other station took nothing for 30 s"

///|
/// `bytes` written to `stream` as they come, each piece taken within `idle_ms`, and the stream finished; reset when
/// they fail on the way (peer.ts `sendBytes`). `failed` told first whether it was the bytes' own source.
async fn send_bytes(stream : @door.Stream, bytes : Body, failed : ((Bool, Error) -> Unit)?, idle_ms? : Int = bytes_idle_ms) -> Unit {
  let mut source = true
  try {
    while (bytes.next)() is Some(piece) {
      if bytes.check is Some(c) {
        c()
      }
      source = false
      within(idle_ms, () => (stream.write)(piece), stalled)
      source = true
    }
    source = false
    (stream.finish)()
  } catch {
    e => {
      if failed is Some(f) {
        f(source, e)
      }
      ignore(@effect.runtime().fork(() => (stream.reset)(failed_code) catch { _ => () }))
      raise e
    }
  }
}

///|
/// Stations of other workspaces this one shares chats with: whether it may ask one.
pub type Outside = (String, String) -> Bool

///|
/// The workspace a request to `target` goes to (peer.ts `workspaceFor`).
async fn workspace_for(k : Keeper, target : String, workspace : String?, outside : Outside?) -> String {
  if (k.peers_current)() && (k.rig_of)(target, workspace) is Some(rig) {
    return str_of(field(rig, "workspace")).unwrap_or("")
  }
  match (workspace, outside) {
    (None, _) | (_, None) => return peer_member(k, target, workspace)
    (Some(w), Some(o)) => {
      if (k.member_of)(w) is Some(_) {
        return peer_member(k, target, workspace)
      }
      if (k.home)() is None {
        raise Refused("station is outside this workspace")
      }
      if !o(target, w) {
        raise Refused("that station is of another workspace that shares no chat with this one")
      }
      w
    }
  }
}

///|
/// Where the stations are dialed (relays.ts `stationAddr`, peer-relays.ts): a connection to `target` asked in a
/// workspace, offering `stillfail/station/2` then `/1`, given up once `given_up` is done; `hold` sets its relays turned
/// off before it is dialed (None: the endpoint holds none, a kept connection through one is closed by `goes_off`).
pub(all) struct Dialing {
  connect : async (String, String?, @effect.Deferred[Unit]) -> @door.Connection
  hold : (async (String) -> Unit)?
  goes_off : ((@door.Connection, String, String?) -> Bool)?
  relays_changed : ((() -> Unit) -> () -> Unit)?
}

///|
/// How long a request's answer is waited for, a connection asked whether it is there once a request waited, and how
/// long that ask takes at most.
pub let answer_ms : Int = 30000

///|
pub let check_ms : Int = 2000

///|
pub let heard_ms : Int = 3000

///|
/// What the station transport's caller is given: its requests, `arrived` for each connection another station opens
/// to this one, and what stops it.
pub(all) struct StationCall {
  call : PeerCall
  arrived : (@door.Connection) -> Unit
  close : () -> Unit
}

///|
priv struct Dial {
  made : @effect.Deferred[@door.Connection]
  mut waiters : Int
  mut settled : Bool
  mut abandoned : Bool
  given_up : @effect.Deferred[Unit]
}

///|
fn closed_stopping(conn : @door.Connection) -> Bool {
  match conn.close_reason {
    Some(f) => f() == Some(("application", stopping))
    None => false
  }
}

///|
/// What a station's connections are closed with as its process stops or hands over to the next.
pub let stopping : String = "station stopping"

///|
fn received(conn : @door.Connection) -> Double? {
  match conn.stats {
    Some(s) => {
      let t = s()
      match t.get("rxPackets") {
        Some(n) => Some(n)
        None => t.get("rxBytes")
      }
    }
    None => None
  }
}

///|
/// How this station asks the others: one connection kept per peer, dialed once however many requests wait for it,
/// and let go when it fails or its peer is no longer heard (peer.ts `peerCall`).
pub fn peer_call(
  k : Keeper,
  dialing : Dialing,
  rt : @effect.Runtime,
  outside? : Outside,
  answer_wait? : Int = answer_ms,
  check_wait? : Int = check_ms,
  heard_wait? : Int = heard_ms,
  idle_wait? : Int = bytes_idle_ms,
) -> StationCall {
  let connections : Map[String, @door.Connection] = Map([])
  let asked_in : Map[String, String?] = Map([])
  let holds = dialing.hold is Some(_)
  let sweep = () => {
    if holds {
      return
    }
    guard dialing.goes_off is Some(goes) else { return }
    for target, conn in connections.copy() {
      if (conn.is_closed)() || !goes(conn, target, asked_in.get(target).unwrap_or(None)) {
        continue
      }
      connections.remove(target)
      @door.log("info", "mesh", "a station's connection goes through a relay turned off: closed", { "peer": Json::string(short(target)) })
      (conn.close)(0, "its relay turned off")
    }
  }
  let stop_sweeping = match dialing.relays_changed {
    Some(f) => f(sweep)
    None => () => ()
  }
  let asking : Array[(@door.Connection, @effect.Deferred[Bool])] = []
  let there = async fn(conn : @door.Connection) -> Bool {
    if (conn.is_closed)() {
      return false
    }
    guard conn.answers is Some(answers) else { return true }
    match asking.iter().find_first(a => physical_equal(a.0, conn)) {
      Some((_, d)) => d.wait()
      None => {
        let d = @effect.Deferred::new()
        asking.push((conn, d))
        let yes = answers(heard_wait) catch { _ => false }
        match asking.search_by(a => physical_equal(a.0, conn)) {
          Some(i) => ignore(asking.remove(i))
          None => ()
        }
        ignore(d.succeed(yes))
        yes
      }
    }
  }
  let found : Array[@door.Connection] = []
  let drop = (target : String, conn : @door.Connection) => {
    if connections.get(target) is Some(c) && physical_equal(c, conn) {
      connections.remove(target)
    }
    if (conn.is_closed)() {
      return
    }
    found.push(conn)
    @door.log("info", "mesh", "a station's connection is gone: closed", { "peer": Json::string(short(target)) })
    (conn.close)(0, "not answering")
  }
  // What waits for an answer on `conn`, raising PeerGone once it is found gone (check_wait on with nothing heard).
  let watched = async fn(target : String, conn : @door.Connection, before : Double?, f : async () -> Json?) -> Json? {
    @effect.race_first(f, () => {
      @effect.sleep(check_wait)
      if before is Some(b) && received(conn).unwrap_or(b) > b {
        @effect.never()
      }
      if there(conn) {
        @effect.never()
      }
      drop(target, conn)
      raise PeerGone(peer_gone_words, false)
    })
  }
  let dials : Map[String, Dial] = Map([])
  let connected = async fn(target : String, ws : String?) -> (Dial?, @door.Connection?) {
    match connections.get(target) {
      Some(open) if !(open.is_closed)() => {
        let off = match dialing.goes_off {
          Some(goes) if !holds => goes(open, target, ws)
          _ => false
        }
        if !off {
          if dialing.hold is Some(h) {
            h(target)
          }
          return (None, Some(open))
        }
        connections.remove(target)
        @door.log("info", "mesh", "a station's connection goes through a relay turned off: closed, dialed anew", { "peer": Json::string(short(target)) })
        (open.close)(0, "its relay turned off")
      }
      _ => ()
    }
    let d = match dials.get(target) {
      Some(d) => d
      None => {
        let d : Dial = { made: @effect.Deferred::new(), waiters: 0, settled: false, abandoned: false, given_up: @effect.Deferred::new() }
        dials[target] = d
        ignore(rt.fork_daemon("peer dial", on_error=e => {
          d.settled = true
          if dials.get(target) is Some(x) && physical_equal(x, d) {
            dials.remove(target)
          }
          ignore(d.made.fail(NoLink("peer unavailable: \{words_of(e)}")))
        }, () => {
          let made = try {
            if dialing.hold is Some(h) {
              h(target)
            }
            Ok((dialing.connect)(target, ws, d.given_up))
          } catch {
            e => Err(e)
          }
          d.settled = true
          if dials.get(target) is Some(x) && physical_equal(x, d) {
            dials.remove(target)
          }
          match made {
            Ok(conn) =>
              if d.abandoned {
                (conn.close)(0, "too late")
                ignore(d.made.fail(NoLink("peer unavailable: its dial was given up")))
              } else {
                connections[target] = conn
                ignore(d.made.succeed(conn))
              }
            Err(e) => ignore(d.made.fail(NoLink("peer unavailable or does not support station RPC: \{words_of(e)}")))
          }
        }))
        d
      }
    }
    d.waiters += 1
    (Some(d), None)
  }
  let leave = (target : String, d : Dial) => {
    d.waiters -= 1
    if d.settled || d.waiters > 0 {
      return
    }
    if dials.get(target) is Some(x) && physical_equal(x, d) {
      dials.remove(target)
    }
    d.abandoned = true
    ignore(d.given_up.succeed(()))
  }
  let stopped_there = async fn(conn : @door.Connection) -> Bool {
    if closed_stopping(conn) {
      return true
    }
    if conn.close_reason is None || (!(conn.is_closed)() && there(conn)) {
      return false
    }
    ignore((conn.closed)()) catch {
      _ => ()
    }
    closed_stopping(conn)
  }
  let let_go = async fn(target : String, conn : @door.Connection) {
    guard connections.get(target) is Some(c) && physical_equal(c, conn) else { return }
    let heard = !(conn.is_closed)() && conn.answers is Some(_) && there(conn)
    guard !heard && connections.get(target) is Some(c2) && physical_equal(c2, conn) else { return }
    connections.remove(target)
    (conn.close)(0, "not answering")
  }
  let late = "peer request timed out; execution may have happened — query the same task key"
  let ask : PeerCall = async fn(target, workspace, request, body) {
    if target == "" && field(request, "method") == Some(Json::string("peers")) {
      let listed = roster(k, workspace)
      let lws = str_of(field(listed, "workspace")).unwrap_or("")
      let rigs = if lws == "" { [] } else { (k.rigs)(lws) }
      let named = if lws == "" { [] } else { (k.rigs_named)(lws) }
      let waiting = named.filter(r => !rigs.iter().any(x => field(x, "id") == field(r, "id")))
      guard listed is Object(lm) else { return (listed, None) }
      let m = lm.copy()
      if rigs.length() > 0 {
        m["rigs"] = Json::array(rigs)
      }
      if waiting.length() > 0 {
        m["rigsWaiting"] = Json::array(waiting)
      }
      return (Json::object(m), None)
    }
    let verb = match field(request, "method") { Some(String(v)) => v; _ => "" }
    let proof = verb == "rig.proof" &&
      workspace is Some(w) &&
      (k.peers_current)() &&
      (k.rigs_named)(w).iter().any(r => str_of(field(r, "id")) == Some(target))
    let offered = match workspace {
      Some(w) if (k.peers_current)() && verb.has_prefix("lock.") && (k.moved_offered)(w) =>
        (k.joined)().iter().any(j => str_of(field(j, "workspace")) == Some(w) && peers_of(j).contains(target))
      _ => false
    }
    let ws = if proof || offered { workspace } else { Some(workspace_for(k, target, workspace, outside)) }
    asked_in[target] = ws
    let conn_ref : Ref[@door.Connection?] = Ref(None)
    let dial_ref : Ref[Dial?] = Ref(None)
    let left = Ref(false)
    let leave_now = () => if !left.val {
      left.val = true
      if dial_ref.val is Some(d) {
        leave(target, d)
      }
    }
    let call = async fn() -> (Json, Body?) {
      let (d, open) = connected(target, ws)
      dial_ref.val = d
      let conn = match open {
        Some(c) => c
        None => {
          let d = d.unwrap()
          match body {
            None => d.made.wait()
            Some(_) => within(answer_wait, () => d.made.wait(), late)
          }
        }
      }
      conn_ref.val = Some(conn)
      leave_now()
      let envelope : Map[String, Json] = {
        "workspace": match ws { Some(w) => Json::string(w); None => Json::null() },
        "request": request,
      }
      if (conn.alpn)() != peer_bytes_alpn {
        if body is Some(_) {
          raise NoBytes("that station takes files only in chunks (it is not updated yet)")
        }
        let stream = (conn.open_bi)()
        let before = received(conn)
        let bytes = @utf8.encode(Json::object(envelope).stringify())
        if bytes.length() > max_message {
          raise Refused("peer request too large")
        }
        (stream.write)(bytes)
        (stream.finish)()
        let read = watched(target, conn, before, () => Some(Json::string(@utf8.decode_lossy(read_all(stream, max_message)))))
        let answer = @json.parse(match read { Some(String(t)) => t; _ => "null" })
        if field(answer, "error") is Some(String(e)) {
          raise PeerRefused(e)
        }
        return (field(answer, "result").unwrap_or(Json::null()), None)
      }
      let stream = (conn.open_bi)()
      let before = received(conn)
      if body is Some(_) {
        envelope["bytes"] = Json::boolean(true)
      }
      let head = @door.line_bytes(Json::object(envelope))
      if head.length() > max_message {
        raise Refused("peer request too large")
      }
      let reader = @door.Reader::new(stream, max_line=max_message)
      let answer = match body {
        None => {
          (stream.write)(head)
          (stream.finish)()
          watched(target, conn, before, () => reader.line())
        }
        Some(b) => {
          within(idle_wait, () => (stream.write)(head), late)
          let answered : @effect.Deferred[Json?] = @effect.Deferred::new()
          ignore(rt.fork_daemon("peer answer", on_error=e => ignore(answered.fail(e)), () => {
            let a = try { Ok(reader.line()) } catch { e => Err(e) }
            match a {
              Ok(v) => ignore(answered.succeed(v))
              Err(e) => ignore(answered.fail(e))
            }
          }))
          let sent = Ref(false)
          let source_failed : Ref[Error?] = Ref(None)
          // What the sending fails with stays in it (said by `failed` above, and by the answer's stream it reset):
          // once the answer came first nothing waits on it, and an error left in it was the runtime's defect (`the
          // other station took nothing for 30 s`, a broken pipe).
          let sending = rt.fork(name="peer bytes", () => try {
            send_bytes(stream, b, Some((source, e) => {
              if source {
                source_failed.val = Some(e)
              }
              @door.log("info", "mesh", if source { "a request's bytes failed at their source: its stream reset" } else { "a request's bytes were not taken by the stream: its stream reset" }, {
                "peer": Json::string(short(target)),
                "method": Json::string(verb),
                "error": Json::string(words_of(e)),
              })
            }), idle_ms=idle_wait)
            sent.val = true
          } catch {
            _ => ()
          })
          ignore(@effect.race_first(() => { ignore(sending.wait()) }, () => { ignore(answered.wait()) catch { _ => () } }))
          let a = within(answer_wait, () => watched(target, conn, before, () => answered.wait()), late)
          if !sent.val {
            ignore(rt.fork_quiet(name="peer reset", () => (stream.reset)(stopped_code) catch { _ => () }))
          }
          if a is None && source_failed.val is Some(e) {
            raise e
          }
          a
        }
      }
      guard answer is Some(answer) else { raise Refused("the other station answered nothing") }
      if field(answer, "error") is Some(String(e)) {
        raise PeerRefused(e)
      }
      let result = field(answer, "result").unwrap_or(Json::null())
      if field(answer, "bytes") != Some(Json::boolean(true)) {
        return (result, None)
      }
      guard result is Object(_) else { raise Refused("bytes after an answer that is no object") }
      (result, Some(Incoming::new(reader, idle_ms=idle_wait).body()))
    }
    try {
      match body {
        None => within(answer_wait, call, late)
        Some(_) => call()
      }
    } catch {
      error => {
        let failed = conn_ref.val
        leave_now()
        if failed is Some(f) && found.iter().any(c => physical_equal(c, f)) {
          raise (match error { PeerGone(_, _) => error; _ => PeerGone(peer_gone_words, false) })
        }
        let words = words_of(error)
        if failed is Some(f) && words == stalled && !(f.is_closed)() && !there(f) {
          drop(target, f)
          raise PeerGone(peer_gone_words, false)
        }
        let final_ = error is PeerRefused(_) || error is NoBytes(_)
        if failed is Some(f) && !final_ && words != late && stopped_there(f) {
          if connections.get(target) is Some(c) && physical_equal(c, f) {
            connections.remove(target)
          }
          raise PeerGone(peer_stopped_words, true)
        }
        if !final_ && failed is Some(f) {
          ignore(rt.fork_quiet(name="peer let go", () => let_go(target, f)))
        }
        if failed is None && dial_ref.val is Some(d) && dials.get(target) is Some(x) && physical_equal(x, d) {
          dials.remove(target)
        }
        raise error
      }
    }
  }
  let arrived = (conn : @door.Connection) => {
    let target = (conn.remote_id)()
    if dialing.hold is Some(h) {
      ignore(rt.fork_daemon("peer relay policy", on_error=_ => (conn.close)(0, "relay policy unavailable"), () => h(target) catch {
        e => {
          @door.log("warn", "mesh", "incoming station relay policy failed", { "peer": Json::string(short(target)), "error": Json::string(words_of(e)) })
          (conn.close)(0, "relay policy unavailable")
        }
      }))
    }
    guard connections.get(target) is Some(kept) && !physical_equal(kept, conn) && !(kept.is_closed)() else { return }
    ignore(rt.fork_quiet(name="peer kept", () => if !there(kept) { drop(target, kept) }))
  }
  { call: ask, arrived, close: stop_sweeping }
}

///|
/// Another station's connection: each of its requests answered, while it belongs (peer.ts `servePeer`).
pub async fn serve_peer(k : Keeper, conn : @door.Connection, remote : PeerBus) -> Unit {
  let rt = @effect.runtime()
  let peer = (conn.remote_id)()
  let outsider = async fn() -> Bool {
    (k.peers_current)() && remote.hears_outside() && (k.has_state)() && (k.home)() is Some(_) && peer != (k.station)()
  }
  let inside = async fn() -> Bool {
    try {
      ignore(peer_member(k, peer, None))
      true
    } catch {
      e => if outsider() { false } else { raise e }
    }
  }
  let rig = async fn() -> Bool { (k.peers_current)() && (k.rig_of)(peer, None) is Some(_) }
  try {
    if !rig() {
      ignore(inside())
    }
  } catch {
    e => if (k.peers_current)() { raise e }
  }
  let answering = Ref(0)
  // (an accept's failure, the connection lost, kept in its fiber's value and raised here: a fiber that fails is the
  // runtime's defect, told before the join takes it)
  let next : Ref[@effect.Fiber[Result[@door.Stream?, Error]]?] = Ref(None)
  while true {
    let waiting = match next.val {
      Some(f) => f
      None => {
        let f = rt.fork(name="peer accept", () => try { Ok((conn.accept_bi)()) } catch { e => Err(e) })
        next.val = Some(f)
        f
      }
    }
    let got = @effect.timeout(60000, () => waiting.join())
    match got {
      None => {
        if answering.val > 0 {
          continue
        }
        raise Refused("peer idle")
      }
      Some(accepted) => {
        next.val = None
        let stream = match accepted {
          Ok(stream) => stream
          Err(e) => raise e
        }
        guard stream is Some(stream) else { return }
        answering.val += 1
        ignore(rt.fork_daemon("peer stream", on_error=e => {
          @door.log("info", "mesh", "a station's stream was not answered", { "peer": Json::string(short(peer)), "error": Json::string(words_of(e)) })
          ignore(rt.fork_quiet(name="peer stream reset", () => (stream.reset)(0) catch { _ => () }))
        }, () => {
          defer { answering.val -= 1 }
          answer_peer_stream(k, conn, remote, peer, stream, rig, inside)
        }))
      }
    }
  }
}

///|
async fn answer_peer_stream(
  k : Keeper,
  conn : @door.Connection,
  remote : PeerBus,
  peer : String,
  stream : @door.Stream,
  rig : async () -> Bool,
  inside : async () -> Bool,
) -> Unit {
  let bytes = (conn.alpn)() == peer_bytes_alpn
  let reader = @door.Reader::new(stream, max_line=max_message)
  let incoming : Ref[Incoming?] = Ref(None)
  let outgoing : Ref[Body?] = Ref(None)
  let asked : Ref[Json] = Ref(Json::null())
  let begun = @effect.now()
  let answer : Json = try {
    let envelope = if bytes {
      within(15000, () => reader.line(), "peer request timed out").unwrap_or(Json::null())
    } else {
      @json.parse(@utf8.decode_lossy(within(15000, () => read_all(stream, max_message), "peer request timed out")))
    }
    guard field(envelope, "workspace") is Some(String(workspace)) else { raise Refused("workspace missing") }
    let mut request = field(envelope, "request").unwrap_or(Json::null())
    asked.val = request
    if !bytes && request is Object(m) && m.contains("whole") {
      let c = m.copy()
      c.remove("whole")
      request = Json::object(c)
    }
    let mut body : Body? = None
    if bytes && field(envelope, "bytes") == Some(Json::boolean(true)) {
      guard request is Object(_) else { raise Refused("bytes after a request that is no object") }
      let inc = Incoming::new(reader)
      inc.held = true
      incoming.val = Some(inc)
      body = Some(inc.body())
    }
    let is_rig = rig()
    let as_rig = if is_rig { (k.rig_of)(peer, Some(workspace)) } else { None }
    if is_rig && as_rig is None {
      raise Refused("a rig asks nothing of a station")
    }
    let ours = as_rig is None && inside()
    let there = ours &&
      (match (k.member_of)(workspace) {
        Some(m) => peers_of(m).contains(peer)
        None => false
      })
    let verb = field(request, "method")
    let (result, out) = if as_rig is Some(_) {
      match verb {
        Some(String(m)) if m == "task.changed" || rig_tells.contains(m) => ()
        _ => raise Refused("a rig asks nothing of a station")
      }
      remote.handle(workspace, peer, request, body)
    } else if there || (ours && !remote.hears_outside()) {
      ignore(peer_member(k, peer, Some(workspace)))
      let w = if workspace != "" && Some(workspace) != (k.home)() { Some(workspace) } else { None }
      if (k.waiting)(w) && !heard_waiting(k, verb) {
        raise Refused(not_given)
      }
      let named = if workspace != "" { workspace } else { (k.home)().unwrap_or("") }
      let r = match verb {
        Some(String(m)) if m.has_prefix("lock.") => (answer_lock(k, request, Some(workspace), Some(peer)), None)
        Some(String(m)) if m.has_prefix("ways.") => ((k.answer_ways)(request, named), None)
        Some(String(m)) if m.has_prefix("stationMarks.") => ((k.answer_marks)(request, named), None)
        _ => remote.handle(workspace, peer, request, body)
      }
      if verb == Some(Json::string("lock.person.put")) || verb == Some(Json::string("lock.person.offer")) {
        (k.persons_written)()
      }
      r
    } else {
      if (k.member_of)(workspace) is None {
        raise Refused("station is outside this workspace")
      }
      remote.handle_outside(peer, request, body, workspace)
    }
    outgoing.val = out
    if out is Some(_) && !bytes {
      raise Refused("this answer has bytes the caller's transport cannot take")
    }
    if out is Some(_) {
      { "result": result, "bytes": true }
    } else {
      { "result": result }
    }
  } catch {
    e => {
      outgoing.val = None
      { "error": Json::string(words_of(e)) }
    }
  }
  let ms = @effect.now() - begun
  if ms >= slow_ms {
    let s = (k : String) => match field(asked.val, k) {
      Some(String(v)) => v
      Some(Null) | None => ""
      Some(v) => v.stringify()
    }
    @door.log("warn", "mesh", "peer request answered slowly", {
      "peer": Json::string(short(peer)),
      "method": Json::string(s("method")),
      "session": Json::string(s("session")),
      "key": Json::string(s("key")),
      "ms": Json::number(ms.to_double()),
    })
  }
  let mut answer = answer
  if outgoing.val is Some(o) && o.check is Some(check) {
    try {
      check()
    } catch {
      e => {
        answer = { "error": Json::string(words_of(e)) }
        outgoing.val = None
      }
    }
  }
  try {
    (stream.write)(@utf8.encode(answer.stringify() + (if bytes { "\n" } else { "" })))
    match outgoing.val {
      Some(o) => send_bytes(stream, o, None)
      None => (stream.finish)()
    }
  } catch {
    e => {
      let m : Map[String, Json] = { "error": Json::string(words_of(e)) }
      if field(answer, "error") is Some(f) {
        m["failed"] = f
      }
      @door.log("info", "mesh", "peer answer not sent", Json::object(m))
      if incoming.val is Some(inc) {
        inc.let_go()
      }
      return
    }
  }
  ignore(@effect.timeout(10000, () => (stream.stopped)() catch { _ => None }))
  if incoming.val is Some(inc) {
    inc.let_go()
  }
}
