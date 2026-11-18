// These parts' ports on a station's program (`@host.Host`, the shell's IO on the program's runtime): the clock and
// its timers on the runtime, connections by the shell's `unix.open` and `tcp.open` (read by `tcp.read`, written by
// `tcp.write`, let go by `tcp.close`), the files by its `fs.*`, random bytes by `crypto.random`, the log on the
// program's stderr. What the shell does not do (a child process followed while it runs, a folder watched, the
// platform's facts and the station's words) its caller gives: the station's Node, which runs the processes and knows
// the machine, or what stands for it.

///|
fn shell_j(host : @host.Host, op : String, fields : Map[String, Json]) -> Json raise {
  host.shell_sync(op, Json::object(fields))
}

///|
/// An operation of the shell's on its own threads (a file's bytes, a folder walked): nothing waits for it here. Its
/// failure an FsFailed with the OS's code as Node names it.
async fn shell_j_async(host : @host.Host, op : String, fields : Map[String, Json]) -> Json {
  let (v, _) = host.shell(op, Json::object(fields)) catch {
    @wire.ShellError(m) => raise FsFailed(m, os_code(m))
    e => raise FsFailed(message_of(e), "EIO")
  }
  v
}

///|
fn shell_text_of(v : Json) -> String? {
  match v {
    String(s) => Some(s)
    _ => None
  }
}

///|
fn hex_bytes(hex : String) -> Bytes {
  let n = hex.length() / 2
  let v = (c : Int) => if c >= '0'.to_int() && c <= '9'.to_int() {
    c - '0'.to_int()
  } else if c >= 'a'.to_int() && c <= 'f'.to_int() {
    c - 'a'.to_int() + 10
  } else {
    0
  }
  Bytes::from_array(FixedArray::makei(n, i => (v(hex.unsafe_get(2 * i).to_int()) * 16 + v(hex.unsafe_get(2 * i + 1).to_int())).to_byte()))
}

///|
/// An OS error's code as Node names it, from what Rust's io::Error says (`… (os error 17)`).
fn os_code(message : String) -> String {
  let codes : Array[(String, String)] = [
    ("(os error 2)", "ENOENT"),
    ("(os error 17)", "EEXIST"),
    ("(os error 13)", "EACCES"),
    ("(os error 21)", "EISDIR"),
    ("(os error 20)", "ENOTDIR"),
    ("(os error 39)", "ENOTEMPTY"),
    ("(os error 66)", "ENOTEMPTY"),
    ("(os error 1)", "EPERM"),
    // Windows'
    ("(os error 3)", "ENOENT"),
    ("(os error 5)", "EACCES"),
    ("(os error 80)", "EEXIST"),
    ("(os error 183)", "EEXIST"),
    ("(os error 145)", "ENOTEMPTY"),
  ]
  for c in codes {
    if message.contains(c.0) {
      return c.1
    }
  }
  "EIO"
}

///|
fn enoent(op : String, path : String) -> FsFailed {
  FsFailed("ENOENT: no such file or directory, \{op} '\{path}'", "ENOENT")
}

///|
/// The ports on `host`: `procs` (how a child is started and run), `os` (what the machine is) and `words` (the
/// station's) given by the caller; the wall's time as the station tells it (`now`).
pub fn host_io(host : @host.Host, procs : Procs, os : Os, words : Words, now? : (() -> Double)? = None) -> Io {
  let wall = now.unwrap_or(() => @host.now().to_double())
  let clock : Clock = {
    now: wall,
    after: (ms, f) => {
      let live = Ref(true)
      host.rt.after(js_max(0.0, ms).to_int(), () => if live.val {
        live.val = false
        f()
      })
      () => live.val = false
    },
    micros: () => @host.now().to_double() * 1000.0,
  }
  let net : Net = {
    connect: (target, events) => {
      let id : Ref[Double?] = Ref(None)
      // Destroyed (by its owner) apart from closed (told): a destroy tells its close on a later turn, as Node's
      // socket.destroy() does, so what its owner does right after (an answer taken) comes before the close.
      let destroyed = Ref(false)
      let closed = Ref(false)
      let paused = Ref(false)
      let waiting : Ref[@effect.Deferred[Unit]?] = Ref(None)
      let close_once = () => if !closed.val {
        closed.val = true
        (events.close)()
      }
      ignore(
        host.rt.fork(async fn() {
          let (opened, _) = (match target {
            Unix(path) => host.shell("unix.open", Json::object({ "path": Json::string(path) }))
            Tcp(port) => host.shell("tcp.open", Json::object({ "port": Json::number(port.to_double()) }))
          }) catch {
            e => {
              (events.error)(match e {
                @wire.ShellError(m) => m
                e => message_of(e)
              })
              close_once()
              return
            }
          }
          guard opened is Object(m) && m.get("id") is Some(Number(n, ..)) else {
            close_once()
            return
          }
          id.val = Some(n)
          if destroyed.val {
            ignore(host.shell("tcp.close", Json::object({ "id": Json::number(n) }))) catch { _ => () }
            return
          }
          (events.connect)()
          while !destroyed.val {
            if paused.val {
              let d : @effect.Deferred[Unit] = @effect.Deferred::new()
              waiting.val = Some(d)
              d.wait()
              continue
            }
            let (said, bytes) = host.shell("tcp.read", Json::object({ "id": Json::number(n) })) catch {
              e => {
                (events.error)(message_of(e))
                break
              }
            }
            match (said, bytes) {
              (Object(m), _) if m.get("end") is Some(True) => break
              (_, Some(b)) => if !destroyed.val { (events.data)(b) }
              _ => break
            }
          }
          close_once()
        }),
      )
      let send = (op : String, bytes : Bytes?) => match id.val {
        Some(n) =>
          ignore(
            host.rt.fork(async fn() {
              ignore(
                (match bytes {
                  Some(b) => host.shell(op, Json::object({ "id": Json::number(n) }), bytes=b)
                  None => host.shell(op, Json::object({ "id": Json::number(n) }))
                }) catch {
                  _ => (Json::null(), None)
                },
              )
            }),
          )
        None => ()
      }
      {
        write: b => send("tcp.write", Some(b)),
        end: () => send("tcp.end", None),
        destroy: () => if !destroyed.val {
          destroyed.val = true
          send("tcp.close", None)
          ignore(host.rt.fork(() => close_once()))
        },
        destroyed: () => destroyed.val,
        pause: () => paused.val = true,
        flow_again: () => {
          paused.val = false
          match waiting.val {
            Some(d) => {
              waiting.val = None
              ignore(d.succeed(()))
            }
            None => ()
          }
        },
      }
    },
  }
  let stat_of_shell = async fn(path : String, follow : Bool) -> Stat {
    let lst = shell_j_async(host, "fs.lstat", { "path": Json::string(path) }) catch { _ => Json::null() }
    guard lst is Object(l) else { raise enoent(if follow { "stat" } else { "lstat" }, path) }
    let link = l.get("kind") is Some(String("link"))
    if follow && link {
      let meta = shell_j_async(host, "fs.meta", { "path": Json::string(path) }) catch { _ => Json::null() }
      guard meta is Object(m) else { raise enoent("stat", path) }
      let kind = shell_j_async(host, "fs.stat", { "path": Json::string(path) }) catch { _ => Json::null() }
      return {
        dir: kind is String("dir"),
        file: kind is String("file"),
        link: false,
        size: match m.get("size") {
          Some(Number(n, ..)) => n
          _ => 0.0
        },
        mtime_ms: match m.get("mtime") {
          Some(Number(n, ..)) => n
          _ => 0.0
        },
      }
    }
    {
      dir: l.get("kind") is Some(String("dir")),
      file: l.get("kind") is Some(String("file")),
      link,
      size: match l.get("size") {
        Some(Number(n, ..)) => n
        _ => 0.0
      },
      mtime_ms: match l.get("mtimeMs") {
        Some(Number(n, ..)) => n
        _ => 0.0
      },
    }
  }
  let put = async fn(path : String, data : Bytes, fields : Map[String, Json]) {
    fields["path"] = Json::string(path)
    ignore(host.shell("fs.put", Json::object(fields), bytes=data)) catch {
      e => {
        let m = match e {
          @wire.ShellError(m) => m
          e => message_of(e)
        }
        raise FsFailed(m, os_code(m))
      }
    }
  }
  let random = (n : Int) => {
    let hex = shell_j(host, "crypto.random", { "bytes": Json::number(n.to_double()) }) catch { _ => Json::string("") }
    let b = hex_bytes(shell_text_of(hex).unwrap_or(""))
    if b.length() == n {
      b
    } else {
      Bytes::from_array(FixedArray::make(n, b'\x00'))
    }
  }
  async fn copy_tree(from : String, to : String) -> Unit {
    let kind = shell_j_async(host, "fs.stat", { "path": Json::string(from), "lstat": Json::boolean(true) })
    match kind {
      String("dir") => {
        ignore(shell_j_async(host, "fs.mkdir", { "path": Json::string(to) }))
        match shell_j_async(host, "fs.readdir", { "path": Json::string(from) }) {
          Array(names) =>
            for name in names {
              match name {
                String(n) => copy_tree(pj([from, n]), pj([to, n]))
                _ => ()
              }
            }
          _ => ()
        }
      }
      String("link") => {
        let target = shell_j_async(host, "fs.readlink", { "path": Json::string(from) })
        ignore(shell_j_async(host, "fs.symlink", { "path": Json::string(to), "target": target }))
      }
      String(_) => ignore(shell_j_async(host, "fs.copy", { "from": Json::string(from), "to": Json::string(to) }))
      _ => raise enoent("cp", from)
    }
  }

  let fs : Files = {
    read: async fn(path) {
      match shell_j_async(host, "fs.bytes", { "path": Json::string(path) }) {
        String(hex) => hex_bytes(hex)
        _ => raise enoent("open", path)
      }
    },
    write: async fn(path, data, mode) {
      let fields : Map[String, Json] = { "truncate": Json::boolean(true), "offset": Json::number(0.0) }
      match mode {
        Some(m) => fields["mode"] = Json::number(m.to_double())
        None => ()
      }
      put(path, data, fields)
    },
    access: async fn(path, mode) {
      let st = shell_j_async(host, "fs.lstat", { "path": Json::string(path) }) catch { _ => return false }
      match st {
        Object(m) =>
          if mode == 1 {
            match m.get("mode") {
              Some(Number(bits, ..)) => (bits.to_int() & 0o111) != 0 && m.get("kind") is Some(String("file") | String("link"))
              _ => false
            }
          } else {
            true
          }
        _ => false
      }
    },
    readdir: async fn(path) {
      match shell_j_async(host, "fs.readdir", { "path": Json::string(path), "types": Json::boolean(true) }) {
        Array(xs) =>
          xs.filter_map(x => match x {
            Array([String(name), String(kind)]) => Some({ name, dir: kind == "dir" })
            _ => None
          })
        _ => raise enoent("scandir", path)
      }
    },
    mkdir: async fn(path, recursive, _) {
      if !recursive && (shell_j_async(host, "fs.stat", { "path": Json::string(path) }) catch { _ => Json::null() }) is String(_) {
        raise FsFailed("EEXIST: file already exists, mkdir '\{path}'", "EEXIST")
      }
      ignore(shell_j_async(host, "fs.mkdir", { "path": Json::string(path) }))
    },
    mkdtemp: async fn(prefix) {
      let alphabet = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
      let b = random(6)
      let tail = StringBuilder()
      for x in b {
        tail.write_char(alphabet.unsafe_get(x.to_int() % alphabet.length()).unsafe_to_char())
      }
      let path = prefix + tail.to_string()
      ignore(shell_j_async(host, "fs.mkdir", { "path": Json::string(path) }))
      path
    },
    rename: async fn(from, to) {
      ignore(shell_j_async(host, "fs.rename", { "from": Json::string(from), "to": Json::string(to) })) catch {
        FsFailed(m, code) =>
          raise (if code == "EIO" && (shell_j_async(host, "fs.stat", { "path": Json::string(from), "lstat": Json::boolean(true) }) catch { _ => Json::null() }) is Null {
            FsFailed("ENOENT: no such file or directory, rename '\{from}' -> '\{to}'", "ENOENT")
          } else {
            FsFailed(m, code)
          })
        e => raise e
      }
    },
    rm: async fn(path, recursive, force) {
      if !force && (shell_j_async(host, "fs.stat", { "path": Json::string(path), "lstat": Json::boolean(true) }) catch { _ => Json::null() }) is Null {
        raise enoent("rm", path)
      }
      ignore(shell_j_async(host, "fs.remove", { "path": Json::string(path), "recursive": Json::boolean(recursive) }))
    },
    unlink: async fn(path) {
      if (shell_j_async(host, "fs.stat", { "path": Json::string(path), "lstat": Json::boolean(true) }) catch { _ => Json::null() }) is Null {
        raise enoent("unlink", path)
      }
      ignore(shell_j_async(host, "fs.remove", { "path": Json::string(path) }))
    },
    stat: async fn(path) { stat_of_shell(path, true) },
    lstat: async fn(path) { stat_of_shell(path, false) },
    copy_tree: async fn(from, to) { copy_tree(from, to) },
    read_at: async fn(path, offset, length) {
      match shell_j_async(host, "fs.bytes", { "path": Json::string(path), "from": Json::number(offset), "length": Json::number(length.to_double()) }) {
        String(hex) => hex_bytes(hex)
        _ => raise enoent("open", path)
      }
    },
    write_at: async fn(path, offset, data) { put(path, data, { "offset": Json::number(offset) }) },
    create: async fn(path) { put(path, b"", { "exclusive": Json::boolean(true) }) },
    append: async fn(path, data) { put(path, data, {}) },
    exists_sync: path => (shell_j(host, "fs.stat", { "path": Json::string(path) }) catch { _ => Json::null() }) is String(_),
    read_sync: path => shell_text_of(shell_j(host, "fs.read", { "path": Json::string(path) }) catch { _ => Json::null() }),
    // (the shell watches no folder: a part that would follow one looks again as it is asked)
    watch: (dir, _, _) => raise FsFailed("ENOSYS: function not implemented, watch '\{dir}'", "ENOSYS"),
  }
  {
    clock,
    spawn: f => ignore(host.rt.fork(f)),
    procs,
    net,
    fs,
    log: { say: (level, part, w, fields) => @host.note("\{level} \{part}: \{w} \{stringify(fields)}") },
    os,
    words,
    random,
    random_int: (lo, hi) => {
      let b = random(4)
      let v = (b[0].to_int() << 24 | b[1].to_int() << 16 | b[2].to_int() << 8 | b[3].to_int()) & 0x7fffffff
      lo + v % (hi - lo)
    },
  }
}
