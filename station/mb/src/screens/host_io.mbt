// These parts' ports on a station's program (`@host.Host`, the shell's IO on the program's runtime): the clock and
// its timers on the runtime, connections by the shell's `unix.open` and `tcp.open`, the files by its `fs.*`, random
// bytes by `crypto.random`, the log on the program's stderr.

///|
async fn[T] wrap_fs(f : async () -> T) -> T {
  f() catch {
    FsFailed(_, _) as e => raise e
    e => {
      let m = @host_world.shell_error_msg(e)
      raise FsFailed(m, @host_world.os_code(m))
    }
  }
}

///|
fn enoent(op : String, path : String) -> FsFailed {
  FsFailed(@host_world.enoent_msg(op, path), "ENOENT")
}

///|
/// The ports on `host`: `procs` (how a child is started and run), `os` (what the machine is) and `words` (the
/// station's) given by the caller; the wall's time as the station tells it (`now`).
pub fn host_io(host : @host.Host, procs : Procs, os : Os, words : Words, now? : (() -> Double)? = None) -> Io {
  let wall = now.unwrap_or(() => @host.wall_ms().to_double())
  let clock : Clock = {
    now: wall,
    after: (ms, f) => {
      let live = Ref(true)
      host.rt.after(js_max(0.0, ms).to_int(), () => if live.val { live.val = false; f() })
      () => live.val = false
    },
    micros: () => @host.now().to_double() * 1000.0,
  }
  let net : Net = {
    connect: (target, events) => {
      let conn : Ref[@host.Conn?] = Ref(None)
      let destroyed = Ref(false)
      let closed = Ref(false)
      let paused = Ref(false)
      let waiting : Ref[@effect.Deferred[Unit]?] = Ref(None)
      let close_once = () => if !closed.val { closed.val = true; (events.close)() }
      ignore(
        host.rt.fork_daemon("screens.connect", on_error=e => { (events.error)(message_of(e)); close_once() }, async fn() {
          let opened = (match target { Unix(path) => host.unix_open(path); Tcp(port) => host.tcp_open(port) }) catch {
            e => { (events.error)(@host_world.shell_error_msg(e)); close_once(); return }
          }
          conn.val = Some(opened)
          if destroyed.val { opened.socket.destroy(); return }
          (events.connect)()
          while !destroyed.val {
            if paused.val {
              let d : @effect.Deferred[Unit] = @effect.Deferred::new()
              waiting.val = Some(d)
              d.wait()
              continue
            }
            let got = opened.socket.read() catch { e => { (events.error)(message_of(e)); break } }
            match got { Some(b) => if !destroyed.val { (events.data)(b) }; None => break }
          }
          if !destroyed.val { opened.socket.destroy() }
          close_once()
        }),
      )
      let send = (step : async (@net.Socket) -> Unit) => if conn.val is Some(c) {
        ignore(host.rt.fork_quiet(async fn() { step(c.socket) catch { _ => () } }))
      }
      {
        write: b => send(async fn(s) { s.write(b) }),
        end: () => send(async fn(s) { s.end_write() }),
        destroy: () => if !destroyed.val {
          destroyed.val = true
          send(async fn(s) { s.destroy() })
          ignore(host.rt.fork_quiet(() => close_once()))
        },
        destroyed: () => destroyed.val,
        pause: () => paused.val = true,
        flow_again: () => {
          paused.val = false
          if waiting.val is Some(d) { waiting.val = None; ignore(d.succeed(())) }
        },
      }
    },
  }
  let stat_of_shell = async fn(path : String, follow : Bool) -> Stat {
    guard (@host_world.fs_lstat(host, path) catch { _ => None }) is Some(l) else {
      raise enoent(if follow { "stat" } else { "lstat" }, path)
    }
    let link = l.kind == "link"
    if follow && link {
      guard (@host_world.fs_meta(host, path) catch { _ => None }) is Some(m) else { raise enoent("stat", path) }
      let kind = @host_world.shell_call(host, false, "fs.stat", { "path": Json::string(path) }) catch { _ => Json::null() }
      return { dir: kind is String("dir"), file: kind is String("file"), link: false, size: m.size, mtime_ms: m.mtime_ms }
    }
    { dir: l.kind == "dir", file: l.kind == "file", link, size: l.size, mtime_ms: l.mtime_ms }
  }
  let random = (n : Int) => {
    let b = @host_world.hex_bytes(@host_world.random_hex(host, n))
    if b.length() == n { b } else { Bytes::from_array(FixedArray::make(n, b'\x00')) }
  }
  async fn copy_tree(from : String, to : String) -> Unit {
    wrap_fs(async fn() {
      match @host_world.shell_call(host, false, "fs.stat", { "path": Json::string(from), "lstat": Json::boolean(true) }) {
        String("dir") => {
          @host_world.fs_mkdir(host, to)
          if @host_world.fs_readdir(host, from) is Some(names) {
            for n in names { copy_tree(pj([from, n]), pj([to, n])) }
          }
        }
        String("link") =>
          match @host_world.fs_readlink(host, from) {
            Some(target) => @host_world.fs_symlink(host, target, to)
            None => raise enoent("cp", from)
          }
        String(_) => ignore(@host_world.shell_call(host, false, "fs.copy", { "from": Json::string(from), "to": Json::string(to) }))
        _ => raise enoent("cp", from)
      }
    })
  }
  let fs : Files = {
    read: async fn(path) {
      wrap_fs(async fn() {
        match @host_world.fs_read_bytes(host, path) { Some(b) => b; None => raise enoent("open", path) }
      })
    },
    write: async fn(path, data, mode) { wrap_fs(async fn() { @host_world.fs_put_whole(host, path, data, mode?) }) },
    access: async fn(path, mode) {
      match (@host_world.fs_lstat(host, path) catch { _ => None }) {
        Some(st) => mode != 1 || ((st.mode.to_int() & 0o111) != 0 && (st.kind == "file" || st.kind == "link"))
        None => false
      }
    },
    readdir: async fn(path) {
      wrap_fs(async fn() {
        match @host_world.shell_call(host, false, "fs.readdir", { "path": Json::string(path), "types": Json::boolean(true) }) {
          Array(xs) => xs.filter_map(x => match x { Array([String(name), String(kind)]) => Some({ name, dir: kind == "dir" }); _ => None })
          _ => raise enoent("scandir", path)
        }
      })
    },
    mkdir: async fn(path, recursive, _) {
      wrap_fs(async fn() {
        if !recursive && (@host_world.fs_exists(host, path) catch { _ => false }) {
          raise FsFailed(@host_world.eexist_msg("mkdir", path), "EEXIST")
        }
        @host_world.fs_mkdir(host, path)
      })
    },
    mkdtemp: async fn(prefix) {
      let alphabet = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
      let tail = StringBuilder()
      for x in random(6) { tail.write_char(alphabet.unsafe_get(x.to_int() % alphabet.length()).unsafe_to_char()) }
      let path = prefix + tail.to_string()
      wrap_fs(async fn() { @host_world.fs_mkdir(host, path) })
      path
    },
    rename: async fn(from, to) {
      wrap_fs(async fn() { @host_world.fs_rename(host, from, to) }) catch {
        FsFailed(m, code) =>
          raise (if code == "EIO" && !(@host_world.fs_exists(host, from, lstat=true) catch { _ => false }) {
            FsFailed("ENOENT: no such file or directory, rename '\{from}' -> '\{to}'", "ENOENT")
          } else {
            FsFailed(m, code)
          })
        e => raise e
      }
    },
    rm: async fn(path, recursive, force) {
      wrap_fs(async fn() {
        if !force && !(@host_world.fs_exists(host, path, lstat=true) catch { _ => false }) { raise enoent("rm", path) }
        @host_world.fs_remove(host, path, recursive~)
      })
    },
    unlink: async fn(path) {
      wrap_fs(async fn() {
        if !(@host_world.fs_exists(host, path, lstat=true) catch { _ => false }) { raise enoent("unlink", path) }
        @host_world.fs_remove(host, path)
      })
    },
    stat: async fn(path) { stat_of_shell(path, true) },
    lstat: async fn(path) { stat_of_shell(path, false) },
    copy_tree: async fn(from, to) { copy_tree(from, to) },
    read_at: async fn(path, offset, length) {
      wrap_fs(async fn() {
        match @host_world.fs_read_bytes(host, path, from=offset, length=length.to_double()) {
          Some(b) => b
          None => raise enoent("open", path)
        }
      })
    },
    write_at: async fn(path, offset, data) { wrap_fs(async fn() { @host_world.fs_put(host, path, data, offset~) }) },
    create: async fn(path) { wrap_fs(async fn() { @host_world.fs_put(host, path, b"", exclusive=true) }) },
    append: async fn(path, data) { wrap_fs(async fn() { @host_world.fs_put(host, path, data) }) },
    exists_sync: path => (host.shell_sync("fs.stat", { "path": Json::string(path) }) catch { _ => Json::null() }) is String(_),
    read_sync: path => @host_world.fs_read_text_sync(host, path),
    watch: (dir, _, _) => raise FsFailed("ENOSYS: function not implemented, watch '\{dir}'", "ENOSYS"),
  }
  {
    clock,
    spawn: f => @host_world.spawn_daemon(host, "screens", f),
    procs,
    net,
    fs,
    log: { say: (level, part, w, fields) => @host.note("\{level} \{part}: \{w} \{stringify(fields)}") },
    os,
    words,
    random,
    random_int: (lo, hi) => {
      let b = random(4)
      let v = ((b[0].to_int() << 24) | (b[1].to_int() << 16) | (b[2].to_int() << 8) | b[3].to_int()) & 0x7fffffff
      lo + v % (hi - lo)
    },
  }
}
