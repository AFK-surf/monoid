// Tasks on other stations of the workspace (station/src/jobs/remote.ts): what of them is the transport's and the
// machine's, which the sessions' program (station/mb src/reader/remote*.mbt, the pseudo-actor `#remote`) asks for. A
// task's files sent and fetched (`station_file`: whole after one request, or in CHUNK pieces to and from a station from
// before, 1 GiB at most), what a task brings back (`station-back/<key>` of its session's workspace, and the patch of
// what it changed in a synced directory), how this station is (`describe`) and the stations of its workspace
// (`station_list`), a source session's room here, and the sweeps of what is kept (what was brought back after 6 h, a
// task's records after 7 d, a room after 14 d unused).

///|
pub let chunk : Int = 256 * 1024

///|
pub let max_file : Double = 1073741824.0

///|
let patch_max : Int = 64 * 1024 * 1024

///|
pub let idle_ms : Double = 14.0 * 24.0 * 3600.0 * 1000.0

///|
pub let give_up_ms : Double = 600_000.0

///|
pub let mirror_idle_ms : Double = 24.0 * 3600.0 * 1000.0

///|
pub let mirror_recent_ms : Double = 3600.0 * 1000.0

///|
pub let sync_answer_ms : Int = 40_000

///|
pub let gets_max : Int = 200

///|
pub let list_wait_ms : Int = 2000

///|
pub let list_alone_wait_ms : Int = 10_000

///|
pub let load_wait_ms : Int = 1000

///|
pub let back_kept_ms : Double = 6.0 * 3600_000.0

///|
pub let back_tidy_ms : Double = 3600_000.0

///|
pub let latest_most : Int = 100_000

///|
pub let remote_budget_most : Double = 32.0 * 1073741824.0

///|
pub let room_recent_ms : Double = 3600_000.0

///|
pub let tasks_kept_ms : Double = 7.0 * 24.0 * 3600_000.0

///|
let sandbox_prefix : String = "sandbox:"

///|
/// What safe mode says of a station it leaves out of the roster (cloud/state.ts `UNPROTECTED`).
pub let unprotected_words : String = "this station is not in the workspace's safe mode, so chats here cannot call it; its owner can add it to safe mode in still.fail"

///|
/// How a request to another station failed (mesh/bus.ts): it answered with an error (`Refused`), no link to it would
/// open (`NoLink`), it takes no bytes after a request (`NoBytes`: a station from before), or it could not be asked
/// (`Unreached`, asked again later).
pub(all) suberror PeerError {
  Refused(String)
  NoLink(String)
  NoBytes(String)
  Unreached(String)
}

///|
/// Its words as they are, where an error is said (`to_string`): without it MoonBit says only the type's name
/// ("station/jobs_host.PeerError.Refused" told an agent in place of what the other station said).
pub impl Show for PeerError with output(self, logger) {
  match self {
    Refused(s) | NoLink(s) | NoBytes(s) | Unreached(s) => logger.write_string(s)
  }
}

///|
fn peer_words(e : Error) -> String {
  match e {
    Refused(s) | NoLink(s) | NoBytes(s) | Unreached(s) => s
    other => words_of(other)
  }
}

///|
/// Bytes after a request's or an answer's head: in memory, or a file's from `from` to `end`, read as they go.
pub(all) enum Body {
  Data(Bytes)
  File(String, Double, Double)
}

///|
/// A request to a station of the workspace and its answer, each with what bytes follow it.
pub type Ask = async (String, Json, Body?) -> (Json, Body?)

///|
/// What a request came to within its wait: its answer, how it failed, or none yet (None).
pub(all) enum Got {
  Answered(Json)
  Failed(Error)
}

///|
/// `what`, or None when it has not settled within `ms` (it goes on no further).
pub async fn bounded(ms : Int, what : async () -> Json) -> Got? {
  @effect.timeout(ms, async fn() -> Got {
    try what() catch {
      e => Failed(e)
    } noraise {
      v => Answered(v)
    }
  }) catch {
    _ => None
  }
}

///|
/// What station_list says of a station asked `describe` (`got`, None when it did not answer within LIST_WAIT_MS), its
/// version as the roster has it being `seen`.
pub fn heard(got : Got?, seen : Json) -> Json {
  let copy : Array[(String, Json)] = match seen {
    String(s) => [("version_seen", jstr(s))]
    _ => []
  }
  match got {
    None =>
      obj(
        copy +
        [
          (
            "unanswered",
            jstr(
              "did not answer within \{js_number(list_wait_ms.to_double() / 1000.0)} s; not known to be offline: ask it alone",
            ),
          ),
        ],
      )
    Some(Failed(Refused(m))) => obj(copy + [("refused", jstr(m))])
    Some(Failed(NoLink(m))) => obj(copy + [("offline", jstr(m))])
    Some(Failed(e)) =>
      obj(copy + [("unanswered", jstr("\{peer_words(e)}; not known to be offline: ask it alone"))])
    Some(Answered(ok)) => {
      let says = match ok {
        Object(_) => field(ok, "version")
        _ => None
      }
      let version : Array[(String, Json)] = match says {
        Some(String(v)) => [("version", jstr(v))]
        _ => copy
      }
      obj(version + [("load", jstr(summary(field_or_null(ok, "load"))))])
    }
  }
}

///|
/// A plain JSON value as `JSON.stringify` writes it.
fn js_json(v : Json) -> @jsjson.JValue {
  @jsjson.JValue::of_json(v)
}

///|
/// The name a source session, task or record goes by: sha256 of its parts as compact JSON.
pub fn remote_hash(v : Json) -> String {
  @memory.sha256_hex(@utf8.encode(@jsjson.stringify(js_json(v))))
}

///|
/// remote/sessions' budget on a disk of `total` bytes (none known: its most).
pub fn remote_budget(total : Double?) -> Double {
  match total {
    Some(t) if t > 0.0 => {
      let share = (t * 0.15).floor()
      if share < remote_budget_most {
        share
      } else {
        remote_budget_most
      }
    }
    _ => remote_budget_most
  }
}

///|
/// STANDARD base64 as the Rust decodes it: padded, nothing else in it.
pub fn from_base64(data : String) -> Bytes raise {
  let n = data.length()
  let mut pad = 0
  let mut ok = n % 4 == 0
  for i in 0..<n {
    let c = data.unsafe_charcode_at(i)
    if c == '=' {
      pad += 1
    } else if pad > 0 ||
      !(is_alpha_unit(c) || is_digit(c) || c == '+' || c == '/') {
      ok = false
    }
  }
  if !ok || pad > 2 {
    raise HostError("Invalid input length or symbol")
  }
  @base64.decode(data)
}

///|
/// The OS and architecture as Rust's std::env::consts name them, of Node's names.
pub fn rust_arch(arch : String) -> String {
  match arch {
    "arm64" => "aarch64"
    "x64" => "x86_64"
    "ia32" => "x86"
    "arm" => "arm"
    a => a
  }
}

///|
/// `describe`'s answer: what this station takes, how busy it is (`load`: None, it says nothing of it), and what more
/// this machine says of itself.
pub fn describe_answer(version : String, os : String, arch : String, load : Json?, more : Json?) -> Json {
  let m : Map[String, Json] = {
    "protocol": jint(1),
    "version": jstr(version),
    "os": jstr(os),
    "arch": jstr(rust_arch(arch)),
    "tasks": jbool(true),
    "sessions": jbool(true),
    "messages": jbool(true),
    "reads": jbool(true),
    "files": jbool(true),
    "chats": jbool(true),
    "sync": jint(1),
    "smallTasks": jint(1),
    "fileChunkBytes": jint(chunk),
    "maxFileBytes": jnum(max_file),
  }
  match load {
    Some(l) => m["load"] = l
    None => ()
  }
  match more {
    Some(Object(extra)) => for k, v in extra { m[k] = v }
    _ => ()
  }
  Json::object(m)
}

///|
/// How busy this station is, measured within LOAD_WAIT_MS, or why it is not known.
pub async fn measured_load(load : (async () -> Json)?) -> Json {
  guard load is Some(read) else { return obj([("unavailable", jstr("not measured"))]) }
  match bounded(load_wait_ms, read) {
    None => obj([("unavailable", jstr("not measured within \{js_number(load_wait_ms.to_double() / 1000.0)} s"))])
    Some(Answered(v)) => v
    Some(Failed(e)) => obj([("unavailable", jstr(peer_words(e)))])
  }
}

///|
/// A sandbox of this station's as station_list says it (agents/sandbox.ts `sandboxDescribed` of it).
pub(all) struct Sandbox {
  name : String
  described : Json
}

///|
fn without(v : Json, keys : Array[String]) -> Map[String, Json] {
  match v {
    Object(m) => {
      let out = m.copy()
      for k in keys {
        out.remove(k)
      }
      out
    }
    _ => Map([])
  }
}

///|
fn merged(a : Map[String, Json], b : Json) -> Json {
  let out = a.copy()
  match b {
    Object(m) => for k, v in m { out[k] = v }
    _ => ()
  }
  Json::object(out)
}

///|
/// station_list (remote.ts `listStations`): the stations of `workspace` from its roster, each asked how busy it is at
/// once (this one answers itself, `own_load`), one not answered within LIST_WAIT_MS listed unanswered; its rigs after
/// (what `rig_said` says of each), its sandboxes, then those safe mode leaves out, not asked.
pub async fn list_stations(
  roster_answer : Json,
  own : String,
  version : String,
  own_load : async () -> Json,
  ask : async (String) -> Json,
  sandboxes : Array[Sandbox],
  rig_said : (async (Json, Json?) -> Json)?,
) -> Json {
  let unprotected = field_or_null(roster_answer, "unprotected")
  let roster = without(roster_answer, ["unprotected"])
  let stations = match roster.get("stations") {
    Some(Array(a)) => a
    _ => []
  }
  let left = match unprotected {
    Array(a) =>
      a.map(entry => merged(without(entry, []), obj([("unprotected", jstr(unprotected_words))])))
    _ => []
  }
  let jobs = stations.map(entry => async fn() -> Json {
    let id = text(entry, "id")
    if id == "" {
      return entry
    }
    let seen = field_or_null(entry, "version")
    let rest = without(entry, ["version"])
    if id == own {
      let l = own_load()
      return merged(rest, obj([("here", jbool(true)), ("version", jstr(version)), ("load", jstr(summary(l)))]))
    }
    let got = bounded(list_wait_ms, async fn() { ask(id) })
    merged(rest, heard(got, seen))
  })
  let listed = @effect.all(jobs)
  for d in sandboxes {
    listed.push(merged({ "id": jstr(sandbox_prefix + d.name), "name": jstr(d.name) }, d.described))
  }
  let rigs = match roster.get("rigs") {
    Some(Array(a)) => a
    _ => []
  }
  match (rigs.length(), rig_said) {
    (0, _) | (_, None) => {
      let out = roster.copy()
      out["stations"] = Json::array(listed + left)
      out.remove("rigs")
      out.remove("rigsWaiting")
      Json::object(out)
    }
    (_, Some(said)) => {
      let listed_rigs = @effect.all(
        rigs.map(rig => async fn() -> Json {
          let entry = { "id": jstr(text(rig, "id")), "name": jstr(text(rig, "name")) }
          let got = bounded(list_wait_ms, async fn() { ask(text(rig, "id")) })
          let described = match got {
            Some(Answered(v)) => Some(v)
            _ => None
          }
          let first = merged(entry, said(rig, described))
          match first {
            Object(m) => merged(m, heard(got, field_or_null(rig, "version")))
            _ => first
          }
        }),
      )
      let out = without(Json::object(roster), ["rigs", "rigsWaiting"])
      out["stations"] = Json::array(listed + listed_rigs + left)
      Json::object(out)
    }
  }
}

///|
/// The id of the station an agent names (remote.ts `stationNamed`): one of its sandboxes, a station's id or name in
/// the roster (`roster`: None where it could not be asked), else as given.
pub fn station_named(named : String, sandboxes : Array[String], roster : Json?) -> String raise {
  if named == "" {
    return named
  }
  let lower = @jscase.lower(named)
  for d in sandboxes {
    if @jscase.lower(sandbox_prefix + d) == lower || @jscase.lower(d) == lower {
      return sandbox_prefix + d
    }
  }
  guard roster is Some(r) else { return named }
  let stations = []
  for key in ["stations", "rigs", "unprotected"] {
    match field(r, key) {
      Some(Array(a)) => stations.push_iter(a.iter())
      _ => ()
    }
  }
  if stations.iter().any(s => text(s, "id") == named) {
    return named
  }
  let same = stations.filter(s => @jscase.lower(text(s, "name")) == lower)
  if same.length() > 1 {
    raise HostError(
      "\{same.length()} stations are named \{named}; give the id station_list shows for the one meant",
    )
  }
  if same.length() == 1 {
    return text(same[0], "id")
  }
  let waiting = match field(r, "rigsWaiting") {
    Some(Array(a)) =>
      a.search_by(w => text(w, "id") == named || @jscase.lower(text(w, "name")) == lower).map(k => a[k])
    _ => None
  }
  match waiting {
    Some(w) => {
      let name = if text(w, "name") != "" { text(w, "name") } else { named }
      let owner = if text(w, "owner_email") != "" { text(w, "owner_email") } else { text(w, "owner") }
      raise HostError(
        "the station \{name} is not taken into this workspace yet: its owner \{owner} has to check its security code in still.fail first",
      )
    }
    None => named
  }
}

///|
/// The workspace a session's tasks go in (mesh/cloud.json as `state`): its chat's (`own`), the home one for those from
/// before; while the station is still in it.
pub fn task_workspace(state : Json, own : String?) -> String raise {
  if state is Null {
    raise HostError("station has no workspace")
  }
  match field(state, "removed_at") {
    None | Some(Null) => ()
    Some(_) => raise HostError("station was removed from workspace")
  }
  let home = text(state, "workspace")
  if home == "" {
    raise HostError("station has no workspace")
  }
  let ws = own.unwrap_or(home)
  let joined = match field(state, "joined") {
    Some(Array(a)) => a.iter().any(j => text(j, "workspace") == ws)
    _ => false
  }
  if ws != home && !joined {
    raise HostError("station is no longer in this chat's workspace")
  }
  ws
}

///|
/// Stations on which a session has a remote workspace (its use `record`), within the workspace it still belongs to;
/// None for none.
pub fn targets_of(record : Json?, workspace : String) -> Json? {
  guard record is Some(r) && !(r is Null) else { return None }
  if field(r, "closing") is Some(True) || text(r, "workspace") != workspace {
    return None
  }
  guard field(r, "stations") is Some(Array(stations)) else { return None }
  Some(
    obj([
      ("workspace", jstr(workspace)),
      (
        "stations",
        Json::array(
          stations.filter(s => match s {
            String(t) => t != ""
            _ => false
          }),
        ),
      ),
    ]),
  )
}

///|
/// A chat's use record once it used `station` (remote.ts `recordUse`): None where it is as it was.
pub fn record_used(had : Json?, workspace : String, session : String, station : String) -> Json? raise {
  let known = match had {
    Some(h) =>
      match field(h, "stations") {
        Some(Array(a)) => a.iter().any(s => s == jstr(station))
        _ => false
      }
    None => false
  }
  match had {
    Some(h) if known && !(field(h, "closing") is Some(True)) => return None
    _ => ()
  }
  let v : Map[String, Json] = match had {
    None | Some(Null) => { "session": jstr(session), "workspace": jstr(workspace), "stations": Json::array([]) }
    Some(Object(m)) => m.copy()
    Some(_) => raise HostError("bad record")
  }
  if !known {
    match v.get("stations") {
      Some(Array(a)) => v["stations"] = Json::array(a + [jstr(station)])
      _ => raise HostError("bad record")
    }
  }
  v["closing"] = jbool(false)
  v["closed"] = Json::array([])
  v["workspace"] = jstr(workspace)
  Some(Json::object(v))
}

///|
/// A chat's use record as its session closes (remote.ts `closeSession`): told to close, since `since`.
pub fn record_closing(had : Json?, since : Double) -> Json? {
  match had {
    Some(Object(m)) => {
      let v = m.copy()
      v["closing"] = jbool(true)
      v["since"] = jnum(since)
      Some(Json::object(v))
    }
    _ => None
  }
}

// ── the machine's side of a task's files ──

///|
async fn is_link(host : @host.Host, path : String) -> Bool {
  match lstat(host, path) {
    Some(st) => text(st, "kind") == "link"
    None => false
  }
}

///|
async fn there(host : @host.Host, path : String) -> Bool {
  match try_ask(host, "fs.stat", { "path": jstr(path) }) {
    Some(String(_)) => true
    _ => false
  }
}

///|
/// Relative paths only; transfers must not follow links planted by a task (remote.ts `filePath`).
pub async fn file_path(host : @host.Host, root : String, relative : String, create : Bool) -> String raise {
  match lstat(host, root) {
    Some(st) if text(st, "kind") == "link" => raise HostError("transfer root is a symbolic link")
    Some(_) => ()
    None => raise HostError("ENOENT: no such file or directory, lstat '\{root}'")
  }
  let given = if relative == "" { None } else { @nodepath.relative_parts("/", relative) }
  let parts = []
  let mut bad = given is None
  for i, part in given.unwrap_or([]) {
    if part == "" {
      continue
    }
    if part == "." {
      if i == 0 {
        bad = true
      }
      continue
    }
    parts.push(part)
  }
  if bad || parts.is_empty() {
    raise HostError("file path must be relative, without . or ..")
  }
  let mut out = root
  for part in parts {
    out = pjoin([out, part])
    if is_link(host, out) {
      raise HostError("file path contains a symbolic link")
    }
  }
  if create {
    mkdirs(host, @nodepath.dirname("/", out))
  }
  out
}

///|
let piece_bytes : Int = 1024 * 1024

///|
/// A body's bytes a piece at a time.
async fn each_piece(host : @host.Host, body : Body, f : async (Bytes) -> Unit) -> Unit raise {
  match body {
    Data(b) => if b.length() > 0 { f(b) }
    File(path, start, end) => {
      let mut at = start
      while at < end {
        let n = if end - at < piece_bytes.to_double() { (end - at).to_int() } else { piece_bytes }
        let h = ask(host, "fs.bytes", { "path": jstr(path), "from": jnum(at), "length": jint(n) })
        let piece = match h {
          String(x) => @hex.decode(x)
          _ => raise HostError("ENOENT: no such file or directory, open '\{path}'")
        }
        if piece.length() == 0 {
          raise HostError("the file got shorter while it was sent")
        }
        at += piece.length().to_double()
        f(piece)
      }
    }
  }
}

///|
/// `body` written into the file at `path` from `offset`, all of it; how many. More than `limit` from where the file
/// begins fails (mesh/files.ts `writeBytes`).
pub async fn write_body(host : @host.Host, path : String, body : Body, offset : Double, limit : Double) -> Double raise {
  let mut at = offset
  each_piece(host, body, async fn(piece) {
    if at + piece.length().to_double() > limit {
      raise HostError("more came than the file can be")
    }
    ignore(put(host, path, piece, offset=at, nofollow=true))
    at += piece.length().to_double()
  })
  at - offset
}

///|
/// `body` in memory, all of it; more than `limit` fails.
pub async fn read_body(host : @host.Host, body : Body, limit : Double) -> Bytes raise {
  let buf = @buffer.new()
  let mut size = 0.0
  each_piece(host, body, async fn(piece) {
    size += piece.length().to_double()
    if size > limit {
      raise HostError("more came than was asked for")
    }
    buf.write_bytes(piece)
  })
  buf.to_bytes()
}

///|
/// serde_json's as_u64.
fn as_u64(v : Json?) -> Double? {
  match v {
    Some(Number(d, ..)) if d >= 0.0 && d == d.floor() => Some(d)
    _ => None
  }
}

///|
/// What is at `path` as a file to be written: none there (made), a file (its size), else refused as Node's open is.
async fn writable(host : @host.Host, path : String) -> Unit raise {
  match lstat(host, path) {
    Some(st) =>
      match text(st, "kind") {
        "link" => raise HostError("ELOOP: too many symbolic links encountered, open '\{path}'")
        "dir" => raise HostError("EISDIR: illegal operation on a directory, open '\{path}'")
        "file" => ()
        _ => raise HostError("only regular files can be transferred")
      }
    None => ()
  }
}

///|
/// file.put (remote.ts `filePut`): an input of a task, whole after the request (`incoming`), or a chunk of base64 in
/// it from a station from before; {bytes, whole}.
pub async fn file_put(host : @host.Host, path : String, request : Json, incoming : Body?) -> Json raise {
  match incoming {
    Some(body) => {
      guard as_u64(field(request, "size")) is Some(size) && size <= max_file else {
        raise HostError("file limit exceeded")
      }
      writable(host, path)
      ignore(put(host, path, b"", offset=0.0, nofollow=true))
      if write_body(host, path, body, 0.0, size) != size {
        raise HostError("the file did not all come")
      }
      ignore(put(host, path, b"", offset=size, truncate=true, sync=true, nofollow=true))
      return obj([("bytes", jnum(size)), ("whole", jbool(true))])
    }
    None => ()
  }
  guard as_u64(field(request, "offset")) is Some(offset) else { raise HostError("offset is required") }
  let data = from_base64(text(request, "data"))
  if data.length() > chunk || offset + data.length().to_double() > max_file {
    raise HostError("file limit exceeded")
  }
  writable(host, path)
  let size = put(host, path, b"", offset=0.0, nofollow=true)
  if offset > size {
    raise HostError("file offset leaves a gap")
  }
  let last = field(request, "final") is Some(True)
  ignore(
    put(host, path, data, offset~, truncate=last, sync=last, nofollow=true),
  )
  obj([("bytes", jint(data.length())), ("whole", jbool(last))])
}

///|
/// file.get (remote.ts `fileGet`): a task's file, all of it from `offset` after the answer, or a chunk to a station
/// from before.
pub async fn file_get(host : @host.Host, path : String, request : Json) -> (Json, Body?) raise {
  guard lstat(host, path) is Some(st) else {
    raise HostError("ENOENT: no such file or directory, open '\{path}'")
  }
  if text(st, "kind") == "link" {
    raise HostError("ELOOP: too many symbolic links encountered, open '\{path}'")
  }
  if text(st, "kind") != "file" {
    raise HostError("only regular files can be transferred")
  }
  let size = num(field(st, "size")).unwrap_or(0.0)
  if size > max_file {
    raise HostError("file limit exceeded")
  }
  let offset = as_u64(field(request, "offset")).unwrap_or(0.0)
  if offset > size {
    raise HostError("offset past end")
  }
  if field(request, "whole") is Some(True) {
    return (obj([("size", jnum(size))]), Some(File(path, offset, size)))
  }
  let piece = match ask(host, "fs.bytes", { "path": jstr(path), "from": jnum(offset), "length": jint(chunk) }) {
    String(h) => @hex.decode(h)
    _ => b""
  }
  let n = piece.length().to_double()
  (
    obj([
      ("data", jstr(@base64.encode(piece))),
      ("size", jnum(size)),
      ("eof", jbool(offset + n >= size)),
    ]),
    None,
  )
}

///|
/// A file of a task's station (`request`'s path) to `path` here, whole after one answer (a station from before answers
/// a chunk, and is asked for each); its size. An existing file is replaced only when `replace`.
pub async fn download(
  host : @host.Host,
  bulk : Bulk,
  ask_it : async (Json) -> (Json, Body?),
  request : Json,
  path : String,
  replace : Bool,
) -> Double raise {
  if !replace && there(host, path) {
    raise HostError("local output already exists; choose another path")
  }
  let temp = @nodepath.with_extension("/", path, "\{random_hex(host, 8)}.part")
  ignore(put(host, temp, b"", exclusive=true, offset=0.0))
  defer remove(host, temp)
  let mut offset = 0.0
  let mut size = 0.0
  while true {
    let req = merged(without(request, []), obj([("method", jstr("file.get")), ("offset", jnum(offset)), ("whole", jbool(true))]))
    let (answer, bytes) = bulk.run(async fn() {
      let (got, b) = ask_it(req)
      match b {
        Some(body) => offset += write_body(host, temp, body, offset, max_file)
        None => ()
      }
      (got, b)
    })
    if bytes is Some(_) {
      if Some(offset) != as_u64(field(answer, "size")) {
        raise HostError("the file did not all come")
      }
      ignore(put(host, temp, b"", offset~, sync=true))
      size = offset
      break
    }
    let data = from_base64(text(answer, "data"))
    if data.length() > chunk || offset + data.length().to_double() > max_file {
      raise HostError("invalid file response")
    }
    ignore(put(host, temp, data, offset~))
    offset += data.length().to_double()
    if field(answer, "eof") is Some(True) {
      ignore(put(host, temp, b"", offset~, sync=true))
      size = offset
      break
    }
    if data.length() == 0 {
      raise HostError("file transfer made no progress")
    }
  }
  if replace {
    rename(host, temp, path)
  } else {
    match ask(host, "fs.link", { "from": jstr(temp), "to": jstr(path) }) {
      False => raise HostError("EEXIST: file already exists, link '\{temp}' -> '\{path}'")
      _ => ()
    }
  }
  size
}

///|
/// A file of a task's station in memory; None when it is bigger than `limit`.
pub async fn fetch_file(
  host : @host.Host,
  bulk : Bulk,
  ask_it : async (Json) -> (Json, Body?),
  path : String,
  limit : Double,
) -> Bytes? raise {
  let parts = @buffer.new()
  let mut offset = 0.0
  while true {
    let req = obj([("method", jstr("file.get")), ("path", jstr(path)), ("offset", jnum(offset)), ("whole", jbool(true))])
    let got = bulk.run(async fn() -> (Bytes, Bool)? raise {
      let (answer, bytes) = ask_it(req)
      let size = as_u64(field(answer, "size")).unwrap_or(0.0)
      if size > limit {
        return None
      }
      match bytes {
        None => Some((from_base64(text(answer, "data")), field(answer, "eof") is Some(True)))
        Some(body) => {
          let data = read_body(host, body, limit)
          if offset + data.length().to_double() != size {
            raise HostError("the file did not all come")
          }
          Some((data, true))
        }
      }
    })
    guard got is Some((data, eof)) else { return None }
    parts.write_bytes(data)
    offset += data.length().to_double()
    if eof {
      return Some(parts.to_bytes())
    }
    if data.length() == 0 {
      raise HostError("file transfer made no progress")
    }
  }
  None
}

///|
/// `name` as a file's name on every system (ops/paths.ts `portableComponent`).
pub fn portable_component(name : String) -> String {
  if @memory.portable_name(name) {
    return name
  }
  let out = StringBuilder::new()
  for i in 0..<name.length() {
    let c = name.unsafe_charcode_at(i)
    let bad = c < 0x20 ||
      c == '<' ||
      c == '>' ||
      c == ':' ||
      c == '"' ||
      c == '/' ||
      c == '\\' ||
      c == '|' ||
      c == '?' ||
      c == '*'
    out.write_char(if bad { '_' } else { Int::unsafe_to_char(c) })
  }
  let mut kept = out.to_string()
  if starts(kept, ".") {
    kept = "_" + from(kept, 1)
  }
  kept = slice(kept, 0, 64)
  "\{kept}-\{slice(@memory.sha256_hex(@utf8.encode(name)), 0, 12)}"
}

///|
/// After a task ends (remote.ts `bringBack`): what it was to bring back (into station-back/<key> of its session's
/// workspace, `workspace`), and, for a task with a directory, the synced files its command changed there, as a patch.
/// An Unreached when its station could not be asked.
pub async fn bring_back(
  host : @host.Host,
  bulk : Bulk,
  peer : Ask,
  entry : Json,
  workspace : String?,
  root : String,
) -> Json raise {
  let station = text(entry, "station")
  let key = text(entry, "key")
  let base = obj([
    ("workspace", field_or_null(entry, "workspace")),
    ("session", field_or_null(entry, "session")),
    ("key", jstr(key)),
  ])
  let ask_it = async fn(request : Json) -> (Json, Body?) raise {
    let req = match base {
      Object(m) => merged(m, request)
      _ => request
    }
    peer(station, req, None) catch {
      Refused(m) => raise Refused(m)
      e => raise Unreached(peer_words(e))
    }
  }
  guard workspace is Some(ws) else { return obj([("error", jstr("the session is gone"))]) }
  let dest = pjoin([ws, "station-back", portable_component(key)])
  let out : Map[String, Json] = Map([])
  let back = match field(entry, "back") {
    Some(Array(a)) => a
    _ => []
  }
  if back.length() > 0 {
    let mut files : Array[(String, Json)] = []
    let mut prefix = ""
    try {
      let (found, _) = ask_it(obj([("method", jstr("task.files")), ("paths", Json::array(back))]))
      files = match field(found, "files") {
        Some(Array(fs)) =>
          fs.filter_map(f => match f {
            [String(p), size] => Some((p, size))
            [p, size] => Some((js_text(p), size))
            _ => None
          })
        _ => []
      }
      prefix = if text(found, "base") == "" { "" } else { text(found, "base") + "/" }
    } catch {
      Refused(m) if index_of(m, "unsupported peer method") >= 0 =>
        files = back.map(p => (js_text(p), jint(0)))
      e => raise e
    }
    mkdirs(host, dest)
    let got = []
    let missing = []
    for f in files {
      let (p, size) = f
      if size is Null {
        missing.push(jstr("\{p}: not there"))
        continue
      }
      try {
        ignore(
          download(
            host,
            bulk,
            ask_it,
            obj([("path", jstr(prefix + p))]),
            file_path(host, dest, p, true),
            true,
          ),
        )
        got.push(jstr(p))
      } catch {
        Unreached(m) => raise Unreached(m)
        e => missing.push(jstr("\{p}: \{peer_words(e)}"))
      }
    }
    out["files"] = obj([
      ("dir", jstr(dest)),
      ("count", jint(got.length())),
      ("files", Json::array(if got.length() > 50 { got[0:50].to_array() } else { got })),
      ("missing", Json::array(missing)),
    ])
  }
  match field(entry, "dir") {
    Some(String(dir)) => {
      let found = try {
        let (f, _) = ask_it(obj([("method", jstr("sync.changes"))]))
        f
      } catch {
        Unreached(m) => raise Unreached(m)
        e => {
          out["changed"] = obj([("error", jstr(peer_words(e)))])
          return Json::object(out)
        }
      }
      let changes = match field(found, "changes") {
        Some(Array(a)) => a
        _ => []
      }
      if changes.length() > 0 {
        let items = []
        let missing = []
        let mut total = 0
        for c in changes {
          let mut after : Bytes? = None
          let new_mode = field(c, "newMode")
          if new_mode == Some(jstr(mode_link)) {
            after = Some(@utf8.encode(js_text_or_empty(field(c, "link"))))
          } else if !(field_or_null(c, "hash") is Null) {
            after = fetch_file(
              host,
              bulk,
              ask_it,
              "\{text(found, "base")}/\{js_text_or_empty(field(c, "path"))}",
              (patch_max - total).to_double(),
            ) catch {
              Unreached(m) => raise Unreached(m)
              _ => None
            }
            match after {
              None => {
                missing.push(js_text_or_empty(field(c, "path")))
                continue
              }
              Some(a) => total += a.length()
            }
          }
          items.push(Change::{
            path: js_text_or_empty(field(c, "path")),
            old: js_text_or_empty(field(c, "old")),
            mode: js_text_or_empty(field(c, "mode")),
            after,
            after_mode: match new_mode {
              Some(String(m)) => Some(m)
              _ => None
            },
          })
        }
        let made = patch_of(
          host,
          dir,
          text(entry, "prefix"),
          pjoin([root, "patch-\{random_hex(host, 6)}"]),
          items,
        )
        let paths = changes.map(c => field_or_null(c, "path"))
        let changed : Map[String, Json] = {
          "count": jint(changes.length()),
          "more": jbool(field(found, "more") is Some(True)),
          "files": Json::array(if paths.length() > 50 { paths[0:50].to_array() } else { paths }),
          "note": jstr("the command changed these synced files on that station; nothing here was changed"),
        }
        match made {
          Some(p) if p.patch != "" => {
            mkdirs(host, dest)
            let file = pjoin([dest, "changes.patch"])
            ignore(put(host, file, @utf8.encode(p.patch), offset=0.0, truncate=true))
            changed["patch"] = jstr(file)
            changed["apply"] = jstr("review it, then git apply it in \{dir} if wanted")
          }
          _ => ()
        }
        let left = missing +
          (match made {
            Some(p) => p.missing
            None => changes.map(c => js_text_or_empty(field(c, "path")))
          })
        if left.length() > 0 {
          changed["notInPatch"] = Json::array(
            (if left.length() > 50 { left[0:50].to_array() } else { left }).map(jstr),
          )
        }
        out["changed"] = Json::object(changed)
      }
    }
    _ => ()
  }
  Json::object(out)
}

///|
/// station_file (remote.ts `stationFile`): an input uploaded, an output downloaded into `root`, the session's
/// workspace.
pub async fn station_file(
  host : @host.Host,
  bulk : Bulk,
  peer : Ask,
  station : String,
  request : Json,
  args : Json,
  root : String,
) -> Json raise {
  let local = text(args, "local")
  let mut relative = local
  if starts(local, "/") {
    let within = if local == root {
      Some("")
    } else {
      let prefix = if ends(root, "/") { root } else { root + "/" }
      if starts(local, prefix) {
        Some(from(local, prefix.length()))
      } else {
        None
      }
    }
    guard within is Some(w) else { raise HostError("local file must be inside this session workspace") }
    relative = w
  }
  let direction = text(args, "direction")
  let path = file_path(host, root, relative, direction == "download")
  let req = without(request, [])
  req["path"] = field_or_null(args, "path")
  if direction == "upload" {
    let st = lstat(host, path)
    match st {
      Some(s) if text(s, "kind") == "link" =>
        raise HostError("ELOOP: too many symbolic links encountered, open '\{path}'")
      None => raise HostError("ENOENT: no such file or directory, open '\{path}'")
      _ => ()
    }
    let s = st.unwrap()
    let size = num(field(s, "size")).unwrap_or(0.0)
    if text(s, "kind") != "file" || size > max_file {
      raise HostError("input must be a regular file of at most 1 GiB")
    }
    let whole = merged(req, obj([("method", jstr("file.put")), ("offset", jint(0)), ("size", jnum(size))]))
    let sent = try {
      ignore(bulk.run(async fn() { peer(station, whole, Some(File(path, 0.0, size))) }))
      true
    } catch {
      NoBytes(_) => false
      e => raise e
    }
    if sent {
      return obj([("uploaded", jstr(path)), ("bytes", jnum(size))])
    }
    let mut offset = 0.0
    while true {
      let piece = match ask(host, "fs.bytes", { "path": jstr(path), "from": jnum(offset), "length": jint(chunk) }) {
        String(h) => @hex.decode(h)
        _ => b""
      }
      let n = piece.length().to_double()
      req["method"] = jstr("file.put")
      req["offset"] = jnum(offset)
      req["data"] = jstr(@base64.encode(piece))
      req["final"] = jbool(offset + n == size)
      let one = Json::object(req.copy())
      ignore(bulk.run(async fn() { peer(station, one, None) }))
      offset += n
      if offset == size {
        break
      }
      if n == 0.0 {
        raise HostError("input changed while reading")
      }
    }
    return obj([("uploaded", jstr(path)), ("bytes", jnum(size))])
  }
  if direction == "download" {
    let size = download(host, bulk, async fn(r) { peer(station, r, None) }, Json::object(req), path, false)
    return obj([("downloaded", jstr(path)), ("bytes", jnum(size))])
  }
  raise HostError("direction must be upload or download")
}

// ── what is kept, swept ──

///|
/// When anything under `path` last changed (its own time for a file); +Infinity where it cannot be said (kept): past
/// `most` entries, deeper than the walk goes, or a walk that failed.
pub async fn latest_in(host : @host.Host, path : String, most? : Int = latest_most) -> Double {
  let infinity = @double.infinity
  let mut latest = @double.neg_infinity
  let mut visited = 0
  guard lstat(host, path) is Some(root) else { return infinity }
  visited += 1
  latest = num(field(root, "mtimeMs")).unwrap_or(latest)
  if text(root, "kind") != "dir" {
    return latest
  }
  let queue = [(path, 0)]
  let mut head = 0
  while head < queue.length() {
    let (dir, depth) = queue[head]
    head += 1
    let listed = match try_ask(host, "fs.readdir", { "path": jstr(dir), "types": jbool(true) }) {
      Some(Array(a)) => a
      _ => return infinity
    }
    for e in listed {
      if visited >= most + 1 {
        return infinity
      }
      guard e is [String(name), _] else { continue }
      let p = pjoin([dir, name])
      guard lstat(host, p) is Some(st) else { return infinity }
      visited += 1
      match num(field(st, "mtimeMs")) {
        Some(m) if m > latest => latest = m
        _ => ()
      }
      if text(st, "kind") == "dir" {
        if depth + 1 >= 32 {
          return infinity
        }
        queue.push((p, depth + 1))
      }
    }
  }
  if latest == @double.neg_infinity {
    infinity
  } else {
    latest
  }
}

///|
/// What tasks brought back (`station-back/<key>` of each of these workspaces) let go of once nothing in it changed for
/// BACK_KEPT_MS.
pub async fn tidy_back(host : @host.Host, workspaces : Array[String], now : Double) -> Array[String] {
  let gone = []
  for ws in workspaces {
    let back = pjoin([ws, "station-back"])
    for name in readdir(host, back).unwrap_or([]) {
      let dir = pjoin([back, name])
      if latest_in(host, dir) < now - back_kept_ms {
        remove(host, dir, recursive=true)
        gone.push(dir)
      }
    }
  }
  gone
}

///|
/// What processes gone left landed: each process's own directory, named by its pid (`alive` says which still run).
pub async fn tidy_landing(host : @host.Host, landing : String, own : Int, alive : async (Int) -> Bool) -> Unit {
  for name in readdir(host, landing).unwrap_or([]) {
    let pid = if all_digits(name) { digits_number(name) } else { -1.0 }
    if safe_integer(pid) && pid > 0.0 && (pid.to_int() == own || alive(pid.to_int())) {
      continue
    }
    remove(host, pjoin([landing, name]), recursive=true)
  }
}

///|
/// The size of a tree on its disk (ops/storage.ts `treeBytes`), as the footprint builder measures it.
pub fn tree_bytes(path : String) -> Double {
  let answer = @footprint.answer(
    obj([("path", jstr(path)), ("maxEntries", jint(1_000_000)), ("maxDurationMs", jint(60_000))]).stringify(),
    "/",
  )
  num(field(answer, "size")).unwrap_or(0.0)
}

///|
/// A source session's rooms here (remote/sessions/<hash>), and when each was last used.
pub struct Rooms {
  priv host : @host.Host
  root : String
  priv seen_at : Map[String, Double]
}

///|
pub fn Rooms::new(host : @host.Host, root : String) -> Rooms {
  { host, root, seen_at: Map([]) }
}

///|
pub fn Rooms::room(self : Rooms, workspace : String, peer : String, session : String) -> String {
  pjoin([self.root, "sessions", remote_hash(Json::array([jstr(workspace), jstr(peer), jstr(session)]))])
}

///|
/// Makes a source session's shared directory and notes when it was last used (at most once a minute): `write`, its
/// record is to be written saying `now`.
pub async fn Rooms::seen(
  self : Rooms,
  workspace : String,
  peer : String,
  session : String,
  now : Double,
) -> Json raise {
  let room = self.room(workspace, peer, session)
  let work = pjoin([room, "work"])
  match self.seen_at.get(room) {
    Some(last) if now - last < 60_000.0 =>
      return obj([("work", jstr(work)), ("write", jbool(false)), ("now", jnum(now))])
    _ => ()
  }
  mkdirs(self.host, work)
  self.seen_at[room] = now
  obj([("work", jstr(work)), ("write", jbool(true)), ("now", jnum(now))])
}

///|
pub fn Rooms::seen_at(self : Rooms, room : String) -> Double? {
  self.seen_at.get(room)
}

///|
pub fn Rooms::forget_seen(self : Rooms, room : String) -> Unit {
  self.seen_at.remove(room)
}

///|
/// A source session's tasks' directories and its room taken out of their places in one step, its use asked again just
/// before (`since`: used after it, nothing taken, None); `since` None, at once. {aside, room}.
pub async fn Rooms::close_room(self : Rooms, room : String, dirs : Array[String], since : Double?) -> Json {
  match since {
    Some(s) if self.seen_at.get(room).unwrap_or(0.0) > s => return Json::null()
    _ => ()
  }
  let aside = []
  for dir in dirs {
    let to = "\{dir}.gone-\{random_hex(self.host, 4)}"
    match try_ask(self.host, "fs.rename", { "from": jstr(dir), "to": jstr(to) }) {
      Some(_) => aside.push(jstr(to))
      None => ()
    }
  }
  let room_gone = "\{room}.gone-\{random_hex(self.host, 4)}"
  let moved = try_ask(self.host, "fs.rename", { "from": jstr(room), "to": jstr(room_gone) }) is Some(_)
  self.seen_at.remove(room)
  obj([("aside", Json::array(aside)), ("room", if moved { jstr(room_gone) } else { Json::null() })])
}
