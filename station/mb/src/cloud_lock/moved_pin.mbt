// A station that keeps no lock of a workspace it joined comes to keep it once that workspace's chain moved and its
// people said it a station of theirs (station/src/mesh/moved-pin.ts): the plane's chain is only offered, pinned only
// where the state the logs and bodies a station of the workspace gives make names this station's key. Never where a
// lock of that workspace is pinned already.

///|
/// The logs and bodies of workspace `ws` as station `peer` gives them to this one (moved-pin.ts `fetched`).
async fn fetched(call : async (String, String, Json) -> Json raise, peer : String, ws : String) -> (Array[Array[Json]], Array[Json]) raise {
  let heads = call(peer, ws, { "method": "lock.person.heads" })
  let logs = []
  for kv in entries_of_obj(get(heads, "heads")) {
    let got = call(peer, ws, { "method": "lock.person.get", "genesis": Json::string(kv.0) })
    if get(got, "chain") is Some(Array(chain)) && chain.length() > 0 {
      logs.push(chain)
    }
  }
  let kept = call(peer, ws, { "method": "lock.bodies.kept" })
  let hashes = match get(kept, "hashes") {
    Some(Array(xs)) => xs.filter(x => x is String(_))
    _ => []
  }
  let got = if hashes.length() == 0 {
    jobj([("bodies", jarr([]))])
  } else {
    call(peer, ws, { "method": "lock.bodies.get", "hashes": Json::array(hashes) })
  }
  (logs, array_at(got, "bodies").unwrap_or([]))
}

///|
/// Workspace `ws`'s offered chain pinned if the state the logs and bodies a station of it in `peers` gives names this
/// station (`me`): whether it was (moved-pin.ts `pinMoved`).
pub async fn pin_moved(cloud : Cloud, call : async (String, String, Json) -> Json raise, ws : String, peers : Array[String], me : String) -> Bool raise Failure {
  guard cloud.moved_offered.get(ws) is Some(entries) else { return false }
  if cloud.chain(ws=Some(ws)) is Some(_) || cloud.left_out(ws) != Some("unpinned") {
    return false
  }
  if !entries.iter().any(e => kind_of(e) == "moved") {
    return false
  }
  for peer in peers {
    if peer == me {
      continue
    }
    let got = try Ok(fetched(call, peer, ws)) catch { e => Err(e) }
    guard got is Ok((logs, bodies)) else { continue }
    let names = state4_moved(cloud.crypto, ws, entries, logs, bodies, (cloud.now)()).lock.stations.contains(me)
    if !names {
      continue
    }
    if cloud.chain(ws=Some(ws)) is Some(_) ||
      !(match cloud.moved_offered.get(ws) {
        Some(now) => physical_equal(now, entries)
        None => false
      }) {
      return false
    }
    keep_moved(cloud, Some(ws), ws, entries, logs, bodies)
    cloud.moved_offered.remove(ws)
    return true
  }
  false
}

///|
/// The moved chain pinned (`w` the name the store keeps it by, none for the home workspace), and the logs and bodies
/// its state was made of kept with it (moved-pin.ts `keep`).
fn keep_moved(cloud : Cloud, w : String?, ws : String, entries : Array[Json], logs : Array[Array[Json]], bodies : Array[Json]) -> Unit raise Failure {
  cloud.take_lock(entries, ws=w) |> ignore
  let chains = cloud.person_chains()
  for log in logs {
    if sub_of(log) is Some(sub) {
      (try Ok(chains.take(hash_of(log[0]), sub, log, ws=Some(ws), fork=true)) catch { e => Err(e) }) |> ignore
    }
  }
  cloud.take_bodies(w, bodies) |> ignore
}

///|
/// A moved chain an owner's device brings a station that pins no lock of workspace `ws` (moved-pin.ts `pinBrought`):
/// the state those logs and bodies make with the chain must let that device in as an owner's and name this station
/// (`me`); raises a refusal or a failure why not.
pub fn pin_brought(cloud : Cloud, w : String?, ws : String, entries : Array[Json], logs : Json?, bodies : Json?, who : Who, me : String) -> Unit raise Failure {
  let ls = match logs {
    Some(Array(ls)) if ls.iter().all(l => l is Array(xs) && xs.length() > 0) => Some(ls.map(l => if l is Array(xs) { xs } else { [] }))
    _ => None
  }
  guard ls is Some(ls) && bodies is Some(Array(bs)) else {
    raise Failed("a moved lock is brought with the logs and bodies its state is made of")
  }
  let now = (cloud.now)()
  let state = state4_moved(cloud.crypto, ws, entries, ls, bs, now).lock
  admit(cloud.crypto, state, who, now) |> ignore
  if state.members.get(who.sub).map(m => m.role) != Some("owner") {
    raise Failed("the lock is brought by its owner")
  }
  if !state.stations.contains(me) {
    raise Failed("the lock does not name this station")
  }
  keep_moved(cloud, w, ws, entries, ls, bs)
}
