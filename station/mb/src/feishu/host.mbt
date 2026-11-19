// What the Feishu code asks of the machine, on a station's program: the shell's (`@host.Host::shell`, client/shell's
// `run`). HTTP by `@host.Host::fetch` (its deadline the program's, as AbortSignal.timeout was), a file by
// `@host.Host::read_bytes`, `fs.put`, `fs.mkdir` and `fs.rename`, the machine's time by `@host.now`, a sleep on the program's runtime.

///|
/// HTTP and time on the shell; `stand_in`: $STILLFAIL_FEISHU_API, where a test gives one.
pub fn host_net(host : @host.Host, stand_in? : String? = None) -> Net {
  {
    fetch: async fn(req) {
      let r = host.fetch(
        req.url,
        method_=req.verb,
        headers=req.headers,
        body?=req.body,
        timeout_ms=req.timeout_ms,
      ) catch {
        @host.FetchTimeout => raise FeishuError(@host.fetch_timed_out)
        e => raise e
      }
      { status: r.status, headers: r.headers.map(h => (@jscase.lower(h.0), h.1)), body: r.body }
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
    read: async fn(path) { host.read_bytes(path) },
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
