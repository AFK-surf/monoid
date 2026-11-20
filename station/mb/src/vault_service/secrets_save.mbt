// Secrets agents ask to keep (station/src/vault/secrets.ts, secret_save agent 存入): the person's vault and devices
// they go to, the request and its card, its seal to each device published later (`boxed`), and its approval
// (`saved`, `savedPlain`).

///|
/// The person a session works for, as the lock has them (their sub), where security mode is on.
fn member_of(lock : Lock, email : String) -> String? {
  lock.member_with_email(email)
}

///|
/// `sub`'s devices set up for the vault: their box certificates, checked against the lock.
fn Secrets::certs_of(self : Secrets, lock : Lock, sub : String) -> Array[Json] raise {
  let out = []
  for id in sorted(lock.devices_for(sub)) {
    match self.vaults.box_(lock.ws, id) {
      Some(cert) =>
        if @vault_crypto.cert_ok(self.crypto, lock.view, Some(cert)) is None &&
          lock.device_sub(gtext(Some(cert), "device")) == Some(sub) {
          out.push(cert)
        }
      None => ()
    }
  }
  out
}

///|
/// The vault a secret kept for `sub` is meant for: one of theirs keyed to a device of theirs, their own first; empty
/// while they have none.
fn Secrets::vault_for(self : Secrets, lock : Lock, sub : String) -> String raise {
  let devices = self.certs_of(lock, sub).map(c => gtext(Some(c), "device"))
  if devices.is_empty() {
    return ""
  }
  self.db.exec("SAVEPOINT vault_choose_owner")
  let chosen = (fn() -> String raise {
    let mut first : Json? = None
    let personal = fn(vaults : Array[Json]) -> Json? {
      for vault in vaults {
        let keyed = ga(Some(vault), "keys").unwrap_or([]).any(k => devices.contains(gtext(get(Some(k), "cert"), "device")))
        if truthy(get(Some(vault), "deleted")) ||
          gs(Some(vault), "scope") == Some("workspace") ||
          !members_of(vault).contains(sub) ||
          !keyed {
          continue
        }
        if first is None {
          first = Some(vault)
        }
        if gs(Some(vault), "owner") == Some(sub) {
          return Some(vault)
        }
      }
      None
    }
    let prefix = self.vaults.first_vaults(lock.ws, listing_prefix)
    let mut owned = personal(prefix.map(e => e.1))
    if owned is Some(o) {
      return gs(Some(o), "id").unwrap_or("")
    }
    if prefix.length() == listing_prefix {
      owned = personal(self.vaults.vaults_after(lock.ws, prefix[prefix.length() - 1].0))
    }
    match owned {
      Some(o) => gs(Some(o), "id").unwrap_or("")
      None =>
        match first {
          Some(f) => gs(Some(f), "id").unwrap_or("")
          None => ""
        }
    }
  })() catch {
    e => {
      self.db.exec("RELEASE vault_choose_owner")
      raise e
    }
  }
  self.db.exec("RELEASE vault_choose_owner")
  chosen
}

///|
fn Secrets::seal_to(self : Secrets, cert : Json, ws : String, request : String, fields : Json) -> Json raise {
  let box_ = gtext(Some(cert), "box")
  obj([
    ("device", get(Some(cert), "device").unwrap_or(Json::null())),
    ("box", get(Some(cert), "box").unwrap_or(Json::null())),
    (
      "secret",
      js(
        @vault_crypto.seal(
          self.crypto,
          box_,
          utf8_of(stringify(fields)),
          @vault_crypto.save_context(ws, request),
        ),
      ),
    ),
  ])
}

///|
/// Whether the person a session works for can keep a secret: `plain`, `on`, `off`, `none`.
pub fn Secrets::status(self : Secrets, session : String, person? : String) -> String raise {
  let (_, lock) = self.place_of(session)
  guard self.person_for(session, person) is Some(email) else { return "none" }
  guard lock is Some(lock) else { return "plain" }
  // (no security mode: a member whose own lock this station has not heard yet turns their vault on as they keep it)
  guard member_of(lock, email) is Some(sub) else { return if lock.open_roster() { "off" } else { "none" } }
  if self.vault_for(lock, sub) != "" {
    "on"
  } else {
    "off"
  }
}

///|
/// What secret_save asks (secrets.ts `save`'s `a`).
pub(all) struct SaveAsk {
  name : String
  kind : String
  reason : String
  value : String?
  command : String?
  path : String?
  username : String?
  public_key : String?
  filename : String?
  modes : Array[String]?
  hosts : Array[String]?
  env : String?
  cwd : String
  station : String?
  browser : String?
  person : String?
  scope : String?
  oauth : String?
  about : String?
  /// Kept from a sign-in's card: no card of its own, its request told to it.
  quiet : ((String) -> Unit)?
}

///|
/// `'p'` quoted for the shell.
fn shell_quoted(p : String) -> String {
  "'" + replace_all(p, "'", "'\\''") + "'"
}

///|
/// `basename(p)`.
fn basename(p : String) -> String {
  @nodepath.basename("/", p)
}

///|
/// The workspace vault `sub` is a member of in `lock`'s workspace, if any (non-deleted).
fn Secrets::workspace_vault_for(self : Secrets, lock : Lock?, sub : String?) -> Json? raise {
  guard (lock, sub) is (Some(l), Some(u)) else { return None }
  for v in self.vaults.vaults(l.ws) {
    if !truthy(get(Some(v), "deleted")) &&
      gs(Some(v), "scope") == Some("workspace") &&
      members_of(v).contains(u) {
      return Some(v)
    }
  }
  None
}

///|
/// secret_save: a request from `session` to keep a secret in the vault of whoever started its chat, given as `value`,
/// printed by `command` or, given neither, typed in by that person on its card.
pub async fn Secrets::save_secret(self : Secrets, session : String, a : SaveAsk) -> String {
  let (ws, place_lock) = self.place_of(session)
  let mut lock = place_lock
  if a.scope is Some(sc) && sc != "personal" && sc != "workspace" {
    raise Refused("scope is personal or workspace")
  }
  let kind = a.kind
  // A sign-in is read from a browser, never given, printed or typed in.
  if kind == "browser" && (a.value is Some(_) || a.command is Some(_) || a.path is Some(_) || a.station is Some(_)) {
    raise Refused(
      "A sign-in (kind browser) is read from this chat's browser (or the station's: browser \"station\"), its cookies of hosts: give no value, command, path or station.",
    )
  }
  if kind == "browser" && self.w.browsers is None {
    raise Refused("This station has no browser to read a sign-in from.")
  }
  if kind != "browser" && a.browser is Some(_) {
    raise Refused("browser says where a sign-in is read from: give kind browser")
  }
  if a.path is Some(_) && kind != "file" {
    raise Refused("path is a file's: give kind file")
  }
  if a.path is Some(_) && (a.command is Some(_) || a.value is Some(_)) {
    raise Refused("Give a file as path, command or value, one of them.")
  }
  // A file given by its path: read as a command printing it would (here or on the station named), ~/ its home there.
  let command = match a.path {
    None => a.command
    Some(p) =>
      Some(
        "cat -- " +
        (if starts(p, "~/") { "\"$HOME\"/" + shell_quoted(slice(p, 2)) } else { shell_quoted(p) }),
      )
  }
  let filename = if kind == "file" {
    trim(match a.filename {
      Some(f) => f
      None => match a.path { Some(p) => basename(p); None => "" }
    })
  } else {
    ""
  }
  let from = match a.station {
    Some(s) if s != "" => self.peer(s)
    _ => None
  }
  if from is Some(_) && command is None {
    raise Refused("station says where command runs: give command (or path)")
  }
  guard self.person_for(session, a.person) is Some(email) else {
    raise Refused("No one started this chat: there is no one to keep a secret for; name the person it is for (person).")
  }
  if !@vault_crypto.kinds.contains(kind) {
    raise Refused("kind is token, login, ssh_key, file or browser")
  }
  let name = trim(a.name)
  if name == "" || name.length() > 200 {
    raise Refused("name is required (at most 200 characters): what the person and agents will know it by")
  }
  if trim(a.reason) == "" {
    raise Refused("reason is required: why it is worth keeping, for the person deciding")
  }
  let about = trim(a.about.unwrap_or(""))
  if about.length() > @vault_crypto.about_most {
    raise Refused("about is at most \{@vault_crypto.about_most} characters")
  }
  if a.value is Some(_) && command is Some(_) {
    raise Refused(
      "Give the secret as value or as a command that prints it (command), not both; neither, and the card asks the person to type it in.",
    )
  }
  let typed = kind != "browser" && a.value is None && command is None
  let oauth = match a.oauth {
    None => None
    Some(o) => oauth_of(o)
  }
  if a.oauth is Some(_) {
    guard oauth is Some((_, ohosts)) else { raise Refused("oauth is one of \{join(oauth_names, ", ")}") }
    if kind != "token" || !typed || a.station is Some(_) {
      raise Refused(
        "oauth is a token the person signs in for on the card: kind token, and no value, command, path or station",
      )
    }
    if a.modes is Some(ms) && ms.any(m => m != "proxy") {
      raise Refused("oauth's token is given through the proxy to \{join(ohosts, ", ")} alone")
    }
  }
  let hosts = match oauth {
    Some((_, h)) => h
    None => uniq(a.hosts.unwrap_or([]).map(h => lower(trim(h))).filter(h => h != ""))
  }
  let modes = match a.modes {
    Some(ms) if ms.length() > 0 => uniq(ms)
    _ =>
      if kind == "ssh_key" {
        ["ssh"]
      } else if kind == "file" {
        ["file"]
      } else if kind == "browser" {
        ["browser"]
      } else if hosts.length() > 0 {
        ["proxy"]
      } else {
        ["env"]
      }
  }
  if !modes.all(m => @vault_crypto.modes.contains(m)) {
    raise Refused("modes are proxy, ssh, env, file or browser")
  }
  if modes.contains("ssh") != (kind == "ssh_key") {
    raise Refused("an SSH key is given by ssh (or env), and only an SSH key is")
  }
  if kind == "file" && (modes.length() != 1 || modes[0] != "file") {
    raise Refused("a file is given as a file (modes: [\"file\"])")
  }
  let mut sub = match lock {
    None => None
    Some(l) => member_of(l, email)
  }
  if lock is Some(l) && !l.open_roster() && sub is None {
    raise Refused("\{email} is not in the workspace's security mode: there is no vault of theirs to keep it in.")
  }
  if a.scope == Some("workspace") && self.workspace_vault_for(lock, sub) is None {
    raise Refused(
      "No workspace vault exists yet (or you are not a member): an owner or admin can create one in Settings → Vault, or omit scope to save to your personal vault.",
    )
  }
  let lf = [("name", js(name)), ("kind", js(kind)), ("modes", jstrs(modes)), ("hosts", jstrs(hosts))]
  if a.env is Some(e) && e != "" {
    lf.push(("env", js(e)))
  }
  if about != "" {
    lf.push(("about", js(about)))
  }
  let listing = obj(lf)
  let now = self.now()
  let item = "i_" + ulid(now, (self.w.random)(16))
  // What is not secret checked before anything is run.
  let draft = (fields : Json) => obj([
    ("ws", js(ws)),
    ("id", js(item)),
    ("owner", js(email)),
    ("version", jn(0.0)),
    ("kind", js(kind)),
    ("name", js(name)),
    ("fields", fields),
    ("notes", js(about)),
    ("listing", listing),
    ("at", jn((now / 1000.0).floor())),
  ])
  let fields_of = (value : String) => match kind {
    "token" => obj([("value", js(value))])
    "browser" => obj([("cookies", js(value))])
    "login" => {
      let fs = []
      if a.username is Some(u) && u != "" {
        fs.push(("username", js(u)))
      }
      fs.push(("password", js(value)))
      obj(fs)
    }
    "file" => {
      let fs = [("content", js(value))]
      if filename != "" {
        fs.push(("filename", js(filename)))
      }
      obj(fs)
    }
    _ => {
      let fs = [("private_key", js(value))]
      if a.public_key is Some(p) && p != "" {
        fs.push(("public_key", js(p)))
      }
      obj(fs)
    }
  }
  match @vault_crypto.plain_ok(None, draft(fields_of("eA==")), email) {
    Some(why) => raise Refused(why)
    None => ()
  }
  let mut value = match (kind, a.value) {
    ("file", Some(v)) => @vault_crypto.b64(utf8_of(v))
    (_, v) => v.unwrap_or("")
  }
  if command is Some(cmd) {
    let got = match from {
      None => capture(self.w, cmd, a.cwd, base_env(self.w), capture_ms)
      Some(on) => self.capture_on(on, session, ws, cmd)
    }
    let end = if got.timed_out {
      "it ran too long"
    } else {
      match got.code {
        Some(c) => "exit code \{c}"
        None => "ended by \{got.signal.unwrap_or("null")}"
      }
    }
    let what = if a.path is Some(_) {
      "The file could not be read (\{end}); nothing was kept."
    } else {
      "The command did not print the secret (\{end}); nothing was kept."
    }
    if got.timed_out || got.code != Some(0) {
      raise Refused("\{what} What it said on stderr:\n\{slice(got.err, -2000)}")
    }
    if got.too_long {
      raise Refused(
        "\{if a.path is Some(_) { "The file is" } else { "The command printed" }} more than 64 KB: that is not one secret; nothing was kept.",
      )
    }
    if kind == "file" && got.raw is None {
      raise Refused(
        "\{match from { Some(f) => f.name; None => "That station" }} cannot read a file as its bytes yet: update it.",
      )
    }
    value = if kind == "file" { got.raw.unwrap() } else { got.out }
  }
  if kind == "browser" {
    value = (self.w.browsers.unwrap().cookies)(session, hosts, a.browser == Some("station"))
    let found = state_of(value)
    if found.0.is_empty() && found.1.is_empty() {
      raise Refused(
        "\{if a.browser == Some("station") { "The station's browser" } else { "This chat's browser" }} holds no cookies or passkeys of \{join(hosts, ", ")}: sign in there first (a person, in the tab you give them with the `screen` tool; a passkey: added on the site's account page there); nothing was kept.",
      )
    }
    if value.length() > typed_most {
      raise Refused(
        "The cookies of \{join(hosts, ", ")} are more than \{typed_most / 1024} KB: name the sites the sign-in is for, not more; nothing was kept.",
      )
    }
  }
  if kind == "file" && @vault_crypto.unb64(value).length() > @vault_crypto.file_most {
    raise Refused("The file is more than \{@vault_crypto.file_most / 1024} KB; nothing was kept.")
  }
  if value == "" && !typed {
    raise Refused("The secret is empty; nothing was kept.")
  }
  // A command or browser read happens once: who may keep it is checked again before a box is made or anything saved.
  let current_lock = fn() -> Lock? raise {
    match (self.w.hub.store.get_session)(session) {
      Some(row) if !row.archived => {
        let rws = match row.ws {
          Some(x) => Some(x)
          None => (self.w.home)()
        }
        if rws != Some(ws) || self.person_for(session, a.person) != Some(email) {
          raise Refused("This chat's owner or workspace changed; nothing was kept.")
        }
        (self.w.lock)(row.ws)
      }
      _ => raise Refused("This chat is archived or gone; nothing was kept.")
    }
  }
  ignore(current_lock())
  let mut thread = self.latest_thread_ready(session)
  while thread is None {
    (self.w.hub.prepare_latest_threads.unwrap())([session])
    ignore(current_lock())
    thread = self.latest_thread_ready(session)
  }
  lock = current_lock()
  sub = match lock {
    None => None
    Some(l) => member_of(l, email)
  }
  if lock is Some(l) && !l.open_roster() && sub is None {
    raise Refused("\{email} is not in the workspace's security mode: there is no vault of theirs to keep it in.")
  }
  let ws_vault = if a.scope == Some("workspace") { self.workspace_vault_for(lock, sub) } else { None }
  if a.scope == Some("workspace") && ws_vault is None {
    raise Refused(
      "No workspace vault exists yet (or you are not a member): an owner or admin can create one in Settings → Vault, or omit scope to save to your personal vault.",
    )
  }
  let fields = if typed { None } else { Some(fields_of(value)) }
  let requested_at = self.now()
  let id = "r_" + ulid(requested_at, (self.w.random)(16))
  let sf = [("kind", js(kind)), ("name", js(name)), ("modes", jstrs(modes)), ("hosts", jstrs(hosts))]
  if a.env is Some(e) && e != "" {
    sf.push(("env", js(e)))
  }
  if a.username is Some(u) && u != "" {
    sf.push(("username", js(u)))
  }
  if a.public_key is Some(p) && p != "" {
    sf.push(("public_key", js(p)))
  }
  if filename != "" {
    sf.push(("filename", js(filename)))
  }
  if typed {
    sf.push(("typed", jb(true)))
  }
  if a.oauth is Some(o) {
    sf.push(("oauth", js(o)))
  }
  if about != "" {
    sf.push(("about", js(about)))
  }
  if ws_vault is Some(wv) {
    if gs(Some(wv), "name") is Some(vn) && vn != "" {
      sf.push(("vaultName", js(vn)))
    }
    sf.push(("shared", jb(true)))
  }
  let save = obj(sf)
  let vault_id = match ws_vault {
    Some(wv) => gtext(Some(wv), "id")
    None =>
      match (lock, sub) {
        (None, _) => @vault_crypto.plain_id
        (Some(_), None) => ""
        (Some(l), Some(u)) => self.vault_for(l, u)
      }
  }
  let rf = [
    ("id", js(id)),
    ("ws", js(ws)),
    ("vault", js(vault_id)),
    ("item", js(item)),
    ("session", js(session)),
    ("chat", js("")),
    ("mode", js(modes[0])),
    ("reason", js(trim(a.reason))),
  ]
  if command is Some(c) {
    rf.push(("command", js(c)))
  }
  if hosts.length() > 0 {
    rf.push(("hosts", jstrs(hosts)))
  }
  // A vault's: a box for the grant to this chat that comes with keeping it.
  rf.push(("box", js(if lock is None { "" } else { self.keeper.open(id) })))
  rf.push(("at", jn((requested_at / 1000.0).floor())))
  rf.push(("status", js("pending")))
  rf.push(("owner", js(email)))
  rf.push(("save", save))
  if from is Some(p) {
    rf.push(("runOn", obj([("id", js(p.id)), ("name", js(p.name))])))
  }
  if lock is Some(l) && fields is Some(f) {
    rf.push(("sealed", jarr(match sub { Some(u) => self.certs_of(l, u).map(c => self.seal_to(c, ws, id, f)); None => [] })))
  }
  let request = obj(rf)
  let during_handover = lock is Some(_) && fields is Some(_) && !self.previous_exited
  if fields is Some(f) {
    self.unsaved[id] = f
    self.scope_save(id, ws, email)
    self.posting_saves[id] = request
    // The previous process cannot rebox a save whose fields exist only in this process.
    if during_handover {
      self.carried_saves[id] = ()
      self.wait_for_carried_saves()
    }
  }
  let kept : KeptRequest = { request, thread: None, card_ts: None, raw: None }
  (async fn() -> Unit raise {
    if thread is Some(Some(t)) {
      set(request, "chat", js(thread_address(t.channel, t.thread_ts)))
      kept.card_ts = if a.quiet is Some(_) { None } else { self.post_save(session, t, request) }
      kept.thread = Some(t.id)
    }
    // If the predecessor exited while the card was posted, its last certificate is included before this is written.
    if during_handover && self.previous_exited {
      ignore(self.seal_current_save(request))
    }
    self.save(kept)
  })() catch {
    e => {
      self.forget_save(id)
      self.keeper.drop(id)
      self.posting_saves.remove(id)
      raise e
    }
  }
  self.posting_saves.remove(id)
  match a.quiet {
    Some(q) => q(id)
    None => ()
  }
  let detail = [
    join(modes, " "),
    join(hosts, " "),
    match from {
      Some(f) => "\{f.name}: \{command.unwrap_or("")}"
      None => command.unwrap_or("")
    },
    match a.oauth {
      Some(o) => "oauth \{o}"
      None => if typed { "typed" } else { "" }
    },
  ]
  self.audit_(request, "save-request", join(detail.filter(x => x != ""), " · "))
  self.told(request)
  self.said_save(request)
}

///|
/// The card of a request to keep a secret: what it is, whose, why.
async fn Secrets::post_save(
  self : Secrets,
  session : String,
  thread : Thread,
  r : Json,
  require_empty? : Bool = false,
  signal? : Signal,
) -> String? {
  let s = get(Some(r), "save")
  let stillfail = thread.surface == stillfail_surface
  let username = gtext(s, "username")
  let filename = gtext(s, "filename")
  let kind = "（\{kind_words(gtext(s, "kind"))}\{if username != "" { " · \{username}" } else if filename != "" { " · \{filename}" } else { "" }}）"
  let name = gtext(s, "name")
  let reason = gtext(Some(r), "reason")
  let oauth = gtext(s, "oauth")
  let typed = truthy(get(s, "typed"))
  let oauth_name = match oauth_of(oauth) {
    Some((n, _)) => n
    None => oauth
  }
  let lines = [
    if oauth != "" {
      "请用 \{oauth_name} 授权，把「\{name}」存入密钥库：\{reason}"
    } else if typed {
      "请填入「\{name}」\{kind}并存入密钥库：\{reason}"
    } else {
      "申请将「\{name}」存入密钥库\{kind}：\{reason}"
    },
  ]
  let about = gtext(s, "about")
  if about != "" {
    lines.push("说明：\{about}")
  }
  if !stillfail {
    lines.push(
      if oauth != "" {
        "请在 still.fail 客户端的「密钥」中授权并存入。"
      } else if typed {
        "请在 still.fail 客户端的「密钥」中填写并存入。"
      } else {
        "请在 still.fail 客户端的「密钥」中批准。"
      },
    )
  }
  let card = if stillfail {
    let mode0 = match get(s, "modes") {
      Some(Array(a)) => a.get(0).unwrap_or(Json::null())
      _ => Json::null()
    }
    let v = [
      ("request", get(Some(r), "id").unwrap_or(Json::null())),
      ("name", js(name)),
      ("reason", js(reason)),
    ]
    if gs(Some(r), "command") is Some(c) && c != "" {
      v.push(("command", js(c)))
    }
    v.push(("mode", mode0))
    v.push(("hosts", if hosted(js_text(Some(mode0))) { get(s, "hosts").unwrap_or(Json::null()) } else { jarr([]) }))
    if about != "" {
      v.push(("about", js(about)))
    }
    if get(Some(r), "runOn") is Some(Object(_) as on) {
      v.push(("station", get(Some(on), "name").unwrap_or(Json::null())))
    }
    let sv = [("kind", get(s, "kind").unwrap_or(Json::null()))]
    if username != "" {
      sv.push(("username", js(username)))
    }
    if filename != "" {
      sv.push(("filename", js(filename)))
    }
    if typed {
      sv.push(("typed", jb(true)))
    }
    if oauth != "" {
      sv.push(("oauth", js(oauth)))
    }
    let vault_name = gtext(s, "vaultName")
    if vault_name != "" {
      sv.push(("vaultName", js(vault_name)))
    }
    if truthy(get(s, "shared")) {
      sv.push(("shared", jb(true)))
    }
    v.push(("save", obj(sv)))
    Some(
      obj([
        ("type", js("options")),
        (
          "options",
          jarr([
            obj([("label", js("存入密钥库")), ("detail", js("agent 之后每次使用仍需你批准")), ("recommended", jb(true))]),
            obj([("label", js("拒绝")), ("detail", js("不保存，通知 agent"))]),
          ]),
        ),
        ("assignee", get(Some(r), "owner").unwrap_or(Json::null())),
        ("vault", obj(v)),
      ]),
    )
  } else {
    None
  }
  self.post_card(session, thread, join(lines, "\n\n"), card, require_empty, Some(r), signal?)
}

///|
/// What an agent is told of a request to keep a secret, waiting or decided.
fn Secrets::said_save(self : Secrets, r : Json) -> String {
  let s = get(Some(r), "save")
  let name = gtext(s, "name")
  let id = gtext(Some(r), "id")
  let whose = match gs(Some(r), "owner") {
    Some(o) => o
    None => "the person"
  }
  match gtext(Some(r), "status") {
    "granted" => {
      let held = self.keeper.usable(gtext(Some(r), "session"), id)
      let env_hint = if gtext(s, "env") != "" { "" } else { ", env: \"NAME\"" }
      let use_ = match held {
        Err(_) => "When you need it, ask with secret_use {item: \"\{name}\"}, then secret_run."
        Ok(h) => {
          let mode = gtext(Some(h.grant), "mode")
          let by = match mode {
            "proxy" => "through the proxy to \{join(strings_of(get(Some(h.grant), "hosts")), ", ")}"
            "ssh" => "by ssh-agent"
            "file" => "as a file, its path in the variable"
            _ => "in the environment"
          }
          "This chat may use it now: secret_run {grant: \"\{id}\", command: \"…\"\{env_hint}} (\{by}); other chats ask with secret_use."
        }
      }
      let acct = match held {
        Ok(h) => account_said(h)
        Err(_) => ""
      }
      "Kept: 「\{name}」 is in \{whose}'s vault now (item \{gtext(Some(r), "item")}). \{use_}\{acct}"
    }
    "denied" => "\{whose} chose not to keep 「\{name}」 (request \{id})."
    "expired" => "The request to keep 「\{name}」 (\{id}) was let go."
    _ => {
      let typed = truthy(get(s, "typed"))
      let off = if gs(Some(r), "vault") == Some("") && !typed {
        " Their vault is not turned on yet: the card lets them turn it on in the still.fail app, and then keep it."
      } else {
        ""
      }
      let oauth = gtext(s, "oauth")
      let oname = match oauth_of(oauth) {
        Some((n, _)) => n
        None => oauth
      }
      let asked = if oauth != "" {
        "Asked \{whose} to sign in to \{oname} for 「\{name}」 (request \{id}): its card has them sign in on \{oname}'s own page in the still.fail app, and their own token goes into their vault as they do, never to you."
      } else if typed {
        "Asked \{whose} to type 「\{name}」 in (request \{id}): its card has a field for it, and what they type goes into their vault as they approve it in the still.fail app (turning their vault on first where it is not), never to you."
      } else {
        "Asked to keep 「\{name}」 (request \{id}); the card is in your chat for \{whose}, who approves it in the still.fail app.\{off}"
      }
      "\{asked} \{undecided} Only their approval in the app keeps it: a reply in the chat saying yes does not."
    }
  }
}

///|
fn Secrets::seal_save(self : Secrets, r : Json, lock : Lock, cert : Json, sub : String, email : String) -> Bool raise {
  let id = gtext(Some(r), "id")
  guard self.unsaved.get(id) is Some(fields) else { return false }
  let box_ = get(Some(cert), "box")
  if gs(Some(r), "ws") != Some(lock.ws) ||
    !truthy(get(Some(r), "save")) ||
    is_plain(r) ||
    gs(Some(r), "owner") != Some(email) ||
    ga(Some(r), "sealed").unwrap_or([]).any(x => get(Some(x), "box") == box_) {
    return false
  }
  let device = get(Some(cert), "device")
  let kept_seals = ga(Some(r), "sealed").unwrap_or([]).filter(x => get(Some(x), "device") != device)
  kept_seals.push(self.seal_to(cert, gtext(Some(r), "ws"), id, fields))
  set(r, "sealed", jarr(kept_seals))
  if gs(Some(r), "vault") == Some("") {
    set(r, "vault", js(self.vault_for(lock, sub)))
  }
  true
}

///|
/// A device's box key published (PUT vault/boxes, checked): the secrets waiting to be kept for its person sealed to it
/// too, so that they may approve them from it.
pub fn Secrets::boxed(self : Secrets, lock : Lock, cert : Json) -> Bool raise {
  let complete = self.boxed_(lock, cert) catch {
    e => {
      self.queue_rebox(lock.ws, gtext(Some(cert), "device"))
      raise e
    }
  }
  if !complete {
    self.queue_rebox(lock.ws, gtext(Some(cert), "device"))
  }
  complete
}

///|
fn Secrets::queue_rebox(self : Secrets, ws : String, device : String) -> Unit {
  if self.restore_closed {
    return
  }
  let key = "\{ws}\u{0}\{device}"
  if !self.rebox_pending.contains(key) {
    self.rebox_pending[key] = (ws, device, 250.0)
  }
  self.schedule_rebox(0.0)
}

///|
fn Secrets::schedule_rebox(self : Secrets, delay : Double) -> Unit {
  if self.restore_closed || self.rebox_scheduled || self.rebox_pending.is_empty() {
    return
  }
  self.rebox_scheduled = true
  // timer: a retry after a failure, with a backoff (a certificate's write raced a request's)
  self.timers.push((self.w.after)(delay, () => self.retry_rebox()))
}

///|
fn Secrets::retry_rebox(self : Secrets) -> Unit {
  self.rebox_scheduled = false
  if self.restore_closed {
    return
  }
  let mut next : (String, (String, String, Double))? = None
  for k, v in self.rebox_pending {
    next = Some((k, v))
    break
  }
  guard next is Some((key, (ws, device, pending_delay))) else { return }
  self.rebox_pending.remove(key)
  let mut retry = false
  let mut delay = pending_delay
  (fn() raise {
    match (self.w.lock)(Some(ws)) {
      None => {
        retry = true
        delay = @cmp.maximum(delay, 5000.0)
      }
      Some(lock) =>
        match self.vaults.box_(ws, device) {
          Some(cert) =>
            if gs(Some(cert), "ws") == Some(ws) &&
              gs(Some(cert), "device") == Some(device) &&
              @vault_crypto.cert_ok(self.crypto, lock.view, Some(cert)) is None {
              retry = !self.boxed_(lock, cert)
            }
          None => ()
        }
    }
  })() catch {
    e => {
      retry = true
      self.w.warn("vault", "a certificate could not rebox its pending saves", obj([("error", js(message_of(e)))]))
    }
  }
  if retry && !self.rebox_pending.contains(key) {
    self.rebox_pending[key] = (ws, device, @cmp.minimum(delay * 2.0, 30000.0))
  }
  self.schedule_rebox(if retry { delay } else { 0.0 })
}

///|
fn Secrets::boxed_(self : Secrets, lock : Lock, cert : Json) -> Bool raise {
  let device = gtext(Some(cert), "device")
  guard lock.device_sub(device) is Some(sub) else { return true }
  guard lock.email_of(sub).map(lower) is Some(email) else { return true }
  // A handover from an older station may contain a save not written yet: those known ids rechecked here.
  if !self.unscoped_saves.is_empty() {
    let ids = []
    for id, _ in self.unscoped_saves {
      ids.push(id)
    }
    for id in ids {
      match self.db.get(carried_save_pending, [js(lock.ws), js(id)]) {
        Some(row) => {
          let r = parse(js_text(row.get(0)))
          let rid = gtext(Some(r), "id")
          if self.unscoped_saves.contains(rid) && truthy(get(Some(r), "save")) && gs(Some(r), "owner") is Some(owner) {
            self.scope_save(rid, gtext(Some(r), "ws"), owner)
          }
        }
        None => ()
      }
    }
  }
  // Request ids are ASCII ULIDs: the old workspace scan's primary-key order kept for notifications.
  let ids = []
  match self.saves_by_owner.get(lock.ws) {
    Some(owners) =>
      match owners.get(email) {
        Some(requests) => for id, _ in requests { ids.push(id) }
        None => ()
      }
    None => ()
  }
  let requests = sorted(ids)
  if requests.is_empty() {
    return true
  }
  let mut checked = stringify(cert)
  let mut complete = true
  for id in requests {
    let mut settled = false
    for _ in 0..<3 {
      // A certificate published meanwhile is trusted only once checked against the lock.
      guard self.vaults.box_snapshot(lock.ws, device) is Some((held_value, held_body)) else { break }
      if held_body != checked {
        if !(held_value is Object(_)) ||
          gs(Some(held_value), "ws") != Some(lock.ws) ||
          gs(Some(held_value), "device") != Some(device) ||
          @vault_crypto.cert_ok(self.crypto, lock.view, Some(held_value)) is Some(_) {
          break
        }
        checked = held_body
      }
      match self.posting_saves.get(id) {
        Some(posting) => ignore(self.seal_save(posting, lock, held_value, sub, email))
        None => ()
      }
      guard self.db.get(
          "SELECT body, thread, card_ts FROM vault_requests WHERE ws = ? AND id = ? AND status = 'pending'",
          [js(lock.ws), js(id)],
        )
        is Some(row) else {
        settled = true
        break
      }
      let row_body = js_text(row.get(0))
      let k : KeptRequest = {
        request: parse(row_body),
        thread: match row.get(1) { Some(Number(n, ..)) => Some(n.to_int()); _ => None },
        card_ts: match row.get(2) { Some(String(s)) => Some(s); _ => None },
        raw: None,
      }
      if !self.seal_save(k.request, lock, held_value, sub, email) {
        settled = true
        break
      }
      if self.db.run(
          "UPDATE vault_requests SET body = ?\n      WHERE ws = ? AND id = ? AND status = 'pending' AND body = ? AND thread IS ? AND card_ts IS ?\n        AND EXISTS (SELECT 1 FROM vault_boxes WHERE ws = ? AND device = ? AND body = ?)",
          [
            js(stringify(k.request)),
            js(lock.ws),
            js(id),
            js(row_body),
            opt_int(k.thread),
            opt_text(k.card_ts),
            js(lock.ws),
            js(device),
            js(held_body),
          ],
        ) ==
        0 {
        continue
      }
      self.track_saved(k)
      self.told(k.request)
      settled = true
      break
    }
    if !settled {
      complete = false
    }
  }
  complete
}

///|
/// POST vault/saves: a secret asked to be kept, written by `sub`'s app into their vault `vault` (its copy brought here
/// first); why it is refused, or None.
pub fn Secrets::saved(self : Secrets, lock : Lock, sub : String, d : Json) -> String? raise {
  let k = match gs(Some(d), "request") {
    Some(id) => self.kept(lock.ws, id)
    None => None
  }
  guard k is Some(k) && truthy(get(Some(k.request), "save")) && !is_plain(k.request) else {
    return Some("no such request to keep a secret in a vault")
  }
  if lock.email_of(sub).map(lower) != gs(Some(k.request), "owner") || lock.email_of(sub) is None {
    return Some("only the person it is kept for decides it")
  }
  let status = gtext(Some(k.request), "status")
  if status != "pending" {
    return Some("the request is \{status}")
  }
  let vault_snapshot = match gs(Some(d), "vault") {
    Some(v) => self.vaults.vault_snapshot(lock.ws, v)
    None => None
  }
  guard vault_snapshot is Some((vault, vault_body)) && members_of(vault).contains(sub) else {
    return Some("no such vault of theirs here")
  }
  let vid = gtext(Some(vault), "id")
  let item_snapshot = self.vaults.item_snapshot(lock.ws, vid, gtext(Some(k.request), "item"))
  guard item_snapshot is Some((item, item_body)) &&
    !truthy(get(Some(item), "deleted")) &&
    gs(get(Some(item), "listing"), "name") == gs(get(Some(k.request), "save"), "name") &&
    has(Some(item), "listing") else {
    return Some("the item is not in that vault here: bring its copy first")
  }
  // Keeping it lets the chat that asked use it (its app's grant, sealed to this request's box).
  let prepared : @vault_crypto.Prepared? = match get(Some(d), "grant") {
    None => None
    Some(g) =>
      Some(self.keeper.prepare_accept(lock.view, vault, item, spread(Some(k.request), [("vault", js(vid))]), g))
  }
  let mut why : String? = None
  let settled = self.settle(k.request, "granted", into=vid, prepare=current => {
    self.check_vault_snapshot(lock.ws, vid, gtext(Some(item), "id"), vault_body, item_body)
    why = match prepared {
      None => Some("none sent")
      Some(Refusal(w)) => Some(w)
      Some(Ready(take)) => take()
    }
    if why is Some(_) && self.keeper.waiting(gtext(Some(current), "id")) {
      self.keeper.drop(gtext(Some(current), "id"))
    }
  }) catch {
    Refused(m) => return Some(m)
    e => raise e
  }
  if !settled {
    return Some(self.decision_changed(k.request))
  }
  if why is Some(w) {
    self.w.warn("vault", "a kept secret's grant to its chat not taken", obj([("why", js(w))]))
  }
  None
}

///|
/// POST vault/plain/saves: a secret asked to be kept, approved by whoever it is for (no security mode): written into
/// the plain library here. The item as written, or why not.
pub fn Secrets::saved_plain(self : Secrets, ws : String, lock : Lock?, email : String, d : Json) -> Result[Json, String] raise {
  let k = match gs(Some(d), "request") {
    Some(id) => self.kept(ws, id)
    None => None
  }
  guard k is Some(k) && truthy(get(Some(k.request), "save")) && is_plain(k.request) else {
    return Err("no such request to keep a secret")
  }
  if gs(Some(k.request), "owner") != Some(lower(email)) {
    return Err("only the person it is kept for decides it")
  }
  if lock is Some(_) {
    return Err("security mode is on: secrets go into the vault, encrypted")
  }
  let status = gtext(Some(k.request), "status")
  if status != "pending" {
    return Err("the request is \{status}")
  }
  let s = get(Some(k.request), "save")
  let kind = gtext(s, "kind")
  let typed = truthy(get(s, "typed"))
  let fields = if typed { typed_fields(kind, get(Some(d), "fields")) } else { self.unsaved.get(gtext(Some(k.request), "id")) }
  guard fields is Some(fields) else {
    return Err(
      if typed {
        "this secret is typed in on its card, and sent with its fields (an app from before that cannot: update it)"
      } else {
        "the secret is gone (the station restarted): the agent asks again"
      },
    )
  }
  let lf = [
    ("name", get(s, "name").unwrap_or(Json::null())),
    ("kind", get(s, "kind").unwrap_or(Json::null())),
    ("modes", get(s, "modes").unwrap_or(Json::null())),
    ("hosts", get(s, "hosts").unwrap_or(Json::null())),
  ]
  if gtext(s, "env") != "" {
    lf.push(("env", get(s, "env").unwrap()))
  }
  if gtext(s, "about") != "" {
    lf.push(("about", get(s, "about").unwrap()))
  }
  let next = obj([
    ("ws", js(ws)),
    ("id", get(Some(k.request), "item").unwrap_or(Json::null())),
    ("owner", get(Some(k.request), "owner").unwrap_or(Json::null())),
    ("version", jn(0.0)),
    ("kind", get(s, "kind").unwrap_or(Json::null())),
    ("name", get(s, "name").unwrap_or(Json::null())),
    ("fields", fields),
    ("notes", js(gtext(s, "about"))),
    ("listing", obj(lf)),
    ("at", jn(self.secs())),
  ])
  let item_id = gtext(Some(next), "id")
  if self.plain.item(ws, item_id) is Some(_) {
    return Err("the item is there already")
  }
  match @vault_crypto.plain_ok(None, next, gtext(Some(next), "owner")) {
    Some(why) => return Err(why)
    None => ()
  }
  let mut held : String? = None
  let settled = self.settle(k.request, "granted", prepare=current => {
    if self.plain.item(ws, item_id) is Some(_) {
      raise Refused("the item is there already")
    }
    self.plain.put(next)
    // Keeping it lets the chat that asked use it, for as long as the person's items are given.
    let lasts = match self.plain.lasts(ws, gtext(Some(next), "owner")) {
      Some((l, _)) => Some(l)
      None => None
    }
    let scope = if @vault_crypto.allows(lasts, Some(js("hour"))) { "hour" } else { "once" }
    let mode0 = match get(s, "modes") {
      Some(Array(a)) => js_text(a.get(0))
      _ => ""
    }
    let hd = [
      ("scope", js(scope)),
      ("hosts", if hosted(mode0) { get(s, "hosts").unwrap_or(Json::null()) } else { jarr([]) }),
      ("listing", get(Some(next), "listing").unwrap()),
      ("lasts", lasts.unwrap_or(Json::null())),
    ]
    if scope == "hour" {
      hd.push(("timeout", obj([("kind", js("idle")), ("seconds", jn(3600.0))])))
    }
    held = self.keeper.hold(
      current,
      obj(hd),
      obj([("kind", get(s, "kind").unwrap_or(Json::null())), ("name", get(s, "name").unwrap_or(Json::null())), ("fields", fields)]),
    )
  }) catch {
    Refused(m) => return Err(m)
    e => raise e
  }
  if !settled {
    return Err(self.decision_changed(k.request))
  }
  if held is Some(h) {
    self.w.warn("vault", "a kept secret's grant to its chat not held", obj([("why", js(h))]))
  }
  Ok(self.plain.item(ws, item_id).unwrap_or(Json::null()))
}

///|
/// A sign-in's state as the vault keeps it (browser/signins.ts `stateOf`): its cookies and its passkeys.
fn state_of(kept : String) -> (Array[Json], Array[Json]) {
  let v = parse_or_null(kept)
  match v {
    Array(a) => (a, [])
    _ => {
      let passkeys = match get(Some(v), "passkeys") {
        Some(Array(ps)) => ps.filter(p => passkey_of(p) is Some(_))
        _ => []
      }
      let cookies = match get(Some(v), "cookies") {
        Some(Array(cs)) => cs
        _ => []
      }
      (cookies, passkeys)
    }
  }
}

///|
/// A passkey as kept (browser/signins.ts `passkeyOf`): one with its credential's id, its site and its private key.
fn passkey_of(p : Json) -> Json? {
  match p {
    Object(_) =>
      if gs(Some(p), "credentialId") is Some(_) && gs(Some(p), "rpId") is Some(_) && gs(Some(p), "privateKey") is Some(_) {
        Some(p)
      } else {
        None
      }
    _ => None
  }
}
