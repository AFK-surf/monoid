// These parts' IO on the station's program: the clock on the program's runtime (the wall's time as the station told it,
// carried on the steady clock), the files through the shell (client/shell's `fs.*`), Chrome's DevTools over the
// shell's WebSocket (`ws.*`), a Farview tab's ports over its TCP (`tcp.*`), the HTTP of `/json/version` by `fetch`.
// What only Node does of the machine (a program started to outlive the station, its group's signals, the browsers the
// platform finds) the station gives as it starts these parts (`MachineProcs`).

///|
fn shell_str(v : Json?) -> String? {
  match v {
    Some(String(s)) => Some(s)
    _ => None
  }
}

///|
fn shell_field(v : Json, k : String) -> Json? {
  match v {
    Object(m) => m.get(k)
    _ => None
  }
}

///|
/// The clock on `host`'s runtime: `wall` the wall's time (ms) as the station told it as the program started.
pub fn host_clock(host : @host.Host, wall : Double) -> Clock {
  let steady = @host.now()
  {
    now: () => wall + (@host.now() - steady).to_double(),
    after: (ms, f) => {
      let fiber = host.rt.fork(async fn() {
        @effect.sleep(if ms > 0.0 { ms.to_int() } else { 0 })
        f() catch {
          _ => ()
        }
      })
      () => fiber.interrupt()
    },
    spawn: f => ignore(
      host.rt.fork_daemon("browser", on_error=_ => (), async fn() {
        f() catch {
          _ => ()
        }
      }),
    ),
    sleep: async fn(ms) { @effect.sleep(if ms > 0.0 { ms.to_int() } else { 0 }) },
  }
}

///|
/// The station's log, on the program's stderr (the station's log takes its lines).
pub fn host_log() -> Log {
  {
    info: (part, what, f) => @host.note("[\{part}] \{what} \{stringify(f)}"),
    warn: (part, what, f) => @host.note("[\{part}] warn: \{what} \{stringify(f)}"),
  }
}

///|
/// A shell's failure as node:fs would say it: its code where its words say one (`ENOENT`…), as Rust's std::fs says
/// them on Unix and on Windows (a directory not there is os error 3 there, a file 2; denied 5; there already 80 or 183).
fn fs_error(e : Error) -> FsError {
  let words = message_of(e)
  let says = (xs : Array[String]) => xs.iter().any(x => words.contains(x))
  let code = if says(["os error 2)", "os error 3)", "No such file", "cannot find the "]) {
    "ENOENT"
  } else if says(["os error 17)", "os error 80)", "os error 183)", "exists"]) {
    "EEXIST"
  } else if says(["os error 13)", "os error 5)", "denied"]) {
    "EACCES"
  } else {
    "EIO"
  }
  FsError(code, words)
}

///|
/// The machine's files, through the shell: each asked of it without waiting (`shell`, done on its own threads, never
/// this program's loop), `fs.write` written beside and renamed into place, then made the station's alone.
pub fn host_files(host : @host.Host) -> Files {
  let ask = async fn(op : String, args : Json) -> Json {
    let (v, _) = host.shell(op, args) catch {
      e => raise fs_error(e)
    }
    v
  }
  let meta = async fn(path : String) -> Json? {
    try Some(ask("fs.meta", { "path": Json::string(path) })) catch {
      _ => None
    }
  }
  let there = async fn(path : String) -> Bool { meta(path) is Some(Object(_)) }
  // (written whole beside it and renamed in, made `mode` after)
  let put = async fn(path : String, text_ : String, mode : Int) {
    ignore(ask("fs.write", { "path": Json::string(path), "text": Json::string(text_) }))
    ignore(ask("fs.chmod", { "path": Json::string(path), "mode": Json::number(mode.to_double()) }))
  }
  // (a file whose directory is not there is not made, as node:fs's open says ENOENT)
  let put_in = async fn(path : String, text_ : String, mode : Int) {
    if !there(pdirname(path)) {
      raise FsError("ENOENT", "ENOENT: no such file or directory, open '\{path}'")
    }
    put(path, text_, mode)
  }
  {
    read: async fn(path) {
      shell_str(Some(ask("fs.read", { "path": Json::string(path) }))) catch {
        _ => None
      }
    },
    write_private: async fn(path, text_) { put(path, text_, 0o600) },
    write: async fn(path, text_, mode) { put_in(path, text_, mode) },
    create: async fn(path, text_) { put_in(path, text_, 0o600) },
    rename: async fn(from, to) { ignore(ask("fs.rename", { "from": Json::string(from), "to": Json::string(to) })) },
    unlink: async fn(path) {
      if !there(path) {
        raise FsError("ENOENT", "ENOENT: no such file or directory, unlink '\{path}'")
      }
      ignore(ask("fs.remove", { "path": Json::string(path) }))
    },
    mkdir: async fn(path, _mode) { ignore(ask("fs.mkdir", { "path": Json::string(path) })) },
    rm: async fn(path, recursive) {
      ignore(ask("fs.remove", { "path": Json::string(path), "recursive": Json::boolean(recursive) }))
    },
    readdir: async fn(path) {
      match ask("fs.readdir", { "path": Json::string(path) }) {
        Array(xs) => xs.filter_map(x => shell_str(Some(x)))
        _ => raise FsError("ENOENT", "ENOENT: no such file or directory, scandir '\{path}'")
      }
    },
    exists: async fn(path) { there(path) },
    mtime: async fn(path) {
      match meta(path) {
        Some(Object(m)) =>
          match m.get("mtime") {
            Some(Number(n, ..)) => n
            _ => 0.0
          }
        _ => raise FsError("ENOENT", "ENOENT: no such file or directory, stat '\{path}'")
      }
    },
  }
}

///|
/// Chrome's DevTools over the shell's WebSocket, for `connect_cdp`.
pub fn host_cdp_open(host : @host.Host) -> async (String, CdpLink) -> CdpSocket {
  async fn(url, link) {
    let (answer, _) = host.shell("ws.open", { "url": Json::string(url), "headers": Json::array([]) })
    let id = match shell_field(answer, "id") {
      Some(Number(n, ..)) => n
      _ => raise fail_("the browser's DevTools did not answer at \{url}")
    }
    let fiber = host.rt.fork(async fn() {
      while true {
        let (frame, _) = host.shell("ws.next", { "id": Json::number(id) }) catch {
          _ => {
            link.ended()
            return
          }
        }
        match shell_str(shell_field(frame, "text")) {
          Some(t) => link.heard(t)
          None => {
            link.ended()
            return
          }
        }
      }
    })
    {
      send: t => ignore(
        host.rt.fork_quiet(name="browser ws send", async fn() {
          ignore(host.shell("ws.send", { "id": Json::number(id), "text": Json::string(t) })) catch {
            _ => ()
          }
        }),
      ),
      close: () => {
        fiber.interrupt()
        ignore(
          host.rt.fork_quiet(name="browser ws close", async fn() {
            ignore(host.shell("ws.close", { "id": Json::number(id) })) catch {
              _ => ()
            }
          }),
        )
      },
    }
  }
}

///|
/// A port of 127.0.0.1 over the shell's TCP.
pub fn host_net(host : @host.Host, clock : Clock) -> FarviewNet {
  {
    connect: async fn(port) {
      let socket = host.tcp_open(port).socket
      {
        write: async fn(b) { socket.write(b) },
        read: async fn() { socket.read() },
        close: () => ignore(host.rt.fork_quiet(async fn() { socket.destroy() })),
      }
    },
    clock,
  }
}

///|
/// What only the station's Node does of the machine, given as these parts start: a program started to outlive the
/// station (its pid and how it ended), a group's start time, whether it is alive, ended or signalled, the browsers the
/// platform finds, whether it shows windows.
pub(all) struct MachineProcs {
  start_lasting : (String, Array[String], String, Array[(String, String)]) -> Child
  start_time_of : async (Int) -> Double?
  group_alive : (Int) -> Bool
  end_group : async (Int, Double) -> Unit
  signal_group : (Int, String) -> Unit
  browsers : () -> Array[String]
  browsers_soon : async () -> Array[String]
  has_display : () -> Bool
}

///|
/// The machine as the Chrome and Farview hosts ask it: the shell's for its network, `procs` for its processes.
pub fn host_machine(host : @host.Host, clock : Clock, procs : MachineProcs) -> Machine {
  let net = host_net(host, clock)
  {
    now: clock.now,
    sleep: clock.sleep,
    browsers: procs.browsers,
    browsers_soon: procs.browsers_soon,
    has_display: procs.has_display,
    start_lasting: procs.start_lasting,
    start_time_of: procs.start_time_of,
    group_alive: procs.group_alive,
    end_group: procs.end_group,
    signal_group: procs.signal_group,
    free: async fn(port) {
      match (try Some(host.tcp_listen_local(port)) catch { _ => None }) {
        Some(l) => {
          host.listen_close(l.id)
          true
        }
        None => false
      }
    },
    version: async fn(port) {
      let got = @effect.timeout(3000, async fn() {
        host.shell("fetch", {
          "url": Json::string("http://127.0.0.1:\{port}/json/version"),
          "method": "GET",
          "headers": Json::array([]),
        })
      }) catch {
        _ => None
      }
      match got {
        Some((answer, Some(body))) => {
          let status = match shell_field(answer, "status") {
            Some(Number(n, ..)) => n
            _ => 0.0
          }
          if status < 200.0 || status > 299.0 {
            return None
          }
          let v = parse(from_utf8(body)) catch { _ => return None }
          match at(Some(v), "webSocketDebuggerUrl") {
            Some(Str(u)) => {
              let agent = match at(Some(v), "User-Agent") {
                None | Some(Null) => ""
                a => js_str(a)
              }
              Some((@jsjson.text(u), agent))
            }
            _ => None
          }
        }
        _ => None
      }
    },
    answers: async fn(port) {
      match (try Some((net.connect)(port)) catch { _ => None }) {
        Some(link) => {
          (link.close)()
          true
        }
        None => false
      }
    },
    connect: async fn(url) { connect_cdp(url, host_cdp_open(host), clock) },
  }
}

///|
/// What unpacking Farview's release asks of the machine, on the shell: a tarball's bytes written (`fs.put`), `tar` run
/// (`proc.run`), random bytes from the system's source.
pub fn host_release_io(host : @host.Host) -> ReleaseIo {
  {
    write_bytes: async fn(path, b) {
      ignore(host.shell("fs.put", { "path": Json::string(path), "truncate": true }, bytes=b)) catch {
        e => raise fs_error(e)
      }
    },
    untar: async fn(tgz, out) {
      let args = ["-xzf", tgz, "-C", out]
      let (ran, _) = host.shell("proc.run", {
        "command": "tar",
        "args": Json::array(args.map(Json::string)),
        "timeoutMs": 120_000,
      }) catch {
        e => raise fail_(message_of(e))
      }
      match ran {
        Null => raise fail_("Command failed: tar \{args.join(" ")}")
        _ => ()
      }
    },
    random_hex: n => match
      (try Some(host.shell_sync("crypto.random", { "bytes": Json::number(n.to_double()) })) catch { _ => None }) {
      Some(String(s)) => s
      _ => "0".repeat(n * 2)
    },
  }
}
