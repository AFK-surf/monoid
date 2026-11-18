// The hub's processes and what it asks of its actors (station/src/sessions/hub.ts "warm processes" and after): idle
// processes ended past the warm limit, changes that end a process now or before its next turn, the sessions' commands
// from the pages; the transcripts' lengths gathered; the handover and taking up; the models a connect offers and a
// connect's session made (`createSession`).

///|
let hex_digits : String = "0123456789abcdef"

///|
fn hex_bytes(hex : String) -> Array[Int] {
  let out = []
  let mut i = 0
  while i + 1 < hex.length() {
    let d = (c : Int) => if c >= 'a'.to_int() { c - 'a'.to_int() + 10 } else { c - '0'.to_int() }
    out.push(d(u(hex, i)) * 16 + d(u(hex, i + 1)))
    i += 2
  }
  out
}

///|
/// Bytes as base64url, without padding (`toString("base64url")`).
pub fn base64url(bytes : Array[Int]) -> String {
  let alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
  let b = StringBuilder()
  let mut i = 0
  while i < bytes.length() {
    let b0 = bytes[i]
    let b1 = if i + 1 < bytes.length() { bytes[i + 1] } else { 0 }
    let b2 = if i + 2 < bytes.length() { bytes[i + 2] } else { 0 }
    let n = (b0 << 16) | (b1 << 8) | b2
    b.write_char(alphabet.get_char((n >> 18) & 63).unwrap())
    b.write_char(alphabet.get_char((n >> 12) & 63).unwrap())
    if i + 1 < bytes.length() {
      b.write_char(alphabet.get_char((n >> 6) & 63).unwrap())
    }
    if i + 2 < bytes.length() {
      b.write_char(alphabet.get_char(n & 63).unwrap())
    }
    i += 3
  }
  b.to_string()
}

///|
/// `newSingleSessionKey`: a new session for a single-session connect.
pub fn Hub::new_single_session_key(self : Hub, connect : String) -> String {
  "\{connect}:s-\{(self.world.random_hex)(4)}"
}

///|
/// `newChatKey`: a new session talked to in the station's chat.
pub fn Hub::new_chat_key(self : Hub) -> String {
  "\{chat_key_prefix}:c-\{(self.world.random_hex)(5)}"
}

///|
/// `newToken`: the bearer token a session presents to the MCP endpoint.
pub fn Hub::new_token(self : Hub) -> String {
  base64url(hex_bytes((self.world.random_hex)(24)))
}

///|
/// internal.ts `nextTsAt`: a Slack-style ts for something said now; they only go up (a clock, not a registry).
let last_micros : Ref[Double] = { val: 0.0 }

///|
pub fn next_ts_at(now_ms : Double) -> String {
  let next = if last_micros.val + 1.0 > now_ms * 1000.0 { last_micros.val + 1.0 } else { now_ms * 1000.0 }
  last_micros.val = next
  let secs = (next / 1_000_000.0).floor()
  let micros = (next % 1_000_000.0).to_int64().to_string()
  "\{secs.to_int64()}.\{"0".repeat(6 - micros.length())}\{micros}"
}

///|
pub fn Hub::next_ts(self : Hub) -> String {
  next_ts_at(self.now())
}

// ── warm processes ──

///|
/// Ends idle claude and dsh processes beyond the warm limit, oldest first, once they have idled past warmMs.
fn Hub::evict_idle(self : Hub) -> Unit {
  let config = self.config()
  let now = self.now()
  let idle = []
  for key, runtime in self.actors {
    if runtime == "codex" {
      continue
    }
    match (self.world.idle_ms)(key, now) {
      Some(ms) => idle.push((key, ms))
      None => ()
    }
  }
  let sorted = stable_sort(idle, (a, b) => {
    let d = b.1 - a.1
    if d > 0.0 {
      1
    } else if d < 0.0 {
      -1
    } else {
      0
    }
  })
  let mut excess = sorted.length() - num_of(config, "maxWarmClaude").unwrap_or(4.0).to_int()
  let warm = num_of(config, "warmMs").unwrap_or(1_800_000.0)
  for x in sorted {
    if excess <= 0 || x.1 < warm {
      break
    }
    self.act(x.0, "evict")
    excess -= 1
  }
}

///|
/// A process went idle: look again when it has idled past warmMs.
pub fn Hub::idle_now(self : Hub, key : String) -> Unit {
  match self.get_session(key) {
    Some(row) if field(row, "archivedAt") is Some(Number(_)) =>
      // (finished archive: what it left in the background ends with it)
      match (try { Some(self.actor(row)) } catch { _ => None }) {
        Some(actor) => self.act(actor, "evictThenCleanArchive")
        None => ()
      }
    _ => ()
  }
  match self.deadlines.get(key) {
    Some(id) => self.cancel(id)
    None => ()
  }
  let limit = num_of(self.config(), "warmMs").unwrap_or(1_800_000.0)
  let idle_for = if self.actors.contains(key) {
    (self.world.idle_ms)(key, self.now()).unwrap_or(0.0)
  } else {
    0.0
  }
  let wait = if limit - idle_for > 0.0 { limit - idle_for } else { 0.0 }
  let id = self.after(wait, () => {
    self.deadlines.remove(key)
    self.evict_idle()
  })
  self.deadlines[key] = id
  self.evict_idle()
}

///|
/// The machine short of memory: every idle claude and dsh process let go now; then what the drivers keep running with
/// no turn on it; how many were asked to end.
pub async fn Hub::evict_all_idle(self : Hub) -> Int {
  let now = self.now()
  let mut asked = 0
  for key, runtime in self.actors {
    if runtime == "codex" || (self.world.idle_ms)(key, now) is None {
      continue
    }
    self.act(key, "evict")
    asked += 1
  }
  let ended = (self.world.ask)("drivers.evictIdle", Json::null())
  match ended {
    Number(n, ..) => asked + n.to_int()
    _ => asked
  }
}

///|
/// Ends the session's runtime process if it is idle.
pub fn Hub::evict(self : Hub, key : String) -> Unit {
  if self.actors.contains(key) {
    self.act(key, "evict")
  }
}

///|
/// How a session runs changed: its process ends now if idle, else before its next turn.
pub fn Hub::changed(self : Hub, key : String, restart? : Bool = false) -> Unit {
  if self.actors.contains(key) {
    self.act(key, "changed", args=[Json::boolean(restart)])
  }
}

///|
/// A manual allowance reset lets every waiting session on the same account, or able to move to it, go on now.
pub async fn Hub::allowance_reset(self : Hub, profile : String) -> Unit {
  ignore((self.world.ask)("accounts.resetAllowance", Json::string(profile)))
  let waiting = []
  for key in self.actor_keys() {
    match self.get_session(key) {
      Some(row) =>
        if (self.world.ask)("accounts.goesOnWith", { "row": row, "profile": Json::string(profile) }) ==
          Json::boolean(true) {
          waiting.push(key)
        }
      None => ()
    }
  }
  for key in waiting {
    self.act(key, "allowanceReset")
  }
}

///|
/// What every runtime process starts with changed: each ends now if idle, else before its next turn.
pub fn Hub::every_changed(self : Hub) -> Unit {
  for key in self.actor_keys() {
    self.act(key, "changed", args=[Json::boolean(true)])
  }
}

///|
/// A runtime updated here: the processes of its sessions end now if idle, else before their next turn.
pub fn Hub::runtime_updated(self : Hub, runtime : String) -> Unit {
  for key, r in self.actors {
    if r == runtime {
      self.act(key, "changed", args=[Json::boolean(true)])
    }
  }
}

///|
/// A profile signed in anew: the processes of the sessions on it end now if idle, else once their turn is over.
pub fn Hub::profile_login_changed(self : Hub, id : String) -> Unit raise {
  for row in self.store.list_sessions() {
    if str_of(row, "profile") != Some(id) || self.handed_over(row_key(row)) {
      continue
    }
    if self.actors.contains(row_key(row)) {
      self.act(row_key(row), "changed", args=[Json::boolean(true)])
    }
  }
}

///|
/// A profile was deleted (disabled, moved away), as hub.ts `profileGone`: a session on it with a turn under way is taken
/// on by another of its runtime's, or stopped where no other can run it; one whose process is idle only has it ended;
/// one with no process is left as it is (its next turn picks another account then).
pub async fn Hub::profile_gone(self : Hub, id : String) -> Unit {
  for row in self.store.list_sessions() {
    let key = row_key(row)
    if str_of(row, "profile") != Some(id) || self.handed_over(key) {
      continue
    }
    let state = self.process_state(key)
    if !self.actors.contains(key) || state == "cold" {
      continue
    }
    if state == "warm" {
      (self.world.tell)("log", {
        "info": "profile deleted under an idle session",
        "fields": { "session": Json::string(key), "profile": Json::string(id) },
      })
      ignore(self.ask_actor(key, "changed"))
      continue
    }
    let movable = match ((self.world.ask)("accounts.runOn", { "key": Json::string(key) }) catch { _ => Json::boolean(false) }) {
      False => false
      _ => true
    }
    if !movable {
      ignore(self.ask_actor(key, "stop"))
    }
    ignore(self.ask_actor(key, "changed"))
  }
}

///|
/// Chats moved here whose accounts came after them: those that ran on an account of `map` go on on its id here.
pub fn Hub::follow_accounts(self : Hub, keys : Array[String], map : Map[String, String]) -> Int raise {
  let mut n = 0
  for key in keys {
    if !self.store.follow_profiles(key, map) {
      continue
    }
    n += 1
    if self.actors.contains(key) {
      self.act(key, "changed")
    }
  }
  n
}

///|
/// A session's command from the pages, on its actor (made where it is not): `warm`, `stop`, `cancelRetry`,
/// `retryFailed`, `reassign`, `compact`, `clear`, `notify`. Unknown sessions refused.
pub async fn Hub::command(self : Hub, key : String, call : String, args : Array[Json]) -> Json {
  match self.get_session(key) {
    None =>
      if call == "warm" {
        Json::null()
      } else {
        raise Refused("unknown session \{key}")
      }
    Some(row) => {
      let actor = self.actor(row)
      match call {
        "notify" => {
          self.act(actor, "notify", args~)
          Json::null()
        }
        _ => self.ask_actor(actor, call, args~)
      }
    }
  }
}

///|
/// Every session's process state that is not cold.
pub fn Hub::processes(self : Hub) -> Array[(String, String)] {
  let out = []
  for key, _ in self.actors {
    let s = (self.world.process_state)(key)
    if s != "cold" {
      out.push((key, s))
    }
  }
  out
}

///|
/// The key the client that asked for a session gave it, while it is kept.
pub fn Hub::client_key(self : Hub, key : String) -> String? {
  match self.client_keys_made.get(key) {
    Some((client, at)) if self.now() - at < client_key_kept_ms => Some(client)
    _ => None
  }
}

///|
pub fn Hub::client_keys(self : Hub) -> Array[(String, String)] {
  let out = []
  for key, v in self.client_keys_made {
    if self.now() - v.1 < client_key_kept_ms {
      out.push((key, v.0))
    }
  }
  out
}

// ── transcripts' lengths ──

///|
/// A transcript's length, written with the others' that come within `lengths_gather_ms` (its first in this process at
/// once).
pub fn Hub::note_length(self : Hub, key : String, n : Json) -> Unit {
  self.lengths[key] = n
  if !self.length_written.contains(key) {
    self.length_written.add(key)
    self.write_lengths(only=[key])
    return
  }
  if self.lengths_due {
    return
  }
  self.lengths_due = true
  ignore(self.after(lengths_gather_ms, () => self.write_lengths()))
}

///|
fn Hub::write_lengths(self : Hub, only? : Array[String]) -> Unit {
  if only is None {
    self.lengths_due = false
  }
  let lengths : Array[(String, Json)] = []
  match only {
    None => {
      for k, v in self.lengths {
        lengths.push((k, v))
      }
      self.lengths = {}
    }
    Some(keys) =>
      for k in keys {
        match self.lengths.get(k) {
          Some(v) => {
            lengths.push((k, v))
            self.lengths.remove(k)
          }
          None => ()
        }
      }
  }
  if lengths.length() == 0 {
    return
  }
  self.store.set_transcript_lengths(lengths) catch {
    _ => ()
  }
}

///|
fn Hub::stop_timers(self : Hub) -> Unit {
  self.write_lengths()
  self.timers.clear()
  self.deadlines.clear()
}

// ── handover ──

///|
/// Hands the sessions to the next station: turns held, every queue run out, each actor's snapshot written to
/// <data>/run/handover.json, and the drivers let go of their processes.
pub async fn Hub::hand_over(self : Hub, limit_ms? : Double = 30_000.0) -> Json {
  self.hold("drain")
  self.holds_runners = false
  let settled = (self.world.ask)("actors.settled", { "limitMs": num(limit_ms) })
  if str_of(settled, "error") is Some(m) {
    self.release("drain")
    raise Refused(m)
  }
  let frozen = (self.world.ask)("drivers.freeze", { "limitMs": num(limit_ms) })
  // What the drivers took in as they froze settled too (hub.ts: `settled` again after `freeze`), so the snapshots say
  // where each stands then.
  let frozen = if str_of(frozen, "error") is Some(_) {
    frozen
  } else {
    (self.world.ask)("actors.settled", { "limitMs": num(limit_ms) })
  }
  if str_of(frozen, "error") is Some(m) {
    (self.world.tell)("drivers", { "call": "thaw", "args": [] })
    self.release("drain")
    raise Refused(m)
  }
  self.stopping = true
  let sessions = []
  for key in self.actor_keys() {
    let holds = (self.world.ask)("actor", { "key": Json::string(key), "call": "holdsState", "args": [] })
    if (self.world.process_state)(key) != "cold" || holds == Json::boolean(true) {
      sessions.push(self.ask_actor(key, "snapshot"))
    } else {
      self.act(key, "close")
    }
  }
  (self.world.tell)("actors.close", Json::null())
  (self.world.tell)("drivers", { "call": "detach", "args": [] })
  ignore((self.world.ask)("runners.allLeft", Json::null()))
  self.stop_timers()
  let handed : Json = { "sessions": Json::array(sessions) }
  let file = join_path([str_of(self.config(), "dataDir").unwrap_or(""), "run", "handover.json"])
  ignore((self.world.ask)("fs.write", { "path": Json::string(file), "text": Json::string(handed.stringify()) }))
  handed
}

///|
/// Takes up what the previous station left: the snapshots of its handover, then the runners it left without one.
pub async fn Hub::take_up(self : Hub) -> Unit {
  let file = join_path([str_of(self.config(), "dataDir").unwrap_or(""), "run", "handover.json"])
  let mut handed : Json = { "sessions": [] }
  let text = (self.world.ask)("fs.read", { "path": Json::string(file) })
  match text {
    Null => ()
    _ => {
      match text {
        String(t) =>
          handed = @json.parse(t) catch {
            _ => {
              (self.world.tell)("log", { "warn": "the handover file does not read; sessions resume the usual way" })
              handed
            }
          }
        _ =>
          (self.world.tell)("log", { "warn": "the handover file does not read; sessions resume the usual way" })
      }
      ignore((self.world.ask)("fs.rm", { "path": Json::string(file) }))
    }
  }
  let before = strings_json((self.world.ask)("runners", Json::null())).filter(id => !id.has_prefix("term-"))
  self.adopt(handed)
  let runners = before
  let taken = items(field(handed, "sessions")).map(s => str_of(s, "key").unwrap_or(""))
  let own_runners = runners.iter().any(id => !id.has_prefix("codex-"))
  let parts = []
  for id in runners {
    match runtime_kinds.iter().find_first(k => k != "codex" && id.has_prefix("\{k}-")) {
      Some(k) => parts.push(Json::string(slice(id, k.length() + 1)))
      None => ()
    }
  }
  let candidates = if !own_runners {
    self.running_sessions()
  } else {
    match (self.world.ask)("sandboxNames.takeUp", Json::array(parts)) {
      Array(rows) => rows
      _ => self.store.list_sessions()
    }
  }
  for row in candidates {
    let key = row_key(row)
    if taken.contains(key) {
      continue
    }
    let runtime = match runtime_named(str_of(row, "runtime").unwrap_or("")) {
      Some(r) => r
      None => continue
    }
    let runner = js_string((self.world.ask)("runnerId", { "runtime": Json::string(runtime), "key": Json::string(key) }))
    if runtime != "codex" {
      if !runners.contains(runner) {
        continue
      }
    } else if !is_true(row, "running") {
      continue
    }
    let turn = if is_true(row, "running") {
      self.store.latest_turn(Json::string(key))
    } else {
      Json::null()
    }
    let summary = field(turn, "summary").unwrap_or(Json::null())
    let snap_turn : Json = match turn {
      Object(_) if field(summary, "endedAt") is Some(Null) => {
        let kind = str_of(summary, "kind")
        {
          "id": field(turn, "id").unwrap_or(Json::null()),
          "authRetried": Json::boolean(kind == Some("auth_retry")),
          "codexRetried": Json::boolean(kind == Some("codex_retry")),
          "by": { "profile": Json::null(), "person": Json::null(), "thread": Json::null() },
          "declared": field(summary, "declared").unwrap_or(Json::null()),
          "wait": field(summary, "waitSeconds").unwrap_or(Json::null()),
        }
      }
      _ => Json::null()
    }
    let idle = self.now() - num_of(row, "lastActiveAt").unwrap_or(0.0)
    let snap : Json = {
      "key": Json::string(key),
      "runtime": Json::string(runtime),
      "agent": Json::null(),
      "turn": snap_turn,
      "workingFor": [],
      "notices": [],
      "waitingMs": Json::null(),
      "waitingSeconds": num(0.0),
      "nudges": num(0.0),
      "stopRequested": Json::boolean(false),
      "idleMs": num(if idle > 0.0 { idle } else { 0.0 }),
    }
    self.adopt_one(row, snap, true)
  }
  self.holds_runners = true
  // What nobody took up of these is ended.
  for id in before {
    if !self.owns_runner(id) {
      ignore((self.world.ask)("runners.end", { "id": Json::string(id) }) catch { _ => Json::null() })
    }
  }
}

///|
/// Whether one of its drivers holds runner `id` (or may: a driver that does not say holds every one of its runtime's).
pub async fn Hub::owns_runner(self : Hub, id : String) -> Bool {
  (self.world.ask)("drivers.owns", Json::string(id)) == Json::boolean(true)
}

///|
/// A runner of an agent's alive past what takes it up that none of its drivers holds: ended. Whether it was.
pub async fn Hub::end_orphan(self : Hub, info : Json, now : Double) -> Bool {
  let id = str_of(info, "id").unwrap_or("")
  if !self.holds_runners ||
    id.has_prefix("term-") ||
    now - num_of(info, "startedAt").unwrap_or(0.0) < runner_left_ms ||
    self.owns_runner(id) {
    return false
  }
  ignore((self.world.ask)("runners.end", { "id": Json::string(id) }))
  true
}

///|
/// Takes up a handover's snapshots.
pub async fn Hub::adopt(self : Hub, handed : Json) -> Unit {
  for snap in items(field(handed, "sessions")) {
    match self.get_session(str_of(snap, "key").unwrap_or("")) {
      None => (self.world.tell)("log", { "warn": "session handed over is gone" })
      Some(row) => self.adopt_one(row, snap, field(snap, "agent") != Some(Json::null()))
    }
  }
}

///|
async fn Hub::adopt_one(self : Hub, row : Json, snap : Json, with_process : Bool) -> Unit {
  (self.world.tell)("taking", Json::null())
  let key = match (try { Some(self.actor(row)) } catch { _ => None }) {
    Some(k) => k
    None => return
  }
  let ran_on = match str_of(row, "runtimeSessionId") {
    Some(id) if id != "" =>
      match (self.store.ran_on(key, Json::string(id)) catch { _ => Json::null() }) {
        String(p) => p
        _ => str_of(row, "profile").unwrap_or("")
      }
    _ => str_of(row, "profile").unwrap_or("")
  }
  let mut agent = Json::null()
  if with_process {
    agent = (self.world.ask)("drivers.adopt", { "row": row, "snap": snap, "ranOn": Json::string(ran_on) }) catch {
      _ => Json::null()
    }
  }
  if with_process && agent == Json::null() {
    return
  }
  ignore(self.ask_actor(key, "adopt", args=[snap, agent, Json::string(ran_on)]))
  if agent != Json::null() {
    self.adopted.add(key)
    if field(snap, "turn") is Some(Null) || field(snap, "turn") is None {
      self.idle_now(key)
    }
  }
  if items(field(snap, "notices")).length() > 0 {
    self.act(key, "release")
  }
}

///|
/// Shuts the hub down: timers stopped, the lengths written, actors disposed, drivers shut down.
pub fn Hub::shutdown(self : Hub) -> Unit {
  self.holds_runners = false
  self.stopping = true
  self.stop_timers()
  for key in self.actor_keys() {
    self.act(key, "dispose")
  }
  (self.world.tell)("actors.close", Json::null())
  (self.world.tell)("drivers", { "call": "shutdown", "args": [] })
}

// ── models and new sessions ──

///|
/// The profiles sessions of workspace `ws` may run on.
pub fn Hub::profiles_in(self : Hub, ws : String?) -> Array[Json] {
  let home = self.home()
  items(field(self.config(), "profiles")).filter(p => enabled(p) && allowed_in(p, ws, home))
}

///|
/// The models a person can pick for a new chat with a connect: its own first.
pub fn Hub::models_for(self : Hub, connect_id : String) -> Array[Json] raise {
  let connect = self.connect(connect_id)
  let bind = field(connect, "bind").unwrap_or(Json::null())
  let own : Json = {
    "runtime": field(bind, "runtime").unwrap_or(Json::null()),
    "model": match field(bind, "model") {
      Some(String(_) as m) => m
      _ => Json::null()
    },
  }
  let profiles = items(field(self.config(), "profiles")).filter(p => enabled(p) &&
    allowed_in(p, str_of(connect, "workspace"), self.home()))
  [own] + candidates(profiles, None).filter(c => !alike(c, own))
}

///|
/// Of those, the few `user` is offered before they type anything.
pub fn Hub::models_first(self : Hub, connect_id : String, user : String) -> Array[Json] raise {
  let all = self.models_for(connect_id)
  if all.length() <= few_most {
    return all
  }
  let connect = self.connect(connect_id)
  let since = self.now() - used_within_ms
  let used = []
  if user != "" {
    for c in items(field(self.config(), "connects")) {
      for u in self.store.models_used_by(Json::string("slack:\{str_of(c, "id").unwrap_or("")}:\{user}"), num(since)) {
        used.push(u)
      }
    }
  }
  let profiles = items(field(self.config(), "profiles")).filter(p => enabled(p) &&
    allowed_in(p, str_of(connect, "workspace"), self.home()))
  let named = profiles.map(p => match p {
    Object(m) => {
      let c = m.copy()
      c["models"] = field(p, "named").unwrap_or(Json::array([]))
      Json::object(c)
    }
    _ => p
  })
  few(all, used, candidates(named, None))
}

///|
/// A session for a connect: the connect's own profile when it keeps to one; else any of its runtime, the model's
/// first. A message sent to a model starts one on that model instead.
pub async fn Hub::create_session(self : Hub, key : String, connect : Json, scope : String, message : Json?, title : String?, created_by : String?) -> Unit {
  let config = self.config()
  let home = self.home()
  let chosen = match message {
    Some(m) =>
      match field(m, "model") {
        Some(Object(_) as c) => Some(c)
        _ => None
      }
    None => None
  }
  let bind = field(connect, "bind").unwrap_or(Json::null())
  let runtime = match chosen {
    None => str_of(bind, "runtime").unwrap_or("claude")
    Some(c) =>
      match runtime_named(str_of(c, "runtime").unwrap_or("")) {
        Some(r) => r
        None => raise Refused("unknown runtime \{str_of(c, "runtime").unwrap_or("undefined")}")
      }
  }
  let model = match chosen {
    None => str_of(bind, "model")
    Some(c) => str_of(c, "model")
  }
  let cws = str_of(connect, "workspace")
  let profiles = items(field(config, "profiles"))
  let profiles_for = (h : String?) => profiles.filter(p => enabled(p) &&
    profile_runtimes(p).contains(str_of(bind, "runtime").unwrap_or("")) &&
    allowed_in(p, cws, h))
  let fits = match chosen {
    None => profiles_for(home)
    Some(_) =>
      profiles.filter(p => enabled(p) &&
        profile_runtimes(p).contains(runtime) &&
        allowed_in(p, cws, home) &&
        serves(p, model))
  }
  if fits.length() == 0 && chosen is Some(_) {
    raise Refused(
      self.words.tr("station.session.noProfileForModel", args=[
        ("model", Json::string(model.unwrap_or(runtime_label(runtime)))),
        ("runtime", Json::string(runtime_label(runtime))),
      ]),
    )
  }
  if fits.length() == 0 && profiles_for(None).length() > 0 {
    raise Refused(
      self.words.tr("station.session.noProfileHere", args=[
        ("runtime", Json::string(runtime_label(str_of(bind, "runtime").unwrap_or("claude")))),
      ]),
    )
  }
  let bound_ids : Array[String]? = if chosen is None {
    let list = items(field(bind, "profiles")).map(js_string)
    if list.length() > 0 {
      Some(list)
    } else {
      match str_of(bind, "profile") {
        Some(p) => Some([p])
        None => None
      }
    }
  } else {
    None
  }
  let bound_fits = match bound_ids {
    Some(ids) => fits.filter(p => ids.contains(profile_id(p)) && serves(p, model))
    None => []
  }
  let saved = if bound_fits.length() > 0 { Some(bound_fits.map(profile_id)) } else { None }
  let profile = if bound_fits.length() == 1 {
    bound_fits[0]
  } else {
    (self.world.ask)("accounts.pick", {
      "candidates": Json::array((if bound_fits.length() > 0 { bound_fits } else { fits }).map(p => Json::string(profile_id(p)))),
      "model": opt_str(model),
      "strict": Json::boolean(false),
    })
  }
  if str_of(profile, "error") is Some(m) {
    raise Refused(m)
  }
  let dir = match message {
    Some(m) if scope == "thread" =>
      "\{str_of(m, "channel").unwrap_or("")}-\{replace_first(str_of(m, "threadTs").unwrap_or(""), ".", "-")}"
    _ => slice(key, str_of(connect, "id").unwrap_or("").length() + 1)
  }
  let data = str_of(config, "dataDir").unwrap_or("")
  let workspace = join_path([data, "sessions", str_of(connect, "id").unwrap_or(""), dir, "workspace"])
  ignore((self.world.ask)("fs.mkdirs", Json::array([Json::string(workspace), Json::string(join_path([data, "repos"]))])))
  if self.get_session(key) is Some(_) {
    return
  }
  let now = self.now()
  self.store.insert_session({
    "key": Json::string(key),
    "connect": field(connect, "id").unwrap_or(Json::null()),
    "scope": Json::string(scope),
    "title": opt_str(title),
    "createdBy": opt_str(created_by),
    "runtime": Json::string(runtime),
    "profile": Json::string(profile_id(profile)),
    "profilePinned": Json::boolean(saved.map(s => s.length()) == Some(1)),
    "profiles": match saved {
      Some(s) => Json::array(s.map(Json::string))
      None => Json::null()
    },
    "model": opt_str(model),
    "effort": if chosen is None { opt_str(str_of(bind, "effort")) } else { Json::null() },
    "fast": Json::null(),
    "workspace": Json::string(workspace),
    "cwd": Json::null(),
    "runtimeSessionId": Json::null(),
    "token": Json::string(self.new_token()),
    "createdAt": num(now),
    "lastActiveAt": num(now),
    "ws": opt_str(cws),
  })
}

///|
/// `s.replace(a, b)`: the first `a` replaced.
pub fn replace_first(s : String, a : String, b : String) -> String {
  let i = index_of(s, a)
  if i < 0 {
    s
  } else {
    slice(s, 0, to=i) + b + slice(s, i + a.length())
  }
}
