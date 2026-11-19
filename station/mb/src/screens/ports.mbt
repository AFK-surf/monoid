// What these parts ask of the machine and the program's runtime, each a port given them (`Io`): the machine's clock
// (`wall`'s, ops/fibers.ts: now, a timer, and process.hrtime's microseconds), fibers on the runtime, child processes
// (node:child_process's spawn and execFile, and ops/processes.ts's groups), connections (node:net's to a Unix socket
// or a TCP port of 127.0.0.1), the files (node:fs/promises, and the few reads made before the station serves), a
// folder watched, random bytes, the log, what the platform says (its os, arch, names and paths, a command's runnable
// form, its mounts) and the station's words. A station's program gives the shell's (`host_io`: files and sockets
// through the shell, the runtime's clock); a test gives its own world (the harness's), so every step is its to say.

/// A process's environment as NodeJS.ProcessEnv holds it: its names in the order first set.
pub(all) struct Env {
  pairs : Array[(String, String)]
}

///|
pub fn Env::new(pairs : Array[(String, String)]) -> Env {
  { pairs: pairs.copy() }
}

///|
pub fn Env::get(self : Env, k : String) -> String? {
  for p in self.pairs {
    if p.0 == k {
      return Some(p.1)
    }
  }
  None
}

///|
/// `env[k] = v` (its place kept where it was set).
pub fn Env::set(self : Env, k : String, v : String) -> Unit {
  for i, p in self.pairs {
    if p.0 == k {
      self.pairs[i] = (k, v)
      return
    }
  }
  self.pairs.push((k, v))
}

///|
pub fn Env::delete(self : Env, k : String) -> Unit {
  match self.pairs.search_by(p => p.0 == k) {
    Some(i) => ignore(self.pairs.remove(i))
    None => ()
  }
}

///|
/// `{ ...env }`.
pub fn Env::copy(self : Env) -> Env {
  { pairs: self.pairs.copy() }
}

///|
/// `env.X || ""`: a value, or nothing where it is unset or empty.
fn Env::truthy(self : Env, k : String) -> String? {
  match self.get(k) {
    Some(v) if v != "" => Some(v)
    _ => None
  }
}

///|
pub fn Env::to_j(self : Env) -> J {
  jo(self.pairs.map(p => (p.0, js(p.1))))
}

///|
pub fn Env::of_j(j : J) -> Env {
  match j {
    Obj(ps) =>
      {
        pairs: ps.filter_map(p => match p.1 {
          Str(u) => Some((@jsjson.text(p.0), @jsjson.text(u)))
          _ => None
        }),
      }
    _ => { pairs: [] }
  }
}

///|
/// The machine's time and timers (ops/fibers.ts `wall`), and process.hrtime's microseconds.
pub(all) struct Clock {
  now : () -> Double
  /// `f` once, `ms` from now; the returned function calls it off.
  after : (Double, () -> Unit) -> (() -> Unit)
  micros : () -> Double
}

///|
/// `wall.sleep(ms)`.
pub async fn Clock::sleep(self : Clock, ms : Double) -> Unit {
  let d : @effect.Deferred[Unit] = @effect.Deferred::new()
  ignore((self.after)(ms, () => ignore(d.succeed(()))))
  d.wait()
}

///|
/// How a child process is started (node:child_process `spawn`'s options as these parts give them): its environment
/// (none: the station's), whether it is a group of its own to be ended whole (ops/processes.ts `startCommand`), and
/// Windows' own (no window, its arguments as they are).
pub(all) struct SpawnOptions {
  env : Env?
  group : Bool
  verbatim : Bool
  /// Which of stdin, stdout, stderr are piped ("pipe") and which let go ("ignore").
  stdio : (String, String, String)
}

///|
pub fn SpawnOptions::piped(env? : Env? = None) -> SpawnOptions {
  { env, group: false, verbatim: false, stdio: ("pipe", "pipe", "pipe") }
}

///|
/// What a child says: its output and its errors' output as they come, its failing to start, its end (exit code, or
/// the signal that ended it; after its output).
pub(all) struct ChildEvents {
  out : (Bytes) -> Unit
  err : (Bytes) -> Unit
  error : (String) -> Unit
  close : (Int?, String?) -> Unit
}

///|
pub fn ChildEvents::none() -> ChildEvents {
  { out: _ => (), err: _ => (), error: _ => (), close: (_, _) => () }
}

///|
/// A child process started (node's ChildProcess, as these parts use it).
pub(all) struct Child {
  /// Its process id, none where it never started.
  pid : () -> Int?
  /// `stdin.write(data, done)`: `done` told once it is written, or why not.
  write : (Bytes, ((String?) -> Unit)?) -> Unit
  /// `stdin.end(data?)`.
  end_input : (Bytes?) -> Unit
  /// `stdin.destroy()`.
  destroy_input : () -> Unit
  /// Whether its stdin is still to be written (`!destroyed && !writableEnded`).
  input_open : () -> Bool
  /// `kill(signal)` ("SIGTERM" where none is said); `endCommand(child, signal)` for a group.
  kill : (String) -> Unit
  /// Still running (`exitCode === null && signalCode === null`).
  running : () -> Bool
}

///|
/// How a command run to its end failed (execFile's error): what Node says of it, its exit code or errno's name, the
/// signal that ended it, and what it said on its outputs.
pub(all) suberror ExecFailed {
  ExecFailed(message~ : String, code~ : J, signal~ : String?, stdout~ : String, stderr~ : String)
}

///|
/// Its words where it is said (`to_string`, a notice, a log): not its type's name (`station/<package>.<Type>`).
pub impl Show for ExecFailed with output(self, logger) {
  match self {
    ExecFailed(message~, ..) => logger.write_string(message)
  }
}

///|
/// execFile's options as these parts give them.
pub(all) struct ExecOptions {
  env : Env?
  timeout : Double?
  max_buffer : Double?
  verbatim : Bool
}

///|
pub fn ExecOptions::new(env? : Env? = None, timeout? : Double? = None, max_buffer? : Double? = None) -> ExecOptions {
  { env, timeout, max_buffer, verbatim: false }
}

///|
/// Child processes.
pub(all) struct Procs {
  spawn : (String, Array[String], SpawnOptions, ChildEvents) -> Child
  /// `execFile(file, args, options)`: its stdout once it ended with 0.
  exec : async (String, Array[String], ExecOptions) -> String
}

///|
/// Where a connection goes: a Unix socket's path, or a port of 127.0.0.1.
#derive(Eq)
pub(all) enum Target {
  Unix(String)
  Tcp(Int)
}

/// What a connection says (node:net's Socket events): it opened, what came, that it failed, that it closed.
pub(all) struct ConnEvents {
  connect : () -> Unit
  data : (Bytes) -> Unit
  error : (String) -> Unit
  close : () -> Unit
}

///|
/// A connection (node:net's Socket, as these parts use it).
pub(all) struct Conn {
  write : (Bytes) -> Unit
  /// `end()`: no more written, what comes still read.
  end : () -> Unit
  destroy : () -> Unit
  destroyed : () -> Bool
  pause : () -> Unit
  flow_again : () -> Unit
}

///|
pub(all) struct Net {
  connect : (Target, ConnEvents) -> Conn
}

///|
/// What a file is (fs.Stats as these parts read it).
#derive(Eq)
pub(all) struct Stat {
  dir : Bool
  file : Bool
  link : Bool
  size : Double
  mtime_ms : Double
}

/// An entry of a folder (`readdir(…, { withFileTypes: true })`).
#derive(Eq)
pub(all) struct Dirent {
  name : String
  dir : Bool
}

///|
/// A file failed to be read or written: Node's message and its code (`ENOENT`, `EEXIST`…).
pub(all) suberror FsFailed {
  FsFailed(String, String)
}

///|
/// Its words where it is said (`to_string`, a notice, a log): not its type's name (`station/<package>.<Type>`).
pub impl Show for FsFailed with output(self, logger) {
  match self {
    FsFailed(m, _) => logger.write_string(m)
  }
}

///|
/// The machine's files (node:fs/promises), and the few read before the station serves (node:fs's sync calls).
pub(all) struct Files {
  read : async (String) -> Bytes
  write : async (String, Bytes, Int?) -> Unit
  /// `access(path, mode)`: 0 F_OK, 1 X_OK, 4 R_OK.
  access : async (String, Int) -> Bool
  readdir : async (String) -> Array[Dirent]
  mkdir : async (String, Bool, Int?) -> Unit
  /// `mkdtemp(prefix)`: the folder made.
  mkdtemp : async (String) -> String
  rename : async (String, String) -> Unit
  /// `rm(path, { recursive, force })`.
  rm : async (String, Bool, Bool) -> Unit
  unlink : async (String) -> Unit
  stat : async (String) -> Stat
  lstat : async (String) -> Stat
  /// `cp(from, to, { recursive: true, verbatimSymlinks: true })`.
  copy_tree : async (String, String) -> Unit
  /// Bytes of an open file at `offset`, as many as there are up to `length` (`FileHandle.read`).
  read_at : async (String, Double, Int) -> Bytes
  /// Bytes written into a file at `offset` (`FileHandle.write`).
  write_at : async (String, Double, Bytes) -> Unit
  /// A file made anew (`open(path, "wx")`), failing where one is there.
  create : async (String) -> Unit
  /// Bytes added at a file's end (a FileHandle written along).
  append : async (String, Bytes) -> Unit
  /// `existsSync(path)`.
  exists_sync : (String) -> Bool
  /// `readFileSync(path, "utf8")`.
  read_sync : (String) -> String?
  /// `watch(dir, listener)`: told each change's file name (none where the system does not say), its failure; the
  /// returned function closes it. Fails where the folder cannot be watched.
  watch : (String, (String?) -> Unit, () -> Unit) -> (() -> Unit) raise FsFailed
}

///|
/// What the station logs (ops/log.ts): its level ("info", "warn"), part, words and details.
pub(all) struct Log {
  say : (String, String, String, J) -> Unit
}

///|
pub fn Log::info(self : Log, part : String, words : String, fields? : J = Null) -> Unit {
  (self.say)("info", part, words, fields)
}

///|
pub fn Log::warn(self : Log, part : String, words : String, fields? : J = Null) -> Unit {
  (self.say)("warn", part, words, fields)
}

///|
/// How a command is run on the platform (platform's `runnable`): what is started, with what, and whether its
/// arguments go as they are (Windows' own).
pub(all) struct Runnable {
  file : String
  args : Array[String]
  verbatim : Bool
}

///|
/// What the platform and this process say of themselves.
pub(all) struct Os {
  /// `os.hostname()`.
  hostname : () -> String
  /// `os.tmpdir()`, `os.homedir()`.
  tmpdir : () -> String
  homedir : () -> String
  /// `process.arch`, the platform's `os` ("mac", "linux", "windows"), `process.getuid()` (none on Windows),
  /// `process.execPath`, `process.pid`.
  arch : String
  os : String
  uid : Int?
  exec_path : String
  pid : Int
  /// `process.env`.
  env : () -> Env
  runnable : (String, Array[String], Env) -> Runnable
  runnable_soon : async (String, Array[String], Env) -> Runnable
  /// The disks mounted, as last read (platform `mountsSoon`).
  mounts_soon : async () -> Array[String]
  /// `Date.parse(s)` as this machine reads a date (its time zone where the words say none); NaN where it is none.
  date_parse : (String) -> Double
  /// `process.cwd()`.
  cwd : String
  /// Where this module's files are beside it (`new URL("./x", import.meta.url)`): the station's code.
  code_dir : String
}

///|
/// The station's words (ops/i18n.ts): `tr(lang, key, args)`, and the language it speaks itself.
pub(all) struct Words {
  tr : (String, String, J) -> String
  station_lang : () -> String
}

///|
/// Everything given: the ports, and fibers on the program's runtime (what a TypeScript `void promise` starts).
pub(all) struct Io {
  clock : Clock
  spawn : (async () -> Unit) -> Unit
  procs : Procs
  net : Net
  fs : Files
  log : Log
  os : Os
  words : Words
  /// `randomBytes(n)`, `randomInt(lo, hi)`.
  random : (Int) -> Bytes
  random_int : (Int, Int) -> Int
}

///|
/// `tr(lang, key, args)`.
fn Io::tr(self : Io, lang : String, key : String, args? : J = jo([])) -> String {
  (self.words.tr)(lang, key, args)
}

///|
/// `randomBytes(n).toString("hex")`.
fn Io::random_hex(self : Io, n : Int) -> String {
  hex_of((self.random)(n))
}

///|
/// A fiber of its own for what is not waited on (`void f()`), its failure let go.
fn Io::go(self : Io, f : async () -> Unit) -> Unit {
  (self.spawn)(async fn() { f() catch { _ => () } })
}

///|
/// `wall.now()`.
pub fn Clock::ms(self : Clock) -> Double {
  (self.now)()
}

///|
/// `Number(process.hrtime.bigint() / 1000n)`.
pub fn Clock::us(self : Clock) -> Double {
  (self.micros)()
}
