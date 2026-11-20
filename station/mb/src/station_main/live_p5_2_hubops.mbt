// What the other parts ask of the agents' side by name on the bus (`hub_ask`), past the program's own (live_p5_2_main
// `hub_op`): the hub's methods (hub.ts, with or without `hub.`), the store's (`store.`, `hub.store.`), and the modules
// the admin API's routes import from outside src/api (`sessions/lifecycle.newSession`, `core/preset-records.starsOf`
// …: test/mb-api-routes.test.ts `MOCKED`), each as the station runs it: the hub's presets, clones and repository index,
// the archive's locks and files, the stars' records, the agents' environment, the wall's timers, the log. A part asked
// by reference (`{"$ref": "hub"}`, `{"$ref": "store"}`) is this side itself; a callback the routes gave
// (`{"$fn": id}`) is called back through P5-1's `$admin.called`.

///|
fn is_undef_json(j : Json) -> Bool {
  j is Object(m) && m.length() == 1 && m.contains("$undef")
}

///|
/// An argument as the TypeScript's function takes it: undefined (`{"$undef"}`) as null.
fn arg_or_null(args : Array[Json], i : Int) -> Json {
  match args.get(i) {
    Some(j) if !is_undef_json(j) => j
    _ => Json::null()
  }
}

///|
fn arg_opt_text(args : Array[Json], i : Int) -> String? {
  opt_str(args.get(i))
}

///|
fn arg_text(args : Array[Json], i : Int) -> String {
  arg_opt_text(args, i).unwrap_or("")
}

///|
/// The arguments past a leading part given by reference (`{"$ref": "hub"}`: the module's function takes the hub first).
fn past_ref(args : Array[Json]) -> Array[Json] {
  match args.get(0) {
    Some(Object(m)) if m.contains("$ref") => args[1:].to_owned()
    _ => args
  }
}

///|
fn undef_json() -> Json {
  { "$undef": Json::number(1.0) }
}

///|
/// What a part throws, as the admin API's routes take it (`instanceof` by its kind, its message, its status).
fn routes_thrown(e : Error) -> Error {
  match e {
    @api_routes.Thrown(_, _) | @api_routes.Refused(_, _) => e
    // (regenerate-title.ts `TitleError`: what went wrong is its `problem`, the route's words chosen by it)
    @session_chats.Thrown("TitleError", m) =>
      @api_routes.Thrown("TitleError", to_jv({ "message": Json::string(m), "problem": Json::string(m) }))
    @session_chats.Thrown(kind, m) =>
      @api_routes.Thrown(if kind == "" { "Error" } else { kind }, to_jv({ "message": Json::string(m) }))
    @session_storage.Thrown(kind, said) =>
      @api_routes.Thrown(
        if kind == "" { "Error" } else { kind },
        to_jv(
          match said {
            Object(_) => said
            _ => { "message": said }
          },
        ),
      )
    other => @api_routes.Thrown("Error", to_jv({ "message": Json::string(said_of(other)) }))
  }
}

///|
/// A callback a route gave (`{"$fn": id}`), called with `args`: its answer.
async fn P52::called(self : P52, f : Json, args : Array[Json]) -> Json {
  match f {
    { "$fn": Number(_, ..) as id, .. } =>
      self.bus.admin_called(id, args)
    _ => Json::null()
  }
}

///|
/// preset-records.ts `starsOf`: a person's stars as a device or a station says them, checked; a RecordRefusal saying
/// what is wrong.
fn stars_of(raw : Json) -> Json raise {
  let refuse = (m : String) => @api_routes.Thrown("RecordRefusal", to_jv({ "message": Json::string(m) }))
  guard raw is Object(m) else { raise refuse("stars: an object of models' stars") }
  if m.length() > 200 {
    raise refuse("stars: 200 models at most")
  }
  let count = (v : Json?, least : Double) => match v {
    Some(Number(n, ..)) => n == n.floor() && n.abs() <= 9007199254740991.0 && n >= least
    _ => false
  }
  let out : Map[String, Json] = {}
  for k, s in m {
    if k == "" || k.length() > 200 {
      raise refuse("stars: a model's key is 1 to 200 characters")
    }
    match s {
      Object(f) if f.get("on") is Some(True | False) && count(f.get("rev"), 1.0) && count(f.get("at"), 0.0) =>
        out[k] = { "on": f["on"], "rev": f["rev"], "at": f["at"] }
      _ => raise refuse("stars: \{k} is {on, rev, at}")
    }
  }
  Json::object(out)
}

///|
fn star_num(s : Json, k : String) -> Double {
  match s {
    Object(m) =>
      match m.get(k) {
        Some(Number(n, ..)) => n
        _ => 0.0
      }
    _ => 0.0
  }
}

///|
fn star_on(s : Json) -> Bool {
  s is Object(m) && m.get("on") is Some(True)
}

///|
/// preset-records.ts `newerStar`: the higher `rev`; then the unstarring; then the later `at`.
fn newer_star(a : Json, b : Json) -> Json {
  if star_num(a, "rev") != star_num(b, "rev") {
    return if star_num(a, "rev") > star_num(b, "rev") { a } else { b }
  }
  if star_on(a) != star_on(b) {
    return if star_on(a) { b } else { a }
  }
  if star_num(b, "at") > star_num(a, "at") {
    b
  } else {
    a
  }
}

///|
/// preset-records.ts `mergeStars`: `given` into `kept`, the newer of each; past 200 the oldest unstarrings go first, the
/// oldest stars after them; its keys in order.
fn merge_stars(kept : Json, given : Json) -> Json {
  let all : Map[String, Json] = match kept {
    Object(m) => m.copy()
    _ => {}
  }
  match given {
    Object(g) =>
      for k, v in g {
        all[k] = match all.get(k) {
          None => v
          Some(was) => newer_star(was, v)
        }
      }
    _ => ()
  }
  let keys = all.keys().collect()
  keys.sort()
  let mut kept_keys = keys
  if keys.length() > 200 {
    let going = keys.copy()
    going.sort_by((a, b) => {
      let on = (if star_on(all[a]) { 1 } else { 0 }) - (if star_on(all[b]) { 1 } else { 0 })
      if on != 0 {
        return on
      }
      let at = compare(star_num(all[a], "at"), star_num(all[b], "at"))
      if at != 0 {
        at
      } else {
        compare(a, b)
      }
    })
    let gone : Map[String, Unit] = {}
    for k in going[:keys.length() - 200] {
      gone[k] = ()
    }
    kept_keys = keys.filter(k => !gone.contains(k))
  }
  let out : Map[String, Json] = {}
  for k in kept_keys {
    out[k] = all[k]
  }
  Json::object(out)
}

///|
/// A picture's or a film's size as shown (image-size.ts `shownFactsSoon`), its bytes read a piece at a time as the
/// reading asks (a film's moov box may be anywhere in 50 MB); none where it does not read.
fn shown_facts(host : @host.Host, file : String) -> Json {
  guard attempt(() => @drive.stat(file)) is Ok(st) && st.file else { return Json::null() }
  let chunk_most = 65536
  let held : Ref[(Double, Bytes)] = Ref((0.0, b""))
  let src : @session_chats.Src = {
    size: st.size,
    read: fn(at : Double, n : Int) {
      let (from, bytes) = held.val
      if at >= from && at + n.to_double() <= from + bytes.length().to_double() {
        let a = (at - from).to_int()
        return bytes[a:a + n].to_bytes()
      }
      let want = if n > chunk_most { n } else { chunk_most }
      let got = p51_file_piece_now(host, file, at, want) catch { _ => b"" }
      held.val = (at, got)
      got[0:if got.length() < n { got.length() } else { n }].to_bytes()
    },
  }
  match @session_chats.facts_of_src(src) {
    Some(f) => of_jv(f.to_j())
    None => Json::null()
  }
}

///|
/// One of the presets' names the conversations' world asks (hub.ts `presets`, its `PresetsPlace`), and the lifecycle's
/// (`presets.refusal`, `presets.keep`: lifecycle.ts `presetRefusal`, `keepCopy`, `keepFor`).
async fn P52::presets_answer(self : P52, meth : String, args : Array[Json]) -> Json {
  let w = self.chats_world()
  let first = self.workspaces().get(0)
  match meth {
    "home" =>
      Json::string(
        self.files.workspace_agent_home_path(self.agent_home(), arg_opt_text(args, 0), first),
      )
    "now" => Json::number(wall_ms().to_double())
    "station" => jopt((self.the_hub().world.station)())
    "stationName" =>
      (self.bus.cloud_call.val)("stationName", { "id": Json::string(arg_text(args, 0)) })
    "workspace" =>
      match arg_opt_text(args, 0) {
        Some(ws) => Json::string(ws)
        None => jopt(first)
      }
    "list" => Json::array(@session_chats.presets_list(w, to_jv(arg_or_null(args, 0))).map(of_jv))
    "isHere" => Json::boolean(@session_chats.presets_is_here(w, arg_text(args, 0)))
    "nameOf" => Json::string(@session_chats.presets_name_of(w, arg_text(args, 0), arg_opt_text(args, 1)))
    "refusal" => {
      let o = args.get(0).unwrap_or(Json::null())
      let ws = match jfield(o, "ws") {
        String(x) => Json::string(x)
        _ => jopt(first)
      }
      let bound = match jfield(o, "copy") {
        Null => {
          guard jtext(o, "preset") is Some(id) else { return Json::null() }
          @session_chats.presets_get(w, to_jv(ws), id)
        }
        c => to_jv(c)
      }
      if bound is Null {
        return Json::null()
      }
      let here = (self.the_hub().world.station)()
      let asked = to_jv({ "runtime": jfield(o, "runtime"), "model": jfield(o, "model") })
      jopt(@session_chats.preset_refusal(self.cwords, bound, here, asked, jtext(o, "lang").unwrap_or(self.lang())))
    }
    "keep" => {
      let o = args.get(0).unwrap_or(Json::null())
      let workspace = jtext(o, "workspace").unwrap_or("")
      match jfield(o, "copy") {
        Null =>
          match jtext(o, "preset") {
            Some(id) => {
              let ws = match jfield(o, "ws") {
                String(x) => Json::string(x)
                _ => jopt(first)
              }
              of_jv(@session_chats.presets_keep_for(w, workspace, to_jv(ws), id))
            }
            None => Json::null()
          }
        copy => of_jv(@session_chats.keep_copy(w, workspace, to_jv(copy)))
      }
    }
    _ => raise LiveError("the presets have no \{meth}")
  }
}

///|
/// What the repository index's world asks (hub.ts `repoIndex`'s options): the home walked, its file in the data
/// directory, which it never looks into.
async fn P52::repo_index_answer(self : P52, meth : String, args : Array[Json]) -> Json raise {
  match meth {
    "file" => Json::string(path([self.data, "repo-index.json"]))
    "now" => Json::number(wall_ms().to_double())
    "roots" => Json::array([Json::string(homedir())])
    "besides" => Json::array([Json::string(self.data)])
    "guarded" => Json::boolean(platform() == "darwin" && protected_place(arg_text(args, 0)))
    "list" => self.fs_op("readdirTypes", args)
    _ => raise LiveError("the repository index has no \{meth}")
  }
}

///|
/// presets.ts RepoIndex `repos`: the repositories as the last pass found them; a pass begun where there is none or it
/// is old, `walked` told as it ends.
async fn P52::repo_index_repos(self : P52, walked : Json) -> Json {
  let w = self.chats_world()
  let (repos, due) = self.repo_index.repos(w)
  if due && !self.repo_walking {
    self.repo_walking = true
    fork_bg(self.host, "repositories' index", async fn() {
      self.repo_index.walk(w) catch {
        e => slice_log("warn", "presets", "the repositories were not looked for", { "error": jstr(said_of(e)) })
      }
      self.repo_walking = false
      ignore(self.called(walked, [])) catch {
        _ => ()
      }
    })
  }
  Json::array(repos.map(of_jv))
}

///|
/// ops/fibers.ts `wall.every`: `f` called every `ms` until its handle is told (`wall.every.stop:<n>`).
fn P52::wall_every(self : P52, ms : Double, f : Json) -> Json {
  self.ids_seq.val += 1
  let handle = "wall.every.stop:\{self.ids_seq.val}"
  let going = Ref(true)
  self.everies[handle] = going
  fork_bg(self.host, "a route's heartbeat", async fn() {
    while going.val {
      @effect.sleep(if ms < 1.0 { 1 } else { ms.to_int() }) // timer: a heartbeat a route keeps (usage.ts)
      if !going.val {
        break
      }
      ignore(self.called(f, [])) catch {
        _ => ()
      }
    }
  })
  { "$ref": Json::string(handle) }
}

///|
/// What a route asks of the hub's side by a module's function or the hub's own (see the top of this file).
async fn P52::hub_bridge(self : P52, op : String, given : Array[Json]) -> Json {
  let args = past_ref(given)
  let hub = self.the_hub()
  let w = () => self.chats_world()
  let r = try {
    // ── the store's ──
    match op {
      "store.prepareLatestThreads" | "hub.prepareLatestThreads" =>
        return self.bus.reader_latest_threads(arg_or_null(args, 0))
      // (replica/module.ts `retired`: a retired workspace's chats said to be out of its sight, idempotent)
      "store.setSessionsWsRetired" => {
        let ws = arg_text(args, 0)
        let home = arg_opt_text(args, 1)
        self.bus.store.set_sessions_ws(if home == Some(ws) { Json::null() } else { Json::string(ws) }, Json::string("retired:" + ws))
        return Json::null()
      }
      _ => ()
    }
    if op.has_prefix("hub.store.") {
      return self.store(op[10:].to_owned(), args)
    }
    if op.has_prefix("store.") {
      return self.store(op[6:].to_owned(), args)
    }
    // ── a handle a part was given ──
    if op.has_prefix("wall.every.stop:") {
      match self.everies.get(op) {
        Some(going) => {
          going.val = false
          self.everies.remove(op)
        }
        None => ()
      }
      return Json::null()
    }
    // ── the files (fs/promises as the routes use it) ──
    if op.has_prefix("fs.") {
      return self.fs_op(op[3:].to_owned(), args)
    }
    // ── the log ──
    if op.has_prefix("ops/log.log.") {
      slice_log(op[12:].to_owned(), arg_text(args, 0), arg_text(args, 1), arg_or_null(args, 2))
      return Json::null()
    }
    match op {
      // ── hub.ts's own parts ──
      "hub.config" => self.config
      "hub.reposDir" => Json::string(self.repos_dir())
      "hub.agentHome" => Json::string(self.agent_home())
      "hub.prepareCardPosts" => (self.bus.reader_ask.val)("$cardPosts", arg_or_null(args, 0), "zh")
      // (what the other parts ask of the hub by its fields (`hub.prepareCardPosts != null`): the readers' builders are
      // this side's; the rest as the conversations' world answers it)
      "hub.has" if ["prepareCardPosts", "prepareLatestThreads"].contains(arg_text(args, 0)) => Json::boolean(true)
      // (card-place.ts `postCard`'s `hub.actors.get(session)?.messageIdentity()`: who the card is said by)
      "hub.identity" => of_jv(self.chats_answer("actor.messageIdentity", args.map(to_jv), args))
      // (`hub.chat(connect).post` as the vault's cards say theirs: the thread's connect, channel, ts and the text)
      "hub.post" =>
        Json::string(self.chat_post(arg_text(args, 0), arg_text(args, 1), arg_text(args, 2), arg_text(args, 3), []))
      // (adb/card.ts's `chat.post` as the phones', devices' and rigs' cards say it: connect, thread, text, files)
      "chat.post" => {
        let here = arg_or_null(args, 1)
        Json::string(
          self.chat_post(
            arg_text(args, 0),
            jtext(here, "channel").unwrap_or(""),
            jtext(here, "threadTs").unwrap_or(""),
            arg_text(args, 2),
            jitems(arg_or_null(args, 3)),
          ),
        )
      }
      // (a part that queued a decided card's outcome itself, its request written in the same transaction where it shares
      // the chats' connection (the phones, the rigs: live_dispatch.mbt `dispatch_threads_card`), after it on the vault's)
      "cardOutcomes.wake" => {
        match self.card_outcomes {
          Some(worker) => {
            worker.wake()
            self.outcomes_follow()
          }
          None => ()
        }
        Json::null()
      }
      // ── card-place.ts and adb/title.ts, as the rigs ask them (requests.ts `hub`) ──
      "dep.postCard" =>
        of_jv(
          @session_chats.post_card(w(), arg_text(args, 0), to_jv(arg_or_null(args, 1)), arg_text(args, 2), to_jv(arg_or_null(args, 3)), None, None),
        )
      "dep.cardPlace" =>
        match @session_chats.card_place(w(), arg_text(args, 0), to_jv(arg_or_null(args, 1)), to_jv(arg_or_null(args, 2))) {
          Some(p) => of_jv(p)
          None => undef_json()
        }
      "dep.grantChatTitle" => jopt(self.grant_chat_title(arg_or_null(args, 0)))
      "hub.presets.list" => Json::array(@session_chats.presets_list(w(), to_jv(arg_or_null(args, 0))).map(of_jv))
      "hub.presets.listed" =>
        Json::array(@session_chats.presets_listed(w(), to_jv(arg_or_null(args, 0))).map(of_jv))
      "hub.presets.kept" =>
        Json::array(
          @session_chats.presets_kept(w(), to_jv(arg_or_null(args, 0)), to_jv(arg_or_null(args, 1))).map(of_jv),
        )
      "hub.presets.others" =>
        Json::array(
          @session_chats.presets_others(w(), to_jv(arg_or_null(args, 0)), to_jv(arg_or_null(args, 1))).map(of_jv),
        )
      "hub.presets.carry" =>
        of_jv(
          @session_chats.presets_carry(
            w(),
            to_jv(arg_or_null(args, 0)),
            to_jv(arg_or_null(args, 1)),
            jitems(arg_or_null(args, 2)).map(to_jv),
          ),
        )
      "hub.presets.add" =>
        of_jv(
          @session_chats.presets_add(w(), to_jv(arg_or_null(args, 0)), to_jv(arg_or_null(args, 1)), arg_text(args, 2), arg_text(args, 3)),
        )
      "hub.presets.put" =>
        of_jv(
          @session_chats.presets_put(
            w(),
            to_jv(arg_or_null(args, 0)),
            arg_text(args, 1),
            to_jv(arg_or_null(args, 2)),
            match args.get(3) {
              Some(x) if !is_undef_json(x) => Some(to_jv(x))
              _ => None
            },
          ),
        )
      "hub.presets.delete" => {
        @session_chats.presets_delete(
          w(),
          to_jv(arg_or_null(args, 0)),
          arg_text(args, 1),
          match args.get(2) {
            Some(x) if !is_undef_json(x) => Some(to_jv(x))
            _ => None
          },
        )
        Json::null()
      }
      "hub.clones.list" => Json::array(self.storage().clones_list(arg_opt_text(args, 0)))
      "hub.clones.drop" => Json::boolean(self.storage().clones_drop(arg_opt_text(args, 0), arg_text(args, 1)))
      "hub.clones.start" => {
        let changed = arg_or_null(args, 3)
        self
        .storage()
        .clones_start(
          arg_opt_text(args, 0),
          match args.get(1) {
            Some(x) if !is_undef_json(x) => Some(x)
            _ => None
          },
          arg_text(args, 2),
          async fn() { ignore(self.called(changed, [])) },
        )
      }
      "hub.repoIndex.repos" => self.repo_index_repos(arg_or_null(args, 0))
      "hub.accounts.change" | "hub.accounts.modelEfforts" =>
        (self.bus.jobs_ask.val)(op[4:].to_owned(), Json::array(args))
      "hub.toldBots" => {
        hub.set_told_bots(arg_text(args, 0), jitems(arg_or_null(args, 1)).map(b => as_text(b).unwrap_or("")))
        Json::null()
      }
      // (replica/handover.ts's store/handover.ts and read/usage.ts, as a hand-over of chats asks them)
      "fn.handedStations" => Json::array(@store_sessions.handed_stations(self.bus.db))
      "fn.handedWithUsage" =>
        Json::array(
          @store_sessions.handed_with_usage(
            self.bus.db,
            arg_or_null(args, 0),
            arg_or_null(args, 1),
            opt_num(args.get(2)).map(n => n.to_int()).unwrap_or(10),
          ),
        )
      "fn.threadRefs" => Json::array(@store_sessions.thread_refs(self.bus.db, arg_or_null(args, 0), jitems(arg_or_null(args, 1))))
      "fn.threadOfRef" => @store_sessions.thread_of_ref(self.bus.db, arg_or_null(args, 0), arg_or_null(args, 1), arg_or_null(args, 2))
      "fn.hasUsage" => Json::boolean(@store_sessions.has_usage(self.bus.db, arg_or_null(args, 0)))
      "fn.importHandedUsage" => @store_sessions.import_handed_usage(self.bus.db, arg_or_null(args, 0), false)
      "fn.usageNow" => hub.usage_now(arg_text(args, 0)).unwrap_or(Json::null())
      // (move/live.ts `clonesElsewhere`: the repositories found on the machine, by their paths)
      "hub.repoClones" => {
        let (repos, _) = self.repo_index.repos(w())
        Json::array(repos.map(of_jv).filter_map(r => match jfield(r, "path") { String(_) as p => Some(p); _ => None }))
      }
      "agents.overview" =>
        self.bus.overview_call(arg_or_null(args, 0), arg_or_null(args, 1))
      // (replica/retire-asks.ts `chatCards`: a card in the session's latest chat, a still.fail one's alone, and whether it
      // still waits there)
      "cards.post" => {
        let session = arg_text(args, 0)
        let thread = match self.with_threads(t => t.latest_thread_if_ready(Json::string(session))) {
          Object(m) if m.contains("$undef") => {
            ignore(self.bus.reader_latest_threads(Json::array([Json::string(session)])))
            self.with_threads(t => t.latest_thread(Json::string(session)))
          }
          t => t
        }
        if thread is Null {
          raise @api_routes.Thrown("Refused", to_jv({ "message": "this session has no chat to ask in" }))
        }
        if jtext(jfield(thread, "thread"), "surface") != Some("chat") {
          raise @api_routes.Thrown(
            "Refused",
            to_jv({
              "message": "the confirmations are cards in the still.fail app, which a Slack or Feishu thread does not show: drive the retirement from a still.fail chat of this workspace (chat_create opens one), or a person retires the station from its page in the app",
            }),
          )
        }
        let posted = @session_chats.post_card(
          w(),
          session,
          to_jv(thread),
          arg_text(args, 1),
          to_jv(arg_or_null(args, 2)),
          Some(m => @session_chats.Thrown("Refused", m)),
          None,
        )
        match of_jv(posted) {
          String(ts) => { "thread": jfield(jfield(thread, "thread"), "id"), "ts": Json::string(ts) }
          _ => Json::null()
        }
      }
      "cards.state" => {
        let at = @session_chats.card_place(w(), arg_text(args, 0), to_jv(arg_or_null(args, 1)), to_jv(arg_or_null(args, 2))) catch {
          _ => return Json::string("none")
        }
        match at {
          Some(p) =>
            match jfield(of_jv(p), "state") {
              String(_) as s => s
              _ => Json::string("same")
            }
          None => Json::string("same")
        }
      }
      // (replica/module.ts `took`: the connects bound to the chats taken, where none is, and the notes to their agents)
      "retire.took" => {
        match arg_or_null(args, 0) {
          Object(m) =>
            for connect, session in m {
              if self.bus.store.binding(Json::string(connect)) is Null && !(self.bus.store.get_session(as_text(session).unwrap_or("")) is Null) {
                self.bus.store.set_binding(Json::string(connect), session)
              }
            }
          _ => ()
        }
        ignore(self.with_threads(t => t.set_moved_notes(arg_or_null(args, 1))))
        Json::null()
      }
      // ── agents.ts ──
      "agents.place" =>
        match (self.bus.cloud_state.val)() {
          Some(s) if jtext(s, "workspace") is Some(ws) && ws != "" && !self.place().removed =>
            {
              "origin": jfield(s, "origin"),
              "workspace": Json::string(ws),
              "station": jfield(s, "station"),
              "name": jfield(s, "name"),
            }
          _ => Json::null()
        }
      "agents.heldBy" => self.bus.coord_connects_held_by(args)
      "agents/runtime.runtimeKind" =>
        match @agent_drivers.runtime_kind(Some(to_jv(arg_or_null(args, 0)))) {
          Some(k) => Json::string(k)
          None => undef_json()
        }
      // ── the client core's records ──
      "core/cache-policy.afreshThreshold" =>
        match args.get(0) {
          Some(Number(n, ..)) if n >= 0.0 && n == n && n - n == 0.0 => Json::number(n)
          _ => Json::number(1.0)
        }
      "core/model-speed.modelSpeed" => jopt(@session_chats.model_speed(Some(to_jv(arg_or_null(args, 0)))))
      "core/preset-records.starsOf" => stars_of(arg_or_null(args, 0))
      "core/preset-records.mergeStars" => merge_stars(arg_or_null(args, 0), arg_or_null(args, 1))
      "core/preset-records.canonical" => Json::string(@session_chats.canonical(to_jv(arg_or_null(args, 0))))
      // ── the store's rows ──
      "rows.toEntry" => @store_threads.entry_of(arg_or_null(args, 0))
      "rows.cardOfEntry" =>
        match @store_threads.card_of_entry(arg_or_null(args, 0)) {
          Some(c) => c
          None => undef_json()
        }
      // ── the agents' environment ──
      "ops/agent-env.agentEnv" =>
        Json::object(Map::from_array(@ops_platform.agent_env(arg_or_null(args, 0)).map(kv => (kv.0, Json::string(kv.1)))))
      "ops/agent-env.parseEnvText" => {
        let kept = match arg_or_null(args, 1) {
          Object(m) => m.to_array().filter_map(kv => if kv.1 is String(v) { Some((kv.0, v)) } else { None })
          _ => []
        }
        @ops_platform.parse_env_text(arg_text(args, 0), kept)
      }
      "ops/agent-env.secretValue" => Json::boolean(@ops_platform.secret_value(arg_text(args, 0), arg_text(args, 1)))
      "ops/agent-env.maskValue" => Json::string(@ops_platform.mask_value(arg_text(args, 0)))
      // ── the wall's clock and timers ──
      "ops/fibers.wall.now" => Json::number(wall_ms().to_double())
      "ops/fibers.wall.after" => {
        let ms = match args.get(0) {
          Some(Number(n, ..)) => n
          _ => 0.0
        }
        let f = arg_or_null(args, 1)
        ignore(
          self.host.rt.fork_quiet(name="a route's later", async fn() {
            @effect.sleep(if ms < 1.0 { 1 } else { ms.to_int() }) // timer: a retry after a failure (a route's own)
            ignore(self.called(f, [])) catch {
              _ => ()
            }
          }),
        )
        Json::null()
      }
      "ops/fibers.wall.every" =>
        self.wall_every(
          match args.get(0) {
            Some(Number(n, ..)) => n
            _ => 1000.0
          },
          arg_or_null(args, 1),
        )
      // ── sessions/*.ts ──
      "sessions/config.runs" => Json::boolean(@session_hub.runs(arg_or_null(args, 0), arg_text(args, 1)))
      "sessions/config.runtimeTitle" => Json::string(@session_chats.runtime_title(arg_text(args, 0)))
      "sessions/context-cap.contextAsked" =>
        match @session_hub.context_asked(
          self.words,
          match args.get(0) {
            Some(x) if !is_undef_json(x) => Some(x)
            _ => None
          },
          arg_text(args, 1),
        ) {
          None => undef_json()
          Some(None) => Json::null()
          Some(Some(n)) => Json::number(n)
        }
      "sessions/footprint.roomOfSoon" => jopt(self.storage().room_of(arg_text(args, 1)))
      "sessions/image-size.shownFactsSoon" => shown_facts(self.host, arg_text(args, 0))
      "sessions/presets.presetCopyInput" =>
        of_jv(@session_chats.preset_copy_input(to_jv(arg_or_null(args, 0))))
      "sessions/presets.candidates" => {
        let here = arg_or_null(args, 3)
        Json::array(
          @session_chats.candidates(
            w(),
            arg_text(args, 0),
            jitems(arg_or_null(args, 1)).map(to_jv),
            jitems(arg_or_null(args, 2)).map(to_jv),
            async fn(station) { self.called(here, [Json::string(station)]) is True },
          ).map(of_jv),
        )
      }
      "sessions/regenerate-title.regenerateTitle" =>
        Json::string(
          @session_chats.regenerate_title(w(), to_jv(arg_or_null(args, 0)), jitems(arg_or_null(args, 1)).map(to_jv)),
        )
      "sessions/relay.relay" =>
        self.storage().relay(arg_or_null(args, 0), arg_or_null(args, 1), arg_or_null(args, 2), arg_text(args, 3))
      "sessions/relay.relayPeople" => self.storage().relay_people(arg_or_null(args, 0), arg_or_null(args, 1))
      "sessions/relay.relayPlaces" => Json::array(self.storage().relay_places(arg_or_null(args, 0)))
      "sessions/review.reviewUndecided" => {
        @session_chats.review_undecided_once(w())
        Json::null()
      }
      "sessions/archive-policy.savePolicy" =>
        jopt(
          self
          .storage()
          .save_policy(
            match args.get(0) {
              Some(x) if !is_undef_json(x) => Some(x)
              _ => None
            },
            arg_or_null(args, 1),
            arg_opt_text(args, 2),
          ),
        )
      "storage.policyView" => {
        // (overview.ts `madeDecisionsView`: whose chats are the viewer's (`mine`), their names, as this viewer sees them)
        // (the week's checks a reader counted, where the asker gave them: agents.ts `hub.policyChecks`; the viewer made
        // a JV once, not once per chat asked `policy.mine` of)
        let viewer = arg_or_null(args, 1)
        let viewer_jv = to_jv(viewer)
        let checks = match args.get(2) {
          Some(Object(_) as c) => Some(c)
          _ => None
        }
        let seen = @session_storage.Storage::new(
          @session_storage.Station::new(
            self.bus.store,
            self.threads,
            hub,
            path([self.data, "archive"]),
            () => told_threads(self.bus, self.threads),
            async fn(name, a) {
              match name {
                "policy.mine" => {
                  let session = opt_str(a.get(0)).unwrap_or("")
                  Json::boolean(@api_routes.sees(viewer_jv, to_jv(jopt(self.ws_of(session)))))
                }
                _ =>
                  match self.storage_world(name, a, viewer~) {
                    Some(v) if name.has_prefix("policy.") => v
                    _ => self.storage_call(name, a)
                  }
              }
            },
          ),
          self.files,
        )
        seen.policy_view(arg_opt_text(args, 0), viewer, checks)
      }
      "views.titleOf" =>
        Json::string(
          self.title_of(
            arg_or_null(args, 0),
            arg_opt_text(args, 1),
            arg_opt_text(args, 2),
          ),
        )
      "sessions/archive.withLock.enter" => {
        let room = arg_text(args, 0)
        let release = self.files.lock(room)
        match archive_locks.get(room) {
          Some(held) => held.push(release)
          None => archive_locks[room] = [release]
        }
        Json::null()
      }
      "sessions/archive.withLock.exit" => {
        let room = arg_text(args, 0)
        match archive_locks.get(room) {
          Some(held) if held.length() > 0 => {
            let release = held.pop().unwrap()
            if held.length() == 0 {
              archive_locks.remove(room)
            }
            release()
          }
          _ => ()
        }
        Json::null()
      }
      "sessions/archive.workspaceFile" =>
        match self.files.workspace_file(arg_text(args, 0), arg_text(args, 1), Ref(0)) {
          Some(b) => of_jv(@api_routes.jbytes(b))
          None => Json::null()
        }
      "sessions/cc.cc" => {
        @session_chats.cc(
          w(),
          to_jv(arg_or_null(args, 0)),
          arg_text(args, 1),
          arg_text(args, 2),
          arg_text(args, 3),
          to_jv(arg_or_null(args, 4)),
          jitems(arg_or_null(args, 5)).map(to_jv),
        )
        Json::null()
      }
      _ => {
        // ── a lifecycle's function or one of the hub's methods, by its TypeScript name ──
        let name = if op.has_prefix("sessions/lifecycle.") {
          op[19:].to_owned()
        } else if op.has_prefix("hub.") {
          op[4:].to_owned()
        } else {
          op
        }
        match (try { Ok(@session_hub.hub_call(hub, name, args)) } catch { e => Err(e) }) {
          Ok(v) => v
          Err(@session_hub.Refused(m)) if m.has_prefix("no hub call") =>
            // (the hub's methods the conversations' world answers: its readers, its chats' surfaces)
            of_jv(self.chats_answer("hub." + name, args.map(to_jv), args))
          Err(e) => raise e
        }
      }
    }
  } catch {
    e => raise routes_thrown(e)
  }
  r
}

///|
/// The archive's locks the routes hold (archive.ts `withLock`), by room: what lets each go, in the order taken.
let archive_locks : Map[String, Array[() -> Unit]] = Map([])

///|
/// adb/title.ts `grantChatTitle`: a grant named by the chat it was asked in where that chat is still the session's,
/// else by the session's latest; None where it has none.
fn P52::grant_chat_title(self : P52, r : Json) -> String? raise {
  let session = jtext(r, "session").unwrap_or("")
  let chat = jtext(r, "chat").unwrap_or("")
  let own = match chat.find("/") {
    Some(i) =>
      jfield(
        self.with_threads(t => t.session_thread(jstr(session), jstr(chat[:i].to_owned()), jstr(chat[i + 1:].to_owned()))),
        "thread",
      )
    None => Json::null()
  }
  if own is Object(_) {
    let without = self.title_of(own, None, None)
    // (a given name and a still.fail chat's name do not depend on the session's most recent chat)
    let surface = jtext(own, "surface")
    if @adb_devices.given_title(to_jv(own)) is Some(_) || surface == Some("chat") || surface == Some("ember") || surface == Some("stillfail") {
      return Some(without)
    }
    let first = as_text(self.bus.store.first_text(jfield(own, "id")))
    let with_text = self.title_of(own, first, None)
    if with_text == without {
      return Some(without)
    }
    let latest = jfield(jfield(self.with_threads(t => t.session_chat(jstr(session))), "thread"), "id")
    return Some(if latest == jfield(own, "id") { with_text } else { without })
  }
  match self.with_threads(t => t.session_chat(jstr(session))) {
    Object(_) as latest => Some(self.title_of(jfield(latest, "thread"), jtext(latest, "firstText"), None))
    _ => None
  }
}
