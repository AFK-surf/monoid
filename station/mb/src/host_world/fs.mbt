// Shared shell filesystem and random-byte primitives on `@host.Host`.

///|
pub fn json_str(v : @json.Json) -> String? {
  match v {
    String(s) => Some(s)
    _ => None
  }
}

///|
pub fn json_field(v : @json.Json, key : String) -> @json.Json? {
  match v {
    Object(m) => m.get(key)
    _ => None
  }
}

///|
pub fn json_num(v : @json.Json, key : String) -> Double? {
  match json_field(v, key) {
    Some(Number(n, ..)) => Some(n)
    _ => None
  }
}

///|
pub fn json_str_field(v : @json.Json, key : String) -> String? {
  match json_field(v, key) {
    Some(String(s)) => Some(s)
    _ => None
  }
}

///|
/// Stat fields returned by `fs.lstat` (links not followed).
pub(all) struct LstatInfo {
  kind : String
  size : Double
  ino : Double
  mtime_ms : Double
  mode : Double
}

///|
/// Metadata fields returned by `fs.meta` (follows symlinks).
pub(all) struct MetaInfo {
  size : Double
  mtime_ms : Double
}

///|
/// Directory entry returned by `fs.readdir` with `types: true`.
pub(all) struct DirEntry {
  name : String
  dir : Bool
}

///|
/// Invoke a shell op either synchronously (`shell_sync`) or asynchronously on the shell thread pool (`shell`).
pub async fn shell_call(
  host : @host.Host,
  sync : Bool,
  op : String,
  args : Map[String, @json.Json],
) -> @json.Json {
  let obj = @json.Json::object(args)
  if sync {
    host.shell_sync(op, obj)
  } else {
    host.shell(op, obj).0
  }
}

///|
/// Invoke a shell op asynchronously with attached binary payload.
pub async fn shell_call_bytes(
  host : @host.Host,
  op : String,
  args : Map[String, @json.Json],
  bytes : Bytes,
) -> @json.Json {
  host.shell(op, @json.Json::object(args), bytes~).0
}

///|
pub async fn fs_read_text(host : @host.Host, path : String, sync? : Bool = false) -> String? {
  json_str(shell_call(host, sync, "fs.read", { "path": @json.Json::string(path) }))
}

///|
pub fn fs_read_text_sync(host : @host.Host, path : String) -> String? {
  json_str(host.shell_sync("fs.read", { "path": @json.Json::string(path) })) catch {
    _ => None
  }
}

///|
pub async fn fs_read_bytes(
  host : @host.Host,
  path : String,
  from? : Double,
  length? : Double,
  sync? : Bool = false,
) -> Bytes? {
  let args : Map[String, @json.Json] = { "path": @json.Json::string(path) }
  match from {
    Some(f) => args["from"] = @json.Json::number(f)
    None => ()
  }
  match length {
    Some(n) => args["length"] = @json.Json::number(n)
    None => ()
  }
  match shell_call(host, sync, "fs.bytes", args) {
    String(hex) => Some(hex_bytes(hex))
    _ => None
  }
}

///|
pub fn fs_read_bytes_sync(host : @host.Host, path : String) -> Bytes? {
  match (try Some(host.shell_sync("fs.bytes", { "path": @json.Json::string(path) })) catch { _ => None }) {
    Some(String(hex)) => Some(hex_bytes(hex))
    _ => None
  }
}

///|
pub async fn fs_write(host : @host.Host, path : String, text : String, sync? : Bool = false) -> Unit {
  ignore(shell_call(host, sync, "fs.write", { "path": @json.Json::string(path), "text": @json.Json::string(text) }))
}

///|
pub async fn fs_put(
  host : @host.Host,
  path : String,
  data : Bytes,
  offset? : Double,
  truncate? : Bool,
  exclusive? : Bool,
  mode? : Int,
  sync_disk? : Bool,
) -> Unit {
  let args : Map[String, @json.Json] = { "path": @json.Json::string(path) }
  match offset {
    Some(v) => args["offset"] = @json.Json::number(v)
    None => ()
  }
  match truncate {
    Some(v) => args["truncate"] = @json.Json::boolean(v)
    None => ()
  }
  match exclusive {
    Some(v) => args["exclusive"] = @json.Json::boolean(v)
    None => ()
  }
  match mode {
    Some(v) => args["mode"] = @json.Json::number(v.to_double())
    None => ()
  }
  match sync_disk {
    Some(v) => args["sync"] = @json.Json::boolean(v)
    None => ()
  }
  ignore(shell_call_bytes(host, "fs.put", args, data))
}

///|
/// Write `data` whole at `path` (`offset: 0`, `truncate: true`), optionally setting `mode`.
pub async fn fs_put_whole(host : @host.Host, path : String, data : Bytes, mode? : Int) -> Unit {
  fs_put(host, path, data, offset=0.0, truncate=true, mode?)
}

///|
pub async fn fs_mkdir(host : @host.Host, path : String, sync? : Bool = false) -> Unit {
  ignore(shell_call(host, sync, "fs.mkdir", { "path": @json.Json::string(path) }))
}

///|
pub async fn fs_remove(
  host : @host.Host,
  path : String,
  recursive? : Bool = false,
  sync? : Bool = false,
) -> Unit {
  let args : Map[String, @json.Json] = { "path": @json.Json::string(path) }
  if recursive {
    args["recursive"] = @json.Json::boolean(true)
  }
  ignore(shell_call(host, sync, "fs.remove", args))
}

///|
pub async fn fs_rename(host : @host.Host, from : String, to : String, sync? : Bool = false) -> Unit {
  ignore(shell_call(host, sync, "fs.rename", { "from": @json.Json::string(from), "to": @json.Json::string(to) }))
}

///|
pub async fn fs_chmod(host : @host.Host, path : String, mode : Int, sync? : Bool = false) -> Unit {
  ignore(shell_call(host, sync, "fs.chmod", { "path": @json.Json::string(path), "mode": @json.Json::number(mode.to_double()) }))
}

///|
pub async fn fs_lstat(host : @host.Host, path : String, sync? : Bool = false) -> LstatInfo? {
  match shell_call(host, sync, "fs.lstat", { "path": @json.Json::string(path) }) {
    Object(_) as obj =>
      Some({
        kind: json_str_field(obj, "kind").unwrap_or(""),
        size: json_num(obj, "size").unwrap_or(0.0),
        ino: json_num(obj, "ino").unwrap_or(0.0),
        mtime_ms: json_num(obj, "mtimeMs").unwrap_or(0.0),
        mode: json_num(obj, "mode").unwrap_or(0.0),
      })
    _ => None
  }
}

///|
pub async fn fs_stat_kind(
  host : @host.Host,
  path : String,
  lstat? : Bool = false,
  sync? : Bool = false,
) -> String? {
  let args : Map[String, @json.Json] = { "path": @json.Json::string(path) }
  if lstat {
    args["lstat"] = @json.Json::boolean(true)
  }
  json_str(shell_call(host, sync, "fs.stat", args))
}

///|
pub async fn fs_exists(
  host : @host.Host,
  path : String,
  lstat? : Bool = false,
  sync? : Bool = false,
) -> Bool {
  fs_stat_kind(host, path, lstat~, sync~) is Some(_)
}

///|
pub fn fs_exists_sync(host : @host.Host, path : String) -> Bool {
  (host.shell_sync("fs.stat", { "path": @json.Json::string(path) }) catch { _ => @json.Json::null() }) is String(_)
}

///|
pub async fn fs_realpath(host : @host.Host, path : String, sync? : Bool = false) -> String? {
  json_str(shell_call(host, sync, "fs.realpath", { "path": @json.Json::string(path) }))
}

///|
pub async fn fs_readlink(host : @host.Host, path : String, sync? : Bool = false) -> String? {
  json_str(shell_call(host, sync, "fs.readlink", { "path": @json.Json::string(path) }))
}

///|
pub async fn fs_symlink(
  host : @host.Host,
  target : String,
  path : String,
  sync? : Bool = false,
) -> Unit {
  ignore(shell_call(host, sync, "fs.symlink", { "target": @json.Json::string(target), "path": @json.Json::string(path) }))
}

///|
pub async fn fs_link(host : @host.Host, from : String, to : String, sync? : Bool = false) -> Bool {
  !(shell_call(host, sync, "fs.link", { "from": @json.Json::string(from), "to": @json.Json::string(to) }) is False)
}

///|
pub async fn fs_copy(host : @host.Host, from : String, to : String, sync? : Bool = false) -> Unit {
  ignore(shell_call(host, sync, "fs.copy", { "from": @json.Json::string(from), "to": @json.Json::string(to) }))
}

///|
pub async fn fs_meta(host : @host.Host, path : String, sync? : Bool = false) -> MetaInfo? {
  match shell_call(host, sync, "fs.meta", { "path": @json.Json::string(path) }) {
    Object(_) as obj =>
      Some({
        size: json_num(obj, "size").unwrap_or(0.0),
        mtime_ms: json_num(obj, "mtime").unwrap_or(0.0),
      })
    _ => None
  }
}

///|
pub async fn fs_readdir(host : @host.Host, path : String, sync? : Bool = false) -> Array[String]? {
  match shell_call(host, sync, "fs.readdir", { "path": @json.Json::string(path) }) {
    Array(xs) =>
      Some(
        xs.filter_map(x => match x {
          String(s) => Some(s)
          Array([String(s), ..]) => Some(s)
          _ => None
        }),
      )
    _ => None
  }
}

///|
pub async fn fs_readdir_types(
  host : @host.Host,
  path : String,
  sync? : Bool = false,
) -> Array[DirEntry]? {
  match shell_call(host, sync, "fs.readdir", { "path": @json.Json::string(path), "types": @json.Json::boolean(true) }) {
    Array(xs) =>
      Some(
        xs.filter_map(x => match x {
          Array([String(name), String(kind)]) => Some({ name, dir: kind == "dir" })
          _ => None
        }),
      )
    _ => None
  }
}

///|
pub async fn fs_hash(host : @host.Host, path : String, sync? : Bool = false) -> String? {
  json_str(shell_call(host, sync, "fs.hash", { "path": @json.Json::string(path) }))
}

///|
/// Request `n` random bytes from the shell as a hex string; empty string on failure.
pub fn random_hex(host : @host.Host, n : Int) -> String {
  match (try Some(host.shell_sync("crypto.random", { "bytes": @json.Json::number(n.to_double()) })) catch { _ => None }) {
    Some(String(s)) => s
    _ => ""
  }
}

///|
/// Request `n` random bytes from the shell, falling back to zero bytes if unavailable.
pub fn random_bytes(host : @host.Host, n : Int) -> Bytes {
  let b = hex_bytes(random_hex(host, n))
  if b.length() == n {
    b
  } else {
    Bytes::from_array(FixedArray::make(n, b'\x00'))
  }
}

///|
/// Uniform-ish random integer in `[lo, hi)` using 4 random bytes from the shell.
pub fn random_int(host : @host.Host, lo : Int, hi : Int) -> Int {
  let b = random_bytes(host, 4)
  let v = ((b[0].to_int() << 24) | (b[1].to_int() << 16) | (b[2].to_int() << 8) | b[3].to_int()) & 0x7fffffff
  lo + v % (hi - lo)
}
