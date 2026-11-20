// What macOS lets still.fail Helper do on this Mac (src/helper/grants.ts): Screen Recording and Accessibility (the
// desktop seen and driven), the folders macOS protects (Documents, Desktop, Downloads, removable and network disks),
// and whether the station may reach the LAN it is on (macOS's Local Network). One look at them (the helper's
// `status`) is kept for whatever asks; at most FRESH_MS old where it matters, looked at again when the helper says a
// grant changed or comes back, and in the background once a page reads it SHOWN_MS after the last look, or after the
// last try where the helper did not answer. A refresh that may be fresh (not `force`) waits SHOWN_MS after such a try
// too: the desktop's screens listed went on starting it every few seconds (2026-11-19).
//
// The helper's window asks for a grant on this Mac, once: not again (nor brought forward) while it is up asking for
// it, nor for AGAIN_MS after it was shown for it; a person's own ask (`again`) puts it up again however lately it was
// shown.

///|
/// The grants, in the order they are shown: the screen's two, the folders', then the LAN's.
pub let grants_all : Array[String] = [
  "capture", "control", "documents", "desktop", "downloads", "removable", "network", "localNetwork",
]

///|
pub fn is_grant(v : String) -> Bool {
  grants_all.contains(v)
}

///|
let screen_grants : Array[String] = ["capture", "control"]

///|
/// System Settings' Local Network list (mesh/lan.ts `LOCAL_NETWORK_SETTINGS`).
pub const LOCAL_NETWORK_SETTINGS : String = "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork"

///|
/// The window shown for a grant is not shown (nor brought forward) again for that grant this soon after.
pub const AGAIN_MS : Double = 180000

///|
/// A look at the grants is this fresh at most where it matters.
const FRESH_MS : Double = 2000

///|
/// How long the window has to come up after the helper answered `permissions.show`, looked at every UP_MS.
const UP_TRIES : Int = 20

///|
const UP_MS : Double = 100

///|
/// The station's page reads what was looked at last; looked at again (in the background) once it is this old.
const SHOWN_MS : Double = 30000

///|
/// A grant that cannot be asked for now, and why (`key` of the station's words).
pub(all) suberror GrantRefused {
  GrantRefused(String)
}

///|
/// What System Settings' Local Network list names the station by: the app it runs in, else its launcher.
pub fn local_network_name(exec_path : String) -> String {
  let mut from = 0
  while true {
    let i = match exec_path.find_by_from(".app/Contents/", from) {
      Some(i) => i
      None => break
    }
    let s = match exec_path.unsafe_substring(start=0, end=i).rev_find("/") {
      Some(j) => j + 1
      None => 0
    }
    if i > s {
      return exec_path.unsafe_substring(start=s, end=i)
    }
    from = i + 1
  }
  "stillfail-station"
}

///|
fn String::find_by_from(self : String, needle : String, from : Int) -> Int? {
  match self.unsafe_substring(start=from, end=self.length()).find(needle) {
    Some(i) => Some(i + from)
    None => None
  }
}

///|
/// A grant's state as a status says it: "granted", "denied" or "unknown".
pub fn grant_state(s : J, grant : String) -> String {
  if grant == "capture" || grant == "control" {
    return if truthy(get(Some(s), grant)) { "granted" } else { "unknown" }
  }
  match text(get(get(Some(s), "files"), grant)) {
    Some("granted") => "granted"
    Some("denied") => "denied"
    _ => "unknown"
  }
}

///|
/// JavaScript's truthiness of a value.
fn truthy(v : J?) -> Bool {
  @jsjson.jval_truthy(v)
}

///|
/// The station's one look at the grants and its window for them (grants.ts `HelperGrants`).
pub struct HelperGrants {
  helper : HelperApp
  priv io : Io
  priv folders : Bool
  priv now : () -> Double
  priv mut status_ : J?
  priv mut checked : Double
  // (when a look was last tried, answered or not)
  priv mut attempted : Double
  priv checking : Shared[Unit]
  /// What the Helper's last failure to answer said, logged; None once it answered.
  priv mut unanswered : String?
  priv asked : Map[String, Double]
  priv listeners : Array[(Int, () -> Unit)]
  priv volumes : String
  priv mounts : async () -> Array[String]
  priv mut lan : String?
  priv reach : async () -> String?
  priv open : (String) -> Unit
  priv mut next : Int
}

///|
/// `reach`: whether the station may reach its LAN (mesh/lan.ts `lanReach`: "granted", "denied" or none).
pub fn HelperGrants::new(
  io : Io,
  helper : HelperApp,
  reach : async () -> String?,
  folders? : Bool = true,
  now? : (() -> Double)? = None,
  volumes? : String = "/Volumes",
  mounts? : (async () -> Array[String])? = None,
  open? : ((String) -> Unit)? = None,
) -> HelperGrants {
  let g = {
    helper,
    io,
    folders,
    now: now.unwrap_or(() => io.clock.ms()),
    status_: None,
    checked: @double.neg_infinity,
    attempted: @double.neg_infinity,
    checking: Shared::new(),
    unanswered: None,
    asked: {},
    listeners: [],
    volumes,
    mounts: mounts.unwrap_or(async fn() { (io.os.mounts_soon)() }),
    lan: None,
    reach,
    open: open.unwrap_or(url => io.go(async fn() {
      ignore((io.procs.exec)("open", [url], ExecOptions::new()))
    })),
    next: 0,
  }
  // Read now, off the thread, for what asks the platform's as last read.
  if mounts is None {
    io.go(async fn() { ignore((io.os.mounts_soon)()) })
  }
  // A grant changed (its window saw it), or the helper came back: looked at again.
  ignore(
    helper.listen(event => if text(get(Some(event), "event")) == Some("grants") {
      io.go(async fn() { g.refresh(force=true) })
    }),
  )
  ignore(helper.on_back(() => io.go(async fn() { g.refresh(force=true) })))
  g
}

///|
/// The last look; none before the first.
pub fn HelperGrants::status(self : HelperGrants) -> J? {
  self.status_
}

///|
/// Told when what is known of them changed.
pub fn HelperGrants::on_change(self : HelperGrants, listener : () -> Unit) -> () -> Unit {
  self.next += 1
  let id = self.next
  self.listeners.push((id, listener))
  () => take_out(self.listeners, id)
}

///|
fn HelperGrants::tell(self : HelperGrants) -> Unit {
  for l in self.listeners.copy() {
    (l.1)()
  }
}

///|
/// The grants as macOS has them now (at most FRESH_MS old, unless `force`); the helper started for it.
pub async fn HelperGrants::refresh(self : HelperGrants, force? : Bool = false) -> Unit {
  // (a look under way is waited for; the helper not answering: tried again SHOWN_MS after the last try, else FRESH_MS
  // after the last look)
  let (last, within) = if self.unanswered is Some(_) {
    (self.attempted, SHOWN_MS)
  } else {
    (self.checked, FRESH_MS)
  }
  if !force && !self.checking.is_going() && (self.now)() - last < within {
    return
  }
  self.checking
  .start(self.io, async fn() {
    self.attempted = (self.now)()
    defer {
      self.attempted = (self.now)()
    }
    ignore(
      @effect.all([
        async fn() {
          let lan = (self.reach)() catch { _ => return }
          self.learn_lan(lan)
        },
        async fn() {
          let status = self.helper.request(jo([("op", js("status"))])) catch {
            e => {
              // (said once until it answers again or says otherwise, not by the addresses in it: grants.ts)
              let said = message_of(e)
              let key = without_addresses(said)
              if self.unanswered != Some(key) {
                self.unanswered = Some(key)
                self.io.log.warn("helper", "still.fail Helper did not answer", fields=jo([("error", js(said))]))
              }
              return
            }
          }
          self.learn(status)
        },
      ]),
    )
  })
  .wait()
}

///|
fn HelperGrants::learn_lan(self : HelperGrants, lan : String?) -> Unit {
  if lan == self.lan {
    return
  }
  self.lan = lan
  if self.status_ is Some(_) {
    self.tell()
  }
}

///|
/// A grant's state as last looked at.
pub fn HelperGrants::state(self : HelperGrants, grant : String) -> String {
  if grant == "localNetwork" {
    return self.lan.unwrap_or("unknown")
  }
  match self.status_ {
    None => "unknown"
    Some(s) => grant_state(s, grant)
  }
}

///|
fn HelperGrants::learn(self : HelperGrants, status : J) -> Unit {
  self.unanswered = None
  self.checked = (self.now)()
  self.attempted = self.checked
  let before = match self.status_ {
    Some(s) => stringify(s)
    None => "null"
  }
  self.status_ = Some(status)
  if stringify(status) != before {
    self.tell()
  }
}

///|
fn status_screen(s : J?) -> Bool {
  get(s, "capture") is Some(Bool(true)) && get(s, "control") is Some(Bool(true))
}

///|
/// What the station's page shows, as last looked at (none before the first look: looked at now, told when known).
pub fn HelperGrants::view(self : HelperGrants) -> J? {
  let last = if self.attempted > self.checked { self.attempted } else { self.checked }
  if (self.now)() - last >= SHOWN_MS {
    self.io.go(async fn() { self.refresh() })
  }
  guard self.status_ is Some(s) else { return None }
  let grants = grants_all
    .filter(g => if g == "localNetwork" { self.lan is Some(_) } else { self.folders || screen_grants.contains(g) })
    .map(grant => jo([("grant", js(grant)), ("state", js(self.state(grant)))]))
  let asking = if get(Some(s), "asking") is Some(Bool(true)) {
    arr(get(Some(s), "asked")).unwrap_or([]).filter(a => text(Some(a)).map(is_grant).unwrap_or(false))
  } else {
    []
  }
  Some(
    jsome([
      ("grants", Some(ja(grants))),
      ("asking", Some(ja(asking))),
      ("screen", Some(jb(truthy(get(Some(s), "capture")) && truthy(get(Some(s), "control"))))),
      ("localNetworkName", if self.lan is Some(_) { Some(js(local_network_name(self.io.os.exec_path))) } else { None }),
    ]),
  )
}

///|
fn asked_includes(s : J?, grant : String) -> Bool {
  match arr(get(s, "asked")) {
    Some(xs) => xs.iter().any(x => text(Some(x)) == Some(grant))
    None => false
  }
}

///|
/// The helper's window asking for `grant` on this Mac (in `words`; `paths` a disk's folder for its grant), unless it
/// is up asking for it or was shown for it within AGAIN_MS: "up", "closed" or "none".
pub async fn HelperGrants::show(
  self : HelperGrants,
  grant : String,
  words : J,
  paths? : J? = None,
  again? : Bool = false,
) -> String {
  let status = Some(self.helper.request(jo([("op", js("status"))]))) catch { _ => None }
  match status {
    Some(s) => self.learn(s)
    None => ()
  }
  // Up already asking for it: left as it is, not brought forward.
  if get(status, "asking") is Some(Bool(true)) && arr(get(status, "asked")) is Some(_) && asked_includes(status, grant) {
    return "up"
  }
  // Shown for it a moment ago: not again (whatever asks again), until AGAIN_MS have gone by.
  match self.asked.get(grant) {
    Some(last) if !again && (self.now)() - last < AGAIN_MS => return if status is None { "up" } else { "closed" }
    _ => ()
  }
  self.asked[grant] = (self.now)()
  try {
    let op = jsome([
      ("op", Some(js("permissions.show"))),
      ("words", Some(words)),
      ("grants", Some(jstrs([grant]))),
      ("paths", paths),
    ])
    ignore(self.helper.request(op))
    // The helper puts it up on its main thread after it answers: what it asks for is known (and told) once it says so.
    self.up_for(grant)
    "up"
  } catch {
    e => {
      self.io.log.warn("helper", "still.fail Helper's window did not show", fields=jo([("error", js(message_of(e)))]))
      "none"
    }
  }
}

///|
/// Until the helper says its window asks for `grant` (at most a moment: UP_TRIES looks), learnt either way.
async fn HelperGrants::up_for(self : HelperGrants, grant : String) -> Unit {
  for _ in 0..<UP_TRIES {
    let status = Some(self.helper.request(jo([("op", js("status"))]))) catch { _ => None }
    match status {
      Some(s) => self.learn(s)
      None => ()
    }
    if status is None || (get(status, "asking") is Some(Bool(true)) && asked_includes(status, grant)) {
      return
    }
    self.io.clock.sleep(UP_MS)
  }
}

///|
/// A person (or an agent) asks for `grant`: the window up for it, unless it is granted already ("granted"); whether
/// the screen can be seen and driven. A disk's grant needs a disk of its kind mounted: refused when none is.
pub async fn HelperGrants::request(self : HelperGrants, grant : String, words : J, again? : Bool = false) -> (String, Bool) {
  if !self.folders && !screen_grants.contains(grant) && grant != "localNetwork" {
    raise GrantRefused("station.permissions.unknown")
  }
  self.refresh(force=true)
  if grant == "localNetwork" {
    return (self.settings(again), status_screen(self.status_))
  }
  guard self.status_ is Some(s) else { raise GrantRefused("station.permissions.noHelper") }
  if grant_state(s, grant) == "granted" {
    return ("granted", status_screen(self.status_))
  }
  let mut paths = None
  if grant == "removable" || grant == "network" {
    match self.disk(grant) {
      Some(disk) => paths = Some(jo([(grant, js(disk))]))
      None => raise GrantRefused(if grant == "removable" { "station.permissions.noDisk" } else { "station.permissions.noNetworkDisk" })
    }
  }
  let window = self.show(grant, words, paths~, again~)
  (window, status_screen(self.status_))
}

///|
/// The LAN not reached: System Settings' Local Network list up on the Mac for it, once in a while as the helper's
/// window is.
fn HelperGrants::settings(self : HelperGrants, again : Bool) -> String {
  if self.lan == Some("granted") {
    return "granted"
  }
  match self.asked.get("localNetwork") {
    Some(last) if !again && (self.now)() - last < AGAIN_MS => return "closed"
    _ => ()
  }
  self.asked["localNetwork"] = (self.now)()
  (self.open)(LOCAL_NETWORK_SETTINGS)
  "up"
}

///|
/// A disk mounted here whose grant is `grant` (the helper tells removable from network), none when there is none.
/// Only the entries of the mount point are looked at, never what is on a disk.
async fn HelperGrants::disk(self : HelperGrants, grant : String) -> String? {
  let names = (self.io.fs.readdir)(self.volumes) catch { _ => [] }
  let each = names.map(e => pj([self.volumes, e.name]))
  // The system's own disk is a link to / there.
  let disks = @effect.all(
    each.map(p => async fn() {
      let st = (self.io.fs.lstat)(p) catch { _ => return false }
      !st.link
    }),
  )
  let tops = []
  for i, p in each {
    if disks[i] {
      tops.push(p)
    }
  }
  for m in (self.mounts)() {
    if !m.has_prefix("\{self.volumes}/") {
      tops.push(m)
    }
  }
  if tops.length() == 0 {
    return None
  }
  let answer = Some(self.helper.request(jo([("op", js("files.access")), ("paths", jstrs(tops))]))) catch { _ => None }
  for a in arr(get(answer, "access")).unwrap_or([]) {
    if text(get(Some(a), "grant")) == Some(grant) {
      match text(get(Some(a), "path")) {
        Some(p) => return Some(p)
        None => ()
      }
    }
  }
  None
}

///|
/// What an error says with each address in it (`0x7a68c38ff0`) said alike (grants.ts `withoutAddresses`).
fn without_addresses(said : String) -> String {
  let hex = (c : Char) => (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F')
  let cs = said.to_array()
  let out = StringBuilder::new()
  let mut i = 0
  while i < cs.length() {
    if cs[i] == '0' && i + 2 < cs.length() && cs[i + 1] == 'x' && hex(cs[i + 2]) {
      out.write_string("0x…")
      i += 2
      while i < cs.length() && hex(cs[i]) {
        i += 1
      }
    } else {
      out.write_char(cs[i])
      i += 1
    }
  }
  out.to_string()
}
