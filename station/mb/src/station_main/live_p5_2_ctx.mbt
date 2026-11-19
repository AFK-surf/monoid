// The agents' side (P5-2): what it is made of (`P52`, agents.ts `AgentsLive`'s parts) and what a session needs of the
// station (sessions/actor.ts `SessionDeps`, hub.ts `sessionDeps`): its store by name, the hub's deps, how what it is
// handed is formatted, its prompt, its runtime session opened, the station's notices.

///|
priv struct P52 {
  bus : LiveBus
  host : @host.Host
  data : String
  pump : Pump
  program : SessionsProgram
  agents : AgentsHost
  threads : @store_threads.Store
  words : @session_hub.Words
  cwords : @session_chats.Words
  rwords : @api_routes.Words
  files : @session_storage.Files
  /// The hub's config (config.ts `hubConfig`), worked out again as config.json changes.
  mut config : Json
  mut hub : @session_hub.Hub?
  mut actors_program : ActorsProgram?
  drivers : Map[String, Driver]
  mut door_url : String
  mut taken : Bool
  mut site_instructions : String
  /// The process before is gone and the sessions are this one's.
  mut agents_side : @session_hub.AgentsSide?
  /// Session pages (sessions/page.ts), where the station is in a workspace of still.fail cloud.
  runner : String?
  mut closed : Bool
  /// The agents' hands on the screens (tools/computer.ts), once made.
  mut computer : @mcp_tools.Computer?
  /// The store's changes to tell (what the program and the parts wrote).
  ids_seq : Ref[Int]
  /// The repositories on the machine, offered as a preset's folders (hub.ts `repoIndex`).
  repo_index : @session_chats.RepoIndex
  /// Its pass under way, if there is (presets.ts RepoIndex `#walking`).
  mut repo_walking : Bool
  /// What a part set going every so often (ops/fibers.ts `wall.every`), by the handle it was given: still going.
  everies : Map[String, Ref[Bool]]
  /// The live view's transcripts' locator (live-locator.ts), once it is first asked.
  mut live_locator : LiveLocator?
  /// The bug reports' part (feedback/module.ts), where the station is on the stable channel of a plane that takes them.
  mut feedback : @mcp_tools.FeedbackPart?
  /// The consumer of the cards' queued outcomes (agents.ts `cardOutcomes`, card-outbox-worker.ts), on `threads`.
  mut card_outcomes : @store_threads.Worker?
  /// Whether what the worker writes is being followed to tell it (`outcomes_follow`).
  mut outcomes_following : Bool
}

///|
fn P52::lang(self : P52) -> String {
  (self.bus.lang.val)()
}

///|
fn P52::the_hub(self : P52) -> @session_hub.Hub raise LiveError {
  match self.hub {
    Some(h) => h
    None => raise LiveError("the hub is not made yet")
  }
}

///|
/// One of the store's calls by its TypeScript name (store.ts): the sessions' store's, else the threads'.
fn P52::store(self : P52, name : String, args : Array[Json]) -> Json raise {
  self.threads.set_now(wall_ms().to_double())
  // (the store's clock, as store.ts's `now`: what the storage's policy view counts its decisions since)
  if name == "now" {
    return Json::number(self.bus.store.now().to_double())
  }
  match (try { Ok(self.bus.store.call(name, args)) } catch { e => Err(e) }) {
    Ok(v) => v
    Err(e) => {
      let said = said_of(e)
      if said.contains("no call") {
        // What it wrote is told as the store's own writes are (the events, the readers), as P5-4's vault does
        // (`p54_told_threads`): kept in `sent` and never told, an agent's chat_post reached no device until the app
        // read the chat again, and `sent` grew for good (0.1.9984).
        // (an argument left undefined, as the conversations and the rigs say it, is none: the threads' store takes a
        // hook where one is given, and ran an empty statement for card-place.ts's `insertMessage(message, undefined)`)
        let given = args.map(a => match a {
          Object(m) if m.length() == 1 && (m.contains("$u") || m.contains("$undef") || m.contains("$undefined")) =>
            Json::null()
          a => a
        })
        let answer = self.threads.call(name, given.map(jv_of)) catch {
          e => {
            p52_told_threads(self.bus, self.threads)
            raise e
          }
        }
        p52_told_threads(self.bus, self.threads)
        answer
      } else {
        raise e
      }
    }
  }
}

///|
/// One of a queued card's pages (read/pool.ts `cardEditPage`, `cardMessagePage`), read by the readers, behind what a
/// person waits on.
async fn P52::card_page(self : P52, op : String, thread : Json, target : String, before : String?) -> Json {
  let got = (self.bus.reader_ask.val)(op, { "thread": thread, "target": Json::string(target), "before": jopt(before) }, "zh")
  let page = match got {
    String(text) => @json.parse(text) catch { _ => Json::null() }
    v => v
  }
  // (a page read after the worker wrote: what it wrote told first)
  p52_told_threads(self.bus, self.threads)
  page
}

///|
/// agents.ts `cardOutcomes`: the worker made on the threads' store, begun once the process before is gone (it wrote
/// the outbox too while it served), closed as the station stops.
fn P52::outcomes_start(self : P52) -> Unit {
  let worker = @store_threads.Worker::new(
    self.threads,
    self.host.rt,
    async fn(thread, target, before) { self.card_page("internalCardEditPage", thread, target, before) },
    async fn(thread, target, before) { self.card_page("internalCardMessagePage", thread, target, before) },
  )
  self.card_outcomes = Some(worker)
  ignore(
    self.host.rt.fork(name="card outcomes", async fn() {
      match (try { Ok((self.bus.previous_gone)()) } catch { e => Err(e) }) {
        Ok(_) => {
          worker.previous_exited()
          self.outcomes_follow()
        }
        Err(e) => {
          worker.previous_failed(said_of(e))
          live_log("warn", "card-outbox", "the previous station did not exit", { "error": jstr(said_of(e)) })
        }
      }
    }),
  )
  ignore(
    self.host.rt.fork(name="card outcomes stop", async fn() {
      ignore(self.bus.stopped.wait())
      worker.close()
    }),
  )
}

///|
/// card-outbox-worker.ts `save`: a card's outcome queued (`{thread, ts, agent, field, close, outcome}`), the card
/// closed in the same write where asked and the close told; the worker restates it. Its id in the queue.
fn P52::outcome_save(self : P52, item : Json) -> Json raise {
  guard self.card_outcomes is Some(worker) else { raise LiveError("the cards' outcomes are not kept yet") }
  self.threads.set_now(wall_ms().to_double())
  let id = worker.save(@store_threads.CardOutcome::from_json(jv_of(item)), () => ()) catch {
    e => {
      p52_told_threads(self.bus, self.threads)
      raise e
    }
  }
  p52_told_threads(self.bus, self.threads)
  self.outcomes_follow()
  Json::string(id)
}

///|
/// What the worker writes as it goes (a card restated, one let go) told on the bus as the store's own writes are:
/// after each of its turns while it goes through the queue, again after a busy write's retry while one waits. A long
/// scan's own pages tell what came before them (`card_page`); its end wakes the worker, which the next save follows.
fn P52::outcomes_follow(self : P52) -> Unit {
  guard self.card_outcomes is Some(worker) && !self.outcomes_following else { return }
  self.outcomes_following = true
  fn step() -> Unit {
    p52_told_threads(self.bus, self.threads)
    let st = worker.state()
    let going = jtext(st, "cursor") != Some("0") || jfield(st, "again") is True
    let waiting = jitems(jfield(st, "deferred")).length() > 0
    if self.bus.stopped.is_done() || !(going || waiting) {
      self.outcomes_following = false
    } else {
      // timer: a retry after a failure (a busy write's, the worker's RETRY_MS) where one waits; else its next turn
      self.host.rt.after(if going { 0 } else { 250 }, () => step())
    }
  }
  self.host.rt.after(0, () => step())
}

///|
/// The threads' store's changes told to the bus's listeners.
fn p52_told_threads(bus : LiveBus, threads : @store_threads.Store) -> Unit {
  let sent = threads.sent.copy()
  threads.sent.clear()
  for c in sent {
    bus.notify_store(c)
  }
  // (what it found not prepared yet, asked of the builders: agents.ts `requestSessionChat`, `followLatestThreadRequests`)
  bus.drain_thread_requests(threads)
}

///|
fn P52::profiles(self : P52) -> Array[Json] {
  jitems(jfield(self.config, "profiles"))
}

///|
/// The agent home (config.json `agentHome`, else `<data>/agent`).
fn P52::agent_home(self : P52) -> String {
  match jtext(self.config, "agentHome") {
    Some(h) if h != "" => h
    _ => path([self.data, "agent"])
  }
}

///|
fn P52::workspaces(self : P52) -> Array[String] {
  match self.hub {
    Some(h) => (h.world.workspaces)()
    None => []
  }
}

///|
fn P52::ws_of(self : P52, key : String) -> String? {
  let v = self.store("sessionWs", [jstr(key)]) catch { _ => return None }
  match v {
    String(w) => Some(w)
    _ => None
  }
}

///|
/// Session `key`'s MEMORY.md: its workspace's (agent-home.ts `workspaceAgentHome`).
fn P52::memory_path(self : P52, key : String) -> String {
  let home = self.agent_home()
  let dir = attempt(() => self.files.workspace_agent_home_path(home, self.ws_of(key), self.workspaces().get(0))).unwrap_or(home)
  self.files.agent_home_paths(dir).0
}

///|
/// Where the session's repositories are cloned (hub.ts `reposDir`).
fn P52::repos_dir(self : P52) -> String {
  path([self.data, "repos"])
}

///|
fn P52::own_name(self : P52) -> String {
  match (self.bus.cloud_state.val)() {
    Some(s) => jtext(s, "station_name").unwrap_or(jtext(s, "name").unwrap_or(""))
    None => ""
  }
}

///|
/// What its process opening needs read first (actor.ts `linkSkills`): its workspace's skills linked where it runs, its
/// memory as it is now.
async fn P52::link_skills(self : P52, row : Json) -> String {
  let key = jtext(row, "key").unwrap_or("")
  let memory_path = self.memory_path(key)
  ignore(attempt(() => @drive.mkdir(@nodepath.dirname(sep(), memory_path), true)))
  let memory = @agent_runtimes.read_memory(self.host, memory_path)
  if jtext(row, "cwd") is None {
    let workspace = jtext(row, "workspace").unwrap_or("")
    let skills = path([@nodepath.dirname(sep(), memory_path), "skills"])
    self.files.session_skills(workspace, skills) catch {
      e => live_log("warn", "session", "its workspace's skills not linked where it runs", { "session": jstr(key), "error": jstr(said_of(e)) })
    }
  }
  memory
}

///|
/// What every session is told of how still.fail works (instructions.ts `sessionInstructions`).
fn P52::instructions(self : P52, row : Json, key : String, memory : String, project : String?) -> String {
  @agent_runtimes.session_instructions(
    jtext(row, "workspace").unwrap_or(""),
    project,
    self.repos_dir(),
    self.memory_path(key),
    memory,
    site=self.site_instructions,
    station=self.own_name(),
  )
}

///|
/// What its chat was opened with (presets.ts `presetCopyOf`): its words, told after the station's instructions.
async fn P52::preset_words(self : P52, workspace : String) -> String {
  let copy = @session_chats.preset_copy_of(self.chats_world(), workspace) catch { _ => return "" }
  match copy {
    Null => ""
    c => @session_chats.preset_instructions(c)
  }
}

///|
/// How a session's runtime session is opened on `profile` (actor.ts `openOptions`).
async fn P52::open_options(self : P52, row : Json, profile : Json, memory : String) -> Json {
  let key = jtext(row, "key").unwrap_or("")
  let cwd = jtext(row, "cwd")
  let skills = match cwd {
    Some(_) => Json::null()
    None => jstr(path([@nodepath.dirname(sep(), self.memory_path(key)), "skills"]))
  }
  let model = match jtext(row, "model") {
    Some(m) => {
      let spelled = match jfield(profile, "spellings") {
        Object(s) => s.get(m).map(v => match v { String(x) => x; _ => m })
        _ => None
      }
      jstr(spelled.unwrap_or(m))
    }
    None => Json::null()
  }
  let instructions = match cwd {
    Some(_) => ""
    None => self.instructions(row, key, memory, None) + self.preset_words(jtext(row, "workspace").unwrap_or(""))
  }
  let m : Map[String, Json] = Map([])
  m["key"] = jstr(key)
  m["profile"] = profile
  m["cwd"] = jstr(cwd.unwrap_or(jtext(row, "workspace").unwrap_or("")))
  if model != Json::null() {
    m["model"] = model
  }
  match jfield(row, "effort") {
    String(_) as e => m["effort"] = e
    _ => ()
  }
  match jfield(row, "context") {
    Number(_) as c => m["context"] = c
    _ => ()
  }
  match jfield(row, "fast") {
    True | False as f => m["fast"] = f
    _ => ()
  }
  // (Claude Code run interactively for this chat: actor.ts `openOptions`)
  if jfield(row, "tui") is True {
    m["tui"] = Json::boolean(true)
  }
  m["instructions"] = jstr(instructions)
  if skills != Json::null() {
    m["skills"] = skills
  }
  m["mcpToken"] = jfield(row, "token")
  m["mcpUrl"] = jstr(self.door_url)
  m["route"] = jstr(key)
  Json::object(m)
}

///|
/// The profile a session's runtime starts on now (accounts.ts `runOn`): the accounts' answer where they are made
/// (another part's, `accounts.runOn`), else its own while it is one of the station's, else the first that runs its
/// runtime, else the machine's own login of its runtime.
async fn P52::run_on(self : P52, key : String, holding : Bool, across : Bool) -> Json {
  // (the accounts' pool, P5-3's: its token, its home and its env as the session's account now)
  match (try { Ok((self.bus.jobs_ask.val)("accounts.runOn", { "key": jstr(key), "holding": jb(holding), "across": jb(across) })) } catch { e => Err(e) }) {
    Ok(Object(_) as p) => return p
    Ok(_) => ()
    Err(e) =>
      live_log("warn", "agents", "the accounts did not say a profile; the session's own is taken", {
        "session": jstr(key),
        "error": jstr(said_of(e)),
      })
  }
  let row = self.store("getSession", [jstr(key)]) catch { _ => Json::null() }
  let runtime = jtext(row, "runtime").unwrap_or("claude")
  let profiles = self.profiles()
  let own = jtext(row, "profile")
  let runs = (p : Json) => {
    let rts = @session_hub.profile_runtimes(p)
    rts.length() == 0 || rts.contains(runtime)
  }
  match own {
    Some(id) =>
      match profiles.iter().find_first(p => jtext(p, "id") == Some(id) && runs(p)) {
        Some(p) => return p
        None => ()
      }
    None => ()
  }
  match profiles.iter().find_first(p => runs(p) && @session_hub.enabled(p)) {
    Some(p) => p
    None =>
      {
        "id": jstr(own.unwrap_or("machine")),
        "runtimes": Json::array([jstr(runtime)]),
        "access": { "kind": jstr("machine") },
        "home": jstr(homedir()),
      }
  }
}

///|
/// The runtime session of session `key` opened (actor.ts `openAgent`).
async fn P52::open_agent(
  self : P52,
  key : String,
  stopped : Array[Json],
  read_back : Bool,
  profile_before : String?,
  set_runtime : (String) -> Unit,
  generation : () -> Int,
  listener : (Int) -> (@jsjson.JValue) -> Unit,
) -> (Agent, Json) {
  let hub = self.the_hub()
  let initial = self.store("getSession", [jstr(key)])
  if initial == Json::null() {
    raise LiveError("session \{key} disappeared")
  }
  guard @session_hub.runtime_named(jtext(initial, "runtime").unwrap_or("")) is Some(was) else {
    raise LiveError("session \{key} runs an unknown runtime \{jtext(initial, "runtime").unwrap_or("")}")
  }
  set_runtime(was)
  let profile = self.run_on(key, false, true)
  let row = self.store("getSession", [jstr(key)])
  guard @session_hub.runtime_named(jtext(row, "runtime").unwrap_or("")) is Some(runtime) else {
    raise LiveError("session \{key} runs an unknown runtime")
  }
  if runtime != was {
    set_runtime(runtime)
  }
  guard self.drivers.get(runtime) is Some(driver) else { raise LiveError("no driver for \{runtime}") }
  let memory = self.link_skills(row)
  let base = self.open_options(row, profile, memory)
  let runtime_sessions = jitems(self.store("runtimeSessions", [jstr(key)]) catch { _ => Json::array([]) })
  let cleared = jfield(row, "runtimeSessionId") == Json::null() && runtime_sessions.length() > 0
  let base = if cleared && jtext(row, "cwd") is Some(cwd) {
    match base {
      Object(m) => {
        let c = m.copy()
        c["instructions"] = jstr(self.instructions(row, key, memory, Some(cwd)))
        Json::object(c)
      }
      other => other
    }
  } else {
    base
  }
  // (a directory it may not read: told as it is; the session's own workspace is the station's)
  let cwd = jtext(base, "cwd").unwrap_or("")
  if jtext(row, "cwd") is None && attempt(() => @drive.stat(cwd)) is Err(_) {
    ignore(attempt(() => @drive.mkdir(cwd, true)))
  }
  let gen = generation()
  let events = listener(gen)
  let told : Map[String, Json] = Map([])
  told["afresh"] = Json::null()
  told["resumeLost"] = jb(false)
  told["readBackTold"] = jb(false)
  told["stoppedNote"] = Json::null()
  let prev_id = jtext(row, "runtimeSessionId")
  match prev_id {
    Some(id) => ignore(self.store("ranIn", [jstr(key), jstr(id), Json::null()]) catch { _ => Json::null() })
    None => ()
  }
  let profile_id = jtext(profile, "id").unwrap_or("")
  let afresh = match prev_id {
    Some(id) => hub.starts_afresh(key, id, profile_id, profile_before) catch { _ => None }
    None => None
  }
  let subagents = stopped.filter(t => jtext(t, "kind") == Some("agent")).map(t => jtext(t, "id").unwrap_or(""))
  let mut resumable : Array[String] = []
  let agent = match (afresh, prev_id) {
    (Some(note), Some(_)) => {
      let a = (driver.open)(base, events)
      told["afresh"] = jstr(note)
      a
    }
    (None, Some(id)) => {
      let resumed = match base {
        Object(m) => {
          let c = m.copy()
          c["resume"] = jstr(id)
          Json::object(c)
        }
        other => other
      }
      match (try { Ok((driver.open)(resumed, events)) } catch { e => Err(e) }) {
        Ok(a) => {
          resumable = subagents
          a
        }
        Err(e) => {
          if non_session_open_error(e) {
            raise e
          }
          live_log("warn", "session", "resume failed; starting a new runtime session", { "session": jstr(key), "id": jstr(id), "error": jstr(said_of(e)) })
          told["resumeLost"] = jb(true)
          (driver.open)(base, events)
        }
      }
    }
    _ => {
      let a = (driver.open)(base, events)
      if cleared {
        told["afresh"] = jstr(hub.told_cleared(key, read_back~) catch { _ => @agent_runtimes.cleared(key, []) })
      }
      told["readBackTold"] = jb(true)
      a
    }
  }
  let id = (agent.id)()
  ignore(self.store("ranIn", [jstr(key), jstr(id), jstr(profile_id)]) catch { _ => Json::null() })
  if prev_id != Some(id) {
    ignore(self.store("setRuntimeSessionId", [jstr(key), jstr(id)]))
  }
  if stopped.length() > 0 {
    told["stoppedNote"] = jstr(@agent_runtimes.background_stopped(stopped.map(jv_of), resumable))
  }
  told["generation"] = ji(gen)
  told["identity"] = { "runtime": jstr(runtime), "model": jfield(row, "model"), "effort": jfield(row, "effort") }
  told["profile"] = jstr(profile_id)
  (agent, Json::object(told))
}

///|
/// Whether opening a runtime session failed for something other than the conversation itself (actor.ts
/// `isNonSessionOpenError`).
fn non_session_open_error(e : Error) -> Bool {
  match e {
    @agent_drivers.Said(_) | CommandMissing(_) => true
    other => {
      let reason = @agent_drivers.failure_of(said_of(other))
      ["network", "auth", "refused", "blocked", "rate_limit", "overloaded"].contains(reason)
    }
  }
}

///|
/// Its process takes how its session runs now in place, where it runs on the same profile (actor.ts `retuneAgent`).
async fn P52::retune_agent(self : P52, key : String, agent : Agent, runtime : String, profile_now : String?, restart : Bool, holding : Bool) -> Json {
  let before = self.store("getSession", [jstr(key)])
  if before == Json::null() {
    return Json::null()
  }
  let profile = self.run_on(key, holding, true)
  let current = self.store("getSession", [jstr(key)])
  guard jtext(current, "runtime") == Some(runtime) else { return Json::null() }
  if restart || jtext(profile, "id") != profile_now {
    return Json::null()
  }
  let memory = self.link_skills(current)
  if (agent.retune)(self.open_options(current, profile, memory)) {
    { "runtime": jstr(runtime), "model": jfield(current, "model"), "effort": jfield(current, "effort") }
  } else {
    Json::null()
  }
}

///|
/// The station's own words posted to the thread people spoke in last, and recorded there (actor.ts `postNotice`).
async fn P52::post_notice(self : P52, key : String, text : String, profile : Json, runtime : Json, change : Json, where_~ : (Json) -> Unit) -> Unit {
  let latest = self.store("latestThread", [jstr(key)])
  if latest == Json::null() {
    live_log("warn", "session", "no thread to post a notice to", { "session": jstr(key), "text": jstr(text) })
    return
  }
  let thread = jfield(latest, "thread")
  let connect = jtext(latest, "connect").unwrap_or("")
  let ts = self.chat_post(connect, jtext(thread, "channel").unwrap_or(""), jtext(thread, "threadTs").unwrap_or(""), @session_hub.mark_notice(text), []) catch {
    e => {
      live_log("warn", "session", "notice failed", { "session": jstr(key), "error": jstr(said_of(e)) })
      return
    }
  }
  let message : Map[String, Json] = Map([])
  message["thread"] = jfield(thread, "id")
  message["ts"] = jstr(ts)
  message["authorKind"] = jstr("station")
  message["author"] = jstr("station")
  message["text"] = jstr(text)
  message["profile"] = profile
  message["runtime"] = runtime
  message["attachments"] = Json::array([])
  message["quotes"] = Json::array([])
  message["declared"] = Json::null()
  message["client"] = Json::null()
  message["card"] = Json::null()
  message["options"] = Json::null()
  message["agentIdentity"] = Json::null()
  if change != Json::null() {
    message["change"] = change
  }
  let inserted = self.store("insertMessage", [Json::object(message)])
  let n = match inserted {
    Array([n, ..]) => n
    other => jfield(other, "n")
  }
  where_(Json::array([jfield(thread, "id"), n, jstr(ts)]))
}

///|
/// What the thread people spoke in last ends with, where the station said it (actor.ts `lastStationSaid`).
fn P52::last_station_said(self : P52, key : String) -> Json raise {
  let latest = self.store("latestThread", [jstr(key)])
  if latest == Json::null() {
    return Json::null()
  }
  let entries = jitems(self.store("entriesBefore", [jfield(jfield(latest, "thread"), "id"), Json::null(), ji(1)]))
  match entries.last() {
    Some(last) if jtext(last, "authorKind") is Some("station" | "ember" | "stillfail") => jfield(last, "text")
    _ => Json::null()
  }
}

///|
/// A post to a chat: the station's own chats' (a new ts, the message the store's), else the part's that has the
/// connect (Slack's, Feishu's, Comma's, a group's: `chat.post` of the coordinators').
async fn P52::chat_post(self : P52, connect : String, channel : String, thread_ts : String, text : String, files : Array[Json]) -> String {
  if connect == @session_hub.internal_connect {
    if channel != "CHAT" && channel != "EMBER" {
      raise LiveError("no still.fail chat \{channel}/\{thread_ts}")
    }
    return @session_hub.next_ts_at(wall_ms().to_double())
  }
  match (self.bus.coord_ask.val)("chat.post", {
    "connect": jstr(connect),
    "thread": { "channel": jstr(channel), "threadTs": jstr(thread_ts) },
    "text": jstr(text),
    "files": Json::array(files),
  }) {
    String(ts) => ts
    Object(m) if m.get("ts") is Some(String(ts)) => ts
    _ => raise LiveError("connect \{connect} is not connected")
  }
}

///|
/// What a turn is prompted with (actor.ts `promptFor`).
async fn P52::prompt_for(self : P52, key : String, now : Double, handed : Json, lost : Bool, stopped : Json, afresh : Json, compacted : Bool) -> String {
  let hub = self.the_hub()
  let row = self.store("getSession", [jstr(key)])
  let handed = match handed {
    String(s) => s
    _ => ""
  }
  let continued = match jtext(row, "cwd") {
    Some(cwd) if !(self.store("hasTurns", [jstr(key)]) is True) =>
      Some(@agent_runtimes.continued_here(self.instructions(row, key, self.link_skills(row), Some(cwd))))
    _ => None
  }
  let mut prompt = if lost { hub.told_resume_lost(key) + "\n\n" + handed } else { handed }
  match stopped {
    String(s) => prompt = s + "\n\n" + prompt
    _ => ()
  }
  let afresh = match afresh {
    String(s) => Some(s)
    _ => None
  }
  if lost || afresh is Some(_) || compacted {
    match (hub.told_long_chat(key) catch { _ => None }) {
      Some(long) => prompt = long + "\n\n" + prompt
      None => ()
    }
  }
  match afresh {
    Some(a) => prompt = a + "\n\n" + prompt
    None => ()
  }
  match continued {
    Some(c) => prompt = c + "\n\n" + prompt
    None => ()
  }
  let latest = @agent_runtimes.latest().to_double()
  let told = jnum_of(Json::object({ "n": self.store("toldNotes", [jstr(key)]) }), "n").unwrap_or(latest)
  if told < latest {
    let workspace = jtext(row, "workspace")
    let full = match workspace {
      Some(w) => path([w, ".stillfail-instructions.md"])
      None => ""
    }
    match workspace {
      Some(w) => {
        let text = self.instructions(row, key, self.link_skills(row), jtext(row, "cwd")) +
          (if jtext(row, "cwd") is None { self.preset_words(w) } else { "" })
        ignore(write_text_mode(full, text, 0))
      }
      None => ()
    }
    ignore(self.store("setToldNotes", [jstr(key), jn(latest)]))
    prompt = @agent_runtimes.untold(told, full) + "\n\n" + prompt
  }
  @session_hub.timed(prompt, now)
}

///|
/// What it is handed now, formatted (mb-actor.ts `#pendingAndFormat`, actor.ts `formatDelivery`): None where nothing
/// is (and none is asked for).
async fn P52::pending_and_format(self : P52, key : String, allow_empty : Bool, cancelled : () -> Bool) -> Json {
  let pending = jitems(@readops.pending_deliveries(self.bus.db, { "key": jstr(key) }))
  if cancelled() {
    raise LiveError("delivery cancelled")
  }
  if !allow_empty && pending.length() == 0 {
    return Json::null()
  }
  let (text, widgets) = self.format_delivery(key, pending, cancelled)
  if cancelled() {
    raise LiveError("delivery cancelled")
  }
  let light = pending.map(m => {
    let message = jfield(m, "message")
    let person = if jtext(message, "authorKind") == Some("person") {
      jstr(@session_hub.person_ref(m))
    } else {
      Json::null()
    }
    ({
      "connect": jfield(m, "connect"),
      "channel": jfield(m, "channel"),
      "threadTs": jfield(m, "threadTs"),
      "surface": jfield(m, "surface"),
      "ts": jfield(message, "ts"),
      "thread": jfield(message, "thread"),
      "n": jfield(message, "n"),
      "apart": jb(jfield(message, "apart") is True),
      "authorKind": jfield(message, "authorKind"),
      "person": person,
      "handed": handed_of(m),
    } : Json)
  })
  { "pending": Json::array(light), "text": jstr(text), "widgets": widgets }
}

///|
/// store/rows.ts `handedOf`: where a message handed is (its thread, its number, whether it came apart).
fn handed_of(m : Json) -> Json {
  let message = jfield(m, "message")
  { "thread": jfield(message, "thread"), "n": jfield(message, "n"), "apart": jb(jfield(message, "apart") is True) }
}

///|
/// actor.ts `formatDelivery`.
async fn P52::format_delivery(self : P52, key : String, said : Array[Json], cancelled : () -> Bool) -> (String, Json) {
  let threads = said.map(m => jfield(jfield(m, "message"), "thread"))
  let heard = jitems(self.store("heardThreads", [jstr(key), Json::array(threads)]))
  let new_threads = threads.filter(t => !heard.contains(t)).filter_map(t => match t { Number(n, ..) => Some(n); _ => None })
  let names : Array[(String, String)] = []
  for m in said {
    let message = jfield(m, "message")
    let author = jtext(message, "author").unwrap_or("")
    if names.iter().any(x => x.0 == author) {
      continue
    }
    match jtext(message, "authorKind") {
      Some("agent") => {
        let letter = jfield(message, "letter")
        let name = if jtext(letter, "way") == Some("in") && jtext(letter, "title").unwrap_or("") != "" {
          jtext(letter, "title").unwrap_or("")
        } else {
          self.agent_name(author, jfield(message, "thread"))
        }
        names.push((author, name))
      }
      Some("person") =>
        match self.user_name(jtext(m, "connect").unwrap_or(""), author) {
          Some(n) => names.push((author, n))
          None => ()
        }
      _ => ()
    }
  }
  let selves : Array[(String, String)] = []
  for m in said {
    let connect = jtext(m, "connect").unwrap_or("")
    if selves.iter().any(x => x.0 == connect) || connect == @session_hub.internal_connect {
      continue
    }
    match (self.bus.coord_ask.val)("chat.bot", { "connect": jstr(connect) }) {
      Object(_) as bot =>
        match (jtext(bot, "name"), jtext(bot, "user")) {
          (Some(name), Some(user)) if name != "" && user != "" => selves.push((connect, "\{name} (<@\{user}>)"))
          (Some(name), _) if name != "" => selves.push((connect, name))
          _ => ()
        }
      _ => ()
    }
  }
  let from_chat : Array[(Int, Json)] = []
  for i, m in said {
    if !(jfield(jfield(m, "message"), "apart") is True) {
      from_chat.push((i, m))
    }
  }
  let positions = Json::array(from_chat.map(x => { "thread": jfield(jfield(x.1, "message"), "thread"), "n": jfield(jfield(x.1, "message"), "n") }))
  let later = jitems(self.store("postsAfter", [jstr(key), positions]) catch { _ => Json::array([]) })
  let posts : Map[Int, String] = Map([])
  for j, x in from_chat {
    match later.get(j) {
      Some(String(ts)) => posts[x.0] = ts
      _ => ()
    }
  }
  let cards : Map[Int, @agent_runtimes.CardChange] = Map([])
  for i, m in said {
    let message = jfield(m, "message")
    if jfield(message, "apart") is True || jtext(message, "authorKind") != Some("person") {
      continue
    }
    if cancelled() {
      raise LiveError("delivery cancelled")
    }
    let state = @readops.delivery_card_state(self.bus.db, { "thread": jfield(message, "thread"), "n": jfield(message, "n") })
    if state == Json::null() {
      continue
    }
    let card = jfield(state, "card")
    let special = if jtext(jfield(card, "vault"), "request") is Some(r) {
      Some("Use secret_reask {request: \{jstr(r).stringify()}} if the request is still needed.")
    } else if jtext(jfield(card, "adb"), "request") is Some(_) {
      Some("Use phone_use {reason: \{jstr(jtext(jfield(card, "adb"), "reason").unwrap_or("")).stringify()}, reask: true} if the request is still needed.")
    } else if jtext(jfield(card, "signin"), "site") is Some(site) {
      Some("Use sign_in {site: \{jstr(site).stringify()}, reask: true} if the sign-in is still needed.")
    } else if jtext(card, "type") == Some("login") {
      Some("Check the login with its tool; if it still needs the person, post its login card again.")
    } else {
      None
    }
    cards[i] = {
      ended_author: jtext(jfield(state, "ended"), "author").unwrap_or(""),
      ended_ts: jtext(jfield(state, "ended"), "ts").unwrap_or(""),
      current_ts: jtext(jfield(state, "current"), "ts"),
      special,
    }
  }
  let text = @agent_runtimes.format_inbound(said.map(jv_of), new_threads, names, selves, posts~, cards~, self_key=key)
  let models = jitems(self.store("untoldWidgetModels", [jstr(key)]) catch { _ => Json::array([]) })
  let widgets = Json::array(models.map(w => Json::array([jfield(w, "path"), jfield(w, "model")])))
  let told = @agent_runtimes.format_widget_models(models.map(jv_of))
  let all = if told == "" { text } else if text == "" { told } else { text + "\n\n" + told }
  (all, widgets)
}

///|
/// What another agent goes by in a thread (actor.ts `agentName`).
fn P52::agent_name(self : P52, key : String, thread : Json) -> String {
  let row = self.store("getSession", [jstr(key)]) catch { _ => Json::null() }
  if row == Json::null() {
    return "another agent"
  }
  let runtime = @session_hub.runtime_named(jtext(row, "runtime").unwrap_or("")).unwrap_or("claude")
  let label = @session_hub.runtime_label(runtime)
  ignore(thread)
  match jtext(row, "model") {
    Some(m) => "\{label} \{m}"
    None => label
  }
}

///|
/// A person's name as their chat names them: the station's own chats' (the address, an email; `local` its admin), else
/// the connect's part's.
async fn P52::user_name(self : P52, connect : String, user : String) -> String? {
  if connect == @session_hub.internal_connect {
    return if user == "UEMBER" { None } else if user == "local" { Some(if self.lang() == "zh" { "管理员" } else { "Admin" }) } else { Some(user) }
  }
  match (self.bus.coord_ask.val)("chat.userName", { "connect": jstr(connect), "user": jstr(user) }) {
    String(s) => Some(s)
    _ => None
  }
}

///|
/// `text` as the agent is handed it, after what people chose on its cards (actor.ts `handedWithChoices`).
async fn P52::handed_with_choices(self : P52, key : String, text : String) -> (String, () -> Unit) {
  let moved_said = self.store("untoldMovedNote", [jstr(key)]) catch { _ => Json::null() }
  let moved = match moved_said {
    String(s) => Some(s)
    _ => None
  }
  let chose = jitems(self.store("untoldCardChoices", [jstr(key)]))
  let (rest, told) = if chose.length() == 0 {
    (text, () => ())
  } else {
    let names : Array[(String, String)] = []
    for c in chose {
      let by = jtext(c, "by").unwrap_or("")
      if names.iter().any(x => x.0 == by) {
        continue
      }
      let via = jitems(self.store("threadSessions", [jfield(c, "thread")])).iter().find_first(m => jtext(m, "session") == Some(key))
      match via {
        Some(m) =>
          match self.user_name(jtext(m, "connect").unwrap_or(""), by) {
            Some(n) => names.push((by, n))
            None => ()
          }
        None => ()
      }
    }
    let said = @agent_runtimes.format_card_choices(chose.map(jv_of), names, wall_ms().to_double())
    (if text == "" { said } else { said + "\n\n" + text }, () => ignore(self.store("markCardChoicesTold", [jstr(key), Json::array(chose)]) catch { _ => Json::null() }))
  }
  match moved {
    Some(m) =>
      (if rest == "" { m } else { m + "\n\n" + rest }, () => {
        told()
        ignore(self.store("markMovedNoteTold", [jstr(key)]) catch { _ => Json::null() })
      })
    None => (rest, told)
  }
}

///|
/// A turn that ended with no state on a card it posted, still waiting: it ends need_human on it (mb-actor.ts
/// `cardAsks`).
fn P52::card_asks(self : P52, key : String, id : String, started : Double?) -> Json raise {
  let recent = self.store("recentSessionThreads", [jstr(key)])
  let mut found : Json? = None
  for t in jitems(jfield(recent, "threads")) {
    let thread = jfield(jfield(t, "thread"), "id")
    let card = match self.store("pendingCard", [thread]) {
      Array([c, ..]) => c
      _ => continue
    }
    if jtext(card, "authorKind") != Some("agent") || jtext(card, "author") != Some(key) {
      continue
    }
    let created = jnum_of(card, "createdAt").unwrap_or(0.0)
    match started {
      Some(s) if created < s => continue
      _ => ()
    }
    match found {
      Some(f) if created < jnum_of(f, "createdAt").unwrap_or(0.0) => ()
      _ => found = Some(card)
    }
  }
  guard found is Some(card) else { return jb(false) }
  ignore(self.store("setAbout", [jstr(id), Json::array([jfield(card, "thread"), jfield(card, "n"), jfield(card, "ts")])]))
  ignore(self.store("declareTurn", [jstr(id), jstr("need_help"), Json::null()]))
  jb(true)
}

///|
/// A turn its background work woke, that waits on: what the turn before asked is asked still (mb-actor.ts `keepAsk`).
fn P52::keep_ask(self : P52, key : String, id : String, before : Json) -> Json raise {
  guard jnum_of(before, "endedAt") is Some(since) else { return jb(false) }
  let threads = jitems(jfield(self.store("recentSessionThreads", [jstr(key)]), "threads")).map(t => jfield(jfield(t, "thread"), "id"))
  for thread in threads {
    if self.store("cardClosedSince", [thread, jn(since)]) is True {
      return jb(false)
    }
  }
  let about = jfield(before, "about")
  let mut asked : Json = match about {
    Object(_) if jnum_of(about, "seq") is Some(_) => Json::array([jfield(about, "thread"), jfield(about, "seq"), jfield(about, "ts")])
    _ => Json::null()
  }
  if asked == Json::null() {
    let during = Json::array([jn(jnum_of(before, "startedAt").unwrap_or(0.0)), jn(since)])
    for thread in threads {
      match self.store("askingMessage", [thread, Json::null(), during]) {
        Array([m, ..]) => {
          asked = Json::array([jfield(m, "thread"), jfield(m, "n"), jfield(m, "ts")])
          break
        }
        _ => ()
      }
    }
  }
  match jtext(before, "need") {
    Some(need) if need != "" => ignore(self.store("setNeed", [jstr(id), jstr(need)]))
    _ => ()
  }
  ignore(self.store("setAbout", [jstr(id), asked]))
  ignore(self.store("declareTurn", [jstr(id), jstr("need_help"), Json::null()]))
  jb(true)
}

///|
/// What its allowance, asked again, says it ran into (accounts.ts `limitAfter`): the accounts' answer.
async fn P52::limit_after(self : P52, key : String, profile : Json) -> Json {
  let row = self.store("getSession", [jstr(key)]) catch { _ => Json::null() }
  match (self.bus.jobs_ask.val)("accounts.limitAfter", { "profile": profile, "model": jfield(row, "model") }) {
    Object(m) if m.contains("limit") => Json::object(m)
    _ => Json::null()
  }
}

///|
fn P52::can_update_codex(self : P52) -> Bool {
  self.drivers.contains("codex")
}

///|
/// Updates the machine's Codex and waits until it serves new turns (updates' `updateOldCodex`): the updates' part.
async fn P52::update_codex(self : P52, before : String?) -> Unit {
  match (self.bus.coord_ask.val)("updates.updateOldCodex", { "running": jopt(before) }) {
    Object(m) if m.get("error") is Some(String(e)) => raise LiveError(e)
    _ => ()
  }
  // (agents.ts `updateOldCodex`: the old hosts marked before any conversation can retry; other turns keep running there)
  match self.drivers.get("codex") {
    Some(d) => ignore((d.ask)("runtimeChanged", { "replaced": jb(before is None), "drainBusy": jb(true) }))
    None => ()
  }
}

///|
/// The live view told a session's runtime's step (sessions/live.ts `event`): the program's `#live`.
fn P52::live_event(self : P52, key : String, event : Json) -> Unit {
  match self.actors_program {
    Some(p) => ignore(p.post({ "call": ji(0), "actor": jstr("#live"), "method": jstr("event"), "args": Json::array([jstr(key), event]) }))
    None => ()
  }
}

///|
/// What a session's transcript said last, read before its turn is said to be over (live.ts `turnEnded`).
async fn P52::live_turn_ended(self : P52, key : String) -> Unit {
  match self.actors_program {
    Some(p) => ignore(p.call("#live", "turnEnded", [jstr(key)]))
    None => ()
  }
}

///|
/// What the turn does, said where its chats show it (a platform's status line): the connect's part's.
fn P52::working(self : P52, key : String, working : Array[Json], status : Json) -> Unit {
  let text = match status {
    String("") => ""
    String("thinking") => self.words.tr("station.status.thinking", lang=self.lang())
    Object(_) => tool_status(self, jtext(status, "tool").unwrap_or(""))
    _ => ""
  }
  for w in working {
    let connect = jtext(w, "connect").unwrap_or("")
    if connect == @session_hub.internal_connect {
      continue
    }
    ignore(
      self.host.rt.fork(name="working", async fn() {
        ignore((self.bus.coord_ask.val)("chat.working", {
          "connect": jstr(connect),
          "thread": { "channel": jfield(w, "channel"), "threadTs": jfield(w, "threadTs") },
          "ts": jfield(w, "ts"),
          "status": jstr(text),
          "page": jopt(self.page_of(key)),
        }))
      }),
    )
  }
}

///|
/// Where a turn stands said where its chat shows it (Slack's assistant status): the connect's part's.
fn P52::stands_at(self : P52, connect : Json, channel : Json, thread_ts : Json, stands : Json) -> Unit {
  if jtext(Json::object({ "c": connect }), "c") == Some(@session_hub.internal_connect) {
    return
  }
  ignore(
    self.host.rt.fork(name="stands at", async fn() {
      ignore((self.bus.coord_ask.val)("chat.standsAt", {
        "connect": connect,
        "thread": { "channel": channel, "threadTs": thread_ts },
        "stands": stands,
      }))
    }),
  )
}

///|
/// What a tool's run is said as on a status line (chat.ts `toolStatus`).
fn tool_status(ctx : P52, tool : String) -> String {
  let lower = tool.to_lower()
  let name = if lower.has_prefix("mcp__") {
    let rest = lower[5:].to_owned()
    match rest.find("__") {
      Some(at) => rest[at + 2:].to_owned()
      None => lower
    }
  } else {
    lower
  }
  let starts = (ps : Array[String]) => ps.iter().any(p => name.has_prefix(p))
  let key = if starts(["read", "grep", "glob", "ls", "list", "view", "search_files", "stat"]) {
    "station.status.readingFiles"
  } else if starts(["edit", "multiedit", "write", "apply_patch", "notebookedit", "delete", "copy"]) {
    "station.status.editingFiles"
  } else if starts(["bash", "shell", "exec", "exec_command", "local_shell", "unified_exec", "run"]) {
    "station.status.runningCommand"
  } else if starts(["websearch", "web_search", "search_query", "image_query"]) {
    "station.status.searchingWeb"
  } else if starts(["webfetch", "fetch", "browse"]) {
    "station.status.readingWeb"
  } else if starts(["task", "agent", "spawn"]) {
    "station.status.delegating"
  } else if starts(["slack"]) {
    "station.status.readingSlack"
  } else if starts(["chat_", "feishu"]) {
    "station.status.readingChat"
  } else if starts(["todowrite", "update_plan", "plan"]) {
    "station.status.planning"
  } else {
    "station.status.working"
  }
  ctx.words.tr(key, lang=ctx.lang())
}

///|
/// What the hub's deps answer a session (hub.ts `sessionDeps`), by name.
async fn P52::deps(self : P52, _key : String, name : String, args : Array[Json]) -> Json {
  let hub = self.the_hub()
  let a = (i : Int) => args.get(i).unwrap_or(Json::null())
  let s = (i : Int) => match a(i) {
    String(x) => x
    _ => ""
  }
  match name {
    "held" => jb(hub.held(s(0)))
    "stoppedNotice" => jopt(hub.stopped_notice(s(0)))
    "maxNudges" => jfield(self.config, "maxNudges")
    "nextTs" => jstr(hub.next_ts())
    "idle" => {
      hub.idle_now(s(0))
      Json::null()
    }
    "backgroundOnMessage" => {
      let row = self.store("getSession", [a(0)])
      if row == Json::null() {
        return jb(true)
      }
      match self.profiles().iter().find_first(p => jtext(p, "id") == jtext(row, "profile")) {
        Some(p) => if jfield(p, "backgroundOnMessage") is False { jb(false) } else { jb(true) }
        None => jb(true)
      }
    }
    "untitled" =>
      // titles.ts `untitledChat`: the chat session `key` last heard from, as its address, when it still has no name
      // (neither people nor an agent named it: its thread's title and autoTitle), is shown, a person has said something
      // there, and none of its other agents is at work. The session row has no title of the chat's: read there, every
      // chat was untitled however often it was named, and its agent was asked again at each turn's end.
      if jfield(self.config, "askToName") is True {
        let thread = jfield(self.store("latestThread", [a(0)]), "thread")
        let named = (k : String) => match jtext(thread, k) { Some(t) => t.trim() != ""; None => false }
        if !(thread is Object(_)) || !(jfield(thread, "hiddenAt") is Null) || named("title") || !(jfield(thread, "autoTitle") is Null) {
          return Json::null()
        }
        let id = jfield(thread, "id")
        if self.store("firstText", [id]) is Null {
          return Json::null()
        }
        let at_work = jitems(self.store("threadSessions", [id])).iter().any(m => {
          let session = jtext(m, "session").unwrap_or("")
          if session == "" || session == s(0) {
            return false
          }
          let last = self.store("lastTurn", [jstr(session)])
          hub.process_state(session) == "running" ||
          self.store("hasPending", [jstr(session)]) is True ||
          (last is Object(_) && (jfield(last, "endedAt") is Null || jtext(last, "declared") == Some("waiting")))
        })
        if at_work {
          Json::null()
        } else {
          jstr(@agent_runtimes.thread_address(jtext(thread, "channel").unwrap_or(""), jtext(thread, "threadTs").unwrap_or("")))
        }
      } else {
        Json::null()
      }
    "coldAfresh" => jb(hub.goes_afresh(s(0), jnum_of(Json::object({ "n": a(1) }), "n").unwrap_or(wall_ms().to_double())))
    "longChat" => jopt(hub.told_long_chat(s(0)))
    "ranIn" => self.store("ranIn", args)
    "spend" => (self.bus.jobs_ask.val)("accounts.spend", { "key": a(0), "ranOn": a(1), "model": a(2) })
    "refillsAt" =>
      match (self.bus.jobs_ask.val)("accounts.refillsAt", { "key": a(0) }) {
        Number(_) as n => n
        _ => jn(wall_ms().to_double() + 3_600_000.0)
      }
    "recheck" => (self.bus.jobs_ask.val)("accounts.recheck", { "profile": a(0) })
    "runtimeMissing" => {
      hub.runtime_updated(s(0))
      ignore((self.bus.coord_ask.val)("updates.runtimeMissing", { "runtime": a(0) }))
      Json::null()
    }
    "settled" => (self.bus.hub_ask.val)("settled", { "key": a(0), "state": a(1), "words": a(2) })
    "stopJobs" => {
      for id in jitems(self.store("runningWaitJobIds", [a(0)]) catch { _ => Json::array([]) }) {
        self.bus.jobs_stop(id)
      }
      Json::null()
    }
    "endJobs" => {
      for id in jitems(self.store("upJobIds", [a(0), jb(false)]) catch { _ => Json::array([]) }) {
        self.bus.jobs_stop(id)
      }
      Json::null()
    }
    "cleanArchive" => {
      self.cold_pack(s(0))
      Json::null()
    }
    _ => raise LiveError("a session asked the hub for \{name}, which it does not know")
  }
}

///|
/// An archived session's files put in cold storage (cold.ts `pack`): its room found, its strays stopped, what can be
/// made again cleaned, the room marked cold, then its workspace and history packed, under the room's lock.
async fn P52::cold_pack(self : P52, key : String) -> Unit {
  self.storage().cold_pack(key) catch {
    e => live_log("warn", "cold", "an archived session's files not put away", { "session": jstr(key), "error": jstr(said_of(e)) })
  }
}
