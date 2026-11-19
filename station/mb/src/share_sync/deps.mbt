// What the sharing is given by the station it is part of: the cloud's word on its workspaces and their stations
// (cloud/state.ts `Cloud`), its config (ops/config.ts `ConfigFile`), the files (the shell's `fs.*`), the memory's program
// (memory-mb.ts, here a call of station/mb src/memory itself) and the station's own words (ops/i18n.ts).

///|
/// One of the station's workspaces as the cloud said it last (cloud/state.ts `Membership`): its stations (`peers`, each
/// `{id, name}` as said, nothing of them checked).
pub(all) struct Membership {
  workspace : String
  workspace_name : String
  peers : Array[Json]
}

///|
/// What the cloud says of this station and its workspaces (cloud/state.ts `Cloud`): this station's id and name, whether
/// it only runs tasks (`rig`), whether the rosters are current (`peersCurrent`), its workspaces (the home one first),
/// whether it was taken out (`removed`), and a listener told each time something of it changes.
pub(all) struct Cloud {
  /// Whether it has any state (`cloud.state !== null`).
  has_state : () -> Bool
  station : () -> String?
  name : () -> String?
  rig : () -> Bool
  peers_current : () -> Bool
  memberships : () -> Array[Membership]
  membership : (String) -> Membership?
  home : () -> String?
  removed : () -> Bool
  listen : (() -> Unit) -> () -> Unit
}

///|
/// The station's config.json (ops/config.ts `ConfigFile`): as it is now (`raw`, never changed in place), an edit taken
/// at once and written behind it (`update_soon`: made on a copy, which is then the config), and a listener told of each.
pub(all) struct Config {
  raw : () -> Json
  update_soon : async ((Json) -> Unit raise) -> Json
  listen : (() -> Unit) -> () -> Unit
}

// ── the files, through the shell ──

///|
/// The station's files as the shell reads and writes them (`fs.*`), its paths joined with `sep`.
pub(all) struct Files {
  host : @host.Host
  sep : String
}

///|
async fn Files::op(self : Files, op : String, args : Array[(String, Json)], bytes? : Bytes) -> Json {
  let (json, _) = match bytes {
    Some(b) => self.host.shell(op, jobj(args), bytes=b)
    None => self.host.shell(op, jobj(args))
  }
  json
}

///|
/// `path.join` of the parts (Node's, on this machine's separator).
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
/// What lstat says of a path (links not followed).
pub struct Stat {
  kind : String
  size : Double
  mode : Int
  ino : Json
  mtime : Double
}

///|
pub async fn Files::lstat(self : Files, path : String) -> Stat? {
  let v = self.op("fs.lstat", [("path", jstr(path))]) catch { _ => return None }
  guard v is Object(m) && m.get("kind") is Some(String(kind)) else { return None }
  let num = (k : String) => match m.get(k) {
    Some(Number(d, ..)) => d
    _ => 0.0
  }
  Some({ kind, size: num("size"), mode: num("mode").to_int(), ino: m.get("ino").unwrap_or(Json::null()), mtime: num("mtimeMs") })
}

///|
/// What is at a path, a link followed (`stat`): "file", "dir", "other"; None where nothing is (or a link to nothing).
pub async fn Files::stat_kind(self : Files, path : String) -> String? {
  let v = self.op("fs.stat", [("path", jstr(path))]) catch { _ => return None }
  match v {
    String(k) => Some(k)
    _ => None
  }
}

///|
/// Whether something is at a path, a link followed (`stat(path).then(() => true, () => false)`).
pub async fn Files::exists(self : Files, path : String) -> Bool {
  self.stat_kind(path) is Some(_)
}

///|
/// A directory's names (`readdir`), in Node's order; None where it does not read.
pub async fn Files::readdir(self : Files, path : String) -> Array[String]? {
  let v = self.op("fs.readdir", [("path", jstr(path))]) catch { _ => return None }
  match v {
    Array(xs) => Some(xs.filter_map(x => if x is String(s) { Some(s) } else { None }))
    _ => None
  }
}

///|
/// A directory's names and kinds ("file", "dir", "link", "other"), as `readdir(…, {withFileTypes: true})`.
pub async fn Files::readdir_types(self : Files, path : String) -> Array[(String, String)]? {
  let v = self.op("fs.readdir", [("path", jstr(path)), ("types", jbool(true))]) catch { _ => return None }
  match v {
    Array(xs) => {
      let out = []
      for x in xs {
        if x is Array(p) && p.get(0) is Some(String(name)) && p.get(1) is Some(String(kind)) {
          out.push((name, kind))
        }
      }
      Some(out)
    }
    _ => None
  }
}

///|
pub async fn Files::readlink(self : Files, path : String) -> String? {
  let v = self.op("fs.readlink", [("path", jstr(path))]) catch { _ => return None }
  match v {
    String(s) => Some(s)
    _ => None
  }
}

///|
/// A file's text (`readFile(path, "utf8")`: what is not UTF-8 replaced, a byte order mark kept); None where it does not
/// open.
pub async fn Files::read_text(self : Files, path : String) -> String? {
  let v = self.op("fs.read", [("path", jstr(path))]) catch { _ => return None }
  match v {
    String(s) => Some(s)
    _ => None
  }
}

///|
/// A file's bytes; None where it does not open.
pub async fn Files::read_bytes(self : Files, path : String) -> Bytes? {
  let v = self.op("fs.bytes", [("path", jstr(path))]) catch { _ => return None }
  match v {
    String(hex) => Some(@hex.decode(hex)) catch { _ => None }
    _ => None
  }
}

///|
/// A file's text, failing as `readFile` fails where it does not open.
pub async fn Files::need_text(self : Files, path : String) -> String {
  match self.read_text(path) {
    Some(t) => t
    None => raise Failed("ENOENT: no such file or directory, open '\{path}'")
  }
}

///|
/// A folder and those it is in made (`mkdir(…, {recursive: true})`).
pub async fn Files::mkdir(self : Files, path : String) -> Unit {
  ignore(self.op("fs.mkdir", [("path", jstr(path))]))
}

///|
/// What is at a path let go (`rm(…, {force: true})`, `recursive` with all it holds; a directory not empty is refused
/// without, as `rmdir`).
pub async fn Files::remove(self : Files, path : String, recursive? : Bool = false) -> Unit {
  ignore(self.op("fs.remove", [("path", jstr(path)), ("recursive", jbool(recursive))]))
}

///|
pub async fn Files::rename(self : Files, from : String, to : String) -> Unit {
  ignore(self.op("fs.rename", [("from", jstr(from)), ("to", jstr(to))]))
}

///|
pub async fn Files::copy(self : Files, from : String, to : String) -> Unit {
  ignore(self.op("fs.copy", [("from", jstr(from)), ("to", jstr(to))]))
}

///|
pub async fn Files::chmod(self : Files, path : String, mode : Int) -> Unit {
  ignore(self.op("fs.chmod", [("path", jstr(path)), ("mode", jnum(mode.to_double()))]))
}

///|
/// A symbolic link at `path` naming `target`.
pub async fn Files::symlink(self : Files, target : String, path : String) -> Unit {
  ignore(self.op("fs.symlink", [("target", jstr(target)), ("path", jstr(path))]))
}

///|
/// `bytes` written to `path` whole, made with `mode` where it is not there (`writeFile(path, bytes, {mode})`).
pub async fn Files::write(self : Files, path : String, bytes : Bytes, mode : Int) -> Unit {
  ignore(
    self.op(
      "fs.put",
      [("path", jstr(path)), ("offset", jnum(0.0)), ("truncate", jbool(true)), ("mode", jnum(mode.to_double()))],
      bytes~,
    ),
  )
}

///|
/// The station's private write (ops/files.ts `writePrivateSoon`): its folder made, written beside it (0o600) under a
/// name of its own, synced and renamed into place (`@host.Host::write_private`: fibers writing one file at once each
/// rename their own, L13).
pub async fn Files::write_private(self : Files, path : String, bytes : Bytes) -> Unit {
  self.host.write_private(path, bytes, sep=self.sep)
}

///|
pub async fn Files::write_private_text(self : Files, path : String, text : String) -> Unit {
  self.write_private(path, @utf8.encode(text))
}

///|
/// The decimal digits of a whole number the shell said (an inode, a device), as exactly as it said them.
fn int_text(v : Json?) -> String {
  match v {
    Some(Number(_, repr=Some(r))) => r
    Some(Number(d, ..)) => js_number(d)
    _ => "0"
  }
}

///|
/// A directory's device and inode (`dev:ino`), which a rename keeps; None: no directory of its own there (index.ts
/// `dirKey`).
pub async fn Files::dir_key(self : Files, dir : String) -> String? {
  let scanned = self.op("fs.scan", [("paths", jarr([jstr(dir)]))]) catch { _ => return None }
  guard scanned is Array([Object(s), ..]) && s.get("kind") is Some(String("dir")) else { return None }
  guard self.lstat(dir) is Some(st) && st.kind == "dir" else { return None }
  Some("\{int_text(s.get("dev"))}:\{int_text(Some(st.ino))}")
}

///|
/// A private file the station keeps in memory and writes through (ops/files.ts `PrivateFile`): what is asked while a
/// write is on its way is written after it, the latest only.
pub struct PrivateFile {
  files : Files
  path : String
  tasks : Tasks
  priv mut latest : String?
  priv mut writing : @effect.Deferred[Unit]?
}

///|
pub fn PrivateFile::new(files : Files, path : String, tasks : Tasks) -> PrivateFile {
  { files, path, tasks, latest: None, writing: None }
}

///|
/// `text` to be written (the latest asked is what the file comes to); what it gives is waited by `written`.
pub fn PrivateFile::write(self : PrivateFile, text : String) -> Unit {
  self.latest = Some(text)
  if self.writing is Some(_) {
    return
  }
  let done : @effect.Deferred[Unit] = @effect.Deferred::new()
  self.writing = Some(done)
  self.tasks.spawn(async fn() {
    defer {
      self.writing = None
      ignore(done.succeed(()))
    }
    while self.latest is Some(t) {
      self.latest = None
      self.files.write_private_text(self.path, t)
    }
  })
}

///|
/// Once what was asked is written (or failed).
pub async fn PrivateFile::written(self : PrivateFile) -> Unit {
  if self.writing is Some(d) {
    d.wait() catch {
      _ => ()
    }
  }
}

// ── the memory's program ──

///|
/// The memory's program (memory-mb.ts `MemoryProgram`): what station/mb src/memory answers an ask, here in the same
/// program, one ask at a time as the program of its own took its lines; none once it is closed.
pub struct MemoryProgram {
  host : @host.Host
  sep : String
  turn : Turn
  mut closed : Bool
  /// How many asks it answered (tests).
  mut asked : Int
}

///|
pub fn MemoryProgram::new(host : @host.Host, sep : String) -> MemoryProgram {
  { host, sep, turn: Turn::new(), closed: false, asked: 0 }
}

///|
/// What the program answers `op` with `args` (mb/src/memory answer.mbt); its error raised.
pub async fn MemoryProgram::ask(self : MemoryProgram, op : String, args : Array[(String, Json)]) -> Json {
  if self.closed {
    raise Stopped("station stopping")
  }
  self.turn.run(async fn() {
    if self.closed {
      raise Stopped("station stopping")
    }
    let m : Map[String, Json] = Map([])
    for p in args {
      m[p.0] = p.1
    }
    m["op"] = jstr(op)
    self.asked += 1
    let answer = @memory.answer(self.host, Json::object(m), self.sep) catch {
      e => raise Failed(error_words(e))
    }
    match answer {
      Object(o) =>
        match o.get("error") {
          Some(String(e)) => raise Failed(e)
          _ => answer
        }
      _ => answer
    }
  })
}

///|
/// Let go at once if nothing is asked of it (memory-mb.ts `trimIdle`): it keeps no process of its own here, so none.
pub fn MemoryProgram::trim_idle(_self : MemoryProgram) -> Int {
  0
}

///|
/// Its end: an ask made from now on fails (what it wrote stays).
pub async fn MemoryProgram::close(self : MemoryProgram) -> Unit {
  self.closed = true
  self.turn.settled()
}

// ── the station's words ──

///|
/// What the station says of sharing, in its two languages (client/i18n/catalog station.json's `station.share.*`).
fn words(lang : String, key : String) -> String {
  let zh = lang != "en"
  match key {
    "station.share.moveUnknown" =>
      if zh {
        "这台 station 没有这个账号；刷新页面，再选它列出的账号"
      } else {
        "This station has no such account; refresh the page and pick one it lists"
      }
    "station.share.moveMachine" =>
      if zh {
        "这是这台机器自己的登录，只能留在这台机器上；请在另一台 station 上自己登录"
      } else {
        "This account is the machine's own login: it stays on its machine. Sign in to it on the other station instead"
      }
    "station.share.moveBorrowed" =>
      if zh {
        "这个账号是从另一台 station 共享来的，请到持有它的那台 station 上迁移"
      } else {
        "This account is shared from another station: move it from the station that has it"
      }
    "station.share.moveWhere" =>
      if zh {
        "那台 station 不是这个账号所服务的 workspace 里的完整 station；请换一台，或先让这个账号服务那个 workspace"
      } else {
        "That station is not a whole station of a workspace this account serves: pick another, or let the account serve that workspace first"
      }
    "station.share.moveHome" =>
      if zh {
        "这个账号在这里只服务 workspace {workspaces}，而那台 station 的主 workspace 不在其中，迁过去就会服务它原本不服务的聊天。请迁到主 workspace 是它所服务的 station，或先在这里让它服务那个 workspace"
      } else {
        "This account serves only the workspaces {workspaces} here, and that station's home workspace is not one of them, so it would serve chats it never served. Move it to a station whose home workspace it serves, or let it serve that workspace here first"
      }
    "station.share.moving" =>
      if zh {
        "这个账号正在迁移，请稍等再看"
      } else {
        "This account is being moved already; wait a moment and look again"
      }
    "station.share.moveNotTaken" =>
      if zh {
        "另一台 station 没有接收这个账号，账号仍留在这里；等那台 station 更新后再试"
      } else {
        "The other station did not take the account; it stays here. Try again once that station is up to date"
      }
    "station.share.notLent" =>
      if zh {
        "登录此订阅的 station 未能借出它，可能已离线"
      } else {
        "The station this subscription is signed in on couldn't lend it; it may be offline"
      }
    "station.share.stationsUnknown" =>
      if zh {
        "这台 station 还没收到它所在的各个 workspace 里都有哪些 station，过一会儿再改"
      } else {
        "This station hasn't heard yet which stations its workspaces have; try again in a moment"
      }
    other => other
  }
}

///|
/// `tr(lang, key, {name: value})`: the words with each `{name}` given filled in.
pub fn tr(lang : String, key : String, args? : Array[(String, String)] = []) -> String {
  let mut text = words(lang, key)
  for a in args {
    text = text.replace_all(old="{\{a.0}}", new=a.1)
  }
  text
}
