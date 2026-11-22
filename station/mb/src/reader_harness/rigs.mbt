// Line-delimited JSON-RPC harness (`--builder harness-rigs`) for client/core-ts/test/rigs.test.ts:
// drives real `@rigs_mode.RigGrants` backed by `@cloud_lock.Crypto::of_host` and `@rigs_mode.Files::of_host`.

///|
priv struct RigInstance {
  grants : @rigs_mode.RigGrants
  ended : Array[String]
  now_ms : Ref[Double]
}

///|
fn rig_opt_json(ask : Json, k : String) -> Json? {
  match sn_at(ask, k) {
    Some(Null) => None
    other => other
  }
}

///|
async fn harness_rigs(host : @host.Host) -> Unit {
  let crypto = @cloud_lock.Crypto::of_host(host)
  let files = @rigs_mode.Files::of_host(host)
  let instances : Map[Int, RigInstance] = Map([])
  let mut next_handle = 0

  fn get_inst(ask : Json) -> RigInstance raise Failure {
    let h = sn_int(ask, "handle", -1)
    match instances.get(h) {
      Some(inst) => inst
      None => fail("no rig handle \{h}")
    }
  }

  while host.line() is Some(line) {
    if line == "" {
      continue
    }
    let ask = @json.parse(line) catch { _ => Json::null() }
    let id = sn_at(ask, "id").unwrap_or(Json::null())
    let op = sn_str(ask, "op")
    let reply : Result[Json, String] = try {
      match op {
        "create" => {
          let self_obj = sn_at(ask, "self").unwrap_or(Json::null())
          let rig_self : @rigs_mode.RigSelf = {
            id: sn_str(self_obj, "id"),
            workspace: sn_str(self_obj, "workspace"),
            owner: sn_str(self_obj, "owner"),
            person: sn_str(self_obj, "person"),
          }
          let now_ms : Ref[Double] = Ref(
            match sn_at(ask, "nowMs") {
              Some(Number(n, ..)) => n
              _ => 0.0
            },
          )
          let ended : Array[String] = []
          let grants = @rigs_mode.RigGrants::new({
            path: sn_str(ask, "path"),
            self_: () => Some(rig_self),
            busy: (_, _) => false,
            stop: (_, _) => (),
            running: () => [],
            ended: e => ended.push("\{sn_str(e, "request")} \{sn_str(e, "why")}"),
            cut: None,
            changed: () => (),
            clock: { now: () => now_ms.val, after: (_, _) => () => () },
            files,
            crypto,
          })
          next_handle += 1
          instances[next_handle] = { grants, ended, now_ms }
          Ok(Json::object({ "handle": Json::number(next_handle.to_double()) }))
        }
        "setNow" => {
          let inst = get_inst(ask)
          if sn_at(ask, "nowMs") is Some(Number(n, ..)) {
            inst.now_ms.val = n
          }
          Ok(Json::boolean(true))
        }
        "grant" => {
          let inst = get_inst(ask)
          let until = inst.grants.grant(
            sn_str(ask, "station"),
            rig_opt_json(ask, "signed"),
            rig_opt_json(ask, "chain"),
          )
          Ok(Json::object({ "until": Json::number(until) }))
        }
        "refusal" => {
          let inst = get_inst(ask)
          let res = inst.grants.refusal(sn_str(ask, "ws"), sn_str(ask, "station"), sn_str(ask, "session"))
          Ok(
            match res {
              Some(s) => Json::string(s)
              None => Json::null()
            },
          )
        }
        "deviceRefusal" => {
          let inst = get_inst(ask)
          let res = inst.grants.device_refusal(
            sn_str(ask, "ws"),
            sn_str(ask, "station"),
            sn_str(ask, "session"),
            sn_str(ask, "device"),
          )
          Ok(
            match res {
              Some(s) => Json::string(s)
              None => Json::null()
            },
          )
        }
        "settings" => {
          let inst = get_inst(ask)
          inst.grants.take_settings(rig_opt_json(ask, "signed"), rig_opt_json(ask, "chain"))
          Ok(Json::boolean(true))
        }
        "open" => {
          let inst = get_inst(ask)
          Ok(Json::boolean(inst.grants.open()))
        }
        "revoke" => {
          let inst = get_inst(ask)
          inst.grants.revoke(rig_opt_json(ask, "signed"), rig_opt_json(ask, "chain"))
          Ok(Json::boolean(true))
        }
        "full" => {
          let inst = get_inst(ask)
          Ok(inst.grants.full(rig_opt_json(ask, "signed"), rig_opt_json(ask, "chain")))
        }
        "added" => {
          let inst = get_inst(ask)
          let lock = inst.grants.added(rig_opt_json(ask, "signed"), pin=rig_opt_json(ask, "pin"), chain=rig_opt_json(ask, "chain"))
          Ok(
            match lock {
              Some(l) => Json::string(l)
              None => Json::null()
            },
          )
        }
        "device" => {
          let inst = get_inst(ask)
          inst.grants.device(rig_opt_json(ask, "signed"), rig_opt_json(ask, "chain"))
          Ok(Json::boolean(true))
        }
        "devices" => {
          let inst = get_inst(ask)
          Ok(Json::array(inst.grants.devices()))
        }
        "view" => {
          let inst = get_inst(ask)
          Ok(inst.grants.view().unwrap_or(Json::null()))
        }
        "takeEnded" => {
          let inst = get_inst(ask)
          let out = inst.ended.map(Json::string)
          inst.ended.clear()
          Ok(Json::array(out))
        }
        "close" => {
          let h = sn_int(ask, "handle", -1)
          match instances.get(h) {
            Some(inst) => {
              inst.grants.close()
              instances.remove(h)
              Ok(Json::boolean(true))
            }
            None => Err("no rig handle \{h}")
          }
        }
        _ => Err("unknown op \{op}")
      }
    } catch {
      e => Err(e.to_string())
    }
    match reply {
      Ok(v) => host.say(Json::object({ "id": id, "ok": v }).stringify())
      Err(m) => host.say(Json::object({ "id": id, "error": Json::string(m) }).stringify())
    }
  }
}
