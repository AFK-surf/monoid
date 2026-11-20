// Cold storage of archived sessions' files (station/src/sessions/cold.ts, the Rust station's hub.rs: archive_room,
// clean_rebuildable, pack_archive, archive_history_files, restore_archive, archive_has_jobs, archive_is_cold): once an
// archived session is idle, what a build makes again is removed from its own directory, and the rest of its workspace
// and the transcripts its runtime keeps in station storage are packed (archive.mbt); they are restored before its
// runtime starts again, or when it is shown again. Where a session's transcripts are is the live view's to say
// (`live.locate`, or `fn.historyFound` where no locator is), a link followed outside the folders macOS protects
// (`fn.realOutside`, ops/places.ts).

///|
let followed_ms : Double = 15.0 * 60000.0

///|
/// Said in the station's data once every transcript put away is in segments.
let segmented_mark = "transcripts-segmented"

///|
/// The Rust station's copy of an archived session's transcript.
let legacy_suffix = ".jsonl.zst"

///|
/// platform.paths.within (Unix's).
fn Files::within(self : Files, path : String, dir : String) -> Bool {
  dir == self.sep || path == dir || path.has_prefix(dir + self.sep)
}

///|
/// ops/paths.ts `fileName`.
fn Files::file_name(self : Files, path : String) -> String? {
  let parts = []
  for p in path.split(self.sep) {
    if p != "" && p != "." {
      parts.push(p.to_string())
    }
  }
  match parts.last() {
    None | Some("..") => None
    Some(l) => Some(l)
  }
}

///|
/// footprint.ts `roomOfSoon`: the room of a session's workspace under the station's sessions directory.
pub async fn Storage::room_of(self : Storage, workspace : String) -> String? {
  // (no workspace: nothing to follow, `realpath("")` would be the process's own directory)
  if workspace == "" {
    return None
  }
  let fs = self.fs
  guard kept_real(self.sessions_real, () => fs.realpath(fs.join([self.data_dir(), "sessions"]))) is Some(sessions) else {
    return None
  }
  let path = match fs.realpath(workspace) {
    Some(p) => Some(p)
    None =>
      if fs.file_name(workspace) == Some("workspace") {
        match fs.realpath(fs.dirname(workspace)) {
          Some(parent) => Some(fs.join([parent, "workspace"]))
          None => None
        }
      } else {
        None
      }
  }
  guard path is Some(path) else { return None }
  if !fs.within(path, sessions) || path == sessions {
    return None
  }
  let relative = cut(path, sessions.length()).split(fs.sep).filter(p => p != "").to_array()
  if relative.length() != 3 || fs.file_name(path) != Some("workspace") {
    return None
  }
  Some(fs.dirname(path))
}

///|
/// What `find` answers, kept in `cell` once it is found (None, a directory not made yet, is asked again).
async fn kept_real(cell : Ref[String?], find : async () -> String?) -> String? {
  if cell.val is Some(real) {
    return Some(real)
  }
  let real = find()
  if real is Some(_) {
    cell.val = real
  }
  real
}

///|
/// How many rooms found and links followed are kept: above two paths for every session of a large station (thousands,
/// archived ones too), so that an upkeep round does not let go of what it asks again in the same round.
let cache_cap : Int = 8192

///|
/// Kept at most `cache_cap`, the least recently found let go first.
fn[V] keep_bounded(kept : Map[String, V], key : String, value : V, also? : Map[String, Double]) -> Unit {
  kept.remove(key)
  kept[key] = value
  if kept.length() > cache_cap {
    match kept.keys().head() {
      Some(k) => {
        kept.remove(k)
        if also is Some(a) {
          a.remove(k)
        }
      }
      None => ()
    }
  }
}

///|
/// Whether `path` is to be followed (again) at `now`: neither followed nor failed to be within `followed_ms`.
fn follow_due(followed : Map[String, (Double, String?)], failed : Map[String, Double], path : String, now : Double) -> Bool {
  match followed.get(path) {
    Some((at, _)) if now - at < followed_ms => return false
    _ => ()
  }
  match failed.get(path) {
    Some(at) => now - at >= followed_ms
    None => true
  }
}

///|
/// `path` followed by `follow` (`fn.realOutside`), kept in `followed` for 15 minutes (cold.ts `canonical`); a
/// failure (a link changed as it was followed) answers None, is not kept as followed (so the path is still taken to
/// be in use) and is not followed again within those 15 minutes either: each session of an upkeep round asks again
/// for every path in use, and a path that does not follow would otherwise be followed again for each.
async fn follow_kept(
  followed : Map[String, (Double, String?)],
  failed : Map[String, Double],
  path : String,
  now : () -> Double,
  follow : async (String) -> String?,
) -> String? {
  if !follow_due(followed, failed, path, now()) {
    return match followed.get(path) {
      Some((_, real)) if failed.get(path) is None => real
      _ => None
    }
  }
  let real = follow(path) catch {
    _ => {
      keep_bounded(failed, path, now())
      return None
    }
  }
  failed.remove(path)
  keep_bounded(followed, path, (now(), real))
  real
}

///|
/// Links followed off the station's thread, kept for 15 minutes (cold.ts `canonical`).
async fn Storage::canonical_followed(self : Storage, path : String) -> String? {
  follow_kept(self.followed, self.follow_failed, path, () => self.now(), async fn(p) {
    as_str(Some(self.ask("fn.realOutside", [js(p)])))
  })
}

///|
/// `follow` started by `fork` unless `path` is being followed already (`following`): an upkeep round asks each path
/// of every session's, and one being followed is not followed again alongside. None where it is.
fn follow_once(
  following : Set[String],
  path : String,
  fork : (async () -> Unit) -> @effect.Fiber[Unit],
  follow : async () -> Unit,
) -> @effect.Fiber[Unit]? {
  if following.contains(path) {
    return None
  }
  following.add(path)
  Some(
    fork(async fn() {
      defer following.remove(path)
      follow()
    }),
  )
}

///|
/// `path` as last followed, whatever its age; None (`undefined`) when it never was, and it is followed in the background.
async fn Storage::followed_now(self : Storage, path : String) -> String?? {
  let kept = self.followed.get(path)
  if follow_due(self.followed, self.follow_failed, path, self.now()) {
    let started = follow_once(self.following, path, f => self.fs.host.rt.fork(name="follow", f), async fn() {
      ignore(self.canonical_followed(path))
    })
    if started is Some(f) {
      self.track_going(f)
    }
  }
  match kept {
    Some((_, real)) => Some(real)
    None => None
  }
}

///|
/// Whether `path`, followed, is in `dir`; one not followed yet is taken to be.
async fn Storage::in_room(self : Storage, path : String, dir : String) -> Bool {
  match self.followed_now(path) {
    None => true
    Some(Some(real)) => self.fs.within(real, dir)
    Some(None) => false
  }
}

///|
/// A workspace's room as `find` finds it, kept in `rooms`: one found is not found again within `followed_ms` (an upkeep
/// round asks it of each session, and each step of packing one again); none found is asked again each time, so a
/// workspace made since is found.
async fn find_kept(
  rooms : Map[String, String?],
  found_at : Map[String, Double],
  workspace : String,
  now : () -> Double,
  find : async (String) -> String?,
) -> Unit {
  if rooms.get(workspace) is Some(Some(_)) && found_at.get(workspace) is Some(at) && now() - at < followed_ms {
    return
  }
  let room = find(workspace)
  found_at[workspace] = now()
  keep_bounded(rooms, workspace, room, also=found_at)
}

///|
async fn Storage::find_room_of(self : Storage, workspace : String) -> Unit {
  find_kept(self.rooms, self.rooms_at, workspace, () => self.now(), async fn(w) { self.room_of(w) })
}

///|
/// Its session's own directory found off the thread, and the directories of what is in use followed.
async fn Storage::find_room(self : Storage, key : String) -> Unit {
  match self.session(key) {
    Some(row) => self.find_room_of(str(row, "workspace").unwrap_or(""))
    None => ()
  }
  self.follow_in_use()
}

///|
/// Every directory in use (the sessions' workspaces and cwds, the jobs' cwds) followed, each once, those followed
/// within `followed_ms` not asked again: an upkeep round asks this of each of its sessions, and once all are followed
/// it costs one read of the paths and nothing more.
async fn Storage::follow_in_use(self : Storage) -> Unit {
  let now = self.now()
  let due : Set[String] = Set([])
  let take = fn(p : String) {
    if !due.contains(p) && follow_due(self.followed, self.follow_failed, p, now) {
      due.add(p)
    }
  }
  for place in self.st.store.in_use_places() {
    let (_, ws, cwd) = place
    take(ws)
    take(cwd)
  }
  let jobs = try {
    self.st.store.jobs_up_places()
  } catch {
    _ => []
  }
  for j in jobs {
    take(j.1)
  }
  for p in due {
    ignore(self.canonical_followed(p))
  }
}

///|
/// A session's own directory, while nothing needs it: archived when `require_archived` is true (else unarchived),
/// not running, and no other in-use session or active job using its directory.
async fn Storage::cleanable_room(self : Storage, key : String, require_archived~ : Bool) -> String? {
  guard self.session(key) is Some(row) else { return None }
  guard self.rooms.get(str(row, "workspace").unwrap_or("")) is Some(Some(dir)) else { return None }
  let archived_ok = if require_archived { !nullish(get(row, "archivedAt")) } else { nullish(get(row, "archivedAt")) }
  if !archived_ok || get(row, "running") is Some(True) || self.st.hub.process_state(key) == "running" {
    return None
  }
  for place in self.st.store.in_use_places() {
    let (k, ws, cwd) = place
    if k == key {
      continue
    }
    if self.in_room(ws, dir) || (cwd != ws && self.in_room(cwd, dir)) {
      return None
    }
  }
  if self.has_jobs(key, dir) {
    return None
  }
  Some(dir)
}

///|
/// An archived session's own directory, while nothing needs it (cold.ts `archiveRoom`).
pub async fn Storage::archive_room(self : Storage, key : String) -> String? {
  self.cleanable_room(key, require_archived=true)
}

///|
/// Whether an archived session still lacks its `cold` mark and is eligible to be packed now.
pub async fn Storage::needs_pack(self : Storage, key : String) -> Bool {
  self.find_room(key)
  match self.archive_room(key) {
    Some(dir) => !self.fs.there(self.fs.join([dir, "cold"]))
    None => false
  }
}

///|
async fn Storage::has_jobs(self : Storage, key : String, dir : String) -> Bool {
  let jobs = try {
    self.st.store.jobs_up_places()
  } catch {
    _ => return true
  }
  for job in jobs {
    let (k, cwd) = job
    if k == key || self.in_room(cwd, dir) {
      return true
    }
  }
  false
}

///|
/// footprint.ts `decide`: how a directory is one a build or an install makes again ("named", "found"), or None.
async fn Files::rebuildable(self : Files, dir : String) -> String? {
  guard self.file_name(dir) is Some(name) else { return None }
  let parent = self.dirname(dir)
  let beside = async fn(files : Array[String]) {
    for f in files {
      if self.there(self.join([parent, f])) {
        return true
      }
    }
    false
  }
  match name {
    "node_modules" | ".next" | ".turbo" | "__pycache__" => return Some("named")
    "target" => if beside(["Cargo.toml"]) { return Some("named") }
    ".gradle" => if beside(["settings.gradle", "settings.gradle.kts", "build.gradle", "build.gradle.kts"]) { return Some("named") }
    "build" => if beside(["build.gradle", "build.gradle.kts"]) { return Some("named") }
    "_build" => if beside(["mix.exs"]) || self.moon_above(parent) { return Some("found") }
    "deps" => if beside(["mix.exs"]) { return Some("found") }
    ".mooncakes" => if beside(["moon.mod.json", "moon.work"]) { return Some("found") }
    _ => ()
  }
  if self.is_dir(self.join([dir, "Build", "Products"])) && self.is_dir(self.join([dir, "Build", "Intermediates.noindex"])) {
    return Some("found")
  }
  let tag = try self.read_range(self.join([dir, "CACHEDIR.TAG"]), 0.0, 512.0) catch {
    _ => None
  } noraise {
    b => Some(@utf8.decode_lossy(b))
  }
  match tag {
    Some(t) => {
      let lines : Array[String] = t.split("\n").map(l => { let s = l.to_string(); if s.has_suffix("\r") { cut(s, 0, end=s.length() - 1) } else { s } }).to_array()
      if lines.contains("Signature: 8a477f597d28d172789f06886806bc55") && lines.contains("# This file is a cache directory tag created by cargo.") {
        if self.there(self.join([dir, ".rustc_info.json"])) {
          return Some("found")
        }
        for profile in ["debug", "release"] {
          for own in ["deps", ".fingerprint"] {
            if self.is_dir(self.join([dir, profile, own])) {
              return Some("found")
            }
          }
        }
      }
    }
    None => ()
  }
  None
}

///|
async fn Files::moon_above(self : Files, from : String) -> Bool {
  let mut found = false
  let mut p = from
  for _ in 0..<8 {
    for m in ["moon.mod.json", "moon.work", "moon.pkg.json"] {
      if !self.there(self.join([p, m])) {
        continue
      }
      if p == from {
        return true
      }
      found = true
    }
    if self.there(self.join([p, ".git"])) {
      return found
    }
    let up = self.dirname(p)
    if up == p {
      break
    }
    p = up
  }
  false
}

///|
/// footprint.ts `safeToRemove`: a generated-looking directory, not tracked by git, and (found by what is in it) ignored.
async fn Files::safe_to_remove(self : Files, path : String) -> Bool {
  let kind = if self.lkind(path) is Some("dir") { self.rebuildable(path) } else { None }
  guard kind is Some(kind) else { return false }
  let parent = self.dirname(path)
  let mut in_repo = false
  let mut p = parent
  while true {
    if self.there(self.join([p, ".git"])) {
      in_repo = true
      break
    }
    if self.dirname(p) == p {
      break
    }
    p = self.dirname(p)
  }
  if !in_repo {
    return true
  }
  let git = async fn(args : Array[String]) -> (Bool, Int) {
    let all = ["-C", parent, ..args]
    match self.sh("proc.run", jo([("command", js("git")), ("args", ja(all.map(a => js(a)))), ("code", jb(true)), ("timeoutMs", ji(600000))])) {
      Object(_) as v => (num(v, "code") == Some(0.0), str(v, "out").unwrap_or("").length())
      _ => (false, 0)
    }
  }
  let (ok, out) = git(["ls-files", "--", self.basename(path)])
  if !ok || out > 0 {
    return false
  }
  kind == "named" || git(["check-ignore", "-q", "--", "\{self.basename(path)}/"]).0
}

///|
/// footprint.ts `measureRoom`: what can be made again in a chat's directory, each with its size.
async fn Files::rebuild_of(self : Files, dir : String) -> Array[(String, Double)] {
  let ask = jo([
    ("path", js(dir)),
    ("base", js(self.join([dir]))),
    ("finding", jb(true)),
    ("strict", jb(false)),
    ("maxEntries", ji(500000)),
    ("maxDurationMs", ji(60000)),
  ])
  let said = match self.footprint_by {
    Some(measure) => measure(ask.stringify())
    None => @footprint.answer(ask.stringify(), self.sep)
  }
  if str(said, "error") is Some(e) {
    raise Thrown("Error", jo([("message", js(e)), ("code", get(said, "code").unwrap_or(Json::null()))]))
  }
  items(get(said, "rebuild")).filter_map(p => match p {
    Array([String(path), Number(b, ..)]) => Some((path, b))
    _ => None
  })
}

///|
async fn Storage::still_cleanable(self : Storage, key : String, require_archived~ : Bool) -> Bool {
  match self.session(key) {
    Some(row) => {
      let archived_ok = if require_archived { !nullish(get(row, "archivedAt")) } else { nullish(get(row, "archivedAt")) }
      archived_ok && !(get(row, "running") is Some(True)) && self.st.hub.process_state(key) != "running"
    }
    None => false
  }
}

///|
async fn Storage::clean_rebuildable_in(self : Storage, key : String, require_archived~ : Bool) -> Double? {
  self.find_room(key)
  guard self.cleanable_room(key, require_archived~) is Some(dir) else { return None }
  let mut freed = 0.0
  for pair in self.fs.rebuild_of(dir) {
    let (path, bytes) = pair
    if !self.still_cleanable(key, require_archived~) || self.has_jobs(key, dir) {
      break
    }
    if !self.fs.safe_to_remove(path) {
      continue
    }
    try self.fs.remove_tree(path) catch {
      e => self.log("warn", "hub", "not removed", jo([("path", js(path)), ("error", js(message_of(e)))]))
    } noraise {
      _ => freed += bytes
    }
  }
  if freed > 0.0 {
    let msg = if require_archived {
      "rebuildable files of an archived session cleaned"
    } else {
      "rebuildable files of an idle session cleaned"
    }
    self.log("info", "hub", msg, jo([("session", js(key)), ("freed", jn(freed))]))
  }
  Some(freed)
}

///|
/// Removes what a build or an install makes again from an archived session's own directory: the bytes removed.
pub async fn Storage::clean_rebuildable(self : Storage, key : String) -> Double {
  self.clean_rebuildable_in(key, require_archived=true).unwrap_or(0.0)
}

///|
/// Removes rebuildable build/install directories from an idle unarchived session's own directory without packing,
/// marking cold, or touching transcripts: Some(bytes) when measured, None when skipped before measuring.
pub async fn Storage::clean_idle_rebuildable(self : Storage, key : String) -> Double? {
  self.clean_rebuildable_in(key, require_archived=false)
}

///|
/// The files of an archived session's transcripts that cold storage puts away (cold.ts `historyFilesSoon`).
pub async fn Storage::history_files(self : Storage, key : String, packing : Bool) -> Array[String] {
  let fs = self.fs
  guard self.session(key) is Some(_) else { raise failed("unknown session \{key}") }
  let sources = self.st.store.runtime_session_sources(key, None)
  if sources.length() == 0 {
    return []
  }
  if packing {
    for s in sources {
      if self.st.store.transcript_in_use(get(s, "runtime").unwrap_or(Json::null()), get(s, "id").unwrap_or(Json::null()), js(key)) {
        return []
      }
    }
  }
  let located = self.ask("live.locate", [js(key)])
  if nullish(Some(located)) {
    return []
  }
  guard fs.realpath(self.data_dir()) is Some(root) else { raise fs_failed("ENOENT", "realpath", self.data_dir()) }
  let files = []
  let runtime0 = str(located, "runtime").unwrap_or("")
  for each in items(get(located, "paths")) {
    let (path, runtime) = match each {
      String(p) => (p, runtime0)
      e => (str(e, "path").unwrap_or(""), str(e, "runtime").unwrap_or(runtime0))
    }
    guard fs.realpath(fs.dirname(path)) is Some(parent) else { continue }
    if !fs.within(parent, root) {
      continue
    }
    files.push(fs.join([parent, fs.basename(path)]))
    if runtime == "claude" {
      let base = fs.basename(path)
      let stem = if base.has_suffix(".jsonl") { cut(base, 0, end=base.length() - 6) } else { base }
      fs.jsonl_files(fs.join([parent, stem]), files)
    }
  }
  files
}

///|
/// Whether an archived session's directory or transcripts are put away.
pub async fn Storage::is_cold(self : Storage, key : String) -> Bool {
  let fs = self.fs
  let room = match self.session(key) {
    Some(row) => self.room_of(str(row, "workspace").unwrap_or(""))
    None => None
  }
  match room {
    Some(r) =>
      if fs.there(fs.join([r, "cold"])) || fs.there(fs.workspace_archive(r)) || fs.there(fs.join([r, "workspace-locks.json"])) {
        return true
      }
    None => ()
  }
  let paths = try {
    let l = self.ask("live.locate", [js(key)])
    items(get(l, "paths")).map(p => match p {
      String(s) => s
      e => str(e, "path").unwrap_or("")
    })
  } catch {
    _ => return false
  }
  for path in paths {
    if !fs.there(path) && fs.there(packed_path(path)) {
      return true
    }
  }
  false
}

///|
pub async fn Storage::cold_restore(self : Storage, key : String) -> Unit {
  let fs = self.fs
  guard self.session(key) is Some(row) else { raise failed("unknown session \{key}") }
  guard self.room_of(str(row, "workspace").unwrap_or("")) is Some(room) else { return }
  fs.with_lock(room, async fn() {
    fs.restore_workspace(room)
    for path in self.history_files(key, false) {
      fs.restore_file(path)
    }
    fs.unlink(fs.join([room, "cold"])) catch { _ => () }
  })
}

///|
/// Archived long enough: its workspace keeps only the files sent in its chat (cold.ts `expire`).
pub async fn Storage::cold_expire(self : Storage, key : String, before : Double) -> Unit {
  let fs = self.fs
  let due = async fn() {
    let at = match self.session(key) {
      Some(r) => num(r, "archivedAt")
      None => None
    }
    match at {
      Some(a) => a <= before && self.archive_room(key) is Some(_)
      None => false
    }
  }
  self.find_room(key)
  let room = if due() { self.archive_room(key) } else { None }
  guard room is Some(room) else { return }
  fs.with_lock(room, async fn() {
    if !due() || !fs.there(fs.join([room, "cold"])) || !fs.holds_more(room) {
      return
    }
    fs.empty_workspace(room)
    self.log("info", "hub", "workspace of a long-archived session emptied", jo([("session", js(key))]))
  })
}

///|
/// Whether an archived session's directory holds more than its chat's files.
pub async fn Storage::cold_holds_more(self : Storage, key : String) -> Bool {
  let room = match self.session(key) {
    Some(row) => self.room_of(str(row, "workspace").unwrap_or(""))
    None => None
  }
  match room {
    Some(r) => self.fs.there(self.fs.join([r, "cold"])) && self.fs.holds_more(r)
    None => false
  }
}

///|
pub async fn Storage::cold_pack(self : Storage, key : String) -> Unit {
  let fs = self.fs
  self.find_room(key)
  guard self.archive_room(key) is Some(room) else { return }
  let ready = async fn() { self.archive_room(key) is Some(_) }
  fs.with_lock(room, async fn() {
    if !ready() {
      return
    }
    self.stop_strays(key, fs.join([room, "workspace"]))
    if !ready() {
      return
    }
    ignore(self.clean_rebuildable(key))
    if !ready() {
      return
    }
    fs.write_text(fs.join([room, "cold"]), "workspace and history may be compressed\n")
    fs.pack_workspace_if(room, ready)
    if !ready() {
      return
    }
    ignore(self.pack_history(key, ready))
  })
}

///|
async fn Files::run_out(self : Files, command : String, args : Array[String]) -> String? {
  as_str(Some(self.sh("proc.run", jo([("command", js(command)), ("args", ja(args.map(a => js(a)))), ("timeoutMs", ji(60000)), ("maxBytes", ji(16 << 20))]))))
}

///|
/// What still runs in an archived session's workspace, its agent's and its jobs' processes gone, stopped.
async fn Storage::stop_strays(self : Storage, key : String, workspace : String) -> Unit {
  let fs = self.fs
  if fs.sep == "\\" {
    return
  }
  guard fs.run_out("id", ["-u"]) is Some(uid) else { return }
  guard fs.run_out("ps", ["-U", js_trim(uid), "-o", "pid="]) is Some(out) else { return }
  let me = @host.pid()
  let pids = out.split("\n").filter_map(l => {
    let n = digits_of(js_trim(l.to_string()))
    if n > 1 && n != me { Some(n) } else { None }
  }).to_array()
  let real = fs.realpath(workspace).unwrap_or(workspace)
  let cwds : Array[(Int, String)] = []
  if pids.length() > 0 {
    if fs.is_dir("/proc/self") {
      for pid in pids {
        match fs.readlink("/proc/\{pid}/cwd") {
          Some(c) => cwds.push((pid, c))
          None => ()
        }
      }
    } else {
      let said = fs.sh("proc.run", jo([("command", js("lsof")), ("args", ja(["-a", "-d", "cwd", "-p", pids.map(p => p.to_string()).join(","), "-Fpn"].map(a => js(a)))), ("code", jb(true)), ("timeoutMs", ji(60000)), ("maxBytes", ji(16 << 20))]))
      let mut pid = -1
      for line in str(said, "out").unwrap_or("").split("\n") {
        let l = line.to_string()
        if l.has_prefix("p") {
          pid = digits_of(cut(l, 1))
        } else if l.has_prefix("n") && pid >= 0 {
          cwds.push((pid, cut(l, 1)))
        }
      }
    }
  }
  let mut stopped = 0
  for pair in cwds {
    let (pid, cwd) = pair
    if cwd != real && cwd != workspace && !fs.within(cwd, real) && !fs.within(cwd, workspace) {
      continue
    }
    match fs.sh("proc.run", jo([("command", js("kill")), ("args", ja([js("-TERM"), js(pid.to_string())])), ("code", jb(true))])) {
      Object(_) as v if num(v, "code") == Some(0.0) => stopped += 1
      _ => ()
    }
  }
  if stopped > 0 {
    self.log("info", "hub", "what was left running in an archived session's workspace stopped", jo([("session", js(key)), ("n", ji(stopped))]))
  }
}

///|
fn Files::legacy_copy(self : Files, archive_dir : String, key : String) -> String {
  self.join([archive_dir, "transcripts", "\{key}\{legacy_suffix}"])
}

///|
/// Packs an archived session's transcripts in place, then lets go of the Rust station's copy of them once they all
/// are: the copy's size, 0 without one.
async fn Storage::pack_history(self : Storage, key : String, ready : async () -> Bool) -> Double {
  let fs = self.fs
  let files = self.history_files(key, true)
  let sources = self.st.store.runtime_session_sources(key, None)
  let unused = async fn() {
    for s in sources {
      if self.st.store.transcript_in_use(get(s, "runtime").unwrap_or(Json::null()), get(s, "id").unwrap_or(Json::null()), js(key)) {
        return false
      }
    }
    true
  }
  for path in files {
    fs.pack_file_if(path, async fn() { ready() && unused() })
  }
  if files.length() == 0 {
    return 0.0
  }
  for path in files {
    if fs.there(path) || !fs.there(packed_path(path)) {
      return 0.0
    }
  }
  let copy = fs.legacy_copy(self.st.archive_dir, key)
  guard fs.stat(copy) is Some(s) else { return 0.0 }
  fs.unlink(copy)
  s.size
}

///|
/// What the Rust station's archiving left (`archive/transcripts/<key>.jsonl.zst`): each such session's transcripts
/// packed now as archiving packs them, and the copy let go.
pub async fn Storage::finish_legacy_copies(self : Storage) -> Unit {
  let fs = self.fs
  let dir = fs.join([self.st.archive_dir, "transcripts"])
  guard fs.readdir(dir) is Some(names) else { return }
  let mut freed = 0.0
  let mut done = 0
  for name in names {
    if !name.has_suffix(legacy_suffix) {
      continue
    }
    let key = cut(name, 0, end=name.length() - legacy_suffix.length())
    self.find_room(key)
    guard self.archive_room(key) is Some(room) else { continue }
    let ready = async fn() { self.archive_room(key) is Some(_) }
    fs.with_lock(room, async fn() {
      if !ready() {
        return
      }
      let size = self.pack_history(key, ready)
      freed += size
      if size > 0.0 {
        done += 1
      }
    }) catch {
      e => self.log("warn", "hub", "an archived session's transcripts not packed", jo([("session", js(key)), ("error", js(message_of(e)))]))
    }
  }
  if done > 0 {
    self.log("info", "hub", "the Rust station's transcript copies let go, the transcripts packed", jo([("sessions", ji(done)), ("freed", jn(freed))]))
  }
}

///|
/// Transcripts put away before they were in segments, put away again in segments; said so on disk once all are.
pub async fn Storage::segment_histories(self : Storage) -> Unit {
  let fs = self.fs
  let said = fs.join([self.data_dir(), segmented_mark])
  if fs.there(said) {
    return
  }
  let mut done = 0
  let mut failed_any = false
  let through = self.st.store.last_archived_session()
  let mut after = Json::null()
  while !nullish(Some(through)) {
    let page = items(Some(self.st.store.archived_sessions(after, through)))
    if page.length() == 0 {
      break
    }
    for row in page {
      let key = str(row, "key").unwrap_or("")
      let files = self.history_files(key, false) catch { _ => [] }
      for path in files {
        try fs.segment_file(path) catch {
          e => {
            failed_any = true
            self.log("warn", "hub", "a put-away transcript not put in segments", jo([("session", js(key)), ("error", js(message_of(e)))]))
          }
        } noraise {
          true => done += 1
          false => ()
        }
      }
      @effect.pause()
    }
    after = page[page.length() - 1]
  }
  if done > 0 {
    self.log("info", "hub", "put-away transcripts put in segments", jo([("n", ji(done))]))
  }
  if !failed_any {
    fs.write_text(said, "") catch { _ => () }
  }
}
