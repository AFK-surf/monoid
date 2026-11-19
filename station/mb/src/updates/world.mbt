// What these parts ask of the station and the machine, one way: a call by its TypeScript name (`fs.readFile`,
// `platform.findCommandSoon`, `log.warn`, `fetch`) with its arguments as JSON, answered with JSON or refused with a
// JavaScript error's class and fields. The station's program gives it the shell's and Node's answers; the tests'
// harness gives it the test's world (test/mb-updates.test.ts), which answers the TypeScript's own calls the same way.
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
  ask : async (String, Array[J]) -> J
  /// A call JavaScript makes and does not wait on (a log line, a listener told): said at once, its answer let go.
  say_now : (String, Array[J]) -> Unit
  /// The machine's own timers (`wall.after`: deadlines given other programs): the function returned calls it off.
  wall_after : async (Double, async () -> Unit) -> () -> Unit
  clock : Clock
  rt : @effect.Runtime
  /// How JSON.parse says what is wrong with `text` (V8's words).
  json_error : async (String) -> String
  /// Whether `signature` is Ed25519's over `message` by the raw public `key` (the shell's `crypto.verify`).
  verify : async (Bytes, Bytes, Bytes) -> Bool
  /// `fs.watch(dir, (_, name) => …)`: the callback told each change's name (none where it says none); the function
  /// returned closes it.
  watch : async (String, (String?) -> Unit) -> async () -> Unit
  /// A file's sha256 and size read as a stream where the world can (the shell's `fs.hash`); none: read whole
  /// (`createReadStream`).
  hash_stream : (async (String) -> (String, Double))?
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
/// `JSON.parse(text)`, refused with V8's words.
pub async fn World::json(self : World, t : String) -> J {
  parse(t) catch {
    _ => raise thrown("SyntaxError", (self.json_error)(t))
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

// ── the files (node:fs/promises, node:fs) ──────────────────────────────────────────────────────────────────────────

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
}

///|
fn stat_of(j : J) -> Stat {
  {
    size: num(get(Some(j), "size")).unwrap_or(0.0),
    file: get(Some(j), "file") is Some(Bool(true)),
    dir: get(Some(j), "dir") is Some(Bool(true)),
    symlink: get(Some(j), "symlink") is Some(Bool(true)),
    dev: num(get(Some(j), "dev")).unwrap_or(0.0),
    ino: num(get(Some(j), "ino")).unwrap_or(0.0),
    mtime_ms: num(get(Some(j), "mtimeMs")).unwrap_or(0.0),
  }
}

///|
/// `readFile(path, "utf8")`.
pub async fn World::read_text(self : World, path : String) -> String {
  match self.call("fs.readFile", [js(path), js("utf8")]) {
    Str(u) => @jsjson.sanitize_str(u)
    _ => ""
  }
}

///|
/// `readFile(path, "utf8")`, null where it fails.
pub async fn World::read_text_or_null(self : World, path : String) -> String? {
  Some(self.read_text(path)) catch {
    _ => None
  }
}

///|
/// `stat(path)`.
pub async fn World::stat(self : World, path : String) -> Stat {
  stat_of(self.call("fs.stat", [js(path)]))
}

///|
/// `lstat(path)`.
pub async fn World::lstat(self : World, path : String) -> Stat {
  stat_of(self.call("fs.lstat", [js(path)]))
}

///|
/// `realpath(path)`.
pub async fn World::realpath(self : World, path : String) -> String {
  text(Some(self.call("fs.realpath", [js(path)]))).unwrap_or("")
}

///|
/// `realpath(path).catch(() => null)`.
pub async fn World::realpath_or_null(self : World, path : String) -> String? {
  Some(self.realpath(path)) catch {
    _ => None
  }
}

///|
/// `access(path[, mode])`.
pub async fn World::access(self : World, path : String, mode? : Int) -> Unit {
  let args = [js(path)]
  match mode {
    Some(m) => args.push(ji(m))
    None => ()
  }
  ignore(self.call("fs.access", args))
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
/// `mkdir(path, opts)`.
pub async fn World::mkdir(self : World, path : String, opts? : J) -> Unit {
  let args = [js(path)]
  match opts {
    Some(o) => args.push(o)
    None => ()
  }
  ignore(self.call("fs.mkdir", args))
}

///|
/// `rm(path, opts)`.
pub async fn World::rm(self : World, path : String, recursive? : Bool = false) -> Unit {
  let opts = if recursive {
    jo([("recursive", jb(true)), ("force", jb(true))])
  } else {
    jo([("force", jb(true))])
  }
  ignore(self.call("fs.rm", [js(path), opts]))
}

///|
/// `rm(path, opts).catch(() => {})`.
pub async fn World::rm_quiet(self : World, path : String, recursive? : Bool = false) -> Unit {
  self.rm(path, recursive~) catch {
    _ => ()
  }
}

///|
pub async fn World::rename(self : World, from : String, to : String) -> Unit {
  ignore(self.call("fs.rename", [js(from), js(to)]))
}

///|
pub async fn World::write_file(self : World, path : String, t : String) -> Unit {
  ignore(self.call("fs.writeFile", [js(path), js(t)]))
}

///|
pub async fn World::readdir(self : World, path : String) -> Array[String] {
  match self.call("fs.readdir", [js(path)]) {
    Arr(xs) => xs.filter_map(x => text(Some(x)))
    _ => []
  }
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
/// The first `len` bytes at `pos` of a file opened for reading (`open`, `read`, `close`): what was read, none where it
/// could not be opened. The read's failure is `raise`d after the close.
pub async fn World::read_at(self : World, path : String, len : Int, pos : Double) -> Bytes? {
  let opened = Some(self.call("fs.open", [js(path), js("r")])) catch { _ => None }
  match opened {
    None => None
    Some(_) => {
      let got : Result[Bytes, Error] = try {
        let r = self.call("fh.read", [js(path), ji(0), ji(len), jn(pos)])
        let all = bytes_of(get(Some(r), "buffer"))
        let n = num(get(Some(r), "bytesRead")).unwrap_or(0.0).to_int()
        Ok(all[0:if n > all.length() { all.length() } else { n }].to_owned())
      } catch {
        e => Err(e)
      }
      ignore(self.call("fh.close", [js(path)])) catch {
        _ => ()
      }
      match got {
        Ok(b) => Some(b)
        Err(e) => raise e
      }
    }
  }
}

///|
/// A file's size as its handle says it (`fh.stat()`).
pub async fn World::handle_size(self : World, path : String) -> Double {
  num(get(Some(self.call("fh.stat", [js(path)])), "size")).unwrap_or(0.0)
}

///|
/// `createReadStream(path)` read whole (its bytes; failing as the stream errs).
pub async fn World::read_stream(self : World, path : String) -> Bytes {
  bytes_of(Some(self.call("fs.createReadStream", [js(path)])))
}

///|
/// A file's sha256 (hex) and size, as `hashFile` streams it.
pub async fn World::hash_file(self : World, path : String) -> (String, Double) {
  match self.hash_stream {
    Some(f) => f(path)
    None => {
      let b = self.read_stream(path)
      (sha256(b), b.length().to_double())
    }
  }
}

///|
/// A file written as it comes (`createWriteStream(path)`), ended once (`end`).
pub struct WriteStream {
  w : World
  path : String
  buf : @buffer.Buffer
}

///|
pub async fn World::write_stream(self : World, path : String) -> WriteStream {
  ignore(self.call("fs.createWriteStream", [js(path)]))
  { w: self, path, buf: Buffer() }
}

///|
pub fn WriteStream::write(self : WriteStream, b : Bytes) -> Unit {
  self.buf.write_bytes(b)
}

///|
/// `out.end(cb)`: the bytes written (an error ending it raised).
pub async fn WriteStream::end(self : WriteStream) -> Unit {
  ignore(self.w.call("fs.writeStream.end", [js(self.path), jbytes(self.buf.to_bytes())]))
}

// ── HTTP (fetch) ───────────────────────────────────────────────────────────────────────────────────────────────────

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
pub async fn Response::json(self : Response, w : World) -> J {
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
/// `request(url, { headers, signal[, method] })` by the request `via` names (`fetch`, the cloud's transport
/// `cloud.fetch`).
pub async fn World::fetch(self : World, via : String, url : String, meth? : String) -> Response {
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
