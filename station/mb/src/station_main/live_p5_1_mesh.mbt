// P5-1's mesh (mesh/mesh.ts MeshLive, services.ts Peers, MeshSide): once the station is in a workspace, its iroh
// endpoint, kept by the launcher's front where it runs one (`STILLFAIL_MESH_FRONT`: mesh_runtime's `FrontEndpoint`),
// else bound here through the shell (`iroh.*`, its fixed address waiting for the process before); its relays kept;
// its presence at the control plane once a relay reaches it (15 s at most); the members' connections let in by their
// credentials and the locks (mesh_door's gate on a keeper of cloud_lock's), each request the admin API's, a part's
// stream, or the device tools'; the other stations of its workspaces asked and answered (the bus's `peer_call` and
// `dispatch_peer`), their web services reached for the agents' door (`/peer/…`); the locks, ways and marks kept level
// with them and told to the devices. A failed start is tried again after a backoff, the next one bound anew.

///|
/// What the station needs of its endpoint, the front's or its own.
priv struct Endpoint {
  id : String
  kind : String
  sockets : () -> Array[String]
  accept : async () -> @door.Connection?
  connect : async (Json, Bytes, @effect.Deferred[Unit]?) -> @door.Connection
  online : async () -> Unit
  home : () -> String?
  insert_relay : async (String) -> Unit
  remove_relay : async (String) -> Unit
  keep : (Array[String]) -> Unit
  public_relays : async (Bool) -> Unit
  set_congestion : (String) -> Unit
  disabled_relays : async (String, Array[String], Bool) -> Unit
  linked : () -> Bool
  /// Whether a relay holds it inactive for another endpoint of its id (native.ts `relaysConflict`: another station on
  /// this station's key; health.json's `relayConflict`).
  relay_conflict : () -> Bool
  /// Its home relays as it has them now (endpoint.ts `relayStatus`).
  relay_status : () -> Json
  /// Whether it is reached through a relay now, end to end (endpoint.ts `probeRelay`).
  probe_relay : async (String) -> Json
  close : async () -> Unit
  /// Its mesh scopes, where its endpoint keeps them (the front's: endpoint.ts `meshConfigure` and the rest).
  mesh : MeshOps?
}

///|
priv struct MeshOps {
  scopes : @mesh_scopes.MeshEndpoint
  attach_leaf : async (Int?, Json) -> Json
  detach_leaf : async (Json) -> Unit
}

///|
priv struct MeshLive {
  mut endpoint : Endpoint?
  mut call : @gate.StationCall?
  mut http : @gate.PeerHttp?
  peers : @gate.PeerBus
  mut keeper : @gate.Keeper?
  /// The workspaces' mesh directory (mesh/scope-sync.ts), where the endpoint keeps scopes.
  mut scopes : @mesh_scopes.ScopeSync?
}

///|
/// A connection's protocol as the gate names it: the shell says it in hex.
fn alpn_text(s : String) -> String {
  if s.length() == 0 || s.length() % 2 != 0 || s.contains("/") {
    return s
  }
  let b = @cloud_lock.hex_bytes(s)
  if b.length() * 2 != s.length() {
    return s
  }
  @utf8.decode_lossy(b)
}

///|
fn with_alpn(c : @door.Connection) -> @door.Connection {
  let a = alpn_text((c.alpn)())
  { ..c, alpn: () => a }
}

// ── the endpoint bound here, through the shell ──

///|
/// A stream of a connection at the shell.
fn shell_stream(host : @host.Host, id : Json) -> @door.Stream {
  {
    read: async fn() -> Bytes? {
      let (said, bytes) = host.shell("istream.read", { "id": id })
      if said is { "end": True, .. } {
        None
      } else {
        Some(bytes.unwrap_or(b""))
      }
    },
    write: async fn(b) { ignore(host.shell("istream.write", { "id": id }, bytes=b)) },
    finish: async fn() { ignore(host.shell("istream.finish", { "id": id })) },
    stopped: async fn() -> Int? {
      match host.shell("istream.stopped", { "id": id }).0 {
        Number(n, ..) => Some(n.to_int())
        { "code": Number(n, ..), .. } => Some(n.to_int())
        _ => None
      }
    },
    reset: async fn(code) { ignore(host.shell("istream.reset", { "id": id, "code": Json::number(code.to_double()) })) },
    media_datagrams: Some(async fn(token) {
      host.shell("istream.mediaDatagrams", { "id": id, "token": Json::number(token) }).0 is True
    }),
  }
}

///|
/// A connection at the shell (`conn.*`), let go there once it is closed and its end told.
fn shell_connection(host : @host.Host, id : Json) -> @door.Connection {
  let sync = (op : String) => host.shell_sync(op, { "id": id }) catch { _ => Json::null() }
  let remote = as_text(sync("conn.remoteId")).unwrap_or("")
  let alpn = alpn_text(as_text(sync("conn.alpn")).unwrap_or(""))
  let closed_info : Ref[Json?] = Ref(None)
  let ended : @effect.Deferred[String] = @effect.Deferred::new()
  fork_bg(host, "conn closed", async fn() {
    let info = host.shell("conn.closed", { "id": id }).0 catch {
      e => { "kind": "other", "reason": Json::string("\{e}") }
    }
    if closed_info.val is None {
      closed_info.val = Some(info)
    }
    ignore(host.shell("conn.close", { "id": id, "code": 0, "reason": "", "forget": true })) catch {
      _ => ()
    }
    let words = match info {
      { "reason": String(r), .. } if r != "" => r
      _ => "closed"
    }
    ignore(ended.succeed(words))
  })
  let conn : @door.Connection = {
    remote_id: () => remote,
    alpn: () => alpn,
    via: () => as_text(sync("conn.via")),
    paths: Some(() => match sync("conn.paths") {
      Array(ps) =>
        ps.map(p => {
          let num = (k : String) => match p {
            Object(m) =>
              opt_num(m.get(k))
            _ => None
          }
          let text = (k : String) => match p {
            Object(m) =>
              opt_str(m.get(k))
            _ => None
          }
          {
            selected: p is { "selected": True, .. },
            relay: text("relay"),
            ip: text("ip"),
            rtt_ms: num("rttMs"),
            tx_packets: num("txPackets").unwrap_or(0.0),
            lost_packets: num("lostPackets").unwrap_or(0.0),
          }
        })
      _ => []
    }),
    accept_bi: async fn() -> @door.Stream? {
      match (try { Ok(host.shell("conn.acceptBi", { "id": id }).0) } catch { e => Err(e) }) {
        Ok({ "id": sid, .. }) => Some(remember_shell_stream(shell_stream(host, sid), sid))
        _ => None
      }
    },
    open_bi: async fn() -> @door.Stream {
      match host.shell("conn.openBi", { "id": id }).0 {
        { "id": sid, .. } => remember_shell_stream(shell_stream(host, sid), sid)
        _ => raise BusError("the connection is closed")
      }
    },
    answers: Some(async fn(within) {
      host.shell("conn.answers", { "id": id, "within": Json::number(within.to_double()) }).0 is True
    }),
    stats: Some(() => match sync("conn.stats") {
      Object(m) => {
        let out : Map[String, Double] = {}
        for k, v in m {
          if v is Number(n, ..) {
            out[k] = n
          }
        }
        out
      }
      _ => {}
    }),
    close: (code, reason) => {
      if closed_info.val is None {
        closed_info.val = Some({ "kind": "local", "reason": "" })
      }
      ignore(
        host.rt.fork_quiet(name="conn close", async fn() {
          ignore(host.shell("conn.close", { "id": id, "code": Json::number(code.to_double()), "reason": Json::string(reason) })) catch {
            _ => ()
          }
        }),
      )
    },
    is_closed: () => closed_info.val is Some(_),
    closed: async fn() -> String { ended.wait() },
    close_reason: Some(() => match closed_info.val {
      Some(c) =>
        Some(
          (
            match c {
              { "kind": String(k), .. } => k
              _ => ""
            },
            match c {
              { "reason": String(r), .. } => r
              _ => ""
            },
          ),
        )
      None => None
    }),
    handed: None,
  }
  remember_shell_conn(conn, id)
}

///|
/// The station's endpoint bound by the shell itself (mesh/endpoint.ts as the addon gives it).
async fn shell_endpoint(host : @host.Host, options : Json, key : Bytes) -> Endpoint {
  let (bound, _) = host.shell("iroh.bind", options, bytes=key)
  guard bound is { "id": eid, .. } else { raise BusError("the shell bound no endpoint") }
  let id = match host.shell_sync("iroh.endpointId", { "id": eid }) {
    String(s) => s
    _ => ""
  }
  let relays : Ref[Json] = Ref(Json::array([]))
  let op = async fn(name : String, args : Array[(String, Json)]) -> Json {
    let m : Map[String, Json] = { "id": eid }
    for a in args {
      m[a.0] = a.1
    }
    host.shell("iroh." + name, Json::object(m)).0
  }
  {
    id,
    kind: "direct",
    sockets: () => {
      let said = try { host.shell_sync("iroh.sockets", { "id": eid }) } catch { _ => Json::null() }
      match said {
        Array(s) => s.filter_map(x => match x { String(t) => Some(t); _ => None })
        _ => []
      }
    },
    accept: async fn() -> @door.Connection? {
      match (try { Ok(host.shell("iroh.accept", { "id": eid }).0) } catch { e => Err(e) }) {
        Ok({ "id": cid, .. }) => Some(shell_connection(host, cid))
        _ => None
      }
    },
    connect: async fn(addr, alpn, given_up) {
      let call = Ref(0L)
      // (the dial called off once it is given up; its watch let go as the dial ends either way, not kept for good)
      let watch = match given_up {
        Some(g) =>
          Some(
            host.rt.fork_quiet(name="dial given up", async fn() {
              g.wait()
              if call.val != 0L {
                ignore(host.shell_sync("fetch.cancel", { "id": Json::number(call.val.to_double()) })) catch {
                  _ => ()
                }
              }
            }),
          )
        None => None
      }
      defer {
        if watch is Some(w) {
          w.interrupt()
        }
      }
      let (made, _) = host.shell("iroh.connect", { "id": eid, "addr": addr }, bytes=alpn, called=c => call.val = c)
      guard made is { "id": cid, .. } else { raise BusError("no connection") }
      shell_connection(host, cid)
    },
    online: async fn() { ignore(op("online", [])) },
    home: () => {
      relays.val = try { host.shell_sync("iroh.relayStatus", { "id": eid }) } catch { _ => relays.val }
      match relays.val {
        Array([{ "url": String(u), .. }, ..]) => Some(u)
        _ => None
      }
    },
    insert_relay: async fn(url) { ignore(op("insertRelay", [("url", Json::string(url))])) },
    remove_relay: async fn(url) { ignore(op("removeRelay", [("url", Json::string(url))])) },
    keep: urls => ignore(
      host.rt.fork_quiet(name="keep relays", async fn() {
        ignore(op("keep", [("urls", Json::array(urls.map(u => Json::string(u))))])) catch {
          _ => ()
        }
      }),
    ),
    public_relays: async fn(on) { ignore(op("publicRelays", [("on", Json::boolean(on))])) },
    set_congestion: c => ignore(
      host.rt.fork_quiet(name="congestion", async fn() {
        ignore(op("setCongestion", [("congestion", Json::string(c))])) catch {
          _ => ()
        }
      }),
    ),
    disabled_relays: async fn(peer, urls, no_public) {
      ignore(op("disabledRelays", [("peer", Json::string(peer)), ("relays", Json::array(urls.map(u => Json::string(u)))), ("public", Json::boolean(no_public))]))
    },
    linked: () => true,
    relay_conflict: () => {
      relays.val = try { host.shell_sync("iroh.relayStatus", { "id": eid }) } catch { _ => relays.val }
      relays_conflict(relays.val)
    },
    relay_status: () => {
      relays.val = try { host.shell_sync("iroh.relayStatus", { "id": eid }) } catch { _ => relays.val }
      relays.val
    },
    probe_relay: async fn(url) { op("probeRelay", [("url", Json::string(url))]) },
    close: async fn() {
      ignore(@effect.timeout(1000, async fn() { ignore(host.shell("iroh.close", { "id": eid, "forget": true })) })) catch {
        _ => ()
      }
    },
    mesh: None,
  }
}

///|
/// Whether a relay's status says it holds the endpoint inactive for another of its id (native.ts `relaysConflict`).
fn relays_conflict(status : Json) -> Bool {
  match status {
    Array(rs) => rs.iter().any(r => r is { "conflict": True, .. })
    _ => false
  }
}

///|
/// The endpoint kept by the launcher's front, for this process in turn.
async fn front_endpoint(host : @host.Host, socket : String, bind : Map[String, Json]) -> Endpoint {
  let e = @mesh_runtime.FrontEndpoint::bind(
    @mesh_runtime.shell_sockets(host),
    socket,
    @host.pid(),
    bind,
    host.rt,
    async fn(ms) { @effect.sleep(ms) }, // timer: a retry after a failure (the front's link made again)
    (level, at, words, with_) => p51_log(level.to_upper(), at, words, fields=with_),
  )
  {
    id: e.id(),
    kind: "front",
    sockets: () => e.sockets(),
    accept: async fn() { e.accept() },
    connect: async fn(addr, alpn, given_up) { e.connect(addr, alpn, given_up~) },
    online: async fn() { e.online() },
    home: () => e.home(),
    insert_relay: async fn(u) { e.insert_relay(u) },
    remove_relay: async fn(u) { e.remove_relay(u) },
    keep: urls => e.keep(urls),
    public_relays: async fn(on) { e.public_relays(on) },
    set_congestion: c => e.set_congestion(c),
    disabled_relays: async fn(peer, urls, no_public) { e.disabled_relays(peer, urls, no_public) },
    linked: () => e.linked(),
    relay_conflict: () => relays_conflict(e.relay_status()),
    relay_status: () => e.relay_status(),
    probe_relay: async fn(url) { e.probe_relay(url) },
    close: async fn() { e.close() },
    mesh: Some({
      scopes: {
        configure: async fn(config) { e.mesh_configure(config) },
        remove: async fn(scope) { e.mesh_remove(scope) },
        listen: f => e.mesh_listen(f),
      },
      attach_leaf: async fn(handed, value) { e.mesh_attach_leaf(handed, value) },
      detach_leaf: async fn(value) { e.mesh_detach_leaf(value) },
    }),
  }
}

// ── the keeper: what the gate asks of the locks, cloud_lock's ──

///|
priv struct KeeperParts {
  cloud : @cloud_lock.Cloud
  crypto : @cloud_lock.Crypto
  plane : Plane
  builds : @cloud_lock.DeviceBuilds
  /// The lock states shown the gate, by their number (`ref`), for the rules to be given back.
  states : Array[@lock.LockState]
  /// The other stations, asked through the mesh once it is up (`pinMoved`'s logs and bodies).
  call : Ref[@gate.StationCall?]
}

///|
fn KeeperParts::view(self : KeeperParts, s : @lock.LockState?) -> Json {
  guard s is Some(st) else { return Json::null() }
  self.states.push(st)
  // (the gate holds a state while it admits one connection: the oldest let go past many)
  while self.states.length() > 4096 {
    ignore(self.states.remove(0))
  }
  let out = match lock_state_json(st) {
    Object(m) => m.copy()
    _ => {}
  }
  out["ref"] = Json::number((self.states.length() - 1).to_double())
  if st.moved is None {
    out.remove("moved")
  }
  Json::object(out)
}

///|
fn KeeperParts::state_of(self : KeeperParts, ref_ : Json) -> @lock.LockState raise {
  match ref_ {
    Number(n, ..) if n.to_int() >= 0 && n.to_int() < self.states.length() => self.states[n.to_int()]
    _ => raise BusError("no lock state \{ref_.stringify()}")
  }
}

///|
fn KeeperParts::locked_view(self : KeeperParts, l : @cloud_lock.Locked?) -> Json {
  match l {
    None => Json::null()
    Some(x) => { "state": self.view(x.state), "waiting": Json::boolean(x.waiting) }
  }
}

///|
fn who_of(w : Json) -> @cloud_lock.Who {
  let t = (k : String) => match w {
    Object(m) =>
      opt_str(m.get(k))
    _ => None
  }
  { sub: t("sub").unwrap_or(""), endpoint: t("endpoint").unwrap_or(""), base: t("base"), proof: t("proof") }
}

///|
fn chains_json(cs : Array[(String, Array[Json])]) -> Json {
  Json::array(cs.map(c => { "genesis": Json::string(c.0), "entries": Json::array(c.1) }))
}

///|
/// One of the gate's asks (mesh_door/gate/asking.mbt names them), answered by cloud_lock as the station keeps its
/// locks; a refusal of the lock's raised as the gate's.
async fn KeeperParts::ask(self : KeeperParts, name : String, a : Json) -> Json {
  let cloud = self.cloud
  let arg = (k : String) => match a {
    Object(m) => m.get(k).unwrap_or(Json::null())
    _ => Json::null()
  }
  let text = (k : String) => as_text(arg(k))
  let arr = (k : String) => jitems(arg(k))
  let ws = text("ws")
  let state_text = (k : String) => match cloud.state {
    Some(s) => s.text(k)
    None => ""
  }
  let chains = cloud.person_chains()
  try {
    match name {
      "home" =>
        jopt(cloud.home())
      "removed" => Json::boolean(cloud.removed())
      "station" => Json::string(state_text("station"))
      "name" => Json::string(state_text("name"))
      "membership" | "memberOf" => cloud.membership(ws.unwrap_or("")).unwrap_or(Json::null())
      "memberships" | "membersAll" => Json::array(cloud.memberships())
      "grantKeys" => cloud.grant_keys(ws~).unwrap_or(Json::null())
      "stateGrantKeys" =>
        match cloud.state {
          Some(s) => s.get("grant_keys").unwrap_or(Json::null())
          None => Json::null()
        }
      "joinedRevocations" => {
        let joined = match cloud.state {
          Some(s) => s.joined()
          None => []
        }
        match joined.iter().find_first(j => j is { "workspace": String(w), .. } && Some(w) == ws) {
          Some({ "revocations": Array(r), .. }) => Json::array(r)
          _ => Json::array([])
        }
      }
      "accepted" => {
        let c = self.plane.control.credential()
        {
          "issuers": Json::array(c.issuers.map(x => Json::string(x))),
          "types": Json::array(c.types.map(x => Json::string(x))),
        }
      }
      "leftOut" =>
        jopt(cloud.left_out(ws.unwrap_or("")))
      "chain" =>
        match cloud.chain(ws~) {
          Some(c) => { "state": self.view(c.state) }
          None => Json::null()
        }
      "locked" => self.locked_view(cloud.locked(ws~))
      "list" => self.locked_view(cloud.list(ws))
      "rootOut" => Json::boolean(cloud.root_out(ws))
      "needs" => Json::number(cloud.needs(ws).length().to_double())
      "takeLock" => Json::number(cloud.take_lock(arr("entries"), ws~).to_double())
      "keepLock" => {
        let t = cloud.keep_lock(arr("entries"), ws~, fork=arg("keep") is True)
        {
          "taken": Json::number(t.taken.to_double()),
          "off": Json::array(t.off.map(o => o.to_json())),
          "refusal": jopt(t.refusal),
        }
      }
      "lockAfter" =>
        Json::array(
          cloud.lock_after(
            as_num(arg("seq")).unwrap_or(-1.0),
            ws~,
          ),
        )
      "takeBodies" => {
        let (taken, refused) = cloud.take_bodies(ws, arr("bodies"))
        { "taken": Json::number(taken.to_double()), "refused": Json::array(refused.map(r => r.to_json())) }
      }
      "bodies" => Json::array(cloud.bodies(ws).all().to_array().map(kv => Json::array([Json::string(kv.0), kv.1])))
      "lacking" => Json::array(cloud.lacking(ws).map(x => Json::string(x)))
      "logsOf" => Json::array(cloud.logs_of(ws).map(x => Json::string(x)))
      "givenTo" =>
        match cloud.given_to(ws, text("key").unwrap_or("")) {
          All => Json::string("all")
          Only(hs) => Json::array(hs.map(x => Json::string(x)))
        }
      "pinBrought" => {
        @cloud_lock.pin_brought(
          cloud,
          ws,
          text("workspace").unwrap_or(""),
          arr("entries"),
          Some(arg("logs")),
          Some(arg("bodies")),
          who_of(arg("who")),
          text("station").unwrap_or(""),
        )
        Json::null()
      }
      "personOf" => chains_json(chains.of(text("sub").unwrap_or("")))
      "personKept" =>
        match chains.kept(text("genesis").unwrap_or("")) {
          Some(k) => Json::array(k)
          None => Json::null()
        }
      "personChosen" => Json::array(chains.chosen(text("pin").unwrap_or(""), text("sub").unwrap_or(""), arr("raw")))
      "personKeep" => {
        chains.keep(text("pin").unwrap_or(""), arr("chain"), ws=text("ws"))
        Json::null()
      }
      "personTake" => {
        let t = chains.take(text("genesis").unwrap_or(""), text("whose").unwrap_or(""), arr("chain"), ws~, fork=arg("fork") is True)
        {
          "taken": Json::number(t.taken.to_double()),
          "chain": Json::array(t.chain),
          "on": Json::boolean(t.on),
          "off": Json::array(t.off.map(o => o.to_json())),
        }
      }
      "personEvery" => chains_json(chains.every())
      "personsWritten" => Json::null()
      "admit" => {
        let (device, role) = @cloud_lock.admit(
          self.crypto,
          self.state_of(arg("state")),
          who_of(arg("who")),
          match arg("now") {
            Number(n, ..) => n
            _ => wall_ms().to_double() / 1000.0
          },
        )
        {
          "device": {
            "id": Json::string(device.id),
            "sub": Json::string(device.sub),
            "kind": Json::string(device.kind),
            "by": jopt(device.by),
            "sign_key": jopt(device.sign_key),
          },
          "role": Json::string(role),
        }
      }
      "admitPerson" => {
        let (device, role, _) = @cloud_lock.admit_person(self.crypto, self.state_of(arg("state")), who_of(arg("who")), arr("entries"))
        { "device": Json::string(device), "role": Json::string(role) }
      }
      "personFold" => {
        let p = @cloud_lock.person_fold(self.crypto, arr("entries"), text("sub").unwrap_or(@cloud_lock.sub_of(arr("entries")).unwrap_or("")))
        @cloud_lock.person_json(p)
      }
      "fold" =>
        self.view(
          Some(
            @cloud_lock.fold(
              self.crypto,
              arr("entries"),
              as_num(arg("now")),
            ),
          ),
        )
      "endpointProof" =>
        Json::boolean(
          self.crypto.endpoint_ok(text("ws").unwrap_or(""), text("base").unwrap_or(""), text("endpoint").unwrap_or(""), text("proof").unwrap_or("")),
        )
      "asEntry" => @cloud_lock.as_entry(arg("v")).unwrap_or(Json::null())
      "hashOf" => Json::string(@cloud_lock.hash_of(arg("e")))
      "checkChain" => {
        let chain = arr("chain")
        let whose = match @cloud_lock.sub_of(chain) {
          Some(w) => w
          None => raise @gate.LockRefusal("a lock of another person's")
        }
        match text("sub") {
          Some(s) if s != whose => raise @gate.LockRefusal("a lock of another person's")
          _ => ()
        }
        let genesis = @cloud_lock.person_fold(self.crypto, chain, whose)
        let g = match @cloud_lock.person_json(genesis) {
          { "genesis": String(g), .. } => g
          _ => ""
        }
        { "genesis": Json::string(g), "chain": Json::array(chains.newest(g, whose, chain)) }
      }
      "buildsSaw" => {
        self.builds.saw(
          text("id").unwrap_or(""),
          match arg("build") {
            Number(n, ..) => Some(n.to_int())
            _ => None
          },
          match arg("now") {
            Number(n, ..) => n
            _ => wall_ms().to_double() / 1000.0
          },
        )
        Json::null()
      }
      "buildsOf" => self.builds.of(arr("ids").filter_map(x => match x { String(s) => Some(s); _ => None }))
      "waysView" => self.plane.ways.view(ws.unwrap_or("")).to_json()
      "waysSetRelays" =>
        @cloud_net.set_relays(self.plane.ways, ws.unwrap_or(""), arr("relays"), text("by")).to_json() catch {
          @cloud_net.WaysRefusal(m) => raise @gate.WaysRefusal(m)
        }
      "waysSetWay" =>
        @cloud_net.set_way(self.plane.ways, ws.unwrap_or(""), text("way").unwrap_or(""), arg("on") is True).to_json() catch {
          @cloud_net.WaysRefusal(m) => raise @gate.WaysRefusal(m)
        }
      "marksOf" => @cloud_net.marks_json(self.plane.marks.of(ws.unwrap_or("")))
      "marksChange" => {
        let change = arg("change")
        let was = arg("was")
        let t = (k : String) => match was {
          Object(m) =>
            opt_str(m.get(k)).unwrap_or("")
          _ => ""
        }
        let field_of = (k : String) => match change {
          Object(m) => m.get(k)
          _ => None
        }
        self.plane.marks
        .change(name?=field_of("name").map(Some(_)), emoji?=field_of("emoji").map(Some(_)), icon?=field_of("icon").map(Some(_)), (t("name"), t("emoji"), t("icon")))
        .to_json() catch {
          @cloud_net.MarkRefusal(m) => raise @gate.MarkRefusal(m)
        }
      }
      "lockKept" => Json::array(cloud.lock_kept(ws~))
      "lockOff" =>
        match cloud.lock_off(ws~) {
          Some(k) => { "entries": Json::array(k.entries), "aside": Json::array(k.aside) }
          None => Json::null()
        }
      "personHeardIn" => chains_json(chains.heard_in(ws.unwrap_or("")))
      "personAll" => Json::array(chains.all(text("genesis").unwrap_or("")))
      "personAsideOf" => Json::number(chains.aside_of(text("genesis").unwrap_or("")).to_double())
      "forceWord" => Json::string(cloud.force_word(ws))
      "peersCurrent" => Json::boolean(self.plane.state.peers_current)
      "hasState" => Json::boolean(cloud.state is Some(_))
      "isRig" =>
        Json::boolean(
          match cloud.state {
            Some(s) => s.get("rig") is Some(_)
            None => false
          },
        )
      "joined" =>
        Json::array(
          match cloud.state {
            Some(s) => s.joined()
            None => []
          },
        )
      "unprotected" => Json::array(cloud.unprotected(ws~))
      "rigOf" =>
        match cloud.rig_of(text("id").unwrap_or(""), workspace=ws) {
          Some((w, r)) => { "workspace": Json::string(w), "rig": r }
          None => Json::null()
        }
      "rigs" => Json::array(cloud.rigs(ws.unwrap_or("")))
      "rigsNamed" => Json::array(cloud.rigs_named(ws.unwrap_or("")))
      "rigVouched" => Json::boolean((cloud.rig_vouched)(ws.unwrap_or(""), arg("rig")))
      "movedOffered" => Json::boolean(cloud.moved_offered.contains(ws.unwrap_or("")))
      "waiting" => Json::boolean(cloud.waiting(ws~))
      "answerWays" => @cloud_net.answer_ways(self.plane.ways, arg("request"), ws.unwrap_or(""))
      "answerMarks" => @cloud_net.answer_marks(self.plane.marks, arg("request"), ws.unwrap_or(""))
      "pinMoved" => {
        // (a joined workspace whose chain moved, pinned once a station of it gives what its state is made of)
        guard self.call.val is Some(call) else { return Json::boolean(false) }
        let ask = async fn(peer : String, ws : String, request : Json) -> Json raise {
          (call.call)(peer, Some(ws), request, None).0
        }
        Json::boolean(
          @cloud_lock.pin_moved(
            cloud,
            ask,
            ws.unwrap_or(""),
            arr("peers").filter_map(x => match x { String(s) => Some(s); _ => None }),
            text("me").unwrap_or(state_text("station")),
          ),
        )
      }
      _ => raise BusError("no keeper part \{name}")
    }
  } catch {
    @cloud_lock.Refused(m) => raise @gate.LockRefusal(m)
    e => raise e
  }
}

// ── put together ──

///|
/// mesh/mesh.ts MeshLive, wired on the bus; `mesh_start` forks its accept loop once the other slices are up.
fn P51::mesh_live(self : P51) -> MeshLive {
  let bus = self.bus
  let peers = @gate.PeerBus::new()
  // Inbound: what the station's parts answer, by method (the bus's handlers).
  peers.otherwise(async fn(peer, request, body, workspace) {
    let meth = match request {
      { "method": String(m), .. } => m
      _ => ""
    }
    let bytes = match body {
      Some(b) => Some(body_bytes(b))
      None => None
    }
    let (answer, out) = bus.dispatch_peer(peer, if workspace == "" { None } else { Some(workspace) }, meth, request, bytes)
    (answer, out.map(bytes_body))
  })
  // (peer.ts `heard`: another station heard from, told the parts that follow it: the moves)
  peers.heard(peer => bus.notify_peer_heard(peer))
  let m : MeshLive = { endpoint: None, call: None, http: None, peers, keeper: None, scopes: None }
  // Outbound: through the mesh once it is up (the bus's `peer_call`).
  let before = bus.peer_call.val
  bus.peer_call.val = async fn(target, ws, meth, params, bytes) {
    if target == bus.key.id || target == "self" {
      return before(target, ws, meth, params, bytes)
    }
    guard m.call is Some(call) else { raise BusError("the mesh is not up yet: \{meth} for \{target}") }
    let request = with_fields(params, [("method", Json::string(meth))])
    let (answer, body) = (call.call)(target, ws, request, bytes.map(bytes_body))
    match body {
      Some(b) => (answer, Some(body_bytes(b)))
      None => (answer, None)
    }
  }
  bus.mesh_front_kind.val = () => match m.endpoint {
    Some(e) => if e.kind == "front" && (e.linked)() { "front" } else if e.kind == "front" { "unlinked" } else { "direct" }
    None => if env_get("STILLFAIL_MESH_FRONT") is Some(_) { "unlinked" } else { "direct" }
  }
  bus.mesh_relay_conflict.val = () => match m.endpoint {
    Some(e) => (e.relay_conflict)()
    None => false
  }
  bus.mesh_net_info.val = () => match m.endpoint {
    Some(e) => {
      "id": Json::string(e.id),
      "home": jopt((e.home)()),
      "sockets": Json::array((e.sockets)().map(s => Json::string(s))),
    }
    None => Json::null()
  }
  self.stops.push(() => match m.endpoint {
    Some(e) => fork_bg(self.host, "mesh close", async fn() { (e.close)() })
    None => ()
  })
  m
}

///|
/// Starts the mesh accept loop once the station's other parts (P5-2 to P5-5) have registered their ops and handlers.
fn P51::mesh_start(self : P51, rig : Bool) -> Unit {
  guard self.mesh is Some(m) else { return }
  let bus = self.bus
  self.fork("mesh", async fn() {
    let mut backoff = 1000
    while !bus.stopped.is_done() {
      let started = @host.now()
      let failed : Result[Unit, String] = try {
        self.mesh_run(m, rig)
        Ok(())
      } catch {
        e => Err("\{e}")
      }
      if bus.stopped.is_done() {
        break
      }
      match failed {
        Err(why) => p51_log("ERROR", "mesh", "mesh stopped; trying again", fields={ "error": Json::string(why) })
        Ok(_) => ()
      }
      match m.endpoint {
        Some(e) => {
          m.endpoint = None
          (e.close)() catch {
            _ => ()
          }
        }
        None => ()
      }
      if @host.now() - started > 60000L {
        backoff = 1000
      }
      @effect.sleep(backoff) // timer: a retry after a failure (the mesh's start), with a backoff
      backoff = if backoff * 2 > 30000 { 30000 } else { backoff * 2 }
    }
  })
}

///|
fn body_bytes_of(chunks : Array[Bytes]) -> Bytes {
  let b = @buffer.new()
  for c in chunks {
    b.write_bytes(c)
  }
  b.to_bytes()
}

///|
/// A body as the gate gives it, read whole.
async fn body_bytes(b : @gate.Body) -> Bytes {
  let chunks = []
  while (b.next)() is Some(c) {
    chunks.push(c)
  }
  body_bytes_of(chunks)
}

///|
/// Bytes as a body the gate sends.
fn bytes_body(bytes : Bytes) -> @gate.Body {
  let given = Ref(false)
  { next: async fn() { if given.val { None } else { given.val = true; Some(bytes) } }, stop: async fn() {  }, check: None }
}

///|
/// One run of the mesh: in a workspace, the endpoint bound and served until it fails or the station stops.
async fn P51::mesh_run(self : P51, m : MeshLive, rig : Bool) -> Unit {
  let bus = self.bus
  let host = self.host
  let plane = self.plane.unwrap()
  // Not in a workspace yet: on the mesh once `enroll` writes cloud.json.
  while (bus.cloud_state.val)() is None && !bus.stopped.is_done() {
    let d : @effect.Deferred[Unit] = @effect.Deferred::new()
    let off = (bus.cloud_listen.val)(s => if s is Some(_) { ignore(d.succeed(())) })
    d.wait()
    off()
  }
  let front = env_get("STILLFAIL_MESH_FRONT")
  let bind_addr = env_get("STILLFAIL_MESH_BIND_ADDR")
  let fixed_port = match bind_addr {
    Some(a) =>
      match a.rev_find(":") {
        Some(i) => attempt(() => @string.parse_int(a[i + 1:].to_owned())).unwrap_or(0) > 0
        None => false
      }
    None => false
  }
  // A fixed UDP address cannot be shared with the process before: bound once it is gone.
  if front is None && fixed_port {
    (bus.previous_gone)()
  }
  let bound = @cloud_net.wanted_relays(plane.ways)
  // (a rig: the station transport alone, no members' links, no gateways' tools)
  let alpns = (if rig {
    [@gate.peer_http_alpn, @gate.peer_bytes_alpn, @gate.peer_alpn]
  } else {
    [
      @gate.alpn,
      @gate.peer_http_alpn,
      @gate.peer_bytes_alpn,
      @gate.peer_alpn,
      @mesh_runtime.tools_alpn,
      @mesh_scopes.enrollment_alpn,
    ]
  }).map(a => @utf8.encode(a))
  let congestion = @mesh_runtime.congestion_of(Some((bus.config_raw.val)()))
  let options = @mesh_runtime.front_bind_options(
    bus.key.seed,
    alpns,
    bound,
    discovery=env_get("STILLFAIL_NO_DISCOVERY") != Some("1"),
    bind_addr~,
    congestion=Some(congestion),
  )
  let endpoint = match front {
    Some(socket) => front_endpoint(host, socket, options)
    None => {
      let opts = @mesh_runtime.bind_station(options.get("options").unwrap_or(Json::object({})), bind_addr, env_get("STILLFAIL_MESH_DSCP"))
      shell_endpoint(host, opts, bus.key.seed)
    }
  }
  m.endpoint = Some(endpoint)
  p51_log("INFO", "mesh", "mesh listening", fields={
    "station": Json::string(endpoint.id),
    "sockets": Json::array((endpoint.sockets)().map(s => Json::string(s))),
  })
  // The network's settings as saved, on the running endpoint.
  let last_congestion = Ref(congestion)
  let off_network = (bus.config_listen.val)(raw => {
    let next = @mesh_runtime.congestion_of(Some(raw))
    if next != last_congestion.val {
      last_congestion.val = next
      (endpoint.set_congestion)(next)
      p51_log("INFO", "mesh", "congestion controller for new connections", fields={ "congestion": Json::string(next) })
    }
  })
  let scope_stops : Array[() -> Unit] = [off_network]
  defer {
    for f in scope_stops {
      f()
    }
    m.call = None
    m.http = None
    self.keeper_call.val = None
  }
  // Its relays kept as its workspaces say (relays.ts).
  let relay_ep : @cloud_net.RelayEndpoint = {
    insert_relay: endpoint.insert_relay,
    remove_relay: endpoint.remove_relay,
    keep: endpoint.keep,
    home: endpoint.home,
    public_relays: endpoint.public_relays,
    relay_status: endpoint.relay_status,
    probe_relay: Some(endpoint.probe_relay),
  }
  // An endpoint found stuck by its relays' probes (relays.ts `PROBE`): the launcher's front restarted, the station handed
  // over to the new one; where there is no front, closed, so its `accept` ends this run and `mesh_start` binds anew.
  let on_unhealthy = match bus.restart_front {
    Some(restart) => restart
    None =>
      () => ignore(
        host.rt.fork_daemon("mesh recovered", on_error=e => @host.note("closing a stuck endpoint failed: \{e}"), async fn() {
          (endpoint.close)()
        }),
      )
  }
  let relays_fiber = host.rt.fork(name="relays", async fn() {
    @cloud_net.keep_relays(
      relay_ep,
      plane.ways,
      @cloud_net.host_pinger(plane.http),
      bound~,
      log=w => p51_log("INFO", "relays", w),
      on_unhealthy~,
      say=(level, w) => p51_log(level, "relays", w),
    )
  })
  scope_stops.push(() => relays_fiber.interrupt())
  // Online at the control plane once a relay can reach it (15 s at most).
  let presence_fiber = host.rt.fork(name="online", async fn() {
    // (none to reach it by: nothing to wait for)
    if bound.length() > 0 && @effect.timeout(15000, async fn() { (endpoint.online)() }) is None {
      p51_log("WARN", "mesh", "no relay link after 15 s; going online at \{plane.control.spec().name} anyway")
    }
    @cloud_net.presence(self.presence_parts(plane))
  })
  scope_stops.push(() => presence_fiber.interrupt())
  // The keeper of the locks, and the workspace's other stations asked through this endpoint.
  let keeper = self.keeper_of(plane)
  m.keeper = Some(keeper)
  let scoped = (target : String, ws : String?) => match m.scopes {
    Some(sync) =>
      match (peer_addr(plane, target, ws), sync.scope_for(target, ws)) {
        (Object(a), Some(scope)) => {
          let out = a.copy()
          out["meshScope"] = Json::string(scope)
          Json::object(out)
        }
        (a, _) => a
      }
    None => peer_addr(plane, target, ws)
  }
  // The relays each station is not reached through, held by the endpoint (peer-relays.ts) while it can: one from before,
  // with no such operation, holds none (`holds` false once it says so), and a kept connection whose chosen path goes
  // through a relay turned off is closed instead (relays.ts `goesThrough`), as it is dialed again or the ways change.
  let holds = Ref(true)
  let dialing : @gate.Dialing = {
    connect: async fn(target, ws, given_up) {
      (endpoint.connect)(scoped(target, ws), @utf8.encode(@gate.peer_bytes_alpn), Some(given_up)) |> with_alpn
    },
    hold: Some(async fn(target) {
      guard holds.val else { return }
      let addr = @cloud_net.station_addr(plane.ways, target)
      (endpoint.disabled_relays)(target, addr.disabled_relays, @cloud_net.ours_off(plane.ways)) catch {
        e => if @cloud_net.unsupported("\{e}") { holds.val = false } else { raise e }
      }
    }),
    goes_off: Some((conn, target, ws) => !holds.val &&
      @cloud_net.goes_through(@gate.chosen_relay(conn), Some(@cloud_net.station_addr(plane.ways, target, workspace?=ws).disabled_relays))),
    relays_changed: Some(f => plane.ways.listen(_ => f())),
  }
  let call = @gate.peer_call(keeper, dialing, host.rt, outside=(target, ws) => (bus.outside_reaches.val)(target, Some(ws)))
  m.call = Some(call)
  self.keeper_call.val = Some(call)
  if bus.peer_outside.val is Some(handler) {
    m.peers.outside(async fn(peer, request, body, ws) {
      let bytes = match body {
        Some(b) => Some(body_bytes(b))
        None => None
      }
      let (answer, out) = handler(peer, request, bytes, ws)
      (answer, out.map(bytes_body))
    })
  }
  m.peers.attach(call.call)
  // A rig's grants first on what a station asks of it, every station told it is here.
  match self.rig {
    Some(r) => {
      m.peers.guarded((ws, peer, request) => r.guarded(ws, peer, request) catch {
        @rigs_mode.Refused(why) => raise @gate.PeerRefused(why)
      })
      m.peers.when_attached(() => r.attached())
    }
    None => ()
  }
  scope_stops.push(() => (call.close)())
  // The workspaces' mesh directory over the peer bus, and the relays' door (mesh.ts, scope-sync.ts, enrollment-door.ts).
  let door = self.mesh_scopes(m, endpoint, plane, call, scope_stops)
  scope_stops.push(() => {
    if m.scopes is Some(sync) { sync.close() }
    m.scopes = None
  })
  // The agents' door's way to the other stations' web services.
  let http_dialing : @gate.Dialing = {
    ..dialing,
    connect: async fn(target, ws, given_up) {
      (endpoint.connect)(scoped(target, ws), @utf8.encode(@gate.peer_http_alpn), Some(given_up)) |> with_alpn
    },
  }
  let http = @gate.PeerHttp::new(keeper, http_dialing, host.rt)
  m.http = Some(http)
  scope_stops.push(() => http.close())
  // The locks kept level with the other stations, their changes told to the devices; the ways and the marks too.
  let peer_cb : @cloud_net.PeerCall = {
    call: (target, ws, request, k) => ignore(
      host.rt.fork_quiet(name="peer call", async fn() {
        match (try { Ok((call.call)(target, ws, request, None)) } catch { e => Err(e) }) {
          Ok((answer, _)) => k(Ok(answer))
          Err(e) => k(Err("\{e}"))
        }
      }),
    ),
  }
  let timers = @cloud_net.After::effect(host.rt)
  scope_stops.push(@gate.follow_lock(keeper, call.call, host.rt))
  scope_stops.push(@gate.follow_persons(keeper, call.call, host.rt))
  let tell_events = (event : String, data : Json, key : String, to : Json) => (bus.events_tell.val)(event, data, key, to)
  scope_stops.push(@mesh_runtime.tell_locks(self.lock_source(plane), tell_events))
  scope_stops.push(@cloud_net.follow_ways(plane.ways, peer_cb, timers))
  scope_stops.push(@cloud_net.tell_ways(plane.ways, { tell: (e, d, k, to) => tell_events(e, d, k, Json::string(to)) }))
  scope_stops.push(@cloud_net.follow_marks(plane.marks, peer_cb, timers))
  scope_stops.push(@cloud_net.tell_marks(plane.marks, { tell: (e, d, k, to) => tell_events(e, d, k, Json::string(to)) }))
  // The peer HTTP door for the agents (`/peer/<station>/<port>/…`), once.
  self.peer_door(m)
  // The device tools (the control plane's gateways), here and on the presence socket.
  let tools = self.tools_deps(plane)
  plane.tool_calls.val = Some((request, k) => ignore(
    host.rt.fork_daemon("presence tools", on_error=e => @host.note("presence tools failed: \{e}"), async fn() {
      k(Ok(@mesh_runtime.presence_tools(tools, Some(request))))
    }),
  ))
  scope_stops.push(() => plane.tool_calls.val = None)
  // (a device's leaf in its workspace's scope, where the endpoint keeps scopes and leaves: leaf.ts)
  let leaves = match (m.scopes, endpoint.mesh) {
    (Some(sync), Some(ops)) => {
      let l = @mesh_scopes.Leaves::new({ id: endpoint.id, attach: ops.attach_leaf, detach: ops.detach_leaf }, sync)
      Some(@gate.LeafDoor::{
        authenticated: (conn, ws, exp) => l.authenticated(conn, ws, exp),
        view: ws => l.view(ws),
        follow: async fn(conn, ws, stream) { l.follow(conn, ws, stream) },
        attach: async fn(conn, ws, raw, target) { l.attach(conn, ws, raw, target) },
      })
    }
    _ => None
  }
  let members = if rig { None } else { Some(self.members(keeper, endpoint, leaves~)) }
  let superseded = @gate.Superseded::new()
  let storms = @gate.Storms::new(() => wall_ms() / 1000L)
  let storms_fiber = host.rt.fork(name="storms", async fn() { storms.start() })
  scope_stops.push(() => storms_fiber.interrupt())
  let here : @gate.HereLocal = match self.rig {
    Some(r) =>
      {
        ..self.here_local(),
        allowed: Some((peer, workspace) => r.station_refusal(peer, workspace)),
      }
    None => self.here_local()
  }
  // Its connections, each served by its protocol's own, closed (code 0) once serving it ends.
  while !bus.stopped.is_done() {
    guard (endpoint.accept)() is Some(raw) else { break }
    let conn = with_alpn(raw)
    storms.watch(conn)
    let alpn = (conn.alpn)()
    if alpn == @gate.alpn {
      fork_bg(host, "superseded", async fn() { superseded.arrived(conn) })
    } else if alpn == @gate.peer_bytes_alpn || alpn == @gate.peer_alpn || alpn == @gate.peer_http_alpn {
      (call.arrived)(conn)
    }
    fork_bg(host, "mesh connection", async fn() {
      let served = try {
        if alpn == @gate.peer_bytes_alpn || alpn == @gate.peer_alpn {
          @gate.serve_peer(keeper, conn, m.peers)
        } else if alpn == @gate.peer_http_alpn {
          @gate.serve_http(keeper, conn, here)
        } else if alpn == @mesh_runtime.tools_alpn {
          @mesh_runtime.serve_tools(tools, conn, host.rt)
        } else if alpn == @mesh_scopes.enrollment_alpn {
          door.serve(conn)
        } else {
          match members {
            Some(mem) => @gate.serve(mem, conn)
            None => (conn.close)(1, "this station only runs tasks")
          }
        }
        Ok(())
      } catch {
        e => Err(e)
      }
      match served {
        Err(e) => p51_log("INFO", "mesh", "a connection ended", fields={ "alpn": Json::string(alpn), "error": Json::string(@gate.words_of(e)) })
        Ok(_) => ()
      }
      (conn.close)(0, "")
    })
  }
}

///|
/// What the presence socket is given (the plane's own, with the mesh up).
fn P51::presence_parts(self : P51, plane : Plane) -> @cloud_net.PresenceParts {
  let bus = self.bus
  let host = self.host
  let sign = (m : String) => bus.key.sign(m) catch { _ => "" }
  {
    plane: plane.plane,
    ways: plane.ways,
    spec: () => plane.control.spec(),
    sign,
    version: bus.version,
    up: plane.up,
    ws: @cloud_net.host_ws(host),
    transport: plane.transport,
    said: c => plane.control.said(c),
    every: (ms, f) => {
      let fiber = host.rt.fork(name="presence heartbeat", async fn() {
        while true {
          @effect.sleep(ms) // timer: a heartbeat that keeps the connection (presence.ts PING_MS)
          f()
        }
      })
      () => fiber.interrupt()
    },
    timers: @cloud_net.After::effect(host.rt),
    write_presence: (online, error, conflict) => {
      let text : Map[String, Json] = {
        "online": Json::boolean(online),
        "at": Json::number((wall_ms() / 1000L).to_double()),
        "error": jopt(error),
      }
      if conflict {
        text["conflict"] = Json::boolean(true)
      }
      write_whole(path([bus.data, "run", "presence.json"]), Json::object(text).stringify() + "\n")
      plane.reach_changed()
    },
  }
}

///|
/// The keeper the gate asks of the locks: cloud_lock's, as this station keeps them.
fn P51::keeper_of(self : P51, plane : Plane) -> @gate.Keeper {
  let bus = self.bus
  let host = self.host
  let parts : KeeperParts = {
    cloud: plane.cloud,
    crypto: plane.crypto,
    plane,
    builds: @cloud_lock.DeviceBuilds::new(None, wall_ms().to_double() / 1000.0),
    states: [],
    call: self.keeper_call,
  }
  let seen_file = path([bus.data, "mesh", "seen-devices.json"])
  let seen = @gate.SeenDevices::new(read_text(seen_file), text => write_whole(seen_file, text))
  @gate.Keeper::asking(
    async fn(name, args) { parts.ask(name, args) },
    () => wall_ms() / 1000L,
    {
      oldest_core: @events.oldest_core,
      counted_from: @cloud_lock.counted_from,
      moved_from: @cloud_lock.moved_from_build,
      root_out_from: @cloud_lock.root_out_from_build,
      logs_before: @cloud_lock.logs_before,
      logs_any_from: @cloud_lock.logs_any_from_build,
    },
    (message, key, sig) => {
      let said = host.shell_sync("crypto.verify", {
        "alg": "Ed25519",
        "key": Json::string(@cloud_lock.hex_of(key)),
        "signature": Json::string(@cloud_lock.hex_of(sig)),
        "message": Json::string(@cloud_lock.hex_of(message)),
      }) catch {
        _ => Json::boolean(false)
      }
      said == Json::boolean(true)
    },
    seen,
    f => plane.cloud.listen(_ => f()),
    f => plane.cloud.person_chains().listen(_ => f()),
  )
}

///|
/// Where the locks' heads come from for the devices' event streams (lock-events.ts).
fn P51::lock_source(self : P51, plane : Plane) -> @mesh_runtime.LockSource {
  ignore(self)
  let cloud = plane.cloud
  {
    memberships: () => {
      let home = cloud.home()
      cloud
      .memberships()
      .filter_map(m => match m {
        { "workspace": String(w), .. } => Some((w, Some(w) == home))
        _ => None
      })
    },
    head: ws => Some(@cloud_lock.lock_head(cloud, ws)),
    force_word: ws => cloud.force_word(ws),
    listen_cloud: f => cloud.listen(_ => f()),
    listen_chains: f => cloud.person_chains().listen(f),
    kept: genesis => cloud.person_chains().kept(genesis),
  }
}

///|
/// The members of the station's workspaces, as the gate serves them: the admin API, a part's own stream, what the
/// station's program would answer of a device's reads (this process here: none of its own `--serve` yet).
fn P51::members(self : P51, keeper : @gate.Keeper, endpoint : Endpoint, leaves? : @gate.LeafDoor? = None) -> @gate.Members {
  let bus = self.bus
  let host = self.host
  let lan = () => {
    let ifaces = lan_addrs()
    let port = (endpoint.sockets)()
    ignore(port)
    ifaces.filter_map(a => match a { { "address": String(s), "family": String("IPv4"), .. } => Some(s); _ => None })
  }
  {
    keeper,
    packer: @mesh_door.shell_packer(host),
    up: () => !bus.stopped.is_done(),
    admin: async fn(ask) { self.member_admin(ask) },
    remember_name: (email, name) => match self.readers {
      Some(r) => if name != "" { r.names[email] = name }
      None => ()
    },
    streams: Some(head => match bus.parts.stream_of(head) {
      Some(answer) => Some(self.member_stream(answer))
      None => None
    }),
    screens: Some(self.member_screens()),
    socket: Some(self.member_socket()),
    traces: match self.plane {
      Some(plane) => self.member_traces(plane)
      None => None
    },
    lan: () => @mesh_runtime.lan_addrs((endpoint.sockets)(), []).filter(a => lan().iter().any(l => a.has_prefix(l))),
    tailnet: () => @mesh_runtime.tailnet_addrs((endpoint.sockets)(), []),
    connected: () => bus.parts.connected(),
    served: None,
    lang_of: hs => @gate.lang_of_core(hs),
    update_words: lang => tr(lang, "station.update.tooOld"),
    leaves,
  }
}

///|
/// A member's request of the admin API (serve.ts `admin`): answered as the admin API answers it.
async fn P51::member_admin(self : P51, ask : @gate.AdminAsk) -> @door.Answer {
  guard self.admin is Some(a) else {
    return { status: 503, headers: [("content-type", "application/json")], body: Whole(@utf8.encode("{\"error\":\"station starting\"}")) }
  }
  let signal = @api_routes.Signal::new()
  let req = @api_routes.Request::new(
    ask.verb,
    ask.path,
    ask.query,
    if ask.search == "" { None } else { Some(ask.search) },
    ask.headers,
    ask.body,
    to_jv(ask.viewer.to_json()),
    ask.lang,
    signal~,
  )
  let answer = self.admin_answer(a, req)
  let headers = answer.headers.to_array()
  // (a device gone before a stream's end: the request's signal aborted, so what reads for it stops, and a streamed
  // body's own stop after it)
  let stop = answer.body.stop_with(signal, f => ignore(self.host.rt.fork_quiet(name="stream stop", async fn() { f() catch { _ => () } })))
  match answer.body {
    Whole(b) => { status: answer.status, headers, body: Whole(b) }
    Stream(next) | Streamed(next, _) => { status: answer.status, headers, body: Coming({ next, stop }) }
  }
}

///|
/// The agents' door's `/peer/<station>/<port>/…` (peer-http.ts): a request of another station's web service, carried.
fn P51::peer_door(self : P51, m : MeshLive) -> Unit {
  let bus = self.bus
  if bus.parts.door_route_of("/peer") is Some(_) {
    return
  }
  let host = self.host
  bus.peer_http.val = async fn(r, conn) {
    if @mcp_tools.not_from_here(r.headers, bus.door_ports.val) is Some(why) {
      return Some(plain(403, why))
    }
    guard @mcp_tools.peer_target(r.target) is Some(parsed) else {
      return Some(plain(404, "a web service of another station is /peer/<station name or id>/<port>/<path>"))
    }
    guard m.http is Some(http) else { return Some(plain(503, "this station is not on the mesh yet; try again shortly")) }
    let station = parsed.station
    let port = parsed.port
    let target = parsed.path
    let wrote_head = Ref(false)
    let gone = Ref(false)
    let given = Ref(false)
    let local : @gate.LocalAsk = {
      verb: r.meth,
      path: target,
      raw_headers: r.headers.map(h => [h.0, h.1]).flatten(),
      body: Some({ next: async fn() { if given.val { None } else { given.val = true; Some(r.body) } }, stop: async fn() {  }, check: None }),
    }
    // What goes out on the connection, in the order it was said: the head, the body's pieces, its end (each a step of
    // one queue, so a body never goes out before its head nor the close before what it wrote).
    let queue : Array[async () -> Unit] = []
    let pumping = Ref(false)
    let pump = () => if !pumping.val {
      pumping.val = true
      fork_bg(host, "peer answer", async fn() {
        while queue.length() > 0 {
          let step = queue.remove(0)
          step()
        }
        pumping.val = false
      })
    }
    let close = async fn() { host.tcp_close(conn) }
    let answer : @gate.LocalAnswer = {
      head: (status, raw) => {
        wrote_head.val = true
        let head = StringBuilder()
        head.write_string("HTTP/1.1 \{status} OK\r\n")
        let mut i = 0
        while i + 1 < raw.length() {
          head.write_string("\{raw[i]}: \{raw[i + 1]}\r\n")
          i += 2
        }
        head.write_string("connection: close\r\n\r\n")
        let bytes = @utf8.encode(head.to_string())
        queue.push(async fn() { if !write_on(host, conn, bytes) { gone.val = true } })
        pump()
      },
      write: async fn(b) {
        let written : @effect.Deferred[Unit] = @effect.Deferred::new()
        queue.push(async fn() {
          if !gone.val && !write_on(host, conn, b) {
            gone.val = true
          }
          ignore(written.succeed(()))
        })
        pump()
        written.wait()
      },
      end: () => {
        queue.push(close)
        pump()
      },
      destroy: () => {
        gone.val = true
        queue.push(close)
        pump()
      },
      gone: () => gone.val,
      sent_head: () => wrote_head.val,
    }
    http.request(local, answer, station, port, target)
    None
  }
  bus.parts.door({ prefix: "peer", request: async fn(r, conn) { (bus.peer_http.val)(r, conn) } })
}

///|
/// Where another station is dialed (relays.ts `stationAddr`): through the relays of the workspaces both are in, those
/// they all turn off kept off, and at the addresses its roster entry names (`ips`), where the plane names any.
fn peer_addr(plane : Plane, target : String, ws : String?) -> Json {
  let addr = match @cloud_net.station_addr(plane.ways, target, workspace?=ws).to_json() {
    Object(m) => m.copy()
    _ => {}
  }
  let ips : Array[Json] = []
  let take_ips = (entries : Array[Json]) => for p in entries {
    match p {
      { "id": String(id), "ips": Array(given), .. } if id == target =>
        for ip in given {
          if ip is String(_) && !ips.contains(ip) {
            ips.push(ip)
          }
        }
      _ => ()
    }
  }
  for m in plane.cloud.memberships() {
    match m {
      Object(o) => {
        if o.get("peers") is Some(Array(peers)) {
          take_ips(peers)
        }
        if o.get("workspace") is Some(String(w)) {
          take_ips(plane.cloud.rigs_named(w))
        }
      }
      _ => ()
    }
  }
  if ips.length() > 0 {
    addr["ips"] = Json::array(ips)
  }
  Json::object(addr)
}
