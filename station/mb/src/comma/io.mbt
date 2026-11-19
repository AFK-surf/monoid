// What the comma parts ask of the machine they run on: its time and timers (station/src/ops/fibers.ts `wall`, and
// `setImmediate`'s turn of the loop), randomness (`randomBytes`, `randomUUID`), the station's log, files, its
// databases, and its words. The station's process gives the machine's own (`host_io`); a test gives its own.

///|
pub(all) struct Io {
  /// `wall.now()`: milliseconds since the epoch.
  now : () -> Double
  /// `wall.after(ms, f)`: f once, ms from now; what it answers calls it off.
  after : (Int, () -> Unit) -> () -> Unit
  /// `wall.sleep(ms)`.
  sleep : async (Int) -> Unit
  /// A turn of the loop (`setImmediate`): what waits meanwhile goes first.
  turn : async () -> Unit
  /// `randomBytes(n).toString("hex")`.
  random_hex : (Int) -> String
  /// `randomUUID()`.
  uuid : () -> String
  /// The station's log: `log.<level>("comma", message, fields)`.
  log : (String, String, J) -> Unit
  /// A file's text, read whole; None where it is not there (ENOENT); raises what else stopped it.
  read_text : (String) -> String? raise
  /// A file written whole, private to the station (`writePrivateSoon`).
  write_private : async (String, String) -> Unit
  /// A directory made with those over it (`mkdir(path, { recursive: true, mode })`).
  mkdir : async (String, Int?) -> Unit
  /// Of the file at a path from `offset`, at most `max` bytes, and its size; None where it cannot be opened.
  file_part : async (String, Double, Int) -> (Double, Bytes)?
  /// A database of the program's own at a path (made where it is not), `busy` ms waited for another's write.
  open_db : (String, Int) -> @sql.Db raise
  /// The system and machine the station says it runs on (`os.platform()`, `os.arch()`, `os.hostname()`), and its
  /// release (`version()`).
  platform : String
  arch : String
  hostname : String
  version : String
  /// The station's words, and its language (`stationLang()`).
  words : Words
  lang : () -> String
}

///|
/// `log.info("comma", …)`.
pub fn Io::info(self : Io, message : String, fields : Array[(String, J?)]) -> Unit {
  (self.log)("info", message, jo(fields))
}

///|
/// `log.warn("comma", …)`.
pub fn Io::warn(self : Io, message : String, fields : Array[(String, J?)]) -> Unit {
  (self.log)("warn", message, jo(fields))
}

///|
/// The station's words of `key` in its language.
pub fn Io::tr(self : Io, lang : String, key : String, args? : Array[(String, String)] = []) -> String {
  self.words.tr(lang, key, args~)
}

///|
/// The path's separator on the station's system.
pub fn Io::sep(self : Io) -> String {
  if self.platform == "win32" {
    "\\"
  } else {
    "/"
  }
}

///|
/// `path.join(...)`.
pub fn Io::join(self : Io, parts : Array[String]) -> String {
  @nodepath.join(self.sep(), parts)
}

///|
/// The machine's own, through the shell of the program (`@host.Host`): its clock and timers on the program's runtime,
/// `crypto.random`, files by `fs.*`, SQLite by `@sql`.
pub fn host_io(
  host : @host.Host,
  words? : Words = Words::empty(),
  lang? : () -> String = () => "zh",
  platform? : String = "darwin",
  arch? : String = "arm64",
  hostname? : String = "",
  version? : String = "",
  log? : (String, String, J) -> Unit = (level, message, fields) => @host.note(
    "comma \{level}: \{message} \{stringify(fields)}",
  ),
) -> Io {
  let random = (n : Int) => {
    let answer = try {
      Some(host.shell_sync("crypto.random", { "bytes": Json::number(n.to_double()) }))
    } catch {
      _ => None
    }
    match answer.map(shell_value) {
      Some(String(h)) => h
      _ => ""
    }
  }
  {
    now: () => @host.epoch_ms().to_double(),
    after: (ms, f) => {
      let fiber = host.rt.fork(async fn() {
        @effect.sleep(if ms < 0 { 0 } else { ms })
        f()
      })
      () => fiber.interrupt()
    },
    sleep: async fn(ms) { @effect.sleep(if ms < 0 { 0 } else { ms }) },
    turn: async fn() { @effect.pause() },
    random_hex: random,
    uuid: () => {
      let h = random(16)
      if h.length() < 32 {
        return h
      }
      // version 4, its variant 10xx
      let v = "0123456789abcdef"
      let y = v.unsafe_charcode_at(8 + (h.unsafe_charcode_at(16) % 4)).unsafe_to_char()
      h.unsafe_substring(start=0, end=8) +
      "-" +
      h.unsafe_substring(start=8, end=12) +
      "-4" +
      h.unsafe_substring(start=13, end=16) +
      "-" +
      y.to_string() +
      h.unsafe_substring(start=17, end=20) +
      "-" +
      h.unsafe_substring(start=20, end=32)
    },
    log,
    read_text: path => {
      let answer = host.shell_sync("fs.bytes", { "path": Json::string(path) })
      match shell_value(answer) {
        String(h) => Some(@utf8.decode_lossy(hex_bytes(h)))
        _ => None
      }
    },
    write_private: async fn(path, text) {
      // as writePrivateSoon: its folder made, written private and synced beside it under a name of its own, renamed over it
      let sep = if platform == "win32" { "\\" } else { "/" }
      host.write_private(path, @utf8.encode(text), sep~)
    },
    mkdir: async fn(path, mode) {
      ignore(host.shell("fs.mkdir", { "path": Json::string(path) }))
      match mode {
        Some(m) =>
          ignore(host.shell("fs.chmod", { "path": Json::string(path), "mode": Json::number(m.to_double()) }))
        None => ()
      }
    },
    file_part: async fn(path, offset, max) {
      let meta = try {
        Some(host.shell_sync("fs.meta", { "path": Json::string(path) }))
      } catch {
        _ => None
      }
      let size = match meta.map(shell_value) {
        Some(Object(m)) =>
          match m.get("size") {
            Some(Number(n, ..)) => n
            _ => return None
          }
        _ => return None
      }
      let want = if size - offset < max.to_double() { size - offset } else { max.to_double() }
      if want <= 0.0 {
        return Some((size, b""))
      }
      let bytes = try {
        Some(
          host.shell_sync("fs.bytes", {
            "path": Json::string(path),
            "from": Json::number(offset),
            "length": Json::number(want),
          }),
        )
      } catch {
        _ => None
      }
      match bytes.map(shell_value) {
        Some(String(h)) => Some((size, hex_bytes(h)))
        _ => None
      }
    },
    open_db: (path, busy) => @sql.Db::create(host, path, wait=busy),
    platform,
    arch,
    hostname,
    version,
    words,
    lang,
  }
}

///|
fn hex_bytes(h : String) -> Bytes {
  let n = h.length() / 2
  let value = (c : Int) => if c >= '0' && c <= '9' {
    c - '0'
  } else if c >= 'a' && c <= 'f' {
    c - 'a' + 10
  } else if c >= 'A' && c <= 'F' {
    c - 'A' + 10
  } else {
    0
  }
  Bytes::from_array(
    FixedArray::makei(n, i => (value(h.unsafe_charcode_at(2 * i)) * 16 + value(h.unsafe_charcode_at(2 * i + 1))).to_byte()),
  )
}

///|
/// What the shell answered: its `value` where it says one.
fn shell_value(answer : Json) -> Json {
  match answer {
    Object(m) =>
      match m.get("value") {
        Some(v) => v
        None => answer
      }
    v => v
  }
}
