// What a station answers of its locks (station/src/mesh/serve.ts: GET and POST /lock, /lock/person, /lock/bodies,
// /lock/logs, /lock/heads, POST /lock/given; a refusal's `left` and `out`; the floor a core is too old under) and of
// a person's logs and a workspace's bodies to another station (station/src/mesh/person-sync.ts).

///|
/// A member's connection as admission let it in (mesh/credential.ts `Viewer`).
pub(all) struct Viewer {
  sub : String
  role : String
  workspace : String
  device : String
  /// Its base key and that key's proof of the endpoint, where its hello brought them.
  lock_device : (String, String)?
  /// The device's id in the lock, where the lock let it in by one.
  lock_id : String?
}

///|
/// A viewer as the TypeScript's object is given (`{sub, role, workspace, device, lockDevice?: {base, proof}, lockId?}`).
pub fn Viewer::of_json(v : Json) -> Viewer {
  let ld = match get(v, "lockDevice") {
    Some(d) =>
      match (text_at(d, "base"), text_at(d, "proof")) {
        (Some(b), Some(p)) => Some((b, p))
        _ => None
      }
    None => None
  }
  {
    sub: text_at(v, "sub").unwrap_or(""),
    role: text_at(v, "role").unwrap_or(""),
    workspace: text_at(v, "workspace").unwrap_or(""),
    device: text_at(v, "device").unwrap_or(""),
    lock_device: ld,
    lock_id: text_at(v, "lockId"),
  }
}

///|
fn Viewer::who(self : Viewer) -> Who {
  { sub: self.sub, endpoint: self.device, base: self.lock_device.map(p => p.0), proof: self.lock_device.map(p => p.1) }
}

///|
/// `ws` when it is a workspace the station joined, none for its home one (serve.ts `joinedOf`).
fn joined_ws(cloud : Cloud, ws : String) -> String? {
  if ws != "" && Some(ws) != cloud.home() {
    Some(ws)
  } else {
    None
  }
}

///|
/// A hello's proof of its endpoint by its base key (serve.ts `lockProof`).
fn lock_proof(v : Json?) -> (String, String)? {
  match (field(v, "device"), field(v, "proof")) {
    (Some(String(d)), Some(String(p))) if d.length() == 64 && p.length() == 128 => Some((d, p))
    _ => None
  }
}

///|
/// How many devices a refusal names to ask at most.
let approvers_most : Int = 16

///|
/// What a device refused where `ws`'s chain moved is told when the state in force does not name it: whom to ask, and
/// whether its person has an app device there (serve.ts `leftOf`): `{approvers, apps}`.
pub fn left_of(cloud : Cloud, ws : String?, device : String, hello : Json?, sub : String) -> Json? {
  guard cloud.chain(ws~) is Some({ state: Some({ moved: Some(_), .. }), .. }) else { return None }
  guard cloud.locked(ws~) is Some(locked) && !locked.waiting && locked.state is Some(s) else { return None }
  let ids = [device]
  if lock_proof(field(hello, "lock")) is Some((base, proof)) &&
    cloud.crypto.endpoint_ok(ws.unwrap_or(cloud.home().unwrap_or("")), base, device, proof) {
    ids.push(base)
  }
  if ids.iter().any(id => s.devices.contains(id)) {
    return None
  }
  let named = s.members.contains(sub)
  let approvers = s.devices
    .values()
    .filter(d => {
      d.kind == "app" &&
      (if named {
        d.sub == sub
      } else {
        match s.members.get(d.sub) {
          Some(m) => m.role == "owner" || m.role == "admin"
          None => false
        }
      })
    })
    .map(d => d.id)
    .take(approvers_most)
    .collect()
  let apps = s.devices.values().any(d => d.kind == "app" && d.sub == sub)
  Some(jobj([("approvers", jstrs(approvers)), ("apps", Json::boolean(apps))]))
}

///|
/// How much of what took a device out a refusal tells at most.
let refusal_out_bytes : Int = 32 * 1024

///|
/// What a device refused where `ws`'s chain moved is told of what took it out (serve.ts `toldOut`): `{bodies, logs}`.
pub fn told_out(cloud : Cloud, ws : String?, device : String, hello : Json?) -> Json? {
  guard cloud.chain(ws~) is Some({ state: Some({ moved: Some(_), .. } as chain), .. }) else { return None }
  let ids = [device]
  if lock_proof(field(hello, "lock")) is Some((base, proof)) &&
    cloud.crypto.endpoint_ok(ws.unwrap_or(cloud.home().unwrap_or("")), base, device, proof) {
    push_unique(ids, base)
  }
  let keys = ids.copy()
  for id in ids {
    if chain.devices.get(id) is Some({ sign_key: Some(k), .. }) {
      push_unique(keys, k)
    }
  }
  for p in cloud.person_chains().every() {
    for e in p.1 {
      let d = match kind_of(e) {
        "genesis" => field(body_of(e), "device")
        "device" => body_of(e)
        _ => None
      }
      match (field(d, "id"), field(d, "key")) {
        (Some(String(id)), Some(String(k))) if ids.contains(id) => push_unique(keys, k)
        _ => ()
      }
    }
  }
  let hashes = []
  for k in keys {
    match cloud.given_to(ws, k) {
      All => return None
      Only(hs) =>
        for h in hs {
          push_unique(hashes, h)
        }
    }
  }
  if hashes.length() == 0 {
    return None
  }
  let kept = cloud.bodies(ws).all()
  let bodies = hashes.filter_map(h => kept.get(h))
  let logs = []
  for p in cloud.person_chains().every() {
    let mut last = -1
    for i, e in p.1 {
      if kind_of(e) == "ws" {
        let h = match field(body_of(e), "h") {
          Some(String(x)) => x
          Some(v) => stringify(v)
          None => "undefined"
        }
        if hashes.contains(h) {
          last = i
        }
      }
    }
    if last >= 0 {
      logs.push(jobj([("genesis", jstr(p.0)), ("entries", jarr(p.1[0:last + 1].to_owned()))]))
    }
  }
  let out = jobj([("bodies", jarr(bodies)), ("logs", jarr(logs))])
  if stringify(out).length() <= refusal_out_bytes {
    Some(out)
  } else {
    None
  }
}

///|
/// How much of a person's own lock a refusal tells at most.
let refusal_person_bytes : Int = 32 * 1024

///|
/// How much of the workspace's lock a refusal tells at most.
let refusal_entries_bytes : Int = 16 * 1024

///|
/// The workspace a hello's credential names, as it says (serve.ts `claimed`).
fn claimed(hello : Json?) -> String {
  let cred = match field(hello, "credential") {
    Some(String(s)) => s
    Some(Null) | None => ""
    Some(v) => stringify(v)
  }
  let parts = cred.split(".").collect()
  let payload = if parts.length() > 1 { parts[1].to_string() } else { "" }
  match parse(@utf8.decode_lossy(b64_bytes(payload))) {
    Some(v) =>
      match get(v, "ws") {
        Some(String(w)) => w
        _ => ""
      }
    None => ""
  }
}

///|
/// What a hello the lock refused (`why`) is answered (serve.ts `refusalOf`, a LockRefusal's): the code the device asks
/// to be approved by, how far the lock goes here, its person's chains, the last entries, and where its chain moved
/// what took it out and whom to ask. `sub`: whose credential checked out.
pub fn lock_refusal(cloud : Cloud, hello : Json?, device : String, why : String, sub : String?) -> Json {
  let ws = joined_ws(cloud, claimed(hello))
  let chains = match sub {
    None => []
    Some(s) => own_chains_of(cloud, s, Some(claimed(hello))).map(p => jobj([("genesis", jstr(p.0)), ("entries", jarr(p.1))]))
  }
  let out = [("error", jstr(why)), ("code", jstr("lock_unconfirmed")), ("lock", lock_head(cloud, ws))]
  if chains.length() > 0 && stringify(jarr(chains)).length() <= refusal_person_bytes {
    out.push(("person", jarr(chains)))
  }
  let tail = []
  if sub is Some(_) {
    let mut bytes = 0
    let all = cloud.lock_after(-1.0, ws~)
    for i = all.length() - 1; i >= 0; i = i - 1 {
      bytes += stringify(all[i]).length()
      if bytes > refusal_entries_bytes {
        break
      }
      tail.insert(0, all[i])
    }
  }
  if tail.length() > 0 {
    out.push(("entries", jarr(tail)))
  }
  if sub is Some(s) {
    if told_out(cloud, ws, device, hello) is Some(o) {
      out.push(("out", o))
    }
    if left_of(cloud, ws, device, hello, s) is Some(l) {
      out.push(("left", l))
    }
  }
  jobj(out)
}

///|
/// Whether a device's connection is given `ws`'s bodies and logs (serve.ts `givesDevice`).
pub fn gives_device(cloud : Cloud, ws : String?, viewer : Viewer) -> Bool {
  ignore(viewer)
  match cloud.locked(ws~) {
    Some(l) => return !l.waiting
    None => ()
  }
  guard cloud.list(ws) is Some(li) && li.state is Some(s) && !li.waiting && s.moved is None else { return false }
  guard cloud.chain(ws~) is Some({ state: Some({ moved: Some(_), .. }), .. }) else { return false }
  s.disabled
}

///|
/// How many bodies one request brings at most.
let bodies_most : Int = 1024

///|
/// Bodies a device of the viewer's workspace brings (serve.ts `bodiesTaken`): `{taken, refused?}`.
fn bodies_taken(cloud : Cloud, viewer : Viewer, bodies : Array[Json]) -> Json {
  let ws = joined_ws(cloud, viewer.workspace)
  if cloud.chain(ws~) is None || bodies.length() > bodies_most {
    let n = if bodies.length() < bodies_most { bodies.length() } else { bodies_most }
    return jobj([
      ("taken", jnum(0.0)),
      ("refused", jarr(bodies[0:n].to_owned().map(_ => jobj([("hash", Json::null()), ("why", jstr("this workspace keeps no statements here"))])))),
    ])
  }
  let (taken, refused) = cloud.take_bodies(ws, bodies)
  let out = [("taken", jnum(taken.to_double()))]
  if refused.length() > 0 {
    out.push(("refused", jarr(refused.map(r => r.to_json()))))
  }
  jobj(out)
}

///|
/// The build a request's headers say (api/oldest.ts `buildOf`): `0.<n>.<build>` or `<build>`.
pub fn build_of(said : String?) -> Int? {
  guard said is Some(s) else { return None }
  let t = s.trim(chars=" \t\n\r\u000b\u000c ﻿").to_string()
  let digits = (x : String) => x != "" && x.iter().all(c => c >= '0' && c <= '9')
  let parts = t.split(".").map(p => p.to_string()).collect()
  let last = match parts {
    [b] if digits(b) => Some(b)
    [z, m, b] if z == "0" && digits(m) && digits(b) => Some(b)
    _ => None
  }
  match last {
    Some(b) => try Some(@string.parse_int(b)) catch { _ => None }
    None => None
  }
}

///|
/// A request of `viewer` saying `build`: kept by the device's id in the lock, where it has one (serve.ts `sawBuild`).
pub fn saw_build(cloud : Cloud, builds : DeviceBuilds, viewer : Viewer, build : Int?) -> Int? {
  if viewer.lock_id is Some(id) {
    builds.saw(id, build, (cloud.now)())
  }
  build
}

///|
/// The build under which a core of a release is too old in `workspace` here (serve.ts `movedFloor`): none where its
/// chain did not move.
pub fn moved_floor(cloud : Cloud, workspace : String) -> Int? {
  let ws = joined_ws(cloud, workspace)
  guard cloud.chain(ws~) is Some({ state: Some({ moved: Some(_), .. }), .. }) else { return None }
  let mut floor = if cloud.root_out(ws) { root_out_from_build } else { moved_from_build }
  if cloud.needs(ws).length() > logs_before && logs_any_from_build > floor {
    floor = logs_any_from_build
  }
  Some(floor)
}

///|
/// Whether a core saying `build` is too old for its workspace here (serve.ts `movedTooOld`).
pub fn moved_too_old(cloud : Cloud, workspace : String, build : Int?) -> Bool {
  guard build is Some(b) && b >= counted_from else { return false }
  match moved_floor(cloud, workspace) {
    Some(f) => b < f
    None => false
  }
}

///|
/// The ids of the devices workspace `ws`'s lock here names (serve.ts `lockDeviceIds`).
fn lock_device_ids(cloud : Cloud, ws : String?) -> Array[String] {
  let out = []
  if cloud.chain(ws~) is Some({ state: Some(s), .. }) {
    for id, _ in s.devices {
      push_unique(out, id)
    }
  }
  if cloud.locked(ws~) is Some({ state: Some(s), .. }) {
    for id, _ in s.devices {
      push_unique(out, id)
    }
  }
  out
}

///|
/// The ids of the app devices on `sub`'s own log, as each chain of it kept here says (serve.ts `personDeviceIds`).
fn person_device_ids(cloud : Cloud, sub : String) -> Array[String] {
  let out = []
  for p in cloud.person_chains().of(sub) {
    match (try Ok(person_fold(cloud.crypto, p.1, sub)) catch { e => Err(e) }) {
      Ok(person) =>
        for _, d in person.devices {
          push_unique(out, d.id)
        }
      Err(_) => ()
    }
  }
  out
}

///|
/// How far this station's lock goes in `ws`: `{seq, hash, genesis}`, null where none is pinned (serve.ts `lockHead`).
pub fn lock_head(cloud : Cloud, ws : String?) -> Json {
  match cloud.chain(ws~) {
    Some({ state: Some(s), .. }) => jobj([("seq", jnum(s.seq)), ("hash", jstr(s.head)), ("genesis", jstr(s.genesis))])
    _ => Json::null()
  }
}

///|
/// What a station serves of the locks (GET /lock `serves`).
pub let lock_serves : Array[String] = [
  "person", "devices", "told", "forks", "bodies", "logs", "builds", "carried", "bind", "rootout", "heads",
]

///|
/// GET and POST /lock (serve.ts `lockRoute`): its status and answer. `query` the URL's, `body` the request's text.
pub fn lock_route(cloud : Cloud, builds : DeviceBuilds, verb : String, query : Array[(String, String)], body : String, viewer : Viewer) -> (Int, Json) {
  let ws = joined_ws(cloud, viewer.workspace)
  if verb == "GET" {
    let after_said = match query.search_by(p => p.0 == "after") {
      Some(i) => js_number(Some(jstr(query[i].1)))
      None => -1.0
    }
    let from = if safe_int(after_said) { after_said } else { -1.0 }
    let out = [("head", lock_head(cloud, ws)), ("entries", jarr(cloud.lock_after(from, ws~)))]
    if from >= 0.0 {
      match cloud.lock_after(from - 1.0, ws~).get(0) {
        Some(at) if seq_of(at) == from => out.push(("after_hash", jstr(hash_of(at))))
        _ => ()
      }
    }
    out.push(("takes", jstrs(["person"])))
    out.push(("serves", jstrs(lock_serves)))
    out.push(("builds", builds.of(lock_device_ids(cloud, ws))))
    return (200, jobj(out))
  }
  if verb != "POST" {
    return (405, jobj([("error", jstr("GET or POST"))]))
  }
  let said = if body == "" { Some(jobj([])) } else { parse(body) }
  guard said is Some(said) else { return (400, jobj([("error", jstr("invalid JSON"))])) }
  let with_logs = get(said, "logs")
  let with_bodies = get(said, "bodies")
  let keep = get(said, "keep") is Some(True)
  if get(said, "person") is Some(Array(chain)) {
    return person_told(cloud, ws, viewer, chain, keep)
  }
  let entries = match get(said, "entries") {
    Some(Array(xs)) => xs.map(as_entry)
    _ => []
  }
  if entries.length() == 0 || entries.iter().any(e => e is None) {
    return (400, jobj([("error", jstr("entries: lock entries"))]))
  }
  let entries = entries.map(e => e.unwrap())
  let answered = try {
    if cloud.chain(ws~) is None {
      if viewer.role != "owner" {
        return (403, jobj([("error", jstr("only the workspace's owner turns its lock on"))]))
      }
      if entries.iter().any(e => kind_of(e) == "moved") {
        let workspace = if viewer.workspace != "" { viewer.workspace } else { cloud.home().unwrap_or("") }
        let me = match cloud.state {
          Some(s) => s.text("station")
          None => ""
        }
        pin_brought(cloud, ws, workspace, entries, with_logs, with_bodies, viewer.who(), me) catch {
          e => return (403, jobj([("error", jstr(why_of(e)))]))
        }
        return (200, jobj([("taken", jnum(entries.length().to_double())), ("head", lock_head(cloud, ws))]))
      }
      let now = (cloud.now)()
      let brought = fold(cloud.crypto, entries, Some(now))
      admit(cloud.crypto, brought, viewer.who(), now) |> ignore
      if brought.members.get(viewer.sub).map(m => m.role) != Some("owner") {
        return (403, jobj([("error", jstr("the lock is brought by its owner"))]))
      }
    }
    let t = cloud.keep_lock(entries, ws~, fork=keep)
    let head = lock_head(cloud, ws)
    let with_off = (out : Array[(String, Json)]) => {
      if t.off.length() > 0 {
        out.push(("off", jarr(t.off.map(o => o.to_json()))))
      }
      jobj(out)
    }
    let h = hash_of(entries[entries.length() - 1])
    if cloud.lock_after(-1.0, ws~).iter().any(e => hash_of(e) == h) {
      return (200, with_off([("taken", jnum(t.taken.to_double())), ("head", head)]))
    }
    let why = match t.off.search_by(o => o.hash == h) {
      Some(i) => Some(t.off[i].why)
      None => None
    }
    if why == Some("beaten") || why == Some("below") || why == Some("again") {
      return (409, with_off([("error", jstr(fork_words)), ("head", head)]))
    }
    if t.taken > 0 {
      return (200, with_off([("taken", jnum(t.taken.to_double())), ("head", head)]))
    }
    (409, with_off([("error", jstr(t.refusal.unwrap_or(fork_words))), ("head", head)]))
  } catch {
    e => (409, jobj([("error", jstr(why_of(e))), ("head", lock_head(cloud, ws))]))
  }
  answered
}

///|
/// A chain as it is brought, checked by the rules for its person: its genesis and whose (person-sync.ts `foldChain`).
pub fn fold_chain(c : Crypto, chain : Json?, sub : String?) -> (String, String) raise Failure {
  guard chain is Some(Array(xs)) && xs.length() > 0 && xs.length() <= chain_most else {
    raise Failed("a person's lock: its entries")
  }
  guard sub_of(xs) is Some(whose) && (sub is None || sub == Some(whose)) else { raise Failed("a lock of another person's") }
  (person_fold(c, xs, whose).genesis, whose)
}

///|
/// A chain brought, taken (person-sync.ts `takeChain`): its genesis and what was taken.
pub fn take_chain(cloud : Cloud, chain : Json?, sub : String?, ws : String?, fork : Bool) -> (String, PersonTook) raise Failure {
  let (genesis, whose) = fold_chain(cloud.crypto, chain, sub)
  let xs = if chain is Some(Array(xs)) { xs } else { [] }
  (genesis, cloud.person_chains().take(genesis, whose, xs, ws~, fork~))
}

///|
/// How far a person's chain gone by goes (serve.ts `personHead`).
fn person_head(chain : Array[Json]) -> Json {
  jobj([
    ("seq", jnum((chain.length() - 1).to_double())),
    (
      "hash",
      match chain.last() {
        Some(e) => jstr(hash_of(e))
        None => Json::null()
      },
    ),
  ])
}

///|
fn person_told(cloud : Cloud, ws : String?, viewer : Viewer, chain : Array[Json], keep : Bool) -> (Int, Json) {
  guard cloud.locked(ws~) is Some({ state: Some(s), .. }) && s.persons.get(viewer.sub) is Some(pin) else {
    return (409, jobj([("error", jstr("no lock of their own bound here"))]))
  }
  let answered = try {
    if person_fold(cloud.crypto, chain, viewer.sub).genesis != pin {
      return (409, jobj([("error", jstr("not the lock bound here"))]))
    }
    let (_, t) = take_chain(cloud, Some(jarr(chain)), Some(viewer.sub), Some(viewer.workspace), keep)
    let out = []
    if !t.on {
      out.push(("error", jstr(at_odds)))
      out.push(("head", person_head(t.chain)))
    }
    if t.off.length() > 0 {
      out.push(("off", jarr(t.off.map(o => o.to_json()))))
    }
    (if t.on { 200 } else { 409 }, jobj(out))
  } catch {
    e => (409, jobj([("error", jstr(why_of(e)))]))
  }
  answered
}

///|
/// The chains of `sub`'s own lock this station keeps, as a device of theirs asking in `workspace` is told them
/// (serve.ts `ownChainsOf`).
pub fn own_chains_of(cloud : Cloud, sub : String, workspace : String?) -> Array[(String, Array[Json])] {
  let all = cloud.person_chains().of(sub)
  let ws = match workspace {
    Some(w) => joined_ws(cloud, w)
    None => None
  }
  guard cloud.chain(ws~) is Some({ state: Some({ moved: Some(root), .. }), .. }) else { return all }
  match cloud.locked(ws~) {
    Some({ state: Some(s), .. }) =>
      match s.persons.get(sub) {
        Some(bound) if bound != root => all.filter(p => p.0 != root)
        _ => all
      }
    _ => all
  }
}

///|
/// The parts of /lock (serve.ts `lockPartRoute`): `person` (GET, POST), `bodies` (GET, POST), `logs` (GET), `heads`
/// (GET), `given` (POST). `devices` is the seen devices' (mesh/seen-devices.ts), not the lock's.
pub fn lock_part_route(cloud : Cloud, builds : DeviceBuilds, part : String, verb : String, body : String, viewer : Viewer) -> (Int, Json) {
  let said_of = () => if body == "" { Some(jobj([])) } else { parse(body) }
  if part == "person" {
    if verb == "GET" {
      let chains = own_chains_of(cloud, viewer.sub, Some(viewer.workspace)).map(p => jobj([("genesis", jstr(p.0)), ("entries", jarr(p.1))]))
      return (
        200,
        jobj([
          ("chains", jarr(chains)),
          ("serves", jstrs(["logs", "builds", "carried", "bind", "rootout"])),
          ("builds", builds.of(person_device_ids(cloud, viewer.sub))),
        ]),
      )
    }
    if verb != "POST" {
      return (405, jobj([("error", jstr("GET or POST"))]))
    }
    guard said_of() is Some(said) else { return (400, jobj([("error", jstr("invalid JSON"))])) }
    let answered = try {
      let (genesis, t) = take_chain(cloud, get(said, "chain"), Some(viewer.sub), Some(viewer.workspace), get(said, "keep") is Some(True))
      let bodies = match get(said, "bodies") {
        Some(Array(bs)) => entries_of_obj(Some(bodies_taken(cloud, viewer, bs)))
        _ => []
      }
      let off = if t.off.length() > 0 { [("off", jarr(t.off.map(o => o.to_json())))] } else { [] }
      if !t.on {
        (409, jobj([("error", jstr(at_odds)), ("head", person_head(t.chain))] + off + bodies))
      } else {
        (200, jobj([("genesis", jstr(genesis)), ("length", jnum(t.chain.length().to_double()))] + off + bodies))
      }
    } catch {
      e => (409, jobj([("error", jstr(why_of(e)))]))
    }
    return answered
  }
  let ws = if (part == "bodies" || part == "logs" || part == "heads" || part == "given") {
    joined_ws(cloud, viewer.workspace)
  } else {
    None
  }
  if part == "bodies" {
    if verb == "GET" {
      if !gives_device(cloud, ws, viewer) {
        return (200, jobj([("bodies", jarr([])), ("lacking", jarr([]))]))
      }
      return (200, jobj([("bodies", jarr(cloud.bodies(ws).all().values().collect())), ("lacking", jstrs(cloud.lacking(ws)))]))
    }
    if verb != "POST" {
      return (405, jobj([("error", jstr("GET or POST"))]))
    }
    guard said_of() is Some(said) else { return (400, jobj([("error", jstr("invalid JSON"))])) }
    guard get(said, "bodies") is Some(Array(bs)) && bs.length() <= bodies_most else {
      return (400, jobj([("error", jstr("bodies: the statements' bodies"))]))
    }
    return (200, bodies_taken(cloud, viewer, bs))
  }
  if part == "logs" && verb == "GET" {
    if !gives_device(cloud, ws, viewer) {
      return (200, jobj([("chains", jarr([]))]))
    }
    return (200, jobj([("chains", jarr(logs_given(cloud, ws, None)))]))
  }
  if part == "heads" && verb == "GET" {
    if !gives_device(cloud, ws, viewer) {
      return (200, jobj([("logs", jarr([])), ("bodies", jarr([])), ("lacking", jarr([]))]))
    }
    let chains = cloud.person_chains()
    let logs = cloud
      .logs_of(ws)
      .filter_map(g => match chains.kept(g) {
        Some(es) if es.length() > 0 => Some(jarr([jstr(g), jstr(hash_of(es[es.length() - 1]))]))
        _ => None
      })
    return (
      200,
      jobj([("logs", jarr(logs)), ("bodies", jstrs(cloud.bodies(ws).all().keys().collect())), ("lacking", jstrs(cloud.lacking(ws)))]),
    )
  }
  if part == "given" {
    if verb != "POST" {
      return (405, jobj([("error", jstr("POST"))]))
    }
    guard said_of() is Some(said) else { return (400, jobj([("error", jstr("invalid JSON"))])) }
    let strings = (x : Json?) => match x {
      Some(Array(xs)) => xs.filter_map(y => if y is String(s) { Some(s) } else { None })
      _ => []
    }
    let logs = strings(get(said, "logs"))
    let hashes = strings(get(said, "bodies"))
    if !gives_device(cloud, ws, viewer) {
      return (200, jobj([("chains", jarr([])), ("bodies", jarr([]))]))
    }
    let all = cloud.bodies(ws).all()
    let unique = []
    for h in hashes {
      push_unique(unique, h)
    }
    return (
      200,
      jobj([
        ("chains", jarr(if logs.length() == 0 { [] } else { logs_given(cloud, ws, Some(logs)) })),
        ("bodies", jarr(unique.filter_map(h => all.get(h)))),
      ]),
    )
  }
  (404, jobj([("error", jstr("no such route"))]))
}

///|
/// The person logs of `ws` a device is given, those of `only` alone where it says (serve.ts `logsGiven`).
fn logs_given(cloud : Cloud, ws : String?, only : Array[String]?) -> Array[Json] {
  let chains = cloud.person_chains()
  cloud
  .logs_of(ws)
  .filter_map(g => {
    if only is Some(o) && !o.contains(g) {
      return None
    }
    match chains.kept(g) {
      Some(es) => Some(jobj([("genesis", jstr(g)), ("entries", jarr(es))]))
      None => None
    }
  })
}

// ── between the stations (mesh/person-sync.ts) ─────────────────────────────────────────────────────────────────────

///|
/// What this station gives station `peer` of workspace `ws`'s bodies (person-sync.ts `bodiesGiven`).
pub fn bodies_given(cloud : Cloud, ws : String, peer : String) -> Map[String, Json] {
  let w = if Some(ws) == cloud.home() { None } else { Some(ws) }
  let all = cloud.bodies(w).all()
  match cloud.given_to(w, peer) {
    All => all
    Only(hs) => {
      let out : Map[String, Json] = Map([])
      for h in hs {
        if all.get(h) is Some(b) {
          out[h] = b
        }
      }
      out
    }
  }
}

///|
/// A bodies request of station `peer` of workspace `ws` (person-sync.ts `answerBodies`).
pub fn answer_bodies(cloud : Cloud, request : Json, ws : String, peer : String?) -> Json raise Failure {
  let w = if Some(ws) == cloud.home() { None } else { Some(ws) }
  match text_at(request, "method") {
    Some("lock.bodies.kept") =>
      jobj([
        (
          "hashes",
          jstrs(
            match peer {
              None => []
              Some(p) => bodies_given(cloud, ws, p).keys().collect()
            },
          ),
        ),
      ])
    Some("lock.bodies.get") => {
      let given = match peer {
        None => Map([])
        Some(p) => bodies_given(cloud, ws, p)
      }
      let want = match get(request, "hashes") {
        Some(Array(xs)) => xs.filter_map(h => if h is String(s) { Some(s) } else { None })
        _ => []
      }
      jobj([("bodies", jarr(want.filter_map(h => given.get(h))))])
    }
    Some("lock.bodies.offer") => {
      let bodies = array_at(request, "bodies").unwrap_or([])
      if bodies.length() > 4096 {
        raise Failed("too many bodies")
      }
      jobj([("taken", jnum(cloud.take_bodies(w, bodies).0.to_double()))])
    }
    _ => raise Failed("unknown lock method")
  }
}

///|
/// A person's lock request of another station of workspace `ws` (person-sync.ts `answerPerson`).
pub fn answer_person(cloud : Cloud, request : Json, ws : String) -> Json raise Failure {
  let chains = cloud.person_chains()
  match text_at(request, "method") {
    Some("lock.person.heads") =>
      jobj([("heads", jobj(chains.heard_in(ws).map(p => (p.0, jnum(p.1.length().to_double())))))])
    Some("lock.person.get") => {
      let found = chains.heard_in(ws).iter().find_first(p => Some(p.0) == text_at(request, "genesis"))
      if get(request, "hashes") is Some(Array(hs)) {
        let want = hs.filter_map(h => if h is String(s) { Some(s) } else { None })
        return jobj([
          (
            "entries",
            jarr(match found {
              None => []
              Some(p) => chains.all(p.0).filter(e => want.contains(hash_of(e)))
            }),
          ),
        ])
      }
      jobj([
        (
          "chain",
          match found {
            Some(p) => jarr(p.1)
            None => Json::null()
          },
        ),
      ])
    }
    Some("lock.person.put") => {
      let (_, t) = take_chain(cloud, get(request, "chain"), None, Some(ws), true)
      if !t.on {
        raise Refused(at_odds)
      }
      jobj([("length", jnum(t.chain.length().to_double()))])
    }
    Some("lock.person.kept") =>
      jobj([("logs", jobj(chains.heard_in(ws).map(p => (p.0, jstrs(chains.all(p.0).map(hash_of))))))])
    Some("lock.person.offer") => {
      let genesis = text_at(request, "genesis").unwrap_or("")
      let entries = match get(request, "entries") {
        Some(Array(xs)) => xs.map(as_entry)
        _ => []
      }
      if entries.length() == 0 || entries.iter().any(e => e is None) {
        raise Failed("a malformed lock entry")
      }
      let entries = entries.map(e => e.unwrap())
      guard sub_of(entries) is Some(sub) && entries.length() <= chain_most + aside_most else {
        raise Failed("a person's lock: its entries")
      }
      let t = chains.take(genesis, sub, entries, ws=Some(ws), fork=true)
      jobj([("taken", jnum(t.taken.to_double())), ("head", person_head(t.chain))])
    }
    _ => raise Failed("unknown lock method")
  }
}
