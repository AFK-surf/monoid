// The agents' memory, one for every station of a workspace (station/src/share/memory.ts `MemorySync`, line for line;
// its head says the whole of it): MEMORY.md and the team's skills kept level between the stations over the station
// transport (`memory.get`, `memory.blobs`, `memory.put`), each file a record (`Rec`) of its content's hash, when and by
// which station it was made and what it was made after; a version that comes after this station's written over it,
// one made beside it merged by station/mb src/memory (`decide`), each station computing the same from the same two.

///|
/// A file is shared up to this size, a skill up to SKILL_MOST bytes and SKILL_FILES files.
let file_most : Double = 524288.0

///|
let skill_most : Double = 4194304.0

///|
let skill_files : Int = 200

///|
/// A request carries at most this many bytes of content.
let batch_bytes : Double = 614400.0

///|
/// The versions of a file kept after its present one.
let prev_most : Int = 16

///|
/// A station not brought level is tried again after this, twice as long each time up to RETRY_MOST_MS.
pub let memory_retry_ms : Double = 5000.0

///|
let retry_most_ms : Double = 600000.0

///|
/// The most directories of the agents' home watched.
let follow_most : Int = 1000

///|
/// The skills the station brings, by directory name (sessions/agent-home.ts `BUILTIN_SKILLS`, `FEEDBACK_SKILL`), and
/// those it brought before (`RETIRED_SKILLS`: a copy left of one is never synced as a team skill).
pub let builtin_skills : Array[String] = [
  "stillfail-chats", "stillfail-jobs", "stillfail-show", "stillfail-viz", "stillfail-browser", "stillfail-login", "stillfail-vault",
  "stillfail-cron", "stillfail-github-ci", "stillfail-retire", "stillfail-move", "stillfail-leading", "stillfail-feedback",
]

///|
fn is_hex64(s : String) -> Bool {
  s.length() == 64 && s.iter().all(c => (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f'))
}

///|
fn safe_int(d : Double) -> Bool {
  @jsjson.is_safe_integer(d)
}

///|
/// Whether `path` names a file of the memory: MEMORY.md, or a file under skills/<name>/ of a team's skill.
pub fn memory_path(path : Json?) -> Bool {
  guard path is Some(String(p)) && p.length() <= 512 else { return false }
  if p == "MEMORY.md" {
    return true
  }
  let parts = p.split("/").map(x => x.to_string()).collect()
  if parts.length() < 3 || parts[0] != "skills" || builtin_skills.contains(parts[1]) {
    return false
  }
  parts[1:].iter().all(x => @memory.portable_name(x) && !skipped.contains(x))
}

///|
/// A record as a peer tells it, as it is kept; None when it is none (memory.ts `recOf`).
pub fn rec_of_peer(raw : Json?) -> Json? {
  guard raw is Some(Object(r)) else { return None }
  guard r.get("hash") is Some(String(hash)) && (hash == "" || is_hex64(hash)) else { return None }
  guard r.get("at") is Some(Number(at, ..)) && safe_int(at) && at >= 0.0 else { return None }
  guard r.get("by") is Some(String(by)) && is_hex64(by) else { return None }
  guard r.get("prev") is Some(Array(prev)) &&
    prev.length() <= prev_most * 2 &&
    prev.iter().all(h => h is String(x) && is_hex64(x)) else {
    return None
  }
  guard r.get("size") is Some(Number(size, ..)) && safe_int(size) && size >= 0.0 && size <= file_most else {
    return None
  }
  guard r.get("mode") is Some(Number(mode, ..)) && (mode == 0o644.to_double() || mode == 0o755.to_double()) else {
    return None
  }
  let out = jobj([
    ("hash", jstr(hash)),
    ("at", jnum(at)),
    ("by", jstr(by)),
    ("prev", jarr(prev.copy())),
    ("size", jnum(size)),
    ("mode", jnum(mode)),
  ])
  if r.get("origin") is Some(True) && out is Object(o) {
    o["origin"] = jbool(true)
  }
  Some(out)
}

///|
fn rec_hash(r : Json) -> String {
  str_of(get(Some(r), "hash")).unwrap_or("")
}

///|
fn rec_by(r : Json) -> String {
  str_of(get(Some(r), "by")).unwrap_or("")
}

///|
fn rec_num(r : Json, k : String) -> Double {
  match get(Some(r), k) {
    Some(Number(d, ..)) => d
    _ => 0.0
  }
}

///|
fn rec_prev(r : Json) -> Array[String] {
  match get(Some(r), "prev") {
    Some(Array(a)) => str_list(a)
    _ => []
  }
}

///|
fn rec(hash : String, at : Double, by : String, prev : Array[String], size : Double, mode : Double, origin : Bool) -> Json {
  let out = jobj([
    ("hash", jstr(hash)),
    ("at", jnum(at)),
    ("by", jstr(by)),
    ("prev", jstrs(prev)),
    ("size", jnum(size)),
    ("mode", jnum(mode)),
  ])
  if origin && out is Object(o) {
    o["origin"] = jbool(true)
  }
  out
}

///|
/// The hashes a record is of: its own and those it was made after, none deleted (memory.ts `history`).
fn history_of(r : Json) -> Array[String] {
  ([rec_hash(r)] + rec_prev(r)).filter(h => h != "")
}

///|
/// What a record is made after (memory.ts `after`): its own hash, then `prev`, then what it was made after, each once.
fn after_of(r : Json, prev : Array[String]) -> Array[String] {
  let out : Array[String] = []
  for h in [rec_hash(r)] + prev + rec_prev(r) {
    if h != "" && !out.contains(h) {
      out.push(h)
    }
  }
  if out.length() > prev_most {
    out[0:prev_most].to_array()
  } else {
    out
  }
}

///|
/// Whether the agents' home's directory at `rel` is followed (memory.ts `memoryFollowed`).
pub fn memory_followed(rel : String) -> Bool {
  let parts = rel.split("/").map(x => x.to_string()).collect()
  let mut i = 0
  if parts[0] == "workspaces" {
    if parts.length() == 1 {
      return true
    }
    if !is_ws_id(parts[1]) {
      return false
    }
    if parts.length() == 2 {
      return true
    }
    i = 2
  }
  if i >= parts.length() || parts[i] != "skills" {
    return false
  }
  if parts.length() == i + 1 {
    return true
  }
  if builtin_skills.contains(parts[i + 1]) {
    return false
  }
  parts[i + 1:].iter().all(n => @memory.portable_name(n) && !skipped.contains(n))
}

///|
/// A station from before the memory was shared: nothing to bring level with it.
fn before_memory(e : Error) -> Bool {
  let m = error_words(e).to_lower()
  m.contains("unsupported peer method") || m.contains("unknown memory method") || m.contains("session and task key are required")
}

///|
/// A file of only its owner's (a key): this machine's alone, never shared.
fn own_mode(m : Int) -> Bool {
  (m & 0o077) == 0
}

///|
/// What a station keeps of a workspace's memory: a clock that only rises and each file's record.
priv struct Kept {
  mut clock : Double
  files : Map[String, Json]
}

///|
fn Kept::json(self : Kept) -> Json {
  jobj([("clock", jnum(self.clock)), ("files", Json::object(self.files))])
}

///|
/// What the memory is given (memory.ts `MemoryDeps`).
pub(all) struct MemoryDeps {
  data : String
  cloud : Cloud
  /// A request to another station of workspace `workspace` (the station transport).
  ask : async (String, String, Json) -> Json
  /// The agents' home.
  agent_home : () -> String
  /// The agent home of workspace `ws` made where a joined one's is not (sessions/agent-home.ts `workspaceAgentHome`,
  /// station/mb src/session_storage `Storage::workspace_agent_home`: the station's own skills in it as the home
  /// workspace has them, stillfail-move where the home has it, as the station's channel has it written there).
  workspace_agent_home : async (String, String?, String?) -> String
  /// Nothing set going by itself (tests: no watch, no station brought level but by `level_now`).
  still : Bool
  watching : Watching
  clock : Clock
  log : Log
  files : Files
}

///|
pub struct MemorySync {
  deps : MemoryDeps
  priv tasks : Tasks
  priv files : Files
  priv program : MemoryProgram
  priv kept : Map[String, Kept]
  priv saved : Map[String, PrivateFile]
  priv lanes : Map[String, Turn]
  priv level_at : Map[String, String]
  priv going : Set[String]
  priv retries : Map[String, (Double, Ref[Bool], () -> Unit)]
  priv settle : Map[String, () -> Unit]
  priv mut tree : (String, Watcher)?
  priv mut follow_retry : (Double, Ref[Bool], () -> Unit)?
  priv stops : Array[() -> Unit]
  priv mut stopped : Bool
}

///|
pub fn MemorySync::new(deps : MemoryDeps, rt : @effect.Runtime) -> MemorySync {
  {
    deps,
    tasks: Tasks::new(rt, deps.log, "memory"),
    files: deps.files,
    program: MemoryProgram::new(deps.files.host, deps.files.sep),
    kept: Map([]),
    saved: Map([]),
    lanes: Map([]),
    level_at: Map([]),
    going: Set::new(),
    retries: Map([]),
    settle: Map([]),
    tree: None,
    follow_retry: None,
    stops: [],
    stopped: false,
  }
}

///|
pub fn MemorySync::busy(self : MemorySync) -> Int {
  self.tasks.busy
}

///|
/// The program let go if nothing is asked of it: 1, else 0.
pub fn MemorySync::trim_idle(self : MemorySync) -> Int {
  self.program.trim_idle()
}

///|
fn MemorySync::me(self : MemorySync) -> String {
  (self.deps.cloud.station)().unwrap_or("")
}

///|
fn MemorySync::root(self : MemorySync) -> String {
  self.files.join([self.deps.data, "share", "memory"])
}

///|
fn MemorySync::blobs_dir(self : MemorySync) -> String {
  self.files.join([self.root(), "blobs"])
}

///|
/// Where workspace `ws`'s memory is, made where it is a joined one's not made yet.
async fn MemorySync::home(self : MemorySync, ws : String) -> String {
  (self.deps.workspace_agent_home)((self.deps.agent_home)(), Some(ws), (self.deps.cloud.home)())
}

///|
/// A station's name in `ws` as its roster says: what marks its lines and names a version kept beside another.
fn MemorySync::name_of(self : MemorySync, ws : String, station : String) -> String {
  let peers = match (self.deps.cloud.membership)(ws) {
    Some(m) => m.peers
    None => []
  }
  for p in peers {
    if get(Some(p), "id") is Some(String(id)) && id == station {
      match get(Some(p), "name") {
        Some(String(n)) if js_trim(n) != "" => return js_trim(n)
        _ => ()
      }
      break
    }
  }
  if station == self.me() && (self.deps.cloud.name)() is Some(n) && js_trim(n) != "" {
    return js_trim(n)
  }
  js_slice(station, 8)
}

///|
async fn[A] MemorySync::lane(self : MemorySync, ws : String, f : async () -> A) -> A {
  let turn = match self.lanes.get(ws) {
    Some(t) => t
    None => {
      let t = Turn::new()
      self.lanes[ws] = t
      t
    }
  }
  turn.run(f)
}

// ── what is kept ──

///|
/// What is kept of `ws` (read from its file the first time) and whether nothing was (`fresh`).
async fn MemorySync::state(self : MemorySync, ws : String) -> (Kept, Bool) {
  if self.kept.get(ws) is Some(had) {
    return (had, false)
  }
  let path = self.files.join([self.root(), "\{ws}.json"])
  let read : Kept? = match self.files.read_text(path) {
    Some(text) =>
      match (try Some(js_parse(text)) catch { _ => None }) {
        Some(raw) => {
          let files : Map[String, Json] = Map([])
          if get(Some(raw), "files") is Some(Object(fs)) {
            for p in js_keys(fs) {
              if rec_of_peer(Some(fs[p])) is Some(r) && memory_path(Some(jstr(p))) {
                files[p] = r
              }
            }
          }
          let clock = match get(Some(raw), "clock") {
            Some(Number(c, ..)) if safe_int(c) => c
            _ => 0.0
          }
          Some({ clock, files })
        }
        None => None
      }
    None => None
  }
  // (another ask may have read it while this one did: the first kept is the one)
  if self.kept.get(ws) is Some(had) {
    return (had, false)
  }
  let fresh = read is None
  let kept = read.unwrap_or({ clock: 0.0, files: Map([]) })
  self.kept[ws] = kept
  (kept, fresh)
}

///|
fn MemorySync::save(self : MemorySync, ws : String) -> Unit {
  guard self.kept.get(ws) is Some(kept) else { return }
  let file = match self.saved.get(ws) {
    Some(f) => f
    None => {
      let f = PrivateFile::new(self.files, self.files.join([self.root(), "\{ws}.json"]), self.tasks)
      self.saved[ws] = f
      f
    }
  }
  file.write(js_stringify(kept.json()))
}

///|
/// Once what was kept is written (tests).
pub async fn MemorySync::written(self : MemorySync) -> Unit {
  for _, lane in self.lanes {
    lane.settled()
  }
  for _, f in self.saved {
    f.written()
  }
}

///|
fn MemorySync::tick(self : MemorySync, ws : String, at_least? : Double = 0.0) -> Double {
  let kept = self.kept[ws]
  let mut c = kept.clock + 1.0
  let now = (self.deps.clock.now)()
  if now > c {
    c = now
  }
  if at_least > c {
    c = at_least
  }
  kept.clock = c
  c
}

///|
fn MemorySync::blob(self : MemorySync, hash : String) -> String {
  self.files.join([self.root(), "blobs", hash])
}

///|
async fn MemorySync::content(self : MemorySync, hash : String) -> Bytes? {
  if hash == "" {
    return None
  }
  guard self.files.read_bytes(self.blob(hash)) is Some(bytes) else { return None }
  if @memory.sha256_hex(bytes) == hash {
    Some(bytes)
  } else {
    None
  }
}

///|
/// `bytes`, of version `hash`, kept unless they are already.
async fn MemorySync::keep_blob(self : MemorySync, hash : String, bytes : Bytes) -> Unit {
  if self.files.lstat(self.blob(hash)) is None {
    self.files.write_private(self.blob(hash), bytes)
  }
}

///|
/// A version's bytes to write: what a peer brought, else what blobs/ keeps of it.
async fn MemorySync::bytes(self : MemorySync, hash : String, given : Map[String, Bytes]) -> Bytes? {
  match given.get(hash) {
    Some(b) => Some(b)
    None => self.files.read_bytes(self.blob(hash))
  }
}

// ── the files as they are ──

///|
/// The memory's files in `dir` as they are now (as the program read them), and those held as they are.
async fn MemorySync::read(self : MemorySync, dir : String, kept : Map[String, Json]) -> (Map[String, Json], Array[String]) {
  let hashes : Map[String, Json] = Map([])
  for p in js_keys(kept) {
    hashes[p] = jstr(rec_hash(kept[p]))
  }
  let answer = self.program.ask("scan", [
    ("dir", jstr(dir)),
    ("blobs", jstr(self.blobs_dir())),
    ("kept", Json::object(hashes)),
    ("builtin", jstrs(builtin_skills)),
    ("skipped", jstrs(skipped)),
    ("fileMost", jnum(file_most)),
    ("skillMost", jnum(skill_most)),
    ("skillFiles", jnum(skill_files.to_double())),
  ])
  let files : Map[String, Json] = Map([])
  if get(Some(answer), "files") is Some(Array(fs)) {
    for f in fs {
      files[js_string(get(Some(f), "path"))] = f
    }
  }
  let held = match get(Some(answer), "held") {
    Some(Array(h)) => str_list(h)
    _ => []
  }
  (files, held)
}

///|
/// Records made of what changed in `ws`'s files since the last look (whether any did).
async fn MemorySync::look(self : MemorySync, ws : String) -> Bool {
  let (_, fresh) = self.state(ws)
  let kept = self.kept[ws]
  let me = self.me()
  if me == "" {
    return false
  }
  let (files, held) = self.read(self.home(ws), kept.files)
  let is_held = (path : String) => held.contains(path) ||
    held.iter().any(h => h.has_suffix("/") && path.has_prefix(h))
  let mut changed = false
  for path, f in files {
    let hash = js_string(get(Some(f), "hash"))
    let had = kept.files.get(path)
    if had is Some(r) && rec_hash(r) == hash {
      continue
    }
    if had is None && path == "MEMORY.md" && get(Some(f), "empty") is Some(True) {
      continue
    }
    // What it had before the memory was shared (its first look) goes as when it was last changed; anything after, as now.
    let origin = fresh && had is None
    let at = if origin {
      self.tick(ws, at_least=num_or0(get(Some(f), "mtime")))
    } else {
      self.tick(ws)
    }
    let prev = match had {
      None => []
      Some(r) => after_of(r, [])
    }
    kept.files[path] = rec(hash, at, me, prev, num_or0(get(Some(f), "size")), num_or0(get(Some(f), "mode")), origin)
    changed = true
  }
  for path in js_keys(kept.files) {
    let r = kept.files[path]
    if rec_hash(r) == "" || files.contains(path) || is_held(path) {
      continue
    }
    kept.files[path] = rec("", self.tick(ws), me, after_of(r, []), 0.0, rec_num(r, "mode"), false)
    changed = true
  }
  if self.mend(ws) {
    changed = true
  }
  if changed || fresh {
    self.save(ws)
  }
  changed
}

///|
/// What stations of 0.1.9133 to 0.1.9168 left of skills kept apart, mended as each looks (memory.ts `#mend`).
async fn MemorySync::mend(self : MemorySync, ws : String) -> Bool {
  let kept = self.kept[ws]
  let skills : Array[Json] = []
  for path in js_keys(kept.files) {
    let r = kept.files[path]
    guard path.has_prefix("skills/") && path.has_suffix("/SKILL.md") else { continue }
    let middle = path.view(start_offset=7, end_offset=path.length() - 9).to_string()
    if middle == "" || middle.contains("/") || rec_hash(r) == "" {
      continue
    }
    skills.push(jobj([("skill", jstr(middle)), ("hash", jstr(rec_hash(r))), ("author", jstr(self.name_of(ws, rec_by(r))))]))
  }
  let aside : Array[Json] = if skills.is_empty() {
    []
  } else {
    match get(Some(self.program.ask("asides", [("blobs", jstr(self.blobs_dir())), ("skills", jarr(skills))])), "asides") {
      Some(Array(a)) => a
      _ => []
    }
  }
  let s = (a : Json, k : String) => js_string(get(Some(a), k))
  let mut changed = false
  let gone : Set[String] = Set::new()
  let keys : Array[String] = []
  let groups : Map[String, Array[Json]] = Map([])
  for a in aside {
    let key = "\{s(a, "base")}\u{0}\{s(a, "body")}"
    match groups.get(key) {
      Some(g) => g.push(a)
      None => {
        keys.push(key)
        groups[key] = [a]
      }
    }
  }
  for key in keys {
    let group = groups[key]
    if group.length() < 2 {
      continue
    }
    let named = (x : Json) => if s(x, "tag") == s(x, "author") { 1 } else { 0 }
    group.sort_by((x, y) => {
      let by_name = named(y) - named(x)
      if by_name != 0 {
        by_name
      } else if @memory.js_after(s(y, "skill"), s(x, "skill")) {
        -1
      } else {
        1
      }
    })
    for extra in group[1:] {
      let skill = s(extra, "skill")
      for path in js_keys(kept.files) {
        let r = kept.files[path]
        if !path.has_prefix("skills/\{skill}/") || rec_hash(r) == "" {
          continue
        }
        let deleted = rec("", self.tick(ws), self.me(), after_of(r, []), 0.0, rec_num(r, "mode"), false)
        if self.write(ws, path, deleted, None) {
          changed = true
        }
      }
      gone.add(skill)
      self.deps.log.info("memory", "a skill kept apart twice made one", jobj([
        ("workspace", jstr(ws)),
        ("kept", jstr(s(group[0], "skill"))),
        ("gone", jstr(skill)),
      ]))
    }
  }
  for a in aside {
    if gone.contains(s(a, "skill")) {
      continue
    }
    let from = self.files.join([self.home(ws), "skills", s(a, "skill")])
    let to = self.files.join([self.home(ws), "skills", s(a, "base")])
    guard self.files.lstat(to) is Some(st) && st.kind == "dir" else { continue }
    let entries = self.files.readdir_types(from).unwrap_or([])
    for e in entries {
      if e.1 != "file" {
        continue
      }
      guard self.files.lstat(self.files.join([from, e.0])) is Some(fst) else {
        raise Failed("ENOENT: no such file or directory, lstat '\{self.files.join([from, e.0])}'")
      }
      if !own_mode(fst.mode) {
        continue
      }
      if self.files.lstat(self.files.join([to, e.0])) is Some(_) {
        continue
      }
      try {
        self.files.copy(self.files.join([from, e.0]), self.files.join([to, e.0]))
        self.files.chmod(self.files.join([to, e.0]), fst.mode & 0o777)
      } catch {
        err =>
          self.deps.log.warn("memory", "a file of a skill kept apart not put back", jobj([
            ("skill", jstr(s(a, "skill"))),
            ("file", jstr(e.0)),
            ("error", jstr(error_words(err))),
          ]))
      }
    }
  }
  changed
}

///|
/// What a station writes in a MEMORY.md of nothing yet.
fn empty_memory_text(t : String) -> Bool {
  match js_trim(t) {
    "" | "# still.fail memory" | "# ember memory" => true
    _ => false
  }
}

///|
/// `rec`'s version of `path` written in `ws`'s files (deleted where it is), unless the file changed since the last
/// look (an edit not yet looked at: it is looked at first, and merged). Whether it was.
async fn MemorySync::write(self : MemorySync, ws : String, path : String, r : Json, content : Bytes?) -> Bool {
  let kept = self.kept[ws]
  let dir = self.home(ws)
  let parts = path.split("/").map(x => x.to_string()).collect()
  let full = self.files.join([dir] + parts)
  // A skill this station has as a link (a deployment's, one borrowed from a share) stays as it is: the record is kept.
  if parts[0] == "skills" {
    if self.files.lstat(self.files.join([dir, "skills", parts[1]])) is Some(st) && st.kind == "link" {
      kept.files[path] = r
      return true
    }
  }
  let now_hash = match get(Some(self.program.ask("hash", [("path", jstr(full))])), "hash") {
    Some(String(h)) => h
    _ => ""
  }
  let was = kept.files.get(path)
  let was_hash = match was {
    Some(w) => rec_hash(w)
    None => ""
  }
  if now_hash != was_hash {
    // (a MEMORY.md of nothing yet is read only where it may be one: no record of it, something there)
    let empty = was is None &&
      path == "MEMORY.md" &&
      now_hash != "" &&
      empty_memory_text(self.files.read_text(full).unwrap_or("\u{0}"))
    if !empty {
      // Edited here since it was looked at: looked at again (and merged, made beside it) before anything is written.
      self.again(ws)
      return false
    }
  }
  match content {
    None => {
      if self.files.lstat(full) is Some(st) && st.kind != "dir" {
        self.files.remove(full) catch {
          _ => ()
        }
      }
      // Its directories, emptied, go too (up to the skill's).
      let skills_root = self.files.join([dir, "skills"])
      let mut d = self.files.dirname(full)
      while parts[0] == "skills" && d.length() > skills_root.length() {
        let removed = match self.files.lstat(d) {
          Some(st) if st.kind == "dir" => (try { self.files.remove(d); true } catch { _ => false })
          _ => false
        }
        if !removed {
          break
        }
        d = self.files.dirname(d)
      }
    }
    Some(bytes) => {
      self.files.mkdir(self.files.dirname(full))
      let mode = rec_num(r, "mode").to_int()
      let tmp = "\{full}.\{@host.pid()}.memory-tmp"
      self.files.write(tmp, bytes, mode)
      self.files.chmod(tmp, mode)
      self.files.rename(tmp, full)
      self.keep_blob(rec_hash(r), bytes)
    }
  }
  kept.files[path] = r
  true
}

///|
/// What another station said of `ws`'s files taken here: each version that comes after this one's written, each made
/// beside it merged. `given`: the versions' content it brought. Whether anything here changed.
async fn MemorySync::take(self : MemorySync, ws : String, theirs : Map[String, Json], given : Map[String, Bytes]) -> Bool {
  let kept = self.kept[ws]
  let mut changed = self.apart(ws, theirs, given)
  for path in js_keys(theirs) {
    guard theirs.get(path) is Some(r) else { continue }
    let mine = kept.files.get(path)
    // What it brought of the versions this decision may read (the rest are blobs/'s), and the stations' names.
    let brought : Map[String, Json] = Map([])
    let wanted : Array[String] = []
    for h in [rec_hash(r)] + rec_prev(r) + history_of(mine.unwrap_or(r)) {
      if !wanted.contains(h) {
        wanted.push(h)
      }
    }
    for h in wanted {
      if given.get(h) is Some(b) {
        brought[h] = jstr(@hex.encode(b))
      }
    }
    let names : Map[String, Json] = Map([])
    names[rec_by(r)] = jstr(self.name_of(ws, rec_by(r)))
    if mine is Some(m) {
      names[rec_by(m)] = jstr(self.name_of(ws, rec_by(m)))
    }
    let outcome = self.program.ask("decide", [
      ("path", jstr(path)),
      ("mine", mine.unwrap_or(jnull())),
      ("theirs", r),
      ("names", Json::object(names)),
      ("given", Json::object(brought)),
      ("blobs", jstr(self.blobs_dir())),
      ("prevMost", jnum(prev_most.to_double())),
    ])
    match get(Some(outcome), "kind") {
      Some(String("keep")) => continue
      Some(String("take")) => {
        // (`content`: the program found it, brought or kept, as what it is)
        let content = if rec_hash(r) == "" || !(get(Some(outcome), "content") is Some(True)) {
          None
        } else {
          self.bytes(rec_hash(r), given)
        }
        if rec_hash(r) != "" && content is None {
          continue
        }
        if kept.files.get(path) is Some(k) && rec_hash(k) == rec_hash(r) {
          kept.files[path] = r
        } else if !self.write(ws, path, r, content) {
          continue
        }
        if rec_num(r, "at") > kept.clock {
          kept.clock = rec_num(r, "at")
        }
        changed = true
        continue
      }
      _ => ()
    }
    let merged = get(Some(outcome), "rec").unwrap_or(jnull())
    guard self.bytes(rec_hash(merged), given) is Some(content) else { continue }
    if !self.write(ws, path, merged, Some(content)) {
      continue
    }
    if rec_num(merged, "at") > kept.clock {
      kept.clock = rec_num(merged, "at")
    }
    let beside = match get(Some(outcome), "beside") {
      Some(Object(_) as b) if memory_path(get(Some(b), "path")) => Some(b)
      _ => None
    }
    if beside is Some(b) {
      let bpath = js_string(get(Some(b), "path"))
      let brec = get(Some(b), "rec").unwrap_or(jnull())
      let same = match kept.files.get(bpath) {
        Some(k) => rec_hash(k) == rec_hash(brec)
        None => false
      }
      if !same {
        if self.bytes(rec_hash(brec), given) is Some(lc) {
          ignore(self.write(ws, bpath, brec, Some(lc)))
        }
      }
    }
    self.deps.log.info("memory", "a file of the memory made apart merged", jobj([
      ("workspace", jstr(ws)),
      ("path", jstr(path)),
      ("beside", match beside { Some(b) => get(Some(b), "path").unwrap_or(jnull()); None => jnull() }),
    ]))
    changed = true
  }
  if changed {
    self.save(ws)
  }
  changed
}

///|
/// Skills two stations each had before the memory was shared, of one name and nothing alike: not merged, the smaller
/// kept as a skill of its own, `<name>-<station>` (memory.ts `#apart`). Whether anything here changed.
async fn MemorySync::apart(self : MemorySync, ws : String, theirs : Map[String, Json], given : Map[String, Bytes]) -> Bool {
  let kept = self.kept[ws]
  let me = self.me()
  let skills_of = (files : Map[String, Json]) => {
    let names : Array[String] = []
    let out : Map[String, Array[(String, Json)]] = Map([])
    for path in js_keys(files) {
      let r = files[path]
      let parts = path.split("/").map(x => x.to_string()).collect()
      if parts[0] != "skills" || rec_hash(r) == "" {
        continue
      }
      let name = parts.get(1).unwrap_or("")
      match out.get(name) {
        Some(a) => a.push((path, r))
        None => {
          names.push(name)
          out[name] = [(path, r)]
        }
      }
    }
    (names, out)
  }
  let (_, mine_by) = skills_of(kept.files)
  let (their_names, their_by) = skills_of(theirs)
  let mut changed = false
  for name in their_names {
    let their = their_by[name]
    guard mine_by.get(name) is Some(mine) else { continue }
    let skill_md = "skills/\{name}/SKILL.md"
    guard kept.files.get(skill_md) is Some(ms) && theirs.get(skill_md) is Some(ts) else { continue }
    if rec_hash(ms) == rec_hash(ts) || (mine + their).iter().any(e => !(get(Some(e.1), "origin") is Some(True))) {
      continue
    }
    let th = history_of(ts)
    if history_of(ms).iter().any(h => th.contains(h)) {
      continue
    }
    // One skill each kept on (copied once, edited on both since): merged file by file, not kept apart.
    let tb : Map[String, Json] = Map([])
    if given.get(rec_hash(ts)) is Some(b) {
      tb[rec_hash(ts)] = jstr(@hex.encode(b))
    }
    let alike = get(
      Some(
        self.program.ask("alikeKept", [
          ("blobs", jstr(self.blobs_dir())),
          ("a", jstr(rec_hash(ms))),
          ("b", jstr(rec_hash(ts))),
          ("given", Json::object(tb)),
        ]),
      ),
      "alike",
    )
    if !(alike is Some(False)) {
      continue
    }
    let size = (files : Array[(String, Json)]) => files.fold(init=0.0, (n, e) => n + rec_num(e.1, "size"))
    let sm = size(mine)
    let st = size(their)
    let mine_aside = if sm != st { sm < st } else { @memory.js_after(rec_by(ts), me) }
    // Named for the station that made it, not the one keeping it.
    let owner = rec_by(if mine_aside { ms } else { ts })
    let owner_name = self.name_of(ws, owner)
    let tag = match get(Some(self.program.ask("tags", [("names", jstrs([owner_name]))])), "tags") {
      Some(Array(t)) => js_string(t.get(0))
      _ => "undefined"
    }
    let aside = "\{name}-\{tag}"
    if !@memory.portable_name(aside) || builtin_skills.contains(aside) {
      continue
    }
    let moved : Array[(String, Json, Bytes)] = []
    for e in (if mine_aside { mine } else { their }) {
      let (path, r) = e
      let content = if mine_aside {
        self.content(rec_hash(r))
      } else {
        match given.get(rec_hash(r)) {
          Some(b) => Some(b)
          None => self.content(rec_hash(r))
        }
      }
      guard content is Some(c) else {
        moved.clear()
        break
      }
      let to = "skills/\{aside}/\{path.view(start_offset=("skills/" + name + "/").length()).to_string()}"
      let bytes = if path == skill_md { aside_skill(c, aside, owner_name) } else { c }
      moved.push((to, rec(@memory.sha256_hex(bytes), rec_num(r, "at"), rec_by(r), [], bytes.length().to_double(), rec_num(r, "mode"), true), bytes))
    }
    if moved.is_empty() {
      continue
    }
    for m in moved {
      let (to, r, bytes) = m
      let same = match kept.files.get(to) {
        Some(k) => rec_hash(k) == rec_hash(r)
        None => false
      }
      if !same && !self.write(ws, to, r, Some(bytes)) {
        return changed
      }
    }
    if mine_aside {
      // Its own moved aside: gone from under the name with no record of it, for the other's to come in as new.
      for e in mine {
        let (path, r) = e
        let gone = match r {
          Object(o) => {
            let c : Map[String, Json] = Map([])
            for k in js_keys(o) {
              c[k] = o[k]
            }
            c["hash"] = jstr("")
            Json::object(c)
          }
          other => other
        }
        if self.write(ws, path, gone, None) {
          kept.files.remove(path)
        }
      }
      self.copy_rest(ws, name, aside)
    } else {
      for e in their {
        theirs.remove(e.0)
      }
    }
    self.deps.log.info("memory", "two skills of one name kept apart", jobj([("workspace", jstr(ws)), ("skill", jstr(name)), ("aside", jstr(aside))]))
    changed = true
  }
  changed
}

///|
/// What is left of skill `name` here once its shared files moved aside (a file only its owner reads): copied beside
/// them, and left where it was too.
async fn MemorySync::copy_rest(self : MemorySync, ws : String, name : String, aside : String) -> Unit {
  let from = self.files.join([self.home(ws), "skills", name])
  let to = self.files.join([self.home(ws), "skills", aside])
  let stack : Array[String] = [""]
  // (depth first, in the order the directory gives its names, as the walk of memory.ts goes)
  async fn walk(rel : String) -> Unit {
    let entries = match self.files.readdir_types(if rel == "" { from } else { self.files.join([from, rel]) }) {
      Some(e) => e
      None => return
    }
    for e in entries {
      let sub = if rel == "" { e.0 } else { self.files.join([rel, e.0]) }
      if e.1 == "dir" {
        walk(sub)
      } else if e.1 == "file" {
        if self.files.lstat(self.files.join([to, sub])) is Some(_) {
          continue
        }
        self.files.mkdir(self.files.dirname(self.files.join([to, sub])))
        try {
          self.files.copy(self.files.join([from, sub]), self.files.join([to, sub]))
          let mode = match self.files.lstat(self.files.join([from, sub])) {
            Some(st) => st.mode
            None => raise Failed("ENOENT: no such file or directory, lstat '\{self.files.join([from, sub])}'")
          }
          self.files.chmod(self.files.join([to, sub]), mode & 0o777)
        } catch {
          err =>
            self.deps.log.warn("memory", "a file of a skill kept apart not copied beside it", jobj([
              ("skill", jstr(name)),
              ("file", jstr(sub)),
              ("error", jstr(error_words(err))),
            ]))
        }
      }
    }
  }
  ignore(stack)
  walk("")
}

// ── between the stations ──

///|
/// A peer's `memory.*` request in workspace `ws` (the transport checked it is of it).
pub async fn MemorySync::handle(self : MemorySync, _peer : String, request : Json, ws : String?) -> Json {
  guard ws is Some(w) && w != "" && (self.deps.cloud.membership)(w) is Some(_) else {
    raise Failed("not a workspace of this station's")
  }
  match get(Some(request), "method") {
    Some(String("memory.get")) =>
      self.lane(w, async fn() {
        ignore(self.look(w))
        jobj([("files", Json::object(self.kept[w].files))])
      })
    Some(String("memory.blobs")) => {
      let out : Map[String, Json] = Map([])
      let mut bytes = 0.0
      let hashes = match get(Some(request), "hashes") {
        Some(Array(a)) => a
        _ => []
      }
      for hj in hashes {
        guard hj is String(h) && is_hex64(h) && bytes <= batch_bytes else { continue }
        // Only what a record of this workspace names: nothing of another's.
        let named = match self.kept.get(w) {
          Some(k) => k.files.values().any(r => rec_hash(r) == h || rec_prev(r).contains(h))
          None => false
        }
        if !named {
          continue
        }
        if self.content(h) is Some(c) {
          out[h] = jstr(base64_of(c))
          bytes += c.length().to_double()
        }
      }
      jobj([("blobs", Json::object(out))])
    }
    Some(String("memory.put")) =>
      self.lane(w, async fn() {
        ignore(self.look(w))
        let theirs : Map[String, Json] = Map([])
        if get(Some(request), "files") is Some(Object(fs)) {
          for path in js_keys(fs) {
            guard rec_of_peer(Some(fs[path])) is Some(r) && memory_path(Some(jstr(path))) else {
              raise Failed("a malformed record of the memory")
            }
            theirs[path] = r
          }
        }
        let given : Map[String, Bytes] = Map([])
        if get(Some(request), "blobs") is Some(Object(bs)) {
          for h in js_keys(bs) {
            let b = base64_loose(js_string(Some(bs[h])))
            if @memory.sha256_hex(b) == h {
              given[h] = b
            }
          }
        }
        if self.take(w, theirs, given) {
          self.again(w)
        }
        jobj([("taken", jbool(true))])
      })
    _ => raise Failed("unknown memory method")
  }
}

///|
/// Brings `peer` and this station level in `ws`: what it has that comes after or beside this station's taken here,
/// then what this station has that it lacks given it.
async fn MemorySync::level(self : MemorySync, peer : String, ws : String) -> Unit {
  let got = (self.deps.ask)(peer, ws, jobj([("method", jstr("memory.get"))]))
  let theirs : Map[String, Json] = Map([])
  if get(Some(got), "files") is Some(Object(fs)) {
    for path in js_keys(fs) {
      if rec_of_peer(Some(fs[path])) is Some(r) && memory_path(Some(jstr(path))) {
        theirs[path] = r
      }
    }
  }
  self.lane(ws, async fn() {
    ignore(self.look(ws))
    let kept = self.kept[ws]
    // Their versions this station has not: fetched, a batch at a time.
    let maybe : Array[(String, Double)] = []
    for path in js_keys(theirs) {
      let r = theirs[path]
      let mine = kept.files.get(path)
      if rec_hash(r) == "" {
        continue
      }
      if mine is Some(m) && (rec_hash(m) == rec_hash(r) || rec_prev(m).contains(rec_hash(r))) {
        continue
      }
      maybe.push((rec_hash(r), rec_num(r, "size")))
      // Made beside this station's: the version both came from too, where this station keeps it not.
      if mine is Some(m) && rec_hash(m) != "" && !rec_prev(r).contains(rec_hash(m)) {
        let theirs_had = history_of(r)
        for h in history_of(m) {
          if theirs_had.contains(h) {
            maybe.push((h, rec_num(r, "size")))
            break
          }
        }
      }
    }
    // (which of them blobs/ keeps, the program says: none of their bytes read here)
    let have = if maybe.is_empty() {
      []
    } else {
      match get(Some(self.program.ask("have", [("blobs", jstr(self.blobs_dir())), ("hashes", jstrs(maybe.map(m => m.0)))])), "have") {
        Some(Array(a)) => a
        _ => []
      }
    }
    let wanted : Array[(String, Double)] = []
    for i, m in maybe {
      if !(have.get(i) is Some(True)) {
        wanted.push(m)
      }
    }
    let given : Map[String, Bytes] = Map([])
    let mut i = 0
    while i < wanted.length() {
      let batch : Array[String] = []
      let mut bytes = 0.0
      while i < wanted.length() && (batch.is_empty() || bytes + wanted[i].1 <= batch_bytes) {
        bytes += wanted[i].1
        batch.push(wanted[i].0)
        i += 1
      }
      let blobs = (self.deps.ask)(peer, ws, jobj([("method", jstr("memory.blobs")), ("hashes", jstrs(batch))]))
      if get(Some(blobs), "blobs") is Some(Object(bs)) {
        for h in js_keys(bs) {
          let b = base64_loose(js_string(Some(bs[h])))
          if @memory.sha256_hex(b) == h {
            given[h] = b
          }
        }
      }
    }
    ignore(self.take(ws, theirs, given))
  })
  // What it lacks of this station's, given it.
  let kept = self.kept[ws]
  let give : Array[(String, Json)] = []
  for path in js_keys(kept.files) {
    let r = kept.files[path]
    let t = theirs.get(path)
    let has = match t {
      Some(x) => rec_hash(x) == rec_hash(r) || rec_prev(x).contains(rec_hash(r))
      None => false
    }
    if !has {
      give.push((path, r))
    }
  }
  let mut i = 0
  while i < give.length() {
    let files : Map[String, Json] = Map([])
    let blobs : Map[String, Json] = Map([])
    let mut bytes = 0.0
    while i < give.length() && (files.is_empty() || bytes + rec_num(give[i].1, "size") <= batch_bytes) {
      let (path, r) = give[i]
      i += 1
      let c = if rec_hash(r) == "" { None } else { self.content(rec_hash(r)) }
      if rec_hash(r) != "" && c is None {
        continue
      }
      files[path] = r
      if c is Some(b) {
        blobs[rec_hash(r)] = jstr(base64_of(b))
        bytes += b.length().to_double()
      }
    }
    if !files.is_empty() {
      ignore((self.deps.ask)(peer, ws, jobj([("method", jstr("memory.put")), ("files", Json::object(files)), ("blobs", Json::object(blobs))])))
    }
  }
}

///|
/// What `ws`'s records are, as a word that changes when any of them does.
fn MemorySync::word(self : MemorySync, ws : String) -> String {
  let pairs : Array[(String, String)] = []
  match self.kept.get(ws) {
    Some(k) =>
      for p in js_keys(k.files) {
        pairs.push((p, rec_hash(k.files[p])))
      }
    None => ()
  }
  // (`.sort()` of [path, hash] pairs: by their text, "path,hash")
  pairs.sort_by((a, b) => {
    let x = "\{a.0},\{a.1}"
    let y = "\{b.0},\{b.1}"
    if x == y {
      0
    } else if @memory.js_after(x, y) {
      1
    } else {
      -1
    }
  })
  sha_text(js_stringify(jarr(pairs.map(p => jstrs([p.0, p.1])))))
}

///|
fn MemorySync::bring(self : MemorySync, peer : String, ws : String) -> Unit {
  let key = "\{ws}|\{peer}"
  let retry = self.retries.get(key)
  if self.going.contains(key) || (retry is Some((_, due, _)) && !due.val) {
    return
  }
  let at = self.word(ws)
  if self.level_at.get(key) == Some(at) && self.kept.contains(ws) {
    return
  }
  self.going.add(key)
  self.tasks.spawn(async fn() {
    defer {
      self.going.remove(key)
      if !self.stopped {
        self.look_all()
      }
    }
    try {
      self.level(peer, ws)
      self.level_at[key] = self.word(ws)
      self.retries.remove(key)
    } catch {
      e => {
        if before_memory(e) {
          self.level_at[key] = at
          self.retries.remove(key)
          return
        }
        self.deps.log.info("memory", "the memory was not brought level with a station", jobj([
          ("peer", jstr(js_slice(peer, 12))),
          ("workspace", jstr(ws)),
          ("error", jstr(error_words(e))),
        ]))
        if self.stopped {
          return
        }
        let wait = match retry {
          None => memory_retry_ms
          Some((w, _, _)) => if w * 2.0 < retry_most_ms { w * 2.0 } else { retry_most_ms }
        }
        let due = Ref(false)
        // timer: a retry after a failure, with a backoff
        let cancel = (self.deps.clock.after)(wait, () => {
          due.val = true
          self.look_all()
        })
        self.retries[key] = (wait, due, cancel)
      }
    }
  })
}

///|
/// Each workspace's files looked at, and each station of it brought level where it is not yet.
fn MemorySync::look_all(self : MemorySync) -> Unit {
  let cloud = self.deps.cloud
  // (a station that only runs tasks keeps no memory and asks nothing of the others)
  if self.stopped || self.deps.still || !(cloud.has_state)() || !(cloud.peers_current)() || (cloud.rig)() {
    return
  }
  self.follow()
  let me = (cloud.station)()
  for m in (cloud.memberships)() {
    let peers = m.peers.filter_map(p => match get(Some(p), "id") {
      Some(String(id)) if is_hex64(id) && Some(id) != me => Some(id)
      _ => None
    })
    if peers.is_empty() {
      continue
    }
    if !self.kept.contains(m.workspace) {
      let ws = m.workspace
      self.tasks.spawn(async fn() {
        try {
          ignore(self.lane(ws, async fn() { self.look(ws) }))
          self.look_all()
        } catch {
          e => self.deps.log.warn("memory", "the memory's files not read", jobj([("workspace", jstr(ws)), ("error", jstr(error_words(e)))]))
        }
      })
      continue
    }
    for p in peers {
      self.bring(p, m.workspace)
    }
  }
}

///|
/// `ws`'s files looked at again, then its stations brought level.
fn MemorySync::again(self : MemorySync, ws : String) -> Unit {
  self.tasks.spawn(async fn() {
    try {
      ignore(self.lane(ws, async fn() { self.look(ws) }))
      self.look_all()
    } catch {
      e => self.deps.log.warn("memory", "the memory's files not read", jobj([("workspace", jstr(ws)), ("error", jstr(error_words(e)))]))
    }
  })
}

///|
/// The agents' home watched: an edit in a workspace's memory, settled, is looked at.
fn MemorySync::follow(self : MemorySync) -> Unit {
  let root = (self.deps.agent_home)()
  if self.tree is Some((r, _)) && r == root {
    return
  }
  if self.tree is Some((_, t)) {
    (t.close)()
  }
  if self.follow_retry is Some((_, _, cancel)) {
    cancel()
  }
  self.follow_retry = None
  let tree = (self.deps.watching.tree)(root, memory_followed, follow_most, rel => self.changed(rel), e => {
    self.deps.log.warn("memory", "the agents' home no longer followed", jobj([("error", jstr(e))]))
    self.refollow()
  })
  self.tree = Some((root, tree))
  self.scan_tree()
}

///|
/// The directories followed found again (a directory made or gone, a retry).
fn MemorySync::scan_tree(self : MemorySync) -> Unit {
  guard self.tree is Some((_, tree)) && !self.stopped else { return }
  self.tasks.spawn(async fn() {
    let failed = (tree.scan)()
    guard self.tree is Some((_, now)) && physical_equal(now, tree) && !self.stopped else { return }
    match failed {
      None => if self.follow_retry is Some((_, due, _)) && due.val { self.follow_retry = None }
      Some(e) => {
        self.deps.log.warn("memory", "the agents' home cannot be followed", jobj([("error", jstr(e))]))
        self.refollow()
      }
    }
  })
}

///|
/// A scan again after a watch failed, twice as long each time up to RETRY_MOST_MS.
fn MemorySync::refollow(self : MemorySync) -> Unit {
  if self.stopped {
    return
  }
  let was = self.follow_retry
  if was is Some((_, due, _)) && !due.val {
    return
  }
  let wait = match was {
    None => memory_retry_ms
    Some((w, _, _)) => if w * 2.0 < retry_most_ms { w * 2.0 } else { retry_most_ms }
  }
  let due = Ref(false)
  // timer: a retry after a failure, with a backoff
  let cancel = (self.deps.clock.after)(wait, () => {
    due.val = true
    self.scan_tree()
  })
  self.follow_retry = Some((wait, due, cancel))
}

///|
/// What changed at `rel` of the agents' home: an edit of a workspace's memory looked at once it settled.
fn MemorySync::changed(self : MemorySync, rel : String) -> Unit {
  let parts = rel.split("/").map(x => x.to_string()).collect()
  let in_ws = parts[0] == "workspaces"
  let ws = if in_ws { parts.get(1) } else { (self.deps.cloud.home)() }
  let what = if in_ws { parts.get(2) } else { Some(parts[0]) }
  // workspaces/<id> made: followed from now on
  if in_ws && parts.length() <= 2 {
    self.settle_scan()
    return
  }
  guard ws is Some(w) && w != "" && what is Some("MEMORY.md" | "skills") else { return }
  if self.settle.get(w) is Some(off) {
    off()
  }
  // timer: a debounce of a burst
  self.settle[w] = (self.deps.clock.after)(settle_ms, () => {
    self.settle.remove(w)
    self.scan_tree()
    self.again(w)
  })
}

///|
fn MemorySync::settle_scan(self : MemorySync) -> Unit {
  if self.settle.get("") is Some(off) {
    off()
  }
  // timer: a debounce of a burst
  self.settle[""] = (self.deps.clock.after)(settle_ms, () => {
    self.settle.remove("")
    self.scan_tree()
  })
}

///|
/// Followed from now on: the files, the rosters (a station come, one back).
pub fn MemorySync::start(self : MemorySync) -> Unit {
  self.stops.push((self.deps.cloud.listen)(() => self.look_all()))
  self.look_all()
}

///|
pub async fn MemorySync::stop(self : MemorySync) -> Unit {
  self.stopped = true
  for s in self.stops {
    s()
  }
  if self.tree is Some((_, t)) {
    (t.close)()
  }
  if self.follow_retry is Some((_, _, cancel)) {
    cancel()
  }
  for _, r in self.retries {
    (r.2)()
  }
  for _, off in self.settle {
    off()
  }
  self.written()
  self.program.close()
}

///|
/// Each workspace's files looked at and each station of it brought level, one after another (tests); a station that
/// cannot be reached is passed over.
pub async fn MemorySync::level_now(self : MemorySync) -> Unit {
  for m in (self.deps.cloud.memberships)() {
    let ws = m.workspace
    ignore(self.lane(ws, async fn() { self.look(ws) }))
    for p in m.peers {
      guard get(Some(p), "id") is Some(String(id)) && id != self.me() else { continue }
      self.level(id, ws) catch {
        e => {
          let words = error_words(e)
          if !before_memory(e) && !words.contains("unavailable") && !words.contains("not reached") {
            raise e
          }
        }
      }
    }
  }
  self.written()
}

///|
/// The records kept of a workspace, as its file holds them (tests).
pub fn MemorySync::kept_json(self : MemorySync, ws : String) -> Json? {
  match self.kept.get(ws) {
    Some(k) => Some(k.json())
    None => None
  }
}

// ── a skill kept apart ──

///|
/// Whether `c` ends a line as JavaScript's `$` and `.` see it.
fn line_end(c : Char) -> Bool {
  c == '\n' || c == '\r' || c == '\u{2028}' || c == '\u{2029}'
}

///|
/// What `\s` matches.
fn js_ws(c : Char) -> Bool {
  js_space(c)
}

///|
/// Where the first line of `body` starting with `prefix` begins (`/^prefix/m`).
fn line_with(body : Array[Char], prefix : String) -> Int? {
  let pre = prefix.to_array()
  for i in 0..<body.length() {
    if i != 0 && !line_end(body[i - 1]) {
      continue
    }
    if i + pre.length() <= body.length() && body[i:i + pre.length()].to_array() == pre {
      return Some(i)
    }
  }
  None
}

///|
/// A skill's SKILL.md as it is kept aside under `name`, of `station` (memory.ts `asideSkill`).
pub fn aside_skill(content : Bytes, name : String, station : String) -> Bytes {
  let text = @utf8.decode_lossy(content)
  let own = "description: [\{station}] \{station}'s own, kept apart from another station's skill of the same name"
  // /^---\n([\s\S]*?)\n---/
  let front_end = if text.has_prefix("---\n") {
    let cs = text.to_array()
    let mut found : Int? = None
    let mut k = 4
    while k + 4 <= cs.length() {
      if cs[k] == '\n' && cs[k + 1] == '-' && cs[k + 2] == '-' && cs[k + 3] == '-' {
        found = Some(k)
        break
      }
      k += 1
    }
    found
  } else {
    None
  }
  guard front_end is Some(end) else {
    return @utf8.encode("---\nname: \{name}\n\{own}\n---\n\n\{text}")
  }
  let cs = text.to_array()
  let mut body = cs[4:end].to_array()
  match line_with(body, "name:") {
    Some(at) => {
      let mut stop = at
      while stop < body.length() && !line_end(body[stop]) {
        stop += 1
      }
      body = body[0:at].to_array() + "name: \{name}".to_array() + body[stop:].to_array()
    }
    None => body = "name: \{name}\n".to_array() + body
  }
  match line_with(body, "description:") {
    Some(at) => {
      let mut stop = at + 12
      while stop < body.length() && js_ws(body[stop]) {
        stop += 1
      }
      body = body[0:at].to_array() + "description: [\{station}] ".to_array() + body[stop:].to_array()
    }
    None => body = body + "\n\{own}".to_array()
  }
  let rest = cs[end + 4:].to_array()
  @utf8.encode("---\n" + String::from_array(body) + "\n---" + String::from_array(rest))
}
