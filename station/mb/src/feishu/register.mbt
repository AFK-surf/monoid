// Feishu apps made by a scan (station/src/feishu/register.ts, 「建机器人」): Feishu's one-click app registration, an
// OAuth device flow (RFC 8628) as its SDKs' `register_app` runs it. The person opens the link (or scans it as a QR
// code) in Feishu and confirms; the station asks until the app's id and secret come back, and keeps them for the
// connect made of them. The station keeps the device flow and the chosen connect settings until the app has been
// saved. A restart can then resume polling or retry the save without asking Feishu to create another app.
//
// A registration is kept as the object it is in the file (`JV`): what the TypeScript changed of it, field by field,
// is changed here in the same places, so the file is written as it wrote it. Its timers run on the runtime the
// registrations are made on.

///|
let registration_endpoint : String = "/oauth/v1/app/registration"

///|
/// What a connect's app is given, as the person confirms it.
pub fn addons() -> JV {
  let scopes = [
    "im:message", "im:message:send_as_bot", "im:message.group_msg", "im:message.p2p_msg:readonly",
    "im:message.group_at_msg:readonly", "im:resource", "im:chat:readonly", "im:chat.members:read",
    "contact:user.base:readonly", "contact:user.email:readonly", "contact:user.id:readonly",
    "cardkit:card:write", "tenant:tenant:readonly", "docx:document", "docx:document:readonly",
    "docs:doc:readonly", "wiki:wiki", "wiki:wiki:readonly", "drive:drive", "drive:drive:readonly",
    "sheets:spreadsheet", "sheets:spreadsheet:readonly", "bitable:app", "bitable:app:readonly",
    "docs:document.media:download", "docs:document.media:upload", "docs:document.comment:read",
    "docs:document.comment:create", "docs:permission.member:create", "board:whiteboard:node:read",
    "search:docs:read", "im:message.reactions:read", "im:message.reactions:write_only",
    "calendar:calendar:readonly", "task:task:read", "minutes:minutes:readonly",
  ]
  jobj([
    ("scopes", Some(jobj([("tenant", Some(Arr(scopes.map(js))))]))),
    (
      "events",
      Some(
        jobj([
          (
            "items",
            Some(jobj([("tenant", Some(Arr([js("im.message.receive_v1")])))])),
          ),
        ]),
      ),
    ),
    (
      "callbacks",
      Some(jobj([("items", Some(Arr([js("card.action.trigger")])))])),
    ),
  ])
}

///|
/// The addons as the registration's link takes them: JSON, gzipped, base64url without padding.
pub fn encode_addons(a : JV) -> String {
  base64url(gzip(utf8(stringify(a))))
}

///|
/// What the overview shows of one (never its secret).
pub fn shown_registration(r : JV) -> JV {
  let app_id = match jget(jget(Some(r), "app"), "appId") {
    None | Some(Null) => jget(Some(r), "appId")
    v => v
  }
  jobj([
    ("id", jget(Some(r), "id")),
    ("url", jget(Some(r), "url")),
    ("expiresAt", jget(Some(r), "expiresAt")),
    ("state", jget(Some(r), "state")),
    ("error", jget(Some(r), "error")),
    ("appId", app_id),
    ("domain", jget(Some(r), "domain")),
  ])
}

///|
/// A form's body (`new URLSearchParams(form)`).
fn form_body(form : Array[(String, String)]) -> Bytes {
  utf8(form.map(e => form_encode(e.0) + "=" + form_encode(e.1)).join("&"))
}

///|
/// The device flow's one request: its answer's JSON.
pub async fn registration_post(
  net : Net,
  domain : String,
  form : Array[(String, String)],
) -> JV {
  let url = url_with(accounts_base(net, domain) + registration_endpoint, [])
  let got = (net.fetch)({
    url,
    verb: "POST",
    headers: [("content-type", "application/x-www-form-urlencoded")],
    body: Some(form_body(form)),
    timeout_ms: 30_000,
  })
  let said = utf8_text(got.body, bom=true)
  match try_parse(said) {
    Some(j) => j
    None =>
      raise FeishuError(
        "feishu registration: HTTP \{got.status} \{slice_js(said, 0, b=200)}",
      )
  }
}

///|
/// One registration: the object kept for it (compared by which it is, as the TypeScript compared its objects).
pub struct Reg {
  r : JV
  priv key : String
}

///|
fn Reg::field(self : Reg, k : String) -> JV? {
  self.r.get(k)
}

///|
fn Reg::set(self : Reg, k : String, v : JV) -> Unit {
  jput(self.r, k, v)
}

///|
/// `r.k === null`.
fn Reg::is_null(self : Reg, k : String) -> Bool {
  self.r.get(k) == Some(Null)
}

///|
/// The key a registration's `id` is in the map by (a Map's SameValueZero: a string and a number apart, every object
/// its own).
fn id_key(v : JV?, n : Int) -> String {
  match v {
    None => "u"
    Some(Null) => "null"
    Some(Str(s)) => "s" + s
    Some(Num(d)) => "n" + num_text(if d == 0.0 { 0.0 } else { d })
    Some(Bool(b)) => "b" + b.to_string()
    Some(_) => "o" + n.to_string()
  }
}

///|
/// What the registrations are given (register.ts's options, and what the module gives them).
pub(all) struct RegistrationsOptions {
  /// The device flow's requests (tests: a stand-in's).
  post : async (String, Array[(String, String)]) -> JV
  /// Where they are kept (None: nowhere).
  file : String?
  disk : Disk
  log : Log
  words : Words
  /// `n` random bytes, as hex (a registration's id).
  random_hex : (Int) -> String
  /// The program's path, as a refusal of the file names it (`process.execPath`).
  exec_path : String
}

///|
pub struct Registrations {
  priv all : Map[String, Reg]
  priv listeners : Map[Int, () -> Unit]
  priv mut next_listener : Int
  priv rt : @effect.Runtime
  priv fibers : Array[@effect.Fiber[Unit]]
  priv options : RegistrationsOptions
  priv file : PrivateFile?
  /// Once what the file kept is known; what it failed with when it could not be read (nothing is written over it then).
  priv loading : @effect.Deferred[Unit]
  priv mut unread : Error?
  priv mut loaded : Bool
  priv mut create : (async (Reg) -> String)?
  priv completing : Map[String, @effect.Deferred[String]]
  priv mut started : Bool
  priv mut objects : Int
}

///|
/// Made on `rt`, reading what the file kept at once.
pub fn Registrations::new(
  rt : @effect.Runtime,
  options : RegistrationsOptions,
) -> Registrations {
  let self : Registrations = {
    all: Map([]),
    listeners: Map([]),
    next_listener: 0,
    rt,
    fibers: [],
    options,
    file: options.file.map(p => PrivateFile::new(options.disk, p)),
    loading: @effect.Deferred::new(),
    unread: None,
    loaded: false,
    create: None,
    completing: Map([]),
    started: false,
    objects: 0,
  }
  self.run(async fn() {
    let failed = try {
      self.read()
      None
    } catch {
      e => Some(e)
    }
    self.loaded = true
    match failed {
      None => ignore(self.loading.succeed(()))
      Some(e) => ignore(self.loading.fail(e))
    }
  })
  self
}

///|
/// A fiber of theirs (ended as they close).
fn Registrations::run(self : Registrations, f : async () -> Unit) -> Unit {
  let fiber = self.rt.fork(async fn() { f() catch { _ => () } })
  self.fibers.push(fiber)
}

///|
fn Registrations::key_of(self : Registrations, r : JV) -> String {
  self.objects += 1
  id_key(jget(Some(r), "id"), self.objects)
}

///|
async fn Registrations::read(self : Registrations) -> Unit {
  guard self.file is Some(file) else { return }
  let bytes = try {
    (self.options.disk.read)(file.path)
  } catch {
    e => {
      self.unread = Some(e)
      return
    }
  }
  guard bytes is Some(b) else { return }
  let saved = match try_parse(utf8_text(b)) {
    Some(s) => s
    None => {
      self.unread = Some(
        FeishuError(
          (self.options.words.tr)(
            (self.options.words.station_lang)(),
            "station.files.invalidJson",
            {
              "path": Json::string(file.path),
              "program": Json::string(self.options.exec_path),
            },
          ),
        ),
      )
      return
    }
  }
  guard saved is Arr(items) else {
    self.unread = Some(FeishuError("invalid feishu registration store"))
    return
  }
  // (one begun meanwhile kept as it is)
  for r in items {
    match r {
      Null => raise FeishuError("Cannot read properties of null (reading 'id')")
      _ => ()
    }
    let key = self.key_of(r)
    if !self.all.contains(key) {
      self.all[key] = { r, key }
    }
  }
}

///|
/// Once the registrations kept before are known (the routes resume them then: `start`).
pub async fn Registrations::ready(self : Registrations) -> Unit {
  self.loading.wait()
}

///|
/// Written off the station's thread (all of them as they are then): once it is. Never over a file that could not be
/// read: what it keeps would be lost.
async fn Registrations::persist(self : Registrations) -> Unit {
  guard self.file is Some(file) else { return }
  if !self.loaded {
    self.loading.wait()
    return self.persist()
  }
  match self.unread {
    Some(e) => raise e
    None => ()
  }
  let all = JV::Arr(self.all.values().map(x => x.r).collect())
  file.write(stringify(all) + "\n").wait()
}

///|
/// Once what was changed is written down (or failed).
pub async fn Registrations::written(self : Registrations) -> Unit {
  self.loading.wait()
  match self.file {
    Some(f) => f.written()
    None => ()
  }
}

///|
/// `persist`, no one waiting: said in the log when it did not go.
fn Registrations::persist_soon(self : Registrations, id : JV?) -> Unit {
  self.run(async fn() {
    self.persist() catch {
      e =>
        self.options.log.warn(
          "feishu",
          "feishu registration not stored",
          jobj([("id", id), ("error", Some(js(error_words(e))))]),
        )
    }
  })
}

///|
/// Set once the routes are ready, then resume unfinished registrations from before a restart (once they are read).
pub fn Registrations::start(
  self : Registrations,
  create : async (Reg) -> String,
) -> Unit {
  self.create = Some(create)
  if self.started {
    return
  }
  self.started = true
  self.run(async fn() {
    self.loading.wait()
    self.resume_kept()
  })
}

///|
fn Registrations::resume_kept(self : Registrations) -> Unit {
  match self.unread {
    Some(e) =>
      self.options.log.error(
        "feishu",
        "feishu registrations not read",
        jobj([("error", Some(js(error_words(e))))]),
      )
    None => ()
  }
  for r in self.all.values().collect() {
    let state = r.field("state")
    if state == Some(Str("waiting")) && !r.is_null("deviceCode") {
      let code = r.field("deviceCode")
      let interval = r.field("interval")
      self.run(async fn() { self.ask(r, code, interval) })
    } else if state == Some(Str("done")) &&
      !r.is_null("app") &&
      !r.is_null("context") {
      self.run(async fn() { self.auto_save(r) })
    } else if state != Some(Str("waiting")) && r.is_null("app") {
      self.expire_later(r)
    }
  }
}

///|
/// Hears each change; gives the function that stops it.
pub fn Registrations::on_change(
  self : Registrations,
  listener : () -> Unit,
) -> () -> Unit {
  let n = self.next_listener
  self.next_listener += 1
  self.listeners[n] = listener
  () => self.listeners.remove(n)
}

///|
fn Registrations::changed(self : Registrations) -> Unit {
  for _, l in self.listeners {
    l()
  }
}

///|
/// Those `by` began (in `workspace`, or in none).
pub fn Registrations::of(
  self : Registrations,
  by : String,
  workspace? : String,
) -> Array[JV] {
  self.all
  .values()
  .filter(x => {
    let r = x.r
    jget(Some(r), "by") == Some(Str(by)) &&
    (match workspace {
      None => true
      Some(w) => {
        let at = jget(Some(r), "workspace")
        at == Some(Null) || at == Some(Str(w))
      }
    })
  })
  .map(x => x.r)
  .collect()
}

///|
pub fn Registrations::get(self : Registrations, id : String) -> Reg? {
  self.all.get("s" + id)
}

///|
/// Everything kept, in order.
pub fn Registrations::all_jv(self : Registrations) -> JV {
  Arr(self.all.values().map(x => x.r).collect())
}

///|
/// Begins one for `by`: its link once Feishu gave it; the station asks on from then.
pub async fn Registrations::begin(
  self : Registrations,
  by : String,
  domain : String,
  name : String?,
  context? : JV = Null,
  workspace? : String? = None,
) -> Reg {
  let init = (self.options.post)(domain, [("action", "init")])
  let methods = jitems(jget(Some(init), "supported_auth_methods"))
  if !methods.contains(Str("client_secret")) {
    raise FeishuError("feishu registration: client_secret is not offered")
  }
  let begun = (self.options.post)(domain, [
    ("action", "begin"),
    ("archetype", "PersonalAgent"),
    ("auth_method", "client_secret"),
    ("request_user_info", "open_id"),
  ])
  let device_code = text(jget(Some(begun), "device_code"))
  let uri = text(jget(Some(begun), "verification_uri_complete"))
  if device_code == "" || uri == "" {
    let why = match jget(Some(begun), "error_description") {
      None | Some(Null) =>
        match jget(Some(begun), "error") {
          None | Some(Null) => "no device code"
          e => js_string(e)
        }
      d => js_string(d)
    }
    raise FeishuError("feishu registration: \{why}")
  }
  let query = [("from", "sdk"), ("tp", "sdk"), ("source", "still.fail")]
  match name {
    Some(n) if n != "" => query.push(("name", n))
    _ => ()
  }
  query.push(("addons", encode_addons(addons())))
  let link = url_with(uri, query)
  let now = @effect.now().to_double()
  let expires_in = jnumber(jget(Some(begun), "expires_in")).unwrap_or(600.0)
  let r = jobj([
    ("id", Some(js((self.options.random_hex)(6)))),
    ("by", Some(js(by))),
    ("url", Some(js(link))),
    ("expiresAt", Some(Num(now + expires_in * 1000.0))),
    ("state", Some(js("waiting"))),
    ("error", Some(Null)),
    ("domain", Some(js(domain))),
    ("app", Some(Null)),
    ("appId", Some(Null)),
    ("deviceCode", Some(js(device_code))),
    ("interval", Some(Num(jnumber(jget(Some(begun), "interval")).unwrap_or(5.0)))),
    ("workspace", Some(jopt(workspace))),
    ("context", Some(context)),
    ("connectId", Some(Null)),
  ])
  let key = id_key(r.get("id"), 0)
  let reg : Reg = { r, key }
  self.all[key] = reg
  self.persist() catch {
    e => {
      self.all.remove(key)
      raise e
    }
  }
  self.changed()
  let code = r.get("deviceCode")
  let interval = r.get("interval")
  self.run(async fn() { self.ask(reg, code, interval) })
  reg
}

///|
/// Whether `r` is still the one kept under its id.
fn Registrations::holds(self : Registrations, r : Reg) -> Bool {
  match self.all.get(r.key) {
    Some(x) => physical_equal(x, r)
    None => false
  }
}

///|
/// What a sleep of `v` seconds is (`Effect.sleep(every * 1000)`).
fn seconds_ms(v : JV?) -> Int {
  let n = match v {
    Some(x) => js_to_number(x)
    None => @double.not_a_number
  }
  if is_finite(n) && n > 0.0 {
    (n * 1000.0).to_int()
  } else {
    0
  }
}

///|
async fn Registrations::ask(
  self : Registrations,
  r : Reg,
  device_code : JV?,
  interval : JV?,
) -> Unit {
  let mut every = interval
  let mut switched = false
  while true {
    @effect.sleep(seconds_ms(every))
    if !self.holds(r) {
      return
    }
    let now = @effect.now().to_double()
    match r.field("expiresAt") {
      Some(Num(at)) if now >= at => return self.end(r, "expired", None)
      Some(Str(at)) if now >= js_number(at) => return self.end(r, "expired", None)
      _ => ()
    }
    let said = try {
      let domain = js_string(r.field("domain"))
      Ok((self.options.post)(domain, [
        ("action", "poll"),
        ("device_code", js_string(device_code)),
      ]))
    } catch {
      e => Err(e)
    }
    if !self.holds(r) {
      return
    }
    let d = match said {
      Ok(d) => d
      Err(e) => {
        self.options.log.warn(
          "feishu",
          "feishu registration not asked",
          jobj([("error", Some(js(error_words(e))))]),
        )
        continue
      }
    }
    match (jget(Some(d), "client_id"), jget(Some(d), "client_secret")) {
      (Some(Str(id)), Some(Str(secret))) => {
        let open_id = match jget(jget(Some(d), "user_info"), "open_id") {
          Some(Str(o)) => JV::Str(o)
          _ => JV::Null
        }
        r.set(
          "app",
          jobj([
            ("appId", Some(js(id))),
            ("appSecret", Some(js(secret))),
            ("openId", Some(open_id)),
          ]),
        )
        r.set("appId", js(id))
        r.set("deviceCode", Null)
        r.set("state", js("done"))
        // Do not lose the only copy if the journal cannot be written yet. Keep retrying before attempting the save.
        while true {
          let stored = try {
            self.persist()
            None
          } catch {
            e => Some(e)
          }
          match stored {
            None => break
            Some(e) => {
              self.options.log.warn(
                "feishu",
                "feishu registration not stored; retrying",
                jobj([
                  ("id", r.field("id")),
                  ("error", Some(js(error_words(e)))),
                ]),
              )
              @effect.sleep(5000)
            }
          }
        }
        self.end(r, "done", None)
        if !r.is_null("context") {
          self.auto_save(r)
        }
        return
      }
      _ => ()
    }
    if jget(jget(Some(d), "user_info"), "tenant_brand") == Some(Str("lark")) &&
      !switched &&
      r.field("domain") != Some(Str("lark")) {
      switched = true
      r.set("domain", js("lark"))
      self.persist_soon(r.field("id"))
      continue
    }
    let error = text(jget(Some(d), "error"))
    if error == "authorization_pending" || error == "" {
      continue
    }
    if error == "slow_down" {
      let next = match every {
        Some(Num(n)) => JV::Num(n + 5.0)
        Some(Str(s)) => JV::Str(s + "5")
        other => JV::Num(js_to_number(or_null(other)) + 5.0)
      }
      every = Some(next)
      r.set("interval", next)
      self.persist_soon(r.field("id"))
    } else if error == "access_denied" {
      return self.end(r, "denied", None)
    } else if error == "expired_token" {
      return self.end(r, "expired", None)
    } else {
      let description = match jget(Some(d), "error_description") {
        None | Some(Null) => ""
        x => js_string(x)
      }
      return self.end(r, "failed", Some(trim_js("\{error} \{description}")))
    }
  }
}

///|
fn Registrations::end(
  self : Registrations,
  r : Reg,
  state : String,
  error : String?,
) -> Unit {
  r.set("state", js(state))
  r.set("error", jopt(error))
  if state != "waiting" {
    r.set("deviceCode", Null)
  }
  self.persist_soon(r.field("id"))
  // (`...(r.app ? { app: r.app.appId } : {})`: an app's id where it is an object that has one)
  let app = match r.field("app") {
    Some(Obj(_) as a) => a.get("appId")
    _ => None
  }
  let fields = jobj([("id", r.field("id")), ("state", Some(js(state)))])
  match app {
    Some(a) => jput(fields, "app", a)
    None => ()
  }
  self.options.log.info("feishu", "feishu registration ended", fields)
  self.changed()
  if state != "done" {
    self.expire_later(r)
  }
}

///|
/// Finished receipts and failed scans need not retain links indefinitely. Unsaved apps never expire here.
fn Registrations::expire_later(self : Registrations, r : Reg) -> Unit {
  self.run(async fn() {
    let now = @effect.now().to_double()
    let at = match r.field("expiresAt") {
      Some(Num(n)) => n
      _ => @double.not_a_number
    }
    let wait = at + 24.0 * 60.0 * 60_000.0 - now
    @effect.sleep(if wait > 0.0 { wait.to_int() } else { 0 })
    while self.holds(r) && r.is_null("app") {
      let key = r.key
      self.all.remove(key)
      let stored = try {
        self.persist()
        None
      } catch {
        e => Some(e)
      }
      match stored {
        None => {
          self.changed()
          return
        }
        Some(e) => {
          if !self.all.contains(key) {
            self.all[key] = r
          }
          self.options.log.warn(
            "feishu",
            "feishu registration not removed",
            jobj([("id", r.field("id")), ("error", Some(js(error_words(e))))]),
          )
          @effect.sleep(60_000)
        }
      }
    }
  })
}

///|
pub async fn Registrations::cancel(
  self : Registrations,
  id : String,
  by : String,
  workspace? : String,
) -> Bool {
  let key = "s" + id
  guard self.all.get(key) is Some(r) else { return false }
  if r.field("by") != Some(Str(by)) ||
    (match workspace {
      Some(w) => !r.is_null("workspace") && r.field("workspace") != Some(Str(w))
      None => false
    }) ||
    r.field("state") == Some(Str("done")) ||
    !r.is_null("context") {
    return false
  }
  self.all.remove(key)
  self.persist() catch {
    e => {
      if !self.all.contains(key) {
        self.all[key] = r
      }
      raise e
    }
  }
  self.changed()
  true
}

///|
/// One save at a time, shared by the background worker and requests from older clients. Keep the app on any failure.
pub async fn Registrations::complete(
  self : Registrations,
  id : String,
  by : String,
  workspace : String,
  save : async (Reg) -> String,
) -> String? {
  let key = "s" + id
  guard self.all.get(key) is Some(r) else { return None }
  if r.field("by") != Some(Str(by)) ||
    (!r.is_null("workspace") && r.field("workspace") != Some(Str(workspace))) ||
    r.field("state") != Some(Str("done")) {
    return None
  }
  if !r.is_null("connectId") {
    return Some(js_string(r.field("connectId")))
  }
  if r.is_null("app") {
    return None
  }
  match self.completing.get(id) {
    Some(d) => return Some(d.wait())
    None => ()
  }
  let d : @effect.Deferred[String] = @effect.Deferred::new()
  self.completing[id] = d
  let done = try {
    let connect_id = save(r)
    let app = or_null(r.field("app"))
    let context = or_null(r.field("context"))
    let url = or_null(r.field("url"))
    r.set("connectId", js(connect_id))
    r.set("app", Null)
    r.set("context", Null)
    r.set("url", js(""))
    self.persist() catch {
      e => {
        r.set("connectId", Null)
        r.set("app", app)
        r.set("context", context)
        r.set("url", url)
        raise e
      }
    }
    self.changed()
    self.expire_later(r)
    Ok(connect_id)
  } catch {
    e => Err(e)
  }
  self.completing.remove(id)
  match done {
    Ok(c) => {
      ignore(d.succeed(c))
      Some(c)
    }
    Err(e) => {
      ignore(d.fail(e))
      raise e
    }
  }
}

///|
async fn Registrations::auto_save(self : Registrations, r : Reg) -> Unit {
  let mut retry_ms = 5000
  while self.holds(r) && !r.is_null("context") && r.is_null("connectId") {
    guard self.create is Some(create) else { return }
    let workspace = match r.field("workspace") {
      None | Some(Null) => ""
      w => js_string(w)
    }
    let result = try {
      ignore(
        self.complete(
          js_string(r.field("id")),
          js_string(r.field("by")),
          workspace,
          create,
        ),
      )
      None
    } catch {
      e => Some(e)
    }
    match result {
      None => return
      Some(e) => {
        self.options.log.warn(
          "feishu",
          "feishu connect not saved; retrying",
          jobj([("id", r.field("id")), ("error", Some(js(error_words(e))))]),
        )
        @effect.sleep(retry_ms)
        retry_ms = @cmp.minimum(retry_ms * 2, 300_000)
      }
    }
  }
}

///|
/// Their fibers ended, then what was changed written down.
pub async fn Registrations::close(self : Registrations) -> Unit {
  for f in self.fibers {
    f.interrupt()
  }
  self.written()
}

///|
/// The object kept for one.
pub fn Reg::jv(self : Reg) -> JV {
  self.r
}
