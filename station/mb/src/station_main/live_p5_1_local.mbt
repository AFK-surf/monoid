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
let shell_conns : Array[(@door.Connection, Json)] = []

///|
fn remember_shell_conn(c : @door.Connection, id : Json) -> @door.Connection {
  shell_conns.push((c, id))
  while shell_conns.length() > 1024 {
    ignore(shell_conns.remove(0))
  }
  c
}

///|
fn shell_conn_id(c : @door.Connection) -> Json? {
  match shell_conns.search_by(x => physical_equal(x.0, c)) {
    Some(i) => Some(shell_conns[i].1)
    None => {
      let remote = (c.remote_id)()
      let mut found : Json? = None
      for x in shell_conns {
        if (x.0.remote_id)() == remote && !(x.0.is_closed)() {
          found = Some(x.1)
        }
      }
      found
    }
  }
}

///|
/// A stream of the mesh's as a socket: its read, write and finish; closed, it is reset (code 0) unless both its ways
/// ended already (its peer's end read, its own sent), when there is nothing left to reset.
fn stream_socket(stream : @door.Stream) -> @net.Socket {
  let read_over = Ref(false)
  let finished = Ref(false)
  @net.Socket::new(
    read=async fn() {
      let got = (stream.read)()
      if got is None {
        read_over.val = true
      }
      got
    },
    write=stream.write,
    end_write=async fn() {
      (stream.finish)()
      finished.val = true
    },
    close=async fn() {
      if !(read_over.val && finished.val) {
        (stream.reset)(0)
      }
    },
  )
}

///|
/// A TCP connection to 127.0.0.1 carried both ways to `stream` (what came on it first, `carry`, given it first), until
/// both end (peer-forward.ts `pipeTcp`, `@net.pipe_duplex`): each side's end passed on as the other's half-close, a
/// failure of either (the stream lost, the connection reset) closing the connection and resetting the stream. Nothing
/// of it fails its caller or its fiber: a fiber of the runtime that fails is its defect (`rt.on_defect`, a log's
/// `WARN runtime:` and a station that exits failed at its next handover).
async fn pipe_tcp(conn : @net.Socket, stream : @door.Stream, carry : Bytes) -> Unit noraise {
  let s = stream_socket(stream)
  if carry.length() > 0 {
    conn.write(carry) catch {
      _ => {
        conn.destroy()
        s.destroy()
        return
      }
    }
  }
  @net.pipe_duplex(conn, s)
}

///|
/// A stream as a handle at the shell the slice that answers it reads and writes: the shell's own stream (`istream`),
/// its first bytes `carry`; or a connection of 127.0.0.1 the shell holds (`tcp`), carried to the stream by a fiber of
/// this process's until either ends, its first bytes given it already.
async fn shell_handle(host : @host.Host, stream : @door.Stream, carry : Bytes) -> Json {
  match shell_stream_id(stream) {
    Some(id) => { "kind": "istream", "stream": id, "carry": { "$bytes": Json::string(@base64.encode(carry)) } }
    None => {
      // (a pair of the shell's own: one end handed to the slice, the other carried to the stream here)
      let listening = host.tcp_listen_local(0)
      let pair = try {
        let theirs = host.tcp_open(listening.port)
        Ok((theirs, host.accept(listening.id)))
      } catch {
        e => Err(e)
      }
      host.listen_close(listening.id)
      let (theirs, ours) = match pair {
        Ok(p) => p
        Err(e) => raise e
      }
      ignore(host.rt.fork_quiet(name="stream handle", async fn() { pipe_tcp(ours.socket, stream, carry) }))
      { "kind": "tcp", "stream": theirs.id, "carry": { "$bytes": "" } }
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
      let conn = host.tcp_open(port)
      async fn(stream, carry) { pipe_tcp(conn.socket, stream, carry) }
    }),
    own,
    forwarded: Some(port => (bus.forwarded_port.val)(port)),
    allowed: None,
    device: Some(async fn(peer, ws, session, device, probe) {
      // A rig's devices are reached through its grants (rig/main.ts: `rig.device`, refused while it is starting), the
      // chat's use of one logged, its connection cut once its grant ends; a whole station's need none (all its chats'
      // alike: devices/connect.ts through the devices' slice).
      if bus.as_rig() {
        let socket = @rigs_mode.mesh_device(self.rig, peer, ws, session, device, probe) catch {
          @rigs_mode.DeviceRefused(status, m) => raise @gate.DeviceRefused(status, m)
          e => raise e
        }
        guard socket is Some(socket) else { return None }
        return Some(async fn(stream, carry) {
          let tunnel = shell_handle(host, stream, carry)
          (socket.pipe)(tunnel) catch {
            e => {
              p51_log("WARN", "devices", "a device's connection ended", fields={ "error": Json::string("\{e}") })
              (socket.destroy)()
            }
          }
        })
      }
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
      (got.status, got.headers, { next: got.next, stop: got.close, check: None })
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
      "conn": match shell_conn_id(ask.conn) {
        Some(cid) => { "id": cid, "remoteId": Json::string((ask.conn.remote_id)()) }
        None => Json::string((ask.conn.remote_id)())
      },
    })
  }
}

///|
/// A screen's view a member opens (`{"screen": …}`): handed straight to P5-4's `ui_screen_view` with the raw
/// `@door.Stream` so QUIC `media_datagrams` stays intact; none there, refused.
fn P51::member_screens(self : P51) -> async (@door.Stream, Bytes, Json, @gate.Viewer, () -> Bool) -> Unit {
  let bus = self.bus
  async fn(stream, carry, head, viewer, _up) {
    match bus.ui_screen_view.val {
      Some(view) => {
        let handled = view(stream, carry, head, viewer.to_json())
        if !handled {
          @door.write_line(stream, { "status": 404, "error": "no screens on this station" })
          (stream.finish)()
        }
      }
      None => {
        @door.write_line(stream, { "status": 404, "error": "no screens on this station" })
        (stream.finish)()
      }
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
/// The mesh's spans (mesh/traces.ts), batched to the control plane: config.json's `telemetry.traces` false, none; true,
/// every one; unset, only a failed or slow one.
fn P51::member_traces(self : P51, plane : Plane) -> @gate.Traces? {
  let tail_only = match (self.bus.config_raw.val)() {
    { "telemetry": { "traces": False, .. }, .. } => return None
    { "telemetry": { "traces": True, .. }, .. } => false
    _ => true
  }
  let traces = @mesh_runtime.Traces::new(true, self.host.rt, () => @host.now() * 1000000L, (level, words, with_) => p51_log(level.to_upper(), "traces", words, fields=with_), tail_only~)
  traces.export_to(async fn(spans) { plane.control.traces(spans) })
  let gen = self.bus.emit_span_gen.val + 1
  self.bus.emit_span_gen.val = gen
  self.bus.emit_span.val = fn(name, start_ms, end_ms, attrs, failed, always_keep, slow_ms) {
    let end_ns = (if end_ms < start_ms { start_ms } else { end_ms }) * 1_000_000L
    traces.record_internal(
      @drive.hex(@drive.random_bytes(16)),
      @drive.hex(@drive.random_bytes(8)),
      start_ms * 1_000_000L,
      end_ns,
      name,
      attrs,
      failed,
      always_keep~,
      slow_ms~,
    )
  }
  self.stops.push(() => {
    if self.bus.emit_span_gen.val == gen {
      self.bus.emit_span.val = fn(_n, _s, _e, _a, _f, _k, _m) { () }
    }
    traces.close()
  })
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
