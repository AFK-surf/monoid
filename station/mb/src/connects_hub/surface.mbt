// A connect's surface on a platform that tells the station what happens over a socket the station opens
// (connects/surface.ts `ConnectedSurface`: Slack's Socket Mode, Feishu's long connection, the group connect's link): who
// its bot is; the socket kept up, connected again whenever it closes (platforms rotate them) or fails (after a wait
// that doubles up to a minute), pinged, and taken for dead once it said nothing for a while (a connection cut on the
// way can look open forever, and nothing would come through it again: 2026-09-30 on bft); what people are called
// there, kept for the connection's lifetime; the status lines of the threads its agents work for. Its socket's loop is
// a fiber in the surface's scope, and stopping the surface closes the scope (the socket with it). What a platform says
// on its socket and is told through its API is its own (`hooks`, set by the platform's surface as it is made).

///|
/// How long who is in a channel or group is kept for (`peopleIn`: who a note relaying a chat there can mention).
pub let members_ms : Double = 60000.0

///|
let max_backoff_ms : Double = 60000.0

///|
/// The socket errors where the other side was not reached (ops/unanswered.ts `UNREACHED`).
let unreached : Array[String] = [
  "ECONNREFUSED", "ECONNRESET", "ECONNABORTED", "ENOTFOUND", "EAI_AGAIN", "ETIMEDOUT", "EHOSTUNREACH", "ENETUNREACH", "EPIPE",
]

///|
/// Whether a request got no answer at all (ops/unanswered.ts): no way there (fetch's "fetch failed", a socket's
/// error, said by its code as the error's kind) or none in time (`TimeoutError`).
pub fn unanswered(e : Error) -> Bool {
  let kind = thrown_kind(e)
  kind == "TimeoutError" || (kind == "TypeError" && thrown_message(e) == "fetch failed") || unreached.contains(kind)
}

///|
/// Parses a shell `ws.open` refusal message (`"websocket refused (<code>)"` or `"websocket refused (<code>): <why>"`)
/// into `(status, why)`.
pub fn parse_ws_refusal(words : String) -> (Int, String)? {
  match words.find("websocket refused (") {
    Some(at) => {
      let rest = words.unsafe_substring(start=at + 19, end=words.length())
      let digits = rest.iter().take_while(c => c >= '0' && c <= '9').collect()
      if digits.is_empty() || digits.length() > 6 {
        return None
      }
      let mut n = 0
      for c in digits {
        n = n * 10 + (c.to_int() - '0'.to_int())
      }
      let tail = words.unsafe_substring(start=at + 19 + digits.length(), end=words.length())
      if !tail.has_prefix(")") {
        return None
      }
      let why = if tail.has_prefix("): ") {
        tail.unsafe_substring(start=3, end=tail.length()).trim().to_owned()
      } else {
        ""
      }
      Some((n, why))
    }
    None => None
  }
}

///|
/// One socket of the machine's (the `ws` package's WebSocket), as `socket_to` keeps it up.
pub(all) struct Socket {
  /// What it says, in order, as it comes.
  events : @effect.Queue[SocketEvent]
  send : (Bytes) -> Unit
  ping : () -> Unit
  /// Cut off (`terminate`).
  terminate : () -> Unit
  /// Open now (`readyState === WebSocket.OPEN`): opened, and neither closed nor cut off since.
  is_open : () -> Bool
}

///|
pub(all) enum SocketEvent {
  Opened
  Said(Bytes, Bool)
  Pong
  Pinged
  Closed
  Failed(String)
  /// The platform said no in the handshake's answer: its status and its `handshake-msg`.
  Refused(Int, String)
}

///|
/// What one socket does besides being kept up (`SocketHooks`): as it opens, with what it says (when, on the surface's
/// clock; `end` ends the socket, None, or fails it: the platform asks for another), and as it is pinged.
pub(all) struct SocketHooks {
  opened : (Socket) -> Unit
  message : (Socket, Bytes, Bool, Double, (String?) -> Unit) -> Unit
  ping : (Socket) -> Unit
}

///|
pub(all) struct SurfaceOptions {
  /// The connect it is (for the log).
  connect : String?
  /// Keeps names across restarts and lets the admin API ask without waiting.
  book : NameBook?
  /// How often the socket is pinged, and how long it may say nothing before it is taken for dead.
  ping_ms : Double
  stale_ms : Double
  /// The first wait before connecting again after a failure (doubling up to a minute).
  backoff_ms : Double
  clock : Clock
  /// Told each time a socket said something (a pong too).
  on_heard : () -> Unit
  log : Log
  /// Opens a socket to `url` with what its handshake carries besides (a platform that keeps its own link has none).
  open_socket : ((String, Array[(String, String)]) -> Socket)?
}

///|
pub struct ConnectedSurface {
  /// What the log calls the platform ("slack", "feishu", "group").
  kind : String
  connect : String?
  book : NameBook?
  mut me : J
  priv mut connected : Bool
  priv mut last_error : String?
  priv listeners : Listeners
  /// People as the platform says, by their id there.
  names : Map[String, J]
  /// People found by their email (`user_of`), by it.
  priv by_email : Map[String, String]
  /// Each thread an agent works for: its status line.
  lines : Map[String, StatusLine]
  ping_ms : Double
  stale_ms : Double
  backoff_ms : Double
  clock : Clock
  on_heard : () -> Unit
  mut stopped : Bool
  scope : @effect.Scope
  /// What `kept` holds: each answer as it was asked for (one asking at a time) and when.
  priv answers : Map[String, (Double, @effect.Deferred[J])]
  log : Log
  priv open_socket : ((String, Array[(String, String)]) -> Socket)?
  /// Who its bot is and where, as the platform says now (a `BotIdentity`).
  mut identify : async () -> J
  /// Where its socket connects to now (asked again for each).
  mut address : async () -> String
  /// One connection to `url`, its events given to the handler: ends as it closes, raises as it fails.
  mut run_socket : async (String, async (J) -> Unit) -> Unit
  /// What the platform says of a person (None: nothing, or it could not be asked).
  mut look_up : async (String) -> J?
  /// The id of the person with this email (None: none, or it could not be asked).
  mut look_up_email : async (String) -> String?
  /// A thread's status line.
  mut status_line : (J) -> StatusLine
  /// An identity it cannot work as raises (Feishu's app without a bot).
  usable : (J) -> Unit raise
}

///|
pub fn ConnectedSurface::new(kind : String, options : SurfaceOptions, usable? : (J) -> Unit raise = _ => ()) -> ConnectedSurface {
  let scope = @effect.runtime().root().child()
  {
    kind,
    connect: options.connect,
    book: options.book,
    me: Null,
    connected: false,
    last_error: None,
    listeners: Listeners::new(),
    names: {},
    by_email: {},
    lines: {},
    ping_ms: options.ping_ms,
    stale_ms: options.stale_ms,
    backoff_ms: options.backoff_ms,
    clock: options.clock,
    on_heard: options.on_heard,
    stopped: false,
    scope,
    answers: {},
    log: options.log,
    open_socket: options.open_socket,
    identify: async fn() { raise fail_("no identify") },
    address: async fn() { raise fail_("no address") },
    run_socket: async fn(_, _) { raise fail_("no socket") },
    look_up: async fn(_) { None },
    look_up_email: async fn(_) { None },
    status_line: _ => abort("no status line"),
    usable,
  }
}

///|
/// Runs `f` as a fiber of the surface's scope (on its clock): it ends when the surface stops.
pub fn ConnectedSurface::run(self : ConnectedSurface, f : async () -> Unit) -> Unit {
  spawn_in(self.scope, f)
}

///|
/// The connect's id as the log says it (absent where it has none).
fn ConnectedSurface::connect_j(self : ConnectedSurface) -> J {
  match self.connect {
    Some(c) => js(c)
    None => undefined()
  }
}

///|
/// What `read` answers for `key`, kept for `ms` on the surface's clock: asked again only after, or once it failed;
/// those asking while it is asked wait for that answer.
pub async fn ConnectedSurface::kept(self : ConnectedSurface, key : String, ms : Double, read : async () -> J) -> J {
  let now = (self.clock.now)()
  match self.answers.get(key) {
    Some((at_, d)) if now - at_ < ms => return d.wait()
    _ => ()
  }
  let d : @effect.Deferred[J] = @effect.Deferred::new()
  self.answers[key] = (now, d)
  spawn(async fn() {
    let v = read() catch {
      e => {
        match self.answers.get(key) {
          Some((_, had)) if physical_equal(had, d) => self.answers.remove(key)
          _ => ()
        }
        ignore(d.fail(e))
        return
      }
    }
    ignore(d.succeed(v))
  })
  d.wait()
}

///|
/// `kept`'s answer for `key` let go of when it was asked at least `ms` ago: whether it was.
pub fn ConnectedSurface::forget(self : ConnectedSurface, key : String, ms : Double) -> Bool {
  match self.answers.get(key) {
    Some((at_, _)) if (self.clock.now)() - at_ >= ms => {
      self.answers.remove(key)
      true
    }
    _ => false
  }
}

///|
pub fn ConnectedSurface::identity(self : ConnectedSurface) -> J {
  self.me
}

///|
/// `{connected, lastError}`.
pub fn ConnectedSurface::socket(self : ConnectedSurface) -> J {
  jo([("connected", jb(self.connected)), ("lastError", jopt(self.last_error))])
}

///|
/// Hears each change of the socket's status, and of the identity; gives the function that stops it.
pub fn ConnectedSurface::on_change(self : ConnectedSurface, listener : () -> Unit) -> () -> Unit {
  self.listeners.add(listener)
}

///|
pub fn ConnectedSurface::changed(self : ConnectedSurface) -> Unit {
  self.listeners.tell()
}

///|
pub fn ConnectedSurface::set_status(self : ConnectedSurface, connected : Bool, last_error : String?) -> Unit {
  if self.connected == connected && self.last_error == last_error {
    return
  }
  self.connected = connected
  self.last_error = last_error
  self.changed()
}

///|
/// Reads again who the bot is and where (its name changed on the platform, say); listeners hear of it.
pub async fn ConnectedSurface::refresh_identity(self : ConnectedSurface) -> Unit {
  self.me = (self.identify)()
  self.changed()
}

///|
pub fn ConnectedSurface::bot_user_id(self : ConnectedSurface) -> String {
  str_of(at(Some(self.me), "botUserId")).unwrap_or("")
}

///|
pub fn ConnectedSurface::bot_name(self : ConnectedSurface) -> String {
  str_of(at(Some(self.me), "botName")).unwrap_or("")
}

///|
pub fn ConnectedSurface::workspace(self : ConnectedSurface) -> String? {
  match str_of(at(Some(self.me), "teamId")).unwrap_or("") {
    "" => None
    team => Some(team)
  }
}

///|
/// Who its bot is, then its socket kept up. The platform's refusal (a token it takes no more, an app without a bot)
/// fails it; no answer at all (the network down as the station starts: 2026-11-12, an update's new process left
/// Slack and Feishu unconnected for 38 minutes) does not: it is asked again on the socket's backoff, the socket
/// opened once it answers.
pub async fn ConnectedSurface::start(self : ConnectedSurface, handler : async (J) -> Unit) -> Unit {
  let identity = (self.identify)() catch {
    e => {
      if !unanswered(e) {
        raise e
      }
      self.not_reached(e, self.backoff_ms)
      self.run(async fn() { self.identify_loop(handler) })
      return
    }
  }
  self.began(identity, handler)
}

///|
fn ConnectedSurface::began(self : ConnectedSurface, identity : J, handler : async (J) -> Unit) -> Unit raise {
  (self.usable)(identity)
  self.log.info(
    self.kind,
    "\{self.kind} authenticated",
    jo([
      ("connect", self.connect_j()),
      ("bot", at(Some(identity), "botName").unwrap_or(undefined())),
      ("botUserId", at(Some(identity), "botUserId").unwrap_or(undefined())),
      ("team", at(Some(identity), "team").unwrap_or(undefined())),
    ])
    |> drop_undefined,
  )
  self.me = identity
  self.run(async fn() { self.connect_loop(handler) })
}

///|
fn ConnectedSurface::not_reached(self : ConnectedSurface, e : Error, retry_in_ms : Double) -> Unit {
  let said = thrown_message(e)
  self.set_status(false, Some(said))
  self.log.warn(self.kind, "\{self.kind} not reached", jo([("connect", self.connect_j()), ("error", js(said)), ("retryInMs", jn(retry_in_ms))]) |> drop_undefined)
}

///|
/// Asks who its bot is again (after a wait that doubles up to a minute) until the platform answers, then goes on as
/// `start` would have; a refusal then ends it, said as the socket's error.
async fn ConnectedSurface::identify_loop(self : ConnectedSurface, handler : async (J) -> Unit) -> Unit {
  let mut backoff = self.backoff_ms
  while true {
    (self.clock.sleep)(backoff)
    backoff = @cmp.minimum(backoff * 2.0, max_backoff_ms)
    let asked : Result[J, Error] = try Ok((self.identify)()) catch {
      e => {
        if @effect.is_interrupted() {
          raise e
        }
        Err(e)
      }
    }
    match asked {
      Err(e) if unanswered(e) => {
        self.not_reached(e, backoff)
        continue
      }
      _ => ()
    }
    try {
      match asked {
        Err(e) => raise e
        Ok(identity) => self.began(identity, handler)
      }
    } catch {
      e => {
        let said = thrown_message(e)
        self.set_status(false, Some(said))
        self.log.error(self.kind, "failed to connect", jo([("connect", self.connect_j()), ("error", js(said))]) |> drop_undefined)
      }
    }
    return
  }
}

///|
pub async fn ConnectedSurface::stop(self : ConnectedSurface) -> Unit {
  if self.stopped {
    return
  }
  self.stopped = true
  self.scope.close()
}

///|
/// Connects again whenever the socket closes or fails (after a wait that doubles up to a minute), until it stops.
async fn ConnectedSurface::connect_loop(self : ConnectedSurface, handler : async (J) -> Unit) -> Unit {
  let mut backoff = self.backoff_ms
  while true {
    let failed : String? = try {
      let url = (self.address)()
      (self.run_socket)(url, handler)
      None
    } catch {
      e => {
        if @effect.is_interrupted() {
          raise e
        }
        Some(thrown_message(e))
      }
    }
    match failed {
      None => backoff = self.backoff_ms
      Some(said) => {
        self.set_status(false, Some(said))
        self.log.warn(self.kind, "\{self.kind} socket failed", jo([("connect", self.connect_j()), ("error", js(said)), ("retryInMs", jn(backoff))]) |> drop_undefined)
        (self.clock.sleep)(backoff)
        backoff = @cmp.minimum(backoff * 2.0, max_backoff_ms)
      }
    }
  }
}

///|
/// One socket: ends when it closes (or a hook ends it), and fails on its error, when it did not open within
/// `stale_ms`, or when it then said nothing (not even a pong) for `stale_ms`; pinged every `ping_ms` meanwhile.
/// `headers`: what its handshake carries besides (Comma's bearer token).
pub async fn ConnectedSurface::socket_to(self : ConnectedSurface, url : String, hooks : SocketHooks, headers? : Array[(String, String)] = []) -> Unit {
  guard self.open_socket is Some(open_socket) else { raise fail_("\{self.kind} has no sockets") }
  let kind = self.kind
  let opened : @effect.Deferred[Unit] = @effect.Deferred::new()
  let heard = Ref((self.clock.now)())
  let ws : Ref[Socket?] = Ref(None)
  // The socket itself: ends when it closes, fails on its error. Interrupted (it went quiet, or the surface stops), it
  // is cut off.
  let open = async fn() -> Unit {
    let socket = open_socket(url, headers)
    ws.val = Some(socket)
    let finished = Ref(false)
    let ended : Ref[Result[Unit, String]?] = Ref(None)
    let cut = () => {
      finished.val = true
      (socket.terminate)()
    }
    let end = (error : String?) => {
      if finished.val {
        return
      }
      cut()
      match error {
        Some(e) => ended.val = Some(Err(e))
        None => {
          self.set_status(false, self.last_error)
          ended.val = Some(Ok(()))
        }
      }
    }
    let alive = () => {
      heard.val = (self.clock.now)()
      (self.on_heard)()
    }
    try {
      while ended.val is None {
        match socket.events.take() {
          // The platform says no in the handshake's answer (an app without the socket, too many sockets).
          Refused(status, said) => end(Some("\{kind} refused the connection: HTTP \{status} \{said}".trim().to_owned()))
          Opened => {
            heard.val = (self.clock.now)()
            self.set_status(true, None)
            ignore(opened.succeed(()))
            (hooks.opened)(socket)
          }
          Pong | Pinged => alive()
          Said(data, binary) => {
            alive()
            (hooks.message)(socket, data, binary, heard.val, end)
          }
          Closed => end(None)
          Failed(e) => end(Some(e))
        }
      }
    } catch {
      e => {
        if !finished.val {
          cut()
        }
        raise e
      }
    }
    match ended.val {
      Some(Err(e)) => raise fail_(e)
      _ => ()
    }
  }
  // Its watch: open within `stale_ms`, then a ping every `ping_ms`; it fails once the socket said nothing for
  // `stale_ms`.
  let watch = async fn() -> Unit {
    let stale = self.stale_ms
    let got = @effect.race_first(
      async fn() -> Bool {
        opened.wait()
        true
      },
      async fn() -> Bool {
        (self.clock.sleep)(stale)
        false
      },
    )
    if !got {
      raise fail_("\{kind} socket did not open within \{@session_chats.num_text(stale / 1000.0)}s")
    }
    while true {
      (self.clock.sleep)(self.ping_ms)
      let quiet = (self.clock.now)() - heard.val
      if quiet >= stale {
        raise fail_("\{kind} socket said nothing for \{@session_chats.num_text(quiet / 1000.0)}s")
      }
      match ws.val {
        Some(s) => {
          (hooks.ping)(s)
          (s.ping)()
        }
        None => ()
      }
    }
  }
  @effect.race_first(open, watch)
}

///|
/// A person as the platform says, kept for the connection's lifetime.
pub async fn ConnectedSurface::profile(self : ConnectedSurface, user : String) -> J? {
  match self.names.get(user) {
    Some(known) => return Some(known)
    None => ()
  }
  let person = (self.look_up)(user)
  match person {
    Some(p) => self.names[user] = p
    None => ()
  }
  person
}

///|
/// Their display name, kept for the connection's lifetime.
pub async fn ConnectedSurface::user_name(self : ConnectedSurface, user : String) -> String? {
  match self.profile(user) {
    Some(p) =>
      match str_of(at(Some(p), "name")) {
        Some(n) if n != "" => Some(n)
        _ => None
      }
    None => None
  }
}

///|
/// Their email, where the platform shares it: what ties them to a still.fail account.
pub async fn ConnectedSurface::user_email(self : ConnectedSurface, user : String) -> String? {
  match self.profile(user) {
    Some(p) =>
      match str_of(at(Some(p), "email")) {
        Some(n) if n != "" => Some(n)
        _ => None
      }
    None => None
  }
}

///|
/// The person there with this email, kept for the connection's lifetime once found (one not found is asked again:
/// they may join later).
pub async fn ConnectedSurface::user_of(self : ConnectedSurface, email : String) -> String? {
  let key = @session_chats.lower(@session_chats.trim(email))
  if key == "" {
    return None
  }
  match self.by_email.get(key) {
    Some(u) => return Some(u)
    None => ()
  }
  let user = (self.look_up_email)(key)
  match user {
    Some(u) => self.by_email[key] = u
    None => ()
  }
  user
}

///|
pub fn ConnectedSurface::working(self : ConnectedSurface, thread : J, message_ts : String?, status : String, page : String?) -> Unit {
  if self.stopped {
    return
  }
  let key = "\{js_text(at(Some(thread), "channel"))}/\{js_text(at(Some(thread), "threadTs"))}"
  let line = match self.lines.get(key) {
    Some(l) => l
    None => {
      let l = (self.status_line)(thread)
      self.lines[key] = l
      l
    }
  }
  if status == "" && self.lines.length() > 200 {
    self.lines.remove(key)
  }
  line.say(status, message_ts~, page~)
}

///|
/// The calls every connected surface answers the same way (`get` of these names), None for the rest.
pub fn ConnectedSurface::base_get(self : ConnectedSurface, name : String, args : Array[J]) -> J? {
  match name {
    "botUserId" => Some(js(self.bot_user_id()))
    "botName" => Some(js(self.bot_name()))
    "identity" => Some(self.me)
    "platform" => Some(js(self.kind))
    "workspace" => Some(jopt(self.workspace()))
    "cards" => Some(jb(true))
    "working" => {
      let ts = str_of(args.get(1))
      let page = str_of(args.get(3))
      self.working(args.get(0).unwrap_or(Null), ts, str_of(args.get(2)).unwrap_or(""), page)
      Some(undefined())
    }
    _ => None
  }
}

///|
/// The calls every connected surface answers the same way, waited on, None for the rest.
pub async fn ConnectedSurface::base_call(self : ConnectedSurface, name : String, args : Array[J]) -> J? {
  let s = (i : Int) => str_of(args.get(i)).unwrap_or(js_text(args.get(i)))
  match name {
    "userName" => Some(jopt(self.user_name(s(0))))
    "userEmail" => Some(jopt(self.user_email(s(0))))
    "userOf" => Some(jopt(self.user_of(s(0))))
    "refreshIdentity" => {
      self.refresh_identity()
      Some(undefined())
    }
    _ => self.base_get(name, args)
  }
}

///|
/// How a platform made outside this package says what its agent is doing in a thread (Comma's `Quiet`, say).
pub fn ConnectedSurface::set_status_line(self : ConnectedSurface, line : (J) -> StatusLine) -> Unit {
  self.status_line = line
}

///|
/// A platform's surface made outside this package (the station's Feishu and Comma surfaces): who its bot is, where its
/// socket is and what it does there, how a person and their email are looked up.
pub fn ConnectedSurface::hooked(
  self : ConnectedSurface,
  identify~ : async () -> J,
  address~ : async () -> String,
  run_socket~ : async (String, async (J) -> Unit) -> Unit,
  look_up~ : async (String) -> J?,
  look_up_email~ : async (String) -> String?,
) -> Unit {
  self.identify = identify
  self.address = address
  self.run_socket = run_socket
  self.look_up = look_up
  self.look_up_email = look_up_email
}
