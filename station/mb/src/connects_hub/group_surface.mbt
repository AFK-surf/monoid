// A group connect as a chat surface (group/surface.ts): the station as a member of an IM community of AFK-surf/group
// (`im/2`), as it is a bot in Slack or Feishu (surface.mbt keeps its link up, connected again after a wait that doubles
// whenever it goes). Its link (group_link.mbt) is let in by the connect's key, and by the code it joins with the first
// time; then the anchor's stream (`GET /events`) tells it each event of its spaces as it is taken, and `POST /sync`
// what each space took since the last event taken of it (group_threads.mbt), so nothing is taken twice and nothing
// said while it was away is lost. Every event is checked as the IM's devices check it (group_event.mbt: its id worked
// out again, its signature its device's), and what the station says is an event signed by the connect's key, its
// device's own count after its last.
//
// A space's stream is a thread: the lobby is `<space>/<space>`, a topic `<space>/<topic>`, each a session of its own.
// A message's ts is its event's place in its space (`aseq`). Every message of a direct space calls the agent; in a
// space, one that mentions the bot (`@name`), answers one of its messages or opens a topic that does, and the rest go
// to a session that follows that stream already.
//
// What the IM has for an agent besides words: a card goes as a decision (`decision.ask`, its options or a field), its
// answer (`decision.resolve`) handed to the session as the person's message; while the agent works, what it does is
// the stream's live state (`POST /spaces/<id>/live`, gone once it ends), whose Stop (`stop` on the stream) stops the
// turn; and a secret a member hands it end to end (`im-secret/1` to this device, or the anchor's `secret` in passing)
// reaches the session as a file of its uploads, never in a message's words, a log or what the station keeps.

///|
/// The longest words of one message, in characters.
let chars_most : Int = 10000

///|
/// The most files one message carries (the anchor's `files_most`).
let files_most : Int = 10

///|
/// The largest file an anchor takes (512 MiB, its `file_most`): a larger one is refused here before it is read.
let file_most : Double = 536870912.0

///|
/// A file larger than this goes a piece of this at a time (`im/2` wave 4): its SHA-256 worked out as it is read, then
/// put from what the anchor has of it already on, so neither side holds more of it than a piece.
let piece_most : Double = 1048576.0

///|
/// The largest file an anchor from before pieces takes, whole in one ask.
let whole_most : Double = 33554432.0

///|
/// How much of a file's head is read for a picture's size.
let head_most : Double = 262144.0

///|
/// So many answers in a row that take nothing more of a file before it is given up.
let stalled_most : Int = 3

///|
/// A topic's title, at most (the anchor's `space_name_most`).
let title_most : Int = 60

///|
/// The most options a decision has, and the longest its label, the line under it, a field's hint and a live state's
/// words are.
let options_most : Int = 8

///|
let option_most : Int = 200

///|
let live_most : Int = 200

///|
/// So many of a stream's last messages are kept in memory.
let tail_most : Int = 200

///|
/// The most pages of a space's events a history read asks of the anchor (500 events each).
let history_pages : Int = 40

///|
/// The control stream's ping: how often, and how long it may go unanswered before the link is taken for dead.
let ping_ms : Double = 15000.0

///|
let stale_ms : Double = 45000.0

///|
/// How often a live state still shown is said again: the anchor lets one go 90 s after it was last said.
let live_again_ms : Double = 60000.0

///|
/// The least time between two changes of a stream's live state.
let live_interval_ms : Double = 2000.0

///|
/// So many closed decisions are kept to know an answer to one.
let closed_kept : Int = 256

///|
/// So many secrets' ids are kept to know one handed again.
let secrets_seen_most : Int = 256

///|
/// A message (a post, or a decision asked) as the station heard it.
priv struct Said {
  id : String
  space : String
  topic : String
  aseq : Double
  kind : String
  author : String
  mut text : String
  mut files : Array[J]
  reply_to : String
  mut deleted : Bool
}

///|
priv struct Space {
  id : String
  kind : String
  name : String
  members : Array[J]
}

///|
priv struct Topic {
  mut title : String
  by : String
  branched_from : String
}

///|
/// What came of a file put a piece at a time, as the anchor answers it (`{have}`; 0 where it says none).
fn have_of(body : Bytes) -> Double {
  let j = body_json(body) catch { _ => return 0.0 }
  match num_of(at(Some(j), "have")) {
    Some(n) if n >= 0.0 && n == n.floor() && n <= 9007199254740991.0 => n
    _ => 0.0
  }
}

///|
/// A character the anchor takes in no name (roster.mbt `unseen`): a control or format character, a line or paragraph
/// separator, half of a pair.
fn unseen(v : Int) -> Bool {
  v < 0x20 ||
  (v >= 0x7F && v <= 0x9F) ||
  v == 0xAD ||
  (v >= 0x600 && v <= 0x605) ||
  v == 0x61C ||
  v == 0x6DD ||
  v == 0x70F ||
  v == 0x180E ||
  (v >= 0x200B && v <= 0x200F) ||
  (v >= 0x2028 && v <= 0x202E) ||
  (v >= 0x2060 && v <= 0x2064) ||
  (v >= 0x2066 && v <= 0x206F) ||
  v == 0xFEFF ||
  (v >= 0xFFF9 && v <= 0xFFFB) ||
  (v >= 0xD800 && v <= 0xDFFF) ||
  v == 0xE0001 ||
  (v >= 0xE0020 && v <= 0xE007F)
}

///|
/// A topic's title as the anchor takes one (roster.mbt `name_of`): a control character a space, what else is not seen
/// left out, trimmed, 60 characters at most; "" where nothing is left.
fn topic_title(title : String) -> String {
  let kept : Array[Char] = []
  for c in title {
    let v = c.to_int()
    if v < 0x20 {
      kept.push(' ')
    } else if !unseen(v) {
      kept.push(c)
    }
  }
  let mut a = 0
  while a < kept.length() && kept[a] == ' ' {
    a += 1
  }
  let mut b = kept.length()
  while b > a && kept[b - 1] == ' ' {
    b -= 1
  }
  if b - a > title_most {
    b = a + title_most
  }
  while b > a && kept[b - 1] == ' ' {
    b -= 1
  }
  let out = StringBuilder()
  for i in a..<b {
    out.write_char(kept[i])
  }
  out.to_string()
}

///|
/// `typeof v === "string" ? v : ""`.
fn text_j(v : J?) -> String {
  str_of(v).unwrap_or("")
}

///|
/// The thread of a space's stream (`threadOf`).
pub fn thread_of(space : String, topic : String) -> J {
  jo([("channel", js(space)), ("threadTs", js(if topic == lobby || topic == "" { space } else { topic }))])
}

///|
/// The stream of a thread (`streamOf`): its space and topic.
pub fn stream_of(thread : J) -> (String, String) {
  let channel = js_text(at(Some(thread), "channel"))
  let ts = js_text(at(Some(thread), "threadTs"))
  (channel, if ts == channel { lobby } else { ts })
}

///|
/// A stream's key, as the IM's session says it (session.mbt `stream_of`).
pub fn stream_key(space : String, topic : String) -> String {
  if topic == lobby || topic == "" {
    space
  } else {
    "\{space}/\{topic}"
  }
}

///|
/// The files a message carries, as the anchor keeps them (`FileRef`).
pub fn files_of(v : J?) -> Array[J] {
  arr_of(v)
  .unwrap_or([])
  .filter(f => match str_of(at(Some(f), "sha256")) { Some(h) => lower_hex_of(h, 64); None => false })
  .map(f => {
    let fields = [
      ("sha256", at(Some(f), "sha256").unwrap()),
      ("name", js(text_j(at(Some(f), "name")))),
      ("mime", js(text_j(at(Some(f), "mime")))),
      ("size", match at(Some(f), "size") { Some(Num(_) as n) => n; _ => jn(0.0) }),
    ]
    match (at(Some(f), "width"), at(Some(f), "height")) {
      (Some(Num(w)), Some(Num(h))) if w > 0.0 && h > 0.0 => {
        fields.push(("width", jn(w)))
        fields.push(("height", jn(h)))
      }
      _ => ()
    }
    jo(fields)
  })
}

///|
/// A card as a decision's body (the IM's `decision.ask`): its question, its options (each its label, the line under
/// it and whether it is the one recommended) or a field to type into.
pub fn decision_body(text : String, card : J) -> J {
  let cut = (s : String) => s.to_array()[0:@cmp.minimum(option_most, s.to_array().length())].iter().fold(init="", (a, c) => a + c.to_string())
  let c = Some(card)
  if str_of(at(c, "type")) == Some("text") {
    return jo([("text", js(text)), ("input", js("text")), ("options", ja([])), ("placeholder", js(cut(text_j(at(c, "placeholder"))))), ("files", ja([]))])
  }
  let seen : Set[String] = Set([])
  let options : Array[J] = []
  for o in arr_of(at(c, "options")).unwrap_or([]) {
    guard str_of(at(Some(o), "label")) is Some(label) && @session_chats.trim(label) != "" else { continue }
    let label = cut(label)
    if seen.contains(label) {
      continue
    }
    seen.add(label)
    if options.length() >= options_most {
      continue
    }
    let fields = [("label", js(label))]
    match str_of(at(Some(o), "detail")) {
      Some(d) if d != "" => fields.push(("detail", js(cut(d))))
      _ => ()
    }
    if at(Some(o), "recommended") is Some(Bool(true)) {
      fields.push(("recommended", jb(true)))
    }
    options.push(jo(fields))
  }
  jo([("text", js(text)), ("input", js("options")), ("options", ja(options)), ("files", ja([]))])
}

///|
pub struct GroupSurfaceOptions {
  connect : String
  /// The anchor's endpoint id (64 hex) and its relays; where it is besides (a test's).
  server : String
  relays : Array[String]
  ips : Array[String]
  /// The connect's key (32 bytes, hex): this device in the community, what its events are signed by.
  key : String
  /// The code it joins by (an invitation, a device code) while it has not; None once it has.
  code : String?
  /// The name it joins as, and is renamed to where the anchor has another.
  bot_name : String?
  threads : GroupThreads
  book : NameBook?
  /// What binds its endpoint: the station's mesh (tests: one of theirs).
  endpoints : Endpoints
  clock : Clock
  ping_ms : Double?
  stale_ms : Double?
  backoff_ms : Double?
  on_heard : () -> Unit
  log : Log
  fs : Fs
  speech : Speech
  uuid : () -> String
  signer : Signer
}

///|
pub struct GroupSurface {
  base : ConnectedSurface
  connect : String
  server : String
  priv link : GroupLink
  priv threads : GroupThreads
  priv code : String?
  priv wanted : String?
  priv link_ping_ms : Double
  priv link_stale_ms : Double
  priv heard_hook : () -> Unit
  priv key : String
  /// This device (the key's public half).
  device_id : String
  priv hlc : Hlc
  priv mut joined : Bool
  priv space_rows : Map[String, Space]
  priv topics : Map[String, Topic]
  priv cursors : Map[String, Double]
  priv floors : Map[String, Double]
  priv provisional : Set[String]
  priv whole : Set[String]
  priv tails : Map[String, Array[Said]]
  priv by_id : Map[String, Said]
  priv by_aseq : Map[String, Said]
  priv cut : Set[String]
  priv members : Map[String, String]
  priv asks : Map[String, (String, String)]
  priv asked : Map[String, (String, String, Array[String])]
  priv closed : Set[String]
  priv secrets : Map[String, Bytes]
  priv secrets_seen : Set[String]
  priv taking : Turns
  priv saying : Turns
  priv mut handler : (async (J) -> Unit)?
  priv mut accepting_secrets : Bool
  priv fs : Fs
  priv speech : Speech
  priv signer : Signer
  priv uuid : () -> String
}

///|
pub fn GroupSurface::new(o : GroupSurfaceOptions) -> GroupSurface raise {
  if !lower_hex_of(o.server, 64) {
    raise fail_("group.server is the IM anchor's endpoint id (64 hex)")
  }
  if !lower_hex_of(o.key, 64) {
    raise fail_("group.key is missing")
  }
  let base = ConnectedSurface::new("group", {
    connect: Some(o.connect),
    book: o.book,
    ping_ms: o.ping_ms.unwrap_or(ping_ms),
    stale_ms: o.stale_ms.unwrap_or(stale_ms),
    backoff_ms: o.backoff_ms.unwrap_or(1000.0),
    clock: o.clock,
    on_heard: o.on_heard,
    log: o.log,
    open_socket: None,
  })
  let g : GroupSurface = {
    base,
    connect: o.connect,
    server: o.server,
    link: GroupLink::new({ endpoints: o.endpoints, secret_key: o.key, server: o.server, relays: o.relays, ips: o.ips }),
    threads: o.threads,
    code: o.code,
    wanted: o.bot_name,
    link_ping_ms: o.ping_ms.unwrap_or(ping_ms),
    link_stale_ms: o.stale_ms.unwrap_or(stale_ms),
    heard_hook: o.on_heard,
    key: o.key,
    device_id: (o.signer.public_key)(o.key).unwrap_or(""),
    hlc: Hlc::new(),
    joined: false,
    space_rows: Map([]),
    topics: Map([]),
    cursors: Map([]),
    floors: Map([]),
    provisional: Set([]),
    whole: Set([]),
    tails: Map([]),
    by_id: Map([]),
    by_aseq: Map([]),
    cut: Set([]),
    members: Map([]),
    asks: Map([]),
    asked: Map([]),
    closed: Set([]),
    secrets: Map([]),
    secrets_seen: Set([]),
    taking: Turns::new(),
    saying: Turns::new(),
    handler: None,
    accepting_secrets: false,
    fs: o.fs,
    speech: o.speech,
    signer: o.signer,
    uuid: o.uuid,
  }
  base.identify = async fn() { g.let_in() }
  base.address = async fn() { g.server }
  base.run_socket = async fn(url, handler) { g.run_socket(url, handler) }
  base.look_up = async fn(user) { g.look_up(user) }
  base.look_up_email = async fn(_) { None }
  base.status_line = thread => g.live_line(thread)
  g
}

///|
fn GroupSurface::now(self : GroupSurface) -> Double {
  (self.base.clock.now)()
}

///|
/// This device's endpoint id: what the anchor knows the connect's key by.
pub async fn GroupSurface::device(self : GroupSurface) -> String {
  self.link.device()
}

///|
fn GroupSurface::bot_user_id(self : GroupSurface) -> String {
  self.base.bot_user_id()
}

///|
fn GroupSurface::bot_name(self : GroupSurface) -> String {
  self.base.bot_name()
}

///|
/// Let in: dialled anew (a code said only until it joined), its name set where it was asked for another.
async fn GroupSurface::let_in(self : GroupSurface) -> J {
  let hello = match (self.joined, self.code) {
    (false, Some(code)) => jo([("credential", js(code))] + (match self.wanted { Some(w) => [("name", js(w))]; None => [] }))
    _ => jo([("credential", js(""))])
  }
  let me = self.link.connect(hello)
  self.joined = true
  if me.joined {
    self.base.log.info("group", "joined the community", jo([("connect", js(self.connect)), ("member", js(me.member_id))]))
  }
  let mut name = me.name
  match self.wanted {
    Some(w) if w != me.name => {
      let renamed = try Some(self.link.ask("POST", "/me/name", body=JsonAsked(jo([("name", js(w))])))) catch { _ => None }
      match renamed {
        Some(r) if r.status == 200 => name = w
        _ =>
          self.base.log.warn("group", "the bot's name not set on the anchor", jo([("connect", js(self.connect)), ("status", match renamed { Some(r) => ji(r.status); None => Null })]))
      }
    }
    _ => ()
  }
  jo([("team", js("")), ("teamId", js(self.server)), ("url", js("")), ("botUserId", js(me.member_id)), ("botName", js(name)), ("botImage", Null), ("botId", js(""))])
}

///|
/// "@name", as people there write it.
pub fn GroupSurface::mention(self : GroupSurface, user : String) -> String {
  let name = match self.members.get(user) {
    Some(n) => n
    None =>
      match at(self.base.names.get(user), "name") {
        Some(Null) | None => user
        Some(v) => js_text(Some(v))
      }
  }
  "@\{name}"
}

///|
pub async fn GroupSurface::stop(self : GroupSurface) -> Unit {
  self.base.stop()
  self.link.close()
}

///|
/// `f` after what is being taken, in turn.
async fn[X] GroupSurface::in_turn(self : GroupSurface, f : async () -> X) -> X {
  self.taking.run(f)
}

///|
/// One run of its link: let in again where it went, the anchor's stream opened, what each space took meanwhile
/// synced, then each event taken in order, the control stream pinged meanwhile. Ends as the stream does; fails (so its
/// backoff counts) where it could not be opened, or the link stopped answering.
async fn GroupSurface::run_socket(self : GroupSurface, _url : String, handler : async (J) -> Unit) -> Unit {
  self.handler = Some(handler)
  self.accept_secrets()
  let over = Ref(false)
  let cancel : Ref[() -> Unit] = Ref(() => ())
  let done : @effect.Deferred[Unit] = @effect.Deferred::new()
  // (the run goes on by itself, as a promise does: let go of, it ends as its stream is cut)
  spawn(async fn() {
    try {
      self.run_body(handler, over, cancel)
      ignore(done.succeed(()))
    } catch {
      e => ignore(done.fail(e))
    }
  })
  let run = async fn() -> Unit {
    done.wait() catch {
      e => {
        if @effect.is_interrupted() {
          over.val = true
          (cancel.val)()
        }
        raise e
      }
    }
  }
  // timer: a heartbeat of the link (its ping on the control stream)
  let watch = async fn() -> Unit {
    while true {
      (self.base.clock.sleep)(self.link_ping_ms)
      let answered = @effect.race_first(
        async fn() -> Bool {
          self.link.ping()
          true
        },
        async fn() -> Bool {
          (self.base.clock.sleep)(self.link_stale_ms)
          false
        },
      )
      if !answered {
        raise group_unreached("the server did not answer for \{@session_chats.num_text(self.link_stale_ms / 1000.0)}s")
      }
    }
  }
  defer self.link.drop("its run ended")
  @effect.race_first(run, watch)
}

///|
async fn GroupSurface::run_body(self : GroupSurface, handler : async (J) -> Unit, over : Ref[Bool], cancel : Ref[() -> Unit]) -> Unit {
  let base = self.base
  if !self.link.open() {
    let me = self.let_in()
    if str_of(at(Some(me), "botUserId")) != str_of(at(Some(base.me), "botUserId")) ||
      str_of(at(Some(me), "botName")) != str_of(at(Some(base.me), "botName")) {
      base.me = me
      base.changed()
    }
  }
  let reply = self.link.stream("GET", "/events")
  cancel.val = reply.cancel
  if over.val {
    return (reply.cancel)()
  }
  if reply.status != 200 {
    (reply.cancel)()
    raise group_unreached("the event stream was answered \{reply.status}")
  }
  self.read_members() catch {
    e => base.log.warn("group", "members not read", jo([("connect", js(self.connect)), ("error", js(thrown_message(e)))]))
  }
  // (the stream follows from its answer on: what it tells after is what this sync did not have)
  self.in_turn(async fn() {
    self.provisional.clear()
    self.sync(handler, first=true)
  })
  base.set_status(true, None)
  let sse = SseLines::new()
  while (reply.next)() is Some(chunk) {
    (self.heard_hook)()
    for e in sse.feed(chunk) {
      let (event, data, _) = e
      if event != "" {
        self.in_turn(async fn() { self.take(event, data, handler) })
      }
    }
  }
  // (ended: dialled again at once, as a socket the platform closed is; the link down fails that, on the backoff)
  base.set_status(false, None)
}

///|
fn body_json(body : Bytes) -> J raise {
  parse_js(text_of(body))
}

///|
async fn GroupSurface::read_members(self : GroupSurface) -> Unit {
  let answer = self.link.ask("GET", "/members")
  if answer.status != 200 {
    return
  }
  for m in arr_of(at(Some(body_json(answer.body)), "members")).unwrap_or([]) {
    self.heard_member(m)
  }
}

///|
fn GroupSurface::heard_member(self : GroupSurface, m : J) -> Unit {
  guard str_of(at(Some(m), "id")) is Some(id) && str_of(at(Some(m), "name")) is Some(name) else { return }
  let known = self.members.get(id)
  self.members[id] = name
  self.base.names[id] = jo([("name", js(name)), ("email", js(""))])
  match (known, self.base.book) {
    (Some(k), Some(book)) if k != name =>
      ignore(book.person(person_key(self.connect, id), async fn() { Some(jo([("name", js(name)), ("email", js(""))])) }, stale=(had, _) => !(str_of(at(Some(had), "name")) == Some(name))))
    _ => ()
  }
}

///|
/// A space as the anchor says it is now (its row: `space_json`).
fn GroupSurface::heard_space(self : GroupSurface, j : J) -> Space? {
  guard str_of(at(Some(j), "id")) is Some(id) else { return None }
  let s : Space = {
    id,
    kind: if str_of(at(Some(j), "kind")) == Some("direct") { "direct" } else { "space" },
    name: text_j(at(Some(j), "name")),
    members: arr_of(at(Some(j), "members")).unwrap_or([]).filter(m => m is Str(_)),
  }
  self.space_rows[id] = s
  if s.kind == "space" && s.name != "" {
    match self.base.book {
      Some(book) => ignore(book.channel(channel_key(self.connect, id), async fn() { js(s.name) }))
      None => ()
    }
  }
  Some(s)
}

///|
/// Where a space's events were taken to (0: none).
fn GroupSurface::cursor(self : GroupSurface, space : String) -> Double {
  match self.cursors.get(space) {
    Some(c) => c
    None =>
      match self.threads.space(self.connect, space) {
        Some(k) => k.aseq
        None => 0.0
      }
  }
}

///|
/// A space first heard of: what it had then (`floor`) taken as history.
fn GroupSurface::first_heard(self : GroupSurface, s : Space, j : J, provisional : Bool) -> Unit {
  let floor = num_of(at(Some(j), "last_aseq")).unwrap_or(0.0)
  self.floors[s.id] = floor
  if provisional {
    self.provisional.add(s.id)
  }
  self.whole.add(s.id)
  self.cursors[s.id] = 0.0
  self.threads.took(self.connect, s.id, floor)
}

///|
/// What each space took after what was taken of it, taken in, in order; spaces left let go of. A space first heard of
/// has what it had then taken as history (`first`: as a run begins, where the stream may tell some of it again).
async fn GroupSurface::sync(self : GroupSurface, handler : async (J) -> Unit, first? : Bool = false) -> Unit {
  while true {
    let ids : Array[String] = []
    for e in self.threads.spaces(self.connect) {
      if !ids.contains(e.0) {
        ids.push(e.0)
      }
    }
    for id in self.cursors.keys() {
      if !ids.contains(id) {
        ids.push(id)
      }
    }
    let since = from_entries(ids.map(id => (id, jn(self.cursor(id)))))
    let answer = self.link.ask("POST", "/sync", body=JsonAsked(jo([("since", since)])))
    if answer.status != 200 {
      raise group_unreached("the anchor did not answer what this device lacks (\{answer.status})")
    }
    let said = body_json(answer.body)
    for id in arr_of(at(Some(said), "left")).unwrap_or([]) {
      match str_of(Some(id)) {
        Some(i) => self.left(i)
        None => ()
      }
    }
    for j in arr_of(at(Some(said), "spaces")).unwrap_or([]) {
      guard self.heard_space(j) is Some(s) else { continue }
      if self.threads.space(self.connect, s.id) is Some(_) || self.floors.contains(s.id) {
        continue
      }
      self.first_heard(s, j, first)
    }
    match at(Some(said), "dseq") {
      Some(Obj(_) | Arr(_)) as d =>
        for e in entries_of(d) {
          match e.1 {
            Num(n) => self.threads.said(self.connect, e.0, n, "")
            _ => ()
          }
        }
      _ => ()
    }
    for j in arr_of(at(Some(said), "events")).unwrap_or([]) {
      self.heard(j, handler)
    }
    if !(at(Some(said), "more") is Some(Bool(true))) {
      return
    }
  }
}

///|
/// A space this member is in no more.
fn GroupSurface::left(self : GroupSurface, space : String) -> Unit {
  self.space_rows.remove(space)
  self.cursors.remove(space)
  self.floors.remove(space)
  self.provisional.remove(space)
  self.whole.remove(space)
  for k in self.tails.keys().to_array() {
    if k != space && !k.has_prefix("\{space}/") {
      continue
    }
    for m in self.tails.get(k).unwrap_or([]) {
      self.by_id.remove(m.id)
      self.by_aseq.remove("\{space}#\{@session_chats.num_text(m.aseq)}")
    }
    self.tails.remove(k)
    self.cut.remove(k)
  }
  for k in self.topics.keys().to_array() {
    if k.has_prefix("\{space}/") {
      self.topics.remove(k)
    }
  }
  self.threads.forget(self.connect, space)
}

///|
/// One event of the stream.
pub async fn GroupSurface::take(self : GroupSurface, event : String, data : String, handler : async (J) -> Unit) -> Unit {
  let told = try parse_js(data) catch { _ => return }
  let t = Some(told)
  match event {
    "event" => self.heard(at(t, "stamped").unwrap_or(Null), handler, streamed=true)
    "space" =>
      match self.heard_space(told) {
        // (a space it is put in while it listens: what it had then is history, what comes after is not)
        Some(s) if self.threads.space(self.connect, s.id) is None && !self.floors.contains(s.id) => {
          self.first_heard(s, told, false)
          self.sync(handler)
        }
        _ => ()
      }
    "left" =>
      match str_of(at(t, "space")) {
        Some(space) => self.left(space)
        None => ()
      }
    "member" => self.heard_member(told)
    "stop" => self.stop_pressed(told, handler)
    "secret" => self.secret_heard(told, handler)
    _ => ()
  }
}

///|
/// A stamped event, taken once in its space's order: folded into what the station keeps of the space, handed to the
/// hub where it is a person's word to it. One after a gap is what the next sync brings, with those before it.
async fn GroupSurface::heard(self : GroupSurface, j : J, handler : async (J) -> Unit, streamed? : Bool = false) -> Unit {
  let aseq = num_of(at(Some(j), "aseq")).unwrap_or(0.0)
  let space = str_of(at(at(Some(j), "event"), "space")).unwrap_or("")
  if aseq < 1.0 || space == "" {
    return
  }
  let cursor = self.cursor(space)
  if aseq <= cursor {
    // (taken as history in the sync a run began with, though the stream says it was taken after it opened)
    match self.floors.get(space) {
      Some(floor) if streamed && self.provisional.contains(space) && aseq <= floor =>
        match stamped_of(self.signer, Some(j)) {
          Some(s) => self.to_hub(s, handler)
          None => ()
        }
      _ => ()
    }
    return
  }
  if aseq > cursor + 1.0 {
    if streamed {
      self.sync(handler)
    }
    return
  }
  let s = stamped_of(self.signer, Some(j))
  self.cursors[space] = aseq
  guard s is Some(s) else {
    self.base.log.warn("group", "an event not signed by its device: not taken", jo([("connect", js(self.connect)), ("space", js(space)), ("aseq", jn(aseq))]))
    self.threads.took(self.connect, space, aseq)
    return
  }
  self.hlc.saw(s.event.hlc.0, s.event.hlc.1)
  let said = self.fold(s)
  let floor = self.floors.get(space).unwrap_or(0.0)
  if aseq > floor {
    self.to_hub(s, handler)
  }
  self.threads.took(self.connect, space, aseq, stream=if said { Some(stream_key(space, s.event.topic)) } else { None })
}

///|
/// The members of a space as a set of what each is (`new Set([...])`): each once, in order.
fn members_once(xs : Array[J]) -> Array[J] {
  let out : Array[J] = []
  for x in xs {
    if !out.iter().any(y => @session_chats.jeq(x, y)) {
      out.push(x)
    }
  }
  out
}

///|
fn aseq_key(space : String, aseq : Double) -> String {
  "\{space}#\{@session_chats.num_text(aseq)}"
}

///|
/// What an event changes of what the station keeps of its space; whether it is a message.
fn GroupSurface::fold(self : GroupSurface, s : Stamped) -> Bool {
  let e = s.event
  let b = match e.body {
    Null => Some(jo([]))
    body => Some(body)
  }
  if e.device == self.device_id {
    self.threads.said(self.connect, e.space, e.dseq, s.id)
  }
  match e.kind {
    "space.create" => {
      if !self.space_rows.contains(e.space) {
        self.space_rows[e.space] = {
          id: e.space,
          kind: if e.space.has_prefix("d_") { "direct" } else { "space" },
          name: text_j(at(b, "name")),
          members: arr_of(at(b, "members")).unwrap_or([]),
        }
      }
      false
    }
    "space.members" => {
      guard self.space_rows.get(e.space) is Some(had) else { return false }
      let gone = [..arr_of(at(b, "remove")).unwrap_or([]), ..(if at(b, "leave") is Some(Bool(true)) { [js(e.author)] } else { [] })]
      let members = members_once([..had.members, ..arr_of(at(b, "add")).unwrap_or([])]).filter(m => !gone.iter().any(g => @session_chats.jeq(g, m)))
      self.space_rows[e.space] = { ..had, members, name: str_of(at(b, "name")).unwrap_or(had.name) }
      false
    }
    "topic.open" => {
      match str_of(at(b, "topic")) {
        Some(topic) => self.topics["\{e.space}/\{topic}"] = { title: text_j(at(b, "title")), by: e.author, branched_from: text_j(at(b, "branched_from")) }
        None => ()
      }
      false
    }
    "topic.patch" => {
      match (self.topics.get("\{e.space}/\{text_j(at(b, "topic"))}"), str_of(at(b, "title"))) {
        (Some(had), Some(title)) => had.title = title
        _ => ()
      }
      false
    }
    "msg.post" | "decision.ask" => {
      let m : Said = {
        id: s.id,
        space: e.space,
        topic: e.topic,
        aseq: s.aseq,
        kind: e.kind,
        author: e.author,
        text: text_j(at(b, "text")),
        files: files_of(at(b, "files")),
        reply_to: text_j(at(b, "reply_to")),
        deleted: false,
      }
      let key = stream_key(e.space, e.topic)
      let tail = self.tails.get(key).unwrap_or([])
      tail.push(m)
      while tail.length() > tail_most {
        let gone = tail.remove(0)
        self.by_id.remove(gone.id)
        self.by_aseq.remove(aseq_key(gone.space, gone.aseq))
        self.cut.add(key)
      }
      self.tails[key] = tail
      self.by_id[m.id] = m
      self.by_aseq[aseq_key(e.space, s.aseq)] = m
      true
    }
    "msg.edit" => {
      match self.by_id.get(text_j(at(b, "target"))) {
        Some(m) if m.author == e.author && !m.deleted => m.text = text_j(at(b, "text"))
        _ => ()
      }
      false
    }
    "msg.unsend" => {
      match self.by_id.get(text_j(at(b, "target"))) {
        Some(m) if m.author == e.author => {
          m.deleted = true
          m.text = ""
          m.files = []
        }
        _ => ()
      }
      false
    }
    _ => false
  }
}

///|
/// Whether a topic is about the bot: its title mentions it, or it was branched from the bot's message or one that
/// mentions it.
fn GroupSurface::topic_about_bot(self : GroupSurface, space : String, topic : String) -> Bool {
  if topic == lobby {
    return false
  }
  guard self.topics.get("\{space}/\{topic}") is Some(t) else { return false }
  if mentions(t.title, self.bot_name()) {
    return true
  }
  match (if t.branched_from == "" { None } else { self.by_id.get(t.branched_from) }) {
    Some(from) => from.author == self.bot_user_id() || mentions(from.text, self.bot_name())
    None => false
  }
}

///|
/// An event handed to the hub where it is a person's word to the agent: a message (a decision a person asked too), an
/// edit of one, an answer to one of the bot's decisions.
async fn GroupSurface::to_hub(self : GroupSurface, s : Stamped, handler : async (J) -> Unit) -> Unit {
  let e = s.event
  let b = match e.body {
    Null => Some(jo([]))
    body => Some(body)
  }
  if e.author == self.bot_user_id() {
    return
  }
  let thread = thread_of(e.space, e.topic)
  let channel = at(Some(thread), "channel").unwrap()
  let thread_ts = at(Some(thread), "threadTs").unwrap()
  let stream = stream_key(e.space, e.topic)
  let ts = @session_chats.num_text(s.aseq)
  match e.kind {
    "msg.post" | "decision.ask" => {
      let m = self.by_aseq.get(aseq_key(e.space, s.aseq))
      let words = text_j(at(b, "text"))
      let space = self.space_rows.get(e.space)
      let replied = match m {
        Some(m) if m.reply_to != "" => self.by_id.get(m.reply_to)
        _ => None
      }
      let first_of_topic = e.topic != lobby && self.tails.get(stream).map(t => t.length()).unwrap_or(0) <= 1 && !self.cut.contains(stream)
      let addressed = (space is Some(sp) && sp.kind == "direct") ||
        mentions(words, self.bot_name()) ||
        (replied is Some(r) && r.author == self.bot_user_id()) ||
        (first_of_topic && self.topic_about_bot(e.space, e.topic))
      let files = files_of(at(b, "files")).map(f => {
        let sha = js_text(at(Some(f), "sha256"))
        let name = match text_j(at(Some(f), "name")) {
          "" => sha
          n => n
        }
        jo([("id", js(sha)), ("name", js(name)), ("size", at(Some(f), "size").unwrap_or(jn(0.0))), ("url", js("\{e.space}/\{sha}"))])
      })
      // (what it answers, or where its topic was branched from: the message its reader is shown first)
      let origin = if first_of_topic && replied is None {
        self.topics.get("\{e.space}/\{e.topic}").map(t => t.branched_from)
      } else {
        None
      }
      let quoted = match replied {
        Some(r) => Some(r)
        None =>
          match origin {
            Some(o) if o != "" => self.by_id.get(o)
            _ => None
          }
      }
      let message = [
        ("channel", channel),
        ("threadTs", thread_ts),
        ("ts", js(ts)),
        ("user", js(e.author)),
        ("text", js(self.answered(stream, words))),
        ("addressed", jb(addressed)),
      ]
      if files.length() > 0 {
        message.push(("files", ja(files)))
      }
      match quoted {
        Some(q) => message.push(("quoted", js(@session_chats.num_text(q.aseq))))
        None => ()
      }
      handler(jo([("type", js("message")), ("message", jo(message))]))
    }
    "msg.edit" =>
      match self.by_id.get(text_j(at(b, "target"))) {
        Some(m) if m.author == e.author && !m.deleted =>
          handler(jo([("type", js("changed")), ("channel", channel), ("threadTs", thread_ts), ("ts", js(@session_chats.num_text(m.aseq))), ("text", js(text_j(at(b, "text"))))]))
        _ => ()
      }
    "decision.resolve" => {
      let target = text_j(at(b, "target"))
      let asked = self.asks.get(target)
      let known = self.by_id.get(target)
      // (someone else's decision, or one of its own a person's message or the station closed: no word to the agent)
      if self.closed.contains(target) || (asked is None && known is Some(k) && k.author != self.bot_user_id()) {
        return
      }
      self.asks.remove(target)
      match asked {
        Some((stream, _)) =>
          match self.asked.get(stream) {
            Some((_, id, _)) if id == target => self.asked.remove(stream)
            _ => ()
          }
        None => ()
      }
      // (one asked before the station started again, whose ask it no longer has: to a session that follows the stream)
      let addressed = asked is Some(_) || known is Some(_) || (self.space_rows.get(e.space) is Some(sp) && sp.kind == "direct")
      handler(
        jo([
          ("type", js("message")),
          (
            "message",
            jo([("channel", channel), ("threadTs", thread_ts), ("ts", js(ts)), ("user", js(e.author)), ("text", js(text_j(at(b, "choice")))), ("addressed", jb(addressed))]),
          ),
        ]),
      )
    }
    _ => ()
  }
}

///|
/// A person's message where a card waits: it closes the card (a person's next message does, a decision or not), and
/// one that is an option's number is that option's words.
fn GroupSurface::answered(self : GroupSurface, stream : String, words : String) -> String {
  guard self.asked.get(stream) is Some((_, id, options)) else { return words }
  self.asked.remove(stream)
  self.close(id)
  // (`/^\s*(\d{1,2})\s*$/`)
  let t = @session_chats.trim(words)
  if t.length() < 1 || t.length() > 2 || !t.iter().all(c => c >= '0' && c <= '9') {
    return words
  }
  let i = digits_of(t).unwrap_or(0) - 1
  if i >= 0 && i < options.length() {
    options[i]
  } else {
    words
  }
}

///|
/// A card that stopped waiting on the station (withdrawn, replaced, closed): a number said after it is a number, an
/// answer to it no word to the agent. Only the card it was (by its ts): one posted since stays.
pub fn GroupSurface::card_ended(self : GroupSurface, thread : J, ts : String) -> Unit {
  let (space, topic) = stream_of(thread)
  let stream = stream_key(space, topic)
  match self.asked.get(stream) {
    Some((t, id, _)) if t == ts => {
      self.asked.remove(stream)
      self.close(id)
    }
    _ => ()
  }
}

///|
/// One of its decisions closed other than by its answer.
fn GroupSurface::close(self : GroupSurface, id : String) -> Unit {
  self.asks.remove(id)
  self.closed.add(id)
  if self.closed.length() > closed_kept {
    match self.closed.iter().head() {
      Some(first) => self.closed.remove(first)
      None => ()
    }
  }
}

///|
/// Stop pressed on a stream's live state: the turn working for it is stopped (where it is this bot's, or anyone's).
async fn GroupSurface::stop_pressed(self : GroupSurface, told : J, handler : async (J) -> Unit) -> Unit {
  let t = Some(told)
  let space = text_j(at(t, "space"))
  if !self.space_rows.contains(space) {
    return
  }
  let target = text_j(at(t, "target"))
  if target != "" && target != self.bot_user_id() {
    return
  }
  let thread = thread_of(space, match text_j(at(t, "topic")) { "" => lobby; x => x })
  let ts = match text_j(at(t, "message_ts")) {
    "" =>
      match at(t, "at") {
        Some(Num(a)) => @session_chats.num_text(a)
        _ => @session_chats.num_text(self.now())
      }
    x => x
  }
  // (pressed on what is shown now: never too early for the turn that shows it)
  handler(
    jo([
      ("type", js("stop")),
      ("channel", at(Some(thread), "channel").unwrap()),
      ("threadTs", at(Some(thread), "threadTs").unwrap()),
      ("ts", js(ts)),
      ("localAt", Null),
    ]),
  )
}

// ── secrets ──

///|
/// The connections other members' devices hand it a secret by, served as they come while the surface runs.
fn GroupSurface::accept_secrets(self : GroupSurface) -> Unit {
  if self.accepting_secrets {
    return
  }
  self.accepting_secrets = true
  self.base.run(async fn() {
    while true {
      guard self.link.accepted() is Some(conn) else { return }
      self.base.run(async fn() {
        defer (conn.close)(0, "secret taken")
        self.secret_dialled(conn) catch {
          e => {
            if @effect.is_interrupted() {
              raise e
            }
            self.base.log.info("group", "a secret's connection ended", jo([("connect", js(self.connect)), ("error", js("Error: \{thrown_message(e)}"))]))
          }
        }
      })
    }
  })
}

///|
/// One secret on its own connection (`im-secret/1`): taken where its device is a device of the member it says it is
/// from, in the space it names, and answered.
async fn GroupSurface::secret_dialled(self : GroupSurface, conn : MeshConn) -> Unit {
  guard (conn.accept_bi)() is Some(stream) else { return }
  let said = LineReader::new(stream).line() catch { _ => None }
  let space = text_j(at(said, "space"))
  let from = text_j(at(said, "from"))
  let mut ok = false
  if self.space_rows.contains(space) && from != "" && self.link.open() {
    let answer = try Some(
      self.link.ask("GET", "/spaces/\{@session_chats.encode_uri_component(space)}/devices?member=\{@session_chats.encode_uri_component(from)}"),
    ) catch {
      _ => None
    }
    let devices = match answer {
      Some(a) if a.status == 200 => at(Some(body_json(a.body)), "devices")
      _ => Some(ja([]))
    }
    ok = match devices {
      Some(Arr(ds)) => ds.iter().any(d => str_of(Some(d)) == Some((conn.remote_id)()))
      _ => false
    }
  }
  // (answered at once: the device that dialled waits a while, then hands it through the anchor instead)
  write_line(stream, if ok { jo([("ok", jb(true))]) } else { jo([("ok", jb(false)), ("error", js("not a device of that member in that space"))]) })
  (stream.finish)() catch { _ => () }
  match (ok, self.handler, said) {
    (true, Some(handler), Some(told)) => self.in_turn(async fn() { self.secret_heard(told, handler) })
    _ => ()
  }
  (stream.stopped)() catch { _ => () }
}

///|
/// A secret handed to the bot: the session told of it by its label, its value a file of its uploads (fetched once, of
/// memory alone: `download`), never in a message's words. A card waiting there is closed by it, as by any message.
async fn GroupSurface::secret_heard(self : GroupSurface, told : J, handler : async (J) -> Unit) -> Unit {
  let t = Some(told)
  let id = text_j(at(t, "id"))
  let space = text_j(at(t, "space"))
  let from = text_j(at(t, "from"))
  let value = str_of(at(t, "value"))
  guard value is Some(value) else { return }
  if id == "" || from == "" || from == self.bot_user_id() || !self.space_rows.contains(space) || self.secrets_seen.contains(id) {
    return
  }
  self.secrets_seen.add(id)
  if self.secrets_seen.length() > secrets_seen_most {
    match self.secrets_seen.iter().head() {
      Some(first) => self.secrets_seen.remove(first)
      None => ()
    }
  }
  let label = match @session_chats.slice(text_j(at(t, "label")), 0, b=80) {
    "" => "secret"
    l => l
  }
  let topic = match text_j(at(t, "topic")) {
    "" => lobby
    x => x
  }
  let thread = thread_of(space, topic)
  let file = "secret-\{id}"
  self.secrets[file] = utf8(value)
  ignore(self.answered(stream_key(space, topic), ""))
  // (between the space's events, its own: a place no event of the space has)
  let ts = "\{@session_chats.num_text(self.cursor(space))}.\{pad10(hex_prefix(@session_chats.slice(id, 0, b=8)))}"
  let name = self.members.get(from).unwrap_or(from)
  let safe = label
    .iter()
    .map(c => if (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_' || c == '.' || c == '-' { c.to_string() } else { "_" })
    .fold(init="", (a, x) => a + x)
  handler(
    jo([
      ("type", js("message")),
      (
        "message",
        jo([
          ("channel", at(Some(thread), "channel").unwrap()),
          ("threadTs", at(Some(thread), "threadTs").unwrap()),
          ("ts", js(ts)),
          ("user", js(from)),
          ("text", js(self.speech.tr(self.speech.station_lang(), "station.group.secretReceived", args=[("label", label), ("name", name)]))),
          ("addressed", jb(true)),
          ("files", ja([jo([("id", js(file)), ("name", js("\{safe}.secret")), ("size", ji(utf8(value).length())), ("url", js("secret:\{file}"))])])),
        ]),
      ),
    ]),
  )
}

///|
/// `Number.parseInt(s, 16) || 1`, as a number's digits: the leading hex digits of `s`, 1 where there are none or they
/// make 0.
fn hex_prefix(s : String) -> String {
  let mut n = 0.0
  let mut any = false
  for c in s {
    let d = match c {
      '0'..='9' => c.to_int() - '0'.to_int()
      'a'..='f' => c.to_int() - 'a'.to_int() + 10
      'A'..='F' => c.to_int() - 'A'.to_int() + 10
      _ => break
    }
    n = n * 16.0 + d.to_double()
    any = true
  }
  if !any || n == 0.0 {
    "1"
  } else {
    @session_chats.num_text(n)
  }
}

///|
fn pad10(s : String) -> String {
  let mut out = s
  while out.length() < 10 {
    out = "0" + out
  }
  out
}

// ── saying ──

///|
/// What the anchor gave an event this device said (its id, place and number), or why it refused it.
priv enum SaidBack {
  Took(String, Double, Double)
  RefusedAs(String)
}

///|
/// An event this device says in a stream: signed after its last there, taken by the anchor.
async fn GroupSurface::say(self : GroupSurface, space : String, topic : String, kind : String, body : J) -> SaidBack {
  self.saying.run(async fn() {
    let mut again = 0
    while true {
      let kept = self.threads.space(self.connect, space).unwrap_or({ aseq: 0.0, dseq: 0.0, prev: "" })
      let unsigned : GroupEvent = {
        space,
        author: self.bot_user_id(),
        device: self.device_id,
        dseq: kept.dseq + 1.0,
        hlc: self.hlc.next(self.now()),
        prev: kept.prev,
        topic,
        kind,
        body,
        sig: "",
      }
      let e = sign_event(self.signer, self.key, unsigned)
      let id = event_id(e)
      self.threads.said(self.connect, space, e.dseq, id)
      let answer = self.link.ask("POST", "/events", body=JsonAsked(jo([("events", ja([e.to_j()]))])))
      if answer.status != 200 {
        raise fail_("the anchor did not take the message (\{answer.status}: \{@session_chats.slice(text_of(answer.body), 0, b=200)})")
      }
      let r = at_i(at(Some(body_json(answer.body)), "results"), 0)
      match at(r, "aseq") {
        Some(Num(aseq)) => return Took(id, aseq, num_of(at(r, "n")).unwrap_or(0.0))
        _ => ()
      }
      let why = str_of(at(r, "why")).unwrap_or("refused")
      // (this device's count behind the anchor's, as a station's kept state went back: said again after it)
      match self.handler {
        Some(handler) if why == "dseq" && again == 0 => {
          again += 1
          self.in_turn(async fn() { self.sync(handler) })
          continue
        }
        _ => ()
      }
      return RefusedAs(why)
    }
    RefusedAs("refused")
  })
}

///|
fn at_i(v : J?, i : Int) -> J? {
  @session_chats.at_i(v, i)
}

///|
/// A file put into a space: whole in one ask where it is one piece at most, else a piece at a time (`piece_most`), from
/// what the anchor has of it already on (`GET /spaces/<id>/uploads/<sha256>`); nothing of it held but a piece.
async fn GroupSurface::upload(self : GroupSurface, space : String, file : J) -> J {
  let path = js_text(at(Some(file), "path"))
  let name = js_text(at(Some(file), "name"))
  let size = (self.fs.size)(path)
  if size > file_most {
    raise fail_("\{name} is \{@session_chats.num_text(size)} bytes, more than the anchor takes (\{@session_chats.num_text(file_most)})")
  }
  let read = async fn(at : Double, n : Double) -> Bytes {
    let got = (self.fs.read_part)(path, at, n)
    if got.length().to_double() != n {
      raise fail_("\{name} changed as it was read")
    }
    got
  }
  let shape = image_size(read(0.0, if size < head_most { size } else { head_most }))
  let files = "/spaces/\{@session_chats.encode_uri_component(space)}/files?name=\{@session_chats.encode_uri_component(name)}&mime=\{@session_chats.encode_uri_component(mime_of(name))}"
  let sides = match shape {
    None => ""
    Some((w, h)) => "&width=\{@session_chats.num_text(w)}&height=\{@session_chats.num_text(h)}"
  }
  let took = fn(answer : Answered) -> J raise {
    let got = if answer.status == 200 || answer.status == 201 {
      files_of(Some(ja([at(Some(body_json(answer.body)), "file").unwrap_or(Null)]))).get(0)
    } else {
      None
    }
    guard got is Some(got) else {
      raise fail_("the anchor did not take \{name} (\{answer.status}: \{@session_chats.slice(text_of(answer.body), 0, b=200)})")
    }
    got
  }
  if size <= piece_most {
    return took(self.link.ask("POST", files + sides, body=BytesAsked(read(0.0, size))))
  }
  let hash = @hash.Sha256::new()
  for at = 0.0; at < size; at = at + piece_most {
    hash.update(read(at, if size - at < piece_most { size - at } else { piece_most }))
  }
  let sha = hash.hex()
  let asked = self.link.ask("GET", "/spaces/\{@session_chats.encode_uri_component(space)}/uploads/\{sha}")
  if asked.status != 200 {
    // (an anchor from before pieces: what it takes whole, in one ask)
    if size > whole_most {
      raise fail_("\{name} is \{@session_chats.num_text(size)} bytes, more than this anchor takes (\{@session_chats.num_text(whole_most)}): it takes larger files once it is updated")
    }
    return took(self.link.ask("POST", files + sides, body=BytesAsked((self.fs.read_bytes)(path))))
  }
  let mut have = have_of(asked.body)
  let mut stalled = 0
  while true {
    let from = if have < size { have } else { size }
    let n = if size - from < piece_most { size - from } else { piece_most }
    let answer = self.link.ask(
      "POST",
      files + "&sha256=\{sha}&size=\{@session_chats.num_text(size)}&from=\{@session_chats.num_text(from)}" + sides,
      body=BytesAsked(read(from, n)),
    )
    if answer.status != 202 && answer.status != 409 {
      return took(answer)
    }
    let now = have_of(answer.body)
    stalled = if now == have { stalled + 1 } else { 0 }
    if stalled > stalled_most {
      raise fail_("the anchor took none of \{name} after \{@session_chats.num_text(have)} of its \{@session_chats.num_text(size)} bytes")
    }
    have = now
  }
  Null
}

///|
/// The agent's words and its files, as one message where they fit, a card as a decision (its words where the anchor
/// takes none); the first one's ts stands for the whole.
pub async fn GroupSurface::post(self : GroupSurface, thread : J, message : String, files : Array[J], card : J) -> String {
  let (space, topic) = stream_of(thread)
  let stream = stream_key(space, topic)
  let asking = match str_of(at(Some(card), "type")) {
    Some("options") | Some("text") => Some(card)
    _ => None
  }
  if asking is Some(_) {
    match self.asked.get(stream) {
      Some((_, id, _)) => self.close(id)
      None => ()
    }
    self.asked.remove(stream)
  }
  let refs : Array[J] = []
  for file in files {
    refs.push(self.upload(space, file))
  }
  let parts = if message == "" { [""] } else { @session_chats.split_for_slack(message, chars_most) }
  let mut at_ = files_most
  while at_ < refs.length() {
    parts.push("")
    at_ += files_most
  }
  let mut first : String? = None
  for i, part in parts {
    let from = @cmp.minimum(i * files_most, refs.length())
    let to = @cmp.minimum((i + 1) * files_most, refs.length())
    let carried = refs[from:to].iter().collect()
    match asking {
      Some(c) if i == 0 => {
        let ts = self.ask(space, topic, stream, part, carried, c)
        if first is None {
          first = Some(ts)
        }
        continue
      }
      _ => ()
    }
    match self.say(space, topic, "msg.post", jo([("text", js(part)), ("files", ja(carried))])) {
      RefusedAs(why) => raise fail_("the anchor did not take the message (\{why})")
      Took(_, aseq, _) => if first is None { first = Some(@session_chats.num_text(aseq)) }
    }
  }
  guard first is Some(first) else { raise fail_("nothing to post") }
  first
}

///|
/// A card asked as a decision, waiting: its ts. Where the anchor takes no such decision, its question and numbered
/// options go as words.
async fn GroupSurface::ask(self : GroupSurface, space : String, topic : String, stream : String, part : String, files : Array[J], card : J) -> String {
  let body = set_field(decision_body(part, card), "files", ja(files))
  match self.say(space, topic, "decision.ask", body) {
    Took(id, aseq, _) => {
      let options = arr_of(at(Some(body), "options")).unwrap_or([]).map(o => js_text(at(Some(o), "label")))
      let ts = @session_chats.num_text(aseq)
      self.asks[id] = (stream, ts)
      self.asked[stream] = (ts, id, options)
      ts
    }
    RefusedAs(why) => {
      // (an anchor from before decisions, or one that takes none of these: its words, answered by number)
      self.base.log.info("group", "a card asked as words", jo([("connect", js(self.connect)), ("why", js(why))]))
      let (words, options) = card_words(self.speech, part, card, self.speech.station_lang())
      match self.say(space, topic, "msg.post", jo([("text", js(words)), ("files", ja(files))])) {
        RefusedAs(why) => raise fail_("the anchor did not take the message (\{why})")
        Took(id, aseq, _) => {
          let ts = @session_chats.num_text(aseq)
          if options.length() > 0 {
            self.asked[stream] = (ts, id, options)
          }
          ts
        }
      }
    }
  }
}

///|
/// What the agent does in a stream, said as its live state ("": done).
async fn GroupSurface::live(self : GroupSurface, thread : J, status : String, message_ts : String?) -> Bool {
  let (space, topic) = stream_of(thread)
  if !self.link.open() {
    return false
  }
  let chars = status.to_array()
  let said = chars[0:@cmp.minimum(live_most, chars.length())].iter().fold(init="", (a, c) => a + c.to_string())
  let fields = [
    ("topic", js(topic)),
    ("state", js(if status == "" { "done" } else { "working" })),
    ("text", js(said)),
    ("stoppable", jb(status != "")),
  ]
  match message_ts {
    Some(ts) => fields.push(("message_ts", js(ts)))
    None => ()
  }
  let answer = try Some(self.link.ask("POST", "/spaces/\{@session_chats.encode_uri_component(space)}/live", body=JsonAsked(jo(fields)))) catch {
    _ => None
  }
  // (an anchor with no live state answers 404: nothing to show it again)
  match answer {
    Some(a) => a.status != 503
    None => false
  }
}

///|
/// What the agent does, as the stream's live state: said to the anchor as it changes (and again while it stands, so
/// the anchor keeps it), taken back ("done") as the turn ends.
fn GroupSurface::live_line(self : GroupSurface, thread : J) -> StatusLine {
  let standing = Ref("")
  let again = Ref(false)
  StatusLine::new(f => self.base.run(f), self.base.clock, live_interval_ms, async fn(line, status, _) {
    let shown = self.live(thread, status, line.message_ts)
    if shown {
      standing.val = status
    }
    if shown && status != "" && !again.val {
      again.val = true
      // timer: a heartbeat that keeps the anchor's live state (its 90 s)
      self.base.run(async fn() {
        while true {
          (self.base.clock.sleep)(live_again_ms)
          if standing.val == "" {
            again.val = false
            return
          }
          ignore(self.live(thread, standing.val, line.message_ts))
        }
      })
    }
    shown
  })
}

///|
pub async fn GroupSurface::download(self : GroupSurface, file : J) -> Bytes {
  let url = str_of(at(Some(file), "url"))
  match url {
    Some(u) if u.has_prefix("secret:") => {
      let id = @session_chats.slice(u, 7)
      let value = self.secrets.get(id)
      self.secrets.remove(id)
      guard value is Some(v) else { raise fail_("the secret was fetched already") }
      return v
    }
    _ => ()
  }
  let at_ = match url {
    Some(u) => @session_chats.index_of(u, "/")
    None => -1
  }
  guard url is Some(u) && at_ >= 0 else { raise fail_("the anchor does not give its contents") }
  let answer = self.link.ask(
    "GET",
    "/spaces/\{@session_chats.encode_uri_component(@session_chats.slice(u, 0, b=at_))}/files/\{@session_chats.encode_uri_component(@session_chats.slice(u, at_ + 1))}",
  )
  if answer.status != 200 {
    raise fail_("the anchor answered \{answer.status} for \{js_text(at(Some(file), "name"))}")
  }
  answer.body
}

///|
fn GroupSurface::message_of(self : GroupSurface, m : Said) -> J {
  let files = m.files.map(f => {
    let sha = js_text(at(Some(f), "sha256"))
    let name = match text_j(at(Some(f), "name")) {
      "" => sha
      n => n
    }
    jo([("id", js(sha)), ("name", js(name)), ("size", at(Some(f), "size").unwrap_or(jn(0.0))), ("url", js("\{m.space}/\{sha}"))])
  })
  let fields = [
    ("ts", js(@session_chats.num_text(m.aseq))),
    ("user", js(m.author)),
    ("text", js(m.text)),
    ("fromBot", jb(m.author == self.bot_user_id())),
  ]
  if files.length() > 0 {
    fields.push(("files", ja(files)))
  }
  jo(fields)
}

///|
/// A space's events after `after`, read of the anchor (500 at most), checked.
async fn GroupSurface::events_after(self : GroupSurface, space : String, after : Double) -> Array[Stamped] {
  let answer = self.link.ask("GET", "/spaces/\{@session_chats.encode_uri_component(space)}/events?after=\{@session_chats.num_text(after)}")
  if answer.status != 200 {
    return []
  }
  arr_of(at(Some(body_json(answer.body)), "events")).unwrap_or([]).filter_map(j => stamped_of(self.signer, Some(j)))
}

///|
fn said_of(s : Stamped, reply_to : String) -> Said {
  let e = s.event
  {
    id: s.id,
    space: e.space,
    topic: e.topic,
    aseq: s.aseq,
    kind: e.kind,
    author: e.author,
    text: text_j(at(Some(e.body), "text")),
    files: files_of(at(Some(e.body), "files")),
    reply_to,
    deleted: false,
  }
}

///|
/// What a stream said before `before` (an event's place), its last `limit`. Of what is kept where the station heard
/// the space from its first event, else read of the anchor.
pub async fn GroupSurface::history(self : GroupSurface, thread : J, before : String, limit : Double) -> Array[J] {
  let (space, topic) = stream_of(thread)
  let key = stream_key(space, topic)
  let n = @session_chats.js_number(js(before)).unwrap_or(@double.not_a_number)
  let b = if !n.is_nan() && !n.is_inf() && n > 0.0 { n.ceil() } else { @double.infinity }
  // (`Math.max(1, Math.min(TAIL_MOST, Math.trunc(limit)))`: NaN where `limit` is, which no count reaches and
  // `slice(-NaN)` takes as all)
  let most : Int? = if limit.is_nan() { None } else { Some(@cmp.maximum(1.0, @cmp.minimum(tail_most.to_double(), limit.trunc())).to_int()) }
  let kept = self.tails.get(key).unwrap_or([]).filter(m => m.aseq < b)
  let reached = (n : Int) => match most {
    Some(m) => n >= m
    None => false
  }
  let said : Array[Said] = if reached(kept.length()) || (self.whole.contains(space) && !self.cut.contains(key)) {
    kept
  } else {
    let said : Array[Said] = []
    let edits : Map[String, Said] = Map([])
    let mut after = 0.0
    let mut page = 0
    while page < history_pages && after + 1.0 < b {
      let got = self.events_after(space, after)
      if got.length() == 0 {
        break
      }
      for s in got {
        after = s.aseq
        if s.aseq >= b {
          break
        }
        let e = s.event
        let target = edits.get(text_j(at(Some(e.body), "target")))
        match target {
          Some(t) if t.author == e.author =>
            if e.kind == "msg.edit" {
              t.text = text_j(at(Some(e.body), "text"))
            } else if e.kind == "msg.unsend" {
              t.deleted = true
            }
          _ => ()
        }
        if (e.kind != "msg.post" && e.kind != "decision.ask") || e.topic != topic {
          continue
        }
        let m = said_of(s, text_j(at(Some(e.body), "reply_to")))
        edits[m.id] = m
        said.push(m)
        if most is Some(m) && said.length() > m {
          ignore(said.remove(0))
        }
      }
      page += 1
    }
    said
  }
  let shown = said.filter(m => !m.deleted)
  let from = match most {
    Some(m) => @cmp.maximum(0, shown.length() - m)
    None => 0
  }
  shown[from:].iter().map(m => self.message_of(m)).collect()
}

///|
/// The message a reply quotes (by its place in its space); None for the bot's own and where it cannot be read.
pub async fn GroupSurface::quoted(self : GroupSurface, thread : J, ts : String) -> J? {
  try {
    let aseq = @session_chats.js_number(js(ts)).unwrap_or(@double.not_a_number)
    if aseq.is_nan() || aseq.floor() != aseq || aseq.abs() > 9007199254740991.0 || aseq < 1.0 {
      return None
    }
    let space = js_text(at(Some(thread), "channel"))
    let m = match self.by_aseq.get(aseq_key(space, aseq)) {
      Some(m) => m
      None => {
        guard self.events_after(space, aseq - 1.0).get(0) is Some(s) else { return None }
        if s.aseq != aseq || (s.event.kind != "msg.post" && s.event.kind != "decision.ask") {
          return None
        }
        said_of(s, "")
      }
    }
    if m.author == self.bot_user_id() || m.deleted {
      return None
    }
    Some(self.message_of(m))
  } catch {
    _ => None
  }
}

///|
/// The spaces (not direct ones) it is in: a chat relayed to one goes on in a topic of its own there (`begin`).
pub fn GroupSurface::places(self : GroupSurface) -> Array[J] {
  self.space_rows
  .values()
  .filter(s => s.kind == "space")
  .map(s => jo([("id", js(s.id)), ("name", js(if s.name == "" { s.id } else { s.name })), ("kind", js("space"))]))
  .collect()
}

///|
pub async fn GroupSurface::people_in(self : GroupSurface, channel : String) -> Array[J] {
  if self.members.length() == 0 {
    self.read_members() catch { _ => () }
  }
  let members = match self.space_rows.get(channel) {
    Some(s) => s.members
    None => []
  }
  members
  .filter(m => !(str_of(Some(m)) == Some(self.bot_user_id())))
  .map(m => {
    let id = js_text(Some(m))
    jo([("id", m), ("name", js(self.members.get(id).unwrap_or(id)))])
  })
}

///|
/// A topic's id drawn (16 hex): the last of a UUID's.
fn GroupSurface::topic_id(self : GroupSurface) -> String {
  let hex = (self.uuid)().replace_all(old="-", new="").to_lower()
  @session_chats.slice(hex, hex.length() - 16)
}

///|
/// A topic of its own opened in the space (`topic.open`, called `title`), begun with `message`: the conversation from
/// now on, `<space>/<topic>`. Where the anchor takes no topic of the station's, the space's lobby.
pub async fn GroupSurface::begin(self : GroupSurface, channel : String, message : String, title : String) -> J {
  let topic = "t_" + self.topic_id()
  let called = topic_title(title)
  match self.say(channel, topic, "topic.open", jo([("topic", js(topic)), ("title", js(if called == "" { "still.fail" } else { called }))])) {
    RefusedAs(why) => {
      self.base.log.warn("group", "a topic not opened for a relayed chat: its space's lobby instead", jo([("connect", js(self.connect)), ("space", js(channel)), ("why", js(why))]))
      let thread = thread_of(channel, lobby)
      let ts = self.post(thread, message, [], Null)
      jo([("thread", thread), ("ts", js(ts))])
    }
    Took(_, _, _) => {
      let thread = thread_of(channel, topic)
      let ts = self.post(thread, message, [], Null)
      jo([("thread", thread), ("ts", js(ts))])
    }
  }
}

///|
async fn GroupSurface::look_up(self : GroupSurface, user : String) -> J? {
  if !self.members.contains(user) {
    self.read_members() catch { _ => () }
  }
  self.members.get(user).map(name => jo([("name", js(name)), ("email", js(""))]))
}

///|
pub fn GroupSurface::known_person(self : GroupSurface, user : String) -> J {
  match self.base.book {
    None => self.base.names.get(user).unwrap_or(Null)
    Some(book) => book.person(person_key(self.connect, user), async fn() { self.look_up(user) }).unwrap_or(Null)
  }
}

///|
/// A space's name; a direct one's the other member's.
pub fn GroupSurface::known_channel(self : GroupSurface, channel : String) -> J {
  match self.base.book {
    None =>
      match self.space_rows.get(channel) {
        Some(s) if s.name != "" => js(s.name)
        _ => Null
      }
    Some(book) =>
      book.channel(channel_key(self.connect, channel), async fn() {
        guard self.space_rows.get(channel) is Some(s) else { return Null }
        if s.kind == "space" {
          return if s.name == "" { Null } else { js(s.name) }
        }
        match s.members.iter().find_first(m => !(str_of(Some(m)) == Some(self.bot_user_id()))) {
          None => Null
          Some(o) =>
            match self.look_up(js_text(Some(o))) {
              Some(p) => nullish_or_null(at(Some(p), "name"))
              None => Null
            }
        }
      })
  }
}

///|
pub fn GroupSurface::channel_name(self : GroupSurface, channel : String) -> J {
  match self.space_rows.get(channel) {
    Some(s) if s.kind == "space" && s.name != "" => js(s.name)
    _ => Null
  }
}

///|
let group_calls : Array[String] = [
  "botUserId", "botName", "identity", "platform", "workspace", "cards", "mention", "sessionLink", "post", "cardEnded", "download",
  "history", "quoted", "places", "peopleIn", "begin", "userName", "userEmail", "userOf", "knownPerson", "knownChannel", "channelName",
  "working", "refreshIdentity",
]

///|
/// The surface the hub uses, and its link to the anchor as the connects keep it.
pub fn GroupSurface::connection(self : GroupSurface) -> Connection {
  let base = self.base
  let s = (args : Array[J], i : Int) => js_text(args.get(i))
  let get = fn(name : String, args : Array[J]) -> J {
    match name {
      "mention" => js(self.mention(s(args, 0)))
      "sessionLink" => Null
      "knownPerson" => self.known_person(s(args, 0))
      "knownChannel" => self.known_channel(s(args, 0))
      _ => base.base_get(name, args).unwrap_or(undefined())
    }
  }
  let surface : Surface = {
    has: name => group_calls.contains(name),
    get,
    call: async fn(name, args) {
      match name {
        "post" => js(self.post(args.get(0).unwrap_or(Null), s(args, 1), arr_of(args.get(2)).unwrap_or([]), nullish_or_null(args.get(3))))
        "cardEnded" => {
          self.card_ended(args.get(0).unwrap_or(Null), s(args, 1))
          undefined()
        }
        "download" => js(hex(self.download(args.get(0).unwrap_or(Null))))
        "history" => ja(self.history(args.get(0).unwrap_or(Null), s(args, 1), num_of(args.get(2)).unwrap_or(@double.not_a_number)))
        "quoted" => self.quoted(args.get(0).unwrap_or(Null), s(args, 1)).unwrap_or(Null)
        "places" => ja(self.places())
        "peopleIn" => ja(self.people_in(s(args, 0)))
        "begin" => self.begin(s(args, 0), s(args, 1), str_of(args.get(2)).unwrap_or(""))
        "channelName" => self.channel_name(s(args, 0))
        _ =>
          match base.base_call(name, args) {
            Some(v) => v
            None => get(name, args)
          }
      }
    },
    remote: false,
  }
  {
    surface,
    start: async fn(handler) { base.start(handler) },
    stop: async fn() { self.stop() },
    socket: () => base.socket(),
    identity: () => base.identity(),
    on_change: f => base.on_change(f),
    refresh_identity: async fn() { base.refresh_identity() },
  }
}
