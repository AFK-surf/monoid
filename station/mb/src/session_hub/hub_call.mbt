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
fn pairs_json(xs : Array[(String, String)]) -> Json {
  Json::array(xs.map(p => Json::array([Json::string(p.0), Json::string(p.1)])))
}

///|
/// One of the hub's methods, by the TypeScript's name.
pub async fn hub_call(hub : Hub, name : String, x : Array[Json]) -> Json {
  let unit = undefined()
  match name {
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
    "movedTo" => opt_str(hub.moved_to(a_str(x, 0), a_str(x, 1), a_str(x, 2)))
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
    "shared" => {
      hub.shared(arg(x, 0).unwrap_or(Json::null()), arg(x, 1).unwrap_or(Json::null()), a_str(x, 2), a_str(x, 3))
      unit
    }
    "evictAllIdle" => int(hub.evict_all_idle())
    "evict" => {
      hub.evict(a_str(x, 0))
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
    "processes" => pairs_json(hub.processes())
    "clientKeys" => pairs_json(hub.client_keys())
    "surface" => Json::string(hub.surface(a_str(x, 0)))
    "wsOf" => opt_str(hub.ws_of_arg(arg(x, 0).unwrap_or(Json::null())))
    "shutdown" => {
      hub.shutdown()
      unit
    }
    // lifecycle.ts
    "bindSingle" => Json::string(hub.bind_single(a_str(x, 0), opt_arg_str(x, 1), opt_arg_str(x, 2), opt_arg_str(x, 3)))
    "ensureConversationChat" => hub.ensure_conversation_chat(a_str(x, 0), a_str(x, 1), opt_arg_str(x, 2))
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
    "archiveChat" => {
      hub.archive_chat(arg(x, 0).unwrap_or(Json::null()), bool_arg(x, 1))
      unit
    }
    "deleteSession" => {
      hub.delete_session(a_str(x, 0))
      unit
    }
    "relieveArchived" => {
      hub.relieve_archived()
      unit
    }
    "continueMachineSession" => {
      let (key, thread) = hub.continue_machine_session(a(x, 0), a(x, 1), a_str(x, 2), lang?=opt_arg_str(x, 3), ws?=opt_arg_str(x, 4))
      [Json::string(key), thread]
    }
    "configure" => {
      hub.configure(a_str(x, 0), arg(x, 1).unwrap_or(Json::null()), lang?=opt_arg_str(x, 2))
      unit
    }
    // usage/
    "readingAll" =>
      match hub.counter {
        Some(c) => Json::boolean(c.reading_all())
        None => Json::boolean(true)
      }
    _ => raise Refused("no hub call \{name}")
  }
}
