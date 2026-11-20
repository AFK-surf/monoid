// adb/grants.ts: a chat's grant of a person's phone (2026-10-29: as vault grants are). An agent asks with
// `phone_use {reason}`, a card in its chat asks the person it works for (whoever started the chat), and they approve it
// for this chat for a time or until the chat is archived, or refuse it, from their app. Only that chat's session holds
// the grant; it ends as its scope does, as the chat is archived or deleted, or as its owner takes it back. Asks,
// decisions and ends are told in the chat; the owner's devices hear of the grants (`adb-grants`), and their phone lends
// itself to the station while one is live.
//
// A request is kept as the TypeScript keeps it: its body the JSON of an object whose fields are in the order they were
// first set (`Req`), so the two write the same rows.

///|
/// How long a grant lasts: `hour` fixed an hour, `idle` until the chat has used the phone for nothing for an hour,
/// `eight` fixed eight hours, `chat` until the chat is archived.
pub let scopes : Array[String] = ["hour", "idle", "eight", "chat"]

///|
/// How long a scope lasts at most (seconds): `chat` and `idle` 30 days at the latest.
pub fn lasts(scope : String) -> Double {
  match scope {
    "hour" => 3600.0
    "eight" => 8.0 * 3600.0
    _ => 30.0 * 86400.0
  }
}

///|
/// An idle grant ends once its chat has used the phone for nothing this long (ms).
pub let idle_for_ms : Double = 3600000.0

///|
fn scope_words(s : String) -> (String, String) {
  match s {
    "hour" =>
      (
        "本对话 1 小时内", "1 小时内这个对话的 agent 可以用这台手机",
      )
    "idle" =>
      (
        "闲置 1 小时后失效", "这个对话 1 小时不用这台手机就失效，最长 30 天",
      )
    "eight" =>
      (
        "本对话 8 小时内", "8 小时内这个对话的 agent 可以用这台手机",
      )
    _ =>
      (
        "本对话直到归档", "这个对话归档或删除前都能用，最长 30 天",
      )
  }
}

///|
/// Whether `s` is a scope.
pub fn is_scope(s : J?) -> Bool {
  match s {
    Some(Str(_)) => scopes.contains(text_of(s))
    _ => false
  }
}

///|
/// The most a grant's signature takes (bytes of JSON).
let signed_max : Int = 4096

///|
/// The ways the station's adb holds a phone that are said on its card and told to the agent.
let links : Array[String] = [
  "connected", "unpaired", "off", "unauthorized", "missing", "failed", "gone",
]

///|
pub let title_member_probe : String =
  #|WITH candidates AS MATERIALIZED
  #|  (SELECT session,joined_at,rowid AS member_rowid FROM thread_sessions WHERE thread=?1 LIMIT ?2)
  #|  SELECT session FROM candidates ORDER BY joined_at,member_rowid

///|
pub let title_shown_members : String =
  #|SELECT m.session FROM json_each(?2) j CROSS JOIN thread_sessions m
  #|  ON m.thread=?1 AND m.session=j.value ORDER BY m.joined_at,m.rowid

///|
pub let title_one_member : String = "SELECT session FROM thread_sessions WHERE thread=?1 AND session=?2"

///|
let grants_schema : String =
  #|CREATE TABLE IF NOT EXISTS adb_requests (
  #|  id TEXT PRIMARY KEY,
  #|  session TEXT NOT NULL,
  #|  owner TEXT NOT NULL,
  #|  status TEXT NOT NULL,
  #|  body TEXT NOT NULL
  #|);
  #|CREATE INDEX IF NOT EXISTS adb_requests_by_owner ON adb_requests (owner, status);
  #|CREATE INDEX IF NOT EXISTS adb_requests_by_session ON adb_requests (session, status);
  #|-- (each owner's 默认最长授权 of before, read no longer: kept, as the schema only goes forward)
  #|CREATE TABLE IF NOT EXISTS adb_lasts (
  #|  owner TEXT PRIMARY KEY,
  #|  lasts TEXT NOT NULL,
  #|  at INTEGER NOT NULL
  #|);
  #|-- (what the owner's devices signed to take a grant back, kept until the grant would have ended: given to their devices
  #|-- as they read their grants, told to them as it comes, the grant's own station or another of theirs)
  #|CREATE TABLE IF NOT EXISTS adb_revokes (
  #|  id TEXT PRIMARY KEY, -- owner, a space, request: another member naming the same request keeps a row of their own
  #|  owner TEXT NOT NULL,
  #|  exp INTEGER NOT NULL,
  #|  body TEXT NOT NULL
  #|);
  #|CREATE INDEX IF NOT EXISTS adb_revokes_by_owner ON adb_revokes (owner, exp);

///|
/// How large a signed taking back is kept at most (its JSON's length), and how many of an owner's at most (those that
/// end first let go).
pub let signed_revoke_max : Int = 4096

///|
pub let revokes_per_owner_max : Int = 256

///|
/// A phone request as kept: an object whose fields keep the order they were first set in.
pub struct Req {
  mut v : J
}

///|
pub fn Req::new(v : J) -> Req {
  { v, }
}

///|
pub fn Req::get(self : Req, k : String) -> J? {
  at(Some(self.v), k)
}

///|
pub fn Req::text(self : Req, k : String) -> String {
  text_of(self.get(k))
}

///|
pub fn Req::num(self : Req, k : String) -> Double? {
  match self.get(k) {
    Some(Num(d)) => Some(d)
    _ => None
  }
}

///|
pub fn Req::set(self : Req, k : String, v : J) -> Unit {
  self.v = set_field(self.v, k, v)
}

///|
pub fn Req::delete(self : Req, k : String) -> Unit {
  self.v = without(self.v, [k])
}

///|
pub fn Req::id(self : Req) -> String {
  self.text("id")
}

///|
pub fn Req::session(self : Req) -> String {
  self.text("session")
}

///|
pub fn Req::owner(self : Req) -> String {
  self.text("owner")
}

///|
pub fn Req::status(self : Req) -> String {
  self.text("status")
}

///|
pub fn Req::copy(self : Req) -> Req {
  { v: self.v, }
}

///|
/// A grant's chat named, as shown (`chatTitle`).
pub struct PhoneGrants {
  w : World
  db : @sql.Db
  /// The chat's current name, or None before it has one.
  title : async (Req) -> String?
  /// Who hears of a change (the owner's devices).
  told : async (J, J, String) -> Unit
  /// A signed taking back kept (`keep_revoke`): told to its owner's devices (`adb-revoke`): signed, owner, request,
  /// workspace.
  told_revoke : (async (J, String, String, String) -> Unit)?
  /// Whether the station keeps cards' outcomes in its outbox (`cardOutcomes`).
  outcomes : Bool
  titles : Map[String, (String, String?)]
  shown_by_session : Map[String, Array[String]]
  used_at : Map[String, Double]
}

///|
fn sql_j(v : J) -> Json {
  match v {
    Str(u) => Json::string(@jsjson.sanitize_str(u))
    Num(d) => Json::number(d)
    Bool(b) => Json::boolean(b)
    _ => Json::null()
  }
}

///|
fn sql_err(e : Error) -> Error {
  fail_(e.to_string())
}

///|
/// The grants, their table made where it is not.
pub fn PhoneGrants::new(
  w : World,
  db : @sql.Db,
  title : async (Req) -> String?,
  told : async (J, J, String) -> Unit,
  outcomes~ : Bool = false,
  told_revoke? : async (J, String, String, String) -> Unit,
) -> PhoneGrants raise {
  db.exec(grants_schema) catch {
    e => raise sql_err(e)
  }
  {
    w,
    db,
    title,
    told,
    told_revoke,
    outcomes,
    titles: {},
    shown_by_session: {},
    used_at: {},
  }
}

///|
fn PhoneGrants::secs(self : PhoneGrants) -> Double {
  ((self.w.now)() / 1000.0).floor()
}

///|
async fn PhoneGrants::ended(self : PhoneGrants, session : String) -> Bool {
  let row = self.w.store("getSession", [js(session)])
  row is Null || !nullish(at(Some(row), "archivedAt"))
}

///|
/// A grant belongs to its chat's workspace, not to the chat's directory on disk.
async fn PhoneGrants::workspace(self : PhoneGrants, r : Req) -> J {
  let row = self.w.store("getSession", [js(r.session())])
  match at(Some(row), "ws") {
    Some(Null) | None => self.w.ask("grants.home", [])
    Some(ws) => ws
  }
}

///|
/// What a store change does to the grants (the constructor's subscription).
pub async fn PhoneGrants::changed(self : PhoneGrants, c : J) -> Unit {
  let type_ = text_of(at(Some(c), "type"))
  let key = at(Some(c), "key")
  if (type_ == "sessionRemoved" || type_ == "session") &&
    key is Some(Str(_)) &&
    self.ended(text_of(key)) {
    // A removed session's row is already gone; the change carries its workspace.
    let workspace : J? = if type_ == "sessionRemoved" {
      match at(Some(c), "ws") {
        Some(Null) | None => Some(self.w.ask("grants.home", []))
        Some(ws) => Some(ws)
      }
    } else {
      None
    }
    for r in self.by_session(text_of(key)) {
      self.end(r, "对话已归档", workspace~)
    }
  } else if type_ == "thread" &&
    at(Some(c), "id") is Some(Num(_)) &&
    self.titles.length() > 0 {
    // A renamed chat changes its list entry even when no adb command is run. Only requests whose titles have been
    // shown can need an update.
    let id = num_of(at(Some(c), "id")).unwrap()
    let count = self.shown_by_session.length()
    let members : Array[String] = if count == 1 {
      let session = self.shown_by_session.keys().collect()[0]
      self
      .rows(title_one_member, [jn(id), js(session)])
      .map(row => text_of(at(Some(row), "session")))
    } else {
      let candidates = self.rows(title_member_probe, [jn(id), ji(count + 1)])
      if candidates.length() <= count {
        candidates.map(row => text_of(at(Some(row), "session")))
      } else {
        let keys = jsa(self.shown_by_session.keys().collect())
        self
        .rows(title_shown_members, [jn(id), js(stringify(keys))])
        .map(row => text_of(at(Some(row), "session")))
      }
    }
    for session in members {
      guard self.shown_by_session.get(session) is Some(shown) &&
        shown.length() > 0 else {
        continue
      }
      let requests = self.load(
        (
          #|SELECT r.body FROM json_each(?1) j CROSS JOIN adb_requests r ON r.id=j.value
          #|            WHERE r.session=?2 AND r.status IN ('pending', 'granted') ORDER BY r.status,r.rowid
        ),
        [js(stringify(jsa(shown))), js(session)],
      )
      for r in requests {
        let title = (self.title)(r)
        match self.titles.get(r.id()) {
          Some((_, before)) if before != title => self.tell(r, "title")
          _ => ()
        }
      }
    }
  }
}

///|
fn PhoneGrants::rows(
  self : PhoneGrants,
  sql : String,
  args : Array[J],
) -> Array[J] raise {
  let rows = self.db.all(sql, args.map(sql_j)) catch { e => raise sql_err(e) }
  rows.map(row => {
    let fields = []
    for k, v in row {
      fields.push(
        (
          k,
          match v {
            String(s) => js(s)
            Number(d, ..) => jn(d)
            _ => J::Null
          },
        ),
      )
    }
    jo(fields)
  })
}

///|
/// A title is read from the chat, so it follows renames and is never a stale copy in the grant record.
pub async fn PhoneGrants::shown(self : PhoneGrants, r : Req) -> J {
  let chat_title = (self.title)(r)
  match self.titles.get(r.id()) {
    Some((session, _)) if session != r.session() => self.forget_title(r.id())
    _ => ()
  }
  self.titles[r.id()] = (r.session(), chat_title)
  let shown = match self.shown_by_session.get(r.session()) {
    Some(s) => s
    None => {
      let s = []
      self.shown_by_session[r.session()] = s
      s
    }
  }
  if !shown.contains(r.id()) {
    shown.push(r.id())
  }
  set_field(r.v, "chatTitle", jopt(chat_title))
}

///|
fn PhoneGrants::forget_title(self : PhoneGrants, id : String) -> Unit {
  guard self.titles.get(id) is Some((session, _)) else { return }
  self.titles.remove(id)
  match self.shown_by_session.get(session) {
    Some(shown) => {
      match shown.search(id) {
        Some(i) => ignore(shown.remove(i))
        None => ()
      }
      if shown.length() == 0 {
        self.shown_by_session.remove(session)
      }
    }
    None => ()
  }
}

///|
async fn PhoneGrants::tell(
  self : PhoneGrants,
  r : Req,
  change : String,
  workspace? : J?,
) -> Unit {
  let shown = self.shown(r)
  let ws = match workspace {
    Some(Some(ws)) => ws
    _ => self.workspace(r)
  }
  (self.told)(shown, ws, change)
}

///|
/// A service of a grant's is in use. Long streams can send many packets; announced at most once a second, but every
/// new or closed service at once, so another chat's more recent command can reorder the list.
pub async fn PhoneGrants::used(
  self : PhoneGrants,
  id : String,
  force : Bool,
) -> Unit {
  let now = (self.w.now)().floor()
  let previous = self.used_at.get(id)
  if !force && previous is Some(p) && now >= p && now - p < 1000.0 {
    return
  }
  guard self.get(id) is Some(r) else { return }
  if r.status() != "granted" || !self.live(r) {
    return
  }
  if r.num("lastUsedAt") == Some(now) {
    return
  }
  r.set("lastUsedAt", jn(now))
  self.used_at[id] = now
  self.save(r)
  self.tell(r, "used")
}

///|
fn PhoneGrants::save(self : PhoneGrants, r : Req) -> Unit raise {
  // Titles are read from the chat, so a later rename is reflected in every grant.
  let body = without(r.v, ["chatTitle"])
  ignore(
    self.db.run(
      "INSERT INTO adb_requests (id, session, owner, status, body) VALUES (?, ?, ?, ?, ?) ON CONFLICT (id) DO UPDATE SET status = excluded.status, body = excluded.body",
      [
        sql_j(r.get("id").unwrap_or(Null)),
        sql_j(r.get("session").unwrap_or(Null)),
        sql_j(r.get("owner").unwrap_or(Null)),
        sql_j(r.get("status").unwrap_or(Null)),
        Json::string(stringify(body)),
      ],
    ),
  ) catch {
    e => raise sql_err(e)
  }
}

///|
fn PhoneGrants::load(
  self : PhoneGrants,
  sql : String,
  args : Array[J],
) -> Array[Req] raise {
  self
  .rows(sql, args)
  .map(row => Req::new(@session_chats.parse_js(text_of(at(Some(row), "body")))))
}

///|
pub fn PhoneGrants::get(self : PhoneGrants, id : String) -> Req? raise {
  self.load("SELECT body FROM adb_requests WHERE id = ?", [js(id)]).get(0)
}

///|
/// A granted request whose scope ran out is ended as it is read.
async fn PhoneGrants::live(self : PhoneGrants, r : Req) -> Bool {
  if r.status() != "granted" {
    return r.status() == "pending"
  }
  let exp = r.num("exp").unwrap_or(0.0)
  if exp <= self.secs() || self.ended(r.session()) {
    self.end(
      r,
      if exp <= self.secs() {
        "授权已到期"
      } else {
        "对话已归档"
      },
    )
    return false
  }
  // (an idle one: since it was last used, or granted)
  if r.text("scope") == "idle" {
    let since = match r.num("lastUsedAt") {
      Some(u) => u
      None =>
        (r.num("exp").unwrap_or(@double.not_a_number) - lasts("idle")) * 1000.0
    }
    if since + idle_for_ms <= (self.w.now)() {
      self.end(r, "闲置超时")
      return false
    }
  }
  true
}

///|
fn PhoneGrants::by_session(
  self : PhoneGrants,
  session : String,
) -> Array[Req] raise {
  self.load(
    "SELECT body FROM adb_requests WHERE session = ? AND status IN ('pending', 'granted')",
    [js(session)],
  )
}

///|
/// The grants live for `session` (the agent's).
pub async fn PhoneGrants::held(
  self : PhoneGrants,
  session : String,
) -> Array[Req] {
  let out = []
  for
    r in self.load(
      "SELECT body FROM adb_requests WHERE session = ? AND status = 'granted'",
      [js(session)],
    ) {
    if r.status() == "granted" && self.live(r) {
      out.push(r)
    }
  }
  out
}

///|
/// Those of `owner` (their devices': which chats their phone is lent to), as shown.
pub async fn PhoneGrants::of_owner(
  self : PhoneGrants,
  owner : String,
  workspace? : String,
) -> Array[J] {
  let out = []
  for
    r in self.load(
      "SELECT body FROM adb_requests WHERE owner = ? AND status IN ('pending', 'granted')",
      [js(owner.to_lower())],
    ) {
    let keep = match workspace {
      None => true
      Some(ws) => jeq(self.workspace(r), js(ws))
    }
    if keep && self.live(r) {
      out.push(self.shown(r))
    }
  }
  out
}

///|
/// The live grants of `owner`, for the phone's link: no pending requests, no titles.
pub async fn PhoneGrants::granted_of_owner(
  self : PhoneGrants,
  owner : String,
) -> Array[Req] {
  let out = []
  for
    r in self.load(
      "SELECT body FROM adb_requests WHERE owner = ? AND status = 'granted'",
      [js(owner.to_lower())],
    ) {
    if r.status() == "granted" && self.live(r) {
      out.push(r)
    }
  }
  out
}

///|
/// Every grant live now, of everyone.
pub async fn PhoneGrants::live_all(self : PhoneGrants) -> Array[Req] {
  let out = []
  for
    r in self.load("SELECT body FROM adb_requests WHERE status = 'granted'", []) {
    if self.live(r) {
      out.push(r)
    }
  }
  out
}

///|
/// The person a session works for: whoever started its chat.
pub async fn PhoneGrants::starter(
  self : PhoneGrants,
  session : String,
) -> String? {
  str_of(Some(self.w.store("starter", [js(session)])))
}

///|
/// phone_use: a grant of this session's already live, or a request asked in its chat: not waited for, its decision
/// told to the session. `of`: whose phone; none, the person the chat's agent works for.
pub async fn PhoneGrants::ask(
  self : PhoneGrants,
  session : String,
  reason : String,
  reask~ : Bool = false,
  of? : String,
) -> Req {
  let owner = match of {
    Some(o) => Some(o.to_lower())
    None => self.starter(session)
  }
  guard owner is Some(owner) else {
    raise refused(
      "Refused", "this chat has no person who started it: nobody to lend a phone",
    )
  }
  for held in self.held(session) {
    if held.owner() == owner {
      return held
    }
  }
  if js_trim(reason) == "" {
    raise refused("Refused", "say why you need the phone (reason)")
  }
  let pending = self
    .load(
      "SELECT body FROM adb_requests WHERE session = ? AND owner = ? AND status = 'pending' ORDER BY rowid LIMIT 1",
      [js(session), js(owner)],
    )
    .get(0)
  // A still-joined original chat already proves the session has a chat. A reused request does not need to choose the
  // latest one: a reasked card goes back to its original place. Older requests may not record that place.
  let original = match pending {
    Some(p) if !nullish(p.get("thread")) =>
      self.w.store("sessionThreadById", [js(session), p.get("thread").unwrap()])
    _ => Null
  }
  let mut thread = original
  if thread is Null {
    if self.w.hub_has("prepareLatestThreads") &&
      self.w.store_has("latestThreadIfReady") {
      let found = self.w.store("latestThreadIfReady", [js(session)])
      if undefined(found) {
        ignore(self.w.ask("hub.prepareLatestThreads", [jsa([session])]))
        if self.ended(session) {
          raise refused("Refused", "this chat is archived or gone")
        }
        // A request, a grant, or a new delivery may have arrived while the old order was prepared.
        return self.ask(session, reason, reask~, of?)
      }
      thread = found
    } else {
      thread = self.w.store("latestThread", [js(session)])
    }
  }
  if thread is Null {
    raise refused("Refused", "this session has no chat to ask in")
  }
  let r = match pending {
    Some(p) => p
    None => {
      let id = match self.w.ask("grants.id", []) {
        Str(_) as s => s
        _ => js(fresh_id((self.w.now)()))
      }
      let row = get(thread, "thread")
      Req::new(
        jo([
          ("id", id),
          ("session", js(session)),
          (
            "chat",
            js(
              text_of(at(Some(row), "channel")) +
              "/" +
              text_of(at(Some(row), "threadTs")),
            ),
          ),
          ("owner", js(owner)),
          ("reason", js(js_trim(reason))),
          ("at", jn(self.secs())),
          ("status", js("pending")),
        ]),
      )
    }
  }
  if pending is Some(_) && reask {
    let place = card_place(
      self.w,
      session,
      r.get("thread").unwrap_or(Null),
      r.get("cardTs").unwrap_or(Null),
    )
    match place {
      None => {
        if !self.w.hub_has("prepareCardPosts") || nullish(r.get("thread")) {
          raise refused("Refused", "card lookup is not ready")
        }
        ignore(
          self.w.ask("hub.prepareCardPosts", [ja([r.get("thread").unwrap()])]),
        )
        guard self.get(r.id()) is Some(current) else {
          raise refused("Refused", "the phone request is no longer pending")
        }
        if current.status() != "pending" {
          return current
        }
        if self.ended(session) {
          raise refused("Refused", "this chat is archived or gone")
        }
        return self.ask(session, reason, reask~, of?)
      }
      Some(Null) => ()
      Some(place) =>
        match text_of(at(Some(place), "state")) {
          "other" => raise refused("Refused", card_occupied)
          "none" => {
            let where_ = get(place, "thread")
            let posted = self.post(session, where_, r, require_empty=true)
            let current = self.get(r.id())
            // A person may have decided the original request while the post was being sent.
            match current {
              Some(current) if current.status() == "pending" => {
                if !(posted is Null) {
                  current.set("thread", get(get(where_, "thread"), "id"))
                  current.set("cardTs", posted)
                  self.save(current)
                }
                return current
              }
              _ => {
                if !(posted is Null) {
                  ignore(
                    self.w.store("withdrawCard", [
                      js(session),
                      get(get(where_, "thread"), "id"),
                      posted,
                    ]),
                  )
                }
                return current.unwrap_or(r)
              }
            }
          }
          _ => ()
        }
    }
  }
  if pending is None {
    self.save(r)
    let posted = self.post(session, thread, r)
    if !(posted is Null) {
      r.set("thread", get(get(thread, "thread"), "id"))
      r.set("cardTs", posted)
      self.save(r)
    }
    self.tell(r, "grant")
  }
  r
}

///|
/// The chance a request's id is made of, the process's own (Math.random).
let id_rng : Ref[@effect.Rng?] = { val: None, }

///|
/// A request's id where none is given: `p_` and the time in base 36 and six of chance.
fn fresh_id(now : Double) -> String {
  let digits = "0123456789abcdefghijklmnopqrstuvwxyz"
  let mut n = now.to_int64()
  let b = StringBuilder::new()
  let out = []
  if n == 0L {
    out.push('0')
  }
  while n > 0L {
    out.push(digits[(n % 36L).to_int()].unsafe_to_char())
    n = n / 36L
  }
  out.rev_in_place()
  for c in out {
    b.write_char(c)
  }
  let rng = match id_rng.val {
    Some(r) => r
    None => {
      let r = @effect.Rng::new((@host.now() % 2147483647L).to_int())
      id_rng.val = Some(r)
      r
    }
  }
  for _ in 0..<6 {
    b.write_char(digits[rng.below(36)].unsafe_to_char())
  }
  "p_" + b.to_string()
}

///|
/// Whether the current card of a still-open request can be acted on; None for a surface without one.
pub async fn PhoneGrants::card_pending(self : PhoneGrants, r : Req) -> Bool? {
  let mut current = self.get(r.id())
  while current is Some(c) && c.status() == "pending" {
    let place = card_place(
      self.w,
      c.session(),
      c.get("thread").unwrap_or(Null),
      c.get("cardTs").unwrap_or(Null),
    )
    match place {
      Some(Null) => return None
      Some(p) => return Some(text_of(at(Some(p), "state")) == "same")
      None => ()
    }
    if !self.w.hub_has("prepareCardPosts") || nullish(c.get("thread")) {
      raise refused("Refused", "card lookup is not ready")
    }
    ignore(self.w.ask("hub.prepareCardPosts", [ja([c.get("thread").unwrap()])]))
    current = self.get(r.id())
  }
  None
}

///|
async fn PhoneGrants::post(
  self : PhoneGrants,
  session : String,
  thread : J,
  r : Req,
  require_empty~ : Bool = false,
) -> J {
  let stillfail = text_of(at(Some(get(thread, "thread")), "surface")) ==
    stillfail_surface &&
    at(Some(get(thread, "thread")), "surface") is Some(Str(_))
  // (asked of someone the chat's agent does not work for: they are named, so the chat sees whose phone it asks)
  let starter = self.w.store("starter", [js(session)])
  let starter = match starter {
    Str(u) => Some(@jsjson.sanitize_str(u).to_lower())
    _ => None
  }
  let whose = if starter == Some(r.owner()) {
    "你的手机"
  } else {
    "\{r.owner()} 的手机"
  }
  let parts = ["申请调试\{whose}：\{r.text("reason")}"]
  if !stillfail {
    parts.push("请在 still.fail 安卓 app 中批准。")
  }
  let text = parts.join("\n\n")
  // Every scope, idle an hour recommended (`lasts`: `chat`, all of them, as an app from before reads it).
  let card = if stillfail {
    let options = scopes.map(s => {
      let (label, detail) = scope_words(s)
      let fields = [("label", js(label)), ("detail", js(detail))]
      if s == "idle" {
        fields.push(("recommended", jb(true)))
      }
      jo(fields)
    })
    options.push(
      jo([("label", js("拒绝")), ("detail", js("通知 agent 已拒绝"))]),
    )
    jo([
      ("type", js("options")),
      ("options", ja(options)),
      ("assignee", js(r.owner())),
      // The request as the app draws it; its outcome added once decided.
      (
        "adb",
        jo([
          ("request", js(r.id())),
          ("reason", r.get("reason").unwrap_or(Null)),
          ("lasts", js("chat")),
        ]),
      ),
    ])
  } else {
    Null
  }
  let id = r.id()
  post_card(
    self.w,
    session,
    thread,
    text,
    card,
    if require_empty {
      Some(why => refused("Refused", why))
    } else {
      None
    },
    if require_empty {
      Some(async fn() {
        match self.get(id) {
          Some(c) => c.status() == "pending" && !self.ended(session)
          None => false
        }
      })
    } else {
      None
    },
  )
}

///|
/// How the station's adb holds `owner`'s phone changed (None: offered here no longer): said on the cards of their
/// grants (`adb.outcome.link`), and told to their agents as it comes to be reached or to wait on its person.
pub async fn PhoneGrants::linked(
  self : PhoneGrants,
  owner : String,
  state : J,
) -> Unit {
  let link = if state is Null {
    "gone"
  } else {
    text_of(at(Some(state), "adb"))
  }
  if !links.contains(link) {
    return
  }
  for r in self.granted_of_owner(owner) {
    if r.get("link") is Some(Str(_)) && r.text("link") == link {
      continue
    }
    r.set("link", js(link))
    let tell = (link == "connected" || link == "unpaired") &&
      !(r.get("toldLink") is Some(Str(_)) && r.text("toldLink") == link)
    if tell {
      r.set("toldLink", js(link))
    }
    self.save_and_restate(r, false)
    if tell {
      // (the session gone: nobody to tell)
      ignore(self.w.ask("hub.notify", [js(r.session()), js(link_said(r))])) catch {
        _ => ()
      }
    }
  }
}

///|
fn outcome_of(r : Req) -> J {
  let fields = [("status", r.get("status").unwrap_or(Null))]
  if truthy(r.get("scope")) {
    fields.push(("scope", r.get("scope").unwrap()))
  }
  if truthy(r.get("why")) {
    fields.push(("why", r.get("why").unwrap()))
  }
  if r.status() == "granted" && truthy(r.get("link")) {
    fields.push(("link", r.get("link").unwrap()))
  }
  jo(fields)
}

///|
/// The request's card as it stands now: its outcome (and, granted, how its phone is reached) beside its words.
async fn PhoneGrants::restate(self : PhoneGrants, r : Req) -> Unit {
  if r.get("thread") is None || r.get("cardTs") is None {
    return
  }
  let outcome = outcome_of(r)
  let f = (self.w.callback)(fn(args) {
    let was = args.get(0).unwrap_or(Null)
    let adb = match at(Some(was), "adb") {
      Some(Obj(_) as a) => a
      _ => jo([])
    }
    spread(
      if was is Obj(_) {
        was
      } else {
        jo([])
      },
      jo([("adb", set_field(adb, "outcome", outcome))]),
    )
  })
  ignore(
    self.w.store("restateCard", [
      js(r.session()),
      r.get("thread").unwrap(),
      r.get("cardTs").unwrap(),
      f,
    ]),
  )
}

///|
async fn PhoneGrants::save_and_restate(
  self : PhoneGrants,
  r : Req,
  close : Bool,
) -> Unit {
  if r.get("thread") is Some(_) && r.get("cardTs") is Some(_) && self.outcomes {
    let item = jo([
      ("thread", r.get("thread").unwrap()),
      ("ts", r.get("cardTs").unwrap()),
      ("agent", js(r.session())),
      ("field", js("adb")),
      ("close", jb(close)),
      ("outcome", outcome_of(r)),
    ])
    let saved = (self.w.callback)(fn(_) {
      self.save(r)
      J::Null
    })
    ignore(self.w.ask("cardOutcomes.save", [item, saved]))
    return
  }
  self.save(r)
  if r.get("thread") is Some(_) && r.get("cardTs") is Some(_) {
    if close {
      ignore(
        self.w.store("withdrawCard", [
          js(r.session()),
          r.get("thread").unwrap(),
          r.get("cardTs").unwrap(),
        ]),
      )
    }
    self.restate(r)
  }
}

///|
/// The owner (`email`) decides request `id`: `scope` grants it, None refuses it. Why it is refused, or None.
pub async fn PhoneGrants::decide(
  self : PhoneGrants,
  email : String,
  id : String,
  scope : String?,
  workspace : String,
  signed? : J,
) -> String? {
  guard self.get(id) is Some(r) && jeq(self.workspace(r), js(workspace)) else {
    return Some("no such request")
  }
  if r.owner() != email.to_lower() {
    return Some(
      "only the person the chat's agent works for decides its requests",
    )
  }
  if r.status() != "pending" {
    return Some("the request is \{r.status()} already")
  }
  match scope {
    Some(s) if !scopes.contains(s) =>
      return Some("scope: hour, idle, eight or chat")
    Some(_) if self.ended(r.session()) => return Some("the chat is archived")
    None => self.settle(r, "denied")
    Some(s) => {
      r.set("scope", js(s))
      r.set("exp", jn(self.secs() + lasts(s)))
      // (an idle grant counts from now)
      if s == "idle" {
        r.set("lastUsedAt", jn((self.w.now)().floor()))
      }
      match signed {
        Some(Obj(_) as s) if stringify(s).length() <= signed_max =>
          r.set("signed", signed_pair(s))
        Some(Arr(_) as s) if stringify(s).length() <= signed_max =>
          r.set("signed", jo([]))
        _ => ()
      }
      self.settle(r, "granted")
    }
  }
  None
}

///|
/// `{ body: s.body, sig: s.sig }` (an undefined field left out, as JSON does).
fn signed_pair(s : J) -> J {
  let fields = []
  match at(Some(s), "body") {
    Some(b) => fields.push(("body", b))
    None => ()
  }
  match at(Some(s), "sig") {
    Some(g) => fields.push(("sig", g))
    None => ()
  }
  jo(fields)
}

///|
/// What the owner's device signed for a grant live from before signatures: carried from now on.
pub async fn PhoneGrants::sign(
  self : PhoneGrants,
  email : String,
  id : String,
  signed : J?,
  workspace : String,
) -> String? {
  guard self.get(id) is Some(r) && jeq(self.workspace(r), js(workspace)) else {
    return Some("no such request")
  }
  if r.owner() != email.to_lower() {
    return Some("only the person the chat's agent works for signs its grants")
  }
  if r.status() != "granted" {
    return Some("the request is \{r.status()}")
  }
  match signed {
    Some(Obj(_) as s) if stringify(s).length() <= signed_max =>
      r.set("signed", signed_pair(s))
    Some(Arr(_) as s) if stringify(s).length() <= signed_max =>
      r.set("signed", jo([]))
    _ => return Some("not a signature")
  }
  // (told to their devices, not to the chat: nothing changed for it)
  self.settle(r, "granted", notify=false)
  None
}

///|
/// What the owner's device signed to take a grant of theirs back, this station's or another's: kept until the grant
/// would have ended and told to their devices, each of which checks it itself. Why it is not kept, or None.
pub async fn PhoneGrants::keep_revoke(
  self : PhoneGrants,
  email : String,
  signed : J?,
  workspace : String,
) -> String? {
  let not_one = Some("not a signature")
  guard signed is Some(Obj(_) as s) else { return not_one }
  guard at(Some(s), "body") is Some(Obj(_) as body) else { return not_one }
  guard at(Some(s), "sig") is Some(Obj(_) | Arr(_) as sig) else {
    return not_one
  }
  guard at(Some(body), "request") is Some(Str(_) as rq) else { return not_one }
  let request = js_text(rq)
  if request.length() == 0 || request.length() > 128 {
    return not_one
  }
  guard at(Some(body), "station") is Some(Str(_) as st) &&
    js_text(st).length() > 0 else {
    return not_one
  }
  guard at(Some(body), "exp") is Some(Num(exp)) && @jsjson.is_safe_integer(exp) else {
    return not_one
  }
  let kept = jo([("body", body), ("sig", sig)])
  let text = stringify(kept)
  if text.length() > signed_revoke_max {
    return not_one
  }
  let now = self.secs()
  // (ended already: the grant it takes back ended with it)
  if exp <= now {
    return None
  }
  let owner = email.to_lower()
  try {
    ignore(
      self.db.run("DELETE FROM adb_revokes WHERE owner = ? AND exp <= ?", [
        Json::string(owner),
        Json::number(now),
      ]),
    )
    ignore(
      self.db.run(
        "INSERT OR REPLACE INTO adb_revokes (id, owner, exp, body) VALUES (?, ?, ?, ?)",
        [
          Json::string("\{owner} \{request}"),
          Json::string(owner),
          Json::number(exp),
          Json::string(text),
        ],
      ),
    )
    ignore(
      self.db.run(
        "DELETE FROM adb_revokes WHERE id IN (SELECT id FROM adb_revokes WHERE owner = ?1 ORDER BY exp DESC LIMIT -1 OFFSET ?2)",
        [Json::string(owner), Json::number(revokes_per_owner_max.to_double())],
      ),
    )
  } catch {
    e => return Some(e.to_string())
  }
  match self.told_revoke {
    Some(f) => f(kept, owner, request, workspace)
    None => ()
  }
  None
}

///|
/// The signed takings back of `email`'s grants kept here (those ended let go).
pub fn PhoneGrants::revokes_of_owner(
  self : PhoneGrants,
  email : String,
) -> Array[J] raise {
  let owner = email.to_lower()
  ignore(
    self.db.run("DELETE FROM adb_revokes WHERE owner = ? AND exp <= ?", [
      Json::string(owner),
      Json::number(self.secs()),
    ]),
  ) catch {
    e => raise sql_err(e)
  }
  self
  .rows("SELECT body FROM adb_revokes WHERE owner = ? ORDER BY exp LIMIT ?", [
    js(owner),
    jn(revokes_per_owner_max.to_double()),
  ])
  .map(row => @session_chats.parse_js(text_of(at(Some(row), "body"))))
}

///|
/// The owner takes a grant (or a request) of theirs back; `signed`, what their device signed for it (`keep_revoke`).
pub async fn PhoneGrants::revoke(
  self : PhoneGrants,
  email : String,
  id : String,
  workspace : String,
  signed? : J,
) -> String? {
  if signed is Some(_) {
    ignore(self.keep_revoke(email, signed, workspace))
  }
  guard self.get(id) is Some(r) && jeq(self.workspace(r), js(workspace)) else {
    return Some("no such request")
  }
  if r.owner() != email.to_lower() {
    return Some("only its owner takes a grant back")
  }
  if r.status() != "granted" && r.status() != "pending" {
    return Some("the request is \{r.status()} already")
  }
  self.end(r, "已收回")
  None
}

///|
/// The chat's agent is done with the phone (`phone_use {done: true}`): its grant, or a request still asked, ends as one
/// taken back does. `owner`: that person's phone alone (none: every one).
pub async fn PhoneGrants::release(
  self : PhoneGrants,
  session : String,
  owner? : String,
) -> Array[Req] {
  let ended = []
  for r in self.by_session(session) {
    let theirs = match owner {
      None => true
      Some(o) => r.owner() == o.to_lower()
    }
    if theirs && self.live(r) {
      ended.push(r)
    }
  }
  for r in ended {
    self.end(r, "agent 已交还", notify=false)
  }
  ended
}

///|
async fn PhoneGrants::end(
  self : PhoneGrants,
  r : Req,
  why : String,
  workspace? : J?,
  notify~ : Bool = true,
) -> Unit {
  if r.status() != "granted" && r.status() != "pending" {
    return
  }
  r.set("why", js(why))
  self.settle(
    r,
    if r.status() == "pending" {
      "denied"
    } else {
      "ended"
    },
    workspace?,
    notify~,
  )
}

///|
async fn PhoneGrants::settle(
  self : PhoneGrants,
  r : Req,
  status : String,
  workspace? : J?,
  notify~ : Bool = true,
) -> Unit {
  r.set("status", js(status))
  // Last use is only needed while the grant can appear in the person's list.
  if status == "ended" || status == "denied" {
    r.delete("lastUsedAt")
  }
  self.save_and_restate(r, true)
  if status != "pending" && notify {
    ignore(self.w.ask("hub.notify", [js(r.session()), js(said(r))])) catch {
      _ => ()
    }
  }
  self.tell(r, "grant", workspace?)
  if status == "ended" || status == "denied" {
    self.forget_title(r.id())
    self.used_at.remove(r.id())
  }
}

///|
/// What the agent is told of how its granted phone is reached (`r.link`).
pub fn link_said(r : Req) -> String {
  let owner = r.owner()
  let id = r.id()
  match r.get("link") {
    Some(Str(_)) if r.text("link") == "connected" =>
      "\{owner}'s phone (your grant \{id}) is connected to this station's adb now: call phone_use for its adb server and serial."
    Some(Str(_)) if r.text("link") == "unpaired" =>
      "\{owner}'s phone (your grant \{id}) is lent to this station, but pairing is still needed. A card under the phone request in the still.fail app on the phone shows its person how; you are told here when it connects. Do not send them to the phone's settings yourself."
    Some(Str(_)) if r.text("link") == "gone" =>
      "\{owner}'s phone (your grant \{id}) is not offered to this station now; it offers itself again while its 共享调试 switch is on."
    link => {
      let held = match link {
        None | Some(Null) => "not yet heard"
        Some(v) => js_text(v)
      }
      "\{owner}'s phone (your grant \{id}): this station's adb holds it as \{held}."
    }
  }
}

///|
/// `String(v)` of what JSON holds.
pub fn js_text(v : J) -> String {
  @jsjson.jval_js_str(Some(v))
}

///|
/// UNDECIDED (agents/instructions.ts).
pub let undecided : String = "You are told in this session when it is decided: meanwhile go on with what does not need it (answer the chat, other work); with nothing else left, end your turn need_human (about the card)."

///|
/// What the agent is told of its request.
pub fn said(r : Req) -> String {
  let owner = r.owner()
  let id = r.id()
  match r.status() {
    "granted" => {
      let link = r.get("link")
      let more = if link is None ||
        (link is Some(Str(_)) && r.text("link") == "connected") {
        ""
      } else {
        " " + link_said(r)
      }
      "Your request \{id} to debug \{owner}'s phone was granted (\{scope_said(r.get("scope"))}). Call phone_use again for how to reach it.\{more}"
    }
    "denied" => {
      let why = if truthy(r.get("why")) {
        " (\{js_text(r.get("why").unwrap())})"
      } else {
        ""
      }
      "Your request \{id} to debug \{owner}'s phone was refused\{why}."
    }
    "ended" => {
      let why = match r.get("why") {
        None | Some(Null) => "ended"
        Some(v) => js_text(v)
      }
      "Your grant \{id} of \{owner}'s phone ended (\{why}): adb no longer reaches it."
    }
    _ =>
      "Your request \{id} to debug \{owner}'s phone waits for them to approve it on the card in your chat. \{undecided}"
  }
}

///|
/// How long a grant lasts, in words an agent reads.
pub fn scope_said(scope : J?) -> String {
  match scope {
    Some(Str(_)) =>
      match text_of(scope) {
        "hour" => "for an hour"
        "idle" => "until this chat has used it for nothing for an hour"
        "eight" => "for eight hours"
        _ => "until this chat is archived"
      }
    _ => "until this chat is archived"
  }
}
