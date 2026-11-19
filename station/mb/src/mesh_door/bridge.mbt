// The harness's connections to the program that drives it (station/test/mb-mesh-door.test.ts): each a connection in
// memory (door's `link`), one end this program's, the other carried as lines over stdin and stdout: a stream opened,
// its bytes (base64), its finish, its reset, its being taken to its end, the connection's close. So the TypeScript
// mesh and this one speak to each other end to end, on a clock the test moves.

///|
/// One connection carried: this program's end and the end the lines stand for.
priv struct Carried {
  id : Int
  wire : @door.Wire
  far : @door.Connection
  streams : Map[String, @door.Stream]
  mut opened : Int
}

///|
priv struct Bridge {
  host : @host.Host
  rt : @effect.Runtime
  conns : Map[Int, Carried]
  mut dials : Int
}

///|
fn Bridge::say(self : Bridge, ev : Json) -> Unit {
  self.host.say(ev.stringify())
}

///|
fn num(n : Int) -> Json {
  Json::number(n.to_double())
}

///|
/// What `s` (on the far end, of stream `sid` of connection `c`) brings, said as lines till it ends.
fn Bridge::pump(self : Bridge, c : Carried, sid : String, s : @door.Stream) -> Unit {
  c.streams[sid] = s
  let ev = (kind : String, more : Map[String, Json]) => {
    let m : Map[String, Json] = {
      "ev": Json::string(kind),
      "conn": num(c.id),
      "stream": Json::string(sid),
    }
    for k, v in more {
      m[k] = v
    }
    self.say(Json::object(m))
  }
  ignore(
    self.rt.fork_daemon("bridge read", on_error=e => @door.log("info", "mesh", "a bridged stream was not read", { "error": Json::string(@door.message_of(e)) }), () => {
      while true {
        let got = try { Ok((s.read)()) } catch { e => Err(e) }
        match got {
          Ok(Some(b)) => ev("data", { "b64": Json::string(@base64.encode(b)) })
          Ok(None) => {
            ev("fin", {})
            break
          }
          Err(e) => {
            let m = @door.message_of(e)
            if m.has_prefix("stream reset (") {
              ev("reset", { "code": Json::string(m) })
            }
            break
          }
        }
      }
    }),
  )
  ignore(
    self.rt.fork_daemon("bridge stopped", on_error=_ => (), () => {
      let code = (s.stopped)() catch { _ => None }
      ev("stopped", {
        "code": match code {
          Some(n) => num(n)
          None => Json::null()
        },
      })
    }),
  )
}

///|
/// A connection carried from now on: `role` "door" (the far end dialled it: this program accepted it) or "client".
fn Bridge::carry(self : Bridge, id : Int, local_id : String, remote_id : String, dialled_here : Bool, alpn? : String = "") -> @door.Connection {
  let w = if dialled_here {
    @door.link(local_id, remote_id, alpn~)
  } else {
    @door.link(remote_id, local_id, alpn~)
  }
  let (mine, far) = if dialled_here {
    (w.connection(0), w.connection(1))
  } else {
    (w.connection(1), w.connection(0))
  }
  let far_index = if dialled_here { 1 } else { 0 }
  let c = { id, wire: w, far, streams: Map([]), opened: 0 }
  self.conns[id] = c
  // What this program opens, carried; its close, said.
  ignore(
    self.rt.fork_daemon("bridge accept", on_error=e => @door.log("info", "mesh", "a bridged connection stopped accepting", { "error": Json::string(@door.message_of(e)) }), () => {
      while (c.far.accept_bi)() is Some(s) {
        c.opened += 1
        let sid = "m\{c.opened}"
        self.say({ "ev": "open", "conn": num(id), "stream": Json::string(sid) })
        self.pump(c, sid, s)
      }
    }),
  )
  ignore(
    self.rt.fork_daemon("bridge closed", on_error=_ => (), () => {
      ignore((c.far.closed)()) catch {
        _ => ()
      }
      // (closed by this program's end, not by a line of the far end's)
      if w.closed_by() is Some((by, code, reason)) && by != far_index {
        self.say({ "ev": "close", "conn": num(id), "reason": Json::string(reason), "code": num(code) })
      }
    }),
  )
  mine
}

///|
/// A line from the far end about connection `c`: a stream opened, bytes, a finish, a reset, a close.
async fn Bridge::heard(self : Bridge, line : Json) -> Unit {
  guard line is { "conn": Number(cn, ..), "ev": String(kind), .. } else { return }
  guard self.conns.get(cn.to_int()) is Some(c) else { return }
  let sid = match line { { "stream": String(s), .. } => s; _ => "" }
  match kind {
    "open" => {
      let s = (c.far.open_bi)()
      self.pump(c, sid, s)
    }
    "data" =>
      if c.streams.get(sid) is Some(s) && line is { "b64": String(b), .. } {
        (s.write)(@base64.decode(b))
      }
    "fin" => if c.streams.get(sid) is Some(s) { (s.finish)() }
    "reset" =>
      if c.streams.get(sid) is Some(s) {
        (s.reset)(match line { { "code": Number(n, ..), .. } => n.to_int(); _ => 0 })
      }
    "close" => {
      let code = match line { { "code": Number(n, ..), .. } => n.to_int(); _ => 0 }
      let reason = match line { { "reason": String(r), .. } => r; _ => "" }
      (c.far.close)(code, reason)
    }
    _ => ()
  }
}

