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
  key : @cloud_lock.StationKey
  db : @sql.Db
  store : @store_sessions.Store
  parts : StationParts
  stopped : @effect.Deferred[String]
  /// Resolved to `http://127.0.0.1:<port>/mcp` once the previous station released `run/hub.json` and the agents' door is listening.
  door_ready : @effect.Deferred[String]
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
  let wait_prev = async fn() -> Unit {
    while held_by_hub(data) is Some(_) && !stopped.is_done() {
      @effect.sleep(100)
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
  {
    host,
    argv0,
    args,
    data,
    app,
    version,
    key,
    db,
    store,
    parts,
    stopped,
    door_ready: @effect.Deferred::new(),
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
  }
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
