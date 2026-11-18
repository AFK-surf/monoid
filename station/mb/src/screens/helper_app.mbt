// still.fail Helper (src/helper/app.ts; station/native/helper §4): the station's macOS app for what macOS grants an
// app (Screen Recording, Accessibility), so that a grant, which takes effect only once the process holding it starts
// again, restarts this app and never the station. LaunchServices starts it (`open -n -g`), which makes it its own
// responsible process.
//
// The release's app is copied to <data>/helper first, anew when its code changed. The station talks to it on a Unix
// socket there, each connection one request: a JSON line with the token in <data>/helper/token, answered with a JSON
// line, or with a stream (`screen.view`). The station watches the app it started (a connection held open, `watch`):
// when the app ends without being asked, the station waits a moment for it to come back by itself, then starts it
// again; `on_back` is told either way. The app tells on that connection what changes meanwhile (`listen`).
//
// A refusal is a `Failed` with the answer's fields (`code`, and what the op adds).

///|
pub const HELPER_APP : String = "still.fail Helper.app"

///|
/// How long a started app has to answer, at most.
const START_MS : Double = 15000

///|
/// How long an app that ended is given to come back by itself before the station starts it.
const COMING_BACK_MS : Double = 3000

///|
/// Started again this many times within REVIVALS_MS without staying up: the station stops trying.
const REVIVALS : Int = 5

///|
const REVIVALS_MS : Double = 60000

///|
/// The release's helper app: STILLFAIL_HELPER, or beside the station's code in a release.
pub fn helper_app(io : Io, env : Env) -> String? {
  let candidates = [env.get("STILLFAIL_HELPER"), Some(pj([io.os.code_dir, HELPER_APP]))]
  for p in candidates {
    match p {
      Some(p) if p != "" && (io.fs.exists_sync)(pj([p, "Contents/Info.plist"])) => return Some(p)
      _ => ()
    }
  }
  None
}

///|
/// How the app is started: by LaunchServices, a new instance, in the background, with its socket and token.
pub fn open_app(io : Io) -> async (String, Array[(String, String)]) -> Unit {
  async fn(app, env) {
    let args = ["-n", "-g"]
    for p in env {
      args.push("--env")
      args.push("\{p.0}=\{p.1}")
    }
    args.push(app)
    ignore((io.procs.exec)("open", args, ExecOptions::new(timeout=Some(START_MS))))
  }
}

///|
/// The files that say an installed copy is the release's: its code and its signature.
let helper_code : Array[String] = [
  "Contents/MacOS/stillfail-helper", "Contents/Info.plist", "Contents/_CodeSignature/CodeResources",
]

///|
/// The release's app copied into `dir`, unless the copy there is the same; whether it was copied.
pub async fn install(io : Io, app : String, dir : String) -> (String, Bool) {
  let path = pj([dir, @nodepath.basename("/", app)])
  let same = @effect.all(
    helper_code.map(f => async fn() {
      let ours = (io.fs.read)(pj([app, f])) catch { _ => return false }
      let there = (io.fs.read)(pj([path, f])) catch { _ => return false }
      ours == there
    }),
  )
  if !same.contains(false) {
    return (path, false)
  }
  (io.fs.mkdir)(dir, true, None)
  let staging = pj([dir, ".staging-\{io.random_hex(4)}"])
  (io.fs.copy_tree)(app, staging)
  let old = "\{path}.old-\{io.random_hex(4)}"
  (io.fs.rename)(path, old) catch {
    FsFailed(_, "ENOENT") => ()
    e => raise e
  }
  (io.fs.rename)(staging, path)
  (io.fs.rm)(old, true, true)
  (path, true)
}

///|
/// The helper's clock (a TestClock in tests): how long it is given to answer and to come back, and the waits between.
pub(all) struct HelperClock {
  now : () -> Double
  sleep : async (Double) -> Unit
}

///|
/// still.fail Helper as the station speaks to it (app.ts `HelperApp`).
pub struct HelperApp {
  app : String
  dir : String
  socket : String
  priv io : Io
  priv launch : async (String, Array[(String, String)]) -> Unit
  priv clock : HelperClock
  priv mut token : String?
  priv starting : Shared[Unit]
  priv mut watch_conn : Sock?
  /// The watching connection being opened: whoever else wants the app watched meanwhile waits for it.
  priv opening : Shared[Unit]
  priv mut quitting : Bool
  /// Where the release's copy was installed by this process, once it was.
  priv mut installed : String?
  priv mut revivals : Array[Double]
  priv backs : Array[(Int, () -> Unit)]
  priv listeners : Array[(Int, (J) -> Unit)]
  priv mut next : Int
}

///|
pub fn HelperApp::new(
  io : Io,
  app : String,
  dir : String,
  launch? : (async (String, Array[(String, String)]) -> Unit)? = None,
  on_back? : (() -> Unit)? = None,
  clock? : HelperClock? = None,
) -> HelperApp {
  let token = match (io.fs.read_sync)(pj([dir, "token"])) {
    Some(t) if trim_js(t) != "" => Some(trim_js(t))
    _ => None
  }
  let h = {
    app,
    dir,
    socket: pj([dir, "helper.sock"]),
    io,
    launch: launch.unwrap_or(open_app(io)),
    clock: clock.unwrap_or({ now: () => io.clock.ms(), sleep: async fn(ms) { io.clock.sleep(ms) } }),
    token,
    starting: Shared::new(),
    watch_conn: None,
    opening: Shared::new(),
    quitting: false,
    installed: None,
    revivals: [],
    backs: [],
    listeners: [],
    next: 0,
  }
  match on_back {
    Some(f) => {
      h.next += 1
      h.backs.push((h.next, f))
    }
    None => ()
  }
  h
}

///|
/// The op with the token (`{ ...op, token }`), as a line.
fn HelperApp::line(self : HelperApp, op : J) -> Bytes {
  @utf8.encode(stringify(set(op, "token", jopt_s(self.token))) + "\n")
}

///|
/// A request's answer, the app started first when it is not up.
pub async fn HelperApp::request(self : HelperApp, op : J) -> J {
  self.ensure()
  self.ask(op)
}

///|
/// A connection for a stream (`screen.view`): its request written, the rest the caller's.
pub async fn HelperApp::connect(self : HelperApp, op : J) -> Sock {
  self.ensure()
  let socket = dial(self.io, Unix(self.socket))
  socket.write(self.line(op))
  socket
}

///|
/// Told when the app came back after it ended by itself; the returned function stops it.
pub fn HelperApp::on_back(self : HelperApp, listener : () -> Unit) -> () -> Unit {
  self.next += 1
  let id = self.next
  self.backs.push((id, listener))
  () => take_out(self.backs, id)
}

///|
/// Told what the app says changed (`{event: "grants"}`: a grant, as its window saw it).
pub fn HelperApp::listen(self : HelperApp, listener : (J) -> Unit) -> () -> Unit {
  self.next += 1
  let id = self.next
  self.listeners.push((id, listener))
  () => take_out(self.listeners, id)
}

///|
/// The running app's process, none when none answers.
pub async fn HelperApp::pid(self : HelperApp) -> Double? {
  if self.token is None {
    return None
  }
  let a = self.ask(jo([("op", js("hello"))])) catch { _ => return None }
  match get(Some(a), "pid") {
    Some(Num(n)) => Some(n)
    _ => None
  }
}

///|
/// Until the app answering is not process `pid` (it started itself again, for a grant), at most `ms`.
pub async fn HelperApp::restarted(self : HelperApp, pid : Double, ms? : Double = START_MS) -> Unit {
  let until = (self.clock.now)() + ms
  while true {
    let now = self.pid()
    match now {
      Some(p) if p != pid => return
      _ => ()
    }
    if (self.clock.now)() > until {
      raise fail("still.fail Helper did not start again")
    }
    (self.clock.sleep)(100.0)
  }
}

///|
/// The app up and answering: started (or started again) when not.
pub async fn HelperApp::ensure(self : HelperApp) -> Unit {
  self.quitting = false
  self.starting
  .start(self.io, async fn() {
    self.ensure_up()
    self.watching()
  })
  .wait()
}

///|
/// The app watched: its end (not asked for) starts it again. One connection at a time.
async fn HelperApp::watching(self : HelperApp) -> Unit {
  if self.watch_conn is Some(_) {
    return
  }
  self.opening.start(self.io, async fn() { self.open_watch() }).wait()
}

///|
async fn HelperApp::open_watch(self : HelperApp) -> Unit {
  let socket = dial(self.io, Unix(self.socket))
  // The station stopped while it opened: nothing to watch for.
  if self.quitting {
    socket.destroy()
    return
  }
  self.watch_conn = Some(socket)
  ignore(socket.on_error(_ => ()))
  // Read (its answer, then what it tells): a socket not read never hears that the other end went.
  let carry = Buffer()
  let answered = Ref(false)
  ignore(
    socket.on_data(chunk => {
      carry.write_bytes(chunk)
      while true {
        let all = carry.to_bytes()
        let at = index_of_byte(all, b'\n')
        if at < 0 {
          break
        }
        let line = all[0:at]
        carry.reset()
        carry.write_bytesview(all[at + 1:])
        if !answered.val {
          answered.val = true
          continue
        }
        match (try Ok(parse(@utf8.decode_lossy(line))) catch { e => Err(e) }) {
          Ok(event) => for l in self.listeners.copy() {
            (l.1)(event)
          }
          Err(_) => ()
        }
      }
    }),
  )
  ignore(
    socket.on_close(() => {
      match self.watch_conn {
        Some(w) if physical_equal(w, socket) => self.watch_conn = None
        _ => ()
      }
      if !self.quitting {
        self.io.go(async fn() { self.revive() })
      }
    }),
  )
  socket.write(@utf8.encode(stringify(jo([("op", js("watch")), ("token", jopt_s(self.token))])) + "\n"))
}

///|
/// The app ended by itself: back by itself in a moment, or started again.
async fn HelperApp::revive(self : HelperApp) -> Unit {
  let now = (self.clock.now)()
  let kept = self.revivals.filter(t => now - t < REVIVALS_MS)
  kept.push(now)
  self.revivals = kept
  if self.revivals.length() > REVIVALS {
    self.io.log.warn("helper", "still.fail Helper keeps ending; not started again until it is needed")
    return
  }
  try {
    self.back(ms=COMING_BACK_MS) catch {
      _ => {
        self.io.log.info("helper", "still.fail Helper ended; starting it again")
        self.ensure()
      }
    }
    self.watching()
    for b in self.backs.copy() {
      (b.1)()
    }
  } catch {
    e => self.io.log.warn("helper", "still.fail Helper not started again", fields=jo([("error", js(message_of(e)))]))
  }
}

///|
async fn HelperApp::ensure_up(self : HelperApp) -> Unit {
  // The installed copy is compared with the release's once a process: up since, each request only asks it. Installed
  // and not answering, the copy is started again as it is, not compared again.
  let path = match self.installed {
    Some(inst) => {
      if self.hello() {
        return
      }
      inst
    }
    None => {
      let (path, replaced) = install(self.io, self.app, self.dir)
      self.installed = Some(path)
      let up = self.hello()
      // Its code changed: the one running is the old one.
      if up && replaced {
        ignore(self.ask(jo([("op", js("quit"))]))) catch {
          _ => ()
        }
      } else if up {
        return
      }
      path
    }
  }
  // The token stays what it is: an app started by macOS itself reads it beside it.
  if self.token is None {
    let token = self.io.random_hex(32)
    (self.io.fs.write)(pj([self.dir, "token"]), @utf8.encode(token), Some(0o600))
    self.token = Some(token)
  }
  (self.io.fs.rm)(self.socket, false, true)
  self.io.log.info("helper", "starting still.fail Helper", fields=jo([("app", js(path))]))
  (self.launch)(path, [("STILLFAIL_HELPER_SOCKET", self.socket), ("STILLFAIL_HELPER_TOKEN", self.token.unwrap_or(""))])
  self.back()
}

///|
/// Until it answers again (started, or starting itself again for a grant), at most `ms`.
pub async fn HelperApp::back(self : HelperApp, ms? : Double = START_MS) -> Unit {
  let until = (self.clock.now)() + ms
  while !self.hello() {
    if (self.clock.now)() > until {
      raise fail("still.fail Helper did not start")
    }
    (self.clock.sleep)(100.0)
  }
}

///|
async fn HelperApp::hello(self : HelperApp) -> Bool {
  // (No socket there: the connection is refused at once.)
  if self.token is None {
    return false
  }
  let a = self.ask(jo([("op", js("hello"))])) catch { _ => return false }
  get(Some(a), "ok") is Some(Bool(true))
}

///|
/// One request on a connection of its own: its answer line.
async fn HelperApp::ask(self : HelperApp, op : J) -> J {
  let socket = dial(self.io, Unix(self.socket))
  let d : @effect.Deferred[J] = @effect.Deferred::new()
  let got = Buffer()
  ignore(
    socket.on_data(chunk => {
      // A long answer (a listing) comes in many parts: only the new part is looked through.
      let from = got.length()
      got.write_bytes(chunk)
      let all = got.to_bytes()
      let at = index_of_byte(all, b'\n', from~)
      if at < 0 {
        return
      }
      socket.destroy()
      match (try Ok(parse(@utf8.decode_lossy(all[0:at]))) catch { e => Err(e) }) {
        Ok(answer) =>
          match get(Some(answer), "error") {
            Some(Str(_) as e) => ignore(d.fail(Failed(text(Some(e)).unwrap_or(""), answer)))
            _ => ignore(d.succeed(answer))
          }
        Err(e) => ignore(d.fail(fail(json_error_message(e))))
      }
    }),
  )
  ignore(socket.on_error(e => ignore(d.fail(fail(e)))))
  ignore(socket.on_close(() => ignore(d.fail(fail("still.fail Helper closed the connection")))))
  socket.write(self.line(op))
  d.wait()
}

///|
/// The station stopping: the app ends too (started again when next needed).
pub async fn HelperApp::quit(self : HelperApp) -> Unit {
  self.quitting = true
  // One being opened is let go as it opens (`open_watch`).
  match self.opening.going {
    Some(d) => d.wait() catch { _ => () }
    None => ()
  }
  if self.hello() {
    ignore(self.ask(jo([("op", js("quit"))]))) catch {
      _ => ()
    }
  }
  match self.watch_conn {
    Some(w) => w.destroy()
    None => ()
  }
  self.watch_conn = None
}

///|
/// What JSON.parse says of what is not JSON (a SyntaxError's message, as the harness compares it by its kind only).
fn json_error_message(e : Error) -> String {
  match e {
    @jsjson.SyntaxError(m) => m
    e => e.to_string()
  }
}
