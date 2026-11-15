// The target's side of the remote tasks (remote.ts `task` and what it stands on): a source session's tasks here, their
// shared directory and its mirrors, and their cleanup.

///|
fn refusal(m : String) -> Error {
  Asked({ "message": jstr(m) })
}

///|
async fn Actors::task(
  self : Actors,
  workspace : String,
  peer : String,
  method : String,
  request : Json,
  load : @effect.Deferred[Json]?,
) -> Json raise {
  if method == "task.gets" {
    // What `task.get` says of each, in one request (a source follows all its tasks here at once).
    let asked = match field_of(request, "tasks") {
      Array(a) if a.length() <= gets_max => a
      _ => raise refusal("tasks are required (at most \{gets_max})")
    }
    let reading : @effect.Deferred[Json] = @effect.Deferred::new()
    let mut read = false
    let tasks : Array[Json] = []
    for one in asked {
      let (session, key) = (field_of(one, "session"), field_of(one, "key"))
      if !read {
        read = true
        self.spawn(() => {
          let l = self.rnode("load", []) catch { e => ({ "unavailable": jstr(FsError::of(e)) } : Json) }
          ignore(reading.succeed(l))
        })
      }
      let got : Json = try {
        { "session": session, "key": key, "result": self.task(workspace, peer, "task.get", { "session": session, "key": key }, Some(reading)) }
      } catch {
        e => ({ "session": session, "key": key, "error": jstr(FsError::of(e)) } : Json)
      }
      tasks.push(got)
    }
    return { "tasks": Json::array(tasks) }
  }
  let session = text_of(request, "session")
  let session_needed = () => if session == "" || bytes_len(session) > 256 { raise refusal("session is required") }
  if method == "session.size" {
    session_needed()
    let room = self.room(workspace, peer, session)
    self.written(rjoin([room, "session.json"]))
    // (and what Node wrote of it: a room used by work() there)
    ignore(self.rnode("written", [jstr(rjoin([room, "session.json"]))]))
    if !self.there(rjoin([room, "session.json"])) {
      return { "present": jbool(false) }
    }
    let path = rjoin([room, "work"])
    let cutoff = match field_of(request, "limit") {
      Null => Json::null()
      Number(n, ..) if n >= 1.0 && n == n.floor() => jnum(n)
      _ => raise refusal("limit must be a positive whole number of bytes")
    }
    return self.rnode("workspaceSize", [jstr(path), cutoff])
  }
  if method == "task.mirrors" || method == "task.clean" {
    session_needed()
    let room = self.room(workspace, peer, session)
    self.written(rjoin([room, "session.json"]))
    // (and what Node wrote of it: a room used by work() there)
    ignore(self.rnode("written", [jstr(rjoin([room, "session.json"]))]))
    let mirrors = if self.there(rjoin([room, "session.json"])) { self.mirrors_of(workspace, peer, session, self.remote_now()) } else { [] }
    // Unlike the automatic sweep's age-based recovery, an explicit cleanup must not interrupt even a slow sync.
    let syncing_now : Map[String, Bool] = {}
    for m in mirrors {
      if self.there(rjoin([room, "sync", m.name])) {
        syncing_now[m.name] = true
      }
    }
    let in_use = (m : MirrorUse) => m.busy || syncing_now.contains(m.name)
    if method == "task.mirrors" {
      return {
        "mirrors": Json::array(
          mirrors.map(m => ({ "name": jstr(m.name), "path": jstr(rjoin([room, "work", m.name])), "busy": jbool(in_use(m)), "lastUsed": jnum(m.used) } : Json)),
        ),
      }
    }
    let name = text_of(request, "mirror")
    if name == "" {
      raise refusal("mirror is required")
    }
    // The name must be one the station itself listed for this peer's session, never a supplied path.
    guard mirrors.search_by(m => m.name == name) is Some(i) else { return { "mirror": jstr(name), "removed": jbool(false) } }
    if in_use(mirrors[i]) {
      raise refusal("mirror is in use by a task or sync")
    }
    if !self.drop_mirror(workspace, peer, session, name, "requested") {
      raise refusal("mirror could not be removed completely")
    }
    return { "mirror": jstr(name), "removed": jbool(true) }
  }
  if method == "task.list" {
    session_needed()
    let tasks : Array[Json] = []
    for t in self.tasks_of(workspace, peer, session) {
      let job = self.rstore("getJob", [jstr(job_of_task(t.dir))])
      tasks.push({ "key": field_of(t.meta, "key"), "spec": field_of(t.meta, "spec"), "job": if job is Null { Json::null() } else { self.rnode("jobJson", [job]) } })
    }
    return { "tasks": Json::array(tasks) }
  }
  if method == "session.close" {
    session_needed()
    ignore(self.close_here(workspace, peer, session, None))
    return { "closed": jbool(true) }
  }
  let key = text_of(request, "key")
  if session == "" || bytes_len(session) > 256 || key == "" || bytes_len(key) > 128 {
    raise refusal("session and task key are required (at most 256 / 128 bytes)")
  }
  let id = rhash(Json::array([jstr(workspace), jstr(peer), jstr(session), jstr(key)]))
  let dir = rjoin([self.remote.root, "incoming", id])
  let record = rjoin([dir, "task.json"])
  let job_id = "remote_\{id}"
  let owner = "remote:\{workspace}:\{peer}:\{session}"
  if method == "task.prepare" {
    let spec = field_of(request, "spec")
    if text_of(spec, "command").trim_space().to_string() == "" {
      raise refusal("command is required")
    }
    match field_of(spec, "small") {
      Null | True | False => ()
      _ => raise refusal("small must be a boolean")
    }
    if field_of(spec, "small") is True && field_of(spec, "screen") is True {
      raise refusal("a small task cannot use the screen")
    }
    let from = field_of(spec, "dir")
    match from {
      Null => ()
      String(f) if f != "" && bytes_len(f) <= 4096 => ()
      _ => raise refusal("dir must be a path")
    }
    let meta = if self.there(record) {
      let meta = self.read_json(record)
      if js_text(field_of(meta, "spec")) != js_text(spec) && !json_equal(field_of(meta, "spec"), spec) {
        raise refusal("task key already used with different inputs; choose a new key for new work")
      }
      meta
    } else {
      let m : Map[String, Json] = { "spec": spec, "workspace": jstr(workspace), "station": jstr(peer), "session": jstr(session), "key": jstr(key), "layout": jstr("session") }
      if from is String(f) {
        m["mirror"] = jstr(self.mirror_name(workspace, peer, session, f))
      }
      self.mkdirs(dir)
      self.write_json(record, Json::object(m))
      Json::object(m)
    }
    ignore(self.seen(workspace, peer, session))
    return match field_of(meta, "mirror") {
      String(mirror) => { "key": jstr(key), "prepared": jbool(true), "dir": jstr(mirror) }
      _ => { "key": jstr(key), "prepared": jbool(true) }
    }
  }
  let meta = self.read_json(record) catch { _ => raise refusal("unknown task") }
  let job = self.rstore("getJob", [jstr(job_id)])
  // Tasks prepared before shared session directories keep their own.
  let work = if text_of(meta, "layout") == "session" {
    if method == "task.start" || method == "file.put" || method == "sync.begin" {
      self.seen(workspace, peer, session)
    } else {
      rjoin([self.room(workspace, peer, session), "work"])
    }
  } else {
    rjoin([dir, "work"])
  }
  // A task with a directory runs in its mirror, a directory of the session's.
  let mirror = match field_of(meta, "mirror") {
    String(m) => Some(m)
    _ => None
  }
  let room = self.room(workspace, peer, session)
  let manifest_path = match mirror { Some(m) => rjoin([room, "mirrors", "\{m}.json"]); None => "" }
  let syncing = match mirror { Some(m) => rjoin([room, "sync", m]); None => "" }
  if method.has_prefix("sync.") && mirror is None {
    raise refusal("this task has no directory to sync")
  }
  let refuse_busy = async fn() raise {
    let tasks = self.tasks_of(workspace, peer, session).filter(t => t.dir != dir && field_of(t.meta, "mirror") == (match mirror { Some(m) => jstr(m); None => Json::null() }))
    for t in tasks {
      if self.task_running(t.dir) {
        raise refusal("task \{text_of(t.meta, "key")} is running in \{mirror.unwrap_or("")} on this station; wait for it or stop it")
      }
    }
    for t in tasks {
      if field_of(t.meta, "safe") is True && !(field_of(t.meta, "collected") is True) && !(self.rstore("getJob", [jstr(job_of_task(t.dir))]) is Null) {
        raise refusal("task \{text_of(t.meta, "key")} is still bringing back its results from \{mirror.unwrap_or("")}; wait for its completion notice")
      }
    }
  }
  let ongoing = async fn() -> Json raise {
    let state = self.read_json(rjoin([syncing, "state.json"])) catch { _ => Json::null() }
    if state is Null || text_of(state, "id") != text_of(request, "id") || text_of(state, "key") != key {
      raise refusal("this sync is over or another one began; start again")
    }
    state
  }
  let m = mirror.unwrap_or("")
  match method {
    "task.start" => {
      match field_of(meta, "uploads") {
        Object(u) if u.values().any(v => !(v is True)) => raise refusal("input upload is incomplete; finish it before starting")
        _ => ()
      }
      let mut cwd = work
      if mirror is Some(_) && job is Null {
        if !(field_of(meta, "synced") is True) {
          raise refusal("this task's directory has not been synced; start it from a station that syncs directories")
        }
        refuse_busy()
      }
      if mirror is Some(_) {
        cwd = self.file_path(work, m, false)
        self.used_mirror(workspace, peer, session, m)
      }
      let spec = field_of(meta, "spec")
      // Through the station's queue (admit): started now if there is room, else when there is. A sandbox's (this
      // station's own): run there, nothing of this machine's taken, so not queued here.
      let in_sandbox = peer.has_prefix("sandbox:")
      if in_sandbox && field_of(spec, "screen") is True {
        raise refusal("a sandbox has no screen: run what needs one on a station")
      }
      if in_sandbox {
        ignore(self.rnode("ensureIdentity", []))
      }
      let back = match field_of(spec, "back") {
        Array(b) => Json::array(b.filter(x => x is String(_)))
        _ => Json::array([])
      }
      let started = if in_sandbox {
        self.locked(() => self.start_id([jstr(owner), field_of(spec, "name"), field_of(spec, "command"), jstr(cwd), Json::null(), jbool(false), jstr(job_id), jbool(false), Json::null(), { "sandbox": jstr(peer.view(start_offset=8).to_string()), "session": jstr(session), "back": back }]))
      } else {
        self.locked(() => self.start_id([jstr(owner), field_of(spec, "name"), field_of(spec, "command"), jstr(cwd), Json::null(), jbool(false), jstr(job_id), jbool(false), { "screen": jbool(field_of(spec, "screen") is True), "small": jbool(field_of(spec, "small") is True) }, Json::null()]))
      }
      // Where its source wants to be told of it (`push_out`): from its first start, as it is then.
      let push = text_of(request, "push")
      let meta = if is_hex64(push) && text_of(meta, "push") != push {
        let meta = with_field(with_field(meta, "push", jstr(push)), "pushed", self.said(id))
        self.write_json(record, meta)
        meta
      } else {
        meta
      }
      let queue = self.queued(text_of(started, "id"), load)
      let now = self.rstore("getJob", [jstr(job_id)])
      let out : Map[String, Json] = { "key": jstr(key), "job": self.rnode("jobJson", [if now is Null { started } else { now }]) }
      for k, v in queue {
        out[k] = v
      }
      if !(field_of(meta, "push") is Null) {
        out["push"] = jbool(true)
      }
      Json::object(out)
    }
    "sync.begin" => {
      if !(job is Null) {
        return { "key": jstr(key), "started": jbool(true) }
      }
      refuse_busy()
      self.remove(syncing, recursive=true)
      self.mkdirs(syncing)
      self.mkdirs(rjoin([room, "mirrors"]))
      self.used_mirror(workspace, peer, session, m)
      // (the manifest, what the mirror has now and the conflict base: dirsync.mbt)
      let version = self.sync_begin(manifest_path, rjoin([work, m]), syncing)
      let sid = self.random_hex(12)
      self.write_json(rjoin([syncing, "state.json"]), { "id": jstr(sid), "key": jstr(key), "version": jnum(version) })
      if field_of(request, "safe") == jnum(1.0) {
        self.write_json(record, with_field(meta, "safe", jbool(true)))
      }
      { "key": jstr(key), "id": jstr(sid), "dir": jstr(m), "version": jnum(version), "safe": jnum(1.0) }
    }
    "sync.manifest" | "sync.base" => {
      ignore(ongoing())
      let after = as_u64(field_of(request, "after")).unwrap_or(0.0)
      let file = if method == "sync.manifest" { "actual.json" } else { "base.json" }
      self.written(rjoin([syncing, file]))
      let files = match self.read_json(rjoin([syncing, file])) {
        Object(f) => f
        _ => {}
      }
      page_of(listed_entries(files), after.to_int())
    }
    "sync.put" => {
      ignore(ongoing())
      // The packed pieces after the request (Node landed them in a file: `landed`); from a station from before, base64
      // in it. Unpacked and written here (dirsync.mbt).
      let landed = str_of(Some(field_of(request, "landed")))
      { "pieces": jnum(self.put_blobs(rjoin([syncing, "blobs"]), field_of(request, "blobs"), landed, field_of(request, "data")).to_double()) }
    }
    "sync.commit" => {
      let state = ongoing()
      let part = plan_part(request)
      ignore(self.fs("fs.put", { "path": jstr(rjoin([syncing, "plan.jsonl"])) }, bytes=@utf8.encode(js_text(part) + "\n")))
      if !(field_of(request, "final") is True) {
        return { "key": jstr(key), "planned": jbool(true) }
      }
      refuse_busy()
      // (the plan checked against what the mirror has and written: dirsync.mbt)
      let done = self.sync_commit(work, m, syncing, manifest_path, field_of(state, "version"), text_of(field_of(meta, "spec"), "dir"))
      self.write_json(record, with_field(meta, "synced", jbool(true)))
      self.remove(syncing, recursive=true)
      self.used_mirror(workspace, peer, session, m)
      let out : Map[String, Json] = { "key": jstr(key) }
      match done {
        Object(d) => for k, v in d { out[k] = v }
        _ => ()
      }
      Json::object(out)
    }
    "sync.changes" => {
      if job is Null || str_of(job.value("state")) == Some("running") {
        raise refusal("the task has not finished")
      }
      let base = self.file_path(work, m, false)
      let found = self.sync_changes(manifest_path, base)
      { "key": jstr(key), "base": jstr(m), "changes": field_of(found, "changes"), "more": field_of(found, "more") }
    }
    "task.collected" => {
      if job is Null || str_of(job.value("state")) == Some("running") {
        raise refusal("the task has not finished")
      }
      self.write_json(record, with_field(meta, "collected", jbool(true)))
      { "key": jstr(key), "collected": jbool(true) }
    }
    "task.files" => {
      if str_of(job.value("state")) == Some("running") {
        raise refusal("wait for the task to finish before downloading artifacts")
      }
      let paths = match field_of(request, "paths") {
        Array(p) if p.length() <= 100 && p.iter().all(x => x is String(_)) => p.map(x => str_of(Some(x)).unwrap_or(""))
        _ => raise refusal("paths are required (at most 100)")
      }
      let cwd = if mirror is None { work } else { self.file_path(work, m, false) }
      let files : Array[Json] = []
      for p in paths {
        self.visit_files(cwd, p, files)
      }
      { "key": jstr(key), "base": jstr(m), "files": Json::array(files) }
    }
    "task.get" | "task.log" => {
      let lines = match as_u64(field_of(request, "lines")) {
        Some(n) => if n < 1.0 { 1.0 } else if n > 1000.0 { 1000.0 } else { n }
        None => 50.0
      }
      let queue = self.queued(job_id, load)
      let current = self.rstore("getJob", [jstr(job_id)])
      let out : Map[String, Json] = {
        "key": jstr(key),
        "job": if current is Null { Json::null() } else { self.rnode("jobJson", [current]) },
        "log": if current is Null { Json::null() } else { self.rnode("tail", [field_of(current, "log"), jnum(lines)]) },
        "notices": self.rstore("jobNotices", [jstr(job_id), jnum(20.0)]),
      }
      for k, v in queue {
        out[k] = v
      }
      if field_of(meta, "push") is String(_) {
        out["push"] = jbool(true)
      }
      Json::object(out)
    }
    "task.stop" => {
      if job is Null {
        raise refusal("task has not started")
      }
      { "key": jstr(key), "job": self.rnode("jobJson", [self.job_stop(text_of(job, "id"))]) }
    }
    "file.put" => {
      if !(job is Null) {
        raise refusal("inputs are immutable after a task starts")
      }
      let name = text_of(request, "path")
      let path = self.file_path(work, name, true)
      let uploads = match field_of(meta, "uploads") {
        Object(u) => u.copy()
        _ => {}
      }
      uploads[name] = jbool(false)
      let meta = with_field(meta, "uploads", Json::object(uploads))
      self.write_json(record, meta)
      // (the bytes Node holds for the request, or a chunk of base64 in it: written there by Node)
      let put = self.rnode("filePut", [jstr(path), request])
      if put.value("whole") is Some(True) {
        uploads[name] = jbool(true)
        self.write_json(record, with_field(meta, "uploads", Json::object(uploads)))
      }
      { "bytes": put.value("bytes").unwrap_or(jnum(0.0)) }
    }
    "file.get" => {
      if str_of(job.value("state")) == Some("running") {
        raise refusal("wait for the task to finish before downloading artifacts")
      }
      let path = self.file_path(work, text_of(request, "path"), false)
      // (read and sent by Node: whole after the answer, or a chunk)
      self.rnode("fileGet", [jstr(path), request])
    }
    _ => raise refusal("unsupported peer method: \{method}")
  }
}

///|
fn is_hex64(s : String) -> Bool {
  s.length() == 64 && s.iter().all(c => (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f'))
}

///|
/// isDeepStrictEqual of two JSON values (keys in any order).
fn json_equal(a : Json, b : Json) -> Bool {
  match (a, b) {
    (Object(x), Object(y)) => x.length() == y.length() && x.iter().all(e => y.get(e.0) is Some(v) && json_equal(e.1, v))
    (Array(x), Array(y)) => x.length() == y.length() && x.mapi((i, v) => json_equal(v, y[i])).iter().all(b => b)
    _ => a == b
  }
}

///|
/// task.files: what of `rel` there is, files by size, a directory's files in name order (1000 at most).
async fn Actors::visit_files(self : Actors, cwd : String, rel : String, files : Array[Json]) -> Unit raise {
  if files.length() >= 1000 {
    raise refusal("more than 1000 files to bring back")
  }
  let st = try {
    self.lstat(self.file_path(cwd, rel, false))
  } catch {
    _ => None
  }
  match st {
    None => files.push(Json::array([jstr(rel), Json::null()]))
    Some(st) =>
      match kind_of_stat(st) {
        "file" => files.push(Json::array([jstr(rel), st.value("size").unwrap_or(jnum(0.0))]))
        "dir" => {
          let names = self.readdir_names(rjoin([cwd, rel]))
          names.sort_by(@search.compare_units) // (as JavaScript sorts them: MoonBit's compare puts the shorter first)
          let base = trim_slashes(rel)
          for name in names {
            self.visit_files(cwd, "\{base}/\{name}", files)
          }
        }
        _ => ()
      }
  }
}

///|
fn trim_slashes(s : String) -> String {
  let mut t = s
  while t.has_suffix("/") {
    t = t.view(end_offset=t.length() - 1).to_string()
  }
  t
}

///|
/// What the task here with this id has come to: its job's state and what it said, hashed (None before it started).
async fn Actors::said(self : Actors, id : String) -> Json raise {
  let job_id = "remote_\{id}"
  let job = self.rstore("getJob", [jstr(job_id)])
  if job is Null {
    return Json::null()
  }
  jstr(rhash(Json::array([field_of(job, "state"), field_of(job, "endedAt"), self.rstore("jobNotices", [jstr(job_id), jnum(20.0)])])))
}

///|
/// What a task waiting in the queue is told of it: its place, what blocks it, and the measured machine's capacity.
async fn Actors::queued(self : Actors, job_id : String, load : @effect.Deferred[Json]?) -> Map[String, Json] raise {
  // (one not waiting is told at once, not behind the jobs' permit: a stop holds it while it signals)
  let job = self.jstore("getJob", [jstr(job_id)])
  if job is Null || str_of(job.value("state")) != Some("running") || !(job.value("queued") is Some(True)) {
    return {}
  }
  if self.locked(() => self.queue_of(job_id)) is Null {
    return {}
  }
  let measured = match load {
    Some(d) => d.wait() catch { _ => Json::null() }
    None => self.rnode("load", []) catch { e => ({ "unavailable": jstr(FsError::of(e)) } : Json) }
  }
  // It may have started while the host was being read; its old queued state is not given.
  let q = self.locked(() => self.queue_of(job_id))
  if q is Null {
    return {}
  }
  let place = num_of(q.value("place")).unwrap_or(1.0)
  let why = match str_of(q.value("why")) {
    Some("memory") => "the machine's memory is under pressure"
    Some("screen") =>
      match str_of(q.value("holder")) {
        Some(h) => "the screen is held by \{h}"
        None => "the screen is held or an earlier request is waiting for it"
      }
    Some("person") => "a person is using this machine's screen (its input not idle): no task is given it meanwhile"
    Some("small") => "another small task is using the station's small-work slot"
    _ => "it is waiting for its turn"
  }
  let at = if place == 1.0 { "next" } else { "number \{place.to_int()}" }
  let out = match q {
    Object(m) => m.copy()
    _ => {}
  }
  out["load"] = measured
  out["note"] = jstr("Waiting in this station's queue (\{at}): \{why}. It starts by itself when there is room; you are told when it ends, as for any task.")
  { "queue": Json::object(out) }
}

///|
priv struct IncomingTask {
  dir : String
  meta : Json
}

///|
priv struct MirrorUse {
  name : String
  used : Double
  busy : Bool
}

///|
/// The owners of the tasks here, kept by session off the records (remote.ts `indexIncoming`): only new or unreadable
/// ones read, the directory's stamp telling whether anything came or went meanwhile.
async fn Actors::index_incoming(self : Actors) -> Unit raise {
  let incoming = rjoin([self.remote.root, "incoming"])
  let stamp = async fn() -> String raise {
    match self.lstat(incoming) {
      Some(st) => "\{st.value("ino").unwrap_or(Json::null()).stringify()}:\{st.value("mtimeMs").unwrap_or(Json::null()).stringify()}:\{st.value("ctimeMs").unwrap_or(Json::null()).stringify()}"
      None => ""
    }
  }
  while true {
    let before = stamp()
    if Some(before) == self.remote.incoming_stamp && self.remote.unreadable.length() == 0 {
      return
    }
    let names = self.readdir_names(incoming)
    let present : Map[String, Bool] = {}
    for n in names {
      present[n] = true
    }
    for name in self.remote.task_owners.keys().collect() {
      if !present.contains(name) {
        self.forget_task(name)
      }
    }
    for name in self.remote.unreadable.keys().collect() {
      if !present.contains(name) {
        self.remote.unreadable.remove(name)
      }
    }
    for name in names {
      if self.remote.task_owners.contains(name) {
        continue
      }
      let meta = self.read_json(rjoin([incoming, name, "task.json"])) catch { _ => Json::null() }
      if meta is Null {
        // A directory can exist before its record is written, even across a station handover: tried again.
        self.remote.unreadable[name] = true
        continue
      }
      let owner = js_text(Json::array([jstr(text_of(meta, "workspace")), jstr(text_of(meta, "station")), jstr(text_of(meta, "session"))]))
      self.remote.task_owners[name] = owner
      let owned = self.remote.owner_tasks.get(owner).unwrap_or({})
      owned[name] = true
      self.remote.owner_tasks[owner] = owned
      self.remote.unreadable.remove(name)
    }
    let after = stamp()
    if before == after {
      self.remote.incoming_stamp = Some(after)
      return
    }
    self.remote.incoming_stamp = None
  }
}

///|
fn Actors::forget_task(self : Actors, name : String) -> Unit {
  if self.remote.task_owners.get(name) is Some(owner) {
    if self.remote.owner_tasks.get(owner) is Some(names) {
      names.remove(name)
      if names.length() == 0 {
        self.remote.owner_tasks.remove(owner)
      }
    }
    self.remote.task_owners.remove(name)
  }
  self.remote.unreadable.remove(name)
}

///|
/// The task records (incoming/<id>) of a source session, read afresh (the index only says which).
async fn Actors::tasks_of(self : Actors, workspace : String, peer : String, session : String) -> Array[IncomingTask] raise {
  match self.remote.indexing {
    Some(d) => d.wait() catch { _ => () }
    None => {
      let d : @effect.Deferred[Unit] = @effect.Deferred::new()
      self.remote.indexing = Some(d)
      defer {
        self.remote.indexing = None
        ignore(d.succeed(()))
      }
      self.index_incoming()
    }
  }
  let owner = js_text(Json::array([jstr(workspace), jstr(peer), jstr(session)]))
  let names = match self.remote.owner_tasks.get(owner) {
    Some(n) => n.keys().collect()
    None => []
  }
  let found : Array[IncomingTask] = []
  for name in names {
    let dir = rjoin([self.remote.root, "incoming", name])
    let meta = self.read_json(rjoin([dir, "task.json"])) catch { _ => continue }
    if text_of(meta, "workspace") == workspace && text_of(meta, "station") == peer && text_of(meta, "session") == session {
      found.push({ dir, meta })
    }
  }
  found
}

///|
/// The directory in a session's that mirrors the source's `dir` (its last name; with a part of its hash when another
/// directory of the source's has that name there already).
async fn Actors::mirror_name(self : Actors, workspace : String, peer : String, session : String, dir : String) -> String raise {
  let parts = dir.split("/").flat_map(p => p.split("\\")).map(p => p.to_string()).filter(p => p != "").collect()
  let last = if parts.length() > 0 { parts[parts.length() - 1] } else { "" }
  let cleaned = StringBuilder::new()
  let mut n = 0
  for c in last {
    if n >= 100 {
      break
    }
    let ok = c.is_ascii_alphabetic() || c.is_ascii_digit() || c == '.' || c == '_' || c == ' ' || c == '-' || c.to_int() > 127
    cleaned.write_char(if ok { c } else { '_' })
    n += if c.to_int() > 0xFFFF { 2 } else { 1 }
  }
  let mut name = cleaned.to_string()
  if name == "" || name == "." || name == ".." {
    name = "dir"
  }
  let claimed : Map[String, String] = {}
  for t in self.tasks_of(workspace, peer, session) {
    if field_of(t.meta, "mirror") is String(m) {
      claimed[m] = text_of(field_of(t.meta, "spec"), "dir")
    }
  }
  let mirrors = rjoin([self.room(workspace, peer, session), "mirrors"])
  for file in self.readdir_names(mirrors) {
    match self.read_manifest(rjoin([mirrors, file])) {
      None => ()
      Some(m) => claimed[text_of(m, "name")] = text_of(m, "dir")
    }
  }
  match claimed.get(name) {
    None => name
    Some(owner) if owner == dir => name
    _ => "\{name}-\{rhash(jstr(dir)).view(end_offset=8)}"
  }
}

///|
/// A task ran in or synced `mirror` now. Callers are in the session's lane.
async fn Actors::used_mirror(self : Actors, workspace : String, peer : String, session : String, mirror : String) -> Unit raise {
  let record = rjoin([self.room(workspace, peer, session), "mirrors-used.json"])
  let now = self.remote_now()
  ignore(self.update_json(record, used => Some(with_field(used, mirror, jnum(now))), missing={}))
}

///|
/// A session's mirrors here: when a task last ran in or synced each, and whether one runs there or syncs to it now
/// (those marked used now).
async fn Actors::mirrors_of(self : Actors, workspace : String, peer : String, session : String, now : Double) -> Array[MirrorUse] raise {
  let room = self.room(workspace, peer, session)
  let record = rjoin([room, "mirrors-used.json"])
  let running : Map[String, Bool] = {}
  let ended : Map[String, Double] = {}
  for t in self.tasks_of(workspace, peer, session) {
    guard field_of(t.meta, "mirror") is String(mirror) else { continue }
    let job = self.rstore("getJob", [jstr(job_of_task(t.dir))])
    if str_of(job.value("state")) == Some("running") ||
      (!(job is Null) && field_of(t.meta, "safe") is True && !(field_of(t.meta, "collected") is True)) {
      running[mirror] = true
    }
    if num_of(job.value("endedAt")) is Some(at) && at != 0.0 {
      ended[mirror] = if ended.get(mirror).unwrap_or(0.0) > at { ended.get(mirror).unwrap_or(0.0) } else { at }
    }
  }
  let mirrors = self.readdir_names(rjoin([room, "mirrors"])).filter(f => f.has_suffix(".json")).map(f => f.view(end_offset=f.length() - 5).to_string())
  let busy : Map[String, Bool] = {}
  for name in mirrors {
    if running.contains(name) || self.syncing_recently(rjoin([room, "sync", name]), now) {
      busy[name] = true
    }
  }
  let used = self.read_json(record) catch { _ => Json::object({}) }
  let marked = mirrors.filter(name => as_i64(field_of(used, name)) is None || busy.contains(name))
  let used = if marked.length() > 0 {
    ignore(self.update_json(record, kept => {
      let m = match kept { Object(m) => m.copy(); _ => {} }
      for name in marked {
        m[name] = jnum(now)
      }
      Some(Json::object(m))
    }, missing={})) catch { _ => () }
    let m = match used { Object(m) => m.copy(); _ => {} }
    for name in marked {
      m[name] = jnum(now)
    }
    Json::object(m)
  } else {
    used
  }
  mirrors.map(name => {
    let u = as_i64(field_of(used, name)).unwrap_or(now)
    let e = ended.get(name).unwrap_or(0.0)
    { name, used: if u > e { u } else { e }, busy: busy.contains(name) }
  })
}

///|
/// A sync to a mirror is under way: its directory there, it or what is in it touched within MIRROR_RECENT_MS.
async fn Actors::syncing_recently(self : Actors, dir : String, now : Double) -> Bool raise {
  let mut latest = 0.0
  let paths = [dir]
  for name in self.readdir_names(dir) {
    paths.push(rjoin([dir, name]))
  }
  for p in paths {
    match self.fs("fs.lstat", { "path": jstr(p) }) {
      Null => ()
      st => {
        let at = num_of(st.value("mtimeMs")).unwrap_or(0.0)
        if at > latest {
          latest = at
        }
      }
    }
  }
  now - latest < mirror_recent_ms
}

///|
/// Removes a mirror and what its tasks made in it; its tasks that have not started sync again first. Callers are in
/// the session's lane.
async fn Actors::drop_mirror(self : Actors, workspace : String, peer : String, session : String, mirror : String, why : String) -> Bool {
  let room = self.room(workspace, peer, session)
  let done = try {
    for t in self.tasks_of(workspace, peer, session) {
      let path = rjoin([t.dir, "task.json"])
      let meta = self.read_json(path)
      if field_of(meta, "mirror") == jstr(mirror) && field_of(meta, "synced") is True {
        self.write_json(path, with_field(meta, "synced", jbool(false)))
      }
    }
    ignore(self.rnode("removeMirror", [jstr(rjoin([room, "work", mirror]))]))
    self.remove(rjoin([room, "sync", mirror]), recursive=true)
    self.remove(rjoin([room, "mirrors", "\{mirror}.json"]))
    ignore(self.update_json(rjoin([room, "mirrors-used.json"]), used => match used {
      Object(m) => {
        let m = m.copy()
        m.remove(mirror)
        Some(Json::object(m))
      }
      _ => None
    })) catch { _ => () }
    self.rlog("info", "remote mirror removed", fields={ "workspace": jstr(workspace), "station": jstr(peer), "session": jstr(session), "mirror": jstr(mirror), "why": jstr(why) })
    true
  } catch {
    e => {
      self.rlog("warn", "remote mirror not removed", fields={ "mirror": jstr(mirror), "error": jstr(FsError::of(e)) })
      false
    }
  }
  done
}

///|
/// Stops a source session's tasks and removes their records and its shared directory (`idle_at`: the target's own
/// cleanup, only what is idle). Callers are in its lane.
async fn Actors::close_here(self : Actors, workspace : String, peer : String, session : String, idle_at : Double?) -> Bool raise {
  let tasks = self.tasks_of(workspace, peer, session)
  let room = self.room(workspace, peer, session)
  // (work() can be called outside the lane: what goes is taken out of its place in one step where work() runs, Node,
  // its use asked again just before; then removed here)
  let moved = match idle_at {
    Some(at) => {
      let recorded = self.read_json(rjoin([room, "session.json"])) catch { _ => return false }
      let seen_here = num_of(Some(self.rnode("seenAt", [jstr(room)]))).unwrap_or(0.0)
      let rec = as_i64(field_of(recorded, "seen")).unwrap_or(at)
      let seen = if rec > seen_here { rec } else { seen_here }
      if at - seen < idle_ms || seen_here > seen {
        return false
      }
      for t in tasks {
        if self.task_running(t.dir) {
          return false
        }
      }
      self.rnode("closeRoom", [jstr(room), Json::array(tasks.map(t => jstr(t.dir))), jnum(seen)])
    }
    None => {
      for t in tasks {
        if self.task_running(t.dir) {
          ignore(self.job_stop(job_of_task(t.dir)))
        }
        ignore(self.rnode("removeTask", [jstr(t.dir)]))
      }
      self.rnode("closeRoom", [jstr(room), Json::array([]), Json::null()])
    }
  }
  // {aside: the tasks' directories moved, room: where the room went (null: it was not there)}; null: used meanwhile
  if moved is Null {
    return false
  }
  match field_of(moved, "aside") {
    Array(a) =>
      for d in a {
        if d is String(p) {
          ignore(self.rnode("removeTask", [jstr(p)])) catch { _ => () }
        }
      }
    _ => ()
  }
  if field_of(moved, "room") is String(gone) {
    self.rlog("info", "remote session directory removed", fields={ "workspace": jstr(workspace), "station": jstr(peer), "session": jstr(session) })
    self.remove(gone, recursive=true) catch { _ => () }
  }
  true
}

///|
/// The target's own cleanup: a source session's directory unused for IDLE_MS, with nothing running, goes; so do task
/// directories from before shared session directories; mirrors unused for MIRROR_IDLE_MS.
async fn Actors::sweep(self : Actors, now : Double) -> Unit raise {
  let sessions = rjoin([self.remote.root, "sessions"])
  for name in self.readdir_names(sessions) {
    if self.remote.stopped {
      return
    }
    let meta = self.read_json(rjoin([sessions, name, "session.json"])) catch { _ => continue }
    let (workspace, peer, session) = (text_of(meta, "workspace"), text_of(meta, "station"), text_of(meta, "session"))
    self.in_lane(self.room(workspace, peer, session), async fn() raise {
      let again = self.read_json(rjoin([sessions, name, "session.json"])) catch { _ => return }
      let seen_here = num_of(Some(self.rnode("seenAt", [jstr(rjoin([sessions, name]))]))).unwrap_or(0.0)
      let rec = as_i64(field_of(again, "seen")).unwrap_or(now)
      let seen = if rec > seen_here { rec } else { seen_here }
      if now - seen >= idle_ms {
        let closed = try {
          self.close_here(workspace, peer, session, Some(now))
        } catch {
          e => {
            self.rlog("warn", "idle remote session directory not removed", fields={ "error": jstr(FsError::of(e)) })
            return
          }
        }
        if closed {
          return
        }
      }
      for m in self.mirrors_of(workspace, peer, session, now) {
        if !m.busy && now - m.used >= mirror_idle_ms {
          ignore(self.drop_mirror(workspace, peer, session, m.name, "unused"))
        }
      }
    })
  }
  let incoming = rjoin([self.remote.root, "incoming"])
  for name in self.readdir_names(incoming) {
    if self.remote.stopped {
      return
    }
    let dir = rjoin([incoming, name])
    let record = rjoin([dir, "task.json"])
    let meta = self.read_json(record) catch { _ => continue }
    if text_of(meta, "layout") == "session" {
      continue
    }
    let (workspace, peer, session) = (text_of(meta, "workspace"), text_of(meta, "station"), text_of(meta, "session"))
    self.in_lane(self.room(workspace, peer, session), async fn() raise {
      let meta = self.read_json(record) catch { _ => return }
      let modified = match self.lstat(record) {
        Some(st) => num_of(st.value("mtimeMs")).unwrap_or(now).floor()
        None => return
      }
      if text_of(meta, "layout") == "session" || now - modified < idle_ms || self.task_running(dir) {
        return
      }
      self.remove(dir, recursive=true)
    })
  }
}

///|
/// The disk of the station's data low (ops/disk.ts): mirrors go, the longest unused first, until there is enough again.
/// One a task runs in or syncs to, or used within MIRROR_RECENT_MS, stays.
async fn Actors::relieve(self : Actors, now : Double) -> Unit raise {
  let low = async fn() -> Bool raise { truthy(self.rnode("diskLow", [jstr(self.remote.root)])) }
  if !low() {
    return
  }
  let sessions = rjoin([self.remote.root, "sessions"])
  let candidates : Array[(String, String, String, String, Double)] = []
  for name in self.readdir_names(sessions) {
    let meta = self.read_json(rjoin([sessions, name, "session.json"])) catch { _ => continue }
    let (workspace, peer, session) = (text_of(meta, "workspace"), text_of(meta, "station"), text_of(meta, "session"))
    self.in_lane(self.room(workspace, peer, session), async fn() raise {
      for m in self.mirrors_of(workspace, peer, session, now) {
        if !m.busy && now - m.used >= mirror_recent_ms {
          candidates.push((workspace, peer, session, m.name, m.used))
        }
      }
    })
  }
  candidates.sort_by((a, b) => a.4.compare(b.4))
  for c in candidates {
    if !low() {
      return
    }
    let (workspace, peer, session, name, _) = c
    self.in_lane(self.room(workspace, peer, session), async fn() raise {
      let ms = self.mirrors_of(workspace, peer, session, now)
      if ms.search_by(x => x.name == name) is Some(i) && !ms[i].busy && now - ms[i].used >= mirror_recent_ms {
        ignore(self.drop_mirror(workspace, peer, session, name, "disk low"))
      }
    })
  }
}

///|
/// Peers removed from a workspace (or the workspace left) have their tasks stopped, without touching any local jobs.
/// `rosters`: each workspace the station is in now, with its other stations.
async fn Actors::revoke(self : Actors, rosters : Json, current : Bool) -> Unit raise {
  if !current {
    return
  }
  let list = match rosters { Array(a) => a; _ => [] }
  let incoming = rjoin([self.remote.root, "incoming"])
  for name in self.readdir_names(incoming) {
    let meta = self.read_json(rjoin([incoming, name, "task.json"])) catch { _ => continue }
    let peer = text_of(meta, "station")
    if list.iter().any(r => text_of(r, "workspace") == text_of(meta, "workspace") && (match field_of(r, "peers") { Array(p) => p.contains(jstr(peer)); _ => false })) {
      continue
    }
    // A sandbox's task is this station's own, not a peer's.
    if peer.has_prefix("sandbox:") {
      continue
    }
    let id = "remote_\{name}"
    if str_of(self.rstore("getJob", [jstr(id)]).value("state")) == Some("running") {
      ignore(self.job_stop(id)) catch { _ => () }
    }
  }
}
