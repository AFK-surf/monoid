// adb/displays.ts: a screen of its own on the phone for each chat it is lent to (2026-11-04, user: 「会有一个虚拟屏跑 app
// 不影响我自己操作」): a virtual display, made and held by a run of scrcpy's server on the phone (`new_display`), in the
// grant's adb server. The agent starts its apps there (`am start --display`), touches it (`input -d`) and takes its
// pictures (`screencap -d`, SurfaceFlinger's id of it), while the person uses the phone's own screen. It is made as
// phone_use says how the phone is reached, and goes as the grant ends, as nothing of the agent's has used the phone for
// IDLE_MS (its apps closed with it), or as the phone's link goes. Its pictures are encoded small and seldom, and read
// only to keep it up.

///|
/// How long scrcpy has to make the display.
let start_timeout : Double = 20000.0

///|
/// How long an adb command of the station's is given.
let display_adb_timeout : Double = 15000.0

///|
/// A display nothing of the agent's used the phone for this long is closed.
pub let idle_ms : Double = 600000.0

///|
/// How often displays are looked at for that.
let idle_check : Double = 60000.0

///|
/// android.ts SERVER_VERSION: scrcpy's server's.
pub let server_version : String = "5.0.1"

// ── what is read of what the phone says ──

///|
fn is_digit(c : Char) -> Bool {
  c >= '0' && c <= '9'
}

///|
/// JavaScript's `\w`.
fn word_char(c : Char) -> Bool {
  is_digit(c) || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_'
}

///|
/// The digits of `s` from `i` (none: "").
fn digits_at(s : String, i : Int) -> String {
  let mut j = i
  while j < s.length() && is_digit(s[j].unsafe_to_char()) {
    j += 1
  }
  js_slice(s, i, b=j)
}

///|
/// Where `word` is in `s` from `from`, or -1.
fn index_of(s : String, word : String, from~ : Int = 0) -> Int {
  @jsjson.js_index_of(s, word, from~)
}

///|
/// Whether a word boundary (`\b`) is between `s[i - 1]` and `s[i]`.
fn boundary(s : String, i : Int) -> Bool {
  let before = i > 0 && word_char(s[i - 1].unsafe_to_char())
  let after = i < s.length() && word_char(s[i].unsafe_to_char())
  before != after
}

///|
/// The digits after the first `word` they follow (`/word(\d+)/`).
fn number_after(s : String, word : String) -> String? {
  let mut from = 0
  while true {
    let at = index_of(s, word, from~)
    if at < 0 {
      return None
    }
    let d = digits_at(s, at + word.length())
    if d != "" {
      return Some(d)
    }
    from = at + 1
  }
  None
}

///|
/// `New display: 1080x2400/420 (id=2)`, as scrcpy says it at log level info.
pub fn display_of(said : String) -> J {
  let word = "New display: "
  let mut from = 0
  while true {
    let at = index_of(said, word, from~)
    if at < 0 {
      return Null
    }
    let mut i = at + word.length()
    let w = digits_at(said, i)
    i += w.length()
    if w != "" && js_slice(said, i, b=i + 1) == "x" {
      let h = digits_at(said, i + 1)
      i += 1 + h.length()
      if h != "" && js_slice(said, i, b=i + 1) == "/" {
        let d = digits_at(said, i + 1)
        i += 1 + d.length()
        if d != "" && js_slice(said, i, b=i + 5) == " (id=" {
          let id = digits_at(said, i + 5)
          i += 5 + id.length()
          if id != "" && js_slice(said, i, b=i + 1) == ")" {
            return jo([
              ("width", jn(@session_chats.js_number(js(w)).unwrap())),
              ("height", jn(@session_chats.js_number(js(h)).unwrap())),
              ("density", jn(@session_chats.js_number(js(d)).unwrap())),
              ("id", jn(@session_chats.js_number(js(id)).unwrap())),
            ])
          }
        }
      }
    }
    from = at + 1
  }
  Null
}

///|
/// `wm density`: the override over the physical.
pub fn density_of(wm : String) -> Double {
  match number_after(wm, "Override density: ") {
    Some(d) => @session_chats.js_number(js(d)).unwrap()
    None =>
      match number_after(wm, "Physical density: ") {
        Some(d) => @session_chats.js_number(js(d)).unwrap()
        None => 0.0
      }
  }
}

///|
/// android.ts `sizeOf`: `wm size`, the override over the physical.
pub fn size_of(wm : String) -> (Double, Double) {
  let of = (word : String) => {
    let head = word + " size: "
    let mut from = 0
    while true {
      let at = index_of(wm, head, from~)
      if at < 0 {
        return None
      }
      let w = digits_at(wm, at + head.length())
      let i = at + head.length() + w.length()
      if w != "" && js_slice(wm, i, b=i + 1) == "x" {
        let h = digits_at(wm, i + 1)
        if h != "" {
          return Some(
            (
              @session_chats.js_number(js(w)).unwrap(),
              @session_chats.js_number(js(h)).unwrap(),
            ),
          )
        }
      }
      from = at + 1
    }
    None
  }
  match of("Override") {
    Some(s) => s
    None => of("Physical").unwrap_or((0.0, 0.0))
  }
}

///|
/// The lines of a text as `split("\n")` has them.
fn lines_of(s : String) -> Array[String] {
  s.split("\n").map(l => l.to_owned()).collect()
}

///|
/// JavaScript's white space and line ends (`\s`).
fn js_space(c : Char) -> Bool {
  @jscase.is_white_space(c.to_int())
}

///|
/// SurfaceFlinger's id of Android's display `id`: its unique id from `dumpsys display`, found in `dumpsys SurfaceFlinger
/// --display-id`'s lines; where they name none, by its layer stack in `dumpsys SurfaceFlinger` (`flinger`).
pub async fn surface_of(
  displays : String,
  ids : String,
  id : Int,
  flinger : async () -> String,
) -> String? {
  let wanted = "displayId \{id},"
  let info = lines_of(displays).search_by(l => {
    guard l.contains("mBaseDisplayInfo=") else { return false }
    let mut from = 0
    while true {
      let at = index_of(l, wanted, from~)
      if at < 0 {
        return false
      }
      if boundary(l, at) {
        return true
      }
      from = at + 1
    }
    false
  })
  guard info is Some(i) else { return None }
  let info = lines_of(displays)[i]
  let unique = {
    let head = "uniqueId \""
    let at = index_of(info, head)
    if at < 0 {
      None
    } else {
      let rest = js_slice(info, at + head.length())
      match rest.find("\"") {
        Some(e) if e > 0 => Some(js_slice(rest, 0, b=e))
        _ => None
      }
    }
  }
  let line = match unique {
    Some(u) =>
      lines_of(ids)
      .search_by(l => l.contains("uniqueId=\"\{u}\""))
      .map(k => lines_of(ids)[k])
    None => None
  }
  match line {
    Some(l) => {
      let t = js_trim(l)
      if t.has_prefix("Display ") {
        let d = digits_at(t, 8)
        return if d == "" { None } else { Some(d) }
      }
      return None
    }
    None => ()
  }
  guard number_after(info, "layerStack ") is Some(stack) else { return None }
  if !ids.contains("(Virtual display)") || ids.contains("uniqueId=") {
    return None
  }
  let mut at : String? = None
  for l in lines_of(flinger()) {
    let t = js_trim(l)
    let display = if t.has_prefix("Display ") {
      let d = digits_at(t, 8)
      let rest = js_slice(t, 8 + d.length())
      if d != "" && rest.has_prefix(" (virtual") && boundary(rest, 9) {
        Some(d)
      } else {
        None
      }
    } else {
      None
    }
    match display {
      Some(d) => at = Some(d)
      None =>
        if l.length() > 0 && !js_space(l[0].unsafe_to_char()) {
          at = None
        } else if at is Some(a) {
          let head = "layerFilter={layerStack=\{stack}"
          let mut from = 0
          while true {
            let k = index_of(l, head, from~)
            if k < 0 {
              break
            }
            if boundary(l, k + head.length()) {
              return Some(a)
            }
            from = k + 1
          }
        }
    }
  }
  None
}

///|
/// The lines of a text as a multiline regular expression has them (`^` after any line's end).
fn js_lines(s : String) -> Array[String] {
  let out = []
  let b = StringBuilder::new()
  for c in s {
    if c == '\n' || c == '\r' || c == '\u{2028}' || c == '\u{2029}' {
      out.push(b.to_string())
      b.reset()
    } else {
      b.write_char(c)
    }
  }
  out.push(b.to_string())
  out
}

///|
/// The root tasks `am stack list` says are on display `id` (`RootTask id=7723 bounds=[…] displayId=13 userId=0`).
pub fn root_tasks_on(list : String, id : Int) -> Array[Int] {
  let out = []
  for l in js_lines(list) {
    let head = if l.has_prefix("RootTask id=") {
      "RootTask id="
    } else if l.has_prefix("Stack id=") {
      "Stack id="
    } else {
      continue
    }
    let task = digits_at(l, head.length())
    let after = head.length() + task.length()
    if task == "" || !boundary(l, after) {
      continue
    }
    // (the last `\bdisplayId=\d+` on the line: `.*` takes all it can)
    let word = "displayId="
    let mut found : String? = None
    let mut from = after
    while true {
      let k = index_of(l, word, from~)
      if k < 0 {
        break
      }
      let d = digits_at(l, k + word.length())
      if d != "" && boundary(l, k) {
        found = Some(d)
      }
      from = k + 1
    }
    match found {
      Some(d) if @session_chats.js_number(js(d)) == Some(id.to_double()) =>
        out.push(@session_chats.js_number(js(task)).unwrap().to_int())
      _ => ()
    }
  }
  out
}

// ── the displays held ──

///|
struct Held {
  grant : String
  owner : String
  mut title : String
  display : J
  opened : Double
  child : J
  socket : J
  port : Double
  server : Array[String]
  adb : String
  mut closing : Bool
}

///|
pub struct PhoneDisplays {
  w : World
  /// When a grant was last used by its agent (grants' `lastUsedAt`), Null when it is not live.
  used_at : async (String) -> J
  /// The displays of `owner`'s phone changed (one opened or closed).
  changed : async (String) -> Unit
  file : String
  idle_most : Double?
  held : Map[String, Held]
  opening : Map[String, @effect.Deferred[J]]
  mut check : (() -> Unit)?
  mut closed : Bool
}

///|
/// The displays, scrcpy's server at `file` (`SERVER_FILE`); `idle_most`: IDLE_MS where not given.
pub fn PhoneDisplays::new(
  w : World,
  file : String,
  used_at : async (String) -> J,
  changed : async (String) -> Unit,
  idle_most? : Double,
) -> PhoneDisplays {
  {
    w,
    used_at,
    changed,
    file,
    idle_most,
    held: {},
    opening: {},
    check: None,
    closed: false,
  }
}

///|
/// What adb says to `args` within ADB_TIMEOUT: its output where it ended well, else why not (displays.ts `adbRun`).
async fn display_adb(w : World, adb : String, args : Array[String]) -> String {
  let ran = w.ask("proc.run", [
    jo([
      ("file", js(adb)),
      ("args", jsa(args)),
      ("timeout", jn(display_adb_timeout)),
      ("adbEnv", jb(true)),
    ]),
  ])
  let code = get(ran, "code")
  if code is Num(0.0) {
    text_of(at(Some(ran), "out"))
  } else {
    let err = js_trim(text_of(at(Some(ran), "err")))
    raise fail_(if err != "" { err } else { "adb ended with \{js_text(code)}" })
  }
}

///|
/// Grant `grant`'s display, made if it has none (`port`: its adb server, `serial`: the phone in it).
pub async fn PhoneDisplays::open(
  self : PhoneDisplays,
  grant : String,
  owner : String,
  title : String,
  port : Int,
  serial : String,
) -> J {
  match self.held.get(grant) {
    Some(h) if !h.closing => {
      h.title = title
      return h.display
    }
    _ => ()
  }
  let opening = match self.opening.get(grant) {
    Some(d) => d
    None => {
      let d : @effect.Deferred[J] = @effect.Deferred::new()
      self.opening[grant] = d
      (self.w.spawn)(async fn() {
        let made = Ok(
          self.start(grant, owner, title, ["-P", port.to_string(), "-s", serial]),
        ) catch {
          e => Err(e)
        }
        self.opening.remove(grant)
        match made {
          Ok(v) => ignore(d.succeed(v))
          Err(e) => ignore(d.fail(e))
        }
      })
      d
    }
  }
  opening.wait()
}

///|
/// The titles of the chats whose displays are up on `owner`'s phone.
pub fn PhoneDisplays::titles(
  self : PhoneDisplays,
  owner : String,
) -> Array[String] {
  self.held
  .values()
  .filter(h => h.owner == owner && !h.closing)
  .map(h => h.title)
  .collect()
}

///|
/// Whether grant `grant` has a display up.
pub fn PhoneDisplays::has(self : PhoneDisplays, grant : String) -> Bool {
  self.held.get(grant) is Some(h) && !h.closing
}

///|
/// The last three lines of what scrcpy said, on one line.
fn last_said(said : String) -> String {
  let lines = js_trim(said).split("\n").map(l => l.to_owned()).collect()
  let from = @cmp.maximum(0, lines.length() - 3)
  lines[from:].to_array().join(" ")
}

///|
async fn PhoneDisplays::start(
  self : PhoneDisplays,
  grant : String,
  owner : String,
  title : String,
  server : Array[String],
) -> J {
  let w = self.w
  let adb = match w.ask("adb.path", []) {
    Str(_) as a => js_text(a)
    _ => raise fail_("adb is not on this machine")
  }
  let run = async fn(args : Array[String]) -> String {
    display_adb(w, adb, server + args)
  }
  let shell = async fn(command : String) -> String {
    run(["shell", "\{display_mark} \{command}"])
  }
  let sdk = js_num(js_trim(shell("getprop ro.build.version.sdk")))
  let (width, height) = size_of(shell("wm size"))
  let density = density_of(shell("wm density"))
  if width == 0.0 || density == 0.0 {
    raise fail_("the phone did not say its screen's size")
  }
  let scid = {
    let n = w.ask("random.int", [ji(1), ji(0x7fffffff)])
    let hex = num_of(Some(n)).unwrap_or(1.0).to_int().to_string(radix=16)
    "0".repeat(@cmp.maximum(0, 8 - hex.length())) + hex
  }
  // Kept on the phone for the next (the link to it may carry 0.1 MB/s): put again when it is not the same.
  let jar = "/data/local/tmp/stillfail-display-\{server_version}.jar"
  let there = js_num(
    js_trim(shell("stat -c %s \{jar} 2>/dev/null") catch { _ => "" }),
  )
  let size = num_of(Some(w.ask("fs.size", [js(self.file)]))).unwrap_or(
    @double.not_a_number,
  )
  if there != size {
    ignore(run(["push", self.file, jar]))
  }
  let port = js_num(
    js_trim(run(["forward", "tcp:0", "localabstract:scrcpy_\{scid}"])),
  )
  if !is_int(port) || port <= 0.0 {
    raise fail_("adb gave no port for the display")
  }
  let args = [
    "scid=\{scid}",
    "log_level=info",
    "audio=false",
    "control=false",
    "tunnel_forward=true",
    "cleanup=false",
    "video_codec=h264",
    "max_size=320",
    "max_fps=1",
    "video_bit_rate=100000",
    "power_on=false",
    "new_display=\{num_text(width)}x\{num_text(height)}/\{num_text(density)}",
  ]
  // No keyboard shown for it, on it or on the person's screen: the agent types by key events, which need none.
  if sdk >= 33.0 {
    args.push("display_ime_policy=hide")
  }
  let child = w.ask("proc.start", [
    jo([
      ("file", js(adb)),
      (
        "args",
        jsa(
          server +
          [
            "shell",
            "\{display_mark} CLASSPATH=\{jar} app_process / com.genymobile.scrcpy.Server \{server_version} \{args.join(" ")}",
          ],
        ),
      ),
      ("adbEnv", jb(true)),
    ]),
  ])
  let said = async fn() -> (String, Bool) {
    let s = w.ask("proc.said", [child])
    (text_of(at(Some(s), "said")), at(Some(s), "ended") is Some(Bool(true)))
  }
  let mut socket : J = Null
  let fail = async fn(why : String) -> Unit {
    if !(socket is Null) {
      ignore(w.ask("net.destroy", [socket]))
    }
    ignore(w.ask("proc.kill", [child]))
    let forward_port = num_text(port)
    (w.spawn)(async fn() {
      ignore(
        display_adb(
          w,
          adb,
          server + ["forward", "--remove", "tcp:\{forward_port}"],
        ),
      ) catch {
        _ => ()
      }
    })
    let (s, _) = said()
    let last = last_said(s)
    raise fail_(if last != "" { last } else { why })
  }
  // (a forward tunnel takes a connection before anything listens: the byte the program sends first says it does)
  let until = (w.now)() + start_timeout
  while socket is Null {
    let (_, ended) = said()
    if ended {
      fail("scrcpy ended")
    }
    if (w.now)() > until {
      fail("scrcpy did not start")
    }
    let s = w.ask("net.connect", [jo([("port", jn(port))])]) catch { _ => Null }
    if !(s is Null) && w.ask("net.first", [s]) is Bool(true) {
      socket = s
      break
    }
    if !(s is Null) {
      ignore(w.ask("net.destroy", [s]))
    }
    w.sleep(100.0)
  }
  // Read only to keep it flowing (scrcpy blocks on a full socket).
  ignore(w.ask("net.keep", [socket]))
  let mut made = display_of(said().0)
  while made is Null {
    let (_, ended) = said()
    if ended {
      fail("scrcpy ended")
    }
    if (w.now)() > until {
      fail("scrcpy made no display")
    }
    w.sleep(100.0)
    made = display_of(said().0)
  }
  let id = num_of(at(Some(made), "id")).unwrap().to_int()
  let surface = surface_of(
    shell("dumpsys display") catch {
      _ => ""
    },
    shell("dumpsys SurfaceFlinger --display-id") catch {
      _ => ""
    },
    id,
    async fn() { shell("dumpsys SurfaceFlinger") catch { _ => "" } },
  )
  let display = set_field(
    made,
    "surface",
    js(surface.unwrap_or(id.to_string())),
  )
  let held : Held = {
    grant,
    owner,
    title,
    display,
    opened: (w.now)(),
    child,
    socket,
    port,
    server,
    adb,
    closing: false,
  }
  self.held[grant] = held
  let gone = async fn() { self.gone(held) }
  (w.spawn)(async fn() {
    ignore(w.ask("proc.closed", [child])) catch {
      _ => ()
    }
    gone()
  })
  (w.spawn)(async fn() {
    ignore(w.ask("net.closed", [socket])) catch {
      _ => ()
    }
    gone()
  })
  // (ended while it was looked at)
  let (s, ended) = said()
  if self.closed || ended || w.ask("net.destroyed", [socket]) is Bool(true) {
    gone()
    let last = last_said(s)
    raise fail_(
      if self.closed {
        "the station is stopping"
      } else if last != "" {
        last
      } else {
        "scrcpy ended"
      },
    )
  }
  w.log(
    "info",
    "adb",
    "a chat's display made on the phone",
    jo([
      ("grant", js(grant)),
      ("id", ji(id)),
      ("surface", jopt(surface)),
      (
        "size",
        js("\{js_text(get(made, "width"))}x\{js_text(get(made, "height"))}"),
      ),
    ]),
  )
  self.watch()
  (self.changed)(owner)
  display
}

///|
/// Done once its apps are closed and scrcpy is ended (the grant's adb server is still needed till then).
async fn PhoneDisplays::gone(self : PhoneDisplays, held : Held) -> Unit {
  guard self.held.get(held.grant) is Some(h) && physical_equal(h, held) else {
    return
  }
  self.held.remove(held.grant)
  held.closing = true
  let w = self.w
  let shell = async fn(command : String) -> String {
    display_adb(
      w,
      held.adb,
      held.server + ["shell", "\{display_mark} \{command}"],
    )
  }
  // Its apps closed before it: left to Android as the display goes, ColorOS's Settings stayed half-removed, in the
  // recents and on a display the phone kept (2026-11-04).
  let exited = !(get(w.ask("proc.said", [held.child]), "exitCode") is Null)
  let alive = !exited && !(w.ask("net.destroyed", [held.socket]) is Bool(true))
  let done : @effect.Deferred[Unit] = @effect.Deferred::new()
  w.log(
    "info",
    "adb",
    "a chat's display closed",
    jo([("grant", js(held.grant))]),
  )
  (self.changed)(held.owner)
  if self.held.length() == 0 {
    match self.check {
      Some(stop) => stop()
      None => ()
    }
    self.check = None
  }
  (w.spawn)(async fn() {
    if alive {
      try {
        let list = shell("am stack list")
        let tasks = root_tasks_on(
          list,
          num_of(at(Some(held.display), "id")).unwrap_or(-1.0).to_int(),
        )
        if tasks.length() > 0 {
          ignore(shell(tasks.map(t => "am stack remove \{t}").join("; ")))
        }
      } catch {
        _ => ()
      }
    }
    ignore(w.ask("net.destroy", [held.socket])) catch {
      _ => ()
    }
    ignore(w.ask("proc.kill", [held.child])) catch {
      _ => ()
    }
    ignore(
      display_adb(
        w,
        held.adb,
        held.server + ["forward", "--remove", "tcp:\{num_text(held.port)}"],
      ),
    ) catch {
      _ => ()
    }
    ignore(done.succeed(()))
  })
  done.wait()
}

///|
/// Grant `grant`'s display closed (the grant ended, handed back); its apps close with it. Done when the phone is
/// through with it.
pub async fn PhoneDisplays::close(self : PhoneDisplays, grant : String) -> Unit {
  match self.held.get(grant) {
    Some(h) => self.gone(h)
    None => ()
  }
}

///|
fn PhoneDisplays::watch(self : PhoneDisplays) -> Unit {
  if self.check is Some(_) {
    return
  }
  self.arm()
}

///|
fn PhoneDisplays::arm(self : PhoneDisplays) -> Unit {
  // timer: a sample of what the agents used the phones for, to close what nothing used
  self.check = Some(
    self.w.after(idle_check, async fn() {
      self.arm()
      self.idle()
    }),
  )
}

///|
/// The displays whose grants nothing of the agent's used for IDLE_MS (nor since they were made) closed.
pub async fn PhoneDisplays::idle(self : PhoneDisplays) -> Unit {
  let now = (self.w.now)()
  let most = self.idle_most.unwrap_or(idle_ms)
  for held in self.held.values().collect() {
    let used = (self.used_at)(held.grant)
    let idle = match used {
      Num(u) => now - @cmp.maximum(u, held.opened) >= most
      _ => true
    }
    if idle {
      (self.w.spawn)(async fn() { self.gone(held) })
    }
  }
}

///|
/// Every display closed (the station stopping).
pub fn PhoneDisplays::close_all(self : PhoneDisplays) -> Unit {
  self.closed = true
  for held in self.held.values().collect() {
    (self.w.spawn)(async fn() { self.gone(held) })
  }
}
