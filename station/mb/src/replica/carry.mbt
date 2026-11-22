// What of a workspace's chats goes along beside their copy as a station is retired from it, or a chat handed over
// (station/src/replica/carry.ts, which starts this as `--builder replica-carry`; replica/AGENTS.md): their agents'
// transcripts and each session's own directory (its room), gathered on the station they leave and put in place on the
// one they go to, at the same place under its data directory, nothing in it changed on the way. Line for line what
// station/test/carry-reference.ts (the worker thread's from before) does, which station/test/mb-replica-carry.test.ts
// holds it to: the same lists, index and answers, the same files put.
//
// A station has a million files under `sessions/`: none of it is one value here. Each session's files are a list on
// disk written a line at a time (carry.c), and what goes along is the index of the lists; a list is read back a part
// at a time (the shell's `text.*`).

///|
#borrow(path)
extern "C" fn open_ffi(path : Bytes, append : Int) -> Int = "sfc_open"

///|
#borrow(data)
extern "C" fn write_ffi(fd : Int, data : Bytes) -> Int = "sfc_write"

///|
extern "C" fn close_ffi(fd : Int) -> Int = "sfc_close"

///|
#borrow(path)
extern "C" fn utimes_ffi(path : Bytes, secs : Double) -> Int = "sfc_utimes"

///|
#borrow(path)
extern "C" fn nlink_ffi(path : Bytes) -> Int = "sfc_nlink"

///|
#borrow(from, to)
extern "C" fn link_ffi(from : Bytes, to : Bytes) -> Int = "sfc_link"

///|
#borrow(path)
extern "C" fn denied_ffi(path : Bytes, dir : Int) -> Int = "sfc_denied"

///|
/// A C string: `s` in UTF-8, NUL-terminated.
fn c_path(s : String) -> Bytes {
  let b = @utf8.encode(s)
  let out = FixedArray::make(b.length() + 1, b'\x00')
  for i = 0; i < b.length(); i = i + 1 {
    out[i] = b[i]
  }
  Bytes::from_array(out)
}

///|
/// A file written a line at a time (made where it is not: emptied first, or appended to with `append`).
priv struct Writer {
  fd : Int
  path : String
}

///|
fn Writer::open(path : String, append : Bool) -> Writer raise {
  let fd = open_ffi(c_path(path), if append { 1 } else { 0 })
  if fd < 0 {
    fail("cannot open '\{path}' to write")
  }
  { fd, path }
}

///|
fn Writer::put(self : Writer, text : String) -> Unit raise {
  if write_ffi(self.fd, @utf8.encode(text)) != 0 {
    fail("cannot write '\{self.path}'")
  }
}

///|
fn Writer::close(self : Writer) -> Unit {
  ignore(close_ffi(self.fd))
}

// ---- paths, as Node's path module and the station's platform (src/platform) make them ----

///|
fn Files::win(self : Files) -> Bool {
  self.sep == "\\"
}

///|
fn Files::is_sep(self : Files, c : Int) -> Bool {
  c == '/' || (self.win() && c == '\\')
}

///|
/// path.isAbsolute.
fn Files::absolute(self : Files, p : String) -> Bool {
  if p.length() == 0 {
    return false
  }
  if self.is_sep(p.unsafe_charcode_at(0)) {
    return true
  }
  if !self.win() || p.length() < 3 {
    return false
  }
  let c = p.unsafe_charcode_at(0)
  ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')) && p.unsafe_charcode_at(1) == ':' && self.is_sep(p.unsafe_charcode_at(2))
}

///|
/// The root a path begins with (`/`, `C:\`, `\\`), as path.parse says it; "" for a relative one.
fn Files::root_of(self : Files, p : String) -> String {
  if self.win() && p.length() >= 3 && p.unsafe_charcode_at(1) == ':' && self.is_sep(p.unsafe_charcode_at(2)) {
    p.view(end_offset=3).to_string()
  } else if p.length() > 0 && self.is_sep(p.unsafe_charcode_at(0)) {
    self.sep
  } else {
    ""
  }
}

///|
/// path.resolve of an absolute path (normalized, no separator left at its end but the root's); a relative one is
/// resolved against the program's working directory, as Node's against its own (the station starts it in its own).
fn Files::resolve(self : Files, p : String) -> String {
  let whole = if self.absolute(p) {
    self.join([p])
  } else {
    let cwd = match (try Some(self.call("fs.realpath", { "path": Json::string(".") })) catch { _ => None }) {
      Some(String(c)) => c
      _ => self.sep
    }
    self.join([cwd, p])
  }
  let root = self.root_of(whole)
  if whole.length() > root.length() && self.is_sep(whole.unsafe_charcode_at(whole.length() - 1)) {
    whole.view(end_offset=whole.length() - 1).to_string()
  } else {
    whole
  }
}

///|
/// path.resolve(dir, p).
fn Files::resolve_in(self : Files, dir : String, p : String) -> String {
  if self.absolute(p) {
    self.resolve(p)
  } else {
    self.resolve(self.join([dir, p]))
  }
}

///|
/// path.dirname.
fn Files::dir_of(self : Files, p : String) -> String {
  let root = self.root_of(p)
  let mut end = p.length()
  while end > root.length() && self.is_sep(p.unsafe_charcode_at(end - 1)) {
    end -= 1
  }
  let mut i = end - 1
  while i >= root.length() && !self.is_sep(p.unsafe_charcode_at(i)) {
    i -= 1
  }
  if i < root.length() {
    return if root == "" { "." } else { root }
  }
  let mut cut = i
  while cut > root.length() && self.is_sep(p.unsafe_charcode_at(cut - 1)) {
    cut -= 1
  }
  if cut <= root.length() {
    root
  } else {
    p.view(end_offset=cut).to_string()
  }
}

///|
/// path.basename.
fn Files::base_of(self : Files, p : String) -> String {
  let mut end = p.length()
  while end > 0 && self.is_sep(p.unsafe_charcode_at(end - 1)) {
    end -= 1
  }
  let mut i = end - 1
  while i >= 0 && !self.is_sep(p.unsafe_charcode_at(i)) {
    i -= 1
  }
  p.view(start_offset=i + 1, end_offset=end).to_string()
}

///|
/// How the platform compares paths (on Windows case does not tell them apart: platform.paths.key).
fn Files::key(self : Files, p : String) -> String {
  if self.win() {
    p.to_lower()
  } else {
    p
  }
}

///|
/// platform.paths.within (ops/paths.ts `within`): `path` is `dir` or under it.
fn Files::within(self : Files, path : String, dir : String) -> Bool {
  if !self.win() {
    return dir == "/" || path == dir || path.has_prefix(dir + "/")
  }
  let p = self.key(path)
  let d = self.key(dir)
  p == d ||
  p.has_prefix(
    if d.length() > 0 && self.is_sep(d.unsafe_charcode_at(d.length() - 1)) {
      d
    } else {
      d + "\\"
    },
  )
}

///|
/// ops/paths.ts `segments`.
fn Files::segments(self : Files, p : String) -> Array[String] {
  let out = []
  let mut start = 0
  for i in 0..<p.length() {
    if p.unsafe_charcode_at(i) == '/' || (self.win() && p.unsafe_charcode_at(i) == '\\') {
      out.push(p.view(start_offset=start, end_offset=i).to_string())
      start = i + 1
    }
  }
  out.push(p.view(start_offset=start).to_string())
  out
}

///|
/// ops/paths.ts `fileName`: the last part; none for `..` or a root.
fn Files::file_name(self : Files, p : String) -> String? {
  let parts = self.segments(p).filter(x => x != "" && x != ".")
  guard parts.last() is Some(last) else { return None }
  if last == ".." {
    return None
  }
  if self.win() && parts.length() == 1 && last.length() == 2 && last.unsafe_charcode_at(1) == ':' {
    let c = last.unsafe_charcode_at(0)
    if (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') {
      return None
    }
  }
  Some(last)
}

///|
/// What follows `dir` in `path` as path.relative(dir, path) says it where `path` is `dir` or under it (""), none
/// where it is not (path.relative's answer would leave it: `..`, or another drive).
fn Files::under_of(self : Files, dir : String, path : String) -> String? {
  let d = self.resolve(dir)
  let p = self.resolve(path)
  if self.key(d) == self.key(p) {
    return Some("")
  }
  let prefix = if d.length() > 0 && self.is_sep(d.unsafe_charcode_at(d.length() - 1)) { d } else { d + self.sep }
  if self.key(p).has_prefix(self.key(prefix)) {
    Some(p.view(start_offset=prefix.length()).to_string())
  } else {
    None
  }
}

///|
/// carry-reference.ts `carriedPlace`: whether `path` is one that goes along, or is put: under `data`'s `sessions/` or a
/// `transcripts*/` of it, or what an Antigravity CLI keeps of its conversations in a profile's home there (`cli_kept`).
fn Files::carried_place(self : Files, data : String, path : String) -> Bool {
  guard self.under_of(data, path) is Some(rel) && rel != "" else { return false }
  let parts : Array[String] = rel.split(self.sep).map(x => x.to_string()).collect()
  parts.length() > 1 && (parts[0] == "sessions" || parts[0].has_prefix("transcripts") || cli_kept(parts))
}

///|
/// carry.ts `cliKept`: the parts of a path under the data directory in a profile's home where an Antigravity CLI keeps
/// a conversation (`homes/<profile>/agy/.gemini/antigravity-cli/` `conversations`, `brain` or `annotations`).
fn cli_kept(parts : Array[String]) -> Bool {
  parts.length() >= 7 &&
  parts[0] == "homes" &&
  parts[2] == "agy" &&
  parts[3] == ".gemini" &&
  parts[4] == "antigravity-cli" &&
  (parts[5] == "conversations" || parts[5] == "brain" || parts[5] == "annotations")
}

///|
/// carry.ts `ONE_SEGMENT`: a path segment of its own (no separator, never `.` or `..`).
fn one_segment(s : String) -> Bool {
  if s.length() == 0 || s.unsafe_charcode_at(0) == '.' {
    return false
  }
  for i in 0..<s.length() {
    let c = s.unsafe_charcode_at(i)
    if !((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_' || c == '.' || c == '@' || c == '+' || c == '-') {
      return false
    }
  }
  true
}

///|
/// carry.ts `cliKeptOf`, gathered: what an Antigravity CLI keeps of each of `ids` (those of the `agy` runtime with a
/// profile) in its profile's home, which `session/load` takes the conversation up from.
fn Gathering::cli_kept_of(self : Gathering, ids : Array[@locate.Source]) -> Unit raise {
  for r in ids {
    guard r.runtime == "agy" && r.profile is Some(profile) && one_segment(profile) && one_segment(r.id) else { continue }
    let cli = self.files.join([self.data, "homes", profile, "agy", ".gemini", "antigravity-cli"])
    self.add(self.files.join([cli, "conversations", r.id + ".db"]))
    self.add(self.files.join([cli, "conversations", r.id + ".db-wal"]))
    self.add(self.files.join([cli, "annotations", r.id + ".pbtxt"]))
    let brain = self.files.join([cli, "brain", r.id])
    if self.files.exists(brain) {
      self.whole(brain)
    }
  }
}

///|
/// carry-reference.ts's own `within`: `path` is `dir` or under it, by its text.
fn Files::inside(self : Files, path : String, dir : String) -> Bool {
  path == dir || path.has_prefix(if dir.has_suffix(self.sep) { dir } else { dir + self.sep })
}

///|
fn Files::real(self : Files, p : String) -> String? {
  match (try Some(self.call("fs.realpath", { "path": Json::string(p) })) catch { _ => None }) {
    Some(String(r)) => Some(r)
    _ => None
  }
}

///|
/// carry-reference.ts `realOf`: `path`'s real path, the part of it not there yet as it is.
fn Files::real_of(self : Files, path : String) -> String {
  let rest : Array[String] = []
  let mut at = path
  while true {
    if self.real(at) is Some(r) {
      rest.rev_in_place()
      return self.join([r, ..rest])
    }
    let up = self.dir_of(at)
    if up == at {
      return path
    }
    rest.push(self.base_of(at))
    at = up
  }
  path
}

///|
/// What lstat says: (kind, size, mode, mtimeMs), none where nothing is there.
fn Files::lstat(self : Files, p : String) -> (String, Double, Int, Double)? {
  match (try Some(self.call("fs.lstat", { "path": Json::string(p) })) catch { _ => None }) {
    Some({ "kind": String(kind), "size": Number(size, ..), "mode": Number(mode, ..), "mtimeMs": Number(mtime, ..), .. }) =>
      Some((kind, size, mode.to_int(), mtime))
    _ => None
  }
}

///|
/// A directory's names with their kinds (links not followed), sorted as JavaScript's sort() sorts strings; none where
/// it does not read.
fn Files::listing(self : Files, dir : String) -> Array[(String, String)]? {
  match (try Some(self.call("fs.readdir", { "path": Json::string(dir), "types": true })) catch { _ => None }) {
    Some(Array(entries)) => {
      let out = entries.filter_map(e => if e is Array([String(name), String(kind)]) { Some((name, kind)) } else { None })
      out.sort_by((a, b) => compare_units(a.0, b.0))
      Some(out)
    }
    _ => None
  }
}

///|
fn Files::read_link(self : Files, p : String) -> String raise {
  match self.call("fs.readlink", { "path": Json::string(p) }) {
    String(t) => t
    _ => fail("EINVAL: invalid argument, readlink '\{p}'")
  }
}

///|
/// The lines of a file (none empty), read a part at a time; nothing where it does not open.
fn Files::each_line(self : Files, path : String, f : (String) -> Unit raise) -> Unit raise {
  let opened = self.call("text.open", { "path": Json::string(path), "lines": Json::boolean(true) })
  guard opened is { "id": id, .. } else { return }
  defer (try Some(self.call("text.close", { "id": id })) catch { _ => None }) |> ignore
  while true {
    guard self.call("text.next", { "id": id }) is String(part) else { break }
    for line in part.split("\n") {
      if line.length() > 0 {
        f(line.to_string())
      }
    }
  }
}

///|
/// As JavaScript's sort() compares strings: by their UTF-16 code units (MoonBit's compare puts the shorter first).
fn compare_units(a : String, b : String) -> Int {
  @jsjson.js_compare(a, b)
}

///|
/// String.prototype.trim: JavaScript's white space and line ends off both ends.
fn js_trim(s : String) -> String {
  @jsjson.trim_js(s)
}

///|
/// The first 32 hex digits of `text`'s SHA-256 (createHash("sha256").update(text).digest("hex").slice(0, 32)).
fn short_hash(text : String) -> String {
  @activity.sha256_hex(@activity.utf8(text)).view(end_offset=32).to_string()
}

///|
/// footprint.ts `rebuildableSoon`: a directory a build or an install makes again.
fn Files::rebuildable(self : Files, dir : String) -> Bool {
  guard self.file_name(dir) is Some(name) else { return false }
  let beside = (file : String) => self.exists(self.join([self.dir_of(dir), file]))
  match name {
    "node_modules" | ".next" | ".turbo" | "__pycache__" => true
    "target" => beside("Cargo.toml")
    ".gradle" =>
      beside("settings.gradle") || beside("settings.gradle.kts") || beside("build.gradle") || beside("build.gradle.kts")
    "build" => beside("build.gradle") || beside("build.gradle.kts")
    _ => false
  }
}

///|
/// test/footprint-reference.ts `rebuiltByName`, the gathering's own decision from the listing it read anyway: `name` a directory's,
/// `beside` the names of the directory it is in. 0: not made again; 1: by its name (and a file beside it); 2: known by
/// what is beside it (Elixir's, MoonBit's).
fn rebuilt_by_name(name : String, beside : Set[String]) -> Int {
  match name {
    "node_modules" | ".next" | ".turbo" | "__pycache__" => 1
    "target" => if beside.contains("Cargo.toml") { 1 } else { 0 }
    ".gradle" =>
      if beside.contains("settings.gradle") ||
        beside.contains("settings.gradle.kts") ||
        beside.contains("build.gradle") ||
        beside.contains("build.gradle.kts") {
        1
      } else {
        0
      }
    "build" => if beside.contains("build.gradle") || beside.contains("build.gradle.kts") { 1 } else { 0 }
    "_build" =>
      if beside.contains("mix.exs") ||
        beside.contains("moon.mod.json") ||
        beside.contains("moon.mod") ||
        beside.contains("moon.work") ||
        beside.contains("moon.pkg.json") ||
        beside.contains("moon.pkg") {
        2
      } else {
        0
      }
    "deps" => if beside.contains("mix.exs") { 2 } else { 0 }
    ".mooncakes" =>
      if beside.contains("moon.mod.json") || beside.contains("moon.mod") || beside.contains("moon.work") {
        2
      } else {
        0
      }
    _ => 0
  }
}

///|
/// test/footprint-reference.ts `ANY_NAME_DEPTH`: how deep under a room's top (its own entries 1) what is made again of any name is
/// asked.
let any_name_depth = 3

///|
/// What Cargo writes in its target directory's CACHEDIR.TAG (footprint.ts `CARGO_TAG`).
let cargo_tag : Array[String] = [
  "Signature: 8a477f597d28d172789f06886806bc55", "# This file is a cache directory tag created by cargo.",
]

///|
/// test/footprint-reference.ts `rebuiltOfAnyName`: whether `dir`, whose listing is `names`, is Xcode's derived data or a Cargo target:
/// looked at on the disk only where its listing shows the sign (a `Build`, a `CACHEDIR.TAG`).
fn Files::rebuilt_of_any_name(self : Files, dir : String, names : Array[(String, String)]) -> Bool raise {
  let has = (n : String) => names.iter().any(e => e.0 == n)
  if has("Build") &&
    self.kind(self.join([dir, "Build", "Products"])) == Some("dir") &&
    self.kind(self.join([dir, "Build", "Intermediates.noindex"])) == Some("dir") {
    return true
  }
  if !has("CACHEDIR.TAG") {
    return false
  }
  guard (try self.read(self.join([dir, "CACHEDIR.TAG"])) catch { _ => None }) is Some(tag) else { return false }
  // (footprint.ts: split at `\r?\n`, a `\r` that ends the text kept)
  let pieces : Array[String] = tag.split("\n").map(l => l.to_string()).collect()
  let lines = pieces.mapi((k, t) => if k < pieces.length() - 1 && t.has_suffix("\r") {
    t.view(end_offset=t.length() - 1).to_string()
  } else {
    t
  })
  if !cargo_tag.iter().all(l => lines.contains(l)) {
    return false
  }
  if has(".rustc_info.json") {
    return true
  }
  for profile in ["debug", "release"] {
    if has(profile) {
      for own in ["deps", ".fingerprint"] {
        if self.kind(self.join([dir, profile, own])) == Some("dir") {
          return true
        }
      }
    }
  }
  false
}

///|
/// The names of a listing, as a set (what `rebuilt_by_name` is asked beside).
fn names_of(entries : Array[(String, String)]) -> Set[String] {
  let out : Set[String] = Set([])
  for e in entries {
    out.add(e.0)
  }
  out
}

///|
/// footprint.ts `roomOfSoon`: where a session's own directory is (sessions/<connect>/<session>), none where its workspace
/// is not in the station's layout.
fn Files::room_of(self : Files, data : String, workspace : String) -> String? {
  guard self.real(self.join([data, "sessions"])) is Some(sessions) else { return None }
  let path = match self.real(workspace) {
    Some(p) => Some(p)
    None =>
      if self.file_name(workspace) == Some("workspace") {
        match self.real(self.dir_of(workspace)) {
          Some(parent) => Some(self.join([parent, "workspace"]))
          None => None
        }
      } else {
        None
      }
  }
  guard path is Some(p) else { return None }
  if !self.within(p, sessions) || self.key(p) == self.key(sessions) {
    return None
  }
  let relative = self.segments(p.view(start_offset=sessions.length()).to_string()).filter(x => x != "")
  if relative.length() != 3 || self.file_name(p) != Some("workspace") {
    return None
  }
  Some(self.dir_of(p))
}

///|
/// carry-reference.ts `roomFor`: a session's room under `data` as given (`real_data` its real path), none where its
/// directory is not the station's own.
fn Files::room_for(self : Files, data : String, real_data : String, workspace : String) -> String? {
  guard self.room_of(data, workspace) is Some(real) && self.within(real, real_data) else { return None }
  let rest = if self.key(real) == self.key(real_data) {
    ""
  } else {
    let cut = if real_data.has_suffix(self.sep) { real_data.length() } else { real_data.length() + 1 }
    real.view(start_offset=cut).to_string()
  }
  Some(self.join([data, rest]))
}

///|
/// transcript.ts `sessionPlaces`.
fn session_places(cwd : String?, workspace : String) -> Array[String] {
  match cwd {
    Some(c) if c != workspace => [c, workspace]
    _ => [workspace]
  }
}

///|
fn field_str(r : Map[String, Json], name : String) -> String? {
  match r.get(name) {
    Some(String(s)) => Some(s)
    _ => None
  }
}

///|
fn jnum(d : Double) -> JValue {
  Num(d)
}

///|
fn jobj(entries : Array[(String, JValue)]) -> JValue {
  Obj(entries)
}

///|
fn jopt(s : String?) -> JValue {
  match s {
    Some(v) => str(v)
    None => Null
  }
}

// ---- the gathering ----

///|
/// A session's list being written (carry-reference.ts `ListFile`): its files and bytes counted, its hash taken once whole.
priv struct ListFile {
  out : Writer
  path : String
  tmp : String
  mut files : Int
  mut bytes : Double
}

///|
fn ListFile::open(path : String) -> ListFile raise {
  let tmp = path + ".writing"
  { out: Writer::open(tmp, false), path, tmp, files: 0, bytes: 0.0 }
}

///|
fn ListFile::add(self : ListFile, f : JValue, size : Double?) -> Unit raise {
  self.out.put(@jsjson.stringify(f) + "\n")
  if size is Some(n) {
    self.files += 1
    self.bytes += n
  }
}

///|
/// The list closed and put in place: its hash.
fn ListFile::close(self : ListFile, files : Files) -> String raise {
  self.out.close()
  guard files.hash(self.tmp) is Some(h) else { fail("ENOENT: no such file or directory, open '\{self.tmp}'") }
  files.rename(self.tmp, self.path)
  h
}

///|
/// Where what is added may be: under the data directory's sessions or transcripts, or (the agent home's own files)
/// under it.
priv enum Under {
  Data
  Home(String)
}

///|
priv struct Gathering {
  files : Files
  data : String
  scratch : String
  gits : Array[JValue]
  bundles : Map[String, String]
  fetched : Set[String]
  /// A gathering's (carry-reference.ts `ownGits`): the session's own repositories (a checkout's `.git` directory),
  /// walked whole once its room was: a linked worktree of one walked after it in the room fetches into it (`linked`).
  own_gits : Array[String]
  mut bytes : Double
  mut before : Map[String, (Double, Double, String)]
  mut seen : Set[String]
  mut list : ListFile?
  mut under : Under
  unreadable : Array[String]
  mut unreadable_count : Int
  /// A sizing's (carry-reference.ts `sizes`): each file's size counted, nothing hashed or listed; the most entries a
  /// session's walk takes, and how many it took.
  mut tally : Tally?
  most : Int?
  mut walked : Int
}

///|
/// A session's files counted, for a sizing.
priv struct Tally {
  mut files : Int
  mut bytes : Double
}

///|
/// A sizing's walk past its bound.
priv suberror Cut

///|
/// Its words where it is said (`to_string`, a notice, a log): not its type's name (`station/<package>.<Type>`).
impl Show for Cut with output(self, logger) {
  match self {
    Cut => logger.write_string("the sizing's walk passed its bound")
  }
}

///|
/// One entry more of a sizing's walk; past its bound, the walk of that session ends there (said at least).
fn Gathering::step(self : Gathering) -> Unit raise {
  if self.most is Some(most) {
    self.walked += 1
    if self.walked > most {
      raise Cut
    }
  }
}

///|
fn Gathering::cannot_read(self : Gathering, path : String) -> Unit {
  self.unreadable_count += 1
  if self.unreadable.length() < 5 {
    self.unreadable.push(path)
  }
}

///|
fn Gathering::denied(self : Gathering, path : String, dir : Bool) -> Bool {
  ignore(self)
  denied_ffi(c_path(path), if dir { 1 } else { 0 }) == 1
}

///|
fn Gathering::allowed(self : Gathering, path : String) -> Bool {
  match self.under {
    Data => self.files.carried_place(self.data, path)
    Home(dir) => self.files.inside(path, dir) && path != dir
  }
}

///|
fn Gathering::add(self : Gathering, path : String) -> Unit raise {
  if self.list is None && self.tally is None {
    return
  }
  if self.seen.contains(path) || !self.allowed(path) {
    return
  }
  self.seen.add(path)
  self.step()
  guard self.files.lstat(path) is Some((kind, size, mode, mtime)) else { return }
  if self.tally is Some(t) {
    if kind == "file" {
      t.files += 1
      t.bytes += size
    }
    return
  }
  guard self.list is Some(list) else { return }
  if kind == "link" {
    list.add(jobj([("path", str(path)), ("link", str(self.files.read_link(path)))]), None)
    return
  }
  if kind != "file" {
    return
  }
  let hash = match self.before.get(path) {
    Some((s, m, h)) if s == size && m == mtime => Some(h)
    _ =>
      match (try Some(self.files.hash(path)) catch { _ => None }) {
        Some(Some(h)) => Some(h)
        _ => None
      }
  }
  guard hash is Some(h) else {
    if self.denied(path, false) {
      self.cannot_read(path)
    }
    return
  }
  list.add(
    jobj([("path", str(path)), ("hash", str(h)), ("size", jnum(size)), ("mode", jnum((mode & 0o777).to_double())), ("mtimeMs", jnum(mtime))]),
    Some(size),
  )
}

///|
/// Every file under `dir` as it is (a checkout's own repository).
fn Gathering::whole(self : Gathering, dir : String) -> Unit raise {
  self.step()
  guard self.files.listing(dir) is Some(entries) else {
    if self.denied(dir, true) {
      self.cannot_read(dir)
    }
    return
  }
  for e in entries {
    let path = self.files.join([dir, e.0])
    if e.1 == "dir" {
      self.whole(path)
    } else {
      self.add(path)
    }
  }
}

///|
/// Every file under `dir`, but what a build makes again; a git checkout in it as `checkout` takes it. `depth`: under
/// the room's top (its own entries 1): what is made again of any name is asked only down to `any_name_depth`, by its
/// own listing, and by name from the listing of where it is.
fn Gathering::tree(self : Gathering, dir : String, depth : Int) -> Unit raise {
  self.step()
  guard self.files.listing(dir) is Some(entries) else {
    if self.denied(dir, true) {
      self.cannot_read(dir)
    }
    return
  }
  if entries.iter().any(e => e.0 == ".git") && self.checkout(dir, depth) {
    return
  }
  if depth <= any_name_depth && self.files.rebuilt_of_any_name(dir, entries) {
    return
  }
  let here = names_of(entries)
  for e in entries {
    let path = self.files.join([dir, e.0])
    if e.1 == "dir" {
      if e.0 == ".git" || rebuilt_by_name(e.0, here) == 0 {
        self.tree(path, depth + 1)
      }
    } else {
      self.add(path)
    }
  }
}

///|
/// git run in `dir` as carry-reference.ts runs it (no prompt for a password, its output trimmed); none where it failed.
fn Gathering::git(self : Gathering, dir : String, args : Array[String], timeout? : Double) -> String? {
  let all : Array[Json] = [Json::string("-C"), Json::string(dir)]
  for a in args {
    all.push(Json::string(a))
  }
  let asked : Json = {
    "command": "git",
    "args": Json::array(all),
    "env": { "GIT_TERMINAL_PROMPT": "0", "GIT_SSH_COMMAND": "ssh -o BatchMode=yes" },
    "maxBytes": Json::number(256.0 * 1024.0 * 1024.0),
    // (none: as long as it takes, as execFileSync without a timeout)
    "timeoutMs": Json::number(timeout.unwrap_or(1.0e12)),
  }
  match (try Some(self.files.call("proc.run", asked)) catch { _ => None }) {
    Some(String(out)) => Some(js_trim(out))
    _ => None
  }
}

///|
/// A git checkout at `dir`, taken (carry-reference.ts `checkout`); false where git does not read it.
fn Gathering::checkout(self : Gathering, dir : String, depth : Int) -> Bool raise {
  let dotgit = self.files.join([dir, ".git"])
  guard self.files.lstat(dotgit) is Some((kind, _, _, _)) else { return false }
  guard self.git(dir, ["ls-files", "-z", "--cached", "--others", "--exclude-standard"]) is Some(listed) else {
    return false
  }
  let made : Map[String, Bool] = Map([])
  let rebuilt = (f : String) => {
    let parts : Array[String] = f.split("/").map(x => x.to_string()).collect()
    for i in 1..<parts.length() {
      let at = parts[:i].iter().join("/")
      let r = match made.get(at) {
        Some(r) => r
        None => {
          let r = self.files.rebuildable(self.files.join([dir, at]))
          made[at] = r
          r
        }
      }
      if r {
        return true
      }
    }
    false
  }
  let entries : Array[String] = []
  let unique : Set[String] = Set([])
  for raw in listed.split("\u{0}") {
    let mut end = raw.length()
    while end > 0 && raw.unsafe_charcode_at(end - 1) == '/' {
      end -= 1
    }
    let f = raw.view(end_offset=end).to_string()
    if f == "" || rebuilt(f) || unique.contains(f) {
      continue
    }
    unique.add(f)
    entries.push(f)
  }
  let take = () => {
    for f in entries {
      let path = self.files.join([dir, f])
      guard self.files.lstat(path) is Some((k, _, _, _)) else { continue }
      // (a repository in it git lists: nothing of any name asked in a checkout)
      if k == "dir" {
        if !self.files.rebuildable(path) {
          self.tree(path, if depth + 1 > any_name_depth { depth + 1 } else { any_name_depth + 1 })
        }
      } else {
        self.add(path)
      }
    }
  }
  if kind == "dir" {
    if self.tally is Some(_) {
      self.whole(dotgit)
    } else {
      self.own_gits.push(dotgit)
    }
    take()
    return true
  }
  if kind != "file" {
    return false
  }
  let said = match (try Some(self.files.read(dotgit)) catch { _ => None }) {
    Some(Some(t)) => js_trim(t)
    _ => ""
  }
  let gitdir = if said.has_prefix("gitdir:") { Some(js_trim(said.view(start_offset=7).to_string())) } else { None }
  let worktree = match gitdir {
    Some(g) if self.files.absolute(g) => self.linked(dir)
    _ => None
  }
  match worktree {
    None => self.add(dotgit)
    Some(w) => self.gits.push(w)
  }
  take()
  true
}

///|
/// A linked worktree at `dir`, as it is made again elsewhere (carry-reference.ts `linked`); none without a remote or a
/// commit.
fn Gathering::linked(self : Gathering, dir : String) -> JValue? raise {
  // (a sizing fetches and bundles nothing: its `.git` file is counted, what git makes again there is not)
  if self.tally is Some(_) {
    return None
  }
  let remote = self.git(dir, ["remote", "get-url", "origin"])
  let head = self.git(dir, ["rev-parse", "--verify", "-q", "HEAD"])
  guard remote is Some(r) && r != "" && head is Some(h) && h != "" else { return None }
  let common = self.git(dir, ["rev-parse", "--git-common-dir"])
  let repo = match common {
    Some(c) => self.files.resolve_in(dir, c)
    None => dir
  }
  if !self.fetched.contains(repo) {
    self.fetched.add(repo)
    ignore(self.git(dir, ["fetch", "-q", "--no-write-fetch-head", "--prune", "origin"], timeout=120000.0))
  }
  let branch = self.git(dir, ["symbolic-ref", "--short", "-q", "HEAD"])
  let bundle = self.files.join([self.scratch, "\{self.gits.length()}.bundle"])
  self.files.remove(bundle)
  // (git refuses a bundle of nothing: every commit of it is on a remote already)
  let mut hash : String? = None
  if self.git(dir, ["bundle", "create", "-q", bundle, "HEAD", "--not", "--remotes"]) is Some(_) && self.files.exists(bundle) {
    guard self.files.hash(bundle) is Some(b) else { fail("ENOENT: no such file or directory, open '\{bundle}'") }
    hash = Some(b)
    self.bundles[b] = bundle
    guard self.files.lstat(bundle) is Some((_, size, _, _)) else { fail("ENOENT: no such file or directory, lstat '\{bundle}'") }
    self.bytes += size
  }
  Some(
    jobj([
      ("dir", str(dir)),
      ("remote", str(r)),
      ("branch", match branch { Some(b) if b != "" => str(b); _ => Null }),
      ("head", str(h)),
      ("bundle", jopt(hash)),
    ]),
  )
}

///|
/// The hashes the list before said, by path (a session's alone).
fn Gathering::read_before(self : Gathering, at : String) -> Unit raise {
  self.before = Map([])
  if !self.files.exists(at) {
    return
  }
  self.files.each_line(at, line => {
    guard (try Some(@jsjson.parse(line)) catch { _ => None }) is Some(f) else { return }
    if get(f, "hash") is Some(Str(h)) && get(f, "path") is Some(Str(p)) {
      self.before[@jsjson.sanitize_str(p)] = (num(get(f, "size")), num(get(f, "mtimeMs")), @jsjson.sanitize_str(h))
    }
  })
}

///|
/// The sessions of a workspace whose things go along (carry-reference.ts `sessionsIn`).
fn sessions_in(home : Bool, keys : Bool) -> String {
  if keys {
    "SELECT key, workspace, cwd, runtime, profile, runtime_session_id, archived_at FROM sessions WHERE key IN (SELECT value FROM json_each(?)) ORDER BY key"
  } else {
    let which = if home { "(ws = ? OR ws IS NULL)" } else { "ws = ?" }
    "SELECT key, workspace, cwd, runtime, profile, runtime_session_id, archived_at FROM sessions WHERE \{which} ORDER BY key"
  }
}

///|
/// carry-reference.ts `listFile`.
fn list_file(files : Files, scratch : String, key : String) -> String {
  files.join([scratch, "lists", short_hash(key) + ".jsonl"])
}

///|
/// carry-reference.ts `gather`: what goes along with the chats of `ws` (or the sessions `keys` alone), written in
/// `scratch`; what it answers (`Gathered`). `own`: the agent home's skills that are the station's own.
pub fn carry_gather(
  host : @host.Host,
  sep : String,
  data : String,
  db_path : String,
  ws : String,
  home : Bool,
  scratch : String,
  agent : String?,
  keys : Array[String]?,
  own : Array[String],
) -> JValue raise {
  let files : Files = { host, sep }
  let db = @sql.Db::attach(host, db_path, wait=30000)
  defer db.close()
  let g : Gathering = {
    files,
    data,
    scratch,
    gits: [],
    bundles: Map([]),
    fetched: Set([]),
    own_gits: [],
    bytes: 0.0,
    before: Map([]),
    seen: Set([]),
    list: None,
    under: Data,
    unreadable: [],
    unreadable_count: 0,
    tally: None,
    most: None,
    walked: 0,
  }
  files.mkdir(files.join([scratch, "lists"]))
  let sessions : Array[JValue] = []
  let skipped : Array[JValue] = []
  let mut total_files = 0
  let mut total_bytes = 0.0
  let real_data = files.real(data).unwrap_or(data)
  let rows = match keys {
    Some(k) => db.all(sessions_in(home, true), [Json::string(@jsjson.stringify(Arr(k.map(str))))])
    None => db.all(sessions_in(home, false), [Json::string(ws)])
  }
  let finder = @locate.Finder::new(host, sep)
  for s in rows {
    let key = field_str(s, "key").unwrap_or("")
    let workspace = field_str(s, "workspace").unwrap_or("")
    let runtime = field_str(s, "runtime").unwrap_or("")
    let at = list_file(files, scratch, key)
    g.read_before(at)
    g.seen = Set([])
    g.own_gits.clear()
    let list = ListFile::open(at)
    g.list = Some(list)
    // Its transcripts: each runtime session's, where the station keeps them, and a Claude one's subagents beside it.
    let ids : Array[@locate.Source] = []
    for r in db.all("SELECT id, profile, runtime FROM runtime_sessions WHERE session_key = ? ORDER BY at", [Json::string(key)]) {
      ids.push({ id: field_str(r, "id").unwrap_or(""), profile: field_str(r, "profile"), runtime: field_str(r, "runtime").unwrap_or(runtime) })
    }
    if field_str(s, "runtime_session_id") is Some(rsid) && !ids.iter().any(r => r.id == rsid) {
      ids.push({ id: rsid, profile: field_str(s, "profile"), runtime })
    }
    // (looked for first where the runtime resumes it: under the project of the room's real path)
    let places = session_places(field_str(s, "cwd"), workspace)
    let looked : Array[String] = []
    for p in places.map(p => files.real_of(p)) + places {
      if !looked.contains(p) {
        looked.push(p)
      }
    }
    let (found, _) = finder.sources(data, [], ids.filter(r => @locate.runtime_kind(r.runtime)), looked, anywhere=true)
    for t in found {
      let (path, kind) = t
      g.add(if files.exists(path) { path } else { path + ".zst" })
      if kind == "claude" {
        let name = path.view(start_offset=(path.rev_find(sep).unwrap_or(-1) + 1)).to_string()
        let id = if name.has_suffix(".jsonl") { name.view(end_offset=name.length() - 6).to_string() } else { name }
        g.whole(files.join([files.dir_of(path), id]))
      }
    }
    // An Antigravity CLI conversation's own store in its profile's home: what `session/load` takes it up from.
    g.cli_kept_of(ids)
    // Its room, whole (an archived one's workspace packed in it): one that is not the station's goes nowhere.
    let room = files.room_for(data, real_data, workspace)
    match room {
      None => skipped.push(str(key))
      Some(dir) => g.room_walk(dir)
    }
    // (its own repositories last, as the fetches of its linked worktrees left them)
    for dotgit in g.own_gits {
      g.whole(dotgit)
    }
    g.list = None
    let hash = list.close(files)
    sessions.push(
      jobj([
        ("key", str(key)),
        ("workspace", str(workspace)),
        ("room", jopt(room)),
        ("list", str(hash)),
        ("files", jnum(list.files.to_double())),
        ("bytes", jnum(list.bytes)),
        ("at", str(at)),
      ]),
    )
    total_files += list.files
    total_bytes += list.bytes
  }
  // The agent home's own files, a list as a session's.
  let mut carried_home : JValue = Null
  if agent is Some(dir) && files.exists(dir) {
    let at = files.join([scratch, "lists", "agent-home.jsonl"])
    g.read_before(at)
    g.seen = Set([])
    let list = ListFile::open(at)
    g.list = Some(list)
    g.under = Home(dir)
    home_files(files, dir, own, path => g.add(path))
    g.list = None
    let hash = list.close(files)
    carried_home = jobj([
      ("dir", str(dir)),
      ("list", str(hash)),
      ("files", jnum(list.files.to_double())),
      ("bytes", jnum(list.bytes)),
      ("at", str(at)),
    ])
    total_files += list.files
    total_bytes += list.bytes
  }
  total_bytes += g.bytes
  let bundles : Array[(String, JValue)] = []
  for h, path in g.bundles {
    bundles.push((h, str(path)))
  }
  let index = jobj([
    ("v", jnum(2.0)),
    ("dataDir", str(data)),
    ("sessions", Arr(sessions)),
    ("gits", Arr(g.gits)),
    ("skipped", Arr(skipped)),
    ("jobs", Arr([])),
    ("bundles", jobj(bundles)),
    ("files", jnum(total_files.to_double())),
    ("bytes", jnum(total_bytes)),
    ("agent", carried_home),
  ])
  let path = files.join([scratch, "index.json"])
  ignore(files.write(path, @jsjson.stringify(index)))
  let answer = [
    ("index", str(path)),
    ("files", jnum(total_files.to_double())),
    ("bytes", jnum(total_bytes)),
    ("gits", jnum(g.gits.length().to_double())),
    ("skipped", jnum(skipped.length().to_double())),
  ]
  if g.unreadable_count > 0 {
    answer.push(("unreadable", Arr(g.unreadable.map(str))))
    answer.push(("unreadableCount", jnum(g.unreadable_count.to_double())))
  }
  if looking.val is Some(seen) {
    answer.push(("looked", Arr(seen.map(e => Arr([str(e.0), str(e.1)])))))
  }
  jobj(answer)
}

///|
/// carry-reference.ts `sizes`: sessions `keys` sized as a move would gather them (the same walk, each file's size added,
/// nothing hashed, listed or written; at most `most` entries a session, past which it is said at least); with `places`
/// (the other station's side: a session's room and transcripts as they would be here), what this station has there.
pub fn carry_sizes(
  host : @host.Host,
  sep : String,
  data : String,
  db_path : String,
  keys : Array[String],
  most : Int,
  places : Array[(String, String?, Array[String])]?,
) -> JValue raise {
  let files : Files = { host, sep }
  let g : Gathering = {
    files,
    data,
    scratch: "",
    gits: [],
    bundles: Map([]),
    fetched: Set([]),
    own_gits: [],
    bytes: 0.0,
    before: Map([]),
    seen: Set([]),
    list: None,
    under: Data,
    unreadable: [],
    unreadable_count: 0,
    tally: None,
    most: Some(most),
    walked: 0,
  }
  let out : Array[JValue] = []
  let sized = (key : String, room : String?, tplaces : Array[String], t : Tally, complete : Bool) => jobj([
    ("key", str(key)),
    ("room", jopt(room)),
    ("transcripts", Arr(tplaces.map(str))),
    ("bytes", jnum(t.bytes)),
    ("files", jnum(t.files.to_double())),
    ("complete", Bool(complete)),
  ])
  // The other station's side: what it has where each session's things would go.
  if places is Some(ps) {
    for p in ps {
      let (key, room, transcripts) = p
      g.seen = Set([])
      g.walked = 0
      let t : Tally = { files: 0, bytes: 0.0 }
      g.tally = Some(t)
      let mut complete = true
      try {
        for i, at in transcripts {
          if i >= 64 {
            break
          }
          match files.lstat(at) {
            Some(("dir", _, _, _)) => g.whole(at)
            Some(_) => g.add(at)
            None => ()
          }
        }
        if room is Some(r) {
          g.room_walk(r)
        }
      } catch {
        Cut => complete = false
        e => raise e
      }
      g.tally = None
      out.push(sized(key, room, transcripts, t, complete))
    }
    return Arr(out)
  }
  let db = @sql.Db::attach(host, db_path, wait=30000)
  defer db.close()
  let real_data = files.real(data).unwrap_or(data)
  let finder = @locate.Finder::new(host, sep)
  let rows = db.all(sessions_in(false, true), [Json::string(@jsjson.stringify(Arr(keys.map(str))))])
  for s in rows {
    let key = field_str(s, "key").unwrap_or("")
    let workspace = field_str(s, "workspace").unwrap_or("")
    let runtime = field_str(s, "runtime").unwrap_or("")
    g.seen = Set([])
    g.walked = 0
    let t : Tally = { files: 0, bytes: 0.0 }
    g.tally = Some(t)
    let tplaces : Array[String] = []
    let mut complete = true
    try {
      let ids : Array[@locate.Source] = []
      for r in db.all("SELECT id, profile, runtime FROM runtime_sessions WHERE session_key = ? ORDER BY at", [Json::string(key)]) {
        ids.push({ id: field_str(r, "id").unwrap_or(""), profile: field_str(r, "profile"), runtime: field_str(r, "runtime").unwrap_or(runtime) })
      }
      if field_str(s, "runtime_session_id") is Some(rsid) && !ids.iter().any(r => r.id == rsid) {
        ids.push({ id: rsid, profile: field_str(s, "profile"), runtime })
      }
      let places = session_places(field_str(s, "cwd"), workspace)
      let looked : Array[String] = []
      for p in places.map(p => files.real_of(p)) + places {
        if !looked.contains(p) {
          looked.push(p)
        }
      }
      let (found, _) = finder.sources(data, [], ids.filter(r => @locate.runtime_kind(r.runtime)), looked, anywhere=true)
      for f in found {
        let (path, kind) = f
        let at = if files.exists(path) { path } else { path + ".zst" }
        g.add(at)
        if tplaces.length() < 64 {
          tplaces.push(at)
        }
        if kind == "claude" {
          let name = path.view(start_offset=(path.rev_find(sep).unwrap_or(-1) + 1)).to_string()
          let id = if name.has_suffix(".jsonl") { name.view(end_offset=name.length() - 6).to_string() } else { name }
          let sub = files.join([files.dir_of(path), id])
          g.whole(sub)
          if tplaces.length() < 64 {
            tplaces.push(sub)
          }
        }
      }
      g.cli_kept_of(ids)
      if files.room_for(data, real_data, workspace) is Some(dir) {
        g.room_walk(dir)
      }
    } catch {
      Cut => complete = false
      e => raise e
    }
    g.tally = None
    out.push(sized(key, files.room_for(data, real_data, workspace), tplaces, t, complete))
  }
  Arr(out)
}

///|
/// A session's room, whole (an archived one's workspace packed in it).
fn Gathering::room_walk(self : Gathering, dir : String) -> Unit raise {
  let entries = self.files.listing(dir).unwrap_or([])
  let here = names_of(entries)
  for e in entries {
    // (its lock, and what is being written as it is looked at, stay)
    if e.0 == "archive.lock" || e.0.has_suffix(".writing") {
      continue
    }
    let path = self.files.join([dir, e.0])
    if e.1 == "dir" {
      if rebuilt_by_name(e.0, here) == 0 {
        self.tree(path, 1)
      }
    } else {
      self.add(path)
    }
  }
}

///|
/// carry-reference.ts `homeFiles`: the files of an agent home that go along, each given to `each` in its order.
fn home_files(files : Files, agent : String, own : Array[String], each : (String) -> Unit raise) -> Unit raise {
  let file = (path : String) => if files.lstat(path) is Some(("file", _, _, _)) { each(path) }
  file(files.join([agent, "MEMORY.md"]))
  file(files.join([agent, "presets.json"]))
  let skills = files.join([agent, "skills"])
  fn walk(dir : String) -> Unit raise {
    let entries = files.listing(dir).unwrap_or([])
    let here = names_of(entries)
    for e in entries {
      let path = files.join([dir, e.0])
      if e.1 == "dir" {
        if rebuilt_by_name(e.0, here) == 0 {
          walk(path)
        }
      } else if e.1 == "file" {
        each(path)
      }
    }
  }
  for e in files.listing(skills).unwrap_or([]) {
    let name = e.0
    if name.has_prefix(".") || name == "synced" || own.contains(name) || e.1 != "dir" {
      continue
    }
    walk(files.join([skills, name]))
  }
}

///|
/// carry-reference.ts `preview`: how many chats of `ws`, archived or not, and how many have a directory that is not the
/// station's own.
pub fn carry_preview(host : @host.Host, sep : String, data : String, db_path : String, ws : String, home : Bool) -> JValue raise {
  let files : Files = { host, sep }
  let db = @sql.Db::attach(host, db_path, wait=30000)
  defer db.close()
  let real_data = files.real(data).unwrap_or(data)
  let mut chats = 0
  let mut archived = 0
  let mut outside = 0
  for s in db.all(sessions_in(home, false), [Json::string(ws)]) {
    match s.get("archived_at") {
      Some(Null) | None => chats += 1
      _ => archived += 1
    }
    if files.room_for(data, real_data, field_str(s, "workspace").unwrap_or("")) is None {
      outside += 1
    }
  }
  jobj([("chats", jnum(chats.to_double())), ("archived", jnum(archived.to_double())), ("outside", jnum(outside.to_double()))])
}

// ---- the placing ----

///|
/// restore.ts `carriedTo`: a path the other station said, as it is here; a Claude transcript of a chat handed over
/// under the project of its room here (`room`, its real path).
fn carried_to(files : Files, path : String, from : String, to : String, room : String?) -> String {
  let at = moved(files, path, from, to)
  let project = match room {
    Some(r) => @locate.claude_project(r)
    None => None
  }
  guard project is Some(p) && from != "" && at != path else { return at }
  let t = if to.has_suffix(files.sep) { to.view(end_offset=to.length() - files.sep.length()).to_string() } else { to }
  let parts = []
  let rest = at.view(start_offset=t.length() + 1).to_string()
  let mut start = 0
  for i in 0..<rest.length() {
    let c = rest.unsafe_charcode_at(i)
    if c == '/' || c == '\\' {
      parts.push(rest.view(start_offset=start, end_offset=i).to_string())
      start = i + 1
    }
  }
  parts.push(rest.view(start_offset=start).to_string())
  if parts.length() < 4 || !parts[0].has_prefix("transcripts") || parts[1] != "claude" {
    return at
  }
  parts[2] = p
  files.join([t, ..parts])
}

///|
/// carry-reference.ts `putFile`: a file sent put at `tmp` linked to it where nothing else is linked to it yet, else
/// copied (two paths never share a file).
fn put_file(files : Files, blob : String, tmp : String) -> Unit raise {
  let links = nlink_ffi(c_path(blob))
  if links < 0 {
    fail("ENOENT: no such file or directory, lstat '\{blob}'")
  }
  if links == 1 {
    match link_ffi(c_path(blob), c_path(tmp)) {
      0 => return
      1 => ()
      _ => fail("cannot link '\{blob}' -> '\{tmp}'")
    }
  }
  files.copy(blob, tmp)
}

///|
priv struct Placing {
  files : Files
  ours : Set[String]
  known : Map[String, String]
  placed_out : Writer?
  made_out : Writer?
  aside : String?
}

///|
fn same_of(hash : String, size : Double, mtime : Double) -> String {
  "\{hash}\t\{@jsjson.stringify(Num(size))}\t\{@jsjson.stringify(Num(@math.trunc(mtime)))}"
}

///|
fn Placing::fresh(self : Placing, path : String) -> Unit raise {
  self.ours.add(path)
  if self.made_out is Some(w) {
    w.put(path + "\n")
  }
}

///|
fn Placing::away(self : Placing, path : String) -> Unit raise {
  guard self.aside is Some(aside) && !self.ours.contains(path) else {
    self.files.remove(path, recursive=true)
    return
  }
  self.files.mkdir(aside)
  let name = short_hash(path) + "-" + self.files.random(4)
  self.files.rename(path, self.files.join([aside, name]))
  let w = Writer::open(self.files.join([aside, "list.txt"]), true)
  defer w.close()
  w.put("\{path}\t\{name}\n")
  self.ours.add(path)
}

///|
fn Placing::now(self : Placing, path : String, same : String) -> Unit raise {
  if self.placed_out is Some(w) && self.known.get(path) != Some(same) {
    w.put("\{path}\t\{same}\n")
  }
}

///|
/// carry-reference.ts `place`: what the index at `index_path` says put under this station's data directory `data`, each
/// list and each file's bytes read from `from`; `{placed, missing, kept}`.
pub fn carry_place(
  host : @host.Host,
  sep : String,
  data : String,
  index_path : String,
  from : String,
  made : String?,
  aside : String?,
  placed : String?,
  projects : Bool,
) -> JValue raise {
  let files : Files = { host, sep }
  guard files.read(index_path) is Some(text) else { fail("ENOENT: no such file or directory, open '\{index_path}'") }
  let index = @jsjson.parse(text)
  // (what is there that is this placing's own already, made or put aside before: replaced, not put aside again)
  let ours : Set[String] = Set([])
  for at in [made, aside.map(a => files.join([a, "list.txt"]))] {
    if at is Some(p) && files.exists(p) {
      files.each_line(p, line => {
        let cut = line.find("\t").unwrap_or(line.length())
        ours.add(line.view(end_offset=cut).to_string())
      })
    }
  }
  let known : Map[String, String] = Map([])
  if placed is Some(p) && files.exists(p) {
    files.each_line(p, line => {
      if line.find("\t") is Some(tab) && tab > 0 {
        known[line.view(end_offset=tab).to_string()] = line.view(start_offset=tab + 1).to_string()
      }
    })
  }
  let placed_out = match placed {
    Some(p) => Some(Writer::open(p, true))
    None => None
  }
  let made_out = match made {
    Some(p) => Some(Writer::open(p, true))
    None => None
  }
  let p : Placing = { files, ours, known, placed_out, made_out, aside }
  let closing = () => {
    if made_out is Some(w) {
      w.close()
    }
    if placed_out is Some(w) {
      w.close()
    }
  }
  defer closing()
  let mut n_placed = 0
  let mut missing = 0
  let mut kept = 0
  let root = files.resolve(data)
  let was = text_of(get(index, "dataDir")).unwrap_or("")
  let sessions = match get(index, "sessions") {
    Some(Arr(items)) => items
    _ => []
  }
  for s in sessions {
    let list = files.join([from, text_of(get(s, "list")).unwrap_or("")])
    // (a chat handed over: its Claude transcripts under the project of its room here as the runtime sees it)
    let room = if projects { Some(files.real_of(moved(files, text_of(get(s, "workspace")).unwrap_or(""), was, data))) } else { None }
    if !files.exists(list) {
      missing += num(get(s, "files")).to_int()
      continue
    }
    files.each_line(list, line => {
      guard (try Some(@jsjson.parse(line)) catch { _ => None }) is Some(f) else { return }
      let given = text_of(get(f, "path")).unwrap_or("")
      // (resolved first: a path the other station said is put under this one's sessions or transcripts, or nowhere)
      let path = files.resolve(if projects { carried_to(files, given, was, data, room) } else { moved(files, given, was, data) })
      if !files.carried_place(root, path) {
        return
      }
      let link = match f {
        Obj(entries) => entries.iter().any(e => e.0 == "link")
        _ => false
      }
      let hash = text_of(get(f, "hash")).unwrap_or("")
      let size = num(get(f, "size"))
      let mtime = num(get(f, "mtimeMs"))
      let same = same_of(hash, size, mtime)
      // (placed by this placing before as the index says it now: not looked at again)
      if !link && p.known.get(path) == Some(same) {
        kept += 1
        return
      }
      let there = files.lstat(path)
      if link {
        let given_link = text_of(get(f, "link")).unwrap_or("")
        let target = if files.absolute(given_link) { moved(files, given_link, was, data) } else { given_link }
        if there is Some((kind, _, _, _)) {
          if kind == "link" && files.read_link(path) == target {
            kept += 1
            return
          }
          p.away(path)
        }
        files.mkdir(files.dir_of(path))
        ignore(files.call("fs.symlink", { "target": Json::string(target), "path": Json::string(path) }))
        if there is None {
          p.fresh(path)
        }
        n_placed += 1
        return
      }
      if there is Some((kind, tsize, _, tmtime)) &&
        kind == "file" &&
        tsize == size &&
        (@math.trunc(tmtime) == @math.trunc(mtime) || files.hash(path) == Some(hash)) {
        p.now(path, same)
        kept += 1
        return
      }
      let blob = files.join([from, hash])
      if !files.exists(blob) {
        missing += 1
        return
      }
      files.mkdir(files.dir_of(path))
      let tmp = "\{path}.\{files.random(4)}.carrying"
      put_file(files, blob, tmp)
      ignore(files.call("fs.chmod", { "path": Json::string(tmp), "mode": Json::number(num(get(f, "mode"))) }))
      if utimes_ffi(c_path(tmp), mtime / 1000.0) != 0 {
        fail("cannot set the times of '\{tmp}'")
      }
      if there is Some(_) {
        p.away(path)
      }
      files.rename(tmp, path)
      if there is None {
        p.fresh(path)
      }
      p.now(path, same)
      n_placed += 1
    })
  }
  jobj([("placed", jnum(n_placed.to_double())), ("missing", jnum(missing.to_double())), ("kept", jnum(kept.to_double()))])
}
