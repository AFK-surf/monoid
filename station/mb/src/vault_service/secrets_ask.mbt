// A request to use, rename, delete or take back (station/src/vault/secrets.ts `ask`, `#said`, `#post`, `#postCard`,
// `reask`, `describe`, `described`, `describedPlain`, `remove`, `removed`, `removedPlain`, `cancel`): made from a
// session, its card posted in the session's chat for whoever decides it, decided from their app.

///|
/// A request's timeout as an agent asked it.
pub(all) struct Timeout {
  kind : String
  seconds : Double
}

///|
/// What secret_use asks (secrets.ts `ask`'s `a`).
pub(all) struct UseAsk_ {
  item : String
  mode : String?
  reason : String
  command : String?
  hosts : Array[String]?
  station : String?
  timeout : Json?
  person : String?
}

///|
fn timeout_bad(t : Json) -> Bool {
  let kind = gs(Some(t), "kind")
  let seconds = get(Some(t), "seconds")
  !(kind == Some("idle") || kind == Some("fixed")) ||
  !safe_int(seconds) ||
  gn(Some(t), "seconds").unwrap() < 60.0 ||
  gn(Some(t), "seconds").unwrap() > 30.0 * 86400.0 ||
  gn(Some(t), "seconds").unwrap() % 60.0 != 0.0
}

///|
/// secret_use: a request for `item` (its id or listed name) from `session`, its card posted; decided, the session is
/// told (`settle`).
pub async fn Secrets::ask(self : Secrets, session : String, a : UseAsk_) -> String {
  let (ws, lock) = self.place_of(session)
  let run_on = match a.station {
    Some(s) if s != "" => self.peer(s)
    _ => None
  }
  let wanted = lower(trim(a.item))
  let found = self.find_listing(session, wanted, a.person)
  // Named, the card is theirs to decide (a member of the vault it is in); else the chat starter if they are a member
  // of that vault (e.g. a shared workspace vault), falling back to the vault's owner.
  let decider = match a.person {
    Some(p) if trim(p) != "" => self.person_for(session, a.person)
    _ =>
      match found {
        Some(f) => {
          let starter = self.person_for(session, None)
          let starter_sub = match (starter, lock) {
            (Some(email), Some(l)) => member_of(l, email)
            _ => None
          }
          let vault = if f.vault != @vault_crypto.plain_id { self.vaults.vault(ws, f.vault) } else { None }
          match (starter, starter_sub, vault) {
            (Some(email), Some(sub), Some(v)) if members_of(v).contains(sub) => Some(email)
            _ => f.owner
          }
        }
        None => None
      }
  }
  guard found is Some(found) else {
    raise Refused("No secret named \{quoted(a.item)} may be asked for here: secret_list lists those that may.")
  }
  let listing = found.listing
  let plain = found.vault == @vault_crypto.plain_id
  let modes = strings_of(get(Some(listing), "modes"))
  let mode = match a.mode {
    Some(m) => m
    None => modes.get(0).unwrap_or("")
  }
  if !modes.contains(mode) {
    raise Refused("「\{gtext(Some(listing), "name")}」 is given only by \{join(modes, ", ")}.")
  }
  if trim(a.reason) == "" {
    raise Refused("reason is required: why you need it, for the person deciding")
  }
  if a.timeout is Some(t) && timeout_bad(t) {
    raise Refused("timeout must be idle or fixed, in whole minutes from 1 minute to 30 days")
  }
  let hosts = match a.hosts {
    Some(h) if h.length() > 0 => h
    _ => if hosted(mode) { strings_of(get(Some(listing), "hosts")) } else { [] }
  }
  if mode == "browser" && self.w.browsers is None {
    raise Refused("This station has no browser for a sign-in to go into.")
  }
  let thread = match self.latest_thread_ready(session) {
    None => {
      (self.w.hub.prepare_latest_threads.unwrap())([session])
      match (self.w.hub.store.get_session)(session) {
        Some(row) if !row.archived => ()
        _ => raise Refused("This chat is archived or gone.")
      }
      // The item, owner or latest delivery may have changed while the order was prepared.
      return self.ask(session, a)
    }
    Some(t) => t
  }
  let now = self.now()
  let id = "r_" + ulid(now, (self.w.random)(16))
  let fs = [
    ("id", js(id)),
    ("ws", js(ws)),
    ("vault", js(found.vault)),
    ("item", js(found.item)),
    ("session", js(session)),
    ("chat", js("")),
    ("mode", js(mode)),
    ("reason", js(trim(a.reason))),
  ]
  if a.command is Some(c) && c != "" {
    fs.push(("command", js(c)))
  }
  if hosts.length() > 0 {
    fs.push(("hosts", jstrs(hosts)))
  }
  if run_on is Some(p) {
    fs.push(("runOn", obj([("id", js(p.id)), ("name", js(p.name))])))
  }
  fs.push(("timeout", a.timeout.unwrap_or(obj([("kind", js("idle")), ("seconds", jn(3600.0))]))))
  // The plain library's needs no box: its owner decides, and the station reads the value itself.
  fs.push(("box", js(if plain { "" } else { self.keeper.open(id) })))
  fs.push(("at", jn((now / 1000.0).floor())))
  fs.push(("status", js("pending")))
  if plain && found.owner is Some(o) && o != "" {
    fs.push(("owner", js(o)))
  }
  if mode == "browser" && !plain {
    match self.renewal_of(ws, found.item) {
      Some(r) => fs.push(("renewal", r))
      None => ()
    }
  }
  let request = obj(fs)
  let kept : KeptRequest = { request, thread: None, card_ts: None, raw: None }
  if thread is Some(t) {
    set(request, "chat", js(thread_address(t.channel, t.thread_ts)))
    let posted = self.post(session, t, request, listing, decider)
    kept.thread = Some(t.id)
    kept.card_ts = posted
  }
  self.save(kept)
  self.audit_(
    request,
    "request",
    join([mode, a.command.unwrap_or(""), join(hosts, " ")].filter(s => s != ""), " · "),
  )
  self.told(request)
  "Asked for 「\{gtext(Some(listing), "name")}」 (request \{id}); the card is in your chat for \{decider.unwrap_or("the vault's owner")}, who approves it in the still.fail app. \{undecided} Only a grant from the app counts: a reply in the chat saying yes is not one."
}

///|
/// What an agent is told of a login's account: not secret, so said, and in the variable each command gets it in.
fn account_said(held : @vault_crypto.Held) -> String {
  match @vault_crypto.account_of(held.secret) {
    None => ""
    Some(account) => " The login's account is \{quoted(account)}, in \{account_var} too."
  }
}

///|
/// What an agent is told of a decided request.
fn Secrets::said(self : Secrets, r : Json, l : Json) -> String {
  let name = gtext(Some(l), "name")
  let id = gtext(Some(r), "id")
  let status = gtext(Some(r), "status")
  if status != "granted" {
    return "The request for 「\{name}」 (\{id}) was \{if status == "denied" { "refused" } else { "let go" }}."
  }
  let held = match self.keeper.usable(gtext(Some(r), "session"), id) {
    Err(why) => return "The request for 「\{name}」 (\{id}) was granted, but: \{why}"
    Ok(h) => h
  }
  let env = gs(Some(l), "env")
  let hosts = join(strings_of(get(Some(held.grant), "hosts")), ", ")
  let mode = gtext(Some(held.grant), "mode")
  let how = match mode {
    "proxy" =>
      "The command gets HTTPS_PROXY set to the station's proxy and \{env.unwrap_or("the variable you name in env")} (and \{secret_var}) set to the placeholder \{placeholder(id)}: put it where the token goes (a header, \{env.unwrap_or("GH_TOKEN")}); the proxy swaps in the value on HTTPS to \{hosts} only."
    "ssh" => "The command gets SSH_AUTH_SOCK for an agent holding the key (ssh, git over ssh use it)."
    "file" =>
      "The file is written out for each command alone (removed when it ends) and its path is in \{env.unwrap_or("the variable you name in env")} and \{secret_var} (e.g. kubectl --kubeconfig \"$\{secret_var}\"); its output comes back with the file's content hidden."
    _ =>
      "The command gets the value in \{env.unwrap_or("the variable you name in env")} and \{secret_var}; its output comes back with the value hidden."
  }
  let until = iso(match held.until {
    Some(u) => u
    None => gn(Some(held.grant), "exp").unwrap_or(0.0)
  })
  let timeout = get(Some(held.grant), "timeout")
  if mode == "browser" {
    let renewal = if gs(timeout, "kind") == Some("idle") {
      ", extended by \{js_text(get(timeout, "seconds"))} seconds when the site is used"
    } else {
      ""
    }
    return "Granted: the sign-in 「\{name}」 (grant \{id}) goes into this chat's browser (the `browser` tool): its cookies of \{hosts}, until \{until}\{renewal}, when they are taken out again. Open the site there; nothing is run with secret_run, and you never get the cookies themselves."
  }
  let scope = gtext(Some(held.grant), "scope")
  let lasts = if scope == "once" {
    "for one command"
  } else if truthy(timeout) {
    "\{if gs(timeout, "kind") == Some("idle") { "until idle for" } else { "for" }} \{js_text(get(timeout, "seconds"))} seconds (currently until \{until})"
  } else if scope == "chat" {
    "until this chat is archived (\{until} at the latest)"
  } else {
    "until \{until}"
  }
  let where_ = match get(Some(r), "runOn") {
    Some(Object(_) as on) =>
      " Its commands run on \{gtext(Some(on), "name")}, in this chat's directory there (where station_task runs); the value is sent there only for each command."
    _ => ""
  }
  let env_hint = if env is Some(e) && e != "" { "" } else { ", env: \"NAME\"" }
  "Granted: 「\{name}」, grant \{id}, \{lasts}. Run with secret_run {grant: \"\{id}\", command: \"…\"\{env_hint}}. \{how}\{account_said(held)}\{where_} You never get the value itself."
}

///|
fn replace_backticks(s : String) -> String {
  replace_all(s, "`", "'")
}

///|
/// The card for request `r` in the session's chat: the vault's owner decides it in the app.
async fn Secrets::post(
  self : Secrets,
  session : String,
  thread : Thread,
  r : Json,
  l : Json,
  owner : String?,
  require_empty? : Bool = false,
  signal? : Signal,
) -> String? {
  let mode = gtext(Some(r), "mode")
  let r_hosts = match ga(Some(r), "hosts") {
    Some(_) => strings_of(get(Some(r), "hosts"))
    None => strings_of(get(Some(l), "hosts"))
  }
  let how = how_words(mode, r_hosts)
  let stillfail = thread.surface == stillfail_surface
  let lines = ["申请使用「\{gtext(Some(l), "name")}」：\{gtext(Some(r), "reason")}"]
  if gs(Some(r), "command") is Some(c) && c != "" {
    lines.push("命令：`\{replace_backticks(c)}`")
  }
  lines.push("方式：\{how}")
  if get(Some(r), "runOn") is Some(Object(_) as on) {
    lines.push("运行在：\{gtext(Some(on), "name")}")
  }
  let timeout = get(Some(r), "timeout")
  if truthy(timeout) {
    let minutes = gn(timeout, "seconds").unwrap_or(@double.not_a_number) / 60.0
    lines.push(
      "申请时限：\{if gs(timeout, "kind") == Some("idle") { "闲置" } else { "固定" }} \{num_text(minutes)} 分钟",
    )
  }
  if !stillfail {
    lines.push("请在 still.fail 客户端的「密钥」中批准。")
  }
  let text = join(lines, "\n\n")
  // The scopes the item allows, the longest recommended.
  let lasts = self.lasts_of(r, l)
  let allowed = scopes.filter(s => @vault_crypto.allows(lasts, Some(js(s))))
  let card = if stillfail {
    let options = []
    for i, s in allowed {
      let (label, detail) = scope_words(s)
      let o = [("label", js(label)), ("detail", js(detail))]
      if i == allowed.length() - 1 {
        o.push(("recommended", jb(true)))
      }
      options.push(obj(o))
    }
    options.push(obj([("label", js("拒绝")), ("detail", js("通知 agent 已拒绝"))]))
    let vault = [
      ("request", get(Some(r), "id").unwrap_or(Json::null())),
      ("name", get(Some(l), "name").unwrap_or(Json::null())),
      ("reason", get(Some(r), "reason").unwrap_or(Json::null())),
    ]
    if gs(Some(r), "command") is Some(c) && c != "" {
      vault.push(("command", js(c)))
    }
    vault.push(("mode", js(mode)))
    vault.push(("hosts", if hosted(mode) { jstrs(r_hosts) } else { jarr([]) }))
    if get(Some(r), "runOn") is Some(Object(_) as on) {
      vault.push(("station", get(Some(on), "name").unwrap_or(Json::null())))
    }
    if truthy(timeout) {
      vault.push(("timeout", timeout.unwrap()))
    }
    let fs = [("type", js("options")), ("options", jarr(options))]
    if owner is Some(o) && o != "" {
      fs.push(("assignee", js(lower(o))))
    }
    // The request as the app draws it; its outcome added once decided (`settle`).
    fs.push(("vault", obj(vault)))
    Some(obj(fs))
  } else {
    None
  }
  self.post_card(session, thread, text, card, require_empty, Some(r), signal?)
}

///|
/// A request's post in the session's chat, with its card where the chat shows cards; the card's ts, if it has one.
async fn Secrets::post_card(
  self : Secrets,
  session : String,
  thread : Thread,
  text : String,
  card : Json?,
  require_empty : Bool,
  request : Json?,
  signal? : Signal,
) -> String? {
  throw_if_aborted(signal)
  let posted = (self.w.hub.post)(thread.connect, thread.channel, thread.thread_ts, text)
  let needed = match request {
    Some(r) =>
      Some(fn() -> Bool raise {
        match self.kept(gtext(Some(r), "ws"), gtext(Some(r), "id")) {
          Some(k) =>
            gs(Some(k.request), "status") == Some("pending") && self.request_live(k.request, self.secs())
          None => false
        }
      })
    None => None
  }
  // A non-card surface has already delivered the message; finish recording it even if the caller leaves.
  record_posted_card(
    self.w,
    session,
    thread,
    text,
    card,
    posted,
    if require_empty { Some(why => Refused(why)) } else { None },
    needed?,
    signal?=if card is None { None } else { signal },
  )
}

///|
/// The same pending request's card posted again, without reading or showing a secret again. A message can end a
/// card's wait without deciding the request; a later, unrelated card is never displaced here.
pub async fn Secrets::reask(self : Secrets, session : String, id : String, signal? : Signal) -> String {
  throw_if_aborted(signal)
  let (ws, _) = self.place_of(session)
  let kept = match self.kept(ws, id) {
    Some(k) if gs(Some(k.request), "session") == Some(session) => k
    _ => raise Refused("No such request in this chat.")
  }
  let r = kept.request
  let status = gtext(Some(r), "status")
  if status != "pending" {
    raise Refused("Request \{id} is no longer pending (\{status}).")
  }
  if !self.request_live(r, self.secs()) {
    if !self.settle(r, "expired") {
      raise Refused("Request \{id} changed while it was checked; try again.")
    }
    raise Refused("Request \{id} is no longer pending (expired).")
  }
  let place = match card_place(self.w.hub.store, session, kept.thread, kept.card_ts) {
    None => {
      guard self.w.hub.prepare_card_posts is Some(prepare) && kept.thread is Some(t) else {
        raise Refused("card lookup is not ready")
      }
      prepare([t])
      throw_if_aborted(signal)
      return self.reask(session, id, signal?)
    }
    Some(p) => p
  }
  guard place is Some((thread, state)) else {
    raise Refused("This request has no card in the chat to ask again.")
  }
  if state == Same {
    return "The card for request \{id} is already pending in the chat."
  }
  if state == Other {
    raise Refused(card_occupied)
  }
  let save = truthy(get(Some(r), "save"))
  let listing = if save { None } else { self.listing_of(r) }
  if !save && listing is None {
    raise Refused("The secret is no longer available to request.")
  }
  let posted = if save {
    self.post_save(session, thread, r, require_empty=true, signal?)
  } else if truthy(get(Some(r), "describe")) {
    self.post_describe(session, thread, r, self.decider_of(r), require_empty=true, signal?)
  } else if truthy(get(Some(r), "remove")) {
    self.post_remove(session, thread, r, self.decider_of(r), require_empty=true, signal?)
  } else {
    self.post(session, thread, r, listing.unwrap(), gs(Some(r), "owner"), require_empty=true, signal?)
  }
  match self.kept(ws, id) {
    Some(c) if gs(Some(c.request), "status") == Some("pending") && !self.request_live(c.request, self.secs()) =>
      ignore(self.settle(c.request, "expired"))
    _ => ()
  }
  // The original request may have been decided while the new message was being posted.
  let withdraw = () => match posted {
    Some(ts) => ignore((self.w.hub.store.withdraw_card)(session, thread.id, ts))
    None => ()
  }
  let latest = match self.kept(ws, id) {
    Some(l) if gs(Some(l.request), "status") == Some("pending") => l
    _ => {
      withdraw()
      raise Refused("Request \{id} is no longer pending.")
    }
  }
  if !self.request_live(latest.request, self.secs()) {
    withdraw()
    raise Refused("Request \{id} changed while it was checked; try again.")
  }
  (fn() raise {
    // The decision and the card location can change on another connection after the last read above.
    let changed = self.db.run(
      "UPDATE vault_requests SET thread=?,card_ts=?\n        WHERE ws=? AND id=? AND status='pending' AND body=? AND thread IS ? AND card_ts IS ?",
      [
        ji(thread.id),
        opt_text(posted),
        js(ws),
        js(id),
        js(latest.raw.unwrap_or("")),
        opt_int(latest.thread),
        opt_text(latest.card_ts),
      ],
    )
    if changed == 0 {
      raise Refused("Request \{id} changed while the card was posted; try again.")
    }
    self.track_saved(latest)
  })() catch {
    e => {
      withdraw()
      raise e
    }
  }
  "The card for request \{id} is in the chat again. It is the same request; no secret was read again. \{undecided}"
}

// ── an item renamed, or said what it is (secret_describe 改名和说明) ──

///|
/// secret_describe: a request from `session` to give item `item` a new name or about, its card posted for the item's
/// owner (or the person named). It grants nothing.
pub async fn Secrets::describe(
  self : Secrets,
  session : String,
  item : String,
  name? : String,
  about? : String,
  reason : String,
  person? : String,
) -> String {
  let (ws, _) = self.place_of(session)
  guard self.find_listing(session, lower(trim(item)), person) is Some(found) else {
    raise Refused("No secret named \{quoted(item)} is listed here: secret_list lists those that are.")
  }
  let decider = match person {
    Some(p) if trim(p) != "" => self.person_for(session, person)
    _ => found.owner
  }
  let listing = found.listing
  let was_name = gtext(Some(listing), "name")
  let was_about = gtext(Some(listing), "about")
  let new_name = trim(name.unwrap_or(was_name))
  let new_about = trim(about.unwrap_or(was_about))
  if new_name == "" || new_name.length() > 200 {
    raise Refused("name is at most 200 characters, and not empty: what the person and agents will know it by")
  }
  if new_about.length() > @vault_crypto.about_most {
    raise Refused("about is at most \{@vault_crypto.about_most} characters")
  }
  if new_name == was_name && new_about == was_about {
    raise Refused("「\{was_name}」 is named and described so already: nothing to change.")
  }
  if trim(reason) == "" {
    raise Refused("reason is required: why, for the person deciding")
  }
  let thread = match self.latest_thread_ready(session) {
    None => {
      (self.w.hub.prepare_latest_threads.unwrap())([session])
      match (self.w.hub.store.get_session)(session) {
        Some(row) if !row.archived => ()
        _ => raise Refused("This chat is archived or gone.")
      }
      return self.describe(session, item, name?, about?, reason, person?)
    }
    Some(t) => t
  }
  let plain = found.vault == @vault_crypto.plain_id
  let now = self.now()
  let id = "r_" + ulid(now, (self.w.random)(16))
  let fs = [
    ("id", js(id)),
    ("ws", js(ws)),
    ("vault", js(found.vault)),
    ("item", js(found.item)),
    ("session", js(session)),
    ("chat", js("")),
    ("mode", get(Some(listing), "modes").map(m => match m { Array(a) => a.get(0).unwrap_or(Json::null()); _ => Json::null() }).unwrap_or(Json::null())),
    ("reason", js(trim(reason))),
    ("box", js("")),
    ("at", jn((now / 1000.0).floor())),
    ("status", js("pending")),
  ]
  if plain && found.owner is Some(o) && o != "" {
    fs.push(("owner", js(o)))
  }
  fs.push(
    (
      "describe",
      obj([
        ("name", js(new_name)),
        ("about", js(new_about)),
        ("was", obj([("name", js(was_name)), ("about", js(was_about))])),
      ]),
    ),
  )
  let request = obj(fs)
  let kept : KeptRequest = { request, thread: None, card_ts: None, raw: None }
  if thread is Some(t) {
    set(request, "chat", js(thread_address(t.channel, t.thread_ts)))
    kept.card_ts = self.post_describe(session, t, request, decider)
    kept.thread = Some(t.id)
  }
  self.save(kept)
  self.audit_(request, "describe-request", if new_name == was_name { "about" } else { "name \{new_name}" })
  self.told(request)
  self.said_describe(request) +
  (match decider {
    Some(d) if d != "" => " It is for \{d} to decide."
    _ => ""
  })
}

///|
/// Who decides request `r` as its card says: the plain library's item's owner, else its vault's owner.
fn Secrets::decider_of(self : Secrets, r : Json) -> String? raise {
  match gs(Some(r), "owner") {
    Some(o) if o != "" => return Some(o)
    _ => ()
  }
  let ws = gtext(Some(r), "ws")
  match ((self.w.lock)(Some(ws)), self.vaults.vault(ws, gtext(Some(r), "vault"))) {
    (Some(lock), Some(vault)) => lock.email_of(gtext(Some(vault), "owner")).map(lower)
    _ => None
  }
}

///|
/// The card of a request to rename an item or say what it is.
async fn Secrets::post_describe(
  self : Secrets,
  session : String,
  thread : Thread,
  r : Json,
  decider : String?,
  require_empty? : Bool = false,
  signal? : Signal,
) -> String? {
  let d = get(Some(r), "describe")
  let name = gtext(d, "name")
  let about = gtext(d, "about")
  let was_name = gtext(get(d, "was"), "name")
  let was_about = gtext(get(d, "was"), "about")
  let stillfail = thread.surface == stillfail_surface
  let what = if name != was_name && about != was_about {
    "名称与说明"
  } else if name != was_name {
    "名称"
  } else {
    "说明"
  }
  let lines = ["申请修改密钥「\{was_name}」的\{what}：\{gtext(Some(r), "reason")}"]
  if name != was_name {
    lines.push("名称改为：\{name}")
  }
  if about != was_about {
    lines.push(if about == "" { "清除说明" } else { "说明改为：\{about}" })
  }
  if !stillfail {
    lines.push("请在 still.fail 客户端的「密钥」中批准。")
  }
  let card = if stillfail {
    let fs = [
      ("type", js("options")),
      (
        "options",
        jarr([
          obj([("label", js("确认修改")), ("detail", js("按以上内容修改名称与说明")), ("recommended", jb(true))]),
          obj([("label", js("保持不变")), ("detail", js("不作修改，通知 agent"))]),
        ]),
      ),
    ]
    if decider is Some(x) && x != "" {
      fs.push(("assignee", js(lower(x))))
    }
    fs.push(
      (
        "vault",
        obj([
          ("request", get(Some(r), "id").unwrap_or(Json::null())),
          ("name", js(was_name)),
          ("reason", get(Some(r), "reason").unwrap_or(Json::null())),
          ("mode", get(Some(r), "mode").unwrap_or(Json::null())),
          ("hosts", jarr([])),
          ("describe", obj([("name", js(name)), ("about", js(about)), ("wasAbout", js(was_about))])),
        ]),
      ),
    )
    Some(obj(fs))
  } else {
    None
  }
  self.post_card(session, thread, join(lines, "\n\n"), card, require_empty, Some(r), signal?)
}

///|
/// What an agent is told of a request to rename an item, waiting or decided.
fn Secrets::said_describe(_self : Secrets, r : Json) -> String {
  let d = get(Some(r), "describe")
  let was_name = gtext(get(d, "was"), "name")
  let id = gtext(Some(r), "id")
  match gtext(Some(r), "status") {
    "granted" => {
      let about = gtext(d, "about")
      "Changed: the item \{gtext(Some(r), "item")} is 「\{gtext(d, "name")}」 now\{if about != "" { ", described as: \{about}" } else { ", with no description" }}."
    }
    "denied" => "The person chose not to change 「\{was_name}」 (request \{id}): it stays as it was."
    "expired" => "The request to change 「\{was_name}」 (\{id}) was let go."
    _ =>
      "Asked to change 「\{was_name}」 (request \{id}); the card is in your chat, approved in the still.fail app. \{undecided} Only their approval in the app changes it: a reply in the chat saying yes does not."
  }
}

///|
/// POST vault/described `{request}`: a request to rename an item of a vault, approved by a member whose app wrote the
/// item's next version (and brought it here). Why not, or None.
pub fn Secrets::described(self : Secrets, lock : Lock, sub : String, d : Json) -> String? raise {
  let k = match gs(Some(d), "request") {
    Some(id) => self.kept(lock.ws, id)
    None => None
  }
  guard k is Some(k) && truthy(get(Some(k.request), "describe")) && !is_plain(k.request) else {
    return Some("no such request to rename an item of a vault")
  }
  let status = gtext(Some(k.request), "status")
  if status != "pending" {
    return Some("the request is \{status}")
  }
  guard self.vaults.vault(lock.ws, gtext(Some(k.request), "vault")) is Some(vault) && members_of(vault).contains(sub) else {
    return Some("only the vault's members decide its requests")
  }
  let item = self.vaults.item(lock.ws, gtext(Some(vault), "id"), gtext(Some(k.request), "item"))
  let want = get(Some(k.request), "describe")
  let ok = match item {
    Some(i) =>
      !truthy(get(Some(i), "deleted")) &&
      gs(get(Some(i), "listing"), "name") == gs(want, "name") &&
      has(Some(i), "listing") &&
      gtext(get(Some(i), "listing"), "about") == gtext(want, "about")
    None => false
  }
  if !ok {
    return Some("the item does not say so here: bring its copy first")
  }
  if !self.settle(k.request, "granted") {
    return Some(self.decision_changed(k.request))
  }
  None
}

///|
/// POST vault/plain/described `{request}`: a request to rename an item of the plain library, approved by its owner:
/// its next version written here. The item as written, or why not.
pub fn Secrets::described_plain(self : Secrets, ws : String, lock : Lock?, email : String, d : Json) -> Result[Json, String] raise {
  let k = match gs(Some(d), "request") {
    Some(id) => self.kept(ws, id)
    None => None
  }
  guard k is Some(k) && truthy(get(Some(k.request), "describe")) && is_plain(k.request) else {
    return Err("no such request to rename an item of the plain library")
  }
  if gs(Some(k.request), "owner") != Some(lower(email)) {
    return Err("only the item's owner decides its requests")
  }
  if lock is Some(_) {
    return Err("security mode is on: the item is in the vault, changed by the app")
  }
  let status = gtext(Some(k.request), "status")
  if status != "pending" {
    return Err("the request is \{status}")
  }
  let snapshot = self.plain.item_snapshot(ws, gtext(Some(k.request), "item"))
  guard snapshot is Some((prev, prev_body)) &&
    !truthy(get(Some(prev), "deleted")) &&
    has(Some(prev), "listing") else {
    return Err("the item is gone, or not one agents may ask for")
  }
  let want = get(Some(k.request), "describe")
  let listing = without(get(Some(prev), "listing").unwrap(), "about")
  set(listing, "name", get(want, "name").unwrap_or(Json::null()))
  if gtext(want, "about") != "" {
    set(listing, "about", get(want, "about").unwrap())
  }
  let next = spread(Some(prev), [
    ("version", jn(gn(Some(prev), "version").unwrap_or(@double.not_a_number) + 1.0)),
    ("name", get(want, "name").unwrap_or(Json::null())),
    ("notes", get(want, "about").unwrap_or(Json::null())),
    ("listing", listing),
    ("at", jn(self.secs())),
  ])
  match @vault_crypto.plain_ok(Some(prev), next, gtext(Some(prev), "owner")) {
    Some(why) => return Err(why)
    None => ()
  }
  let settled = self.settle(k.request, "granted", prepare=_ => {
    if self.db.get("SELECT 1 FROM vault_plain WHERE ws=? AND id=? AND body=?", [
        js(ws),
        get(Some(prev), "id").unwrap_or(Json::null()),
        js(prev_body),
      ]) is None {
      raise Refused("the item changed; try again")
    }
    self.plain.put(next)
  }) catch {
    Refused(m) => return Err(m)
    e => raise e
  }
  if !settled {
    return Err(self.decision_changed(k.request))
  }
  Ok(self.plain.item(ws, gtext(Some(next), "id")).unwrap_or(Json::null()))
}

// ── an item deleted (secret_delete 删除) ──

///|
/// secret_delete: a request from `session` to delete item `item`, its card posted for the item's owner (or the person
/// named). It grants nothing.
pub async fn Secrets::remove(self : Secrets, session : String, item : String, reason : String, person? : String) -> String {
  let (ws, _) = self.place_of(session)
  guard self.find_listing(session, lower(trim(item)), person) is Some(found) else {
    raise Refused("No secret named \{quoted(item)} is listed here: secret_list lists those that are.")
  }
  if trim(reason) == "" {
    raise Refused("reason is required: why, for the person deciding")
  }
  let decider = match person {
    Some(p) if trim(p) != "" => self.person_for(session, person)
    _ => found.owner
  }
  let thread = match self.latest_thread_ready(session) {
    None => {
      (self.w.hub.prepare_latest_threads.unwrap())([session])
      match (self.w.hub.store.get_session)(session) {
        Some(row) if !row.archived => ()
        _ => raise Refused("This chat is archived or gone.")
      }
      return self.remove(session, item, reason, person?)
    }
    Some(t) => t
  }
  let plain = found.vault == @vault_crypto.plain_id
  let now = self.now()
  let id = "r_" + ulid(now, (self.w.random)(16))
  let fs = [
    ("id", js(id)),
    ("ws", js(ws)),
    ("vault", js(found.vault)),
    ("item", js(found.item)),
    ("session", js(session)),
    ("chat", js("")),
    ("mode", match get(Some(found.listing), "modes") { Some(Array(a)) => a.get(0).unwrap_or(Json::null()); _ => Json::null() }),
    ("reason", js(trim(reason))),
    ("box", js("")),
    ("at", jn((now / 1000.0).floor())),
    ("status", js("pending")),
  ]
  if plain && found.owner is Some(o) && o != "" {
    fs.push(("owner", js(o)))
  }
  fs.push(("remove", obj([("name", get(Some(found.listing), "name").unwrap_or(Json::null()))])))
  let request = obj(fs)
  let kept : KeptRequest = { request, thread: None, card_ts: None, raw: None }
  if thread is Some(t) {
    set(request, "chat", js(thread_address(t.channel, t.thread_ts)))
    kept.card_ts = self.post_remove(session, t, request, decider)
    kept.thread = Some(t.id)
  }
  self.save(kept)
  self.audit_(request, "remove-request", "")
  self.told(request)
  self.said_remove(request) +
  (match decider {
    Some(d) if d != "" => " It is for \{d} to decide."
    _ => ""
  })
}

///|
/// The card of a request to delete an item: its name and why.
async fn Secrets::post_remove(
  self : Secrets,
  session : String,
  thread : Thread,
  r : Json,
  decider : String?,
  require_empty? : Bool = false,
  signal? : Signal,
) -> String? {
  let name = gtext(get(Some(r), "remove"), "name")
  let stillfail = thread.surface == stillfail_surface
  let lines = ["申请删除密钥「\{name}」：\{gtext(Some(r), "reason")}"]
  if !stillfail {
    lines.push("请在 still.fail 客户端的「密钥」中批准。")
  }
  let card = if stillfail {
    let fs = [
      ("type", js("options")),
      (
        "options",
        jarr([
          obj([("label", js("删除")), ("detail", js("从密钥库删除这条密钥")), ("recommended", jb(true))]),
          obj([("label", js("保留")), ("detail", js("不删除，通知 agent"))]),
        ]),
      ),
    ]
    if decider is Some(x) && x != "" {
      fs.push(("assignee", js(lower(x))))
    }
    fs.push(
      (
        "vault",
        obj([
          ("request", get(Some(r), "id").unwrap_or(Json::null())),
          ("name", js(name)),
          ("reason", get(Some(r), "reason").unwrap_or(Json::null())),
          ("mode", get(Some(r), "mode").unwrap_or(Json::null())),
          ("hosts", jarr([])),
          ("remove", obj([("name", js(name))])),
        ]),
      ),
    )
    Some(obj(fs))
  } else {
    None
  }
  self.post_card(session, thread, join(lines, "\n\n"), card, require_empty, Some(r), signal?)
}

///|
/// What an agent is told of a request to delete an item, waiting or decided.
fn Secrets::said_remove(_self : Secrets, r : Json) -> String {
  let name = gtext(get(Some(r), "remove"), "name")
  let id = gtext(Some(r), "id")
  match gtext(Some(r), "status") {
    "granted" => "Deleted: 「\{name}」 (\{gtext(Some(r), "item")}) is no longer in the vault."
    "denied" => "The person chose to keep 「\{name}」 (request \{id}): it stays in the vault."
    "expired" => "The request to delete 「\{name}」 (\{id}) was let go."
    "withdrawn" => "You withdrew the request to delete 「\{name}」 (\{id})."
    _ =>
      "Asked to delete 「\{name}」 (request \{id}); the card is in your chat, approved in the still.fail app. \{undecided} Only their approval in the app deletes it: a reply in the chat saying yes does not."
  }
}

///|
/// POST vault/removed `{request}`: a request to delete an item of a vault, approved by a member whose app wrote the
/// item's deleted version (and brought it here). Why not, or None.
pub fn Secrets::removed(self : Secrets, lock : Lock, sub : String, d : Json) -> String? raise {
  let k = match gs(Some(d), "request") {
    Some(id) => self.kept(lock.ws, id)
    None => None
  }
  guard k is Some(k) && truthy(get(Some(k.request), "remove")) && !is_plain(k.request) else {
    return Some("no such request to delete an item of a vault")
  }
  let status = gtext(Some(k.request), "status")
  if status != "pending" {
    return Some("the request is \{status}")
  }
  guard self.vaults.vault(lock.ws, gtext(Some(k.request), "vault")) is Some(vault) && members_of(vault).contains(sub) else {
    return Some("only the vault's members decide its requests")
  }
  match self.vaults.item(lock.ws, gtext(Some(vault), "id"), gtext(Some(k.request), "item")) {
    Some(i) if !truthy(get(Some(i), "deleted")) => return Some("the item is not deleted here: bring its copy first")
    _ => ()
  }
  if !self.settle(k.request, "granted") {
    return Some(self.decision_changed(k.request))
  }
  None
}

///|
/// POST vault/plain/removed `{request}`: a request to delete an item of the plain library, approved by its owner:
/// its deleted version written here. The item as written, or why not.
pub fn Secrets::removed_plain(self : Secrets, ws : String, email : String, d : Json) -> Result[Json, String] raise {
  let k = match gs(Some(d), "request") {
    Some(id) => self.kept(ws, id)
    None => None
  }
  guard k is Some(k) && truthy(get(Some(k.request), "remove")) && is_plain(k.request) else {
    return Err("no such request to delete an item of the plain library")
  }
  if gs(Some(k.request), "owner") != Some(lower(email)) {
    return Err("only the item's owner decides its requests")
  }
  let status = gtext(Some(k.request), "status")
  if status != "pending" {
    return Err("the request is \{status}")
  }
  let snapshot = self.plain.item_snapshot(ws, gtext(Some(k.request), "item"))
  guard snapshot is Some((prev, prev_body)) && !truthy(get(Some(prev), "deleted")) else {
    return Err("the item is gone already")
  }
  let next = obj([
    ("ws", js(ws)),
    ("id", get(Some(prev), "id").unwrap_or(Json::null())),
    ("owner", get(Some(prev), "owner").unwrap_or(Json::null())),
    ("version", jn(gn(Some(prev), "version").unwrap_or(@double.not_a_number) + 1.0)),
    ("kind", get(Some(prev), "kind").unwrap_or(Json::null())),
    ("name", js("")),
    ("fields", obj([])),
    ("notes", js("")),
    ("at", jn(self.secs())),
    ("deleted", jb(true)),
  ])
  match @vault_crypto.plain_ok(Some(prev), next, gtext(Some(prev), "owner")) {
    Some(why) => return Err(why)
    None => ()
  }
  let settled = self.settle(k.request, "granted", prepare=_ => {
    if self.db.get("SELECT 1 FROM vault_plain WHERE ws=? AND id=? AND body=?", [
        js(ws),
        get(Some(prev), "id").unwrap_or(Json::null()),
        js(prev_body),
      ]) is None {
      raise Refused("the item changed; try again")
    }
    self.plain.put(next)
  }) catch {
    Refused(m) => return Err(m)
    e => raise e
  }
  if !settled {
    return Err(self.decision_changed(k.request))
  }
  Ok(self.plain.item(ws, gtext(Some(next), "id")).unwrap_or(Json::null()))
}

// ── a request taken back by the agent that asked (secret_cancel 撤回) ──

///|
/// secret_cancel: `session` takes back request `id` of its own that nobody decided yet.
pub fn Secrets::cancel(self : Secrets, session : String, id : String) -> String raise {
  let (ws, _) = self.place_of(session)
  let kept = match self.kept(ws, trim(id)) {
    Some(k) if gs(Some(k.request), "session") == Some(session) => k
    _ =>
      raise Refused(
        "No such request in this chat: give the id (r_…) secret_use, secret_save, secret_describe or secret_delete answered.",
      )
  }
  let r = kept.request
  let rid = gtext(Some(r), "id")
  let status = gtext(Some(r), "status")
  if status != "pending" {
    raise Refused("Request \{rid} is no longer pending (\{status}): nothing to withdraw.")
  }
  if !self.settle(r, "withdrawn") {
    let now = match self.kept(ws, rid) {
      Some(k) => gs(Some(k.request), "status")
      None => None
    }
    match now {
      Some(n) if n != "pending" && n != "" => raise Refused("Request \{rid} was \{n} meanwhile: nothing to withdraw.")
      _ => raise Refused("Request \{rid} changed while it was withdrawn; try again.")
    }
  }
  "Withdrew request \{rid}: its card is closed and its owner no longer sees it waiting."
}
