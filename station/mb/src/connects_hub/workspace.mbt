// The workspace's connects (remote.mbt) as a part of the agents' side (connects/workspace.ts): on the station a connect
// runs on, its platform's events routed to the station a chat of their thread runs on, the calls of those chats
// answered, the connect moved to another station by hand (POST /connects/:id/move); on the station a chat runs on, the
// events taken and the connect's surface asked; on every one, whether a connect being added runs on another station
// already.

///|
/// What a connect's secret is known by across the workspace without being said: its platform's token (Slack's bot
/// token, a Comma line's token, a group connect's key) or its app (Feishu's), hashed. None: one that has none yet.
pub fn fingerprint(kind : String, own : J?) -> String? {
  let field = match kind {
    "feishu" => "appId"
    "comma" => "token"
    "group" => "key"
    _ => "botToken"
  }
  match nonempty_str(at(own, field)) {
    Some(secret) => Some(@cloud_net.sha256_hex("\{kind}\n\{secret}"))
    None => None
  }
}

///|
/// The hub, as the workspace's connects use it.
pub(all) struct WsHub {
  /// `hub.chatOf(id)`: the surface it posts through (a connect of its own, or another station's: `remote`).
  chat_of : async (String) -> Surface?
  /// `hub.config().connects`: each connect as the hub reads it (sessions/config.ts `Connect`).
  config_connects : async () -> Array[J]
  receive : async (String, J) -> Unit
  /// The station a chat of this thread was handed to (null: none).
  moved_to : async (String, String, String) -> String?
  /// Whether its chats of that workspace are being handed to another station.
  quiet_in : async (String) -> Bool
  /// The surface a connect's threads are kept under (`hub.surface(id)`).
  surface : async (String) -> String
  /// `hub.toldBots.set(peer, new Set(bots))`.
  told_bots : async (String, Array[String]) -> Unit
}

///|
/// The store, as the workspace's connects use it: the threads a connect handed to other stations.
pub(all) struct WsStore {
  drop_connect_thread_station : async (String, String, String) -> Unit
  set_connect_thread_station : async (String, String, String, String) -> Unit
  connect_thread_station : async (String, String, String) -> String?
  drop_connect_threads : async (String) -> Unit
  /// `{channel, threadTs, station}` each.
  connect_threads : async (String) -> Array[J]
  /// `{channel, threadTs}` each.
  connect_local_threads : async (String) -> Array[J]
  /// The thread's row, null where there is none.
  thread_at : async (String, String, String) -> J
}

///|
/// The mesh between the stations (mesh/bus.ts `PeerBus`): asking one, and what this one answers by method. What a
/// station refused (`Refused` there) raises `Thrown("Declined", ...)`.
pub(all) struct Bus {
  ask : async (String, J, Body) -> Answer
  /// What answers `method`: given the asking station, its request, its workspace and the bytes after it.
  on : (String, async (String, J, String?, Bytes?) -> Answer) -> Unit
  /// Told each station a request was heard from (none where the bus does not tell).
  heard : (((String) -> Unit) -> Unit)?
}

///|
pub(all) struct WorkspaceDeps {
  data : String
  hub : WsHub
  store : WsStore
  config : Config
  /// This station's id, and its home workspace.
  here : () -> String
  home : () -> String?
  /// The stations of one of this station's workspaces (the cloud's roster: `{id, name}`); none of any other.
  stations : (String) -> Array[J]
  bus : Bus
  /// Each platform's names book.
  names : (String) -> NameBook?
  fs : Fs
  log : Log
  speech : Speech
  uuid : () -> String
}

///|
pub struct WorkspaceConnects {
  remote : RemoteConnects
  priv d : WorkspaceDeps
  /// The files a chat of another station posts, until they are posted.
  priv uploads : String
  priv uploads_cleared : @effect.Deferred[Unit]
  /// One event at a time per thread: a conversation's first message is handed on before its next is looked at.
  priv gates : Map[String, Turns]
  /// What a platform says of a workspace whose chats this station hands to another (hub `quiet`), acknowledged and
  /// kept in order, on disk, until it goes there (`move_all`); one at a time, the kept ones before any after them.
  priv held_file : String
  priv held_turn : Turns
  /// The workspaces whose kept events went to the station their chats went to, and where the next go at once.
  priv held_to : Map[String, String]
  /// The connects of this station's being handed to another (`move`), from the moment that one is asked to take it:
  /// where it went once taken (None: it was not, and is this station's still), and its workspace. What its socket
  /// here still gives meanwhile waits for it and goes to the holder (`receive`), never handled here, nor twice.
  priv handing : Map[String, (@effect.Deferred[String?], String)]
  /// The moves of a connect of this station's under way (`{id, to, ws, localsTo}`), kept from before it asks the other
  /// to take it until it heard either way (`replica/connects-moving/`).
  priv moving : Map[String, J]
  /// Those whose move is asking the other now (settled by its answer, not by `settle_moving`).
  priv asking : Set[String]
  priv settling : Turns
  /// Of each connect moved here that is not routed, the chats of it still on their way here (`move`'s `awaiting`),
  /// kept on disk with what its platform said meanwhile, read as the station starts.
  priv awaiting : Map[String, Set[String]]
  priv awaiting_turn : Turns
  /// The bots of this station's connects as last told to the workspace's other stations, by workspace.
  priv bots_told : Map[String, String]
}

///|
fn kind_of(c : J?) -> String {
  match at(c, "kind") {
    Some(Str(u)) => @jsjson.text(u)
    _ => "slack"
  }
}

///|
fn single_session(c : J?) -> Bool {
  str_of(at(c, "mode")) == Some("single-session")
}

///|
/// The workspace's connects of this station: what they kept read before the station serves, its handlers on the
/// mesh, and the moves left under way settled.
pub async fn WorkspaceConnects::new(d : WorkspaceDeps) -> WorkspaceConnects {
  let fs = d.fs
  let uploads = fs.join([d.data, "run", "connect-uploads"])
  let cleared : @effect.Deferred[Unit] = @effect.Deferred::new()
  // What a process before left of the files remote chats posted, taken away off the thread; the first upload waits
  // for it.
  spawn(async fn() {
    (fs.rm)(uploads) catch { _ => () }
    ignore(cleared.succeed(()))
  })
  let awaiting : Map[String, Set[String]] = Map([])
  let kept_awaiting = try parse_js((fs.read_text)(fs.join([d.data, "replica", "awaiting.json"]))) catch { _ => Null }
  for e in entries_of(Some(kept_awaiting)) {
    match e.1 {
      Arr(keys) if keys.length() > 0 => awaiting[e.0] = Set(keys.map(k => js_text(Some(k))))
      _ => ()
    }
  }
  let remote = RemoteConnects::new(d.data, d.here, { ask: d.bus.ask }, d.names, fs, d.log)
  let w : WorkspaceConnects = {
    remote,
    d,
    uploads,
    uploads_cleared: cleared,
    gates: {},
    held_file: fs.join([d.data, "replica", "held-events.jsonl"]),
    held_turn: Turns::new(),
    held_to: {},
    handing: {},
    moving: {},
    asking: Set([]),
    settling: Turns::new(),
    awaiting,
    awaiting_turn: Turns::new(),
    bots_told: {},
  }
  // (the moves under way as this station stopped: settled as it starts and as the station each went to is heard from)
  let names = (fs.readdir)(w.moving_dir()) catch { _ => [] }
  for name in names {
    let m = try parse_js((fs.read_text)(fs.join([w.moving_dir(), name]))) catch { _ => continue }
    match (str_of(at(Some(m), "id")), str_of(at(Some(m), "to"))) {
      (Some(id), Some(_)) => w.moving[id] = m
      _ => ()
    }
  }
  let bus = d.bus
  (bus.on)(holds_method, async fn(peer, request, workspace, _) {
    let known = known_in(at(Some(request), "connect"))
    guard known is Some(known) && workspace is Some(ws) && w.in_workspace(ws, peer) else { raise fail_("no such connect") }
    plain(jo([("holds", jb(w.entry_of(local_of(known, (d.here)())) is Some(_)))]))
  })
  // (a request heard: nothing asked of anyone unless a move of this station's is under way with that one)
  match bus.heard {
    Some(heard) => heard(peer => if w.moving.length() > 0 { spawn(async fn() { w.settle_moving(peer=Some(peer)) }) })
    None => ()
  }
  spawn(async fn() { w.settle_moving() })
  (bus.on)(event_method, async fn(peer, request, workspace, _) { w.taken(peer, request, workspace) })
  (bus.on)(moved_method, async fn(_, request, _, _) {
    let known = known_in(at(Some(request), "connect"))
    guard known is Some(known) && str_of(at(Some(request), "station")) is Some(station) else { raise fail_("no such connect") }
    w.remote.moved(local_of(known, (d.here)()), station)
    plain(jo([("ok", jb(true))]))
  })
  let answerer : CallAnswerer = {
    surface: async fn(known, workspace) {
      let id = local_of(known, (d.here)())
      match w.entry_of(id) {
        Some(entry) if workspace is Some(ws) && w.workspace_of(Some(entry)) == Some(ws) => w.own(id)
        _ => None
      }
    },
    uploads,
    cleared: async fn() { cleared.wait() },
    fs,
    uuid: d.uuid,
  }
  (bus.on)(call_method, async fn(_, request, workspace, body) { answerer.answer(request, body, workspace) })
  // Whether one of this station's connects of that workspace has that secret.
  (bus.on)(list_method, async fn(_, request, workspace, _) {
    let print = str_of(at(Some(request), "fingerprint")).unwrap_or("")
    let has = w
      .entries()
      .iter()
      .any(c => workspace is Some(ws) && w.workspace_of(Some(c)) == Some(ws) && fingerprint(kind_of(Some(c)), at(Some(c), kind_of(Some(c)))) == Some(print))
    plain(jo([("has", jb(has))]))
  })
  (bus.on)(take_method, async fn(peer, request, workspace, _) { w.take(peer, request, workspace) })
  // (the bots of another station's connects, told as they change: its notices are no person's message here)
  (bus.on)(bots_method, async fn(peer, request, workspace, _) {
    guard workspace is Some(ws) && w.in_workspace(ws, peer) else { raise fail_("not a station of this workspace") }
    let bots : Array[String] = []
    for b in arr_of(at(Some(request), "bots")).unwrap_or([]) {
      match str_of(Some(b)) {
        Some(s) if s != "" => bots.push(s)
        _ => ()
      }
    }
    let kept : Array[String] = []
    for b in bots[0:@cmp.minimum(200, bots.length())] {
      if !kept.contains(b) {
        kept.push(b)
      }
    }
    (d.hub.told_bots)(peer, kept)
    plain(jo([("ok", jb(true))]))
  })
  // (one thread's chat runs on another station from now on, or here again: replica/handover.ts)
  (bus.on)(route_method, async fn(peer, request, workspace, _) {
    let r = Some(request)
    let known = known_in(at(r, "connect"))
    let id = match known {
      Some(k) => local_of(k, (d.here)())
      None => ""
    }
    let entry = w.entry_of(id)
    guard known is Some(_) && entry is Some(_) && workspace is Some(ws) && w.workspace_of(entry) == Some(ws) && w.in_workspace(ws, peer) else {
      raise fail_("no such connect")
    }
    guard str_of(at(r, "channel")) is Some(channel) && str_of(at(r, "threadTs")) is Some(thread_ts) else { raise fail_("no such thread") }
    w.route_here(id, channel, thread_ts, str_of(at(r, "station")))
    plain(jo([("ok", jb(true))]))
  })
  w
}

///|
/// An answer of JSON alone.
fn plain(v : J) -> Answer {
  { json: v, bytes: None }
}

///|
fn WorkspaceConnects::here(self : WorkspaceConnects) -> String {
  (self.d.here)()
}

///|
/// A thread of a connect of this station's: its chat runs on `station` from now on (None, or this one: here).
async fn WorkspaceConnects::route_here(self : WorkspaceConnects, id : String, channel : String, thread_ts : String, station : String?) -> Unit {
  match station {
    Some(s) if s != self.here() => (self.d.store.set_connect_thread_station)(id, channel, thread_ts, s)
    _ => (self.d.store.drop_connect_thread_station)(id, channel, thread_ts)
  }
}

///|
/// A thread of connect `id` (as this station names it): its chat runs on `station` from now on, said where the connect
/// runs (here, or asked of the station it runs on, `connect.route`). Not a routed kind: refused.
pub async fn WorkspaceConnects::route(self : WorkspaceConnects, id : String, channel : String, thread_ts : String, station : String) -> Unit {
  match self.entry_of(id) {
    Some(entry) => {
      if !routed.contains(kind_of(Some(entry))) || single_session(Some(entry)) {
        raise fail_("that connect's chats run only where it runs")
      }
      return self.route_here(id, channel, thread_ts, Some(station))
    }
    None => ()
  }
  guard self.remote.surface(id) is Some(remote) else { raise fail_("connect \{id} is not known here") }
  ignore(
    (self.d.bus.ask)(
      remote.station,
      jo([
        ("method", js(route_method)),
        ("workspace", at(Some(remote.described), "workspace").unwrap_or(undefined())),
        ("connect", known_of(id, self.here()).to_j()),
        ("channel", js(channel)),
        ("threadTs", js(thread_ts)),
        ("station", js(station)),
      ])
      |> drop_undefined,
      NoBody,
    ),
  )
}

///|
/// Connect `id` as this station knows it: where it runs and what it says of itself (None: not known here), so that a
/// station a chat of it is handed to posts through it before it heard any of its events (`learn_of`).
pub async fn WorkspaceConnects::described_for(self : WorkspaceConnects, id : String) -> (String, J)? {
  match self.described(id) {
    Some(own) => return Some((self.here(), own))
    None => ()
  }
  self.remote.surface(id).map(r => (r.station, r.described))
}

///|
/// What another station said of a connect a chat handed here goes through (`described_for`): learnt, unless it is one
/// of this station's own.
pub fn WorkspaceConnects::learn_of(self : WorkspaceConnects, known : Known, station : String, described : J) -> Unit {
  let id = local_of(known, self.here())
  if self.entry_of(id) is Some(_) {
    return
  }
  self.remote.learn(id, station, described)
}

///|
fn WorkspaceConnects::entries(self : WorkspaceConnects) -> Array[J] {
  arr_of(at(Some((self.d.config.raw)()), "connects")).unwrap_or([])
}

///|
fn WorkspaceConnects::entry_of(self : WorkspaceConnects, id : String) -> J? {
  self.entries().iter().find_first(c => str_of(at(Some(c), "id")) == Some(id))
}

///|
/// The workspace a connect's chats are of (config.json's `workspace`; absent: the home one).
fn WorkspaceConnects::workspace_of(self : WorkspaceConnects, entry : J?) -> String? {
  match nonempty_str(at(entry, "workspace")) {
    Some(ws) => Some(ws)
    None => (self.d.home)()
  }
}

///|
fn WorkspaceConnects::in_workspace(self : WorkspaceConnects, ws : String, station : String) -> Bool {
  (self.d.stations)(ws).iter().any(p => str_of(at(Some(p), "id")) == Some(station))
}

///|
fn WorkspaceConnects::name_of(self : WorkspaceConnects, ws : String, station : String) -> String {
  match (self.d.stations)(ws).iter().find_first(p => str_of(at(Some(p), "id")) == Some(station)) {
    Some(p) =>
      match at(Some(p), "name") {
        Some(Null) | None => station
        Some(n) => js_text(Some(n))
      }
    None => station
  }
}

///|
/// A connect running here, its surface: config.json's, not one of another station's.
async fn WorkspaceConnects::own(self : WorkspaceConnects, id : String) -> Surface? {
  match (self.d.hub.chat_of)(id) {
    Some(s) if !s.remote => Some(s)
    _ => None
  }
}

///|
async fn WorkspaceConnects::described(self : WorkspaceConnects, id : String) -> J? {
  let connect = (self.d.hub.config_connects)().iter().find_first(c => str_of(at(Some(c), "id")) == Some(id))
  let chat = self.own(id)
  let ws = self.workspace_of(self.entry_of(id))
  match (connect, chat, ws) {
    (Some(c), Some(s), Some(w)) => Some(describe(c, w, s))
    _ => None
  }
}

// ── on the station a chat runs on ────────────────────────────────────────────────────────────────────────────

///|
/// An event of a connect of another station's for a chat here; or one kept on a station retired for one of its
/// connects that moved here since (`kept`), taken as this station's connect's own (`move_all`).
async fn WorkspaceConnects::taken(self : WorkspaceConnects, peer : String, request : J, workspace : String?) -> Answer {
  let r = Some(request)
  let known = known_in(at(r, "connect"))
  let event = at(r, "event").unwrap_or(undefined())
  if at(r, "kept") is Some(Bool(true)) {
    let id = match known {
      Some(k) => local_of(k, self.here())
      None => ""
    }
    let entry = self.entry_of(id)
    guard known is Some(_) && workspace is Some(ws) && entry is Some(_) && self.workspace_of(entry) == Some(ws) && self.in_workspace(ws, peer) else {
      raise fail_("no such connect")
    }
    self.receive(id, event)
    return plain(jo([("ok", jb(true))]))
  }
  let d = at(r, "described")
  guard known is Some(known) && str_of(at(d, "kind")) is Some(_) && workspace is Some(ws) && str_of(at(d, "workspace")) == Some(ws) && self.in_workspace(ws, peer) else {
    raise fail_("no such connect")
  }
  let d = d.unwrap()
  let id = local_of(known, self.here())
  if self.entry_of(id) is Some(_) {
    raise fail_("that connect runs on this station")
  }
  self.remote.learn(id, peer, d)
  // (its chat was handed from here to another station, and the connect's station not told yet, or the event already
  // on its way: it goes on there, as the connect's station would send it)
  let thread = thread_of_event(event)
  let moved = (self.d.hub.moved_to)(id, js_text(at(Some(thread), "channel")), js_text(at(Some(thread), "threadTs")))
  match moved {
    Some(m) if m != self.here() => {
      ignore((self.d.bus.ask)(m, jo([("method", js(event_method)), ("workspace", js(ws)), ("connect", known.to_j()), ("described", d), ("event", event)]), NoBody))
      return plain(jo([("ok", jb(true))]))
    }
    _ => ()
  }
  (self.d.hub.receive)(id, event)
  // Its people and channel named here as there (the pages read them from this station's names book).
  if str_of(at(Some(event), "type")) == Some("message") {
    match self.remote.surface(id) {
      Some(chat) => {
        let s = chat.surface()
        let message = at(Some(event), "message")
        ignore((s.get)("knownPerson", [at(message, "user").unwrap_or(undefined())]))
        ignore((s.get)("knownChannel", [at(message, "channel").unwrap_or(undefined())]))
      }
      None => ()
    }
  }
  plain(jo([("ok", jb(true))]))
}

// ── on the station a connect runs on ─────────────────────────────────────────────────────────────────────────

///|
async fn WorkspaceConnects::in_turn(self : WorkspaceConnects, key : String, f : async () -> Unit) -> Unit {
  let turns = match self.gates.get(key) {
    Some(t) => t
    None => {
      let t = Turns::new()
      self.gates[key] = t
      t
    }
  }
  defer {
    if turns.idle() && self.gates.get(key) is Some(t) && physical_equal(t, turns) {
      self.gates.remove(key)
    }
  }
  turns.run(f)
}

///|
fn WorkspaceConnects::moving_dir(self : WorkspaceConnects) -> String {
  self.d.fs.join([self.d.data, "replica", "connects-moving"])
}

///|
fn WorkspaceConnects::moving_file(self : WorkspaceConnects, id : String) -> String {
  self.d.fs.join([self.moving_dir(), "\{@session_chats.slice(@cloud_net.sha256_hex(id), 0, b=32)}.json"])
}

///|
/// How many names beside a file `write_beside` gave in this process.
let beside_seq : Ref[Int64] = { val: 0L }

///|
/// `text` written to `path` whole: beside it under a name no other write of this process takes (`<path>.<n>.tmp`: two
/// at once each rename their own, L13) and renamed over it; what was written beside let go of where that fails.
async fn write_beside(fs : Fs, path : String, text : String) -> Unit {
  beside_seq.val += 1L
  let tmp = "\{path}.\{beside_seq.val}.tmp"
  errdefer @effect.uninterruptible(async fn() { (fs.rm)(tmp) catch { _ => () } })
  (fs.write_text)(tmp, text)
  (fs.rename)(tmp, path)
}

///|
async fn WorkspaceConnects::keep_moving(self : WorkspaceConnects, m : J) -> Unit {
  let fs = self.d.fs
  let id = js_text(at(Some(m), "id"))
  self.moving[id] = m
  (fs.mkdir)(self.moving_dir())
  write_beside(fs, self.moving_file(id), js_stringify(m))
}

///|
async fn WorkspaceConnects::done_moving(self : WorkspaceConnects, id : String) -> Unit {
  self.moving.remove(id)
  (self.d.fs.rm)(self.moving_file(id))
}

///|
/// The moves under way (of those to `peer`, where given), settled by asking each station whether it holds the
/// connect: it does, the move ends here as it would have (this one's entry dropped, its threads its); it does not, it
/// never moved. So one of the two holds it, never both nor neither, once both are up and have heard each other.
pub async fn WorkspaceConnects::settle_moving(self : WorkspaceConnects, peer? : String? = None) -> Unit {
  self.settling.run(async fn() {
    for m in self.moving.values().to_array() {
      let id = js_text(at(Some(m), "id"))
      let to = js_text(at(Some(m), "to"))
      let ws = at(Some(m), "ws").unwrap_or(undefined())
      if (peer is Some(p) && to != p) || self.asking.contains(id) {
        continue
      }
      let holds = try {
        let got = (self.d.bus.ask)(to, jo([("method", js(holds_method)), ("workspace", ws), ("connect", known_of(id, self.here()).to_j())]) |> drop_undefined, NoBody)
        at(Some(got.json), "holds") is Some(Bool(true))
      } catch {
        e => {
          self.d.log.info("connects", "a connect's move under way not settled yet: the station it went to not heard", jo([("connect", js(id)), ("to", js(to)), ("error", js(thrown_message(e)))]))
          continue
        }
      }
      if holds && self.entry_of(id) is Some(_) {
        self.handed_off(id, to, js_text(Some(ws)), js_text(at(Some(m), "localsTo")))
      } else if holds {
        self.done_moving(id)
      } else {
        self.handing.remove(id)
        self.done_moving(id)
      }
      self.d.log.info("connects", "a connect's move under way settled", jo([("connect", js(id)), ("to", js(to)), ("there", jb(holds))]))
    }
  })
}

///|
/// A Deferred already done with `v`.
fn[X] done_with(v : X) -> @effect.Deferred[X] {
  let d = @effect.Deferred::new()
  ignore(d.succeed(v))
  d
}

///|
/// What ends a connect's move here once the other took it: its entry dropped, its threads the other's, the chats here
/// going on through it there, the other stations told; what its socket here still gives goes there (`receive`).
/// `taken`: the move's own answer, said once its entry is gone from here (what waited for it then goes there, as the
/// TypeScript's goes on to here before what waits does).
async fn WorkspaceConnects::handed_off(
  self : WorkspaceConnects,
  id : String,
  to : String,
  ws : String,
  locals_to : String,
  taken? : @effect.Deferred[String?]? = None,
) -> Unit {
  let d = self.described(id)
  let known = known_of(id, self.here())
  self.handing[id] = (done_with(Some(to)), ws)
  (self.d.config.update_soon)(raw => {
    match taken {
      Some(t) => ignore(t.succeed(Some(to)))
      None => ()
    }
    let kept = arr_of(at(Some(raw), "connects")).unwrap_or([]).filter(c => !(str_of(at(Some(c), "id")) == Some(id)))
    set_field(raw, "connects", Arr(kept))
  })
  (self.d.store.drop_connect_threads)(id)
  // The chats here go on through it there.
  match d {
    Some(described) if locals_to == self.here() => self.remote.learn(id, to, described)
    _ => ()
  }
  for p in (self.d.stations)(ws) {
    guard str_of(at(Some(p), "id")) is Some(pid) else { continue }
    if pid == self.here() || pid == to {
      continue
    }
    spawn(async fn() {
      ignore((self.d.bus.ask)(pid, jo([("method", js(moved_method)), ("workspace", js(ws)), ("connect", known.to_j()), ("station", js(to))]), NoBody))
    })
  }
  self.done_moving(id)
}

///|
async fn WorkspaceConnects::forward(self : WorkspaceConnects, station : String, id : String, ws : String, event : J) -> Unit {
  guard self.described(id) is Some(d) else { raise fail_("the connect is not connected") }
  ignore(
    (self.d.bus.ask)(
      station,
      jo([("method", js(event_method)), ("workspace", js(ws)), ("connect", known_of(id, self.here()).to_j()), ("described", d), ("event", event)]),
      NoBody,
    ),
  )
}

///|
fn WorkspaceConnects::awaiting_file(self : WorkspaceConnects, id : String) -> String {
  self.d.fs.join([self.d.data, "replica", "awaiting", "\{@session_chats.slice(@cloud_net.sha256_hex(id), 0, b=32)}.jsonl"])
}

///|
/// Connect `id` keeps what it says for chats `keys` until each is here.
async fn WorkspaceConnects::await_chats(self : WorkspaceConnects, id : String, keys : Array[String]) -> Unit {
  self.awaiting_turn.run(async fn() {
    let next : Set[String] = Set([])
    match self.awaiting.get(id) {
      Some(had) => for k in had { next.add(k) }
      None => ()
    }
    for k in keys {
      next.add(k)
    }
    self.awaiting[id] = next
    self.save_awaiting()
  })
}

///|
async fn WorkspaceConnects::keep_for(self : WorkspaceConnects, id : String, event : J) -> Unit {
  self.awaiting_turn.run(async fn() {
    if !self.awaiting.contains(id) {
      return (self.d.hub.receive)(id, event)
    }
    let fs = self.d.fs
    let file = self.awaiting_file(id)
    (fs.mkdir)(fs.dirname(file))
    (fs.append_text)(file, "\{js_stringify(event)}\n")
  })
}

///|
/// Chats `keys` are here now (replica/handover.ts as it shows them): a connect waiting for no more of its chats takes
/// what it kept, in order, as it came.
pub async fn WorkspaceConnects::arrived(self : WorkspaceConnects, keys : Array[String]) -> Unit {
  self.awaiting_turn.run(async fn() {
    let fs = self.d.fs
    for entry in self.awaiting.to_array() {
      let (id, waiting) = entry
      for k in keys {
        waiting.remove(k)
      }
      if waiting.length() > 0 {
        continue
      }
      self.awaiting.remove(id)
      self.save_awaiting()
      let file = self.awaiting_file(id)
      let text = (fs.read_text)(file) catch { _ => "" }
      let lines = text.split("\n").map(l => l.to_owned()).filter(l => l != "").collect()
      (fs.rm)(file)
      for line in lines {
        (self.d.hub.receive)(id, parse_js(line)) catch {
          e => self.d.log.warn("connects", "an event kept for a chat on its way not taken", jo([("connect", js(id)), ("error", js(thrown_message(e)))]))
        }
      }
    }
    self.save_awaiting()
  })
}

///|
async fn WorkspaceConnects::save_awaiting(self : WorkspaceConnects) -> Unit {
  let fs = self.d.fs
  let path = fs.join([self.d.data, "replica", "awaiting.json"])
  (fs.mkdir)(fs.dirname(path))
  let kept = from_entries(self.awaiting.to_array().map(e => (e.0, jsa(e.1.iter().collect()))))
  write_beside(fs, path, js_stringify(kept))
}

///|
/// This station's connects' bots of `ws` told to its other stations where they changed since they were last told (as
/// an event of one comes: its bot is known by then), never asked for.
async fn WorkspaceConnects::tell_bots(self : WorkspaceConnects, ws : String) -> Unit {
  let bots : Array[String] = []
  for c in self.entries() {
    if self.workspace_of(Some(c)) != Some(ws) {
      continue
    }
    let bot = match self.own(js_text(at(Some(c), "id"))) {
      Some(s) => s.bot_user_id()
      None => ""
    }
    if bot != "" && !bots.contains(bot) {
      bots.push(bot)
    }
  }
  bots.sort_by(@session_chats.js_compare)
  let said = js_stringify(jsa(bots))
  if self.bots_told.get(ws) == Some(said) {
    return
  }
  self.bots_told[ws] = said
  for p in (self.d.stations)(ws) {
    guard str_of(at(Some(p), "id")) is Some(pid) else { continue }
    if pid == self.here() {
      continue
    }
    spawn(async fn() {
      ignore((self.d.bus.ask)(pid, jo([("method", js(bots_method)), ("workspace", js(ws)), ("bots", jsa(bots))]), NoBody)) catch {
        _ => self.bots_told.remove(ws)
      }
    })
  }
}

///|
/// What a connect's platform says: to the station a chat of its thread runs on, or a new conversation's to the
/// station the connect starts them on; the rest to the hub here.
pub async fn WorkspaceConnects::receive(self : WorkspaceConnects, id : String, event : J) -> Unit {
  // (a connect being handed to another station, or handed: what its socket here still gives goes there, handled only
  // by the station that holds it; the hand-off failed, it is this one's still)
  match self.handing.get(id) {
    Some(handed) => {
      let to = handed.0.wait()
      // (only while it is not this station's: one of that id here again, added anew by a person, is this one's)
      match to {
        Some(station) if self.entry_of(id) is None || self.asking.contains(id) => {
          ignore(
            (self.d.bus.ask)(
              station,
              jo([("method", js(event_method)), ("workspace", js(handed.1)), ("connect", known_of(id, self.here()).to_j()), ("kept", jb(true)), ("event", event)]),
              NoBody,
            ),
          )
          return
        }
        Some(_) =>
          match self.handing.get(id) {
            Some(now) if physical_equal(now.0, handed.0) => self.handing.remove(id)
            _ => ()
          }
        None => ()
      }
    }
    None => ()
  }
  {
    let entry = self.entry_of(id)
    if entry is Some(_) {
      match self.workspace_of(entry) {
        Some(ws) => self.tell_bots(ws)
        None => ()
      }
    }
  }
  let connect = (self.d.hub.config_connects)().iter().find_first(c => str_of(at(Some(c), "id")) == Some(id))
  let entry = self.entry_of(id)
  let ws = if entry is Some(_) { self.workspace_of(entry) } else { None }
  // (a connect that is not routed whose chats are still on their way here: kept for them, in order)
  if self.awaiting.contains(id) {
    return self.keep_for(id, event)
  }
  guard connect is Some(connect) && ws is Some(ws) && routed.contains(js_text(at(Some(connect), "kind"))) else {
    return (self.d.hub.receive)(id, event)
  }
  if single_session(Some(connect)) {
    return if (self.d.hub.quiet_in)(ws) { self.hold(id, ws, event) } else { (self.d.hub.receive)(id, event) }
  }
  let thread = thread_of_event(event)
  let channel = js_text(at(Some(thread), "channel"))
  let thread_ts = js_text(at(Some(thread), "threadTs"))
  self.in_turn("\{id}\u{0}\{channel}\u{0}\{thread_ts}", async fn() {
    match (self.d.store.connect_thread_station)(id, channel, thread_ts) {
      Some(there) => {
        self.forward(there, id, ws, event) catch {
          e => {
            self.d.log.warn("connects", "an event of a chat on another station did not get there", jo([("connect", js(id)), ("station", js(there)), ("error", js(thrown_message(e)))]))
            if str_of(at(Some(event), "type")) == Some("message") {
              match self.own(id) {
                Some(s) => {
                  let words = self.d.speech.tr(self.d.speech.station_lang(), "station.connect.stationAway", args=[("station", self.name_of(ws, there))])
                  ignore((s.call)("post", [thread, js(@session_chats.mark_notice("⚠️ \{words}")), ja([])])) catch { _ => () }
                }
                None => ()
              }
            }
          }
        }
        return
      }
      None => ()
    }
    // (its chats here going to another station: kept for it)
    if (self.d.hub.quiet_in)(ws) {
      return self.hold(id, ws, event)
    }
    // A new conversation starts on the station the connect names (absent, or not of its workspace: this one).
    let want = str_of(at(entry, "station"))
    let message = at(Some(event), "message")
    let fresh = str_of(at(Some(event), "type")) == Some("message") &&
      truthy(at(message, "addressed")) &&
      (self.d.store.thread_at)((self.d.hub.surface)(id), channel, thread_ts) is Null
    guard fresh && want is Some(want) && want != self.here() && self.in_workspace(ws, want) else { return (self.d.hub.receive)(id, event) }
    try {
      self.forward(want, id, ws, event)
      (self.d.store.set_connect_thread_station)(id, channel, thread_ts, want)
      self.d.log.info("connects", "a new conversation runs on another station", jo([("connect", js(id)), ("station", js(want))]))
    } catch {
      e => {
        self.d.log.warn("connects", "the connect's station for new conversations did not take one; it runs here", jo([("connect", js(id)), ("station", js(want)), ("error", js(thrown_message(e)))]))
        (self.d.hub.receive)(id, event)
      }
    }
  })
}

// ── one connect, one station ─────────────────────────────────────────────────────────────────────────────────

///|
/// The station of workspace `ws` a connect of `kind` with this part (its tokens) runs on already, by its name: None
/// for none (or none that answered).
pub async fn WorkspaceConnects::held_by(self : WorkspaceConnects, ws : String?, kind : String, own : J?) -> String? {
  guard fingerprint(kind, own) is Some(print) && ws is Some(ws) else { return None }
  for p in (self.d.stations)(ws) {
    guard str_of(at(Some(p), "id")) is Some(pid) else { continue }
    if pid == self.here() {
      continue
    }
    let got = (self.d.bus.ask)(pid, jo([("method", js(list_method)), ("workspace", js(ws)), ("fingerprint", js(print))]), NoBody) catch { _ => continue }
    if at(Some(got.json), "has") is Some(Bool(true)) {
      return Some(self.name_of(ws, pid))
    }
  }
  None
}

///|
/// This station's connects of `ws` (config.json's).
pub fn WorkspaceConnects::own_in(self : WorkspaceConnects, ws : String) -> Array[String] {
  self.entries().filter(c => self.workspace_of(Some(c)) == Some(ws) && str_of(at(Some(c), "id")) is Some(_)).map(c => js_text(at(Some(c), "id")))
}

///|
/// `own_in`'s with their kind and mode (move/connects.ts): `{id, name, kind, mode}` each.
pub fn WorkspaceConnects::own_kinds(self : WorkspaceConnects, ws : String) -> Array[J] {
  self
  .named_in(ws)
  .map(c => {
    let mode = if single_session(self.entry_of(js_text(at(Some(c), "id")))) { "single-session" } else { "multi-session" }
    set_field(c, "mode", js(mode))
  })
}

///|
/// The connects of `ws` added on this station that run on another one now (moved there).
pub fn WorkspaceConnects::moved_away(self : WorkspaceConnects, ws : String) -> Array[J] {
  self.remote
  .connects()
  .filter(c => str_of(at(Some(c), "workspace")) == Some(ws) && !js_text(at(Some(c), "id")).contains("@"))
  .map(c => jo([
    ("id", at(Some(c), "id").unwrap_or(undefined())),
    ("name", at(Some(c), "id").unwrap_or(undefined())),
    ("kind", at(Some(c), "kind").unwrap_or(undefined())),
    ("mode", at(Some(c), "mode").unwrap_or(undefined())),
  ]) |> drop_undefined)
}

///|
/// The ids of every connect of this station's.
pub fn WorkspaceConnects::own_ids(self : WorkspaceConnects) -> Array[String] {
  self.entries().filter(c => str_of(at(Some(c), "id")) is Some(_)).map(c => js_text(at(Some(c), "id")))
}

///|
/// How connect `id` (as this station names it) goes, its own or another station's (None: not known here):
/// `{kind, mode}`.
pub fn WorkspaceConnects::kind_mode(self : WorkspaceConnects, id : String) -> J? {
  match self.entry_of(id) {
    Some(entry) =>
      return Some(jo([("kind", js(kind_of(Some(entry)))), ("mode", js(if single_session(Some(entry)) { "single-session" } else { "multi-session" }))]))
    None => ()
  }
  self.remote
  .surface(id)
  .map(r => jo([("kind", at(Some(r.described), "kind").unwrap_or(undefined())), ("mode", at(Some(r.described), "mode").unwrap_or(undefined()))]) |> drop_undefined)
}

///|
/// The station connect `id` runs on (None: this one, or not known).
pub fn WorkspaceConnects::runs_on(self : WorkspaceConnects, id : String) -> String? {
  if self.entry_of(id) is Some(_) {
    return None
  }
  self.remote.surface(id).map(r => r.station)
}

///|
/// `own_in`'s, as the app names them: each one's name (its id where it has none) and kind.
pub fn WorkspaceConnects::named_in(self : WorkspaceConnects, ws : String) -> Array[J] {
  self
  .entries()
  .filter(c => self.workspace_of(Some(c)) == Some(ws) && str_of(at(Some(c), "id")) is Some(_))
  .map(c => {
    let id = js_text(at(Some(c), "id"))
    let name = match nonempty_str(at(Some(c), "name")) {
      Some(n) => n
      None => id
    }
    jo([("id", js(id)), ("name", js(name)), ("kind", js(kind_of(Some(c))))])
  })
}

///|
/// Each connect is there before what was kept of it goes there, in order, as that station's own connect's (`kept`):
/// a chat it starts a turn in calls it there (2026-11-14: forwarded before it moved, each such turn failed, the
/// connect not yet on the station). From then on each event goes there as it comes. One that came on its new socket
/// meanwhile is in its thread's log by its ts. What did not go stays kept, and goes as this is done again.
pub async fn WorkspaceConnects::move_all(self : WorkspaceConnects, ws : String, to : String) -> Unit {
  self.held_turn.run(async fn() {
    // (those kept of a connect moved before this was cut first)
    let own = self.own_in(ws)
    let own_set : Set[String] = Set(own)
    self.send_kept(ws, to, id => !own_set.contains(id))
    for id in own_set {
      self.move_to(id, to, None, lang=Some(self.d.speech.station_lang()), locals_to=Some(to))
      self.send_kept(ws, to, c => c == id)
    }
    self.held_to[ws] = to
  })
}

///|
fn split_lines(text : String) -> Array[String] {
  text.split("\n").map(l => l.to_owned()).filter(l => l != "").collect()
}

///|
/// What was kept of `ws`'s connects that `which` names sent to `to`, where they run now, in order; the rest stays kept.
async fn WorkspaceConnects::send_kept(self : WorkspaceConnects, ws : String, to : String, which : (String) -> Bool) -> Unit {
  let lines = split_lines((self.d.fs.read_text)(self.held_file) catch { _ => "" })
  if lines.length() == 0 {
    return
  }
  let rest : Array[String] = []
  for i, line in lines {
    let e = try parse_js(line) catch { _ => continue }
    let id = str_of(at(Some(e), "id"))
    guard str_of(at(Some(e), "ws")) == Some(ws) && id is Some(id) && which(id) else {
      rest.push(line)
      continue
    }
    ignore(
      (self.d.bus.ask)(
        to,
        jo([("method", js(event_method)), ("workspace", js(ws)), ("connect", known_of(id, self.here()).to_j()), ("kept", jb(true)), ("event", at(Some(e), "event").unwrap_or(undefined()))])
        |> drop_undefined,
        NoBody,
      ),
    ) catch {
      error => {
        self.write_held([..rest, ..lines[i:]])
        raise error
      }
    }
  }
  self.write_held(rest)
}

///|
/// What was kept of `ws`'s platforms while its chats were quiet, taken here after all, in order, as it would have
/// been as it came: its chats work here again (a retirement called off, or a hand-over that failed).
pub async fn WorkspaceConnects::take_held(self : WorkspaceConnects, ws : String) -> Unit {
  let mine : Array[(String, J)] = []
  self.held_turn.run(async fn() {
    let lines = split_lines((self.d.fs.read_text)(self.held_file) catch { _ => "" })
    if lines.length() == 0 {
      return
    }
    let rest : Array[String] = []
    for line in lines {
      let e = try parse_js(line) catch { _ => continue }
      match (str_of(at(Some(e), "ws")), str_of(at(Some(e), "id"))) {
        (Some(w), Some(id)) if w == ws => mine.push((id, at(Some(e), "event").unwrap_or(undefined())))
        _ => rest.push(line)
      }
    }
    self.write_held(rest)
  })
  for m in mine {
    self.receive(m.0, m.1) catch {
      error => self.d.log.warn("connects", "an event kept while a workspace was quiet not taken", jo([("connect", js(m.0)), ("error", js(thrown_message(error)))]))
    }
  }
}

///|
/// An event of `ws`'s, whose chats here go to another station: kept, or, once its connects and what was kept went
/// there, sent there as its connect's there.
async fn WorkspaceConnects::hold(self : WorkspaceConnects, id : String, ws : String, event : J) -> Unit {
  self.held_turn.run(async fn() {
    match self.held_to.get(ws) {
      Some(to) => {
        ignore(
          (self.d.bus.ask)(
            to,
            jo([("method", js(event_method)), ("workspace", js(ws)), ("connect", known_of(id, self.here()).to_j()), ("kept", jb(true)), ("event", event)]),
            NoBody,
          ),
        )
        return
      }
      None => ()
    }
    let fs = self.d.fs
    (fs.mkdir)(fs.dirname(self.held_file))
    (fs.append_text)(self.held_file, "\{js_stringify(jo([("id", js(id)), ("ws", js(ws)), ("event", event)]) |> drop_undefined)}\n")
  })
}

///|
async fn WorkspaceConnects::write_held(self : WorkspaceConnects, lines : Array[String]) -> Unit {
  let fs = self.d.fs
  write_beside(fs, self.held_file, lines.map(l => "\{l}\n").join(""))
}

///|
/// A connect moved here: its config.json entry, and its threads' stations (none of those whose chats run here).
async fn WorkspaceConnects::take(self : WorkspaceConnects, peer : String, request : J, workspace : String?) -> Answer {
  let r = Some(request)
  let known = known_in(at(r, "connect"))
  let entry = at(r, "entry")
  guard known is Some(known) && entry is Some(Obj(_) | Arr(_) as entry) && workspace is Some(ws) && str_of(at(Some(entry), "workspace")) == Some(ws) && self.in_workspace(ws, peer) else {
    raise fail_("no such connect")
  }
  let id = local_of(known, self.here())
  if self.entry_of(id) is Some(_) {
    raise fail_("that connect runs on this station already")
  }
  // (one handed from here before, back: this station's again)
  self.handing.remove(id)
  // (one of its home workspace says none, as one added here would)
  let rest = without(entry, ["workspace"])
  let home = (self.d.home)()
  (self.d.config.update_soon)(raw => {
    let connects = arr_of(at(Some(raw), "connects")).unwrap_or([])
    let mut added = set_field(rest, "id", js(id))
    if home != Some(ws) {
      added = set_field(added, "workspace", js(ws))
    }
    set_field(raw, "connects", Arr([..connects, added]))
  })
  for t in arr_of(at(r, "threads")).unwrap_or([]) {
    match (str_of(at(Some(t), "channel")), str_of(at(Some(t), "threadTs")), str_of(at(Some(t), "station"))) {
      (Some(channel), Some(thread_ts), Some(station)) if station != self.here() =>
        (self.d.store.set_connect_thread_station)(id, channel, thread_ts, station)
      _ => ()
    }
  }
  self.remote.moved(id, self.here())
  // (its chats still on their way here: what it says meanwhile is kept for them, delivered once they are here)
  let awaiting : Array[String] = []
  for k in arr_of(at(r, "awaiting")).unwrap_or([]) {
    match str_of(Some(k)) {
      Some(s) => awaiting.push(s)
      None => ()
    }
  }
  if awaiting.length() > 0 {
    self.await_chats(id, awaiting)
  }
  self.d.log.info("connects", "a connect moved here", jo([("connect", js(id)), ("from", js(peer))]))
  plain(jo([("ok", jb(true))]))
}

///|
/// Moves a connect of this station's to `to`, another of its workspace (`viewer`'s, when a person asks): that station
/// takes its config.json entry and its threads' stations (this one's, for the chats here, which go on here), then it
/// is gone from here, and the workspace's other stations are told. `locals_to`: whose the chats here count as there
/// (this station's, or, as it is retired, the one they went to). `awaiting`: the chats of it (a connect that is not
/// routed) still here, to come there after it: what its platform says meanwhile is kept there for them (`arrived`).
/// Refused as `Thrown("Refused:<status>", words)`.
pub async fn WorkspaceConnects::move_to(
  self : WorkspaceConnects,
  id : String,
  to : String,
  viewer : String?,
  lang? : String? = None,
  locals_to? : String? = None,
  awaiting? : Array[String] = [],
) -> Unit {
  let lang = lang.unwrap_or(self.d.speech.station_lang())
  let locals_to = locals_to.unwrap_or(self.here())
  let entry = self.entry_of(id)
  let ws = if entry is Some(_) { self.workspace_of(entry) } else { None }
  guard entry is Some(entry) && ws is Some(ws) else { raise @session_chats.Thrown("Refused:404", "unknown connect \{id}") }
  match (viewer, (self.d.home)()) {
    (Some(v), Some(_)) if ws != v => raise @session_chats.Thrown("Refused:404", "unknown connect \{id}")
    _ => ()
  }
  if to == self.here() || !self.in_workspace(ws, to) {
    raise @session_chats.Thrown("Refused:400", self.d.speech.tr(lang, "station.connect.moveWhere"))
  }
  let known = known_of(id, self.here())
  // (a thread routed elsewhere already, a chat of it handed from here to another station, goes on there)
  let routed_threads = (self.d.store.connect_threads)(id)
  let seen : Set[String] = Set(routed_threads.map(t => "\{js_text(at(Some(t), "channel"))}\u{0}\{js_text(at(Some(t), "threadTs"))}"))
  let locals = (self.d.store.connect_local_threads)(id)
    .filter(t => !seen.contains("\{js_text(at(Some(t), "channel"))}\u{0}\{js_text(at(Some(t), "threadTs"))}"))
    .map(t => set_field(t, "station", js(locals_to)))
  let threads = [..routed_threads, ..locals].filter(t => !(str_of(at(Some(t), "station")) == Some(to)))
  // (kept before it is asked: a stop from here on is settled by asking it, as this station starts; settled by its
  // answer meanwhile, not by a settling that asks it first)
  self.asking.add(id)
  let taken : @effect.Deferred[String?] = @effect.Deferred::new()
  self.handing[id] = (taken, ws)
  try {
    self.keep_moving(jo([("id", js(id)), ("to", js(to)), ("ws", js(ws)), ("localsTo", js(locals_to))]))
    let request = [
      ("method", js(take_method)),
      ("workspace", js(ws)),
      ("connect", known.to_j()),
      ("entry", set_field(entry, "workspace", js(ws))),
      ("threads", ja(threads)),
    ]
    if awaiting.length() > 0 {
      request.push(("awaiting", jsa(awaiting)))
    }
    ignore((self.d.bus.ask)(to, jo(request), NoBody))
  } catch {
    e => {
      self.handing.remove(id)
      self.asking.remove(id)
      ignore(taken.succeed(None))
      // (refused there: it did not take it; no answer: it may have, asked as it is heard from, the record kept)
      if thrown_kind(e) == "Declined" {
        self.done_moving(id)
      } else {
        spawn(async fn() { self.settle_moving(peer=Some(to)) })
      }
      raise e
    }
  }
  self.asking.remove(id)
  self.handed_off(id, to, ws, locals_to, taken=Some(taken))
  ignore(taken.succeed(Some(to)))
  self.d.log.info("connects", "connect moved to another station", jo([("connect", js(id)), ("to", js(to))]))
}

///|
/// A request's path segment as the pages send it (api/request.ts `segment`: a + is a +, then `percentDecode`).
pub fn segment(s : String) -> String {
  request_percent_decode(@session_chats.replace_all(s, "+", "%2B"))
}

///|
/// api/request.ts `percentDecode`: `%xx` a byte, `+` a space, the rest as it is; then UTF-8, lossily.
pub fn request_percent_decode(s : String) -> String {
  let bytes = utf8(s)
  let out = Buffer()
  let mut i = 0
  while i < bytes.length() {
    let b = bytes[i]
    if b == b'%' && i + 2 < bytes.length() {
      match (hex_digit(Int::unsafe_to_char(bytes[i + 1].to_int())), hex_digit(Int::unsafe_to_char(bytes[i + 2].to_int()))) {
        (Some(x), Some(y)) => {
          out.write_byte((x * 16 + y).to_byte())
          i += 3
          continue
        }
        _ => ()
      }
    }
    out.write_byte(if b == b'+' { b' ' } else { b })
    i += 1
  }
  let text = text_of(out.to_bytes())
  if text.has_prefix("\u{FEFF}") {
    @session_chats.slice(text, 1)
  } else {
    text
  }
}

///|
/// `POST /connects/:id/move` (the admin page's): the connect moved to the station the body names, answered the
/// overview as it is then (`overview`); a refusal answered its status and words, anything else 500. Its status and
/// body.
pub async fn WorkspaceConnects::move_route(
  self : WorkspaceConnects,
  path : String,
  at_ : String,
  body : String,
  viewer_workspace : String?,
  viewer_email : J,
  lang : String,
  overview : async () -> J,
) -> (Int, J) {
  try {
    let input = request_input(body)
    let to = match at(Some(input), "station") {
      Some(Str(u)) if u.length() > 0 => @jsjson.text(u)
      _ => raise @session_chats.Thrown("Refused:400", self.d.speech.tr(lang, "station.connect.moveWhere"))
    }
    let id = segment(at_)
    self.move_to(id, to, viewer_workspace, lang=Some(lang))
    self.d.log.info("admin", "connect moved from the admin page", jo([("connect", js(id)), ("to", js(to)), ("by", viewer_email)]) |> drop_undefined)
    (200, overview())
  } catch {
    e => {
      let kind = thrown_kind(e)
      if kind.has_prefix("Refused:") {
        let status = digits_of(@session_chats.slice(kind, 8)).unwrap_or(500)
        return (status, jo([("error", js(thrown_message(e)))]))
      }
      self.d.log.error("admin", "admin request failed", jo([("path", js(path)), ("error", js(thrown_message(e)))]))
      (500, jo([("error", js(thrown_message(e)))]))
    }
  }
}

///|
/// A request's JSON object (api/request.ts `input`): nothing is `{}`, as is anything not an object; more than a
/// megabyte refused.
pub fn request_input(body : String) -> J raise Thrown {
  if utf8(body).length() > 1000000 {
    raise @session_chats.Thrown("Refused:413", "request too large")
  }
  if body == "" {
    return jo([])
  }
  let v = try parse_js(body) catch { _ => raise @session_chats.Thrown("Refused:400", "invalid JSON") }
  match v {
    Obj(_) => v
    _ => jo([])
  }
}

///|
/// A whole number written in decimal digits.
fn digits_of(s : String) -> Int? {
  if s == "" {
    return None
  }
  let mut n = 0
  for c in s {
    if c < '0' || c > '9' {
      return None
    }
    n = n * 10 + (c.to_int() - '0'.to_int())
  }
  Some(n)
}
