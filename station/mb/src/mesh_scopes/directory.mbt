// The one owner of the endpoint's mesh scopes (scope-directory.ts `ScopeDirectory`): what roster each scope has is
// the station's admission's to say (`set`), a signed announcement never grants a place in one. Its configuration of the
// endpoint goes one at a time (`reconcile`), a roster that came while it waited applied by the next.

///|
/// The endpoint's scopes as this package asks them of it (endpoint.ts `meshConfigure`, `meshRemove`, `meshListen`):
/// a scope configured answers this station's descriptor in it; what the endpoint says of its scopes as they change
/// (`[{scope, descriptor}]`) is told each listener, what it returns stopping it.
pub(all) struct MeshEndpoint {
  configure : async (Json) -> Json
  remove : async (String) -> Unit
  listen : ((Array[Json]) -> Unit) -> () -> Unit
}

///|
/// A scope's roster as the station admits it (scope-directory.ts `ScopeRoster`).
pub(all) struct Roster {
  scope : String
  nodes : Set[String]
  generations : Map[String, Int64]
  relay_urls : Array[String]
  transit : Bool
  global_relays : Array[Json]
}

///|
pub struct ScopeDirectory {
  endpoint : MeshEndpoint
  kept : Announcements
  crypto : Crypto
  signer : String
  priv mut wanted : Map[String, Roster]
  priv applied : Map[String, String]
  priv known : Set[String]
  priv mut tail : @effect.Deferred[Unit]?
  priv mut closed : Bool
  priv mut authoritative : Bool
  priv mut off : () -> Unit
  priv changed : (String) -> Unit
  priv failed : (Error) -> Unit
  priv rt : @effect.Runtime
}

///|
pub fn ScopeDirectory::new(
  endpoint : MeshEndpoint,
  kept : Announcements,
  crypto : Crypto,
  signer : String,
  changed : (String) -> Unit,
  failed : (Error) -> Unit,
  rt : @effect.Runtime,
) -> ScopeDirectory {
  let d : ScopeDirectory = {
    endpoint,
    kept,
    crypto,
    signer,
    wanted: Map([]),
    applied: Map([]),
    known: Set([]),
    tail: None,
    closed: false,
    authoritative: false,
    off: fn() {  },
    changed,
    failed,
    rt,
  }
  d.off = (endpoint.listen)(scopes => {
    d.addresses(scopes) catch {
      e => (d.failed)(e)
    }
    if d.authoritative &&
      scopes.iter().any(s => !d.wanted.contains(text(field(s, "scope")).unwrap_or(""))) {
      ignore(d.rt.fork_daemon("mesh scopes", on_error=e => (d.failed)(e), async fn() { d.reconcile() catch { e => (d.failed)(e) } }))
    }
  })
  d
}

///|
fn ScopeDirectory::addresses(self : ScopeDirectory, scopes : Array[Json]) -> Unit raise {
  if self.closed {
    return
  }
  for s in scopes {
    let scope = text(field(s, "scope")).unwrap_or("")
    self.known.add(scope)
    guard self.wanted.contains(scope) else { continue }
    let before = self.kept.list(scope, [self.signer]).get(0)
    let after = self.kept.publish(scope, field(s, "descriptor"), self.signer)
    let body_of = (j : Json?) => match j {
      Some(r) => text(field(r, "body"))
      None => None
    }
    if body_of(before) != body_of(Some(after)) {
      (self.changed)(scope)
    }
  }
}

///|
/// The scopes as the station admits them now, applied to the endpoint (`set`).
pub async fn ScopeDirectory::set(self : ScopeDirectory, rosters : Array[Roster]) -> Unit {
  let scopes = Set::from_array(rosters.map(r => r.scope))
  guard rosters.length() <= 32 && scopes.length() == rosters.length() else {
    fail("too many or duplicate mesh scopes")
  }
  let next : Map[String, Roster] = Map([])
  for r in rosters {
    guard hex64(r.scope) &&
      r.nodes.length() <= 256 &&
      r.nodes.contains(self.signer) &&
      r.nodes.iter().all(hex64) else {
      fail("invalid mesh roster")
    }
    if r.global_relays.iter().any(g => r.nodes.contains(text(field(g, "node")).unwrap_or(""))) ||
      r.nodes.length() + r.global_relays.length() > 256 {
      fail("conflicting or excessive mesh identities")
    }
    next[r.scope] = r
  }
  self.kept.retain(next.map((_, r) => r.nodes))
  self.wanted = next
  self.authoritative = true
  self.reconcile()
}

///|
/// What a scope's stations are given of its policy (`policy`).
pub fn ScopeDirectory::policy(self : ScopeDirectory, scope : String) -> Json raise {
  guard self.wanted.get(scope) is Some(r) && !self.closed else { fail("mesh scope removed") }
  let generations : Map[String, Json] = Map([])
  for k, v in r.generations {
    generations[k] = int_json(v)
  }
  {
    "nodes": Json::array(r.nodes.iter().map(Json::string).collect()),
    "generations": Json::object(generations),
    "relayUrls": Json::array(r.relay_urls.map(Json::string)),
    "globalRelays": Json::array(r.global_relays),
  }
}

///|
/// Whether `node` can be reached in `scope` by it (`ready`).
pub fn ScopeDirectory::ready(self : ScopeDirectory, scope : String, node : String) -> Bool {
  !self.closed &&
  self.applied.contains(scope) &&
  (match self.wanted.get(scope) {
    Some(r) => r.nodes.contains(node)
    None => false
  })
}

///|
/// The scope's announcements kept, none older than its node's registration's generation (`records`).
pub fn ScopeDirectory::records(self : ScopeDirectory, scope : String) -> Array[Json] {
  guard self.wanted.get(scope) is Some(r) else { return [] }
  let listed = self.kept.list(scope, r.nodes.iter().collect()) catch { _ => return [] }
  listed.filter(record => {
    let value = (try { @json.parse(text(field(record, "body")).unwrap_or("")) } catch { _ => Json::null() })
    let generation = safe_int(field(field(field(value, "descriptor"), "binding"), "generation")).unwrap_or(0L)
    let node = text(field(value, "node")).unwrap_or("")
    generation >= r.generations.get(node).unwrap_or(0L)
  })
}

///|
/// Another station's records of a scope taken, the whole batch checked before any is kept (`take`).
pub async fn ScopeDirectory::take(self : ScopeDirectory, scope : String, records : Array[Json]) -> Unit {
  guard self.wanted.get(scope) is Some(r) && records.length() <= 256 else {
    fail("invalid mesh directory exchange")
  }
  for record in records {
    let value = announcement_of(self.crypto, record, scope, r.nodes)
    let generation = safe_int(field(field(value.descriptor, "binding"), "generation")).unwrap_or(0L)
    if generation < r.generations.get(value.node).unwrap_or(0L) {
      fail("stale mesh binding generation")
    }
  }
  let mut changed = false
  for record in records {
    changed = self.kept.take(record, scope, r.nodes) || changed
  }
  if changed {
    (self.changed)(scope)
  }
  self.reconcile()
}

///|
/// A station's exchange of a scope's records answered (`exchange`): what it gave taken, the versions of all kept, the
/// records it wanted.
pub async fn ScopeDirectory::exchange(self : ScopeDirectory, scope : String, request : Json) -> Json {
  let give = match field(request, "give") {
    Array(g) => g
    Null => []
    _ => fail("invalid mesh directory exchange")
  }
  let want = match field(request, "want") {
    Array(w) => w
    Null => []
    _ => fail("invalid mesh directory exchange")
  }
  guard self.wanted.get(scope) is Some(r) &&
    give.length() <= 16 &&
    want.length() <= 16 &&
    want.iter().all(n => match n {
      String(id) => r.nodes.contains(id)
      _ => false
    }) else {
    fail("invalid mesh directory exchange")
  }
  self.take(scope, give)
  // (the roster may have changed while the endpoint was configured: nothing of the one before is given)
  guard self.wanted.get(scope) is Some(current) else { fail("mesh scope removed") }
  let versions : Map[String, Json] = Map([])
  let records = []
  let wanted_nodes = Set::from_array(want.map(n => text(n).unwrap_or("")))
  for record in self.records(scope) {
    let value = announcement_of(self.crypto, record, scope, current.nodes)
    versions[value.node] = int_json(value.revision)
    if wanted_nodes.contains(value.node) {
      records.push(record)
    }
  }
  { "versions": Json::object(versions), "records": Json::array(records) }
}

///|
/// The endpoint brought to the scopes wanted, one reconciliation at a time (`reconcile`).
pub async fn ScopeDirectory::reconcile(self : ScopeDirectory) -> Unit {
  let before = self.tail
  let mine : @effect.Deferred[Unit] = @effect.Deferred::new()
  self.tail = Some(mine)
  defer ignore(mine.succeed(()))
  match before {
    Some(d) => d.wait() catch { _ => () }
    None => ()
  }
  if self.closed {
    return
  }
  for scope in self.known.iter().collect() {
    if !self.wanted.contains(scope) {
      (self.endpoint.remove)(scope)
      self.known.remove(scope)
      self.applied.remove(scope)
    }
  }
  // (each wait can admit a new roster, whose own reconciliation configures what comes next)
  let wanted = self.wanted
  for scope, r in wanted {
    if self.closed || !physical_equal(self.wanted, wanted) {
      break
    }
    self.kept.load(scope, r.nodes)
    if self.closed || !physical_equal(self.wanted, wanted) {
      break
    }
    let peers = []
    for a in self.records(scope) {
      let value = announcement_of(self.crypto, a, scope, r.nodes)
      if value.node != self.signer {
        peers.push(value.descriptor)
      }
    }
    let config : Json = {
      "scope": Json::string(scope),
      "peers": Json::array(peers),
      "transit": Json::boolean(r.transit),
      "relayUrls": Json::array(r.relay_urls.map(Json::string)),
      "globalRelays": Json::array(r.global_relays),
    }
    let word = config.stringify()
    if self.applied.get(scope) == Some(word) {
      continue
    }
    // (kept even unanswered: a removal later sends its tombstone, the endpoint may have taken this one)
    self.known.add(scope)
    let descriptor = (self.endpoint.configure)(config)
    self.applied[scope] = word
    if !self.closed && physical_equal(self.wanted, wanted) {
      self.addresses([{ "scope": Json::string(scope), "descriptor": descriptor }])
    }
  }
}

///|
/// Stopped: what the endpoint forwards survives a handover, the next process reconciling it with its own roster.
pub fn ScopeDirectory::close(self : ScopeDirectory) -> Unit {
  self.closed = true
  (self.off)()
}
