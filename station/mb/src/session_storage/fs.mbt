// The machine's files as node:fs/promises reaches them, asked of the shell (client/shell `fs.*`): what each says when
// a path is not there (null), and its failures as the system said them, by their codes (`ENOENT`, `EEXIST`, ...).

///|
/// The shell's file calls and the program that packs (station/packed) in one: what the modules here do their IO by.
pub struct Files {
  host : @host.Host
  /// The locks held in this process, by path: who waits for each next.
  held : Map[String, Array[@effect.Deferred[Unit]]]
  /// The path separator (`/`, or `\` on Windows).
  sep : String
  /// Where the packing is asked (an ask `{op, …}` answered as `@packed.answer` would, its refusal raised): a process
  /// of its own where the station runs it (sessions/packed-mb.ts), so none of the bytes are on the station's thread;
  /// None, this program's own `@packed.answer` (a harness, a builder).
  priv packed_by : (async (Json) -> Json)?
  /// Where a directory's size is measured (`@footprint.answer`'s ask, answered as it answers): a backgrounded process
  /// of its own where the station runs it (sessions/footprint.ts); None, this program's own.
  priv footprint_by : (async (String) -> Json)?
}

///|
/// `packed` and `footprint`: what asks the packing and a directory's measure of another process (a station's, which
/// must not walk or pack on its own thread); left out, this program does both itself.
pub fn Files::new(
  host : @host.Host,
  sep? : String = "/",
  packed? : async (Json) -> Json,
  footprint? : async (String) -> Json,
) -> Files {
  { host, held: {}, sep, packed_by: packed, footprint_by: footprint }
}

///|
async fn Files::sh(self : Files, op : String, args : Json, bytes? : Bytes) -> Json {
  let (v, _) = match bytes {
    Some(b) => self.host.shell(op, args, bytes=b)
    None => self.host.shell(op, args)
  }
  v
}

///|
/// A system failure's code, from the words the shell said it in (Rust's io::Error: `... (os error N)`).
pub fn code_of(e : Error) -> String {
  let m = message_of(e)
  if m.has_prefix("E") && m.find(":") is Some(at) && at < 12 {
    return cut(m, 0, end=at)
  }
  let n = match m.rev_find("(os error ") {
    Some(at) => {
      let rest = cut(m, at + 10)
      digits_of(cut(rest, 0, end=rest.find(")").unwrap_or(rest.length())))
    }
    None => -1
  }
  match n {
    1 => "EPERM"
    2 => "ENOENT"
    5 if m.contains("Access is denied") => "EACCES"
    13 => "EACCES"
    16 | 32 | 33 => "EBUSY"
    17 => "EEXIST"
    20 => "ENOTDIR"
    21 => "EISDIR"
    39 | 66 => "ENOTEMPTY"
    _ =>
      if m.contains("No such file") {
        "ENOENT"
      } else if m.contains("Access is denied") || m.contains("Permission denied") {
        "EACCES"
      } else if m.contains("Operation not permitted") {
        "EPERM"
      } else if m.contains("resource busy") ||
        m.contains("Resource busy") ||
        m.contains("being used by another process") ||
        m.contains("locked a portion") {
        "EBUSY"
      } else {
        "EIO"
      }
  }
}

///|
/// A failure as node:fs says it: `CODE: words, op 'path'`.
fn fs_failed(code : String, op : String, path : String) -> Thrown {
  let words = match code {
    "ENOENT" => "no such file or directory"
    "EEXIST" => "file already exists"
    "ENOTEMPTY" => "directory not empty"
    "EACCES" => "permission denied"
    _ => "failed"
  }
  Thrown("Error", jo([("message", js("\{code}: \{words}, \{op} '\{path}'")), ("code", js(code))]))
}

///|
/// `stat(path)` (links followed): "file", "dir", "other"; None where nothing is (or it cannot be).
pub async fn Files::kind(self : Files, path : String) -> String? {
  as_str(Some(self.sh("fs.stat", jo([("path", js(path))]))))
}

///|
/// `lstat(path)`: "file", "dir", "link", "other"; None where nothing is.
pub async fn Files::lkind(self : Files, path : String) -> String? {
  as_str(Some(self.sh("fs.stat", jo([("path", js(path)), ("lstat", jb(true))]))))
}

///|
/// What lstat says: kind, size, mode, ino, mtimeMs.
pub struct LStat {
  kind : String
  size : Double
  mode : Int
  ino : Double
  mtime_ms : Double
}

///|
pub async fn Files::lstat(self : Files, path : String) -> LStat? {
  let v = self.sh("fs.lstat", jo([("path", js(path))]))
  if v is Null {
    return None
  }
  Some({
    kind: str(v, "kind").unwrap_or("other"),
    size: num(v, "size").unwrap_or(0.0),
    mode: num(v, "mode").unwrap_or(0.0).to_int(),
    ino: num(v, "ino").unwrap_or(0.0),
    mtime_ms: num(v, "mtimeMs").unwrap_or(0.0),
  })
}

///|
/// What stat says (links followed): its kind, size, mode, ino and dev, mtimeMs.
pub struct Stat {
  kind : String
  size : Double
  mode : Int
  ino : Double
  dev : Double
  mtime_ms : Double
}

///|
pub async fn Files::stat(self : Files, path : String) -> Stat? {
  guard self.realpath(path) is Some(real) else { return None }
  guard self.lstat(real) is Some(l) else { return None }
  let scan = items(Some(self.sh("fs.scan", jo([("paths", ja([js(real)]))]))))
  let dev = match scan.get(0) {
    Some(s) => num(s, "dev").unwrap_or(0.0)
    None => 0.0
  }
  Some({ kind: l.kind, size: l.size, mode: l.mode, ino: l.ino, dev, mtime_ms: l.mtime_ms })
}

///|
/// `access(path)` / `stat(path)` succeeding.
pub async fn Files::there(self : Files, path : String) -> Bool {
  self.kind(path) is Some(_)
}

///|
pub async fn Files::is_dir(self : Files, path : String) -> Bool {
  self.kind(path) is Some("dir")
}

///|
/// `readdir(path)`, in its order; None where it cannot be read.
pub async fn Files::readdir(self : Files, path : String) -> Array[String]? {
  match self.sh("fs.readdir", jo([("path", js(path))])) {
    Array(xs) => Some(xs.filter_map(x => if x is String(s) { Some(s) } else { None }))
    _ => None
  }
}

///|
/// `readdir(path).catch(() => [])`.
pub async fn Files::entries(self : Files, path : String) -> Array[String] {
  self.readdir(path).unwrap_or([])
}

///|
/// `readdir(path)`, raising as it does.
pub async fn Files::readdir_strict(self : Files, path : String) -> Array[String] {
  match self.readdir(path) {
    Some(xs) => xs
    None => raise fs_failed(if self.there(path) { "ENOTDIR" } else { "ENOENT" }, "scandir", path)
  }
}

///|
/// `readdir(path, {withFileTypes})`: each name with "file", "dir", "link" or "other".
pub async fn Files::readdir_types(self : Files, path : String) -> Array[(String, String)] {
  match self.sh("fs.readdir", jo([("path", js(path)), ("types", jb(true))])) {
    Array(xs) =>
      xs.filter_map(x => match x {
        Array([String(n), String(k)]) => Some((n, k))
        _ => None
      })
    _ => raise fs_failed("ENOENT", "scandir", path)
  }
}

///|
/// `readFile(path, "utf8")`; None where it does not read.
pub async fn Files::read_text(self : Files, path : String) -> String? {
  as_str(Some(self.sh("fs.read", jo([("path", js(path))]))))
}

///|
/// `readFile(path)`; None where it does not read.
pub async fn Files::read_bytes(self : Files, path : String) -> Bytes? {
  match self.sh("fs.bytes", jo([("path", js(path))])) {
    String(h) => Some(@hex.decode(h)) catch { _ => None }
    _ => None
  }
}

///|
/// Bytes of the file at `path` from `from`, `length` of them at most.
pub async fn Files::read_range(self : Files, path : String, from : Double, length : Double) -> Bytes {
  match self.sh("fs.bytes", jo([("path", js(path)), ("from", jn(from)), ("length", jn(length))])) {
    String(h) => @hex.decode(h)
    _ => raise fs_failed("ENOENT", "open", path)
  }
}

///|
/// `writeFile(path, bytes)` (`exclusive`: flag "wx"), its mode where it is made.
pub async fn Files::write(self : Files, path : String, bytes : Bytes, mode? : Int = 0o666, exclusive? : Bool = false, sync? : Bool = false) -> Unit {
  ignore(
    self.sh(
      "fs.put",
      jo([
        ("path", js(path)),
        ("offset", ji(0)),
        ("truncate", jb(true)),
        ("exclusive", jb(exclusive)),
        ("mode", ji(mode)),
        ("sync", jb(sync)),
      ]),
      bytes~,
    ),
  )
}

///|
pub async fn Files::write_text(self : Files, path : String, text : String, mode? : Int = 0o666, exclusive? : Bool = false, sync? : Bool = false) -> Unit {
  self.write(path, @utf8.encode(text), mode~, exclusive~, sync~)
}

///|
/// `bytes` written at `offset` into the file at `path`, made where it is not.
pub async fn Files::put_at(self : Files, path : String, bytes : Bytes, offset : Double, mode? : Int = 0o644) -> Double {
  let v = self.sh("fs.put", jo([("path", js(path)), ("offset", jn(offset)), ("mode", ji(mode)), ("nofollow", jb(true))]), bytes~)
  num(v, "size").unwrap_or(0.0)
}

///|
/// `(await open(path, "a", mode)).close()`: made where it is not, never cut.
pub async fn Files::touch(self : Files, path : String, mode? : Int = 0o600) -> Unit {
  ignore(self.sh("fs.put", jo([("path", js(path)), ("mode", ji(mode))]), bytes=b""))
}

///|
/// `mkdir(path, {recursive: true})`.
pub async fn Files::mkdirs(self : Files, path : String) -> Unit {
  ignore(self.sh("fs.mkdir", jo([("path", js(path))])))
}

///|
/// `mkdir(path)`: refused where something is.
pub async fn Files::mkdir(self : Files, path : String) -> Unit {
  if self.lkind(path) is Some(_) {
    raise fs_failed("EEXIST", "mkdir", path)
  }
  self.mkdirs(path)
}

///|
pub async fn Files::rename(self : Files, from : String, to : String) -> Unit {
  ignore(self.sh("fs.rename", jo([("from", js(from)), ("to", js(to))])))
}

///|
/// How long a rename waits, attempt by attempt, for a Windows transient file or directory lock (`rename_retrying`).
let rename_backoff : Array[Int] = [20, 40, 80, 160]

///|
/// How long moving a whole workspace directory aside waits for a lock to clear (1.55 s in all): on Windows an agent's
/// process just stopped (`evict`), a scanner or the indexer keeps a handle in it a moment after.
let workspace_rename_backoff : Array[Int] = [50, 100, 200, 400, 800]

///|
/// Renames `from` to `to`, waiting briefly on Windows transient file or directory locks (`EPERM`, `EBUSY`, `EACCES`).
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
        let code = code_of(e)
        if attempt >= backoff.length() || (code != "EPERM" && code != "EBUSY" && code != "EACCES") {
          raise e
        }
        wait(backoff[attempt])
      }
    }
  }
}

///|
/// `rename`, waiting out Windows transient file or directory locks (`EPERM`, `EBUSY`, `EACCES`).
async fn Files::rename_retrying(
  self : Files,
  from : String,
  to : String,
  backoff? : Array[Int] = rename_backoff,
) -> Unit {
  rename_retrying_by(async fn(a, b) { self.rename(a, b) }, from, to, backoff~)
}

///|
pub async fn Files::copy(self : Files, from : String, to : String) -> Unit {
  ignore(self.sh("fs.copy", jo([("from", js(from)), ("to", js(to))])))
}

///|
pub async fn Files::chmod(self : Files, path : String, mode : Int) -> Unit {
  ignore(self.sh("fs.chmod", jo([("path", js(path)), ("mode", ji(mode))])))
}

///|
/// `rm(path, {recursive, force})`.
pub async fn Files::rm(self : Files, path : String, recursive? : Bool = false, force? : Bool = false) -> Unit {
  if !force && self.lkind(path) is None {
    raise fs_failed("ENOENT", "lstat", path)
  }
  ignore(self.sh("fs.remove", jo([("path", js(path)), ("recursive", jb(recursive))])))
}

///|
/// `unlink(path)`.
pub async fn Files::unlink(self : Files, path : String) -> Unit {
  match self.lkind(path) {
    None => raise fs_failed("ENOENT", "unlink", path)
    Some("dir") => raise fs_failed("EISDIR", "unlink", path)
    _ => ignore(self.sh("fs.remove", jo([("path", js(path))])))
  }
}

///|
pub async fn Files::symlink(self : Files, target : String, path : String) -> Unit {
  if self.lkind(path) is Some(_) {
    raise fs_failed("EEXIST", "symlink", "\{target}' -> '\{path}")
  }
  ignore(self.sh("fs.symlink", jo([("target", js(target)), ("path", js(path))])))
}

///|
/// A hard link `to` of `from` (`link(from, to)`).
pub async fn Files::hard_link(self : Files, from : String, to : String) -> Unit {
  if self.sh("fs.link", jo([("from", js(from)), ("to", js(to))])) is False {
    raise fs_failed("EEXIST", "link", "\{from}' -> '\{to}")
  }
}

///|
pub async fn Files::readlink(self : Files, path : String) -> String? {
  as_str(Some(self.sh("fs.readlink", jo([("path", js(path))]))))
}

///|
/// `realpath(path)`; None where a part is not there.
pub async fn Files::realpath(self : Files, path : String) -> String? {
  as_str(Some(self.sh("fs.realpath", jo([("path", js(path))]))))
}

///|
/// `realpath(path).catch(() => path)`.
pub async fn Files::canonical(self : Files, path : String) -> String {
  self.realpath(path).unwrap_or(path)
}

///|
/// `path` linked to `target` (ops/links.ts `link`): a link where the machine makes one; what stands in (a junction, a
/// copy) is Windows', where a link may be refused, and this program's shell makes every link it is asked (`fs.symlink`).
pub async fn Files::link(self : Files, target : String, path : String) -> String {
  self.symlink(target, path)
  "link"
}

///|
/// What `packedProgram().ask(op, args)` answers: station/packed's, in this program.
pub async fn Files::packed(self : Files, op : String, args : Array[(String, Json)]) -> Json {
  args.push(("op", js(op)))
  match self.packed_by {
    Some(ask) => ask(jo(args))
    None => @packed.answer(self.host, jo(args))
  }
}

///|
/// A lock file's lock (archive.ts `fileLock`): the file made (0600, never cut) and the lock taken in turn with whoever
/// else in this program asked for it; what is returned lets it go. (Across processes the station's native flock holds
/// it; this program is the only one working on a data directory it is given.)
pub async fn Files::file_lock(self : Files, path : String) -> () -> Unit {
  match self.held.get(path) {
    Some(queue) => {
      let mine = @effect.Deferred::new()
      queue.push(mine)
      mine.wait()
    }
    None => self.held[path] = []
  }
  let release = () => match self.held.get(path) {
    Some(queue) if queue.length() > 0 => ignore(queue.remove(0).succeed(()))
    _ => self.held.remove(path)
  }
  self.touch(path) catch {
    e => {
      release()
      raise e
    }
  }
  release
}

///|
pub fn Files::join(self : Files, parts : Array[String]) -> String {
  @nodepath.join(self.sep, parts)
}

///|
pub fn Files::dirname(self : Files, path : String) -> String {
  @nodepath.dirname(self.sep, path)
}

///|
pub fn Files::basename(self : Files, path : String) -> String {
  @nodepath.basename(self.sep, path)
}

///|
/// `try { body } finally { after }`.
async fn[T] ensure(body : async () -> T, after : async () -> Unit) -> T {
  let r = body() catch {
    e => {
      after()
      raise e
    }
  }
  after()
  r
}

///|
/// `rm(path, {force: true})`, its failure let go.
async fn Files::gone(self : Files, path : String) -> Unit {
  self.rm(path, force=true) catch {
    _ => ()
  }
}
