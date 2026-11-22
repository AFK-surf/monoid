// The station's Chrome as a process (src/browser/chrome.ts, "The station's browser"): found on the machine, started as
// a normal browser on a profile of its own with a DevTools port, found again by a station process that did not start
// it (it outlives a handover, as jobs do), and ended. What it is used for is browser.mbt's.
//
// It is started as a person's browser would be, so that sites let it sign in: no --enable-automation, no
// --remote-debugging-pipe; headless, so that it opens no window on the machine at all; headful only when asked. Chrome
// says navigator.webdriver = true of any browser it lets be debugged (undone by
// --disable-blink-features=AutomationControlled), and a headless one says HeadlessChrome in its user agent (given the
// headful one's). With either, Google refuses to sign in (Chrome 155, 2026-10-17).

///|
/// A Chrome that runs: its DevTools (`port`, the browser's WebSocket `ws`), the program, how it was started.
pub(all) struct Running {
  /// Its process (group), when this station started it; None for one found without a record of it.
  pid : Int?
  /// When `pid` started (ms), to tell it from a later process given the same pid.
  started : Double?
  port : Int
  ws : String
  binary : String
  headless : Bool
  user_agent : String
}

///|
pub fn Running::to_j(self : Running) -> J {
  jo([
    (
      "pid",
      match self.pid {
        Some(p) => ji(p)
        None => Null
      },
    ),
    (
      "started",
      match self.started {
        Some(s) => jn(s)
        None => Null
      },
    ),
    ("port", ji(self.port)),
    ("ws", js(self.ws)),
    ("binary", js(self.binary)),
    ("headless", jb(self.headless)),
    ("userAgent", js(self.user_agent)),
  ])
}

///|
/// A Running as state.json keeps it.
pub fn Running::of_j(v : J) -> Running {
  let vv = Some(v)
  {
    pid: match at(vv, "pid") {
      Some(Num(n)) => Some(n.to_int())
      _ => None
    },
    started: num_of(at(vv, "started")),
    port: js_num(at(vv, "port")).to_int(),
    ws: js_str(at(vv, "ws")),
    binary: text(at(vv, "binary")),
    headless: is_true(at(vv, "headless")),
    user_agent: text(at(vv, "userAgent")),
  }
}

///|
/// A process started to outlive this one (ops/processes.ts `startLasting`): its pid, and how it ended once it did
/// (its exit code as `${code}` says it: "null" for a signal, "-1" for one that could not be started).
pub(all) struct Child {
  pid : Int?
  ended : () -> String?
}

///|
/// What the Chrome and Farview hosts ask of the machine (the TypeScript's platform, ops/group.ts, node:net, fetch).
pub(all) struct Machine {
  /// The machine's time (`wall.now`), and a wait on it (`wall.sleep`).
  now : () -> Double
  sleep : async (Double) -> Unit
  /// The machine's browsers, best first (platform.browsers), looked for at once; and looked for off the thread.
  browsers : () -> Array[String]
  browsers_soon : async () -> Array[String]
  has_display : () -> Bool
  /// A program started in a group of its own, to outlive the station: its program, arguments, directory and the
  /// environment it adds.
  start_lasting : (String, Array[String], String, Array[(String, String)]) -> Child
  start_time_of : async (Int) -> Double?
  group_alive : (Int) -> Bool
  /// The group ended (asked to end, then killed after `ms`).
  end_group : async (Int, Double) -> Unit
  signal_group : (Int, String) -> Unit
  /// Whether a port of 127.0.0.1 is free to be listened on.
  free : async (Int) -> Bool
  /// The browser's DevTools as it says them at `port` (`/json/version`): its WebSocket and user agent.
  version : async (Int) -> (String, String)?
  /// Whether something answers on a port of 127.0.0.1.
  answers : async (Int) -> Bool
  connect : async (String) -> Cdp
}

///|
/// What the browser asks of the machine for its Chrome (chrome.ts `ChromeHost`), apart so a test can be given a Chrome
/// of its own making.
pub(all) struct ChromeHost {
  /// The station's Chrome when it runs already (started by an earlier station process), else None.
  find : async () -> Running?
  /// Starts it.
  launch : async () -> Running
  /// Whether there is a Chrome here to start.
  installed : () -> Bool
  /// Makes sure it has ended (asked to close first by the caller): waits a little for it, then ends its group.
  kill : async (Running) -> Unit
  connect : async (String) -> Cdp
  /// Its state.json, shared with the browser that uses it; None: the browser keeps its own.
  state : BrowserState?
}

///|
/// `DevToolsActivePort` (written by Chrome into its profile): the port on the first line, the browser's path on the
/// second.
pub fn parse_active_port(text_ : String) -> (Int, String)? {
  let lines = []
  let mut start = 0
  let n = text_.length()
  let mut i = 0
  while i < n {
    if text_.unsafe_charcode_at(i) == 0x0a {
      let end = if i > start && text_.unsafe_charcode_at(i - 1) == 0x0d { i - 1 } else { i }
      lines.push(slice(text_, start, b=end))
      start = i + 1
    }
    i += 1
  }
  lines.push(slice(text_, start))
  let first = lines[0]
  let path = if lines.length() > 1 { trim(lines[1]) } else { "" }
  if !all_digits(first) || !path.has_prefix("/devtools/browser/") {
    return None
  }
  let port = js_num(Some(js(first)))
  if port <= 0.0 || port > 65535.0 {
    return None
  }
  Some((port.to_int(), path))
}

///|
/// Chrome's command line. `port` 0: any free one (said in DevToolsActivePort).
pub fn chrome_args(profile : String, port : Int, headless : Bool, user_agent? : String) -> Array[String] {
  let out = [
    "--user-data-dir=\{profile}", "--remote-debugging-port=\{port}", "--no-first-run", "--no-default-browser-check",
    // Chrome says navigator.webdriver of a browser it lets be debugged; sites (Google's sign-in) refuse such a one.
    "--disable-blink-features=AutomationControlled",
    // Started again after it died, it opens as it was without asking.
    "--hide-crash-restore-bubble",
    // A tab a person watches is drawn while its window is covered, and the agents' tabs run at speed behind others.
    "--disable-backgrounding-occluded-windows", "--disable-renderer-backgrounding", "--disable-background-timer-throttling",
  ]
  // Headful (when asked), no window of its own as it starts: one would make it the machine's front app.
  // Headless, drawn at twice its CSS pixels, as on a Retina screen: Chrome casts a tab at its one screen's scale,
  // so a phone's or a Retina window's view of it came as a picture of half its pixels (a captcha could not be read:
  // Peng Xiao, 2026-11-17). A viewer's bounds still cap what is cast. Without --screen-info, headless Chrome's default
  // 800x600 physical screen divides by DPR 2 to 400x300 CSS pixels; {2880x1800} yields a 1440x900 @2x screen.
  if headless {
    out.push("--headless=new")
    out.push("--window-size=1280,900")
    out.push("--force-device-scale-factor=2")
    out.push("--screen-info={2880x1800}")
  } else {
    out.push("--no-startup-window")
  }
  match user_agent {
    Some(a) if a != "" => out.push("--user-agent=\{a}")
    _ => ()
  }
  out
}

///|
/// The user agent a headless Chrome is given: its own, as the headful one says it.
pub fn headful_agent(agent : String) -> String {
  agent.replace_all(old="HeadlessChrome/", new="Chrome/")
}

///|
/// How long Chrome is given to come up (its DevToolsActivePort), and to end once asked.
let start_ms : Double = 30_000.0

///|
let given_port_ms : Double = 10_000.0

///|
let end_ms : Double = 5_000.0

///|
let look_ms : Double = 100.0

///|
/// What <data>/browser/state.json says (`{}` where it says nothing an object: what it is read as).
pub async fn read_state(files : Files, dir : String) -> J {
  let t = (files.read)(join(dir, "state.json"))
  match t {
    Some(s) =>
      match (try Ok(parse(s)) catch { e => Err(e) }) {
        Ok(Obj(_) | Arr(_) as v) => v
        _ => Obj([])
      }
    None => Obj([])
  }
}

///|
/// <data>/browser/state.json, read and changed in turn: each change read, made and written whole after the one before,
/// so none is lost to another made at once (Chrome's start, its end, its last use noted).
pub struct BrowserState {
  dir : String
  priv files : Files
  priv clock : Clock
  priv mut queue : Later[Unit]
}

///|
pub fn BrowserState::new(dir : String, files : Files, clock : Clock) -> BrowserState {
  { dir, files, clock, queue: Later::resolved(()) }
}

///|
/// What it says, once what was changed before is written.
pub async fn BrowserState::read(self : BrowserState) -> J {
  self.queue.wait() catch {
    _ => ()
  }
  read_state(self.files, self.dir)
}

///|
/// A change made in turn (`change(s => …)`); raises what its write raised.
pub async fn BrowserState::change(self : BrowserState, change : (J) -> J) -> Unit {
  self.start_change(change).wait()
}

///|
/// A change asked and not waited for (`void state.change(…)`): what waits for it is `written`.
pub fn BrowserState::start_change(self : BrowserState, change : (J) -> J) -> Later[Unit] {
  let before = self.queue
  let next = Later::start(self.clock, async fn() {
    before.wait() catch {
      _ => ()
    }
    let s = change(read_state(self.files, self.dir))
    (self.files.write_private)(join(self.dir, "state.json"), stringify_pretty(s) + "\n")
  })
  self.queue = next
  next
}

///|
/// Once every change asked is written (or failed).
pub async fn BrowserState::written(self : BrowserState) -> Unit {
  self.queue.wait() catch {
    _ => ()
  }
}

///|
/// `join(dir, name)` with `/`.
fn join(dir : String, name : String) -> String {
  pjoin([dir, name])
}

///|
/// `new URL(ws).pathname`; raises as `new URL` throws.
fn pathname_of(ws : String) -> String raise Thrown {
  match url_of(ws) {
    Some(u) => u.path
    None => raise Thrown("TypeError", "Invalid URL")
  }
}

///|
/// How long which Chrome is here is taken to stay as it was last looked for.
let browsers_ms : Double = 10_000.0

///|
/// The station's Chrome on the machine (chrome.ts `chromeHost`): `dir` <data>/browser (the profile in it, and
/// state.json), `binary` the program (else the machine's best), `headless` (the default) or headful.
pub fn chrome_host(
  dir : String,
  machine : Machine,
  files : Files,
  clock : Clock,
  log : Log,
  binary? : String,
  headless? : Bool,
) -> ChromeHost {
  let profile = join(dir, "profile")
  let active_port = join(profile, "DevToolsActivePort")
  let state = BrowserState::new(dir, files, clock)
  // Which Chrome is here: looked for once as the station starts; looked for again as it is started, and as whether
  // there is one is asked over BROWSERS_MS after the last look.
  let best : Ref[(Double, String?)?] = Ref(
    match binary {
      Some(_) => None
      None => Some(((machine.now)(), (machine.browsers)().get(0)))
    },
  )
  let looking : Ref[Later[String?]?] = Ref(None)
  let look = fn() -> Later[String?] {
    match looking.val {
      Some(l) => l
      None => {
        let l = Later::start(clock, async fn() {
          let r = try Ok((machine.browsers_soon)()) catch { e => Err(e) }
          looking.val = None
          match r {
            Ok(found) => {
              let b = found.get(0)
              best.val = Some(((machine.now)(), b))
              b
            }
            Err(_) =>
              match best.val {
                Some((_, b)) => {
                  best.val = Some(((machine.now)(), b))
                  b
                }
                None => None
              }
          }
        })
        looking.val = Some(l)
        l
      }
    }
  }
  let read_active = async fn() -> (Int, String)? {
    match (files.read)(active_port) {
      Some(t) => parse_active_port(t)
      None => None
    }
  }
  let still_there = async fn(r : Running) -> Bool {
    guard r.pid is Some(pid) else { return false }
    let started = (machine.start_time_of)(pid)
    match started {
      None => false
      Some(s) =>
        (match r.started {
          None => true
          Some(rs) => (s - rs).abs() < 5000.0
        }) &&
        (machine.group_alive)(pid)
    }
  }
  let find = async fn() -> Running? {
    // Where it said it is (DevToolsActivePort: written when it chose its port), else where it was recorded (one given
    // its port writes none).
    let recorded = match at(Some(state.read()), "running") {
      Some(Obj(_) as r) => Some(Running::of_j(r))
      _ => None
    }
    let active = match read_active() {
      Some(a) => Some(a)
      None =>
        match recorded {
          Some(r) => Some((r.port, pathname_of(r.ws)))
          None => None
        }
    }
    guard active is Some((port, path)) else { return None }
    guard (machine.version)(port) is Some((ws, agent)) else { return None }
    // What answers there is this profile's Chrome (its browser's path is the one it said), not another program given
    // the port since.
    if pathname_of(ws) != path {
      return None
    }
    let known = match recorded {
      Some(r) if r.port == port && still_there(r) => Some(r)
      _ => None
    }
    Some({
      pid: known.bind(k => k.pid),
      started: known.bind(k => k.started),
      port,
      ws,
      binary: match known {
        Some(k) => k.binary
        None => recorded.map(r => r.binary).unwrap_or("")
      },
      headless: match known {
        Some(k) => k.headless
        None => agent.contains("HeadlessChrome")
      },
      user_agent: agent,
    })
  }
  let kill = async fn(running : Running) -> Unit {
    match running.pid {
      Some(pid) =>
        if still_there(running) {
          let mut waited = 0.0
          while waited < end_ms && (machine.group_alive)(pid) {
            (machine.sleep)(look_ms)
            waited += look_ms
          }
          if (machine.group_alive)(pid) {
            (machine.end_group)(pid, end_ms)
          }
        }
      None => ()
    }
    // Its record and its DevToolsActivePort (Chrome takes that away when it ends well; one killed leaves it), unless
    // they are already another's (one started since).
    state.change(s => {
      guard at(Some(s), "running") is Some(r) else { return s }
      let rr = Running::of_j(r)
      if at(Some(r), "pid") is (Some(Num(_)) | Some(Null)) && rr.pid == running.pid && rr.port == running.port {
        drop_key(s, "running")
      } else {
        s
      }
    })
    match read_active() {
      Some((p, _)) if p == running.port =>
        if (machine.version)(running.port) is None {
          (files.rm)(active_port, false)
        }
      _ => ()
    }
  }
  let close_and_kill = async fn(running : Running) -> Unit {
    (async fn() {
      let cdp = (machine.connect)(running.ws)
      ignore(cdp.ask("Browser.close")) catch {
        _ => ()
      }
      (cdp.close)()
    })() catch {
      _ => ()
    }
    kill(running)
  }
  // `retried`: started again for its user agent; `any_port`: the port it had last time was not had; `windowless`:
  // headless whatever the machine says.
  async fn launch(retried : Bool, any_port : Bool, windowless : Bool) -> Running {
    let bin = match binary {
      Some(b) => Some(b)
      None => look().wait()
    }
    guard bin is Some(program) else {
      raise fail_("There is no Chrome on this machine: install Google Chrome (or Chromium or Edge) and ask again.")
    }
    let is_headless = windowless || headless.unwrap_or(true)
    (files.mkdir)(profile, 0o777)
    (files.rm)(active_port, false)
    let had = state.read()
    let had_port = match at(Some(had), "port") {
      Some(Num(p)) => Some(p.to_int())
      _ => None
    }
    let port = match had_port {
      Some(p) if !any_port && (machine.free)(p) => p
      _ => 0
    }
    let mtime = (files.mtime)(program) catch { _ => 0.0 }
    let known = at(Some(had), "headlessAgent")
    let agent = if is_headless &&
      truthy(known) &&
      text(at(known, "binary")) == program &&
      at(known, "binary") is Some(Str(_)) &&
      num_of(at(known, "mtimeMs")) == Some(mtime) {
      Some(js_str(at(known, "agent")))
    } else {
      None
    }
    let child = (machine.start_lasting)(
      program,
      chrome_args(profile, port, is_headless, user_agent?=agent),
      dir,
      [],
    )
    let pid = child.pid
    let started = match pid {
      Some(p) => (machine.start_time_of)(p)
      None => None
    }
    // Chrome's own time: looked at until it answers at its port (given; or chosen, and said in DevToolsActivePort,
    // which Chrome writes only then), or ends.
    let mut at_port : Int? = if port == 0 { None } else { Some(port) }
    let mut v : (String, String)? = None
    let mut waited = 0.0
    while v is None {
      match (child.ended)() {
        Some(code) =>
          raise fail_(
            "Chrome (\{program}) ended as it started (exit \{code}); is this profile open in another Chrome? \{profile}",
          )
        None => ()
      }
      // The port it had is not answered on (taken meanwhile): any other, then.
      if port != 0 && waited >= given_port_ms {
        match pid {
          Some(p) => (machine.signal_group)(p, "SIGKILL")
          None => ()
        }
        (log.warn)(
          "browser",
          "Chrome did not answer on the port it had; starting it on another",
          fields([("port", ji(port))]),
        )
        (machine.sleep)(end_ms)
        return launch(retried, true, windowless)
      }
      if waited >= start_ms {
        match pid {
          Some(p) => (machine.signal_group)(p, "SIGKILL")
          None => ()
        }
        raise fail_("Chrome (\{program}) did not open its DevTools port within \{dnum(start_ms / 1000.0)} s")
      }
      (machine.sleep)(look_ms)
      if at_port is None {
        at_port = read_active().map(a => a.0)
      }
      match at_port {
        Some(p) => v = (machine.version)(p)
        None => ()
      }
      waited += look_ms
    }
    let (ws, said_agent) = v.unwrap()
    let running : Running = {
      pid,
      started,
      port: at_port.unwrap(),
      ws,
      binary: program,
      headless: is_headless,
      user_agent: said_agent,
    }
    // A headless Chrome names itself in its user agent: started again with the headful one's, kept for next time.
    if is_headless && agent is None && said_agent.contains("HeadlessChrome") && !retried {
      state.change(s => put(
        s,
        "headlessAgent",
        jo([("binary", js(program)), ("mtimeMs", jn(mtime)), ("agent", js(headful_agent(said_agent)))]),
      ))
      close_and_kill(running)
      return launch(true, any_port, windowless)
    }
    state.change(s => put(put(s, "running", running.to_j()), "port", ji(running.port)))
    (log.info)(
      "browser",
      "Chrome started",
      fields([
        ("binary", js(program)),
        ("port", ji(running.port)),
        (
          "pid",
          match pid {
            Some(p) => ji(p)
            None => Null
          },
        ),
        ("headless", jb(is_headless)),
      ]),
    )
    running
  }

  {
    find,
    installed: () => match best.val {
      None => true
      Some((at_, b)) => {
        if (machine.now)() - at_ >= browsers_ms {
          ignore(look())
        }
        b is Some(_)
      }
    },
    launch: async fn() {
      launch(false, false, false) catch {
        e => {
          // A machine said to show windows that shows none to this process (a Mac's station with no one logged
          // in): headless, then.
          if headless is Some(_) || !(machine.has_display)() {
            raise e
          }
          (log.warn)(
            "browser",
            "Chrome did not start with windows; starting it headless",
            fields([("error", js(message_of(e)))]),
          )
          launch(false, false, true)
        }
      }
    },
    kill,
    connect: machine.connect,
    state: Some(state),
  }
}
