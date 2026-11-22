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

let max_underlay_addrs : Int = 8

///|
fn parse_dec_octet(chars : Array[Char], start : Int, end : Int) -> Int? {
  let len = end - start
  if len < 1 || len > 3 {
    return None
  }
  if len > 1 && chars[start] == '0' {
    return None
  }
  let mut n = 0
  for i in start..<end {
    let c = chars[i]
    if c < '0' || c > '9' {
      return None
    }
    n = n * 10 + (c.to_int() - '0'.to_int())
  }
  if n > 255 { None } else { Some(n) }
}

///|
fn parse_ipv4(host : String) -> (Int, Int, Int, Int)? {
  let chars = host.to_array()
  let dots : Array[Int] = []
  for i, c in chars {
    if c == '.' {
      dots.push(i)
    }
  }
  if dots.length() != 3 {
    return None
  }
  match (
    parse_dec_octet(chars, 0, dots[0]),
    parse_dec_octet(chars, dots[0] + 1, dots[1]),
    parse_dec_octet(chars, dots[1] + 1, dots[2]),
    parse_dec_octet(chars, dots[2] + 1, chars.length()),
  ) {
    (Some(a), Some(b), Some(c), Some(d)) => Some((a, b, c, d))
    _ => None
  }
}

///|
fn parse_hex_group(chars : Array[Char], start : Int, end : Int) -> Int? {
  let len = end - start
  if len < 1 || len > 4 {
    return None
  }
  let mut n = 0
  for i in start..<end {
    let c = chars[i]
    let digit = if c >= '0' && c <= '9' {
      c.to_int() - '0'.to_int()
    } else if c >= 'a' && c <= 'f' {
      10 + (c.to_int() - 'a'.to_int())
    } else if c >= 'A' && c <= 'F' {
      10 + (c.to_int() - 'A'.to_int())
    } else {
      return None
    }
    n = (n << 4) | digit
  }
  Some(n)
}

///|
fn parse_ipv6_side(chars : Array[Char], start : Int, end : Int, allow_ipv4_tail : Bool) -> Array[Int]? {
  if start >= end {
    return Some([])
  }
  let groups : Array[Int] = []
  let mut pos = start
  while pos <= end {
    let mut next = pos
    while next < end && chars[next] != ':' {
      next += 1
    }
    let is_last = next == end
    let mut has_dot = false
    for i in pos..<next {
      if chars[i] == '.' {
        has_dot = true
        break
      }
    }
    if allow_ipv4_tail && is_last && has_dot {
      let buf = StringBuilder::new()
      for i in pos..<next {
        buf.write_char(chars[i])
      }
      match parse_ipv4(buf.to_string()) {
        Some((a, b, c, d)) => {
          groups.push((a << 8) | b)
          groups.push((c << 8) | d)
        }
        None => return None
      }
    } else {
      match parse_hex_group(chars, pos, next) {
        Some(g) => groups.push(g)
        None => return None
      }
    }
    if is_last {
      break
    }
    pos = next + 1
  }
  Some(groups)
}

///|
fn parse_ipv6(raw : String) -> Array[Int]? {
  let all = raw.to_array()
  let mut end = all.length()
  for i, c in all {
    if c == '%' {
      end = i
      break
    }
  }
  let mut dc = -1
  for i in 0..<(end - 1) {
    if all[i] == ':' && all[i + 1] == ':' {
      if dc != -1 {
        return None
      }
      dc = i
    }
  }
  if dc == -1 {
    match parse_ipv6_side(all, 0, end, true) {
      Some(g) if g.length() == 8 => Some(g)
      _ => None
    }
  } else {
    match (parse_ipv6_side(all, 0, dc, false), parse_ipv6_side(all, dc + 2, end, true)) {
      (Some(left), Some(right)) if left.length() + right.length() < 8 => {
        let out : Array[Int] = []
        for g in left {
          out.push(g)
        }
        for _ in 0..<(8 - left.length() - right.length()) {
          out.push(0)
        }
        for g in right {
          out.push(g)
        }
        Some(out)
      }
      _ => None
    }
  }
}

///|
fn extract_ip_host(raw : String) -> String {
  let chars = raw.to_array()
  let len = chars.length()
  if len == 0 {
    return raw
  }
  if chars[0] == '[' {
    let mut end = -1
    for i in 1..<len {
      if chars[i] == ']' {
        end = i
        break
      }
    }
    if end != -1 {
      let buf = StringBuilder::new()
      for i in 1..<end {
        buf.write_char(chars[i])
      }
      return buf.to_string()
    }
    return raw
  }
  let mut first = -1
  let mut last = -1
  for i, c in chars {
    if c == ':' {
      if first == -1 {
        first = i
      }
      last = i
    }
  }
  if first != -1 && first == last {
    let buf = StringBuilder::new()
    for i in 0..<first {
      buf.write_char(chars[i])
    }
    return buf.to_string()
  }
  raw
}

///|
fn ip_tier(raw : String) -> Int {
  let host = extract_ip_host(raw)
  match parse_ipv4(host) {
    Some((a, b, c, d)) => {
      if (a == 169 && b == 254) || a == 127 || (a == 0 && b == 0 && c == 0 && d == 0) {
        return 5
      }
      if a == 10 || (a == 172 && (b & 0xf0) == 16) || (a == 192 && b == 168) || (a == 100 && (b & 0xc0) == 64) {
        return 3
      }
      if (a & 0xf0) == 224 ||
        (a == 255 && b == 255 && c == 255 && d == 255) ||
        (a == 192 && b == 0 && c == 2) ||
        (a == 198 && b == 51 && c == 100) ||
        (a == 203 && b == 0 && c == 113) ||
        a == 0 {
        return 4
      }
      return 1
    }
    None => ()
  }
  match parse_ipv6(host) {
    Some(s) => {
      let s0 = s[0]
      let all_zero = s.iter().all(g => g == 0)
      let is_loopback = s[0] == 0 && s[1] == 0 && s[2] == 0 && s[3] == 0 && s[4] == 0 && s[5] == 0 && s[6] == 0 && s[7] == 1
      if (s0 & 0xffc0) == 0xfe80 || is_loopback || all_zero {
        return 5
      }
      if (s0 & 0xfe00) == 0xfc00 || (s0 & 0xff00) == 0xff00 {
        return 4
      }
      return 2
    }
    None => 4
  }
}

///|
fn underlay_entry(addr : Json) -> (Int, String, String)? {
  match addr {
    Object(m) if m.length() == 1 =>
      match (m.get("Relay"), m.get("Ip")) {
        (Some(String(relay)), _) if relay.length() <= 2048 => Some((0, relay, "R:" + relay))
        (_, Some(String(ip))) if ip.length() <= 128 => Some((ip_tier(ip), ip, "I:" + ip))
        _ => None
      }
    _ => None
  }
}

///|
fn bounded_descriptor(descriptor : Json) -> Json {
  guard descriptor is Object(desc_map) else { return descriptor }
  guard desc_map.get("address") is Some(Object(addr_map)) else { return descriptor }
  guard addr_map.get("addrs") is Some(Array(addrs)) && addrs.length() > max_underlay_addrs else {
    return descriptor
  }
  let ranked : Array[(Int, String, Json)] = []
  let seen : Set[String] = Set::new()
  for addr in addrs {
    match underlay_entry(addr) {
      None => return descriptor
      Some((tier, key, dedup)) => {
        if seen.contains(dedup) {
          continue
        }
        seen.add(dedup)
        ranked.push((tier, key, addr))
      }
    }
  }
  ranked.sort_by((a, b) => if a.0 != b.0 { a.0 - b.0 } else { a.1.compare(b.1) })
  let kept : Array[Json] = []
  let limit = if ranked.length() < max_underlay_addrs { ranked.length() } else { max_underlay_addrs }
  for i in 0..<limit {
    kept.push(ranked[i].2)
  }
  let next_addr : Map[String, Json] = Map::new()
  for k, v in addr_map {
    next_addr[k] = v
  }
  next_addr["addrs"] = Json::array(kept)
  let next_desc : Map[String, Json] = Map::new()
  for k, v in desc_map {
    next_desc[k] = v
  }
  next_desc["address"] = Json::object(next_addr)
  Json::object(next_desc)
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
    let after = self.kept.publish(scope, bounded_descriptor(field(s, "descriptor")), self.signer)
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
/// Whether `node` is on the scope's roster here (`admits`): an exchange asks a peer for only these.
pub fn ScopeDirectory::admits(self : ScopeDirectory, scope : String, node : String) -> Bool {
  match self.wanted.get(scope) {
    Some(r) => r.nodes.contains(node)
    None => false
  }
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
