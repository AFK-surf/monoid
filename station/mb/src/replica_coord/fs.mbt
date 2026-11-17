// The machine's files, as node:fs/promises and node:path reach them (session_storage's `Files`, over the shell's
// `fs.*`), and what these parts do with them more than once.

///|
pub struct Fs {
  files : @session_storage.Files
  host : @host.Host
  sep : String
}

///|
pub fn Fs::new(host : @host.Host, sep? : String = "/") -> Fs {
  { files: @session_storage.Files::new(host, sep~), host, sep }
}

///|
pub fn Fs::join(self : Fs, parts : Array[String]) -> String {
  @nodepath.join(self.sep, parts)
}

///|
pub fn Fs::dirname(self : Fs, path : String) -> String {
  @nodepath.dirname(self.sep, path)
}

///|
pub fn Fs::basename(self : Fs, path : String) -> String {
  @nodepath.basename(self.sep, path)
}

///|
pub fn Fs::is_absolute(self : Fs, path : String) -> Bool {
  @nodepath.is_absolute(self.sep, path)
}

///|
fn split_parts(path : String, sep : String) -> Array[String] {
  let out = []
  let mut start = 0
  for i = 0; i <= path.length(); i = i + 1 {
    if i < path.length() {
      let c = path.unsafe_charcode_at(i)
      if !(c == '/' || (sep == "\\" && c == '\\')) {
        continue
      }
    }
    let p = path.unsafe_substring(start~, end=i)
    if p != "" && p != "." {
      if p == ".." {
        ignore(out.pop())
      } else {
        out.push(p)
      }
    }
    start = i + 1
  }
  out
}

///|
/// path.resolve of an absolute path (normalized; a trailing separator dropped).
pub fn Fs::resolve(self : Fs, path : String, rest? : Array[String] = []) -> String {
  let whole = if rest.length() == 0 { path } else { self.join([path, ..rest]) }
  let parts = split_parts(whole, self.sep)
  self.sep + parts.join(self.sep)
}

///|
/// path.relative(from, to) of two absolute paths.
pub fn Fs::relative(self : Fs, from : String, to : String) -> String {
  let a = split_parts(self.resolve(from), self.sep)
  let b = split_parts(self.resolve(to), self.sep)
  let mut i = 0
  while i < a.length() && i < b.length() && a[i] == b[i] {
    i += 1
  }
  let out = []
  for _ in i..<a.length() {
    out.push("..")
  }
  for j in i..<b.length() {
    out.push(b[j])
  }
  out.join(self.sep)
}

///|
/// What `path` is under `root`: its parts (None: not under it, or `root` itself: []).
pub fn Fs::under(self : Fs, root : String, path : String) -> Array[String]? {
  let rel = self.relative(root, path)
  if rel == "" {
    return Some([])
  }
  if rel.has_prefix("..") || self.is_absolute(rel) {
    return None
  }
  Some(rel.split(self.sep).map(v => v.to_string()).collect())
}

///|
/// `stat(path).then(() => true, () => false)`.
pub async fn Fs::there(self : Fs, path : String) -> Bool {
  self.files.there(path)
}

///|
/// `lstat(path)` succeeding.
pub async fn Fs::lthere(self : Fs, path : String) -> Bool {
  self.files.lkind(path) is Some(_)
}

///|
/// `readdir(path).catch(() => [])`.
pub async fn Fs::names(self : Fs, path : String) -> Array[String] {
  self.files.entries(path)
}

///|
/// `rm(path, {recursive: true, force: true})`.
pub async fn Fs::rm_rf(self : Fs, path : String) -> Unit {
  self.files.rm(path, recursive=true, force=true)
}

///|
/// `rm(path, {force: true})`.
pub async fn Fs::rm_f(self : Fs, path : String) -> Unit {
  self.files.rm(path, force=true)
}

///|
/// `rmdir(path)`: an empty directory taken out; false where it is not one, not empty, or not there.
pub async fn Fs::rmdir(self : Fs, path : String) -> Bool {
  if self.files.lkind(path) is Some("dir") {
    ignore(self.host.shell("fs.remove", jsonc([("path", path)]))) catch {
      _ => return false
    }
    true
  } else {
    false
  }
}

///|
pub async fn Fs::mkdirs(self : Fs, path : String) -> Unit {
  self.files.mkdirs(path)
}

///|
pub async fn Fs::rename(self : Fs, from : String, to : String) -> Unit {
  self.files.rename(from, to)
}

///|
/// `readFile(path, "utf8")`, None where it does not read.
pub async fn Fs::read_text(self : Fs, path : String) -> String? {
  self.files.read_text(path)
}

///|
/// `readFile(path, "utf8")`, raising where it does not read (ENOENT).
pub async fn Fs::read_text_strict(self : Fs, path : String) -> String {
  match self.files.read_text(path) {
    Some(t) => t
    None => raise Thrown("Error", jo([("message", js("ENOENT: no such file or directory, open '\{path}'")), ("code", js("ENOENT"))]))
  }
}

///|
/// `JSON.parse(await readFile(path, "utf8"))`, None where it does not read or parse.
pub async fn Fs::read_json(self : Fs, path : String) -> J? {
  match self.files.read_text(path) {
    Some(t) => Some(parse(t)) catch { _ => None }
    None => None
  }
}

///|
pub async fn Fs::write_text(self : Fs, path : String, text : String, sync? : Bool = false) -> Unit {
  self.files.write_text(path, text, sync~)
}

///|
/// `appendFile(path, text)`.
pub async fn Fs::append(self : Fs, path : String, text : String) -> Unit {
  ignore(self.host.shell("fs.put", jsonc([("path", path)]), bytes=@utf8.encode(text)))
}

///|
/// The random part of a name: `randomBytes(n).toString("hex")`.
pub async fn Fs::random_hex(self : Fs, n : Int) -> String {
  let v = self.host.shell_sync("crypto.random", { "bytes": Json::number(n.to_double()) })
  match v {
    String(h) => h
    _ => ""
  }
}

///|
/// Written beside and renamed into place (each write its own name): a JSON file whole or not at all.
pub async fn Fs::write_json(self : Fs, path : String, v : J) -> Unit {
  self.mkdirs(self.dirname(path))
  let tmp = "\{path}.\{self.random_hex(4)}.tmp"
  self.files.write_text(tmp, stringify(v))
  self.rename(tmp, path)
}

///|
/// A file's SHA-256 (None where it does not open).
pub async fn Fs::hash(self : Fs, path : String) -> String? {
  let (v, _) = self.host.shell("fs.hash", jsonc([("path", path)]))
  match v {
    String(h) => Some(h)
    _ => None
  }
}

///|
/// What stat (links followed) says: kind, size, mtimeMs (None: nothing there).
pub async fn Fs::stat(self : Fs, path : String) -> (String, Double, Double)? {
  let (v, _) = self.host.shell("fs.meta", jsonc([("path", path)]))
  match v {
    Object(o) => {
      let size = match o.get("size") {
        Some(Number(n, ..)) => n
        _ => 0.0
      }
      let mtime = match o.get("mtime") {
        Some(Number(n, ..)) => n
        _ => 0.0
      }
      let dir = o.get("dir") is Some(True)
      let kind = if dir { "dir" } else { self.files.kind(path).unwrap_or("other") }
      Some((kind, size, mtime))
    }
    _ => None
  }
}

///|
/// `link(from, to)`: false where `to` is there already.
pub async fn Fs::link(self : Fs, from : String, to : String) -> Bool {
  let (v, _) = self.host.shell("fs.link", jsonc([("from", from), ("to", to)]))
  !(v is False)
}

///|
pub async fn Fs::realpath(self : Fs, path : String) -> String? {
  self.files.realpath(path)
}

///|
pub async fn Fs::copy(self : Fs, from : String, to : String) -> Unit {
  self.files.copy(from, to)
}

///|
pub async fn Fs::chmod(self : Fs, path : String, mode : Int) -> Unit {
  self.files.chmod(path, mode)
}

///|
fn jsonc(fields : Array[(String, String)]) -> Json {
  let m : Map[String, Json] = {}
  for f in fields {
    m[f.0] = Json::string(f.1)
  }
  Json::object(m)
}

///|
/// The lines of a file (`createInterface` over it), "" where it does not read.
pub async fn Fs::lines(self : Fs, path : String) -> Array[String] {
  match self.files.read_text(path) {
    Some(t) => {
      let out = []
      for l in t.split("\n") {
        let s = l.to_string()
        out.push(if s.has_suffix("\r") { s.unsafe_substring(start=0, end=s.length() - 1) } else { s })
      }
      // (a last line ends where the file does: none after a final "\n")
      if out.length() > 0 && out[out.length() - 1] == "" {
        ignore(out.pop())
      }
      out
    }
    None => []
  }
}
