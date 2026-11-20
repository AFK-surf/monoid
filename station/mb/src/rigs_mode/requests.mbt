// A chat's request for a rig (rigs/requests.ts; a station that only runs tasks, 2026-11-10; as a vault's grant and a
// phone's are asked): an agent asks with `station_use {station, reason}`, a card in its chat asks the rig's person
// (whoever added it), and they approve it for this chat for a time (idle or fixed, a vault's timeouts) or refuse it,
// from their app. What they approve is signed with a key on their own lock (rig-form.ts) and brought to the rig, which
// checks it itself: this station only carries it, and a grant it wrote for itself is none there. Approved while the rig
// is away, the grant is kept here and brought as the rig is next heard (rigs.mbt).
//
// The rig says when a grant ends (its time up, idle, taken back); this station says it in the chat and to the agent.
// A request is kept as the TypeScript keeps it, the JSON object it writes (`RigRequest`), its fields in the order it
// sets them.

///|
let requests_schema : String = "CREATE TABLE IF NOT EXISTS rig_requests (\n  id TEXT PRIMARY KEY,\n  ws TEXT NOT NULL,\n  session TEXT NOT NULL,\n  rig TEXT NOT NULL,\n  owner TEXT NOT NULL,\n  status TEXT NOT NULL,\n  body TEXT NOT NULL\n);\nCREATE INDEX IF NOT EXISTS rig_requests_by_session ON rig_requests (session, status);\nCREATE INDEX IF NOT EXISTS rig_requests_by_rig ON rig_requests (rig, status);\nCREATE INDEX IF NOT EXISTS rig_requests_by_owner ON rig_requests (owner, status);"

///|
/// The most a statement with its person's lock takes (bytes of JSON): a lock is a chain of a person's devices.
let signed_max : Int = 524288

///|
/// A request no one decided is let go after a day, as a vault's.
let pending_secs : Double = 86400.0

///|
/// agents/instructions.ts `UNDECIDED`.
pub let undecided : String = "You are told in this session when it is decided: meanwhile go on with what does not need it (answer the chat, other work); with nothing else left, end your turn need_human (about the card)."

///|
/// sessions/card-place.ts `CARD_OCCUPIED`.
pub let card_occupied : String = "Another card is pending in that conversation. Resolve or withdraw it before asking this again."

///|
/// store/rows.ts `STILLFAIL_SURFACE`.
pub let stillfail_surface : String = "chat"

///|
/// A number in base 36, as `n.toString(36)` writes a whole one.
pub fn base36(n : Double) -> String {
  let digits = "0123456789abcdefghijklmnopqrstuvwxyz"
  let mut v = n.floor().to_int64()
  if v == 0L {
    return "0"
  }
  let neg = v < 0L
  if neg {
    v = -v
  }
  let out = []
  while v > 0L {
    out.push(digits.unsafe_charcode_at((v % 36L).to_int()))
    v = v / 36L
  }
  let b = StringBuilder()
  if neg {
    b.write_char('-')
  }
  for i = out.length() - 1; i >= 0; i = i - 1 {
    b.write_char(out[i].unsafe_to_char())
  }
  b.to_string()
}

///|
/// A request's id as the station makes one (rigs/requests.ts): `r_`, the time in base 36, then six random letters.
pub fn request_id_of(now : Double, random : String) -> String {
  "r_\{base36(now)}\{random}"
}

///|
/// A request as kept (rigs/requests.ts `RigRequest`): its fields in the order they were set.
pub type RigRequest = Map[String, Json]

///|
fn rs(r : RigRequest, k : String) -> String {
  match r.get(k) {
    Some(String(s)) => s
    _ => ""
  }
}

///|
fn rn(r : RigRequest, k : String) -> Double? {
  match r.get(k) {
    Some(Number(n, ..)) => Some(n)
    _ => None
  }
}

///|
pub fn request_json(r : RigRequest) -> Json {
  Json::object(r)
}

///|
/// Which of a chat's grants `release` lets go: the rig's own (no device), either, any device's, or one device's.
pub(all) enum DeviceSel {
  RigItself
  Either
  AnyDevice
  OneDevice(String)
}

///|
pub(all) struct RequestsDeps {
  db : @sql.Db
  /// The hub and its store (`store.*`, `hub.notify`, `hub.prepareLatestThreads`), a chat's card (`dep.postCard`,
  /// `dep.cardPlace`) and the card outbox (`cardOutcomes.save`).
  world : World
  card_outcomes : Bool
  /// The station's home workspace (sessions from before workspace membership was recorded), and its own id.
  home : () -> String?
  self_ : () -> String
  /// The chat's current name, or None before it has one.
  title : async (String, String) -> String?
  /// A grant brought to its rig: until when it holds there (unix seconds). Raises `Refused` where the rig refused it
  /// (final), anything else where it was not reached.
  bring : async (RigRequest) -> Double
  /// A grant given back, or one taken back by its person, told to its rig (kept and told again when not reached).
  release : (RigRequest, Json?) -> Unit raise
  now : () -> Double
  /// A request changed: who shows the rigs is told.
  told : (async (RigRequest) -> Unit)?
  id : () -> String
}

///|
pub struct RigRequests {
  priv d : RequestsDeps
}

///|
pub fn RigRequests::new(d : RequestsDeps) -> RigRequests raise {
  d.db.exec(requests_schema)
  { d, }
}

///|
/// What the store told changed (`hub.store.subscribe`): a session archived or gone ends its requests.
pub async fn RigRequests::store_changed(self : RigRequests, c : Json) -> Unit {
  let c = Some(c)
  let t = str_at(c, "type")
  guard (t == Some("sessionRemoved") || t == Some("session")) && str_at(c, "key") is Some(key) else { return }
  if self.gone(key) {
    for r in self.by_session(key) {
      self.end(r, "对话已归档", true, notify=false)
    }
  }
}

///|
fn RigRequests::secs(self : RigRequests) -> Double {
  ((self.d.now)() / 1000.0).floor()
}

///|
async fn RigRequests::gone(self : RigRequests, session : String) -> Bool {
  match self.d.world.ask("store.getSession", [jstr(session)]) {
    None | Some(Null) => true
    Some(row) =>
      match get(Some(row), "archivedAt") {
        None | Some(Null) => false
        _ => true
      }
  }
}

///|
fn RigRequests::save(self : RigRequests, r : RigRequest) -> Unit raise {
  self.d.db.run(
    "INSERT INTO rig_requests (id, ws, session, rig, owner, status, body) VALUES (?, ?, ?, ?, ?, ?, ?) ON CONFLICT (id) DO UPDATE SET status = excluded.status, body = excluded.body",
    [
      r.get("id").unwrap_or(Json::null()),
      r.get("ws").unwrap_or(Json::null()),
      r.get("session").unwrap_or(Json::null()),
      r.get("rig").unwrap_or(Json::null()),
      r.get("owner").unwrap_or(Json::null()),
      r.get("status").unwrap_or(Json::null()),
      jstr(stringify(Json::object(r))),
    ],
  )
  |> ignore
}

///|
fn RigRequests::load(self : RigRequests, sql : String, args : Array[Json]) -> Array[RigRequest] raise {
  let rows = self.d.db.all(sql, args)
  let out = []
  for row in rows {
    if row.get("body") is Some(String(text)) && parse(text) is Some(Object(m)) {
      out.push(m)
    }
  }
  out
}

///|
pub fn RigRequests::get(self : RigRequests, id : String) -> RigRequest? raise {
  self.load("SELECT body FROM rig_requests WHERE id = ?", [jstr(id)]).get(0)
}

///|
fn RigRequests::by_session(self : RigRequests, session : String) -> Array[RigRequest] raise {
  self.load("SELECT body FROM rig_requests WHERE session = ? AND status IN ('pending', 'granted')", [jstr(session)])
}

///|
/// A pending request nobody decided within a day is let go as it is read; a granted one past its last second ended.
async fn RigRequests::live(self : RigRequests, r : RigRequest) -> Bool {
  let now = self.secs()
  let status = rs(r, "status")
  if status == "pending" && now - rn(r, "at").unwrap_or(0.0) >= pending_secs {
    self.end(r, "一天内无人处理", false)
    return false
  }
  if status == "granted" &&
    r.get("signed") is Some(signed) &&
    num_at(get(Some(signed), "body"), "exp").unwrap_or(0.0) <= now {
    self.end(r, "授权已到期", false)
    return false
  }
  status == "pending" || status == "granted"
}

///|
/// A chat's requests for `rig` (or, `device` named, for that device of it alone) still open (asked, or granted).
pub async fn RigRequests::of(
  self : RigRequests,
  session : String,
  rig : String,
  device~ : String? = None,
) -> Array[RigRequest] {
  let out = []
  for r in self.by_session(session) {
    let d = match r.get("device") {
      Some(v) => Some(js_string_of(Some(v)))
      None => None
    }
    if rs(r, "rig") == rig && d == device && self.live(r) {
      out.push(r)
    }
  }
  out
}

///|
/// The requests of a workspace's rig still open, every chat's (who lists the rig shows them).
pub async fn RigRequests::of_rig(self : RigRequests, ws : String, rig : String) -> Array[RigRequest] {
  let out = []
  for r in self.load("SELECT body FROM rig_requests WHERE rig = ? AND status IN ('pending', 'granted')", [jstr(rig)]) {
    if rs(r, "ws") == ws && self.live(r) {
      out.push(r)
    }
  }
  out
}

///|
/// The granted ones the rig has not taken yet (it was away as they were approved).
pub async fn RigRequests::undelivered(self : RigRequests, ws : String, rig : String) -> Array[RigRequest] {
  self.of_rig(ws, rig).filter(r => rs(r, "status") == "granted" && !(r.get("delivered") is Some(True)))
}

///|
/// station_use: a request asked in the session's chat, of the rig's person; not waited for (the agent's turn goes on),
/// its decision told to the session. One already open for the rig is said again, not asked twice.
pub async fn RigRequests::ask(
  self : RigRequests,
  session : String,
  rig : Json,
  ws : String,
  reason : String,
  timeout : Json?,
  device~ : (String, String)? = None,
) -> RigRequest {
  if self.gone(session) {
    raise Refused("this chat is archived or gone")
  }
  let rig_ = Some(rig)
  let open = self.of(session, str_at(rig_, "id").unwrap_or(""), device=device.map(d => d.0))
  if open.get(0) is Some(o) {
    return o
  }
  if js_trim(reason) == "" {
    raise Refused(
      if device is None {
        "say what you will run on that station and why (reason)"
      } else {
        "say what you will do with the device and why (reason)"
      },
    )
  }
  if timeout is Some(_) && timeout_refusal(timeout) is Some(why) {
    raise Refused(why)
  }
  let has_prepare = self.d.world.ask("hub.has", [jstr("prepareLatestThreads")]) is Some(True)
  let has_ready = self.d.world.ask("store.has", [jstr("latestThreadIfReady")]) is Some(True)
  let thread = if has_prepare && has_ready {
    match self.d.world.ask("store.latestThreadIfReady", [jstr(session)]) {
      None => {
        self.d.world.ask("hub.prepareLatestThreads", [jarr([jstr(session)])]) |> ignore
        if self.gone(session) {
          raise Refused("this chat is archived or gone")
        }
        return self.ask(session, rig, ws, reason, timeout, device~)
      }
      Some(t) => t
    }
  } else {
    self.d.world.ask("store.latestThread", [jstr(session)]).unwrap_or(Json::null())
  }
  if thread is Null {
    raise Refused("this session has no chat to ask in")
  }
  let th = get(Some(thread), "thread")
  let chat = js_string_of(get(th, "channel")) + "/" + js_string_of(get(th, "threadTs"))
  let title = (self.d.title)(session, chat)
  let starter = self.d.world.ask("store.starter", [jstr(session)])
  let r : RigRequest = Map([
    ("id", jstr((self.d.id)())),
    ("ws", jstr(ws)),
    ("session", jstr(session)),
    ("chat", jstr(chat)),
    ("rig", get(rig_, "id").unwrap_or(Json::null())),
    ("rigName", get(rig_, "name").unwrap_or(Json::null())),
    ("owner", get(rig_, "owner").unwrap_or(Json::null())),
    ("ownerEmail", jstr(js_lower(str_at(rig_, "owner_email").unwrap_or("")))),
    ("reason", jstr(js_trim(reason))),
    ("timeout", timeout.unwrap_or(timeout_default())),
    ("at", jnum(self.secs())),
    ("status", jstr("pending")),
    ("title", jstr(title.unwrap_or(""))),
    (
      "by",
      match starter {
        None | Some(Null) => jstr("")
        Some(v) => v
      },
    ),
  ])
  if device is Some((id, name)) {
    r["device"] = jstr(id)
    r["deviceName"] = jstr(name)
  }
  self.save(r)
  let posted = self.post(session, thread, r)
  if posted is Some(ts) {
    r["thread"] = get(th, "id").unwrap_or(Json::null())
    r["cardTs"] = jstr(ts)
    self.save(r)
  }
  if self.d.told is Some(told) {
    told(r)
  }
  r
}

///|
async fn RigRequests::post(self : RigRequests, session : String, thread : Json, r : RigRequest) -> String? {
  let stillfail = str_at(get(Some(thread), "thread"), "surface") == Some(stillfail_surface)
  let whose = if rs(r, "ownerEmail") != "" { rs(r, "ownerEmail") } else { rs(r, "owner") }
  let what = match r.get("device") {
    None => " station「\{rs(r, "rigName")}」"
    Some(_) => {
      let name = match r.get("deviceName") {
        Some(String(n)) => n
        _ => rs(r, "device")
      }
      "设备「\{name}」（在 station「\{rs(r, "rigName")}」上）"
    }
  }
  let parts = ["申请使用\{what}：\{rs(r, "reason")}"]
  if !stillfail {
    parts.push("请它的所有者 \{whose} 在 still.fail app 中批准。")
  }
  let text = parts.join("\n\n")
  let card = if stillfail {
    let rig_fields = [
      ("request", r.get("id").unwrap_or(Json::null())),
      ("rig", r.get("rig").unwrap_or(Json::null())),
      ("name", r.get("rigName").unwrap_or(Json::null())),
      ("owner", r.get("owner").unwrap_or(Json::null())),
      ("reason", r.get("reason").unwrap_or(Json::null())),
      ("timeout", r.get("timeout").unwrap_or(Json::null())),
      ("ws", r.get("ws").unwrap_or(Json::null())),
      ("station", jstr((self.d.self_)())),
      ("session", r.get("session").unwrap_or(Json::null())),
      ("chat", r.get("chat").unwrap_or(Json::null())),
      ("title", r.get("title").unwrap_or(Json::null())),
      ("by", r.get("by").unwrap_or(Json::null())),
    ]
    if r.get("device") is Some(dv) {
      rig_fields.push(("device", dv))
      rig_fields.push(
        (
          "deviceName",
          match r.get("deviceName") {
            None => jstr("")
            Some(n) => n
          },
        ),
      )
    }
    jobj([
      ("type", jstr("options")),
      (
        "options",
        jarr([
          jobj([
            ("label", jstr("允许")),
            (
              "detail",
              jstr(
                if r.get("device") is None {
                  "这个对话的 agent 可以在这台 station 上运行任务"
                } else {
                  "这个对话的 agent 可以连接这台设备"
                },
              ),
            ),
            ("recommended", jbool(true)),
          ]),
          jobj([("label", jstr("拒绝")), ("detail", jstr("通知 agent 已拒绝"))]),
        ]),
      ),
      ("assignee", r.get("ownerEmail").unwrap_or(Json::null())),
      // The request as the app draws it, with what its person's device signs to approve it; its outcome added once
      // decided.
      ("rig", jobj(rig_fields)),
    ])
  } else {
    Json::null()
  }
  match self.d.world.ask("dep.postCard", [jstr(session), thread, jstr(text), card]) {
    Some(String(ts)) => Some(ts)
    _ => None
  }
}

///|
fn outcome_of(r : RigRequest) -> Json {
  let out = [("status", r.get("status").unwrap_or(Json::null()))]
  if truthy(r.get("why")) {
    out.push(("why", r.get("why").unwrap()))
  }
  if rs(r, "status") == "granted" {
    let timeout = match get(get(r.get("signed"), "body"), "timeout") {
      None | Some(Null) => r.get("timeout").unwrap_or(Json::null())
      Some(t) => t
    }
    out.push(("timeout", timeout))
    out.push(("delivered", jbool((r.get("delivered") is Some(True)))))
    if r.get("until") is Some(u) {
      out.push(("until", u))
    }
  }
  jobj(out)
}

///|
async fn RigRequests::save_and_restate(self : RigRequests, r : RigRequest, close : Bool) -> Unit {
  let thread = r.get("thread")
  let ts = r.get("cardTs")
  if thread is Some(t) && ts is Some(s) && self.d.card_outcomes {
    // (written in the same transaction as the card's close and its queued outcome: neither without the other)
    let saved = (self.d.world.callback)(fn(_ : Array[Json]) raise {
      self.save(r)
      undefined_json()
    })
    self.d.world.ask("cardOutcomes.save", [
      jobj([
        ("thread", t),
        ("ts", s),
        ("agent", r.get("session").unwrap_or(Json::null())),
        ("field", jstr("rig")),
        ("close", jbool(close)),
        ("outcome", outcome_of(r)),
      ]),
      saved,
    ])
    |> ignore
    return
  }
  self.save(r)
  if thread is Some(t) && ts is Some(s) {
    let session = r.get("session").unwrap_or(Json::null())
    if close {
      self.d.world.ask("store.withdrawCard", [session, t, s]) |> ignore
    }
    let outcome = outcome_of(r)
    let made = (self.d.world.callback)(fn(args : Array[Json]) {
      let was = args.get(0)
      spread(was, Some(jobj([("rig", spread(get(was, "rig"), Some(jobj([("outcome", outcome)]))))])))
    })
    self.d.world.ask("store.restateCard", [session, t, s, made]) |> ignore
  }
}

///|
/// Whether the request's card still waits in its chat; None on a surface without one.
pub async fn RigRequests::card_pending(self : RigRequests, r : RigRequest) -> Bool? {
  let place = self.d.world.ask("dep.cardPlace", [
    r.get("session").unwrap_or(Json::null()),
    r.get("thread").unwrap_or(undefined_json()),
    r.get("cardTs").unwrap_or(undefined_json()),
  ])
  match place {
    None | Some(Null) => None
    Some(p) =>
      match str_at(Some(p), "state") {
        Some("other") => raise Refused(card_occupied)
        s => Some(s == Some("same"))
      }
  }
}

///|
/// The rig's person (`sub`) decides request `id`: `signed` (with their lock, `chain`) grants it, none refuses it. Why it
/// is not taken, or None. Granted, it is brought to the rig at once (`delivered` says whether it got there).
pub async fn RigRequests::decide(
  self : RigRequests,
  sub : String,
  id : String,
  workspace : String,
  signed : Json?,
  chain : Json?,
) -> String? {
  guard self.get(id) is Some(r) && rs(r, "ws") == workspace else { return Some("no such request") }
  if rs(r, "owner") != sub {
    return Some("only the rig's owner decides who uses it")
  }
  if rs(r, "status") != "pending" {
    return Some("the request is \{rs(r, "status")} already")
  }
  if signed is (None | Some(Null)) {
    self.settle(r, "denied")
    return None
  }
  if self.gone(rs(r, "session")) {
    return Some("the chat is archived")
  }
  let chain_or_null = match chain {
    None => Json::null()
    Some(c) => c
  }
  if !well_formed("grant", signed) || stringify(jarr([signed.unwrap(), chain_or_null])).length() > signed_max {
    return Some("not a rig's grant")
  }
  let b = get(signed, "body")
  if str_at(b, "sub") != Some(sub) ||
    str_at(b, "ws") != Some(rs(r, "ws")) ||
    str_at(b, "rig") != Some(rs(r, "rig")) ||
    str_at(b, "station") != Some((self.d.self_)()) ||
    str_at(b, "session") != Some(rs(r, "session")) ||
    str_at(b, "chat") != Some(rs(r, "chat")) ||
    str_at(b, "request") != Some(rs(r, "id")) ||
    str_at(b, "title") != Some(rs(r, "title")) ||
    str_at(b, "by") != Some(rs(r, "by")) ||
    get(b, "device") != r.get("device") {
    return Some("signed for something else than this request")
  }
  let at = num_at(b, "at").unwrap_or(0.0)
  let exp = num_at(b, "exp").unwrap_or(0.0)
  if exp > latest(at, get(b, "timeout")) {
    return Some("signed for longer than its timeout")
  }
  if exp <= self.secs() {
    return Some("the grant has expired")
  }
  r["signed"] = signed.unwrap()
  if chain is Some(Array(_)) {
    r["chain"] = chain.unwrap()
  }
  r["delivered"] = jbool(false)
  r["status"] = jstr("granted")
  self.save(r)
  self.deliver(r)
  None
}

///|
/// A granted request brought to its rig. Taken: its agent told it may use the rig. Refused there (what was signed does
/// not hold for the rig): the request ends as refused, with why. Not reached: it waits, its agent told so once.
pub async fn RigRequests::deliver(self : RigRequests, given : RigRequest) -> Unit {
  let id = rs(given, "id")
  let brought = try {
    Ok((self.d.bring)(given))
  } catch {
    e => Err(e)
  }
  match brought {
    Ok(until) => {
      guard self.get(id) is Some(r) && rs(r, "status") == "granted" else { return }
      r["delivered"] = jbool(true)
      r["until"] = jnum(until)
      self.settle(r, "granted")
    }
    Err(e) => {
      guard self.get(id) is Some(r) && rs(r, "status") == "granted" && !(r.get("delivered") is Some(True)) else {
        return
      }
      match e {
        Refused(m) => {
          r["why"] = jstr("这台 station 拒绝了这份授权：\{m}")
          r.remove("signed")
          r.remove("chain")
          self.settle(r, "denied")
        }
        // Away: said once, as it was approved; brought again as the rig is next heard.
        _ =>
          if !(r.get("toldAway") is Some(True)) {
            r["toldAway"] = jbool(true)
            self.settle(r, "granted")
          }
      }
    }
  }
}

///|
/// The rig's person takes a grant (signed: the rig takes it back on that) or a request still asked (no signature needed
/// to refuse) of their rig back.
pub async fn RigRequests::revoke(
  self : RigRequests,
  sub : String,
  id : String,
  workspace : String,
  signed : Json?,
  chain : Json?,
) -> String? {
  guard self.get(id) is Some(r) && rs(r, "ws") == workspace else { return Some("no such request") }
  if rs(r, "owner") != sub {
    return Some("only the rig's owner takes a grant of it back")
  }
  if rs(r, "status") == "pending" {
    r["why"] = jstr("所有者已拒绝")
    self.settle(r, "denied")
    return None
  }
  if rs(r, "status") != "granted" {
    return Some("the request is \{rs(r, "status")} already")
  }
  if !well_formed("revoke", signed) {
    return Some("not a rig's revoke")
  }
  let b = get(signed, "body")
  if str_at(b, "sub") != Some(sub) ||
    str_at(b, "ws") != Some(rs(r, "ws")) ||
    str_at(b, "rig") != Some(rs(r, "rig")) ||
    str_at(b, "request") != Some(rs(r, "id")) {
    return Some("signed for something else than this grant")
  }
  let revoke = [("signed", signed.unwrap())]
  if chain is Some(Array(_)) {
    revoke.push(("chain", chain.unwrap()))
  }
  self.end(r, "所有者已收回", false, revoke=Some(jobj(revoke)))
  None
}

///|
/// The chat's agent is done with the rig (`station_use {done: true}`): its grant, or a request still asked, ends.
pub async fn RigRequests::release(
  self : RigRequests,
  session : String,
  rig : String?,
  device? : DeviceSel = Either,
) -> Array[RigRequest] {
  let ended = []
  for r in self.by_session(session) {
    let rig_ok = match rig {
      None => true
      Some(x) => rs(r, "rig") == x
    }
    let dev_ok = match device {
      Either => true
      AnyDevice => r.get("device") is Some(_)
      RigItself => r.get("device") is None
      OneDevice(d) => r.get("device") is Some(v) && js_string_of(Some(v)) == d
    }
    if rig_ok && dev_ok && self.live(r) {
      ended.push(r)
    }
  }
  for r in ended {
    self.end(r, "agent 已交还", true, notify=false)
  }
  ended
}

///|
/// The rig says a grant ended there (`why`: its time up, idle, taken back), or no longer lists one this station brought
/// it.
pub async fn RigRequests::ended_there(self : RigRequests, id : String, why : String) -> Unit {
  guard self.get(id) is Some(r) && rs(r, "status") == "granted" && (r.get("delivered") is Some(True)) else { return }
  self.end(r, why, false)
}

///|
/// The rig's own word on a grant it holds: until when, if the chat uses it no more.
pub async fn RigRequests::held_there(self : RigRequests, id : String, until : Double) -> Unit {
  guard self.get(id) is Some(r) &&
    rs(r, "status") == "granted" &&
    (r.get("delivered") is Some(True)) &&
    rn(r, "until") != Some(until) else {
    return
  }
  r["until"] = jnum(until)
  self.save_and_restate(r, false)
  if self.d.told is Some(told) {
    told(r)
  }
}

///|
/// `tell`: whether the rig is told (it is not when it said so itself). `revoke`: what its person signed taking it back.
async fn RigRequests::end(
  self : RigRequests,
  r : RigRequest,
  why : String,
  tell : Bool,
  notify? : Bool = true,
  revoke? : Json? = None,
) -> Unit {
  let was = rs(r, "status")
  if was != "granted" && was != "pending" {
    return
  }
  r["why"] = jstr(why)
  if was == "granted" && (tell || revoke is Some(_)) {
    (self.d.release)(r, revoke)
  }
  self.settle(r, if was == "pending" { "denied" } else { "ended" }, notify~)
}

///|
async fn RigRequests::settle(self : RigRequests, r : RigRequest, status : String, notify? : Bool = true) -> Unit {
  r["status"] = jstr(status)
  if status == "ended" || status == "denied" {
    r.remove("signed")
    r.remove("chain")
  }
  self.save_and_restate(r, true)
  if notify {
    // (the session gone: nobody to tell)
    let _ = self.d.world.ask("hub.notify", [r.get("session").unwrap_or(Json::null()), jstr(said(r))]) catch {
      _ => None
    }
  }
  if self.d.told is Some(told) {
    told(r)
  }
}

///|
/// How long a timeout is, in words an agent reads.
pub fn lasting(t : Json?) -> String {
  let minutes = num_at(t, "seconds").unwrap_or(0.0) / 60.0
  let span = if minutes % 1440.0 == 0.0 {
    "\{num_text(minutes / 1440.0)} d"
  } else if minutes % 60.0 == 0.0 {
    "\{num_text(minutes / 60.0)} h"
  } else {
    "\{num_text(minutes)} min"
  }
  if str_at(t, "kind") == Some("idle") {
    "until this chat has used it for nothing for \{span} (a task of yours still running there is use)"
  } else {
    "for \{span}"
  }
}

///|
fn timeout_said(r : RigRequest) -> Json? {
  match get(get(r.get("signed"), "body"), "timeout") {
    None | Some(Null) => r.get("timeout")
    t => t
  }
}

///|
/// What the agent is told of its request.
pub fn said(r : RigRequest) -> String {
  let whose = if rs(r, "ownerEmail") != "" { rs(r, "ownerEmail") } else { js_string_of(r.get("owner")) }
  if r.get("device") is Some(_) {
    return device_said(r, whose)
  }
  let id = js_string_of(r.get("id"))
  let name = js_string_of(r.get("rigName"))
  let why = r.get("why")
  match rs(r, "status") {
    "granted" =>
      if !(r.get("delivered") is Some(True)) {
        "Your request \{id} for the tasks-only station \{name} was approved by \{whose}, but it is not reached now: the grant is brought to it when it is back, and you are told then. Do not ask again."
      } else {
        "Your request \{id} for the tasks-only station \{name} was granted by \{whose} (\{lasting(timeout_said(r))}): use it as any station, by its name, with station_task, station_file, peer_forward and secret_use's station. Done with it, call station_use with done: true."
      }
    "denied" => {
      let because = if truthy(why) { " (\{js_string_of(why)})" } else { "" }
      "Your request \{id} for the tasks-only station \{name} was refused\{because}."
    }
    "ended" => {
      let because = match why {
        None | Some(Null) => "ended"
        w => js_string_of(w)
      }
      "Your grant \{id} of the tasks-only station \{name} ended (\{because}): what this chat ran there was stopped, and it takes nothing more from this chat. What a task left there (its log, files to bring back) is still read with station_task and station_file. Ask again with station_use if it is still needed."
    }
    _ =>
      "Your request \{id} for the tasks-only station \{name} waits for its owner \{whose} to approve it on the card in your chat. \{undecided}"
  }
}

///|
/// What the agent is told of its request for one of a rig's devices.
fn device_said(r : RigRequest, whose : String) -> String {
  let device_name = match r.get("deviceName") {
    None | Some(Null) => js_string_of(r.get("device"))
    n => js_string_of(n)
  }
  let what = "the device \{device_name} (on the tasks-only station \{js_string_of(r.get("rigName"))})"
  let id = js_string_of(r.get("id"))
  let why = r.get("why")
  match rs(r, "status") {
    "granted" =>
      if !(r.get("delivered") is Some(True)) {
        "Your request \{id} for \{what} was approved by \{whose}, but that station is not reached now: the grant is brought to it when it is back, and you are told then. Do not ask again."
      } else {
        "Your request \{id} for \{what} was granted by \{whose} (\{lasting(timeout_said(r))}): call device_use again with the device for where it is reached here. Done with it, call device_use with done: true."
      }
    "denied" => {
      let because = if truthy(why) { " (\{js_string_of(why)})" } else { "" }
      "Your request \{id} for \{what} was refused\{because}."
    }
    "ended" => {
      let because = match why {
        None | Some(Null) => "ended"
        w => js_string_of(w)
      }
      "Your grant \{id} of \{what} ended (\{because}): its port here is closed. Ask again with device_use if it is still needed."
    }
    _ => "Your request \{id} for \{what} waits for its owner \{whose} to approve it on the card in your chat. \{undecided}"
  }
}
