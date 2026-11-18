// The system as the station in MoonBit asks it (sys.c): the wall clock, stderr, the environment, the machine, the mesh
// addon's three calls, child processes, signals and the launcher's control lines. What sys.c tells later comes on the
// host's queue (`Host::sys_listen`), taken by the fiber that waits for it.

///|
/// `s` up to (not with) its UTF-16 unit `i`.
fn head(s : String, i : Int) -> String {
  s[:i].to_owned()
}

///|
/// `s` from its UTF-16 unit `i`.
fn tail(s : String, i : Int) -> String {
  s[i:].to_owned()
}

///|
fn cstr(s : String) -> Bytes {
  let b = @utf8.encode(s)
  let out = FixedArray::make(b.length() + 1, b'\x00')
  for i = 0; i < b.length(); i = i + 1 {
    out[i] = b[i]
  }
  Bytes::from_array(out)
}

///|
/// Strings each ended by a NUL, as one run of bytes.
fn nul_joined(xs : Array[String]) -> Bytes {
  let out = @buffer.Buffer()
  for x in xs {
    out.write_bytes(@utf8.encode(x))
    out.write_byte(b'\x00')
  }
  out.to_bytes()
}

///|
fn nul_split(b : Bytes) -> Array[String] {
  let out = []
  let mut start = 0
  for i = 0; i < b.length(); i = i + 1 {
    if b[i] == b'\x00' {
      out.push(@utf8.decode_lossy(b[start:i]))
      start = i + 1
    }
  }
  out
}

///|
extern "C" fn wall_ms_ffi() -> Int64 = "sfs_wall_ms"

///|
#borrow(b)
extern "C" fn err_ffi(b : Bytes) -> Int = "sfs_err"

///|
#borrow(b)
extern "C" fn fd_write_ffi(fd : Int, b : Bytes) -> Int = "sfs_fd_write"

///|
extern "C" fn fd_close_ffi(fd : Int) -> Int = "sfs_fd_close"

///|
extern "C" fn env_all_ffi() -> Bytes = "sfs_env_all"

///|
#borrow(name, value)
extern "C" fn env_set_ffi(name : Bytes, value : Bytes) -> Int = "sfs_env_set"

///|
#borrow(name)
extern "C" fn env_unset_ffi(name : Bytes) -> Int = "sfs_env_unset"

///|
extern "C" fn hostname_ffi() -> Bytes = "sfs_hostname"

///|
extern "C" fn homedir_ffi() -> Bytes = "sfs_homedir"

///|
extern "C" fn tmpdir_ffi() -> Bytes = "sfs_tmpdir"

///|
extern "C" fn os_ffi() -> Int = "sfs_os"

///|
extern "C" fn arch_ffi() -> Int = "sfs_arch"

///|
extern "C" fn machine_ffi() -> Bytes = "sfs_machine"

///|
#borrow(path)
extern "C" fn disk_of_ffi(path : Bytes) -> Bytes = "sfs_disk_of"

///|
#borrow(path)
extern "C" fn executable_ffi(path : Bytes) -> Int = "sfs_executable"

///|
extern "C" fn lan_addrs_ffi() -> Bytes = "sfs_lan_addrs"

///|
extern "C" fn parent_pid_ffi() -> Int = "sfs_parent_pid"

///|
extern "C" fn pid_alive_ffi(pid : Int) -> Int = "sfs_pid_alive"

///|
extern "C" fn kill_ffi(pid : Int, sig : Int, group : Int) -> Int = "sfs_kill"

///|
#borrow(path)
extern "C" fn file_lock_ffi(id : Int64, path : Bytes) = "sfs_file_lock"

///|
extern "C" fn file_unlock_ffi(handle : Int64) -> Int = "sfs_file_unlock"

///|
extern "C" fn peer_process_ffi(fd : Int) -> Bytes = "sfs_peer_process"

///|
extern "C" fn process_usage_ffi(pid : Int) -> Bytes = "sfs_process_usage"

///|
#borrow(program, args, env, cwd, out_file, err_file, out, why)
extern "C" fn spawn_ffi(
  id : Int64,
  program : Bytes,
  args : Bytes,
  env : Bytes,
  cwd : Bytes,
  in_mode : Int,
  out_mode : Int,
  err_mode : Int,
  out_file : Bytes,
  err_file : Bytes,
  group : Int,
  out : FixedArray[Int64],
  why : FixedArray[Byte],
) -> Int = "sfs_spawn"

///|
#borrow(b)
extern "C" fn handle_write_ffi(handle : Int64, b : Bytes) -> Int = "sfs_handle_write"

///|
extern "C" fn handle_close_ffi(handle : Int64) -> Int = "sfs_handle_close"

///|
extern "C" fn read_lines_ffi(id : Int64, fd : Int) = "sfs_read_lines"

///|
extern "C" fn signals_ffi(id : Int64, ignore : Int) = "sfs_signals"

///|
/// Now, in ms since 1970 (`wall`: what is shared with other programs, file times, expiries).
pub fn wall_ms() -> Int64 {
  wall_ms_ffi()
}

///|
/// The wall's time and the host's (a monotonic clock, `@host.now`, what the runtime's timers go by) as the program
/// started.
let p5_wall_0 : Int64 = wall_ms_ffi()

///|
let p5_mono_0 : Int64 = @host.now()

///|
/// Now, ms since the epoch, going on as the host's monotonic clock goes from the wall's time as the program started:
/// what the parts keep or compare as a time of the world's (a token's expiry, a record's `at`, a sample's time) never
/// the host's clock alone, which counts from the machine's start (a date in January 1970), and never going back.
fn p5_epoch_ms() -> Int64 {
  p5_wall_0 + (@host.now() - p5_mono_0)
}

///|
/// Writes `text` to stderr as it is.
pub fn err_write(text : String) -> Unit {
  ignore(err_ffi(@utf8.encode(text)))
}

///|
/// Writes `text` to stdout as it is.
pub fn out_write(text : String) -> Unit {
  ignore(fd_write_ffi(1, @utf8.encode(text)))
}

///|
/// Writes `bytes` to descriptor `fd` whole; false where it could not.
pub fn fd_write(fd : Int, bytes : Bytes) -> Bool {
  fd_write_ffi(fd, bytes) != 0
}

///|
pub fn fd_close(fd : Int) -> Unit {
  ignore(fd_close_ffi(fd))
}

///|
/// This process's environment, in its order.
pub fn env_all() -> Array[(String, String)] {
  nul_split(env_all_ffi()).filter_map(kv => match kv.find("=") {
    Some(i) if i > 0 => Some((head(kv, i), tail(kv, i + 1)))
    _ => None
  })
}

///|
/// One variable of this process's environment (a name of any case on Windows, as Node's `process.env`).
pub fn env_get(name : String) -> String? {
  let windows = is_windows()
  for kv in env_all() {
    if kv.0 == name || (windows && kv.0.to_upper() == name.to_upper()) {
      return Some(kv.1)
    }
  }
  None
}

///|
pub fn env_set(name : String, value : String) -> Unit {
  ignore(env_set_ffi(cstr(name), cstr(value)))
}

///|
pub fn env_unset(name : String) -> Unit {
  ignore(env_unset_ffi(cstr(name)))
}

///|
pub fn hostname() -> String {
  @utf8.decode_lossy(hostname_ffi())
}

///|
pub fn homedir() -> String {
  @utf8.decode_lossy(homedir_ffi())
}

///|
pub fn tmpdir() -> String {
  @utf8.decode_lossy(tmpdir_ffi())
}

///|
/// The system as Node's `process.platform` names it.
pub fn platform() -> String {
  match os_ffi() {
    0 => "darwin"
    1 => "linux"
    2 => "win32"
    _ => "other"
  }
}

///|
pub fn is_windows() -> Bool {
  os_ffi() == 2
}

///|
/// The processor as Node's `process.arch` names it.
pub fn arch() -> String {
  match arch_ffi() {
    0 => "arm64"
    1 => "x64"
    _ => "other"
  }
}

///|
/// The release's name of this system (darwin-arm64, linux-x64, linux-arm64, win32-x64).
pub fn target() -> String {
  "\{platform()}-\{arch()}"
}

///|
fn parsed(b : Bytes) -> Json? {
  if b.length() == 0 {
    return None
  }
  Some(@json.parse(@utf8.decode_lossy(b))) catch {
    _ => None
  }
}

///|
/// The machine as Node's os module says it: `{cpus: [{model, speed, times}], totalmem, freemem, loadavg, uptime, rss,
/// footprint}` (the last two this process's).
pub fn machine() -> Json {
  parsed(machine_ffi()).unwrap_or(Json::object({}))
}

///|
/// Whether `path` is a file that can be run (a regular file with an execute bit; on Windows, a file).
pub fn executable(path : String) -> Bool {
  executable_ffi(cstr(path)) != 0
}

///|
/// The free and whole size of the disk `path` is on (`{free, total}`).
pub fn disk_of(path : String) -> (Double, Double)? {
  match parsed(disk_of_ffi(cstr(path))) {
    Some({ "free": Number(f, ..), "total": Number(t, ..), .. }) => Some((f, t))
    _ => None
  }
}

///|
/// This machine's addresses on its networks, none of its loopback: `[{name, address, family}]`.
pub fn lan_addrs() -> Array[Json] {
  match parsed(lan_addrs_ffi()) {
    Some(Array(xs)) => xs
    _ => []
  }
}

///|
pub fn parent_pid() -> Int {
  parent_pid_ffi()
}

///|
pub fn pid_alive(pid : Int) -> Bool {
  pid_alive_ffi(pid) != 0
}

///|
/// A signal's number as sys.c takes it.
fn signal_code(name : String) -> Int {
  match name {
    "SIGHUP" => 1
    "SIGINT" => 2
    "SIGKILL" => 9
    "SIGUSR1" => 101
    "SIGUSR2" => 102
    "0" => 0
    _ => 15
  }
}

///|
/// `process.kill(group ? -pid : pid, signal)`; on Windows the process ended (its tree with `group`). False where it
/// was not sent (no such process).
pub fn kill(pid : Int, signal : String, group? : Bool = false) -> Bool {
  kill_ffi(pid, signal_code(signal), if group { 1 } else { 0 }) == 0
}

///|
/// A lock held (`file_lock`): let go with `FileLock::release`.
pub struct FileLock {
  priv handle : Int64
  priv mut held : Bool
}

///|
pub fn FileLock::release(self : FileLock) -> Unit {
  if self.held {
    self.held = false
    ignore(file_unlock_ffi(self.handle))
  }
}

///|
pub(all) suberror SysError {
  SysError(String)
}

///|
/// archive.rs `file_lock`: the lock file made (0600, never truncated) and an exclusive lock taken on it, waited for on a
/// thread of sys.c's; the program goes on meanwhile.
pub async fn file_lock(host : @host.Host, path : String) -> FileLock {
  let done : @effect.Deferred[Bytes] = @effect.Deferred::new()
  let id = host.sys_listen(b => ignore(done.succeed(b)))
  file_lock_ffi(id, cstr(path))
  let told = done.wait()
  host.sys_done(id)
  let text = @utf8.decode_lossy(told[1:])
  if told.length() > 0 && told[0] == b'1' {
    let handle = @string.parse_int64(text) catch { _ => raise SysError("no lock: \{text}") }
    { handle, held: true }
  } else {
    raise SysError(text)
  }
}

///|
/// The process at the other end of a connected Unix socket (its descriptor): `{pid, auditToken}`.
pub fn peer_process(fd : Int) -> Json? {
  parsed(peer_process_ffi(fd))
}

///|
/// What each of `pids` has used so far (macOS): `{cpuNs, footprint, wakeups, energyNj, diskRead, diskWritten}`, none
/// for one not read.
pub fn process_usage(pids : Array[Int]) -> Array[Json?] {
  pids.map(p => parsed(process_usage_ffi(p)))
}

///|
/// Where a child's stdout or stderr goes.
pub(all) enum Sink {
  Ignored
  Piped
  Appended(String)
}

///|
/// What a child said or did.
pub(all) enum ProcEvent {
  Out(Bytes)
  Err(Bytes)
  /// Its end: its code, or the signal that ended it.
  Exit(Int?, String?)
}

///|
/// A child started (`spawn`).
pub struct Proc {
  pid : Int
  priv host : @host.Host
  priv id : Int64
  priv stdin : Int64
  /// What it says, in order, its end last (once its output's pipes are closed too).
  events : @effect.Queue[ProcEvent]
}

///|
/// A child: `program` with `args`, `env` (none: this one's), in `cwd` (none: this one's), its stdin a pipe
/// (`stdin_piped`) or nothing, stdout and stderr as `stdout` and `stderr` say, in a group of its own with `group`
/// (Windows: CREATE_NEW_PROCESS_GROUP), as Node's `spawn` with `detached`.
pub fn spawn(
  host : @host.Host,
  program : String,
  args : Array[String],
  env? : Array[(String, String)],
  cwd? : String,
  stdin_piped? : Bool = false,
  stdout? : Sink = Ignored,
  stderr? : Sink = Ignored,
  group? : Bool = false,
) -> Proc raise SysError {
  let events : @effect.Queue[ProcEvent] = @effect.Queue::unbounded()
  let pending = Ref(
    1 +
    (if stdout is Piped { 1 } else { 0 }) +
    (if stderr is Piped { 1 } else { 0 }),
  )
  let ended : Ref[ProcEvent?] = Ref(None)
  let listened = Ref(0L)
  let close_one = () => {
    pending.val -= 1
    if pending.val == 0 {
      if ended.val is Some(e) {
        ignore(events.try_offer(e))
      }
      host.sys_done(listened.val)
    }
  }
  let id = host.sys_listen(b => {
    if b.length() == 0 {
      return
    }
    let rest = b[1:].to_owned()
    match b[0] {
      b'o' => ignore(events.try_offer(Out(rest)))
      b'e' => ignore(events.try_offer(Err(rest)))
      b'O' | b'E' => close_one()
      b'x' => {
        let text = @utf8.decode_lossy(rest)
        let (code, signal) = match text.find(" ") {
          Some(i) => (head(text, i), tail(text, i + 1))
          None => (text, "")
        }
        let code = if code == "-" { None } else { Some(@string.parse_int(code) catch { _ => -1 }) }
        ended.val = Some(Exit(code, if signal == "" { None } else { Some(signal) }))
        close_one()
      }
      _ => ()
    }
  })
  listened.val = id
  let env_bytes = match env {
    Some(kvs) => nul_joined(kvs.map(kv => "\{kv.0}=\{kv.1}"))
    None => b""
  }
  let mode = (s : Sink) => match s {
    Ignored => 0
    Piped => 1
    Appended(_) => 2
  }
  let file = (s : Sink) => match s {
    Appended(p) => cstr(p)
    _ => cstr("")
  }
  let out = FixedArray::make(2, -1L)
  let why = FixedArray::make(512, b'\x00')
  let pid = spawn_ffi(
    id,
    cstr(resolved_program(program, env)),
    nul_joined(args),
    env_bytes,
    cstr(cwd.unwrap_or("")),
    if stdin_piped { 1 } else { 0 },
    mode(stdout),
    mode(stderr),
    file(stdout),
    file(stderr),
    if group { 1 } else { 0 },
    out,
    why,
  )
  if pid < 0 {
    host.sys_done(id)
    let n = out[0].to_int()
    let said = Bytes::makei(n, i => why[i])
    raise SysError(@utf8.decode_lossy(said))
  }
  { pid, host, id, stdin: out[1], events }
}

///|
/// A command named bare (no directory) as the child is started with it: where the PATH it is given (else this
/// process's) has it, else the system's own directories (/usr/bin, /bin, /usr/sbin, /sbin: a station started with a
/// PATH of none of them, as a test's with Node kept out, still runs `ps`, `lsof`, `git`); as given where none has it,
/// or on Windows (CreateProcess's own search).
fn resolved_program(program : String, env : Array[(String, String)]?) -> String {
  if is_windows() || program.contains("/") || program == "" {
    return program
  }
  let given = match env {
    Some(kvs) =>
      match kvs.iter().find_first(kv => kv.0 == "PATH") {
        Some(kv) => Some(kv.1)
        None => None
      }
    None => env_get("PATH")
  }
  let dirs : Array[String] = match given {
    Some(p) => p.split(":").map(d => if d.is_empty() { "." } else { d.to_owned() }).collect()
    None => []
  }
  for d in [..dirs, "/usr/bin", "/bin", "/usr/sbin", "/sbin"] {
    let at = d + "/" + program
    if executable(at) {
      return at
    }
  }
  program
}

///|
/// Writes `bytes` to its stdin; false where it is closed.
pub fn Proc::write(self : Proc, bytes : Bytes) -> Bool {
  self.stdin >= 0L && handle_write_ffi(self.stdin, bytes) != 0
}

///|
/// Closes its stdin.
pub fn Proc::end_input(self : Proc) -> Unit {
  if self.stdin >= 0L {
    ignore(handle_close_ffi(self.stdin))
  }
}

///|
/// Waits for its end, gathering what it said: (code, signal, stdout, stderr).
pub async fn Proc::finished(self : Proc) -> (Int?, String?, Bytes, Bytes) {
  ignore(self.host)
  ignore(self.id)
  let out = @buffer.Buffer()
  let err = @buffer.Buffer()
  while true {
    match self.events.take() {
      Out(b) => out.write_bytes(b)
      Err(b) => err.write_bytes(b)
      Exit(code, signal) => return (code, signal, out.to_bytes(), err.to_bytes())
    }
  }
  (None, None, out.to_bytes(), err.to_bytes())
}

///|
/// Each line read from descriptor `fd` (its end not in it), given to `line` as it comes, `ended` once it is closed.
pub fn read_lines(host : @host.Host, fd : Int, line : (String) -> Unit, ended : () -> Unit) -> Unit {
  let listened = Ref(0L)
  let id = host.sys_listen(b => {
    if b.length() == 0 {
      return
    }
    match b[0] {
      b'l' => line(@utf8.decode_lossy(b[1:]))
      b'z' => {
        host.sys_done(listened.val)
        ended()
      }
      _ => ()
    }
  })
  listened.val = id
  read_lines_ffi(id, fd)
}

///|
/// The signals a station is ended or told by (SIGTERM, SIGINT, SIGHUP, SIGUSR1, SIGUSR2), each given to `told` by its
/// name as it comes.
pub fn on_signals(host : @host.Host, told : (String) -> Unit) -> Unit {
  let id = host.sys_listen(b => if b.length() > 0 && b[0] == b's' { told(@utf8.decode_lossy(b[1:])) })
  signals_ffi(id, 0)
}

///|
/// Those signals ignored: a launcher tells the station on its control line instead.
pub fn ignore_signals() -> Unit {
  signals_ffi(0L, 1)
}
