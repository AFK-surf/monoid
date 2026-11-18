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
  let opt = (s : String?) => p55_jopt(s)
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
        (String(h), None) => Some(hex_bytes(h))
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
          Some(x) => of_core(Json::string(x))
          None => Null
        }
      "accounts.present" => Bool((hooks.account_present)(s(a, 0)))
      "arrivedStopped" => {
        let w = to_core(a.get(1).unwrap_or(Null))
        (hooks.arrived_stopped)(strs(a.get(0)), ({ module: p55_jtext(w, "module"), id: p55_jtext(w, "id"), label: p55_jstr(w, "label"), at: p55_jstr(w, "at") } : @move_coord.Waits), s(a, 2))
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
      _ if name.has_prefix("connects.") => of_core(self.coord_connects(name, a.map(to_core)))
      // (store.*, hub.*, fn.*, keptSends, keepSends: the hub's and its store's)
      _ => of_core(self.hub(name, a.map(to_core)))
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
    boot: () => wall_ms().to_double() - (match p55_jfield(machine(), "uptime") { Number(u, ..) => u * 1000.0; _ => 0.0 }),
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
    together: async fn(k, _page) { h.together(k) },
    chat_of: async fn(k) { h.chat_of(k) },
    accounts_of: async fn(keys, _page) { h.accounts_of(keys).map(p => (p.0, match p.1 { Null => None; x => Some(x) })) },
    past_left: async fn(accounts, keys, _page) { h.past_left(accounts.map(p => (p.0, p.1.unwrap_or(Null))), keys) },
    check: async fn(k, to, planning, _page) { h.check(k, to, planning~) },
    coming_in: async fn(ws) { h.coming_in(ws) },
    abandon: () => h.abandon(),
    hand_over: async fn(k, to, wait, progress, stopped_for) { h.hand_over(k, to, wait~, progress~, stopped_for=stopped_for.map(x => x.to_j())) },
    arrived: async fn(k, ms) { h.arrived(k, within_ms=Some(ms.to_double())) },
    out_of: async fn(k) { h.out_of(k) },
    coming_from: async fn(k) { h.coming_from(k) },
    waits_for_turn: async fn(o) {
      h.waits_for_turn(match o { Obj(_) => match to_core(o) { x => p55_jtext(x, "id") }; Str(u) => @jsjson.text(u); _ => "" })
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
/// A page of a workspace's chats here, by key (store.ts `sessionPageOfWs`): those after `after`, at most `limit`.
fn P55::sessions_page(self : P55, keys : Array[String]) -> @move_coord.Page {
  let rows = (try { Ok(self.bus.store.sessions_of(keys)) } catch { e => Err(e) }).unwrap_or([])
  let store = self.bus.store
  {
    keys,
    rows: rows.map(of_core),
    session: async fn(k) {
      match (try { Ok(store.get_session(k)) } catch { e => Err(e) }) {
        Ok(Null) | Err(_) => None
        Ok(r) => Some(of_core(r))
      }
    },
    handle: Null,
  }
}

///|
fn P55::sessions_in(self : P55, ws : String, after : String, limit : Int) -> @move_coord.Page {
  let home = self.home() == Some(ws)
  let rows = (try {
    Ok(
      self.bus.db.all(
        if home {
          "SELECT key FROM sessions WHERE (ws = ? OR ws IS NULL) AND key > ? ORDER BY key LIMIT ?"
        } else {
          "SELECT key FROM sessions WHERE ws = ? AND key > ? ORDER BY key LIMIT ?"
        },
        [Json::string(ws), Json::string(after), Json::number(limit.to_double())],
      ),
    )
  } catch {
    e => Err(e)
  }).unwrap_or([])
  self.sessions_page(rows.filter_map(r => match r.get("key") { Some(String(k)) => Some(k); _ => None }))
}

///|
fn jv_text(v : @jsjson.JValue?) -> String? {
  match v {
    Some(Str(u)) => Some(@jsjson.text(u))
    _ => None
  }
}

///|
async fn P55::start_moves(self : P55) -> Unit {
  let bus = self.bus
  let data = bus.data
  let host = bus.host
  let replica_fs = @replica_coord.Fs::new(host, sep=sep())
  let say = @move_coord.Say::of((lang, key, args) => tr(lang, key, args~), (bus.lang.val)(), log=(level, part, fields) => slice_log(level, "move", part, to_core(fields)))
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
    let r = to_core(request)
    let (value, _) = bus.call_peer(station, p55_jstr(r, "workspace"), p55_jtext(r, "method"), r, bytes?=moved_bytes(host, body))
    of_core(value)
  }
  let hub_bool = async fn(name : String, args : Array[Json]) -> Bool { self.hub(name, args) is True }
  let items_of = (v : Json) => core_items(v).map(of_core)
  let moves = @move_coord.Moves::new({
    data,
    here: () => Some(bus.key.id),
    home: () => self.home(),
    roster,
    ask: { ask: ask_peer },
    clock: @move_coord.host_clock(host),
    disk: @move_coord.host_disk(host),
    fs: @move_coord.host_fs(host),
    say,
    random: @move_coord.host_random(host),
    store: {
      subscribe: Some(f => ignore(bus.subscribe_store(change => match p55_jstr(change, "key") { Some(k) => f(k); None => () }))),
      handed_to: async fn(k) { match self.hub("store.handedTo", [Json::string(k)]) { Null => None; v => Some(of_core(v)) } },
      get_session: async fn(k) {
        match (try { Ok(bus.store.get_session(k)) } catch { e => Err(e) }) {
          Ok(Null) | Err(_) => None
          Ok(r) => Some(of_core(r))
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
          Object(_) as k => Some((p55_jtext(k, "kind"), p55_jtext(k, "mode")))
          _ => None
        }
      },
      own_in: async fn(ws) {
        core_items(self.coord_connects("connects.ownKinds", [Json::string(ws)])).map(c => ({
          id: p55_jtext(c, "id"),
          name: p55_jtext(c, "name"),
          kind: p55_jtext(c, "kind"),
          mode: p55_jtext(c, "mode"),
        } : @move_coord.OwnConnect))
      },
      moved_away: Some(async fn(ws) {
        core_items(self.coord_connects("connects.movedAway", [Json::string(ws)])).map(c => ({
          id: p55_jtext(c, "id"),
          name: p55_jtext(c, "name"),
          kind: p55_jtext(c, "kind"),
          mode: p55_jtext(c, "mode"),
        } : @move_coord.OwnConnect))
      }),
      runs_on: async fn(id) { p55_jstr({ "s": self.coord_connects("connects.runsOn", [Json::string(id)]) }, "s") },
      move: async fn(id, to, awaiting) {
        ignore(self.coord_connects("connects.move", [Json::string(id), Json::string(to), Json::array(awaiting.map(Json::string(_)))]))
      },
      arrived: Some(async fn(keys) { ignore(self.coord_connects("connects.arrived", [Json::array(keys.map(Json::string(_)))])) }),
    }),
    jobs: {
      up: async fn(keys, ws) {
        items_of(self.jobs("jobs.upAsMoves", [match keys { Some(k) => Json::array(k.map(Json::string(_))); None => Json::null() }, p55_jopt(ws)]))
      },
      stop: async fn(id, why) { ignore(self.jobs("jobs.stop", [Json::string(id), Json::string(why)])) },
      start: async fn(j) { ignore(self.jobs("jobs.startMoved", [to_core(j)])) },
      stop_named: async fn(session, name) { ignore(self.jobs("jobs.stopNamed", [Json::string(session), Json::string(name)])) },
    },
    profiles: async fn() { core_items(p55_jfield((bus.config_raw.val)(), "profiles")).map(of_core) },
    move_profile: async fn(id, to) { of_core(self.jobs("sharing.moveProfile", [p55_jopt(id), Json::string(to)])) },
    share_moves: Some({
      move: async fn(id, to, made) {
        let v = self.jobs("sharing.moveProfile", [Json::string(id), Json::string(to)])
        match p55_jstr(v, "share") {
          Some(share) => made(share)
          None => ()
        }
        of_core(v)
      },
      unshare: async fn(share, stations) { self.jobs("sharing.unshareMoved", [Json::string(share), Json::array(stations.map(Json::string(_)))]) is True },
      lend: Some(async fn(id, to) {
        let v = self.jobs("sharing.lendTo", [Json::string(id), Json::string(to)])
        (p55_jtext(v, "share"), jtrue(v, "made"), jtrue(v, "widened"))
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
      of_core({ "free": match free { Some(f) => Json::number(f); None => Json::null() }, "total": match total { Some(t) => Json::number(t); None => Json::null() } })
    }),
    git: Some(async fn(dir, args) { git_run(host, dir, args) }),
    changed: Some(changed),
    config: Some({
      raw: async fn() { of_core((bus.config_raw.val)()) },
      update_soon: async fn(next) {
        let n = to_core(next)
        ignore((bus.config_update.val)(_ => n))
      },
    }),
    vault: None,
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
        of_core({ "free": match free { Some(f) => Json::number(f); None => Json::null() }, "total": match total { Some(t) => Json::number(t); None => Json::null() } })
      },
      sizes: async fn(keys, sizing) {
        match self.carry_ask({ "op": "sizes", "dataDir": Json::string(data), "db": Json::string(path([data, "stillfail.db"])), "keys": Json::array(keys.map(Json::string(_))), "sizing": to_core(sizing), "own": Json::array(@replica_coord.own_skills().map(Json::string(_))) }) {
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
    (to_core(answers(from, of_core(with_method(params, meth)), ws, body)), None)
  }
  bus.on_peer_prefix("handover.", peer_answer)
  bus.on_peer_prefix("move.", async fn(from, ws, meth, params, bytes) {
    if meth == "move.tool" {
      if !self.in_workspace(from) || ws is None {
        raise BusError("not a station of this workspace")
      }
      return (self.move_tool_in(moves, ws.unwrap(), None, p55_jfield(params, "args")), None)
    }
    peer_answer(from, ws, meth, params, bytes)
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
    rig: () => p55_jfield((bus.cloud_state.val)().unwrap_or(Json::null()), "rig") != Json::null(),
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
  // (station_move is an agent's only where moving is on here)
  bus.parts.tools(
    [
      {
        name: "station_move",
        declared: tool_declared(move_declared),
        call: async fn(args, context) {
          tool_said(async fn() {
            let session = self.session_of(context)
            let ws = match (try { Ok(bus.store.session_ws(session)) } catch { e => Err(e) }) {
              Ok(String(w)) => w
              Ok(Null) => self.home().unwrap_or("")
              _ => raise BusError("this chat is of no workspace here")
            }
            self.move_tool_in(moves, ws, Some(session), args)
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
    let p = p55_jtext(req, "path")
    let viewer = p55_jfield(req, "viewer")
    for r in routes {
      if r.method_ == m && (r.matches)(p) {
        let query = match p55_jfield(req, "query") {
          Object(q) => q.to_array().filter_map(kv => match kv.1 { String(v) => Some((kv.0, v)); _ => None })
          _ => []
        }
        let (status, body) = (r.handle)({
          method_: m,
          path: p,
          query,
          body: match p55_jfield(req, "body") { Null => ""; b => b.stringify() },
          email: p55_jtext(viewer, "email"),
          role: p55_jtext(viewer, "role"),
          workspace: p55_jstr(viewer, "workspace"),
          lang: lang_in(req),
        })
        return answered(status, to_core(body))
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
    module: p55_jstr(v, "module"),
    item: p55_jstr(v, "item"),
    all: jtrue(v, "all"),
    with_needs: jtrue(v, "withNeeds"),
    follow: match p55_jfield(v, "follow") { Array(_) as f => Some(core_strs(f)); _ => None },
    arrive_stopped: jtrue(v, "arriveStopped"),
  } : @move_coord.Selection)
  self.op("move.here", async fn(_arg) { Json::string(self.bus.key.id) })
  self.op("move.wsOf", async fn(arg) {
    let session = s(args_of(arg), 0)
    match (try { Ok(self.bus.store.session_ws(session)) } catch { e => Err(e) }) {
      Ok(String(w)) => Json::string(w)
      Ok(Null) => p55_jopt(self.home())
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
    p55_jopt(moves.refusal(s(a, 0), s(a, 1)))
  })
  self.op("move.room", async fn(arg) {
    let a = args_of(arg)
    to_core(moves.room(s(a, 0), s(a, 1), core_strs(a.get(2).unwrap_or(Json::null()))))
  })
  self.op("move.scheduler.plan", async fn(arg) {
    let a = args_of(arg)
    to_core(moves.scheduler.plan(s(a, 0), s(a, 1)))
  })
  self.op("move.scheduler.planShown", async fn(arg) {
    let a = args_of(arg)
    to_core(moves.scheduler.plan_shown(s(a, 0), s(a, 1)))
  })
  self.op("move.scheduler.move", async fn(arg) {
    let a = args_of(arg)
    to_core(moves.scheduler.move(s(a, 0), s(a, 1), sel(a.get(2).unwrap_or(Json::null())), by?=match a.get(3) { Some(String(b)) => Some(b); _ => None }))
  })
  self.op("move.scheduler.back", async fn(arg) {
    let a = args_of(arg)
    to_core(moves.scheduler.back(s(a, 0), s(a, 1), sel(a.get(2).unwrap_or(Json::null())), by?=match a.get(3) { Some(String(b)) => Some(b); _ => None }))
  })
  self.op("move.scheduler.stopTurn", async fn(arg) {
    Json::boolean(moves.scheduler.stop_turn(match args_of(arg).get(0) { Some(String(x)) => Some(x); _ => None }))
  })
  self.op("move.scheduler.stopped", async fn(_arg) {
    Json::array(moves.scheduler.stopped_list().map(p => to_core(@move_coord.jo([("need", p.0.to_j()), ("waits", p.1.to_j())]))))
  })
  self.op("move.ask", async fn(arg) {
    let a = args_of(arg)
    to_core(moves.ask(s(a, 0), of_core(a.get(1).unwrap_or(Json::null())), None))
  })
  self.op("move.told.asked", async fn(arg) {
    let a = args_of(arg)
    let request = of_core(a.get(2).unwrap_or(Json::null()))
    to_core(moves.told.asked(s(a, 0), s(a, 1), () => (request, None)))
  })
  self.op("move.setWait", async fn(arg) {
    moves.set_wait(args_of(arg).get(0) is Some(True))
    Json::null()
  })
  self.op("move.on", async fn(_arg) { Json::boolean(self.move_on()) })
}

///|
/// station_move's work for workspace `ws` (tools/move.ts `MoveAsks.toolIn`; `session`: the chat asking here, None: asked
/// by another station): a plan or where each stands (a summary, a module's page, or one item), one item moved or moved
/// back, the turn under way stopped. All of a station is confirmed on a card in the app (mcp_tools' station_move, which
/// asks `move.*` of this slice, posts it).
async fn P55::move_tool_in(self : P55, moves : @move_coord.Moves, ws : String, session : String?, args : Json) -> Json {
  fn station(v : Json) -> (String, String) raise {
    let want = match v {
      String(t) => t.trim().to_owned()
      _ => ""
    }
    match self.roster(ws) {
      Some(r) =>
        match r.search_by(x => x.0 == want || x.1.to_lower() == want.to_lower() || (want.length() >= 8 && x.0.has_prefix(want))) {
          Some(i) => (r[i].0, r[i].1)
          None => raise BusError("no station \{want} in this chat's workspace: station_list lists them")
        }
      None => raise BusError("this station is in no workspace")
    }
  }
  moves.set_wait(!(p55_jfield(args, "wait") is False))
  let module = p55_jstr(args, "module")
  let item = p55_jstr(args, "item")
  let follow = if module == Some("chats") { Some(["jobs"]) } else { None }
  let sel : @move_coord.Selection = {
    module,
    item,
    all: jtrue(args, "all"),
    with_needs: jtrue(args, "withNeeds"),
    follow,
    arrive_stopped: jtrue(args, "arriveStopped"),
  }
  match p55_jstr(args, "action") {
    Some("plan") | Some("status") => {
      let status = p55_jstr(args, "action") == Some("status")
      let to = if status && p55_jfield(args, "to") == Json::null() { "" } else { station(p55_jfield(args, "to")).0 }
      let plan = to_core(moves.scheduler.plan_shown(ws, to))
      let items = core_items(p55_jfield(plan, "items"))
      match item {
        Some(i) =>
          match items.search_by(x => p55_jstr(x, "id") == Some(i) && (module is None || p55_jstr(x, "module") == module)) {
            Some(n) => { "item": items[n] }
            None => raise BusError("no item \{i} in the plan: plan with module lists them")
          }
        None => {
          let shown = match module {
            Some(m) => items.filter(x => p55_jstr(x, "module") == Some(m))
            None => []
          }
          let counts : Map[String, Json] = Map([])
          for x in items {
            let m = p55_jtext(x, "module")
            let n = match counts.get(m) { Some(Number(c, ..)) => c; _ => 0.0 }
            counts[m] = Json::number(n + 1.0)
          }
          {
            "summary": { "items": Json::number(items.length().to_double()), "modules": Json::object(counts) },
            "items": Json::array(shown[:if shown.length() > 50 { 50 } else { shown.length() }].to_array()),
          }
        }
      }
    }
    Some("move") => {
      let (to, _name) = station(p55_jfield(args, "to"))
      match moves.refusal(ws, to) {
        Some(why) if why != "" => raise BusError(why)
        _ => ()
      }
      if jtrue(args, "all") {
        raise BusError("moving all of a station is confirmed on a card in a chat on it, by an owner or admin in the app")
      }
      if module is None || item is None {
        raise BusError("move: name the module and the item (station_move plan lists them), or all")
      }
      { "outcome": to_core(moves.scheduler.move(ws, to, sel, by?=session)) }
    }
    Some("back") => {
      let (from, _name) = station(p55_jfield(args, "to"))
      if module is None || (item is None && !jtrue(args, "all")) {
        raise BusError("back: name the module and the item (station_move status lists them), and to: the station it is on")
      }
      match moves.refusal(ws, from) {
        Some(why) if why != "" => raise BusError(why)
        _ => ()
      }
      { "outcome": to_core(moves.scheduler.back(ws, from, sel, by?=session)) }
    }
    Some("stop") => {
      if !moves.scheduler.stop_turn(session) {
        raise BusError(tr((self.bus.lang.val)(), "station.move.notRunning"))
      }
      { "stopping": Json::boolean(true) }
    }
    _ => raise BusError("action is one of plan, move, back, status, stop")
  }
}

///|
/// station_move (tools/move.ts), as it is declared to the agents.
let move_declared : String =
  #|{
  #|  "name": "station_move",
  #|  "description": "Move this station's chats, accounts, jobs and connects to another station of its workspace, one item or all, and back. Read skill stillfail-move first: it says each option. plan {to}: a summary; module (after, limit) pages, item one. move {to, module, item}: one item (a chat: its session key); withNeeds: its needs first; all: everything, once a card is confirmed in the app. back {module, item, to}: back here. status: where each stands. stop: the move under way stops.",
  #|  "inputSchema": {
  #|    "type": "object",
  #|    "properties": {
  #|      "action": {
  #|        "enum": [
  #|          "plan",
  #|          "move",
  #|          "back",
  #|          "status",
  #|          "stop"
  #|        ]
  #|      },
  #|      "to": {
  #|        "type": "string",
  #|        "description": "The other station: name or id (station_list)."
  #|      },
  #|      "module": {
  #|        "type": "string"
  #|      },
  #|      "item": {
  #|        "type": "string"
  #|      },
  #|      "withNeeds": {
  #|        "type": "boolean"
  #|      },
  #|      "arriveStopped": {
  #|        "type": "boolean"
  #|      },
  #|      "all": {
  #|        "type": "boolean"
  #|      },
  #|      "station": {
  #|        "type": "string"
  #|      },
  #|      "wait": {
  #|        "type": "boolean"
  #|      },
  #|      "after": {
  #|        "type": "string"
  #|      },
  #|      "limit": {
  #|        "type": "number"
  #|      }
  #|    },
  #|    "required": [
  #|      "action"
  #|    ],
  #|    "additionalProperties": false
  #|  }
  #|}

///|
fn hex_bytes(h : String) -> Bytes {
  let out = @buffer.Buffer()
  let v = (c : Int) => if c >= 48 && c <= 57 { c - 48 } else if c >= 97 && c <= 102 { c - 87 } else if c >= 65 && c <= 70 { c - 55 } else { 0 }
  let mut i = 0
  while i + 1 < h.length() {
    out.write_byte((v(h.unsafe_charcode_at(i)) * 16 + v(h.unsafe_charcode_at(i + 1))).to_byte())
    i += 2
  }
  out.to_bytes()
}
