// What a rig was told to run (rig/log.ts; a station that only runs tasks): a line for each command a station prepared
// on it and each one run with a secret, with the chat that asked, kept on the rig itself (<data>/rig/commands.log),
// where no station or agent writes. Its person reads the last of it from their app (through a station); `stillfail
// status` names the file.

///|
/// The file goes to `.1` past this, the one before it gone.
let file_max : Double = 4194304.0

///|
/// A line's command is cut to this (what was run in full is in the task's own record).
let command_max : Int = 2000

///|
/// The most of the file's end read for its last lines.
let tail_bytes : Double = 262144.0

///|
pub struct CommandLog {
  priv host : @host.Host
  priv path : String
  /// The lines asked for, appended in turn (two going past FILE_MAX at once would each move the file aside, the second
  /// taking the first's line with it).
  priv queue : Array[String]
  priv mut going : Bool
  priv idle : Array[@effect.Deferred[Unit]]
}

///|
pub fn CommandLog::new(host : @host.Host, path : String) -> CommandLog {
  let disk : @cloud_lock.Disk = { host, }
  disk.mkdir(@cloud_lock.dirname(path))
  { host, path, queue: [], going: false, idle: [] }
}

///|
/// A command told to the log (`Command`: at, station, session, key, name, command, kind), its command cut.
pub fn CommandLog::add(self : CommandLog, c : Array[(String, Json)]) -> Unit {
  let line = jobj(
    c.map(p => if p.0 == "command" {
      match p.1 {
        String(s) if s.length() > command_max => (p.0, jstr(s.unsafe_substring(start=0, end=command_max)))
        _ => p
      }
    } else {
      p
    }),
  )
  self.queue.push(stringify(line) + "\n")
  if !self.going {
    self.going = true
    self.host.rt.fork(() => self.drain()) |> ignore
  }
}

///|
async fn CommandLog::drain(self : CommandLog) -> Unit {
  while self.queue.length() > 0 {
    let line = self.queue.remove(0)
    self.append(line)
  }
  self.going = false
  let waiting = self.idle.copy()
  self.idle.clear()
  for w in waiting {
    w.succeed(()) |> ignore
  }
}

///|
async fn CommandLog::append(self : CommandLog, line : String) -> Unit {
  // A full disk does not stop the task: the station's own log says what it ran too.
  let size = match (try self.host.shell_sync("fs.meta", jobj([("path", jstr(self.path))])) catch { _ => Json::null() }) {
    { "size": Number(n, ..), .. } => n
    _ => 0.0
  }
  if size > file_max {
    let renamed = try {
      let _ = self.host.shell_sync("fs.rename", jobj([("from", jstr(self.path)), ("to", jstr(self.path + ".1"))]))
      true
    } catch {
      _ => false
    }
    if !renamed {
      return
    }
  }
  let _ = self.host.shell(
    "fs.put",
    jobj([("path", jstr(self.path)), ("mode", jnum(384.0))]),
    bytes=@cloud_lock.utf8_of(line),
  ) catch {
    _ => (Json::null(), None)
  }
}

///|
/// Once every line asked for so far is written (or failed).
pub async fn CommandLog::written(self : CommandLog) -> Unit {
  if !self.going {
    return
  }
  let d : @effect.Deferred[Unit] = @effect.Deferred::new()
  self.idle.push(d)
  d.wait()
}

///|
/// Its last `limit` lines, newest first (those asked for before it among them).
pub async fn CommandLog::last(
  self : CommandLog,
  limit : Int,
  workspace? : String? = None,
  include_legacy? : Bool = false,
) -> Array[Json] {
  self.written()
  let size = match (try self.host.shell_sync("fs.meta", jobj([("path", jstr(self.path))])) catch { _ => Json::null() }) {
    { "size": Number(n, ..), "dir": False, .. } => n
    _ => return []
  }
  let from = if size - tail_bytes > 0.0 { size - tail_bytes } else { 0.0 }
  let hex = match
    (try self.host.shell_sync("fs.bytes", jobj([("path", jstr(self.path)), ("from", jnum(from)), ("length", jnum(size - from))])) catch {
      _ => Json::null()
    }) {
    String(h) => h
    _ => return []
  }
  let text = @utf8.decode_lossy(@cloud_lock.hex_bytes(hex))
  let lines = text.split("\n").map(v => v.to_string()).collect()
  // Read from the middle of the file: its first line is the end of one.
  if from > 0.0 && lines.length() > 0 {
    lines.remove(0) |> ignore
  }
  let out = []
  let mut i = lines.length() - 1
  while i >= 0 && out.length() < limit {
    if lines[i] != "" {
      if parse(lines[i]) is Some(v) {
        let keep = match workspace {
          None => true
          Some(ws) =>
            match str_at(Some(v), "workspace") {
              Some(w) => w == ws
              None => include_legacy
            }
        }
        if keep {
          out.push(v)
        }
      }
    }
    i -= 1
  }
  out
}
