// P5-1's admin API (services.ts AdminApi, api/admin.ts): api_routes' table of routes, asked of the station's parts by
// name (`<part>.<method>`, api_routes/backend.mbt): the platform's answered here (the readers, the store's reads, the
// machine, config.json, the event streams, the control plane, the overview, the clock and crypto), what is another
// slice's asked of it through the bus (`hub_ask` the agents' side, `jobs_ask`, `ui_ask`, `coord_ask`), and after them
// the parts' own routes (StationParts `all_routes`). Members reach it on the mesh (live_p5_1_mesh.mbt); where
// STILLFAIL_LOCAL_ADMIN=1 says so (a test with no mesh), the machine's own programs reach it on the agents' door under
// `/admin-api/`, as the station's owner.
//
// A part's route is answered from the request as JSON (`{method, path, params, query, search, headers, body, json,
// viewer, lang}`) and answers JSON: `{status, headers?, body?}` where it says its status, else its value whole (200).

///|
priv struct AdminLive {
  admin : @api_routes.Admin
  /// The files the routes opened (`fs.open`'s handle, `fh:<n>`): the path each reads.
  files : Map[String, String]
  mut next_handle : Int
  /// What a route's answer streams (a file read, an event stream), by id: its next piece.
  streams : Map[Int, async () -> Bytes?]
  /// What lets a stream go as its reader went, by id.
  stream_stops : Map[Int, () -> Unit]
  mut next_stream : Int
}

///|
/// What is another slice's, by the name a route asks it by.
fn slice_of(name : String) -> String {
  let mut cut = name.length()
  for i = 0; i < name.length(); i = i + 1 {
    if name[i] == '.' || name[i] == '/' {
      cut = i
      break
    }
  }
  let first = name[:cut].to_owned()
  match first {
    "jobs" | "search" | "resources" | "usage" | "sharing" | "xshare" | "models" | "links" | "accounts" | "repoIndex" | "workspaceWatch" =>
      "jobs"
    "vault" | "vaults" | "secrets" | "screens" | "drive" | "logins" | "signIns" | "grants" | "devices" | "terminals" | "browser" | "helper" | "transfers" =>
      "ui"
    "slack" | "feishu" | "comma" | "group" | "updates" | "copies" | "retire" | "moves" | "features" | "connectKinds" | "cli" => "coord"
    _ => "hub"
  }
}

///|
/// `length` bytes of `file` from `from` (fewer at its end), read by the shell off the program's thread (`from` a
/// Double: a file past 2 GiB is read where it is asked, which `Host::read_bytes`'s Int would not reach).
async fn p51_file_piece(host : @host.Host, file : String, from : Double, length : Int) -> Bytes raise {
  if length <= 0 {
    return b""
  }
  let args : Json = { "path": Json::string(file), "from": Json::number(from), "length": Json::number(length.to_double()) }
  let (said, _) = host.shell("fs.bytes", args) catch {
    @wire.ShellError(e) => raise @api_routes.Thrown("Error", to_jv({ "message": Json::string(e) }))
    e => raise e
  }
  p51_piece_answered(file, said)
}

///|
/// `p51_file_piece` on the program's thread, for a reading that cannot wait (`shown_facts`' `Src`).
fn p51_file_piece_now(host : @host.Host, file : String, from : Double, length : Int) -> Bytes raise {
  if length <= 0 {
    return b""
  }
  p51_piece_answered(
    file,
    host.shell_sync("fs.bytes", { "path": Json::string(file), "from": Json::number(from), "length": Json::number(length.to_double()) }),
  )
}

///|
/// What `fs.bytes` answered of `file`: its bytes, or Node's ENOENT where it did not open.
fn p51_piece_answered(file : String, said : Json) -> Bytes raise {
  match said {
    String(hex) => @cloud_lock.hex_bytes(hex)
    { "error": String(e), .. } => raise @api_routes.Thrown("Error", to_jv({ "message": Json::string(e) }))
    _ => raise @api_routes.Thrown("Error", to_jv({ "message": "ENOENT: no such file or directory, open '\{file}'", "code": "ENOENT" }))
  }
}

///|
/// Whether a viewer manages the station, and whether one only reads (api_routes' `manages_station`, `read_only`).
fn p51_manages(viewer : Json) -> Bool {
  @api_routes.manages_station(to_jv(viewer))
}

///|
fn p51_read_only(viewer : Json) -> Bool {
  @api_routes.read_only(to_jv(viewer))
}

///|
/// A file system's failure as the routes take it (fs.mbt: an `Error` with its `code`), anything else as it was.
fn p51_fs_thrown(e : Error) -> Error {
  match e {
    DispatchFsError(code, message) =>
      @api_routes.Thrown("Error", to_jv({ "message": Json::string(message), "code": Json::string(code) }))
    @drive.FsError(f) =>
      @api_routes.Thrown("Error", to_jv({ "message": Json::string(f.message), "code": Json::string(f.code) }))
    other => other
  }
}

///|
/// The launcher's pid where it can hand this process over (it said so in run/station.json), else None.
fn P51::restart_pid(self : P51) -> Int? {
  match read_json(path([self.bus.data, "run", "station.json"])) {
    Some({ "pid": Number(p, ..), "handoff": Number(1.0, ..), .. }) if pid_alive(p.to_int()) && !is_windows() =>
      Some(p.to_int())
    _ => None
  }
}

///|
/// The station's parts whose answer is bytes, as the routes ask them (api_routes `Backend::ask_bytes`): a file's
/// piece, a file whole, a stream's next piece and a reader's answer given as they are, never base64 and back (a part's
/// piece is 4 MB); `None` where `backend` answers null. Any other part is `backend`'s answer decoded.
async fn P51::backend_bytes(self : P51, a : AdminLive, name : String, args : Array[@api_routes.JV]) -> Bytes? {
  let text = (i : Int) => match args.get(i) {
    Some(Str(s)) => s
    _ => ""
  }
  match name {
    "readers.readBytes" => {
      let readers = self.readers.unwrap()
      let background = match of_jv(args.get(3).unwrap_or(Null)) {
        { "background": True, .. } => true
        _ => false
      }
      let got = readers.read_bytes(text(0), of_jv(args.get(1).unwrap_or(Null)), text(2), background~) catch {
        ReadFailed(status, m) => raise @api_routes.Thrown("HttpError", to_jv({ "message": Json::string(m), "status": Json::number(status.to_double()) }))
        e => raise e
      }
      Some(got)
    }
    "fs.readFile" =>
      match self.host.read_bytes(text(0)) {
        Some(b) => Some(b)
        None => raise @api_routes.Thrown("Error", to_jv({ "message": "ENOENT: no such file or directory, open '\{text(0)}'", "code": "ENOENT" }))
      }
    "drive/fs.readAt" => {
      // (a handle `fs.open` gave, where to start, how much): the bytes there, fewer at the file's end
      let handle = @api_routes.ref_of(args.get(0).unwrap_or(Null)).unwrap_or("")
      guard a.files.get(handle) is Some(file) else {
        raise @api_routes.Thrown("Error", to_jv({ "message": "EBADF: bad file descriptor", "code": "EBADF" }))
      }
      let num = (i : Int) => match args.get(i) {
        Some(Num(n)) => n
        _ => 0.0
      }
      Some(p51_file_piece(self.host, file, num(1), num(2).to_int()))
    }
    "$stream.next" => {
      let id = match args.get(0) {
        Some(Num(n)) => n.to_int()
        _ => -1
      }
      guard a.streams.get(id) is Some(next) else { return None }
      match next() {
        Some(b) => Some(b)
        None => {
          a.streams.remove(id)
          a.stream_stops.remove(id)
          None
        }
      }
    }
    _ => {
      let got = self.backend(a, name, args)
      if @api_routes.nullish(got) {
        None
      } else {
        @api_routes.bytes_of(got)
      }
    }
  }
}

///|
/// The station's parts as the routes ask them (api_routes `Backend`).
async fn P51::backend(self : P51, a : AdminLive, name : String, args : Array[@api_routes.JV]) -> @api_routes.JV {
  let bus = self.bus
  let arg = (i : Int) => of_jv(args.get(i).unwrap_or(Null))
  let text = (i : Int) => match args.get(i) {
    Some(Str(s)) => s
    _ => ""
  }
  // A file the routes opened (`fs.open`): its size, a piece of it, let go.
  if name.has_prefix("fh:") {
    let (handle, call) = match name.rev_find(".") {
      Some(i) => (name[:i].to_owned(), name[i + 1:].to_owned())
      None => (name, "")
    }
    guard a.files.get(handle) is Some(file) else {
      raise @api_routes.Thrown("Error", to_jv({ "message": "EBADF: bad file descriptor", "code": "EBADF" }))
    }
    match call {
      "stat" => return self.backend(a, "fs.stat", [Str(file)])
      "read" => {
        // (buffer, offset, length, position): what was read, put in the buffer at `offset`
        let buffer = @api_routes.bytes_of(args.get(0).unwrap_or(Null)).unwrap_or(b"")
        let num = (i : Int) => match args.get(i) {
          Some(Num(n)) => n
          _ => 0.0
        }
        let at = num(1).to_int()
        let length = num(2).to_int()
        let got = p51_file_piece(self.host, file, num(3), length)
        let room = if buffer.length() - at < 0 { 0 } else { buffer.length() - at }
        let n = if got.length() < room { got.length() } else { room }
        let out = @buffer.new()
        out.write_bytesview(buffer[0:at])
        out.write_bytesview(got[0:n])
        out.write_bytesview(buffer[at + n:])
        return to_jv({ "bytesRead": Json::number(n.to_double()), "buffer": of_jv(@api_routes.jbytes(out.to_bytes())) })
      }
      "close" => {
        a.files.remove(handle)
        return Null
      }
      _ => raise @api_routes.Thrown("Error", to_jv({ "message": "no call \{call} of a file" }))
    }
  }
  // A part's card choice (`parts.cardChoiceOf`'s): whether a member may choose on it, and what is done once they did.
  if name.has_prefix("card:") {
    let (handle, call) = match name.rev_find(".") {
      Some(i) => (name[5:i].to_owned(), name[i + 1:].to_owned())
      None => (name[5:].to_owned(), "")
    }
    guard bus.parts.card_choice_named(handle) is Some(choice) else {
      raise @api_routes.Thrown("Error", to_jv({ "message": "no card choice \{handle}" }))
    }
    match call {
      "may" =>
        return match (choice.may)(arg(0), arg(1), arg(2)) {
          Some(why) => Str(why)
          None => Null
        }
      "chosen" => {
        (choice.chosen)(arg(0), arg(1), text(2), arg(3))
        return Null
      }
      _ => raise @api_routes.Thrown("Error", to_jv({ "message": "no call \{call} of a card choice" }))
    }
  }
  // The page's restart, asked first (`restart`) and then told (`restart.go`) once its answer is on its way.
  if name == "restart.go" {
    match self.restart_pid() {
      Some(pid) => {
        let front = bus.restart_front
        fork_bg(self.host, "restart", async fn() {
          @effect.sleep(150) // timer: a deadline (the answer's time to leave before the process ends)
          match front {
            Some(f) => f()
            None => ignore(kill(pid, "SIGUSR2"))
          }
        })
      }
      None => ()
    }
    return Null
  }
  match name {
    // (bytes as `{"$bytes": base64}`, for a caller that does not take them as they are: `backend_bytes`'s)
    "readers.readBytes" | "fs.readFile" | "drive/fs.readAt" | "$stream.next" =>
      match self.backend_bytes(a, name, args) {
        Some(b) => @api_routes.jbytes(b)
        None => Null
      }
    "readers.names.set" => {
      match (args.get(0), args.get(1)) {
        (Some(Str(email)), Some(Str(n))) => self.readers.unwrap().names[email] = n
        _ => ()
      }
      Null
    }
    "crypto.randomBytes" => {
      let n = match args.get(0) {
        Some(Num(n)) => n.to_int()
        _ => 16
      }
      @api_routes.jbytes(@drive.random_bytes(n))
    }
    "clock.currentTimeMillisUnsafe" | "os.homedir" | "os.totalmem" | "os.cpus" | "config.raw" | "config.updateSoon" | "cloud.memberships" | "cloud.reload" | "events.overviewChanged" | "events.tell" =>
      to_jv(dispatch_infra(bus, name, args.map(of_jv)).unwrap_or(Json::null()))
    "host.sample" => to_jv((bus.host_sample.val)())
    "events.open" => {
      guard self.events is Some(events) else { raise @api_routes.Thrown("HttpError", to_jv({ "message": "events not ready", "status": 503 })) }
      let live = match arg(3) {
        Array(items) =>
          items.filter_map(i => match i {
            Array([String(k), Number(from, ..), last]) =>
              Some((k, from, match last { Number(l, ..) => Some(l); _ => None }))
            _ => None
          })
        _ => []
      }
      let logs = match arg(4) {
        Array(items) =>
          items.filter_map(i => match i {
            Array([String(id), Number(n, ..)]) => Some((id, n.to_int()))
            _ => None
          })
        _ => []
      }
      let asked : @events.Asked = {
        host: arg(2) is True,
        live,
        logs,
        since: as_text(arg(5)),
        brief: arg(6) is True,
        logins: match arg(7) {
          Array(l) => l.filter_map(x => match x { String(s) => Some(s); _ => None })
          _ => []
        },
        running: arg(8) is True,
      }
      let (headers, id) = events.open(arg(0), text(1), asked)
      a.next_stream += 1
      let sid = a.next_stream
      a.streams[sid] = async fn() {
        match events.next(id) {
          Some(t) => Some(@utf8.encode(t))
          None => None
        }
      }
      a.stream_stops[sid] = () => events.close(id)
      let h : Map[String, Json] = {}
      for kv in headers {
        h[kv.0] = Json::string(kv.1)
      }
      to_jv({ "status": 200, "headers": Json::object(h), "body": { "$stream": Json::number(sid.to_double()) } })
    }
    "events.presetsChanged" => {
      if self.events is Some(e) { e.events.presets_changed() }
      Null
    }
    "$fn.call" => {
      let id = match args.get(0) {
        Some(Num(n)) => n.to_int()
        Some(Obj(_) as f) =>
          match f.get("$fn") {
            Some(Num(n)) => n.to_int()
            _ => -1
          }
        _ => -1
      }
      a.admin.called(id, args[1:].to_array())
    }
    "$stream.stop" => {
      let id = match args.get(0) {
        Some(Num(n)) => n.to_int()
        _ => -1
      }
      a.streams.remove(id)
      match a.stream_stops.get(id) {
        Some(stop) => {
          a.stream_stops.remove(id)
          stop()
        }
        None => ()
      }
      Null
    }
    "fs.stat" => {
      let p = text(0)
      match (try { Ok(self.fs.lstat(p)) } catch { e => Err(e) }) {
        Ok(Some(st)) => {
          // (stat follows a link: what it names)
          let st = if st.kind == "symlink" {
            match (try { Ok(self.fs.realpath(p)) } catch { e => Err(e) }) {
              Ok(Some(real)) => self.fs.lstat(real).unwrap_or(st)
              _ => st
            }
          } else {
            st
          }
          to_jv({
            "size": Json::number(st.size),
            "mtimeMs": Json::number(st.mtime_ms),
            "file": Json::boolean(st.kind == "file"),
            "dir": Json::boolean(st.kind == "dir" || st.kind == "directory"),
          })
        }
        _ => raise @api_routes.Thrown("Error", to_jv({ "message": "ENOENT: no such file or directory, stat '\{p}'", "code": "ENOENT" }))
      }
    }
    "fs.writeFile" => {
      let data = @api_routes.bytes_of(args.get(1).unwrap_or(Null)).unwrap_or_else(() => @utf8.encode(text(1)))
      let (excl, mode) = match arg(2) {
        Object(o) =>
          (
            o.get("flag") is Some(String("wx" | "xw")),
            opt_num(o.get("mode")).map(n => n.to_int()).unwrap_or(0),
          )
        _ => (false, 0)
      }
      host_write_file(self.host, text(0), data, excl~, mode~) catch {
        e => raise p51_fs_thrown(e)
      }
      Null
    }
    "fs.appendFile" => {
      let data = @api_routes.bytes_of(args.get(1).unwrap_or(Null)).unwrap_or_else(() => @utf8.encode(text(1)))
      host_append_file(self.host, text(0), data) catch {
        e => raise p51_fs_thrown(e)
      }
      Null
    }
    "fs.access" | "fs.readdir" | "fs.copyFile" | "fs.rename" | "fs.rm" | "fs.statfs" | "fs.mkdir" => {
      let got = host_fs_op(self.host, name[3:].to_owned(), args.map(of_jv), strict_rm=true, readdir_file_field=true) catch {
        e => raise p51_fs_thrown(e)
      }
      to_jv(got)
    }
    "fs.open" => {
      let p = text(0)
      match (try { Ok(self.fs.lstat(p)) } catch { e => Err(e) }) {
        Ok(Some(_)) => ()
        _ => raise @api_routes.Thrown("Error", to_jv({ "message": "ENOENT: no such file or directory, open '\{p}'", "code": "ENOENT" }))
      }
      a.next_handle += 1
      let handle = "fh:\{a.next_handle}"
      a.files[handle] = p
      @api_routes.jref(handle)
    }
    // (lock.ts `admit` of the lock in force where `state` says, `vault.lock`'s: the device and role it admits)
    "cloud/lock.admit" => {
      guard self.plane is Some(plane) else { raise @api_routes.Thrown("Error", to_jv({ "message": "no control plane" })) }
      // (a vault's lock made of its members' own locks, no security mode: cloud/vault-lock.ts, lock.ts `admit`)
      let personal = arg(0)
      if personal is { "genesis": String(""), .. } {
        let (id, role, sign_key) = @cloud_lock.admit_personal(plane.crypto, personal, who_of(arg(1))) catch {
          e => raise @api_routes.Thrown("Error", to_jv({ "message": Json::string("\{e}") }))
        }
        let d : Map[String, Json] = { "id": Json::string(id), "sub": Json::string(who_of(arg(1)).sub), "kind": Json::string("app") }
        if sign_key is Some(k) { d["sign_key"] = Json::string(k) }
        return to_jv({ "device": Json::object(d), "role": Json::string(role) })
      }
      let ws = match arg(0) {
        { "ws": String(w), .. } if Some(w) != plane.cloud.home() => Some(w)
        _ => None
      }
      guard plane.cloud.locked(ws~) is Some({ state: Some(st), .. }) else {
        raise @api_routes.Thrown("Error", to_jv({ "message": "this workspace keeps no lock" }))
      }
      let now = match args.get(2) {
        Some(Num(n)) => n
        _ => wall_ms().to_double() / 1000.0
      }
      let (device, role) = @cloud_lock.admit(plane.crypto, st, who_of(arg(1)), now) catch {
        e => raise @api_routes.Thrown("Error", to_jv({ "message": Json::string("\{e}") }))
      }
      let d : Map[String, Json] = { "id": Json::string(device.id), "sub": Json::string(device.sub), "kind": Json::string(device.kind) }
      if device.by is Some(b) { d["by"] = Json::string(b) }
      if device.sign_key is Some(k) { d["sign_key"] = Json::string(k) }
      to_jv({ "device": Json::object(d), "role": Json::string(role) })
    }
    "cli.joinWorkspace" => {
      let home_locked = () => match self.plane {
        Some(plane) => plane.cloud.locked() is Some(_)
        None => false
      }
      let lock = match args.get(2) {
        Some(Str(l)) => Some(l)
        _ => None
      }
      let joined = join_workspace(self.host, text(0), text(1), lock, bus.version, home_locked) catch {
        JoinRefused(kind, m) => raise @api_routes.Thrown(kind, to_jv({ "message": Json::string(m) }))
        e => raise @api_routes.Thrown("Error", to_jv({ "message": Json::string("\{e}") }))
      }
      to_jv(joined)
    }
    "fs.createReadStream" => {
      let file = text(0)
      let (start, end) = match arg(1) {
        Object(m) =>
          (
            match m.get("start") {
              Some(Number(s, ..)) => s.to_int64()
              _ => 0L
            },
            match m.get("end") {
              Some(Number(e, ..)) => Some(e.to_int64())
              _ => None
            },
          )
        _ => (0L, None)
      }
      let reading = @mesh_runtime.shell_file(self.host, file)
      let size = match end {
        Some(e) => e + 1L - start
        None => {
          let total = match (try { Ok(self.fs.lstat(file)) } catch { e => Err(e) }) {
            Ok(Some(st)) => st.size.to_int64()
            _ => 0L
          }
          total - start
        }
      }
      let pieces = @mesh_runtime.file_bytes(async fn() { reading }, start, if size < 0L { 0L } else { size })
      a.next_stream += 1
      let sid = a.next_stream
      a.streams[sid] = async fn() {
        let b = @mesh_runtime.read_bytes(pieces, 65536)
        if b.length() == 0 {
          None
        } else {
          Some(b)
        }
      }
      to_jv({ "$stream": Json::number(sid.to_double()) })
    }
    "agents.overview" => to_jv(self.overview(arg(0), text(1)))
    "parts.mayView" =>
      match arg(0) {
        { "method": String(m), "path": String(p), .. } => Bool(bus.parts.may_view(m, p))
        _ => Bool(false)
      }
    // (a part's own card: what the route asks of it next, `card:<key>.may` and `.chosen`, by the key it said)
    "parts.cardChoiceOf" =>
      match bus.parts.card_key_of(arg(0)) {
        Some(key) => @api_routes.jref("card:\{key}")
        None => Null
      }
    "restart" =>
      // (the page's restart: the launcher asked to hand over, its front started anew where it keeps one)
      match self.restart_pid() {
        Some(_) => @api_routes.jref("restart.go")
        None => Null
      }
    "store.sessionWs" =>
      match bus.store.session_ws(text(0)) {
        Null => @api_routes.jundef
        ws => to_jv(ws)
      }
    "store.getSession" | "hub.store.getSession" => to_jv(bus.store.get_session(text(0)))
    "store.getJob" => to_jv(bus.store.get_job(arg(0)))
    "store.handedTo" => to_jv(bus.store.handed_to(text(0)))
    "store.homeChat" => to_jv(bus.store.home_chat(arg(0)))
    "hub.store.binding" => to_jv(bus.store.binding(arg(0)))
    "store.setThreadTitle" => {
      bus.store.set_thread_title(arg(0), arg(1))
      Null
    }
    "store.told" => {
      match arg(0) {
        Array(changes) => bus.store.told(changes)
        c => bus.store.told([c])
      }
      Null
    }
    "store.threadSessions" =>
      match self.threads_store() {
        Some(t) => {
          t.set_now(wall_ms().to_double())
          let v = t.thread_sessions(arg(0))
          told_threads(bus, t)
          to_jv(v)
        }
        None => Arr([])
      }
    "store.getThread" =>
      match self.threads_store() {
        Some(t) => {
          t.set_now(wall_ms().to_double())
          let v = t.get_thread(arg(0))
          told_threads(bus, t)
          to_jv(v)
        }
        None => Null
      }
    "mesh/settings.networkView" => to_jv(@mesh_runtime.network_view(Some(arg(0))))
    "read/machine.roots" => {
      let home = env_get("HOME").unwrap_or(".")
      let codex = match env_get("CODEX_HOME") {
        Some(c) if c != "" => c
        _ => path([home, ".codex"])
      }
      to_jv({ "claude": Json::string(path([home, ".claude", "projects"])), "codex": Json::string(path([codex, "sessions"])) })
    }
    _ => {
      // Another slice's: asked through the bus with the arguments as JSON; what it refuses thrown as its kind.
      let asked = Json::array(args.map(of_jv))
      let ask = match slice_of(name) {
        "jobs" => bus.jobs_ask.val
        "ui" => bus.ui_ask.val
        "coord" => bus.coord_ask.val
        _ => bus.hub_ask.val
      }
      match (try { Ok(ask(name, asked)) } catch { e => Err(e) }) {
        Ok(v) => to_jv(v)
        Err(@api_routes.Thrown(_, _) as t) => raise t
        // (P5-4's refusals carry their kind and what the route reads of them: a drive's code, a vault's need)
        Err(P54Refused(kind, said)) => raise @api_routes.Thrown(kind, to_jv(said))
        // (a file system's refusal keeps its code: ENOENT, EEXIST, what `ioMessage` and an exclusive write read)
        Err(@session_chats.Thrown(code, m)) =>
          raise @api_routes.Thrown(
            "Error",
            to_jv(
              if code == "" {
                { "message": Json::string(m) }
              } else {
                { "message": Json::string(m), "code": Json::string(code) }
              },
            ),
          )
        Err(@drive.FsError(_) as e) => raise p51_fs_thrown(e)
        Err(e) => raise @api_routes.Thrown("Error", to_jv({ "message": Json::string(said_of(e)) }))
      }
    }
  }
}

///|
/// GET /overview (sessions/agents.ts `view`): the agents' side's where it makes one, else the platform's
/// (api/overview.ts), with the fields the station's parts add (parts.ts `overviewOf`).
async fn P51::overview(self : P51, viewer : Json, lang : String) -> Json {
  let bus = self.bus
  let made = bus.hub_overview(viewer, lang) catch { _ => Json::null() }
  let base : Map[String, Json] = match made {
    Object(m) => m.copy()
    _ =>
      match self.platform_overview(viewer, lang) {
        Object(m) => m.copy()
        _ => {}
      }
  }
  for k, v in bus.parts.overview_of(viewer, lang) {
    base[k] = v
  }
  Json::object(base)
}

///|
fn P51::threads_store(self : P51) -> @store_threads.Store? {
  match self.threads {
    Some(t) => Some(t)
    None => {
      let t = (try { Some(@store_threads.Store::new(self.bus.db, wall_ms().to_double())) } catch { _ => None })
      self.threads = t
      t
    }
  }
}

///|
/// api/overview.ts `overview`, of what the platform has: the control plane, the connects config.json names, the
/// sessions counted, the agents' processes, the disk, the drive's roots, the memberships.
async fn P51::platform_overview(self : P51, viewer : Json, lang : String) -> Json {
  let bus = self.bus
  let store = bus.store
  let host = self.host
  let processes = bus.hub_processes() catch { _ => Json::null() }
  let threads = self.threads_store()
  if threads is Some(t) { t.set_now(wall_ms().to_double()) }
  // What the other slices say of it, asked first (the overview's own reads are synchronous): the accounts' views
  // (P5-3), the updates and the connects' connections (P5-5), Helper's grants (P5-4), the archive policy and the
  // decisions' version (P5-2), the model catalog as the cloud gave it.
  let asked = async fn(ask : async (String, Json) -> Json, op : String, a : Array[Json]) -> Json? {
    match (try { Ok(ask(op, Json::array(a))) } catch { e => Err(e) }) {
      Ok(v) => Some(v)
      Err(_) => None
    }
  }
  let jobs = bus.jobs_ask.val
  // (the decisions' parts, asked only where the overview does not keep their view already: below, `decisions_fresh`)
  let decisions : Ref[Json?] = Ref(None)
  let policy : Ref[Json?] = Ref(None)
  let models_asked : Ref[Json?] = Ref(None)
  let accounts : @events.AccountsDeps? = match
    (
      asked(jobs, "accounts.profilesView", [viewer]),
      asked(jobs, "accounts.loginsView", []),
      asked(jobs, "accounts.apiProviders", []),
      asked(jobs, "accounts.machineLogins", []),
      asked(jobs, "accounts.decisionModels", []),
    ) {
    (Some(profiles), Some(logins), Some(providers), Some(machine), Some(models)) => {
      models_asked.val = Some(models)
      Some({
        // (accounts/index.ts `homesReadSoon`: the profiles' homes read again before the view is made)
        homes_read_soon: Some(k => ignore(
          host.rt.fork_daemon("homes read soon", on_error=e => @host.note("homes read soon failed: \{e}"), async fn() {
            ignore(asked(jobs, "accounts.homesReadSoon", []))
            k()
          }),
        )),
        profiles_view: _ => to_jv(profiles),
        logins_view: _ => to_jv(logins),
        api_providers: () => to_jv(providers),
        machine_logins: () => to_jv(machine),
        decision_models: () => to_jv(models),
        automatic_decisions_view: (_, _, _) => decisions.val.map(to_jv),
      })
    }
    _ => None
  }
  let updates = asked(bus.coord_ask.val, "updates.get", [Json::string(lang)])
  // (each connect as its kind shows it and where its connection stands, and every kind made: P5-5's, one ask)
  let states : Map[String, Json] = {}
  let shown : Map[String, Json] = {}
  let kinds : Map[String, Unit] = {}
  match asked(bus.coord_ask.val, "connects.overview", []) {
    Some(Object(o)) => {
      match o.get("kinds") {
        Some(Array(ks)) =>
          for k in ks {
            if k is String(k) {
              kinds[k] = ()
            }
          }
        _ => ()
      }
      match o.get("connects") {
        Some(Array(xs)) =>
          for x in xs {
            if x is { "id": String(id), .. } {
              match x {
                { "connection": st, .. } => states[id] = st
                _ => ()
              }
              match x {
                { "shown": Object(_) as sh, .. } => shown[id] = sh
                _ => ()
              }
            }
          }
        _ => ()
      }
    }
    _ => ()
  }
  let grants = if platform() == "darwin" { asked(bus.ui_ask.val, "grants.view", []) } else { None }
  // (the drive's roots as P5-4 sees them, still.fail Helper's grants for a protected folder among them)
  let root_views : Map[String, Json] = {}
  let drive_of = match viewer {
    { "home": False, "workspace": String(w), .. } => "drive@\{w}"
    _ => "drive"
  }
  match asked(bus.ui_ask.val, drive_of + ".roots", []) {
    Some(Array(xs)) =>
      for x in xs {
        if x is { "path": String(p), .. } {
          root_views[p] = x
        }
      }
    _ => ()
  }
  // (the catalog as P5-3 keeps it, catalog.ts `catalog()`: the file, 126 KB, was read and parsed each overview; read
  // only where none is kept, a P5-1 alone)
  let catalog = match (bus.model_catalog.val)() {
    { "models": Object(m) as models, .. } if !m.is_empty() => models
    _ =>
      match read_json(path([bus.data, "model-catalog.json"])) {
        Some({ "models": Object(_) as m, .. }) => m
        _ => Json::object({})
      }
  }
  // The automatic decisions and the archive policy, last before the overview is made: what it keeps of them a minute
  // is given again without asking (overview.ts `decisionsView`), so they are asked only where it keeps none for this
  // viewer and stamp. One time and one config for the whole overview (`store_now`, `config`), the ones this is judged
  // by, so `decisions_view` finds what was found here.
  let decisions_version = asked(bus.hub_ask.val, "store.decisionsVersion", []).unwrap_or(Json::number(0.0))
  let config_now = (bus.config_raw.val)()
  let overview_now = wall_ms().to_double()
  let viewer_v = @events.Viewer::of(to_jv(viewer))
  // (archive-policy.ts `policyView`'s parts: the week's checks counted by a reader, off the loop as agents.ts
  // `hub.policyChecks` has them, then the view given them; the decisions' models as asked above, not made again)
  let ask_decisions = async fn() {
    decisions.val = asked(jobs, "accounts.automaticDecisionsView", [
      viewer,
      Json::boolean(false),
      models_asked.val.unwrap_or(Json::null()),
    ])
    if p51_manages(viewer) {
      let ws = match viewer {
        { "home": False, "workspace": String(w), .. } => Json::string(w)
        _ => Json::null()
      }
      let checks = (bus.reader_ask.val)(
        "policyChecks",
        {
          "since": Json::number(overview_now - 7.0 * 86_400_000.0),
          "viewer": {
            "workspace": match viewer {
              { "workspace": w, .. } => w
              _ => Json::null()
            },
            "home": match viewer {
              { "home": h, .. } => h
              _ => Json::boolean(true)
            },
          },
        },
        "zh",
      ) catch {
        _ => Json::null()
      }
      policy.val = asked(bus.hub_ask.val, "storage.policyView", [ws, viewer, checks])
    }
  }
  let decisions_fresh = match models_asked.val {
    Some(models) =>
      self.overview_kept.decisions_fresh(viewer_v, to_jv(decisions_version), to_jv(config_now), to_jv(models), overview_now)
    None => false
  }
  if !decisions_fresh {
    ask_decisions()
  }
  // (were what is kept gone by the time the overview looks, another viewer's overview having made it again
  // meanwhile, they are asked then, once: never `prepare_decision_sessions` given back at once with nothing asked)
  let decisions_asked = Ref(!decisions_fresh)
  let deps : @events.OverviewDeps = {
    config: () => to_jv(config_now),
    session_counts: (v, ids) => match (try { Ok(store.overview_session_counts(of_jv(v.raw), ids.map(of_jv))) } catch { e => Err(e) }) {
      Ok({ "total": Number(total, ..), "byConnect": Array(by), .. }) => {
        let m : Map[String, Double] = {}
        for e in by {
          match e {
            Array([String(k), Number(n, ..)]) => m[k] = n
            _ => ()
          }
        }
        Some((total, m))
      }
      _ => None
    },
    // (agents.ts `waitForSessionCounts`: the sessions' counts built where a store from before has none yet)
    wait_for_session_counts: Some(k => ignore(
      host.rt.fork_quiet(name="session counts", async fn() {
        match (try { Ok((bus.reader_ask.val)("$sessionCounts", Json::null(), lang)) } catch { e => Err(e) }) {
          Ok(_) => k(true)
          Err(_) => k(false)
        }
      }),
    )),
    hub_processes: () => match processes {
      Array(items) =>
        items.filter_map(p => match p {
          Array([String(k), String(s)]) => Some((k, s))
          _ => None
        })
      _ => []
    },
    session_ws: key => match (try { Ok(store.session_ws(key)) } catch { e => Err(e) }) {
      Ok(Null) | Err(_) => None
      Ok(ws) => Some(to_jv(ws))
    },
    list_processes: () => match (try { Ok(store.list_processes()) } catch { e => Err(e) }) {
      Ok(ps) => ps.map(to_jv)
      Err(_) => []
    },
    data_dir: bus.data,
    group_memory: (pgids, k) => ignore(
      host.rt.fork_daemon("group memory", on_error=e => @host.note("group memory failed: \{e}"), async fn() {
        let wanted = pgids.filter_map(p => match of_jv(p) { Number(n, ..) => Some(n); _ => None })
        let out : Map[String, Double] = {}
        if wanted.length() > 0 && !is_windows() {
          match run_said(host, "/bin/ps", ["-axo", "pgid=,rss="], 3000) {
            Some(text) =>
              for (pgid, bytes) in @ops_platform.group_memory_of_ps(text, wanted) {
                out[if pgid == pgid.floor() { pgid.to_int64().to_string() } else { pgid.to_string() }] = bytes
              }
            None => ()
          }
        }
        k(out)
      }),
    ),
    disk_room: (p, k) => match disk_of(p) {
      Some((free, total)) => k(to_jv({ "freeBytes": Json::number(free), "totalBytes": Json::number(total) }))
      None => k(@jsjson.JValue::Null)
    },
    store_now: () => overview_now,
    binding: id => match (try { Ok(store.binding(Json::string(id))) } catch { e => Err(e) }) {
      Ok(b) => to_jv(b)
      Err(_) => @jsjson.JValue::Null
    },
    connect_kind: kind => if kinds.contains(kind) {
      Some({
        shown: c => match of_jv(c) {
          { "id": String(id), .. } => to_jv(shown.get(id).unwrap_or(Json::object({})))
          _ => @jsjson.JValue::Obj([])
        },
        connection: c => match of_jv(c) {
          { "id": String(id), .. } => states.get(id).map(to_jv)
          _ => None
        },
      })
    } else {
      None
    },
    accounts,
    updates: match updates {
      Some(u) => Some(_ => to_jv(u))
      None => None
    },
    slack_identities: email => match (try { Ok(store.slack_identities(Json::string(email))) } catch { e => Err(e) }) {
      Ok(ids) => to_jv(Json::array(ids))
      Err(_) => to_jv(Json::array([]))
    },
    root_view: (p, k) => k(to_jv(root_views.get(p).unwrap_or_else(() => @drive.root_view(p).to_json()))),
    homedir: homedir(),
    has_spotlight: platform() == "darwin",
    permissions: match grants {
      Some(Object(g)) =>
        Some(v => {
          let m = g.copy()
          m["request"] = Json::boolean(!p51_read_only(of_jv(v.raw)))
          Some(to_jv(Json::object(m)))
        })
      _ => None
    },
    cloud_state: () => match (bus.cloud_state.val)() {
      Some(s) => Some(to_jv(s))
      None => None
    },
    membership: ws => match (bus.cloud_state.val)() {
      Some(s) =>
        match s {
          { "workspace": String(w), .. } if w == ws => Some(to_jv(s))
          { "joined": Array(j), .. } =>
            j.iter().find_first(x => x is { "workspace": String(w), .. } && w == ws).map(to_jv)
          _ => None
        }
      None => None
    },
    reached: () => (bus.cloud_reached.val)(),
    catalog: () => to_jv(catalog),
    decisions_version: () => to_jv(decisions_version),
    // (the week's checks are a reader's, given to the policy's view asked above: `ask_decisions`)
    policy_checks: None,
    policy_view: (_, _, _, _, _) => to_jv(policy.val.unwrap_or(Json::null())),
    prepare_decision_sessions: k => if decisions_asked.val {
      k()
    } else {
      decisions_asked.val = true
      ignore(
        host.rt.fork_quiet(name="overview decisions", async fn() {
          ask_decisions()
          k()
        }),
      )
    },
    // (hub.ts `prepareSessionChatNames`: the cc index's chat names of these sessions, built before they are shown)
    prepare_session_chat_names: Some((keys, k) => ignore(
      host.rt.fork_quiet(name="session chat names", async fn() {
        ignore((bus.reader_ask.val)("$sessionChatNames", Json::array(keys.map(Json::string(_))), lang)) catch {
          _ => ()
        }
        k()
      }),
    )),
    session_there: key => match (try { Ok(store.get_session(key)) } catch { e => Err(e) }) {
      Ok(Null) | Err(_) => false
      Ok(_) => true
    },
    chat_readable: key => match (try { Ok(store.session_ws(key)) } catch { e => Err(e) }) {
      Ok(String(ws)) => !ws.has_prefix("handed:")
      _ => true
    },
    // (overview.ts `chatTitleOf`: what a session's chat is called in the chat list; its title, else its key)
    chat_title: key => {
      let chat = match threads {
        Some(t) => {
          let c = t.session_chat(Json::string(key)) catch { _ => Json::null() }
          bus.drain_thread_requests(t)
          c
        }
        None => Json::null()
      }
      match chat {
        Object(_) =>
          @adb_devices.chat_title(
            to_jv(jfield(chat, "thread")),
            as_text(jfield(chat, "firstText")),
            None,
            tr(lang, "station.chat.untitled"),
            tr(lang, "station.chat.directMessage"),
          )
        _ =>
          match (try { Ok(store.get_session(key)) } catch { e => Err(e) }) {
            Ok({ "title": String(t), .. }) => t
            _ => key
          }
      }
    },
    rooted: p => p.has_prefix("/") || (p.length() > 2 && p[1] == ':'),
    clean: p => p,
    built_at: bus.built_at,
  }
  let d : @effect.Deferred[Json] = @effect.Deferred::new()
  @events.overview(deps, self.overview_kept, @events.Viewer::of(to_jv(viewer)), lang, r => match r {
    Ok(v) => ignore(d.succeed(of_jv(v)))
    Err(e) => ignore(d.succeed({ "error": Json::string(e) }))
  })
  d.wait()
}

///|
/// services.ts AdminApi: the routes put together on the platform; the parts' routes after them.
async fn P51::admin_live(self : P51) -> AdminLive {
  let bus = self.bus
  let (zh, en) = catalogs_json()
  // (drive/grants.ts `grantKey`: the data directory's own, made the first time)
  let key_file = path([bus.data, "drive-grant.key"])
  let kept = try {
    match self.host.read_bytes(key_file) {
      Some(b) if b.length() >= 32 => Some(b)
      _ => None
    }
  } catch {
    _ => None
  }
  let grant_key = match kept {
    Some(k) => k
    None => {
      let key = @drive.random_bytes(32)
      ignore(self.host.shell("fs.put", { "path": Json::string(key_file), "truncate": true, "mode": 384 }, bytes=key)) catch {
        e => p51_log("WARN", "drive", "the drive's grant key not kept", fields={ "error": Json::string("\{e}") })
      }
      key
    }
  }
  let setup = @api_routes.Setup::new(
    @api_routes.Words::new(to_jv(zh), to_jv(en)),
    bus.version,
    @events.runtime_kinds,
    env_get("STILLFAIL_DEV") == Some("1"),
    Some(bus.data),
    grant_key,
    (bus.lang.val)(),
    // (what is not here: starting a retirement is switched off, retire.ts RETIRE_STARTS; still.fail Helper's grants
    // are a Mac's)
    if platform() == "darwin" { ["retire.starts"] } else { ["retire.starts", "grants"] },
  )
  // (the routes' paths by this machine's rules: ops/paths.ts on Windows is win32's)
  if is_windows() {
    @api_routes.windows_paths(@drive.cwd())
  }
  let holder : Ref[AdminLive?] = Ref(None)
  let backend = @api_routes.Backend::new(
    async fn(name, args) { self.backend(holder.val.unwrap(), name, args) },
    call_bytes=async fn(name, args) { self.backend_bytes(holder.val.unwrap(), name, args) },
  )
  let a : AdminLive = {
    admin: @api_routes.Admin::new(backend, setup),
    files: {},
    next_handle: 0,
    streams: {},
    stream_stops: {},
    next_stream: 0,
  }
  holder.val = Some(a)
  // What the routes start for themselves (a Feishu registration's `save`), once every slice is put together: the agents'
  // door opens after `run` started them all.
  self.fork("admin api", async fn() {
    ignore(bus.door_ready.wait())
    a.admin.start()
  })
  // A part calls back what a route gave it (`{"$fn": id}`), through the bus: `$admin.called` `{id, args}`.
  bus.on_peer("$admin.called", async fn(_, _, params, _) {
    let (id, args) = match params {
      { "id": Number(n, ..), "args": Array(a), .. } => (n.to_int(), a)
      { "id": Number(n, ..), .. } => (n.to_int(), [])
      _ => raise BusError("$admin.called names no callback")
    }
    (of_jv(a.admin.called(id, args.map(to_jv))), None)
  })
  // What a hand-over carries of the messages written under a key (move/live.ts `keptSends`, `keepSends`): those of the
  // threads `{"threads": [[here, there], …]}` here, each under its thread's id there, and those another station kept,
  // kept here (`{"sends": [KeptSend, …]}`).
  bus.on_peer("$admin.keptSends", async fn(_, _, params, _) {
    let threads : Map[Double, Double] = Map([])
    for p in jitems(jfield(params, "threads")) {
      match p {
        [Number(here, ..), Number(there, ..), ..] => threads[here] = there
        _ => ()
      }
    }
    let sends = a.admin.kept_sends(threads).map(s => {
      let headers : Map[String, Json] = Map([])
      for k, v in s.headers {
        headers[k] = Json::string(v)
      }
      let o : Json = {
        "viewer": Json::string(s.viewer),
        "thread": Json::number(s.thread),
        "key": Json::string(s.key),
        "at": Json::number(s.at),
        "status": Json::number(s.status.to_double()),
        "headers": Json::object(headers),
        "body": Json::string(s.body),
      }
      o
    })
    (Json::array(sends), None)
  })
  bus.on_peer("$admin.keepSends", async fn(_, _, params, _) {
    let sends = jitems(jfield(params, "sends")).map(s => {
      let headers : Map[String, String] = Map([])
      match jfield(s, "headers") {
        Object(m) =>
          for k, v in m {
            if v is String(t) {
              headers[k] = t
            }
          }
        _ => ()
      }
      let send : @api_routes.KeptSend = {
        viewer: jtext(s, "viewer").unwrap_or(""),
        thread: jnum_of(s, "thread").unwrap_or(0.0),
        key: jtext(s, "key").unwrap_or(""),
        at: jnum_of(s, "at").unwrap_or(0.0),
        status: jnum_of(s, "status").unwrap_or(0.0).to_int(),
        headers,
        body: jtext(s, "body").unwrap_or(""),
      }
      send
    })
    a.admin.keep_sends(sends)
    (Json::null(), None)
  })
  // GET /overview's value for a viewer, as another part answers with it (a connect moved: connects/workspace.ts's route
  // answers `agents.view`).
  bus.on_peer("$overview", async fn(_, _, params, _) {
    (self.overview(jfield(params, "viewer"), jtext(params, "lang").unwrap_or((bus.lang.val)())), None)
  })
  // The machine's own, where a test with no mesh says so: under `/admin-api/` on the agents' door, as its owner.
  if env_get("STILLFAIL_LOCAL_ADMIN") == Some("1") {
    bus.parts.door({
      prefix: "admin-api",
      request: async fn(r, conn) { self.local_admin(a, r, conn) },
    })
  }
  a
}

///|
/// A request of the admin API answered for `viewer`: the platform's routes, then the parts'.
async fn P51::admin_answer(self : P51, a : AdminLive, r : @api_routes.Request) -> @api_routes.Answer {
  let answer = a.admin.handle(r)
  if answer.status != 404 || !answer.text().contains("no route") {
    return answer
  }
  // The parts' routes (parts.ts), made with what the admin API's routes are given.
  let tools : Json = { "data": Json::string(self.bus.data) }
  for route in self.bus.parts.all_routes(tools) {
    if route.meth != r.verb {
      continue
    }
    guard part_route_match(route.path, r.path) is Some(params) else { continue }
    let body_text = @utf8.decode_lossy(r.body)
    let query : Map[String, Json] = {}
    for q in r.query {
      if !query.contains(q.0) {
        query[q.0] = Json::string(q.1)
      }
    }
    let asked : Json = {
      "method": Json::string(r.verb),
      "path": Json::string(r.path),
      "params": params,
      "query": Json::object(query),
      "queryPairs": Json::array(r.query.map(q => Json::array([Json::string(q.0), Json::string(q.1)]))),
      "search": jopt(r.search),
      "headers": Json::object(Map::from_array(r.headers.map(h => (h.0, Json::string(h.1))))),
      "body": if body_text == "" {
        Json::null()
      } else {
        @json.parse(body_text) catch {
          _ => Json::string(body_text)
        }
      },
      "rawBody": Json::string(body_text),
      "viewer": of_jv(r.viewer),
      "lang": Json::string(r.lang),
    }
    let said = (route.answer)(asked) catch {
      e => return @api_routes.error(500, "\{e}")
    }
    return match said {
      { "status": Number(status, ..), .. } => {
        let body = match said {
          // (a body said as text is the JSON it holds already)
          { "body": String(t), .. } => t
          { "body": b, .. } => b.stringify()
          _ => ""
        }
        let answer = @api_routes.json(status.to_int(), body)
        match said {
          { "headers": Object(hs), .. } =>
            for k, v in hs {
              if v is String(t) {
                answer.headers[k] = t
              }
            }
          _ => ()
        }
        answer
      }
      v => @api_routes.json(200, v.stringify())
    }
  }
  answer
}

///|
/// The admin API on the agents' door (STILLFAIL_LOCAL_ADMIN): `/admin-api/<path>`, the station's owner asking.
async fn P51::local_admin(self : P51, a : AdminLive, r : Request, conn : Json) -> Reply? {
  let full = r.path()
  let sub = full["/admin-api".length():].to_owned()
  let p = if sub == "" { "/" } else { sub }
  let query = match r.query() {
    Some(q) => @api_routes.query_pairs(q)
    None => []
  }
  let home = match (self.bus.cloud_state.val)() {
    Some({ "workspace": String(w), .. }) => w
    _ => ""
  }
  let viewer : Json = {
    "sub": "local",
    "email": "",
    "name": "",
    "role": "owner",
    "workspace": Json::string(home),
    "device": "local",
    "home": true,
  }
  let lang = match r.header("stillfail-lang") {
    Some(l) => lang_of(Some(l))
    None => "zh"
  }
  let req = @api_routes.Request::new(
    r.meth,
    p,
    query,
    r.query().map(q => "?" + q),
    r.headers,
    r.body,
    to_jv(viewer),
    lang,
  )
  let answer = self.admin_answer(a, req)
  let headers = answer.headers.to_array()
  match answer.body {
    Whole(b) => Some({ status: answer.status, headers, body: b })
    Stream(next) | Streamed(next, _) => {
      // (a stream: written as it comes, the connection closed at its end)
      let head = StringBuilder()
      head.write_string("HTTP/1.1 \{answer.status} OK\r\n")
      for h in headers {
        head.write_string("\{h.0}: \{h.1}\r\n")
      }
      head.write_string("connection: close\r\n\r\n")
      if !write_on(self.host, conn, @utf8.encode(head.to_string())) {
        return None
      }
      // (until its pieces end, not as the station is told to stop: a stream let go of before the events are handed
      // over would be no listener of them, and the next process would take up none)
      while true {
        match (try { Ok(next()) } catch { e => Err(e) }) {
          Ok(Some(piece)) => if !write_on(self.host, conn, piece) { break }
          _ => break
        }
      }
      match answer.body {
        Streamed(_, stop) => stop() catch { _ => () }
        _ => ()
      }
      self.host.tcp_close(conn)
      None
    }
  }
}

///|
/// Whether a part's route (`path`: a pattern beginning `^`, or Express's segments, `:name` one and `*` the rest) is
/// this request's path: its parameters (a pattern's groups in order, a segment path's by name), or None.
fn part_route_match(pattern : String, p : String) -> Json? {
  if pattern.has_prefix("^") {
    match @api_routes.re(pattern).exec(p) {
      Some(found) =>
        Some(Json::array(found[1:].to_array().map(g => match g { Some(s) => Json::string(s); None => Json::null() })))
      None => None
    }
  } else {
    let want = pattern.split("/").map(x => x.to_owned()).filter(x => x != "").to_array()
    let have = p.split("/").map(x => x.to_owned()).filter(x => x != "").to_array()
    let named : Map[String, Json] = {}
    for i, w in want {
      if w == "*" {
        named["*"] = Json::string(have[i:].to_array().join("/"))
        return Some(Json::object(named))
      }
      guard i < have.length() else { return None }
      if w.has_prefix(":") {
        named[w[1:].to_owned()] = Json::string(@api_routes.decode_uri_component(have[i]).unwrap_or(have[i]))
      } else if w != have[i] {
        return None
      }
    }
    if want.length() != have.length() {
      return None
    }
    Some(Json::object(named))
  }
}
