// Line-delimited JSON-RPC harness (`--builder harness-lock`) for client/core-ts/test/ lock/vault/clock tests:
// drives real `@cloud_lock.Cloud`, `@cloud_lock.DeviceBuilds`, and `@gate.Keeper` with a controllable test clock.

///|
priv struct LockKeeperParts {
  cloud : @cloud_lock.Cloud
  crypto : @cloud_lock.Crypto
  builds : @cloud_lock.DeviceBuilds
  now_ms : Ref[Double]
  states : Array[@lock.LockState]
}

///|
priv struct LockStationInstance {
  cloud : @cloud_lock.Cloud
  builds : @cloud_lock.DeviceBuilds
  keeper : @gate.Keeper
  data : String
}

///|
fn lk_opt_str(v : Json?) -> String? {
  match v {
    Some(String(s)) => Some(s)
    _ => None
  }
}

///|
fn lk_opt_num(v : Json?) -> Double? {
  match v {
    Some(Number(n, ..)) => Some(n)
    _ => None
  }
}

///|
fn lk_jopt(v : String?) -> Json {
  match v {
    Some(s) => Json::string(s)
    None => Json::null()
  }
}

///|
fn lk_arr(v : Json?) -> Array[Json] {
  match v {
    Some(Array(xs)) => xs
    _ => []
  }
}

///|
fn lk_opt_int(v : Json?) -> Int? {
  match v {
    Some(Number(n, ..)) => Some(n.to_int())
    _ => None
  }
}

///|
fn lk_now_secs(now_ms : Ref[Double]) -> Double {
  (now_ms.val / 1000.0).floor()
}

///|
fn lk_who_of(w : Json) -> @cloud_lock.Who {
  let t = (k : String) => match w {
    Object(m) => lk_opt_str(m.get(k))
    _ => None
  }
  { sub: t("sub").unwrap_or(""), endpoint: t("endpoint").unwrap_or(""), base: t("base"), proof: t("proof") }
}

///|
fn lk_chains_json(cs : Array[(String, Array[Json])]) -> Json {
  Json::array(cs.map(c => ({ "genesis": Json::string(c.0), "entries": Json::array(c.1) } : Json)))
}

///|
fn lk_gate_state_json(st : @lock.LockState) -> Map[String, Json] {
  let devices : Map[String, Json] = {}
  for id, d in st.devices {
    let m : Map[String, Json] = {
      "id": Json::string(id),
      "sub": Json::string(d.sub),
      "kind": Json::string(d.kind),
      "own": Json::boolean(d.own),
    }
    if d.by is Some(b) {
      m["by"] = Json::string(b)
    }
    if d.sign_key is Some(k) {
      m["sign_key"] = Json::string(k)
    }
    devices[id] = Json::object(m)
  }
  let members : Map[String, Json] = {}
  for sub, m in st.members {
    members[sub] = Json::string(m.role)
  }
  let persons : Map[String, Json] = {}
  for sub, g in st.persons {
    persons[sub] = Json::string(g)
  }
  let stations = st.stations.keys().map(Json::string).collect()
  let out : Map[String, Json] = {
    "seq": Json::number(st.seq),
    "head": Json::string(st.head),
    "genesis": Json::string(st.genesis),
    "devices": Json::object(devices),
    "members": Json::object(members),
    "stations": Json::array(stations),
    "persons": Json::object(persons),
  }
  if st.moved is Some(root) {
    out["moved"] = Json::string(root)
  }
  out
}

///|
fn LockKeeperParts::view(self : LockKeeperParts, s : @lock.LockState?) -> Json {
  guard s is Some(st) else { return Json::null() }
  self.states.push(st)
  while self.states.length() > 4096 {
    ignore(self.states.remove(0))
  }
  let out = lk_gate_state_json(st)
  out["ref"] = Json::number((self.states.length() - 1).to_double())
  Json::object(out)
}

///|
fn LockKeeperParts::state_of(self : LockKeeperParts, ref_ : Json) -> @lock.LockState raise Failure {
  match ref_ {
    Number(n, ..) if n.to_int() >= 0 && n.to_int() < self.states.length() => self.states[n.to_int()]
    _ => fail("no lock state \{ref_.stringify()}")
  }
}

///|
fn LockKeeperParts::locked_view(self : LockKeeperParts, l : @cloud_lock.Locked?) -> Json {
  match l {
    None => Json::null()
    Some(x) => { "state": self.view(x.state), "waiting": Json::boolean(x.waiting) }
  }
}

///|
async fn LockKeeperParts::ask(self : LockKeeperParts, name : String, a : Json) -> Json {
  let cloud = self.cloud
  let arg = (k : String) => match a {
    Object(m) => m.get(k).unwrap_or(Json::null())
    _ => Json::null()
  }
  let text = (k : String) => lk_opt_str(Some(arg(k)))
  let arr = (k : String) => lk_arr(Some(arg(k)))
  let ws = text("ws")
  let state_text = (k : String) => match cloud.state {
    Some(s) => s.text(k)
    None => ""
  }
  let chains = cloud.person_chains()
  try {
    match name {
      "home" => lk_jopt(cloud.home())
      "removed" => Json::boolean(cloud.removed())
      "station" => Json::string(state_text("station"))
      "name" => Json::string(state_text("name"))
      "membership" | "memberOf" => cloud.membership(ws.unwrap_or("")).unwrap_or(Json::null())
      "memberships" | "membersAll" => Json::array(cloud.memberships())
      "grantKeys" => cloud.grant_keys(ws~).unwrap_or(Json::null())
      "stateGrantKeys" =>
        match cloud.state {
          Some(s) => s.get("grant_keys").unwrap_or(Json::null())
          None => Json::null()
        }
      "joinedRevocations" => {
        let joined = match cloud.state {
          Some(s) => s.joined()
          None => []
        }
        match joined.iter().find_first(j => j is { "workspace": String(w), .. } && Some(w) == ws) {
          Some({ "revocations": Array(r), .. }) => Json::array(r)
          _ => Json::array([])
        }
      }
      "accepted" =>
        {
          "issuers": Json::array(@gate.stillfail_credential.issuers.map(Json::string)),
          "types": Json::array(@gate.stillfail_credential.types.map(Json::string)),
        }
      "leftOut" => lk_jopt(cloud.left_out(ws.unwrap_or("")))
      "chain" =>
        match cloud.chain(ws~) {
          Some(c) => { "state": self.view(c.state) }
          None => Json::null()
        }
      "locked" => self.locked_view(cloud.locked(ws~))
      "list" => self.locked_view(cloud.list(ws))
      "rootOut" => Json::boolean(cloud.root_out(ws))
      "needs" => Json::number(cloud.needs(ws).length().to_double())
      "takeLock" => Json::number(cloud.take_lock(arr("entries"), ws~).to_double())
      "keepLock" => {
        let t = cloud.keep_lock(arr("entries"), ws~, fork=arg("keep") is True)
        {
          "taken": Json::number(t.taken.to_double()),
          "off": Json::array(t.off.map(o => o.to_json())),
          "refusal": lk_jopt(t.refusal),
        }
      }
      "lockAfter" => Json::array(cloud.lock_after(lk_opt_num(Some(arg("seq"))).unwrap_or(-1.0), ws~))
      "takeBodies" => {
        let (taken, refused) = cloud.take_bodies(ws, arr("bodies"))
        { "taken": Json::number(taken.to_double()), "refused": Json::array(refused.map(r => r.to_json())) }
      }
      "bodies" => Json::array(cloud.bodies(ws).all().to_array().map(kv => Json::array([Json::string(kv.0), kv.1])))
      "lacking" => Json::array(cloud.lacking(ws).map(Json::string))
      "logsOf" => Json::array(cloud.logs_of(ws).map(Json::string))
      "givenTo" =>
        match cloud.given_to(ws, text("key").unwrap_or("")) {
          All => Json::string("all")
          Only(hs) => Json::array(hs.map(Json::string))
        }
      "pinBrought" => {
        @cloud_lock.pin_brought(
          cloud,
          ws,
          text("workspace").unwrap_or(""),
          arr("entries"),
          Some(arg("logs")),
          Some(arg("bodies")),
          lk_who_of(arg("who")),
          text("station").unwrap_or(""),
        )
        Json::null()
      }
      "personOf" => lk_chains_json(chains.of(text("sub").unwrap_or("")))
      "personKept" =>
        match chains.kept(text("genesis").unwrap_or("")) {
          Some(k) => Json::array(k)
          None => Json::null()
        }
      "personChosen" => Json::array(chains.chosen(text("pin").unwrap_or(""), text("sub").unwrap_or(""), arr("raw")))
      "personKeep" => {
        chains.keep(text("pin").unwrap_or(""), arr("chain"), ws=text("ws"))
        Json::null()
      }
      "personTake" => {
        let t = chains.take(text("genesis").unwrap_or(""), text("whose").unwrap_or(""), arr("chain"), ws~, fork=arg("fork") is True)
        {
          "taken": Json::number(t.taken.to_double()),
          "chain": Json::array(t.chain),
          "on": Json::boolean(t.on),
          "off": Json::array(t.off.map(o => o.to_json())),
        }
      }
      "personEvery" => lk_chains_json(chains.every())
      "personsWritten" => Json::null()
      "admit" => {
        let (device, role) = @cloud_lock.admit(
          self.crypto,
          self.state_of(arg("state")),
          lk_who_of(arg("who")),
          match arg("now") {
            Number(n, ..) => n
            _ => lk_now_secs(self.now_ms)
          },
        )
        {
          "device": {
            "id": Json::string(device.id),
            "sub": Json::string(device.sub),
            "kind": Json::string(device.kind),
            "by": lk_jopt(device.by),
            "sign_key": lk_jopt(device.sign_key),
          },
          "role": Json::string(role),
        }
      }
      "admitPerson" => {
        let (device, role, _) = @cloud_lock.admit_person(self.crypto, self.state_of(arg("state")), lk_who_of(arg("who")), arr("entries"))
        { "device": Json::string(device), "role": Json::string(role) }
      }
      "personFold" => {
        let p = @cloud_lock.person_fold(
          self.crypto,
          arr("entries"),
          text("sub").unwrap_or(@cloud_lock.sub_of(arr("entries")).unwrap_or("")),
        )
        @cloud_lock.person_json(p)
      }
      "fold" => self.view(Some(@cloud_lock.fold(self.crypto, arr("entries"), lk_opt_num(Some(arg("now"))))))
      "endpointProof" =>
        Json::boolean(
          self.crypto.endpoint_ok(
            text("ws").unwrap_or(""),
            text("base").unwrap_or(""),
            text("endpoint").unwrap_or(""),
            text("proof").unwrap_or(""),
          ),
        )
      "asEntry" => @cloud_lock.as_entry(arg("v")).unwrap_or(Json::null())
      "hashOf" => Json::string(@cloud_lock.hash_of(arg("e")))
      "checkChain" => {
        let chain = arr("chain")
        let whose = match @cloud_lock.sub_of(chain) {
          Some(w) => w
          None => raise @gate.LockRefusal("a lock of another person's")
        }
        match text("sub") {
          Some(s) if s != whose => raise @gate.LockRefusal("a lock of another person's")
          _ => ()
        }
        let genesis = @cloud_lock.person_fold(self.crypto, chain, whose)
        let g = match @cloud_lock.person_json(genesis) {
          { "genesis": String(g), .. } => g
          _ => ""
        }
        { "genesis": Json::string(g), "chain": Json::array(chains.newest(g, whose, chain)) }
      }
      "buildsSaw" => {
        self.builds.saw(
          text("id").unwrap_or(""),
          lk_opt_int(Some(arg("build"))),
          match arg("now") {
            Number(n, ..) => n
            _ => lk_now_secs(self.now_ms)
          },
        )
        Json::null()
      }
      "buildsOf" => self.builds.of(arr("ids").filter_map(x => match x { String(s) => Some(s); _ => None }))
      "lockKept" => Json::array(cloud.lock_kept(ws~))
      "lockOff" =>
        match cloud.lock_off(ws~) {
          Some(k) => { "entries": Json::array(k.entries), "aside": Json::array(k.aside) }
          None => Json::null()
        }
      "personHeardIn" => lk_chains_json(chains.heard_in(ws.unwrap_or("")))
      "personAll" => Json::array(chains.all(text("genesis").unwrap_or("")))
      "personAsideOf" => Json::number(chains.aside_of(text("genesis").unwrap_or("")).to_double())
      "forceWord" => Json::string(cloud.force_word(ws))
      "peersCurrent" => Json::boolean(cloud.peers_current)
      "hasState" => Json::boolean(cloud.state is Some(_))
      "isRig" => Json::boolean(cloud.is_rig_only())
      "isRigIn" => Json::boolean(cloud.rig_in(ws.unwrap_or("")) is Some(_))
      "joined" =>
        Json::array(
          match cloud.state {
            Some(s) => s.joined()
            None => []
          },
        )
      "unprotected" => Json::array(cloud.unprotected(ws~))
      "rigOf" =>
        match cloud.rig_of(text("id").unwrap_or(""), workspace=ws) {
          Some((w, r)) => { "workspace": Json::string(w), "rig": r }
          None => Json::null()
        }
      "rigs" => Json::array(cloud.rigs(ws.unwrap_or("")))
      "rigsNamed" => Json::array(cloud.rigs_named(ws.unwrap_or("")))
      "rigVouched" => Json::boolean((cloud.rig_vouched)(ws.unwrap_or(""), arg("rig")))
      "movedOffered" => Json::boolean(cloud.moved_offered.contains(ws.unwrap_or("")))
      "waiting" => Json::boolean(cloud.waiting(ws~))
      _ => fail("no lock keeper part \{name}")
    }
  } catch {
    @cloud_lock.Refused(m) => raise @gate.LockRefusal(m)
    @cloud_lock.Failed(m) => fail(m)
    e => raise e
  }
}

///|
fn lk_make_keeper(
  host : @host.Host,
  cloud : @cloud_lock.Cloud,
  crypto : @cloud_lock.Crypto,
  builds : @cloud_lock.DeviceBuilds,
  now_ms : Ref[Double],
) -> @gate.Keeper {
  let parts : LockKeeperParts = { cloud, crypto, builds, now_ms, states: [] }
  let seen = @gate.SeenDevices::new(None, _ => ())
  @gate.Keeper::asking(
    async fn(name, args) { parts.ask(name, args) },
    () => lk_now_secs(now_ms).to_int64(),
    {
      oldest_core: 0,
      counted_from: @cloud_lock.counted_from,
      moved_from: @cloud_lock.moved_from_build,
      root_out_from: @cloud_lock.root_out_from_build,
      logs_before: @cloud_lock.logs_before,
      logs_any_from: @cloud_lock.logs_any_from_build,
    },
    (message, key, sig) => {
      let said = host.shell_sync("crypto.verify", {
        "alg": "Ed25519",
        "key": Json::string(@cloud_lock.hex_of(key)),
        "signature": Json::string(@cloud_lock.hex_of(sig)),
        "message": Json::string(@cloud_lock.hex_of(message)),
      }) catch {
        _ => Json::boolean(false)
      }
      said == Json::boolean(true)
    },
    seen,
    f => cloud.listen(_ => f()),
    f => cloud.person_chains().listen(_ => f()),
  )
}

///|
fn lk_locked_json(l : @cloud_lock.Locked?) -> Json {
  match l {
    None => Json::null()
    Some(x) =>
      {
        "state": match x.state {
          Some(s) => @cloud_lock.state_json(s)
          None => Json::null()
        },
        "waiting": Json::boolean(x.waiting),
      }
  }
}

///|
fn lk_err_words(e : Error) -> String {
  match e {
    @cloud_lock.Failed(m) | @cloud_lock.Refused(m) => m
    _ => @gate.words_of(e)
  }
}

///|
async fn harness_lock(host : @host.Host) -> Unit {
  let crypto = @cloud_lock.Crypto::of_host(host)
  let disk : @cloud_lock.Disk = { host, }
  let now_ms : Ref[Double] = Ref(0.0)
  let stations : Map[Int, LockStationInstance] = Map([])
  let mut next_handle = 0

  fn get_inst(ask : Json) -> LockStationInstance raise Failure {
    let h = sn_int(ask, "handle", -1)
    match stations.get(h) {
      Some(inst) => inst
      None => fail("no lock station handle \{h}")
    }
  }

  while host.line() is Some(line) {
    if line == "" {
      continue
    }
    let ask = @json.parse(line) catch { _ => Json::null() }
    let id = sn_at(ask, "id").unwrap_or(Json::null())
    let op = sn_str(ask, "op")
    if sn_at(ask, "nowMs") is Some(Number(n, ..)) {
      now_ms.val = n
    }
    let reply : Result[Json, String] = try {
      match op {
        "setClock" => Ok(Json::boolean(true))
        "create" => {
          let data = sn_str(ask, "data")
          let fields = match sn_at(ask, "state") {
            Some(Object(m)) => m.copy()
            _ => Map([])
          }
          @cloud_lock.write_state(disk, data, { fields, })
          let cloud = @cloud_lock.Cloud::new(host, data, crypto, () => lk_now_secs(now_ms))
          let builds = @cloud_lock.DeviceBuilds::new(None, lk_now_secs(now_ms))
          let keeper = lk_make_keeper(host, cloud, crypto, builds, now_ms)
          next_handle += 1
          stations[next_handle] = { cloud, builds, keeper, data }
          Ok(Json::object({ "handle": Json::number(next_handle.to_double()) }))
        }
        "takeLock" => {
          let inst = get_inst(ask)
          let entries = sn_params(ask, "entries")
          let ws = lk_opt_str(sn_at(ask, "ws"))
          let fork = sn_bool(ask, "fork")
          let took = inst.cloud.keep_lock(entries, ws~, fork~)
          Ok(
            Json::object({
              "taken": Json::number(took.taken.to_double()),
              "off": Json::array(took.off.map(o => o.to_json())),
              "refusal": lk_jopt(took.refusal),
            }),
          )
        }
        "lockKept" => {
          let inst = get_inst(ask)
          let ws = lk_opt_str(sn_at(ask, "ws"))
          Ok(Json::array(inst.cloud.lock_kept(ws~)))
        }
        "lockAfter" => {
          let inst = get_inst(ask)
          let ws = lk_opt_str(sn_at(ask, "ws"))
          let seq = lk_opt_num(sn_at(ask, "seq")).unwrap_or(-1.0)
          Ok(Json::array(inst.cloud.lock_after(seq, ws~)))
        }
        "chain" => {
          let inst = get_inst(ask)
          let ws = lk_opt_str(sn_at(ask, "ws"))
          Ok(lk_locked_json(inst.cloud.chain(ws~)))
        }
        "locked" => {
          let inst = get_inst(ask)
          let ws = lk_opt_str(sn_at(ask, "ws"))
          Ok(lk_locked_json(inst.cloud.locked(ws~)))
        }
        "bodiesAll" => {
          let inst = get_inst(ask)
          let ws = lk_opt_str(sn_at(ask, "ws"))
          Ok(Json::array(inst.cloud.bodies(ws).all().to_array().map(kv => Json::array([Json::string(kv.0), kv.1]))))
        }
        "takeBodies" => {
          let inst = get_inst(ask)
          let ws = lk_opt_str(sn_at(ask, "ws"))
          let (taken, refused) = inst.cloud.take_bodies(ws, sn_params(ask, "bodies"))
          Ok(
            Json::object({
              "taken": Json::number(taken.to_double()),
              "refused": Json::array(refused.map(r => r.to_json())),
            }),
          )
        }
        "lockRoute" => {
          let inst = get_inst(ask)
          let query : Array[(String, String)] = []
          for pair in sn_params(ask, "query") {
            if pair is Array([String(k), String(v)]) {
              query.push((k, v))
            }
          }
          let body = sn_str(ask, "body")
          let viewer = @cloud_lock.Viewer::of_json(sn_at(ask, "viewer").unwrap_or(Json::null()))
          let (status, out) = @cloud_lock.lock_route(inst.cloud, inst.builds, sn_str(ask, "method"), query, body, viewer)
          Ok(Json::object({ "status": Json::number(status.to_double()), "body": out }))
        }
        "lockPartRoute" => {
          let inst = get_inst(ask)
          let body = sn_str(ask, "body")
          let viewer = @cloud_lock.Viewer::of_json(sn_at(ask, "viewer").unwrap_or(Json::null()))
          let (status, out) = @cloud_lock.lock_part_route(
            inst.cloud,
            inst.builds,
            sn_str(ask, "part"),
            sn_str(ask, "method"),
            body,
            viewer,
          )
          Ok(Json::object({ "status": Json::number(status.to_double()), "body": out }))
        }
        "inLock" => {
          let inst = get_inst(ask)
          let admitted = @gate.Admitted::from_json(sn_at(ask, "admitted").unwrap_or(Json::null()))
          let role = sn_str(ask, "role")
          let device = sn_str(ask, "device")
          let hello_opt = match sn_at(ask, "hello") {
            Some(Null) | None => None
            other => other
          }
          let sub_opt = lk_opt_str(sn_at(ask, "sub"))
          try {
            let out = @gate.in_lock(inst.keeper, admitted, role, device, hello=hello_opt.unwrap_or(Json::null()))
            Ok(Json::object({ "ok": Json::boolean(true), "viewer": out.viewer.to_json() }))
          } catch {
            @gate.LockRefusal(why) =>
              Ok(
                Json::object({
                  "ok": Json::boolean(false),
                  "refusal": Json::boolean(true),
                  "message": Json::string(why),
                  "body": @cloud_lock.lock_refusal(inst.cloud, hello_opt, device, why, sub_opt),
                }),
              )
            e => Err(lk_err_words(e))
          }
        }
        "inLockBringing" => {
          let inst = get_inst(ask)
          let admitted = @gate.Admitted::from_json(sn_at(ask, "admitted").unwrap_or(Json::null()))
          let role = sn_str(ask, "role")
          let device = sn_str(ask, "device")
          let hello = sn_at(ask, "hello").unwrap_or(Json::null())
          let sub_opt = lk_opt_str(sn_at(ask, "sub"))
          try {
            let out = @gate.in_lock_bringing(inst.keeper, admitted, role, device, hello)
            Ok(Json::object({ "ok": Json::boolean(true), "viewer": out.viewer.to_json() }))
          } catch {
            @gate.LockRefusal(why) =>
              Ok(
                Json::object({
                  "ok": Json::boolean(false),
                  "refusal": Json::boolean(true),
                  "message": Json::string(why),
                  "body": @cloud_lock.lock_refusal(inst.cloud, Some(hello), device, why, sub_opt),
                }),
              )
            e => Err(lk_err_words(e))
          }
        }
        "personChainsEvery" => {
          let inst = get_inst(ask)
          let pairs = inst.cloud.person_chains().every().map(p => Json::array([Json::string(p.0), Json::array(p.1)]))
          Ok(Json::array(pairs))
        }
        "personChainsOf" => {
          let inst = get_inst(ask)
          let pairs = inst.cloud.person_chains().of(sn_str(ask, "sub")).map(p => Json::array([Json::string(p.0), Json::array(p.1)]))
          Ok(Json::array(pairs))
        }
        "personChainsKeep" => {
          let inst = get_inst(ask)
          let ws = lk_opt_str(sn_at(ask, "ws"))
          inst.cloud.person_chains().keep(sn_str(ask, "genesis"), sn_params(ask, "entries"), ws~)
          Ok(Json::boolean(true))
        }
        "sawBuild" => {
          let inst = get_inst(ask)
          let viewer = @cloud_lock.Viewer::of_json(sn_at(ask, "viewer").unwrap_or(Json::null()))
          let build = @cloud_lock.build_of(lk_opt_str(sn_at(ask, "build")))
          let out = @cloud_lock.saw_build(inst.cloud, inst.builds, viewer, build)
          Ok(
            match out {
              Some(n) => Json::number(n.to_double())
              None => Json::null()
            },
          )
        }
        "deviceBuildsSaw" => {
          let inst = get_inst(ask)
          let build = lk_opt_int(sn_at(ask, "build"))
          let now_sec = lk_opt_num(sn_at(ask, "nowSec")).unwrap_or(lk_now_secs(now_ms))
          inst.builds.saw(sn_str(ask, "device"), build, now_sec)
          Ok(Json::boolean(true))
        }
        "movedTooOld" => {
          let inst = get_inst(ask)
          let build = lk_opt_int(sn_at(ask, "build"))
          Ok(Json::boolean(@cloud_lock.moved_too_old(inst.cloud, sn_str(ask, "ws"), build)))
        }
        "close" => {
          let h = sn_int(ask, "handle", -1)
          match stations.get(h) {
            Some(_) => {
              stations.remove(h)
              Ok(Json::boolean(true))
            }
            None => Err("no lock station handle \{h}")
          }
        }
        _ => Err("unknown op \{op}")
      }
    } catch {
      e => Err(lk_err_words(e))
    }
    match reply {
      Ok(v) => host.say(Json::object({ "id": id, "ok": v }).stringify())
      Err(m) => host.say(Json::object({ "id": id, "error": Json::string(m) }).stringify())
    }
  }
}
