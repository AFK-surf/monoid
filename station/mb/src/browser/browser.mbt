// The station's browser (src/browser/browser.ts): one real Chrome, kept for the agents, its tabs screens a person can
// see and drive. Started when an agent asks for it (the `browser` tool), started again if it dies while in use, closed
// after a long idle. It outlives a station process, as jobs do: the next one (a handover, a restart) finds it by its
// DevToolsActivePort and takes it up, its tabs and logins as they were.

///|
/// Unused this long (no agent asking for it, no tab coming, going or navigated, no one watching), it is closed.
pub let idle_ms : Double = 60.0 * 60_000.0

///|
/// One that ran this long before it died is started again at once; one that keeps dying waits longer each time.
let steady_ms : Double = 60_000.0

///|
let first_pause_ms : Double = 1000.0

///|
let max_pause_ms : Double = 60_000.0

///|
/// How often its last use is written down (for the station process after this one), at most.
let note_ms : Double = 60_000.0

///|
/// How long whether there is a Chrome on the machine is taken to stay as it was found.
let installed_ms : Double = 60_000.0

///|
/// What the browser says of itself (browser.ts `BrowserStatus`).
pub(all) struct BrowserStatus {
  running : Bool
  /// http://127.0.0.1:<port>: what chrome-devtools-mcp's --browserUrl and Playwright's connectOverCDP take.
  http : String?
  /// The browser's WebSocket (chrome-devtools-mcp --wsEndpoint).
  ws : String?
  binary : String?
  headless : Bool?
  /// Its process: Some(None) for one found without a record of it.
  pid : Int??
  tabs : Int?
  viewing : Int?
  /// When it was last used (ms).
  last_use : Double?
}

///|
pub fn BrowserStatus::off() -> BrowserStatus {
  {
    running: false,
    http: None,
    ws: None,
    binary: None,
    headless: None,
    pid: None,
    tabs: None,
    viewing: None,
    last_use: None,
  }
}

///|
pub fn BrowserStatus::to_j(self : BrowserStatus) -> J {
  let fs : Array[(String, J)] = [("running", jb(self.running))]
  match self.http {
    Some(h) => fs.push(("http", js(h)))
    None => ()
  }
  match self.ws {
    Some(w) => fs.push(("ws", js(w)))
    None => ()
  }
  match self.binary {
    Some(b) => fs.push(("binary", js(b)))
    None => ()
  }
  match self.headless {
    Some(h) => fs.push(("headless", jb(h)))
    None => ()
  }
  match self.pid {
    Some(Some(p)) => fs.push(("pid", ji(p)))
    Some(None) => fs.push(("pid", Null))
    None => ()
  }
  match self.tabs {
    Some(t) => fs.push(("tabs", ji(t)))
    None => ()
  }
  match self.viewing {
    Some(v) => fs.push(("viewing", ji(v)))
    None => ()
  }
  match self.last_use {
    Some(l) => fs.push(("lastUse", jn(l)))
    None => ()
  }
  jo(fs)
}

///|
pub(all) struct BrowserOptions {
  /// <data>/browser.
  dir : String
  chrome : ChromeHost
  screens : Screens?
  clock : Clock
  idle_ms : Double?
  user_tab_idle_ms : Double?
  /// The session whose chat's context a browser context is (browsers.mbt): a tab in it is that session's.
  context_owner : ((String?) -> String?)?
  used_tab : ((String, String) -> Unit)?
  files : Files
  log : Log
  uuid : () -> String
  random_hex : (Int) -> String
  /// This process's id (what names a file being written).
  pid : Int
}

///|
priv struct LoginTab {
  ctx : String
  state_file : () -> String?
  mut ending : Later[Unit]?
  mut saving : Later[Unit]
}

///|
priv struct Up {
  running : Running
  cdp : Cdp
  tabs : Tabs
  keys : Authenticators
  login_contexts : Map[String, Unit]
  login_tabs : Map[String, LoginTab]
  unlisten : () -> Unit
  since : Double
}

///|
pub struct StationBrowser {
  priv o : BrowserOptions
  priv idle_ms : Double
  priv flushing : Map[Int, Later[Unit]]
  priv mut flush_id : Int
  priv user_tabs : UserTabs
  priv mut default_create_queue : Later[Unit]
  priv mut active_login_contexts : Map[String, Unit]?
  priv mut up : Up?
  /// A start under way: whoever asks meanwhile waits for it.
  priv mut starting : Later[Up]?
  priv mut last_use : Double
  priv mut noted : Double
  priv mut pause : Double
  priv mut idle : () -> Unit
  priv mut restart : () -> Unit
  /// Closing on purpose (stopped, idle, or this station process ending): its end is not a death.
  priv mut leaving : Bool
  priv mut closed : Bool
  /// Which session opened each tab (owners.mbt).
  priv owners : Owners
  /// Its state.json (its last use): the Chrome host's, shared.
  priv state : BrowserState
  /// Its last use as state.json said it, read as it was made.
  priv mut loaded : Later[Unit]
  /// Whether a Chrome was found on the machine, and when it was looked for.
  priv mut installed : (Double, Bool)?
  priv mut login_state_seq : Int
}

///|
pub fn StationBrowser::new(o : BrowserOptions) -> StationBrowser {
  let state = match o.chrome.state {
    Some(s) => s
    None => BrowserState::new(o.dir, o.files, o.clock)
  }
  let self_ref : Ref[StationBrowser?] = Ref(None)
  let user_tabs = UserTabs::new({
    dir: o.dir,
    screens: o.screens,
    clock: o.clock,
    idle_ms: o.user_tab_idle_ms,
    is_isolated_context: Some(ctx => match ctx {
      Some(c) if c != "" => {
        let owned = match o.context_owner {
          Some(f) => f(Some(c)) is Some(_)
          None => false
        }
        owned ||
        (match self_ref.val {
          Some(b) =>
            match b.active_login_contexts {
              Some(l) => l.contains(c)
              None => false
            }
          None => false
        })
      }
      _ => false
    }),
    create_target: async fn(url, claim, claimed) {
      self_ref.val.unwrap().create_default_target(url, claim~, claimed~)
    },
    files: o.files,
    random_hex: o.random_hex,
  })
  let b : StationBrowser = {
    o,
    idle_ms: o.idle_ms.unwrap_or(idle_ms),
    flushing: {},
    flush_id: 0,
    user_tabs,
    default_create_queue: Later::resolved(()),
    active_login_contexts: None,
    up: None,
    starting: None,
    last_use: 0.0,
    noted: 0.0,
    pause: 0.0,
    idle: () => (),
    restart: () => (),
    leaving: false,
    closed: false,
    owners: Owners::new(o.dir, o.files, o.clock, o.log),
    state,
    loaded: Later::resolved(()),
    installed: None,
    login_state_seq: 0,
  }
  self_ref.val = Some(b)
  // A use since it was made is newer than what the file says.
  b.loaded = Later::start(o.clock, async fn() {
    let s = state.read()
    let said = match at(Some(s), "lastUse") {
      None | Some(Null) => 0.0
      v => js_num(v)
    }
    b.last_use = js_max(b.last_use, said)
  })
  match o.screens {
    Some({ set_browser: Some(f), .. }) => f(Some(b.as_screen_browser()))
    _ => ()
  }
  b
}

///|
/// `Math.max(a, b)` (NaN where either is).
fn js_max(a : Double, b : Double) -> Double {
  if a.is_nan() || b.is_nan() {
    @double.not_a_number
  } else if a > b {
    a
  } else {
    b
  }
}

///|
pub fn StationBrowser::as_screen_browser(self : StationBrowser) -> ScreenBrowser {
  { available: () => self.available(), open_user_tab: async fn(url, id) { self.open_user_tab(url, id?) } }
}

///|
fn StationBrowser::now(self : StationBrowser) -> Double {
  (self.o.clock.now)()
}

///|
async fn StationBrowser::all_ready(self : StationBrowser) -> Unit {
  self.user_tabs.ready()
  self.owners.ready()
  self.loaded.wait() catch {
    _ => ()
  }
}

///|
/// Takes up the Chrome an earlier station process left running, if there is one (its tabs become screens again).
pub async fn StationBrowser::resume(self : StationBrowser) -> Unit {
  self.all_ready()
  if self.closed || self.up is Some(_) || self.starting is Some(_) {
    return
  }
  let found = (self.o.chrome.find)() catch { _ => None }
  guard found is Some(running) else { return }
  if self.closed || self.up is Some(_) || self.starting is Some(_) {
    return
  }
  match attempt(async fn() { self.take(running) }) {
    Ok(_) =>
      (self.o.log.info)(
        "browser",
        "took up the Chrome left running",
        fields([("port", ji(running.port)), ("pid", pid_j(running.pid))]),
      )
    Err(e) =>
      (self.o.log.warn)(
        "browser",
        "the Chrome left running could not be taken up",
        fields([("error", js(message_of(e)))]),
      )
  }
}

///|
fn pid_j(pid : Int?) -> J {
  match pid {
    Some(p) => ji(p)
    None => Null
  }
}

///|
/// The browser, started if it is not running: what an agent connects to.
pub async fn StationBrowser::endpoint(self : StationBrowser) -> BrowserStatus {
  self.used()
  let up = self.ensure()
  self.status_of(up)
}

///|
/// Its tabs (none while it is not running).
pub fn StationBrowser::tabs(self : StationBrowser) -> Array[TabInfo] {
  match self.up {
    Some(up) => {
      self.used()
      up.tabs.list()
    }
    None => []
  }
}

///|
/// Whether it can be had here: it runs, or there is a Chrome on the machine to start (looked for again a minute on).
pub fn StationBrowser::available(self : StationBrowser) -> Bool {
  if self.up is Some(_) {
    return true
  }
  let now = self.now()
  match self.installed {
    Some((at_, _)) if now - at_ < installed_ms => ()
    _ => self.installed = Some((now, (self.o.chrome.installed)()))
  }
  self.installed.unwrap().1
}

///|
/// Opens a persistent user page (`browser:u_<id>`) in Chrome's default profile, recycled to sleep when idle.
pub async fn StationBrowser::open_user_tab(self : StationBrowser, url : String, id? : String) -> String {
  self.user_tabs.open_new(url, asked?=id)
}

///|
async fn StationBrowser::create_default_target(
  self : StationBrowser,
  url : String,
  claim? : () -> Unit,
  claimed? : (String, Tabs) -> Unit,
) -> (String, Tabs) {
  self.used()
  let up = self.ensure()
  let gate : @effect.Deferred[Unit] = @effect.Deferred::new()
  let prev = self.default_create_queue
  self.default_create_queue = Later::of(gate)
  prev.wait() catch {
    _ => ()
  }
  let r = attempt(async fn() {
    match claim {
      Some(f) => f()
      None => ()
    }
    let made = up.cdp.send("Target.createTarget", jo([("url", js(url))] + behind()), None)
    guard at(Some(made), "targetId") is Some(Str(t)) && t.length() > 0 else {
      raise fail_("Chrome opened no tab.")
    }
    let target_id = @jsjson.sanitize_str(t)
    match claimed {
      Some(f) => f(target_id, up.tabs)
      None => ()
    }
    (target_id, up.tabs)
  })
  ignore(gate.succeed(()))
  match r {
    Ok(v) => v
    Err(e) => raise e
  }
}

///|
/// A tab of the station's own (no session's) at `url`, in a window of its own opened behind the others, the browser
/// started if it is not running: its target id, once it is among the screens. With `state_file`, opened in a browser
/// context of its own whose cookies and passkeys are read from and saved back to that file (and disposed when the
/// tab closes).
pub async fn StationBrowser::open_tab(
  self : StationBrowser,
  url : String,
  state_file? : () -> String?,
) -> String {
  self.used()
  guard state_file is Some(state_file) else {
    let (target_id, tabs) = self.create_default_target(url)
    tabs.arrived(target_id)
    return target_id
  }
  let up = self.ensure()
  let made = up.cdp.send("Target.createBrowserContext", jo([("disposeOnDetach", jb(false))]), None)
  guard at(Some(made), "browserContextId") is Some(Str(cu)) && cu.length() > 0 else {
    raise fail_("Chrome made no browser context.")
  }
  let ctx = @jsjson.sanitize_str(cu)
  up.login_contexts[ctx] = ()
  match state_file() {
    Some(initial) =>
      match (self.o.files.read)(initial) {
        Some(kept) => {
          let state = state_of(kept)
          let cookies = all_cookies(Some(ja(state.cookies)))
          if cookies.length() > 0 {
            ignore(
              up.cdp.send(
                "Storage.setCookies",
                jo([("browserContextId", js(ctx)), ("cookies", ja(cookies))]),
                None,
              ),
            ) catch {
              _ =>
                for cookie in cookies {
                  ignore(
                    up.cdp.send(
                      "Storage.setCookies",
                      jo([("browserContextId", js(ctx)), ("cookies", ja([cookie]))]),
                      None,
                    ),
                  ) catch {
                    _ => ()
                  }
                }
            }
          }
          if state.passkeys.length() > 0 {
            up.keys.put(ctx, state.passkeys)
          }
        }
        None => ()
      }
    None => ()
  }
  let target_ref = Ref("")
  let r = attempt(async fn() {
    let created = up.cdp.send(
      "Target.createTarget",
      jo([("url", js(url)), ("browserContextId", js(ctx))] + behind()),
      None,
    )
    target_ref.val = text(at(Some(created), "targetId"))
    if target_ref.val == "" {
      raise fail_("Chrome opened no tab.")
    }
    up.login_tabs[target_ref.val] = { ctx, state_file, ending: None, saving: Later::resolved(()) }
    up.tabs.arrived(target_ref.val)
    target_ref.val
  })
  match r {
    Ok(t) => t
    Err(e) => {
      if target_ref.val != "" {
        up.login_tabs.remove(target_ref.val)
      }
      up.login_contexts.remove(ctx)
      up.keys.forget(ctx)
      ignore(up.cdp.send("Target.disposeBrowserContext", jo([("browserContextId", js(ctx))]), None)) catch {
        _ => ()
      }
      raise e
    }
  }
}

///|
/// A command on the browser's own DevTools connection (its cookies: browsers.mbt), the browser started if it is not
/// running.
pub async fn StationBrowser::send(self : StationBrowser, method : String, params? : J = Obj([])) -> J {
  self.used()
  let up = self.ensure()
  up.cdp.send(method, params, None)
}

///|
/// A connection of its own to tab `target_id` (a sign-in's form filled by the station: signin_form.mbt), the tab's
/// session on it; closing it lets go of the tab.
pub async fn StationBrowser::attach(self : StationBrowser, target_id : String) -> (Cdp, String) {
  self.used()
  let up = self.ensure()
  if !up.tabs.has(target_id) {
    raise fail_("This tab is closed.")
  }
  let cdp = (self.o.chrome.connect)(up.running.ws)
  let r = attempt(async fn() {
    cdp.send("Target.attachToTarget", jo([("targetId", js(target_id)), ("flatten", jb(true))]), None)
  })
  match r {
    Ok(a) => (cdp, text(at(Some(a), "sessionId")))
    Err(e) => {
      (cdp.close)()
      raise e
    }
  }
}

///|
/// The chats' tabs' authenticators (passkeys.mbt), the browser started if it is not running.
pub async fn StationBrowser::passkeys(self : StationBrowser) -> Authenticators {
  self.used()
  self.ensure().keys
}

///|
/// The browser context of target `target_id` (any target: a page, a frame, a worker), when it is known.
pub fn StationBrowser::context_of(self : StationBrowser, target_id : String) -> String? {
  match self.up {
    Some(up) => up.tabs.context_of(target_id)
    None => None
  }
}

///|
/// Where tab `target_id` is now, or None where it is not there.
pub fn StationBrowser::tab_url(self : StationBrowser, target_id : String) -> String? {
  match self.up {
    Some(up) => up.tabs.url_of(target_id)
    None => None
  }
}

///|
/// Whether tab `target_id` is there.
pub fn StationBrowser::has_tab(self : StationBrowser, target_id : String) -> Bool {
  match self.up {
    Some(up) => up.tabs.has(target_id)
    None => false
  }
}

///|
/// Closes tab `target_id`, if it is there.
pub async fn StationBrowser::close_tab(self : StationBrowser, target_id : String) -> Unit {
  guard self.up is Some(up) else { return }
  if up.login_tabs.contains(target_id) {
    self.track_flush(self.end_login_tab(up, target_id, true)).wait() catch {
      _ => ()
    }
    return
  }
  if !up.tabs.has(target_id) {
    return
  }
  up.tabs.close_tab(target_id) catch {
    _ => ()
  }
}

///|
/// Waits for any in-flight login-context and user-tab saves and disposals to finish.
pub async fn StationBrowser::flushed(self : StationBrowser) -> Unit {
  while self.flushing.length() > 0 {
    let all = []
    for _, l in self.flushing {
      all.push(l)
    }
    for l in all {
      l.wait() catch {
        _ => ()
      }
    }
  }
  self.user_tabs.written()
}

///|
/// Tab `target_id` was opened by `session` (on its own connection, proxy.mbt).
pub fn StationBrowser::own(self : StationBrowser, target_id : String, session : String) -> Unit {
  match self.up {
    Some(up) => up.tabs.owned(target_id, session)
    None => ignore(self.owners.set(target_id, session))
  }
}

///|
/// Closes the tabs `session` opened (its chat archived or deleted); the browser stays.
pub async fn StationBrowser::close_of(self : StationBrowser, session : String) -> Unit {
  guard self.up is Some(up) else { return }
  let ids = up.tabs.of_session(session)
  if ids.length() == 0 {
    return
  }
  (self.o.log.info)(
    "browser",
    "closing the tabs of a session that ended",
    fields([("session", js(session)), ("tabs", ji(ids.length()))]),
  )
  all_of(
    self.o.clock,
    ids.map(id => async fn() {
      up.tabs.close_tab(id) catch {
        _ => ()
      }
    }),
  )
}

///|
pub fn StationBrowser::status(self : StationBrowser) -> BrowserStatus {
  match self.up {
    Some(up) => self.status_of(up)
    None =>
      {
        ..BrowserStatus::off(),
        last_use: if self.last_use == 0.0 || self.last_use.is_nan() { None } else { Some(self.last_use) },
      }
  }
}

///|
/// Something used it now (an agent asked, a tab changed, a view opened or ended).
pub fn StationBrowser::used(self : StationBrowser) -> Unit {
  self.last_use = self.now()
  if self.last_use - self.noted >= note_ms {
    self.note()
  }
}

///|
/// Closes it (its tabs with it); the profile and its logins stay.
pub async fn StationBrowser::stop(self : StationBrowser) -> Unit {
  let up = match self.up {
    Some(u) => Some(u)
    None =>
      match self.starting {
        Some(s) => (try Some(s.wait()) catch { _ => None })
        None => None
      }
  }
  guard up is Some(u) else { return }
  self.end(u, "asked to stop")
}

///|
/// This station process ends: lets go of the browser, which goes on running for the next one to take up.
pub async fn StationBrowser::close(self : StationBrowser) -> Unit {
  if self.closed {
    return
  }
  self.closed = true
  self.leaving = true
  (self.idle)()
  (self.restart)()
  match self.o.screens {
    Some({ set_browser: Some(f), .. }) => f(None)
    _ => ()
  }
  let up = self.up
  self.up = None
  self.active_login_contexts = None
  match up {
    Some(u) => {
      for _, tab in u.login_tabs {
        if tab.ending is None {
          ignore(self.track_flush(self.save_login_tab(u, tab)))
        }
      }
      self.flushed()
      self.user_tabs.close()
      (u.unlisten)()
      u.tabs.close()
      u.keys.close()
      (u.cdp.close)()
    }
    None => {
      self.flushed()
      self.user_tabs.close()
    }
  }
  self.note()
  // What the next station process takes up: written down before this one lets go.
  self.owners.written()
  self.state.written()
}

///|
fn StationBrowser::status_of(self : StationBrowser, up : Up) -> BrowserStatus {
  {
    running: true,
    http: Some("http://127.0.0.1:\{up.running.port}"),
    ws: Some(up.running.ws),
    binary: Some(up.running.binary),
    headless: Some(up.running.headless),
    pid: Some(up.running.pid),
    tabs: Some(up.tabs.list().length()),
    viewing: Some(up.tabs.viewing()),
    last_use: Some(self.last_use),
  }
}

///|
async fn StationBrowser::ensure(self : StationBrowser) -> Up {
  if self.closed {
    raise fail_("The station is stopping.")
  }
  match self.up {
    Some(u) => return u
    None => ()
  }
  match self.starting {
    Some(s) => return s.wait()
    None => ()
  }
  (self.restart)()
  let me : Ref[Later[Up]?] = Ref(None)
  let starting = Later::start(self.o.clock, async fn() {
    let r = attempt(async fn() {
      self.all_ready()
      // One left running by an earlier station process, else a new one.
      let found = (self.o.chrome.find)() catch { _ => None }
      let running = match found {
        Some(f) => f
        None => (self.o.chrome.launch)()
      }
      self.take(running)
    })
    match (self.starting, me.val) {
      (Some(s), Some(m)) if s.same(m) => self.starting = None
      _ => ()
    }
    match r {
      Ok(u) => u
      Err(e) => raise e
    }
  })
  me.val = Some(starting)
  self.starting = Some(starting)
  starting.wait()
}

///|
/// Watches a running Chrome: its tabs into the screens, its end heard.
async fn StationBrowser::take(self : StationBrowser, running : Running) -> Up {
  let chrome = self.o.chrome
  let cdp = (chrome.connect)(running.ws)
  // (each chat's tab and each isolated login tab its authenticator: passkeys.mbt; the station's shared context has
  // none)
  let owner = self.o.context_owner
  let login_contexts : Map[String, Unit] = {}
  let login_tabs : Map[String, LoginTab] = {}
  self.active_login_contexts = Some(login_contexts)
  let current : Ref[Up?] = Ref(None)
  let keys = Authenticators::new(
    cdp,
    ctx => (match owner {
        Some(f) => f(Some(ctx)) is Some(_)
        None => false
      }) ||
      login_contexts.contains(ctx),
    on_changed=ctx => self.login_context_changed(current.val, ctx),
    clock=self.o.clock,
    log=self.o.log,
  )
  let tabs_ref : Ref[Tabs?] = Ref(None)
  let tabs = Tabs::new({
    cdp,
    screens: self.o.screens,
    connect: async fn() { (chrome.connect)(running.ws) },
    now: () => self.now(),
    activity: () => self.used(),
    clock: self.o.clock,
    owners: Some(self.owners),
    context_owner: owner,
    used_tab: Some((session, target) => match self.o.used_tab {
      Some(f) => f(session, target)
      None => ()
    }),
    own_passkey: Some((target_id, rp_id) => match tabs_ref.val {
      Some(t) =>
        match t.context_of(target_id) {
          Some(ctx) => keys.has(ctx, rp_id)
          None => false
        }
      None => false
    }),
    user_tabs: Some(self.user_tabs.hooks()),
    uuid: self.o.uuid,
  })
  tabs_ref.val = Some(tabs)
  self.user_tabs.attaching(tabs)
  let unlisten = (cdp.on)(e => self.heard_login(current.val, e))
  let started = attempt(async fn() {
    keys.start()
    tabs.start()
    self.user_tabs.attached(tabs)
  })
  match started {
    Ok(_) => ()
    Err(e) => {
      self.active_login_contexts = None
      self.user_tabs.browser_stopped()
      unlisten()
      keys.close()
      tabs.close()
      (cdp.close)()
      raise e
    }
  }
  if self.closed {
    self.active_login_contexts = None
    unlisten()
    keys.close()
    tabs.close()
    (cdp.close)()
    raise fail_("The station is stopping.")
  }
  let up : Up = { running, cdp, tabs, keys, login_contexts, login_tabs, unlisten, since: self.now() }
  current.val = Some(up)
  self.up = Some(up)
  self.leaving = false
  (self.o.clock.spawn)(async fn() {
    (cdp.closed)()
    self.lost(up)
  })
  self.arm_idle()
  up
}

///|
fn StationBrowser::is_up(self : StationBrowser, up : Up) -> Bool {
  match self.up {
    Some(u) => physical_equal(u, up)
    None => false
  }
}

///|
/// Its connection ended: closed on purpose, or the browser is gone (it died, or someone quit it).
fn StationBrowser::lost(self : StationBrowser, up : Up) -> Unit {
  if !self.is_up(up) {
    return
  }
  self.up = None
  self.active_login_contexts = None
  (up.unlisten)()
  up.tabs.close()
  self.user_tabs.browser_stopped()
  up.keys.close()
  (self.idle)()
  if self.leaving || self.closed {
    return
  }
  let in_use = self.now() - self.last_use < self.idle_ms
  (self.o.log.warn)(
    "browser",
    "Chrome ended by itself",
    fields([("pid", pid_j(up.running.pid)), ("inUse", jb(in_use))]),
  )
  // Its group (what it left) ended, and its record taken away, before another is started.
  let killed = Later::start(self.o.clock, async fn() {
    (self.o.chrome.kill)(up.running) catch {
      _ => ()
    }
  })
  if !in_use {
    return
  }
  // In use: started again, at once if it had run a while, else after a pause that grows.
  let ran = self.now() - up.since
  self.pause = if ran >= steady_ms {
    0.0
  } else {
    let doubled = self.pause * 2.0
    let at_least = if doubled > first_pause_ms { doubled } else { first_pause_ms }
    if at_least < max_pause_ms {
      at_least
    } else {
      max_pause_ms
    }
  }
  let again = async fn() {
    killed.wait() catch {
      _ => ()
    }
    if self.up is Some(_) || self.starting is Some(_) || self.closed {
      return
    }
    match attempt(async fn() { ignore(self.ensure()) }) {
      Ok(_) => (self.o.log.info)("browser", "Chrome started again", fields([]))
      Err(e) =>
        (self.o.log.warn)("browser", "Chrome could not be started again", fields([("error", js(message_of(e)))]))
    }
  }
  if self.pause == 0.0 {
    (self.o.clock.spawn)(again)
  } else {
    self.restart = self.after(self.pause, again)
  }
}

///|
/// A timer of this part's (its Fibers'): none once it is closed.
fn StationBrowser::after(self : StationBrowser, ms : Double, f : async () -> Unit) -> () -> Unit {
  (self.o.clock.after)(ms, async fn() {
    if !self.closed {
      f()
    }
  })
}

///|
/// Closed once it has been idle long enough: looked at when it would be, and again then if it was used since.
fn StationBrowser::arm_idle(self : StationBrowser) -> Unit {
  (self.idle)()
  guard self.up is Some(up) else { return }
  let left0 = self.last_use + self.idle_ms - self.now()
  let left = if left0 > 0.0 { left0 } else { 0.0 }
  self.idle = self.after(left, async fn() {
    if !self.is_up(up) {
      return
    }
    if up.tabs.viewing() > 0 {
      self.used()
    }
    if self.now() - self.last_use >= self.idle_ms {
      self.end(up, "idle")
      return
    }
    self.arm_idle()
  })
}

///|
async fn StationBrowser::end(self : StationBrowser, up : Up, why : String) -> Unit {
  self.leaving = true
  (self.idle)()
  (self.restart)()
  (self.o.log.info)("browser", "closing Chrome", fields([("why", js(why)), ("pid", pid_j(up.running.pid))]))
  for _, tab in up.login_tabs {
    if tab.ending is None {
      ignore(self.track_flush(self.save_login_tab(up, tab)))
    }
  }
  self.flushed()
  (up.unlisten)()
  up.tabs.close()
  self.user_tabs.browser_stopped()
  up.keys.close()
  ignore(up.cdp.send("Browser.close", Obj([]), None)) catch {
    _ => ()
  }
  (up.cdp.close)()
  if self.is_up(up) {
    self.up = None
    self.active_login_contexts = None
  }
  (self.o.chrome.kill)(up.running)
  self.pause = 0.0
  self.note()
}

///|
fn StationBrowser::track_flush(self : StationBrowser, p : Later[Unit]) -> Later[Unit] {
  self.flush_id += 1
  let id = self.flush_id
  let tracked = Later::start(self.o.clock, async fn() {
    p.wait() catch {
      _ => ()
    }
    self.flushing.remove(id)
  })
  self.flushing[id] = tracked
  p
}

///|
fn StationBrowser::heard_login(self : StationBrowser, up : Up?, e : CdpEvent) -> Unit {
  guard up is Some(up) && e.session_id is None else { return }
  if e.method == "Target.targetInfoChanged" {
    match at_path(Some(e.params), ["targetInfo", "targetId"]) {
      Some(Str(u)) =>
        match up.login_tabs.get(@jsjson.sanitize_str(u)) {
          Some(tab) if tab.ending is None => ignore(self.track_flush(self.save_login_tab(up, tab)))
          _ => ()
        }
      _ => ()
    }
  } else if e.method == "Target.targetDestroyed" {
    match at(Some(e.params), "targetId") {
      Some(Str(u)) => {
        let target_id = @jsjson.sanitize_str(u)
        match up.login_tabs.get(target_id) {
          Some(tab) if tab.ending is None =>
            ignore(self.track_flush(self.end_login_tab(up, target_id, false)))
          _ => ()
        }
      }
      _ => ()
    }
  }
}

///|
fn StationBrowser::login_context_changed(self : StationBrowser, up : Up?, ctx : String) -> Unit {
  guard up is Some(up) else { return }
  for _, tab in up.login_tabs {
    if tab.ctx == ctx && tab.ending is None {
      ignore(self.track_flush(self.save_login_tab(up, tab)))
    }
  }
}

///|
/// Writes `content` to `resolve_path()` (0600) only when its parent directory exists: never recreates a dropped
/// pending login's home, and follows a new login's home if it was just renamed.
async fn StationBrowser::write_login_state(
  self : StationBrowser,
  resolve_path : () -> String?,
  content : String,
) -> Unit {
  let mut tried : String? = None
  for _attempt in 0..<2 {
    guard resolve_path() is Some(path) else { return }
    if tried == Some(path) {
      return
    }
    tried = Some(path)
    self.login_state_seq += 1
    let tmp = "\{path}.\{self.o.pid}.\{self.login_state_seq}.tmp"
    match attempt(async fn() { (self.o.files.create)(tmp, content) }) {
      Ok(_) => ()
      Err(FsError("ENOENT", _)) => continue
      Err(e) => raise e
    }
    match attempt(async fn() { (self.o.files.rename)(tmp, path) }) {
      Ok(_) => return
      Err(e) => {
        (self.o.files.unlink)(tmp) catch {
          _ => ()
        }
        match e {
          FsError("ENOENT", _) => continue
          _ => raise e
        }
      }
    }
  }
}

///|
fn StationBrowser::save_login_tab(self : StationBrowser, up : Up, tab : LoginTab) -> Later[Unit] {
  let before = tab.saving
  let next = Later::start(self.o.clock, async fn() {
    before.wait() catch {
      _ => ()
    }
    (async fn() {
      guard (tab.state_file)() is Some(_) else { return }
      let got = up.cdp.send("Storage.getCookies", jo([("browserContextId", js(tab.ctx))]), None) catch {
        _ => return
      }
      let cookies = all_cookies(at(Some(got), "cookies"))
      let passkeys = up.keys.read(tab.ctx) catch { _ => [] }
      if cookies.length() == 0 && passkeys.length() == 0 {
        match (tab.state_file)() {
          Some(target) =>
            (self.o.files.unlink)(target) catch {
              _ => ()
            }
          None => ()
        }
        return
      }
      self.write_login_state(tab.state_file, kept_of({ cookies, passkeys }))
    })() catch {
      e =>
        (self.o.log.warn)(
          "browser",
          "could not save a login tab's state",
          fields([("error", js(message_of(e)))]),
        )
    }
  })
  tab.saving = next
  next
}

///|
fn StationBrowser::end_login_tab(
  self : StationBrowser,
  up : Up,
  target_id : String,
  close_target : Bool,
) -> Later[Unit] {
  guard up.login_tabs.get(target_id) is Some(tab) else { return Later::resolved(()) }
  match tab.ending {
    Some(e) => return e
    None => ()
  }
  let saved = self.save_login_tab(up, tab)
  let ending = Later::start(self.o.clock, async fn() {
    saved.wait() catch {
      _ => ()
    }
    if close_target && up.tabs.has(target_id) {
      up.tabs.close_tab(target_id) catch {
        _ => ()
      }
    }
    up.login_tabs.remove(target_id)
    up.login_contexts.remove(tab.ctx)
    up.keys.forget(tab.ctx)
    ignore(up.cdp.send("Target.disposeBrowserContext", jo([("browserContextId", js(tab.ctx))]), None)) catch {
      _ => ()
    }
  })
  tab.ending = Some(ending)
  ending
}

///|
fn StationBrowser::note(self : StationBrowser) -> Unit {
  self.noted = self.now()
  let last_use = self.last_use
  // Never older than what is there (read as it was made: a note before that is not to undo it).
  ignore(
    self.state.start_change(s => {
      let had = match at(Some(s), "lastUse") {
        None | Some(Null) => 0.0
        v => js_num(v)
      }
      put(spread(Obj([]), s), "lastUse", jn(js_max(had, last_use)))
    }),
  )
}

///|
/// The user tabs (the browsers' tests reach them).
pub fn StationBrowser::user_tabs(self : StationBrowser) -> UserTabs {
  self.user_tabs
}
