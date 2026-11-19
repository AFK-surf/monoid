// What the Feishu code asks of the machine, on a station's program: the shell's (`@host.Host::shell`, client/shell's
// `run`). HTTP by `fetch` (its deadline the program's, as AbortSignal.timeout was), a file by `fs.bytes`, `fs.put`,
// `fs.mkdir` and `fs.rename`, the machine's time by `@host.now`, a sleep on the program's runtime.

///|
fn shell_hex(j : Json) -> Bytes? {
  let hex = match j {
    String(h) => h
    Object(m) =>
      match m.get("value") {
        Some(String(h)) => h
        _ => return None
      }
    _ => return None
  }
  let n = hex.length() / 2
  let out = FixedArray::make(n, b'\x00')
  for i in 0..<n {
    let hi = hex_digit(hex.unsafe_charcode_at(2 * i)).unwrap_or(0)
    let lo = hex_digit(hex.unsafe_charcode_at(2 * i + 1)).unwrap_or(0)
    out[i] = (hi * 16 + lo).to_byte()
  }
  Some(Bytes::from_array(out))
}

///|
/// HTTP and time on the shell; `stand_in`: $STILLFAIL_FEISHU_API, where a test gives one.
pub fn host_net(host : @host.Host, stand_in? : String? = None) -> Net {
  {
    fetch: async fn(req) {
      let args : Json = {
        "url": Json::string(req.url),
        "method": Json::string(req.verb),
        "headers": Json::array(
          req.headers.map(h => Json::array([Json::string(h.0), Json::string(h.1)])),
        ),
      }
      let call = async fn() {
        let (answer, body) = match req.body {
          Some(b) => host.shell("fetch", args, bytes=b)
          None => host.shell("fetch", args)
        }
        let status = match answer {
          Object(m) =>
            match m.get("status") {
              Some(Number(n, ..)) => n.to_int()
              _ => 0
            }
          _ => 0
        }
        let headers = match answer {
          Object(m) =>
            match m.get("headers") {
              Some(Array(pairs)) =>
                pairs.filter_map(p => match p {
                  Array([String(k), String(v)]) => Some((@jscase.lower(k), v))
                  _ => None
                })
              _ => []
            }
          _ => []
        }
        { status, headers, body: body.unwrap_or(b"") }
      }
      match @effect.timeout(req.timeout_ms, call) {
        Some(r) => r
        None => raise FeishuError("The operation was aborted due to timeout")
      }
    },
    now: () => @host.epoch_ms(),
    sleep: async fn(ms) { @effect.sleep(ms) },
    stand_in,
  }
}

///|
/// The disk on the shell (`sep`: the file system's separator).
pub fn host_disk(host : @host.Host, sep? : String = "/") -> Disk {
  let fs = async fn(op : String, args : Json, bytes : Bytes?) -> Json {
    let (json, _) = match bytes {
      Some(b) => host.shell(op, args, bytes=b)
      None => host.shell(op, args)
    }
    json
  }
  {
    read: async fn(path) {
      shell_hex(fs("fs.bytes", { "path": Json::string(path) }, None))
    },
    write_private: async fn(path, bytes) { host.write_private(path, bytes, sep~) },
    mkdir: async fn(path) {
      ignore(fs("fs.mkdir", { "path": Json::string(path) }, None))
    },
    put_new: async fn(path, bytes) {
      ignore(
        fs(
          "fs.put",
          { "path": Json::string(path), "exclusive": Json::boolean(true) },
          Some(bytes),
        ),
      )
    },
  }
}

///|
/// `n` random bytes of the system's source, as hex (a registration's id).
pub fn host_random_hex(host : @host.Host) -> (Int) -> String {
  n => match
    (try Some(host.shell_sync("crypto.random", { "bytes": Json::number(n.to_double()) })) catch {
      _ => None
    }) {
    Some(String(s)) => s
    _ => ""
  }
}

///|
/// The station's log on the program's stderr (`@host.note`): a line a saying, its fields as JSON.
pub fn host_log() -> Log {
  { say: (level, area, words, fields) => @host.note("[\{level}] \{area}: \{words} \{stringify(fields)}") }
}
