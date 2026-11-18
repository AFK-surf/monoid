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
fn jv_of_json(j : Json) -> @api_routes.JV {
  match j {
    Null => Null
    True => Bool(true)
    False => Bool(false)
    Number(n, ..) => Num(n)
    String(s) => Str(s)
    Array(a) => Arr(a.map(jv_of_json))
    Object(m) => Obj(m.to_array().map(kv => (kv.0, jv_of_json(kv.1))))
  }
}

///|
fn json_of_jv(v : @api_routes.JV) -> Json {
  match v {
    Null => Json::null()
    Bool(b) => Json::boolean(b)
    Num(n) => Json::number(n)
    Str(s) => Json::string(s)
    Arr(a) => Json::array(a.map(json_of_jv))
    Obj(fields) => {
      let m : Map[String, Json] = {}
      for f in fields {
        m[f.0] = json_of_jv(f.1)
      }
      Json::object(m)
    }
  }
}

///|
priv struct AdminLive {
  admin : @api_routes.Admin
  /// What the routes hold by reference (a hash being made).
  handles : Map[String, @buffer.Buffer]
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
/// `length` bytes of `file` from `from` (fewer at its end), read by the shell.
fn p51_file_piece(host : @host.Host, file : String, from : Double, length : Int) -> Bytes raise {
  if length <= 0 {
    return b""
  }
  match host.shell_sync("fs.bytes", { "path": Json::string(file), "from": Json::number(from), "length": Json::number(length.to_double()) }) {
    String(hex) => @cloud_lock.hex_bytes(hex)
    { "error": String(e), .. } => raise @api_routes.Thrown("Error", jv_of_json({ "message": Json::string(e) }))
    _ => raise @api_routes.Thrown("Error", jv_of_json({ "message": "ENOENT: no such file or directory, open '\{file}'", "code": "ENOENT" }))
  }
}

///|
/// read/sessions.ts `mime`: a file's type by its extension (Path::extension's: none for a name with no dot, or only the
/// one it starts with).
fn p51_mime(p : String) -> String {
  let mut name = p
  match name.rev_find("/") {
    Some(i) => name = name[i + 1:].to_owned()
    None => ()
  }
  match name.rev_find("\\") {
    Some(i) => name = name[i + 1:].to_owned()
    None => ()
  }
  let dot = name.rev_find(".").unwrap_or(-1)
  if dot <= 0 {
    return "application/octet-stream"
  }
  match name[dot + 1:].to_owned().to_lower() {
    "png" => "image/png"
    "jpg" | "jpeg" => "image/jpeg"
    "gif" => "image/gif"
    "webp" => "image/webp"
    "svg" => "image/svg+xml"
    "pdf" => "application/pdf"
    "txt" => "text/plain; charset=utf-8"
    "md" => "text/markdown; charset=utf-8"
    "json" => "application/json"
    _ => "application/octet-stream"
  }
}

///|
/// Whether a viewer manages the station, and whether one only reads (api_routes' `manages_station`, `read_only`).
fn p51_manages(viewer : Json) -> Bool {
  @api_routes.manages_station(jv_of_json(viewer))
}

///|
fn p51_read_only(viewer : Json) -> Bool {
  @api_routes.read_only(jv_of_json(viewer))
}

///|
/// A file system's failure as the routes take it (fs.mbt: an `Error` with its `code`), anything else as it was.
fn p51_fs_thrown(e : Error) -> Error {
  match e {
    @drive.FsError(f) =>
      @api_routes.Thrown("Error", jv_of_json({ "message": Json::string(f.message), "code": Json::string(f.code) }))
    other => other
  }
}

///|
/// The system's error number `n` of `call` on `p` (live_p5_2_sys.c's), as Node throws it.
fn p51_errno_thrown(n : Int, call : String, p : String) -> Error {
  let (code, words) = match n {
    1 => ("EPERM", "operation not permitted")
    2 => ("ENOENT", "no such file or directory")
    13 => ("EACCES", "permission denied")
    17 => ("EEXIST", "file already exists")
    20 => ("ENOTDIR", "not a directory")
    21 => ("EISDIR", "illegal operation on a directory")
    28 => ("ENOSPC", "no space left on device")
    _ => ("EIO", "i/o error")
  }
  @api_routes.Thrown("Error", jv_of_json({ "message": Json::string("\{code}: \{words}, \{call} '\{p}'"), "code": Json::string(code) }))
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
/// The station's parts as the routes ask them (api_routes `Backend`).
async fn P51::backend(self : P51, a : AdminLive, name : String, args : Array[@api_routes.JV]) -> @api_routes.JV {
  let bus = self.bus
  let arg = (i : Int) => json_of_jv(args.get(i).unwrap_or(Null))
  let text = (i : Int) => match args.get(i) {
    Some(Str(s)) => s
    _ => ""
  }
  // A hash being made (`crypto.createHash` and what is asked of its handle).
  if name.has_prefix("h:") {
    let (handle, call) = match name.rev_find(".") {
      Some(i) => (name[:i].to_owned(), name[i + 1:].to_owned())
      None => (name, "")
    }
    guard a.handles.get(handle) is Some(buf) else { raise @api_routes.Thrown("Error", jv_of_json({ "message": "no handle \{handle}" })) }
    match call {
      "update" => {
        match @api_routes.bytes_of(args.get(0).unwrap_or(Null)) {
          Some(b) => buf.write_bytes(b)
          None => buf.write_bytes(@utf8.encode(text(0)))
        }
        return @api_routes.jref(handle)
      }
      "digest" => {
        a.handles.remove(handle)
        let digest = @cloud_lock.sha256(buf.to_bytes())
        return if text(0) == "hex" { Str(@cloud_lock.hex_of(digest)) } else { @api_routes.jbytes(digest) }
      }
      _ => raise @api_routes.Thrown("Error", jv_of_json({ "message": "no call \{call} of a hash" }))
    }
  }
  // A file the routes opened (`fs.open`): its size, a piece of it, let go.
  if name.has_prefix("fh:") {
    let (handle, call) = match name.rev_find(".") {
      Some(i) => (name[:i].to_owned(), name[i + 1:].to_owned())
      None => (name, "")
    }
    guard a.files.get(handle) is Some(file) else {
      raise @api_routes.Thrown("Error", jv_of_json({ "message": "EBADF: bad file descriptor", "code": "EBADF" }))
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
        return jv_of_json({ "bytesRead": Json::number(n.to_double()), "buffer": json_of_jv(@api_routes.jbytes(out.to_bytes())) })
      }
      "close" => {
        a.files.remove(handle)
        return Null
      }
      _ => raise @api_routes.Thrown("Error", jv_of_json({ "message": "no call \{call} of a file" }))
    }
  }
  // A part's card choice (`parts.cardChoiceOf`'s): whether a member may choose on it, and what is done once they did.
  if name.has_prefix("card:") {
    let (handle, call) = match name.rev_find(".") {
      Some(i) => (name[5:i].to_owned(), name[i + 1:].to_owned())
      None => (name[5:].to_owned(), "")
    }
    guard bus.parts.card_choice_named(handle) is Some(choice) else {
      raise @api_routes.Thrown("Error", jv_of_json({ "message": "no card choice \{handle}" }))
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
      _ => raise @api_routes.Thrown("Error", jv_of_json({ "message": "no call \{call} of a card choice" }))
    }
  }
  // The page's restart, asked first (`restart`) and then told (`restart.go`) once its answer is on its way.
  if name == "restart.go" {
    match self.restart_pid() {
      Some(pid) => {
        let front = bus.restart_front
        ignore(
          self.host.rt.fork(name="restart", async fn() {
            @effect.sleep(150) // timer: a deadline (the answer's time to leave before the process ends)
            match front {
              Some(f) => f()
              None => ignore(kill(pid, "SIGUSR2"))
            }
          }),
        )
      }
      None => ()
    }
    return Null
  }
  match name {
    "readers.readBytes" => {
      let readers = self.readers.unwrap()
      let background = match arg(3) {
        { "background": True, .. } => true
        _ => false
      }
      let got = readers.read_bytes(text(0), arg(1), text(2), background~) catch {
        ReadFailed(status, m) => raise @api_routes.Thrown("HttpError", jv_of_json({ "message": Json::string(m), "status": Json::number(status.to_double()) }))
        e => raise e
      }
      @api_routes.jbytes(got)
    }
    "readers.names.set" => {
      match (args.get(0), args.get(1)) {
        (Some(Str(email)), Some(Str(n))) => self.readers.unwrap().names[email] = n
        _ => ()
      }
      Null
    }
    "clock.currentTimeMillisUnsafe" => Num(wall_ms().to_double())
    "crypto.randomBytes" => {
      let n = match args.get(0) {
        Some(Num(n)) => n.to_int()
        _ => 16
      }
      @api_routes.jbytes(@drive.random_bytes(n))
    }
    "crypto.createHash" => {
      a.next_handle += 1
      let handle = "h:\{a.next_handle}"
      a.handles[handle] = @buffer.new()
      @api_routes.jref(handle)
    }
    "os.homedir" => Str(homedir())
    "os.totalmem" =>
      match machine() {
        { "totalmem": Number(n, ..), .. } => Num(n)
        _ => Num(0.0)
      }
    "os.cpus" =>
      match machine() {
        { "cpus": Array(c), .. } => jv_of_json(Json::array(c))
        _ => Arr([])
      }
    "config.raw" => jv_of_json((bus.config_raw.val)())
    "config.updateSoon" => {
      let next = arg(0)
      ignore((bus.config_update.val)(_ => next))
      Null
    }
    "host.sample" => jv_of_json((bus.host_sample.val)())
    "cloud.memberships" => jv_of_json((bus.cloud_call.val)("memberships", Json::null()))
    "cloud.reload" => {
      ignore((bus.cloud_call.val)("reload", Json::null()))
      Null
    }
    "events.open" => {
      guard self.events is Some(events) else { raise @api_routes.Thrown("HttpError", jv_of_json({ "message": "events not ready", "status": 503 })) }
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
        since: match arg(5) {
          String(s) => Some(s)
          _ => None
        },
        brief: arg(6) is True,
        logins: match arg(7) {
          Array(l) => l.filter_map(x => match x { String(s) => Some(s); _ => None })
          _ => []
        },
        running: arg(8) is True,
        shared: arg(9) is True,
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
      jv_of_json({ "status": 200, "headers": Json::object(h), "body": { "$stream": Json::number(sid.to_double()) } })
    }
    "events.overviewChanged" => {
      (bus.overview_changed.val)()
      Null
    }
    "events.presetsChanged" => {
      match self.events {
        Some(e) => e.events.presets_changed()
        None => ()
      }
      Null
    }
    "events.tell" => {
      (bus.events_tell.val)(text(0), arg(1), text(2), arg(3))
      Null
    }
    "$stream.next" => {
      let id = match args.get(0) {
        Some(Num(n)) => n.to_int()
        _ => -1
      }
      guard a.streams.get(id) is Some(next) else { return Null }
      match next() {
        Some(b) => @api_routes.jbytes(b)
        None => {
          a.streams.remove(id)
          a.stream_stops.remove(id)
          Null
        }
      }
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
          jv_of_json({
            "size": Json::number(st.size),
            "mtimeMs": Json::number(st.mtime_ms),
            "file": Json::boolean(st.kind == "file"),
            "dir": Json::boolean(st.kind == "dir" || st.kind == "directory"),
          })
        }
        _ => raise @api_routes.Thrown("Error", jv_of_json({ "message": "ENOENT: no such file or directory, stat '\{p}'", "code": "ENOENT" }))
      }
    }
    "fs.readFile" => @api_routes.jbytes(@drive.read_all(text(0)) catch { e => raise p51_fs_thrown(e) })
    "fs.writeFile" => {
      let data = @api_routes.bytes_of(args.get(1).unwrap_or(Null)).unwrap_or_else(() => @utf8.encode(text(1)))
      let (excl, mode) = match arg(2) {
        Object(o) =>
          (
            o.get("flag") is Some(String("wx" | "xw")),
            match o.get("mode") {
              Some(Number(m, ..)) => m.to_int()
              _ => 0
            },
          )
        _ => (false, 0)
      }
      let n = live_write_flags_ffi(live_c(text(0)), data, mode, if excl { 1 } else { 0 })
      if n != 0 {
        raise p51_errno_thrown(n, "open", text(0))
      }
      Null
    }
    "fs.appendFile" => {
      let data = @api_routes.bytes_of(args.get(1).unwrap_or(Null)).unwrap_or_else(() => @utf8.encode(text(1)))
      let n = live_append_ffi(live_c(text(0)), data)
      if n != 0 {
        raise p51_errno_thrown(n, "open", text(0))
      }
      Null
    }
    "fs.access" => {
      ignore(@drive.stat(text(0)) catch { e => raise p51_fs_thrown(e) })
      Null
    }
    "fs.readdir" => {
      let dir = text(0)
      let names = @drive.names(dir) catch { e => raise p51_fs_thrown(e) }
      if arg(1) is { "withFileTypes": True, .. } {
        // (a Dirent as the routes take it, `{name, file, dir}`: a link is neither, as Node's isFile and isDirectory)
        jv_of_json(
          Json::array(
            names.map(n => {
              let st = attempt(() => @drive.lstat(path([dir, n])))
              {
                "name": Json::string(n),
                "file": Json::boolean(st is Ok(x) && x.file),
                "dir": Json::boolean(st is Ok(x) && x.dir),
              }
            }),
          ),
        )
      } else {
        Arr(names.map(n => @api_routes.JV::Str(n)))
      }
    }
    "fs.copyFile" => {
      // (Node's mode: COPYFILE_EXCL, 1, only where nothing is; else what is there replaced, FICLONE or not)
      let mode = match args.get(2) {
        Some(Num(n)) => n.to_int()
        _ => 0
      }
      if (mode & 1) != 0 {
        @drive.copy_file(text(0), text(1)) catch {
          e => raise p51_fs_thrown(e)
        }
      } else {
        copy_file_over(text(0), text(1)) catch {
          e => raise p51_fs_thrown(e)
        }
      }
      Null
    }
    "fs.rename" => {
      @drive.rename(text(0), text(1)) catch {
        e => raise p51_fs_thrown(e)
      }
      Null
    }
    "fs.rm" => {
      if !(arg(1) is { "force": True, .. }) {
        match attempt(() => @drive.lstat(text(0))) {
          Err(e) => raise p51_fs_thrown(e)
          Ok(_) => ()
        }
      }
      ignore(remove_tree(text(0)))
      Null
    }
    "fs.statfs" =>
      match disk_of(text(0)) {
        Some((free, total)) =>
          jv_of_json({ "blocks": Json::number(total), "bavail": Json::number(free), "bsize": Json::number(1.0) })
        None => raise p51_errno_thrown(2, "statfs", text(0))
      }
    "fs.open" => {
      let p = text(0)
      match (try { Ok(self.fs.lstat(p)) } catch { e => Err(e) }) {
        Ok(Some(_)) => ()
        _ => raise @api_routes.Thrown("Error", jv_of_json({ "message": "ENOENT: no such file or directory, open '\{p}'", "code": "ENOENT" }))
      }
      a.next_handle += 1
      let handle = "fh:\{a.next_handle}"
      a.files[handle] = p
      @api_routes.jref(handle)
    }
    "drive/fs.readAt" => {
      // (a handle `fs.open` gave, where to start, how much): the bytes there, fewer at the file's end
      let handle = @api_routes.ref_of(args.get(0).unwrap_or(Null)).unwrap_or("")
      guard a.files.get(handle) is Some(file) else {
        raise @api_routes.Thrown("Error", jv_of_json({ "message": "EBADF: bad file descriptor", "code": "EBADF" }))
      }
      let num = (i : Int) => match args.get(i) {
        Some(Num(n)) => n
        _ => 0.0
      }
      @api_routes.jbytes(p51_file_piece(self.host, file, num(1), num(2).to_int()))
    }
    // (lock.ts `admit` of the lock in force where `state` says, `vault.lock`'s: the device and role it admits)
    "cloud/lock.admit" => {
      guard self.plane is Some(plane) else { raise @api_routes.Thrown("Error", jv_of_json({ "message": "no control plane" })) }
      let ws = match arg(0) {
        { "ws": String(w), .. } if Some(w) != plane.cloud.home() => Some(w)
        _ => None
      }
      guard plane.cloud.locked(ws~) is Some({ state: Some(st), .. }) else {
        raise @api_routes.Thrown("Error", jv_of_json({ "message": "this workspace keeps no lock" }))
      }
      let now = match args.get(2) {
        Some(Num(n)) => n
        _ => wall_ms().to_double() / 1000.0
      }
      let (device, role) = @cloud_lock.admit(plane.crypto, st, who_of(arg(1)), now) catch {
        e => raise @api_routes.Thrown("Error", jv_of_json({ "message": Json::string("\{e}") }))
      }
      let d : Map[String, Json] = { "id": Json::string(device.id), "sub": Json::string(device.sub), "kind": Json::string(device.kind) }
      match device.by {
        Some(b) => d["by"] = Json::string(b)
        None => ()
      }
      match device.sign_key {
        Some(k) => d["sign_key"] = Json::string(k)
        None => ()
      }
      jv_of_json({ "device": Json::object(d), "role": Json::string(role) })
    }
    "read/sessions.mime" => Str(p51_mime(text(0)))
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
        JoinRefused(kind, m) => raise @api_routes.Thrown(kind, jv_of_json({ "message": Json::string(m) }))
        e => raise @api_routes.Thrown("Error", jv_of_json({ "message": Json::string("\{e}") }))
      }
      jv_of_json(joined)
    }
    "fs.mkdir" => {
      ignore(attempt(() => @drive.mkdir(text(0), true)))
      Null
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
      jv_of_json({ "$stream": Json::number(sid.to_double()) })
    }
    "agents.overview" => jv_of_json(self.overview(arg(0), text(1)))
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
    "store.getSession" => jv_of_json(bus.store.get_session(text(0)))
    "hub.store.getSession" => jv_of_json(bus.store.get_session(text(0)))
    "store.sessionWs" =>
      match bus.store.session_ws(text(0)) {
        Null => @api_routes.jundef
        ws => jv_of_json(ws)
      }
    "store.getJob" => jv_of_json(bus.store.get_job(arg(0)))
    "store.handedTo" => jv_of_json(bus.store.handed_to(text(0)))
    "store.homeChat" => jv_of_json(bus.store.home_chat(arg(0)))
    "store.threadSessions" => {
      let rows = bus.db.all("SELECT * FROM thread_sessions WHERE thread = ? ORDER BY joined_at, rowid", [arg(0)])
      Arr(
        rows.map(r => {
          jv_of_json({
            "thread": r.get("thread").unwrap_or(Json::null()),
            "session": r.get("session").unwrap_or(Json::null()),
            "connect": r.get("connect").unwrap_or(Json::null()),
            "joinedAt": r.get("joined_at").unwrap_or(Json::null()),
            "leftAt": r.get("left_at").unwrap_or(Json::null()),
          })
        }),
      )
    }
    "store.told" => {
      match arg(0) {
        Array(changes) => bus.store.told(changes)
        c => bus.store.told([c])
      }
      Null
    }
    "hub.store.binding" => jv_of_json(bus.store.binding(arg(0)))
    "store.getThread" =>
      match bus.db.all("SELECT * FROM threads WHERE id = ?", [arg(0)]) {
        [r, ..] => {
          let c = (k : String) => r.get(k).unwrap_or(Json::null())
          jv_of_json({
            "id": c("id"),
            "surface": c("surface"),
            "channel": c("channel"),
            "threadTs": c("thread_ts"),
            "title": c("title"),
            "autoTitle": c("auto_title"),
            "createdBy": c("created_by"),
            "createdAt": c("created_at"),
            "home": c("home"),
            "hiddenAt": c("hidden_at"),
            "hiddenBy": c("hidden_by"),
            "shownAt": c("shown_at"),
          })
        }
        _ => Null
      }
    "store.setThreadTitle" => {
      bus.store.set_thread_title(arg(0), arg(1))
      Null
    }
    "runtimeView.runtimeView" => {
      // (what a client from before takes of a shape: the runtimes it knows, events/compat.mbt)
      let supported : Map[String, Unit] = {}
      match arg(2) {
        { "$set": Array(kinds), .. } =>
          for k in kinds {
            if k is String(x) {
              supported[x] = ()
            }
          }
        _ => ()
      }
      match @events.runtime_view(jv(arg(0)), Some(jv(arg(1))), supported) {
        Omit => jv_of_json({ "$omit": true })
        Value(Some(v)) => jv_of_json(of_jv(v))
        Value(None) => @api_routes.jundef
      }
    }
    "device/tools.accessOf" =>
      match arg(0) {
        { "tools": { "access": String(a), .. }, .. } if a == "off" || a == "read" || a == "full" => Str(a)
        _ => Str("off")
      }
    "mesh/settings.networkView" => jv_of_json(@mesh_runtime.network_view(Some(arg(0))))
    "read/machine.roots" => {
      let home = env_get("HOME").unwrap_or(".")
      let codex = match env_get("CODEX_HOME") {
        Some(c) if c != "" => c
        _ => path([home, ".codex"])
      }
      jv_of_json({ "claude": Json::string(path([home, ".claude", "projects"])), "codex": Json::string(path([codex, "sessions"])) })
    }
    // (std::io::Error as anyhow shows it: read/sessions.ts `ioMessage`)
    "read/sessions.ioMessage" =>
      match arg(0) {
        { "code": String("ENOENT"), .. } => Str("No such file or directory (os error 2)")
        { "code": String("EACCES"), .. } => Str("Permission denied (os error 13)")
        { "code": String("EISDIR"), .. } => Str("Is a directory (os error 21)")
        { "code": String("EPERM"), .. } => Str("Operation not permitted (os error 1)")
        { "message": String(m), .. } => Str(m)
        _ => Str("")
      }
    _ => {
      // Another slice's: asked through the bus with the arguments as JSON; what it refuses thrown as its kind.
      let asked = Json::array(args.map(json_of_jv))
      let ask = match slice_of(name) {
        "jobs" => bus.jobs_ask.val
        "ui" => bus.ui_ask.val
        "coord" => bus.coord_ask.val
        _ => bus.hub_ask.val
      }
      match (try { Ok(ask(name, asked)) } catch { e => Err(e) }) {
        Ok(v) => jv_of_json(v)
        Err(@api_routes.Thrown(_, _) as t) => raise t
        // (P5-4's refusals carry their kind and what the route reads of them: a drive's code, a vault's need)
        Err(P54Refused(kind, said)) => raise @api_routes.Thrown(kind, jv_of_json(said))
        // (a file system's refusal keeps its code: ENOENT, EEXIST, what `ioMessage` and an exclusive write read)
        Err(@session_chats.Thrown(code, m)) =>
          raise @api_routes.Thrown(
            "Error",
            jv_of_json(
              if code == "" {
                { "message": Json::string(m) }
              } else {
                { "message": Json::string(m), "code": Json::string(code) }
              },
            ),
          )
        Err(@drive.FsError(_) as e) => raise p51_fs_thrown(e)
        Err(e) => raise @api_routes.Thrown("Error", jv_of_json({ "message": Json::string(said_of(e)) }))
      }
    }
  }
}

///|
/// GET /overview (sessions/agents.ts `view`): the agents' side's where it makes one, else the platform's
/// (api/overview.ts), with the fields the station's parts add (parts.ts `overviewOf`).
async fn P51::overview(self : P51, viewer : Json, lang : String) -> Json {
  let bus = self.bus
  let made = (bus.hub_ask.val)("overview", { "viewer": viewer, "lang": Json::string(lang) }) catch { _ => Json::null() }
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
/// api/overview.ts `overview`, of what the platform has: the control plane, the connects config.json names, the
/// sessions counted, the agents' processes, the disk, the drive's roots, the memberships.
async fn P51::platform_overview(self : P51, viewer : Json, lang : String) -> Json {
  let bus = self.bus
  let store = bus.store
  let host = self.host
  let processes = (bus.hub_ask.val)("processes", Json::null()) catch { _ => Json::null() }
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
  let accounts : @events.AccountsDeps? = match
    (
      asked(jobs, "accounts.profilesView", [viewer]),
      asked(jobs, "accounts.loginsView", []),
      asked(jobs, "accounts.apiProviders", []),
      asked(jobs, "accounts.machineLogins", []),
      asked(jobs, "accounts.decisionModels", []),
    ) {
    (Some(profiles), Some(logins), Some(providers), Some(machine), Some(models)) => {
      let decisions = asked(jobs, "accounts.automaticDecisionsView", [viewer, Json::boolean(false)])
      Some({
        homes_read_soon: None,
        profiles_view: _ => jv(profiles),
        logins_view: _ => jv(logins),
        api_providers: () => jv(providers),
        machine_logins: () => jv(machine),
        decision_models: () => jv(models),
        automatic_decisions_view: (_, _, _) => decisions.map(jv),
      })
    }
    _ => None
  }
  let updates = asked(bus.coord_ask.val, "updates.get", [Json::string(lang)])
  let states : Map[String, Json] = {}
  match asked(bus.coord_ask.val, "connects.states", []) {
    Some(Array(xs)) =>
      for x in xs {
        match x {
          { "id": String(id), "connection": st, .. } => states[id] = st
          _ => ()
        }
      }
    _ => ()
  }
  let kinds : Map[String, Unit] = {}
  match asked(bus.coord_ask.val, "connects.states", []) {
    Some(Array(xs)) =>
      for x in xs {
        if x is { "kind": String(k), .. } {
          kinds[k] = ()
        }
      }
    _ => ()
  }
  let grants = if platform() == "darwin" { asked(bus.ui_ask.val, "grants.view", []) } else { None }
  let decisions_version = asked(bus.hub_ask.val, "store.decisionsVersion", []).unwrap_or(Json::number(0.0))
  let policy = if p51_manages(viewer) {
    let ws = match viewer {
      { "home": False, "workspace": String(w), .. } => Json::string(w)
      _ => Json::null()
    }
    asked(bus.hub_ask.val, "storage.policyView", [ws, viewer])
  } else {
    None
  }
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
  let catalog = match read_json(path([bus.data, "model-catalog.json"])) {
    Some({ "models": Object(_) as m, .. }) => m
    _ => Json::object({})
  }
  let deps : @events.OverviewDeps = {
    config: () => jv((bus.config_raw.val)()),
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
    wait_for_session_counts: None,
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
      Ok(ws) => Some(jv(ws))
    },
    list_processes: () => match (try { Ok(store.list_processes()) } catch { e => Err(e) }) {
      Ok(ps) => ps.map(jv)
      Err(_) => []
    },
    data_dir: bus.data,
    group_memory: (pgids, k) => ignore(
      host.rt.fork(name="group memory", async fn() {
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
      Some((free, total)) => k(jv({ "freeBytes": Json::number(free), "totalBytes": Json::number(total) }))
      None => k(@jsjson.Null)
    },
    store_now: () => wall_ms().to_double(),
    binding: id => match (try { Ok(store.binding(Json::string(id))) } catch { e => Err(e) }) {
      Ok(b) => jv(b)
      Err(_) => @jsjson.Null
    },
    connect_kind: kind => if kinds.contains(kind) {
      Some({
        shown: _ => @jsjson.Obj([]),
        connection: c => match of_jv(c) {
          { "id": String(id), .. } => states.get(id).map(jv)
          _ => None
        },
      })
    } else {
      None
    },
    accounts,
    updates: match updates {
      Some(u) => Some(_ => jv(u))
      None => None
    },
    slack_identities: email => match (try { Ok(store.slack_identities(Json::string(email))) } catch { e => Err(e) }) {
      Ok(ids) => jv(Json::array(ids))
      Err(_) => jv(Json::array([]))
    },
    root_view: (p, k) => k(jv(root_views.get(p).unwrap_or_else(() => @drive.root_view(p).to_json()))),
    homedir: homedir(),
    has_spotlight: platform() == "darwin",
    permissions: match grants {
      Some(Object(g)) =>
        Some(v => {
          let m = g.copy()
          m["request"] = Json::boolean(!p51_read_only(of_jv(v.raw)))
          Some(jv(Json::object(m)))
        })
      _ => None
    },
    cloud_state: () => match (bus.cloud_state.val)() {
      Some(s) => Some(jv(s))
      None => None
    },
    membership: ws => match (bus.cloud_state.val)() {
      Some(s) =>
        match s {
          { "workspace": String(w), .. } if w == ws => Some(jv(s))
          { "joined": Array(j), .. } =>
            j.iter().find_first(x => x is { "workspace": String(w), .. } && w == ws).map(jv)
          _ => None
        }
      None => None
    },
    reached: () => (bus.cloud_reached.val)(),
    catalog: () => jv(catalog),
    decisions_version: () => jv(decisions_version),
    // (the checks are counted in the policy's view itself, session_storage `policy_view`)
    policy_checks: None,
    policy_view: (_, _, _, _, _) => jv(policy.unwrap_or(Json::null())),
    prepare_decision_sessions: k => k(),
    prepare_session_chat_names: None,
    session_there: key => match (try { Ok(store.get_session(key)) } catch { e => Err(e) }) {
      Ok(Null) | Err(_) => false
      Ok(_) => true
    },
    chat_readable: key => match (try { Ok(store.session_ws(key)) } catch { e => Err(e) }) {
      Ok(String(ws)) => !ws.has_prefix("handed:")
      _ => true
    },
    chat_title: key => match (try { Ok(store.get_session(key)) } catch { e => Err(e) }) {
      Ok({ "title": String(t), .. }) => t
      _ => ""
    },
    rooted: p => p.has_prefix("/") || (p.length() > 2 && p[1] == ':'),
    clean: p => p,
  }
  let d : @effect.Deferred[Json] = @effect.Deferred::new()
  @events.overview(deps, @events.OverviewKept::new(), @events.Viewer::of(jv(viewer)), lang, r => match r {
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
    match self.host.shell_sync("fs.bytes", { "path": Json::string(key_file) }) {
      String(hex) if hex.length() >= 64 => Some(@cloud_lock.hex_bytes(hex))
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
    @api_routes.Words::new(jv_of_json(zh), jv_of_json(en)),
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
  let backend = @api_routes.Backend::new(async fn(name, args) { self.backend(holder.val.unwrap(), name, args) })
  let a : AdminLive = {
    admin: @api_routes.Admin::new(backend, setup),
    handles: {},
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
    (json_of_jv(a.admin.called(id, args.map(jv_of_json))), None)
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
      "search": match r.search {
        Some(s) => Json::string(s)
        None => Json::null()
      },
      "headers": Json::object(Map::from_array(r.headers.map(h => (h.0, Json::string(h.1))))),
      "body": if body_text == "" {
        Json::null()
      } else {
        @json.parse(body_text) catch {
          _ => Json::string(body_text)
        }
      },
      "rawBody": Json::string(body_text),
      "viewer": json_of_jv(r.viewer),
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
    jv_of_json(viewer),
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
      while !self.bus.stopped.is_done() {
        match (try { Ok(next()) } catch { e => Err(e) }) {
          Ok(Some(piece)) => if !write_on(self.host, conn, piece) { break }
          _ => break
        }
      }
      match answer.body {
        Streamed(_, stop) => stop() catch { _ => () }
        _ => ()
      }
      ignore(self.host.shell("tcp.close", { "id": conn })) catch {
        _ => ()
      }
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
