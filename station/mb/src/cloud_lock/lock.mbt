// The workspace's lock (station/src/cloud/lock.ts): the rules (rules/src/lock) with the station's cryptography, an
// entry a JSON value as it came, each answer and refusal as the TypeScript's.

///|
/// The roles, lowest first (lock.ts `ROLES`).
pub let roles : Array[String] = ["viewer", "member", "admin", "owner"]

///|
pub fn rank(role : String) -> Int {
  match roles.search(role) {
    Some(i) => i
    None => -1
  }
}

///|
/// The lower of two roles (lock.ts `lowerRole`: an unknown role is the lowest).
pub fn lower_role(a : String, b : String) -> String {
  let r = if rank(a) < rank(b) { rank(a) } else { rank(b) }
  roles[if r < 0 { 0 } else { r }]
}

///|
/// How long a device added from a web page lasts at most.
pub let web_device_secs : Double = 2678400.0

///|
/// JSON with object keys sorted, no space: what is hashed (lock.ts `canonical`).
pub fn canonical(v : Json) -> String raise Failure {
  @form.canonical(v) catch {
    @form.Invalid(why) => raise Failed(why)
  }
}

///|
/// The cryptography of hashing alone (no signature is checked with it).
let hashing : Crypto = { verify: (_, _, _, _) => false }

///|
/// An entry's hash (hex): of everything but its signature (lock.ts `entryHash`).
pub fn entry_hash(e : Json) -> String raise Failure {
  @lock.entry_hash(e, hashing) catch {
    err => raise Failed(why_of(err))
  }
}

///|
/// An entry's hash, as `hashOf` (log-keep.ts) gives it: "" where it has none (as it is never asked of such).
pub fn hash_of(e : Json) -> String {
  entry_hash(e) catch {
    _ => ""
  }
}

///|
fn seq_of(e : Json) -> Double {
  num_at(e, "seq").unwrap_or(0.0)
}

///|
fn prev_of(e : Json) -> String? {
  text_at(e, "prev")
}

///|
fn kind_of(e : Json) -> String {
  text_at(e, "kind").unwrap_or("")
}

///|
fn ws_of(e : Json) -> String {
  text_at(e, "ws").unwrap_or("")
}

///|
fn body_of(e : Json) -> Json? {
  get(e, "body")
}

///|
/// An entry as it may have come over the wire: its shape checked, not its signature (lock.ts `asEntry`).
pub fn as_entry(v : Json) -> Json? {
  guard v is Object(_) else { return None }
  guard get(v, "v") is Some(Number(1.0, ..)) else { return None }
  guard get(v, "ws") is Some(String(_)) else { return None }
  guard get(v, "seq") is Some(Number(seq, ..)) && safe_int(seq) && seq >= 0.0 else { return None }
  match get(v, "prev") {
    Some(Null) => ()
    Some(String(p)) => if !is_hex32(p) { return None }
    _ => return None
  }
  guard get(v, "at") is Some(Number(at, ..)) && safe_int(at) else { return None }
  guard get(v, "kind") is Some(String(_)) else { return None }
  guard get(v, "sig") is Some(Object(_) as s) else { return None }
  guard get(s, "key") is Some(String(_)) && get(s, "sig") is Some(String(_)) else { return None }
  match get(s, "alg") {
    Some(String("webauthn")) =>
      if !(get(s, "authenticator_data") is Some(String(_)) && get(s, "client_data") is Some(String(_))) {
        return None
      }
    Some(String("Ed25519")) | Some(String("ES256")) => ()
    _ => return None
  }
  if (try Ok(canonical(get(v, "body").unwrap_or(Json::null()))) catch { e => Err(e) }) is Err(_) {
    return None
  }
  Some(v)
}

///|
/// Entries as they came over the wire, their shape checked; None where one is malformed (person-chains.ts `entriesOf`).
pub fn entries_of(raw : Array[Json]) -> Array[Json]? {
  let out = []
  for x in raw {
    match as_entry(x) {
      Some(e) => out.push(e)
      None => return None
    }
  }
  Some(out)
}

// ── the rules ────────────────────────────────────────────────────────────────────────────────────────────────────

///|
/// The lock its first entry starts (lock.ts `genesis`).
pub fn genesis(c : Crypto, e : Json) -> @lock.LockState raise Failure {
  @lock.genesis(e, c) catch {
    err => raise Failed(why_of(err))
  }
}

///|
/// The lock with one more entry (lock.ts `apply`); `now` none for entries taken before.
pub fn apply(c : Crypto, prev : @lock.LockState, e : Json, now : Double?) -> @lock.LockState raise Failure {
  @lock.apply(prev, e, now, c) catch {
    err => raise Failed(why_of(err))
  }
}

///|
/// A whole chain from its genesis (lock.ts `fold`).
pub fn fold(c : Crypto, entries : Array[Json], now : Double?) -> @lock.LockState raise Failure {
  @lock.fold(entries, now, c) catch {
    err => raise Failed(why_of(err))
  }
}

///|
/// Who signed with `key` (lock.ts `signer`).
pub fn signer(s : @lock.LockState, key : String, now : Double?) -> @lock.Signer? {
  @lock.signer(s, key, now)
}

///|
/// Who a connection is (lock.ts `admit`): the device and its member's role; raises a refusal why not.
pub fn admit(c : Crypto, s : @lock.LockState, who : Who, now : Double) -> (@lock.Device, String) raise Failure {
  @lock.admit(s, who.sub, who.endpoint, who.base, who.proof, now, c) catch {
    err => raise Refused(why_of(err))
  }
}

///|
/// A connection as it shows itself: whose credential, its endpoint, its base key and that key's proof of the endpoint.
pub(all) struct Who {
  sub : String
  endpoint : String
  base : String?
  proof : String?
}

///|
/// A person's own lock as its chain says it (lock.ts `personFold`).
pub fn person_fold(c : Crypto, entries : Array[Json], sub : String) -> @lock.Person raise Failure {
  @lock.fold_person(entries, sub, c) catch {
    err => raise Failed(why_of(err))
  }
}

///|
/// Who a connection is by a person's own lock (lock.ts `admitPerson`): the device's id, the member's role and the
/// person; raises a refusal why not.
pub fn admit_person(c : Crypto, s : @lock.LockState, who : Who, entries : Array[Json]) -> (String, String, @lock.Person) raise Failure {
  let (d, role, person) = @lock.admit_person(s, who.sub, who.endpoint, who.base, who.proof, entries, c) catch {
    err => raise Refused(why_of(err))
  }
  (d.id, role, person)
}

///|
/// Why an entry given is off a log's active chain (lock.ts `Off`).
pub(all) struct Off {
  at : Int
  why : String
  refusal : String?
  winner : String?
  step : String?
  under : String?
}

///|
/// A log's active chain among entries given (lock.ts `Chain`).
pub(all) struct Chain {
  at : Array[Int]
  hashes : Array[String]
  off : Array[Off]
}

///|
fn step_name(s : @fork.Step) -> String {
  match s {
    Weight => "weight"
    Removal => "removal"
    Tie => "tie"
    Hash => "hash"
  }
}

///|
fn chain_of(ch : @lock.Chain) -> Chain {
  let off = ch.off.map(p => {
    let at = p.0
    match p.1 {
      NotValid(why) => { at, why: "refused", refusal: Some(why), winner: None, step: None, under: None }
      NoParent => { at, why: "no parent", refusal: None, winner: None, step: None, under: None }
      Beaten(w, step) => { at, why: "beaten", refusal: None, winner: Some(w), step: Some(step_name(step)), under: None }
      Below(top) => { at, why: "below", refusal: None, winner: None, step: None, under: Some(top) }
      Again => { at, why: "again", refusal: None, winner: None, step: None, under: None }
    }
  })
  { at: ch.at, hashes: ch.hashes, off }
}

///|
/// The workspace lock's active chain among `entries` from its genesis of hash `root`, votes by role (lock.ts
/// `lockChain`).
pub fn lock_chain(c : Crypto, entries : Array[Json], root : String) -> Chain raise Failure {
  chain_of(@lock.lock_chain(entries, root, Roles, None, c)) catch {
    err => raise Failed(why_of(err))
  }
}

///|
/// A person log's active chain among `entries` from its genesis of hash `root` (lock.ts `personChain`).
pub fn person_chain(c : Crypto, entries : Array[Json], root : String) -> Chain raise Failure {
  chain_of(@lock.person_chain(entries, root, c)) catch {
    err => raise Failed(why_of(err))
  }
}

///|
/// A workspace said in its people's own logs (lock.ts `state4`).
pub fn state4(c : Crypto, ws : String, root : String, chains : Array[Array[Json]], bodies : Array[Json], now : Double) -> @lock.State4 {
  @lock.state4(ws, root, chains, bodies, now, c)
}

///|
/// A chain read as it moved, kept while it is the same chain (lock.ts `carriedOf`).
priv struct CarriedKept {
  chain : Array[Json]
  length : Int
  last : Json?
  moved : @lock.Moved
}

///|
let carried_kept : Ref[CarriedKept?] = Ref(None)

///|
fn carried(c : Crypto, chain : Array[Json]) -> @lock.Moved {
  let last = chain.last()
  if carried_kept.val is Some(k) &&
    physical_equal(k.chain, chain) &&
    k.length == chain.length() &&
    (match (k.last, last) {
      (Some(a), Some(b)) => physical_equal(a, b)
      (None, None) => true
      _ => false
    }) {
    return k.moved
  }
  let moved = @lock.moved_of(chain, c)
  carried_kept.val = Some({ chain, length: chain.length(), last, moved })
  moved
}

///|
/// `state4` of a workspace whose chain moved (lock.ts `state4Moved`).
pub fn state4_moved(c : Crypto, ws : String, chain : Array[Json], chains : Array[Array[Json]], bodies : Array[Json], now : Double) -> @lock.State4 {
  @lock.state4_carried(ws, carried(c, chain), chains, bodies, now, c)
}

///|
/// `roster4` of a workspace whose chain moved (lock.ts `roster4Moved`).
pub fn roster4_moved(c : Crypto, ws : String, chain : Array[Json], chains : Array[Array[Json]], bodies : Array[Json], without? : Array[String] = []) -> @lock.Roster {
  @lock.roster_carried(ws, carried(c, chain), chains, bodies, without, c)
}

///|
/// Workspace `ws`'s list (lock.ts `roster4`).
pub fn roster4(c : Crypto, ws : String, root : String, chains : Array[Array[Json]], bodies : Array[Json], without? : Array[String] = []) -> @lock.Roster {
  @lock.roster_without(ws, root, chains, bodies, without, c)
}

///|
/// Workspace `ws`'s tag in the person log of genesis hash `genesis` (lock.ts `wsTag`).
pub fn ws_tag(ws : String, genesis : String) -> String {
  @lock.ws_tag(ws, genesis, hashing)
}

///|
/// A statement's body's hash (lock.ts `bodyHash`); none where it has none.
pub fn body_hash(body : Json) -> String? {
  try Some(@lock.body_hash(body, hashing)) catch { _ => None }
}

///|
/// A commitment kept: its log's genesis hash and that log from its genesis to the entry.
pub(all) struct Commit {
  genesis : String
  chain : Array[Json]
}

///|
/// Why a keeper of workspace `ws` does not take `body`, or none (lock.ts `bodyRefusal`).
pub fn body_refusal(c : Crypto, ws : String, body : Json, commits : Array[Commit]) -> String? {
  @lock.body_refusal(ws, body, commits.map(x => { genesis: x.genesis, chain: x.chain }), c)
}

///|
/// A binding's digest and tag (rules `bind_digest_js`).
pub fn bind_digest(ws : String, sub : String, log : String, moved : String) -> (String, String) {
  (@lock.bind_tag, @lock.bind_digest(ws, sub, log, moved, hashing))
}

///|
/// The first member with this lower-case email, in the lock's order (lock.ts `memberWithEmail`).
pub fn member_with_email(s : @lock.LockState, email : String) -> @lock.Member? {
  for _, m in s.members {
    if m.email.to_lower() == email {
      return Some(m)
    }
  }
  None
}

///|
/// Every member with this lower-case email, in the lock's order (lock.ts `membersWithEmail`).
pub fn members_with_email(s : @lock.LockState, email : String) -> Array[@lock.Member] {
  s.members.values().filter(m => m.email.to_lower() == email).collect()
}

///|
/// The ids of a person's devices (lock.ts `devicesFor`).
pub fn devices_for(s : @lock.LockState, sub : String) -> Array[String] {
  s.devices.iter().filter(p => p.1.sub == sub).map(p => p.0).collect()
}

///|
/// A device's short code, from its base key (lock.ts `shortCode`).
pub fn short_code(base : String) -> String {
  let hash = sha256(utf8_of("stillfail-lock-code/1\u0000" + base))
  let alphabet = "23456789ABCDEFGHJKLMNPQRSTUVWXYZ"
  let out = StringBuilder()
  for i in 0..<6 {
    if i == 3 {
      out.write_char('-')
    }
    out.write_char(alphabet.unsafe_charcode_at(hash[i].to_int() % 32).unsafe_to_char())
  }
  out.to_string()
}

///|
/// A lock's state as plain JSON, its maps as [key, value] pairs in their order (rules/src/js `state_json`): what a test
/// compares with the TypeScript's.
pub fn state_json(s : @lock.LockState) -> Json {
  let device = (d : @lock.Device) => {
    let m : Map[String, Json] = Map([
      ("id", jstr(d.id)),
      ("sub", jstr(d.sub)),
      ("kind", jstr(d.kind)),
      ("label", jstr(d.label)),
      ("own", Json::boolean(d.own)),
    ])
    if d.sign_key is Some(k) {
      m["sign_key"] = jstr(k)
    }
    if d.endpoints is Some(es) {
      m["endpoints"] = jstrs(es)
    }
    if d.exp is Some(x) {
      m["exp"] = jnum(x)
    }
    if d.by is Some(b) {
      m["by"] = jstr(b)
    }
    Json::object(m)
  }
  let pairs = (xs : Array[(String, Json)]) => jarr(xs.map(p => jarr([jstr(p.0), p.1])))
  let out : Map[String, Json] = Map([
    ("ws", jstr(s.ws)),
    ("seq", jnum(s.seq)),
    ("head", jstr(s.head)),
    ("genesis", jstr(s.genesis)),
    ("origins", jstrs(s.origins)),
    ("rp_id", jstr(s.rp_id)),
    ("cloud_keys", s.cloud_keys),
    (
      "members",
      pairs(s.members.iter().map(p => (p.0, jobj([("sub", jstr(p.1.sub)), ("email", jstr(p.1.email)), ("role", jstr(p.1.role))]))).collect()),
    ),
    ("devices", pairs(s.devices.iter().map(p => (p.0, device(p.1))).collect())),
    ("signKeys", pairs(s.sign_keys.iter().map(p => (p.0, jstrs(p.1))).collect())),
    (
      "passkeys",
      pairs(s.passkeys.iter().map(p => (p.0, jobj([("id", jstr(p.1.id)), ("sub", jstr(p.1.sub)), ("key", jstr(p.1.key)), ("label", jstr(p.1.label)), ("own", Json::boolean(p.1.own))]))).collect()),
    ),
    ("signed", jstrs(s.signed.keys().collect())),
    ("stations", pairs(s.stations.iter().map(p => (p.0, jobj([("key", jstr(p.1.key)), ("name", jstr(p.1.name))]))).collect())),
    ("gateways", jstrs(s.gateways.keys().collect())),
    ("persons", pairs(s.persons.iter().map(p => (p.0, jstr(p.1))).collect())),
    ("disabled", Json::boolean(s.disabled)),
  ])
  if s.moved is Some(root) {
    out["moved"] = jstr(root)
  }
  Json::object(out)
}

///|
/// A person's lock as plain JSON (rules/src/js `person_json`).
pub fn person_json(p : @lock.Person) -> Json {
  let device = (d : @lock.PersonDevice) => {
    let m : Map[String, Json] = Map([
      ("key", jstr(d.key)),
      ("id", jstr(d.id)),
      ("label", jstr(d.label)),
      ("sign_keys", jstrs(d.sign_keys)),
    ])
    if d.sign_key is Some(k) {
      m["sign_key"] = jstr(k)
    }
    Json::object(m)
  }
  jobj([
    ("sub", jstr(p.sub)),
    ("genesis", jstr(p.genesis)),
    ("head", jstr(p.head)),
    ("seq", jnum(p.seq)),
    ("devices", jarr(p.devices.values().map(device).collect())),
    (
      "webs",
      jarr(p.webs.values().map(w => jobj([("id", jstr(w.id)), ("label", jstr(w.label)), ("at", jnum(w.at)), ("exp", jnum(w.exp))])).collect()),
    ),
  ])
}

///|
/// A list as plain JSON (rules/src/js `roster_json`).
pub fn roster_json(r : @lock.Roster) -> Json {
  let s = (x : String) => jstr(x)
  jobj([
    ("rooted", Json::boolean(r.rooted)),
    (
      "members",
      jarr(r.members.map(m => jobj([
        ("sub", s(m.sub)),
        ("role", s(m.role)),
        ("lock", s(m.lock)),
        ("admit", opt_str_json(m.admit)),
        (
          "keys",
          match m.keys {
            Some(ks) => jstrs(ks)
            None => Json::null()
          },
        ),
      ]))),
    ),
    ("stations", jstrs(r.stations)),
    ("pairs", jarr(r.pairs.map(p => jobj([("sub", s(p.0)), ("lock", s(p.1)), ("role", s(p.2))])))),
    ("undecided", jarr(r.undecided.map(p => jobj([("sub", s(p.0)), ("lock", s(p.1))])))),
    ("cancelled", jstrs(r.cancelled)),
    (
      "statements",
      jarr(r.statements.map(x => jobj([
        ("hash", s(x.hash)),
        ("kind", s(x.kind)),
        ("log", s(x.log)),
        ("by", s(x.by)),
        ("label", s(x.label)),
        ("why", opt_str_json(x.why)),
        ("decided", opt_str_json(x.decided)),
      ]))),
    ),
    ("labels", jarr(r.labels.map(p => jarr([s(p.0), s(p.1)])))),
    ("refused", jarr(r.refused.map(p => jobj([("genesis", s(p.0)), ("why", s(p.1))])))),
    ("in_force", jarr(r.in_force.map(p => jobj([("entry", s(p.0)), ("body", s(p.1))])))),
    ("lacking", jstrs(r.lacking)),
    ("newest", opt_str_json(r.newest)),
    ("settings", r.settings.unwrap_or(Json::null())),
    ("carried_keys", jarr(r.carried_keys.map(p => jobj([("key", s(p.0)), ("sub", s(p.1))])))),
  ])
}
