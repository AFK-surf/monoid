// The size of a directory on disk (station/src/sessions/footprint.ts, which starts this as `--builder footprint`, one
// process a measure, under the system's background priority): line for line what station/test/footprint-reference.ts
// (the main thread's walk from before, station/src/ops/walk.ts `walkBounded` with `stat`) counts, which
// station/test/mb-footprint.test.ts holds it to. A workspace's files, each counted once by its blocks however many
// links it has, on its root's file system, no link followed, within a budget of entries and time all its walks share;
// with `finding`, what a build or an install makes again listed with its size (each counted whole, not looked into for
// more), never in a `.git` or `uploads`. The system's calls are footprint.c's, an entry at a time.

///|
#borrow(path, out)
extern "C" fn lstat_ffi(path : Bytes, out : FixedArray[Int64]) -> Int = "sff_lstat"

///|
#borrow(path, err)
extern "C" fn list_ffi(path : Bytes, err : FixedArray[Int]) -> Bytes = "sff_list"

///|
#borrow(path)
extern "C" fn exists_ffi(path : Bytes) -> Int = "sff_exists"

///|
#borrow(path)
extern "C" fn dir_ffi(path : Bytes) -> Int = "sff_dir"

///|
#borrow(path, err)
extern "C" fn head_ffi(path : Bytes, most : Int, err : FixedArray[Int]) -> Bytes = "sff_head"

///|
/// How far up a MoonBit manifest is looked for above a `_build` (footprint.ts MANIFEST_UP).
let manifest_up = 8

///|
/// The first bytes of a file looked at (footprint.ts HEAD_BYTES).
let head_bytes = 512

///|
/// What Cargo writes in its target directory's CACHEDIR.TAG (footprint.ts CARGO_TAG).
let cargo_tag : Array[String] = [
  "Signature: 8a477f597d28d172789f06886806bc55", "# This file is a cache directory tag created by cargo.",
]

///|
/// How deep a walk goes below its root (ops/walk.ts WALK_MAX_DEPTH).
let max_depth = 32

///|
/// What footprint.c's lstat says an entry is (out[0]).
let kind_dir = 2L

///|
/// What footprint.c says failed: Node's code and libuv's words for it.
fn error_of(code : Int) -> (String, String) {
  match code {
    1 => ("ENOENT", "no such file or directory")
    2 => ("EACCES", "permission denied")
    3 => ("EPERM", "operation not permitted")
    4 => ("ENOTDIR", "not a directory")
    5 => ("ELOOP", "too many symbolic links encountered")
    6 => ("ENAMETOOLONG", "name too long")
    _ => ("EIO", "i/o error")
  }
}

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
/// A measure cut short as its limit (`stopAfter`) was passed: what it counted by then.
priv suberror Enough {
  Enough(Double)
}

///|
/// Its words where it is said (`to_string`, a notice, a log): not its type's name (`station/<package>.<Type>`).
impl Show for Enough with output(self, logger) {
  match self {
    Enough(_) => logger.write_string("the measure passed its limit")
  }
}

///|
/// An error of the file system a strict measure does not pass over: its code and Node's message.
pub suberror Failed {
  Failed(String, String)
}

///|
/// Its words as they are where it is said (`to_string`), not its type's name.
pub impl Show for Failed with output(self, logger) {
  match self {
    Failed(_, m) => logger.write_string(m)
  }
}

///|
/// What a visit says of an entry (ops/walk.ts `Visit`).
priv enum Visit {
  Go
  Skip
  Stop
}

///|
/// A directory to list: where it is listed (its root as given), where its entries are joined onto (normalized), how
/// deep, and its root's device.
priv struct Pending {
  path : String
  base : String
  depth : Int
  dev : Int64
}

///|
priv struct Measure {
  sep : String
  /// The most entries all the walks visit together (none: Infinity).
  most : Double
  /// When the budget's time is up, on the program's clock that never goes back.
  until : Int64
  stop_after : Double?
  strict : Bool
  /// The files with more than one name counted, by (dev, ino).
  seen : Set[(Int64, Int64)]
  mut total : Double
  mut bytes : Double
  mut visited : Double
  mut cut : String?
  found : Array[(String, Double)]?
  stat : FixedArray[Int64]
  err : FixedArray[Int]
}

///|
/// `seen.bytes` of footprint-reference.ts: a file's blocks, once however many names it has.
fn Measure::count(self : Measure) -> Double raise Enough {
  if self.stat[3] > 1L {
    let id = (self.stat[1], self.stat[2])
    if self.seen.contains(id) {
      return 0.0
    }
    self.seen.add(id)
  }
  let bytes = self.stat[4].to_double() * 512.0
  self.total += bytes
  if self.stop_after is Some(most) && self.total > most {
    raise Enough(self.total)
  }
  bytes
}

///|
/// An error of the file system as the walk's `onError`: passed over, or a strict measure's end (but a path gone).
fn Measure::failed(self : Measure, code : Int, op : String, path : String) -> Unit raise Failed {
  if !self.strict || code == 1 {
    return
  }
  let (name, words) = error_of(code)
  raise Failed(name, "\{name}: \{words}, \{op} '\{path}'")
}

///|
fn Measure::join(self : Measure, base : String, name : String) -> String {
  if base == "." {
    name
  } else if base.has_suffix(self.sep) || (self.sep == "\\" && base.has_suffix("/")) {
    base + name
  } else {
    base + self.sep + name
  }
}

///|
/// Node's dirname of `p` (its last name taken off), as footprint.ts climbs: `p` itself at a root or with no separator.
fn Measure::up(self : Measure, p : String) -> String {
  let is_sep = (c : Char) => c.to_string() == self.sep ||
    (self.sep == "\\" && c == '/')
  let chars = p.to_array()
  let mut end = chars.length()
  while end > 1 && is_sep(chars[end - 1]) {
    end -= 1
  }
  let mut i = end - 1
  while i >= 0 && !is_sep(chars[i]) {
    i -= 1
  }
  if i < 0 {
    return if self.sep == "\\" && end >= 2 && chars[1] == ':' { p } else { "." }
  }
  let mut cut = i
  while cut > 0 && is_sep(chars[cut - 1]) {
    cut -= 1
  }
  let head = String::from_array(chars[0:cut].to_owned())
  if head == "" {
    self.sep
  } else if self.sep == "\\" && head.length() == 2 && head.has_suffix(":") {
    head + self.sep
  } else {
    head
  }
}

///|
/// footprint.ts `moonAbove`: a MoonBit manifest in `from` or above it within its checkout (to the directory with
/// `.git`, at most `manifest_up` up); outside a checkout only in `from` itself.
fn Measure::moon_above(self : Measure, from : String) -> Bool {
  let there = (at : String, file : String) => exists_ffi(c_path(self.join(at, file))) != 0
  let mut found = false
  let mut p = from
  for i = 0; i < manifest_up; i = i + 1 {
    for m in ["moon.mod.json", "moon.work", "moon.pkg.json"] {
      if !there(p, m) {
        continue
      }
      if p == from {
        return true
      }
      found = true
    }
    if there(p, ".git") {
      return found
    }
    let next = self.up(p)
    if next == p {
      break
    }
    p = next
  }
  false
}

///|
/// Whether the text of a CACHEDIR.TAG has Cargo's lines (footprint.ts: split at `\r?\n`, each line whole).
fn cargo_said(text : String) -> Bool {
  let pieces : Array[String] = text.split("\n").map(l => l.to_string()).collect()
  let lines = pieces.mapi((k, t) => if k < pieces.length() - 1 && t.has_suffix("\r") {
    t.view(end_offset=t.length() - 1).to_string()
  } else {
    t
  })
  cargo_tag.iter().all(l => lines.contains(l))
}

///|
/// test/footprint-reference.ts `rebuildableKind` (footprint.ts `decide`, look for look): a directory a build or an install makes again, by its
/// name and what is beside it, by what is near it (Elixir's, MoonBit's), or of any name by what is in it (Xcode's
/// derived data, a Cargo target). `parent` is where it is (its entries joined onto it), `path` it.
fn Measure::rebuildable(
  self : Measure,
  parent : String,
  name : String,
  path : String,
) -> Bool {
  let beside = (file : String) => exists_ffi(c_path(self.join(parent, file))) != 0
  let dir = (at : String) => dir_ffi(c_path(at)) != 0
  match name {
    "node_modules" | ".next" | ".turbo" | "__pycache__" => return true
    "target" => if beside("Cargo.toml") { return true }
    ".gradle" =>
      if beside("settings.gradle") ||
        beside("settings.gradle.kts") ||
        beside("build.gradle") ||
        beside("build.gradle.kts") {
        return true
      }
    "build" =>
      if beside("build.gradle") || beside("build.gradle.kts") {
        return true
      }
    "_build" =>
      if beside("mix.exs") || self.moon_above(parent) {
        return true
      }
    "deps" => if beside("mix.exs") { return true }
    ".mooncakes" =>
      if beside("moon.mod.json") || beside("moon.work") {
        return true
      }
    _ => ()
  }
  let build = self.join(path, "Build")
  if dir(self.join(build, "Products")) &&
    dir(self.join(build, "Intermediates.noindex")) {
    return true
  }
  let err = FixedArray::make(1, 0)
  let head = head_ffi(c_path(self.join(path, "CACHEDIR.TAG")), head_bytes, err)
  if err[0] != 0 || !cargo_said(@utf8.decode_lossy(head[:])) {
    return false
  }
  if exists_ffi(c_path(self.join(path, ".rustc_info.json"))) != 0 {
    return true
  }
  for profile in ["debug", "release"] {
    for own in ["deps", ".fingerprint"] {
      if dir(self.join(self.join(path, profile), own)) {
        return true
      }
    }
  }
  false
}

///|
/// The measure's visit of an entry (its lstat in `self.stat`), counting it against the budget all walks share.
fn Measure::visit(
  self : Measure,
  path : String,
  parent : String,
  name : String,
  depth : Int,
  dir : Bool,
  finding : Bool,
) -> Visit raise {
  self.visited += 1.0
  if self.visited > self.most {
    if self.cut is None {
      self.cut = Some("entries")
    }
    return Stop
  }
  if finding && depth > 0 && dir {
    // Never discover cleanup candidates in repository metadata or historical attachments.
    if name == ".git" || name == "uploads" {
      self.walk(path, path, false)
      return if self.cut is Some(_) { Stop } else { Skip }
    }
    if self.rebuildable(parent, name, path) {
      let before = self.bytes
      self.walk(path, path, false)
      if self.found is Some(found) {
        found.push((path, self.bytes - before))
      }
      return if self.cut is Some(_) { Stop } else { Skip }
    }
  }
  self.bytes += self.count()
  Go
}

///|
/// One walk (ops/walk.ts `walkBounded` with `stat`, its own entries unbounded): breadth first from `root` (listed as
/// given, its entries joined onto `base`), on its file system, no link followed, at most `max_depth` below it, until the
/// budget's time. Why it ended short, but for a visit's stop, is the measure's `cut` unless one was already.
fn Measure::walk(self : Measure, root : String, base : String, finding : Bool) -> Unit raise {
  // (a walk of what a measure found is given what time is left, none less than nothing)
  let started = @host.now()
  let until = if self.until > started { self.until } else { started }
  let short = (why : String) => if self.cut is None { self.cut = Some(why) }
  if @host.now() > until {
    return short("duration")
  }
  let code = lstat_ffi(c_path(root), self.stat)
  if code != 0 {
    return self.failed(code, "lstat", root)
  }
  let dir = self.stat[0] == kind_dir
  let dev = self.stat[1]
  match self.visit(root, "", "", 0, dir, finding) {
    Stop => return
    Skip => return
    Go => if !dir { return }
  }
  let queue = [{ path: root, base, depth: 0, dev }]
  let mut head = 0
  let mut deeper = false
  while head < queue.length() {
    let at = queue[head]
    head += 1
    if @host.now() > until {
      return short("duration")
    }
    let listed = list_ffi(c_path(at.path), self.err)
    if self.err[0] != 0 {
      self.failed(self.err[0], "scandir", at.path)
      continue
    }
    let mut start = 0
    for i = 0; i < listed.length(); i = i + 1 {
      if listed[i] != b'\x00' {
        continue
      }
      let name = @utf8.decode_lossy(listed[start:i])
      start = i + 1
      if @host.now() > until {
        return short("duration")
      }
      let path = self.join(at.base, name)
      let depth = at.depth + 1
      let code = lstat_ffi(c_path(path), self.stat)
      if code != 0 {
        self.failed(code, "lstat", path)
        continue
      }
      let dir = self.stat[0] == kind_dir
      let its = self.stat[1]
      match self.visit(path, at.base, name, depth, dir, finding) {
        Stop => return
        Skip => continue
        Go => if !dir { continue }
      }
      // (another file system mounted in it: listed, not gone into)
      if its != at.dev {
        continue
      }
      if depth >= max_depth {
        deeper = true
        continue
      }
      queue.push({ path, base: path, depth, dev: at.dev })
    }
  }
  if deeper {
    short("depth")
  }
}

///|
/// One measure, as footprint.ts asks it (a line of JSON): `path` (and `base`, it normalized), `finding`, `strict`,
/// `stopAfter`, `maxEntries` (none: Infinity), `maxDurationMs`. Answered `{size, complete, reason?, rebuild?}` (its
/// bytes said `size`: a line that says `bytes` has a body after it, mb-reader.ts `Said`), or `{size, complete: false,
/// enough: true}` once it counted past `stopAfter`, or `{error, code}`.
pub fn answer(line : String, sep : String) -> Json {
  let ask : Json = @json.parse(line) catch {
    _ => return { "error": Json::string("not JSON"), "code": Json::string("EINVAL") }
  }
  guard ask is Object(m) else {
    return { "error": Json::string("not an object"), "code": Json::string("EINVAL") }
  }
  let text = (name : String) => match m.get(name) {
    Some(String(s)) => Some(s)
    _ => None
  }
  let number = (name : String) => match m.get(name) {
    Some(Number(n, ..)) => Some(n)
    _ => None
  }
  let yes = (name : String) => m.get(name) is Some(True)
  guard text("path") is Some(path) else {
    return { "error": Json::string("path is required"), "code": Json::string("EINVAL") }
  }
  let base = text("base").unwrap_or(path)
  let finding = yes("finding")
  let ms = number("maxDurationMs").unwrap_or(60000.0)
  let measure : Measure = {
    sep,
    most: number("maxEntries").unwrap_or(@double.infinity),
    until: @host.now() + (if ms > 0.0 { ms.to_int64() } else { 0L }),
    stop_after: number("stopAfter"),
    strict: yes("strict"),
    seen: Set([]),
    total: 0.0,
    bytes: 0.0,
    visited: 0.0,
    cut: None,
    found: if finding { Some([]) } else { None },
    stat: FixedArray::make(5, 0L),
    err: FixedArray::make(1, 0),
  }
  try measure.walk(path, base, finding) catch {
    Enough(bytes) => return { "size": Json::number(bytes), "complete": false, "enough": true }
    Failed(code, message) => return { "error": Json::string(message), "code": Json::string(code) }
    e => return { "error": Json::string(e.to_string()), "code": Json::string("EIO") }
  }
  let out : Map[String, Json] = { "size": Json::number(measure.bytes), "complete": Json::boolean(measure.cut is None) }
  if measure.cut is Some(why) {
    out["reason"] = Json::string(why)
  }
  if measure.found is Some(found) {
    out["rebuild"] = Json::array(found.map(f => Json::array([Json::string(f.0), Json::number(f.1)])))
  }
  Json::object(out)
}
