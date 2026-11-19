// P5-1's way between the mesh's streams and this machine (mesh/peer-http.ts `HereLocal`, mesh/serve.ts's parts'
// streams): another station's web request passed to a service on 127.0.0.1 (jobs_host's `proxy_preview`), its
// WebSocket (`open_socket`, `pump_socket`) and a forwarded TCP connection carried byte for byte (`tcp.open`); a device's
// connection, a member's stream a part answers itself and a screen's view handed to the slice that has them as a
// handle at the shell: the stream's own (`istream`) where the shell holds it, else a connection of 127.0.0.1 the shell
// holds, carried both ways to the stream here.

///|
/// The shell's streams this process made, by the stream as the gate holds it: their handles at the shell.
let shell_streams : Array[(@door.Stream, Json)] = []

///|
fn remember_shell_stream(s : @door.Stream, id : Json) -> @door.Stream {
  shell_streams.push((s, id))
  // (the oldest let go past many: a stream lives no longer than its request)
  while shell_streams.length() > 4096 {
    ignore(shell_streams.remove(0))
  }
  s
}

///|
fn shell_stream_id(s : @door.Stream) -> Json? {
  match shell_streams.search_by(x => physical_equal(x.0, s)) {
    Some(i) => Some(shell_streams[i].1)
    None => None
  }
}

///|
/// A TCP connection to 127.0.0.1:`port` carried both ways to `stream` (what came on it first, `carry`, given it
/// first), until either ends (peer-forward.ts `pipeTcp`): each side's end passed on as the other's half-close, a
/// failure of either (the stream lost, the connection reset) closing the connection and resetting the stream. Nothing
/// of it fails its caller or its fiber: a fiber of the runtime that fails is its defect (`rt.on_defect`, a log's
/// `WARN runtime:` and a station that exits failed at its next handover).
async fn pipe_tcp(host : @host.Host, conn : Json, stream : @door.Stream, carry : Bytes) -> Unit {
  let over = Ref(false)
  let fail = async fn() {
    if !over.val {
      over.val = true
      ignore(host.shell("tcp.close", { "id": conn })) catch {
        _ => ()
      }
      (stream.reset)(0) catch {
        _ => ()
      }
    }
  }
  // (the stream to the connection)
  let up = host.rt.fork(name="tcp up", async fn() {
    try {
      if carry.length() > 0 {
        ignore(host.shell("tcp.write", { "id": conn }, bytes=carry))
      }
      while !over.val && (stream.read)() is Some(b) {
        if over.val {
          return
        }
        ignore(host.shell("tcp.write", { "id": conn }, bytes=b))
      }
      if !over.val {
        ignore(host.shell("tcp.end", { "id": conn })) catch {
          _ => fail()
        }
      }
    } catch {
      _ => fail()
    }
  })
  defer up.interrupt()
  // (the connection to the stream)
  while !over.val {
    let (said, bytes) = host.shell("tcp.read", { "id": conn }) catch {
      _ => {
        fail()
        break
      }
    }
    match (said, bytes) {
      ({ "end": True, .. }, _) | (_, None) => {
        if !over.val {
          (stream.finish)() catch {
            _ => fail()
          }
        }
        break
      }
      (_, Some(b)) =>
        (stream.write)(b) catch {
          _ => {
            fail()
            break
          }
        }
    }
  }
  // (what the stream still sends delivered, or the connection closed under it: its write fails, `fail`)
  ignore(up.wait())
  ignore(host.shell("tcp.close", { "id": conn })) catch {
    _ => ()
  }
}

///|
/// A stream as a handle at the shell the slice that answers it reads and writes: the shell's own stream (`istream`),
/// its first bytes `carry`; or a connection of 127.0.0.1 the shell holds (`tcp`), carried to the stream by a fiber of
/// this process's until either ends, its first bytes given it already.
async fn shell_handle(host : @host.Host, stream : @door.Stream, carry : Bytes) -> Json {
  match shell_stream_id(stream) {
    Some(id) => { "kind": "istream", "stream": id, "carry": { "$bytes": Json::string(@base64.encode(carry)) } }
    None => {
      let (listening, _) = host.shell("tcp.listen", { "port": 0 })
      guard listening is { "id": lid, "port": Number(port, ..), .. } else { raise BusError("no port for a stream's handle") }
      let (opened, _) = host.shell("tcp.open", { "port": Json::number(port) })
      let (accepted, _) = host.shell("tcp.accept", { "id": lid })
      ignore(host.shell("tcp.close", { "id": lid })) catch {
        _ => ()
      }
      guard opened is { "id": theirs, .. } && accepted is { "id": ours, .. } else { raise BusError("no handle for a stream") }
      ignore(
        host.rt.fork(name="stream handle", async fn() {
          pipe_tcp(host, ours, stream, carry) catch {
            _ => ()
          }
        }),
      )
      { "kind": "tcp", "stream": theirs, "carry": { "$bytes": "" } }
    }
  }
}

///|
/// What another station's web requests reach here (peer-http.ts `HereLocal`): a service on a port of this machine's
/// own, never the station's own ports (the agents' door, the admin port), nor one a chat forwarded here.
fn P51::here_local(self : P51) -> @gate.HereLocal {
  let bus = self.bus
  let host = self.host
  let own = (port : Int) => match read_json(path([bus.data, "run", "mcp.json"])) {
    Some({ "port": Number(p, ..), .. }) if p.to_int() == port => true
    _ =>
      match read_json(path([bus.data, "run", "ports.json"])) {
        Some({ "admin": Number(p, ..), .. }) => p.to_int() == port
        _ => false
      }
  }
  {
    reach: Some(async fn(port) {
      let (opened, _) = host.shell("tcp.open", { "port": Json::number(port.to_double()) })
      guard opened is { "id": conn, .. } else { raise BusError("nothing takes connections on port \{port}") }
      async fn(stream, carry) { pipe_tcp(host, conn, stream, carry) }
    }),
    own,
    forwarded: Some(port => (bus.forwarded_port.val)(port)),
    allowed: None,
    device: Some(async fn(peer, ws, session, device, probe) {
      let ask : Json = {
        "peer": Json::string(peer),
        "workspace": Json::string(ws),
        "session": Json::string(session),
        "device": Json::string(device),
        "probe": Json::boolean(probe),
      }
      if probe {
        // (whether it can be reached: the devices' slice says, refusing why not)
        (bus.here_device.val)(ask, Json::null()) catch {
          @gate.DeviceRefused(_) as e => raise e
          // (the devices' slice refusing with its status: none such here, 404)
          P54Refused(_, { "status": Number(status, ..), "message": String(m), .. }) => raise @gate.DeviceRefused(status.to_int(), m)
          e => raise @gate.DeviceRefused(502, "\{e}")
        }
        return None
      }
      Some(async fn(stream, carry) {
        let handle = shell_handle(host, stream, carry)
        (bus.here_device.val)(ask, handle) catch {
          e => p51_log("WARN", "devices", "a device's connection ended", fields={ "error": Json::string("\{e}") })
        }
      })
    }),
    proxy: async fn(verb, headers, body, port, target) {
      let sent = match body {
        Some(b) => Some(body_bytes(b))
        None => None
      }
      let got = @jobs_host.proxy_preview(host, verb, headers, sent, port, target, (bus.lang.val)(), asker=Peer)
      (got.status, got.headers, { next: got.next, stop: async fn() {  }, check: None })
    },
    socket: async fn(headers, port, target, stream, carry) raise @gate.HttpRefusal {
      let service = @jobs_host.open_socket(host, headers, port, target, (bus.lang.val)(), asker=Peer) catch {
        @jobs_host.SocketRefused(status, words) => raise @gate.HttpRefusal(status, words, false)
      }
      let said : Json = {
        "status": 101,
        "headers": match service.protocol {
          Some(p) => [["sec-websocket-protocol", Json::string(p)]]
          None => []
        },
      }
      @door.write_line(stream, said) catch {
        _ => return
      }
      @jobs_host.pump_socket(host.rt, service, @jobs_host.FrameReader::new(stream.read, carry~), {
        write: stream.write,
        finish: stream.finish,
      }) catch {
        _ => ()
      }
    },
  }
}

///|
/// A member's request a part answers itself (parts.ts `streams`): the part given its head, who asks, and the stream
/// as a handle at the shell with what came on it first and the connection it is on.
fn P51::member_stream(self : P51, answer : async (Json) -> Unit) -> async (@gate.MemberAsk) -> Unit {
  let host = self.host
  async fn(ask : @gate.MemberAsk) {
    let handle = shell_handle(host, ask.stream, ask.reader.take_carry())
    answer({
      "head": ask.head,
      "viewer": ask.viewer.to_json(),
      "stream": handle.value("stream").unwrap_or(Json::null()),
      "kind": handle.value("kind").unwrap_or(Json::null()),
      "carry": handle.value("carry").unwrap_or({ "$bytes": "" }),
      "conn": Json::string((ask.conn.remote_id)()),
    })
  }
}

///|
/// A screen's view a member opens (`{"screen": …}`): the screens' slice's (`ui_ask` `screens.view`), given the stream
/// as a handle at the shell; none there, refused.
fn P51::member_screens(self : P51) -> async (@door.Stream, Bytes, Json, @gate.Viewer, () -> Bool) -> Unit {
  let bus = self.bus
  let host = self.host
  async fn(stream, carry, head, viewer, _up) {
    let handle = shell_handle(host, stream, carry)
    let said = (bus.ui_ask.val)("screens.view", { "head": head, "viewer": viewer.to_json(), "stream": handle })
    if said is Null {
      @door.write_line(stream, { "status": 404, "error": "no screens on this station" })
      (stream.finish)()
    }
  }
}

///|
/// A preview page's WebSocket a member opens (`"socket": true`, jobs/preview.ts): `/preview/<port>/<path>` of a service
/// here, its messages carried both ways.
fn P51::member_socket(self : P51) -> async (@door.Stream, @door.Reader, Json, String) -> Unit {
  let host = self.host
  let bus = self.bus
  async fn(stream, reader, head, target) {
    guard @api_routes.preview_target(target) is Some((port, rest)) else {
      @door.write_line(stream, { "status": 404, "error": "only a preview's WebSocket is opened over the mesh" })
      (stream.finish)()
      return
    }
    let headers = @gate.headers_of(head)
    match (try { Ok(@jobs_host.open_socket(host, headers, port, rest, (bus.lang.val)())) } catch { e => Err(e) }) {
      Ok(service) => {
        @door.write_line(stream, {
          "status": 101,
          "headers": match service.protocol {
            Some(p) => [["sec-websocket-protocol", Json::string(p)]]
            None => []
          },
        })
        @jobs_host.pump_socket(host.rt, service, @jobs_host.FrameReader::new(stream.read, carry=reader.take_carry()), {
          write: stream.write,
          finish: stream.finish,
        })
      }
      Err(@jobs_host.SocketRefused(status, words)) => {
        @door.write_line(stream, { "status": Json::number(status.to_double()), "error": Json::string(words) })
        (stream.finish)()
      }
    }
  }
}

///|
/// The mesh's spans (mesh/traces.ts), where config.json turns them on (`telemetry.traces`): batched to the control plane.
fn P51::member_traces(self : P51, plane : Plane) -> @gate.Traces? {
  guard (self.bus.config_raw.val)() is { "telemetry": { "traces": True, .. }, .. } else { return None }
  let traces = @mesh_runtime.Traces::new(true, self.host.rt, () => @host.now() * 1000000L, (level, words, with_) => p51_log(level.to_upper(), "traces", words, fields=with_))
  traces.export_to(async fn(spans) { plane.control.traces(spans) })
  self.stops.push(() => traces.close())
  let span_of = (j : Json) => match j {
    { "trace": String(t), "span": String(s), "id": String(id), "wall": Number(w, ..), "started": Number(st, ..), .. } =>
      Some(({ parent: { trace: t, span: s, sampled: true }, id, wall_ns: w.to_int64(), started: st.to_int64() } : @mesh_runtime.Span))
    _ => None
  }
  Some({
    start: theirs => match traces.start(@mesh_runtime.parse_parent(theirs), @drive.hex(@drive.random_bytes(8)), wall_ms()) {
      Some(sp) =>
        Some({
          "trace": Json::string(sp.parent.trace),
          "span": Json::string(sp.parent.span),
          "id": Json::string(sp.id),
          "wall": Json::number(sp.wall_ns.to_double()),
          "started": Json::number(sp.started.to_double()),
        })
      None => None
    },
    traceparent: j => match span_of(j) {
      Some(sp) => @mesh_runtime.traceparent(sp)
      None => ""
    },
    end: (j, _, name, attributes, failed) => match span_of(j) {
      Some(sp) => traces.end(sp, name, attributes, failed)
      None => ()
    },
  })
}
