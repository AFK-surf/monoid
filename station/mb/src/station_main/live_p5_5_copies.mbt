// CopiesLive (replica/module.ts): the copies of this station's chats (the export in this program, replica_coord's
// `program_runner`), what the store says changed told to it, the other stations' requests of the copies this one keeps
// (`replica.*`) and of a retirement (`retire.*`), a lost station's links taken to the one that took its place, the
// copies' part of the overview and their routes; a station's retirement and station_retire, its cards' choices.
//
// What the copies ask of the station's other parts goes on the bus: the hub's (`hub_ask`: a workspace's chats quiet and
// back, a chat's agent told, a card posted and where it stands) and the jobs' and accounts' (`jobs_ask`), by the names
// the TypeScript calls them (`retire.quiet`, `hub.notify`, `jobs.start`, `sharing.moveProfile`, …).

///|
/// What the slice asks of the hub's part (P5-2), by name, its arguments in order.
async fn P55::hub(self : P55, name : String, args : Array[Json]) -> Json {
  (self.bus.hub_ask.val)(name, Json::array(args))
}

///|
/// What the slice asks of the jobs' and accounts' part (P5-3), by name, its arguments in order.
async fn P55::jobs(self : P55, name : String, args : Array[Json]) -> Json {
  (self.bus.jobs_ask.val)(name, Json::array(args))
}

///|
/// What the slice asks of the vault's and the devices' part (P5-4), by name, its arguments in order.
async fn P55::ui(self : P55, name : String, args : Array[Json]) -> Json {
  (self.bus.ui_ask.val)(name, Json::array(args))
}

///|
fn core_strs(v : Json) -> Array[String] {
  match v {
    Array(xs) => xs.filter_map(x => match x { String(s) => Some(s); _ => None })
    _ => []
  }
}

///|
/// A body's bytes as the mesh carries them (replica_coord's `Body`: whole, a file's range, or a stream).
async fn p55_body_bytes(fs : @replica_coord.Fs, b : @replica_coord.Body?) -> Bytes? {
  match b {
    None => None
    Some(Whole(x)) => Some(x)
    Some(other) => Some(other.whole(fs))
  }
}

///|
/// The station's restart where the launcher holds it (ops/restart.ts `restarter`): run/station.json's pid, one that
/// says `handoff: 1` and is there, asked to hand over (SIGUSR2); none where there is no launcher to ask.
fn restarter(data : String) -> (async () -> Unit)? {
  match read_json(path([data, "run", "station.json"])) {
    Some({ "pid": Number(p, ..), "handoff": Number(1.0, ..), .. }) if p > 0.0 && pid_alive(p.to_int()) && !is_windows() =>
      Some(async fn() { ignore(kill(p.to_int(), "SIGUSR2")) })
    _ => None
  }
}

///|
/// git, run in `dir` to its end: what it said on stdout, or why it failed.
async fn git_run(host : @host.Host, dir : String, args : Array[String]) -> String {
  let proc = spawn(host, "git", args, cwd=dir, stdout=Piped, stderr=Piped)
  let (code, _signal, out, err) = proc.finished()
  if code != Some(0) {
    raise BusError("git \{args.get(0).unwrap_or("")} failed: \{@utf8.decode_lossy(err).trim()}")
  }
  @utf8.decode_lossy(out)
}

///|
async fn has_git(host : @host.Host) -> Bool {
  (try { Ok(git_run(host, tmpdir(), ["--version"])) } catch { e => Err(e) }) is Ok(_)
}

///|
/// The free and whole bytes of the disk the data directory is on.
fn room_of(data : String) -> (Double?, Double?) {
  match disk_of(data) {
    Some((free, total)) => (Some(free), Some(total))
    None => (None, None)
  }
}

///|
/// The replica_coord world on this machine: its files the shell's, the other stations asked over the bus's mesh, its
/// clock and runtime the program's; what it asks of the station's parts by name (`call`) answered by `answer`.
fn P55::replica_world(self : P55, answer : async (String, Array[@jsjson.JValue]) -> @jsjson.JValue, told : (String, Array[@jsjson.JValue]) -> Unit) -> @replica_coord.World {
  let bus = self.bus
  let fs = @replica_coord.Fs::new(bus.host, sep=sep())
  let (zh, en) = catalogs_json()
  {
    host: bus.host,
    fs,
    call: answer,
    ask_peer: async fn(station, request, body, _itself) {
      let r = of_jv(request)
      let meth = jtext_or_empty(r, "method")
      let ws = jtext(r, "workspace")
      let bytes = p55_body_bytes(fs, body)
      let (value, back) = bus.call_peer(station, ws, meth, r, bytes?)
      { value: to_jv(value), body: back.map(b => Whole(b)) }
    },
    clock: {
      now: () => wall_ms().to_double(),
      after: (ms, f) => bus_after(bus.host, ms, f),
    },
    log: (level, part, words, fields) => slice_log(level, part, words, of_jv(fields)),
    words: @replica_coord.station_words(to_jv(zh), to_jv(en)),
    lang: Ref((bus.lang.val)()),
    fork: f => ignore(bus.host.rt.fork_quiet(async fn() { f() catch { e => err_write("copies: \{e}\n") } })),
    tell: told,
  }
}

///|
/// The roster of a workspace as replica_coord takes it.
fn P55::members(self : P55, ws : String) -> Array[@replica_coord.Member]? {
  self.roster(ws).map(r => r.map(m => { id: m.0, name: m.1, tasks: m.2 }))
}

///|
async fn P55::start_copies(self : P55) -> Unit {
  let bus = self.bus
  let data = bus.data
  let here = () => Some(bus.key.id)
  let w = self.replica_world(async fn(name, _args) { raise BusError("copies: nothing answers \{name} here") }, (name, args) => {
    if name == "changed" {
      (bus.overview_changed.val)()
    } else if name == "trace" && args.length() > 0 {
      bus.emit_trace_json(of_jv(args[0]))
    }
  })
  let runner = self.export_runner(path([data, "stillfail.db"]), path([data, "replica"]), data, bus.key.id)
  let retire_ref : Ref[@replica_coord.Retire?] = Ref(None)
  let copies = @replica_coord.Copies::new(w, {
    data,
    here,
    places: () => to_jv({
      "home": jopt(self.home()),
      "workspaces": Json::array(self.memberships().map(m => ({ "workspace": Json::string(m.0), "name": Json::string(m.1) } : Json))),
    }),
    roster: ws => self.members(ws),
    runner,
    changed: () => (bus.overview_changed.val)(),
    restart: async fn() { restarter(data) },
    taking: Some(() => match retire_ref.val {
      Some(r) => r.taking_now()
      None => []
    }),
    backup: Some(() => @replica_coord.read_backup_config(to_jv((bus.config_raw.val)()))),
  })
  // The jobs and services of a workspace's chats up now (what a retirement stops and the preview lists).
  let jobs_in = async fn(ws : String) -> Array[@jsjson.JValue] {
    jitems(self.jobs("jobs.upIn", [Json::string(ws)])).map(to_jv)
  }
  let asks_ref : Ref[@replica_coord.RetireAsks?] = Ref(None)
  let retire = @replica_coord.Retire::new(w, {
    data,
    here,
    home: () => self.home(),
    roster: ws => self.members(ws),
    copies: {
      settle_export: async fn() { copies.settle_export() },
      bring_to: async fn(ws, peer) { copies.bring_to(ws, peer) },
      take_over: async fn(ws, origin, gen, connects, ws_here) { copies.take_over(ws, origin, gen, connects, ws_here) },
      formerly: () => copies.was,
      restored: () => copies.restored,
    },
    quiet: async fn(ws) {
      // (their jobs and services stop too, those of this workspace's chats alone; what they were is said there)
      let up = jobs_in(ws)
      ignore(self.hub("hub.quiet", [Json::string(ws)]))
      ignore(self.jobs("jobs.stopAllIn", [Json::string(ws), Json::string("this station's chats of the workspace went to another station")]))
      up
    },
    unquiet: async fn(ws) {
      ignore(self.hub("hub.unquiet", [Json::string(ws)]))
      ignore(self.coord_connects("retire.takeHeld", [Json::string(ws)]))
    },
    retired: async fn(ws) { ignore(self.hub("store.setSessionsWsRetired", [Json::string(ws), jopt(self.home())])) },
    accounts_own: async fn() {
      own_profiles((bus.config_raw.val)()).map(p => (jtext_or_empty(p, "id"), match jtext(p, "name") { Some(n) if n != "" => n; _ => jtext_or_empty(p, "id") }))
    },
    accounts_move: async fn(id, to) { to_jv(self.jobs("sharing.moveProfile", [Json::string(id), Json::string(to)])) },
    follow_accounts: Some(async fn(keys, map) {
      match self.hub("hub.followAccounts", [Json::array(keys.map(Json::string(_))), Json::array(map.map(p => Json::array([Json::string(p.0), Json::string(p.1)])))]) {
        Number(n, ..) => n.to_int()
        _ => 0
      }
    }),
    connects_of: async fn(ws) { core_strs(self.coord_connects("retire.of", [Json::string(ws)])) },
    bindings_of: async fn(cs) {
      cs.filter_map(c => match (try Ok(bus.store.binding(Json::string(c))) catch { e => Err(e) }) { Ok(String(s)) => Some((c, s)); _ => None })
    },
    move_connects: async fn(ws, to) { ignore(self.coord_connects("retire.move", [Json::string(ws), Json::string(to)])) },
    took: async fn(bindings, notes) { ignore(self.hub("retire.took", [of_jv(bindings), of_jv(notes)])) },
    repos_dir: path([data, "repos"]),
    room: async fn() {
      let (free, _) = room_of(data)
      (free, true)
    },
    has_git: async fn() { has_git(bus.host) },
    git: async fn(dir, args) { git_run(bus.host, dir, args) },
    lack_most: @replica_coord.lack_most,
    work: @replica_coord.work_here(w.fs),
    jobs_in,
    connects_named: async fn(ws) { jitems(self.coord_connects("retire.named", [Json::string(ws)])).map(to_jv) },
    tell: Some(async fn(session, text) { ignore(self.hub("hub.notify", [Json::string(session), Json::string(text)])) }),
    jobs: Some({
      start: async fn(session, j) { to_jv(self.jobs("jobs.start", [Json::string(session), of_jv(j)])) },
      running: async fn(session, name, command) {
        self.jobs("jobs.running", [Json::string(session), Json::string(name), Json::string(command)]) is True
      },
      say: async fn(session, text) { ignore(self.jobs("jobs.say", [Json::string(session), Json::string(text)])) },
    }),
    agent_home: Some(async fn(ws) {
      as_text(self.hub("hub.agentHome", [Json::string(ws)]))
    }),
    drives: (station, session) => match asks_ref.val {
      Some(a) => a.drives(station, session)
      None => false
    },
    of_workspace: Some(async fn(session, ws) { self.hub("hub.ofWorkspace", [Json::string(session), Json::string(ws)]) is True }),
    hold: () => @updates.hold(),
    changed: () => (bus.overview_changed.val)(),
    used: async fn(db, ws, home) { @replica_coord.used_connects(w.fs, db, ws, home) },
  })
  retire_ref.val = Some(retire)
  // station_retire: its cards in the asking chat, chosen in the app by an owner or admin (retire-asks.ts).
  let asks = @replica_coord.RetireAsks::new(w, {
    data,
    here,
    roster: ws => self.members(ws),
    ws_of: async fn(session) {
      match (try Ok(bus.store.session_ws(session)) catch { e => Err(e) }) {
        Ok(String(ws)) => Some(ws)
        Ok(Null) => self.home()
        _ => None
      }
    },
    card_post: async fn(session, text, card) {
      match self.hub("cards.post", [Json::string(session), Json::string(text), of_jv(card)]) {
        Object(_) as p => Some((match jfield(p, "thread") { Number(n, ..) => n; _ => 0.0 }, jtext_or_empty(p, "ts")))
        _ => None
      }
    },
    card_state: async fn(session, thread, ts) {
      match self.hub("cards.state", [Json::string(session), Json::number(thread), Json::string(ts)]) {
        String(s) => s
        _ => "none"
      }
    },
    notify: async fn(session, text) { ignore(self.hub("hub.notify", [Json::string(session), Json::string(text)])) },
    now: () => wall_ms().to_double(),
    id: None,
    starts: @replica_coord.retire_starts,
    manages: v => manages(of_jv(v)),
  }, retire)
  asks_ref.val = Some(asks)
  bus.parts.card_choice("retire", {
    may: (viewer, card, at) => asks.may(to_jv(viewer), to_jv(card), at_thread(at), jtext_or_empty(at, "ts")),
    chosen: (viewer, card, option, at) => asks.chosen(to_jv(viewer), to_jv(card), option, at_thread(at), jtext_or_empty(at, "ts")),
  })
  bus.parts.tools([
    {
      name: "station_retire",
      declared: tool_declared(retire_declared),
      call: async fn(args, context) {
        tool_said(async fn() {
          let session = self.session_of(context)
          of_jv(asks.tool(session, to_jv(args)))
        })
      },
    },
  ])
  // (the export's process ended with them, waited for: left to see its stdin close as the station exits, it went on
  // writing in the data directory after the station had stopped)
  self.closing(async fn() {
    copies.close()
    (runner.close)()
  })
  self.closing(async fn() { retire.close() })
  // The other stations' requests: a retirement's (`retire.`), the copies' (`replica.`).
  bus.on_peer_prefix("retire.", async fn(from, ws, meth, params, bytes) {
    let v = retire.answer((p, x) => copies.in_workspace(p, x), from, to_jv(with_method(params, meth)), bytes.map(b => Whole(b)), ws)
    (of_jv(v), None)
  })
  bus.on_peer_prefix("replica.", async fn(from, ws, meth, params, bytes) {
    let a = copies.answer(from, to_jv(with_method(params, meth)), bytes.map(b => Whole(b)), ws)
    (of_jv(a.value), p55_body_bytes(w.fs, a.body))
  })
  // (what the store says changed, told to the export)
  ignore(bus.subscribe_store(change => copies.told(to_jv(change))))
  // (the workspaces, or their stations, changed: what this station keeps and whom it tells, worked out again)
  let roster_now = () => Json::array(self.memberships().map(m => Json::array([Json::string(m.0), Json::array(m.3.map(p => jfield(p, "id")))]))).stringify()
  let roster = Ref(roster_now())
  ignore(
    (bus.cloud_listen.val)(_state => {
      let now = roster_now()
      if now != roster.val {
        roster.val = now
        bus.host.rt.fork(async fn() {
          copies.places_changed() catch {
            e => self.warn("copies", "the workspaces' copies not worked out again", e)
          }
        })
        |> ignore
      }
    }),
  )
  // (begun once the mesh carries requests: P5-1's transport; meanwhile what it asks of other stations waits)
  bus.host.rt.fork(name="copies start", async fn() {
    ignore(bus.door_ready.wait())
    copies.start() catch {
      e => self.warn("copies", "the copies did not start", e)
    }
    retire.start() catch {
      e => self.warn("retire", "the retirement did not go on", e)
    }
  })
  |> ignore
  bus.parts.overview("copies", async fn(viewer, _lang) {
    let ws = jtext_or_empty(viewer, "workspace")
    let o = of_jv(copies.overview(ws, manage=manages(viewer)))
    let r = of_jv(retire.overview(ws))
    match (o, r) {
      (Object(a), Object(b)) => {
        for k, v in b {
          a[k] = v
        }
        Json::object(a)
      }
      _ => o
    }
  })
  bus.parts.routes(copies_routes(bus, copies, retire))
  self.copies_ops(copies, retire)
  self.op("copies.overview", async fn(arg) { of_jv(copies.overview(jtext_or_empty(arg, "workspace"), manage=jtrue(arg, "manage"))) })
  self.op("copies.now", async fn(arg) { Json::string(copies.now(jtext(arg, "workspace"), jtext_or_empty(arg, "station"))) })
  self.op("copies.heard", async fn(arg) {
    Json::array(copies.heard(jtext_or_empty(arg, "station"), jtext_or_empty(arg, "workspace"), core_strs(jfield(arg, "gens"))).map(Json::string(_)))
  })
  self.op("retireAsks.tool", async fn(arg) {
    match arg {
      Array([String(session), args, ..]) => of_jv(asks.tool(session, to_jv(args)))
      _ => raise BusError("retireAsks.tool: [session, args]")
    }
  })
}

///|
fn at_thread(at : Json) -> Double {
  as_num(jfield(at, "thread")).unwrap_or(0.0)
}

///|
/// This station's own accounts (no copy borrowed, not the machine's login): what may move (share/index.ts moveProfile).
fn own_profiles(raw : Json) -> Array[Json] {
  jitems(jfield(raw, "profiles")).filter(p => jtext(p, "id") is Some(_) &&
    !(jfield(p, "machine") is True) &&
    !(jfield(jfield(p, "share"), "borrowed") is True))
}

///|
/// Shared implementation for `PUT /copies/settings` and `copies.setSettings`.
async fn copies_put_settings(bus : LiveBus, copies : @replica_coord.Copies, ws : String, b : Json) -> Result[Json, String] {
  let crypto = @vault_crypto.Crypto::of_host(bus.host)
  let rand_hex = (n : Int) => {
    let bytes = crypto.random(n) catch { _ => b"" }
    @hash.hex_encode(bytes[:])
  }
  let (backup_jv, gen_keys) = @replica_coord.apply_backup_update(to_jv((bus.config_raw.val)()), to_jv(b), rand_hex) catch {
    e => return Err(message_text_any(e))
  }
  let backup_json = of_jv(backup_jv)
  try {
    ignore(
      (bus.config_update.val)(raw => match raw {
        Object(m) => {
          let next : Map[String, Json] = {}
          for k, v in m {
            next[k] = v
          }
          next["backup"] = backup_json
          Json::object(next)
        }
        _ => { "backup": backup_json }
      }),
    )
  } catch {
    e => return Err(message_text_any(e))
  }
  copies.config_changed()
  (bus.overview_changed.val)()
  let view = of_jv(copies.backup_view(ws))
  let gk : Map[String, Json] = {}
  for p in gen_keys {
    gk[p.0] = Json::string(p.1)
  }
  match view {
    Object(m) => {
      m["generatedKeys"] = Json::object(gk)
      Ok(Json::object(m))
    }
    _ => Ok(view)
  }
}

///|
/// Shared implementation for `POST /copies/s3/test` and `copies.testS3`.
async fn copies_test_s3(bus : LiveBus, b : Json) -> Result[Json, String] {
  let saved = @replica_coord.read_backup_config(to_jv((bus.config_raw.val)())).s3
  let id = jtext(b, "id").unwrap_or("")
  let prev = if id != "" {
    saved.search_by(t => t.id == id).map(i => saved[i])
  } else {
    None
  }
  let pick_str = (k : String, fallback : String) => match jtext(b, k) {
    Some(s) if s.trim().to_string() != "" => s.trim().to_string()
    _ => fallback
  }
  let pick_secret = (k : String, fallback : String) => match jtext(b, k) {
    Some(s) if s != "" => s
    _ => fallback
  }
  let pick_bool = (k : String, fallback : Bool) => match jfield(b, k) {
    True => true
    False => false
    _ => fallback
  }
  let raw_target = @replica_coord.jo([
    ("id", @replica_coord.js(if id != "" { id } else { "test" })),
    ("name", @replica_coord.js(pick_str("name", match prev { Some(p) => p.name; None => "test" }))),
    ("endpoint", @replica_coord.js(pick_str("endpoint", match prev { Some(p) => p.endpoint; None => "" }))),
    ("region", @replica_coord.js(pick_str("region", match prev { Some(p) => p.region; None => "auto" }))),
    ("bucket", @replica_coord.js(pick_str("bucket", match prev { Some(p) => p.bucket; None => "" }))),
    ("prefix", @replica_coord.js(pick_str("prefix", match prev { Some(p) => p.prefix; None => @replica_coord.default_backup_prefix }))),
    ("forcePathStyle", @replica_coord.jb(pick_bool("forcePathStyle", match prev { Some(p) => p.force_path_style; None => true }))),
    ("accessKeyId", @replica_coord.js(pick_str("accessKeyId", match prev { Some(p) => p.access_key_id; None => "" }))),
    ("secretAccessKey", @replica_coord.js(pick_secret("secretAccessKey", match prev { Some(p) => p.secret_access_key; None => "" }))),
    ("encryptionKey", @replica_coord.js(pick_str("encryptionKey", match prev { Some(p) => p.encryption_key; None => "0".repeat(64) }))),
    ("includeTranscripts", @replica_coord.jb(pick_bool("includeTranscripts", match prev { Some(p) => p.include_transcripts; None => true }))),
  ])
  let target = @replica_coord.normalize_s3_target(raw_target, 0) catch {
    e => return Err(message_text_any(e))
  }
  let client = @replica_coord.S3Client::new(target, bus.host, () => wall_ms().to_double())
  match (try { Ok(client.test_connection()) } catch { e => Err(e) }) {
    Ok(_) => Ok({ "ok": Json::boolean(true) })
    Err(e) => Ok({ "ok": Json::boolean(false), "error": Json::string(message_text_any(e)) })
  }
}

///|
/// api/routes/copies.ts: a retirement started, previewed, called off and tried again; backup settings & S3 test; a lost station's copy taken back.
fn copies_routes(bus : LiveBus, copies : @replica_coord.Copies, retire : @replica_coord.Retire) -> Array[PartRoute] {
  let managers = "only the workspace's owners and admins retire a station"
  let refusal = (e : Error) => match e {
    @replica_coord.Thrown(_) => refused(409, message_text_any(e))
    _ => refused(500, message_text_any(e))
  }
  [
    p55_route("POST", "^/retire$", async fn(r) {
      let viewer = jfield(r, "viewer")
      if !manages(viewer) {
        return refused(403, managers)
      }
      if !@replica_coord.retire_starts {
        return refused(409, tr(lang_in(r), "station.retire.off"))
      }
      guard jtext(jfield(r, "body"), "to") is Some(to) else {
        return refused(400, "to is needed: the station the chats go to")
      }
      match (try { Ok(retire.retire(jtext_or_empty(viewer, "workspace"), to, jtext_or_empty(viewer, "email"))) } catch { e => Err(e) }) {
        Ok(_) => answered(202, { "retiring": Json::boolean(true) })
        Err(e) => refusal(e)
      }
    }),
    p55_route("GET", "^/retire/preview$", async fn(r) {
      let viewer = jfield(r, "viewer")
      if !manages(viewer) {
        return refused(403, managers)
      }
      match (try { Ok(retire.preview(jtext_or_empty(viewer, "workspace"))) } catch { e => Err(e) }) {
        Ok(v) => answered(200, of_jv(v))
        Err(e) => refused(500, message_text_any(e))
      }
    }),
    p55_route("DELETE", "^/retire$", async fn(r) {
      let viewer = jfield(r, "viewer")
      if !manages(viewer) {
        return refused(403, managers)
      }
      match (try { Ok(retire.cancel(jtext_or_empty(viewer, "workspace"))) } catch { e => Err(e) }) {
        Ok(_) => answered(200, { "ok": Json::boolean(true) })
        Err(e) => refusal(e)
      }
    }),
    p55_route("POST", "^/retire/again$", async fn(r) {
      let viewer = jfield(r, "viewer")
      if !manages(viewer) {
        return refused(403, managers)
      }
      match (try { Ok(retire.again(jtext_or_empty(viewer, "workspace"))) } catch { e => Err(e) }) {
        Ok(_) => answered(202, { "ok": Json::boolean(true) })
        Err(e) => refusal(e)
      }
    }),
    p55_route("GET", "^/copies/history$", async fn(r) {
      let viewer = jfield(r, "viewer")
      let limit = match jtext(jfield(r, "query"), "limit") {
        Some(s) if s != "" =>
          match (try { Some(@string.parse_int(s)) } catch { _ => None }) {
            Some(n) => if n < 1 { 1 } else if n > 50 { 50 } else { n }
            None => 30
          }
        _ => 30
      }
      answered(200, { "records": of_jv(copies.history_json(jtext_or_empty(viewer, "workspace"), limit~)) })
    }),
    p55_route("GET", "^/copies/settings$", async fn(r) {
      let viewer = jfield(r, "viewer")
      if !manages(viewer) {
        return refused(403, "only the workspace's owners and admins manage backup settings")
      }
      answered(200, of_jv(copies.backup_view(jtext_or_empty(viewer, "workspace"))))
    }),
    p55_route("PUT", "^/copies/settings$", async fn(r) {
      let viewer = jfield(r, "viewer")
      if !manages(viewer) {
        return refused(403, "only the workspace's owners and admins manage backup settings")
      }
      match copies_put_settings(bus, copies, jtext_or_empty(viewer, "workspace"), jfield(r, "body")) {
        Ok(v) => answered(200, v)
        Err(msg) => refused(400, msg)
      }
    }),
    p55_route("POST", "^/copies/s3/test$", async fn(r) {
      let viewer = jfield(r, "viewer")
      if !manages(viewer) {
        return refused(403, "only the workspace's owners and admins test backup targets")
      }
      match copies_test_s3(bus, jfield(r, "body")) {
        Ok(v) => answered(200, v)
        Err(msg) => refused(400, msg)
      }
    }),
    p55_route("POST", "^/copies/restore$", async fn(r) {
      let viewer = jfield(r, "viewer")
      if !manages(viewer) {
        return refused(403, "only the workspace's owners and admins restore a lost station's chats")
      }
      let b = jfield(r, "body")
      let from = jfield(b, "from")
      match (jtext(b, "station"), jtext(b, "gen"), jtext(from, "station"), jtext(from, "s3")) {
        (Some(station), Some(gen), Some(from_st), _) if from_st != "" => {
          // (it goes on as the copy is brought; how far it is, the station's settings show)
          copies.w.go(async fn() { copies.restore(jtext_or_empty(viewer, "workspace"), station, gen, from_st) })
          answered(202, { "restoring": Json::boolean(true) })
        }
        (Some(station), Some(gen), _, Some(from_s3)) if from_s3 != "" => {
          copies.w.go(async fn() { copies.restore(jtext_or_empty(viewer, "workspace"), station, gen, from_s3, from_s3=true) })
          answered(202, { "restoring": Json::boolean(true) })
        }
        _ => refused(400, "station, gen and from: {station} or {s3} are needed")
      }
    }),
  ]
}

///|
fn message_text_any(e : Error) -> String {
  match e {
    BusError(m) => m
    e => @replica_coord.message_of(e)
  }
}

///|
/// A tool's answer as MCP says it: its text, pretty JSON where it is not words.
fn tool_text(v : Json) -> Json {
  let text = match v {
    String(s) => s
    other => other.stringify(indent=2)
  }
  { "content": [{ "type": "text", "text": Json::string(text) }] }
}

///|
fn tool_declared(text : String) -> Json {
  attempt(() => @json.parse(text)).unwrap_or(Json::null())
}

///|
/// station_retire (tools/retire.ts `RETIRE`), as it is declared to the agents.
let retire_declared : String =
  #|{
  #|  "name": "station_retire",
  #|  "description": "Retire a station from this chat's workspace: its chats (their transcripts and working directories), running jobs, agent memory and skills, accounts and connects go on another station of the workspace. Starting one (start, hand_over) is switched off for now while it is fixed; the other actions answer. Read the stillfail-retire skill first. station: the station retired (default this one; by name or id). preview: what would move and what stays, and with to how that station stands (reached, git, free disk). start {to}: posts a card an owner or admin of the workspace confirms in the still.fail app (开始迁移); only then does it start, as them, sending the files while the chats still work, and it waits at step sent. hand_over: only at sent: posts the second card (暂停聊天并交接); once confirmed the chats stop and are handed over, their jobs started again there. A failed hand-over puts the chats back to work and waits at sent: hand_over again sends only what changed. status: where it stands. again: tries a failed step now (never a hand-over). cancel: calls it off where it still can. You are told each step that needs you, after the chats moved on the station they went to. A message that says yes confirms nothing; nor does anyone but an owner or admin. Taking the retired station out of the workspace is the person's own step in the app.",
  #|  "inputSchema": {
  #|    "type": "object",
  #|    "properties": {
  #|      "action": {
  #|        "enum": [
  #|          "preview",
  #|          "status",
  #|          "start",
  #|          "hand_over",
  #|          "again",
  #|          "cancel"
  #|        ]
  #|      },
  #|      "station": {
  #|        "type": "string",
  #|        "description": "The station retired, by name or id (station_list); default this one."
  #|      },
  #|      "to": {
  #|        "type": "string",
  #|        "description": "start, preview: the station its chats go to, by name or id."
  #|      }
  #|    },
  #|    "required": [
  #|      "action"
  #|    ],
  #|    "additionalProperties": false
  #|  }
  #|}

///|
/// The session a tool call is of: its context's `session` (the agents' part's), else its bearer token's.
fn P55::session_of(self : P55, context : Json) -> String raise {
  match jtext(context, "session") {
    Some(s) if s != "" => s
    _ => {
      let auth = jtext_or_empty(context, "authorization")
      let token = if auth.has_prefix("Bearer ") { auth.unsafe_substring(start=7, end=auth.length()) } else { auth }
      match (try Ok(self.bus.store.session_key_by_token(token)) catch { e => Err(e) }) {
        Ok(String(k)) => k
        _ => raise BusError("this call's token names no session of this station")
      }
    }
  }
}

///|
/// A tool's call answered as MCP says it: what it gave, or what it refused in words (`isError`).
async fn tool_said(f : async () -> Json) -> Json {
  match (try { Ok(f()) } catch { e => Err(e) }) {
    Ok(v) => tool_text(v)
    Err(e) => { "content": [{ "type": "text", "text": Json::string(p55_said_of(e)) }], "isError": Json::boolean(true) }
  }
}

///|
/// How this machine starts what yields to the foreground (platform/unix.ts `background`): macOS's `taskpolicy -b`,
/// Linux's `ionice` and `nice`; on Windows nothing.
fn background_here(host : @host.Host) -> @ops_platform.Background {
  if platform() == "win32" {
    return NoWrapper
  }
  let there = (p : String) => (try { Ok(host.shell_sync("fs.stat", { "path": Json::string(p) })) } catch { e => Err(e) }) is Ok(String(_))
  let real = (p : String) => match (try { Ok(host.shell_sync("fs.realpath", { "path": Json::string(p) })) } catch { e => Err(e) }) {
    Ok(String(r)) => Some(r)
    _ => None
  }
  @ops_platform.background_found(platform() == "darwin", there, real)
}

///|
/// The copies' export in a process of its own (replica/runner.ts `exportThread`: `--builder replica-export`), started
/// as the station's background work is (mb-reader.ts `BACKGROUND_BUILDERS`, under `platform.backgrounded`), so its
/// reads, hashing, compressing and writing yield the disk and the CPU to the foreground; asked as replica_coord's
/// `process_runner` asks it, which alone reads what it says (its end too, so a close waits for it however an ask is).
fn P55::export_runner(self : P55, db : String, replica : String, data : String, origin : String) -> @replica_coord.Runner {
  let host = self.bus.host
  let how = background_here(host)
  let args = ["--builder", "replica-export", "--db", db, "--replica", replica, "--data-dir", data, "--origin", origin, "--sep", sep()]
  let start = fn() -> @replica_coord.ExportProcess raise {
    let (program, argv) = @ops_platform.backgrounded_on(how, self.bus.argv0, args)
    let p = spawn(host, program, argv, stdin_piped=true, stdout=Piped, stderr=Ignored)
    {
      write: b => p.write(b),
      end_input: () => p.end_input(),
      kill: sig => {
        p.end_input()
        ignore(kill(p.pid, sig))
      },
      next: async fn() {
        match p.events.take() {
          Out(b) => Said(b)
          Err(_) => Other
          Exit(code, signal) => Ended(code, signal)
        }
      },
    }
  }
  @replica_coord.process_runner(start, () => wall_ms().to_double())
}
