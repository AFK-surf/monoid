// The machine's files as the routes reach them (node:fs/promises, node:fs), through the backend: `fs.<call>` with
// the arguments node gives it, a stat as `{size, mtimeMs, file, dir}`, a handle by reference, an error thrown as
// `Error` with its `code`.

///|
/// What a stat says of a path.
pub struct Stat {
  size : Double
  mtime_ms : Double
  file : Bool
  dir : Bool
}

///|
fn stat_of(v : JV) -> Stat {
  {
    size: jnumber(v.get("size")).unwrap_or(0.0),
    mtime_ms: jnumber(v.get("mtimeMs")).unwrap_or(0.0),
    file: v.get("file") is Some(Bool(true)),
    dir: v.get("dir") is Some(Bool(true)),
  }
}

///|
/// `stat(path)`, raising as it does.
pub async fn Admin::fs_stat(self : Admin, path : String) -> Stat {
  stat_of(self.backend.ask("fs.stat", [js(path)]))
}

///|
/// `stat(path).catch(() => null)`.
pub async fn Admin::stat_or_none(self : Admin, path : String) -> Stat? {
  Some(self.fs_stat(path)) catch {
    _ => None
  }
}

///|
pub async fn Admin::exists(self : Admin, path : String) -> Bool {
  self.stat_or_none(path) is Some(_)
}

///|
pub async fn Admin::fs(self : Admin, call : String, args : Array[JV]) -> JV {
  self.backend.ask("fs." + call, args)
}

///|
pub async fn Admin::read_file(self : Admin, path : String) -> Bytes {
  self.backend.ask_bytes("fs.readFile", [js(path)]).unwrap_or(b"")
}

///|
pub async fn Admin::mkdirs(self : Admin, path : String) -> Unit {
  ignore(self.fs("mkdir", [js(path), jobj([("recursive", jbool(true))])]))
}

///|
/// What an error says as station/src/read/sessions.ts `ioMessage` says it.
pub fn Admin::io_message(self : Admin, e : Error) -> String {
  ignore(self)
  let said = match e {
    Thrown(_, said) => said
    _ => jobj([("message", js(message_of(e)))])
  }
  match jstr(said.get("code")) {
    Some("ENOENT") => "No such file or directory (os error 2)"
    Some("EACCES") => "Permission denied (os error 13)"
    Some("EISDIR") => "Is a directory (os error 21)"
    Some("EPERM") => "Operation not permitted (os error 1)"
    _ => jstr(said.get("message")).unwrap_or("")
  }
}

///|
/// A stream's next piece, as the backend gives it (`{"$stream": id}` read on with `$stream.next`).
pub fn Admin::stream_of(self : Admin, v : JV) -> async () -> Bytes? {
  let id = v.get("$stream").unwrap_or(Null)
  async fn() { self.backend.ask_bytes("$stream.next", [id]) }
}
