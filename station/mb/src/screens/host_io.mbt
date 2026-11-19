// These parts' ports on a station's program (`@host.Host`, the shell's IO on the program's runtime): the clock and
// its timers on the runtime, connections by the shell's `unix.open` and `tcp.open` (read by `tcp.read`, written by
// `tcp.write`, let go by `tcp.close`), the files by its `fs.*`, random bytes by `crypto.random`, the log on the
// program's stderr. What the shell does not do (a child process followed while it runs, a folder watched, the
// platform's facts and the station's words) its caller gives: the station's Node, which runs the processes and knows
// the machine, or what stands for it.

///|
fn fs_failed(e : Error) -> FsFailed {
  let m = @host_world.shell_error_msg(e)
  FsFailed(m, @host_world.os_code(m))
}

///|
async fn[T] wrap_fs(f : async () -> T) -> T {
  f() catch {
    FsFailed(_, _) as e => raise e
    e => raise fs_failed(e)
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
    after: (ms, f) => @host_world.after_cb(host, js_max(0.0, ms).to_int(), f),
    micros: () => @host.now().to_double() * 1000.0,
  }
  let net : Net = {
    connect: (target, events) => {
      let conn : Ref[@host.Conn?] = Ref(None)
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
        host.rt.fork_daemon("screens.connect", on_error=e => {
          (events.error)(message_of(e))
          close_once()
        }, async fn() {
          let opened = (match target {
            Unix(path) => host.unix_open(path)
            Tcp(port) => host.tcp_open(port)
          }) catch {
            e => {
              (events.error)(@host_world.shell_error_msg(e))
              close_once()
              return
            }
          }
          conn.val = Some(opened)
          if destroyed.val {
            opened.socket.destroy()
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
            let got = opened.socket.read() catch {
              e => {
                (events.error)(message_of(e))
                break
              }
            }
            match got {
              Some(b) => if !destroyed.val { (events.data)(b) }
              None => break
            }
          }
          // The far end gone (or a read failed) with no destroy asked: the connection let go here, as Node's socket
          // is once it ends, never left open in the shell (a destroy asked already let it go; another is nothing).
          if !destroyed.val {
            opened.socket.destroy()
          }
          close_once()
        }),
      )
      // (each step on the connection a fiber of its own, in the order asked; what one fails with let go)
      let send = (step : async (@net.Socket) -> Unit) => match conn.val {
        Some(c) => ignore(host.rt.fork_quiet(async fn() { step(c.socket) catch { _ => () } }))
        None => ()
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
    let lst = @host_world.fs_lstat(host, path) catch { _ => None }
    guard lst is Some(l) else { raise enoent(if follow { "stat" } else { "lstat" }, path) }
    let link = l.kind == "link"
    if follow && link {
      let meta = @host_world.fs_meta(host, path) catch { _ => None }
      guard meta is Some(m) else { raise enoent("stat", path) }
      let kind = @host_world.fs_stat_kind(host, path) catch { _ => None }
      return {
        dir: kind == Some("dir"),
        file: kind == Some("file"),
        link: false,
        size: m.size,
        mtime_ms: m.mtime_ms,
      }
    }
    { dir: l.kind == "dir", file: l.kind == "file", link, size: l.size, mtime_ms: l.mtime_ms }
  }
  let random = (n : Int) => @host_world.random_bytes(host, n)
  async fn copy_tree(from : String, to : String) -> Unit {
    wrap_fs(async fn() {
      match @host_world.fs_stat_kind(host, from, lstat=true) {
        Some("dir") => {
          @host_world.fs_mkdir(host, to)
          match @host_world.fs_readdir(host, from) {
            Some(names) =>
              for n in names {
                copy_tree(pj([from, n]), pj([to, n]))
              }
            None => ()
          }
        }
        Some("link") =>
          match @host_world.fs_readlink(host, from) {
            Some(target) => @host_world.fs_symlink(host, target, to)
            None => raise enoent("cp", from)
          }
        Some(_) => @host_world.fs_copy(host, from, to)
        None => raise enoent("cp", from)
      }
    })
  }

  let fs : Files = {
    read: async fn(path) {
      wrap_fs(async fn() {
        match @host_world.fs_read_bytes(host, path) {
          Some(b) => b
          None => raise enoent("open", path)
        }
      })
    },
    write: async fn(path, data, mode) { wrap_fs(async fn() { @host_world.fs_put_whole(host, path, data, mode?) }) },
    access: async fn(path, mode) {
      match (@host_world.fs_lstat(host, path) catch { _ => None }) {
        Some(st) =>
          if mode == 1 {
            (st.mode.to_int() & 0o111) != 0 && (st.kind == "file" || st.kind == "link")
          } else {
            true
          }
        None => false
      }
    },
    readdir: async fn(path) {
      wrap_fs(async fn() {
        match @host_world.fs_readdir_types(host, path) {
          Some(xs) => xs.map(x => { name: x.name, dir: x.dir })
          None => raise enoent("scandir", path)
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
      for x in random(6) {
        tail.write_char(alphabet.unsafe_get(x.to_int() % alphabet.length()).unsafe_to_char())
      }
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
        if !force && !(@host_world.fs_exists(host, path, lstat=true) catch { _ => false }) {
          raise enoent("rm", path)
        }
        @host_world.fs_remove(host, path, recursive~)
      })
    },
    unlink: async fn(path) {
      wrap_fs(async fn() {
        if !(@host_world.fs_exists(host, path, lstat=true) catch { _ => false }) {
          raise enoent("unlink", path)
        }
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
    exists_sync: path => @host_world.fs_exists_sync(host, path),
    read_sync: path => @host_world.fs_read_text_sync(host, path),
    // (the shell watches no folder: a part that would follow one looks again as it is asked)
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
    random_int: (lo, hi) => @host_world.random_int(host, lo, hi),
  }
}
