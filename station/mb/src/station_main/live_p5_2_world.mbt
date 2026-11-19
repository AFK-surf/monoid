// What the hub, its live view and its storage ask of the station that the TypeScript's hub had of its own parts: the
// live view's transcripts (sessions/live.ts: where they are, what one gained, a page of its past, where its reading
// stands, its file watched), the machine's sessions (read/machine.ts `transcriptOf`, lifecycle.ts `copyTranscript`), a
// deleted session's readings let go (read/transcripts.ts `forgetMarksSoon`), and the storage's world (sessions/
// archive.ts, others.ts, relay.ts, clones.ts: the hub's lists and chats, the readers, the peers, the policy's names).

///|
/// The live view's locator, made as it is first asked.
fn P52::locator(self : P52) -> LiveLocator {
  match self.live_locator {
    Some(l) => l
    None => {
      let l = LiveLocator::new(
        self.host,
        self.bus.argv0,
        self.data,
        key => self.store("getSession", [Json::string(key)]) catch { _ => Json::null() },
        () => self.profiles().filter_map(p => match (jtext(p, "id"), jtext(p, "home")) {
          (Some(id), Some(home)) => Some((id, home))
          _ => None
        }),
      )
      self.live_locator = Some(l)
      l
    }
  }
}

///|
/// read/machine.ts `machineRoots`: where the machine's own Claude Code and Codex keep their sessions.
fn machine_roots() -> (String, String) {
  let home = homedir()
  let codex = match env_get("CODEX_HOME") {
    Some(c) if c != "" => c
    _ => path([home, ".codex"])
  }
  (path([home, ".claude", "projects"]), path([codex, "sessions"]))
}

///|
/// What the live view reads through the readers (agents.ts `hub.live.history`, `tailRead`).
async fn P52::live_ask(self : P52, what : String, args : Json) -> Json {
  let reader = self.bus.reader_ask.val
  match what {
    "live.locate" => self.locator().locate(jtext(args, "key").unwrap_or(""))
    "live.tailRead" => {
      let a = jitems(args)
      reader("tailRead", { "runtime": a.get(0).unwrap_or(Json::null()), "state": a.get(1).unwrap_or(Json::null()) }, "zh")
    }
    "live.page" => {
      let a = jitems(args)
      let num = (i : Int) => match a.get(i) {
        Some(Number(n, ..)) => n
        _ => 0.0
      }
      let ask : Map[String, Json] = {
        "key": a.get(0).unwrap_or(Json::null()),
        "before": Json::string(js_number_text(num(1))),
        "limit": Json::string(js_number_text(num(2))),
        "lang": "zh",
      }
      if a.get(3) is Some(True) {
        ask["brief"] = "1"
      }
      reader("timeline", Json::object(ask), "zh")
    }
    "live.state" => {
      let key = match args {
        String(k) => k
        _ => jtext(args, "key").unwrap_or("")
      }
      jfield(reader("transcriptState", { "key": Json::string(key) }, "zh"), "states")
    }
    // (sessions/live.ts `counted`: how many entries a transcript has, only counted)
    "live.counted" => {
      let state : Json = { "path": jfield(args, "path"), "runtime": jfield(args, "runtime"), "entries": false }
      let read = reader("tailRead", { "runtime": jfield(args, "runtime"), "state": state }, "zh")
      jfield(jfield(read, "state"), "count")
    }
    _ => raise LiveError("the live view asks nothing called \{what}")
  }
}

///|
/// The transcripts watched for the live view (live.ts `#arm`): by session, whether its watch still goes.
let transcript_watches : Map[String, Ref[Bool]] = Map([])

///|
let transcript_watch_ms : Int = 200

///|
/// live.ts `#arm`: the transcript written to now (its file, or its `.zst` while packed) watched, each change said to
/// the program (`soon`). The shell keeps no watch of a file: its size and time looked at every TRANSCRIPT_WATCH_MS.
fn P52::arm(self : P52, key : String, file : String) -> Unit {
  if transcript_watches.get(key) is Some(going) { going.val = false }
  let going = Ref(true)
  transcript_watches[key] = going
  let host = self.host
  let stamp = () => {
    let at = if attempt(() => @drive.stat(file)) is Ok(_) { file } else { file + ".zst" }
    match attempt(() => @drive.stat(at)) {
      Ok(st) => "\{at}:\{st.size}:\{st.mtime_ms}"
      Err(_) => ""
    }
  }
  fork_bg(host, "a transcript watched", async fn() {
    let mut before = stamp()
    while going.val && !self.closed {
      @effect.sleep(transcript_watch_ms) // timer: an outside system that offers no push (a runtime's transcript; the shell keeps no watch)
      if !going.val {
        break
      }
      let now = stamp()
      if now != before {
        before = now
        match self.actors_program {
          Some(p) => ignore(p.post({ "call": ji(0), "actor": jstr("#live"), "method": jstr("soon"), "args": Json::array([jstr(key)]) }))
          None => ()
        }
      }
    }
  })
}

///|
fn P52::disarm(_self : P52, key : String) -> Unit {
  match transcript_watches.get(key) {
    Some(going) => {
      going.val = false
      transcript_watches.remove(key)
    }
    None => ()
  }
}

///|
/// What the hub asks of the machine's sessions and a deleted session's readings.
async fn P52::machine_ask(self : P52, what : String, args : Json) -> Json {
  let fs = @ops_platform.Fs::new(self.host)
  let (claude, codex) = machine_roots()
  match what {
    "machine.transcriptOf" =>
      jopt(@ops_platform.transcript_of(fs, claude, codex, jtext(args, "runtime").unwrap_or(""), jtext(args, "id").unwrap_or("")))
    // (lifecycle.ts `copyTranscript`: a machine session's transcript copied to the station's shared transcripts, the
    // originals not touched; `{error}` where it could not be)
    "machine.copyTranscript" => {
      let found = jfield(args, "found")
      let runtime = jtext(args, "runtime").unwrap_or("")
      let roots = jfield(args, "roots")
      let root = if runtime == "claude" {
        jtext(roots, "claude").unwrap_or(claude)
      } else {
        jtext(roots, "codex").unwrap_or(codex)
      }
      let shared = path([self.data, "transcripts", runtime])
      let first = jtext(found, "path").unwrap_or("")
      let id = jtext(found, "id").unwrap_or("")
      let files = [first]
      if runtime == "codex" {
        let o = {
          ..@ops_platform.WalkOptions::default(() => wall_ms().to_double()),
          max_depth: @ops_platform.rollout_depth,
          max_entries: @ops_platform.rollout_entries,
          follow_root: true,
        }
        ignore(
          @ops_platform.walk_bounded(
            fs,
            [root],
            e => {
              if e.file &&
                e.depth > 0 &&
                e.name.has_prefix("rollout-") &&
                @ops_platform.extension(e.name) == Some("jsonl") &&
                e.path != first &&
                @ops_platform.rollout_of(e.path, id) {
                files.push(e.path)
              }
              Go
            },
            o,
          ),
        ) catch {
          e => return { "error": jstr(said_of(e)) }
        }
      }
      let under = (p : String) => {
        let prefix = if root.has_suffix(sep()) { root } else { root + sep() }
        if p.has_prefix(prefix) && p.length() > prefix.length() {
          Ok(p[prefix.length():].to_owned())
        } else {
          Err("\{p} is not the machine's")
        }
      }
      for from in files {
        let rel = match under(from) {
          Ok(r) => r
          Err(m) => return { "error": jstr(m) }
        }
        let to = path([shared, rel])
        let partial = (if to.has_suffix(".jsonl") { to[:to.length() - 6].to_owned() } else { to }) + ".jsonl.part"
        let copied = attempt(() => {
          @drive.mkdir(@nodepath.dirname(sep(), to), true)
          // (a part a copy cut short left is replaced)
          copy_file_over(from, partial)
          @drive.rename(partial, to)
        })
        if copied is Err(e) {
          return { "error": jstr(said_of(e)) }
        }
      }
      match under(first) {
        Ok(rel) => Json::string(path([shared, rel]))
        Err(m) => { "error": jstr(m) }
      }
    }
    // (lifecycle.ts `deleteSession`: where its transcripts were, for what the readers kept of them to go)
    "transcripts.of" => {
      let at = self.locator().locate(jtext(args, "key").unwrap_or("")) catch { _ => Json::null() }
      Json::array(jitems(jfield(at, "paths")).filter_map(p => match jfield(p, "path") { String(_) as s => Some(s); _ => None }))
    }
    "marks.forget" => {
      let paths = jitems(args).filter_map(p => match p { String(s) => Some(s); _ => None })
      @ops_platform.forget_marks(fs, @ops_platform.transcript_marks_dir(self.data), paths) catch {
        _ => ()
      }
      Json::null()
    }
    _ => raise LiveError("the hub asks nothing called \{what}")
  }
}

///|
/// What the sessions' storage asks of the station (session_storage `Station`), past the store and the log: the hub's
/// parts by their TypeScript names. None where it is the conversations' world's to answer.
async fn P52::storage_world(self : P52, name : String, args : Array[Json], viewer? : Json) -> Json? {
  let a = (i : Int) => args.get(i).unwrap_or(Json::null())
  let s = (i : Int) => as_text(a(i)).unwrap_or("")
  let opt = (i : Int) => as_text(a(i))
  let reader = self.bus.reader_ask.val
  let hub = self.the_hub()
  let answered = match name {
    "hub.config" => self.config
    "hub.has" => Json::boolean(["locateAsync", "recentChatList", "searchChatList", "threadList"].contains(s(0)))
    "hub.hasPeers" => Json::boolean(self.bound())
    "hub.hasChat" => Json::boolean(s(0) == @session_hub.internal_connect || (hub.world.chat)(s(0)) is Some(_))
    "hub.chatPost" =>
      Json::string(
        self.chat_post(s(0), jtext(a(1), "channel").unwrap_or(""), jtext(a(1), "threadTs").unwrap_or(""), s(2), jitems(a(3))),
      )
    "hub.link" => jopt(self.page_of(s(0)))
    "hub.now" => Json::number(hub.now())
    "hub.pid" => Json::number(@drive.pid().to_double())
    "hub.outsideChats" => (self.bus.jobs_ask.val)("xshare.borrowed", Json::array([a(0)]))
    "hub.recentChatList" => reader("recentChatList", { "ws": a(0), "home": a(1), "limit": a(2) }, "zh")
    "hub.searchChatList" => {
      let req : Map[String, Json] = { "ws": a(0), "home": a(1), "limit": a(2), "query": a(3) }
      match a(4) {
        Object(f) => for k, v in f { req[k] = v }
        _ => ()
      }
      reader("searchChatList", Json::object(req), "zh")
    }
    "hub.threadList" => reader("threadList", Json::object({}), "zh")
    "hub.workspaces" => Json::array(self.workspaces().map(Json::string))
    "hub.wsOf" => jopt(hub.ws_of(opt(0)))
    "hub.surface" => Json::string(hub.surface(s(0)))
    "hub.processState" => Json::string(hub.process_state(s(0)))
    "hub.inWorkspace" => @session_hub.hub_call(hub, "inWorkspace", args)
    "live.locate" => self.locator().locate(s(0))
    "live.page" => self.live_ask("live.page", Json::array([a(0), a(1), a(2), Json::boolean(false)]))
    "peers.call" => {
      // (agents.ts `hub.onPeer`: the request carried to the other station, the xshare's way where it is another
      // workspace's; a file it carries read by the shell where it says, the answer's bytes given back as base64)
      let request = match a(1) {
        Object(m) => m.copy()
        _ => {}
      }
      match request.get("$file") {
        Some(f) => {
          request.remove("$file")
          let from = as_num(jfield(f, "offset")).unwrap_or(0.0)
          let end = as_num(jfield(f, "end")).unwrap_or(0.0)
          let piece = p51_file_piece(self.host, jtext(f, "path").unwrap_or(""), from, (end - from).to_int())
          request["$bytes"] = Json::string(@base64.encode(piece))
        }
        None => ()
      }
      (self.bus.jobs_ask.val)("xshare.send", Json::array([a(0), Json::object(request)]))
    }
    "fn.realOutside" =>
      jopt(@readops.real_outside_of(self.host, s(0), home=homedir(), mac=platform() == "darwin"))
    "fn.shownFacts" => shown_facts(self.host, s(0))
    "fn.startEnv" =>
      Json::object(
        Map::from_array(
          @ops_platform.start_env(env_all(), (self.bus.config_raw.val)(), []).map(kv => (kv.0, Json::string(kv.1))),
        ),
      )
    "fn.stationLang" => Json::string(self.lang())
    "fn.tr" => {
      let vars = match a(2) {
        Object(m) => m.to_array()
        _ => []
      }
      Json::string(self.words.tr(s(1), args=vars, lang=s(0)))
    }
    "fn.titleOf" => Json::string(self.title_of(a(0), opt(1), opt(2)))
    "fn.threadsToldOf" => {
      let recent = (jitems(jfield(a(1), "threads")), jfield(a(1), "more") is True)
      Json::array(hub.threads_told_of(s(0), recent~).map(Json::string))
    }
    "fn.threadHistory" => {
      let seen : Array[@jsjson.JValue]? = if a(5) is True { Some([]) } else { None }
      let text = @session_chats.thread_history(self.chats_world(), s(0), to_jv(a(1)), s(2), s(3), to_jv(a(4)), seen)
      match seen {
        Some(got) => { "text": Json::string(text), "seen": Json::array(got.map(of_jv)) }
        // (session_storage reads `text` of it either way: a bare string read as "", every chat_read empty)
        None => { "text": Json::string(text) }
      }
    }
    "policy.mine" =>
      match viewer {
        Some(v) => Json::boolean(@api_routes.sees(@jsjson.JV::of_json(v), @jsjson.JV::of_json(jopt(self.ws_of(s(0))))))
        None => Json::boolean(true)
      }
    "policy.title" => Json::string(self.chat_title_of(s(0)))
    "chat.has" =>
      if s(0) == @session_hub.internal_connect {
        Json::boolean(false)
      } else {
        (self.bus.coord_ask.val)("chat.has", Json::array(args))
      }
    "clones.reposDir" => Json::string(self.repos_dir())
    "clones.indexRepos" => self.repo_index_repos(Json::null())
    "clones.run" => self.clone_run(s(0), jitems(a(1)).filter_map(x => match x { String(t) => Some(t); _ => None }), a(2))
    "clones.kill" => {
      if clones_running.get(s(0)) is Some(pid) { ignore(kill(pid, "SIGKILL")) }
      Json::null()
    }
    "clones.changed" => {
      self.bus.notify_store({ "type": jstr("clones") })
      Json::null()
    }
    _ =>
      if name.has_prefix("chat.") {
        if s(0) == @session_hub.internal_connect {
          undef_json()
        } else {
          (self.bus.coord_ask.val)(name, Json::array(args))
        }
      } else {
        return None
      }
  }
  Some(answered)
}

///|
/// The git clones running, by the clone's id: their process.
let clones_running : Map[String, Int] = Map([])

///|
let clone_most_ms : Int = 30 * 60000

///|
/// clones.ts `runGit`: git with `args` in `env` (the agents' environment and what the clone adds), no terminal, its
/// stderr's end held; stopped at CLONE_MOST_MS.
async fn P52::clone_run(self : P52, id : String, args : Array[String], env : Json) -> Json {
  let pairs = match env {
    Object(m) => m.to_array().filter_map(kv => if kv.1 is String(v) { Some((kv.0, v)) } else { None })
    _ => []
  }
  let git = find_command("git", pairs).unwrap_or("git")
  let proc = spawn(self.host, git, args, env=pairs, stderr=Piped) catch {
    e => return { "ok": false, "stderr": jstr("\n" + said_of(e)) }
  }
  clones_running[id] = proc.pid
  let late = Ref(false)
  let killer = self.host.rt.fork(name="a clone's deadline", async fn() {
    @effect.sleep(clone_most_ms) // timer: a deadline to a process (git given CLONE_MOST_MS at most)
    late.val = true
    ignore(kill(proc.pid, "SIGKILL"))
  })
  let (code, _, _, err) = proc.finished()
  killer.interrupt()
  clones_running.remove(id)
  let said = @utf8.decode_lossy(err)
  let held = if said.length() > 8192 { said[said.length() - 8192:].to_owned() } else { said }
  {
    "ok": Json::boolean(code == Some(0)),
    "stderr": Json::string(
      if late.val {
        held + "\ngit clone took longer than 30 minutes and was stopped"
      } else {
        held
      },
    ),
  }
}

///|
/// read/views.ts `titleOf`: what a thread is called, by the one rule the core names it by too.
fn P52::title_of(self : P52, thread : Json, first : String?, channel : String?) -> String {
  @adb_devices.chat_title(
    to_jv(thread),
    first,
    channel,
    self.words.tr("station.chat.untitled"),
    self.words.tr("station.chat.directMessage"),
  )
}

///|
/// overview.ts `chatTitleOf`: what a session's chat is called in the chat list; its title, else its key, where it has
/// none.
fn P52::chat_title_of(self : P52, session : String) -> String {
  let chat = self.store("sessionChat", [Json::string(session)]) catch { _ => Json::null() }
  match chat {
    Object(_) =>
      self.title_of(
        jfield(chat, "thread"),
        as_text(jfield(chat, "firstText")),
        None,
      )
    _ =>
      match (self.store("getSession", [Json::string(session)]) catch { _ => Json::null() }) {
        Object(_) as row => jtext(row, "title").unwrap_or(session)
        _ => session
      }
  }
}

///|
/// The conversations' `net.fetch` (decision.ts, title-completion.ts `fetch`): a request to a model's endpoint, its
/// answer as `{ok, status, chunks}` (`readFailed` where its body did not read whole).
async fn P52::net_fetch(self : P52, meth : String, args : Array[Json]) -> Json {
  guard meth == "fetch" else { raise LiveError("the conversations asked the network for \{meth}") }
  let init = args.get(1).unwrap_or(Json::null())
  let headers = match jfield(init, "headers") {
    Object(m) => m.to_array().filter_map(kv => if kv.1 is String(v) { Some((kv.0, v)) } else { None })
    _ => []
  }
  let answer = (p5_oauth_io(self.host).fetch)({
    url: opt_str(args.get(0)).unwrap_or(""),
    method_: jtext(init, "method").unwrap_or("GET"),
    headers,
    body: jtext(init, "body"),
    timeout_ms: match jfield(init, "timeout") {
      Number(n, ..) => n.to_int()
      _ => 30000
    },
    manual: jtext(init, "redirect") == Some("manual"),
  })
  {
    "ok": Json::boolean(answer.status >= 200 && answer.status < 300),
    "status": Json::number(answer.status.to_double()),
    "chunks": Json::array([Json::string(answer.body)]),
  }
}

///|
/// agents.ts `hub.onClose`, as the parts it names are here: each on the bus but the screens' hands, this side's own.
fn P52::on_closed(self : P52, key : String) -> Unit {
  let bus = self.bus
  fork_bg(self.host, "a session closed", async fn() {
    ignore((bus.jobs_ask.val)("remote.closeSession", Json::array([Json::string(key)]))) catch {
      _ => ()
    }
    let gone = (self.store("getSession", [Json::string(key)]) catch { _ => Json::null() }) is Null
    if gone {
      ignore((bus.jobs_ask.val)("workspaceWatch.forget", Json::array([Json::string(key)]))) catch {
        _ => ()
      }
    }
    match self.computer {
      Some(c) => c.close_session(key) catch { _ => () }
      None => ()
    }
    ignore(bus.forwards_call("forwards.closeSession", [Json::string(key)])) catch {
      _ => ()
    }
    bus.parts.end_session(key)
  })
}

///|
/// feedback/module.ts `FeedbackLive`: on the stable channel of a control plane that takes bug reports, the agents'
/// feedback tools, the pages' report routes (a read-only member may report), the overview's `feedback`, and what was
/// fixed told a while after the station starts and as each release is out.
async fn P52::start_feedback(self : P52) -> Unit {
  let bus = self.bus
  let part = @mcp_tools.feedback_live(self.tool_ctx(), env_get("HOME").unwrap_or(homedir())) catch {
    e => {
      slice_log("warn", "feedback", "the bug reports' part was not made", { "error": jstr(said_of(e)) })
      None
    }
  }
  guard part is Some(part) else { return }
  self.feedback = Some(part)
  bus.parts.routes(
    part.routes.map(rr => {
      meth: rr.verb,
      path: rr.pattern,
      answer: async fn(asked : Json) -> Json {
        let params = jitems(jfield(asked, "params")).map(p => as_text(p))
        let ask : @mcp_tools.ReportAsk = {
          body: @utf8.encode(jtext(asked, "rawBody").unwrap_or("")),
          lang: jtext(asked, "lang").unwrap_or(self.lang()),
          viewer: @jsjson.JV::of_json(jfield(asked, "viewer")),
        }
        let answer = (rr.handle)(ask, params)
        let body = match answer.body {
          Whole(b) => @utf8.decode_lossy(b)
          _ => ""
        }
        {
          "status": Json::number(answer.status.to_double()),
          "headers": Json::object(answer.headers.map((_, v) => Json::string(v))),
          "body": Json::string(body),
        }
      },
    }),
  )
  bus.parts.viewer_may(@mcp_tools.feedback_viewer_may)
  bus.parts.overview("feedback", async fn(_viewer, _lang) { Json::boolean((part.overview)()) }) catch {
    _ => ()
  }
  let tell = () => fork_bg(self.host, "fixed bug reports", async fn() { (part.telling_fixed)() })
  ignore(
    self.host.rt.fork_daemon("fixed bug reports, later", on_error=e => @host.note("fixed bug reports, later failed: \{e}"), async fn() {
      @effect.sleep(part.told_after_ms) // timer: a deadline (what came out while the station was not running, a while after it starts)
      tell()
    }),
  )
  // (the plane's `release`, told by its presence socket: feedback/module.ts `plane.told("release", tellingFixed)`)
  bus.on_release(tell)
}
