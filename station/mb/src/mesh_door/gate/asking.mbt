// A keeper that asks another program for each thing (`Keeper::asking`): what it is asked by name with its arguments as
// JSON, and what it answers as JSON (`{error, kind}` raised as the refusal of that kind). The harness's, asking the
// TypeScript station's cloud and rules (station/test/mb-mesh-door.test.ts), so the mesh's admission is held to the
// TypeScript's on one state.

///|
fn opt_str(v : String?) -> Json {
  match v {
    Some(s) => Json::string(s)
    None => Json::null()
  }
}

///|
fn str_of(j : Json?) -> String? {
  match j {
    Some(String(s)) => Some(s)
    _ => None
  }
}

///|
fn int_of(j : Json?) -> Int {
  match j {
    Some(Number(n, ..)) => n.to_int()
    _ => 0
  }
}

///|
fn arr_of(j : Json?) -> Array[Json] {
  match j {
    Some(Array(a)) => a
    _ => []
  }
}

///|
fn strs(j : Json?) -> Array[String] {
  arr_of(j).filter_map(x => match x { String(s) => Some(s); _ => None })
}

///|
pub fn LockState::from_json(j : Json) -> LockState {
  let devices = Map([])
  if field(j, "devices") is Some(Object(m)) {
    for id, d in m {
      devices[id] = {
        id,
        sub: str_of(field(d, "sub")).unwrap_or(""),
        kind: str_of(field(d, "kind")).unwrap_or(""),
        by: str_of(field(d, "by")),
        sign_key: str_of(field(d, "sign_key")),
      }
    }
  }
  let strmap = (k : String) => {
    let out = Map([])
    if field(j, k) is Some(Object(m)) {
      for key, v in m {
        if v is String(s) {
          out[key] = s
        }
      }
    }
    out
  }
  {
    ref_: field(j, "ref").unwrap_or(Json::null()),
    seq: int_of(field(j, "seq")),
    head: str_of(field(j, "head")).unwrap_or(""),
    genesis: str_of(field(j, "genesis")).unwrap_or(""),
    moved: str_of(field(j, "moved")),
    devices,
    members: strmap("members"),
    stations: strs(field(j, "stations")),
    persons: strmap("persons"),
  }
}

///|
fn locked_of(j : Json) -> Locked? {
  match j {
    Null => None
    _ =>
      Some({
        state: match field(j, "state") { Some(Null) | None => None; Some(s) => Some(LockState::from_json(s)) },
        waiting: field(j, "waiting") == Some(Json::boolean(true)),
      })
  }
}

///|
fn who_json(w : Who) -> Json {
  { "sub": Json::string(w.sub), "endpoint": Json::string(w.endpoint), "base": opt_str(w.base), "proof": opt_str(w.proof) }
}

///|
fn revocations_of(j : Json?) -> Array[Revocation] {
  arr_of(j).map(r => {
    kind: str_of(field(r, "kind")).unwrap_or(""),
    id: str_of(field(r, "id")).unwrap_or(""),
    at: match field(r, "at") { Some(Number(n, ..)) => n.to_int64(); _ => 0L },
  })
}

///|
fn chains_of(j : Json) -> Array[(String, Array[Json])] {
  arr_of(Some(j)).map(c => (str_of(field(c, "genesis")).unwrap_or(""), arr_of(field(c, "entries"))))
}

///|
fn n(x : Int) -> Json {
  Json::number(x.to_double())
}

///|
/// A keeper whose every part asks `ask` (its name, its arguments), the clock, the floors, the signature check and the
/// devices seen given.
pub fn Keeper::asking(
  ask : async (String, Json) -> Json,
  now_secs : () -> Int64,
  floors : Floors,
  verify : Verify,
  seen : SeenDevices,
  listen : (() -> Unit) -> () -> Unit,
  persons_listen : (() -> Unit) -> () -> Unit,
) -> Keeper {
  let ws_j = (ws : String?) => opt_str(ws)
  {
    now_secs,
    floors,
    verify,
    seen,
    listen,
    persons_listen,
    home: async fn() { str_of(Some(ask("home", Json::null()))) },
    removed: async fn() { ask("removed", Json::null()) == Json::boolean(true) },
    station: async fn() { str_of(Some(ask("station", Json::null()))).unwrap_or("") },
    name: async fn() { str_of(Some(ask("name", Json::null()))).unwrap_or("") },
    membership: async fn(ws) {
      match ask("membership", { "ws": Json::string(ws) }) {
        Null => None
        m => Some((str_of(field(m, "name")).unwrap_or(""), revocations_of(field(m, "revocations"))))
      }
    },
    memberships: async fn() {
      arr_of(Some(ask("memberships", Json::null()))).map(m => {
        workspace: str_of(field(m, "workspace")).unwrap_or(""),
        revocations: revocations_of(field(m, "revocations")),
      })
    },
    grant_keys: async fn(ws) { ask("grantKeys", { "ws": ws_j(ws) }) },
    state_grant_keys: async fn() { ask("stateGrantKeys", Json::null()) },
    joined_revocations: async fn(ws) { revocations_of(Some(ask("joinedRevocations", { "ws": Json::string(ws) }))) },
    accepted: async fn() {
      let a = ask("accepted", Json::null())
      { issuers: strs(field(a, "issuers")), types: strs(field(a, "types")) }
    },
    left_out: async fn(ws) { str_of(Some(ask("leftOut", { "ws": Json::string(ws) }))) },
    chain: async fn(ws) {
      match ask("chain", { "ws": ws_j(ws) }) {
        Null => (false, None)
        c =>
          (
            true,
            match field(c, "state") {
              Some(Null) | None => None
              Some(s) => Some(LockState::from_json(s))
            },
          )
      }
    },
    locked: async fn(ws) { locked_of(ask("locked", { "ws": ws_j(ws) })) },
    list: async fn(ws) { locked_of(ask("list", { "ws": ws_j(ws) })) },
    root_out: async fn(ws) { ask("rootOut", { "ws": ws_j(ws) }) == Json::boolean(true) },
    needs: async fn(ws) { int_of(Some(ask("needs", { "ws": ws_j(ws) }))) },
    take_lock: async fn(entries, ws) { int_of(Some(ask("takeLock", { "entries": Json::array(entries), "ws": ws_j(ws) }))) },
    keep_lock: async fn(entries, ws, keep) {
      let t = ask("keepLock", { "entries": Json::array(entries), "ws": ws_j(ws), "keep": Json::boolean(keep) })
      { taken: int_of(field(t, "taken")), off: arr_of(field(t, "off")), refusal: str_of(field(t, "refusal")) }
    },
    lock_after: async fn(seq, ws) { arr_of(Some(ask("lockAfter", { "seq": n(seq), "ws": ws_j(ws) }))) },
    take_bodies: async fn(ws, bodies) {
      let t = ask("takeBodies", { "ws": ws_j(ws), "bodies": Json::array(bodies) })
      (int_of(field(t, "taken")), arr_of(field(t, "refused")))
    },
    bodies: async fn(ws) {
      arr_of(Some(ask("bodies", { "ws": ws_j(ws) }))).map(p => match p {
        Array([String(h), b]) => (h, b)
        _ => ("", Json::null())
      })
    },
    lacking: async fn(ws) { ask("lacking", { "ws": ws_j(ws) }) },
    logs_of: async fn(ws) { strs(Some(ask("logsOf", { "ws": ws_j(ws) }))) },
    given_to: async fn(ws, key) {
      match ask("givenTo", { "ws": ws_j(ws), "key": Json::string(key) }) {
        String("all") => None
        a => Some(strs(Some(a)))
      }
    },
    pin_brought: async fn(ws, w, entries, logs, bodies, who, station) {
      ignore(
        ask("pinBrought", {
          "ws": ws_j(ws),
          "workspace": Json::string(w),
          "entries": Json::array(entries),
          "logs": logs,
          "bodies": bodies,
          "who": who_json(who),
          "station": Json::string(station),
        }),
      )
    },
    person_of: async fn(sub) { chains_of(ask("personOf", { "sub": Json::string(sub) })) },
    person_kept: async fn(genesis) {
      match ask("personKept", { "genesis": Json::string(genesis) }) {
        Array(a) => Some(a)
        _ => None
      }
    },
    person_chosen: async fn(pin, sub, raw) {
      arr_of(Some(ask("personChosen", { "pin": Json::string(pin), "sub": Json::string(sub), "raw": Json::array(raw) })))
    },
    person_keep: async fn(pin, chain, ws) {
      ignore(ask("personKeep", { "pin": Json::string(pin), "chain": Json::array(chain), "ws": Json::string(ws) }))
    },
    person_take: async fn(genesis, whose, chain, ws, fork) {
      let t = ask("personTake", {
        "genesis": Json::string(genesis),
        "whose": Json::string(whose),
        "chain": Json::array(chain),
        "ws": ws_j(ws),
        "fork": Json::boolean(fork),
      })
      {
        taken: int_of(field(t, "taken")),
        chain: arr_of(field(t, "chain")),
        on: field(t, "on") == Some(Json::boolean(true)),
        off: arr_of(field(t, "off")),
      }
    },
    person_every: async fn() { chains_of(ask("personEvery", Json::null())) },
    persons_written: async fn() { ignore(ask("personsWritten", Json::null())) },
    admit: async fn(state, who, now) {
      let a = ask("admit", { "state": state.ref_, "who": who_json(who), "now": Json::number(now.to_double()) })
      let d = field(a, "device").unwrap_or(Json::null())
      (
        {
          id: str_of(field(d, "id")).unwrap_or(""),
          sub: str_of(field(d, "sub")).unwrap_or(""),
          kind: str_of(field(d, "kind")).unwrap_or(""),
          by: str_of(field(d, "by")),
          sign_key: str_of(field(d, "sign_key")),
        },
        str_of(field(a, "role")).unwrap_or(""),
      )
    },
    admit_person: async fn(state, who, chain) {
      let a = ask("admitPerson", { "state": state.ref_, "who": who_json(who), "entries": Json::array(chain) })
      (str_of(field(a, "device")).unwrap_or(""), str_of(field(a, "role")).unwrap_or(""))
    },
    person_fold: async fn(chain, sub) {
      let p = ask("personFold", { "entries": Json::array(chain), "sub": opt_str(sub) })
      (str_of(field(p, "genesis")).unwrap_or(""), arr_of(field(p, "devices")).filter_map(d => str_of(field(d, "id"))))
    },
    fold: async fn(entries, now) {
      LockState::from_json(
        ask("fold", { "entries": Json::array(entries), "now": match now { Some(t) => Json::number(t.to_double()); None => Json::null() } }),
      )
    },
    endpoint_proof: async fn(ws, base, endpoint, proof) {
      ask("endpointProof", { "ws": Json::string(ws), "base": Json::string(base), "endpoint": Json::string(endpoint), "proof": Json::string(proof) }) ==
      Json::boolean(true)
    },
    as_entry: async fn(v) {
      match ask("asEntry", { "v": v }) {
        Null => None
        e => Some(e)
      }
    },
    hash_of: async fn(e) { str_of(Some(ask("hashOf", { "e": e }))).unwrap_or("") },
    check_chain: async fn(chain, sub) {
      let c = ask("checkChain", { "chain": chain, "sub": opt_str(sub) })
      (str_of(field(c, "genesis")).unwrap_or(""), arr_of(field(c, "chain")))
    },
    lock_kept: async fn(ws) { arr_of(Some(ask("lockKept", { "ws": ws_j(ws) }))) },
    lock_off: async fn(ws) {
      match ask("lockOff", { "ws": ws_j(ws) }) {
        Null => None
        o => Some((arr_of(field(o, "entries")), arr_of(field(o, "aside"))))
      }
    },
    person_heard_in: async fn(ws) { chains_of(ask("personHeardIn", { "ws": Json::string(ws) })) },
    person_all: async fn(genesis) { arr_of(Some(ask("personAll", { "genesis": Json::string(genesis) }))) },
    person_aside_of: async fn(genesis) { int_of(Some(ask("personAsideOf", { "genesis": Json::string(genesis) }))) },
    force_word: async fn(ws) { str_of(Some(ask("forceWord", { "ws": ws_j(ws) }))).unwrap_or("") },
    peers_current: async fn() { ask("peersCurrent", Json::null()) == Json::boolean(true) },
    has_state: async fn() { ask("hasState", Json::null()) == Json::boolean(true) },
    is_rig: async fn() { ask("isRig", Json::null()) == Json::boolean(true) },
    is_rig_in: async fn(ws) { ask("isRigIn", { "ws": Json::string(ws) }) == Json::boolean(true) },
    member_of: async fn(ws) {
      match ask("memberOf", { "ws": Json::string(ws) }) {
        Null => None
        m => Some(m)
      }
    },
    members_all: async fn() { arr_of(Some(ask("membersAll", Json::null()))) },
    joined: async fn() { arr_of(Some(ask("joined", Json::null()))) },
    unprotected: async fn(ws) { arr_of(Some(ask("unprotected", { "ws": Json::string(ws) }))) },
    rig_of: async fn(id, ws) {
      match ask("rigOf", { "id": Json::string(id), "ws": ws_j(ws) }) {
        Null => None
        r => Some(r)
      }
    },
    rigs: async fn(ws) { arr_of(Some(ask("rigs", { "ws": Json::string(ws) }))) },
    rigs_named: async fn(ws) { arr_of(Some(ask("rigsNamed", { "ws": Json::string(ws) }))) },
    rig_vouched: async fn(ws, rig) { ask("rigVouched", { "ws": Json::string(ws), "rig": rig }) == Json::boolean(true) },
    moved_offered: async fn(ws) { ask("movedOffered", { "ws": Json::string(ws) }) == Json::boolean(true) },
    waiting: async fn(ws) { ask("waiting", { "ws": ws_j(ws) }) == Json::boolean(true) },
    answer_ways: async fn(request, ws) { ask("answerWays", { "request": request, "ws": Json::string(ws) }) },
    answer_marks: async fn(request, ws) { ask("answerMarks", { "request": request, "ws": Json::string(ws) }) },
    pin_moved: async fn(_call, ws, peers, me) {
      ask("pinMoved", { "ws": Json::string(ws), "peers": Json::array(peers.map(p => Json::string(p))), "me": Json::string(me) }) ==
      Json::boolean(true)
    },
    builds_saw: async fn(id, build, now) {
      ignore(
        ask("buildsSaw", {
          "id": Json::string(id),
          "build": match build { Some(b) => n(b); None => Json::null() },
          "now": Json::number(now.to_double()),
        }),
      )
    },
    builds_of: async fn(ids) { ask("buildsOf", { "ids": Json::array(ids.map(x => Json::string(x))) }) },
    ways_view: async fn(ws) { ask("waysView", { "ws": Json::string(ws) }) },
    ways_set_relays: async fn(ws, relays, by) { ask("waysSetRelays", { "ws": Json::string(ws), "relays": relays, "by": opt_str(by) }) },
    ways_set_way: async fn(ws, way, on) { ask("waysSetWay", { "ws": Json::string(ws), "way": Json::string(way), "on": Json::boolean(on) }) },
    marks_of: async fn(ws) { ask("marksOf", { "ws": Json::string(ws) }) },
    marks_change: async fn(change, was) { ask("marksChange", { "change": change, "was": was }) },
  }
}

///|
/// What an answer of the asked program raises, by its kind.
pub fn raised(said : Json) -> Error {
  let words = str_of(field(said, "error")).unwrap_or("")
  match str_of(field(said, "kind")) {
    Some("lock") => LockRefusal(words)
    Some("ways") => WaysRefusal(words)
    Some("mark") => MarkRefusal(words)
    _ => Refused(words)
  }
}
