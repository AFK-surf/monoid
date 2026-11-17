// What of station_task's directory sync is the machine's on the source (station/src/jobs/dirsync.ts): the queue the
// station's bulk requests to other stations wait in (`Bulk`), and, once a task ended, the patch of what its command
// changed in the mirror (`patch_of`), made by git in a scratch work tree. How a sync goes is the sessions' program's
// (station/mb src/reader/dirsync*.mbt).

///|
pub let mode_file : String = "100644"

///|
pub let mode_exec : String = "100755"

///|
pub let mode_link : String = "120000"

///|
/// A sync request's pieces unpacked at most (the program's `max_raw`).
pub let sync_raw : Int = 16 * 1024 * 1024

///|
/// A request's packed pieces at most, after it.
pub let sync_packed : Int = 16 * 1024 * 1024 + 1024 * 1024

///|
/// A file's content id as Git has it.
pub fn blob_id(content : Bytes) -> String {
  let head = @utf8.encode("blob \{content.length()}")
  let buf = @buffer.new(size_hint=head.length() + 1 + content.length())
  buf.write_bytes(head)
  buf.write_byte(b'\x00')
  buf.write_bytes(content)
  sha1_hex(buf.to_bytes())
}

///|
/// The station's bulk requests to other stations, one at a time, in the order they came: one request's worth (under
/// 1 MiB) ahead of what else the station sends at most.
pub struct Bulk {
  priv lock : @effect.Semaphore
}

///|
pub fn Bulk::new() -> Bulk {
  { lock: @effect.Semaphore::new(1) }
}

///|
/// `f` once the request before it is answered (or failed).
pub async fn[X] Bulk::run(self : Bulk, f : async () -> X) -> X {
  self.lock.acquire()
  defer self.lock.release()
  f()
}

///|
/// A file a task changed in the mirror: its old id and mode, what the command left (None: removed) and its mode.
pub(all) struct Change {
  path : String
  old : String
  mode : String
  after : Bytes?
  after_mode : String?
}

///|
/// A patch and the files whose old content was not found.
pub(all) struct Patch {
  patch : String
  missing : Array[String]
}

///|
async fn git(host : @host.Host, args : Array[String]) -> String raise {
  match run_code(host, "git", args, timeout_ms=600_000, max_bytes=1 << 30) {
    Some((0, out)) => out
    Some((code, _)) => raise HostError("Command failed: git \{join(args, " ")} (\{code})")
    None => raise HostError("Command failed: git \{join(args, " ")}")
  }
}

///|
/// A patch from what the mirror had (`old` ids, taken from `dir` or its Git objects) to what a command left there;
/// None when git is not there. Paths as `git apply` takes them in `dir` (`prefix`: dir's place in its work tree).
pub async fn patch_of(
  host : @host.Host,
  dir : String,
  prefix : String,
  scratch : String,
  changes : Array[Change],
) -> Patch? raise {
  if run_code(host, "git", ["--version"]) is None || run_code(host, "git", ["--version"]) is Some((c, _)) && c != 0 {
    return None
  }
  let missing = []
  mkdirs(host, scratch)
  defer remove(host, scratch, recursive=true)
  let g = async fn(args : Array[String]) -> String raise {
    git(
      host,
      [
        "-C", scratch, "-c", "core.autocrlf=false", "-c", "core.symlinks=true", "-c", "core.filemode=true",
      ] +
      args,
    )
  }
  ignore(g(["init", "-q"]))
  let put_file = async fn(path : String, content : Bytes, mode : String) -> Unit raise {
    let abs = pjoin([scratch] + split(path, "/"))
    mkdirs(host, @nodepath.dirname("/", abs))
    remove(host, abs)
    if mode == mode_link {
      ignore(
        ask(host, "fs.symlink", {
          "target": jstr(@utf8.decode_lossy(content)),
          "path": jstr(abs),
        }),
      )
    } else {
      ignore(put(host, abs, content, offset=0.0, truncate=true))
      ignore(
        ask(host, "fs.chmod", {
          "path": jstr(abs),
          "mode": jint(if mode == mode_exec { 0o755 } else { 0o644 }),
        }),
      )
    }
  }
  let kept = []
  for c in changes {
    let mut before : Bytes? = None
    let abs = pjoin([dir] + split(c.path, "/"))
    match lstat(host, abs) {
      Some(st) => {
        let local = match text(st, "kind") {
          "link" =>
            match try_ask(host, "fs.readlink", { "path": jstr(abs) }) {
              Some(String(t)) => Some(@utf8.encode(t))
              _ => None
            }
          "file" => read_bytes(host, abs)
          _ => None
        }
        match local {
          Some(l) if blob_id(l) == c.old => before = Some(l)
          _ => ()
        }
      }
      None => ()
    }
    if before is None {
      match try_ask(host, "proc.run", {
          "command": jstr("git"),
          "args": Json::array(["-C", dir, "cat-file", "blob", c.old].map(jstr)),
          "hex": jbool(true),
          "timeoutMs": jint(600_000),
          "maxBytes": jint(1 << 30),
        }) {
        Some(String(h)) => before = Some(@hex.decode(h) catch { _ => b"" })
        _ => ()
      }
    }
    guard before is Some(b) else {
      missing.push(c.path)
      continue
    }
    put_file(c.path, b, c.mode)
    kept.push(c)
  }
  ignore(g(["add", "-A"]))
  for c in kept {
    match c.after {
      None => remove(host, pjoin([scratch] + split(c.path, "/")))
      Some(a) => put_file(c.path, a, c.after_mode.unwrap_or(c.mode))
    }
  }
  let patch = g(["diff", "--binary", "--src-prefix=a/\{prefix}", "--dst-prefix=b/\{prefix}"])
  Some({ patch, missing })
}
