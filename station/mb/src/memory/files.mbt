// The memory's files as they are and its blobs (station/src/share/memory.ts `#read`, `#content`, `#keepBlob`, as they
// were before they moved here): read, hashed and kept by the shell (`fs.*`), none of their bytes the station's.

///|
/// What failed of the files where memory.ts failed as well (a file gone as it was read).
pub suberror Failed {
  Failed(String)
}

///|
/// Its words as they are where it is said (`to_string`), not its type's name.
pub impl Show for Failed with output(self, logger) {
  match self {
    Failed(m) => logger.write_string(m)
  }
}

///|
/// The shell's answer to `op` (its value).
async fn fs(host : @host.Host, op : String, args : Map[String, Json], bytes? : Bytes) -> Json {
  let (json, _) = match bytes {
    Some(b) => host.shell(op, Json::object(args), bytes=b)
    None => host.shell(op, Json::object(args))
  }
  json
}

///|
/// What lstat says of `path`: its kind, size, mode and mtimeMs; None when nothing is there.
priv struct Stat {
  kind : String
  size : Double
  mode : Int
  mtime : Double
}

///|
async fn lstat(host : @host.Host, path : String) -> Stat? {
  let v = fs(host, "fs.lstat", { "path": Json::string(path) })
  guard str_field(v, "kind") is Some(kind) else { return None }
  Some({
    kind,
    size: num_field(v, "size").unwrap_or(0),
    mode: num_field(v, "mode").unwrap_or(0).to_int(),
    mtime: num_field(v, "mtimeMs").unwrap_or(0),
  })
}

///|
/// A directory's names and kinds ("file", "dir", "link", "other"), in Node's readdir's order; None when it cannot be
/// read.
async fn readdir(host : @host.Host, path : String) -> Array[(String, String)]? {
  let v = fs(host, "fs.readdir", { "path": Json::string(path), "types": Json::boolean(true) })
  guard v is Array(xs) else { return None }
  let out = []
  for x in xs {
    if x is Array(pair) && pair.get(0) is Some(String(name)) && pair.get(1) is Some(String(kind)) {
      out.push((name, kind))
    }
  }
  Some(out)
}

///|
/// A file's SHA-256 (hex); None when it does not read.
async fn hash_of(host : @host.Host, path : String) -> String? {
  let v = fs(host, "fs.hash", { "path": Json::string(path) }) catch { _ => return None }
  match v {
    String(h) => Some(h)
    _ => None
  }
}

///|
/// A file's bytes; None when it does not open.
async fn bytes_of(host : @host.Host, path : String) -> Bytes? {
  let v = fs(host, "fs.bytes", { "path": Json::string(path) }) catch { _ => return None }
  guard v is String(hex) else { return None }
  Some(@hex.decode(hex)) catch {
    _ => None
  }
}

///|
/// The memory's blobs (`<data>/share/memory/blobs`), its content kept by hash.
pub struct Blobs {
  host : @host.Host
  dir : String
  sep : String
  mut made : Int
}

///|
pub fn Blobs::new(host : @host.Host, dir : String, sep : String) -> Blobs {
  { host, dir, sep, made: 0 }
}

///|
fn Blobs::path(self : Blobs, hash : String) -> String {
  self.dir + self.sep + hash
}

///|
/// What is kept of version `hash`, when its bytes are that version's (memory.ts `#content`).
pub async fn Blobs::content(self : Blobs, hash : String) -> Bytes? {
  if hash == "" {
    return None
  }
  let path = self.path(hash)
  guard hash_of(self.host, path) is Some(h) && h == hash else { return None }
  guard bytes_of(self.host, path) is Some(bytes) else { return None }
  Some(bytes)
}

///|
/// Whether version `hash` is kept (and is that version).
pub async fn Blobs::has(self : Blobs, hash : String) -> Bool {
  hash != "" && hash_of(self.host, self.path(hash)) is Some(h) && h == hash
}

///|
/// A temporary file of the blobs' own: a private one, its bytes on the disk before it is named.
async fn Blobs::temp(self : Blobs, write : async (String) -> Unit) -> (String, String) {
  ignore(fs(self.host, "fs.mkdir", { "path": Json::string(self.dir) }))
  self.made += 1
  let temp = self.dir + self.sep + ".\{@host.pid()}-\{self.made}.memory-tmp"
  write(temp)
  match hash_of(self.host, temp) {
    Some(hash) => (temp, hash)
    None => {
      ignore(fs(self.host, "fs.remove", { "path": Json::string(temp) })) catch { _ => () }
      raise Failed("a blob of the memory was not written")
    }
  }
}

///|
/// The temporary `temp` named `hash` (memory.ts `writePrivateSoon`'s rename), unless that one is there already.
async fn Blobs::name(self : Blobs, temp : String, hash : String) -> Unit {
  if lstat(self.host, self.path(hash)) is Some(_) {
    ignore(fs(self.host, "fs.remove", { "path": Json::string(temp) }))
  } else {
    ignore(fs(self.host, "fs.rename", { "from": Json::string(temp), "to": Json::string(self.path(hash)) }))
  }
}

///|
/// `bytes` kept (memory.ts `#keepBlob`): written privately (0o600), synced and renamed into place, unless kept already.
/// Their hash.
pub async fn Blobs::keep(self : Blobs, bytes : Bytes) -> String {
  let (temp, hash) = self.temp(async fn(temp) {
    ignore(
      fs(
        self.host,
        "fs.put",
        {
          "path": Json::string(temp),
          "offset": Json::number(0),
          "truncate": Json::boolean(true),
          "sync": Json::boolean(true),
          "mode": Json::number(0o600.to_double()),
        },
        bytes~,
      ),
    )
  })
  self.name(temp, hash)
  hash
}

///|
/// What a station writes in a MEMORY.md of nothing yet (memory.ts EMPTY): no memory of its own.
fn empty_memory(bytes : Bytes) -> Bool {
  if !is_text(bytes) {
    // (what is not UTF-8 reads as U+FFFD, which is none of them)
    return false
  }
  match js_trim(text_of(bytes)) {
    "" | "# still.fail memory" | "# ember memory" => true
    _ => false
  }
}

///|
/// Whether `name` may be a file's name on every system (station/src/ops/paths.ts `portableName`).
pub fn portable_name(name : String) -> Bool {
  let n = name.length()
  if n == 0 || name.has_prefix(".") {
    return false
  }
  let last = name[n - 1].to_int()
  if last == '.' || last == ' ' {
    return false
  }
  let mut bytes = 0
  let mut i = 0
  while i < n {
    let c = name[i].to_int()
    if c < 0x20 ||
      c == '<' ||
      c == '>' ||
      c == ':' ||
      c == '"' ||
      c == '/' ||
      c == '\\' ||
      c == '|' ||
      c == '?' ||
      c == '*' {
      return false
    }
    if c < 0x80 {
      bytes += 1
    } else if c < 0x800 {
      bytes += 2
    } else if c >= 0xd800 &&
      c <= 0xdbff &&
      i + 1 < n &&
      name[i + 1].to_int() >= 0xdc00 &&
      name[i + 1].to_int() <= 0xdfff {
      bytes += 4
      i += 1
    } else {
      bytes += 3
    }
    i += 1
  }
  if bytes > 255 {
    return false
  }
  // /^(con|prn|aux|nul|com[0-9¹²³]|lpt[0-9¹²³])(\.|$)/i, its case ASCII's alone
  let lower = fn(k : Int) -> Int {
    let c = name[k].to_int()
    if c >= 'A' && c <= 'Z' {
      c + 32
    } else {
      c
    }
  }
  let ends = fn(k : Int) { k == n || name[k] == '.' }
  if n >= 3 {
    let word = [lower(0), lower(1), lower(2)]
    let named = fn(s : String) { word[0] == s[0].to_int() && word[1] == s[1].to_int() && word[2] == s[2].to_int() }
    if (named("con") || named("prn") || named("aux") || named("nul")) && ends(3) {
      return false
    }
    if (named("com") || named("lpt")) && n >= 4 {
      let d = name[3].to_int()
      if ((d >= '0' && d <= '9') || d == 0xb9 || d == 0xb2 || d == 0xb3) && ends(4) {
        return false
      }
    }
  }
  true
}

///|
/// What a scan is told: where the memory is, what of it the station keeps (path → hash), and memory.ts's bounds.
priv struct Scan {
  dir : String
  kept : Map[String, String]
  builtin : Array[String]
  skipped : Array[String]
  file_most : Double
  skill_most : Double
  skill_files : Int
}

///|
/// A file of the memory found: its path, where it is and what lstat said of it.
priv struct Found {
  path : String
  full : String
  st : Stat
}

///|
/// The memory's files in `dir` as they are now (memory.ts `#read`), each hashed and, changed since the station kept it,
/// its content kept (`#look`'s `#keepBlob`): in the order they were read, each {path, hash, size, mode, mtime} (`empty`:
/// a MEMORY.md of nothing yet the station has no record of, not kept); and the skills not shared as they are (`held`:
/// too large, a link, no SKILL.md yet). A file gone as it was read fails it, as it failed memory.ts's.
async fn scan(blobs : Blobs, ask : Scan) -> Json {
  let host = blobs.host
  let sep = blobs.sep
  let out : Array[Json] = []
  let held : Array[Json] = []
  // MEMORY.md, a link not shared; one that does not read passed over. One only its owner may read is shared all the
  // same (as 0o644): it is the workspace's, never a key, and passed over it was never taken in nor written (a
  // station's of before, 0o600, held every other station's edits off for good).
  let memory = ask.dir + sep + "MEMORY.md"
  if lstat(host, memory) is Some(st) && st.kind == "file" {
    if st.size <= ask.file_most {
      if found_json(blobs, ask, { path: "MEMORY.md", full: memory, st }) is Some(j) {
        out.push(j)
      }
    } else {
      held.push(Json::string("MEMORY.md"))
    }
  }
  let projects = ask.dir + sep + "PROJECTS.jsonl"
  if lstat(host, projects) is Some(st) && st.kind == "file" {
    if own(st.mode) || st.size > ask.file_most {
      held.push(Json::string("PROJECTS.jsonl"))
    } else if found_json(blobs, ask, { path: "PROJECTS.jsonl", full: projects, st }) is Some(j) {
      out.push(j)
    }
  }
  let skills_dir = ask.dir + sep + "skills"
  for entry in readdir(host, skills_dir).unwrap_or([]) {
    let (name, kind) = entry
    let prefix = "skills/\{name}/"
    if ask.builtin.contains(name) || !portable_name(name) || ask.skipped.contains(name) {
      continue
    }
    if kind != "dir" {
      held.push(Json::string(prefix))
      continue
    }
    let found : Array[Found] = []
    let mut bytes = 0.0
    let mut over = false
    // (a directory's walk of its own: what is under it however deep, as memory.ts walked it)
    // Depth first, each directory's entries in their order, as memory.ts's recursion went.
    let stack : Array[(String, Array[(String, String)], Int)] = []
    if readdir(host, skills_dir + sep + name) is Some(es) {
      stack.push(("", es, 0))
    }
    while stack.pop() is Some((rel, es, at)) {
      if at >= es.length() {
        continue
      }
      stack.push((rel, es, at + 1))
      let (e, ekind) = es[at]
      if over || !portable_name(e) || ask.skipped.contains(e) {
        continue
      }
      let sub = if rel == "" { e } else { rel + "/" + e }
      let full = skills_dir + sep + name + sep + sub.replace_all(old="/", new=sep)
      if ekind == "dir" {
        match readdir(host, full) {
          Some(inner) => stack.push((sub, inner, 0))
          None => ()
        }
      } else if ekind == "file" {
        guard lstat(host, full) is Some(st) else {
          raise Failed("ENOENT: no such file or directory, lstat '\{full}'")
        }
        if own(st.mode) {
          continue
        }
        bytes += st.size
        if st.size > ask.file_most ||
          bytes > ask.skill_most ||
          found.length() >= ask.skill_files {
          over = true
        } else {
          found.push({ path: prefix + sub, full, st })
        }
      }
    }
    // A skill without its SKILL.md yet (being written, or no skill) waits until it has one.
    if over || !found.iter().any(fn(f) { f.path == prefix + "SKILL.md" }) {
      held.push(Json::string(prefix))
    } else {
      for f in found {
        match found_json(blobs, ask, f) {
          Some(j) => out.push(j)
          None => raise Failed("ENOENT: no such file or directory, open '\{f.full}'")
        }
      }
    }
  }
  { "files": Json::array(out), "held": Json::array(held) }
}

///|
/// A file only its owner may read (a key, a host's address kept beside a skill): this machine's alone, never shared.
fn own(mode : Int) -> Bool {
  (mode & 0o077) == 0
}

///|
/// What is shared of a file's mode: whether its owner may run it.
fn mode_of(mode : Int) -> Int {
  if (mode & 0o100) != 0 {
    0o755
  } else {
    0o644
  }
}

///|
/// A file found as the scan tells it, its content kept where the station does not keep it yet; None when it does not
/// read.
async fn found_json(blobs : Blobs, ask : Scan, f : Found) -> Json? {
  let host = blobs.host
  guard hash_of(host, f.full) is Some(hash) else { return None }
  let m : Map[String, Json] = {
    "path": Json::string(f.path),
    "hash": Json::string(hash),
    "size": Json::number(f.st.size),
    "mode": Json::number(mode_of(f.st.mode).to_double()),
    "mtime": Json::number(@double.round(f.st.mtime)),
  }
  if ask.kept.get(f.path) is Some(k) && k == hash {
    return Some(Json::object(m))
  }
  if f.path == "MEMORY.md" && !ask.kept.contains(f.path) {
    guard bytes_of(host, f.full) is Some(bytes) else { return None }
    if empty_memory(bytes) {
      m["empty"] = Json::boolean(true)
      return Some(Json::object(m))
    }
  }
  if blobs.has(hash) {
    return Some(Json::object(m))
  }
  // Its bytes as they are now, kept: what was read is what is told.
  guard bytes_of(host, f.full) is Some(bytes) else { return None }
  let kept = blobs.keep(bytes)
  m["hash"] = Json::string(kept)
  m["size"] = Json::number(bytes.length().to_double())
  Some(Json::object(m))
}
