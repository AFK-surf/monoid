// MovesLive (move/live.ts): migrations between stations of a workspace (move_coord's `Moves`: its modules and their
// scheduler), a chat handed over by replica_coord's `Handover`, `handover.*` and `move.*` answered, the routes of a
// move, station_move given while moving is on here (features.ts `stationMoveOn`: the `beta` feature `stationMove`), its
// card chosen. What a move asks of the hub, the store, the jobs and the accounts goes on the bus (`hub_ask`, `jobs_ask`)
// by the names the TypeScript calls them; of the connects, this slice's own (`coord_connects`).

///|
/// Whether moving is offered and taken here (features.ts `stationMoveOn`).
fn P55::move_on(self : P55) -> Bool {
  station_feature("stationMove", (self.bus.config_raw.val)(), self.bus.app)
}

///|
/// One ask of the program's carry (`--builder replica-carry`, replica/carry.ts `inProgram`): a process of its own,
/// its answer, or its error; nothing of the walk on the station's own thread.
async fn P55::carry_ask(self : P55, ask : Json) -> @jsjson.JValue {
  let bus = self.bus
  let proc = spawn(
    bus.host,
    bus.argv0,
    ["--builder", "replica-carry", "--sep", sep(), "--shell-dir", path([bus.data, "shell"])],
    stdin_piped=true,
    stdout=Piped,
    stderr=Piped,
  )
  ignore(proc.write(@utf8.encode(ask.stringify() + "\n")))
  proc.end_input()
  let (code, _signal, out, err) = proc.finished()
  let lines = @utf8.decode_lossy(out).split("\n").map(l => l.to_owned()).filter(l => l.has_prefix("{")).to_array()
  match lines.last() {
    Some(line) =>
      match attempt(() => @jsjson.parse(line)) {
        Ok(said) =>
          match said.get("answer") {
            Some(a) => a
            None =>
              match said.get("error") {
                Some(Str(e)) => raise BusError(@jsjson.text(e))
                _ => raise BusError("the gathering's program said nothing it was asked")
              }
          }
        Err(_) => raise BusError("the gathering's program said what is not JSON")
      }
    None => raise BusError("the gathering's program ended saying nothing (\{code}): \{@utf8.decode_lossy(err).trim()}")
  }
}

///|
/// The carry's work as processes of the program (replica/carry.ts `gatherSoon`, `placeSoon`, `previewSoon`).
fn P55::carry_work(self : P55) -> @replica_coord.Work {
  let opt = (s : String?) => jopt(s)
  {
    gather: async fn(data, db, ws, home, scratch, agent, keys) {
      self.carry_ask({
        "op": "gather",
        "dataDir": Json::string(data),
        "db": Json::string(db),
        "ws": Json::string(ws),
        "home": Json::boolean(home),
        "scratch": Json::string(scratch),
        "agent": opt(agent),
        "keys": match keys { Some(k) => Json::array(k.map(Json::string(_))); None => Json::null() },
        "own": Json::array(@replica_coord.own_skills().map(Json::string(_))),
      })
    },
    place: async fn(data, index, from, made, aside, placed, projects) {
      self.carry_ask({
        "op": "place",
        "dataDir": Json::string(data),
        "index": Json::string(index),
        "from": Json::string(from),
        "made": opt(made),
        "aside": opt(aside),
        "placed": opt(placed),
        "projects": Json::boolean(projects),
      })
    },
    preview: async fn(data, db, ws, home) {
      self.carry_ask({ "op": "preview", "dataDir": Json::string(data), "db": Json::string(db), "ws": Json::string(ws), "home": Json::boolean(home) })
    },
    drop: None,
  }
}

///|
/// A move's body as the mesh carries it (move_coord's `Bytes_`: a file's range, or what comes a piece at a time).
async fn moved_bytes(host : @host.Host, b : @move_coord.Bytes_?) -> Bytes? {
  match b {
    None => None
    Some(FileBytes(p, from, len)) => {
      let (said, bytes) = host.shell("fs.bytes", { "path": Json::string(p), "from": Json::number(from.to_double()), "length": Json::number(len.to_double()) })
      match (said, bytes) {
        (_, Some(b)) => Some(b)
        (String(h), None) => Some(unhex_lenient(h))
        _ => Some(b"")
      }
    }
    Some(Came(next)) => {
      let out = @buffer.Buffer()
      while next() is Some(chunk) {
        out.write_bytes(chunk)
      }
      Some(out.to_bytes())
    }
  }
}

///|
/// The hand-over of one chat (replica_coord's `Handover`) as a move's `chats` module takes it (move_coord's
/// `HandoverPort`), made of what the move hands it (`HandoverHooks`).
async fn P55::handover_port(self : P55, hooks : @move_coord.HandoverHooks) -> @move_coord.HandoverPort {
  let bus = self.bus
  let data = bus.data
  let s = (a : Array[@jsjson.JValue], i : Int) => match a.get(i) { Some(Str(u)) => @jsjson.text(u); _ => "" }
  let strs = (v : @jsjson.JValue?) => match v {
    Some(Arr(xs)) => xs.filter_map(x => match x { Str(u) => Some(@jsjson.text(u)); _ => None })
    _ => []
  }
  // (what it asks of the station by name: the hub's and the store's on the bus, the move's own by its hooks)
  let answer = async fn(name : String, a : Array[@jsjson.JValue]) -> @jsjson.JValue {
    match name {
      "jobs.of" => @jsjson.JValue::Arr((hooks.jobs_of)(strs(a.get(0))))
      "jobs.stop" => {
        (hooks.jobs_stop)(strs(a.get(0)), s(a, 1))
        Null
      }
      "jobs.start" => {
        (hooks.jobs_start)(a.get(0).unwrap_or(Null))
        Null
      }
      "accounts.of" => (hooks.account_of)(s(a, 0)).unwrap_or(Null)
      "accounts.here" =>
        match (hooks.account_here)(a.get(0).unwrap_or(Null)) {
          Some(x) => to_jv(Json::string(x))
          None => Null
        }
      "accounts.present" => Bool((hooks.account_present)(s(a, 0)))
      "arrivedStopped" => {
        let w = of_jv(a.get(1).unwrap_or(Null))
        (hooks.arrived_stopped)(strs(a.get(0)), ({ module: jtext_or_empty(w, "module"), id: jtext_or_empty(w, "id"), label: jtext(w, "label"), at: jtext(w, "at") } : @move_coord.Waits), s(a, 2))
        Null
      }
      "shown" => {
        (hooks.shown)(strs(a.get(0)), match a.get(1) { Some(Str(u)) => Some(@jsjson.text(u)); _ => None })
        Null
      }
      "went" => {
        (hooks.went)(strs(a.get(0)))
        Null
      }
      "bindingsOf" => (hooks.bindings_of)(strs(a.get(0)))
      _ if name.has_prefix("connects.") => to_jv(self.coord_connects(name, a.map(of_jv)))
      // What the admin API kept of the messages written under a key (P5-1's, `$admin.keptSends`, `$admin.keepSends`)
      "keptSends" =>
        to_jv(self.bus.admin_kept_sends(of_jv(a.get(0).unwrap_or(Null))))
      "keepSends" => {
        self.bus.admin_keep_sends(of_jv(a.get(0).unwrap_or(Null)))
        Null
      }
      // (store.*, hub.*, fn.*: the hub's and its store's)
      _ => to_jv(self.hub(name, a.map(of_jv)))
    }
  }
  let w = self.replica_world(answer, (name, _a) => if name == "changed" { (hooks.changed)() })
  let told = hooks.told
  let previous : @replica_coord.Later[Unit] = @replica_coord.Later::new()
  bus.host.rt.fork(async fn() {
    (bus.previous_gone)()
    previous.resolve(())
  })
  |> ignore
  let h = @replica_coord.Handover::new(w, {
    data,
    here: () => Some(bus.key.id),
    home: () => self.home(),
    roster: ws => self.members(ws),
    connects: true,
    repos_dir: path([data, "repos"]),
    room: async fn() { room_of(data) },
    has_git: async fn() { has_git(bus.host) },
    flush: None,
    boot: () => wall_ms().to_double() - (match jfield(machine(), "uptime") { Number(u, ..) => u * 1000.0; _ => 0.0 }),
    git: Some(async fn(dir, args) { git_run(bus.host, dir, args) }),
    lack_most: @replica_coord.lack_most,
    hash_most: @replica_coord.hash_most,
    pack_files: None,
    pack_bytes: None,
    work: self.carry_work(),
    told: {
      asked: async fn(to, key, make, progress) { told.asked(to, key, () => (make(), None), progress?) },
      run: async fn(peer, key, work, measure) {
        told.run(peer, key, async fn(_p) { Some(work()) }, measure?)
      },
      let_go: (to, key, words) => told.let_go(to, key, @move_coord.error_of("Said", words)),
      settle: async fn() { told.settle() },
    },
    hold: Some(hooks.hold),
    fail: None,
    previous: Some(previous),
    previous_pid: bus.previous_pid.map(p => p.to_double()),
  })
  {
    together: async fn(k, page) { h.together(k, reads=self.reads_of(page)) },
    chat_of: async fn(k) { h.chat_of(k) },
    accounts_of: async fn(keys, page) {
      h.accounts_of(keys, reads=self.reads_of(page)).map(p => (p.0, match p.1 { Null => None; x => Some(x) }))
    },
    past_left: async fn(accounts, keys, page) {
      h.past_left(accounts.map(p => (p.0, p.1.unwrap_or(Null))), keys, reads=self.reads_of(page))
    },
    check: async fn(k, to, planning, page) { h.check(k, to, planning~, reads=self.reads_of(page)) },
    coming_in: async fn(ws) { h.coming_in(ws) },
    abandon: () => h.abandon(),
    hand_over: async fn(k, to, wait, progress, stopped_for) { h.hand_over(k, to, wait~, progress~, stopped_for=stopped_for.map(x => x.to_j())) },
    arrived: async fn(k, ms) { h.arrived(k, within_ms=Some(ms.to_double())) },
    out_of: async fn(k) { h.out_of(k) },
    coming_from: async fn(k) { h.coming_from(k) },
    waits_for_turn: async fn(o) {
      h.waits_for_turn(match o { Obj(_) => match of_jv(o) { x => jtext_or_empty(x, "id") }; Str(u) => @jsjson.text(u); _ => "" })
    },
    start: async fn() { h.start() },
    close: async fn() { h.close() },
    settle: async fn() { h.settle() },
    loaded_within: async fn() { h.loaded_within() },
    answer: async fn(peer, request, ws, bytes) {
      let body : @replica_coord.Body? = match bytes {
        None => None
        Some(FileBytes(p, from, len)) => Some(File(p, from.to_double(), len.to_double()))
        Some(Came(next)) => Some(Stream(next))
      }
      h.answer(hooks.admits, peer, request, body, ws)
    },
    reached: peer => h.reached(peer),
  }
}

///|
/// A page of sessions as the moves read it (move/live.ts gives store.ts's SessionPage as it is): its rows, and its
/// reads (each session's row, its home chat's sessions, the accounts it ran on: one statement for the page) kept by
/// the page's `handle` for the plan's checks of it (P55::reads_of), the latest 256 pages' alone.
fn P55::wrap_session_page(self : P55, sp : @store_sessions.SessionPage) -> @move_coord.Page {
  let reads : @replica_coord.SessionReads = {
    session: async fn(k) {
      match (try { Ok(sp.session(k)) } catch { e => Err(e) }) {
        Ok(Null) | Err(_) => None
        Ok(r) => Some(to_jv(r))
      }
    },
    home_members: async fn(k) { (try { Ok(sp.home_members(k)) } catch { _ => Ok(None) }).unwrap_or(None) },
    ran_on: async fn(k) { (try { Ok(sp.ran_on(k)) } catch { _ => Ok([]) }).unwrap_or([]) },
  }
  self.next_page += 1
  let id = self.next_page
  self.pages[id] = reads
  self.pages.remove(id - 256)
  let rows = (try { Ok(sp.rows()) } catch { _ => Ok([]) }).unwrap_or([]).map(to_jv)
  { keys: sp.keys, rows, session: reads.session, handle: @jsjson.JValue::Num(id.to_double()) }
}

///|
/// The reads of a page the moves made (`handle`), while it is kept: None, each session read alone.
fn P55::reads_of(self : P55, page : @move_coord.Page?) -> @replica_coord.SessionReads? {
  match page {
    Some({ handle: Num(n), .. }) => self.pages.get(n.to_int())
    _ => None
  }
}

///|
/// A page of sessions `keys` (store.ts `sessionPage`).
fn P55::sessions_page(self : P55, keys : Array[String]) -> @move_coord.Page {
  self.wrap_session_page(self.bus.store.session_page(keys, None))
}

///|
/// A page of a workspace's chats here, by key (store.ts `sessionPageOfWs`, as move/live.ts asks it): those after
/// `after`, at most `limit`, the home workspace's with those of no workspace, and those handed over from it.
fn P55::sessions_in(self : P55, ws : String, after : String, limit : Int) -> @move_coord.Page {
  let home = self.home()
  let ws_arg = if home == Some(ws) { Json::null() } else { Json::string(ws) }
  match (try { Ok(self.bus.store.session_page_of_ws(ws_arg, jopt(home), Json::string(after), limit)) } catch { e => Err(e) }) {
    Ok(sp) => self.wrap_session_page(sp)
    Err(_) => { keys: [], rows: [], session: async fn(_) { None }, handle: Null }
  }
}

///|
async fn P55::start_moves(self : P55) -> Unit {
  let bus = self.bus
  let data = bus.data
  let host = bus.host
  let replica_fs = @replica_coord.Fs::new(host, sep=sep())
  let say = @move_coord.Say::of((lang, key, args) => tr(lang, key, args~), (bus.lang.val)(), log=(level, part, fields) => slice_log(level, "move", part, of_jv(fields)))
  let roster = (ws : String) => self.roster(ws).map(r => r.map(m => ({ id: m.0, name: m.1, tasks: m.2 } : @move_coord.RosterEntry)))
  // (a burst of changes, a file's progress among them, told once: what the app's page reads again, GET /move)
  let telling = Ref(false)
  let changed = () => if !telling.val {
    telling.val = true
    host.rt.fork(async fn() {
      @effect.sleep(500) // timer: a debounce of a burst (each file's progress)
      telling.val = false
      (bus.events_tell.val)("move", { "changed": Json::boolean(true) }, "move", Json::object({}))
      (bus.overview_changed.val)()
    })
    |> ignore
  }
  let ask_peer = async fn(station : String, request : @jsjson.JValue, body : @move_coord.Bytes_?) -> @jsjson.JValue {
    let r = of_jv(request)
    let (value, _) = bus.call_peer(station, jtext(r, "workspace"), jtext_or_empty(r, "method"), r, bytes?=moved_bytes(host, body))
    to_jv(value)
  }
  let hub_bool = async fn(name : String, args : Array[Json]) -> Bool { self.hub(name, args) is True }
  let items_of = (v : Json) => core_items(v).map(to_jv)
  let opt_of = (v : Json) => match v {
    Null => None
    v => Some(to_jv(v))
  }
  let moves = @move_coord.Moves::new({
    data,
    here: () => Some(bus.key.id),
    home: () => self.home(),
    roster,
    ask: { ask: ask_peer },
    clock: { ..@move_coord.host_clock(host), now: () => p5_epoch_ms() },
    disk: @move_coord.host_disk(host),
    fs: @move_coord.host_fs(host),
    say,
    random: @move_coord.host_random(host),
    store: {
      subscribe: Some(f => ignore(bus.subscribe_store(change => match jtext(change, "key") { Some(k) => f(k); None => () }))),
      handed_to: async fn(k) { match self.hub("store.handedTo", [Json::string(k)]) { Null => None; v => Some(to_jv(v)) } },
      get_session: async fn(k) {
        match (try { Ok(bus.store.get_session(k)) } catch { e => Err(e) }) {
          Ok(Null) | Err(_) => None
          Ok(r) => Some(to_jv(r))
        }
      },
      jobs_mark_of: async fn(keys) {
        core_items(self.jobs("store.jobsMarkOf", [Json::array(keys.map(Json::string(_)))])).filter_map(p => match p {
          Array([String(a), String(b), ..]) => Some((a, b))
          _ => None
        })
      },
      live_sessions_on: async fn(c, n) { core_strs(self.hub("store.liveSessionsOn", [Json::string(c), Json::number(n.to_double())])) },
      live_of: async fn(keys) { core_strs(self.hub("store.liveOf", [Json::array(keys.map(Json::string(_)))])) },
      jobs_up_of: async fn(keys) { items_of(self.jobs("store.jobsUpOf", [Json::array(keys.map(Json::string(_)))])) },
      sessions_of_connect: async fn(c, n, after) {
        core_strs(self.hub("store.sessionsOfConnect", [Json::string(c), Json::number(n.to_double()), Json::string(after)]))
      },
      session_page: async fn(keys) { self.sessions_page(keys) },
      handed_chats: async fn(to, n) { items_of(self.hub("store.handedChats", [Json::string(to), Json::number(n.to_double())])) },
      list_bindings: async fn() {
        let rows = (try { Ok(bus.db.all("SELECT session_key, connect FROM bindings", [])) } catch { e => Err(e) }).unwrap_or([])
        let by : Map[String, Array[String]] = Map([])
        for r in rows {
          match (r.get("session_key"), r.get("connect")) {
            (Some(String(s)), Some(String(c))) =>
              match by.get(s) {
                Some(xs) => xs.push(c)
                None => by[s] = [c]
              }
            _ => ()
          }
        }
        by.to_array()
      },
    },
    hub: {
      hold_chat: async fn(k, why, notice) { ignore(self.hub("hub.holdChat", [Json::string(k), Json::string(why), Json::string(notice())])) },
      release_chat: async fn(k) { hub_bool("hub.releaseChat", [Json::string(k)]) },
      busy: Some(async fn(k) { hub_bool("hub.busy", [Json::string(k)]) }),
    },
    handover: hooks => {
      // (made at once: its records read as it starts)
      let port : Ref[@move_coord.HandoverPort?] = Ref(None)
      let made : @effect.Deferred[@move_coord.HandoverPort] = @effect.Deferred::new()
      host.rt.fork(async fn() {
        let p = self.handover_port(hooks)
        port.val = Some(p)
        ignore(made.succeed(p))
      })
      |> ignore
      handover_waiting(made)
    },
    connects: Some({
      kind_of: async fn(id) {
        match self.coord_connects("connects.kindOf", [Json::string(id)]) {
          Object(_) as k => Some((jtext_or_empty(k, "kind"), jtext_or_empty(k, "mode")))
          _ => None
        }
      },
      own_in: async fn(ws) {
        core_items(self.coord_connects("connects.ownKinds", [Json::string(ws)])).map(c => ({
          id: jtext_or_empty(c, "id"),
          name: jtext_or_empty(c, "name"),
          kind: jtext_or_empty(c, "kind"),
          mode: jtext_or_empty(c, "mode"),
        } : @move_coord.OwnConnect))
      },
      moved_away: Some(async fn(ws) {
        core_items(self.coord_connects("connects.movedAway", [Json::string(ws)])).map(c => ({
          id: jtext_or_empty(c, "id"),
          name: jtext_or_empty(c, "name"),
          kind: jtext_or_empty(c, "kind"),
          mode: jtext_or_empty(c, "mode"),
        } : @move_coord.OwnConnect))
      }),
      runs_on: async fn(id) { jtext({ "s": self.coord_connects("connects.runsOn", [Json::string(id)]) }, "s") },
      move: async fn(id, to, awaiting) {
        ignore(self.coord_connects("connects.move", [Json::string(id), Json::string(to), Json::array(awaiting.map(Json::string(_)))]))
      },
      arrived: Some(async fn(keys) { ignore(self.coord_connects("connects.arrived", [Json::array(keys.map(Json::string(_)))])) }),
    }),
    jobs: {
      up: async fn(keys, ws) {
        items_of(self.jobs("jobs.upAsMoves", [match keys { Some(k) => Json::array(k.map(Json::string(_))); None => Json::null() }, jopt(ws)]))
      },
      stop: async fn(id, why) { ignore(self.jobs("jobs.stop", [Json::string(id), Json::string(why)])) },
      start: async fn(j) { ignore(self.jobs("jobs.startMoved", [of_jv(j)])) },
      stop_named: async fn(session, name) { ignore(self.jobs("jobs.stopNamed", [Json::string(session), Json::string(name)])) },
    },
    profiles: async fn() { core_items(jfield((bus.config_raw.val)(), "profiles")).map(to_jv) },
    move_profile: async fn(id, to) { to_jv(self.jobs("sharing.moveProfile", [jopt(id), Json::string(to)])) },
    share_moves: Some({
      move: async fn(id, to, made) {
        let v = self.jobs("sharing.moveProfile", [Json::string(id), Json::string(to)])
        if jtext(v, "share") is Some(share) { made(share) }
        to_jv(v)
      },
      unshare: async fn(share, stations) { self.jobs("sharing.unshareMoved", [Json::string(share), Json::array(stations.map(Json::string(_)))]) is True },
      lend: Some(async fn(id, to) {
        let v = self.jobs("sharing.lendTo", [Json::string(id), Json::string(to)])
        (jtext_or_empty(v, "share"), jtrue(v, "made"), jtrue(v, "widened"))
      }),
      unlend: Some(async fn(share, to, made, widened) {
        ignore(self.jobs("sharing.unlend", [Json::string(share), Json::string(to), Json::boolean(made), Json::boolean(widened)]))
      }),
      uses_there: None,
      handed_on: None,
    }),
    sessions_in: async fn(ws, after, limit) { self.sessions_in(ws, after, limit) },
    repos_dir: path([data, "repos"]),
    remove: Some(async fn(p) { ignore(host.shell("fs.rm", { "path": Json::string(p), "recursive": Json::boolean(true) })) }),
    room: Some(async fn() {
      let (free, total) = room_of(data)
      to_jv({ "free": match free { Some(f) => Json::number(f); None => Json::null() }, "total": match total { Some(t) => Json::number(t); None => Json::null() } })
    }),
    git: Some(async fn(dir, args) { git_run(host, dir, args) }),
    changed: Some(changed),
    config: Some({
      raw: async fn() { to_jv((bus.config_raw.val)()) },
      update_soon: async fn(next) {
        let n = of_jv(next)
        ignore((bus.config_update.val)(_ => n))
      },
    }),
    // (move/live.ts `vault`: an owner's plain items and the vaults they own, the store's rows as they are, the vault's
    // part (P5-4) asked for them)
    vault: Some({
      owners: async fn(ws) { core_strs(self.ui("vault.moveOwners", [Json::string(ws)])) },
      grant_owners: async fn(keys) {
        let out : Map[String, Array[String]] = {}
        match self.ui("vault.moveGrantOwners", [Json::array(keys.map(Json::string(_)))]) {
          Object(m) => for k, v in m { out[k] = core_strs(v) }
          _ => ()
        }
        out
      },
      stores: {
        plain_items: async fn(ws, owner) { items_of(self.ui("secrets.plain.items", [Json::string(ws), Json::string(owner)])) },
        plain_item: async fn(ws, id) { opt_of(self.ui("secrets.plain.item", [Json::string(ws), Json::string(id)])) },
        plain_put: async fn(row) { ignore(self.ui("secrets.plain.put", [of_jv(row)])) },
        plain_forget: async fn(ws, id) { ignore(self.ui("secrets.plain.forget", [Json::string(ws), Json::string(id)])) },
        vaults: async fn(ws) { items_of(self.ui("vaults.vaults", [Json::string(ws)])) },
        vault: async fn(ws, id) { opt_of(self.ui("vaults.vault", [Json::string(ws), Json::string(id)])) },
        items: async fn(ws, vault) { items_of(self.ui("vaults.items", [Json::string(ws), Json::string(vault)])) },
        item: async fn(ws, vault, id) {
          opt_of(self.ui("vaults.item", [Json::string(ws), Json::string(vault), Json::string(id)]))
        },
        put_vault: async fn(row) { ignore(self.ui("vaults.putVault", [of_jv(row)])) },
        put_item: async fn(row) { ignore(self.ui("vaults.putItem", [of_jv(row)])) },
        forget_item: async fn(ws, vault, id) {
          ignore(self.ui("vaults.forgetItem", [Json::string(ws), Json::string(vault), Json::string(id)]))
        },
        forget_vault: async fn(ws, id) { ignore(self.ui("vaults.forgetVault", [Json::string(ws), Json::string(id)])) },
      },
    }),
    // (a beta feature of the station's: features.ts stationMoveOn)
    move_on: Some(() => self.move_on()),
    plan_page: None,
    clones_elsewhere: Some(async fn() { core_strs(self.hub("hub.repoClones", [])) }),
    hold: () => @updates.hold(),
    replica: {
      moved: (p, from, to) => @replica_coord.moved(replica_fs, p, from, to),
      carried_to: (p, from, to, room) => @replica_coord.carried_to(replica_fs, p, from, to, room),
      floor_of: total => @replica_coord.floor_of(total),
      room_here: async fn() {
        let (free, total) = room_of(data)
        to_jv({ "free": match free { Some(f) => Json::number(f); None => Json::null() }, "total": match total { Some(t) => Json::number(t); None => Json::null() } })
      },
      sizes: async fn(keys, sizing) {
        match self.carry_ask({ "op": "sizes", "dataDir": Json::string(data), "db": Json::string(path([data, "stillfail.db"])), "keys": Json::array(keys.map(Json::string(_))), "sizing": of_jv(sizing), "own": Json::array(@replica_coord.own_skills().map(Json::string(_))) }) {
          Arr(xs) => xs.map(@move_coord.Sized::of)
          _ => []
        }
      },
    },
  })
  self.closing(async fn() { moves.close() })
  let answers = moves.answers(peer => self.in_workspace(peer))
  let peer_answer = async fn(from : String, ws : String?, meth : String, params : Json, bytes : Bytes?) -> (Json, Bytes?) {
    let body : @move_coord.Bytes_? = match bytes {
      Some(b) => {
        let given = Ref(false)
        Some(Came(async fn() {
          if given.val {
            None
          } else {
            given.val = true
            Some(b)
          }
        }))
      }
      None => None
    }
    (of_jv(answers(from, to_jv(with_method(params, meth)), ws, body)), None)
  }
  // station_move's asks (tools/move.ts `MoveAsks`: mcp_tools'), all of a station confirmed on a card in the asking chat
  let asks = @mcp_tools.MoveAsks::new(self.move_tool_ctx(), data, { ask: true, set_wait: true, refusal: true, room: true, told: true })
  bus.on_peer_prefix("handover.", peer_answer)
  bus.on_peer_prefix("move.", async fn(from, ws, meth, params, bytes) {
    if meth == "move.tool" {
      guard self.in_workspace(from) && ws is Some(ws) else { raise BusError("not a station of this workspace") }
      return (move_asked(moves, asks, from, ws, params), None)
    }
    peer_answer(from, ws, meth, params, bytes)
  })
  // (a station heard from again: what is owed to it of a hand-over is told now, move/live.ts `bus.heard`)
  bus.on_peer_heard(peer => {
    (moves.handover.reached)(peer)
    moves.heard(peer)
  })
  // (a login home again, by any route: the share a trip made for it undone, move/live.ts `sharing.onHosted`)
  self.op("move.shareCameHome", async fn(arg) {
    let a = core_strs(arg)
    moves.share_came_home(a.get(0).unwrap_or(""), a.get(1).unwrap_or(""))
    Json::null()
  })
  // (the logins changed: what is stopped here for one looked at again)
  ignore((bus.config_listen.val)(_raw => moves.logins_changed()))
  bus.parts.routes(move_part_routes(@move_coord.move_routes({
    scheduler: moves.scheduler,
    order: () => moves.modules.map(m => m.id),
    home: () => self.home(),
    station: (ws, v) => match self.roster(ws) {
      Some(r) =>
        match r.search_by(x => x.0 == v || x.1.to_lower() == v.to_lower() || (v.length() >= 8 && x.0.has_prefix(v))) {
          Some(i) => Some((r[i].0, r[i].2))
          None => None
        }
      None => None
    },
    here: () => Some(bus.key.id),
    rig: () => jfield((bus.cloud_state.val)().unwrap_or(Json::null()), "rig") != Json::null(),
    name: Some((ws, id) => match self.roster(ws) {
      Some(r) =>
        match r.search_by(x => x.0 == id) {
          Some(i) if r[i].1 != "" => Some(r[i].1)
          _ => None
        }
      None => None
    }),
    refusal: async fn(ws, station, lang) { moves.refusal(ws, station, lang~) },
    begun: None,
    say,
  })))
  // (whether the app offers moving here: the switch; GET /move answers either way)
  bus.parts.overview("move", async fn(_viewer, _lang) { { "offered": Json::boolean(self.move_on()) } })
  // (the card's choice, in the app: an owner or admin of the chat's workspace confirms it or declines)
  bus.parts.card_choice("move", {
    may: (viewer, card, at) => asks.may(@jsjson.JV::of_json(viewer), @jsjson.JV::of_json(card), @jsjson.JV::of_json(at)),
    chosen: (viewer, card, option, at) => ignore(host.rt.fork_quiet(name="move card chosen", async fn() {
      asks.chosen(@jsjson.JV::of_json(viewer), @jsjson.JV::of_json(card), option, @jsjson.JV::of_json(at)) catch {
        e => self.warn("move", "the card's choice was not taken", e)
      }
    })),
  })
  // (station_move is an agent's only where moving is on here)
  bus.parts.tools(
    [
      {
        name: "station_move",
        declared: @jsjson.JV::to_json(asks.c.decl("station_move")),
        call: async fn(args, context) {
          tool_said(async fn() {
            let session = self.session_of(context)
            Json::string(@mcp_tools.pretty(move_tool_said(async fn() { asks.tool(session, @jsjson.JV::of_json(args)) })))
          })
        },
      },
    ],
    offered=() => self.move_on(),
  )
  self.move_ops(moves)
  bus.host.rt.fork(name="moves start", async fn() {
    ignore(bus.door_ready.wait())
    moves.start() catch {
      e => self.warn("move", "the migrations did not go on", e)
    }
  })
  |> ignore
}

///|
/// The hand-over port once it is made (its records read as it starts): each of its asks waits for it.
fn handover_waiting(made : @effect.Deferred[@move_coord.HandoverPort]) -> @move_coord.HandoverPort {
  let p = async fn() { made.wait() }
  {
    together: async fn(k, page) { (p().together)(k, page) },
    chat_of: async fn(k) { (p().chat_of)(k) },
    accounts_of: async fn(keys, page) { (p().accounts_of)(keys, page) },
    past_left: async fn(a, keys, page) { (p().past_left)(a, keys, page) },
    check: async fn(k, to, planning, page) { (p().check)(k, to, planning, page) },
    coming_in: async fn(ws) { (p().coming_in)(ws) },
    abandon: () => match (try { made.poll() } catch { _ => None }) {
      Some(port) => (port.abandon)()
      None => ()
    },
    hand_over: async fn(k, to, wait, progress, stopped_for) { (p().hand_over)(k, to, wait, progress, stopped_for) },
    arrived: async fn(k, ms) { (p().arrived)(k, ms) },
    out_of: async fn(k) { (p().out_of)(k) },
    coming_from: async fn(k) { (p().coming_from)(k) },
    waits_for_turn: async fn(o) { (p().waits_for_turn)(o) },
    start: async fn() { (p().start)() },
    close: async fn() { (p().close)() },
    settle: async fn() { (p().settle)() },
    loaded_within: async fn() { (p().loaded_within)() },
    answer: async fn(peer, request, ws, bytes) { (p().answer)(peer, request, ws, bytes) },
    reached: peer => match (try { made.poll() } catch { _ => None }) {
      Some(port) => (port.reached)(peer)
      None => ()
    },
  }
}

///|
/// A move's routes (routes.ts) as the admin API's: each matched by its own test of the path.
fn move_part_routes(routes : Array[@move_coord.MoveRoute]) -> Array[PartRoute] {
  let meths : Array[String] = []
  for r in routes {
    if !meths.contains(r.method_) {
      meths.push(r.method_)
    }
  }
  meths.map(m => p55_route(m, "^/move(/.*)?$", async fn(req) {
    let p = jtext_or_empty(req, "path")
    let viewer = jfield(req, "viewer")
    for r in routes {
      if r.method_ == m && (r.matches)(p) {
        let query = match jfield(req, "query") {
          Object(q) => q.to_array().filter_map(kv => match kv.1 { String(v) => Some((kv.0, v)); _ => None })
          _ => []
        }
        let (status, body) = (r.handle)({
          method_: m,
          path: p,
          query,
          body: match jfield(req, "body") { Null => ""; b => b.stringify() },
          email: jtext_or_empty(viewer, "email"),
          role: jtext_or_empty(viewer, "role"),
          workspace: jtext(viewer, "workspace"),
          lang: lang_in(req),
        })
        return answered(status, of_jv(body))
      }
    }
    refused(404, "not found")
  }))
}

///|
/// The move's own parts, for the agents' tools (mcp_tools' station_move asks them so) and the other slices.
fn P55::move_ops(self : P55, moves : @move_coord.Moves) -> Unit {
  let args_of = (arg : Json) => match arg {
    Array(xs) => xs
    _ => [arg]
  }
  let s = (a : Array[Json], i : Int) => match a.get(i) { Some(String(x)) => x; _ => "" }
  let sel = (v : Json) => ({
    module: jtext(v, "module"),
    item: jtext(v, "item"),
    all: jtrue(v, "all"),
    with_needs: jtrue(v, "withNeeds"),
    follow: match jfield(v, "follow") { Array(_) as f => Some(core_strs(f)); _ => None },
    arrive_stopped: jtrue(v, "arriveStopped"),
  } : @move_coord.Selection)
  self.op("move.here", async fn(_arg) { Json::string(self.bus.key.id) })
  self.op("move.wsOf", async fn(arg) {
    let session = s(args_of(arg), 0)
    match (try { Ok(self.bus.store.session_ws(session)) } catch { e => Err(e) }) {
      Ok(String(w)) => Json::string(w)
      Ok(Null) => jopt(self.home())
      _ => Json::null()
    }
  })
  self.op("move.roster", async fn(arg) {
    match self.roster(s(args_of(arg), 0)) {
      Some(r) => Json::array(r.map(m => ({ "id": Json::string(m.0), "name": Json::string(m.1), "tasks": Json::boolean(m.2) } : Json)))
      None => Json::null()
    }
  })
  self.op("move.refusal", async fn(arg) {
    let a = args_of(arg)
    jopt(moves.refusal(s(a, 0), s(a, 1)))
  })
  self.op("move.room", async fn(arg) {
    let a = args_of(arg)
    of_jv(moves.room(s(a, 0), s(a, 1), core_strs(a.get(2).unwrap_or(Json::null()))))
  })
  self.op("move.scheduler.plan", async fn(arg) {
    let a = args_of(arg)
    of_jv(moves.scheduler.plan(s(a, 0), s(a, 1)))
  })
  self.op("move.scheduler.planShown", async fn(arg) {
    let a = args_of(arg)
    of_jv(moves.scheduler.plan_shown(s(a, 0), s(a, 1)))
  })
  self.op("move.scheduler.move", async fn(arg) {
    let a = args_of(arg)
    of_jv(moves.scheduler.move(s(a, 0), s(a, 1), sel(a.get(2).unwrap_or(Json::null())), by?=match a.get(3) { Some(String(b)) => Some(b); _ => None }))
  })
  self.op("move.scheduler.back", async fn(arg) {
    let a = args_of(arg)
    of_jv(moves.scheduler.back(s(a, 0), s(a, 1), sel(a.get(2).unwrap_or(Json::null())), by?=match a.get(3) { Some(String(b)) => Some(b); _ => None }))
  })
  self.op("move.scheduler.stopTurn", async fn(arg) {
    Json::boolean(moves.scheduler.stop_turn(match args_of(arg).get(0) { Some(String(x)) => Some(x); _ => None }))
  })
  // (scheduler.ts `stopped()`: each item stopped here and what it waits for)
  self.op("move.scheduler.stopped", async fn(_arg) {
    Json::array(moves.scheduler.stopped_list().map(p => of_jv(@move_coord.jo([("item", p.0.to_j()), ("waitsFor", p.1.to_j())]))))
  })
  self.op("move.ask", async fn(arg) {
    let a = args_of(arg)
    of_jv(moves.ask(s(a, 0), to_jv(a.get(1).unwrap_or(Json::null())), None))
  })
  self.op("move.told.asked", async fn(arg) {
    let a = args_of(arg)
    let request = to_jv(a.get(2).unwrap_or(Json::null()))
    of_jv(moves.told.asked(s(a, 0), s(a, 1), () => (request, None)))
  })
  self.op("move.setWait", async fn(arg) {
    moves.set_wait(args_of(arg).get(0) is Some(True))
    Json::null()
  })
  self.op("move.on", async fn(_arg) { Json::boolean(self.move_on()) })
  // (move/live.ts `chatCards`, `hub.notify`: a card in the session's latest still.fail chat, a notice to its agent)
  self.op("move.cards.post", async fn(arg) {
    let a = args_of(arg)
    self.hub("cards.post", [Json::string(s(a, 0)), Json::string(s(a, 1)), a.get(2).unwrap_or(Json::null())])
  })
  self.op("move.notify", async fn(arg) {
    let a = args_of(arg)
    ignore(self.hub("hub.notify", [Json::string(s(a, 0)), Json::string(s(a, 1))]))
    Json::null()
  })
}

///|
/// What station_move's asks (mcp_tools' `MoveAsks`) ask of the station: the move's own parts (`move.*`, as `move_ops`
/// answers them on coord_ask), its file of asks (`fs.*`) and a temporary name's bytes (`crypto.randomBytes`).
fn P55::move_tool_ctx(self : P55) -> @mcp_tools.Ctx {
  let (zh, en) = catalogs_json()
  let words = @api_routes.Words::new(@jsjson.JV::of_json(zh), @jsjson.JV::of_json(en))
  let backend = @mcp_tools.ToolsBackend::new(async fn(op, args) {
    match op {
      "fs.readFileSync" | "fs.mkdir" | "fs.rename" =>
        @jsjson.JV::of_json(
          host_fs_op(self.bus.host, op[3:].to_owned(), args.map(@jsjson.JV::to_json)) catch {
            DispatchFsError(_, m) => raise BusError(m)
            e => raise e
          },
        )
      "fs.writeFile" =>
        @jsjson.JV::of_json(
          host_fs_op(self.bus.host, "writePrivate", args.map(@jsjson.JV::to_json)) catch {
            DispatchFsError(_, m) => raise BusError(m)
            e => raise e
          },
        )
      "crypto.randomBytes" =>
        @api_routes.jbytes(@drive.random_bytes(match args.get(0) { Some(Num(n)) => n.to_int(); _ => 0 }))
      _ =>
        match self.ops.get(op) {
          Some(f) => @jsjson.JV::of_json(f(Json::array(args.map(@jsjson.JV::to_json))))
          None => raise BusError("no move part \{op}")
        }
    }
  })
  @mcp_tools.Ctx::new(backend, words, { runtime_kinds: [], station_lang: (self.bus.lang.val)(), os: p54_os(), arch: arch() })
}

///|
/// station_move asked by another station (tools/move.ts `MoveAsks.answer`): a move or a move back as a told step where
/// it asks so (`told`, its key), the step's end told to it; else answered with its outcome as before.
async fn move_asked(moves : @move_coord.Moves, asks : @mcp_tools.MoveAsks, peer : String, ws : String, request : Json) -> Json {
  let args = match jfield(request, "args") {
    Object(_) as a => @jsjson.JV::of_json(a)
    _ => @api_routes.JV::Obj([])
  }
  match jfield(request, "told") {
    String(key) if key.length() <= 300 =>
      of_jv(moves.told.run(peer, key, async fn(_progress) {
        Some(to_jv(@jsjson.JV::to_json(move_tool_said(async fn() { asks.tool_in(ws, None, args) }))))
      }))
    _ => @jsjson.JV::to_json(move_tool_said(async fn() { asks.tool_in(ws, None, args) }))
  }
}

///|
/// What station_move answers, its refusals in their words (a bus error, as the station's other parts say theirs).
async fn move_tool_said(f : async () -> @api_routes.JV) -> @api_routes.JV {
  f() catch {
    @mcp_tools.Refusal(m) | @mcp_tools.Failed(m) => raise BusError(m)
    e => raise e
  }
}
