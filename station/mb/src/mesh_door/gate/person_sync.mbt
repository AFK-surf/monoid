// Each person's own lock between the stations of the workspaces it was heard in (station/src/mesh/person-sync.ts):
// `lock.person.kept` the hashes of every entry each log heard in the workspace keeps here, `lock.person.get {genesis,
// hashes}` those, `lock.person.offer {genesis, entries}` some; those from before `lock.person.heads`, `lock.person.get
// {genesis}`, `lock.person.put {chain}`. And the workspace's statements' bodies: `lock.bodies.kept`, `.get`, `.offer`.

///|
/// How many entries one offer may bring at most past a chain (log-keep.ts ASIDE_MOST).
pub let aside_most : Int = 64

///|
/// How many bodies one offer brings at most.
pub let bodies_offered : Int = 4096

///|
async fn head_of(k : Keeper, chain : Array[Json]) -> Json {
  {
    "seq": Json::number((chain.length() - 1).to_double()),
    "hash": if chain.length() == 0 { Json::null() } else { Json::string((k.hash_of)(chain[chain.length() - 1])) },
  }
}

///|
/// A person's lock request of another station of workspace `ws` (person-sync.ts `answerPerson`).
pub async fn answer_person(k : Keeper, request : Json, ws : String) -> Json {
  match field(request, "method") {
    Some(String("lock.person.heads")) => {
      let m : Map[String, Json] = Map([])
      for c in (k.person_heard_in)(ws) {
        m[c.0] = Json::number(c.1.length().to_double())
      }
      { "heads": Json::object(m) }
    }
    Some(String("lock.person.get")) => {
      let found = (k.person_heard_in)(ws).iter().find_first(c => Some(Json::string(c.0)) == field(request, "genesis"))
      match field(request, "hashes") {
        Some(Array(_) as hs) => {
          let want = strs(Some(hs))
          let out = []
          if found is Some(f) {
            for e in (k.person_all)(f.0) {
              if want.contains((k.hash_of)(e)) {
                out.push(e)
              }
            }
          }
          { "entries": Json::array(out) }
        }
        _ => { "chain": match found { Some(f) => Json::array(f.1); None => Json::null() } }
      }
    }
    Some(String("lock.person.put")) => {
      let (_, t) = take_chain(k, field(request, "chain").unwrap_or(Json::null()), None, Some(ws), fork=true)
      if !t.on {
        raise LockRefusal(at_odds)
      }
      { "length": Json::number(t.chain.length().to_double()) }
    }
    Some(String("lock.person.kept")) => {
      let m : Map[String, Json] = Map([])
      for c in (k.person_heard_in)(ws) {
        m[c.0] = Json::array(hashes_of(k, (k.person_all)(c.0)).map(h => Json::string(h)))
      }
      { "logs": Json::object(m) }
    }
    Some(String("lock.person.offer")) => {
      let genesis = match field(request, "genesis") { Some(String(g)) => g; _ => "" }
      let entries = []
      let raw = match field(request, "entries") { Some(Array(a)) => a; _ => [] }
      for r in raw {
        match (k.as_entry)(r) {
          Some(e) => entries.push(e)
          None => raise Refused("a malformed lock entry")
        }
      }
      if entries.length() == 0 {
        raise Refused("a malformed lock entry")
      }
      guard sub_of(entries) is Some(sub) && entries.length() <= chain_most + aside_most else {
        raise Refused("a person's lock: its entries")
      }
      let t = (k.person_take)(genesis, sub, entries, Some(ws), true)
      { "taken": Json::number(t.taken.to_double()), "head": head_of(k, t.chain) }
    }
    _ => raise Refused("unknown lock method")
  }
}

///|
/// What this station gives station `peer` of workspace `ws`'s bodies, by hash (person-sync.ts `bodiesGiven`).
pub async fn bodies_given(k : Keeper, ws : String, peer : String) -> Array[(String, Json)] {
  let w = if Some(ws) == (k.home)() { None } else { Some(ws) }
  let all = (k.bodies)(w)
  match (k.given_to)(w, peer) {
    None => all
    Some(given) => {
      let kept = Map::from_array(all)
      given.filter_map(h => kept.get(h).map(b => (h, b)))
    }
  }
}

///|
/// A bodies request of station `peer` of workspace `ws` (person-sync.ts `answerBodies`).
pub async fn answer_bodies(k : Keeper, request : Json, ws : String, peer : String?) -> Json {
  let w = if Some(ws) == (k.home)() { None } else { Some(ws) }
  match field(request, "method") {
    Some(String("lock.bodies.kept")) =>
      {
        "hashes": match peer {
          None => []
          Some(p) => Json::array(bodies_given(k, ws, p).map(b => Json::string(b.0)))
        },
      }
    Some(String("lock.bodies.get")) => {
      let given = match peer { None => Map([]); Some(p) => Map::from_array(bodies_given(k, ws, p)) }
      let want = strs(field(request, "hashes"))
      { "bodies": Json::array(want.filter_map(h => given.get(h))) }
    }
    Some(String("lock.bodies.offer")) => {
      let bodies = arr_of(field(request, "bodies"))
      if bodies.length() > bodies_offered {
        raise Refused("too many bodies")
      }
      let (taken, _) = (k.take_bodies)(w, bodies)
      { "taken": Json::number(taken.to_double()) }
    }
    _ => raise Refused("unknown lock method")
  }
}

///|
/// Brings one peer and this station level in workspace `ws`'s bodies (person-sync.ts `bodiesSyncWith`).
pub async fn bodies_sync_with(k : Keeper, call : PeerCall, peer : String, ws : String) -> Unit {
  let w = if Some(ws) == (k.home)() { None } else { Some(ws) }
  let (exists, _) = (k.chain)(w)
  if !exists {
    return
  }
  let said = try {
    ask_json(call, peer, Some(ws), { "method": "lock.bodies.kept" })
  } catch {
    e => {
      if unknown_method(e) {
        return
      }
      raise e
    }
  }
  let theirs = []
  for h in strs(field(said, "hashes")) {
    if !theirs.contains(h) {
      theirs.push(h)
    }
  }
  let given = bodies_given(k, ws, peer)
  let lacks = given.filter(b => !theirs.contains(b.0)).map(b => b.1)
  if lacks.length() > 0 {
    let n = if lacks.length() < bodies_offered { lacks.length() } else { bodies_offered }
    ignore(ask_json(call, peer, Some(ws), { "method": "lock.bodies.offer", "bodies": Json::array(lacks[0:n].to_owned()) }))
  }
  let have = (k.bodies)(w).map(b => b.0)
  let want = theirs.filter(h => !have.contains(h))
  if want.length() == 0 {
    return
  }
  let got = ask_json(call, peer, Some(ws), { "method": "lock.bodies.get", "hashes": Json::array(want.map(h => Json::string(h))) })
  let bodies = arr_of(field(got, "bodies"))
  if bodies.length() > 0 && bodies.length() <= bodies_offered {
    ignore((k.take_bodies)(w, bodies))
  }
}

///|
/// Brings one peer and this station level in workspace `ws`'s person logs (person-sync.ts `personSyncWith`).
pub async fn person_sync_with(k : Keeper, call : PeerCall, peer : String, ws : String) -> Unit {
  let said = try {
    ask_json(call, peer, Some(ws), { "method": "lock.person.kept" })
  } catch {
    e => {
      if !unknown_method(e) {
        raise e
      }
      return person_as_before(k, call, peer, ws)
    }
  }
  guard field(said, "logs") is Some(Object(theirs)) else { return person_as_before(k, call, peer, ws) }
  for c in (k.person_heard_in)(ws) {
    let has = match theirs.get(c.0) { Some(Array(a)) => a; _ => [] }
    let lacks = []
    for e in (k.person_all)(c.0) {
      if !has.contains(Json::string((k.hash_of)(e))) {
        lacks.push(e)
      }
    }
    if lacks.length() > 0 {
      ignore(ask_json(call, peer, Some(ws), { "method": "lock.person.offer", "genesis": Json::string(c.0), "entries": Json::array(lacks) }))
    }
  }
  for genesis, hs in theirs {
    guard hs is Array(_) else { continue }
    let have = hashes_of(k, (k.person_all)(genesis))
    let want = strs(Some(hs)).filter(h => !have.contains(h))
    if want.length() == 0 {
      continue
    }
    let got = ask_json(call, peer, Some(ws), {
      "method": "lock.person.get",
      "genesis": Json::string(genesis),
      "hashes": Json::array(want.map(h => Json::string(h))),
    })
    let entries = []
    for r in arr_of(field(got, "entries")) {
      match (k.as_entry)(r) {
        Some(e) => entries.push(e)
        None => raise Refused("a malformed lock entry")
      }
    }
    guard entries.length() > 0 && sub_of(entries) is Some(sub) else { continue }
    ignore((k.person_take)(genesis, sub, entries, Some(ws), true))
  }
}

///|
async fn person_as_before(k : Keeper, call : PeerCall, peer : String, ws : String) -> Unit {
  let said = ask_json(call, peer, Some(ws), { "method": "lock.person.heads" })
  let theirs = match field(said, "heads") { Some(Object(m)) => m; _ => Map([]) }
  let mine = (k.person_heard_in)(ws)
  for c in mine {
    match theirs.get(c.0) {
      Some(Number(n, ..)) if n >= c.1.length().to_double() => ()
      _ => ignore(ask_json(call, peer, Some(ws), { "method": "lock.person.put", "chain": Json::array(c.1) }))
    }
  }
  for genesis, n in theirs {
    let ours = match mine.iter().find_first(c => c.0 == genesis) { Some(c) => c.1.length(); None => 0 }
    match n {
      Number(x, ..) if x > ours.to_double() => ()
      _ => continue
    }
    let got = ask_json(call, peer, Some(ws), { "method": "lock.person.get", "genesis": Json::string(genesis) })
    let (_, t) = take_chain(k, field(got, "chain").unwrap_or(Json::null()), None, Some(ws), fork=true)
    if !t.on {
      raise LockRefusal(at_odds)
    }
  }
}

///|
/// What this station heard in `ws`, as a word that changes when any of it does (person-sync.ts `headsIn`).
async fn heads_in(k : Keeper, ws : String) -> String {
  let words = []
  for c in (k.person_heard_in)(ws) {
    let h = if c.1.length() == 0 { "null" } else { (k.hash_of)(c.1[c.1.length() - 1]) }
    words.push("\{c.0}:\{c.1.length()}:\{h}:\{(k.person_aside_of)(c.0)}")
  }
  let fixed = FixedArray::from_array(words)
  fixed.stable_sort_by((a, b) => js_compare(a, b))
  fixed.iter().collect().join(",")
}

///|
/// Whenever a chain kept here moves, a body comes, or a roster comes, each station of each workspace this one is in is
/// brought level with it in the logs heard there (person-sync.ts `followPersons`). What it gives stops it.
pub fn follow_persons(k : Keeper, call : PeerCall, rt : @effect.Runtime) -> () -> Unit {
  let level : Map[String, String] = Map([])
  let going : Array[String] = []
  let retries : Map[String, Retry] = Map([])
  let stopped = Ref(false)
  let look_ref : Ref[() -> Unit] = Ref(() => ())
  let bring = (peer : String, ws : String, heads : String) => {
    let key = "\{ws}|\{peer}"
    let retry = retries.get(key)
    let waits = match retry {
      Some(r) => !r.due
      None => false
    }
    if level.get(key) == Some(heads) || going.contains(key) || waits {
      return
    }
    going.push(key)
    ignore(rt.fork_daemon("persons level", on_error=e => @door.log("warn", "persons", "persons were not brought level", { "error": Json::string(words_of(e)) }), () => {
      let failed = try {
        person_sync_with(k, call, peer, ws)
        bodies_sync_with(k, call, peer, ws)
        None
      } catch {
        e => Some(e)
      }
      match failed {
        None => {
          level[key] = heads
          retries.remove(key)
        }
        Some(e) => {
          @door.log("info", "lock", "a station's person locks were not brought level", {
            "peer": Json::string(short(peer)),
            "error": Json::string(words_of(e)),
            "workspace": Json::string(ws),
          })
          if !stopped.val {
            let wait = match retry {
              None => retry_ms
              Some(r) => if r.wait * 2 < retry_most_ms { r.wait * 2 } else { retry_most_ms }
            }
            let r : Retry = { wait, due: false, cancel: () => () }
            r.cancel = @door.after(rt, wait, () => {
              r.due = true
              (look_ref.val)()
            })
            retries[key] = r
          }
        }
      }
      match going.search(key) {
        Some(i) => ignore(going.remove(i))
        None => ()
      }
      if !stopped.val {
        (look_ref.val)()
      }
    }))
  }
  let look = async fn() {
    if stopped.val || !(k.has_state)() || !(k.peers_current)() {
      return
    }
    let me = (k.station)()
    for m in (k.members_all)() {
      let workspace = str_of(field(m, "workspace")).unwrap_or("")
      let w = if field(m, "home") == Some(Json::boolean(true)) { None } else { Some(workspace) }
      let (exists, s) = (k.chain)(w)
      let tail = if exists {
        "\{(k.bodies)(w).length()}:\{arr_of(Some((k.lacking)(w))).length()}:\{(k.force_word)(w)}"
      } else {
        ""
      }
      let heads = "\{heads_in(k, workspace)}|\{tail}"
      for p in arr_of(field(m, "peers")) {
        if str_of(field(p, "id")) is Some(id) && id != me {
          bring(id, workspace, heads)
        }
      }
      if s is Some(st) && st.moved is Some(_) {
        for r in (k.rigs_named)(workspace) {
          if (k.rig_vouched)(workspace, r) && str_of(field(r, "id")) is Some(id) {
            bring(id, workspace, heads)
          }
        }
      }
    }
  }
  look_ref.val = () => ignore(rt.fork_daemon("persons look", on_error=_ => (), () => look() catch { _ => () }))
  (look_ref.val)()
  let off_cloud = (k.listen)(() => (look_ref.val)())
  let off_chains = (k.persons_listen)(() => (look_ref.val)())
  () => {
    stopped.val = true
    off_cloud()
    off_chains()
    for _, r in retries {
      (r.cancel)()
    }
    retries.clear()
  }
}
