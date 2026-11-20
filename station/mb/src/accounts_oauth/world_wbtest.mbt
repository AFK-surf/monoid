// In-memory test world and case runners for accounts_oauth_wbtest.mbt.

///|
priv struct World {
  rt : @effect.Runtime
  files : Map[String, String]
  /// Folders: their inode and mtime.
  dirs : Map[String, (Double, Double)]
  inodes : Map[String, Double]
  /// Each file's mtime: a count of its writes.
  mtimes : Map[String, Double]
  mut next_ino : Double
  /// What each address answers, in turn (the last again once the rest are given).
  routes : Map[String, Array[Json]]
  requests : Array[Json]
  logs : Array[Json]
  /// Paths whose writes fail.
  unwritable : Array[String]
  /// The wall clock held where a test holds it (the TypeScript's Date held), else the runtime's.
  wall_at : Int64?
}

///|
fn World::new(c : Json) -> World {
  let start = num_of(get(Some(c), "now")).unwrap_or(0.0).to_int64()
  let w : World = {
    rt: @effect.Runtime::new(start~),
    files: {},
    dirs: {},
    inodes: {},
    mtimes: {},
    next_ino: 100.0,
    routes: {},
    requests: [],
    logs: [],
    unwritable: strings_of(get(Some(c), "unwritable")),
    wall_at: num_of(get(Some(c), "wall")).map(d => d.to_int64()),
  }
  if get(Some(c), "files") is Some(Object(fs)) {
    for path, text in fs {
      if text is String(t) {
        w.put(path, t)
      }
    }
  }
  if get(Some(c), "dirs") is Some(Object(ds)) {
    for path, mtime in ds {
      w.make_dirs(@nodepath.dirname("/", path))
      w.next_ino += 1.0
      w.dirs[path] = (w.next_ino, num_of(Some(mtime)).unwrap_or(start.to_double()))
    }
  }
  if get(Some(c), "routes") is Some(Object(rs)) {
    for path, answers in rs {
      if answers is Array(a) {
        w.routes[path] = a.copy()
      }
    }
  }
  w
}

///|
fn World::now(self : World) -> Int64 {
  self.rt.now()
}

///|
fn World::make_dirs(self : World, path : String) -> Unit {
  if path == "" || path == "/" || path == "." || self.dirs.contains(path) {
    return
  }
  self.make_dirs(@nodepath.dirname("/", path))
  self.next_ino += 1.0
  self.dirs[path] = (self.next_ino, self.now().to_double())
}

///|
fn World::has_dir(self : World, path : String) -> Bool {
  path == "/" || path == "." || self.dirs.contains(path)
}

///|
fn World::put(self : World, path : String, text : String) -> Unit {
  self.make_dirs(@nodepath.dirname("/", path))
  self.files[path] = text
  self.mtimes[path] = self.mtimes.get(path).unwrap_or(0.0) + 1.0
  if !self.inodes.contains(path) {
    self.next_ino += 1.0
    self.inodes[path] = self.next_ino
  }
}

///|
fn World::path_of(url : String) -> String {
  match @cloud_net.parse_url(url) {
    Some(u) => u.path
    None => url
  }
}

///|
fn World::io(self : World) -> Io {
  let rt = self.rt
  let enoent = (path : String) => FsError("ENOENT", "ENOENT: no such file or directory, '\{path}'")
  {
    now: () => rt.now(),
    wall: () => self.wall_at.unwrap_or(rt.now()),
    sleep: ms => @effect.sleep(ms),
    after: (ms, f) => {
      let fiber = rt.fork(async fn() {
        @effect.sleep(ms.to_int())
        f()
      })
      () => fiber.interrupt()
    },
    every: (ms, f) => {
      let fiber = rt.fork(async fn() {
        while true {
          @effect.sleep(ms.to_int())
          f()
        }
      })
      () => fiber.interrupt()
    },
    spawn: f => ignore(rt.fork(f)),
    fetch: req => {
      let path = World::path_of(req.url)
      self.requests.push({
        "method": Json::string(req.method_),
        "url": Json::string(req.url),
        "path": Json::string(path),
        "headers": Json::object(Map::from_array(req.headers.map(h => (lower(h.0), Json::string(h.1))))),
        "body": opt(req.body),
      })
      guard self.routes.get(path) is Some(answers) && answers.length() > 0 else {
        return { status: 404, headers: [], body: "{\"error\":\"no route\"}" }
      }
      let a = if answers.length() > 1 { answers.remove(0) } else { answers[0] }
      if num_of(get(Some(a), "delay")) is Some(ms) {
        @effect.sleep(ms.to_int())
      }
      if str_of(get(Some(a), "fail")) is Some(_) {
        raise Failed("fetch failed")
      }
      let body = match get(Some(a), "body") {
        Some(String(s)) => s
        Some(Null) | None => ""
        Some(j) => stringify(j)
      }
      let headers = match get(Some(a), "headers") {
        Some(Object(m)) => m.to_array().map(p => (p.0, js_string(Some(p.1))))
        _ => []
      }
      { status: num_of(get(Some(a), "status")).unwrap_or(200.0).to_int(), headers, body }
    },
    read: path => match self.files.get(path) {
      Some(t) => t
      None => raise enoent(path)
    },
    write_private: (path, text) => {
      if self.unwritable.contains(path) {
        raise FsError("EACCES", "EACCES: permission denied, open '\{path}'")
      }
      self.put(path, text)
    },
    write: (path, text) => {
      if self.unwritable.contains(path) {
        raise FsError("EACCES", "EACCES: permission denied, open '\{path}'")
      }
      if !self.has_dir(@nodepath.dirname("/", path)) {
        raise enoent(path)
      }
      self.put(path, text)
    },
    mkdir: (path, recursive) => {
      if recursive {
        self.make_dirs(path)
      } else if self.dirs.contains(path) || self.files.contains(path) {
        raise FsError("EEXIST", "EEXIST: file already exists, mkdir '\{path}'")
      } else if !self.has_dir(@nodepath.dirname("/", path)) {
        raise enoent(path)
      } else {
        self.next_ino += 1.0
        self.dirs[path] = (self.next_ino, self.now().to_double())
      }
    },
    rmdir: path => {
      guard self.dirs.contains(path) else { raise enoent(path) }
      let inside = path + "/"
      if self.dirs.keys().any(d => d.has_prefix(inside)) || self.files.keys().any(f => f.has_prefix(inside)) {
        raise FsError("ENOTEMPTY", "ENOTEMPTY: directory not empty, rmdir '\{path}'")
      }
      self.dirs.remove(path)
    },
    rm: (path, recursive) => {
      self.files.remove(path)
      if self.dirs.contains(path) {
        if !recursive {
          raise FsError("ERR_FS_EISDIR", "Path is a directory: rm returned EISDIR (is a directory) \{path}")
        }
        let inside = path + "/"
        self.dirs.remove(path)
        for d in self.dirs.keys().collect() {
          if d.has_prefix(inside) {
            self.dirs.remove(d)
          }
        }
        for f in self.files.keys().collect() {
          if f.has_prefix(inside) {
            self.files.remove(f)
          }
        }
      }
    },
    stat: path => match (self.dirs.get(path), self.files.get(path)) {
      (Some((ino, mtime)), _) => { dev: 1.0, ino, size: 0.0, mtime_ms: mtime }
      (None, Some(t)) =>
        { dev: 1.0, ino: self.inodes.get(path).unwrap_or(0.0), size: utf8_of(t).length().to_double(), mtime_ms: self.mtimes.get(path).unwrap_or(0.0) }
      _ => raise enoent(path)
    },
    exists: path => self.dirs.contains(path) || self.files.contains(path),
    realpath: path => if self.dirs.contains(path) || self.files.contains(path) { path } else { raise enoent(path) },
    readdir: path => {
      guard self.dirs.contains(path) else { raise enoent(path) }
      let inside = path + "/"
      let names = []
      for p in self.dirs.keys().collect() + self.files.keys().collect() {
        if p.has_prefix(inside) && !includes(from(p, inside.length()), "/") {
          names.push(from(p, inside.length()))
        }
      }
      sort_units(names)
    },
    hold: path => {
      guard self.dirs.get(path) is Some((ino, mtime)) else { raise enoent(path) }
      {
        stat: async fn() { { dev: 1.0, ino, size: 0.0, mtime_ms: mtime } },
        utimes: async fn(at) {
          if self.dirs.get(path) is Some((i, _)) && i == ino {
            self.dirs[path] = (ino, at.to_double())
          }
        },
        close: async fn() {  },
      }
    },
    log: (level, part, words, fields) =>
      self.logs.push({
        "level": Json::string(level),
        "part": Json::string(part),
        "words": Json::string(words),
        "fields": fields,
      }),
  }
}

///|
/// What the world holds now under `root`: its files by path from there.
fn World::files_under(self : World, root : String) -> Json {
  let out : Map[String, Json] = Map([])
  let inside = root + "/"
  for p in sort_units(self.files.keys().collect()) {
    if p.has_prefix(inside) {
      out[from(p, inside.length())] = Json::string(self.files[p])
    }
  }
  Json::object(out)
}

///|
fn World::dirs_under(self : World, root : String) -> Json {
  let inside = root + "/"
  jstrings(sort_units(self.dirs.keys().filter(d => d.has_prefix(inside)).map(d => from(d, inside.length())).collect()))
}

///|
/// Runs `f` on the world's clock to its end: what is ready, and with `timers` each timer as it comes due.
fn World::drive(self : World, f : async () -> Json, timers? : Bool = true) -> Json raise {
  let fiber = self.rt.fork(f)
  let mut turns = 0
  while !fiber.is_done() && turns < 200_000 {
    turns += 1
    self.rt.advance(0)
    if fiber.is_done() || !timers {
      break
    }
    match self.rt.next_timer() {
      Some(at) => {
        let d = at - self.rt.now()
        self.rt.advance(if d > 0L { d.to_int() } else { 0 })
      }
      None => break
    }
  }
  match fiber.poll() {
    Some(Succeeded(v)) => v
    Some(Failed(e)) => raise e
    Some(Interrupted) => raise Failed("interrupted")
    None => raise Failed("still waiting")
  }
}

///|
/// What is left going (a renewal behind a lend), run out.
fn World::settle(self : World) -> Unit {
  let mut turns = 0
  while turns < 200_000 {
    turns += 1
    self.rt.advance(0)
    match self.rt.next_timer() {
      Some(at) => {
        let d = at - self.rt.now()
        self.rt.advance(if d > 0L { d.to_int() } else { 0 })
      }
      None => break
    }
  }
}

///|
/// An outcome as the test compares it: `{ok}`, or `{error, kind}` (`kind`: said, renewRefused with its `status`, or
/// error).
fn outcome(f : () -> Json raise) -> Json {
  try {
    { "ok": f() }
  } catch {
    Said(m) => { "error": Json::string(m), "kind": "said" }
    RenewRefused(s, m) =>
      {
        "error": Json::string(m),
        "kind": "renewRefused",
        "status": match s {
          Some(n) => Json::number(n.to_double())
          None => Json::null()
        },
      }
    e => { "error": Json::string(message_of(e)), "kind": "error" }
  }
}

///|
let words_kept : Ref[Words?] = Ref(None)

///|
fn words() -> Words {
  match words_kept.val {
    Some(w) => w
    None => { tr: (_, key, _) => key }
  }
}

///|
fn env_of(j : Json?) -> Env {
  let e : Env = Map([])
  if j is Some(Object(m)) {
    for k, v in m {
      if v is String(s) {
        e[k] = s
      }
    }
  }
  e
}

///|
fn int_of(j : Json?, d : Int64) -> Int64 {
  num_of(j).map(n => n.to_int64()).unwrap_or(d)
}

///|
///|
fn store_of(w : World, c : Json) -> ClaudeStore {
  let keychain = get(Some(c), "keychain")
  {
    has_keychain: keychain is Some(_),
    read_keychain: async fn(_) {
      match keychain {
        Some(String(t)) => KeychainFound(t)
        Some(Null) | None => KeychainMissing
        Some(_) => KeychainUnreadable
      }
    },
    take_back_missing: async fn(_) { false },
    home_of: env => env.get("HOME"),
    user_name: async fn() { Some((true, "station")) },
    security: async fn(_, input, _) {
      w.logs.push({ "security": Json::string(input) })
      SecurityExited(Some(0))
    },
  }
}

///|
fn commands_of(w : World, c : Json) -> Commands {
  let said = get(Some(c), "commands")
  {
    run: async fn(command, args, env, _) {
      let line = ([command] + args).join(" ")
      w.requests.push({ "run": Json::string(line), "env": Json::object(env.map((_, v) => Json::string(v))) })
      match get(said, line) {
        Some(Object(r)) =>
          if r.get("missing") is Some(True) {
            NotFound("spawn \{command} ENOENT")
          } else if r.get("timeout") is Some(True) {
            TimedOut
          } else {
            Ended(
              num_of(r.get("code")).map(d => d.to_int()),
              str_of(r.get("stdout")).unwrap_or(""),
              str_of(r.get("stderr")).unwrap_or(""),
            )
          }
        _ => NotFound("spawn \{command} ENOENT")
      }
    },
  }
}

/// Claude's renewal (oauth.ts `claudeOAuthToken`), its world's files and the token endpoint's answers.
fn oauth_case(c : Json) -> Json raise {
  let w = World::new(c)
  let io = w.io()
  let auth = ClaudeAuth::new(io, store_of(w, c), words())
  let env = env_of(get(Some(c), "env"))
  let home = str_of(get(Some(c), "home"))
  let bound = match get(Some(c), "bound") {
    Some(Number(ms, ..)) => Some(({ ms: ms.to_int64(), after: io.after } : Bound))
    _ => None
  }
  let margin = int_of(get(Some(c), "margin"), margin_ms)
  let result = outcome(() => w.drive(async fn() {
    let (token, expires) = match bound {
      Some(b) =>
        auth.token(env, home, str_of(get(Some(c), "rejected")), str_of(get(Some(c), "endpoint")).unwrap_or(""), str_of(get(Some(c), "lang")).unwrap_or("zh"), margin~, bound=b)
      None =>
        auth.token(env, home, str_of(get(Some(c), "rejected")), str_of(get(Some(c), "endpoint")).unwrap_or(""), str_of(get(Some(c), "lang")).unwrap_or("zh"), margin~)
    }
    Json::array([Json::string(token), jnum(expires)])
  }))
  w.settle()
  let root = str_of(get(Some(c), "root")).unwrap_or("")
  {
    "result": result,
    "requests": Json::array(w.requests),
    "files": w.files_under(root),
    "dirs": w.dirs_under(root),
    "security": Json::array(w.logs.filter(l => get(Some(l), "security") is Some(_))),
  }
}

///|
fn check_case(c : Json) -> Json raise {
  let w = World::new(c)
  let io = w.io()
  let o = get(Some(c), "options")
  let given = get(Some(c), "deps")
  let source = get(given, "source")
  let ends = get(given, "endpoints")
  let deps : ProfileDeps = {
    commands: commands_of(w, c),
    find: _ => match source {
      Some(Null) | None => None
      s => s
    },
    endpoints: (_, _, _) => match ends {
      Some(Null) | None => None
      e => e
    },
    profile_runtimes: (_, _) => strings_of(get(given, "runtimes")),
    take_back: async fn(_) {  },
    file_credentials: async fn(_) {  },
    link_codex_auth: async fn(_, _) {  },
    parse_claude_credentials: text => {
      let oauth = get(parse_or_none(text), "claudeAiOauth")
      guard text_of(get(oauth, "accessToken")) is Some(_) else { return None }
      let m : Map[String, Json] = Map([])
      if str_of(get(oauth, "subscriptionType")) is Some(s) {
        m["subscriptionType"] = Json::string(s)
      }
      if str_of(get(oauth, "rateLimitTier")) is Some(s) {
        m["rateLimitTier"] = Json::string(s)
      }
      Some(Json::object(m))
    },
    read_cursor: async fn(_) { get(given, "cursor").filter(j => !(j is Null)) },
    cursor_me: async fn(_) { get(given, "cursorMe").filter(j => !(j is Null)) },
    cursor_models: async fn(_) { get(given, "cursorModels").unwrap_or(Json::null()) },
    devin_catalog: j => match get(given, "devinCatalog") {
      Some(Null) | None => raise Failed("no catalog")
      Some(cat) => {
        ignore(j)
        cat
      }
    },
    agy_take_back: async fn(_) { get(given, "agySignedIn") is Some(True) },
    note_agy_email: async fn(_, _) { str_of(get(given, "agyEmail")) },
    agy_token_ready: (_, _) => get(given, "agyReady") is Some(True),
    agy_plan_in: _ => str_of(get(given, "agyPlan")),
    uuid: () => "00000000-0000-4000-8000-000000000000",
  }
  let at = get(o, "urls")
  let options : CheckOptions = {
    runtime: str_of(get(o, "runtime")).unwrap_or(""),
    kind: str_of(get(o, "kind")).unwrap_or(""),
    key: str_of(get(o, "key")).unwrap_or(""),
    provider: str_of(get(get(o, "via"), "provider")),
    endpoint: str_of(get(get(o, "via"), "endpoint")),
    protocol: str_of(get(get(o, "via"), "protocol")),
    home: str_of(get(o, "home")).unwrap_or(""),
    env: env_of(get(o, "env")),
    machine: get(o, "machine") is Some(True),
    login: get(o, "login") is Some(True),
    machine_token: match get(o, "machineToken") {
      Some(String(t)) => Some(async fn(_) { t })
      _ => None
    },
    urls: match at {
      Some(Object(_)) =>
        Some({
          opencode: str_of(get(at, "opencode")).unwrap_or(""),
          anthropic: str_of(get(at, "anthropic")).unwrap_or(""),
          chatgpt: str_of(get(at, "chatgpt")).unwrap_or(""),
          claude_token: str_of(get(at, "claudeToken")).unwrap_or(""),
          console: str_of(get(at, "console")).unwrap_or(""),
        })
      _ => None
    },
    lang: str_of(get(o, "lang")).unwrap_or("zh"),
  }
  let auth = ClaudeAuth::new(io, store_of(w, c), words())
  let result = w.drive(async fn() { check_profile(io, deps, auth, words(), options) })
  let root = str_of(get(Some(c), "root")).unwrap_or("")
  {
    "result": result,
    "requests": Json::array(w.requests.filter(r => get(Some(r), "run") is None)),
    "files": w.files_under(root),
  }
}

///|
fn machine_case(c : Json) -> Json raise {
  let w = World::new(c)
  let io = w.io()
  let given = get(Some(c), "deps")
  let usage = match get(given, "usage") {
    Some(Object(u)) =>
      Some(async fn(runtime : String, _env : Env) -> Json {
        match u.get(runtime) {
          Some(String("throw")) => raise Failed("usage failed")
          Some(q) => q
          None => Json::null()
        }
      })
    _ => None
  }
  let deps : MachineDeps = {
    commands: commands_of(w, c),
    claude_credentials: async fn(_) { get(given, "credentials").filter(j => !(j is Null)) },
    codex_home: env => match env.get("CODEX_HOME") {
      Some(h) if h != "" => h
      _ => join([env.get("HOME").unwrap_or("."), ".codex"])
    },
    usage,
  }
  let env = env_of(get(Some(c), "env"))
  let logins = MachineLogins::new(io, deps, words(), env, () => str_of(get(Some(c), "lang")).unwrap_or("zh"))
  let heard = Ref(0)
  ignore(logins.changes(() => heard.val += 1))
  let reads = int_of(get(Some(c), "reads"), 1L).to_int()
  let out = []
  for _ in 0..<reads {
    ignore(w.drive(async fn() {
      logins.refresh()
      Json::null()
    }))
    out.push(Json::array(logins.get().map(l => l.to_json())))
  }
  // (the readings' allowances stamped by the clock, which the two sides do not share)
  { "readings": without_checked_at(Json::array(out)), "heard": Json::number(heard.val.to_double()) }
}

