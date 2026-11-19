// Shared composition bus (`station/src/services.ts` Context layers in MoonBit) connecting `run.mbt` and the 5 live
// subsystem slices (`live_p5_1` .. `live_p5_5`), using only types already imported in `station_main` so each slice
// compiles and tests end-to-end on its own and combines cleanly with zero circular package dependencies.

///|
pub(all) suberror BusError {
  BusError(String)
}

///|
/// Its words, as what takes an error by its text says it.
pub impl Show for BusError with output(self, logger) {
  match self {
    BusError(s) => logger.write_string(s)
  }
}

///|
pub(all) struct LiveBus {
  host : @host.Host
  argv0 : String
  args : Array[String]
  data : String
  app : String
  version : String
  built_at : Double?
  key : @cloud_lock.StationKey
  db : @sql.Db
  store : @store_sessions.Store
  parts : StationParts
  stopped : @effect.Deferred[String]
  /// Resolved to `http://127.0.0.1:<port>/mcp` once the previous station released `run/hub.json` and the agents' door is listening.
  door_ready : @effect.Deferred[String]
  /// Opens the agents' door (`/mcp`) once sessions are taken up, resolving `door_ready`; idempotent.
  open_door : Ref[async () -> String]
  handed : Bool
  mcp_token : String
  previous_pid : Int?
  previous_gone : async () -> Unit
  control_say : (Json) -> Unit
  stop_station : (String) -> Unit
  restart_front : (() -> Unit)?
  /// ops/launcher.ts `runInstaller` (`--launcher-installer`): the release's installer started by the launcher, where
  /// this process could not start it itself (updates.ts `startPlanned`).
  run_installer : ((String, Map[String, String]) -> Unit)?
  // ── Config & Own (owned by P5-1; defaults read/write config.json directly for standalone slice tests) ──
  config_raw : Ref[() -> Json]
  config_update : Ref[async ((Json) -> Json) -> Json]
  config_listen : Ref[((Json) -> Unit) -> () -> Unit]
  config_check : Ref[((Json) -> String?) -> Unit]
  own_add : Ref[(String) -> Unit]
  own_paths : Ref[() -> Array[String]]
  lang : Ref[() -> String]
  // ── ControlPlane & CloudState (owned by P5-1; defaults read mesh/cloud.json directly) ──
  cloud_state : Ref[() -> Json?]
  cloud_reached : Ref[() -> Bool]
  cloud_listen : Ref[((Json?) -> Unit) -> () -> Unit]
  cloud_call : Ref[async (String, Json) -> Json]
  // ── Store change pubsub, Readers & Events SSE (owned by P5-1) ──
  store_listeners : Array[(Int, (Json) -> Unit)]
  mut next_listener : Int
  reader_ask : Ref[async (String, Json, String) -> Json]
  /// What the model catalog says now, as catalog.ts `catalog()` gives it ({ version, models }): set by the model
  /// catalog's part (P5-3), given to the readers as it changes (read/pool.ts `give`).
  model_catalog : Ref[() -> Json]
  events_tell : Ref[(String, Json, String, Json) -> Unit]
  overview_changed : Ref[() -> Unit]
  host_sample : Ref[async () -> Json]
  // ── PeerBus & MeshSide (transport attached by P5-1; handlers registered by any slice) ──
  peer_handlers : Map[String, async (String, String?, Json, Bytes?) -> (Json, Bytes?)]
  peer_prefixes : Array[(String, async (String, String?, String, Json, Bytes?) -> (Json, Bytes?))]
  peer_call : Ref[async (String, String?, String, Json, Bytes?) -> (Json, Bytes?)]
  mesh_front_kind : Ref[() -> String]
  mesh_relay_conflict : Ref[() -> Bool]
  mesh_net_info : Ref[() -> Json]
  peer_http : Ref[async (Request, Json) -> Reply?]
  outside_reaches : Ref[(String, String?) -> Bool]
  forwarded_port : Ref[(Int) -> Bool]
  runtimes_available : Ref[() -> Array[String]]
  here_device : Ref[async (Json, Json) -> Unit]
  // ── Agents / Hub / MCP / Handover / Drain / Status (owned by P5-2) ──
  /// Custom `/mcp` HTTP handler (when `Some`, handles auth, `LISTINGS`, `OUTWARD` gating, `station_tool`, `SPEAKS`).
  mcp_handle : Ref[(async (Request) -> Reply)?]
  hub_ask : Ref[async (String, Json) -> Json]
  handover_sessions : Ref[async () -> Array[Json]]
  take_handover : Ref[async (Json?) -> Unit]
  drain_wait : Ref[async () -> String]
  status_agents : Ref[() -> Json?]
  // ── Cross-slice service bridges (P5-3, P5-4, P5-5) ──
  /// P5-3: Jobs, Remote, WorkspaceWatch, Accounts, Sharing, MemorySync, ChatShares, Resources, Search, Models, Links.
  jobs_ask : Ref[async (String, Json) -> Json]
  /// P5-4: Vault, StationDrive, Helper, Grants, HelperFolders, ScreenRegistry, Browser, Adb, Devices, Terminals, Logins.
  ui_ask : Ref[async (String, Json) -> Json]
  /// P5-5: Slack, Feishu, Comma, Group, WorkspaceConnects, Copies, Moves, Updates, Features.
  coord_ask : Ref[async (String, Json) -> Json]
  // ── Hooks any slice registers on (plain lists: each slice adds its own, none provides a whole) ──
  /// The control plane's presence said a release is out (`plane.told("release", …)`: the updates, the fixed bug reports).
  release_hearers : Array[() -> Unit]
  /// A peer station was heard (peer.ts `heard`: the moves' handover reached, its plan asked again).
  peer_hearers : Array[(String) -> Unit]
  /// The helper processes' pids each part keeps (resources' `programs`).
  helper_pids : Array[() -> Array[Int]]
  /// What each part lets go of that answers nothing, short of memory (pool.ts `onTrim`): a count.
  trimmers : Array[() -> Int]
  /// What `@store_threads.Store`'s `requested` asked prepared, under way (agents.ts `namesPreparing`).
  threads_preparing : Map[String, Bool]
}

///|
pub fn LiveBus::new(
  host : @host.Host,
  argv0 : String,
  args : Array[String],
  data : String,
  app : String,
  version : String,
  key : @cloud_lock.StationKey,
  db : @sql.Db,
  store : @store_sessions.Store,
  parts : StationParts,
  stopped : @effect.Deferred[String],
  handed : Bool,
  mcp_token : String,
  previous_pid : Int?,
  control_say : (Json) -> Unit,
  stop_station : (String) -> Unit,
  restart_front? : () -> Unit,
  run_installer? : (String, Map[String, String]) -> Unit,
) -> LiveBus {
  let cfg_checks : Array[(Json) -> String?] = []
  let cfg_listeners : Array[(Int, (Json) -> Unit)] = []
  let next_cfg = Ref(0)
  let own : Array[String] = [data, config_path(data)]
  let read_cfg = () => read_json(config_path(data)).unwrap_or(Json::object({}))
  let default_update = async fn(edit : (Json) -> Json) -> Json {
    let next = edit(read_cfg())
    for chk in cfg_checks {
      if chk(next) is Some(why) {
        raise BusError(why)
      }
    }
    write_whole(config_path(data), next.stringify() + "\n")
    for l in cfg_listeners {
      (l.1)(next)
    }
    next
  }
  let cloud_listeners : Array[(Int, (Json?) -> Unit)] = []
  let next_cloud = Ref(0)
  // (previous.ts `previousProcess`: the process before is gone once its pid is, not once run/hub.json is: Node lets go
  // of hub.json as its agents stop and writes run/events.json after; PREVIOUS_LIMIT_MS at most)
  let wait_prev = async fn() -> Unit {
    let mut waited = 0
    while (previous_pid.map(pid_alive).unwrap_or(false) || held_by_hub(data) is Some(_)) && waited < 400 && !stopped.is_done() {
      waited += 1
      @effect.sleep(100) // timer: a retry until the process before is gone (it says nothing when it ends)
    }
  }
  let peer_handlers : Map[String, async (String, String?, Json, Bytes?) -> (Json, Bytes?)] = Map([])
  let peer_prefixes : Array[(String, async (String, String?, String, Json, Bytes?) -> (Json, Bytes?))] = []
  let default_peer_call = async fn(
    target : String,
    ws : String?,
    meth : String,
    params : Json,
    bytes : Bytes?,
  ) -> (Json, Bytes?) {
    if target == key.id || target == "self" {
      if peer_handlers.get(meth) is Some(h) {
        return h(key.id, ws, params, bytes)
      }
      for p in peer_prefixes {
        if meth.has_prefix(p.0) {
          return (p.1)(key.id, ws, meth, params, bytes)
        }
      }
    }
    raise BusError("mesh transport not attached for \{target}: \{meth}")
  }
  let door_ready : @effect.Deferred[String] = @effect.Deferred::new()
  let b : LiveBus = {
    host,
    argv0,
    args,
    data,
    app,
    version,
    built_at: match build_built_at(app) {
      Some(ms) => Some(ms)
      None => station_built_at(args, argv0)
    },
    key,
    db,
    store,
    parts,
    stopped,
    door_ready,
    open_door: Ref(async fn() { door_ready.wait() }),
    handed,
    mcp_token,
    previous_pid,
    previous_gone: wait_prev,
    control_say,
    stop_station,
    restart_front,
    run_installer,
    config_raw: Ref(read_cfg),
    config_update: Ref(default_update),
    config_listen: Ref(fn(f) {
      next_cfg.val += 1
      let id = next_cfg.val
      cfg_listeners.push((id, f))
      () => ignore(cfg_listeners.search_by(x => x.0 == id).map(i => cfg_listeners.remove(i)))
    }),
    config_check: Ref(fn(chk) { cfg_checks.push(chk) }),
    own_add: Ref(fn(p) { if !own.contains(p) { own.push(p) } }),
    own_paths: Ref(() => own.copy()),
    lang: Ref(() => station_lang(data)),
    cloud_state: Ref(() => read_json(path([data, "mesh", "cloud.json"]))),
    cloud_reached: Ref(() => false),
    cloud_listen: Ref(fn(f) {
      next_cloud.val += 1
      let id = next_cloud.val
      cloud_listeners.push((id, f))
      () => ignore(cloud_listeners.search_by(x => x.0 == id).map(i => cloud_listeners.remove(i)))
    }),
    cloud_call: Ref(async fn(_op, _arg) { Json::null() }),
    store_listeners: [],
    next_listener: 0,
    reader_ask: Ref(async fn(_op, _q, _lang) { Json::null() }),
    model_catalog: Ref(() => { "version": Json::number(0.0), "models": Json::object({}) }),
    events_tell: Ref(fn(_ev, _data, _key, _to) { () }),
    overview_changed: Ref(() => ()),
    host_sample: Ref(async fn() { machine() }),
    peer_handlers,
    peer_prefixes,
    peer_call: Ref(default_peer_call),
    mesh_front_kind: Ref(() => "direct"),
    mesh_relay_conflict: Ref(() => false),
    mesh_net_info: Ref(() => Json::null()),
    peer_http: Ref(async fn(_r, _conn) { Some(plain(503, "mesh not up")) }),
    outside_reaches: Ref((_target, _ws) => false),
    forwarded_port: Ref(_port => false),
    runtimes_available: Ref(() => []),
    here_device: Ref(async fn(_ask, _conn) { () }),
    mcp_handle: Ref(None),
    hub_ask: Ref(async fn(_op, _arg) { Json::null() }),
    handover_sessions: Ref(async fn() { [] }),
    take_handover: Ref(async fn(_h) { () }),
    drain_wait: Ref(async fn() { "idle" }),
    status_agents: Ref(() => None),
    jobs_ask: Ref(async fn(_op, _arg) { Json::null() }),
    ui_ask: Ref(async fn(_op, _arg) { Json::null() }),
    coord_ask: Ref(async fn(_op, _arg) { Json::null() }),
    release_hearers: [],
    peer_hearers: [],
    helper_pids: [],
    trimmers: [],
    threads_preparing: Map([]),
  }
  // (the store's own writes told on the bus too, as the program's changes are: one stream of changes, as store.ts's
  // `subscribe` gives every part of the TypeScript)
  ignore(b.store.subscribe(c => b.notify_store(c)))
  b
}

///|
pub fn LiveBus::subscribe_store(self : LiveBus, f : (Json) -> Unit) -> () -> Unit {
  self.next_listener += 1
  let id = self.next_listener
  self.store_listeners.push((id, f))
  () => ignore(self.store_listeners.search_by(x => x.0 == id).map(i => self.store_listeners.remove(i)))
}

///|
pub fn LiveBus::notify_store(self : LiveBus, change : Json) -> Unit {
  for l in self.store_listeners.copy() {
    (l.1)(change)
  }
}

///|
pub fn LiveBus::on_peer(
  self : LiveBus,
  meth : String,
  handler : async (String, String?, Json, Bytes?) -> (Json, Bytes?),
) -> Unit {
  self.peer_handlers[meth] = handler
}

///|
pub fn LiveBus::on_peer_prefix(
  self : LiveBus,
  prefix : String,
  handler : async (String, String?, String, Json, Bytes?) -> (Json, Bytes?),
) -> Unit {
  self.peer_prefixes.push((prefix, handler))
}

///|
pub async fn LiveBus::dispatch_peer(
  self : LiveBus,
  from_station : String,
  ws : String?,
  meth : String,
  params : Json,
  bytes : Bytes?,
) -> (Json, Bytes?) {
  if self.peer_handlers.get(meth) is Some(h) {
    return h(from_station, ws, params, bytes)
  }
  for p in self.peer_prefixes {
    if meth.has_prefix(p.0) {
      return (p.1)(from_station, ws, meth, params, bytes)
    }
  }
  raise BusError("unknown peer method: \{meth}")
}

///|
/// peer.ts `heard`: what follows a peer station's being heard.
pub fn LiveBus::on_peer_heard(self : LiveBus, f : (String) -> Unit) -> Unit {
  self.peer_hearers.push(f)
}

///|
pub fn LiveBus::notify_peer_heard(self : LiveBus, peer : String) -> Unit {
  if peer == "" || peer == self.key.id {
    return
  }
  for f in self.peer_hearers.copy() {
    f(peer)
  }
}

///|
/// The control plane's `release` (presence): what reads it again.
pub fn LiveBus::on_release(self : LiveBus, f : () -> Unit) -> Unit {
  self.release_hearers.push(f)
}

///|
pub fn LiveBus::told_release(self : LiveBus) -> Unit {
  for f in self.release_hearers.copy() {
    f()
  }
}

///|
/// A part's helper processes, counted in the station's own memory (resources' `programs`).
pub fn LiveBus::register_pids(self : LiveBus, f : () -> Array[Int]) -> Unit {
  self.helper_pids.push(f)
}

///|
/// What a part lets go of short of memory (pool.ts `onTrim`), asked by resources' `trimIdle`.
pub fn LiveBus::on_trim(self : LiveBus, f : () -> Int) -> Unit {
  self.trimmers.push(f)
}

///|
pub fn LiveBus::trim_helpers(self : LiveBus) -> Int {
  let mut n = 0
  for f in self.trimmers {
    n += f()
  }
  n
}

///|
pub fn LiveBus::all_helper_pids(self : LiveBus) -> Array[Int] {
  let out : Array[Int] = []
  for f in self.helper_pids {
    for pid in f() {
      if pid > 0 && !out.contains(pid) {
        out.push(pid)
      }
    }
  }
  out
}

///|
/// agents.ts's `threads.requested` (721-733): what the threads' store found not yet prepared (a session's latest
/// thread, its chat's names) asked of the readers' builders, once each while under way.
pub fn LiveBus::drain_thread_requests(self : LiveBus, threads : @store_threads.Store) -> Unit {
  if threads.requested.is_empty() {
    return
  }
  let reqs = threads.requested.copy()
  threads.requested.clear()
  let latest : Array[Json] = []
  let names : Array[Json] = []
  for r in reqs {
    match r {
      { "latestThread": String(s), .. } if !self.threads_preparing.contains("l:" + s) => {
        self.threads_preparing["l:" + s] = true
        latest.push(Json::string(s))
      }
      { "sessionChat": String(s), .. } if !self.threads_preparing.contains("n:" + s) => {
        self.threads_preparing["n:" + s] = true
        names.push(Json::string(s))
      }
      _ => ()
    }
  }
  let prepare = (op : String, prefix : String, keys : Array[Json]) => if !keys.is_empty() {
    ignore(
      self.host.rt.fork_quiet(name="threads prepared", async fn() {
        ignore((self.reader_ask.val)(op, Json::array(keys), "")) catch {
          _ => ()
        }
        for k in keys {
          if k is String(s) {
            self.threads_preparing.remove(prefix + s)
          }
        }
      }),
    )
  }
  prepare("$latestThreads", "l:", latest)
  prepare("$sessionChatNames", "n:", names)
}

///|
pub async fn LiveBus::call_peer(
  self : LiveBus,
  target : String,
  ws : String?,
  meth : String,
  params : Json,
  bytes? : Bytes,
) -> (Json, Bytes?) {
  (self.peer_call.val)(target, ws, meth, params, bytes)
}

///|
fn channel_id_of(s : String) -> String? {
  let t = s.trim().to_owned()
  if t == "stable" || t == "beta" {
    Some(t)
  } else {
    None
  }
}

///|
/// updates/versions.ts `channelOf`: `config.json`'s `updateChannel`, else `<app>/CHANNEL`, else `"stable"`.
pub fn station_channel(raw : Json, app : String) -> String {
  let from_cfg = match raw {
    Object(m) =>
      match m.get("updateChannel") {
        Some(String(s)) => channel_id_of(s)
        _ => None
      }
    _ => None
  }
  match from_cfg {
    Some(ch) => ch
    None =>
      match read_text(path([app, "CHANNEL"])) {
        Some(t) => channel_id_of(t).unwrap_or("stable")
        None => "stable"
      }
  }
}

///|
/// features.ts `stationFeature`: `id` first so `scripts/features-check.ts` matches `station_feature("terminal", ...)` and `station_feature("stationMove", ...)`.
pub fn station_feature(id : String, raw : Json, app : String) -> Bool {
  (id == "terminal" || id == "stationMove") && station_channel(raw, app) == "beta"
}

///|
/// features.ts `stationFeatures`: the `beta` features on here, for `overview("features", ...)`.
pub fn station_features(raw : Json, app : String) -> Array[String] {
  if station_channel(raw, app) == "beta" {
    ["terminal", "stationMove"]
  } else {
    []
  }
}

///|
/// Whether this station only runs tasks (a rig, rig/main.ts): `run --rig`, or the control plane's state naming its
/// grants' owner. What P5-1 makes and which slices `run` starts go by it.
pub fn LiveBus::as_rig(self : LiveBus) -> Bool {
  self.args.contains("--rig") || (self.cloud_state.val)() is Some({ "rig": Object(_), .. })
}

// ── What one slice asks of another, typed ──
// Each is asked by its name on the slice's `*_ask` (what a slice's test stands in for), its arguments named here once:
// a caller cannot misname a field the answering slice reads (`rejected`, not `runtime`). station/test/
// mb-station-contracts.test.ts holds every name asked here to one its slice answers.

///|
/// The agents' side ends its sessions' processes as the station stops (not handing over).
async fn LiveBus::hub_shutdown(self : LiveBus) -> Unit {
  ignore((self.hub_ask.val)("shutdown", Json::null()))
}

///|
/// A session's agent told `text` (the hub's notify, which wakes it).
async fn LiveBus::hub_notify(self : LiveBus, session~ : String, text~ : String) -> Unit {
  ignore((self.hub_ask.val)("notify", { "session": Json::string(session), "text": Json::string(text) }))
}

///|
/// A runtime installed or updated from the pages (agents.ts `onRuntimeChanged`): what waited for it started, its
/// processes on the new one.
async fn LiveBus::hub_runtime_changed(
  self : LiveBus,
  kind~ : String,
  installed~ : Bool,
  replaced~ : Bool,
) -> Unit {
  ignore(
    (self.hub_ask.val)("runtimeChanged", {
      "kind": Json::string(kind),
      "installed": Json::boolean(installed),
      "replaced": Json::boolean(replaced),
    }),
  )
}

///|
/// The disk low: archived sessions' rooms made smaller, until `low_bytes` are free.
async fn LiveBus::hub_relieve_archived(self : LiveBus, low_bytes~ : Double) -> Unit {
  ignore((self.hub_ask.val)("relieveArchived", { "lowBytes": Json::number(low_bytes) }))
}

///|
/// A decided card's outcome queued for the agents' side's worker (agents.ts `cardOutcomes.save`).
async fn LiveBus::hub_card_outcomes_save(self : LiveBus, outcome : Json) -> Unit {
  ignore((self.hub_ask.val)("cardOutcomes.save", Json::array([outcome])))
}

///|
/// A job stopped by its id.
async fn LiveBus::jobs_stop(self : LiveBus, id : Json) -> Unit {
  ignore((self.jobs_ask.val)("jobs.stop", { "id": id }))
}

///|
/// The machine's logins read again (a runtime installed or updated).
async fn LiveBus::jobs_machine_refresh(self : LiveBus) -> Unit {
  ignore((self.jobs_ask.val)("accounts.machineRefresh", Json::array([])))
}

///|
/// The model catalog read again, as the control plane said it changed (`etag`, null where it gave none).
async fn LiveBus::jobs_models_refresh(self : LiveBus, etag : Json) -> Unit {
  ignore((self.jobs_ask.val)("models.refresh", Json::array([etag])))
}

///|
/// `stillfail update --beta|--stable` asked by SIGHUP: the updates read its channel ask.
async fn LiveBus::coord_updates_hup(self : LiveBus) -> Unit {
  ignore((self.coord_ask.val)("updates.hup", Json::null()))
}

///|
/// The machine's Claude login (accounts/index.ts `machineToken`) asked of the accounts by `ask` (the bus's `jobs_ask`, a
/// harness's own), renewed where `rejected` is the one it gave before: `{token, expiresAt}`, null where none answers.
async fn asked_machine_token(ask : async (String, Json) -> Json, rejected~ : String?) -> Json {
  ask("accounts.machineToken", { "rejected": jopt(rejected) })
}

///|
/// A subscription profile's Claude login (accounts/index.ts `claudeToken`), asked so.
async fn asked_subscription_token(
  ask : async (String, Json) -> Json,
  profile : Json,
  rejected~ : String?,
) -> Json {
  ask("accounts.claudeToken", { "profile": profile, "rejected": jopt(rejected) })
}

///|
/// The Claude login another station lent a profile (sharing `lendClaude`), asked so.
async fn asked_lent_token(ask : async (String, Json) -> Json, profile : Json, rejected~ : String?) -> Json {
  ask("sharing.lendClaude", { "profile": profile, "rejected": jopt(rejected) })
}

