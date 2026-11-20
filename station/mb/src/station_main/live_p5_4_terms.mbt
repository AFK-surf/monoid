// The station's terminals (station/src/terminals/module.ts `TerminalsLive`) and its logins to command-line tools
// (logins/module.ts `LoginsLive`) as parts of the station, on terminals_logins' parts.
//
// A terminal is a runner's (`stillfail-runner --pty`, its id `term-…`, its meta in <data>/run/terminals/), taken up
// by the next process; a new one opens only on a station on the test channel (`station_feature("terminal", …)`, as
// features.ts). Its views are members' `terminal` requests, given the stream the mesh opened for them: the request
// as the parts take it is `{viewer, head, stream, carry}`, `stream` the shell's stream (`istream.*`), `carry` what
// came of it past its head line (base64). A login runs its command on a pseudo-terminal (`script`) as the platform's
// `terminalSoon` does, its screen read by terminals_logins' Vt, told on the event streams (`machine-logins`).

///|
/// A member's stream as a part is given it (`{stream, kind}`, P5-1's `shell_handle`): the shell's own stream (`istream`,
/// its id as it is), or one of the shell's loopback connections carrying it (`tcp`, `{"$tcp": id}`).
fn p54_stream_handle(asked : Json) -> Json {
  let id = opt_field(Some(asked), "stream").unwrap_or(Json::null())
  match jtext(asked, "kind") {
    Some("tcp") => { "$tcp": id }
    _ => id
  }
}

///|
/// One of the shell's calls of a member's stream (`read`, `write`, `finish`, `reset`, `stopped`), as its handle is
/// held: `istream.*`, or `tcp.*` for one carried on a loopback connection.
async fn p54_stream_call(host : @host.Host, handle : Json, call : String, bytes? : Bytes, code? : Json, token? : Json) -> (Json, Bytes?) {
  match handle {
    { "$tcp": id, .. } =>
      match call {
        "read" =>
          match host.tcp_read(id) {
            Some(b) => (Json::null(), Some(b))
            None => ({ "end": true }, None)
          }
        "write" => {
          host.tcp_write(id, bytes.unwrap_or(b""))
          (Json::null(), None)
        }
        "finish" => {
          host.tcp_end(id)
          (Json::null(), None)
        }
        "reset" => {
          host.tcp_close(id)
          (Json::null(), None)
        }
        _ => (Json::null(), None)
      }
    id => {
      let asked : Map[String, Json] = { "id": id }
      if code is Some(c) { asked["code"] = c }
      if token is Some(t) { asked["token"] = t }
      match bytes {
        Some(b) => host.shell("istream." + call, Json::object(asked), bytes=b)
        None => host.shell("istream." + call, Json::object(asked))
      }
    }
  }
}

///|
async fn p54_stream_read(host : @host.Host, handle : Json) -> Bytes? {
  let (said, bytes) = p54_stream_call(host, handle, "read") catch { _ => return None }
  match (opt_field(Some(said), "end"), bytes) {
    (Some(True), _) => None
    (_, Some(b)) => Some(b)
    _ => None
  }
}

///|
/// A member's stream as the shell holds it (its handle: `p54_stream_handle`): read, written, finished.
fn p54_member_stream(host : @host.Host, handle : Json) -> @terminals_logins.Stream {
  {
    read: async fn() { p54_stream_read(host, handle) },
    write: async fn(b) { ignore(p54_stream_call(host, handle, "write", bytes=b)) },
    finish: async fn() { ignore(p54_stream_call(host, handle, "finish")) catch { _ => () } },
  }
}

///|
fn p54_viewer_of(v : Json?) -> @terminals_logins.Viewer {
  {
    name: opt_text(v, "name").unwrap_or(""),
    email: opt_text(v, "email").unwrap_or(""),
    role: opt_text(v, "role").unwrap_or("member"),
    workspace: opt_text(v, "workspace").unwrap_or(""),
    device: opt_text(v, "device").unwrap_or(""),
  }
}

///|
/// A runner's info file, as `liveRunners` reads it.
fn p54_runner_info(v : Json) -> @terminals_logins.RunnerInfo {
  {
    id: jtext(v, "id").unwrap_or(""),
    pty: opt_field(Some(v), "pty").map(to_jv),
    cols: opt_field(Some(v), "cols").map(to_jv),
    rows: opt_field(Some(v), "rows").map(to_jv),
  }
}

///|
/// Runners of before alive now (runner.ts `liveRunners`): their info files whose runner is alive; each with its socket.
fn p54_live_runners(data : String) -> Array[(Json, @terminals_logins.RunnerInfo)] {
  let dir = path([data, "run", "runners"])
  let out = []
  let names = @drive.names(dir) catch { _ => return out }
  for name in names {
    if !name.has_suffix(".json") {
      continue
    }
    match read_json(path([dir, name])) {
      Some(Object(_) as v) =>
        match opt_num(opt_field(Some(v), "runner")) {
          Some(pid) if pid_alive(pid.to_int()) => out.push((v, p54_runner_info(v)))
          _ => ()
        }
      _ => ()
    }
  }
  out
}

///|
/// A runner's socket (its `socket`: a Unix socket's path, a named pipe on Windows), as runnerWire reads it.
fn p54_runner_socket(host : @host.Host, socket_path : String) -> @terminals_logins.RunnerSocket {
  let datas : Array[(Bytes) -> Unit] = []
  let closes : Array[() -> Unit] = []
  let conn : Ref[P54Conn?] = Ref(None)
  let pending : Array[Bytes] = []
  let ended = Ref(false)
  let close_all = () => {
    if ended.val {
      return
    }
    ended.val = true
    for c in closes.copy() {
      c()
    }
  }
  let write_now : Ref[(Bytes) -> Unit] = Ref(b => pending.push(b))
  fork_bg(host, "runner socket", async fn() {
    let c = p54_unix_open(host, socket_path) catch {
      _ => {
        close_all()
        return
      }
    }
    conn.val = Some(c)
    let w = c.writer()
    for b in pending {
      w(b)
    }
    pending.clear()
    write_now.val = w
    while c.read() is Some(b) {
      for f in datas.copy() {
        f(b)
      }
    }
    c.close()
    close_all()
  })
  {
    write: line => (write_now.val)(@utf8.encode(line)),
    end: () => {
      if conn.val is Some(c) { c.close() }
      close_all()
    },
    writable: () => !ended.val,
    on_data: f => datas.push(f),
    on_close: f => closes.push(f),
    says_leave: is_windows(),
  }
}

///|
/// A program started under a runner (runner.ts `startRunner`): its info once it says it is ready.
async fn p54_start_runner(
  bus : LiveBus,
  id : String,
  program : String,
  args : Array[String],
  cwd : String,
  pty : (Int, Int)?,
  env? : Array[(String, String)],
) -> Json {
  guard runner_binary(bus.app, bus.argv0, bus.data) is Some(runner) else { raise Failure("stillfail-runner is not there") }
  start_runner_proc(bus.host, runner, bus.data, id, program, args, env?, cwd, pty?) catch {
    LiveError(m) => raise Failure(m)
    e => raise e
  }
}

///|
priv struct P54Terms {
  terminals : @terminals_logins.TerminalsPart
  sockets : Map[String, String]
  /// Whether a new terminal opens here now (a `beta` feature of the station's: features.ts `stationFeature`).
  offered : () -> Bool
}

///|
/// The terminals made and said (terminals/module.ts).
async fn p54_terminals_start(bus : LiveBus) -> P54Terms {
  let host = bus.host
  let sockets : Map[String, String] = Map([])
  let offered = () => station_feature("terminal", (bus.config_raw.val)(), bus.app)
  let part = @terminals_logins.TerminalsPart::start({
    data: bus.data,
    home: homedir(),
    os: platform_os(),
    shell: env_get("SHELL"),
    session_dir: k => bus_session_dir(bus, k),
    random_hex: () => @drive.hex(@drive.random_bytes(8)),
    offered,
    tell: (workspace, value) => (bus.events_tell.val)(
      "terminals",
      of_jv(value),
      "terminals\u{0}\{workspace}",
      { "workspace": Json::string(workspace) },
    ),
    mkdir: async fn(p) { @drive.mkdir(p, true, mode=0o700) },
    write_file: async fn(p, text) { bus.host.write_private(p, @utf8.encode(text), sep=sep()) },
    remove: async fn(p) { @drive.rm_force(p) },
    read_file: async fn(p) {
      match bus.host.read_text(p) {
        Some(t) => t
        None => raise @drive.fs_error("ENOENT", "ENOENT: no such file or directory, open '\{p}'")
      }
    },
    start_runner: async fn(id, program, args, cwd, cols, rows) {
      let station_env : Map[String, String] = Map([])
      for kv in env_all() {
        station_env[kv.0] = kv.1
      }
      station_env.remove("STILLFAIL_MESH_FRONT")
      let env = @terminals_logins.shell_env(platform_os(), station_env).iter().map(kv => (kv.0, kv.1)).collect()
      let info = p54_start_runner(bus, id, program, args, cwd, Some((cols, rows)), env~)
      sockets[id] = jtext(info, "socket").unwrap_or("")
      p54_runner_info(info)
    },
    live_runners: async fn() {
      p54_live_runners(bus.data).map(r => {
        sockets[r.1.id] = jtext(r.0, "socket").unwrap_or("")
        r.1
      })
    },
    listening_soon: async fn(info) {
      // (a pipe cannot be looked at: its info file, which goes with it, says so then)
      is_windows() ||
      (match sockets.get(info.id) {
        Some(s) if s != "" => (try { Ok(@drive.lstat(s)) } catch { e => Err(e) }) is Ok(_)
        _ => false
      })
    },
    wire: info => @terminals_logins.runner_wire(p54_runner_socket(host, sockets.get(info.id).unwrap_or(""))),
    now: () => wall_ms().to_double(),
    spawn: f => ignore(host.rt.fork_quiet(name="terminal", async fn() { f() catch { _ => () } })),
    log: (said, about) => err_write("terminal: \{said} \{@jsjson.stringify(about)}\n"),
  })
  bus.parts.streams("terminal", async fn(asked) {
    let stream = p54_member_stream(host, p54_stream_handle(asked))
    let carry = p54_bytes_of(opt_field(Some(asked), "carry"))
    part.terminals.answer(stream, carry, to_jv(opt_field(Some(asked), "head").unwrap_or(Json::null())), p54_viewer_of(opt_field(Some(asked), "viewer")))
  })
  bus.parts.routes([
    {
      meth: "GET",
      path: "^/terminals$",
      answer: async fn(r) {
        let (status, body) = part.listed(opt_text(opt_field(Some(r), "viewer"), "workspace").unwrap_or(""))
        { "status": Json::number(status.to_double()), "body": Json::string(body) }
      },
    },
    {
      meth: "POST",
      path: "^/terminals/([^/]+)/end$",
      answer: async fn(r) {
        let raw = match opt_field(Some(r), "params") {
          Some(Array([String(id), ..])) => id
          _ => {
            let p = jtext(r, "path").unwrap_or("")
            let parts = p.split("/").map(x => x.to_owned()).to_array()
            if parts.length() >= 3 { parts[2] } else { "" }
          }
        }
        let (status, body) = part.end_asked(raw, p54_viewer_of(opt_field(Some(r), "viewer")))
        { "status": Json::number(status.to_double()), "body": Json::string(body) }
      },
    },
  ])
  { terminals: part, sockets, offered }
}

///|
/// What is asked of the terminals by name.
fn p54_terminals_ask(t : P54Terms, op : String, a : Json) -> Json? {
  match op {
    "terminals.offered" => Some(Json::boolean((t.offered)()))
    "terminals.list" => Some(of_jv(t.terminals.terminals.list(call_arg_text(a, 0))))
    _ => None
  }
}

///|
/// A child of a login's command, as its run follows it (terminals_logins `Child`).
fn p54_login_child(
  host : @host.Host,
  program : String,
  args : Array[String],
  cwd : String,
  env : Map[String, String],
) -> (@terminals_logins.Child, Int) raise {
  let outs : Array[(Int, Bytes) -> Unit] = []
  let closes : Array[(Int?, String?) -> Unit] = []
  let early : Array[(Int, Bytes)] = []
  let ended : Ref[(Int?, String?)?] = Ref(None)
  let open_in = Ref(true)
  let child = p54_spawn(
    host,
    program,
    args,
    env=env.iter().map(kv => (kv.0, kv.1)).collect(),
    cwd~,
    group=true,
    out=b => if outs.is_empty() { early.push((0, b)) } else { for f in outs { f(0, b) } },
    err=b => if outs.is_empty() { early.push((1, b)) } else { for f in outs { f(1, b) } },
    close=(code, signal) => {
      ended.val = Some((code, signal))
      for f in closes {
        f(code, signal)
      }
    },
  )
  let pid = child.proc.pid
  (
    {
      pid: Some(pid),
      writable: () => open_in.val && ended.val is None,
      write: text => ignore(child.proc.write(@utf8.encode(text))),
      end_stdin: () => {
        open_in.val = false
        child.proc.end_input()
      },
      on_output: f => {
        outs.push(f)
        for e in early {
          f(e.0, e.1)
        }
        early.clear()
      },
      on_close: f => match ended.val {
        Some((code, signal)) => f(code, signal)
        None => closes.push(f)
      },
    },
    pid,
  )
}

///|
fn p54_quoted(s : String) -> String {
  if s != "" && s.iter().all(c => c.is_ascii_alphabetic() || c.is_ascii_digit() || "-_./=:,@+".contains_char(c)) {
    s
  } else {
    "'" + s.replace_all(old="'", new="'\\''") + "'"
  }
}

///|
/// The answer of an HTTP request to 127.0.0.1:`port` (a login's local callback relayed), its body at most a million
/// bytes.
async fn p54_http_send(
  host : @host.Host,
  port : Int,
  meth : String,
  target : String,
  headers : Array[(String, String)],
  body : Bytes,
) -> @terminals_logins.Answered {
  let c = p54_tcp_open(host, port) catch {
    e => raise @terminals_logins.SendFailed("ECONNREFUSED", p54_message(e))
  }
  let head = StringBuilder::new()
  head.write_string("\{meth} \{target} HTTP/1.1\r\nhost: 127.0.0.1:\{port}\r\nconnection: close\r\n")
  for h in headers {
    let k = h.0.to_lower()
    if k != "host" && k != "connection" && k != "content-length" && k != "transfer-encoding" {
      head.write_string("\{h.0}: \{h.1}\r\n")
    }
  }
  head.write_string("content-length: \{body.length()}\r\n\r\n")
  let all = @buffer.new()
  all.write_bytes(@utf8.encode(head.to_string()))
  all.write_bytes(body)
  c.write(all.to_bytes()) catch {
    e => {
      c.close()
      raise @terminals_logins.SendFailed("EPIPE", p54_message(e))
    }
  }
  let got = @buffer.new()
  while c.read() is Some(b) {
    got.write_bytes(b)
    if got.length() > 1048576 + 65536 {
      break
    }
  }
  c.close()
  let bytes = got.to_bytes()
  let text = @utf8.decode_lossy(bytes)
  guard text.find("\r\n\r\n") is Some(cut) else { raise @terminals_logins.SendFailed("EPROTO", "no answer") }
  let lines = text[:cut].to_owned().split("\r\n").map(l => l.to_owned()).to_array()
  let status = match lines.get(0) {
    Some(l) =>
      match l.split(" ").map(x => x.to_owned()).to_array().get(1) {
        Some(s) => @string.parse_int(s) catch { _ => 0 }
        None => 0
      }
    None => 0
  }
  let hs : Array[(String, String)] = []
  for l in lines[1:] {
    match l.find(":") {
      Some(i) => {
        let k = l[:i].to_owned().to_lower()
        let v = l[i + 1:].to_owned().trim().to_owned()
        match hs.search_by(h => h.0 == k) {
          Some(j) => hs[j] = (k, hs[j].1 + ", " + v)
          None => hs.push((k, v))
        }
      }
      None => ()
    }
  }
  let start = @utf8.encode(text[:cut + 4].to_owned()).length()
  let rest = if start <= bytes.length() { bytes[start:].to_owned() } else { b"" }
  let body = if rest.length() > 1048576 { rest[:1048576].to_owned() } else { rest }
  { status, headers: hs, body: @utf8.decode_lossy(body) }
}

///|
priv struct P54Logins {
  logins : @terminals_logins.Logins
  part : @terminals_logins.LoginsPart
}

///|
/// The logins made and said (logins/module.ts).
async fn p54_logins_start(
  bus : LiveBus,
  threads : @store_threads.Store,
  pages : @terminals_logins.LoginPages?,
  cloud : P54Cloud,
) -> P54Logins {
  let host = bus.host
  let mac = platform() == "darwin"
  let fork = (f : async () -> Unit) => ignore(host.rt.fork_quiet(name="login", async fn() { f() catch { _ => () } }))
  let env_map = () => {
    let m : Map[String, String] = Map([])
    for kv in env_all() {
      m[kv.0] = kv.1
    }
    m.remove("STILLFAIL_MESH_FRONT")
    m
  }
  let run_out = async fn(program : String, args : Array[String]) -> String? {
    let (code, out, _) = run_cmd(host, program, args) catch { _ => return None }
    if code == Some(0) { Some(out) } else { None }
  }
  let run_io : @terminals_logins.RunIo = {
    now: () => wall_ms().to_double(),
    after: (ms, f) => bus_after(host, ms.to_double(), f),
    spawn: fork,
    home: env => env.get("HOME"),
    prepend_path: env_prepend_path,
    exe: name => if is_windows() { name + ".exe" } else { name },
    with_shell_command: async fn(program, env) { env_with_shell_command(host, program, env) },
    terminal: async fn(program, args, cols, rows) {
      bus_pty_terminal(bus, program, args, cols, rows, allow_windows=false, script => (try { Ok(@drive.stat(script)) } catch { e => Err(e) }) is Ok(_))
    },
    runnable: async fn(program, args, _) { (program, args) },
    start_command: (program, args, cwd, env) => p54_login_child(host, program, args, cwd, env).0,
    started: async fn(_) { None },
    end_command: (child, signal) => match child.pid {
      Some(pid) => ignore(kill(pid, signal, group=true))
      None => ()
    },
    descendants: async fn(pid) { process_descendants(host, pid) },
    echoes: async fn(pid) {
      guard run_out("ps", ["-o", "tty=", "-p", pid.to_string()]) is Some(t) else { return None }
      let tty = t.trim().to_owned()
      if tty == "" || tty.has_prefix("?") {
        return None
      }
      guard run_out("stty", [if mac { "-f" } else { "-F" }, "/dev/" + tty, "-a"]) is Some(said) else { return None }
      let words = said.split(" ").map(w => w.trim().to_owned()).to_array() + said.split("\n").map(w => w.trim().to_owned()).to_array()
      let flat = said.replace_all(old="\n", new=" ").replace_all(old="\t", new=" ").split(" ").map(w => w.to_owned()).to_array()
      ignore(words)
      if flat.contains("-echo") && !flat.contains("-icanon") {
        Some(false)
      } else if flat.contains("echo") || flat.contains("-echo") {
        Some(true)
      } else {
        None
      }
    },
    commands: async fn(pids) {
      if pids.is_empty() {
        return []
      }
      match run_out("ps", ["-o", "comm=", "-p", pids.map(p => p.to_string()).join(",")]) {
        Some(t) => t.split("\n").map(l => l.trim().to_owned()).filter(l => l != "").to_array()
        None => []
      }
    },
    read_file: async fn(p) {
      match bus.host.read_text(p) {
        Some(t) => t
        None => raise @drive.fs_error("ENOENT", "ENOENT: no such file or directory, open '\{p}'")
      }
    },
    watch: (dir, _) => raise Failure("\{dir} is not watched here: its file is read as it is asked"),
    tr: (lang, key, args) => tr(lang, key, args=args.iter().map(kv => (kv.0, kv.1)).collect()),
    log: (said, about) => err_write("login: \{said} \{@jsjson.stringify(about)}\n"),
  }
  let io : @terminals_logins.LoginsIo = {
    data: bus.data,
    env: env_map,
    lang: () => (bus.lang.val)(),
    run: run_io,
    mkdir: async fn(p) { @drive.mkdir(p, true) },
    make_command: async fn(p, text) {
      // (made 0o700 as it is written; chmod'd after, as the umask may have taken bits off)
      bus.host.write_atomic(p, @utf8.encode(text), mode=0o700, sync=true, mkdir=true, sep=sep())
      ignore(host.shell("fs.chmod", { "path": Json::string(p), "mode": Json::number(0o700.to_double()) })) catch {
        _ => ()
      }
    },
    write_private: async fn(p, text) { bus.host.write_private(p, @utf8.encode(text), sep=sep()) },
    sleep: async fn(ms) { @effect.sleep(ms) },
    random4: () => @drive.hex(@drive.random_bytes(2)),
    relay: {
      listening: async fn(pids, port) {
        if pids.is_empty() {
          return Some([])
        }
        let (code, out, _) = run_cmd(host, "lsof", ["-nP", "-a", "-p", pids.map(p => p.to_string()).join(","), "-iTCP:\{port}", "-sTCP:LISTEN", "-Fn"]) catch {
          _ => return None
        }
        if code != Some(0) && code != Some(1) {
          return None
        }
        let addrs = []
        for line in out.split("\n") {
          if line.has_prefix("n") {
            let a = line[1:].to_owned()
            let host_part = match a.rev_find(":") {
              Some(i) => a[:i].to_owned()
              None => a
            }
            if !addrs.contains(host_part) {
              addrs.push(host_part)
            }
          }
        }
        Some(addrs)
      },
      send: async fn(_, port, meth, target, headers, body) { p54_http_send(host, port, meth, target, headers, body) },
    },
  }
  let logins = @terminals_logins.Logins::new(io, pages?)
  // (logins/module.ts: a login's terminal followed on the event streams, its screen given as it changes)
  match live_events.val {
    Some(events) =>
      events.follow(login_screen=(id, send) => Some(
        logins.follow(id, s => send({ rows: s.rows, cursor: s.to_json().get("cursor").unwrap_or(@jsjson.JValue::Null), echo: s.echo, live: s.live })),
      ))
    None => ()
  }
  let part = @terminals_logins.LoginsPart::new(logins, {
    session_ws: k => bus_session_ws(bus, k),
    session_row: k => match bus_session_row_opt(bus, k) {
      Some(row) => Some((jtext(row, "createdBy"), bus_session_ws(bus, k)))
      None => None
    },
    close_login_cards: id => {
      let got = threads.close_login_cards(Json::string(id))
      told_threads(bus, threads)
      opt_strs(Some(got))
    },
    machine_logins: (data, limited, of) => {
      (bus.events_tell.val)("machine-logins", of_jv(data), "machine-logins\u{0}\{of}", { "readOnly": Json::boolean(false) })
      (bus.events_tell.val)("machine-logins", of_jv(limited), "machine-logins-limited\u{0}\{of}", { "readOnly": Json::boolean(true) })
    },
    notify: (session, text) => {
      if bus_session_row_opt(bus, session) is None {
        raise Failure("no session \{session}")
      }
      fork(async fn() { ignore((bus.hub_ask.val)("hub.notify", [Json::string(session), Json::string(text)])) })
    },
    chat_title: session => opt_text(bus_session_row_opt(bus, session), "title"),
    name_of: email => cloud.person_name(email),
    place: () => match (bus_station_id_opt(bus), bus_home(bus)) {
      (Some(s), Some(w)) => Some((s, w))
      _ => None
    },
    page_base: () => match ((bus.cloud_state.val)(), bus_home(bus), bus_station_id_opt(bus)) {
      (Some(st), Some(w), Some(s)) =>
        match jtext(st, "origin") {
          Some(o) => Some((o, w, s))
          None => None
        }
      _ => None
    },
    station_name: id => cloud.station_name(id),
    peer_named: given => match cloud.peer(bus, given) {
      Some(p) => p.id
      None => raise Failure("\{given} is this station: log in here without `station`")
    },
    ask: async fn(station, request) {
      let r = of_jv(request)
      let (answer, _) = bus.call_peer(station, jtext(r, "workspace"), jtext(r, "method").unwrap_or(""), r) catch {
        e => raise @terminals_logins.BusRefused(p54_message(e))
      }
      to_jv(answer)
    },
    spawn: fork,
    log: (said, about) => err_write("login: \{said} \{@jsjson.stringify(about)}\n"),
  })
  bus.on_peer_prefix("login.", async fn(peer, ws, meth, params, _) {
    let request = with_method(params, meth)
    let answer = part.heard_peer(peer, to_jv(request), match ws {
      Some(w) => @jsjson.JValue::Str(w)
      None => @jsjson.JValue::Null
    }) catch {
      e => raise BusError(p54_message(e))
    }
    (of_jv(answer), None)
  })
  let declared = of_jv(@terminals_logins.login_tool())
  bus.parts.tools([
    {
      name: jtext(declared, "name").unwrap_or("login"),
      declared,
      call: async fn(args, context) {
        match (try { Ok(@terminals_logins.run_login_tool(part.tool(), p54_session(context), to_jv(args))) } catch { e => Err(e) }) {
          Ok(text) => tool_answer(text)
          Err(e) => tool_answer(p54_message(e), error=true)
        }
      },
    },
  ])
  { logins, part }
}

///|
fn p54_person_of(v : Json?) -> @terminals_logins.Person? {
  match opt_text(v, "email") {
    Some(e) => Some({ email: e, name: opt_text(v, "name").unwrap_or("") })
    None => None
  }
}

///|
/// What the admin API's logins routes ask (api_routes accounts.mbt's `logins.`), by name.
async fn p54_logins_ask(l : P54Logins, op : String, a : Json) -> Json? {
  let s = (i : Int) => call_arg_text(a, i)
  let answer : Json = try {
    match op {
      // (whether the station keeps logins at all: a login card's answer from a chat's platform takes one, hub.ts)
      "logins.has" => Json::boolean(true)
      "logins.logins" => Json::array(l.logins.logins().map(of_jv))
      "logins.get" => l.logins.get(s(0)).map(of_jv).unwrap_or(Json::null())
      "logins.history" => Json::array(l.logins.history().map(of_jv))
      "logins.cancel" => of_jv(l.logins.cancel(s(0), by?=p54_person_of(call_arg(a, 1))))
      "logins.answer" => of_jv(l.logins.answer(s(0), call_arg(a, 1).map(to_jv), by?=p54_person_of(call_arg(a, 2))))
      "logins.paste" => of_jv(l.logins.paste(s(0), opt_true(call_arg(a, 1))))
      "logins.callback" => {
        let asked = call_arg(a, 1)
        let got = l.logins.callback(
          s(0),
          {
            method_: opt_text(asked, "method").unwrap_or("GET"),
            path: opt_text(asked, "path").unwrap_or("/"),
            headers: match opt_field(asked, "headers") {
              Some(Object(m)) => m.iter().filter_map(kv => as_text(kv.1).map(v => (kv.0, v))).collect()
              _ => []
            },
            body: opt_text(asked, "body"),
          },
          by?=p54_person_of(call_arg(a, 2)),
        )
        of_jv(got.to_json())
      }
      "logins.openPage" => Json::string(l.logins.open_page(s(0), by?=p54_person_of(call_arg(a, 1))))
      _ => return None
    }
  } catch {
    @terminals_logins.Refused(status, why) =>
      raise P54Refused("HttpError", { "status": Json::number(status.to_double()), "message": Json::string(why) })
    e => raise e
  }
  Some(answer)
}
