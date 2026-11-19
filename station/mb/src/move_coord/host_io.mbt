// These parts' IO on the station's program: its files through the shell (client/shell's `fs.*`), its clock and fibers
// on the program's runtime, its random bytes from the system's source. What a test gives instead is the harness's.

///|
fn shell_text(v : @json.Json) -> String? {
  match v {
    String(s) => Some(s)
    _ => None
  }
}

///|
/// The machine's files, as the shell writes them (`fs.write` beside and renamed into place, `fs.put` appended).
pub fn host_disk(host : @host.Host) -> Disk {
  {
    read: path => shell_text(host.shell_sync("fs.read", { "path": @json.Json::string(path) })) catch {
      _ => None
    },
    write: async fn(path, text) {
      ignore(
        host.shell_sync("fs.write", {
          "path": @json.Json::string(path),
          "text": @json.Json::string(text),
        }),
      ) catch {
        e => raise Failed(e.to_string())
      }
    },
    append: async fn(path, text) {
      ignore(
        host.shell_sync("fs.mkdir", { "path": @json.Json::string(@nodepath.dirname("/", path)) }),
      ) catch {
        e => raise Failed(e.to_string())
      }
      ignore(host.shell("fs.put", { "path": @json.Json::string(path) }, bytes=@utf8.encode(text)))
    },
    remove: async fn(path) {
      ignore(host.shell_sync("fs.remove", { "path": @json.Json::string(path) })) catch {
        e => raise Failed(e.to_string())
      }
    },
    spawn: f => ignore(
      host.rt.fork_daemon("move_coord", f, on_error=e => @host.note("move_coord: background work failed: \{e}")),
    ),
  }
}

///|
/// The machine's files as repos.ts asks them (node:fs/promises).
pub fn host_fs(host : @host.Host) -> Fs {
  let meta = fn(path : String) -> @json.Json? {
    match (try Ok(host.shell_sync("fs.meta", { "path": @json.Json::string(path) })) catch { e => Err(e) }) {
      Ok(Object(_) as m) => Some(m)
      _ => None
    }
  }
  {
    read_text: async fn(path) {
      shell_text(host.shell_sync("fs.read", { "path": @json.Json::string(path) })) catch {
        _ => None
      }
    },
    readdir: async fn(path) {
      match (try Ok(host.shell_sync("fs.readdir", { "path": @json.Json::string(path) })) catch { e => Err(e) }) {
        Ok(Array(xs)) => Some(xs.filter_map(shell_text))
        _ => None
      }
    },
    mtime: async fn(path) {
      match meta(path) {
        Some(Object(m)) =>
          match m.get("mtime") {
            Some(Number(n, ..)) => Some(n)
            _ => Some(0.0)
          }
        _ => None
      }
    },
    size: async fn(path) {
      match meta(path) {
        Some(Object(m)) =>
          match m.get("size") {
            Some(Number(n, ..)) => Some(n)
            _ => Some(0.0)
          }
        _ => None
      }
    },
    realpath: async fn(path) {
      shell_text(host.shell_sync("fs.realpath", { "path": @json.Json::string(path) })) catch {
        _ => None
      }
    },
    mkdir: async fn(path) {
      ignore(host.shell_sync("fs.mkdir", { "path": @json.Json::string(path) })) catch {
        e => raise Failed(e.to_string())
      }
    },
    rename: async fn(from, to) {
      ignore(
        host.shell_sync("fs.rename", {
          "from": @json.Json::string(from),
          "to": @json.Json::string(to),
        }),
      ) catch {
        e => raise Failed(e.to_string())
      }
    },
    remove: async fn(path, recursive) {
      ignore(
        host.shell_sync("fs.remove", {
          "path": @json.Json::string(path),
          "recursive": @json.Json::boolean(recursive),
        }),
      ) catch {
        e => raise Failed(e.to_string())
      }
    },
    write_from: async fn(path, next) {
      let mut first = true
      while true {
        let piece = match next() {
          Some(p) => p
          None => break
        }
        let args : Map[String, @json.Json] = { "path": @json.Json::string(path) }
        if first {
          args["offset"] = @json.Json::number(0.0)
          args["truncate"] = @json.Json::boolean(true)
          first = false
        }
        ignore(host.shell("fs.put", @json.Json::object(args), bytes=piece))
      }
      if first {
        ignore(host.shell("fs.put", { "path": @json.Json::string(path), "offset": 0, "truncate": true }, bytes=b""))
      }
    },
  }
}

///|
/// The program's clock and fibers: its runtime's timers, on the machine's clock.
pub fn host_clock(host : @host.Host) -> Clock {
  let rt = host.rt
  {
    now: () => @host.epoch_ms(),
    after: (ms, f) => {
      let fiber = rt.fork(async fn() {
        @effect.sleep(ms)
        f()
      })
      () => fiber.interrupt()
    },
    every: (ms, f) => {
      let fiber = rt.fork(async fn() {
        while true {
          @effect.sleep(ms)
          f() catch {
            _ => ()
          }
        }
      })
      () => fiber.interrupt()
    },
    spawn: f => ignore(
      rt.fork_daemon("move_coord", f, on_error=e => @host.note("move_coord: background work failed: \{e}")),
    ),
  }
}

///|
/// `n` random bytes as hex, from the system's source.
pub fn host_random(host : @host.Host) -> (Int) -> String {
  n => shell_text(host.shell_sync("crypto.random", { "bytes": @json.Json::number(n.to_double()) })).unwrap_or(
    "",
  ) catch {
    _ => ""
  }
}
