// adb/servers.ts: an adb server of each grant's own (2026-10-29). A phone granted to a chat is connected in that
// grant's server alone, its port given to that chat's agent (phone_use), and the phone's listener takes connections
// from those servers' processes alone (`owner`). An agent of another chat, though it knows the ports, reaches neither:
// the phone is not in the station's own server (5037), a connection of its to the phone's port is turned away, and the
// server's own port is a door that lets the grant's session through alone (door; none on Windows, where the machine's
// processes are not read: there the server serves on the port as it is).

///|
/// A grant's server up: its port and its process.
pub struct Server {
  port : Int
  child : J
}

///|
/// A server started here, as written down: its process, and when that started (another process given its pid later
/// is not it).
struct KeptServer {
  pid : Int
  port : Int
  mut started : J
  dir : String?
}

///|
fn KeptServer::to_j(self : KeptServer) -> J {
  let fields = [
    ("pid", ji(self.pid)),
    ("port", ji(self.port)),
    ("started", self.started),
  ]
  match self.dir {
    Some(d) => fields.push(("dir", js(d)))
    None => ()
  }
  jo(fields)
}

///|
pub struct GrantServers {
  w : World
  servers : Map[String, @effect.Deferred[Server?]]
  /// Where the servers started are written down (None: nowhere, as in tests), for the next station process to stop
  /// what this one left.
  record : String?
  kept : Map[Int, KeptServer]
  mut writing : @effect.Deferred[Unit]
  /// Who may use a server (door); None: its port is the server's own.
  admit : Admit?
}

///|
pub async fn GrantServers::new(
  w : World,
  record? : String,
  admit? : Admit,
) -> GrantServers {
  // Where adb is, found before the station serves.
  ignore(w.ask("adb.path", []))
  let done : @effect.Deferred[Unit] = @effect.Deferred::new()
  ignore(done.succeed(()))
  { w, servers: {}, record, kept: {}, writing: done, admit, }
}

///|
/// Stops the servers a station process before left running (once it is gone: `previous_gone`), as written down.
pub async fn GrantServers::reap(
  self : GrantServers,
  previous_gone? : async () -> Unit,
) -> Int {
  guard self.record is Some(record) else { return 0 }
  match previous_gone {
    Some(f) => f()
    None => ()
  }
  let w = self.w
  let left = @session_chats.parse_js(js_text(w.ask("fs.read", [js(record)]))) catch {
    _ => ja([])
  }
  let mut stopped = 0
  for k in list_of(Some(left)) {
    let pid = match at(Some(k), "pid") {
      Some(Num(p)) if is_int(p) && p.abs() <= 9007199254740991.0 => p.to_int()
      _ => continue
    }
    if self.kept.contains(pid) {
      continue
    }
    match at(Some(k), "dir") {
      Some(Str(_) as d) => ignore(w.ask("fs.rm", [d]))
      _ => ()
    }
    let started = w.ask("platform.startTimeOf", [ji(pid)])
    // Not that process any more (gone, or its pid another's).
    let was = at(Some(k), "started")
    match started {
      Null => continue
      Num(s) =>
        match was {
          Some(Num(k)) if (s - k).abs() > 2000.0 => continue
          _ => ()
        }
      _ => ()
    }
    try {
      ignore(w.ask("proc.signal", [ji(pid), js("SIGTERM")]))
      stopped += 1
    } catch {
      _ => ()
    }
  }
  if stopped > 0 {
    w.log(
      "info",
      "adb",
      "the grants' adb servers a station before left stopped",
      jo([("n", ji(stopped))]),
    )
  }
  self.write()
  stopped
}

///|
/// How many records' names beside them this process gave (`GrantServers::write_soon`).
let record_seq : Ref[Int64] = { val: 0L }

///|
/// One write at a time, each of what is kept as it begins.
fn GrantServers::write_soon(self : GrantServers) -> @effect.Deferred[Unit] {
  guard self.record is Some(record) else {
    let d = @effect.Deferred::new()
    ignore(d.succeed(()))
    return d
  }
  let before = self.writing
  let done : @effect.Deferred[Unit] = @effect.Deferred::new()
  self.writing = done
  let w = self.w
  (w.spawn)(async fn() {
    before.wait() catch {
      _ => ()
    }
    try {
      let pid = w.ask("process.pid", [])
      // (a name of its own, let go of where the write fails: never one another write of this process takes, L13)
      record_seq.val += 1L
      let temp = "\{record}.\{js_text(pid)}.\{record_seq.val}.tmp"
      errdefer @effect.uninterruptible(async fn() {
        ignore(w.ask("fs.rm", [js(temp)])) catch {
          _ => ()
        }
      })
      ignore(
        w.ask("fs.write", [
          js(temp),
          js(stringify(ja(self.kept.values().map(k => k.to_j()).collect()))),
        ]),
      )
      ignore(w.ask("fs.rename", [js(temp), js(record)]))
    } catch {
      e =>
        w.log(
          "warn",
          "adb",
          "the grants' adb servers were not written down",
          jo([("error", js(message_of(e)))]),
        )
    }
    ignore(done.succeed(()))
  })
  done
}

///|
async fn GrantServers::write(self : GrantServers) -> Unit {
  self.write_soon().wait()
}

///|
/// Grant `id`'s server, started if it is not running (`adb -P <port> server nodaemon`: its own process, held here).
pub async fn GrantServers::ensure(self : GrantServers, id : String) -> Server? {
  let s = match self.servers.get(id) {
    Some(s) => s
    None => {
      let s : @effect.Deferred[Server?] = @effect.Deferred::new()
      self.servers[id] = s
      (self.w.spawn)(async fn() {
        let got = self.start(id) catch { _ => None }
        ignore(s.succeed(got))
      })
      s
    }
  }
  s.wait()
}

///|
async fn GrantServers::start(self : GrantServers, id : String) -> Server? {
  let w = self.w
  let adb = match w.ask("adb.path", []) {
    Str(_) as a => js_text(a)
    _ => return None
  }
  for _ in 0..<3 {
    // Behind its door, on a socket of a directory of its own, named in its environment and not on its command line;
    // else on the port itself.
    let dir = match self.admit {
      None => None
      Some(_) => Some(js_text(w.ask("fs.mkdtemp", [js("sf-adb-")])))
    }
    let path = dir.map(d => d + "/s")
    let door = match (path, self.admit) {
      (Some(p), Some(admit)) =>
        Some(
          open_door(
            w,
            id,
            p,
            async fn(port) {
              list_of(Some(w.ask("platform.tcpPortPids", [ji(port)]))).map(x => {
                num_of(Some(x)).unwrap_or(0.0).to_int()
              })
            },
            admit,
          ),
        )
      _ => None
    }
    let port = match door {
      Some(d) => d.port
      None => num_of(Some(w.ask("net.freePort", []))).unwrap_or(0.0).to_int()
    }
    let args = match path {
      None => ["-P", port.to_string(), "server", "nodaemon"]
      Some(_) => ["server", "nodaemon"]
    }
    let env = match path {
      None => J::Null
      Some(p) => jo([("ADB_SERVER_SOCKET", js("localfilesystem:\{p}"))])
    }
    let child = w.ask("proc.start", [
      jo([("file", js(adb)), ("args", jsa(args)), ("env", env)]),
    ])
    let closed = () => {
      match door {
        Some(d) => (d.close)()
        None => ()
      }
      match dir {
        Some(d) =>
          (w.spawn)(async fn() {
            ignore(w.ask("fs.rm", [js(d)])) catch {
              _ => ()
            }
          })
        None => ()
      }
    }
    let up : @effect.Deferred[Bool] = @effect.Deferred::new()
    (w.spawn)(async fn() {
      ignore(w.ask("proc.closed", [child])) catch {
        _ => ()
      }
      ignore(up.succeed(false))
    })
    // Up once it takes a connection on its socket or port.
    let target = match path {
      None => jo([("host", js("127.0.0.1")), ("port", ji(port))])
      Some(p) => jo([("path", js(p))])
    }
    (w.spawn)(async fn() {
      for tries in 1..<=50 {
        let c = w.ask("net.connect", [target]) catch { _ => Null }
        if !(c is Null) {
          ignore(w.ask("net.destroy", [c])) catch {
            _ => ()
          }
          ignore(up.succeed(true))
          return
        }
        if tries < 50 {
          w.sleep(100.0)
        }
      }
      ignore(up.succeed(false))
    })
    if up.wait() {
      let pid = match w.ask("proc.pid", [child]) {
        Num(p) => Some(p.to_int())
        _ => None
      }
      match pid {
        Some(pid) => {
          self.kept[pid] = { pid, port, started: Null, dir, }
          ignore(self.write_soon())
          // When it started, for a station after this one to know it is still this process: asked, not waited on.
          (w.spawn)(async fn() {
            let started = w.ask("platform.startTimeOf", [ji(pid)]) catch {
              _ => Null
            }
            match (self.kept.get(pid), started) {
              (Some(k), Num(_)) => {
                k.started = started
                ignore(self.write_soon())
              }
              _ => ()
            }
          })
        }
        None => ()
      }
      (w.spawn)(async fn() {
        ignore(w.ask("proc.closed", [child])) catch {
          _ => ()
        }
        closed()
        match pid {
          Some(p) if self.kept.contains(p) => {
            self.kept.remove(p)
            ignore(self.write_soon())
          }
          _ => ()
        }
        // Gone (killed, crashed): started anew when next wanted.
        self.servers.remove(id)
      })
      w.log(
        "info",
        "adb",
        "a grant's adb server started",
        jo([
          ("grant", js(id)),
          ("port", ji(port)),
          (
            "pid",
            match pid {
              Some(p) => ji(p)
              None => Null
            },
          ),
        ]),
      )
      return Some({ port, child, })
    }
    ignore(w.ask("proc.kill", [child, js("SIGKILL")])) catch {
      _ => ()
    }
    closed()
  }
  w.log(
    "warn",
    "adb",
    "a grant's adb server did not start",
    jo([("grant", js(id))]),
  )
  self.servers.remove(id)
  None
}

///|
/// Grant `id`'s server stopped (the grant ended).
pub async fn GrantServers::stop(self : GrantServers, id : String) -> Unit {
  let s = match self.servers.get(id) {
    Some(d) => d.wait()
    None => None
  }
  self.servers.remove(id)
  match s {
    Some(s) =>
      ignore(self.w.ask("proc.kill", [s.child, js("SIGTERM")])) catch {
        _ => ()
      }
    None => ()
  }
}

///|
/// The grants whose servers run (or start).
pub fn GrantServers::ids(self : GrantServers) -> Array[String] {
  self.servers.keys().collect()
}

///|
/// Which grant's server is at the other end of `socket` (a loopback connection to a phone's port), if any.
pub async fn GrantServers::owner(
  self : GrantServers,
  socket : J,
  ids : Array[String],
) -> String? {
  let pids : Map[Int, String] = Map::new()
  for id in ids {
    match self.servers.get(id) {
      Some(d) =>
        match d.wait() {
          Some(s) =>
            match self.w.ask("proc.pid", [s.child]) {
              Num(p) => pids[p.to_int()] = id
              _ => ()
            }
          None => ()
        }
      None => ()
    }
  }
  if pids.length() == 0 {
    return None
  }
  let remote = self.w.ask("net.remotePort", [socket])
  guard remote is Num(port) else { return None }
  for p in list_of(Some(self.w.ask("platform.tcpPortPids", [jn(port)]))) {
    match pids.get(num_of(Some(p)).unwrap_or(-1.0).to_int()) {
      Some(id) => return Some(id)
      None => ()
    }
  }
  None
}

///|
/// Done once what was asked written of the record so far is written: a test's wait.
pub async fn GrantServers::written(self : GrantServers) -> Unit {
  self.writing.wait()
}

///|
pub async fn GrantServers::close(self : GrantServers) -> Unit {
  for id in self.ids() {
    self.stop(id)
  }
}
