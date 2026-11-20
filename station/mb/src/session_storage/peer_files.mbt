// Files between sessions on different stations of the workspace (station/src/sessions/peer-files.ts): an agent reading
// a chat there (chat_read) gets its attachments here, and one writing to a session there (session_send) takes its files
// along, each whole after one request or answer (to and from a station from before, in chunks). A request or an answer
// carries its bytes as `{"$bytes": base64}` where they came, and names a file's as `{"$file": {path, offset, end}}`
// where they go, from `offset` to `end`: the station's bus reads them from there as it sends (mesh/files.ts `fileBytes`).

///|
pub let file_method = "session.file"

///|
pub let put_method = "session.put"

///|
/// Attachments up to this size come with a read of their chat by themselves; larger ones when asked for.
pub let fetched_most : Double = 16.0 * 1024.0 * 1024.0

///|
let fetched_in_all : Double = 64.0 * 1024.0 * 1024.0

///|
let max_files = 10

///|
let max_sent : Double = 50.0 * 1024.0 * 1024.0

///|
let staged_ms : Double = 24.0 * 3600.0 * 1000.0

///|
/// jobs/remote.ts `CHUNK`.
let chunk : Double = 256.0 * 1024.0

///|
/// A chat's attachment as another station lists it.
pub(all) struct Listed {
  path : String
  name : String
  size : Double
}

///|
/// jobs/remote.ts `hash`: the SHA-256 of a value's JSON.
fn hash_of(v : Json) -> String {
  @memory.sha256_hex(@utf8.encode(v.stringify()))
}

///|
/// ops/paths.ts `anyBaseName`: the last part of a path, Unix's or Windows'.
fn any_base_name(path : String) -> String {
  let parts = []
  for p in path.split("/") {
    for q in p.split("\\") {
      if q != "" {
        parts.push(q.to_string())
      }
    }
  }
  parts.last().unwrap_or("")
}

///|
/// A file's bytes as a request or answer names them for the bus.
fn file_bytes(path : String, offset : Double, end : Double) -> Json {
  jo([("path", js(path)), ("offset", jn(offset)), ("end", jn(end))])
}

///|
fn with_file(fields : Array[(String, Json)], path : String, offset : Double, end : Double) -> Json {
  fields.push(("$file", file_bytes(path, offset, end)))
  jo(fields)
}

///|
/// Some random hex, from the system's source.
fn Files::random_hex(self : Files, bytes : Int) -> String {
  let said = self.host.shell_sync("crypto.random", jo([("bytes", ji(bytes))])) catch { _ => return "" }
  match said {
    String(h) => h
    _ => ""
  }
}

///|
/// randomUUID(): a version 4 UUID.
fn Files::uuid(self : Files) -> String {
  let h = self.random_hex(16).to_array()
  if h.length() < 32 {
    return "00000000-0000-4000-8000-000000000000"
  }
  let s = (a : Int, b : Int) => String::from_array(h[a:b].to_array())
  let variant = "89ab".to_array()[(hex_value(h[16].to_int()).unwrap_or(0)) & 3]
  "\{s(0, 8)}-\{s(8, 12)}-4\{s(13, 16)}-\{variant}\{s(17, 20)}-\{s(20, 32)}"
}

///|
/// A name as a file in uploads is named: stamped, nothing that leaves the directory.
async fn Storage::upload_name(self : Storage, name : String) -> String {
  let stamp = cut(iso(self.now()), 0, end=19).replace_all(old=":", new="-").replace_all(old=".", new="-")
  let safe = StringBuilder::new()
  for c in name {
    safe.write_char(if c == '\\' || c == '/' || c.to_int() < 0x20 { '_' } else { c })
  }
  "\{stamp}-\{safe}"
}

///|
/// An attachment as messages keep it: pictures and films measured (image-size.ts `shownFactsSoon`).
async fn Storage::attachment(self : Storage, name : String, path : String, size : Double) -> Json {
  let fields = [("name", js(name)), ("path", js(path)), ("size", jn(size))]
  match self.ask("fn.shownFacts", [js(path)]) {
    Object(o) => for k, v in o { fields.push((k, v)) }
    _ => ()
  }
  jo(fields)
}

///|
fn loop_failed(path : String) -> Thrown {
  Thrown("Error", jo([("message", js("ELOOP: too many symbolic links encountered, open '\{path}'")), ("code", js("ELOOP"))]))
}

///|
/// A chunk of the file at `path` from `offset` (`whole`: all of it from there, after the answer).
async fn Storage::chunk_of(self : Storage, path : String, nofollow : Bool, offset : Double, whole : Bool, not_file : () -> Error) -> Json {
  let fs = self.fs
  guard fs.lstat(path) is Some(l) else { raise fs_failed("ENOENT", "open", path) }
  if l.kind == "link" && nofollow {
    raise loop_failed(path)
  }
  guard fs.stat(path) is Some(st) else { raise fs_failed("ENOENT", "open", path) }
  if st.kind != "file" {
    raise not_file()
  }
  let size = st.size
  if offset > size {
    raise failed("offset past end")
  }
  if !whole {
    let data = fs.read_range(path, offset, chunk)
    let n = data.length().to_double()
    return jo([("data", js(@base64.encode(data))), ("size", jn(size)), ("eof", jb(offset + n >= size))])
  }
  with_file([("size", jn(size))], path, offset, size)
}

// ── a chat's attachments, read from another station ──────────────────────────────────────────────────────────────

///|
/// What another station's session reads of a chat's attachment here (`fetch_attachments` there).
pub async fn Storage::file_for_peer(self : Storage, request : Json, ws : String?) -> Json {
  let fs = self.fs
  let chat = str(request, "chat").unwrap_or("")
  let given = str(request, "path").unwrap_or("")
  let offset = match num(request, "offset") {
    Some(n) if n >= 0.0 && n == n.floor() && n <= 9007199254740991.0 => n
    _ => 0.0
  }
  if js_trim(chat) == "" || given == "" {
    raise failed("chat and path are required")
  }
  let sessions = match self.named(chat, ws) {
    Session(k, _) => [k]
    Thread(t) => sessions_of(self.st.threads.thread_sessions(get(t, "id").unwrap_or(Json::null())))
  }
  let path = fs.join([given])
  let base = fs.basename(path)
  let mut row : Json? = None
  for k in sessions {
    match self.session(k) {
      Some(s) =>
        if fs.join([str(s, "workspace").unwrap_or(""), "uploads"]) == fs.dirname(path) {
          row = Some(s)
          break
        }
      None => ()
    }
  }
  guard row is Some(row) && base != "" && base != "." && base != ".." else {
    raise failed("\{given} is not a file of that chat")
  }
  let whole = get(request, "whole") is Some(True)
  if fs.lkind(path) is Some(_) && fs.kind(path) is Some(_) {
    return self.chunk_of(path, true, offset, whole, () => failed("\{given} is not a file of that chat"))
  }
  let data = self.data_dir()
  let dir = fs.join([data, "remote", "served"])
  let kept = fs.join([dir, hash_of(ja([js(path)]))])
  if offset == 0.0 || fs.kind(kept) is None {
    let room = self.room_of(str(row, "workspace").unwrap_or(""))
    let bytes = match room {
      None => None
      Some(r) => fs.with_lock(r, async fn() { fs.workspace_file(r, "uploads/\{base}", self.reads) })
    }
    guard bytes is Some(bytes) else { raise failed("\{given} is gone from that chat") }
    fs.mkdirs(dir)
    self.sweep(dir)
    let part = "\{kept}.part-\{cut(fs.uuid(), 0, end=8)}"
    fs.write(part, bytes)
    fs.rename(part, kept)
  }
  self.chunk_of(kept, false, offset, whole, () => failed("\{given} is gone from that chat"))
}

///|
/// Why a file did not come: a station from before files are read takes the request for a task.
fn why_not(e : Error) -> String {
  if is_kind(e, "Refused") && from_before(message_of(e)) {
    "that station is not updated yet to give files"
  } else {
    message_of(e)
  }
}

///|
fn set_pair(pairs : Array[(String, String)], k : String, v : String) -> Unit {
  match pairs.search_by(p => p.0 == k) {
    Some(i) => pairs[i] = (k, v)
    None => pairs.push((k, v))
  }
}

///|
/// Reads `files` of a chat on station `station` into session `key`'s uploads (uploads/<station>/), each once: those up
/// to `fetched_most` by themselves, those in `wanted` whatever their size. Where each landed by its path there, and
/// what was not fetched and why.
pub async fn Storage::fetch_attachments(
  self : Storage,
  key : String,
  call : async (String, Json) -> Json,
  station : String,
  chat : String,
  files : Array[Listed],
  wanted : Array[String],
) -> (Array[(String, String)], Array[String]) {
  let fs = self.fs
  guard self.session(key) is Some(row) else { raise failed("unknown session") }
  let dir = fs.join([str(row, "workspace").unwrap_or(""), "uploads", cut(station, 0, end=12)])
  let here : Array[(String, String)] = []
  let left = []
  let mut budget = fetched_in_all
  let seen = Set::new()
  for file in files {
    if seen.contains(file.path) {
      continue
    }
    seen.add(file.path)
    let asked = wanted.contains(file.path)
    let local = fs.join([dir, any_base_name(file.path)])
    if fs.stat(local) is Some(s) && s.size == file.size {
      set_pair(here, file.path, local)
      continue
    }
    if !asked && (file.size > fetched_most || file.size > budget) {
      left.push("\{file.path} (\{num_text(file.size)} bytes)")
      continue
    }
    try self.download(call, station, chat, file.path, local) catch {
      e => left.push("\{file.path} (\{why_not(e)})")
    } noraise {
      _ => {
        set_pair(here, file.path, local)
        if !asked {
          budget -= file.size
        }
      }
    }
  }
  for path in wanted {
    if seen.contains(path) {
      continue
    }
    seen.add(path)
    let local = fs.join([dir, any_base_name(path)])
    try {
      if fs.kind(local) is None {
        self.download(call, station, chat, path, local)
      }
    } catch {
      e => left.push("\{path} (\{why_not(e)})")
    } noraise {
      _ => set_pair(here, path, local)
    }
  }
  (here, left)
}

///|
/// One file of a chat there into `local`, which appears only once all of it came.
async fn Storage::download(self : Storage, call : async (String, Json) -> Json, station : String, chat : String, path : String, local : String) -> Unit {
  let fs = self.fs
  fs.mkdirs(fs.dirname(local))
  let part = "\{local}.part-\{cut(fs.uuid(), 0, end=8)}"
  fs.write(part, b"", mode=0o644, exclusive=true)
  try {
    let mut offset = 0.0
    while true {
      let got = call(station, jo([("method", js(file_method)), ("chat", js(chat)), ("path", js(path)), ("offset", jn(offset)), ("whole", jb(true))]))
      match bytes_in(got) {
        Some(bytes) => {
          let size = num(got, "size").unwrap_or(0.0)
          if offset + bytes.length().to_double() > size {
            raise failed("more came than the file can be")
          }
          ignore(fs.put_at(part, bytes, offset))
          offset += bytes.length().to_double()
          if offset != size {
            raise failed("the file stopped coming")
          }
          break
        }
        None => ()
      }
      let data = @base64.decode(str(got, "data").unwrap_or("")) catch { _ => b"" }
      if data.length() > 0 {
        ignore(fs.put_at(part, data, offset))
      }
      offset += data.length().to_double()
      if get(got, "eof") is Some(True) {
        break
      }
      if data.length() == 0 {
        raise failed("the file stopped coming")
      }
    }
    fs.rename(part, local)
  } catch {
    e => {
      fs.gone(part)
      raise e
    }
  }
}

// ── files sent along with a message to another station ──────────────────────────────────────────────────────────

///|
/// Files a message takes along, checked as chat_post checks them: absolute or in session `key`'s workspace.
pub async fn Storage::sendable(self : Storage, key : String, given : Array[String]) -> Array[Listed] {
  let fs = self.fs
  guard self.session(key) is Some(row) else { raise failed("unknown session") }
  if given.length() > max_files {
    raise failed("at most \{max_files} files per message")
  }
  let out = []
  for g in given {
    let path = if @nodepath.is_absolute(fs.sep, g) { g } else { fs.join([str(row, "workspace").unwrap_or(""), g]) }
    guard fs.stat(path) is Some(meta) else { raise failed("no such file: \{g}") }
    if meta.kind != "file" {
      raise failed("not a file: \{g}")
    }
    if meta.size > max_sent {
      raise failed("too large (over 50 MB): \{g}")
    }
    out.push({ path, name: fs.basename(path), size: meta.size })
  }
  out
}

///|
/// Sends `files` ahead of a message from session `key` to session `to` on station `station`, each whole after one
/// request (to a station from before, in chunks): what the message names them by.
pub async fn Storage::send_along(self : Storage, call : async (String, Json) -> Json, station : String, key : String, to : String, files : Array[Listed]) -> Array[(String, String)] {
  let fs = self.fs
  let sent = []
  let mut after = true
  for file in files {
    let id = fs.uuid()
    if after {
      let whole = try {
        let size = match fs.stat(file.path) {
          Some(s) => s.size
          None => raise fs_failed("ENOENT", "stat", file.path)
        }
        ignore(call(station, with_file([("method", js(put_method)), ("session", js(key)), ("to", js(to)), ("id", js(id)), ("name", js(file.name)), ("size", jn(size))], file.path, 0.0, size)))
        true
      } catch {
        e => {
          if !is_kind(e, "NoBytes") {
            raise e
          }
          after = false
          false
        }
      }
      if whole {
        sent.push((id, file.name))
        continue
      }
    }
    guard fs.stat(file.path) is Some(st) else { raise fs_failed("ENOENT", "open", file.path) }
    let size = st.size
    let mut offset = 0.0
    while true {
      let data = fs.read_range(file.path, offset, chunk)
      let n = data.length().to_double()
      let final = n == 0.0 || offset + n >= size
      ignore(call(station, jo([("method", js(put_method)), ("session", js(key)), ("to", js(to)), ("id", js(id)), ("name", js(file.name)), ("offset", jn(offset)), ("data", js(@base64.encode(data))), ("final", jb(final))])))
      offset += n
      if final {
        break
      }
    }
    sent.push((id, file.name))
  }
  sent
}

///|
async fn Storage::staged_dir(self : Storage) -> String {
  self.fs.join([self.data_dir(), "remote", "staged"])
}

///|
async fn Storage::staged(self : Storage, peer : String, from : String, id : String) -> String {
  self.fs.join([self.staged_dir(), hash_of(ja([js(peer), js(from), js(id)]))])
}

///|
fn safe_size(v : Json?) -> Double? {
  match v {
    Some(Number(n, ..)) if n >= 0.0 && n == n.floor() && n <= 9007199254740991.0 => Some(n)
    _ => None
  }
}

///|
/// A file another station's session sends along with a message to a session here (`send_along` there).
pub async fn Storage::put_for_peer(self : Storage, peer : String, request : Json, ws : String?) -> Json {
  let fs = self.fs
  let from = str(request, "session").unwrap_or("")
  let to = str(request, "to").unwrap_or("")
  let id = str(request, "id").unwrap_or("")
  match bytes_in(request) {
    Some(incoming) => {
      let size = safe_size(get(request, "size"))
      if from == "" || id == "" || id.length() > 64 || size is None {
        raise failed("a file needs session, id and size")
      }
      let size = size.unwrap()
      if size > max_sent {
        raise failed("too large (over 50 MB)")
      }
      if self.session(to) is None || !self.reachable(to, ws, write=true) {
        raise failed("no session \{to} on this station (it may have been deleted)")
      }
      let dir = self.staged_dir()
      fs.mkdirs(dir)
      self.sweep(dir)
      let path = self.staged(peer, from, id)
      if fs.lkind("\{path}.part") is Some("link") {
        raise loop_failed("\{path}.part")
      }
      if incoming.length().to_double() > size {
        fs.write("\{path}.part", b"", mode=0o644)
        raise failed("more came than the file can be")
      }
      fs.write("\{path}.part", incoming, mode=0o644)
      if incoming.length().to_double() != size {
        raise failed("the file did not all come")
      }
      fs.rename("\{path}.part", path)
      return jo([("bytes", jn(size))])
    }
    None => ()
  }
  let offset = safe_size(get(request, "offset"))
  if from == "" || id == "" || id.length() > 64 || offset is None {
    raise failed("a file needs session, id and offset")
  }
  let offset = offset.unwrap()
  if self.session(to) is None || !self.reachable(to, ws, write=true) {
    raise failed("no session \{to} on this station (it may have been deleted)")
  }
  let data = @base64.decode(str(request, "data").unwrap_or("")) catch { _ => b"" }
  if data.length().to_double() > chunk || offset + data.length().to_double() > max_sent {
    raise failed("too large (over 50 MB)")
  }
  let dir = self.staged_dir()
  fs.mkdirs(dir)
  if offset == 0.0 {
    self.sweep(dir)
  }
  let path = self.staged(peer, from, id)
  let part = "\{path}.part"
  if fs.lkind(part) is Some("link") {
    raise loop_failed(part)
  }
  let had = match fs.lstat(part) {
    Some(s) => s.size
    None => {
      fs.write(part, b"", mode=0o644)
      0.0
    }
  }
  if offset > had {
    raise failed("file offset leaves a gap")
  }
  if data.length() > 0 {
    ignore(fs.put_at(part, data, offset))
  }
  if get(request, "final") is Some(True) {
    fs.rename(part, path)
  }
  jo([("bytes", ji(data.length()))])
}

///|
/// Files sent along that no message claimed in a day; archived attachments read out a day ago.
async fn Storage::sweep(self : Storage, dir : String) -> Unit {
  let now = self.now()
  for name in self.fs.readdir_strict(dir) {
    let path = self.fs.join([dir, name])
    match self.fs.stat(path) {
      Some(s) => if now - s.mtime_ms > staged_ms { self.fs.gone(path) }
      None => ()
    }
  }
}

///|
/// The files a message from another station's session `from` names (`send_along` there), moved into session `to`'s
/// uploads.
pub async fn Storage::claim(self : Storage, peer : String, from : String, to : String, given : Json?) -> Array[Json] {
  let fs = self.fs
  if nullish(given) {
    return []
  }
  let list = match given {
    Some(Array(xs)) if xs.length() <= max_files => xs
    _ => raise failed("files: at most \{max_files}, each {id, name}")
  }
  guard self.session(to) is Some(row) else { raise failed("no session \{to} on this station (it may have been deleted)") }
  let found = []
  for f in list {
    let id = str(f, "id").unwrap_or("")
    let name = match str(f, "name") {
      Some(n) if js_trim(n) != "" => n
      _ => "file"
    }
    let path = self.staged(peer, from, id)
    if id == "" || fs.kind(path) is None {
      raise failed("file \{name} did not all arrive: send it again")
    }
    found.push((path, name))
  }
  let dir = fs.join([str(row, "workspace").unwrap_or(""), "uploads"])
  fs.mkdirs(dir)
  let out = []
  for pair in found {
    let (path, name) = pair
    let into = fs.join([dir, self.upload_name(name)])
    fs.copy(path, into)
    fs.gone(path)
    out.push(self.attachment(name, into, match fs.stat(into) { Some(s) => s.size; None => 0.0 }))
  }
  out
}
