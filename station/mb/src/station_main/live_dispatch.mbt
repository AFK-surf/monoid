// Shared infrastructure dispatch and cross-slice primitives for `station_main`:
// - async FS helpers (`host_*`) and unified `fs.*` dispatch (`host_fs_op`) over `host.shell("fs.*")` (0 sync FS calls),
// - unified `store.*` / threads-store / `cardOutcomes.save` dispatch (`dispatch_store`, `dispatch_store_threads`, `dispatch_threads_card`),
// - unified `config.*` / `cloud.*` / `events.*` / `remote.ask` / `os.*` / `platform.*` / `crypto.*` / `process.*` / `log.*` / `wall.now` dispatch (`dispatch_infra`),
// - shared `@updates.World` builder (`build_updates_world`),
// - shared slice primitives (`fork_bg`, `bus_after`, `bus_pty_terminal`, `AskArgs`, `bus_*`, `run_cmd`, `process_descendants`, `env_*`, `arg_*`).

///|
priv suberror DispatchFsError {
  DispatchFsError(String, String)
}

///|
impl Show for DispatchFsError with output(self, logger) {
  match self { DispatchFsError(_, m) => logger.write_string(m) }
}

///|
fn shell_fs_code(e : Error) -> String {
  let said = said_of(e)
  let n = match said.find("(os error ") {
    Some(i) => {
      let digits = StringBuilder()
      for c in said[i + 10:] {
        if c >= '0' && c <= '9' { digits.write_char(c) } else { break }
      }
      @string.parse_int(digits.to_string()) catch { _ => -1 }
    }
    None => -1
  }
  if platform() == "win32" {
    match n { 2 | 3 | 123 => "ENOENT"; 5 | 32 | 33 => "EPERM"; 80 | 183 => "EEXIST"; 112 => "ENOSPC"; 145 => "ENOTEMPTY"; 267 => "ENOTDIR"; 17 => "EXDEV"; _ => "EIO" }
  } else {
    match n { 1 => "EPERM"; 2 => "ENOENT"; 13 => "EACCES"; 16 => "EBUSY"; 17 => "EEXIST"; 18 => "EXDEV"; 20 => "ENOTDIR"; 21 => "EISDIR"; 28 => "ENOSPC"; 39 | 66 => "ENOTEMPTY"; _ => "EIO" }
  }
}

///|
fn fs_code_said(code : String, call : String, p : String) -> String {
  let words = match code {
    "EPERM" => "operation not permitted"
    "ENOENT" => "no such file or directory"
    "EACCES" => "permission denied"
    "EBUSY" => "resource busy or locked"
    "EEXIST" => "file already exists"
    "EXDEV" => "cross-device link not permitted"
    "ENOTDIR" => "not a directory"
    "EISDIR" => "illegal operation on a directory"
    "ENOSPC" => "no space left on device"
    "ENOTEMPTY" => "directory not empty"
    _ => "i/o error"
  }
  "\{code}: \{words}, \{call} '\{p}'"
}

///|
fn dispatch_fs_shell_err(e : Error, call : String, p : String) -> DispatchFsError {
  let code = shell_fs_code(e)
  DispatchFsError(code, fs_code_said(code, call, p))
}

///|
fn dispatch_fs_missing(call : String, p : String) -> DispatchFsError {
  DispatchFsError("ENOENT", fs_code_said("ENOENT", call, p))
}

///|
fn dispatch_fs_drive_err(e : Error) -> DispatchFsError {
  match e {
    @drive.FsError(f) => DispatchFsError(f.code, f.message)
    other => DispatchFsError("", said_of(other))
  }
}

// ── async FS primitives (all off the main thread via `host.shell("fs.*")`) ──

///|
async fn host_readdir_types(host : @host.Host, dir : String) -> Array[(String, String)]? {
  let (said, _) = host.shell("fs.readdir", { "path": jstr(dir), "types": jb(true) }) catch { _ => return None }
  match said {
    Array(items) =>
      Some(items.filter_map(it => match it {
        [String(name), String(kind), ..] => Some((name, kind))
        Object(_) => Some((jtext_or_empty(it, "name"), jtext_or_empty(it, "kind")))
        String(name) => Some((name, ""))
        _ => None
      }))
    _ => None
  }
}

///|
async fn host_readdir_names(host : @host.Host, dir : String) -> Array[String]? {
  let (said, _) = host.shell("fs.readdir", { "path": jstr(dir) }) catch { _ => return None }
  match said {
    Array(items) => Some(items.filter_map(as_text))
    _ => None
  }
}

///|
async fn host_lstat(host : @host.Host, p : String) -> (String, Double, Double)? {
  let (said, _) = host.shell("fs.lstat", { "path": jstr(p) }) catch { _ => return None }
  match said {
    { "kind": String(kind), "size": Number(size, ..), "mtimeMs": Number(mtime, ..), .. } => Some((kind, size, mtime))
    _ => None
  }
}

///|
async fn host_stat_follow(host : @host.Host, p : String) -> (String, Double, Double)? {
  match host_lstat(host, p) {
    Some(("link", _, _)) =>
      match (host.shell("fs.realpath", { "path": jstr(p) }) catch { _ => return None }) {
        (String(r), _) =>
          match host_lstat(host, r) {
            Some(("link", _, _)) => None
            other => other
          }
        _ => None
      }
    other => other
  }
}

///|
async fn host_exists(host : @host.Host, p : String) -> Bool {
  match (try { Ok(host.shell("fs.stat", { "path": jstr(p) })) } catch { e => Err(e) }) {
    Ok((Null, _)) | Err(_) => false
    Ok(_) => true
  }
}

///|
async fn host_is_dir(host : @host.Host, p : String) -> Bool {
  match (try { Ok(host.shell("fs.stat", { "path": jstr(p) })) } catch { e => Err(e) }) {
    Ok((String("dir"), _)) => true
    _ => false
  }
}

///|
async fn host_mkdir(host : @host.Host, p : String, mode? : Int = 0) -> Unit {
  ignore(host.shell("fs.mkdir", { "path": jstr(p), "recursive": jb(true) })) catch {
    e => raise dispatch_fs_shell_err(e, "mkdir", p)
  }
  if mode > 0 {
    ignore(host.shell("fs.chmod", { "path": jstr(p), "mode": ji(mode) })) catch { _ => () }
  }
}

///|
async fn host_mkdir_quiet(host : @host.Host, p : String) -> Unit {
  ignore(host.shell("fs.mkdir", { "path": jstr(p), "recursive": jb(true) })) catch { _ => () }
}

///|
async fn host_rename(host : @host.Host, from : String, to : String) -> Unit {
  ignore(host.shell("fs.rename", { "from": jstr(from), "to": jstr(to) })) catch {
    e => raise dispatch_fs_shell_err(e, "rename", from)
  }
}

///|
async fn host_remove_tree(host : @host.Host, p : String) -> Unit {
  ignore(host.shell("fs.remove", { "path": jstr(p), "recursive": jb(true) })) catch { _ => () }
}

///|
async fn host_copy_over(host : @host.Host, from : String, to : String) -> Unit {
  let (kind, _) = host.shell("fs.stat", { "path": jstr(from) })
  if kind is Null { raise @wire.ShellError("No such file or directory (os error 2)") }
  if from == to { return }
  match host_lstat(host, to) {
    Some((k, _, _)) if k != "dir" => ignore(host.shell("fs.remove", { "path": jstr(to) })) catch { _ => () }
    _ => ()
  }
  ignore(host.shell("fs.copy", { "from": jstr(from), "to": jstr(to) }))
}

///|
async fn host_write_file(host : @host.Host, p : String, data : Bytes, excl? : Bool = false, mode? : Int = 0) -> Unit {
  let put : Json = { "path": jstr(p), "offset": jn(0.0), "truncate": jb(true), "exclusive": jb(excl), "mode": ji(if mode > 0 { mode } else { 0o644 }) }
  ignore(host.shell("fs.put", put, bytes=data)) catch { e => raise dispatch_fs_shell_err(e, "open", p) }
  if mode > 0 {
    ignore(host.shell("fs.chmod", { "path": jstr(p), "mode": ji(mode) })) catch { _ => () }
  }
}

///|
async fn host_append_file(host : @host.Host, p : String, data : Bytes) -> Unit {
  ignore(host.shell("fs.put", { "path": jstr(p), "mode": ji(0o644) }, bytes=data)) catch {
    e => raise dispatch_fs_shell_err(e, "open", p)
  }
}

///|
async fn host_read_bytes_req(host : @host.Host, p : String) -> Bytes {
  match (host.read_bytes(p) catch { e => raise dispatch_fs_drive_err(e) }) {
    Some(b) => b
    None =>
      if host_is_dir(host, p) {
        raise DispatchFsError("EISDIR", fs_code_said("EISDIR", "read", p))
      } else {
        raise dispatch_fs_missing("open", p)
      }
  }
}

///|
async fn host_read_text_req(host : @host.Host, p : String) -> String {
  match (host.read_text(p) catch { e => raise dispatch_fs_drive_err(e) }) {
    Some(t) => t
    None =>
      if host_is_dir(host, p) {
        raise DispatchFsError("EISDIR", fs_code_said("EISDIR", "read", p))
      } else {
        raise dispatch_fs_missing("open", p)
      }
  }
}

///|
fn dispatch_bytes_arg(args : Array[Json], i : Int) -> Bytes {
  match args.get(i) {
    Some(String(x)) => @utf8.encode(x)
    Some(Object({ "$bytes": String(b), .. })) => @base64.decode(b) catch { _ => b"" }
    _ => b""
  }
}

///|
/// Unified async `fs.*` dispatcher (op without `"fs."` prefix).
async fn host_fs_op(
  host : @host.Host,
  op : String,
  args : Array[Json],
  strict_rm? : Bool = false,
  readdir_file_field? : Bool = false,
) -> Json {
  let s = (i : Int) => arg_str(args, i)
  match op {
    "readText" | "read" | "readFile" | "readFileSync" => jstr(host_read_text_req(host, s(0)))
    "readBase64" => jstr(@drive.base64(host_read_bytes_req(host, s(0))))
    "writeFile" => {
      let (excl, mode) = match args.get(2) {
        Some(Object(o)) => (o.get("flag") is Some(String("wx" | "xw")), match o.get("mode") { Some(Number(m, ..)) => m.to_int(); _ => 0 })
        _ => (false, 0)
      }
      host_write_file(host, s(0), dispatch_bytes_arg(args, 1), excl~, mode~)
      Json::null()
    }
    "writePrivate" | "write" => {
      host.write_private(s(0), @utf8.encode(s(1)), sep=sep()) catch { e => raise dispatch_fs_shell_err(e, "open", s(0)) }
      Json::null()
    }
    "appendFile" => {
      host_append_file(host, s(0), dispatch_bytes_arg(args, 1))
      Json::null()
    }
    "access" => {
      let (kind, _) = host.shell("fs.stat", { "path": jstr(s(0)) }) catch { e => raise dispatch_fs_shell_err(e, "access", s(0)) }
      if kind is Null { raise dispatch_fs_missing("access", s(0)) }
      Json::null()
    }
    "exists" => jb(host_exists(host, s(0)))
    "statfs" =>
      match disk_of(s(0)) {
        Some((free, total)) => { "blocks": jn(total), "bavail": jn(free), "bsize": jn(1.0) }
        None => raise dispatch_fs_missing("statfs", s(0))
      }
    "rename" => { host_rename(host, s(0), s(1)); Json::null() }
    "mkdir" => { host_mkdir(host, s(0)); Json::null() }
    "rm" => {
      if strict_rm && !(args.get(1) is Some(Object({ "force": True, .. }))) && host_lstat(host, s(0)) is None {
        raise dispatch_fs_missing("lstat", s(0))
      }
      host_remove_tree(host, s(0))
      Json::null()
    }
    "copyFile" => {
      let excl = match args.get(2) { Some(Number(m, ..)) => (m.to_int() & 1) == 1; _ => false }
      if excl {
        @drive.copy_file(s(0), s(1)) catch { e => raise dispatch_fs_drive_err(e) }
      } else {
        host_copy_over(host, s(0), s(1)) catch { e => raise dispatch_fs_shell_err(e, "copyfile", s(0)) }
      }
      Json::null()
    }
    "copy" => {
      host_copy_over(host, s(0), s(1)) catch { e => raise dispatch_fs_shell_err(e, "copyfile", s(0)) }
      Json::null()
    }
    "symlink" => {
      if live_symlink_ffi(cstr(s(0)), cstr(s(1))) != 0 {
        raise DispatchFsError("EEXIST", "EEXIST: file already exists, symlink '\{s(0)}' -> '\{s(1)}'")
      }
      Json::null()
    }
    "readdir" =>
      if args.get(1) is Some(Object({ "withFileTypes": True, .. })) {
        guard host_readdir_types(host, s(0)) is Some(entries) else {
          match host_stat_follow(host, s(0)) {
            Some((k, _, _)) if k != "dir" => raise DispatchFsError("ENOTDIR", fs_code_said("ENOTDIR", "scandir", s(0)))
            _ => raise dispatch_fs_missing("scandir", s(0))
          }
        }
        Json::array(entries.map(e => if readdir_file_field {
          ({ "name": jstr(e.0), "file": jb(e.1 == "file"), "dir": jb(e.1 == "dir") } : Json)
        } else {
          ({ "name": jstr(e.0), "dir": jb(e.1 == "dir") } : Json)
        }))
      } else {
        guard host_readdir_names(host, s(0)) is Some(names) else {
          match host_stat_follow(host, s(0)) {
            Some((k, _, _)) if k != "dir" => raise DispatchFsError("ENOTDIR", fs_code_said("ENOTDIR", "scandir", s(0)))
            _ => raise dispatch_fs_missing("scandir", s(0))
          }
        }
        Json::array(names.map(Json::string))
      }
    "readdirTypes" => {
      guard host_readdir_types(host, s(0)) is Some(entries) else {
        match host_stat_follow(host, s(0)) {
          Some((k, _, _)) if k != "dir" => raise DispatchFsError("ENOTDIR", fs_code_said("ENOTDIR", "scandir", s(0)))
          _ => raise dispatch_fs_missing("scandir", s(0))
        }
      }
      Json::array(entries.map(e => ({ "name": jstr(e.0), "isFile": jb(e.1 == "file"), "isDirectory": jb(e.1 == "dir") } : Json)))
    }
    "stat" => {
      guard host_stat_follow(host, s(0)) is Some((kind, size, mtime)) else { raise dispatch_fs_missing("stat", s(0)) }
      { "isFile": jb(kind == "file"), "isDirectory": jb(kind == "dir"), "size": jn(size), "mtimeMs": jn(mtime) }
    }
    "lstat" => {
      guard host_lstat(host, s(0)) is Some((kind, size, mtime)) else { raise dispatch_fs_missing("lstat", s(0)) }
      { "isFile": jb(kind == "file"), "isDirectory": jb(kind == "dir"), "isSymbolicLink": jb(kind == "link"), "size": jn(size), "mtimeMs": jn(mtime) }
    }
    "size" => {
      guard host_stat_follow(host, s(0)) is Some((_, size, _)) else { raise dispatch_fs_missing("stat", s(0)) }
      jn(size)
    }
    "stamp" =>
      match (try { Ok(host.shell("fs.meta", { "path": jstr(s(0)) })) } catch { e => Err(e) }) {
        Ok((m, _)) => jstr("\{jnum_of(m, "size").unwrap_or(0.0)}:\{jnum_of(m, "mtimeMs").unwrap_or(0.0)}")
        Err(_) => jstr("")
      }
    "realpath" => jstr(@drive.realpath(s(0)) catch { e => raise dispatch_fs_drive_err(e) })
    "mkdtemp" => {
      let dir = path([tmpdir(), s(0) + @drive.hex(@drive.random_bytes(4))])
      host_mkdir(host, dir, mode=0o700)
      jstr(dir)
    }
    "sha256" =>
      match (host.file_sha256(s(0)) catch { e => raise dispatch_fs_drive_err(e) }) {
        Some(h) => jstr(h)
        None => raise dispatch_fs_missing("open", s(0))
      }
    "readHead" => {
      let want = as_num(arg_at(args, 1)).unwrap_or(0.0)
      let show = as_num(arg_at(args, 2)).map(n => n.to_int()).unwrap_or(want.to_int())
      let (bytes, _, _) = @drive.read_part(s(0), 0.0, want) catch { e => raise dispatch_fs_drive_err(e) }
      let cut = if bytes.length() < show { bytes.length() } else { show }
      { "text": jstr(@utf8.decode_lossy(bytes[0:cut].to_owned())), "got": ji(bytes.length()) }
    }
    _ => raise DispatchFsError("", "no fs op \{op}")
  }
}

// ── unified `store.*` & threads-store dispatch ──

///|
fn dispatch_store(bus : LiveBus, name : String, args : Array[Json]) -> Json raise {
  match name {
    "now" => jn(bus.store.now().to_double())
    // (session_storage cold.mbt `pack_history`, `finish_legacy_copies`: `store.archiveDir` through P52::storage_call)
    "archiveDir" => jstr(path([bus.data, "archive"]))
    "told" => {
      match arg_at(args, 0) { Array(changes) => bus.store.told(changes); c => bus.store.told([c]) }
      Json::null()
    }
    "threadSessions" => {
      let rows = bus.db.all("SELECT * FROM thread_sessions WHERE thread = ? ORDER BY joined_at, rowid", [arg_at(args, 0)])
      Json::array(rows.map(r => {
        let c = (k : String) => r.get(k).unwrap_or(Json::null())
        ({ "thread": c("thread"), "session": c("session"), "connect": c("connect"), "joinedAt": c("joined_at"), "leftAt": c("left_at") } : Json)
      }))
    }
    "getThread" =>
      match bus.db.all("SELECT * FROM threads WHERE id = ?", [arg_at(args, 0)]) {
        [r, ..] => {
          let c = (k : String) => r.get(k).unwrap_or(Json::null())
          { "id": c("id"), "surface": c("surface"), "channel": c("channel"), "threadTs": c("thread_ts"), "title": c("title"), "autoTitle": c("auto_title"), "createdBy": c("created_by"), "createdAt": c("created_at"), "home": c("home"), "hiddenAt": c("hidden_at"), "hiddenBy": c("hidden_by"), "shownAt": c("shown_at") }
        }
        _ => Json::null()
      }
    _ => bus.store.call(name, args)
  }
}

///|
fn dispatch_store_threads(bus : LiveBus, threads : @store_threads.Store, name : String, args : Array[Json]) -> Json raise {
  threads.set_now(wall_ms().to_double())
  match (try { Ok(dispatch_store(bus, name, args)) } catch { e => Err(e) }) {
    Ok(v) => v
    Err(e) =>
      if said_of(e).contains("no call") {
        let given = args.map(a => match a {
          Object(m) if m.length() == 1 && (m.contains("$u") || m.contains("$undef") || m.contains("$undefined")) => Json::null()
          a => a
        })
        errdefer told_threads(bus, threads)
        let answer = threads.call(name, given.map(to_jv))
        told_threads(bus, threads)
        answer
      } else {
        raise e
      }
  }
}

///|
async fn dispatch_threads_card(
  bus : LiveBus,
  threads : @store_threads.Store,
  name : String,
  args : Array[Json],
  run_cb : async (Json, Array[Json]) -> Json?,
) -> Json? {
  let a = (i : Int) => arg_at(args, i)
  match name {
    "store.starter" => Some(threads.starter(a(0)))
    "store.firstText" => Some(threads.first_text(a(0)))
    "store.latestThread" => { let v = threads.latest_thread(a(0)); bus.drain_thread_requests(threads); Some(v) }
    "store.latestThreadIfReady" => { let v = threads.latest_thread_if_ready(a(0)); bus.drain_thread_requests(threads); Some(v) }
    "store.sessionThreadById" => Some(threads.session_thread_by_id(a(0), a(1)))
    "store.pendingCardHeader" => Some(threads.pending_card_header(a(0)))
    "store.pendingCardHeaderIfReady" => Some(threads.pending_card_header_if_ready(a(0)))
    "store.insertMessage" => {
      ignore(run_cb(a(1), []))
      let got = threads.insert_message(to_jv(a(0)))
      told_threads(bus, threads)
      Some(got)
    }
    "store.withdrawCard" => {
      errdefer told_threads(bus, threads)
      let got = threads.withdraw_card(a(0), a(1), a(2))
      told_threads(bus, threads)
      Some(got)
    }
    "store.restateCard" => {
      let was = threads.card_at(a(1), a(2))
      let next = run_cb(a(3), [was]).unwrap_or(was)
      errdefer told_threads(bus, threads)
      let got = threads.restate_card(a(0), a(1), a(2), _ => to_jv(next))
      told_threads(bus, threads)
      Some(got)
    }
    "cardOutcomes.save" => {
      ignore(run_cb(a(1), []))
      Some(bus.hub_card_outcomes_save(a(0)))
    }
    _ => None
  }
}

// ── unified infrastructure dispatch ──

///|
async fn bus_remote_ask(bus : LiveBus, station : String, request : Json) -> Json {
  let (answer, _) = bus.call_peer(station, jtext(request, "workspace"), jtext_or_empty(request, "method"), request)
  answer
}

///|
async fn dispatch_infra(bus : LiveBus, name : String, args : Array[Json]) -> Json? {
  let a = (i : Int) => arg_at(args, i)
  let s = (i : Int) => arg_str(args, i)
  match name {
    "config.raw" => Some((bus.config_raw.val)())
    "config.updateSoon" => { let next = a(0); ignore((bus.config_update.val)(_ => next)); Some(Json::null()) }
    "config.put" => { let next = a(0); Some((bus.config_update.val)(_ => next)) }
    "cloud.memberships" => Some((bus.cloud_call.val)("memberships", Json::null()))
    "cloud.reload" => { ignore((bus.cloud_call.val)("reload", Json::null())); Some(Json::null()) }
    "cloud.station" => Some(jopt(bus_station_id_opt(bus)))
    "cloud.home" => Some(jopt(bus_home(bus)))
    "cloud.removed" => Some(jb(bus_cloud_removed(bus)))
    "events.tell" => { (bus.events_tell.val)(s(0), a(1), s(2), a(3)); Some(Json::null()) }
    "events.overviewChanged" => { (bus.overview_changed.val)(); Some(Json::null()) }
    "remote.ask" => Some(bus_remote_ask(bus, s(0), a(1)))
    "os.homedir" => Some(jstr(homedir()))
    "os.hostname" => Some(jstr(hostname()))
    "os.tmpdir" => Some(jstr(tmpdir()))
    "os.totalmem" => Some(match machine() { { "totalmem": Number(n, ..), .. } => jn(n); _ => jn(0.0) })
    "os.cpus" => Some(match machine() { { "cpus": Array(c), .. } => Json::array(c); _ => Json::array([]) })
    "os.info" => Some(jobj_of([("platform", jstr(platform())), ("arch", jstr(arch())), ("hostname", jstr(hostname())), ("homedir", jstr(homedir()))]))
    "platform.os" => Some(jstr(platform_os()))
    "platform.sep" => Some(jstr(sep()))
    "platform.hasKeychain" => Some(jb(platform() == "darwin"))
    "crypto.randomHex" => Some(jstr(@drive.hex(@drive.random_bytes(as_num(a(0)).unwrap_or(16.0).to_int()))))
    "crypto.randomUUID" => Some(jstr(@drive.random_uuid()))
    "process.pid" => Some(ji(@drive.pid()))
    "wall.now" | "clock.currentTimeMillisUnsafe" => Some(jn(wall_ms().to_double()))
    "log.info" | "log.warn" | "log.error" => { slice_log(name[4:].to_owned(), s(0), s(1), a(2)); Some(Json::null()) }
    _ => None
  }
}

// ── shared `@updates.World` builder ──

///|
fn build_updates_world(
  host : @host.Host,
  data : String,
  config_raw : () -> Json,
  config_update : async (Json) -> Unit,
  extra_node? : (async (String, Array[@jsjson.JValue]) -> @jsjson.JValue?)? = None,
  tell? : (String, Array[@jsjson.JValue]) -> Unit = (_, _) => (),
  watch? : (async (String, (String?) -> Unit) -> async () -> Unit)? = None,
) -> @updates.World {
  let world : Ref[@updates.World?] = Ref(None)
  let node = async fn(name : String, a : Array[@jsjson.JValue]) -> @jsjson.JValue {
    let core = (i : Int) => if i < a.length() { of_jv(a[i]) } else { Json::null() }
    match extra_node {
      Some(f) => if f(name, a) is Some(v) { return v }
      None => ()
    }
    match name {
      "cloud.fetch" => match world.val { Some(w) => w.call("fetch", a); None => to_jv(Json::null()) }
      "CloudTransport.new" | "CloudTransport.close" | "ConfigFile.new" | "listener.changed" => to_jv(Json::null())
      "wall.sleep" => {
        if core(0) is Number(ms, ..) { @effect.sleep(ms.to_int()) }
        to_jv(Json::null())
      }
      "ConfigFile.raw" => to_jv(config_raw())
      "ConfigFile.update" | "config.updateSoon" => {
        config_update(core(if name == "ConfigFile.update" { 1 } else { 0 }))
        to_jv(Json::null())
      }
      "process.kill" =>
        match core(0) {
          Number(p, ..) => {
            let signal = match core(1) { String(s) => s; Number(0.0, ..) => "0"; _ => "SIGTERM" }
            if kill(p.to_int(), signal) { to_jv(jb(true)) } else { raise coded("ESRCH", "kill ESRCH") }
          }
          _ => to_jv(jb(false))
        }
      "os.tmpdir" => to_jv(jstr(tmpdir()))
      _ =>
        match updates_platform(host, data, name, a.map(of_jv)) {
          Some(v) => to_jv(v)
          None => raise coded("ENOSYS", "the station's program does not do \{name}")
        }
    }
  }
  let clock : @updates.Clock = { now: () => wall_ms().to_double(), sleep: async fn(ms) { @effect.sleep(ms.to_int()) } }
  let w = @updates.host_world(host, node, tell, clock, watch.unwrap_or(async fn(_dir, _told) { async fn() {  } }))
  world.val = Some(w)
  w
}

// ── shared slice primitives ──

///|
fn arg_at(args : Array[Json], i : Int) -> Json {
  if i < args.length() { args[i] } else { Json::null() }
}

///|
fn arg_str(args : Array[Json], i : Int) -> String {
  match arg_at(args, i) { String(s) => s; _ => "" }
}

///|
fn arg_int(args : Array[Json], i : Int) -> Int {
  match arg_at(args, i) { Number(n, ..) => n.to_int(); _ => 0 }
}

///|
/// Fork a background daemon fiber on `host.rt` whose unexpected failure is logged via `@host.note`.
fn fork_bg(host : @host.Host, name : String, f : async () -> Unit) -> Unit {
  ignore(host.rt.fork_daemon(name, on_error=e => @host.note("\{name} failed: \{e}"), f))
}

///|
/// Spawn a child with piped stdin/stdout and feed each `\n`-delimited stdout line to `on_line`, then `on_exit`.
fn spawn_lines(
  host : @host.Host,
  program : String,
  args : Array[String],
  name : String,
  on_line : (Proc, String) -> Unit,
  on_exit : (Proc, Int?) -> Unit,
) -> Proc raise SysError {
  let p = spawn(host, program, args, stdin_piped=true, stdout=Piped)
  fork_bg(host, name, async fn() {
    let line = @buffer.Buffer()
    while true {
      match p.events.take() {
        Out(b) =>
          for i in 0..<b.length() {
            if b[i] == b'\n' {
              on_line(p, @utf8.decode_lossy(line.to_bytes()))
              line.reset()
            } else {
              line.write_byte(b[i])
            }
          }
        Err(_) => ()
        Exit(code, _) => { on_exit(p, code); return }
      }
    }
  })
  p
}

///|
/// Run `f` once after `ms` milliseconds on the program's runtime; the returned closure cancels and interrupts it.
fn bus_after(host : @host.Host, ms : Double, f : () -> Unit) -> () -> Unit {
  let off = Ref(false)
  let wait = if ms < 0.0 { 0 } else if ms > 2147483647.0 { 2147483647 } else { ms.to_int() }
  let fiber = host.rt.fork_daemon("after", on_error=e => @host.note("after failed: \{e}"), async fn() {
    @effect.sleep(wait) // timer: a deadline a part set (its `after`)
    if !off.val { f() }
  })
  () => { off.val = true; fiber.interrupt() }
}

///|
fn platform_os() -> String {
  match platform() { "darwin" => "macos"; "win32" => "windows"; p => p }
}

///|
fn bus_cloud(bus : LiveBus) -> Json {
  (bus.cloud_state.val)().unwrap_or(Json::null())
}

///|
fn bus_station_id_opt(bus : LiveBus) -> String? {
  match (bus.cloud_state.val)() {
    Some(s) => match jtext(s, "station") { Some(id) if id != "" => Some(id); _ => None }
    None => None
  }
}

///|
fn bus_station_id(bus : LiveBus) -> String {
  bus_station_id_opt(bus).unwrap_or(bus.key.id)
}

///|
fn bus_home(bus : LiveBus) -> String? {
  match (bus.cloud_state.val)() {
    Some(s) => match jtext(s, "workspace") { Some(w) if w != "" => Some(w); _ => None }
    None => None
  }
}

///|
fn bus_agent_home(bus : LiveBus) -> String {
  match jtext((bus.config_raw.val)(), "agentHome") {
    Some(h) if h != "" => h
    _ => path([bus.data, "agent"])
  }
}

///|
fn bus_cloud_removed(bus : LiveBus) -> Bool {
  match (bus.cloud_state.val)() {
    Some(st) => opt_num(opt_field(Some(st), "removed_at")) is Some(_)
    None => false
  }
}

///|
fn bus_session_row_opt(bus : LiveBus, key : String) -> Json? {
  match (try { Ok(bus.store.get_session(key)) } catch { e => Err(e) }) {
    Ok(Object(_) as row) => Some(row)
    _ => None
  }
}

///|
fn bus_session_row(bus : LiveBus, key : String) -> Json {
  bus_session_row_opt(bus, key).unwrap_or(Json::null())
}

///|
fn bus_session_ws(bus : LiveBus, key : String) -> String? {
  match (try { Ok(bus.store.session_ws(key)) } catch { e => Err(e) }) {
    Ok(String(w)) if w != "" => Some(w)
    _ => bus_home(bus)
  }
}

///|
fn bus_session_dir(bus : LiveBus, key : String) -> String? {
  let row = bus_session_row_opt(bus, key)
  match opt_text(row, "cwd") {
    Some(c) if c != "" => Some(c)
    _ => match opt_text(row, "workspace") { Some(w) if w != "" => Some(w); _ => None }
  }
}

///|
async fn run_cmd(host : @host.Host, program : String, args : Array[String], env? : Array[(String, String)], cwd? : String) -> (Int?, String, String) {
  let proc = spawn(host, program, args, env?, cwd?, stdout=Piped, stderr=Piped)
  let (code, _, out, err) = proc.finished()
  (code, @utf8.decode_lossy(out), @utf8.decode_lossy(err))
}

///|
/// Run a child to its end with optional stdin and timeout; None where it did not start.
async fn run_capture(
  host : @host.Host,
  program : String,
  args : Array[String],
  env? : Array[(String, String)],
  cwd? : String,
  input? : String,
  ms? : Int = 0,
  group? : Bool = false,
) -> (Int?, String?, String, String, Bool)? {
  let proc = spawn(host, program, args, env?, cwd?, stdin_piped=input is Some(_), stdout=Piped, stderr=Piped, group~) catch {
    _ => return None
  }
  if input is Some(t) {
    ignore(proc.write(@utf8.encode(t)))
    proc.end_input()
  }
  if ms > 0 {
    match @effect.timeout(ms, async fn() { proc.finished() }) {
      Some((code, signal, out, err)) => Some((code, signal, @utf8.decode_lossy(out), @utf8.decode_lossy(err), false))
      None => {
        ignore(kill(proc.pid, "SIGKILL", group~))
        Some((None, None, "", "", true))
      }
    }
  } else {
    let (code, signal, out, err) = proc.finished()
    Some((code, signal, @utf8.decode_lossy(out), @utf8.decode_lossy(err), false))
  }
}

///|
/// What a command printed (trimmed), None where it failed or took longer than `ms`.
async fn run_said(host : @host.Host, program : String, args : Array[String], ms : Int) -> String? {
  match run_capture(host, program, args, ms~) {
    Some((Some(0), _, out, _, false)) => Some(out.trim().to_owned())
    _ => None
  }
}

///|
/// A program run to its end via shell `proc.run`, its stdout; none where it failed.
async fn shell_proc_run(host : @host.Host, command : String, args : Array[String], timeout_ms? : Int = 10000) -> String? {
  match (try { Ok(host.shell("proc.run", { "command": jstr(command), "args": Json::array(args.map(jstr)), "timeoutMs": ji(timeout_ms) })) } catch { e => Err(e) }) {
    Ok((String(s), _)) => Some(s)
    _ => None
  }
}

///|
/// The CPUs' ticks from `machine()` as (busy, total); None where unavailable.
fn machine_cpu_ticks() -> (Double, Double)? {
  guard machine() is { "cpus": Array(cpus), .. } && cpus.length() > 0 else { return None }
  let mut busy = 0.0
  let mut total = 0.0
  for c in cpus {
    if c is { "times": Object(t), .. } {
      for k, v in t {
        if v is Number(n, ..) {
          total += n
          if k != "idle" { busy += n }
        }
      }
    }
  }
  Some((busy, total))
}

///|
/// Shared GPU sampler (`@jobs_host.Gpus`: Apple Silicon ioreg, NVIDIA nvidia-smi, Linux DRM, Windows AMD).
fn make_gpus(host : @host.Host) -> @jobs_host.Gpus {
  let run = async fn(file, args, ms) { @jobs_host.run_on(host, file, args, ms) }
  @jobs_host.Gpus::new(
    run,
    platform_os(),
    arch(),
    () => wall_ms().to_double(),
    async fn() { @jobs_host.linux_gpus(@jobs_host.LinuxIo::shell(host, run)) },
  )
}

///|
fn gpus_to_json(g : Array[@jobs_host.Gpu]) -> Json {
  Json::array(g.map(x => x.to_json()))
}

///|
/// Start `program` under `runner`, returning its `{"ready": true, ...}` line.
async fn start_runner_proc(
  host : @host.Host,
  runner : String,
  data : String,
  id : String,
  program : String,
  args : Array[String],
  env? : Array[(String, String)],
  cwd : String,
  pty? : (Int, Int),
  use_nice? : Bool = false,
) -> Json {
  let given = ["--dir", path([data, "run", "runners"]), "--id", id, "--cwd", cwd]
  if pty is Some((cols, rows)) {
    given.push("--pty")
    given.push("\{cols}x\{rows}")
  }
  given.push("--")
  given.push(program)
  for a in args { given.push(a) }
  let (command, all_args) = if use_nice && !is_windows() {
    let nice = agent_nice()
    if nice > 0 && host_exists(host, "/usr/bin/nice") {
      ("/usr/bin/nice", ["-n", nice.to_string(), runner, ..given])
    } else {
      (runner, given)
    }
  } else {
    (runner, given)
  }
  let child = spawn(host, command, all_args, env?, stdout=Piped, stderr=Piped, group=true)
  let (_, _, out, err) = child.finished()
  let text = @utf8.decode_lossy(out)
  for line in text.split("\n") {
    let l = line.to_owned()
    if l.has_prefix("{") {
      if attempt(() => @json.parse(l)) is Ok({ "ready": True, .. } as ready) {
        return ready
      }
    }
  }
  let why = @utf8.decode_lossy(err).trim().to_owned()
  raise LiveError("the runner did not start: \{if why == "" { text.trim().to_owned() } else { why }}")
}

///|
async fn process_descendants(host : @host.Host, pid : Int) -> Array[Int] {
  let (code, text, _) = run_cmd(host, "ps", ["-A", "-o", "pid=,ppid="]) catch { _ => return [] }
  guard code == Some(0) else { return [] }
  let children : Map[Int, Array[Int]] = Map([])
  for line in text.split("\n") {
    let f = line.trim().split(" ").filter(x => x != "").map(x => x.to_owned()).to_array()
    if f.length() >= 2 {
      let c = @string.parse_int(f[0]) catch { _ => continue }
      let p = @string.parse_int(f[1]) catch { _ => continue }
      match children.get(p) { Some(a) => a.push(c); None => children[p] = [c] }
    }
  }
  let out = []
  let next = [pid]
  while next.pop() is Some(p) {
    for c in children.get(p).unwrap_or([]) {
      if !out.contains(c) { out.push(c); next.push(c) }
    }
  }
  out
}

///|
fn env_prepend_path(env : Map[String, String], dir : String) -> Map[String, String] {
  let m = env.copy()
  let sep_ = if is_windows() { ";" } else { ":" }
  m["PATH"] = match env.get("PATH") { Some(p) if p != "" => dir + sep_ + p; _ => dir }
  m
}

///|
async fn env_with_shell_command(host : @host.Host, program : String, env : Map[String, String], lookup? : Array[(String, String)]) -> Map[String, String]? {
  let given = env.to_array()
  let found = match lookup { Some(l) => with_shell_command(host, program, given, lookup=l); None => with_shell_command(host, program, given) }
  if found == given { None } else { Some(Map::from_array(found)) }
}

///|
fn base64url_encode(b : Bytes) -> String {
  @base64.encode(b).replace_all(old="+", new="-").replace_all(old="/", new="_").replace_all(old="=", new="")
}

///|
/// Wrap a command in a pseudo-terminal (`script` on macOS/Linux, optionally ConPTY runner on Windows).
fn bus_pty_terminal(
  bus : LiveBus,
  program : String,
  args : Array[String],
  cols : Int,
  rows : Int,
  allow_windows~ : Bool,
  has_script : (String) -> Bool,
) -> (String, Array[String])? {
  if is_windows() {
    return if allow_windows {
      runner_binary(bus.app, bus.argv0, bus.data).map(r => (r, ["--relay-pty", "--size", "\{cols}x\{rows}", program, ..args]))
    } else {
      None
    }
  }
  let run = "stty cols \{cols} rows \{rows} 2>/dev/null; exec \"$@\""
  if platform() == "darwin" {
    let feed = "exec 3<&0; cat <&3 | { /usr/bin/script -q /dev/null /bin/sh -c '\{run}' sh \"$@\" 3<&-; s=$?; /usr/bin/pkill -P $$ -x cat; exit $s; }"
    return Some(("/bin/sh", ["-c", feed, "sh", program, ..args]))
  }
  for script in ["/usr/bin/script", "/bin/script"] {
    if has_script(script) {
      let inner = ["/bin/sh", "-c", run, "sh", program, ..args].map(p54_quoted)
      return Some((script, ["-qfec", inner.join(" "), "/dev/null"]))
    }
  }
  None
}
