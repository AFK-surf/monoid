// P5-1's device tools (src/device/tools.ts, mesh/tools.ts): what the control plane's gateways may do on this machine
// (contract v1 §8), over `comma/tools/1` or the presence socket, as config.json's `tools.access` lets them (`off` by
// default, `read`, `full`): a command run, a file read, written, listed or looked at, a process started and followed,
// the runtimes there; never the station's own data or the machine's logins. A chat they start or drive is the agents'
// side's (`hub_ask`).

///|
let tools_output_cap : Int = 1048576

///|
let tools_read_cap : Int = 8388608

///|
let tools_process_keep : Int = 4194304

///|
let tools_processes_most : Int = 32

///|
let tools_read_ops : Array[String] = ["fs.read", "fs.list", "fs.stat", "runtime.probe", "process.list", "process.tail", "session.status"]

///|
let tools_ops : Array[String] = [
  "exec", "fs.read", "fs.write", "fs.list", "fs.stat", "process.start", "process.write", "process.tail", "process.stop",
  "process.list", "runtime.probe", "session.start", "session.say", "session.status",
]

///|
priv suberror ToolFailed {
  ToolFailed(String, String)
}

///|
/// Its words where it is said (`to_string`, a notice, a log): not its type's name (`station/<package>.<Type>`).
impl Show for ToolFailed with output(self, logger) {
  match self {
    ToolFailed(_, m) => logger.write_string(m)
  }
}

///|
priv struct KeptProcess {
  id : String
  command : String
  proc : Proc
  started_at : Double
  chunks : Array[Bytes]
  mut base : Int
  mut total : Int
  mut exited : Bool
  mut exit_code : Int?
}

///|
priv struct DeviceTools {
  p : P51
  processes : Array[KeptProcess]
  mut next : Int
}

///|
fn tool_str(a : Json, k : String) -> String? {
  match a {
    Object(m) =>
      match m.get(k) {
        Some(String(s)) => Some(s)
        _ => None
      }
    _ => None
  }
}

///|
fn tool_need(a : Json, k : String) -> String raise ToolFailed {
  match tool_str(a, k) {
    Some(s) => s
    None => raise ToolFailed("invalid_request", "\{k} is required")
  }
}

///|
fn tool_int(a : Json, k : String) -> Int? {
  match a {
    Object(m) =>
      match m.get(k) {
        Some(Number(n, ..)) if n == n.floor() && n >= 0.0 => Some(n.to_int())
        _ => None
      }
    _ => None
  }
}

///|
fn tool_env(a : Json) -> Array[(String, String)] raise ToolFailed {
  match a {
    Object(m) =>
      match m.get("env") {
        None | Some(Null) => []
        Some(Object(e)) => {
          let out = []
          for k, v in e {
            match v {
              String(s) => out.push((k, s))
              _ => raise ToolFailed("invalid_request", "env must be a map of strings")
            }
          }
          out
        }
        _ => raise ToolFailed("invalid_request", "env must be a map of strings")
      }
    _ => []
  }
}

///|
fn within_path(p : String, root : String) -> Bool {
  let s = sep()
  p == root || p.has_prefix(if root.has_suffix(s) { root } else { root + s })
}

///|
/// `p` as an op may use it: absolute (from the home when relative), none of what is the station's own.
fn DeviceTools::allowed(self : DeviceTools, p : String) -> String raise ToolFailed {
  let asked = if p.has_prefix("/") || (p.length() > 2 && p[1] == ':') { p } else { path([homedir(), p]) }
  let real = attempt(() => @drive.realpath(asked)).unwrap_or(asked)
  let own = (self.p.bus.own_paths.val)()
  own.push(path([homedir(), ".claude.json"]))
  own.push(path([homedir(), ".codex", "auth.json"]))
  for root in own {
    let r = attempt(() => @drive.realpath(root)).unwrap_or(root)
    if within_path(asked, root) || within_path(real, r) || within_path(asked, r) || within_path(real, root) {
      raise ToolFailed("forbidden", "the station's own data and the machine's logins are not reachable through device tools")
    }
  }
  asked
}

///|
fn shell_program() -> String {
  if is_windows() {
    "cmd.exe"
  } else {
    match env_get("SHELL") {
      Some(s) if s != "" => s
      _ => "/bin/sh"
    }
  }
}

///|
fn env_with(more : Array[(String, String)]) -> Array[(String, String)] {
  let out = env_all().filter(kv => !more.iter().any(m => m.0 == kv.0))
  for m in more {
    out.push(m)
  }
  out
}

///|
async fn DeviceTools::run_op(self : DeviceTools, op : String, a : Json, context : Json) -> Json {
  let host = self.p.host
  match op {
    "exec" => {
      let command = tool_need(a, "command")
      let env = tool_env(a)
      let timeout = {
        let t = tool_int(a, "timeout_ms").unwrap_or(120000)
        if t > 600000 { 600000 } else { t }
      }
      let cwd = self.allowed(tool_str(a, "cwd").unwrap_or(homedir()))
      let proc = spawn(host, shell_program(), if is_windows() { ["/c", command] } else { ["-c", command] }, env=env_with(env), cwd~, stdout=Piped, stderr=Piped, group=true) catch {
        SysError(e) => raise ToolFailed("failed", e)
      }
      let out = @buffer.new()
      let err = @buffer.new()
      let cut = Ref(false)
      let take = (into : @buffer.Buffer, b : Bytes) => {
        let room = tools_output_cap - into.length()
        if room <= 0 {
          cut.val = true
        } else if b.length() > room {
          into.write_bytesview(b[:room])
          cut.val = true
        } else {
          into.write_bytes(b)
        }
      }
      let ended = @effect.timeout(timeout, async fn() {
        while true {
          match proc.events.take() {
            Out(b) => take(out, b)
            Err(b) => take(err, b)
            Exit(code, _) => return code
          }
        }
        None
      })
      let result : Map[String, Json] = {
        "exit_code": Json::null(),
        "stdout": Json::string(@utf8.decode_lossy(out.to_bytes())),
        "stderr": Json::string(@utf8.decode_lossy(err.to_bytes())),
        "truncated": Json::boolean(cut.val),
      }
      match ended {
        Some(code) =>
          result["exit_code"] = match code {
            Some(c) => Json::number(c.to_double())
            None => Json::null()
          }
        None => {
          ignore(kill(proc.pid, "SIGKILL", group=true))
          result["timed_out"] = Json::boolean(true)
        }
      }
      Json::object(result)
    }
    "fs.read" => {
      let p = self.allowed(tool_need(a, "path"))
      let offset = tool_int(a, "offset").unwrap_or(0)
      let length = {
        let l = tool_int(a, "length").unwrap_or(tools_read_cap)
        if l > tools_read_cap { tools_read_cap } else { l }
      }
      let size = match (try { Ok(self.p.fs.lstat(p)) } catch { e => Err(e) }) {
        Ok(Some(st)) => st.size.to_int()
        _ => raise ToolFailed("not_found", "no such file \{p}")
      }
      let want = if size - offset < length { size - offset } else { length }
      let got = if want <= 0 {
        b""
      } else {
        let said = try {
          host.shell_sync("fs.bytes", { "path": Json::string(p), "from": Json::number(offset.to_double()), "length": Json::number(want.to_double()) })
        } catch {
          e => raise ToolFailed("failed", "\{e}")
        }
        match said {
          String(hex) => @cloud_lock.hex_bytes(hex)
          _ => b""
        }
      }
      Json::object({
        "content_base64": Json::string(@base64.encode(got)),
        "size": Json::number(size.to_double()),
        "eof": Json::boolean(offset + got.length() >= size),
      })
    }
    "fs.write" => {
      let p = self.allowed(tool_need(a, "path"))
      let content = match tool_str(a, "content_base64") {
        Some(c) => try { @base64.decode(c) } catch { _ => raise ToolFailed("invalid_request", "content_base64 is not base64") }
        None => raise ToolFailed("invalid_request", "content_base64 is required")
      }
      ignore(attempt(() => @drive.mkdir(@nodepath.dirname(sep(), p), true)))
      let append = a is { "append": True, .. }
      let offset = if append {
        match (try { Ok(self.p.fs.lstat(p)) } catch { e => Err(e) }) {
          Ok(Some(st)) => Some(st.size)
          _ => None
        }
      } else {
        None
      }
      let args : Map[String, Json] = { "path": Json::string(p) }
      match offset {
        Some(o) => args["offset"] = Json::number(o)
        None => args["truncate"] = Json::boolean(true)
      }
      ignore(host.shell("fs.put", Json::object(args), bytes=content)) catch {
        e => raise ToolFailed("failed", "\{e}")
      }
      let size = match (try { Ok(self.p.fs.lstat(p)) } catch { e => Err(e) }) {
        Ok(Some(st)) => st.size
        _ => content.length().to_double()
      }
      Json::object({ "size": Json::number(size) })
    }
    "fs.list" => {
      let p = self.allowed(tool_need(a, "path"))
      let names = match (try { Ok(self.p.fs.names(p)) } catch { e => Err(e) }) {
        Ok(Some(n)) => n
        _ => raise ToolFailed("not_found", "no such directory \{p}")
      }
      names.sort()
      let entries = names.filter_map(n => match (try { Ok(self.p.fs.lstat(path([p, n]))) } catch { e => Err(e) }) {
        Ok(Some(st)) =>
          Some(
            ({
              "name": Json::string(n),
              "type": Json::string(kind_word(st.kind)),
              "size": Json::number(st.size),
              "mtime_ms": Json::number(st.mtime_ms.floor()),
            } : Json),
          )
        _ => None
      })
      Json::object({ "entries": Json::array(entries) })
    }
    "fs.stat" => {
      let p = self.allowed(tool_need(a, "path"))
      match (try { Ok(self.p.fs.lstat(p)) } catch { e => Err(e) }) {
        Ok(Some(st)) =>
          {
            "path": Json::string(p),
            "type": Json::string(kind_word(st.kind)),
            "size": Json::number(st.size),
            "mtime_ms": Json::number(st.mtime_ms.floor()),
            "mode": Json::number((st.mode.to_int() & 0o7777).to_double()),
          }
        _ => raise ToolFailed("not_found", "no such file \{p}")
      }
    }
    "process.start" => {
      let command = tool_need(a, "command")
      let env = tool_env(a)
      if self.processes.length() >= tools_processes_most {
        self.processes.retain(k => !k.exited)
        if self.processes.length() >= tools_processes_most {
          raise ToolFailed("too_many_processes", "at most \{tools_processes_most} processes are kept; stop one first")
        }
      }
      let cwd = self.allowed(tool_str(a, "cwd").unwrap_or(homedir()))
      self.next += 1
      let id = "p\{self.next}"
      let proc = spawn(host, shell_program(), if is_windows() { ["/c", command] } else { ["-c", command] }, env=env_with(env), cwd~, stdin_piped=true, stdout=Piped, stderr=Piped, group=true) catch {
        SysError(e) => raise ToolFailed("failed", e)
      }
      let kept : KeptProcess = {
        id,
        command,
        proc,
        started_at: wall_ms().to_double(),
        chunks: [],
        base: 0,
        total: 0,
        exited: false,
        exit_code: None,
      }
      let take = (b : Bytes) => {
        kept.chunks.push(b)
        kept.total += b.length()
        let mut held = kept.total - kept.base
        while held > tools_process_keep && kept.chunks.length() > 1 {
          let dropped = kept.chunks.remove(0)
          kept.base += dropped.length()
          held -= dropped.length()
        }
      }
      ignore(
        host.rt.fork_daemon("device process", on_error=e => @host.note("device process failed: \{e}"), async fn() {
          while true {
            match proc.events.take() {
              Out(b) | Err(b) => take(b)
              Exit(code, _) => {
                kept.exited = true
                kept.exit_code = code
                break
              }
            }
          }
        }),
      )
      self.processes.push(kept)
      Json::object({ "process_id": Json::string(id) })
    }
    "process.write" => {
      let k = self.kept(a)
      let data = match tool_str(a, "data_base64") {
        Some(d) => try { @base64.decode(d) } catch { _ => raise ToolFailed("invalid_request", "data_base64 is not base64") }
        None => raise ToolFailed("invalid_request", "data_base64 is required")
      }
      if k.exited {
        raise ToolFailed("exited", "process \{k.id} has exited")
      }
      if !k.proc.write(data) {
        raise ToolFailed("failed", "its input is closed")
      }
      Json::object({})
    }
    "process.tail" => {
      let k = self.kept(a)
      let since = {
        let s = tool_int(a, "since").unwrap_or(0)
        if s < k.base { k.base } else { s }
      }
      let all = body_bytes_of(k.chunks)
      let from = if since - k.base > all.length() { all.length() } else { since - k.base }
      let out : Map[String, Json] = {
        "data_base64": Json::string(@base64.encode(all[from:].to_owned())),
        "next": Json::number(k.total.to_double()),
        "exited": Json::boolean(k.exited),
      }
      if k.exited {
        out["exit_code"] = match k.exit_code {
          Some(c) => Json::number(c.to_double())
          None => Json::null()
        }
      }
      Json::object(out)
    }
    "process.stop" => {
      let k = self.kept(a)
      if !k.exited {
        ignore(kill(k.proc.pid, "SIGTERM", group=true))
      }
      Json::object({ "process_id": Json::string(k.id), "exited": Json::boolean(k.exited) })
    }
    "process.list" =>
      {
        "processes": Json::array(
          self.processes.map(k => {
            "process_id": Json::string(k.id),
            "command": Json::string(k.command),
            "pid": Json::number(k.proc.pid.to_double()),
            "started_at_ms": Json::number(k.started_at),
            "exited": Json::boolean(k.exited),
            "exit_code": match k.exit_code {
              Some(c) => Json::number(c.to_double())
              None => Json::null()
            },
          }),
        ),
      }
    "runtime.probe" => {
      let runtimes = []
      for kind in ["claude", "codex"] {
        guard find_program(kind) is Some(found) else { continue }
        let said = run_said(host, found, ["--version"], 10000).unwrap_or("")
        let version = {
          let b = StringBuilder()
          let mut started = false
          for c in said {
            if (c >= '0' && c <= '9') || (started && c == '.') {
              b.write_char(c)
              started = true
            } else if started {
              break
            }
          }
          b.to_string()
        }
        let signed_in = if kind == "codex" {
          read_text(path([env_get("CODEX_HOME").unwrap_or(path([homedir(), ".codex"])), "auth.json"])) is Some(_)
        } else {
          env_get("ANTHROPIC_API_KEY") is Some(_) ||
          (read_text(path([homedir(), ".claude", ".credentials.json"])).unwrap_or("").contains("accessToken"))
        }
        runtimes.push(
          ({
            "kind": Json::string(kind),
            "path": Json::string(found),
            "version": if version == "" { Json::null() } else { Json::string(version) },
            "signed_in": Json::boolean(signed_in),
          } : Json),
        )
      }
      Json::object({ "runtimes": Json::array(runtimes) })
    }
    _ => {
      // A chat started, said to or looked at: the agents' side's, as the person it names.
      let answer = (self.p.bus.hub_ask.val)("device.\{op}", { "args": a, "context": context }) catch {
        e => raise ToolFailed("failed", "\{e}")
      }
      match answer {
        Null => raise ToolFailed("unavailable", "this station runs no chats")
        { "error": { "code": String(code), "message": String(m), .. }, .. } => raise ToolFailed(code, m)
        v => v
      }
    }
  }
}

///|
fn kind_word(kind : String) -> String {
  match kind {
    "file" => "file"
    "dir" | "directory" => "dir"
    "symlink" | "link" => "symlink"
    _ => "other"
  }
}

///|
fn DeviceTools::kept(self : DeviceTools, a : Json) -> KeptProcess raise ToolFailed {
  let id = tool_need(a, "process_id")
  match self.processes.iter().find_first(k => k.id == id) {
    Some(k) => k
    None => raise ToolFailed("not_found", "no process \{id}")
  }
}

///|
/// The gateways' tools on this station (mesh/tools.ts `ToolsDeps`).
fn P51::tools_deps(self : P51, plane : Plane) -> @mesh_runtime.ToolsDeps {
  let tools : DeviceTools = { p: self, processes: [], next: 0 }
  self.stops.push(() => for k in tools.processes {
    if !k.exited {
      ignore(kill(k.proc.pid, "SIGKILL", group=true))
    }
  })
  let access = () => match (self.bus.config_raw.val)() {
    { "tools": { "access": String(a), .. }, .. } if a == "off" || a == "read" || a == "full" => a
    _ => "off"
  }
  {
    enabled: () => plane.control.spec().tools,
    workspace: () => match plane.cloud.state {
      Some(s) if s.text("workspace") != "" => Some(s.text("workspace"))
      _ => None
    },
    removed: () => plane.cloud.removed(),
    gateway_keys: () => match plane.cloud.state {
      Some(s) =>
        match s.get("gateway_keys") {
          Some(Array(k)) => k.filter_map(x => match x { String(t) => Some(t); _ => None })
          _ => []
        }
      None => []
    },
    run: async fn(op, args, context) {
      if !tools_ops.contains(op) {
        return Err(("unknown_op", "unknown op \{op}"))
      }
      let a = access()
      if !(a == "full" || (a == "read" && tools_read_ops.contains(op))) {
        return Err(
          (
            "forbidden",
            if a == "off" {
              "device tools are turned off on this station"
            } else {
              "\{op} needs full access; this station allows \{a}"
            },
          ),
        )
      }
      match (try { Ok(tools.run_op(op, args, context)) } catch { e => Err(e) }) {
        Ok(v) => Ok(v)
        Err(ToolFailed(code, m)) => Err((code, m))
        Err(e) => Err(("failed", "\{e}"))
      }
    },
    said: (op, id, fields) => p51_log("INFO", "tools", "device tool", fields=with_fields(fields, [("op", Json::string(op)), ("id", Json::string(id))])),
  }
}
