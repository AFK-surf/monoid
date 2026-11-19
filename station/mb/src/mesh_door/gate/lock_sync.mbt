// The workspace lock between the workspace's stations (station/src/mesh/lock-sync.ts): over the station transport,
// only with stations the lock names, `lock.kept` (how far one's chain goes, the hash of every entry it keeps), `lock.get
// {hashes}`, `lock.offer {entries}`; those from before `lock.head`, `lock.get {after}`, `lock.put {entries}`. Each
// station checks every entry itself (the keeper's `keep_lock`).

///|
/// Whether a peer refused a request as one from before that does not know its method.
pub fn unknown_method(e : Error) -> Bool {
  words_of(e).contains("unknown lock method")
}

///|
async fn entries_of(k : Keeper, raw : Json?) -> Array[Json] {
  let out = []
  for r in arr_of(raw) {
    match (k.as_entry)(r) {
      Some(e) => out.push(e)
      None => raise Refused("a malformed lock entry")
    }
  }
  out
}

///|
async fn hashes_of(k : Keeper, entries : Array[Json]) -> Array[String] {
  let out = []
  for e in entries {
    out.push((k.hash_of)(e))
  }
  out
}

///|
fn seq_json(s : LockState?, fallback : Int) -> Json {
  Json::number(
    (match s {
      Some(st) => st.seq
      None => fallback
    }).to_double(),
  )
}

///|
/// A lock request of another station of the workspace, of the lock of the workspace it was asked in (lock-sync.ts
/// `answerLock`).
pub async fn answer_lock(k : Keeper, request : Json, workspace : String?, peer : String?) -> Json {
  let verb = match field(request, "method") { Some(String(m)) => m; _ => "" }
  let named = match workspace { Some(w) => w; None => (k.home)().unwrap_or("") }
  if verb.has_prefix("lock.person.") {
    return answer_person(k, request, named)
  }
  if verb.has_prefix("lock.bodies.") {
    return answer_bodies(k, request, named, peer)
  }
  let ws = match workspace { Some(w) => joined_of(k, w); None => None }
  let (exists, state) = (k.chain)(ws)
  let seq = match state { Some(s) => s.seq; None => -1 }
  let head = match state { Some(s) => Json::string(s.head); None => Json::null() }
  match verb {
    "lock.head" => { "seq": Json::number(seq.to_double()), "hash": head }
    "lock.kept" =>
      {
        "seq": Json::number(seq.to_double()),
        "hash": head,
        "genesis": match state { Some(s) => Json::string(s.genesis); None => Json::null() },
        "hashes": if exists { Json::array(hashes_of(k, (k.lock_kept)(ws)).map(h => Json::string(h))) } else { [] },
      }
    "lock.get" =>
      match field(request, "hashes") {
        Some(Array(_) as hs) => {
          let want = strs(Some(hs))
          let out = []
          if exists {
            for e in (k.lock_kept)(ws) {
              if want.contains((k.hash_of)(e)) {
                out.push(e)
              }
            }
          }
          { "entries": Json::array(out) }
        }
        _ => {
          let after = match field(request, "after") {
            Some(Number(n, ..)) if n == n.floor() && n.abs() <= 9007199254740991.0 => n.to_int()
            _ => -1
          }
          { "entries": Json::array((k.lock_after)(after, ws)) }
        }
      }
    "lock.put" => {
      if !exists {
        raise Refused("this station has no workspace lock")
      }
      let taken = (k.take_lock)(entries_of(k, field(request, "entries")), ws)
      let (_, now) = (k.chain)(ws)
      { "taken": Json::number(taken.to_double()), "seq": seq_json(now, seq) }
    }
    "lock.offer" => {
      if !exists {
        let off = (k.lock_off)(ws)
        let entries = entries_of(k, field(request, "entries"))
        guard off is Some((kept, _)) &&
          entries.length() > 0 &&
          field(entries[0], "prev") is Some(String(_)) else {
          raise Refused("this station has no workspace lock")
        }
        let t = try {
          Some((k.keep_lock)([kept[0], ..entries], ws, true))
        } catch {
          _ => None
        }
        match t {
          None => return { "taken": 0, "seq": -1, "hash": Json::null() }
          Some(t) => {
            let (_, now) = (k.chain)(ws)
            return {
              "taken": Json::number(t.taken.to_double()),
              "seq": seq_json(now, -1),
              "hash": match now { Some(s) => Json::string(s.head); None => Json::null() },
            }
          }
        }
      }
      let t = (k.keep_lock)(entries_of(k, field(request, "entries")), ws, true)
      let (_, now) = (k.chain)(ws)
      {
        "taken": Json::number(t.taken.to_double()),
        "seq": seq_json(now, seq),
        "hash": match now { Some(s) => Json::string(s.head); None => Json::null() },
      }
    }
    _ => raise Refused("unknown lock method")
  }
}

///|
async fn ask_json(call : PeerCall, peer : String, ws : String?, request : Json) -> Json {
  call(peer, ws, request, None).0
}

///|
/// Brings one peer and this station level in workspace `ws` (None: the home one) (lock-sync.ts `syncWith`).
pub async fn sync_with(k : Keeper, call : PeerCall, peer : String, ws : String?) -> Unit {
  guard (k.chain)(ws) is (_, Some(_)) else { return }
  let kept = try {
    ask_json(call, peer, ws, { "method": "lock.kept" })
  } catch {
    e => {
      if !unknown_method(e) {
        raise e
      }
      return sync_as_before(k, call, peer, ws)
    }
  }
  match field(kept, "seq") {
    Some(Number(n, ..)) if n == n.floor() && n >= 0.0 => ()
    _ => return
  }
  guard field(kept, "hashes") is Some(Array(_) as hs) else { return sync_as_before(k, call, peer, ws) }
  let theirs = strs(Some(hs))
  let lacks = []
  for e in (k.lock_kept)(ws) {
    if !theirs.contains((k.hash_of)(e)) {
      lacks.push(e)
    }
  }
  if lacks.length() > 0 {
    ignore(ask_json(call, peer, ws, { "method": "lock.offer", "entries": Json::array(lacks) }))
  }
  let have = hashes_of(k, (k.lock_kept)(ws))
  let want = []
  for h in theirs {
    if !have.contains(h) && !want.contains(h) {
      want.push(h)
    }
  }
  if want.length() == 0 {
    return
  }
  let got = ask_json(call, peer, ws, { "method": "lock.get", "hashes": Json::array(want.map(h => Json::string(h))) })
  if (k.chain)(ws) is (_, Some(_)) {
    ignore((k.keep_lock)(entries_of(k, field(got, "entries")), ws, true))
  }
}

///|
/// A lock turned off here and a peer that keeps it on: gives it what it lacks and takes what it has more
/// (lock-sync.ts `offerOff`).
pub async fn offer_off(k : Keeper, call : PeerCall, peer : String, ws : String?, off : (Array[Json], Array[Json])) -> Unit {
  let kept = try {
    ask_json(call, peer, ws, { "method": "lock.kept" })
  } catch {
    e => {
      if unknown_method(e) {
        return
      }
      raise e
    }
  }
  let genesis = (k.hash_of)(off.0[0])
  guard field(kept, "hashes") is Some(Array(_) as hs) &&
    field(kept, "seq") is Some(Number(n, ..)) &&
    n == n.floor() &&
    n >= 0.0 &&
    field(kept, "genesis") == Some(Json::string(genesis)) else {
    return
  }
  let theirs = strs(Some(hs))
  let mine = [..off.0, ..off.1]
  let lacks = []
  for e in mine {
    if !theirs.contains((k.hash_of)(e)) {
      lacks.push(e)
    }
  }
  if lacks.length() > 0 {
    ignore(ask_json(call, peer, ws, { "method": "lock.offer", "entries": Json::array(lacks) }))
  }
  let have = hashes_of(k, mine)
  let want = []
  for h in theirs {
    if !have.contains(h) && !want.contains(h) {
      want.push(h)
    }
  }
  if want.length() == 0 {
    return
  }
  let got = ask_json(call, peer, ws, { "method": "lock.get", "hashes": Json::array(want.map(h => Json::string(h))) })
  try {
    ignore((k.keep_lock)([off.0[0], ..entries_of(k, field(got, "entries"))], ws, true))
  } catch {
    _ => ()
  }
}

///|
async fn sync_as_before(k : Keeper, call : PeerCall, peer : String, ws : String?) -> Unit {
  guard (k.chain)(ws) is (_, Some(mine)) else { return }
  let head = ask_json(call, peer, ws, { "method": "lock.head" })
  let theirs = match field(head, "seq") {
    Some(Number(n, ..)) if n == n.floor() && n.abs() <= 9007199254740991.0 => n.to_int()
    _ => -1
  }
  if theirs < 0 {
    return
  }
  if theirs < mine.seq {
    ignore(ask_json(call, peer, ws, { "method": "lock.put", "entries": Json::array((k.lock_after)(theirs, ws)) }))
  } else if theirs > mine.seq {
    let got = ask_json(call, peer, ws, { "method": "lock.get", "after": Json::number(mine.seq.to_double()) })
    ignore((k.take_lock)(entries_of(k, field(got, "entries")), ws))
  }
}

///|
/// How long a station waits before it tries a peer again that it could not bring level, at first; each failure after
/// doubles it, up to `retry_most_ms`.
pub let retry_ms : Int = 5000

///|
pub let retry_most_ms : Int = 10 * 60000

///|
/// What a station keeps of the lock in `ws`, as a word that changes when any of it does (lock-sync.ts `keptWord`).
async fn kept_word(k : Keeper, ws : String?) -> String {
  guard (k.chain)(ws) is (_, Some(s)) else { return "" }
  let all = (k.lock_kept)(ws)
  let aside = if s.seq + 1 < all.length() { all[s.seq + 1:].to_owned() } else { [] }
  let last = if aside.length() == 0 { "" } else { (k.hash_of)(aside[aside.length() - 1]) }
  "\{s.seq}:\{s.head}:\{aside.length()}:\{last}"
}

///|
/// The retries of a follower: each key's wait and whether it is over.
priv struct Retry {
  wait : Int
  mut due : Bool
  mut cancel : () -> Unit
}

///|
/// A key tried again later, sooner at first, doubling up to `retry_most_ms`.
fn retry_later(rt : @effect.Runtime, retries : Map[String, Retry], key : String, was : Retry?, look : Ref[() -> Unit]) -> Unit {
  let wait = match was {
    None => retry_ms
    Some(r) => if r.wait * 2 < retry_most_ms { r.wait * 2 } else { retry_most_ms }
  }
  let r : Retry = { wait, due: false, cancel: () => () }
  r.cancel = @door.after(rt, wait, () => {
    r.due = true
    (look.val)()
  })
  retries[key] = r
}

///|
/// One try at pinning a moved chain offered (lock-sync.ts `followLock`'s `pin`).
async fn pin_once(
  k : Keeper,
  call : PeerCall,
  workspace : String,
  peers : Array[String],
  key : String,
  retry : Retry?,
  going : Array[String],
  retries : Map[String, Retry],
  stopped : Ref[Bool],
  schedule : (String, Retry?) -> Unit,
) -> Unit {
  if (k.left_out)(workspace) != Some("unpinned") {
    return
  }
  going.push(key)
  let done = (k.pin_moved)(call, workspace, peers, (k.station)()) catch { _ => false }
  match going.search(key) {
    Some(i) => ignore(going.remove(i))
    None => ()
  }
  if done {
    retries.remove(key)
  } else if !stopped.val {
    schedule(key, retry)
  }
}

///|
/// Whenever what this station keeps of its lock changes, or a roster comes, each station of the lock is brought level
/// with it; one that could not be is tried again, sooner at first, until it is (lock-sync.ts `followLock`). What it
/// gives stops it.
pub fn follow_lock(k : Keeper, call : PeerCall, rt : @effect.Runtime) -> () -> Unit {
  let level : Map[String, String] = Map([])
  let going : Array[String] = []
  let retries : Map[String, Retry] = Map([])
  let stopped = Ref(false)
  let look_ref : Ref[() -> Unit] = Ref(() => ())
  let schedule = (key : String, was : Retry?) => retry_later(rt, retries, key, was, look_ref)
  let bring = (peer : String, ws : String?, workspace : String, kept : String, off : (Array[Json], Array[Json])?) => {
    let key = "\{workspace}|\{peer}"
    let retry = retries.get(key)
    let waits = match retry {
      Some(r) => !r.due
      None => false
    }
    if level.get(key) == Some(kept) || going.contains(key) || waits {
      return
    }
    going.push(key)
    ignore(rt.fork_daemon("lock level", on_error=e => @door.log("warn", "lock", "the lock was not brought level", { "error": Json::string(words_of(e)) }), () => {
      let ok = try {
        match off {
          None => sync_with(k, call, peer, ws)
          Some(o) => offer_off(k, call, peer, ws, o)
        }
        None
      } catch {
        e => Some(e)
      }
      match ok {
        None => {
          level[key] = kept
          retries.remove(key)
        }
        Some(e) => {
          let m : Map[String, Json] = { "peer": Json::string(short(peer)), "error": Json::string(words_of(e)) }
          if ws is Some(w) {
            m["workspace"] = Json::string(w)
          }
          @door.log("info", "lock", "a station's lock was not brought level", Json::object(m))
          if !stopped.val {
            schedule(key, retry)
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
  let pin = (workspace : String, peers : Array[String]) => {
    let key = "\{workspace}|moved"
    let retry = retries.get(key)
    let waits = match retry {
      Some(r) => !r.due
      None => false
    }
    if !going.contains(key) && !waits {
      ignore(rt.fork_daemon("lock pin", on_error=e => @door.log("warn", "lock", "a lock pin was not offered", { "error": Json::string(words_of(e)) }), () => pin_once(k, call, workspace, peers, key, retry, going, retries, stopped, schedule)))
    }
  }
  let look = async fn() {
    if stopped.val || !(k.has_state)() || !(k.peers_current)() {
      return
    }
    let me = (k.station)()
    let home = (k.home)()
    let listed = (k.members_all)()
    let named_ws = listed.filter_map(m => str_of(field(m, "workspace")))
    let all = listed.copy()
    for j in (k.joined)() {
      guard str_of(field(j, "workspace")) is Some(w) else { continue }
      if Some(w) != home && !named_ws.contains(w) && (k.lock_off)(Some(w)) is Some(_) {
        guard j is Object(jm) else { continue }
        let c = jm.copy()
        c["home"] = Json::boolean(false)
        all.push(Json::object(c))
      }
    }
    for m in all {
      let workspace = str_of(field(m, "workspace")).unwrap_or("")
      let ws = if field(m, "home") == Some(Json::boolean(true)) { None } else { Some(workspace) }
      let peers = arr_of(field(m, "peers")).filter_map(p => str_of(field(p, "id")))
      let (exists, s) = (k.chain)(ws)
      // (`cloud.chain(ws)?.state` undefined: no chain at all, not a broken one)
      let off = if !exists { (k.lock_off)(ws) } else { None }
      if off is Some((entries, aside)) {
        let named = try {
          (k.fold)(entries[0:entries.length() - 1].to_owned(), None).stations
        } catch {
          _ => []
        }
        if !named.contains(me) {
          continue
        }
        let word = "off:\{(k.hash_of)(entries[entries.length() - 1])}:\{aside.length()}"
        for p in peers {
          if p != me && named.contains(p) {
            bring(p, ws, workspace, word, off)
          }
        }
        continue
      }
      guard s is Some(st) && st.stations.contains(me) else { continue }
      let kept = kept_word(k, ws)
      for p in peers {
        if p != me {
          bring(p, ws, workspace, kept, None)
        }
      }
      for r in (k.rigs)(workspace) {
        if str_of(field(r, "id")) is Some(id) {
          bring(id, ws, workspace, kept, None)
        }
      }
    }
    for j in (k.joined)() {
      guard str_of(field(j, "workspace")) is Some(w) else { continue }
      if (k.moved_offered)(w) {
        pin(w, arr_of(field(j, "peers")).filter_map(p => str_of(field(p, "id"))))
      }
    }
  }
  look_ref.val = () => ignore(rt.fork_daemon("lock look", on_error=_ => (), () => look() catch { _ => () }))
  (look_ref.val)()
  let unlisten = (k.listen)(() => (look_ref.val)())
  () => {
    stopped.val = true
    unlisten()
    for _, r in retries {
      (r.cancel)()
    }
    retries.clear()
  }
}
