// The program `stillfail-reader harness-mesh-door` (station/test/mb-mesh-door.test.ts): this package's mesh driven by
// the test over stdin and stdout, a JSON line each way, on a clock of the test's (a runtime of its own, moved only as
// the test says `advance`), answering each line it is told once all it set going is done (`{"ack": id}`).
//
// What it is told: `conn` (a connection carried, `bridge.mbt`: the door here serving it with the interop admission, or
// a client here running the interop scenario on it), `ev` (what the far end did on one), `advance`, `advanced` (the
// test moved its own clock as a client here asked), and `call` (one of this package's functions asked, its answer
// said: what is held to its TypeScript as it is).

///|
priv struct Harness {
  host : @host.Host
  rt : @effect.Runtime
  bridge : Bridge
  /// What the keeper asked the test and waits on, by its number.
  asked : Map[Int, @effect.Deferred[Json]]
  mut asks : Int
  mut now : Int64
  mut keeper : @gate.Keeper?
  mut floors : Json
  listeners : Array[() -> Unit]
  /// A client's asks to move the test's clock, waiting for `advanced`.
  advancing : Array[@effect.Deferred[Unit]]
}

///|
/// The packer the shell gives (`zstd.compress`, `zstd.stream`).
pub fn shell_packer(host : @host.Host) -> @door.Packer {
  {
    whole: async fn(bytes : Bytes, level : Int) -> Bytes {
      let (_, out) = host.shell("zstd.compress", { "level": num(level), "window": num(@door.window_log) }, bytes~)
      out.unwrap_or(b"")
    },
    stream: async fn() -> @door.Packing {
      let (made, _) = host.shell("zstd.stream", { "level": num(@door.level), "window": num(@door.window_log) })
      let id = match made { { "id": id, .. } => id; _ => Json::null() }
      {
        push: async fn(piece : Bytes) -> Bytes { host.shell("zstd.push", { "id": id }, bytes=piece).1.unwrap_or(b"") },
        close: () => ignore(host.rt.fork(() => ignore(host.shell("zstd.close", { "id": id })) catch { _ => () })),
      }
    },
  }
}

///|
/// Runs the harness till stdin ends.
pub async fn harness(host : @host.Host) -> Unit {
  let rt = @effect.Runtime::new()
  rt.on_defect(e => host.say(({ "defect": Json::string(e.to_string()) } : Json).stringify()))
  // (a fiber here woken by the shell's answer runs once the host's loop turns)
  rt.on_wake(() => ignore(host.rt.fork(() => ignore(rt.run_ready()))))
  let h : Harness = {
    host,
    rt,
    bridge: { host, rt, conns: Map([]), dials: 0 },
    advancing: [],
    asked: Map([]),
    asks: 0,
    now: 0L,
    keeper: None,
    floors: Json::null(),
    listeners: [],
  }
  host.say(({ "ready": true } : Json).stringify())
  while host.line() is Some(text) {
    let line = @json.parse(text) catch { _ => continue }
    let id = match line { { "id": id, .. } => id; _ => Json::null() }
    match line {
      { "op": "advance", "ms": Number(ms, ..), .. } => rt.advance(ms.to_int())
      { "op": "advanced", .. } => {
        let waiting = h.advancing.copy()
        h.advancing.clear()
        for d in waiting {
          ignore(d.succeed(()))
        }
      }
      { "op": "ev", .. } => ignore(rt.fork(() => h.bridge.heard(line) catch { _ => () }))
      { "op": "conn", .. } => h.conn(line)
      { "op": "call", .. } => ignore(rt.fork(() => h.call(id, line)))
      { "op": "kept", "n": Number(k, ..), .. } =>
        match h.asked.get(k.to_int()) {
          Some(d) => {
            h.asked.remove(k.to_int())
            match line {
              { "error": String(_), .. } => ignore(d.fail(@gate.raised(line)))
              _ => ignore(d.succeed(line.value("value").unwrap_or(Json::null())))
            }
          }
          None => ()
        }
      { "op": "now", "secs": Number(t, ..), .. } => h.now = t.to_int64()
      { "op": "floors", "floors": floors, .. } => h.floors = floors
      { "op": "changed", .. } => for f in h.listeners.copy() { f() }
      _ => ()
    }
    ignore(rt.run_ready())
    host.say(({ "ack": id } : Json).stringify())
  }
}

///|
fn Harness::conn(self : Harness, line : Json) -> Unit {
  guard line is { "conn": Number(cn, ..), "role": String(role), .. } else { return }
  let id = cn.to_int()
  let here = match line { { "local": String(s), .. } => s; _ => "mb" }
  let remote = match line { { "remote": String(s), .. } => s; _ => "ts" }
  match role {
    "door" => {
      let conn = self.bridge.carry(id, here, remote, false)
      ignore(self.rt.fork(name="harness door", () => {
        let packer = shell_packer(self.host)
        @door.door(conn, interop_admit(packer)) catch {
          e => self.host.say(({ "ev": "door ended", "conn": num(id), "error": Json::string(@door.message_of(e)) } : Json).stringify())
        }
        // (served no more: closed with code 0, as accept.mbt closes it)
        (conn.close)(0, "served")
      }))
    }
    "member" => {
      let conn = self.bridge.carry(id, here, remote, false)
      let words = match line { { "update": Object(w), .. } => w; _ => Map([]) }
      let m = self.members(words)
      ignore(self.rt.fork(name="harness member", () => {
        @gate.serve(m, conn) catch {
          e => self.host.say(({ "ev": "door ended", "conn": num(id), "error": Json::string(@gate.words_of(e)) } : Json).stringify())
        }
        (conn.close)(0, "served")
      }))
    }
    "peer" => {
      let alpn = match line { { "alpn": String(a), .. } => a; _ => @gate.peer_bytes_alpn }
      let conn = self.bridge.carry(id, here, remote, false, alpn~)
      let bus = interop_bus()
      ignore(self.rt.fork(name="harness peer", () => {
        @gate.serve_peer(self.the_keeper(), conn, bus) catch {
          e => self.host.say(({ "ev": "door ended", "conn": num(id), "error": Json::string(@gate.words_of(e)) } : Json).stringify())
        }
        (conn.close)(0, "served")
      }))
    }
    "peerclient" => {
      let alpn = match line { { "alpn": String(a), .. } => a; _ => @gate.peer_bytes_alpn }
      let target = remote
      let dialing : @gate.Dialing = {
        connect: async fn(_t, _ws, _given_up) {
          self.bridge.dials += 1
          let cid = id * 1000 + self.bridge.dials
          let conn = self.bridge.carry(cid, here, target, true, alpn~)
          self.host.say(({ "ev": "dial", "conn": num(id), "dialed": num(cid), "alpn": Json::string(alpn) } : Json).stringify())
          conn
        },
        hold: None,
        goes_off: None,
        relays_changed: None,
      }
      let calls = match line { { "calls": Array(a), .. } => a; _ => [] }
      ignore(self.rt.fork(name="harness peer client", () => {
        let station = @gate.peer_call(self.the_keeper(), dialing, self.rt)
        let said = []
        for c in calls {
          said.push(peer_client_step(station.call, target, c))
        }
        self.host.say(({ "ev": "result", "conn": num(id), "said": Json::array(said) } : Json).stringify())
      }))
    }
    "http" => {
      let conn = self.bridge.carry(id, here, remote, false, alpn=@gate.peer_http_alpn)
      ignore(self.rt.fork(name="harness http", () => {
        @gate.serve_http(self.the_keeper(), conn, interop_here()) catch {
          e => self.host.say(({ "ev": "door ended", "conn": num(id), "error": Json::string(@gate.words_of(e)) } : Json).stringify())
        }
        (conn.close)(0, "served")
      }))
    }
    "client" => {
      let conn = self.bridge.carry(id, here, remote, true)
      let hellos = match line { { "hellos": Array(a), .. } => a; _ => [] }
      let c = self.bridge.conns[id]
      ignore(self.rt.fork(name="harness client", () => {
        let said = interop_client(conn, c.wire, 0, hellos, self.host, () => self.ask_time(id))
        self.host.say(({ "ev": "result", "conn": num(id), "said": Json::array(said) } : Json).stringify())
      }))
    }
    _ => ()
  }
}

///|
/// Asks the test to move its clock on as far as what it waits on, once it has.
async fn Harness::ask_time(self : Harness, id : Int) -> Unit {
  let d = @effect.Deferred::new()
  self.advancing.push(d)
  self.host.say(({ "ev": "advance", "conn": num(id) } : Json).stringify())
  d.wait()
}

///|
async fn Harness::call(self : Harness, id : Json, line : Json) -> Unit {
  let answer = try {
    Ok(self.calls(line))
  } catch {
    e => Err(e)
  }
  let said : Json = match answer {
    Ok(v) => { "answer": id, "ok": v }
    Err(e) => { "answer": id, "error": Json::string(@gate.words_of(e)), "lock": Json::boolean(e is @gate.LockRefusal(_)) }
  }
  self.host.say(said.stringify())
}

