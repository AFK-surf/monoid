// What a person debugging an app on an iOS Simulator has beside its picture (src/screens/sim-debug.ts): the logs of
// the apps installed on it and their restart, all simctl's. The log is `log stream` inside the device, started as it
// is first asked for and left running a while after, its newest lines held here. Only apps a person installed log
// into it, and of those only what the app's own code says, Foundation's for it (NSLog) and any error.

///|
/// One line of an app's log, `seq` counting from the first this device's stream held.
pub(all) struct SimLog {
  seq : Int
  at : String
  level : String
  app : String
  text : String
}

///|
pub fn SimLog::to_j(self : SimLog) -> J {
  jo([("seq", ji(self.seq)), ("at", js(self.at)), ("level", js(self.level)), ("app", js(self.app)), ("text", js(self.text))])
}

///|
/// An app a person installed on the device.
pub(all) struct SimApp {
  id : String
  name : String
  running : Bool
}

///|
pub fn SimApp::to_j(self : SimApp) -> J {
  jo([("id", js(self.id)), ("name", js(self.name)), ("running", jb(self.running))])
}

///|
let appearances : Array[String] = ["light", "dark"]

///|
let text_sizes : Array[String] = [
  "extra-small", "small", "medium", "large", "extra-large", "extra-extra-large", "extra-extra-extra-large", "accessibility-medium",
  "accessibility-large", "accessibility-extra-large", "accessibility-extra-extra-large", "accessibility-extra-extra-extra-large",
]

///|
/// A command run to its end: its stdout (simulator.ts `Run`).
pub(all) struct Run {
  run : async (String, Array[String]) -> String
}

///|
/// `simctl io recordVideo`'s process: started (it said so, or a moment went by), ended, and how it is stopped.
pub(all) struct Recording {
  started : @effect.Deferred[Unit]
  ended : @effect.Deferred[Unit]
  stop : () -> Unit
}

///|
/// `log stream`'s process, its stdout read line by line; the returned function stops it.
pub(all) struct LogStream {
  start : (Array[String], (String) -> Unit, () -> Unit) -> (() -> Unit)
}

///|
const HELD : Int = 2000

///|
const SENT : Int = 500

///|
/// How long the stream goes on after the last time it was asked for.
const IDLE_MS : Double = 600000

///|
const PREDICATE : String = "processImagePath CONTAINS \"/Containers/Bundle/Application/\" AND (senderImagePath CONTAINS \"/Containers/Bundle/Application/\" OR senderImagePath ENDSWITH \"/Foundation\" OR messageType == error OR messageType == fault)"

///|
const MAX_URL : Int = 8192

///|
const APP_DEPTH : Int = 3

///|
const ENROLLED : String = "com.apple.BiometricKit.enrollmentChanged"

///|
/// The panels of an iPhone Duo as `simctl io` numbers its displays.
const DISPLAY_COVER : Int = 1

///|
const DISPLAY_INNER : Int = 3

///|
/// The longest a recording goes on: one left running does not fill the disk.
const RECORD_MS : Double = 600000

///|
const RECORD_START_MS : Double = 5000

///|
const RECORD_STOP_MS : Double = 15000

///|
let tidy_bar : Array[String] = [
  "override", "--time", "9:41", "--dataNetwork", "wifi", "--wifiMode", "active", "--wifiBars", "3", "--cellularMode",
  "active", "--cellularBars", "4", "--batteryState", "charged", "--batteryLevel", "100",
]

///|
/// `/^[A-Za-z0-9][A-Za-z0-9.-]*$/`.
pub fn is_bundle_id(s : String) -> Bool {
  let cs = s.to_array()
  if cs.length() == 0 {
    return false
  }
  let alnum = (c : Char) => (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9')
  if !alnum(cs[0]) {
    return false
  }
  for c in cs[1:] {
    if !(alnum(c) || c == '.' || c == '-') {
      return false
    }
  }
  true
}

///|
/// `/^[A-Za-z][A-Za-z0-9+.-]*:\S*$/`.
fn is_url_scheme(s : String) -> Bool {
  let cs = s.to_array()
  if cs.length() == 0 || !((cs[0] >= 'A' && cs[0] <= 'Z') || (cs[0] >= 'a' && cs[0] <= 'z')) {
    return false
  }
  let mut i = 1
  while i < cs.length() {
    let c = cs[i]
    if (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '+' || c == '.' || c == '-' {
      i += 1
    } else {
      break
    }
  }
  if i >= cs.length() || cs[i] != ':' {
    return false
  }
  for c in cs[i + 1:] {
    if is_js_space(c) {
      return false
    }
  }
  true
}

///|
/// The quarter turns clockwise a panel's picture is shown at, from `simctl io enumerate`'s words of it.
pub fn turn_of(said : String, panel : String) -> Int {
  let blocks = said.split("Device Name: ").map(v => v.to_string()).collect()
  for block in blocks[1:] {
    if !block.has_prefix("\{panel}\n") {
      continue
    }
    let lines = block.split("\n").map(v => v.to_string()).collect()
    match lines.search_by(l => l.contains("UI Orientation:")) {
      Some(i) => {
        let line = trim_end_js(lines[i])
        if line.has_suffix("Landscape Left") {
          return 1
        }
        if line.has_suffix("Landscape Right") {
          return 3
        }
        if line.has_suffix("Portrait Upside Down") {
          return 2
        }
      }
      None => ()
    }
    return 0
  }
  0
}

///|
/// The movie at `file` said to be shown `turn` quarter turns clockwise (its video track's matrix): nothing encoded
/// again.
pub async fn turn_movie(io : Io, file : String, turn : Int) -> Bool {
  // (opened r+: a file that is not there fails as it does)
  let size = (io.fs.stat)(file).size
  if size == 0.0 {
    return false
  }
  if turn == 0 {
    return true
  }
  let read = async fn(at : Double, n : Int) -> FixedArray[Byte] {
    let got = (io.fs.read_at)(file, at, n)
    let b = FixedArray::make(n, b'\x00')
    for i in 0..<got.length() {
      if i < n {
        b[i] = got[i]
      }
    }
    b
  }
  let head = async fn(at : Double) -> (String, Double, Double) {
    let b = Bytes::from_array(read(at, 16))
    let short = u32be(b, 0)
    let long = short == 1L
    (
      latin1_text(b[4:8]),
      if long { u64be(b, 8).to_double() } else if short == 0L { size - at } else { short.to_double() },
      if long { 16.0 } else { 8.0 },
    )
  }
  let find = async fn(name : String, from : Double, to : Double) -> (Double, Double, Double)? {
    let mut at = from
    while at + 8.0 <= to {
      let (kind, length, skip) = head(at)
      if length < 8.0 {
        return None
      }
      if kind == name {
        return Some((at + skip, at + length, length))
      }
      at = at + length
    }
    None
  }
  guard find("moov", 0.0, size) is Some(moov) else { return false }
  let mut at = moov.0
  while at + 8.0 <= moov.1 {
    let (kind, length, skip) = head(at)
    if length < 8.0 {
      return false
    }
    if kind == "trak" {
      let tkhd = find("tkhd", at + skip, at + length)
      let mdia = find("mdia", at + skip, at + length)
      let hdlr = match mdia {
        Some(m) => find("hdlr", m.0, m.1)
        None => None
      }
      let handler = match hdlr {
        Some(h) => latin1_text(Bytes::from_array(read(h.0 + 8.0, 4)))
        None => "\u{0}\u{0}\u{0}\u{0}"
      }
      match tkhd {
        Some(t) if handler == "vide" => {
          let version = read(t.0, 1)
          let matrix = t.0 + (if version[0] == b'\x01' { 52.0 } else { 40.0 })
          let shape = Bytes::from_array(read(matrix + 36.0, 8))
          let w = u32be(shape, 0)
          let h = u32be(shape, 4)
          let one = 0x10000L
          // a b u, c d v, tx ty w: (x, y) goes to (ax + cy + tx, bx + dy + ty), in 16.16 but u, v and w
          let m = if turn == 1 {
            [0L, one, 0L, -one, 0L, 0L, h, 0L]
          } else if turn == 2 {
            [-one, 0L, 0L, 0L, -one, 0L, w, h]
          } else {
            [0L, -one, 0L, one, 0L, 0L, 0L, w]
          }
          let out = FixedArray::make(36, b'\x00')
          for i, v in m {
            if v > 2147483647L || v < -2147483648L {
              raise fail("The value of \"value\" is out of range.")
            }
            put_u32be(out, i * 4, v & 0xffffffffL)
          }
          put_u32be(out, 32, 0x40000000L)
          (io.fs.write_at)(file, matrix, Bytes::from_array(out))
          return true
        }
        _ => ()
      }
    }
    at = at + length
  }
  false
}

///|
/// The first .app under `dir`, at most `depth` folders down (an .ipa's in Payload, a build's zip with a folder round it).
async fn app_in(io : Io, dir : String, depth : Int) -> String? {
  let entries = (io.fs.readdir)(dir)
  for e in entries {
    if e.dir && e.name.has_suffix(".app") {
      return Some(pj([dir, e.name]))
    }
  }
  if depth <= 0 {
    return None
  }
  for e in entries {
    if !e.dir || e.name == "__MACOSX" {
      continue
    }
    match app_in(io, pj([dir, e.name]), depth - 1) {
      Some(found) => return Some(found)
      None => ()
    }
  }
  None
}

///|
/// A line of `log stream --style ndjson` as a person reads it; none for what is not one.
pub fn log_of(line : String) -> (String, String, String, String)? {
  let e = (try Some(parse(line)) catch { _ => None })
  guard e is Some(e) else { return None }
  guard text(get(Some(e), "eventMessage")) is Some(message) else { return None }
  let image = text(get(Some(e), "processImagePath")).unwrap_or("")
  let app = match image.rev_find("/") {
    Some(i) => image.unsafe_substring(start=i + 1, end=image.length())
    None => image
  }
  Some((text(get(Some(e), "timestamp")).unwrap_or(""), text(get(Some(e), "messageType")).unwrap_or(""), app, message))
}

///|
/// The apps a person installed, from `simctl listapps` (as JSON) and what `launchctl list` inside the device runs.
pub fn apps_of(installed : J, launchctl : String) -> Array[SimApp] {
  let running = []
  let mut from = 0
  let marker = "UIKitApplication:"
  while true {
    let i = match launchctl.unsafe_substring(start=from, end=launchctl.length()).find(marker) {
      Some(i) => from + i
      None => break
    }
    let start = i + marker.length()
    let mut j = start
    while j < launchctl.length() {
      let c = launchctl.unsafe_get(j).to_int()
      if c == '['.to_int() || is_js_space(Int::unsafe_to_char(c)) {
        break
      }
      j += 1
    }
    if j > start && j < launchctl.length() && launchctl.unsafe_get(j).to_int() == '['.to_int() {
      running.push(launchctl.unsafe_substring(start~, end=j))
      from = j + 1
    } else {
      from = i + 1
    }
  }
  let apps = []
  let entries : Array[(String, J)] = match installed {
    Obj(ps) => ps.map(p => (@jsjson.sanitize_str(p.0), p.1))
    Arr(xs) => xs.mapi((i, x) => (i.to_string(), x))
    _ => []
  }
  for p in entries {
    let (id, app) = p
    if text(get(Some(app), "ApplicationType")) != Some("User") {
      continue
    }
    let name = match string_of(get(Some(app), "CFBundleDisplayName")) {
      Some(n) => n
      None => string_of(get(Some(app), "CFBundleName")).unwrap_or(id)
    }
    apps.push({ id, name, running: running.contains(id) })
  }
  apps.sort_by((a, b) => {
    let r = (if b.running { 1 } else { 0 }) - (if a.running { 1 } else { 0 })
    if r != 0 {
      return r
    }
    let n = locale_compare(a.name, b.name)
    if n != 0 {
      n
    } else {
      locale_compare(a.id, b.id)
    }
  })
  apps
}

///|
/// `simctl io recordVideo` started: told started as it says "Recording started" (or it ended, or a moment went by).
pub fn recorder(io : Io) -> (Array[String]) -> Recording {
  args => {
    let ended : @effect.Deferred[Unit] = @effect.Deferred::new()
    let started : @effect.Deferred[Unit] = @effect.Deferred::new()
    let out = Buffer()
    let child = (io.procs.spawn)(
      args[0],
      args[1:].to_array(),
      { env: None, group: false, verbatim: false, stdio: ("ignore", "pipe", "ignore") },
      {
        out: chunk => {
          out.write_bytes(chunk)
          if @utf8.decode_lossy(chunk).contains("Recording started") {
            ignore(started.succeed(()))
          }
        },
        err: _ => (),
        error: _ => {
          ignore(ended.succeed(()))
          ignore(started.succeed(()))
        },
        close: (_, _) => {
          ignore(ended.succeed(()))
          ignore(started.succeed(()))
        },
      },
    )
    ignore((io.clock.after)(RECORD_START_MS, () => ignore(started.succeed(()))))
    {
      started,
      ended,
      stop: () => {
        // (SIGINT is what ends it with its movie whole)
        (child.kill)("SIGINT")
        ignore((io.clock.after)(RECORD_STOP_MS, () => (child.kill)("SIGKILL")))
      },
    }
  }
}

///|
/// `log stream` started, its stdout's lines told.
pub fn log_stream(io : Io) -> LogStream {
  {
    start: (args, line, ended) => {
      let rest = Ref("")
      let child = (io.procs.spawn)(
        args[0],
        args[1:].to_array(),
        { env: None, group: false, verbatim: false, stdio: ("ignore", "pipe", "ignore") },
        {
          out: chunk => {
            let parts = (rest.val + @utf8.decode_lossy(chunk)).split("\n").map(v => v.to_string()).collect()
            rest.val = parts.pop().unwrap_or("")
            for p in parts {
              line(p)
            }
          },
          err: _ => (),
          error: _ => ended(),
          close: (_, _) => ended(),
        },
      )
      () => (child.kill)("SIGTERM")
    },
  }
}

///|
/// One booted device's logs and apps (sim-debug.ts `SimDebug`).
pub struct SimDebug {
  priv io : Io
  priv simctl : String
  priv udid : String
  priv run : Run
  priv stream : LogStream
  priv picture : async () -> Bytes
  priv held : Array[SimLog]
  priv mut next : Int
  priv mut running : (Int, () -> Unit)?
  priv mut idle : (() -> Unit)?
  priv mut closed : Bool
  priv record : (Array[String]) -> Recording
  priv mut recording_ : (Recording, String, String, Int, () -> Unit)?
  priv mut streams : Int
}

///|
/// `picture`: the device's screen as a view has it (a JPEG).
pub fn SimDebug::new(
  io : Io,
  simctl : String,
  udid : String,
  run : Run,
  picture : async () -> Bytes,
  stream? : LogStream? = None,
  record? : ((Array[String]) -> Recording)? = None,
) -> SimDebug {
  {
    io,
    simctl,
    udid,
    run,
    stream: stream.unwrap_or(log_stream(io)),
    picture,
    held: [],
    next: 0,
    running: None,
    idle: None,
    closed: false,
    record: record.unwrap_or(recorder(io)),
    recording_: None,
    streams: 0,
  }
}

///|
async fn SimDebug::sh(self : SimDebug, file : String, args : Array[String]) -> String {
  (self.run.run)(file, args)
}

///|
/// The lines after `after` (the newest of them if there are more than go at once), and where to ask from next.
pub fn SimDebug::logs(self : SimDebug, after : Double) -> (Int, Array[SimLog]) {
  self.follow()
  let lines = self.held.filter(l => l.seq.to_double() >= after)
  let from = if lines.length() > SENT { lines.length() - SENT } else { 0 }
  (self.next, lines[from:].to_array())
}

///|
pub async fn SimDebug::apps(self : SimDebug) -> Array[SimApp] {
  let got = @effect.all([
    // listapps says an old-style plist, which only plutil reads, from its stdin here.
    async fn() {
      self.sh("/bin/sh", ["-c", "\"$0\" listapps \"$1\" | plutil -convert json -o - -", self.simctl, self.udid])
    },
    async fn() { self.sh(self.simctl, ["spawn", self.udid, "launchctl", "list"]) },
  ])
  apps_of(parse(got[0]), got[1])
}

///|
async fn SimDebug::installed(self : SimDebug, app : String) -> Bool {
  is_bundle_id(app) && self.apps().iter().any(a => a.id == app)
}

///|
/// Ends `app` if it runs, and starts it; false when it is no app a person installed here.
pub async fn SimDebug::relaunch(self : SimDebug, app : String) -> Bool {
  if !self.installed(app) {
    return false
  }
  self.follow()
  ignore(self.sh(self.simctl, ["launch", "--terminate-running-process", self.udid, app]))
  true
}

///|
pub async fn SimDebug::settings(self : SimDebug) -> J {
  let got = @effect.all([
    async fn() { self.sh(self.simctl, ["ui", self.udid, "appearance"]) },
    async fn() { self.sh(self.simctl, ["ui", self.udid, "content_size"]) },
    async fn() { self.sh(self.simctl, ["spawn", self.udid, "notifyutil", "-g", ENROLLED]) catch { _ => "" } },
  ])
  jo([
    ("appearance", js(trim_js(got[0]))),
    ("textSize", js(trim_js(got[1]))),
    ("recording", jb(self.recording_ is Some(_))),
    ("enrolled", jb(trim_js(got[2]).has_suffix(" 1"))),
  ])
}

///|
/// Sets one of them; false when it is no such setting or value.
pub async fn SimDebug::set_setting(self : SimDebug, name : String, value : String) -> Bool {
  let allowed = if name == "appearance" {
    appearances
  } else if name == "textSize" {
    text_sizes
  } else {
    []
  }
  if !allowed.contains(value) {
    return false
  }
  ignore(self.sh(self.simctl, ["ui", self.udid, if name == "appearance" { "appearance" } else { "content_size" }, value]))
  true
}

///|
/// Opens a link in it (its browser, or the app that takes it: a deep link); false when it is no URL.
pub async fn SimDebug::open_url(self : SimDebug, url : String) -> Bool {
  if units_len(url) > MAX_URL || !is_url_scheme(url) {
    return false
  }
  ignore(self.sh(self.simctl, ["openurl", self.udid, url]))
  true
}

///|
/// `^\s*(-?\d{1,2}(?:\.\d+)?)\s*,\s*(-?\d{1,3}(?:\.\d+)?)\s*$`: the place's two numbers as said.
fn place_of(at : String) -> (String, String)? {
  let r = Reader::new(at, 0)
  let number = (most : Int) => {
    let was = r.at
    ignore(r.eat('-'))
    let d = r.digits()
    match d {
      Some(d) if d.length() <= most => ()
      _ => {
        r.at = was
        return None
      }
    }
    if r.peek() == Some('.') {
      let dot = r.at
      r.at += 1
      if r.digits() is None {
        r.at = dot
      }
    }
    Some(String::from_array(r.s[was:r.at]))
  }
  r.spaces()
  guard number(2) is Some(a) else { return None }
  r.spaces()
  if !r.eat(',') {
    return None
  }
  r.spaces()
  guard number(3) is Some(b) else { return None }
  r.spaces()
  if r.at != r.s.length() {
    return None
  }
  Some((a, b))
}

///|
/// Puts it at `at` ("latitude,longitude"), or back to none; false when that is no place.
pub async fn SimDebug::location(self : SimDebug, at : String?) -> Bool {
  guard at is Some(at) else {
    ignore(self.sh(self.simctl, ["location", self.udid, "clear"]))
    return true
  }
  guard place_of(at) is Some((a, b)) else { return false }
  if abs_d(js_number(a)) > 90.0 || abs_d(js_number(b)) > 180.0 {
    return false
  }
  ignore(self.sh(self.simctl, ["location", self.udid, "set", "\{a},\{b}"]))
  true
}

///|
/// Its status bar tidy, as App Store screenshots have it, or as it really is.
pub async fn SimDebug::status_bar(self : SimDebug, tidy : Bool) -> Unit {
  ignore(self.sh(self.simctl, ["status_bar", self.udid] + (if tidy { tidy_bar } else { ["clear"] })))
}

///|
/// A notification saying `text` to `app`; false when it is no app a person installed here or says nothing.
pub async fn SimDebug::push(self : SimDebug, app : String, words : String) -> Bool {
  if trim_js(words) == "" || !self.installed(app) {
    return false
  }
  let file = pj([(self.io.os.tmpdir)(), "stillfail-sim-\{self.io.random_hex(8)}.apns"])
  try {
    (self.io.fs.write)(file, @utf8.encode(stringify(jo([("aps", jo([("alert", js(words)), ("sound", js("default"))]))]))), None)
    ignore(self.sh(self.simctl, ["push", self.udid, app, file]))
  } catch {
    e => {
      (self.io.fs.rm)(file, false, true)
      raise e
    }
  }
  (self.io.fs.rm)(file, false, true)
  true
}

///|
/// Where a file to install on it goes up to (`install`): among the machine's temporary files. Made there off the
/// station's thread as it is named.
pub fn SimDebug::install_folder(self : SimDebug) -> String {
  let folder = pj([(self.io.os.tmpdir)(), "stillfail-sim-install"])
  self.io.go(async fn() { (self.io.fs.mkdir)(folder, true, None) })
  folder
}

///|
/// The app in `path` (an .ipa, or a .zip with a .app in it, in `install_folder`) installed and started, the file let go
/// of: its bundle id; none when that is no such file or there is no app in it.
pub async fn SimDebug::install(self : SimDebug, path : String) -> String? {
  let resolved = if path.has_prefix("/") { pj([path]) } else { pj([self.io.os.cwd, path]) }
  let lower = path.to_lower()
  if @nodepath.dirname("/", resolved) != self.install_folder() ||
    !(lower.has_suffix(".ipa") || lower.has_suffix(".zip")) ||
    @nodepath.basename("/", path).has_prefix("-") {
    return None
  }
  let out = (self.io.fs.mkdtemp)(pj([(self.io.os.tmpdir)(), "stillfail-sim-app-"]))
  let tidy = async fn() {
    ignore(
      @effect.all([
        async fn() { (self.io.fs.rm)(out, true, true) catch { _ => () } },
        async fn() { (self.io.fs.rm)(path, false, true) catch { _ => () } },
      ]),
    )
  }
  let result = try Ok({
    // (what does not unpack is no such file either)
    let unpacked = {
      ignore(self.sh("ditto", ["-x", "-k", path, out]))
      true
    } catch {
      _ => false
    }
    if !unpacked {
      None
    } else {
      match app_in(self.io, out, APP_DEPTH) {
        None => None
        Some(app) => {
          ignore(self.sh(self.simctl, ["install", self.udid, app]))
          let id = text(get(Some(parse(self.sh("plutil", ["-convert", "json", "-o", "-", pj([app, "Info.plist"])]))), "CFBundleIdentifier"))
          match id {
            Some(id) if is_bundle_id(id) => {
              ignore(self.sh(self.simctl, ["launch", "--terminate-running-process", self.udid, id]))
              Some(id)
            }
            _ => None
          }
        }
      }
    }
  }) catch {
    e => Err(e)
  }
  tidy()
  match result {
    Ok(v) => v
    Err(e) => raise e
  }
}

///|
/// Takes `app` a person installed off it; false when it is none.
pub async fn SimDebug::uninstall(self : SimDebug, app : String) -> Bool {
  if !self.installed(app) {
    return false
  }
  ignore(self.sh(self.simctl, ["uninstall", self.udid, app]))
  true
}

///|
/// Face ID or Touch ID: enrolled or not, or the face or finger shown just now to what asks for it. False when it is no
/// such thing.
pub async fn SimDebug::biometrics(self : SimDebug, what : String) -> Bool {
  let notify = async fn(args : Array[String]) { ignore(self.sh(self.simctl, ["spawn", self.udid, "notifyutil"] + args)) }
  if what == "enrol" || what == "unenrol" {
    notify(["-s", ENROLLED, if what == "enrol" { "1" } else { "0" }])
    notify(["-p", ENROLLED])
    return true
  }
  if what != "match" && what != "nomatch" {
    return false
  }
  notify(["-p", "com.apple.BiometricKit_Sim.pearl.\{what}"])
  true
}

///|
/// Starts recording its screen, `panel`'s where it has two ("inner" or "cover"); what it started before goes on.
pub async fn SimDebug::record_start(self : SimDebug, panel : String?) -> Unit {
  if self.recording_ is Some(_) {
    return
  }
  let folder = pj([(self.io.os.tmpdir)(), "stillfail-sim-recordings"])
  (self.io.fs.rm)(folder, true, true)
  (self.io.fs.mkdir)(folder, true, None)
  let name = "\{slice_units(self.udid, 0, 8)}-\{self.io.random_hex(4)}.mp4"
  let file = pj([folder, name])
  let turn = if panel == Some("inner") {
    turn_of(self.sh(self.simctl, ["io", self.udid, "enumerate"]), "primary-1")
  } else {
    0
  }
  let display = match panel {
    None => []
    Some(p) => ["--display=\{if p == "inner" { DISPLAY_INNER } else { DISPLAY_COVER }}"]
  }
  let child = (self.record)([self.simctl, "io", self.udid, "recordVideo", "--codec=h264"] + display + ["--force", file])
  let limit = (self.io.clock.after)(RECORD_MS, () => (child.stop)())
  self.recording_ = Some((child, folder, name, turn, limit))
  child.started.wait()
}

///|
pub fn SimDebug::recording(self : SimDebug) -> Bool {
  self.recording_ is Some(_)
}

///|
/// Ends the recording and says where its movie is, the drive's way (`root`, `path`); none when none goes on.
pub async fn SimDebug::record_stop(self : SimDebug) -> (String, String)? {
  guard self.recording_ is Some((child, folder, name, turn, limit)) else { return None }
  self.recording_ = None
  limit()
  (child.stop)()
  child.ended.wait()
  let ok = turn_movie(self.io, pj([folder, name]), turn) catch { _ => false }
  if !ok {
    raise fail("nothing was recorded")
  }
  Some((folder, name))
}

///|
/// The device's screen as a PNG, in its own pixels.
pub async fn SimDebug::screenshot(self : SimDebug) -> Bytes {
  let base = pj([(self.io.os.tmpdir)(), "stillfail-sim-\{self.io.random_hex(8)}"])
  let tidy = async fn() {
    ignore(
      @effect.all([
        async fn() { (self.io.fs.rm)("\{base}.jpg", false, true) catch { _ => () } },
        async fn() { (self.io.fs.rm)("\{base}.png", false, true) catch { _ => () } },
      ]),
    )
  }
  let result = try Ok({
    (self.io.fs.write)("\{base}.jpg", (self.picture)(), None)
    ignore(self.sh("sips", ["-s", "format", "png", "\{base}.jpg", "--out", "\{base}.png"]))
    (self.io.fs.read)("\{base}.png")
  }) catch {
    e => Err(e)
  }
  tidy()
  match result {
    Ok(b) => b
    Err(e) => raise e
  }
}

///|
/// The device shut down (or the station stops).
pub fn SimDebug::close(self : SimDebug) -> Unit {
  self.closed = true
  match self.recording_ {
    Some((child, _, _, _, limit)) => {
      limit()
      (child.stop)()
    }
    None => ()
  }
  self.recording_ = None
  match self.idle {
    Some(f) => f()
    None => ()
  }
  match self.running {
    Some((_, stop)) => stop()
    None => ()
  }
  self.running = None
}

///|
fn SimDebug::follow(self : SimDebug) -> Unit {
  if self.closed {
    return
  }
  match self.idle {
    Some(f) => f()
    None => ()
  }
  self.idle = Some(
    (self.io.clock.after)(IDLE_MS, () => {
      match self.running {
        Some((_, stop)) => stop()
        None => ()
      }
      self.running = None
    }),
  )
  if self.running is Some(_) {
    return
  }
  let args = [self.simctl, "spawn", self.udid, "log", "stream", "--style", "ndjson", "--level", "debug", "--predicate", PREDICATE]
  self.streams += 1
  let id = self.streams
  let stop = (self.stream.start)(args, line => self.line(line), () => {
    // Its own end, not one asked for: the next look starts it again.
    match self.running {
      Some((i, _)) if i == id => self.running = None
      _ => ()
    }
  })
  self.running = Some((id, stop))
  self.io.log.info("screens", "a simulator's log followed", fields=jo([("udid", js(self.udid))]))
}

///|
fn SimDebug::line(self : SimDebug, line : String) -> Unit {
  guard log_of(line) is Some((at, level, app, text)) else { return }
  self.held.push({ seq: self.next, at, level, app, text })
  self.next += 1
  if self.held.length() > HELD {
    let drop = self.held.length() - HELD
    for _ in 0..<drop {
      ignore(self.held.remove(0))
    }
  }
}
