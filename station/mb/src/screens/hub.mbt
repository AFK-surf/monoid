// The station's screens (src/screens/hub.ts): the registry its parts add their sources to (`Screens`), and who is on
// each now. What members are told of them (GET /admin/api/screens, `screens` on the event stream, the agents' `screen`
// tool) is said here; the views themselves go over the member link.

///|
/// One view open now (hub.ts `Watcher`): whose, whether its input is taken, and how it is told its people changed.
/// `device`: the member's device it came over; `client`, `app`: the name and kind of app that device says it is;
/// `self_`: the device's own main id as it says it; `agent`: an agent's own view. `end` and `watch_only`: how a member
/// elsewhere ends it or stops its input being taken, `by` naming them.
pub(all) struct Watcher {
  name : String
  mut control : Bool
  tell : (J) -> Unit
  device : String?
  self_ : String?
  client : String?
  app : String?
  agent : Bool
  mut taken : Bool
  end : ((String) -> Unit)?
  watch_only : ((String?) -> Unit)?
  mut at : Double
}

///|
pub fn Watcher::new(
  name : String,
  control : Bool,
  tell : (J) -> Unit,
  device? : String? = None,
  self_? : String? = None,
  client? : String? = None,
  app? : String? = None,
  agent? : Bool = false,
  taken? : Bool = false,
  end? : ((String) -> Unit)? = None,
  watch_only? : ((String?) -> Unit)? = None,
) -> Watcher {
  { name, control, tell, device, self_, client, app, agent, taken, end, watch_only, at: 0.0 }
}

///|
/// One view as members are told of it: `id`, the hub's, to end it by; `at`, when it opened (ms).
pub(all) struct ViewShown {
  id : String
  name : String
  control : Bool
  at : Double
  device : String?
  self_ : String?
  client : String?
  app : String?
  agent : Bool
}

///|
pub fn ViewShown::to_j(self : ViewShown) -> J {
  jsome([
    ("id", Some(js(self.id))),
    ("name", Some(js(self.name))),
    ("control", Some(jb(self.control))),
    ("at", Some(jn(self.at))),
    ("device", self.device.filter(d => d != "").map(js)),
    ("self", self.self_.filter(d => d != "").map(js)),
    ("client", self.client.filter(d => d != "").map(js)),
    ("app", self.app.filter(d => d != "").map(js)),
    ("agent", if self.agent { Some(jb(true)) } else { None }),
  ])
}

///|
/// Where a person's view is, for an agent to name it to them: the app, the device (its id's start), how long it has
/// been open.
pub fn view_on(v : ViewShown, now : Double) -> String {
  let minutes = js_max(0.0, js_round((now - v.at) / 60000.0))
  let opened = if minutes < 1.0 {
    "just now"
  } else if minutes < 120.0 {
    "\{num_text(minutes)} min ago"
  } else {
    "\{num_text(js_round(minutes / 60.0))} h ago"
  }
  let parts = [v.client.unwrap_or("an app that does not say its name")]
  match v.device {
    Some(d) if d != "" => parts.push("device \{slice_units(d, 0, 12)}")
    _ => ()
  }
  parts.push("opened \{opened}")
  parts.join(", ")
}

///|
/// What a person is told of a source's access when something is missing: whether it can be seen and driven, why not,
/// in their language, and what to turn on.
pub(all) struct AccessShown {
  capture : Bool
  control : Bool
  message : String
  app : String?
  path : String?
  asking : Bool
  help : String?
}

///|
pub fn AccessShown::to_j(self : AccessShown) -> J {
  jsome([
    ("capture", Some(jb(self.capture))),
    ("control", Some(jb(self.control))),
    ("message", Some(js(self.message))),
    ("app", self.app.map(js)),
    ("path", self.path.map(js)),
    ("asking", if self.asking { Some(jb(true)) } else { None }),
    ("help", self.help.map(js)),
  ])
}

///|
/// The message for what is missing; none when nothing is.
pub fn access_shown(words : Words, access : ScreenAccess?, lang : String) -> AccessShown? {
  guard access is Some(access) else { return None }
  if access.capture && access.control && access.unsupported is None && access.reason is None {
    return None
  }
  let tr = (k : String, args : J) => (words.tr)(lang, k, args)
  let app = match access.app {
    Some(a) if a != "" => a
    _ => "still.fail Helper"
  }
  let named = jo([("app", js(app))])
  let message = match (access.reason, access.unsupported) {
    (Some(r), _) if r != "" => tr("station.screen.\{r}", jo([]))
    (_, Some("platform")) => tr("station.screen.unsupported", jo([]))
    (_, Some("helper")) => tr("station.screen.noHelper", jo([]))
    _ => {
      // Neither: it cannot be viewed either, so not "viewed but not controlled".
      let first = if !access.capture && !access.control {
        tr("station.screen.bothOff", named)
      } else if !access.capture {
        tr("station.screen.captureOff", named)
      } else {
        tr("station.screen.controlOff", named)
      }
      // Where it is granted: the window on the machine, up now or once the screen is opened.
      [first, tr(if access.asking { "station.screen.asking" } else { "station.screen.toAsk" }, named)].join(" ")
    }
  }
  let help = match access.reason {
    Some(
      "linuxNoDisplay"
      | "linuxTools"
      | "linuxToolsFailed"
      | "linuxUnavailable"
      | "linuxPortalUnavailable"
      | "linuxX11FallbackUnavailable"
    ) => Some("linux-desktop")
    _ => None
  }
  Some({
    capture: access.capture,
    control: access.control,
    message,
    app: access.app.filter(a => a != ""),
    path: access.path.filter(a => a != ""),
    asking: access.asking,
    help,
  })
}

///|
/// A view made to only look stays so if its device opens it again this soon without its person asking to drive.
pub const WATCH_HELD_MS : Double = 90000

///|
/// The longest address a view's state carries (a longer one is not said: its site still is).
pub const ADDRESS_MOST : Int = 2048

///|
/// A browser tab's address as a view of it is told: none where it has none or it is longer than `ADDRESS_MOST`.
pub fn address_shown(address : String?) -> String? {
  match address {
    Some(a) if a != "" && units_len(a) <= ADDRESS_MOST => Some(a)
    _ => None
  }
}

///|
/// The station's screens and who is on each (hub.ts `ScreenHub`). `drop`: where a file a person drops into a view is
/// put on this machine (none: files are not taken).
pub struct ScreenHub {
  priv io : Io
  priv sources : Screens
  priv drop : (() -> String?)?
  priv views : Map[String, Map[String, Watcher]]
  priv mut view_count : Int
  /// Until when a device's views of a screen are held to only looking, by device and screen.
  priv held : Map[String, Double]
  /// Devices whose next driving view of a screen was explicitly asked (`taken: true` in `drive`).
  priv taking : Map[String, Unit]
  priv listeners : Array[(Int, () -> Unit)]
  priv refreshers : Array[(Int, async () -> Unit)]
  priv stopping : Array[(Int, () -> Unit)]
  priv mut next : Int
  priv mut browser : ScreenBrowser?
}

///|
pub fn ScreenHub::new(io : Io, drop? : (() -> String?)? = None) -> ScreenHub {
  let hub = {
    io,
    sources: Screens::new(),
    drop,
    views: {},
    view_count: 0,
    held: {},
    taking: {},
    listeners: [],
    refreshers: [],
    stopping: [],
    next: 0,
    browser: None,
  }
  ignore(hub.sources.watch(_ => hub.told_changed()))
  hub
}

///|
fn ScreenHub::told_changed(self : ScreenHub) -> Unit {
  for l in self.listeners.copy() {
    (l.1)()
  }
}

///|
fn ScreenHub::id(self : ScreenHub) -> Int {
  self.next += 1
  self.next
}

///|
fn[T] take_out(list : Array[(Int, T)], id : Int) -> Unit {
  match list.search_by(l => l.0 == id) {
    Some(i) => ignore(list.remove(i))
    None => ()
  }
}

///|
pub fn ScreenHub::set_browser(self : ScreenHub, browser : ScreenBrowser?) -> Unit {
  match (self.browser, browser) {
    (None, None) => return
    (Some(a), Some(b)) if physical_equal(a, b) => return
    _ => ()
  }
  self.browser = browser
  self.told_changed()
}

///|
pub fn ScreenHub::add(self : ScreenHub, source : ScreenSource) -> () -> Unit {
  self.sources.add(source)
}

///|
pub fn ScreenHub::list(self : ScreenHub) -> Array[ScreenSource] {
  self.sources.list()
}

///|
pub fn ScreenHub::get(self : ScreenHub, id : String) -> ScreenSource? {
  self.sources.get(id)
}

///|
pub fn ScreenHub::watch(self : ScreenHub, listener : (Array[ScreenSource]) -> Unit) -> () -> Unit {
  self.sources.watch(listener)
}

///|
/// A source's title, size or access changed.
pub fn ScreenHub::changed(self : ScreenHub) -> Unit {
  self.sources.changed()
}

///|
/// How a source's state is looked at again before it is told (the desktop's grants: asked of macOS, not followed).
pub fn ScreenHub::refresher(self : ScreenHub, refresh : async () -> Unit) -> () -> Unit {
  let id = self.id()
  self.refreshers.push((id, refresh))
  () => take_out(self.refreshers, id)
}

///|
pub async fn ScreenHub::refresh(self : ScreenHub) -> Unit {
  ignore(@effect.all(self.refreshers.map(r => async fn() { (r.1)() catch { _ => () } })))
}

///|
/// What members are told changed: a source came, went or changed, or someone opened or left a view.
pub fn ScreenHub::on_change(self : ScreenHub, listener : () -> Unit) -> () -> Unit {
  let id = self.id()
  self.listeners.push((id, listener))
  () => take_out(self.listeners, id)
}

///|
/// Who is on a source now: everyone viewing, those of them whose input is taken, and each view.
pub fn ScreenHub::people(self : ScreenHub, id : String) -> J {
  let on = match self.views.get(id) {
    Some(m) => m.iter().collect()
    None => []
  }
  jo([
    ("viewers", jstrs(on.map(p => p.1.name))),
    ("controlledBy", jstrs(on.filter(p => p.1.control).map(p => p.1.name))),
    (
      "views",
      ja(on.map(p => {
        let w = p.1
        ViewShown::{ id: p.0, name: w.name, control: w.control, at: w.at, device: w.device, self_: w.self_, client: w.client, app: w.app, agent: w.agent }.to_j()
      })),
    ),
  ])
}

///|
/// A view opened on `id`: everyone on it is told who is, and members are; the returned function leaves.
pub fn ScreenHub::join(self : ScreenHub, id : String, watcher : Watcher) -> () -> Unit {
  let on = match self.views.get(id) {
    Some(m) => m
    None => Map::new()
  }
  self.views[id] = on
  self.view_count += 1
  let view = "v\{self.view_count}"
  let taken_key = watcher.device.unwrap_or("")
  if watcher.control && !watcher.agent && taken_key != "" && self.taking.contains("\{taken_key}\n\{id}") {
    self.taking.remove("\{taken_key}\n\{id}")
    watcher.taken = true
  }
  watcher.at = self.io.clock.ms()
  on[view] = watcher
  self.tell_people(id)
  let left = Ref(false)
  () => {
    if left.val {
      return
    }
    left.val = true
    on.remove(view)
    match self.views.get(id) {
      Some(m) if on.length() == 0 && physical_equal(m, on) => self.views.remove(id)
      _ => ()
    }
    self.tell_people(id)
  }
}

///|
fn ScreenHub::tell_people(self : ScreenHub, id : String) -> Unit {
  let people = self.people(id)
  let on = match self.views.get(id) {
    Some(m) => m.values().collect()
    None => []
  }
  for w in on {
    (w.tell)(people)
  }
  self.told_changed()
}

///|
/// A person's view found to act on: refused for one not there and an agent's.
fn ScreenHub::view_of(self : ScreenHub, id : String, view : String) -> Watcher raise ScreenRefused {
  if self.get(id) is None {
    raise self.io.refused(404, "station.screen.notFound")
  }
  guard self.views.get(id).bind(m => m.get(view)) is Some(w) else {
    raise self.io.refused(404, "station.screen.viewGone")
  }
  if w.agent || w.end is None {
    raise self.io.refused(405, "station.screen.viewNotEnded")
  }
  w
}

///|
/// POST /admin/api/screens/<id>/views/<view>/end: a member ends a view from wherever they are.
pub fn ScreenHub::end_view(self : ScreenHub, id : String, view : String, by : String) -> Unit raise ScreenRefused {
  let w = self.view_of(id, view)
  match w.end {
    Some(end) => end(by)
    None => ()
  }
}

///|
/// POST /admin/api/screens/<id>/views/<view>/watch: the view goes on, only looking.
pub fn ScreenHub::watch_only(self : ScreenHub, id : String, view : String) -> Unit raise ScreenRefused {
  self.look_only(id, self.view_of(id, view), None)
}

///|
/// `w` goes on only looking, its device held from driving again by itself for WATCH_HELD_MS (unless `hold` is false:
/// an agent stepping in while a view watched passively); `by`: who took it.
fn ScreenHub::look_only(self : ScreenHub, id : String, w : Watcher, by : String?, hold? : Bool = true) -> Unit {
  if !w.control {
    return
  }
  w.control = false
  w.taken = false
  if hold {
    match w.device {
      Some(device) if device != "" => {
        let now = self.io.clock.ms()
        for key in self.held.keys().collect() {
          if self.held.get(key).unwrap() <= now {
            self.held.remove(key)
          }
        }
        // (set again: in the place it had where it was still held)
        self.held["\{device}\n\{id}"] = now + WATCH_HELD_MS
      }
      _ => ()
    }
  }
  match w.watch_only {
    Some(f) => f(by)
    None => ()
  }
  self.tell_people(id)
}

///|
/// Whether a view `device` opens of `id`, asking to drive, may: not just after it was made to only look, unless its
/// person asked (`taken`, which lets it go).
pub fn ScreenHub::may_drive(self : ScreenHub, id : String, device : String, taken : Bool) -> Bool {
  let key = "\{device}\n\{id}"
  guard self.held.get(key) is Some(until) else { return true }
  if taken || until <= self.io.clock.ms() {
    self.held.remove(key)
    return true
  }
  false
}

///|
/// Whether a view `device` opens of `id`, asking to drive, drives it: one person's view drives a screen at a time, any
/// number look (pengxiao, 2026-11-12). `took`: whose views it took it from.
pub fn ScreenHub::drive(self : ScreenHub, id : String, device : String, taken : Bool, by : String) -> (Bool, Array[String]) {
  if !self.may_drive(id, device, taken) {
    return (false, [])
  }
  let on = match self.views.get(id) {
    Some(m) => m.values().collect()
    None => []
  }
  let others = on.filter(w => w.control && !w.agent && w.device != Some(device))
  if others.length() == 0 {
    if device != "" {
      if taken {
        self.taking["\{device}\n\{id}"] = ()
      } else {
        self.taking.remove("\{device}\n\{id}")
      }
    }
    return (true, [])
  }
  if !taken {
    return (false, [])
  }
  for w in others {
    self.look_only(id, w, Some(by))
  }
  if device != "" {
    self.taking["\{device}\n\{id}"] = ()
  }
  let took = []
  for w in others {
    if !took.contains(w.name) {
      took.push(w.name)
    }
  }
  (true, took)
}

///|
/// Distinct names of people's views currently driving `id` (`control && !agent`).
pub fn ScreenHub::driving_people(self : ScreenHub, id : String) -> Array[String] {
  let out : Array[String] = []
  match self.views.get(id) {
    Some(m) =>
      for _, w in m {
        if w.control && !w.agent && !out.contains(w.name) {
          out.push(w.name)
        }
      }
    None => ()
  }
  out
}

///|
/// Whether any person's view currently driving `id` explicitly asked to take control (`taken: true`).
pub fn ScreenHub::has_taken_view(self : ScreenHub, id : String) -> Bool {
  match self.views.get(id) {
    Some(m) => m.values().any(w => w.control && !w.agent && w.taken)
    None => false
  }
}

///|
/// Yields passive (`!taken`) person views on `id` to watch-only while agent `by` operates it, without locking their
/// devices from resuming once the agent finishes.
pub fn ScreenHub::yield_to_agent(self : ScreenHub, id : String, by : String) -> Int {
  let on = match self.views.get(id) {
    Some(m) => m.values().collect()
    None => []
  }
  let passive = on.filter(w => w.control && !w.agent && !w.taken && w.watch_only is Some(_))
  for w in passive {
    self.look_only(id, w, Some(by), hold=false)
  }
  passive.length()
}

///|
/// An agent asked by a person to take the screen (the `screen` tool's take_control): every person's view that drives
/// it goes on only looking; how many did.
pub fn ScreenHub::take_control(self : ScreenHub, id : String, by? : String? = None) -> Int raise ScreenRefused {
  if self.get(id) is None {
    raise self.io.refused(404, "station.screen.notFound")
  }
  let on = match self.views.get(id) {
    Some(m) => m.values().collect()
    None => []
  }
  let driving = on.filter(w => w.control && !w.agent && w.watch_only is Some(_))
  for w in driving {
    self.look_only(id, w, by)
  }
  driving.length()
}

///|
/// POST /admin/api/screens/<id>/views/end: every person's view ends (an agent's stays); how many did.
pub fn ScreenHub::end_views(self : ScreenHub, id : String, by : String) -> Int raise ScreenRefused {
  if self.get(id) is None {
    raise self.io.refused(404, "station.screen.notFound")
  }
  let on = match self.views.get(id) {
    Some(m) => m.values().collect()
    None => []
  }
  let ending = on.filter(w => !w.agent && w.end is Some(_))
  for w in ending {
    match w.end {
      Some(end) => end(by)
      None => ()
    }
  }
  ending.length()
}

///|
/// A view opened by the station itself (the agents' computer-use tool), shown as `name` while it is open. Closing it
/// leaves.
pub async fn ScreenHub::open_as(
  self : ScreenHub,
  id : String,
  options : ViewOptions,
  name : String,
  control : Bool,
) -> ScreenView {
  guard self.get(id) is Some(source) else { raise self.io.refused(404, "station.screen.notFound") }
  if source.user_tab {
    raise self.io.refused(403, "station.screen.userOnly")
  }
  let view = (source.open)(options)
  let leave = self.join(id, Watcher::new(name, control, _ => (), agent=true))
  ScreenView::bare(
    async fn() { (view.next)() },
    () => (view.keyframe)(),
    async fn(event) { (view.input)(event) },
    () => {
      leave()
      (view.close)()
    },
  )
}

///|
/// What ends a view as the station stops.
pub fn ScreenHub::when_stopping(self : ScreenHub, stop : () -> Unit) -> () -> Unit {
  let id = self.id()
  self.stopping.push((id, stop))
  () => take_out(self.stopping, id)
}

///|
/// The station stopping: every view ends, said so.
pub fn ScreenHub::close(self : ScreenHub) -> Unit {
  for s in self.stopping.copy() {
    (s.1)()
  }
}

///|
fn ScreenHub::source_of(self : ScreenHub, id : String) -> ScreenSource raise ScreenRefused {
  match self.get(id) {
    Some(s) => s
    None => raise self.io.refused(404, "station.screen.notFound")
  }
}

///|
/// POST /admin/api/screens/<id>/close: a screen closed from a person's app.
pub async fn ScreenHub::close_screen(self : ScreenHub, id : String) -> Unit {
  let source = self.source_of(id)
  match source.discard {
    Some(f) => f()
    None => raise self.io.refused(405, "station.screen.notClosed")
  }
}

///|
/// POST /admin/api/screens/browser: opens a persistent user tab in the station's browser.
pub async fn ScreenHub::open_browser(self : ScreenHub, url : String, id? : String? = None) -> String {
  match self.browser {
    Some(b) if (b.available)() => (b.open_user_tab)(url, id)
    _ => raise self.io.refused(503, "station.screen.noBrowser")
  }
}

///|
/// POST /admin/api/screens/<id>/open-url: navigates a browser tab or opens a link on a simulator.
pub async fn ScreenHub::open_url(self : ScreenHub, id : String, url : String) -> Unit {
  let source = self.source_of(id)
  match source.open_url {
    Some(f) => {
      f(url)
      return
    }
    None => ()
  }
  match source.debug {
    Some(debug) => {
      if !debug.open_url(url) {
        raise self.io.refused(400, "station.screen.badUrl")
      }
      return
    }
    None => ()
  }
  raise self.io.refused(405, "station.screen.noDebug")
}

///|
/// POST /admin/api/screens/<id>/reload: reloads a browser tab.
pub async fn ScreenHub::reload_screen(self : ScreenHub, id : String) -> Unit {
  let source = self.source_of(id)
  match source.reload {
    Some(f) => f()
    None => raise self.io.refused(405, "station.screen.notBrowser")
  }
}

///|
/// POST /admin/api/screens/<id>/back and …/forward: a page back or forward in a browser tab's history.
pub async fn ScreenHub::history_screen(self : ScreenHub, id : String, delta : Int) -> Unit {
  let source = self.source_of(id)
  let go = if delta < 0 { source.back } else { source.forward }
  match go {
    Some(f) => f()
    None => raise self.io.refused(405, "station.screen.notBrowser")
  }
}

///|
/// POST /admin/api/screens/<id>/sleep: hibernates a user tab.
pub async fn ScreenHub::sleep_screen(self : ScreenHub, id : String) -> Unit {
  let source = self.source_of(id)
  match source.sleep {
    Some(f) => f()
    None => raise self.io.refused(405, "station.screen.notBrowser")
  }
}

///|
/// A screen's apps' logs and their restart (a simulator's); refused for any other.
pub fn ScreenHub::debug_of(self : ScreenHub, id : String) -> SimDebug raise ScreenRefused {
  let source = self.source_of(id)
  match source.debug {
    Some(d) => d
    None => raise self.io.refused(405, "station.screen.noDebug")
  }
}

///|
/// A simulator's case, one panel's turned as it asks (`GET …/chrome/<panel>/<turn>`); refused for what has none.
pub async fn ScreenHub::chrome_of(self : ScreenHub, id : String, panel : Int, turn : Double) -> ChromePictures {
  let source = self.source_of(id)
  let chrome = match source.chrome {
    Some(cs) if panel >= 0 && panel < cs.length() => Some(cs[panel])
    _ => None
  }
  guard chrome is Some(chrome) && is_integer(turn) && turn >= 0.0 && turn <= 3.0 else {
    raise self.io.refused(404, "station.screen.notFound")
  }
  pictures_of(self.io, chrome, turn.to_int())
}

///|
/// GET /admin/api/screens, in `lang`.
pub fn ScreenHub::listed(self : ScreenHub, lang : String) -> J {
  let folder = match self.drop {
    Some(f) => f()
    None => None
  }
  let browser = match self.browser {
    Some(b) => (b.available)()
    None => false
  }
  let screens = self.list().map(s => {
    let (width, height) = (s.size)()
    let access = access_shown(self.io.words, s.access.map(f => f()), lang)
    let clipboard = match s.clipboard {
      Some(f) => f()
      None => []
    }
    let by = s.opened_by.bind(f => f())
    let since = s.since.bind(f => f())
    let site = s.site.bind(f => f())
    let sleeping = match s.sleeping {
      Some(f) => f()
      None => false
    }
    let people = self.people(s.id)
    let out = jo([("id", js(s.id)), ("kind", js(s.kind.name())), ("title", js((s.title)())), ("width", jn(width)), ("height", jn(height))])
    let out = spread(out, people)
    spread(
      out,
      jsome([
        ("access", access.map(a => a.to_j())),
        ("clipboard", if clipboard.length() > 0 { Some(jstrs(clipboard)) } else { None }),
        ("peek", if s.peek { Some(jb(true)) } else { None }),
        ("farview", if s.farview { Some(jb(true)) } else { None }),
        ("closable", if s.discard is Some(_) { Some(jb(true)) } else { None }),
        ("userTab", if s.user_tab { Some(jb(true)) } else { None }),
        ("sleeping", if sleeping { Some(jb(true)) } else { None }),
        ("site", site.filter(x => x != "").map(js)),
        ("openUrl", if s.open_url is Some(_) { Some(jb(true)) } else { None }),
        ("debug", if s.debug is Some(_) { Some(jb(true)) } else { None }),
        ("install", s.debug.map(d => js(d.install_folder()))),
        ("poses", if s.poses { Some(jb(true)) } else { None }),
        ("panels", s.panels.filter(p => p.length() > 0).map(p => ja(p.map(x => x.to_j())))),
        ("chrome", s.chrome.filter(c => c.length() > 0).map(c => ja(c.map(x => x.told().to_j())))),
        ("openedBy", by.filter(x => x != "").map(js)),
        ("since", since.map(jn)),
        ("drop", folder.map(f => jo([("folder", js(f)), ("reveal", jb(s.reveal))]))),
      ]),
    )
  })
  jsome([("browser", if browser { Some(jb(true)) } else { None }), ("screens", Some(ja(screens)))])
}
