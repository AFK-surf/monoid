// The station's requests to and from the other stations of its workspace (station/src/mesh/bus.ts): one bus for every
// part that asks or answers them. A part says which methods it answers (`on`); a request is answered by the part whose
// method or prefix (`share.`) it names, a request of a station of another workspace by the one that hears those
// (`outside`). What is asked before the transport is there waits for it (`mesh_wait_ms`).

///|
/// The answer of a peer that refused a request (its `{"error": …}`): final, unlike a request that did not get through.
pub(all) suberror PeerRefused {
  PeerRefused(String)
}

///|
/// A request to a station no link to which would open: the one failure that says it is not there now.
pub(all) suberror NoLink {
  NoLink(String)
}

///|
/// A request with bytes to a station whose transport carries none.
pub(all) suberror NoBytes {
  NoBytes(String)
}

///|
/// What a request fails with when its connection was found gone (its other end did not answer on it); `stopped`: its
/// other end's process stopped or handed over as it was asked (peer.ts `PeerGone`, `PeerStopped`).
pub(all) suberror PeerGone {
  PeerGone(String, Bool)
}

///|
pub let peer_gone_words : String = "the other station's connection was gone: the request got no answer from it (asked again, it is dialed anew)"

///|
pub let peer_stopped_words : String = "the other station's process stopped or handed over as it was asked: its connection closed and the request got no answer (asked again, it is dialed anew)"

///|
/// A request answered here: from which station, the request and its bytes, the workspace it was made in.
pub type Inbox = async (String, Json, Body?, String) -> (Json, Body?)

///|
/// A request asked before the transport is attached waits for it this long.
pub let mesh_wait_ms : Int = 30000

///|
pub struct PeerBus {
  priv mut call : PeerCall?
  priv attached : @effect.Deferred[Unit]
  priv wait_ms : Int
  priv handlers : Map[String, Inbox]
  priv mut rest : Inbox?
  priv mut outsider : Inbox?
  priv mut guard_ : ((String, String, Json) -> Unit raise)?
  priv on_attach : Array[() -> Unit]
  priv mut now : ((String, String?) -> String)?
  priv mut self_ : String
  priv hearers : Array[(String) -> Unit]
}

///|
pub fn PeerBus::new(wait_ms? : Int = mesh_wait_ms) -> PeerBus {
  {
    call: None,
    attached: @effect.Deferred::new(),
    wait_ms,
    handlers: Map([]),
    rest: None,
    outsider: None,
    guard_: None,
    on_attach: [],
    now: None,
    self_: "",
    hearers: [],
  }
}

///|
/// The transport is there: what waited for it is asked, what follows it starts.
pub fn PeerBus::attach(self : PeerBus, call : PeerCall) -> Unit {
  self.call = Some(call)
  ignore(self.attached.succeed(()))
  let fs = self.on_attach.copy()
  self.on_attach.clear()
  for f in fs {
    f()
  }
}

///|
/// `f` once the transport is there (at once if it is).
pub fn PeerBus::when_attached(self : PeerBus, f : () -> Unit) -> Unit {
  if self.call is Some(_) {
    f()
  } else {
    self.on_attach.push(f)
  }
}

///|
async fn PeerBus::ready(self : PeerBus) -> PeerCall {
  if self.call is None {
    ignore(@effect.timeout(self.wait_ms, () => self.attached.wait()))
  }
  match self.call {
    Some(c) => c
    None => raise Refused("station mesh is not ready")
  }
}

///|
/// A request to another station of the workspace. One named by a lost station's id goes to the station that took its
/// place, this one's own answered here.
pub async fn PeerBus::ask(self : PeerBus, station : String, request : Json, bytes? : Body) -> (Json, Body?) {
  let call = self.ready()
  let workspace = match field(request, "workspace") { Some(String(w)) => Some(w); _ => None }
  let to = match self.now {
    Some(now) if station != "" => now(station, workspace)
    _ => station
  }
  if to != station && to == self.self_ {
    return self.handle(workspace.unwrap_or(""), self.self_, request, bytes)
  }
  call(to, workspace, request, bytes)
}

///|
/// A request to the station `station` names itself, never to one that took its place.
pub async fn PeerBus::ask_itself(self : PeerBus, station : String, request : Json, bytes? : Body) -> (Json, Body?) {
  let call = self.ready()
  call(station, match field(request, "workspace") { Some(String(w)) => Some(w); _ => None }, request, bytes)
}

///|
/// Whether a request naming `station` comes back to this station.
pub fn PeerBus::came_here(self : PeerBus, station : String, workspace? : String? = None) -> Bool {
  if station == "" || self.self_ == "" {
    return false
  }
  station == self.self_ ||
  (match self.now {
    Some(now) => now(station, workspace) == self.self_
    None => false
  })
}

///|
/// Which station took a lost one's place; `me`, this station's id.
pub fn PeerBus::formerly(self : PeerBus, now : (String, String?) -> String, me : String) -> Unit {
  self.now = Some(now)
  self.self_ = me
}

///|
/// Who answers `methods` (whole names, or prefixes ending in `.`).
pub fn PeerBus::on(self : PeerBus, methods : Array[String], inbox : Inbox) -> Unit {
  for m in methods {
    self.handlers[m] = inbox
  }
}

///|
pub fn PeerBus::otherwise(self : PeerBus, inbox : Inbox) -> Unit {
  self.rest = Some(inbox)
}

///|
pub fn PeerBus::outside(self : PeerBus, inbox : Inbox) -> Unit {
  self.outsider = Some(inbox)
}

///|
pub fn PeerBus::guarded(self : PeerBus, g : (String, String, Json) -> Unit raise) -> Unit {
  self.guard_ = Some(g)
}

///|
pub fn PeerBus::hears_outside(self : PeerBus) -> Bool {
  self.outsider is Some(_)
}

///|
/// Who is told each time another station is heard from.
pub fn PeerBus::heard(self : PeerBus, f : (String) -> Unit) -> Unit {
  self.hearers.push(f)
}

///|
/// A request of a station of `workspace`.
pub async fn PeerBus::handle(self : PeerBus, workspace : String, peer : String, request : Json, bytes : Body?) -> (Json, Body?) {
  for f in self.hearers {
    f(peer)
  }
  let verb = match field(request, "method") { Some(String(m)) => m; _ => "" }
  let inbox = match self.handlers.get(verb) {
    Some(i) => Some(i)
    None =>
      match verb.find(".") {
        Some(dot) if dot > 0 =>
          match self.handlers.get(verb.clamped_view(end=dot + 1).to_owned()) {
            Some(i) => Some(i)
            None => self.rest
          }
        _ => self.rest
      }
  }
  guard inbox is Some(inbox) else { raise Refused("station is starting") }
  if self.guard_ is Some(g) {
    g(workspace, peer, request)
  }
  inbox(peer, request, bytes, workspace)
}

///|
/// A request of a station that is not of this workspace.
pub async fn PeerBus::handle_outside(self : PeerBus, peer : String, request : Json, bytes : Body?, workspace : String) -> (Json, Body?) {
  guard self.outsider is Some(o) else { raise Refused("station is starting") }
  o(peer, request, bytes, workspace)
}
