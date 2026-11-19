// The agents' side (P5-2): what the drivers (station/mb/src/agent_drivers) wait on and ask of the machine, made real.
// The drivers are written as the TypeScript's promises are, on a loop of their own (`Loop`, `Later`): its continuations
// are run here, on the station's runtime, each time something outside settled one of them (`Pump::kick`), and its
// timers at their time on the wall's clock (a fiber that sleeps until the first is due). What they ask of the machine
// (`Machine`: its files, its processes, a runner's socket) is answered by the drive's calls, live_p5_2_sys.c's and the
// shell's sockets (`unix.open`, `tcp.read`, `tcp.write`, `tcp.end`, `tcp.close`).

///|
#borrow(path, data)
extern "C" fn live_append_ffi(path : Bytes, data : Bytes) -> Int = "sflive_append"

///|
#borrow(path, data)
extern "C" fn live_write_ffi(path : Bytes, data : Bytes, mode : Int) -> Int = "sflive_write"

///|
/// A file written whole as `sflive_write`, or only where none is (`excl`: O_EXCL, Win32's CREATE_NEW): 0, else the
/// system's error number (EEXIST where it is there).
#borrow(path, data)
extern "C" fn live_write_flags_ffi(path : Bytes, data : Bytes, mode : Int, excl : Int) -> Int = "sflive_write_flags"

///|
#borrow(target, path)
extern "C" fn live_symlink_ffi(target : Bytes, path : Bytes) -> Int = "sflive_symlink"

///|
#borrow(from, to)
extern "C" fn live_link_ffi(from : Bytes, to : Bytes) -> Int = "sflive_link"

///|
#borrow(path)
extern "C" fn live_rm_tree_ffi(path : Bytes) -> Int = "sflive_rm_tree"

///|
extern "C" fn live_start_time_ffi(pid : Int) -> Double = "sflive_start_time"

///|
extern "C" fn live_group_alive_ffi(pgid : Int) -> Int = "sflive_group_alive"

///|
extern "C" fn live_cloexec_all_ffi() -> Int = "sflive_cloexec_all"

///|
/// What this process holds kept from what it starts (the launcher's descriptors are given it inheritable): how many.
pub fn keep_descriptors() -> Int {
  live_cloexec_all_ffi()
}

///|
fn live_c(s : String) -> Bytes {
  let b = @utf8.encode(s)
  let out = Bytes::makei(b.length() + 1, i => if i < b.length() { b[i] } else { b'\x00' })
  out
}

///|
/// Whether process group `pgid` has a process left.
pub fn group_alive(pgid : Int) -> Bool {
  live_group_alive_ffi(pgid) != 0
}

///|
/// When process `pid` started (ms since the epoch), where the system says.
pub fn start_time_of(pid : Int) -> Double? {
  let t = live_start_time_ffi(pid)
  if t < 0.0 {
    None
  } else {
    Some(t)
  }
}

///|
/// Text appended to a file (made where it is not).
pub fn append_text(path : String, text : String) -> Bool {
  live_append_ffi(live_c(path), @utf8.encode(text)) == 0
}

///|
/// A file written whole (its mode on Unix; 0: 0644).
pub fn write_text_mode(path : String, text : String, mode : Int) -> Bool {
  live_write_ffi(live_c(path), @utf8.encode(text), mode) == 0
}

///|
/// A tree removed, what is not there taken as gone.
pub fn remove_tree(path : String) -> Bool {
  live_rm_tree_ffi(live_c(path)) == 0
}

// ── converting between the three JSONs the packages speak ──

///|
fn jv_of(j : Json) -> @jsjson.JValue {
  @jsjson.JValue::of_json(j)
}

///|
fn p52_json_of_jv(v : @jsjson.JValue) -> Json {
  v.to_json()
}

///|
fn jfield(v : Json, k : String) -> Json {
  match v {
    Object(m) => m.get(k).unwrap_or(Json::null())
    _ => Json::null()
  }
}

///|
fn jtext(v : Json, k : String) -> String? {
  match jfield(v, k) {
    String(s) => Some(s)
    _ => None
  }
}

///|
fn jnum_of(v : Json, k : String) -> Double? {
  match jfield(v, k) {
    Number(n, ..) => Some(n)
    _ => None
  }
}

///|
fn jitems(v : Json) -> Array[Json] {
  match v {
    Array(a) => a
    _ => []
  }
}

///|
/// At most `n` of `s`'s characters (what a log line shows of a long one).
fn clip(s : String, n : Int) -> String {
  if s.length() <= n {
    s
  } else {
    s[:n].to_owned()
  }
}

///|
fn jobj_of(pairs : Array[(String, Json)]) -> Json {
  let m : Map[String, Json] = Map([])
  for p in pairs {
    m[p.0] = p.1
  }
  Json::object(m)
}

///|
fn jstr(s : String) -> Json {
  Json::string(s)
}

///|
fn jn(n : Double) -> Json {
  Json::number(n)
}

///|
fn ji(n : Int) -> Json {
  Json::number(n.to_double())
}

///|
fn jb(b : Bool) -> Json {
  Json::boolean(b)
}

///|
fn jopt(s : String?) -> Json {
  match s {
    Some(t) => Json::string(t)
    None => Json::null()
  }
}

///|
/// The station's language, for what a driver says by its words' key (`Said("station.…")`): set as P5-2 starts.
let p52_lang_fn : Ref[() -> String] = Ref(() => "zh")

///|
/// What an error says: the drivers', the store's, the hub's, a thrown one's. A driver's words said by their key
/// (claude.ts `tr(stationLang(), …)`) in the station's language.
fn said_of(e : Error) -> String {
  match e {
    @agent_drivers.Failed(m) => m
    @agent_drivers.Said(m) => if m.has_prefix("station.") { tr((p52_lang_fn.val)(), m) } else { m }
    @agent_drivers.RenewRefused(m) => m
    @accounts_oauth.Said(m)
    | @accounts_oauth.RenewRefused(_, m)
    | @accounts_oauth.Failed(m)
    | @accounts_oauth.FsError(_, m)
    | @accounts_oauth.JsonError(m) => m
    @accounts_pool.Thrown(_, _) => @accounts_pool.message_of(e)
    @session_hub.Refused(m) => m
    BusError(m) => m
    LiveError(m) => m
    @store_sessions.StoreError(m, _) => m
    @store_threads.StoreError(m) => m
    @session_chats.Thrown(_, m) => m
    @session_storage.Thrown(kind, said) => jtext(said, "message").unwrap_or(kind)
    @mcp_tools.Failed(m) => m
    @api_routes.Thrown(kind, said) => match said { Obj(_) => match said.get("message") { Some(Str(m)) => m; _ => kind }; _ => kind }
    @drive.FsError(f) => f.message
    @wire.ShellError(m) => m
    @api_routes.Refused(_, m) => m
    Failure(m) => m
    _ => @gate.words_of(e)
  }
}

///|
pub(all) suberror LiveError {
  LiveError(String)
}

///|
/// Its words, as what takes an error by its text says it (a door's `{error}`, jobs_host `words_of`).
pub impl Show for LiveError with output(self, logger) {
  match self {
    LiveError(s) => logger.write_string(s)
  }
}

// ── the drivers' loop on the station's runtime ──

///|
/// The drivers' loop (agent_drivers `Loop`), run on the station's runtime: what is queued run, and what is due, each time
/// something from outside settled one of its `Later`s (`kick`), and at its first timer's time.
priv struct Pump {
  host : @host.Host
  lp : @agent_drivers.Loop
  /// The first timer's time it sleeps until, and that sleep's number (a later one replaces it).
  mut armed : Double?
  mut armed_seq : Int
  mut kicking : Bool
}

///|
fn Pump::new(host : @host.Host) -> Pump {
  { host, lp: @agent_drivers.Loop::new(now=wall_ms().to_double()), armed: None, armed_seq: 0, kicking: false }
}

///|
/// The loop run to now: its queue, and each timer due by the wall's clock, then its next timer slept for.
fn Pump::kick(self : Pump) -> Unit {
  if self.kicking {
    return
  }
  self.kicking = true
  self.lp.advance(wall_ms().to_double())
  self.kicking = false
  let mut first : Double? = None
  for t in self.lp.timers {
    match first {
      Some(f) if f <= t.0 => ()
      _ => first = Some(t.0)
    }
  }
  match first {
    None => self.armed = None
    Some(at) =>
      match self.armed {
        Some(a) if a <= at => ()
        _ => {
          self.armed = Some(at)
          self.armed_seq += 1
          let seq = self.armed_seq
          let wait = at - wall_ms().to_double()
          ignore(
            self.host.rt.fork_daemon("drivers' timer", on_error=e => @host.note("drivers' timer failed: \{e}"), async fn() {
              // timer: a wait of the drivers' own (their timeouts, their retries' backoff, a grace), at its time
              @effect.sleep(if wait < 1.0 { 1 } else { wait.ceil().to_int() })
              if self.armed_seq == seq {
                self.armed = None
                self.kick()
              }
            }),
          )
        }
      }
  }
}

///|
/// What `l` comes to, waited for on the station's runtime.
async fn[T] Pump::wait(self : Pump, l : @agent_drivers.Later[T]) -> T {
  let d : @effect.Deferred[T] = @effect.Deferred::new()
  l.on(r => match r {
    Ok(v) => ignore(d.succeed(v))
    Err(e) => ignore(d.fail(e))
  })
  self.kick()
  d.wait()
}

///|
/// A `Later` of the loop that `f` (run on the station's runtime) settles.
fn[T] Pump::later(self : Pump, name : String, f : async () -> T) -> @agent_drivers.Later[T] {
  let l : @agent_drivers.Later[T] = @agent_drivers.Later::new(self.lp)
  ignore(
    self.host.rt.fork_quiet(name~, async fn() {
      let r = try {
        Ok(f())
      } catch {
        e => Err(e)
      }
      match r {
        Ok(v) => l.resolve(v)
        Err(e) => l.reject(driver_error_of(e))
      }
      self.kick()
    }),
  )
  l
}

///|
/// What failed on the station's side, as the drivers tell failures apart (agent_drivers `DriverError`): a sign-in's
/// renewal refused (`ClaudeDriver::open` asks for a login again by it), words for people, or any other failure by its
/// words alone (never `Error: …` or a constructor's path, as a log line said them).
fn driver_error_of(e : Error) -> Error {
  match e {
    @agent_drivers.Failed(_) | @agent_drivers.Said(_) | @agent_drivers.RenewRefused(_) => e
    @api_routes.Thrown("RenewRefused", _)
    | @accounts_pool.Thrown("RenewRefused", _)
    | @accounts_oauth.RenewRefused(_, _) => @agent_drivers.RenewRefused(said_of(e))
    @api_routes.Thrown("Said", _) | @accounts_pool.Thrown("Said", _) | @accounts_oauth.Said(_) =>
      @agent_drivers.Said(said_of(e))
    // (a file system's by its code, as the machine's calls give it: `fs_failed`)
    @drive.FsError(_) => fs_failed(e)
    other => @agent_drivers.Failed(said_of(other))
  }
}

///|
fn[T] lok(lp : @agent_drivers.Loop, v : T) -> @agent_drivers.Later[T] {
  @agent_drivers.Later::ok(lp, v)
}

///|
fn[T] lfail(lp : @agent_drivers.Loop, e : Error) -> @agent_drivers.Later[T] {
  @agent_drivers.Later::fail(lp, fs_failed(e))
}

///|
/// What failed on the file system, as the drivers tell failures apart (Node's code: `ENOENT`…).
fn fs_failed(e : Error) -> Error {
  match e {
    @drive.FsError(f) => @agent_drivers.Failed(f.code)
    other => @agent_drivers.Failed(said_of(other))
  }
}

///|
/// The machine as the drivers ask it (agent_drivers `Machine`): the drive's calls and this program's, each settled at
/// once, a runner's socket through the shell.
fn Pump::machine(self : Pump) -> @agent_drivers.Machine {
  let lp = self.lp
  {
    lp,
    sep: sep(),
    socket_visible: !is_windows(),
    says_leave: is_windows(),
    read_dir: p => match attempt(() => @drive.names(p)) {
      Ok(names) => lok(lp, names)
      Err(e) => lfail(lp, e)
    },
    read_file: p => match attempt(() => @drive.read_all(p)) {
      Ok(b) => lok(lp, @utf8.decode_lossy(b))
      Err(e) => lfail(lp, e)
    },
    mtime: p => match attempt(() => @drive.lstat(p)) {
      Ok(st) => lok(lp, Some(st.mtime_ms))
      Err(_) => lok(lp, None)
    },
    size: p => match attempt(() => @drive.stat(p)) {
      Ok(st) => lok(lp, Some(st.size.to_int()))
      Err(_) => lok(lp, None)
    },
    read_at: (p, at, length) => match attempt(() => @drive.read_part(p, at.to_double(), length.to_double())) {
      Ok((bytes, _, _)) => lok(lp, bytes)
      Err(e) => lfail(lp, e)
    },
    remove: p => match attempt(() => @drive.unlink(p)) {
      Ok(_) => lok(lp, ())
      Err(@drive.FsError(f)) if f.code == "ENOENT" => lok(lp, ())
      Err(e) => lfail(lp, e)
    },
    there: p => lok(lp, attempt(() => @drive.lstat(p)) is Ok(_)),
    is_file: p => lok(lp, attempt(() => @drive.stat(p)) is Ok(st) && st.file),
    realpath: p => lok(lp, attempt(() => @drive.realpath(p)).to_option()),
    make_dir: p => match attempt(() => @drive.mkdir(p, true)) {
      Ok(_) => lok(lp, ())
      Err(e) => lfail(lp, e)
    },
    link: (to_what, p) => {
      let e = live_symlink_ffi(live_c(to_what), live_c(p))
      if e == 0 {
        lok(lp, ())
      } else {
        @agent_drivers.Later::fail(lp, @agent_drivers.Failed(if e == 17 { "EEXIST" } else { "EIO" }))
      }
    },
    stat: (p, follow) => {
      let got = if follow { attempt(() => @drive.stat(p)) } else { attempt(() => @drive.lstat(p)) }
      match got {
        Ok(st) =>
          lok(lp, Some({ dev: st.dev, ino: 0.0, size: st.size, mtime: st.mtime_ms, file: st.file, directory: st.dir, symlink: st.link }))
        Err(_) => lok(lp, None)
      }
    },
    write_file: (p, text, private) => {
      ignore(attempt(() => @drive.mkdir(@nodepath.dirname(sep(), p), true)))
      if write_text_mode(p, text, if private { 0o600 } else { 0 }) {
        lok(lp, ())
      } else {
        @agent_drivers.Later::fail(lp, @agent_drivers.Failed("EIO"))
      }
    },
    append_file: (p, text) => if append_text(p, text) {
      lok(lp, ())
    } else {
      @agent_drivers.Later::fail(lp, @agent_drivers.Failed("EIO"))
    },
    remove_tree: p => {
      ignore(remove_tree(p))
      lok(lp, ())
    },
    rename: (from, to) => match attempt(() => @drive.rename(from, to)) {
      Ok(_) => lok(lp, ())
      Err(e) => lfail(lp, e)
    },
    copy: (from, to) => match attempt(() => copy_over(from, to)) {
      Ok(_) => lok(lp, ())
      Err(e) => lfail(lp, e)
    },
    copy_file: (from, to) => match attempt(() => copy_file_over(from, to)) {
      Ok(_) => lok(lp, ())
      Err(e) => lfail(lp, e)
    },
    hard_link: (from, to) => {
      let e = live_link_ffi(live_c(from), live_c(to))
      if e == 0 {
        lok(lp, ())
      } else {
        @agent_drivers.Later::fail(lp, @agent_drivers.Failed(if e == 17 { "EEXIST" } else { "EXDEV" }))
      }
    },
    link_path: (to_what, p) => {
      let e = live_symlink_ffi(live_c(to_what), live_c(p))
      if e == 0 {
        lok(lp, ())
      } else {
        @agent_drivers.Later::fail(lp, @agent_drivers.Failed(if e == 17 { "EEXIST" } else { "EIO" }))
      }
    },
    pid_alive: pid => pid > 0 && pid_alive(pid),
    group_alive: pgid => group_alive(pgid),
    start_time: pid => lok(lp, start_time_of(pid)),
    connect: (p, events) => self.connect(p, events),
    sleep: ms => {
      let l : @agent_drivers.Later[Unit] = @agent_drivers.Later::new(lp)
      ignore(lp.after(ms, () => l.resolve(())))
      self.kick()
      l
    },
    now: () => wall_ms().to_double(),
    log: (level, area, message, fields) => live_log(level, area, message, p52_json_of_jv(fields)),
  }
}

///|
/// A line of the station's log (ops/log.ts): stderr, which the launcher keeps as stillfail.log.
fn live_log(level : String, area : String, message : String, fields : Json) -> Unit {
  slice_log(level, area, message, fields)
}

///|
/// A connection to a runner's socket (its path: a Unix socket, a Windows named pipe), its events told on the loop.
fn Pump::connect(self : Pump, path : String, events : @agent_drivers.SocketEvents) -> @agent_drivers.Socket {
  let conn : Ref[@host.Conn?] = Ref(None)
  let gone = Ref(false)
  let ended = Ref(false)
  let writes : @effect.Queue[Bytes?] = @effect.Queue::unbounded()
  let host = self.host
  let close_once = () => if !gone.val {
    gone.val = true
    match conn.val {
      Some(c) => ignore(host.rt.fork_quiet(name="runner close", async fn() { c.socket.destroy() }))
      None => ()
    }
    (events.closed)()
    self.kick()
  }
  ignore(
    host.rt.fork_daemon("runner socket", on_error=e => @host.note("runner socket failed: \{e}"), async fn() {
      match (try { Ok(host.unix_open(path)) } catch { e => Err(e) }) {
        Ok(c) => {
          let id = c.id
          conn.val = Some(c)
          if gone.val {
            c.socket.destroy()
            return
          }
          (events.connected)()
          self.kick()
          // what is written goes in order
          ignore(
            host.rt.fork_quiet(name="runner socket out", async fn() {
              while !gone.val {
                match writes.take() {
                  Some(b) =>
                    host.tcp_write(id, b) catch {
                      _ => break
                    }
                  None => {
                    host.tcp_end(id) catch { _ => () }
                    break
                  }
                }
              }
            }),
          )
          while !gone.val {
            let bytes = host.tcp_read(id) catch {
              e => {
                if !gone.val {
                  (events.error)(said_of(e))
                }
                break
              }
            }
            guard bytes is Some(bytes) else { break }
            if !gone.val {
              (events.data)(@utf8.decode_lossy(bytes))
              self.kick()
            }
          }
          close_once()
        }
        _ => {
          if !gone.val {
            (events.error)("ENOENT")
          }
          close_once()
        }
      }
    }),
  )
  {
    write: text => if !gone.val && !ended.val { ignore(writes.try_offer(Some(@utf8.encode(text)))) },
    end: () => if !gone.val && !ended.val {
      ended.val = true
      ignore(writes.try_offer(None))
    },
    destroy: () => close_once(),
    writable: () => !gone.val && !ended.val,
    destroyed: () => gone.val,
  }
}

///|
/// node's `copyFile`: `to` replaced where it is there (the drive's copy makes a new file only), never `from` itself.
fn copy_file_over(from : String, to : String) -> Unit raise {
  ignore(@drive.stat(from))
  if from != to {
    ignore(attempt(() => @drive.unlink(to)))
  }
  @drive.copy_file(from, to)
}

///|
/// node's `cp(from, to, { recursive: true })`: a folder copied whole into `to`, each file replacing what is there.
fn copy_over(from : String, to : String) -> Unit raise {
  if @drive.stat(from).dir {
    @drive.mkdir(to, true)
    for e in @drive.readdir(from) {
      copy_over(path([from, e.name]), path([to, e.name]))
    }
  } else {
    copy_file_over(from, to)
  }
}
