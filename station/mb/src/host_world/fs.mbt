// Shared shell filesystem and random-byte primitives on `@host.Host`.

///|
fn json_str(v : @json.Json) -> String? {
  match v { String(s) => Some(s); _ => None }
}

///|
fn json_num(v : @json.Json, key : String) -> Double? {
  match v { Object(m) => match m.get(key) { Some(Number(n, ..)) => Some(n); _ => None }; _ => None }
}

///|
fn json_str_field(v : @json.Json, key : String) -> String? {
  match v { Object(m) => match m.get(key) { Some(String(s)) => Some(s); _ => None }; _ => None }
}

///|
pub(all) struct LstatInfo {
  kind : String
  size : Double
  ino : Double
  mtime_ms : Double
  mode : Double
}

///|
pub(all) struct MetaInfo {
  size : Double
  mtime_ms : Double
}

///|
pub async fn shell_call(
  host : @host.Host,
  sync : Bool,
  op : String,
  args : Map[String, @json.Json],
) -> @json.Json {
  let obj = @json.Json::object(args)
  if sync { host.shell_sync(op, obj) } else { host.shell(op, obj).0 }
}

///|
pub async fn fs_read_text(host : @host.Host, path : String, sync? : Bool = false) -> String? {
  json_str(shell_call(host, sync, "fs.read", { "path": @json.Json::string(path) }))
}

///|
pub fn fs_read_text_sync(host : @host.Host, path : String) -> String? {
  json_str(host.shell_sync("fs.read", { "path": @json.Json::string(path) })) catch { _ => None }
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
  if from is Some(f) { args["from"] = @json.Json::number(f) }
  if length is Some(n) { args["length"] = @json.Json::number(n) }
  match shell_call(host, sync, "fs.bytes", args) { String(hex) => Some(hex_bytes(hex)); _ => None }
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
  if offset is Some(v) { args["offset"] = @json.Json::number(v) }
  if truncate is Some(v) { args["truncate"] = @json.Json::boolean(v) }
  if exclusive is Some(v) { args["exclusive"] = @json.Json::boolean(v) }
  if mode is Some(v) { args["mode"] = @json.Json::number(v.to_double()) }
  if sync_disk is Some(v) { args["sync"] = @json.Json::boolean(v) }
  ignore(host.shell("fs.put", @json.Json::object(args), bytes=data))
}

///|
pub async fn fs_put_whole(host : @host.Host, path : String, data : Bytes, mode? : Int) -> Unit {
  fs_put(host, path, data, offset=0.0, truncate=true, mode?)
}

///|
pub async fn fs_mkdir(host : @host.Host, path : String, sync? : Bool = false) -> Unit {
  ignore(shell_call(host, sync, "fs.mkdir", { "path": @json.Json::string(path) }))
}

///|
pub async fn fs_remove(host : @host.Host, path : String, recursive? : Bool = false, sync? : Bool = false) -> Unit {
  let args : Map[String, @json.Json] = { "path": @json.Json::string(path) }
  if recursive { args["recursive"] = @json.Json::boolean(true) }
  ignore(shell_call(host, sync, "fs.remove", args))
}

///|
pub async fn fs_rename(host : @host.Host, from : String, to : String, sync? : Bool = false) -> Unit {
  ignore(shell_call(host, sync, "fs.rename", { "from": @json.Json::string(from), "to": @json.Json::string(to) }))
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
pub async fn fs_exists(host : @host.Host, path : String, lstat? : Bool = false, sync? : Bool = false) -> Bool {
  let args : Map[String, @json.Json] = { "path": @json.Json::string(path) }
  if lstat { args["lstat"] = @json.Json::boolean(true) }
  shell_call(host, sync, "fs.stat", args) is String(_)
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
pub async fn fs_symlink(host : @host.Host, target : String, path : String, sync? : Bool = false) -> Unit {
  ignore(shell_call(host, sync, "fs.symlink", { "target": @json.Json::string(target), "path": @json.Json::string(path) }))
}

///|
pub async fn fs_meta(host : @host.Host, path : String, sync? : Bool = false) -> MetaInfo? {
  match shell_call(host, sync, "fs.meta", { "path": @json.Json::string(path) }) {
    Object(_) as obj => Some({ size: json_num(obj, "size").unwrap_or(0.0), mtime_ms: json_num(obj, "mtime").unwrap_or(0.0) })
    _ => None
  }
}

///|
pub async fn fs_readdir(host : @host.Host, path : String, sync? : Bool = false) -> Array[String]? {
  match shell_call(host, sync, "fs.readdir", { "path": @json.Json::string(path) }) {
    Array(xs) =>
      Some(xs.filter_map(x => match x { String(s) => Some(s); Array([String(s), ..]) => Some(s); _ => None }))
    _ => None
  }
}

///|
pub fn random_hex(host : @host.Host, n : Int) -> String {
  match (try Some(host.shell_sync("crypto.random", { "bytes": @json.Json::number(n.to_double()) })) catch { _ => None }) {
    Some(String(s)) => s
    _ => ""
  }
}
