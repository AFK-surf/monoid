// The device tools (station/src/device/tools.ts, contract v1 §8, `comma/tools/1`): what a control plane's gateway may
// do on this machine for its agents — run a command, read and write files, keep processes, see which runtimes are
// here, and start and drive the station's own chats. What each op refuses is a ToolError with a stable code. How far
// the gateway may go is the station's own setting (`tools.access`: off | read | full). The machine is asked through
// the seam: its files (`fs.*`), a command started (`ops/processes.startCommand`, its output and end read as it comes:
// `$child.next`, each an event `[stream, base64]`, `["error", message]`, `["close", code]`, `["timeout"]` where the
// exec's timer came due, or null when nothing more comes), a signal (`ops/processes.endCommand`), the shell
// (`platform/index.platform.posixShellSoon`).

///|
/// Why an op was not done: `code` for machines (invalid_request, forbidden, not_found, unknown_op, failed, timeout…).
pub(all) suberror ToolError {
  ToolError(String, String)
}

///|
/// Its words where it is said (`to_string`, a notice, a log): not its type's name (`station/<package>.<Type>`).
pub impl Show for ToolError with output(self, logger) {
  match self {
    ToolError(_, m) => logger.write_string(m)
  }
}

///|
pub let access_levels : Array[String] = ["off", "read", "full"]

///|
/// The access config.json gives (`tools.access`); off when it names none it knows.
pub fn access_of(raw : JV) -> String {
  match jget(jget(Some(raw), "tools"), "access") {
    Some(Str(a)) if access_levels.contains(a) => a
    _ => "off"
  }
}

///|
pub let read_ops : Array[String] = [
  "fs.read", "fs.list", "fs.stat", "runtime.probe", "process.list", "process.tail", "session.status",
]

///|
pub let ops : Array[String] = [
  "exec", "fs.read", "fs.write", "fs.list", "fs.stat", "process.start", "process.write",
  "process.tail", "process.stop", "process.list", "runtime.probe", "session.start",
  "session.say", "session.status",
]

///|
pub fn permitted(access : String, op : String) -> Bool {
  access == "full" || (access == "read" && read_ops.contains(op))
}

///|
pub let output_cap : Int = 1024 * 1024

///|
pub let read_cap : Int = 8 * 1024 * 1024

///|
let exec_timeout_ms : Double = 120000.0

///|
let exec_timeout_max_ms : Double = 600000.0

///|
/// What a kept process's output keeps (its latest), and how many are kept at once.
let process_keep : Int = 4 * 1024 * 1024

///|
let max_processes : Int = 32

///|
struct Kept {
  id : String
  command : String
  child : JV
  pid : JV
  started_at : JV
  chunks : Array[Bytes]
  mut base : Int
  mut total : Int
  mut exited : Bool
  mut exit_code : JV
}

///|
pub struct DeviceTools {
  b : ToolsBackend
  home : String
  env : JV
  sessions : String?
  processes : Map[String, Kept]
  mut next : Int
  background : Array[@effect.Fiber[Unit]]
}

///|
/// `home`: where relative paths and commands start; `env` the station's environment; `sessions` the station's
/// chats' part (none: this station runs no chats). What no op may touch is asked anew at each (`device.protect`), the
/// time of a start too (`device.now`).
pub fn DeviceTools::new(
  b : ToolsBackend,
  home : String,
  env : JV,
  sessions : String?,
) -> DeviceTools {
  { b, home, env, sessions, processes: Map::new(), next: 1, background: [] }
}

///|
fn tool_fail(code : String, message : String) -> ToolError {
  ToolError(code, message)
}

///|
fn str_arg(a : JV, k : String) -> String? {
  jstr(a.get(k))
}

///|
fn need(a : JV, k : String) -> String raise ToolError {
  match str_arg(a, k) {
    None | Some("") => raise tool_fail("invalid_request", "\{k} is required")
    Some(v) => v
  }
}

///|
fn int_arg(a : JV, k : String) -> Double? {
  match a.get(k) {
    Some(Num(n)) if is_integer(n) && n >= 0.0 => Some(n)
    _ => None
  }
}

///|
/// The env given (`{}` when none), None when it is not a map of strings.
fn env_of(a : JV) -> JV? {
  match a.get("env") {
    None | Some(Null) => Some(jobj([]))
    Some(e) if is_undef(e) => Some(jobj([]))
    Some(Obj(f) as e) =>
      if f.iter().all(p => p.1 is Str(_)) {
        Some(e)
      } else {
        None
      }
    _ => None
  }
}

///|
/// An IO failure as the op says it (its errno's code: ENOENT not_found, EACCES and EPERM forbidden).
fn io_error(e : Error) -> ToolError {
  let said = match e {
    @api_routes.Thrown(_, said) => Some(said)
    _ => None
  }
  let code = match jstr(jget(said, "code")) {
    Some("ENOENT") => "not_found"
    Some("EACCES") | Some("EPERM") => "forbidden"
    _ => "failed"
  }
  ToolError(code, message_of(e))
}

///|
fn within(path : String, root : String) -> Bool {
  path == root ||
  path.has_prefix(if root.has_suffix("/") { root } else { root + "/" })
}

///|
/// A path as the file system has it: its links followed, as far as it exists (what is not there yet is under its
/// nearest parent that is).
async fn DeviceTools::real(self : DeviceTools, path : String) -> String {
  match (try Some(self.b.ask("fs.realpath", [js(path)])) catch { _ => None }) {
    Some(Str(found)) => found
    _ => {
      let parent = path_dirname(path)
      if parent == path {
        path
      } else {
        path_resolve(self.home, [self.real(parent), path_basename(path)])
      }
    }
  }
}

///|
/// `path` as an op may use it: absolute (from the home when relative), and none of what is protected.
async fn DeviceTools::allowed(self : DeviceTools, path : String) -> String raise {
  let asked = if path_is_absolute(path) {
    path
  } else {
    path_resolve(self.home, [path])
  }
  let ok = {
    let found = self.real(asked)
    let roots = strings_of(Some(self.b.ask("device.protect", [])))
    let mut ok = true
    for root in roots {
      let r = self.real(root)
      if within(asked, root) ||
        within(found, r) ||
        within(asked, r) ||
        within(found, root) {
        ok = false
        break
      }
    }
    ok
  }
  if ok {
    asked
  } else {
    raise tool_fail(
      "forbidden", "the station's own data and the machine's logins are not reachable through device tools",
    )
  }
}

///|
async fn DeviceTools::path(self : DeviceTools, a : JV, k : String) -> String raise {
  self.allowed(need(a, k))
}

///|
async fn DeviceTools::cwd(self : DeviceTools, a : JV) -> String raise {
  self.allowed(str_arg(a, "cwd").unwrap_or(self.home))
}

///|
async fn DeviceTools::shell(self : DeviceTools) -> JV raise {
  self.b.ask("platform/index.platform.posixShellSoon", [self.env]) catch {
    e => raise ToolError("failed", message_of(e))
  }
}

///|
/// `{ ...self.env, ...env }`.
fn DeviceTools::env_with(self : DeviceTools, env : JV) -> JV {
  spread(self.env, jfields(Some(env)))
}

///|
/// Every kept process stopped (the station stops).
pub async fn DeviceTools::close(self : DeviceTools) -> Unit {
  for _, p in self.processes {
    if !p.exited {
      self.b.tell("ops/processes.endCommand", [p.child, js("SIGKILL")]) catch {
        _ => ()
      }
    }
  }
  self.processes.clear()
}

///|
/// Every process's output read as far as it has come (a test's).
pub async fn DeviceTools::drained(self : DeviceTools) -> Unit {
  while self.background.length() > 0 {
    let f = self.background.remove(0)
    ignore(f.wait())
  }
}

///|
/// One op, as `access` lets it: its result, or why not.
pub async fn DeviceTools::run(
  self : DeviceTools,
  op : String,
  args : JV,
  context : JV,
  access : String,
) -> JV raise {
  if !ops.contains(op) {
    raise tool_fail("unknown_op", "unknown op \{op}")
  }
  if !permitted(access, op) {
    raise tool_fail(
      "forbidden",
      if access == "off" {
        "device tools are turned off on this station"
      } else {
        "\{op} needs full access; this station allows \{access}"
      },
    )
  }
  let a = match args {
    Null => jobj([])
    x if is_undef(x) => jobj([])
    x => x
  }
  match op {
    "exec" => self.exec(a)
    "fs.read" => self.read(a)
    "fs.write" => self.write(a)
    "fs.list" => self.list(a)
    "fs.stat" => self.stat(a)
    "process.start" => self.start(a)
    "process.write" => self.process_write(a)
    "process.tail" => self.tail(a)
    "process.stop" => self.stop(a)
    "process.list" => {
      let shown = []
      for _, p in self.processes {
        shown.push(shown_process(p))
      }
      jobj([("processes", jarr(shown))])
    }
    "runtime.probe" => self.probe()
    _ => self.session(op, a, context)
  }
}

///|
/// A stream's text, the first OUTPUT_CAP bytes of it.
priv struct Captured {
  parts : @buffer.Buffer
  mut size : Int
  mut cut : Bool
}

///|
fn Captured::take(self : Captured, chunk : Bytes) -> Unit {
  if self.size >= output_cap {
    self.cut = true
    return
  }
  let room = output_cap - self.size
  if chunk.length() > room {
    self.cut = true
  }
  let n = if chunk.length() < room { chunk.length() } else { room }
  self.parts.write_bytesview(chunk[0:n])
  self.size += n
}

///|
fn chunk_of(v : JV?) -> Bytes {
  @base64.decode(text(v)) catch {
    _ => b""
  }
}

///|
async fn DeviceTools::exec(self : DeviceTools, a : JV) -> JV raise {
  let command = need(a, "command")
  guard env_of(a) is Some(env) else {
    raise tool_fail("invalid_request", "env must be a map of strings")
  }
  let timeout = {
    let t = int_arg(a, "timeout_ms").unwrap_or(exec_timeout_ms)
    if t < exec_timeout_max_ms {
      t
    } else {
      exec_timeout_max_ms
    }
  }
  let cwd = self.cwd(a)
  let sh = self.shell()
  let child = self.b.ask("ops/processes.startCommand", [
    sh,
    jstrs(["-c", command]),
    jobj([
      ("cwd", js(cwd)),
      ("env", self.env_with(env)),
      ("stdio", jstrs(["ignore", "pipe", "pipe"])),
    ]),
  ]) catch {
    e => raise tool_fail("failed", message_of(e))
  }
  let out : Captured = { parts: @buffer.new(), size: 0, cut: false }
  let err : Captured = { parts: @buffer.new(), size: 0, cut: false }
  let mut timed_out = false
  // How long a command is given is the machine's time.
  self.b.tell("ops/fibers.wall.after", [jnum(timeout)]) catch {
    e => raise tool_fail("failed", message_of(e))
  }
  while true {
    let ev = self.b.ask("$child.next", [child]) catch {
      e => raise tool_fail("failed", message_of(e))
    }
    let items = jitems(Some(ev))
    match jstr(items.get(0)) {
      Some("stdout") => out.take(chunk_of(items.get(1)))
      Some("stderr") => err.take(chunk_of(items.get(1)))
      Some("timeout") => {
        timed_out = true
        self.b.tell("ops/processes.endCommand", [child, js("SIGKILL")]) catch {
          _ => ()
        }
      }
      Some("error") => raise tool_fail("failed", text(items.get(1)))
      Some("close") => {
        let fields = [
          ("exit_code", items.get(1).unwrap_or(Null)),
          ("stdout", js(utf8_text(out.parts.to_bytes()))),
          ("stderr", js(utf8_text(err.parts.to_bytes()))),
          ("truncated", jbool(out.cut || err.cut)),
        ]
        if timed_out {
          fields.push(("timed_out", jbool(true)))
        }
        return jobj(fields)
      }
      // (it says nothing more and never ends: as a command that hangs, which only its timer ends)
      _ => @effect.never()
    }
  }
  Null
}

///|
async fn DeviceTools::read(self : DeviceTools, a : JV) -> JV raise {
  let path = self.path(a, "path")
  let offset = int_arg(a, "offset").unwrap_or(0.0)
  let length = {
    let l = int_arg(a, "length").unwrap_or(read_cap.to_double())
    if l < read_cap.to_double() {
      l
    } else {
      read_cap.to_double()
    }
  }
  let b = self.b
  (async fn() -> JV {
    let file = b.ask("fs.open", [js(path), js("r")])
    let name = ref_of(file).unwrap_or("")
    let result = {
      let stat = b.ask("\{name}.stat", [])
      let size = jnumber_or_zero(stat.get("size"))
      let want = {
        let w = if length < size - offset { length } else { size - offset }
        if w > 0.0 {
          w
        } else {
          0.0
        }
      }
      let (bytes_read, data) = if want > 0.0 {
        let got = b.ask("\{name}.read", [jnum(0.0), jnum(want), jnum(offset)])
        let n = jnumber_or_zero(got.get("bytesRead"))
        let bytes = @api_routes.bytes_of(got.get("buffer").unwrap_or(Null)).unwrap_or(
          b"",
        )
        let n = if n.to_int() < bytes.length() { n.to_int() } else { bytes.length() }
        (n.to_double(), bytes[0:n].to_bytes())
      } else {
        (0.0, b"")
      }
      jobj([
        ("content_base64", js(@base64.encode(data))),
        ("size", jnum(size)),
        ("eof", jbool(offset + bytes_read >= size)),
      ])
    } catch {
      e => {
        b.tell("\{name}.close", [])
        raise e
      }
    }
    b.tell("\{name}.close", [])
    result
  })() catch {
    e => raise io_error(e)
  }
}

///|
fn jnumber_or_zero(v : JV?) -> Double {
  match v {
    Some(Num(n)) => n
    _ => 0.0
  }
}

///|
async fn DeviceTools::write(self : DeviceTools, a : JV) -> JV raise {
  let path = self.path(a, "path")
  guard str_arg(a, "content_base64") is Some(content) else {
    raise tool_fail("invalid_request", "content_base64 is required")
  }
  let bytes = @base64.decode(content) catch { _ => b"" }
  let b = self.b
  (async fn() -> JV {
    b.tell("fs.mkdir", [
      js(path_dirname(path)),
      jobj([("recursive", jbool(true))]),
    ])
    if is_true(a.get("append")) {
      b.tell("fs.appendFile", [js(path), @api_routes.jbytes(bytes)])
    } else {
      b.tell("fs.writeFile", [js(path), @api_routes.jbytes(bytes)])
    }
    let s = b.ask("fs.stat", [js(path)])
    jobj([("size", field(s, "size"))])
  })() catch {
    e => raise io_error(e)
  }
}

///|
fn kind_of(s : JV) -> String {
  if is_true(s.get("file")) {
    "file"
  } else if is_true(s.get("dir")) {
    "dir"
  } else if is_true(s.get("symlink")) {
    "symlink"
  } else {
    "other"
  }
}

///|
async fn DeviceTools::list(self : DeviceTools, a : JV) -> JV raise {
  let path = self.path(a, "path")
  let b = self.b
  (async fn() -> JV {
    let names = strings_of(Some(b.ask("fs.readdir", [js(path)])))
    names.sort_by((x, y) => js_compare(x, y))
    let entries = []
    for name in names {
      let s = b.ask("fs.lstat", [js(path_resolve(self.home, [path, name]))]) catch {
        _ => continue
      }
      entries.push(
        jobj([
          ("name", js(name)),
          ("type", js(kind_of(s))),
          ("size", field(s, "size")),
          ("mtime_ms", jnum(jnumber_or_zero(s.get("mtimeMs")).floor())),
        ]),
      )
    }
    jobj([("entries", jarr(entries))])
  })() catch {
    e => raise io_error(e)
  }
}

///|
async fn DeviceTools::stat(self : DeviceTools, a : JV) -> JV raise {
  let path = self.path(a, "path")
  let b = self.b
  (async fn() -> JV {
    let s = b.ask("fs.lstat", [js(path)])
    jobj([
      ("path", js(path)),
      ("type", js(kind_of(s))),
      ("size", field(s, "size")),
      ("mtime_ms", jnum(jnumber_or_zero(s.get("mtimeMs")).floor())),
      ("mode", jnum((jnumber_or_zero(s.get("mode")).to_int() & 0o7777).to_double())),
    ])
  })() catch {
    e => raise io_error(e)
  }
}

///|
async fn DeviceTools::start(self : DeviceTools, a : JV) -> JV raise {
  let command = need(a, "command")
  guard env_of(a) is Some(env) else {
    raise tool_fail("invalid_request", "env must be a map of strings")
  }
  // The oldest ended ones make room; running ones are never dropped.
  if self.processes.length() >= max_processes {
    let ended = []
    for id, p in self.processes {
      if p.exited {
        ended.push(id)
      }
    }
    for id in ended {
      if self.processes.length() >= max_processes {
        self.processes.remove(id)
      }
    }
    if self.processes.length() >= max_processes {
      raise tool_fail(
        "too_many_processes", "at most \{max_processes} processes are kept; stop one first",
      )
    }
  }
  let cwd = self.cwd(a)
  let sh = self.shell()
  let id = "p\{self.next}"
  self.next += 1
  let child = self.b.ask("ops/processes.startCommand", [
    sh,
    jstrs(["-c", command]),
    jobj([
      ("cwd", js(cwd)),
      ("env", self.env_with(env)),
      ("stdio", jstrs(["pipe", "pipe", "pipe"])),
    ]),
  ]) catch {
    e => raise tool_fail("failed", message_of(e))
  }
  let started_at = self.b.ask("device.now", []) catch {
    e => raise tool_fail("failed", message_of(e))
  }
  let pid = self.b.ask("$child.pid", [child]) catch { _ => Null }
  let kept : Kept = {
    id,
    command,
    child,
    pid,
    started_at,
    chunks: [],
    base: 0,
    total: 0,
    exited: false,
    exit_code: Null,
  }
  let take = (chunk : Bytes) => {
    kept.chunks.push(chunk)
    kept.total += chunk.length()
    let mut held = kept.total - kept.base
    while held > process_keep && kept.chunks.length() > 1 {
      let dropped = kept.chunks.remove(0)
      kept.base += dropped.length()
      held -= dropped.length()
    }
  }
  self.processes[id] = kept
  let b = self.b
  self.background.push(
    @effect.runtime().fork(name="device process", async fn() {
      while true {
        let ev = b.ask("$child.next", [child]) catch { _ => break }
        let items = jitems(Some(ev))
        match jstr(items.get(0)) {
          Some("stdout") | Some("stderr") => take(chunk_of(items.get(1)))
          Some("error") => {
            take(utf8("\n[failed: \{text(items.get(1))}]\n"))
            kept.exited = true
          }
          Some("close") => {
            kept.exited = true
            kept.exit_code = items.get(1).unwrap_or(Null)
          }
          Some(_) => ()
          None => break
        }
      }
    }),
  )
  jobj([("process_id", js(id))])
}

///|
fn DeviceTools::kept(self : DeviceTools, a : JV) -> Kept raise ToolError {
  let id = need(a, "process_id")
  match self.processes.get(id) {
    Some(p) => p
    None => raise tool_fail("not_found", "no process \{id}")
  }
}

///|
async fn DeviceTools::process_write(self : DeviceTools, a : JV) -> JV raise {
  let p = self.kept(a)
  guard str_arg(a, "data_base64") is Some(data) else {
    raise tool_fail("invalid_request", "data_base64 is required")
  }
  if p.exited {
    raise tool_fail("exited", "process \{p.id} has exited")
  }
  let bytes = @base64.decode(data) catch { _ => b"" }
  self.b.tell("\{ref_of(p.child).unwrap_or("")}.stdin.write", [
    @api_routes.jbytes(bytes),
  ]) catch {
    e => raise tool_fail("failed", message_of(e))
  }
  jobj([])
}

///|
fn DeviceTools::tail(self : DeviceTools, a : JV) -> JV raise ToolError {
  let p = self.kept(a)
  let since = {
    let s = int_arg(a, "since").unwrap_or(0.0).to_int()
    if s > p.base {
      s
    } else {
      p.base
    }
  }
  let all = @buffer.new()
  for c in p.chunks {
    all.write_bytes(c)
  }
  let bytes = all.to_bytes()
  let from = if since - p.base < bytes.length() {
    since - p.base
  } else {
    bytes.length()
  }
  let data = bytes[from:].to_bytes()
  let fields = [
    ("data_base64", js(@base64.encode(data))),
    ("next", jint(p.total)),
    ("exited", jbool(p.exited)),
  ]
  if p.exited {
    fields.push(("exit_code", p.exit_code))
  }
  jobj(fields)
}

///|
async fn DeviceTools::stop(self : DeviceTools, a : JV) -> JV raise {
  let p = self.kept(a)
  if !p.exited {
    self.b.tell("ops/processes.endCommand", [p.child, js("SIGTERM")]) catch {
      _ => ()
    }
  }
  jobj([("process_id", js(p.id)), ("exited", jbool(p.exited))])
}

///|
fn shown_process(p : Kept) -> JV {
  jobj([
    ("process_id", js(p.id)),
    ("command", js(p.command)),
    ("pid", if is_undef(p.pid) { Null } else { p.pid }),
    ("started_at_ms", p.started_at),
    ("exited", jbool(p.exited)),
    ("exit_code", p.exit_code),
  ])
}

///|
async fn DeviceTools::probe(self : DeviceTools) -> JV raise {
  let b = self.b
  (async fn() -> JV {
    let runtimes = []
    for kind in ["claude", "codex"] {
      let env = b.ask("ops/shell-path.withShellCommand", [js(kind), self.env])
      let found = b.ask("updates/runtimes.findCommandSoon", [js(kind), env])
      if found is Null {
        continue
      }
      let r = b.ask("platform/index.platform.runnableSoon", [
        field(found, "real"),
        jstrs(["--version"]),
        env,
      ])
      let said = b.ask("child_process.execFile", [
        field(r, "file"),
        field(r, "args"),
        jobj([
          ("timeout", jint(10000)),
          ("env", env),
          ("windowsVerbatimArguments", field(r, "windowsVerbatimArguments")),
        ]),
      ])
      let said = match said {
        Str(s) => s
        Null => ""
        x if is_undef(x) => ""
        x => js_string(Some(x))
      }
      let version = b.ask("updates/versions.versionIn", [js(said)])
      let signed_in = signed_in(b, kind, env)
      runtimes.push(
        jobj([
          ("kind", js(kind)),
          ("path", field(found, "onPath")),
          ("version", version),
          ("signed_in", jbool(signed_in)),
        ]),
      )
    }
    jobj([("runtimes", jarr(runtimes))])
  })()
}

///|
/// Signed in on this machine, as the runtime keeps it.
async fn signed_in(b : ToolsBackend, kind : String, env : JV) -> Bool {
  if kind == "codex" {
    let file = b.ask("agents/machine-logins.codexAuthFile", [env]) catch {
      _ => return false
    }
    return (try Some(b.ask("fs.access", [file])) catch { _ => None }) is Some(_)
  }
  if truthy(env.get("ANTHROPIC_API_KEY")) {
    return true
  }
  let file = b.ask("agents/machine-logins.claudeCredentialsFile", [env]) catch {
    _ => return false
  }
  match (try Some(b.ask("fs.readFile", [file, js("utf8")])) catch { _ => None }) {
    Some(Str(t)) => index_of(t, "accessToken") >= 0
    _ => false
  }
}

///|
async fn DeviceTools::session(
  self : DeviceTools,
  op : String,
  a : JV,
  context : JV,
) -> JV raise {
  guard self.sessions is Some(sessions) else {
    raise tool_fail("unavailable", "this station runs no chats")
  }
  let requester = () => {
    let email = match str_arg(a, "requester_email") {
      Some(e) => Some(e)
      None => jstr(context.get("user_email"))
    }
    match email {
      None | Some("") => raise tool_fail("invalid_request", "requester_email is required")
      Some(e) => e
    }
  }
  let refused = (e : Error) => {
    let code = match e {
      @api_routes.Thrown(_, said) =>
        match jstr(said.get("code")) {
          Some(c) => c
          None => "failed"
        }
      _ => "failed"
    }
    ToolError(code, message_of(e))
  }
  let opt = (k : String) => match str_arg(a, k) {
    Some(v) => js(v)
    None => Null
  }
  match op {
    "session.start" => {
      let prompt = need(a, "prompt")
      let email = requester()
      self.b.ask("\{sessions}.start", [
        jobj([
          ("prompt", js(prompt)),
          ("title", opt("title")),
          ("runtime", opt("runtime")),
          ("requester", js(email)),
        ]),
      ]) catch {
        e => raise refused(e)
      }
    }
    "session.say" => {
      let thread = need(a, "thread")
      let text = need(a, "text")
      let email = requester()
      self.b.tell("\{sessions}.say", [
        jobj([
          ("thread", js(thread)),
          ("text", js(text)),
          ("requester", js(email)),
        ]),
      ]) catch {
        e => raise refused(e)
      }
      jobj([])
    }
    _ => {
      let thread = need(a, "thread")
      let status = self.b.ask("\{sessions}.status", [js(thread)])
      if status is Null {
        raise tool_fail("not_found", "no chat \{thread}")
      }
      status
    }
  }
}
