// What the live parts of P5-4 (the vault, the drive, the screens and the Helper, the browser, the phones and devices,
// the terminals and logins) share in the station's process: JSON between the two codecs the packages use (`Json`,
// the station's; `@jsjson.JValue`, JavaScript's), a call's arguments, the session a tool's call is of, the clock's
// `after`, the machine's processes followed as events (sys.mbt `spawn`) and a stream the shell opened.

///|
fn p54_jv(j : Json) -> @jsjson.JValue {
  @jsjson.parse(j.stringify()) catch {
    _ => @jsjson.JValue::Null
  }
}

///|
fn p54_of_jv(v : @jsjson.JValue) -> Json {
  @json.parse(@jsjson.stringify(v)) catch {
    _ => Json::null()
  }
}

///|
fn p54_obj(fields : Array[(String, Json)]) -> Json {
  let m : Map[String, Json] = Map([])
  for f in fields {
    m[f.0] = f.1
  }
  Json::object(m)
}

///|
fn p54_get(v : Json?, k : String) -> Json? {
  match v {
    Some(Object(m)) => m.get(k)
    _ => None
  }
}

///|
fn p54_str(v : Json?) -> String? {
  match v {
    Some(String(s)) => Some(s)
    _ => None
  }
}

///|
fn p54_text(v : Json?, k : String) -> String? {
  p54_str(p54_get(v, k))
}

///|
fn p54_num(v : Json?) -> Double? {
  match v {
    Some(Number(n, ..)) => Some(n)
    _ => None
  }
}

///|
fn p54_bool(v : Json?) -> Bool {
  v is Some(True)
}

///|
fn p54_opt(s : String?) -> Json {
  match s {
    Some(t) => Json::string(t)
    None => Json::null()
  }
}

///|
fn p54_strs(v : Json?) -> Array[String] {
  match v {
    Some(Array(a)) => a.filter_map(x => p54_str(Some(x)))
    _ => []
  }
}

///|
/// The `i`th argument of a call (`[a, b, …]`), none past its end.
fn p54_arg(args : Json, i : Int) -> Json? {
  match args {
    Array(a) if i < a.length() => Some(a[i])
    Array(_) => None
    other => if i == 0 { Some(other) } else { None }
  }
}

///|
fn p54_arg_text(args : Json, i : Int) -> String {
  p54_str(p54_arg(args, i)).unwrap_or("")
}

///|
/// The session a tool is called for (the door's context: `session`, as the agents' side gives it).
fn p54_session(context : Json) -> String {
  p54_text(Some(context), "session").unwrap_or("")
}

///|
/// A tool's answer as MCP gives it: its text, an error where it failed.
fn p54_tool_answer(text : String, error? : Bool = false) -> Json {
  let content : Json = [{ "type": "text", "text": Json::string(text) }]
  if error {
    { "content": content, "isError": Json::boolean(true) }
  } else {
    { "content": content }
  }
}

///|
/// `f` once, `ms` from now on the program's runtime; what it gives calls it off.
fn p54_after(host : @host.Host, ms : Double, f : () -> Unit) -> () -> Unit {
  let off = Ref(false)
  let wait = if ms < 0.0 { 0 } else if ms > 2147483647.0 { 2147483647 } else { ms.to_int() }
  ignore(
    host.rt.fork_daemon("after", on_error=e => @host.note("after failed: \{e}"), async fn() {
      @effect.sleep(wait) // timer: a deadline a part set (its `after`)
      if !off.val {
        f()
      }
    }),
  )
  () => off.val = true
}

///|
/// An error's words, without its kind's name where it says only that.
fn p54_message(e : Error) -> String {
  match e {
    Failure(m) => m
    BusError(m) => m
    SysError(m) => m
    _ => "\{e}"
  }
}

///|
/// A child of this process, its output and end given as they come (sys.mbt `spawn`, its events taken on a fiber).
priv struct P54Child {
  proc : Proc
  mut ended : (Int?, String?)?
  mut running : Bool
}

///|
/// `program` started, `out`, `err` and `close` called as it says and ends (Node's `spawn` with its events).
fn p54_spawn(
  host : @host.Host,
  program : String,
  args : Array[String],
  env? : Array[(String, String)],
  cwd? : String,
  stdin_piped? : Bool = true,
  group? : Bool = false,
  out? : (Bytes) -> Unit = _ => (),
  err? : (Bytes) -> Unit = _ => (),
  close? : (Int?, String?) -> Unit = (_, _) => (),
) -> P54Child raise SysError {
  let proc = spawn(host, program, args, env?, cwd?, stdin_piped~, stdout=Piped, stderr=Piped, group~)
  let child = { proc, ended: None, running: true }
  ignore(
    host.rt.fork_daemon("child \{program}", on_error=e => @host.note("child \{program} failed: \{e}"), async fn() {
      while true {
        match proc.events.take() {
          Out(b) => out(b)
          Err(b) => err(b)
          Exit(code, signal) => {
            child.ended = Some((code, signal))
            child.running = false
            close(code, signal)
            return
          }
        }
      }
    }),
  )
  child
}

///|
/// `program` run to its end: its code, stdout and stderr.
async fn p54_run(
  host : @host.Host,
  program : String,
  args : Array[String],
  env? : Array[(String, String)],
  cwd? : String,
) -> (Int?, String, String) {
  let proc = spawn(host, program, args, env?, cwd?, stdout=Piped, stderr=Piped)
  let (code, _, out, err) = proc.finished()
  (code, @utf8.decode_lossy(out), @utf8.decode_lossy(err))
}

///|
/// A stream the shell opened (`unix.open`, `tcp.open`): its bytes as they come, written, closed.
priv struct P54Conn {
  host : @host.Host
  id : Json
  mut closed : Bool
}

///|
async fn p54_unix_open(host : @host.Host, path : String) -> P54Conn {
  { host, id: host.unix_open(path).id, closed: false }
}

///|
async fn p54_tcp_open(host : @host.Host, port : Int) -> P54Conn {
  { host, id: host.tcp_open(port).id, closed: false }
}

///|
/// What came next on it; None at its end.
async fn P54Conn::read(self : P54Conn) -> Bytes? {
  if self.closed {
    return None
  }
  self.host.tcp_read(self.id) catch {
    _ => None
  }
}

///|
async fn P54Conn::write(self : P54Conn, b : Bytes) -> Unit {
  self.host.tcp_write(self.id, b)
}

///|
fn P54Conn::close(self : P54Conn) -> Unit {
  if self.closed {
    return
  }
  self.closed = true
  let host = self.host
  let id = self.id
  ignore(host.rt.fork_quiet(name="conn close", async fn() { host.tcp_close(id) }))
}

///|
/// Writes in their order, none waiting on the caller: a queue taken by a fiber of its own.
fn P54Conn::writer(self : P54Conn) -> (Bytes) -> Unit {
  let q : @effect.Queue[Bytes] = @effect.Queue::unbounded()
  ignore(
    self.host.rt.fork_daemon("conn writes", on_error=e => @host.note("conn writes failed: \{e}"), async fn() {
      while !self.closed {
        let b = q.take()
        self.write(b) catch {
          _ => {
            self.close()
            return
          }
        }
      }
    }),
  )
  b => ignore(q.try_offer(b))
}

///|
/// The station's id and its workspaces' memberships (mesh/cloud.json's, the control plane's as P5-1 keeps it).
fn p54_station_id(bus : LiveBus) -> String? {
  match (bus.cloud_state.val)() {
    Some(s) =>
      match p54_text(Some(s), "station") {
        Some(id) if id != "" => Some(id)
        _ => None
      }
    None => None
  }
}

///|
fn p54_home(bus : LiveBus) -> String? {
  match (bus.cloud_state.val)() {
    Some(s) =>
      match p54_text(Some(s), "workspace") {
        Some(w) if w != "" => Some(w)
        _ => None
      }
    None => None
  }
}

///|
/// A session's row as the store has it (none where there is none).
fn p54_session_row(bus : LiveBus, key : String) -> Json? {
  match (try { Ok(bus.store.get_session(key)) } catch { e => Err(e) }) {
    Ok(Object(_) as row) => Some(row)
    _ => None
  }
}

///|
/// The session's workspace (the store's), else the station's home.
fn p54_session_ws(bus : LiveBus, key : String) -> String? {
  match (try { Ok(bus.store.session_ws(key)) } catch { e => Err(e) }) {
    Ok(String(w)) if w != "" => Some(w)
    _ => p54_home(bus)
  }
}

///|
/// The session's working directory (its `cwd`, else its workspace directory).
fn p54_session_dir(bus : LiveBus, key : String) -> String? {
  let row = p54_session_row(bus, key)
  match p54_text(row, "cwd") {
    Some(c) if c != "" => Some(c)
    _ =>
      match p54_text(row, "workspace") {
        Some(w) if w != "" => Some(w)
        _ => None
      }
  }
}

///|
/// The runner binary (platform/processes.ts `runnerBinary`): STILLFAIL_RUNNER, else beside this program, else in the
/// release's station directory.
fn p54_runner_binary(bus : LiveBus) -> String? {
  let name = if is_windows() { "stillfail-runner.exe" } else { "stillfail-runner" }
  let here = @nodepath.dirname(sep(), @drive.real_of(bus.argv0))
  let candidates = [env_get("STILLFAIL_RUNNER").unwrap_or(""), path([here, name]), path([bus.app, "station", name])]
  for c in candidates {
    if c != "" && (try { Ok(@drive.stat(c)) } catch { e => Err(e) }) is Ok(_) {
      return Some(c)
    }
  }
  None
}

///|
/// The system as the TypeScript station's platform names it (`platform.os`): macos, linux, windows.
fn p54_os() -> String {
  match platform() {
    "darwin" => "macos"
    "win32" => "windows"
    p => p
  }
}
