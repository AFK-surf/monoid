// The lock asked line by line (reader `--builder harness-cloud-lock`), as station/test/mb-cloud-lock.test.ts asks the
// TypeScript's on the same events: each line `{id, op, …}` answered `{id, ok}` or `{id, error, refused}`. A Cloud is
// opened on a data directory by a name (`at`), its clock the harness's (`now`), several at once (one station giving
// another the logs and bodies it pins by: `pinMoved`).

///|
priv struct Harness {
  host : @host.Host
  crypto : Crypto
  clouds : Map[String, Cloud]
  builds : Map[String, DeviceBuilds]
  now : Ref[Double]
}

///|
fn ws_arg(ask : Json) -> String? {
  match get(ask, "ws") {
    Some(String(w)) => Some(w)
    _ => None
  }
}

///|
fn strings_arg(v : Json?) -> Array[String] {
  match v {
    Some(Array(xs)) => xs.filter_map(x => if x is String(s) { Some(s) } else { None })
    _ => []
  }
}

///|
fn json_arr(v : Json?) -> Array[Json] {
  match v {
    Some(Array(xs)) => xs
    _ => []
  }
}

///|
fn chains_arg(v : Json?) -> Array[Array[Json]] {
  json_arr(v).map(x => if x is Array(es) { es } else { [] })
}

///|
fn locked_json(l : Locked?) -> Json {
  match l {
    None => Json::null()
    Some(x) => {
      let out = [
        (
          "state",
          match x.state {
            Some(s) => state_json(s)
            None => Json::null()
          },
        ),
      ]
      if x.waiting {
        out.push(("waiting", Json::boolean(true)))
      }
      jobj(out)
    }
  }
}

///|
fn kept_lock_json(l : KeptLock?) -> Json {
  match l {
    None => Json::null()
    Some(k) => jobj([("entries", jarr(k.entries)), ("aside", jarr(k.aside))])
  }
}

///|
fn took_json(t : Took) -> Json {
  jobj([
    ("kept", kept_json(t.kept)),
    ("taken", jnum(t.taken.to_double())),
    ("off", jarr(t.off.map(o => o.to_json()))),
    ("moved", Json::boolean(t.moved)),
    ("changed", Json::boolean(t.changed)),
  ])
}

///|
fn person_took_json(t : PersonTook) -> Json {
  jobj([
    ("chain", jarr(t.chain)),
    ("taken", jnum(t.taken.to_double())),
    ("off", jarr(t.off.map(o => o.to_json()))),
    ("on", Json::boolean(t.on)),
  ])
}

///|
fn chain_json(ch : Chain) -> Json {
  jobj([
    ("at", jarr(ch.at.map(i => jnum(i.to_double())))),
    ("hashes", jstrs(ch.hashes)),
    (
      "off",
      jarr(ch.off.map(o => {
        let m = [("at", jnum(o.at.to_double())), ("why", jstr(o.why))]
        if o.refusal is Some(r) {
          m.push(("refusal", jstr(r)))
        }
        if o.winner is Some(w) {
          m.push(("winner", jstr(w)))
        }
        if o.step is Some(s) {
          m.push(("step", jstr(s)))
        }
        if o.under is Some(u) {
          m.push(("under", jstr(u)))
        }
        jobj(m)
      })),
    ),
  ])
}

///|
fn who_arg(v : Json?) -> Who {
  let w = v.unwrap_or(Json::null())
  { sub: text_at(w, "sub").unwrap_or(""), endpoint: text_at(w, "endpoint").unwrap_or(""), base: text_at(w, "base"), proof: text_at(w, "proof") }
}

///|
fn route_json(r : (Int, Json)) -> Json {
  jarr([jnum(r.0.to_double()), r.1])
}

///|
fn Harness::cloud(self : Harness, ask : Json) -> Cloud raise Failure {
  let at = text_at(ask, "at").unwrap_or("")
  match self.clouds.get(at) {
    Some(c) => c
    None => raise Failed("no cloud \{at}")
  }
}

///|
fn Harness::builds_of(self : Harness, at : String) -> DeviceBuilds {
  match self.builds.get(at) {
    Some(b) => b
    None => {
      let b = DeviceBuilds::new(None, self.now.val)
      self.builds[at] = b
      b
    }
  }
}

///|
/// One ask answered (its `ok`), or raised why not.
async fn Harness::answer(self : Harness, ask : Json) -> Json raise Error {
  let op = text_at(ask, "op").unwrap_or("")
  let c = self.crypto
  let arg = (k : String) => get(ask, k)
  let ws = ws_arg(ask)
  match op {
    "now" => {
      self.now.val = num_at(ask, "secs").unwrap_or(0.0)
      Json::null()
    }
    // ── the pure ones (lock.ts, log-keep.ts, key.ts) ──
    "canonical" => jstr(canonical(arg("value").unwrap_or(Json::null())))
    "entryHash" => jstr(entry_hash(arg("entry").unwrap_or(Json::null())))
    "asEntry" => as_entry(arg("value").unwrap_or(Json::null())).unwrap_or(Json::null())
    "sigValid" =>
      Json::boolean(
        c.sig_ok(arg("sig").unwrap_or(Json::null()), text_at(ask, "hash").unwrap_or(""), strings_arg(arg("origins")), text_at(ask, "rp_id").unwrap_or(""), arg("passkey") is Some(True)),
      )
    "validKeyId" => Json::boolean(c.valid_key(text_at(ask, "key").unwrap_or("")))
    "endpointProof" =>
      Json::boolean(c.endpoint_ok(text_at(ask, "ws").unwrap_or(""), text_at(ask, "base").unwrap_or(""), text_at(ask, "endpoint").unwrap_or(""), text_at(ask, "proof").unwrap_or("")))
    "taggedSigValid" =>
      Json::boolean(c.tagged_ok(text_at(ask, "key").unwrap_or(""), text_at(ask, "sig").unwrap_or(""), text_at(ask, "tag").unwrap_or(""), text_at(ask, "digest").unwrap_or("")))
    "sha256hex" => jstr(sha256_hex(text_at(ask, "text").unwrap_or("")))
    "shortCode" => jstr(short_code(text_at(ask, "base").unwrap_or("")))
    "lowerRole" => jstr(lower_role(text_at(ask, "a").unwrap_or(""), text_at(ask, "b").unwrap_or("")))
    "wsTag" => jstr(ws_tag(text_at(ask, "ws").unwrap_or(""), text_at(ask, "genesis").unwrap_or("")))
    "bodyHash" => opt_str_json(body_hash(arg("body").unwrap_or(Json::null())))
    "fold" => state_json(fold(c, json_arr(arg("entries")), num_at(ask, "now")))
    "lockChain" => chain_json(lock_chain(c, json_arr(arg("entries")), text_at(ask, "root").unwrap_or("")))
    "personChain" => chain_json(person_chain(c, json_arr(arg("entries")), text_at(ask, "root").unwrap_or("")))
    "personFold" => person_json(person_fold(c, json_arr(arg("entries")), text_at(ask, "sub").unwrap_or("")))
    "admit" => {
      let s = fold(c, json_arr(arg("entries")), None)
      let (d, role) = admit(c, s, who_arg(arg("who")), self.now.val)
      jobj([("device", jstr(d.id)), ("role", jstr(role))])
    }
    "signer" => {
      let s = fold(c, json_arr(arg("entries")), None)
      match signer(s, text_at(ask, "key").unwrap_or(""), num_at(ask, "at")) {
        None => Json::null()
        Some(w) => jobj([("sub", jstr(w.sub)), ("role", jstr(w.role)), ("passkey", Json::boolean(w.passkey)), ("own", Json::boolean(w.own))])
      }
    }
    "emails" => {
      let s = fold(c, json_arr(arg("entries")), None)
      let email = text_at(ask, "email").unwrap_or("")
      let m = (x : @lock.Member) => jobj([("sub", jstr(x.sub)), ("email", jstr(x.email)), ("role", jstr(x.role))])
      jobj([
        (
          "first",
          match member_with_email(s, email) {
            Some(x) => m(x)
            None => Json::null()
          },
        ),
        ("all", jarr(members_with_email(s, email).map(m))),
        ("devices", jstrs(devices_for(s, text_at(ask, "sub").unwrap_or("")))),
      ])
    }
    "state4Moved" => {
      let s = state4_moved(c, text_at(ask, "ws").unwrap_or(""), json_arr(arg("chain")), chains_arg(arg("chains")), json_arr(arg("bodies")), self.now.val)
      jobj([("on", jstr(s.on)), ("state", state_json(s.lock)), ("rootIn", Json::boolean(s.root_in))])
    }
    "roster4Moved" =>
      roster_json(roster4_moved(c, text_at(ask, "ws").unwrap_or(""), json_arr(arg("chain")), chains_arg(arg("chains")), json_arr(arg("bodies")), without=strings_arg(arg("without"))))
    "bodyRefusal" =>
      opt_str_json(
        body_refusal(
          c,
          text_at(ask, "ws").unwrap_or(""),
          arg("body").unwrap_or(Json::null()),
          json_arr(arg("commits")).map(x => { genesis: text_at(x, "genesis").unwrap_or(""), chain: json_arr(get(x, "chain")) }),
        ),
      )
    "keepLog" => {
      // (log-keep.ts `keep` with a person log's rules, or `rechoose` where nothing is brought)
      let genesis = text_at(ask, "genesis").unwrap_or("")
      let rules = person_rules(c, genesis, text_at(ask, "logWs").unwrap_or(""))
      let was : Kept = { entries: json_arr(arg("entries")), aside: json_arr(arg("aside")) }
      took_json(if arg("brought") is Some(Array(b)) { keep(was, b, rules) } else { rechoose(was, rules) })
    }
    "loadKey" => {
      let k = load_key(self.host, text_at(ask, "data").unwrap_or(""))
      jobj([("id", jstr(k.id)), ("signature", jstr(k.sign(text_at(ask, "message").unwrap_or(""))))])
    }
    "signedRequest" => {
      let k = load_key(self.host, text_at(ask, "data").unwrap_or(""))
      let state : CloudState? = match arg("state") {
        Some(Object(m)) => Some({ fields: m })
        _ => None
      }
      let r = signed_request(state, k, text_at(ask, "path").unwrap_or(""), text_at(ask, "tag").unwrap_or(""), arg("value").unwrap_or(Json::null()), num_at(ask, "ts").unwrap_or(0.0))
      jobj([("url", jstr(r.url)), ("headers", jobj(r.headers.map(h => (h.0, jstr(h.1))))), ("body", jstr(r.body))])
    }
    // ── a Cloud on a data directory ──
    "open" => {
      let now = self.now
      let cloud = Cloud::new(self.host, text_at(ask, "data").unwrap_or(""), c, () => now.val)
      self.clouds[text_at(ask, "at").unwrap_or("")] = cloud
      self.builds.remove(text_at(ask, "at").unwrap_or(""))
      Json::null()
    }
    "readState" =>
      match read_state({ host: self.host }, text_at(ask, "data").unwrap_or("")) {
        Some(s) => s.to_json()
        None => Json::null()
      }
    "writeState" => {
      write_state({ host: self.host }, text_at(ask, "data").unwrap_or(""), { fields: obj_arg(arg("state")) })
      Json::null()
    }
    "stateText" => jstr(state_text({ fields: obj_arg(arg("state")) }))
    "joinedOf" => jarr(joined_of(arg("raw")))
    "rigsOf" => jarr(rigs_of(arg("raw")))
    "waysSaidOf" => ways_said_of(arg("raw")).unwrap_or(Json::null())
    "resetLock" => Json::boolean(reset_lock({ host: self.host }, text_at(ask, "data").unwrap_or(""), self.now.val))
    _ => self.cloud_answer(op, ask, ws)
  }
}

///|
/// An ask of one Cloud (`at`).
async fn Harness::cloud_answer(self : Harness, op : String, ask : Json, ws : String?) -> Json raise Error {
  let cloud = self.cloud(ask)
  let arg = (k : String) => get(ask, k)
  let builds = () => self.builds_of(text_at(ask, "at").unwrap_or(""))
  match op {
    "state" =>
      match cloud.state {
        Some(s) => s.to_json()
        None => Json::null()
      }
    "takeLock" => jnum(cloud.take_lock(json_arr(arg("entries")), ws~, fork=arg("fork") is Some(True)).to_double())
    "keepLock" => {
      let t = cloud.keep_lock(json_arr(arg("entries")), ws~, fork=arg("fork") is Some(True))
      jobj([("taken", jnum(t.taken.to_double())), ("off", jarr(t.off.map(o => o.to_json()))), ("refusal", opt_str_json(t.refusal))])
    }
    "locked" => locked_json(cloud.locked(ws~))
    "chain" => locked_json(cloud.chain(ws~))
    "list" => locked_json(cloud.list(ws))
    "rosterOf" => locked_json(cloud.roster_of(ws~))
    "waiting" => Json::boolean(cloud.waiting(ws~))
    "kept" => kept_lock_json(cloud.kept_lock(ws~))
    "rootOut" => Json::boolean(cloud.root_out(ws))
    "needs" => jstrs(cloud.needs(ws))
    "logsOf" => jstrs(cloud.logs_of(ws))
    "lacking" => jstrs(cloud.lacking(ws))
    "forceWord" => jstr(cloud.force_word(ws))
    "givenTo" =>
      match cloud.given_to(ws, text_at(ask, "key").unwrap_or("")) {
        All => jstr("all")
        Only(hs) => jstrs(hs)
      }
    "takeBodies" => {
      let (taken, refused) = cloud.take_bodies(ws, json_arr(arg("bodies")))
      jobj([("taken", jnum(taken.to_double())), ("refused", jarr(refused.map(r => r.to_json())))])
    }
    "bodies" => jstrs(cloud.bodies(ws).all().keys().collect())
    "grantKeys" => cloud.grant_keys(ws~).unwrap_or(Json::null())
    "pendingLock" => opt_str_json(cloud.pending_lock(ws.unwrap_or("")))
    "leftJoined" => {
      cloud.left_joined(ws.unwrap_or(""))
      Json::null()
    }
    "succeed" => Json::boolean(cloud.succeed(ws.unwrap_or("")))
    "setPlaneLists" => {
      cloud.set_plane_lists(json_arr(arg("peers")), arg("gateways"))
      Json::null()
    }
    "update" => {
      // (a `state` frame's lists, as presence.ts puts them in: the roster and the joined workspaces)
      let peers = arg("peers")
      let joined = arg("joined")
      cloud.update(st => {
        if peers is Some(p) {
          st.fields["peers"] = p
        }
        if joined is Some(j) {
          st.fields["joined"] = jarr(joined_of(Some(j)))
        }
      })
      Json::null()
    }
    "filtered" =>
      match cloud.state {
        Some(st) => {
          let (peers, gateways) = cloud.filtered(st)
          let out = [("peers", jarr(peers))]
          if gateways is Some(g) {
            out.push(("gateways", g))
          }
          jobj(out)
        }
        None => Json::null()
      }
    "unprotected" => jarr(cloud.unprotected(ws~))
    "memberships" => jarr(cloud.memberships())
    "membership" => cloud.membership(ws.unwrap_or("")).unwrap_or(Json::null())
    "leftOut" => opt_str_json(cloud.left_out(ws.unwrap_or("")))
    "home" => opt_str_json(cloud.home())
    "relays" => jstrs(cloud.relays())
    "rigs" => jarr(cloud.rigs(ws.unwrap_or("")))
    "rigsNamed" => jarr(cloud.rigs_named(ws.unwrap_or("")))
    "lockAfter" => jarr(cloud.lock_after(num_at(ask, "seq").unwrap_or(-1.0), ws~))
    "lockKept" => jarr(cloud.lock_kept(ws~))
    "lockOff" =>
      match cloud.lock_off(ws~) {
        Some(k) => kept_json(k)
        None => Json::null()
      }
    "reload" => {
      cloud.reload()
      Json::null()
    }
    "reloadLock" => {
      cloud.reload_lock()
      Json::null()
    }
    "reloadJoined" => {
      cloud.reload_joined()
      Json::null()
    }
    "offerMoved" => {
      cloud.offer_moved(ws.unwrap_or(""), json_arr(arg("entries")))
      Json::null()
    }
    "vouch" => {
      // (the rigs its person signed for, by workspace and id: rigs/adds.ts's word)
      let vouched = json_arr(arg("rigs")).map(x => (text_at(x, "ws").unwrap_or(""), text_at(x, "id").unwrap_or("")))
      cloud.set_rig_vouched((w, r) => vouched.contains((w, text_at(r, "id").unwrap_or(""))))
      Json::null()
    }
    // ── the person logs ──
    "personTake" =>
      person_took_json(
        cloud.person_chains().take(text_at(ask, "genesis").unwrap_or(""), text_at(ask, "sub").unwrap_or(""), json_arr(arg("chain")), ws~, fork=arg("fork") is Some(True)),
      )
    "personKeep" => {
      cloud.person_chains().keep(text_at(ask, "genesis").unwrap_or(""), json_arr(arg("chain")), ws~, fork=arg("fork") is Some(True))
      Json::null()
    }
    "personNewest" =>
      jarr(cloud.person_chains().newest(text_at(ask, "genesis").unwrap_or(""), text_at(ask, "sub").unwrap_or(""), json_arr(arg("chain"))))
    "personChosen" =>
      jarr(cloud.person_chains().chosen(text_at(ask, "genesis").unwrap_or(""), text_at(ask, "sub").unwrap_or(""), json_arr(arg("chain"))))
    "personEvery" => jarr(cloud.person_chains().every().map(p => jarr([jstr(p.0), jarr(p.1)])))
    "personAll" => jarr(cloud.person_chains().all(text_at(ask, "genesis").unwrap_or("")))
    "personOf" => jarr(cloud.person_chains().of(text_at(ask, "sub").unwrap_or("")).map(p => jarr([jstr(p.0), jarr(p.1)])))
    "personHeardIn" => jarr(cloud.person_chains().heard_in(ws.unwrap_or("")).map(p => jarr([jstr(p.0), jarr(p.1)])))
    "commitsTo" =>
      jarr(cloud.person_chains().commits_to(text_at(ask, "h").unwrap_or("")).map(x => jobj([("genesis", jstr(x.genesis)), ("chain", jarr(x.chain))])))
    // ── the routes and what a device is told ──
    "lockRoute" => {
      let query = json_arr(arg("query")).map(p => match p {
        Array([String(k), String(v)]) => (k, v)
        _ => ("", "")
      })
      route_json(lock_route(cloud, builds(), text_at(ask, "method").unwrap_or(""), query, text_at(ask, "body").unwrap_or(""), Viewer::of_json(arg("viewer").unwrap_or(Json::null()))))
    }
    "lockPartRoute" =>
      route_json(
        lock_part_route(cloud, builds(), text_at(ask, "part").unwrap_or(""), text_at(ask, "method").unwrap_or(""), text_at(ask, "body").unwrap_or(""), Viewer::of_json(arg("viewer").unwrap_or(Json::null()))),
      )
    "sawBuild" => {
      let b = match arg("build") {
        Some(Number(n, ..)) => Some(n.to_int())
        _ => None
      }
      saw_build(cloud, builds(), Viewer::of_json(arg("viewer").unwrap_or(Json::null())), b) |> ignore
      Json::null()
    }
    "buildOf" => {
      let said = text_at(ask, "said")
      match build_of(said) {
        Some(b) => jnum(b.to_double())
        None => Json::null()
      }
    }
    "movedFloor" =>
      match moved_floor(cloud, text_at(ask, "workspace").unwrap_or("")) {
        Some(f) => jnum(f.to_double())
        None => Json::null()
      }
    "movedTooOld" => {
      let b = match arg("build") {
        Some(Number(n, ..)) => Some(n.to_int())
        _ => None
      }
      Json::boolean(moved_too_old(cloud, text_at(ask, "workspace").unwrap_or(""), b))
    }
    "refusal" =>
      lock_refusal(cloud, arg("hello"), text_at(ask, "device").unwrap_or(""), text_at(ask, "why").unwrap_or(""), text_at(ask, "sub"))
    "answerPerson" => answer_person(cloud, arg("request").unwrap_or(Json::null()), ws.unwrap_or(""))
    "answerBodies" => answer_bodies(cloud, arg("request").unwrap_or(Json::null()), ws.unwrap_or(""), text_at(ask, "peer"))
    "pinBrought" => {
      let w = match arg("w") {
        Some(String(x)) => Some(x)
        _ => None
      }
      pin_brought(cloud, w, ws.unwrap_or(""), json_arr(arg("entries")), arg("logs"), arg("bodies"), who_arg(arg("who")), text_at(ask, "me").unwrap_or(""))
      Json::null()
    }
    "pinMoved" => {
      // (each peer a Cloud of this harness by its key: `stations` {key: at}, asked as person-sync.ts answers)
      let stations : Map[String, String] = Map([])
      for kv in entries_of_obj(arg("stations")) {
        if kv.1 is String(at) {
          stations[kv.0] = at
        }
      }
      let me = text_at(ask, "me").unwrap_or("")
      let call = async fn(peer : String, w : String, request : Json) -> Json raise {
        guard stations.get(peer) is Some(at) && self.clouds.get(at) is Some(other) else { raise Failed("unreachable") }
        match text_at(request, "method") {
          Some(m) if m.has_prefix("lock.bodies.") => answer_bodies(other, request, w, Some(me))
          _ => answer_person(other, request, w)
        }
      }
      Json::boolean(pin_moved(cloud, call, ws.unwrap_or(""), strings_arg(arg("peers")), me))
    }
    _ => raise Failed("no such op: \{op}")
  }
}

///|
/// Reads asks from stdin until it ends, answering each on stdout.
pub async fn harness(host : @host.Host) -> Unit {
  let h : Harness = { host, crypto: Crypto::of_host(host), clouds: Map([]), builds: Map([]), now: Ref(0.0) }
  while host.line() is Some(line) {
    if line == "" {
      continue
    }
    let ask = parse(line).unwrap_or(Json::null())
    let id = get(ask, "id").unwrap_or(Json::null())
    let answer = try {
      let ok = h.answer(ask)
      jobj([("id", id), ("ok", ok)])
    } catch {
      e =>
        jobj([
          ("id", id),
          ("error", jstr(why_of(e))),
          ("refused", Json::boolean(e is Failure::Refused(_))),
        ])
    }
    host.say(stringify(answer))
  }
}

///|
fn obj_arg(v : Json?) -> Map[String, Json] {
  match v {
    Some(Object(m)) => m
    _ => Map([])
  }
}
