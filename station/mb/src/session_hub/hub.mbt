// The station's sessions hub (station/src/sessions/hub.ts `Hub`): routes chat messages to session actors and creates
// sessions; several connects share one hub, each with its own chat connection and its own sessions. Its state: why turns
// are held, the workspaces and chats being handed to another station, the chats held one at a time, the sessions taken
// up from the station before, the idle processes' deadlines, the incoming gates by thread, the held posts, the lengths
// of transcripts gathered before they are written. The store is the station's database through the store packages
// (`@store_sessions`, `@store_threads`), the rest the world's (world.mbt).

///|
/// Why turns are held (`Hold`): drain, unbound, starting.
pub let holds_known : Array[String] = ["drain", "unbound", "starting"]

///|
/// How long transcripts' lengths are gathered before they are written (`noteLength`).
pub let lengths_gather_ms : Double = 5_000.0

///|
/// How long a new chat's rows say the key its client gave it.
pub let client_key_kept_ms : Double = 600_000.0

///|
/// agents/runner.ts `RUNNER_LEFT_MS`.
pub let runner_left_ms : Double = 300_000.0

///|
/// The most of a shared file the station fetches.
pub let max_inbound_file : Double = 52_428_800.0

///|
/// rows.ts surfaces and marks.
pub let stillfail_surface : String = "chat"

///|
pub let internal_connect : String = "chat"

///|
pub let internal_channel : String = "CHAT"

///|
pub let chat_key_prefix : String = "chat"

///|
pub let manual : String = "manual"

///|
pub let auto : String = "auto"

///|
/// chat.ts `NOTICE_MARK`.
pub let notice_mark : String = "\u{2063}"

///|
pub fn mark_notice(text : String) -> String {
  if text.has_suffix(notice_mark) {
    text
  } else {
    text + notice_mark
  }
}

///|
pub fn is_notice(text : String) -> Bool {
  // (trimEnd: the mark is no white space)
  let mut end = text.length()
  while end > 0 && @jscase.is_white_space(u(text, end - 1)) {
    end -= 1
  }
  slice(text, 0, to=end).has_suffix(notice_mark)
}

///|
pub fn retired_ws(ws : String) -> String {
  "retired:\{ws}"
}

///|
pub fn handed_ws(ws : String) -> String {
  "handed:\{ws}"
}

///|
pub fn coming_ws(ws : String) -> String {
  "coming:\{ws}"
}

///|
pub fn slack_surface(connect : String, team : String?) -> String {
  match team {
    Some(t) if t != "" => "slack:\{t}"
    _ => "slack:\{connect}"
  }
}

///|
/// `sessionKey`: a multi-session connect's session for one thread.
pub fn session_key(connect : String, channel : String, thread_ts : String) -> String {
  "\{connect}:\{channel}:\{thread_ts}"
}

///|
/// read/transcript.ts `iso`: an ISO timestamp of milliseconds since the epoch, as toISOString writes it.
pub fn iso(ms : Double) -> String {
  @jsjson.js_iso(ms)
}

///|
/// A timer of the hub's own (its idle deadlines, the lengths' write): due at, in the order set.
pub struct Timer {
  id : Int
  due : Double
  run : () -> Unit
}

///|
pub struct Hub {
  world : World
  store : @store_sessions.Store
  /// The threads' store, made again at each step the clock moved (its time is the one it was made with).
  threads : @store_threads.Store
  words : Words
  /// The actors made (a session's key, its runtime), in the order made.
  actors : Map[String, String]
  /// Why turns are held.
  holds_now : Array[String]
  /// Sessions taken up from the previous station: their turns run on.
  adopted : Set[String]
  mut holds_runners : Bool
  /// The workspaces whose chats this station hands to another.
  quieted : Set[String]
  /// The chats held one at a time, with why.
  held_chats : Map[String, String]
  /// What a chat stopped by a move says once: its words, and whether said in this stop.
  stop_notices : Map[String, (String, Bool)]
  /// When each idle process is next looked at (a timer's id).
  deadlines : Map[String, Int]
  /// Chats made lately: the key their client gave them, and when.
  client_keys_made : Map[String, (String, Double)]
  /// Posts chat_post held back, by session and then by id.
  held_posts : Map[String, Map[String, Json]]
  held_count : Int
  /// The bots other stations told this one, by station.
  told_bots : Map[String, Set[String]]
  /// The quoted messages already brought in (`thread:ts`).
  quoted_in : Array[String]
  /// Transcripts' lengths not written yet, whether their write is due, and those written in this process.
  mut lengths : Map[String, Json]
  mut lengths_due : Bool
  length_written : Set[String]
  /// Its timers, and the next id.
  timers : Array[Timer]
  mut timer_seq : Int
  /// What waits for a timer to be set (a test's, before it moves the clock on to it).
  timer_waiters : Array[@effect.Deferred[Unit]]
  /// Whether it was handed over or shut down (`incoming` aborted).
  mut stopping : Bool
  /// What waits for the workspaces' activity to be prepared.
  awaiting_workspace_activity : Set[String]
  /// The usage counter (usage.mbt), once started: told what the store tells.
  mut counter : UsageCounter?
  /// Whether what the store tells of usage is kept (module.ts `keepCounted`).
  mut keeps_counted : Bool
}

///|
pub fn Hub::new(world : World, store : @store_sessions.Store, threads : @store_threads.Store, words? : Words = Words::new()) -> Hub {
  let hub = {
    world,
    store,
    threads,
    words,
    actors: {},
    holds_now: [],
    adopted: Set([]),
    holds_runners: false,
    quieted: Set([]),
    held_chats: {},
    stop_notices: {},
    deadlines: {},
    client_keys_made: {},
    held_posts: {},
    held_count: 0,
    told_bots: {},
    quoted_in: [],
    lengths: {},
    lengths_due: false,
    length_written: Set([]),
    timers: [],
    timer_seq: 0,
    timer_waiters: [],
    stopping: false,
    awaiting_workspace_activity: Set([]),
    counter: None,
    keeps_counted: false,
  }
  // The sessions at work are followed by the station itself (live.ts `running`): as the store says each starts and
  // stops. Each transcript's length goes where its summary reads it (`noteLength`).
  ignore(hub.store.subscribe(change => hub.told(change)))
  hub
}

///|
/// What the store told: a session changed (its summary is told now, with its transcript's length as read), or gone.
pub fn Hub::told(self : Hub, change : Json) -> Unit {
  match (str_of(change, "type"), str_of(change, "key")) {
    (Some("session"), Some(key)) => {
      if self.lengths.contains(key) {
        self.write_lengths(only=[key])
      }
      let running = match self.get_session(key) {
        Some(row) => is_true(row, "running")
        None => false
      }
      (self.world.tell)("live.running", { "key": Json::string(key), "running": Json::boolean(running) })
    }
    (Some("sessionRemoved"), Some(key)) =>
      (self.world.tell)("live.running", { "key": Json::string(key), "running": Json::boolean(false) })
    _ => ()
  }
  // (then what follows the store after the hub, in the order the station has them: the counter, then the usage kept)
  match self.counter {
    Some(c) => c.told(change)
    None => ()
  }
  if self.keeps_counted {
    self.counted(change)
  }
}

///|
/// What the threads' store told meanwhile, told on as the TypeScript store tells its followers.
pub fn Hub::flush_threads(self : Hub) -> Unit {
  let sent = self.threads.sent.copy()
  self.threads.sent.clear()
  for c in sent {
    match c {
      Array(list) => for x in list { self.told(x) }
      _ => self.told(c)
    }
  }
}

// ── the store, as the hub reads it ──

///|
pub fn Hub::get_session(self : Hub, key : String) -> Json? {
  match (self.store.get_session(key) catch { _ => Json::null() }) {
    Null => None
    row => Some(row)
  }
}

///|
/// The workspace a session's row says (None: no session; Some(None): none).
pub fn Hub::session_ws(self : Hub, key : String) -> String?? {
  match (self.store.session_ws(key) catch { _ => Json::boolean(false) }) {
    String(ws) => Some(Some(ws))
    Null => Some(None)
    _ => None
  }
}

///|
fn strings_json(v : Json) -> Array[String] {
  match v {
    Array(a) => a.filter_map(x => match x { String(s) => Some(s); _ => None })
    _ => []
  }
}

///|
pub fn Hub::sessions_with_pending(self : Hub) -> Array[String] {
  strings_json(self.threads.sessions_with_pending() catch { _ => Json::array([]) })
}

///|
pub fn Hub::has_pending(self : Hub, key : String) -> Bool {
  (self.threads.has_pending(Json::string(key)) catch { _ => Json::boolean(false) }) == Json::boolean(true)
}

///|
pub fn Hub::running_sessions(self : Hub) -> Array[Json] {
  self.store.running_sessions() catch { _ => [] }
}

///|
fn row_key(row : Json) -> String {
  str_of(row, "key").unwrap_or("")
}

///|
fn row_ws(row : Json) -> String? {
  str_of(row, "ws")
}

// ── the clock and its timers ──

///|
pub fn Hub::now(self : Hub) -> Double {
  (self.world.now)()
}

///|
pub fn Hub::config(self : Hub) -> Json {
  (self.world.config)()
}

///|
pub fn Hub::workspaces(self : Hub) -> Array[String] {
  (self.world.workspaces)()
}

///|
fn Hub::home(self : Hub) -> String? {
  self.workspaces().get(0)
}

///|
/// Sets `run` going at `ms` from now (0 or less: as the step that set it ends, `run_due` then); its id.
pub fn Hub::after(self : Hub, ms : Double, run : () -> Unit) -> Int {
  self.timer_seq += 1
  let id = self.timer_seq
  self.timers.push({ id, due: self.now() + (if ms > 0.0 { ms } else { 0.0 }), run })
  for d in self.timer_waiters {
    ignore(d.succeed(()))
  }
  self.timer_waiters.clear()
  id
}

///|
pub fn Hub::cancel(self : Hub, id : Int) -> Unit {
  match self.timers.search_by(t => t.id == id) {
    Some(i) => ignore(self.timers.remove(i))
    None => ()
  }
}

///|
/// Runs what is due by `now` (the clock moved there), earliest first, those set at once in the order set.
pub fn Hub::run_due(self : Hub, now : Double) -> Unit {
  while true {
    let mut best : Int? = None
    for i, t in self.timers {
      if t.due <= now {
        match best {
          None => best = Some(i)
          Some(b) =>
            if t.due < self.timers[b].due ||
              (t.due == self.timers[b].due && t.id < self.timers[b].id) {
              best = Some(i)
            }
        }
      }
    }
    match best {
      None => break
      Some(i) => {
        let t = self.timers.remove(i)
        (t.run)()
      }
    }
  }
}

// ── actors ──

///|
/// The session's actor, made on first use (its key).
pub fn Hub::actor(self : Hub, row : Json) -> String raise Refused {
  let key = row_key(row)
  if self.actors.contains(key) {
    return key
  }
  let runtime = str_of(row, "runtime").unwrap_or("")
  match runtime_named(runtime) {
    None => raise Refused("session \{key} runs an unknown runtime \{runtime}")
    Some(r) => {
      self.actors[key] = r
      (self.world.tell)("actor.made", { "key": Json::string(key), "runtime": Json::string(r) })
    }
  }
  key
}

///|
/// Tells an actor to do something (`void actor.<call>()`).
pub fn Hub::act(self : Hub, key : String, call : String, args? : Array[Json] = []) -> Unit {
  (self.world.tell)("actor", { "key": Json::string(key), "call": Json::string(call), "args": Json::array(args) })
}

///|
/// Asks an actor and waits for its answer (`await actor.<call>()`).
pub async fn Hub::ask_actor(self : Hub, key : String, call : String, args? : Array[Json] = []) -> Json {
  (self.world.ask)("actor", { "key": Json::string(key), "call": Json::string(call), "args": Json::array(args) })
}

///|
pub fn Hub::process_state(self : Hub, key : String) -> String {
  if self.actors.contains(key) {
    (self.world.process_state)(key)
  } else {
    "cold"
  }
}

///|
/// Takes a session's actor out (deleted).
pub fn Hub::drop_actor(self : Hub, key : String) -> Bool {
  let had = self.actors.contains(key)
  self.actors.remove(key)
  match self.deadlines.get(key) {
    Some(id) => self.cancel(id)
    None => ()
  }
  self.deadlines.remove(key)
  had
}

///|
fn Hub::actor_keys(self : Hub) -> Array[String] {
  let out = []
  for k, _ in self.actors {
    out.push(k)
  }
  out
}

// ── holds ──

///|
/// Holds turns for `reason`: none starts from now on, and messages stay pending. Those running go on.
pub fn Hub::hold(self : Hub, reason : String) -> Unit {
  if !self.holds_now.contains(reason) {
    self.holds_now.push(reason)
  }
}

///|
/// Takes back `reason` to hold turns; once none is left, turns start again and what waited meanwhile goes on.
pub fn Hub::release(self : Hub, reason : String) -> Unit raise Refused {
  match self.holds_now.search(reason) {
    None => return
    Some(i) => ignore(self.holds_now.remove(i))
  }
  if self.holds_now.length() > 0 {
    return
  }
  // (an actor released goes on with what waits for it itself: hub.ts `release`)
  let released = self.actor_keys()
  for key in released {
    self.act(key, "release")
  }
  for key in self.sessions_with_pending() {
    if released.contains(key) {
      continue
    }
    match self.get_session(key) {
      Some(row) => self.kick(row)
      None => ()
    }
  }
}

///|
/// `void this.actor(row).kick()`: an actor made where it can be (one of an unknown runtime throws, as `actor` does).
fn Hub::kick(self : Hub, row : Json) -> Unit raise Refused {
  self.act(self.actor(row), "kick")
}

///|
fn Hub::recover_one(self : Hub, row : Json) -> Unit raise Refused {
  self.act(self.actor(row), "recover")
}

///|
pub fn Hub::holds(self : Hub, reason : String) -> Bool {
  self.holds_now.contains(reason)
}

///|
/// The station left its workspace: every runtime process ends, running or idle, then what the drivers run themselves.
pub fn Hub::suspend_all(self : Hub) -> Unit {
  for _, id in self.deadlines {
    self.cancel(id)
  }
  self.deadlines.clear()
  self.adopted.clear()
  for key in self.actor_keys() {
    self.act(key, "suspend")
  }
  (self.world.tell)("drivers", { "call": "shutdown", "args": [Json::boolean(true)] })
}

///|
/// Whether a session's workspace is one the station is in now.
fn Hub::in_a_workspace(self : Hub, key : String) -> Bool {
  let all = self.workspaces()
  let ws = match self.session_ws(key) {
    Some(w) => w
    None => None
  }
  let at = match ws {
    Some(w) => w
    None => all.get(0).unwrap_or("")
  }
  if self.quieted.contains(at) {
    return false
  }
  if all.length() == 0 {
    return true
  }
  match ws {
    None => true
    Some(w) => all.contains(w)
  }
}

///|
/// Whether session `key` is one of `ws`'s chats here.
pub fn Hub::of_workspace(self : Hub, key : String, ws : String) -> Bool {
  match self.session_ws(key) {
    None => false
    Some(was) => {
      let at = match was {
        Some(w) => Some(w)
        None => self.home()
      }
      at == Some(ws) || was == Some(retired_ws(ws))
    }
  }
}

///|
fn Hub::deadline_and_actor_keys(self : Hub) -> Array[String] {
  let keys = []
  for k, _ in self.deadlines {
    keys.push(k)
  }
  for k, _ in self.actors {
    if !keys.contains(k) {
      keys.push(k)
    }
  }
  keys
}

///|
/// This station's chats of `ws` go to another: none of them takes a turn from now on, those running end.
pub fn Hub::quiet(self : Hub, ws : String) -> Unit {
  self.quieted.add(ws)
  let keys = self.deadline_and_actor_keys().filter(k => self.of_workspace(k, ws))
  for key in keys {
    match self.deadlines.get(key) {
      Some(id) => {
        self.cancel(id)
        self.deadlines.remove(key)
      }
      None => ()
    }
  }
  for key in self.actor_keys() {
    if keys.contains(key) {
      self.act(key, "suspend", args=["its workspace's chats go to another station"])
    }
  }
}

///|
/// Rows of sessions running or with something pending, of those `keep` says, the latest active first.
fn Hub::returning(self : Hub, keep : (Json) -> Bool) -> Array[Json] {
  let keys : Array[String] = []
  for row in self.running_sessions() {
    keys.push(row_key(row))
  }
  for k in self.sessions_with_pending() {
    if !keys.contains(k) {
      keys.push(k)
    }
  }
  let rows = []
  for k in keys {
    match self.get_session(k) {
      Some(row) =>
        if keep(row) && (is_true(row, "running") || self.has_pending(k)) {
          rows.push(row)
        }
      None => ()
    }
  }
  stable_sort(rows, (a, b) => {
    let d = num_of(b, "lastActiveAt").unwrap_or(0.0) - num_of(a, "lastActiveAt").unwrap_or(0.0)
    if d > 0.0 {
      1
    } else if d < 0.0 {
      -1
    } else {
      0
    }
  })
}

///|
fn Hub::resume_rows(self : Hub, rows : Array[Json]) -> Unit raise Refused {
  for row in rows {
    if !self.online(row) {
      continue
    }
    if is_true(row, "running") {
      self.recover_one(row)
    } else {
      self.kick(row)
    }
  }
}

///|
/// `quiet` taken back: what it cut off resumes and what waited goes on.
pub async fn Hub::unquiet(self : Hub, ws : String) -> Unit {
  if !self.quieted.contains(ws) {
    return
  }
  self.quieted.remove(ws)
  if Some(ws) != self.home() {
    return self.back_in(ws)
  }
  let rows = self.returning(row => self.of_workspace(row_key(row), ws))
  self.resume_rows(rows)
}

///|
pub fn Hub::quiet_in(self : Hub, ws : String) -> Bool {
  self.quieted.contains(ws)
}

///|
/// Whether session `key` is one of the chats this station hands, or handed, to another.
pub fn Hub::handed_over(self : Hub, key : String) -> Bool {
  match self.session_ws(key) {
    None => false
    Some(ws) => {
      if self.held_chats.contains(key) {
        return true
      }
      match ws {
        Some(w) if w.has_prefix(retired_ws("")) || w.has_prefix(handed_ws("")) || w.has_prefix(coming_ws("")) =>
          return true
        _ => ()
      }
      let at = match ws {
        Some(w) => w
        None => self.home().unwrap_or("")
      }
      self.quieted.contains(at)
    }
  }
}

///|
/// Holds session `key` (`why`: for the status), at once: none of its turns starts from now on.
pub fn Hub::hold_chat(self : Hub, key : String, why : String, notice? : String) -> Unit {
  self.held_chats[key] = why
  match notice {
    Some(n) => self.stop_notices[key] = (n, false)
    None => ()
  }
  match self.deadlines.get(key) {
    Some(id) => {
      self.cancel(id)
      self.deadlines.remove(key)
    }
    None => ()
  }
  if self.actors.contains(key) {
    self.act(key, "suspend", args=[Json::string("the chat is held: \{why}")])
  }
}

///|
/// `holdChat` taken back. False: it was not held.
pub fn Hub::release_chat(self : Hub, key : String) -> Bool raise Refused {
  self.stop_notices.remove(key)
  if !self.held_chats.contains(key) {
    return false
  }
  self.held_chats.remove(key)
  self.wake_chat(key)
  true
}

///|
/// A chat that may take turns now: what was cut off resumes, what waited goes on.
pub fn Hub::wake_chat(self : Hub, key : String) -> Unit raise Refused {
  match self.get_session(key) {
    None => ()
    Some(row) => {
      if self.held_chats.contains(key) ||
        self.holds_now.length() > 0 ||
        !self.online(row) ||
        !self.in_a_workspace(key) {
        return
      }
      if is_true(row, "running") {
        self.recover_one(row)
      } else if self.has_pending(key) {
        self.kick(row)
      }
    }
  }
}

///|
pub fn Hub::busy(self : Hub, key : String) -> Bool {
  self.actors.contains(key) && (self.world.process_state)(key) == "running"
}

///|
pub fn Hub::chat_held(self : Hub, key : String) -> String? {
  self.held_chats.get(key)
}

///|
/// What the stop notice of a held chat says, once (`SessionDeps.stoppedNotice`).
pub fn Hub::stopped_notice(self : Hub, key : String) -> String? {
  match self.stop_notices.get(key) {
    Some((words, false)) if self.held_chats.contains(key) => {
      self.stop_notices[key] = (words, true)
      Some(words)
    }
    _ => None
  }
}

///|
/// `SessionDeps.moveOn`: whether moving to another station is on here (its skill named in a session's instructions);
/// on where nothing says otherwise.
pub fn Hub::move_on(self : Hub) -> Bool {
  (self.world.move_on)().unwrap_or(true)
}

///|
/// `SessionDeps.held`: whether session `key`'s turns are held.
pub fn Hub::held(self : Hub, key : String) -> Bool {
  self.holds_now.length() > 0 || self.held_chats.contains(key) || !self.in_a_workspace(key)
}

///|
/// The station a chat of `connect`'s thread was handed to.
pub fn Hub::moved_to(self : Hub, connect : String, channel : String, thread_ts : String) -> String? {
  let thread = self.threads.thread_at(
    Json::string(self.surface(connect)),
    Json::string(channel),
    Json::string(thread_ts),
  ) catch {
    _ => return None
  }
  guard num_of(thread, "id") is Some(id) else { return None }
  for m in items(Some(self.threads.thread_sessions(num(id)) catch { _ => Json::array([]) })) {
    let session = str_of(m, "session").unwrap_or("")
    if str_of(m, "connect") != Some(connect) {
      continue
    }
    match self.session_ws(session) {
      Some(Some(w)) if w.has_prefix(coming_ws("")) => continue
      _ => ()
    }
    match (self.store.handed_to(session) catch { _ => Json::null() }) {
      Object(_) as to => return str_of(to, "station")
      _ => ()
    }
  }
  None
}

///|
/// The station left one of its workspaces but is still in others: that workspace's sessions end their processes.
pub fn Hub::left_workspace(self : Hub, ws : String) -> Unit {
  let keys = self.deadline_and_actor_keys().filter(k => self.session_ws(k) == Some(Some(ws)))
  for key in keys {
    match self.deadlines.get(key) {
      Some(id) => {
        self.cancel(id)
        self.deadlines.remove(key)
      }
      None => ()
    }
  }
  for key in self.actor_keys() {
    if keys.contains(key) {
      self.act(key, "suspend", args=["the station left its workspace"])
    }
  }
}

///|
/// The station is in a workspace again: its sessions' cut-off turns resume, and what waited goes on.
pub async fn Hub::back_in(self : Hub, ws : String) -> Unit {
  let ready = self.threads.returning_sessions_in(Json::string(ws)) catch { _ => Json::null() }
  let rows = match ready {
    Array(r) => r
    _ => {
      // (an older store's index of workspace activity not prepared: waited for where the station can, else read)
      let waits = (self.world.ask)("waitForWorkspaceActivity.has", Json::null()) == Json::boolean(true)
      if waits {
        if !self.awaiting_workspace_activity.contains(ws) {
          self.awaiting_workspace_activity.add(ws)
          let done = (self.world.ask)("waitForWorkspaceActivity", Json::null())
          self.awaiting_workspace_activity.remove(ws)
          if done == Json::boolean(true) && self.workspaces().contains(ws) {
            self.back_in(ws)
          }
        }
        return
      }
      self.returning(row => row_ws(row) == Some(ws))
    }
  }
  self.resume_rows(rows)
}

///|
/// How many turns are running.
pub fn Hub::running(self : Hub) -> Int {
  self.actor_keys().filter(k => (self.world.process_state)(k) == "running").length()
}

///|
pub fn Hub::any_running(self : Hub) -> Bool {
  self.running() > 0
}
