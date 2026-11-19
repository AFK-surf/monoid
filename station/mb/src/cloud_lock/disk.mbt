// The files the lock keeps, read and written through the shell (fs.*), as station/src/ops/files.ts `writePrivate`
// writes them: whole, by a rename, readable by this user alone.

///|
pub(all) struct Disk {
  host : @host.Host
}

///|
fn Disk::call(self : Disk, op : String, args : Json) -> Json? {
  match (try Ok(self.host.shell_sync(op, args)) catch { e => Err(e) }) {
    Ok(v) => Some(v)
    Err(_) => None
  }
}

///|
/// A file's text (UTF-8, what is not as U+FFFD), none where it is not there.
pub fn Disk::read(self : Disk, path : String) -> String? {
  match self.call("fs.read", { "path": Json::string(path) }) {
    Some(String(s)) => Some(s)
    _ => None
  }
}

///|
/// A file's bytes, none where it is not there.
pub fn Disk::bytes(self : Disk, path : String) -> Bytes? {
  match self.call("fs.bytes", { "path": Json::string(path) }) {
    Some(String(h)) => Some(hex_bytes(h))
    _ => None
  }
}

///|
pub fn Disk::exists(self : Disk, path : String) -> Bool {
  match self.call("fs.stat", { "path": Json::string(path) }) {
    Some(String(_)) => true
    _ => false
  }
}

///|
/// Written whole (a file beside it renamed over it), its folder made, readable by this user alone (writePrivate).
pub fn Disk::write(self : Disk, path : String, text : String) -> Unit raise Failure {
  let _ = self.host.shell_sync("fs.write", { "path": Json::string(path), "text": Json::string(text) }) catch {
    e => raise Failed(e.to_string())
  }
  self.call("fs.chmod", { "path": Json::string(path), "mode": Json::number(384.0) }) |> ignore
}

///|
pub fn Disk::rename(self : Disk, from : String, to : String) -> Unit raise Failure {
  let _ = self.host.shell_sync("fs.rename", { "from": Json::string(from), "to": Json::string(to) }) catch {
    e => raise Failed(e.to_string())
  }
}

///|
/// What is at `path` let go; nothing there is no failure (rmSync's `force`).
pub fn Disk::remove(self : Disk, path : String) -> Unit {
  self.call("fs.remove", { "path": Json::string(path) }) |> ignore
}

///|
pub fn Disk::mkdir(self : Disk, path : String) -> Unit {
  self.call("fs.mkdir", { "path": Json::string(path) }) |> ignore
}

///|
/// Bytes written whole, readable by this user alone (writePrivate of a Buffer).
pub async fn Disk::put(self : Disk, path : String, bytes : Bytes) -> Unit raise Failure {
  self.mkdir(dirname(path))
  // (a name of its own: two fibers writing one file at once each rename theirs, L13; let go of where this fails)
  let tmp = @host.unique_tmp(path)
  errdefer self.remove(tmp)
  let (answer, _) = self.host.shell(
    "fs.put",
    { "path": Json::string(tmp), "truncate": true, "sync": true, "mode": Json::number(384.0) },
    bytes~,
  ) catch {
    e => raise Failed(e.to_string())
  }
  if answer is { "error": String(e), .. } {
    raise Failed(e)
  }
  self.rename(tmp, path)
}

///|
/// A path's folder (node's `dirname`).
pub fn dirname(path : String) -> String {
  @nodepath.dirname("/", path)
}

///|
/// Paths joined with "/" (node's `join`).
pub fn join(parts : Array[String]) -> String {
  @nodepath.join("/", parts)
}
