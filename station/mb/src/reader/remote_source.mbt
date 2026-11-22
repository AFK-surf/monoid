// The source's side of the remote tasks (remote.ts): a task started from here followed until its end is told to its
// session (`check`, `round`, `settle`), a task here told to the station it came from (`push_out`), the chats' use of
// other stations and their closing there (`record_use`, `close_session`, `closer`), and the station_* tools.

///|
/// Whether the task's station tells of it itself (`task.changed`).
fn pushes(got : Json) -> Bool {
  field_of(field_of(got, "result"), "push") is True
}

///|
/// The tasks started from here not told yet followed again, and those here whose source missed their last change told
/// (the transport is there: Node's `attached`).
async fn Actors::resume(self : Actors) -> Unit raise {
  let outgoing = self.rjoin([self.remote.root, "outgoing"])
  let followed : Array[String] = []
  for name in self.readdir_names(outgoing) {
    if self.remote.stopped {
      return
    }
    if !name.has_suffix(".json") {
      continue
    }
    let path = self.rjoin([outgoing, name])
    let v = self.read_json(path) catch { _ => continue }
    if !(field_of(v, "delivered") is True) {
      followed.push(path)
    }
  }
  // All found before any is asked about: those on one station are asked about together, once.
  let groups : Map[String, Array[String]] = {}
  for path in followed {
    let entry = self.read_json(path) catch { _ => continue }
    let group = js_text(Json::array([jstr(text_of(entry, "station")), field_of(entry, "workspace")]))
    let g = groups.get(group).unwrap_or([])
    g.push(path)
    groups[group] = g
  }
  for group, paths in groups {
    let parts = @json.parse(group) catch { _ => continue }
    let (station, workspace) = match parts {
      Array([String(s), w]) => (s, w)
      _ => continue
    }
    self.spawn(() => try {
      for o in self.round(station, workspace, paths, true) {
        self.after_outcome(o.0, o.1, o.2)
      }
    } catch {
      _ => ()
    })
  }
}

///|
async fn Actors::push_missed(self : Actors) -> Unit raise {
  let incoming = self.rjoin([self.remote.root, "incoming"])
  for name in self.readdir_names(incoming) {
    if self.remote.stopped {
      return
    }
    let meta = self.read_json(self.rjoin([incoming, name, "task.json"])) catch { _ => continue }
    if text_of(meta, "push") != "" && field_of(meta, "pushed") != self.said(name) {
      self.push_out(name)
    }
  }
}

///|
/// Tells the station a task here came from that it changed (`task.changed`, which asks then); asked again until it is
/// reached. Its last change told is kept in its record (`pushed`).
fn Actors::push_out(self : Actors, id : String) -> Unit {
  if self.remote.stopped || id == "" {
    return
  }
  if self.remote.pushing.contains(id) {
    self.remote.pushing[id] = true
    return
  }
  self.remote.pushing[id] = false
  let record = self.rjoin([self.remote.root, "incoming", id, "task.json"])
  self.again(
    async fn() {
      self.remote.pushing[id] = false
      try {
        let meta = self.read_json(record) catch { _ => return true }
        let push = text_of(meta, "push")
        let said = self.said(id)
        if push == "" || said is Null || field_of(meta, "pushed") == said {
          return true
        }
        try {
          ignore(self.ask(text_of(meta, "station"), { "method": jstr("task.changed"), "workspace": field_of(meta, "workspace"), "ref": jstr(push) }))
        } catch {
          // A refusal is final (the source no longer has the task); anything else is asked again.
          e => if !refused(e) { return false }
        }
        ignore(self.update_json(record, now => Some(with_field(now, "pushed", said)))) catch { _ => () }
        true
      } catch {
        _ => false
      }
    },
    _ => {
      let more = self.remote.pushing.get(id) == Some(true)
      self.remote.pushing.remove(id)
      if more {
        self.push_out(id)
      }
    },
  )
}

///|
/// `task.changed`: the station of a task started from here says it changed; asked what, after the answer.
async fn Actors::changed_there(self : Actors, workspace : String, request : Json) -> Json raise {
  let ref_ = text_of(request, "ref")
  if !is_hex64(ref_) {
    raise refusal("ref is required")
  }
  let path = self.rjoin([self.remote.root, "outgoing", "\{ref_}.json"])
  let entry = self.read_json(path) catch { _ => raise refusal("unknown task") }
  // Only what the task's own station says is taken (`check` asks that one), so this need not be from it.
  if text_of(entry, "workspace") != workspace {
    raise refusal("unknown task")
  }
  self.check(path)
  { "taken": jbool(true) }
}

///|
/// What follows an outcome ("over", "wait", "again", or a time to ask at).
fn Actors::after_outcome(self : Actors, path : String, outcome : Json, got : Json) -> Unit {
  match outcome {
    String("again") => self.check(path)
    Number(at, ..) => self.later(path, at)
    String("wait") if !pushes(got) => self.spawn(() => try { self.unfollowed(path) } catch { _ => () })
    _ => ()
  }
}

///|
/// Asks the station of the task started from here (`path`) about it now, and again until it is reached and what it
/// said is told.
fn Actors::check(self : Actors, path : String) -> Unit {
  if self.remote.stopped {
    return
  }
  if self.remote.checking.contains(path) {
    self.remote.checking[path] = true
    return
  }
  self.remote.checking[path] = false
  let last : Ref[(Json, Json)] = { val: (jstr("over"), Json::null()) }
  self.again(
    async fn() {
      self.remote.checking[path] = false
      try {
        let entry = self.read_json(path) catch { _ => return true }
        let rounds = self.round(text_of(entry, "station"), field_of(entry, "workspace"), [path], true)
        last.val = if rounds.length() == 0 { (jstr("over"), Json::null()) } else { (rounds[0].1, rounds[0].2) }
        last.val.0 != jstr("again")
      } catch {
        _ => false
      }
    },
    _ => {
      let more = self.remote.checking.get(path) == Some(true)
      self.remote.checking.remove(path)
      if more {
        self.check(path)
      } else {
        self.after_outcome(path, if last.val.0 == jstr("again") { jstr("wait") } else { last.val.0 }, last.val.1)
      }
    },
  )
}

///|
/// Asks about the task started from here (`path`) at `at`: one its station has not started, or does not know.
fn Actors::later(self : Actors, path : String, at : Double) -> Unit {
  if self.remote.stopped {
    return
  }
  self.spawn(() => {
    let now = self.remote_now() catch { _ => at }
    ignore(self.rafter(if at - now < 0.0 { 0.0 } else { at - now }, () => self.check(path)))
  })
}

///|
/// A task on a station from before `task.changed`: that station never tells of it; its session is told so, once.
async fn Actors::unfollowed(self : Actors, path : String) -> Unit raise {
  let entry = self.read_json(path) catch { _ => return }
  if field_of(entry, "delivered") is True {
    return
  }
  let message = "Remote task \{text_of(entry, "key")} on \{text_of(entry, "station")}: that station is from before it tells how its tasks go, so this one is not followed. Update that station, or ask with get."
  self.told_then_written(path, text_of(entry, "session"), message, with_field(entry, "delivered", jbool(true))) catch {
    _ => return
  }
}

///|
/// Asks `station` once about the tasks of `paths` (those still to be told), what it says settled: each one's outcome.
async fn Actors::round(self : Actors, station : String, workspace : Json, paths : Array[String], batched : Bool) -> Array[(String, Json, Json)] raise {
  let entries : Array[(String, Json)] = []
  for path in paths {
    let entry = self.read_json(path) catch { _ => continue }
    if !(field_of(entry, "delivered") is True) {
      entries.push((path, entry))
    }
  }
  if entries.length() == 0 {
    return []
  }
  let got = self.states(station, workspace, entries.map(e => e.1), batched)
  let out : Array[(String, Json, Json)] = []
  for i, e in entries {
    out.push((e.0, self.settle(e.0, e.1, got[i]), got[i]))
  }
  out
}

///|
/// What `station` says of each of `entries`' tasks: {result}, {refused}, or null when it was not reached; in one request
/// while `batched` (a station from before refuses it).
async fn Actors::states(self : Actors, station : String, workspace : Json, entries : Array[Json], batched : Bool) -> Array[Json] raise {
  let ref_ = (e : Json) => ({ "session": field_of(e, "session"), "key": field_of(e, "key") } : Json)
  if batched {
    let out : Array[Json] = []
    let ok = try {
      let mut i = 0
      while i < entries.length() {
        let part = entries[i:if i + gets_max < entries.length() { i + gets_max } else { entries.length() }].to_array()
        let answer = self.ask(station, { "method": jstr("task.gets"), "workspace": workspace, "tasks": Json::array(part.map(ref_)) })
        match field_of(answer, "tasks") {
          Array(tasks) if tasks.length() == part.length() =>
            for t in tasks {
              out.push(match field_of(t, "error") {
                String(e) => { "refused": jstr(e) }
                _ => { "result": field_of(t, "result") }
              })
            }
          _ => raise Asked({ "message": jstr("task.gets is not answered there"), "kind": jstr("Refused") })
        }
        i += gets_max
      }
      true
    } catch {
      e => if !refused(e) { return entries.map(_ => Json::null()) } else { false }
    }
    if ok {
      return out
    }
  }
  let out : Array[Json] = []
  for e in entries {
    let request = with_field(with_field(with_field(ref_(e), "method", jstr("task.get")), "workspace", workspace), "session", field_of(e, "session"))
    out.push(
      try {
        ({ "result": self.ask(station, request) } : Json)
      } catch {
        err => if refused(err) { { "refused": jstr(Asked::message(err)) } } else { Json::null() }
      },
    )
  }
  out
}

///|
/// One round's answer about the task of `entry` (the record at `path`): what it said on the way and how it ended told
/// its session; what comes of it.
async fn Actors::settle(self : Actors, path : String, entry : Json, got : Json) -> Json raise {
  if got is Null {
    return jstr("again")
  }
  let now = self.remote_now()
  let entry = if field_of(entry, "since") is Number(_, ..) {
    entry
  } else {
    let e = with_field(entry, "since", jnum(now))
    self.write_json(path, e) catch { _ => return jstr("again") }
    e
  }
  let since = num_of(Some(field_of(entry, "since"))).unwrap_or(now)
  let result = field_of(got, "result")
  // Never started there: asked about once more when it would have started, then given up on, said once.
  let unknown = match field_of(got, "refused") {
    String(r) => r.contains("unknown task")
    _ => false
  }
  if unknown || (!(result is Null) && field_of(result, "job") is Null) {
    if now - since < give_up_ms {
      return jnum(since + give_up_ms)
    }
    let why = if unknown { "that station does not know it" } else { "it is prepared there but was never started" }
    let message = "Remote task \{text_of(entry, "key")} on \{text_of(entry, "station")}: \{why} \{(give_up_ms / 60000.0).to_int()} minutes after its start was asked for, and is no longer followed. Ask with get, or prepare and start it again."
    self.told_then_written(path, text_of(entry, "session"), message, with_field(with_field(entry, "delivered", jbool(true)), "lost", jbool(true))) catch {
      _ => return jstr("again")
    }
    return jstr("over")
  }
  if result is Null {
    return jstr("again")
  }
  let state = text_of(field_of(result, "job"), "state")
  let notices = field_of(result, "notices")
  let finished = state != "" && state != "running"
  let mut entry = entry
  // What the task was to bring back, and what it changed of its directory, comes before its end is told (once).
  if finished && field_of(entry, "brought") is Null && !(entry.value("brought") is Some(_)) &&
    (field_of(entry, "back") is Array(_) || field_of(entry, "dir") is String(_)) {
    let brought = try {
      self.rnode("bringBack", [entry])
    } catch {
      e => {
        if e is Asked(j) && j.value("kind") is Some(String("Unreached")) {
          return jstr("again")
        }
        ({ "error": jstr(Asked::message(e)) } : Json)
      }
    }
    entry = with_field(entry, "brought", brought)
    self.write_json(path, entry) catch { _ => return jstr("again") }
  }
  let mut result = result
  if finished && field_of(entry, "dir") is String(_) && entry.value("brought") is Some(brought) {
    let missing = match field_of(field_of(brought, "files"), "missing") { Array(m) => m; _ => [] }
    let changed = field_of(brought, "changed")
    let incomplete = !(field_of(brought, "error") is Null) ||
      !(field_of(changed, "error") is Null) ||
      field_of(changed, "more") is True ||
      (match field_of(changed, "notInPatch") { Array(a) => a.length() > 0; _ => false }) ||
      missing.iter().any(m => !(m is String(s) && s.has_suffix(": not there")))
    if incomplete {
      entry = with_field(entry, "brought", with_field(brought, "pending", jstr("Some results were not brought back. Preserve them with station_file; then station_task release permits the next task in this mirror.")))
    } else {
      try {
        ignore(self.ask(text_of(entry, "station"), { "method": jstr("task.collected"), "workspace": field_of(entry, "workspace"), "session": field_of(entry, "session"), "key": field_of(entry, "key") }))
      } catch {
        // An old target has no result fence. New targets retain it until this acknowledgement is received.
        e => if !(refused(e) && Asked::message(e).contains("unsupported peer method")) { return jstr("again") }
      }
    }
  }
  if finished && entry.value("brought") is Some(b) && result is Object(_) {
    result = with_field(result, "back", b)
  }
  let new_notices = match notices { Array(n) => n.length() > 0 && !json_equal(field_of(entry, "notices"), notices); _ => false }
  if finished || new_notices {
    let message = "Remote task \{text_of(entry, "key")} on \{text_of(entry, "station")}: \{js_text(result)}"
    self.told_then_written(path, text_of(entry, "session"), message, with_field(with_field(entry, "notices", notices), "delivered", jbool(finished))) catch {
      _ => return jstr("again")
    }
  }
  jstr(if finished { "over" } else { "wait" })
}

///|
/// A session was archived or deleted: its tasks started from here are no longer followed, its prepared tasks go
/// (`close_session`, which writes its use record closing and asks its stations to remove its directories).
async fn Actors::unfollow_session(self : Actors, session : String) -> Unit raise {
  let outgoing = self.rjoin([self.remote.root, "outgoing"])
  for name in self.readdir_names(outgoing) {
    let file = self.rjoin([outgoing, name])
    let seen = self.read_json(file) catch { _ => continue }
    if text_of(seen, "session") != session || field_of(seen, "delivered") is True {
      continue
    }
    ignore(self.update_json(file, e => if field_of(e, "delivered") is True { None } else { Some(with_field(e, "delivered", jbool(true))) })) catch { _ => () }
  }
  self.remove(self.prepared_dir(session), recursive=true) catch { _ => () }
}

///|
fn Actors::prepared_dir(self : Actors, session : String) -> String {
  self.rjoin([self.remote.root, "prepared", rhash(jstr(session))])
}

///|
fn Actors::outgoing_path(self : Actors, workspace : String, session : String, station : String, key : String) -> String {
  self.rjoin([self.remote.root, "outgoing", "\{rhash(Json::array([jstr(workspace), jstr(session), jstr(station), jstr(key)]))}.json"])
}

///|
/// The sync of a directory to a station for task `key` (dirsync_source.mbt `sync_dir`): the one under way, or ended and not
/// yet taken, when it is that task's; otherwise a new one, begun once the one before it (another task's) has ended.
async fn Actors::sync_of(self : Actors, id : String, key : String, args : Array[Json]) -> SyncRun raise {
  let now = self.remote_now()
  let was = self.remote.syncs.get(id)
  if was is Some(w) && w.key == key && (w.ended_at is None || now - w.ended_at.unwrap_or(0.0) < sync_kept_ms) {
    return w
  }
  let run : SyncRun = { key, result: @effect.Deferred::new(), ended_at: None }
  self.remote.syncs[id] = run
  self.spawn(() => {
    if was is Some(w) {
      ignore(w.result.wait()) catch { _ => () }
    }
    let got = try {
      let arg = (i : Int) => str_of(Some(args[i])).unwrap_or("")
      ({ "ok": self.sync_dir(arg(0), arg(1), arg(2), arg(3), arg(4)) } : Json)
    } catch {
      e => match e {
        Asked(j) => { "error": j }
        _ => { "error": { "message": jstr(FsError::of(e)) } }
      }
    }
    let at = self.remote_now() catch { _ => 0.0 }
    run.ended_at = Some(at)
    ignore(run.result.succeed(got))
  })
  run
}

///|
/// The workspace a session's tasks go in (mesh/cloud.json): its chat's, the home one for those from before; while the
/// station is still in it.
async fn Actors::task_workspace(self : Actors, own : Json) -> String raise {
  let state = self.rnode("cloudState", [])
  if state is Null {
    raise refusal("station has no workspace")
  }
  if !(field_of(state, "removed_at") is Null) {
    raise refusal("station was removed from workspace")
  }
  let home = text_of(state, "workspace")
  if home == "" {
    raise refusal("station has no workspace")
  }
  let ws = match own { String(w) => w; _ => home }
  let joined = match field_of(state, "joined") { Array(j) => j; _ => [] }
  if ws != home && !joined.iter().any(j => text_of(j, "workspace") == ws) {
    raise refusal("station is no longer in this chat's workspace")
  }
  ws
}

///|
async fn Actors::own_id(self : Actors) -> String {
  let state = self.rnode("cloudState", []) catch { _ => Json::null() }
  text_of(state, "station")
}

///|
/// Parses an explicit cross-station sandbox id `sandbox:<hostId>:<name>`.
fn parse_remote_sandbox_id(named : String) -> (String, String)? {
  if !named.has_prefix("sandbox:") {
    return None
  }
  let rest = named.view(start_offset=8).to_string()
  match rest.find(":") {
    Some(i) if i > 0 && i < rest.length() - 1 => {
      let host_id = rest.view(end_offset=i).to_string()
      let name = rest.view(start_offset=i + 1).to_string()
      if name.contains(":") { None } else { Some((host_id, name)) }
    }
    _ => None
  }
}

///|
/// The id of the station an agent names: by its name or its id, either taken; a local sandbox by `sandbox:<name>` or
/// its name; a remote sandbox by `sandbox:<hostId>:<name>` or advertised name. A name no station of the workspace has
/// goes on as given, to be refused or reached as an id.
async fn Actors::station_named(self : Actors, workspace : String, named : String) -> String raise {
  if named == "" {
    return named
  }
  let lower = named.to_lower()
  match self.rnode("sandboxes", [jstr(workspace)]) {
    Array(list) =>
      for d in list {
        let name = text_of(d, "name")
        if ("sandbox:" + name).to_lower() == lower || name.to_lower() == lower {
          return "sandbox:" + name
        }
      }
    _ => ()
  }
  let roster = try {
    self.ask("", { "method": jstr("peers"), "workspace": jstr(workspace) })
  } catch {
    _ => return named
  }
  let stations : Array[Json] = []
  for k in ["stations", "rigs", "unprotected"] {
    if field_of(roster, k) is Array(l) {
      stations.push_iter(l.iter())
    }
  }
  if parse_remote_sandbox_id(named) is Some((host_id, sb_name)) {
    if host_id == self.own_id() {
      return "sandbox:" + sb_name
    }
    if stations.iter().any(s => text_of(s, "id") == host_id) {
      return "sandbox:\{host_id}:\{sb_name}"
    }
  }
  if stations.iter().any(s => text_of(s, "id") == named) {
    return named
  }
  let same = stations.filter(s => text_of(s, "name").to_lower() == lower)
  if same.length() > 1 {
    raise refusal("\{same.length()} stations are named \{named}; give the id station_list shows for the one meant")
  }
  if same.length() == 1 {
    return text_of(same[0], "id")
  }
  match field_of(roster, "rigsWaiting") {
    Array(w) =>
      match w.search_by(r => text_of(r, "id") == named || text_of(r, "name").to_lower() == lower) {
        Some(i) => {
          let r = w[i]
          let name = if text_of(r, "name") != "" { text_of(r, "name") } else { named }
          let owner = if text_of(r, "owner_email") != "" { text_of(r, "owner_email") } else { text_of(r, "owner") }
          raise refusal("the station \{name} is not taken into this workspace yet: its owner \{owner} has to check its security code in still.fail first")
        }
        None => ()
      }
    _ => ()
  }
  match (self.rnode("remoteSandboxes", [jstr(workspace)]) catch { _ => Json::null() }) {
    Array(list) => {
      let matches = list.filter(d => {
        let id = text_of(d, "id").to_lower()
        let name = text_of(d, "name").to_lower()
        id == lower || ("sandbox:" + name) == lower || name == lower
      })
      if matches.length() > 1 {
        let ids = matches.map(d => text_of(d, "id")).join(", ")
        raise refusal("\{matches.length()} stations offer sandbox \{named}; give the full id station_list shows (\{ids})")
      }
      if matches.length() == 1 {
        return text_of(matches[0], "id")
      }
    }
    _ => ()
  }
  named
}

///|
/// What the station_* tools do, as `session`: among the stations of its workspace.
async fn Actors::tool(self : Actors, tool : String, session : String, args : Json) -> Json raise {
  let row = self.rstore("getSession", [jstr(session)])
  if row is Null {
    raise refusal("unknown session")
  }
  let workspace = self.task_workspace(field_of(row, "ws"))
  let station = self.station_named(workspace, text_of(args, "station"))
  if tool == "station_list" {
    // (the stations asked how busy each is, the rigs and sandboxes: Node's, as station_list was)
    return self.rnode("listStations", [jstr(workspace), jstr(session), jstr(station)])
  }
  let key = text_of(args, "key")
  let action = if tool == "station_task" { text_of(args, "action") } else { "" }
  let session_action = ["list", "mirrors", "clean"].contains(action)
  if station == "" || (key == "" && !session_action) {
    raise refusal("station and key are required (list, mirrors and clean need only station)")
  }
  if !session_action {
    ignore(self.record_use(workspace, session, station))
  }
  let request : Map[String, Json] = { "workspace": jstr(workspace), "session": jstr(session), "key": jstr(key) }
  if tool != "station_task" {
    // station_file: the bytes Node's (an upload, a download into this session's workspace)
    return self.rnode("stationFile", [jstr(station), Json::object(request), args, field_of(row, "workspace")])
  }
  if !["prepare", "start", "get", "log", "stop", "release", "list", "mirrors", "clean"].contains(action) {
    raise refusal("unknown task action")
  }
  request["method"] = jstr(if action == "release" { "task.collected" } else { "task.\{action}" })
  if action == "mirrors" || action == "clean" {
    if action == "clean" {
      request["mirror"] = field_of(args, "mirror")
    }
    return self.ask(station, Json::object(request))
  }
  request["lines"] = field_of(args, "lines")
  let spec : Map[String, Json] = { "name": field_of(args, "name"), "command": field_of(args, "command"), "requestedBy": field_of(row, "createdBy") }
  // Said only when so: a task prepared before keeps the same inputs.
  if field_of(args, "screen") is True {
    spec["screen"] = jbool(true)
  }
  if field_of(args, "small") is True {
    spec["small"] = jbool(true)
  }
  let prepared_name = "\{rhash(Json::array([jstr(workspace), jstr(session), jstr(station), jstr(key)]))}.json"
  let prepared = self.rjoin([self.prepared_dir(session), prepared_name])
  if action == "prepare" {
    // Any earlier spec fenced off before validation or a request: a start must not quietly use the task the target
    // kept from an earlier prepare that succeeded.
    self.mkdirs(self.prepared_dir(session))
    let attempt = self.random_hex(16)
    self.write_json(prepared, { "workspace": jstr(workspace), "session": jstr(session), "station": jstr(station), "key": jstr(key), "preparing": jstr(attempt) })
    let dir = field_of(args, "dir")
    let back = field_of(args, "back")
    let small = field_of(args, "small") is True
    if small && field_of(args, "screen") is True {
      raise refusal("a small task cannot use the screen")
    }
    match dir {
      Null => ()
      String(d) if @nodepath.is_absolute(self.sep, d) => ()
      _ => raise refusal("dir must be an absolute path on this machine")
    }
    // An older station would silently use the ordinary queue. Asked once for both small-task support and sync.
    let described = if !(dir is Null) || small { self.ask(station, { "method": jstr("describe"), "workspace": jstr(workspace) }) } else { Json::null() }
    if small && field_of(described, "smallTasks") != jnum(1.0) {
      raise refusal("\{station} cannot run small tasks; update that station first")
    }
    if dir is String(d) {
      // The station reads it itself as it syncs: in a folder macOS protects, only when it may (Node's places).
      ignore(self.rnode("directory", [jstr(d)]))
      if field_of(described, "sync") is Null {
        raise refusal("\{station} is from before directory sync and would run the task without the files; update that station first, or upload inputs with station_file")
      }
      spec["dir"] = self.rnode("resolve", [jstr(d)])
    }
    match back {
      Null => ()
      Array(b) if b.length() <= 100 && b.iter().all(p => p is String(s) && s != "" && !@nodepath.is_absolute(self.sep, s) && !s.split("/").flat_map(x => x.split("\\")).any(x => x == "..")) =>
        spec["back"] = back
      _ => raise refusal("back must be paths relative to the task's directory (at most 100)")
    }
    request["spec"] = Json::object(spec)
    let answer = self.ask(station, Json::object(request))
    // A concurrent prepare may have begun while this one was away. Its result alone can release its fence.
    if text_of(self.read_json(prepared), "preparing") != attempt {
      raise refusal("a newer prepare superseded this one; prepare again before starting")
    }
    self.write_json(prepared, { "workspace": jstr(workspace), "session": jstr(session), "station": jstr(station), "key": jstr(key), "dir": spec.get("dir").unwrap_or(Json::null()), "back": spec.get("back").unwrap_or(Json::null()) })
    return answer
  }
  request["spec"] = Json::object(spec)
  let mut synced = Json::null()
  if action == "start" {
    let local = try {
      self.read_json(prepared)
    } catch {
      // Not moved into its session's directory yet, or moved meanwhile.
      _ => try {
        self.read_json(self.rjoin([self.remote.root, "prepared", prepared_name]))
      } catch {
        _ => self.read_json(prepared) catch { _ => Json::null() }
      }
    }
    if field_of(local, "preparing") is String(_) {
      raise refusal("the last prepare failed or is still in progress; prepare again before starting this key")
    }
    if field_of(local, "dir") is String(dir) {
      let id = rhash(Json::array([jstr(workspace), jstr(session), jstr(station), jstr(dir)]))
      let sync = self.sync_of(id, key, [jstr(station), jstr(workspace), jstr(session), jstr(key), jstr(dir)])
      guard self.bounded(sync.result, sync_answer_ms) is Some(got) else {
        return {
          "key": jstr(key),
          "syncing": jbool(true),
          "dir": jstr(dir),
          "note": jstr("\{dir} is still being synced to \{station}; nothing was started yet. Call start again with the same key: it waits on this sync rather than beginning another"),
        }
      }
      // Taken: the next start of this task syncs anew.
      if self.remote.syncs.get(id) is Some(now) && physical_equal(now, sync) {
        self.remote.syncs.remove(id)
      }
      match got {
        { "error": err, .. } => {
          let message = text_of(err, "message")
          if text_of(err, "kind") == "Refused" && message.contains("unsupported peer method") {
            raise refusal("\{station} cannot sync directories (it is from before); nothing was started. Update that station first")
          }
          raise refusal("\{dir} was not synced to \{station}, so nothing was started: \{message}")
        }
        _ => synced = field_of(got, "ok")
      }
    }
    // A re-prepare may have failed while the directory sync was in flight.
    let latest = self.read_json(prepared) catch { _ => Json::null() }
    if field_of(latest, "preparing") is String(_) {
      raise refusal("the last prepare failed or is still in progress; prepare again before starting this key")
    }
    // Persist before sending: an uncertain start is still followed after a process restart.
    let path = self.outgoing_path(workspace, session, station, key)
    let was = self.read_json(path) catch { _ => Json::null() }
    if was is Null || field_of(was, "refused") is True {
      let e : Map[String, Json] = { "workspace": jstr(workspace), "session": jstr(session), "station": jstr(station), "key": jstr(key), "delivered": jbool(false), "since": jnum(self.remote_now()) }
      if !(local is Null) {
        e["dir"] = field_of(local, "dir")
        e["back"] = field_of(local, "back")
        e["prefix"] = jstr(text_of(synced, "prefix"))
      }
      self.write_json(path, Json::object(e))
    }
    // Its station tells this one when it changes (`task.changed`), naming this record.
    let base = self.rbasename(path)
    request["push"] = jstr(base.view(end_offset=base.length() - 5).to_string())
  }
  try {
    let answer = self.ask(station, Json::object(request))
    // A station from before `task.changed` never tells of it: not followed, its session told so.
    if action == "start" && !(field_of(answer, "push") is True) {
      let path = self.outgoing_path(workspace, session, station, key)
      self.spawn(() => try { self.unfollowed(path) } catch { _ => () })
    }
    if synced is Null { answer } else { with_field(answer, "sync", synced) }
  } catch {
    e => {
      let path = self.outgoing_path(workspace, session, station, key)
      // An uncertain start: asked about once its station would have started it.
      if action == "start" && !refused(e) {
        let entry = self.read_json(path) catch { _ => Json::null() }
        let since = as_i64(field_of(entry, "since")).unwrap_or(self.remote_now())
        self.later(path, since + give_up_ms)
      }
      if action == "start" && refused(e) {
        ignore(self.update_json(path, entry => Some(with_field(with_field(entry, "delivered", jbool(true)), "refused", jbool(true))))) catch { _ => () }
      }
      raise e
    }
  }
}

// ── the chats' use of other stations (remote/used/<hash(session)>.json) ──

///|
/// A source keeps asking an unreachable target to remove a closed session's directory this long.
let close_for_ms : Double = 30.0 * 24.0 * 3600.0 * 1000.0

///|
/// A closing session's stations not answered yet are asked again this long after.
let close_every_ms : Double = 60000.0

///|
/// The record of which stations of its workspace a session of this station ran tasks on (remote.ts `usedPath`).
fn Actors::used_path(self : Actors, session : String) -> String {
  self.rjoin([self.remote.root, "used", "\{rhash(jstr(session))}.json"])
}

///|
/// The record at `path` is `v` now (Null: none): kept, and Node told (what it reads at once: remote.ts `workspaceTargets`).
fn Actors::used_told(self : Actors, path : String, v : Json) -> Unit {
  self.remote.used[path] = v
  self.tell(remote_key, "used", [jstr(path), v])
}

///|
/// Every chat's record read in as the station starts, each told Node (`used`), then that all were (`usedReady`): read on
/// Node's thread as each chat is first shown after every update, the reads held up its other work. One changed here
/// meanwhile is told as it is now.
async fn Actors::load_used(self : Actors) -> Unit {
  let dir = self.rjoin([self.remote.root, "used"])
  let names = self.readdir_names(dir) catch { _ => [] }
  for name in names {
    if !name.has_suffix(".json") {
      continue
    }
    let path = self.rjoin([dir, name])
    if self.remote.used.get(path) is Some(v) {
      self.tell(remote_key, "used", [jstr(path), v])
      continue
    }
    let before = self.remote.writes.get(path).unwrap_or(0)
    let text = self.read_text(path) catch { _ => continue }
    guard text is Some(text) else { continue }
    let v = @json.parse(text) catch { _ => continue }
    if !self.remote.used.contains(path) && self.remote.writes.get(path).unwrap_or(0) == before {
      self.used_told(path, v)
    }
  }
  self.tell(remote_key, "usedReady", [])
}

///|
/// A chat's record (Null: none), read once and kept; raised when it is not JSON.
async fn Actors::used_record(self : Actors, path : String) -> Json raise {
  if self.remote.used.get(path) is Some(v) {
    return v
  }
  let before = self.remote.writes.get(path).unwrap_or(0)
  self.written(path)
  let v = match self.read_text(path) {
    Some(text) => @json.parse(text) catch { _ => raise FsError("\{path}: not JSON") }
    None => Json::null()
  }
  if !self.remote.used.contains(path) && self.remote.writes.get(path).unwrap_or(0) == before {
    self.remote.used[path] = v
  }
  v
}

///|
/// `f` after what was asked before it of the record at `path` (its changes, one after another).
async fn[X] Actors::in_used(self : Actors, path : String, f : async () -> X raise) -> X raise {
  self.in_lane("used:" + path, f)
}

///|
/// The source remembers which stations a session ran tasks on, to ask them to clean up when it closes: a station_task's
/// (`tool`), and Node's (remote.ts `recordUse`). The record as it is now.
async fn Actors::record_use(self : Actors, workspace : String, session : String, station : String) -> Json raise {
  let path = self.used_path(session)
  self.in_used(path, async fn() -> Json raise {
    let had = self.used_record(path) catch { _ => Json::null() }
    let known = match field_of(had, "stations") {
      Array(s) => s.contains(jstr(station))
      _ => false
    }
    if known && !(field_of(had, "closing") is True) {
      return had
    }
    let mut v : Json = if had is Null {
      { "session": jstr(session), "workspace": jstr(workspace), "stations": Json::array([]) }
    } else {
      had
    }
    if !known {
      match field_of(v, "stations") {
        Array(s) => {
          let s = s.copy()
          s.push(jstr(station))
          v = with_field(v, "stations", Json::array(s))
        }
        _ => raise FsError("bad record")
      }
    }
    // Used again after closing (shown again): close later from the start.
    v = with_field(with_field(with_field(v, "closing", jbool(false)), "closed", Json::array([])), "workspace", jstr(workspace))
    self.used_told(path, v)
    self.write_json(path, v) catch {
      e => self.rlog("warn", "a session's use of a station not written", fields={ "session": jstr(session), "error": jstr(FsError::of(e)) })
    }
    v
  })
}

///|
/// A session was archived or deleted (remote.ts `closeSession`): its record written closing since `since`, its tasks
/// started from here no longer followed (`unfollow_session`), and each station it used asked to remove its directories
/// (`closer`) once that is written. The record as it is now (Null: none, nothing to close).
async fn Actors::close_session(self : Actors, session : String, since : Double) -> Json raise {
  let path = self.used_path(session)
  let (v, wrote) = self.in_used(path, async fn() -> (Json, Bool) raise {
    let had = self.used_record(path) catch { _ => return (Json::null(), false) }
    if had is Null {
      return (had, false)
    }
    let v = with_field(with_field(had, "closing", jbool(true)), "since", jnum(since))
    self.used_told(path, v)
    let wrote = try {
      self.write_json(path, v)
      true
    } catch {
      _ => false
    }
    (v, wrote)
  })
  if v is Null {
    return v
  }
  self.spawn(() => try { self.unfollow_session(session) } catch { _ => () })
  if wrote {
    self.closer(path)
  }
  v
}

///|
/// The record at `path` changed by `edit` in its turn (`update_json`), Node told what it is then.
async fn Actors::used_update(self : Actors, path : String, edit : (Json) -> Json?) -> Unit raise {
  self.in_used(path, async fn() raise {
    let got : Ref[Json?] = { val: None }
    let ok = self.update_json(path, v => {
      let next = edit(v)
      got.val = next
      next
    })
    if ok && got.val is Some(next) {
      self.used_told(path, next)
    }
  })
}

///|
/// The sessions closing asked to remove their directories again (the transport is there: `attached`).
async fn Actors::resume_closing(self : Actors) -> Unit raise {
  let dir = self.rjoin([self.remote.root, "used"])
  for name in self.readdir_names(dir) {
    if self.remote.stopped {
      return
    }
    if !name.has_suffix(".json") {
      continue
    }
    let path = self.rjoin([dir, name])
    let v = self.read_json(path) catch { _ => continue }
    if field_of(v, "closing") is True {
      self.closer(path)
    }
  }
}

///|
/// Asks each station a closing session used to remove its directory, now and every minute (on the remote tasks' clock)
/// until all have answered; one round at a time for each record.
fn Actors::closer(self : Actors, path : String) -> Unit {
  if self.remote.stopped || self.remote.closing.contains(path) {
    return
  }
  self.remote.closing[path] = true
  self.closing_round(path)
}

///|
fn Actors::closing_round(self : Actors, path : String) -> Unit {
  self.spawn(() => {
    let over = (try { self.close_round(path) } catch { _ => false }) || self.remote.stopped
    if over {
      self.remote.closing.remove(path)
      return
    }
    ignore(self.rafter(close_every_ms, () => self.closing_round(path)))
  })
}

///|
/// One round of `closer`: whether it is over (the record gone, no longer closing, or every station answered).
async fn Actors::close_round(self : Actors, path : String) -> Bool raise {
  let v = self.read_json(path) catch { _ => return true }
  if !(field_of(v, "closing") is True) {
    return true
  }
  let closed = match field_of(v, "closed") {
    Array(c) => c
    _ => []
  }
  let pending = match field_of(v, "stations") {
    Array(s) => s.filter(x => x is String(_) && !closed.contains(x))
    _ => []
  }
  let now = self.remote_now()
  if pending.length() == 0 || now - as_i64(field_of(v, "since")).unwrap_or(0.0) > close_for_ms {
    self.used_update(path, now => if field_of(now, "closing") is True { Some(Json::null()) } else { None }) catch {
      _ => ()
    }
    return true
  }
  for s in pending {
    let request : Json = { "method": jstr("session.close"), "workspace": field_of(v, "workspace"), "session": field_of(v, "session") }
    // An answer, or a refusal (a station from before session directories, or one that no longer takes tasks from
    // here), is final; no connection is asked again.
    let done = try {
      ignore(self.ask(str_of(Some(s)).unwrap_or(""), request))
      true
    } catch {
      e => refused(e)
    }
    if done {
      self.used_update(path, now => match (field_of(now, "closing"), field_of(now, "closed")) {
        (True, Array(c)) => {
          let c = c.copy()
          c.push(s)
          Some(with_field(now, "closed", Json::array(c)))
        }
        _ => None
      }) catch {
        _ => ()
      }
    }
  }
  false
}
