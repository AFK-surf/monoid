// What these parts ask of the station and the machine: files, HTTP and Ed25519 directly through `@host.Host`
// (`@host_world.*`, `host.fetch`, `host.shell_sync`); station/platform callbacks (`platform.*`, `ConfigFile.*`,
// `config.updateSoon`, `processes.*`, `CloudTransport.*`, `cloud.fetch`, `shellPath.*`, `cursor.sdkVersionSoon`,
// `os.tmpdir`, `console.*`, `wall.sleep`, `process.kill`) through `ask` / `say_now`.
// Time is the part's clock (`Clock`: the station's, a test's), timers and fibers on the program's runtime.

///|
/// An error as JavaScript throws it: its class's name (`Error`, `TypeError`, `Unverified`, `NotFinished`…) and its
/// fields (`message`, a system error's `code`, a DOMException's `name`).
pub(all) suberror Thrown {
  Thrown(String, J)
}

///|
/// Its words where it is said (`to_string`, a notice, a log): not its type's name (`station/<package>.<Type>`).
pub impl Show for Thrown with output(self, logger) {
  match self {
    Thrown(kind, f) => logger.write_string(text(get(Some(f), "message")).unwrap_or(kind))
  }
}

///|
pub fn thrown(kind : String, message : String, more? : Array[(String, J)] = []) -> Error {
  Thrown(kind, jo([("message", js(message))] + more))
}

///|
/// `new Error(message)`.
pub fn fail(message : String) -> Error {
  thrown("Error", message)
}

///|
/// `e.message`.
pub fn message_of(e : Error) -> String {
  match e {
    Thrown(_, f) => text(get(Some(f), "message")).unwrap_or("")
    @effect.Interrupt => "interrupted"
    e => e.to_string()
  }
}

///|
/// Its class's name.
pub fn kind_of(e : Error) -> String {
  match e {
    Thrown(k, _) => k
    _ => "Error"
  }
}

///|
/// A field of what it carries (`code`, `name`).
pub fn field_of(e : Error, k : String) -> J? {
  match e {
    Thrown(_, f) => get(Some(f), k)
    _ => None
  }
}

///|
/// What the error is as JSON (the harness says it so).
pub fn error_j(e : Error) -> J {
  match e {
    Thrown(k, f) => jo([("kind", js(k)), ("fields", f)])
    e => jo([("kind", js("Error")), ("fields", jo([("message", js(message_of(e)))]))])
  }
}

///|
/// The part's time: milliseconds since 1970 and a wait of so many.
pub(all) struct Clock {
  now : () -> Double
  sleep : async (Double) -> Unit
}

///|
/// What the part asks of the station and the machine (see the head of this file).
pub struct World {
  host : @host.Host
  ask : async (String, Array[J]) -> J
  /// A call JavaScript makes and does not wait on (a log line, a listener told): said at once, its answer let go.
  say_now : (String, Array[J]) -> Unit
  clock : Clock
  rt : @effect.Runtime
  /// `fs.watch(dir, (_, name) => …)`: the callback told each change's name (none where it says none); the function
  /// returned closes it.
  watch : async (String, (String?) -> Unit) -> async () -> Unit
}

///|
/// The world on the station's program: the shell's files, HTTP and Ed25519 directly on `host`, the rest asked of the
/// station (`node`, and what is only told it, `tell`). `clock`: the station's time; `watch`: a directory's changes.
pub fn host_world(
  host : @host.Host,
  node : async (String, Array[J]) -> J,
  tell : (String, Array[J]) -> Unit,
  clock : Clock,
  watch : async (String, (String?) -> Unit) -> async () -> Unit,
) -> World {
  { host, ask: node, say_now: tell, clock, rt: host.rt, watch }
}

///|
/// The machine's own timers (`wall.after`: deadlines given other programs): the function returned calls it off.
pub fn World::wall_after(self : World, ms : Double, f : async () -> Unit) -> () -> Unit {
  @host_world.after_async(self.host, ms.to_int(), f)
}

///|
/// Whether `signature` is Ed25519's over `message` by the raw public `key` (the shell's `crypto.verify`).
pub fn World::verify(self : World, key : Bytes, signature : Bytes, message : Bytes) -> Bool {
  let args : Json = {
    "alg": Json::string("Ed25519"),
    "key": Json::string(hex(key)),
    "signature": Json::string(hex(signature)),
    "message": Json::string(hex(message)),
  }
  (try self.host.shell_sync("crypto.verify", args) catch { _ => Json::null() }) is True
}

///|
pub async fn World::call(self : World, name : String, args : Array[J]) -> J {
  (self.ask)(name, args)
}

///|
/// A call that cannot fail as JavaScript makes it (a log line, a listener told): what it answers let go.
pub async fn World::tell(self : World, name : String, args : Array[J]) -> Unit {
  ignore(self.call(name, args)) catch {
    _ => ()
  }
}

///|
/// `log.info(part, message, fields)`.
pub fn World::info(self : World, part : String, message : String, fields? : J) -> Unit {
  let args = [js(part), js(message)]
  match fields {
    Some(f) => args.push(f)
    None => ()
  }
  (self.say_now)("log.info", args)
}

///|
/// `log.warn(part, message, fields)`.
pub fn World::warn(self : World, part : String, message : String, fields? : J) -> Unit {
  let args = [js(part), js(message)]
  match fields {
    Some(f) => args.push(f)
    None => ()
  }
  (self.say_now)("log.warn", args)
}

///|
/// A call made and not waited on (see `say_now`).
pub fn World::now(self : World, name : String, args : Array[J]) -> Unit {
  (self.say_now)(name, args)
}

///|
/// Runs `f` apart, what it throws let go (a promise nobody awaits: `void (async () => …)()`).
pub fn World::go(self : World, f : async () -> Unit) -> Unit {
  ignore(
    self.rt.fork_daemon("updates", on_error=_ => (), async fn() {
      f() catch {
        _ => ()
      }
    }),
  )
}

///|
/// `JSON.parse(text)`.
pub fn World::json(self : World, t : String) -> J raise {
  ignore(self)
  parse(t) catch {
    e => raise thrown("SyntaxError", e.to_string())
  }
}

// ── an AbortSignal ─────────────────────────────────────────────────────────────────────────────────────────────────

///|
/// An AbortSignal: aborted once, with its reason.
pub struct Signal {
  mut aborted : Bool
  mut reason : Error?
}

///|
pub fn Signal::new() -> Signal {
  { aborted: false, reason: None }
}

///|
/// `controller.abort(reason)` (none: an AbortError).
pub fn Signal::abort(self : Signal, reason? : Error) -> Unit {
  if self.aborted {
    return
  }
  self.aborted = true
  self.reason = Some(
    reason.unwrap_or(
      thrown("DOMException", "This operation was aborted", more=[("name", js("AbortError"))]),
    ),
  )
}

///|
/// `signal.throwIfAborted()`.
pub fn Signal::throw_if_aborted(self : Signal) -> Unit raise {
  match self.reason {
    Some(r) if self.aborted => raise r
    _ => ()
  }
}

///|
/// `new DOMException("timed out", "TimeoutError")`.
pub fn timed_out() -> Error {
  thrown("DOMException", "timed out", more=[("name", js("TimeoutError"))])
}

///|
/// An AbortSignal as the world is shown one.
let signal_j : J = jo([("$signal", jb(true))])

// ── the part's fibers (ops/fibers.ts Fibers) ───────────────────────────────────────────────────────────────────────

///|
/// Long-lived work and time of a part, on its clock, ended with it. As Effect runs a promise: a fiber waiting on work
/// that is called off stops waiting, and the work goes on.
pub struct Fibers {
  w : World
  what : String
  mut closed : Bool
  live : Array[@effect.Fiber[Unit]]
}

///|
pub fn Fibers::new(w : World, what : String) -> Fibers {
  { w, what, closed: false, live: [] }
}

///|
pub fn Fibers::now(self : Fibers) -> Double {
  (self.w.clock.now)()
}

///|
pub async fn Fibers::sleep(self : Fibers, ms : Double) -> Unit {
  (self.w.clock.sleep)(if ms < 0.0 { 0.0 } else { ms })
}

///|
/// `f` run with what it throws said in the log (`#guarded`).
async fn Fibers::guarded(self : Fibers, f : async () -> Unit) -> Unit {
  f() catch {
    e => self.w.warn(self.what, "background work failed", fields=jo([("error", js(message_of(e)))]))
  }
}

///|
/// `f` run apart, as a promise is; the fiber that waits on it ends once it is done (or is called off).
async fn Fibers::promise(self : Fibers, f : async () -> Unit) -> Unit {
  let done : @effect.Deferred[Unit] = @effect.Deferred::new()
  ignore(
    self.w.rt.fork_daemon("updates promise", on_error=_ => ignore(done.succeed(())), async fn() {
      self.guarded(f)
      ignore(done.succeed(()))
    }),
  )
  done.wait()
}

///|
fn Fibers::run(self : Fibers, f : async () -> Unit) -> @effect.Fiber[Unit] {
  let fiber = self.w.rt.fork_quiet(name="updates", async fn() {
    f() catch {
      _ => ()
    }
  })
  self.live.push(fiber)
  fiber
}

///|
/// Runs `f` as a fiber of the part's; what it throws is logged.
pub fn Fibers::spawn(self : Fibers, f : async () -> Unit) -> Unit {
  if self.closed {
    return
  }
  ignore(self.run(async fn() { self.promise(f) }))
}

///|
/// `f` once, `ms` from now, unless called off (the function returned) or the part closed first.
pub fn Fibers::after(self : Fibers, ms : Double, f : async () -> Unit) -> () -> Unit {
  if self.closed {
    return () => ()
  }
  let fiber = self.run(async fn() {
    self.sleep(ms)
    self.promise(f)
  })
  () => fiber.interrupt()
}

///|
/// `f` every `ms` (the first `ms` from now) until stopped (the function returned) or the part closes.
pub fn Fibers::every(self : Fibers, ms : Double, f : async () -> Unit) -> () -> Unit {
  if self.closed {
    return () => ()
  }
  let fiber = self.run(async fn() {
    while true {
      self.sleep(ms)
      self.promise(f)
    }
  })
  () => fiber.interrupt()
}

///|
/// A fiber of the part's running `f` (an Effect forked in its scope).
pub fn Fibers::fork(self : Fibers, f : async () -> Unit) -> @effect.Fiber[Unit] {
  self.run(f)
}

///|
/// Stops every wait it has going.
pub fn Fibers::close(self : Fibers) -> Unit {
  if self.closed {
    return
  }
  self.closed = true
  for f in self.live {
    f.interrupt()
  }
  self.live.clear()
}

// ── the files (direct `@host_world.*` on `self.host`) ──────────────────────────────────────────────────────────────

///|
fn enoent(syscall : String, path : String) -> Error {
  thrown("Error", @host_world.enoent_msg(syscall, path), more=[("code", js("ENOENT"))])
}

///|
async fn[T] wrap_shell(f : async () -> T) -> T {
  f() catch {
    Thrown(_, _) as e => raise e
    e => raise fail(@host_world.shell_error_msg(e))
  }
}

///|
/// A file's stat as the world says it.
pub struct Stat {
  size : Double
  file : Bool
  dir : Bool
  symlink : Bool
  dev : Double
  ino : Double
  mtime_ms : Double
  mode : Double
}

///|
fn stat_of_lstat(st : @host_world.LstatInfo) -> Stat {
  {
    size: st.size,
    file: st.kind == "file",
    dir: st.kind == "dir",
    symlink: st.kind == "link",
    dev: 0.0,
    ino: st.ino,
    mtime_ms: st.mtime_ms,
    mode: st.mode,
  }
}

///|
/// `readFile(path, "utf8")`.
pub async fn World::read_text(self : World, path : String, sync? : Bool = false) -> String {
  wrap_shell(async fn() {
    match @host_world.fs_read_text(self.host, path, sync~) {
      Some(t) => t
      None => raise enoent("open", path)
    }
  })
}

///|
/// `readFile(path)`.
pub async fn World::read_bytes(self : World, path : String, sync? : Bool = false) -> Bytes {
  wrap_shell(async fn() {
    match @host_world.fs_read_bytes(self.host, path, sync~) {
      Some(b) => b
      None => raise enoent("open", path)
    }
  })
}

///|
/// `readFile(path, "utf8")`, null where it fails.
pub async fn World::read_text_or_null(self : World, path : String, sync? : Bool = false) -> String? {
  Some(self.read_text(path, sync~)) catch {
    _ => None
  }
}

///|
/// `lstat(path, { throwIfNoEntry: false })`.
pub async fn World::lstat_or_null(self : World, path : String, sync? : Bool = false) -> Stat? {
  wrap_shell(async fn() { @host_world.fs_lstat(self.host, path, sync~).map(stat_of_lstat) })
}

///|
/// `lstat(path)`.
pub async fn World::lstat(self : World, path : String, sync? : Bool = false) -> Stat {
  match self.lstat_or_null(path, sync~) {
    Some(st) => st
    None => raise enoent("lstat", path)
  }
}

///|
async fn World::stat_or_null(self : World, path : String, sync? : Bool = false) -> Stat? {
  wrap_shell(async fn() {
    match @host_world.fs_realpath(self.host, path, sync~) {
      Some(r) => @host_world.fs_lstat(self.host, r, sync~).map(stat_of_lstat)
      None => None
    }
  })
}

///|
/// `stat(path)`.
pub async fn World::stat(self : World, path : String, sync? : Bool = false) -> Stat {
  match self.stat_or_null(path, sync~) {
    Some(st) => st
    None => raise enoent("stat", path)
  }
}

///|
/// `realpath(path)`.
pub async fn World::realpath(self : World, path : String, sync? : Bool = false) -> String {
  wrap_shell(async fn() {
    match @host_world.fs_realpath(self.host, path, sync~) {
      Some(r) => r
      None => raise enoent("realpath", path)
    }
  })
}

///|
/// `realpath(path).catch(() => null)`.
pub async fn World::realpath_or_null(self : World, path : String, sync? : Bool = false) -> String? {
  Some(self.realpath(path, sync~)) catch {
    _ => None
  }
}

///|
/// `access(path[, mode])`.
pub async fn World::access(self : World, path : String, mode? : Int = 0, sync? : Bool = false) -> Unit {
  guard self.stat_or_null(path, sync~) is Some(st) else { raise enoent("access", path) }
  let bits = st.mode.to_int()
  let unix = machine.val.plat is Unix
  if ((mode & 2) != 0 && (bits & 0o222) == 0) || (unix && (mode & 1) != 0 && (bits & 0o111) == 0) {
    raise thrown("Error", "EACCES: permission denied, access '\{path}'", more=[("code", js("EACCES"))])
  }
}

///|
/// `access(path).then(() => true, () => false)`.
pub async fn World::accessible(self : World, path : String) -> Bool {
  (try {
    self.access(path)
    true
  } catch {
    _ => false
  })
}

///|
/// `existsSync(path)` / `exists(path)`.
pub async fn World::exists(self : World, path : String, sync? : Bool = false) -> Bool {
  wrap_shell(async fn() { @host_world.fs_exists(self.host, path, sync~) })
}

///|
/// `mkdir(path)`.
pub async fn World::mkdir(self : World, path : String, sync? : Bool = false) -> Unit {
  wrap_shell(async fn() { @host_world.fs_mkdir(self.host, path, sync~) })
}

///|
/// `rm(path, opts)`.
pub async fn World::rm(self : World, path : String, recursive? : Bool = false, sync? : Bool = false) -> Unit {
  wrap_shell(async fn() { @host_world.fs_remove(self.host, path, recursive~, sync~) })
}

///|
/// `rm(path, opts).catch(() => {})`.
pub async fn World::rm_quiet(self : World, path : String, recursive? : Bool = false, sync? : Bool = false) -> Unit {
  self.rm(path, recursive~, sync~) catch {
    _ => ()
  }
}

///|
pub async fn World::rename(self : World, from : String, to : String, sync? : Bool = false) -> Unit {
  wrap_shell(async fn() { @host_world.fs_rename(self.host, from, to, sync~) })
}

///|
pub async fn World::write_file(self : World, path : String, t : String, sync? : Bool = false) -> Unit {
  wrap_shell(async fn() { @host_world.fs_write(self.host, path, t, sync~) })
}

///|
pub async fn World::write_bytes(self : World, path : String, data : Bytes) -> Unit {
  wrap_shell(async fn() { @host_world.fs_put_whole(self.host, path, data) })
}

///|
pub async fn World::readdir(self : World, path : String, sync? : Bool = false) -> Array[String] {
  wrap_shell(async fn() {
    match @host_world.fs_readdir(self.host, path, sync~) {
      Some(xs) => xs
      None => raise enoent("scandir", path)
    }
  })
}

///|
pub async fn World::readlink(self : World, path : String, sync? : Bool = false) -> String {
  wrap_shell(async fn() {
    match @host_world.fs_readlink(self.host, path, sync~) {
      Some(t) => t
      None => raise enoent("readlink", path)
    }
  })
}

///|
pub async fn World::symlink(self : World, target : String, path : String, sync? : Bool = false) -> Unit {
  wrap_shell(async fn() { @host_world.fs_symlink(self.host, target, path, sync~) })
}

///|
pub async fn World::link(self : World, from : String, to : String, sync? : Bool = false) -> Unit {
  wrap_shell(async fn() {
    if @host_world.shell_call(self.host, sync, "fs.link", { "from": Json::string(from), "to": Json::string(to) }) is False {
      raise thrown("Error", "EEXIST: file already exists, link '\{from}' -> '\{to}'", more=[("code", js("EEXIST"))])
    }
  })
}

///|
/// `crypto.randomBytes(n)`.
pub async fn World::random_bytes(self : World, n : Int) -> Bytes {
  wrap_shell(async fn() {
    match @host_world.shell_call(self.host, true, "crypto.random", { "bytes": Json::number(n.to_double()) }) {
      String(h) => @host_world.hex_bytes(h)
      _ => raise fail("no random bytes")
    }
  })
}

///|
/// `stat(p).then(() => true, () => false)`.
pub async fn World::exists_soon(self : World, path : String) -> Bool {
  (try {
    ignore(self.stat(path))
    true
  } catch {
    _ => false
  })
}

///|
/// The first `len` bytes at `pos` of a file opened for reading: what was read, none where it could not be opened.
pub async fn World::read_at(self : World, path : String, len : Int, pos : Double) -> Bytes? {
  let opened = (try { ignore(self.stat(path)); true } catch { _ => false })
  if !opened {
    return None
  }
  let got = wrap_shell(async fn() {
    @host_world.fs_read_bytes(self.host, path, from=pos, length=len.to_double())
  }).unwrap_or(b"")
  Some(got)
}

///|
/// A file's size (`fh.stat()`).
pub async fn World::handle_size(self : World, path : String) -> Double {
  self.stat(path).size
}

///|
/// `createReadStream(path)` read whole (its bytes; failing as the stream errs).
pub async fn World::read_stream(self : World, path : String) -> Bytes {
  self.read_bytes(path)
}

///|
/// A file's sha256 (hex) and size, its bytes read a MiB at a time by the shell (`fs.hash`).
pub async fn World::hash_file(self : World, path : String) -> (String, Double) {
  wrap_shell(async fn() {
    guard @host_world.fs_realpath(self.host, path) is Some(real) else { raise enoent("open", path) }
    guard @host_world.fs_lstat(self.host, real) is Some(st) else { raise enoent("open", path) }
    if st.kind == "dir" {
      raise thrown("Error", "EISDIR: illegal operation on a directory, read", more=[("code", js("EISDIR"))])
    }
    match @host_world.shell_call(self.host, false, "fs.hash", { "path": Json::string(real) }) {
      String(h) => (h, st.size)
      _ => raise enoent("open", path)
    }
  })
}

///|
/// A file written as it comes (`createWriteStream(path)`), ended once (`end`).
pub struct WriteStream {
  w : World
  path : String
  buf : @buffer.Buffer
}

///|
pub fn World::write_stream(self : World, path : String) -> WriteStream {
  { w: self, path, buf: Buffer() }
}

///|
pub fn WriteStream::write(self : WriteStream, b : Bytes) -> Unit {
  self.buf.write_bytes(b)
}

///|
/// `out.end(cb)`: the bytes written (an error ending it raised).
pub async fn WriteStream::end(self : WriteStream) -> Unit {
  self.w.write_bytes(self.path, self.buf.to_bytes())
}

// ── HTTP (fetch) ───────────────────────────────────────────────────────────────────────────────────────────────────

///|
let fetch_head_ms : Int = 15000

///|
let fetch_stall_ms : Int = 60000

///|
/// A response as fetch gives it: its status, its headers, its body in the pieces it came in.
pub struct Response {
  status : Int
  headers : J
  chunks : Array[Bytes]
  /// Whether it has a body (`response.body` is not null).
  has_body : Bool
  /// What reading its body ends with after its chunks (a connection broken off), when it does.
  breaks : Error?
}

///|
pub fn Response::to_j(self : Response) -> J {
  jo([
    ("status", jn(self.status.to_double())),
    ("headers", self.headers),
    ("chunks", ja(self.chunks.map(jbytes))),
  ])
}

///|
pub fn Response::ok(self : Response) -> Bool {
  self.status >= 200 && self.status <= 299
}

///|
/// `headers.get(name)` (names as the world gives them, lowercase).
pub fn Response::header(self : Response, name : String) -> String? {
  match get(Some(self.headers), name) {
    Some(Str(u)) => Some(@jsjson.sanitize_str(u))
    Some(Num(n)) => Some(num_text(n))
    _ => None
  }
}

///|
pub fn Response::bytes(self : Response) -> Bytes {
  let b = Buffer()
  for c in self.chunks {
    b.write_bytes(c)
  }
  b.to_bytes()
}

///|
pub fn Response::text(self : Response) -> String {
  utf8_text(self.bytes())
}

///|
/// `response.json()`.
pub fn Response::json(self : Response, w : World) -> J raise {
  w.json(self.text())
}

///|
fn response_of(j : J) -> Response {
  let chunks = match get(Some(j), "chunks") {
    Some(Arr(xs)) => xs.map(x => bytes_of(Some(x)))
    _ =>
      match get(Some(j), "body") {
        Some(b) => [bytes_of(Some(b))]
        None => []
      }
  }
  {
    status: num(get(Some(j), "status")).unwrap_or(200.0).to_int(),
    headers: get(Some(j), "headers").unwrap_or(jo([])),
    chunks,
    has_body: !(get(Some(j), "body") is Some(Null)),
    breaks: match get(Some(j), "breaks") {
      Some(Obj(_) as b) =>
        Some(Thrown(text(get(Some(b), "kind")).unwrap_or("Error"), get(Some(b), "fields").unwrap_or(jo([]))))
      _ => None
    },
  }
}

///|
/// Node's `fetch(url, { headers, signal[, method] })` on the shell: its redirects followed as `fetch` follows them (a
/// release's or a manifest's 302 to the storage it is served from).
pub async fn fetch_on(host : @host.Host, url : String, meth? : String) -> Response {
  let r = host.fetch(
    url,
    method_=meth.unwrap_or("GET"),
    headers=[("user-agent", "stillfail-station")],
    head_ms=fetch_head_ms,
    stall_ms=fetch_stall_ms,
    redirect="follow",
  ) catch {
    e => raise thrown("TypeError", "fetch failed", more=[("cause", js(@host_world.shell_error_msg(e)))])
  }
  let hs = jo(r.headers.map(h => (@jscase.lower(h.0), js(h.1))))
  { status: r.status, headers: hs, chunks: [r.body], has_body: true, breaks: None }
}

///|
/// `request(url, { headers, signal[, method] })` by the request `via` names (`fetch`, `fetch_on`; the cloud's
/// transport `cloud.fetch`).
pub async fn World::fetch(self : World, via : String, url : String, meth? : String) -> Response {
  if via == "fetch" {
    return fetch_on(self.host, url, meth?)
  }
  let init = [("headers", jo([("user-agent", js("stillfail-station"))]))]
  match meth {
    Some(m) => init.insert(0, ("method", js(m)))
    None => ()
  }
  init.push(("signal", signal_j))
  response_of(self.call(via, [js(url), jo(init)]))
}

// ── what is a JavaScript value's truth ─────────────────────────────────────────────────────────────────────────────

///|
/// `!!v` of a JSON value.
pub fn truthy(j : J?) -> Bool {
  @jsjson.jval_truthy(j)
}

// ── paths (node:path, this machine's) ──────────────────────────────────────────────────────────────────────────────

///|
/// The separator of this machine's paths (`\` on Windows), as node:path's own functions go by it.
let path_sep : Ref[String] = Ref("/")

///|
pub fn set_path_sep(sep : String) -> Unit {
  path_sep.val = sep
}

///|
/// `join(...parts)`.
pub fn pjoin(parts : Array[String]) -> String {
  @nodepath.join(path_sep.val, parts)
}

///|
/// `dirname(p)`.
pub fn pdirname(p : String) -> String {
  @nodepath.dirname(path_sep.val, p)
}

///|
/// `basename(p)`.
pub fn pbasename(p : String) -> String {
  @nodepath.basename(path_sep.val, p)
}

///|
/// `isAbsolute(p)`.
pub fn pis_absolute(p : String) -> Bool {
  @nodepath.is_absolute(path_sep.val, p)
}
