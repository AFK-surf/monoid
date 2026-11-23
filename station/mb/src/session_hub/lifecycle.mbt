// Sessions and chats as people make, change, archive and delete them (station/src/sessions/lifecycle.ts): a
// single-session connect bound, a chat opened and joined, a person's message said in it, a session of its own made,
// how a session runs changed, archived and shown again, idle ones archived by themselves, deleted. What is a part's of
// its own (the accounts' choice, the presets, the cold storage, the files) is the world's (world.mbt).

///|
fn trimmed(v : String?) -> String? {
  match v {
    Some(s) => {
      let t = trim(s)
      if t == "" {
        None
      } else {
        Some(t)
      }
    }
    None => None
  }
}

///|
/// internal.ts `chatKey`: a chat's session key, from its id (`c-…`): the one already made (the station's), else new.
pub fn Hub::chat_key(self : Hub, id : String) -> String {
  for p in [internal_connect, chat_key_prefix] {
    let k = "\{p}:\{id}"
    if self.get_session(k) is Some(_) {
      return k
    }
  }
  "\{chat_key_prefix}:\{id}"
}

///|
/// internal.ts `chatWorkspace`: where a chat session's workspace is, under the station's data.
pub fn chat_workspace(data : String, key : String) -> String {
  let at = index_of(key, ":")
  join_path([data, "sessions", slice(key, 0, to=at), slice(key, at + 1), "workspace"])
}

///|
/// `bindSingle`: points a single-session connect at a session (an existing one, or with None a new empty one), one at a
/// time a connect. The bound session's key.
pub async fn Hub::bind_single(self : Hub, connect_id : String, target : String?, title : String?, created_by : String?) -> String {
  self.one_single(connect_id, async fn() {
    let connect = self.connect(connect_id)
    if str_of(connect, "mode") != Some("single-session") {
      raise Refused("connect \{connect_id} is not single-session")
    }
    let bind_runtime = str_of(field(connect, "bind").unwrap_or(Json::null()), "runtime").unwrap_or("")
    match target {
      None => {
        let key = self.new_single_session_key(connect_id)
        self.create_session(key, connect, "all", None, trimmed(title), created_by)
        self.store.set_binding(Json::string(connect_id), Json::string(key))
        key
      }
      Some(t) => {
        let row = match self.get_session(t) {
          Some(r) => r
          None => raise Refused("unknown session \{t}")
        }
        let runtime = str_of(row, "runtime").unwrap_or("")
        if runtime != bind_runtime {
          raise Refused("session \{t} runs \{runtime}, the connect runs \{bind_runtime}")
        }
        match self.home() {
          Some(home) => {
            let cws = match str_of(connect, "workspace") {
              Some(w) => w
              None => home
            }
            if self.ws_of(Some(t)) != Some(cws) {
              raise Refused("session \{t} is in another workspace than the connect")
            }
          }
          None => ()
        }
        self.store.set_binding(Json::string(connect_id), Json::string(t))
        t
      }
    }
  })
}

///|
/// `ensureConversationChat`: idempotently ensures the conversation's home chat exists (§3.3).
pub fn Hub::ensure_conversation_chat(self : Hub, session : String, created_by : String, title : String?) -> Json raise {
  if (self.world.chat)(internal_connect) is None {
    raise Refused("still.fail chat is not available")
  }
  let row = match self.get_session(session) {
    Some(r) => r
    None => raise Refused("unknown session \{session}")
  }
  let existing = self.store.home_chat(Json::string(session))
  if existing != Json::null() {
    return existing
  }
  let anchor = self.store.conversation_of(session)
  let anchor_row = self.get_session(anchor).unwrap_or(row)
  let name = match title {
    Some(t) => Some(t)
    None => str_of(anchor_row, "title")
  }
  let thread = self.tw(() => self.threads.open_thread_of(
    Json::string(stillfail_surface),
    Json::string(internal_channel),
    Json::string(self.next_ts()),
    opt_str(name),
    Json::string(created_by),
    Json::string(anchor),
  ))
  let tid = field(thread, "id").unwrap_or(Json::null())
  let active = self.store.active_conversation_members(anchor, session)
  let ordered : Array[String] = []
  if active.contains(anchor) {
    ordered.push(anchor)
  }
  for m in active {
    if !ordered.contains(m) {
      ordered.push(m)
    }
  }
  for member in ordered {
    ignore(self.tw(() => self.threads.join_thread(tid, Json::string(member), Json::string(internal_connect))))
  }
  thread
}

///|
/// `openChat`: opens a chat on the station's pages with a session in it; the first made with a session is its own.
pub fn Hub::open_chat(self : Hub, session : String, created_by : String, title : String?) -> Json raise {
  if (self.world.chat)(internal_connect) is None {
    raise Refused("still.fail chat is not available")
  }
  let row = match self.get_session(session) {
    Some(r) => r
    None => raise Refused("unknown session \{session}")
  }
  let home = if self.store.home_chat(Json::string(session)) != Json::null() {
    None
  } else {
    Some(session)
  }
  let name = match title {
    Some(t) => Some(t)
    None => if home is Some(_) { str_of(row, "title") } else { None }
  }
  let thread = self.tw(() => self.threads.open_thread_of(
    Json::string(stillfail_surface),
    Json::string(internal_channel),
    Json::string(self.next_ts()),
    opt_str(name),
    Json::string(created_by),
    opt_str(home),
  ))
  ignore(self.tw(() => self.threads.join_thread(field(thread, "id").unwrap_or(Json::null()), Json::string(session), Json::string(internal_connect))))
  thread
}

///|
fn Hub::stillfail_chat(self : Hub, thread : Json) -> Json raise {
  let row = self.tw(() => self.threads.get_thread(thread))
  if row == Json::null() || str_of(row, "surface") != Some(stillfail_surface) {
    raise Refused("no still.fail chat \{js_string(thread)}")
  }
  row
}

///|
/// `addToThread`: brings another session into a chat on the station's pages (one of the same workspace).
pub fn Hub::add_to_thread(self : Hub, thread : Json, session : String) -> Unit raise {
  ignore(self.stillfail_chat(thread))
  let row = match self.get_session(session) {
    Some(r) => r
    None => raise Refused("unknown session \{session}")
  }
  let there = items(Some(self.tw(() => self.threads.thread_sessions(thread)))).get(0)
  match there {
    Some(m) if self.workspaces().length() > 0 =>
      if self.ws_of(str_of(m, "session")) != self.ws_of(Some(row_key(row))) {
        raise Refused("session \{session} is in another workspace than the chat")
      }
    _ => ()
  }
  ignore(self.tw(() => self.threads.join_thread(thread, Json::string(session), Json::string(internal_connect))))
}

///|
/// `say`: a person's message in a chat on the station's pages, recorded and delivered to every session in it. Its
/// entry number.
pub fn Hub::say(self : Hub, thread : Json, user : String, text : String, attachments? : Array[Json] = [], quotes? : Array[Json] = [], client? : String) -> Json raise {
  ignore(self.stillfail_chat(thread))
  if self.store.manually_archived(thread) {
    raise Refused(self.words.tr("station.chat.archived"))
  }
  let inserted = self.tw(() => self.threads.insert_message(
    jv({
      "thread": thread,
      "ts": Json::string(self.next_ts()),
      "authorKind": "person",
      "author": Json::string(user),
      "text": Json::string(text),
      "attachments": Json::array(attachments),
      "quotes": Json::array(quotes),
      "client": opt_str(client),
    }),
  ))
  let n = match inserted {
    Array(a) if a.length() > 0 => a[0]
    _ => Json::null()
  }
  let sessions = items(Some(self.tw(() => self.threads.thread_sessions(thread)))).map(m => str_of(m, "session").unwrap_or(""))
  self.deliver(thread, n, sessions, text)
  n
}

///|
/// What a new session of its own is made with (`NewChat`), as JSON.
/// `newSession`: a session of its own, talked to in the station's chat: the runtime, model and effort chosen by whoever
/// starts it, the profile given or picked by the pool. Its key and its chat.
pub async fn Hub::new_session(self : Hub, options : Json, lang? : String) -> (String, Json) {
  let lang = lang.unwrap_or(self.words.lang)
  let client = trimmed(str_of(options, "clientKey"))
  let key = match client {
    None => self.new_chat_key()
    Some(c) => {
      let made = Json::array([
        opt_str(str_of(options, "ws")),
        field(options, "createdBy").unwrap_or(Json::null()),
        Json::string(c),
      ])
      let digest = @memory.sha256_hex(@utf8.encode(js_json(made)))
      self.chat_key("c-\{slice(digest, 0, to=32)}")
    }
  }
  match client {
    None => self.session_made(key, client, options, lang)
    Some(_) => self.one_single("$new:\{key}", async fn() { self.session_made(key, client, options, lang) })
  }
}

///|
async fn Hub::session_made(self : Hub, key : String, client : String?, options : Json, lang : String) -> (String, Json) {
  let config = self.config()
  let created_by = str_of(options, "createdBy").unwrap_or("")
  let made = () => match self.get_session(key) {
    None => None
    Some(existing) => {
      match client {
        Some(c) => self.client_keys_made[key] = (c, self.now())
        None => ()
      }
      let home = self.store.home_chat(Json::string(key))
      let thread = if home != Json::null() {
        home
      } else {
        self.open_chat(key, created_by, str_of(existing, "title"))
      }
      ignore(self.tw(() => self.threads.join_thread(field(thread, "id").unwrap_or(Json::null()), Json::string(key), Json::string(internal_connect))))
      Some((key, thread))
    }
  }
  match made() {
    Some(r) => return r
    None => ()
  }
  let runtime = str_of(options, "runtime").unwrap_or("")
  let all = items(field(config, "profiles")).filter(p => profile_runtimes(p).contains(runtime))
  if all.length() == 0 {
    raise Refused("no \{runtime} profile configured")
  }
  let raw_list = match field(options, "profiles") {
    Some(Array(list)) => {
      let out = []
      for x in list {
        let t = trim(js_string(x))
        if t != "" && !out.contains(t) {
          out.push(t)
        }
      }
      out
    }
    _ => []
  }
  let wanted : Array[String]? = if raw_list.length() > 0 {
    Some(raw_list)
  } else {
    match str_of(options, "profile") {
      Some(p) if p != "" => Some([p])
      _ => None
    }
  }
  match wanted {
    Some(ids) =>
      for id in ids {
        match all.iter().find_first(p => profile_id(p) == id) {
          Some(p) if field(p, "enabled") is Some(False) =>
            raise Refused(self.words.tr("station.profile.disabled", args=[("profile", field(p, "name").unwrap_or(Json::null()))], lang~))
          _ => ()
        }
      }
    None => ()
  }
  let here = self.profiles_in(str_of(options, "ws")).map(profile_id)
  let profiles = all.filter(p => here.contains(profile_id(p)))
  if profiles.length() == 0 {
    raise Refused(self.words.tr("station.session.noProfileHere", args=[("runtime", Json::string(runtime_label(runtime)))], lang~))
  }
  let model = trimmed(str_of(options, "model"))
  // (what its preset binds it to: the presets' own, asked of them)
  let preset = trimmed(str_of(options, "preset"))
  let copy = field(options, "presetCopy")
  let has_copy = match copy {
    Some(Null) | None => false
    _ => true
  }
  if has_copy || preset is Some(_) {
    let refused = (self.world.ask)("presets.refusal", {
      "ws": opt_str(str_of(options, "ws")),
      "preset": opt_str(preset),
      "copy": copy.unwrap_or(Json::null()),
      "runtime": Json::string(runtime),
      "model": opt_str(model),
      "lang": Json::string(lang),
    })
    match refused {
      String(m) => raise Refused(m)
      _ => ()
    }
  }
  let speed = model_speed(field(options, "speed"))
  let pick_account = (candidates : Array[Json]) => {
    if speed != Some("ultrafast") {
      self.pick(candidates, model, true)
    } else {
      let eligible = []
      for candidate in candidates {
        if self.supports_ultrafast(candidate, model) {
          eligible.push(candidate)
        }
      }
      check_speed(self.words, runtime, field(options, "speed"), !eligible.is_empty(), lang)
      self.pick(eligible, model, true)
    }
  }
  let profile = match wanted {
    Some(ids) => {
      let subset = []
      for id in ids {
        match profiles.iter().find_first(p => profile_id(p) == id) {
          None =>
            match all.iter().find_first(p => profile_id(p) == id) {
              Some(there) => raise Refused(self.words.tr("station.profile.notHere", args=[("profile", field(there, "name").unwrap_or(Json::null()))], lang~))
              None => raise Refused("no \{runtime} profile \{id}")
            }
          Some(found) => {
            match model {
              Some(m) if !runs(found, m) =>
                raise Refused(self.words.tr("station.profile.modelOff", args=[("profile", field(found, "name").unwrap_or(Json::null())), ("model", Json::string(m))], lang~))
              _ => ()
            }
            subset.push(found)
          }
        }
      }
      if subset.length() == 1 {
        subset[0]
      } else {
        pick_account(subset)
      }
    }
    None => pick_account(profiles)
  }
  let effort = match str_of(options, "effort") {
    Some(e) if e != "" => Some(e)
    _ => None
  }
  check_speed(self.words, runtime, field(options, "speed"), speed == Some("ultrafast") && self.supports_ultrafast(profile, model), lang)
  let context = num_of(options, "context")
  check_context(self.words, runtime, context, lang)
  match effort {
    Some(e) => {
      let allowed = items(Some((self.world.ask)("accounts.modelEfforts", {
        "runtime": Json::string(runtime),
        "model": opt_str(model),
        "pinned": match wanted { Some(w) => Json::array(w.map(Json::string)); None => Json::null() },
        "allowed": Json::array(here.map(Json::string)),
      }))).map(js_string)
      if !allowed.contains(e) {
        raise Refused("effort must be one of \{allowed.join(", ")}")
      }
    }
    None => ()
  }
  let data = str_of(config, "dataDir").unwrap_or("")
  let workspace = chat_workspace(data, key)
  ignore((self.world.ask)("fs.mkdirs", [Json::string(workspace)]))
  if has_copy || preset is Some(_) {
    ignore((self.world.ask)("presets.keep", { "workspace": Json::string(workspace), "ws": opt_str(str_of(options, "ws")), "preset": opt_str(preset), "copy": copy.unwrap_or(Json::null()) }))
  }
  ignore((self.world.ask)("fs.mkdirs", [Json::string(join_path([data, "repos"]))]))
  let now = self.now()
  match client {
    Some(c) => {
      let gone = []
      for k, v in self.client_keys_made {
        if now - v.1 >= client_key_kept_ms {
          gone.push(k)
        }
      }
      for k in gone {
        self.client_keys_made.remove(k)
      }
      self.client_keys_made[key] = (take(c, 120), now)
    }
    None => ()
  }
  let title = trimmed(str_of(options, "title"))
  let fast : Json = if fast_runtimes.contains(runtime) {
    match speed {
      Some(s) => Json::boolean(s != "standard")
      None =>
        match field(options, "fast") {
          Some(True) => Json::boolean(true)
          Some(False) => Json::boolean(false)
          _ => Json::null()
        }
    }
  } else {
    Json::null()
  }
  self.store.insert_session({
    "key": Json::string(key),
    "connect": Json::string(internal_connect),
    "scope": "all",
    "title": opt_str(title),
    "createdBy": Json::string(created_by),
    "runtime": Json::string(runtime),
    "profile": Json::string(profile_id(profile)),
    "profilePinned": Json::boolean(wanted.map(w => w.length()) == Some(1)),
    "profiles": match wanted { Some(w) => Json::array(w.map(Json::string)); None => Json::null() },
    "model": match model { Some(m) => Json::string(m); None => opt_str(str_of(profile, "model")) },
    "effort": opt_str(effort),
    "fast": fast,
    "speed": opt_str(speed),
    "tui": Json::boolean(runtime == "claude" && field(options, "tui") == Some(Json::boolean(true))),
    "context": match context { Some(c) => num(c); None => Json::null() },
    "workspace": Json::string(workspace),
    "cwd": Json::null(),
    "runtimeSessionId": Json::null(),
    "token": Json::string(self.new_token()),
    "createdAt": num(now),
    "lastActiveAt": num(now),
    "ws": opt_str(str_of(options, "ws")),
  })
  (key, self.open_chat(key, created_by, title))
}

///|
/// What the pool picks of `candidates` (the station's accounts).
async fn Hub::pick(self : Hub, candidates : Array[Json], model : String?, strict : Bool) -> Json {
  let picked = (self.world.ask)("accounts.pick", {
    "candidates": Json::array(candidates.map(p => Json::string(profile_id(p)))),
    "model": opt_str(model),
    "strict": Json::boolean(strict),
  })
  match str_of(picked, "error") {
    Some(m) => raise Refused(m)
    None => picked
  }
}

///|
/// lifecycle.ts `checkSpeed`: a speed asked of a runtime and model that take it.
pub fn check_speed(words : Words, runtime : String, speed : Json?, supports_ultrafast : Bool, lang : String) -> Unit raise Refused {
  match speed {
    None | Some(Null) => return
    _ => ()
  }
  if model_speed(speed) is None || !fast_runtimes.contains(runtime) {
    raise Refused(words.tr("station.speed.invalid", lang~))
  }
  if speed == Some(Json::string("ultrafast")) && (runtime != "codex" || !supports_ultrafast) {
    raise Refused(words.tr("station.speed.ultrafast_unavailable", lang~))
  }
}

///|
fn Hub::supports_ultrafast(self : Hub, profile : Json, model : String?) -> Bool raise {
  if access_kind(profile) != "subscription" {
    return false
  }
  let model = match model { Some(m) => Some(m); None => str_of(profile, "model") }
  let reported = self.store.profile_check(profile_id(profile)).bind(check => field(check, "codexUltrafastModels"))
  ultrafast_model(model.map(Json::string), reported)
}

///|
/// `archiveBy`: hides a session from lists, or shows it again; `by` is "manual" or "auto". Archiving ends its idle
/// process and hands its files to cold storage once it is idle; shown again, they are restored first.
pub async fn Hub::archive_by(self : Hub, key : String, archived : Bool, by : String, known? : Json) -> Unit {
  let row = match known {
    Some(r) => r
    None =>
      match self.get_session(key) {
        Some(r) => r
        None => raise Refused("unknown session \{key}")
      }
  }
  let anchor = self.store.conversation_of(key)
  let found = self.store.members_of(anchor)
  let members = if found.is_empty() { [key] } else { found }
  if !archived {
    for m in members {
      ignore((self.world.ask)("cold.restore", Json::string(m)))
    }
    self.store.set_archived(key, false, by)
    for m in members {
      ignore((self.world.ask)("fs.rm", { "path": Json::string(self.transcript_copy(m)) }))
    }
    return
  }
  self.store.set_archived(key, archived, by)
  for m in members {
    if self.idle_measured.contains(m) {
      self.idle_measured.remove(m)
      self.idle_measured_dirty = true
    }
    (self.world.tell)("closed", Json::string(m))
    let m_row = if m == key { Some(row) } else { self.get_session(m) }
    match m_row {
      Some(r) => {
        let actor = self.actor(r)
        self.act(actor, "putAway")
        self.act(actor, "evict", args=[Json::boolean(true)])
        self.act(actor, "cleanArchive")
      }
      None => ()
    }
  }
}

///|
async fn Hub::transcript_copy(self : Hub, key : String) -> String {
  let archive = js_string((self.world.ask)("store.archiveDir", Json::null()) catch { _ => Json::string("") })
  join_path([archive, "transcripts", "\{key}.jsonl.zst"])
}

///|
/// `archive`: by hand.
pub async fn Hub::archive(self : Hub, key : String, archived : Bool) -> Unit {
  self.archive_by(key, archived, manual)
}

///|
/// `archiveChat`: a session's own chat goes with its session; a chat of its own goes alone. Lists show a chat through a
/// session that is shown, so one shown again with none brings its sessions back first.
pub async fn Hub::archive_chat(self : Hub, thread : Json, archived : Bool) -> Unit {
  let chat = self.stillfail_chat(thread)
  match str_of(chat, "home") {
    Some(home) => self.archive(home, archived)
    None => {
      if !archived {
        let sessions = items(Some(self.tw(() => self.threads.thread_sessions(thread)))).map(m => str_of(m, "session").unwrap_or(""))
        let none_shown = sessions.iter().all(s => match self.get_session(s) {
          Some(r) => !(field(r, "archivedAt") is (None | Some(Null)))
          None => false
        })
        if !sessions.is_empty() && none_shown {
          for s in sessions {
            self.archive(s, false)
          }
        }
      }
      self.store.set_thread_hidden(thread, archived, manual)
    }
  }
}

///|
/// `deleteSession`: its process ends, its rows go (with the threads only it was in) and its workspace directory,
/// transcript copy, exclusive transcripts under `<data>`, and what the readers kept of its transcripts' reading with
/// them. Transcripts outside `<data>` (a person's own profile home) or referenced by any other session row stay.
pub async fn Hub::delete_session(self : Hub, key : String) -> Unit {
  let row = match self.get_session(key) {
    Some(r) => r
    None => raise Refused("unknown session \{key}")
  }
  if self.drop_actor(key) {
    ignore(self.ask_actor(key, "dispose"))
  }
  // Flush any unread transcript tail into usage statistics before deleting the session row and its transcripts.
  match self.counter {
    Some(c) => ignore(c.read(Some([key])))
    None => ()
  }
  (self.world.tell)("live.forget", Json::string(key))
  if self.idle_measured.contains(key) {
    self.idle_measured.remove(key)
    self.idle_measured_dirty = true
  }
  let transcripts = (self.world.ask)("transcripts.of", { "key": Json::string(key), "row": row })
  let sources = self.store.runtime_session_sources(key, None)
  let exclusive_sources = []
  for s in sources {
    let rt = field(s, "runtime").unwrap_or(Json::null())
    let id = field(s, "id").unwrap_or(Json::null())
    if !self.store.transcript_referenced(rt, id, Json::string(key)) {
      exclusive_sources.push(s)
    }
  }
  let exclusive_files = if exclusive_sources.length() > 0 {
    (self.world.ask)("transcripts.exclusive", { "key": Json::string(key), "row": row, "sources": Json::array(exclusive_sources) }) catch {
      _ => Json::array([])
    }
  } else {
    Json::array([])
  }
  self.store.delete_session(key)
  (self.world.tell)("closed", Json::string(key))
  ignore((self.world.ask)("fs.rm", { "path": Json::string(self.transcript_copy(key)) }))
  ignore((self.world.ask)("marks.forget", transcripts))
  for file in items(Some(exclusive_files)) {
    if file is String(p) {
      ignore((self.world.ask)("fs.rm", { "path": Json::string(p) }) catch { _ => Json::null() })
    }
  }
  let data = str_of(self.config(), "dataDir").unwrap_or("")
  let sessions = join_path([data, "sessions"])
  let workspace = str_of(row, "workspace").unwrap_or("")
  let segs = split(workspace, "/")
  let own = segs[segs.length() - 1] == "workspace" && (workspace + "/").has_prefix(sessions + "/")
  let home = if own { segs[:segs.length() - 1].to_owned().join("/") } else { workspace }
  ignore((self.world.ask)("fs.rmRoom", { "workspace": Json::string(workspace), "home": Json::string(home) }))
}

///|
/// A profile of the config, by id (accounts.ts `profile`).
fn Hub::profile_named(self : Hub, id : String) -> Json? {
  items(field(self.config(), "profiles")).iter().find_first(p => profile_id(p) == id)
}

///|
/// `configure`: changes how a session runs from its next turn on (another profile, model, effort, speed, most
/// context); its process ends so the change takes, at once when idle, else before its next turn. Said in its chat when
/// its runtime, model, effort or speed changed. `change` is accounts.ts `SessionChange` as JSON.
pub async fn Hub::configure(self : Hub, key : String, change : Json, lang? : String) -> Unit {
  let lang = lang.unwrap_or(self.words.lang)
  let rest = match change {
    Object(m) => {
      let r = m.copy()
      r.remove("afresh")
      r
    }
    _ => {}
  }
  match field(change, "afresh") {
    None => ()
    Some(afresh) => {
      if self.get_session(key) is None {
        raise Refused("unknown session \{key}")
      }
      self.store.set_session_afresh(key, Some(afresh))
      if rest.length() == 0 {
        return
      }
    }
  }
  let decided = (self.world.ask)("accounts.change", { "key": Json::string(key), "change": change, "lang": Json::string(lang) })
  match str_of(decided, "error") {
    Some(m) => raise Refused(m)
    None => ()
  }
  let row = field(decided, "row").unwrap_or(Json::null())
  let runtime = str_of(decided, "runtime").unwrap_or("")
  let model = field(decided, "model").unwrap_or(Json::null())
  let effort = field(decided, "effort").unwrap_or(Json::null())
  let profile = field(decided, "profile").unwrap_or(Json::null())
  let profiles = field(decided, "profiles")
  let pinned = is_true(decided, "pinned")
  let repick = is_true(decided, "repick")
  let row_profile = str_of(row, "profile").unwrap_or("")
  let account = self.profile_named(match profile { String(p) => p; _ => row_profile })
  let row_speed = field(row, "speed").unwrap_or(Json::null())
  let fixed = profile is String(_) || (profiles is None && is_true(row, "profilePinned"))
  let wants_ultrafast = row_speed == Json::string("ultrafast") ||
    field(change, "speed") == Some(Json::string("ultrafast"))
  let supports_ultrafast = if !wants_ultrafast || runtime != "codex" {
    false
  } else if fixed {
    match account {
      Some(a) => self.supports_ultrafast(a, str_of(decided, "model"))
      None => false
    }
  } else {
    let kept = items(match profiles { None => field(row, "profiles"); Some(_) => profiles })
    let mut supported = false
    for p in self.profiles_in(str_of(row, "ws")) {
      if profile_runtimes(p).contains("codex") &&
        (kept.is_empty() || kept.contains(Json::string(profile_id(p)))) &&
        (match model { String(m) => runs(p, m); _ => true }) &&
        self.supports_ultrafast(p, str_of(decided, "model")) {
        supported = true
        break
      }
    }
    supported
  }
  let speed : Json = match field(change, "speed") {
    Some(s) => s
    None =>
      if field(change, "fast") is Some(_) ||
        Some(runtime) != str_of(row, "runtime") ||
        (row_speed == Json::string("ultrafast") && !supports_ultrafast) {
        Json::null()
      } else {
        row_speed
      }
  }
  check_speed(self.words, runtime, Some(speed), supports_ultrafast, lang)
  let moved_runtime = Some(runtime) != str_of(row, "runtime") && profile is String(_)
  let row_context = field(row, "context").unwrap_or(Json::null())
  let recapped = match field(change, "context") {
    Some(c) => c != row_context
    None => false
  }
  let over = !moved_runtime &&
    (match field(change, "context") {
      Some(Number(c, ..)) =>
        match self.usage_now(key) {
          Some(u) => num_of(u, "contextTokens").unwrap_or(0.0) > c
          None => 0.0 > c
        }
      _ => false
    })
  if moved_runtime {
    match field(row, "runtimeSessionId") {
      Some(String(id)) if id != "" => self.store.ran_in(key, Json::string(id), Json::string(row_profile))
      _ => ()
    }
    self.store.set_session_runtime(
      key,
      Json::string(runtime),
      profile,
      pinned,
      model,
      effort,
      Some(field(change, "fast").unwrap_or(Json::null())),
      field(change, "context").unwrap_or(Json::null()),
      Some(profiles.unwrap_or(Json::null())),
    )
    self.store.set_session_context_before(key, Json::null())
  } else {
    let left_pool = match profiles {
      Some(Array(list)) => list.length() > 1 && !list.contains(Json::string(row_profile))
      _ => false
    }
    match profiles {
      Some(ps) =>
        self.store.set_session_profile(
          key,
          match profile { Null => Json::string(row_profile); p => p },
          profile != Json::null(),
          Some(ps),
        )
      None => ()
    }
    if model != field(row, "model").unwrap_or(Json::null()) || effort != field(row, "effort").unwrap_or(Json::null()) {
      self.store.set_session_model(key, model, effort)
    }
    match field(change, "fast") {
      Some(f) => self.store.set_session_fast(key, Some(f))
      None => ()
    }
    if recapped {
      self.store.set_session_context(key, field(change, "context").unwrap_or(Json::null()))
      self.store.set_session_context_before(
        key,
        if over {
          match field(row, "contextBefore") {
            Some(Null) | None =>
              match row_context {
                Null => num(0.0)
                c => c
              }
            Some(b) => b
          }
        } else {
          Json::null()
        },
      )
    }
    if field(change, "speed") is Some(_) || (field(change, "fast") is None && row_speed != speed) {
      self.store.set_session_speed(key, speed)
    }
    if repick || left_pool {
      ignore((self.world.ask)("accounts.repick", Json::string(key)))
    } else if profile == Json::null() || (!fixed && speed == Json::string("ultrafast") && field(change, "speed") is Some(_)) {
      ignore((self.world.ask)("accounts.runOn", { "key": Json::string(key), "holding": Json::boolean(false), "quiet": Json::boolean(true) }))
    }
  }
  let was_tui = field(row, "tui") == Some(Json::boolean(true))
  let tui = runtime == "claude" && field(change, "tui").unwrap_or(Json::boolean(was_tui)) == Json::boolean(true)
  let mode_changed = tui != was_tui
  if mode_changed { self.store.set_session_tui(key, tui) }
  if moved_runtime && speed != Json::null() {
    self.store.set_session_speed(key, speed)
  }
  if self.actors.contains(key) {
    ignore(self.ask_actor(key, "changed", args=[Json::boolean(moved_runtime || recapped || mode_changed)]))
  }
  match self.get_session(key) {
    Some(now) => {
      let named = (id : String) => match self.profile_named(id) {
        Some(p) => str_of(p, "name")
        None => None
      }
      let ran : Json = { "was": run_shown(row, named), "now": run_shown(now, named) }
      if run_changed(ran) {
        ignore(self.ask_actor(self.actor(now), "runChanged", args=[ran]))
      }
    }
    None => ()
  }
  if recapped && over {
    let r = match self.get_session(key) {
      Some(r) => r
      None => row
    }
    ignore(self.ask_actor(self.actor(r), "compactToCap"))
  }
  let last = self.store.last_turn(Json::string(key))
  let detail = if str_of(last, "outcome") == Some("failed") { str_of(last, "detail").unwrap_or("") } else { "" }
  if detail.has_prefix("rate_limit") || (detail.has_prefix("overloaded") && str_of(last, "declared") == Some("waiting")) {
    let r = match self.get_session(key) {
      Some(r) => r
      None => row
    }
    self.act(self.actor(r), "goOn")
  }
}

///|
/// What an auto-archiving pass found not prepared yet, for its readers to prepare (lifecycle.ts `autoArchive`'s
/// callbacks): chats' unread state, the bindings' index, sessions' up jobs, the archive marks, chats' last messages.
pub struct Unprepared {
  unread : Array[Json]
  mut bindings : Bool
  jobs : Array[String]
  mut marks : Bool
  last : Array[Json]
}

///|
pub fn Unprepared::new() -> Unprepared {
  { unread: [], bindings: false, jobs: [], marks: false, last: [] }
}

///|
pub fn Unprepared::to_json(self : Unprepared) -> Json {
  {
    "unread": Json::array(self.unread),
    "bindings": Json::boolean(self.bindings),
    "jobs": Json::array(self.jobs.map(Json::string)),
    "marks": Json::boolean(self.marks),
    "last": Json::array(self.last),
  }
}

///|
/// archive-mark-index.ts `archiveMarksReady` (both lookups built).
fn marks_ready(db : @sql.Db) -> Bool raise {
  let rows = db.all("SELECT kind, version, complete FROM archive_mark_meta ORDER BY kind", [])
  guard rows.length() == 2 else { raise Refused("archive mark index version marker is missing") }
  rows.iter().all(r => r.get("complete") is Some(Number(1.0, ..)))
}

///|
/// session-bindings-index.ts `sessionBindingsReady`.
fn bindings_ready(db : @sql.Db) -> Bool raise {
  let rows = db.all("SELECT version, complete FROM session_binding_meta WHERE id = 1", [])
  guard rows.length() == 1 else { raise Refused("session binding index version marker is missing") }
  rows[0].get("complete") is Some(Number(1.0, ..))
}

///|
/// `autoArchive`: archives what has idled past autoArchiveMs and is done (and what is heard only on a platform after
/// slackArchiveMs), never the latest conversations of a workspace (`@readops.recent_conversations`); `look`: what a
/// reader read (`archiveLook`). When the next one will have idled long enough (None: none, or off), and what was found
/// not prepared.
pub async fn Hub::auto_archive(self : Hub, now : Double, look? : Json, missing? : Unprepared = Unprepared::new()) -> Double? {
  let config = self.config()
  let after = num_of(config, "autoArchiveMs").unwrap_or(0.0)
  let slack_after = num_of(config, "slackArchiveMs").unwrap_or(0.0)
  let reviewed = is_true(config, "autoArchiveReviewed")
  let completion = is_true(field(field(config, "automaticDecisions").unwrap_or(Json::null()), "completion").unwrap_or(Json::null()), "enabled")
  if after <= 0.0 && slack_after <= 0.0 {
    return None
  }
  let mut next : Double? = None
  let idle = (at : Array[Json], wait : Double) => {
    if wait <= 0.0 {
      return false
    }
    let mut most = 0.0
    for x in at {
      match x {
        Number(n, ..) => if n > most { most = n }
        _ => ()
      }
    }
    let due = most + wait
    if due > now && (next is None || due < next.unwrap()) {
      next = Some(due)
    }
    due <= now
  }
  let unread = (t : Json) => {
    let created_by = str_of(t, "createdBy")
    if created_by is None || str_of(t, "surface") != Some(stillfail_surface) {
      return false
    }
    let id = field(t, "id").unwrap_or(Json::null())
    match self.tw(() => self.threads.unread_for_archive(Json::string(created_by.unwrap()), id)) {
      True => true
      False => false
      _ => {
        missing.unread.push(id)
        true
      }
    }
  }
  match look {
    Some(l) => {
      if !is_true(l, "marksReady") {
        missing.marks = true
        return None
      }
      for t in items(field(l, "ownUnknown")) {
        missing.last.push(t)
      }
      next = num_of(l, "next")
    }
    None => ()
  }
  let live = if look is Some(_) { [] } else { self.store.live_sessions() }
  let own = match look {
    Some(l) => items(field(l, "own"))
    None => self.store.chats_of_their_own()
  }
  if look is None && live.length() == 0 && own.length() == 0 {
    return None
  }
  if look is None && !marks_ready(self.store.db) {
    missing.marks = true
    return None
  }
  let bindings = look is Some(_) || live.length() == 0 || bindings_ready(self.store.db)
  // (none waits for the bindings' index here: the station's readers prepare it, as they are asked)
  let waiting_bindings = !bindings
  if waiting_bindings {
    missing.bindings = true
  }
  let stats : Map[String, Json] = Map([])
  let stat_of = (key : String) => match stats.get(key) {
    Some(s) => s
    None => {
      let s = self.store.work_of(Json::string(key)) catch { _ => Json::null() }
      stats[key] = s
      s
    }
  }
  let jobs_read : Map[String, Bool] = Map([])
  let has_up_job = (key : String) => match jobs_read.get(key) {
    Some(b) => b
    None => {
      let found = self.store.session_has_up_job(Json::string(key)) catch { _ => Json::null() }
      let answer = match found {
        True => true
        False => false
        _ => {
          missing.jobs.push(key)
          true
        }
      }
      jobs_read[key] = answer
      answer
    }
  }
  let last_turn_of = (s : Json) => match field(s, "lastTurn") {
    Some(Object(_) as t) => Some(t)
    _ => None
  }
  let working = (key : String) => match self.get_session(key) {
    None => true
    Some(row) => {
      let stat = stat_of(key)
      is_true(row, "running") ||
      self.process_state(key) == "running" ||
      is_true(stat, "pending") ||
      (match last_turn_of(stat) {
        Some(t) => field(t, "endedAt") is Some(Null)
        None => false
      }) ||
      has_up_job(key)
    }
  }
  let busy = (key : String) => working(key) ||
    (match last_turn_of(stat_of(key)) {
      Some(t) => str_of(t, "declared") == Some("block")
      None => false
    })
  let pinned = (key : String) => {
    let m = self.tw(() => self.threads.archive_marks(Json::array([Json::string(key)]), Json::array([])))
    is_true(field(m, "pinned").unwrap_or(Json::null()), key)
  }
  let kept = (thread : Json) => {
    let m = self.tw(() => self.threads.archive_marks(Json::array([]), Json::array([thread])))
    is_true(field(m, "kept").unwrap_or(Json::null()), js_string(thread))
  }
  let recommended = (thread : Json) => !reviewed ||
    (completion && self.tw(() => self.threads.archive_suggested(thread)) == Json::boolean(true))
  match look {
    Some(l) => {
      let look_passed : Map[String, Json] = Map([])
      for x in items(field(l, "sessions")) {
        let s = field(x, "row").unwrap_or(Json::null())
        let key = row_key(s)
        let f = field(x, "facts").unwrap_or(Json::null())
        if field(f, "work") is Some(Null) || field(f, "work") is None {
          continue
        }
        if field(f, "bound") is Some(Null) {
          missing.bindings = true
          continue
        }
        if field(f, "pinned") is Some(Null) || field(f, "kept") is Some(Null) {
          missing.marks = true
          continue
        }
        if is_true(f, "bound") || is_true(f, "pinned") {
          continue
        }
        if field(f, "upJob") is Some(Null) {
          missing.jobs.push(key)
        }
        let work = field(f, "work").unwrap_or(Json::null())
        let last = last_turn_of(work)
        let working_now = is_true(s, "running") ||
          self.process_state(key) == "running" ||
          is_true(work, "pending") ||
          (match last {
            Some(t) => field(t, "endedAt") is Some(Null)
            None => false
          }) ||
          !(field(f, "upJob") is Some(False))
        let busy_now = working_now ||
          (match last {
            Some(t) => str_of(t, "declared") == Some("block")
            None => false
          })
        let threads = items(field(f, "threads"))
        let slack = threads.length() > 0 &&
          threads.iter().all(t => str_of(field(t, "thread").unwrap_or(Json::null()), "surface") != Some(stillfail_surface))
        let done = is_true(x, "quiet") && !busy_now
        let lingering = slack && is_true(x, "quietLong") && !working_now
        if !done && !lingering {
          continue
        }
        let thread_id = (t : Json) => field(field(t, "thread").unwrap_or(Json::null()), "id").unwrap_or(Json::null())
        if !lingering && !threads.iter().all(t => recommended(thread_id(t))) {
          continue
        }
        let kept_list = items(field(f, "kept"))
        if threads.iter().any(t => kept_list.contains(thread_id(t)) || unread(field(t, "thread").unwrap_or(Json::null()))) {
          continue
        }
        look_passed[key] = s
      }
      let archived_look : Array[String] = []
      for k, _ in look_passed {
        let anchor = self.store.conversation_of(k)
        if archived_look.contains(anchor) {
          continue
        }
        archived_look.push(anchor)
        let members = self.store.members_of(anchor)
        if members.length() > 0 && members.iter().all(m => look_passed.contains(m)) {
          match look_passed.get(anchor) {
            Some(row) => self.archive_by(anchor, true, auto, known=row)
            None => self.archive_by(anchor, true, auto)
          }
        }
      }
    }
    None => ()
  }
  let live_passed : Map[String, Json] = Map([])
  // The latest conversations of each workspace stay in the lists (a reader's look leaves them out already).
  let recent = if live.length() > 0 { @readops.recent_conversations(self.store.db, self.home(), num_of(config, "autoArchiveKeep").unwrap_or(0.0).to_int()) } else { Map([]) }
  for s in live {
    let key = row_key(s)
    if recent.contains(self.store.conversation_of(key)) {
      continue
    }
    if waiting_bindings || self.store.prepared_session_bound(Json::string(key)) || pinned(key) {
      continue
    }
    let at = [field(s, "lastActiveAt").unwrap_or(Json::null()), field(s, "shownAt").unwrap_or(Json::null())]
    let quiet = idle(at, after)
    let quiet_long = idle(at, slack_after)
    if !quiet && !quiet_long {
      continue
    }
    let (threads, _) = self.recent_threads(key)
    let slack = threads.length() > 0 &&
      threads.iter().all(t => str_of(field(t, "thread").unwrap_or(Json::null()), "surface") != Some(stillfail_surface))
    let done = quiet && !busy(key)
    let lingering = slack && quiet_long && !working(key)
    if !done && !lingering {
      continue
    }
    let thread_id = (t : Json) => field(field(t, "thread").unwrap_or(Json::null()), "id").unwrap_or(Json::null())
    if !lingering && !threads.iter().all(t => recommended(thread_id(t))) {
      continue
    }
    if threads.iter().any(t => kept(thread_id(t)) || unread(field(t, "thread").unwrap_or(Json::null()))) {
      continue
    }
    live_passed[key] = s
  }
  let archived_live : Array[String] = []
  for k, _ in live_passed {
    let anchor = self.store.conversation_of(k)
    if archived_live.contains(anchor) {
      continue
    }
    archived_live.push(anchor)
    let members = self.store.members_of(anchor)
    if members.length() > 0 && members.iter().all(m => live_passed.contains(m)) {
      match live_passed.get(anchor) {
        Some(row) => self.archive_by(anchor, true, auto, known=row)
        None => self.archive_by(anchor, true, auto)
      }
    }
  }
  for t in own {
    let id = field(t, "id").unwrap_or(Json::null())
    if look is None {
      if kept(id) {
        continue
      }
      let said = self.tw(() => self.threads.last_message_at_for_archive(id))
      if !is_true(said, "known") {
        missing.last.push(id)
        continue
      }
      let at = [field(t, "createdAt").unwrap_or(Json::null()), field(said, "at").unwrap_or(Json::null()), field(t, "shownAt").unwrap_or(Json::null())]
      if !idle(at, after) {
        continue
      }
    }
    if unread(t) || !recommended(id) {
      continue
    }
    let members = items(Some(self.tw(() => self.threads.thread_sessions(id))))
    if members.iter().any(m => pinned(str_of(m, "session").unwrap_or("")) || busy(str_of(m, "session").unwrap_or(""))) {
      continue
    }
    self.store.set_thread_hidden(id, true, auto)
  }
  next
}

///|
/// store.ts `ARCHIVED_WORKSPACE_BATCH`.
let archived_workspace_batch : Int = 64

///|
/// store.ts `IDLE_UNARCHIVED_BATCH`.
let idle_unarchived_batch : Int = 64

///|
/// Minimum interval between periodic archive backfill (`pack_unfinished_archived`) and idle rebuildable cleanup
/// (`clean_idle_rebuildable`) rounds (10 minutes): packing up to 16 sessions per round clears a backlog of several
/// hundred sessions within a few hours without contending with the main lifecycle loop.
pub let archive_upkeep_every_ms : Double = 10.0 * 60000.0

///|
/// Short startup grace (60 seconds) before `run_archive_upkeep_if_due` may run after hub startup: avoids a startup
/// burst while allowing persisted `last_archive_upkeep_at` to run promptly after frequent restarts.
pub let archive_upkeep_startup_grace_ms : Double = 60000.0

///|
/// Max unfinished archived sessions packed per periodic round.
pub let pack_backfill_max_per_round : Int = 16

///|
/// Max archived sessions checked per periodic backfill round before advancing the cross-round cursor.
pub let pack_backfill_check_max_per_round : Int = 256

///|
/// Unarchived sessions idle this long have their rebuildable directories cleaned (24 hours: acceptable to reinstall
/// dependencies when returning the next day).
pub let idle_rebuild_ms : Double = 24.0 * 3600000.0

///|
/// Aggressive idle threshold for cleaning rebuildable directories of unarchived sessions when disk is below `diskLow`.
pub let idle_rebuild_low_ms : Double = 3600000.0

///|
/// Max idle unarchived sessions measured per periodic round.
pub let idle_rebuild_max_per_round : Int = 16

///|
let idle_measured_max : Int = 4096

///|
fn Hub::record_idle_measured(self : Hub, key : String, last_active_at : Double) -> Unit {
  self.idle_measured.remove(key)
  self.idle_measured[key] = last_active_at
  if self.idle_measured.length() > idle_measured_max {
    match self.idle_measured.keys().head() {
      Some(k) => self.idle_measured.remove(k)
      None => ()
    }
  }
  self.idle_measured_dirty = true
}

///|
async fn Hub::ensure_upkeep_state_loaded(self : Hub) -> Unit {
  match self.upkeep_state_load {
    Some(d) => d.wait() catch { _ => () }
    None => {
      let d : @effect.Deferred[Unit] = @effect.Deferred::new()
      self.upkeep_state_load = Some(d)
      defer {
        ignore(d.succeed(()))
      }
      let saved = (self.world.ask)("upkeepState.read", Json::null()) catch { _ => Json::null() }
      guard saved is Object(m) else { return }
      match m.get("idleMeasured") {
        Some(Object(im)) => {
          let existing : Array[(String, Double)] = []
          for k, v in self.idle_measured {
            existing.push((k, v))
          }
          self.idle_measured.clear()
          for k, v in im {
            match v {
              Number(ts, ..) => self.idle_measured[k] = ts
              _ => ()
            }
          }
          for kv in existing {
            self.idle_measured.remove(kv.0)
            self.idle_measured[kv.0] = kv.1
          }
          while self.idle_measured.length() > idle_measured_max {
            match self.idle_measured.keys().head() {
              Some(k) => self.idle_measured.remove(k)
              None => break
            }
          }
        }
        _ => ()
      }
      if self.last_archive_upkeep_at is None {
        match m.get("lastArchiveUpkeepAt") {
          Some(Number(ts, ..)) => self.last_archive_upkeep_at = Some(ts)
          _ => ()
        }
      }
    }
  }
}

///|
async fn Hub::persist_upkeep_state(self : Hub, include_idle : Bool, include_archive_ts : Bool) -> Unit {
  let patch : Map[String, Json] = Map([])
  let mut any = false
  if include_idle && self.idle_measured_dirty {
    let im : Map[String, Json] = Map([])
    for k, v in self.idle_measured {
      im[k] = num(v)
    }
    patch["idleMeasured"] = Json::object(im)
    any = true
  }
  if include_archive_ts {
    patch["lastArchiveUpkeepAt"] = match self.last_archive_upkeep_at {
      Some(ts) => num(ts)
      None => Json::null()
    }
    any = true
  }
  if !any {
    return
  }
  ignore((self.world.ask)("upkeepState.patch", Json::object(patch)) catch { _ => Json::null() })
  if include_idle {
    self.idle_measured_dirty = false
  }
}

///|
/// Earliest timestamp when `run_archive_upkeep_if_due` will next be eligible to run.
pub fn Hub::next_archive_upkeep_at(self : Hub, every_ms? : Double = archive_upkeep_every_ms) -> Double {
  let grace = self.started_at + archive_upkeep_startup_grace_ms
  match self.last_archive_upkeep_at {
    None => grace
    Some(last) => {
      let due = last + every_ms
      if due > grace { due } else { grace }
    }
  }
}

///|
/// rows of archived workspaces, a page at a time, through `through` (a time, or the last one as `{key, archivedAt}`),
/// each given to `each` while `needed` says so.
async fn Hub::archived_workspaces(
  self : Hub,
  through : Json,
  each : async (Json) -> Bool,
  needed? : async () -> Bool,
  start? : Json = Json::null(),
) -> Unit {
  let mut after = start
  while true {
    match needed {
      Some(n) => if !n() { return }
      None => ()
    }
    let page = items(Some(self.store.archived_sessions(after, through)))
    for s in page {
      if !each(s) {
        return
      }
    }
    if page.length() < archived_workspace_batch {
      return
    }
    after = page[page.length() - 1]
  }
}

///|
/// `expireArchived`: empties the workspaces of sessions archived past archivedWorkspaceMs (their chats' files, history
/// and transcripts kept: the cold storage's `expire`). When the next archived comes due (None: none, or off).
pub async fn Hub::expire_archived(self : Hub, now : Double) -> Double? {
  let after = num_of(self.config(), "archivedWorkspaceMs").unwrap_or(0.0)
  if after <= 0.0 || (self.world.ask)("cold.expires", Json::null()) != Json::boolean(true) {
    return None
  }
  self.archived_workspaces(num(now - after), async fn(s) {
    let key = field(s, "key").unwrap_or(Json::null())
    try {
      if (self.world.ask)("cold.holdsMore", key) == Json::boolean(true) {
        ignore((self.world.ask)("cold.expire", { "key": key, "before": num(now - after) }))
      }
    } catch {
      _ => ()
    }
    true
  })
  match self.store.next_archived_at(num(now - after)) {
    Number(n, ..) => Some(n + after)
    _ => None
  }
}

///|
/// Runs `pack_unfinished_archived` and `clean_idle_rebuildable` on their own cadence (`archive_upkeep_every_ms`),
/// independent of how frequently `P52::lifecycle` wakes. Respects a short startup grace
/// (`archive_upkeep_startup_grace_ms`) so startup never runs an immediate burst, then uses persisted
/// `last_archive_upkeep_at` so frequent restarts do not starve upkeep. Returns whether a round ran.
pub async fn Hub::run_archive_upkeep_if_due(
  self : Hub,
  now : Double,
  every_ms? : Double = archive_upkeep_every_ms,
) -> Bool {
  self.ensure_upkeep_state_loaded()
  if now - self.started_at < archive_upkeep_startup_grace_ms {
    return false
  }
  match self.last_archive_upkeep_at {
    Some(last) if now - last < every_ms => return false
    _ => ()
  }
  self.last_archive_upkeep_at = Some(now)
  ignore(self.pack_unfinished_archived(now) catch {
    e => {
      (self.world.tell)("log", { "warn": Json::string("backfilling unfinished archived workspaces failed"), "error": Json::string(e.to_string()) })
      0
    }
  })
  ignore(self.clean_idle_rebuildable(now, persist=false) catch {
    e => {
      (self.world.tell)("log", { "warn": Json::string("cleaning rebuildable files of idle sessions failed"), "error": Json::string(e.to_string()) })
      0
    }
  })
  self.persist_upkeep_state(true, true)
  true
}

///|
/// `packUnfinishedArchived`: finishes packing archived sessions not yet past `archivedWorkspaceMs` that lack a `cold`
/// mark, one at a time via each session's actor queue, using a cross-round cursor and capping both checked and packed
/// sessions per round.
pub async fn Hub::pack_unfinished_archived(
  self : Hub,
  now : Double,
  limit? : Int = pack_backfill_max_per_round,
  check_limit? : Int = pack_backfill_check_max_per_round,
) -> Int {
  if limit <= 0 || check_limit <= 0 || (self.world.ask)("cold.expires", Json::null()) != Json::boolean(true) {
    return 0
  }
  let through = self.store.last_archived_session()
  if through == Json::null() {
    self.pack_cursor = Json::null()
    return 0
  }
  let after_ms = num_of(self.config(), "archivedWorkspaceMs").unwrap_or(0.0)
  let window_start : Json = if after_ms > 0.0 {
    { "archivedAt": num(now - after_ms), "key": Json::string("") }
  } else {
    Json::null()
  }
  let through_at = num_of(through, "archivedAt").unwrap_or(0.0)
  let through_key = str_of(through, "key").unwrap_or("")
  let saved_in_window = match (num_of(self.pack_cursor, "archivedAt"), str_of(self.pack_cursor, "key")) {
    (Some(sat), Some(sk)) =>
      (after_ms <= 0.0 || sat >= now - after_ms) && (sat < through_at || (sat == through_at && sk < through_key))
    _ => false
  }
  let start = if saved_in_window { self.pack_cursor } else { window_start }

  let mut checked = 0
  let mut attempted = 0
  let mut packed = 0
  let mut last_seen = Json::null()
  let mut stopped_early = false
  self.archived_workspaces(
    through,
    async fn(s) {
      if checked >= check_limit || attempted >= limit {
        stopped_early = true
        return false
      }
      checked += 1
      last_seen = s
      let key_j = field(s, "key").unwrap_or(Json::null())
      let key = match key_j {
        String(k) => k
        _ => return true
      }
      try {
        if (self.world.ask)("cold.needsPack", key_j) == Json::boolean(true) {
          let row = self.store.get_session(key)
          if row != Json::null() && field(row, "archivedAt").unwrap_or(Json::null()) != Json::null() {
            attempted += 1
            let actor = self.actor(row)
            ignore(self.ask_actor(actor, "cleanArchive"))
            packed += 1
          }
        }
      } catch {
        e => (self.world.tell)("log", { "warn": Json::string("an archived session's files not put away on backfill"), "session": Json::string(key), "error": Json::string(e.to_string()) })
      }
      if checked >= check_limit || attempted >= limit {
        stopped_early = true
        return false
      }
      true
    },
    needed=async fn() { checked < check_limit && attempted < limit },
    start~,
  )
  self.pack_cursor = if stopped_early && last_seen != Json::null() { last_seen } else { Json::null() }
  packed
}

///|
/// `cleanIdleRebuildable`: cleans rebuildable directories of idle unarchived sessions (`last_active_at <= now - idle_ms`),
/// oldest activity first, capped at `limit` measured sessions per round, skipping sessions whose `last_active_at` has
/// not changed since they were last measured. Never packs, writes `cold`, or touches transcripts.
pub async fn Hub::clean_idle_rebuildable(
  self : Hub,
  now : Double,
  idle_ms? : Double = idle_rebuild_ms,
  limit? : Int = idle_rebuild_max_per_round,
  persist? : Bool = true,
) -> Int {
  if limit <= 0 || (self.world.ask)("cold.expires", Json::null()) != Json::boolean(true) {
    return 0
  }
  self.ensure_upkeep_state_loaded()
  let through = num(now - idle_ms)
  let mut after = Json::null()
  let mut measured = 0
  while measured < limit {
    let page = self.store.idle_unarchived_sessions(after, through, idle_unarchived_batch)
    for s in page {
      if measured >= limit {
        break
      }
      let key_j = field(s, "key").unwrap_or(Json::null())
      let key = match key_j {
        String(k) => k
        _ => continue
      }
      let last_active_at = num_of(s, "lastActiveAt").unwrap_or(0.0)
      if self.idle_measured.get(key) == Some(last_active_at) {
        continue
      }
      try {
        match (self.world.ask)("cold.cleanIdleRebuildable", key_j) {
          Number(_, ..) => {
            self.record_idle_measured(key, last_active_at)
            measured += 1
          }
          _ => ()
        }
      } catch {
        e => (self.world.tell)("log", { "warn": Json::string("rebuildable files of an idle session not cleaned"), "session": key_j, "error": Json::string(e.to_string()) })
      }
    }
    if measured >= limit || page.length() < idle_unarchived_batch {
      break
    }
    after = page[page.length() - 1]
  }
  if persist {
    self.persist_upkeep_state(true, false)
  }
  measured
}

///|
/// `relieveIdleRebuildable`: low-disk reclamation of rebuildable directories from idle unarchived sessions
/// (threshold `idle_rebuild_low_ms`, oldest activity first). When `full` is true, cleans all eligible sessions
/// without stopping early when disk is no longer low. Shares `idle_measured` with `clean_idle_rebuildable`.
pub async fn Hub::relieve_idle_rebuildable(
  self : Hub,
  now : Double,
  idle_ms? : Double = idle_rebuild_low_ms,
  full? : Bool = false,
  persist? : Bool = true,
) -> Int {
  if (self.world.ask)("cold.expires", Json::null()) != Json::boolean(true) || (!full && !self.disk_free_low()) {
    return 0
  }
  self.ensure_upkeep_state_loaded()
  let through = num(now - idle_ms)
  let mut after = Json::null()
  let mut measured = 0
  let mut done = false
  while !done && (full || self.disk_free_low()) {
    let page = self.store.idle_unarchived_sessions(after, through, idle_unarchived_batch)
    for s in page {
      if !full && !self.disk_free_low() {
        done = true
        break
      }
      let key_j = field(s, "key").unwrap_or(Json::null())
      let key = match key_j {
        String(k) => k
        _ => continue
      }
      let last_active_at = num_of(s, "lastActiveAt").unwrap_or(0.0)
      if self.idle_measured.get(key) == Some(last_active_at) {
        continue
      }
      try {
        match (self.world.ask)("cold.cleanIdleRebuildable", key_j) {
          Number(_, ..) => {
            self.record_idle_measured(key, last_active_at)
            measured += 1
          }
          _ => ()
        }
      } catch {
        e => (self.world.tell)("log", { "warn": Json::string("rebuildable files of an idle session not cleaned"), "session": key_j, "error": Json::string(e.to_string()) })
      }
    }
    if done || page.length() < idle_unarchived_batch {
      break
    }
    after = page[page.length() - 1]
  }
  if persist {
    self.persist_upkeep_state(true, false)
  }
  measured
}

///|
/// relieve's DISK_LOW_BYTES (ops/disk.ts), as the world says it.
async fn Hub::disk_free_low(self : Hub) -> Bool {
  (self.world.ask)("disk.low", Json::null()) == Json::boolean(true)
}

///|
/// `relieveArchived`: the disk of the station's data is low: archived workspaces emptied before archivedWorkspaceMs, the
/// longest archived first (when `full` is true, empties all eligible workspaces without stopping early).
pub async fn Hub::relieve_archived(self : Hub, full? : Bool = false) -> Unit {
  if num_of(self.config(), "archivedWorkspaceMs").unwrap_or(0.0) <= 0.0 ||
    (self.world.ask)("cold.expires", Json::null()) != Json::boolean(true) {
    return
  }
  if !full && !self.disk_free_low() {
    return
  }
  let through = self.store.last_archived_session()
  if through == Json::null() {
    return
  }
  self.archived_workspaces(
    through,
    async fn(s) {
      if !full && !self.disk_free_low() {
        return false
      }
      let key = field(s, "key").unwrap_or(Json::null())
      try {
        if (self.world.ask)("cold.holdsMore", key) != Json::boolean(true) {
          return true
        }
        if !full && !self.disk_free_low() {
          return false
        }
        ignore((self.world.ask)("cold.expire", { "key": key, "before": field(s, "archivedAt").unwrap_or(Json::null()) }))
      } catch {
        _ => ()
      }
      true
    },
    needed=async fn() { full || self.disk_free_low() },
  )
}

///|
/// `continueMachineSession`: goes on in a chat with a session the machine's own Claude Code or Codex kept (`found`:
/// read/machine.ts `MachineSession`): its transcript copied into the shared ones (the world's), the new session
/// resuming it in the directory it ran in, its chat begun with a note of where it came from. One already going on with
/// it is that one's chat, brought back if archived.
pub async fn Hub::continue_machine_session(self : Hub, roots : Json, found : Json, created_by : String, lang? : String, ws? : String) -> (String, Json) {
  let lang = lang.unwrap_or(self.words.lang)
  let runtime = str_of(found, "runtime").unwrap_or("")
  let id = field(found, "id").unwrap_or(Json::null())
  let going = self.store.session_of_runtime(Json::string(runtime), id)
  match going {
    Object(_) => {
      let gk = row_key(going)
      let thread = self.store.home_chat(Json::string(gk))
      if thread != Json::null() {
        if field(going, "archivedAt") is Some(Number(_)) {
          self.archive(gk, false) catch {
            _ => ()
          }
        }
        return (gk, thread)
      }
    }
    _ => ()
  }
  let cwd = str_of(found, "cwd").unwrap_or("")
  // (as agents.ts makes the station's Places: its own data directory its own, `own`)
  match (self.world.ask)("places.directory", { "path": Json::string(cwd), "lang": Json::string(lang), "own": field(self.config(), "dataDir").unwrap_or(Json::null()) }) {
    Object(_) as r =>
      match str_of(r, "refused") {
        Some("gone" | "not_a_directory") => raise Refused(self.words.tr("station.session.cwdGone", args=[("cwd", Json::string(cwd))], lang~))
        Some(_) => raise Refused(str_of(r, "message").unwrap_or(""))
        None => ()
      }
    _ => ()
  }
  match self.store.session_of_runtime(Json::string(runtime), id) {
    Object(_) as already => {
      let thread = self.store.home_chat(Json::string(row_key(already)))
      if thread != Json::null() {
        return (row_key(already), thread)
      }
    }
    _ => ()
  }
  let config = self.config()
  let profiles = self.profiles_in(ws).filter(p => profile_runtimes(p).contains(runtime))
  if profiles.length() == 0 {
    raise Refused(self.words.tr("station.session.noProfile", args=[("runtime", Json::string(runtime_label(runtime)))], lang~))
  }
  let kept_model = match str_of(found, "model") {
    Some(m) if profiles.iter().any(p => profile_models(p).contains(m)) => Some(m)
    _ => None
  }
  let profile = self.pick(profiles, kept_model, false)
  let model = match kept_model {
    Some(m) => Some(m)
    None =>
      match str_of(profile, "model") {
        Some(m) => Some(m)
        None => profile_models(profile).get(0)
      }
  }
  let copy = (self.world.ask)("machine.copyTranscript", { "roots": roots, "found": found, "runtime": Json::string(runtime) })
  match copy {
    Object(_) as e => raise Refused(str_of(e, "error").unwrap_or(""))
    _ => ()
  }
  let entries = num_of(Json::object({ "n": (self.world.ask)("live.counted", { "runtime": Json::string(runtime), "path": copy }) }), "n").unwrap_or(0.0)
  let last = if entries > 0.0 { Some(entries - 1.0) } else { None }
  let key = self.new_chat_key()
  let data = str_of(config, "dataDir").unwrap_or("")
  let workspace = chat_workspace(data, key)
  ignore((self.world.ask)("fs.mkdirs", [Json::string(workspace)]))
  ignore((self.world.ask)("fs.mkdirs", [Json::string(join_path([data, "repos"]))]))
  let now = self.now()
  let title_of = match str_of(found, "title") {
    Some(t) => Some(t)
    None => str_of(found, "first")
  }
  let title = title_of.map(t => take(t, 80))
  let row : Map[String, Json] = {
    "key": Json::string(key),
    "connect": Json::string(internal_connect),
    "scope": "all",
    "title": opt_str(title),
    "createdBy": Json::string(created_by),
    "runtime": Json::string(runtime),
    "profile": Json::string(profile_id(profile)),
    "profilePinned": Json::boolean(false),
    "model": opt_str(model),
    "effort": Json::null(),
    "fast": Json::null(),
    "workspace": Json::string(workspace),
    "cwd": Json::string(cwd),
    "runtimeSessionId": id,
    "token": Json::string(self.new_token()),
    "createdAt": num(now),
    "lastActiveAt": num(now),
  }
  match ws {
    Some(w) => row["ws"] = Json::string(w)
    None => ()
  }
  self.store.insert_session(Json::object(row))
  let thread = self.open_chat(key, created_by, title)
  let thread_id = field(thread, "id").unwrap_or(Json::null())
  let at = match last {
    Some(l) => "&entry=\{js_number_text(l)}"
    None => ""
  }
  let note = self.words.tr("station.session.continued", args=[
    ("runtime", Json::string(runtime_label(runtime))),
    ("cwd", Json::string(cwd)),
    ("link", Json::string("?history=\{key}\{at}")),
  ], lang~)
  ignore(
    self.tw(() => self.threads.insert_message(
      jv({ "thread": thread_id, "ts": Json::string(self.next_ts()), "authorKind": "station", "author": "station", "text": Json::string(note) }),
    )),
  )
  ignore(self.tw(() => self.threads.set_read(Json::string(created_by), thread_id, self.threads.last_entry(thread_id))))
  (key, thread)
}
