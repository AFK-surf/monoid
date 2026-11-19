// Slack as a chat surface (station/src/slack/surface.ts, on a socket kept up as connects/surface.ts keeps every
// connect's): Socket Mode for what Slack tells the station (a card's buttons too), the Web API for what the station and
// its agents say and ask. One SlackSurface per connected connect.
//
// The socket kept up: connected again whenever it closes (Slack rotates them) or fails (after a wait that doubles up to
// a minute), pinged, and taken for dead once it said nothing for a while, where its socket can be pinged (`WsConn`'s
// `ping`: the shell's `ws.*` answers Slack's pings itself and says nothing of pongs, so a socket of the shell is held
// only to opening in time).

///|
/// How long who is in a channel is kept for (`people_in`).
pub let members_ms : Double = 60000.0

///|
/// How long the workspace's people are kept for (`people_in`).
pub let people_ms : Double = 600000.0

///|
let max_backoff_ms : Int = 60000

///|
/// The most of a question's words its card carries.
let question_chars : Int = 8000

///|
/// The most bytes a chat.update's `text` is cut to, though chat.postMessage takes 40,000 and the message's Markdown block
/// 12,000 characters: a message posted whole is changed with its blocks whole and its `text`, only the notification's
/// fallback, cut to fit. Slack refuses a `text` over 4,000 UTF-8 bytes (msg_too_long) as it stands after Slack's own
/// changes to it: `&`, `<` and `>` escaped (`&amp;`, `&lt;`, `&gt;`) and bare links and emails made `<url>` /
/// `<mailto:…|…>`. Each character is counted as escaped (`slack_text_bytes`); the 500 bytes left are for the links.
let update_text_bytes : Int = 3500

///|
/// What `text` is cut to on a second try where Slack still found it too long (a message of nothing but links).
let update_text_fallback_bytes : Int = 200

///|
/// A code point's bytes in a `text` as Slack measures it: `&`, `<` and `>` as their escapes, the rest as UTF-8.
fn slack_text_bytes(cp : Int) -> Int {
  if cp == 0x26 {
    5
  } else if cp == 0x3c || cp == 0x3e {
    4
  } else if cp <= 0x7f {
    1
  } else if cp <= 0x7ff {
    2
  } else if cp <= 0xffff {
    3
  } else {
    4
  }
}

///|
/// `said` cut to `max_bytes` as Slack counts them (`slack_text_bytes`) at a whole code point, "…" after it where cut
/// (slack/surface.ts `updateText`).
fn update_text(said : String, max_bytes? : Int = update_text_bytes) -> String {
  let mut total = 0
  for c in said {
    total += slack_text_bytes(c.to_int())
  }
  if total <= max_bytes {
    return said
  }
  let out = StringBuilder::new()
  let mut used = 0
  for c in said {
    let bytes = slack_text_bytes(c.to_int())
    if used + bytes > max_bytes - 3 {
      break
    }
    used += bytes
    out.write_char(c)
  }
  out.write_string("…")
  out.to_string()
}

///|
/// What a chat's events are given to (sessions/chat.ts `Handler`): a message, an edit, a stop or a login's code, as
/// `{type, …}`; what it raises is said as the event not taken.
pub type Handler = async (J) -> Unit

///|
/// A socket the surface reads: its next text (None once it closed), what it sends, its close, and its ping where it has
/// one (a pong or any frame counts as heard: `heard`).
pub struct WsConn {
  next : async () -> String?
  send : (String) -> Unit
  close : () -> Unit
  ping : (() -> Unit)?
}

///|
/// Slack said no in a socket's handshake: its status and its `handshake-msg`.
pub(all) suberror WsRefused {
  WsRefused(Int, String)
}

///|
/// Its words where it is said (`to_string`, a notice, a log): not its type's name (`station/<package>.<Type>`).
pub impl Show for WsRefused with output(self, logger) {
  match self {
    WsRefused(status, m) => logger.write_string(trim("slack refused the connection: HTTP \{status} \{m}"))
  }
}

///|
/// No answer at all (no way there, or none in time): what is asked again (ops/unanswered.ts).
pub(all) suberror Unanswered {
  Unanswered(String)
}

///|
/// Its words where it is said (`to_string`, a notice, a log): not its type's name (`station/<package>.<Type>`).
pub impl Show for Unanswered with output(self, logger) {
  match self {
    Unanswered(m) => logger.write_string(m)
  }
}

///|
pub struct WsIO {
  open : async (String) -> WsConn
}

///|
/// A message the bot posted, as it posted it.
priv struct Said {
  text : String
  blocks : Array[J]
  question : Bool
}

///|
/// What `kept` holds: each answer as it was asked for (one asking at a time) and when.
priv struct KeptAnswer {
  at : Double
  answer : @effect.Deferred[J]
}

///|
pub struct SurfaceOptions {
  app_token : String
  bot_token : String
  client : SlackClient
  /// The connect it is (for the log).
  connect : String?
  /// Keeps names and lets the pages ask without waiting (`known_person`, `known_channel`).
  book : NameBook?
  /// The connects' names book where the station keeps one for every platform (connects/names.ts `NameBook`, the one
  /// its connects open: connects_hub's): taken before `book`, so a connect's names are kept once.
  names : Names?
  ping_ms : Int
  stale_ms : Int
  backoff_ms : Int
  clock : Clock
  ws : WsIO
  words : Words
  lang : Ref[String]
  log : Log
  /// An attachment's bytes, by its path.
  read_file : async (String) -> Bytes
  /// Told each time a socket said something.
  on_heard : () -> Unit
  /// A new turn began showing its status, an opportunity to retry an app setup that previously failed.
  on_working : async () -> Bool
  /// The models `/sf` offers, the connect's own first.
  models : () -> Array[ModelChoice]
  /// Of those, the few its form lists for a person before they type anything.
  models_first : ((String) -> Array[ModelChoice])?
}

///|
pub fn SurfaceOptions::new(
  app_token : String,
  bot_token : String,
  client : SlackClient,
  clock : Clock,
  ws : WsIO,
  words : Words,
  lang : Ref[String],
  log : Log,
  read_file : async (String) -> Bytes,
  connect? : String? = None,
  book? : NameBook? = None,
  names? : Names? = None,
  ping_ms? : Int = 5000,
  stale_ms? : Int = 20000,
  backoff_ms? : Int = 1000,
  on_heard? : () -> Unit = () => (),
  on_working? : async () -> Bool = async fn() { false },
  models? : () -> Array[ModelChoice] = () => [],
  models_first? : ((String) -> Array[ModelChoice])? = None,
) -> SurfaceOptions {
  {
    app_token,
    bot_token,
    client,
    connect,
    book,
    names,
    ping_ms,
    stale_ms,
    backoff_ms,
    clock,
    ws,
    words,
    lang,
    log,
    read_file,
    on_heard,
    on_working,
    models,
    models_first,
  }
}

///|
pub struct SlackSurface {
  o : SurfaceOptions
  app_token : String
  bot_token : String
  client : SlackClient
  mut me : BotIdentity?
  mut connected : Bool
  mut last_error : String?
  listeners : Array[() -> Unit]
  /// People as Slack says, by their id there.
  names : Map[String, J]
  /// People found by their email (`user_of`), by it.
  by_email : Map[String, String]
  /// Each thread an agent works for: its status line.
  lines : Map[String, ThreadStatus]
  mut stopped : Bool
  priv answers : Map[String, KeptAnswer]
  fibers : Array[@effect.Fiber[Unit]]
  channels : Map[String, String?]
  /// The questions answered or closed (their messages' ts): a second press before the card changed is not said again.
  answered : Map[String, Unit]
  /// The questions posted (by the ts `post` gave): their own message's ts and the Markdown they show.
  questions : Map[String, (String, String)]
  /// Each thread's newest message as the station saw it, the bot's with what it posted; and where the thread stands said
  /// at its end.
  priv ends : Map[String, (String, Said?)]
  priv stands : Map[String, (String, Said?, J)]
  /// One change at a time in each thread, in order.
  priv standing : Chains
  standing_count : Map[String, Int]
}

///|
pub fn SlackSurface::new(o : SurfaceOptions) -> SlackSurface raise {
  if !o.app_token.has_prefix("xapp-") {
    raise fail_("slack.appToken must be an app-level token (xapp-…)")
  }
  if !o.bot_token.has_prefix("xoxb-") {
    raise fail_("slack.botToken must be a bot token (xoxb-…)")
  }
  {
    o,
    app_token: o.app_token,
    bot_token: o.bot_token,
    client: o.client,
    me: None,
    connected: false,
    last_error: None,
    listeners: [],
    names: {},
    by_email: {},
    lines: {},
    stopped: false,
    answers: {},
    fibers: [],
    channels: {},
    answered: {},
    questions: {},
    ends: {},
    stands: {},
    standing: { tails: {} },
    standing_count: {},
  }
}

///|
fn SlackSurface::lang(self : SlackSurface) -> String {
  self.o.lang.val
}

///|
fn SlackSurface::tr(self : SlackSurface, key : String, args? : Array[(String, String)] = []) -> String {
  self.o.words.tr(self.lang(), key, args~)
}

///|
fn SlackSurface::log(self : SlackSurface, level : String, words : String, fields? : Array[(String, J)] = []) -> Unit {
  (self.o.log)(level, "slack", words, jo(fields))
}

///|
/// Runs `f` as a fiber of the surface's: it ends when the surface stops.
fn SlackSurface::run(self : SlackSurface, f : async () -> Unit) -> Unit {
  ignore(self.spawn(f))
}

///|
fn SlackSurface::spawn(self : SlackSurface, f : async () -> Unit) -> @effect.Fiber[Unit] {
  let fiber = (self.o.clock.fork)(async fn() {
    if !self.stopped {
      f() catch {
        _ => ()
      }
    }
  })
  // (those ended go as the next starts)
  let live = self.fibers.filter(x => !x.is_done())
  self.fibers.clear()
  self.fibers.append(live)
  self.fibers.push(fiber)
  fiber
}

///|
fn SlackSurface::now(self : SlackSurface) -> Double {
  (self.o.clock.now)()
}

///|
/// What `read` answers for `key`, kept for `ms`: asked again only after, or once it failed; those asking while it is
/// asked wait for that answer.
async fn SlackSurface::kept(self : SlackSurface, key : String, ms : Double, read : async () -> J) -> J {
  let now = self.now()
  match self.answers.get(key) {
    Some(had) if now - had.at < ms => return had.answer.wait()
    _ => ()
  }
  let answer : @effect.Deferred[J] = @effect.Deferred::new()
  self.answers[key] = { at: now, answer }
  let got = read() catch {
    e => {
      ignore(answer.fail(e))
      match self.answers.get(key) {
        Some(a) if physical_equal(a.answer, answer) => self.answers.remove(key)
        _ => ()
      }
      raise e
    }
  }
  ignore(answer.succeed(got))
  got
}

///|
/// `kept`'s answer for `key` let go of when it was asked at least `ms` ago: whether it was.
fn SlackSurface::forget(self : SlackSurface, key : String, ms : Double) -> Bool {
  match self.answers.get(key) {
    None => false
    Some(had) if self.now() - had.at < ms => false
    Some(_) => {
      self.answers.remove(key)
      true
    }
  }
}

///|
pub fn SlackSurface::identity(self : SlackSurface) -> BotIdentity? {
  self.me
}

///|
/// The socket's status: whether it is connected, and its last error.
pub fn SlackSurface::socket(self : SlackSurface) -> (Bool, String?) {
  (self.connected, self.last_error)
}

///|
/// Hears each change of the socket's status, and of the identity.
pub fn SlackSurface::on_change(self : SlackSurface, f : () -> Unit) -> Unit {
  self.listeners.push(f)
}

///|
fn SlackSurface::changed(self : SlackSurface) -> Unit {
  for f in self.listeners {
    f()
  }
}

///|
fn SlackSurface::set_status(self : SlackSurface, connected : Bool, last_error : String?) -> Unit {
  if self.connected == connected && self.last_error == last_error {
    return
  }
  self.connected = connected
  self.last_error = last_error
  self.changed()
}

///|
/// Reads again who the bot is and where; listeners hear of it.
pub async fn SlackSurface::refresh_identity(self : SlackSurface) -> Unit {
  self.me = Some(identity_of(self.client, self.bot_token))
  self.changed()
}

///|
pub fn SlackSurface::platform(_self : SlackSurface) -> String {
  "slack"
}

///|
pub fn SlackSurface::bot_user_id(self : SlackSurface) -> String {
  match self.me {
    Some(m) => m.bot_user_id
    None => ""
  }
}

///|
pub fn SlackSurface::bot_name(self : SlackSurface) -> String {
  match self.me {
    Some(m) => m.bot_name
    None => ""
  }
}

///|
pub fn SlackSurface::workspace(self : SlackSurface) -> String? {
  match self.me {
    Some(m) if m.team_id != "" => Some(m.team_id)
    _ => None
  }
}

///|
fn unanswered(e : Error) -> Bool {
  e is Unanswered(_)
}

///|
/// Who its bot is, then its socket kept up. Slack's refusal fails it; no answer at all does not: it is asked again on
/// the socket's backoff, the socket opened once it answers.
pub async fn SlackSurface::start(self : SlackSurface, handler : Handler) -> Unit {
  let identity = identity_of(self.client, self.bot_token) catch {
    e => {
      if !unanswered(e) {
        raise e
      }
      self.not_reached(e, self.o.backoff_ms)
      self.run(async fn() { self.identify_loop(handler) })
      return
    }
  }
  self.began(identity, handler)
}

///|
fn SlackSurface::began(self : SlackSurface, identity : BotIdentity, handler : Handler) -> Unit {
  self.log("info", "slack authenticated", fields=[
    ("connect", jopt(self.o.connect)),
    ("bot", js(identity.bot_name)),
    ("botUserId", js(identity.bot_user_id)),
    ("team", js(identity.team)),
  ])
  self.me = Some(identity)
  self.run(async fn() { self.connect_loop(handler) })
}

///|
fn SlackSurface::not_reached(self : SlackSurface, e : Error, retry_in_ms : Int) -> Unit {
  self.set_status(false, Some(message_of(e)))
  self.log("warn", "slack not reached", fields=[
    ("connect", jopt(self.o.connect)),
    ("error", js(message_of(e))),
    ("retryInMs", ji(retry_in_ms)),
  ])
}

///|
async fn SlackSurface::identify_loop(self : SlackSurface, handler : Handler) -> Unit {
  let mut backoff = self.o.backoff_ms
  while !self.stopped {
    (self.o.clock.sleep)(backoff)
    backoff = @cmp.minimum(backoff * 2, max_backoff_ms)
    match (try Ok(identity_of(self.client, self.bot_token)) catch { e => Err(e) }) {
      Err(e) if unanswered(e) => {
        self.not_reached(e, backoff)
        continue
      }
      Err(e) => {
        let said = message_of(e)
        self.set_status(false, Some(said))
        self.log("error", "failed to connect", fields=[("connect", jopt(self.o.connect)), ("error", js(said))])
      }
      Ok(i) => self.began(i, handler)
    }
    return
  }
}

///|
/// Ends its timers and its socket.
pub fn SlackSurface::stop(self : SlackSurface) -> Unit {
  if self.stopped {
    return
  }
  self.stopped = true
  for f in self.fibers {
    f.interrupt()
  }
}

///|
/// Connects again whenever the socket closes or fails (after a wait that doubles up to a minute), until it stops.
async fn SlackSurface::connect_loop(self : SlackSurface, handler : Handler) -> Unit {
  let mut backoff = self.o.backoff_ms
  while !self.stopped {
    let ran = try Ok({
      let url = self.address()
      self.run_socket(url, handler)
    }) catch { e => Err(e) }
    match ran {
      Ok(_) => backoff = self.o.backoff_ms
      Err(e) => {
        let said = message_of(e)
        self.set_status(false, Some(said))
        self.log("warn", "slack socket failed", fields=[
          ("connect", jopt(self.o.connect)),
          ("error", js(said)),
          ("retryInMs", ji(backoff)),
        ])
        (self.o.clock.sleep)(backoff)
        backoff = @cmp.minimum(backoff * 2, max_backoff_ms)
      }
    }
  }
}

///|
/// Where its socket connects to now (asked again for each).
async fn SlackSurface::address(self : SlackSurface) -> String {
  let open = self.client.api("apps.connections.open", [], self.app_token)
  match str_of(at(Some(open), "url")) {
    Some(u) => u
    None => raise fail_("slack gave no socket url")
  }
}

///|
fn seconds(ms : Double) -> String {
  num_text(Num(ms / 1000.0))
}

///|
/// One socket: ends when it closes (or Slack asks for another), and fails on its error, when it did not open within
/// `stale_ms`, or when it then said nothing (not even a pong) for `stale_ms` where it is pinged every `ping_ms`.
async fn SlackSurface::run_socket(self : SlackSurface, url : String, handler : Handler) -> Unit {
  let stale = self.o.stale_ms
  let opened = try {
    @effect.timeout(stale, async fn() { (self.o.ws.open)(url) })
  } catch {
    WsRefused(status, msg) => raise fail_(trim("slack refused the connection: HTTP \{status} \{msg}"))
    e => raise e
  }
  let conn = match opened {
    Some(c) => c
    None => raise fail_("slack socket did not open within \{seconds(stale.to_double())}s")
  }
  let heard = Ref(self.now())
  self.set_status(true, None)
  let ended = Ref(false)
  let finish = () => if !ended.val {
    ended.val = true
    (conn.close)()
  }
  let reading = async fn() -> Unit {
    while true {
      match (conn.next)() {
        None => {
          // (closed: as `end(null)`)
          finish()
          self.set_status(false, self.last_error)
          return
        }
        Some(data) => {
          heard.val = self.now()
          (self.o.on_heard)()
          if self.message(conn, data, handler) {
            finish()
            self.set_status(false, self.last_error)
            return
          }
        }
      }
    }
  }
  let watch = async fn() -> Unit {
    match conn.ping {
      None => @effect.never()
      Some(ping) =>
        while true {
          (self.o.clock.sleep)(self.o.ping_ms)
          let quiet = self.now() - heard.val
          if quiet >= stale.to_double() {
            raise fail_("slack socket said nothing for \{seconds(quiet)}s")
          }
          ping()
        }
    }
  }
  @effect.race_first(reading, watch) catch {
    e => {
      finish()
      raise e
    }
  }
}

///|
/// One envelope of Socket Mode, taken: whether Slack asked for another socket (`disconnect`). Each event is
/// acknowledged once its handler kept it; one that failed is not, and Slack sends it again.
fn SlackSurface::message(self : SlackSurface, conn : WsConn, data : String, handler : Handler) -> Bool {
  let envelope = match (try Ok(parse(data)) catch { e => Err(e) }) {
    Ok(v) => Some(v)
    Err(_) => return false
  }
  let kind = str_of(at(envelope, "type"))
  if kind == Some("disconnect") {
    self.log("info", "slack asked to reconnect", fields=[
      ("reason", js(stringify(at(envelope, "reason").unwrap_or(Null)))),
    ])
    return true
  }
  let bot = self.bot_user_id()
  let bot_id = match self.me {
    Some(m) => m.bot_id
    None => ""
  }
  let envelope_id = match at(envelope, "envelope_id") {
    None => J::Null
    Some(v) => v
  }
  // Acknowledged (Slack waits 3 s), with what it asked for when it asks (`payload`).
  let ack = (payload : J?) => {
    let fs = [("envelope_id", envelope_id)]
    match payload {
      Some(p) => fs.push(("payload", p))
      None => ()
    }
    (conn.send)(stringify(jo(fs)))
  }
  let payload = at(envelope, "payload")
  let ptype = str_of(at(payload, "type"))
  // `/sf`: its form opened (its trigger lasts 3 s).
  if kind == Some("slash_commands") {
    ack(None)
    if str_of(at(payload, "command")) == Some(new_chat_command) {
      self.run(async fn() {
        self.new_chat(payload) catch {
          e => self.log("error", "failed to open the new chat form", fields=[("error", js(message_of(e)))])
        }
      })
    }
    return false
  }
  // The form's model field: the models matching what is typed; nothing typed, the few the person is offered first.
  if kind == Some("interactive") && ptype == Some("block_suggestion") {
    let typed = text(at(payload, "value"))
    let offered = if trim(typed) == "" {
      match self.o.models_first {
        Some(f) => f(text(at_path(payload, ["user", "id"])))
        None => (self.o.models)()
      }
    } else {
      (self.o.models)()
    }
    let options = model_options(self.o.words, offered, typed, self.lang())
    ack(Some(jo([("options", ja(options))])))
    return false
  }
  // The form sent: acknowledged once its thread is posted (or with what is wrong, shown in the form), then taken.
  if kind == Some("interactive") && ptype == Some("view_submission") {
    let acked = Ref(false)
    let once = (p : J?) => {
      if !acked.val {
        ack(p)
      }
      acked.val = true
    }
    self.run(async fn() {
      self.start_chat(payload, handler, once) catch {
        e => {
          self.log("error", "failed to start a chat from the form", fields=[("error", js(message_of(e)))])
          once(
            Some(
              jo([
                ("response_action", js("errors")),
                ("errors", jo([("words", js(self.tr("station.slack.newChatFailed", args=[("error", message_of(e))])))])),
              ]),
            ),
          )
        }
      }
    })
    return false
  }
  // A card's button pressed: acknowledged at once, then said as the person's answer.
  if kind == Some("interactive") {
    ack(None)
    if ptype == Some("block_actions") {
      self.run(async fn() {
        try {
          if login_code_of(payload) is Some(_) {
            self.enter_code(payload, handler)
          } else {
            self.answer(payload, handler)
          }
        } catch {
          e => self.log("error", "failed to take a card's answer", fields=[("error", js(message_of(e)))])
        }
      })
    }
    return false
  }
  if kind != Some("events_api") {
    return false
  }
  let event = match to_event(at(payload, "event"), bot, bot_id) {
    Some(e) if str_of(at(Some(e), "type")) == Some("stop") =>
      Some(
        put(e, "localAt", match self.client.local_time_upper(text(at(Some(e), "ts"))) {
          Some(t) => jn(t)
          None => Null
        }),
      )
    e => e
  }
  let look_up = files_to_look_up(at(payload, "event"))
  self.run(async fn() {
    let taken = try Ok({
      match event {
        Some(e) => {
          let e = if str_of(at(Some(e), "type")) == Some("message") && look_up.length() > 0 {
            match at(at(Some(e), "message"), "files") {
              Some(Arr(files)) => {
                let looked = []
                for f in files {
                  looked.push(if look_up.contains(text(at(Some(f), "id"))) { self.file_info(f) } else { f })
                }
                put(e, "message", put(at(Some(e), "message").unwrap(), "files", ja(looked)))
              }
              _ => e
            }
          } else {
            e
          }
          if str_of(at(Some(e), "type")) == Some("message") {
            let m = at(Some(e), "message")
            self.heard(text(at(m, "channel")), text(at(m, "threadTs")), text(at(m, "ts")))
          }
          handler(e)
        }
        None => ()
      }
    }) catch { e => Err(e) }
    match taken {
      Ok(_) => (conn.send)(stringify(jo([("envelope_id", envelope_id)])))
      // Not acknowledged: Slack redelivers, and the store dedupes.
      Err(e) => self.log("error", "failed to accept slack event", fields=[("error", js(message_of(e)))])
    }
  })
  false
}

///|
/// A file Slack's event gave by its id alone, as files.info gives it; as it was where that fails (named as missing).
async fn SlackSurface::file_info(self : SlackSurface, file : J) -> J {
  let id = text(at(Some(file), "id"))
  let info = self.client.api("files.info", [("file", id)], self.bot_token) catch {
    e => {
      self.log("warn", "files.info failed", fields=[("file", js(id)), ("error", js(message_of(e)))])
      return file
    }
  }
  match at(Some(info), "file") {
    Some(Null) | None => file
    Some(f) => file_of(f)
  }
}

///|
fn thread_key(channel : String, thread_ts : String) -> String {
  "\{channel}/\{thread_ts}"
}

///|
async fn SlackSurface::post_message(self : SlackSurface, params : Params) -> J {
  self.client.api("chat.postMessage", params, self.bot_token)
}

///|
/// Posted as written, in a markdown block; a long message goes out in parts, the first part's ts standing for the
/// whole. A question (`card`: options or a field), or a login's field for its page's code, is one message with its
/// buttons. Files (`{path, name}`) are uploaded before anything is posted, then shared into the thread below the text.
/// In a channel shared with another organization, an installer or executable Slack Connect refuses goes as
/// `<name>.zip` (zip.mbt).
pub async fn SlackSurface::post(
  self : SlackSurface,
  channel : String,
  thread_ts : String,
  message : String,
  files : Array[J],
  card? : J? = None,
) -> String {
  let uploaded = []
  let blocked = (f : J) => connect_blocked(text(at(Some(f), "name")))
  let zipped = files.iter().any(blocked) && self.shared_out(channel)
  for f in files {
    let name = text(at(Some(f), "name"))
    let bytes = (self.o.read_file)(text(at(Some(f), "path")))
    uploaded.push(
      if zipped && blocked(f) {
        self.upload("\{name}.zip", zip_one(name, bytes))
      } else {
        self.upload(name, bytes)
      },
    )
  }
  let first : Ref[String?] = Ref(None)
  let send = async fn(said : String, blocks : Array[J], question : Bool) -> Unit {
    let posted = self.post_message([
      ("channel", channel),
      ("thread_ts", thread_ts),
      ("text", said),
      ("blocks", stringify(ja(blocks))),
      ("unfurl_links", "false"),
    ])
    match str_of(at(Some(posted), "ts")) {
      Some(ts) => {
        if first.val is None {
          first.val = Some(ts)
        }
        self.heard(channel, thread_ts, ts, mine=Some({ text: said, blocks, question }))
      }
      None => ()
    }
  }
  let question = match str_of(at(card, "type")) {
    Some("options" | "text" | "login") => card
    _ => None
  }
  let mut parts = @session_chats.split_for_slack(message, 3500).filter(t => t != "")
  // A question is one message with its buttons; what is too long for it goes before it, in parts.
  let mut asking = ""
  if question is Some(_) {
    if point_count(message) <= question_chars {
      asking = message
      parts = []
    } else {
      asking = parts.pop().unwrap_or("")
    }
  }
  for part in parts {
    send(part, [markdown(part)], false)
  }
  if question is Some(_) {
    let before = first.val
    let blocks = if str_of(at(question, "type")) == Some("login") {
      let page = match at(question, "page") {
        None => None
        p => p
      }
      let shown = if truthy(page) { !self.shared_out(channel) } else { true }
      login_blocks(self.o.words, asking, self.lang(), page~, shown~)
    } else {
      question_blocks(self.o.words, asking, question, self.lang())
    }
    send(asking, blocks, true)
    match self.ends.get(thread_key(channel, thread_ts)) {
      Some((ts, _)) => {
        self.questions[before.unwrap_or(ts)] = (ts, asking)
        // (the oldest go once there are many: long answered or closed)
        if self.questions.length() > 500 {
          drop_first(self.questions)
        }
      }
      None => ()
    }
  }
  if uploaded.length() > 0 {
    let list = stringify(ja(uploaded.map(u => jo([("id", js(u.0)), ("title", js(u.1))]))))
    let shared = self.client.api(
      "files.completeUploadExternal",
      [("files", list), ("channel_id", channel), ("thread_ts", thread_ts)],
      self.bot_token,
    )
    // (the files are its newest message, nothing the bot can add words to)
    self.heard(channel, thread_ts, "")
    if first.val is None {
      first.val = self.shared_ts(shared, uploaded[0].0, channel)
      if first.val is None {
        self.log("warn", "slack: shared files without text, their message's ts did not show up")
        first.val = Some(to_fixed((self.client.net.now)() / 1000.0, 6))
      }
    }
  }
  match first.val {
    Some(f) => f
    None => raise fail_("nothing to post")
  }
}

///|
fn[V] drop_first(m : Map[String, V]) -> Unit {
  match m.iter().head() {
    Some((k, _)) => m.remove(k)
    None => ()
  }
}

///|
/// `/sf`: its form, the model field on the connect's own model and the words what followed the command.
async fn SlackSurface::new_chat(self : SlackSurface, payload : J?) -> Unit {
  let trigger = text(at(payload, "trigger_id"))
  let channel = text(at(payload, "channel_id"))
  if trigger == "" || channel == "" {
    return
  }
  let view = new_chat_view(self.o.words, (self.o.models)(), channel, text(at(payload, "text")), self.lang())
  ignore(self.client.api("views.open", [("trigger_id", trigger), ("view", stringify(view))], self.bot_token))
}

///|
fn form_errors(field : String, words : String) -> J {
  jo([("response_action", js("errors")), ("errors", jo([(field, js(words))]))])
}

///|
/// The `/sf` form sent: its words posted in its channel as the person's, a new thread, which a session on the model
/// picked takes. What cannot be done is said in the form, which stays open; nothing is posted then.
async fn SlackSurface::start_chat(self : SlackSurface, payload : J?, handler : Handler, ack : (J?) -> Unit) -> Unit {
  let asked = match submitted_chat(payload) {
    Some(a) => a
    None => return ack(None)
  }
  let offered = (self.o.models)()
  let model = match asked.model {
    None => None
    Some(m) =>
      match offered.search_by(o => model_value(o) == model_value(m)) {
        Some(i) => Some(offered[i])
        None => None
      }
  }
  let model = match model {
    Some(m) => m
    None => return ack(Some(form_errors("model", self.tr("station.slack.newChatNoModel"))))
  }
  if asked.words == "" {
    return ack(Some(form_errors("words", self.tr("station.slack.newChatEmpty"))))
  }
  let (said_text, said_blocks) = new_chat_blocks(self.o.words, asked.user, model, asked.words, self.lang())
  let posted = try Ok(self.post_message([
    ("channel", asked.channel),
    ("text", said_text),
    ("blocks", stringify(ja(said_blocks))),
    ("unfurl_links", "false"),
  ])) catch { e => Err(e) }
  let ts = match posted {
    Ok(p) => text(at(Some(p), "ts"))
    Err(e) => {
      let why = message_of(e)
      let key = if why.contains("not_in_channel") || why.contains("channel_not_found") || why.contains("is_archived") {
        "station.slack.newChatNotHere"
      } else {
        "station.slack.newChatFailed"
      }
      return ack(Some(form_errors("words", self.tr(key, args=[("error", why)]))))
    }
  }
  ack(None)
  if ts == "" {
    return
  }
  // (the bot's message, but the person's words: nothing of the bot's to change)
  self.heard(asked.channel, ts, ts)
  handler(
    jo([
      ("type", js("message")),
      (
        "message",
        jo([
          ("channel", js(asked.channel)),
          ("threadTs", js(ts)),
          ("ts", js(ts)),
          ("user", js(asked.user)),
          ("text", js(asked.words)),
          ("addressed", jb(true)),
          ("model", model.to_j()),
        ]),
      ),
    ]),
  )
}

///|
/// Where a press was made: its channel, its message, its thread and who pressed it.
fn pressed_at(payload : J?) -> (String, String, String, String) {
  let or = (a : String, b : String) => if a != "" { a } else { b }
  let channel = or(text(at_path(payload, ["channel", "id"])), text(at_path(payload, ["container", "channel_id"])))
  let asked = or(text(at_path(payload, ["message", "ts"])), text(at_path(payload, ["container", "message_ts"])))
  let thread_ts = or(
    or(text(at_path(payload, ["message", "thread_ts"])), text(at_path(payload, ["container", "thread_ts"]))),
    asked,
  )
  (channel, asked, thread_ts, text(at_path(payload, ["user", "id"])))
}

///|
async fn SlackSurface::ephemeral(self : SlackSurface, channel : String, user : String, thread_ts : String, said : String) -> Unit {
  ignore(
    self.client.api(
      "chat.postEphemeral",
      [("channel", channel), ("user", user), ("thread_ts", thread_ts), ("text", said)],
      self.bot_token,
    ),
  )
}

///|
fn SlackSurface::mark_answered(self : SlackSurface, ts : String) -> Unit {
  self.answered[ts] = ()
  if self.answered.length() > 500 {
    drop_first(self.answered)
  }
}

///|
/// A login card's button pressed: the field's code handed to the station (never said in the thread), and the card
/// changed to say who entered it. Nothing written, or refused: only they are told.
async fn SlackSurface::enter_code(self : SlackSurface, payload : J?, handler : Handler) -> Unit {
  let code = login_code_of(payload).unwrap_or("")
  let (channel, asked, thread_ts, user) = pressed_at(payload)
  if channel == "" || asked == "" || user == "" {
    return
  }
  if code == "" {
    return self.ephemeral(channel, user, thread_ts, self.tr("station.feishu.answerEmpty"))
  }
  let refused = try {
    handler(
      jo([
        ("type", js("loginCode")),
        ("channel", js(channel)),
        ("threadTs", js(thread_ts)),
        ("ts", js(asked)),
        ("user", js(user)),
        ("code", js(code)),
      ]),
    )
    None
  } catch {
    e => Some(message_of(e))
  }
  match refused {
    Some(why) => return self.ephemeral(channel, user, thread_ts, self.tr("station.slack.loginRefused", args=[("error", why)]))
    None => ()
  }
  // (entered: the login's end leaves it saying so)
  self.mark_answered(asked)
  let (asking, w) = self.words_of(asked, payload)
  let entered = login_entered_blocks(self.o.words, w, self.user_name(user).unwrap_or(""), self.lang())
  self.settle_card(channel, thread_ts, asked, asking, entered)
  self.update(channel, asked, asking, entered)
}

///|
/// A card's buttons gone for good: never put back with where the thread stands; its thread's end said as it is now.
fn SlackSurface::settle_card(
  self : SlackSurface,
  channel : String,
  thread_ts : String,
  asked : String,
  asking : String,
  blocks : Array[J],
) -> Unit {
  let key = thread_key(channel, thread_ts)
  match self.stands.get(key) {
    Some((ts, _, _)) if ts == asked => self.stands.remove(key)
    _ => ()
  }
  match self.ends.get(key) {
    Some((ts, Some(_))) if ts == asked => self.ends[key] = (ts, Some({ text: asking, blocks, question: false }))
    _ => ()
  }
}

///|
/// What a pressed card says, to be shown again under its answer: its message's text, and its words.
fn SlackSurface::words_of(self : SlackSurface, asked : String, payload : J?) -> (String, CardWords) {
  for q in self.questions.values() {
    if q.0 == asked {
      return (q.1, Markdown(q.1))
    }
  }
  let blocks = arr(at_path(payload, ["message", "blocks"]))
  let said = text(at_path(payload, ["message", "text"]))
  (said, if blocks.length() > 0 { Blocks(blocks) } else { Markdown(said) })
}

///|
/// A card's send button pressed: said in its thread as the person's message, and the card changed to say who
/// answered what. Nothing chosen or written, or answered before: only they are told, and nothing is said.
async fn SlackSurface::answer(self : SlackSurface, payload : J?, handler : Handler) -> Unit {
  let (said, field) = match answer_of(payload) {
    Some(a) => a
    None => return
  }
  let (channel, asked, thread_ts, user) = pressed_at(payload)
  if channel == "" || asked == "" || user == "" {
    return
  }
  let tell = async fn(key : String) { self.ephemeral(channel, user, thread_ts, self.tr(key)) }
  if said == "" {
    return tell(if field { "station.feishu.answerEmpty" } else { "station.slack.chooseFirst" })
  }
  if self.answered.contains(asked) {
    return tell("station.feishu.answeredBefore")
  }
  self.mark_answered(asked)
  let actions = arr(at(payload, "actions"))
  let action_ts = match actions.search_by(a => text(at(Some(a), "action_ts")) != "") {
    Some(i) => text(at(Some(actions[i]), "action_ts"))
    None => ""
  }
  let ts = if action_ts != "" { action_ts } else { to_fixed((self.client.net.now)() / 1000.0, 6) }
  self.heard(channel, thread_ts, ts)
  handler(
    jo([
      ("type", js("message")),
      (
        "message",
        jo([
          ("channel", js(channel)),
          ("threadTs", js(thread_ts)),
          ("ts", js(ts)),
          ("user", js(user)),
          ("text", js(said)),
          ("addressed", jb(true)),
        ]),
      ),
    ]),
  ) catch {
    e => {
      self.answered.remove(asked)
      // Slack has already acknowledged the button press, so it will not redeliver a rejected answer.
      tell("station.slack.answerUnconfirmed") catch {
        n => self.log("warn", "could not tell the person their answer was unconfirmed", fields=[("error", js(message_of(n)))])
      }
      raise e
    }
  }
  let (asking, w) = self.words_of(asked, payload)
  let who = self.user_name(user).unwrap_or("")
  let answered = answered_blocks(self.o.words, w, who, said, self.lang())
  self.settle_card(channel, thread_ts, asked, asking, answered)
  self.update(channel, asked, asking, answered)
}

///|
/// A question that stopped waiting other than by its button (connects/card-ends.ts), a login's field among them:
/// changed to say why, its buttons gone (`end`: `{why, by?, byTs?}`).
pub async fn SlackSurface::card_ended(
  self : SlackSurface,
  channel : String,
  thread_ts : String,
  ts : String,
  said : String,
  card : J?,
  end : J?,
) -> Unit {
  match str_of(at(card, "type")) {
    Some("options" | "text" | "login") => ()
    _ => return
  }
  let asked = match self.questions.get(ts) {
    Some(q) => Some(q)
    None => if point_count(said) <= question_chars { Some((ts, said)) } else { None }
  }
  let (asked_ts, asked_text) = match asked {
    Some(a) => a
    None => return
  }
  if self.answered.contains(asked_ts) {
    return
  }
  self.mark_answered(asked_ts)
  let who = if text(at(end, "why")) == "message" {
    self.user_name(text(at(end, "by"))) catch {
      _ => None
    }
  } else {
    None
  }
  let blocks = ended_blocks(asked_text, ended_words(self.o.words, card, end, who, self.lang()))
  self.settle_card(channel, thread_ts, asked_ts, asked_text, blocks)
  self.update(channel, asked_ts, asked_text, blocks)
}

///|
/// The channels the bot is in, public and private (users.conversations), at most a couple of thousand
/// (`{id, name, kind, private?}`).
pub async fn SlackSurface::places(self : SlackSurface) -> Array[J] {
  let out = []
  let mut cursor = ""
  for _ in 0..<10 {
    let params = [("types", "public_channel,private_channel"), ("exclude_archived", "true"), ("limit", "200")]
    if cursor != "" {
      params.push(("cursor", cursor))
    }
    let d = self.client.api("users.conversations", params, self.bot_token)
    for c in arr(at(Some(d), "channels")) {
      let id = text(at(Some(c), "id"))
      if id == "" {
        continue
      }
      let name = text(at(Some(c), "name"))
      let fs = [("id", js(id)), ("name", js(if name != "" { name } else { id })), ("kind", js("channel"))]
      if is_true(at(Some(c), "is_private")) {
        fs.push(("private", jb(true)))
      }
      out.push(jo(fs))
    }
    cursor = text(at_path(Some(d), ["response_metadata", "next_cursor"]))
    if cursor == "" {
      break
    }
  }
  out
}

///|
/// Whether the bot may join a public channel itself: its token granted channels:join, as Slack last said.
pub fn SlackSurface::joins(self : SlackSurface) -> Bool {
  self.client.has_scope(self.bot_token, "channels:join")
}

///|
/// The public channels the bot is not in (conversations.list, is_member false), at most a couple of thousand.
pub async fn SlackSurface::open_places(self : SlackSurface) -> Array[J] {
  let out = []
  let mut cursor = ""
  for _ in 0..<10 {
    let params = [("types", "public_channel"), ("exclude_archived", "true"), ("limit", "200")]
    if cursor != "" {
      params.push(("cursor", cursor))
    }
    let d = self.client.api("conversations.list", params, self.bot_token)
    for c in arr(at(Some(d), "channels")) {
      let id = text(at(Some(c), "id"))
      if id == "" || is_true(at(Some(c), "is_member")) {
        continue
      }
      let name = text(at(Some(c), "name"))
      out.push(jo([("id", js(id)), ("name", js(if name != "" { name } else { id })), ("kind", js("channel"))]))
    }
    cursor = text(at_path(Some(d), ["response_metadata", "next_cursor"]))
    if cursor == "" {
      break
    }
  }
  out
}

///|
/// The bot joins a public channel (conversations.join).
pub async fn SlackSurface::join(self : SlackSurface, channel : String) -> Unit {
  ignore(self.client.api("conversations.join", [("channel", channel)], self.bot_token))
}

///|
/// The people in a channel (conversations.members), named as users.list says (`{id, name, aka?, picture?}`). Who is
/// in a channel is kept for `members_ms`, the workspace's people for `people_ms`; someone in the channel the
/// workspace's people did not have reads those again, once in `members_ms` at most.
pub async fn SlackSurface::people_in(self : SlackSurface, channel : String) -> Array[J] {
  let ids = strings(Some(self.kept("members:\{channel}", members_ms, async fn() { jsa(self.members_of(channel)) })))
  let mut all = self.kept("people", people_ms, async fn() { self.everyone() })
  let seen = (all : J) => strings(at(Some(all), "seen"))
  if ids.iter().any(id => !seen(all).contains(id)) && self.forget("people", members_ms) {
    all = self.kept("people", people_ms, async fn() { self.everyone() })
  }
  let people = at(Some(all), "people")
  ids.filter_map(id => at(people, id))
}

///|
/// Who is in a channel (conversations.members), at most a couple of thousand.
async fn SlackSurface::members_of(self : SlackSurface, channel : String) -> Array[String] {
  let ids = []
  let mut cursor = ""
  for _ in 0..<10 {
    let params = [("channel", channel), ("limit", "200")]
    if cursor != "" {
      params.push(("cursor", cursor))
    }
    let d = self.client.api("conversations.members", params, self.bot_token)
    for id in strings(at(Some(d), "members")) {
      if !ids.contains(id) {
        ids.push(id)
      }
    }
    cursor = text(at_path(Some(d), ["response_metadata", "next_cursor"]))
    if cursor == "" {
      break
    }
  }
  ids
}

///|
fn squeezed(s : String) -> String {
  lower(s.iter().filter(c => !@jscase.is_space(c.to_int())).collect() |> String::from_array)
}

///|
/// The workspace's people (users.list), at most ten thousand: every account it listed (`seen`), and those of them a
/// note can mention by id (`people`, by id).
async fn SlackSurface::everyone(self : SlackSurface) -> J {
  let seen = []
  let people : Array[(String, J)] = []
  let mut cursor = ""
  for _ in 0..<50 {
    let params = [("limit", "200")]
    if cursor != "" {
      params.push(("cursor", cursor))
    }
    let d = self.client.api("users.list", params, self.bot_token)
    for u in arr(at(Some(d), "members")) {
      let uu = Some(u)
      let id = text(at(uu, "id"))
      if id == "" {
        continue
      }
      if !seen.contains(id) {
        seen.push(id)
      }
      if is_true(at(uu, "is_bot")) || is_true(at(uu, "deleted")) || id == "USLACKBOT" {
        continue
      }
      let full = match text(at_path(uu, ["profile", "real_name"])) {
        "" => text(at(uu, "real_name"))
        f => f
      }
      let person = person_of(Some(jo([("user", u)])))
      let shown = text(at(Some(person), "name"))
      let picture = text(at(Some(person), "picture"))
      let name = if shown != "" { shown } else { full }
      if name == "" {
        continue
      }
      // (their full name beside it only where it says more than the name: not the same but for case or spaces)
      let fs = [("id", js(id)), ("name", js(name))]
      if full != "" && squeezed(full) != squeezed(name) {
        fs.push(("aka", js(full)))
      }
      if picture != "" {
        fs.push(("picture", js(picture)))
      }
      match people.search_by(p => p.0 == id) {
        Some(i) => people[i] = (id, jo(fs))
        None => people.push((id, jo(fs)))
      }
    }
    cursor = text(at_path(Some(d), ["response_metadata", "next_cursor"]))
    if cursor == "" {
      break
    }
  }
  jo([("seen", jsa(seen)), ("people", jo(people))])
}

///|
/// The thread in Slack: its workspace's address, the channel, its root's ts without the dot.
pub fn SlackSurface::permalink(self : SlackSurface, channel : String, thread_ts : String) -> String? {
  let url = match self.me {
    Some(m) => m.url
    None => ""
  }
  if url == "" {
    return None
  }
  let mut end = url.length()
  while end > 0 && url.unsafe_charcode_at(end - 1) == '/'.to_int() {
    end -= 1
  }
  let dotless = match thread_ts.find(".") {
    Some(i) => thread_ts.unsafe_substring(start=0, end=i) + thread_ts.unsafe_substring(start=i + 1, end=thread_ts.length())
    None => thread_ts
  }
  Some("\{url.unsafe_substring(start=0, end~)}/archives/\{channel}/p\{dotless}")
}

///|
/// `url.host`: its hostname, and its port where it is not its scheme's.
fn url_host(u : @cloud_net.Url) -> String {
  match u.port {
    Some(p) => "\{u.hostname()}:\{p}"
    None => u.hostname()
  }
}

///|
/// `url.searchParams.get(name)`.
fn search_param(u : @cloud_net.Url, name : String) -> String? {
  let q = match u.query {
    Some(q) => q
    None => return None
  }
  for pair in q.split("&") {
    let p = pair.to_string()
    let (k, v) = match p.find("=") {
      Some(i) => (p.unsafe_substring(start=0, end=i), p.unsafe_substring(start=i + 1, end=p.length()))
      None => (p, "")
    }
    if form_decode(k) == name {
      return Some(form_decode(v))
    }
  }
  None
}

///|
/// What application/x-www-form-urlencoded says: + a space, %XX its byte, the bytes UTF-8.
fn form_decode(s : String) -> String {
  let bytes = @buffer.new()
  let n = s.length()
  let hexv = (c : Int) => if c >= '0'.to_int() && c <= '9'.to_int() {
    Some(c - '0'.to_int())
  } else if c >= 'a'.to_int() && c <= 'f'.to_int() {
    Some(c - 'a'.to_int() + 10)
  } else if c >= 'A'.to_int() && c <= 'F'.to_int() {
    Some(c - 'A'.to_int() + 10)
  } else {
    None
  }
  let mut i = 0
  while i < n {
    let c = s.unsafe_charcode_at(i)
    if c == '+'.to_int() {
      bytes.write_byte(b' ')
      i += 1
      continue
    }
    if c == '%'.to_int() && i + 2 < n + 0 && i + 2 <= n - 1 {
      match (hexv(s.unsafe_charcode_at(i + 1)), hexv(s.unsafe_charcode_at(i + 2))) {
        (Some(a), Some(b)) => {
          bytes.write_byte((a * 16 + b).to_byte())
          i += 3
          continue
        }
        _ => ()
      }
    }
    // (one code point as UTF-8)
    if c >= 0xd800 && c <= 0xdbff && i + 1 < n {
      bytes.write_bytes(@utf8.encode(s.unsafe_substring(start=i, end=i + 2)))
      i += 2
    } else {
      bytes.write_bytes(@utf8.encode(s.unsafe_substring(start=i, end=i + 1)))
      i += 1
    }
  }
  @utf8.decode_lossy(bytes.to_bytes())
}

///|
/// A message's link in this workspace (https://acme.slack.com/archives/C1/p1700000000000100, a reply's with
/// ?thread_ts=): the thread it is in (channel, thread's ts).
pub fn SlackSurface::thread_of(self : SlackSurface, link : String) -> (String, String)? {
  let url = match @cloud_net.parse_url(trim(link)) {
    Some(u) => u
    None => return None
  }
  let home = match @cloud_net.parse_url(match self.me { Some(m) => m.url; None => "" }) {
    Some(u) => u
    None => return None
  }
  if url_host(url) != url_host(home) {
    return None
  }
  // /^\/archives\/([A-Z0-9]+)\/p(\d{10})(\d{6})\/?$/
  let path = url.path
  if !path.has_prefix("/archives/") {
    return None
  }
  let rest = path.unsafe_substring(start=10, end=path.length())
  let slash = match rest.find("/") {
    Some(i) => i
    None => return None
  }
  let channel = rest.unsafe_substring(start=0, end=slash)
  if channel == "" || !channel.iter().all(c => (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')) {
    return None
  }
  let mut tail = rest.unsafe_substring(start=slash + 1, end=rest.length())
  if tail.has_suffix("/") {
    tail = tail.unsafe_substring(start=0, end=tail.length() - 1)
  }
  if tail.length() != 17 || !tail.has_prefix("p") {
    return None
  }
  let digits = tail.unsafe_substring(start=1, end=17)
  if !digits.iter().all(c => c >= '0' && c <= '9') {
    return None
  }
  let ts_ok = (t : String) => t.length() == 17 &&
    t.unsafe_charcode_at(10) == '.'.to_int() &&
    (0).until(17).all(k => k == 10 || (t.unsafe_charcode_at(k) >= '0'.to_int() && t.unsafe_charcode_at(k) <= '9'.to_int()))
  let thread_ts = match search_param(url, "thread_ts") {
    Some(r) if ts_ok(r) => r
    _ => "\{digits.unsafe_substring(start=0, end=10)}.\{digits.unsafe_substring(start=10, end=16)}"
  }
  Some((channel, thread_ts))
}

///|
/// A new message in the channel, its thread's root: what is too long for one message goes on in the thread. The
/// thread's root ts, which is the message's too.
pub async fn SlackSurface::begin(self : SlackSurface, channel : String, message : String) -> String {
  let parts = @session_chats.split_for_slack(message, 3500).filter(t => t != "")
  let mut root = ""
  for part in parts {
    let params = [
      ("channel", channel),
      ("text", part),
      ("blocks", stringify(ja([markdown(part)]))),
      ("unfurl_links", "false"),
    ]
    if root != "" {
      params.push(("thread_ts", root))
    }
    let posted = self.post_message(params)
    if root == "" {
      root = text(at(Some(posted), "ts"))
    }
    if root == "" {
      raise fail_("slack chat.postMessage gave no ts")
    }
    let ts = match text(at(Some(posted), "ts")) {
      "" => root
      t => t
    }
    self.heard(channel, root, ts, mine=Some({ text: part, blocks: [markdown(part)], question: false }))
  }
  if root == "" {
    raise fail_("nothing to post")
  }
  root
}

///|
/// A message changed in place (chat.update), as `post` writes one; where the thread stands, said under it, stays.
pub async fn SlackSurface::edit(self : SlackSurface, channel : String, thread_ts : String, ts : String, message : String) -> Bool {
  if @session_chats.split_for_slack(message, 3500).length() > 1 {
    return false
  }
  let key = thread_key(channel, thread_ts)
  let said : Said = { text: message, blocks: [markdown(message)], question: false }
  let under = match self.stands.get(key) {
    Some((t, Some(_), block)) if t == ts => Some(block)
    _ => None
  }
  let blocks = match under {
    Some(b) => said.blocks + [b]
    None => said.blocks
  }
  self.update(channel, ts, message, blocks)
  match self.stands.get(key) {
    Some((t, Some(_), block)) if t == ts => self.stands[key] = (t, Some(said), block)
    _ => ()
  }
  match self.ends.get(key) {
    Some((t, Some(_))) if t == ts => self.ends[key] = (t, Some(said))
    _ => ()
  }
  true
}

///|
/// A thread's newest message, as they came (`mine`: one the bot posted, as it posted it).
fn SlackSurface::heard(self : SlackSurface, channel : String, thread_ts : String, ts : String, mine? : Said? = None) -> Unit {
  let key = thread_key(channel, thread_ts)
  // (the oldest go once there are many: threads long quiet)
  if !self.ends.contains(key) && self.ends.length() > 2000 {
    drop_first(self.ends)
  }
  self.ends[key] = (ts, mine)
}

///|
/// Where the thread stands as its agent's turn ended, said under its newest message: added to the bot's own message
/// when that is the newest, else in a small message of its own. None: nothing to say. Whatever was said before goes
/// first. Best effort, never waited on.
pub fn SlackSurface::stands_at(self : SlackSurface, channel : String, thread_ts : String, stands : Stands?) -> Unit {
  if self.stopped {
    return
  }
  let key = thread_key(channel, thread_ts)
  // (nothing said, nor on its way)
  if stands is None && !self.stands.contains(key) && self.standing_count.get(key).unwrap_or(0) == 0 {
    return
  }
  self.standing_count[key] = self.standing_count.get(key).unwrap_or(0) + 1
  self.run(async fn() {
    self.standing.run(key, async fn() {
      self.say_stands(channel, thread_ts, key, stands) catch {
        e => self.log("warn", "could not say where the thread stands", fields=[
          ("channel", js(channel)),
          ("thread", js(thread_ts)),
          ("error", js(message_of(e))),
        ])
      }
    }) catch {
      _ => ()
    }
    let left = self.standing_count.get(key).unwrap_or(1) - 1
    if left <= 0 {
      self.standing_count.remove(key)
    } else {
      self.standing_count[key] = left
    }
  })
}

///|
async fn SlackSurface::say_stands(self : SlackSurface, channel : String, thread_ts : String, key : String, stands : Stands?) -> Unit {
  match self.stands.get(key) {
    Some((ts, mine, _)) => {
      self.stands.remove(key)
      match mine {
        Some(m) => self.update(channel, ts, m.text, m.blocks)
        None => ignore(self.client.api("chat.delete", [("channel", channel), ("ts", ts)], self.bot_token))
      }
    }
    None => ()
  }
  let stands = match stands {
    Some(s) => s
    None => return
  }
  let end = self.ends.get(key)
  // (a question waiting at the end says it, as the chat leaves the line out while a card waits)
  match end {
    Some((_, Some(m))) if stands.kind == "need" && m.question => return
    _ => ()
  }
  let block = stands_block(self.o.words, stands, self.lang())
  // (a message holds 50 blocks)
  match end {
    Some((ts, Some(m))) if m.blocks.length() < 50 => {
      // (known as said before it goes: a change of the message meanwhile keeps it)
      self.stands[key] = (ts, Some(m), block)
      return self.update(channel, ts, m.text, m.blocks + [block])
    }
    _ => ()
  }
  let said = stands_text(self.o.words, stands, self.lang())
  let posted = self.post_message([
    ("channel", channel),
    ("thread_ts", thread_ts),
    ("text", said),
    ("blocks", stringify(ja([block]))),
  ])
  let ts = text(at(Some(posted), "ts"))
  if ts == "" {
    return
  }
  self.stands[key] = (ts, None, block)
  self.heard(channel, thread_ts, ts)
}

///|
/// A message changed in place, its blocks whole; where Slack still finds the cut text too long once its links are made,
/// once more with a text cut shorter (slack/surface.ts `update`).
async fn SlackSurface::update(self : SlackSurface, channel : String, ts : String, said : String, blocks : Array[J]) -> Unit {
  let call = async fn(text : String) {
    ignore(
      self.client.api(
        "chat.update",
        [("channel", channel), ("ts", ts), ("text", text), ("blocks", stringify(ja(blocks)))],
        self.bot_token,
      ),
    )
  }
  let first = update_text(said)
  call(first) catch {
    e => {
      let shorter = update_text(said, max_bytes=update_text_fallback_bytes)
      if blocks.length() == 0 || !message_of(e).contains("msg_too_long") || shorter == first {
        raise e
      }
      call(shorter)
    }
  }
}

///|
/// What an agent is doing in a thread (connects/surface.ts `working`; `status` "": the turn ended): its status line;
/// working again, where it stood is no longer so.
pub fn SlackSurface::working(
  self : SlackSurface,
  channel : String,
  thread_ts : String,
  message_ts : String?,
  status : String,
  page? : String? = None,
) -> Unit {
  if self.stopped {
    return
  }
  let key = thread_key(channel, thread_ts)
  let line = match self.lines.get(key) {
    Some(l) => l
    None => {
      let l = self.status_line(channel, thread_ts)
      self.lines[key] = l
      l
    }
  }
  if status == "" && self.lines.length() > 200 {
    self.lines.remove(key)
  }
  line.say(status, message_ts~, page~)
  if status != "" {
    self.stands_at(channel, thread_ts, None)
  }
}

///|
/// Sends a file's bytes to Slack (not yet shared anywhere): its file id and title.
async fn SlackSurface::upload(self : SlackSurface, name : String, bytes : Bytes) -> (String, String) {
  let url = self.client.api(
    "files.getUploadURLExternal",
    [("filename", name), ("length", bytes.length().to_string())],
    self.bot_token,
  )
  match (str_of(at(Some(url), "upload_url")), str_of(at(Some(url), "file_id"))) {
    (Some(u), Some(id)) => {
      self.client.upload(u, bytes, name)
      (id, name)
    }
    _ => raise fail_("slack files.getUploadURLExternal: no upload_url")
  }
}

///|
/// The ts of the message files were shared in, which Slack fills in a moment after the share.
async fn SlackSurface::shared_ts(self : SlackSurface, completed : J, file : String, channel : String) -> String? {
  let find = (f : J?) => {
    for k in ["public", "private"] {
      match str_of(at(at_i(at(at(at(f, "shares"), k), channel), 0), "ts")) {
        Some(ts) => return Some(ts)
        None => ()
      }
    }
    None
  }
  match find(at_i(at(Some(completed), "files"), 0)) {
    Some(ts) => return Some(ts)
    None => ()
  }
  for _ in 0..<10 {
    (self.client.net.sleep)(500)
    let info = self.client.api("files.info", [("file", file)], self.bot_token) catch { _ => return None }
    match find(at(Some(info), "file")) {
      Some(ts) => return Some(ts)
      None => ()
    }
  }
  None
}

///|
async fn SlackSurface::look_up(self : SlackSurface, user : String) -> J? {
  let d = self.client.api("users.info", [("user", user)], self.bot_token) catch { _ => return None }
  Some(person_of(Some(d)))
}

///|
/// users.lookupByEmail (users:read.email): users_not_found, or a deactivated account, is none.
async fn SlackSurface::look_up_email(self : SlackSurface, email : String) -> String? {
  let d = self.client.api("users.lookupByEmail", [("email", email)], self.bot_token) catch { _ => return None }
  let user = at(Some(d), "user")
  if is_true(at(user, "deleted")) {
    return None
  }
  match text(at(user, "id")) {
    "" => None
    id => Some(id)
  }
}

///|
/// A person as Slack says, kept for the connection's lifetime.
async fn SlackSurface::profile(self : SlackSurface, user : String) -> J? {
  match self.names.get(user) {
    Some(p) => return Some(p)
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
pub async fn SlackSurface::user_name(self : SlackSurface, user : String) -> String? {
  match text(at(self.profile(user), "name")) {
    "" => None
    n => Some(n)
  }
}

///|
/// Their email, where Slack shares it: what ties them to a still.fail account.
pub async fn SlackSurface::user_email(self : SlackSurface, user : String) -> String? {
  match text(at(self.profile(user), "email")) {
    "" => None
    e => Some(e)
  }
}

///|
/// The person there with this email, kept once found (one not found is asked again: they may join later).
pub async fn SlackSurface::user_of(self : SlackSurface, email : String) -> String? {
  let key = lower(trim(email))
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
/// A person as far as already known, without waiting; an unknown one is looked up in the background, and so is one
/// learned before pictures were kept.
pub fn SlackSurface::known_person(self : SlackSurface, user : String) -> J? {
  let team = self.workspace().unwrap_or("?")
  match self.o.names {
    Some(n) => return (n.person)("u:\{team}:\{user}", async fn() { self.look_up(user) }, (known, _) => at(Some(known), "picture") is None)
    None => ()
  }
  let book = match self.o.book {
    Some(b) => b
    None => return None
  }
  book.person("u:\{team}:\{user}", async fn() { self.look_up(user) }, stale=(known, _) => at(Some(known), "picture") is None)
}

///|
/// A channel's name as far as already known (None for DMs or not yet known), without waiting.
pub fn SlackSurface::known_channel(self : SlackSurface, channel : String) -> String? {
  match self.o.names {
    Some(n) => {
      let team = self.workspace().unwrap_or("?")
      return (n.channel)("c:\{team}:\{channel}", async fn() { self.channel_name_of(channel) })
    }
    None => ()
  }
  let book = match self.o.book {
    Some(b) => b
    None => return None
  }
  let team = self.workspace().unwrap_or("?")
  book.channel("c:\{team}:\{channel}", async fn() { self.channel_name_of(channel) })
}

///|
async fn SlackSurface::channel_name_of(self : SlackSurface, channel : String) -> String? {
  let r = self.client.api("conversations.info", [("channel", channel)], self.bot_token) catch { _ => return None }
  let c = at(Some(r), "channel")
  if is_true(at(c, "is_im")) {
    return None
  }
  match str_of(at(c, "name")) {
    Some(n) if n != "" => Some(n)
    _ => None
  }
}

///|
/// Whether a channel is shared with another organization (Slack Connect): a login's page and device code are not
/// shown there. Not known (the answer failed): taken as shared.
pub async fn SlackSurface::shared_out(self : SlackSurface, channel : String) -> Bool {
  let r = self.client.api("conversations.info", [("channel", channel)], self.bot_token) catch { _ => return true }
  let c = at(Some(r), "channel")
  nullish(c) || is_true(at(c, "is_ext_shared")) || is_true(at(c, "is_pending_ext_shared"))
}

///|
/// Channel name via conversations.info (None for DMs), kept for the connection's lifetime.
pub async fn SlackSurface::channel_name(self : SlackSurface, channel : String) -> String? {
  match self.channels.get(channel) {
    Some(n) => return n
    None => ()
  }
  let name = self.channel_name_of(channel)
  self.channels[channel] = name
  name
}

///|
/// A thread's messages before `before`, the last `limit` of them (`{ts, user, text, fromBot, files?}`).
pub async fn SlackSurface::history(self : SlackSurface, channel : String, thread_ts : String, before : String, limit : Int) -> Array[J] {
  let bot = self.bot_user_id()
  let all : Array[(Double, J)] = []
  let mut cursor : String? = None
  while true {
    let params = [("channel", channel), ("ts", thread_ts), ("limit", "200")]
    match cursor {
      Some(c) => params.push(("cursor", c))
      None => ()
    }
    let page = self.client.api("conversations.replies", params, self.bot_token)
    for m in arr(at(Some(page), "messages")) {
      let mm = Some(m)
      let by = match at(mm, "user") {
        None | Some(Null) => at(mm, "bot_id")
        u => u
      }
      let user = match by {
        Some(Str(u)) => @jsjson.text(u)
        _ => "unknown"
      }
      let from_bot = !nullish(at(mm, "bot_id")) || user == bot
      let files = message_files(mm)
      let ts = text(at(mm, "ts"))
      let fs = [("ts", js(ts)), ("user", js(user)), ("text", js(message_text(mm))), ("fromBot", jb(from_bot))]
      if files.length() > 0 {
        fs.push(("files", ja(files)))
      }
      all.push((ts_number(ts).unwrap_or(0.0), jo(fs)))
    }
    cursor = match str_of(at_path(Some(page), ["response_metadata", "next_cursor"])) {
      Some(n) if n != "" => Some(n)
      _ => None
    }
    if cursor is None {
      break
    }
  }
  let until = ts_number(before).unwrap_or(@double.max_value)
  let earlier = all.filter(m => m.0 < until).map(m => m.1)
  let from = @cmp.maximum(0, earlier.length() - limit)
  earlier[from:].to_array()
}

///|
/// A shared file's bytes (`{url, name}`), read as the bot (files:read).
pub async fn SlackSurface::download(self : SlackSurface, file : J) -> Bytes {
  match str_of(at(Some(file), "url")) {
    Some(u) => self.client.download(u, text(at(Some(file), "name")), self.bot_token)
    None => raise fail_("Slack does not give its contents")
  }
}

///|
/// Any Web API method as the bot; values that are not strings (blocks, arrays) go as JSON, as Slack takes them.
pub async fn SlackSurface::api(self : SlackSurface, meth : String, params : J) -> J {
  let form = match params {
    Obj(fs) =>
      fs.filter_map(f => match f.1 {
        Null => None
        v => Some((@jsjson.text(f.0), field(v)))
      })
    _ => []
  }
  self.client.api(meth, form, self.bot_token)
}

///|
/// A thread's status line, whose first call of a turn is the opportunity to set its app up (`on_working`).
fn SlackSurface::status_line(self : SlackSurface, channel : String, thread_ts : String) -> ThreadStatus {
  let working = Ref(false)
  let call = async fn(meth : String, params : Params) {
    let status = match params.search_by(p => p.0 == "status") {
      Some(i) => params[i].1
      None => ""
    }
    let agent_status = meth == "agents.sessions.setStatus"
    let legacy_status = meth == "assistant.threads.setStatus"
    let starts = (agent_status && status == "processing") || (legacy_status && status != "")
    let ends = (agent_status && status == "active") || (legacy_status && status == "")
    let setup : Ref[@effect.Deferred[Bool]?] = Ref(None)
    if starts && !working.val {
      working.val = true
      let d : @effect.Deferred[Bool] = @effect.Deferred::new()
      setup.val = Some(d)
      self.run(async fn() {
        let ok = (self.o.on_working)() catch { _ => false }
        ignore(d.succeed(ok))
      })
    }
    let call_once = async fn() { ignore(self.client.api(meth, params, self.bot_token)) }
    let finish = () => if ends {
      working.val = false
    }
    call_once() catch {
      e => {
        // The first call can race with setup. Only wait if the session API actually failed, so an app that is already
        // enabled shows its status immediately even when a manifest request is slow.
        let again = match setup.val {
          Some(d) if agent_status && starts && message_of(e).contains("not_authorized") => d.wait() catch { _ => false }
          _ => false
        }
        if !again {
          finish()
          raise e
        }
        call_once() catch {
          e2 => {
            finish()
            raise e2
          }
        }
      }
    }
    finish()
  }
  ThreadStatus::new(call, { ..self.o.clock, fork: f => self.spawn(f) }, self.o.log, channel, thread_ts)
}
