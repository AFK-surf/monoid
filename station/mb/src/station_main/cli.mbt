// The station's commands other than `run` (station/src/cli.ts and main.ts's `commandMain`), as the program runs them
// itself with no Node: enroll, status, id, lock, channel, update, heap. Their output is what people and `bin/stillfail`
// read, so its words are the catalog's (words.mbt), as the TypeScript says them, and its exit codes are its.

///|
/// Flags that take a value: what follows them is no command's argument.
let valued : Array[String] = ["--data", "--provider", "--lock", "--rig", "--workspace"]

///|
let usage_text : String = "usage: stillfail-station run --app DIR [--port N] [--data DIR] | enroll <cloud> <token> [--provider stillfail|comma] [--lock HASH] [--rig HASH] [--join | --stay] | status | id | channel [stable|beta] | update [--beta|--stable] --app DIR | lock status | lock reset [--workspace ID] | heap"

///|
/// `--flag`: one of the command line's flags (a word of lowercase letters and dashes), not a value (files.ts `isFlag`).
fn is_flag(a : String) -> Bool {
  guard a.length() >= 3 && a.length() <= 26 && a.has_prefix("--") else { false }
  let first = a.unsafe_charcode_at(2)
  guard first >= 'a' && first <= 'z' else { false }
  for i = 3; i < a.length(); i = i + 1 {
    let c = a.unsafe_charcode_at(i)
    if !((c >= 'a' && c <= 'z') || c == '-') {
      return false
    }
  }
  true
}

///|
/// What a command is given besides its flags (each of `valued` with its value): in order, the command first.
pub fn positionals(args : Array[String], valued : Array[String]) -> Array[String] {
  let out = []
  let mut i = 0
  while i < args.length() {
    let a = args[i]
    if a == "--" {
      for k = i + 1; k < args.length(); k = k + 1 {
        out.push(args[k])
      }
      break
    }
    if !is_flag(a) {
      out.push(a)
    } else if valued.contains(a) {
      i += 1
    }
    i += 1
  }
  out
}

///|
/// The value after `name` in argv, wherever it is.
pub fn flag(args : Array[String], name : String) -> String? {
  match args.search(name) {
    Some(at) if at + 1 < args.length() => Some(args[at + 1])
    _ => None
  }
}

///|
/// The data directory: `--data`, else $STILLFAIL_DATA, else ~/.stillfail.
pub fn data_dir(args : Array[String]) -> String {
  match args.search("--data") {
    Some(at) if at + 1 < args.length() && args[at + 1] != "" => return args[at + 1]
    _ => ()
  }
  match env_get("STILLFAIL_DATA") {
    Some(d) if d != "" => d
    _ => @nodepath.join(sep(), [homedir(), ".stillfail"])
  }
}

///|
/// The command: the first argument that is not a flag nor a flag's value (main.ts `command`).
pub fn command_of(args : Array[String]) -> String? {
  for i, a in args {
    if !a.has_prefix("--") && !(i > 0 && args[i - 1].has_prefix("--") && args[i - 1] != "--with-parent") {
      return Some(a)
    }
  }
  None
}

///|
pub fn sep() -> String {
  if is_windows() {
    "\\"
  } else {
    "/"
  }
}

///|
fn path(parts : Array[String]) -> String {
  @nodepath.join(sep(), parts)
}

///|
fn read_text(p : String) -> String? {
  match attempt(() => @drive.read_all(p)) {
    Ok(b) => Some(@utf8.decode_lossy(b))
    Err(_) => None
  }
}

///|
fn read_json(p : String) -> Json? {
  guard read_text(p) is Some(t) else { None }
  attempt(() => @json.parse(t)).to_option()
}

///|
/// config.json's path: $STILLFAIL_CONFIG, else `<data>/config.json`.
pub fn config_path(data : String) -> String {
  match env_get("STILLFAIL_CONFIG") {
    Some(c) if c != "" => c
    _ => path([data, "config.json"])
  }
}

///|
/// The station's language on this machine (config.json `language`).
pub fn station_lang(data : String) -> String {
  match read_json(config_path(data)) {
    Some({ "language": String(l), .. }) => lang_of(Some(l))
    _ => "zh"
  }
}

///|
/// An instant as JavaScript's `toISOString` says it (ms since 1970, UTC).
pub fn iso_time(ms : Double) -> String {
  @time.format_iso_ms(ms.floor().to_int64())
}

// ── id ──

///|
/// `id`: the station's id (its key's public half, hex), the key made where there is none.
pub async fn cmd_id(host : @host.Host, data : String) -> Int {
  let key = @cloud_lock.load_key(host, data)
  out_write(key.id + "\n")
  0
}

// ── lock ──

///|
/// `lock status` / `lock reset [--workspace ID]` (cli.ts `lockCommand`).
pub fn lock_command(host : @host.Host, data : String, what : String, workspace : String?) -> String {
  let lang = station_lang(data)
  let say = (key : String, args : Array[(String, String)]) => tr(lang, key, args~)
  let disk : @cloud_lock.Disk = { host, }
  let home = match (try { @cloud_lock.read_state(disk, data) } catch { _ => None }) {
    Some(s) => Some(s.text("workspace"))
    None => None
  }
  let now_secs = (wall_ms() / 1000L).to_double()
  if what == "reset" && workspace is Some(ws) && Some(ws) != home {
    return say(
      if reset_joined_lock(disk, data, ws, now_secs) { "station.cli.lock.resetWorkspace" } else { "station.cli.lock.noneWorkspace" },
      [("workspace", ws)],
    )
  }
  if what == "reset" {
    return say(
      if @cloud_lock.reset_lock(disk, data, now_secs) { "station.cli.lock.reset" } else { "station.cli.lock.none" },
      [],
    )
  }
  guard @cloud_lock.read_lock(disk, @cloud_lock.Crypto::of_host(host), data, None) is Some(lock) else {
    return say("station.cli.lock.none", [])
  }
  guard lock.state is Some(s) else { return say("station.cli.lock.broken", []) }
  let head = if s.head.length() > 16 { s.head[:16].to_owned() } else { s.head }
  let status = say("station.cli.lock.status", [
    ("seq", js_number_text(s.seq)),
    ("hash", head),
    ("members", s.members.length().to_string()),
    ("devices", s.devices.length().to_string()),
    ("stations", s.stations.length().to_string()),
  ])
  if lock.aside.length() == 0 {
    status
  } else {
    status + say("station.cli.lock.aside", [("n", lock.aside.length().to_string())])
  }
}

///|
/// A number as JavaScript's `String(n)` says one that is whole.
fn js_number_text(n : Double) -> String {
  if n == n.floor() && n.abs() < 1.0e15 {
    n.to_int64().to_string()
  } else {
    n.to_string()
  }
}

///|
/// cli.ts `resetJoinedLock`.
fn reset_joined_lock(disk : @cloud_lock.Disk, data : String, ws : String, now_secs : Double) -> Bool {
  let lock = @cloud_lock.joined_lock_path(data, ws)
  let pending = @cloud_lock.joined_pending_path(data, ws)
  let had = disk.exists(lock) || disk.exists(pending)
  if disk.exists(lock) {
    ignore(attempt(() => disk.rename(lock, "\{lock}.reset-\{now_secs.to_int64()}")))
  }
  disk.remove(pending)
  had
}

// ── status ──

///|
/// What health.json says, where it reads as such (ops/health.ts `healthOf`): its pid, when, its front, whether online,
/// whether a relay holds its endpoint for another.
priv struct Health {
  pid : Int
  updated_at : Double
  front : String
  relay_conflict : Bool
  /// Its open descriptors and resident memory (none from a release from before it said them).
  open_fds : Int?
  rss_bytes : Double?
}

///|
fn health_of(v : Json?) -> Health? {
  guard v is Some(Object(h)) else { None }
  guard h.get("pid") is Some(Number(pid, ..)) && pid == pid.floor() else { None }
  guard h.get("updatedAt") is Some(Number(at, ..)) else { None }
  guard h.get("front") is Some(String(front)) && ["ok", "reconnecting", "direct"].contains(front) else { None }
  let open_fds = match h.get("openFds") {
    Some(Number(n, ..)) if n >= 0.0 && n == n.floor() => Some(n.to_int())
    _ => None
  }
  let rss_bytes = match h.get("rssBytes") {
    Some(Number(n, ..)) if n >= 0.0 => Some(n)
    _ => None
  }
  Some({ pid: pid.to_int(), updated_at: at, front, relay_conflict: h.get("relayConflict") is Some(True), open_fds, rss_bytes })
}

///|
/// How long what health.json says stays the word of a process that runs its loop (HEALTH_FRESH_MS).
let health_fresh_ms : Double = 60000.0

///|
fn alive_pid(v : Json?) -> Int? {
  match v {
    Some(Number(p, ..)) if p == p.floor() && p > 0.0 && pid_alive(p.to_int()) => Some(p.to_int())
    _ => None
  }
}

///|
/// `status` (cli.ts `status`): where the station is, running or not, its workspace, online or why not, how it works.
pub fn status_text(host : @host.Host, data : String, now : Double) -> String {
  let lang = station_lang(data)
  let say = (key : String, args : Array[(String, String)]) => tr(lang, key, args~)
  let when = (secs : Double) => iso_time(secs * 1000.0)
  let station = read_json(path([data, "run", "station.json"]))
  let running = match station {
    Some(Object(s)) => if alive_pid(s.get("pid")) is Some(_) { Some(s) } else { None }
    _ => None
  }
  let out = [say("station.cli.status.data", [("path", data)])]
  match running {
    Some(s) =>
      out.push(
        say("station.cli.status.running", [
          ("pid", js_number_text(match s.get("pid") { Some(Number(p, ..)) => p; _ => 0.0 })),
          ("version", match s.get("version") { Some(String(v)) => v; _ => "?" }),
        ]),
      )
    None => out.push(say("station.cli.status.notRunning", []))
  }
  let join_ = say("station.cli.status.join", [])
  let disk : @cloud_lock.Disk = { host, }
  let state = if disk.exists(path([data, "mesh", "cloud.json"])) {
    try { @cloud_lock.read_state(disk, data) } catch { _ => None }
  } else {
    None
  }
  guard state is Some(st) else {
    out.push(say("station.cli.status.noWorkspace", []))
    out.push(say("station.cli.status.idleUnjoined", [("join", join_)]))
    return out.join("\n")
  }
  out.push(say("station.cli.status.workspace", [("name", st.text("workspace_name")), ("id", st.text("workspace"))]))
  let station_id = st.text("station")
  out.push(say("station.cli.status.name", [("name", st.text("name")), ("id", if station_id.length() > 12 { station_id[:12].to_owned() } else { station_id })]))
  match st.get("rig") {
    Some(Object(rig)) => {
      let owner = match (rig.get("owner_email"), rig.get("owner")) {
        (Some(String(e)), _) if e != "" => e
        (_, Some(String(o))) => o
        _ => ""
      }
      let person = match rig.get("person") {
        Some(String(p)) => if p.length() > 16 { p[:16].to_owned() } else { p }
        _ => ""
      }
      out.push(say("station.cli.rig.status", [("owner", owner), ("person", person)]))
    }
    _ => ()
  }
  out.push(say("station.cli.status.cloud", [("origin", st.text("origin"))]))
  if @cloud_lock.read_lock(disk, @cloud_lock.Crypto::of_host(host), data, None) is Some(_) {
    out.push(lock_command(host, data, "status", None))
  }
  let removed_at = opt_num(st.get("removed_at"))
  match removed_at {
    Some(at) => {
      let how = match st.get("removed_code") {
        Some(Number(4004.0, ..)) => say("station.cli.status.removedOnClose", [])
        Some(Number(404.0, ..)) => say("station.cli.status.removedOn404", [])
        Some(Number(c, ..)) => say("station.cli.status.removedCode", [("code", js_number_text(c))])
        _ => ""
      }
      out.push(say("station.cli.status.removed", [("workspace", st.text("workspace_name")), ("at", when(at)), ("how", how)]))
      out.push(say("station.cli.status.idleRemoved", [("join", join_)]))
    }
    None => ()
  }
  let presence = if running is Some(_) { read_json(path([data, "run", "presence.json"])) } else { None }
  let online = presence is Some({ "online": True, .. })
  match presence {
    Some(Object(p)) if online =>
      out.push(
        say("station.cli.status.onlineSince", [
          ("at", match p.get("at") { Some(Number(a, ..)) if a == a.floor() => when(a); _ => "" }),
        ]),
      )
    Some(Object(p)) =>
      out.push(
        say("station.cli.status.offlineWhy", [
          ("why", match p.get("error") { Some(String(e)) => e; _ => say("station.cli.status.notConnectedYet", []) }),
        ]),
      )
    Some(_) => out.push(say("station.cli.status.offlineWhy", [("why", say("station.cli.status.notConnectedYet", []))]))
    None =>
      if running is None {
        out.push(say("station.cli.status.offlineNotRunning", []))
      } else {
        out.push(say("station.cli.status.offline", []))
      }
  }
  if removed_at is None {
    let health = if running is Some(_) { health_of(read_json(path([data, "run", "health.json"]))) } else { None }
    let health_alive = match health {
      Some(h) => pid_alive(h.pid)
      None => false
    }
    let conflict = presence is Some({ "conflict": True, .. })
    let rig = st.get("rig") is Some(Object(_))
    let line = if running is None {
      say("station.cli.status.stopped", [])
    } else {
      match health {
        Some(h) if health_alive && now - h.updated_at > health_fresh_ms =>
          say("station.cli.status.unresponsive", [("secs", ((now - h.updated_at) / 1000.0).round().to_int().to_string())])
        Some(h) if health_alive && h.front == "reconnecting" => say("station.cli.status.frontDown", [])
        Some(h) if health_alive && h.relay_conflict => say("station.cli.status.keyConflict", [])
        _ =>
          if conflict {
            say("station.cli.status.keyConflict", [])
          } else if !online {
            say("station.cli.status.limited", [])
          } else {
            say(if rig { "station.cli.rig.working" } else { "station.cli.status.working" }, [])
          }
      }
    }
    out.push(line)
  }
  out.join("\n")
}

// ── heap ──

///|
/// `heap` (ops/heap.ts `heapCommand`): asks the running station for a snapshot of its memory (the program's: what it
/// holds, as JSON, there being no V8 heap to write) and says where it was written. 1 where none answered.
pub async fn cmd_heap(data : String) -> Int {
  let dir = path([data, "run"])
  ignore(attempt(() => @drive.mkdir(dir, true)))
  let answer = path([dir, "heap.answer"])
  @drive.rm_force(answer)
  let request = path([dir, "heap.request"])
  ignore(attempt(() => @drive.write_private(request, "{}")))
  let started = wall_ms()
  // timer: a deadline of a request to another process (the station), looked at until it answers
  while (wall_ms() - started).to_double() < 120000.0 {
    match read_json(answer) {
      Some({ "path": String(p), .. }) => {
        @drive.rm_force(answer)
        out_write(p + "\n")
        return 0
      }
      Some({ "error": String(e), .. }) => {
        @drive.rm_force(answer)
        err_write("Error: \{e}\n")
        return 1
      }
      _ => ()
    }
    @effect.sleep(250)
  }
  @drive.rm_force(request)
  err_write(tr(station_lang(data), "station.cli.noAnswer", args=[]) + "\n")
  1
}

///|
/// The station's side of `heap`: a request waiting in `<data>/run` claimed and answered with what this program holds
/// (`what`), written beside it (`heap-<time>.json`, 0600, only the latest kept). Whether one was.
pub fn answer_heap_request(data : String, what : () -> Json) -> Bool {
  let dir = path([data, "run"])
  let claimed = path([dir, "heap.request.\{@drive.pid()}"])
  guard attempt(() => @drive.rename(path([dir, "heap.request"]), claimed)) is Ok(_) else { return false }
  @drive.rm_force(claimed)
  for name in attempt(() => @drive.names(dir)).unwrap_or([]) {
    if name.has_prefix("heap-") && (name.has_suffix(".heapsnapshot") || name.has_suffix(".json")) {
      @drive.rm_force(path([dir, name]))
    }
  }
  let started = wall_ms()
  let stamp = iso_time(started.to_double()).replace_all(old=":", new="-").replace_all(old=".", new="-")
  let file = path([dir, "heap-\{stamp}.json"])
  let text = what().stringify()
  let answer : Json = match attempt(() => @drive.write_private(file, text)) {
    Ok(_) =>
      {
        "path": Json::string(file),
        "bytes": Json::number(@utf8.encode(text).length().to_double()),
        "ms": Json::number((wall_ms() - started).to_double()),
      }
    Err(e) => { "error": Json::string("\{e}") }
  }
  ignore(attempt(() => @drive.write_private(path([dir, "heap.answer"]), answer.stringify())))
  true
}

// ── channel and update ──

///|
/// The updates' world on this machine with no Node (updates/world.mbt's, what it asks of Node answered here).
pub fn updates_world(host : @host.Host, data : String) -> @updates.World {
  let config_raw = () => read_json(config_path(data)).unwrap_or(Json::object({}))
  let config_update = async fn(next : Json) {
    let text = next.stringify(indent=2) + "\n"
    ignore(attempt(() => @drive.mkdir(@nodepath.dirname(sep(), config_path(data)), true)))
    @drive.write_private(config_path(data), text)
  }
  let tell = (name : String, a : Array[@jsjson.JValue]) => match name {
    "console.log" => if a.length() > 0 { out_write(js_text(a[0]) + "\n") }
    "console.error" => if a.length() > 0 { err_write(js_text(a[0]) + "\n") }
    _ => ignore(updates_platform_told(name, a.map(of_jv)))
  }
  build_updates_world(host, data, config_raw, config_update, tell~)
}

///|
/// An error as node's with its `code`.
fn coded(code : String, message : String) -> Error {
  @updates.thrown("Error", message, more=[("code", to_jv(Json::string(code)))])
}

///|
fn js_text(v : @jsjson.JValue) -> String {
  match of_jv(v) {
    String(s) => s
    other => other.stringify()
  }
}

///|
/// The updates' parts set up for this machine: their words and language, its paths and Node (none: this program).
pub fn updates_setup(data : String, argv0 : String, app? : String = "") -> Unit {
  updates_runner_from.val = (app, argv0, data)
  updates_runner.val = None
  let (zh, en) = catalogs_json()
  @updates.set_words(zh, en)
  @updates.set_station_lang(station_lang(data))
  @updates.set_path_sep(sep())
  @updates.set_env_release_keys(env_get("STILLFAIL_RELEASE_KEYS"))
  @updates.set_process(env_get("STILLFAIL_CONFIG"), @drive.pid())
  @updates.set_machine(
    @updates.Machine::of(
      build_os=Some(platform()),
      arch=Some(arch()),
      windows=is_windows(),
      cwd=@drive.cwd(),
      exec_path=argv0,
      applier="",
    ),
  )
}

///|
/// `channel [stable|beta]`.
pub async fn cmd_channel(host : @host.Host, args : Array[String], data : String, argv0 : String) -> Int {
  updates_setup(data, argv0)
  @updates.channel_command(updates_world(host, data), args, data)
}

///|
/// `update [--beta|--stable] --app DIR` and the applier `update --apply-delta`.
pub async fn cmd_update(host : @host.Host, args : Array[String], data : String, argv0 : String) -> Int {
  updates_setup(data, argv0)
  @updates.update_command(updates_world(host, data), args, data, None, async fn(_raw) {
    raise SysError("an APK's deflate is not this program's")
  })
}

// ── enroll ──

///|
/// cli.ts `enroll` and `joinWorkspace`: redeems a one-time token (enroll, or join with `--join`/`--stay` where the
/// station is in a workspace), proving it holds its key, and writes what the control plane said.
pub async fn cmd_enroll(host : @host.Host, args : Array[String], data : String, argv0 : String) -> Int {
  let lang = station_lang(data)
  let pos = positionals(args, valued)
  let origin = if pos.length() > 1 { pos[1] } else { "" }
  let token = if pos.length() > 2 { pos[2] } else { "" }
  let provider = flag(args, "--provider").unwrap_or("stillfail")
  let lock = flag(args, "--lock")
  let rig = flag(args, "--rig")
  let hex64 = (s : String?) => match s {
    None => true
    Some(h) => h.length() == 64 && h.iter().all(c => (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f'))
  }
  if origin == "" || token == "" || !["stillfail", "comma"].contains(provider) || !hex64(lock) || !hex64(rig) {
    err_write(usage_text + "\n")
    return 2
  }
  let mut origin = origin
  while origin.has_suffix("/") {
    origin = origin[:origin.length() - 1].to_owned()
  }
  let disk : @cloud_lock.Disk = { host, }
  let state = try { @cloud_lock.read_state(disk, data) } catch { _ => None }
  let in_one = match state {
    Some(s) => s.text("workspace") != "" && s.get("removed_at") is (None | Some(Null))
    None => false
  }
  let is_rig = in_one && state.map(s => s.get("rig") is Some(Object(_))).unwrap_or(false)
  let stay = rig is None && !is_rig && !args.contains("--join") && args.contains("--stay") && in_one
  let key = @cloud_lock.load_key(host, data) catch {
    e => {
      err_write("\{e}\n")
      return 1
    }
  }
  // (cloud/provider.ts: each control plane's paths and the prefix its proof is signed under)
  let (plane_name, enroll_path, join_path, prefixes) = if provider == "comma" {
    ("Comma", "/v1/comma/stations/enroll", "/v1/comma/stations/join", ["comma"])
  } else {
    ("still.fail cloud", "/v1/stations/enroll", "/v1/stations/join", ["stillfail"])
  }
  let joining = rig is None && (args.contains("--join") || stay)
  if joining {
    if !in_one {
      err_write("Error: this station is in no workspace: enroll it first\n")
      return 1
    }
    let now_origin = state.map(s => s.text("origin")).unwrap_or("")
    if !stay && now_origin != origin {
      err_write("this station is enrolled at \{now_origin}; it joins workspaces there only\n")
      return 1
    }
    origin = now_origin
  }
  if !joining && state is Some(s) && in_one && (s.get("rig") is Some(Object(_))) != (rig is Some(_)) {
    let ws = if s.text("workspace_name") != "" { s.text("workspace_name") } else { s.text("workspace") }
    err_write(
      "Error: " +
      tr(lang, if s.get("rig") is Some(Object(_)) { "station.cli.rig.isRig" } else { "station.cli.rig.isStation" }, args=[("workspace", ws)]) +
      "\n",
    )
    return 1
  }
  let at = if joining { join_path } else { enroll_path }
  let body = redeem(host, key, origin, token, plane_name, at, prefixes, station_version(args, argv0), locks=joining, rig=rig is Some(_)) catch {
    Failure(m) => {
      err_write("Error: \{m}\n")
      return 1
    }
  }
  let field = (k : String) => match body {
    Object(m) =>
      opt_str(m.get(k)).unwrap_or("")
    _ => ""
  }
  let id12 = key.id[:12].to_owned()
  if joining {
    let ws = field("workspace")
    if ws == "" {
      err_write("Error: \{plane_name} did not say which workspace was joined\n")
      return 1
    }
    guard state is Some(s) else { return 1 }
    if ws != s.text("workspace") {
      let joined = match s.get("joined") {
        Some(Array(xs)) => xs
        _ => []
      }
      if !joined.iter().any(j => j is { "workspace": String(w), .. } && w == ws) {
        joined.push({
          "workspace": Json::string(ws),
          "workspace_name": Json::string(field("workspace_name")),
          "name": Json::string(field("name")),
          "peers": Json::array([]),
          "revocations": Json::array([]),
        })
        s.fields["joined"] = Json::array(joined)
        @cloud_lock.write_state(disk, data, s) catch {
          e => {
            err_write("Error: \{e}\n")
            return 1
          }
        }
      }
      match lock {
        Some(h) => {
          disk.mkdir(@cloud_lock.dirname(@cloud_lock.joined_pending_path(data, ws)))
          ignore(attempt(() => disk.write(@cloud_lock.joined_pending_path(data, ws), ({ "hash": Json::string(h) } : Json).stringify())))
        }
        None => ()
      }
    }
    out_write(tr(lang, "station.cli.joined", args=[("workspace", field("workspace_name")), ("name", field("name")), ("id", id12)]) + "\n")
    if lock is Some(_) {
      out_write(tr(lang, "station.cli.lock.pending", args=[("code", short_code(key.id))]) + "\n")
    }
    return 0
  }
  let relays = match body {
    Object(m) =>
      match m.get("relay_urls") {
        Some(Array(xs)) => xs.filter(x => x is String(_))
        _ => []
      }
    _ => []
  }
  let relay_url = match field("relay_url") {
    "" =>
      if provider == "comma" && relays.length() > 0 {
        as_text(relays[0]).unwrap_or("")
      } else {
        ""
      }
    r => r
  }
  let grant_keys = match body {
    Object(m) => m.get("grant_keys").unwrap_or(Json::null())
    _ => Json::null()
  }
  let fields : Map[String, Json] = {
    "origin": Json::string(origin),
    "station": Json::string(key.id),
    "workspace": Json::string(field("workspace")),
    "workspace_name": Json::string(field("workspace_name")),
    "name": Json::string(field("name")),
    "relay_url": Json::string(relay_url),
    "relay_urls": Json::array(relays),
    "grant_keys": grant_keys,
    "peers": Json::array([]),
    "revocations": Json::array([]),
  }
  if provider != "stillfail" {
    fields["provider"] = Json::string(provider)
    fields["gateway_keys"] = match body {
      Object(m) =>
        match m.get("gateway_keys") {
          Some(Array(xs)) => Json::array(xs.filter(x => x is String(_)))
          _ => Json::array([])
        }
      _ => Json::array([])
    }
  }
  match rig {
    Some(person) => {
      let r = match body {
        Object(m) => m.get("rig")
        _ => None
      }
      let rf = (k : String) => match r {
        Some(Object(o)) =>
          opt_str(o.get(k)).unwrap_or("")
        _ => ""
      }
      if rf("owner") == "" {
        err_write("Error: \{plane_name} did not say whose rig this is\n")
        return 1
      }
      fields["rig"] = {
        "owner": Json::string(rf("owner")),
        "owner_email": Json::string(rf("owner_email")),
        "owner_name": Json::string(rf("owner_name")),
        "person": Json::string(person),
      }
    }
    None => ()
  }
  @cloud_lock.write_state(disk, data, { fields, }) catch {
    e => {
      err_write("Error: \{e}\n")
      return 1
    }
  }
  if disk.exists(@cloud_lock.lock_path(data)) {
    ignore(@cloud_lock.reset_lock(disk, data, (wall_ms() / 1000L).to_double()))
  }
  disk.remove(@cloud_lock.pending_lock_path(data))
  match lock {
    Some(h) => ignore(attempt(() => disk.write(@cloud_lock.pending_lock_path(data), ({ "hash": Json::string(h) } : Json).stringify())))
    None => ()
  }
  match fields.get("rig") {
    Some(Object(r)) => {
      let owner = match (r.get("owner_email"), r.get("owner")) {
        (Some(String(e)), _) if e != "" => e
        (_, Some(String(o))) => o
        _ => ""
      }
      out_write(tr(lang, "station.cli.rig.joined", args=[("workspace", field("workspace_name")), ("name", field("name")), ("id", id12), ("owner", owner)]) + "\n")
    }
    _ => out_write(tr(lang, "station.cli.joined", args=[("workspace", field("workspace_name")), ("name", field("name")), ("id", id12)]) + "\n")
  }
  if lock is Some(_) {
    out_write(
      tr(lang, if rig is Some(_) { "station.cli.rig.pending" } else { "station.cli.lock.pending" }, args=[("code", short_code(key.id))]) +
      "\n",
    )
  }
  0
}

///|
/// cli.ts `redeem`: a one-time token redeemed at `at` (enroll or join), proving this station holds its key; the
/// control plane's answer. Each prefix its proof may be signed under is tried while the plane says the signature is not
/// its (cloud/provider.ts).
async fn redeem(
  host : @host.Host,
  key : @cloud_lock.StationKey,
  origin : String,
  token : String,
  plane_name : String,
  at : String,
  prefixes : Array[String],
  version : String,
  locks~ : Bool,
  rig~ : Bool,
) -> Json raise Failure {
  let mut answered : (Int, String) = (0, "")
  for prefix in prefixes {
    let signature = key.sign("\{prefix}-station-enroll-v1:\{origin}:\{token}:\{key.id}") catch {
      e => fail("\{e}")
    }
    let fields : Map[String, Json] = {
      "token": Json::string(token),
      "station": Json::string(key.id),
      "signature": Json::string(signature),
      "version": Json::string(version),
    }
    if locks {
      fields["locks"] = Json::boolean(true)
    }
    if rig {
      fields["rig"] = Json::boolean(true)
    }
    let r = host.fetch(
      origin + at,
      method_="POST",
      headers=[("content-type", "application/json")],
      body=@utf8.encode(Json::object(fields).stringify()),
    ) catch {
      e => fail("\{plane_name} did not answer: \{e}")
    }
    let status = r.status
    answered = (status, r.text())
    if prefix == prefixes[prefixes.length() - 1] || status != 401 {
      break
    }
    if !answered.1.contains("invalid_signature") {
      fail("\{plane_name} answered \{status}: \{answered.1}")
    }
  }
  let (status, text) = answered
  if status < 200 || status >= 300 {
    fail("\{plane_name} answered \{status}: \{text}")
  }
  attempt(() => @json.parse(text)).unwrap_or(Json::object({}))
}

///|
/// What a join asked over the mesh refused or did (cli.ts `KeptLock` among them: joined, the lock kept there for that
/// workspace left as it is), as the admin API's route throws it.
pub(all) suberror JoinRefused {
  JoinRefused(String, String)
}

///|
/// Its words where it is said (`to_string`, a notice, a log): not its type's name (`station/<package>.<Type>`).
pub impl Show for JoinRefused with output(self, logger) {
  match self {
    JoinRefused(_, m) => logger.write_string(m)
  }
}

///|
/// cli.ts `joinWorkspace` asked over the mesh (POST /workspaces/join): one more workspace joined with its one-time
/// token, staying in those the station is in, kept in cloud.json's `joined` at once. A locked home joins only a
/// workspace whose lock is named (`lock`); a lock kept here for that workspace that does not hold it stays, and the join
/// says so once done (`KeptLock`). `home_locked`: whether the home's lock is on as the running station reads it
/// (Cloud.locked, for a chain that moved).
pub async fn join_workspace(
  host : @host.Host,
  data : String,
  token : String,
  lock : String?,
  version : String,
  home_locked : () -> Bool,
) -> Json raise {
  let lang = station_lang(data)
  let disk : @cloud_lock.Disk = { host, }
  let state = @cloud_lock.read_state(disk, data) catch { _ => None }
  guard state is Some(s) && s.text("workspace") != "" && s.get("removed_at") is (None | Some(Null)) else {
    raise JoinRefused("Error", "this station is in no workspace: enroll it first")
  }
  if s.get("rig") is Some(Object(_)) {
    let ws = if s.text("workspace_name") != "" { s.text("workspace_name") } else { s.text("workspace") }
    raise JoinRefused("Error", tr(lang, "station.cli.rig.isRig", args=[("workspace", ws)]))
  }
  let crypto = @cloud_lock.Crypto::of_host(host)
  let home = @cloud_lock.read_lock(disk, crypto, data, None)
  let on = match home {
    None => false
    Some({ state: Some(st), .. }) => !st.disabled && (st.moved is None || home_locked())
    Some(_) => true
  }
  if on && lock is None {
    raise JoinRefused("Error", "this station's workspace is locked: it joins only a workspace with a lock of its own")
  }
  let provider = s.text("provider")
  let (plane_name, join_path, prefixes) = if provider == "comma" {
    ("Comma", "/v1/comma/stations/join", ["comma"])
  } else {
    ("still.fail cloud", "/v1/stations/join", ["stillfail"])
  }
  let key = @cloud_lock.load_key(host, data)
  let body = redeem(host, key, s.text("origin"), token, plane_name, join_path, prefixes, version, locks=true, rig=false)
  let field = (k : String) => match body {
    Object(m) =>
      opt_str(m.get(k)).unwrap_or("")
    _ => ""
  }
  let ws = field("workspace")
  if ws == "" {
    raise JoinRefused("Error", "\{plane_name} did not say which workspace was joined")
  }
  // nameJoinedLock asked over the mesh: pinned once the plane brings a lock holding it; one kept here that does not stays.
  let named = match lock {
    Some(h) if ws != s.text("workspace") => {
      let kept = @cloud_lock.read_lock(disk, crypto, data, Some(ws))
      match kept {
        Some(k) if k.entries.iter().any(e => (try { @cloud_lock.entry_hash(e) } catch { _ => "" }) == h) => {
          disk.remove(@cloud_lock.joined_pending_path(data, ws))
          "kept"
        }
        Some(_) => "kept another"
        None => {
          disk.mkdir(@cloud_lock.dirname(@cloud_lock.joined_pending_path(data, ws)))
          disk.write(@cloud_lock.joined_pending_path(data, ws), ({ "hash": Json::string(h) } : Json).stringify())
          "pending"
        }
      }
    }
    _ => "pending"
  }
  // The plane's `state` frame may have named it already (it tells the station before it answers): that is kept.
  let now = (@cloud_lock.read_state(disk, data) catch { _ => None }).unwrap_or(s)
  if ws != now.text("workspace") {
    let joined = match now.get("joined") {
      Some(Array(xs)) => xs
      _ => []
    }
    if !joined.iter().any(j => j is { "workspace": String(w), .. } && w == ws) {
      joined.push({
        "workspace": Json::string(ws),
        "workspace_name": Json::string(field("workspace_name")),
        "name": Json::string(field("name")),
        "peers": Json::array([]),
        "revocations": Json::array([]),
      })
      now.fields["joined"] = Json::array(joined)
      @cloud_lock.write_state(disk, data, now)
    }
  }
  if named == "kept another" {
    raise JoinRefused(
      "KeptLock",
      "this station joined the workspace but keeps another security mode record for it, which it goes by there; to take the one you named, run `stillfail lock reset --workspace \{ws}` on that computer first",
    )
  }
  {
    "workspace": Json::string(ws),
    "workspace_name": Json::string(field("workspace_name")),
    "name": Json::string(field("name")),
  }
}

///|
/// cloud/lock.ts `shortCode`: what an owner confirms a station by, the first of its id in groups.
fn short_code(id : String) -> String {
  @cloud_lock.short_code(id)
}

// ── the commands ──

///|
/// Runs the command `args` names (main.ts `commandMain`, but `run`); its exit code.
pub async fn run_command(host : @host.Host, argv0 : String, args : Array[String]) -> Int {
  let data = data_dir(args)
  let usage = () => {
    err_write(usage_text + "\n")
    2
  }
  match command_of(args) {
    Some("id") => cmd_id(host, data) catch { e => { err_write("\{e}\n"); 1 } }
    Some("status") => {
      out_write(status_text(host, data, wall_ms().to_double()) + "\n")
      0
    }
    Some("lock") => {
      let pos = positionals(args, valued)
      let what = if pos.length() > 1 { pos[1] } else { "" }
      let workspace = flag(args, "--workspace")
      if (what != "status" && what != "reset") || (workspace is Some(_) && what != "reset") {
        return usage()
      }
      out_write(lock_command(host, data, what, workspace) + "\n")
      0
    }
    Some("channel") => {
      let code = cmd_channel(host, args, data, argv0)
      if code == 2 { usage() } else { code }
    }
    Some("update") => {
      let code = cmd_update(host, args, data, argv0)
      if code == 2 { usage() } else { code }
    }
    Some("heap") => cmd_heap(data)
    Some("enroll") => cmd_enroll(host, args, data, argv0)
    Some("admin") => run_admin_cli(host, argv0, args)
    _ => usage()
  }
}
