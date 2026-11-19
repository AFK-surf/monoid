// The repos module (station/src/move/repos.ts; move/AGENTS.md): an item is one canonical clone in the repository
// cache that a chat's linked worktree hangs on, known by its remote (`repo:<url>`). Moved: there it is a clone of that
// remote, with what no remote has of it fetched from a bundle sent along (`move.repo.make`, `move.repo.bundle`, a told
// step there). Moved back: the clone there is removed where this move made it, never one that was there before.

///|
/// How long a clone there is waited for, told back as it ends (`move.repo.made`).
pub let clone_wait_ms : Int = 60 * 60_000

///|
/// What the repos module asks of the machine's files (node:fs/promises, as repos.ts asks it).
pub(all) struct Fs {
  read_text : async (String) -> String?
  readdir : async (String) -> Array[String]?
  /// `stat(path).mtimeMs` (None: it does not stat).
  mtime : async (String) -> Double?
  /// `stat(path).size` (None: it does not stat).
  size : async (String) -> Double?
  realpath : async (String) -> String?
  mkdir : async (String) -> Unit
  rename : async (String, String) -> Unit
  /// `rm(path, { recursive, force: true })`.
  remove : async (String, Bool) -> Unit
  /// The file at `path` written anew with each piece `next` gives, as it comes.
  write_from : async (String, async () -> Bytes?) -> Unit
}

///|
pub fn repo_item_id(url : String) -> String {
  "repo:\{url}"
}

///|
/// JavaScript's `String.prototype.trim`.
pub fn js_trim(s : String) -> String {
  s
  .trim(
    chars=" \t\n\r\u{0b}\u{0c}\u{a0}\u{feff}\u{1680}\u{2000}\u{2001}\u{2002}\u{2003}\u{2004}\u{2005}\u{2006}\u{2007}\u{2008}\u{2009}\u{200a}\u{2028}\u{2029}\u{202f}\u{205f}\u{3000}",
  )
  .to_string()
}

///|
fn js_space(c : Int) -> Bool {
  c == 0x20 ||
  (c >= 0x09 && c <= 0x0d) ||
  c == 0xa0 ||
  c == 0x1680 ||
  (c >= 0x2000 && c <= 0x200a) ||
  c == 0x2028 ||
  c == 0x2029 ||
  c == 0x202f ||
  c == 0x205f ||
  c == 0x3000 ||
  c == 0xfeff
}

///|
fn line_end(c : Int) -> Bool {
  c == 0x0a || c == 0x0d || c == 0x2028 || c == 0x2029
}

///|
/// What `/\[remote "origin"\][^[]*?url\s*=\s*(.+)/.exec(config)?.[1]` finds.
pub fn origin_url_of(config : String) -> String? {
  let head = "[remote \"origin\"]"
  let n = config.length()
  let mut from = 0
  while true {
    let at = match config.unsafe_substring(start=from, end=n).find(head) {
      Some(i) => from + i
      None => return None
    }
    let mut i = at + head.length()
    while i <= n {
      if i + 3 <= n && config.unsafe_substring(start=i, end=i + 3) == "url" {
        let mut j = i + 3
        while j < n && js_space(config.unsafe_charcode_at(j)) {
          j += 1
        }
        if j < n && config.unsafe_charcode_at(j) == '=' {
          let start = j + 1
          let mut k = start
          while k < n && js_space(config.unsafe_charcode_at(k)) {
            k += 1
          }
          // (`\s*` gives back what `.+` needs)
          let mut m = k
          while m >= start {
            let mut e = m
            while e < n && !line_end(config.unsafe_charcode_at(e)) {
              e += 1
            }
            if e > m {
              return Some(config.unsafe_substring(start=m, end=e))
            }
            m -= 1
          }
        }
      }
      if i < n && config.unsafe_charcode_at(i) == '[' {
        break
      }
      i += 1
    }
    from = at + 1
  }
  None
}

///|
/// The remotes of the linked worktrees in a directory, read again only as the directory's time changes.
let worktrees_kept : Map[String, (Double, Array[(String, String)])] = {}

///|
pub async fn worktrees_kept_of(fs : Fs, dir : String) -> Array[(String, String)] {
  let at = (fs.mtime)(dir).unwrap_or(-1.0)
  match worktrees_kept.get(dir) {
    Some((was, list)) if was == at => return list
    _ => ()
  }
  let list = if at < 0.0 { [] } else { worktrees_in(fs, dir) }
  worktrees_kept[dir] = (at, list)
  list
}

///|
/// A clone refused for want of a login, in words that say what to do (None: another failure).
pub fn clone_login(s : Say, error : String, url : String, station : String) -> String? {
  let e = error.to_lower()
  if !(e.contains("authentication failed") ||
    e.contains("could not read username") ||
    e.contains("terminal prompts disabled") ||
    e.contains("permission denied (publickey") ||
    e.contains("repository not found") ||
    e.contains("access denied")) {
    return None
  }
  Some(s.tr("station.move.why.cloneLogin", [("station", station), ("url", url), ("host", host_of(url))]))
}

///|
fn ascii_letter(c : Int) -> Bool {
  (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
}

///|
/// `/^[a-z]+:\/\/(?:[^@/]*@)?([^/:]+)/i` of `url`, else `/^[^@]+@([^:]+):/`, else `url`.
fn host_of(url : String) -> String {
  let n = url.length()
  let mut i = 0
  while i < n && ascii_letter(url.unsafe_charcode_at(i)) {
    i += 1
  }
  if i > 0 && i + 3 <= n && url.unsafe_substring(start=i, end=i + 3) == "://" {
    let rest = i + 3
    let mut j = rest
    let mut at_ = -1
    while j < n && url.unsafe_charcode_at(j) != '/' {
      if url.unsafe_charcode_at(j) == '@' {
        at_ = j
        break
      }
      j += 1
    }
    let start = if at_ >= 0 { at_ + 1 } else { rest }
    let mut e = start
    while e < n && url.unsafe_charcode_at(e) != '/' && url.unsafe_charcode_at(e) != ':' {
      e += 1
    }
    if e > start {
      return url.unsafe_substring(start~, end=e)
    }
  }
  match url.find("@") {
    Some(a) if a > 0 => {
      let mut e = a + 1
      while e < n && url.unsafe_charcode_at(e) != ':' {
        e += 1
      }
      if e < n && e > a + 1 {
        return url.unsafe_substring(start=a + 1, end=e)
      }
    }
    _ => ()
  }
  url
}

///|
/// The remote of the canonical clone a linked worktree at `dir` hangs on (its `.git` a file naming it).
pub async fn worktree_remote(fs : Fs, dir : String) -> (String, String)? {
  let said = match (fs.read_text)(@nodepath.join("/", [dir, ".git"])) {
    Some(s) if s.has_prefix("gitdir:") => s
    _ => return None
  }
  let gitdir = js_trim(slice_from(said, 7))
  if !@nodepath.is_absolute("/", gitdir) {
    return None
  }
  let common = @nodepath.join("/", [gitdir, "..", ".."])
  let config = (fs.read_text)(@nodepath.join("/", [common, "config"])).unwrap_or("")
  match origin_url_of(config) {
    Some(u) => Some((@nodepath.dirname("/", common), js_trim(u)))
    None => None
  }
}

///|
/// The canonical clones the linked worktrees in `workspace` hang on (it, and the directories right under it).
pub async fn worktrees_in(fs : Fs, workspace : String) -> Array[(String, String)] {
  let out = []
  match worktree_remote(fs, workspace) {
    Some(r) => out.push(r)
    None => ()
  }
  for name in (fs.readdir)(workspace).unwrap_or([]) {
    match worktree_remote(fs, @nodepath.join("/", [workspace, name])) {
      Some(r) => if !out.iter().any(x => x.1 == r.1) { out.push(r) }
      None => ()
    }
  }
  out
}

///|
/// What each worktree name of a clone's says its worktree is, read once for the process's life.
let gitdirs : Map[String, String] = {}

///|
fn sorted(xs : Array[String]) -> Array[String] {
  let c = xs.copy()
  c.sort_by((a, b) => js_compare(a, b))
  c
}

///|
/// JavaScript's default sort order of strings (by UTF-16 code units).
fn js_compare(a : String, b : String) -> Int {
  let n = if a.length() < b.length() { a.length() } else { b.length() }
  for i in 0..<n {
    let x = a.unsafe_charcode_at(i)
    let y = b.unsafe_charcode_at(i)
    if x != y {
      return x - y
    }
  }
  a.length() - b.length()
}

///|
/// The linked worktrees of canonical clones, as each clone says them, by the directory each is in and the one above
/// (repos.ts `worktreesOfClones`).
pub async fn worktrees_of_clones(
  fs : Fs,
  repos_dir : String,
  elsewhere : Array[String],
  data_dir : String,
) -> Map[String, Array[(String, String)]] {
  let out : Map[String, Array[(String, String)]] = {}
  let real = (fs.realpath)(data_dir).unwrap_or(data_dir)
  let in_cache = sorted((fs.readdir)(repos_dir).unwrap_or([])).map(name => @nodepath.join("/", [repos_dir, name]))
  let all = []
  for r in in_cache {
    if !all.contains(r) {
      all.push(r)
    }
  }
  for r in elsewhere {
    if !all.contains(r) {
      all.push(r)
    }
  }
  for repo in all {
    let config = (fs.read_text)(@nodepath.join("/", [repo, ".git", "config"])).unwrap_or("")
    let url = match origin_url_of(config) {
      Some(u) => js_trim(u)
      None => continue
    }
    for wt in sorted((fs.readdir)(@nodepath.join("/", [repo, ".git", "worktrees"])).unwrap_or([])) {
      let at = @nodepath.join("/", [repo, ".git", "worktrees", wt, "gitdir"])
      let gitdir = match gitdirs.get(at) {
        Some(g) => g
        None => {
          let g = js_trim((fs.read_text)(at).unwrap_or(""))
          if g != "" {
            gitdirs[at] = g
          }
          g
        }
      }
      if gitdir == "" || !@nodepath.is_absolute("/", gitdir) {
        continue
      }
      let dir = @nodepath.dirname("/", gitdir)
      let said = if real != data_dir && dir.has_prefix(real + "/") {
        Some(data_dir + slice_from(dir, real.length()))
      } else {
        None
      }
      let ats = [dir, @nodepath.dirname("/", dir)]
      match said {
        Some(s) => {
          ats.push(s)
          ats.push(@nodepath.dirname("/", s))
        }
        None => ()
      }
      for a in ats {
        let list = out.get(a).unwrap_or([])
        if !list.iter().any(x => x.1 == url) {
          list.push((repo, url))
        }
        out[a] = list
      }
    }
  }
  out
}

///|
pub(all) struct ReposDeps {
  data : String
  repos_dir : String
  workspaces : async (String) -> Array[String]
  git : async (String, Array[String]) -> String
  ask : Ask
  here : () -> String
  after : ((Int, () -> Unit) -> (() -> Unit))?
  name : ((String) -> String)?
  told : Told?
  remove : (async (String) -> Unit)?
  fs : Fs
  disk : Disk
  clock : Clock
  random : (Int) -> String
  say : Say
}

///|
/// The key a told step of a repository's names: what it is, its remote, and this ask's own part.
fn step_key(d : ReposDeps, step : String, url : String) -> String {
  let hash = @memory.sha256_hex(@utf8.encode(url)[:])
  "\{step}:\{slice_to(hash, 16)}:\{(d.random)(6)}"
}

///|
/// The told step a request names (None: a station from before, answered as before).
fn told_of(request : J) -> String? {
  match text(get(Some(request), "told")) {
    Some(t) if t.length() > 0 && t.length() <= 300 => Some(t)
    _ => None
  }
}

///|
pub struct Repos {
  priv d : ReposDeps
  priv there : Map[String, Bool]
  priv local : Map[String, String]
  priv moving : Map[String, J]
  priv cloning : Map[String, @effect.Deferred[(String, Bool)?]]
  priv clones : Map[String, @effect.Deferred[Unit]]
  priv mut made : J
}

///|
pub fn Repos::new(d : ReposDeps) -> Repos {
  let made = match (d.disk.read)(@nodepath.join("/", [d.data, "move", "repos.json"])) {
    Some(t) =>
      match (try Ok(parse(t)) catch { e => Err(e) }) {
        Ok(j) => j
        Err(_) => jo([])
      }
    None => jo([])
  }
  { d, there: {}, local: {}, moving: {}, cloning: {}, clones: {}, made }
}

///|
pub fn Repos::module(self : Repos) -> Module {
  {
    id: "repos",
    needs: [],
    plan: async fn(ws, to, reads) { self.plan(ws, to, reads) },
    move: async fn(item, to, progress, _arrive) { self.move(item, to, progress) },
    back: async fn(item, from, _arrive) { self.back(item, from) },
    state: async fn(item) {
      match self.moving.get(item_id(item)) {
        Some(p) => jo([("state", js("moving")), ("progress", p)])
        None =>
          st(
            if self.there.get(item_id(item)) == Some(true) {
              "there"
            } else {
              "here"
            },
          )
      }
    },
    usable_here: Some(async fn(_) { true }),
    usable_there: None,
    can_lend: None,
    lend: None,
    lent_for: None,
    left: None,
    is_here: None,
    abandon: None,
    ready: None,
    stop: None,
    resume: None,
  }
}

///|
async fn Repos::plan(self : Repos, ws : String, to : String, reads : PlanReads?) -> Array[J] {
  let items = []
  let workspaces = match reads {
    Some(r) => {
      let out = []
      (r.pages)(async fn(page) {
        for row in page.rows {
          out.push(text(get(Some(row), "workspace")).unwrap_or(""))
        }
      })
      out
    }
    None => (self.d.workspaces)(ws)
  }
  for w in workspaces {
    let list = match reads {
      Some(r) => (r.worktrees)(w)
      None => worktrees_kept_of(self.d.fs, w)
    }
    for r in list {
      let id = repo_item_id(r.1)
      if items.iter().any(x => item_id(x) == id) {
        continue
      }
      self.local[id] = r.0
      items.push(new_item("repos", id, @nodepath.basename("/", r.0), []))
    }
  }
  if items.length() > 0 && to != "" {
    let mut failed = false
    let answer = Some(
      (self.d.ask.ask)(
        to,
        jo([
          ("method", js("move.repo.have")),
          ("urls", jstrs(items.map(x => slice_from(item_id(x), 5)))),
        ]),
        None,
      ),
    ) catch {
      e => {
        ignore(not_answered(self.d.say, "move.repo.have", to, e))
        failed = true
        None
      }
    }
    for x in items {
      self.there[item_id(x)] = is_true(get(get(answer, "have"), slice_from(item_id(x), 5)))
    }
    if failed {
      for i in 0..<items.length() {
        items[i] = set(set(items[i], "cannot", js(unanswered(self.d.say))), "again", jb(true))
      }
    }
  }
  items
}

///|
async fn Repos::move(self : Repos, item : J, to : String, progress : (J) -> Unit) -> Unit {
  let repo = match self.local.get(item_id(item)) {
    Some(r) => r
    None => raise Failed("repository \{item_label(item)} is not here")
  }
  let url = slice_from(item_id(item), 5)
  let told : @effect.Deferred[(String, Bool)?] = @effect.Deferred::new()
  self.cloning[url] = told
  let there_name = match self.d.name {
    Some(n) => n(to)
    None => slice_to(to, 12)
  }
  // timer: a deadline for the clone there
  let late = match self.d.after {
    Some(after) =>
      after(clone_wait_ms, () => ignore(
        told.succeed(
          Some((
            self.d.say.tr("station.move.why.cloneLate", [
              ("url", url),
              ("station", there_name),
              ("minutes", (clone_wait_ms / 60_000).to_string()),
            ]),
            true,
          )),
        ),
      ))
    None => () => ()
  }
  let r = try Ok({
    let made = (self.d.ask.ask)(
      to,
      jo([
        ("method", js("move.repo.make")),
        ("url", js(url)),
        ("name", js(@nodepath.basename("/", repo))),
      ]),
      None,
    )
    if is_true(get(Some(made), "cloning")) {
      match told.wait() {
        Some((error, said)) => raise (if said { Said(error) } else { Failed(error) })
        None => ()
      }
    }
  }) catch { e => Err(e) }
  late()
  self.cloning.remove(url)
  match r {
    Ok(_) => ()
    Err(e) => raise e
  }
  let bundle = @nodepath.join("/", [self.d.data, "move", "\{(self.d.random)(4)}.bundle"])
  (self.d.fs.mkdir)(@nodepath.dirname("/", bundle))
  let r = try Ok({
    let made = (try Ok((self.d.git)(repo, [
      "bundle", "create", "-q", bundle, "--branches", "--tags", "--not", "--remotes",
    ])) catch { e => Err(e) }) is Ok(_)
    let size = if made { (self.d.fs.size)(bundle).unwrap_or(0.0) } else { 0.0 }
    let p = progress_j(0.0, size, "bytes")
    self.moving[item_id(item)] = p
    progress(p)
    if size > 0.0 {
      let bytes = Bytes_::FileBytes(bundle, 0L, size.to_int64())
      match self.d.told {
        None =>
          ignore(
            (self.d.ask.ask)(
              to,
              jo([("method", js("move.repo.bundle")), ("url", js(url))]),
              Some(bytes),
            ),
          )
        Some(told) => {
          let key = step_key(self.d, "bundle", url)
          ignore(
            told.asked(to, key, () => (
              jo([
                ("method", js("move.repo.bundle")),
                ("url", js(url)),
                ("told", js(key)),
              ]),
              Some(bytes),
            )),
          )
        }
      }
    }
    progress(progress_j(size, size, "bytes"))
    self.there[item_id(item)] = true
  }) catch { e => Err(e) }
  self.moving.remove(item_id(item))
  (self.d.fs.remove)(bundle, false)
  match r {
    Ok(_) => ()
    Err(e) => raise e
  }
}

///|
async fn Repos::back(self : Repos, item : J, from : String) -> Unit {
  let url = slice_from(item_id(item), 5)
  let key = step_key(self.d, "repodrop", url)
  match self.d.told {
    None =>
      ignore(
        (self.d.ask.ask)(
          from,
          jo([("method", js("move.repo.drop")), ("url", js(url))]),
          None,
        ),
      )
    Some(told) =>
      ignore(
        told.asked(from, key, () => (
          jo([
            ("method", js("move.repo.drop")),
            ("url", js(url)),
            ("told", js(key)),
          ]),
          None,
        )),
      )
  }
  self.there[item_id(item)] = false
}

///|
/// A clone of `url` made here, named after `named`.
async fn Repos::clone(self : Repos, url : String, named : String) -> Unit {
  let buf = StringBuilder::new()
  for c in named {
    let ok = (c >= 'A' && c <= 'Z') ||
      (c >= 'a' && c <= 'z') ||
      (c >= '0' && c <= '9') ||
      c == '.' ||
      c == '_' ||
      c == '-'
    if ok {
      buf.write_char(c)
    } else if c.to_int() > 0xffff {
      // (a character outside the BMP is two code units, each made `-`, as JavaScript's regex replaces them)
      buf.write_string("--")
    } else {
      buf.write_char('-')
    }
  }
  let base = if buf.to_string() == "" { "repo" } else { buf.to_string() }
  let mut name = base
  let mut i = 2
  while (self.d.fs.mtime)(@nodepath.join("/", [self.d.repos_dir, name])) is Some(_) {
    name = "\{base}-\{i}"
    i += 1
  }
  (self.d.fs.mkdir)(self.d.repos_dir)
  let temp = ".cloning-\{(self.d.random)(4)}"
  let r = try Ok({
    ignore((self.d.git)(self.d.repos_dir, ["clone", "-q", "--", url, temp]))
    (self.d.fs.rename)(
      @nodepath.join("/", [self.d.repos_dir, temp]),
      @nodepath.join("/", [self.d.repos_dir, name]),
    )
  }) catch { e => Err(e) }
  (self.d.fs.remove)(@nodepath.join("/", [self.d.repos_dir, temp]), true)
  match r {
    Ok(_) => ()
    Err(e) => raise e
  }
  self.made = set(
    self.made,
    url,
    jo([
      ("dir", js(@nodepath.join("/", [self.d.repos_dir, name]))),
      ("made", jb(true)),
    ]),
  )
  self.save_made()
}

///|
/// The clone here of remote `url` (None: none).
async fn Repos::clone_of(self : Repos, url : String) -> String? {
  for name in sorted((self.d.fs.readdir)(self.d.repos_dir).unwrap_or([])) {
    if name.has_prefix(".") {
      continue
    }
    let dir = @nodepath.join("/", [self.d.repos_dir, name])
    match (try Ok((self.d.git)(dir, ["remote", "get-url", "origin"])) catch { e => Err(e) }) {
      Ok(u) if u == url => return Some(dir)
      _ => ()
    }
  }
  None
}

///|
async fn Repos::save_made(self : Repos) -> Unit {
  (self.d.disk.write)(@nodepath.join("/", [self.d.data, "move", "repos.json"]), stringify(self.made))
}

///|
/// What another station asks of the clones here (`move.repo.*`).
pub async fn Repos::answer(self : Repos, peer : String, request : J, bytes : Bytes_?) -> J {
  let url = text(get(Some(request), "url")).unwrap_or("")
  let ok = jo([("ok", jb(true))])
  match text(get(Some(request), "method")) {
    Some("move.repo.made") => {
      match self.cloning.get(url) {
        Some(d) =>
          ignore(
            d.succeed(
              match text(get(Some(request), "error")) {
                Some(e) => Some((e, is_true(get(Some(request), "said"))))
                None => None
              },
            ),
          )
        None => ()
      }
      ok
    }
    Some("move.repo.have") => {
      let mut have = jo([])
      let urls = arr(get(Some(request), "urls")).unwrap_or([])
      let urls = if urls.length() > 500 { urls[0:500].to_array() } else { urls }
      for u in urls {
        match text(Some(u)) {
          Some(u) => have = set(have, u, jb(self.clone_of(u) is Some(_)))
          None => ()
        }
      }
      jo([("have", have)])
    }
    Some("move.repo.make") => {
      if url == "" {
        raise Refused("no remote named")
      }
      if self.clones.contains(url) {
        return jo([("cloning", jb(true))])
      }
      if self.clone_of(url) is Some(_) {
        return jo([
          ("ok", jb(true)),
          ("made", jb(is_true(get(get(Some(self.made), url), "made")))),
        ])
      }
      let done : @effect.Deferred[Unit] = @effect.Deferred::new()
      self.clones[url] = done
      let named = match get(Some(request), "name") {
        Some(Str(u)) => @jsjson.sanitize_str(u)
        None | Some(Null) => ""
        Some(v) => stringify(v)
      }
      (self.d.clock.spawn)(async fn() {
        let failed = match (try Ok(self.clone(url, named)) catch { e => Err(e) }) {
          Ok(_) => None
          Err(e) => {
            let message = message_of(e)
            let here = (self.d.here)()
            let station = match self.d.name {
              Some(n) => n(here)
              None => slice_to(here, 12)
            }
            match clone_login(self.d.say, message, url, station) {
              Some(said) => Some((said, true))
              None => {
                let lines = message.split("\n").map(l => l.to_string()).filter(l => l != "").collect()
                let last = if lines.length() > 0 {
                  lines[lines.length() - 1]
                } else {
                  message
                }
                Some(("the clone of \{url} failed there: \{last}", false))
              }
            }
          }
        }
        let tell = match failed {
          Some((error, said)) =>
            jo([
              ("method", js("move.repo.made")),
              ("url", js(url)),
              ("error", js(error)),
              ("said", jb(said)),
            ])
          None => jo([("method", js("move.repo.made")), ("url", js(url))])
        }
        ignore(try Ok((self.d.ask.ask)(peer, tell, None)) catch { e => Err(e) })
        self.clones.remove(url)
        ignore(done.succeed(()))
      })
      jo([("cloning", jb(true))])
    }
    Some("move.repo.bundle") => {
      let dir = self.clone_of(url)
      let (dir, next) = match (dir, bytes) {
        (Some(d), Some(Came(next))) => (d, next)
        _ => raise Refused("no clone of that remote here: move.repo.make first")
      }
      let files = @nodepath.join("/", [self.d.data, "move", "in", "repos"])
      let name = (self.d.random)(8)
      (self.d.fs.mkdir)(files)
      let path = @nodepath.join("/", [files, name])
      (self.d.fs.write_from)(path, next)
      let fetch = async fn() -> J? {
        let r = try Ok((self.d.git)(dir, [
          "fetch", "-q", "--update-head-ok", path, "+refs/heads/*:refs/heads/*", "+refs/tags/*:refs/tags/*",
        ])) catch { e => Err(e) }
        (self.d.fs.remove)(path, false)
        match r {
          Ok(_) => Some(ok)
          Err(e) => raise e
        }
      }
      match (told_of(request), self.d.told) {
        (Some(key), Some(told)) => {
          let started = Ref(false)
          let answer = told.run(peer, key, _ => fetch(), started=() => started.val = true)
          if !started.val {
            (self.d.fs.remove)(path, false)
          }
          answer
        }
        _ => fetch().unwrap_or(ok)
      }
    }
    Some("move.repo.drop") => {
      let drop = async fn() -> J? {
        match get(get(Some(self.made), url), "made") {
          Some(Bool(true)) => {
            let dir = text(get(get(Some(self.made), url), "dir")).unwrap_or("")
            match self.d.remove {
              Some(r) => r(dir)
              None => (self.d.fs.remove)(dir, true)
            }
          }
          _ => ()
        }
        self.made = del(self.made, url)
        self.save_made()
        Some(ok)
      }
      match (told_of(request), self.d.told) {
        (Some(key), Some(told)) => told.run(peer, key, _ => drop())
        _ => drop().unwrap_or(ok)
      }
    }
    _ => raise Refused("no such repo request")
  }
}
