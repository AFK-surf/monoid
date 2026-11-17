// A command run with a grant (station/src/vault/run.ts, secret_run 三种用法): through the proxy, with the grant's SSH
// key in an agent, with the secret in its environment, or with a file kept in the vault written out for it. The station
// runs it and gives back what it said with the secret hidden (scrub.mbt) and cut to a size an agent reads, and how it
// ended. The command itself is the machine's to start (machine.mbt `spawn`).

///|
/// What of a command's output an agent is given: its start and its end, this much of each.
let head_most : Int = 4 * 1024

///|
let tail_most : Int = 28 * 1024

///|
/// The variable every run has the secret (or its placeholder) in, besides the one the item or the agent names.
pub let secret_var : String = "STILLFAIL_SECRET"

///|
/// The variable every run of a login's grant has its account in.
pub let account_var : String = "STILLFAIL_USERNAME"

///|
/// A command to run (run.ts `RunAsk`).
pub(all) struct RunAsk {
  command : String
  cwd : String
  env : String?
  timeout_ms : Double
}

///|
/// How it ended, and what it said (run.ts `Ran`).
pub(all) struct Ran {
  code : Int?
  signal : String?
  output : String
  cut : Bool
  timed_out : Bool
  used : Bool?
}

///|
pub fn Ran::to_json(self : Ran) -> Json {
  let fs = [
    ("code", match self.code { Some(c) => ji(c); None => Json::null() }),
    ("signal", match self.signal { Some(s) => js(s); None => Json::null() }),
    ("output", js(self.output)),
    ("cut", jb(self.cut)),
    ("timedOut", jb(self.timed_out)),
  ]
  if self.used is Some(u) {
    fs.push(("used", jb(u)))
  }
  obj(fs)
}

///|
/// Output kept as it comes: all of it while short, then its first HEAD bytes and its last TAIL.
priv struct KeptOutput {
  mut head : Bytes
  mut tail : Bytes
  mut cut : Bool
}

///|
fn KeptOutput::new() -> KeptOutput {
  { head: b"", tail: b"", cut: false }
}

///|
fn KeptOutput::add(self : KeptOutput, b : Bytes) -> Unit {
  let mut rest = b
  if self.head.length() < head_most {
    let take = sub(rest, 0, rest.length().min(head_most - self.head.length()))
    self.head = concat(self.head, take)
    rest = sub(rest, take.length(), rest.length())
  }
  let all = concat(self.tail, rest)
  if all.length() > tail_most {
    self.cut = true
  }
  self.tail = sub(all, (all.length() - tail_most).max(0), all.length())
}

///|
fn KeptOutput::text(self : KeptOutput) -> String {
  if self.cut {
    "\{utf8_text(self.head)}\n…(cut)…\n\{utf8_text(self.tail)}"
  } else {
    utf8_text(concat(self.head, self.tail))
  }
}

///|
/// The shell a command is run by, found by the run's environment and the station's for what that leaves out
/// (run.ts `shellFor`): only to find it, the command given `env` alone.
async fn shell_for(w : World, env : Array[(String, String)]) -> String {
  let given : Map[String, Unit] = Map([])
  for e in env {
    given[upper(e.0)] = ()
  }
  let by : Array[(String, String)] = []
  for e in (w.env)() {
    if !given.contains(upper(e.0)) {
      by.push(e)
    }
  }
  (w.machine.shell_for)([..by, ..env])
}

///|
/// The environment's variables with `k` set to `v` (in its place where it is there).
fn env_set(vars : Array[(String, String)], k : String, v : String) -> Unit {
  for i, e in vars {
    if e.0 == k {
      vars[i] = (k, v)
      return
    }
  }
  vars.push((k, v))
}

///|
/// Runs `ask.command` (by sh -c) with grant `held`; `env`: the environment it starts from; `used` is told each use of
/// the secret (a host the proxy put it in, an SSH signature, the start of a command given it in its environment).
pub async fn run_with(
  w : World,
  held : @vault_crypto.Held,
  ask : RunAsk,
  proxy : Proxy,
  env : Array[(String, String)],
  used : (String) -> Unit,
  allowed? : () -> Bool = () => true,
) -> Ran {
  let value = @vault_crypto.value_of(held.secret).unwrap_or("")
  let id = gtext(Some(held.request), "id")
  let vars = env.copy()
  if @vault_crypto.account_of(held.secret) is Some(account) {
    env_set(vars, account_var, account)
  }
  let ends : Array[async () -> Unit] = []
  let finish = async fn() {
    // Last made, first ended: an agent's socket closed before its directory is taken away; one that fails leaves the
    // rest to be ended.
    let n = ends.length()
    for i in 0..<n {
      (ends[n - 1 - i])() catch {
        _ => ()
      }
    }
  }
  let ran = (async fn() -> Ran raise {
    if !allowed() {
      raise Failure("grant expired")
    }
    let mode = gtext(Some(held.grant), "mode")
    if mode == "proxy" {
      ignore(proxy.start())
      let admitted = proxy.admit({
        hosts: strings_of(get(Some(held.grant), "hosts")),
        placeholder: placeholder(id),
        value,
        used: host => used(host),
        allowed,
      })
      ends.push(async fn() { (admitted.1)() })
      let stand = placeholder(id)
      let bundle = proxy.bundle()
      for kv in [
        ("HTTPS_PROXY", admitted.0),
        ("https_proxy", admitted.0),
        ("NO_PROXY", ""),
        ("no_proxy", ""),
        ("NODE_EXTRA_CA_CERTS", bundle),
        ("SSL_CERT_FILE", bundle),
        ("REQUESTS_CA_BUNDLE", bundle),
        ("CURL_CA_BUNDLE", bundle),
        ("GIT_SSL_CAINFO", bundle),
        (secret_var, stand),
      ] {
        env_set(vars, kv.0, kv.1)
      }
      if ask.env is Some(e) && e != "" {
        env_set(vars, e, stand)
      }
    } else if mode == "ssh" {
      let key = parse_ssh_key(w.machine, value)
      let dir = (w.machine.temp_dir)("sf-ssh-")
      ends.push(async fn() { (w.machine.remove)(dir) })
      let sock = dir + "/agent.sock"
      let close = serve_agent(w.machine, sock, key, () => {
        if !allowed() {
          return false
        }
        used("ssh signature")
        true
      })
      ends.push(async fn() { close() })
      env_set(vars, "SSH_AUTH_SOCK", sock)
    } else if mode == "file" {
      used("file")
      let dir = (w.machine.temp_dir)("sf-file-")
      ends.push(async fn() { (w.machine.remove)(dir) })
      (w.machine.chmod)(dir, 0o700)
      let path = dir + "/" + file_name(gs(get(Some(held.secret), "fields"), "filename"))
      let bytes = @vault_crypto.unb64(value)
      (w.machine.write_file)(path, bytes, 0o600)
      env_set(vars, secret_var, path)
      if ask.env is Some(e) && e != "" {
        env_set(vars, e, path)
      }
      return spawned(w, ask, vars, file_hidden(bytes, value))
    } else {
      used("environment")
      env_set(vars, secret_var, value)
      if ask.env is Some(e) && e != "" {
        env_set(vars, e, value)
      }
    }
    spawned(w, ask, vars, [value])
  })() catch {
    e => {
      finish()
      raise e
    }
  }
  finish()
  ran
}

///|
/// The name a file is written under: its own, where it is a plain name, else "secret".
fn file_name(name : String?) -> String {
  let n = trim(name.unwrap_or(""))
  if n == "" || n == "." || n == ".." || contains(n, "/") || contains(n, "\\") || contains(n, "\u{0}") {
    "secret"
  } else {
    n
  }
}

///|
/// What of a file is hidden in a command's output: its text whole and its bytes' base64; a file not text, its base64.
fn file_hidden(bytes : Bytes, b64 : String) -> Array[String] {
  let text = utf8_text(bytes)
  if utf8_of(text) == bytes {
    let t = if ends(text, "\r\n") {
      slice(text, 0, b=text.length() - 2)
    } else if ends(text, "\n") {
      slice(text, 0, b=text.length() - 1)
    } else {
      text
    }
    [t, b64]
  } else {
    [b64]
  }
}

///|
async fn spawned(w : World, ask : RunAsk, env : Array[(String, String)], hidden : Array[String]) -> Ran {
  let shell = shell_for(w, env) catch {
    e =>
      return {
        code: None,
        signal: None,
        output: message_of(e),
        cut: false,
        timed_out: false,
        used: None,
      }
  }
  let kept = KeptOutput::new()
  let out = Scrubber::new(hidden)
  let err = Scrubber::new(hidden)
  let ended = (w.machine.spawn)({
    shell,
    args: ["-c", ask.command],
    cwd: ask.cwd,
    env,
    timeout_ms: ask.timeout_ms,
    on_out: b => kept.add(out.push(b)),
    on_err: b => kept.add(err.push(b)),
  })
  if ended.error is Some(why) {
    return { code: None, signal: None, output: why, cut: false, timed_out: false, used: None }
  }
  kept.add(out.end())
  kept.add(err.end())
  {
    code: ended.code,
    signal: ended.signal,
    output: kept.text(),
    cut: kept.cut,
    timed_out: ended.timed_out,
    used: None,
  }
}

///|
/// What a command printed, for a secret an agent asks to keep (run.ts `Captured`).
pub(all) struct Captured {
  code : Int?
  signal : String?
  out : String
  raw : String?
  err : String
  timed_out : Bool
  too_long : Bool
}

///|
pub fn Captured::to_json(self : Captured) -> Json {
  let fs = [
    ("code", match self.code { Some(c) => ji(c); None => Json::null() }),
    ("signal", match self.signal { Some(s) => js(s); None => Json::null() }),
    ("out", js(self.out)),
  ]
  if self.raw is Some(r) {
    fs.push(("raw", js(r)))
  }
  fs.push(("err", js(self.err)))
  fs.push(("timedOut", jb(self.timed_out)))
  fs.push(("tooLong", jb(self.too_long)))
  obj(fs)
}

///|
/// The most of a command's standard output taken as a secret.
let capture_max : Int = 64 * 1024

///|
/// Runs `command` (by sh -c) in `cwd` and takes what it prints as a secret: none of it is shown, its standard error
/// only with the output hidden in it.
pub async fn capture(w : World, command : String, cwd : String, env : Array[(String, String)], timeout_ms : Double) -> Captured {
  let shell = shell_for(w, env) catch {
    e =>
      return {
        code: None,
        signal: None,
        out: "",
        raw: None,
        err: message_of(e),
        timed_out: false,
        too_long: false,
      }
  }
  let out = Buffer()
  let mut size = 0
  let mut too_long = false
  let err = KeptOutput::new()
  let ended = (w.machine.spawn)({
    shell,
    args: ["-c", command],
    cwd,
    env,
    timeout_ms,
    on_out: b => {
      size += b.length()
      if size > capture_max {
        too_long = true
      } else {
        out.write_bytes(b)
      }
    },
    on_err: b => err.add(b),
  })
  if ended.error is Some(why) {
    return { code: None, signal: None, out: "", raw: None, err: why, timed_out: false, too_long: false }
  }
  let bytes = out.to_bytes()
  let text = utf8_text(bytes)
  let value = if ends(text, "\r\n") {
    slice(text, 0, b=text.length() - 2)
  } else if ends(text, "\n") {
    slice(text, 0, b=text.length() - 1)
  } else {
    text
  }
  {
    code: ended.code,
    signal: ended.signal,
    out: if too_long { "" } else { value },
    raw: Some(if too_long { "" } else { @vault_crypto.b64(bytes) }),
    err: if value == "" { err.text() } else { scrub(err.text(), [value]) },
    timed_out: ended.timed_out,
    too_long,
  }
}
