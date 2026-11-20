// The tabs of the station's browser (src/browser/tabs.ts), as its DevTools tell of them (Target.setDiscoverTargets on
// the station's own connection): listed to the agents, and each a screen source (`browser:<targetId>`) in the
// station's Screens while it is there, saying the session that opened it (owners.mbt) and closed from a person's app.

///|
/// A tab as the agents are told of it: `session` the session that opened it, when known.
pub(all) struct TabInfo {
  id : String
  title : String
  url : String
  attached : Bool
  session : String?
}

///|
pub fn TabInfo::to_j(self : TabInfo) -> J {
  let fs : Array[(String, J)] = [
    ("id", js(self.id)),
    ("title", js(self.title)),
    ("url", js(self.url)),
    ("attached", jb(self.attached)),
  ]
  match self.session {
    Some(s) => fs.push(("session", js(s)))
    None => ()
  }
  jo(fs)
}

///|
/// What a person's own pages (user-tabs.mbt) are told of Chrome's targets, so they stay apart from the agents' tabs.
pub(all) struct UserTabHooks {
  target_created : (J) -> String?
  target_info_changed : (J) -> Bool
  target_destroyed : (String) -> Bool
  refresh_titles : (Array[J]) -> Unit
}

///|
/// What the tabs need of the browser.
pub(all) struct TabsParts {
  /// The station's connection to the browser (its watch on the targets).
  cdp : Cdp
  /// Where the tabs are added as screens.
  screens : Screens?
  /// A new connection to the browser, for a view of its own.
  connect : async () -> Cdp
  /// Milliseconds.
  now : () -> Double
  /// Something happened in the browser (a tab came, went, was navigated), or a view opened or ended.
  activity : () -> Unit
  /// Chrome's time for its titles and a tab's coming: the clock's (the machine's in the station).
  clock : Clock
  /// Which session opened each tab of the station's own context; None: not known.
  owners : Owners?
  /// The session whose chat's context a browser context is (browsers.mbt).
  context_owner : ((String?) -> String?)?
  used_tab : ((String, String) -> Unit)?
  /// Whether tab `target_id`'s context has a passkey of relying party `rp_id` its authenticator signs.
  own_passkey : ((String, String) -> Bool)?
  /// Claims and tracks persistent user pages so they stay separate from agent tabs.
  user_tabs : UserTabHooks?
  /// A random UUID (a view's binding's owner).
  uuid : () -> String
}

///|
/// Chrome tells of a tab's new address, not of its title, which the page sets after (Chrome 155): the titles are read
/// again this long after a tab came or changed.
let titles_after_ms : Array[Double] = [1000.0, 5000.0]

///|
/// How long a tab just created is waited for (`arrived`).
pub let arrive_ms : Double = 3000.0

///|
priv struct ActiveView {
  target_id : String
  view : TabView
  children : Array[(Int, (String) -> Unit)]
}

///|
/// A tab as a screen source.
priv struct Tab {
  id : String
  mut target_id : String
  mut title : J
  mut url : J
  mut attached : Bool
  mut size : (Double, Double)
}

///|
fn Tab::title_shown(self : Tab) -> String {
  if truthy(Some(self.title)) {
    js_str(Some(self.title))
  } else {
    js_str(Some(self.url))
  }
}

///|
fn Tab::url_text(self : Tab) -> String {
  js_str(Some(self.url))
}

///|
priv struct Known {
  tab : Tab
  mut remove : () -> Unit
  source : ScreenSource
}

///|
pub struct Tabs {
  priv p : TabsParts
  priv tabs : Map[String, Known]
  priv live_targets : Map[String, Unit]
  /// The browser context of every target told of (pages, frames, workers): whose chat's it is (gate.mbt).
  priv contexts : Map[String, String]
  priv views : Array[ActiveView]
  priv mut unlisten : () -> Unit
  priv mut closed : Bool
  /// Past the tabs that were there at start (told as created): what comes now is the browser being used.
  priv mut ready : Bool
  priv mut rereads : Array[() -> Unit]
  /// Who waits for a tab to come (`arrived`), by its target id.
  priv awaited : Map[String, Array[(Int, () -> Unit)]]
  priv mut waiter_id : Int
}

///|
pub fn Tabs::new(p : TabsParts) -> Tabs {
  {
    p,
    tabs: {},
    live_targets: {},
    contexts: {},
    views: [],
    unlisten: () => (),
    closed: false,
    ready: false,
    rereads: [],
    awaited: {},
    waiter_id: 0,
  }
}

///|
/// Starts watching: the tabs there now come as created.
pub async fn Tabs::start(self : Tabs) -> Unit {
  self.unlisten = (self.p.cdp.on)(e => self.heard(e))
  ignore(self.p.cdp.send("Target.setDiscoverTargets", jo([("discover", jb(true))]), None))
  self.ready = true
  // Those of tabs closed while no station process watched are forgotten.
  match self.p.owners {
    Some(o) => o.keep(self.tab_ids())
    None => ()
  }
}

///|
fn Tabs::tab_ids(self : Tabs) -> Array[String] {
  let ids = []
  for id, _ in self.tabs {
    ids.push(id)
  }
  ids
}

///|
pub fn Tabs::list(self : Tabs) -> Array[TabInfo] {
  let out = []
  for _, k in self.tabs {
    out.push({
      id: k.tab.target_id,
      title: js_str(Some(k.tab.title)),
      url: js_str(Some(k.tab.url)),
      attached: k.tab.attached,
      session: self.owner_of(k.tab.target_id),
    })
  }
  out
}

///|
/// Whether tab `target_id` is there (among the agent/station tabs).
pub fn Tabs::has(self : Tabs, target_id : String) -> Bool {
  self.tabs.contains(target_id)
}

///|
/// Returns once tab `target_id` is there (a tab just created: Chrome may answer before it tells of it), or after `ms`
/// all the same.
pub async fn Tabs::arrived(self : Tabs, target_id : String, ms? : Double = arrive_ms) -> Unit {
  if self.closed || self.tabs.contains(target_id) || self.live_targets.contains(target_id) {
    return
  }
  let d : @effect.Deferred[Unit] = @effect.Deferred::new()
  self.waiter_id += 1
  let me = self.waiter_id
  let stop_ref : Ref[() -> Unit] = Ref(() => ())
  let done = () => {
    (stop_ref.val)()
    let left = self.awaited.get(target_id).unwrap_or([]).filter(w => w.0 != me)
    if left.length() > 0 {
      self.awaited[target_id] = left
    } else {
      self.awaited.remove(target_id)
    }
    ignore(d.succeed(()))
  }
  stop_ref.val = (self.p.clock.after)(ms, async fn() { done() })
  self.awaited[target_id] = self.awaited.get(target_id).unwrap_or([]) + [(me, done)]
  d.wait() catch {
    _ => ()
  }
}

///|
fn Tabs::wake_awaited(self : Tabs, target_id : String) -> Unit {
  for w in self.awaited.get(target_id).unwrap_or([]) {
    (w.1)()
  }
}

///|
/// The session whose tab `target_id` is: its context's chat's, else the one that opened it in the station's own.
pub fn Tabs::owner_of(self : Tabs, target_id : String) -> String? {
  let by_context = match self.p.context_owner {
    Some(f) => f(self.contexts.get(target_id))
    None => None
  }
  match by_context {
    Some(s) => Some(s)
    None =>
      match self.p.owners {
        Some(o) => o.of(target_id)
        None => None
      }
  }
}

///|
/// The browser context of target `target_id`, when it was told of.
pub fn Tabs::context_of(self : Tabs, target_id : String) -> String? {
  self.contexts.get(target_id)
}

///|
/// Tab `target_id` was opened by `session` (its connection said so): the screens' watchers hear, once it is there.
pub fn Tabs::owned(self : Tabs, target_id : String, session : String) -> Unit {
  match self.p.owners {
    Some(o) => if !o.set(target_id, session) { return }
    None => return
  }
  match self.tabs.get(target_id) {
    Some(known) => self.retitled(known)
    None => ()
  }
}

///|
/// The tabs `session` opened that are there now.
pub fn Tabs::of_session(self : Tabs, session : String) -> Array[String] {
  self.tab_ids().filter(id => self.owner_of(id) == Some(session))
}

///|
/// Closes tab `target_id` (it leaves the screens as Chrome tells it went).
pub async fn Tabs::close_tab(self : Tabs, target_id : String) -> Unit {
  if self.closed || !self.tabs.contains(target_id) {
    raise fail_("This tab is closed.")
  }
  ignore(self.p.cdp.send("Target.closeTarget", jo([("targetId", js(target_id))]), None))
}

///|
/// Closes any live Chrome target `target_id` (used by the user tabs when sleeping or discarding).
pub async fn Tabs::close_target(self : Tabs, target_id : String) -> Unit {
  if self.closed {
    return
  }
  ignore(self.p.cdp.send("Target.closeTarget", jo([("targetId", js(target_id))]), None))
}

///|
/// Closes any open views attached to `target_id`.
pub fn Tabs::close_views_of(self : Tabs, target_id : String) -> Unit {
  for active in self.views.copy() {
    if active.target_id == target_id {
      active.view.close()
    }
  }
}

///|
fn Tabs::refuse_gone(self : Tabs, target_id : String) -> Unit raise ScreenRefused {
  if self.closed || (!self.tabs.contains(target_id) && !self.live_targets.contains(target_id)) {
    raise ScreenRefused(404, "station.screen.notFound")
  }
}

///|
/// A connection of its own attached to `target_id`, `f` done on it, the connection closed after.
async fn Tabs::on_own_connection(
  self : Tabs,
  target_id : String,
  f : async (Cdp, String?) -> Bool,
) -> Bool {
  let cdp = (self.p.connect)()
  let r = attempt(async fn() {
    let attached = cdp.send(
      "Target.attachToTarget",
      jo([("targetId", js(target_id)), ("flatten", jb(true))]),
      None,
    )
    f(cdp, str_of(at(Some(attached), "sessionId")))
  })
  (cdp.close)()
  match r {
    Ok(v) => v
    Err(e) => raise e
  }
}

///|
/// Navigates a live target to `url`.
pub async fn Tabs::navigate_target(self : Tabs, target_id : String, url : String) -> Unit {
  self.refuse_gone(target_id)
  ignore(
    self.on_own_connection(target_id, async fn(cdp, session) {
      ignore(cdp.send("Page.navigate", jo([("url", js(url))]), session))
      true
    }),
  )
  self.titles_later()
  (self.p.activity)()
}

///|
/// Reloads a live target.
pub async fn Tabs::reload_target(self : Tabs, target_id : String) -> Unit {
  self.refuse_gone(target_id)
  ignore(
    self.on_own_connection(target_id, async fn(cdp, session) {
      ignore(cdp.send("Page.reload", Obj([]), session))
      true
    }),
  )
  self.titles_later()
  (self.p.activity)()
}

///|
/// Goes `delta` steps through a live target's history (-1 back, 1 forward), as a browser's arrows do; nothing where
/// its history has no page there.
pub async fn Tabs::history_target(self : Tabs, target_id : String, delta : Int) -> Unit {
  self.refuse_gone(target_id)
  let went = self.on_own_connection(target_id, async fn(cdp, session) {
    let history = cdp.send("Page.getNavigationHistory", Obj([]), session)
    let entries = match at(Some(history), "entries") {
      Some(Arr(xs)) => xs
      _ => []
    }
    let at_ = match at(Some(history), "currentIndex") {
      Some(Num(n)) => n + delta.to_double()
      _ => -1.0
    }
    if at_ < 0.0 || at_.floor() != at_ || at_ >= entries.length().to_double() {
      return false
    }
    let entry = entries[at_.to_int()]
    guard at(Some(entry), "id") is Some(Num(_) as id) else { return false }
    ignore(cdp.send("Page.navigateToHistoryEntry", jo([("entryId", id)]), session))
    true
  })
  if !went {
    return
  }
  self.titles_later()
  (self.p.activity)()
}

///|
/// How many views of the tabs are open.
pub fn Tabs::viewing(self : Tabs) -> Int {
  self.views.length()
}

///|
/// Stops watching: every tab leaves the screens, every view ends.
pub fn Tabs::close(self : Tabs) -> Unit {
  if self.closed {
    return
  }
  self.closed = true
  (self.unlisten)()
  let rereads = self.rereads
  self.rereads = []
  for stop in rereads {
    stop()
  }
  for active in self.views.copy() {
    active.view.close()
  }
  for _, k in self.tabs {
    (k.remove)()
  }
  self.tabs.clear()
  self.live_targets.clear()
  let waiting = []
  for _, ws in self.awaited {
    waiting.push(ws)
  }
  for ws in waiting {
    for w in ws {
      (w.1)()
    }
  }
}

///|
async fn Tabs::open_tab(self : Tabs, tab : Tab, options : ViewOptions) -> ScreenView {
  if self.closed || !self.tabs.contains(tab.target_id) {
    raise fail_("This tab is closed.")
  }
  let target_id = tab.target_id
  self.open_target(
    target_id,
    options,
    sized=s => self.tab_sized(tab, s),
    used=() => match self.owner_of(target_id) {
      Some(owner) =>
        match self.p.used_tab {
          Some(f) => f(owner, target_id)
          None => ()
        }
      None => ()
    },
  )
}

///|
/// A view of target `target_id` on a connection of its own.
pub async fn Tabs::open_target(
  self : Tabs,
  target_id : String,
  options : ViewOptions,
  sized~ : ((Double, Double)) -> Unit,
  used? : () -> Unit,
  ended? : () -> Unit,
) -> ScreenView {
  if !options.codecs.contains("jpeg") {
    raise fail_("A tab of the station's browser is seen as JPEG frames, which this viewer does not take.")
  }
  if self.closed {
    raise fail_("This tab is closed.")
  }
  let cdp = (self.p.connect)()
  let made = attempt(async fn() {
    let attached = cdp.send(
      "Target.attachToTarget",
      jo([("targetId", js(target_id)), ("flatten", jb(true))]),
      None,
    )
    let session = text(at(Some(attached), "sessionId"))
    let children : Array[(Int, (String) -> Unit)] = []
    let active_ref : Ref[ActiveView?] = Ref(None)
    let view = TabView::new({
      cdp,
      session,
      target_id,
      now: self.p.now,
      own_passkey: self.p.own_passkey.map(f => rp => f(target_id, rp)),
      sized: Some(s => sized(s)),
      used: Some(() => match used {
        Some(u) => u()
        None => ()
      }),
      ended: Some(() => {
        match active_ref.val {
          Some(a) =>
            match self.views.search_by(v => physical_equal(v, a)) {
              Some(i) => ignore(self.views.remove(i))
              None => ()
            }
          None => ()
        }
        children.clear()
        match ended {
          Some(f) => f()
          None => ()
        }
        (self.p.activity)()
      }),
      uuid: self.p.uuid,
      clock: self.p.clock,
    })
    let next_child = Ref(0)
    view.set_watch_child(heard => {
      next_child.val += 1
      let me = next_child.val
      children.push((me, heard))
      () => match children.search_by(c => c.0 == me) {
        Some(i) => ignore(children.remove(i))
        None => ()
      }
    })
    let active : ActiveView = { target_id, view, children }
    active_ref.val = Some(active)
    self.views.push(active)
    (self.p.activity)()
    view.start(options)
    view.as_view()
  })
  match made {
    Ok(v) => v
    Err(e) => {
      (cdp.close)()
      raise e
    }
  }
}

///|
fn Tabs::source_of(self : Tabs, tab : Tab) -> ScreenSource {
  {
    id: tab.id,
    kind: "browser",
    peek: () => true,
    title: () => tab.title_shown(),
    site: () => site_of_browser_url(tab.url_text()),
    address: () => tab.url_text(),
    size: () => tab.size,
    clipboard: () => ["text"],
    opened_by: () => self.owner_of(tab.target_id),
    open: async fn(o) { self.open_tab(tab, o) },
    open_url: Some(async fn(raw) {
      guard address_or_search(raw) is Some(url) else {
        raise ScreenRefused(400, "station.screen.badUrl")
      }
      self.navigate_target(tab.target_id, url)
    }),
    reload: Some(async fn() { self.reload_target(tab.target_id) }),
    back: Some(async fn() { self.history_target(tab.target_id, -1) }),
    forward: Some(async fn() { self.history_target(tab.target_id, 1) }),
    discard: Some(async fn() { self.close_tab(tab.target_id) }),
    sleep: None,
    user_tab: false,
    popup: false,
    sleeping: () => false,
    farview: false,
  }
}

///|
/// A tab's viewport, as measured or as a view's frames say it: the screens' watchers hear when it changed.
fn Tabs::tab_sized(self : Tabs, tab : Tab, size : (Double, Double)) -> Unit {
  if size.0 == tab.size.0 && size.1 == tab.size.1 {
    return
  }
  tab.size = size
  match self.tabs.get(tab.target_id) {
    Some(known) if physical_equal(known.tab, tab) => self.retitled(known)
    _ => ()
  }
}

///|
fn info_text(v : J?, or_ : J) -> J {
  match v {
    None | Some(Null) => or_
    Some(x) => x
  }
}

///|
fn Tabs::heard(self : Tabs, e : CdpEvent) -> Unit {
  if e.session_id is Some(_) {
    return
  }
  let activity = () => {
    self.titles_later()
    if self.ready {
      (self.p.activity)()
    }
  }
  let p = Some(e.params)
  let info = at(p, "targetInfo")
  match (at(info, "targetId"), at(info, "browserContextId")) {
    (Some(Str(t)), Some(Str(c))) => self.contexts[@jsjson.sanitize_str(t)] = @jsjson.sanitize_str(c)
    _ => ()
  }
  if e.method == "Target.targetDestroyed" {
    match at(p, "targetId") {
      Some(Str(u)) if !self.tabs.contains(@jsjson.sanitize_str(u)) => self.contexts.remove(@jsjson.sanitize_str(u))
      _ => ()
    }
  }
  match e.method {
    "Target.targetCreated" => {
      if text(at(info, "type")) != "page" {
        return
      }
      let target_id = js_str(at(info, "targetId"))
      let opener = str_of(at(info, "openerId"))
      self.live_targets[target_id] = ()
      match self.p.user_tabs {
        Some(u) =>
          match (u.target_created)(info.unwrap()) {
            Some(claimed) => {
              self.wake_awaited(target_id)
              match opener {
                Some(o) => self.notify_child(o, claimed)
                None => ()
              }
              activity()
              return
            }
            None => ()
          }
        None => ()
      }
      if !self.tabs.contains(target_id) {
        // A tab a page opened (a link to a new window, a popup) is its opener's session's.
        match opener {
          Some(o) =>
            match self.owner_of(o) {
              Some(s) =>
                match self.p.owners {
                  Some(ow) => ignore(ow.set(target_id, s))
                  None => ()
                }
              None => ()
            }
          None => ()
        }
        let tab : Tab = {
          id: "browser:\{target_id}",
          target_id,
          title: info_text(at(info, "title"), js("")),
          url: info_text(at(info, "url"), js("")),
          attached: truthy(at(info, "attached")),
          size: (0.0, 0.0),
        }
        let source = self.source_of(tab)
        let remove = match self.p.screens {
          Some(s) => (s.add)(source)
          None => () => ()
        }
        self.tabs[target_id] = { tab, remove, source }
        (self.p.clock.spawn)(async fn() {
          self.measure_target(target_id, s => self.tab_sized(tab, s), () => tab.size.0)
        })
        self.wake_awaited(target_id)
        match opener {
          Some(o) => self.notify_child(o, tab.id)
          None => ()
        }
      }
      activity()
    }
    "Target.targetInfoChanged" => {
      match (info, self.p.user_tabs) {
        (Some(i), Some(u)) =>
          if (u.target_info_changed)(i) {
            activity()
            return
          }
        _ => ()
      }
      guard info is Some(_) else { return }
      guard self.tabs.get(js_str(at(info, "targetId"))) is Some(known) else { return }
      let before = known.tab.title_shown()
      let before_url = known.tab.url_text()
      known.tab.target_id = js_str(at(info, "targetId"))
      known.tab.title = info_text(at(info, "title"), js(""))
      known.tab.url = info_text(at(info, "url"), js(""))
      known.tab.attached = truthy(at(info, "attached"))
      if known.tab.title_shown() != before || known.tab.url_text() != before_url {
        self.retitled(known)
      }
      activity()
    }
    "Target.targetDestroyed" => {
      let target_id = str_of(at(p, "targetId"))
      match target_id {
        Some(t) => {
          self.live_targets.remove(t)
          match self.p.user_tabs {
            Some(u) =>
              if (u.target_destroyed)(t) {
                self.contexts.remove(t)
                activity()
                return
              }
            None => ()
          }
        }
        None => ()
      }
      guard target_id is Some(t) && self.tabs.get(t) is Some(known) else { return }
      self.tabs.remove(t)
      self.contexts.remove(t)
      match self.p.owners {
        Some(o) => o.drop(t)
        None => ()
      }
      (known.remove)()
      activity()
    }
    _ => ()
  }
}

///|
fn Tabs::notify_child(self : Tabs, opener_target_id : String, child_screen_id : String) -> Unit {
  for active in self.views {
    if active.target_id == opener_target_id {
      for c in active.children.copy() {
        (c.1)(child_screen_id)
      }
    }
  }
}

///|
/// The titles read again a little later (and again after that), once a tab came or changed.
fn Tabs::titles_later(self : Tabs) -> Unit {
  let rereads = self.rereads
  self.rereads = []
  for stop in rereads {
    stop()
  }
  self.rereads = titles_after_ms.map(ms => (self.p.clock.after)(ms, async fn() { self.titles() }))
}

///|
async fn Tabs::titles(self : Tabs) -> Unit {
  if self.closed {
    return
  }
  let got = self.p.cdp.send("Target.getTargets", Obj([]), None) catch {
    _ => jo([("targetInfos", ja([]))])
  }
  let infos = match at(Some(got), "targetInfos") {
    Some(Arr(xs)) => xs
    _ => []
  }
  match self.p.user_tabs {
    Some(u) => (u.refresh_titles)(infos)
    None => ()
  }
  for info in infos {
    let iv = Some(info)
    guard self.tabs.get(js_str(at(iv, "targetId"))) is Some(known) else { continue }
    let title = info_text(at(iv, "title"), js(""))
    let url = info_text(at(iv, "url"), known.tab.url)
    if same_value(Some(title), Some(known.tab.title)) && same_value(Some(url), Some(known.tab.url)) {
      continue
    }
    let before = known.tab.title_shown()
    let before_url = known.tab.url_text()
    known.tab.title = title
    known.tab.url = url
    if known.tab.title_shown() != before || known.tab.url_text() != before_url {
      self.retitled(known)
    }
  }
}

///|
/// Where tab `target_id` is now (its address), or None where there is no such tab.
pub fn Tabs::url_of(self : Tabs, target_id : String) -> String? {
  self.tabs.get(target_id).map(k => k.tab.url_text())
}

///|
/// A tab's title changed: the screens' watchers hear of it.
fn Tabs::retitled(self : Tabs, known : Known) -> Unit {
  match self.p.screens {
    None => ()
    Some({ changed: Some(f), .. }) => f()
    Some(s) => known.remove = (s.add)(known.source)
  }
}

///|
/// A tab's size before a view says it: its viewport (what its frames show, not its window with the toolbar), read on a
/// connection of its own; its window's when that cannot be read.
pub async fn Tabs::measure_target(
  self : Tabs,
  target_id : String,
  sized : ((Double, Double)) -> Unit,
  current_width : () -> Double,
) -> Unit {
  let measured = attempt(async fn() {
    let cdp = (self.p.connect)()
    let r = attempt(async fn() {
      let attached = cdp.send(
        "Target.attachToTarget",
        jo([("targetId", js(target_id)), ("flatten", jb(true))]),
        None,
      )
      let session = str_of(at(Some(attached), "sessionId"))
      viewport_of(Some(cdp.send("Page.getLayoutMetrics", Obj([]), session)))
    })
    (cdp.close)()
    match r {
      Ok(Some(v)) => {
        if current_width() == 0.0 {
          sized(v)
        }
        true
      }
      Ok(None) => false
      Err(e) => raise e
    }
  })
  if measured is Ok(true) {
    return
  }
  let got = attempt(async fn() {
    self.p.cdp.send("Browser.getWindowForTarget", jo([("targetId", js(target_id))]), None)
  })
  match got {
    Ok(g) => {
      let bounds = at(Some(g), "bounds")
      if current_width() == 0.0 && js_num(at(bounds, "width")) > 0.0 {
        sized((js_num(at(bounds, "width")), js_num(at(bounds, "height"))))
      }
    }
    Err(_) => ()
  }
}
