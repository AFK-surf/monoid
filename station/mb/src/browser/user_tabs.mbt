// A person's own pages in the station's browser (src/browser/user-tabs.ts, `browser:u_<id>`): opened in Chrome's
// persistent default profile so sign-ins survive across sessions, hidden from agents, and recycled like Arc tabs — when
// nobody views one for `user_tab_idle_ms` (or when Chrome stops), its underlying Chrome target closes to free memory
// while its entry stays in the screens (`sleeping`) and reloads its saved URL the next time a person opens it.

///|
/// Unviewed this long, a live user tab closes its Chrome target and sleeps until opened again.
pub let user_tab_idle_ms : Double = 10.0 * 60_000.0

///|
pub(all) struct UserTabsOptions {
  dir : String
  screens : Screens?
  clock : Clock
  idle_ms : Double?
  is_isolated_context : ((String?) -> Bool)?
  /// A target made in the default context, `claim` told as it is asked for and `claimed` as Chrome made it.
  create_target : async (String, () -> Unit, (String, Tabs) -> Unit) -> (String, Tabs)
  files : Files
  /// `n` random bytes, in hex.
  random_hex : (Int) -> String
}

///|
priv struct UserTab {
  key : String
  id : String
  popup : Bool
  mut url : String
  mut saved_title : String
  mut target_id : String?
  mut resume_target_id : String?
  mut views : Int
  mut waking : Later[String]?
  mut pending_navigate_url : String?
  mut hibernating : Bool
  mut discarded : Bool
  mut cancel_idle : () -> Unit
  mut remove_screen : () -> Unit
  mut size_ : (Double, Double)
}

///|
fn UserTab::make(key : String, url : String, title : String, popup : Bool, resume? : String) -> UserTab {
  {
    key,
    id: "browser:\{key}",
    popup,
    url,
    saved_title: title,
    target_id: None,
    resume_target_id: resume,
    views: 0,
    waking: None,
    pending_navigate_url: None,
    hibernating: false,
    discarded: false,
    cancel_idle: () => (),
    remove_screen: () => (),
    size_: (0.0, 0.0),
  }
}

///|
/// Its page's title; "" on a new tab's blank page (the app names that 新标签页 in the viewer's words).
fn UserTab::title(self : UserTab) -> String {
  if self.url == blank_page {
    return self.saved_title
  }
  if self.saved_title != "" {
    return self.saved_title
  }
  match site_of_browser_url(self.url) {
    Some(s) if s != "" => s
    _ => self.url
  }
}

///|
fn UserTab::site(self : UserTab) -> String? {
  site_of_browser_url(self.url)
}

///|
fn UserTab::size(self : UserTab) -> (Double, Double) {
  if self.target_id is None {
    (0.0, 0.0)
  } else {
    self.size_
  }
}

///|
pub struct UserTabs {
  priv o : UserTabsOptions
  priv file : PrivateFile
  priv idle_ms : Double
  priv by_key : Map[String, UserTab]
  priv by_target : Map[String, UserTab]
  priv mut claiming : UserTab?
  priv mut ready_ : Later[Unit]
  priv mut tabs : Tabs?
  priv mut popup_seq : Int
  priv mut closed : Bool
}

///|
pub fn UserTabs::new(o : UserTabsOptions) -> UserTabs {
  let u : UserTabs = {
    o,
    file: PrivateFile::new(join(o.dir, "user-tabs.json"), o.files, o.clock),
    idle_ms: o.idle_ms.unwrap_or(user_tab_idle_ms),
    by_key: {},
    by_target: {},
    claiming: None,
    ready_: Later::resolved(()),
    tabs: None,
    popup_seq: 0,
    closed: false,
  }
  u.ready_ = Later::start(o.clock, async fn() { u.load() })
  u
}

///|
pub async fn UserTabs::ready(self : UserTabs) -> Unit {
  self.ready_.wait() catch {
    _ => ()
  }
}

///|
pub async fn UserTabs::written(self : UserTabs) -> Unit {
  self.ready()
  self.file.written()
}

///|
pub fn UserTabs::notify_screens(self : UserTabs) -> Unit {
  told_changed(self.o.screens)
}

///|
fn UserTabs::source_of(self : UserTabs, tab : UserTab) -> ScreenSource {
  {
    id: tab.id,
    kind: "browser",
    peek: () => tab.target_id is Some(_),
    title: () => tab.title(),
    site: () => tab.site(),
    address: () => tab.url,
    size: () => tab.size(),
    clipboard: () => ["text"],
    opened_by: () => None,
    open: async fn(o) { self.open_view(tab, o) },
    open_url: Some(async fn(url) { self.navigate(tab, url) }),
    reload: Some(async fn() { self.reload(tab) }),
    back: Some(async fn() { self.history(tab, -1) }),
    forward: Some(async fn() { self.history(tab, 1) }),
    discard: Some(async fn() { self.discard(tab) }),
    sleep: Some(async fn() { self.sleep(tab) }),
    user_tab: true,
    popup: tab.popup,
    sleeping: () => tab.target_id is None,
    farview: false,
  }
}

///|
fn UserTabs::add_screen(self : UserTabs, tab : UserTab) -> () -> Unit {
  match self.o.screens {
    Some(s) => (s.add)(self.source_of(tab))
    None => () => ()
  }
}

///|
fn UserTabs::sized(self : UserTabs, tab : UserTab, size : (Double, Double)) -> Unit {
  if size.0 == tab.size_.0 && size.1 == tab.size_.1 {
    return
  }
  tab.size_ = size
  self.notify_screens()
}

///|
fn UserTabs::not_found() -> ScreenRefused {
  ScreenRefused(404, "station.screen.notFound")
}

///|
/// Opens a new persistent user page at `raw_url` (an address or words searched for; none, a new tab's blank page) and
/// returns its stable screen id (`browser:u_<id>`). `asked`: the key the app made for it, so its view was opened as it
/// was pressed; asked again (the app's call retried), the tab it named already.
pub async fn UserTabs::open_new(self : UserTabs, raw_url : String, asked? : String) -> String {
  self.ready()
  match asked {
    Some(a) if self.by_key.contains(a) => return "browser:\{a}"
    _ => ()
  }
  let url = if trim(raw_url) == "" { Some(blank_page) } else { address_or_search(raw_url) }
  guard url is Some(url) else { raise ScreenRefused(400, "station.screen.badUrl") }
  let key = match asked {
    Some(a) => a
    None => self.fresh_key()
  }
  let tab = UserTab::make(key, url, "", false)
  self.by_key[key] = tab
  tab.remove_screen = self.add_screen(tab)
  ignore(self.wake(tab, url)) catch {
    e => {
      tab.discarded = true
      (tab.cancel_idle)()
      self.by_key.remove(key)
      (tab.remove_screen)()
      self.save()
      raise e
    }
  }
  if tab.views == 0 {
    self.arm_idle(tab)
  }
  self.save()
  tab.id
}

///|
async fn UserTabs::open_view(self : UserTabs, tab : UserTab, options : ViewOptions) -> ScreenView {
  self.ready()
  if tab.discarded || self.closed {
    raise UserTabs::not_found()
  }
  if options.peek && tab.target_id is None {
    raise fail_("This tab is sleeping.")
  }
  let target_id = self.ensure_live(tab)
  guard self.tabs is Some(tabs) && !tab.discarded && tab.target_id == Some(target_id) else {
    raise UserTabs::not_found()
  }
  let counted = !options.peek
  if counted {
    tab.views += 1
    (tab.cancel_idle)()
  }
  let let_go = () => {
    if !counted {
      return
    }
    tab.views = if tab.views - 1 > 0 { tab.views - 1 } else { 0 }
    if tab.views == 0 && tab.target_id is Some(_) && !tab.discarded && !self.closed {
      self.arm_idle(tab)
    }
  }
  tabs.open_target(target_id, options, sized=s => self.sized(tab, s), ended=let_go) catch {
    e => {
      let_go()
      raise e
    }
  }
}

///|
async fn UserTabs::navigate(self : UserTabs, tab : UserTab, raw_url : String) -> Unit {
  self.ready()
  if tab.discarded || self.closed {
    raise UserTabs::not_found()
  }
  guard address_or_search(raw_url) is Some(url) else { raise ScreenRefused(400, "station.screen.badUrl") }
  tab.url = url
  tab.saved_title = ""
  self.save()
  self.notify_screens()
  match (tab.target_id, self.tabs) {
    (Some(t), Some(tabs)) => {
      tab.pending_navigate_url = None
      tabs.navigate_target(t, url)
      if tab.views == 0 {
        self.arm_idle(tab)
      }
      return
    }
    _ => ()
  }
  let joined_existing_wake = tab.waking is Some(_)
  tab.pending_navigate_url = Some(url)
  let woke = attempt(async fn() { self.ensure_live(tab, override_url=url) })
  if tab.pending_navigate_url == Some(url) {
    tab.pending_navigate_url = None
  }
  let target_id = match woke {
    Ok(t) => t
    Err(e) => raise e
  }
  if joined_existing_wake &&
    !tab.discarded &&
    !self.closed &&
    tab.url == url &&
    self.tabs is Some(_) &&
    tab.target_id == Some(target_id) {
    self.tabs.unwrap().navigate_target(target_id, url)
    if !tab.popup {
      self.save()
    }
  }
  if tab.views == 0 {
    self.arm_idle(tab)
  }
}

///|
async fn UserTabs::reload(self : UserTabs, tab : UserTab) -> Unit {
  self.ready()
  if tab.discarded || self.closed {
    raise UserTabs::not_found()
  }
  match (tab.target_id, self.tabs) {
    (Some(t), Some(tabs)) => {
      tabs.reload_target(t)
      if tab.views == 0 {
        self.arm_idle(tab)
      }
      return
    }
    _ => ()
  }
  ignore(self.ensure_live(tab))
  if tab.views == 0 {
    self.arm_idle(tab)
  }
}

///|
/// Goes `delta` steps through its history (-1 back, 1 forward); a sleeping tab kept no history, so it only wakes.
async fn UserTabs::history(self : UserTabs, tab : UserTab, delta : Int) -> Unit {
  self.ready()
  if tab.discarded || self.closed {
    raise UserTabs::not_found()
  }
  match (tab.target_id, self.tabs) {
    (Some(t), Some(tabs)) => tabs.history_target(t, delta)
    _ => ignore(self.ensure_live(tab))
  }
  if tab.views == 0 {
    self.arm_idle(tab)
  }
}

///|
async fn UserTabs::sleep(self : UserTabs, tab : UserTab) -> Unit {
  self.ready()
  if tab.discarded || self.closed {
    return
  }
  if tab.popup {
    self.discard(tab)
    return
  }
  guard tab.target_id is Some(target_id) else { return }
  tab.hibernating = true
  tab.pending_navigate_url = None
  (tab.cancel_idle)()
  tab.target_id = None
  tab.resume_target_id = None
  tab.size_ = (0.0, 0.0)
  self.by_target.remove(target_id)
  self.save()
  self.notify_screens()
  match self.tabs {
    Some(tabs) => {
      tabs.close_views_of(target_id)
      tabs.close_target(target_id) catch {
        _ => ()
      }
    }
    None => ()
  }
  tab.hibernating = false
}

///|
async fn UserTabs::discard(self : UserTabs, tab : UserTab) -> Unit {
  self.ready()
  if tab.discarded {
    return
  }
  tab.discarded = true
  tab.pending_navigate_url = None
  (tab.cancel_idle)()
  let target_id = tab.target_id
  tab.target_id = None
  tab.resume_target_id = None
  match target_id {
    Some(t) => self.by_target.remove(t)
    None => ()
  }
  self.by_key.remove(tab.key)
  (tab.remove_screen)()
  if !tab.popup {
    self.save()
  }
  match (target_id, self.tabs) {
    (Some(t), Some(tabs)) => {
      tabs.close_views_of(t)
      tabs.close_target(t) catch {
        _ => ()
      }
    }
    _ => ()
  }
}

///|
/// Attaches a newly connected `Tabs` before its start discovers targets.
pub fn UserTabs::attaching(self : UserTabs, tabs : Tabs) -> Unit {
  self.tabs = Some(tabs)
}

///|
/// Finishes attaching once the tabs' start has discovered every live target in Chrome.
pub fn UserTabs::attached(self : UserTabs, tabs : Tabs) -> Unit {
  match self.tabs {
    Some(t) if physical_equal(t, tabs) => ()
    _ => return
  }
  let mut changed = false
  for _, tab in self.by_key {
    if tab.resume_target_id is Some(_) && tab.target_id is None {
      tab.resume_target_id = None
      changed = true
    }
  }
  if changed {
    self.save()
  }
}

///|
/// Chrome stopped or died: live user pages become sleeping entries; transient popups are removed.
pub fn UserTabs::browser_stopped(self : UserTabs) -> Unit {
  self.tabs = None
  self.claiming = None
  self.by_target.clear()
  let mut changed = false
  let mut screens_changed = false
  let all = []
  for _, tab in self.by_key {
    all.push(tab)
  }
  for tab in all {
    (tab.cancel_idle)()
    tab.pending_navigate_url = None
    tab.views = 0
    tab.hibernating = false
    if tab.popup {
      tab.discarded = true
      tab.target_id = None
      self.by_key.remove(tab.key)
      (tab.remove_screen)()
      continue
    }
    if tab.target_id is Some(_) || tab.resume_target_id is Some(_) {
      tab.target_id = None
      tab.resume_target_id = None
      tab.size_ = (0.0, 0.0)
      changed = true
      screens_changed = true
    }
  }
  if changed {
    self.save()
  }
  if screens_changed {
    self.notify_screens()
  }
}

///|
/// Station process ending (handover): leaves live target ids in `user-tabs.json` for the next station to re-adopt.
pub async fn UserTabs::close(self : UserTabs) -> Unit {
  if self.closed {
    return
  }
  self.closed = true
  for _, tab in self.by_key {
    (tab.cancel_idle)()
  }
  self.written()
}

///|
fn UserTabs::measure(self : UserTabs, tab : UserTab, target_id : String) -> Unit {
  match self.tabs {
    Some(tabs) =>
      (self.o.clock.spawn)(async fn() {
        tabs.measure_target(target_id, s => self.sized(tab, s), () => tab.size().0)
      })
    None => ()
  }
}

///|
/// Claims a newly created Chrome page target when it is a user tab (or a popup opened from one).
pub fn UserTabs::target_created(self : UserTabs, info : J) -> String? {
  let iv = Some(info)
  let target_id = js_str(at(iv, "targetId"))
  match self.by_target.get(target_id) {
    Some(existing) => {
      self.apply_info(existing, info, true)
      self.measure(existing, target_id)
      return Some(existing.id)
    }
    None => ()
  }
  match self.o.is_isolated_context {
    Some(f) => if f(str_of(at(iv, "browserContextId"))) { return None }
    None => ()
  }
  // 1. Re-adopting a live user tab left running by an earlier station process.
  for _, tab in self.by_key {
    if tab.target_id is None && tab.resume_target_id == Some(target_id) {
      self.bind_target(tab, target_id)
      self.apply_info(tab, info, true)
      if tab.views == 0 {
        self.arm_idle(tab)
      }
      self.measure(tab, target_id)
      return Some(tab.id)
    }
  }
  // 2. The target the user tabs are creating right now on the default-context creation queue.
  if !truthy(at(iv, "openerId")) {
    match self.claiming {
      Some(tab) => {
        self.claiming = None
        if !tab.discarded {
          self.bind_target(tab, target_id)
          self.apply_info(tab, info, true)
          self.measure(tab, target_id)
          return Some(tab.id)
        }
      }
      None => ()
    }
  }
  // 3. A child popup / `target="_blank"` tab opened from a live user tab.
  let opener = if truthy(at(iv, "openerId")) {
    self.by_target.get(js_str(at(iv, "openerId")))
  } else {
    None
  }
  match opener {
    Some(o) => {
      self.popup_seq += 1
      let key = "u_p_\{self.popup_seq}_\{(self.o.random_hex)(3)}"
      let url = persistable_browser_url(match at(iv, "url") {
        None | Some(Null) => ""
        u => js_str(u)
      }).unwrap_or(o.url)
      let title = match at(iv, "title") {
        None | Some(Null) => ""
        t => js_str(t)
      }
      let popup = UserTab::make(key, url, title, true)
      self.by_key[key] = popup
      self.bind_target(popup, target_id)
      popup.remove_screen = self.add_screen(popup)
      self.arm_idle(popup)
      self.measure(popup, target_id)
      Some(popup.id)
    }
    None => None
  }
}

///|
pub fn UserTabs::target_info_changed(self : UserTabs, info : J) -> Bool {
  guard self.by_target.get(js_str(at(Some(info), "targetId"))) is Some(tab) else { return false }
  self.apply_info(tab, info, false)
  true
}

///|
pub fn UserTabs::target_destroyed(self : UserTabs, target_id : String) -> Bool {
  guard self.by_target.get(target_id) is Some(tab) else { return false }
  self.by_target.remove(target_id)
  (tab.cancel_idle)()
  if tab.discarded {
    return true
  }
  if tab.popup {
    tab.discarded = true
    tab.target_id = None
    self.by_key.remove(tab.key)
    (tab.remove_screen)()
    return true
  }
  tab.target_id = None
  tab.resume_target_id = None
  tab.hibernating = false
  tab.size_ = (0.0, 0.0)
  self.save()
  self.notify_screens()
  true
}

///|
pub fn UserTabs::refresh_titles(self : UserTabs, infos : Array[J]) -> Unit {
  for info in infos {
    match self.by_target.get(js_str(at(Some(info), "targetId"))) {
      Some(tab) => self.apply_info(tab, info, false)
      None => ()
    }
  }
}

///|
/// What the tabs are told to hand on (tabs.mbt `UserTabHooks`).
pub fn UserTabs::hooks(self : UserTabs) -> UserTabHooks {
  {
    target_created: info => self.target_created(info),
    target_info_changed: info => self.target_info_changed(info),
    target_destroyed: id => self.target_destroyed(id),
    refresh_titles: infos => self.refresh_titles(infos),
  }
}

///|
async fn UserTabs::ensure_live(self : UserTabs, tab : UserTab, override_url? : String) -> String {
  match (tab.target_id, override_url) {
    (Some(t), None) => return t
    _ => ()
  }
  match tab.waking {
    Some(w) => return w.wait()
    None => ()
  }
  let url = override_url.unwrap_or(tab.url)
  let me : Ref[Later[String]?] = Ref(None)
  let p = Later::start(self.o.clock, async fn() {
    let r = attempt(async fn() { self.wake(tab, url) })
    match (tab.waking, me.val) {
      (Some(w), Some(m)) if w.same(m) => tab.waking = None
      _ => ()
    }
    match r {
      Ok(t) => t
      Err(e) => raise e
    }
  })
  me.val = Some(p)
  tab.waking = Some(p)
  p.wait()
}

///|
async fn UserTabs::wake(self : UserTabs, tab : UserTab, url : String) -> String {
  let created = (self.o.create_target)(
    url,
    () => self.claiming = Some(tab),
    (target_id, tabs) => {
      match self.claiming {
        Some(c) if physical_equal(c, tab) => self.claiming = None
        _ => ()
      }
      if tab.target_id is None && !tab.discarded && !self.closed {
        self.bind_target(tab, target_id)
        (self.o.clock.spawn)(async fn() {
          tabs.measure_target(target_id, s => self.sized(tab, s), () => tab.size().0)
        })
      }
    },
  ) catch {
    e => {
      match self.claiming {
        Some(c) if physical_equal(c, tab) => self.claiming = None
        _ => ()
      }
      raise e
    }
  }
  let (target_id, tabs) = created
  if tab.discarded || self.closed {
    tabs.close_target(target_id) catch {
      _ => ()
    }
    raise UserTabs::not_found()
  }
  tabs.arrived(target_id)
  if !tab.popup {
    self.save()
  }
  self.notify_screens()
  target_id
}

///|
fn UserTabs::bind_target(self : UserTabs, tab : UserTab, target_id : String) -> Unit {
  match tab.target_id {
    Some(old) if old != target_id => self.by_target.remove(old)
    _ => ()
  }
  tab.target_id = Some(target_id)
  tab.resume_target_id = Some(target_id)
  self.by_target[target_id] = tab
}

///|
fn UserTabs::apply_info(self : UserTabs, tab : UserTab, info : J, force_notify : Bool) -> Unit {
  let iv = Some(info)
  let before_title = tab.title()
  let before_site = tab.site()
  let before_url = tab.url
  let mut persist = false
  let next_url = match at(iv, "url") {
    Some(Str(u)) => persistable_browser_url(@jsjson.sanitize_str(u))
    _ => None
  }
  match tab.pending_navigate_url {
    Some(p) if next_url != Some(p) => {
      if force_notify {
        self.notify_screens()
      }
      return
    }
    _ => ()
  }
  let info_title = match at(iv, "title") {
    None | Some(Null) => ""
    t => js_str(t)
  }
  match next_url {
    Some(n) if n != tab.url => {
      let old_site = site_of_browser_url(tab.url)
      let new_site = site_of_browser_url(n)
      tab.url = n
      if old_site != new_site && trim(info_title) == "" {
        tab.saved_title = ""
      }
      persist = true
    }
    _ => ()
  }
  let trimmed = trim(info_title)
  if trimmed != "" && trimmed != tab.saved_title {
    tab.saved_title = trimmed
    persist = true
  }
  if persist && !tab.popup {
    self.save()
  }
  if force_notify || tab.title() != before_title || tab.site() != before_site || tab.url != before_url {
    self.notify_screens()
  }
}

///|
fn UserTabs::arm_idle(self : UserTabs, tab : UserTab) -> Unit {
  (tab.cancel_idle)()
  if self.closed || tab.discarded || tab.target_id is None || tab.views > 0 {
    return
  }
  tab.cancel_idle = (self.o.clock.after)(self.idle_ms, async fn() {
    if self.closed || tab.discarded || tab.target_id is None || tab.views > 0 {
      return
    }
    (self.o.clock.spawn)(async fn() { self.sleep(tab) catch { _ => () } })
  })
}

///|
fn UserTabs::fresh_key(self : UserTabs) -> String {
  while true {
    let key = "u_\{(self.o.random_hex)(6)}"
    if !self.by_key.contains(key) {
      return key
    }
  }
  ""
}

///|
/// `/^u_[a-z0-9_-]{1,40}$/i`.
fn user_tab_key(id : String) -> Bool {
  if !id.has_prefix("u_") || id.length() < 3 || id.length() > 42 {
    return false
  }
  slice(id, 2).iter().all(c => is_ascii_alpha(c) || is_ascii_digit(c) || c == '_' || c == '-')
}

///|
async fn UserTabs::load(self : UserTabs) -> Unit {
  guard (self.o.files.read)(self.file.path) is Some(raw) else { return }
  if self.closed {
    return
  }
  let parsed = parse(raw) catch { _ => return }
  let items = match at(Some(parsed), "tabs") {
    Some(Arr(xs)) => xs
    _ => []
  }
  for item in items {
    let rec = Some(item)
    guard item is Obj(_) else { continue }
    guard at(rec, "id") is Some(Str(iu)) else { continue }
    let id = @jsjson.sanitize_str(iu)
    if !user_tab_key(id) || self.by_key.contains(id) {
      continue
    }
    let url = match at(rec, "url") {
      Some(Str(u)) if @jsjson.sanitize_str(u) == blank_page => Some(blank_page)
      Some(Str(u)) => persistable_browser_url(@jsjson.sanitize_str(u))
      _ => None
    }
    guard url is Some(url) else { continue }
    let title = match at(rec, "title") {
      Some(Str(t)) => slice(trim(@jsjson.sanitize_str(t)), 0, b=512)
      _ => ""
    }
    let resume = match at(rec, "targetId") {
      Some(Str(t)) if t.length() > 0 => Some(@jsjson.sanitize_str(t))
      _ => None
    }
    let tab = UserTab::make(id, url, title, false, resume?)
    self.by_key[id] = tab
    tab.remove_screen = self.add_screen(tab)
  }
}

///|
fn UserTabs::save(self : UserTabs) -> Unit {
  if self.closed {
    return
  }
  let tabs = []
  for _, tab in self.by_key {
    if tab.popup || tab.discarded {
      continue
    }
    let fs : Array[(String, J)] = [("id", js(tab.key)), ("url", js(tab.url)), ("title", js(tab.saved_title))]
    match tab.target_id {
      Some(t) => fs.push(("targetId", js(t)))
      None => ()
    }
    tabs.push(jo(fs))
  }
  ignore(self.file.write(stringify_pretty(jo([("tabs", ja(tabs))])) + "\n"))
}
