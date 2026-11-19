// Chats shared with other workspaces (station/src/xshare/index.ts `ChatShares`, line for line; its head says the whole
// of it): the station a chat is on keeps whom it is shared with (stillfail.db `chat_shares`), the stations of each of
// those workspaces (state.json `guests`) and which of them it told of which version (`hosted`), telling each
// (`xshare.changed`) and answering their reads and writes of those chats, nothing else; a station a chat is shared with
// keeps which station it is from (`borrowed`), asks it once a run (`xshare.list`) and tells it its workspace's
// stations (`xshare.roster`), taking a station's word only once a member said to (`hosts`, `xshare.trusts`); a session
// that wrote to another workspace's may be answered by it (`replies`, `answered`), each lapsing once unused for
// XSHARE_IDLE_MS (6 hours).

///|
let xshare_retry_ms : Double = 60000.0

///|
let xshare_retry_max_ms : Double = 1800000.0

///|
/// At most this many workspaces for one chat, stations for one workspace, sessions answered from outside.
let max_to : Int = 16

///|
let max_stations : Int = 64

///|
let max_replies : Int = 2000

///|
/// Six hours: a share unused that long lapses (store/rows.ts `XSHARE_IDLE_MS`).
pub let xshare_idle_ms : Double = 21600000.0

///|
/// Why a chat once shared with an agent's workspace is not now (store/rows.ts `LAPSED`).
pub let lapsed_words : String = "that chat's share with your workspace lapsed, unused for 6 hours: a person of its workspace must share it again (by @-mentioning it in a message to you, or in its chat info)"

///|
/// The store's chats shared with other workspaces (store/store.ts, `chat_shares`): each share `{to: [{workspace, name,
/// used}], write, by, at}` as store/rows.ts `toChatShare` reads it.
pub(all) struct ChatStore {
  chat_share : (String) -> Json? raise
  chat_shares : () -> Array[(String, Json)] raise
  chat_share_lapsed : (String, Array[String]?) -> Bool raise
  lapsed_share_workspaces : (Array[String]?) -> Array[String] raise
  used_chat_share : (String, Array[String]) -> Unit raise
  lapse_chat_shares : (Double) -> Double? raise
  set_chat_share : (String, Array[(String, String)], Bool, String) -> Unit raise
  /// What the store changed, told as it changes (`{type, id?, key?}`).
  subscribe : ((Json) -> Unit) -> () -> Unit
  /// The session a thread is the home chat of (`getThread(id)?.home`).
  thread_home : (String) -> String? raise
}

///|
/// What the chat shares are given (xshare/index.ts `XshareDeps`).
pub(all) struct XshareDeps {
  data : String
  store : ChatStore
  cloud : Cloud
  /// The workspace a chat of this station is in; None: the home one.
  chat_ws : ((String) -> String?)?
  /// A request to another station: of this workspace, or of another with `request.workspace` its.
  ask : async (String, Json) -> Json
  /// The link and the title a chat goes by; a link is None outside a workspace.
  link : (String) -> String?
  title : (String) -> String
  /// The chats a session.* request of another station reads or writes in.
  touches : (Json) -> Array[String]
  /// Where session.* requests go once allowed.
  inbox : async (String, Json) -> Json
  /// Start or resume the bounded lookup without delaying a share operation.
  prepare_index : (() -> Unit)?
  clock : Clock
  log : Log
  files : Files
}

///|
/// The stations a request names, checked: [{id, name}], at least one.
fn stations_of(v : Json?) -> Array[(String, String)] raise {
  guard v is Some(Array(a)) && a.length() > 0 && a.length() <= max_stations else {
    raise Failed("stations: 1 to \{max_stations}, each {id, name}")
  }
  a.map(s => {
    guard get(Some(s), "id") is Some(String(id)) && is_ws_id(id) else { raise Failed("a station's id is its public key") }
    let name = text_most(get(Some(s), "name"), 80)
    (id, if name == "" { js_slice(id, 8) } else { name })
  })
}

///|
/// `decodeURIComponent`: %XX escapes of UTF-8 read back; a malformed one fails.
pub fn decode_uri_component(s : String) -> String raise {
  guard @url.decode_uri_component(s) is Some(text) else { raise Failed("URI malformed") }
  text
}

///|
/// A chat's link as a still.fail link names it: …/o/<workspace>/<station>/<key> (the first such in it).
pub fn link_parts(link : String) -> (String, String, String)? raise {
  let cs = link.to_array()
  let part = (c : Char) => c != '/' && c != '?' && c != '#' && !js_space(c)
  let run = (from : Int) => {
    let mut k = from
    while k < cs.length() && part(cs[k]) {
      k += 1
    }
    k
  }
  for start in 0..<cs.length() {
    guard start + 3 <= cs.length() && cs[start] == '/' && cs[start + 1] == 'o' && cs[start + 2] == '/' else { continue }
    let a = start + 3
    let a_end = run(a)
    guard a_end > a && a_end < cs.length() && cs[a_end] == '/' else { continue }
    let b = a_end + 1
    let b_end = run(b)
    guard b_end > b && b_end < cs.length() && cs[b_end] == '/' else { continue }
    let c = b_end + 1
    let c_end = run(c)
    guard c_end > c else { continue }
    return Some(
      (
        String::from_array(cs[a:a_end]),
        String::from_array(cs[b:b_end]),
        decode_uri_component(String::from_array(cs[c:c_end])),
      ),
    )
  }
  None
}

///|
/// A stable sort (`Array.prototype.sort` keeps equal ones in their order).
fn[T] stable_sort(a : Array[T], cmp : (T, T) -> Int) -> Array[T] {
  let out = a.copy()
  for i in 1..<out.length() {
    let x = out[i]
    let mut j = i - 1
    while j >= 0 && cmp(out[j], x) > 0 {
      out[j + 1] = out[j]
      j -= 1
    }
    out[j + 1] = x
  }
  out
}

///|
/// `.sort()` of strings: by their UTF-16 units.
fn js_sorted(a : Array[String]) -> Array[String] {
  stable_sort(a, (x, y) => if x == y { 0 } else if @memory.js_after(x, y) { 1 } else { -1 })
}

///|
pub struct ChatShares {
  deps : XshareDeps
  priv tasks : Tasks
  priv files : Files
  priv mut retry : (() -> Unit)?
  priv mut retry_wait : Double
  priv stops : Array[() -> Unit]
  priv mut reconciling : @effect.Deferred[Unit]?
  priv mut again : Bool
  /// Hosts asked what they share in this run.
  priv listed : Set[String]
  /// How often each host said something changed (xshare.changed).
  priv heard : Map[String, Int]
  priv mut state : Map[String, Json]?
  priv mut file : PrivateFile?
  /// Shares that lapsed by this time were told of; the next to lapse is waited for.
  priv mut lapsed : Double
  priv mut lapsing : (() -> Unit)?
  priv mut closed : Bool
}

///|
pub fn ChatShares::new(deps : XshareDeps, rt : @effect.Runtime) -> ChatShares {
  {
    deps,
    tasks: Tasks::new(rt, deps.log, "xshare"),
    files: deps.files,
    retry: None,
    retry_wait: xshare_retry_ms,
    stops: [],
    reconciling: None,
    again: false,
    listed: Set::new(),
    heard: Map([]),
    state: None,
    file: None,
    lapsed: (deps.clock.now)(),
    lapsing: None,
    closed: false,
  }
}

///|
pub fn ChatShares::busy(self : ChatShares) -> Int {
  self.tasks.busy
}

///|
fn ChatShares::root(self : ChatShares) -> String {
  self.files.join([self.deps.data, "xshare"])
}

///|
let xshare_keys : Array[String] = ["guests", "hosted", "borrowed", "hosts", "replies", "answered", "roster"]

///|
/// The one copy of state.json in memory, read as it is made (`load`) and written through.
pub async fn ChatShares::load(self : ChatShares) -> Unit {
  if self.state is Some(_) {
    return
  }
  let st : Map[String, Json] = Map([])
  for k in xshare_keys {
    st[k] = Json::object(Map([]))
  }
  match self.files.read_text(self.files.join([self.root(), "state.json"])) {
    Some(text) =>
      match (try Some(js_parse(text)) catch { _ => None }) {
        Some(s) =>
          for k in xshare_keys {
            if get(Some(s), k) is Some(Object(_) as o) {
              st[k] = o
            }
          }
        None => ()
      }
    None => ()
  }
  self.fill_answered(st)
  if self.state is None {
    self.state = Some(st)
  }
}

///|
/// Each station a session wrote to answered from now where nothing was kept of when (none kept from before).
fn ChatShares::fill_answered(self : ChatShares, st : Map[String, Json]) -> Unit {
  let now = (self.deps.clock.now)()
  let replies = section(st, "replies")
  let answered = section(st, "answered")
  for session in js_keys(replies) {
    let at = match answered.get(session) {
      Some(Object(o)) => o
      Some(_) => {
        // (`??=` keeps what is there, an object or not: what is not gets nothing set on it)
        continue
      }
      None => {
        let o : Map[String, Json] = Map([])
        answered[session] = Json::object(o)
        o
      }
    }
    match replies[session] {
      Array(stations) =>
        for s in stations {
          let key = js_string(Some(s))
          if at.get(key) is None || at.get(key) is Some(Null) {
            at[key] = jnum(now)
          }
        }
      _ => ()
    }
  }
}

///|
fn ChatShares::st(self : ChatShares) -> Map[String, Json] {
  match self.state {
    Some(s) => s
    None => {
      let st : Map[String, Json] = Map([])
      for k in xshare_keys {
        st[k] = Json::object(Map([]))
      }
      self.state = Some(st)
      st
    }
  }
}

///|
fn ChatShares::sec(self : ChatShares, k : String) -> Map[String, Json] {
  section(self.st(), k)
}

///|
/// The state as state.json holds it (tests).
pub fn ChatShares::state_json(self : ChatShares) -> Json {
  Json::object(self.st())
}

///|
/// Written through off the station's thread (only this keeps it: what is read is the copy in memory).
fn ChatShares::write_state(self : ChatShares) -> Unit {
  let file = match self.file {
    Some(f) => f
    None => {
      let f = PrivateFile::new(self.files, self.files.join([self.root(), "state.json"]), self.tasks)
      self.file = Some(f)
      f
    }
  }
  file.write(js_stringify2(Json::object(self.st())))
}

///|
/// Once what was asked of state.json is written.
pub async fn ChatShares::written(self : ChatShares) -> Unit {
  if self.file is Some(f) {
    f.written()
  }
}

///|
fn ChatShares::home(self : ChatShares) -> String? {
  (self.deps.cloud.home)()
}

///|
fn ChatShares::station(self : ChatShares) -> String? {
  (self.deps.cloud.station)()
}

///|
fn ChatShares::name_of(self : ChatShares, ws : String) -> String {
  match (self.deps.cloud.membership)(ws) {
    Some(m) => m.workspace_name
    None => ws
  }
}

///|
fn ChatShares::chat_ws(self : ChatShares, chat : String) -> String? {
  match self.deps.chat_ws {
    Some(f) =>
      match f(chat) {
        Some(w) => Some(w)
        None => self.home()
      }
    None => self.home()
  }
}

///|
/// The workspace of this station's a chat borrowed or a host said is for.
fn ChatShares::as_of(self : ChatShares, b : Map[String, Json]) -> String? {
  match b.get("as") {
    None | Some(Null) => self.home()
    v => Some(js_string(v))
  }
}

///|
/// The station a key in `hosts` is of, with the workspace of this station's it is for.
fn ChatShares::host_key(self : ChatShares, key : String, h : Map[String, Json]) -> (String?, String) {
  let station = match key.find("/") {
    Some(at) => key.view(start_offset=at + 1).to_string()
    None => key
  }
  (self.as_of(h), station)
}

///|
/// The host a member of workspace `as` said to take chats from, and its key in `hosts`.
fn ChatShares::host_of(self : ChatShares, station : String, as_ : String?) -> (String, Map[String, Json])? {
  let hosts = self.sec("hosts")
  for key in js_keys(hosts) {
    guard entry_of(hosts, key) is Some(h) else { continue }
    if self.host_key(key, h).1 == station && self.as_of(h) == as_ {
      return Some((key, h))
    }
  }
  None
}

///|
/// The workspace a station that is not of workspace `as` is in, as far as this one knows; None when it knows none.
pub fn ChatShares::workspace_of(self : ChatShares, station : String, as_? : String?? = None) -> String? {
  let a = match as_ {
    None => self.home()
    Some(x) => x
  }
  if self.host_of(station, a) is Some((_, h)) {
    return str_of(h.get("workspace"))
  }
  let borrowed = self.sec("borrowed")
  for k in js_keys(borrowed) {
    guard entry_of(borrowed, k) is Some(b) else { continue }
    if b.get("station") is Some(String(s)) && s == station && self.as_of(b) == a {
      return str_of(b.get("workspace"))
    }
  }
  self.guest_of(station)
}

///|
/// The workspace a station is in that chats here are shared with, or None.
fn ChatShares::guest_of(self : ChatShares, station : String) -> String? {
  let guests = self.sec("guests")
  for workspace in js_keys(guests) {
    if get(get(Some(guests[workspace]), "stations"), station) is Some(_) {
      return Some(workspace)
    }
  }
  None
}

///|
fn in_stations(g : Json?, station : String) -> Bool {
  match get(g, "stations") {
    Some(Object(m)) => m.contains(station)
    _ => false
  }
}

///|
/// The workspaces chats here are shared with that a station asks for.
fn ChatShares::guests_of(self : ChatShares, station : String, as_ : Json?) -> Array[String] {
  let guests = self.sec("guests")
  if as_ is Some(String(a)) {
    return if in_stations(guests.get(a), station) { [a] } else { [] }
  }
  js_keys(guests).filter(w => in_stations(guests.get(w), station))
}

///|
/// Whether this station may ask `target` of workspace `workspace` (not its own) anything.
pub fn ChatShares::reaches(self : ChatShares, target : String, workspace : String) -> Bool {
  let hosts = self.sec("hosts")
  for key in js_keys(hosts) {
    guard entry_of(hosts, key) is Some(h) else { continue }
    if self.host_key(key, h).1 == target && h.get("workspace") is Some(String(w)) && w == workspace {
      return true
    }
  }
  let borrowed = self.sec("borrowed")
  for k in js_keys(borrowed) {
    guard entry_of(borrowed, k) is Some(b) else { continue }
    if b.get("station") is Some(String(s)) && s == target && b.get("workspace") is Some(String(w)) && w == workspace {
      return true
    }
  }
  in_stations(self.sec("guests").get(workspace), target)
}

///|
/// A request to another station as it is sent: to one of another workspace with that workspace.
pub fn ChatShares::address(self : ChatShares, station : String, request : Json) -> Json {
  let as_ = match get(Some(request), "workspace") {
    Some(String(w)) => Some(w)
    _ => self.home()
  }
  let own = match as_ {
    Some(a) => (self.deps.cloud.membership)(a)
    None => None
  }
  // Out of it (or a station of it): the transport says.
  guard own is Some(m) && !m.peers.iter().any(p => get(Some(p), "id") is Some(String(id)) && id == station) else {
    return request
  }
  guard self.workspace_of(station, as_=Some(as_)) is Some(workspace) else { return request }
  let out : Map[String, Json] = Map([])
  if request is Object(r) {
    for k in js_keys(r) {
      out[k] = r[k]
    }
  }
  out["workspace"] = jstr(workspace)
  // For which of this station's workspaces, when it is not plain.
  if as_ != self.home() || (self.deps.cloud.membership)(workspace) is Some(_) {
    out["as"] = match as_ {
      Some(a) => jstr(a)
      None => jnull()
    }
  }
  Json::object(out)
}

///|
/// A request to another station as `address` makes it, sent. A message of a session to another workspace's lets that
/// station answer it from then; one not taken, no more than before.
pub async fn ChatShares::send(self : ChatShares, station : String, request : Json, send : async (Json) -> Json) -> Json {
  let addressed = self.address(station, request)
  let session = if get(Some(request), "method") is Some(String("session.message")) &&
    !physical_equal(addressed, request) &&
    get(Some(request), "session") is Some(String(s)) {
    Some(s)
  } else {
    None
  }
  guard session is Some(s) else { return send(addressed) }
  let replies = self.sec("replies")
  let answered = self.sec("answered")
  let before = (replies.get(s), answered.get(s))
  self.note_sent(s, station)
  try {
    send(addressed)
  } catch {
    e => {
      let replies = self.sec("replies")
      let answered = self.sec("answered")
      match before.0 {
        None => replies.remove(s)
        Some(v) => replies[s] = v
      }
      match before.1 {
        None => answered.remove(s)
        Some(v) => answered[s] = v
      }
      self.write_state()
      raise e
    }
  }
}

///|
fn ChatShares::note_sent(self : ChatShares, session : String, station : String) -> Unit {
  let replies = self.sec("replies")
  let answered = self.sec("answered")
  let had = match replies.get(session) {
    Some(Array(a)) => a
    _ => []
  }
  if !had.contains(jstr(station)) {
    replies[session] = jarr(had + [jstr(station)])
  }
  let at : Map[String, Json] = Map([])
  match answered.get(session) {
    Some(Object(o)) =>
      for k in js_keys(o) {
        at[k] = o[k]
      }
    _ => ()
  }
  at[station] = jnum((self.deps.clock.now)())
  answered[session] = Json::object(at)
  let keys = js_keys(replies)
  let drop = keys.length() - max_replies
  if drop > 0 {
    for k in keys[0:drop] {
      replies.remove(k)
      answered.remove(k)
    }
  }
  self.write_state()
}

///|
/// Whether `station` may answer session `session` here: it wrote to it, and it or that station spoke within
/// XSHARE_IDLE_MS (which it does now, from when it goes on).
fn ChatShares::answers(self : ChatShares, session : String, station : String) -> Bool {
  let replies = self.sec("replies")
  guard replies.get(session) is Some(Array(list)) && list.contains(jstr(station)) else { return false }
  let now = (self.deps.clock.now)()
  let answered = self.sec("answered")
  let last = match get(answered.get(session), station) {
    None | Some(Null) => 0.0
    v => js_num(v)
  }
  if now - last >= xshare_idle_ms {
    return false
  }
  let at = match answered.get(session) {
    Some(Object(o)) => o
    _ => {
      let o : Map[String, Json] = Map([])
      answered[session] = Json::object(o)
      o
    }
  }
  at[station] = jnum(now)
  self.write_state()
  true
}

// ── running ──

///|
pub fn ChatShares::start(self : ChatShares) -> Unit raise {
  self.lapse_later()
  self.stops.push((self.deps.cloud.listen)(() => self.reconcile_soon()))
  self.stops.push(
    (self.deps.store.subscribe)(change => {
      // A shared chat's name changed: told again. Its session deleted: no longer shared.
      try {
        match get(Some(change), "type") {
          Some(String("thread")) => {
            let home = (self.deps.store.thread_home)(js_string(get(Some(change), "id")))
            if home is Some(h) && (self.deps.store.chat_share)(h) is Some(_) {
              self.reconcile_soon()
            }
          }
          Some(String("sessionRemoved")) => {
            let key = js_string(get(Some(change), "key"))
            if (self.deps.store.chat_share)(key) is Some(_) || (self.deps.store.chat_share_lapsed)(key, None) {
              (self.deps.store.set_chat_share)(key, [], false, "")
              self.reconcile_soon()
            }
          }
          _ => ()
        }
      } catch {
        e => self.deps.log.warn("xshare", "a change of the store not followed", jobj([("error", jstr(error_words(e)))]))
      }
    }),
  )
  self.reconcile_soon()
}

///|
pub async fn ChatShares::close(self : ChatShares) -> Unit {
  self.closed = true
  for stop in self.stops {
    stop()
  }
  self.stops.clear()
  if self.lapsing is Some(off) {
    off()
  }
  self.lapsing = None
  if self.retry is Some(off) {
    off()
  }
  self.retry = None
  self.written()
}

///|
fn ChatShares::prepare(self : ChatShares) -> Unit {
  if self.deps.prepare_index is Some(f) {
    f()
  }
}

///|
/// Once the next share lapses (unused too long), its chat's views change and its workspace's stations are told.
fn ChatShares::lapse_later(self : ChatShares) -> Unit raise {
  self.prepare()
  if self.lapsing is Some(off) {
    off()
  }
  self.lapsing = None
  let next = (self.deps.store.lapse_chat_shares)(self.lapsed)
  self.lapsed = (self.deps.clock.now)()
  guard next is Some(n) && !self.closed else { return }
  self.lapsing = Some(
    (self.deps.clock.after)(n - self.lapsed, () => {
      self.lapsing = None
      self.lapse_later() catch {
        e => self.deps.log.warn("xshare", "chat shares not lapsed", jobj([("error", jstr(error_words(e)))]))
      }
      self.reconcile_soon()
    }),
  )
}

///|
/// Brings what is told and asked in line, without waiting: one at a time, again if asked meanwhile.
pub fn ChatShares::reconcile_soon(self : ChatShares) -> Unit {
  self.prepare()
  if self.reconciling is Some(_) {
    self.again = true
    return
  }
  let done : @effect.Deferred[Unit] = @effect.Deferred::new()
  self.reconciling = Some(done)
  self.tasks.spawn(async fn() {
    defer {
      self.reconciling = None
      ignore(done.succeed(()))
    }
    while true {
      self.again = false
      self.reconcile_once() catch {
        e => self.deps.log.warn("xshare", "bringing chat shares in line failed", jobj([("error", jstr(error_words(e)))]))
      }
      if !self.again {
        break
      }
    }
  })
}

///|
/// Brings what is told and asked in line: one at a time, again if asked meanwhile.
pub async fn ChatShares::reconcile(self : ChatShares) -> Unit {
  self.reconcile_soon()
  match self.reconciling {
    Some(d) => d.wait()
    None => ()
  }
}

///|
/// xshare/index.ts `hashOf`: of anything, its `JSON.stringify`.
fn xhash(v : Json) -> String {
  sha_text(js_stringify(v))
}

///|
fn share_to(share : Json) -> Array[Json] {
  match get(Some(share), "to") {
    Some(Array(a)) => a
    _ => []
  }
}

///|
fn to_ws(t : Json) -> String {
  js_string(get(Some(t), "workspace"))
}

///|
async fn ChatShares::reconcile_once(self : ChatShares) -> Unit {
  guard self.home() is Some(_) && self.station() is Some(_) else { return }
  let pending = Ref(false)
  let tell = async fn(station : String, workspace : String, request : Json) -> Bool {
    let out : Map[String, Json] = Map([])
    if request is Object(r) {
      for k in js_keys(r) {
        out[k] = r[k]
      }
    }
    out["workspace"] = jstr(workspace)
    try {
      ignore((self.deps.ask)(station, Json::object(out)))
      true
    } catch {
      e => {
        pending.val = true
        self.deps.log.info("xshare", "a station of another workspace was not told", jobj([("station", jstr(station)), ("error", jstr(error_words(e)))]))
        false
      }
    }
  }

  // The chats shared from here: each station of the workspaces they are for told of their version, the ones no
  // longer for it that they are not.
  let shares = (self.deps.store.chat_shares)()
  let shared_chats : Set[String] = Set::new()
  for s in shares {
    shared_chats.add(s.0)
  }
  let hosted_all = self.sec("hosted")
  for s in shares {
    let (chat, share) = s
    guard (self.deps.link)(chat) is Some(link) else { continue }
    let title = (self.deps.title)(chat)
    let write = get(Some(share), "write").unwrap_or(jnull())
    let hash = xhash(
      jobj([
        ("to", jstrs(js_sorted(share_to(share).map(to_ws)))),
        ("write", write),
        ("title", jstr(title)),
        ("link", jstr(link)),
      ]),
    )
    let hosted = match entry_of(hosted_all, chat) {
      Some(h) => h
      None => {
        let h : Map[String, Json] = Map([])
        h["version"] = jnum(0.0)
        h["hash"] = jstr("")
        h["told"] = Json::object(Map([]))
        hosted_all[chat] = Json::object(h)
        h
      }
    }
    if !(hosted.get("hash") is Some(String(x)) && x == hash) {
      hosted["version"] = jnum_js(js_num(hosted.get("version")) + 1.0)
      hosted["hash"] = jstr(hash)
    }
    self.write_state()
    let audience = self.audience(share)
    // Of the workspace it is in.
    let from = self.chat_ws(chat).unwrap_or("")
    for a in audience {
      let (station, workspace) = a
      let told = obj_field(hosted, "told")
      if strict_eq(told.get(station), hosted.get("version")) {
        continue
      }
      let version = hosted.get("version").unwrap_or(jnull())
      let said = jobj([
        ("method", jstr("xshare.changed")),
        ("chat", jstr(chat)),
        ("version", version),
        ("title", jstr(title)),
        ("link", jstr(link)),
        ("write", write),
        ("from", jstr(from)),
        ("fromName", jstr(self.name_of(from))),
      ])
      if tell(station, workspace, said) {
        obj_field(hosted, "told")[station] = version
      }
    }
    let told = obj_field(hosted, "told")
    for station in js_keys(told) {
      if audience.iter().any(a => a.0 == station) {
        continue
      }
      let workspace = self.guest_of(station)
      if workspace is None ||
        tell(station, workspace.unwrap(), jobj([("method", jstr("xshare.changed")), ("chat", jstr(chat)), ("gone", jbool(true))])) {
        told.remove(station)
      }
    }
  }
  for chat in js_keys(hosted_all) {
    if shared_chats.contains(chat) {
      continue
    }
    guard entry_of(hosted_all, chat) is Some(hosted) else { continue }
    let told = obj_field(hosted, "told")
    for station in js_keys(told) {
      let workspace = self.guest_of(station)
      if workspace is None ||
        tell(station, workspace.unwrap(), jobj([("method", jstr("xshare.changed")), ("chat", jstr(chat)), ("gone", jbool(true))])) {
        told.remove(station)
      }
    }
    if told.is_empty() {
      hosted_all.remove(chat)
    }
  }
  // Workspaces nothing is shared with any more, once told so: forgotten (those a share with lapsed are answered why).
  let used : Set[String] = Set::new()
  for s in shares {
    for t in share_to(s.1) {
      used.add(to_ws(t))
    }
  }
  let guests = self.sec("guests")
  for w in (self.deps.store.lapsed_share_workspaces)(Some(js_keys(guests))) {
    used.add(w)
  }
  for workspace in js_keys(guests) {
    if used.contains(workspace) {
      continue
    }
    let g = guests.get(workspace)
    let still_told = js_keys(hosted_all).iter().any(c => match get(hosted_all.get(c), "told") {
      Some(Object(t)) => js_keys(t).iter().any(st => in_stations(g, st))
      _ => false
    })
    if still_told {
      continue
    }
    guests.remove(workspace)
  }
  self.write_state()

  // The chats shared with this station's workspaces: each host asked once a run what it shares, and told the stations
  // of the workspace that takes them when they changed.
  let host_keys : Array[String] = []
  let hosts : Map[String, (String, String, String)] = Map([])
  let borrowed_all = self.sec("borrowed")
  for k in js_keys(borrowed_all) {
    guard entry_of(borrowed_all, k) is Some(b) else { continue }
    guard self.as_of(b) is Some(as_) else { continue }
    let key = "\{as_}/\{js_string(b.get("station"))}"
    if !hosts.contains(key) {
      host_keys.push(key)
    }
    hosts[key] = (as_, js_string(b.get("station")), js_string(b.get("workspace")))
  }
  let hosts_all = self.sec("hosts")
  for key in js_keys(hosts_all) {
    guard entry_of(hosts_all, key) is Some(h) else { continue }
    let (as_, host) = self.host_key(key, h)
    guard as_ is Some(a) else { continue }
    let k = "\{a}/\{host}"
    if !hosts.contains(k) {
      host_keys.push(k)
      hosts[k] = (a, host, js_string(h.get("workspace")))
    }
  }
  for key in host_keys {
    let (as_, host, workspace) = hosts[key]
    // A workspace this station is out of asks nothing.
    if (self.deps.cloud.membership)(as_) is None {
      continue
    }
    let of_host = (b : Map[String, Json]) => b.get("station") is Some(String(s)) && s == host && self.as_of(b) == Some(as_)
    if !self.listed.contains(key) {
      let mark = self.heard.get(key).unwrap_or(0)
      try {
        let got = (self.deps.ask)(host, jobj([("method", jstr("xshare.list")), ("workspace", jstr(workspace)), ("as", jstr(as_))]))
        self.listed.add(key)
        self.took(host, workspace, as_, got, self.heard.get(key).unwrap_or(0) == mark)
      } catch {
        e =>
          if !(e is Refused(_)) {
            pending.val = true
          } else if self.heard.get(key).unwrap_or(0) == mark {
            // It shares nothing with this workspace (any more).
            self.listed.add(key)
            let borrowed_now = self.sec("borrowed")
            for k in js_keys(borrowed_now) {
              if entry_of(borrowed_now, k) is Some(b) && of_host(b) {
                borrowed_now.remove(k)
              }
            }
          }
      }
    }
    let roster = self.roster(as_)
    let borrowed_now = self.sec("borrowed")
    let any = js_keys(borrowed_now).iter().any(k => entry_of(borrowed_now, k) is Some(b) && of_host(b))
    if roster is Some((stations, hash)) && any && !(self.sec("roster").get(key) is Some(String(x)) && x == hash) {
      try {
        ignore(
          (self.deps.ask)(
            host,
            jobj([
              ("method", jstr("xshare.roster")),
              ("workspace", jstr(workspace)),
              ("stations", jarr(stations.map(s => jobj([("id", jstr(s.0)), ("name", jstr(s.1))])))),
              ("as", jstr(as_)),
            ]),
          ),
        )
        self.sec("roster")[key] = jstr(hash)
      } catch {
        e => if !(e is Refused(_)) { pending.val = true }
      }
    }
  }
  let roster_all = self.sec("roster")
  for key in js_keys(roster_all) {
    if !hosts.contains(key) {
      roster_all.remove(key)
    }
  }
  self.write_state()
  if !pending.val {
    self.retry_wait = xshare_retry_ms
  } else if self.retry is None && !self.closed {
    let wait = self.retry_wait
    self.retry_wait = if self.retry_wait * 2.0 < xshare_retry_max_ms { self.retry_wait * 2.0 } else { xshare_retry_max_ms }
    self.retry = Some(
      (self.deps.clock.after)(wait, () => {
        self.retry = None
        self.reconcile_soon()
      }),
    )
  }
}

///|
/// The stations a chat is shared with now: each with its workspace (this one is told nothing: it has the chat).
fn ChatShares::audience(self : ChatShares, share : Json) -> Array[(String, String)] {
  let guests = self.sec("guests")
  let me = self.station()
  let out : Array[(String, String)] = []
  for t in share_to(share) {
    let ws = to_ws(t)
    match get(guests.get(ws), "stations") {
      Some(Object(stations)) =>
        for station in js_keys(stations) {
          if Some(station) == me {
            continue
          }
          match out.search_by(a => a.0 == station) {
            Some(i) => out[i] = (station, ws)
            None => out.push((station, ws))
          }
        }
      _ => ()
    }
  }
  out
}

///|
/// The stations of workspace `as` as the control plane said last, and their hash; None while that is not current.
fn ChatShares::roster(self : ChatShares, as_ : String) -> (Array[(String, String)], String)? {
  let cloud = self.deps.cloud
  guard (cloud.peers_current)() && (cloud.membership)(as_) is Some(of) else { return None }
  let stations : Array[(String, String)] = []
  for p in of.peers {
    guard get(Some(p), "id") is Some(String(id)) && is_ws_id(id) else { continue }
    let name = text_most(get(Some(p), "name"), 80)
    stations.push((id, if name == "" { js_slice(id, 8) } else { name }))
  }
  if stations.is_empty() {
    return None
  }
  Some((stations, xhash(jstrs(js_sorted(stations.map(s => s.0))))))
}

///|
/// What a host answered xshare.list with: its chats shared with workspace `as` of this station's, in place of what was
/// had from it (`whole`); added to it, the newer of each, when the host said something changed meanwhile.
fn ChatShares::took(self : ChatShares, host : String, workspace : String, as_ : String, got : Json, whole : Bool) -> Unit raise {
  let borrowed = self.sec("borrowed")
  if whole {
    for k in js_keys(borrowed) {
      if entry_of(borrowed, k) is Some(b) && b.get("station") is Some(String(s)) && s == host && self.as_of(b) == Some(as_) {
        borrowed.remove(k)
      }
    }
  }
  let chats = match get(Some(got), "chats") {
    Some(Array(a)) => a
    _ => []
  }
  let from_name = text_most(get(Some(got), "fromName"), 80)
  for c in chats {
    guard self.borrowed_from(host, workspace, if from_name == "" { workspace } else { from_name }, c) is Some(b) else {
      continue
    }
    let chat = js_string(b.get("chat"))
    let had = self.borrowed_at(host, chat, Some(as_))
    let had_version = match had {
      Some((_, h)) => js_num(h.get("version"))
      None => -1.0
    }
    if whole || had_version < js_num(b.get("version")) {
      if had is Some((k, _)) {
        borrowed.remove(k)
      }
      b["as"] = jstr(as_)
      borrowed["\{as_}/\{host}/\{chat}"] = Json::object(b)
    }
  }
  self.write_state()
}

///|
/// A chat borrowed from `host` for workspace `as`, with its key.
fn ChatShares::borrowed_at(self : ChatShares, host : String, chat : String, as_ : String?) -> (String, Map[String, Json])? {
  let borrowed = self.sec("borrowed")
  for k in js_keys(borrowed) {
    guard entry_of(borrowed, k) is Some(b) else { continue }
    if b.get("station") is Some(String(s)) && s == host && b.get("chat") is Some(String(c)) && c == chat && self.as_of(b) == as_ {
      return Some((k, b))
    }
  }
  None
}

///|
/// A chat as its host describes it, checked: its link must be of that host and workspace.
fn ChatShares::borrowed_from(self : ChatShares, host : String, workspace : String, workspace_name : String, c : Json) -> Map[String, Json]? raise {
  ignore(self)
  let chat = text_most(get(Some(c), "chat"), 200)
  let link = text_most(get(Some(c), "link"), 1000)
  guard link_parts(link) is Some((ws, station, _)) && chat != "" && station == host && ws == workspace else { return None }
  let title = text_most(get(Some(c), "title"), 200)
  let out : Map[String, Json] = Map([])
  out["workspace"] = jstr(workspace)
  out["workspaceName"] = jstr(workspace_name)
  out["station"] = jstr(host)
  out["chat"] = jstr(chat)
  out["title"] = jstr(if title == "" { chat } else { title })
  out["link"] = jstr(link)
  out["write"] = jbool(get(Some(c), "write") is Some(True))
  out["version"] = jnum_js(num_or0(get(Some(c), "version")))
  Some(out)
}

// ── requests ──

///|
/// A request of a station of one of this station's workspaces (`workspace`: which; None: the home one).
pub async fn ChatShares::inside(self : ChatShares, peer : String, request : Json, workspace? : String? = None) -> Json {
  let asked = match get(Some(request), "method") {
    None | Some(Null) => ""
    m => js_string(m)
  }
  if asked == "xshare.trusts" {
    let station = match get(Some(request), "station") {
      None | Some(Null) => ""
      s => js_string(s)
    }
    guard self.host_of(station, match workspace { Some(_) => workspace; None => self.home() }) is Some((_, h)) else {
      return jobj([("trusted", jbool(false))])
    }
    let out : Map[String, Json] = Map([])
    out["trusted"] = jbool(true)
    for k in ["workspace", "name", "stationName"] {
      if h.get(k) is Some(v) {
        out[k] = v
      }
    }
    return Json::object(out)
  }
  if asked.has_prefix("xshare.") {
    return self.outside(peer, request, workspace~)
  }
  raise Failed("unknown request \{asked}")
}

///|
/// A request of a station that is not of this workspace: only what is shared with its workspace, or an answer to a
/// session here that wrote to it.
pub async fn ChatShares::outside(self : ChatShares, peer : String, request : Json, workspace? : String? = None) -> Json {
  let rq = Some(request)
  let asked = match get(rq, "method") {
    None | Some(Null) => ""
    m => js_string(m)
  }
  let here = match workspace {
    Some(_) => workspace
    None => self.home()
  }
  if asked == "xshare.changed" {
    return self.changed(peer, request, here)
  }
  let to = match get(rq, "to") {
    Some(String(t)) => t
    _ => ""
  }
  if (asked == "session.message" || asked == "session.put") && self.answers(to, peer) {
    return (self.deps.inbox)(peer, request)
  }
  let guests = self.guests_of(peer, get(rq, "as"))
  if guests.is_empty() {
    raise Failed("this station shares no chat with your workspace")
  }
  match asked {
    "describe" =>
      jobj([
        ("protocol", jnum(1.0)),
        ("outside", jbool(true)),
        ("reads", jbool(true)),
        ("messages", jbool(true)),
        ("files", jbool(true)),
      ])
    "xshare.list" => self.list(peer, here, guests)
    "xshare.roster" => self.roster_of(peer, guests[0], request)
    "session.read" | "session.file" => {
      self.check(guests, request, false)
      (self.deps.inbox)(peer, request)
    }
    "session.put" | "session.message" => {
      self.check(guests, request, true)
      (self.deps.inbox)(peer, request)
    }
    _ => raise Failed("\{asked} is not open to other workspaces: only reading and writing in the chats shared with them")
  }
}

///|
/// Whether a request reads (or writes in) a chat shared with one of `workspaces`; raises why not. Its share goes on.
fn ChatShares::check(self : ChatShares, workspaces : Array[String], request : Json, write : Bool) -> Unit raise {
  let store = self.deps.store
  let chats = (self.deps.touches)(request)
  let shared : Array[(String, Json)] = []
  for c in chats {
    if (store.chat_share)(c) is Some(s) && share_to(s).iter().any(t => workspaces.contains(to_ws(t))) {
      shared.push((c, s))
    }
  }
  if shared.is_empty() {
    for c in chats {
      if (store.chat_share_lapsed)(c, Some(workspaces)) {
        raise Failed(lapsed_words)
      }
    }
    raise Failed("that chat is not shared with your workspace")
  }
  if write && !shared.iter().any(s => get(Some(s.1), "write") is Some(True)) {
    raise Failed("that chat is shared with your workspace to read only: nothing can be sent to it")
  }
  for s in shared {
    (store.used_chat_share)(s.0, workspaces)
  }
}

///|
/// xshare.list: the chats of workspace `here` shared with the asking station's workspaces; it has them now.
fn ChatShares::list(self : ChatShares, peer : String, here : String?, workspaces : Array[String]) -> Json raise {
  self.prepare()
  let hosted_all = self.sec("hosted")
  let chats : Array[Json] = []
  for s in (self.deps.store.chat_shares)() {
    let (chat, share) = s
    if !share_to(share).iter().any(t => workspaces.contains(to_ws(t))) || self.chat_ws(chat) != here {
      continue
    }
    guard (self.deps.link)(chat) is Some(link) else { continue }
    let hosted = entry_of(hosted_all, chat)
    let version = match hosted {
      Some(h) =>
        match h.get("version") {
          None | Some(Null) => jnum(0.0)
          Some(v) => v
        }
      None => jnum(0.0)
    }
    chats.push(
      jobj([
        ("chat", jstr(chat)),
        ("title", jstr((self.deps.title)(chat))),
        ("link", jstr(link)),
        ("write", get(Some(share), "write").unwrap_or(jnull())),
        ("version", version),
      ]),
    )
    if hosted is Some(h) {
      obj_field(h, "told")[peer] = h.get("version").unwrap_or(jnull())
    }
  }
  self.write_state()
  jobj([
    ("from", jstr(here.unwrap_or(""))),
    ("fromName", jstr(match here { Some(h) => self.name_of(h); None => "" })),
    ("chats", jarr(chats)),
  ])
}

///|
/// xshare.roster: the stations of the asking station's workspace now, in place of those known; the new ones are told.
fn ChatShares::roster_of(self : ChatShares, peer : String, workspace : String, request : Json) -> Json raise {
  let stations = stations_of(get(Some(request), "stations"))
  if !stations.iter().any(s => s.0 == peer) {
    raise Failed("the stations given must include the one giving them")
  }
  let guests = self.sec("guests")
  let name = match get(guests.get(workspace), "name") {
    None | Some(Null) => jstr(workspace)
    Some(n) => n
  }
  let m : Map[String, Json] = Map([])
  for s in stations {
    m[s.0] = jstr(s.1)
  }
  guests[workspace] = jobj([("name", name), ("stations", Json::object(m))])
  self.write_state()
  self.reconcile_soon()
  jobj([("ok", jbool(true))])
}

///|
/// xshare.changed: a host says a chat is shared with workspace `as` of this station's, changed, or no longer is.
async fn ChatShares::changed(self : ChatShares, peer : String, request : Json, as_ : String?) -> Json {
  guard as_ is Some(a) && (self.deps.cloud.membership)(a) is Some(_) else { raise Failed("this station is in no workspace") }
  let rq = Some(request)
  let from = match get(rq, "from") {
    None | Some(Null) => ""
    f => js_string(f)
  }
  let gone = get(rq, "gone") is Some(True)
  let mut host : Map[String, Json]? = match self.host_of(peer, as_) {
    Some((_, h)) => Some(h)
    None => None
  }
  if host is None && !gone {
    guard self.ask_trust(peer, a) is Some(trusted) else {
      raise Failed("no member of this workspace said to take chats from your station")
    }
    trusted["as"] = jstr(a)
    self.sec("hosts")["\{a}/\{peer}"] = Json::object(trusted)
    host = Some(trusted)
  }
  let chat = text_most(get(rq, "chat"), 200)
  let key = "\{a}/\{peer}"
  self.heard[key] = self.heard.get(key).unwrap_or(0) + 1
  let had = self.borrowed_at(peer, chat, as_)
  let borrowed = self.sec("borrowed")
  if gone {
    if had is Some((k, _)) {
      borrowed.remove(k)
    }
  } else {
    let h = host.unwrap()
    if !(h.get("workspace") is Some(String(w)) && w == from) {
      raise Failed("your station is not of the workspace it was said to be")
    }
    let from_name = text_most(get(rq, "fromName"), 80)
    let name = if from_name == "" { js_string(h.get("name")) } else { from_name }
    guard self.borrowed_from(peer, from, name, request) is Some(b) else {
      raise Failed("a chat's link must be of the station sharing it")
    }
    if had is Some((k, _)) {
      borrowed.remove(k)
    }
    b["as"] = jstr(a)
    borrowed["\{a}/\{peer}/\{chat}"] = Json::object(b)
  }
  self.write_state()
  self.reconcile_soon()
  jobj([("heard", jbool(true))])
}

///|
/// Whether another station of workspace `as` was told to take chats from `station`: its word on it.
async fn ChatShares::ask_trust(self : ChatShares, station : String, as_ : String) -> Map[String, Json]? {
  let me = self.station()
  guard (self.deps.cloud.membership)(as_) is Some(of) && (self.deps.cloud.peers_current)() else { return None }
  let peers = of.peers.filter_map(p => match get(Some(p), "id") {
    Some(String(id)) if Some(id) != me => Some(id)
    _ => None
  })
  let answers = @effect.all(
    peers.map(p => async fn() -> Json {
      (self.deps.ask)(p, jobj([("method", jstr("xshare.trusts")), ("station", jstr(station)), ("workspace", jstr(as_))])) catch {
        _ => jnull()
      }
    }),
  )
  for a in answers {
    if get(Some(a), "trusted") is Some(True) && get(Some(a), "workspace") is Some(String(w)) && is_ws_id(w) {
      let name = text_most(get(Some(a), "name"), 80)
      let out : Map[String, Json] = Map([])
      out["workspace"] = jstr(w)
      out["name"] = jstr(if name == "" { w } else { name })
      out["stationName"] = jstr(text_most(get(Some(a), "stationName"), 80))
      return Some(out)
    }
  }
  None
}

// ── the pages ──

///|
/// Shares chat `chat` with workspaces `to` (none: no longer), as `by`: `[{workspace, name, stations: [{id, name}]}]`.
pub fn ChatShares::share(self : ChatShares, chat : String, to : Array[Json], write : Bool, by : String) -> Json? raise {
  if self.home() is None {
    raise Failed("this station is in no workspace")
  }
  if to.length() > max_to {
    raise Failed("at most \{max_to} workspaces")
  }
  let guests = self.sec("guests")
  // Its own workspace is the one it is in.
  let own = self.chat_ws(chat)
  for t in to {
    guard get(Some(t), "workspace") is Some(String(w)) && is_ws_id(w) && Some(w) != own else {
      raise Failed("to: other workspaces, each {workspace, name, stations}")
    }
    let m : Map[String, Json] = Map([])
    for s in stations_of(get(Some(t), "stations")) {
      m[s.0] = jstr(s.1)
    }
    let g : Map[String, Json] = Map([])
    if get(Some(t), "name") is Some(n) {
      g["name"] = n
    }
    g["stations"] = Json::object(m)
    guests[w] = Json::object(g)
  }
  self.write_state()
  (self.deps.store.set_chat_share)(
    chat,
    to.map(t => {
      let name = text_most(get(Some(t), "name"), 80)
      (to_ws(t), if name == "" { to_ws(t) } else { name })
    }),
    write,
    by,
  )
  self.lapse_later()
  self.reconcile_soon()
  guard (self.deps.store.chat_share)(chat) is Some(now) else { return None }
  let out : Map[String, Json] = Map([])
  if now is Object(n) {
    for k in js_keys(n) {
      out[k] = n[k]
    }
  }
  out["to"] = jarr(share_to(now).map(t => jobj([("workspace", get(Some(t), "workspace").unwrap_or(jnull())), ("name", get(Some(t), "name").unwrap_or(jnull()))])))
  Some(Json::object(out))
}

///|
/// A member of workspace `as` of this station's says it takes chats from `station`, of workspace `workspace`.
pub fn ChatShares::trust(
  self : ChatShares,
  workspace : String,
  name : String,
  station : String,
  station_name : String,
  as_? : String? = None,
) -> Unit raise {
  let of = match as_ {
    Some(_) => as_
    None => self.home()
  }
  guard of is Some(o) && (self.deps.cloud.membership)(o) is Some(_) else { raise Failed("this station is in no workspace") }
  if !is_ws_id(workspace) || workspace == o || !is_ws_id(station) {
    raise Failed("workspace and station are another workspace's")
  }
  let hosts = self.sec("hosts")
  if self.host_of(station, of) is Some((k, _)) {
    hosts.remove(k)
  }
  let n = text_most(Some(jstr(name)), 80)
  hosts["\{o}/\{station}"] = jobj([
    ("workspace", jstr(workspace)),
    ("name", jstr(if n == "" { workspace } else { n })),
    ("stationName", jstr(text_most(Some(jstr(station_name)), 80))),
    ("as", jstr(o)),
  ])
  self.listed.remove("\{o}/\{station}")
  self.write_state()
  self.reconcile_soon()
}

///|
/// The chats of other workspaces shared with workspace `as` of this station's, the latest first.
pub fn ChatShares::borrowed(self : ChatShares, as_? : String? = None) -> Array[Json] raise {
  self.prepare()
  let of = match as_ {
    Some(_) => as_
    None => self.home()
  }
  let borrowed = self.sec("borrowed")
  let theirs : Array[Json] = []
  for k in js_keys(borrowed) {
    if entry_of(borrowed, k) is Some(b) && self.as_of(b) == of {
      theirs.push(borrowed[k])
    }
  }
  let me = self.station()
  let ours : Array[Json] = []
  if of is Some(o) && me is Some(m) {
    let hosted_all = self.sec("hosted")
    for s in (self.deps.store.chat_shares)() {
      let (chat, share) = s
      let ws = self.chat_ws(chat)
      let link = (self.deps.link)(chat)
      guard ws is Some(w) && w != o && link is Some(l) && share_to(share).iter().any(t => to_ws(t) == o) else { continue }
      ours.push(
        jobj([
          ("workspace", jstr(w)),
          ("workspaceName", jstr(self.name_of(w))),
          ("station", jstr(m)),
          ("chat", jstr(chat)),
          ("title", jstr((self.deps.title)(chat))),
          ("link", jstr(l)),
          ("write", get(Some(share), "write").unwrap_or(jnull())),
          (
            "version",
            match entry_of(hosted_all, chat) {
              Some(h) =>
                match h.get("version") {
                  None | Some(Null) => jnum(0.0)
                  Some(v) => v
                }
              None => jnum(0.0)
            },
          ),
          ("as", jstr(o)),
        ]),
      )
    }
  }
  stable_sort(theirs + ours, (a, b) => {
    let d = js_num(get(Some(b), "version")) - js_num(get(Some(a), "version"))
    if d > 0.0 {
      1
    } else if d < 0.0 {
      -1
    } else {
      0
    }
  })
}
