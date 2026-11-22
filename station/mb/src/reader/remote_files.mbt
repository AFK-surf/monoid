// What the remote tasks (remote.mbt, dirsync.mbt) ask of the filesystem, through the shell (client/shell `fs.*`, each
// off this program's thread), as station/src/jobs/remote.ts did with node:fs/promises; and their records, written as
// the Rust's were (JSON.stringify's bytes, a whole file renamed into place) so a station from before reads them.

///|
suberror FsError {
  FsError(String)
}

///|
/// Its words as they are where it is said (`to_string`), not its type's name.
impl Show for FsError with output(self, logger) {
  match self {
    FsError(m) => logger.write_string(m)
  }
}

///|
fn FsError::of(e : Error) -> String {
  match e {
    FsError(m) => m
    @wire.ShellError(m) => m
    _ => Asked::message(e)
  }
}

///|
/// `op` of the shell with `args`, its answer's JSON.
async fn Actors::fs(self : Actors, op : String, args : Map[String, Json], bytes? : Bytes) -> Json raise {
  let (json, _) = match bytes {
    Some(b) => self.host.shell(op, Json::object(args), bytes=b)
    None => self.host.shell(op, Json::object(args))
  }
  json
}

///|
/// JSON.stringify of `v` (keys in their order, numbers and strings as JavaScript writes them).
fn js_text(v : Json) -> String {
  @jsjson.stringify(@replica.of_json(v))
}

///|
/// remote.ts `hash`: SHA-256 of the parts as compact JSON, hex.
fn rhash(v : Json) -> String {
  @activity.sha256_hex(@activity.utf8(js_text(v)))
}

///|
/// Node's path.join on this station's system (`--sep`): what is told Node of a path (`writing`, `wrote`, the records'
/// paths it waits on and keeps) is the path its own join makes, so on Windows `\`, never a `/` of this program's.
fn Actors::rjoin(self : Actors, parts : Array[String]) -> String {
  @nodepath.join(self.sep, parts)
}

///|
fn Actors::rdirname(self : Actors, path : String) -> String {
  @nodepath.dirname(self.sep, path)
}

///|
fn Actors::rbasename(self : Actors, path : String) -> String {
  @nodepath.basename(self.sep, path)
}

///|
/// What lstat says (`fs.lstat`): kind, size, mode, ino, mtimeMs, ctimeMs; None when nothing is there.
async fn Actors::lstat(self : Actors, path : String) -> Json? raise {
  match self.fs("fs.lstat", { "path": jstr(path) }) {
    Null => None
    st => Some(st)
  }
}

///|
fn kind_of_stat(st : Json) -> String {
  str_of(st.value("kind")).unwrap_or("")
}

///|
async fn Actors::there(self : Actors, path : String) -> Bool raise {
  self.lstat(path) is Some(_)
}

///|
async fn Actors::read_text(self : Actors, path : String) -> String? raise {
  match self.fs("fs.read", { "path": jstr(path), "strict": jbool(true) }) {
    String(s) => Some(s)
    _ => None
  }
}

///|
async fn Actors::readdir_names(self : Actors, path : String) -> Array[String] raise {
  match self.fs("fs.readdir", { "path": jstr(path) }) {
    Array(rows) =>
      rows.filter_map(r => match r {
        Array([String(n), ..]) => Some(n)
        String(n) => Some(n)
        _ => None
      })
    _ => []
  }
}

///|
async fn Actors::mkdirs(self : Actors, path : String) -> Unit raise {
  ignore(self.fs("fs.mkdir", { "path": jstr(path) }))
}

///|
async fn Actors::remove(self : Actors, path : String, recursive? : Bool = false) -> Unit raise {
  ignore(self.fs("fs.remove", { "path": jstr(path), "recursive": jbool(recursive) }))
}

///|
async fn Actors::rename(self : Actors, from : String, to : String) -> Unit raise {
  ignore(self.fs("fs.rename", { "from": jstr(from), "to": jstr(to) }))
}

///|
/// Random hex, `n` bytes of the system's source.
fn Actors::random_hex(self : Actors, n : Int) -> String {
  match (try Some(self.host.shell_sync("crypto.random", { "bytes": jnum(n.to_double()) })) catch { _ => None }) {
    Some(String(s)) => s
    _ => {
      self.next += 1
      "\{self.next}"
    }
  }
}

///|
/// A record read (JSON); raised when it is not there or not JSON.
async fn Actors::read_json(self : Actors, path : String) -> Json raise {
  self.written(path)
  match self.read_text(path) {
    Some(text) => @json.parse(text) catch { _ => raise FsError("\{path}: not JSON") }
    None => raise FsError("ENOENT: \{path}")
  }
}

///|
/// Once what was asked to be written of `path` before is written (remote.ts `written`).
async fn Actors::written(self : Actors, path : String) -> Unit {
  while self.remote.writing.get(path) is Some(d) {
    d.wait() catch { _ => () }
    if self.remote.writing.get(path) is Some(now) && physical_equal(now, d) {
      break
    }
  }
}

///|
/// `work` after what was asked of `path` before it (remote.ts `inTurn`).
async fn[X] Actors::in_turn(self : Actors, path : String, work : async () -> X raise) -> X raise {
  let before = self.remote.writing.get(path)
  let mine : @effect.Deferred[Unit] = @effect.Deferred::new()
  self.remote.writing[path] = mine
  // (Node told of it first, so that what waits there on the record's write, told after this, waits for it too)
  self.next += 1
  let id = jnum(self.next.to_double())
  self.tell(remote_key, "writing", [jstr(path), id])
  if before is Some(b) {
    b.wait() catch { _ => () }
  }
  defer {
    self.tell(remote_key, "wrote", [jstr(path), id])
    ignore(mine.succeed(()))
    if self.remote.writing.get(path) is Some(now) && physical_equal(now, mine) {
      self.remote.writing.remove(path)
    }
  }
  work()
}

///|
/// `json` written whole or not at all: a private temporary file, synced, renamed over (remote.ts `writeWhole`).
async fn Actors::write_whole(self : Actors, path : String, json : String) -> Unit raise {
  let temp = self.with_extension(path, "\{self.random_hex(8)}.tmp")
  ignore(self.fs("fs.put", { "path": jstr(temp), "offset": jnum(0), "exclusive": jbool(true), "truncate": jbool(true), "sync": jbool(true), "mode": jnum(0o600.to_double()) }, bytes=@utf8.encode(json)))
  self.rename(temp, path) catch {
    e => {
      self.remove(temp) catch { _ => () }
      raise e
    }
  }
}

///|
/// Path::with_extension: the file name's extension replaced (or added).
fn Actors::with_extension(self : Actors, path : String, ext : String) -> String {
  @nodepath.with_extension(self.sep, path, ext)
}

///|
/// A record written in its turn (remote.ts `writeJson`); what the chats' use records keep of it is the new one now.
async fn Actors::write_json(self : Actors, path : String, value : Json) -> Unit raise {
  let json = js_text(value)
  self.remote.writes[path] = self.remote.writes.get(path).unwrap_or(0) + 1
  if self.remote.used.contains(path) {
    self.remote.used[path] = @json.parse(json) catch { _ => Json::null() }
  }
  self.in_turn(path, () => self.write_whole(path, json))
}

///|
/// `session` told `message`, then `value` written as the record at `path`, in one turn of the record's: Node hears
/// of the write (`writing`) before the session is told, so what the telling wakes there waits for it (remote.ts
/// `written`). A telling that fails raises, nothing written; a write that fails after it is let go, as before.
async fn Actors::told_then_written(self : Actors, path : String, session : String, message : String, value : Json) -> Unit raise {
  let json = js_text(value)
  self.in_turn(path, () => {
    ignore(self.rnode("notify", [jstr(session), jstr(message)]))
    self.remote.writes[path] = self.remote.writes.get(path).unwrap_or(0) + 1
    if self.remote.used.contains(path) {
      self.remote.used[path] = @json.parse(json) catch { _ => Json::null() }
    }
    self.write_whole(path, json) catch { _ => () }
  })
}

///|
/// A record read after what was written of it before, changed by `edit` and written in its turn (remote.ts
/// `updateJson`): what `edit` gives is written (None: nothing; Some(Null): the record removed). False when it could not
/// be read; one not there is `missing` where that is given.
async fn Actors::update_json(self : Actors, path : String, edit : (Json) -> Json?, missing? : Json) -> Bool raise {
  self.in_turn(path, () => {
    let v = match self.read_text(path) {
      Some(text) =>
        match (try Some(@json.parse(text)) catch { _ => None }) {
          Some(v) => v
          None => return false
        }
      None =>
        match missing {
          Some(m) => m
          None => return false
        }
    }
    match edit(v) {
      None => true
      Some(Null) => {
        self.remote.writes[path] = self.remote.writes.get(path).unwrap_or(0) + 1
        self.remote.used.remove(path)
        self.remove(path)
        true
      }
      Some(next) => {
        self.remote.writes[path] = self.remote.writes.get(path).unwrap_or(0) + 1
        let json = js_text(next)
        if self.remote.used.contains(path) {
          self.remote.used[path] = next
        }
        self.write_whole(path, json)
        true
      }
    }
  })
}

///|
/// Path::components as a transfer takes them (remote.ts `filePath`): relative as the station's system has it
/// (ops/paths.ts `relativeParts`: on Windows `\` separates too, and a drive, a share or a stream is not relative), no
/// `.` first, no `..`, nothing through a link; its folders made with `create`. `allow_leaf_link`: the last part may be a
/// link itself, for a caller that only replaces or removes it, never reads or writes through it.
async fn Actors::file_path(
  self : Actors,
  root : String,
  relative : String,
  create : Bool,
  allow_leaf_link? : Bool = false,
) -> String raise {
  match self.lstat(root) {
    Some(st) if kind_of_stat(st) == "link" => raise FsError("transfer root is a symbolic link")
    Some(_) => ()
    None => raise FsError("ENOENT: no such file or directory, lstat '\{root}'")
  }
  guard @nodepath.relative_parts(self.sep, relative) is Some(given) else { raise FsError("file path must be relative, without . or ..") }
  let parts : Array[String] = []
  let mut bad = false
  for i, part in given {
    if part == "" {
      continue
    }
    if part == "." {
      if i == 0 {
        bad = true
      }
      continue
    }
    parts.push(part)
  }
  if bad || parts.length() == 0 {
    raise FsError("file path must be relative, without . or ..")
  }
  let mut out = root
  let last = parts.length() - 1
  for i, part in parts {
    out = self.rjoin([out, part])
    if (i < last || !allow_leaf_link) && self.lstat(out) is Some(st) && kind_of_stat(st) == "link" {
      raise FsError("file path contains a symbolic link")
    }
  }
  if create {
    self.mkdirs(self.rdirname(out))
  }
  out
}
