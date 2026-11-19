// A station's drive (drive.ts): its machine's files, which members browse and change over their link: list a folder,
// read a part of a file, write one in parts, make a folder, rename, remove. A member who may write reaches every folder
// (`anywhere`): any absolute path is a root to ask from. The folders pinned in config.json (`drive.roots`) are the list
// everyone sees first, and all a read-only member reaches. Every path is asked relative to a root and stays in it: `..`
// is refused rather than worked out, and, for a read-only member, the path as the file system has it (its links
// followed) must still be under the pinned root. The station's own data is never reachable: a listing leaves it out.
//
// On macOS the folders its privacy protection keeps from a station launchd runs (Documents, Desktop, Downloads, disks)
// are reached through still.fail Helper (`DriveDeps.files`): the same checks here first, then the helper's operations
// instead of the file system's. The station never touches them itself while the helper is there.

///|
/// For `permission` (drive.ts DriveError `need`): the grant still.fail Helper lacks, the folder, its window's state.
pub(all) struct Need {
  grant : String
  top : String
  mut window : String
} derive(Show)

///|
/// drive.ts `DriveError`: zdrive's code (`CODES`), its words, how much of an upload the station has (`upload_lost`),
/// the path it is about when not the one asked, what still.fail Helper needs.
pub(all) struct DriveFailure {
  code : String
  message : String
  have : Double?
  mut about : String?
  mut need : Need?
} derive(Show)

///|
pub(all) suberror DriveError {
  DriveError(DriveFailure)
}

///|
pub impl Show for DriveError with output(self, logger) {
  let DriveError(f) = self
  logger.write_string(f.message)
}

///|
pub fn drive_error(code : String, message : String, have? : Double) -> DriveError {
  DriveError({ code, message, have, about: None, need: None })
}

///|
/// drive.ts `CODES`: each code's status.
pub fn code_status(code : String) -> Int {
  match code {
    "invalid_request" => 400
    "not_a_root" | "not_found" => 404
    "path_escape" | "protected" | "permission" => 403
    "is_a_directory"
    | "not_a_directory"
    | "exists"
    | "upload_lost"
    | "no_trash" => 409
    "too_large" => 413
    _ => 500
  }
}

///|
/// A folder's entry as a listing gives it (drive.ts `Entry`).
pub(all) struct Entry {
  name : String
  dir : Bool
  size : Double
  mtime : Double
  type_ : String
} derive(Show, Eq)

///|
pub fn Entry::to_json(self : Entry) -> Json {
  {
    "name": j(self.name),
    "dir": j(self.dir),
    "size": j(self.size),
    "mtime": j(self.mtime),
    "type": j(self.type_),
  }
}

///|
/// A root as the settings and the drive's page show it (drive.ts `RootView`).
pub(all) struct RootView {
  path : String
  name : String
  state : String
} derive(Show, Eq)

///|
pub fn RootView::to_json(self : RootView) -> Json {
  { "path": j(self.path), "name": j(self.name), "state": j(self.state) }
}

///|
pub let too_big : String = "too big to send"

///|
pub let most_roots : Int = 32

///|
let most_entries : Int = 50000

///|
pub let max_read : Double = 8388608.0

///|
let stale_ms : Double = 86400000.0

///|
let zips_kept_ms : Double = 3600000.0

///|
/// drive.ts PART: an upload's file beside where it goes, until it is whole.
pub fn is_part(name : String) -> Bool {
  let pre = ".stillfail-up-"
  let suf = ".part"
  if !name.has_prefix(pre) || !name.has_suffix(suf) {
    return false
  }
  let id = name.unsafe_substring(start=pre.length(), end=name.length() - suf.length())
  is_id(id)
}

///|
/// 1 to 64 letters, digits, `-` or `_`.
pub fn is_id(id : String) -> Bool {
  if id.length() < 1 || id.length() > 64 {
    return false
  }
  for c in id {
    let ok = (c >= 'a' && c <= 'z') ||
      (c >= 'A' && c <= 'Z') ||
      (c >= '0' && c <= '9') ||
      c == '-' ||
      c == '_'
    if !ok {
      return false
    }
  }
  true
}

///|
/// Number.isSafeInteger.
pub fn safe_integer(x : Double) -> Bool {
  x == x.floor() && x.abs() <= 9007199254740991.0
}

///|
/// Math.round.
pub fn js_round(x : Double) -> Double {
  (x + 0.5).floor()
}

// ── the machine's paths (platform.paths, POSIX) ────────────────────────────────────────────────────────────────

///|
/// drive.ts `rootsOf`: the roots config.json names (`drive.roots`, or `drive.workspaces[<id>]`).
pub fn roots_of(raw : Json, workspace? : String) -> Array[String] {
  let drive = match raw {
    Object(o) => o.get("drive")
    _ => None
  }
  let roots = match (drive, workspace) {
    (Some(Object(d)), None) => d.get("roots")
    (Some(Object(d)), Some(ws)) =>
      match d.get("workspaces") {
        Some(Object(w)) => w.get(ws)
        _ => None
      }
    _ => None
  }
  match roots {
    Some(Array(a)) => {
      let out = []
      for r in a {
        if r is String(s) && rooted(s) {
          out.push(clean(s))
        }
      }
      out
    }
    _ => []
  }
}

///|
/// drive.ts `rootName`: a root's last component, or the path itself when it has none.
pub fn root_name(path : String) -> String {
  let b = basename(path)
  if b == "" {
    path
  } else {
    b
  }
}

///|
/// drive.ts `rootView`.
pub fn root_view(path : String) -> RootView {
  let name = root_name(path)
  match attempt(() => stat(path)) {
    Ok(s) =>
      if !s.dir {
        return { path, name, state: "not_a_directory" }
      }
    Err(FsError({ code: "EPERM" | "EACCES", .. })) =>
      return { path, name, state: "unreadable" }
    Err(_) => return { path, name, state: "missing" }
  }
  { path, name, state: if unreadable_dir(path) { "unreadable" } else { "ok" } }
}

///|
/// Whether still.fail Helper may open the protected folder `top`, as last known (looked at when not known yet).
fn granted(files : Protected, top : String) -> Bool {
  let known = (files.known)(top)
  if known is None {
    (files.check)([top])
  }
  match known {
    Some((_, "granted")) => true
    _ => false
  }
}

///|
/// drive.ts `rootViewThrough`.
pub fn root_view_through(
  path : String,
  files : Protected?,
  home : String,
  mounts : Array[String],
) -> RootView {
  let top = match files {
    Some(_) => protected_top_soon(path, home, mounts)
    None => None
  }
  match (top, files) {
    (Some(t), Some(f)) =>
      {
        path,
        name: root_name(path),
        state: if granted(f, t) { "ok" } else { "unreadable" },
      }
    _ => root_view(path)
  }
}

///|
/// drive.ts `dropFolder`: the machine's Downloads, the home where it has none.
pub fn drop_folder(home : String) -> String {
  let downloads = join([home, "Downloads"])
  match attempt(() => stat(downloads)) {
    Ok(s) => if s.dir { downloads } else { home }
    Err(_) => home
  }
}

///|
/// drive.ts `droppedInto`: `drop_folder` for who asks it on the spot, as last found, looked at again at each ask for the
/// next.
pub fn dropped_into(home : String) -> () -> String {
  let kept : Ref[String] = { val: drop_folder(home) }
  fn() {
    let was = kept.val
    kept.val = drop_folder(home)
    was
  }
}

///|
let types : Map[String, String] = {
  "png": "image/png",
  "jpg": "image/jpeg",
  "jpeg": "image/jpeg",
  "gif": "image/gif",
  "webp": "image/webp",
  "svg": "image/svg+xml",
  "heic": "image/heic",
  "bmp": "image/bmp",
  "mp4": "video/mp4",
  "m4v": "video/mp4",
  "mov": "video/quicktime",
  "webm": "video/webm",
  "ogv": "video/ogg",
  "3gp": "video/3gpp",
  "3g2": "video/3gpp2",
  "mkv": "video/x-matroska",
  "avi": "video/x-msvideo",
  "ts": "video/mp2t",
  "mp3": "audio/mpeg",
  "m4a": "audio/mp4",
  "aac": "audio/aac",
  "flac": "audio/flac",
  "wav": "audio/wav",
  "ogg": "audio/ogg",
  "opus": "audio/opus",
  "pdf": "application/pdf",
  "zip": "application/zip",
  "txt": "text/plain; charset=utf-8",
  "md": "text/markdown; charset=utf-8",
  "markdown": "text/markdown; charset=utf-8",
  "log": "text/plain; charset=utf-8",
  "csv": "text/csv; charset=utf-8",
  "json": "application/json",
  "html": "text/html; charset=utf-8",
  "htm": "text/html; charset=utf-8",
  "srt": "application/x-subrip",
  "vtt": "text/vtt",
  "ass": "text/x-ssa",
  "ssa": "text/x-ssa",
}

///|
/// drive.ts `typeOf`: a file's type by its name.
pub fn type_of(name : String) -> String {
  let ext = match name.rev_find(".") {
    Some(dot) if dot > 0 =>
      name.unsafe_substring(start=dot + 1, end=name.length()).to_lower()
    _ => ""
  }
  types.get(ext).unwrap_or("application/octet-stream")
}

///|
/// What a refusal is as the drive says it (drive.ts `failed`).
pub fn failed(e : Error) -> DriveError {
  match e {
    DriveError(_) as d => d
    FsError(f) =>
      match f.code {
        "outside" => drive_error("path_escape", "that path leads out of its root")
        "protected" =>
          drive_error("protected", "the station's own data is not part of its drive")
        "grant" => {
          let d = drive_error(
            "permission", "macOS has not let still.fail Helper open that folder",
          )
          let DriveError(inner) = d
          inner.need = Some({
            grant: f.grant.unwrap_or(""),
            top: f.top.unwrap_or(""),
            window: "none",
          })
          d
        }
        "ENOENT" => drive_error("not_found", "no such file or folder")
        "EACCES" | "EPERM" =>
          drive_error("permission", "the station may not do that here")
        "EEXIST" | "ENOTEMPTY" =>
          drive_error("exists", "there is already one by that name")
        "EISDIR" => drive_error("is_a_directory", "that is a folder")
        "ENOTDIR" => drive_error("not_a_directory", "that is not a folder")
        "ENOSPC" => drive_error("too_large", "the station's disk is full")
        _ => drive_error("io", f.message)
      }
    e => drive_error("io", e.to_string())
  }
}

///|
/// The home's own folders offered as places to start from (drive.ts PLACES).
let place_names : Array[String] = [
  "Desktop", "Documents", "Downloads", "Movies", "Videos", "Music", "Pictures",
]

///|
/// The words of `station.drive.place.*` (client/i18n/catalog), Chinese for any language but English.
pub fn place_word(lang : String, name : String) -> String {
  let en = lang == "en"
  match name {
    "home" => if en { "Home" } else { "主目录" }
    "Desktop" => if en { "Desktop" } else { "桌面" }
    "Documents" => if en { "Documents" } else { "文稿" }
    "Downloads" => if en { "Downloads" } else { "下载" }
    "Movies" => if en { "Movies" } else { "影片" }
    "Videos" => if en { "Videos" } else { "视频" }
    "Music" => if en { "Music" } else { "音乐" }
    "Pictures" => if en { "Pictures" } else { "图片" }
    _ => "station.drive.place.\{name}"
  }
}

///|
fn is_dir(path : String) -> Bool {
  match attempt(() => stat(path)) {
    Ok(s) => s.dir
    Err(_) => false
  }
}

///|
/// The way to `at` (drive.ts `crumbs`): from the home when it is under it, else from the top.
fn crumbs(at : String, home : String, lang : String) -> Json {
  let (first_name, first_path, rest) = match relative_in(home, at) {
    Some(under) => (place_word(lang, "home"), home, under)
    None => {
      // Else from the top of its own disk (`/`; on Windows its drive, `E:\`).
      let top = root_of(at)
      (top, top, at.unsafe_substring(start=top.length(), end=at.length()))
    }
  }
  let out : Array[Json] = [{ "name": j(first_name), "path": j(first_path) }]
  let mut path = first_path
  for part in split_parts(rest) {
    path = join([path, part])
    out.push({ "name": j(part), "path": j(path) })
  }
  Json::array(out)
}

///|
/// A path asked of the drive (drive.ts `Place`).
pub(all) struct Place {
  root : String
  top : String
  asked : String
  found : String
  entry : String
  parts : Array[String]
  fs : Fs
  scope : String
}

///|
/// drive.ts `DriveDeps`.
pub(all) struct DriveDeps {
  config : () -> Json
  protect : () -> Array[String]
  now : (() -> Double)?
  files : Protected?
  home : String?
  /// The machine's mounts (platform.mountsSoon: macOS's `mount`; none elsewhere).
  mounts : () -> Array[String]
  /// The disks offered as places (platform.disks).
  disks : (String) -> Array[(String, String)]
}

///|
/// drive.ts `stationDrive`: the station's drive over config.json (`config`, as it is now), the station's own never
/// reached (its data directory, config.json, and `more`: what its parts add), the folders macOS protects through
/// still.fail Helper (`files`).
pub fn station_drive(
  config : () -> Json,
  data : String,
  config_path : String,
  more : () -> Array[String],
  files : Protected?,
  mounts : () -> Array[String],
) -> Drive {
  Drive::new({
    config,
    protect: () => [data, config_path] + more(),
    now: None,
    files,
    home: None,
    mounts,
    disks,
  })
}

///|
/// The station's drive (drive.ts `Drive`).
pub struct Drive {
  deps : DriveDeps
  /// What a listing gives, as a test shapes it (the TypeScript tests put their own `list` on a drive): given the
  /// path asked and what was listed.
  mut shape : ((String, (String, Array[Entry], Bool)) -> (String, Array[Entry], Bool) raise DriveError)?
}

///|
pub fn Drive::new(deps : DriveDeps) -> Drive {
  { deps, shape: None }
}

///|
pub fn Drive::set_shape(
  self : Drive,
  shape : ((String, (String, Array[Entry], Bool)) -> (String, Array[Entry], Bool) raise DriveError)?,
) -> Unit {
  self.shape = shape
}

///|
fn Drive::home(self : Drive) -> String {
  self.deps.home.unwrap_or(homedir())
}

///|
fn Drive::now(self : Drive) -> Double {
  match self.deps.now {
    Some(f) => f()
    None => (wall_now.val)()
  }
}

///|
pub fn Drive::roots(self : Drive) -> Array[RootView] {
  roots_of((self.deps.config)()).map(p => self.root_view(p))
}

///|
pub fn Drive::root_view(self : Drive, path : String) -> RootView {
  root_view_through(path, self.deps.files, self.home(), (self.deps.mounts)())
}

///|
fn Drive::locked(self : Drive, path : String) -> String? {
  match self.deps.files {
    Some(_) => protected_top_soon(path, self.home(), (self.deps.mounts)())
    None => None
  }
}

///|
fn Drive::real(self : Drive, path : String, fs : Fs) -> String raise {
  if fs.helper && self.locked(path) is Some(_) {
    (fs.real)(path)
  } else {
    real_of(path)
  }
}

///|
fn Drive::unreadable(self : Drive, dir : String) -> Bool {
  match self.locked(dir) {
    None => unreadable_dir(dir)
    Some(top) => !granted(self.deps.files.unwrap(), top)
  }
}

///|
fn unique(items : Array[String]) -> Array[String] {
  let out = []
  for i in items {
    if !out.contains(i) {
      out.push(i)
    }
  }
  out
}

///|
fn Drive::fs_for(
  self : Drive,
  places : Array[(String, String)],
) -> (Fs, Array[String]) {
  let locked = places.map(p => self.locked(p.0))
  let scopes = []
  for i, p in places {
    let top = p.1
    scopes.push(
      match locked[i] {
        Some(l) if !within(top, l) => l
        _ => top
      },
    )
  }
  if locked.iter().all(l => l is None) {
    return (direct(), scopes)
  }
  let protect = self.protected_now()
  ((self.deps.files.unwrap().fs)(unique(scopes), protect), scopes)
}

///|
/// drive.ts `#run`: `f`, its refusal a DriveError; one for a grant still.fail Helper lacks puts the helper's window up.
fn[T] Drive::run(self : Drive, f : () -> T raise) -> T raise DriveError {
  try f() catch {
    e => {
      let d = failed(e)
      let DriveError(inner) = d
      match (inner.need, self.deps.files) {
        (Some(need), Some(files)) => need.window = (files.ask)(need.grant, need.top)
        _ => ()
      }
      raise d
    }
  }
}

///|
/// drive.ts `scoped`: the drive as a workspace the station joined has it, its own pinned folders.
pub fn Drive::scoped(self : Drive, workspace : String) -> Drive {
  let config = self.deps.config
  {
    shape: None,
    deps: {
      ..self.deps,
      config: fn() {
        let raw = config()
        let o = match raw {
          Object(o) => o.copy()
          _ => Map::new()
        }
        let d = match o.get("drive") {
          Some(Object(d)) => d.copy()
          _ => Map::new()
        }
        d.set("roots", Json::array(roots_of(raw, workspace~).map(r => j(r))))
        o.set("drive", Json::object(d))
        Json::object(o)
      },
    },
  }
}

///|
fn Drive::protected_now(self : Drive) -> Array[String] {
  let named = (self.deps.protect)()
  named + named.map(p => real_of(p))
}

///|
fn Drive::is_protected(
  self : Drive,
  asked : String,
  found : String,
  protect? : Array[String],
) -> Bool {
  let p = match protect {
    Some(p) => p
    None => self.protected_now()
  }
  p.iter().any(x => within(asked, x) || within(found, x))
}

///|
/// drive.ts `place`: `path` under `root` as a request may use it, or why not.
pub fn Drive::place(
  self : Drive,
  root : String,
  path : String,
  anywhere : Bool,
) -> Place raise {
  let roots = roots_of((self.deps.config)())
  let cleaned = clean(root)
  let named = match roots.search_by(r => path_key(r) == path_key(cleaned)) {
    Some(i) => Some(roots[i])
    None => if anywhere && rooted(root) { Some(cleaned) } else { None }
  }
  guard named is Some(named) else {
    raise drive_error("not_a_root", "that folder is not one of this station's drive")
  }
  let parts = path
    .split("/")
    .map(p => p.to_string())
    .filter(p => p != "" && p != ".")
    .to_array()
  let win = path_mode.val is Win(_)
  if parts
    .iter()
    .any(p => p == ".." ||
      p.contains("\u{0}") ||
      (win && (p.contains("\\") || p.contains(":")))) {
    raise drive_error("path_escape", "a path stays in its root")
  }
  let mut top = if self.locked(named) is None { real_of(named) } else { named }
  let (fs, scopes) = self.fs_for([
    (if parts.is_empty() { top } else { join([top] + parts) }, top),
  ])
  if fs.helper && self.locked(top) is Some(_) {
    top = (fs.real)(top)
  }
  let asked = if parts.is_empty() { top } else { join([top] + parts) }
  let found = self.real(asked, fs)
  if !anywhere && !within(found, top) {
    raise drive_error("path_escape", "that path leads out of its root")
  }
  if self.is_protected(asked, found) {
    raise drive_error("protected", "the station's own data is not part of its drive")
  }
  let entry = if parts.is_empty() {
    top
  } else {
    join([self.real(dirname(asked), fs), basename(asked)])
  }
  { root: named, top, asked, found, entry, parts, fs, scope: scopes[0] }
}

///|
/// drive.ts `locate`: where a transfer reads a path (`found`) and removes it (`entry`).
pub fn Drive::locate(
  self : Drive,
  root : String,
  path : String,
  anywhere : Bool,
) -> (String, String) raise DriveError {
  self.run(() => {
    let p = self.place(root, path, anywhere)
    (p.found, p.entry)
  })
}

///|
fn last_part(parts : Array[String]) -> String? {
  parts.last()
}

///|
/// drive.ts `list`: a folder's entries, folders first, each part by name; what is protected or leads out left out.
pub fn Drive::list(
  self : Drive,
  root : String,
  path : String,
  anywhere : Bool,
) -> (String, Array[Entry], Bool) raise DriveError {
  let got = self.list_own(root, path, anywhere)
  match self.shape {
    Some(f) => f(path, got)
    None => got
  }
}

///|
fn Drive::list_own(
  self : Drive,
  root : String,
  path : String,
  anywhere : Bool,
) -> (String, Array[Entry], Bool) raise DriveError {
  self.run(() => {
    let at = self.place(root, path, anywhere)
    try {
      let (listed, more) = (at.fs.list)(at.found, most_entries)
      let entries = []
      let protect = self.protected_now()
      for d in listed {
        if is_part(d.name) {
          continue
        }
        let asked = join([at.found, d.name])
        guard d.stat is Some(s) else { continue }
        if (!anywhere && !within(d.real, at.top)) ||
          self.is_protected(asked, d.real, protect~) {
          continue
        }
        entries.push({
          name: d.name,
          dir: s.dir,
          size: if s.dir { 0.0 } else { s.size },
          mtime: js_round(s.mtime_ms),
          type_: if s.dir { "" } else { type_of(d.name) },
        })
      }
      let sorted = stable_sort(entries, (a, b) => if a.dir != b.dir {
        if a.dir {
          -1
        } else {
          1
        }
      } else {
        let c = collate(a.name, b.name)
        if c != 0 {
          c
        } else {
          units_compare(a.name, b.name)
        }
      })
      (at.parts.join("/"), sorted, more)
    } catch {
      e => raise failed(e)
    }
  })
}

///|
pub fn Drive::stat(
  self : Drive,
  root : String,
  path : String,
  anywhere : Bool,
) -> Entry raise DriveError {
  self.run(() => {
    let at = self.place(root, path, anywhere)
    try {
      let s = (at.fs.stat)(at.found)
      let name = last_part(at.parts).unwrap_or(root_name(at.root))
      {
        name,
        dir: s.dir,
        size: if s.dir { 0.0 } else { s.size },
        mtime: js_round(s.mtime_ms),
        type_: if s.dir { "" } else { type_of(name) },
      }
    } catch {
      e => raise failed(e)
    }
  })
}

///|
/// What a read gives (drive.ts `read`): the bytes, the file's whole size, its time, its type.
pub(all) struct Read {
  bytes : Bytes
  total : Double
  mtime : Double
  type_ : String
}

///|
/// drive.ts `read`: `length` bytes of a file from `offset`, with its whole size and time.
pub fn Drive::read(
  self : Drive,
  root : String,
  path : String,
  offset : Double,
  length : Double,
  anywhere : Bool,
) -> Read raise DriveError {
  self.run(() => {
    if !safe_integer(offset) ||
      offset < 0.0 ||
      !safe_integer(length) ||
      length < 0.0 ||
      length > max_read {
      raise drive_error("invalid_request", "invalid offset or length")
    }
    let at = self.place(root, path, anywhere)
    try {
      let (bytes, size, mtime) = (at.fs.read)(at.found, offset, length)
      {
        bytes,
        total: size,
        mtime: js_round(mtime),
        type_: type_of(last_part(at.parts).unwrap_or("")),
      }
    } catch {
      e => raise failed(e)
    }
  })
}

///|
/// drive.ts `file`: where a file is as the file system has it, its name, size and time; `copy` where it is reached
/// through still.fail Helper.
pub(all) struct FileAt {
  found : String
  name : String
  size : Double
  mtime : Double
  copy : ((String) -> Unit raise DriveError)?
}

///|
pub fn Drive::file(
  self : Drive,
  root : String,
  path : String,
  anywhere : Bool,
) -> FileAt raise DriveError {
  self.run(() => {
    let at = self.place(root, path, anywhere)
    try {
      let s = (at.fs.stat)(at.found)
      if s.dir {
        raise drive_error("is_a_directory", "that is a folder")
      }
      let copy : ((String) -> Unit raise DriveError)? = if at.fs.helper {
        Some(to => try (at.fs.copy_to)(at.found, to) catch { e => raise failed(e) })
      } else {
        None
      }
      {
        found: at.found,
        name: last_part(at.parts).unwrap_or(root_name(at.root)),
        size: s.size,
        mtime: js_round(s.mtime_ms),
        copy,
      }
    } catch {
      e => raise failed(e)
    }
  })
}

///|
/// drive.ts `upload`: a part of a file being written (an upload `id`), its bytes at `offset` of `total`; how much the
/// station has, and the file's entry once whole.
pub fn Drive::upload(
  self : Drive,
  root : String,
  path : String,
  id : String,
  offset : Double,
  total : Double,
  body : Bytes,
  replace : Bool,
  anywhere : Bool,
) -> (Double, Entry?) raise DriveError {
  self.run(() => {
    if !is_id(id) {
      raise drive_error(
        "invalid_request", "an upload's id is 1 to 64 letters, digits, - or _",
      )
    }
    let size = body.length().to_double()
    if !safe_integer(offset) ||
      offset < 0.0 ||
      !safe_integer(total) ||
      total < 0.0 ||
      offset + size > total {
      raise drive_error("invalid_request", "invalid offset or total")
    }
    let at = self.place(root, path, anywhere)
    guard last_part(at.parts) is Some(_) else {
      raise drive_error("invalid_request", "a file needs a name")
    }
    let fs = at.fs
    let folder = dirname(at.found)
    let part = join([folder, ".stillfail-up-\{id}.part"])
    let taken = () => {
      let s = match attempt(() => (fs.stat)(at.found)) {
        Ok(s) => Some(s)
        Err(_) => None
      }
      match s {
        Some(s) if s.dir =>
          raise drive_error("is_a_directory", "there is a folder by that name")
        Some(_) if !replace =>
          raise drive_error("exists", "there is already a file by that name")
        _ => ()
      }
    }
    let final_ = offset + size == total
    let mut last = false
    try {
      if offset == 0.0 {
        taken()
        self.sweep(folder, fs)
      }
      let written = try
        (fs.write)(part, {
          create: offset == 0.0,
          offset,
          data: body,
          at_least: if offset > 0.0 { Some(offset) } else { None },
          truncate: if final_ { Some(total) } else { None },
          sync: final_,
        })
      catch {
        FsError({ code: "ENOENT", .. }) if offset > 0.0 =>
          raise drive_error(
            "upload_lost",
            "the station has none of that upload",
            have=0.0,
          )
        e => raise e
      }
      if written.short {
        raise drive_error(
          "upload_lost",
          "a part before this one is missing",
          have=written.size,
        )
      }
      if !final_ {
        return (written.size, None)
      }
      last = true
      taken()
      (fs.rename)(part, at.found)
    } catch {
      e => {
        if last {
          (fs.unlink)(part) catch {
            _ => ()
          }
        }
        raise failed(e)
      }
    }
    (total, Some(self.stat(root, at.parts.join("/"), anywhere)))
  })
}

///|
/// Uploads in `folder` left unfinished long ago, removed.
fn Drive::sweep(self : Drive, folder : String, fs : Fs) -> Unit {
  let now = self.now()
  let listed = match attempt(() => (fs.names)(folder)) {
    Ok(n) => n
    Err(_) => []
  }
  for name in listed {
    if !is_part(name) {
      continue
    }
    match attempt(() => (fs.stat)(join([folder, name]))) {
      Ok(s) if now - s.mtime_ms > stale_ms =>
        (fs.unlink)(join([folder, name])) catch {
          _ => ()
        }
      _ => ()
    }
  }
}

///|
pub fn Drive::mkdir(
  self : Drive,
  root : String,
  path : String,
  anywhere : Bool,
) -> Entry raise DriveError {
  self.run(() => {
    let at = self.place(root, path, anywhere)
    if at.parts.is_empty() {
      raise drive_error("exists", "the root is there")
    }
    try {
      if attempt(() => (at.fs.stat)(at.found)) is Ok(_) {
        raise drive_error("exists", "there is already one by that name")
      }
      (at.fs.mkdir)(at.found, true)
    } catch {
      e => raise failed(e)
    }
    self.stat(root, at.parts.join("/"), anywhere)
  })
}

///|
/// drive.ts `rename`: renamed or moved within its root; what is there already is not replaced.
pub fn Drive::rename(
  self : Drive,
  root : String,
  from : String,
  to : String,
  anywhere : Bool,
) -> Entry raise DriveError {
  self.run(() => {
    let a = self.place(root, from, anywhere)
    let b = self.place(root, to, anywhere)
    if a.parts.is_empty() || b.parts.is_empty() {
      raise drive_error("invalid_request", "the root itself is not renamed")
    }
    if within(b.entry, a.entry) && path_key(b.entry) != path_key(a.entry) {
      raise drive_error("invalid_request", "a folder cannot go into itself")
    }
    let fs = if a.fs.helper || b.fs.helper {
      (self.deps.files.unwrap().fs)(unique([a.scope, b.scope]), self.protected_now())
    } else {
      direct()
    }
    try {
      (fs.lstat)(a.entry) |> ignore
      let there = attempt(() => (fs.lstat)(b.entry)) is Ok(_)
      if there && path_key(a.entry) != path_key(b.entry) {
        raise drive_error("exists", "there is already one by that name")
      }
      (fs.mkdir)(dirname(b.entry), true)
      (fs.rename)(a.entry, b.entry)
    } catch {
      e => raise failed(e)
    }
    self.stat(root, b.parts.join("/"), anywhere)
  })
}

///|
/// drive.ts `stage`: a file copied to `into` for a member to send it in a chat; `zip`: a folder put into a zip.
pub fn Drive::stage(
  self : Drive,
  root : String,
  path : String,
  into : (String) -> (String, String) raise,
  most : Double,
  anywhere : Bool,
  zip : Bool,
) -> (String, String, Double) raise DriveError {
  self.run(() => {
    let at = self.place(root, path, anywhere)
    let fs = at.fs
    let name = last_part(at.parts).unwrap_or(root_name(at.root))
    try {
      let s = (fs.stat)(at.found)
      if s.dir && zip {
        let (safe, to) = into("\{name}.zip")
        let protect = self.protected_now()
        let skip = (p : String, n : String) => is_part(n) ||
          self.is_protected(p, self.real(p, fs), protect~)
        let size = try zip_folder(at.found, to, most, skip, fs) catch {
          e => {
            unlink(to) catch {
              _ => ()
            }
            match e {
              TooBig => raise drive_error("too_large", too_big)
              e => raise e
            }
          }
        }
        return (safe, to, size)
      }
      if s.dir {
        raise drive_error("is_a_directory", "that is a folder")
      }
      if s.size > most {
        raise drive_error("too_large", too_big)
      }
      let (safe, to) = into(name)
      (fs.copy_to)(at.found, to)
      (safe, to, s.size)
    } catch {
      e => raise failed(e)
    }
  })
}

///|
/// drive.ts `remove`: put in the machine's trash (`no_trash` where none takes it); `permanent`: removed.
pub fn Drive::remove(
  self : Drive,
  root : String,
  path : String,
  anywhere : Bool,
  permanent : Bool,
) -> Unit raise DriveError {
  self.run(() => {
    let at = self.place(root, path, anywhere)
    if at.parts.is_empty() {
      raise drive_error("invalid_request", "the root itself is not removed")
    }
    try {
      (at.fs.lstat)(at.entry) |> ignore
      if !permanent {
        if (at.fs.trash)(at.entry, self.now(), self.deps.home) is None {
          raise drive_error("no_trash", "no trash takes it here")
        }
        return
      }
      (at.fs.remove)(at.entry)
    } catch {
      e => raise failed(e)
    }
  })
}

///|
/// The folders in `dir` made more than `ms` ago, removed.
fn sweep_old(dir : String, ms : Double, now : Double) -> Unit {
  let listed = match attempt(() => names(dir)) {
    Ok(n) => n
    Err(_) => []
  }
  for name in listed {
    let at = join([dir, name])
    match attempt(() => stat(at)) {
      Ok(s) if now - s.mtime_ms > ms => rm_force(at)
      _ => ()
    }
  }
}

///|
/// drive.ts `zip`: a folder put into a zip of its own name for a member to download it, in a folder of its own in the
/// machine's temporary files: (root, path, name, size).
pub fn Drive::zip(
  self : Drive,
  root : String,
  path : String,
  most : Double,
  anywhere : Bool,
) -> (String, String, String, Double) raise DriveError {
  self.run(() => {
    let at = self.place(root, path, anywhere)
    let name = "\{last_part(at.parts).unwrap_or(root_name(at.root))}.zip"
    let zips = join([tmpdir(), "stillfail-zips"])
    sweep_old(zips, zips_kept_ms, self.now())
    let dir = join([zips, random_uuid()])
    try {
      if !(at.fs.stat)(at.found).dir {
        raise drive_error("not_a_directory", "that is a file")
      }
      mkdir(dir, true, mode=0o700)
      let protect = self.protected_now()
      let skip = (p : String, n : String) => is_part(n) ||
        self.is_protected(p, self.real(p, at.fs), protect~)
      let size = zip_folder(at.found, join([dir, name]), most, skip, at.fs)
      (dir, name, name, size)
    } catch {
      e => {
        rm_force(dir)
        match e {
          TooBig => raise drive_error("too_large", too_big)
          e => raise failed(e)
        }
      }
    }
  })
}

///|
/// drive.ts `folderToWatch`: the folder at `path` as the file system has it, to watch; one reached through still.fail
/// Helper is refused.
pub fn Drive::folder_to_watch(
  self : Drive,
  root : String,
  path : String,
  anywhere : Bool,
) -> String raise {
  let at = self.place(root, path, anywhere)
  if at.fs.helper {
    raise drive_error(
      "permission", "a folder reached through still.fail Helper is not watched",
    )
  }
  try {
    if !stat(at.found).dir {
      raise drive_error("not_a_directory", "that is a file")
    }
  } catch {
    e => raise failed(e)
  }
  at.found
}

///|
fn folder_json(
  name : String,
  path : String,
  unreadable : Bool,
  disk? : Bool = false,
  git? : Bool = false,
) -> Json {
  let o : Map[String, Json] = {
    "name": j(name),
    "path": j(path),
    "unreadable": j(unreadable),
  }
  if disk {
    o.set("disk", j(true))
  }
  if git {
    o.set("git", j(true))
  }
  Json::object(o)
}

///|
/// drive.ts `folders`: the folders in `path` (the home when none), for owners and admins to pick a root from.
pub fn Drive::folders(
  self : Drive,
  path : String,
  home : String,
  lang : String,
) -> Json raise {
  let at = clean(if path == "" { home } else { path })
  if !rooted(if path == "" { home } else { path }) {
    raise drive_error("invalid_request", "an absolute path")
  }
  try {
    let (fs, _) = self.fs_for([(at, at)])
    let (listed, unreadable) = try ((fs.list)(at, most_entries).0, false) catch {
      FsError(f) as e => {
        if f.code == "grant" {
          self.run(() => raise e) catch {
            _ => ()
          }
        }
        if f.code == "EPERM" || f.code == "EACCES" || f.code == "grant" {
          ([], true)
        } else {
          raise e
        }
      }
      e => raise e
    }
    let protect = self.protected_now()
    let entries : Array[(String, String, Bool)] = []
    for d in listed {
      if d.name.has_prefix(".") {
        continue
      }
      let asked = join([at, d.name])
      let is_folder = match d.stat {
        Some(s) => s.dir
        None => false
      }
      if is_folder && !self.is_protected(asked, d.real, protect~) {
        entries.push((d.name, asked, self.unreadable(asked)))
      }
    }
    let sorted = stable_sort(entries, (a, b) => collate(a.0, b.0))
    let reach = self.locked(at)
    let reaches = sorted.map(e => self.locked(e.1))
    let shown : Array[Json] = []
    let names_shown : Array[Json] = []
    for i, e in sorted {
      let looked = !e.2 && reaches[i] == reach
      let git = looked && attempt(() => (fs.stat)(join([e.1, ".git"]))) is Ok(_)
      shown.push(folder_json(e.0, e.1, e.2, git~))
      names_shown.push(j(e.0))
    }
    let parent = dirname(at)
    {
      "path": j(at),
      "parent": if parent == at { Json::null() } else { j(parent) },
      "home": j(home),
      "folders": Json::array(names_shown),
      "entries": Json::array(shown),
      "unreadable": j(unreadable),
      "crumbs": crumbs(at, home, lang),
      "places": Json::array(self.places(home, lang, protect)),
    }
  } catch {
    e => raise failed(e)
  }
}

///|
/// Where a folder to lend usually is: the home's own folders that are there, then the disks mounted.
fn Drive::places(
  self : Drive,
  home : String,
  lang : String,
  protect : Array[String],
) -> Array[Json] {
  let found = [folder_json(place_word(lang, "home"), home, self.unreadable(home))]
  for name in place_names {
    let path = join([home, name])
    if is_dir(path) {
      found.push(folder_json(place_word(lang, name), path, self.unreadable(path)))
    }
  }
  for disk in (self.deps.disks)(home) {
    let (name, path) = disk
    if !is_dir(path) ||
      real_of(path) == "/" ||
      self.is_protected(path, real_of(path), protect~) {
      continue
    }
    found.push(folder_json(name, path, self.unreadable(path), disk=true))
  }
  found
}

///|
/// drive.ts `checkRoot`: whether `path` may be a root: there, a folder, none of the station's own data.
pub fn Drive::check_root(self : Drive, path : String) -> String raise DriveError {
  let about = (e : DriveError) => {
    let DriveError(inner) = e
    inner.about = Some(path)
    e
  }
  if !rooted(path) {
    raise about(drive_error("invalid_request", "not an absolute path"))
  }
  let cleaned = clean(path)
  let (fs, _) = self.fs_for([(cleaned, cleaned)])
  let s = self.run(() => (fs.stat)(cleaned)) catch { e => raise about(failed(e)) }
  if !s.dir {
    raise about(drive_error("not_a_directory", "not a folder"))
  }
  let real = self.real(cleaned, fs) catch { e => raise about(failed(e)) }
  if self.is_protected(cleaned, real) {
    raise about(drive_error("protected", "the station's own data"))
  }
  cleaned
}
