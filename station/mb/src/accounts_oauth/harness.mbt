// What station/test/mb-accounts-oauth.test.ts gives the same inputs as the TypeScript it replaces (reader `--builder
// harness-accounts-oauth`): a JSON line a case on stdin, a JSON line its outcome on stdout (`{"ok": …}` or
// `{"error": …}`). A case that does IO is worked out whole in a world of its own (`World`: its files in memory, the
// answers each address gives in turn, the commands' outputs, a clock of its own), every ask written down, so its
// outcome is a function of what it was given alone; the test gives the TypeScript the same world on a disk of its own,
// a server on 127.0.0.1 and commands that say the same.

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
fn job_json(j : LoginJob?) -> Json {
  match j {
    Some(x) => x.to_json()
    None => Json::null()
  }
}

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

///|
fn pure_case(c : Json) -> Json raise {
  let a = get(Some(c), "args")
  let arg = (i : Int) => match a {
    Some(Array(xs)) if i < xs.length() => Some(xs[i])
    _ => None
  }
  let s = (i : Int) => str_of(arg(i)).unwrap_or("")
  let w = words()
  match str_of(get(Some(c), "fn")).unwrap_or("") {
    "stripAnsi" => Json::string(strip_ansi(s(0)))
    "deviceCode" => opt(device_code(s(0)))
    "urlsIn" => jstrings(urls_in(s(0)))
    "parse" => {
      let j = arg(0)
      let job : LoginJob = {
        profile: str_of(get(j, "profile")).unwrap_or(""),
        runtime: str_of(get(j, "runtime")).unwrap_or(""),
        provider: None,
        state: str_of(get(j, "state")).unwrap_or(""),
        url: str_of(get(j, "url")),
        user_code: str_of(get(j, "userCode")),
        error: str_of(get(j, "error")),
        started_at: 0L,
        expires_at: 0L,
        browser: false,
        screen: None,
      }
      let changed = parse_login(job, s(1))
      { "changed": Json::boolean(changed), "job": job.to_json() }
    }
    "claudeCodeOf" => Json::string(claude_code_of(w, s(0), str_of(arg(1)), s(2)))
    "agyCallbackCode" => opt(agy_callback_code(str_of(arg(0)), str_of(arg(1))))
    "lineOf" => {
      let (line, version) = line_of(s(0))
      { "line": Json::string(line), "version": Json::array(version.map(d => Json::number(d))) }
    }
    "newerOf" => opt(newer_of(s(0), strings_of(arg(1))))
    "seesImages" => {
      let cat = Catalog::new()
      ignore(cat.learn(arg(0)))
      Json::boolean(sees_images(cat, s(1)))
    }
    "uncheckOutdated" => {
      let raw = arg(0).unwrap_or(Json::null())
      let found = arg(1)
      let (changes, unchecked) = uncheck_outdated(
        raw,
        id => match get(found, id) {
          Some(Array(_)) as l => Some(strings_of(l))
          _ => None
        },
        strings_of(arg(2)),
      )
      { "changes": Json::array(changes.map(x => x.to_json())), "unchecked": jstrings(unchecked), "raw": raw }
    }
    "catalog" => {
      let cat = Catalog::new()
      let n = cat.learn(arg(0))
      let facts = strings_of(arg(1)).map(m => match cat.facts(m) {
        Some(f) => f
        None => Json::null()
      })
      {
        "learned": Json::number(n.to_double()),
        "named": jstrings(cat.named()),
        "snapshot": cat.snapshot(),
        "facts": Json::array(facts),
      }
    }
    "consoleIn" =>
      match console_in(s(0)) {
        Some(l) => l.to_json()
        None => Json::null()
      }
    "pollAnswer" => {
      let token = match arg(0) {
        Some(Object(_)) as t =>
          Some({
            access: str_of(get(t, "access")).unwrap_or(""),
            refresh: str_of(get(t, "refresh")).unwrap_or(""),
            expires_in_ms: num_of(get(t, "expiresInMs")).unwrap_or(0.0),
            org: str_of(get(t, "org")),
          })
        _ => None
      }
      poll_answer(token, () => s(1)).to_json()
    }
    "renewAnswer" => {
      let token = match arg(1) {
        Some(Object(_)) as t =>
          Some({
            access: str_of(get(t, "access")).unwrap_or(""),
            refresh: str_of(get(t, "refresh")).unwrap_or(""),
            expires_in_ms: num_of(get(t, "expiresInMs")).unwrap_or(0.0),
            org: str_of(get(t, "org")),
          })
        _ => None
      }
      outcome(() => renew_answer(num_of(arg(0)).unwrap_or(0.0).to_int(), token, () => s(2)).to_json())
    }
    "accessKinds" => jstrings(access_kinds(s(0)))
    "keyed" => Json::boolean(keyed(s(0)))
    "runtimesOf" => jstrings(runtimes_of(s(0), str_of(arg(1))))
    "loginCommand" => Json::string(login_command(s(0), s(1), machine=arg(2) is Some(True)))
    "devinEmailIn" => opt(devin_email_in(s(0)))
    "grokModels" => jstrings(grok_models(s(0)))
    "grokEmailIn" => outcome(() => opt(grok_email_in(s(0))))
    "devinNotedIn" => outcome(() => opt(devin_noted_in(s(0))))
    "claudePlan" => opt(claude_plan(arg(0), arg(1)))
    "codexClaimsIn" =>
      match codex_claims_in(s(0)) {
        Some(j) => { "claims": j }
        None => { "none": true }
      }
    "capitalized" => Json::string(capitalized(s(0)))
    "formEncoded" =>
      Json::string(
        form_encoded(
          match arg(0) {
            Some(Array(ps)) =>
              ps.map(p => match p {
                Array([String(k), String(v)]) => (k, v)
                _ => ("", "")
              })
            _ => []
          },
        ),
      )
    "agyBaseModel" => {
      let (m, e) = agy_base_model(s(0))
      { "model": Json::string(m), "effort": opt(e) }
    }
    "devinFusionBase" => {
      let (m, e) = devin_fusion_base(s(0))
      { "model": Json::string(m), "effort": opt(e) }
    }
    f => raise Failed("no such function: \{f}")
  }
}

///|
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
fn console_case(c : Json) -> Json raise {
  let w = World::new(c)
  let io = w.io()
  let base = str_of(get(Some(c), "base")).unwrap_or("")
  let a = get(Some(c), "args")
  let arg = (i : Int) => match a {
    Some(Array(xs)) if i < xs.length() => Some(xs[i])
    _ => None
  }
  let s = (i : Int) => str_of(arg(i)).unwrap_or("")
  let what = str_of(get(Some(c), "fn")).unwrap_or("")
  let result = outcome(() => w.drive(async fn() {
    match what {
      "startDevice" => start_device(io, base).to_json()
      "deviceToken" => device_token(io, base, s(0)).to_json()
      "renewToken" => renew_token(io, base, s(0)).to_json()
      "whoIs" => {
        let (email, workspace) = who_is(io, base, s(0), str_of(arg(1)))
        { "email": opt(email), "workspace": opt(workspace) }
      }
      "postForm" => {
        let form = match arg(0) {
          Some(Object(m)) => m.to_array().map(p => (p.0, js_string(Some(p.1))))
          _ => []
        }
        let headers = match arg(1) {
          Some(Object(m)) => m.to_array().map(p => (p.0, js_string(Some(p.1))))
          _ => []
        }
        let (status, body) = post_form(io, base + s(2), form, headers)
        { "status": Json::number(status.to_double()), "body": body }
      }
      "readConsole" =>
        match read_console(io, s(0)) {
          Some(l) => l.to_json()
          None => Json::null()
        }
      "writeConsole" => {
        match console_in(stringify(arg(1).unwrap_or(Json::null()))) {
          Some(l) => write_console(io, s(0), l)
          None => ()
        }
        Json::null()
      }
      f => raise Failed("no such function: \{f}")
    }
  }))
  let root = str_of(get(Some(c), "root")).unwrap_or("")
  { "result": result, "requests": Json::array(w.requests), "files": w.files_under(root) }
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

///|
fn identity_case(c : Json) -> Json raise {
  let w = World::new(c)
  let io = w.io()
  let ids = CodexIds::new()
  let home = str_of(get(Some(c), "home")).unwrap_or("")
  let out = []
  let steps = match get(Some(c), "steps") {
    Some(Array(a)) => a
    _ => []
  }
  for step in steps {
    match get(Some(step), "write") {
      Some(String(t)) => w.put(join([home, "auth.json"]), t)
      _ => ()
    }
    if get(Some(step), "remove") is Some(True) {
      w.files.remove(join([home, "auth.json"]))
    }
    out.push(w.drive(async fn() { opt(ids.identity(io, home)) }))
  }
  Json::array(out)
}

///|
fn module_case(c : Json) -> Json raise {
  let w = World::new(c)
  let io = w.io()
  let cat = Catalog::new()
  let file = str_of(get(Some(c), "file")).unwrap_or("")
  let origin = str_of(get(Some(c), "origin"))
  let added : Array[Json] = []
  let steps = match get(Some(c), "steps") {
    Some(Array(a)) => a
    _ => []
  }
  let out : Array[Json] = []
  let m = w.drive(async fn() {
    let m = ModelCatalog::open(io, cat, file, () => origin, added=keys => added.push(jstrings(keys)))
    out.push({ "named": jstrings(cat.named()) })
    for step in steps {
      match get(Some(step), "etag") {
        Some(String(e)) => m.refresh(etag=e)
        _ => m.refresh()
      }
      out.push({ "named": jstrings(cat.named()) })
    }
    m.written()
    Json::null()
  })
  ignore(m)
  let root = str_of(get(Some(c), "root")).unwrap_or("")
  {
    "steps": Json::array(out),
    "added": Json::array(added),
    "requests": Json::array(w.requests),
    "files": w.files_under(root),
  }
}

///|
/// A login command as a test's world has it: what it says at first, then what it says and how it ends for each line
/// given it (`lines`: `is` a line exactly, or any other), and its end once it is approved (`approved`).
priv struct FakeCommand {
  spec : Json
  events : ChildEvents
  mut ended : Bool
}

///|
fn FakeCommand::say(self : FakeCommand, part : Json?) -> Unit {
  if self.ended {
    return
  }
  if str_of(get(part, "out")) is Some(o) && o != "" {
    (self.events.output)(o)
  }
  if num_of(get(part, "exit")) is Some(code) {
    self.ended = true
    (self.events.close)(Some(code.to_int()), None)
  }
}

///|
fn login_case(c : Json) -> Json raise {
  let w = World::new(c)
  let io = w.io()
  let specs = get(Some(c), "commands")
  let children : Map[String, FakeCommand] = Map([])
  let killed = []
  let plat : LoginPlatform = {
    terminal: async fn(_, _, _, _) { None },
    prepend_path: (env, dir) => {
      let out = env.copy()
      out["PATH"] = match env.get("PATH") {
        Some(p) if p != "" => "\{dir}:\{p}"
        _ => dir
      }
      out
    },
    runnable: async fn(command, args, _) { (command, args) },
    make_command: async fn(path, script) {
      w.put(path, script)
      path
    },
    with_shell_command: async fn(_, _, _) { None },
    file_credentials: async fn(_) {  },
    spawn: async fn(path, fargs, _, _, events) {
      let file = if fargs.length() > 0 { "\{path} \{fargs[0]}" } else { path }
      let spec = match get(specs, file) {
        Some(Object(_) as s) => s
        _ => raise Failed("spawn \{file} ENOENT")
      }
      let child : FakeCommand = { spec, events, ended: false }
      children[file] = child
      // What it says first, once it has started.
      w.rt.fork(async fn() { child.say(get(Some(child.spec), "start")) }) |> ignore
      {
        pid: Some(1),
        writable: () => !child.ended,
        write: async fn(text) {
          let line = trim(text)
          let rules = match get(Some(child.spec), "lines") {
            Some(Array(a)) => a
            _ => []
          }
          let rule = match rules.search_by(r => str_of(get(Some(r), "is")) == Some(line)) {
            Some(i) => Some(rules[i])
            None =>
              match rules.search_by(r => get(Some(r), "is") is None) {
                Some(i) => Some(rules[i])
                None => None
              }
          }
          w.rt.fork(async fn() { child.say(rule) }) |> ignore
        },
        send: _ => (),
        kill: () => {
          killed.push(Json::string(file))
          if !child.ended {
            child.ended = true
            (child.events.close)(None, Some("SIGTERM"))
          }
        },
      }
    },
    descendants: async fn(_) { [] },
    kill: _ => (),
  }
  let base_env = env_of(get(Some(c), "env"))
  let deps : LoginDeps = {
    platform: plat,
    env: () => base_env.copy(),
    kimi: async fn(_) { raise Failed("no Kimi here") },
    cursor_handshake: () => Json::object({}),
    poll_cursor: async fn(_) { None },
    mint_cursor_key: async fn(_, _) { raise Failed("no Cursor here") },
    write_cursor: async fn(_, _) {  },
    agy_token_ready: (_, _) => false,
    note_agy_email: async fn(_, _) {  },
    loopback_of: _ => false,
    key_name: () => "still.fail",
  }
  let data = str_of(get(Some(c), "data")).unwrap_or("")
  let cmds = get(Some(c), "names")
  let logins = LoginManager::new(io, deps, words(), data, commands={
    claude: str_of(get(cmds, "claude")).unwrap_or("claude"),
    codex: str_of(get(cmds, "codex")).unwrap_or("codex"),
    grok: str_of(get(cmds, "grok")),
    devin: None,
    agy: None,
  }, console=str_of(get(Some(c), "console")).unwrap_or(console_url))
  let out = []
  let steps = match get(Some(c), "steps") {
    Some(Array(a)) => a
    _ => []
  }
  for step in steps {
    let s = Some(step)
    let profile = str_of(get(s, "profile")).unwrap_or("")
    let lang = str_of(get(s, "lang")).unwrap_or("zh")
    let did = match str_of(get(s, "do")).unwrap_or("") {
      "start" => {
        let p = get(s, "login")
        let lp : LoginProfile = {
          id: str_of(get(p, "id")).unwrap_or(""),
          runtime: str_of(get(p, "runtime")).unwrap_or(""),
          home: str_of(get(p, "home")).unwrap_or(""),
          email: str_of(get(p, "email")),
          enterprise: get(p, "enterprise") is Some(True),
        }
        outcome(() => w.drive(async fn() { logins.start(lp, lang).to_json() }, timers=false))
      }
      "startConsole" =>
        outcome(() => w.drive(async fn() {
          logins.start_console(profile, str_of(get(s, "home")).unwrap_or(""), lang).to_json()
        }, timers=false))
      "submit" =>
        outcome(() => w.drive(async fn() {
          logins.submit_code(profile, str_of(get(s, "code")).unwrap_or(""), lang).to_json()
        }, timers=false))
      "cancel" => {
        logins.cancel(profile)
        Json::null()
      }
      "approve" => {
        match children.get(str_of(get(s, "command")).unwrap_or("")) {
          Some(child) => w.rt.fork(async fn() { child.say(get(Some(child.spec), "approved")) }) |> ignore
          None => ()
        }
        w.rt.advance(0)
        Json::null()
      }
      "advance" => {
        w.rt.advance(int_of(get(s, "ms"), 0L).to_int())
        w.rt.advance(0)
        Json::null()
      }
      "get" | "until" => {
        w.rt.advance(0)
        job_json(logins.get(profile))
      }
      d => raise Failed("no such step: \{d}")
    }
    out.push(did)
  }
  logins.stop_all()
  w.rt.advance(0)
  let root = str_of(get(Some(c), "root")).unwrap_or("")
  {
    "steps": Json::array(out),
    "requests": Json::array(w.requests),
    "files": w.files_under(root),
  }
}

///|
/// The station's words, from the catalog's files (client/i18n/catalog/<lang>/station.json).
async fn words_case(host : @host.Host, c : Json) -> Json {
  let read = async fn(path : String) -> @jsjson.JValue {
    match sh(host, "fs.read", { "path": Json::string(path) }) {
      String(t) => @jsjson.parse(t)
      _ => raise Failed("no catalog at \{path}")
    }
  }
  let w = @api_routes.Words::new(jv(read(str_of(get(Some(c), "zh")).unwrap_or(""))), jv(read(str_of(get(Some(c), "en")).unwrap_or(""))))
  words_kept.val = Some({ tr: (lang, key, args) => w.tr(lang, key, args~) })
  Json::boolean(true)
}

///|
pub fn harness_case(c : Json) -> Json {
  try {
    let ok = match str_of(get(Some(c), "op")).unwrap_or("") {
      "pure" => pure_case(c)
      "oauth" => oauth_case(c)
      "console" => console_case(c)
      "check" => check_case(c)
      "machine" => machine_case(c)
      "identity" => identity_case(c)
      "module" => module_case(c)
      "login" => login_case(c)
      op => raise Failed("no such case: \{op}")
    }
    { "ok": ok }
  } catch {
    e => { "error": Json::string(message_of(e)) }
  }
}

///|
/// The program's harness: a case a line, answered a line each, until stdin ends.
pub async fn harness(host : @host.Host) -> Unit {
  while true {
    guard host.line() is Some(line) else { break }
    let answer = match (try Some(@json.parse(line)) catch { _ => None }) {
      Some(c) =>
        if get(Some(c), "op") is Some(String("words")) {
          match (try Ok(words_case(host, c)) catch { e => Err(e) }) {
            Ok(v) => ({ "ok": v } : Json)
            Err(e) => { "error": Json::string(message_of(e)) }
          }
        } else {
          harness_case(c)
        }
      None => { "error": "not JSON" }
    }
    host.say(answer.stringify())
  }
}

///|
fn jv(v : @jsjson.JValue) -> @api_routes.JV {
  @jsjson.JValue::of_js(v)
}
