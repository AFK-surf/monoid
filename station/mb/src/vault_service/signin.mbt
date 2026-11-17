// Signing in to a site from a card (station/src/vault/signin.ts, 登录态): an agent that needs a site signed in to in
// its chat's browser asks once (`sign_in {site, reason}`): a sign-in the vault keeps for the site is asked for as any
// secret is; none, a card asks the person it works for to sign in. On the card their app asks their own password
// manager for the site's login, and what it gives comes here (`fill`): the station types it into the tab's sign-in
// form step by step. A step only a person can take gives them the tab's screen from the same card. The page left its
// sign-in, the agent is told and looks; signed in, it says so (`done`), and the sign-in is kept in the person's vault
// if they chose so on the card. What the app gave is held in memory only; the asks are kept in `signin_asks`.

///|
let open_statuses : Array[String] = ["pending", "filling", "code", "person", "left"]

///|
/// What an undecided ask lasts, and what the app's login is held for after its last use.
let signin_pending_secs : Double = 86400.0

///|
let held_ms : Double = 15.0 * 60000.0

///|
/// What a sign-in asks of the chat's browser and of the vault (signin.ts `SignInDeps`, beside the World's).
pub(all) struct SignInDeps {
  /// The chat's browser: its tabs (`{id, url}`), a tab's sign-in form (`FormAsks`), the form driven with what the app
  /// gave (`Driven`: `{state, why?}`), what of it was typed kept in `used`.
  tabs : (String) -> Array[(String, String)]
  look : async (String, String) -> Json
  drive : async (String, String, String, Json, Map[String, Unit]) -> Json
  /// The vault: a sign-in it keeps for a site this session may ask for; one held already; one asked for; one kept
  /// from the chat's browser with no card of its own (its request told to `made`).
  listed : (String, String) -> String? raise
  held : (String, String) -> String? raise
  use_ : async (String, String, String) -> String
  keep : async (String, String, String, (String) -> Unit, String?, String?) -> String
  /// The link that opens a tab's screen in the app, where the station has pages.
  screen_link : (String) -> String?
  /// The workspace a session's chat is in.
  workspace : (String) -> String?
  /// A new ask's id.
  id : (() -> String)?
}

///|
/// What an ask's app gave and what of it was typed; let go HELD_MS after its last use.
struct HeldLogin {
  mut values : Json
  used : Map[String, Unit]
  mut drop : () -> Unit
}

///|
/// A site as asked: its host, lower case, no scheme, path, port or `www.`.
pub fn site_of(given : String) -> String {
  let mut s = lower(trim(given))
  // ^[a-z][a-z0-9+.-]*://
  match s.find("://") {
    Some(i) if i > 0 => {
      let scheme = slice(s, 0, b=i)
      let ok = scheme.code_unit_at(0) >= 'a' && scheme.code_unit_at(0) <= 'z' && {
        let mut all = true
        for k in 1..<scheme.length() {
          let c = scheme.code_unit_at(k)
          if !((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '+' || c == '.' || c == '-') {
            all = false
          }
        }
        all
      }
      if ok {
        s = slice(s, i + 3)
      }
    }
    _ => ()
  }
  // [/?#].*$
  let mut cut = s.length()
  for k in 0..<s.length() {
    let c = s.code_unit_at(k)
    if c == '/' || c == '?' || c == '#' {
      cut = k
      break
    }
  }
  s = slice(s, 0, b=cut)
  // :\d+$
  match s.rev_find(":") {
    Some(i) if digits_int(slice(s, i + 1)) is Some(_) => s = slice(s, 0, b=i)
    _ => ()
  }
  if ends(s, ".") {
    s = slice(s, 0, b=s.length() - 1)
  }
  if starts(s, "www.") {
    s = slice(s, 4)
  }
  s
}

///|
fn on_site(host : String, site : String) -> Bool {
  host == site || ends(host, ".\{site}")
}

///|
/// A URL's host, lower case; "" where it is not a URL.
fn host_of_url(url : String) -> String {
  guard url.find("://") is Some(i) && i > 0 else { return "" }
  let rest = slice(url, i + 3)
  let mut end = rest.length()
  for k in 0..<rest.length() {
    let c = rest.code_unit_at(k)
    if c == '/' || c == '?' || c == '#' {
      end = k
      break
    }
  }
  let mut authority = slice(rest, 0, b=end)
  match authority.rev_find("@") {
    Some(at) => authority = slice(authority, at + 1)
    None => ()
  }
  if starts(authority, "[") {
    return match authority.find("]") {
      Some(j) => lower(slice(authority, 0, b=j + 1))
      None => ""
    }
  }
  match authority.rev_find(":") {
    Some(c) => authority = slice(authority, 0, b=c)
    None => ()
  }
  lower(authority)
}

///|
pub struct SignIns {
  w : World
  db : @vault_crypto.Db
  d : SignInDeps
  held : Map[String, HeldLogin]
  save_index : SigninSaveBuilder
}

///|
pub fn SignIns::new(w : World, db : @vault_crypto.Db, d : SignInDeps) -> SignIns raise {
  db.exec(signin_schema)
  let self_ref : Ref[SignIns?] = Ref(None)
  let save_index = SigninSaveBuilder::new(w, db, (pending, body) => match (self_ref.val, body) {
    (Some(s), Some(b)) => s.heard_body(b, pending.status, replay=true)
    _ => ()
  })
  let s = { w, db, d, held: Map([]), save_index }
  self_ref.val = Some(s)
  s
}

///|
/// A session's chat changed: one archived or gone ends its sign-ins under way.
pub fn SignIns::session_changed(self : SignIns, key : String) -> Unit raise {
  let ended = match (self.w.hub.store.get_session)(key) {
    None => true
    Some(row) => row.archived
  }
  if ended {
    for a in self.by_session(key) {
      if open_statuses.contains(gtext(Some(a), "status")) {
        self.end(a, "ended")
      }
    }
  }
}

///|
fn SignIns::secs(self : SignIns) -> Double {
  self.w.secs()
}

///|
pub fn SignIns::get(self : SignIns, id : String) -> Json? raise {
  match self.db.get("SELECT body FROM signin_asks WHERE id = ?", [js(id)]) {
    Some(row) => Some(parse(js_text(row.get(0))))
    None => None
  }
}

///|
fn SignIns::by_session(self : SignIns, session : String) -> Array[Json] raise {
  let marks = join(open_statuses.map(_ => "?"), ", ")
  self.db
  .all("SELECT body FROM signin_asks WHERE session = ? AND status IN (\{marks}) ORDER BY rowid", [
    js(session),
    ..open_statuses.map(js),
  ])
  .map(r => parse_or_null(js_text(r.get(0))))
}

///|
fn SignIns::save(self : SignIns, a : Json) -> Unit raise {
  ignore(
    self.db.run(
      "INSERT INTO signin_asks (id, session, owner, status, body) VALUES (?, ?, ?, ?, ?) ON CONFLICT (id) DO UPDATE SET status = excluded.status, body = excluded.body",
      [
        get(Some(a), "id").unwrap_or(Json::null()),
        get(Some(a), "session").unwrap_or(Json::null()),
        get(Some(a), "owner").unwrap_or(Json::null()),
        get(Some(a), "status").unwrap_or(Json::null()),
        js(stringify(a)),
      ],
    ),
  )
}

///|
fn SignIns::tell(self : SignIns, session : String, text : String) -> Unit {
  // (the session gone: nobody to tell)
  (self.w.hub.notify)(session, text) catch {
    _ => ()
  }
}

///|
/// What sign_in asks (signin.ts `ask`'s `a`).
pub(all) struct SignInAsk {
  site : String
  reason : String?
  tab : String?
  again : Bool
  reask : Bool
  done : Bool
  stuck : String?
  name : String?
  about : String?
}

///|
/// sign_in: the site signed in to in this session's chat's browser.
pub async fn SignIns::ask(self : SignIns, session : String, a : SignInAsk, signal? : Signal) -> String {
  throw_if_aborted(signal)
  let site = site_of(a.site)
  if site == "" || !contains(site, ".") {
    raise Refused("site is the site's host, e.g. github.com")
  }
  let mut open : Json? = None
  for x in self.by_session(session) {
    if gs(Some(x), "site") == Some(site) && open_statuses.contains(gtext(Some(x), "status")) {
      open = Some(x)
    }
  }
  if open is Some(o) &&
    gs(Some(o), "status") == Some("pending") &&
    gn(Some(o), "at").unwrap_or(@double.not_a_number) + signin_pending_secs < self.secs() {
    self.end(o, "expired")
    raise Refused("The sign-in to \{site} expired. Ask for a new sign-in if it is still needed.")
  }
  if a.done || a.stuck is Some(_) {
    guard open is Some(o) else {
      raise Refused("No sign-in to \{site} is under way in this chat: sign_in {site, reason} asks for one.")
    }
    return if a.done {
      let name = match a.name { Some(n) if trim(n) != "" => Some(trim(n)); _ => None }
      let about = match a.about { Some(n) if trim(n) != "" => Some(trim(n)); _ => None }
      self.done(o, name, about)
    } else {
      self.stuck(o, a.stuck.unwrap_or(""))
    }
  }
  // Asked again once it left its sign-in, the site asking for the password again: typed in again while it is held.
  let held = match open {
    Some(o) => self.held.get(gtext(Some(o), "id"))
    None => None
  }
  match (open, held) {
    (Some(o), Some(h)) if gs(Some(o), "status") == Some("left") => {
      h.used.clear()
      self.set(o, "filling")
      self.drive_later(o, h, "a sign-in could not be filled again")
      return "Filling \{site}'s sign-in form on tab \{gtext(Some(o), "tab")} again with what \{gtext(Some(o), "owner")}'s password manager gave; you are told here when the page has left it."
    }
    _ => ()
  }
  if open is Some(o) {
    let oid = gtext(Some(o), "id")
    let place = match card_place(self.w.hub.store, session, gn(Some(o), "thread").map(n => n.to_int()), gs(Some(o), "cardTs")) {
      None => {
        guard self.w.hub.prepare_card_posts is Some(prepare) && gn(Some(o), "thread") is Some(t) else {
          raise Refused("card lookup is not ready")
        }
        prepare([t.to_int()])
        throw_if_aborted(signal)
        match (self.w.hub.store.get_session)(session) {
          Some(row) if !row.archived => ()
          _ => raise Refused("This chat is archived or gone.")
        }
        guard self.get(oid) is Some(current) else { return "The sign-in to \{site} is no longer pending." }
        let status = gtext(Some(current), "status")
        if !open_statuses.contains(status) {
          return "The sign-in to \{site} (\{oid}) is \{status}."
        }
        if status == "left" {
          return self.waiting(current)
        }
        return self.ask(session, a, signal?)
      }
      Some(p) => p
    }
    let status = gtext(Some(o), "status")
    if a.reask && status != "left" {
      match place {
        Some((_, Other)) => raise Refused(card_occupied)
        Some((thread, NoCard)) => {
          let posted = self.post(session, thread, o, require_empty=true, signal?)
          let current = self.get(oid)
          let withdraw = () => match posted {
            Some(ts) => ignore((self.w.hub.store.withdraw_card)(session, thread.id, ts))
            None => ()
          }
          match current {
            None => {
              withdraw()
              return "The sign-in to \{site} is no longer pending."
            }
            Some(c) if !open_statuses.contains(gtext(Some(c), "status")) || gs(Some(c), "status") == Some("left") => {
              withdraw()
              return self.waiting(c)
            }
            Some(c) => {
              if posted is Some(ts) {
                set(c, "thread", ji(thread.id))
                set(c, "cardTs", js(ts))
                self.save_and_restate(c, false) catch {
                  e => {
                    // Posting happens before the request can be saved: no unassociated card left waiting.
                    withdraw()
                    raise e
                  }
                }
              }
              return self.waiting(c)
            }
          }
        }
        _ => ()
      }
    }
    match place {
      Some((_, state)) if state != Same && status != "left" =>
        return "The sign-in to \{site} (\{oid}) is \{status}, but its card is no longer pending. If it is still needed, call sign_in with site and reask: true."
      _ => ()
    }
    return self.waiting(o)
  }
  let reason = trim(a.reason.unwrap_or(""))
  if reason == "" {
    raise Refused("reason is required: why you need to be signed in, for the person, in the language they use")
  }
  if !a.again {
    match (self.d.held)(session, site) {
      Some(h) =>
        return "\{h} If the site still asks you to sign in there, its sign-in ran out: sign in with its passkey if it offers one (this chat's browser signs it itself), else call sign_in again with again: true."
      None => ()
    }
    match (self.d.listed)(session, site) {
      Some(item) =>
        return "\{(self.d.use_)(session, item, reason)} Granted, the sign-in is put into this chat's browser; if the site still asks you to sign in then, call sign_in again with again: true."
      None => ()
    }
  }
  guard (self.w.hub.store.starter)(session) is Some(owner) else {
    raise Refused("No one started this chat: there is nobody to sign in.")
  }
  let thread = match (self.w.hub.prepare_latest_threads, self.w.hub.store.latest_thread_if_ready) {
    (Some(prepare), Some(ready)) =>
      match ready(session) {
        None => {
          prepare([session])
          throw_if_aborted(signal)
          match (self.w.hub.store.get_session)(session) {
            Some(row) if !row.archived => ()
            _ => raise Refused("This chat is archived or gone.")
          }
          // A sign-in, a vault grant or another delivery may have arrived during preparation.
          return self.ask(session, a, signal?)
        }
        Some(t) => t
      }
    _ => (self.w.hub.store.latest_thread)(session)
  }
  guard thread is Some(thread) else { raise Refused("This session has no chat to ask in.") }
  let tabs = (self.d.tabs)(session)
  let tab = match a.tab {
    Some(t) => tabs.search_by(x => x.0 == t).map(i => tabs[i])
    None => {
      let on = tabs.filter(x => on_site(host_of_url(x.1), site))
      on.last()
    }
  }
  guard tab is Some((tab_id, tab_url)) else {
    match a.tab {
      Some(t) => raise Refused("This chat's browser has no tab \{t}.")
      None =>
        raise Refused(
          "This chat's browser has no tab on \{site}: open its sign-in page there first (the `browser` tool), then call sign_in.",
        )
    }
  }
  if !on_site(host_of_url(tab_url), site) {
    let h = host_of_url(tab_url)
    raise Refused("Tab \{tab_id} is on \{if h != "" { h } else { tab_url }}, not \{site}.")
  }
  let form = (self.d.look)(session, tab_id)
  throw_if_aborted(signal)
  match (self.w.hub.store.get_session)(session) {
    Some(row) if !row.archived => ()
    _ => raise Refused("This chat is archived or gone.")
  }
  // A concurrent call can have created the sign-in while this browser inspection was in flight.
  if (self.w.hub.store.starter)(session) != Some(owner) ||
    self.by_session(session).any(x => gs(Some(x), "site") == Some(site) && open_statuses.contains(gtext(Some(x), "status"))) {
    return self.ask(session, a, signal?)
  }
  if !truthy(get(Some(form), "username")) && !truthy(get(Some(form), "password")) && !truthy(get(Some(form), "code")) {
    raise Refused(
      "Tab \{tab_id} (\{tab_url}) shows no sign-in form: go to \{site}'s sign-in page there (its \"Sign in\" link), then call sign_in.",
    )
  }
  let id = match self.d.id {
    Some(f) => f()
    // (`g_${now.toString(36)}${Math.random().toString(36).slice(2, 8)}`)
    None => {
      let r = (self.w.random)(6)
      "g_" + base36((self.w.now)()) + String::from_array(Array::makei(6, i => digits36.code_unit_at(r[i].to_int() % 36).to_int().unsafe_to_char()))
    }
  }
  let x = obj([
    ("id", js(id)),
    ("session", js(session)),
    ("chat", js(thread_address(thread.channel, thread.thread_ts))),
    ("owner", js(owner)),
    ("site", js(site)),
    ("tab", js(tab_id)),
    ("reason", js(reason)),
    ("at", jn(self.secs())),
    ("status", js("pending")),
  ])
  self.save(x)
  match self.post(session, thread, x) {
    Some(posted) => {
      set(x, "thread", ji(thread.id))
      set(x, "cardTs", js(posted))
      self.save(x)
    }
    None => ()
  }
  "Asked \{owner} to sign in to \{site} (sign-in \{id}): the card in your chat signs in on tab \{tab_id} from their own password manager, the station typing it in; you never see it. \{undecided} You are told here when the page has left its sign-in: then look, and say so with sign_in {site: \"\{site}\", done: true, name: \"…\", about: \"…\"} (a name and about a person knows it by, as secret_save's), or stuck: \"what is left\"."
}

///|
/// What the agent is told of an ask still under way.
fn SignIns::waiting(_self : SignIns, x : Json) -> String {
  let site = gtext(Some(x), "site")
  let id = gtext(Some(x), "id")
  let tab = gtext(Some(x), "tab")
  match gtext(Some(x), "status") {
    "left" =>
      "The sign-in to \{site} (\{id}) left its sign-in page on tab \{tab}: look whether it is signed in, then sign_in {site: \"\{site}\", done: true, name: \"…\", about: \"…\"}, or stuck: \"what is left\"."
    "person" =>
      "The sign-in to \{site} (\{id}) is with \{gtext(Some(x), "owner")}, on tab \{tab}'s screen. \{undecided} You are told when they are done."
    _ => "The sign-in to \{site} (\{id}) waits for \{gtext(Some(x), "owner")} on its card. \{undecided}"
  }
}

///|
async fn SignIns::post(
  self : SignIns,
  session : String,
  thread : Thread,
  x : Json,
  require_empty? : Bool = false,
  signal? : Signal,
) -> String? {
  let stillfail = thread.surface == stillfail_surface
  let tab = gtext(Some(x), "tab")
  let link = (self.d.screen_link)(tab)
  let lines = ["要登录 \{gtext(Some(x), "site")}：\{gtext(Some(x), "reason")}"]
  if !stillfail {
    lines.push(
      match link {
        Some(l) => "请在 still.fail 中打开此画面登录，登录后在此回复：\n\{l}"
        None => "请在 still.fail 客户端里登录。"
      },
    )
  }
  let card = if stillfail {
    Some(
      obj([
        ("type", js("options")),
        (
          "options",
          jarr([
            obj([("label", js("在画面中登录")), ("detail", js("打开此网页，自行输入"))]),
            obj([("label", js("用密码管理器登录")), ("detail", js("由 station 填入并提交")), ("recommended", jb(true))]),
          ]),
        ),
        ("assignee", get(Some(x), "owner").unwrap_or(Json::null())),
        (
          "signin",
          obj([
            ("id", get(Some(x), "id").unwrap_or(Json::null())),
            ("site", get(Some(x), "site").unwrap_or(Json::null())),
            ("reason", get(Some(x), "reason").unwrap_or(Json::null())),
            ("screen", js("browser:\{tab}")),
          ]),
        ),
      ]),
    )
  } else {
    None
  }
  let xid = gtext(Some(x), "id")
  let needed = if require_empty {
    Some(fn() -> Bool raise {
      let current = self.get(xid)
      let chat = (self.w.hub.store.get_session)(session)
      match (current, chat) {
        (Some(c), Some(row)) =>
          open_statuses.contains(gtext(Some(c), "status")) && gs(Some(c), "status") != Some("left") && !row.archived
        _ => false
      }
    })
  } else {
    None
  }
  post_card(
    self.w,
    session,
    thread,
    join(lines, "\n\n"),
    card,
    if require_empty { Some(why => Refused(why)) } else { None },
    needed?,
    signal?,
  )
}

///|
/// The ask's card as it stands now: where it is, why a person is needed, whether it is kept.
fn outcome_of(x : Json) -> Json {
  let fs = [("status", get(Some(x), "status").unwrap_or(Json::null()))]
  for k in ["why", "said"] {
    if truthy(get(Some(x), k)) {
      fs.push((k, get(Some(x), k).unwrap()))
    }
  }
  if get(Some(x), "keep") is Some(k) {
    fs.push(("keep", k))
  }
  for k in ["save", "kept"] {
    if truthy(get(Some(x), k)) {
      fs.push((k, get(Some(x), k).unwrap()))
    }
  }
  obj(fs)
}

///|
/// The state saved with its durable card outcome; a closed card announced only after the write commits.
fn SignIns::save_and_restate(self : SignIns, x : Json, close : Bool) -> Unit raise {
  let session = gtext(Some(x), "session")
  match (gn(Some(x), "thread"), gs(Some(x), "cardTs"), self.w.card_outcomes) {
    (Some(t), Some(ts), Some(q)) => {
      (q.save)(
        obj([
          ("thread", jn(t)),
          ("ts", js(ts)),
          ("agent", js(session)),
          ("field", js("signin")),
          ("close", jb(close)),
          ("outcome", outcome_of(x)),
        ]),
        () => self.save(x),
      )
      return
    }
    _ => ()
  }
  self.save(x)
  match (gn(Some(x), "thread"), gs(Some(x), "cardTs")) {
    (Some(t), Some(ts)) => {
      let outcome = outcome_of(x)
      ignore(
        (self.w.hub.store.restate_card)(session, t.to_int(), ts, card => spread(card, [
          ("signin", spread(get(card, "signin"), [("outcome", outcome)])),
        ])),
      )
      if close {
        ignore((self.w.hub.store.withdraw_card)(session, t.to_int(), ts))
      }
    }
    _ => ()
  }
}

///|
fn SignIns::set(self : SignIns, x : Json, status : String, why? : String, close? : Bool = false) -> Unit raise {
  set(x, "status", js(status))
  match why {
    None => unset(x, "why")
    Some(w) => set(x, "why", js(w))
  }
  self.save_and_restate(x, close)
}

///|
/// Its card no longer waits on anyone: withdrawn, but while its sign-in's keeping waits for the app to approve it.
fn SignIns::end(self : SignIns, x : Json, status : String) -> Unit raise {
  let kept = match gs(Some(x), "kept") {
    Some(k) => k
    None => "pending"
  }
  let close = !(status == "done" && has(Some(x), "save") && kept == "pending")
  self.set(x, status, close~)
  self.forget(gtext(Some(x), "id"))
}

///|
/// The ask `id` as its person may answer it (in their workspace's station), or why not.
fn SignIns::theirs(self : SignIns, email : String, ws : String, id : String) -> Result[Json, String] raise {
  guard self.get(id) is Some(x) && (self.d.workspace)(gtext(Some(x), "session")) == Some(ws) else {
    return Err("no such sign-in")
  }
  if gs(Some(x), "owner") != Some(lower(email)) {
    return Err("only the person the chat's agent works for signs it in")
  }
  let status = gtext(Some(x), "status")
  if !open_statuses.contains(status) {
    return Err("the sign-in is \{status} already")
  }
  if status == "pending" && gn(Some(x), "at").unwrap_or(@double.not_a_number) + signin_pending_secs < self.secs() {
    self.end(x, "expired")
    return Err("the sign-in was let go (a day undecided)")
  }
  Ok(x)
}

///|
/// From the person's app: the login their password manager gave, typed into the tab's form; or, with a code alone,
/// the one the page asks. `keep`: kept in their vault once signed in. Why not, or None.
pub fn SignIns::fill(self : SignIns, email : String, ws : String, id : String, values : Json) -> String? raise {
  let x = match self.theirs(email, ws, id) {
    Err(why) => return Some(why)
    Ok(x) => x
  }
  if gs(Some(x), "status") == Some("filling") {
    return Some("the sign-in is being filled")
  }
  let given = []
  for k in ["username", "password", "code"] {
    match gs(Some(values), k) {
      Some(v) if v != "" && v.length() <= 4096 => given.push((k, js(v)))
      _ => ()
    }
  }
  if given.is_empty() {
    return Some("nothing to fill: give username, password or code")
  }
  let held = match self.held.get(id) {
    Some(h) => h
    None => { values: obj([]), used: Map([]), drop: () => () }
  }
  // (a code is typed once; a new one may be asked again)
  if given.any(g => g.0 == "code") {
    held.used.remove("code")
  }
  held.values = spread(Some(held.values), given)
  self.hold(id, held)
  if get(Some(values), "keep") is Some(True | False as k) {
    set(x, "keep", k)
  }
  self.set(x, "filling")
  self.drive_later(x, held, "a sign-in could not be filled")
  None
}

///|
/// The form driven in the background; what goes wrong gives the person the tab's screen.
fn SignIns::drive_later(self : SignIns, x : Json, held : HeldLogin, warning : String) -> Unit {
  let xid = gtext(Some(x), "id")
  ignore(
    @effect.runtime().fork(name="signin drive", async fn() {
      self.drive(x, held) catch {
        e => {
          (self.w.log)(
            "warn",
            "signin",
            warning,
            obj([("id", js(xid)), ("site", get(Some(x), "site").unwrap_or(Json::null())), ("error", js(message_of(e)))]),
          )
          (fn() raise {
            match self.get(xid) {
              Some(now) if gs(Some(now), "status") == Some("filling") => self.to_person(now, "stuck")
              _ => ()
            }
          })() catch {
            _ => ()
          }
        }
      }
    }),
  )
}

///|
/// `held` kept for ask `id`, let go HELD_MS from now.
fn SignIns::hold(self : SignIns, id : String, held : HeldLogin) -> Unit {
  (held.drop)()
  held.drop = (self.w.after)(held_ms, () => match self.held.get(id) {
    Some(h) if physical_equal(h, held) => self.held.remove(id)
    _ => ()
  })
  self.held[id] = held
}

///|
fn SignIns::forget(self : SignIns, id : String) -> Unit {
  match self.held.get(id) {
    Some(h) => (h.drop)()
    None => ()
  }
  self.held.remove(id)
}

///|
async fn SignIns::drive(self : SignIns, x : Json, held : HeldLogin) -> Unit {
  let xid = gtext(Some(x), "id")
  let driven = (self.d.drive)(
    gtext(Some(x), "session"),
    gtext(Some(x), "tab"),
    gtext(Some(x), "site"),
    held.values,
    held.used,
  )
  guard self.get(xid) is Some(now) && gs(Some(now), "status") == Some("filling") else { return }
  self.hold(xid, held)
  let fs = [("id", js(xid)), ("site", get(Some(x), "site").unwrap_or(Json::null())), ("state", get(Some(driven), "state").unwrap_or(Json::null()))]
  if truthy(get(Some(driven), "why")) {
    fs.push(("why", get(Some(driven), "why").unwrap()))
  }
  (self.w.log)("info", "signin", "a sign-in filled", obj(fs))
  match gtext(Some(driven), "state") {
    "code" => self.set(now, "code")
    "person" => self.to_person(now, gs(Some(driven), "why").unwrap_or("stuck"))
    _ =>
      self.left(
        now,
        "The sign-in form of \{gtext(Some(now), "site")} on tab \{gtext(Some(now), "tab")} was filled from \{gtext(Some(now), "owner")}'s password manager and sent, and the page has left its sign-in.",
      )
  }
}

///|
fn SignIns::to_person(self : SignIns, x : Json, why : String) -> Unit raise {
  self.set(x, "person", why~)
}

///|
fn SignIns::left(self : SignIns, x : Json, said : String) -> Unit raise {
  self.set(x, "left")
  let site = gtext(Some(x), "site")
  let keeps = if get(Some(x), "keep") != Some(Json::boolean(false)) {
    ", which keeps the sign-in in their vault as they chose on the card"
  } else {
    ""
  }
  self.tell(
    gtext(Some(x), "session"),
    "\{said} Look whether \{site} is signed in now (tab \{gtext(Some(x), "tab")}): then call sign_in {site: \"\{site}\", done: true, name: \"…\", about: \"…\"}\{keeps}; if a step is left that only they can take (a confirmation by mail, a new device's check), sign_in {site: \"\{site}\", stuck: \"what is left\"}, in their language.",
  )
}

///|
/// From the person's app: they sign in themselves on the tab's screen (`done` false), or say they did.
pub fn SignIns::self_(self : SignIns, email : String, ws : String, id : String, done : Bool) -> String? raise {
  let x = match self.theirs(email, ws, id) {
    Err(why) => return Some(why)
    Ok(x) => x
  }
  if !done {
    self.set(x, "person", why="self")
    return None
  }
  self.left(
    x,
    "\{gtext(Some(x), "owner")} says they signed in to \{gtext(Some(x), "site")} themselves on tab \{gtext(Some(x), "tab")}.",
  )
  None
}

///|
/// From the person's app: they will not sign in.
pub fn SignIns::deny(self : SignIns, email : String, ws : String, id : String) -> String? raise {
  let x = match self.theirs(email, ws, id) {
    Err(why) => return Some(why)
    Ok(x) => x
  }
  self.end(x, "denied")
  self.tell(
    gtext(Some(x), "session"),
    "\{gtext(Some(x), "owner")} chose not to sign in to \{gtext(Some(x), "site")} (\{gtext(Some(x), "id")}).",
  )
  None
}

///|
/// The agent looked: signed in. Kept in the vault where the person chose so, by the name and about the agent gave.
async fn SignIns::done(self : SignIns, x : Json, name : String?, about : String?) -> String {
  self.forget(gtext(Some(x), "id"))
  let site = gtext(Some(x), "site")
  if get(Some(x), "keep") == Some(Json::boolean(false)) {
    self.end(x, "done")
    return "Signed in to \{site}. \{gtext(Some(x), "owner")} chose not to keep it in their vault: it lasts as long as this chat's browser does."
  }
  let made : Ref[String?] = Ref(None)
  let said = (self.d.keep)(
    gtext(Some(x), "session"),
    site,
    "登录 \{site} 后保存，下次 agent 申请使用就不用再登录",
    r => made.val = Some(r),
    name,
    about,
  ) catch {
    e => {
      self.end(x, "done")
      return "Signed in to \{site}, but it could not be kept in the vault: \{message_of(e)}"
    }
  }
  if made.val is Some(m) {
    set(x, "save", js(m))
  }
  self.end(x, "done")
  "Signed in to \{site}. \{said}"
}

///|
fn SignIns::stuck(self : SignIns, x : Json, what : String) -> String raise {
  set(x, "said", js(slice(trim(what), 0, b=500)))
  self.to_person(x, "agent")
  "The card now gives \{gtext(Some(x), "owner")} tab \{gtext(Some(x), "tab")}'s screen, saying what is left. \{undecided} You are told when they are done."
}

///|
/// A request of the vault's decided (`Secrets::listen`): a sign-in's keeping said on its card.
pub fn SignIns::heard(self : SignIns, r : Json) -> Unit raise {
  let save = get(Some(r), "save")
  let status = gtext(Some(r), "status")
  if !truthy(save) || status == "pending" {
    return
  }
  let session = gtext(Some(r), "session")
  let id = gtext(Some(r), "id")
  match self.save_index.lookup(session, id) {
    Some(body) => {
      self.heard_body(body, status)
      self.save_index.forget(session, id, status)
    }
    None => if gs(save, "kind") == Some("browser") { self.save_index.wait(session, id, status) }
  }
}

///|
fn SignIns::heard_body(self : SignIns, body : String, status : String, replay? : Bool = false) -> Unit raise {
  let x = parse(body)
  if gs(Some(x), "kept") != Some(status) {
    set(x, "kept", js(status))
  } else if !replay {
    return
  }
  // A queued decision can have been saved just before the previous process stopped: its card told.
  self.save_and_restate(x, true)
}

///|
pub fn SignIns::close(self : SignIns) -> Unit {
  self.save_index.close()
}

// ── older sign-ins' saves indexed only when needed (signin-save-builder.ts) ──

///|
pub struct SigninSaveBuilder {
  w : World
  db : @vault_crypto.Db
  answer : (PendingSigninSave, String?) -> Unit raise
  mut conn : @sql.Db?
  mut current : String?
  mut last : String?
  mut closed : Bool
  mut previous_ready : Bool
  mut previous_waiting : Bool
  mut timer : (() -> Unit)?
  mut retry_ms : Double
}

///|
pub fn SigninSaveBuilder::new(w : World, db : @vault_crypto.Db, answer : (PendingSigninSave, String?) -> Unit raise) -> SigninSaveBuilder raise {
  install_signin_save_index(db)
  let b : SigninSaveBuilder = {
    w,
    db,
    answer,
    conn: None,
    current: None,
    last: None,
    closed: false,
    previous_ready: false,
    previous_waiting: false,
    timer: None,
    retry_ms: 250.0,
  }
  b.pump()
  b
}

///|
pub fn SigninSaveBuilder::lookup(self : SigninSaveBuilder, session : String, save : String) -> String? raise {
  signin_for_save(self.db, session, save)
}

///|
/// An already covered session cannot contain an older matching ask: no work for ordinary saves.
pub fn SigninSaveBuilder::wait(self : SigninSaveBuilder, session : String, save : String, status : String) -> Unit raise {
  if self.closed || signin_save_complete(self.db, session) {
    return
  }
  queue_signin_save(self.db, session, save, status)
  self.pump()
}

///|
pub fn SigninSaveBuilder::forget(self : SigninSaveBuilder, session : String, save : String, status : String) -> Unit raise {
  forget_signin_save(self.db, session, save, status~)
}

///|
fn SigninSaveBuilder::schedule(self : SigninSaveBuilder, ms : Double) -> Unit {
  if self.closed || self.timer is Some(_) {
    return
  }
  // timer: a retry after a failure, with a backoff (or the next session's turn)
  self.timer = Some(
    (self.w.after)(ms, () => {
      self.timer = None
      self.pump()
    }),
  )
}

///|
fn SigninSaveBuilder::let_conn_go(self : SigninSaveBuilder) -> Unit {
  match self.conn {
    Some(c) => c.close()
    None => ()
  }
  self.conn = None
}

///|
fn SigninSaveBuilder::pump(self : SigninSaveBuilder) -> Unit {
  if self.closed || self.current is Some(_) || self.timer is Some(_) {
    return
  }
  let pending = next_pending_signin_save(self.db, self.last) catch {
    e => {
      self.w.warn("signin", "an older sign-in decision could not be told", obj([("error", js(message_of(e)))]))
      return
    }
  }
  guard pending is Some(pending) else {
    self.let_conn_go()
    return
  }
  if !self.previous_ready {
    if self.previous_waiting {
      return
    }
    self.previous_waiting = true
    ignore(
      @effect.runtime().fork(name="signin save previous", async fn() {
        match self.w.previous.gone {
          Some(gone) =>
            gone() catch {
              e => {
                self.previous_waiting = false
                self.w.warn("signin", "the previous station did not finish", obj([("error", js(message_of(e)))]))
                self.schedule(self.retry_ms)
                return
              }
            }
          None => @effect.pause()
        }
        self.previous_ready = true
        self.previous_waiting = false
        self.pump()
      }),
    )
    return
  }
  self.last = Some(pending.session)
  let complete = signin_save_complete(self.db, pending.session) catch { _ => false }
  if complete {
    (fn() raise {
      (self.answer)(pending, self.lookup(pending.session, pending.save))
      // A newer decision that arrived while the answer was being told is not dropped.
      forget_signin_save(self.db, pending.session, pending.save, status=pending.status)
    })() catch {
      e => {
        self.w.warn("signin", "an older sign-in decision could not be told", obj([("error", js(message_of(e)))]))
        self.schedule(self.retry_ms)
        self.retry_ms = (self.retry_ms * 2.0).min(30000.0)
        return
      }
    }
    self.retry_ms = 250.0
    self.schedule(0.0)
    return
  }
  guard self.w.index_db is Some(open) else {
    // (left queued: no step without a connection of its own)
    self.w.warn("signin", "signin-save backfill requires a file-backed store", obj([]))
    return
  }
  let conn = match self.conn {
    Some(c) => c
    None => {
      let c = open() catch {
        e => {
          self.w.warn("signin", "the sign-in index worker could not start", obj([("error", js(message_of(e)))]))
          self.schedule(self.retry_ms)
          self.retry_ms = (self.retry_ms * 2.0).min(30000.0)
          return
        }
      }
      self.conn = Some(c)
      c
    }
  }
  self.current = Some(pending.session)
  let session = pending.session
  ignore(
    @effect.runtime().fork(name="signin save step", async fn() {
      // (one batch under the backfills' permit, as station/src/read/mb-reader.ts `MbBackfill` takes it)
      while !(self.w.backfill_take)() {
        (self.w.sleep)(backfill_pause_ms)
        if self.closed {
          return
        }
      }
      let ok = (fn() -> Bool raise {
        ignore(@signin.step(conn, session, limit=20))
        true
      })() catch {
        e => {
          self.w.warn("signin", "an older sign-in index batch stopped", obj([("error", js(message_of(e)))]))
          false
        }
      }
      (self.w.backfill_give)()
      if self.closed {
        return
      }
      self.current = None
      if ok {
        self.retry_ms = 250.0
        self.pump()
      } else {
        self.let_conn_go()
        let more = next_pending_signin_save(self.db, None) catch { _ => None }
        if more is Some(_) {
          self.schedule(self.retry_ms)
          self.retry_ms = (self.retry_ms * 2.0).min(30000.0)
        }
      }
    }),
  )
}

///|
pub fn SigninSaveBuilder::close(self : SigninSaveBuilder) -> Unit {
  if self.closed {
    return
  }
  self.closed = true
  match self.timer {
    Some(t) => t()
    None => ()
  }
  self.timer = None
  self.let_conn_go()
}

///|
let digits36 : String = "0123456789abcdefghijklmnopqrstuvwxyz"

///|
/// An integer as `n.toString(36)` writes it.
fn base36(n : Double) -> String {
  let mut v = n.floor()
  if v <= 0.0 {
    return "0"
  }
  let out : Array[Char] = []
  while v > 0.0 {
    let d = (v - (v / 36.0).floor() * 36.0).to_int()
    out.insert(0, digits36.code_unit_at(d).to_int().unsafe_to_char())
    v = (v / 36.0).floor()
  }
  String::from_array(out)
}
