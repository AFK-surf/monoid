// adb/door.ts: the door of a grant's adb server (2026-11-05), the port a chat's agent is given. The server itself
// serves any client on its socket and says nothing of who it is, so the phone's listener cannot tell one chat's
// `adb -P <port> shell` from another's. Here each connection's client is found among the machine's processes, and only
// the grant's session (and the station) is put through; the server listens on a socket in a directory of its own,
// named only in its environment.

///|
/// What adb's client shows of a server refusing it: its `FAIL`, with the message's length in four hex digits.
pub fn failure(message : String) -> String {
  // (`Buffer.from(message).subarray(0, 0xffff).toString()`: its UTF-8 cut at 65535 bytes, read again)
  let bytes = @utf8.encode(message)
  let said = if bytes.length() > 0xffff {
    @utf8.decode_lossy(bytes[0:0xffff])
  } else {
    message
  }
  let n = @utf8.encode(said).length().to_string(radix=16)
  "FAIL" + "0".repeat(@cmp.maximum(0, 4 - n.length())) + n + said
}

///|
let refusing_ms : Double = 5000.0

///|
/// Why these processes (those holding the client's end of a connection) may not use grant `id`'s server, or None.
pub type Admit = async (String, Array[Int]) -> String?

///|
/// The client told why, what it sent read so that its end gets the words rather than a reset.
async fn refuse(w : World, socket : J, message : String) -> Unit {
  let stop = w.after(refusing_ms, async fn() {
    ignore(w.ask("net.destroy", [socket])) catch {
      _ => ()
    }
  })
  (w.spawn)(async fn() {
    ignore(w.ask("net.closed", [socket])) catch {
      _ => ()
    }
    stop()
  })
  ignore(w.ask("net.resume", [socket]))
  ignore(w.ask("net.end", [socket, js(failure(message))]))
}

///|
/// A door open: its port, and how it is closed.
pub struct Door {
  port : Int
  close : () -> Unit
}

///|
/// A door on a free port of 127.0.0.1 to the server at `socket_path`.
pub async fn open_door(
  w : World,
  id : String,
  socket_path : String,
  holders_of : async (Int) -> Array[Int],
  admit : Admit,
) -> Door {
  // (127.0.0.1 alone: the machine's own processes, each found among them)
  let listening = w.ask("net.listen", [
    jo([
      ("host", js("127.0.0.1")),
      ("port", ji(0)),
      ("pauseOnConnect", jb(true)),
      ("allowHalfOpen", jb(true)),
    ]),
  ])
  let lid = get(listening, "id")
  let port = num_of(at(Some(listening), "port")).unwrap_or(0.0).to_int()
  (w.spawn)(async fn() {
    while true {
      let socket = w.ask("net.accept", [lid]) catch { _ => Null }
      if socket is Null {
        break
      }
      (w.spawn)(async fn() {
        door_take(w, id, socket_path, holders_of, admit, socket)
      })
    }
  })
  {
    port,
    close: () => {
      (w.spawn)(async fn() {
        ignore(w.ask("net.close", [lid])) catch {
          _ => ()
        }
      })
    },
  }
}

///|
async fn door_take(
  w : World,
  id : String,
  socket_path : String,
  holders_of : async (Int) -> Array[Int],
  admit : Admit,
  socket : J,
) -> Unit {
  let remote = w.ask("net.remotePort", [socket]) catch { _ => Null }
  let holders = match remote {
    Num(p) => holders_of(p.to_int()) catch { _ => [] }
    _ => []
  }
  let why = admit(id, holders) catch {
    e => Some("could not tell who asks: \{message_of(e)}")
  }
  if w.ask("net.destroyed", [socket]) is Bool(true) {
    return
  }
  match why {
    Some(why) => refuse(w, socket, why)
    None => {
      let server = w.ask("net.connect", [
        jo([("path", js(socket_path)), ("allowHalfOpen", jb(true))]),
      ]) catch {
        _ => Null
      }
      if server is Null {
        refuse(
          w, socket, "this chat's adb server is gone: call phone_use again",
        )
        return
      }
      // Both ways until each has ended (adb half-closes), and whichever fails or closes takes the other with it.
      ignore(w.ask("net.join", [socket, server]))
      ignore(w.ask("net.resume", [socket]))
    }
  }
}

///|
/// What the gate needs: the grant's session, the machine's processes, and what of them is whose.
pub struct GateDeps {
  /// The session holding the grant, with its own directory (`{workspace}`), or Null.
  session : (String) -> J raise
  /// The machine's processes (`[{pid, ppid, pgid}]`), Null where they were not read.
  table : async () -> J
  /// The session's agent: the pids of its runner and the runtime it runs.
  runners : async (String) -> Array[Int]
  /// The jobs running: what runs in a job's group is its session's (`mine` of a grant).
  jobs : async () -> Array[(Int, async (String) -> Bool)]
  cwds : async (Array[Int]) -> Map[Int, String]
  /// This station's process: the adb it runs itself is its direct child.
  self_pid : Int
  /// What a process of another chat is told (a phone's words when none given).
  elsewhere : String?
}

///|
let phone_elsewhere : String = "this phone is granted to another chat: ask for it with phone_use in this chat"

///|
fn int_field(v : J, k : String) -> Int? {
  match at(Some(v), k) {
    Some(Num(d)) => Some(d.to_int())
    _ => None
  }
}

///|
/// Why `holders` may not use grant `id`'s server, or None: a process under the session's agent or in one of its jobs;
/// the station's own adb; else one working in the session's own directory.
pub async fn gate(
  d : GateDeps,
  w : World,
  id : String,
  holders : Array[Int],
) -> String? {
  let elsewhere = d.elsewhere.unwrap_or(phone_elsewhere)
  let session = (d.session)(id)
  if session is Null {
    return Some(elsewhere)
  }
  let table = (d.table)()
  guard table is Arr(rows) else {
    return Some(
      "could not tell who asks: the machine's processes were not read",
    )
  }
  let by_pid : Map[Int, J] = Map::new()
  for p in rows {
    match int_field(p, "pid") {
      Some(pid) => by_pid[pid] = p
      None => ()
    }
  }
  let jobs = (d.jobs)()
  let runners = (d.runners)(id)
  for pid in holders {
    guard by_pid.get(pid) is Some(row) else { continue }
    let job = jobs.search_by(j => Some(j.0) == int_field(row, "pgid"))
    if int_field(row, "ppid") == Some(d.self_pid) && job is None {
      return None
    }
    let mut p : J? = Some(row)
    let mut n = 0
    while p is Some(proc) && n < 256 {
      if int_field(proc, "pid") is Some(x) && runners.contains(x) {
        return None
      }
      for j in jobs {
        if Some(j.0) == int_field(proc, "pgid") && (j.1)(id) {
          return None
        }
      }
      p = match int_field(proc, "ppid") {
        Some(pp) => by_pid.get(pp)
        None => None
      }
      n += 1
    }
  }
  let workspace = match at(Some(session), "workspace") {
    Some(Str(_) as s) => js_text(s)
    _ => ""
  }
  if workspace == "" || workspace == "/" {
    return Some(elsewhere)
  }
  let cwds = (d.cwds)(holders)
  let own = (@host_world.fs_realpath(w.host, workspace) catch { _ => None }).unwrap_or(
    workspace,
  )
  let prefix = if own.has_suffix("/") { own } else { own + "/" }
  for pid in holders {
    match cwds.get(pid) {
      Some(cwd) if cwd == own || cwd.has_prefix(prefix) => return None
      _ => ()
    }
  }
  Some(
    "\{elsewhere} (the chat holding it runs adb under its agent or from its own directory, \{workspace})",
  )
}

///|
/// devices/module.ts `admitFor(session)`: why `holders` may not use a device forwarded to session `key`'s port, or
/// None (a process under its agent or in one of its jobs, or working in its own directory), as `gate` decides a phone's.
pub async fn session_gate(w : World, key : String, holders : Array[Int], elsewhere : String) -> String? {
  let deps : GateDeps = {
    session: fn(id) { jo([("workspace", get(w.get_session(id), "workspace"))]) },
    table: async fn() { w.ask("platform.processTable", []) },
    runners: async fn(id) {
      list_of(Some(w.ask("agents.runners", [js(id)]))).map(x => num_of(Some(x)).unwrap_or(-1.0).to_int())
    },
    jobs: async fn() {
      list_of(Some(w.ask("jobs.watched", []))).map(j => {
        let session = get(j, "session")
        (num_of(at(Some(j), "pgid")).unwrap_or(-1.0).to_int(), fn(id : String) -> Bool raise { jeq(session, js(id)) })
      })
    },
    cwds: async fn(pids) { cwds_of(w.ask("platform.cwds", [ja(pids.map(ji))])) },
    self_pid: @host.pid(),
    elsewhere: Some(elsewhere),
  }
  gate(deps, w, key, holders)
}
