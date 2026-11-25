// Who a member's connection is let in as (station/src/mesh/serve.ts): the credential checked, then the lock of its
// workspace, a device it names (or its person's own lock, for an app device bound to one), its role the lower of the
// lock's and the credential's; what a refused hello is told; what a device brings with its hello (entries that put it
// in the lock, a moved workspace's root log and bodies) taken first.

///|
/// A hello's `lock: {device, proof}`: the device's base key, and its signature saying this endpoint is its own.
pub fn lock_proof(v : Json?) -> (String, String)? {
  match v {
    Some({ "device": String(d), "proof": String(p), .. }) if d.length() == 64 && p.length() == 128 => Some((d, p))
    _ => None
  }
}

///|
fn field(j : Json, k : String) -> Json? {
  match j {
    Object(m) => m.get(k)
    _ => None
  }
}

///|
fn path_of(j : Json, keys : Array[String]) -> Json? {
  let mut at = Some(j)
  for k in keys {
    at = match at {
      Some(v) => field(v, k)
      None => None
    }
  }
  at
}

///|
/// How many entries a hello may bring.
pub let brought_most : Int = 64

///|
/// `ws` when it is a workspace the station joined, None for its home one.
pub async fn joined_of(k : Keeper, ws : String) -> String? {
  if ws != "" && Some(ws) != (k.home)() {
    Some(ws)
  } else {
    None
  }
}

///|
/// The entries a device brings with its hello (`lock.entries`), taken onto the workspace's own chain where they could
/// let this very device in; whether any was.
pub async fn brought(k : Keeper, hello : Json, workspace : String, base : String?) -> Bool {
  guard base is Some(base) else { return false }
  guard path_of(hello, ["lock", "entries"]) is Some(Array(raw)) else { return false }
  if raw.length() == 0 || raw.length() > brought_most {
    return false
  }
  let entries = []
  for r in raw {
    match (k.as_entry)(r) {
      Some(e) => entries.push(e)
      None => return false
    }
  }
  let ws = joined_of(k, workspace)
  let (_, state) = (k.chain)(ws)
  guard state is Some(state) && state.moved is None else { return false }
  let seq_of = (e : Json) => match field(e, "seq") { Some(Number(n, ..)) => n.to_int(); _ => -1 }
  if seq_of(entries[0]) > state.seq + 1 {
    return false
  }
  for i in 1..<entries.length() {
    if seq_of(entries[i]) != seq_of(entries[i - 1]) + 1 {
      return false
    }
  }
  if !entries.iter().any(e => seq_of(e) > state.seq &&
      field(e, "kind") == Some(Json::string("device")) &&
      path_of(e, ["body", "id"]) == Some(Json::string(base))) {
    return false
  }
  ((k.take_lock)(entries, ws) > 0) catch {
    e => {
      @door.log("info", "lock", "a device brought lock entries this station does not take", { "error": Json::string(words_of(e)) })
      false
    }
  }
}

///|
/// What an error says.
pub fn words_of(e : Error) -> String {
  match e {
    LockRefusal(m) => m
    Refused(m) => m
    PeerRefused(m) | NoLink(m) | NoBytes(m) | WaysRefusal(m) | MarkRefusal(m) => m
    PeerGone(m, _) => m
    HttpRefusal(_, m, _) | DeviceRefused(_, m) => m
    e => @door.message_of(e)
  }
}

///|
/// Where a workspace's chain moved and this station waits for what its state is made of: what a hello brings of it, the
/// root's log (`lock.person`) and statements' bodies (`lock.bodies`), taken as any are; whether any was.
pub async fn brought_for_state(k : Keeper, hello : Json, workspace : String) -> Bool {
  let ws = joined_of(k, workspace)
  let (_, chain) = (k.chain)(ws)
  guard chain is Some(c) && c.moved is Some(root) else { return false }
  guard (k.locked)(ws) is Some(l) && l.waiting else { return false }
  let mut any = false
  if path_of(hello, ["lock", "person"]) is Some(Array(log)) && log.length() > 0 && log.length() <= brought_most {
    try {
      let (genesis, whose) = fold_chain(k, Json::array(log), None)
      if genesis == root {
        any = (k.person_take)(genesis, whose, log, Some(workspace), false).taken > 0 || any
      }
    } catch {
      _ => ()
    }
  }
  if path_of(hello, ["lock", "bodies"]) is Some(Array(bodies)) && bodies.length() > 0 && bodies.length() <= brought_most {
    let (taken, _) = (k.take_bodies)(ws, bodies)
    any = taken > 0 || any
  }
  any
}

///|
/// What a device is told when this station takes none of its workspace's members for a security mode.
pub fn left_out_words(why : String) -> String {
  match why {
    "pending" => "this station has not pinned this workspace's lock yet: the control plane has not brought the one it joined with"
    "unpinned" => "this workspace turned its lock on after this station joined it: remove the station from it and add it again"
    _ => "this station's own workspace is locked and this one is not: it takes none of this one's members"
  }
}

///|
/// The workspace a hello's credential names, as it says.
pub fn claimed(hello : Json) -> String {
  match field(hello, "credential") {
    Some(String(c)) => claimed_ws(c)
    Some(Number(_, ..)) | Some(True) | Some(False) => ""
    _ => ""
  }
}

///|
fn credential_of(line : Json) -> String {
  match field(line, "credential") {
    Some(String(c)) => c
    _ => ""
  }
}

///|
/// Why a credential for a workspace this station joined is refused, when it is as the control plane signs them and that
/// workspace is left out for a lock; None otherwise.
pub async fn left_out_for(k : Keeper, hello : Json, device : String, accepted : Accepted) -> String? {
  let ws = claimed(hello)
  guard ws != "" else { return None }
  guard (k.left_out)(ws) is Some(why) else { return None }
  let revocations = (k.joined_revocations)(ws)
  let keys = (k.state_grant_keys)()
  try {
    ignore(verify_member_of(credential_of(hello), _ => keys, [{ workspace: ws, revocations }], device, (k.now_secs)(), k.verify, accepted~))
    Some(why)
  } catch {
    _ => None
  }
}

///|
/// How many devices a refusal names to ask at most.
pub let approvers_most : Int = 16

///|
/// How much of what took a device out a refusal tells at most.
pub let refusal_out_bytes : Int = 32 * 1024

///|
/// How much of a person's own lock a refusal tells at most.
pub let refusal_person_bytes : Int = 32 * 1024

///|
/// How much of the workspace's lock (its last entries) a refusal tells at most.
pub let refusal_entries_bytes : Int = 16 * 1024

///|
/// The length JavaScript's JSON.stringify gives (UTF-16 units of the text).
pub fn js_length(j : Json) -> Int {
  j.stringify().length()
}

///|
/// What a hello this station refused (`e`, why) is answered (serve.ts `refusalOf`).
pub async fn refusal_of(k : Keeper, hello : Json, device : String, e : Error, accepted : Accepted, sub : String?) -> Json {
  match e {
    LockRefusal(words) => {
      let ws = joined_of(k, claimed(hello))
      let m : Map[String, Json] = {
        "error": Json::string(words),
        "code": "lock_unconfirmed",
        "lock": lock_head_json(k, ws),
      }
      let chains = match sub {
        None => []
        Some(s) => own_chains_of(k, s, Some(claimed(hello))).map(c => ({ "genesis": Json::string(c.0), "entries": Json::array(c.1) } : Json))
      }
      if chains.length() > 0 && js_length(Json::array(chains)) <= refusal_person_bytes {
        m["person"] = Json::array(chains)
      }
      let tail = []
      if sub is Some(_) {
        let all = (k.lock_after)(-1, ws)
        let mut bytes = 0
        for i = all.length() - 1; i >= 0; i = i - 1 {
          bytes += js_length(all[i])
          if bytes > refusal_entries_bytes {
            break
          }
          tail.insert(0, all[i])
        }
      }
      if tail.length() > 0 {
        m["entries"] = Json::array(tail)
      }
      if sub is Some(s) {
        if told_out(k, ws, device, hello) is Some(out) {
          m["out"] = out
        }
        if left_of(k, ws, device, hello, s) is Some(left) {
          m["left"] = left
        }
      }
      Json::object(m)
    }
    _ =>
      match left_out_for(k, hello, device, accepted) {
        Some(why) => { "error": Json::string(left_out_words(why)), "code": "lock_station", "why": Json::string(why) }
        None => { "error": Json::string(words_of(e)) }
      }
  }
}

///|
/// The ids a refused device is known by: its endpoint, and its base key where its hello proves it.
async fn ids_of(k : Keeper, ws : String?, device : String, hello : Json) -> Array[String] {
  let ids = [device]
  if lock_proof(field(hello, "lock")) is Some((base, proof)) {
    let w = match ws { Some(w) => w; None => (k.home)().unwrap_or("") }
    if (k.endpoint_proof)(w, base, device, proof) {
      ids.push(base)
    }
  }
  ids
}

///|
/// Whom a device refused where `ws`'s chain moved may ask, when the state in force does not name it (serve.ts
/// `leftOf`).
pub async fn left_of(k : Keeper, ws : String?, device : String, hello : Json, sub : String) -> Json? {
  let (_, chain) = (k.chain)(ws)
  guard chain is Some(c) && c.moved is Some(_) else { return None }
  guard (k.locked)(ws) is Some(locked) && !locked.waiting && locked.state is Some(s) else { return None }
  let ids = ids_of(k, ws, device, hello)
  if ids.iter().any(id => s.devices.contains(id)) {
    return None
  }
  let named = s.members.contains(sub)
  let approvers = []
  for _, d in s.devices {
    if approvers.length() >= approvers_most {
      break
    }
    if d.kind == "app" &&
      (if named {
        d.sub == sub
      } else {
        let r = s.members.get(d.sub).unwrap_or("")
        r == "owner" || r == "admin"
      }) {
      approvers.push(Json::string(d.id))
    }
  }
  let apps = s.devices.values().any(d => d.kind == "app" && d.sub == sub)
  Some({ "approvers": Json::array(approvers), "apps": Json::boolean(apps) })
}

///|
/// What a device refused where `ws`'s chain moved is told of what took it out (serve.ts `toldOut`).
pub async fn told_out(k : Keeper, ws : String?, device : String, hello : Json) -> Json? {
  let (_, chain) = (k.chain)(ws)
  guard chain is Some(c) && c.moved is Some(_) else { return None }
  let ids = ids_of(k, ws, device, hello)
  let keys = ids.copy()
  for id in ids {
    if c.devices.get(id) is Some(d) && d.sign_key is Some(key) && !keys.contains(key) {
      keys.push(key)
    }
  }
  for chain in (k.person_every)() {
    for e in chain.1 {
      let d = match field(e, "kind") {
        Some(String("genesis")) => path_of(e, ["body", "device"])
        Some(String("device")) => field(e, "body")
        _ => None
      }
      match d {
        Some({ "id": String(id), "key": String(key), .. }) if ids.contains(id) && !keys.contains(key) => keys.push(key)
        _ => ()
      }
    }
  }
  let hashes = []
  for key in keys {
    match (k.given_to)(ws, key) {
      None => return None
      Some(given) =>
        for h in given {
          if !hashes.contains(h) {
            hashes.push(h)
          }
        }
    }
  }
  if hashes.length() == 0 {
    return None
  }
  let kept = Map::from_array((k.bodies)(ws))
  let bodies = hashes.filter_map(h => kept.get(h))
  let logs = []
  for chain in (k.person_every)() {
    let mut last = -1
    for i, e in chain.1 {
      if field(e, "kind") == Some(Json::string("ws")) {
        let h = match path_of(e, ["body", "h"]) {
          Some(String(h)) => h
          Some(v) => v.stringify()
          None => "undefined"
        }
        if hashes.contains(h) {
          last = i
        }
      }
    }
    if last >= 0 {
      logs.push(({ "genesis": Json::string(chain.0), "entries": Json::array(chain.1[0:last + 1].to_owned()) } : Json))
    }
  }
  let out : Json = { "bodies": Json::array(bodies), "logs": Json::array(logs) }
  if js_length(out) <= refusal_out_bytes {
    Some(out)
  } else {
    None
  }
}

///|
fn who_of(v : Viewer, endpoint : String) -> Who {
  {
    sub: v.sub,
    endpoint,
    base: v.lock_device.map(p => p.0),
    proof: v.lock_device.map(p => p.1),
  }
}

///|
/// Whether a device's connection is given `ws`'s bodies and logs (serve.ts `givesDevice`).
pub async fn gives_device(k : Keeper, ws : String?, viewer : Viewer) -> Bool {
  ignore(viewer)
  if (k.locked)(ws) is Some(locked) {
    return !locked.waiting
  }
  guard (k.list)(ws) is Some(li) && li.state is Some(s) else { return false }
  let (_, chain) = (k.chain)(ws)
  if li.waiting || s.moved is Some(_) || !(chain is Some(c) && c.moved is Some(_)) {
    return false
  }
  // `locked` is None while `list` is non-waiting on a moved chain only when the moved workspace is `off`:
  // any admitted member may pull the root log and bodies to verify `off` locally.
  true
}

///|
/// How many bodies one request brings at most.
pub let bodies_most : Int = 1024

///|
/// Bodies a device of the viewer's workspace brings, taken as the rules take them (serve.ts `bodiesTaken`).
pub async fn bodies_taken(k : Keeper, viewer : Viewer, bodies : Array[Json]) -> Json {
  let ws = joined_of(k, viewer.workspace)
  let (exists, _) = (k.chain)(ws)
  if !exists || bodies.length() > bodies_most {
    let n = if bodies.length() < bodies_most { bodies.length() } else { bodies_most }
    return {
      "taken": 0,
      "refused": Json::array(Array::make(n, ({ "hash": Json::null(), "why": "this workspace keeps no statements here" } : Json))),
    }
  }
  let (taken, refused) = (k.take_bodies)(ws, bodies)
  if refused.length() > 0 {
    { "taken": Json::number(taken.to_double()), "refused": Json::array(refused) }
  } else {
    { "taken": Json::number(taken.to_double()) }
  }
}

///|
/// The build in `0.<m>.<n>` (or `<n>`), None for none (api/oldest.ts `buildOf`).
pub fn build_of(said : String?) -> Int? {
  guard said is Some(s) else { return None }
  let t = s.trim(chars=" \t\n\r\u{a0}\u{feff}").to_owned()
  let digits = (x : String) => x.length() > 0 && x.iter().all(c => c >= '0' && c <= '9')
  let parts = t.split(".").map(p => p.to_owned()).collect()
  let n = match parts.length() {
    1 => if digits(parts[0]) { Some(parts[0]) } else { None }
    3 => if parts[0] == "0" && digits(parts[1]) && digits(parts[2]) { Some(parts[2]) } else { None }
    _ => None
  }
  match n {
    Some(d) => Some(@string.parse_int(d)) catch { _ => None }
    None => None
  }
}

///|
/// The build a request's headers say, None for none.
pub fn build_said(headers : Json) -> Int? {
  match headers {
    Object(m) => {
      for name, v in m {
        if name.to_lower() == "stillfail-build" {
          return match v { String(s) => build_of(Some(s)); _ => None }
        }
      }
      None
    }
    _ => None
  }
}

///|
/// Whether a core asking with these headers is older than the oldest answered (api/oldest.ts `coreTooOld`).
pub fn core_too_old(k : Keeper, headers : Json) -> Bool {
  if k.floors.oldest_core <= 0 {
    return false
  }
  match build_said(headers) {
    Some(b) => b >= k.floors.counted_from && b < k.floors.oldest_core
    None => false
  }
}

///|
/// A request of `viewer` with `headers`: the build it says kept by the device's id in the lock. The build said.
pub async fn saw_build(k : Keeper, viewer : Viewer, headers : Json) -> Int? {
  let build = build_said(headers)
  if viewer.lock_id is Some(id) {
    (k.builds_saw)(id, build, (k.now_secs)())
  }
  build
}

///|
/// Whether a core saying `build` is too old for its workspace here (serve.ts `movedTooOld`).
pub async fn moved_too_old(k : Keeper, viewer : Viewer, build : Int?) -> Bool {
  guard build is Some(b) && b >= k.floors.counted_from else { return false }
  match moved_floor(k, viewer.workspace) {
    Some(floor) => b < floor
    None => false
  }
}

///|
/// The build under which a core of a release is too old in `workspace` here (serve.ts `movedFloor`).
pub async fn moved_floor(k : Keeper, workspace : String) -> Int? {
  let ws = joined_of(k, workspace)
  let (_, chain) = (k.chain)(ws)
  guard chain is Some(c) && c.moved is Some(_) else { return None }
  let mut floor = if (k.root_out)(ws) { k.floors.root_out_from } else { k.floors.moved_from }
  if (k.needs)(ws) > k.floors.logs_before && k.floors.logs_any_from > floor {
    floor = k.floors.logs_any_from
  }
  Some(floor)
}

///|
/// The ids of the devices workspace `ws`'s lock here names.
pub async fn lock_device_ids(k : Keeper, ws : String?) -> Array[String] {
  let out = []
  let (_, chain) = (k.chain)(ws)
  if chain is Some(s) {
    for id, _ in s.devices {
      out.push(id)
    }
  }
  if (k.locked)(ws) is Some({ state: Some(s), .. }) {
    for id, _ in s.devices {
      if !out.contains(id) {
        out.push(id)
      }
    }
  }
  out
}

///|
/// The ids of the app devices on `sub`'s own log, as each chain of it kept here says.
pub async fn person_device_ids(k : Keeper, sub : String) -> Array[String] {
  let out = []
  for chain in (k.person_of)(sub) {
    try {
      let (_, devices) = (k.person_fold)(chain.1, Some(sub))
      for d in devices {
        if !out.contains(d) {
          out.push(d)
        }
      }
    } catch {
      _ => ()
    }
  }
  out
}

///|
/// How far this station's lock goes in `ws` (None: no lock pinned there).
pub async fn lock_head_json(k : Keeper, ws : String?) -> Json {
  match (k.chain)(ws) {
    (_, Some(s)) => { "seq": Json::number(s.seq.to_double()), "hash": Json::string(s.head), "genesis": Json::string(s.genesis) }
    _ => Json::null()
  }
}

///|
/// The chains of `sub`'s own lock this station keeps, as a device of theirs asking in workspace `workspace` is told
/// them (serve.ts `ownChainsOf`).
pub async fn own_chains_of(k : Keeper, sub : String, workspace : String?) -> Array[(String, Array[Json])] {
  let all = (k.person_of)(sub)
  let ws = match workspace {
    Some(w) => joined_of(k, w)
    None => None
  }
  let (_, chain) = (k.chain)(ws)
  guard chain is Some(c) && c.moved is Some(root) else { return all }
  let bound = match (k.locked)(ws) {
    Some({ state: Some(s), .. }) => s.persons.get(sub)
    _ => None
  }
  match bound {
    None => all
    Some(b) if b == root => all
    Some(_) => all.filter(c => c.0 != root)
  }
}

///|
/// With a lock pinned: the member admitted only on a device the lock names, with the lower of the lock's role and the
/// credential's (`named`). Without one, as the credential says. Raises a LockRefusal why not (serve.ts `inLock`).
pub async fn in_lock(k : Keeper, admitted : Admitted, named : String, endpoint : String, hello? : Json = Json::null()) -> Admitted {
  let ws = joined_of(k, admitted.viewer.workspace)
  guard (k.locked)(ws) is Some(locked) else { return { ..admitted, viewer: admitted.viewer.with_role(named) } }
  guard locked.state is Some(state) else {
    raise LockRefusal("this station's workspace lock is broken; run `stillfail lock reset` on it")
  }
  if locked.waiting {
    raise LockRefusal(not_given)
  }
  let v = admitted.viewer
  let (device, role) = (k.admit)(state, who_of(v, endpoint), (k.now_secs)())
  if device.kind == "app" && state.persons.contains(v.sub) && device.by != Some("chain") {
    match on_personal_lock(k, admitted, named, endpoint, hello) {
      None => raise LockRefusal("this device goes by its person's own lock in this workspace, and it brought none")
      Some(person) => return person
    }
  }
  { ..admitted, viewer: { ..v, role: lower_role(role, named), lock_id: Some(device.id) } }
}

///|
fn is_lock_refusal(e : Error) -> Bool {
  e is LockRefusal(_)
}

///|
/// inLock again for a connection already in (serve.ts `stillIn`).
pub async fn still_in(k : Keeper, admitted : Admitted, named : String, endpoint : String) -> Admitted {
  try {
    in_lock(k, admitted, named, endpoint)
  } catch {
    e => {
      if !is_lock_refusal(e) {
        raise e
      }
      match on_personal_lock(k, admitted, named, endpoint, Json::null()) {
        None => raise e
        Some(person) => person
      }
    }
  }
}

///|
/// inLock, for a hello that may bring what put the device in the lock (serve.ts `inLockBringing`).
pub async fn in_lock_bringing(k : Keeper, admitted : Admitted, named : String, endpoint : String, hello : Json) -> Admitted {
  try {
    in_lock(k, admitted, named, endpoint, hello~)
  } catch {
    e => {
      if !is_lock_refusal(e) {
        raise e
      }
      if brought_for_state(k, hello, admitted.viewer.workspace) {
        match (try { Ok(in_lock(k, admitted, named, endpoint, hello~)) } catch { again => Err(again) }) {
          Ok(a) => return a
          Err(again) => if !is_lock_refusal(again) { raise again }
        }
      }
      if brought(k, hello, admitted.viewer.workspace, admitted.viewer.lock_device.map(p => p.0)) {
        match (try { Ok(in_lock(k, admitted, named, endpoint, hello~)) } catch { again => Err(again) }) {
          Ok(a) => return a
          Err(again) => if !is_lock_refusal(again) { raise again }
        }
      }
      match on_personal_lock(k, admitted, named, endpoint, hello) {
        None => raise e
        Some(person) => person
      }
    }
  }
}

///|
/// On the person's own lock its member bound there (serve.ts `onPersonalLock`). None when there is none to go by;
/// raises a LockRefusal why not.
async fn on_personal_lock(k : Keeper, admitted : Admitted, named : String, endpoint : String, hello : Json) -> Admitted? {
  let raw = path_of(hello, ["lock", "person"])
  let raw = match raw {
    None => None
    Some(Array(a)) if a.length() > 0 && a.length() <= brought_most => Some(a)
    Some(_) => return None
  }
  let v = admitted.viewer
  let ws = joined_of(k, v.workspace)
  guard (k.locked)(ws) is Some({ state: Some(state), .. }) && state.persons.get(v.sub) is Some(pin) else {
    return None
  }
  let who = who_of(v, endpoint)
  let mut newest = match raw {
    None => (k.person_kept)(pin)
    Some(a) => Some(a)
  }
  if raw is Some(a) {
    try {
      ignore(fold_chain(k, Json::array(a), Some(v.sub)))
      let chosen = (k.person_chosen)(pin, v.sub, a)
      if chosen.length() > 0 {
        newest = Some(chosen)
      }
    } catch {
      _ => ()
    }
  }
  guard newest is Some(newest) else { return None }
  let (device, role) = (k.admit_person)(state, who, newest)
  (k.person_keep)(pin, raw.unwrap_or(newest), v.workspace)
  Some({ ..admitted, viewer: { ..v, role: lower_role(role, named), lock_id: Some(device) } })
}

///|
/// How long a person's chain brought may be (person-chains.ts CHAIN_MOST).
pub let chain_most : Int = 1024

///|
/// Whose a chain is: its entries name the person's lock (`person:<sub>`).
pub fn sub_of(chain : Array[Json]) -> String? {
  match chain.get(0) {
    Some(e) =>
      match field(e, "ws") {
        Some(String(ws)) if ws.has_prefix("person:") => Some(ws.clamped_view(start=7).to_owned())
        _ => None
      }
    None => None
  }
}

///|
/// A chain as it is brought, checked by the rules for its person: its genesis and whose; raises why not
/// (person-sync.ts `foldChain`).
pub async fn fold_chain(k : Keeper, chain : Json, sub : String?) -> (String, String) {
  guard chain is Array(c) && c.length() > 0 && c.length() <= chain_most else {
    raise Refused("a person's lock: its entries")
  }
  let whose = sub_of(c)
  guard whose is Some(whose) && (sub is None || sub == Some(whose)) else { raise Refused("a lock of another person's") }
  let (genesis, _) = (k.person_fold)(c, Some(whose))
  (genesis, whose)
}

///|
/// A chain brought by a device or a station from before, taken (person-sync.ts `takeChain`): its genesis and what the
/// keeping said.
pub async fn take_chain(k : Keeper, chain : Json, sub : String?, ws : String?, fork? : Bool = false) -> (String, ChainTaken) {
  let (genesis, whose) = fold_chain(k, chain, sub)
  guard chain is Array(c) else { raise Refused("a person's lock: its entries") }
  (genesis, (k.person_take)(genesis, whose, c, ws, fork))
}
