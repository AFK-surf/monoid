// The phones lent to the station over members' links (station/src/adb/module.ts `AdbLive`) and the devices attached
// to it (devices/module.ts `DevicesLive`), as adb_devices has them: everything they ask of the station and the machine
// is a call by its name (adb_devices `World`), answered here: the clock, the store's chats and cards, the hub, the
// control plane's workspaces, the events, the files, the processes, the sockets (the shell's `tcp.*`, `unix.*`), a
// member's mesh connection and its streams (the shell's `conn.*`, `istream.*`), and what other parts keep (the agents'
// runners, the jobs, the rigs, the forwards: asked through the bus).

///|
/// A socket the devices hold: the shell's stream, what came of it and was not taken yet, and its end.
priv struct P54Sock {
  conn : P54Wire
  chunks : Array[Bytes?]
  waiting : Array[@effect.Deferred[Unit]]
  closed : @effect.Deferred[Unit]
  mut reading : Bool
  mut destroyed : Bool
  mut kept : Bool
  /// The port the other end connects from, where it was accepted here (Node's `socket.remotePort`).
  remote_port : Int?
}

///|
/// A process the devices started: what it said, whether it ended, its end.
priv struct P54Proc {
  child : P54Child
  said : StringBuilder
  closed : @effect.Deferred[Unit]
  mut code : Int?
}

///|
/// The handles the devices' world gives out by number, and the functions it stands for (`callback`).
priv struct P54DevWorld {
  bus : LiveBus
  threads : @store_threads.Store
  cloud : P54Cloud
  socks : Map[Int, P54Sock]
  listeners : Map[Int, Json]
  procs : Map[Int, P54Proc]
  fns : Map[Int, async (Array[@jsjson.JValue]) -> @jsjson.JValue]
  mut next : Int
}

///|
/// A byte stream as the devices use it: the shell's (`tcp.*`, `unix.*`) or live_p5_4_io.c's.
priv struct P54Wire {
  read : async () -> Bytes?
  write : async (Bytes) -> Unit
  end : () -> Unit
  close : () -> Unit
}

///|
fn p54_wire_of_conn(c : P54Conn) -> P54Wire {
  let host = c.host
  {
    read: async fn() { c.read() },
    write: async fn(b) { c.write(b) },
    end: () => ignore(host.rt.fork_quiet(name="tcp end", async fn() {
      host.tcp_end(c.id) catch {
        _ => ()
      }
    })),
    close: () => c.close(),
  }
}

///|
fn p54_wire_of_net(n : P54Net) -> P54Wire {
  {
    read: async fn() { n.read() },
    write: async fn(b) {
      if !n.write(b) {
        raise Failure("the connection closed")
      }
    },
    end: () => n.end(),
    close: () => n.close(),
  }
}

///|
fn P54DevWorld::id(self : P54DevWorld) -> Int {
  self.next += 1
  self.next
}

///|
fn P54DevWorld::sock(self : P54DevWorld, conn : P54Wire, remote_port? : Int? = None) -> Json {
  let id = self.id()
  self.socks[id] = {
    conn,
    chunks: [],
    waiting: [],
    closed: @effect.Deferred::new(),
    reading: false,
    destroyed: false,
    kept: false,
    remote_port,
  }
  Json::number(id.to_double())
}

///|
/// Reads on, a chunk at a time, while something waits for one (a socket is paused otherwise, as Node's).
async fn P54DevWorld::fill(self : P54DevWorld, s : P54Sock) -> Unit {
  if s.reading {
    let d : @effect.Deferred[Unit] = @effect.Deferred::new()
    s.waiting.push(d)
    d.wait()
    return
  }
  s.reading = true
  let got = (s.conn.read)() catch { _ => None }
  s.reading = false
  if s.kept {
    // (kept alive with nothing read: what comes is let go)
  } else {
    s.chunks.push(got)
  }
  if got is None {
    s.destroyed = true
    ignore(s.closed.succeed(()))
  }
  for w in s.waiting {
    ignore(w.succeed(()))
  }
  s.waiting.clear()
}

///|
/// The port of an accepted connection's peer as the shell says it (`127.0.0.1:54321`, `[::1]:54321`): the digits
/// after its last colon.
fn p54_peer_port(peer : String?) -> Int? {
  guard peer is Some(p) && p.rev_find(":") is Some(i) else { return None }
  let digits = p[i + 1:].to_owned()
  guard digits != "" && digits.iter().all(c => c >= '0' && c <= '9') else { return None }
  match (try { Some(@string.parse_int(digits)) } catch { _ => None }) {
    Some(n) if n > 0 && n < 65536 => Some(n)
    _ => None
  }
}

///|
fn p54_int(v : Json?) -> Int {
  opt_num(v).unwrap_or(-1.0).to_int()
}

///|
fn P54DevWorld::sock_of(self : P54DevWorld, v : Json?) -> P54Sock raise {
  match self.socks.get(p54_int(v)) {
    Some(s) => s
    None => raise Failure("no such socket")
  }
}

///|
/// The process table (platform `processTable`): each process's pid, parent and group.
async fn p54_process_table(host : @host.Host) -> Json {
  let (code, out, _) = run_cmd(host, "ps", ["-axo", "pid=,ppid=,pgid="]) catch { _ => return Json::null() }
  if code != Some(0) {
    return Json::null()
  }
  let rows = []
  for line in out.split("\n") {
    let f = line.trim().split(" ").filter(x => x != "").map(x => x.to_owned()).to_array()
    if f.length() >= 3 {
      let n = (s : String) => Json::number((@string.parse_int(s) catch { _ => -1 }).to_double())
      rows.push(({ "pid": n(f[0]), "ppid": n(f[1]), "pgid": n(f[2]) } : Json))
    }
  }
  Json::array(rows)
}

///|
/// The pids listening on 127.0.0.1:`port` (platform `tcpPortPids`).
async fn p54_port_pids(host : @host.Host, port : Int) -> Json {
  let me = @drive.pid()
  if platform() == "darwin" {
    // (lsof -i names the sockets either end of which is on the port: the listener's own end is this process's)
    let (_, out, _) = run_cmd(host, "lsof", ["-nP", "-a", "-iTCP@127.0.0.1:\{port}", "-sTCP:ESTABLISHED", "-Fp"]) catch {
      _ => return Json::array([])
    }
    let pids : Array[Int] = []
    for l in out.split("\n") {
      guard l.has_prefix("p") else { continue }
      match (try { Some(@string.parse_int(l[1:].to_owned())) } catch { _ => None }) {
        Some(p) if p != me && !pids.contains(p) => pids.push(p)
        _ => ()
      }
    }
    return Json::array(pids.map(p => Json::number(p.to_double())))
  }
  // (Linux: the connection's inode from /proc/net/tcp, local 127.0.0.1:<port>, then whose descriptor it is)
  let tables = []
  for f in ["/proc/net/tcp", "/proc/net/tcp6"] {
    tables.push(shell_read_text(host, f).unwrap_or(""))
  }
  let inodes = @ops_platform.tcp_port_inodes(tables, port)
  if inodes.length() == 0 {
    return Json::array([])
  }
  let pids : Array[Json] = []
  for name in attempt(() => @drive.names("/proc")).unwrap_or([]) {
    let pid = (try { Some(@string.parse_int(name)) } catch { _ => None })
    guard pid is Some(pid) && pid != me else { continue }
    for fd in attempt(() => @drive.names("/proc/\{pid}/fd")).unwrap_or([]) {
      match p54_readlink(host, "/proc/\{pid}/fd/\{fd}") {
        Some(link) =>
          match @ops_platform.socket_inode(link) {
            Some(inode) if inodes.contains(inode) => {
              pids.push(Json::number(pid.to_double()))
              break
            }
            _ => ()
          }
        None => ()
      }
    }
  }
  Json::array(pids)
}

///|
/// A process's start, ms since the epoch (platform `startTimeOf`), as the system says it: `ps -o lstart=` is in the
/// machine's own time zone.
async fn p54_start_time(host : @host.Host, pid : Int) -> Json {
  ignore(host)
  (start_time_of(pid)).map(jn).unwrap_or(Json::null())
}

///|
/// adb on this machine (adb/link.ts `adbPath`): the first of `adbCandidates` that is a file.
fn p54_adb_path() -> String? {
  let env : Map[String, Json] = Map([])
  for k in ["PATH", "PATHEXT", "ANDROID_HOME", "ANDROID_SDK_ROOT", "HOME", "LOCALAPPDATA"] {
    if env_get(k) is Some(v) { env[k] = Json::string(v) }
  }
  let exe = if is_windows() { "adb.exe" } else { "adb" }
  let delimiter = if is_windows() { ";" } else { ":" }
  let on_path = env_get("PATH").unwrap_or("").split(delimiter).map(d => path([d.to_owned(), exe])).find_first(p => (try { Ok(@drive.stat(p)) } catch { e => Err(e) }) is Ok(st) && st.file)
  for p in @adb_devices.adb_candidates(to_jv(Json::object(env)), on_path, exe, sep(), delimiter) {
    if (try { Ok(@drive.stat(p)) } catch { e => Err(e) }) is Ok(st) && st.file {
      return Some(p)
    }
  }
  None
}

///|
/// What the devices ask by name (adb_devices `World.call`).
async fn P54DevWorld::call(self : P54DevWorld, name : String, given : Array[@jsjson.JValue]) -> @jsjson.JValue {
  let bus = self.bus
  let host = bus.host
  let args = given.map(of_jv)
  let a = (i : Int) => args.get(i)
  let s = (i : Int) => opt_str(a(i)).unwrap_or("")
  let jarr = Json::array(args)
  let fn_of = (v : Json?) => match opt_num(opt_field(v, "$fn")) {
    Some(n) => self.fns.get(n.to_int())
    None => None
  }
  let answer : Json = match name {
    "log.info" | "log.warn" | "log.error" => {
      err_write("\{name[4:]} \{s(0)}: \{s(1)} \{a(2).unwrap_or(Json::null()).stringify()}\n")
      Json::null()
    }
    // the machine
    "remote.ask" | "cloud.station" | "cloud.home" | "cloud.removed" | "events.tell" =>
      dispatch_infra(bus, name, args).unwrap_or(Json::null())
    "platform.startTimeOf" => p54_start_time(host, p54_int(a(0)))
    "platform.tcpPortPids" => p54_port_pids(host, p54_int(a(0)))
    "platform.processTable" => p54_process_table(host)
    "platform.cwds" => {
      let out = []
      let pids = match a(0) {
        Some(Array(x)) => x
        _ => []
      }
      if platform() != "darwin" {
        // (Linux: each one's /proc/<pid>/cwd)
        for p in pids {
          let pid = p54_int(Some(p))
          match p54_readlink(host, "/proc/\{pid}/cwd") {
            Some(dir) => out.push(Json::array([Json::number(pid.to_double()), Json::string(dir)]))
            None => ()
          }
        }
      } else if pids.length() > 0 {
        // (lsof exits 1 where one of them is gone: what it found is still said)
        let list = pids.map(p => p54_int(Some(p)).to_string()).join(",")
        let (_, said, _) = run_cmd(host, "lsof", ["-a", "-d", "cwd", "-p", list, "-Fpn"]) catch { _ => (None, "", "") }
        let mut pid = -1
        for line in said.split("\n") {
          if line.has_prefix("p") {
            pid = (try { @string.parse_int(line[1:].to_owned()) } catch { _ => -1 })
          } else if line.has_prefix("n") && pid >= 0 {
            out.push(Json::array([Json::number(pid.to_double()), Json::string(line[1:].to_owned())]))
          }
        }
      }
      Json::array(out)
    }
    "adb.path" => jopt(p54_adb_path())
    "previous.gone" => {
      (bus.previous_gone)()
      Json::null()
    }
    // the processes
    "proc.signal" => {
      ignore(kill(p54_int(a(0)), s(1)))
      Json::null()
    }
    "proc.run" => {
      let o = a(0)
      let env = if opt_true(opt_field(o, "adbEnv")) { Some(env_all() + [("ADB_MDNS_AUTO_CONNECT", "0")]) } else { None }
      let ms = match opt_num(opt_field(o, "timeout")) { Some(t) if t > 0.0 => t.to_int(); _ => 0 }
      match run_capture(host, opt_text(o, "file").unwrap_or(""), opt_strs(opt_field(o, "args")), env?, ms~, group=true) {
        Some((_, _, _, _, true)) =>
          { "timedOut": Json::boolean(true), "code": Json::null(), "out": Json::string(""), "err": Json::string("") }
        Some((code, _, out, err, false)) =>
          { "code": code.map(ji).unwrap_or(Json::null()), "out": jstr(out), "err": jstr(err) }
        None => raise SysError("spawn failed")
      }
    }
    "proc.start" => {
      let o = a(0)
      let env = env_all() +
        (if opt_true(opt_field(o, "adbEnv")) { [("ADB_MDNS_AUTO_CONNECT", "0")] } else { [] }) +
        (match opt_field(o, "env") {
          Some(Object(m)) => m.iter().filter_map(kv => as_text(kv.1).map(v => (kv.0, v))).collect()
          _ => []
        })
      let said = StringBuilder::new()
      let closed : @effect.Deferred[Unit] = @effect.Deferred::new()
      let id = self.id()
      let child = p54_spawn(
        host,
        opt_text(o, "file").unwrap_or(""),
        opt_strs(opt_field(o, "args")),
        env~,
        stdin_piped=false,
        group=true,
        out=b => said.write_string(@utf8.decode_lossy(b)),
        err=b => said.write_string(@utf8.decode_lossy(b)),
        close=(code, _) => {
          if self.procs.get(id) is Some(p) { p.code = code }
          ignore(closed.succeed(()))
        },
      )
      self.procs[id] = { child, said, closed, code: None }
      Json::number(id.to_double())
    }
    "proc.said" =>
      match self.procs.get(p54_int(a(0))) {
        Some(p) =>
          {
            "said": Json::string(p.said.to_string()),
            "ended": Json::boolean(!p.child.running),
            "exitCode": p.code.map(c => Json::number(c.to_double())).unwrap_or(Json::null()),
          }
        None => Json::null()
      }
    "proc.kill" => {
      if self.procs.get(p54_int(a(0))) is Some(p) { ignore(kill(p.child.proc.pid, opt_str(a(1)).unwrap_or("SIGTERM"), group=true)) }
      Json::null()
    }
    "proc.closed" => {
      if self.procs.get(p54_int(a(0))) is Some(p) { p.closed.wait() }
      Json::null()
    }
    "proc.pid" =>
      match self.procs.get(p54_int(a(0))) {
        Some(p) => Json::number(p.child.proc.pid.to_double())
        None => Json::null()
      }
    // the sockets: this machine's own (127.0.0.1, a Unix socket's path)
    "net.listen" => {
      let o = a(0)
      let l = host.tcp_listen_local(opt_num(opt_field(o, "port")).unwrap_or(0.0).to_int())
      let id = self.id()
      self.listeners[id] = l.id
      { "id": Json::number(id.to_double()), "port": Json::number(l.port.to_double()) }
    }
    "net.accept" =>
      match self.listeners.get(p54_int(a(0))) {
        Some(lid) => {
          let got = host.accept(lid) catch { _ => return @jsjson.JValue::Null }
          self.sock(
            p54_wire_of_conn({ host, id: got.id, closed: false }),
            remote_port=p54_peer_port(if got.peer == "" { None } else { Some(got.peer) }),
          )
        }
        None => Json::null()
      }
    "net.close" => {
      match self.listeners.get(p54_int(a(0))) {
        Some(lid) => {
          self.listeners.remove(p54_int(a(0)))
          host.listen_close(lid)
        }
        None => ()
      }
      Json::null()
    }
    "net.connect" => {
      let o = a(0)
      let conn = match opt_text(o, "path") {
        Some(p) => p54_wire_of_conn(p54_unix_open(host, p))
        None => {
          let h = opt_text(o, "host").unwrap_or("127.0.0.1")
          let port = p54_int(opt_field(o, "port"))
          let open = async fn() {
            if h == "127.0.0.1" || h == "localhost" {
              p54_wire_of_conn(p54_tcp_open(host, port))
            } else {
              p54_wire_of_net(p54_net_tcp(host, h, port))
            }
          }
          match opt_num(opt_field(o, "timeout")) {
            Some(ms) if ms > 0.0 =>
              match @effect.timeout(ms.to_int(), open) {
                Some(w) => w
                None => raise Failure(opt_text(o, "why").unwrap_or("connect \{h}:\{port} timed out"))
              }
            _ => open()
          }
        }
      }
      self.sock(conn)
    }
    "net.first" => {
      let sk = self.sock_of(a(0))
      while sk.chunks.is_empty() {
        self.fill(sk)
      }
      Json::boolean(sk.chunks[0] is Some(_))
    }
    "net.keep" => {
      let sk = self.sock_of(a(0))
      sk.kept = true
      sk.chunks.clear()
      fork_bg(host, "socket kept", async fn() {
        while !sk.destroyed {
          self.fill(sk)
        }
      })
      Json::null()
    }
    "net.read" => {
      let sk = self.sock_of(a(0))
      while sk.chunks.is_empty() {
        self.fill(sk)
      }
      match sk.chunks[0] {
        None => Json::null()
        Some(b) => {
          ignore(sk.chunks.remove(0))
          Json::string(@drive.base64(b))
        }
      }
    }
    "net.write" => {
      let sk = self.sock_of(a(0))
      if sk.destroyed {
        raise Failure("the adb connection closed")
      }
      (sk.conn.write)(@drive.from_base64(s(1)))
      Json::null()
    }
    "net.end" => {
      let sk = self.sock_of(a(0))
      match a(1) {
        Some(String(b)) => (sk.conn.write)(@drive.from_base64(b))
        _ => ()
      }
      (sk.conn.end)()
      Json::null()
    }
    "net.resume" => Json::null()
    "net.destroy" => {
      match self.socks.get(p54_int(a(0))) {
        Some(sk) => {
          sk.destroyed = true
          (sk.conn.close)()
          ignore(sk.closed.succeed(()))
        }
        None => ()
      }
      Json::null()
    }
    "net.destroyed" =>
      match self.socks.get(p54_int(a(0))) {
        Some(sk) => Json::boolean(sk.destroyed)
        None => Json::boolean(true)
      }
    "net.closed" => {
      self.sock_of(a(0)).closed.wait()
      Json::null()
    }
    // (where an accepted socket comes from: who asks the adb door, and of which chat's server, is told by its port)
    "net.remotePort" =>
      match self.socks.get(p54_int(a(0))) {
        Some({ remote_port: Some(port), .. }) => Json::number(port.to_double())
        _ => Json::null()
      }
    "net.join" => {
      let one = self.sock_of(a(0))
      let two = self.sock_of(a(1))
      // (each way's own: what one says written to the other, as Node's pipe; what came already first)
      let carry = async fn(from : P54Sock, to : P54Sock) {
        for c in from.chunks {
          match c {
            Some(b) => (to.conn.write)(b) catch { _ => () }
            None => ()
          }
        }
        from.chunks.clear()
        while (from.conn.read)() is Some(b) {
          (to.conn.write)(b) catch {
            _ => break
          }
        }
        (to.conn.end)()
        from.destroyed = true
        ignore(from.closed.succeed(()))
      }
      fork_bg(host, "join", async fn() { carry(one, two) })
      fork_bg(host, "join", async fn() { carry(two, one) })
      Json::null()
    }
    "serial.open" => {
      // (stty set its speed already: opened raw here at that speed, unless a baud is given)
      let baud = match opt_num(a(1)) {
        Some(b) => b.to_int()
        None => 0
      }
      self.sock(p54_wire_of_net(p54_net_serial(host, s(0), baud)))
    }
    // the store's chats and cards (writes/requests needing bus notifications)
    "store.latestThread" | "store.latestThreadIfReady" | "store.insertMessage" | "store.withdrawCard" | "store.restateCard" | "cardOutcomes.save" =>
      dispatch_threads_card(bus, self.threads, name, args, async fn(cb, cb_args) {
        match fn_of(Some(cb)) {
          Some(f) => Some(of_jv(f(cb_args.map(to_jv))))
          None => None
        }
      }).unwrap_or(Json::null())
    "store.sessionChat" | "store.sessionThread" => (bus.hub_ask.val)(name, jarr)
    // the hub and the agents' side (P5-2's)
    "hub.identity" | "hub.notify" | "hub.shared" | "hub.prepareCardPosts" | "hub.prepareLatestThreads" | "chat.post" | "agents.runners" =>
      (bus.hub_ask.val)(name, jarr)
    "jobs.watched" => (bus.jobs_ask.val)(name, jarr)
    // (the forwards and the rigs are P5-1's: asked of this station's own handlers on the bus, the jobs' where none is)
    "forwards.openDevice" | "forwards.closeDevice" =>
      match (try { Ok(bus.forwards_call(name, args)) } catch { e => Err(e) }) {
        Ok(got) => got
        Err(BusError(_)) => (bus.jobs_ask.val)(name, jarr)
        Err(e) => raise e
      }
    "rigs.list" | "rigs.use" | "rigs.done" => bus.rigs_call(name, args)
    // the control plane's workspaces
    "cloud.memberships" => Json::array(self.cloud.memberships)
    "cloud.peers" =>
      match self.cloud.memberships.iter().find_first(m => jtext(m, "workspace") == Some(s(0))) {
        Some(m) => opt_field(Some(m), "peers").unwrap_or(Json::array([]))
        None => Json::array([])
      }
    "cloud.nameOf" => {
      let id = s(0)
      let mut named = id
      for m in self.cloud.memberships {
        match opt_field(Some(m), "peers") {
          Some(Array(ps)) =>
            for p in ps {
              if jtext(p, "id") == Some(id) {
                match jtext(p, "name") {
                  Some(n) if n != "" => named = n
                  _ => ()
                }
              }
            }
          _ => ()
        }
      }
      Json::string(named)
    }
    "cloud.removedLater" => {
      // (said once the station is taken out of its workspace, as the control plane tells it, or as it stops here:
      // adb/link.ts `removed`, its listener let go either way)
      let gone : @effect.Deferred[Unit] = @effect.Deferred::new()
      let off = (bus.cloud_listen.val)(_ => if bus_cloud_removed(bus) { ignore(gone.succeed(())) })
      defer off()
      if !bus_cloud_removed(bus) {
        @effect.race(async fn() { gone.wait() }, async fn() { ignore(bus.stopped.wait()) })
      }
      Json::null()
    }
    "grants.home" => jopt(bus_home(bus))
    "sources.changed" => {
      (bus.overview_changed.val)()
      Json::null()
    }
    _ => (bus.hub_ask.val)(name, jarr)
  }
  to_jv(answer)
}

///|
priv struct P54Devices {
  adb : @adb_devices.Adb
  devices : @adb_devices.Devices
  world : P54DevWorld
  dev : @adb_devices.World
}

///|
fn p54_declared_tool(decl : @jsjson.JValue, call : async (String, Json) -> String) -> PartTool {
  let declared = of_jv(decl)
  {
    name: jtext(declared, "name").unwrap_or(""),
    declared,
    call: async fn(args, context) {
      match (try { Ok(call(p54_session(context), args)) } catch { e => Err(e) }) {
        Ok(text) => tool_answer(text)
        Err(e) => tool_answer(@adb_devices.message_of(e), error=true)
      }
    },
  }
}

///|
/// The phones' and the devices' parts made and said (adb/module.ts, devices/module.ts).
async fn p54_devices_start(bus : LiveBus, threads : @store_threads.Store, cloud : P54Cloud, screens : P54Screens) -> P54Devices {
  let host = bus.host
  let w0 : P54DevWorld = {
    bus,
    threads,
    cloud,
    socks: Map([]),
    listeners: Map([]),
    procs: Map([]),
    fns: Map([]),
    next: 0,
  }
  let (zh, en) = catalogs_json()
  let world = @adb_devices.World::new(
    host,
    bus.store,
    threads,
    async fn(name, args) { w0.call(name, args) },
    f => {
      let id = w0.id()
      w0.fns[id] = f
      @jsjson.JValue::Obj([("$fn", @jsjson.JValue::Num(id.to_double()))])
    },
    () => wall_ms().to_double(),
    f => ignore(host.rt.fork_quiet(name="devices", async fn() { f() catch { _ => () } })),
    @session_chats.Words::new(to_jv(zh), to_jv(en)),
  )
  world.set_lang((bus.lang.val)())
  let adb = @adb_devices.Adb::new(
    world,
    bus.db,
    @screens.server_file(screens.io),
    record=path([bus.data, "run", "adb-servers.json"]),
    admit=!is_windows(),
    outcomes=true,
  )
  let registry = @adb_devices.DeviceRegistry::new(world, bus.db)
  let devices = @adb_devices.Devices::new(world, registry, phones=adb)
  // An offer or an ask on a member's link (`adb`), given the stream the mesh opened for it.
  bus.parts.streams("adb", async fn(asked) {
    adb.stream(
      to_jv(opt_field(Some(asked), "conn").unwrap_or(Json::null())),
      to_jv(opt_field(Some(asked), "viewer").unwrap_or(Json::null())),
      to_jv(opt_field(Some(asked), "head").unwrap_or(Json::null())),
      to_jv(p54_stream_handle(asked)),
    )
  })
  bus.parts.tools([
    p54_declared_tool(@adb_devices.phone_use_decl, async fn(session, args) { adb.phone_use(session, to_jv(args)) }),
    p54_declared_tool(@adb_devices.phone_send_decl, async fn(session, args) { adb.phone_send(session, to_jv(args)) }),
    p54_declared_tool(@adb_devices.adb_devices_decl, async fn(_, _) { adb.adb_devices() }),
    p54_declared_tool(@adb_devices.device_list_decl, async fn(session, _) { devices.device_list(session) }),
    p54_declared_tool(@adb_devices.device_use_decl, async fn(session, args) { devices.device_use(session, to_jv(args)) }),
  ])
  // What a member's app asks of the devices attached here.
  let route = (meth : String, pattern : String) => ({
    meth,
    path: pattern,
    answer: async fn(r) {
      let asked = jtext(r, "path").unwrap_or("")
      let body = match jtext(r, "rawBody") {
        Some(b) => b
        None => jtext(r, "body").unwrap_or("")
      }
      match devices.route(meth, asked, to_jv(opt_field(Some(r), "viewer").unwrap_or(Json::null())), body) {
        Some((status, value)) => { "status": Json::number(status.to_double()), "body": Json::string(@jsjson.stringify(value)) }
        None => { "status": Json::number(404.0), "body": Json::string("{\"error\":\"no such route\"}") }
      }
    },
  } : PartRoute)
  bus.parts.routes([route("GET", "^/devices$"), route("POST", "^/devices$"), route("DELETE", "^/devices/([0-9a-f]{16})$")])
  // Another station's asks of the devices here (`devices.`: its list, a device reached).
  bus.on_peer_prefix("devices.", async fn(_peer, ws, meth, params, _) {
    if meth != "devices.list" {
      raise BusError("unknown method \{meth}")
    }
    // (the workspace it is asked in: the bus's, else what the request names)
    let workspace = match ws {
      Some(w) => w
      None => jtext(params, "workspace").unwrap_or("")
    }
    (of_jv(devices.bus_list(to_jv(Json::string(workspace)))), None)
  })
  // A device here, reached from another station's chat (mesh/peer-http.ts's tunnel `device`): `probe` only says it
  // is there; else its connection opened, what came with the ask (`carry`) sent first, and the bytes carried both ways
  // between it and the tunnel's stream until either ends.
  bus.here_device.val = async fn(ask, conn) {
    let workspace = jtext(ask, "workspace").unwrap_or("")
    // (P5-1's HereLocal names it `device`; an ask of before, `id`)
    let id = match jtext(ask, "device") {
      Some(d) => d
      None => jtext(ask, "id").unwrap_or("")
    }
    let probe = opt_true(opt_field(Some(ask), "probe"))
    let got = devices.side_device(workspace, id, probe) catch {
      e => raise P54Refused("HttpError", { "status": 404, "message": Json::string(@adb_devices.message_of(e)) })
    }
    if probe {
      return
    }
    // (the tunnel's stream as P5-1 handed it, `{stream, kind, carry}`: what came past its head carried with it, once)
    let (stream, carry) = match conn {
      { "stream": _, .. } => (p54_member_stream(host, p54_stream_handle(conn)), p54_bytes_of(opt_field(Some(conn), "carry")))
      _ => (p54_member_stream(host, conn), p54_bytes_of(opt_field(Some(ask), "carry")))
    }
    p54_device_tunnel(w0, of_jv(got), carry, stream)
  }
  { adb, devices, world: w0, dev: world }
}

///|
/// A device's `reach` (the devices' world's function by its number) called, and the connection it opened carried both
/// ways to one of the shell's loopback connections, whose id is given (`{"id": …}`): what the forwards take a socket as.
async fn p54_reach_forward(d : P54Devices, reach : Json) -> Json {
  let w = d.world
  let host = w.bus.host
  let id = match reach {
    { "$fn": Number(n, ..), .. } => n.to_int()
    _ => raise Failure("no way to reach the device")
  }
  guard w.fns.get(id) is Some(f) else { raise Failure("no way to reach the device") }
  let opened = of_jv(f([]))
  guard as_num(opened) is Some(n) && w.socks.get(n.to_int()) is Some(sock) else {
    raise Failure("the device was not reached")
  }
  let wire = sock.conn
  w.socks.remove(n.to_int())
  // (a pair of the shell's own: one end given, the other carried to the device)
  let listening = host.tcp_listen_local(0)
  let lid = listening.id
  let port = listening.port
  let accepting : @effect.Deferred[Json] = @effect.Deferred::new()
  fork_bg(host, "device forward accept", async fn() {
    let accepted = host.accept(lid) catch {
      _ => {
        ignore(accepting.succeed(Json::null()))
        return
      }
    }
    ignore(accepting.succeed(accepted.id))
  })
  let given = p54_tcp_open(host, port)
  let inner_id = accepting.wait()
  host.listen_close(lid)
  if inner_id is Null {
    given.close()
    (wire.close)()
    raise Failure("the device's connection was not made")
  }
  let inner : P54Conn = { host, id: inner_id, closed: false }
  fork_bg(host, "device forward in", async fn() {
    let read = wire.read
    while true {
      let got = read() catch { _ => None }
      guard got is Some(b) else { break }
      inner.write(b) catch {
        _ => break
      }
    }
    inner.close()
  })
  fork_bg(host, "device forward out", async fn() {
    let write = wire.write
    while inner.read() is Some(b) {
      write(b) catch {
        _ => break
      }
    }
    (wire.close)()
    inner.close()
  })
  { "id": given.id }
}

///|
/// What the routes ask of the phones and devices by name.
async fn p54_devices_ask(d : P54Devices, op : String, a : Json) -> Json? {
  let s = (i : Int) => call_arg_text(a, i)
  let answer : Json = match op {
    "devices.listed" => Json::array(d.devices.listed(s(0)).map(of_jv))
    "devices.phones" => Json::array(d.devices.phones(s(0)).map(of_jv))
    "devices.all" => Json::array(d.devices.all(s(0), s(1)).map(of_jv))
    "adb.phonesShown" => Json::array(d.adb.phones_shown(s(0)).map(of_jv))
    // (a station that only runs tasks reaches its devices so: `Rig`'s reach, P5-1's; the socket by its number, used
    // through `devices.net.*` as the devices' world uses it)
    "devices.reach" => of_jv(d.devices.side_device(s(0), s(1), opt_true(call_arg(a, 2))))
    // (a device attached here, forwarded to a chat's port by P5-1's forwards: `[session, reach]`, the target's `reach`
    // called and what it opened, a TCP connection or a serial port, given as one of the shell's loopback connections)
    "devices.reachForward" => p54_reach_forward(d, call_arg(a, 1).unwrap_or(Json::null()))
    // (a tasks-only station's device a chat's grant lets it reach (P5-1's rigs, rig.mbt `reach`: devices/connect.ts
    // `reachDevice` of the device as its owner signed it): the socket's number; its end waited for, the socket let go
    // then; and it closed)
    "devices.reachDevice" => of_jv(@adb_devices.reach_device(d.dev, to_jv(call_arg(a, 0).unwrap_or(Json::null()))))
    "devices.socketClosed" => {
      let id = p54_int(call_arg(a, 0))
      match d.world.socks.get(id) {
        Some(sk) => {
          sk.closed.wait()
          d.world.socks.remove(id)
        }
        None => ()
      }
      Json::null()
    }
    "devices.socketDestroy" => of_jv(d.world.call("net.destroy", [to_jv(call_arg(a, 0).unwrap_or(Json::null()))]))
    // (who may use a device forwarded to a session's port: devices/module.ts `admitFor`, null to let them in)
    "devices.admit" => {
      let holders = match call_arg(a, 2) {
        Some(Array(xs)) => xs.filter_map(x => as_num(x).map(n => n.to_int()))
        _ => []
      }
      jopt(@adb_devices.session_gate(d.dev, s(0), holders, "this device's port is another chat's: ask for the device with device_use in this chat"))
    }
    // (P5-1's rigs open a device's forward here once a chat may use it: sources.ts `forward`)
    "sources.hasForward" => Json::boolean(true)
    "sources.forward" => Json::string(d.devices.forward(s(0), to_jv(call_arg(a, 1).unwrap_or(Json::null()))))
    // (a test's: a device's TCP reached as the devices reach one, a line sent and what came back)
    "test.reachTcp" if p54_testing() => {
      let w = d.world
      let sock = of_jv(w.call("net.connect", [to_jv({ "host": Json::string(s(0)), "port": Json::number(opt_num(call_arg(a, 1)).unwrap_or(0.0)) })]))
      ignore(w.call("net.write", [to_jv(sock), to_jv(Json::string(@drive.base64(@utf8.encode(s(2)))))]))
      let got = of_jv(w.call("net.read", [to_jv(sock)]))
      ignore(w.call("net.destroy", [to_jv(sock)]))
      match got {
        String(b) => Json::string(@utf8.decode_lossy(@drive.from_base64(b)))
        _ => Json::null()
      }
    }
    // (a test's: a share's wait for the station taken out of its workspace (link.mbt `cloud.removedLater`), the control
    // plane's state and its listeners the test's for it: said as the plane tells the removal, the station still
    // running, its listener let go; said at once where it was removed before)
    "test.removedLater" if p54_testing() => {
      let bus = d.world.bus
      let (state_was, listen_was) = (bus.cloud_state.val, bus.cloud_listen.val)
      let removed = Ref(false)
      let listeners : Array[(Int, (Json?) -> Unit)] = []
      let next = Ref(0)
      let listening : @effect.Deferred[Unit] = @effect.Deferred::new()
      bus.cloud_state.val = () => if removed.val { Some({ "removed_at": Json::number(1.0) }) } else { state_was() }
      bus.cloud_listen.val = f => {
        next.val += 1
        let id = next.val
        listeners.push((id, f))
        ignore(listening.succeed(()))
        () => ignore(listeners.search_by(x => x.0 == id).map(i => listeners.remove(i)))
      }
      let said : @effect.Deferred[Unit] = @effect.Deferred::new()
      fork_bg(bus.host, "test removedLater", async fn() {
        ignore(d.world.call("cloud.removedLater", []))
        ignore(said.succeed(()))
      })
      listening.wait()
      let waited = !said.is_done() && listeners.length() == 1
      removed.val = true
      for l in listeners.copy() {
        (l.1)(None)
      }
      said.wait()
      let let_go = listeners.is_empty()
      // (removed before it is asked: at once)
      ignore(d.world.call("cloud.removedLater", []))
      let none_left = listeners.is_empty()
      bus.cloud_state.val = state_was
      bus.cloud_listen.val = listen_was
      {
        "waited": Json::boolean(waited),
        "running": Json::boolean(!bus.stopped.is_done()),
        "letGo": Json::boolean(let_go && none_left),
      }
    }
    // (a test's: a tasks-only station's device reached as its rig reaches one, then let go: its end told)
    "test.rigReach" if p54_testing() => {
      let socket = bus_rig_reach(d.world.bus, call_arg(a, 0).unwrap_or(Json::null()))
      let ended : @effect.Deferred[Unit] = @effect.Deferred::new()
      (socket.on_close)(() => ignore(ended.succeed(())))
      (socket.destroy)()
      ended.wait()
      // (told once more after the end: at once)
      let again = Ref(false)
      (socket.on_close)(() => again.val = true)
      Json::boolean(again.val)
    }
    // (a test's: a device here reached as another station's tunnel reaches it, the tunnel's stream a connection to
    // the test's port; the slots live_p5_4_io.c holds; a connection read to its end, one called off as it connects)
    "test.hereDevice" if p54_testing() => {
      let got = d.devices.side_device(s(0), s(1), false)
      let c = p54_tcp_open(d.world.bus.host, opt_num(call_arg(a, 2)).unwrap_or(0.0).to_int())
      let stream : @terminals_logins.Stream = {
        read: async fn() { c.read() },
        write: async fn(b) { c.write(b) },
        finish: async fn() {
          d.world.bus.host.tcp_end(c.id) catch {
            _ => ()
          }
        },
      }
      p54_device_tunnel(d.world, of_jv(got), @utf8.encode(s(3)), stream)
      c.close()
      Json::boolean(true)
    }
    "test.ioHeld" if p54_testing() => Json::number(p54io_held_ffi().to_double())
    "test.netEof" if p54_testing() => {
      let n = p54_net_tcp(d.world.bus.host, s(0), opt_num(call_arg(a, 1)).unwrap_or(0.0).to_int())
      let held = p54io_held_ffi()
      let got = StringBuilder::new()
      while n.read() is Some(b) {
        got.write_string(@utf8.decode_lossy(b))
      }
      { "held": Json::number(held.to_double()), "after": Json::number(p54io_held_ffi().to_double()), "got": Json::string(got.to_string()) }
    }
    "test.netCalledOff" if p54_testing() => {
      let host = d.world.bus.host
      let ms = opt_num(call_arg(a, 2)).unwrap_or(100.0).to_int()
      let t0 = @host.now()
      let opened = @effect.timeout(ms, async fn() { p54_net_tcp(host, s(0), opt_num(call_arg(a, 1)).unwrap_or(0.0).to_int()) }) catch {
        _ => None
      }
      if opened is Some(n) { n.close() }
      { "held": Json::number(p54io_held_ffi().to_double()), "elapsedMs": Json::number((@host.now() - t0).to_double()) }
    }
    "test.netBackpressure" if p54_testing() => {
      let host = d.world.bus.host
      let n = p54_net_tcp(host, s(0), opt_num(call_arg(a, 1)).unwrap_or(0.0).to_int())
      let chunk = Bytes::make(262144, b'x')
      let t0 = @host.now()
      let mut writes = 0
      let mut hit_full = false
      for _ in 0..<128 {
        if !n.write(chunk) {
          hit_full = true
          break
        }
        writes += 1
      }
      let elapsed = (@host.now() - t0).to_double()
      n.close()
      {
        "hitFull": Json::boolean(hit_full),
        "writes": Json::number(writes.to_double()),
        "elapsedMs": Json::number(elapsed),
        "heldAfter": Json::number(p54io_held_ffi().to_double()),
      }
    }
    "test.netWriteEndOrder" if p54_testing() => {
      let host = d.world.bus.host
      let n = p54_net_tcp(host, s(0), opt_num(call_arg(a, 1)).unwrap_or(0.0).to_int())
      let chunks = opt_num(call_arg(a, 2)).unwrap_or(16.0).to_int()
      let chunk = Bytes::make(65536, b'a')
      let mut all_written = true
      for _ in 0..<chunks {
        if !n.write(chunk) {
          all_written = false
          break
        }
      }
      n.end()
      let got = StringBuilder::new()
      while n.read() is Some(b) {
        got.write_string(@utf8.decode_lossy(b))
      }
      {
        "allWritten": Json::boolean(all_written),
        "reply": Json::string(got.to_string()),
        "heldAfter": Json::number(p54io_held_ffi().to_double()),
      }
    }
    "test.pumpConnectErrors" if p54_testing() => {
      let host = d.world.bus.host
      let pump = Pump::new(host)
      // 1. Write failure propagates error and closes the socket
      let write_err : @effect.Deferred[String] = @effect.Deferred::new()
      let write_closed : @effect.Deferred[Unit] = @effect.Deferred::new()
      let write_connected : @effect.Deferred[Unit] = @effect.Deferred::new()
      let read_hold : @effect.Deferred[Bytes?] = @effect.Deferred::new()
      let sock = pump.connect_with(
        async fn() { (Json::number(1.0), async fn() { ignore(read_hold.succeed(None)) }) },
        async fn(_id, _b) { raise Failure("Broken pipe") },
        async fn(_id) { read_hold.wait() },
        async fn(_id) {  },
        {
          connected: () => ignore(write_connected.succeed(())),
          data: _ => (),
          error: m => ignore(write_err.succeed(m)),
          closed: () => ignore(write_closed.succeed(())),
        },
      )
      write_connected.wait()
      (sock.write)("hello")
      let w_err = write_err.wait()
      write_closed.wait()
      let w_destroyed = (sock.destroyed)()
      // 2. unix_open error code preservation (ENOENT, ECONNREFUSED, and passthrough)
      let open_err = async fn(path : String) -> String {
        let err_d : @effect.Deferred[String] = @effect.Deferred::new()
        let cls_d : @effect.Deferred[Unit] = @effect.Deferred::new()
        ignore(
          pump.connect(path, {
            connected: () => (),
            data: _ => (),
            error: m => ignore(err_d.succeed(m)),
            closed: () => ignore(cls_d.succeed(())),
          }),
        )
        let msg = err_d.wait()
        cls_d.wait()
        msg
      }
      let missing_code = open_err(s(0))
      let refused_code = open_err(s(1))
      let other_d : @effect.Deferred[String] = @effect.Deferred::new()
      let other_c : @effect.Deferred[Unit] = @effect.Deferred::new()
      ignore(
        pump.connect_with(
          async fn() { raise Failure("Permission denied") },
          async fn(_id, _b) {  },
          async fn(_id) { None },
          async fn(_id) {  },
          {
            connected: () => (),
            data: _ => (),
            error: m => ignore(other_d.succeed(m)),
            closed: () => ignore(other_c.succeed(())),
          },
        ),
      )
      let other_code = other_d.wait()
      other_c.wait()
      {
        "writeErr": Json::string(w_err),
        "writeDestroyed": Json::boolean(w_destroyed),
        "missingCode": Json::string(missing_code),
        "refusedCode": Json::string(refused_code),
        "otherCode": Json::string(other_code),
      }
    }
    _ =>
      if op.has_prefix("devices.net.") {
        of_jv(d.world.call(op[8:].to_owned(), (match a { Array(xs) => xs; _ => [] }).map(to_jv)))
      } else {
        return None
      }
  }
  Some(answer)
}

///|
/// A device's connection (the devices' world's socket `sock`) and a stream carried both ways, `carry` sent to the
/// device first, until either ends; both closed then.
async fn p54_device_tunnel(w0 : P54DevWorld, sock_id : Json, carry : Bytes, stream : @terminals_logins.Stream) -> Unit {
  let host = w0.bus.host
  let sock = w0.sock_of(Some(sock_id))
  // (either side reset or gone fails a read or a write: the tunnel's end as much as an end is, never the runtime's
  // defect, and both are let go after it all the same)
  let carried = try {
    if carry.length() > 0 {
      (sock.conn.write)(carry)
    }
    true
  } catch {
    _ => false
  }
  let down = host.rt.fork(name="device down", async fn() {
    try {
      for c in sock.chunks {
        match c {
          Some(b) => (stream.write)(b) catch { _ => () }
          None => ()
        }
      }
      sock.chunks.clear()
      while (sock.conn.read)() is Some(b) {
        (stream.write)(b) catch {
          _ => break
        }
      }
    } catch {
      _ => ()
    }
    (stream.finish)() catch {
      _ => ()
    }
  })
  if carried {
    try {
      while (stream.read)() is Some(b) {
        (sock.conn.write)(b) catch {
          _ => break
        }
      }
    } catch {
      _ => ()
    }
  }
  (sock.conn.end)()
  ignore(down.wait())
  sock.destroyed = true
  (sock.conn.close)()
  ignore(sock.closed.succeed(()))
}

///|
/// Where a link points (the shell's `fs.readlink`), None where it is no link or cannot be read.
fn p54_readlink(host : @host.Host, p : String) -> String? {
  match (try { Ok(host.shell_sync("fs.readlink", { "path": Json::string(p) })) } catch { e => Err(e) }) {
    Ok(String(t)) => Some(t)
    _ => None
  }
}
