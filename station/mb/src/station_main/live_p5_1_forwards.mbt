// P5-1's forwards (sessions/agents.ts's `Forwards`, mesh/peer-forward.ts): another station's port, or a device, given a
// chat as a port of 127.0.0.1 here, each connection to it carried over the mesh (`PeerHttp::tunnel`); the sockets the
// shell's (`tcp.listen`, `tcp.accept`, `tcp.pipe`, `tcp.*`). The other slices ask it on the bus, `$forwards`:
//
//   { "op": "open", "session", "station", "port", "local"?, "job"? }           → the forward's view
//   { "op": "remove", "session", "local" }                                     → the forward's view as it was
//   { "op": "list", "session" }                                                → [views]
//   { "op": "closeSession", "session" }                                        → null (its session ended)
//   { "op": "openDevice", "session", "station", "self", "device": { "id", "name", "here", "admit" } } → the view
//   { "op": "closeDevice", "session"?, "device"?, "why" }                      → null
//
// A device attached here (`here: true`) is reached by asking its slice `devices.reach` `{session, device}` (`ui_ask`),
// which answers a shell's TCP connection to it (`{"id": …}`); one whose chat's processes alone may connect
// (`admit: true`) by `devices.admit` `{session, device, holders}`: null to let it in, else why not.

///|
/// The shell's TCP connections the forwards hold, by the socket as the gate holds it.
let forward_sockets : Array[(@gate.Socket, Json)] = []

///|
fn forward_socket_id(s : @gate.Socket) -> Json? {
  match forward_sockets.search_by(x => physical_equal(x.0, s)) {
    Some(i) => Some(forward_sockets[i].1)
    None => None
  }
}

///|
fn forget_forward_socket(id : Json) -> Unit {
  if forward_sockets.search_by(x => x.1 == id) is Some(i) { ignore(forward_sockets.remove(i)) }
}

///|
/// A connection the shell holds (`tcp.open`'s, `tcp.accept`'s) as the forwards take one; its `peer` where it came from.
fn shell_socket(host : @host.Host, conn : @host.Conn) -> @gate.Socket {
  let id = conn.id
  let gone = Ref(false)
  let closed : @effect.Deferred[Unit] = @effect.Deferred::new()
  let end = () => if !gone.val {
    gone.val = true
    forget_forward_socket(id)
    ignore(closed.succeed(()))
  }
  let peer = conn.peer
  let remote_port = match peer.rev_find(":") {
    Some(i) => @string.parse_int(peer[i + 1:].to_owned()) catch { _ => -1 }
    None => -1
  }
  let s : @gate.Socket = {
    remote_port: if remote_port > 0 { Some(remote_port) } else { None },
    abort: () => if !gone.val {
      end()
      ignore(host.rt.fork_quiet(name="forward close", async fn() { conn.socket.destroy() }))
    },
    destroyed: () => gone.val,
    closed: async fn() { closed.wait() },
    pipe: async fn(stream, carry) {
      pipe_tcp(conn.socket, stream, carry)
      end()
    },
    join: async fn(other) {
      guard forward_socket_id(other) is Some(theirs) else {
        end()
        (other.abort)()
        raise BusError("a device's connection is not the shell's")
      }
      // (carried by the shell itself, both ways)
      host.tcp_pipe(id, theirs) catch {
        _ => ()
      }
      end()
      (other.abort)()
    },
  }
  forward_sockets.push((s, id))
  s
}

///|
/// The machine's sockets as the forwards use them: a port of 127.0.0.1 listened on, each connection taken by a fiber of
/// its own; the processes at the other end of a connection (unix.ts `tcpPortPids`).
fn P51::machine_sockets(self : P51) -> @gate.Sockets {
  let host = self.host
  {
    listen: async fn(port, _mine, take) {
      guard (try Some(host.tcp_listen_local(port)) catch { _ => None }) is Some(listening) else { return None }
      let got = listening.port
      let listener = host.listener_of(listening.id)
      let stopped = Ref(false)
      ignore(
        host.rt.fork_quiet(name="forward accept", async fn() {
          listener.serve(host.rt.root(), async fn(conn) {
            if stopped.val {
              conn.socket.destroy()
              return
            }
            take(shell_socket(host, conn))
          })
        }),
      )
      Some({
        port: got,
        close: () => if !stopped.val {
          stopped.val = true
          // (a listener whose accept is waiting is let go once that accept ends: one connection of its own ends it)
          ignore(
            host.rt.fork_quiet(name="forward unlisten", async fn() {
              listener.close()
              match (try { Ok(host.tcp_open(got)) } catch { e => Err(e) }) {
                Ok(wake) => wake.socket.destroy()
                _ => ()
              }
            }),
          )
        },
      })
    },
    holders: async fn(port) { tcp_port_pids(host, port) },
  }
}

///|
/// The processes holding a connection whose own end is 127.0.0.1:`port` (unix.ts `tcpPortPids`), this one left out;
/// none known on Windows (a device's forward there lets in what connects).
async fn tcp_port_pids(host : @host.Host, port : Int) -> Array[Int] {
  if is_windows() {
    return []
  }
  let own = @drive.pid().to_double()
  if platform() == "darwin" {
    guard run_said(host, "lsof", ["-nP", "-a", "-iTCP@127.0.0.1:\{port}", "-sTCP:ESTABLISHED", "-Fp"], 10000) is Some(out) else {
      return []
    }
    return @ops_platform.lsof_pids(out, own).map(p => p.to_int())
  }
  let tables = []
  for f in ["/proc/net/tcp", "/proc/net/tcp6"] {
    if shell_read_text(host, f) is Some(t) {
      tables.push(t)
    }
  }
  let inodes = @ops_platform.tcp_port_inodes(tables, port)
  if inodes.length() == 0 {
    return []
  }
  // (whose descriptor each socket is: find's -lname over /proc, as the station's readlink of each)
  let args = ["/proc", "-mindepth", "3", "-maxdepth", "3", "-path", "/proc/[0-9]*/fd/*", "("]
  for i, n in inodes {
    if i > 0 {
      args.push("-o")
    }
    args.push("-lname")
    args.push("socket:[\{n}]")
  }
  args.push(")")
  args.push("-print")
  // (find says 1 where some /proc entries could not be read: what it printed still counts)
  let proc = spawn(host, "find", args, stdout=Piped) catch { _ => return [] }
  let out = match @effect.timeout(10000, async fn() { proc.finished() }) {
    Some((_, _, out, _)) => @utf8.decode_lossy(out)
    None => {
      ignore(kill(proc.pid, "SIGKILL"))
      return []
    }
  }
  let pids : Array[Int] = []
  for line in out.split("\n") {
    let parts = line.split("/").map(x => x.to_owned()).to_array()
    if parts.length() > 2 {
      let pid = @string.parse_int(parts[2]) catch { _ => continue }
      if pid.to_double() != own && !pids.contains(pid) {
        pids.push(pid)
      }
    }
  }
  pids
}

///|
/// sessions/agents.ts's forwards, once: their way the mesh's once it is up, a forward going with its job, the ports
/// they hold told to what another station's requests reach here (`forwarded_port`), and their bus.
fn P51::forwards_live(self : P51) -> @gate.Forwards {
  let bus = self.bus
  let host = self.host
  let route = () => match self.mesh {
    Some({ http: Some(http), .. }) =>
      Some(({
        tunnel: async fn(station, port, probe) {
          http.tunnel(station, { "port": Json::number(port.to_double()) }, probe~)
        },
        tunnel_device: Some(async fn(station, device, session, probe) {
          http.tunnel(station, { "device": Json::string(device), "session": Json::string(session) }, probe~)
        }),
      } : @gate.Tunnels))
    _ => None
  }
  let resolve = async fn(station : String) -> (String, String) raise {
    guard self.mesh is Some({ keeper: Some(k), .. }) else {
      raise @gate.Refused("this station is not on the mesh yet; try again shortly")
    }
    let (id, _) = @gate.peer_named(k, station)
    (id, @gate.name_of(k, id))
  }
  let job = (id : String) => match (try { Ok(bus.store.get_job(Json::string(id))) } catch { e => Err(e) }) {
    Ok({ "sessionKey": String(session), "state": String(state), "port": port, .. }) =>
      Some(({ session, state, port: match port { Number(p, ..) => Some(p.to_int()); _ => None } } : @gate.JobState))
    _ => None
  }
  let forwards = @gate.Forwards::new(host.rt, route, resolve, self.machine_sockets(), job~)
  self.forwards = Some(forwards)
  self.stops.push(() => forwards.close())
  // A job's forwards let go with its end.
  self.stops.push(
    bus.subscribe_store(change => match change {
      { "type": "job" | "jobRemoved", "id": String(id), .. } => forwards.job_changed(id)
      _ => ()
    }),
  )
  // What another station's requests may not reach here: a port a chat forwarded (peer-http.ts `forwarded`).
  let before = bus.forwarded_port.val
  bus.forwarded_port.val = port => forwards.forwarded(port) || before(port)
  bus.on_peer("$forwards", async fn(_, _, given, _) {
    // (asked by name, `{op, session, …}`, or as the other slices' parts ask the TypeScript's methods,
    // `{op: "forwards.<method>", args: [...]}`: those arguments named as the first form has them)
    let params = p51_forwards_named(given)
    let get = (k : String) => match params {
      Object(m) => m.get(k)
      _ => None
    }
    let t = (k : String) => opt_str(get(k))
    let n = (k : String) => match get(k) {
      Some(Number(x, ..)) => Some(x.to_int())
      _ => None
    }
    let session = t("session").unwrap_or("")
    let said : Json = match t("op") {
      Some("open") =>
        forwards.open(session, t("station").unwrap_or(""), n("port").unwrap_or(0), local?=n("local"), job?=t("job"))
      Some("remove") => forwards.remove(session, n("local").unwrap_or(0))
      Some("list") => Json::array(forwards.list(session))
      Some("closeSession") => {
        forwards.close_session(session)
        Json::null()
      }
      Some("openDevice") => {
        let d = get("device").unwrap_or(Json::null())
        // (a target as the devices' part gives it: `here` a boolean with its `reach`, admitted by the devices' gate)
        let d = match d {
          { "here": True, "reach": reach, .. } if !(reach is Null) => {
            let m = match d {
              Object(o) => o.copy()
              _ => {}
            }
            m["reachFn"] = reach
            m["admit"] = Json::boolean(!is_windows())
            Json::object(m)
          }
          _ => d
        }
        let dt = (k : String) => match d {
          Object(m) => match m.get(k) { Some(String(s)) => s; _ => "" }
          _ => ""
        }
        let id = dt("id")
        let here = if d is { "here": True, .. } {
          Some(async fn() -> @gate.Socket raise {
            let reached = match d {
              { "reachFn": reach, .. } => (bus.ui_ask.val)("devices.reachForward", Json::array([Json::string(session), reach]))
              _ => bus.ui_devices_reach(session, id)
            }
            match reached {
              { "id": cid, .. } => shell_socket(host, host.conn(cid))
              _ => raise @gate.Refused("the device \{id} cannot be reached on this station")
            }
          })
        } else {
          None
        }
        let admit = if d is { "admit": True, .. } {
          Some(async fn(holders : Array[Int]) -> String? raise {
            match
              (bus.ui_ask.val)(
                "devices.admit",
                Json::array([Json::string(session), Json::string(id), Json::array(holders.map(h => Json::number(h.to_double())))]),
              ) {
              String(why) => Some(why)
              _ => None
            }
          })
        } else {
          None
        }
        forwards.open_device(session, t("station").unwrap_or(""), { id, name: dt("name"), here, admit }, get("self") is Some(True))
      }
      Some("closeDevice") => {
        forwards.close_device(t("session"), t("device"), t("why").unwrap_or("closed"))
        Json::null()
      }
      op => raise BusError("no such forwards call: \{op}")
    }
    (said, None)
  })
  forwards
}

///|
/// A `$forwards` ask as `{op, session, …}`: one made as `{op: "forwards.<method>", args}` (peer-forward.ts's methods'
/// arguments in their order) named so.
fn p51_forwards_named(given : Json) -> Json {
  guard given is { "op": String(op), "args": Array(args), .. } else { return given }
  let a = (i : Int) => if i < args.length() { args[i] } else { Json::null() }
  let method_ = if op.has_prefix("forwards.") { op[9:].to_owned() } else { op }
  let m : Map[String, Json] = { "op": Json::string(method_) }
  match method_ {
    "open" => {
      m["session"] = a(0)
      m["station"] = a(1)
      m["port"] = a(2)
      match a(3) {
        { "local": l, .. } => m["local"] = l
        Number(_, ..) as l => m["local"] = l
        _ => ()
      }
      match a(3) {
        { "job": j, .. } => m["job"] = j
        _ =>
          match a(4) {
            String(_) as j => m["job"] = j
            _ => ()
          }
      }
    }
    "remove" => {
      m["session"] = a(0)
      m["local"] = match a(1) {
        // (a port, or where it is: "127.0.0.1:<port>")
        String(s) =>
          match s.rev_find(":") {
            Some(i) => Json::number((@string.parse_int(s[i + 1:].to_owned()) catch { _ => 0 }).to_double())
            None => Json::number((@string.parse_int(s) catch { _ => 0 }).to_double())
          }
        v => v
      }
    }
    "list" | "closeSession" => m["session"] = a(0)
    "openDevice" => {
      m["session"] = a(0)
      m["station"] = a(1)
      m["device"] = a(2)
      m["self"] = a(3)
    }
    "closeDevice" => {
      m["session"] = a(0)
      m["device"] = a(1)
      m["why"] = a(2)
    }
    _ => ()
  }
  Json::object(m)
}
