// Feishu as a chat surface (station/src/feishu/surface.ts): its long connection for what Feishu tells the station,
// the OpenAPI for what the station and its agents say and ask. One FeishuSurface per connected connect.
//
// The socket is kept up as every connect's is (connects/surface.ts `socketTo`: connected again whenever it closes,
// pinged, taken for dead once it says nothing): that loop is the connects' own; what Feishu says on its socket is
// here (`socket_hooks`: as it opens, each binary frame, each ping). What the connects' surface keeps of people (their
// names for the connection's lifetime, `kept` answers) and of the threads' status lines is kept here as it was in it.

///|
/// Who the bot is and where (connects/connections.ts `BotIdentity`).
#derive(Eq, Debug)
pub(all) struct BotIdentity {
  team : String
  team_id : String
  url : String
  bot_user_id : String
  bot_name : String
  bot_image : String?
  bot_id : String
}

///|
pub fn BotIdentity::to_jv(self : BotIdentity) -> JV {
  jobj([
    ("team", Some(js(self.team))),
    ("teamId", Some(js(self.team_id))),
    ("url", Some(js(self.url))),
    ("botUserId", Some(js(self.bot_user_id))),
    ("botName", Some(js(self.bot_name))),
    ("botImage", Some(jopt(self.bot_image))),
    ("botId", Some(js(self.bot_id))),
  ])
}

///|
/// A person as a platform says (sessions/chat.ts `Person`).
#derive(Eq, Debug)
pub(all) struct Person {
  name : String
  email : String
}

///|
pub fn Person::to_jv(self : Person) -> JV {
  jobj([("name", Some(js(self.name))), ("email", Some(js(self.email)))])
}

///|
/// Someone in a group (sessions/chat.ts `Member`).
pub(all) struct Member {
  id : String
  name : String
}

///|
/// A group the bot is in (sessions/chat.ts `Place`).
pub(all) struct Place {
  id : String
  name : String
  kind : String
}

///|
/// A thread (sessions/chat.ts `ThreadRef`).
#derive(Eq, Debug)
pub(all) struct ThreadRef {
  channel : String
  thread_ts : String
}

///|
/// A file the agent posts (store.ts `Attachment`): where it is, its name.
pub(all) struct Attachment {
  path : String
  name : String
}

///|
/// A message of a thread's past (sessions/chat.ts `ChatMessage`).
pub(all) struct ChatMessage {
  ts : String
  user : String
  text : String
  from_bot : Bool
  files : Array[InboundFile]
}

///|
pub fn ChatMessage::to_jv(self : ChatMessage) -> JV {
  jobj([
    ("ts", Some(js(self.ts))),
    ("user", Some(js(self.user))),
    ("text", Some(js(self.text))),
    ("fromBot", Some(Bool(self.from_bot))),
    (
      "files",
      if self.files.length() > 0 {
        Some(Arr(self.files.map(f => f.to_jv())))
      } else {
        None
      },
    ),
  ])
}

///|
/// connects/names.ts `NameBook`: what people and chats are called, kept across restarts and answered without waiting
/// (`person`: what is known now, read again by `fetch` where it is not or `stale` says so).
pub(all) struct NameBook {
  person : (String, async () -> Person?, (Person, Double) -> Bool) -> Person?
  channel : (String, async () -> String?) -> String?
}

///|
/// What one socket is to the hooks: what it is sent (a binary frame), and whether it is open.
pub(all) struct Socket {
  send : (Bytes) -> Unit
  is_open : () -> Bool
}

///|
/// What Feishu's socket does besides being kept up (connects/surface.ts `SocketHooks`): as it opens, each binary
/// frame it says (`now`: when, on the surface's clock), and as it is pinged.
pub(all) struct SocketHooks {
  opened : (Socket) -> Unit
  message : (Socket, Bytes, Int64) -> Unit raise FeishuError
  ping : (Socket) -> Unit raise FeishuError
}

///|
/// Who the bot is and where, as the pages are shown a Slack connect's: its name and picture, its open_id as its user,
/// its company as its team.
pub async fn identity_of(client : FeishuClient) -> BotIdentity {
  let info = client.call("GET", "/open-apis/bot/v3/info")
  let bot = nullish(
    jget(Some(info), "bot"),
    nullish(jget(jget(Some(info), "data"), "bot"), Obj([])),
  )
  let mut team = ""
  let mut team_id = ""
  try {
    let t = nullish(
      jget(
        jget(Some(client.call("GET", "/open-apis/tenant/v2/tenant/query")), "data"),
        "tenant",
      ),
      Obj([]),
    )
    team = text(jget(Some(t), "name"))
    team_id = text(jget(Some(t), "tenant_key"))
  } catch {
    _ => ()
  }
  let image = text(jget(Some(bot), "avatar_url"))
  {
    team,
    team_id,
    url: "",
    bot_user_id: text(jget(Some(bot), "open_id")),
    bot_name: text(jget(Some(bot), "app_name")),
    bot_image: if starts(image, "https://") { Some(image) } else { None },
    bot_id: "",
  }
}

///|
/// `/^cli_[0-9a-z]+$/i`.
fn app_id_like(s : String) -> Bool {
  if s.length() < 5 || ascii_lower(s.unsafe_substring(start=0, end=4)) != "cli_" {
    return false
  }
  for i in 4..<s.length() {
    let c = s.unsafe_charcode_at(i)
    if !((c >= '0' && c <= '9') || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')) {
      return false
    }
  }
  true
}

///|
/// Checks an app's id and secret without connecting: its token is taken, its bot read, and the long connection's
/// address asked for. Its problems are said in `lang`.
pub async fn verify_feishu_app(
  net : Net,
  words : Words,
  app_id : String,
  app_secret : String,
  domain : String,
  lang? : String,
) -> (BotIdentity?, Array[String]) {
  let lang = match lang {
    Some(l) => l
    None => (words.station_lang)()
  }
  if !app_id_like(app_id) {
    return (None, [tr0(words, lang, "station.feishu.badAppId")])
  }
  if trim_js(app_secret) == "" {
    return (None, [tr0(words, lang, "station.feishu.noSecret")])
  }
  let client = FeishuClient::new(net, app_id, app_secret, domain~)
  ignore(client.tenant_token()) catch {
    e =>
      return (
        None,
        [
          (words.tr)(lang, "station.feishu.badSecret", {
            "error": Json::string(error_words(e)),
          }),
        ],
      )
  }
  let mut identity = None
  let errors = []
  try {
    let i = identity_of(client)
    identity = Some(i)
    if i.bot_user_id == "" {
      errors.push(tr0(words, lang, "station.feishu.noBot"))
    }
  } catch {
    e =>
      errors.push(
        (words.tr)(lang, "station.feishu.botUnread", {
          "error": Json::string(error_words(e)),
        }),
      )
  }
  ignore(client.endpoint()) catch {
    e =>
      errors.push(
        (words.tr)(lang, "station.feishu.noLongConnection", {
          "error": Json::string(error_words(e)),
        }),
      )
  }
  (identity, errors)
}

///|
/// Node's `path.extname` (POSIX).
pub fn extname(path : String) -> String {
  let mut start_dot = -1
  let mut start_part = 0
  let mut end = -1
  let mut matched_slash = true
  let mut pre_dot_state = 0
  let mut i = path.length() - 1
  while i >= 0 {
    let code = path.unsafe_charcode_at(i)
    if code == '/' {
      if !matched_slash {
        start_part = i + 1
        break
      }
      i -= 1
      continue
    }
    if end == -1 {
      matched_slash = false
      end = i + 1
    }
    if code == '.' {
      if start_dot == -1 {
        start_dot = i
      } else if pre_dot_state != 1 {
        pre_dot_state = 1
      }
    } else if start_dot != -1 {
      pre_dot_state = -1
    }
    i -= 1
  }
  if start_dot == -1 ||
    end == -1 ||
    pre_dot_state == 0 ||
    (pre_dot_state == 1 && start_dot == end - 1 && start_dot == start_part + 1) {
    return ""
  }
  path.unsafe_substring(start=start_dot, end~)
}

///|
/// What Feishu takes as a message's file type, by its name.
pub fn file_type(name : String) -> String {
  let ext = @jscase.lower(extname(name))
  if ext == ".opus" {
    "opus"
  } else if ext == ".mp4" {
    // Only MP4 itself: Feishu checks the container, so a QuickTime .mov goes as a plain file.
    "mp4"
  } else if ext == ".pdf" {
    "pdf"
  } else if ext is (".doc" | ".docx") {
    "doc"
  } else if ext is (".xls" | ".xlsx" | ".csv") {
    "xls"
  } else if ext is (".ppt" | ".pptx") {
    "ppt"
  } else {
    "stream"
  }
}

///|
/// The message type a file of that type is sent as: Feishu refuses any other (230055).
fn file_msg_type(kind : String) -> String {
  if kind == "mp4" {
    "media"
  } else if kind == "opus" {
    "audio"
  } else {
    "file"
  }
}

///|
/// `/\.(png|jpe?g|gif|webp|bmp|ico|tiff?)$/i`.
pub fn is_image_name(name : String) -> Bool {
  let l = ascii_lower(name)
  for ext in [".png", ".jpg", ".jpeg", ".gif", ".webp", ".bmp", ".ico", ".tif", ".tiff"] {
    if l.has_suffix(ext) {
      return true
    }
  }
  false
}

///|
/// Images Feishu takes as images (larger ones go as files).
let max_image : Int = 10 * 1024 * 1024

///|
/// How long who is in a group is kept for (connects/surface.ts `MEMBERS_MS`).
pub let members_ms : Int64 = 60_000L

///|
/// Feishu pings every two minutes; the station asks more often, to find a connection cut on the way sooner.
pub let ping_ms : Int = 15_000

///|
pub let stale_ms : Int = 45_000

///|
/// How long a person known without an email is left before their email is asked for again.
let email_again_ms : Double = 24.0 * 60.0 * 60_000.0

///|
/// A question posted, kept until it is answered: what it said, for the answered card, and the thread it answers in
/// (its card kept with it as the TypeScript keeps it, read by nothing yet).
#warnings("-unused_field")
priv struct Asked {
  text : String
  card : JV
  thread : String
  mut answered : Bool
}

///|
priv struct ChatInfo {
  name : String?
  topics : Bool
  p2p : Bool
}

///|
/// What a surface is given.
pub(all) struct FeishuSurfaceOptions {
  connect : String
  app_id : String
  app_secret : String
  domain : String
  threads : FeishuThreads
  /// In a group, one conversation for each thread, begun by an @ and answered in it (「会话怎么分」); else one
  /// for the group.
  thread_mode : Bool
  /// In a direct chat, one conversation for each thread, as a group's in thread mode: each message outside a thread
  /// begins one, answered in it; else one for the chat.
  direct_threads : Bool
  /// Keeps names across restarts and lets the admin API ask without waiting (knownPerson, knownChannel).
  book : NameBook?
  /// The client (tests: one pointed at a stand-in); None: one of the app's.
  client : FeishuClient?
  net : Net
  words : Words
  log : Log
  disk : Disk
  /// The runtime its fibers run on (its status lines', what it reads in the background).
  rt : @effect.Runtime
}

///|
pub struct FeishuSurface {
  connect : String
  client : FeishuClient
  domain : String
  priv options : FeishuSurfaceOptions
  priv threads : FeishuThreads
  priv thread_mode : Bool
  priv direct_threads : Bool
  priv words : Words
  priv log : Log
  priv book : NameBook?
  priv rt : @effect.Runtime
  /// Who its bot is (connects/surface.ts `me`).
  mut me : BotIdentity?
  /// The messages that called it, the latest kept: a turn for one of them shows its status card at once.
  priv called : Map[String, Unit]
  /// Chats as Feishu says: their name, whether they are a topic group (each topic its own conversation), a direct one.
  priv chats : Map[String, ChatInfo]
  /// The chat a person was last heard in: where their name is looked up when the contacts API will not say it.
  priv heard_in : Map[String, String]
  priv members : Map[String, Map[String, String]]
  priv asked : Map[String, Asked]
  priv parts : Parts
  /// People as the platform says, by their id there (connects/surface.ts `names`).
  priv names : Map[String, Person]
  /// People found by their email (userOf), by it.
  priv by_email : Map[String, String]
  /// Each thread an agent works for: its status line.
  priv lines : Map[String, FeishuStatus]
  /// What `kept` holds: each answer as it was asked for (one asking at a time) and when.
  priv answers : Map[String, (Int64, @effect.Deferred[Array[Member]])]
  priv mut stopped : Bool
}

///|
pub fn FeishuSurface::new(
  options : FeishuSurfaceOptions,
) -> FeishuSurface raise FeishuError {
  if options.app_id == "" || options.app_secret == "" {
    raise FeishuError("feishu.appId and feishu.appSecret are required")
  }
  let client = match options.client {
    Some(c) => c
    None =>
      FeishuClient::new(
        options.net,
        options.app_id,
        options.app_secret,
        domain=options.domain,
      )
  }
  {
    connect: options.connect,
    client,
    domain: options.domain,
    options,
    threads: options.threads,
    thread_mode: options.thread_mode,
    direct_threads: options.direct_threads,
    words: options.words,
    log: options.log,
    book: options.book,
    rt: options.rt,
    me: None,
    called: Map([]),
    chats: Map([]),
    heard_in: Map([]),
    members: Map([]),
    asked: Map([]),
    parts: Parts::new(),
    names: Map([]),
    by_email: Map([]),
    lines: Map([]),
    answers: Map([]),
    stopped: false,
  }
}

///|
/// Who its bot is, as Feishu says now.
pub async fn FeishuSurface::identify(self : FeishuSurface) -> BotIdentity {
  let me = identity_of(self.client)
  if me.bot_user_id != "" {
    self.me = Some(me)
  }
  me
}

///|
/// An identity it cannot work as: a Feishu app without a bot.
pub fn FeishuSurface::usable(
  self : FeishuSurface,
  identity : BotIdentity,
) -> Unit raise FeishuError {
  if identity.bot_user_id == "" {
    raise FeishuError("this Feishu app has no bot: turn on its bot capability")
  }
  self.me = Some(identity)
}

///|
/// Where its socket connects to now (asked again for each).
pub async fn FeishuSurface::address(self : FeishuSurface) -> String {
  self.client.endpoint().0
}

///|
/// Lark is Feishu on larksuite.com.
pub fn FeishuSurface::platform(self : FeishuSurface) -> String {
  if self.domain == "lark" {
    "lark"
  } else {
    "feishu"
  }
}

///|
pub fn FeishuSurface::mention(_self : FeishuSurface, user : String) -> String {
  "<at id=\{user}></at>"
}

///|
/// Not said: the status card links the session's page.
pub fn FeishuSurface::session_link(_self : FeishuSurface) -> String? {
  None
}

///|
pub fn FeishuSurface::bot_user_id(self : FeishuSurface) -> String {
  match self.me {
    Some(m) => m.bot_user_id
    None => ""
  }
}

///|
pub fn FeishuSurface::bot_name(self : FeishuSurface) -> String {
  match self.me {
    Some(m) => m.bot_name
    None => ""
  }
}

///|
pub fn FeishuSurface::workspace(self : FeishuSurface) -> String? {
  match self.me {
    Some(m) if m.team_id != "" => Some(m.team_id)
    _ => None
  }
}

///|
/// The status lines and the socket's hooks stop.
pub fn FeishuSurface::stop(self : FeishuSurface) -> Unit {
  self.stopped = true
}

///|
fn frame_text(b : BytesView) -> String {
  utf8_text(b, bom=true)
}

///|
/// The ping frame Feishu takes on its socket (`service`: the address's `service_id`; one no BigInt can be is refused
/// as `BigInt(service)` refuses it).
fn ping_frame(service : Double) -> Bytes raise FeishuError {
  if !is_finite(service) || service != service.floor() {
    raise FeishuError(
      "The number \{num_text(service)} cannot be converted to a BigInt because it is not an integer",
    )
  }
  encode({
      seq_id: Big::of(0UL),
      log_id: Big::of(0UL),
      service: wrap64(service),
      meth: method_control,
      headers: [("type", "ping")],
      payload_encoding: None,
      payload_type: None,
      payload: None,
      log_id_new: None,
    })
}

///|
/// `Number(new URL(url).searchParams.get("service_id") ?? "0")`.
pub fn service_of(url : String) -> Double raise FeishuError {
  guard @cloud_net.parse_url(url) is Some(u) else { raise FeishuError("Invalid URL") }
  for e in form_parse(u.query.unwrap_or("")) {
    if e.0 == "service_id" {
      return js_number(e.1)
    }
  }
  0.0
}

///|
/// One long connection's hooks (connects/surface.ts keeps it up), pinged with Feishu's own ping frame too. Each event
/// is acknowledged once its handler kept it; one that failed is not, and Feishu sends it again.
pub fn FeishuSurface::socket_hooks(
  self : FeishuSurface,
  url : String,
  handler : async (JV) -> Unit,
) -> SocketHooks raise FeishuError {
  let service = service_of(url)
  let ping = (socket : Socket) => (socket.send)(ping_frame(service))
  {
    opened: socket => {
      ping(socket) catch {
        _ => ()
      }
      ignore(
        self.rt.fork_daemon("feishu catch up", on_error=_ => (), async fn() {
          self.catch_up(handler) catch {
            e =>
              self.log.warn(
                "feishu",
                "what was said while away not read",
                jobj([
                  ("connect", Some(js(self.connect))),
                  ("error", Some(js(error_words(e)))),
                ]),
              )
          }
        }),
      )
    },
    ping,
    message: (socket, bytes, now) => {
      let frame = decode(bytes) catch {
        e => {
          self.log.warn(
            "feishu",
            "feishu frame unreadable",
            jobj([("error", Some(js(error_words(e))))]),
          )
          return
        }
      }
      if frame.meth != method_data {
        return
      }
      let kind = header(frame, "type")
      if kind != Some("event") && kind != Some("card") {
        return
      }
      self.parts.drop(now - 5L * 60_000L)
      let whole = self.parts.add(frame, now)
      guard whole is Some(whole) else { return }
      ignore(
        self.rt.fork_daemon("feishu event", on_error=e => self.log.warn("feishu", "a feishu event was not answered", jobj([("connect", Some(js(self.connect))), ("error", Some(js(error_words(e))))])), async fn() {
          let answer = try {
            let envelope = parse(frame_text(whole))
            self.take(envelope, handler)
          } catch {
            e => {
              // Not acknowledged: Feishu sends it again, and the store dedupes.
              self.log.error(
                "feishu",
                "failed to accept feishu event",
                jobj([
                  ("connect", Some(js(self.connect))),
                  ("error", Some(js(error_words(e)))),
                ]),
              )
              return
            }
          }
          let payload = jobj([("code", Some(jint(200)))])
          match answer {
            Some(a) => jput(payload, "data", js(base64(utf8(stringify(a)))))
            None => ()
          }
          if (socket.is_open)() {
            (socket.send)(
              encode({
                ..frame,
                headers: frame.headers + [("biz_rt", "0")],
                payload: Some(utf8(stringify(payload))),
              }),
            )
          }
        }),
      )
    },
  }
}

///|
/// One event, kept: a message goes to the hub; a card's answer too, and Feishu is answered with the card as it is now
/// (None: nothing to answer with).
pub async fn FeishuSurface::take(
  self : FeishuSurface,
  envelope : JV,
  handler : async (JV) -> Unit,
) -> JV? {
  let head = jget(Some(envelope), "header")
  let kind = text(jget(head, "event_type"))
  let tenant = text(jget(head, "tenant_key"))
  match self.me {
    Some(me) if tenant != "" && me.team_id == "" =>
      self.me = Some({ ..me, team_id: tenant })
    _ => ()
  }
  if kind == "im.message.receive_v1" {
    match message_of(jget(Some(envelope), "event"), self.bot_user_id()) {
      Some(m) => self.heard(m, handler)
      None => ()
    }
    return None
  }
  if kind == "card.action.trigger" {
    return self.answered(
      jget(Some(envelope), "event"),
      text(jget(head, "event_id")),
      handler,
    )
  }
  None
}

///|
async fn FeishuSurface::chat_info(self : FeishuSurface, chat : String) -> ChatInfo {
  match self.chats.get(chat) {
    Some(known) => return known
    None => ()
  }
  let info = try {
    let d = nullish(
      jget(
        Some(
          self.client.call(
            "GET",
            "/open-apis/im/v1/chats/\{encode_uri_component(chat)}",
          ),
        ),
        "data",
      ),
      Obj([]),
    )
    let mode = text(jget(Some(d), "chat_mode"))
    let p2p = mode == "p2p"
    let name = text(jget(Some(d), "name"))
    {
      name: if p2p || name == "" { None } else { Some(name) },
      topics: text(jget(Some(d), "group_message_type")) == "thread" ||
      mode == "topic",
      p2p,
    }
  } catch {
    e => {
      self.log.warn(
        "feishu",
        "chat not read",
        jobj([("chat", Some(js(chat))), ("error", Some(js(error_words(e))))]),
      )
      return { name: None, topics: false, p2p: false }
    }
  }
  self.chats[chat] = info
  info
}

///|
/// What was said in the chats with a conversation while the station was not connected (Feishu keeps no events for a
/// connection that is not there), heard as if it had come: the store keeps each message once.
pub async fn FeishuSurface::catch_up(
  self : FeishuSurface,
  handler : async (JV) -> Unit,
) -> Unit {
  for c in self.threads.conversations(self.connect) {
    let (chat, since) = c
    if since == Num(0.0) {
      continue
    }
    let since_n = match since {
      Str(s) => js_number(s)
      v => js_to_number(v)
    }
    let mut token = ""
    for page = 0; page < 10; page = page + 1 {
      let query = [
        ("container_id_type", "chat"),
        ("container_id", chat),
        ("start_time", num_text((since_n / 1000.0).floor())),
        ("sort_type", "ByCreateTimeAsc"),
        ("page_size", "50"),
      ]
      if token != "" {
        query.push(("page_token", token))
      }
      let d = nullish(
        jget(Some(self.client.call("GET", "/open-apis/im/v1/messages", query~)), "data"),
        Obj([]),
      )
      for item in jitems(jget(Some(d), "items")) {
        match message_of(Some(listed_as_event(Some(item))), self.bot_user_id()) {
          Some(m) if greater(m.at, since) => self.heard(m, handler)
          _ => ()
        }
      }
      token = text(jget(Some(d), "page_token"))
      if jget(Some(d), "has_more") != Some(Bool(true)) || token == "" {
        break
      }
    }
  }
}

///|
fn FeishuSurface::was_called(self : FeishuSurface, ts : String) -> Unit {
  if !self.called.contains(ts) {
    self.called[ts] = ()
  }
  // The oldest go once there are many: a turn still working for one of those has its card once it does something.
  if self.called.length() > 500 {
    match self.called.keys().next() {
      Some(first) => self.called.remove(first)
      None => ()
    }
  }
}

///|
/// Whether this message called the bot.
pub fn FeishuSurface::was_called_by(self : FeishuSurface, ts : String) -> Bool {
  self.called.contains(ts)
}

///|
/// `map.set(k, v)` as a JavaScript Map does it: a key there keeps its place.
fn[V] map_set(m : Map[String, V], k : String, v : V) -> Unit {
  m[k] = v
}

///|
/// Which thread a message is in (「会话怎么分」): a topic group's topic is its own; in thread mode a group's thread is,
/// by its first message (one that @s the bot outside a thread begins one); anything else said in the chat is the
/// chat's conversation now, begun by the first message that @s the bot (or a new one asked for).
async fn FeishuSurface::heard(
  self : FeishuSurface,
  m : FeishuMessage,
  handler : async (JV) -> Unit,
) -> Unit {
  map_set(self.heard_in, m.user, m.chat)
  if m.addressed {
    self.was_called(m.id)
  }
  if m.at > 0.0 {
    self.threads.heard(self.connect, m.chat, m.at)
  }
  let topics = match m.topic {
    Some(_) if !m.p2p => self.chat_info(m.chat).topics
    _ => false
  }
  let thread_ts = if topics {
    let topic = m.topic.unwrap()
    self.threads.heard_topic(self.connect, topic, m.root.unwrap_or(m.id))
    js(topic)
  } else if (if m.p2p { self.direct_threads } else { self.thread_mode }) {
    let ts = m.root.unwrap_or(m.id)
    if m.topic is Some(_) || m.addressed {
      self.threads.heard_topic(self.connect, ts, ts)
    }
    js(ts)
  } else {
    let current = self.threads.current(self.connect, m.chat)
    if current is None || m.fresh {
      if m.addressed {
        self.threads.begin(self.connect, m.chat, m.id)
      }
      if m.addressed || current is None {
        js(m.id)
      } else {
        current.unwrap()
      }
    } else {
      current.unwrap()
    }
  }
  let message = jobj([
    ("channel", Some(js(m.chat))),
    ("threadTs", Some(thread_ts)),
    ("ts", Some(js(m.id))),
    ("user", Some(js(m.user))),
    ("text", Some(js(m.text))),
    ("addressed", Some(Bool(m.addressed))),
    (
      "files",
      if m.files.length() > 0 {
        Some(Arr(m.files.map(f => f.to_jv())))
      } else {
        None
      },
    ),
    ("quoted", m.parent.map(js)),
  ])
  handler(jobj([("type", Some(js("message"))), ("message", Some(message))]))
}

///|
/// A person's name as this connection knows it: what it was told, else what the book says.
fn FeishuSurface::name_of(self : FeishuSurface, user : String) -> String? {
  match self.names.get(user) {
    Some(p) if p.name != "" => return Some(p.name)
    _ => ()
  }
  match self.known_person(user) {
    Some(p) if p.name != "" => Some(p.name)
    _ => None
  }
}

///|
/// A card's button pressed or its field sent: said in its thread as the person's message, and the card shows the
/// answer.
async fn FeishuSurface::answered(
  self : FeishuSurface,
  event : JV?,
  event_id : String,
  handler : async (JV) -> Unit,
) -> JV? {
  let a = card_answer_of(event, event_id)
  guard a is Some(a) else { return None }
  let value = a.value
  guard jget(Some(value), "sf") == Some(Str("answer")) else { return None }
  let asked = self.asked.get(a.message)
  // (a button pressed before its card was changed to name its thread, a conversation's first message: the thread kept)
  let thread = match (jget(Some(value), "t"), asked) {
    (Some(Str(t)), _) if t != "" => t
    (_, Some(q)) => q.thread
    _ => ""
  }
  if thread == "" {
    return None
  }
  let lang = (self.words.station_lang)()
  let said = match jget(Some(value), "l") {
    Some(Str(l)) => l
    _ => trim_js(text(jget(Some(a.form), "answer")))
  }
  if said == "" {
    return Some(
      jobj([
        (
          "toast",
          Some(
            jobj([
              ("type", Some(js("warning"))),
              ("content", Some(js(tr0(self.words, lang, "station.feishu.answerEmpty")))),
            ]),
          ),
        ),
      ]),
    )
  }
  if asked is Some(q) && q.answered {
    return Some(
      jobj([
        (
          "toast",
          Some(
            jobj([
              ("type", Some(js("info"))),
              (
                "content",
                Some(js(tr0(self.words, lang, "station.feishu.answeredBefore"))),
              ),
            ]),
          ),
        ),
      ]),
    )
  }
  let ts = "card-\{a.event}"
  self.was_called(ts)
  handler(
    jobj([
      ("type", Some(js("message"))),
      (
        "message",
        Some(
          jobj([
            ("channel", Some(js(a.chat))),
            ("threadTs", Some(js(thread))),
            ("ts", Some(js(ts))),
            ("user", Some(js(a.user))),
            ("text", Some(js(said))),
            ("addressed", Some(Bool(true))),
          ]),
        ),
      ),
    ]),
  )
  match asked {
    Some(q) => q.answered = true
    None => ()
  }
  let who = self.name_of(a.user).unwrap_or("")
  let answer = jobj([
    (
      "toast",
      Some(
        jobj([
          ("type", Some(js("success"))),
          ("content", Some(js(tr0(self.words, lang, "station.feishu.sent")))),
        ]),
      ),
    ),
  ])
  match asked {
    Some(q) =>
      jput(
        answer,
        "card",
        jobj([
          ("type", Some(js("raw"))),
          ("data", Some(answered_card(self.words, q.text, who, said, lang))),
        ]),
      )
    None => ()
  }
  Some(answer)
}

///|
/// Posts a message where the thread is: a topic's or a thread's reply in it, else in the chat. Its message id.
pub async fn FeishuSurface::send(
  self : FeishuSurface,
  thread : ThreadRef,
  msg_type : String,
  content : String,
) -> String {
  let answer = match self.threads.topic_root(self.connect, thread.thread_ts) {
    Some(root) =>
      self.client.call(
        "POST",
        "/open-apis/im/v1/messages/\{encode_uri_component(root)}/reply",
        body=Some(
          jobj([
            ("msg_type", Some(js(msg_type))),
            ("content", Some(js(content))),
            ("reply_in_thread", Some(Bool(true))),
          ]),
        ),
      )
    None =>
      self.client.call(
        "POST",
        "/open-apis/im/v1/messages",
        body=Some(
          jobj([
            ("receive_id", Some(js(thread.channel))),
            ("msg_type", Some(js(msg_type))),
            ("content", Some(js(content))),
          ]),
        ),
        query=[("receive_id_type", "chat_id")],
      )
  }
  match jget(jget(Some(answer), "data"), "message_id") {
    Some(Str(id)) if id != "" => id
    _ => raise FeishuError("feishu gave no message_id")
  }
}

///|
fn line_key(thread : ThreadRef) -> String {
  "\{thread.channel}/\{thread.thread_ts}"
}

///|
/// Each file uploaded, as the message that sends it: an image as one (larger ones as files), any other file as the
/// message type its file type takes. All of them before anything is sent (FB-41).
async fn FeishuSurface::upload(
  self : FeishuSurface,
  files : Array[Attachment],
) -> Array[(String, String)] {
  let uploaded : Array[(String, String)] = []
  for file in files {
    let bytes = match (self.options.disk.read)(file.path) {
      Some(b) => b
      None =>
        raise FeishuError(
          "ENOENT: no such file or directory, open '\{file.path}'",
        )
    }
    if is_image_name(file.name) && bytes.length() <= max_image {
      let up = self.client.call(
        "POST",
        "/open-apis/im/v1/images",
        body=Some(jobj([("image_type", Some(js("message")))])),
        files=[
          { field: "image", bytes, name: file.name, mime: "application/octet-stream" },
        ],
      )
      uploaded.push(
        (
          "image",
          stringify(
            jobj([("image_key", jget(jget(Some(up), "data"), "image_key"))]),
          ),
        ),
      )
    } else {
      let kind = file_type(file.name)
      let up = self.client.call(
        "POST",
        "/open-apis/im/v1/files",
        body=Some(
          jobj([
            ("file_type", Some(js(kind))),
            ("file_name", Some(js(file.name))),
          ]),
        ),
        files=[
          { field: "file", bytes, name: file.name, mime: "application/octet-stream" },
        ],
      )
      uploaded.push(
        (
          file_msg_type(kind),
          stringify(
            jobj([("file_key", jget(jget(Some(up), "data"), "file_key"))]),
          ),
        ),
      )
    }
  }
  uploaded
}

///|
/// A question posted as message `id`, kept until it is answered.
fn FeishuSurface::ask(
  self : FeishuSurface,
  id : String,
  message : String,
  card : JV,
  thread_ts : String,
) -> Unit {
  self.asked[id] = { text: message, card, thread: thread_ts, answered: false }
  // The oldest go once there are many: an answer to one of those shows as said, without its card changed.
  if self.asked.length() > 500 {
    match self.asked.keys().next() {
      Some(oldest) => self.asked.remove(oldest)
      None => ()
    }
  }
}

///|
/// The agent's words as rich text (a question's as a card, its buttons or field with them), then each file as a message
/// of its own. Every file is uploaded before anything is sent, so a file that fails leaves no words posted alone. The
/// first message's id stands for the whole.
pub async fn FeishuSurface::post(
  self : FeishuSurface,
  thread : ThreadRef,
  message : String,
  files : Array[Attachment],
  card? : JV? = None,
) -> String {
  let lang = (self.words.station_lang)()
  let question = match card {
    Some(Obj(_) as c) if jget(Some(c), "type") is Some(Str("options" | "text")) =>
      Some(c)
    _ => None
  }
  let sends = match question {
    Some(q) =>
      [
        (
          "interactive",
          inline(question_card(self.words, message, Some(q), thread.thread_ts, lang)),
        ),
      ]
    None => text_posts(message).map(p => ("post", p))
  }
  if sends.length() == 0 && files.length() == 0 {
    raise FeishuError("nothing to post")
  }
  let uploaded = self.upload(files)
  match self.lines.get(line_key(thread)) {
    Some(line) => line.spoke()
    None => ()
  }
  let mut first : String? = None
  for s in sends {
    let id = self.send(thread, s.0, s.1)
    if first is None {
      first = Some(id)
    }
    match question {
      Some(q) => self.ask(id, message, q, thread.thread_ts)
      None => ()
    }
  }
  for u in uploaded {
    let id = self.send(thread, u.0, u.1)
    if first is None {
      first = Some(id)
    }
  }
  match first {
    Some(f) => f
    None => raise FeishuError("nothing to post")
  }
}

///|
/// The groups the bot is in (`GET /im/v1/chats`), each a topic group or not as Feishu says of it.
pub async fn FeishuSurface::places(self : FeishuSurface) -> Array[Place] {
  let found = []
  let mut token = ""
  for page = 0; page < 10; page = page + 1 {
    let query = [("page_size", "100")]
    if token != "" {
      query.push(("page_token", token))
    }
    let d = nullish(
      jget(Some(self.client.call("GET", "/open-apis/im/v1/chats", query~)), "data"),
      Obj([]),
    )
    for c in jitems(jget(Some(d), "items")) {
      let id = text(jget(Some(c), "chat_id"))
      if id != "" {
        let name = text(jget(Some(c), "name"))
        found.push((id, if name != "" { name } else { id }))
      }
    }
    token = text(jget(Some(d), "page_token"))
    if jget(Some(d), "has_more") != Some(Bool(true)) || token == "" {
      break
    }
  }
  let out = []
  for c in found {
    let info = self.chat_info(c.0)
    if !info.p2p {
      out.push({
        id: c.0,
        name: info.name.unwrap_or(c.1),
        kind: if info.topics { "topics" } else { "group" },
      })
    }
  }
  out
}

///|
/// What `read` answers for `key`, kept for `ms` on the surface's clock: asked again only after, or once it failed;
/// those asking while it is asked wait for that answer (connects/surface.ts `kept`).
async fn FeishuSurface::kept(
  self : FeishuSurface,
  key : String,
  ms : Int64,
  read : async () -> Array[Member],
) -> Array[Member] {
  let now = self.rt.now()
  match self.answers.get(key) {
    Some((at, d)) if now - at < ms => return d.wait()
    _ => ()
  }
  let d : @effect.Deferred[Array[Member]] = @effect.Deferred::new()
  self.answers[key] = (now, d)
  let got = try {
    Ok(read())
  } catch {
    e => Err(e)
  }
  match got {
    Ok(v) => {
      ignore(d.succeed(v))
      v
    }
    Err(e) => {
      match self.answers.get(key) {
        Some((_, mine)) if physical_equal(mine, d) => self.answers.remove(key)
        _ => ()
      }
      ignore(d.fail(e))
      raise e
    }
  }
}

///|
/// The people in a group (`GET /im/v1/chats/:id/members`; bots are not among them), by their name in it, kept for
/// MEMBERS_MS.
pub async fn FeishuSurface::people_in(
  self : FeishuSurface,
  chat : String,
) -> Array[Member] {
  self.kept("members:\{chat}", members_ms, async fn() { self.members_of(chat) })
}

///|
async fn FeishuSurface::members_of(
  self : FeishuSurface,
  chat : String,
) -> Array[Member] {
  let out = []
  let mut token = ""
  for page = 0; page < 20; page = page + 1 {
    let query = [("member_id_type", "open_id"), ("page_size", "100")]
    if token != "" {
      query.push(("page_token", token))
    }
    let d = nullish(
      jget(
        Some(
          self.client.call(
            "GET",
            "/open-apis/im/v1/chats/\{encode_uri_component(chat)}/members",
            query~,
          ),
        ),
        "data",
      ),
      Obj([]),
    )
    for item in jitems(jget(Some(d), "items")) {
      let id = text(jget(Some(item), "member_id"))
      let name = text(jget(Some(item), "name"))
      if id != "" && name != "" {
        out.push({ id, name })
      }
    }
    token = text(jget(Some(d), "page_token"))
    if jget(Some(d), "has_more") != Some(Bool(true)) || token == "" {
      break
    }
  }
  out
}

///|
/// The chat in Feishu's (or Lark's) app; a topic opens with its chat.
pub fn FeishuSurface::permalink(
  self : FeishuSurface,
  thread : ThreadRef,
) -> String raise FeishuError {
  let app = if self.domain == "lark" {
    "https://applink.larksuite.com"
  } else {
    "https://applink.feishu.cn"
  }
  "\{app}/client/chat/open?openChatId=\{encode_uri_component(thread.channel)}"
}

///|
/// A new message in the chat, as the agent's words are (rich text, or a question's card), its files after it: in a topic
/// group a topic of its own; elsewhere the chat's conversation from now on, as a new one asked for in it begins
/// (「会话怎么分」), or in thread mode a thread of its own. Every file is uploaded before anything is sent, as `post`'s.
pub async fn FeishuSurface::begin(
  self : FeishuSurface,
  chat : String,
  message : String,
  files? : Array[Attachment] = [],
  card? : JV? = None,
) -> (ThreadRef, String) {
  let lang = (self.words.station_lang)()
  let question = match card {
    Some(Obj(_) as c) if jget(Some(c), "type") is Some(Str("options" | "text")) =>
      Some(c)
    _ => None
  }
  // (a question's buttons name the thread they answer in, known once its message is: changed to it then)
  let sends = match question {
    Some(q) =>
      [("interactive", inline(question_card(self.words, message, Some(q), "", lang)))]
    None => text_posts(message).map(p => ("post", p))
  }
  if sends.length() == 0 && files.length() == 0 {
    raise FeishuError("nothing to post")
  }
  let uploaded = self.upload(files)
  let info = self.chat_info(chat)
  let topics = info.topics
  let all = [..sends, ..uploaded]
  let first = nullish(
    jget(
      Some(
        self.client.call(
          "POST",
          "/open-apis/im/v1/messages",
          body=Some(
            jobj([
              ("receive_id", Some(js(chat))),
              ("msg_type", Some(js(all[0].0))),
              ("content", Some(js(all[0].1))),
            ]),
          ),
          query=[("receive_id_type", "chat_id")],
        ),
      ),
      "data",
    ),
    Obj([]),
  )
  let id = text(jget(Some(first), "message_id"))
  if id == "" {
    raise FeishuError("feishu gave no message_id")
  }
  let mut topic = if topics { text(jget(Some(first), "thread_id")) } else { "" }
  // A topic group's message is a topic, whose id Feishu may leave out of the answer: read the message back.
  if topics && topic == "" {
    topic = text(
      jget(
        jat(
          jget(
            jget(
              Some(
                self.client.call(
                  "GET",
                  "/open-apis/im/v1/messages/\{encode_uri_component(id)}",
                ),
              ),
              "data",
            ),
            "items",
          ),
          0,
        ),
        "thread_id",
      ),
    )
  }
  let thread : ThreadRef = if topic != "" {
    self.threads.heard_topic(self.connect, topic, id)
    ThreadRef::{ channel: chat, thread_ts: topic }
  } else {
    if (if info.p2p { self.direct_threads } else { self.thread_mode }) {
      self.threads.heard_topic(self.connect, id, id)
    } else {
      self.threads.begin(self.connect, chat, id)
    }
    ThreadRef::{ channel: chat, thread_ts: id }
  }
  match question {
    Some(q) => {
      self.ask(id, message, q, thread.thread_ts)
      // (only an options card's buttons name the thread: a text card's field does not)
      if jget(Some(q), "type") is Some(Str("options")) {
        ignore(
          self.client.call(
            "PATCH",
            "/open-apis/im/v1/messages/\{encode_uri_component(id)}",
            body=Some(
              jobj([
                (
                  "content",
                  Some(
                    js(
                      inline(
                        question_card(self.words, message, Some(q), thread.thread_ts, lang),
                      ),
                    ),
                  ),
                ),
              ]),
            ),
          ),
        )
      }
    }
    None => ()
  }
  for u in all[1:] {
    ignore(self.send(thread, u.0, u.1))
  }
  (thread, id)
}

///|
/// A question that stopped waiting other than by its buttons (connects/card-ends.ts): its card changed to say why,
/// nothing left to press. One answered by a press (its answer, a message `card-…`) shows that answer already.
pub async fn FeishuSurface::card_ended(
  self : FeishuSurface,
  _thread : ThreadRef,
  ts : String,
  said : String,
  card : JV?,
  end : CardEnd,
) -> Unit {
  if !(jget(card, "type") is Some(Str("options" | "text"))) {
    return
  }
  match end {
    ByMessage(_, by_ts) if starts(by_ts, "card-") => return
    _ => ()
  }
  let asked = self.asked.get(ts)
  if asked is Some(q) && q.answered {
    return
  }
  match asked {
    Some(q) => q.answered = true
    None => ()
  }
  let lang = (self.words.station_lang)()
  let who = match end {
    ByMessage(by, _) => self.name_of(by)
    _ => None
  }
  let t = match asked {
    Some(q) => q.text
    None => said
  }
  ignore(
    self.client.call(
      "PATCH",
      "/open-apis/im/v1/messages/\{encode_uri_component(ts)}",
      body=Some(
        jobj([
          (
            "content",
            Some(
              js(
                inline(
                  ended_card(t, ended_words(self.words, card, end, who, lang)),
                ),
              ),
            ),
          ),
        ]),
      ),
    ),
  )
}

///|
/// A message changed in place (`PUT /im/v1/messages/:id`, which edits rich text), as `post` writes one.
pub async fn FeishuSurface::edit(
  self : FeishuSurface,
  _thread : ThreadRef,
  ts : String,
  message : String,
) -> Bool {
  let posts = text_posts(message)
  if posts.length() != 1 {
    return false
  }
  ignore(
    self.client.call(
      "PUT",
      "/open-apis/im/v1/messages/\{encode_uri_component(ts)}",
      body=Some(
        jobj([("msg_type", Some(js("post"))), ("content", Some(js(posts[0])))]),
      ),
    ),
  )
  true
}

///|
pub async fn FeishuSurface::download(
  self : FeishuSurface,
  file : InboundFile,
) -> Bytes {
  let at = match file.url {
    Some(u) => resource_of(u)
    None => None
  }
  guard at is Some((kind, message, key)) else {
    raise FeishuError("Feishu does not give its contents")
  }
  self.client.resource(message, key, kind)
}

///|
/// A person's name and email: from the contacts (as far as the app may read them), else their name in the chat they
/// were heard in.
pub async fn FeishuSurface::look_up(
  self : FeishuSurface,
  user : String,
) -> Person? {
  try {
    let u = nullish(
      jget(
        jget(
          Some(
            self.client.call(
              "GET",
              "/open-apis/contact/v3/users/\{encode_uri_component(user)}",
              query=[("user_id_type", "open_id")],
            ),
          ),
          "data",
        ),
        "user",
      ),
      Obj([]),
    )
    let name = text(jget(Some(u), "name"))
    let name = if name != "" { name } else { text(jget(Some(u), "en_name")) }
    if name != "" {
      let enterprise = text(jget(Some(u), "enterprise_email"))
      let email = if enterprise != "" {
        enterprise
      } else {
        text(jget(Some(u), "email"))
      }
      return Some({ name, email: @jscase.lower(email) })
    }
  } catch {
    _ => ()
  }
  guard self.heard_in.get(user) is Some(chat) else { return None }
  let names = match self.members.get(chat) {
    Some(n) => n
    None => {
      let n : Map[String, String] = Map([])
      let people = self.people_in(chat) catch { _ => return None }
      for m in people {
        n[m.id] = m.name
      }
      self.members[chat] = n
      n
    }
  }
  let name = names.get(user).unwrap_or("")
  if name == "" {
    None
  } else {
    Some({ name, email: "" })
  }
}

///|
/// contact/v3/users/batch_get_id (contact:user.id:readonly; an app given only the scopes before it cannot ask, and has
/// none): their open_id, as `mention` takes it.
pub async fn FeishuSurface::look_up_email(
  self : FeishuSurface,
  email : String,
) -> String? {
  try {
    let d = nullish(
      jget(
        Some(
          self.client.call(
            "POST",
            "/open-apis/contact/v3/users/batch_get_id",
            body=Some(jobj([("emails", Some(Arr([js(email)])))])),
            query=[("user_id_type", "open_id")],
          ),
        ),
        "data",
      ),
      Obj([]),
    )
    let mut found : JV? = None
    for u in jitems(jget(Some(d), "user_list")) {
      if @jscase.lower(text(jget(Some(u), "email"))) == email {
        found = Some(u)
        break
      }
    }
    let id = text(jget(found, "user_id"))
    if id == "" {
      None
    } else {
      Some(id)
    }
  } catch {
    _ => None
  }
}

///|
/// A person for the book: what this connection knows when that has an email, else what the platform says now.
async fn FeishuSurface::relearned(
  self : FeishuSurface,
  user : String,
) -> Person? {
  let known = self.names.get(user)
  match known {
    Some(k) if k.email != "" => return Some(k)
    _ => ()
  }
  let person = self.look_up(user)
  match person {
    Some(p) => {
      self.names[user] = p
      Some(p)
    }
    None => known
  }
}

///|
pub fn FeishuSurface::known_person(
  self : FeishuSurface,
  user : String,
) -> Person? {
  match self.book {
    None => self.names.get(user)
    Some(book) =>
      // One without an email may get one: a person the app may read later on, or who fills it in.
      (book.person)(
        "u:\{self.connect}:\{user}",
        async fn() { self.relearned(user) },
        (known, age_ms) => known.email == "" && age_ms >= email_again_ms,
      )
  }
}

///|
pub fn FeishuSurface::known_channel(
  self : FeishuSurface,
  channel : String,
) -> String? {
  match self.book {
    None =>
      match self.chats.get(channel) {
        Some(c) => c.name
        None => None
      }
    Some(book) =>
      (book.channel)("c:\{self.connect}:\{channel}", async fn() {
        self.chat_info(channel).name
      })
  }
}

///|
pub async fn FeishuSurface::channel_name(
  self : FeishuSurface,
  channel : String,
) -> String? {
  self.chat_info(channel).name
}

///|
/// A person as the platform says, kept for the connection's lifetime (connects/surface.ts `profile`).
async fn FeishuSurface::profile(self : FeishuSurface, user : String) -> Person? {
  match self.names.get(user) {
    Some(k) => return Some(k)
    None => ()
  }
  let person = self.look_up(user)
  match person {
    Some(p) => self.names[user] = p
    None => ()
  }
  person
}

///|
/// Their display name, kept for the connection's lifetime.
pub async fn FeishuSurface::user_name(
  self : FeishuSurface,
  user : String,
) -> String? {
  match self.profile(user) {
    Some(p) if p.name != "" => Some(p.name)
    _ => None
  }
}

///|
/// Their email, where the platform shares it: what ties them to a still.fail account.
pub async fn FeishuSurface::user_email(
  self : FeishuSurface,
  user : String,
) -> String? {
  match self.profile(user) {
    Some(p) if p.email != "" => Some(p.email)
    _ => None
  }
}

///|
/// The person there with this email, kept for the connection's lifetime once found (one not found is asked again:
/// they may join later).
pub async fn FeishuSurface::user_of(
  self : FeishuSurface,
  email : String,
) -> String? {
  let key = @jscase.lower(trim_js(email))
  if key == "" {
    return None
  }
  match self.by_email.get(key) {
    Some(u) => return Some(u)
    None => ()
  }
  let user = self.look_up_email(key)
  match user {
    Some(u) => self.by_email[key] = u
    None => ()
  }
  user
}

///|
/// What a topic or a thread said before `before` (a chat's conversation begins with the message the station first
/// heard: there is nothing before it of its own).
pub async fn FeishuSurface::history(
  self : FeishuSurface,
  thread : ThreadRef,
  before : String,
  limit : Int,
) -> Array[ChatMessage] {
  let mut container = thread.thread_ts
  if !starts(container, "omt_") {
    if self.threads.topic_root(self.connect, container) is None {
      return []
    }
    // A thread goes by its first message here, by its own id there; none yet: that message is all it is.
    container = text(
      jget(
        jat(
          jget(
            jget(
              Some(
                self.client.call(
                  "GET",
                  "/open-apis/im/v1/messages/\{encode_uri_component(container)}",
                ),
              ),
              "data",
            ),
            "items",
          ),
          0,
        ),
        "thread_id",
      ),
    )
    if container == "" {
      return []
    }
  }
  let all : Array[ChatMessage] = []
  let last = (all : Array[ChatMessage]) => {
    let from = @cmp.maximum(0, all.length() - limit)
    if from >= all.length() {
      []
    } else {
      all[from:].to_array()
    }
  }
  let mut token = ""
  for page = 0; page < 20; page = page + 1 {
    let query = [
      ("container_id_type", "thread"),
      ("container_id", container),
      ("sort_type", "ByCreateTimeAsc"),
      ("page_size", "50"),
    ]
    if token != "" {
      query.push(("page_token", token))
    }
    let d = nullish(
      jget(Some(self.client.call("GET", "/open-apis/im/v1/messages", query~)), "data"),
      Obj([]),
    )
    for item in jitems(jget(Some(d), "items")) {
      let id = text(jget(Some(item), "message_id"))
      if id == before {
        return last(all)
      }
      let from_bot = text(jget(jget(Some(item), "sender"), "sender_type")) == "app"
      let event = listed_as_event(Some(item))
      match event.get("sender") {
        Some(s) => jput(s, "sender_type", js("user"))
        None => ()
      }
      match message_of(Some(event), self.bot_user_id()) {
        Some(m) =>
          all.push({ ts: id, user: m.user, text: m.text, from_bot, files: m.files })
        None => ()
      }
    }
    token = text(jget(Some(d), "page_token"))
    if jget(Some(d), "has_more") != Some(Bool(true)) || token == "" {
      break
    }
  }
  last(all)
}

///|
/// The message a reply quotes (`GET /im/v1/messages/:id`), read as `history` reads one; None for an app's (the agent's
/// own answers it has already) and where it cannot be read (deleted, the app not in its chat).
pub async fn FeishuSurface::quoted(
  self : FeishuSurface,
  _thread : ThreadRef,
  ts : String,
) -> ChatMessage? {
  try {
    let item = jat(
      jget(
        jget(
          Some(
            self.client.call(
              "GET",
              "/open-apis/im/v1/messages/\{encode_uri_component(ts)}",
            ),
          ),
          "data",
        ),
        "items",
      ),
      0,
    )
    if item is None || text(jget(jget(item, "sender"), "sender_type")) == "app" {
      return None
    }
    match message_of(Some(listed_as_event(item)), self.bot_user_id()) {
      None => None
      Some(m) =>
        Some({
          ts: m.id,
          user: m.user,
          text: m.text,
          from_bot: false,
          files: m.files,
        })
    }
  } catch {
    e => {
      self.log.warn(
        "feishu",
        "quoted message not read",
        jobj([
          ("connect", Some(js(self.connect))),
          ("message", Some(js(ts))),
          ("error", Some(js(error_words(e)))),
        ]),
      )
      None
    }
  }
}

///|
/// `/^(GET|POST|PUT|PATCH|DELETE)\s+(\/open-apis\/\S+)$/i` on a method: its verb (upper case) and its path.
pub fn api_method(meth : String) -> (String, String)? {
  let n = meth.length()
  let mut i = 0
  while i < n && is_ascii_letter(meth.unsafe_charcode_at(i)) {
    i += 1
  }
  let verb = ascii_upper(meth.unsafe_substring(start=0, end=i))
  if !(verb is ("GET" | "POST" | "PUT" | "PATCH" | "DELETE")) {
    return None
  }
  let spaces = i
  while i < n && is_js_space(meth.unsafe_charcode_at(i)) {
    i += 1
  }
  if i == spaces {
    return None
  }
  let path = meth.unsafe_substring(start=i, end=n)
  if path.length() <= 11 || ascii_lower(path.unsafe_substring(start=0, end=11)) != "/open-apis/" {
    return None
  }
  for k in 0..<path.length() {
    if is_js_space(path.unsafe_charcode_at(k)) {
      return None
    }
  }
  Some((verb, path))
}

///|
fn is_ascii_letter(c : Int) -> Bool {
  (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
}

///|
fn ascii_upper(s : String) -> String {
  let out = StringBuilder::new()
  for i in 0..<s.length() {
    let c = s.unsafe_charcode_at(i)
    out.write_char((if c >= 'a' && c <= 'z' { c - 32 } else { c }).unsafe_to_char())
  }
  out.to_string()
}

///|
/// `Object.entries(v)` as `[k, String(v)]` (a query's: an object's fields, an array's or a string's by index).
fn entries_text(v : JV?) -> Array[(String, String)] {
  match v {
    Some(Obj(_) as o) => jkeys(o).map(k => (k, js_string(o.get(k))))
    Some(Arr(a)) => a.mapi((i, x) => (i.to_string(), js_string(Some(x))))
    Some(Str(s)) =>
      Array::makei(s.length(), i => (i.to_string(), s.unsafe_substring(start=i, end=i + 1)))
    _ => []
  }
}

///|
/// An OpenAPI call as the bot, for feishu_api: `method` is "GET /open-apis/…"; a GET's params go in the address,
/// anything else's as its JSON body.
pub async fn FeishuSurface::api(
  self : FeishuSurface,
  meth : String,
  params : JV,
) -> Answered {
  guard api_method(trim_js(meth)) is Some((verb, path)) else {
    raise FeishuError(
      "feishu_api: method is \"GET /open-apis/…\" (an HTTP method and a path), got \{stringify(js(meth))}",
    )
  }
  if verb == "GET" {
    let query = []
    for k in jkeys(params) {
      match params.get(k) {
        None | Some(Null) => ()
        Some(Str(s)) => query.push((k, s))
        Some(v) => query.push((k, stringify(v)))
      }
    }
    return self.client.api(verb, path, body=None, query~, take_file=true)
  }
  let body = JV::Obj([])
  let mut query : JV? = None
  for k in jkeys(params) {
    if k == "query" {
      query = params.get(k)
    } else {
      jput(body, k, params.get(k).unwrap())
    }
  }
  self.client.api(
    verb,
    path,
    body=Some(body),
    query=entries_text(match query {
      Some(Null) => None
      q => q
    }),
    take_file=true,
  )
}

///|
/// A thread's status line, made as the agent first works for it.
fn FeishuSurface::status_line(
  self : FeishuSurface,
  thread : ThreadRef,
) -> FeishuStatus {
  FeishuStatus::new(
    self.rt,
    {
      api: async fn(verb, path, body) { self.client.call(verb, path, body~) },
      send: async fn(kind, content) { self.send(thread, kind, content) },
      called: ts => self.called.contains(ts),
    },
    self.words,
    self.log,
  )
}

///|
/// What the agent is doing in a thread ("": its turn ended), said there (connects/surface.ts `working`).
pub fn FeishuSurface::working(
  self : FeishuSurface,
  thread : ThreadRef,
  message_ts : String?,
  status : String,
  page? : String? = None,
) -> Unit {
  if self.stopped {
    return
  }
  let key = line_key(thread)
  let line = match self.lines.get(key) {
    Some(l) => l
    None => {
      let l = self.status_line(thread)
      self.lines[key] = l
      l
    }
  }
  if status == "" && self.lines.length() > 200 {
    self.lines.remove(key)
  }
  line.say(status, message_ts~, page~)
}
