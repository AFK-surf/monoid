// Dispatching Hub methods by their TypeScript names (`hub_call`), used by station_main's live P5-2 bridge.

///|
fn arg(args : Array[Json], i : Int) -> Json? {
  match args.get(i) {
    None => None
    Some(Object(m)) if m.get("$undefined") is Some(True) => None
    Some(v) => Some(v)
  }
}

///|
fn a(args : Array[Json], i : Int) -> Json {
  arg(args, i).unwrap_or(Json::null())
}

///|
fn a_str(args : Array[Json], i : Int) -> String {
  match arg(args, i) {
    Some(String(s)) => s
    Some(v) => js_string(v)
    None => ""
  }
}

///|
fn a_num(args : Array[Json], i : Int) -> Double {
  match arg(args, i) {
    Some(Number(n, ..)) => n
    _ => 0.0
  }
}

///|
fn a_arr(args : Array[Json], i : Int) -> Array[Json] {
  items(arg(args, i))
}

///|
fn opt_arg_str(args : Array[Json], i : Int) -> String? {
  match arg(args, i) {
    Some(String(s)) => Some(s)
    _ => None
  }
}

///|
fn bool_arg(args : Array[Json], i : Int) -> Bool {
  arg(args, i) is Some(True)
}

///|
fn strs(xs : Array[String]) -> Json {
  Json::array(xs.map(Json::string))
}

///|
fn opt_json(v : Json?) -> Json {
  match v {
    Some(j) => j
    None => Json::null()
  }
}

///|
fn pairs_json(xs : Array[(String, String)]) -> Json {
  Json::array(xs.map(p => Json::array([Json::string(p.0), Json::string(p.1)])))
}

///|
let checks : Array[UsageCheck] = []

///|
let agents_of : Array[AgentsSide] = []

///|
/// One of the hub's methods, by the TypeScript's name.
pub async fn hub_call(hub : Hub, name : String, x : Array[Json]) -> Json {
  let unit = undefined()
  match name {
    "hold" => {
      hub.hold(a_str(x, 0))
      unit
    }
    "release" => {
      hub.release(a_str(x, 0))
      unit
    }
    "holds" => Json::boolean(hub.holds(a_str(x, 0)))
    "suspendAll" => {
      hub.suspend_all()
      unit
    }
    "quiet" => {
      hub.quiet(a_str(x, 0))
      unit
    }
    "unquiet" => {
      hub.unquiet(a_str(x, 0))
      unit
    }
    "quietIn" => Json::boolean(hub.quiet_in(a_str(x, 0)))
    "ofWorkspace" => Json::boolean(hub.of_workspace(a_str(x, 0), a_str(x, 1)))
    "handedOver" => Json::boolean(hub.handed_over(a_str(x, 0)))
    "holdChat" => {
      hub.hold_chat(a_str(x, 0), a_str(x, 1), notice?=opt_arg_str(x, 2))
      unit
    }
    "releaseChat" => Json::boolean(hub.release_chat(a_str(x, 0)))
    "wakeChat" => {
      hub.wake_chat(a_str(x, 0))
      unit
    }
    "busy" => Json::boolean(hub.busy(a_str(x, 0)))
    "chatHeld" => opt_str(hub.chat_held(a_str(x, 0)))
    "held" => Json::boolean(hub.held(a_str(x, 0)))
    "moveOn" => Json::boolean(hub.move_on())
    "stoppedNotice" => opt_str(hub.stopped_notice(a_str(x, 0)))
    "movedTo" => opt_str(hub.moved_to(a_str(x, 0), a_str(x, 1), a_str(x, 2)))
    "leftWorkspace" => {
      hub.left_workspace(a_str(x, 0))
      unit
    }
    "backIn" => {
      hub.back_in(a_str(x, 0))
      unit
    }
    "running" => int(hub.running())
    "anyRunning" => Json::boolean(hub.any_running())
    "receive" => {
      hub.receive(a_str(x, 0), arg(x, 1).unwrap_or(Json::null()))
      unit
    }
    "accept" => {
      hub.accept(a_str(x, 0), arg(x, 1).unwrap_or(Json::null()))
      unit
    }
    "deliver" => {
      let options = arg(x, 4).unwrap_or(Json::object({}))
      hub.deliver(
        arg(x, 0).unwrap_or(Json::null()),
        arg(x, 1).unwrap_or(Json::null()),
        a_arr(x, 2).map(js_string),
        a_str(x, 3),
        retry_pending=is_true(options, "retryPending"),
        workspace?=match field(options, "workspace") {
          None => None
          Some(Object(m)) if m.get("$undefined") is Some(True) => None
          Some(String(w)) => Some(Some(w))
          Some(_) => Some(None)
        },
      )
      unit
    }
    "deliverLetter" => {
      hub.deliver_letter(arg(x, 0).unwrap_or(Json::null()), arg(x, 1).unwrap_or(Json::null()), a_arr(x, 2).map(js_string))
      unit
    }
    "shared" => {
      hub.shared(arg(x, 0).unwrap_or(Json::null()), arg(x, 1).unwrap_or(Json::null()), a_str(x, 2), a_str(x, 3))
      unit
    }
    "toolsAt" => {
      hub.tools_at(a_str(x, 0))
      unit
    }
    "recover" => {
      hub.recover()
      unit
    }
    "installed" => {
      hub.installed(a_str(x, 0))
      unit
    }
    "idleNow" => {
      hub.idle_now(a_str(x, 0))
      unit
    }
    "evictAllIdle" => int(hub.evict_all_idle())
    "evict" => {
      hub.evict(a_str(x, 0))
      unit
    }
    "changed" => {
      hub.changed(a_str(x, 0), restart=bool_arg(x, 1))
      unit
    }
    "allowanceReset" => {
      hub.allowance_reset(a_str(x, 0))
      unit
    }
    "everyChanged" => {
      hub.every_changed()
      unit
    }
    "runtimeUpdated" => {
      hub.runtime_updated(a_str(x, 0))
      unit
    }
    "profileLoginChanged" => {
      hub.profile_login_changed(a_str(x, 0))
      unit
    }
    "profileGone" => {
      hub.profile_gone(a_str(x, 0))
      unit
    }
    "followAccounts" => {
      let map : Map[String, String] = Map([])
      for e in a_arr(x, 1) {
        match e {
          Array(pair) if pair.length() == 2 => map[js_string(pair[0])] = js_string(pair[1])
          _ => ()
        }
      }
      int(hub.follow_accounts(a_arr(x, 0).map(js_string), map))
    }
    "warm" | "stop" | "cancelRetry" | "retryFailed" | "reassign" | "compact" | "notify" => {
      let r = hub.command(a_str(x, 0), name, x[1:].to_owned())
      if name == "compact" {
        r
      } else {
        unit
      }
    }
    "clear" => hub.command(a_str(x, 0), "clear", [Json::boolean(false), Json::boolean(bool_arg(x, 1))])
    "processState" => Json::string(hub.process_state(a_str(x, 0)))
    "processes" => pairs_json(hub.processes())
    "clientKey" =>
      match hub.client_key(a_str(x, 0)) {
        Some(k) => Json::string(k)
        None => unit
      }
    "clientKeys" => pairs_json(hub.client_keys())
    "noteLength" => {
      hub.note_length(a_str(x, 0), arg(x, 1).unwrap_or(Json::null()))
      unit
    }
    "surface" => Json::string(hub.surface(a_str(x, 0)))
    "wsOf" => opt_str(hub.ws_of_arg(arg(x, 0).unwrap_or(Json::null())))
    "profilesIn" => Json::array(hub.profiles_in(opt_arg_str(x, 0)))
    "inWorkspace" => {
      let key = a_str(x, 0)
      Json::boolean(hub.get_session(key) is Some(_) && hub.ws_of(Some(key)) == Some(a_str(x, 1)))
    }
    "modelsFor" => Json::array(hub.models_for(a_str(x, 0)))
    "modelsFirst" => Json::array(hub.models_first(a_str(x, 0), a_str(x, 1)))
    "createSession" => {
      hub.create_session(
        a_str(x, 0),
        hub.connect(a_str(x, 1)),
        a_str(x, 2),
        arg(x, 3),
        opt_arg_str(x, 4),
        opt_arg_str(x, 5),
      )
      unit
    }
    "handOver" => {
      let limit_ms = match arg(x, 0) {
        Some(Number(ms, ..)) => ms
        _ => 30_000.0
      }
      let partial = arg(x, 1) is Some(True)
      hub.hand_over(limit_ms~, partial~)
    }
    "takeUp" => {
      hub.take_up()
      unit
    }
    "endOrphan" => Json::boolean(hub.end_orphan(arg(x, 0).unwrap_or(Json::null()), a_num(x, 1)))
    "adopt" => {
      hub.adopt(arg(x, 0).unwrap_or(Json::null()))
      unit
    }
    "shutdown" => {
      hub.shutdown()
      unit
    }
    "dropActor" => Json::boolean(hub.drop_actor(a_str(x, 0)))
    "fetched" => {
      let (text, attachments) = hub.fetched(a_str(x, 0), a_str(x, 1), a_str(x, 2), a_arr(x, 3))
      { "text": Json::string(text), "attachments": Json::array(attachments) }
    }
    "told" => {
      // other stations' bots, as connects/workspace.ts tells them
      let bots : Set[String] = Set([])
      for b in a_arr(x, 1) {
        bots.add(js_string(b))
      }
      hub.told_bots[a_str(x, 0)] = bots
      unit
    }
    // lifecycle.ts
    "bindSingle" => Json::string(hub.bind_single(a_str(x, 0), opt_arg_str(x, 1), opt_arg_str(x, 2), opt_arg_str(x, 3)))
    "openChat" => hub.open_chat(a_str(x, 0), a_str(x, 1), opt_arg_str(x, 2))
    "addToThread" => {
      hub.add_to_thread(arg(x, 0).unwrap_or(Json::null()), a_str(x, 1))
      unit
    }
    "say" =>
      hub.say(
        arg(x, 0).unwrap_or(Json::null()),
        a_str(x, 1),
        a_str(x, 2),
        attachments=a_arr(x, 3),
        quotes=a_arr(x, 4),
        client?=opt_arg_str(x, 5),
      )
    "newSession" => {
      let (key, thread) = hub.new_session(arg(x, 0).unwrap_or(Json::null()), lang?=opt_arg_str(x, 1))
      [Json::string(key), thread]
    }
    "archive" => {
      hub.archive(a_str(x, 0), bool_arg(x, 1))
      unit
    }
    "archiveBy" => {
      hub.archive_by(a_str(x, 0), bool_arg(x, 1), a_str(x, 2))
      unit
    }
    "archiveChat" => {
      hub.archive_chat(arg(x, 0).unwrap_or(Json::null()), bool_arg(x, 1))
      unit
    }
    "deleteSession" => {
      hub.delete_session(a_str(x, 0))
      unit
    }
    "expireArchived" =>
      match hub.expire_archived(a_num(x, 0)) {
        Some(n) => num(n)
        None => Json::null()
      }
    "relieveArchived" => {
      hub.relieve_archived()
      unit
    }
    "continueMachineSession" => {
      let (key, thread) = hub.continue_machine_session(a(x, 0), a(x, 1), a_str(x, 2), lang?=opt_arg_str(x, 3), ws?=opt_arg_str(x, 4))
      [Json::string(key), thread]
    }
    "agents.start" | "agents.follow" => {
      let p = a(x, 0)
      let place : Place = {
        bound: is_true(p, "bound"),
        joined: items(field(p, "joined")).map(js_string),
        home: str_of(p, "home"),
        first: str_of(p, "first"),
        removed: is_true(p, "removed"),
        rig_due: is_true(p, "rigDue"),
        rig_pending: match field(p, "rigPending") {
          None | Some(Null) => None
          r => r
        },
      }
      let side = match agents_of.get(0) {
        Some(s) => s
        None => {
          let s = AgentsSide::new(hub, place)
          agents_of.push(s)
          s
        }
      }
      if name == "agents.start" {
        side.start(place)
      } else {
        side.follow(place)
      }
      unit
    }
    "autoArchive" => {
      let missing = Unprepared::new()
      let next = hub.auto_archive(a_num(x, 0), look?=arg(x, 1), missing~)
      { "next": match next { Some(n) => num(n); None => Json::null() }, "missing": missing.to_json() }
    }
    "configure" => {
      hub.configure(a_str(x, 0), arg(x, 1).unwrap_or(Json::null()), lang?=opt_arg_str(x, 2))
      unit
    }
    // afresh.ts, read/usage.ts `usageNow`
    "usageNow" => opt_json(hub.usage_now(a_str(x, 0)))
    "threadsToldOf" => strs(hub.threads_told_of(a_str(x, 0)))
    "startsAfresh" => opt_str(hub.starts_afresh(a_str(x, 0), a_str(x, 1), a_str(x, 2), opt_arg_str(x, 3)))
    "toldCleared" => Json::string(hub.told_cleared(a_str(x, 0), read_back=bool_arg(x, 1)))
    "goesAfresh" => Json::boolean(hub.goes_afresh(a_str(x, 0), a_num(x, 1)))
    "toldLongChat" => opt_str(hub.told_long_chat(a_str(x, 0)))
    "toldResumeLost" => Json::string(hub.told_resume_lost(a_str(x, 0)))
    // usage/: the counter, the usage kept, the checker
    "usageStart" => {
      let c = UsageCounter::new(hub)
      hub.counter = Some(c)
      hub.keeps_counted = true
      c.start()
      unit
    }
    "usageSoon" => {
      match hub.counter {
        Some(c) => c.soon(a_str(x, 0))
        None => ()
      }
      unit
    }
    "readingAll" =>
      match hub.counter {
        Some(c) => Json::boolean(c.reading_all())
        None => Json::boolean(true)
      }
    "untilTimer" => {
      if hub.timers.length() == 0 {
        let d : @effect.Deferred[Unit] = @effect.Deferred::new()
        hub.timer_waiters.push(d)
        d.wait()
      }
      unit
    }
    "usageDrain" => {
      let d = UsageDrain::new(hub)
      d.begin()
      unit
    }
    "retireUsage" => {
      hub.retire_usage()
      unit
    }
    "usageCheck" => {
      let c = match checks.get(0) {
        Some(c) => c
        None => {
          let c = UsageCheck::new(hub)
          checks.push(c)
          c
        }
      }
      match a_str(x, 0) {
        "remote" => c.ready_remote()
        "chats" => c.ready_chats(a(x, 1))
        "heard" => c.heard(a(x, 1))
        "exited" => c.exited(a_num(x, 1).to_int())
        "trim" => return int(c.trim_idle())
        "close" => c.close()
        other => raise Refused("no check call \{other}")
      }
      unit
    }
    "keepUsage" => {
      hub.keep_usage(a_str(x, 0), quiet=bool_arg(x, 1))
      unit
    }
    "usageStop" => {
      match hub.counter {
        Some(c) => c.stop()
        None => ()
      }
      unit
    }
    "storeCall" =>
      match a_str(x, 0) {
        "startTurn" => {
          hub.store.start_turn(a(x, 1), a(x, 2), a(x, 3))
          unit
        }
        "endTurn" => {
          hub.store.end_turn(a(x, 1), a(x, 2), a(x, 3), a(x, 4), a(x, 5))
          unit
        }
        "usageChanged" => {
          hub.store.usage_changed(a_arr(x, 1), None, bool_arg(x, 3))
          unit
        }
        other => raise Refused("no store call \{other}")
      }
    _ => raise Refused("no hub call \{name}")
  }
}
