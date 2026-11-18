// The workspaces' mesh directory kept level between their stations over the peer connections they already have
// (scope-sync.ts `ScopeSync`; scope-exchange.ts): a station's scopes are its workspaces', their rosters the plane's
// stations and the relays their issuers registered; a healthy peer is asked only when a roster or a record changes.

///|
/// A workspace's scope (enrollment-door.ts `workspaceScope`).
pub fn workspace_scope(c : Crypto, origin : String, workspace : String) -> String {
  let mut o = origin
  while o.has_suffix("/") {
    o = o[:o.length() - 1].to_owned()
  }
  (c.sha256)(utf8("mesh-workspace/v1\u{0}" + o + "\u{0}" + workspace))
}

///|
fn exchange_reply(raw : Json) -> Json raise {
  guard field(raw, "versions") is Object(versions) &&
    versions.length() <= 256 &&
    field(raw, "records") is Array(records) &&
    records.length() <= 16 else {
    fail("invalid mesh exchange reply")
  }
  for node, revision in versions {
    guard hex64(node) && safe_int(revision) is Some(r) && r >= 1L else { fail("invalid mesh revision") }
  }
  raw
}

///|
fn versions_of(records : Array[Json], name : String) -> Map[String, Int64] {
  let out = Map([])
  for r in records {
    let value = (try { @json.parse(text(field(r, "body")).unwrap_or("")) } catch { _ => Json::null() })
    out[text(field(value, "node")).unwrap_or("")] = safe_int(field(value, name)).unwrap_or(0L)
  }
  out
}

///|
/// One exchange of signed records with a peer (scope-exchange.ts `exchangeSignedRecords`): what it has newer asked for
/// sixteen at a time and taken, then what this one has newer given it.
pub async fn exchange_signed_records(
  records : () -> Array[Json],
  take : async (Array[Json]) -> Unit,
  send : async (Json) -> Json,
  name : String,
) -> Unit {
  let mut theirs = exchange_reply(send(Json::object(Map([]))))
  guard field(theirs, "records") is Array(rs) && rs.length() == 0 else { fail("unsolicited mesh records") }
  let ours = versions_of(records(), name)
  let want = []
  guard field(theirs, "versions") is Object(vs) else { fail("invalid mesh exchange reply") }
  for id, v in vs {
    if ours.get(id).unwrap_or(0L) < safe_int(v).unwrap_or(0L) {
      want.push(id)
    }
  }
  let mut i = 0
  while i < want.length() {
    let end = if i + 16 < want.length() { i + 16 } else { want.length() }
    let requested = want[i:end].to_owned()
    let page = exchange_reply(send({ "want": Json::array(requested.map(Json::string)) }))
    guard field(page, "records") is Array(got) else { fail("invalid mesh exchange reply") }
    for record in got {
      let value = (try { @json.parse(text(field(record, "body")).unwrap_or("")) } catch { _ => Json::null() })
      if !requested.contains(text(field(value, "node")).unwrap_or("")) {
        fail("unsolicited mesh identity")
      }
    }
    take(got)
    theirs = page
    i = end
  }
  let their_versions = match field(theirs, "versions") {
    Object(m) => m
    _ => Map([])
  }
  let give = records().filter(record => {
    let value = (try { @json.parse(text(field(record, "body")).unwrap_or("")) } catch { _ => Json::null() })
    safe_int(their_versions.get(text(field(value, "node")).unwrap_or("")).unwrap_or(Json::null())).unwrap_or(0L) <
    safe_int(field(value, name)).unwrap_or(0L)
  })
  let mut j = 0
  while j < give.length() {
    let end = if j + 16 < give.length() { j + 16 } else { give.length() }
    let reply = exchange_reply(send({ "give": Json::array(give[j:end].to_owned()) }))
    guard field(reply, "records") is Array(rr) && rr.length() == 0 else { fail("unsolicited mesh records") }
    j = end
  }
}

///|
priv struct Job {
  scope : String
  workspace : String
  peer : String
  mut done : String
  mut running : Bool
  mut wait : Int
  mut cancel : (() -> Unit)?
}

///|
/// How long a station waits before it tries a peer again that it could not reach or exchange with, at first; each
/// failure after doubles it, up to `peer_retry_most_ms` (scope-sync.ts `PEER_RETRY_MS`, as ways and lock-sync do).
let peer_retry_ms : Int = 5_000

///|
let peer_retry_most_ms : Int = 10 * 60_000

///|
/// What a station from before the directory exchange answers it (scope-sync.ts `OLD_PEER`): a method it does not
/// know, or (one from before `meshDirectory` in peer.ts `servePeer`) the exchange taken as a task's request.
fn old_peer(said : String) -> Bool {
  let s = said.to_lower()
  (s.contains("unknown") && s.contains("method")) ||
  s.contains("no such method") ||
  s.contains("unsupported peer method") ||
  s.contains("session and task key is required") ||
  s.contains("session and task key are required")
}

///|
fn backoff(wait : Int, first : Int, most : Int) -> Int {
  if wait == 0 {
    first
  } else if wait * 2 < most {
    wait * 2
  } else {
    most
  }
}

///|
/// What a failed exchange did to its job, and how long it waits before it is tried again.
priv enum Failed {
  /// A station from before the exchange: level with it until this station's word changes.
  Level
  /// The peer's call failed (it is off, or refused): tried again from 5 s, doubling up to 10 min, said at INFO.
  Peer(Int)
  /// This station's own directory failed: tried again from 1 s, doubling up to 60 s, said at WARN.
  Own(Int)
}

///|
/// A failed exchange taken (scope-sync.ts `#pump`'s rejection): `peer_failed` where the peer's call raised.
fn Job::failed(self : Job, word : String, peer_failed : Bool, said : String) -> Failed {
  if peer_failed && old_peer(said) {
    self.done = word
    self.wait = 0
    Level
  } else if peer_failed {
    self.wait = backoff(self.wait, peer_retry_ms, peer_retry_most_ms)
    Peer(self.wait)
  } else {
    self.wait = backoff(self.wait, 1000, 60000)
    Own(self.wait)
  }
}

///|
/// What the directory is given of the station (mesh.ts's ScopeSync arguments).
pub(all) struct SyncParts {
  cloud : @cloud_net.CloudView
  ways : @cloud_net.Ways
  /// A request of another station of the workspace over the peer bus (peer.ts `peerCall`).
  call : async (String, String, Json) -> Json
  /// The store's mesh rows (the readers' `internalMeshControl`: announcements, relayRecords, registration).
  read : async (Json) -> Json
  after : (Int, () -> Unit) -> () -> Unit
  now : () -> Double
  /// A failure of this station's own directory (logged at WARN).
  log : (String) -> Unit
  /// A peer not brought level, its words and fields (logged at INFO): a peer that is off is the workspace's ordinary
  /// state, not this station's failure.
  info : (String, Json) -> Unit
}

///|
pub struct ScopeSync {
  directory : ScopeDirectory
  parts : SyncParts
  db : @sql.Db
  crypto : Crypto
  priv relay_records : Map[String, Array[Json]]
  priv workspaces : Map[String, String]
  priv jobs : Map[String, Job]
  priv listeners : Map[Int, (String) -> Unit]
  priv mut next_listener : Int
  priv mut roster_epoch : Int
  priv mut roster_wait : Int
  priv mut roster_retry : (() -> Unit)?
  priv mut offs : Array[() -> Unit]
  priv mut closed : Bool
  priv mut active : Int
  priv rt : @effect.Runtime
}

///|
pub fn ScopeSync::new(
  endpoint : MeshEndpoint,
  db : @sql.Db,
  crypto : Crypto,
  signer : String,
  parts : SyncParts,
  rt : @effect.Runtime,
) -> ScopeSync {
  let kept = Announcements::new(db, crypto, async fn(scope, nodes) {
    match
      (parts.read)({
        "kind": "announcements",
        "scope": Json::string(scope),
        "nodes": Json::array(nodes.map(Json::string)),
      }) {
      Array(rows) => rows
      _ => []
    }
  })
  let changed : Ref[(String) -> Unit] = Ref(_ => ())
  let failed : Ref[(Error) -> Unit] = Ref(_ => ())
  let directory = ScopeDirectory::new(endpoint, kept, crypto, signer, s => (changed.val)(s), e => (failed.val)(e), rt)
  let sync : ScopeSync = {
    directory,
    parts,
    db,
    crypto,
    relay_records: Map([]),
    workspaces: Map([]),
    jobs: Map([]),
    listeners: Map([]),
    next_listener: 0,
    roster_epoch: 0,
    roster_wait: 0,
    roster_retry: None,
    offs: [],
    closed: false,
    active: 0,
    rt,
  }
  changed.val = s => sync.changed(s)
  failed.val = e => sync.failed(e)
  let again = () => ignore(rt.fork(name="mesh roster", async fn() { sync.roster() }))
  sync.offs = [(parts.cloud.listen)(again), parts.ways.listen(_ => again())]
  again()
  sync
}

///|
fn ScopeSync::failed(self : ScopeSync, e : Error) -> Unit {
  (self.parts.log)("mesh directory update failed: \{e}")
}

///|
fn ScopeSync::origin(self : ScopeSync) -> String? {
  (self.parts.cloud.origin)()
}

///|
fn peer_ids(m : @cloud_net.Membership) -> Array[String] {
  m.peers.filter_map(p => text(field(p, "id")))
}

///|
/// The rosters the plane says now, with the relays their issuers registered, applied (`#roster`).
async fn ScopeSync::roster(self : ScopeSync) -> Unit {
  if self.closed || !(self.parts.cloud.peers_current)() {
    return
  }
  guard self.origin() is Some(origin) else { return }
  self.roster_epoch += 1
  let epoch = self.roster_epoch
  match self.roster_retry {
    Some(f) => f()
    None => ()
  }
  self.roster_retry = None
  let rosters : Array[Roster] = []
  let jobs : Map[String, (String, String, String)] = Map([])
  let workspaces : Map[String, String] = Map([])
  let records : Map[String, Array[Json]] = Map([])
  let applied = try {
    for m in (self.parts.cloud.memberships)() {
      let scope = workspace_scope(self.crypto, origin, m.workspace)
      let nodes = Set::from_array([self.directory.signer])
      for id in peer_ids(m) {
        nodes.add(id)
      }
      let off = Set::from_array(self.parts.ways.view(m.workspace).off)
      let globals = if off.contains("ours") {
        []
      } else {
        (self.parts.cloud.mesh_relays)().filter(g => !off.contains("mesh:" + text(field(g, "node")).unwrap_or("")))
      }
      let roster : Roster = {
        scope,
        nodes,
        generations: Map([]),
        relay_urls: @cloud_net.workspace_relays(self.parts.ways, m.workspace),
        transit: true,
        global_relays: globals,
      }
      rosters.push(roster)
      workspaces[m.workspace] = scope
      for peer in nodes {
        if peer != self.directory.signer {
          jobs["\{scope}:\{peer}"] = (scope, m.workspace, peer)
        }
      }
    }
    for i, roster in rosters {
      let saved = match (self.parts.read)({ "kind": "relayRecords", "scope": Json::string(roster.scope) }) {
        Array(rows) if rows.length() <= 256 => rows
        _ => fail("invalid stored relay directory")
      }
      let admitted = []
      let nodes = Set::from_array(roster.nodes.iter().collect())
      let generations : Map[String, Int64] = Map([])
      for signed in saved {
        // (an issuer the roster no longer names grants no transit)
        let issuer = (try { text(field(@json.parse(text(field(signed, "body")).unwrap_or("")), "issuer")).unwrap_or("") } catch { _ => "" })
        if !roster.nodes.contains(issuer) {
          continue
        }
        let record = relay_record_of(self.crypto, signed, roster.scope, roster.nodes)
        admitted.push(signed)
        if safe_int(field(record, "revoked")) == Some(0L) {
          let node = text(field(record, "node")).unwrap_or("")
          nodes.add(node)
          generations[node] = safe_int(field(record, "generation")).unwrap_or(0L)
        }
      }
      records[roster.scope] = admitted
      rosters[i] = { ..roster, nodes, generations }
    }
    if epoch != self.roster_epoch || self.closed {
      return
    }
    let changed_scopes = Set::from_array(self.relay_records.keys().collect())
    for s in records.keys() {
      changed_scopes.add(s)
    }
    self.relay_records.clear()
    for s, rows in records {
      self.relay_records[s] = rows
    }
    self.workspaces.clear()
    for w, s in workspaces {
      self.workspaces[w] = s
    }
    for k in self.jobs.keys().collect() {
      if !jobs.contains(k) {
        match self.jobs[k].cancel {
          Some(f) => f()
          None => ()
        }
        self.jobs.remove(k)
      }
    }
    for k, j in jobs {
      if !self.jobs.contains(k) {
        self.jobs[k] = { scope: j.0, workspace: j.1, peer: j.2, done: "", running: false, wait: 0, cancel: None }
      }
    }
    self.directory.set(rosters)
    Ok(changed_scopes)
  } catch {
    e => Err(e)
  }
  match applied {
    Ok(changed_scopes) => {
      if epoch == self.roster_epoch {
        self.roster_wait = 0
      }
      for s in changed_scopes {
        self.changed(s)
      }
    }
    Err(e) => self.retry_roster(epoch, e)
  }
}

///|
fn ScopeSync::retry_roster(self : ScopeSync, epoch : Int, e : Error) -> Unit {
  if self.closed || epoch != self.roster_epoch {
    return
  }
  self.failed(e)
  self.roster_wait = if self.roster_wait == 0 {
    1000
  } else if self.roster_wait * 2 < 60000 {
    self.roster_wait * 2
  } else {
    60000
  }
  // timer: a retry after a failure, with a backoff (the endpoint's directory not applied)
  self.roster_retry = Some(
    (self.parts.after)(self.roster_wait, () => ignore(self.rt.fork(name="mesh roster", async fn() { self.roster() }))),
  )
}

///|
fn ScopeSync::word(self : ScopeSync, scope : String) -> String {
  let pairs = (records : Array[Json], name : String) => {
    let out = records.map(r => {
      let a = (try { @json.parse(text(field(r, "body")).unwrap_or("")) } catch { _ => Json::null() })
      Json::array([field(a, "node"), field(a, name)]).stringify()
    })
    out.sort()
    out
  }
  Json::array([
    Json::array(pairs(self.directory.records(scope), "revision").map(Json::string)),
    Json::array(pairs(self.relay_records.get(scope).unwrap_or([]), "generation").map(Json::string)),
  ]).stringify()
}

///|
/// Each peer of each scope brought level where what was last brought differs, four at a time (`#pump`).
fn ScopeSync::pump(self : ScopeSync) -> Unit {
  if self.closed {
    return
  }
  for key, job in self.jobs {
    if self.active >= 4 {
      break
    }
    let word = self.word(job.scope)
    if job.running || job.cancel is Some(_) || job.done == word {
      continue
    }
    job.running = true
    self.active += 1
    // Whether the peer's call failed, not this station's own directory (its endpoint, its store).
    let peer_failed = Ref(false)
    let send = (asked : String) => async fn(request : Json) -> Json {
      guard !self.closed && self.jobs.get(key) is Some(j) && physical_equal(j, job) else {
        fail("mesh membership changed")
      }
      let body = match request {
        Object(m) => {
          let out : Map[String, Json] = Map([("method", Json::string(asked))])
          for k, v in m {
            out[k] = v
          }
          out
        }
        _ => Map([("method", Json::string(asked))])
      }
      errdefer {
        peer_failed.val = true
      }
      (self.parts.call)(job.peer, job.workspace, Json::object(body))
    }
    ignore(
      self.rt.fork(name="mesh exchange", async fn() {
        let result = try {
          // (who may relay arrives before any relay's address)
          exchange_signed_records(
            () => self.relay_records.get(job.scope).unwrap_or([]),
            async fn(records) { self.take_registrations(job.scope, records) },
            send("meshRelays.exchange"),
            "generation",
          )
          exchange_signed_records(
            () => self.directory.records(job.scope),
            async fn(records) { self.directory.take(job.scope, records) },
            send("meshScopes.exchange"),
            "revision",
          )
          Ok(())
        } catch {
          e => Err(e)
        }
        job.running = false
        self.active -= 1
        match result {
          Ok(_) => {
            job.done = word
            job.wait = 0
          }
          Err(e) =>
            if !self.closed && self.jobs.get(key) is Some(j) && physical_equal(j, job) {
              let wait = match job.failed(word, peer_failed.val, "\{e}") {
                Level => None
                Peer(wait) => {
                  (self.parts.info)("a station's mesh directory was not brought level", {
                    "peer": Json::string(
                      if job.peer.length() > 12 {
                        job.peer[:12].to_owned()
                      } else {
                        job.peer
                      },
                    ),
                    "workspace": Json::string(job.workspace),
                    "error": Json::string("\{e}"),
                  })
                  Some(wait)
                }
                Own(wait) => {
                  self.failed(e)
                  Some(wait)
                }
              }
              if wait is Some(ms) {
                // timer: a retry after a failure, with a backoff (a directory exchange)
                job.cancel = Some(
                  (self.parts.after)(ms, () => {
                    job.cancel = None
                    self.pump()
                  }),
                )
              }
            }
        }
        self.pump()
      }),
    )
  }
}

///|
fn ScopeSync::changed(self : ScopeSync, scope : String) -> Unit {
  self.pump()
  for _, f in self.listeners {
    f(scope)
  }
}

///|
/// Told each scope that changed; what it returns stops it.
pub fn ScopeSync::listen(self : ScopeSync, f : (String) -> Unit) -> () -> Unit {
  self.next_listener += 1
  let id = self.next_listener
  self.listeners[id] = f
  () => self.listeners.remove(id)
}

///|
/// What a relay registered in `scope` as `node` is given of its directory (`relayView`).
pub fn ScopeSync::relay_view(self : ScopeSync, scope : String, node : String) -> Json raise {
  let registered = self.relay_records.get(scope).unwrap_or([]).iter().find_first(r => {
    let a = (try { @json.parse(text(field(r, "body")).unwrap_or("")) } catch { _ => Json::null() })
    text(field(a, "node")) == Some(node) && safe_int(field(a, "revoked")) == Some(0L)
  })
  guard registered is Some(r) && !self.closed else { fail("relay registration removed") }
  let a = @json.parse(text(field(r, "body")).unwrap_or(""))
  let policy = self.directory.policy(scope)
  let out : Map[String, Json] = Map([("scope", Json::string(scope)), ("generation", field(a, "generation"))])
  match policy {
    Object(m) =>
      for k, v in m {
        out[k] = v
      }
    _ => ()
  }
  out["records"] = Json::array(self.directory.records(scope))
  Json::object(out)
}

///|
/// A registered relay's own announcement taken (`relayAnnouncement`): it must offer forwarding.
pub async fn ScopeSync::relay_announcement(self : ScopeSync, scope : String, node : String, signed : Json) -> Unit {
  let view = self.relay_view(scope, node)
  let record = announcement_of(
    self.crypto,
    signed,
    scope,
    Set::from_array([node]),
    minimum_generation=safe_int(field(view, "generation")).unwrap_or(0L),
  )
  guard field(field(record.descriptor, "binding"), "transit") is True else {
    fail("a relay must advertise forwarding capability")
  }
  self.directory.take(scope, [signed])
}

///|
/// A registration this station's door issued, taken as any station's (`registration`).
pub async fn ScopeSync::registration(self : ScopeSync, signed : Json) -> Unit {
  let body = @json.parse(text(field(signed, "body")).unwrap_or(""))
  self.take_registrations(text(field(body, "scope")).unwrap_or(""), [signed])
}

///|
async fn ScopeSync::take_registrations(self : ScopeSync, scope : String, records : Array[Json]) -> Unit {
  guard self.origin() is Some(origin) && !self.closed else { fail("relay workspace removed") }
  guard (self.parts.cloud.memberships)().iter().find_first(m => workspace_scope(self.crypto, origin, m.workspace) ==
      scope)
    is Some(membership) else {
    fail("relay workspace removed")
  }
  let issuers = Set::from_array([self.directory.signer])
  for id in peer_ids(membership) {
    issuers.add(id)
  }
  for signed in records {
    ignore(relay_record_of(self.crypto, signed, scope, issuers))
  }
  let mut changed = false
  for signed in records {
    changed = take_relay_record(self.db, self.crypto, signed, scope, issuers) || changed
  }
  // (the door may have kept the record already before this call)
  if changed || records.length() > 0 {
    self.roster()
  }
}

///|
/// A workspace's relays as their records say (`relays`).
pub fn ScopeSync::relays(self : ScopeSync, workspace : String) -> Array[Json] raise {
  guard self.workspaces.get(workspace) is Some(scope) &&
    (self.parts.cloud.membership)(workspace) is Some(_) else {
    fail("mesh workspace is not ready")
  }
  self.relay_records
  .get(scope)
  .unwrap_or([])
  .map(signed => @json.parse(text(field(signed, "body")).unwrap_or(""))) catch {
    _ => fail("invalid relay record")
  }
}

///|
/// A relay of the workspace taken back: by this station where it issued it, else asked of its issuer (`revoke`).
pub async fn ScopeSync::revoke(self : ScopeSync, workspace : String, node : String, local_only? : Bool = false) -> Json {
  guard self.workspaces.get(workspace) is Some(scope) &&
    !self.closed &&
    (self.parts.cloud.membership)(workspace) is Some(_) &&
    hex64(node) else {
    fail("invalid relay workspace or identity")
  }
  guard self.relay_records
    .get(scope)
    .unwrap_or([])
    .iter()
    .find_first(s => (try { text(field(@json.parse(text(field(s, "body")).unwrap_or("")), "node")) } catch { _ => None }) ==
      Some(node))
    is Some(signed) else {
    fail("relay is not registered in this workspace")
  }
  let record = @json.parse(text(field(signed, "body")).unwrap_or(""))
  let issuer = text(field(record, "issuer")).unwrap_or("")
  if issuer != self.directory.signer {
    if local_only {
      fail("only the issuing station can revoke this relay")
    }
    let reply = (self.parts.call)(issuer, workspace, { "method": "meshRelays.revoke", "node": Json::string(node) })
    let revoked = relay_record_of(self.crypto, reply, scope, Set::from_array([issuer]))
    if text(field(revoked, "node")) != Some(node) ||
      safe_int(field(revoked, "revoked")) != Some(1L) ||
      safe_int(field(revoked, "generation")).unwrap_or(0L) <
      safe_int(field(record, "generation")).unwrap_or(0L) {
      fail("invalid relay revocation reply")
    }
    self.registration(reply)
    return reply
  }
  let revoked = Enrollment::new(self.db, self.directory.signer, self.parts.now, self.crypto).revoke(scope, node)
  let reply = sign_relay_record(self.crypto, revoked)
  self.registration(reply)
  reply
}

///|
/// The scope a peer is reached in, where one is ready (`scopeFor`).
pub fn ScopeSync::scope_for(self : ScopeSync, peer : String, workspace : String?) -> String? {
  let candidates = match workspace {
    Some(w) =>
      match self.workspaces.get(w) {
        Some(s) => [s]
        None => []
      }
    None => self.workspaces.values().collect()
  }
  candidates.iter().find_first(scope => self.directory.ready(scope, peer))
}

///|
/// A peer's directory request answered (`answer`): meshScopes.exchange, meshRelays.exchange, meshRelays.revoke.
pub async fn ScopeSync::answer(self : ScopeSync, peer : String, workspace : String, request : Json) -> Json {
  let admitted = () => !self.closed &&
    (match (self.parts.cloud.membership)(workspace) {
      Some(m) => peer_ids(m).contains(peer)
      None => false
    })
  let asked = text(field(request, "method")).unwrap_or("")
  guard self.workspaces.get(workspace) is Some(scope) &&
    admitted() &&
    (asked == "meshScopes.exchange" || asked == "meshRelays.exchange" || asked == "meshRelays.revoke") else {
    fail("mesh workspace membership required")
  }
  let result = if asked == "meshRelays.revoke" {
    self.revoke(workspace, text(field(request, "node")).unwrap_or(""), local_only=true)
  } else if asked == "meshRelays.exchange" {
    let give = match field(request, "give") {
      Array(g) => g
      Null => []
      _ => fail("invalid relay record exchange")
    }
    let want = match field(request, "want") {
      Array(w) => w
      Null => []
      _ => fail("invalid relay record exchange")
    }
    if give.length() > 16 ||
      want.length() > 16 ||
      want.iter().any(id => !(id is String(s) && hex64(s))) {
      fail("invalid relay record exchange")
    }
    self.take_registrations(scope, give)
    let wanted = Set::from_array(want.map(id => text(id).unwrap_or("")))
    let versions : Map[String, Json] = Map([])
    let records = []
    for signed in self.relay_records.get(scope).unwrap_or([]) {
      let record = @json.parse(text(field(signed, "body")).unwrap_or(""))
      let node = text(field(record, "node")).unwrap_or("")
      versions[node] = field(record, "generation")
      if wanted.contains(node) {
        records.push(signed)
      }
    }
    { "versions": Json::object(versions), "records": Json::array(records) }
  } else {
    self.directory.exchange(scope, request)
  }
  guard admitted() else { fail("mesh workspace membership removed") }
  result
}

///|
pub fn ScopeSync::close(self : ScopeSync) -> Unit {
  self.closed = true
  match self.roster_retry {
    Some(f) => f()
    None => ()
  }
  for f in self.offs {
    f()
  }
  for _, job in self.jobs {
    match job.cancel {
      Some(f) => f()
      None => ()
    }
  }
  self.jobs.clear()
  self.listeners.clear()
  self.directory.close()
}
