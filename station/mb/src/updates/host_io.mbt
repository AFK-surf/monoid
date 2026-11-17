// These parts' world on the station's program: the machine's files, HTTP and Ed25519 through the shell (client/shell's
// `fs.*`, `fetch`, `crypto.*`), answered here as node:fs, fetch and node:crypto answer the TypeScript; what is Node's
// (the platform's lookups, the processes it starts and follows, the log, the config, the cloud's transport) asked of it
// (`node`, the program's channel to its station). Its clock and timers the program's runtime's.

///|
fn shell_error(e : Error) -> String {
  match e {
    @wire.ShellError(m) => m
    e => message_of(e)
  }
}

///|
fn enoent(syscall : String, path : String) -> Error {
  thrown("Error", "ENOENT: no such file or directory, \{syscall} '\{path}'", more=[("code", js("ENOENT"))])
}

///|
fn sj(s : String) -> Json {
  Json::string(s)
}

///|
/// A stat as the world says it, from the shell's `fs.lstat` (links not followed).
fn lstat_j(said : Json) -> J {
  let n = (k : String) => match said {
    Object(m) =>
      match m.get(k) {
        Some(Number(v, ..)) => v
        _ => 0.0
      }
    _ => 0.0
  }
  let kind = match said {
    Object(m) =>
      match m.get("kind") {
        Some(String(k)) => k
        _ => ""
      }
    _ => ""
  }
  jo([
    ("size", jn(n("size"))),
    ("file", jb(kind == "file")),
    ("dir", jb(kind == "dir")),
    ("symlink", jb(kind == "link")),
    ("dev", ji(0)),
    ("ino", jn(n("ino"))),
    ("mtimeMs", jn(n("mtimeMs"))),
    ("mode", jn(n("mode"))),
  ])
}

///|
/// The world's calls the shell answers; none for what is asked of Node.
fn host_answer(host : @host.Host, name : String, a : Array[J]) -> J? raise {
  let sync = (op : String, args : Map[String, Json]) => host.shell_sync(op, Json::object(args)) catch {
    e => raise fail(shell_error(e))
  }
  let path = sarg(a, 0)
  let lstat = (p : String) => match sync("fs.lstat", { "path": sj(p) }) {
    Object(_) as said => Some(lstat_j(said))
    _ => None
  }
  let real = (p : String) => match sync("fs.realpath", { "path": sj(p) }) {
    String(r) => Some(r)
    _ => None
  }
  match name {
    "fs.readFile" | "fs.readFileSync" =>
      if oarg(a, 1) == Some("utf8") {
        match sync("fs.read", { "path": sj(path) }) {
          String(t) => Some(js(t))
          _ => raise enoent("open", path)
        }
      } else {
        match sync("fs.bytes", { "path": sj(path) }) {
          String(h) => Some(jbytes(unhex(h)))
          _ => raise enoent("open", path)
        }
      }
    "fs.createReadStream" =>
      match sync("fs.bytes", { "path": sj(path) }) {
        String(h) => Some(jbytes(unhex(h)))
        _ => raise enoent("open", path)
      }
    "fs.lstat" | "fs.lstatSync" =>
      match lstat(path) {
        Some(s) => Some(s)
        None =>
          if get(Some(jarg(a, 1)), "throwIfNoEntry") is Some(Bool(false)) {
            Some(Null)
          } else {
            raise enoent("lstat", path)
          }
      }
    "fs.stat" | "fs.statSync" | "fh.stat" =>
      match real(path).bind(lstat) {
        Some(s) => Some(s)
        None => raise enoent("stat", path)
      }
    "fs.realpath" | "fs.realpathSync" =>
      match real(path) {
        Some(r) => Some(js(r))
        None => raise enoent("realpath", path)
      }
    "fs.existsSync" => Some(jb(sync("fs.stat", { "path": sj(path) }) is String(_)))
    "fs.readdir" | "fs.readdirSync" =>
      match sync("fs.readdir", { "path": sj(path) }) {
        Array(xs) => Some(ja(xs.filter_map(x => match x { String(s) => Some(js(s)); _ => None })))
        _ => raise enoent("scandir", path)
      }
    "fs.readlinkSync" =>
      match sync("fs.readlink", { "path": sj(path) }) {
        String(t) => Some(js(t))
        _ => raise enoent("readlink", path)
      }
    "fs.mkdir" => {
      ignore(sync("fs.mkdir", { "path": sj(path) }))
      Some(Null)
    }
    "fs.rm" | "fs.rmSync" | "fs.unlinkSync" => {
      let recursive = get(Some(jarg(a, 1)), "recursive") is Some(Bool(true))
      ignore(sync("fs.remove", { "path": sj(path), "recursive": Json::boolean(recursive) }))
      Some(Null)
    }
    "fs.rename" | "fs.renameSync" => {
      ignore(sync("fs.rename", { "from": sj(path), "to": sj(sarg(a, 1)) }))
      Some(Null)
    }
    "fs.writeFile" => {
      ignore(sync("fs.write", { "path": sj(path), "text": sj(sarg(a, 1)) }))
      Some(Null)
    }
    "fs.symlinkSync" => {
      ignore(sync("fs.symlink", { "target": sj(path), "path": sj(sarg(a, 1)) }))
      Some(Null)
    }
    "fs.linkSync" =>
      if sync("fs.link", { "from": sj(path), "to": sj(sarg(a, 1)) }) is False {
        raise thrown("Error", "EEXIST: file already exists, link '\{path}' -> '\{sarg(a, 1)}'", more=[
          ("code", js("EEXIST")),
        ])
      } else {
        Some(Null)
      }
    "crypto.randomBytes" =>
      match sync("crypto.random", { "bytes": Json::number(darg(a, 0).unwrap_or(0.0)) }) {
        String(h) => Some(jbytes(unhex(h)))
        _ => raise fail("no random bytes")
      }
    _ => None
  }
}

///|
/// What is written as it comes (`createWriteStream`, `openSync`/`writeSync`): kept here, written whole at its end.
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
          Some(Obj(ps)) => Json::array(ps.map(p => Json::array([sj(@jsjson.text(p.0)), sj(js_string(p.1))])))
          _ => Json::array([])
        }
        let args : Json = {
          "url": sj(sarg(a, 0)),
          "method": sj(text(get(Some(init), "method")).unwrap_or("GET")),
          "headers": headers,
        }
        let (answer, bytes) = host.shell("fetch", args) catch {
          e => raise thrown("TypeError", "fetch failed", more=[("cause", js(shell_error(e)))])
        }
        let status = match answer {
          Object(m) =>
            match m.get("status") {
              Some(Number(n, ..)) => n
              _ => 0.0
            }
          _ => 0.0
        }
        let hs = match answer {
          Object(m) =>
            match m.get("headers") {
              Some(Array(xs)) =>
                jo(
                  xs.filter_map(x => match x {
                    Array([String(k), String(v)]) => Some((@jscase.lower(k), js(v)))
                    _ => None
                  }),
                )
              _ => jo([])
            }
          _ => jo([])
        }
        jo([("status", jn(status)), ("headers", hs), ("chunks", ja([jbytes(bytes.unwrap_or(b""))]))])
      }
      "fs.createWriteStream" => Null
      "fs.writeStream.end" => {
        write_bytes(host, sarg(a, 0), bytes_of(Some(jarg(a, 1))))
        Null
      }
      "fs.openSync" => {
        writing.next += 1
        writing.files[writing.next] = (sarg(a, 0), Buffer())
        write_bytes(host, sarg(a, 0), b"")
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
        match writing.files.get(fd) {
          Some((p, buf)) => {
            writing.files.remove(fd)
            write_bytes(host, p, buf.to_bytes())
          }
          None => ()
        }
        Null
      }
      "fs.open" => {
        ignore(host_answer(host, "fs.stat", a))
        Null
      }
      "fh.read" => {
        let r = host.shell_sync("fs.bytes", {
          "path": sj(sarg(a, 0)),
          "from": Json::number(darg(a, 3).unwrap_or(0.0)),
          "length": Json::number(darg(a, 2).unwrap_or(0.0)),
        }) catch {
          e => raise fail(shell_error(e))
        }
        let got = match r {
          String(h) => unhex(h)
          _ => b""
        }
        jo([("bytesRead", ji(got.length())), ("buffer", jbytes(got))])
      }
      "fh.close" => Null
      _ =>
        match host_answer(host, name, a) {
          Some(v) => v
          None => node(name, a)
        }
    }
  }
  {
    ask,
    say_now: tell,
    wall_after: async fn(ms, f) {
      let fiber = host.rt.fork(async fn() {
        @effect.sleep(ms.to_int())
        f()
      })
      () => fiber.interrupt()
    },
    clock,
    rt: host.rt,
    json_error: async fn(t) {
      (try {
        ignore(parse(t))
        ""
      } catch {
        e => e.to_string()
      })
    },
    verify: async fn(key, signature, message) {
      let args : Json = {
        "alg": sj("Ed25519"),
        "key": sj(hex(key)),
        "signature": sj(hex(signature)),
        "message": sj(hex(message)),
      }
      (try host.shell_sync("crypto.verify", args) catch { _ => Json::null() }) is True
    },
    watch,
  }
}

///|
/// `bytes` written whole at `path` (the shell's `fs.put` from its start, cut where they end).
async fn write_bytes(host : @host.Host, path : String, bytes : Bytes) -> Unit {
  let args : Json = { "path": sj(path), "offset": Json::number(0.0), "truncate": Json::boolean(true) }
  ignore(host.shell("fs.put", args, bytes~)) catch {
    e => raise fail(shell_error(e))
  }
}
