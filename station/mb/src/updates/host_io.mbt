// These parts' world on the station's program: the machine's files, HTTP and Ed25519 through the shell (client/shell's
// `fs.*`, `fetch`, `crypto.*`), answered here as node:fs, fetch and node:crypto answer the TypeScript; what is Node's
// (the platform's lookups, the processes it starts and follows, the log, the config, the cloud's transport) asked of it
// (`node`, the program's channel to its station). Its clock and timers the program's runtime's.

///|
fn sarg(args : Array[J], i : Int) -> String {
  if i < args.length() {
    text(Some(args[i])).unwrap_or("")
  } else {
    ""
  }
}

///|
fn oarg(args : Array[J], i : Int) -> String? {
  if i < args.length() {
    text(Some(args[i]))
  } else {
    None
  }
}

///|
fn jarg(args : Array[J], i : Int) -> J {
  if i < args.length() {
    args[i]
  } else {
    Null
  }
}

///|
fn darg(args : Array[J], i : Int) -> Double? {
  if i < args.length() {
    num(Some(args[i]))
  } else {
    None
  }
}

///|
fn enoent(syscall : String, path : String) -> Error {
  thrown("Error", @host_world.enoent_msg(syscall, path), more=[("code", js("ENOENT"))])
}

///|
fn lstat_j(st : @host_world.LstatInfo) -> J {
  jo([
    ("size", jn(st.size)), ("file", jb(st.kind == "file")), ("dir", jb(st.kind == "dir")),
    ("symlink", jb(st.kind == "link")), ("dev", ji(0)), ("ino", jn(st.ino)),
    ("mtimeMs", jn(st.mtime_ms)), ("mode", jn(st.mode)),
  ])
}

///|
fn is_sync_call(name : String) -> Bool {
  ends_with(name, "Sync") || name == "crypto.randomBytes"
}

///|
async fn[T] wrap_shell(f : async () -> T) -> T {
  f() catch {
    Thrown(_, _) as e => raise e
    e => raise fail(@host_world.shell_error_msg(e))
  }
}

///|
/// The world's calls the shell answers; none for what is asked of Node.
async fn host_answer(host : @host.Host, name : String, a : Array[J]) -> J? {
  wrap_shell(async fn() {
    let sync = is_sync_call(name)
    let path = sarg(a, 0)
    let lstat = async fn(p : String) -> J? { @host_world.fs_lstat(host, p, sync~).map(lstat_j) }
    let real = async fn(p : String) -> String? { @host_world.fs_realpath(host, p, sync~) }
    let stat = async fn(p : String) -> J? {
      match real(p) { Some(r) => lstat(r); None => None }
    }
    match name {
      "fs.readFile" | "fs.readFileSync" =>
        if oarg(a, 1) == Some("utf8") {
          match @host_world.fs_read_text(host, path, sync~) { Some(t) => Some(js(t)); None => raise enoent("open", path) }
        } else {
          match @host_world.fs_read_bytes(host, path, sync~) { Some(b) => Some(jbytes(b)); None => raise enoent("open", path) }
        }
      "fs.createReadStream" =>
        match @host_world.fs_read_bytes(host, path, sync~) { Some(b) => Some(jbytes(b)); None => raise enoent("open", path) }
      "fs.lstat" | "fs.lstatSync" =>
        match lstat(path) {
          Some(st) => Some(st)
          None => if get(Some(jarg(a, 1)), "throwIfNoEntry") is Some(Bool(false)) { Some(Null) } else { raise enoent("lstat", path) }
        }
      "fs.stat" | "fs.statSync" | "fh.stat" =>
        match stat(path) { Some(st) => Some(st); None => raise enoent("stat", path) }
      "fs.access" | "fs.accessSync" => {
        guard stat(path) is Some(st) else { raise enoent("access", path) }
        let mode = darg(a, 1).unwrap_or(0.0).to_int()
        let bits = num(get(Some(st), "mode")).unwrap_or(0.0).to_int()
        let unix = machine.val.plat is Unix
        if ((mode & 2) != 0 && (bits & 0o222) == 0) || (unix && (mode & 1) != 0 && (bits & 0o111) == 0) {
          raise thrown("Error", "EACCES: permission denied, access '\{path}'", more=[("code", js("EACCES"))])
        }
        Some(Null)
      }
      "fs.realpath" | "fs.realpathSync" =>
        match real(path) { Some(r) => Some(js(r)); None => raise enoent("realpath", path) }
      "fs.existsSync" => Some(jb(@host_world.fs_exists(host, path, sync~)))
      "fs.readdir" | "fs.readdirSync" =>
        match @host_world.fs_readdir(host, path, sync~) { Some(xs) => Some(ja(xs.map(js))); None => raise enoent("scandir", path) }
      "fs.readlinkSync" =>
        match @host_world.fs_readlink(host, path, sync~) { Some(t) => Some(js(t)); None => raise enoent("readlink", path) }
      "fs.mkdir" => { @host_world.fs_mkdir(host, path, sync~); Some(Null) }
      "fs.rm" | "fs.rmSync" | "fs.unlinkSync" => {
        let recursive = get(Some(jarg(a, 1)), "recursive") is Some(Bool(true))
        @host_world.fs_remove(host, path, recursive~, sync~)
        Some(Null)
      }
      "fs.rename" | "fs.renameSync" => { @host_world.fs_rename(host, path, sarg(a, 1), sync~); Some(Null) }
      "fs.writeFile" => { @host_world.fs_write(host, path, sarg(a, 1), sync~); Some(Null) }
      "fs.symlinkSync" => { @host_world.fs_symlink(host, path, sarg(a, 1), sync~); Some(Null) }
      "fs.linkSync" =>
        if @host_world.shell_call(host, sync, "fs.link", { "from": Json::string(path), "to": Json::string(sarg(a, 1)) }) is False {
          raise thrown("Error", "EEXIST: file already exists, link '\{path}' -> '\{sarg(a, 1)}'", more=[("code", js("EEXIST"))])
        } else {
          Some(Null)
        }
      "crypto.randomBytes" =>
        match @host_world.shell_call(host, sync, "crypto.random", { "bytes": Json::number(darg(a, 0).unwrap_or(0.0)) }) {
          String(h) => Some(jbytes(@host_world.hex_bytes(h)))
          _ => raise fail("no random bytes")
        }
      _ => None
    }
  })
}

///|
/// A file's sha256 and size, its bytes read a MiB at a time by the shell (`fs.hash`), none of them held here.
async fn host_hash(host : @host.Host, path : String) -> (String, Double) {
  wrap_shell(async fn() {
    guard @host_world.fs_realpath(host, path) is Some(real) else { raise enoent("open", path) }
    guard @host_world.fs_lstat(host, real) is Some(st) else { raise enoent("open", path) }
    if st.kind == "dir" {
      raise thrown("Error", "EISDIR: illegal operation on a directory, read", more=[("code", js("EISDIR"))])
    }
    match @host_world.shell_call(host, false, "fs.hash", { "path": Json::string(real) }) {
      String(h) => (h, st.size)
      _ => raise enoent("open", path)
    }
  })
}

///|
let fetch_head_ms : Double = 15000.0

///|
let fetch_stall_ms : Double = 60000.0

///|
priv struct Writing {
  files : Map[Int, (String, Buffer)]
  mut next : Int
}

///|
/// The world on the station's program: the shell's files, HTTP and Ed25519, the rest asked of Node (`node`, and what
/// is only told it, `tell`). `clock`: the station's time as it tells the program; `watch`: a directory's changes as
/// Node tells them (the shell watches none).
pub fn host_world(
  host : @host.Host,
  node : async (String, Array[J]) -> J,
  tell : (String, Array[J]) -> Unit,
  clock : Clock,
  watch : async (String, (String?) -> Unit) -> async () -> Unit,
) -> World {
  let writing : Writing = { files: Map([]), next: 3 }
  let ask = async fn(name : String, a : Array[J]) -> J {
    match name {
      "fetch" => {
        let init = jarg(a, 1)
        let headers = match get(Some(init), "headers") {
          Some(Obj(ps)) => ps.map(p => (@jsjson.sanitize_str(p.0), js_string(p.1)))
          _ => []
        }
        let r = host.fetch(
          sarg(a, 0),
          method_=text(get(Some(init), "method")).unwrap_or("GET"),
          headers~,
          head_ms=fetch_head_ms.to_int(),
          stall_ms=fetch_stall_ms.to_int(),
        ) catch {
          e => raise thrown("TypeError", "fetch failed", more=[("cause", js(@host_world.shell_error_msg(e)))])
        }
        let hs = jo(r.headers.map(h => (@jscase.lower(h.0), js(h.1))))
        jo([("status", jn(r.status.to_double())), ("headers", hs), ("chunks", ja([jbytes(r.body)]))])
      }
      "fs.createWriteStream" => Null
      "fs.writeStream.end" => {
        wrap_shell(async fn() { @host_world.fs_put_whole(host, sarg(a, 0), bytes_of(Some(jarg(a, 1)))) })
        Null
      }
      "fs.openSync" => {
        writing.next += 1
        writing.files[writing.next] = (sarg(a, 0), Buffer())
        wrap_shell(async fn() { @host_world.fs_put_whole(host, sarg(a, 0), b"") })
        ji(writing.next)
      }
      "fs.writeSync" => {
        let b = bytes_of(Some(jarg(a, 1)))
        match writing.files.get(darg(a, 0).unwrap_or(0.0).to_int()) {
          Some((_, buf)) => buf.write_bytes(b)
          None => raise thrown("Error", "EBADF: bad file descriptor, write", more=[("code", js("EBADF"))])
        }
        ji(b.length())
      }
      "fs.closeSync" => {
        let fd = darg(a, 0).unwrap_or(0.0).to_int()
        if writing.files.get(fd) is Some((p, buf)) {
          writing.files.remove(fd)
          wrap_shell(async fn() { @host_world.fs_put_whole(host, p, buf.to_bytes()) })
        }
        Null
      }
      "fs.open" => { ignore(host_answer(host, "fs.stat", a)); Null }
      "fh.read" => {
        let got = wrap_shell(async fn() {
          @host_world.fs_read_bytes(host, sarg(a, 0), from=darg(a, 3).unwrap_or(0.0), length=darg(a, 2).unwrap_or(0.0))
        }).unwrap_or(b"")
        jo([("bytesRead", ji(got.length())), ("buffer", jbytes(got))])
      }
      "fh.close" => Null
      _ => match host_answer(host, name, a) { Some(v) => v; None => node(name, a) }
    }
  }
  {
    ask,
    say_now: tell,
    wall_after: fn(ms, f) { @host_world.after_async(host, ms.to_int(), f) },
    clock,
    rt: host.rt,
    json_error: fn(t) { try { ignore(parse(t)); "" } catch { e => e.to_string() } },
    verify: fn(key, signature, message) {
      let args : Json = {
        "alg": Json::string("Ed25519"),
        "key": Json::string(hex(key)),
        "signature": Json::string(hex(signature)),
        "message": Json::string(hex(message)),
      }
      (try host.shell_sync("crypto.verify", args) catch { _ => Json::null() }) is True
    },
    watch,
    hash_stream: Some(async fn(path) { host_hash(host, path) }),
  }
}
