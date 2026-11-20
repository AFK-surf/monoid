// Repositories cloned from git into the station's repository cache (station/src/sessions/clones.ts), so a preset can
// name them: the clone runs in the background into a dot-named directory (`.cloning-<id>`) and comes into the cache
// whole once it is done. What is under way and what failed is kept in memory by workspace, every change told
// (`changed`). git itself is the station's to run (`clones.run`: no terminal prompt, ssh in batch mode, no `ext::` or
// `file:` transport, the address after `--`, a deadline; `clones.kill` stops it). An address's name and password are
// used for the clone and kept nowhere.

///|
pub let clone_most_ms : Double = 30.0 * 60.0 * 1000.0

///|
let kept_most = 20

///|
let error_most = 300

///|
let temp_prefix = ".cloning-"

///|
/// A clone under way or failed, as GET /presets lists it.
pub struct Clone {
  id : String
  url : String
  repo : String
  name : String
  mut state : String
  mut error : String?
  by : String
  started_at : Double
  mut running : Bool
  mut dropped : Bool
  changed : async () -> Unit
}

///|
pub fn Clone::shown(self : Clone) -> Json {
  let fields = [("id", js(self.id)), ("url", js(self.url)), ("repo", js(self.repo)), ("name", js(self.name)), ("state", js(self.state))]
  if self.error is Some(e) {
    fields.push(("error", js(e)))
  }
  fields.push(("by", js(self.by)))
  fields.push(("startedAt", jn(self.started_at)))
  jo(fields)
}

///|
fn part_ok(p : String) -> Bool {
  all_of(p, c => alnum(c) || c == '.' || c == '_' || c == '-') && !all_of(p, c => c == '.')
}

///|
fn no_clone_url() -> Thrown {
  Thrown("NoCloneUrl", jo([("message", js("not a git address that can be cloned"))]))
}

///|
/// The address `given` is cloned from: http(s), ssh, git, scp's `user@host:path`, or `owner/name` (GitHub's).
pub fn clone_url(given : Json?) -> String raise Thrown {
  let url = match given {
    Some(String(s)) => js_trim(s)
    _ => ""
  }
  if url == "" || url.has_prefix("-") || url.iter().any(c => js_space(c) || c.to_int() < 0x20 || c.to_int() == 0x7f) {
    raise no_clone_url()
  }
  let parts = url.split("/").map(p => p.to_string()).to_array()
  if parts.length() == 2 && parts.iter().all(part_ok) {
    let name = if parts[1].has_suffix(".git") { cut(parts[1], 0, end=parts[1].length() - 4) } else { parts[1] }
    return "https://github.com/\{parts[0]}/\{name}.git"
  }
  let low = url.to_lower()
  let scheme = ["https://", "http://", "ssh://", "git://"].iter().find_first(s => low.has_prefix(s))
  match scheme {
    Some(s) => {
      let rest = cut(url, s.length())
      let end = stop_at(rest, c => c == '/' || c == '?' || c == '#')
      if end > 0 && end < rest.length() && rest.unsafe_charcode_at(end) == '/' && end + 1 < rest.length() {
        let raw = cut(rest, 0, end=end)
        let host = match raw.find("@") {
          Some(at) => cut(raw, at + 1)
          None => raw
        }
        if host == "" || host.has_prefix("-") {
          raise no_clone_url()
        }
        return url
      }
    }
    None => ()
  }
  // (scp's: a user, a host, a path after one colon)
  match url.find("@") {
    Some(at) => {
      let user = cut(url, 0, end=at)
      let rest = cut(url, at + 1)
      match rest.find(":") {
        Some(colon) => {
          let host = cut(rest, 0, end=colon)
          let path = cut(rest, colon + 1)
          let user_ok = all_of(user, c => alnum(c) || c == '.' || c == '_' || c == '-')
          let host_ok = host != "" && alnum(host.to_array()[0]) && all_of(host, c => alnum(c) || c == '.' || c == '-')
          if user_ok && host_ok && path != "" && !path.has_prefix(":") {
            return url
          }
        }
        None => ()
      }
    }
    None => ()
  }
  raise no_clone_url()
}

///|
fn scheme_char(c : Char) -> Bool {
  alnum(c) || c == '+' || c == '.' || c == '-'
}

///|
fn letter(c : Char) -> Bool {
  (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
}

///|
/// `url` without a password in it, and an http address without its name either.
pub fn safe_url(url : String) -> String {
  let low = url.to_lower()
  let mut u = url
  for s in ["https://", "http://"] {
    if low.has_prefix(s) {
      let rest = cut(url, s.length())
      let end = stop_at(rest, c => c == '/' || c == '@')
      if end < rest.length() && rest.unsafe_charcode_at(end) == '@' {
        u = cut(url, 0, end=s.length()) + cut(rest, end + 1)
      }
      break
    }
  }
  // ^([a-z][a-z0-9+.-]*:\/\/[^/:@]*):[^/@]*@  →  $1@
  let c = u.to_array()
  if c.length() > 0 && letter(c[0]) {
    let mut i = 1
    while i < c.length() && scheme_char(c[i]) {
      i += 1
    }
    let s = String::from_array(c[i:].to_array())
    if s.has_prefix("://") {
      let rest = cut(s, 3)
      let name_end = stop_at(rest, ch => ch == '/' || ch == ':' || ch == '@')
      if name_end < rest.length() && rest.unsafe_charcode_at(name_end) == ':' {
        let after = cut(rest, name_end + 1)
        let pass_end = stop_at(after, ch => ch == '/' || ch == '@')
        if pass_end < after.length() && after.unsafe_charcode_at(pass_end) == '@' {
          return String::from_array(c[:i].to_array()) + "://" + cut(rest, 0, end=name_end) + "@" + cut(after, pass_end + 1)
        }
      }
    }
  }
  u
}

///|
/// `text` with no address's name and password in it.
fn scrubbed(text : String) -> String {
  let c = text.to_array()
  let n = c.length()
  let out = StringBuilder::new()
  let mut i = 0
  while i < n {
    if letter(c[i]) {
      let mut j = i + 1
      while j < n && scheme_char(c[j]) {
        j += 1
      }
      if j + 2 < n && c[j] == ':' && c[j + 1] == '/' && c[j + 2] == '/' {
        let k = j + 3
        let mut m = k
        while m < n && !(js_space(c[m]) || c[m] == '/' || c[m] == '@') {
          m += 1
        }
        if m > k && m < n && c[m] == '@' {
          for x in c[i:k] {
            out.write_char(x)
          }
          i = m + 1
          continue
        }
      }
    }
    out.write_char(c[i])
    i += 1
  }
  out.to_string()
}

///|
/// What a failed clone says: git's last lines that say something, at most `error_most` characters.
fn error_of(stderr : String) -> String {
  let lines = []
  let line = StringBuilder::new()
  let s = scrubbed(stderr).to_array()
  let mut i = 0
  while i <= s.length() {
    if i == s.length() || s[i] == '\n' || s[i] == '\r' {
      let t = js_trim(line.to_string())
      if t != "" {
        lines.push(t)
      }
      line.reset()
      if i < s.length() && s[i] == '\r' && i + 1 < s.length() && s[i + 1] == '\n' {
        i += 1
      }
    } else {
      line.write_char(s[i])
    }
    i += 1
  }
  let mut out = ""
  let mut at = lines.length() - 1
  while at >= 0 {
    let next = if out == "" { lines[at] } else { "\{lines[at]}\n\{out}" }
    if next.length() > error_most {
      if out == "" {
        out = cut(lines[at], lines[at].length() - error_most)
      }
      break
    }
    out = next
    at -= 1
  }
  if out == "" {
    "git clone failed"
  } else {
    out
  }
}

///|
/// A directory's name for a part of repository `repo`, as a name the cache shows.
fn dir_name(part : String) -> String {
  let b = StringBuilder::new()
  for i in 0..<part.length() {
    let u = part.unsafe_charcode_at(i)
    let ok = (u >= 'A' && u <= 'Z') || (u >= 'a' && u <= 'z') || (u >= '0' && u <= '9') || u == '.' || u == '_' || u == '-'
    b.write_char(if ok { Int::unsafe_to_char(u) } else { '-' })
  }
  let mut name = b.to_string()
  while name.has_prefix(".") {
    name = cut(name, 1)
  }
  if name == "" {
    "repo"
  } else {
    name
  }
}

///|
/// presets.ts `repoName`: `host/owner/name` of an address.
pub fn repo_name(url : String) -> String {
  let mut u = js_trim(url)
  if u.has_suffix(".git") {
    u = cut(u, 0, end=u.length() - 4)
  }
  while u.has_suffix("/") {
    u = cut(u, 0, end=u.length() - 1)
  }
  // ^[^@/]+@([^:/]+):(.+)$
  match u.find("@") {
    Some(at) if at > 0 && !cut(u, 0, end=at).contains("/") => {
      let rest = cut(u, at + 1)
      let host_end = stop_at(rest, c => c == ':' || c == '/')
      if host_end > 0 && host_end < rest.length() && rest.unsafe_charcode_at(host_end) == ':' && host_end + 1 < rest.length() {
        return "\{cut(rest, 0, end=host_end)}/\{cut(rest, host_end + 1)}"
      }
    }
    _ => ()
  }
  // ^[a-z+]+:\/\/  then  ^[^@/]+@
  let c = u.to_array()
  let mut i = 0
  while i < c.length() && (letter(c[i]) || c[i] == '+') {
    i += 1
  }
  if i > 0 && String::from_array(c[i:].to_array()).has_prefix("://") {
    u = String::from_array(c[i + 3:].to_array())
  }
  match u.find("@") {
    Some(at) if at > 0 && !cut(u, 0, end=at).contains("/") => cut(u, at + 1)
    _ => u
  }
}

///|
/// presets.ts `originIn`: the repository a git config's origin names.
pub fn origin_in(config : String) -> String? {
  guard config.find("[remote \"origin\"]") is Some(at) else { return None }
  for line in cut(config, at).split("\n") {
    let t = js_trim(line.to_string())
    if t.has_prefix("url") {
      let rest = js_trim(cut(t, 3))
      if rest.has_prefix("=") {
        let url = js_trim(cut(rest, 1))
        return if url == "" { None } else { Some(repo_name(url)) }
      }
    }
  }
  None
}

///|
async fn Storage::repos_dir(self : Storage) -> String {
  as_str(Some(self.ask("clones.reposDir", []))).unwrap_or("")
}

///|
/// The clones under way and failed of workspace `ws`, newest first.
pub fn Storage::clones_list(self : Storage, ws : String?) -> Array[Json] {
  let all = self.clones.get(ws.unwrap_or("")).unwrap_or([])
  all.rev().map(c => c.shown())
}

///|
/// `given` cloned into the cache for workspace `ws` by `by`, answered at once.
pub async fn Storage::clones_start(self : Storage, ws : String?, given : Json?, by : String, changed : async () -> Unit) -> Json {
  let url = clone_url(given)
  let kept = safe_url(url)
  let repo = repo_name(kept)
  match self.repo_there(repo) {
    Some(path) => return jo([("state", js("there")), ("path", js(path)), ("repo", js(repo)), ("name", js(self.fs.basename(path)))])
    None => ()
  }
  let key = ws.unwrap_or("")
  let all = self.clones.get(key).unwrap_or([])
  match all.iter().find_first(c => c.repo == repo && c.state == "cloning") {
    Some(running) => return running.shown()
    None => ()
  }
  let rest = all.filter(c => c.repo != repo)
  while rest.length() >= kept_most {
    match rest.search_by(c => c.state == "failed") {
      Some(i) => ignore(rest.remove(i))
      None => break
    }
  }
  let parts = repo.split("/").map(p => p.to_string()).to_array()
  let clone : Clone = {
    id: "c-\{self.fs.random_hex(5)}",
    url: kept,
    repo,
    name: dir_name(parts.last().unwrap_or(repo)),
    state: "cloning",
    error: None,
    by,
    started_at: self.now(),
    running: false,
    dropped: false,
    changed,
  }
  rest.push(clone)
  self.clones[key] = rest
  self.log("info", "presets", "clone started", jo([("id", js(clone.id)), ("repo", js(repo)), ("by", js(by))]))
  changed()
  let owner = dir_name(if parts.length() >= 2 { parts[parts.length() - 2] } else { "" })
  let owner = if parts.length() >= 2 { owner } else { "" }
  self.track_going(
    self.fs.host.rt.fork(name="clone", async fn() {
      self.clone_run(clone, url, owner) catch {
        e => self.clone_failed(clone, message_of(e))
      }
    }),
  )
  clone.shown()
}

///|
/// Clone `id` of workspace `ws` forgotten, stopped first if it is under way; false for none.
pub async fn Storage::clones_drop(self : Storage, ws : String?, id : String) -> Bool {
  let key = ws.unwrap_or("")
  let all = self.clones.get(key).unwrap_or([])
  guard all.iter().find_first(c => c.id == id) is Some(clone) else { return false }
  self.clones[key] = all.filter(c => !physical_equal(c, clone))
  clone.dropped = true
  if clone.running {
    self.st.tell("clones.kill", [js(clone.id)])
  }
  self.log("info", "presets", if clone.state == "cloning" { "clone stopped" } else { "clone dropped" }, jo([("id", js(id)), ("repo", js(clone.repo))]))
  (clone.changed)()
  true
}

///|
/// Where the station has repository `repo` already: a clone in the cache, or one found on the machine.
async fn Storage::repo_there(self : Storage, repo : String) -> String? {
  let dir = self.repos_dir()
  for name in self.fs.entries(dir) {
    if name.has_prefix(".") {
      continue
    }
    let config = self.fs.read_text(self.fs.join([dir, name, ".git", "config"])).unwrap_or("")
    if config != "" && origin_in(config) == Some(repo) {
      return Some(self.fs.join([dir, name]))
    }
  }
  let found = items(Some(self.ask("clones.indexRepos", []))) catch { _ => [] }
  match found.iter().find_first(c => str(c, "repo") == Some(repo)) {
    Some(c) => str(c, "path")
    None => None
  }
}

///|
async fn Storage::clone_run(self : Storage, clone : Clone, url : String, owner : String) -> Unit {
  let dir = self.repos_dir()
  self.fs.mkdirs(dir)
  // (one sweep, every clone started meanwhile waiting for it)
  match self.swept {
    Some(done) => done.wait()
    None => {
      let done = @effect.Deferred::new()
      self.swept = Some(done)
      self.clones_sweep(dir)
      ignore(done.succeed(()))
    }
  }
  if clone.dropped {
    return
  }
  let temp = self.fs.join([dir, "\{temp_prefix}\{clone.id}"])
  let env = match self.ask("fn.startEnv", []) {
    Object(o) => o.copy()
    _ => Map::new()
  }
  env["GIT_TERMINAL_PROMPT"] = js("0")
  env["GIT_SSH_COMMAND"] = js("ssh -oBatchMode=yes -oStrictHostKeyChecking=accept-new")
  let args = ["-c", "protocol.ext.allow=never", "-c", "protocol.file.allow=never", "clone", "--quiet", "--", url, temp]
  clone.running = true
  let done = self.ask("clones.run", [js(clone.id), ja(args.map(a => js(a))), Json::object(env)])
  clone.running = false
  let ok = get(done, "ok") is Some(True)
  let stderr = str(done, "stderr").unwrap_or("")
  if !ok || clone.dropped {
    self.fs.rm(temp, recursive=true, force=true) catch { _ => () }
    if !clone.dropped {
      self.clone_failed(clone, stderr)
    }
    return
  }
  let path = self.clone_place(temp, dir, clone.name, owner) catch { _ => None }
  guard path is Some(path) else {
    self.fs.rm(temp, recursive=true, force=true) catch { _ => () }
    self.clone_failed(clone, "the clone could not be put in the repository cache")
    return
  }
  for key, all in self.clones {
    if all.iter().any(c => physical_equal(c, clone)) {
      self.clones[key] = all.filter(c => !physical_equal(c, clone))
    }
  }
  self.log("info", "presets", "clone done", jo([("id", js(clone.id)), ("repo", js(clone.repo)), ("path", js(path))]))
  (clone.changed)()
}

///|
/// `temp` moved to `dir/<name>`, or where that is taken `dir/<owner>-<name>`, then `-2`, `-3`…: where it went.
async fn Storage::clone_place(self : Storage, temp : String, dir : String, name : String, owner : String) -> String? {
  let base = if owner == "" { name } else { "\{owner}-\{name}" }
  for i in 0..<100 {
    let to = self.fs.join([dir, if i == 0 { name } else if i == 1 { base } else { "\{base}-\{i}" }])
    if self.fs.there(to) {
      continue
    }
    try self.fs.rename(temp, to) catch {
      e => {
        let code = code_of(e)
        if code != "EEXIST" && code != "ENOTEMPTY" {
          raise e
        }
        continue
      }
    }
    return Some(to)
  }
  None
}

///|
async fn Storage::clone_failed(self : Storage, clone : Clone, said : String) -> Unit {
  if clone.dropped || clone.state == "failed" {
    return
  }
  clone.state = "failed"
  clone.error = Some(error_of(said))
  self.log("info", "presets", "clone failed", jo([("id", js(clone.id)), ("repo", js(clone.repo)), ("error", jopt(clone.error))]))
  (clone.changed)()
}

///|
async fn Storage::clones_sweep(self : Storage, dir : String) -> Unit {
  let left = self.fs.entries(dir).filter(n => n.has_prefix(temp_prefix))
  for n in left {
    self.fs.rm(self.fs.join([dir, n]), recursive=true, force=true) catch { _ => () }
  }
  if left.length() > 0 {
    self.log("info", "presets", "unfinished clones removed", jo([("count", ji(left.length()))]))
  }
}
