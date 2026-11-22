// The shell's files (client/shell's `fs.*`) as this program reads and writes them off its thread: each call is
// answered from the shell's own threads (`Host::shell`), never on the program's one. A file written whole goes beside
// it first under a name of its own (`unique_tmp`) and is renamed over it: two fibers of one process writing the same
// file at once each rename their own (named by the pid alone, the second rename found the first's gone, ENOENT:
// L13, 2026-11-19), and what failed halfway is let go of, never left beside it.

///|
/// How many names `unique_tmp` gave in this process.
let tmp_seq : Ref[Int64] = { val: 0L }

///|
/// A name beside `path` for process `pid` that no other write of it takes: `<path>.<pid>.<n>.tmp`.
fn tmp_beside(path : String, pid : Int) -> String {
  tmp_seq.val += 1L
  "\{path}.\{pid}.\{tmp_seq.val}.tmp"
}

///|
/// A name beside `path` to write it whole under before renaming it into place, never one this process gave before
/// (`<path>.<pid>.<n>.tmp`): fibers writing the same file at once each have their own.
pub fn unique_tmp(path : String) -> String {
  tmp_beside(path, pid())
}

///|
/// What `fs.bytes` answered as bytes: none where the file did not open.
fn bytes_answered(path : String, said : Json) -> Bytes? raise {
  match said {
    String(hex) =>
      match @hash.hex_decode(hex) {
        Some(b) => Some(b)
        None => fail("the shell's bytes of \{path} are not hex")
      }
    _ => None
  }
}

///|
/// A file's bytes (from byte `from`, `length` of them where it says), read off the program's thread; none where it does
/// not open.
pub async fn Host::read_bytes(self : Host, path : String, from? : Int, length? : Int) -> Bytes? {
  let args : Map[String, Json] = { "path": Json::string(path) }
  if from is Some(f) {
    args["from"] = Json::number(f.to_double())
  }
  if length is Some(n) {
    args["length"] = Json::number(n.to_double())
  }
  let (said, _) = self.shell("fs.bytes", Json::object(args))
  bytes_answered(path, said)
}

///|
/// A file's text (what is not UTF-8 as U+FFFD; with `strict`, none for it, a BOM let go), read off the program's
/// thread; none where it does not open.
pub async fn Host::read_text(self : Host, path : String, strict? : Bool = false) -> String? {
  let (said, _) = self.shell("fs.read", { "path": Json::string(path), "strict": Json::boolean(strict) })
  match said {
    String(s) => Some(s)
    _ => None
  }
}

///|
/// A file's SHA-256 (hex), read off the program's thread; none where it does not open.
pub async fn Host::file_sha256(self : Host, path : String) -> String? {
  let (said, _) = self.shell("fs.hash", { "path": Json::string(path) })
  match said {
    String(h) => Some(h)
    _ => None
  }
}

///|
/// How long a rename waits, attempt by attempt, for a Windows transient file or directory lock (`rename_retrying`).
let rename_backoff : Array[Int] = [20, 40, 80, 160]

///|
/// Whether a rename failure indicates a transient lock (`EPERM`, `EBUSY`, `EACCES`, or Windows sharing/access denied).
fn is_transient_rename_error(e : Error) -> Bool {
  let m = e.to_string()
  m.contains("EPERM") ||
  m.contains("EBUSY") ||
  m.contains("EACCES") ||
  m.contains("(os error 1)") ||
  m.contains("(os error 13)") ||
  m.contains("(os error 16)") ||
  m.contains("(os error 32)") ||
  m.contains("(os error 33)") ||
  m.contains("Permission denied") ||
  m.contains("Access is denied") ||
  m.contains("Operation not permitted") ||
  m.contains("Device or resource busy") ||
  m.contains("Resource busy") ||
  m.contains("being used by another process") ||
  m.contains("locked a portion")
}

///|
/// Renames `from` to `to`, waiting briefly on Windows transient file or directory locks (`EPERM`, `EBUSY`, `EACCES`):
/// a virus scanner, the indexer, or a process that has just exited still holding a handle. Any other error, or one
/// still there once the backoff is spent, is raised as it came.
async fn rename_retrying_by(
  rename : async (String, String) -> Unit,
  from : String,
  to : String,
  backoff? : Array[Int] = rename_backoff,
  wait? : async (Int) -> Unit = async fn(ms) {
    // timer: retry backoff for Windows transient file/directory locks on rename
    @effect.sleep(ms)
  },
) -> Unit {
  for attempt = 0; ; attempt = attempt + 1 {
    try {
      rename(from, to)
      return
    } catch {
      e => {
        if attempt >= backoff.length() || !is_transient_rename_error(e) {
          raise e
        }
        wait(backoff[attempt])
      }
    }
  }
}

///|
/// `fs.rename`, waiting out Windows transient file or directory locks (`EPERM`, `EBUSY`, `EACCES`).
pub async fn Host::rename_retrying(
  self : Host,
  from : String,
  to : String,
  backoff? : Array[Int] = rename_backoff,
) -> Unit {
  rename_retrying_by(
    async fn(a, b) {
      ignore(self.shell("fs.rename", { "from": Json::string(a), "to": Json::string(b) }))
    },
    from,
    to,
    backoff~,
  )
}

///|
/// `write_atomic` over `call` (an op, its arguments and bytes, the shell's answer), beside `path` under `tmp(path)`.
async fn write_atomic_by(
  call : async (String, Json, Bytes?) -> Json,
  tmp : (String) -> String,
  path : String,
  bytes : Bytes,
  mode : Int,
  sync : Bool,
  mkdir : Bool,
  sep : String,
  backoff? : Array[Int] = rename_backoff,
  wait? : async (Int) -> Unit = async fn(ms) {
    // timer: retry backoff for Windows transient file/directory locks on rename
    @effect.sleep(ms)
  },
) -> Unit {
  if mkdir {
    let dir = @nodepath.dirname(sep, path)
    if dir != "" && dir != "." && dir != path {
      ignore(call("fs.mkdir", { "path": Json::string(dir) }, None))
    }
  }
  let beside = tmp(path)
  // (let go of even where the write was given up: the fiber is then cut, and its last call with it unless shielded)
  errdefer @effect.uninterruptible(async fn() {
    ignore(call("fs.remove", { "path": Json::string(beside) }, None)) catch {
      _ => ()
    }
  })
  ignore(
    call(
      "fs.put",
      {
        "path": Json::string(beside),
        "offset": Json::number(0.0),
        "truncate": Json::boolean(true),
        "mode": Json::number(mode.to_double()),
        "sync": Json::boolean(sync),
      },
      Some(bytes),
    ),
  )
  rename_retrying_by(
    async fn(from, to) {
      ignore(call("fs.rename", { "from": Json::string(from), "to": Json::string(to) }, None))
    },
    beside,
    path,
    backoff~,
    wait~,
  )
}

///|
/// `bytes` written to `path` whole (a reader never sees half of it): its folder made (`mkdir`, by `sep`), written beside
/// it under a name of its own with `mode` (synced with `sync`) and renamed over it; what was written beside is let go
/// where that failed.
pub async fn Host::write_atomic(
  self : Host,
  path : String,
  bytes : Bytes,
  mode? : Int = 0o666,
  sync? : Bool = false,
  mkdir? : Bool = true,
  sep? : String = "/",
) -> Unit {
  write_atomic_by(
    async fn(op, args, b) {
      let (said, _) = match b {
        Some(b) => self.shell(op, args, bytes=b)
        None => self.shell(op, args)
      }
      said
    },
    unique_tmp,
    path,
    bytes,
    mode,
    sync,
    mkdir,
    sep,
  )
}

///|
/// The station's private write (ops/files.ts `writePrivateSoon`): `write_atomic` readable by this user alone (0o600),
/// synced.
pub async fn Host::write_private(self : Host, path : String, bytes : Bytes, sep? : String = "/") -> Unit {
  self.write_atomic(path, bytes, mode=0o600, sync=true, mkdir=true, sep~)
}
