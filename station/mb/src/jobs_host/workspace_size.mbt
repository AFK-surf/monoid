// A working chat's workspace on each station has a soft size limit (station/src/jobs/workspace-size.ts): measured one
// walk at a time (`WorkspaceReader`, a walk the footprint builder's: station/mb src/footprint), and a chat whose
// workspace is over its limit told so, then reminded hourly while it stays over (`WorkspaceWatch`), each chat's
// limits kept in workspace-limits/<sha256 of its session>.json.

///|
pub let gib_size : Double = 1073741824.0

///|
pub let default_limit : Double = 10.0 * 1073741824.0

///|
pub let check_ms : Double = 300_000.0

///|
pub let remind_ms : Double = 3_600_000.0

///|
/// The most of the sessions shown (the latest active first) a round looks at.
pub let measured_most : Int = 1000

///|
/// What a walk measured: `truncated`, a lower bound for the walk's own limits, not the soft limit.
pub(all) struct WorkspaceSize {
  bytes : Double
  complete : Bool
  truncated : Bool
} derive(Eq, Show)

///|
pub fn WorkspaceSize::to_json(self : WorkspaceSize) -> Json {
  let m : Map[String, Json] = { "bytes": jnum(self.bytes), "complete": jbool(self.complete) }
  if self.truncated {
    m["truncated"] = jbool(true)
  }
  Json::object(m)
}

///|
priv struct Measurement {
  mut size : WorkspaceSize?
  mut at : Double
  mut pending : Bool
  mut limit : Double
}

///|
/// A single walk at a time, shared by local and incoming remote requests. A caller never waits for the walk: it asks
/// again for the completed result. A fresh result is reused for CHECK_MS.
pub struct WorkspaceReader {
  priv now : () -> Double
  priv read : async (String, Double) -> WorkspaceSize
  priv fork : (async () -> Unit) -> Unit
  priv warn : (String, String) -> Unit
  priv entries : Map[String, Measurement]
  priv queue : Array[String]
  priv mut running : Bool
  priv mut closed : Bool
}

///|
/// `fork` runs what is started apart (a fiber of the program's); `warn`, a measure that failed.
pub fn WorkspaceReader::new(
  now : () -> Double,
  read : async (String, Double) -> WorkspaceSize,
  fork : (async () -> Unit) -> Unit,
  warn? : (String, String) -> Unit = (_, _) => (),
) -> WorkspaceReader {
  { now, read, fork, warn, entries: Map([]), queue: [], running: false, closed: false }
}

///|
/// What is known of `path` now (None: not yet; asked for meanwhile).
pub fn WorkspaceReader::size(
  self : WorkspaceReader,
  path : String,
  limit? : Double = default_limit,
) -> WorkspaceSize? {
  if self.closed {
    return None
  }
  self.sweep()
  match self.entries.get(path) {
    Some({ size: Some(s), at, .. }) if (self.now)() - at < check_ms &&
      (s.complete || s.truncated || s.bytes > limit) => return Some(s)
    _ => ()
  }
  let entry = match self.entries.get(path) {
    Some(e) => e
    None => {
      let e = { size: None, at: 0.0, pending: false, limit }
      self.entries[path] = e
      e
    }
  }
  if !entry.pending {
    entry.pending = true
    entry.limit = limit
    self.queue.push(path)
    self.next_soon()
  }
  None
}

///|
fn WorkspaceReader::next_soon(self : WorkspaceReader) -> Unit {
  if self.running {
    return
  }
  self.running = true
  (self.fork)(async fn() {
    while !self.closed && self.queue.length() > 0 {
      let path = self.queue.remove(0)
      guard self.entries.get(path) is Some(entry) else { continue }
      try {
        entry.size = Some((self.read)(path, entry.limit))
        entry.at = (self.now)()
      } catch {
        e => {
          entry.size = None
          if !self.closed {
            (self.warn)(path, words_of(e))
          }
        }
      }
      entry.pending = false
    }
    self.sweep()
    self.running = false
  })
}

///|
/// How many workspaces it keeps a measure of (or is measuring).
pub fn WorkspaceReader::kept(self : WorkspaceReader) -> Int {
  self.entries.length()
}

///|
/// Lets go of what no round asked for again: a measure not under way and older than two rounds.
fn WorkspaceReader::sweep(self : WorkspaceReader) -> Unit {
  let now = (self.now)()
  let gone = []
  for path, e in self.entries {
    if !e.pending && now - e.at >= 2.0 * check_ms {
      gone.push(path)
    }
  }
  for p in gone {
    self.entries.remove(p)
  }
}

///|
pub fn WorkspaceReader::close(self : WorkspaceReader) -> Unit {
  self.closed = true
  self.queue.clear()
}

///|
/// A ready measurement of a working session's workspace: `station` empty for the session's own station.
pub(all) struct WorkspaceReading {
  session : String
  station : String
  name : String
  path : String
  bytes : Double
  complete : Bool
} derive(Eq, Show)

///|
pub fn WorkspaceReading::from_json(v : Json) -> WorkspaceReading? {
  match v {
    {
      "session": String(session),
      "station": String(station),
      "name": String(name),
      "path": String(path),
      "bytes": Number(bytes, ..),
      "complete": complete,
      ..
    } => Some({ session, station, name, path, bytes, complete: complete is True })
    _ => None
  }
}

///|
priv struct Limit {
  bytes : Double
  over : Bool
  told : Double?
}

///|
/// Each chat's limits by station ("local" for its own), in the order JavaScript keeps an object's keys.
priv struct Limits {
  keys : Array[String]
  values : Map[String, Limit]
}

///|
fn Limits::get(self : Limits, key : String) -> Limit? {
  self.values.get(key)
}

///|
fn Limits::set(self : Limits, key : String, l : Limit) -> Unit {
  if !self.values.contains(key) {
    self.keys.push(key)
  }
  self.values[key] = l
}

///|
/// An array index's canonical text (JavaScript orders those keys first, as numbers).
fn index_key(k : String) -> Double? {
  @jsjson.index_key(k)
}

///|
fn js_key_order(keys : Array[String]) -> Array[String] {
  let ints = keys.filter(k => index_key(k) is Some(_))
  ints.sort_by((a, b) => index_key(a).unwrap_or(0.0).compare(index_key(b).unwrap_or(0.0)))
  let rest = keys.filter(k => index_key(k) is None)
  ints + rest
}

///|
/// `JSON.stringify` of a chat's limits.
fn Limits::stringify(self : Limits) -> String {
  let pairs = []
  for k in js_key_order(self.keys) {
    let l = self.values[k]
    pairs.push((
      k,
      @jsjson.JValue::Obj([
        ("bytes", Num(l.bytes)),
        ("over", Bool(l.over)),
        (
          "told",
          match l.told {
            Some(t) => Num(t)
            None => Null
          },
        ),
      ]),
    ))
  }
  @jsjson.stringify(Obj(pairs))
}

///|
/// What the watch does with the world: its clock, the readings ready, whether a chat is at work, a word to its agent.
pub(all) struct WatchIo {
  now : () -> Double
  readings : async () -> Array[WorkspaceReading]
  working : (String) -> Bool
  notify : async (String, String) -> Unit
  warn : (String, String) -> Unit
}

///|
/// Each working chat's workspace held to its soft limit: told once over it, reminded hourly while it stays over.
pub struct WorkspaceWatch {
  priv host : @host.Host
  priv io : WatchIo
  priv directory : String
  priv limits : Map[String, Limits]
  /// what each chat's file said as the watch began, by file name (None: it did not read)
  priv read : Map[String, String?]
}

///|
/// A watch over the limits kept in `data`/workspace-limits, every chat's read first (`ready`).
pub async fn WorkspaceWatch::new(host : @host.Host, data : String, io : WatchIo) -> WorkspaceWatch {
  let w = {
    host,
    io,
    directory: pjoin([data, "workspace-limits"]),
    limits: Map([]),
    read: Map([]),
  }
  w.read_all()
  w
}

///|
async fn WorkspaceWatch::read_all(self : WorkspaceWatch) -> Unit {
  mkdirs(self.host, self.directory) catch {
    _ => ()
  }
  for name in readdir(self.host, self.directory).unwrap_or([]) {
    if !ends(name, ".json") || self.read.contains(name) {
      continue
    }
    self.read[name] = read_text(self.host, pjoin([self.directory, name]))
  }
}

///|
fn file_name(session : String) -> String {
  @memory.sha256_hex(@utf8.encode(session)) + ".json"
}

///|
fn WorkspaceWatch::file(self : WorkspaceWatch, session : String) -> String {
  pjoin([self.directory, file_name(session)])
}

///|
/// A deleted chat's limits let go (an archived one keeps them).
pub async fn WorkspaceWatch::forget(self : WorkspaceWatch, session : String) -> Unit {
  self.limits.remove(session)
  self.read.remove(file_name(session))
  ignore(try_ask(self.host, "fs.remove", { "path": jstr(self.file(session)) }))
}

///|
fn WorkspaceWatch::of(self : WorkspaceWatch, session : String) -> Limits {
  match self.limits.get(session) {
    Some(l) => return l
    None => ()
  }
  let all : Limits = { keys: [], values: Map([]) }
  let name = file_name(session)
  let text = self.read.get(name)
  self.read.remove(name)
  match text {
    Some(Some(t)) =>
      match (try { Some(@jsjson.parse(t)) } catch { _ => None }) {
        Some(@jsjson.JValue::Obj(pairs)) => {
          // (a key said twice is its last value, at its first place)
          let order : Array[String] = []
          let last : Map[String, @jsjson.JValue] = Map([])
          for p in pairs {
            let (ku, v) = p
            let k = @jsjson.sanitize_str(ku)
            if !last.contains(k) {
              order.push(k)
            }
            last[k] = v
          }
          for station in js_key_order(order) {
            guard last.get(station) is Some(@jsjson.JValue::Obj(fields)) else { continue }
            let get = (name : String) => {
              let mut found : @jsjson.JValue? = None
              for f in fields {
                if @jsjson.sanitize_str(f.0) == name {
                  found = Some(f.1)
                }
              }
              found
            }
            guard get("bytes") is Some(Num(bytes)) &&
              safe_integer(bytes) &&
              bytes >= gib_size else {
              continue
            }
            all.set(station, {
              bytes,
              over: get("over") is Some(Bool(true)),
              told: match get("told") {
                Some(Num(t)) => Some(t)
                _ => None
              },
            })
          }
        }
        _ => ()
      }
    _ => ()
  }
  self.limits[session] = all
  all
}

///|
async fn WorkspaceWatch::save(self : WorkspaceWatch, session : String) -> Unit raise {
  let file = self.file(session)
  write_text(self.host, file, self.of(session).stringify())
  ignore(try_ask(self.host, "fs.chmod", { "path": jstr(file), "mode": jint(0o600) }))
}

///|
/// A chat's limit on a station ("" its own), in bytes.
pub fn WorkspaceWatch::limit(self : WorkspaceWatch, session : String, station : String) -> Double {
  match self.of(session).get(if station == "" { "local" } else { station }) {
    Some(l) => l.bytes
    None => default_limit
  }
}

///|
/// A chat's limit set (workspace_limit): whole GiB, its notice state begun anew. The bytes.
pub async fn WorkspaceWatch::set_limit(
  self : WorkspaceWatch,
  session : String,
  station : String,
  gib : Double,
) -> Double raise {
  if !safe_integer(gib) || gib < 1.0 || gib > (9007199254740991.0 / gib_size).floor() {
    raise HostError("limit_gib must be a positive whole number of GiB")
  }
  let bytes = gib * gib_size
  self.of(session).set(if station == "" { "local" } else { station }, {
    bytes,
    over: false,
    told: None,
  })
  self.save(session)
  bytes
}

///|
/// One look at every reading ready.
pub async fn WorkspaceWatch::look(self : WorkspaceWatch) -> Unit {
  let readings = (self.io.readings)() catch { _ => return }
  for reading in readings {
    self.consider(reading) catch {
      e => (self.io.warn)(reading.session, words_of(e))
    }
  }
}

///|
/// `x.toFixed(digits)` of a non-negative number whose ten-fold is exact (bytes over GiB).
fn to_fixed(x : Double, digits : Int) -> String {
  let scale = if digits == 0 { 1.0 } else { 10.0 }
  let n = (x * scale + 0.5).floor()
  if digits == 0 {
    return js_number(n)
  }
  let whole = (n / 10.0).floor()
  let tenth = (n - whole * 10.0).to_int()
  "\{js_number(whole)}.\{tenth}"
}

///|
async fn WorkspaceWatch::consider(self : WorkspaceWatch, reading : WorkspaceReading) -> Unit raise {
  if !(self.io.working)(reading.session) {
    return
  }
  let all = self.of(reading.session)
  let key = if reading.station == "" { "local" } else { reading.station }
  let existing = all.get(key)
  let previous = existing.unwrap_or({ bytes: default_limit, over: false, told: None })
  if reading.bytes <= previous.bytes {
    if previous.over && reading.complete {
      all.set(key, { ..previous, over: false, told: None })
      self.save(reading.session)
    }
    return
  }
  let now = (self.io.now)()
  match previous {
    { over: true, told: Some(t), .. } if now - t < remind_ms => return
    _ => ()
  }
  let station = if reading.station != "" {
    ", station: \{js_quoted(reading.station)}"
  } else {
    ""
  }
  let place = if reading.station != "" { "on \{reading.name}" } else { "on this station" }
  let gib = reading.bytes / gib_size
  let current = to_fixed(if reading.complete { gib } else { (gib * 10.0).floor() / 10.0 }, 1)
  let limit = to_fixed(previous.bytes / gib_size, 0)
  let at_least = if reading.complete { "" } else { "at least " }
  (self.io.notify)(
    reading.session,
    "Your workspace \{place} (\{reading.path}) uses \{at_least}\{current} GiB, above its \{limit} GiB limit. Inspect it and clean what you are authorized to remove, or raise this workspace's limit with workspace_limit {limit_gib: <new whole GiB>\{station}}. The station will remind you hourly while it remains over the limit; it does not delete files or stop work for this.",
  )
  // An agent may have raised the limit while the notice was being delivered; keep its newer choice.
  let now_there = all.get(key)
  let same = match (existing, now_there) {
    (None, None) => true
    (Some(a), Some(b)) => physical_equal(a, b)
    _ => false
  }
  if !same {
    return
  }
  all.set(key, { ..previous, over: true, told: Some(now) })
  self.save(reading.session)
}

///|
/// Looks every CHECK_MS, the first a minute after it starts, on `rt`.
pub fn WorkspaceWatch::start(self : WorkspaceWatch, rt : @effect.Runtime) -> @effect.Fiber[Unit] {
  rt.fork(async fn() {
    @effect.sleep(60_000) // timer: a sample of this machine (its workspaces' sizes)
    while true {
      self.look()
      @effect.sleep(check_ms.to_int()) // timer: a sample of this machine (its workspaces' sizes)
    }
  })
}
