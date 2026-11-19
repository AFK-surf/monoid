// These parts' IO on the station's program: the clock on the program's runtime (the wall's time as the station told it,
// carried on the steady clock), the files through the shell (client/shell's `fs.*`), Chrome's DevTools over the
// shell's WebSocket (`ws.*`), a Farview tab's ports over its TCP (`tcp.*`), the HTTP of `/json/version` by `fetch`.
// What only Node does of the machine (a program started to outlive the station, its group's signals, the browsers the
// platform finds) the station gives as it starts these parts (`MachineProcs`).

///|
/// The clock on `host`'s runtime: `wall` the wall's time (ms) as the station told it as the program started.
pub fn host_clock(host : @host.Host, wall : Double) -> Clock {
  let steady = @host.now()
  {
    now: () => wall + (@host.now() - steady).to_double(),
    after: (ms, f) => @host_world.after_async(host, ms.to_int(), f, swallow_error=true),
    spawn: f => @host_world.spawn_daemon(host, "browser", f, silent=true),
    sleep: async fn(ms) { @host_world.sleep_ms(ms.to_int()) },
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
fn fs_error(e : Error) -> FsError {
  let words = @host_world.shell_error_msg(e)
  FsError(@host_world.os_code(words), words)
}

///|
async fn[T] wrap_fs(f : async () -> T) -> T {
  f() catch {
    FsError(_, _) as e => raise e
    e => raise fs_error(e)
  }
}

///|
/// The machine's files, through the shell: each asked of it without waiting (`shell`, done on its own threads, never
/// this program's loop), `fs.write` written beside and renamed into place, then made the station's alone.
pub fn host_files(host : @host.Host) -> Files {
  let meta = async fn(path : String) -> @host_world.MetaInfo? {
    @host_world.fs_meta(host, path) catch {
      _ => None
    }
  }
  let there = async fn(path : String) -> Bool { meta(path) is Some(_) }
  let put = async fn(path : String, text_ : String, mode : Int) {
    wrap_fs(async fn() {
      @host_world.fs_write(host, path, text_)
      ignore(@host_world.shell_call(host, false, "fs.chmod", { "path": Json::string(path), "mode": Json::number(mode.to_double()) }))
    })
  }
  // (a file whose directory is not there is not made, as node:fs's open says ENOENT)
  let put_in = async fn(path : String, text_ : String, mode : Int) {
    if !there(pdirname(path)) {
      raise FsError("ENOENT", @host_world.enoent_msg("open", path))
    }
    put(path, text_, mode)
  }
  {
    read: async fn(path) { @host_world.fs_read_text(host, path) catch { _ => None } },
    write_private: async fn(path, text_) { put(path, text_, 0o600) },
    write: async fn(path, text_, mode) { put_in(path, text_, mode) },
    create: async fn(path, text_) { put_in(path, text_, 0o600) },
    rename: async fn(from, to) { wrap_fs(async fn() { @host_world.fs_rename(host, from, to) }) },
    unlink: async fn(path) {
      if !there(path) {
        raise FsError("ENOENT", @host_world.enoent_msg("unlink", path))
      }
      wrap_fs(async fn() { @host_world.fs_remove(host, path) })
    },
    mkdir: async fn(path, _mode) { wrap_fs(async fn() { @host_world.fs_mkdir(host, path) }) },
    rm: async fn(path, recursive) { wrap_fs(async fn() { @host_world.fs_remove(host, path, recursive~) }) },
    readdir: async fn(path) {
      wrap_fs(async fn() {
        match @host_world.fs_readdir(host, path) {
          Some(xs) => xs
          None => raise FsError("ENOENT", @host_world.enoent_msg("scandir", path))
        }
      })
    },
    exists: async fn(path) { there(path) },
    mtime: async fn(path) {
      match meta(path) {
        Some(m) => m.mtime_ms
        None => raise FsError("ENOENT", @host_world.enoent_msg("stat", path))
      }
    },
  }
}

///|
/// Chrome's DevTools over the shell's WebSocket, for `connect_cdp`.
pub fn host_cdp_open(host : @host.Host) -> async (String, CdpLink) -> CdpSocket {
  async fn(url, link) {
    let conn = @host_world.ws_open(
      host,
      url,
      "browser",
      on_message=t => link.heard(t),
      on_close=_ => link.ended(),
    ) catch {
      e => raise fail_("the browser's DevTools did not answer at \{url}: \{@host_world.shell_error_msg(e)}")
    }
    { send: conn.send, close: conn.close }
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
      let got = host.fetch("http://127.0.0.1:\{port}/json/version", timeout_ms=3000) catch { _ => return None }
      if got.status < 200 || got.status > 299 {
        return None
      }
      let v = parse(from_utf8(got.body)) catch { _ => return None }
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
      wrap_fs(async fn() { @host_world.fs_put(host, path, b, truncate=true) })
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
    random_hex: n => {
      let s = @host_world.random_hex(host, n)
      if s.length() > 0 { s } else { "0".repeat(n * 2) }
    },
  }
}
