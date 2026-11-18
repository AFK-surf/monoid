// Each chat's own environment in the station's browser (src/browser/browsers.ts, "A chat's own environment"): one
// Chrome for the station (browser.mbt), and in it a browser context per chat, made over DevTools when the chat's agent
// first asks for the browser. A context is kept in memory only, as Chrome keeps one it is asked to make: no cookie of
// a chat is written to the station's disk, and none of another chat's reaches it (the gate on its agent's connection,
// gate.mbt). What a chat is signed in to comes from the vault (登录态): a sign-in granted is put into its context
// (signins.mbt) and taken out again when its grant ends, its cookies as they were then given back to the vault. The
// context goes when its chat is archived or deleted, and with Chrome when Chrome ends: a chat asking again then has a
// new one, its sign-ins still granted put in again. The default context is the station's own, for the tabs it opens
// itself (a login's page), no chat's. Where Farview is a chat's browser (farview.mbt `active_for`), its sign-ins, tabs
// and sign-in form are its Farview's instead.

///|
/// A sign-in taken out of a chat's context as its grant ended: its session, request, its cookies (and passkeys) as
/// they were then, as the vault keeps them (signins.mbt `kept_of`), and its workspace.
pub type TakenOut = (String, String, String, String?) -> Unit

///|
pub struct Browsers {
  /// The station's one Chrome; its default context the station's own.
  station : StationBrowser
  priv dir : String
  priv clock : Clock
  priv files : Files
  priv log : Log
  /// Each chat's context, by session, in the Chrome at `ws`.
  priv contexts : Map[String, String]
  priv mut ws : String?
  priv mut file : PrivateFile?
  /// Contexts being made, by session: asked again meanwhile, the same one.
  priv making : Map[String, Later[String]]
  /// The sign-ins put into each chat's context and not taken out yet, by session; their timers by request.
  priv signed_in : Map[String, Array[SignedIn]]
  priv timers : Map[String, () -> Unit]
  priv mut taken_out : TakenOut
  /// A chat's context made anew (Chrome started again): its sign-ins still granted are to be put in again.
  priv mut fresh : (String) -> Unit
  /// A chat's context taken up from the station process before: the passkeys of its sign-ins still granted are to be
  /// put in again.
  priv mut resumed : (String) -> Unit
  priv mut used_ : (String, String) -> Unit
  priv mut agent_act : (String, String, String) -> String?
  priv mut stopped : (String) -> Unit
  /// The chats' Farview, where the config makes it their browser.
  priv mut farview : FarviewTabs?
  priv mut closed : Bool
}

///|
/// The browsers, what <data>/browser/contexts.json kept taken up as they are made.
pub async fn Browsers::new(o : BrowserOptions) -> Browsers {
  let self_ref : Ref[Browsers?] = Ref(None)
  let station = StationBrowser::new({
    ..o,
    context_owner: Some(ctx => match self_ref.val {
      Some(b) => b.owner_of(ctx)
      None => None
    }),
    used_tab: Some((session, target) => match self_ref.val {
      Some(b) => b.used(session, target)
      None => ()
    }),
  })
  let b : Browsers = {
    station,
    dir: o.dir,
    clock: o.clock,
    files: o.files,
    log: o.log,
    contexts: {},
    ws: None,
    file: None,
    making: {},
    signed_in: {},
    timers: {},
    taken_out: (_, _, _, _) => (),
    fresh: _ => (),
    resumed: _ => (),
    used_: (_, _) => (),
    agent_act: (_, _, _) => None,
    stopped: _ => (),
    farview: None,
    closed: false,
  }
  self_ref.val = Some(b)
  let kept = match (o.files.read)(join(o.dir, "contexts.json")) {
    Some(t) => b.read_kept(t)
    None => None
  }
  match kept {
    Some((ws, contexts, signed_in)) => {
      b.ws = Some(ws)
      for c in contexts {
        b.contexts[c.0] = c.1
      }
      for s in signed_in {
        b.signed_in[s.0] = s.1
        for x in s.1 {
          b.arm(s.0, x)
        }
      }
    }
    None => ()
  }
  b
}

///|
fn Browsers::now(self : Browsers) -> Double {
  (self.clock.now)()
}

///|
/// A timer for sign-in `x` of `session`, at its end.
fn Browsers::arm(self : Browsers, session : String, x : SignedIn) -> Unit {
  match self.timers.get(x.request) {
    Some(stop) => stop()
    None => ()
  }
  let left = x.until * 1000.0 - self.now()
  self.timers[x.request] = (self.clock.after)(if left > 0.0 { left } else { 0.0 }, async fn() {
    if self.closed {
      return
    }
    self.timers.remove(x.request)
    self.due(session) catch {
      e =>
        (self.log.warn)(
          "browser",
          "a sign-in could not be taken out",
          fields([("session", js(session)), ("error", js(message_of(e)))]),
        )
    }
  })
}

///|
/// The chats' Farview (module.mbt): while its config is active, the chats' tabs and sign-ins are there.
pub fn Browsers::use_farview(self : Browsers, f : FarviewTabs) -> Unit {
  self.farview = Some(f)
}

///|
fn Browsers::fv(self : Browsers, session : String) -> FarviewTabs? {
  match self.farview {
    Some(f) if f.active_for(session) => Some(f)
    _ => None
  }
}

///|
/// Hears each sign-in taken out of a chat's context, with its cookies as they were.
pub fn Browsers::on_taken_out(self : Browsers, f : TakenOut) -> Unit {
  self.taken_out = f
}

///|
/// Hears each chat whose context was made anew, to put its sign-ins still granted in again.
pub fn Browsers::on_fresh(self : Browsers, f : (String) -> Unit) -> Unit {
  self.fresh = f
}

///|
/// Hears each chat whose context was taken up from the station process before, to put its passkeys in again.
pub fn Browsers::on_resumed(self : Browsers, f : (String) -> Unit) -> Unit {
  self.resumed = f
}

///|
/// A person or agent deliberately used a site in this chat's browser.
pub fn Browsers::on_used(self : Browsers, f : (String, String) -> Unit) -> Unit {
  self.used_ = f
}

///|
/// An agent operated a tab of its chat's browser over DevTools (`Gate`).
pub fn Browsers::on_agent_act(self : Browsers, f : (String, String, String) -> String?) -> Unit {
  self.agent_act = f
}

///|
/// `session`'s browser context was stopped or closed.
pub fn Browsers::on_stopped(self : Browsers, f : (String) -> Unit) -> Unit {
  self.stopped = f
}

///|
pub fn Browsers::used(self : Browsers, session : String, target : String, url? : String) -> Unit {
  let address = match url {
    Some(u) => Some(u)
    None =>
      match self.tabs(session).search_by(t => t.id == target) {
        Some(i) => Some(self.tabs(session)[i].url)
        None => None
      }
  }
  guard address is Some(a) && a != "" else { return }
  match url_of(a) {
    Some(u) => (self.used_)(session, lower(u.hostname()))
    None => ()
  }
}

///|
/// Extend the browser's removal timer without putting old cookies back over the current ones.
pub fn Browsers::extend_sign_in(self : Browsers, session : String, request : String, until : Double) -> Unit {
  guard self.signed_in.get(session) is Some(all) else { return }
  guard all.search_by(y => y.request == request) is Some(i) else { return }
  let x = all[i]
  if x.until <= self.now() / 1000.0 {
    return
  }
  x.until = until
  self.write()
  self.arm(session, x)
}

///|
/// Takes up the Chrome an earlier station process left running, with the chats' contexts in it.
pub async fn Browsers::resume(self : Browsers) -> Unit {
  self.station.resume()
  if self.station.status().running {
    self.passkeys_again()
  }
}

///|
/// Each chat with sign-ins in its context: their passkeys asked to be put in again (`on_resumed`).
pub fn Browsers::passkeys_again(self : Browsers) -> Unit {
  let sessions = []
  for s, _ in self.signed_in {
    sessions.push(s)
  }
  for s in sessions {
    if self.contexts.contains(s) {
      (self.resumed)(s)
    }
  }
}

///|
/// The passkeys of a sign-in still granted put into `session`'s chat's context again (its cookies are there still), if
/// the browser runs with it.
pub async fn Browsers::passkeys_in(self : Browsers, session : String, sites : Array[String], cookies : String) -> Unit {
  let passkeys = site_passkeys(state_of(cookies).passkeys, sites)
  match self.fv(session) {
    Some(f) => {
      // (its profile keeps them on disk: put in again only where its tab runs, no host started for it)
      if passkeys.length() > 0 && f.status(session).running {
        f.put_passkeys(session, passkeys)
      }
      return
    }
    None => ()
  }
  let ctx = self.contexts.get(session)
  guard ctx is Some(c) && passkeys.length() > 0 && self.station.status().running else { return }
  self.station.passkeys().put(c, passkeys)
}

///|
/// The session whose chat's context `ctx` is.
fn Browsers::owner_of(self : Browsers, ctx : String?) -> String? {
  guard ctx is Some(c) else { return None }
  for session, x in self.contexts {
    if x == c {
      return Some(session)
    }
  }
  None
}

///|
/// `session`'s chat's context in the browser (started if it is not running), made if it has none there.
pub async fn Browsers::context(self : Browsers, session : String) -> String {
  let status = self.station.endpoint()
  let ws = status.ws.unwrap_or("")
  if Some(ws) != self.ws {
    // Another Chrome than the one the contexts were made in: theirs went with it, the sign-ins in them too (those still
    // granted are put in again as each chat's context is made anew).
    self.ws = Some(ws)
    self.contexts.clear()
    for _, stop in self.timers {
      stop()
    }
    self.timers.clear()
    self.signed_in.clear()
    self.write()
  }
  match self.contexts.get(session) {
    Some(had) => return had
    None => ()
  }
  match self.making.get(session) {
    Some(m) => return m.wait()
    None => ()
  }
  let made = Later::start(self.clock, async fn() {
    let r = attempt(async fn() {
      let got = self.station.send(
        "Target.createBrowserContext",
        params=jo([("disposeOnDetach", jb(false))]),
      )
      guard at(Some(got), "browserContextId") is Some(Str(u)) && u.length() > 0 else {
        raise fail_("Chrome made no browser context.")
      }
      let ctx = @jsjson.text(u)
      self.contexts[session] = ctx
      self.write()
      (self.log.info)("browser", "a chat's own context made", fields([("session", js(session))]))
      (self.fresh)(session)
      ctx
    })
    self.making.remove(session)
    match r {
      Ok(c) => c
      Err(e) => raise e
    }
  })
  self.making[session] = made
  made.wait()
}

///|
/// The door's way in for `session` (proxy.mbt): the browser's DevTools and the gate's parts for its chat's context.
pub async fn Browsers::open(self : Browsers, session : String) -> (String, GateParts) {
  let context = self.context(session)
  self.due(session)
  guard self.station.status().ws is Some(ws) else { raise fail_("the browser has no DevTools address") }
  (
    ws,
    {
      context,
      context_of: id => self.station.context_of(id),
      opened: Some(id => ignore((self.agent_act)(session, id, "Target.createTarget"))),
      used: Some((id, url) => self.used(session, id, url?)),
      act: Some((id, m) => (self.agent_act)(session, id, m)),
    },
  )
}

///|
/// The door's view of the browsers.
pub fn Browsers::door(self : Browsers) -> DoorBrowsers {
  { open: async fn(session) { self.open(session) } }
}

///|
/// What `session`'s agent is told of the browser (its tool): it runs, its chat's context made.
pub async fn Browsers::endpoint(self : Browsers, session : String) -> BrowserStatus {
  ignore(self.context(session))
  self.due(session)
  self.status(session)
}

///|
/// The tabs of `session`'s chat.
pub fn Browsers::tabs(self : Browsers, session : String) -> Array[TabInfo] {
  match self.fv(session) {
    Some(f) => f.tabs(session).map(t => t.info)
    None => self.station.tabs().filter(t => t.session == Some(session))
  }
}

///|
/// The tabs of `session`'s chat as the tool lists them (a Farview tab with its agent's port).
pub fn Browsers::tabs_j(self : Browsers, session : String) -> Array[J] {
  match self.fv(session) {
    Some(f) => f.tabs(session).map(t => t.to_j())
    None => self.station.tabs().filter(t => t.session == Some(session)).map(t => t.to_j())
  }
}

///|
/// The sign-in form of `session`'s chat's tab `target_id`, on a connection of its own (signin_form.mbt); refused for a
/// tab not its chat's.
pub async fn Browsers::form(self : Browsers, session : String, target_id : String) -> SignInForm {
  if !self.tabs(session).iter().any(t => t.id == target_id) {
    raise fail_("no such tab in this chat's browser")
  }
  match self.fv(session) {
    Some(f) => return f.form(session, id=target_id)
    None => ()
  }
  let (cdp, tab) = self.station.attach(target_id)
  tab_form(cdp, tab, target_id)
}

///|
pub fn Browsers::status(self : Browsers, session : String) -> BrowserStatus {
  let s = self.station.status()
  if !s.running || !self.contexts.contains(session) {
    return BrowserStatus::off()
  }
  { ..s, tabs: Some(self.tabs(session).length()) }
}

///|
/// Closes `session`'s chat's context, its tabs with it; its sign-ins still granted are put in again when it asks.
pub async fn Browsers::stop(self : Browsers, session : String) -> Unit {
  (self.stopped)(session)
  self.dispose(session)
}

///|
/// `session`'s chat was archived or deleted: its context goes, its tabs and sign-ins with it; tabs it opened in the
/// station's own context (before chats had their own) are closed.
pub async fn Browsers::close_of(self : Browsers, session : String) -> Unit {
  (self.stopped)(session)
  self.dispose(session)
  for x in self.signed_in.get(session).unwrap_or([]) {
    match self.timers.get(x.request) {
      Some(stop) => stop()
      None => ()
    }
    self.timers.remove(x.request)
  }
  self.signed_in.remove(session)
  self.write()
  self.station.close_of(session)
}

///|
async fn Browsers::dispose(self : Browsers, session : String) -> Unit {
  guard self.contexts.get(session) is Some(ctx) else { return }
  self.contexts.remove(session)
  self.write()
  if self.station.status().running {
    self.station.passkeys().forget(ctx)
    ignore(self.station.send("Target.disposeBrowserContext", params=jo([("browserContextId", js(ctx))]))) catch {
      _ => ()
    }
  }
}

///|
/// The sign-in to `sites` in `session`'s chat's context (its Farview's profile where that is its browser), or in the
/// station's own (`station`), as the vault keeps it: its cookies, and its passkeys (a chat's only); the browser started
/// if it is not running.
pub async fn Browsers::cookies(self : Browsers, session : String, sites : Array[String], station : Bool) -> String {
  match self.fv(session) {
    Some(f) if !station => {
      let cookies = site_cookies(Some(ja(f.cookies(session))), sites)
      return kept_of({ cookies, passkeys: site_passkeys(f.passkeys(session), sites) })
    }
    _ => ()
  }
  let ctx = if station { None } else { Some(self.context(session)) }
  let got = self.station.send(
    "Storage.getCookies",
    params=match ctx {
      Some(c) => jo([("browserContextId", js(c))])
      None => Obj([])
    },
  )
  let passkeys = match ctx {
    None => []
    Some(c) => self.station.passkeys().read(c, sites~)
  }
  kept_of({ cookies: site_cookies(at(Some(got), "cookies"), sites), passkeys })
}

///|
/// A sign-in granted (`request`): its cookies and passkeys of `sites` put into `session`'s chat's context (the browser
/// started if it is not running), taken out again at `until` (unix seconds).
pub async fn Browsers::sign_in(
  self : Browsers,
  session : String,
  request : String,
  workspace : String?,
  sites : Array[String],
  cookies_kept : String,
  until : Double,
) -> Unit {
  let state = state_of(cookies_kept)
  let cookies = site_cookies(Some(ja(state.cookies)), sites)
  let passkeys = site_passkeys(state.passkeys, sites)
  let keep = (x : SignedIn) => {
    let others = self.signed_in.get(session).unwrap_or([]).filter(y => y.request != request)
    others.push(x)
    self.signed_in[session] = others
    self.write()
  }
  match self.fv(session) {
    Some(f) => {
      let x = SignedIn::new(request, workspace, sites, until)
      keep(x)
      f.put_cookies(session, cookies)
      f.put_passkeys(session, passkeys)
      (self.log.info)(
        "browser",
        "a sign-in put into a chat's Farview",
        fields([
          ("session", js(session)),
          ("request", js(request)),
          ("sites", jsa(sites)),
          ("cookies", ji(cookies.length())),
          ("passkeys", ji(passkeys.length())),
        ]),
      )
      self.arm(session, x)
      return
    }
    None => ()
  }
  let ctx = self.context(session)
  let x = SignedIn::new(request, workspace, sites, until)
  keep(x)
  if cookies.length() > 0 {
    ignore(
      self.station.send("Storage.setCookies", params=jo([("browserContextId", js(ctx)), ("cookies", ja(cookies))])),
    )
  }
  self.station.passkeys().put(ctx, passkeys)
  (self.log.info)(
    "browser",
    "a sign-in put into a chat's context",
    fields([
      ("session", js(session)),
      ("request", js(request)),
      ("sites", jsa(sites)),
      ("cookies", ji(cookies.length())),
      ("passkeys", ji(passkeys.length())),
    ]),
  )
  self.arm(session, x)
}

///|
/// Takes out of `session`'s chat's context the sign-ins whose grant ended, their cookies given back as they were.
async fn Browsers::due(self : Browsers, session : String) -> Unit {
  let now = self.now() / 1000.0
  let ended = self.signed_in.get(session).unwrap_or([]).filter(x => x.until <= now)
  if ended.length() == 0 {
    return
  }
  match self.fv(session) {
    Some(f) => {
      self.signed_in[session] = self.signed_in.get(session).unwrap_or([]).filter(x => x.until > now)
      self.write()
      for x in ended {
        let (cookies, passkeys) = f.take_out(session, x.sites)
        (self.log.info)(
          "browser",
          "a sign-in taken out of a chat's Farview as its grant ended",
          fields([("session", js(session)), ("request", js(x.request)), ("sites", jsa(x.sites))]),
        )
        if cookies.length() > 0 || passkeys.length() > 0 {
          (self.taken_out)(session, x.request, kept_of({ cookies, passkeys }), x.workspace)
        }
      }
      return
    }
    None => ()
  }
  // Its context is not there (the browser is closed, or not taken up yet): taken out when it next is. One gone with
  // its Chrome took its cookies with it: nothing to take out, nothing new to give back.
  let ctx = self.contexts.get(session)
  if !self.station.status().running {
    return
  }
  self.signed_in[session] = self.signed_in.get(session).unwrap_or([]).filter(x => x.until > now)
  self.write()
  guard ctx is Some(c) else { return }
  let got = self.station.send("Storage.getCookies", params=jo([("browserContextId", js(c))]))
  let read = at(Some(got), "cookies")
  let keys = self.station.passkeys()
  for x in ended {
    let cookies = site_cookies(read, x.sites)
    if cookies.length() > 0 {
      ignore(
        self.station.send(
          "Storage.setCookies",
          params=jo([("browserContextId", js(c)), ("cookies", ja(expired(cookies)))]),
        ),
      )
    }
    let passkeys = keys.take_out(c, x.sites)
    (self.log.info)(
      "browser",
      "a sign-in taken out of a chat's context as its grant ended",
      fields([("session", js(session)), ("request", js(x.request)), ("sites", jsa(x.sites))]),
    )
    if cookies.length() > 0 || passkeys.length() > 0 {
      (self.taken_out)(session, x.request, kept_of({ cookies, passkeys }), x.workspace)
    }
  }
}

///|
/// This station process ends: lets go of the browser, which goes on running with the chats' contexts for the next one
/// to take up.
pub async fn Browsers::close(self : Browsers) -> Unit {
  for _, stop in self.timers {
    stop()
  }
  self.timers.clear()
  self.station.close()
  self.closed = true
  // What the next station process takes up: written down before this one lets go.
  match self.file {
    Some(f) => f.written()
    None => ()
  }
}

///|
/// What contexts.json kept: Chrome's DevTools address, each chat's context, each chat's sign-ins.
fn Browsers::read_kept(self : Browsers, t : String) -> (String, Array[(String, String)], Array[(String, Array[SignedIn])])? {
  ignore(self)
  let v = parse(t) catch { _ => return None }
  let vv = Some(v)
  guard at(vv, "ws") is Some(Str(wu)) && truthy(at(vv, "contexts")) && is_object(at(vv, "contexts")) else {
    return None
  }
  let ordered = (o : J?) => match o {
    Some(Obj(_) as x) =>
      match js_object(entries_of(x)) {
        Obj(fs) => fs.map(f => (@jsjson.text(f.0), f.1))
        _ => []
      }
    _ => []
  }
  let contexts = ordered(at(vv, "contexts")).map(e => (e.0, js_str(Some(e.1))))
  let signed_in = ordered(at(vv, "signedIn")).map(e => (e.0, arr(Some(e.1)).map(SignedIn::of_j)))
  Some((@jsjson.text(wu), contexts, signed_in))
}

///|
/// What is kept in memory, written down (the latest only).
fn Browsers::write(self : Browsers) -> Unit {
  let file = match self.file {
    Some(f) => f
    None => {
      let f = PrivateFile::new(join(self.dir, "contexts.json"), self.files, self.clock)
      self.file = Some(f)
      f
    }
  }
  let contexts = []
  for s, c in self.contexts {
    contexts.push((s, js(c)))
  }
  let signed = []
  for s, all in self.signed_in {
    signed.push((s, ja(all.map(x => x.to_j()))))
  }
  let text_ = stringify_pretty(
      jo([("ws", js(self.ws.unwrap_or(""))), ("contexts", js_object(contexts)), ("signedIn", js_object(signed))]),
    ) +
    "\n"
  let w = file.write(text_)
  let log = self.log
  (self.clock.spawn)(async fn() {
    w.wait() catch {
      e =>
        (log.warn)("browser", "the chats' contexts could not be written down", fields([("error", js(message_of(e)))]))
    }
  })
}
