// The agents' home (station/src/sessions/agent-home.ts): one MEMORY.md and one skills/ directory used by every profile
// of every runtime, in the data directory; a joined workspace has its own beside it (`workspaces/<ws>`). A session is
// given its workspace's: the skills linked where it runs. The station's own skills are written into each at start,
// their text read from the station's skills (`skills_source`: src/skills, or dist/skills bundled). Each runtime's
// transcripts are kept in one shared place, each profile home's transcript directory a link there.

///|
pub fn Files::agent_home_paths(self : Files, agent_home : String) -> (String, String) {
  (self.join([agent_home, "MEMORY.md"]), self.join([agent_home, "skills"]))
}

///|
fn ws_id_ok(ws : String) -> Bool {
  ws.length() >= 1 && ws.length() <= 128 && ws.iter().all(c => alnum(c) || c == '_' || c == '-')
}

///|
/// Where the agent home of workspace `ws` is, nothing looked at on the disk.
pub fn Files::workspace_agent_home_path(self : Files, agent_home : String, ws : String?, home : String?) -> String raise Thrown {
  match (ws, home) {
    (Some(w), Some(h)) if w != h => {
      if !ws_id_ok(w) {
        raise failed("not a workspace id: \{quoted(w)}")
      }
      self.join([agent_home, "workspaces", w])
    }
    _ => agent_home
  }
}

///|
pub let builtin_skills : Array[String] = [
  "stillfail-chats", "stillfail-jobs", "stillfail-show", "stillfail-viz", "stillfail-browser", "stillfail-login", "stillfail-vault",
  "stillfail-cron", "stillfail-github-ci", "stillfail-move", "stillfail-leading",
]

///|
/// `RETIRED_SKILLS`: brought before and no longer (stillfail-retire: station_retire is off and hidden). A copy left
/// untouched is taken away at every start; the shared memory still counts them the station's own.
pub let retired_skills : Array[String] = ["stillfail-retire"]

///|
pub let feedback_skill = "stillfail-feedback"

///|
/// `MOVE_SKILL`: written only where moving is on.
pub let move_skill = "stillfail-move"

///|
/// The agent home of workspace `ws`, a joined one's made when it is missing: its MEMORY.md and skills/, the station's
/// own skills in it as the home workspace has them.
pub async fn Storage::workspace_agent_home(self : Storage, agent_home : String, ws : String?, home : String?, skills_source : String, site : String?) -> String {
  let fs = self.fs
  let dir = fs.workspace_agent_home_path(agent_home, ws, home)
  if dir == agent_home {
    return dir
  }
  let (memory, skills) = fs.agent_home_paths(dir)
  let has_skills = fs.there(skills)
  let has_memory = fs.there(memory)
  if has_skills && has_memory {
    return dir
  }
  fs.mkdirs(skills)
  let shared = fs.agent_home_paths(agent_home).1
  let feedback = fs.there(fs.join([shared, feedback_skill]))
  self.write_builtin_skills(dir, feedback, skills_source, site, move=fs.there(fs.join([shared, move_skill])))
  if !has_memory {
    fs.write_text(memory, "# still.fail memory\n", exclusive=true) catch {
      e => if code_of(e) != "EEXIST" && fs.lkind(memory) is None { raise e }
    }
  }
  dir
}

///|
/// The agent home and those of the workspaces the station joined (made so far).
pub async fn Files::agent_homes(self : Files, agent_home : String) -> Array[String] {
  let out = [agent_home]
  for ws in self.entries(self.join([agent_home, "workspaces"])) {
    let at = self.join([agent_home, "workspaces", ws])
    if self.lkind(at) is Some("dir") {
      out.push(at)
    }
  }
  out
}

///|
/// Whether a directory holds nothing but the SKILL.md the station wrote.
async fn Files::only_skill(self : Files, dir : String) -> Bool {
  if !(self.lkind(dir) is Some("dir")) {
    return false
  }
  match self.readdir(dir) {
    Some(names) => names.iter().all(e => e == "SKILL.md")
    None => false
  }
}

///|
/// Writes the station's own skills into the shared skills directory (agent-home.ts `writeBuiltinSkills`).
/// `move`: stillfail-move too (else taken away, as stillfail-feedback is). The retired skills are taken away so, always.
pub async fn Storage::write_builtin_skills(
  self : Storage,
  agent_home : String,
  feedback : Bool,
  skills_source : String,
  site : String?,
  move? : Bool = true,
) -> Unit {
  let fs = self.fs
  let (_, skills) = fs.agent_home_paths(agent_home)
  match site {
    Some(s) => self.link_site_skills(skills, s)
    None => ()
  }
  if !feedback && fs.only_skill(fs.join([skills, feedback_skill])) {
    fs.rm(fs.join([skills, feedback_skill]), recursive=true, force=true)
  }
  if !move && fs.only_skill(fs.join([skills, move_skill])) {
    fs.rm(fs.join([skills, move_skill]), recursive=true, force=true)
  }
  for name in retired_skills {
    if fs.only_skill(fs.join([skills, name])) {
      fs.rm(fs.join([skills, name]), recursive=true, force=true)
    }
  }
  let names = builtin_skills.filter(n => move || n != move_skill)
  if feedback {
    names.push(feedback_skill)
  }
  for name in names {
    guard fs.read_bytes(fs.join([skills_source, "\{name}.md"])) is Some(text) else {
      raise fs_failed("ENOENT", "open", fs.join([skills_source, "\{name}.md"]))
    }
    let source_dir = fs.join([skills_source, name])
    let files = []
    for file in fs.entries(source_dir) {
      match fs.read_bytes(fs.join([source_dir, file])) {
        Some(b) => files.push((file, b))
        None => raise fs_failed("EISDIR", "read", fs.join([source_dir, file]))
      }
    }
    let dir = fs.join([skills, name])
    fs.mkdirs(dir)
    let path = fs.join([dir, "SKILL.md"])
    // (as read in UTF-8 and compared as text)
    if fs.read_text(path) != Some(@utf8.decode_lossy(text)) {
      fs.write(path, text)
    }
    for pair in files {
      let (file, body) = pair
      let at = fs.join([dir, file])
      if fs.read_bytes(at) != Some(body) {
        fs.write(at, body, mode=0o755)
      }
    }
  }
}

///|
/// Links each of the deployment's skills (the entries of directory `site`) into `skills` (agent-home.ts
/// `linkSiteSkills`).
pub async fn Storage::link_site_skills(self : Storage, skills : String, site : String) -> Unit {
  let fs = self.fs
  let names = fs.entries(site).filter(n => !n.has_prefix("."))
  fs.mkdirs(skills)
  for entry in fs.entries(skills) {
    if !names.contains(entry) && fs.links_into(fs.join([skills, entry]), site) {
      fs.rm(fs.join([skills, entry]), force=true)
    }
  }
  for name in names {
    let at = fs.join([skills, name])
    let target = fs.join([site, name])
    if fs.links_to(at, target) {
      continue
    }
    if fs.lkind(at) is Some(_) {
      if !self.left_alone.contains(at) {
        self.log("warn", "agent_home", "a team's skill has the name of one the deployment brings: the team's kept", jo([("skill", js(name)), ("path", js(at))]))
      }
      self.left_alone.add(at)
      continue
    }
    ignore(fs.link(target, at))
  }
}

///|
/// Whether `path` is a link to `target`, however either is spelled.
async fn Files::links_to(self : Files, path : String, target : String) -> Bool {
  if !(self.lkind(path) is Some("link")) {
    return false
  }
  if self.readlink(path) == Some(target) {
    return true
  }
  match (self.realpath(path), self.realpath(target)) {
    (Some(a), Some(b)) => a == b
    _ => false
  }
}

///|
/// Whether `path` is a link to something in directory `dir`, however either is spelled.
async fn Files::links_into(self : Files, path : String, dir : String) -> Bool {
  if !(self.lkind(path) is Some("link")) {
    return false
  }
  guard self.readlink(path) is Some(l) else { return false }
  if self.dirname(l) == dir {
    return true
  }
  match (self.realpath(path), self.realpath(dir)) {
    (Some(a), Some(b)) => self.dirname(a) == b
    _ => false
  }
}

///|
/// A profile's home: its id, its runtimes, where it is.
pub(all) struct ProfileHome {
  id : String
  runtimes : Array[String]
  home : String
}

///|
/// Takes away what stations before this one linked into every profile home (agent-home.ts `unlinkAgentHome`).
pub async fn Files::unlink_agent_home(self : Files, agent_home : String, profiles : Array[ProfileHome]) -> Unit {
  let (memory, skills) = self.agent_home_paths(agent_home)
  for p in profiles {
    for name in ["CLAUDE.md", "AGENTS.md", self.join(["grok", "AGENTS.md"])] {
      if self.links_to(self.join([p.home, name]), memory) {
        self.rm(self.join([p.home, name]), force=true)
      }
    }
    for dir in ["skills", self.join(["hermes", "skills"]), self.join(["grok", "skills"])] {
      let path = self.join([p.home, dir])
      if self.links_to(path, skills) {
        self.rm(path, force=true)
      } else {
        for entry in self.entries(path) {
          if self.links_into(self.join([path, entry]), skills) {
            self.rm(self.join([path, entry]), force=true)
          }
        }
      }
    }
  }
}

///|
pub fn Files::skill_homes(self : Files) -> Array[String] {
  [self.join([".claude", "skills"]), self.join([".agents", "skills"])]
}

///|
/// Links the skills of a session's workspace (`skills`) into the directory it runs in (agent-home.ts `sessionSkills`).
pub async fn Files::session_skills(self : Files, workspace : String, skills : String) -> Unit {
  let names = []
  for name in self.entries(skills) {
    if self.there(self.join([skills, name, "SKILL.md"])) {
      names.push(name)
    }
  }
  for home in self.skill_homes() {
    let dir = self.join([workspace, home])
    for entry in self.entries(dir) {
      if !names.contains(entry) && self.links_into(self.join([dir, entry]), skills) {
        self.rm(self.join([dir, entry]), force=true)
      }
    }
    if names.length() == 0 {
      continue
    }
    self.mkdirs(dir)
    for name in names {
      let at = self.join([dir, name])
      if !self.there(at) && self.lkind(at) is None {
        ignore(self.link(self.join([skills, name]), at))
      }
    }
  }
}

///|
pub let runtime_kinds : Array[String] = ["claude", "codex", "dsh", "grok", "cursor", "devin", "hermes", "agy", "pi"]

///|
/// read/transcript.ts `transcriptDir`.
pub fn Files::transcript_dir(self : Files, runtime : String) -> String {
  match runtime {
    "claude" => "projects"
    "codex" => "sessions"
    "grok" => self.join(["grok", "sessions"])
    "cursor" => self.join(["cursor", "sessions"])
    "devin" => self.join(["devin", "sessions"])
    "hermes" => self.join(["hermes", "sessions"])
    "agy" => self.join(["agy", "sessions"])
    "pi" => self.join(["pi", "sessions"])
    _ => "dsh-sessions"
  }
}

///|
pub fn Files::shared_transcripts(self : Files, data_dir : String, runtime : String) -> String {
  self.join([data_dir, "transcripts", runtime])
}

///|
/// Each profile home's transcript directory made a link to the one shared place (agent-home.ts `linkTranscripts`).
pub async fn Storage::link_transcripts(self : Storage, data_dir : String, profiles : Array[ProfileHome]) -> Unit {
  let fs = self.fs
  let data = fs.canonical(data_dir)
  for p in profiles {
    fs.mkdirs(p.home)
    let in_data = fs.within(fs.canonical(p.home), data)
    for runtime in p.runtimes {
      self.share(fs.join([p.home, fs.transcript_dir(runtime)]), fs.shared_transcripts(data_dir, runtime), in_data, p.id)
    }
  }
  let named = Set::new()
  for p in profiles {
    named.add(fs.canonical(p.home))
  }
  let homes = fs.join([data_dir, "homes"])
  for name in fs.entries(homes) {
    let home = fs.join([homes, name])
    if named.contains(fs.canonical(home)) || !(fs.lkind(home) is Some("dir")) {
      continue
    }
    for runtime in runtime_kinds {
      let dir = fs.join([home, fs.transcript_dir(runtime)])
      if !(fs.lkind(dir) is Some("dir")) {
        continue
      }
      if runtime == "codex" && !fs.some_dir(dir) {
        continue
      }
      self.share(dir, fs.shared_transcripts(data_dir, runtime), true, name)
    }
  }
}

///|
async fn Files::some_dir(self : Files, dir : String) -> Bool {
  for e in self.entries(dir) {
    if self.lkind(self.join([dir, e])) is Some("dir") {
      return true
    }
  }
  false
}

///|
/// Makes transcript directory `dir` (of profile `of`'s home) a link to the shared place `shared` (agent-home.ts `share`).
async fn Storage::share(self : Storage, dir : String, shared : String, gathers : Bool, of : String) -> Unit {
  let fs = self.fs
  fs.mkdirs(shared)
  fs.mkdirs(fs.dirname(dir))
  for _ in 0..<3 {
    let meta = fs.lkind(dir)
    guard meta is Some(kind) else {
      if fs.link_dir(shared, dir) {
        return
      }
      continue
    }
    if fs.links_to(dir, shared) {
      return
    }
    if !gathers || kind != "dir" {
      if !self.left_alone.contains(dir) {
        self.log("warn", "agent_home", "a profile's transcripts are not in the shared place", jo([("profile", js(of)), ("path", js(dir))]))
      }
      self.left_alone.add(dir)
      return
    }
    ignore(fs.gather(dir, shared, [], Set::new()))
    let mut aside = "\{dir}.unshared"
    let mut n = 2
    while fs.lkind(aside) is Some(_) {
      aside = "\{dir}.unshared-\{n}"
      n += 1
    }
    fs.rename(dir, aside) catch {
      e => {
        self.log("warn", "agent_home", "a home's transcripts not moved to the shared place", jo([("profile", js(of)), ("path", js(dir)), ("error", js(message_of(e)))]))
        return
      }
    }
    let made = fs.link_dir(shared, dir) catch {
      e => {
        fs.rename(aside, dir)
        raise e
      }
    }
    let left = fs.gather(aside, shared, [], Set::new())
    if left.length() == 0 {
      fs.rm(aside, recursive=true, force=true)
    } else {
      self.log("warn", "agent_home", "transcripts kept aside: the shared place has others of the same names", jo([("profile", js(of)), ("path", js(aside)), ("files", ji(left.length())), ("first", js(left[0]))]))
    }
    if made {
      self.log("info", "agent_home", "a home's transcripts moved to the shared place", jo([("profile", js(of)), ("path", js(dir))]))
      return
    }
  }
}

///|
/// `path` made a link to directory `target`; false when something is there first.
async fn Files::link_dir(self : Files, target : String, path : String) -> Bool {
  try ignore(self.link(target, path)) catch {
    e => {
      if code_of(e) == "EEXIST" {
        return false
      }
      raise e
    }
  }
  true
}

///|
/// Every file under `from` put at the same place under `to` as well (agent-home.ts `gather`): the files left out.
async fn Files::gather(self : Files, from : String, to : String, left : Array[String], seen : Set[String]) -> Array[String] {
  for name in self.entries(from) {
    let path = self.join([from, name])
    let there = self.join([to, name])
    let step = try {
      guard self.realpath(path) is Some(real) else { raise fs_failed("ENOENT", "realpath", path) }
      guard self.stat(real) is Some(st) else { raise fs_failed("ENOENT", "stat", real) }
      if st.kind == "dir" {
        if seen.contains(real) || real == self.canonical(there) {
          ()
        } else {
          seen.add(real)
          self.mkdirs(there)
          ignore(self.gather(real, there, left, seen))
        }
      } else {
        let other = self.stat(there)
        if st.kind != "file" {
          left.push(path)
        } else {
          match other {
            None => self.hard_link(real, there)
            Some(o) =>
              if o.dev == st.dev && o.ino == st.ino {
                ()
              } else if st.size > o.size && self.begins(real, there, o.size) {
                let next = "\{there}.\{@host.pid()}.sharing"
                self.rm(next, force=true)
                self.hard_link(real, next)
                self.rename(next, there)
              } else if !(o.size >= st.size && self.begins(there, real, st.size)) {
                left.push(path)
              }
          }
        }
      }
    } catch {
      _ => left.push(path)
    }
    ignore(step)
  }
  left
}

///|
/// Whether file `a` begins with the first `n` bytes of file `b`, read a piece at a time.
async fn Files::begins(self : Files, a : String, b : String, n : Double) -> Bool {
  let piece = 1048576.0
  let mut at = 0.0
  while at < n {
    let want = if n - at < piece { n - at } else { piece }
    let ra = self.read_range(a, at, want)
    let rb = self.read_range(b, at, want)
    if ra.length().to_double() != want || rb.length().to_double() != want || ra != rb {
      return false
    }
    at += want
  }
  true
}
