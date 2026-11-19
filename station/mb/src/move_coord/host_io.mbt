// These parts' IO on the station's program: its files through the shell (client/shell's `fs.*`), its clock and fibers
// on the program's runtime, its random bytes from the system's source. What a test gives instead is the harness's.

///|
async fn[T] wrap_failed(f : async () -> T) -> T {
  f() catch {
    e => raise Failed(e.to_string())
  }
}

///|
/// The machine's files, as the shell writes them (`fs.write` beside and renamed into place, `fs.put` appended).
pub fn host_disk(host : @host.Host) -> Disk {
  {
    read: path => @host_world.fs_read_text_sync(host, path),
    write: async fn(path, text) { wrap_failed(async fn() { @host_world.fs_write(host, path, text, sync=true) }) },
    append: async fn(path, text) {
      wrap_failed(async fn() { @host_world.fs_mkdir(host, @nodepath.dirname("/", path), sync=true) })
      @host_world.fs_put(host, path, @utf8.encode(text))
    },
    remove: async fn(path) { wrap_failed(async fn() { @host_world.fs_remove(host, path, sync=true) }) },
    spawn: f => @host_world.spawn_daemon(host, "move_coord", f),
  }
}

///|
/// The machine's files as repos.ts asks them (node:fs/promises).
pub fn host_fs(host : @host.Host) -> Fs {
  {
    read_text: async fn(path) { @host_world.fs_read_text(host, path, sync=true) catch { _ => None } },
    readdir: async fn(path) { @host_world.fs_readdir(host, path, sync=true) catch { _ => None } },
    mtime: async fn(path) { (@host_world.fs_meta(host, path, sync=true) catch { _ => None }).map(m => m.mtime_ms) },
    size: async fn(path) { (@host_world.fs_meta(host, path, sync=true) catch { _ => None }).map(m => m.size) },
    realpath: async fn(path) { @host_world.fs_realpath(host, path, sync=true) catch { _ => None } },
    mkdir: async fn(path) { wrap_failed(async fn() { @host_world.fs_mkdir(host, path, sync=true) }) },
    rename: async fn(from, to) { wrap_failed(async fn() { @host_world.fs_rename(host, from, to, sync=true) }) },
    remove: async fn(path, recursive) {
      wrap_failed(async fn() { @host_world.fs_remove(host, path, recursive~, sync=true) })
    },
    write_from: async fn(path, next) {
      let mut first = true
      while true {
        let piece = match next() {
          Some(p) => p
          None => break
        }
        if first {
          @host_world.fs_put_whole(host, path, piece)
          first = false
        } else {
          @host_world.fs_put(host, path, piece)
        }
      }
      if first {
        @host_world.fs_put_whole(host, path, b"")
      }
    },
  }
}

///|
/// The program's clock and fibers: its runtime's timers, on the machine's clock.
pub fn host_clock(host : @host.Host) -> Clock {
  {
    now: () => @host.epoch_ms(),
    after: (ms, f) => @host_world.after(host, ms, f),
    every: (ms, f) => @host_world.every(host, ms, f, swallow_error=true),
    spawn: f => @host_world.spawn_daemon(host, "move_coord", f),
  }
}

///|
/// `n` random bytes as hex, from the system's source.
pub fn host_random(host : @host.Host) -> (Int) -> String {
  n => @host_world.random_hex(host, n)
}
