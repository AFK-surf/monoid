// The agents' side (P5-2): what the conversations' parts (station/mb/src/session_chats, session_storage) and the
// agents' tools (mcp_tools) ask of the station by name, answered by its own parts: the store's calls, the hub's
// methods (session_hub `hub_call`), its readers (readops on the station's database), the deps of src/sessions as their
// MoonBit (session_hub, session_storage, agent_runtimes), the files; and the `/mcp` endpoint (tools/mcp.ts
// `McpEndpoint`) over the tools they make.

///|
using @jsjson {type JValue as J}

///|
fn j_undef() -> J {
  Obj([(@jsjson.units("$u"), Num(1.0))])
}

///|
/// The states the hub keeps of its own for the conversations (held posts, relayed chats' openings, title requests).
priv struct ChatState {
  held : Map[String, Map[String, J]]
  openings : Map[String, J]
  titles : Map[String, J]
  mut held_count : Int32
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
  held: Map([]),
  openings: Map([]),
  titles: Map([]),
  held_count: 0,
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
  {
    call: async fn(name, args) {
      lang.val = self.lang()
      self.chats_call(name, args, thrown)
    },
    callback: f => {
      chat_state.next_cb += 1
      let id = chat_state.next_cb
      chat_state.callbacks[id] = f
      Obj([(@jsjson.units("$fn"), Num(id.to_double()))])
    },
    words: self.cwords,
    lang,
    thrown,
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
  Obj([(@jsjson.units("$fn"), Num(stop_id.to_double()))])
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
          Some(Str(u)) => @jsjson.text(u)
          _ => ""
        }
        to_jv(self.storage_call("peers.call", [jstr(station), of_jv(given.get(1).unwrap_or(Null))]))
      }
      chat_state.peers_cb = Some(id)
      id
    }
  }
  Obj([(@jsjson.units("$fn"), Num(id.to_double()))])
}

///|
/// The conversations' storage parts (session_storage `Storage`), their station's calls answered here.
fn P52::storage(self : P52) -> @session_storage.Storage {
  @session_storage.Storage::new(
    @session_storage.Station::new(async fn(name, args) {
      self.storage_call(name, args)
    }),
    self.files,
  )
}

///|
async fn P52::storage_call(
  self : P52,
  name : String,
  args : Array[Json],
) -> Json {
  let a = (i : Int32) => args.get(i).unwrap_or(Json::null())
  if name.has_prefix("store.") {
    return self.store(name[6:].to_owned(), args)
  }
  match name {
    "hub.notify" => {
      self
      .the_hub()
      .act(as_text(a(0)).unwrap_or(""), "notify", args=[
        a(1),
      ])
      Json::null()
    }
    "hub.setOpening" => {
      chat_state.openings[a(0).stringify()] = to_jv(a(1))
      Json::null()
    }
    "fn.archiveChat" => {
      self.the_hub().archive_chat(a(0), a(1) is True)
      Json::null()
    }
    "fn.configure" => {
      let target = match a(0) { String(k) => k; _ => "" }
      self.the_hub().configure(target, a(1), lang="en")
      Json::null()
    }
    "fn.contextAsked" =>
      match @session_hub.context_asked(self.words, match a(0) { Null => None; x => Some(x) }, "en") {
        Some(Some(n)) => Json::number(n)
        _ => Json::null()
      }
    "fn.inferRuntime" => {
      let ws = match a(0) { String(w) => Some(w); _ => None }
      let cur = match a(1) { String(r) => r; _ => "" }
      let model = match a(2) { String(m) => m; _ => "" }
      let available = self.the_hub().profiles_in(ws)
      let rts_of = (p : Json) =>
        match jfield(p, "runtimes") {
          Array(xs) => xs.filter_map(x => match x { String(s) => Some(s); _ => None })
          _ => []
        }
      let fits_cur = available.iter().any(p => rts_of(p).contains(cur) && @session_hub.runs(p, model))
      if fits_cur {
        Json::null()
      } else {
        let matched : Array[String] = []
        for p in available {
          if @session_hub.runs(p, model) {
            for r in rts_of(p) {
              if !matched.contains(r) {
                matched.push(r)
              }
            }
          }
        }
        if matched.length() == 1 {
          Json::string(matched[0])
        } else if matched.length() > 1 {
          raise @session_storage.failed("model \{model} runs on multiple runtimes (\{matched.join(", ")}): pass runtime")
        } else {
          Json::null()
        }
      }
    }
    "clones.changed" => {
      self.bus.notify_store({ "type": jstr("clones") })
      Json::null()
    }
    "clones.kill" => {
      match a(0) {
        Number(pid, ..) => ignore(kill(pid.to_int(), "SIGKILL", group=true))
        _ => ()
      }
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
    match a(i) {
      String(x) => x
      _ => ""
    }
  }
  let (part, meth) = match name.find(".") {
    Some(i) => (name[:i].to_owned(), name[i + 1:].to_owned())
    None => (name, "")
  }
  let db = self.bus.db
  match part {
    "store" if meth == "subscribe" => self.store_subscribe(raw.get(0).unwrap_or(Null))
    "store" => to_jv(self.store(meth, args))
    "hub" =>
      match meth {
        "has" => {
          let readers = [
            "historyMessages", "latestMessages", "statePendingCard", "stateQuestion",
            "reviewPendingCard", "historyPendingCard", "openedChatSaid", "forkReview",
          ]
          J::Bool(readers.contains(s(0)))
        }
        "isNull" => J::Bool(false)
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
        "sameChat" => J::Bool(s(0) == s(1))
        "chatOfExists" =>
          J::Bool(
            s(0) == @session_hub.internal_connect ||
            (self.the_hub().world.chat)(s(0)) is Some(_),
          )
        "hasActor" => J::Bool(self.the_hub().actors.contains(s(0)))
        "actorId" =>
          if self.the_hub().actors.contains(s(0)) {
            @jsjson.JValue::of_string(s(0))
          } else {
            Null
          }
        "latestMessages" =>
          to_jv(@readops.latest_messages(db, { "thread": a(0), "limit": a(1) }))
        "openedChatSaid" =>
          to_jv(
            @readops.opened_chat_said(db, {
              "thread": a(0),
              "author": a(1),
              "agentOnly": a(2),
            }),
          )
        "historyMessages" =>
          to_jv(
            @readops.chat_history_messages(db, {
              "thread": a(0),
              "before": a(1),
              "limit": a(2),
            }),
          )
        "historyPendingCard" => to_jv(@readops.pending_card_number(db, a(0)))
        "stateQuestion" =>
          to_jv(
            @readops.state_question(db, {
              "key": a(0),
              "threads": a(1),
              "ts": a(2),
            }),
          )
        "statePendingCard" =>
          to_jv(@readops.state_pending_card(db, { "threads": a(0) }))
        "reviewPendingCard" =>
          to_jv(@readops.review_pending_card(db, { "thread": a(0) }))
        "link" => @jsjson.JValue::of_opt_string((self.the_hub().world.link)(s(0)))
        "workspaces" => J::Arr(self.the_hub().workspaces().map(@jsjson.JValue::of_string))
        "station" => @jsjson.JValue::of_opt_string((self.the_hub().world.station)())
        "wsOf" =>
          @jsjson.JValue::of_opt_string(
            self
            .the_hub()
            .ws_of(
              match a(0) {
                String(x) => Some(x)
                _ => None
              },
            ),
          )
        "surface" => @jsjson.JValue::of_string(self.the_hub().surface(s(0)))
        "nextTs" => @jsjson.JValue::of_string(self.the_hub().next_ts())
        "now" => J::Num(wall_ms().to_double())
        "config" => to_jv(self.config)
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
    "state" =>
      match meth {
        "heldGet" =>
          match chat_state.held.get(s(0)) {
            Some(m) => m.get(s(1)).unwrap_or(j_undef())
            None => j_undef()
          }
        "heldEnsure" => {
          if !chat_state.held.contains(s(0)) {
            chat_state.held[s(0)] = Map([])
          }
          Null
        }
        "heldSize" =>
          J::Num(
            chat_state.held
            .get(s(0))
            .map(m => m.length())
            .unwrap_or(0)
            .to_double(),
          )
        "heldDeleteOldest" => {
          match chat_state.held.get(s(0)) {
            Some(m) =>
              match m.keys().next() {
                Some(k) => m.remove(k)
                None => ()
              }
            None => ()
          }
          Null
        }
        "heldSet" => {
          match chat_state.held.get(s(0)) {
            Some(m) => m[s(1)] = raw.get(2).unwrap_or(Null)
            None => ()
          }
          Null
        }
        "heldDelete" => {
          match chat_state.held.get(s(0)) {
            Some(m) => m.remove(s(1))
            None => ()
          }
          Null
        }
        "heldCountNext" => {
          chat_state.held_count += 1
          J::Num(chat_state.held_count.to_double())
        }
        "openingGet" =>
          match chat_state.openings.get(a(0).stringify()) {
            Some(Obj(fs)) =>
              Obj([..fs, (@jsjson.units("$id"), raw.get(0).unwrap_or(Null))])
            Some(o) => o
            None => Null
          }
        "openingClaim" => {
          match chat_state.openings.get(a(0).stringify()) {
            Some(Obj(fs)) =>
              chat_state.openings[a(0).stringify()] = Obj(
                [
                  ..fs.filter(f => @jsjson.text(f.0) != "claimed"),
                  (@jsjson.units("claimed"), raw.get(2).unwrap_or(Null)),
                ],
              )
            _ => ()
          }
          Null
        }
        "openingDelete" => {
          chat_state.openings.remove(a(0).stringify())
          Null
        }
        "openingIs" => J::Bool(chat_state.openings.contains(a(0).stringify()))
        "titleRequestSet" => {
          chat_state.titles[a(0).stringify()] = raw.get(1).unwrap_or(Null)
          Null
        }
        "titleRequestGet" =>
          chat_state.titles.get(a(0).stringify()).unwrap_or(Null)
        "titleRequestDelete" => {
          chat_state.titles.remove(a(0).stringify())
          Null
        }
        _ => raise LiveError("no state op \{meth}")
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
    "db" => {
      let sql = s(0)
      let params = args[1:].to_owned()
      match meth {
        "exec" => {
          db.exec(sql)
          Null
        }
        "get" =>
          match db.all(sql, params) {
            [row, ..] => to_jv(Json::object(row))
            _ => j_undef()
          }
        "all" => J::Arr(db.all(sql, params).map(r => to_jv(Json::object(r))))
        _ => {
          ignore(db.run(sql, params))
          Null
        }
      }
    }
    "log" => {
      slice_log(meth, s(0), s(1), a(2))
      Null
    }
    "wall" => {
      match a(0) {
        Number(ms, ..) => @effect.sleep(ms.to_int())
        _ => ()
      }
      Null
    }
    "random" =>
      if meth == "uuid" {
        @jsjson.JValue::of_string(@drive.random_uuid())
      } else {
        let n = as_num(a(0))
          .unwrap_or(16.0)
          .to_int()
        @jsjson.JValue::of_string(@drive.hex(@drive.random_bytes(n)))
      }
    "fs" => to_jv(self.fs_op(meth, args))
    "os" => @jsjson.JValue::of_string(homedir())
    "path" => {
      let parts = args.map(x => {
        match x {
          String(t) => t
          _ => ""
        }
      })
      let start = parts
        .rev()
        .search_by(p => {
          p.has_prefix("/") || (p.length() > 1 && p[1:2].to_owned() == ":")
        })
      let from = match start {
        Some(i) => parts.length() - 1 - i
        None => -1
      }
      let base = if from < 0 {
        [@drive.cwd(), ..parts]
      } else {
        parts[from:].to_owned()
      }
      @jsjson.JValue::of_string(@nodepath.join(sep(), base))
    }
    "files" =>
      if meth == "profileFilesRead" {
        Null
      } else {
        match (self.host.read_text(s(0)) catch { _ => None }) {
          Some(t) => @jsjson.JValue::of_string(t)
          None => Null
        }
      }
    "drivers" => J::Bool(self.drivers.contains(s(0)))
    "dep" => self.dep(meth, raw, args)
    "presets" => to_jv(self.presets_answer(meth, args))
    "accounts" =>
      to_jv((self.bus.jobs_ask.val)("accounts." + meth, Json::array(args)))
    "logins" =>
      to_jv((self.bus.ui_ask.val)("logins." + meth, Json::array(args)))
    "places" =>
      match meth {
        "mac" => J::Bool(platform() == "darwin")
        "protects" => J::Bool(platform() == "darwin" && protected_place(s(0)))
        "file" => raw.get(0).unwrap_or(Null)
        _ => Null
      }
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
  let agent = (driver.open)(options, event => {
    told.push(event)
    ignore(wake.val.succeed(()))
  })
  chat_state.next_side += 1
  let n = chat_state.next_side
  chat_state.sides[n] = { agent, told, wake, events: callback, until: wall_ms().to_double() + @session_chats.title_timeout_ms }
  Obj([(@jsjson.units("$side"), Num(n.to_double()))])
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
  host_fs_op(self.host, op, args)
}

///|
/// What `P52::fs_op` answers, each call the shell's `fs.*` off the program's thread but `symlink`, `statfs`, `readHead`
/// and an exclusive `copyFile`.
async fn host_fs_op(host : @host.Host, op : String, args : Array[Json]) -> Json raise {
  let s = (i : Int32) => {
    match args.get(i) {
      Some(String(x)) => x
      _ => ""
    }
  }
  // What to write: a string's UTF-8, or the bytes a route gave (`{"$bytes": base64}`).
  let data = (i : Int32) => {
    match args.get(i) {
      Some(String(x)) => @utf8.encode(x)
      Some(Object({ "$bytes": String(b), .. })) =>
        @base64.decode(b) catch {
          _ => b""
        }
      _ => b""
    }
  }
  let fail = (e : Error) => {
    match e {
      @drive.FsError(f) => @session_chats.Thrown(f.code, f.message)
      other => @session_chats.Thrown("", said_of(other))
    }
  }
  // (the shell's `fs.*` failing, by Node's code and words for `call` on `p`)
  let shell_fail = (e : Error, call : String, p : String) => {
    let code = shell_fs_code(e)
    @session_chats.Thrown(code, fs_code_said(code, call, p))
  }
  let missing = (call : String, p : String) => @session_chats.Thrown("ENOENT", fs_code_said("ENOENT", call, p))
  // (read off the program's thread; Node's ENOENT where it does not open, as `@drive.read_all`'s)
  let read_whole = async fn(p : String) -> Bytes raise {
    match (host.read_bytes(p) catch { e => raise fail(e) }) {
      Some(b) => b
      None => raise @session_chats.Thrown("ENOENT", "ENOENT: no such file or directory, open '\{p}'")
    }
  }
  match op {
    "readText" =>
      Json::string(
        @utf8.decode_lossy(read_whole(s(0))),
      )
    "writeFile" => {
      // (node's `flag: "wx"`: refused where the file is there, as the hub's uploads ask it; made only where none is)
      let excl = args.get(2) is Some(Object({ "flag": String("wx"), .. }))
      let put : Json = {
        "path": jstr(s(0)),
        "offset": jn(0.0),
        "truncate": jb(true),
        "exclusive": jb(excl),
        "mode": jn(0o644.to_double()),
      }
      ignore(host.shell("fs.put", put, bytes=data(1))) catch {
        e => raise shell_fail(e, "open", s(0))
      }
      Json::null()
    }
    "appendFile" => {
      // (the hub's uploads add each part at the file's end, making it with the first)
      ignore(host.shell("fs.put", { "path": jstr(s(0)), "mode": jn(0o644.to_double()) }, bytes=data(1))) catch {
        e => raise shell_fail(e, "open", s(0))
      }
      Json::null()
    }
    "access" => {
      let (kind, _) = host.shell("fs.stat", { "path": jstr(s(0)) }) catch {
        e => raise shell_fail(e, "access", s(0))
      }
      if kind is Null {
        raise missing("access", s(0))
      }
      Json::null()
    }
    "statfs" =>
      // (statfs's fields: blocks of one byte each, as the disk's sizes say them)
      match disk_of(s(0)) {
        Some((free, total)) =>
          { "blocks": jn(total), "bavail": jn(free), "bsize": jn(1.0) }
        None =>
          raise @session_chats.Thrown(
            "ENOENT",
            "ENOENT: no such file or directory, statfs '\{s(0)}'",
          )
      }
    "rename" => {
      ignore(host.shell("fs.rename", { "from": jstr(s(0)), "to": jstr(s(1)) })) catch {
        e => raise shell_fail(e, "rename", s(0))
      }
      Json::null()
    }
    "mkdir" => {
      ignore(host.shell("fs.mkdir", { "path": jstr(s(0)) })) catch {
        e => raise shell_fail(e, "mkdir", s(0))
      }
      Json::null()
    }
    "rm" => {
      host_remove_tree(host, s(0))
      Json::null()
    }
    "copyFile" => {
      // (node's copyFile replaces what is there unless its mode says COPYFILE_EXCL (1); the drive's never does)
      let excl = match args.get(2) {
        Some(Number(m, ..)) => (m.to_int() & 1) == 1
        _ => false
      }
      if excl {
        @drive.copy_file(s(0), s(1)) catch {
          e => raise fail(e)
        }
      } else {
        host_copy_over(host, s(0), s(1)) catch {
          e => raise shell_fail(e, "copyfile", s(0))
        }
      }
      Json::null()
    }
    "symlink" => {
      if live_symlink_ffi(cstr(s(0)), cstr(s(1))) != 0 {
        raise @session_chats.Thrown(
          "EEXIST",
          "EEXIST: file already exists, symlink '\{s(0)}' -> '\{s(1)}'",
        )
      }
      Json::null()
    }
    "readdir" =>
      // (`withFileTypes`: each entry's name and whether it is a folder, as the routes read it)
      if args.get(1) is Some(Object({ "withFileTypes": True, .. })) {
        guard host_readdir_types(host, s(0)) is Some(entries) else { raise missing("scandir", s(0)) }
        Json::array(entries.map(e => ({ "name": jstr(e.0), "dir": jb(e.1 == "dir") } : Json)))
      } else {
        guard host_readdir_names(host, s(0)) is Some(names) else { raise missing("scandir", s(0)) }
        Json::array(names.map(Json::string))
      }
    "readdirTypes" => {
      // (the kinds the folder gives, a link neither a file nor a folder, as lstat says: no call for each entry)
      guard host_readdir_types(host, s(0)) is Some(entries) else { raise missing("scandir", s(0)) }
      Json::array(
        entries.map(e => ({ "name": jstr(e.0), "isFile": jb(e.1 == "file"), "isDirectory": jb(e.1 == "dir") } : Json)),
      )
    }
    "readBase64" =>
      Json::string(
        @drive.base64(read_whole(s(0))),
      )
    "stat" => {
      guard host_stat_follow(host, s(0)) is Some((kind, size, mtime)) else { raise missing("stat", s(0)) }
      { "isFile": jb(kind == "file"), "isDirectory": jb(kind == "dir"), "size": jn(size), "mtimeMs": jn(mtime) }
    }
    "readHead" => {
      let want = match args.get(1) {
        Some(Number(n, ..)) => n
        _ => 0.0
      }
      let show = match args.get(2) {
        Some(Number(n, ..)) => n.to_int()
        _ => want.to_int()
      }
      let (bytes, _, _) = @drive.read_part(s(0), 0.0, want) catch {
        e => raise fail(e)
      }
      let cut = if bytes.length() < show { bytes.length() } else { show }
      {
        "text": jstr(@utf8.decode_lossy(bytes[0:cut].to_owned())),
        "got": ji(bytes.length()),
      }
    }
    _ => raise @session_chats.Thrown("", "no fs op \{op}")
  }
}

///|
/// The deps of src/sessions the conversations ask by name, as their MoonBit.
async fn P52::dep(
  self : P52,
  name : String,
  raw : Array[J],
  args : Array[Json],
) -> J {
  let a = (i : Int32) => args.get(i).unwrap_or(Json::null())
  let s = (i : Int32) => {
    match a(i) {
      String(x) => x
      _ => ""
    }
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
    "USED_WITHIN_MS" => J::Num(@session_hub.used_within_ms)
    "accessKind" => @jsjson.JValue::of_string(@session_hub.access_kind(a(0)))
    "agyBaseModel" => {
      let (model, effort) = @session_hub.agy_base_model(s(0))
      to_jv(
        match effort {
          Some(e) => { "model": jstr(model), "effort": jstr(e) }
          None => { "model": jstr(model) }
        },
      )
    }
    "devinFusionBase" => {
      let model = @session_hub.devin_fusion_base(s(0))
      to_jv({ "model": jstr(model) })
    }
    "splitDevinFusion" =>
      match @session_hub.split_devin_fusion(s(0)) {
        Some((lead, effort, side)) =>
          to_jv(
            match effort {
              Some(e) =>
                { "lead": jstr(lead), "effort": jstr(e), "side": jstr(side) }
              None => { "lead": jstr(lead), "side": jstr(side) }
            },
          )
        None => Null
      }
    "askWhich" => @jsjson.JValue::of_string(@session_hub.ask_which(jitems(a(0)), s(1)))
    "candidates" =>
      J::Arr(
        @session_hub.candidates(
          jitems(a(0)),
          match a(1) {
            String(r) => Some(r)
            _ => None
          },
          leads=a(2) is True,
        ).map(to_jv),
      )
    "choose" =>
      to_jv(@session_hub.choose(jitems(a(0)), jitems(a(1)), leads=jitems(a(2))))
    "contextAsked" =>
      match @session_hub.context_asked(self.words, opt(a(0)), self.lang()) {
        None => j_undef()
        Some(None) => Null
        Some(Some(n)) => J::Num(n)
      }
    "firstLine" => @jsjson.JValue::of_string(@session_hub.first_line(s(0)))
    "fromBefore" => J::Bool(@session_storage.from_before(s(0)))
    "iso" =>
      @jsjson.JValue::of_string(
        @session_hub.iso(
          as_num(a(0)).unwrap_or(0.0),
        ),
      )
    "isSlackMethod" => J::Bool(@session_hub.is_slack_method(s(0)))
    "isSlackWrite" => J::Bool(@mcp_tools.is_slack_write(s(0)))
    "linkedSession" =>
      match @session_storage.linked_session(s(0)) {
        Some((key, n)) =>
          J::Arr([
            @jsjson.JValue::of_string(key),
            match n {
              Some(x) => J::Num(x.to_double())
              None => Null
            },
          ])
        None => Null
      }
    "linkedStation" => @jsjson.JValue::of_opt_string(@session_storage.linked_station(s(0)))
    "named" =>
      match
        storage.named(
          s(0),
          match a(1) {
            String(w) => Some(w)
            _ => None
          },
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
          match a(1) {
            String(w) => Some(w)
            _ => None
          },
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
              Some(Str(u)) => @jsjson.text(u)
              _ => ""
            }
            to_jv(call(station, of_jv(given.get(1).unwrap_or(Null))))
          }
          Obj([(@jsjson.units("$fn"), Num(id.to_double()))])
        }
        None => Null
      }
    "sendable" =>
      J::Arr(
        storage
        .sendable(
          s(0),
          jitems(a(1)).map(x => {
            match x {
              String(t) => t
              _ => ""
            }
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
    "needArg" =>
      match a(0) {
        Object(m) => @jsjson.JValue::of_opt_string(@session_hub.need_arg(m, a(1), s(2)))
        _ => Null
      }
    "stateArg" =>
      match @session_hub.state_arg(opt(a(0))) {
        Some((state, said)) => J::Arr([to_jv(state), @jsjson.JValue::of_string(said)])
        None => Null
      }
    "cardArg" =>
      match @session_hub.card_arg(opt(a(0)), opt(a(1))) {
        Some(c) => to_jv(c)
        None => Null
      }
    "cardSaid" => @jsjson.JValue::of_string(@session_hub.card_said(a(0)))
    "placeFigures" => @jsjson.JValue::of_string(@session_hub.place_figures(s(0), jitems(a(1))))
    "slackWithFiles" => {
      let (text, rest) = @session_hub.slack_with_files(
        self.words,
        s(0),
        jitems(a(1)),
        s(2),
      )
      J::Arr([@jsjson.JValue::of_string(text), @jsjson.JValue::of_string(rest)])
    }
    "prepareLocalLinks" =>
      match
        prepare_local_links(
          s(0),
          jitems(a(1)).map(x => {
            match x {
              String(t) => t
              _ => ""
            }
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
    // (agents/profiles.ts `profileRuntimes`: the runtimes an account runs, by its access; not a hub config's own list)
    "profileRuntimes" => J::Arr(@agent_runtimes.profile_runtimes(raw.get(0).unwrap_or(Null)).map(@jsjson.JValue::of_string))
    "profileEnv" => {
      let pairs = fields_pairs(@agent_runtimes.profile_env(to_jv(a(0)), s(1)))
      Obj(pairs.map(p => (@jsjson.units(p.0), @jsjson.JValue::of_string(p.1))))
    }
    "usable" => J::Bool(@session_hub.usable(a(0), None))
    // (image-size.ts `shownFactsSoon`: a film's or a GIF's size, length and frames read from its head as hubops'
    // and the world's; the picture's ThumbHash is `keep`'s, made in its one decode)
    "shownFactsSoon" => to_jv(shown_facts(self.host, s(0)))
    "makeReadStore" => @jsjson.JValue::of_string("readStore")
    "readStateQuestion" =>
      to_jv(
        @readops.state_question(self.bus.db, {
          "key": a(1),
          "threads": a(2),
          "ts": a(3),
        }),
      )
    "readStatePendingCard" =>
      to_jv(@readops.state_pending_card(self.bus.db, { "threads": a(1) }))
    "localeCompare" => J::Num(@drive.collate(s(0), s(1)).to_double())
    "policyFrom" => to_jv(@session_storage.policy_from(opt(a(0))).to_json())
    "policyQuestion" =>
      to_jv(
        @session_storage.policy_question(
          @session_storage.policy_from(Some({ "policy": a(0) })),
        ),
      )
    "archiveMass" =>
      J::Num(
        @session_storage.archive_mass(
          a(0),
          @session_storage.policy_from(Some({ "policy": a(1) })),
        ),
      )
    "recommends" =>
      J::Bool(
        @session_storage.recommends(
          a(0),
          @session_storage.policy_from(Some({ "policy": a(1) })),
          as_num(a(2)).unwrap_or(0.0),
        ),
      )
    "dshRoute" =>
      match @agent_runtimes.dsh_route(to_jv(a(0))) {
        Some(r) => r.json()
        None => Null
      }
    "expandRoute" => {
      let env = match a(0) {
        Object(m) =>
          m
          .iter()
          .map(kv => {
            (
              kv.0,
              match kv.1 {
                String(v) => v
                _ => ""
              },
            )
          })
          .to_array()
        _ => []
      }
      Obj(
        @agent_drivers.expand_route(env, s(1)).map(p => {
          (@jsjson.units(p.0), @jsjson.JValue::of_string(p.1))
        }),
      )
    }
    "apiSource" =>
      match
        @agent_runtimes.api_source(@agent_runtimes.profile_via(to_jv(a(0)))) {
        Some((_, at)) => J::Arr([Null, at.json()])
        None => j_undef()
      }
    "given" => @jsjson.JValue::of_opt_string(jtext(a(0), "given"))
    "titleOf" => {
      let t = a(0)
      let first = match a(1) {
        String(x) => Some(x)
        _ => None
      }
      @jsjson.JValue::of_string(
        match jtext(t, "title") {
          Some(title) if title != "" => title
          _ =>
            match first {
              Some(f) => @session_hub.first_line(f)
              None =>
                @agent_runtimes.thread_address(
                  jtext(t, "channel").unwrap_or(""),
                  jtext(t, "threadTs").unwrap_or(""),
                )
            }
        },
      )
    }
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
    "formatHistory" => {
      let names = jitems(a(4)).filter_map(p => {
        match p {
          Array([String(k), String(v), ..]) => Some((k, v))
          _ => None
        }
      })
      let cards : Map[Double, @agent_runtimes.HistoryCard] = Map([])
      for c in jitems(a(5)) {
        match c {
          Array([Number(n, ..), card, ..]) =>
            cards[n] = {
              card: match jfield(card, "card") {
                Null => None
                x => Some(to_jv(x))
              },
              pending: jfield(card, "pending") is True,
              chose: match jfield(card, "chose") {
                Object(_) as ch =>
                  Some(
                    (jtext(ch, "by").unwrap_or(""), to_jv(jfield(ch, "option"))),
                  )
                _ => None
              },
            }
          _ => ()
        }
      }
      @jsjson.JValue::of_string(
        @agent_runtimes.format_history(
          jitems(a(0)).map(to_jv),
          s(1),
          s(2),
          s(3),
          names,
          cards~,
        ),
      )
    }
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
    "modelKey" => @jsjson.JValue::of_string(s(0).to_lower())
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
    _ => {
      ignore(raw)
      raise @session_chats.Thrown(
        "",
        "the conversations asked for dep.\{name}, which the station does not have",
      )
    }
  }
}

// ── the agents' tools ──

///|
fn rjs(s : String) -> @api_routes.JV {
  Str(s)
}

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
  let s = (i : Int32) => {
    match a(i) {
      Str(x) => x
      _ => ""
    }
  }
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
          @api_routes.jobj([("message", rjs(m))]),
        )
      other =>
        @api_routes.Thrown(
          "Error",
          @api_routes.jobj([("message", rjs(said_of(other)))]),
        )
    }
  }
  let run = async fn(f : async () -> @api_routes.JV) -> @api_routes.JV {
    f() catch {
      e => raise thrown(e)
    }
  }
  let jvx = (v : @api_routes.JV) => to_jv(@jsjson.JV::to_json(v))
  match name {
    "mcp.resolve" =>
      match self.store("sessionKeyByToken", [jstr(s(0))]) {
        String(k) => rjs(k)
        _ => @api_routes.jundef
      }
    "mcp.listing" => {
      let row = self.store("getSession", [jstr(s(0))]) catch {
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
        rjs(@mcp_tools.unbound_refusal)
      }
    "hub.store.handedTo" => @jsjson.JV::of_json(self.store("handedTo", [jstr(s(0))]))
    "sessions/conversations.target" =>
      run(async fn() {
        @jsjson.JV::of_json(
          of_jv(
            @session_chats.target(
              w,
              s(1),
              match a(2) {
                Null => None
                x => Some(jvx(x))
              },
            ),
          ),
        )
      })
    "sessions/conversations.mayStage" =>
      run(async fn() {
        @api_routes.jbool(
          @session_chats.may_stage(w, jvx(a(1)), a(2) is Bool(true)),
        )
      })
    "sessions/conversations.staged" =>
      run(async fn() {
        let (given, copies) = @session_chats.staged(
          w,
          s(1),
          jvx(a(2)),
          a(3) is Bool(true),
        )
        chat_state.next_ref += 1
        let id = "staged.done:\{chat_state.next_ref}"
        chat_state.refs[id] = J::Arr(copies.map(@jsjson.JValue::of_string))
        @api_routes.jobj([
          ("args", @jsjson.JV::of_json(of_jv(given))),
          ("done", @api_routes.jobj([("$ref", rjs(id))])),
        ])
      })
    "sessions/conversations.unheld" =>
      run(async fn() {
        let held = @session_chats.unheld(w, s(1), jvx(a(2)))
        @api_routes.jobj([
          ("args", @jsjson.JV::of_json(of_jv(held.args))),
          (
            "id",
            match held.id {
              Some(i) => rjs(i)
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
          args: jvx(@api_routes.jget(Some(held), "args").unwrap_or(a(2))),
        }
        rjs(@session_chats.chat_post(w, s(1), jvx(a(2)), h))
      })
    "sessions/conversations.chatState" =>
      run(async fn() { rjs(@session_chats.chat_state(w, s(1), jvx(a(2)))) })
    "sessions/conversations.chatLeave" =>
      run(async fn() { rjs(@session_chats.chat_leave(w, s(1), jvx(a(2)))) })
    "sessions/conversations.chatHistory" =>
      run(async fn() { rjs(@session_chats.chat_history(w, s(1), jvx(a(2)))) })
    "sessions/conversations.slackApi" =>
      run(async fn() {
        rjs(
          @session_chats.slack_api(
            w,
            s(1),
            s(2),
            jvx(a(3)),
            match a(4) {
              Str(x) => Some(x)
              _ => None
            },
            match a(5) {
              Str(x) => Some(x)
              _ => None
            },
            a(6) is Bool(true),
          ),
        )
      })
    "sessions/messages.sessionSend" =>
      run(async fn() { rjs(@session_chats.session_send(w, s(1), jvx(a(2)))) })
    "sessions/opened.chatCreate" =>
      run(async fn() { rjs(@session_chats.chat_create(w, s(1), jvx(a(2)))) })
    "sessions/review.suggestArchive" => {
      let key = s(1)
      ignore(
        self.host.rt.fork_quiet(name="suggest archive", async fn() {
          @session_chats.review(w, key) catch {
            _ => ()
          }
        }),
      )
      Null
    }
    "sessions/review.reviewUndecided" => {
      ignore(
        self.host.rt.fork_quiet(name="review undecided", async fn() {
          @session_chats.review_undecided_once(w) catch {
            _ => ()
          }
        }),
      )
      Null
    }
    "sessions/review.policyWs" =>
      match self.ws_of(s(1)) {
        Some(ws) => rjs(ws)
        None => Null
      }
    "sessions/archive-policy.currentPolicy" =>
      run(async fn() {
        @jsjson.JV::of_json(
          self
          .storage()
          .current_policy(
            match a(1) {
              Str(x) => Some(x)
              _ => None
            },
          )
          .to_json(),
        )
      })
    "sessions/archive-policy.savePolicy" =>
      run(async fn() {
        match
          self
          .storage()
          .save_policy(
            Some(@jsjson.JV::to_json(a(1))),
            @jsjson.JV::to_json(a(2)),
            match a(3) {
              Str(x) => Some(x)
              _ => None
            },
          ) {
          Some(t) => rjs(t)
          None => Null
        }
      })
    "sessions/chat-archive.chatArchive" =>
      run(async fn() {
        rjs(self.storage().chat_archive(s(1), @jsjson.JV::to_json(a(2))))
      })
    "sessions/chat-configure.chatConfigure" =>
      run(async fn() {
        rjs(self.storage().chat_configure(s(1), @jsjson.JV::to_json(a(2))))
      })
    "sessions/others.chatList" =>
      run(async fn() { rjs(self.storage().chat_list(s(1), @jsjson.JV::to_json(a(2)))) })
    "sessions/others.scopeOf" =>
      match self.storage().scope_of(s(1)) {
        Some(x) => rjs(x)
        None => Null
      }
    "sessions/others.chatRead" =>
      run(async fn() {
        rjs(
          self
          .storage()
          .chat_read(
            s(1),
            @jsjson.JV::to_json(a(2)),
            None,
            match a(4) {
              Str(x) => Some(x)
              _ => None
            },
          ),
        )
      })
    "sessions/others.sessionHistory" =>
      run(async fn() {
        rjs(
          self
          .storage()
          .session_history(
            @jsjson.JV::to_json(a(1)),
            match a(2) {
              Str(x) => Some(x)
              _ => None
            },
          ),
        )
      })
    "sessions/others.elsewhere" =>
      match self.storage().elsewhere(s(1), s(2)) {
        Some(x) => rjs(x)
        None => Null
      }
    "sessions/others.readAfar" =>
      run(async fn() {
        rjs(self.storage().read_afar(s(1), s(2), s(3), @jsjson.JV::to_json(a(4))))
      })
    "sessions/others.linkedSession" =>
      match @session_storage.linked_session(s(0)) {
        Some((k, n)) =>
          @api_routes.jarr([
            rjs(k),
            match n {
              Some(x) => @api_routes.jnum(x.to_double())
              None => Null
            },
          ])
        None => Null
      }
    "paths.data" => rjs(self.data)
    // ── the relays tool's (agents.ts `relayTools`) ──
    "relays.ways" =>
      if (self.bus.cloud_state.val)() is Some(_) {
        @api_routes.jref("ways")
      } else {
        Null
      }
    "relays.workspaceOf" =>
      match self.ws_of(s(0)) {
        Some(ws) => rjs(ws)
        None =>
          match self.place().home {
            Some(h) => rjs(h)
            None => Null
          }
      }
    // (agents.ts `meshList`, `revoke`, `enroll`: the mesh directory's, P5-1's on the bus)
    "relays.meshList" =>
      match (self.bus.cloud_call.val)("meshList", { "workspace": @jsjson.JV::to_json(a(0)) }) {
        Null => @api_routes.jarr([])
        said => @jsjson.JV::of_json(said)
      }
    // (where no mesh answers them, a program with no P5-1's: refused as agents.ts refuses them with no directory)
    "relays.revoke" =>
      match (self.bus.cloud_call.val)("meshRevoke", { "workspace": @jsjson.JV::to_json(a(0)), "node": @jsjson.JV::to_json(a(1)) }) {
        Null => fail("native mesh relay control is not available on this station")
        said => @jsjson.JV::of_json(said)
      }
    "relays.enroll" =>
      match
        (self.bus.cloud_call.val)("meshEnroll", {
          "workspace": @jsjson.JV::to_json(a(0)),
          "name": @jsjson.JV::to_json(a(1)),
          "by": @jsjson.JV::to_json(a(2)),
        }) {
        Null => fail("native mesh relay enrollment is not available on this station")
        said => @jsjson.JV::of_json(said)
      }
    "relays.by" => {
      let row = self.store("getSession", [jstr(s(0))]) catch { _ => Json::null() }
      rjs(@session_hub.agent_name(jtext(row, "title"), s(0)))
    }
    "ways.view" => @jsjson.JV::of_json((self.bus.cloud_call.val)("ways", { "workspace": @jsjson.JV::to_json(a(0)) }))
    "ways.cloud.state" =>
      match (self.bus.cloud_state.val)() {
        Some(st) => @jsjson.JV::of_json(st)
        None => @api_routes.jundef
      }
    "mesh/ways.stillFails" => @jsjson.JV::of_json((self.bus.cloud_call.val)("stillFails", Json::null()))
    "mesh/ways.relayUrl" =>
      match @cloud_net.relay_url(@jsjson.JV::to_json(a(0)), insecure=a(1) is Bool(true)) {
        Some(u) => rjs(u)
        None => Null
      }
    "mesh/ways.addRelay" =>
      @jsjson.JV::of_json((self.bus.cloud_call.val)("addRelay", { "workspace": @jsjson.JV::to_json(a(1)), "url": @jsjson.JV::to_json(a(2)), "by": @jsjson.JV::to_json(a(3)) }))
    "mesh/ways.removeRelay" =>
      @jsjson.JV::of_json((self.bus.cloud_call.val)("removeRelay", { "workspace": @jsjson.JV::to_json(a(1)), "url": @jsjson.JV::to_json(a(2)) }))
    // (relays.ts `probeRelay`: a relay reached over https, its answer's status)
    "fetch" => {
      let answer = (p5_oauth_io(self.host).fetch)({
        url: s(0),
        method_: "GET",
        headers: [],
        body: None,
        timeout_ms: 10000,
        manual: true,
      })
      @api_routes.jobj([("status", @api_routes.jnum(answer.status.to_double()))])
    }
    // ── the feedback's (feedback/module.ts) ──
    "plane.spec" => @jsjson.JV::of_json((self.bus.cloud_call.val)("spec", Json::null()))
    "plane.state.removed" => @jsjson.JV::of_json((self.bus.cloud_call.val)("removed", Json::null()))
    "plane.state.state" =>
      match (self.bus.cloud_state.val)() {
        Some(st) => @jsjson.JV::of_json(st)
        None => Null
      }
    "cloud/signed.signedPost" =>
      @jsjson.JV::of_json((self.bus.cloud_call.val)("signedPost", { "path": @jsjson.JV::to_json(a(2)), "tag": @jsjson.JV::to_json(a(3)), "value": @jsjson.JV::to_json(a(4)) }))
    "ops/agent-env.agentEnv" =>
      @jsjson.JV::of_json(Json::object(Map::from_array(@ops_platform.agent_env((self.bus.config_raw.val)()).map(kv => (kv.0, Json::string(kv.1))))))
    "agents.hub.notify" => {
      self.the_hub().act(s(0), "notify", args=[jstr(s(1))])
      Null
    }
    // (the fixed reports told a while after the station starts and as each release is out: this side's own timers,
    // `start_feedback`)
    "ops/fibers.Fibers.after" | "plane.told" => Null
    "fs.open" => {
      tool_files_next.val += 1
      let h = "toolfile:\{tool_files_next.val}"
      tool_files[h] = s(0)
      @api_routes.jref(h)
    }
    "base" =>
      match (self.bus.cloud_state.val)() {
        Some(st) if self.bound() =>
          match
            (jtext(st, "origin"), jtext(st, "workspace"), jtext(st, "station")) {
            (Some(o), Some(ws), Some(station)) =>
              rjs("\{o}/w/\{ws}/s/\{station}")
            _ => Null
          }
        _ => Null
      }
    "agentName" => {
      let row = self.store("getSession", [jstr(s(0))]) catch {
        _ => Json::null()
      }
      let title = jtext(row, "title")
      rjs(@session_hub.agent_name(title, s(0)))
    }
    // (paths.ts `joinPath`: a path given whole stays as it is)
    "ops/paths.joinPath" =>
      rjs(
        if is_windows() {
          @ops_platform.win_join(s(0), s(1))
        } else {
          @ops_platform.unix_join(s(0), s(1))
        },
      )
    "os.hostname" => rjs(hostname())
    "ops/version.version" => rjs(self.bus.version)
    "agents.pageOf" =>
      match self.page_of(s(0)) {
        Some(l) => rjs(l)
        None => @api_routes.jundef
      }
    _ => {
      if name.has_prefix("store.") {
        return @jsjson.JV::of_json(self.store(name[6:].to_owned(), args.map(@jsjson.JV::to_json)))
      }
      // (a file the tools opened, `fs.open`: its size, a piece of it, let go)
      if name.has_prefix("toolfile:") {
        let (h, call) = match name.rev_find(".") {
          Some(i) => (name[:i].to_owned(), name[i + 1:].to_owned())
          None => (name, "")
        }
        guard tool_files.get(h) is Some(file) else { return Null }
        return match call {
          "stat" =>
            match attempt(() => @drive.stat(file)) {
              Ok(st) => @api_routes.jobj([("size", @api_routes.jnum(st.size))])
              Err(e) => raise thrown(e)
            }
          "read" => {
            let len = match a(1) {
              Num(n) => n.to_int()
              _ => 0
            }
            let pos = match a(2) {
              Num(n) => n
              _ => 0.0
            }
            let got = p51_file_piece(self.host, file, pos, len) catch { e => raise thrown(e) }
            @api_routes.jobj([("bytesRead", @api_routes.jnum(got.length().to_double())), ("buffer", @api_routes.jbytes(got))])
          }
          "close" => {
            tool_files.remove(h)
            Null
          }
          _ => Null
        }
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
        slice_log(name[12:].to_owned(), s(0), s(1), @jsjson.JV::to_json(a(2)))
        return Null
      }
      // (the forwards' are the gate's (P5-1 `@gate.Forwards`), answered on the bus as `$forwards`; the jobs' part
      // where no gate answers)
      if name.has_prefix("forwards.") {
        let given = Json::array(args.map(@jsjson.JV::to_json))
        let answered = Some(
          self.bus.call_peer("self", None, "$forwards", {
            "op": jstr(name),
            "args": given,
          }).0,
        ) catch {
          _ => None
        }
        return @jsjson.JV::of_json(
          match answered {
            Some(v) => v
            None => (self.bus.jobs_ask.val)(name, given)
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
      @jsjson.JV::of_json((to.val)(name, Json::array(args.map(@jsjson.JV::to_json))))
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
    let tool = @mcp_tools.Tool::new(@jsjson.JV::of_json(t.declared), async fn(
      session,
      args,
      _,
    ) {
      let out = (t.call)(@jsjson.JV::to_json(args), { "session": jstr(session) })
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
  let endpoint = @mcp_tools.McpEndpoint::new(self.tools_backend(), () => {
    self.tools()
  })
  let answered = endpoint.handle(r.meth, r.header("authorization"), r.body)
  match answered.body {
    Some(b) => json_reply(answered.status, @jsjson.JV::to_json(b))
    None => { status: answered.status, headers: [], body: b"", }
  }
}

///|
/// The files the tools opened (`fs.open`), by their handle: the path each reads.
let tool_files : Map[String, String] = Map([])

///|
let tool_files_next : Ref[Int] = Ref(0)
