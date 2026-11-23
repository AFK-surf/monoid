// The agents' side (P5-2): what the conversations' parts (station/mb/src/session_chats, session_storage) and the
// agents' tools (mcp_tools) ask of the station by name, answered by its own parts: the store's calls, the hub's
// methods (session_hub `hub_call`), its readers (readops on the station's database), the deps of src/sessions as their
// MoonBit (session_hub, session_storage, agent_runtimes), the files; and the `/mcp` endpoint (tools/mcp.ts
// `McpEndpoint`) over the tools they make.

///|
using @jsjson {type JValue as J}

///|
fn j_undef() -> J {
  Obj([("$u", Num(1.0))])
}

///|
/// The states the hub keeps of its own for the conversations (callback handles, side agents, plus the shared
/// `@session_chats.ChatState` for held posts, relayed chats' openings, and title requests).
priv struct ChatState {
  shared : @session_chats.ChatState
  callbacks : Map[Int32, async (Array[J]) -> J]
  mut next_cb : Int32
  refs : Map[String, J]
  mut next_ref : Int32
  /// The `peers` function's callback, made once (`peers_callback`).
  mut peers_cb : Int32?
  /// The runtime sessions the conversations opened themselves (`driver.open`), by the number their handle names.
  sides : Map[Int32, SideAgent]
  mut next_side : Int32
}

///|
/// A runtime session a conversation opened itself (`side_open`): its events kept as the driver tells them, each given
/// the conversation's callback as it waits for them (`agent.waitEvents`), since a driver tells them as they come and
/// the callback is the conversation's own, to be awaited.
priv struct SideAgent {
  agent : Agent
  told : Array[J]
  wake : Ref[@effect.Deferred[Unit]]
  /// The conversation's callback (`{"$fn": id}`) its events are given.
  events : Int32
  /// When it is given up waiting (wall ms): regenerate-title.ts `TIMEOUT_MS` after it was opened.
  until : Double
}

///|
let chat_state : ChatState = {
  shared: @session_chats.ChatState::new(),
  callbacks: Map([]),
  next_cb: 0,
  refs: Map([]),
  next_ref: 0,
  peers_cb: None,
  sides: Map([]),
  next_side: 0,
}

///|
/// The conversations' world (session_chats `World`).
fn P52::chats_world(self : P52) -> @session_chats.World {
  let lang = Ref(self.lang())
  // (what the last call threw besides its words, read by the conversations as they tell a kind's fields apart:
  // a busy database's `errcode`, a file's `code`, the sessions a `CcSessionsUnavailable` names)
  let thrown : Ref[J] = Ref(Null)
  let live : @session_chats.Live? = match self.hub {
    Some(hub) =>
      Some({
        store: self.bus.store,
        threads: self.threads,
        hub,
        db: self.bus.db,
        state: chat_state.shared,
        flush_threads: () => told_threads(self.bus, self.threads),
      })
    None => None
  }
  {
    call: async fn(name, args) {
      lang.val = self.lang()
      self.chats_call(name, args, thrown)
    },
    callback: f => {
      chat_state.next_cb += 1
      let id = chat_state.next_cb
      chat_state.callbacks[id] = f
      Obj([("$fn", Num(id.to_double()))])
    },
    words: self.cwords,
    lang,
    thrown,
    live,
  }
}

///|
/// `hub.store.subscribe(listener)` as the conversations ask it (conversations.mbt `state_read`): the store's changes on
/// the bus (LiveBus::subscribe_store) kept as they come, and told the listener (a callback they gave, `{"$fn": id}`)
/// as the function this answers with is called to stop it, which state_read calls before it looks at what it was told.
/// (The listener is async and a change is told on the bus's own turn: kept there, not called there.) Not answered, it
/// failed every state an agent recorded (`no such store method: subscribe`).
fn P52::store_subscribe(self : P52, listener : J) -> J {
  let id = jv_num(listener, "$fn")
    .unwrap_or(-1.0)
    .to_int()
  let seen : Array[Json] = []
  let off = self.bus.subscribe_store(change => seen.push(change))
  chat_state.next_cb += 1
  let stop_id = chat_state.next_cb
  chat_state.callbacks[stop_id] = async fn(_) {
    off()
    chat_state.callbacks.remove(stop_id)
    let told = chat_state.callbacks.get(id)
    chat_state.callbacks.remove(id)
    match told {
      Some(f) => for change in seen { f([to_jv(change)]) |> ignore }
      None => ()
    }
    Null
  }
  Obj([("$fn", Num(stop_id.to_double()))])
}

///|
/// The one function the conversations call to carry a request to another station (hub.ts `peers()`, agents.ts
/// `onPeer`): `[station, request]`, the request's workspace and method its own, carried as `peers.call` carries a
/// session's.
fn P52::peers_callback(self : P52) -> J {
  let id = match chat_state.peers_cb {
    Some(id) => id
    None => {
      chat_state.next_cb += 1
      let id = chat_state.next_cb
      chat_state.callbacks[id] = async fn(given) {
        let station = match given.get(0) {
          Some(Str(u)) => @jsjson.sanitize_str(u)
          _ => ""
        }
        to_jv(self.storage_call("peers.call", [jstr(station), of_jv(given.get(1).unwrap_or(Null))]))
      }
      chat_state.peers_cb = Some(id)
      id
    }
  }
  Obj([("$fn", Num(id.to_double()))])
}

///|
/// The conversations' storage parts (session_storage `Storage`), their station's calls answered here.
fn P52::storage(self : P52) -> @session_storage.Storage raise LiveError {
  match self.storage_inst {
    Some(s) => s
    None => {
      let s = @session_storage.Storage::new(
        @session_storage.Station::new(
          self.bus.store,
          self.threads,
          self.the_hub(),
          path([self.data, "archive"]),
          () => told_threads(self.bus, self.threads),
          async fn(name, args) { self.storage_call(name, args) },
        ),
        self.files,
      )
      self.storage_inst = Some(s)
      s
    }
  }
}

///|
async fn P52::storage_call(
  self : P52,
  name : String,
  args : Array[Json],
) -> Json {
  let a = (i : Int32) => args.get(i).unwrap_or(Json::null())
  match name {
    "hub.setOpening" => {
      chat_state.shared.set_opening(a(0).stringify(), to_jv(a(1)))
      Json::null()
    }
    _ =>
      if name.has_prefix("log.") {
        slice_log(
          name[4:].to_owned(),
          as_text(a(0)).unwrap_or("storage"),
          as_text(a(1)).unwrap_or(""),
          a(2),
        )
        Json::null()
      } else {
        match self.storage_world(name, args) {
          Some(v) => v
          // (the rest as the conversations' world answers it: the hub's methods, its readers, the files, the deps)
          None => of_jv(self.chats_answer(name, args.map(to_jv), args))
        }
      }
  }
}

///|
/// What the conversations are given of an error the station's parts threw: a kind they tell apart by its name, and
/// what it carries besides its words in `thrown` (World.thrown: the TypeScript's error's own fields).
fn thrown_of(e : Error, thrown : Ref[J]) -> Error {
  thrown.val = Null
  match e {
    @session_chats.Thrown(code, _) => {
      if code != "" {
        thrown.val = to_jv({ "code": Json::string(code) })
      }
      e
    }
    _ if @sql.busy(e) => {
      // (node:sqlite's SQLITE_BUSY: conversations.mbt `state_write` takes it for StateWriteBusy)
      thrown.val = to_jv({ "errcode": Json::number(5.0) })
      @session_chats.Thrown("SqliteError", said_of(e))
    }
    @drive.FsError(f) => {
      thrown.val = to_jv({ "code": Json::string(f.code) })
      @session_chats.Thrown(f.code, f.message)
    }
    @store_threads.MessageWriteBusy => @session_chats.Thrown("MessageWriteBusy", "message write is busy")
    @store_threads.CcSessionsUnavailable(ss) => {
      thrown.val = to_jv({ "sessions": Json::array(ss.map(Json::string)) })
      @session_chats.Thrown("CcSessionsUnavailable", "cc sessions unavailable")
    }
    @store_threads.DecisionSessionsUnavailable =>
      @session_chats.Thrown("DecisionSessionsUnavailable", "decision sessions unavailable")
    @store_threads.SessionChatUnavailable => @session_chats.Thrown("SessionChatUnavailable", "session chat unavailable")
    @session_hub.Refused(m) => @session_chats.Thrown("Refused", m)
    @session_storage.Thrown(kind, said) => @session_chats.Thrown(kind, jtext(said, "message").unwrap_or(said.stringify()))
    other => @session_chats.Thrown("", said_of(other))
  }
}

///|
/// One of the names the conversations ask (session_chats `World.call`).
async fn P52::chats_call(self : P52, name : String, args : Array[J], thrown : Ref[J]) -> J {
  let given = args.map(x => of_jv(x))
  thrown.val = Null
  let r = Ok(self.chats_answer(name, args, given)) catch { e => Err(e) }
  match r {
    Ok(v) => v
    Err(e) => raise thrown_of(e, thrown)
  }
}

///|
async fn P52::chats_answer(
  self : P52,
  name : String,
  raw : Array[J],
  args : Array[Json],
) -> J {
  let a = (i : Int32) => args.get(i).unwrap_or(Json::null())
  let s = (i : Int32) => {
    as_text(a(i)).unwrap_or("")
  }
  let (part, meth) = match name.find(".") {
    Some(i) => (name[:i].to_owned(), name[i + 1:].to_owned())
    None => (name, "")
  }
  match part {
    "store" if meth == "subscribe" => self.store_subscribe(raw.get(0).unwrap_or(Null))
    "store" => to_jv(self.store(meth, args))
    "hub" =>
      match meth {
        "has" => J::Bool(s(0) == "forkReview")
        "storeHas" => J::Bool(s(0) != "pendingCardHeaderIfReady")
        "chatHasApi" =>
          J::Bool(
            match connect_surfaces.get(s(0)) {
              Some(c) => @session_hub.chat_has(c, "api")
              None => false
            },
          )
        "chatHas" =>
          J::Bool(
            match connect_surfaces.get(s(0)) {
              Some(c) => @session_hub.chat_has(c, s(1))
              None => false
            },
          )
        "chatProp" =>
          if s(0) == @session_hub.internal_connect {
            match s(1) {
              "botUserId" => @jsjson.JValue::of_string("UEMBER")
              _ => j_undef()
            }
          } else {
            match connect_surfaces.get(s(0)).map(c => jfield(c, s(1))) {
              Some(Null) | None => j_undef()
              Some(v) => to_jv(v)
            }
          }
        "workspaces" => J::Arr(self.the_hub().workspaces().map(@jsjson.JValue::of_string))
        "nextTs" => @jsjson.JValue::of_string(self.the_hub().next_ts())
        // (hub.ts `peers()`: how a message for a chat moved to another station is carried there, messages.ts
        // `fromPeer`; one function kept, as the TypeScript's hook is one)
        "peers" => if self.bound() { self.peers_callback() } else { Null }
        "fetchedFor" => {
          let (text, files) = self
            .the_hub()
            .fetched(s(0), s(1), s(2), args[3:].to_owned())
          J::Arr([@jsjson.JValue::of_string(text), J::Arr(files.map(to_jv))])
        }
        // (hub.ts `fork(effect)` of review.ts `suggestArchive`: the review of a chat that ended all_done, run in the
        // background on the hub's runtime, a failure of it the review's own)
        "forkReview" => {
          let key = s(0)
          ignore(
            self.host.rt.fork_quiet(name="archive review", async fn() {
              @session_chats.review(self.chats_world(), key) catch {
                _ => ()
              }
            }),
          )
          Null
        }
        "fork" => Null
        _ => to_jv(@session_hub.hub_call(self.the_hub(), meth, args))
      }
    "chat" | "chatOf" => {
      let connect = s(0)
      if connect == @session_hub.internal_connect {
        match meth {
          "post" => @jsjson.JValue::of_string(@session_hub.next_ts_at(wall_ms().to_double()))
          "userName" =>
            match self.user_name(connect, s(1)) {
              Some(n) => @jsjson.JValue::of_string(n)
              None => Null
            }
          "botUserId" => @jsjson.JValue::of_string("UEMBER")
          _ => j_undef()
        }
      } else {
        to_jv(
          (self.bus.coord_ask.val)("chat." + meth, {
            "connect": jstr(connect),
            "args": Json::array(args[1:].to_owned()),
          }),
        )
      }
    }
    "actor" => {
      let key = s(0)
      guard self.actors_program is Some(p) else { return Null }
      match p.actors.get(key) {
        Some(actor) => to_jv(actor.hub_asked(meth, args[1:].to_owned()))
        None => Null
      }
    }
    "fn" => {
      let id = jnum_of(a(0), "$fn")
        .unwrap_or(-1.0)
        .to_int()
      match chat_state.callbacks.get(id) {
        Some(f) => f(raw[1:].to_owned())
        None => raise LiveError("no function \{id}")
      }
    }
    "log" => {
      slice_log(meth, s(0), s(1), a(2))
      Null
    }
    "fs" => to_jv(self.fs_op(meth, args))
    "files" => {
      let now = @host.now().to_double()
      if meth == "profileFilesRead" {
        // (a check reads the profile's files first: read again now, kept for `readLately`)
        match a(0) {
          Object(m) =>
            match m.get("home") {
              Some(String(home)) if home != "" =>
                for name in ["config.toml", "auth.json"] {
                  let p = @nodepath.join(sep(), [home, name])
                  self.read_lately[p] = (now, self.host.read_text(p) catch { _ => None })
                }
              _ => ()
            }
          _ => ()
        }
        Null
      } else {
        let p = s(0)
        let text = match self.read_lately.get(p) {
          Some((at, text)) if now - at < 10_000.0 => text
          _ => {
            let text = self.host.read_text(p) catch { _ => None }
            if self.read_lately.length() >= 256 && !self.read_lately.contains(p) {
              self.read_lately.clear()
            }
            self.read_lately[p] = (now, text)
            text
          }
        }
        match text {
          Some(t) => @jsjson.JValue::of_string(t)
          None => Null
        }
      }
    }
    "drivers" => J::Bool(self.drivers.contains(s(0)))
    "dep" => self.dep(meth, args)
    "presets" => to_jv(self.presets_answer(meth, args))
    "accounts" =>
      to_jv((self.bus.jobs_ask.val)("accounts." + meth, Json::array(args)))
    "logins" =>
      to_jv((self.bus.ui_ask.val)("logins." + meth, Json::array(args)))
    "repoIndex" => to_jv(self.repo_index_answer(meth, args))
    "net" => to_jv(self.net_fetch(meth, args))
    // (a runtime session of its own a conversation opens, apart from any actor's: regenerate_title.mbt's, a chat's
    // new title asked of one of its agents' runtimes, regenerate-title.ts `driver.open`)
    "driver" if meth == "open" => self.side_open(s(0), a(1), raw.get(2).unwrap_or(Null))
    "agent" => self.side_agent(meth, a(0), s(1))
    "driver" =>
      raise LiveError(
        "a conversation asked a runtime session directly (\{name}): opened through its actor here",
      )
    _ =>
      raise LiveError(
        "the conversations asked the station for \{name}, which it does not know",
      )
  }
}

///|
/// `driver.open` of a runtime session of the conversations' own: the driver of `runtime` opens it with `options`, its
/// events kept for `events` (a callback of theirs) as they come. A handle of it is answered (`{"$side": n}`).
async fn P52::side_open(self : P52, runtime : String, options : Json, events : J) -> J {
  guard self.drivers.get(runtime) is Some(driver) else { raise LiveError("no driver for \{runtime}") }
  let callback = jv_num(events, "$fn").unwrap_or(-1.0).to_int()
  let told : Array[J] = []
  let wake : Ref[@effect.Deferred[Unit]] = Ref(@effect.Deferred::new())
  let agent = (driver.open)(
    options,
    event => {
      told.push(event)
      ignore(wake.val.succeed(()))
    },
    () => false,
  )
  chat_state.next_side += 1
  let n = chat_state.next_side
  chat_state.sides[n] = { agent, told, wake, events: callback, until: wall_ms().to_double() + @session_chats.title_timeout_ms }
  Obj([("$side", Num(n.to_double()))])
}

///|
/// What a conversation asks of a runtime session it opened (`agent.<meth>`, its handle `handle`).
async fn P52::side_agent(_self : P52, meth : String, handle : Json, text : String) -> J {
  let n = jnum_of(handle, "$side").unwrap_or(-1.0).to_int()
  guard chat_state.sides.get(n) is Some(side) else { raise LiveError("no runtime session \{n} opened here") }
  match meth {
    "prompt" => {
      (side.agent.prompt)(text)
      Null
    }
    // (what it told since it was last asked, given the conversation's callback in order; none yet: waited for until
    // it tells some, or until its time is up, which ends the request as regenerate-title.ts's timeout does)
    "waitEvents" => {
      if side.told.length() == 0 {
        let left = side.until - wall_ms().to_double()
        let woke = if left <= 0.0 {
          None
        } else {
          @effect.timeout(left.to_int(), async fn() { side.wake.val.wait() })
        }
        if woke is None {
          raise @session_chats.Thrown("TitleError", "timeout")
        }
      }
      let given = side.told.copy()
      side.told.clear()
      side.wake.val = @effect.Deferred::new()
      match chat_state.callbacks.get(side.events) {
        Some(f) => for event in given { f([event]) |> ignore }
        None => ()
      }
      Null
    }
    "busy" => J::Bool((side.agent.busy)())
    "abort" => {
      (side.agent.abort)()
      Null
    }
    "dispose" => {
      chat_state.sides.remove(n)
      chat_state.callbacks.remove(side.events)
      (side.agent.dispose)()
      Null
    }
    _ => raise LiveError("a runtime session opened here answers no \{meth}")
  }
}

///|
/// Whether a path is in a folder macOS protects (ops/places.ts `protects`): Documents, Desktop, Downloads, disks.
fn protected_place(p : String) -> Bool {
  let home = homedir()
  ["Documents", "Desktop", "Downloads"]
  .iter()
  .any(d => p.has_prefix(path([home, d]))) ||
  p.has_prefix("/Volumes/")
}

///|
/// The files as the station's own file system answers (session_chats' `fs.*`).
async fn P52::fs_op(self : P52, op : String, args : Array[Json]) -> Json raise {
  host_fs_op(self.host, op, args) catch {
    DispatchFsError(c, m) => raise @session_chats.Thrown(c, m)
    e => raise e
  }
}

///|
/// The deps of src/sessions the conversations ask by name (stateful/IO/platform ops).
async fn P52::dep(
  self : P52,
  name : String,
  args : Array[Json],
) -> J {
  let a = (i : Int32) => args.get(i).unwrap_or(Json::null())
  let s = (i : Int32) => {
    as_text(a(i)).unwrap_or("")
  }
  let storage = self.storage()
  let opt = (v : Json) => {
    match v {
      Object(m) if m.get("$u") is Some(_) && m.length() == 1 => None
      Null => None
      x => Some(x)
    }
  }
  match name {
    "named" =>
      match
        storage.named(
          s(0),
          as_text(a(1)),
        ) {
        Thread(t) => to_jv({ "type": jstr("thread"), "thread": t })
        Session(key, n) =>
          to_jv({
            "type": jstr("session"),
            "key": jstr(key),
            "entry": match n {
              Some(x) => ji(x)
              None => Json::null()
            },
          })
      }
    "reachable" =>
      J::Bool(
        storage.reachable(
          s(0),
          as_text(a(1)),
          write=a(2) is True,
        ),
      )
    "scopeOf" => @jsjson.JValue::of_opt_string(storage.scope_of(s(0)))
    "sessionThreadOf" => to_jv(storage.session_thread_of(s(0)))
    "peersOf" =>
      match storage.peers_of(s(0)) {
        Some(call) => {
          // (a function the conversations call back, `fn`: the request to another station of the session's workspace)
          chat_state.next_cb += 1
          let id = chat_state.next_cb
          chat_state.callbacks[id] = async fn(given) {
            let station = match given.get(0) {
              Some(Str(u)) => @jsjson.sanitize_str(u)
              _ => ""
            }
            to_jv(call(station, of_jv(given.get(1).unwrap_or(Null))))
          }
          Obj([("$fn", Num(id.to_double()))])
        }
        None => Null
      }
    "sendable" =>
      J::Arr(
        storage
        .sendable(
          s(0),
          jitems(a(1)).map(x => {
            as_text(x).unwrap_or("")
          }),
        )
        .map(l => {
          to_jv({
            "path": jstr(l.path),
            "name": jstr(l.name),
            "size": jn(l.size),
          })
        }),
      )
    "prepareLocalLinks" =>
      match
        prepare_local_links(
          s(0),
          jitems(a(1)).map(x => {
            as_text(x).unwrap_or("")
          }),
          s(2),
        ) {
        Ok((text, paths)) =>
          to_jv({
            "text": jstr(text),
            "paths": Json::array(paths.map(Json::string)),
          })
        Err(why) => raise @session_chats.Thrown("", why)
      }
    "threadsToldOf" => J::Arr(self.the_hub().threads_told_of(s(0)).map(@jsjson.JValue::of_string))
    "newSession" => {
      let (key, thread) = self.the_hub().new_session(a(0), lang=self.lang())
      J::Arr([@jsjson.JValue::of_string(key), to_jv(thread)])
    }
    // (image-size.ts `shownFactsSoon`: a film's or a GIF's size, length and frames read from its head as hubops'
    // and the world's; the picture's ThumbHash is `keep`'s, made in its one decode)
    "shownFactsSoon" => to_jv(shown_facts(self.host, s(0)))
    "claim" => J::Arr(storage.claim(s(0), s(1), s(2), opt(a(3))).map(to_jv))
    "sendAlong" => {
      let peers = storage.peers_of(s(2))
      match peers {
        Some(call) => {
          let files = jitems(a(4)).map(f => {
            (
              {
                path: jtext(f, "path").unwrap_or(""),
                name: jtext(f, "name").unwrap_or(""),
                size: jnum_of(f, "size").unwrap_or(0.0),
              } : @session_storage.Listed)
          })
          J::Arr(
            storage
            .send_along(call, s(1), s(2), s(3), files)
            .map(p => to_jv({ "id": jstr(p.0), "name": jstr(p.1) })),
          )
        }
        None => J::Arr([])
      }
    }
    "keep" => J::Arr(@drive.keep(jitems(a(0)).map(to_jv), s(1), Some(codecs())))
    "fileURLToPath" => {
      let u = s(0)
      @jsjson.JValue::of_string(
        if u.has_prefix("file://") {
          @session_storage.percent_decode(u[7:].to_owned())
        } else {
          u
        },
      )
    }
    "opencodeGo" => j_undef()
    "parseUrl" => {
      let u = s(0)
      match u.find("://") {
        Some(i) => {
          let rest = u[i + 3:].to_owned()
          let host = match rest.find("/") {
            Some(j) => rest[:j].to_owned()
            None => rest
          }
          to_jv({
            "protocol": jstr(u[:i + 1].to_owned()),
            "host": jstr(host),
            "href": jstr(u),
          })
        }
        None => Null
      }
    }
    _ =>
      raise @session_chats.Thrown(
        "",
        "the conversations asked for dep.\{name}, which the station does not have",
      )
  }
}

// ── the agents' tools ──

///|
/// What the tools ask the station's parts by name (mcp_tools `ToolsBackend`): the conversations', the endpoint's own
/// (`mcp.*`), the log; what is another part's goes to it over the bus.
fn P52::tools_backend(self : P52) -> @mcp_tools.ToolsBackend {
  @mcp_tools.ToolsBackend::new(async fn(name, args) {
    self.tools_call(name, args)
  })
}

///|
async fn P52::tools_call(
  self : P52,
  name : String,
  args : Array[@api_routes.JV],
) -> @api_routes.JV {
  let a = (i : Int32) => args.get(i).unwrap_or(Null)
  let s = (i : Int32) => match a(i) { Str(x) => x; _ => "" }
  let opt_s = (i : Int32) => match a(i) { Str(x) => Some(x); _ => None }
  let jopt_jv = (x : String?) => match x { Some(t) => @api_routes.JV::Str(t); None => Null }
  let w = self.chats_world()
  let thrown = (e : Error) => {
    match e {
      @session_chats.Thrown(kind, m) =>
        @api_routes.Thrown(
          if kind == "" {
            "Error"
          } else {
            kind
          },
          @api_routes.jobj([("message", Str(m))]),
        )
      other =>
        @api_routes.Thrown(
          "Error",
          @api_routes.jobj([("message", Str(said_of(other)))]),
        )
    }
  }
  let run = async fn(f : async () -> @api_routes.JV) -> @api_routes.JV {
    f() catch {
      e => raise thrown(e)
    }
  }
  match name {
    "mcp.resolve" =>
      match self.bus.store.session_key_by_token(s(0)) {
        String(k) => Str(k)
        _ => @api_routes.jundef
      }
    "mcp.listing" => {
      let row = self.bus.store.get_session(s(0)) catch {
        _ => Json::null()
      }
      match @session_hub.runtime_named(jtext(row, "runtime").unwrap_or("")) {
        Some("agy") => @api_routes.jobj([("budget", @api_routes.jnum(22000.0))])
        Some("claude") =>
          @api_routes.jobj([
            (
              "loaded",
              @api_routes.jobj([
                ("anthropic/alwaysLoad", @api_routes.jbool(true)),
              ]),
            ),
          ])
        _ => @api_routes.jundef
      }
    }
    "mcp.gate" =>
      if self.bound() && self.in_its_workspace(s(0)) {
        @api_routes.jundef
      } else {
        Str(@mcp_tools.unbound_refusal)
      }
    "hub.store.handedTo" => to_jv(self.bus.store.handed_to(s(0)))
    "sessions/conversations.target" =>
      run(async fn() {
        @session_chats.target(
          w,
          s(1),
          match a(2) {
            Null => None
            x => Some(x)
          },
        )
      })
    "sessions/conversations.mayStage" =>
      run(async fn() {
        @api_routes.jbool(
          @session_chats.may_stage(w, a(1), a(2) is Bool(true)),
        )
      })
    "sessions/conversations.staged" =>
      run(async fn() {
        let (given, copies) = @session_chats.staged(
          w,
          s(1),
          a(2),
          a(3) is Bool(true),
        )
        chat_state.next_ref += 1
        let id = "staged.done:\{chat_state.next_ref}"
        chat_state.refs[id] = J::Arr(copies.map(@jsjson.JValue::of_string))
        @api_routes.jobj([
          ("args", given),
          ("done", @api_routes.jobj([("$ref", Str(id))])),
        ])
      })
    "sessions/conversations.unheld" =>
      run(async fn() {
        let held = @session_chats.unheld(w, s(1), a(2))
        @api_routes.jobj([
          ("args", held.args),
          (
            "id",
            match held.id {
              Some(i) => Str(i)
              None => Null
            },
          ),
        ])
      })
    "sessions/conversations.chatPost" =>
      run(async fn() {
        let held = a(3)
        let h : @session_chats.Held = {
          id: match @api_routes.jget(Some(held), "id") {
            Some(Str(i)) => Some(i)
            _ => None
          },
          args: @api_routes.jget(Some(held), "args").unwrap_or(a(2)),
        }
        Str(@session_chats.chat_post(w, s(1), a(2), h))
      })
    "sessions/conversations.chatState" =>
      run(async fn() { Str(@session_chats.chat_state(w, s(1), a(2))) })
    "sessions/conversations.chatLeave" =>
      run(async fn() { Str(@session_chats.chat_leave(w, s(1), a(2))) })
    "sessions/conversations.chatHistory" =>
      run(async fn() { Str(@session_chats.chat_history(w, s(1), a(2))) })
    "sessions/conversations.slackApi" =>
      run(async fn() {
        Str(@session_chats.slack_api(w, s(1), s(2), a(3), opt_s(4), opt_s(5), a(6) is Bool(true)))
      })
    "sessions/messages.sessionSend" =>
      run(async fn() { Str(@session_chats.session_send(w, s(1), a(2))) })
    "sessions/opened.chatCreate" =>
      run(async fn() { Str(@session_chats.chat_create(w, s(1), a(2))) })
    "sessions/review.suggestArchive" => {
      let key = s(1)
      ignore(self.host.rt.fork_quiet(name="suggest archive", async fn() { @session_chats.review(w, key) catch { _ => () } }))
      Null
    }
    "sessions/review.reviewUndecided" => {
      ignore(self.host.rt.fork_quiet(name="review undecided", async fn() { @session_chats.review_undecided_once(w) catch { _ => () } }))
      Null
    }
    "sessions/review.policyWs" => jopt_jv(self.ws_of(s(1)))
    "sessions/archive-policy.currentPolicy" =>
      run(async fn() { to_jv(self.storage().current_policy(opt_s(1)).to_json()) })
    "sessions/archive-policy.savePolicy" =>
      run(async fn() { jopt_jv(self.storage().save_policy(Some(of_jv(a(1))), of_jv(a(2)), opt_s(3))) })
    "sessions/chat-archive.chatArchive" =>
      run(async fn() { Str(self.storage().chat_archive(s(1), of_jv(a(2)))) })
    "sessions/chat-configure.chatConfigure" =>
      run(async fn() { Str(self.storage().chat_configure(s(1), of_jv(a(2)))) })
    "sessions/others.chatList" =>
      run(async fn() { Str(self.storage().chat_list(s(1), of_jv(a(2)))) })
    "sessions/others.scopeOf" => jopt_jv(self.storage().scope_of(s(1)))
    "sessions/others.chatRead" =>
      run(async fn() { Str(self.storage().chat_read(s(1), of_jv(a(2)), None, opt_s(4))) })
    "sessions/others.sessionHistory" =>
      run(async fn() { Str(self.storage().session_history(of_jv(a(1)), opt_s(2))) })
    "sessions/others.elsewhere" => jopt_jv(self.storage().elsewhere(s(1), s(2)))
    "sessions/others.readAfar" =>
      run(async fn() {
        Str(self.storage().read_afar(s(1), s(2), s(3), of_jv(a(4))))
      })
    "paths.data" => Str(self.data)
    // ── the relays tool's (agents.ts `relayTools`) ──
    "relays.ways" =>
      if (self.bus.cloud_state.val)() is Some(_) {
        @api_routes.jref("ways")
      } else {
        Null
      }
    "relays.workspaceOf" => jopt_jv(either(self.ws_of(s(0)), self.place().home))
    // (agents.ts `meshList`, `revoke`, `enroll`: the mesh directory's, P5-1's on the bus)
    "relays.meshList" =>
      match (self.bus.cloud_call.val)("meshList", { "workspace": of_jv(a(0)) }) {
        Null => @api_routes.jarr([])
        said => to_jv(said)
      }
    // (where no mesh answers them, a program with no P5-1's: refused as agents.ts refuses them with no directory)
    "relays.revoke" =>
      match (self.bus.cloud_call.val)("meshRevoke", { "workspace": of_jv(a(0)), "node": of_jv(a(1)) }) {
        Null => fail("native mesh relay control is not available on this station")
        said => to_jv(said)
      }
    "relays.enroll" =>
      match (self.bus.cloud_call.val)("meshEnroll", { "workspace": of_jv(a(0)), "name": of_jv(a(1)), "by": of_jv(a(2)) }) {
        Null => fail("native mesh relay enrollment is not available on this station")
        said => to_jv(said)
      }
    "relays.by" => {
      let row = self.bus.store.get_session(s(0)) catch { _ => Json::null() }
      Str(@session_hub.agent_name(jtext(row, "title"), s(0)))
    }
    "ways.view" => to_jv((self.bus.cloud_call.val)("ways", { "workspace": of_jv(a(0)) }))
    "ways.cloud.state" => (self.bus.cloud_state.val)().map(to_jv).unwrap_or(@api_routes.jundef)
    "mesh/ways.stillFails" => to_jv((self.bus.cloud_call.val)("stillFails", Json::null()))
    "mesh/ways.addRelay" =>
      to_jv((self.bus.cloud_call.val)("addRelay", { "workspace": of_jv(a(1)), "url": of_jv(a(2)), "by": of_jv(a(3)) }))
    "mesh/ways.removeRelay" =>
      to_jv((self.bus.cloud_call.val)("removeRelay", { "workspace": of_jv(a(1)), "url": of_jv(a(2)) }))
    // (relays.ts `probeRelay`: a relay reached over https, its answer's status, redirects followed as its `fetch` does)
    "fetch" => {
      let answer = (p5_oauth_io(self.host).fetch)({ url: s(0), method_: "GET", headers: [], body: None, timeout_ms: 10000, manual: false })
      @api_routes.jobj([("status", @api_routes.jnum(answer.status.to_double()))])
    }
    // ── the feedback's (feedback/module.ts) ──
    "plane.spec" => to_jv((self.bus.cloud_call.val)("spec", Json::null()))
    "plane.state.removed" => to_jv((self.bus.cloud_call.val)("removed", Json::null()))
    "plane.state.state" => (self.bus.cloud_state.val)().map(to_jv).unwrap_or(Null)
    "cloud/signed.signedPost" =>
      to_jv((self.bus.cloud_call.val)("signedPost", { "path": of_jv(a(2)), "tag": of_jv(a(3)), "value": of_jv(a(4)) }))
    "ops/agent-env.agentEnv" =>
      to_jv(Json::object(Map::from_array(@ops_platform.agent_env((self.bus.config_raw.val)()).map(kv => (kv.0, Json::string(kv.1))))))
    "agents.hub.notify" => {
      ignore(self.the_hub().command(s(0), "notify", [jstr(s(1))]))
      Null
    }
    // (the fixed reports told a while after the station starts and as each release is out: this side's own timers,
    // `start_feedback`)
    "ops/fibers.Fibers.after" | "plane.told" => Null
    "fs.readTail" => {
      let path = s(0)
      let most = match a(1) {
        Num(n) => n
        _ => 0.0
      }
      let (m, _) = self.host.shell("fs.meta", { "path": jstr(path) }) catch {
        _ => return Null
      }
      guard jfield(m, "exists") != Json::boolean(false) &&
        jnum_of(m, "size") is Some(size) else {
        return Null
      }
      let from = if size - most > 0.0 { size - most } else { 0.0 }
      let got = p51_file_piece(self.host, path, from, (size - from).to_int()) catch {
        _ => return Null
      }
      let text = @api_routes.utf8_text(got)
      Str(
        if from == 0.0 {
          text
        } else {
          match text.find("\n") {
            Some(i) => text[i + 1:].to_owned()
            None => text
          }
        },
      )
    }
    "base" =>
      match (self.bus.cloud_state.val)() {
        Some(st) if self.bound() =>
          match
            (jtext(st, "origin"), jtext(st, "workspace"), jtext(st, "station")) {
            (Some(o), Some(ws), Some(station)) =>
              Str("\{o}/w/\{ws}/s/\{station}")
            _ => Null
          }
        _ => Null
      }
    "agentName" => {
      let row = self.bus.store.get_session(s(0)) catch {
        _ => Json::null()
      }
      let title = jtext(row, "title")
      Str(@session_hub.agent_name(title, s(0)))
    }
    "os.hostname" => Str(hostname())
    "ops/version.version" => Str(self.bus.version)
    "agents.pageOf" =>
      match self.page_of(s(0)) {
        Some(l) => Str(l)
        None => @api_routes.jundef
      }
    _ => {
      if name.has_prefix("store.") {
        return to_jv(self.store(name[6:].to_owned(), args.map(of_jv)))
      }
      if name.has_prefix("staged.done:") {
        let copies = match chat_state.refs.get(name) {
          Some(Arr(c)) => c.map(s => @jsjson.jval_str_of(Some(s)).unwrap_or(""))
          _ => []
        }
        chat_state.refs.remove(name)
        @session_chats.staged_done(w, copies) catch {
          _ => ()
        }
        return Null
      }
      if name.has_prefix("ops/log.log.") {
        slice_log(name[12:].to_owned(), s(0), s(1), of_jv(a(2)))
        return Null
      }
      // (the forwards' are the gate's (P5-1 `@gate.Forwards`), answered on the bus as `$forwards`; the jobs' part
      // where no gate answers)
      if name.has_prefix("forwards.") {
        let given = args.map(of_jv)
        let answered = Some(
          self.bus.forwards_call(name, given),
        ) catch {
          _ => None
        }
        return to_jv(
          match answered {
            Some(v) => v
            None => (self.bus.jobs_ask.val)(name, Json::array(given))
          },
        )
      }
      // (another part's: the jobs', remote tasks', workspaces' and accounts' (P5-3); the screens', grants', devices' and
      // helper's (P5-4); the mesh's, moves', feedback's, updates' and the connects' (P5-5))
      let to = if name.has_prefix("jobs") ||
        name.has_prefix("remote") ||
        name.has_prefix("workspaceWatch") ||
        name.has_prefix("forwards") ||
        name.has_prefix("accounts") {
        self.bus.jobs_ask
      } else if name.has_prefix("screens") ||
        name.has_prefix("grants") ||
        name.has_prefix("helper") ||
        name.has_prefix("device") ||
        name.has_prefix("computer") ||
        name.has_prefix("door") {
        self.bus.ui_ask
      } else {
        self.bus.coord_ask
      }
      match (try { Ok((to.val)(name, Json::array(args.map(of_jv)))) } catch { e => Err(e) }) {
        Ok(v) => to_jv(v)
        Err(P54Refused(kind, said)) => raise @api_routes.Thrown(kind, to_jv(said))
        Err(e) => raise e
      }
    }
  }
}

///|
/// Whether the station is in a workspace now (agents.ts `bound`).
fn P52::bound(self : P52) -> Bool {
  match (self.bus.cloud_state.val)() {
    Some(s) =>
      jtext(s, "workspace") is Some(w) &&
      w != "" &&
      jfield(s, "removed_at") == Json::null()
    None => false
  }
}

///|
/// A session of a workspace the station is still in (agents.ts `inItsWorkspace`).
fn P52::in_its_workspace(self : P52, session : String) -> Bool {
  match self.ws_of(session) {
    None => true
    Some(ws) => self.workspaces().contains(ws)
  }
}

///|
/// The agents' tools (agents.ts `tools`): those of the chats, the archive policy, peer_forward, relays, permissions,
/// workspace_limit, skill_read and feedback, with what the station's parts add (parts.ts).
fn P52::tool_ctx(self : P52) -> @mcp_tools.Ctx {
  @mcp_tools.Ctx::new(self.tools_backend(), self.rwords, {
    runtime_kinds: @session_hub.runtime_kinds,
    station_lang: self.lang(),
    os: if is_windows() {
      "windows"
    } else if platform() == "darwin" {
      "darwin"
    } else {
      "linux"
    },
    arch: arch(),
  })
}

///|
fn P52::tools(self : P52) -> Array[@mcp_tools.Tool] {
  let c = self.tool_ctx()
  let tools = [
    ..@mcp_tools.chat_tools(c),
    ..@mcp_tools.archive_tools(c),
    ..@mcp_tools.remote_tools(c),
    ..@mcp_tools.workspace_size_tools(c),
    ..@mcp_tools.job_tools(c),
    ..@mcp_tools.screen_tools(c),
    ..@mcp_tools.permission_tools(
      c,
      grants=if platform() == "darwin" { Some("grants") } else { None },
    ),
    ..match self.computer {
      Some(computer) => @mcp_tools.computer_tools(computer)
      None => []
    },
    ..@mcp_tools.forward_tools(c),
    // (`list` says the mesh's relays as agents.ts's `meshList` does; enrolling and revoking one are the mesh
    // directory's (live_p5_1_scopes.mbt), refused where the endpoint keeps no scopes, as agents.ts refuses them)
    ..@mcp_tools.relay_tools(c, mesh_list=true, enroll=true, revoke=true),
    ..@mcp_tools.search_tools(c),
    // (feedback/module.ts: offered only where its part is live)
    ..match self.feedback {
      Some(part) => part.tools
      None => []
    },
  ]
  // (what the station's other parts add: tools/mcp.ts takes them as their own; one a part registers under a name
  // listed here is the part's, in that place: its instance holds the part's state, ours only asks it on the bus)
  for t in self.bus.parts.all_tools() {
    let tool = @mcp_tools.Tool::new(to_jv(t.declared), async fn(
      session,
      args,
      _,
    ) {
      let out = (t.call)(of_jv(args), { "session": jstr(session) })
      match out {
        String(text) => text
        // (a part's refusal stays one: the call said as failed, isError)
        { "content": Array([{ "text": String(text), .. }, ..]), "isError": True, .. } => raise @mcp_tools.Failed(text)
        { "content": Array([{ "text": String(text), .. }, ..]), .. } => text
        other => other.stringify()
      }
    })
    match tools.search_by(x => x.name == t.name) {
      Some(i) => tools[i] = tool
      None => tools.push(tool)
    }
  }
  // (in the order the TypeScript lists them, its tools then its parts' as main.ts's layers give them: a session handed
  // between the two keeps its list of tools, and so its runtime's cached prompt; one not named here after, as given)
  let place = (t : @mcp_tools.Tool) => tools_order.search(t.name).unwrap_or(tools_order.length())
  tools.mut_view().stable_sort_by((a, b) => place(a).compare(place(b)))
  tools
}

///|
let tools_order : Array[String] = [
  "chat_post", "slack_api", "chat_state", "chat_leave", "chat_history", "chat_list", "chat_read", "session_send", "chat_create",
  "chat_archive", "chat_configure", "session_history", "archive_policy", "station_list", "station_task", "station_file", "workspace_limit",
  "job_start", "job_list", "job_log", "job_stop", "screen", "permissions", "computer", "peer_forward", "relays",
  "station_version", "sign_in", "secret_list", "secret_use", "secret_save", "secret_describe", "secret_delete", "secret_cancel",
  "secret_reask", "secret_run", "phone_use", "phone_send", "adb_devices", "browser", "feedback_send", "feedback_reply",
  "skill_read", "search", "station_use", "device_list", "device_use", "station_retire", "station_move", "login", "feishu_api",
]

///|
/// The agents' door's `/mcp` (tools/http.ts over tools/mcp.ts `McpEndpoint`).
async fn P52::mcp(self : P52, r : Request) -> Reply {
  if self.mcp_draining {
    let is_tool_call = match attempt(() => @json.parse(@utf8.decode_lossy(r.body))) {
      Ok({ "method": String("tools/call"), .. }) => true
      _ => false
    }
    if is_tool_call {
      return json_reply(503, { "error": jstr("station is handing over") })
    }
  }
  self.in_flight_mcp += 1
  defer {
    self.in_flight_mcp -= 1
    if self.in_flight_mcp == 0 {
      if self.mcp_drained is Some(d) {
        self.mcp_drained = None
        ignore(d.succeed(()))
      }
    }
  }
  let endpoint = @mcp_tools.McpEndpoint::new(
    self.tools_backend(),
    () => self.tools(),
    now_ms=() => wall_ms(),
    on_tool=(tool_name, session, start_ms, end_ms, failed, err_type) => {
      let attrs : Array[(String, Json)] = [("stillfail.tool", jstr(tool_name))]
      if jtext((self.bus.store.get_session(session) catch { _ => Json::null() }), "runtime") is Some(rt) && rt != "" {
        attrs.push(("stillfail.runtime", jstr(rt)))
      }
      if failed {
        if err_type is Some(et) {
          attrs.push(("error.type", jstr(et)))
        }
      }
      (self.bus.emit_span.val)("mcp.tool", start_ms, end_ms, attrs, failed, false, 500)
    },
  )
  let answered = endpoint.handle(r.meth, r.header("authorization"), r.body)
  if r.meth == "POST" && answered.status == 200 {
    match attempt(() => @json.parse(@utf8.decode_lossy(r.body))) {
      Ok({ "method": String("tools/list" | "tools/call"), "id": _, .. }) => {
        let auth = r.header("authorization").unwrap_or("")
        let token = (if auth.has_prefix("Bearer ") || auth.has_prefix("bearer ") {
          auth[7:].to_owned()
        } else {
          auth
        }).trim().to_owned()
        if token != "" {
          match self.bus.store.session_key_by_token(token) {
            String(session) if session != "" => self.note_mcp_heard(session)
            _ => ()
          }
        }
      }
      _ => ()
    }
  }
  match answered.body {
    Some(b) => json_reply(answered.status, of_jv(b))
    None => { status: answered.status, headers: [], body: b"", }
  }
}
