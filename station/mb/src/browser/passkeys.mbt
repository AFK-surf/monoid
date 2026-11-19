// Passkeys in a chat's browser (src/browser/passkeys.ts, 登录态): each tab of a chat's context has an authenticator of
// Chrome's own (DevTools' WebAuthn domain, a virtual one: internal, with resident keys and the person verified,
// presence given without asking), so a site's "add a passkey" makes one there and a site's sign-in with a passkey is
// signed there, with no window. A context's passkeys are kept here by context, in memory only: each made in a tab is
// heard and kept, each tab made after has them all, and a sign-in of the vault puts its passkeys in and takes them out
// again, as its cookies. An authenticator lasts as long as the connection that made it.

///|
/// A passkey as the vault keeps it and DevTools takes it (WebAuthn.Credential): its id, the site it is for (relying
/// party), its private key (PKCS#8), the user handle, how many times it signed (all base64 but signCount).
pub(all) struct Passkey {
  credential_id : String
  rp_id : String
  private_key : String
  user_handle : String?
  sign_count : Double
}

///|
pub fn Passkey::to_j(self : Passkey) -> J {
  let fs : Array[(String, J)] = [
    ("credentialId", js(self.credential_id)),
    ("rpId", js(self.rp_id)),
    ("privateKey", js(self.private_key)),
  ]
  match self.user_handle {
    Some(h) => fs.push(("userHandle", js(h)))
    None => ()
  }
  fs.push(("signCount", jn(self.sign_count)))
  jo(fs)
}

///|
/// What DevTools says when a tab's page is in another environment than the one asked of (it navigated).
fn moved_words(why : String) -> Bool {
  why.contains("not been enabled") || why.contains("matching the ID")
}

///|
fn authenticator_options() -> J {
  jo([
    ("protocol", js("ctap2")),
    ("ctap2Version", js("ctap2_1")),
    ("transport", js("internal")),
    ("hasResidentKey", jb(true)),
    ("hasUserVerification", jb(true)),
    ("isUserVerified", jb(true)),
    ("automaticPresenceSimulation", jb(true)),
  ])
}

///|
/// A passkey of `read` (a DevTools credential) as kept; None when it is not one.
pub fn passkey_of(read : J?) -> Passkey? {
  guard read is Some(Obj(_) | Arr(_)) &&
    at(read, "credentialId") is Some(Str(_)) &&
    at(read, "rpId") is Some(Str(_)) &&
    at(read, "privateKey") is Some(Str(_)) else {
    return None
  }
  let user_handle = match at(read, "userHandle") {
    Some(Str(u)) if u.length() > 0 => Some(@jsjson.sanitize_str(u))
    _ => None
  }
  let count = at(read, "signCount")
  Some({
    credential_id: text(at(read, "credentialId")),
    rp_id: text(at(read, "rpId")),
    private_key: text(at(read, "privateKey")),
    user_handle,
    sign_count: if is_safe_integer(count) && js_num(count) >= 0.0 {
      js_num(count)
    } else {
      0.0
    },
  })
}

///|
/// The passkeys of `sites` (a relying party is a site's when it is the site or under it, as a cookie's domain).
pub fn site_passkeys(all : Array[Passkey], sites : Array[String]) -> Array[Passkey] {
  all.filter(p => of_sites(p.rp_id, sites))
}

///|
/// A tab with an authenticator: its context, its session on the station's connection, its authenticator ("" until it
/// has one).
priv struct AuthTab {
  ctx : String
  session : String?
  mut id : String
}

///|
/// The authenticators of the chats' tabs, on the station's connection to the browser.
pub struct Authenticators {
  priv cdp : Cdp
  priv chat : (String) -> Bool
  priv on_changed : ((String) -> Unit)?
  priv clock : Clock
  priv log : Log
  priv tabs : Map[String, AuthTab]
  /// Tabs being given one, by target id.
  priv making : Map[String, Later[Unit]]
  /// Each context's passkeys, by credential id.
  priv keys : Map[String, Map[String, Passkey]]
  priv mut unlisten : () -> Unit
  priv mut closed : Bool
}

///|
pub fn Authenticators::new(
  cdp : Cdp,
  chat : (String) -> Bool,
  on_changed? : (String) -> Unit,
  clock~ : Clock,
  log~ : Log,
) -> Authenticators {
  {
    cdp,
    chat,
    on_changed,
    clock,
    log,
    tabs: {},
    making: {},
    keys: {},
    unlisten: () => (),
    closed: false,
  }
}

///|
fn Authenticators::no_authenticator(self : Authenticators, e : Error) -> Unit {
  (self.log.warn)("browser", "a chat's tab has no authenticator", fields([("error", js(message_of(e)))]))
}

///|
/// Starts: every chat's tab there now, and each after, given an authenticator.
pub async fn Authenticators::start(self : Authenticators) -> Unit {
  self.unlisten = (self.cdp.on)(e => self.heard(e))
  let got = self.cdp.ask("Target.getTargets") catch {
    _ => jo([("targetInfos", ja([]))])
  }
  for info in arr(at(Some(got), "targetInfos")) {
    self.tab(Some(info))
  }
}

///|
pub fn Authenticators::close(self : Authenticators) -> Unit {
  self.closed = true
  (self.unlisten)()
  self.tabs.clear()
}

///|
fn Authenticators::heard(self : Authenticators, e : CdpEvent) -> Unit {
  let p = Some(e.params)
  match e.session_id {
    None => {
      if e.method == "Target.targetCreated" || e.method == "Target.targetInfoChanged" {
        self.tab(at(p, "targetInfo"))
      } else if e.method == "Target.targetDestroyed" {
        match at(p, "targetId") {
          Some(Str(u)) => self.tabs.remove(@jsjson.sanitize_str(u))
          _ => ()
        }
      }
      return
    }
    Some(session) => {
      let mut found : (String, AuthTab)? = None
      for id, t in self.tabs {
        if t.session == Some(session) {
          found = Some((id, t))
          break
        }
      }
      guard found is Some((target_id, tab)) else { return }
      if e.method == "Page.frameNavigated" && at_path(p, ["frame", "parentId"]) is None {
        (self.clock.spawn)(async fn() {
          self.authenticator(target_id) catch {
            err => self.no_authenticator(err)
          }
        })
        return
      }
      guard at(p, "authenticatorId") is Some(Str(a)) && @jsjson.sanitize_str(a) == tab.id else {
        return
      }
      // One made in the tab (a site's "add a passkey"), or one that signed (its count): kept for the context.
      if e.method == "WebAuthn.credentialAdded" ||
        e.method == "WebAuthn.credentialAsserted" ||
        e.method == "WebAuthn.credentialUpdated" {
        guard passkey_of(at(p, "credential")) is Some(pk) else { return }
        let keys = match self.keys.get(tab.ctx) {
          Some(k) => k
          None => {}
        }
        let had = keys.contains(pk.credential_id)
        keys[pk.credential_id] = pk
        self.keys[tab.ctx] = keys
        if !had {
          (self.log.info)("browser", "a passkey made in a chat's tab", fields([("rpId", js(pk.rp_id))]))
          let ctx = tab.ctx
          let but = tab.session
          (self.clock.spawn)(async fn() { self.everywhere(ctx, [pk], but~) })
        }
        match self.on_changed {
          Some(f) => f(tab.ctx)
          None => ()
        }
      }
    }
  }
}

///|
/// A page of a chat's context, not given one yet: given one, with the context's passkeys.
fn Authenticators::tab(self : Authenticators, info : J?) -> Unit {
  if self.closed || text(at(info, "type")) != "page" {
    return
  }
  guard at(info, "targetId") is Some(Str(t)) && at(info, "browserContextId") is Some(Str(c)) else {
    return
  }
  let target_id = @jsjson.sanitize_str(t)
  let ctx = @jsjson.sanitize_str(c)
  if self.tabs.contains(target_id) || self.making.contains(target_id) || !(self.chat)(ctx) {
    return
  }
  let made = Later::start(self.clock, async fn() {
    (async fn() {
      let attached = self.cdp.ask(
        "Target.attachToTarget",
        params=jo([("targetId", js(target_id)), ("flatten", jb(true))]),
      )
      let session = str_of(at(Some(attached), "sessionId"))
      // (its main frame's navigations heard: one may come into an environment of Chrome's other than the one the
      // authenticator was put into, 2026-11-01, a page Playwright opened, through the gate: given one there too)
      ignore(self.cdp.send("Page.enable", Obj([]), session))
      self.tabs[target_id] = { ctx, session, id: "" }
      self.authenticator(target_id)
    })() catch {
      e => self.no_authenticator(e)
    }
    self.making.remove(target_id)
  })
  self.making[target_id] = made
}

///|
/// Tab `target_id` given an authenticator in the environment its page is in now, with its context's passkeys; none
/// where it has one there (Chrome takes one internal authenticator an environment).
async fn Authenticators::authenticator(self : Authenticators, target_id : String) -> Unit {
  let mut tries = 1
  while true {
    guard self.tabs.get(target_id) is Some(tab) else { return }
    let r = attempt(async fn() {
      ignore(self.cdp.send("WebAuthn.enable", jo([("enableUI", jb(false))]), tab.session))
      let added = self.cdp.send(
        "WebAuthn.addVirtualAuthenticator",
        jo([("options", authenticator_options())]),
        tab.session,
      )
      let id = text(at(Some(added), "authenticatorId"))
      tab.id = id
      match self.keys.get(tab.ctx) {
        Some(keys) => for _, p in keys {
          self.add(tab.session, id, p)
        }
        None => ()
      }
    })
    match r {
      Ok(_) => return
      Err(e) => {
        let why = message_of(e)
        if why.contains("one internal authenticator") {
          return
        }
        if tries >= 3 || !moved_words(why) {
          raise e
        }
      }
    }
    tries += 1
  }
}

///|
async fn Authenticators::add(self : Authenticators, session : String?, id : String, p : Passkey) -> Unit {
  let credential : Array[(String, J)] = [
    ("credentialId", js(p.credential_id)),
    ("isResidentCredential", jb(true)),
    ("rpId", js(p.rp_id)),
    ("privateKey", js(p.private_key)),
    ("signCount", jn(p.sign_count)),
  ]
  match p.user_handle {
    Some(h) => credential.push(("userHandle", js(h)))
    None => ()
  }
  ignore(
    self.cdp.send(
      "WebAuthn.addCredential",
      jo([("authenticatorId", js(id)), ("credential", jo(credential))]),
      session,
    ),
  )
}

///|
async fn Authenticators::all_made(self : Authenticators) -> Unit {
  let waiting = []
  for _, m in self.making {
    waiting.push(m)
  }
  for m in waiting {
    m.wait() catch {
      _ => ()
    }
  }
}

///|
/// `keys` put into every tab of `ctx` (but `but`'s, which has them); a tab whose page moved to another environment
/// given an authenticator there, with all of the context's.
async fn Authenticators::everywhere(
  self : Authenticators,
  ctx : String,
  keys : Array[Passkey],
  but? : String?,
) -> Unit {
  self.all_made()
  let tabs = []
  for id, t in self.tabs {
    tabs.push((id, t))
  }
  for pair in tabs {
    let (target_id, t) = pair
    if t.ctx != ctx || t.id == "" {
      continue
    }
    match but {
      Some(b) => if t.session == b { continue }
      None => ()
    }
    let r = attempt(async fn() {
      for p in keys {
        self.add(t.session, t.id, p)
      }
    })
    match r {
      Ok(_) => ()
      Err(e) =>
        if !moved_words(message_of(e)) {
          (self.log.warn)("browser", "a passkey not put into a tab", fields([("error", js(message_of(e)))]))
        } else {
          self.authenticator(target_id) catch {
            err => self.no_authenticator(err)
          }
        }
    }
  }
}

///|
/// The passkeys of `sites` (or all, when `sites` is omitted) in `ctx`, as they are now (their counts read again).
pub async fn Authenticators::read(
  self : Authenticators,
  ctx : String,
  sites? : Array[String],
) -> Array[Passkey] {
  self.all_made()
  let keys = match self.keys.get(ctx) {
    Some(k) => k
    None => {}
  }
  let tabs = []
  for _, t in self.tabs {
    tabs.push(t)
  }
  for t in tabs {
    if t.ctx != ctx || t.id == "" {
      continue
    }
    let got = self.cdp.send("WebAuthn.getCredentials", jo([("authenticatorId", js(t.id))]), t.session) catch {
      _ => jo([("credentials", ja([]))])
    }
    for c in arr(at(Some(got), "credentials")) {
      guard passkey_of(Some(c)) is Some(p) else { continue }
      match keys.get(p.credential_id) {
        None => keys[p.credential_id] = p
        Some(had) => if p.sign_count >= had.sign_count { keys[p.credential_id] = p }
      }
    }
  }
  self.keys[ctx] = keys
  let all = []
  for _, p in keys {
    all.push(p)
  }
  match sites {
    None => all
    Some(s) => site_passkeys(all, s)
  }
}

///|
/// `keys` put into `ctx`: kept for it, in each of its tabs.
pub async fn Authenticators::put(self : Authenticators, ctx : String, keys : Array[Passkey]) -> Unit {
  if keys.length() == 0 {
    return
  }
  let held = match self.keys.get(ctx) {
    Some(k) => k
    None => {}
  }
  for p in keys {
    held[p.credential_id] = p
  }
  self.keys[ctx] = held
  self.everywhere(ctx, keys)
}

///|
/// The passkeys of `sites` taken out of `ctx` (each of its tabs, and what is kept for it): what they were.
pub async fn Authenticators::take_out(
  self : Authenticators,
  ctx : String,
  sites : Array[String],
) -> Array[Passkey] {
  let out = self.read(ctx, sites~)
  match self.keys.get(ctx) {
    Some(held) => for p in out {
      held.remove(p.credential_id)
    }
    None => ()
  }
  let tabs = []
  for _, t in self.tabs {
    tabs.push(t)
  }
  for t in tabs {
    if t.ctx != ctx || t.id == "" {
      continue
    }
    for p in out {
      ignore(
        self.cdp.send(
          "WebAuthn.removeCredential",
          jo([("authenticatorId", js(t.id)), ("credentialId", js(p.credential_id))]),
          t.session,
        ),
      ) catch {
        _ => ()
      }
    }
  }
  out
}

///|
/// Whether `ctx` has a passkey for relying party `rp_id` (a page's sign-in it can sign itself).
pub fn Authenticators::has(self : Authenticators, ctx : String, rp_id : String) -> Bool {
  let l = lower(rp_id)
  let rp = if l.has_suffix(".") { slice(l, 0, b=l.length() - 1) } else { l }
  match self.keys.get(ctx) {
    Some(keys) => {
      for _, p in keys {
        if lower(p.rp_id) == rp {
          return true
        }
      }
      false
    }
    None => false
  }
}

///|
/// A context gone (its chat's, archived, or Chrome's ended): its passkeys forgotten.
pub fn Authenticators::forget(self : Authenticators, ctx : String) -> Unit {
  self.keys.remove(ctx)
}
