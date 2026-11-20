// runner.ts: agent processes kept by runners (native/runner), each the child of a `stillfail-runner` that outlives the
// station. What a runner's info file says, how one is started and found alive, its files swept once it is gone, and
// one connection to it: its messages a line of JSON each, stdout and stderr in base64, each whole line handed on in
// order and acknowledged once handled, so a station that takes it up after this one reads exactly the rest.
//
// What it does with the machine (a directory read, a file's time, a process looked at, a socket) is the `Machine`'s it
// is given: the station's, or a test's.

///|
/// What a runner's info file says (`RunnerInfo`), as the JSON it is.
pub(all) struct RunnerInfo {
  json : JValue
}

///|
pub fn RunnerInfo::id(self : RunnerInfo) -> String {
  str_at(Some(self.json), "id").unwrap_or("")
}

///|
pub fn RunnerInfo::runner(self : RunnerInfo) -> Int {
  num_at(Some(self.json), "runner").unwrap_or(0.0).to_int()
}

///|
pub fn RunnerInfo::pgid(self : RunnerInfo) -> Int {
  num_at(Some(self.json), "pgid").unwrap_or(0.0).to_int()
}

///|
pub fn RunnerInfo::started_at(self : RunnerInfo) -> Double? {
  num_at(Some(self.json), "startedAt")
}

///|
pub fn RunnerInfo::socket(self : RunnerInfo) -> String {
  str_at(Some(self.json), "socket").unwrap_or("")
}

///|
pub fn RunnerInfo::args(self : RunnerInfo) -> Array[String] {
  strings_in(get(Some(self.json), "args"))
}

///|
pub fn RunnerInfo::keeps(self : RunnerInfo) -> Bool {
  is_true(Some(self.json), "keeps")
}

///|
/// How a process ended (`Exit`).
pub(all) struct Exit {
  code : Int?
  signal : String?
}

///|
/// What `stat` says of a path.
pub(all) struct FileStat {
  dev : Double
  ino : Double
  size : Double
  mtime : Double
  file : Bool
  directory : Bool
  symlink : Bool
}

///|
/// A connection's events.
pub(all) struct SocketEvents {
  connected : () -> Unit
  data : (String) -> Unit
  error : (String) -> Unit
  closed : () -> Unit
}

///|
/// A connection as the machine gives it.
pub(all) struct Socket {
  write : (String) -> Unit
  end : () -> Unit
  destroy : () -> Unit
  writable : () -> Bool
  destroyed : () -> Bool
}

///|
/// What the drivers ask of the machine.
pub(all) struct Machine {
  lp : Loop
  /// the path's separator (`/`, `\` on Windows)
  sep : String
  /// a runner's socket is a file that can be looked at (not a pipe: `platform.runnerSocketVisible`)
  socket_visible : Bool
  /// a runner is asked to close a connection let go (a pipe's: `platform.runnerSaysLeave`)
  says_leave : Bool
  /// the names in a directory (an error, its code, where it cannot be read)
  read_dir : (String) -> Later[Array[String]]
  read_file : (String) -> Later[String]
  /// a file's modification time (lstat), none where it is not there
  mtime : (String) -> Later[Double?]
  /// a file's size (stat), none where it is not there
  size : (String) -> Later[Int?]
  /// `length` bytes of a file from `at` (fewer at its end)
  read_at : (String, Int, Int) -> Later[Bytes]
  remove : (String) -> Later[Unit]
  /// `fs.access`
  there : (String) -> Later[Bool]
  /// a file there and a file (`stat().isFile()`)
  is_file : (String) -> Later[Bool]
  /// `fs.realpath`, none where it fails
  realpath : (String) -> Later[String?]
  /// `mkdir -p`
  make_dir : (String) -> Later[Unit]
  /// a hard link made, else a symbolic one (`link(...).catch(() => symlink(...))`)
  link : (String, String) -> Later[Unit]
  /// a file's or a directory's facts (`stat`, `lstat` where `follow` is false), none where it is not there
  stat : (String, Bool) -> Later[FileStat?]
  /// a file written whole (`writeFile`), a private one (ops/files.ts `writePrivateSoon`)
  write_file : (String, String, Bool) -> Later[Unit]
  /// appended to (`appendFile`)
  append_file : (String, String) -> Later[Unit]
  /// `rm -rf`
  remove_tree : (String) -> Later[Unit]
  /// `rename`
  rename : (String, String) -> Later[Unit]
  /// `cp -R`, times kept (`cp(..., { recursive: true, preserveTimestamps: true })`)
  copy : (String, String) -> Later[Unit]
  /// `copyFile`
  copy_file : (String, String) -> Later[Unit]
  /// a hard link alone (`link`)
  hard_link : (String, String) -> Later[Unit]
  /// a link to a directory or file (ops/links.ts `link`, a junction on Windows)
  link_path : (String, String) -> Later[Unit]
  /// `process.kill(pid, 0)` did not throw
  pid_alive : (Int) -> Bool
  /// `process.kill(-pgid, 0)` did not throw, or threw EPERM
  group_alive : (Int) -> Bool
  /// when a process started, as the system says (`platform.startTimeOf`)
  start_time : (Int) -> Later[Double?]
  connect : (String, SocketEvents) -> Socket
  /// `wall.sleep`
  sleep : (Double) -> Later[Unit]
  /// `wall.now`
  now : () -> Double
  /// a log line (level, at, message, fields)
  log : (String, String, String, JValue) -> Unit
}

///|
pub fn Machine::join(self : Machine, parts : Array[String]) -> String {
  parts.join(self.sep)
}

///|
/// `<data>/run/runners`.
pub fn runners_dir(m : Machine, data : String) -> String {
  m.join([data, "run", "runners"])
}

///|
/// A person's terminal's runner, not an agent's: its id's start.
let terminal_runner = "term-"

///|
pub fn is_terminal_runner(id : String) -> Bool {
  id.has_prefix(terminal_runner)
}

///|
/// Whether a runner of before still keeps its process: its socket there; a pipe's info file says so (`listeningSoon`).
pub fn listening_soon(m : Machine, info : RunnerInfo) -> Later[Bool] {
  if !m.socket_visible {
    Later::ok(m.lp, true)
  } else {
    m.there(info.socket())
  }
}

///|
/// What an info file says, if its runner is alive (`alive`).
pub fn alive_in(m : Machine, text : String) -> RunnerInfo? {
  match parse_json(text) {
    Some(Obj(_) as j) =>
      match num_at(Some(j), "runner") {
        Some(pid) if m.pid_alive(pid.to_int()) => Some({ json: j })
        _ => None
      }
    _ => None
  }
}

///|
/// Runners of before alive now (`liveRunners`); `strict`: a directory that cannot be read but is not missing fails.
pub fn live_runners(m : Machine, data : String, strict? : Bool = false) -> Later[Array[RunnerInfo]] {
  let dir = runners_dir(m, data)
  m
  .read_dir(dir)
  .recover(e => if strict && words_of(e) != "ENOENT" {
    Later::fail(m.lp, e)
  } else {
    Later::ok(m.lp, [])
  })
  .bind(names => {
    let files = names.filter(f => f.has_suffix(".json"))
    all(
      m.lp,
      files.map(f => m
        .read_file(m.join([dir, f]))
        .map(t => Some(t))
        .recover(_ => Later::ok(m.lp, None))),
    ).map(texts => texts.filter_map(t => match t {
      Some(text) => alive_in(m, text)
      None => None
    }))
  })
}

///|
/// Runner `id`'s, its file alone, if its runner is alive (`runnerOf`).
pub fn runner_of(m : Machine, data : String, id : String) -> Later[RunnerInfo?] {
  m
  .read_file(m.join([runners_dir(m, data), "\{id}.json"]))
  .map(t => alive_in(m, t))
  .recover(_ => Later::ok(m.lp, None))
}

///|
/// How far a process's start as the system says it may be past its runner's `startedAt`.
let started_slack_ms = 60000.0

///|
/// Whether an info file's runner is alive and is that runner (`liveRunner`).
pub fn live_runner(m : Machine, info : RunnerInfo) -> Later[Bool] {
  if !m.pid_alive(info.runner()) {
    return Later::ok(m.lp, false)
  }
  m
  .start_time(info.runner())
  .recover(_ => Later::ok(m.lp, None))
  .map(started => match (started, info.started_at()) {
    (None, _) | (_, None) => true
    (Some(at), Some(said)) => at <= said + started_slack_ms
  })
}

///|
let runner_files : Array[String] = [".json", ".out", ".err", ".sock"]

///|
/// A runner's files with no info file beside them this long are left over.
let runner_left_ms = 300000.0

///|
/// The files of runners gone removed, and of runners alive that nobody holds where `orphan` ends them; the ids removed
/// (`sweepRunners`).
pub fn sweep_runners(
  m : Machine,
  data : String,
  now : Double,
  orphan? : (RunnerInfo) -> Later[Bool],
) -> Later[Array[String]] {
  let dir = runners_dir(m, data)
  m
  .read_dir(dir)
  .map(names => Some(names))
  .recover(_ => Later::ok(m.lp, None))
  .bind(listed => {
    guard listed is Some(names) else { return Later::ok(m.lp, []) }
    let infos = names
      .filter(n => n.has_suffix(".json"))
      .map(n => n.substring(end=n.length() - 5))
    let gone : Array[String] = []
    let remove = (id : String) => each_in_turn(m.lp, runner_files.length(), i => m
      .remove(m.join([dir, "\{id}\{runner_files[i]}"]))
      .recover(_ => done(m.lp))).map(_ => if !gone.contains(id) { gone.push(id) })
    let first = each_in_turn(m.lp, infos.length(), i => {
      let id = infos[i]
      let file = m.join([dir, "\{id}.json"])
      m
      .read_file(file)
      .map(t => Some(t))
      .recover(_ => Later::ok(m.lp, None))
      .bind(text => {
        let info = match text {
          Some(t) =>
            match parse_json(t) {
              Some(Obj(_) as j) if num_at(Some(j), "runner") is Some(_) =>
                Some(RunnerInfo::{ json: j })
              _ => None
            }
          None => None
        }
        match info {
          None =>
            m
            .mtime(file)
            .recover(_ => Later::ok(m.lp, None))
            .bind(at => match at {
              Some(t) if now - t >= runner_left_ms => remove(id)
              _ => done(m.lp)
            })
          Some(info) =>
            live_runner(m, info).bind(alive => if !alive {
              remove(id)
            } else {
              match orphan {
                Some(f) if !is_terminal_runner(id) =>
                  f(info)
                  .recover(_ => Later::ok(m.lp, false))
                  .bind(ended => if ended { remove(id) } else { done(m.lp) })
                _ => done(m.lp)
              }
            })
        }
      })
    })
    first
    .bind(_ => each_in_turn(m.lp, names.length(), i => {
      let name = names[i]
      let ext = match runner_files.search_by(e => e != ".json" && name.has_suffix(e)) {
        Some(k) => Some(runner_files[k])
        None => if name.has_suffix(".tmp") { Some(".tmp") } else { None }
      }
      guard ext is Some(ext) else { return done(m.lp) }
      let id = name.substring(end=name.length() - ext.length())
      if infos.contains(id) || gone.contains(id) {
        return done(m.lp)
      }
      m
      .mtime(m.join([dir, name]))
      .recover(_ => Later::ok(m.lp, None))
      .bind(at => match at {
        Some(t) if now - t >= runner_left_ms =>
          m
          .remove(m.join([dir, name]))
          .recover(_ => done(m.lp))
          .map(_ => if !gone.contains(id) { gone.push(id) })
        _ => done(m.lp)
      })
    }))
    .map(_ => {
      if gone.length() > 0 {
        m.log("info", "agents::runner", "runners gone, their files removed", obj([("count", n(gone.length()))]))
      }
      gone
    })
  })
}

///|
/// A program named by its command that the environment's PATH does not have (`CommandMissing`).
pub fn command_missing(command : String) -> Error {
  Failed("the runner did not start: \{command} is not on PATH")
}

///|
/// The runner's arguments for `program` (`startRunner`, before `niced`).
pub fn runner_args(
  m : Machine,
  data : String,
  id : String,
  cwd : String,
  program : String,
  args : Array[String],
  pty? : (Int, Int),
) -> Array[String] {
  let out = ["--dir", runners_dir(m, data), "--id", id, "--cwd", cwd]
  match pty {
    Some((cols, rows)) => out.append(["--pty", "\{cols}x\{rows}"])
    None => ()
  }
  out.push("--")
  out.push(program)
  out.append(args)
  out
}

///|
/// What a runner said as it started: its info from the ready line, or why it did not start (`startRunner`'s end).
pub fn runner_ready(out : String, err : String) -> RunnerInfo raise {
  for line in out.split("\n") {
    let l = line.to_string()
    if l.has_prefix("{") {
      match parse_json(l) {
        Some(j) =>
          if get(Some(j), "ready") is Some(v) && truthy(v) {
            return { json: j }
          }
        None => raise Failed("the runner said what is not JSON: \{l}")
      }
      break
    }
  }
  let why = @jscase.trim(err)
  raise Failed("the runner did not start: \{if why != "" { why } else { @jscase.trim(out) }}")
}

///|
/// JavaScript's truth of a value.
pub fn truthy(v : JValue) -> Bool {
  @jsjson.jval_truthy(Some(v))
}

///|
/// Whole lines of bytes that come a piece at a time (`Lines`): a line's pieces kept as they came and joined once.
pub struct Lines {
  parts : Array[Bytes]
  mut size : Int
}

///|
pub fn Lines::new() -> Lines {
  { parts: [], size: 0 }
}

///|
/// The lines `bytes` ends, without their newline; what it leaves of one held for the next piece.
pub fn Lines::take(self : Lines, bytes : BytesView) -> Array[Bytes] {
  let lines = []
  let mut from = 0
  for i in 0..<bytes.length() {
    if bytes[i] == b'\n' {
      let last = bytes[from:i]
      if self.parts.length() == 0 {
        lines.push(last.to_owned())
      } else {
        let buf = @buffer.Buffer(size_hint=self.size + last.length())
        for p in self.parts {
          buf.write_bytes(p)
        }
        buf.write_bytesview(last)
        lines.push(buf.to_bytes())
        self.drop()
      }
      from = i + 1
    }
  }
  if from < bytes.length() {
    self.parts.push(bytes[from:].to_owned())
    self.size += bytes.length() - from
  }
  lines
}

///|
pub fn Lines::drop(self : Lines) -> Unit {
  self.parts.clear()
  self.size = 0
}

///|
/// Bytes as Node's `toString("utf8")` reads them.
pub fn utf8_text(bytes : BytesView) -> String {
  @utf8.decode_lossy(bytes)
}

///|
/// A connection to one runner (`RunnerConnection`): each whole line handed to `line` in order, acknowledged once it is
/// done; what comes after `detach` not handled.
pub struct RunnerConnection {
  m : Machine
  info : RunnerInfo
  socket : Socket
  mut carry : String
  out_lines : Lines
  err_lines : Lines
  mut out_at : Int
  mut err_at : Int
  mut acked_out : Int
  mut acked_err : Int
  /// up to where of stdout the runner may give the disk back, told with each ack (none: up to the ack)
  mut keep : Int?
  mut queue : Later[Unit]
  mut left : Bool
  exited : Later[Exit]
  line : (String, String, Int, Int) -> Later[Unit]
  closed : Later[Unit]
}

///|
pub fn RunnerConnection::open(
  m : Machine,
  info : RunnerInfo,
  line : (String, String, Int, Int) -> Later[Unit],
) -> RunnerConnection {
  let conn_ref : Ref[RunnerConnection?] = Ref(None)
  let closed = Later::new(m.lp)
  let socket = m.connect(info.socket(), {
    connected: () => match conn_ref.val {
      Some(c) => c.send(obj([("op", s("attach"))]))
      None => ()
    },
    data: chunk => match conn_ref.val {
      Some(c) => c.heard(chunk)
      None => ()
    },
    error: _ => (),
    closed: () => closed.resolve(()),
  })
  let c = {
    m,
    info,
    socket,
    carry: "",
    out_lines: Lines::new(),
    err_lines: Lines::new(),
    out_at: -1,
    err_at: -1,
    acked_out: 0,
    acked_err: 0,
    keep: None,
    queue: done(m.lp),
    left: false,
    exited: Later::new(m.lp),
    line,
    closed,
  }
  conn_ref.val = Some(c)
  c
}

///|
pub fn RunnerConnection::heard(self : RunnerConnection, chunk : String) -> Unit {
  if self.left {
    return
  }
  self.carry = self.carry + chunk
  while true {
    guard self.carry.find("\n") is Some(i) else { break }
    let text = self.carry.substring(end=i)
    self.carry = self.carry.substring(start=i + 1)
    guard parse_json(text) is Some(message) else { continue }
    match str_at(Some(message), "op") {
      Some("out") => {
        let stream = str_at(Some(message), "stream").unwrap_or("out")
        let at = num_at(Some(message), "at").unwrap_or(0.0).to_int()
        let bytes = @base64.decode_lossy(str_at(Some(message), "data").unwrap_or(""))
        self.data(stream, at, bytes)
      }
      Some("exit") => {
        let code = num_at(Some(message), "code").map(x => x.to_int())
        let signal = str_at(Some(message), "signal")
        self.queue = self.queue.map(_ => self.exited.resolve({ code, signal }))
      }
      _ => ()
    }
  }
}

///|
pub fn RunnerConnection::data(self : RunnerConnection, stream : String, at : Int, bytes : Bytes) -> Unit {
  let err = stream == "err"
  if (if err { self.err_at } else { self.out_at }) < 0 {
    if err {
      self.err_at = at
    } else {
      self.out_at = at
    }
  }
  let lines = if err { self.err_lines } else { self.out_lines }
  for whole in lines.take(bytes) {
    let text = utf8_text(whole)
    let start = if err { self.err_at } else { self.out_at }
    let end = start + whole.length() + 1
    if err {
      self.err_at = end
    } else {
      self.out_at = end
    }
    self.queue = self.queue.bind(_ => (self.line)(stream, text, start, end).map(_ => {
      if err {
        self.acked_err = end
      } else {
        self.acked_out = end
      }
      let ack = [("op", s("ack")), ("out", n(self.acked_out)), ("err", n(self.acked_err))]
      match self.keep {
        Some(k) => ack.push(("keep", n(k)))
        None => ()
      }
      self.send(obj(ack))
    }))
  }
}

///|
pub fn RunnerConnection::send(self : RunnerConnection, message : JValue) -> Unit {
  if (self.socket.writable)() {
    (self.socket.write)(json_text(message) + "\n")
  }
}

///|
/// A line to the process's stdin.
pub fn RunnerConnection::write(self : RunnerConnection, text : String) -> Unit {
  self.send(obj([("op", s("write")), ("data", s(@base64.encode(@utf8.encode(text))))]))
}

///|
pub fn RunnerConnection::close_stdin(self : RunnerConnection) -> Unit {
  self.send(obj([("op", s("close_stdin"))]))
}

///|
pub fn RunnerConnection::signal(self : RunnerConnection, signal : String, group? : Bool = true) -> Unit {
  self.send(obj([("op", s("signal")), ("signal", s(signal)), ("group", b(group))]))
}

///|
/// Read to the end: the runner cleans up and goes.
pub fn RunnerConnection::finish(self : RunnerConnection) -> Unit {
  self.send(obj([("op", s("done"))]))
  (self.socket.end)()
}

///|
/// This station lets go: resolved once the runner closed its side too (or was gone).
pub fn RunnerConnection::detach(self : RunnerConnection) -> Later[Unit] {
  self.left = true
  if (self.socket.destroyed)() {
    return done(self.m.lp)
  }
  if self.m.says_leave {
    self.send(obj([("op", s("leave"))]))
  }
  (self.socket.end)()
  self.closed
}

///|
pub fn Machine::read_dir(self : Machine, p : String) -> Later[Array[String]] {
  (self.read_dir)(p)
}

///|
pub fn Machine::read_file(self : Machine, p : String) -> Later[String] {
  (self.read_file)(p)
}

///|
pub fn Machine::mtime(self : Machine, p : String) -> Later[Double?] {
  (self.mtime)(p)
}

///|
pub fn Machine::size(self : Machine, p : String) -> Later[Int?] {
  (self.size)(p)
}

///|
pub fn Machine::read_at(self : Machine, p : String, at : Int, length : Int) -> Later[Bytes] {
  (self.read_at)(p, at, length)
}

///|
pub fn Machine::remove(self : Machine, p : String) -> Later[Unit] {
  (self.remove)(p)
}

///|
pub fn Machine::there(self : Machine, p : String) -> Later[Bool] {
  (self.there)(p)
}

///|
pub fn Machine::pid_alive(self : Machine, pid : Int) -> Bool {
  (self.pid_alive)(pid)
}

///|
pub fn Machine::group_alive(self : Machine, pgid : Int) -> Bool {
  (self.group_alive)(pgid)
}

///|
pub fn Machine::start_time(self : Machine, pid : Int) -> Later[Double?] {
  (self.start_time)(pid)
}

///|
pub fn Machine::connect(self : Machine, path : String, events : SocketEvents) -> Socket {
  (self.connect)(path, events)
}

///|
pub fn Machine::sleep(self : Machine, ms : Double) -> Later[Unit] {
  (self.sleep)(ms)
}

///|
pub fn Machine::now(self : Machine) -> Double {
  (self.now)()
}

///|
pub fn Machine::log(self : Machine, level : String, at : String, message : String, fields : JValue) -> Unit {
  (self.log)(level, at, message, fields)
}

///|
/// Up to where of stdout the runner may give the disk back, told with the next ack.
pub fn RunnerConnection::keep_from(self : RunnerConnection, at : Int) -> Unit {
  self.keep = Some(at)
}

///|
pub fn Machine::is_file(self : Machine, p : String) -> Later[Bool] {
  (self.is_file)(p)
}

///|
pub fn Machine::realpath(self : Machine, p : String) -> Later[String?] {
  (self.realpath)(p)
}

///|
pub fn Machine::make_dir(self : Machine, p : String) -> Later[Unit] {
  (self.make_dir)(p)
}

///|
pub fn Machine::link(self : Machine, from : String, to : String) -> Later[Unit] {
  (self.link)(from, to)
}

///|
pub fn Machine::stat(self : Machine, p : String, follow? : Bool = true) -> Later[FileStat?] {
  (self.stat)(p, follow)
}

///|
pub fn Machine::write_file(self : Machine, p : String, text : String, private? : Bool = false) -> Later[Unit] {
  (self.write_file)(p, text, private)
}

///|
pub fn Machine::append_file(self : Machine, p : String, text : String) -> Later[Unit] {
  (self.append_file)(p, text)
}

///|
pub fn Machine::remove_tree(self : Machine, p : String) -> Later[Unit] {
  (self.remove_tree)(p)
}

///|
pub fn Machine::rename(self : Machine, from : String, to : String) -> Later[Unit] {
  (self.rename)(from, to)
}

///|
pub fn Machine::copy(self : Machine, from : String, to : String) -> Later[Unit] {
  (self.copy)(from, to)
}

///|
pub fn Machine::copy_file(self : Machine, from : String, to : String) -> Later[Unit] {
  (self.copy_file)(from, to)
}

///|
pub fn Machine::hard_link(self : Machine, from : String, to : String) -> Later[Unit] {
  (self.hard_link)(from, to)
}

///|
pub fn Machine::link_path(self : Machine, from : String, to : String) -> Later[Unit] {
  (self.link_path)(from, to)
}
