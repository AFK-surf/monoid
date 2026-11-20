// The phones lent to this station's agents and the workspace's devices (station/src/adb/, station/src/devices/) in
// MoonBit. Clock, async FS, mesh connections/streams, platform/random and read-only session/thread lookups run
// directly on `host`, `sessions` and `threads`; station-bus operations (`hub.*`, `chat.post`, `events.tell`,
// `cloud.*`, `proc.*`, `net.*`, `serial.*`, `adb.path`, `rigs.*`, `forwards.*`, card writes) go through `call`.

///|
using @session_chats {
  type Thrown,
  type Words,
  fail_,
  thrown_message,
  js,
  jn,
  ji,
  jb,
  jo,
  ja,
  jsa,
  jopt,
  at,
  at_i,
  str_of,
  num_of,
  arr_of,
  nullish,
  set_field,
  without,
  spread,
  stringify,
  jeq,
  parse_opt,
  truthy,
}

///|
using @jsjson {type JValue as J}

///|
/// What these parts ask of the station and the machine.
pub struct World {
  /// The station's shell host (async FS, mesh connections/streams, runtime fibers).
  host : @host.Host
  /// The sessions store (direct session lookups).
  sessions : @store_sessions.Store
  /// The threads store (direct starter/firstText/thread/card-header lookups).
  threads : @store_threads.Store
  /// Asks `name` with `args`; what it threw raises `Thrown(kind, message)`.
  call : async (String, Array[J]) -> J
  /// A function given as an argument (a card restated, a check run inside a write): what stands for it.
  callback : (async (Array[J]) -> J) -> J
  /// A write given as an argument that the station runs inside its own transaction (a request saved with its card's
  /// outcome): called there at once, so it never waits on anything.
  write : ((Array[J]) -> J raise) -> J
  /// The clock, in ms (`wall.now()`, a part's `now()`).
  now : () -> Double
  /// Work set going, not waited for (`void promise`).
  spawn : (async () -> Unit) -> Unit
  /// The station's words (client/i18n/catalog's station part).
  words : Words
  /// The station's own language (`stationLang`).
  mut lang : String
}

///|
pub fn World::new(
  host : @host.Host,
  sessions : @store_sessions.Store,
  threads : @store_threads.Store,
  call : async (String, Array[J]) -> J,
  callback : (async (Array[J]) -> J) -> J,
  write : ((Array[J]) -> J raise) -> J,
  now : () -> Double,
  spawn : (async () -> Unit) -> Unit,
  words : Words,
) -> World {
  { host, sessions, threads, call, callback, write, now, spawn, words, lang: "zh" }
}

///|
pub async fn World::ask(self : World, name : String, args : Array[J]) -> J {
  (self.call)(name, args)
}

///|
/// `hub.store.<name>(...args)`.
pub async fn World::store(self : World, name : String, args : Array[J]) -> J {
  self.ask("store." + name, args)
}

///|
/// What an ask says, or Null where it threw (a `.catch(() => null)`).
pub async fn World::try_ask(self : World, name : String, args : Array[J]) -> J {
  self.ask(name, args) catch {
    _ => Null
  }
}

///|
fn clamp_ms(ms : Double) -> Int {
  if ms <= 0.0 { 0 } else if ms > 2147483647.0 { 2147483647 } else { ms.to_int() }
}

///|
/// A wait of `ms` (`wall.sleep`, `Effect.sleep` on a part's clock).
pub async fn World::sleep(self : World, ms : Double) -> Unit {
  ignore(self)
  @host_world.sleep_ms(clamp_ms(ms))
}

///|
/// `f` once, `ms` from now (`wall.after`); the function returned calls it off.
pub fn World::after(self : World, ms : Double, f : async () -> Unit) -> () -> Unit {
  @host_world.after_async(self.host, clamp_ms(ms), f, swallow_error=true)
}

// ── direct mesh connection & stream calls ──

///|
fn conn_id(conn : J) -> Json {
  @jsjson.jval_to_json(at(Some(conn), "id").unwrap_or(conn))
}

///|
pub fn conn_remote_id(conn : J) -> String {
  match conn { Str(_) => js_text(conn); _ => text_of(at(Some(conn), "remoteId")) }
}

///|
pub fn conn_about(conn : J) -> J {
  let r = conn_remote_id(conn)
  jo([("device", js(if r.length() > 12 { r[:12].to_owned() } else { r })), ("via", js("none")), ("ways", js(""))])
}

///|
pub async fn World::conn_open_bi(self : World, conn : J) -> J {
  match self.host.shell("conn.openBi", { "id": conn_id(conn) }).0 {
    Object({ "id": id, .. }) => @jsjson.jval_of_json(id)
    _ => Null
  }
}

///|
pub async fn World::conn_closed(self : World, conn : J) -> Unit {
  ignore(self.host.shell("conn.closed", { "id": conn_id(conn) })) catch { _ => () }
}

///|
pub async fn World::conn_answers(self : World, conn : J, within_ms : Double) -> Bool {
  self.host.shell("conn.answers", { "id": conn_id(conn), "within": Json::number(within_ms) }).0 is True
}

///|
async fn World::stream_call(
  self : World,
  handle : J,
  call : String,
  bytes? : Bytes,
  code? : Json,
) -> (Json, Bytes?) {
  match @jsjson.jval_to_json(handle) {
    Object({ "$tcp": id, .. }) =>
      match call {
        "read" => match self.host.tcp_read(id) { Some(b) => (Json::null(), Some(b)); None => ({ "end": true }, None) }
        "write" => { self.host.tcp_write(id, bytes.unwrap_or(b"")); (Json::null(), None) }
        "finish" => { self.host.tcp_end(id); (Json::null(), None) }
        "reset" => { self.host.tcp_close(id); (Json::null(), None) }
        _ => (Json::null(), None)
      }
    id => {
      let asked : Map[String, Json] = { "id": id }
      if code is Some(c) { asked["code"] = c }
      match bytes {
        Some(b) => self.host.shell("istream." + call, Json::object(asked), bytes=b)
        None => self.host.shell("istream." + call, Json::object(asked))
      }
    }
  }
}

///|
pub async fn World::stream_finish(self : World, stream : J) -> Unit {
  ignore(self.stream_call(stream, "finish")) catch { _ => () }
}

///|
pub async fn World::stream_reset(self : World, stream : J, code : Int) -> Unit {
  ignore(self.stream_call(stream, "reset", code=Json::number(code.to_double()))) catch { _ => () }
}

///|
pub async fn World::stream_stopped(self : World, stream : J) -> Unit {
  ignore(self.stream_call(stream, "stopped")) catch { _ => () }
}

// ── direct async FS, platform/random & store reads ──

///|
pub async fn World::fs_stat(self : World, p : String) -> @host_world.LstatInfo? {
  match (@host_world.fs_lstat(self.host, p) catch { _ => return None }) {
    Some({ kind: "link", .. }) =>
      match (@host_world.fs_realpath(self.host, p) catch { _ => return None }) {
        Some(r) => match (@host_world.fs_lstat(self.host, r) catch { _ => return None }) {
          Some({ kind: "link", .. }) => None
          other => other
        }
        None => None
      }
    other => other
  }
}

///|
pub async fn World::fs_mkdir(self : World, p : String) -> Unit {
  ignore(self.host.shell("fs.mkdir", { "path": Json::string(p), "recursive": Json::boolean(true) }))
}

///|
pub async fn World::fs_copy(self : World, from : String, to : String) -> Unit {
  if self.host.shell("fs.stat", { "path": Json::string(from) }).0 is Null {
    raise fail_("ENOENT: no such file or directory, copyfile '\{from}'")
  }
  if from == to { return }
  match (@host_world.fs_lstat(self.host, to) catch { _ => None }) {
    Some({ kind: k, .. }) if k != "dir" => @host_world.fs_remove(self.host, to) catch { _ => () }
    _ => ()
  }
  ignore(self.host.shell("fs.copy", { "from": Json::string(from), "to": Json::string(to) }))
}

///|
pub async fn World::fs_mkdtemp(self : World, prefix : String) -> String {
  let dir = @nodepath.join(@drive.sep(), [@drive.tmpdir(), prefix + @drive.hex(@drive.random_bytes(4))])
  self.fs_mkdir(dir)
  ignore(self.host.shell("fs.chmod", { "path": Json::string(dir), "mode": Json::number((0o700).to_double()) })) catch { _ => () }
  dir
}

///|
fn random_int(lo : Int, hi : Int) -> Int {
  let r = @drive.random_bytes(4)
  let n = (r[0].to_int() << 16) | (r[1].to_int() << 8) | r[2].to_int()
  lo + n % (if hi > lo { hi - lo } else { 1 })
}

///|
fn platform_os() -> String {
  if @drive.is_mac() { "macos" } else if @drive.is_windows() { "windows" } else { "linux" }
}

///|
pub fn World::get_session(self : World, key : String) -> J {
  match (try { Ok(self.sessions.get_session(key)) } catch { e => Err(e) }) {
    Ok(Object(_) as row) => @jsjson.jval_of_json(row)
    _ => Null
  }
}

///|
pub fn World::starter(self : World, session : String) -> String? raise {
  match self.threads.starter(Json::string(session)) { String(s) => Some(s); _ => None }
}

///|
/// Logged as the station logs: its level, part, words and fields.
pub async fn World::log(
  self : World,
  level : String,
  part : String,
  words : String,
  fields : J,
) -> Unit {
  ignore(self.ask("log." + level, [js(part), js(words), fields])) catch {
    _ => ()
  }
}

///|
/// The station's words in `lang` (i18n.ts `tr`).
pub fn World::tr(
  self : World,
  lang : String,
  key : String,
  args~ : Array[(String, String)] = [],
) -> String {
  self.words.tr(lang, key, args~)
}

///|
/// What a refusal of these parts is (`instanceof Refused`, `DeviceAsk`...): a Thrown of its kind.
pub fn refused(kind : String, message : String) -> Thrown {
  Thrown(kind, message)
}

///|
pub fn kind_of(e : Error) -> String {
  @session_chats.thrown_kind(e)
}

///|
pub fn message_of(e : Error) -> String {
  thrown_message(e)
}

// ── what reading a value goes by ──

///|
pub fn text_of(v : J?) -> String {
  str_of(v).unwrap_or("")
}

///|
/// A field of an object, Null where it has none.
pub fn get(v : J, name : String) -> J {
  at(Some(v), name).unwrap_or(Null)
}

///|
/// Whether an object has field `name` (`name in o`, `o.name !== undefined`).
pub fn has(v : J, name : String) -> Bool {
  at(Some(v), name) is Some(_)
}

///|
pub fn list_of(v : J?) -> Array[J] {
  arr_of(v).unwrap_or([])
}

///|
pub fn num_text(d : Double) -> String {
  @session_chats.num_text(d)
}

///|
pub fn int_text(i : Int) -> String {
  i.to_string()
}

///|
/// `JSON.stringify(v, null, 2)`.
pub fn pretty(v : J) -> String {
  @jsjson.stringify_indent(v, 2)
}

///|
/// The string's UTF-16 length (`s.length`).
pub fn js_length(s : String) -> Int {
  s.length()
}

///|
/// `s.slice(a, b)` by UTF-16 units.
pub fn js_slice(s : String, a : Int, b? : Int) -> String {
  @jsjson.js_slice(s, a, end?=b)
}

///|
/// `s.trim()` (JavaScript's white space and line ends).
pub fn js_trim(s : String) -> String {
  @jsjson.trim_js(s)
}

///|
/// What JSON a number is (`Number.isInteger`).
pub fn is_int(d : Double) -> Bool {
  !d.is_nan() && !d.is_inf() && d.floor() == d
}

///|
/// `Math.floor`.
pub fn floor(d : Double) -> Double {
  d.floor()
}

///|
/// The station's own language set (`setStationLang`).
pub fn World::set_lang(self : World, lang : String) -> Unit {
  self.lang = lang
}

///|
/// `Number(s)` of a string.
pub fn js_num(s : String) -> Double {
  if js_trim(s) == "" {
    0.0
  } else {
    @session_chats.js_number(js(s)).unwrap_or(@double.not_a_number)
  }
}
