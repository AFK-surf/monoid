// The tools whose work is one part's (station/src/tools/jobs.ts, remote.ts, forward.ts, retire.ts, archive.ts,
// workspace-size.ts; src/devices/tool.ts, src/rigs/tool.ts): their arguments read and checked as the TypeScript reads
// them, the part asked, its answer said.

///|
/// A JSON number serde reads as a u64: a whole number, not negative.
fn as_u64(v : JV?) -> Double? {
  match v {
    Some(Num(n)) if is_integer(n) && n >= 0.0 => Some(n)
    _ => None
  }
}

///|
/// The job a tool names (`id`), when it is this session's.
async fn owned_job(c : Ctx, jobs : String, key : String, args : JV) -> JV {
  let id = trim_js(text(args.get("id")))
  let job = c.b.ask("\{jobs}.store.getJob", [js(id)])
  if !truthy(Some(job)) {
    raise Failed("no job \{id}: job_list names this session's")
  }
  if !(jstr(job.get("sessionKey")) == Some(key)) {
    raise Failed("job \{id} is another session's")
  }
  job
}

///|
/// job_start, job_list, job_log, job_stop (tools/jobs.ts): the jobs part (`jobs`), a session's workspace directory
/// (`workspace`: null for a session there is not), how a cwd given is looked at (`places`: none, not at all).
pub fn job_tools(
  c : Ctx,
  jobs? : String = "jobs",
  workspace? : String = "jobs.workspace",
  places? : String? = Some("places"),
) -> Array[Tool] {
  let b = c.b
  [
    Tool::new(c.decl("job_start"), (key, args, _) => {
      let home = match b.ask(workspace, [js(key)]) {
        Str(h) => h
        _ => raise Failed("unknown session")
      }
      let given = trim_js(text(args.get("cwd")))
      let cwd = if given == "" {
        home
      } else if c.consts.os == "windows" {
        @ops_platform.win_join(home, given)
      } else {
        @ops_platform.unix_join(home, given)
      }
      let mut port : JV = Null
      if !absent(args.get("port")) && !(args.get("port") is Some(Null)) {
        match as_u64(args.get("port")) {
          Some(p) if p <= 65535.0 => port = jnum(p)
          _ => raise Failed("port must be a number from 1024 to 65535")
        }
      }
      let watch = is_true(args.get("watch"))
      match places {
        Some(p) if given != "" =>
          b.tell("\{p}.directory", [
            js(cwd),
            jobj([("lang", js("en")), ("agent", jbool(true))]),
          ])
        _ => ()
      }
      let job = b.ask("\{jobs}.start", [
        js(key),
        js(text(args.get("name"))),
        js(text(args.get("command"))),
        js(cwd),
        port,
        jbool(watch),
        jbool(places is Some(_) && given != ""),
      ])
      pretty(b.ask("\{jobs}.view", [job]))
    }),
    Tool::new(c.decl("job_list"), (key, _, _) => {
      let list = jitems(Some(b.ask("\{jobs}.store.listJobs", [js(key)])))
      let views = []
      for j in list {
        views.push(b.ask("\{jobs}.view", [j]))
      }
      if views.length() == 0 {
        "No jobs."
      } else {
        pretty(jarr(views))
      }
    }),
    Tool::new(c.decl("job_log"), (key, args, _) => {
      let job = owned_job(c, jobs, key, args)
      let lines = match as_u64(args.get("lines")) {
        None => 50.0
        Some(n) => if n < 1.0 { 1.0 } else if n > 1000.0 { 1000.0 } else { n }
      }
      let log = said_text(b.ask("jobs/jobs.tail", [field(job, "log"), jnum(lines)]))
      if log == "" {
        "\{said_text(b.ask("jobs/jobs.named", [job]))} has written nothing yet."
      } else {
        log
      }
    }),
    Tool::new(c.decl("job_stop"), (key, args, _) => {
      let id = field(owned_job(c, jobs, key, args), "id")
      let job = b.ask("\{jobs}.stop", [id])
      "\{said_text(b.ask("jobs/jobs.named", [job]))} is \{js_string(job.get("state"))}."
    }),
  ]
}

///|
/// station_list, station_task, station_file (tools/remote.ts): what they do is Remote.tool.
pub fn remote_tools(c : Ctx, remote? : String = "remote") -> Array[Tool] {
  ["station_list", "station_task", "station_file"].map(name => Tool::new(
    c.decl(name),
    (session, args, _) => {
      let out = c.b.ask("\{remote}.tool", [js(name), js(session), args])
      pretty(if is_undef(out) { Null } else { out })
    },
  ))
}

///|
/// peer_forward (tools/forward.ts): with station and port it opens one, with close it closes one, with nothing it
/// lists the session's.
pub fn forward_tools(c : Ctx, forwards? : String = "forwards") -> Array[Tool] {
  let b = c.b
  [
    Tool::new(c.decl("peer_forward"), (session, args, _) => {
      let int = (key : String) => {
        match args.get(key) {
          None | Some(Null) => None
          Some(v) if is_undef(v) => None
          Some(Num(n)) if is_integer(n) && n >= 1.0 && n <= 65535.0 => Some(n)
          _ => raise Failed("\{key}: a port, 1 to 65535")
        }
      }
      let close = int("close")
      let station = trimmed(args.get("station"))
      let port = int("port")
      match close {
        Some(local) => {
          if station != "" || port is Some(_) {
            raise Failed("close takes no station or port")
          }
          let was = b.ask("\{forwards}.remove", [js(session), jnum(local)])
          return "Closed \{js_string(was.get("local"))} (to \{js_string(was.get("station"))}:\{js_string(was.get("port"))})."
        }
        None => ()
      }
      if station == "" && port is None {
        let list = b.ask("\{forwards}.list", [js(session)])
        return if jitems(Some(list)).length() == 0 {
          "No forwarded ports."
        } else {
          pretty(list)
        }
      }
      guard port is Some(port) && station != "" else {
        raise Failed(
          "give both station and port to forward one (none: list them; close: close one)",
        )
      }
      let job = match args.get("job") {
        Some(Str(j)) if trim_js(j) != "" => js(trim_js(j))
        _ => jundef
      }
      let local = match int("local_port") {
        Some(n) => jnum(n)
        None => jundef
      }
      pretty(
        b.ask("\{forwards}.open", [js(session), js(station), jnum(port), local, job]),
      )
    }),
  ]
}

///|
/// station_retire (tools/retire.ts): what it does is RetireAsks.tool.
pub fn retire_tools(c : Ctx, asks? : String = "retireAsks") -> Array[Tool] {
  [
    Tool::new(c.decl("station_retire"), (session, args, _) => pretty(
      c.b.ask("\{asks}.tool", [js(session), args]),
    )),
  ]
}

///|
/// archive_policy (tools/archive.ts): the archive policy of the workspace a session's chat is in, read or changed.
pub fn archive_tools(c : Ctx, hub? : JV = jref("hub")) -> Array[Tool] {
  let b = c.b
  [
    Tool::new(c.decl("archive_policy"), (key, args, _) => {
      let ws = b.ask("sessions/review.policyWs", [hub, js(key)])
      let store = jref("\{ref_of(hub).unwrap_or("hub")}.store")
      let now = b.ask("sessions/archive-policy.currentPolicy", [store, ws])
      if absent(args.get("policy")) && absent(args.get("options")) {
        return pretty(now)
      }
      let pick = (k : String) => match args.get(k) {
        None | Some(Null) => field(now, k)
        Some(v) if is_undef(v) => field(now, k)
        Some(v) => v
      }
      let next = jobj([("policy", pick("policy")), ("options", pick("options"))])
      let changed = b.ask("sessions/archive-policy.savePolicy", [
        store,
        next,
        jobj([("kind", js("agent")), ("session", js(key))]),
        ws,
      ])
      if changed is Null {
        return "Nothing changed: the policy is already so."
      }
      b.tell("sessions/review.reviewUndecided", [hub]) catch {
        _ => ()
      }
      "Saved (\{js_string(Some(changed))}). The done chats are checked again under it; this chat is when your turn ends all_done. Tell the person what you changed."
    }),
  ]
}

///|
/// workspace_limit (tools/workspace-size.ts): the MCP token supplies the chat: a caller can change only its own
/// workspace's limit on a station it has used.
pub fn workspace_size_tools(
  c : Ctx,
  watch? : String = "workspaceWatch",
  remote? : String = "remote",
) -> Array[Tool] {
  let b = c.b
  [
    Tool::new(c.decl("workspace_limit"), (session, args, _) => {
      let named = trimmed(args.get("station"))
      let station = b.ask("\{remote}.workspaceStation", [js(session), js(named)])
      b.tell("\{watch}.ready", [])
      if !absent(args.get("limit_gib")) {
        guard args.get("limit_gib") is Some(Num(_) as limit) else {
          raise Failed("limit_gib must be a positive whole number of GiB")
        }
        b.tell("\{watch}.setLimit", [js(session), station, limit])
      }
      let limit = match b.ask("\{watch}.limit", [js(session), station]) {
        Num(n) => jnum(n / 1073741824.0)
        _ => jnum(0.0 / 0.0)
      }
      let shown = if truthy(Some(station)) { station } else { js("this station") }
      stringify(jobj([("station", shown), ("limit_gib", limit)]))
    }),
  ]
}

///|
/// device_list, device_use (src/devices/tool.ts): how a chat's agent finds the workspace's devices and asks for one.
pub fn device_tools(c : Ctx, d? : String = "devices") -> Array[Tool] {
  let b = c.b
  [
    Tool::new(c.decl("device_list"), (session, _, _) => {
      let all = b.ask("\{d}.list", [js(session)])
      if jitems(Some(all)).length() == 0 {
        "No device is attached to this workspace's stations, and no phone is lent to this station. A member adds one on a station's page in the still.fail app (添加设备); a person lends their Android phone by turning on 共享调试 in the app on it."
      } else {
        pretty(all)
      }
    }),
    Tool::new(c.decl("device_use"), (session, args, signal) => {
      let device = trimmed(args.get("device"))
      if is_true(args.get("done")) {
        return said_text(b.ask("\{d}.done", [js(session), js(device)]))
      }
      said_text(
        b.ask("\{d}.use", [
          js(session),
          js(device),
          js(text(args.get("reason"))),
          field(args, "timeout"),
          signal,
        ]),
      )
    }),
  ]
}

///|
/// Where a device is reached here once forwarded (`port` on 127.0.0.1), in words for its kind.
pub fn reached_at(e : JV, port : Int) -> String {
  let name = js_string(e.get("name"))
  let target = js_string(e.get("target"))
  match jstr(e.get("kind")) {
    Some("adb") =>
      "\{name} is reached here through the adb server of the machine it is on: `adb -P \{port} -s \{target} …` (-P on every adb command; never adb kill-server on it). Only this chat's processes connect."
    Some("serial") => {
      let baud = match e.get("baud") {
        None | Some(Null) => "115200"
        Some(v) if is_undef(v) => "115200"
        Some(v) => js_string(Some(v))
      }
      "\{name} (serial \{target}, \{baud} baud, set raw there) is at 127.0.0.1:\{port}: its bytes both ways, e.g. `socat - TCP:127.0.0.1:\{port}` or a socket in a script. Only this chat's processes connect."
    }
    _ =>
      "\{name} (\{target}) is at 127.0.0.1:\{port}: connect to it there as you would to \{target} (http://127.0.0.1:\{port}/, ssh -p \{port} …). Only this chat's processes connect."
  }
}

///|
/// station_use (src/rigs/tool.ts): how a chat's agent asks for a station that only runs tasks, and hands it back.
pub fn rig_tools(c : Ctx, use_? : String = "rigUse") -> Array[Tool] {
  let b = c.b
  [
    Tool::new(c.decl("station_use"), (session, args, signal) => {
      let rig = trimmed(args.get("station"))
      if is_true(args.get("done")) {
        return said_text(b.ask("\{use_}.done", [js(session), js(rig)]))
      }
      if rig == "" {
        raise Failed("station is required (its name from station_list)")
      }
      let timeout = match args.get("timeout") {
        Some(Obj(_) as t) if !is_undef(t) =>
          jobj([("kind", field(t, "kind")), ("seconds", field(t, "seconds"))])
        Some(Arr(_)) => jobj([("kind", jundef), ("seconds", jundef)])
        _ => jundef
      }
      said_text(
        b.ask("\{use_}.ask", [
          js(session),
          js(rig),
          js(text(args.get("reason"))),
          timeout,
          signal,
        ]),
      )
    }),
  ]
}
