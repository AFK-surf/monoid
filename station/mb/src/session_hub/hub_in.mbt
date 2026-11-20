// What comes into the hub (station/src/sessions/hub.ts "messages in"): a connect's platform's events, one at a time a
// thread (`inThread`), recorded once and delivered to the sessions of the thread; a single-session connect's one session
// made once (`oneSingle`); the files a message shares fetched into the session's uploads; recovery after a restart.

///|
/// A message refused, unrecorded, by a station handing its chats of that workspace to another (`Retiring`).
pub let retiring_message : String = "this station is handing its chats of this workspace to another station"

///|
/// One gate a thread: what the last event of it left (None: it went; Some: an error the next ones are refused with).
priv struct Gate {
  mut tail : @effect.Deferred[Error?]
  mut waiting : Int
}

///|
/// The gates of the hubs, by hub and then by thread (the struct is the package's; a hub keeps none of these).
let gates : Map[String, Gate] = Map([])

///|
/// The single-session connects' making, by connect.
let singles : Map[String, @effect.Deferred[Unit]] = Map([])

///|
fn done_deferred() -> @effect.Deferred[Error?] {
  let d = @effect.Deferred::new()
  ignore(d.succeed(None))
  d
}

///|
/// `inThread`: runs `run` once what came before it in the thread at `at` is done; one that failed with
/// `block_following` refuses those after it with its error, until the gate is let go.
pub async fn[T] Hub::in_thread(self : Hub, at : String, run : async () -> T, block_following? : Bool = false) -> T {
  ignore(self)
  let gate = match gates.get(at) {
    Some(g) => g
    None => {
      let g = { tail: done_deferred(), waiting: 0 }
      gates[at] = g
      g
    }
  }
  gate.waiting += 1
  let previous = gate.tail
  let mine : @effect.Deferred[Error?] = @effect.Deferred::new()
  gate.tail = mine
  let blocked = previous.wait()
  let result : Result[T, Error] = match blocked {
    Some(e) => Err(e)
    None => try Ok(run()) catch { e => Err(e) }
  }
  match result {
    Ok(_) => ignore(mine.succeed(None))
    Err(e) =>
      ignore(
        mine.succeed(
          match blocked {
            Some(b) => Some(b)
            None => if block_following { Some(e) } else { None }
          },
        ),
      )
  }
  gate.waiting -= 1
  if gate.waiting == 0 && gates.get(at) is Some(g) && physical_equal(g, gate) {
    gates.remove(at)
  }
  match result {
    Ok(v) => v
    Err(e) => raise e
  }
}

///|
/// `oneSingle`: a single-session connect's session made or chosen, one at a time.
pub async fn[T] Hub::one_single(self : Hub, connect : String, f : async () -> T) -> T {
  ignore(self)
  let before = singles.get(connect)
  let mine : @effect.Deferred[Unit] = @effect.Deferred::new()
  singles[connect] = mine
  match before {
    Some(d) => d.wait()
    None => ()
  }
  let result : Result[T, Error] = try Ok(f()) catch { e => Err(e) }
  ignore(mine.succeed(()))
  if singles.get(connect) is Some(d) && physical_equal(d, mine) {
    singles.remove(connect)
  }
  match result {
    Ok(v) => v
    Err(e) => raise e
  }
}

///|
/// Where a connect's threads live.
pub fn Hub::surface(self : Hub, connect : String) -> String {
  if connect == internal_connect {
    return stillfail_surface
  }
  let kind = match self.connect_of(connect) {
    Some(c) => str_of(c, "kind")
    None => None
  }
  match kind {
    Some("feishu") => "feishu:\{connect}"
    Some("comma") => "comma:\{connect}"
    Some("group") => "group:\{connect}"
    _ => {
      let team = match (self.world.chat)(connect) {
        Some(c) => str_of(c, "workspace")
        None => None
      }
      slack_surface(connect, team)
    }
  }
}

///|
/// A connect of the config, by id.
pub fn Hub::connect_of(self : Hub, id : String) -> Json? {
  items(field(self.config(), "connects")).iter().find_first(c => str_of(c, "id") == Some(id))
}

///|
/// `connectOf`: one that is not there refused.
pub fn Hub::connect(self : Hub, id : String) -> Json raise Refused {
  match self.connect_of(id) {
    Some(c) => c
    None => raise Refused("unknown connect \{id}")
  }
}

///|
fn Hub::bot_of(self : Hub, connect : String) -> String {
  match (self.world.chat)(connect) {
    Some(c) => str_of(c, "botUserId").unwrap_or("")
    None => ""
  }
}

///|
/// A station's own notice from a bot of any connect this station knows of the workspace's.
fn Hub::station_notice(self : Hub, message : Json) -> Bool {
  if !is_notice(str_of(message, "text").unwrap_or("")) {
    return false
  }
  let user = str_of(message, "user").unwrap_or("")
  for c in items(field(self.config(), "connects")) {
    if self.bot_of(str_of(c, "id").unwrap_or("")) == user && user != "" {
      return true
    }
  }
  for _, bots in self.told_bots {
    if bots.contains(user) {
      return true
    }
  }
  false
}

///|
/// A user that is one of this station's connects' bots.
fn Hub::own_bot(self : Hub, user : String) -> Bool {
  items(field(self.config(), "connects")).iter().any(c => {
    let bot = self.bot_of(str_of(c, "id").unwrap_or(""))
    bot != "" && bot == user
  })
}

///|
/// Whether the thread a session last spoke in came through a connect that is connected.
pub fn Hub::online(self : Hub, row : Json) -> Bool {
  let key = row_key(row)
  let via = match (self.threads.latest_thread(Json::string(key)) catch { _ => Json::null() }) {
    Object(_) as t => str_of(t, "connect")
    _ => None
  }
  let connect = match via {
    Some(c) => c
    None => str_of(row, "connect").unwrap_or("")
  }
  self.flush_threads()
  (self.world.chat)(connect) is Some(_)
}

///|
/// Which workspace a session's chat is in: its own, or the station's home one.
pub fn Hub::ws_of(self : Hub, key : String?) -> String? {
  let row = match key {
    Some(k) => self.get_session(k)
    None => None
  }
  match row {
    Some(r) =>
      match row_ws(r) {
        Some(w) => Some(w)
        None => self.home()
      }
    None => self.home()
  }
}

///|
/// hub.ts `wsOf(row: SessionRow | string | null)`: a session's row read for its own workspace as it is given (not read
/// again: handover.mbt `check` gives the row of its plan's page), a key's row read here, else the home one.
pub fn Hub::ws_of_arg(self : Hub, arg : Json) -> String? {
  match arg {
    Object(_) =>
      match row_ws(arg) {
        Some(w) if w != "" => Some(w)
        _ => self.home()
      }
    String(k) => self.ws_of(Some(k))
    _ => self.home()
  }
}

///|
/// The threads' store's write, its changes told on.
fn[T] Hub::tw(self : Hub, f : () -> T raise) -> T raise {
  errdefer self.flush_threads()
  let r = f()
  self.flush_threads()
  r
}

///|
/// A JSON value as the threads' store takes it (station/jsjson).
pub fn jv(v : Json) -> @jsjson.JValue {
  @jsjson.JValue::of_json(v)
}

///|
/// Takes one event from a connect's platform (`receive`).
pub async fn Hub::receive(self : Hub, connect : String, event : Json) -> Unit {
  match str_of(event, "type") {
    Some("message") => self.accept(connect, field(event, "message").unwrap_or(Json::null()))
    Some("loginCode") => self.enter_code(connect, event)
    Some("stop") => {
      let thread = self.tw(() => self.threads.thread_at(
        Json::string(self.surface(connect)),
        field(event, "channel").unwrap_or(Json::null()),
        field(event, "threadTs").unwrap_or(Json::null()),
      ))
      guard thread is Object(_) else { return }
      for m in items(Some(self.tw(() => self.threads.thread_sessions(field(thread, "id").unwrap_or(Json::null()))))) {
        if str_of(m, "connect") != Some(connect) {
          continue
        }
        match self.get_session(str_of(m, "session").unwrap_or("")) {
          Some(row) => {
            let key = self.actor(row)
            ignore(
              self.ask_actor(key, "stopFromSlack", args=[
                Json::string(connect),
                field(event, "channel").unwrap_or(Json::null()),
                field(event, "threadTs").unwrap_or(Json::null()),
                field(event, "ts").unwrap_or(Json::null()),
                field(event, "localAt").unwrap_or(undefined()),
              ]),
            )
          }
          None => ()
        }
      }
    }
    _ => {
      // an edit
      let surface = self.surface(connect)
      let args = [
        Json::string(surface),
        field(event, "channel").unwrap_or(Json::null()),
        field(event, "threadTs").unwrap_or(Json::null()),
        field(event, "ts").unwrap_or(Json::null()),
        field(event, "text").unwrap_or(Json::null()),
      ]
      let prepares = (self.world.ask)("prepareLegacyEdits.has", Json::null()) == Json::boolean(true)
      if !prepares {
        ignore(self.tw(() => self.threads.edit_message(args[0], args[1], args[2], args[3], args[4])))
        return
      }
      let at = "\{surface}\u{0}\{js_string(args[1])}\u{0}\{js_string(args[2])}"
      self.in_thread(
        at,
        async fn() {
          while true {
            if self.stopping {
              raise Refused("This operation was aborted")
            }
            let changed = self.tw(() => self.threads.edit_message_if_ready(args[0], args[1], args[2], args[3], args[4]))
            if changed != undefined() {
              return
            }
            ignore((self.world.ask)("prepareLegacyEdits", Json::null()))
          }
        },
        block_following=true,
      )
    }
  }
}

///|
/// A login card's field answered on a platform: the code goes to the login that card is of. Refuses what is not.
async fn Hub::enter_code(self : Hub, connect : String, event : Json) -> Unit {
  let thread = self.tw(() => self.threads.thread_at(
    Json::string(self.surface(connect)),
    field(event, "channel").unwrap_or(Json::null()),
    field(event, "threadTs").unwrap_or(Json::null()),
  ))
  let card = match thread {
    Object(_) => self.tw(() => self.threads.card_at(field(thread, "id").unwrap_or(Json::null()), field(event, "ts").unwrap_or(Json::null())))
    _ => Json::null()
  }
  let is_login = str_of(card, "type") == Some("login") &&
    str_of(card, "login") is Some(_) &&
    field(card, "station") is None
  if !is_login {
    raise Refused("this message is no login card")
  }
  if (self.world.ask)("logins.has", Json::null()) != Json::boolean(true) {
    raise Refused("this station has no logins")
  }
  let user = field(event, "user").unwrap_or(Json::null())
  let email = match ((self.world.ask)("chat.userEmail", { "connect": Json::string(connect), "user": user }) catch { _ => Json::null() }) {
    String(e) => Some(e)
    _ => None
  }
  let name = match ((self.world.ask)("chat.userName", { "connect": Json::string(connect), "user": user }) catch { _ => Json::null() }) {
    String(n) => Some(n)
    _ => None
  }
  let by : Json = match email {
    Some(e) => { "name": Json::string(name.unwrap_or(e)), "email": Json::string(e) }
    None => undefined()
  }
  ignore(
    (self.world.ask)("logins.answer", {
      "id": field(card, "login").unwrap_or(Json::null()),
      "code": field(event, "code").unwrap_or(Json::null()),
      "by": by,
    }),
  )
}

///|
/// Accepts one message seen by a connect, one at a time per thread.
pub async fn Hub::accept(self : Hub, connect : String, message : Json) -> Unit {
  let at = "\{self.surface(connect)}\u{0}\{str_of(message, "channel").unwrap_or("")}\u{0}\{str_of(message, "threadTs").unwrap_or("")}"
  self.in_thread(at, async fn() { self.accept_in_turn(connect, message) })
}

///|
/// A post through a connect's chat, not waited for (what it gives is not read; a failure is only logged).
fn Hub::post_soon(self : Hub, connect : String, here : Json, text : String) -> Unit {
  (self.world.tell)("chat.post", {
    "connect": Json::string(connect),
    "thread": here,
    "text": Json::string(text),
    "files": Json::array([]),
  })
}

///|
/// A post through a connect's chat, waited for.
async fn Hub::post(self : Hub, connect : String, here : Json, text : String) -> Json {
  (self.world.ask)("chat.post", {
    "connect": Json::string(connect),
    "thread": here,
    "text": Json::string(text),
    "files": Json::array([]),
  })
}

///|
async fn Hub::accept_in_turn(self : Hub, connect_id : String, message : Json) -> Unit {
  let user = str_of(message, "user").unwrap_or("")
  if self.own_bot(user) {
    return
  }
  if self.station_notice(message) {
    return
  }
  let connect = self.connect(connect_id)
  let cws = match str_of(connect, "workspace") {
    Some(w) => w
    None => self.home().unwrap_or("")
  }
  if self.quieted.length() > 0 && self.quieted.contains(cws) {
    raise Refused(retiring_message)
  }
  if (self.world.chat)(connect_id) is None {
    raise Refused("connect \{connect_id} is not connected")
  }
  let surface = self.surface(connect_id)
  let channel = str_of(message, "channel").unwrap_or("")
  let thread_ts = str_of(message, "threadTs").unwrap_or("")
  let ts = str_of(message, "ts").unwrap_or("")
  let single = str_of(connect, "mode") == Some("single-session")
  let bound = if single {
    match (self.store.binding(Json::string(connect_id)) catch { _ => Json::null() }) {
      String(b) => Some(b)
      _ => None
    }
  } else {
    None
  }
  let existing = self.tw(() => self.threads.thread_at(Json::string(surface), Json::string(channel), Json::string(thread_ts)))
  let existing_id = match existing {
    Object(_) => field(existing, "id")
    _ => None
  }
  let members = match existing_id {
    Some(id) => items(Some(self.tw(() => self.threads.thread_sessions(id))))
    None => []
  }
  let own = if single { None } else { Some(session_key(connect_id, channel, thread_ts)) }
  let same_bot = if single { [] } else { members.filter(m => str_of(m, "connect") == Some(connect_id)) }
  let taken = match same_bot.iter().find_first(m => field(m, "leftAt") is Some(Null) || field(m, "leftAt") is None) {
    Some(m) => Some(m)
    None =>
      match same_bot.iter().find_first(m => str_of(m, "session") == own && own is Some(_)) {
        Some(m) => Some(m)
        None => same_bot.get(0)
      }
  }
  let mut key = match bound {
    Some(b) => b
    None =>
      match taken {
        Some(t) => str_of(t, "session").unwrap_or("")
        None =>
          match own {
            Some(o) => o
            None => self.new_single_session_key(connect_id)
          }
      }
  }
  let exists = self.get_session(key) is Some(_)
  let left = members.iter().any(m => str_of(m, "session") == Some(key) && !(field(m, "leftAt") is Some(Null) || field(m, "leftAt") is None))
  let addressed = is_true(message, "addressed")
  let wanted = addressed ||
    (
      !left &&
      (
        if single {
          !is_true(connect, "requireMention") || (exists && members.iter().any(m => str_of(m, "session") == Some(key)))
        } else {
          exists
        }
      )
    )
  if !wanted && members.length() == 0 {
    return
  }
  let here : Json = { "channel": Json::string(channel), "threadTs": Json::string(thread_ts) }
  match existing_id {
    Some(id) =>
      if self.store.manually_archived(id) {
        if self.tw(() => self.threads.message_number_at(id, Json::string(ts))) == Json::null() {
          ignore(self.post(connect_id, here, mark_notice("⚠️ \{self.words.tr("station.chat.archived")}")) catch { _ => Json::null() })
        }
        return
      }
    None => ()
  }
  let created_by = "slack:\{connect_id}:\{user}"
  if wanted && !exists {
    let made = try {
      if !single {
        self.create_session(key, connect, "thread", Some(message), None, Some(created_by))
      } else {
        let making = key
        key = self.one_single(connect_id, async fn() {
          let now = match self.store.binding(Json::string(connect_id)) {
            String(b) => Some(b)
            _ => None
          }
          match now {
            Some(b) if self.get_session(b) is Some(_) => return b
            _ => ()
          }
          self.create_session(making, connect, "all", Some(message), None, Some(created_by))
          self.store.set_binding(Json::string(connect_id), Json::string(making))
          making
        })
      }
      None
    } catch {
      e => Some(e)
    }
    match made {
      Some(e) => {
        let m = error_words(e)
        ignore(self.post(connect_id, here, mark_notice("⚠️ \{self.words.tr("station.slack.sessionFailed", args=[("error", Json::string(m))])}")))
        return
      }
      None => ()
    }
    let link = if single { None } else { (self.world.link)(key) }
    match link {
      Some(l) => {
        let word = self.words.tr("station.slack.viewSession")
        let has = match (self.world.chat)(connect_id) {
          Some(c) => chat_has(c, "sessionLink")
          None => false
        }
        // (a surface whose link is none posts none: hub.ts `said !== null`)
        let said = if has {
          match (self.world.ask)("chat.sessionLink", { "connect": Json::string(connect_id), "link": Json::string(l), "label": Json::string(word) }) {
            String(s) => Some(s)
            _ => None
          }
        } else {
          Some("<\{l}|\{word}>")
        }
        match said {
          Some(s) => self.post_soon(connect_id, here, mark_notice(s))
          None => ()
        }
      }
      None => ()
    }
  }
  let thread = match existing {
    Object(_) => existing
    _ => self.open_slack_thread(connect_id, surface, message, created_by, key)
  }
  let thread_id = field(thread, "id").unwrap_or(Json::null())
  if wanted {
    ignore(self.tw(() => self.threads.join_thread(thread_id, Json::string(key), Json::string(connect_id))))
  }
  let into = if wanted {
    key
  } else {
    match members.get(0) {
      Some(m) => str_of(m, "session").unwrap_or(key)
      None => key
    }
  }
  let first = self.tw(() => self.threads.message_number_at(thread_id, Json::string(ts))) == Json::null()
  let text = str_of(message, "text").unwrap_or("")
  let mut said = if first {
    self.fetched(connect_id, into, text, items(field(message, "files")))
  } else {
    (text, [])
  }
  if first && wanted {
    said = self.with_quoted(connect_id, thread_id, here, into, message, said)
  }
  let inserted = self.tw(() => self.threads.insert_message(
    jv({
      "thread": thread_id,
      "ts": Json::string(ts),
      "authorKind": "person",
      "author": Json::string(user),
      "text": Json::string(said.0),
      "attachments": Json::array(said.1),
    }),
  ))
  let (n, fresh) = match inserted {
    Array([n, f]) => (n, f == Json::boolean(true))
    _ => (Json::null(), false)
  }
  let targets = if fresh {
    items(Some(self.tw(() => self.threads.thread_sessions(thread_id)))).map(m => str_of(m, "session").unwrap_or(""))
  } else if wanted {
    [key]
  } else {
    []
  }
  self.deliver(thread_id, n, targets, text)
}

///|
/// What an error says, as `(error as Error).message`.
pub fn error_words(e : Error) -> String {
  match e {
    Refused(m) => m
    @store_sessions.StoreError(m, _) => m
    _ => {
      let s = e.to_string()
      s
    }
  }
}

///|
/// A message that quotes one the conversation does not have brings it in, once.
async fn Hub::with_quoted(self : Hub, connect : String, thread : Json, here : Json, into : String, message : Json, said : (String, Array[Json])) -> (String, Array[Json]) {
  let quoted_ts = match field(message, "quoted") {
    Some(String(q)) => q
    _ => return said
  }
  let has = match (self.world.chat)(connect) {
    Some(c) => chat_has(c, "quoted")
    None => false
  }
  if !has || self.tw(() => self.threads.message_number_at(thread, Json::string(quoted_ts))) != Json::null() {
    return said
  }
  let once = "\{js_string(thread)}:\{quoted_ts}"
  if self.quoted_in.contains(once) {
    return said
  }
  self.quoted_in.push(once)
  if self.quoted_in.length() > 2000 {
    ignore(self.quoted_in.remove(0))
  }
  let quoted = (self.world.ask)("chat.quoted", { "connect": Json::string(connect), "thread": here, "ts": Json::string(quoted_ts) })
  let qtext = str_of(quoted, "text").unwrap_or("")
  let qfiles = items(field(quoted, "files"))
  if quoted == Json::null() || (qtext == "" && qfiles.length() == 0) {
    return said
  }
  let (its_text, its_files) = self.fetched(connect, into, qtext, qfiles)
  let block = if its_text == "" {
    ""
  } else {
    split(its_text, "\n").map(l => "> \{l}").join("\n")
  }
  let text = [block, said.0].filter(t => t != "").join("\n\n")
  (text, its_files + said.1)
}

///|
/// A thread the station starts following; what was said before in it recorded first (without deliveries).
async fn Hub::open_slack_thread(self : Hub, connect : String, surface : String, message : Json, created_by : String, key : String) -> Json {
  let channel = field(message, "channel").unwrap_or(Json::null())
  let thread_ts = field(message, "threadTs").unwrap_or(Json::null())
  let ts = field(message, "ts").unwrap_or(Json::null())
  let mut earlier : Array[Json] = []
  if ts != thread_ts {
    let has = match (self.world.chat)(connect) {
      Some(c) => chat_has(c, "history")
      None => false
    }
    if has {
      earlier = items(
        Some(
          (self.world.ask)("chat.history", {
            "connect": Json::string(connect),
            "thread": { "channel": channel, "threadTs": thread_ts },
            "before": ts,
            "limit": num(200.0),
          }) catch {
            _ => Json::array([])
          },
        ),
      )
    }
  }
  let said = []
  for m in earlier {
    let (text, attachments) = self.fetched(connect, key, str_of(m, "text").unwrap_or(""), items(field(m, "files")))
    said.push((m, text, attachments))
  }
  let thread = self.tw(() => self.threads.open_thread(Json::string(surface), channel, thread_ts, Json::null(), Json::string(created_by)))
  for x in said {
    let (m, text, attachments) = x
    ignore(
      self.tw(() => self.threads.insert_message(
        jv({
          "thread": field(thread, "id").unwrap_or(Json::null()),
          "ts": field(m, "ts").unwrap_or(Json::null()),
          "authorKind": "person",
          "author": field(m, "user").unwrap_or(Json::null()),
          "text": Json::string(text),
          "attachments": Json::array(attachments),
        }),
      )),
    )
  }
  thread
}

///|
/// node:path `join` of what the hub joins (POSIX, its parts plain names).
pub fn join_path(parts : Array[String]) -> String {
  @nodepath.join("/", parts)
}

///|
/// A message's text and its shared files, fetched into the session's uploads. A file that cannot be fetched is named in
/// the text with why.
pub async fn Hub::fetched(self : Hub, connect : String, key : String, text : String, files : Array[Json]) -> (String, Array[Json]) {
  let row = if files.length() > 0 { self.get_session(key) } else { None }
  guard row is Some(row) else { return (text, []) }
  let dir = join_path([str_of(row, "workspace").unwrap_or(""), "uploads"])
  let attachments = []
  let missing = []
  let can = match (self.world.chat)(connect) {
    Some(c) => chat_has(c, "download")
    None => false
  }
  for file in files {
    let name = str_of(file, "name").unwrap_or("")
    let failed : String? = if !can {
      Some("this platform does not give files")
    } else if num_of(file, "size").unwrap_or(0.0) > max_inbound_file {
      Some("over 50 MB")
    } else {
      let b = StringBuilder()
      for c in name {
        b.write_char(if c == '\\' || c == '/' || c.to_int() < 0x20 { '_' } else { c })
      }
      let stamp = slice(iso(self.now()), 0, to=19)
      let stamp = replace_all(replace_all(stamp, ":", "-"), ".", "-")
      let path = join_path([dir, "\{stamp}-\{str_of(file, "id").unwrap_or("")}-\{b.to_string()}"])
      let got = (self.world.ask)("chat.downloadTo", {
        "connect": Json::string(connect),
        "file": file,
        "dir": Json::string(dir),
        "path": Json::string(path),
      }) catch {
        e => { "error": Json::string(error_words(e)) }
      }
      match str_of(got, "error") {
        Some(m) => Some(m)
        None => {
          let a : Map[String, Json] = {
            "name": Json::string(name),
            "path": Json::string(path),
            "size": field(got, "size").unwrap_or(num(0.0)),
          }
          match field(got, "facts") {
            Some(Object(f)) => for k, v in f { a[k] = v }
            _ => ()
          }
          attachments.push(Json::object(a))
          None
        }
      }
    }
    match failed {
      Some(m) =>
        missing.push(self.words.tr("station.slack.fileNotFetched", args=[("name", Json::string(name)), ("error", Json::string(m))]))
      None => ()
    }
  }
  (([text] + missing).filter(t => t != "").join("\n\n"), attachments)
}

///|
/// Gives sessions a message they have not had: each runs it, or stops for `-stop`, compacts for `-compact`, clears for
/// `-clear`. A session archived by hand hears nothing until shown again.
pub fn Hub::deliver(self : Hub, thread : Json, n : Json, sessions : Array[String], text : String, retry_pending? : Bool = false, workspace? : String?) -> Unit raise {
  let left = items(Some(self.tw(() => self.threads.thread_sessions(thread))))
    .filter(m => !(field(m, "leftAt") is Some(Null) || field(m, "leftAt") is None))
    .map(m => str_of(m, "session").unwrap_or(""))
  let hearing = sessions.filter(key => !left.contains(key) &&
    (match self.get_session(key) {
      Some(r) => str_of(r, "archivedBy") != Some(manual)
      None => true
    }))
  let ws_arg : Json = match workspace {
    // (the store reads an object as the workspace's check)
    None => Json::null()
    Some(expected) => { "expected": opt_str(expected), "fallback": opt_str(self.ws_of(None)) }
  }
  let added = strings_json(self.tw(() => self.threads.deliver(thread, n, Json::array(hearing.map(Json::string)), ws_arg)))
  let command = thread_command(text)
  let give = (key : String) => {
    self.store.touch(key)
    match self.get_session(key) {
      None => ()
      Some(row) => {
        let actor = self.actor(row)
        match command {
          None => self.act(actor, "kick")
          Some(c) => {
            let marked = self.tw(() => self.threads.mark_delivered(Json::string(key), Json::array([{ "thread": thread, "n": n, "apart": Json::boolean(false) }])))
            if workspace is Some(_) && marked == num(0.0) {
              return
            }
            match c {
              "stop" => self.act(actor, "stop")
              "compact" => self.act(actor, "compact", args=[Json::boolean(true)])
              _ => self.act(actor, "clear", args=[Json::boolean(true)])
            }
          }
        }
      }
    }
  }
  for key in added {
    give(key)
  }
  if retry_pending {
    let seen = []
    for key in hearing {
      if seen.contains(key) {
        continue
      }
      seen.push(key)
      if added.contains(key) ||
        self.tw(() => self.threads.delivery_pending(thread, n, Json::string(key))) != Json::boolean(true) {
        continue
      }
      give(key)
    }
  }
}

///|
/// Gives sessions a letter of their chat's own log they have not had: each runs it.
pub fn Hub::deliver_letter(self : Hub, thread : Json, n : Json, sessions : Array[String]) -> Unit raise {
  let hearing = sessions.filter(key => match self.get_session(key) {
    Some(r) => str_of(r, "archivedBy") != Some(manual)
    None => true
  })
  for key in strings_json(self.tw(() => self.threads.deliver_letter(thread, n, Json::array(hearing.map(Json::string))))) {
    self.store.touch(key)
    match self.get_session(key) {
      Some(row) => self.kick(row)
      None => ()
    }
  }
}

///|
/// An agent's post reaches the other sessions of its thread, as a person's would.
pub fn Hub::shared(self : Hub, thread : Json, n : Json, author : String, text : String) -> Unit raise {
  let others = items(Some(self.tw(() => self.threads.thread_sessions(thread))))
    .map(m => str_of(m, "session").unwrap_or(""))
    .filter(s => s != author)
  if others.length() > 0 {
    self.deliver(thread, n, others, text)
  }
}

///|
/// The station's tools are open at `url`.
pub fn Hub::tools_at(self : Hub, url : String) -> Unit {
  for key in self.actor_keys() {
    self.act(key, "toolsAt", args=[Json::string(url)])
  }
}

///|
fn viewer_sees_ws(viewer : Json, ws : String?) -> Bool {
  match str_of(viewer, "workspace") {
    None | Some("") => true
    Some(vw) =>
      match ws {
        Some(w) => w == vw
        None => field(viewer, "home") != Some(Json::boolean(false))
      }
  }
}

///|
/// Sessions interrupted by a non-update restart visible to `viewer`, newest active first (items capped at 20).
pub fn Hub::interrupted_in(self : Hub, viewer : Json) -> Json {
  let rows : Array[Json] = []
  for key in self.interrupted_by_restart {
    match self.get_session(key) {
      Some(row) if !is_true(row, "running") &&
        field(row, "archivedAt") is (None | Some(Null)) &&
        !self.handed_over(key) &&
        viewer_sees_ws(viewer, row_ws(row)) => rows.push(row)
      _ => ()
    }
  }
  let sorted = stable_sort(rows, (a, b) => {
    let d = num_of(b, "lastActiveAt").unwrap_or(0.0) - num_of(a, "lastActiveAt").unwrap_or(0.0)
    if d > 0.0 { 1 } else if d < 0.0 { -1 } else { 0 }
  })
  let count = sorted.length()
  let limit = if count < 20 { count } else { 20 }
  let items_out : Array[Json] = []
  for i = 0; i < limit; i = i + 1 {
    let row = sorted[i]
    let key = row_key(row)
    let latest = self.threads.latest_thread(Json::string(key)) catch { _ => Json::null() }
    let thread_obj = field(latest, "thread").unwrap_or(Json::null())
    let thread_id = field(thread_obj, "id").unwrap_or(Json::null())
    let title = match str_of(row, "title") {
      Some(t) if t != "" => t
      _ => str_of(thread_obj, "title").unwrap_or("")
    }
    items_out.push({ "key": Json::string(key), "thread": thread_id, "title": Json::string(title) })
  }
  { "count": num(count.to_double()), "items": Json::array(items_out) }
}

///|
/// Resumes sessions interrupted by a non-update restart visible to `viewer` (optionally narrowed to `keys`),
/// gently staggered by 250 ms on the hub clock.
pub fn Hub::resume_interrupted(self : Hub, viewer : Json, keys : Json) -> Int raise Refused {
  let wanted : Array[String]? = match keys {
    Array(arr) => Some(arr.filter_map(x => match x { String(s) if s != "" => Some(s); _ => None }))
    _ => None
  }
  let rows : Array[Json] = []
  let keep : Array[String] = []
  for key in self.interrupted_by_restart {
    let matched = match wanted {
      None => true
      Some(w) => w.contains(key)
    }
    if !matched {
      keep.push(key)
      continue
    }
    match self.get_session(key) {
      Some(row) if !is_true(row, "running") &&
        field(row, "archivedAt") is (None | Some(Null)) &&
        !self.handed_over(key) =>
        if viewer_sees_ws(viewer, row_ws(row)) {
          rows.push(row)
        } else {
          keep.push(key)
        }
      _ => ()
    }
  }
  self.interrupted_by_restart.clear()
  for k in keep {
    self.interrupted_by_restart.push(k)
  }
  if rows.length() == 0 {
    return 0
  }
  (self.world.tell)("overview.changed", Json::null())
  let sorted = stable_sort(rows, (a, b) => {
    let d = num_of(b, "lastActiveAt").unwrap_or(0.0) - num_of(a, "lastActiveAt").unwrap_or(0.0)
    if d > 0.0 { 1 } else if d < 0.0 { -1 } else { 0 }
  })
  let eligible = sorted.filter(row => self.online(row))
  if eligible.length() == 0 {
    return 0
  }
  self.recover_one(eligible[0])
  for i = 1; i < eligible.length(); i = i + 1 {
    let key = row_key(eligible[i])
    let delay = 250.0 * i.to_double()
    ignore(
      self.after(delay, () => {
        match self.get_session(key) {
          Some(now) if !is_true(now, "running") &&
            field(now, "archivedAt") is (None | Some(Null)) &&
            !self.handed_over(key) &&
            self.online(now) =>
            try {
              self.recover_one(now)
            } catch {
              _ => ()
            }
          _ => ()
        }
      }),
    )
  }
  eligible.length()
}

///|
/// Dismisses sessions interrupted by a non-update restart visible to `viewer` (optionally narrowed to `keys`).
pub fn Hub::dismiss_interrupted(self : Hub, viewer : Json, keys : Json) -> Int {
  let wanted : Array[String]? = match keys {
    Array(arr) => Some(arr.filter_map(x => match x { String(s) if s != "" => Some(s); _ => None }))
    _ => None
  }
  let mut removed = 0
  let keep : Array[String] = []
  for key in self.interrupted_by_restart {
    let matched = match wanted {
      None => true
      Some(w) => w.contains(key)
    }
    if !matched {
      keep.push(key)
      continue
    }
    match self.get_session(key) {
      Some(row) if !viewer_sees_ws(viewer, row_ws(row)) => keep.push(key)
      _ => removed += 1
    }
  }
  self.interrupted_by_restart.clear()
  for k in keep {
    self.interrupted_by_restart.push(k)
  }
  if removed > 0 {
    (self.world.tell)("overview.changed", Json::null())
  }
  removed
}

///|
/// After a restart: resume cut-off turns (those not taken up with their runtime), then deliver whatever is pending.
pub fn Hub::recover(self : Hub) -> Unit raise {
  let manual_resume = self.non_update_restart
  self.non_update_restart = false
  let recovering : Array[String] = []
  let running = self.running_sessions()
  running.sort_by((a, b) => {
    let diff = num_of(b, "lastActiveAt").unwrap_or(0.0) - num_of(a, "lastActiveAt").unwrap_or(0.0)
    if diff > 0.0 { 1 } else if diff < 0.0 { -1 } else { 0 }
  })
  for row in running {
    let key = row_key(row)
    if self.adopted.contains(key) || !self.online(row) {
      continue
    }
    if manual_resume {
      let actor = self.actor(row)
      pending_work.push(async fn() {
        let interrupted = self.ask_actor(actor, "cutOffByRestart")
        if interrupted != Json::boolean(true) {
          return
        }
        match self.get_session(key) {
          Some(now) if !is_true(now, "running") &&
            field(now, "archivedAt") is (None | Some(Null)) &&
            !self.handed_over(key) =>
            if !self.interrupted_by_restart.contains(key) {
              self.interrupted_by_restart.push(key)
              (self.world.tell)("overview.changed", Json::null())
            }
          _ => ()
        }
      })
      self.wake_waiters()
      continue
    }
    recovering.push(key)
    self.recover_one(row)
  }
  // (a turn resumed takes what waits for it with it; while turns are held, `release` gives the rest theirs)
  if self.holds_now.length() == 0 {
    for key in self.sessions_with_pending() {
      if recovering.contains(key) {
        continue
      }
      match self.get_session(key) {
        Some(row) => if self.online(row) { self.kick(row) }
        None => ()
      }
    }
  }
  let indexed = self.store.recovery_waits()
  match indexed {
    Array(list) => {
      for x in list {
        let row = field(x, "row").unwrap_or(Json::null())
        if !self.online(row) {
          continue
        }
        let key = self.actor(row)
        self.act(key, if is_true(x, "refill") { "takeRefill" } else { "takeWait" })
      }
      return
    }
    _ => ()
  }
  let live = self.store.live_sessions()
  let turns = self.store.last_turns_of(live.map(row_key))
  for row in live {
    let last = match turns {
      Object(m) => m.get(row_key(row))
      Array(entries) => {
        let mut found : Json? = None
        for e in entries {
          match e {
            Array(pair) if pair.length() == 2 && pair[0] == Json::string(row_key(row)) => {
              found = Some(pair[1])
              break
            }
            _ => ()
          }
        }
        found
      }
      _ => None
    }
    let ended_null = match last {
      Some(l) => field(l, "endedAt") is Some(Null)
      None => false
    }
    if is_true(row, "running") || ended_null {
      continue
    }
    let refill = match last {
      Some(l) => str_of(l, "outcome") == Some("failed") && (str_of(l, "detail").unwrap_or("").has_prefix("rate_limit:"))
      None => false
    }
    let waiting = match last {
      Some(l) => str_of(l, "declared") == Some("waiting")
      None => false
    }
    if (!refill && !waiting) || !self.online(row) {
      continue
    }
    let key = self.actor(row)
    self.act(key, if refill { "takeRefill" } else { "takeWait" })
  }
}

///|
/// A runtime installed here: the sessions on it whose messages wait take them now.
pub fn Hub::installed(self : Hub, runtime : String) -> Unit raise {
  for key in self.sessions_with_pending() {
    match self.get_session(key) {
      Some(row) => if str_of(row, "runtime") == Some(runtime) && self.online(row) { self.kick(row) }
      None => ()
    }
  }
}
