// station/src/logins/run.ts: one login (怎么做到): a login command run on this machine in a pseudo-terminal (the
// system's `script`, 200 × 40), with stand-ins for the browser (BROWSER, and `open`, `xdg-open`, `osascript` first on
// its PATH) that hand the page it would open to the station instead. What a person has to do is read from three
// places: the page it opens, what it prints (pages, a device code, prompts), and whether it has stopped on a prompt.
// Its screen is kept by a terminal with no display (vt.mbt, the port of @xterm/headless it ran on), which also answers
// what the program asks of its terminal (the cursor's place, the background colour: gh waits for both). Nothing it
// shows is logged or kept on disk.
//
// The terminal takes what it is written later, in order, and says it drawn then (xterm.js's write buffer, a timer
// away): here a fiber of its own takes each write in turn.

///|
pub const COLS : Int = 200

///|
pub const ROWS : Int = 40

///|
/// How long a login may take before it is ended (a device code lasts 5 to 15 minutes; a browser left open, as long).
pub const TIMEOUT_MS : Int = 900000

///|
/// Output quiet this long: the command waits (on a prompt, or for the browser).
pub const QUIET_MS : Int = 500

///|
/// Silent this long once it has no more need of anyone (the browser came back, it said it is logged in, or what it
/// started waits on a keychain or a credential store), not at a prompt: stuck, and ended (the overall time still
/// holds).
pub const STALL_MS : Int = 180000

///|
/// How much of what it said is kept to read (pages and codes come early).
const SAID_KEPT : Int = 32000

///|
/// An ended command's group is killed outright this long after it was asked to stop.
const KILL_MS : Int = 3000

///|
/// The keys an agent may press, as the terminal sends them.
pub let keys : Array[(String, String)] = [
  ("Enter", "\r"),
  ("Backspace", "\u{7f}"),
  ("Up", "\u{1b}[A"),
  ("Down", "\u{1b}[B"),
  ("Right", "\u{1b}[C"),
  ("Left", "\u{1b}[D"),
  ("Tab", "\t"),
  ("Ctrl-C", "\u{3}"),
]

///|
pub fn key_code(key : String) -> String? {
  for k in keys {
    if k.0 == key {
      return Some(k.1)
    }
  }
  None
}

///|
/// The screen as the login's agent reads it and its page follows it.
pub(all) struct Screen {
  rows : Array[String]
  cursor : (Int, Int)
  echo : Bool
  live : Bool
}

///|
pub fn Screen::to_json(self : Screen) -> J {
  jo([
    ("rows", jstrs(self.rows)),
    ("cursor", jo([("x", ji(self.cursor.0)), ("y", ji(self.cursor.1))])),
    ("echo", jb(self.echo)),
    ("live", jb(self.live)),
  ])
}

///|
/// An environment, its names in the order they were set.
pub type Env = Map[String, String]

///|
/// A login command's process, as the platform started it.
pub(all) struct Child {
  pid : Int?
  /// Its stdin is there to write to (not destroyed).
  writable : () -> Bool
  write : (String) -> Unit
  end_stdin : () -> Unit
  /// What it writes (0: stdout, 1: stderr), a chunk at a time; its close (code, signal).
  on_output : ((Int, Bytes) -> Unit) -> Unit
  on_close : ((Int?, String?) -> Unit) -> Unit
}

///|
/// What a login's run asks of the station and the machine.
pub(all) struct RunIo {
  /// The fibers' clock (Fibers.now), and its timers: the returned function calls one off.
  now : () -> Double
  after : (Int, () -> Unit) -> (() -> Unit)
  spawn : (async () -> Unit) -> Unit
  /// platform `home(env)`.
  home : (Env) -> String?
  prepend_path : (Env, String) -> Env
  exe : (String) -> String
  /// shell-path.ts `withShellCommand`: the environment the program is found in, None where `env` stands.
  with_shell_command : async (String, Env) -> Env?
  /// platform `terminalSoon`.
  terminal : async (String, Array[String], Int, Int) -> (String, Array[String])?
  /// platform `runnableSoon`.
  runnable : async (String, Array[String], Env) -> (String, Array[String])
  /// processes.ts `startCommand` (in `cwd`, with `env`): its child, or why it could not be.
  start_command : (String, Array[String], String, Env) -> Child raise
  /// platform/processes.ts `started`: the error it failed to start with, none once it did.
  started : async (Child) -> String?
  /// processes.ts `endCommand(child, signal)`.
  end_command : (Child, String) -> Unit
  descendants : async (Int) -> Array[Int]
  /// platform `echoes(pid)`: whether its terminal echoes, none where it cannot be told.
  echoes : async (Int) -> Bool?
  /// platform `commands(pids)`.
  commands : async (Array[Int]) -> Array[String]
  read_file : async (String) -> String
  /// fs.watch of a directory (not persistent): what changed in it (None: unknown); what stops it. Raises where it
  /// cannot be watched.
  watch : (String, (String?) -> Unit) -> (() -> Unit) raise
  /// tr(lang, key, args).
  tr : (String, String, Map[String, String]) -> String
  log : (String, J) -> Unit
}

///|
pub(all) struct RunOptions {
  id : String
  command : Array[String]
  /// The command's environment (PATH as the station's): the stand-ins are put first.
  env : Env
  cwd : String
  /// Where the stand-ins are (one directory for all logins), and the file this login's write the pages to.
  shims : String
  opened : String
  lang : String
  /// Its state, step, page or code changed.
  changed : () -> Unit
  /// Its screen changed.
  drawn : () -> Unit
}

///|
pub struct LoginRun {
  id : String
  command : Array[String]
  started_at : Double
  expires_at : Double
  mut state : String
  mut step : String?
  mut url : String?
  mut loopback : @ops_platform.Loopback?
  mut code : String?
  mut code_url : String?
  mut waiting : Bool
  /// Its agent saw it wait for what its page gives: the person's to enter, from their card, not its agent's.
  mut paste : Bool
  mut echo : Bool
  mut error : String?
  mut ended_at : Double?
  /// Its callback was relayed (once only).
  mut relayed : Bool
  /// Ended for want of time.
  mut timed_out : Bool
  /// It has asked a person for a browser step (a page, a code) at some point.
  mut had_browser_step : Bool
  priv quiet_waiters : Array[@effect.Deferred[Unit]]
  priv o : RunOptions
  priv io : RunIo
  priv mut child : Child?
  priv term : Vt
  /// What the terminal is yet to take, each with what follows once it has.
  priv writes : Array[(String, () -> Unit)]
  priv mut pumping : Bool
  priv mut said : String
  priv mut cr : String
  priv mut opened : Array[String]
  priv mut reads : Int
  priv mut look_again : Bool
  priv mut rows : Array[String]
  priv mut cursor : (Int, Int)
  priv mut exited : Bool
  priv mut quiet : (() -> Unit)?
  priv mut timeout : () -> Unit
  priv mut watcher : (() -> Unit)?
  /// The prompt last answered for the person (its line and place), so it is answered once.
  priv mut answered : String
  /// What it has said since its browser step was first asked for (the end kept), and whether that says it is logged in.
  priv mut after_step : String
  priv mut said_done : Bool
  priv mut stall : () -> Unit
  priv mut disposed : Bool
}

///|
pub fn LoginRun::new(o : RunOptions, io : RunIo) -> LoginRun {
  let started_at = (io.now)()
  let run : LoginRun = {
    id: o.id,
    command: o.command,
    started_at,
    expires_at: started_at + TIMEOUT_MS.to_double(),
    state: "starting",
    step: None,
    url: None,
    loopback: None,
    code: None,
    code_url: None,
    waiting: false,
    paste: false,
    echo: true,
    error: None,
    ended_at: None,
    relayed: false,
    timed_out: false,
    had_browser_step: false,
    quiet_waiters: [],
    o,
    io,
    child: None,
    term: Vt::new(COLS, ROWS, 200),
    writes: [],
    pumping: false,
    said: "",
    cr: "",
    opened: [],
    reads: 0,
    look_again: false,
    rows: Array::make(ROWS, ""),
    cursor: (0, 0),
    exited: false,
    quiet: None,
    timeout: () => (),
    watcher: None,
    answered: "",
    after_step: "",
    said_done: false,
    stall: () => (),
    disposed: false,
  }
  // What the program asks of its terminal, answered as a terminal would: the cursor's place and the like by the
  // emulator itself, the colours here (a light terminal).
  run.term.on_data(reply => run.write(reply))
  run.term.osc(10, data => if data == "?" {
    run.write("\u{1b}]10;rgb:0000/0000/0000\u{1b}\\")
    true
  } else {
    false
  })
  run.term.osc(11, data => if data == "?" {
    run.write("\u{1b}]11;rgb:ffff/ffff/ffff\u{1b}\\")
    true
  } else {
    false
  })
  run
}

///|
pub fn LoginRun::active(self : LoginRun) -> Bool {
  self.ended_at is None
}

///|
/// The processes it runs as: `script` (or the command itself) and all it started.
pub async fn LoginRun::pids(self : LoginRun) -> Array[Int] {
  match self.child {
    Some({ pid: Some(pid), .. }) if !self.exited => {
      let out = [pid]
      out.append((self.io.descendants)(pid))
      out
    }
    _ => []
  }
}

///|
pub fn LoginRun::screen(self : LoginRun) -> Screen {
  { rows: self.rows.copy(), cursor: self.cursor, echo: self.echo, live: self.active() }
}

///|
fn LoginRun::tr(self : LoginRun, key : String, args? : Map[String, String] = {}) -> String {
  (self.io.tr)(self.o.lang, key, args)
}

///|
/// The terminal takes `text`, then `after` runs (`term.write(text, after)`).
fn LoginRun::term_write(self : LoginRun, text : String, after : () -> Unit) -> Unit {
  self.writes.push((text, after))
  if self.pumping {
    return
  }
  self.pumping = true
  (self.io.spawn)(async fn() {
    while self.writes.length() > 0 {
      let (t, f) = self.writes.remove(0)
      if !self.disposed {
        self.term.write(t)
        f()
      }
    }
    self.pumping = false
  })
}

///|
/// Starts the command; one that cannot be run ends failed, saying why.
pub async fn LoginRun::start(self : LoginRun) -> Unit {
  // `NAME=value claude auth login`: the environment it is given, as a shell takes it, not a program to run.
  let (given_env, rest) = @ops_platform.assignments_of(self.command, (self.io.home)(self.o.env))
  if rest.length() == 0 {
    return self.fail(self.tr("station.machineLogin.badCommand"))
  }
  let program = rest[0]
  let args = rest[1:].to_array()
  let mut env : Env = (self.io.prepend_path)(self.o.env, self.o.shims).copy()
  let browser = self.o.shims + "/" + (self.io.exe)("browser")
  // What it is given, but not the stand-ins for the browser: the page it opens is the person's to open.
  for p in given_env {
    env[p.0] = p.1
  }
  env["TERM"] = "xterm-256color"
  env["COLUMNS"] = COLS.to_string()
  env["LINES"] = ROWS.to_string()
  env["BROWSER"] = browser
  env["GH_BROWSER"] = browser
  env["STILLFAIL_LOGIN_OPENED"] = self.o.opened
  let found = (self.io.with_shell_command)(program, env)
  if !self.active() {
    return
  }
  if found is Some(f) {
    env = (self.io.prepend_path)(f, self.o.shims)
  }
  keychain_out_of_git(env)
  let wrapped = match (self.io.terminal)(program, args, COLS, ROWS) {
    Some(w) => w
    None => (program, args)
  }
  if !self.active() {
    return
  }
  let (file, file_args) = (self.io.runnable)(wrapped.0, wrapped.1, env)
  if !self.active() {
    return
  }
  let child = (self.io.start_command)(file, file_args, self.o.cwd, env) catch {
    e => return self.fail(self.tr("station.machineLogin.cannotRun", args={ "error": error_message(e) }))
  }
  self.child = Some(child)
  match (self.io.started)(child) {
    Some(spawned) => {
      self.exited = true
      return self.fail(self.tr("station.machineLogin.cannotRun", args={ "error": spawned }))
    }
    None => ()
  }
  let decoders = [Utf8Decoder::new(), Utf8Decoder::new()]
  (child.on_output)((stream, chunk) => self.output(decoders[stream].write(chunk)))
  (child.on_close)((code, signal) => self.closed(code, signal))
  self.timeout = (self.io.after)(TIMEOUT_MS, () => self.fail(self.tr("station.machineLogin.timedOut"), timeout=true))
  self.watch_stall()
  // The pages it opens, as its stand-ins write them.
  let file_name = basename(self.o.opened)
  self.watcher = Some(
    (self.io.watch)(dirname(self.o.opened), name => match name {
      None => self.reopen()
      Some(n) if n == file_name => self.reopen()
      _ => ()
    }),
  ) catch {
    _ => None
  }
  (self.io.log)("a login started", jo([("id", js(self.id)), ("command", js(self.command[0]))]))
  (self.o.changed)()
}

///|
fn basename(path : String) -> String {
  @nodepath.basename("/", path)
}

///|
fn dirname(path : String) -> String {
  @nodepath.dirname("/", path)
}

///|
/// Whether it waits on a line typed without echo: a secret (a password), which nobody types for it here.
pub fn LoginRun::secret(self : LoginRun) -> Bool {
  self.active() && self.waiting && !self.echo
}

///|
/// The next time its output has gone quiet and been looked at (what it waits on is known then), or it ends.
pub fn LoginRun::next_quiet(self : LoginRun) -> @effect.Deferred[Unit] {
  let d : @effect.Deferred[Unit] = @effect.Deferred::new()
  if !self.active() {
    d.succeed(()) |> ignore
  } else {
    self.quiet_waiters.push(d)
  }
  d
}

///|
fn LoginRun::quiet_now(self : LoginRun) -> Unit {
  let waiters = self.quiet_waiters.copy()
  self.quiet_waiters.clear()
  for w in waiters {
    w.succeed(()) |> ignore
  }
}

///|
/// Typed into its terminal: text as it is, or a key.
pub fn LoginRun::input(self : LoginRun, text? : String, key? : String) -> Unit {
  if !self.active() {
    return
  }
  match key {
    Some(k) =>
      match key_code(k) {
        Some(c) => self.write(c)
        None => ()
      }
    None =>
      match text {
        Some(t) => self.write(t)
        None => ()
      }
  }
}

///|
/// Cancelled by a person (or the station going): its command ended.
pub fn LoginRun::cancel(self : LoginRun) -> Unit {
  if !self.active() {
    return
  }
  self.end("cancelled", None)
}

///|
fn LoginRun::write(self : LoginRun, text : String) -> Unit {
  match self.child {
    Some(c) if (c.writable)() && !self.exited => (c.write)(text)
    _ => ()
  }
}

///|
/// What its command printed, a chunk as it came (its output's own handler; a test gives the chunks it means).
pub fn LoginRun::output(self : LoginRun, text : String) -> Unit {
  if text == "" || !self.active() {
    return
  }
  // A line's "\r" at a chunk's end is read with what follows it ("\r\n" split in two is one line's end).
  let whole = self.cr + text
  let mut k = whole.length()
  while k > 0 && whole.code_unit_at(k - 1) == '\r'.to_int().to_uint16() {
    k -= 1
  }
  self.cr = whole.unsafe_substring(start=k, end=whole.length())
  let plain = @ops_platform.plain_text(whole.unsafe_substring(start=0, end=k))
  self.watch_stall()
  self.term_write(text, () => {
    // What it said is taken as the emulator has drawn it, chunk by chunk in the order they came, never ahead of the
    // screen (2026-11-16, logins.test.ts's "answered [n]").
    let said = self.said + plain
    self.said = if said.length() > SAID_KEPT {
      said.unsafe_substring(start=said.length() - SAID_KEPT, end=said.length())
    } else {
      said
    }
    if self.had_browser_step && !self.said_done {
      let after = self.after_step + plain
      self.after_step = if after.length() > 4000 {
        after.unsafe_substring(start=after.length() - 4000, end=after.length())
      } else {
        after
      }
      self.said_done = @ops_platform.says_done(self.after_step)
    }
    self.draw()
    // Saying more, it no longer waits on what it asked (whether it waits now is asked once it is quiet again).
    if self.waiting {
      self.waiting = false
      (self.o.changed)()
    }
    // Looked at with the pages it opened as they are now: a command opens its page, then prints another.
    self.reopen(look=true)
  })
  // Quiet again from now: whether it waits is asked once it has said its piece.
  match self.quiet {
    Some(f) => f()
    None => ()
  }
  self.quiet = Some((self.io.after)(QUIET_MS, () => (self.io.spawn)(async fn() { self.settled() })))
}

///|
/// The screen as the emulator has it now; told when it changed.
fn LoginRun::draw(self : LoginRun) -> Unit {
  let rows = Array::makei(ROWS, i => self.term.row(i))
  let cursor = (self.term.cursor_x(), self.term.cursor_y())
  let same = rows == self.rows && cursor == self.cursor
  self.rows = rows
  self.cursor = cursor
  if !same {
    (self.o.drawn)()
  }
}

///|
/// The pages it opened read again, off the station's thread (as its stand-ins write them), then looked at again: once
/// they changed, or as it said more (`look`).
fn LoginRun::reopen(self : LoginRun, look? : Bool = false) -> Unit {
  if !self.active() {
    return
  }
  if look {
    self.look_again = true
  }
  self.reads += 1
  let read = self.reads
  (self.io.spawn)(async fn() {
    let opened = (try Some((self.io.read_file)(self.o.opened)) catch { _ => None }).map(
      @ops_platform.urls_in,
    )
    let opened = match opened {
      Some(o) => o
      None => self.opened
    }
    if read != self.reads || !self.active() {
      return
    }
    let changed = opened != self.opened
    self.opened = opened
    if !changed && !self.look_again {
      return
    }
    self.look_again = false
    self.read_said()
  })
}

///|
fn LoginRun::shown_key(self : LoginRun) -> String {
  stringify(
    ja([
      js(self.state),
      opt_js(self.step),
      opt_js(self.url),
      match self.loopback {
        Some(l) => loopback_json(l)
        None => Null
      },
      opt_js(self.code),
      opt_js(self.code_url),
      jb(self.waiting),
    ]),
  )
}

///|
fn opt_js(s : String?) -> J {
  match s {
    Some(x) => js(x)
    None => Null
  }
}

///|
/// A loopback callback as the logins say it (`{host, port, path, state, post}`).
pub fn loopback_json(l : @ops_platform.Loopback) -> J {
  jo([
    ("host", js(l.host)),
    ("port", ji(l.port)),
    ("path", js(l.path)),
    ("state", opt_js(l.state)),
    ("post", jb(l.post)),
  ])
}

///|
/// What it asks of a person now, from the pages it opened (as last read) and what it said.
fn LoginRun::read_said(self : LoginRun) -> Unit {
  if !self.active() {
    return
  }
  let before = self.shown_key()
  // As it said them, a link broken at the terminal's width put together again.
  let said = @ops_platform.unwrapped(self.said, COLS)
  let printed = @ops_platform.urls_in(said)
  // The page it opens, over what it prints: they may differ.
  let page = self.opened.last()
  let back = match page {
    Some(p) => @ops_platform.loopback_of(p)
    None => None
  }
  let printed_back = match page {
    None => printed.search_by(u => @ops_platform.loopback_of(u) is Some(_)).map(i => printed[i])
    Some(_) => None
  }
  let code = @ops_platform.device_code_in(said, self.opened)
  if self.state == "verifying" {
    // The browser came back: nothing more to do but wait for it to finish.
    ()
  } else if back is Some(_) || printed_back is Some(_) {
    self.url = match (page, back) {
      (Some(p), Some(_)) => Some(p)
      _ => printed_back
    }
    self.loopback = match back {
      Some(b) => Some(b)
      None => @ops_platform.loopback_of(printed_back.unwrap())
    }
    self.step = Some("loopback")
    self.state = "browser"
    self.code = None
  } else if !self.paste && code is Some(c) {
    // A code the person pastes from its page (paste) stays theirs to enter: what it says after is not a device code.
    let all = self.opened.copy()
    all.append(printed)
    let (url, code_url) = @ops_platform.device_urls(all, c)
    self.code = Some(c)
    self.url = url
    self.code_url = code_url
    self.step = Some("device")
    self.state = "code"
  } else if page is Some(_) || printed.iter().any(u => u.has_prefix("https://")) {
    self.url = match page {
      Some(p) => Some(p)
      None => printed.filter(u => u.has_prefix("https://")).last()
    }
    self.step = Some("open")
    self.state = "browser"
  }
  if self.step == Some("device") || self.step == Some("loopback") || self.step == Some("open") {
    self.had_browser_step = true
  }
  if self.shown_key() != before {
    (self.o.changed)()
  }
}

///|
/// Its output has been quiet a while: Enter pressed where it only asks for Enter to open its page in a browser (gh,
/// npm, docker: nothing to choose, and the stand-in takes the page); any other prompt, a question (Y/n) included, is
/// the person's to answer in the terminal: it waits for them.
async fn LoginRun::settled(self : LoginRun) -> Unit {
  self.quiet = None
  if !self.active() || self.exited {
    return
  }
  let line = self.rows[self.cursor.1]
  // Its "Press Enter to open … in your browser": on the cursor's line, or (gh) the line above it, the cursor on an
  // empty one under it. Pressed by the station whenever it asks (nothing opens on this machine: the stand-ins take the
  // page).
  let asked = if @jscase.trim(line) != "" { Some(self.cursor.1) } else { self.last_said_above(self.cursor.1) }
  let ask_line = match asked {
    Some(a) => self.rows[a]
    None => ""
  }
  let place = (match asked {
    Some(a) => a.to_string()
    None => "null"
  }) +
    "\u{0}" +
    ask_line
  if place != self.answered && @ops_platform.asks_enter(ask_line) {
    self.answered = place
    self.write("\r")
    // Its page comes now: what it waits on is known once it is quiet again.
    return
  }
  let waiting = @jscase.trim(line) != "" && @ops_platform.prompts(line) && self.state != "verifying"
  let mut echo = self.echo
  if waiting {
    // Asked of the first of its processes that is on the terminal (not `script` itself, nor what feeds it).
    let mut told : Bool? = None
    let pids = self.pids()
    for k in 1..<pids.length() {
      told = (self.io.echoes)(pids[k])
      if told is Some(_) {
        break
      }
    }
    echo = match told {
      Some(t) => t
      None => !@ops_platform.secret_asked(line)
    }
    if !self.active() {
      return
    }
  }
  let changed = waiting != self.waiting || (waiting && self.step is None)
  self.waiting = waiting
  if waiting && self.step is None {
    self.step = Some("terminal")
    self.state = "input"
  }
  if echo != self.echo {
    self.echo = echo
    (self.o.drawn)()
  }
  if changed {
    (self.o.changed)()
  }
  self.quiet_now()
}

///|
/// The nearest line above `y` with something on it (within a few lines: what it asks is just above), if any.
fn LoginRun::last_said_above(self : LoginRun, y : Int) -> Int? {
  let mut i = y - 1
  while i >= @cmp.maximum(0, y - 3) {
    if @jscase.trim(self.rows[i]) != "" {
      return Some(i)
    }
    i -= 1
  }
  None
}

///|
/// Watches for it going silent once nothing is left for anyone to do (STALL_MS): restarted by every output.
fn LoginRun::watch_stall(self : LoginRun) -> Unit {
  (self.stall)()
  if !self.active() {
    return
  }
  self.stall = (self.io.after)(STALL_MS, () => (self.io.spawn)(async fn() { self.stalled() }))
}

///|
async fn LoginRun::stalled(self : LoginRun) -> Unit {
  if !self.active() || self.exited {
    return
  }
  let stuck = !self.waiting &&
    (self.relayed ||
    self.said_done ||
    {
      let pids = self.pids()
      (self.io.commands)(pids[1:].to_array()).iter().any(@ops_platform.stores_secret)
    })
  if !self.active() {
    return
  }
  if !stuck {
    return self.watch_stall()
  }
  let shown = self.rows.map(r => js_trim_end(r)).filter(r => @jscase.trim(r) != "")
  let last = shown[@cmp.maximum(0, shown.length() - 8):].to_array()
  let screen = last.join("\n")
  (self.io.log)("a login stalled", jo([("id", js(self.id))]))
  self.fail(
    self.tr("station.machineLogin.stalled", args={ "minutes": (STALL_MS / 60000).to_string() }) +
    (if screen != "" { "\n" + screen } else { "" }),
    timeout=true,
  )
}

///|
/// Whether the person enters what its page gives on their card (its agent says so): only once it has given a page to
/// open, and never at a prompt that reads a secret.
pub fn LoginRun::ask_paste(self : LoginRun, on : Bool) -> Bool {
  if !self.active() || (on && (self.step != Some("open") || self.url is None || self.secret())) {
    return false
  }
  // Asked again (what was entered was refused): it waits on the person once more, no longer finishing.
  let again = on && self.state == "verifying"
  if again {
    self.state = "browser"
  }
  if on != self.paste || again {
    self.paste = on
    (self.o.changed)()
  }
  true
}

///|
/// The person entered what its page gave, and Enter: it finishes by itself now (or asks again, its agent says so).
pub fn LoginRun::answered_now(self : LoginRun) -> Unit {
  if !self.active() {
    return
  }
  self.state = "verifying"
  self.waiting = false
  (self.o.changed)()
}

///|
/// Its browser came back and the callback went to it: it finishes by itself now.
pub fn LoginRun::relayed_now(self : LoginRun) -> Unit {
  self.relayed = true
  if self.active() && self.state != "verifying" {
    self.state = "verifying"
    self.waiting = false
    self.paste = false
    (self.o.changed)()
  }
}

///|
fn LoginRun::closed(self : LoginRun, code : Int?, signal : String?) -> Unit {
  self.exited = true
  if !self.active() {
    return
  }
  // What it said last on the screen before it is ended: the terminal takes what it is given later, in order.
  let drawn : @effect.Deferred[Unit] = @effect.Deferred::new()
  self.term_write("", () => drawn.succeed(()) |> ignore)
  (self.io.spawn)(async fn() {
    drawn.wait()
    if !self.active() {
      return
    }
    if code == Some(0) {
      return self.end("done", None)
    }
    let said = last_lines(self.said)
    self.end(
      "failed",
      Some(
        if said != "" {
          said
        } else {
          self.tr("station.machineLogin.exited", args={
            "code": match (code, signal) {
              (Some(c), _) => c.to_string()
              (None, Some(s)) => s
              (None, None) => "signal"
            },
          })
        },
      ),
    )
  })
}

///|
fn LoginRun::fail(self : LoginRun, error : String, timeout? : Bool = false) -> Unit {
  if !self.active() {
    return
  }
  if timeout {
    self.timed_out = true
  }
  self.end("failed", Some(error))
}

///|
fn LoginRun::end(self : LoginRun, state : String, error : String?) -> Unit {
  if !self.active() {
    return
  }
  self.state = state
  self.error = error
  self.waiting = false
  self.paste = false
  self.ended_at = Some((self.io.now)())
  (self.timeout)()
  (self.stall)()
  match self.quiet {
    Some(f) => f()
    None => ()
  }
  self.quiet = None
  match self.watcher {
    Some(w) => w()
    None => ()
  }
  self.watcher = None
  match self.child {
    Some(child) if !self.exited => {
      (child.end_stdin)()
      (self.io.end_command)(child, "SIGTERM")
      (self.io.after)(KILL_MS, () => if !self.exited { (self.io.end_command)(child, "SIGKILL") }) |> ignore
    }
    _ => ()
  }
  (self.io.log)("a login ended", jo([("id", js(self.id)), ("state", js(state))]))
  (self.o.changed)()
  (self.o.drawn)()
  self.quiet_now()
}

///|
/// Stops listening to it for good (the station closing): its command ended.
pub fn LoginRun::close(self : LoginRun) -> Unit {
  self.cancel()
  self.disposed = true
}

///|
/// Git's credential helpers left out for a login's command and what it starts: a station's command has nobody to
/// answer the macOS keychain's dialog, so `git credential-osxkeychain` waits on it forever. An empty
/// `credential.helper` given on git's command line (GIT_CONFIG_COUNT, read after every file) clears the helpers the
/// files name, for this process only.
pub fn keychain_out_of_git(env : Env) -> Unit {
  let at = match env.get("GIT_CONFIG_COUNT") {
    Some(s) =>
      match parse_int_js(s) {
        Some(n) if n >= 0.0 => n
        _ => 0.0
      }
    None => 0.0
  }
  let name = stringify(Num(at))
  env["GIT_CONFIG_KEY_" + name] = "credential.helper"
  env["GIT_CONFIG_VALUE_" + name] = ""
  env["GIT_CONFIG_COUNT"] = stringify(Num(at + 1.0))
}

///|
/// `Number.parseInt(s, 10)` where it gives a number (None: NaN).
fn parse_int_js(s : String) -> Double? {
  let mut i = 0
  let n = s.length()
  while i < n && @jscase.is_white_space(s.code_unit_at(i).to_int()) {
    i += 1
  }
  let mut neg = false
  if i < n && (s.code_unit_at(i).to_int() == '-'.to_int() || s.code_unit_at(i).to_int() == '+'.to_int()) {
    neg = s.code_unit_at(i).to_int() == '-'.to_int()
    i += 1
  }
  let start = i
  let mut v = 0.0
  while i < n {
    let c = s.code_unit_at(i).to_int()
    if c < '0'.to_int() || c > '9'.to_int() {
      break
    }
    v = v * 10.0 + (c - '0'.to_int()).to_double()
    i += 1
  }
  if i == start {
    return None
  }
  Some(if neg { -v } else { v })
}

///|
/// The last few lines of what a command said, for why it failed.
pub fn last_lines(said : String) -> String {
  let lines = @jscase.trim(said)
    .split("\n")
    .map(l => js_trim_end(l.to_string()))
    .filter(l => @jscase.trim(l) != "")
    .collect()
  let joined = lines[@cmp.maximum(0, lines.length() - 6):].to_array().join("\n")
  // `[...s].slice(0, 800).join("")`: the first 800 code points
  let out = StringBuilder::new()
  let mut k = 0
  for c in joined {
    if k >= 800 {
      break
    }
    out.write_char(c)
    k += 1
  }
  out.to_string()
}

///|
/// A UTF-8 decoder kept across chunks (Node's StringDecoder): an incomplete sequence at a chunk's end waits for the
/// rest, what cannot be one is U+FFFD.
pub struct Utf8Decoder {
  priv mut held : Bytes
}

///|
pub fn Utf8Decoder::new() -> Utf8Decoder {
  { held: b"" }
}

///|
pub fn Utf8Decoder::write(self : Utf8Decoder, chunk : Bytes) -> String {
  let b = @buffer.new()
  b.write_bytes(self.held)
  b.write_bytes(chunk)
  let all = b.to_bytes()
  // what at its end may still be the start of a character
  let n = all.length()
  let mut cut = n
  let mut back = 1
  while back <= 3 && n - back >= 0 {
    let c = all[n - back].to_int()
    if (c & 0xC0) != 0x80 {
      let need = if c >= 0xF0 && c <= 0xF4 {
        4
      } else if c >= 0xE0 && c <= 0xEF {
        3
      } else if c >= 0xC2 && c <= 0xDF {
        2
      } else {
        1
      }
      if need > back && incomplete_ok(all, n - back, back) {
        cut = n - back
      }
      break
    }
    back += 1
  }
  self.held = all[cut:].to_bytes()
  utf8_text(all[:cut].to_bytes())
}

///|
/// Whether the `len` bytes at `at` are a sequence's start that more bytes could make one.
fn incomplete_ok(b : Bytes, at : Int, len : Int) -> Bool {
  let c = b[at].to_int()
  if len >= 2 {
    let d = b[at + 1].to_int()
    if c == 0xE0 && d < 0xA0 {
      return false
    }
    if c == 0xED && d > 0x9F {
      return false
    }
    if c == 0xF0 && d < 0x90 {
      return false
    }
    if c == 0xF4 && d > 0x8F {
      return false
    }
  }
  true
}
